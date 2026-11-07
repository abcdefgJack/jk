# next.ps1 - jk next: the one thing to do now, and what follows it.
# In order: an exam under way or within 6 hours, a class starting within 45 minutes, work due within
# 12 hours, to-dos due today, then the study jk plan has for today; each with the command that does it.

function Get-JkNextSteps([datetime]$Now = (Get-JkNow)) {
    $data = Get-JkDueData
    $cmap = Get-JkCourseMap $data
    $out = New-Object System.Collections.Generic.List[object]
    $add = { param($text, $hint) $out.Add([pscustomobject]@{ Text = $text; Hint = $hint }) }
    # a deadline with no time counts to the end of its day; an online quiz shows once, at its close
    $ahead = @($data.events | Where-Object { -not $_.done -and [string]$_.title -notmatch '(?i)\sopens?$' } |
            ForEach-Object { [pscustomobject]@{ E = $_; Due = (Get-JkEventDue $_); Closes = ([string]$_.title -match '(?i)\s+closes?$') } } | Where-Object { $_.Due -gt $Now } | Sort-Object Due)
    $name = { param($e) "$(Get-JkCourseLabel $e $cmap) $(([string]$e.title -replace '(?i)\s+closes?$', '').Trim())" }
    $key = { param($e) $c = @($data.courses | Where-Object { $_.key -eq $e.course })[0]; $k = Get-JkNormKey ([string]$c.code); if ($k) { $k } else { [string]$e.course } }
    $within = { param($x, [double]$Hours) if ($x.E.time) { ($x.Due - $Now).TotalHours -le $Hours } else { $x.Due.Date -eq $Now.Date } }
    $clock = { param($x) "$(Format-JkTime $x.E.time) (in $(Format-JkDuration (Get-JkTimeLeft $x.Due $Now)))" }
    $shown = New-Object System.Collections.Generic.List[string]

    # an exam under way: until it ends, nothing else is what is happening now
    foreach ($e in @($data.events | Where-Object { -not $_.done -and $_.kind -eq 'exam' -and $_.time -and (Get-JkProp $_ 'end' '') })) {
        $start = Get-JkEventDue $e
        $part = ([string]$e.end).Split(':')
        $stop = $start.Date.AddHours([int]$part[0]).AddMinutes([int]$part[1])
        if ($Now -ge $start -and $Now -lt $stop) {
            $where = Get-JkExamNote $e
            & $add "$(& $name $e), under way until $(Format-JkTime ([string]$e.end))" $(if ($where) { $where } else { 'the rest can wait until it ends' })
        }
    }
    # an exam within 6 hours: the last review, then getting there
    foreach ($x in @($ahead | Where-Object { $_.E.kind -eq 'exam' -and -not $_.Closes -and (& $within $_ 6) })) {
        $where = Get-JkExamNote $x.E
        $hint = "jk exam $(& $key $x.E)"
        if ($where -notmatch '(?i)\bonline\b') { $hint = (@('leave in time', $where, $hint) | Where-Object { $_ }) -join " $($script:G.dot) " }
        & $add "$(& $name $x.E) $(if ($x.E.time) { "at $(& $clock $x)" } else { 'today' })" $hint
        $shown.Add("$($x.E.course)|#$($x.E.id)")
    }
    # a class starting within 45 minutes (or under way)
    try {
        foreach ($m in @(Get-JkClassesOn $Now.Date | Where-Object { $_.End -gt $Now -and ($_.Start - $Now).TotalMinutes -le 45 })) {
            $room = $(if ($m.Class.room) { " in $($m.Class.room)" } else { '' })
            $when = $(if ($m.Start -le $Now) { "now, until $(Format-JkTime $m.End.ToString('HH:mm', $script:Inv))" } else { "at $(Format-JkTime $m.Start.ToString('HH:mm', $script:Inv)) (in $(Format-JkDuration ($m.Start - $Now)))" })
            & $add "$(Format-JkClassLabel $m.Class $cmap)$room $when" 'jk class'
        }
    } catch { }
    # work due within 12 hours, or today if it has no time; an online quiz closing counts as work
    foreach ($x in @($ahead | Where-Object { (($_.E.kind -ne 'exam' -and $_.E.kind -ne 'appt') -or $_.Closes) -and (& $within $_ 12) })) {
        if ($x.Closes) { & $add "$(& $name $x.E) closes $(& $clock $x)" "write it, then jk due done $($x.E.id)" }
        elseif ($x.E.time) { & $add "$(& $name $x.E), due $(& $clock $x)" "hand it in, then jk due done $($x.E.id)" }
        else { & $add "$(& $name $x.E), due today" "hand it in, then jk due done $($x.E.id)" }
        $shown.Add("$($x.E.course)|#$($x.E.id)")
    }
    # an interview or appointment within 6 hours
    foreach ($x in @($ahead | Where-Object { $_.E.kind -eq 'appt' -and $_.E.time -and ($_.Due - $Now).TotalHours -le 6 })) {
        & $add "$(& $name $x.E) at $(& $clock $x)" $(if ($x.E.note) { [string]$x.E.note } else { 'be ready a few minutes early' })
        $shown.Add("$($x.E.course)|#$($x.E.id)")
    }
    # to-dos due today (or overdue)
    try {
        foreach ($t in @((Get-JkTodoData).items | Where-Object { -not $_.done -and ($d = Get-JkTodoDue $_) -and $d.Date -le $Now.Date } | Sort-Object { Get-JkTodoDue $_ })) {
            $d = Get-JkTodoDue $t
            $when = $(if ($d.Date -lt $Now.Date) { "overdue since $($d.ToString('ddd', $script:Inv))" } elseif ($d.TimeOfDay.TotalMinutes -gt 0) { "by $(Format-JkTime $d.ToString('HH:mm', $script:Inv))" } else { 'today' })
            & $add "$($t.text) ($when)" "jk todo done $($t.id)"
        }
    } catch { }
    # the study jk plan has for today, biggest first (what is due tonight is already above)
    try {
        $p = Get-JkPlanToday
        if ($p) {
            $its = @($p.Items | Where-Object { [double]$p.Today.Alloc[$_.Key] -gt 0 -and -not $shown.Contains($_.Key) } | Sort-Object { [double]$p.Today.Alloc[$_.Key] } -Descending)
            foreach ($it in $its) {
                $c = Get-JkCourseLabel ([pscustomobject]@{ course = $it.Course }) $cmap
                & $add "Study $c $($it.Title): $(Format-JkMinutes ([double]$p.Today.Alloc[$it.Key])) planned today" 'jk plan start'
            }
        }
    } catch { }
    if (-not $out.Count) {
        $n = @($ahead)[0]
        $txt = 'Nothing pressing.'
        if ($n) { $txt += " Next: $(& $name $n.E), $($n.Due.ToString('ddd MMM d', $script:Inv)) (in $([int]($n.Due.Date - $Now.Date).TotalDays) days)" }
        & $add $txt 'jk for the week'
    }
    $out.ToArray()
}

function Show-JkNext {
    $now = Get-JkNow
    $steps = @(Get-JkNextSteps $now)
    Write-JkHeader 'Next' "$($now.ToString('ddd', $script:Inv)) $(Format-JkTime $now.ToString('HH:mm', $script:Inv))"
    $i = 0
    foreach ($s in @($steps | Select-Object -First 3)) {
        $label = $(if ($i -eq 0) { 'now' } else { 'then' })
        $style = $(if ($i -eq 0) { 'bold white' } else { 'white' })
        Write-JkTip ('  ' + (Paint $(if ($i -eq 0) { 'bold green' } else { 'gray' }) (Fit $label 6))) 8 $s.Text $style -Indent 8
        Say ((' ' * 8) + (Paint 'gray' "$($script:G.arrow) $($s.Hint)"))
        $i++
    }
    if ($steps.Count -gt 3) { Say (Paint 'gray' "  +$($steps.Count - 3) more $($script:G.dot) jk for everything") }
}
