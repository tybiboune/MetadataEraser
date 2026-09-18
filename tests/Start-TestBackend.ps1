param([int]$Port = 8744)
Import-Module "C:\Gemini\MetadataEraser\src\Http.psm1" -Force
Import-Module "C:\Gemini\MetadataEraser\src\Routes.psm1" -Force
Import-Module "C:\Gemini\MetadataEraser\src\MetadataCore.psm1" -Force
Import-Module "C:\Gemini\MetadataEraser\src\UpdateChecker.psm1" -Force
$AppState = [hashtable]::Synchronized(@{ StopRequested = $false; LastHeartbeat = $null; ListenerStarted = $false })
Register-AppRoutes -Port $Port
Start-Backend -Port $Port -WebRoot "C:\Gemini\MetadataEraser\web" -AppState $AppState
