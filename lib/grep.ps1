# grep.ps1 - jk grep: words inside your course files (lecture PDFs page by page, slides, notes,
# notebooks, code) with the page and a snippet.   jk grep cs370 condition number  |  jk grep lu decomposition
# PDF text comes from pdftotext (MiKTeX, Git, poppler) or else pypdf, and is kept in the cache by
# file size and time, so each file is read once. Handwritten or scanned PDFs have no text to find.

$script:JkGrepTextRx = '^\.(txt|md|tex|py|c|cc|cpp|h|hpp|java|js|ts|r|m|jl|ml|rkt|sql|csv|html?)$'
$script:JkGrepSkipDir = '^(\.git|\.vscode|\.idea|node_modules|__pycache__|site-packages|mpl-data|venv|\.venv|env|build|dist|target|bin|obj|\.ipynb_checkpoints)$'

# ---------------------------------------------------------------- files and their text

function Get-JkGrepFiles([string[]]$Folders) {
    $out = New-Object System.Collections.Generic.List[IO.FileInfo]
    $hidden = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System
    foreach ($f in $Folders) {
        if (-not $f -or -not [IO.Directory]::Exists($f)) { continue }
        $stack = New-Object System.Collections.Generic.Stack[IO.DirectoryInfo]
        $stack.Push((New-Object IO.DirectoryInfo $f))
        while ($stack.Count) {
            $d = $stack.Pop()
            try {
                foreach ($i in $d.EnumerateFileSystemInfos()) {
                    if ($i.Attributes -band $hidden) { continue }
                    if ($i -is [IO.DirectoryInfo]) {
                        if ($i.Name -notmatch $script:JkGrepSkipDir -and -not ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($i) }
                        continue
                    }
                    $x = $i.Extension.ToLowerInvariant()
                    if ($i.Name.StartsWith('~$')) { continue }
                    if ($x -in '.pdf', '.pptx', '.docx', '.ipynb' -or ($x -match $script:JkGrepTextRx -and $i.Length -le 2MB)) { $out.Add($i) }
                }
            } catch { }
        }
    }
    $out.ToArray()
}

function Get-JkTextCachePath([string]$Path) {
    $sha = [Security.Cryptography.SHA1]::Create()
    try { $h = -join @($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())) | Select-Object -First 10 | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
    Join-Path (Join-Path (Get-JkCacheDir) 'text') "$h.txt"
}

# v1: pages kept already folded by ConvertTo-JkSearchText
function Get-JkTextStamp([IO.FileInfo]$F) { "v1|$($F.Length)|$($F.LastWriteTimeUtc.Ticks)" }

function Read-JkTextCache([IO.FileInfo]$F) {
    $p = Get-JkTextCachePath $F.FullName
    if (-not [IO.File]::Exists($p)) { return $null }
    $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
    $nl = $t.IndexOf("`n")
    if ($nl -lt 0 -or $t.Substring(0, $nl) -ne (Get-JkTextStamp $F)) { return $null }
    $t.Substring($nl + 1)
}

# $Text is pages ending in form feeds, as pdftotext writes them; each is kept folded for search.
function Save-JkTextCache([IO.FileInfo]$F, [string]$Text) {
    $p = Get-JkTextCachePath $F.FullName
    $dir = Split-Path $p
    if (-not [IO.Directory]::Exists($dir)) { $null = [IO.Directory]::CreateDirectory($dir) }
    $pages = ''
    if ($Text.Trim()) { $pages = (@($Text.TrimEnd([char]12).Split([char]12) | ForEach-Object { ConvertTo-JkSearchText $_ }) -join "`f") + "`f" }
    Write-JkText $p ((Get-JkTextStamp $F) + "`n" + $pages)
}

function Find-JkPdfToText {
    $c = Get-Command pdftotext -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($p in "$env:LOCALAPPDATA\Programs\MiKTeX\miktex\bin\x64\pdftotext.exe", "$env:ProgramFiles\MiKTeX\miktex\bin\x64\pdftotext.exe", "$env:ProgramFiles\Git\mingw64\bin\pdftotext.exe") {
        if ([IO.File]::Exists($p)) { return $p }
    }
    $null
}

