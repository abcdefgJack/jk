# grade.ps1 - marks tracker built on the weights already stored with each deadline.
#   jk grade                 overview of every course
#   jk grade cs350           detail + what you need on the rest of the course
#   jk grade set 14 17/20    record a mark for deadline #14

function Get-JkGradeData {
    $d = Read-JkJson 'grades.json' $null
    if (-not $d) { $d = [pscustomobject]@{ scores = @(); extras = @(); targets = @(); nextExtra = 1 } }
    foreach ($p in 'scores', 'extras', 'targets') { if ($null -eq (Get-JkProp $d $p)) { Set-JkProp $d $p @() } }
    if (-not (Get-JkProp $d 'nextExtra')) { Set-JkProp $d 'nextExtra' 1 }
    $d
}

function Save-JkGradeData($Data) {
    foreach ($p in 'scores', 'extras', 'targets') { $Data.$p = @($Data.$p) }
    Save-JkJson 'grades.json' $Data
}

function ConvertTo-JkPercent([string]$Text) {
    $t = $Text.Trim().TrimEnd('%')
    if ($t -match '^(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)$') {
        $den = [double]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture)
        if ($den -le 0) { throw "bad score '$Text'" }
        return [Math]::Round(100 * [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) / $den, 2)
    }
    if ($t -match '^\d+(\.\d+)?$') { return [double]::Parse($t, [Globalization.CultureInfo]::InvariantCulture) }
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
    [pscustomobject]@{ Banked = $banked; Graded = $graded; Remaining = $remaining; Total = $graded + $remaining; Average = $avg; Dropped = @($dropped | ForEach-Object { $_.Key }) }
}

function Get-JkTarget($GradeData, [string]$CourseKey) {
    $t = @($GradeData.targets | Where-Object { $_.course -eq $CourseKey })
    if ($t) { return [double]$t[0].target }
    80.0
}

function Format-JkPct($v, [int]$Digits = 1) {
    if ($null -eq $v) { return '-' }
    ("{0:N$Digits}%" -f [double]$v)
}

function Get-JkNeededText([double]$Target, $M) {
    if ($M.Remaining -le 0.0001) {
        if ($M.Banked -ge $Target) { return @('done', 'green') } else { return @('out of reach', 'red') }
    }
    $need = 100 * ($Target - $M.Banked) / $M.Remaining
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
    Say ''
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
    if ($m.Remaining -gt 0) {
        Say ''
        $targets = @(50, 60, 70, 80, 90) + @($target) | Sort-Object -Unique
        $row1 = '  to finish with   '
        $row2 = '  you need         '
        foreach ($t in $targets) {
            $n = Get-JkNeededText $t $m
            $hl = 'muted'; if ($t -eq $target) { $hl = 'bold white' }
            $row1 += Paint $hl (Fit (Format-JkPct $t 0) 13 -Right)
            $row2 += Paint $n[1] (Fit $n[0] 13 -Right)
        }
        Say $row1
        Say ($row2 + (Paint 'gray' "   avg on the remaining $(Format-JkPct $m.Remaining 1)"))
    }
}

function Set-JkGrade {
    param([Parameter(Position = 0)][string]$Ref, [Parameter(Position = 1)][string]$Score)
    if (-not $Ref -or -not $Score) { throw 'usage: jk grade set <deadline id | extra id> <85 | 85% | 17/20>' }
    $pct = ConvertTo-JkPercent $Score
    $gd = Get-JkGradeData
    $due = Get-JkDueData
    $key = $Ref.TrimStart('#')
    if ($key -match '^x\d+$') {
        $x = @($gd.extras | Where-Object { $_.id -eq $key })
        if (-not $x) { throw "no extra component $key" }
        $x[0].score = $pct
        $label = "$($x[0].title)"
        $courseKey = $x[0].course
    } else {
        # marks usually arrive after the item is checked off, so search finished ones too
        $e = @(Find-JkEvents $due @($key) -Any)[0]
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
        '^(help|-h|--help|\?)$' { Show-JkHelp 'grade'; return }
    }
    Show-JkGrade @a
}
