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
    'jk find co250 a3       finds a file by words in its name or folders; jk find -o 1 opens it',
    'jk recent              the files you changed in the last 2 days, newest first',
    'jk clip unwrap         fixes text copied from a PDF (one line per paragraph again)'
)

# What's new, newest first. Add an entry when a feature ships; the dashboard announces each one
# once (three per run) and remembers the ids in state.json.
$script:JkNews = @(
    @{ Id = 'plan-week'; Cmd = 'jk plan week'; Text = 'the next seven days as a checklist; a course behind on its marks gets more time, and jk config set plan.skip <course> leaves one out' },
    @{ Id = 'next'; Cmd = 'jk next'; Text = 'the one thing to do now (work due tonight, a class soon, today''s study) and the command for it' },
    @{ Id = 'clip-ocr'; Cmd = 'jk clip ocr'; Text = 'snip anything with Win+Shift+S, then this puts the text in it on the clipboard' },
    @{ Id = 'shots-find'; Cmd = 'jk shots find backward euler'; Text = 'your screenshots by the words in them (a slide, an error, a question you snapped)' },
    @{ Id = 'course'; Cmd = 'jk cs341'; Text = 'one course on a screen: its exam, deadlines, marks, classes, study today, newest files' },
    @{ Id = 'time'; Cmd = 'jk time'; Text = 'the time in Beijing (from your Chinese keyboard), 8pm beijing in your time, and when you are both up to call' },
    @{ Id = 'grep'; Cmd = 'jk grep cs370 condition number'; Text = 'the lecture pages that cover it, with a snippet; jk find -o 1 opens the PDF at that page' },
    @{ Id = 'weather'; Cmd = 'jk weather'; Text = 'rain or snow from when, what to take, and the weather at your exam; a line of it on the dashboard' },
    @{ Id = 'grade-whatif'; Cmd = 'jk grade cs370 if midterm 70'; Text = 'what the rest of the course would need with that mark; nothing is saved' },
    @{ Id = 'pdf'; Cmd = 'jk pdf *.jpg'; Text = 'photos of handwritten work into one PDF for LEARN or Crowdmark, each page upright' },
    @{ Id = 'cp-links'; Cmd = 'jk cp new <AtCoder/USACO/CSES link>'; Text = 'the problem''s folder with every sample downloaded; jk cp tests them' },
    @{ Id = 'cp-listen'; Cmd = 'jk cp listen'; Text = 'Codeforces too: press Competitive Companion''s green + and the problem (or contest) arrives' },
    @{ Id = 'grade-import'; Cmd = 'jk grade import cs341'; Text = 'copy a course''s Grades page in LEARN: every mark matched to its deadline and recorded at once' },
    @{ Id = 'shots'; Cmd = 'jk shots'; Text = 'your 4000+ screenshots by month, the newest one to open, the rest filed into month folders' },
    @{ Id = 'exam-brief'; Cmd = 'jk exam cs370'; Text = 'one exam on a screen: when, worth, what you need, prep planned, review files to open' },
    @{ Id = 'net'; Cmd = 'jk net'; Text = 'Wi-Fi up but nothing loads? says whether it is the signal, the router, DNS or a sign-in page' },
    @{ Id = 'todo-dates'; Cmd = 'jk todo pay rent nov 1'; Text = 'a date at the end becomes its due date (by fri, at 7pm, tomorrow), so the popup lists it' },
    @{ Id = 'grade-names'; Cmd = 'jk grade cs341 midterm 1 72%'; Text = 'marks by course and title (a1 = Assignment 1); 17 / 20 and 18 out of 20 work too' },
    @{ Id = 'port-exposed'; Cmd = 'jk port'; Text = 'flags a database other devices on your Wi-Fi can reach, and the setting that keeps it local' },
    @{ Id = 'due-words'; Cmd = 'jk due done cs341 midterm 2'; Text = 'deadlines by course and title words; jk due add needs no quotes, and 7-9pm sets an exam''s end' },
    @{ Id = 'class-add-words'; Cmd = 'jk class add cs350 tue thu 4pm-5:20pm MC 1056'; Text = 'no quotes or commas needed; tth, mwf and 220pm work too' },
    @{ Id = 'spoken-lengths'; Cmd = 'jk in an hour call mom'; Text = 'jk in and jk focus take "an hour", "half an hour" and "for 30 minutes"' },
    @{ Id = 'due-files';Cmd = 'jk due files cs341 a2'; Text = 'the files in the course folder for that deadline (A2.tex, A2\...), numbered for jk find -o' },
    @{ Id = 'clip'; Cmd = 'jk clip'; Text = 'word count of the clipboard; jk clip unwrap fixes text copied from a PDF' },
    @{ Id = 'grade-fill'; Cmd = 'jk grade fill'; Text = 'type the marks for everything already handed in, one after another (Enter skips)' },
    @{ Id = 'recent'; Cmd = 'jk recent'; Text = 'the files you changed in the last 2 days, newest first (jk find -o 1 opens one)' },
    @{ Id = 'exam-mornings'; Cmd = 'exam days'; Text = 'the morning popup leads with the exam, with its end time, room and what to bring' },
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

# A tip line ("new  jk net  says whether..."): one line when it fits; otherwise the text wraps under
# itself, or, when the lead leaves too little room, under the lead on lines of its own. $LeadW is the
# lead's visible width (it carries colour codes).
function Write-JkTip([string]$Lead, [int]$LeadW, [string]$Text, [string]$Style = 'gray', [int]$Indent = 7) {
    $w = Get-JkWidth
    $avail = $w - $LeadW - 1
    if ((Get-JkTextWidth $Text) -le $avail) { Say ($Lead + (Paint $Style $Text)); return }
    if ($avail -ge 30) {
        $lines = @(Split-JkWords $Text $avail)
        Say ($Lead + (Paint $Style $lines[0]))
        foreach ($l in @($lines | Select-Object -Skip 1)) { Say ((' ' * $LeadW) + (Paint $Style $l)) }
        return
    }
    Say $Lead.TrimEnd()
    foreach ($l in @(Split-JkWords $Text ($w - $Indent - 1))) { Say ((' ' * $Indent) + (Paint $Style $l)) }
}

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

# The dashboard's JOBS lines as one block of text ('' when nothing is waiting on you).
function Get-JkDashJobsText([datetime]$Now, [int]$Width) {
    $waiting = @(Get-JkJobsWaiting $Now)
    if (-not $waiting.Count) { return '' }
    $lines = @((' ' + (Paint 'bold white' 'JOBS') + (Paint 'gray' "  $(Format-JkCount $waiting.Count 'application') waiting on you")))
    foreach ($r in ($waiting | Select-Object -First 2)) { $lines += Format-JkJobLine $r $Width $Now }
    if ($waiting.Count -gt 2) { $lines += Paint 'gray' "  +$($waiting.Count - 2) more $($script:G.arrow) jk jobs todo" }
    $lines -join "`n"
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
    # the weather, from the kept forecast (an old one is fetched again in the background)
    try { $wx = Get-JkDashWeather $now; if ($wx) { Say (' ' + $wx) } } catch { }
    Say (Paint 'gray dim' (' ' + ($script:G.hline * ($w - 1))))

    # next exam callout
    # (one being written now stays the callout until it is over: at its end time it is, as jk due
    # and jk next have it)
    $nextExam = @($data.events | Where-Object { $_.kind -eq 'exam' -and -not $_.done -and (Get-JkExamEnd $_) -gt $now } | Sort-Object { Get-JkEventDue $_ } | Select-Object -First 1)
    if ($nextExam) {
        $e = $nextExam[0]
        $due = Get-JkEventDue $e
        $days = [int]($due.Date - $now.Date).TotalDays
        $color = Get-JkCourseColor $e.course $cmap
        $stamp = { param($ev, [string]$Fmt) $s = (Get-JkEventDue $ev).ToString($Fmt, $script:Inv); if ($ev.time) { $s += ' ' + (Format-JkTime $ev.time) }; $s }
        $title = [string]$e.title
        $when = & $stamp $e 'ddd MMM d'
        $cd = "in $days days"; if ($days -eq 0) { $cd = 'TODAY' } elseif ($days -eq 1) { $cd = 'tomorrow' }
        if ($days -eq 0 -and $e.time) {
            if ($due -le $now) { $cd = 'NOW' } else { $cd = "TODAY, in $(Format-JkDuration (Get-JkTimeLeft $due $now))" }
        }
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
                # a week or more after it opens, the date: "Mon Nov 9 9:00 am - Mon Nov 16 11:59 pm"
                $closeWhen = Format-JkComingDay $win.Closes $win.Opens
                if ($win.Close.time) { $closeWhen += ' ' + (Format-JkTime $win.Close.time) }
                if ($win.Closes.Date -eq $win.Opens.Date) { $closeWhen = Format-JkTime $win.Closes.ToString('HH:mm', $script:Inv) }
                $when = (& $stamp $win.Open 'ddd MMM d') + " $($script:G.dash) " + $closeWhen
            }
        }
        # three days out or closer: the command for its brief (files, prep, what you need on it)
        $brief = ''
        if ($days -le 3 -and $cd -ne 'NOW') { $brief = Paint 'gray' "  $($script:G.arrow) jk exam $(Get-JkNormKey ([string](@($data.courses | Where-Object { $_.key -eq $e.course })[0].code)))" }
        Say (' ' + (Paint "bold bg:#$color ink" ' NEXT EXAM ') + ' ' + (Paint "bold #$color" (Get-JkCourseLabel $e $cmap)) + ' ' + (Paint 'bold white' $title) + (Paint 'muted' "  $cd $($script:G.dot) $when") + $(if ($e.weight) { Paint 'gray' "  $($e.weight)" } else { '' }) + $brief)
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
    # "2 due, 1 exam": a final is not something due, and an online exam's two rows are one exam
    Say (' ' + (Paint 'bold white' 'THIS WEEK') + (Paint 'gray' "  $(Format-JkDueCounts (Measure-JkDue $soon)) in 7 days"))
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

    # today's study blocks from jk plan (about 200 ms cold, so kept for the hour until the
    # deadlines, focus log or settings change)
    try {
        $planKey = $now.ToString('yyyyMMddHH', $script:Inv) + '|' + (Get-JkFileStamp @((Get-JkPath 'deadlines.json'), (Get-JkPath 'focus.json'), (Get-JkPath 'config.json'), (Get-JkPath 'grades.json'))) + "|$script:JkUseColor|$script:JkLightTheme"
        $planLine = Get-JkCached 'plan-line' $planKey { Get-JkPlanLine }
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

    # job applications blocked on you (recent ones; older ones stay in jk jobs todo). Reading the
    # tracker takes about 250 ms cold, so the section is kept for the day until the tracker changes.
    try {
        $jf = Get-JkCached 'jobs-file' ($now.ToString('yyyyMMdd', $script:Inv) + '|' + (Get-JkConfig 'jobs.file')) { Find-JkJobsFile }
        if ($jf -and -not [IO.File]::Exists($jf)) { $jf = Find-JkJobsFile }
        if ($jf) {
            $jobsKey = $now.ToString('yyyyMMdd', $script:Inv) + "|$jf|" + (Get-JkFileStamp @($jf)) + "|$w|$script:JkUseColor|$script:JkLightTheme"
            $jobsText = Get-JkCached 'dash-jobs' $jobsKey { Get-JkDashJobsText $now $w }
            if ($jobsText) { Say ''; foreach ($l in ($jobsText -split "`n")) { Say $l } }
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
        # filling up fast: 4 GB or more gone in three days is worth a look before it is a problem
        $txt = "$($env:SystemDrive) $(Format-JkSize $c.AvailableFreeSpace) free"
        $drop = $null; try { Update-JkDiskLog $c.AvailableFreeSpace $now; $drop = Get-JkDiskDrop $c.AvailableFreeSpace $now } catch { }
        if ($drop) { $txt += " ($(Format-JkDiskDrop $drop))"; if ($st -eq 'muted') { $st = 'orange' }; $hint = Paint 'gray' " $($script:G.arrow) jk space" }
        $sysBits += (Paint $st $txt) + $hint
    } catch { }
    try {
        $mem = Get-JkMemory
        $memUsed = 1 - ($mem.Free / $mem.Total)
        $st = 'muted'; if ($memUsed -gt 0.9) { $st = 'red' } elseif ($memUsed -gt 0.8) { $st = 'orange' }
        $ram = "RAM {0:N0}%" -f ($memUsed * 100)
        # tight on memory: name the app holding the most, the one worth closing
        if ($memUsed -gt 0.85) { try { $hog = @(Get-JkMemoryHogs 1)[0]; if ($hog) { $ram += " ($($hog.Name) $(Format-JkSize $hog.Mem))" } } catch { } }
        $sysBits += Paint $st $ram
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
        foreach ($n in @(Pop-JkNews)) { Write-JkTip ('  ' + (Paint 'bold purple' 'new') + '  ' + (Paint 'white' $n.Cmd) + '  ') (9 + (Get-JkTextWidth $n.Cmd)) $n.Text }
    } catch { }
    $unpicked = @()
    $phase = ''; if ($info) { $phase = $info.Phase }
    # sections only matter while there are classes to go to
    if ($phase -in '', 'before', 'classes') { try { $unpicked = @(Get-JkUnpickedCourses) } catch { } }
    # one setup nudge at a time: sections first, then the LEARN feed, then next term. The command
    # comes first, so a narrow window that cuts the line still shows what to type.
    $upcoming = @($data.events | Where-Object { -not $_.done -and (Get-JkEventDue $_) -ge $now }).Count
    $nudge = { param([string]$Cmd, [string]$Why) Write-JkTip ('  ' + (Paint 'cyan' "$($script:G.star) $Cmd") + '  ') (6 + (Get-JkTextWidth $Cmd)) $Why -Indent 4 }
    # the morning task first: without it nothing else reminds you of anything (a sandbox has none)
    $taskProblem = @(); if (-not $env:JK_SANDBOX) { try { $taskProblem = @(Get-JkTaskNudge $now) } catch { } }
    # marks before sections: jk plan splits the time by them, and a course with none is planned blind
    $marks = $null
    if ($phase -in '', 'classes', 'study', 'exams') { try { $marks = Get-JkMarksNudge $data $now } catch { } }
    if ($taskProblem.Count) {
        & $nudge $taskProblem[0] $taskProblem[1]
    } elseif ($marks) {
        & $nudge $marks[0] $marks[1]
    } elseif (-not @($data.events).Count -and $phase -ne 'next') {
        # a brand-new setup: the first thing worth doing
        & $nudge 'jk due sync' 'bring in your deadlines: in LEARN, Calendar > Subscribe, copy the link, then run it'
    } elseif ($phase -eq 'after') {
        & $nudge 'jk due sync  +  jk class import' "$($info.Name) is over: next term's deadlines (LEARN) and classes (Quest)"
    } elseif ($phase -eq 'next' -and -not $upcoming) {
        # a new term with nothing in it yet
        & $nudge 'jk due sync  +  jk class import' "bring in $($info.Name)'s deadlines (LEARN) and classes (Quest)"
    } elseif ($unpicked.Count) {
        & $nudge 'jk class pick' "add your class sections ($($unpicked -join ', ') not on your timetable yet), or jk class import copies them from Quest"
    } elseif (-not (Get-JkConfig 'sync.url') -and @($data.events).Count) {
        & $nudge 'jk due sync' 'keep deadlines current: in LEARN, Calendar > Subscribe, copy the link, then run it'
    } elseif ($now.DayOfWeek -eq 'Sunday') {
        & $nudge 'jk review' 'Sunday: look back at the week and plan the next one'
    } else {
        $tip = $script:JkTips[(Get-Random -Maximum $script:JkTips.Count)]
        Say (Paint 'gray' "  tip: $tip")
    }
}

# The dashboard's nudge for marks not yet in: @(command, why) when 3 or more past graded items have
# none, naming the course (not left out of jk plan) with the most weight missing; $null otherwise.
function Get-JkMarksNudge($Data, [datetime]$Now) {
    $items = @(Get-JkUnmarkedItems $Now)
    if ($items.Count -lt 3) { return $null }
    $skip = @(Get-JkPlanSkip $Data)
    $byCourse = @{}
    foreach ($e in @($Data.events)) {
        $it = @($items | Where-Object { $_.Id -eq [string]$e.id })[0]
        if (-not $it -or $skip -contains [string]$e.course) { continue }
        $byCourse[[string]$e.course] = [double]$byCourse[[string]$e.course] + [double]$it.Weight
    }
    if (-not $byCourse.Count) { return $null }
    $top = @($byCourse.Keys | Sort-Object @{ e = { - $byCourse[$_] } }, @{ e = { $_ } })[0]
    $cmap = Get-JkCourseMap $Data
    $code = Get-JkCourseLabel ([pscustomobject]@{ course = $top }) $cmap
    $key = Get-JkNormKey $code; if (-not $key) { $key = $top }
    $pct = Format-JkWeightPct $byCourse[$top]
    @("jk grade import $key", "$(Format-JkCount $items.Count 'past item') have no mark yet ($code $pct of the course): copy its LEARN Grades page first (Ctrl+A, Ctrl+C), and jk plan weighs it by your marks")
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
    # which three: anything due today or tomorrow, then an exam this week (a 20% quiz on Thursday
    # matters more than two Monday assignments), then the rest by date; shown in date order. A
    # narrow window drops the least pressing first.
    # an online window counts once: by its opening while that is still to come
    $rank = { param($x) $d = Get-JkEventDue $x; $n = ($d.Date - $now.Date).TotalDays
        if ($n -le 1) { return 0 }
        if ($x.kind -ne 'exam') { return 2 }
        if ([string]$x.title -match '(?i)\s+closes?$') { $win = Get-JkEventWindow $x $data; if ($win -and @($soon | Where-Object { $_.id -eq $win.Open.id }).Count) { return 2 } }
        1 }
    $byRank = @($soon | Sort-Object @{ e = { & $rank $_ } }, @{ e = { Get-JkEventDue $_ } })
    $render = { param($pick)
        foreach ($e in @($pick | Sort-Object { Get-JkEventDue $_ })) {
        $due = Get-JkEventDue $e
        $n = [int]($due.Date - $now.Date).TotalDays
        $when = $due.ToString('ddd', [Globalization.CultureInfo]::InvariantCulture)
        # a week out is that weekday again: on a Monday, "Mon" would read as today
        if ($n -ge 7) { $when = $due.ToString('MMM d', [Globalization.CultureInfo]::InvariantCulture) }
        $st = 'muted'
        # today's carry their time (the line is cached for the hour, so a clock time, not "in 30m")
        if ($n -eq 0) { $when = 'today'; if ($e.time) { $when += ' ' + ((Format-JkTime ([string]$e.time)) -replace ':00 ', ' ') }; $st = 'bold red' }
        elseif ($n -eq 1) { $when = 'tmrw'; $st = 'orange' }
        $color = Get-JkCourseColor $e.course $cmap
        $label = (Get-JkCourseLabel $e $cmap) -replace '\s', ''
        # today's exam in a class carries the class's room (the class itself is left off the line)
        $room = ''; if ($n -eq 0) { $xc = Get-JkExamClass $e; if ($xc -and $xc.Class.room) { $room = ' ' + (Paint 'muted' ([string]$xc.Class.room)) } }
        (Paint "#$color" $label) + ' ' + (Paint 'white' ([string]$e.title)) + ' ' + (Paint $st $when) + $room
        }
    }
    $lead = @()
    # the next class today leads the line (absolute time: the line is cached for the hour)
    try {
        $nc = @(Get-JkClassesOn $now.Date | Where-Object { $_.End -gt $now }) | Select-Object -First 1
        # a class that holds an exam on the line is that exam
        if ($nc -and @($soon | Where-Object { $c = Get-JkExamClass $_; $c -and $c.Class.course -eq $nc.Class.course -and $c.Start -eq $nc.Start }).Count) { $nc = $null }
        if ($nc) {
            $label = (Format-JkClassLabel $nc.Class $cmap) -replace '\s(?=\d)', ''
            $room = ''; if ($nc.Class.room) { $room = ' ' + $nc.Class.room }
            $lead = @((Paint "bold #$(Get-JkCourseColor $nc.Class.course $cmap)" $label) + ' ' + (Paint 'white' (Format-JkTime $nc.Start.ToString('HH:mm'))) + (Paint 'muted' $room))
        }
    } catch { }
    $td = Get-JkTodoData
    $openTodo = @($td.items | Where-Object { -not $_.done }).Count
    $tail = ''
    # rain, snow or a bitter wind chill in the next 12 hours (nothing on a dry, mild day)
    try { $wx = Get-JkBriefWeather $now; if ($wx) { $tail += (Paint 'gray' "  $($script:G.vline)  ") + (Paint 'cyan' $wx) } } catch { }
    if ($openTodo) { $tail += Paint 'gray' "  $($script:G.vline)  $openTodo to-do" }
    $tail += Paint 'gray' '   (jk for more)'
    # keep it on one line: drop trailing items (they become "+N") until it fits the window
    $width = Get-JkWidth
    $k = [Math]::Min(3, $byRank.Count)
    $shown = $lead.Count + $k
    while ($true) {
        $parts = @($lead) + @(& $render @($byRank | Select-Object -First $k))
        # the class goes last, after every deadline has been dropped
        $parts = @($parts | Select-Object -First $shown)
        $line = ' ' + (Paint 'bold bg:#7C9CF8 ink' ' jk ') + ' '
        if ($shown -gt 0) { $line += ($parts -join (Paint 'gray' "  $($script:G.dot)  ")) }
        else { $line += Paint 'green' 'nothing due this week' }
        $more = $soon.Count - [Math]::Max(0, $shown - $lead.Count)
        $dueCount = $soon.Count
        if ($shown -eq 0 -and $dueCount) { $line = ' ' + (Paint 'bold bg:#7C9CF8 ink' ' jk ') + ' ' + (Paint 'white' "$(Format-JkDueCounts (Measure-JkDue $soon)) this week"); $more = 0 }
        if ($more -gt 0) { $line += Paint 'gray' "  +$more" }
        $line += $tail
        if ((Get-JkVisibleLength $line) -le $width -or $shown -eq 0) { break }
        if ($k -gt 0) { $k-- }
        $shown--
    }
    $line
}
