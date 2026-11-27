# pdf.ps1 - photos of handwritten work (and PDFs) into one PDF, the way LEARN dropboxes and Crowdmark
# want it.
#   jk pdf *.jpg                       every photo upright, one per page (Letter), into <folder>.pdf
#   jk pdf p1.jpg p2.png notes.pdf -Out a3.pdf      images and PDFs, in that order
#   -A4 for A4 pages, -Small to shrink photos for upload limits
# Images are written by jk itself (each re-encoded as an RGB JPEG, turned by its EXIF orientation).
# Merging existing PDFs uses pypdf (Python) or pdfunite when present.

$script:JkImageExt = @('.jpg', '.jpeg', '.png', '.bmp', '.gif', '.tif', '.tiff')

# EXIF orientation (tag 0x0112) -> the RotateFlip that makes a phone photo upright.
function Get-JkRotateFlip([int]$Orientation) {
    switch ($Orientation) {
        2 { 'RotateNoneFlipX' } 3 { 'Rotate180FlipNone' } 4 { 'Rotate180FlipX' } 5 { 'Rotate90FlipX' }
        6 { 'Rotate90FlipNone' } 7 { 'Rotate270FlipX' } 8 { 'Rotate270FlipNone' } default { 'RotateNoneFlipNone' }
    }
}

# An image file as JPEG bytes, upright, RGB, at most $MaxSide pixels on its longer side (0 = as is).
function ConvertTo-JkJpegBytes([string]$Path, [int]$MaxSide = 0, [int]$Quality = 90) {
    Add-Type -AssemblyName System.Drawing
    # Windows reports a picture it cannot read (cut short, or not what its name says) as "Out of memory"
    try { $img = [Drawing.Image]::FromFile($Path) } catch { throw "can't read $(Split-Path $Path -Leaf) as a picture: it is damaged, or not the kind of file its name says" }
    try {
        $o = 1
        if ($img.PropertyIdList -contains 0x0112) { $o = [int]([BitConverter]::ToUInt16($img.GetPropertyItem(0x0112).Value, 0)) }
        $img.RotateFlip([Drawing.RotateFlipType](Get-JkRotateFlip $o))
        $w = $img.Width; $h = $img.Height
        if ($MaxSide -gt 0 -and [Math]::Max($w, $h) -gt $MaxSide) {
            $s = $MaxSide / [double][Math]::Max($w, $h); $w = [int][Math]::Round($w * $s); $h = [int][Math]::Round($h * $s)
        }
        # drawn onto a white RGB canvas: transparency, palettes and CMYK all come out plain RGB
        $bmp = New-Object Drawing.Bitmap $w, $h, ([Drawing.Imaging.PixelFormat]::Format24bppRgb)
        try {
            $g = [Drawing.Graphics]::FromImage($bmp)
            try { $g.Clear([Drawing.Color]::White); $g.InterpolationMode = 'HighQualityBicubic'; $g.DrawImage($img, 0, 0, $w, $h) } finally { $g.Dispose() }
            $codec = @([Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' })[0]
            $ep = New-Object Drawing.Imaging.EncoderParameters 1
            $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality, [long]$Quality)
            $ms = New-Object IO.MemoryStream
            $bmp.Save($ms, $codec, $ep)
            [pscustomobject]@{ Bytes = $ms.ToArray(); Width = $w; Height = $h }
        } finally { $bmp.Dispose() }
    } finally { $img.Dispose() }
}

# A PDF with one page per image, each fitted inside the page with a small margin, landscape pages for
# landscape images.
function New-JkPdfFromImages($Images, [string]$Out, [switch]$A4) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $pw = 612.0; $ph = 792.0; if ($A4) { $pw = 595.28; $ph = 841.89 }
    $margin = 18.0
    $fs = [IO.File]::Create($Out)
    try {
        # every write goes through here, so the byte offsets the xref table needs are counted as we go
        $w = { param([byte[]]$b) $fs.Write($b, 0, $b.Length); $script:JkPdfPos += $b.Length }
        $script:JkPdfPos = 0
        $txt = { param([string]$s) & $w ([Text.Encoding]::ASCII.GetBytes($s)) }
        $offsets = @{}
        $n = @($Images).Count
        # the header, then the binary-marker comment readers use to treat the file as binary
        & $w ([byte[]](0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A, 0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A))
        $kids = @(for ($i = 0; $i -lt $n; $i++) { "$(3 + 3 * $i) 0 R" }) -join ' '
        $offsets[1] = $script:JkPdfPos; & $txt "1 0 obj`n<< /Type /Catalog /Pages 2 0 R >>`nendobj`n"
        $offsets[2] = $script:JkPdfPos; & $txt "2 0 obj`n<< /Type /Pages /Kids [$kids] /Count $n >>`nendobj`n"
        for ($i = 0; $i -lt $n; $i++) {
            $im = @($Images)[$i]
            $pageW = $pw; $pageH = $ph
            if ($im.Width -gt $im.Height) { $pageW = $ph; $pageH = $pw }
            $scale = [Math]::Min(($pageW - 2 * $margin) / $im.Width, ($pageH - 2 * $margin) / $im.Height)
            $dw = $im.Width * $scale; $dh = $im.Height * $scale
            $x = ($pageW - $dw) / 2; $y = ($pageH - $dh) / 2
            $page = 3 + 3 * $i; $content = $page + 1; $image = $page + 2
            $f = { param($v) ([double]$v).ToString('0.###', $inv) }
            $offsets[$page] = $script:JkPdfPos
            & $txt "$page 0 obj`n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $(& $f $pageW) $(& $f $pageH)] /Resources << /XObject << /Im0 $image 0 R >> >> /Contents $content 0 R >>`nendobj`n"
            $draw = "q $(& $f $dw) 0 0 $(& $f $dh) $(& $f $x) $(& $f $y) cm /Im0 Do Q"
            $offsets[$content] = $script:JkPdfPos
            & $txt "$content 0 obj`n<< /Length $($draw.Length) >>`nstream`n$draw`nendstream`nendobj`n"
            $offsets[$image] = $script:JkPdfPos
            & $txt "$image 0 obj`n<< /Type /XObject /Subtype /Image /Width $($im.Width) /Height $($im.Height) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length $($im.Bytes.Length) >>`nstream`n"
            & $w $im.Bytes
            & $txt "`nendstream`nendobj`n"
        }
        $count = 3 + 3 * $n
        $xref = $script:JkPdfPos
        $sb = New-Object Text.StringBuilder
        [void]$sb.Append("xref`n0 $count`n0000000000 65535 f `n")
        for ($k = 1; $k -lt $count; $k++) { [void]$sb.Append(('{0:D10} 00000 n ' -f $offsets[$k]) + "`n") }
        [void]$sb.Append("trailer`n<< /Size $count /Root 1 0 R >>`nstartxref`n$xref`n%%EOF`n")
        & $txt $sb.ToString()
    } finally { $fs.Dispose() }
}