# The PDFs not in the cache yet, read six pdftotext at a time (each takes about a third of a
# second); without pdftotext, one Python process reads them all with pypdf. A file that cannot be
# read is kept as empty, so it is not tried again until it changes.
function Update-JkPdfTexts([IO.FileInfo[]]$Files) {
    if (-not $Files.Count) { return }
    $dir = Join-Path (Get-JkCacheDir) 'text'
    if (-not [IO.Directory]::Exists($dir)) { $null = [IO.Directory]::CreateDirectory($dir) }
    $exe = Find-JkPdfToText
    if ($exe) {
        $queue = New-Object 'System.Collections.Generic.Queue[object]'
        foreach ($f in $Files) { $queue.Enqueue($f) }
        $running = New-Object 'System.Collections.Generic.List[object]'
        while ($queue.Count -or $running.Count) {
            while ($queue.Count -and $running.Count -lt 6) {
                $f = $queue.Dequeue()
                $out = Join-Path $dir ([guid]::NewGuid().ToString('N') + '.part')
                $psi = New-Object Diagnostics.ProcessStartInfo $exe, ('-q -enc UTF-8 "' + $f.FullName + '" "' + $out + '"')
                $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
                try { $running.Add([pscustomobject]@{ P = [Diagnostics.Process]::Start($psi); F = $f; Out = $out; At = [DateTime]::UtcNow }) }
                catch { Save-JkTextCache $f '' }
            }
            foreach ($r in $running.ToArray()) {
                $done = $r.P.HasExited
                if (-not $done -and ([DateTime]::UtcNow - $r.At).TotalSeconds -gt 60) { try { $r.P.Kill() } catch { }; $done = $true }
                if (-not $done) { continue }
                $text = ''
                try { if ([IO.File]::Exists($r.Out)) { $text = [IO.File]::ReadAllText($r.Out, [Text.Encoding]::UTF8); [IO.File]::Delete($r.Out) } } catch { }
                Save-JkTextCache $r.F $text
                $r.P.Dispose()
                $null = $running.Remove($r)
            }
            if ($running.Count) { Start-Sleep -Milliseconds 25 }
        }
        return
    }
    $py = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $py) { foreach ($f in $Files) { Save-JkTextCache $f '' }; return }
    $list = Join-Path $dir 'pypdf-list.txt'
    $script = Join-Path $dir 'pypdf-read.py'
    $pairs = @(foreach ($f in $Files) { $f.FullName + "`t" + (Join-Path $dir ([guid]::NewGuid().ToString('N') + '.part')) })
    [IO.File]::WriteAllLines($list, $pairs, (New-Object Text.UTF8Encoding $false))
    Write-JkText $script @'
import sys
try:
    import pypdf
except Exception:
    sys.exit(0)
for line in open(sys.argv[1], encoding='utf-8'):
    src, dst = line.rstrip('\n').split('\t')
    try:
        pages = [p.extract_text() or '' for p in pypdf.PdfReader(src).pages]
        text = '\f'.join(pages) + ('\f' if pages else '')
    except Exception:
        text = ''
    open(dst, 'w', encoding='utf-8').write(text)
'@
    # -P: nothing from the working or script folder is importable
    try { $null = & $py.Source -P $script $list 2>$null } catch { }
    for ($i = 0; $i -lt $Files.Count; $i++) {
        $out = $pairs[$i].Split("`t")[1]
        $text = ''
        try { if ([IO.File]::Exists($out)) { $text = [IO.File]::ReadAllText($out, [Text.Encoding]::UTF8); [IO.File]::Delete($out) } } catch { }
        Save-JkTextCache $Files[$i] $text
    }
}

