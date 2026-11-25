# papers.ps1 - jk exam <course> papers: the past exams in a course's folder for its next exam, each
# paired with its solutions when they are there, newest term first, and which ones are done.
#   jk exam cs370 papers  |  jk exam cs370 did 2 74  |  jk exam cs370 undid 2  |  jk exam cs370 sol 2
# Read-only on the course folder; what is done is kept in papers.json.

# "-sol", "_solutions", " answers", "-key" (a word of its own) mark a solution file; "-blank",
# "-questions", "No-Solutions" the paper itself. Stripping both pairs a paper with its solutions.
$script:PaperSolRx = '(?i)[-_ ]*(?<![a-z])(solutions?|solns?|sols?|answers?|ans|key)(?=$|[-_ ])'
$script:PaperBlankRx = '(?i)[-_ ]*(?<![a-z])(blank|questions?|no[-_ ]?solutions?|unsolved|nosol)(?=$|[-_ ])'

# What a past paper for this exam is called: final, midterm, or (a quiz, a test) any exam.
function Get-JkPaperKind([string]$Title) {
    if ($Title -match '(?i)(?<![a-z])final(?![a-z])') { return 'final' }
    if ($Title -match '(?i)mid[-_ ]?term|(?<![a-z])mt\d?(?![a-z])') { return 'midterm' }
    'exam'
}

# A paper's term from its name: Waterloo's term codes ("cs-370-1029-final": 1, the year, the first
# month 1/5/9 -> F2002) or a season and year ("F19-midterm" -> F2019). Sort is newest-highest.
function Get-JkPaperTerm([string]$Name) {
    if ($Name -match '(?<![0-9])1(\d{2})([159])(?![0-9])') {
        $y = 2000 + [int]$Matches[1]; $m = [int]$Matches[2]
        $s = $(switch ($m) { 1 { 'W' } 5 { 'S' } default { 'F' } })
        return [pscustomobject]@{ Label = "$s$y"; Sort = $y * 10 + $m }
    }
    if ($Name -match '(?i)(?<![a-z0-9])([fws])(\d{2})(?![0-9])') {
        $y = 2000 + [int]$Matches[2]; $l = $Matches[1].ToUpper()
        $m = $(switch ($l) { 'W' { 1 } 'S' { 5 } default { 9 } })
        return [pscustomobject]@{ Label = "$l$y"; Sort = $y * 10 + $m }
    }
    [pscustomobject]@{ Label = ''; Sort = 0 }
}

# Whether a file name is a past paper of that kind (not slides, a formula sheet or a preamble, and
# not "a1-final", the last version of an assignment).
function Test-JkPaperName([string]$Name, [string]$Kind) {
    if ($Name -notmatch '(?i)\.pdf$') { return $false }
    $n = [IO.Path]::GetFileNameWithoutExtension($Name)
    if ($n -match '(?i)(?<![a-z])not[-_ ]|preamble|formula|cheat|(?<![a-z])slides?(?![a-z])|outcomes|syllabus|outline') { return $false }
    $final = $n -match '(?i)(?<![a-z])final(?![a-z])' -and $n -notmatch '(?i)(?<![a-z])(a|hw|asst|assignment|lab|project|p|q|report|essay|draft|submission)\d{0,2}[ _-]final'
    $mid = $n -match '(?i)mid[-_ ]?term|(?<![a-z])mt(?![a-z])'
    switch ($Kind) {
        'final' { return $final }
        'midterm' { return $mid }
        default { return ($final -or $mid -or $n -match '(?i)(?<![a-z])(exam|test|quiz)(?![a-z])') }
    }
}

function Get-JkPaperStem([string]$Name) {
    $n = [IO.Path]::GetFileNameWithoutExtension($Name).ToLowerInvariant()
    # a second download of the same file: "exams (4)"
    $n = $n -replace '\s*\(\d+\)$', ''
    # "No-Solutions" before "Solutions"
    (($n -replace $script:PaperBlankRx, '') -replace $script:PaperSolRx, '').Trim(' ', '-', '_')
}

