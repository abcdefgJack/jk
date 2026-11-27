# grade.ps1 - marks tracker built on the weights already stored with each deadline.
#   jk grade                 overview of every course
#   jk grade cs350           detail + what you need on the rest of the course
#   jk grade set 14 17/20    record a mark for deadline #14

function Get-JkGradeData {
    $d = Read-JkJson 'grades.json' $null
    if (-not $d) { $d = [pscustomobject]@{ scores = @(); extras = @(); targets = @(); nextExtra = 1 } }
    foreach ($p in 'scores', 'extras', 'targets', 'pass') { if ($null -eq (Get-JkProp $d $p)) { Set-JkProp $d $p @() } }
    if (-not (Get-JkProp $d 'nextExtra')) { Set-JkProp $d 'nextExtra' 1 }
    # a mark that is not a number ("great", a hand edit) is kept aside, not counted (core.ps1): it
    # stopped jk grade, the course's grades and its exam brief
    Split-JkUnreadable $d 'scores' {
        param($s)
        $n = 0.0
        [string]$s.id -and [double]::TryParse([string]$s.score, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)
    }
    # the same for a pass rule or a target whose percent is not a number ("min": "half", a list):
    # it stopped jk grade and jk plan. Each list keeps its own set-aside records
    $isPct = { param($v) $n = 0.0; ($v -is [string] -or $v -is [ValueType]) -and [double]::TryParse([string]$v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and $n -ge 0 -and $n -le 100 }
    Split-JkUnreadable $d 'pass' { param($r) [string]$r.course -and (& $isPct $r.min) } -Aside 'unreadablePass'
    Split-JkUnreadable $d 'targets' { param($r) [string]$r.course -and (& $isPct $r.target) } -Aside 'unreadableTargets'
    $d
}

function Save-JkGradeData($Data) {
    foreach ($p in 'scores', 'extras', 'targets', 'pass') { if ($null -ne (Get-JkProp $Data $p)) { $Data.$p = @($Data.$p) } }
    Save-JkWithUnreadable $Data 'targets' {
        Save-JkWithUnreadable $Data 'pass' {
            Save-JkWithUnreadable $Data 'scores' { Save-JkJson 'grades.json' $Data }
        } -Aside 'unreadablePass'
    } -Aside 'unreadableTargets'
}

function ConvertTo-JkPercent([string]$Text) {
    # "17 out of 20", "85 %"
    $t = ($Text.Trim() -replace '(?i)\s*\bout\s+of\b\s*', '/').TrimEnd('%').Trim()
    if ($t -match '^(\d*\.?\d+)\s*/\s*(\d*\.?\d+)$') {
        $den = [double]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture)
        if ($den -le 0) { throw "bad score '$Text'" }
        return [Math]::Round(100 * [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) / $den, 2)
    }
    if ($t -match '^\d*\.?\d+$') { return [double]::Parse($t, [Globalization.CultureInfo]::InvariantCulture) }
    throw "can't read the score '$Text' (try 85, 85%, 17/20)"
}

