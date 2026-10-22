# dash.ps1 - `jk` with no arguments (the daily dashboard) and `jk brief` (one line for the profile).

$script:JkTips = @(
    'jk due done a2a        marks a deadline done by matching its title',
    'jk due week            shows the next two weeks as a grid',
    'jk due ics             exports deadlines for Google Calendar / Outlook (phone alerts)',
    'jk grade set 23 17/20  records a mark; jk grade cs350 shows what you need on the final',
    'jk focus 50 cs350      starts a 50-minute focus block with a popup at the end',
    'jk in 20m "stretch"    pops up a reminder in 20 minutes',
    'jk at 5pm "leave"      pops up a reminder at 5 pm',
    'jk cp new A            scaffolds a contest problem; jk cp tests it against samples',
    'jk cp add              turns the clipboard into the next sample test',
    'jk tidy                shows what is cluttering Downloads; jk tidy apply sorts it (undoable)',
    'jk port 8080 -Kill     frees a port held by a stuck dev server',
    'j co250                jumps to a folder by fuzzy name; j - goes back',
    'jk mark                bookmarks the current folder for j',
    'jk repos               shows uncommitted/unpushed work across every repo',
    'jk sys                 CPU, memory, disks, battery and the apps eating RAM',
    'jk todo "email TA"     adds a to-do; jk todo done 1 checks it off',
    'jk review              last week done/slipped, next week load, where the marks are',
    'jk class week          this week''s timetable; jk class import reads Quest''s list view',
    'jk space               what is filling the disk, with the right cleanup for each',
    'jk exams               every remaining exam with a countdown'
)

function Get-JkGreeting([datetime]$Now) {
    $h = $Now.Hour
    if ($h -lt 5) { return 'Up late' }
    if ($h -lt 12) { return 'Good morning' }
    if ($h -lt 18) { return 'Good afternoon' }
    'Good evening'
}