function Test-JkPaperIsSolution([string]$Name) {
    $n = [IO.Path]::GetFileNameWithoutExtension($Name)
    ($n -match $script:PaperSolRx) -and ($n -notmatch '(?i)no[-_ ]?sol')
}

function Get-JkPaperData {
    $d = Read-JkJson 'papers.json' $null
    if (-not $d) { $d = [pscustomobject]@{ done = @() } }
    if ($null -eq (Get-JkProp $d 'done')) { Set-JkProp $d 'done' @() }
    $d
}

function Save-JkPaperData($Data) { $Data.done = @($Data.done); Save-JkJson 'papers.json' $Data }

# The papers in a list: Paper (the file to sit: the questions, or the solutions when that is all
# there is), Sol, Term, Done (its papers.json record). Copies of one paper in two folders are one.
function Get-JkPaperGroups($Files, [string]$Kind, $DoneByPath) {
    $groups = [ordered]@{}
    foreach ($f in @($Files | Where-Object { Test-JkPaperName $_.Name $Kind } | Sort-Object Modified -Descending)) {
        $stem = Get-JkPaperStem $f.Name
        if (-not $groups.Contains($stem)) { $groups[$stem] = [pscustomobject]@{ Stem = $stem; Q = $null; Sol = $null } }
        $g = $groups[$stem]
        if (Test-JkPaperIsSolution $f.Name) { if (-not $g.Sol) { $g.Sol = $f } } elseif (-not $g.Q) { $g.Q = $f }
    }
    @(foreach ($g in $groups.Values) {
            $paper = $(if ($g.Q) { $g.Q } else { $g.Sol })
            $sol = $(if ($g.Q) { $g.Sol } else { $null })
            $done = $null
            foreach ($f in @($g.Q, $g.Sol) | Where-Object { $_ }) { if (-not $done) { $done = $DoneByPath[([string]$f.Path).ToLowerInvariant()] } }
            [pscustomobject]@{ Paper = $paper; Sol = $sol; SolOnly = (-not $g.Q); Term = (Get-JkPaperTerm $paper.Name); Done = $done }
        }) | Sort-Object @{ Expression = { $_.Term.Sort }; Descending = $true }, @{ Expression = { $_.Paper.Name } }
}

# The past papers for a coming exam: Dir, Kind, Main (that kind's papers) and, for a final, Also
# (the midterms: earlier material the final covers too). All is both, numbered in that order.
function Get-JkExamPapers($Data, $Exam) {
    $e = $Exam.E
    $dir = Get-JkCourseFolderFor $Data ([string]$e.course)
    if (-not $dir) { return $null }
    $files = @(Find-JkFiles @() @($dir) -Since ([datetime]'1900-01-01') | Where-Object { -not (Test-JkRecentNoise $_) })
    $byPath = @{}
    foreach ($r in @((Get-JkPaperData).done)) { $byPath[([string]$r.path).ToLowerInvariant()] = $r }
    $kind = Get-JkPaperKind ([string]$Exam.Title)
    $main = @(Get-JkPaperGroups $files $kind $byPath)
    $also = @()
    if ($kind -eq 'final') { $also = @(Get-JkPaperGroups $files 'midterm' $byPath) }
    [pscustomobject]@{ Dir = $dir; Kind = $kind; Main = $main; Also = $also; All = @(@($main) + @($also)) }
}

function Get-JkPaperKindWord([string]$Kind, [int]$Count) {
    $w = $(switch ($Kind) { 'final' { 'final' } 'midterm' { 'midterm' } default { 'past exam' } })
    if ($Count -ne 1) { $w += 's' }
    $w
}