function Get-JkWeightValue([string]$w) {
    if (-not $w) { return 0.0 }
    $m = [regex]::Match($w, '(\d+(?:\.\d+)?)')
    if (-not $m.Success) { return 0.0 }
    [double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
}

# Assessments for one course: weighted deadlines (a quiz window's "opens"/"closes"
# pair counts once) plus extra components added with `jk grade add`.
function Get-JkGradeItems {
    param($DueData, $GradeData, [string]$CourseKey)
    $scoreMap = @{}
    foreach ($s in @($GradeData.scores)) { $scoreMap[[string]$s.id] = [double]$s.score }
    $items = @()
    $evs = @($DueData.events | Where-Object { $_.course -eq $CourseKey -and (Get-JkWeightValue $_.weight) -gt 0 } | Sort-Object date, id)
    foreach ($e in $evs) {
        # an online window ("X opens" + "X closes") is one assessment, listed at its closing; other
        # items that merely share a title (weekly "Quiz") are separate assessments
        $win = $null
        if ([string]$e.title -match '(?i)\s+(opens?|closes?)$') { $win = Get-JkEventWindow $e $DueData }
        if ($win -and [int]$win.Close.id -ne [int]$e.id) { continue }
        $key = [string]$e.id
        $score = $null
        if ($scoreMap.ContainsKey($key)) { $score = $scoreMap[$key] }
        elseif ($win -and $scoreMap.ContainsKey([string]$win.Open.id)) {
            # the mark may have been recorded against the opening half
            $key = [string]$win.Open.id; $score = $scoreMap[$key]
        }
        $items += [pscustomobject]@{ Key = $key; Title = ([string]$e.title -replace '(?i)\s+(opens?|closes?)$', ''); Weight = (Get-JkWeightValue $e.weight); Score = $score; Date = [string]$e.date; Extra = $false }
    }
    foreach ($x in @($GradeData.extras | Where-Object { $_.course -eq $CourseKey })) {
        $sc = $null
        if ($null -ne $x.score -and "$($x.score)" -ne '') { $sc = [double]$x.score }
        $items += [pscustomobject]@{ Key = [string]$x.id; Title = [string]$x.title; Weight = [double]$x.weight; Score = $sc; Date = ''; Extra = $true }
    }
    @($items | Sort-Object Extra, Date, Key)
}

# "best 6 of 8" written in any note for the course becomes a drop-lowest rule for
# assessments that share the first word of that item's title ("Assignment").
function Get-JkGradeRules($DueData, [string]$CourseKey) {
    $rules = @()
    foreach ($e in @($DueData.events | Where-Object { $_.course -eq $CourseKey })) {
        $m = [regex]::Match([string]$e.note, '(?i)best\s+(\d+)\s+of\s+(\d+)')
        if ($m.Success) {
            $prefix = ([string]$e.title -split '\s+')[0]
            if (-not @($rules | Where-Object { $_.Prefix -eq $prefix })) {
                $rules += [pscustomobject]@{ Prefix = $prefix; Keep = [int]$m.Groups[1].Value; Of = [int]$m.Groups[2].Value }
            }
        }
    }
    $rules
}

function Measure-JkGrade {
    param($Items, $Rules)
    $banked = 0.0; $graded = 0.0; $remaining = 0.0
    $dropped = @()
    $ruled = @{}
    foreach ($r in $Rules) {
        $group = @($Items | Where-Object { $_.Title -like "$($r.Prefix)*" })
        if ($group.Count -eq 0) { continue }
        foreach ($g in $group) { $ruled[$g.Key] = $true }
        $w = ($group | Measure-Object -Property Weight -Average).Average
        $scored = @($group | Where-Object { $null -ne $_.Score } | Sort-Object Score -Descending)
        $keep = [Math]::Min($r.Keep, $group.Count)
        $counted = @($scored | Select-Object -First $keep)
        $dropped += @($scored | Select-Object -Skip $keep)
        foreach ($c in $counted) { $banked += $c.Score * $c.Weight / 100; $graded += $c.Weight }
        $remaining += [Math]::Max(0, $keep - $counted.Count) * $w
    }
    foreach ($i in $Items) {
        if ($ruled.ContainsKey($i.Key)) { continue }
        if ($null -ne $i.Score) { $banked += $i.Score * $i.Weight / 100; $graded += $i.Weight }
        else { $remaining += $i.Weight }
    }
    $avg = $null
    if ($graded -gt 0) { $avg = 100 * $banked / $graded }
    # weight not entered yet is still to come: with only a 30% midterm in, the course is not over
    $total = $graded + $remaining
    $unlisted = $(if ($total -lt 99.5) { 100 - $total } else { 0.0 })
    [pscustomobject]@{ Banked = $banked; Graded = $graded; Remaining = $remaining; Unlisted = $unlisted; Total = $total; Average = $avg; Dropped = @($dropped | ForEach-Object { $_.Key }) }
}

# A course's pass rules (jk grade pass): the exams, or the other work, must average at least Min%
# on their own, or the course is capped (Cap, when the outline gives one) or failed. CS 370: the
# midterm and final must average 50% ("36 out of 72"); CS 350: exams and assignments 50% each, or 46.
function Get-JkPassRules($GradeData, [string]$CourseKey) {
    @(@(Get-JkProp $GradeData 'pass' @()) | Where-Object { $_.course -eq $CourseKey })
}

# Each rule measured: the weight of its kind, the average so far, and what its ungraded part needs.
# Need: the average on what is left of that kind for the rule to hold (<= 0: it holds already;
# > 100: out of reach). Left names the ungraded items of that kind ("FINAL").
function Measure-JkPassRules($Data, $GradeData, [string]$CourseKey) {
    $rules = @(Get-JkPassRules $GradeData $CourseKey)
    if (-not $rules.Count) { return @() }
    $kindOf = @{}
    foreach ($e in @($Data.events)) { if ($e.course -eq $CourseKey) { $kindOf[[string]$e.id] = [string]$e.kind } }
    # a window's mark can sit on its opening half: look up the kind by either half
    foreach ($e in @($Data.events)) {
        if ($e.course -ne $CourseKey -or [string]$e.title -notmatch '(?i)\s+(opens?|closes?)$') { continue }
        $win = Get-JkEventWindow $e $Data
        if ($win) { $kindOf[[string]$win.Open.id] = [string]$win.Close.kind }
    }
    $items = @(Get-JkGradeItems $Data $GradeData $CourseKey)
    foreach ($r in $rules) {
        $mine = @($items | Where-Object { $isExam = (-not $_.Extra) -and $kindOf[[string]$_.Key] -eq 'exam'; if ($r.kind -eq 'exam') { $isExam } else { -not $isExam } })
        $w = 0.0; $gw = 0.0; $b = 0.0; $left = @()
        foreach ($i in $mine) {
            $w += $i.Weight
            if ($null -ne $i.Score) { $gw += $i.Weight; $b += $i.Score * $i.Weight / 100 } else { $left += $i.Title }
        }
        $rest = $w - $gw
        $need = $null
        if ($rest -gt 0.0001) { $need = 100 * ([double]$r.min * $w / 100 - $b) / $rest }
        [pscustomobject]@{
            Kind = [string]$r.kind; Min = [double]$r.min; Cap = $(if ($null -ne (Get-JkProp $r 'cap' $null)) { [double]$r.cap } else { $null })
            Weight = $w; Graded = $gw; Average = $(if ($gw -gt 0) { 100 * $b / $gw } else { $null }); Need = $need; Left = @($left)
            Held = $(if ($rest -le 0.0001) { $gw -gt 0 -and 100 * $b / $gw -ge [double]$r.min } else { $need -le 0 })
        }
    }
}

# One rule in words: "the exams (72% of the course) must average 50%: 38.8% so far, the FINAL needs
# 59%". Style is the colour the need deserves.
function Format-JkPassRule($R) {
    $what = $(if ($R.Kind -eq 'exam') { 'the exams' } else { 'the assignments and other work' })
    $txt = "$what ($(Format-JkWeightPct $R.Weight) of the course) must average $(Format-JkPct $R.Min 0)"
    $cap = $(if ($null -ne $R.Cap) { " or the course is capped at $(Format-JkPct $R.Cap 0)" } else { ' to pass' })
    $so = $(if ($null -ne $R.Average) { "$(Format-JkPct $R.Average) so far" } else { 'nothing marked yet' })
    $rest = $(if ($R.Left.Count -eq 1) { "the $($R.Left[0])" } elseif ($R.Left.Count) { "the rest of them" } else { '' })
    if ($null -eq $R.Need) {
        $st = $(if ($R.Held) { 'green' } else { 'red' })
        return @("$txt$cap`: $so, $(if ($R.Held) { "held $($script:G.check)" } else { 'not held' })", $st)
    }
    if ($R.Need -le 0) { return @("$txt$cap`: $so, held whatever $rest scores $($script:G.check)", 'green') }
    if ($R.Need -gt 100) { return @("$txt$cap`: $so, $rest would need $([int][Math]::Round($R.Need))% (out of reach)", 'red') }
    $st = $(if ($R.Need -ge 70) { 'orange' } else { 'white' })
    @("$txt$cap`: $so, $rest needs $([int][Math]::Ceiling($R.Need - 0.0001))%", $st)
}

# jk grade pass cs370 exams 50 | jk grade pass cs350 exams 50 work 50 cap 46 | jk grade pass cs370 off
function Set-JkGradePass {
    $a = @($args | ForEach-Object { [string]$_ })
    if (-not $a.Count) { throw 'usage: jk grade pass <course> exams 50 [work 50] [cap 46]   |   jk grade pass <course> off' }
    $due = Get-JkDueData
    $c = Resolve-JkCourse $due $a[0]
    if (-not $c) { throw "unknown course '$($a[0])'" }
    $gd = Get-JkGradeData
    $others = @(@(Get-JkProp $gd 'pass' @()) | Where-Object { $_.course -ne $c.key })
    if ($a.Count -eq 1) { Show-JkGrade $c.key; return }
    if ($a[1] -match '^(?i)(off|none|clear|rm)$') { Set-JkProp $gd 'pass' $others; Save-JkGradeData $gd; Say (Paint 'gray' "  $($c.code): no pass rule"); return }
    $new = @(); $cap = $null
    for ($i = 1; $i -lt $a.Count; $i += 2) {
        $k = $a[$i].ToLower(); $v = $(if ($i + 1 -lt $a.Count) { $a[$i + 1] } else { '' })
        if ($v -notmatch '^\d+(\.\d+)?%?$') { throw "a pass rule takes a percent after '$k', not '$v' (jk grade pass $($c.key) exams 50)" }
        $n = [double]::Parse($v.TrimEnd('%'), $script:Inv)
        if ($n -le 0 -or $n -gt 100) { throw "'$v' is not a percent from 1 to 100" }
        switch -Regex ($k) {
            '^(exams?|tests?|midterms?|finals?)$' { $new += [pscustomobject]@{ course = $c.key; kind = 'exam'; min = $n } }
            '^(work|assignments?|asst|a|other|homework|hw)$' { $new += [pscustomobject]@{ course = $c.key; kind = 'work'; min = $n } }
            '^(cap|capped|max)$' { $cap = $n }
            default { throw "'$k' is not exams, work or cap (jk grade pass $($c.key) exams 50 work 50 cap 46)" }
        }
    }
    if (-not $new.Count) { throw 'name what must be passed: exams 50, work 50, or both' }
    if ($null -ne $cap) { foreach ($r in $new) { $r | Add-Member -NotePropertyName cap -NotePropertyValue $cap } }
    Set-JkProp $gd 'pass' @($others + $new)
    Save-JkGradeData $gd
    Show-JkGrade $c.key
}

function Get-JkTarget($GradeData, [string]$CourseKey) {
    $t = @($GradeData.targets | Where-Object { $_.course -eq $CourseKey })
    if ($t) { return [double]$t[0].target }
    # jk grade target 85 with no course sets the default for all of them
    $t = @($GradeData.targets | Where-Object { $_.course -eq '*' })
    if ($t) { return [double]$t[0].target }
    80.0
}

# A mark typed at the end of the words: 17/20, 17 / 20, 85, 85 %, 18 out of 20.
$script:JkScoreTailRx = '^(?<ref>.+?)\s+(?<score>\d+(?:\.\d+)?(?:\s*/\s*\d+(?:\.\d+)?|\s+out\s+of\s+\d+(?:\.\d+)?)?\s*%?)$'

# What "cs341 midterm 1", "cs370 a1" or "a2a sync" names among the gradable items: an optional
# course first, then words of the title, where a1 / q2 also stand for "Assignment 1" / "Quiz 2".
# Returns the item's key (deadline id or extra id); $null when nothing graded matches.
function Resolve-JkGradeRef($DueData, $GradeData, [string[]]$Words) {
    $sp = Split-JkCourseWords $DueData $Words
    $courses = @($DueData.courses); if ($sp[0]) { $courses = @($sp[0]) }
    $w = @($sp[1])
    if (-not $w.Count) { return $null }
    $pool = foreach ($c in $courses) {
        foreach ($it in @(Get-JkGradeItems $DueData $GradeData ([string]$c.key))) { $it | Add-Member -NotePropertyName Code -NotePropertyValue ([string]$c.code) -PassThru -Force }
    }
    $rx = @(Get-JkTitleWordRx $w)
    $hits = @($pool | Where-Object { Test-JkTitleWords ([string]$_.Title) $rx })
    if ($hits.Count -gt 1) {
        # marks come in after the fact: one past, unmarked match beats later ones
        $today = (Get-JkNow).ToString('yyyy-MM-dd', $script:Inv)
        $past = @($hits | Where-Object { $_.Date -and $_.Date -le $today -and $null -eq $_.Score })
        if ($past.Count -eq 1) { $hits = $past }
        else {
            $list = $hits; if ($past.Count) { $list = $past }
            throw ("'$($Words -join ' ')' matches several: " + (($list | ForEach-Object { "#$($_.Key) $($_.Code) $($_.Title)" }) -join ', ') + ' (use the number)')
        }
    }
    if ($hits.Count -eq 1) { return [string]$hits[0].Key }
    $null
}

function Format-JkPct($v, [int]$Digits = 1) {
    if ($null -eq $v) { return '-' }
    ("{0:N$Digits}%" -f [double]$v)
}

function Get-JkNeededText([double]$Target, $M) {
    $rest = $M.Remaining + [double]$M.Unlisted
    if ($rest -le 0.0001) {
        if ($M.Banked -ge $Target) { return @('done', 'green') } else { return @('out of reach', 'red') }
    }
    $need = 100 * ($Target - $M.Banked) / $rest
    if ($need -le 0) { return @('locked in', 'green') }
    if ($need -gt 100) { return @(('{0:N0}% (!)' -f $need), 'red') }
    $st = 'white'
    if ($need -ge 90) { $st = 'orange' } elseif ($need -le 60) { $st = 'green' }
    @(('{0:N0}%' -f $need), $st)
}

function Show-JkGradeOverview {
    $due = Get-JkDueData
    $gd = Get-JkGradeData
    Write-JkHeader 'Grades' 'avg = weighted average of what is graded so far'
    # grades hang off the weights on your deadlines: none yet, say how they get there
    if (-not @($due.courses | Where-Object { @(Get-JkGradeItems $due $gd $_.key).Count }).Count) {
        Say (Paint 'gray' '  Nothing to grade yet: marks go against deadlines that carry a weight.')
        Say ('  ' + (Paint 'cyan' 'jk due add cs350 "A3" nov 25 8pm -Weight 10') + (Paint 'gray' '   or  ') + (Paint 'cyan' 'jk due edit <id> -Weight 10'))
        return
    }
    Say (Paint 'gray' ('  ' + (Fit 'course' 12) + (Fit 'graded' 9 -Right) + (Fit 'average' 10 -Right) + (Fit 'banked' 9 -Right) + (Fit 'target' 9 -Right) + (Fit 'need on rest' 15 -Right)))
    foreach ($c in @($due.courses)) {
        $items = Get-JkGradeItems $due $gd $c.key
        if ($items.Count -eq 0) { continue }
        $m = Measure-JkGrade $items (Get-JkGradeRules $due $c.key)
        $target = Get-JkTarget $gd $c.key
        $need = Get-JkNeededText $target $m
        $avgStyle = 'white'
        if ($null -ne $m.Average) { if ($m.Average -ge $target) { $avgStyle = 'green' } elseif ($m.Average -lt $target - 10) { $avgStyle = 'orange' } }
        Say ('  ' + (Paint "bold #$(([string]$c.color).TrimStart('#'))" (Fit $c.code 12)) + (Paint 'muted' (Fit (Format-JkPct $m.Graded 0) 9 -Right)) + (Paint $avgStyle (Fit (Format-JkPct $m.Average) 10 -Right)) + (Paint 'muted' (Fit ('{0:N1}' -f $m.Banked) 9 -Right)) + (Paint 'gray' (Fit (Format-JkPct $target 0) 9 -Right)) + (Paint $need[1] (Fit $need[0] 15 -Right)))
    }
    # pass rules that still want something
    $passLines = @(foreach ($c in @($due.courses)) {
            foreach ($r in @(Measure-JkPassRules $due $gd $c.key)) {
                # held already, or nothing marked of its kind yet (then it says no more than the target)
                if ($r.Held -or $null -eq $r.Average) { continue }
                $t = Format-JkPassRule $r
                "$($c.code): $($t[0])"
            }
        })
    if ($passLines.Count) { Say ''; foreach ($l in $passLines) { Write-JkTip ('  ' + (Paint 'bold white' (Fit 'pass' 7))) 9 $l 'white' -Indent 9 } }
    Say ''
    $unmarked = @(Get-JkUnmarkedItems).Count
    if ($unmarked) { Say ('  ' + (Paint 'amber' "$(Format-JkCount $unmarked 'past item') with no mark yet") + (Paint 'gray' "  $($script:G.arrow) ") + (Paint 'cyan' 'jk grade import <course>') + (Paint 'gray' ' reads a copied LEARN Grades page, or ') + (Paint 'cyan' 'jk grade fill') + (Paint 'gray' ' asks')) }
    Say (Paint 'gray' "  jk grade <course>  $($script:G.dot)  jk grade set <id> 17/20  $($script:G.dot)  jk grade target <course> 85")
}

function Show-JkGrade {
    param([Parameter(Position = 0)][string]$Course)
    if (-not $Course) { Show-JkGradeOverview; return }
    $due = Get-JkDueData
    $gd = Get-JkGradeData
    $c = Resolve-JkCourse $due $Course
    if (-not $c) { throw "unknown course '$Course'" }
    $items = Get-JkGradeItems $due $gd $c.key
    $rules = Get-JkGradeRules $due $c.key
    $m = Measure-JkGrade $items $rules
    $target = Get-JkTarget $gd $c.key
    $color = ([string]$c.color).TrimStart('#')
    Write-JkHeader ([string]$c.code) "target $(Format-JkPct $target 0)" -Sub ([string]$c.name)
    $w = Get-JkWidth
    $titleW = [Math]::Max(16, [Math]::Min(36, $w - 44))
    foreach ($i in $items) {
        $isDropped = $m.Dropped -contains $i.Key
        $scoreTxt = Format-JkPct $i.Score
        $contrib = ''
        if ($null -ne $i.Score) { $contrib = '{0:N2}' -f ($i.Score * $i.Weight / 100) }
        $idTxt = "#$($i.Key)"
        $line = '  ' + (Paint 'gray' (Fit $idTxt 6)) + (Paint 'white' (Fit $i.Title $titleW)) + (Paint 'muted' (Fit (Format-JkPct $i.Weight 1) 8 -Right))
        $scoreStyle = 'gray'
        if ($null -ne $i.Score) { $scoreStyle = 'bold white'; if ($i.Score -ge 85) { $scoreStyle = 'bold green' } elseif ($i.Score -lt 60) { $scoreStyle = 'bold red' } }
        $line += (Paint $scoreStyle (Fit $scoreTxt 9 -Right)) + (Paint 'gray' (Fit $contrib 8 -Right))
        if ($isDropped) { $line += Paint 'gray' '  dropped' }
        Say $line
    }
    foreach ($r in $rules) { Say (Paint 'gray' "  (best $($r.Keep) of $($r.Of) '$($r.Prefix)' items count)") }
    Say ''
    $sumNote = ''
    if ($m.Total -lt 99.5) { $sumNote = Paint 'yellow' "  (weights add up to $(Format-JkPct $m.Total 1) - add missing parts: jk grade add $($c.key) `"Participation`" -Weight 5)" }
    elseif ($m.Total -gt 100.5) { $sumNote = Paint 'yellow' "  (weights add up to $(Format-JkPct $m.Total 1) - is something counted twice? jk due edit <id> -Weight 0, or jk grade clear x<n>)" }
    Say ('  graded ' + (Paint 'white' (Format-JkPct $m.Graded 1)) + ' of the course  ' + $script:G.dot + '  average ' + (Paint "bold #$color" (Format-JkPct $m.Average)) + '  ' + $script:G.dot + '  banked ' + (Paint 'white' ('{0:N2}' -f $m.Banked)) + ' / ' + ('{0:N1}' -f $m.Graded) + $sumNote)
    Write-JkNeedTable $m $target
    # the course's own pass rules: a minimum on the exams (or the work) whatever the total
    $pr = @(Measure-JkPassRules $due $gd $c.key)
    if ($pr.Count) {
        Say ''
        foreach ($r in $pr) { $t = Format-JkPassRule $r; Write-JkTip ('  ' + (Paint 'bold white' (Fit 'pass' 7))) 9 $t[0] $t[1] -Indent 9 }
    } else { Say (Paint 'gray' "  a rule like `"the exams must average 50%`" in the outline? jk grade pass $($c.key) exams 50") }
}

# "to finish with 50% 60% ... / you need ..." for what is left of the course.
function Write-JkNeedTable($M, [double]$Target) {
    $rest = $M.Remaining + [double]$M.Unlisted
    if ($rest -le 0) { return }
    Say ''
    $targets = @(50, 60, 70, 80, 90) + @($Target) | Sort-Object -Unique
    # the cells narrow with the window; the explanation gets a line of its own
    $cellW = [Math]::Max(7, [Math]::Min(13, [int][Math]::Floor(((Get-JkWidth) - 21) / $targets.Count)))
    $row1 = '  to finish with   '
    $row2 = '  you need         '
    foreach ($t in $targets) {
        $n = Get-JkNeededText $t $M
        $hl = 'muted'; if ($t -eq $Target) { $hl = 'bold white' }
        $row1 += Paint $hl (Fit (Format-JkPct $t 0) $cellW -Right)
        $row2 += Paint $n[1] (Fit $n[0] $cellW -Right)
    }
    Say $row1
    Say $row2
    Say (Paint 'gray' "  (the average you need on the remaining $(Format-JkPct $rest 1) of the course$(if ($M.Unlisted -gt 0) { ", $(Format-JkPct $M.Unlisted 1) of it not entered yet" }))")
}

# jk grade cs370 if midterm 70[, a2 85]: the course as it would stand with those marks (nothing is
# saved): the average, and what the rest would then need.
function Show-JkGradeWhatIf {
    param([string]$Course, [string[]]$Words)
    $due = Get-JkDueData
    $gd = Get-JkGradeData
    $c = Resolve-JkCourse $due $Course
    if (-not $c) { throw "unknown course '$Course'" }
    # "a1 38/40, midterm 1 73 / 90": PowerShell turns the comma into an array, which arrives joined by
    # spaces, so each item and mark is paired by where the mark ends instead (before the next item's
    # first word, which starts with a letter, or at the end) - "midterm 1 73" stays Midterm 1 = 73
    $text = ((($Words | Where-Object { $_ }) -join ' ') -replace '\s*,\s*', ' ' -replace '(?i)\s+and\s+', ' ').Trim()
    $pairRx = '(?<ref>\S.*?)\s+(?<score>\d+(?:\.\d+)?(?:\s*/\s*\d+(?:\.\d+)?|\s+out\s+of\s+\d+(?:\.\d+)?)?\s*%?)(?=\s+[A-Za-z]|\s*$)'
    $chunks = @([regex]::Matches($text, $pairRx) | ForEach-Object { "$($_.Groups['ref'].Value.Trim()) $($_.Groups['score'].Value.Trim())" })
    if (-not $chunks.Count) { throw "usage: jk grade $($c.key) if midterm 70   (several: if midterm 70, a2 85)" }
    # a copy of the marks with the assumed ones put in
    $scores = @($gd.scores | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; score = [double]$_.score } })
    $extras = @($gd.extras | ForEach-Object { $_ | Select-Object * })
    $assumed = @()
    foreach ($ch in $chunks) {
        if ($ch -notmatch $script:JkScoreTailRx) { throw "can't read '$ch' (an item and a mark: midterm 70, a2 17/20)" }
        $ref = $Matches['ref']; $pct = ConvertTo-JkPercent $Matches['score']
        $key = Resolve-JkGradeRef $due $gd (@([string]$c.key) + @($ref -split '\s+'))
        if (-not $key) { throw "nothing graded in $($c.code) matches '$ref' (jk grade $($c.key) lists them)" }
        $item = @(Get-JkGradeItems $due $gd ([string]$c.key) | Where-Object { $_.Key -eq $key })[0]
        $assumed += [pscustomobject]@{ Title = $item.Title; Weight = $item.Weight; Pct = $pct; Was = $item.Score }
        if ($key -match '^x\d+$') { @($extras | Where-Object { $_.id -eq $key })[0].score = $pct }
        else { $scores = @($scores | Where-Object { $_.id -ne $key }) + [pscustomobject]@{ id = $key; score = $pct } }
    }
    $hypo = [pscustomobject]@{ scores = $scores; extras = $extras; targets = $gd.targets; nextExtra = $gd.nextExtra }
    $m = Measure-JkGrade (Get-JkGradeItems $due $hypo ([string]$c.key)) (Get-JkGradeRules $due ([string]$c.key))
    $real = Measure-JkGrade (Get-JkGradeItems $due $gd ([string]$c.key)) (Get-JkGradeRules $due ([string]$c.key))
    $target = Get-JkTarget $gd ([string]$c.key)
    Write-JkHeader "$($c.code) what if" "target $(Format-JkPct $target 0)" -Sub 'nothing is saved'
    foreach ($a in $assumed) {
        $was = ''; if ($null -ne $a.Was) { $was = Paint 'gray' "  (recorded: $(Format-JkPct $a.Was))" }
        Say ('  ' + (Paint 'white' (Fit $a.Title 30)) + (Paint 'muted' (Fit (Format-JkPct $a.Weight 1) 8 -Right)) + (Paint 'bold white' (Fit (Format-JkPct $a.Pct) 9 -Right)) + $was)
    }
    Say ''
    $then = 'average ' + (Paint 'bold white' (Format-JkPct $m.Average)) + ' over ' + (Format-JkPct $m.Graded 1) + ' of the course'
    $now = $(if ($null -ne $real.Average) { " (now $(Format-JkPct $real.Average) over $(Format-JkPct $real.Graded 1))" } else { ' (nothing recorded yet)' })
    Say ('  then: ' + $then + (Paint 'gray' $now))
    Write-JkNeedTable $m $target
    if ($m.Remaining + $m.Unlisted -le 0) { Say ''; Say ('  ' + (Paint 'bold white' "final mark $(Format-JkPct $m.Average)")) }
}