function Show-JkDashboard {
    $now = Get-JkNow
    $w = Get-JkWidth
    $name = Get-JkConfig 'name'
    $data = Get-JkDueData -Cached
    $cmap = Get-JkCourseMap $data
    $info = Get-JkTermInfo $data $now

    Say ''
    $left = " $(Get-JkGreeting $now), $name."
    $right = $now.ToString('dddd, MMMM d', [Globalization.CultureInfo]::InvariantCulture) + '  ' + (Format-JkTime $now.ToString('HH:mm'))
    Say ((Paint 'bold white' $left) + (' ' * [Math]::Max(2, $w - $left.Length - $right.Length - 1)) + (Paint 'muted' $right))
    $termLine = Format-JkTermLine $info
    if ($termLine) { Say (' ' + (Paint 'gray' $termLine)) }
    Say (Paint 'gray dim' (' ' + ($script:G.hline * ($w - 1))))

    # next exam callout
    $nextExam = @($data.events | Where-Object { $_.kind -eq 'exam' -and -not $_.done -and (Get-JkEventDue $_) -ge $now } | Sort-Object { Get-JkEventDue $_ } | Select-Object -First 1)
    if ($nextExam) {
        $e = $nextExam[0]
        $due = Get-JkEventDue $e
        $days = [int]($due.Date - $now.Date).TotalDays
        $color = Get-JkCourseColor $e.course $cmap
        $when = $due.ToString('ddd MMM d', [Globalization.CultureInfo]::InvariantCulture)
        if ($e.time) { $when += ' ' + (Format-JkTime $e.time) }
        $cd = "in $days days"; if ($days -eq 0) { $cd = 'TODAY' } elseif ($days -eq 1) { $cd = 'tomorrow' }
        Say (' ' + (Paint "bold bg:#$color ink" ' NEXT EXAM ') + ' ' + (Paint "bold #$color" (Get-JkCourseLabel $e $cmap)) + ' ' + (Paint 'bold white' ([string]$e.title)) + (Paint 'muted' "  $cd $($script:G.dot) $when") + $(if ($e.weight) { Paint 'gray' "  $($e.weight)" } else { '' }))
    }

    # next class (today or tomorrow), with how many are left today
    try {
        $nc = Get-JkNextClass $now 1
        if ($nc) {
            $cw = Get-JkClassWhen $nc $now
            $color = Get-JkCourseColor $nc.Class.course $cmap
            $leftToday = @(Get-JkClassesOn $now.Date | Where-Object { $_.End -gt $now }).Count
            $extra = ''
            if ($nc.Start.Date -eq $now.Date -and $leftToday -gt 1) { $extra = Paint 'gray' "  +$($leftToday - 1) more today" }
            $label = ' NEXT CLASS '; if ($nc.Start -le $now) { $label = '  IN CLASS  ' }
            Say (' ' + (Paint "bold bg:#$color ink" $label) + ' ' + (Paint "bold #$color" (Format-JkClassLabel $nc.Class $cmap)) + '  ' + (Paint $cw[1] $cw[0]) + (Paint 'muted' "  $($script:G.dot) $($nc.Class.room)") + $extra)
        }
    } catch { }

    # deadlines for the next 7 days
    $soon = @($data.events | Where-Object { -not $_.done } | Where-Object { $d = Get-JkEventDue $_; $d -ge $now -and $d -lt $now.Date.AddDays(8) } | Sort-Object { Get-JkEventDue $_ })
    Say ''
    Say (' ' + (Paint 'bold white' 'THIS WEEK') + (Paint 'gray' "  $($soon.Count) due in 7 days"))
    if ($soon.Count -eq 0) { Say (Paint 'green' "  Nothing due in the next 7 days. $($script:G.check)") }
    $shown = 0
    foreach ($e in $soon) {
        if ($shown -ge 8) { break }
        $due = Get-JkEventDue $e
        $n = [int]($due.Date - $now.Date).TotalDays
        $dayTxt = $due.ToString('ddd', [Globalization.CultureInfo]::InvariantCulture)
        $dst = 'muted'
        if ($n -eq 0) { $dayTxt = 'today'; $dst = 'bold red' } elseif ($n -eq 1) { $dayTxt = 'tmrw'; $dst = 'bold orange' } elseif ($n -le 3) { $dst = 'yellow' }
        $color = Get-JkCourseColor $e.course $cmap
        $time = Format-JkTime ([string]$e.time)
        $tag = ''; if ($e.kind -eq 'exam') { $tag = ' ' + (Paint "bold bg:#$color ink" ' EXAM ') }
        $titleW = [Math]::Max(12, $w - 46)
        $line = '  ' + (Paint $dst (Fit $dayTxt 6)) + (Paint 'gray' (Fit ($due.ToString('MMM d', [Globalization.CultureInfo]::InvariantCulture)) 7)) + (Paint "bold #$color" (Fit (Get-JkCourseLabel $e $cmap) 11)) + (Paint 'white' (Fit ([string]$e.title) $titleW)) + (Paint 'muted' (Fit $time 9 -Right)) + (Paint 'gray' (Fit ([string]$e.weight) 7 -Right)) + $tag
        Say $line
        $shown++
    }
    if ($soon.Count -gt $shown) { Say (Paint 'gray' "  +$($soon.Count - $shown) more $($script:G.arrow) jk due") }

    # today's study blocks from jk plan
    try {
        $planLine = Get-JkPlanLine
        if ($planLine) {
            Say ''
            Say (' ' + (Paint 'bold white' 'STUDY TODAY') + '  ' + $planLine + (Paint 'gray' "   $($script:G.arrow) jk plan start"))
        }
    } catch { }

    # to-dos
    $td = Get-JkTodoData
    $open = @($td.items | Where-Object { -not $_.done } | Sort-Object @{ Expression = { $x = Get-JkTodoDue $_; if ($x) { $x } else { [datetime]::MaxValue } } }, id)
    if ($open.Count) {
        Say ''
        Say (' ' + (Paint 'bold white' 'TO-DO') + (Paint 'gray' "  $($open.Count) open"))
        foreach ($i in ($open | Select-Object -First 5)) { Say (Format-JkTodoLine $i $w $now) }
        if ($open.Count -gt 5) { Say (Paint 'gray' "  +$($open.Count - 5) more $($script:G.arrow) jk todo") }
    }

    # reminders + focus
    $rem = @(Get-JkReminderList | Where-Object { [datetime]::Parse([string]$_.at, [Globalization.CultureInfo]::InvariantCulture) -ge (Get-Date) })
    $fd = Get-JkFocusData
    $todayMin = Get-JkFocusMinutes ((Get-Date).Date) $fd
    $weekStart = (Get-Date).Date.AddDays(-(([int](Get-Date).DayOfWeek + 6) % 7))
    $weekMin = Get-JkFocusMinutes $weekStart $fd
    $bits = @()
    if ($fd.active) {
        $a = $fd.active
        $left = [datetime]::Parse([string]$a.start, [Globalization.CultureInfo]::InvariantCulture).AddSeconds([double]$a.seconds) - (Get-Date)
        if ($left.TotalSeconds -gt 0) { $bits += (Paint 'bold green' "$($script:G.circle) focusing") + (Paint 'muted' " $(if ($a.label) { $a.label + ' ' })$(Format-JkDuration $left) left") }
    }
    if ($todayMin -gt 0 -or $weekMin -gt 0) { $bits += (Paint 'muted' "focus today $(Format-JkMinutes $todayMin) $($script:G.dot) week $(Format-JkMinutes $weekMin)") }
    if ($rem.Count) {
        $nr = $rem[0]
        $at = [datetime]::Parse([string]$nr.at, [Globalization.CultureInfo]::InvariantCulture)
        $bits += (Paint 'amber' "$($script:G.circle) $($rem.Count) reminder$(if ($rem.Count -ne 1) {'s'})") + (Paint 'muted' " next $(Format-JkTime $at.ToString('HH:mm')): $($nr.text)")
    }
    if ($bits.Count) { Say ''; Say ('  ' + ($bits -join (Paint 'gray' "   $($script:G.vline)  "))) }

    # machine
    Say ''
    $sysBits = @()
    try {
        $c = New-Object IO.DriveInfo ($env:SystemDrive)
        $free = $c.AvailableFreeSpace / $c.TotalSize
        $st = 'muted'; if ($free -lt 0.1) { $st = 'red' } elseif ($free -lt 0.2) { $st = 'orange' }
        $hint = ''; if ($free -lt 0.2) { $hint = Paint 'gray' " $($script:G.arrow) jk space" }
        $sysBits += (Paint $st "$($env:SystemDrive) $(Format-JkSize $c.AvailableFreeSpace) free") + $hint
    } catch { }
    try {
        $mem = Get-JkMemory
        $memUsed = 1 - ($mem.Free / $mem.Total)
        $st = 'muted'; if ($memUsed -gt 0.9) { $st = 'red' } elseif ($memUsed -gt 0.8) { $st = 'orange' }
        $sysBits += Paint $st ("RAM {0:N0}%" -f ($memUsed * 100))
        $upDays = (Get-JkUptime).TotalDays
        if ($upDays -ge 7) { $sysBits += Paint 'yellow' "up $([int]$upDays)d (restart?)" }
    } catch { }
    try {
        $bat = Get-JkBattery
        if ($bat) {
            $st = 'muted'; if ($bat.Percent -le 20 -and -not $bat.Plugged) { $st = 'red' }
            $sysBits += Paint $st "battery $($bat.Percent)%"
        }
    } catch { }
    try {
        $dl = Get-JkDownloadsPath
        $files = @(Get-ChildItem -LiteralPath $dl -File -Force -ErrorAction Stop)
        $size = ($files | Measure-Object Length -Sum).Sum
        $st = 'muted'; $hint = ''
        if ($files.Count -gt 150 -or $size -gt 5GB) { $st = 'orange'; $hint = Paint 'gray' " $($script:G.arrow) jk tidy" }
        $sysBits += (Paint $st "Downloads $($files.Count) files / $(Format-JkSize $size)") + $hint
    } catch { }
    Say ('  ' + ($sysBits -join (Paint 'gray' "  $($script:G.dot)  ")))

    Say ''
    if ($now.DayOfWeek -eq 'Sunday') {
        Say ('  ' + (Paint 'cyan' "$($script:G.star) Sunday: ") + (Paint 'white' 'look back at the week and plan the next one') + (Paint 'gray' "  $($script:G.arrow) jk review"))
    } else {
        $tip = $script:JkTips[(Get-Random -Maximum $script:JkTips.Count)]
        Say (Paint 'gray' "  tip: $tip")
    }
}