# One line for jk exam's screen: how many papers, how many done.
function Get-JkExamPapersLine($Data, $Exam, [string]$Key) {
    $p = Get-JkExamPapers $Data $Exam
    if (-not $p -or -not $p.All.Count) { return $null }
    $parts = @("$($p.Main.Count) $(Get-JkPaperKindWord $p.Kind $p.Main.Count)")
    if ($p.Also.Count) { $parts += "$($p.Also.Count) $(Get-JkPaperKindWord 'midterm' $p.Also.Count)" }
    if (-not $p.Main.Count) { $parts = @($parts | Select-Object -Skip 1) }
    $done = @($p.All | Where-Object { $_.Done }).Count
    "$($parts -join ' and ') in the folder, $done done  $($script:G.arrow) jk exam $Key papers"
}

function Format-JkPaperMark($Record) {
    $m = Get-JkProp $Record 'mark' $null
    if ($null -eq $m -or "$m" -eq '') { return '' }
    "  $($script:G.dot)  $(Format-JkPct ([double]$m) 0)"
}

function Show-JkExamPapers($Data, $Exam) {
    $cmap = Get-JkCourseMap $Data
    $e = $Exam.E
    $code = Get-JkCourseLabel $e $cmap
    $key = Get-JkNormKey $code
    $p = Get-JkExamPapers $Data $Exam
    if (-not $p) { throw "no folder for $code on the Desktop (a course folder such as Waterloo course\CS350; jk config set tidy.courses <folder>)" }
    $done = @($p.All | Where-Object { $_.Done }).Count
    Write-JkHeader "$code $($Exam.Title)  past papers" $(if ($p.All.Count) { "$done of $($p.All.Count) done" } else { Get-JkShortPath $p.Dir })
    if (-not $p.All.Count) {
        Say (Paint 'gray' "  no past $(Get-JkPaperKindWord $p.Kind 2) in the folder: a PDF with ""$(if ($p.Kind -eq 'exam') { 'exam' } else { $p.Kind })"" in its name counts (cs-370-1029-final.pdf, F19-midterm-sol.pdf)")
        return
    }
    $w = Get-JkWidth
    $nameW = [Math]::Max(18, [Math]::Min(44, $w - 46))
    $n = 0
    $sections = @(@{ Head = (Get-JkPaperKindWord $p.Kind 2); Items = $p.Main }, @{ Head = 'midterms'; Note = '  earlier material, on the final too'; Items = $p.Also })
    # a final with no past finals here: its midterms are what there is
    if (-not $p.Main.Count) { Say (Paint 'gray' "  no past $(Get-JkPaperKindWord $p.Kind 2) in the folder; the midterms cover the first part of the course") }
    foreach ($sec in $sections) {
        if (-not @($sec.Items).Count) { continue }
        Say (' ' + (Paint 'bold white' ((Get-Culture).TextInfo.ToTitleCase($sec.Head))) + (Paint 'gray' ([string]$sec.Note)))
        foreach ($g in @($sec.Items)) {
            $n++
            $mark = $(if ($g.Done) { Paint 'green' $script:G.check } else { Paint 'muted' $script:G.ring })
            $info = $(if ($g.SolOnly) { Paint 'muted' 'solutions only' } elseif ($g.Sol) { Paint 'muted' '+ solutions' } else { Paint 'gray' 'no solutions' })
            if ($g.Done) {
                $at = [datetime]::MinValue
                $when = $(if ([datetime]::TryParse([string]$g.Done.at, $script:Inv, [Globalization.DateTimeStyles]::None, [ref]$at)) { $at.ToString('MMM d', $script:Inv) } else { '' })
                $info = Paint 'green' "done $when$(Format-JkPaperMark $g.Done)"
            }
            Say ('  ' + (Paint 'gray' (Fit "$n" 3 -Right)) + ' ' + $mark + ' ' + (Paint 'white' (Fit $g.Term.Label 6)) + (Paint 'white' (Fit $g.Paper.Name $nameW)) + '  ' + $info)
        }
    }
    Save-JkFindLast @($p.All | ForEach-Object { $_.Paper })
    # the next to sit: the newest not done that has its questions (a solutions-only file gives the
    # answers away), else the newest not done
    $next = Get-JkNextPaper $p
    Say ''
    if ($next) {
        $g = $p.All[$next - 1]
        $what = $(if ($g.Term.Label) { "the $($g.Term.Label) paper" } else { $g.Paper.Name })
        Say ('  ' + (Paint 'gray' 'next: ') + (Paint 'cyan' "jk find -o $next") + (Paint 'gray' " opens $what") + $(if ($g.SolOnly) { Paint 'gray' ' (solutions only: cover the answers)' } else { '' }))
        Say (Paint 'gray' "  then jk exam $key sol <n> for its solutions, and jk exam $key did <n> 74 when done")
    } else { Say (Paint 'green' "  every paper here is done $($script:G.check)  (jk exam $key undid <n> to clear one)") }
    Say (Paint 'gray' "  in $(Get-JkShortPath $p.Dir)")
}