function Set-JkGrade {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Words)
    $all = (@($Words | Where-Object { $_ }) -join ' ').Trim()
    if ($all -notmatch $script:JkScoreTailRx) { throw 'usage: jk grade set <id | course and title> <85 | 85% | 17/20>   (jk grade set cs341 midterm 1 72%)' }
    $Ref = $Matches['ref']; $Score = $Matches['score']
    $pct = ConvertTo-JkPercent $Score
    $gd = Get-JkGradeData
    $due = Get-JkDueData
    $key = $Ref.TrimStart('#')
    if ($key -notmatch '^(\d+|x\d+)$') {
        # course and title words; anything the gradable items don't cover goes by title as before
        $k = Resolve-JkGradeRef $due $gd @($Ref -split '\s+')
        if ($k) { $key = $k }
    }
    if ($key -match '^x\d+$') {
        $x = @($gd.extras | Where-Object { $_.id -eq $key })
        if (-not $x) { throw "no extra component $key" }
        $x[0].score = $pct
        $label = "$($x[0].title)"
        $courseKey = $x[0].course
    } else {
        # marks usually arrive after the item is checked off, so search finished ones too
        try { $e = @(Find-JkEvents $due @($key) -Any)[0] }
        catch {
            if ($key -match '^\d+$' -or $_.Exception.Message -match 'several') { throw }
            throw "nothing graded matches '$Ref' (jk grade <course> lists each item with its number)"
        }
        $key = [string]$e.id
        $gd.scores = @($gd.scores | Where-Object { [string]$_.id -ne $key }) + [pscustomobject]@{ id = $key; score = $pct }
        $label = "$(Get-JkCourseLabel $e (Get-JkCourseMap $due)) $($e.title)"
        $courseKey = $e.course
    }
    Save-JkGradeData $gd
    Say ((Paint 'green' "  recorded $($script:G.check)") + "  $label = $(Format-JkPct $pct)")
    $m = Measure-JkGrade (Get-JkGradeItems $due $gd $courseKey) (Get-JkGradeRules $due $courseKey)
    Say (Paint 'gray' "  course average now $(Format-JkPct $m.Average) over $(Format-JkPct $m.Graded 1) graded")
}