# Existing PDFs (and the images' PDF) into one: pypdf through Python, else pdfunite.
function Join-JkPdfFiles([string[]]$Pdfs, [string]$Out) {
    $py = Get-Command python -ErrorAction SilentlyContinue
    if ($py) {
        $script = 'import sys' + "`n" + 'from pypdf import PdfWriter' + "`n" + 'w = PdfWriter()' + "`n" + 'for p in sys.argv[2:]: w.append(p)' + "`n" + 'w.write(sys.argv[1])'
        $res = Invoke-JkProcess -Exe $py.Source -ArgList (@('-c', $script, $Out) + $Pdfs) -InputText '' -TimeoutMs 120000 -WorkDir (Split-Path $Out -Parent)
        if ($res.Code -eq 0 -and (Test-Path -LiteralPath $Out)) { return 'pypdf' }
    }
    $pu = Get-Command pdfunite -ErrorAction SilentlyContinue
    if ($pu) {
        $res = Invoke-JkProcess -Exe $pu.Source -ArgList (@($Pdfs) + $Out) -InputText '' -TimeoutMs 120000 -WorkDir (Split-Path $Out -Parent)
        if ($res.Code -eq 0 -and (Test-Path -LiteralPath $Out)) { return 'pdfunite' }
    }
    throw 'merging PDFs needs pypdf (python -m pip install pypdf) or pdfunite (poppler); images alone need neither'
}

# "*.jpg" and friends, expanded here (PowerShell hands a function the pattern as typed), in natural
# order so IMG_2 comes before IMG_10.
function Resolve-JkPdfInputs([string[]]$Items) {
    foreach ($it in @($Items | Where-Object { $_ })) {
        # a name that exists as typed is that file, even with brackets in it ("page[1].png") or in
        # the folder it is in; only then is it a pattern
        $full = Get-JkFullPath $it
        if ([IO.File]::Exists($full)) { $full; continue }
        if (-not [Management.Automation.WildcardPattern]::ContainsWildcardCharacters($it)) { throw "no such file: $it" }
        $dir = Split-Path $full -Parent
        $where = $(if (Test-Path -LiteralPath $dir) { @{ LiteralPath = $dir } } else { @{ Path = $dir } })
        @(Get-ChildItem @where -Filter (Split-Path $full -Leaf) -File -ErrorAction SilentlyContinue | Sort-Object { Get-JkNaturalKey $_.Name }) | ForEach-Object { $_.FullName }
    }
}

