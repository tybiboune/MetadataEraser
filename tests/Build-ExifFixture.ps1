<#
.SYNOPSIS
    Throwaway test-tooling: hand-builds a minimal but spec-valid little-endian TIFF/EXIF
    blob (IFD0 + Exif sub-IFD + GPS sub-IFD) so MetadataCore's EXIF parser can be verified
    against known-correct input, without depending on any external tool actually writing
    real EXIF (ImageMagick's -set exif:* was found not to embed EXIF in this build).
    Not part of the shipped app - used only from the PowerShell test console.
#>

function New-TiffAsciiEntry { param([int]$Tag, [string]$Value) [pscustomobject]@{ Tag = $Tag; Type = 2; Values = @($Value + "`0") ; Kind = 'ascii' } }
function New-TiffLongEntry { param([int]$Tag, [uint32]$Value) [pscustomobject]@{ Tag = $Tag; Type = 4; Values = @($Value); Kind = 'long' } }
function New-TiffRationalEntry { param([int]$Tag, [int[][]]$Pairs) [pscustomobject]@{ Tag = $Tag; Type = 5; Values = $Pairs; Kind = 'rational' } }
function New-TiffUndefinedEntry { param([int]$Tag, [byte[]]$Bytes) [pscustomobject]@{ Tag = $Tag; Type = 7; Values = $Bytes; Kind = 'undefined' } }

function Build-Ifd {
    param([array]$Entries, [uint32]$BaseOffset, [uint32]$NextIfdOffset = 0)
    # Returns @{ Header = <bytes of count+entries+nextOffset>; Extra = <bytes of overflow data>; Size = header.Length }
    $sorted = $Entries | Sort-Object Tag
    $headerSize = 2 + ($sorted.Count * 12) + 4
    $extraStart = $BaseOffset + $headerSize
    $extra = New-Object System.IO.MemoryStream
    $entryBytes = New-Object System.IO.MemoryStream

    foreach ($e in $sorted) {
        $tagBytes = [BitConverter]::GetBytes([uint16]$e.Tag)
        $typeBytes = [BitConverter]::GetBytes([uint16]$e.Type)
        switch ($e.Kind) {
            'ascii' {
                $strBytes = [System.Text.Encoding]::ASCII.GetBytes($e.Values[0])
                $countBytes = [BitConverter]::GetBytes([uint32]$strBytes.Length)
                $entryBytes.Write($tagBytes, 0, 2); $entryBytes.Write($typeBytes, 0, 2); $entryBytes.Write($countBytes, 0, 4)
                if ($strBytes.Length -le 4) {
                    $valField = New-Object byte[] 4
                    [Array]::Copy($strBytes, $valField, $strBytes.Length)
                    $entryBytes.Write($valField, 0, 4)
                }
                else {
                    $offBytes = [BitConverter]::GetBytes([uint32]($extraStart + $extra.Length))
                    $entryBytes.Write($offBytes, 0, 4)
                    $extra.Write($strBytes, 0, $strBytes.Length)
                }
            }
            'long' {
                $countBytes = [BitConverter]::GetBytes([uint32]1)
                $valBytes = [BitConverter]::GetBytes([uint32]$e.Values[0])
                $entryBytes.Write($tagBytes, 0, 2); $entryBytes.Write($typeBytes, 0, 2); $entryBytes.Write($countBytes, 0, 4)
                $entryBytes.Write($valBytes, 0, 4)
            }
            'rational' {
                $count = $e.Values.Count
                $countBytes = [BitConverter]::GetBytes([uint32]$count)
                $entryBytes.Write($tagBytes, 0, 2); $entryBytes.Write($typeBytes, 0, 2); $entryBytes.Write($countBytes, 0, 4)
                $offBytes = [BitConverter]::GetBytes([uint32]($extraStart + $extra.Length))
                $entryBytes.Write($offBytes, 0, 4)
                foreach ($pair in $e.Values) {
                    $n = [BitConverter]::GetBytes([uint32]$pair[0]); $d = [BitConverter]::GetBytes([uint32]$pair[1])
                    $extra.Write($n, 0, 4); $extra.Write($d, 0, 4)
                }
            }
            'undefined' {
                $bytes = $e.Values
                $countBytes = [BitConverter]::GetBytes([uint32]$bytes.Length)
                $entryBytes.Write($tagBytes, 0, 2); $entryBytes.Write($typeBytes, 0, 2); $entryBytes.Write($countBytes, 0, 4)
                if ($bytes.Length -le 4) {
                    $valField = New-Object byte[] 4
                    [Array]::Copy($bytes, $valField, $bytes.Length)
                    $entryBytes.Write($valField, 0, 4)
                }
                else {
                    $offBytes = [BitConverter]::GetBytes([uint32]($extraStart + $extra.Length))
                    $entryBytes.Write($offBytes, 0, 4)
                    $extra.Write($bytes, 0, $bytes.Length)
                }
            }
        }
    }

    $full = New-Object System.IO.MemoryStream
    $countB = [BitConverter]::GetBytes([uint16]$sorted.Count)
    $full.Write($countB, 0, 2)
    $entryArr = $entryBytes.ToArray()
    $full.Write($entryArr, 0, $entryArr.Length)
    $nextB = [BitConverter]::GetBytes([uint32]$NextIfdOffset)
    $full.Write($nextB, 0, 4)
    $extraArr = $extra.ToArray()
    $full.Write($extraArr, 0, $extraArr.Length)
    return $full.ToArray()
}

function New-ExifFixture {
    # Layout: header(8) + IFD0 + GpsIfd + ExifIfd (each self-contained with their own extra data)
    $ifd0Size = 2 + (6 * 12) + 4  # Make, Model, Software, DateTime, ExifPtr, GPSPtr
    $ifd0Offset = 8
    $gpsOffset = $ifd0Offset + $ifd0Size + 500  # generous slack for ASCII overflow
    $exifOffset = $gpsOffset + 500

    $gpsEntries = @(
        [pscustomobject]@{ Tag = 0x0001; Type = 2; Values = @("N`0"); Kind = 'ascii' }
        (New-TiffRationalEntry -Tag 0x0002 -Pairs @(@(40, 1), @(26, 1), @(461400, 10000)))
        [pscustomobject]@{ Tag = 0x0003; Type = 2; Values = @("W`0"); Kind = 'ascii' }
        (New-TiffRationalEntry -Tag 0x0004 -Pairs @(@(79, 1), @(58, 1), @(356500, 10000)))
    )
    $gpsBytes = Build-Ifd -Entries $gpsEntries -BaseOffset $gpsOffset

    $userComment = [System.Text.Encoding]::ASCII.GetBytes("ASCII`0`0`0" + "parameters: masterpiece, prompt: a cat sitting on a wall, Steps: 30")
    $exifEntries = @(
        (New-TiffAsciiEntry -Tag 0x9003 -Value "2026:05:12 14:30:00")
        (New-TiffUndefinedEntry -Tag 0x9286 -Bytes $userComment)
    )
    $exifBytes = Build-Ifd -Entries $exifEntries -BaseOffset $exifOffset

    $ifd0Entries = @(
        (New-TiffAsciiEntry -Tag 0x010F -Value "Canon")
        (New-TiffAsciiEntry -Tag 0x0110 -Value "EOS R5")
        (New-TiffAsciiEntry -Tag 0x0131 -Value "AUTOMATIC1111")
        (New-TiffAsciiEntry -Tag 0x0132 -Value "2026:05:12 14:30:00")
        (New-TiffLongEntry -Tag 0x8769 -Value $exifOffset)
        (New-TiffLongEntry -Tag 0x8825 -Value $gpsOffset)
    )
    $ifd0Bytes = Build-Ifd -Entries $ifd0Entries -BaseOffset $ifd0Offset

    $header = [byte[]](0x49, 0x49, 0x2A, 0x00) + [BitConverter]::GetBytes([uint32]$ifd0Offset)

    $total = New-Object System.IO.MemoryStream
    $total.Write($header, 0, $header.Length)
    $total.Write($ifd0Bytes, 0, $ifd0Bytes.Length)
    $padTo = $gpsOffset - $total.Length
    if ($padTo -gt 0) { $total.Write((New-Object byte[] $padTo), 0, $padTo) }
    $total.Write($gpsBytes, 0, $gpsBytes.Length)
    $padTo2 = $exifOffset - $total.Length
    if ($padTo2 -gt 0) { $total.Write((New-Object byte[] $padTo2), 0, $padTo2) }
    $total.Write($exifBytes, 0, $exifBytes.Length)

    return $total.ToArray()
}