# Slides of a .pptx (a page each) or the paragraphs of a .docx (one page), from the XML inside.
function Get-JkOfficeText([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $read = { param($e) $sr = New-Object IO.StreamReader ($e.Open()); try { $sr.ReadToEnd() } finally { $sr.Dispose() } }
        if ($Path -match '(?i)\.pptx$') {
            $slides = @($z.Entries | Where-Object { $_.FullName -match '^ppt/slides/slide(\d+)\.xml$' } | Sort-Object { [int]([regex]::Match($_.FullName, '(\d+)\.xml$').Groups[1].Value) })
            $pages = foreach ($s in $slides) { (@([regex]::Matches((& $read $s), '<a:t>([^<]*)</a:t>') | ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) }) -join ' ') }
            return ((@($pages) -join "`f") + "`f")
        }
        $doc = @($z.Entries | Where-Object { $_.FullName -eq 'word/document.xml' })[0]
        if (-not $doc) { return '' }
        $x = (& $read $doc) -replace '</w:p>', "`n"
        (@([regex]::Matches($x, '<w:t(?:\s[^>]*)?>([^<]*)</w:t>|\n') | ForEach-Object { if ($_.Value -eq "`n") { "`n" } else { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) } }) -join '') + "`f"
    } finally { $z.Dispose() }
}

# A notebook's cells, a "page" each.
function Get-JkNotebookText([string]$Path) {
    $nb = ConvertFrom-Json ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8))
    (@(foreach ($c in @($nb.cells)) { (@($c.source) -join '') }) -join "`f") + "`f"
}

# The pages of each file: [pscustomobject]@{ File; Kind = pdf|slides|doc|cells|text; Pages }.
function Get-JkGrepDocs([IO.FileInfo[]]$Files) {
    $todo = @($Files | Where-Object { $_.Extension -ieq '.pdf' -and $null -eq (Read-JkTextCache $_) })
    if ($todo.Count -ge 8) { Say (Paint 'gray' "  reading $($todo.Count) PDFs for the first time (they are kept, so only once)...") }
    Update-JkPdfTexts $todo
    foreach ($f in $Files) {
        $x = $f.Extension.ToLowerInvariant()
        $kind = 'text'; $text = $null
        try {
            switch ($x) {
                '.pdf' { $kind = 'pdf'; $text = Read-JkTextCache $f }
                { $_ -in '.pptx', '.docx' } {
                    $kind = $(if ($x -eq '.pptx') { 'slides' } else { 'doc' })
                    $text = Read-JkTextCache $f
                    if ($null -eq $text) { $t = ''; try { $t = Get-JkOfficeText $f.FullName } catch { }; Save-JkTextCache $f $t; $text = Read-JkTextCache $f }
                }
                '.ipynb' { $kind = 'cells'; $text = Get-JkNotebookText $f.FullName }
                { $_ -in '.html', '.htm' } {
                    $text = [IO.File]::ReadAllText($f.FullName)
                    $text = [Net.WebUtility]::HtmlDecode(([regex]::Replace(([regex]::Replace($text, '(?is)<(script|style)\b.*?</\1>', ' ')), '<[^>]+>', ' ')))
                }
                default { $text = [IO.File]::ReadAllText($f.FullName) }
            }
        } catch { $text = '' }
        if ($null -eq $text) { $text = '' }
        $raw = ''
        if ($kind -eq 'text') { $raw = $text; $pages = @(ConvertTo-JkSearchText $text) }
        elseif ($kind -eq 'cells') { $pages = @($text.TrimEnd([char]12).Split([char]12) | ForEach-Object { ConvertTo-JkSearchText $_ }) }
        else { $pages = @($text.TrimEnd([char]12).Split([char]12)) }
        [pscustomobject]@{ File = $f; Kind = $kind; Pages = $pages; Raw = $raw; Empty = -not $text.Trim() }
    }
}

# ---------------------------------------------------------------- matching

# PDF text with its ligatures spelled out, line-end hyphens joined and runs of space folded, so a
# phrase matches across a line break.
function ConvertTo-JkSearchText([string]$Text) {
    $t = $Text.Replace([string][char]0xFB01, 'fi').Replace([string][char]0xFB02, 'fl').Replace([string][char]0xFB00, 'ff').Replace([string][char]0xFB03, 'ffi').Replace([string][char]0xFB04, 'ffl')
    $t = [regex]::Replace($t, '(\w)-[ \t]*\r?\n\s*(\w)', '$1$2')
    [regex]::Replace($t, '\s+', ' ').Trim()
}