# Graded items already past with no mark yet, oldest first: what jk grade fill asks about. An
# online window is one item, keyed by its closing half (as Get-JkGradeItems keys it).
function Get-JkUnmarkedItems([datetime]$Now = (Get-JkNow)) {
    $due = Get-JkDueData
    $gd = Get-JkGradeData
    $cmap = Get-JkCourseMap $due
    $byId = @{}
    foreach ($e in @($due.events)) { $byId[[string]$e.id] = $e }
    $out = foreach ($c in @($due.courses)) {
        foreach ($it in @(Get-JkGradeItems $due $gd ([string]$c.key))) {
            if ($it.Extra -or $null -ne $it.Score) { continue }
            $e = $byId[$it.Key]
            if (-not $e) { continue }
            $at = Get-JkEventDue $e
            if ($at -ge $Now) { continue }
            [pscustomobject]@{ Id = $it.Key; Label = "$(Get-JkCourseLabel $e $cmap) $($it.Title)"; Weight = $it.Weight; Due = $at }
        }
    }
    @($out | Sort-Object Due)
}

# A marked item was handed in: check it off as of its due time (not now, which would tell jk plan
# that the course's latest work was finished today), with the opening half of a window too.
function Complete-JkMarkedItem([string]$Id) {
    $data = Get-JkDueData
    $e = @($data.events | Where-Object { [string]$_.id -eq $Id })[0]
    if (-not $e -or $e.done) { return }
    $done = @($e)
    $win = Get-JkEventWindow $e $data
    if ($win) { $done += $win.Open }
    foreach ($x in $done) { $x.done = $true; Set-JkProp $x 'doneAt' ((Get-JkEventDue $x).ToString('s', $script:Inv)) }
    Save-JkDueData $data
}

