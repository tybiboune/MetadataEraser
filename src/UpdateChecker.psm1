<#
.SYNOPSIS
    Self-update support: diffs the local app files against the latest commit on GitHub
    (via git blob SHA1, the same hash `git hash-object` produces - so no separate manifest
    file needs to be published or kept in sync) and downloads whatever differs. Network-only
    functions (Get-RemoteTree, Invoke-AppUpdate's download step) talk to the GitHub REST API
    and raw.githubusercontent.com directly; everything else here is pure and covered by tests.
#>

Set-StrictMode -Version Latest

# Only these top-level paths are ever compared/updated - deliberately excludes tests/ (a
# portable end-user install never had it, so it would look permanently "out of date") and
# anything else outside the shipped app (docs, this repo's own .gitignore, etc).
$script:UpdateManifestPaths = @('src', 'web', 'Start-App.bat', 'README.txt')

function Get-GitBlobSha1 {
    <#
    .SYNOPSIS
        The same SHA1 `git hash-object`/the GitHub API reports for a blob: sha1("blob "
        + byte-length + NUL + content). Computing this locally means the update check needs
        no separately-published manifest/version file - the git tree API is the manifest.
    #>
    # AllowEmptyCollection: a Mandatory array parameter otherwise rejects an empty array
    # outright, but a genuinely empty file (0 bytes) is valid input here and has a well-defined
    # git blob hash of its own.
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $header = [System.Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0")
    $full = New-Object byte[] ($header.Length + $Bytes.Length)
    [Array]::Copy($header, 0, $full, 0, $header.Length)
    [Array]::Copy($Bytes, 0, $full, $header.Length, $Bytes.Length)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash($full)
        return -join ($hash | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha1.Dispose()
    }
}

function Get-LocalAppFileMap {
    <#
    .SYNOPSIS
        Every file under the update manifest's scope, as a map of posix-style relative
        path -> git blob SHA1, so it can be compared 1:1 against the GitHub tree API response.
    #>
    param([Parameter(Mandatory)][string]$AppRoot)
    $resolvedRoot = (Resolve-Path -LiteralPath $AppRoot).Path.TrimEnd('\', '/')
    $map = @{}
    foreach ($top in $script:UpdateManifestPaths) {
        $full = Join-Path $resolvedRoot $top
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $bytes = [System.IO.File]::ReadAllBytes($full)
            $map[$top.Replace('\', '/')] = Get-GitBlobSha1 -Bytes $bytes
        }
        elseif (Test-Path -LiteralPath $full -PathType Container) {
            Get-ChildItem -LiteralPath $full -Recurse -File | ForEach-Object {
                $rel = $_.FullName.Substring($resolvedRoot.Length + 1).Replace('\', '/')
                $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
                $map[$rel] = Get-GitBlobSha1 -Bytes $bytes
            }
        }
    }
    return $map
}

function Get-RemoteTree {
    <#
    .SYNOPSIS
        The full recursive file listing (path + blob sha) of the given branch's latest
        commit, via the GitHub REST API. Requires network access; not covered by tests.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [string]$Branch = 'main'
    )
    $uri = "https://api.github.com/repos/$Owner/$Repo/git/trees/${Branch}?recursive=1"
    $headers = @{ 'User-Agent' = 'MetadataEraser-Updater'; 'Accept' = 'application/vnd.github+json' }
    $resp = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15
    if ($resp.truncated) {
        throw 'The remote file listing was too large and got truncated by GitHub - update check is incomplete.'
    }
    return @($resp.tree | Where-Object { $_.type -eq 'blob' })
}

function Get-AppUpdatePlan {
    <#
    .SYNOPSIS
        Compares local file hashes against a remote tree (as returned by Get-RemoteTree) and
        returns the files that are new or changed, scoped to the update manifest paths.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][array]$RemoteTree
    )
    $localMap = Get-LocalAppFileMap -AppRoot $AppRoot
    $prefixes = $script:UpdateManifestPaths
    $changed = @()
    foreach ($entry in $RemoteTree) {
        $path = $entry.path
        $inScope = $false
        foreach ($p in $prefixes) {
            if ($path -eq $p -or $path.StartsWith("$p/")) { $inScope = $true; break }
        }
        if (-not $inScope) { continue }
        if (-not $localMap.ContainsKey($path) -or $localMap[$path] -ne $entry.sha) {
            $changed += [pscustomobject]@{ Path = $path; RemoteSha = $entry.sha }
        }
    }
    return @($changed)
}

function Invoke-AppUpdate {
    <#
    .SYNOPSIS
        Downloads every changed file from raw.githubusercontent.com and overwrites the local
        copy. Reports whether anything under src/ (backend, needs a process restart to take
        effect - PowerShell modules are loaded into memory at startup) or web/ (frontend,
        just needs a page reload) changed.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][array]$ChangedFiles,
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [string]$Branch = 'main'
    )
    $resolvedRoot = (Resolve-Path -LiteralPath $AppRoot).Path.TrimEnd('\', '/')
    $headers = @{ 'User-Agent' = 'MetadataEraser-Updater' }
    $applied = @()
    foreach ($f in $ChangedFiles) {
        $rawUri = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch/$($f.Path)"
        $destPath = Join-Path $resolvedRoot ($f.Path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $destDir = Split-Path -Parent $destPath
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

        $tmpFile = [System.IO.Path]::GetTempFileName()
        try {
            Invoke-WebRequest -Uri $rawUri -Headers $headers -UseBasicParsing -TimeoutSec 20 -OutFile $tmpFile
            Copy-Item -LiteralPath $tmpFile -Destination $destPath -Force
        }
        finally {
            Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
        }
        $applied += $f.Path
    }
    $backendChanged = [bool]($applied | Where-Object { $_ -eq 'src' -or $_.StartsWith('src/') })
    $frontendChanged = [bool]($applied | Where-Object { $_.StartsWith('web/') })
    return [pscustomobject]@{ Applied = $applied; BackendChanged = $backendChanged; FrontendChanged = $frontendChanged }
}

Export-ModuleMember -Function Get-GitBlobSha1, Get-LocalAppFileMap, Get-RemoteTree, Get-AppUpdatePlan, Invoke-AppUpdate