# Pages holding every term (a word anywhere on the page, "a phrase" as written), best first: more
# hits, the terms close together, and a file whose name has them.
function Search-JkDocs($Docs, [string[]]$Terms) {
    $terms = @($Terms | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $cmp = [StringComparison]::OrdinalIgnoreCase
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($d in $Docs) {
        $name = $d.File.Name
        for ($i = 0; $i -lt $d.Pages.Count; $i++) {
            $page = [string]$d.Pages[$i]
            # most pages hold none of the words: the first one rules them out
            if (-not $page -or $page.IndexOf($terms[0], $cmp) -lt 0) { continue }
            $score = 0.0; $first = -1; $longest = -1; $ok = $true; $at = @()
            foreach ($t in $terms) {
                $p = $page.IndexOf($t, $cmp)
                if ($p -lt 0) { $ok = $false; break }
                $at += $p
                $n = 0; $q = $p
                while ($q -ge 0 -and $n -lt 5) { $n++; $q = $page.IndexOf($t, $q + $t.Length, $cmp) }
                $score += $n * $(if ($t.Contains(' ')) { 2 } else { 1 })
                if ($name.IndexOf($t, $cmp) -ge 0) { $score += 3 }
                # the snippet shows the longest term, the most telling one
                if ($t.Length -gt $longest) { $longest = $t.Length; $first = $p }
            }
            if (-not $ok) { continue }
            if ($terms.Count -gt 1) {
                # the words as one phrase ("condition number", not "boundary condition ... number")
                $phrase = $terms -join ' '
                $n = 0; $q = $page.IndexOf($phrase, $cmp)
                if ($q -ge 0) { $first = $q }
                while ($q -ge 0 -and $n -lt 5) { $n++; $q = $page.IndexOf($phrase, $q + $phrase.Length, $cmp) }
                $score += 6 * $n
                if ((($at | Measure-Object -Maximum).Maximum - ($at | Measure-Object -Minimum).Minimum) -lt 120) { $score += 3 }
            }
            # a table of contents names everything once, between dot leaders
            if ([regex]::Matches($page, '(?:\. ){4,}').Count -ge 3) { $score *= 0.3 }
            $line = 0
            if ($d.Kind -eq 'text') {
                $w0 = $terms[0].Split(' ')[0]
                $line = ([regex]::Matches($d.Raw.Substring(0, [Math]::Max(0, $d.Raw.IndexOf($w0, $cmp))), "`n")).Count + 1
            }
            $hits.Add([pscustomobject]@{ Doc = $d; Page = $i + 1; Line = $line; Text = $page; At = $first; Score = $score })
        }
    }
    # on a tie the original before its downloaded copy ("a2.pdf" before "a2 (1).pdf")
    @($hits | Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = { $_.Doc.File.Name -match ' \(\d+\)\.\w+$' } }, @{ Expression = { $_.Doc.File.Name } }, Page)
}

# "p.4", "slide 12", "cell 3", "line 40"
function Format-JkGrepWhere($Hit) {
    switch ($Hit.Doc.Kind) {
        'pdf' { "p.$($Hit.Page)" } 'slides' { "slide $($Hit.Page)" } 'cells' { "cell $($Hit.Page)" } 'doc' { '' }
        default { "line $($Hit.Line)" }
    }
}

# $Width columns of the page around the match, the terms picked out.
function Format-JkGrepSnippet($Hit, [string[]]$Terms, [int]$Width) {
    $t = $Hit.Text
    $start = [Math]::Max(0, $Hit.At - [int]($Width / 3))
    $s = $t.Substring($start, [Math]::Min($t.Length - $start, $Width))
    if ($start -gt 0) { $s = $script:G.ell + $s.Substring(1) }
    if ($start + $Width -lt $t.Length) { $s = $s.Substring(0, $s.Length - 1) + $script:G.ell }
    $s = Fit $s $Width
    foreach ($term in $Terms) {
        $s = [regex]::Replace($s, [regex]::Escape($term), { param($m) Paint 'bold yellow' $m.Value }, 'IgnoreCase')
    }
    $s
}

# ---------------------------------------------------------------- jk grep

