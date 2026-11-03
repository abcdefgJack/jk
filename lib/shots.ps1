# shots.ps1 - the Screenshots folder (Win+PrtScn, Snipping Tool): years of files in one folder.
#   jk shots                count and size per month, the newest numbered for jk find -o
#   jk shots file           move screenshots from before this month into YYYY-MM folders (jk tidy undo)
#   jk shots old            screenshots older than a year; -Months 6 to choose, -Recycle to bin them

$script:JkShotExt = @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic', '.mp4')

function Get-JkShotsPath {
    $cfg = Get-JkConfig 'shots.path'
    if ($cfg) { return [Environment]::ExpandEnvironmentVariables($cfg) }
    Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Screenshots'
}

# Every screenshot under the folder (month folders included), shaped like jk find's rows. The top
# level and each subfolder are listed on their own: a folder given as C:\Users\JACKWA~1\... lists
# its children under the long name, so cutting one path by the other's length goes wrong.
function Get-JkShots([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $root = Get-Item -LiteralPath $Path
    $row = { param($f, $folder, $loose) [pscustomobject]@{ Name = $f.Name; Folder = $folder; Size = $f.Length; Modified = $f.LastWriteTime; Path = $f.FullName; Loose = $loose; Item = $f } }
    $isShot = { param($f) $script:JkShotExt -contains $f.Extension.ToLower() }
    foreach ($f in @(Get-ChildItem -LiteralPath $root.FullName -File -Force -ErrorAction SilentlyContinue)) { if (& $isShot $f) { & $row $f $root.Name $true } }
    foreach ($d in @(Get-ChildItem -LiteralPath $root.FullName -Directory -Recurse -Force -ErrorAction SilentlyContinue)) {
        $rel = $d.FullName.Substring($root.FullName.TrimEnd('\').Length).TrimStart('\')
        foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -File -Force -ErrorAction SilentlyContinue)) { if (& $isShot $f) { & $row $f $rel $false } }
    }
}

function Show-JkShots {
    # jk shots 20: the newest 20 (a bare word is never taken for the folder)
    param([Parameter(Position = 0)][int]$Newest = 8, [string]$Path = (Get-JkShotsPath))
    $shots = @(Get-JkShots $Path)
    $total = ($shots | Measure-Object Size -Sum).Sum
    Write-JkHeader 'Screenshots' "$(Format-JkCount $shots.Count 'file') $($script:G.dot) $(Format-JkSize ([double]$total))" -Sub (Get-JkShortPath $Path)
    if (-not $shots.Count) { Say (Paint 'gray' "  none in $Path (jk config set shots.path <folder>)"); return }
    # the last twelve months, newest first
    $now = Get-Date
    $byMonth = @{}
    foreach ($s in $shots) { $k = $s.Modified.ToString('yyyy-MM', $script:Inv); $byMonth[$k] = [int]$byMonth[$k] + 1 }
    $months = @(for ($i = 0; $i -lt 12; $i++) { $now.AddMonths(-$i).ToString('yyyy-MM', $script:Inv) })
    $max = [Math]::Max(1, ($months | ForEach-Object { [int]$byMonth[$_] } | Measure-Object -Maximum).Maximum)
    foreach ($m in $months) {
        $n = [int]$byMonth[$m]
        Say ('  ' + (Paint 'muted' $m) + '  ' + (Get-JkBar ($n / $max) 30 'teal') + '  ' + (Paint 'white' "$n"))
    }
    $older = @($shots | Where-Object { $_.Modified -lt $now.AddMonths(-11).Date.AddDays(1 - $now.AddMonths(-11).Day) }).Count
    if ($older) { Say (Paint 'gray' "  + $older from before that") }
    Say ''
    Say (' ' + (Paint 'bold white' 'Newest'))
    $show = @($shots | Sort-Object Modified -Descending | Select-Object -First $Newest)
    Save-JkFindLast $show
    Write-JkFindRows $show -Ago
    $loose = @(Get-JkShotsToFile $shots $now).Count
    $old = @($shots | Where-Object { $_.Modified -lt $now.AddMonths(-12) })
    $tips = @("jk find -o 1 opens the newest")
    if ($loose) { $tips += "jk shots file sorts $loose older ones into month folders (jk tidy undo puts them back)" }
    if ($old.Count) { $tips += "jk shots old: $($old.Count) older than a year ($(Format-JkSize ([double](($old | Measure-Object Size -Sum).Sum))))" }
    foreach ($t in $tips) { Say (Paint 'gray' "  $t") }
}

# Loose screenshots from before this month: the ones jk shots file moves.
function Get-JkShotsToFile($Shots, [datetime]$Now) {
    $thisMonth = $Now.ToString('yyyy-MM', $script:Inv)
    @($Shots | Where-Object { $_.Loose -and $_.Modified.ToString('yyyy-MM', $script:Inv) -lt $thisMonth })
}

# Moves loose screenshots from before this month into YYYY-MM folders beside them. Logged the way
# jk tidy logs a batch, so jk tidy undo puts them back.
function Invoke-JkShotsFile {
    param([string]$Path = (Get-JkShotsPath))
    $todo = @(Get-JkShotsToFile @(Get-JkShots $Path) (Get-Date))
    if (-not $todo.Count) { Say (Paint 'green' "  Nothing to file: only this month's screenshots are loose. $($script:G.check)"); return }
    $log = New-Object System.Collections.Generic.List[object]
    $failed = 0
    foreach ($s in $todo) {
        $dir = Join-Path $Path ($s.Modified.ToString('yyyy-MM', $script:Inv))
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        try {
            $dest = Get-JkUniquePath $dir $s.Name
            Move-Item -LiteralPath $s.Path -Destination $dest -ErrorAction Stop
            $log.Add([pscustomobject]@{ from = $s.Path; to = $dest })
        } catch { $failed++ }
    }
    $dirLog = Get-JkPath 'tidy'
    if (-not (Test-Path $dirLog)) { New-Item -ItemType Directory -Path $dirLog | Out-Null }
    Save-JkJson "tidy\$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').json" ([pscustomobject]@{ root = $Path; at = (Get-Date).ToString('s'); moves = $log.ToArray() })
    $months = @($log | ForEach-Object { Split-Path (Split-Path $_.to -Parent) -Leaf } | Select-Object -Unique).Count
    Say ((Paint 'green' "  filed $(Format-JkCount $log.Count 'screenshot') into $(Format-JkCount $months 'month folder') $($script:G.check)") + (Paint 'gray' '  (jk tidy undo puts them back)'))
    if ($failed) { Say (Paint 'yellow' "  $failed could not be moved (open in another program?)") }
}

function Invoke-JkShotsOld {
    # jk shots old 6: older than six months
    param([Parameter(Position = 0)][int]$Months = 12, [string]$Path = (Get-JkShotsPath), [switch]$Recycle)
    $cut = (Get-Date).AddMonths(-$Months)
    $old = @(Get-JkShots $Path | Where-Object { $_.Modified -lt $cut } | Sort-Object Modified)
    $size = [double](($old | Measure-Object Size -Sum).Sum)
    Write-JkHeader 'Old screenshots' "$(Format-JkCount $old.Count 'file') $($script:G.dot) $(Format-JkSize $size)" -Sub "older than $(Format-JkCount $Months 'month') (before $($cut.ToString('MMM d yyyy', $script:Inv)))"
    if (-not $old.Count) { Say (Paint 'green' "  None. $($script:G.check)"); return }
    foreach ($g in ($old | Group-Object { $_.Modified.ToString('yyyy', $script:Inv) })) {
        Say ('  ' + (Paint 'white' $g.Name) + (Paint 'gray' "  $(Format-JkCount $g.Count 'file') $($script:G.dot) $(Format-JkSize ([double](($g.Group | Measure-Object Size -Sum).Sum)))"))
    }
    Say ''
    if ($Recycle) {
        $n = 0
        foreach ($s in $old) { try { Send-JkToRecycleBin $s.Path; $n++ } catch { } }
        Say ((Paint 'green' "  sent $n screenshots to the Recycle Bin $($script:G.check)") + (Paint 'gray' " $($script:G.dot) restore them from there if needed"))
    } else {
        Say (Paint 'gray' "  jk shots old -Recycle sends these to the Recycle Bin (recoverable); -Months 24 keeps two years instead")
    }
}

# ---------------------------------------------------------------- jk shots find: by the words in them

# Windows' own text recognition (Windows.Media.Ocr: printed text, in the OCR languages installed
# under Settings > Time & language), set up once per process.
function Initialize-JkOcr {
    if ($script:JkOcr) { return $script:JkOcr }
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
    $asTask = @([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    # one engine per language of yours that Windows can read (English and Chinese both, once the
    # Chinese one is installed); en-GB and en-US are one language here
    $available = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages)
    $engines = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($tag in @(Get-JkProfileLanguages)) {
        $prim = $tag.Split('-')[0].ToLower()
        if ($seen[$prim]) { continue }
        $l = @($available | Where-Object { $_.LanguageTag -ieq $tag })[0]
        if (-not $l) { $l = @($available | Where-Object { $_.LanguageTag.Split('-')[0] -ieq $prim })[0] }
        if ($l) { $e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($l); if ($e) { $engines.Add($e); $seen[$prim] = $true } }
    }
    if (-not $engines.Count -and $available.Count) { $engines.Add([Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($available[0])) }
    if (-not $engines.Count) { throw 'Windows has no text recognition language installed (Settings > Time & language > Language: a language with "Optical character recognition")' }
    $script:JkOcr = [pscustomobject]@{ Engines = $engines.ToArray(); Tags = (@($engines | ForEach-Object { $_.RecognizerLanguage.LanguageTag }) -join ','); AsTask = $asTask }
    $script:JkOcr
}

# Your languages, from Windows (Settings > Time & language > Language).
function Get-JkProfileLanguages {
    try { @((Get-ItemProperty 'HKCU:\Control Panel\International\User Profile' -ErrorAction Stop).Languages) } catch { @('en-US') }
}

# Languages of yours that Windows cannot read in pictures yet: "Chinese (Simplified, China)".
function Get-JkOcrMissing {
    $o = Initialize-JkOcr
    $have = @($o.Engines | ForEach-Object { $_.RecognizerLanguage.LanguageTag.Split('-')[0].ToLower() })
    @(foreach ($tag in @(Get-JkProfileLanguages)) {
            if ($have -contains $tag.Split('-')[0].ToLower()) { continue }
            try { [Globalization.CultureInfo]::GetCultureInfo($tag).EnglishName } catch { $tag }
        }) | Select-Object -Unique
}

function Wait-JkWinRt($Op, [Type]$Type) { $t = $script:JkOcr.AsTask.MakeGenericMethod($Type).Invoke($null, @($Op)); $null = $t.Wait(-1); $t.Result }

# The text in an image, on one line ('' when there is none or it cannot be read).
function Get-JkImageText([string]$Path) {
    $o = Initialize-JkOcr
    $file = Wait-JkWinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
    $stream = Wait-JkWinRt ($file.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
    try {
        $dec = Wait-JkWinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $max = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
        if ($dec.PixelWidth -gt $max -or $dec.PixelHeight -gt $max) { return '' }
        $bmp = Wait-JkWinRt ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $texts = foreach ($e in $o.Engines) { [string](Wait-JkWinRt ($e.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])).Text }
        [regex]::Replace((@($texts) -join ' '), '\s+', ' ').Trim()
    } finally { $stream.Dispose() }
}

# The index: a line per screenshot read, "name|size|time<TAB>text", in the cache. Keyed by name,
# size and time rather than path, so filing them into month folders keeps what was read.
function Get-JkShotsIndexPath { Join-Path (Get-JkCacheDir) 'shots-text.tsv' }
function Get-JkShotKey($Shot) { "$($Shot.Name)|$($Shot.Size)|$($Shot.Item.LastWriteTimeUtc.Ticks)" }

function Read-JkShotsIndex {
    $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $p = Get-JkShotsIndexPath
    if ([IO.File]::Exists($p)) {
        foreach ($l in [IO.File]::ReadAllLines($p, [Text.Encoding]::UTF8)) {
            $tab = $l.IndexOf("`t")
            if ($tab -gt 0) { $map[$l.Substring(0, $tab)] = $l.Substring($tab + 1) }
        }
    }
    , $map
}

# Reads screenshots not in the index yet, newest first, for up to $Seconds (videos aside).
# Returns how many are read and how many are left.
function Update-JkShotsIndex {
    param([double]$Seconds = 30, [switch]$Progress, [switch]$LowPriority, [string]$Path = (Get-JkShotsPath))
    if ($LowPriority) { try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { } }
    $p = Get-JkShotsIndexPath
    # read with other languages than last time (Chinese just installed): everything again
    $tagFile = "$p.langs"
    $tags = (Initialize-JkOcr).Tags
    $was = ''; try { if ([IO.File]::Exists($tagFile)) { $was = [IO.File]::ReadAllText($tagFile).Trim() } } catch { }
    if ($was -ne $tags) {
        if ($was -and [IO.File]::Exists($p)) { Remove-Item -LiteralPath $p -ErrorAction SilentlyContinue }
        Write-JkText $tagFile $tags
    }
    $shots = @(Get-JkShots $Path | Where-Object { $_.Item.Extension -match '^\.(png|jpe?g|bmp|gif)$' } | Sort-Object Modified -Descending)
    $idx = Read-JkShotsIndex
    $todo = @($shots | Where-Object { -not $idx.ContainsKey((Get-JkShotKey $_)) })
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    $batch = New-Object System.Collections.Generic.List[string]
    $n = 0
    $flush = { if ($batch.Count) { [IO.File]::AppendAllText($p, (($batch -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false)); $batch.Clear() } }
    try {
        foreach ($s in $todo) {
            if ([DateTime]::UtcNow -gt $deadline) { break }
            $text = ''
            try { $text = Get-JkImageText $s.Path } catch { if ($_.Exception.Message -match 'no text recognition') { throw } }
            $batch.Add((Get-JkShotKey $s) + "`t" + $text.Replace("`t", ' '))
            $n++
            # written as it goes: an interrupted run keeps what it read
            if ($batch.Count -ge 50) { & $flush }
            if ($Progress -and $n % 20 -eq 0) { Write-Progress -Activity 'jk shots: reading the text in screenshots' -Status "$n of $($todo.Count)" -PercentComplete ([int](100 * $n / [Math]::Max(1, $todo.Count))) }
        }
    } finally {
        & $flush
        if ($Progress) { Write-Progress -Activity 'jk shots: reading the text in screenshots' -Completed }
    }
    [pscustomobject]@{ Read = $shots.Count - ($todo.Count - $n); Total = $shots.Count; Left = $todo.Count - $n; Now = $n }
}

# The rest in a background process at low priority, one at a time, never in tests or the sandbox.
function Start-JkShotsIndexing {
    if ($env:JK_NOW -or $env:JK_NONINTERACTIVE -or $env:JK_SANDBOX) { return $false }
    $mark = Join-Path (Get-JkCacheDir) 'shots-index.running'
    try {
        if ([IO.File]::Exists($mark) -and ([DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($mark)).TotalMinutes -lt 30) { return $false }
        [IO.File]::WriteAllText($mark, '')
    } catch { return $false }
    $m = $mark.Replace("'", "''")
    $null = Start-JkBackground -Script "try { `$null = Update-JkShotsIndex -Seconds 1500 -LowPriority } finally { Remove-Item -LiteralPath '$m' -ErrorAction SilentlyContinue }"
    $true
}

function Invoke-JkShotsFind {
    [CmdletBinding(PositionalBinding = $false)]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Words, [switch]$All, [string]$Path = (Get-JkShotsPath))
    $terms = @($Words | Where-Object { $_ } | ForEach-Object { $_.Trim() })
    if (-not $terms.Count) { throw 'which words? jk shots find error message   (jk shots find "exact phrase" for one)' }
    $u = $null
    try { $u = Update-JkShotsIndex -Seconds 30 -Progress -Path $Path } catch { Say (Paint 'yellow' "  $($_.Exception.Message)") }
    $idx = Read-JkShotsIndex
    if (-not $u) {
        # nothing can be read here: search what an earlier read left
        $all = @(Get-JkShots $Path | Where-Object { $_.Item.Extension -match '^\.(png|jpe?g|bmp|gif)$' })
        $read = @($all | Where-Object { $idx.ContainsKey((Get-JkShotKey $_)) }).Count
        $u = [pscustomobject]@{ Read = $read; Total = $all.Count; Left = 0; Now = 0 }
    }
    $cmp = [StringComparison]::OrdinalIgnoreCase
    $hits = @(foreach ($s in @(Get-JkShots $Path)) {
            $t = $null
            if (-not $idx.TryGetValue((Get-JkShotKey $s), [ref]$t) -or -not $t) { continue }
            $ok = $true; foreach ($w in $terms) { if ($t.IndexOf($w, $cmp) -lt 0) { $ok = $false; break } }
            if ($ok) { $s | Add-Member -NotePropertyName Text -NotePropertyValue $t -PassThru }
        })
    $hits = @($hits | Sort-Object Modified -Descending)
    $max = $(if ($All) { 100 } else { 12 })
    $show = @($hits | Select-Object -First $max)
    Write-JkHeader 'Screenshots with' "$(Format-JkCount $hits.Count 'screenshot') $($script:G.dot) $($u.Read) of $($u.Total) read" -Sub (($terms | ForEach-Object { if ($_.Contains(' ')) { "`"$_`"" } else { $_ } }) -join ' ')
    if (-not $show.Count) { Say (Paint 'gray' '  None of the screenshots read so far has all of those words.') }
    else {
        Save-JkFindLast $show
        $w = Get-JkWidth
        $nameW = [int][Math]::Min(40, ($show | ForEach-Object { Get-JkTextWidth $_.Name } | Measure-Object -Maximum).Maximum)
        $n = 0
        foreach ($h in $show) {
            $n++
            $where = $(if ($h.Loose) { '' } else { $h.Folder })
            $when = $(if (((Get-Date) - $h.Modified).TotalDays -lt 2) { Format-JkRelTime $h.Modified } else { Format-JkFindDate $h.Modified (Get-Date) })
            Say ('  ' + (Paint 'gray' (Fit "$n" 3 -Right)) + '  ' + (Paint 'white' (Fit $h.Name $nameW)) + '  ' + (Paint 'muted' (Fit $when 14)) + (Paint 'gray' $where))
            # the words in their place, picked out
            $at = $h.Text.IndexOf($terms[0], $cmp); $from = [Math]::Max(0, $at - 30)
            $snip = $h.Text.Substring($from, [Math]::Min($h.Text.Length - $from, [Math]::Max(20, $w - 10)))
            if ($from -gt 0) { $snip = $script:G.ell + $snip.Substring(1) }
            foreach ($t in $terms) { $snip = [regex]::Replace($snip, [regex]::Escape($t), { param($m) Paint 'bold yellow' $m.Value }, 'IgnoreCase') }
            Say ('       ' + (Paint 'gray' $snip))
        }
        Say ''
        if ($hits.Count -gt $show.Count) { Say (Paint 'gray' "  +$($hits.Count - $show.Count) older: another word narrows it, -All lists them") }
        Say (Paint 'gray' "  jk find -o 1 opens one  $($script:G.dot)  jk find -e 1 shows it in Explorer")
    }
    if ($u.Left -gt 0) {
        $bg = Start-JkShotsIndexing
        Say (Paint 'gray' "  $($u.Left) older screenshots not read yet$(if ($bg) { ': reading them in the background now (a few minutes)' } else { ': run it again to read more' }); the morning task keeps new ones read")
    }
    Say (Paint 'gray' "  text read by Windows itself, kept on this PC only (jk shots forget deletes it)")
    $missing = @(); try { $missing = @(Get-JkOcrMissing) } catch { }
    foreach ($l in $missing) {
        Say (Paint 'yellow' "  $l text is not read yet: Windows has no $l text recognition installed")
        Write-JkTip '    ' 4 "Settings > Time & language > Language & region > $l > Language options > Optical character recognition: Download. jk reads them all again after." 'gray' -Indent 4
    }
}

function Invoke-JkShots {
    $a = @($args)
    if ($a.Count -eq 0) { Show-JkShots; return }
    $first = ([string]$a[0]).ToLower()
    $rest = @(); if ($a.Count -gt 1) { $rest = @($a[1..($a.Count - 1)]) }
    switch -Regex ($first) {
        '^(file|sort|apply)$' { Invoke-JkShotsFile @rest; return }
        '^(old|stale)$' { Invoke-JkShotsOld @rest; return }
        '^(find|search|text|grep)$' { Invoke-JkShotsFind @rest; return }
        '^(forget)$' {
            Remove-Item -LiteralPath (Get-JkShotsIndexPath), "$(Get-JkShotsIndexPath).langs" -ErrorAction SilentlyContinue
            Say (Paint 'green' "  the text read from your screenshots is deleted $($script:G.check)  (jk shots find reads it again)")
            return
        }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'shots'; return }
    }
    Show-JkShots @a
}