# jk grade fill: one pass over every past graded item without a mark.
function Invoke-JkGradeFill {
    $items = @(Get-JkUnmarkedItems)
    if (-not $items.Count) { Say (Paint 'green' "  Every past graded item has a mark. $($script:G.check)"); return }
    Write-JkHeader 'Marks to fill in' (Format-JkCount $items.Count 'item') -Sub 'past graded items with no mark yet'
    if (-not (Test-JkInteractive)) {
        foreach ($i in $items) {
            Say ('  ' + (Paint 'gray' (Fit "#$($i.Id)" 5 -Right)) + '  ' + (Paint 'white' (Fit $i.Label 34)) + (Paint 'muted' (Fit "$($i.Weight)%" 7 -Right)) + (Paint 'gray' "  $($i.Due.ToString('MMM d', $script:Inv))"))
        }
        Say ''
        Say (Paint 'gray' '  jk grade set <id> 17/20 for each, or run jk grade fill in a terminal to go through them')
        return
    }
    Say (Paint 'gray' '  type the mark (17/20, 85 or 85%); Enter skips one, q stops')
    $n = 0
    foreach ($i in $items) {
        while ($true) {
            $ans = ([string](Read-Host "  $($i.Label) ($($i.Weight)%, $($i.Due.ToString('MMM d', $script:Inv)))")).Trim()
            if (-not $ans) { break }
            if ($ans -match '^(q|quit|stop)$') { Say (Paint 'gray' "  $(Format-JkCount $n 'mark') recorded; jk grade for the averages"); return }
            try { $null = ConvertTo-JkPercent $ans } catch { Say (Paint 'orange' "    $($_.Exception.Message)"); continue }
            Set-JkGrade $i.Id $ans
            Complete-JkMarkedItem $i.Id
            $n++
            break
        }
    }
    Say ''
    Say (Paint 'gray' "  $(Format-JkCount $n 'mark') recorded; jk grade for the averages")
}

