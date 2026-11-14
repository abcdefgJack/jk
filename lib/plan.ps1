# plan.ps1 - jk plan: split today's study time across what is coming up.
# Each graded item due in the next two weeks gets a work estimate from its weight
# (exams: plan.examMin minutes per percent, others: plan.dueMin per percent). Focus time
# already logged on the course is subtracted, the rest is spread over the days left, and
# today's shares are fitted into the daily budget (plan.hours) as 25-minute blocks.

$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:PlanBlock = 25
# how far ahead an exam is planned for in a course whose marks are behind its target (others: 14)
$script:PlanFarDays = 35

# The courses jk plan leaves out (plan.skip), as course keys; a name that is no course is ignored.
function Get-JkPlanSkip($Data) {
    $raw = [string](Get-JkConfig 'plan.skip')
    if (-not $raw -or $raw -match '^(off|none)$') { return @() }
    @((Resolve-JkCourseList $Data $raw).Keys)
}

# "health105; CS 341" or "health105 cs341" -> course keys, and the names that are no course. A
# piece between ; or , is tried whole first ("CS 341"), then word by word.
function Resolve-JkCourseList($Data, [string]$Text) {
    $keys = @(); $bad = @()
    foreach ($piece in @($Text -split '[;,]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $c = Resolve-JkCourse $Data $piece
        if ($c) { $keys += [string]$c.key; continue }
        foreach ($word in @($piece -split '\s+' | Where-Object { $_ })) {
            $c = Resolve-JkCourse $Data $word
            if ($c) { $keys += [string]$c.key } else { $bad += $word }
        }
    }
    [pscustomobject]@{ Keys = @($keys | Select-Object -Unique); Bad = @($bad) }
}

# What a course's marks do to its study time. The mark still needed on the rest of the course for
# its target (as jk grade works it out) is set against the target: 20 points more is 1.4 times the
# work, capped at 1.5, and a course ahead of its target gets less, down to 0.75. No marks, no
# change. A kind of work already at the target is not given more: assignments at 100% in a course
# with a failed midterm stay as they are, and the exams get the time. Exam is the factor for exams,
# Other for everything else; Need, Target and Average are the numbers behind them.
function Get-JkPlanGradeFactor($Data, $GradeData, [string]$CourseKey) {
    $none = [pscustomobject]@{ Exam = 1.0; Other = 1.0; Need = $null; Target = $null; Average = $null; Pass = $null }
    $items = @(Get-JkGradeItems $Data $GradeData $CourseKey)
    if (-not @($items | Where-Object { $null -ne $_.Score }).Count) { return $none }
    $m = Measure-JkGrade $items (Get-JkGradeRules $Data $CourseKey)
    $rest = $m.Remaining + [double]$m.Unlisted
    if ($m.Graded -le 0 -or $rest -le 0.0001) { return $none }
    $target = Get-JkTarget $GradeData $CourseKey
    $need = 100 * ($target - $m.Banked) / $rest
    $f = [Math]::Round([Math]::Max(0.75, [Math]::Min(1.5, 1 + ($need - $target) / 50)), 2)
    $fe = $f; $fo = $f
    if ($f -gt 1) {
        $kindOf = @{}
        foreach ($e in @($Data.events)) { if ($e.course -eq $CourseKey) { $kindOf[[string]$e.id] = [string]$e.kind } }
        $ew = 0.0; $eb = 0.0; $ow = 0.0; $ob = 0.0
        foreach ($i in $items) {
            if ($null -eq $i.Score) { continue }
            if ($kindOf[[string]$i.Key] -eq 'exam') { $ew += $i.Weight; $eb += $i.Score * $i.Weight }
            else { $ow += $i.Weight; $ob += $i.Score * $i.Weight }
        }
        if ($ew -gt 0 -and $eb / $ew -ge $target) { $fe = 1.0 }
        if ($ow -gt 0 -and $ob / $ow -ge $target) { $fo = 1.0 }
    }
    # the course's own pass rule (jk grade pass): the exams must average 50% whatever the total.
    # A rule that needs more on what is left than its kind has averaged so far gets the same
    # treatment as a target does: 20 points more is 1.4 times the time, capped at 1.5.
    $pass = $null
    foreach ($r in @(Measure-JkPassRules $Data $GradeData $CourseKey)) {
        if ($r.Held -or $null -eq $r.Need -or $null -eq $r.Average -or $r.Need -le $r.Average) { continue }
        $pf = [Math]::Round([Math]::Min(1.5, 1 + ($r.Need - $r.Average) / 50), 2)
        if ($r.Kind -eq 'exam') { if ($pf -gt $fe) { $fe = $pf; $pass = $r } }
        elseif ($pf -gt $fo) { $fo = $pf; $pass = $r }
    }
    [pscustomobject]@{ Exam = $fe; Other = $fo; Need = $need; Target = $target; Average = $m.Average; Pass = $pass }
}

function Get-JkPlanItems {
    param([datetime]$Now = (Get-JkNow), [int]$HorizonDays = 14)
    $data = Get-JkDueData -Cached
    $fd = Get-JkFocusData
    $examPer = [double](Get-JkConfig 'plan.examMin')
    $duePer = [double](Get-JkConfig 'plan.dueMin')
    $groups = @{}
    $skip = @(Get-JkPlanSkip $data)
    $gd = $null; $gf = @{}
    $farDays = [Math]::Max($HorizonDays, $script:PlanFarDays)
    # dates are ISO text: anything outside [today, horizon] is skipped before any parsing
    $fromDay = $Now.ToString('yyyy-MM-dd', $script:Inv)
    $toDay = $Now.AddDays($farDays).ToString('yyyy-MM-dd', $script:Inv)
    foreach ($e in @($data.events)) {
        if ($e.done) { continue }
        if ([string]$e.date -lt $fromDay -or [string]$e.date -gt $toDay) { continue }
        if ($skip -contains [string]$e.course) { continue }
        $w = Get-JkWeightValue $e.weight
        if ($w -le 0) { continue }
        $due = Get-JkEventDue $e
        if ($due -le $Now) { continue }
        # the course's marks: more time where it is behind its target, and its exams from further out
        $ck = [string]$e.course
        if (-not $gf.ContainsKey($ck)) {
            if ($null -eq $gd) { $gd = Get-JkGradeData }
            $gf[$ck] = Get-JkPlanGradeFactor $data $gd $ck
        }
        $factor = $(if ($e.kind -eq 'exam') { $gf[$ck].Exam } else { $gf[$ck].Other })
        $horizon = $HorizonDays
        if ($e.kind -eq 'exam' -and $factor -ge 1.2) { $horizon = $farDays }
        if ($due -gt $Now.AddDays($horizon)) { continue }
        # an exam window (opens + closes) is one thing to prepare for: target the opening.
        # Other items sharing a title (weekly "Quiz") stay separate.
        $norm = ([string]$e.title -replace '(?i)\s+(opens?|closes?)$', '').Trim()
        $key = "$($e.course)|#$($e.id)"
        if ($norm -ne [string]$e.title) {
            $win = Get-JkEventWindow $e $data
            if ($win) { $key = "$($e.course)|#$($win.Close.id)" }
        }
        if (-not $groups.ContainsKey($key) -or $due -lt $groups[$key].Due) {
            $per = $duePer; if ($e.kind -eq 'exam') { $per = $examPer }
            $groups[$key] = [pscustomobject]@{ Key = $key; Course = [string]$e.course; Title = $norm; Due = $due; Weight = $w; Kind = [string]$e.kind; Id = $e.id; Effort = $w * $per * $factor; Done = 0.0; Factor = $factor; Horizon = $horizon; Marks = $gf[$ck] }
        }
    }
    $items = @($groups.Values)
    # only the last two weeks of focus can count (items are at most 14 days out, and credit starts
    # 14 days before each); start stamps are ISO, so they compare as text without parsing. Each
    # label's course is resolved once: a term of sessions repeats a handful of labels.
    $back = 14; foreach ($it in $items) { if ($it.Horizon -gt $back) { $back = $it.Horizon } }
    $cutoff = $Now.Date.AddDays(-$back).ToString('s', $script:Inv)
    $memo = @{}
    $sessions = foreach ($s in @($fd.sessions)) {
        if ([string]$s.start -lt $cutoff) { continue }
        $ck = Resolve-JkLabelCourse $data $memo ([string]$s.label)
        if ($ck) { [pscustomobject]@{ Course = $ck; Start = [datetime]::Parse([string]$s.start, $script:Inv); Minutes = [double]$s.actual } }
    }
    # focus already logged on a course since two weeks before an item counts toward it,
    # shared between that course's items in proportion to their effort. Time before the course's
    # last finished item was spent on that item, so it does not count. (One pass over the finished
    # items, comparing their ISO done-stamps as text, finds each course's latest.)
    $nowIso = $Now.ToString('s', $script:Inv)
    $lastDone = @{}
    foreach ($f in @($data.events)) {
        if (-not $f.done) { continue }
        $at = [string](Get-JkProp $f 'doneAt' '')
        if ($at -and $at -le $nowIso -and $at -gt [string]$lastDone[[string]$f.course]) { $lastDone[[string]$f.course] = $at }
    }
    foreach ($course in ($items | Group-Object Course)) {
        $courseItems = @($course.Group)
        $since = ($courseItems | ForEach-Object { $_.Due.AddDays(-[Math]::Max(14, $_.Horizon)) } | Measure-Object -Minimum).Minimum
        if ($lastDone[$course.Name]) {
            $at = [datetime]::Parse($lastDone[$course.Name], $script:Inv)
            if ($at -gt $since) { $since = $at }
        }
        $logged = 0.0
        foreach ($s in @($sessions)) {
            if ($s.Course -eq $course.Name -and $s.Start -ge $since -and $s.Start -le $Now) { $logged += $s.Minutes }
        }
        # an exam planned from further out (a course behind on its marks) takes only what the nearer
        # items leave: an hour on Monday's assignment is not mostly credited to a final in December
        $near = @($courseItems | Where-Object { $_.Due -le $Now.AddDays($HorizonDays) })
        $far = @($courseItems | Where-Object { $_.Due -gt $Now.AddDays($HorizonDays) })
        foreach ($part in @($near, $far)) {
            $group = @($part)
            $total = 0.0; foreach ($it in $group) { $total += $it.Effort }
            if ($total -le 0) { continue }
            $used = 0.0
            foreach ($it in $group) { $it.Done = [Math]::Min($it.Effort, $logged * $it.Effort / $total); $used += $it.Done }
            $logged = [Math]::Max(0, $logged - $used)
        }
    }
    @($items | Sort-Object Due)
}

# Minutes per item for each of the next $Days days (index 0 = today). Each day, every item
# asks for remaining / days-left; asks are scaled to the budget, rounded to blocks, and
# anything due within two days always gets at least one block.
function Get-JkPlanSchedule {
    param($Items, [datetime]$Now = (Get-JkNow), [int]$Days = 7, [double]$BudgetMin = 180, [double]$TodayLeftFraction = 1.0, [double[]]$DayBudgets = @())
    $remaining = @{}
    $byKey = @{}
    foreach ($it in $Items) { $remaining[$it.Key] = [Math]::Max(0, $it.Effort - $it.Done); $byKey[$it.Key] = $it }
    $sched = @()
    # minutes free on the due day before it: from 9 am to an hour before
    $dueDayFree = { param($it) [Math]::Max(0.0, $it.Due.TimeOfDay.TotalMinutes - 9 * 60 - 60) }
    for ($d = 0; $d -lt $Days; $d++) {
        $day = $Now.Date.AddDays($d)
        # each day has its own budget: a week that runs into the study break has longer days there
        $budget = $BudgetMin
        if ($d -lt $DayBudgets.Count) { $budget = $DayBudgets[$d] }
        $dayBudget = $budget
        if ($d -eq 0) { $budget = $budget * $TodayLeftFraction }
        $asks = @{}
        foreach ($it in $Items) {
            if ($it.Due.Date -lt $day -or $remaining[$it.Key] -le 0) { continue }
            # days available count today and stop the day before the due date, plus the due day itself
            # when the item is at noon or later (a 4:30 pm midterm leaves its morning for review),
            # and today only while more than an hour is left
            $usableDueDay = $it.Due.Hour -ge 12
            # the due day counts for the time before it (from 9 am, keeping the last hour free) as a
            # share of a day's budget: a 12:30 pm final leaves 2h 30m, not a whole day of review
            $w = 0.0
            if ($usableDueDay) { $w = [Math]::Max(0.0, [Math]::Min(1.0, (& $dueDayFree $it) / [Math]::Max(60.0, $budget / $(if ($d -eq 0) { [Math]::Max(0.01, $TodayLeftFraction) } else { 1 })))) }
            $daysLeft = [Math]::Max(1, ($it.Due.Date - $day).TotalDays + $w)
            if ($it.Due.Date -eq $day -and -not $usableDueDay) { continue }
            if ($d -eq 0 -and ($it.Due - $Now).TotalMinutes -lt 60) { continue }
            $asks[$it.Key] = $remaining[$it.Key] / $daysLeft
        }
        $sum = 0.0; foreach ($v in $asks.Values) { $sum += $v }
        $scale = 1.0
        if ($sum -gt $budget -and $sum -gt 0) { $scale = $budget / $sum }
        # when squeezed, hand out the whole blocks that fit by largest share first; rounding each
        # share on its own can leave every item at zero (three 15-minute shares of a 45-minute evening)
        $blocksFor = @{}
        if ($scale -lt 1) {
            $free = [int][Math]::Floor($budget / $script:PlanBlock)
            $exact = @{}
            foreach ($k in $asks.Keys) { $exact[$k] = $asks[$k] * $scale / $script:PlanBlock; $blocksFor[$k] = [int][Math]::Floor($exact[$k]); $free -= $blocksFor[$k] }
            foreach ($k in @($asks.Keys | Sort-Object @{ Expression = { $exact[$_] - $blocksFor[$_] }; Descending = $true }, @{ Expression = { $byKey[$_].Due } })) {
                if ($free -le 0) { break }
                $blocksFor[$k]++; $free--
            }
        }
        $alloc = @{}
        foreach ($k in $asks.Keys) {
            $it = $byKey[$k]
            if ($scale -lt 1) { $m = $blocksFor[$k] * $script:PlanBlock }
            else { $m = [Math]::Round($asks[$k] / $script:PlanBlock) * $script:PlanBlock }
            if ($m -lt $script:PlanBlock -and ($it.Due.Date - $day).TotalDays -le 2) { $m = $script:PlanBlock }
            $m = [Math]::Min($m, [Math]::Ceiling($remaining[$k] / $script:PlanBlock) * $script:PlanBlock)
            # on the day itself, no more than fits before it (one block at least, while any fits)
            if ($it.Due.Date -eq $day) { $m = [Math]::Min($m, [Math]::Max([Math]::Min($script:PlanBlock, $m), [Math]::Floor((& $dueDayFree $it) / $script:PlanBlock) * $script:PlanBlock)) }
            if ($m -gt 0) { $alloc[$k] = $m; $remaining[$k] = [Math]::Max(0, $remaining[$k] - $m) }
        }
        # Need is a whole day's worth (remaining / days left); Budget is what is left of the day,
        # DayBudget the whole day's
        $sched += [pscustomobject]@{ Day = $day; Alloc = $alloc; Need = $sum; Budget = $budget; DayBudget = $dayBudget }
    }
    $sched
}

# A focus label ("cs350 a2a") -> course key. $Memo remembers each first word: resolving a course
# name is a fuzzy search, and a term of sessions uses the same few labels over and over.
function Resolve-JkLabelCourse($Data, [hashtable]$Memo, [string]$Label) {
    $first = ($Label -split '\s+')[0]
    if (-not $first) { return $null }
    if (-not $Memo.ContainsKey($first)) {
        $c = Resolve-JkCourse $Data $first
        $Memo[$first] = $(if ($c) { [string]$c.key } else { $null })
    }
    $Memo[$first]
}

# Focus minutes logged today per course key.
function Get-JkTodayFocusByCourse([datetime]$Now = (Get-JkNow)) {
    $data = Get-JkDueData -Cached
    $memo = @{}
    $day = $Now.ToString('yyyy-MM-dd', $script:Inv)
    $out = @{}
    foreach ($s in @((Get-JkFocusData).sessions)) {
        # ISO start stamps: today's begin with today's date, no parsing needed
        if (-not ([string]$s.start).StartsWith($day)) { continue }
        $ck = Resolve-JkLabelCourse $data $memo ([string]$s.label)
        if ($ck) { $out[$ck] = [double]$out[$ck] + [double]$s.actual }
    }
    $out
}

function Get-JkPlanToday {
    $now = Get-JkNow
    $budgetKey = Get-JkPlanBudgetKey $now
    $budget = [double](Get-JkConfig $budgetKey) * 60
    $items = @(Get-JkPlanItems -Now $now)
    if (-not $items) { return $null }
    # later in the day there is less of the budget left (counting from 8 am to 11 pm)
    $frac = 1.0
    $h = $now.Hour + $now.Minute / 60.0
    if ($h -gt 8) { $frac = [Math]::Max(0.25, (23 - $h) / 15) }
    # plan.hours on class days, plan.examHours in the study break and the exam period, day by day
    $dayBudgets = @(foreach ($d in 0..6) { [double](Get-JkConfig (Get-JkPlanBudgetKey $(if ($d) { $now.Date.AddDays($d).AddHours(12) } else { $now }))) * 60 })
    $sched = @(Get-JkPlanSchedule -Items $items -Now $now -Days 7 -BudgetMin $budget -TodayLeftFraction $frac -DayBudgets $dayBudgets)
    [pscustomobject]@{ Items = $items; Schedule = $sched; Today = $sched[0]; Budget = $budget; BudgetKey = $budgetKey }
}

# Why the plan is not by weight alone, a line each: the courses left out, and what the marks change.
function Get-JkPlanNotes($Plan, $Cmap, $Data) {
    $notes = @()
    $skip = @(Get-JkPlanSkip $Data)
    if ($skip.Count) {
        $names = @($skip | ForEach-Object { Get-JkCourseLabel ([pscustomobject]@{ course = $_ }) $Cmap })
        $notes += "left out: $($names -join ', ')  (jk config set plan.skip off brings $(if ($names.Count -eq 1) { 'it' } else { 'them' }) back)"
    }
    if ($Plan) {
        foreach ($g in @($Plan.Items | Where-Object { $_.Factor -ne 1 } | Group-Object Course)) {
            $it = @($g.Group | Sort-Object Due)[0]; $m = $it.Marks
            $what = $(if (@($g.Group | Where-Object { $_.Kind -ne 'exam' }).Count -eq 0) { ' exams' } elseif (@($g.Group | Where-Object { $_.Kind -eq 'exam' }).Count -eq 0) { ' work' } else { '' })
            $txt = "by your marks: $(Get-JkCourseLabel $it $Cmap)$what x$(([double]$it.Factor).ToString('0.0', $script:Inv))"
            if (@($g.Group | Where-Object { $_.Horizon -gt 14 }).Count) { $txt += ", from $([int]($script:PlanFarDays / 7)) weeks out" }
            $need = $(if ($m.Need -gt 100) { "is out of reach on paper ($([int][Math]::Round($m.Need))% on the rest)" } elseif ($m.Need -le 0) { 'is locked in' } else { "takes $([int][Math]::Round($m.Need))% on the rest" })
            # when the course's pass rule is what sets the time, say that instead, with the factor
            # of the kind the rule is about (not the earliest item's, which may be the other kind)
            if ($m.Pass) {
                $isExam = $m.Pass.Kind -eq 'exam'
                $what = $(if ($isExam) { 'exams' } else { 'work' })
                $kin = @($g.Group | Where-Object { ($_.Kind -eq 'exam') -eq $isExam } | Sort-Object Factor -Descending)
                if ($kin.Count) {
                    $txt = "by your marks: $(Get-JkCourseLabel $it $Cmap) $what x$(([double]$kin[0].Factor).ToString('0.0', $script:Inv))"
                    if (@($kin | Where-Object { $_.Horizon -gt 14 }).Count) { $txt += ", from $([int]($script:PlanFarDays / 7)) weeks out" }
                }
                $rest = $(if ($m.Pass.Left.Count -eq 1) { "the $($m.Pass.Left[0])" } else { 'the rest' })
                $notes += "$txt $($script:G.dash) to pass, the $what must average $([int]$m.Pass.Min)%: $([int][Math]::Round($m.Pass.Average))% so far, $rest needs $([int][Math]::Ceiling($m.Pass.Need - 0.0001))%"
                continue
            }
            $notes += "$txt $($script:G.dash) $([int][Math]::Round($m.Average))% so far, $([int]$m.Target)% $need"
        }
    }
    $notes
}

# jk plan week: the next seven days as a checklist. Each day's study blocks (what jk plan would give
# that day), and under them what is handed in or written that day.
function Show-JkPlanWeek {
    $p = Get-JkPlanToday
    $now = Get-JkNow
    $data = Get-JkDueData -Cached
    $cmap = Get-JkCourseMap $data
    $w = Get-JkWidth
    $key = Get-JkPlanBudgetKey $now
    Write-JkHeader 'Study week' "budget $(Format-JkMinutes ([double](Get-JkConfig $key) * 60))/day $($script:G.dot) jk config set $key $([int](Get-JkConfig $key) + 1)" -Sub "$($now.ToString('ddd MMM d', $script:Inv)) $($script:G.dash) $($now.AddDays(6).ToString('ddd MMM d', $script:Inv))"
    $skip = @(Get-JkPlanSkip $data)
    $left = @{}
    if ($p) { foreach ($r in @(Get-JkPlanLeft $p (Get-JkTodayFocusByCourse $now))) { $left[$r.Item.Key] = $r.Left } }
    $titleW = [Math]::Max(14, [Math]::Min(30, $w - 52))
    $byCourse = @{}; $all = 0.0
    for ($d = 0; $d -lt 7; $d++) {
        $day = $now.Date.AddDays($d)
        $s = $null; if ($p) { $s = @($p.Schedule | Where-Object { $_.Day -eq $day })[0] }
        $its = @(); if ($s) { $its = @($p.Items | Where-Object { $s.Alloc.ContainsKey($_.Key) } | Sort-Object @{ e = { - $s.Alloc[$_.Key] } }, @{ e = { $_.Due } }) }
        $dayKey = $day.ToString('yyyy-MM-dd', $script:Inv)
        # handed in or written that day (not 0% work, not a window's opening, not a course left out)
        $dueThat = @($data.events | Where-Object {
                -not $_.done -and [string]$_.date -eq $dayKey -and $skip -notcontains [string]$_.course -and
                [string]$_.title -notmatch '(?i)\s+opens?$' -and -not ($_.weight -and (Get-JkWeightValue $_.weight) -le 0) -and (Get-JkEventDue $_) -gt $now
            } | Sort-Object { Get-JkEventDue $_ })
        $sum = 0.0; foreach ($it in $its) { $sum += $s.Alloc[$it.Key] }
        $name = $day.ToString('ddd MMM d', $script:Inv)
        $tag = $(if ($d -eq 0) { '  today' } elseif ($d -eq 1) { '  tomorrow' } else { '' })
        $total = $(if ($sum -gt 0) { Format-JkMinutes $sum } else { '' })
        Say (' ' + (Paint 'bold white' $name) + (Paint 'muted' $tag) + (' ' * [Math]::Max(2, 38 + $titleW - $name.Length - $tag.Length - $total.Length)) + (Paint 'bold white' $total))
        if (-not $its.Count -and -not $dueThat.Count) { Say (Paint 'gray' "   $($script:G.dash) nothing planned") }
        foreach ($it in $its) {
            $m = $s.Alloc[$it.Key]
            $byCourse[$it.Course] = [double]$byCourse[$it.Course] + $m; $all += $m
            $color = Get-JkCourseColor $it.Course $cmap
            $mark = $script:G.ring; $st = 'white'
            if ($d -eq 0 -and $left.ContainsKey($it.Key) -and $left[$it.Key] -le 0) { $mark = $script:G.check; $st = 'gray' }
            $days = [int]($it.Due.Date - $day).TotalDays
            $when = $(if ($days -eq 0) { 'due today' } elseif ($days -eq 1) { 'due tomorrow' } else { 'due ' + (Format-JkComingDay $it.Due $now -Short) })
            if ($it.Kind -eq 'exam') { $when = $when -replace '^due ', 'exam ' }
            $ttl = [string]$it.Title; if ((Get-JkTextWidth $ttl) -gt ($titleW - 1)) { $ttl = Get-JkShortTitle $ttl }
            Say ('   ' + (Paint $(if ($mark -eq $script:G.check) { 'green' } else { 'gray' }) $mark) + ' ' + (Paint "bold #$color" (Fit (Get-JkCourseLabel $it $cmap) 11)) + (Paint $st (Fit $ttl ($titleW - 1))) + ' ' + (Paint 'muted' (Fit $when 16)) + (Paint $st (Fit (Format-JkMinutes $m) 7 -Right)))
        }
        foreach ($e in $dueThat) {
            $verb = $(if ($e.kind -eq 'exam') { 'exam' } elseif ($e.kind -eq 'appt') { 'at' } else { 'due' })
            $at = $(if ($e.time) { ' ' + (Format-JkTime ([string]$e.time)) } else { '' })
            Say ('   ' + (Paint 'orange' '!') + ' ' + (Paint 'orange' "$verb$at") + '  ' + (Paint 'white' "$(Get-JkCourseLabel $e $cmap) $(([string]$e.title -replace '(?i)\s+closes?$', '').Trim())") + $(if ($e.weight) { Paint 'gray' "  $($e.weight)" } else { '' }))
        }
    }
    Say ''
    if ($all -gt 0) {
        $parts = @($byCourse.Keys | Sort-Object @{ e = { - $byCourse[$_] } }, @{ e = { $_ } } | ForEach-Object { "$(Get-JkCourseLabel ([pscustomobject]@{ course = $_ }) $cmap) $(Format-JkMinutes $byCourse[$_])" })
        Write-JkTip ('  ' + (Paint 'bold white' (Fit 'the week' 10))) 12 "$(Format-JkMinutes $all): $($parts -join "  $($script:G.dot)  ")" 'white' -Indent 12
    } else { Say (Paint 'green' '  Nothing graded is due in the next two weeks.') }
    foreach ($n in @(Get-JkPlanNotes $p $cmap $data)) { Write-JkTip '  ' 2 $n 'gray' -Indent 4 }
    Say (Paint 'gray' "  jk plan start begins today's first block  $($script:G.dot)  jk plan is today alone")
}

# Which daily budget applies: plan.examHours during the study break and the exam period (no
# classes), plan.hours otherwise.
function Get-JkPlanBudgetKey([datetime]$Now = (Get-JkNow)) {
    try {
        $phase = (Get-JkTermInfo (Get-JkDueData -Cached) $Now).Phase
        if ($phase -eq 'study' -or $phase -eq 'exams') { return 'plan.examHours' }
    } catch { }
    'plan.hours'
}

function Show-JkPlan {
    $p = Get-JkPlanToday
    $now = Get-JkNow
    $data = Get-JkDueData
    $cmap = Get-JkCourseMap $data
    $w = Get-JkWidth
    $key = Get-JkPlanBudgetKey $now
    Write-JkHeader 'Study plan' "budget $(Format-JkMinutes ([double](Get-JkConfig $key) * 60))/day $($script:G.dot) jk config set $key $([int](Get-JkConfig $key) + 1)" -Sub ($now.ToString('dddd, MMM d', $script:Inv))
    if (-not $p) { Say (Paint 'green' '  Nothing graded is due in the next two weeks.'); foreach ($n in @(Get-JkPlanNotes $null $cmap $data)) { Write-JkTip '  ' 2 $n 'gray' -Indent 4 }; return }
    $logged = Get-JkTodayFocusByCourse $now
    $today = $p.Today
    Say (' ' + (Paint 'bold white' 'Today'))
    if ($today.Alloc.Count -eq 0) { Say (Paint 'green' '  nothing scheduled for today') }
    $order = @($p.Items | Where-Object { $today.Alloc.ContainsKey($_.Key) } | Sort-Object @{ Expression = { $today.Alloc[$_.Key] }; Descending = $true }, Due)
    # the title column gives way in a narrow window so "~4h of work left" still fits
    $titleW = [Math]::Max(12, [Math]::Min(24, $w - 72))
    foreach ($it in $order) {
        $m = $today.Alloc[$it.Key]
        $color = Get-JkCourseColor $it.Course $cmap
        $code = Get-JkCourseLabel ([pscustomobject]@{ course = $it.Course }) $cmap
        $days = [int]($it.Due.Date - $now.Date).TotalDays
        # the plan looks two weeks ahead: past the first, "Mon" would name the wrong Monday
        $when = Format-JkComingDay $it.Due $now -Short; if ($days -eq 0) { $when = 'today' } elseif ($days -eq 1) { $when = 'tmrw' }
        $blocks = Paint "#$color" ($script:G.full * [int]($m / $script:PlanBlock))
        $left = [Math]::Max(0, $it.Effort - $it.Done)
        # a narrow window: "A6" rather than "Assignment..." (and a space before the next column)
        $ttl = [string]$it.Title; if ((Get-JkTextWidth $ttl) -gt ($titleW - 1)) { $ttl = Get-JkShortTitle $ttl }
        Say ('  ' + (Paint "bold #$color" (Fit $code 11)) + (Paint 'white' (Fit $ttl ($titleW - 1))) + ' ' + (Paint 'muted' (Fit "$when $($script:G.dot) $($it.Weight)%" 13)) + (Paint 'bold white' (Fit (Format-JkMinutes $m) 7 -Right)) + '  ' + $blocks + (Paint 'gray' "   ~$(Format-JkMinutes $left) of work left"))
    }
    $planned = 0.0; foreach ($v in $today.Alloc.Values) { $planned += $v }
    $doneToday = 0.0; foreach ($v in $logged.Values) { $doneToday += $v }
    Say ''
    $prog = 0.0; if ($planned -gt 0) { $prog = [Math]::Min(1, $doneToday / $planned) }
    Say ('  ' + (Get-JkBar $prog 30 'green') + '  ' + (Paint 'white' "$(Format-JkMinutes $doneToday) of $(Format-JkMinutes $planned) focused today"))
    # Need is a whole day's worth of work, so it is weighed against the whole day's budget: an
    # evening that has only 45 minutes left is short by the clock, not by the budget
    if ($today.Need -gt $today.DayBudget * 1.15) {
        $more = [int][Math]::Ceiling($today.Need / 60)
        Say ('  ' + (Paint 'orange' "! the next deadlines want ~$(Format-JkMinutes $today.Need) a day, more than your $(Format-JkMinutes $today.DayBudget): the plan is squeezed (jk config set $($p.BudgetKey) $more)"))
    }
    foreach ($n in @(Get-JkPlanNotes $p $cmap $data)) { Write-JkTip '  ' 2 $n 'gray' -Indent 4 }

    # the week ahead: minutes per course per day
    Say ''
    Say (' ' + (Paint 'bold white' 'Next 7 days') + (Paint 'gray' '  (minutes per course, if you follow the plan)'))
    $courses = @($p.Items | ForEach-Object { $_.Course } | Select-Object -Unique)
    $head = '  ' + (' ' * 11)
    foreach ($s in $p.Schedule) { $lbl = $s.Day.ToString('ddd', $script:Inv); if ($s.Day -eq $now.Date) { $lbl = 'tod' }; $head += Paint 'muted' (Fit $lbl 6 -Right) }
    Say $head
    foreach ($c in $courses) {
        $color = Get-JkCourseColor $c $cmap
        $line = '  ' + (Paint "bold #$color" (Fit (Get-JkCourseLabel ([pscustomobject]@{ course = $c }) $cmap) 11))
        foreach ($s in $p.Schedule) {
            $m = 0
            foreach ($it in @($p.Items | Where-Object { $_.Course -eq $c })) { if ($s.Alloc.ContainsKey($it.Key)) { $m += $s.Alloc[$it.Key] } }
            $txt = ''; if ($m -gt 0) { $txt = "$m" }
            $line += Paint "#$color" (Fit $txt 6 -Right)
        }
        Say $line
    }
    $next = Get-JkPlanNext $p $logged
    if ($next) {
        Say ''
        Say ('  ' + (Paint 'gray' 'next: ') + (Paint 'cyan' "jk plan start") + (Paint 'gray' "  $($script:G.arrow) 25m on $((Get-JkCourseLabel ([pscustomobject]@{ course = $next.Course }) $cmap)) $($next.Title)"))
    }
}

# Today's planned items with the minutes still to focus, in deadline order: focus logged on a
# course today counts against its earliest item first. Want is the plan's, Left what remains.
function Get-JkPlanLeft($Plan, $Logged) {
    if (-not $Plan) { return @() }
    $usedByCourse = @{}
    if ($Logged) { foreach ($k in $Logged.Keys) { $usedByCourse[$k] = $Logged[$k] } }
    @(foreach ($it in @($Plan.Items | Where-Object { $Plan.Today.Alloc.ContainsKey($_.Key) } | Sort-Object Due)) {
            $want = [double]$Plan.Today.Alloc[$it.Key]
            $used = [Math]::Min($want, [double]$usedByCourse[$it.Course])
            $usedByCourse[$it.Course] = [double]$usedByCourse[$it.Course] - $used
            [pscustomobject]@{ Item = $it; Want = $want; Left = $want - $used }
        })
}

# The planned item with the most unfocused minutes left today (the earlier deadline on a tie):
# what jk plan start begins, and what jk next leads its study with.
function Get-JkPlanNext($Plan, $Logged) {
    $best = $null; $bestLeft = 0
    foreach ($r in @(Get-JkPlanLeft $Plan $Logged)) { if ($r.Left -gt $bestLeft) { $best = $r.Item; $bestLeft = $r.Left } }
    $best
}

function Start-JkPlanBlock {
    $p = Get-JkPlanToday
    $next = Get-JkPlanNext $p (Get-JkTodayFocusByCourse)
    if (-not $next) { Say (Paint 'green' "  Today's plan is covered. $($script:G.check)"); return }
    Start-JkFocus ([string]$script:PlanBlock) @($next.Course, $next.Title)
    # the files for it, one jk find -o away
    try {
        $data = Get-JkDueData
        $e = @($data.events | Where-Object { [string]$_.id -eq [string]$next.Id })[0]
        $f = $null; if ($e) { $f = Get-JkDueFileHits $data $e }
        if ($f -and $f.Hits.Count) {
            $top = @($f.Hits | Select-Object -First 3)
            Save-JkFindLast $top
            $n = 0
            $names = foreach ($h in $top) { $n++; (Paint 'gray' "$n ") + (Paint 'white' $h.Name) }
            Say ('  ' + (Paint 'gray' 'files: ') + ($names -join '   ') + (Paint 'gray' "   $($script:G.arrow) jk find -o 1"))
        }
    } catch { }
}

# Today's courses, most planned minutes first and the earlier deadline on a tie (what jk plan start
# picks); $ByCourse holds the minutes. Without the tie-break, two courses at 1h 15m came out in
# hashtable order.
function Get-JkPlanCourseOrder($Plan, $ByCourse) {
    $first = @{}
    foreach ($it in @($Plan.Items)) {
        if (-not $Plan.Today.Alloc.ContainsKey($it.Key)) { continue }
        if (-not $first.ContainsKey($it.Course) -or $it.Due -lt $first[$it.Course]) { $first[$it.Course] = $it.Due }
    }
    @($ByCourse.Keys | Sort-Object @{ e = { - [double]$ByCourse[$_] } }, @{ e = { $first[$_] } })
}

# One line for the dashboard: today's blocks per course.
function Get-JkPlanLine {
    $p = Get-JkPlanToday
    if (-not $p -or $p.Today.Alloc.Count -eq 0) { return $null }
    $cmap = Get-JkCourseMap (Get-JkDueData -Cached)
    $logged = Get-JkTodayFocusByCourse
    $byCourse = @{}
    foreach ($it in $p.Items) { if ($p.Today.Alloc.ContainsKey($it.Key)) { $byCourse[$it.Course] = [double]$byCourse[$it.Course] + $p.Today.Alloc[$it.Key] } }
    # the line ends "-> jk plan start": the course that begins leads (after focus on another, it
    # need not be the one with the most minutes planned)
    $order = @(Get-JkPlanCourseOrder $p $byCourse)
    $next = Get-JkPlanNext $p $logged
    if ($next) { $order = @($next.Course) + @($order | Where-Object { $_ -ne $next.Course }) }
    $parts = foreach ($c in $order) {
        $color = Get-JkCourseColor $c $cmap
        $code = (Get-JkCourseLabel ([pscustomobject]@{ course = $c }) $cmap) -replace '\s', ''
        $done = [double]$logged[$c]
        $txt = Format-JkMinutes $byCourse[$c]
        if ($done -gt 0) { $txt = "$(Format-JkMinutes ([Math]::Min($done, $byCourse[$c])))/$txt" }
        $st = 'muted'; if ($done -ge $byCourse[$c]) { $st = 'green' }
        (Paint "#$color" $code) + ' ' + (Paint $st $txt)
    }
    ($parts -join (Paint 'gray' "  $($script:G.dot)  "))
}

function Invoke-JkPlan {
    $a = @($args)
    if ($a.Count -eq 0) { Show-JkPlan; return }
    switch -Regex (([string]$a[0]).ToLower()) {
        '^(start|go|next)$' { Start-JkPlanBlock; return }
        '^(week|wk|w|7|list|checklist)$' { Show-JkPlanWeek; return }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'plan'; return }
    }
    throw "unknown 'plan' action '$($a[0])' (jk plan | jk plan week | jk plan start)"
}
