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
    'jk exams               every remaining exam with a countdown',
    'jk jobs stripe         did I already apply? every application to a company, with links',
    'jk find co250 a3       finds a file by words in its name or folders; jk find -o 1 opens it'
)

# What's new, newest first. Add an entry when a feature ships; the dashboard announces each one
# once (three per run) and remembers the ids in state.json.
$script:JkNews = @(
    @{ Id = 'battery-health'; Cmd = 'jk sys'; Text = 'now shows battery wear: how much of its original charge your battery still holds' },
    @{ Id = 'tidy-courses'; Cmd = 'jk tidy'; Text = 'course downloads (CS245-F25-A05.pdf, STAT_230_002_27.pdf) now go to their course folders' },
    @{ Id = 'find'; Cmd = 'jk find'; Text = 'find a file by words in its name or folders (jk find co250 a3); jk find -o 1 opens it' },
    @{ Id = 'backup-mirror'; Cmd = 'jk backup mirror'; Text = 'keep a daily copy of your jk data outside ~\.jk (another drive, USB, a synced folder)' },
    @{ Id = 'class-alerts'; Cmd = 'class alerts'; Text = 'a popup 10 minutes before each class, with the room (jk config set alert.class 5m, or off)' },
    @{ Id = 'jobs'; Cmd = 'jk jobs'; Text = 'your job tracker: applied, waiting on you, and "did I already apply to X?" (jk jobs stripe)' },
    @{ Id = 'alerts'; Cmd = 'same-day alerts'; Text = 'a popup 2h before anything due today, interviews included (jk config set alert.before 90m)' },
    @{ Id = 'plan'; Cmd = 'jk plan'; Text = 'today''s study time split by weight and days left; jk plan start runs the next 25-minute block' },
    @{ Id = 'sync'; Cmd = 'jk due sync'; Text = 'pulls deadlines from your LEARN calendar feed; the morning task keeps them current' },
    @{ Id = 'review'; Cmd = 'jk review'; Text = 'the last 7 days (done, slipped, focus) and the next 7 (load, where the marks are)' }
)

