<#
.SYNOPSIS
    Entry point. Starts the local HTTP backend on a background runspace, opens the UI in
    an Edge app-mode window, and shuts down once the page stops sending heartbeats (mirrors
    the same approach used by the sibling OptimizerPS app, minus the WebView2/native-drop
    machinery - this app only ever needs uploaded file *bytes*, not real filesystem paths,
    since dropped files are read client-side via the standard HTML5 File API and processed
    server-side over HTTP, so a plain browser window is enough).
#>
param(
    [int]$Port = 8744,
    [switch]$NoBrowser,
    # Set by the self-updater when it restarts the backend after applying an update: a
    # browser tab is already open and will reconnect on its own once the port answers again,
    # so opening a second Edge window here would just leave a stray duplicate window behind.
    [switch]$Relaunched
)

$ErrorActionPreference = 'Stop'

function Write-FatalErrorAndPause {
    param($ErrorRecord, [string[]]$ExtraLines = @())
    Write-Host ''
    Write-Host 'FATAL ERROR - the app could not start.' -ForegroundColor Red
    if ($ErrorRecord) {
        Write-Host $ErrorRecord.Exception.Message -ForegroundColor Red
        Write-Host $ErrorRecord.ScriptStackTrace -ForegroundColor DarkRed
    }
    foreach ($line in $ExtraLines) { Write-Host $line -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Please copy the text above and report it.' -ForegroundColor Yellow
    Read-Host 'Press Enter to close this window'
}

try {
    $root = Split-Path -Parent $PSScriptRoot
    $srcDir = Join-Path $root 'src'
    $webRoot = Join-Path $root 'web'

    $AppState = [hashtable]::Synchronized(@{
        StopRequested   = $false
        LastHeartbeat   = $null
        ListenerStarted = $false
    })

    $modulePaths = @(
        (Join-Path $srcDir 'Http.psm1'),
        (Join-Path $srcDir 'Routes.psm1'),
        (Join-Path $srcDir 'MetadataCore.psm1'),
        (Join-Path $srcDir 'UpdateChecker.psm1')
    )

    $backendThread = [powershell]::Create()
    [void]$backendThread.AddScript({
        param($Port, $WebRoot, $AppState, $ModulePaths)
        foreach ($m in $ModulePaths) { Import-Module $m -Force }
        Register-AppRoutes -Port $Port
        Start-Backend -Port $Port -WebRoot $WebRoot -AppState $AppState
    }).AddArgument($Port).AddArgument($webRoot).AddArgument($AppState).AddArgument($modulePaths)

    $backendHandle = $backendThread.BeginInvoke()

    if ($NoBrowser) {
        Start-Sleep -Milliseconds 400
        return [pscustomobject]@{ BackendThread = $backendThread; BackendHandle = $backendHandle; AppState = $AppState; Port = $Port }
    }

    Write-Host "Starting backend on port $Port ..."
    $backendReady = $false
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/ping" -UseBasicParsing -TimeoutSec 1
            if ($r.StatusCode -eq 200) { $backendReady = $true; break }
        }
        catch { Start-Sleep -Milliseconds 300 }
    }
    if (-not $backendReady) {
        $backendErrors = @()
        if ($backendThread.Streams.Error.Count -gt 0) {
            $backendErrors = @('Backend errors:') + ($backendThread.Streams.Error | ForEach-Object { $_.ToString() })
        }
        Write-FatalErrorAndPause -ErrorRecord $null -ExtraLines (@("The backend never responded on http://127.0.0.1:$Port/ after 9 seconds.") + $backendErrors)
        exit 1
    }
    Write-Host 'Backend is up.'

    if ($Relaunched) {
        Write-Host 'Relaunched after a self-update - the existing browser tab will reconnect on its own.'
    }
    else {
        $edgePaths = @(
            "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
            "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        )
        $edge = $edgePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

        if ($edge) {
            $edgeProfileDir = Join-Path $env:TEMP 'MetadataEraser_EdgeProfile'
            New-Item -ItemType Directory -Path $edgeProfileDir -Force | Out-Null
            $edgeArgs = @("--app=http://127.0.0.1:$Port/", "--user-data-dir=$edgeProfileDir", '--no-first-run', '--window-size=1180,840')
            Start-Process -FilePath $edge -ArgumentList $edgeArgs | Out-Null
            Write-Host 'Opened Edge app window.'
        }
        else {
            # Edge is preinstalled on every current Windows 10/11 machine, but a machine where
            # it was removed (or a locked-down corporate image) shouldn't leave the user with
            # nothing but a warning and a backend quietly running in the background - falling
            # back to whatever the OS considers the default browser gets a working window
            # either way, just without the app-mode chrome Edge's --app flag provides.
            Write-Warning 'Microsoft Edge was not found - opening the default browser instead.'
            try {
                Start-Process "http://127.0.0.1:$Port/" | Out-Null
            }
            catch {
                Write-Warning "Could not open a browser automatically. Open http://127.0.0.1:$Port/ manually."
            }
        }
    }

    Write-Host 'Waiting for the browser tab to connect...'
    $heartbeatTimeoutSeconds = 90
    $firstHeartbeatDeadline = (Get-Date).AddSeconds(30)
    $warnedSlowStart = $false
    while ($true) {
        Start-Sleep -Seconds 2
        if ($AppState.StopRequested) {
            Write-Host 'Restart requested (self-update applied) - shutting down so the new process can bind the port.'
            break
        }
        if ($AppState.LastHeartbeat) {
            if (((Get-Date) - $AppState.LastHeartbeat).TotalSeconds -gt $heartbeatTimeoutSeconds) {
                Write-Host "No response from the browser tab for $heartbeatTimeoutSeconds s - assuming it was closed."
                break
            }
        }
        elseif ((Get-Date) -gt $firstHeartbeatDeadline -and -not $warnedSlowStart) {
            Write-Warning "The browser page hasn't checked in yet after 30s. If the window looks blank, try refreshing it, or open http://127.0.0.1:$Port/ manually. Still waiting..."
            $warnedSlowStart = $true
        }
    }

    $AppState.StopRequested = $true
    Start-Sleep -Milliseconds 300
    $backendThread.Stop()
    $backendThread.Dispose()
}
catch {
    Write-FatalErrorAndPause -ErrorRecord $_
    exit 1
}
