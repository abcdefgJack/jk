# plan.ps1 - jk plan: split today's study time across what is coming up.
# Each graded item due in the next two weeks gets a work estimate from its weight
# (exams: plan.examMin minutes per percent, others: plan.dueMin per percent). Focus time
# already logged on the course is subtracted, the rest is spread over the days left, and
# today's shares are fitted into the daily budget (plan.hours) as 25-minute blocks.

$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:PlanBlock = 25

function Get-JkPlanItems {
    param([datetime]$Now = (Get-JkNow), [int]$HorizonDays = 14)
    $data = Get-JkDueData -Cached
    $fd = Get-JkFocusData
    $examPer = [double](Get-JkConfig 'plan.examMin')
    $duePer = [double](Get-JkConfig 'plan.dueMin')
    $groups = @{}
    foreach ($e in @($data.events)) {
        if ($e.done) { continue }
        $w = Get-JkWeightValue $e.weight
        if ($w -le 0) { continue }
        $due = Get-JkEventDue $e
        if ($due -le $Now -or $due -gt $Now.AddDays($HorizonDays)) { continue }
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
            $groups[$key] = [pscustomobject]@{ Key = $key; Course = [string]$e.course; Title = $norm; Due = $due; Weight = $w; Kind = [string]$e.kind; Id = $e.id; Effort = $w * $per; Done = 0.0 }
        }
    }
    $items = @($groups.Values)
    # resolve each session's course once (labels repeat a lot)
    $sessions = foreach ($s in @($fd.sessions)) {
        $first = ([string]$s.label -split '\s+')[0]
        if (-not $first) { continue }
        $c = Resolve-JkCourse $data $first
        if ($c) { [pscustomobject]@{ Course = $c.key; Start = [datetime]::Parse([string]$s.start, $script:Inv); Minutes = [double]$s.actual } }
    }
    # focus already logged on a course since two weeks before an item counts toward it,
    # shared between that course's items in proportion to their effort. Time before the course's
    # last finished item was spent on that item, so it does not count.
    foreach ($course in ($items | Group-Object Course)) {
        $courseItems = @($course.Group)
        $since = ($courseItems | ForEach-Object { $_.Due.AddDays(-14) } | Measure-Object -Minimum).Minimum
        foreach ($f in @($data.events | Where-Object { $_.course -eq $course.Name -and $_.done })) {
            $at = Get-JkDoneAt $f
            if ($at -and $at -gt $since -and $at -le $Now) { $since = $at }
        }
        $logged = 0.0
        foreach ($s in @($sessions)) {
            if ($s.Course -eq $course.Name -and $s.Start -ge $since -and $s.Start -le $Now) { $logged += $s.Minutes }
        }
        $total = ($courseItems | Measure-Object -Property Effort -Sum).Sum
        foreach ($it in $courseItems) { if ($total -gt 0) { $it.Done = [Math]::Min($it.Effort, $logged * $it.Effort / $total) } }
    }
    @($items | Sort-Object Due)
}

# Minutes per item for each of the next $Days days (index 0 = today). Each day, every item
# asks for remaining / days-left; asks are scaled to the budget, rounded to blocks, and
# anything due within two days always gets at least one block.
function Get-JkPlanSchedule {
    param($Items, [datetime]$Now = (Get-JkNow), [int]$Days = 7, [double]$BudgetMin = 180, [double]$TodayLeftFraction = 1.0)
    $remaining = @{}
    $byKey = @{}
    foreach ($it in $Items) { $remaining[$it.Key] = [Math]::Max(0, $it.Effort - $it.Done); $byKey[$it.Key] = $it }
    $sched = @()
    for ($d = 0; $d -lt $Days; $d++) {
        $day = $Now.Date.AddDays($d)
        $budget = $BudgetMin
        if ($d -eq 0) { $budget = $BudgetMin * $TodayLeftFraction }
        $asks = @{}
        foreach ($it in $Items) {
            if ($it.Due.Date -lt $day -or $remaining[$it.Key] -le 0) { continue }
            # days available count today and stop the day before the due date, plus the due day itself
            # when the item is at noon or later (a 4:30 pm midterm leaves its morning for review),
            # and today only while more than an hour is left
            $usableDueDay = $it.Due.Hour -ge 12
            $daysLeft = [Math]::Max(1, ($it.Due.Date - $day).TotalDays + $(if ($usableDueDay) { 1 } else { 0 }))
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
            if ($m -gt 0) { $alloc[$k] = $m; $remaining[$k] = [Math]::Max(0, $remaining[$k] - $m) }
        }
        $sched += [pscustomobject]@{ Day = $day; Alloc = $alloc; Need = $sum; Budget = $budget }
    }
    $sched
}

