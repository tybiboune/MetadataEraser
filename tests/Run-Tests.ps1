<#
.SYNOPSIS
    Runs every Pester test file in this directory and exits non-zero on any failure.
    Requires Pester 3.4.0, which ships with Windows PowerShell 5.1 - no separate install
    needed on a normal Windows machine.
#>
param()

Import-Module Pester -RequiredVersion 3.4.0 -Force
$result = Invoke-Pester -Script $PSScriptRoot -PassThru
if ($result.FailedCount -gt 0) {
    Write-Host "`n$($result.FailedCount) test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host "`nAll $($result.PassedCount) tests passed." -ForegroundColor Green
