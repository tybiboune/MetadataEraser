<#
.SYNOPSIS
    Minimal local HTTP server (System.Net.HttpListener) plus a byte-level multipart/
    form-data parser. Single-threaded accept loop - deliberately not pooled like a
    multi-user server would be, since this app only ever serves one local browser tab
    stripping a handful of images at a time; a request queue of depth 1 is invisible to
    the user and keeps the whole backend easy to reason about.
#>

Set-StrictMode -Version Latest

$script:Routes = @{}

function Add-ApiRoute {
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][scriptblock]$Handler)
    $script:Routes["$Method $Path"] = $Handler
}

$script:MimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.ico'  = 'image/x-icon'
}

function Get-RequestBodyBytes {
    param($Request)
    $stream = New-Object System.IO.MemoryStream
    $Request.InputStream.CopyTo($stream)
    return $stream.ToArray()
}

function Find-BytePattern {
    <#
    .SYNOPSIS
        Index of the first occurrence of Pattern in Haystack at or after StartIndex, or -1.
        Scans for candidate positions via the pattern's first byte (sparse in real data,
        including image bytes) then verifies the full pattern only at each candidate -
        avoids an O(n*m) byte-by-byte compare across a multi-megabyte upload body.
    #>
    param([byte[]]$Haystack, [byte[]]$Pattern, [int]$StartIndex = 0)
    $hLen = $Haystack.Length
    $pLen = $Pattern.Length
    if ($pLen -eq 0 -or $StartIndex -ge $hLen) { return -1 }
    $first = $Pattern[0]
    $i = $StartIndex
    while ($true) {
        $idx = [Array]::IndexOf($Haystack, $first, $i, $hLen - $i)
        if ($idx -lt 0) { return -1 }
        if ($idx + $pLen -gt $hLen) { return -1 }
        $match = $true
        for ($j = 1; $j -lt $pLen; $j++) {
            if ($Haystack[$idx + $j] -ne $Pattern[$j]) { $match = $false; break }
        }
        if ($match) { return $idx }
        $i = $idx + 1
    }
}

function Get-MultipartBoundary {
    param([string]$ContentType)
    if ($ContentType -notmatch 'boundary="?([^";]+)"?') { throw 'multipart/form-data request is missing a boundary.' }
    return $Matches[1]
}

function Parse-MultipartFormData {
    <#
    .SYNOPSIS
        Splits a multipart/form-data body into parts. Each returned part has Name,
        FileName (empty for plain fields), ContentType, and Data (raw bytes, no encoding
        transform - correct for binary image uploads).
    #>
    param([Parameter(Mandatory)][byte[]]$Body, [Parameter(Mandatory)][string]$Boundary)

    $enc = [System.Text.Encoding]::ASCII
    $delimiter = $enc.GetBytes("--$Boundary")
    $crlf = [byte[]](13, 10)
    $headerEnd = $enc.GetBytes("`r`n`r`n")

    $parts = @()
    $pos = Find-BytePattern -Haystack $Body -Pattern $delimiter -StartIndex 0
    if ($pos -lt 0) { return $parts }
    $pos += $delimiter.Length

    while ($true) {
        # Boundary is followed by either CRLF (another part follows) or "--" (end of body).
        if ($pos + 1 -lt $Body.Length -and $Body[$pos] -eq 0x2D -and $Body[$pos + 1] -eq 0x2D) { break }
        if ($pos + 1 -lt $Body.Length -and $Body[$pos] -eq $crlf[0] -and $Body[$pos + 1] -eq $crlf[1]) { $pos += 2 }

        $hEnd = Find-BytePattern -Haystack $Body -Pattern $headerEnd -StartIndex $pos
        if ($hEnd -lt 0) { break }
        $headerText = [System.Text.Encoding]::UTF8.GetString($Body, $pos, $hEnd - $pos)
        $dataStart = $hEnd + $headerEnd.Length

        $name = ''
        $fileName = ''
        # Values are usually quoted ( name="files" ) but not every client quotes them
        # (.NET's HttpClient MultipartFormDataContent writes name=files unquoted by
        # default) - both forms are accepted. The negative lookahead on filename keeps
        # "filename=" from also matching the leading part of "filename*=" (RFC 5987
        # extended filename, sent alongside the plain one by HttpClient).
        if ($headerText -match 'name="([^"]*)"') { $name = $Matches[1] }
        elseif ($headerText -match 'name=([^;\r\n]+)') { $name = $Matches[1].Trim() }
        if ($headerText -match 'filename="([^"]*)"') { $fileName = $Matches[1] }
        elseif ($headerText -match 'filename=(?!\*)([^;\r\n]+)') { $fileName = $Matches[1].Trim() }
        $partContentType = ''
        if ($headerText -match 'Content-Type:\s*([^\r\n]+)') { $partContentType = $Matches[1].Trim() }

        $nextDelim = Find-BytePattern -Haystack $Body -Pattern $delimiter -StartIndex $dataStart
        if ($nextDelim -lt 0) { break }
        # The two bytes immediately before the boundary are the trailing CRLF of this part's
        # data, not part of the payload itself.
        $dataEnd = $nextDelim
        if ($dataEnd -ge 2 -and $Body[$dataEnd - 2] -eq $crlf[0] -and $Body[$dataEnd - 1] -eq $crlf[1]) { $dataEnd -= 2 }
        $dataLength = [Math]::Max(0, $dataEnd - $dataStart)
        $data = New-Object byte[] $dataLength
        if ($dataLength -gt 0) { [Array]::Copy($Body, $dataStart, $data, 0, $dataLength) }

        $parts += [pscustomobject]@{ Name = $name; FileName = $fileName; ContentType = $partContentType; Data = $data }

        $pos = $nextDelim + $delimiter.Length
    }
    return $parts
}

