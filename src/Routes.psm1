<#
.SYNOPSIS
    API route registration. Runs inside the backend's own runspace (see App.ps1), so it
    shares that runspace's loaded copy of Http.psm1/MetadataCore.psm1 and therefore the
    same populated route table - Add-ApiRoute in a different runspace would register into
    a route table nobody's accept loop ever reads.
#>

Set-StrictMode -Version Latest

# The GitHub repo self-updates check/pull from. Update-checking is entirely opt-in (the user
# clicks the button) and only ever reads this specific public repo - never anything else.
$script:UpdateOwner = 'tybiboune'
$script:UpdateRepo = 'MetadataEraser'
$script:UpdateBranch = 'main'

function Register-AppRoutes {
    param([int]$Port = 8744)
    # Captured once here (a plain top-level function call, so $PSScriptRoot is reliable) and
    # read later from inside the route scriptblocks below via module script-scope, since a
    # scriptblock stored in a hashtable and invoked elsewhere can't rely on its own $PSScriptRoot.
    $script:AppRoot = Split-Path -Parent $PSScriptRoot
    $script:Port = $Port

    Add-ApiRoute -Method 'GET' -Path '/api/ping' -Handler {
        param($Request, $Response, $AppState)
        Send-JsonResponse -Response $Response -StatusCode 200 -Object @{ ok = $true }
    }

    Add-ApiRoute -Method 'POST' -Path '/api/heartbeat' -Handler {
        param($Request, $Response, $AppState)
        $AppState.LastHeartbeat = Get-Date
        Send-JsonResponse -Response $Response -StatusCode 200 -Object @{ ok = $true }
    }

    Add-ApiRoute -Method 'POST' -Path '/api/strip' -Handler {
        param($Request, $Response, $AppState)

        $contentType = $Request.ContentType
        if (-not $contentType -or $contentType -notmatch '^multipart/form-data') {
            Send-JsonResponse -Response $Response -StatusCode 400 -Object @{ error = 'Expected multipart/form-data.' }
            return
        }

        $boundary = Get-MultipartBoundary -ContentType $contentType
        $bodyBytes = Get-RequestBodyBytes -Request $Request
        $parts = Parse-MultipartFormData -Body $bodyBytes -Boundary $boundary
        $fileParts = @($parts | Where-Object { $_.FileName })

        # Plain form field (no filename), not a file - opts every PNG in this batch into
        # PNG->JPEG conversion after cleaning. "true" is the only truthy value the
        # frontend ever sends; anything else (including absent) means off.
        $convertField = $parts | Where-Object { -not $_.FileName -and $_.Name -eq 'convertPngToJpeg' } | Select-Object -First 1
        $convertPngToJpeg = $false
        if ($convertField) {
            $convertPngToJpeg = ([System.Text.Encoding]::UTF8.GetString($convertField.Data)) -eq 'true'
        }

        if ($fileParts.Count -eq 0) {
            Send-JsonResponse -Response $Response -StatusCode 400 -Object @{ error = 'No files were uploaded.' }
            return
        }

        $results = @()
        foreach ($part in $fileParts) {
            $entry = [ordered]@{
                name          = $part.FileName
                ok            = $false
                error         = $null
                format        = $null
                convertedFrom = $null
                originalSize  = $part.Data.Length
                cleanedSize   = 0
                before        = @()
                remainingAfter = @()
                details       = @()
                cleanedBase64 = $null
            }
            try {
                $format = Get-ImageFormat -Bytes $part.Data
                if (-not $format) {
                    throw 'Unsupported file type - only PNG and JPEG images are supported.'
                }
                $before = @(Get-ImageMetadataReport -Bytes $part.Data)
                # Full un-truncated key/value dump of everything found - separate from the
                # short chip labels above, only pulled apart client-side when the user
                # actually asks to see it (a "View full metadata" toggle per file).
                $detail = @(Get-ImageMetadataDetail -Bytes $part.Data)

                if ($format -eq 'png' -and $convertPngToJpeg) {
                    $cleaned = Convert-PngToCleanJpeg -Bytes $part.Data
                    $entry.format = 'jpeg'
                    $entry.convertedFrom = 'png'
                }
                else {
                    $cleaned = Remove-ImageMetadata -Bytes $part.Data
                    $entry.format = $format
                }
                $after = @(Get-ImageMetadataReport -Bytes $cleaned)

                $entry.before = @($before | ForEach-Object { @{ label = $_.Label; isAi = [bool]$_.IsAi } })
                $entry.remainingAfter = @($after | ForEach-Object { @{ label = $_.Label; isAi = [bool]$_.IsAi } })
                $entry.details = @($detail | ForEach-Object { @{ key = $_.Key; value = $_.Value; isAi = [bool]$_.IsAi } })
                $entry.cleanedSize = $cleaned.Length
                $entry.cleanedBase64 = [Convert]::ToBase64String($cleaned)
                $entry.ok = $true
            }
            catch {
                $entry.error = $_.Exception.Message
            }
            $results += [pscustomobject]$entry
        }

        Send-JsonResponse -Response $Response -StatusCode 200 -Object @{ results = $results }
    }

    Add-ApiRoute -Method 'GET' -Path '/api/update/check' -Handler {
        param($Request, $Response, $AppState)
        try {
            $tree = @(Get-RemoteTree -Owner $script:UpdateOwner -Repo $script:UpdateRepo -Branch $script:UpdateBranch)
            # @()-wrap at the call site, not just inside the function - a single changed file
            # would otherwise unwrap to a bare PSCustomObject when captured here, and .Count
            # would throw under Set-StrictMode (this bit us before, see UpdateChecker.Tests.ps1).
            $changed = @(Get-AppUpdatePlan -AppRoot $script:AppRoot -RemoteTree $tree)
            Send-JsonResponse -Response $Response -StatusCode 200 -Object @{
                upToDate     = ($changed.Count -eq 0)
                changedFiles = @($changed | ForEach-Object { $_.Path })
            }
        }
        catch {
            Send-JsonResponse -Response $Response -StatusCode 502 -Object @{ error = "Could not check for updates: $($_.Exception.Message)" }
        }
    }

    Add-ApiRoute -Method 'POST' -Path '/api/update/apply' -Handler {
        param($Request, $Response, $AppState)
        try {
            $tree = @(Get-RemoteTree -Owner $script:UpdateOwner -Repo $script:UpdateRepo -Branch $script:UpdateBranch)
            $changed = @(Get-AppUpdatePlan -AppRoot $script:AppRoot -RemoteTree $tree)
            if ($changed.Count -eq 0) {
                Send-JsonResponse -Response $Response -StatusCode 200 -Object @{ ok = $true; applied = @(); backendChanged = $false; frontendChanged = $false }
                return
            }
            $result = Invoke-AppUpdate -AppRoot $script:AppRoot -ChangedFiles $changed -Owner $script:UpdateOwner -Repo $script:UpdateRepo -Branch $script:UpdateBranch
            Send-JsonResponse -Response $Response -StatusCode 200 -Object @{
                ok             = $true
                applied        = $result.Applied
                backendChanged = $result.BackendChanged
                frontendChanged = $result.FrontendChanged
            }
        }
        catch {
            Send-JsonResponse -Response $Response -StatusCode 502 -Object @{ error = "Update failed: $($_.Exception.Message)" }
        }
    }

    Add-ApiRoute -Method 'POST' -Path '/api/update/restart' -Handler {
        param($Request, $Response, $AppState)
        # PowerShell modules are loaded into memory once at startup, so a changed .psm1/.ps1
        # file on disk has no effect until the process restarts. The new process retries
        # binding the port (see Start-Backend) until this one releases it, so there's no
        # window where the app is unreachable other than the handoff itself.
        try {
            $appScript = Join-Path $script:AppRoot 'src\App.ps1'
            Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $appScript, '-Port', $script:Port, '-Relaunched'
            ) -WindowStyle Hidden
            Send-JsonResponse -Response $Response -StatusCode 200 -Object @{ ok = $true; restarting = $true }
            $AppState.StopRequested = $true
        }
        catch {
            Send-JsonResponse -Response $Response -StatusCode 500 -Object @{ error = "Could not restart: $($_.Exception.Message)" }
        }
    }
}

Export-ModuleMember -Function Register-AppRoutes
