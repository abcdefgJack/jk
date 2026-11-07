# find.ps1 - jk find: a file by words in its name or folders, across the Desktop, Documents and
# Downloads.   jk find co250 a3  |  jk find cs350 pdf  |  jk find -o 2 (open result 2)
# The folders are walked live (about 0.2 s for ~13k files), so a file saved a minute ago is found
# too. Dependency, build and hidden folders are skipped, and so are links (a junction would list
# its target twice).

$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:JkFindSkip = '^(node_modules|__pycache__|site-packages|venv|bin|obj|build|dist|target)$'
# app caches under Documents that hold thousands of files nobody searches for
$script:JkFindSkipPath = '\\WeChat Files\\(Applet|WMPF|All Users|[^\\]+\\Applet)$'
# by-products of LaTeX and compilers rank below the files they come from (resume.pdf before resume.aux)
$script:JkFindNoise = '^\.(aux|log|out|toc|fls|fdb_latexmk|bbl|blg|nav|snm|bak|tmp|pyc|class|o|obj|d|ilk|pdb)$'

function Get-JkFindRoots {
    $cfg = Get-JkConfig 'find.roots'
    if ($cfg) { return @($cfg -split ';' | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_.Trim()) } | Where-Object { $_ }) }
    @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'), (Get-JkDownloadsPath))
}

# A word in the file name counts more than one only in its folders, more again at the start or
# end of a word in the name ("a3" in "co250_a3.pdf" rather than "data3"); a word that is the
# extension ("pdf") picks the type. Files changed this week or month get a little extra.
function Get-JkFindScore([string[]]$Words, [string]$Name, [string]$Ext, [string]$Leaf, [datetime]$Modified, [datetime]$Now) {
    $score = 0.0
    $stem = $Name
    if ($Ext -and $Name.EndsWith($Ext)) { $stem = $Name.Substring(0, $Name.Length - $Ext.Length) }
    foreach ($w in $Words) {
        if ($Ext -eq ".$w") { $score += 5; continue }
        $at = $stem.IndexOf($w)
        if ($at -ge 0) {
            $score += 10
            if ($at -eq 0 -or -not [char]::IsLetterOrDigit($stem[$at - 1])) { $score += 4 }
            $end = $at + $w.Length
            if ($end -ge $stem.Length -or -not [char]::IsLetterOrDigit($stem[$end])) { $score += 2 }
        }
        elseif ($Leaf.Contains($w)) { $score += 6 }
        else { $score += 3 }
    }
    $age = ($Now - $Modified).TotalDays
    if ($age -lt 7) { $score += 3 } elseif ($age -lt 30) { $score += 1.5 }
    if ($Ext -match $script:JkFindNoise -and $Words -notcontains $Ext.TrimStart('.')) { $score -= 6 }
    $score
}