# Focus minutes logged today per course key.
function Get-JkTodayFocusByCourse([datetime]$Now = (Get-JkNow)) {
    $data = Get-JkDueData -Cached
    $out = @{}
    foreach ($s in @((Get-JkFocusData).sessions)) {
        $start = [datetime]::Parse([string]$s.start, $script:Inv)
        if ($start.Date -ne $Now.Date) { continue }
        $first = ([string]$s.label -split '\s+')[0]
        $c = $null; if ($first) { $c = Resolve-JkCourse $data $first }
        if ($c) { $out[$c.key] = [double]$out[$c.key] + [double]$s.actual }
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
    $sched = @(Get-JkPlanSchedule -Items $items -Now $now -Days 7 -BudgetMin $budget -TodayLeftFraction $frac)
    [pscustomobject]@{ Items = $items; Schedule = $sched; Today = $sched[0]; Budget = $budget; BudgetKey = $budgetKey }
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
    if (-not $p) { Say (Paint 'green' '  Nothing graded is due in the next two weeks.'); return }
    $logged = Get-JkTodayFocusByCourse $now
    $today = $p.Today
    Say (' ' + (Paint 'bold white' 'Today'))
    if ($today.Alloc.Count -eq 0) { Say (Paint 'green' '  nothing scheduled for today') }
    $order = @($p.Items | Where-Object { $today.Alloc.ContainsKey($_.Key) } | Sort-Object @{ Expression = { $today.Alloc[$_.Key] }; Descending = $true }, Due)
    foreach ($it in $order) {
        $m = $today.Alloc[$it.Key]
        $color = Get-JkCourseColor $it.Course $cmap
        $code = Get-JkCourseLabel ([pscustomobject]@{ course = $it.Course }) $cmap
        $days = [int]($it.Due.Date - $now.Date).TotalDays
        $when = $it.Due.ToString('ddd', $script:Inv); if ($days -eq 0) { $when = 'today' } elseif ($days -eq 1) { $when = 'tmrw' }
        $blocks = Paint "#$color" ($script:G.full * [int]($m / $script:PlanBlock))
        $left = [Math]::Max(0, $it.Effort - $it.Done)
        Say ('  ' + (Paint "bold #$color" (Fit $code 11)) + (Paint 'white' (Fit "$($it.Title)" 24)) + (Paint 'muted' (Fit "$when $($script:G.dot) $($it.Weight)%" 13)) + (Paint 'bold white' (Fit (Format-JkMinutes $m) 7 -Right)) + '  ' + $blocks + (Paint 'gray' "   ~$(Format-JkMinutes $left) of work left"))
    }
    $planned = 0.0; foreach ($v in $today.Alloc.Values) { $planned += $v }
    $doneToday = 0.0; foreach ($v in $logged.Values) { $doneToday += $v }
    Say ''
    $prog = 0.0; if ($planned -gt 0) { $prog = [Math]::Min(1, $doneToday / $planned) }
    Say ('  ' + (Get-JkBar $prog 30 'green') + '  ' + (Paint 'white' "$(Format-JkMinutes $doneToday) of $(Format-JkMinutes $planned) focused today"))
    if ($today.Need -gt $today.Budget * 1.15) {
        Say ('  ' + (Paint 'orange' "! the next deadlines want ~$(Format-JkMinutes $today.Need) today; the plan is squeezed into your budget"))
    }

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

# The planned item with the most unfocused minutes left today.
function Get-JkPlanNext($Plan, $Logged) {
    if (-not $Plan) { return $null }
    $best = $null; $bestLeft = 0
    $usedByCourse = @{}
    foreach ($k in $Logged.Keys) { $usedByCourse[$k] = $Logged[$k] }
    foreach ($it in @($Plan.Items | Where-Object { $Plan.Today.Alloc.ContainsKey($_.Key) } | Sort-Object Due)) {
        $want = $Plan.Today.Alloc[$it.Key]
        $used = [Math]::Min($want, [double]$usedByCourse[$it.Course])
        $usedByCourse[$it.Course] = [double]$usedByCourse[$it.Course] - $used
        $left = $want - $used
        if ($left -gt $bestLeft) { $best = $it; $bestLeft = $left }
    }
    $best
}

function Start-JkPlanBlock {
    $p = Get-JkPlanToday
    $next = Get-JkPlanNext $p (Get-JkTodayFocusByCourse)
    if (-not $next) { Say (Paint 'green' "  Today's plan is covered. $($script:G.check)"); return }
    Start-JkFocus ([string]$script:PlanBlock) @($next.Course, $next.Title)
}

# One line for the dashboard: today's blocks per course.
function Get-JkPlanLine {
    $p = Get-JkPlanToday
    if (-not $p -or $p.Today.Alloc.Count -eq 0) { return $null }
    $cmap = Get-JkCourseMap (Get-JkDueData -Cached)
    $logged = Get-JkTodayFocusByCourse
    $byCourse = @{}
    foreach ($it in $p.Items) { if ($p.Today.Alloc.ContainsKey($it.Key)) { $byCourse[$it.Course] = [double]$byCourse[$it.Course] + $p.Today.Alloc[$it.Key] } }
    $parts = foreach ($c in ($byCourse.Keys | Sort-Object { $byCourse[$_] } -Descending)) {
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
        '^(help|-h|--help|\?)$' { Show-JkHelp 'plan'; return }
    }
    throw "unknown 'plan' action '$($a[0])' (jk plan | jk plan start)"
}