function Get-JkGrepFolders($Data, [string[]]$Words, [switch]$All) {
    $folders = Get-JkCourseFolders
    $w = @($Words)
    $label = ''
    if ($w.Count -gt 1 -and $w[0] -match '^(all|every)$') { $All = $true; $w = @($w | Select-Object -Skip 1) }
    if (-not $All -and $w.Count -gt 1) {
        $sp = Split-JkCourseWords $Data $w
        $key = $null
        if ($sp[0]) { $key = $sp[0].key; $w = @($sp[1]); $label = [string]$sp[0].code }
        elseif ($folders.ContainsKey((Get-JkNormKey $w[0]))) { $key = Get-JkNormKey $w[0]; $label = $w[0].ToUpper(); $w = @($w | Select-Object -Skip 1) }
        if ($key) {
            if (-not $folders.ContainsKey($key)) { throw "no folder for $label under $((@((Get-JkConfig 'tidy.courses') -split ';') + 'the Desktop')[0]) (jk config set tidy.courses <folder>)" }
            return , @(@($folders[$key]), $w, $label)
        }
    }
    if ($All) { return , @(@($folders.Values), $w, 'every course') }
    # this term's courses, the ones with deadlines; without any, every course folder
    $now = @($Data.courses | ForEach-Object { $_.key } | Where-Object { $folders.ContainsKey($_) })
    if ($now.Count) { return , @(@($now | ForEach-Object { $folders[$_] }), $w, "this term's courses") }
    , @(@($folders.Values), $w, 'every course')
}