# Every file under $Roots whose name or folder path (from the root's own name down, e.g.
# "Desktop\Waterloo course\CO250") holds all the words, best first. -Since keeps files changed
# after it; with no words, that is every such file (jk recent).
function Find-JkFiles {
    param([string[]]$Words, [string[]]$Roots, [datetime]$Since = [datetime]::MinValue)
    $words = @($Words | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
    $hits = New-Object System.Collections.Generic.List[object]
    if (-not $words.Count -and $Since -eq [datetime]::MinValue) { return @() }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $hiddenAttr = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System
    $now = Get-Date
    foreach ($root in @($Roots)) {
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $top = [IO.DirectoryInfo](Resolve-JkLongPath $root)
        $cut = 0
        if ($top.Parent) { $cut = $top.Parent.FullName.TrimEnd('\').Length + 1 }
        $stack = New-Object System.Collections.Generic.Stack[IO.DirectoryInfo]
        $stack.Push($top)
        while ($stack.Count) {
            $dir = $stack.Pop()
            if (-not $seen.Add($dir.FullName)) { continue }
            $folder = $dir.FullName.Substring([Math]::Min($cut, $dir.FullName.Length))
            $folderLow = $folder.ToLowerInvariant()
            $leaf = $dir.Name.ToLowerInvariant()
            # words the folder path already holds; the rest must be in the file name
            $need = @(foreach ($w in $words) { if (-not $folderLow.Contains($w)) { $w } })
            try {
                foreach ($i in $dir.EnumerateFileSystemInfos()) {
                    if ($i.Attributes -band $hiddenAttr) { continue }
                    if ($i -is [IO.DirectoryInfo]) {
                        if ($i.Name.StartsWith('.') -or $i.Name -match $script:JkFindSkip -or $i.FullName -match $script:JkFindSkipPath) { continue }
                        # junctions and symlinks point at folders found elsewhere; cloud placeholders
                        # (OneDrive) are reparse points too, but real folders
                        if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                            $link = $null; try { $link = $i.LinkType } catch { }
                            if ($link) { continue }
                        }
                        $stack.Push($i)
                        continue
                    }
                    if ($i.LastWriteTime -lt $Since) { continue }
                    $low = $i.Name.ToLowerInvariant()
                    $ok = $true
                    foreach ($w in $need) { if (-not $low.Contains($w)) { $ok = $false; break } }
                    if (-not $ok) { continue }
                    $score = Get-JkFindScore $words $low $i.Extension.ToLowerInvariant() $leaf $i.LastWriteTime $now
                    $hits.Add([pscustomobject]@{ Path = $i.FullName; Name = $i.Name; Folder = $folder; Size = $i.Length; Modified = $i.LastWriteTime; Score = $score })
                }
            } catch { }
        }
    }
    @($hits | Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Modified'; Descending = $true })
}

function Save-JkFindLast($Hits) { Write-JkText (Get-JkPath 'find.last') ((@($Hits | ForEach-Object { $_.Path }) -join "`n") + "`n") }

function Get-JkFindLast {
    $p = Get-JkPath 'find.last'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    @([IO.File]::ReadAllLines($p) | Where-Object { $_ })
}

function Format-JkFindDate([datetime]$Date, [datetime]$Now) {
    if ($Date.Date -eq $Now.Date) { return 'today' }
    if ($Date.Date -eq $Now.Date.AddDays(-1)) { return 'yesterday' }
    if ($Date.Year -eq $Now.Year) { return $Date.ToString('MMM d', $script:Inv) }
    $Date.ToString('MMM yyyy', $script:Inv)
}

# Long folder paths keep their end, the most specific part: "...\CO250\A3"
function Format-JkFindFolder([string]$Folder, [int]$Width) {
    $cols = Get-JkTextWidth $Folder
    if ($cols -le $Width) { return $Folder + (' ' * ($Width - $cols)) }
    $keep = ''; $used = 1
    for ($k = $Folder.Length - 1; $k -ge 0; $k--) {
        $ch = "$($Folder[$k])"
        $cw = Get-JkTextWidth $ch
        if ($used + $cw -gt $Width) { break }
        $keep = $ch + $keep; $used += $cw
    }
    $script:G.ell + $keep + (' ' * ($Width - $used))
}

function Open-JkFindHit([string]$Path, [string]$How) {
    # a jk grep result carries its PDF page after a tab
    $page = 0
    $tab = $Path.IndexOf("`t")
    if ($tab -ge 0) { $page = [int]$Path.Substring($tab + 1); $Path = $Path.Substring(0, $tab) }
    if (-not (Test-Path -LiteralPath $Path)) { throw "that file is gone: $Path" }
    switch ($How) {
        'print' { return $Path }
        'explorer' { Start-Process explorer.exe -ArgumentList "/select,`"$Path`""; Say ((Paint 'green' '  shown in Explorer  ') + $Path) }
        'code' { Open-JkInEditor $Path; Say ((Paint 'green' '  opened in editor  ') + $Path) }
        default {
            if ($page -gt 0) { Open-JkPdfAtPage $Path $page; return }
            Invoke-Item -LiteralPath $Path; Say ((Paint 'green' '  opened  ') + $Path)
        }
    }
}

function Invoke-JkFind {
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Words,
        [Alias('o')][switch]$Open,
        [Alias('e')][switch]$Explorer,
        [Alias('c')][switch]$Code,
        [Alias('p')][switch]$Print,
        [switch]$All,
        [string]$Root
    )
    $words = @($Words | Where-Object { $_ })
    $how = ''
    if ($Print) { $how = 'print' } elseif ($Explorer) { $how = 'explorer' } elseif ($Code) { $how = 'code' } elseif ($Open) { $how = 'open' }
    if (-not $words.Count) {
        if ($how) { throw 'which file? jk find <words> -o, or jk find -o <n> for a result of the last search' }
        Show-JkHelp 'find'
        return
    }
    # "jk find -o 2": result 2 of the last search
    if ($how -and $words.Count -eq 1 -and $words[0] -match '^\d+$') {
        $last = @(Get-JkFindLast)
        if ($last.Count) {
            $n = [int]$words[0]
            if ($n -lt 1 -or $n -gt $last.Count) { throw "the last search listed $(Format-JkCount $last.Count 'file') (1-$($last.Count))" }
            return (Open-JkFindHit $last[$n - 1] $how)
        }
    }
    $roots = @(Get-JkFindRoots)
    if ($Root) { $roots = @($Root) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $hits = @(Find-JkFiles $words $roots)
    $sw.Stop()
    $query = $words -join ' '
    if ($how) {
        if (-not $hits.Count) { throw "no file matches '$query' (searched $($roots -join ', '))" }
        Save-JkFindLast @($hits | Select-Object -First 15)
        return (Open-JkFindHit $hits[0].Path $how)
    }
    $max = 15
    if ($All) { $max = 200 }
    $show = @($hits | Select-Object -First $max)
    Save-JkFindLast $show
    $right = Format-JkCount $hits.Count 'file'
    if ($hits.Count -gt $show.Count) { $right += ", best $($show.Count)" }
    $right += " $($script:G.dot) $('{0:N1}' -f $sw.Elapsed.TotalSeconds) s"
    Write-JkHeader 'find' $right -Sub $query
    if (-not $show.Count) {
        Say (Paint 'gray' '  Nothing matches. Every word has to appear in the file name or its folders.')
        Say (Paint 'gray' "  searched: $($roots -join '  ')")
        Say ((Paint 'gray' '  Words inside a file (a lecture PDF, notes)?  ') + (Paint 'white' "jk grep $query"))
        return
    }
    Write-JkFindRows $show
    if ($hits.Count -gt $show.Count) { Say (Paint 'gray' "  +$($hits.Count - $show.Count) more: add a word to narrow it, or jk find $query -All") }
    Write-JkFindFooter
}

# The numbered result table shared by jk find and jk recent. -Ago shows "3h 10m ago" instead of a date.
function Write-JkFindRows($Show, [switch]$Ago) {
    $now = Get-Date
    $w = Get-JkWidth
    $dateW = 9; if ($Ago) { $dateW = 13 }
    $avail = [Math]::Max(30, $w - 20 - $dateW)
    $longest = ($Show | ForEach-Object { Get-JkTextWidth $_.Name } | Measure-Object -Maximum).Maximum
    $nameW = [int][Math]::Min($longest, [Math]::Max(16, [Math]::Floor($avail * 0.55)))
    $folderW = $avail - $nameW
    $n = 0
    foreach ($h in $Show) {
        $n++
        $when = Format-JkFindDate $h.Modified $now
        if ($Ago) { $when = Format-JkRelTime $h.Modified }
        Say ('  ' + (Paint 'gray' (Fit "$n" 3 -Right)) + '  ' + (Paint 'white' (Fit $h.Name $nameW)) + '  ' + (Paint 'muted' (Format-JkFindFolder $h.Folder $folderW)) + (Paint 'gray' (Fit (Format-JkSize $h.Size) 9 -Right)) + '  ' + (Paint 'gray' (Fit $when $dateW)))
    }
    Say ''
}

function Write-JkFindFooter {
    Say ((Paint 'gray' '  jk find -o 1 ') + (Paint 'muted' 'open') + (Paint 'gray' "  $($script:G.dot)  -e 1 ") + (Paint 'muted' 'show in Explorer') + (Paint 'gray' "  $($script:G.dot)  -c 1 ") + (Paint 'muted' 'editor') + (Paint 'gray' "  $($script:G.dot)  -p 1 ") + (Paint 'muted' 'path'))
}

# Office lock files, unfinished downloads and build by-products are not "what you worked on"
function Test-JkRecentNoise($Hit) {
    $ext = [IO.Path]::GetExtension($Hit.Name).ToLowerInvariant()
    $Hit.Name.StartsWith('~$') -or $ext -match $script:JkFindNoise -or $script:TidyPartial -contains $ext
}

# Names a deadline's files are likely to carry: "Assignment 2" -> a2, a02, assignment 2, hw2;
# "Quiz 1" -> quiz 1, q1; codes such as "A2A" as they are; a bare "Midterm" as itself.
function Get-JkTitleFileTokens([string]$Title) {
    $t = ($Title -replace '(?i)\s+(opens?|closes?)$', '').Trim()
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($t, '(?i)\b(assignment|asst|homework|hw)\s*0*(\d{1,2})\b')) {
        $n = $m.Groups[2].Value
        foreach ($x in "a$n", "a0$n", "assignment $n", "hw$n", "asst$n") { $out.Add($x) }
    }
    foreach ($m in [regex]::Matches($t, '(?i)\b(quiz|midterm|lab|tutorial|project)\s*0*(\d{1,2})\b')) {
        $w = $m.Groups[1].Value.ToLower(); $n = $m.Groups[2].Value
        foreach ($x in "$w $n", "$($w[0])$n") { $out.Add($x) }
    }
    foreach ($m in [regex]::Matches($t, '\b[A-Za-z]{1,3}\d{1,2}[A-Za-z]?\b')) { $out.Add($m.Value.ToLower()) }
    if (-not $out.Count -and $t -match '(?i)\b(midterm|final|exam|quiz)\b') { $out.Add($Matches[1].ToLower()) }
    @($out | Select-Object -Unique)
}

# The course's folder for a deadline: by its code ("HEALTH 105" -> HEALTH105) or its key.
function Get-JkCourseFolderFor($Data, [string]$CourseKey) {
    $folders = Get-JkCourseFolders
    $c = @($Data.courses | Where-Object { $_.key -eq $CourseKey })[0]
    foreach ($k in @((Get-JkNormKey ([string]$c.code)), (Get-JkNormKey $CourseKey))) { if ($k -and $folders.ContainsKey($k)) { return $folders[$k] } }
    $null
}

# A deadline from an id, or from words: an optional course first ("cs341 a2", "health midterm 1"),
# the rest all in the title. Several matches: the nearest upcoming one (the one being worked on),
# else the latest past one.
function Find-JkDueByWords($Data, [string[]]$Words) {
    $w = @($Words | Where-Object { $_ })
    if ($w.Count -eq 1 -and $w[0] -match '^#?\d+$') { return @(Find-JkEvents $Data $w -Any)[0] }
    $evs = @($Data.events)
    if ($w.Count -gt 1) {
        $c = Resolve-JkCourse $Data $w[0]
        if ($c) { $evs = @($evs | Where-Object { $_.course -eq $c.key }); $w = @($w | Select-Object -Skip 1) }
    }
    $hits = @($evs | Where-Object { $t = ([string]$_.title).ToLower(); -not @($w | Where-Object { -not $t.Contains($_.ToLower()) }).Count })
    if (-not $hits.Count) { throw "no deadline matches '$($Words -join ' ')' (see: jk due all)" }
    $now = Get-JkNow
    $next = @($hits | Where-Object { (Get-JkEventDue $_) -ge $now } | Sort-Object { Get-JkEventDue $_ })
    if ($next.Count) { return $next[0] }
    @($hits | Sort-Object { Get-JkEventDue $_ } -Descending)[0]
}

# A deadline's course folder, every file in it, and those named after the deadline (name matches
# first: A2.tex before A2\MassSpring.ipynb). $null when the course has no folder.
function Get-JkDueFileHits($Data, $Item) {
    $dir = Get-JkCourseFolderFor $Data ([string]$Item.course)
    if (-not $dir) { return $null }
    $all = @(Find-JkFiles @() @($dir) -Since ([datetime]'1900-01-01') | Where-Object { -not (Test-JkRecentNoise $_) })
    $tokens = @(Get-JkTitleFileTokens ([string]$Item.title))
    $hits = @()
    if ($tokens.Count) {
        # "a1-final" and "report_final" are the last version of something else, not the final exam
        $notVersion = '(?<!(?:a|hw|asst|assignment|lab|project|p|q|quiz|report|essay|draft|submission)\d{0,2}[ _-])'
        $rx = '(?i)(?<![a-z0-9])(' + (($tokens | ForEach-Object { if ($_ -eq 'final') { $notVersion + 'final' } else { [regex]::Escape($_) -replace '\\ ', '[ _-]?' } }) -join '|') + ')(?![0-9])'
        $skip = (Split-Path $dir -Leaf).Length
        $hits = @($all | ForEach-Object {
                $inName = $_.Name -match $rx
                $inPath = ("$($_.Folder)".Substring([Math]::Min($skip, "$($_.Folder)".Length))) -match $rx
                if ($inName -or $inPath) { [pscustomobject]@{ Hit = $_; Rank = [int]$inName } }
            } | Sort-Object @{ Expression = 'Rank'; Descending = $true }, @{ Expression = { $_.Hit.Modified }; Descending = $true } | ForEach-Object { $_.Hit })
    }
    [pscustomobject]@{ Dir = $dir; All = $all; Hits = $hits }
}

# jk due files <id|text>: the files in the course folder that look like they belong to a deadline
# (or, when none do, the newest ones there); numbered for jk find -o.
function Show-JkDueFiles {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Refs)
    if (-not $Refs) { throw 'usage: jk due files <id or part of the title>' }
    $data = Get-JkDueData
    $cmap = Get-JkCourseMap $data
    $e = Find-JkDueByWords $data $Refs
    $label = "$(Get-JkCourseLabel $e $cmap) $(([string]$e.title -replace '(?i)\s+(opens?|closes?)$', '').Trim())"
    $f = Get-JkDueFileHits $data $e
    if (-not $f) { throw "no folder for $(Get-JkCourseLabel $e $cmap) on the Desktop (a course folder such as Waterloo course\CS350; jk config set tidy.courses <folder>)" }
    $dir = $f.Dir; $all = $f.All; $hits = $f.Hits
    $show = @($hits | Select-Object -First 15)
    $sub = $label
    if (-not $show.Count) { $show = @($all | Sort-Object Modified -Descending | Select-Object -First 8); $sub = "nothing named after $label yet; newest in the folder" }
    Save-JkFindLast $show
    Write-JkHeader 'Files' (Get-JkShortPath $dir) -Sub $sub
    if (-not $show.Count) { Say (Paint 'gray' '  the folder is empty'); return }
    Write-JkFindRows $show
    Write-JkFindFooter
    Say (Paint 'gray' "  j $(Get-JkNormKey (Split-Path $dir -Leaf)) goes to the folder")
}

# jk recent [days]: files changed in the last few days under the find roots, newest first.
function Invoke-JkRecent {
    param([Parameter(Position = 0)][double]$Days = 2, [switch]$All, [string]$Root)
    if ($Days -le 0) { throw 'how many days back? jk recent 3' }
    $roots = @(Get-JkFindRoots)
    if ($Root) { $roots = @($Root) }
    $since = (Get-Date).AddDays(-$Days)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $hits = @(Find-JkFiles @() $roots -Since $since | Where-Object { -not (Test-JkRecentNoise $_) } | Sort-Object Modified -Descending)
    $sw.Stop()
    $max = 20
    if ($All) { $max = 200 }
    $show = @($hits | Select-Object -First $max)
    Save-JkFindLast $show
    $span = Format-JkCount ([int][Math]::Ceiling($Days)) 'day'
    if ($Days -lt 1) { $span = Format-JkCount ([int][Math]::Round($Days * 24)) 'hour' }
    $right = Format-JkCount $hits.Count 'file'
    if ($hits.Count -gt $show.Count) { $right += ", newest $($show.Count)" }
    $right += " $($script:G.dot) $('{0:N1}' -f $sw.Elapsed.TotalSeconds) s"
    Write-JkHeader 'recent' $right -Sub "changed in the last $span"
    if (-not $show.Count) { Say (Paint 'gray' "  Nothing changed in the last $span (searched: $($roots -join '  '))"); return }
    # where the work happened, before the file-by-file list
    if ($hits.Count -ge 5) {
        $busy = @($hits | Group-Object Folder | Sort-Object Count -Descending | Select-Object -First 4 | ForEach-Object { (Paint 'muted' $_.Name) + (Paint 'gray' " $($_.Count)") })
        Say ('  ' + (Paint 'gray' 'busiest: ') + ($busy -join (Paint 'gray' "  $($script:G.dot)  ")))
        Say ''
    }
    Write-JkFindRows $show -Ago
    if ($hits.Count -gt $show.Count) { Say (Paint 'gray' "  +$($hits.Count - $show.Count) more: jk recent $Days -All") }
    Write-JkFindFooter
}