# Unseen news, marked seen as it is returned. A brand-new setup (no deadlines yet) has nothing
# to catch up on: everything is marked seen silently.
function Pop-JkNews([int]$Take = 3) {
    $stored = Get-JkState 'newsSeen'
    $seen = @($stored)
    $unseen = @($script:JkNews | Where-Object { $seen -notcontains $_.Id })
    if (-not $unseen.Count) { return @() }
    $show = @($unseen | Select-Object -First $Take)
    if ($null -eq $stored -and -not @((Get-JkDueData -Cached).events).Count) { $show = @(); $mark = $unseen }
    else { $mark = $show }
    Set-JkState 'newsSeen' @(@($seen | Where-Object { $_ }) + @($mark | ForEach-Object { $_.Id }))
    $show
}

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
        $stamp = { param($ev, [string]$Fmt) $s = (Get-JkEventDue $ev).ToString($Fmt, $script:Inv); if ($ev.time) { $s += ' ' + (Format-JkTime $ev.time) }; $s }
        $title = [string]$e.title
        $when = & $stamp $e 'ddd MMM d'
        $cd = "in $days days"; if ($days -eq 0) { $cd = 'TODAY' } elseif ($days -eq 1) { $cd = 'tomorrow' }
        # an online window: one callout for the pair ("Mon Oct 26 6:00 am - Tue 11:59 pm")
        $win = Get-JkEventWindow $e $data
        if ($win) {
            $title = $win.Title
            if ($win.Opens -le $now) {
                $cd = 'OPEN NOW'
                $closeDay = & $stamp $win.Close 'ddd MMM d'
                $rel = Format-JkRelDay $win.Closes $now
                if ($rel -eq 'today' -or $rel -eq 'tomorrow') { $closeDay = "$rel $(Format-JkTime $win.Closes.ToString('HH:mm', $script:Inv))" }
                $when = "closes $closeDay"
            }
            else {
                $closeWhen = & $stamp $win.Close 'ddd'
                if ($win.Closes.Date -eq $win.Opens.Date) { $closeWhen = Format-JkTime $win.Closes.ToString('HH:mm', $script:Inv) }
                $when = (& $stamp $win.Open 'ddd MMM d') + " $($script:G.dash) " + $closeWhen
            }
        }
        Say (' ' + (Paint "bold bg:#$color ink" ' NEXT EXAM ') + ' ' + (Paint "bold #$color" (Get-JkCourseLabel $e $cmap)) + ' ' + (Paint 'bold white' $title) + (Paint 'muted' "  $cd $($script:G.dot) $when") + $(if ($e.weight) { Paint 'gray' "  $($e.weight)" } else { '' }))
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
    # the title column gives way to the EXAM tag when one is on screen, so rows keep one width
    $tagW = 0
    if (@($soon | Select-Object -First 8 | Where-Object { $_.kind -eq 'exam' }).Count) { $tagW = 7 }
    $titleW = [Math]::Max(12, $w - 46 - $tagW)
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

    # job applications blocked on you (recent ones; older ones stay in jk jobs todo)
    try {
        $waiting = @(Get-JkJobsWaiting $now)
        if ($waiting.Count) {
            Say ''
            Say (' ' + (Paint 'bold white' 'JOBS') + (Paint 'gray' "  $($waiting.Count) application$(if ($waiting.Count -ne 1) {'s'}) waiting on you"))
            foreach ($r in ($waiting | Select-Object -First 2)) { Say (Format-JkJobLine $r $w $now) }
            if ($waiting.Count -gt 2) { Say (Paint 'gray' "  +$($waiting.Count - 2) more $($script:G.arrow) jk jobs todo") }
        }
    } catch { }

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
        $sysBits += (Paint $st "Downloads $(Format-JkCount $files.Count 'file') / $(Format-JkSize $size)") + $hint
    } catch { }
    Say ('  ' + ($sysBits -join (Paint 'gray' "  $($script:G.dot)  ")))

    Say ''
    # features added since you last looked, each announced once
    try {
        foreach ($n in @(Pop-JkNews)) { Say ('  ' + (Paint 'bold purple' 'new') + '  ' + (Paint 'white' $n.Cmd) + '  ' + (Paint 'gray' (Fit $n.Text ([Math]::Max(10, $w - $n.Cmd.Length - 10))).TrimEnd())) }
    } catch { }
    $unpicked = @()
    $phase = ''; if ($info) { $phase = $info.Phase }
    # sections only matter while there are classes to go to
    if ($phase -in '', 'before', 'classes') { try { $unpicked = @(Get-JkUnpickedCourses) } catch { } }
    # one setup nudge at a time: sections first, then the LEARN feed, then next term
    $upcoming = @($data.events | Where-Object { -not $_.done -and (Get-JkEventDue $_) -ge $now }).Count
    if ($phase -eq 'after') {
        Say ('  ' + (Paint 'cyan' "$($script:G.star) $($info.Name) is over.") + (Paint 'gray' ' Next term: ') + (Paint 'cyan' 'jk due sync') + (Paint 'gray' ' (LEARN) and ') + (Paint 'cyan' 'jk class import') + (Paint 'gray' ' (Quest)'))
    } elseif ($phase -eq 'next' -and -not $upcoming) {
        # a new term with nothing in it yet
        Say ('  ' + (Paint 'cyan' "$($script:G.star) $($info.Name):") + (Paint 'gray' ' bring in its deadlines with ') + (Paint 'cyan' 'jk due sync') + (Paint 'gray' ' (LEARN) and its classes with ') + (Paint 'cyan' 'jk class import') + (Paint 'gray' ' (Quest)'))
    } elseif ($unpicked.Count) {
        Say ('  ' + (Paint 'cyan' "$($script:G.star) add your class sections") + (Paint 'gray' " ($($unpicked -join ', ') not on your timetable yet)  $($script:G.arrow) ") + (Paint 'cyan' 'jk class pick'))
    } elseif (-not (Get-JkConfig 'sync.url') -and @($data.events).Count) {
        Say ('  ' + (Paint 'cyan' "$($script:G.star) keep deadlines current") + (Paint 'gray' ": in LEARN, Calendar > Subscribe, copy the link, then $($script:G.arrow) ") + (Paint 'cyan' 'jk due sync'))
    } elseif ($now.DayOfWeek -eq 'Sunday') {
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
