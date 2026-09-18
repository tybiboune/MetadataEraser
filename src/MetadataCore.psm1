<#
.SYNOPSIS
    Byte-level PNG/JPEG metadata stripping. Deliberately does NOT decode/re-encode pixel
    data through System.Drawing or any codec - it walks the container format (PNG chunks /
    JPEG marker segments) and copies image-essential parts through unchanged while dropping
    everything else. That makes the strip lossless (bit-identical pixels, same file size
    class) and immune to whatever a re-encode's default quality/color-management settings
    would otherwise silently change.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Shared byte helpers
# ---------------------------------------------------------------------------

function Read-UInt32BE {
    param([byte[]]$Bytes, [int]$Offset)
    return ([uint32]$Bytes[$Offset] -shl 24) -bor ([uint32]$Bytes[$Offset + 1] -shl 16) -bor ([uint32]$Bytes[$Offset + 2] -shl 8) -bor ([uint32]$Bytes[$Offset + 3])
}

function Read-UInt16BE {
    param([byte[]]$Bytes, [int]$Offset)
    return ([int]$Bytes[$Offset] -shl 8) -bor ([int]$Bytes[$Offset + 1])
}

function Get-NullTerminatedLatin1 {
    <#
    .SYNOPSIS
        Reads a Latin-1 string starting at Offset up to (not including) the first NUL byte,
        or up to MaxLength bytes, whichever comes first. Used only for reading PNG tEXt/
        zTXt/iTXt keywords - never for the payload itself, which may be compressed/binary.
    #>
    param([byte[]]$Bytes, [int]$Offset, [int]$MaxLength = 79)
    $end = $Offset
    $limit = [Math]::Min($Bytes.Length, $Offset + $MaxLength)
    while ($end -lt $limit -and $Bytes[$end] -ne 0) { $end++ }
    return [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($Bytes, $Offset, $end - $Offset)
}

# Keywords/markers strongly associated with AI-generation metadata, checked
# case-insensitively against PNG text-chunk keywords, JPEG COM text, and EXIF/XMP content
# previews. Used only to flag entries as "AI" in the report - stripping itself is blanket
# (every non-essential chunk/segment is removed regardless of whether it matches this list).
$script:AiMetadataHints = @(
    'parameters', 'prompt', 'negative_prompt', 'workflow', 'comfyui', 'comfy',
    'stable diffusion', 'sd-metadata', 'dream', 'novelai', 'midjourney', 'invokeai',
    'generation_data', 'c2pa', 'ai_generated', 'aigc'
)

function Add-AiFlagToDetailEntries {
    <#
    .SYNOPSIS
        Stamps each {Key;Value} detail entry with an IsAi flag (checked against both the
        key and the value text), so the "full metadata" inspector view can highlight
        AI-related rows the same way the short chip summary does.
    #>
    param([array]$Entries)
    return @($Entries | ForEach-Object {
        [pscustomobject]@{ Key = $_.Key; Value = $_.Value; IsAi = ((Test-IsAiHint $_.Key) -or (Test-IsAiHint $_.Value)) }
    })
}

function Test-IsAiHint {
    param([string]$Text)
    if (-not $Text) { return $false }
    $lower = $Text.ToLowerInvariant()
    foreach ($hint in $script:AiMetadataHints) {
        if ($lower.Contains($hint)) { return $true }
    }
    return $false
}

function Expand-ZlibBytes {
    <#
    .SYNOPSIS
        Inflates zlib-wrapped deflate data (RFC 1950 - a 2-byte header, a raw deflate
        stream, then a 4-byte Adler32 trailer) as used by PNG zTXt/iTXt/iCCP payloads.
        .NET Framework 4.x (what Windows PowerShell 5.1 runs on) only ships raw-deflate
        DeflateStream, not a zlib-aware wrapper, so the 2-byte header is skipped manually
        before handing the rest to DeflateStream - a standard, well-known workaround.
    #>
    param([byte[]]$Bytes)
    if ($Bytes.Length -lt 2) { return [byte[]]@() }
    # NOTE: the compressed-data stream is deliberately not named $input - that's a
    # PowerShell automatic/reserved variable (the pipeline input enumerator), and
    # assigning to it here was confirmed to silently corrupt this exact expression
    # (New-Object's argument list evaluated against stale/wrong types, throwing
    # "op_Subtraction" errors on what should be a plain Int32 subtraction).
    # ($Bytes.Length - 2) MUST be parenthesized: PowerShell's comma (array-literal)
    # operator binds tighter than binary "-" here, so an unparenthesized
    # "$Bytes, 2, $Bytes.Length - 2" argument list is actually parsed as
    # "($Bytes, 2, $Bytes.Length) - 2" - building a 3-element array, then trying (and
    # failing) to subtract 2 from that whole array - confirmed by reproducing the
    # identical "System.Object[] has no op_Subtraction" error with a bare `1,2,3-1`.
    $compressedStream = New-Object System.IO.MemoryStream($Bytes, 2, ($Bytes.Length - 2))
    $deflate = New-Object System.IO.Compression.DeflateStream($compressedStream, [System.IO.Compression.CompressionMode]::Decompress)
    $output = New-Object System.IO.MemoryStream
    try { $deflate.CopyTo($output) } finally { $deflate.Dispose() }
    return $output.ToArray()
}

# ---------------------------------------------------------------------------
# EXIF / TIFF (shared by PNG's eXIf chunk and JPEG's APP1 Exif segment)
# ---------------------------------------------------------------------------

$script:ExifIfd0Tags = @{
    0x010E = 'ImageDescription'; 0x010F = 'Make'; 0x0110 = 'Model'; 0x0112 = 'Orientation'
    0x011A = 'XResolution'; 0x011B = 'YResolution'; 0x0128 = 'ResolutionUnit'
    0x0131 = 'Software'; 0x0132 = 'DateTime'; 0x013B = 'Artist'; 0x8298 = 'Copyright'
}
$script:ExifSubIfdTags = @{
    0x829A = 'ExposureTime'; 0x829D = 'FNumber'; 0x8827 = 'ISOSpeedRatings'
    0x9003 = 'DateTimeOriginal'; 0x9004 = 'DateTimeDigitized'; 0x9201 = 'ShutterSpeedValue'
    0x9202 = 'ApertureValue'; 0x9209 = 'Flash'; 0x920A = 'FocalLength'
    0x9286 = 'UserComment'; 0xA002 = 'PixelXDimension'; 0xA003 = 'PixelYDimension'
    0xA405 = 'FocalLengthIn35mmFilm'; 0xA420 = 'ImageUniqueID'; 0xA430 = 'CameraOwnerName'
    0xA431 = 'BodySerialNumber'; 0xA433 = 'LensMake'; 0xA434 = 'LensModel'
}
$script:ExifGpsTags = @{
    0x0001 = 'GPSLatitudeRef'; 0x0002 = 'GPSLatitude'; 0x0003 = 'GPSLongitudeRef'
    0x0004 = 'GPSLongitude'; 0x0005 = 'GPSAltitudeRef'; 0x0006 = 'GPSAltitude'
    0x0007 = 'GPSTimeStamp'; 0x001D = 'GPSDateStamp'
}
# Bytes-per-component for each TIFF field type (index = type id, 1-12).
$script:ExifTypeSizes = @(0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8)

function Get-ExifEntries {
    <#
    .SYNOPSIS
        Parses a TIFF/EXIF byte blob (starting exactly at the "II"/"MM" byte-order marker -
        callers strip any "Exif`0`0" prefix first) into a flat list of {Name; Value}
        entries covering IFD0, the Exif sub-IFD, and the GPS sub-IFD. Tags this module
        doesn't have a friendly name for are still included, labeled by their raw tag
        number, rather than silently dropped - the goal is to show everything present, not
        just a curated subset. Returns an empty list (never throws) on malformed EXIF, since
        a broken EXIF blob shouldn't block viewing the rest of a file's metadata.
    #>
    param([byte[]]$Bytes)
    $entries = @()
    try {
        if ($Bytes.Length -lt 8) { return $entries }
        $bigEndian = $false
        if ($Bytes[0] -eq 0x4D -and $Bytes[1] -eq 0x4D) { $bigEndian = $true }
        elseif ($Bytes[0] -eq 0x49 -and $Bytes[1] -eq 0x49) { $bigEndian = $false }
        else { return $entries }

        $readU16 = {
            param([int]$Offset)
            if ($bigEndian) { return ([int]$Bytes[$Offset] -shl 8) -bor [int]$Bytes[$Offset + 1] }
            return ([int]$Bytes[$Offset + 1] -shl 8) -bor [int]$Bytes[$Offset]
        }
        $readU32 = {
            param([int]$Offset)
            if ($bigEndian) {
                return ([uint32]$Bytes[$Offset] -shl 24) -bor ([uint32]$Bytes[$Offset + 1] -shl 16) -bor ([uint32]$Bytes[$Offset + 2] -shl 8) -bor [uint32]$Bytes[$Offset + 3]
            }
            return ([uint32]$Bytes[$Offset + 3] -shl 24) -bor ([uint32]$Bytes[$Offset + 2] -shl 16) -bor ([uint32]$Bytes[$Offset + 1] -shl 8) -bor [uint32]$Bytes[$Offset]
        }

        function Format-ExifValue {
            param([int]$Type, [uint32]$Count, [int]$ValueOffset)
            $size = if ($Type -ge 1 -and $Type -le 12) { $script:ExifTypeSizes[$Type] } else { 0 }
            if ($size -eq 0 -or $Count -eq 0) { return $null }
            $totalBytes = $size * $Count
            $dataOffset = if ($totalBytes -le 4) { $ValueOffset } else { [int](& $readU32 $ValueOffset) }
            if ($dataOffset -lt 0 -or $dataOffset + $totalBytes -gt $Bytes.Length) { return $null }

            switch ($Type) {
                2 {
                    # ASCII, NUL-terminated.
                    $s = [System.Text.Encoding]::ASCII.GetString($Bytes, $dataOffset, $Count).TrimEnd([char]0)
                    return $s
                }
                7 {
                    # UNDEFINED - typically UserComment: 8-byte character-code prefix then text.
                    if ($Count -gt 8) {
                        $code = [System.Text.Encoding]::ASCII.GetString($Bytes, $dataOffset, 8).TrimEnd([char]0)
                        $textBytes = $Count - 8
                        $enc = if ($code -eq 'UNICODE') { [System.Text.Encoding]::BigEndianUnicode } else { [System.Text.Encoding]::ASCII }
                        return $enc.GetString($Bytes, $dataOffset + 8, $textBytes).Trim([char]0)
                    }
                    return "$Count byte(s) of binary data"
                }
                { $_ -in @(3, 4, 8, 9) } {
                    # SHORT/LONG/SSHORT/SLONG - one or more integers.
                    $vals = @()
                    for ($i = 0; $i -lt $Count; $i++) {
                        $off = $dataOffset + ($i * $size)
                        if ($size -eq 2) { $vals += (& $readU16 $off) } else { $vals += [int](& $readU32 $off) }
                    }
                    return ($vals -join ', ')
                }
                { $_ -in @(5, 10) } {
                    # RATIONAL/SRATIONAL - numerator/denominator pairs.
                    $vals = @()
                    for ($i = 0; $i -lt $Count; $i++) {
                        $off = $dataOffset + ($i * 8)
                        $num = [int](& $readU32 $off)
                        $den = [int](& $readU32 ($off + 4))
                        if ($den -ne 0) { $vals += "$num/$den ($([Math]::Round($num / $den, 4)))" } else { $vals += "$num/$den" }
                    }
                    return ($vals -join ', ')
                }
                default { return "$Count byte(s) of binary data" }
            }
        }

        function Read-Ifd {
            param([int]$Offset, [hashtable]$TagNames, [string]$Prefix)
            $result = @()
            if ($Offset -le 0 -or $Offset + 2 -gt $Bytes.Length) { return $result }
            $count = & $readU16 $Offset
            $entryStart = $Offset + 2
            for ($i = 0; $i -lt $count; $i++) {
                $entryOffset = $entryStart + ($i * 12)
                if ($entryOffset + 12 -gt $Bytes.Length) { break }
                $tag = & $readU16 $entryOffset
                $type = & $readU16 ($entryOffset + 2)
                $cnt = & $readU32 ($entryOffset + 4)
                # Skip the two sub-IFD pointer tags themselves - their sub-IFDs are parsed
                # separately below and a raw byte offset isn't meaningful to show as a value.
                if ($tag -eq 0x8769 -or $tag -eq 0x8825) { continue }
                $name = if ($TagNames.ContainsKey($tag)) { $TagNames[$tag] } else { 'Tag 0x{0:X4}' -f $tag }
                $value = Format-ExifValue -Type $type -Count $cnt -ValueOffset ($entryOffset + 8)
                if ($null -ne $value -and $value -ne '') {
                    $result += [pscustomobject]@{ Name = "$Prefix$name"; Value = $value }
                }
            }
            return $result
        }

        $ifd0Offset = [int](& $readU32 4)
        $entries += Read-Ifd -Offset $ifd0Offset -TagNames $script:ExifIfd0Tags -Prefix ''

        # Sub-IFD pointers live among IFD0's entries; find them directly rather than
        # re-walking, since Read-Ifd deliberately skips emitting them as values.
        if ($ifd0Offset -gt 0 -and $ifd0Offset + 2 -le $Bytes.Length) {
            $count = & $readU16 $ifd0Offset
            for ($i = 0; $i -lt $count; $i++) {
                $entryOffset = $ifd0Offset + 2 + ($i * 12)
                if ($entryOffset + 12 -gt $Bytes.Length) { break }
                $tag = & $readU16 $entryOffset
                if ($tag -eq 0x8769) {
                    $exifOffset = [int](& $readU32 ($entryOffset + 8))
                    $entries += Read-Ifd -Offset $exifOffset -TagNames $script:ExifSubIfdTags -Prefix 'Exif:'
                }
                elseif ($tag -eq 0x8825) {
                    $gpsOffset = [int](& $readU32 ($entryOffset + 8))
                    $entries += Read-Ifd -Offset $gpsOffset -TagNames $script:ExifGpsTags -Prefix 'GPS:'
                }
            }
        }
    }
    catch {
        # A malformed/truncated EXIF blob shouldn't prevent the rest of the file's
        # metadata from being shown - return whatever was successfully parsed so far.
    }
    return $entries
}

# ---------------------------------------------------------------------------
# PNG
# ---------------------------------------------------------------------------

$script:PngSignature = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

# Only chunks that are load-bearing for correctly decoding pixels are kept. Everything else
# (tEXt/zTXt/iTXt - where AI tools stash "parameters"/"prompt"/"workflow" - eXIf, tIME,
# pHYs, gAMA, cHRM, sRGB, iCCP, hIST, sPLT, sBIT, bKGD, and any private/custom chunk such as
# C2PA's "caBX") is dropped unconditionally. This is a deliberate whitelist, not a blocklist
# of known-bad chunks, so it can't miss a vendor-specific chunk type it has never seen.
$script:PngKeepChunkTypes = @('IHDR', 'PLTE', 'IDAT', 'IEND', 'tRNS')

function Test-IsPng {
    param([byte[]]$Bytes)
    if ($Bytes.Length -lt 8) { return $false }
    for ($i = 0; $i -lt 8; $i++) { if ($Bytes[$i] -ne $script:PngSignature[$i]) { return $false } }
    return $true
}

function Get-PngChunks {
    <#
    .SYNOPSIS
        Walks a PNG's chunk stream and returns one object per chunk: its type, the offset/
        length of its data within Bytes, and the full chunk span (length+type+data+crc)
        needed to copy it through verbatim. Throws on truncated/malformed chunk headers.
    #>
    param([byte[]]$Bytes)
    $chunks = @()
    $pos = 8
    $len = $Bytes.Length
    while ($pos -lt $len) {
        if ($pos + 8 -gt $len) { throw "Truncated PNG chunk header at offset $pos." }
        $dataLen = Read-UInt32BE -Bytes $Bytes -Offset $pos
        $type = [System.Text.Encoding]::ASCII.GetString($Bytes, $pos + 4, 4)
        $chunkTotal = 8 + [int64]$dataLen + 4
        if ($pos + $chunkTotal -gt $len) { throw "Truncated PNG chunk '$type' at offset $pos." }
        $chunks += [pscustomobject]@{
            Type        = $type
            DataOffset  = $pos + 8
            DataLength  = [int]$dataLen
            ChunkStart  = $pos
            ChunkLength = [int]$chunkTotal
        }
        $pos += $chunkTotal
        if ($type -eq 'IEND') { break }
    }
    return $chunks
}

function Remove-PngMetadata {
    <#
    .SYNOPSIS
        Returns a new byte[] containing only the signature plus whitelisted chunks from
        the input PNG, in their original relative order (which already satisfies PNG's
        chunk-ordering rules, since it's a strict subset of a valid original stream).
    #>
    param([Parameter(Mandatory)][byte[]]$Bytes)
    if (-not (Test-IsPng $Bytes)) { throw 'Not a valid PNG file (bad signature).' }
    $chunks = Get-PngChunks -Bytes $Bytes

    $output = New-Object System.IO.MemoryStream
    $output.Write($script:PngSignature, 0, 8)
    foreach ($chunk in $chunks) {
        if ($script:PngKeepChunkTypes -contains $chunk.Type) {
            $output.Write($Bytes, $chunk.ChunkStart, $chunk.ChunkLength)
        }
    }
    return $output.ToArray()
}

function Get-PngMetadataReport {
    <#
    .SYNOPSIS
        Describes what metadata a PNG carries, for UI display before stripping. Never
        throws on a chunk it doesn't understand - unknown/private chunks are reported by
        their raw 4-char type.
    #>
    param([Parameter(Mandatory)][byte[]]$Bytes)
    if (-not (Test-IsPng $Bytes)) { throw 'Not a valid PNG file (bad signature).' }
    $chunks = Get-PngChunks -Bytes $Bytes
    $entries = @()
    foreach ($chunk in $chunks) {
        if ($script:PngKeepChunkTypes -contains $chunk.Type) { continue }
        switch ($chunk.Type) {
            { $_ -in @('tEXt', 'zTXt', 'iTXt') } {
                $keyword = Get-NullTerminatedLatin1 -Bytes $Bytes -Offset $chunk.DataOffset
                $isAi = Test-IsAiHint $keyword
                $entries += [pscustomobject]@{ Type = $chunk.Type; Label = "Text: $keyword"; IsAi = $isAi }
            }
            'eXIf' {
                $isAi = $false
                try {
                    $exifBytes = New-Object byte[] $chunk.DataLength
                    [Array]::Copy($Bytes, $chunk.DataOffset, $exifBytes, 0, $chunk.DataLength)
                    foreach ($tag in (Get-ExifEntries -Bytes $exifBytes)) {
                        if (Test-IsAiHint $tag.Value) { $isAi = $true; break }
                    }
                }
                catch { }
                $entries += [pscustomobject]@{ Type = $chunk.Type; Label = 'EXIF data'; IsAi = $isAi }
            }
            'tIME' { $entries += [pscustomobject]@{ Type = $chunk.Type; Label = 'Modification timestamp'; IsAi = $false } }
            'pHYs' { $entries += [pscustomobject]@{ Type = $chunk.Type; Label = 'Physical pixel dimensions'; IsAi = $false } }
            'iCCP' { $entries += [pscustomobject]@{ Type = $chunk.Type; Label = 'ICC color profile'; IsAi = $false } }
            { $_ -in @('gAMA', 'cHRM', 'sRGB', 'sBIT') } { $entries += [pscustomobject]@{ Type = $chunk.Type; Label = 'Color management data'; IsAi = $false } }
            'hIST' { $entries += [pscustomobject]@{ Type = $chunk.Type; Label = 'Palette histogram'; IsAi = $false } }
            'sPLT' { $entries += [pscustomobject]@{ Type = $chunk.Type; Label = 'Suggested palette'; IsAi = $false } }
            'bKGD' { $entries += [pscustomobject]@{ Type = $chunk.Type; Label = 'Background color'; IsAi = $false } }
            'caBX' { $entries += [pscustomobject]@{ Type = $chunk.Type; Label = 'C2PA content credentials'; IsAi = $true } }
            default { $entries += [pscustomobject]@{ Type = $chunk.Type; Label = "Custom chunk: $($chunk.Type)"; IsAi = (Test-IsAiHint $chunk.Type) } }
        }
    }
    return $entries
}

function Get-PngMetadataDetail {
    <#
    .SYNOPSIS
        Full, un-truncated view of every metadata chunk in a PNG - the complete text of
        each tEXt/zTXt/iTXt chunk (decompressing zTXt/iTXt as needed), every EXIF tag found
        in an eXIf chunk, and raw sizes for binary chunks (ICC profile, histogram, etc.).
        Meant for a "show me exactly what was in this file" UI, as opposed to
        Get-PngMetadataReport's short chip labels.
    #>
    param([Parameter(Mandatory)][byte[]]$Bytes)
    if (-not (Test-IsPng $Bytes)) { throw 'Not a valid PNG file (bad signature).' }
    $chunks = Get-PngChunks -Bytes $Bytes
    $entries = @()
    foreach ($chunk in $chunks) {
        if ($script:PngKeepChunkTypes -contains $chunk.Type) { continue }
        try {
            switch ($chunk.Type) {
                'tEXt' {
                    $keyword = Get-NullTerminatedLatin1 -Bytes $Bytes -Offset $chunk.DataOffset
                    $valueOffset = $chunk.DataOffset + $keyword.Length + 1
                    $valueLength = $chunk.DataOffset + $chunk.DataLength - $valueOffset
                    $value = if ($valueLength -gt 0) { [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($Bytes, $valueOffset, $valueLength) } else { '' }
                    $entries += [pscustomobject]@{ Key = $keyword; Value = $value }
                }
                'zTXt' {
                    $keyword = Get-NullTerminatedLatin1 -Bytes $Bytes -Offset $chunk.DataOffset
                    $compressedOffset = $chunk.DataOffset + $keyword.Length + 2  # +1 NUL, +1 compression method
                    $compressedLength = $chunk.DataOffset + $chunk.DataLength - $compressedOffset
                    $compressed = New-Object byte[] ([Math]::Max(0, $compressedLength))
                    if ($compressedLength -gt 0) { [Array]::Copy($Bytes, $compressedOffset, $compressed, 0, $compressedLength) }
                    $inflated = Expand-ZlibBytes -Bytes $compressed
                    $value = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($inflated)
                    $entries += [pscustomobject]@{ Key = $keyword; Value = $value }
                }
                'iTXt' {
                    $keyword = Get-NullTerminatedLatin1 -Bytes $Bytes -Offset $chunk.DataOffset
                    $p = $chunk.DataOffset + $keyword.Length + 1
                    $compressionFlag = $Bytes[$p]; $p++
                    $p++ # compression method (always 0/deflate when flag is set)
                    $langTag = Get-NullTerminatedLatin1 -Bytes $Bytes -Offset $p -MaxLength ($chunk.DataOffset + $chunk.DataLength - $p)
                    $p += $langTag.Length + 1
                    $translatedLen = 0
                    while ($p + $translatedLen -lt $chunk.DataOffset + $chunk.DataLength -and $Bytes[$p + $translatedLen] -ne 0) { $translatedLen++ }
                    $translatedKeyword = [System.Text.Encoding]::UTF8.GetString($Bytes, $p, $translatedLen)
                    $p += $translatedLen + 1
                    $textLength = $chunk.DataOffset + $chunk.DataLength - $p
                    $textBytes = New-Object byte[] ([Math]::Max(0, $textLength))
                    if ($textLength -gt 0) { [Array]::Copy($Bytes, $p, $textBytes, 0, $textLength) }
                    $value = if ($compressionFlag -eq 1) {
                        [System.Text.Encoding]::UTF8.GetString((Expand-ZlibBytes -Bytes $textBytes))
                    }
                    else {
                        [System.Text.Encoding]::UTF8.GetString($textBytes)
                    }
                    $displayKey = if ($translatedKeyword) { "$keyword ($translatedKeyword)" } else { $keyword }
                    $entries += [pscustomobject]@{ Key = $displayKey; Value = $value }
                }
                'eXIf' {
                    $exifBytes = New-Object byte[] $chunk.DataLength
                    [Array]::Copy($Bytes, $chunk.DataOffset, $exifBytes, 0, $chunk.DataLength)
                    $tags = Get-ExifEntries -Bytes $exifBytes
                    if ($tags.Count -eq 0) {
                        $entries += [pscustomobject]@{ Key = 'EXIF'; Value = "$($chunk.DataLength) byte(s), could not be parsed" }
                    }
                    else {
                        foreach ($tag in $tags) { $entries += [pscustomobject]@{ Key = "EXIF: $($tag.Name)"; Value = $tag.Value } }
                    }
                }
                'tIME' {
                    if ($chunk.DataLength -ge 7) {
                        $o = $chunk.DataOffset
                        $year = (Read-UInt16BE -Bytes $Bytes -Offset $o)
                        $value = '{0:D4}-{1:D2}-{2:D2} {3:D2}:{4:D2}:{5:D2} UTC' -f $year, $Bytes[$o + 2], $Bytes[$o + 3], $Bytes[$o + 4], $Bytes[$o + 5], $Bytes[$o + 6]
                        $entries += [pscustomobject]@{ Key = 'Last modified'; Value = $value }
                    }
                }
                default {
                    $entries += [pscustomobject]@{ Key = $chunk.Type; Value = "$($chunk.DataLength) byte(s) of binary data" }
                }
            }
        }
        catch {
            $entries += [pscustomobject]@{ Key = $chunk.Type; Value = "$($chunk.DataLength) byte(s), could not be parsed" }
        }
    }
    return Add-AiFlagToDetailEntries -Entries $entries
}

# ---------------------------------------------------------------------------
# JPEG
# ---------------------------------------------------------------------------

# Markers with no length field / payload - never appear as a length-prefixed segment.
$script:JpegStandaloneMarkers = @(0xD8, 0xD9, 0x01) + (0xD0..0xD7)

function Test-IsJpeg {
    param([byte[]]$Bytes)
    return ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xD8)
}

function Get-JpegAppSegmentDescription {
    <#
    .SYNOPSIS
        Best-effort human label for an APPn/COM segment's content, sniffed from its first
        bytes, for the metadata report. Never affects what gets stripped.
    #>
    param([byte]$Marker, [byte[]]$Bytes, [int]$DataOffset, [int]$DataLength)
    $preview = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($Bytes, $DataOffset, [Math]::Min($DataLength, 64))
    if ($Marker -eq 0xFE) {
        $isAi = Test-IsAiHint $preview
        return [pscustomobject]@{ Label = "Comment: $($preview.Trim())"; IsAi = $isAi }
    }
    if ($preview.StartsWith("Exif`0`0") -or $preview.StartsWith('Exif')) {
        # The raw preview bytes are binary TIFF, not text, so a hint match there is
        # unlikely - actually parse the tags (UserComment/ImageDescription/Software are
        # common places AI tools stash prompt data inside EXIF) to catch that case too.
        $isAi = $false
        try {
            $exifOffset = $DataOffset + 6
            $exifLength = $DataLength - 6
            if ($exifLength -gt 0) {
                $exifBytes = New-Object byte[] $exifLength
                [Array]::Copy($Bytes, $exifOffset, $exifBytes, 0, $exifLength)
                foreach ($tag in (Get-ExifEntries -Bytes $exifBytes)) {
                    if (Test-IsAiHint $tag.Value) { $isAi = $true; break }
                }
            }
        }
        catch { }
        return [pscustomobject]@{ Label = 'EXIF data'; IsAi = $isAi }
    }
    if ($preview.StartsWith('http://ns.adobe.com/xap/1.0/') -or $preview.Contains('<x:xmpmeta')) {
        $fullLen = [Math]::Min($DataLength, 8192)
        $full = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($Bytes, $DataOffset, $fullLen)
        return [pscustomobject]@{ Label = 'XMP metadata'; IsAi = (Test-IsAiHint $full) }
    }
    if ($preview.StartsWith('Photoshop 3.0') -or $Marker -eq 0xED) {
        return [pscustomobject]@{ Label = 'Photoshop / IPTC data'; IsAi = $false }
    }
    if ($Marker -eq 0xE0 -and $preview.StartsWith('JFIF')) {
        return [pscustomobject]@{ Label = 'JFIF header'; IsAi = $false }
    }
    if ($Marker -eq 0xEB) {
        return [pscustomobject]@{ Label = 'C2PA content credentials'; IsAi = $true }
    }
    if ($Marker -eq 0xE2 -and $preview.StartsWith('ICC_PROFILE')) {
        return [pscustomobject]@{ Label = 'ICC color profile'; IsAi = $false }
    }
    return [pscustomobject]@{ Label = ('APP{0} segment' -f ($Marker - 0xE0)); IsAi = (Test-IsAiHint $preview) }
}

function Get-JpegMetadataReport {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    if (-not (Test-IsJpeg $Bytes)) { throw 'Not a valid JPEG file (bad SOI marker).' }
    $entries = @()
    $len = $Bytes.Length
    $pos = 2
    while ($pos -lt $len - 1) {
        if ($Bytes[$pos] -ne 0xFF) { break }
        $marker = $Bytes[$pos + 1]
        if ($marker -eq 0xFF) { $pos++; continue }
        if ($marker -eq 0xD9) { break }
        $pos += 2
        if ($script:JpegStandaloneMarkers -contains $marker) { continue }
        if ($pos + 2 -gt $len) { break }
        $segLen = Read-UInt16BE -Bytes $Bytes -Offset $pos
        $dataOffset = $pos + 2
        $dataLength = $segLen - 2
        if ($dataLength -lt 0 -or $dataOffset + $dataLength -gt $len) { break }
        if (($marker -ge 0xE0 -and $marker -le 0xEF) -or $marker -eq 0xFE) {
            $desc = Get-JpegAppSegmentDescription -Marker $marker -Bytes $Bytes -DataOffset $dataOffset -DataLength $dataLength
            $entries += [pscustomobject]@{ Type = ('0x{0:X2}' -f $marker); Label = $desc.Label; IsAi = $desc.IsAi }
        }
        $pos += $segLen
        if ($marker -eq 0xDA) {
            # Skip entropy-coded scan data (handles byte-stuffed FF00 and RSTn markers) so
            # the walk resumes at the next real marker rather than misreading scan bytes.
            while ($pos -lt $len) {
                if ($Bytes[$pos] -eq 0xFF) {
                    $nxt = if ($pos + 1 -lt $len) { $Bytes[$pos + 1] } else { 0 }
                    if ($nxt -eq 0x00 -or ($nxt -ge 0xD0 -and $nxt -le 0xD7)) { $pos += 2; continue }
                    break
                }
                $pos++
            }
        }
    }
    return $entries
}

function Get-JpegMetadataDetail {
    <#
    .SYNOPSIS
        Full, un-truncated view of every APPn/COM segment in a JPEG - every EXIF tag, the
        complete XMP XML, the complete comment text, and raw sizes for binary segments
        (ICC profile, Photoshop/IPTC). Meant for a "show me exactly what was in this file"
        UI, as opposed to Get-JpegMetadataReport's short chip labels.
    #>
    param([Parameter(Mandatory)][byte[]]$Bytes)
    if (-not (Test-IsJpeg $Bytes)) { throw 'Not a valid JPEG file (bad SOI marker).' }
    $entries = @()
    $len = $Bytes.Length
    $pos = 2
    while ($pos -lt $len - 1) {
        if ($Bytes[$pos] -ne 0xFF) { break }
        $marker = $Bytes[$pos + 1]
        if ($marker -eq 0xFF) { $pos++; continue }
        if ($marker -eq 0xD9) { break }
        $pos += 2
        if ($script:JpegStandaloneMarkers -contains $marker) { continue }
        if ($pos + 2 -gt $len) { break }
        $segLen = Read-UInt16BE -Bytes $Bytes -Offset $pos
        $dataOffset = $pos + 2
        $dataLength = $segLen - 2
        if ($dataLength -lt 0 -or $dataOffset + $dataLength -gt $len) { break }

        if (($marker -ge 0xE0 -and $marker -le 0xEF) -or $marker -eq 0xFE) {
            try {
                $preview = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($Bytes, $dataOffset, [Math]::Min($dataLength, 32))
                if ($marker -eq 0xFE) {
                    $text = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString($Bytes, $dataOffset, $dataLength)
                    $entries += [pscustomobject]@{ Key = 'Comment'; Value = $text }
                }
                elseif ($preview.StartsWith("Exif`0`0")) {
                    $exifOffset = $dataOffset + 6
                    $exifLength = $dataLength - 6
                    if ($exifLength -gt 0) {
                        $exifBytes = New-Object byte[] $exifLength
                        [Array]::Copy($Bytes, $exifOffset, $exifBytes, 0, $exifLength)
                        $tags = Get-ExifEntries -Bytes $exifBytes
                        if ($tags.Count -eq 0) {
                            $entries += [pscustomobject]@{ Key = 'EXIF'; Value = "$exifLength byte(s), could not be parsed" }
                        }
                        else {
                            foreach ($tag in $tags) { $entries += [pscustomobject]@{ Key = "EXIF: $($tag.Name)"; Value = $tag.Value } }
                        }
                    }
                }
                elseif ($preview.StartsWith('http://ns.adobe.com/xap/1.0/')) {
                    $marker0 = [byte]0
                    $prefixLen = 0
                    while ($dataOffset + $prefixLen -lt $dataOffset + $dataLength -and $Bytes[$dataOffset + $prefixLen] -ne $marker0) { $prefixLen++ }
                    $prefixLen++ # include the NUL terminator
                    $xmlOffset = $dataOffset + $prefixLen
                    $xmlLength = $dataLength - $prefixLen
                    if ($xmlLength -gt 0) {
                        $xml = [System.Text.Encoding]::UTF8.GetString($Bytes, $xmlOffset, $xmlLength)
                        $entries += [pscustomobject]@{ Key = 'XMP'; Value = $xml }
                    }
                }
                elseif ($marker -eq 0xE0 -and $preview.StartsWith('JFIF')) {
                    $entries += [pscustomobject]@{ Key = 'JFIF header'; Value = "$dataLength byte(s)" }
                }
                elseif ($marker -eq 0xE2 -and $preview.StartsWith('ICC_PROFILE')) {
                    $entries += [pscustomobject]@{ Key = 'ICC color profile'; Value = "$dataLength byte(s) of binary data" }
                }
                elseif ($preview.StartsWith('Photoshop 3.0') -or $marker -eq 0xED) {
                    $entries += [pscustomobject]@{ Key = 'Photoshop / IPTC data'; Value = "$dataLength byte(s) of binary data" }
                }
                elseif ($marker -eq 0xEB) {
                    $entries += [pscustomobject]@{ Key = 'C2PA content credentials'; Value = "$dataLength byte(s) of binary data" }
                }
                else {
                    $entries += [pscustomobject]@{ Key = ('APP{0} segment' -f ($marker - 0xE0)); Value = "$dataLength byte(s) of binary data" }
                }
            }
            catch {
                $entries += [pscustomobject]@{ Key = ('0x{0:X2} segment' -f $marker); Value = "$dataLength byte(s), could not be parsed" }
            }
        }
        $pos += $segLen
        if ($marker -eq 0xDA) {
            while ($pos -lt $len) {
                if ($Bytes[$pos] -eq 0xFF) {
                    $nxt = if ($pos + 1 -lt $len) { $Bytes[$pos + 1] } else { 0 }
                    if ($nxt -eq 0x00 -or ($nxt -ge 0xD0 -and $nxt -le 0xD7)) { $pos += 2; continue }
                    break
                }
                $pos++
            }
        }
    }
    return Add-AiFlagToDetailEntries -Entries $entries
}

function Remove-JpegMetadata {
    <#
    .SYNOPSIS
        Returns a new byte[] with every APPn (APP0-APP15, incl. EXIF/XMP/ICC/C2PA/
        Photoshop-IPTC) and COM segment dropped. All other markers (SOF*, DHT, DQT, DRI,
        SOS + its entropy-coded scan data, EOI, restart markers) are copied through
        unchanged, so decoded pixels are bit-for-bit identical to the original.
    #>
    param([Parameter(Mandatory)][byte[]]$Bytes)
    if (-not (Test-IsJpeg $Bytes)) { throw 'Not a valid JPEG file (bad SOI marker).' }
    $len = $Bytes.Length
    $output = New-Object System.IO.MemoryStream
    $output.WriteByte(0xFF); $output.WriteByte(0xD8)
    $pos = 2
    while ($pos -lt $len) {
        if ($Bytes[$pos] -ne 0xFF) { throw "Malformed JPEG: expected marker at offset $pos." }
        $nxt = if ($pos + 1 -lt $len) { $Bytes[$pos + 1] } else { 0 }
        if ($nxt -eq 0xFF) { $pos++; continue }
        $marker = $nxt
        if ($marker -eq 0xD9) { $output.WriteByte(0xFF); $output.WriteByte(0xD9); $pos += 2; break }
        $pos += 2
        if ($script:JpegStandaloneMarkers -contains $marker) {
            $output.WriteByte(0xFF); $output.WriteByte($marker)
            continue
        }
        if ($pos + 2 -gt $len) { throw "Truncated JPEG segment at offset $pos." }
        $segLen = Read-UInt16BE -Bytes $Bytes -Offset $pos
        if ($pos + $segLen -gt $len) { throw "Truncated JPEG segment at offset $pos." }

        $drop = (($marker -ge 0xE0 -and $marker -le 0xEF) -or $marker -eq 0xFE)
        if (-not $drop) {
            $output.WriteByte(0xFF); $output.WriteByte($marker)
            $output.Write($Bytes, $pos, $segLen)
        }
        $pos += $segLen

        if ($marker -eq 0xDA) {
            $scanStart = $pos
            while ($pos -lt $len) {
                if ($Bytes[$pos] -eq 0xFF) {
                    $peek = if ($pos + 1 -lt $len) { $Bytes[$pos + 1] } else { 0 }
                    if ($peek -eq 0x00 -or ($peek -ge 0xD0 -and $peek -le 0xD7)) { $pos += 2; continue }
                    break
                }
                $pos++
            }
            if (-not $drop) {
                $output.Write($Bytes, $scanStart, $pos - $scanStart)
            }
        }
    }
    return $output.ToArray()
}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

function Get-ImageFormat {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    if (Test-IsPng $Bytes) { return 'png' }
    if (Test-IsJpeg $Bytes) { return 'jpeg' }
    return $null
}

function Remove-ImageMetadata {
    <#
    .SYNOPSIS
        Detects format from file content (not extension) and strips metadata accordingly.
        Throws for unsupported/unrecognized formats.
    #>
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $format = Get-ImageFormat -Bytes $Bytes
    switch ($format) {
        'png' { return Remove-PngMetadata -Bytes $Bytes }
        'jpeg' { return Remove-JpegMetadata -Bytes $Bytes }
        default { throw 'Unsupported image format - only PNG and JPEG are supported.' }
    }
}

# ---------------------------------------------------------------------------
# PNG -> JPEG conversion (opt-in - everything above this point is metadata-only
# and never touches pixel data; this is the one path that does, via GDI+)
# ---------------------------------------------------------------------------

function ConvertTo-JpegFromCleanPng {
    <#
    .SYNOPSIS
        Re-encodes an already-metadata-stripped PNG as a JPEG via GDI+ (System.Drawing) -
        the only path in this module that decodes/re-encodes pixels rather than doing a
        lossless byte-level strip, since JPEG conversion is inherently lossy and format
        translation, not something that can be done losslessly. Flattens onto a white
        background first, since JPEG has no alpha channel and GDI+'s JPEG encoder would
        otherwise drop transparency to solid black.

        Takes an already-cleaned PNG (not raw input) so callers control ordering
        explicitly - see Convert-PngToCleanJpeg for the "clean, then convert" pipeline
        actually used by the API.
    #>
    param([Parameter(Mandatory)][byte[]]$Bytes, [int]$Quality = 92)
    if (-not (Test-IsPng $Bytes)) { throw 'Not a valid PNG file (bad signature).' }

    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $inputStream = New-Object System.IO.MemoryStream(, $Bytes)
    try {
        $source = [System.Drawing.Image]::FromStream($inputStream)
        try {
            $flattened = New-Object System.Drawing.Bitmap($source.Width, $source.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
            try {
                $graphics = [System.Drawing.Graphics]::FromImage($flattened)
                try {
                    $graphics.Clear([System.Drawing.Color]::White)
                    $graphics.DrawImage($source, 0, 0, $source.Width, $source.Height)
                }
                finally { $graphics.Dispose() }

                $encoder = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
                if (-not $encoder) { throw 'No JPEG encoder is available on this system.' }
                $qualityParam = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [int64]$Quality)
                $encoderParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
                $encoderParams.Param[0] = $qualityParam

                $outputStream = New-Object System.IO.MemoryStream
                try {
                    $flattened.Save($outputStream, $encoder, $encoderParams)
                    return $outputStream.ToArray()
                }
                finally { $outputStream.Dispose() }
            }
            finally { $flattened.Dispose() }
        }
        finally { $source.Dispose() }
    }
    finally { $inputStream.Dispose() }
}

function Convert-PngToCleanJpeg {
    <#
    .SYNOPSIS
        The "clean, then convert" pipeline: strips the PNG's metadata losslessly first,
        converts the cleaned pixels to JPEG, then runs the JPEG stripper over GDI+'s
        output too - not because GDI+ is known to embed anything sensitive (its default
        encoder writes only a plain JFIF header), but so this path keeps the exact same
        zero-metadata guarantee as every other path through this module rather than being
        a silent exception to it.
    #>
    param([Parameter(Mandatory)][byte[]]$Bytes, [int]$Quality = 92)
    $cleanedPng = Remove-PngMetadata -Bytes $Bytes
    $jpeg = ConvertTo-JpegFromCleanPng -Bytes $cleanedPng -Quality $Quality
    return Remove-JpegMetadata -Bytes $jpeg
}

function Get-ImageMetadataReport {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $format = Get-ImageFormat -Bytes $Bytes
    switch ($format) {
        'png' { return Get-PngMetadataReport -Bytes $Bytes }
        'jpeg' { return Get-JpegMetadataReport -Bytes $Bytes }
        default { throw 'Unsupported image format - only PNG and JPEG are supported.' }
    }
}

function Get-ImageMetadataDetail {
    <#
    .SYNOPSIS
        Full, un-truncated {Key;Value} view of every metadata item in the file - see
        Get-PngMetadataDetail/Get-JpegMetadataDetail. Used for the "show full metadata"
        inspector view, as opposed to Get-ImageMetadataReport's short chip labels.
    #>
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $format = Get-ImageFormat -Bytes $Bytes
    switch ($format) {
        'png' { return Get-PngMetadataDetail -Bytes $Bytes }
        'jpeg' { return Get-JpegMetadataDetail -Bytes $Bytes }
        default { throw 'Unsupported image format - only PNG and JPEG are supported.' }
    }
}

Export-ModuleMember -Function `
    Test-IsPng, Get-PngChunks, Remove-PngMetadata, Get-PngMetadataReport, Get-PngMetadataDetail, `
    Test-IsJpeg, Get-JpegMetadataReport, Get-JpegMetadataDetail, Remove-JpegMetadata, `
    Get-ImageFormat, Remove-ImageMetadata, Get-ImageMetadataReport, Get-ImageMetadataDetail, `
    Get-ExifEntries, Expand-ZlibBytes, ConvertTo-JpegFromCleanPng, Convert-PngToCleanJpeg
