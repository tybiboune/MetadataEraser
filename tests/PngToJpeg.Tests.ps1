<#
.SYNOPSIS
    Pester tests for the PNG->JPEG conversion path (ConvertTo-JpegFromCleanPng /
    Convert-PngToCleanJpeg) in MetadataCore.psm1.

    Deliberately kept in its own file rather than appended to MetadataCore.Tests.ps1:
    that file has repeatedly triggered a persistent write-lock from this machine's
    antivirus real-time scanning mid-session (see the CMD:Heur.BZC.PZQ.Boxter
    false-positive discussed in project memory) - every edit attempt to it was refused
    with "access denied" even after long waits. A fresh file sidesteps the issue rather
    than fighting it.
#>

$srcDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
Import-Module (Join-Path $srcDir 'MetadataCore.psm1') -Force

Add-Type -AssemblyName System.Drawing

function New-TestPngWithAlpha {
    param([System.Drawing.Color]$FillColor = [System.Drawing.Color]::FromArgb(160, 255, 0, 0))
    $bmp = New-Object System.Drawing.Bitmap 20, 20, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush($FillColor)
    $g.FillRectangle($brush, 0, 0, 20, 20)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return $ms.ToArray()
}

Describe "MetadataCore - PNG to JPEG conversion" {
    It "converts a PNG to a structurally valid JPEG" {
        $png = New-TestPngWithAlpha
        $jpeg = ConvertTo-JpegFromCleanPng -Bytes $png
        (Test-IsJpeg $jpeg) | Should Be $true
    }

    It "flattens transparency onto a white background rather than leaving black" {
        $png = New-TestPngWithAlpha -FillColor ([System.Drawing.Color]::FromArgb(0, 10, 10, 10))  # fully transparent
        $jpeg = ConvertTo-JpegFromCleanPng -Bytes $png
        $bmp = New-Object System.Drawing.Bitmap (New-Object System.IO.MemoryStream(, $jpeg))
        $pixel = $bmp.GetPixel(10, 10)
        $bmp.Dispose()
        # JPEG compression means it won't be exactly 255, but it must be close to white,
        # not anywhere near black (which is what an un-composited alpha channel would give).
        $pixel.R | Should BeGreaterThan 240
        $pixel.G | Should BeGreaterThan 240
        $pixel.B | Should BeGreaterThan 240
    }

    It "produces a JPEG with zero metadata even though the source PNG had some" {
        $png = New-TestPngWithAlpha
        # .NET's own PNG encoder writes a few harmless color-management chunks
        # (sRGB/gAMA/pHYs) by default - confirm the source actually has metadata to
        # strip, so this test proves something rather than passing vacuously.
        (@(Get-PngMetadataReport -Bytes $png)).Count | Should BeGreaterThan 0

        $jpeg = Convert-PngToCleanJpeg -Bytes $png
        (Test-IsJpeg $jpeg) | Should Be $true
        (@(Get-JpegMetadataReport -Bytes $jpeg)).Count | Should Be 0
    }

    It "produces output at the same pixel dimensions as the source PNG" {
        $png = New-TestPngWithAlpha
        $jpeg = ConvertTo-JpegFromCleanPng -Bytes $png
        $srcBmp = New-Object System.Drawing.Bitmap (New-Object System.IO.MemoryStream(, $png))
        $outBmp = New-Object System.Drawing.Bitmap (New-Object System.IO.MemoryStream(, $jpeg))
        $outBmp.Width | Should Be $srcBmp.Width
        $outBmp.Height | Should Be $srcBmp.Height
        $srcBmp.Dispose(); $outBmp.Dispose()
    }

    It "rejects a non-PNG input to ConvertTo-JpegFromCleanPng" {
        $bmp = New-Object System.Drawing.Bitmap 10, 10
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        $bmp.Dispose()
        $jpg = $ms.ToArray()
        { ConvertTo-JpegFromCleanPng -Bytes $jpg } | Should Throw
    }

    It "respects a custom quality parameter (higher quality produces a larger file for the same image)" {
        $png = New-TestPngWithAlpha
        $lowQ = ConvertTo-JpegFromCleanPng -Bytes $png -Quality 20
        $highQ = ConvertTo-JpegFromCleanPng -Bytes $png -Quality 95
        $highQ.Length | Should BeGreaterThan $lowQ.Length
    }
}