function Invoke-JkPdf {
    # every word that is not an option is a file: without this, "jk pdf *.jpg *.png" would bind *.png to -Out
    [CmdletBinding(PositionalBinding = $false)]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Files, [string]$Out, [switch]$A4, [switch]$Small, [switch]$Force)
    if (-not @($Files | Where-Object { $_ }).Count -or $Files[0] -match '^(?i)(help|-h|--help|\?)$') { Show-JkHelp 'pdf'; return }
    $inputs = @(Resolve-JkPdfInputs $Files)
    # an iPhone's own photo format, which Windows' picture reader cannot open
    $heic = @($inputs | Where-Object { [IO.Path]::GetExtension($_) -match '^(?i)\.(heic|heif)$' })
    if ($heic.Count) { throw "$(Split-Path $heic[0] -Leaf)$(if ($heic.Count -gt 1) { " and $($heic.Count - 1) more are" } else { ' is' }) HEIC, which jk cannot read: send the photos as JPEG (on the iPhone: Settings > Camera > Formats > Most Compatible), or open them in Photos and save a copy as .jpg" }
    $inputs = @($inputs | Where-Object { $script:JkImageExt -contains [IO.Path]::GetExtension($_).ToLower() -or [IO.Path]::GetExtension($_).ToLower() -eq '.pdf' })
    if (-not $inputs.Count) { throw 'no images or PDFs among those files (jpg, png, bmp, gif, tif, pdf)' }
    $here = (Get-Location).ProviderPath
    if (-not $Out) { $Out = (Split-Path $here -Leaf) + '.pdf' }
    if ($Out -notmatch '(?i)\.pdf$') { $Out += '.pdf' }
    if (-not [IO.Path]::IsPathRooted($Out)) { $Out = Join-Path $here $Out }
    if ((Test-Path -LiteralPath $Out) -and -not $Force) { $Out = Get-JkUniquePath (Split-Path $Out -Parent) (Split-Path $Out -Leaf) }
    if ($inputs -contains $Out) { throw "the output would overwrite an input: -Out another name" }
    $max = 0; $q = 90; if ($Small) { $max = 1700; $q = 72 }
    # runs of images become one PDF each, in place, so images and PDFs keep the order given
    $parts = New-Object System.Collections.Generic.List[object]
    $run = @()
    $flush = { if ($run.Count) { $parts.Add(@{ Images = $run }); Set-Variable -Name run -Value @() -Scope 1 } }
    foreach ($f in $inputs) {
        if ([IO.Path]::GetExtension($f).ToLower() -eq '.pdf') { & $flush; $parts.Add(@{ Pdf = $f }) }
        else { $run += $f }
    }
    & $flush
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $tmp = @()
    try {
        if ($parts.Count -eq 1 -and $parts[0].Images) {
            New-JkPdfFromImages @($parts[0].Images | ForEach-Object { ConvertTo-JkJpegBytes $_ $max $q }) $Out -A4:$A4
            $how = 'jk'
        } else {
            $pdfs = foreach ($p in $parts) {
                if ($p.Pdf) { $p.Pdf; continue }
                $t = Join-Path $env:TEMP ('jk-pdf-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.pdf')
                New-JkPdfFromImages @($p.Images | ForEach-Object { ConvertTo-JkJpegBytes $_ $max $q }) $t -A4:$A4
                $tmp += $t; $t
            }
            $how = Join-JkPdfFiles @($pdfs) $Out
        }
    } finally { foreach ($t in $tmp) { Remove-Item -LiteralPath $t -ErrorAction SilentlyContinue } }
    $size = (Get-Item -LiteralPath $Out).Length
    $imgs = @($inputs | Where-Object { [IO.Path]::GetExtension($_).ToLower() -ne '.pdf' }).Count
    $what = @(); if ($imgs) { $what += Format-JkCount $imgs 'image' }; if ($inputs.Count - $imgs) { $what += Format-JkCount ($inputs.Count - $imgs) 'PDF' }
    Say ((Paint 'green' "  wrote $($script:G.check)") + "  $(Resolve-JkLongPath $Out)" + (Paint 'gray' "  $($what -join ' + ') $($script:G.dot) $(Format-JkSize $size) $($script:G.dot) $([Math]::Round($sw.Elapsed.TotalSeconds, 1)) s$(if ($how -ne 'jk') { " (merged with $how)" })"))
    if ($size -gt 20MB -and -not $Small) { Say (Paint 'gray' '  large for an upload: -Small shrinks the photos') }
}