function Invoke-JkGrep {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Words,
        [switch]$All,
        [string]$Root
    )
    $w = @($Words | Where-Object { $_ })
    if (-not $w.Count -or $w[0] -match '^(help|-h|--help|\?)$') { Show-JkHelp grep; return }
    $data = Get-JkDueData -Cached
    if ($Root) { $folders = @($Root); $label = $Root }
    else { $r = Get-JkGrepFolders $data $w -All:$All; $folders = $r[0]; $w = @($r[1]); $label = $r[2] }
    if (-not $w.Count) { throw 'which words? jk grep cs370 condition number' }
    if (-not @($folders).Count) { throw 'no course folders found (jk config set tidy.courses <the folder holding them>)' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $files = @(Get-JkGrepFiles $folders)
    # a .txt beside a PDF of the same name is text copied out of it: the PDF has the pages
    $pdfs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $files) { if ($f.Extension -ieq '.pdf') { $null = $pdfs.Add([IO.Path]::GetFileNameWithoutExtension($f.Name)) } }
    $files = @($files | Where-Object { -not ($_.Extension -ieq '.txt' -and $pdfs.Contains([IO.Path]::GetFileNameWithoutExtension($_.Name))) })
    $docs = @(Get-JkGrepDocs $files)
    $hits = @(Search-JkDocs $docs $w)
    $sw.Stop()
    # no file takes over the list: three pages each, unless -All; the same page twice (a2.pdf and
    # a2 (1).pdf) shows once
    $show = New-Object System.Collections.Generic.List[object]
    $per = @{}
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($h in $hits) {
        $k = $h.Doc.File.FullName
        if (-not $seen.Add("$($h.Text.Length)|" + $h.Text.Substring(0, [Math]::Min(400, $h.Text.Length)))) { continue }
        if (-not $All -and [int]$per[$k] -ge 3) { continue }
        $per[$k] = [int]$per[$k] + 1
        $show.Add($h)
        if ($show.Count -ge $(if ($All) { 60 } else { 12 })) { break }
    }
    $pages = ($docs | ForEach-Object { $_.Pages.Count } | Measure-Object -Sum).Sum
    $right = "$(Format-JkCount $hits.Count 'page') in $(Format-JkCount @($hits | ForEach-Object { $_.Doc.File.FullName } | Select-Object -Unique).Count 'file') $($script:G.dot) $('{0:N1}' -f $sw.Elapsed.TotalSeconds) s"
    Write-JkHeader 'grep' $right -Sub (($w | ForEach-Object { if ($_.Contains(' ')) { "`"$_`"" } else { $_ } }) -join ' ')
    Say (Paint 'gray' "  $label $($script:G.dot) $(Format-JkCount $docs.Count 'file') $($script:G.dot) $(Format-JkCount $pages 'page')")
    Say ''
    if (-not $show.Count) {
        Say (Paint 'gray' '  Nothing has all of those words on one page. Fewer words, or part of one (interp finds interpolation), widens it.')
    } else {
        $width = Get-JkWidth
        $nameW = [int][Math]::Min(30, [Math]::Max(14, (($show | ForEach-Object { Get-JkTextWidth $_.Doc.File.Name } | Measure-Object -Maximum).Maximum)))
        $whereW = 9
        $snipW = [Math]::Max(20, $width - 5 - $nameW - 2 - $whereW - 1)
        $n = 0
        foreach ($h in $show) {
            $n++
            Say ('  ' + (Paint 'gray' (Fit "$n" 3 -Right)) + '  ' + (Paint 'white' (Fit $h.Doc.File.Name $nameW)) + '  ' + (Paint 'cyan' (Fit (Format-JkGrepWhere $h) $whereW)) + (Paint 'muted' (Format-JkGrepSnippet $h $w $snipW)))
        }
        Save-JkFindLast @($show | ForEach-Object { [pscustomobject]@{ Path = $(if ($_.Doc.Kind -eq 'pdf') { $_.Doc.File.FullName + "`t" + $_.Page } else { $_.Doc.File.FullName }) } })
        Say ''
        if ($hits.Count -gt $show.Count) { Say (Paint 'gray' "  +$(Format-JkCount ($hits.Count - $show.Count) 'more page'): another word narrows it, -All lists them") }
        Say ((Paint 'gray' '  jk find -o 1 ') + (Paint 'muted' 'opens a result (a PDF at its page)') + (Paint 'gray' "  $($script:G.dot)  -e 1 ") + (Paint 'muted' 'shows it in Explorer'))
    }
    $blind = @($docs | Where-Object { $_.Kind -eq 'pdf' -and $_.Empty -and $_.File.Length -gt 50KB })
    if ($blind.Count) { Say (Paint 'gray' "  $(Format-JkCount $blind.Count 'PDF') with no text inside (handwritten or scanned) could not be searched") }
}

# ---------------------------------------------------------------- opening at a page

# The program that opens PDFs here (Edge, Chrome, SumatraPDF, Acrobat...), from the file association.
function Get-JkPdfApp {
    $prog = $null
    try { $prog = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.pdf\UserChoice' -ErrorAction Stop).ProgId } catch { }
    if (-not $prog) { try { $prog = (Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\.pdf' -ErrorAction Stop).'(default)' } catch { } }
    if (-not $prog) { return $null }
    $cmd = $null
    try { $cmd = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\$prog\shell\open\command" -ErrorAction Stop).'(default)' } catch { }
    if (-not $cmd) { return $null }
    $m = [regex]::Match($cmd, '^\s*"([^"]+)"|^\s*(\S+)')
    $exe = $(if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value })
    if ($exe -and [IO.File]::Exists($exe)) { $exe } else { $null }
}

# The arguments that open $Path at $Page in that program; $null when it cannot be told a page.
function Get-JkPdfPageArgs([string]$App, [string]$Path, [int]$Page) {
    $leaf = [IO.Path]::GetFileName([string]$App).ToLowerInvariant()
    if ($leaf -match '^(msedge|chrome|brave|firefox|vivaldi|opera)\.exe$') {
        # each folder name escaped on its own: a "#" or a space in a name stays part of the path
        $segs = $Path.Split('\')
        $url = 'file:///' + $segs[0] + '/' + (@($segs | Select-Object -Skip 1 | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
        return '"' + $url + "#page=$Page" + '"'
    }
    if ($leaf -eq 'sumatrapdf.exe') { return "-page $Page `"$Path`"" }
    if ($leaf -in 'acrobat.exe', 'acrord32.exe') { return "/A `"page=$Page`" `"$Path`"" }
    $null
}

function Open-JkPdfAtPage([string]$Path, [int]$Page) {
    $app = Get-JkPdfApp
    $a = $null; if ($app) { $a = Get-JkPdfPageArgs $app $Path $Page }
    if ($a) { Start-Process -FilePath $app -ArgumentList $a; Say ((Paint 'green' "  opened at page $Page  ") + $Path); return }
    Invoke-Item -LiteralPath $Path
    Say ((Paint 'green' '  opened  ') + $Path + (Paint 'gray' "  (page $Page)"))
}
