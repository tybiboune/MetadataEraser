<#
.SYNOPSIS
    Pester tests for MetadataCore.psm1. Test fixtures are built in-memory (a real PNG/JPEG
    encoded via System.Drawing, then metadata chunks/segments spliced in by hand) rather
    than relying on external sample files or tools, so these tests are fully self-contained
    and don't depend on anything outside this repo.
#>

$srcDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
Import-Module (Join-Path $srcDir 'MetadataCore.psm1') -Force
. (Join-Path $PSScriptRoot 'Build-ExifFixture.ps1')

Add-Type -AssemblyName System.Drawing

function New-Crc32Table {
    $table = New-Object 'uint32[]' 256
    for ($n = 0; $n -lt 256; $n++) {
        [uint32]$c = $n
        for ($k = 0; $k -lt 8; $k++) {
            if (($c -band 1) -ne 0) { $c = 0xEDB88320 -bxor ($c -shr 1) } else { $c = $c -shr 1 }
        }
        $table[$n] = $c
    }
    return $table
}
$script:Crc32Table = New-Crc32Table

function Get-Crc32 {
    param([byte[]]$Bytes)
    [uint32]$crc = [uint32]::MaxValue
    foreach ($b in $Bytes) {
        $crc = $script:Crc32Table[($crc -bxor $b) -band 0xFF] -bxor ($crc -shr 8)
    }
    return $crc -bxor [uint32]::MaxValue
}

function Get-Uint32BEBytes {
    param([uint32]$Value)
    return [byte[]](
        (($Value -shr 24) -band 0xFF), (($Value -shr 16) -band 0xFF),
        (($Value -shr 8) -band 0xFF), ($Value -band 0xFF)
    )
}

