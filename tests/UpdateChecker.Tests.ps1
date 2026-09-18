<#
.SYNOPSIS
    Pester tests for UpdateChecker.psm1. Uses real `git hash-object` (git is a hard
    dependency of this repo anyway) as ground truth for the blob-hash tests rather than
    hardcoded hash literals, and a throwaway temp directory as a stand-in app root - no
    network access is exercised except in the Invoke-AppUpdate tests, which mock
    Invoke-WebRequest instead of hitting raw.githubusercontent.com.
#>

$srcDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
Import-Module (Join-Path $srcDir 'UpdateChecker.psm1') -Force

function New-TempAppRoot {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("MetadataEraserUpdateTest_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'src') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'web\js') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'tests') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $root 'src\App.ps1'), "# app`n")
    [System.IO.File]::WriteAllText((Join-Path $root 'web\index.html'), "<html></html>")
    [System.IO.File]::WriteAllText((Join-Path $root 'web\js\app.js'), "console.log('hi');")
    [System.IO.File]::WriteAllText((Join-Path $root 'Start-App.bat'), "@echo off`n")
    [System.IO.File]::WriteAllText((Join-Path $root 'README.txt'), "readme")
    # Deliberately out of the update manifest's scope - must never be touched or compared.
    [System.IO.File]::WriteAllText((Join-Path $root 'tests\Some.Tests.ps1'), "# not shipped")
    return $root
}

function Get-RealGitBlobSha1 {
    param([string]$Path)
    (git hash-object -- $Path) | Select-Object -First 1
}

Describe "UpdateChecker - Get-GitBlobSha1" {
    $tempRoot = New-TempAppRoot

    It "matches git hash-object for a plain text file" {
        $path = Join-Path $tempRoot 'src\App.ps1'
        $expected = Get-RealGitBlobSha1 -Path $path
        $actual = Get-GitBlobSha1 -Bytes ([System.IO.File]::ReadAllBytes($path))
        $actual | Should Be $expected
    }

    It "matches git hash-object for an empty file" {
        $emptyPath = Join-Path $tempRoot 'empty.txt'
        [System.IO.File]::WriteAllBytes($emptyPath, [byte[]]@())
        $expected = Get-RealGitBlobSha1 -Path $emptyPath
        $actual = Get-GitBlobSha1 -Bytes ([byte[]]@())
        $actual | Should Be $expected
    }

    It "matches git hash-object for binary (non-UTF8) bytes" {
        $binPath = Join-Path $tempRoot 'bin.dat'
        $bytes = [byte[]](0, 255, 128, 10, 13, 0, 254, 1, 2, 3)
        [System.IO.File]::WriteAllBytes($binPath, $bytes)
        $expected = Get-RealGitBlobSha1 -Path $binPath
        $actual = Get-GitBlobSha1 -Bytes $bytes
        $actual | Should Be $expected
    }

    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe "UpdateChecker - Get-LocalAppFileMap" {
    $tempRoot = New-TempAppRoot
    $map = Get-LocalAppFileMap -AppRoot $tempRoot

    It "includes files under src/ and web/ with posix-style relative paths" {
        $map.ContainsKey('src/App.ps1') | Should Be $true
        $map.ContainsKey('web/index.html') | Should Be $true
        $map.ContainsKey('web/js/app.js') | Should Be $true
    }

    It "includes the root-level manifest files" {
        $map.ContainsKey('Start-App.bat') | Should Be $true
        $map.ContainsKey('README.txt') | Should Be $true
    }

    It "excludes tests/ entirely" {
        ($map.Keys | Where-Object { $_ -like 'tests/*' }) | Should Be $null
    }

    It "reports the correct hash for a known file" {
        $expected = Get-RealGitBlobSha1 -Path (Join-Path $tempRoot 'src\App.ps1')
        $map['src/App.ps1'] | Should Be $expected
    }

    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe "UpdateChecker - Get-AppUpdatePlan" {
    $tempRoot = New-TempAppRoot
    $localMap = Get-LocalAppFileMap -AppRoot $tempRoot

    $remoteTree = @(
        [pscustomobject]@{ path = 'src/App.ps1'; sha = $localMap['src/App.ps1']; type = 'blob' }                # unchanged
        [pscustomobject]@{ path = 'web/index.html'; sha = 'deadbeef0000000000000000000000000000dead'; type = 'blob' } # changed
        [pscustomobject]@{ path = 'web/js/new-feature.js'; sha = 'cafef00d0000000000000000000000000000cafe'; type = 'blob' } # new file
        [pscustomobject]@{ path = 'tests/Some.Tests.ps1'; sha = 'feedface00000000000000000000000000feedfa'; type = 'blob' } # out of scope
        [pscustomobject]@{ path = 'README.md'; sha = '1111111111111111111111111111111111111a'; type = 'blob' }  # out of scope (not README.txt)
    )

    $plan = Get-AppUpdatePlan -AppRoot $tempRoot -RemoteTree $remoteTree

    It "excludes files whose hash matches the local copy" {
        ($plan | Where-Object { $_.Path -eq 'src/App.ps1' }) | Should Be $null
    }

    It "includes a changed in-scope file" {
        ($plan | Where-Object { $_.Path -eq 'web/index.html' }) | Should Not Be $null
    }

    It "includes a new in-scope file with no local counterpart" {
        ($plan | Where-Object { $_.Path -eq 'web/js/new-feature.js' }) | Should Not Be $null
    }

    It "excludes files outside the manifest scope even when their hash differs" {
        ($plan | Where-Object { $_.Path -eq 'tests/Some.Tests.ps1' }) | Should Be $null
        ($plan | Where-Object { $_.Path -eq 'README.md' }) | Should Be $null
    }

    It "returns exactly the two in-scope changed/new files" {
        $plan.Count | Should Be 2
    }

    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe "UpdateChecker - Get-AppUpdatePlan with exactly one changed file" {
    # Regression test: PowerShell unwraps a single-element array to a bare object when a
    # function's output is captured by the caller, even if the function itself wrapped its
    # return value in @() - only wrapping *at the call site* (as Routes.psm1 now does)
    # actually prevents it. This must be tested with exactly one match, since two or more
    # changed files never trigger the unwrap and would hide the bug.
    $tempRoot = New-TempAppRoot
    $localMap = Get-LocalAppFileMap -AppRoot $tempRoot
    $remoteTree = @(
        [pscustomobject]@{ path = 'src/App.ps1'; sha = $localMap['src/App.ps1']; type = 'blob' } # unchanged
        [pscustomobject]@{ path = 'web/index.html'; sha = 'deadbeef0000000000000000000000000000dead'; type = 'blob' } # the one change
    )

    It "is still countable (not unwrapped to a bare object) via the exact call pattern Routes.psm1 uses" {
        $plan = @(Get-AppUpdatePlan -AppRoot $tempRoot -RemoteTree $remoteTree)
        $plan.Count | Should Be 1
        $plan[0].Path | Should Be 'web/index.html'
    }

    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe "UpdateChecker - Invoke-AppUpdate" {
    $tempRoot = New-TempAppRoot

    Mock Invoke-WebRequest -ModuleName UpdateChecker -MockWith {
        param($Uri, $Headers, $UseBasicParsing, $TimeoutSec, $OutFile)
        [System.IO.File]::WriteAllText($OutFile, "downloaded:$Uri")
    }

    $changed = @(
        [pscustomobject]@{ Path = 'src/App.ps1'; RemoteSha = 'aaa' }
        [pscustomobject]@{ Path = 'web/js/new-feature.js'; RemoteSha = 'bbb' }
    )
    $result = Invoke-AppUpdate -AppRoot $tempRoot -ChangedFiles $changed -Owner 'tybiboune' -Repo 'MetadataEraser' -Branch 'main'

    It "writes the downloaded content to the correct local path" {
        $content = [System.IO.File]::ReadAllText((Join-Path $tempRoot 'src\App.ps1'))
        $content | Should Be 'downloaded:https://raw.githubusercontent.com/tybiboune/MetadataEraser/main/src/App.ps1'
    }

    It "creates missing directories for a brand-new file" {
        (Test-Path (Join-Path $tempRoot 'web\js\new-feature.js')) | Should Be $true
    }

    It "flags backendChanged when a src/ file was applied" {
        $result.BackendChanged | Should Be $true
    }

    It "flags frontendChanged when a web/ file was applied" {
        $result.FrontendChanged | Should Be $true
    }

    It "reports both applied paths" {
        $result.Applied.Count | Should Be 2
    }

    Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