# Rows of a LEARN Grades page copied as text ("Assignment 1  9 / 10  4 / 5  90 %"): the title, and
# the first score on the line (points, or a percentage). "- / 10" is not graded yet (Pct $null).
function ConvertFrom-JkGradesText([string]$Text) {
    foreach ($line in ([string]$Text -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $l) { continue }
        $fr = [regex]::Match($l, '(?<num>\d+(?:\.\d+)?|-+)\s*/\s*(?<den>\d+(?:\.\d+)?)')
        $pc = [regex]::Match($l, '(?<p>\d+(?:\.\d+)?)\s*%')
        $at = -1; $pct = $null; $shown = ''
        if ($fr.Success -and (-not $pc.Success -or $fr.Index -le $pc.Index)) {
            $at = $fr.Index
            $num = $fr.Groups['num'].Value; $den = $fr.Groups['den'].Value
            $shown = "$num / $den"
            $d = [double]::Parse($den, $script:Inv)
            if ($num -notmatch '^-' -and $d -gt 0) { $pct = [Math]::Round(100 * [double]::Parse($num, $script:Inv) / $d, 2) }
        } elseif ($pc.Success) {
            $at = $pc.Index; $pct = [double]::Parse($pc.Groups['p'].Value, $script:Inv); $shown = "$($pc.Groups['p'].Value)%"
        } else { continue }
        $title = $l.Substring(0, $at).Trim(" `t:-")
        if ($title -notmatch '[A-Za-z]') { continue }
        # LEARN's next column, "Weight Achieved 2 / 2", carries the item's weight
        $weight = $null
        if ($fr.Success) {
            $w2 = [regex]::Match($l.Substring($fr.Index + $fr.Length), '(?:\d+(?:\.\d+)?|-+)\s*/\s*(?<w>\d+(?:\.\d+)?)')
            if ($w2.Success) { $weight = [double]::Parse($w2.Groups['w'].Value, $script:Inv) }
        }
        [pscustomobject]@{ Title = $title; Shown = $shown; Pct = $pct; Weight = $weight }
    }
}

# The graded item a LEARN row is about: the same title; else the one item whose title words all
# appear in the row's ("Assignment 1" in "Assignment 1 - Sorting"; the longest when several do);
# else the one whose title has all the row's words ("A1" for "Assignment 1"). $null when unsure.
function Find-JkGradeRowItem($Row, $Items) {
    # "Assignment 01" is "Assignment 1"
    $norm = { param($s) ((([string]$s -replace '(?i)\s+(opens?|closes?)$', '') -replace '\s+', ' ') -replace '\b0+(\d)', '$1').Trim().ToLower() }
    $rt = & $norm $Row.Title
    $same = @($Items | Where-Object { (& $norm $_.Title) -eq $rt })
    if ($same.Count -eq 1) { return $same[0] }
    $hits = @($Items | Where-Object { $rx = @(Get-JkTitleWordRx @((& $norm $_.Title) -split ' ')); $rx.Count -and (Test-JkTitleWords $rt $rx) })
    if ($hits.Count -gt 1) { $max = ($hits | ForEach-Object { ([string]$_.Title).Length } | Measure-Object -Maximum).Maximum; $hits = @($hits | Where-Object { ([string]$_.Title).Length -eq $max }) }
    if ($hits.Count -eq 1) { return $hits[0] }
    $rx2 = @(Get-JkTitleWordRx @($rt -split ' '))
    $hits = @($Items | Where-Object { Test-JkTitleWords (& $norm $_.Title) $rx2 })
    if ($hits.Count -eq 1) { return $hits[0] }
    $null
}