# One line, shown by the profile hook when a terminal opens. The rendered line is cached
# (brief.cache: hour stamp + ANSI line) so new shells print it without loading the module;
# saving deadlines or to-dos deletes the cache.
function Show-JkBrief {
    param([switch]$Force)
    $off = (Get-JkConfig 'banner') -eq 'off'
    $useColor = $script:JkUseColor
    $script:JkUseColor = $true
    try { $line = Get-JkBriefLine } finally { $script:JkUseColor = $useColor }
    $cacheLine = $line
    if ($off) { $cacheLine = '' }
    Write-JkText (Get-JkPath 'brief.cache') ((Get-JkNow).ToString('yyyy-MM-dd HH') + "`n" + $cacheLine + "`n")
    if ($off -and -not $Force) { return }
    if (-not $useColor) { $line = $line -replace "$([char]27)\[[0-9;]*m", '' }
    Say $line
}

function Clear-JkBriefCache { Remove-Item -LiteralPath (Get-JkPath 'brief.cache') -ErrorAction SilentlyContinue }

function Get-JkBriefLine {
    $now = Get-JkNow
    $data = Get-JkDueData -Cached
    $cmap = Get-JkCourseMap $data
    $soon = @($data.events | Where-Object { -not $_.done } | Where-Object { $d = Get-JkEventDue $_; $d -ge $now -and $d -lt $now.Date.AddDays(8) } | Sort-Object { Get-JkEventDue $_ })
    $parts = @()
    foreach ($e in ($soon | Select-Object -First 3)) {
        $due = Get-JkEventDue $e
        $n = [int]($due.Date - $now.Date).TotalDays
        $when = $due.ToString('ddd', [Globalization.CultureInfo]::InvariantCulture)
        $st = 'muted'
        if ($n -eq 0) { $when = 'today'; $st = 'bold red' } elseif ($n -eq 1) { $when = 'tmrw'; $st = 'orange' }
        $color = Get-JkCourseColor $e.course $cmap
        $label = (Get-JkCourseLabel $e $cmap) -replace '\s', ''
        $parts += (Paint "#$color" $label) + ' ' + (Paint 'white' ([string]$e.title)) + ' ' + (Paint $st $when)
    }
    # the next class today leads the line (absolute time: the line is cached for the hour)
    try {
        $nc = @(Get-JkClassesOn $now.Date | Where-Object { $_.End -gt $now }) | Select-Object -First 1
        if ($nc) {
            $label = (Format-JkClassLabel $nc.Class $cmap) -replace '\s(?=\d)', ''
            $room = ''; if ($nc.Class.room) { $room = ' ' + $nc.Class.room }
            $parts = @((Paint "bold #$(Get-JkCourseColor $nc.Class.course $cmap)" $label) + ' ' + (Paint 'white' (Format-JkTime $nc.Start.ToString('HH:mm'))) + (Paint 'muted' $room)) + $parts
            $soon = @($null) + $soon   # keeps the "+N more" arithmetic in step with $parts
        }
    } catch { }
    $td = Get-JkTodoData
    $openTodo = @($td.items | Where-Object { -not $_.done }).Count
    $tail = ''
    if ($openTodo) { $tail += Paint 'gray' "  $($script:G.vline)  $openTodo to-do" }
    $tail += Paint 'gray' '   (jk for more)'
    # keep it on one line: drop trailing items (they become "+N") until it fits the window
    $width = Get-JkWidth
    $shown = $parts.Count
    while ($true) {
        $line = ' ' + (Paint 'bold bg:#7C9CF8 ink' ' jk ') + ' '
        if ($shown -gt 0) { $line += (@($parts | Select-Object -First $shown) -join (Paint 'gray' "  $($script:G.dot)  ")) }
        else { $line += Paint 'green' 'nothing due this week' }
        $more = $soon.Count - $shown
        $dueCount = @($soon | Where-Object { $_ }).Count
        if ($shown -eq 0 -and $dueCount) { $line = ' ' + (Paint 'bold bg:#7C9CF8 ink' ' jk ') + ' ' + (Paint 'white' "$dueCount due this week"); $more = 0 }
        if ($more -gt 0) { $line += Paint 'gray' "  +$more" }
        $line += $tail
        if ((Get-JkVisibleLength $line) -le $width -or $shown -eq 0) { break }
        $shown--
    }
    $line
}
