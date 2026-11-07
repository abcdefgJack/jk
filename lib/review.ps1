# review.ps1 - jk review: the last 7 days and the next 7, on one screen.
# Looks back (deadlines finished, to-dos done, focus time per course, anything that slipped
# past without a check mark) and ahead (load per day, and which course carries the most
# grade weight this week, i.e. where study time pays off most).

$script:Inv = [Globalization.CultureInfo]::InvariantCulture

function Get-JkDoneAt($Item) {
    $v = Get-JkProp $Item 'doneAt'
    if (-not $v) { return $null }
    try { [datetime]::Parse([string]$v, $script:Inv) } catch { $null }
}

function Show-JkReview {
    param([int]$Days = 7)
    if ($Days -lt 1 -or $Days -gt 366) { throw 'jk review takes 1 to 366 days' }
    $now = Get-JkNow
    $from = $now.Date.AddDays(-$Days + 1)
    $to = $now.Date.AddDays($Days)
    $data = Get-JkDueData
    $cmap = Get-JkCourseMap $data
    $info = Get-JkTermInfo $data $now
    $w = Get-JkWidth
    Write-JkHeader 'Weekly review' (Format-JkTermLine $info) -Sub "$($from.ToString('MMM d', $script:Inv)) $($script:G.dash) $($now.ToString('MMM d', $script:Inv))"

    # ---- looking back
    $doneDue = @($data.events | Where-Object { $_.done -and ($d = Get-JkDoneAt $_) -and $d -ge $from })
    $td = Get-JkTodoData
    $doneTodo = @($td.items | Where-Object { $_.done -and ($d = Get-JkDoneAt $_) -and $d -ge $from })
    $fd = Get-JkFocusData
    $sessions = @($fd.sessions | Where-Object { [datetime]::Parse([string]$_.start, $script:Inv) -ge $from })
    $focusMin = ($sessions | Measure-Object -Property actual -Sum).Sum
    if (-not $focusMin) { $focusMin = 0 }
    $slipped = @($data.events | Where-Object { -not $_.done -and $_.kind -eq 'due' -and ($due = Get-JkEventDue $_) -lt $now -and $due -ge $from } | Sort-Object { Get-JkEventDue $_ })

    Say (' ' + (Paint 'bold white' 'Last 7 days'))
    $bits = @(
        (Paint 'green' "$($script:G.check) $($doneDue.Count) deadline$(if ($doneDue.Count -ne 1) {'s'}) done"),
        (Paint 'green' "$($script:G.check) $($doneTodo.Count) to-do$(if ($doneTodo.Count -ne 1) {'s'})"),
        (Paint 'cyan' "$($script:G.circle) $(Format-JkMinutes $focusMin) focused")
    )
    Say ('  ' + ($bits -join '   '))
    if ($sessions.Count) {
        $byCourse = $sessions | Group-Object { $l = ([string]$_.label -split '\s+')[0]; $c = $null; if ($l) { $c = Resolve-JkCourse $data $l }; if ($c) { $c.key } else { '(other)' } } | ForEach-Object {
            [pscustomobject]@{ Key = $_.Name; Minutes = ($_.Group | Measure-Object -Property actual -Sum).Sum }
        } | Sort-Object Minutes -Descending
        $parts = foreach ($b in $byCourse) {
            $label = $b.Key; $color = 'muted'
            if ($cmap[$b.Key]) { $label = $cmap[$b.Key].code; $color = "#$(Get-JkCourseColor $b.Key $cmap)" }
            (Paint $color $label) + (Paint 'gray' " $(Format-JkMinutes $b.Minutes)")
        }
        Say ('    ' + (Paint 'gray' 'focus by course: ') + ($parts -join (Paint 'gray' '  ')))
    }
    if ($slipped.Count) {
        Say ''
        Say ('  ' + (Paint 'yellow' "! $($slipped.Count) passed without a check mark") + (Paint 'gray' ' (done? jk due done <ids>; dropped? jk due rm <id>)'))
        foreach ($e in ($slipped | Select-Object -First 6)) {
            $due = Get-JkEventDue $e
            Say ('    ' + (Paint 'gray' ("#$($e.id)".PadLeft(4))) + '  ' + (Paint "#$(Get-JkCourseColor $e.course $cmap)" (Fit (Get-JkCourseLabel $e $cmap) 11)) + (Fit ([string]$e.title) 30) + (Paint 'muted' $due.ToString('ddd MMM d', $script:Inv)))
        }
    }

    # job search: applications this week against the week before, and what is still on you
    try {
        $jobs = @(Get-JkJobs -Cached)
        if ($jobs.Count) {
            $sent = @($jobs | Where-Object { $_.State -eq 'applied' })
            $thisWk = @($sent | Where-Object { $_.Date -ge $from -and $_.Date -le $now.Date }).Count
            $prevWk = @($sent | Where-Object { $_.Date -ge $from.AddDays(-$Days) -and $_.Date -lt $from }).Count
            $waiting = @(Get-JkJobsWaiting $now).Count
            $txt = "$thisWk application$(if ($thisWk -ne 1) {'s'}) sent" + (Paint 'gray' " (week before: $prevWk)")
            if ($waiting) { $txt += (Paint 'gray' "  $($script:G.dot)  ") + (Paint 'amber' "$waiting waiting on you") }
            Say ''
            Say ('  ' + (Paint 'purple' "$($script:G.circle) job search  ") + $txt + (Paint 'gray' "   $($script:G.arrow) jk jobs"))
        }
    } catch { }

    # ---- looking ahead
    $ahead = @($data.events | Where-Object { -not $_.done -and ($due = Get-JkEventDue $_) -ge $now -and $due -lt $to.AddDays(1) } | Sort-Object { Get-JkEventDue $_ })
    Say ''
    Say (' ' + (Paint 'bold white' "Next $Days days") + (Paint 'gray' "  $($now.ToString('MMM d', $script:Inv)) $($script:G.dash) $($to.ToString('MMM d', $script:Inv))"))
    if ($ahead.Count -eq 0) { Say (Paint 'green' '  Nothing due. A good week to get ahead.'); return }
    $exams = @($ahead | Where-Object { $_.kind -eq 'exam' }).Count
    $byDay = $ahead | Group-Object { (Get-JkEventDue $_).Date.ToString('yyyy-MM-dd') } | Sort-Object Count -Descending
    $busiest = $byDay | Select-Object -First 1
    $busyTxt = ''
    if ($busiest.Count -gt 1) { $busyTxt = "  $($script:G.dot)  busiest: " + ([datetime]::ParseExact($busiest.Name, 'yyyy-MM-dd', $script:Inv)).ToString('ddd MMM d', $script:Inv) + " ($($busiest.Count) items)" }
    Say ('  ' + (Paint 'white' (Format-JkCount $ahead.Count 'item')) + (Paint 'gray' "  $($script:G.dot)  $(Format-JkCount $exams 'exam')$busyTxt"))

    # day strip: one cell per day with a dot per item (exams solid)
    $strip = '  '
    for ($i = 0; $i -le $Days; $i++) {
        $d = $now.Date.AddDays($i)
        $items = @($ahead | Where-Object { (Get-JkEventDue $_).Date -eq $d })
        $dots = ''
        foreach ($e in $items) {
            $g = $script:G.ring; if ($e.kind -eq 'exam') { $g = $script:G.circle }
            $dots += Paint "#$(Get-JkCourseColor $e.course $cmap)" $g
        }
        $label = $d.ToString('ddd', $script:Inv)
        if ($i -eq 0) { $label = 'tod' }
        $strip += (Paint 'muted' $label) + ' ' + $dots + (' ' * [Math]::Max(1, 5 - $items.Count)) + ' '
    }
    Say $strip

    # where the weight is: per course, sum of grade weight due this week
    $weights = $ahead | Where-Object { (Get-JkWeightValue $_.weight) -gt 0 } | Group-Object course | ForEach-Object {
        $items = @($_.Group)
        # an exam window (opens + closes) counts once
        $seen = @{}; $sum = 0.0; $names = @()
        foreach ($e in $items) {
            $norm = ([string]$e.title -replace '(?i)\s+(opens?|closes?)$', '').Trim()
            if ($seen.ContainsKey($norm)) { continue }
            $seen[$norm] = $true
            $sum += Get-JkWeightValue $e.weight
            $names += "$norm ($($e.weight))"
        }
        [pscustomobject]@{ Course = $_.Name; Weight = $sum; Items = $names }
    } | Sort-Object Weight -Descending
    if ($weights) {
        Say ''
        Say (' ' + (Paint 'bold white' 'Where the marks are') + (Paint 'gray' '  (share of each course''s grade due this week)'))
        $max = ($weights | Measure-Object -Property Weight -Maximum).Maximum
        foreach ($r in $weights) {
            $color = Get-JkCourseColor $r.Course $cmap
            $code = $r.Course; if ($cmap[$r.Course]) { $code = $cmap[$r.Course].code }
            Say ('  ' + (Paint "bold #$color" (Fit $code 11)) + (Get-JkBar ($r.Weight / $max) 16 "#$color") + (Paint 'white' (Fit (Format-JkPct $r.Weight 1) 8 -Right)) + '  ' + (Paint 'gray' (Fit ($r.Items -join ', ') ($w - 42)).TrimEnd()))
        }
        $top = $weights | Select-Object -First 1
        $topCode = $top.Course; if ($cmap[$top.Course]) { $topCode = $cmap[$top.Course].code }
        Say ''
        Say ('  ' + (Paint 'gray' 'suggestion: ') + "start with $(Paint "bold #$(Get-JkCourseColor $top.Course $cmap)" $topCode)" + (Paint 'gray' "  $($script:G.arrow) jk focus 50 $($top.Course)"))
    }
}