$script:JkLearnHomeUrl = 'https://learn.uwaterloo.ca/d2l/home'

# jk grade import cs341: the course's LEARN Grades page, copied, becomes marks. Shows what matched
# and what did not, then records on a yes (-Yes skips the question); handed-in items are checked off.
# The course a copied LEARN page is about: the one course code it names most ("CS 350 - Operating
# Systems" in the header, CS350 in links), or $null when it names none or two equally often.
function Find-JkCourseInText($Data, [string]$Text) {
    if (-not $Text) { return $null }
    $hits = foreach ($c in @($Data.courses)) {
        $code = [string]$c.code
        if ($code -notmatch '^\s*([A-Za-z]+)\s*(\d+[A-Za-z]?)\s*$') { continue }
        $n = [regex]::Matches($Text, "(?i)(?<![A-Za-z])$($Matches[1])[ _-]?$($Matches[2])(?![0-9])").Count
        if ($n) { [pscustomobject]@{ C = $c; N = $n } }
    }
    $hits = @($hits | Sort-Object N -Descending)
    if (-not $hits.Count -or ($hits.Count -gt 1 -and $hits[0].N -eq $hits[1].N)) { return $null }
    $hits[0].C
}

function Import-JkGrades {
    param([Parameter(Position = 0)][string]$Course, [string]$Path, [switch]$Yes)
    $due = Get-JkDueData
    $read = { if ($Path) { [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath) } else { Get-JkClipboardText } }
    if (-not $Course) {
        # no course named: the copied page says which one
        $c = Find-JkCourseInText $due (& $read)
        if (-not $c) { throw 'usage: jk grade import <course>   (copy the course''s Grades page in LEARN first; with it copied, jk grade import alone finds the course)' }
        Say (Paint 'gray' "  the copied page is $($c.code)'s")
    } else {
        $c = Resolve-JkCourse $due $Course
        if (-not $c) { throw "unknown course '$Course'" }
    }
    $rows = @(ConvertFrom-JkGradesText (& $read))
    if (-not $Path -and -not @($rows | Where-Object { $null -ne $_.Pct }).Count -and (Test-JkInteractive)) {
        # nothing copied yet: open LEARN, then read the page once it is on the clipboard
        $ans = [string](Read-Host "  Open LEARN in your browser to copy $($c.code)'s grades? [Y/n]")
        if ($ans.Trim() -match '^(|y|yes)$') { Open-JkUrl $script:JkLearnHomeUrl }
        Say (Paint 'gray' "  There: open $($c.code), then Grades; select all (Ctrl+A), copy (Ctrl+C), and come back.")
        $go = [string](Read-Host '  Press Enter once it is copied (q cancels)')
        if ($go.Trim() -match '^(?i)(q|quit|cancel)$') { return }
        $rows = @(ConvertFrom-JkGradesText (& $read))
    }
    if (-not $rows.Count) { throw "found no marks. In LEARN open $($c.code) > Grades, select all (Ctrl+A), copy, then: jk grade import $($c.key)" }
    $gd = Get-JkGradeData
    $items = @(Get-JkGradeItems $due $gd ([string]$c.key))
    $taken = @{}
    # LEARN's own totals: the final grade, and a category's subtotal ("Assignments 8.5 / 10") above
    # the rows it sums, which would be counted twice as an extra part of the grade
    $titles = @($rows | ForEach-Object { ([string]$_.Title).ToLower() })
    $isTotal = { param($t)
        $lt = ([string]$t).ToLower().Trim()
        if ($lt -match '^(final (calculated|adjusted) grade|total|course total|overall)\b') { return $true }
        $stem = $lt -replace 'zzes$', 'z' -replace '(e?s)$', ''   # quizzes, labs, midterms
        $stem.Length -ge 3 -and @($titles | Where-Object { $_ -ne $lt -and $_.StartsWith($stem) }).Count -gt 0
    }
    $plan = foreach ($r in $rows) {
        $it = Find-JkGradeRowItem $r $items
        $state = 'new'
        if (-not $it -and (& $isTotal $r.Title)) { $state = 'total' }
        elseif ($null -eq $r.Pct) { $state = 'ungraded' }
        elseif (-not $it) { $state = 'unmatched' }
        elseif ($taken.ContainsKey($it.Key)) { $state = 'twice' }
        elseif ($null -ne $it.Score -and [Math]::Abs([double]$it.Score - $r.Pct) -lt 0.01) { $state = 'same' }
        elseif ($null -ne $it.Score) { $state = 'change' }
        if ($it -and $state -in 'new', 'change') { $taken[$it.Key] = $true }
        [pscustomobject]@{ Row = $r; Item = $it; State = $state }
    }
    $todo = @($plan | Where-Object { $_.State -in 'new', 'change' })
    Write-JkHeader 'Marks from LEARN' "$(Format-JkCount $todo.Count 'mark') to record" -Sub ([string]$c.code)
    foreach ($p in $plan) {
        $what = ''; $st = 'gray'
        switch ($p.State) {
            'new' { $what = "$($script:G.arrow) #$($p.Item.Key) $($p.Item.Title)"; $st = 'green' }
            'change' { $what = "$($script:G.arrow) #$($p.Item.Key) $($p.Item.Title) (was $(Format-JkPct $p.Item.Score))"; $st = 'yellow' }
            'same' { $what = 'already recorded' }
            'twice' { $what = 'another row already gives this item a mark' }
            'ungraded' { $what = 'not graded yet' }
            'total' { $what = 'a total LEARN adds up (skipped)' }
            'unmatched' { $what = 'not a deadline here (below)' }
        }
        $pct = $(if ($null -ne $p.Row.Pct) { Format-JkPct $p.Row.Pct } else { '' })
        Say ('  ' + (Paint 'white' (Fit $p.Row.Title 28)) + (Paint 'muted' (Fit $p.Row.Shown 12 -Right)) + (Paint 'white' (Fit $pct 9 -Right)) + '  ' + (Paint $st $what))
    }
    # rows that are no deadline (participation, bonus): the command that adds each as a part of the grade
    $extra = @($plan | Where-Object { $_.State -eq 'unmatched' })
    if ($extra.Count) {
        Say ''
        Say (Paint 'gray' '  parts of the grade that are no deadline - add them with:')
        foreach ($p in $extra) {
            $wt = '<weight>'; if ($p.Row.Weight) { $wt = ([double]$p.Row.Weight).ToString('0.##', $script:Inv) }
            Say (Paint 'cyan' "    jk grade add $($c.key) `"$($p.Row.Title)`" -Weight $wt -Score $($p.Row.Shown -replace '\s', '')")
        }
    }
    Say ''
    if (-not $todo.Count) { Say (Paint 'green' "  Nothing new to record. $($script:G.check)"); return }
    if (-not $Yes) {
        if (-not (Test-JkInteractive)) { Say (Paint 'gray' "  jk grade import $($c.key) -Yes records them"); return }
        $ok = [string](Read-Host "  Record $(Format-JkCount $todo.Count 'mark')? [Y/n]")
        if ($ok.Trim() -notmatch '^(|y|yes)$') { Say (Paint 'gray' '  nothing recorded'); return }
    }
    foreach ($p in $todo) {
        $key = [string]$p.Item.Key
        if ($key -match '^x\d+$') { @($gd.extras | Where-Object { $_.id -eq $key })[0].score = $p.Row.Pct }
        else { $gd.scores = @($gd.scores | Where-Object { [string]$_.id -ne $key }) + [pscustomobject]@{ id = $key; score = $p.Row.Pct } }
    }
    Save-JkGradeData $gd
    foreach ($p in $todo) { if ([string]$p.Item.Key -notmatch '^x') { Complete-JkMarkedItem ([string]$p.Item.Key) } }
    $m = Measure-JkGrade (Get-JkGradeItems $due $gd ([string]$c.key)) (Get-JkGradeRules $due ([string]$c.key))
    Say ((Paint 'green' "  recorded $(Format-JkCount $todo.Count 'mark') $($script:G.check)") + (Paint 'gray' "  $($c.code) average now $(Format-JkPct $m.Average) over $(Format-JkPct $m.Graded 1) graded"))
}

function Clear-JkGrade {
    param([Parameter(Position = 0)][string]$Ref)
    $gd = Get-JkGradeData
    $key = $Ref.TrimStart('#')
    if ($key -match '^x\d+$') {
        $gd.extras = @($gd.extras | Where-Object { $_.id -ne $key })
        Say (Paint 'yellow' "  removed extra component $key")
    } else {
        $gd.scores = @($gd.scores | Where-Object { [string]$_.id -ne $key })
        Say (Paint 'yellow' "  cleared the mark for #$key")
    }
    Save-JkGradeData $gd
}

function Add-JkGradeExtra {
    param([Parameter(Position = 0)][string]$Course, [Parameter(Position = 1)][string]$Title, [double]$Weight, [string]$Score)
    if (-not $Course -or -not $Title -or -not $Weight) { throw 'usage: jk grade add <course> "<title>" -Weight 5 [-Score 100]' }
    $due = Get-JkDueData
    $c = Resolve-JkCourse $due $Course
    if (-not $c) { throw "unknown course '$Course'" }
    $gd = Get-JkGradeData
    $id = 'x' + [int]$gd.nextExtra
    $gd.nextExtra = [int]$gd.nextExtra + 1
    $sc = $null
    if ($Score) { $sc = ConvertTo-JkPercent $Score }
    $gd.extras = @($gd.extras) + [pscustomobject]@{ id = $id; course = $c.key; title = $Title; weight = $Weight; score = $sc }
    Save-JkGradeData $gd
    Say ((Paint 'green' "  added $($script:G.check)") + "  $id  $($c.code) $Title ($Weight%)")
}

function Set-JkGradeTarget {
    param([Parameter(Position = 0)][string]$Course, [Parameter(Position = 1)][string]$Target)
    $due = Get-JkDueData
    $isPct = { param($s) $s -match '^\d+(\.\d+)?\s*%?$' }
    if ((& $isPct $Course) -and $Target -and -not (& $isPct $Target)) { $Course, $Target = $Target, $Course }   # target 85 cs350
    if ((& $isPct $Course) -and -not $Target) {
        # one target for every course that has none of its own
        $gd = Get-JkGradeData
        $gd.targets = @($gd.targets | Where-Object { $_.course -ne '*' }) + [pscustomobject]@{ course = '*'; target = (ConvertTo-JkPercent $Course) }
        Save-JkGradeData $gd
        Show-JkGradeOverview
        return
    }
    $c = Resolve-JkCourse $due $Course
    if (-not $c -or -not $Target) { throw 'usage: jk grade target <course> <percent>' }
    $gd = Get-JkGradeData
    $gd.targets = @($gd.targets | Where-Object { $_.course -ne $c.key }) + [pscustomobject]@{ course = $c.key; target = (ConvertTo-JkPercent $Target) }
    Save-JkGradeData $gd
    Show-JkGrade $c.key
}

function Invoke-JkGrade {
    $a = @($args)
    if ($a.Count -eq 0) { Show-JkGradeOverview; return }
    $first = ([string]$a[0]).ToLower()
    $rest = @()
    if ($a.Count -gt 1) { $rest = @($a[1..($a.Count - 1)]) }
    switch -Regex ($first) {
        '^(set|record|got)$' { Set-JkGrade @rest; return }
        '^(clear|unset|rm)$' { Clear-JkGrade @rest; return }
        '^(add|extra)$' { Add-JkGradeExtra @rest; return }
        '^(target|goal)$' { Set-JkGradeTarget @rest; return }
        '^(pass|rule|minimum|min)$' { Set-JkGradePass @rest; return }
        '^(fill|catchup|marks)$' { Invoke-JkGradeFill; return }
        '^(import|learn|paste)$' { Import-JkGrades @rest; return }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'grade'; return }
    }
    # "jk grade cs370 if midterm 70": a what-if, never a mark (checked before the rule below)
    if ($a.Count -ge 3 -and ([string]$a[1]) -match '^(?i)(if|whatif|what-if)$') { Show-JkGradeWhatIf ([string]$a[0]) @($a | Select-Object -Skip 2); return }
    # "jk grade cs370 a1 9/10": a mark at the end means set
    if ($a.Count -ge 2 -and ($a -join ' ') -match $script:JkScoreTailRx) { Set-JkGrade @a; return }
    # words after the course but no mark jk can read at the end: say that, not "unexpected word 'a1'"
    if ($a.Count -ge 2 -and @($a | Where-Object { "$_" -match '^-' }).Count -eq 0) {
        $last = [string]$a[-1]
        if ($last -match '\d') { $null = ConvertTo-JkPercent $last; Set-JkGrade @a; return }
        throw "a mark goes last: jk grade $($a -join ' ') 85   (or 17/20, 85%)"
    }
    Show-JkGrade @a
}