function Send-JsonResponse {
    param($Response, [int]$StatusCode, $Object)
    $json = $Object | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Send-BinaryResponse {
    param($Response, [int]$StatusCode, [byte[]]$Bytes, [string]$ContentType, [string]$FileName)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    if ($FileName) {
        $Response.Headers.Add('Content-Disposition', "attachment; filename=`"$FileName`"")
    }
    $Response.ContentLength64 = $Bytes.Length
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Response.OutputStream.Close()
}

function Send-StaticFile {
    param($Response, [string]$WebRoot, [string]$UrlPath)
    $relative = $UrlPath.TrimStart('/')
    if ([string]::IsNullOrEmpty($relative)) { $relative = 'index.html' }
    $fullPath = Join-Path $WebRoot $relative
    $resolvedRoot = (Resolve-Path $WebRoot).Path
    $candidate = [System.IO.Path]::GetFullPath($fullPath)
    if (-not $candidate.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $Response.StatusCode = 404
        $Response.OutputStream.Close()
        return
    }
    $ext = [System.IO.Path]::GetExtension($candidate).ToLowerInvariant()
    $contentType = if ($script:MimeTypes.ContainsKey($ext)) { $script:MimeTypes[$ext] } else { 'application/octet-stream' }
    $bytes = [System.IO.File]::ReadAllBytes($candidate)
    Send-BinaryResponse -Response $Response -StatusCode 200 -Bytes $bytes -ContentType $contentType -FileName $null
}

function Start-Backend {
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$WebRoot, [Parameter(Mandatory)]$AppState)

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:$Port/")
    # A self-update restart briefly overlaps the old and new process on the same port (the
    # new one is spawned before the old one has released its listener) - retry instead of
    # failing outright so that handoff doesn't need to be perfectly sequenced.
    $bound = $false
    $bindAttempts = 20
    for ($i = 0; $i -lt $bindAttempts; $i++) {
        try {
            $listener.Start()
            $bound = $true
            break
        }
        catch [System.Net.HttpListenerException] {
            if ($i -eq $bindAttempts - 1) { throw }
            Start-Sleep -Milliseconds 300
        }
    }
    $AppState.ListenerStarted = $true

    try {
        while (-not $AppState.StopRequested) {
            $contextTask = $listener.GetContextAsync()
            while (-not $contextTask.AsyncWaitHandle.WaitOne(250)) {
                if ($AppState.StopRequested) { $listener.Stop(); return }
            }
            $context = $contextTask.GetAwaiter().GetResult()
            $request = $context.Request
            $response = $context.Response
            try {
                $key = "$($request.HttpMethod) $($request.Url.AbsolutePath)"
                if ($script:Routes.ContainsKey($key)) {
                    & $script:Routes[$key] $request $response $AppState
                }
                elseif ($request.HttpMethod -eq 'GET') {
                    Send-StaticFile -Response $response -WebRoot $WebRoot -UrlPath $request.Url.AbsolutePath
                }
                else {
                    $response.StatusCode = 404
                    $response.OutputStream.Close()
                }
            }
            catch {
                try {
                    Send-JsonResponse -Response $response -StatusCode 500 -Object @{ error = $_.Exception.Message }
                }
                catch { }
            }
        }
    }
    finally {
        if ($listener.IsListening) { $listener.Stop() }
        $listener.Close()
    }
}

Export-ModuleMember -Function Add-ApiRoute, Get-RequestBodyBytes, Get-MultipartBoundary, Parse-MultipartFormData, `
    Send-JsonResponse, Send-BinaryResponse, Send-StaticFile, Start-Backend, Find-BytePattern