# The number of the paper to sit next (0 when all are done).
function Get-JkNextPaper($Papers) {
    for ($i = 0; $i -lt $Papers.All.Count; $i++) { if (-not $Papers.All[$i].Done -and -not $Papers.All[$i].SolOnly) { return $i + 1 } }
    for ($i = 0; $i -lt $Papers.All.Count; $i++) { if (-not $Papers.All[$i].Done) { return $i + 1 } }
    0
}

# For a course in today's plan whose time goes to an exam: "Next past paper: CS 370 F2005
# cs-370-1059-final.pdf (jk exam cs370 papers)", or $null.
function Get-JkPlanPaperHint($Plan, $Data, [string]$Course) {
    if (-not $Plan -or -not $Course) { return $null }
    $it = @($Plan.Items | Where-Object { $_.Course -eq $Course -and $_.Kind -eq 'exam' -and $Plan.Today.Alloc.ContainsKey($_.Key) } | Sort-Object Due)[0]
    if (-not $it) { return $null }
    $e = @($Data.events | Where-Object { [string]$_.id -eq [string]$it.Id })[0]
    if (-not $e) { return $null }
    $p = Get-JkExamPapers $Data ([pscustomobject]@{ E = $e; Title = $it.Title })
    if (-not $p) { return $null }
    $n = Get-JkNextPaper $p
    if (-not $n) { return $null }
    $g = $p.All[$n - 1]
    $code = Get-JkCourseLabel $e (Get-JkCourseMap $Data)
    "Next past paper: $code $(if ($g.Term.Label) { "$($g.Term.Label) " })$($g.Paper.Name) (jk exam $(Get-JkNormKey $code) papers)"
}

# "74", "74%", "17/20" -> 74 / 85; nothing -> $null
function ConvertTo-JkPaperMark([string]$Text) {
    $t = $Text.Trim().TrimEnd('%')
    if (-not $t) { return $null }
    $v = 0.0; $a = 0.0; $b = 0.0
    if ($t -match '^(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)$' -and [double]::TryParse($Matches[1], [Globalization.NumberStyles]::Float, $script:Inv, [ref]$a) -and [double]::TryParse($Matches[2], [Globalization.NumberStyles]::Float, $script:Inv, [ref]$b) -and $b -gt 0) { $v = 100 * $a / $b }
    elseif (-not [double]::TryParse($t, [Globalization.NumberStyles]::Float, $script:Inv, [ref]$v)) { throw "a mark is 74, 74% or 17/20, not '$Text'" }
    if ($v -lt 0 -or $v -gt 100) { throw "a mark is between 0 and 100%, not '$Text'" }
    [Math]::Round($v, 1)
}