function New-TestPng {
    <#
    .SYNOPSIS
        A tiny real PNG (encoded by .NET's own PNG encoder) with a tEXt "parameters" chunk
        (mimicking Stable Diffusion/AUTOMATIC1111 output) and a tIME chunk spliced in right
        before IEND.
    #>
    $bmp = New-Object System.Drawing.Bitmap 4, 4
    $bmp.SetPixel(0, 0, [System.Drawing.Color]::Red)
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $base = $ms.ToArray()

    # Split at IEND (last 12 bytes: 4-len + 'IEND' + 4-crc, len is always 0 for IEND).
    $iendStart = $base.Length - 12
    $head = $base[0..($iendStart - 1)]
    $iend = $base[$iendStart..($base.Length - 1)]

    $keyword = [System.Text.Encoding]::ASCII.GetBytes("parameters")
    $textValue = [System.Text.Encoding]::ASCII.GetBytes("a photo of a cat, Steps: 20, Sampler: Euler a")
    $chunkData = $keyword + [byte[]](0) + $textValue
    $typeBytes = [System.Text.Encoding]::ASCII.GetBytes("tEXt")
    $crc = Get-Crc32 -Bytes ($typeBytes + $chunkData)
    $tEXtChunk = (Get-Uint32BEBytes $chunkData.Length) + $typeBytes + $chunkData + (Get-Uint32BEBytes $crc)

    return $head + $tEXtChunk + $iend
}

function New-TestJpeg {
    <#
    .SYNOPSIS
        A tiny real JPEG (encoded by .NET's own JPEG encoder) with a COM segment containing
        AI-style prompt text spliced in right after SOI.
    #>
    $bmp = New-Object System.Drawing.Bitmap 4, 4
    $bmp.SetPixel(0, 0, [System.Drawing.Color]::Blue)
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $bmp.Dispose()
    $base = $ms.ToArray()

    $comment = [System.Text.Encoding]::ASCII.GetBytes("parameters: masterpiece, prompt: a cat")
    $segLen = $comment.Length + 2
    $comSegment = [byte[]](0xFF, 0xFE) + (Get-Uint32BEBytes $segLen)[2, 3] + $comment

    $soi = $base[0, 1]
    $rest = $base[2..($base.Length - 1)]
    return $soi + $comSegment + $rest
}

Describe "MetadataCore - PNG" {
    $png = New-TestPng

    It "detects PNG format" {
        (Get-ImageFormat -Bytes $png) | Should Be 'png'
    }

    It "reports the injected AI metadata before stripping" {
        $report = @(Get-PngMetadataReport -Bytes $png)
        $report.Count | Should BeGreaterThan 0
        @($report | Where-Object { $_.IsAi }).Count | Should BeGreaterThan 0
    }

    It "produces a PNG with zero metadata entries after stripping" {
        $cleaned = Remove-PngMetadata -Bytes $png
        $after = @(Get-PngMetadataReport -Bytes $cleaned)
        $after.Count | Should Be 0
    }

    It "keeps the cleaned output a structurally valid PNG (signature + IHDR + IEND)" {
        $cleaned = Remove-PngMetadata -Bytes $png
        (Test-IsPng $cleaned) | Should Be $true
        $chunks = Get-PngChunks -Bytes $cleaned
        $chunks[0].Type | Should Be 'IHDR'
        $chunks[-1].Type | Should Be 'IEND'
    }

    It "is idempotent (stripping an already-clean PNG changes nothing further)" {
        $cleaned = Remove-PngMetadata -Bytes $png
        $twice = Remove-PngMetadata -Bytes $cleaned
        [System.Convert]::ToBase64String($cleaned) | Should Be ([System.Convert]::ToBase64String($twice))
    }

    It "throws on a truncated/corrupt PNG" {
        $truncated = $png[0..($png.Length - 20)]
        { Remove-PngMetadata -Bytes $truncated } | Should Throw
    }
}

Describe "MetadataCore - JPEG" {
    $jpg = New-TestJpeg

    It "detects JPEG format" {
        (Get-ImageFormat -Bytes $jpg) | Should Be 'jpeg'
    }

    It "reports the injected AI metadata before stripping" {
        $report = @(Get-JpegMetadataReport -Bytes $jpg)
        $report.Count | Should BeGreaterThan 0
        @($report | Where-Object { $_.IsAi }).Count | Should BeGreaterThan 0
    }

    It "produces a JPEG with zero metadata entries after stripping" {
        $cleaned = Remove-JpegMetadata -Bytes $jpg
        $after = @(Get-JpegMetadataReport -Bytes $cleaned)
        $after.Count | Should Be 0
    }

    It "keeps the cleaned output a structurally valid JPEG (SOI...EOI)" {
        $cleaned = Remove-JpegMetadata -Bytes $jpg
        (Test-IsJpeg $cleaned) | Should Be $true
        $cleaned[0] | Should Be 0xFF
        $cleaned[1] | Should Be 0xD8
        $cleaned[-2] | Should Be 0xFF
        $cleaned[-1] | Should Be 0xD9
    }

    It "shrinks the file (metadata actually removed, not just relabeled)" {
        $cleaned = Remove-JpegMetadata -Bytes $jpg
        $cleaned.Length | Should BeLessThan $jpg.Length
    }
}

Describe "MetadataCore - dispatcher and error handling" {
    It "rejects a non-image byte array" {
        { Remove-ImageMetadata -Bytes ([byte[]](1, 2, 3, 4, 5, 6, 7, 8)) } | Should Throw
    }

    It "rejects a GIF (unsupported format)" {
        $gifHeader = [System.Text.Encoding]::ASCII.GetBytes("GIF89a") + [byte[]](0, 0, 0, 0, 0, 0)
        { Remove-ImageMetadata -Bytes $gifHeader } | Should Throw
    }

    It "dispatches PNG bytes to the PNG stripper via Remove-ImageMetadata" {
        $png = New-TestPng
        $cleaned = Remove-ImageMetadata -Bytes $png
        (Test-IsPng $cleaned) | Should Be $true
        (@(Get-ImageMetadataReport -Bytes $cleaned)).Count | Should Be 0
    }

    It "dispatches JPEG bytes to the JPEG stripper via Remove-ImageMetadata" {
        $jpg = New-TestJpeg
        $cleaned = Remove-ImageMetadata -Bytes $jpg
        (Test-IsJpeg $cleaned) | Should Be $true
        (@(Get-ImageMetadataReport -Bytes $cleaned)).Count | Should Be 0
    }
}

function ConvertTo-ZlibBytes {
    <#
    .SYNOPSIS
        Compresses Raw into RFC 1950 zlib format (2-byte header + deflate + Adler32
        trailer), the inverse of MetadataCore's Expand-ZlibBytes - used to build zTXt/iTXt
        fixtures with real compressed payloads.
    #>
    param([byte[]]$Raw)
    $comp = New-Object System.IO.MemoryStream
    $ds = New-Object System.IO.Compression.DeflateStream($comp, [System.IO.Compression.CompressionMode]::Compress, $true)
    $ds.Write($Raw, 0, $Raw.Length)
    $ds.Dispose()
    $compBytes = $comp.ToArray()
    [uint32]$a = 1; [uint32]$b = 0
    foreach ($byte in $Raw) { $a = ($a + $byte) % 65521; $b = ($b + $a) % 65521 }
    $adler = ($b -shl 16) -bor $a
    return [byte[]](0x78, 0x9C) + $compBytes + (Get-Uint32BEBytes ([uint32]$adler))
}

function New-TestPngWithFullMetadata {
    <#
    .SYNOPSIS
        A PNG carrying one of every kind of thing Get-PngMetadataDetail needs to handle:
        a plain tEXt chunk, a zlib-compressed zTXt chunk, an uncompressed iTXt chunk with a
        non-empty language/translated-keyword, and a real eXIf chunk (via the hand-built
        TIFF fixture) whose UserComment hides AI prompt text.
    #>
    $bmp = New-Object System.Drawing.Bitmap 4, 4
    $bmp.SetPixel(0, 0, [System.Drawing.Color]::Orange)
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $base = $ms.ToArray()
    $iendStart = $base.Length - 12
    $head = $base[0..($iendStart - 1)]
    $iend = $base[$iendStart..($base.Length - 1)]

    function New-Chunk {
        param([string]$Type, [byte[]]$Data)
        $typeBytes = [System.Text.Encoding]::ASCII.GetBytes($Type)
        $crc = Get-Crc32 -Bytes ($typeBytes + $Data)
        return (Get-Uint32BEBytes $Data.Length) + $typeBytes + $Data + (Get-Uint32BEBytes $crc)
    }

    $tExtData = [System.Text.Encoding]::ASCII.GetBytes("Title") + [byte[]](0) + [System.Text.Encoding]::ASCII.GetBytes("A plain text chunk")
    $tExtChunk = New-Chunk -Type 'tEXt' -Data $tExtData

    $zRaw = [System.Text.Encoding]::ASCII.GetBytes("workflow: a long ComfyUI graph, prompt: cyberpunk city at night")
    $zData = [System.Text.Encoding]::ASCII.GetBytes("Comment") + [byte[]](0, 0) + (ConvertTo-ZlibBytes -Raw $zRaw)
    $zChunk = New-Chunk -Type 'zTXt' -Data $zData

    $iRaw = [System.Text.Encoding]::UTF8.GetBytes("prompt: caf" + [char]0x00E9 + " scene " + [char]0x2764)
    $iData = [System.Text.Encoding]::ASCII.GetBytes("XML:com.adobe.xmp") + [byte[]](0, 0, 0, 0, 0) + $iRaw
    $iChunk = New-Chunk -Type 'iTXt' -Data $iData

    $exifChunk = New-Chunk -Type 'eXIf' -Data (New-ExifFixture)

    return $head + $tExtChunk + $zChunk + $iChunk + $exifChunk + $iend
}

function New-TestJpegWithFullMetadata {
    <#
    .SYNOPSIS
        A JPEG with a real APP1 Exif segment (built from the hand-built TIFF fixture,
        including a GPS sub-IFD and an AI-hint-bearing UserComment) plus a plain COM
        segment - covers everything Get-JpegMetadataDetail needs to handle.
    #>
    $bmp = New-Object System.Drawing.Bitmap 4, 4
    $bmp.SetPixel(0, 0, [System.Drawing.Color]::Teal)
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $bmp.Dispose()
    $base = $ms.ToArray()
    $soi = $base[0, 1]
    $rest = $base[2..($base.Length - 1)]

    $exifWithPrefix = [System.Text.Encoding]::ASCII.GetBytes("Exif") + [byte[]](0, 0) + (New-ExifFixture)
    $app1Len = $exifWithPrefix.Length + 2
    $app1Segment = [byte[]](0xFF, 0xE1) + (Get-Uint32BEBytes $app1Len)[2, 3] + $exifWithPrefix

    $comment = [System.Text.Encoding]::ASCII.GetBytes("plain comment, no AI hint here")
    $comLen = $comment.Length + 2
    $comSegment = [byte[]](0xFF, 0xFE) + (Get-Uint32BEBytes $comLen)[2, 3] + $comment

    return $soi + $app1Segment + $comSegment + $rest
}

Describe "MetadataCore - full metadata detail (PNG)" {
    $png = New-TestPngWithFullMetadata

    It "extracts the plain tEXt value verbatim" {
        $detail = @(Get-PngMetadataDetail -Bytes $png)
        ($detail | Where-Object { $_.Key -eq 'Title' }).Value | Should Be 'A plain text chunk'
    }

    It "decompresses a zTXt value correctly" {
        $detail = @(Get-PngMetadataDetail -Bytes $png)
        $entry = $detail | Where-Object { $_.Key -eq 'Comment' }
        $entry.Value | Should Be 'workflow: a long ComfyUI graph, prompt: cyberpunk city at night'
    }

    It "decodes an iTXt UTF-8 value (including multi-byte characters) correctly" {
        $detail = @(Get-PngMetadataDetail -Bytes $png)
        $entry = $detail | Where-Object { $_.Key -like 'XML:com.adobe.xmp*' }
        $entry.Value | Should Be ("prompt: caf" + [char]0x00E9 + " scene " + [char]0x2764)
    }

    It "parses the eXIf chunk into individual EXIF tags, including the AI prompt hidden in UserComment" {
        $detail = @(Get-PngMetadataDetail -Bytes $png)
        ($detail | Where-Object { $_.Key -eq 'EXIF: Make' }).Value | Should Be 'Canon'
        $userComment = $detail | Where-Object { $_.Key -eq 'EXIF: Exif:UserComment' }
        $userComment.Value | Should Match 'parameters: masterpiece'
    }

    It "flags the eXIf chunk as AI-related in the summary report because of its UserComment content" {
        $report = @(Get-PngMetadataReport -Bytes $png)
        $exifEntry = $report | Where-Object { $_.Type -eq 'eXIf' }
        $exifEntry.IsAi | Should Be $true
    }
}

Describe "MetadataCore - full metadata detail (JPEG)" {
    $jpg = New-TestJpegWithFullMetadata

    It "parses EXIF tags out of the APP1 segment, including GPS coordinates" {
        $detail = @(Get-JpegMetadataDetail -Bytes $jpg)
        ($detail | Where-Object { $_.Key -eq 'EXIF: Model' }).Value | Should Be 'EOS R5'
        ($detail | Where-Object { $_.Key -eq 'EXIF: GPS:GPSLatitudeRef' }).Value | Should Be 'N'
    }

    It "reveals the AI prompt hidden inside EXIF UserComment" {
        $detail = @(Get-JpegMetadataDetail -Bytes $jpg)
        $userComment = $detail | Where-Object { $_.Key -eq 'EXIF: Exif:UserComment' }
        $userComment.Value | Should Match 'parameters: masterpiece'
    }

    It "extracts the full COM comment text verbatim" {
        $detail = @(Get-JpegMetadataDetail -Bytes $jpg)
        ($detail | Where-Object { $_.Key -eq 'Comment' }).Value | Should Be 'plain comment, no AI hint here'
    }

    It "flags the EXIF entry as AI-related in the summary report because of UserComment, even though the comment itself has no hint" {
        $report = @(Get-JpegMetadataReport -Bytes $jpg)
        (($report | Where-Object { $_.Type -eq '0xE1' }).IsAi) | Should Be $true
        (($report | Where-Object { $_.Type -eq '0xFE' }).IsAi) | Should Be $false
    }

    It "still parses correctly and strips cleanly after a round trip through Get-ImageMetadataDetail's dispatcher" {
        $detail = @(Get-ImageMetadataDetail -Bytes $jpg)
        $detail.Count | Should BeGreaterThan 0
        $cleaned = Remove-JpegMetadata -Bytes $jpg
        (@(Get-JpegMetadataDetail -Bytes $cleaned)).Count | Should Be 0
    }
}

Describe "MetadataCore - EXIF/TIFF parser" {
    $exifBytes = New-ExifFixture

    It "parses IFD0 ASCII tags" {
        $entries = @(Get-ExifEntries -Bytes $exifBytes)
        (($entries | Where-Object { $_.Name -eq 'Make' }).Value) | Should Be 'Canon'
        (($entries | Where-Object { $_.Name -eq 'Software' }).Value) | Should Be 'AUTOMATIC1111'
    }

    It "parses the Exif sub-IFD and the UNDEFINED-type UserComment (stripping its ASCII character-code prefix)" {
        $entries = @(Get-ExifEntries -Bytes $exifBytes)
        $comment = $entries | Where-Object { $_.Name -eq 'Exif:UserComment' }
        $comment.Value | Should Match '^parameters: masterpiece'
        $comment.Value | Should Not Match 'ASCII'
    }

    It "parses the GPS sub-IFD RATIONAL triplets" {
        $entries = @(Get-ExifEntries -Bytes $exifBytes)
        $lat = $entries | Where-Object { $_.Name -eq 'GPS:GPSLatitude' }
        $lat.Value | Should Match '40/1'
        $lat.Value | Should Match '46.14'
    }

    It "returns an empty list rather than throwing on garbage input" {
        $garbage = [byte[]](1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
        { $entries = @(Get-ExifEntries -Bytes $garbage) } | Should Not Throw
        (@(Get-ExifEntries -Bytes $garbage)).Count | Should Be 0
    }
}

Describe "MetadataCore - Expand-ZlibBytes" {
    It "round-trips arbitrary bytes through compress/decompress" {
        $raw = [System.Text.Encoding]::UTF8.GetBytes("round trip test with some repeated repeated repeated text")
        $zlib = ConvertTo-ZlibBytes -Raw $raw
        $out = Expand-ZlibBytes -Bytes $zlib
        [System.Text.Encoding]::UTF8.GetString($out) | Should Be ([System.Text.Encoding]::UTF8.GetString($raw))
    }

    It "round-trips multi-byte UTF-8 characters correctly" {
        $raw = [System.Text.Encoding]::UTF8.GetBytes("caf" + [char]0x00E9 + " " + [char]0x2764)
        $zlib = ConvertTo-ZlibBytes -Raw $raw
        $out = Expand-ZlibBytes -Bytes $zlib
        [System.Text.Encoding]::UTF8.GetString($out) | Should Be ("caf" + [char]0x00E9 + " " + [char]0x2764)
    }
}