function Get-JkPaperByNumber($Papers, [string]$Ref, [string]$Key) {
    $i = 0
    if (-not [int]::TryParse($Ref, [ref]$i) -or $i -lt 1 -or $i -gt $Papers.All.Count) {
        throw "which paper? a number from jk exam $Key papers (1 to $($Papers.All.Count))"
    }
    $Papers.All[$i - 1]
}

function Set-JkExamPaperDone($Data, $Exam, [string[]]$Rest, [bool]$Done) {
    $code = Get-JkCourseLabel $Exam.E (Get-JkCourseMap $Data)
    $key = Get-JkNormKey $code
    $verb = $(if ($Done) { 'did' } else { 'undid' })
    if (-not @($Rest).Count) { throw "usage: jk exam $key $verb <n>$(if ($Done) { ' [mark]' })  (the numbers are in jk exam $key papers)" }
    $p = Get-JkExamPapers $Data $Exam
    if (-not $p) { throw "no folder for $code on the Desktop (jk config set tidy.courses <folder>)" }
    if (-not $p.All.Count) { throw "no past papers for it in $(Get-JkShortPath $p.Dir)" }
    $g = Get-JkPaperByNumber $p $Rest[0] $key
    $mark = $null; if ($Done -and $Rest.Count -gt 1) { $mark = ConvertTo-JkPaperMark ($Rest[1..($Rest.Count - 1)] -join '') }
    $d = Get-JkPaperData
    $paths = @(@($g.Paper, $g.Sol) | Where-Object { $_ } | ForEach-Object { ([string]$_.Path).ToLowerInvariant() })
    $d.done = @($d.done | Where-Object { $paths -notcontains ([string]$_.path).ToLowerInvariant() })
    if ($Done) { $d.done = @($d.done) + [pscustomobject]@{ path = [string]$g.Paper.Path; at = (Get-JkNow).ToString('s', $script:Inv); mark = $mark } }
    Save-JkPaperData $d
    $name = $(if ($g.Term.Label) { "$($g.Term.Label) $($g.Paper.Name)" } else { $g.Paper.Name })
    $count = @($p.All | Where-Object { $_.Done -and -not [object]::ReferenceEquals($_, $g) }).Count + [int]$Done
    if ($Done) {
        $m = ''; if ($null -ne $mark) { $m = "  $($script:G.dot)  $(Format-JkPct $mark 0)" }
        Say ('  ' + (Paint 'bold green' "$($script:G.check) Done") + " $name" + (Paint 'gray' "$m  $($script:G.dot)  $count of $($p.All.Count) done"))
        if ($g.Sol -and -not $g.SolOnly) { Say (Paint 'gray' "    check it against the solutions: jk exam $key sol $($Rest[0])") }
        $after = Get-JkExamPapers $Data $Exam
        $nx = Get-JkNextPaper $after
        if ($nx) { $ng = $after.All[$nx - 1]; Say (Paint 'gray' "    next: $(if ($ng.Term.Label) { "the $($ng.Term.Label) paper" } else { $ng.Paper.Name }) (jk exam $key papers)") }
    } else { Say ((Paint 'yellow' '  Not done') + " $name" + (Paint 'gray' "  $($script:G.dot)  $count of $($p.All.Count) done")) }
}

function Open-JkExamPaperSolution($Data, $Exam, [string[]]$Rest) {
    $code = Get-JkCourseLabel $Exam.E (Get-JkCourseMap $Data)
    $key = Get-JkNormKey $code
    if (-not @($Rest).Count) { throw "usage: jk exam $key sol <n>  (the numbers are in jk exam $key papers)" }
    $p = Get-JkExamPapers $Data $Exam
    if (-not $p -or -not $p.All.Count) { throw "no past papers for $code" }
    $g = Get-JkPaperByNumber $p $Rest[0] $key
    $f = $(if ($g.SolOnly) { $g.Paper } else { $g.Sol })
    if (-not $f) { throw "no solutions for $($g.Paper.Name) in the folder" }
    Open-JkFindHit $f.Path ''
}
