# remind.ps1 - one-off reminders (jk in 20m "..." / jk at 3pm "...") and the daily deadline check task.

$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:JkTaskName = 'jk-remind'

function Get-JkReminderData {
    $d = Read-JkJson 'reminders.json' $null
    if (-not $d) { $d = [pscustomobject]@{ nextId = 1; items = @() } }
    if ($null -eq (Get-JkProp $d 'items')) { Set-JkProp $d 'items' @() }
    $d
}

function Save-JkReminderData($Data) { $Data.items = @($Data.items); Save-JkJson 'reminders.json' $Data }

# reminders.json is read, changed and saved by several processes (each timer that fires, the
# morning task, the shell). A machine-wide mutex keeps one change from overwriting another, for
# example two alerts that fire in the same minute. Windows mutexes are re-entrant per thread,
# so a locked function may call another.
function Enter-JkReminderLock {
    $m = New-Object Threading.Mutex($false, 'Local\jk-reminders')
    # an owner that died while holding it leaves it "abandoned": the wait still acquires it
    try { $null = $m.WaitOne(10000) } catch { }
    $m
}

function Exit-JkReminderLock($Mutex) {
    try { $Mutex.ReleaseMutex() } catch { }
    $Mutex.Dispose()
}

function Get-JkReminderList { @((Get-JkReminderData).items | Sort-Object at) }

function New-JkReminder {
    param([datetime]$At, [string]$Text, [string]$Key = '', [int]$DueId = 0)
    if (-not $Text) { $Text = 'Reminder' }
    $lock = Enter-JkReminderLock
    try {
        $d = Get-JkReminderData
        $id = [int](Get-JkProp $d 'nextId' 1)
        $d.nextId = $id + 1
        # spawn first, then save once with the pid: the timer needs over a second just to load,
        # so the record is on disk long before it can fire
        $job = Get-JkReminderJob $id $At
        $p = Start-JkBackground @job
        $item = [pscustomobject][ordered]@{ id = $id; text = $Text; at = $At.ToString('s', $script:Inv); created = (Get-Date).ToString('s', $script:Inv); pid = $p.Id; spawned = $p.StartTime.ToString('s', $script:Inv); key = $Key; dueId = $DueId }
        $d.items = @($d.items) + $item
        Save-JkReminderData $d
    } finally { Exit-JkReminderLock $lock }
    $item
}

# Splat for Start-JkBackground: sleep until $At, then fire reminder $Id.
function Get-JkReminderJob([int]$Id, [datetime]$At) {
    @{ Script = "Complete-JkReminder -Id $Id"; WaitUntil = $At.ToString('o', $script:Inv) }
}

# Re-arms an existing reminder (after a restart).
function Start-JkReminderProcess($Item) {
    $at = [datetime]::Parse([string]$Item.at, $script:Inv)
    $job = Get-JkReminderJob ([int]$Item.id) $at
    $p = Start-JkBackground @job
    $lock = Enter-JkReminderLock
    try {
        $d = Get-JkReminderData
        foreach ($i in @($d.items)) {
            if ([int]$i.id -eq [int]$Item.id) { $i.pid = $p.Id; $i.spawned = $p.StartTime.ToString('s', $script:Inv) }
        }
        Save-JkReminderData $d
    } finally { Exit-JkReminderLock $lock }
}

# Runs in the background process when a reminder is due.
function Complete-JkReminder {
    param([int]$Id, [switch]$Missed)
    $lock = Enter-JkReminderLock
    try {
        $d = Get-JkReminderData
        $item = @($d.items | Where-Object { [int]$_.id -eq $Id })
        if ($item) {
            $d.items = @($d.items | Where-Object { [int]$_.id -ne $Id })
            Save-JkReminderData $d
        }
    } finally { Exit-JkReminderLock $lock }
    if (-not $item) { return }
    $item = $item[0]
    $at = [datetime]::Parse([string]$item.at, $script:Inv)
    $lines = @()
    $accent = $script:JkPalette.amber
    $dueId = [int](Get-JkProp $item 'dueId' 0)
    $key = [string](Get-JkProp $item 'key' '')
    if ($key.StartsWith('class:')) {
        # set up the next class first: this popup can stay up until it is dismissed
        try { $null = Register-JkClassAlert } catch { Add-Content -LiteralPath (Get-JkPath 'background.log') -Value ((Get-Date -Format s) + ' class alert: ' + $_.Exception.Message) }
        # class:<date>:<HH>:<mm>:<course>:<kind>; quiet if it was dropped or the day became a break
        $p = $key.Split(':')
        $m = @(Get-JkClassesOn $at.Date | Where-Object { $_.Class.course -eq $p[4] -and [string]$_.Class.kind -eq $p[5] -and $_.Start.ToString('HH:mm', $script:Inv) -eq "$($p[2]):$($p[3])" })[0]
        $now = Get-JkNow
        if (-not $m -or $m.Start -le $now) { return }
        $lines += "Starts in $(Format-JkDuration ($m.Start - $now))$(if ($m.Class.room) { " $($script:G.dot) $($m.Class.room)" })"
        $data = Get-JkDueData
        # a quiz, exam or deadline during this class (an in-class quiz is too early for its own alert)
        foreach ($e in @($data.events | Where-Object { $_.course -eq $m.Class.course -and -not $_.done -and $_.time -and $_.date -eq $m.Start.ToString('yyyy-MM-dd', $script:Inv) })) {
            $due = Get-JkEventDue $e
            if ($due -ge $m.Start -and $due -lt $m.End) {
                $lines += "$($e.title)$(if ($e.kind -eq 'exam') { ' (exam)' })$(if ($e.weight) { ', ' + $e.weight }) in this class"
            }
            # the course's exam later the same day: the lecture before a 4:30 pm midterm says so
            elseif ($e.kind -eq 'exam' -and $due -ge $m.End -and [string]$e.title -notmatch '(?i)\s+opens?$') {
                $lines += "$(([string]$e.title -replace '(?i)\s+closes?$', '').Trim()) later today at $(Format-JkTime $due.ToString('HH:mm', $script:Inv))$(if ($e.weight) { ', ' + $e.weight })"
            }
        }
        $accent = Get-JkCourseColor $m.Class.course (Get-JkCourseMap $data)
    }
    elseif ($dueId) {
        # a same-day deadline alert: stay quiet if it was finished in the meantime
        $data = Get-JkDueData
        $e = @($data.events | Where-Object { [int]$_.id -eq $dueId })[0]
        if (-not $e -or $e.done -or -not $e.time) { return }
        $due = Get-JkEventDue $e
        # moved to another day or already past since the alert was set: nothing useful to say
        $now = Get-JkNow
        if ($due -le $now -or $due.Date -ne $at.Date) { return }
        if ([string]$e.title -match '(?i)\s+closes?$') {
            # the end of an online window: the last chance to write it
            $lines += "Closes $(Format-JkTime $e.time) $($script:G.dot) in $(Format-JkDuration (Get-JkTimeLeft $due $now))"
            if ($e.note) { $lines += [string]$e.note }
            $lines += "Written it? jk due done $dueId"
        } elseif ($e.kind -eq 'exam' -or $e.kind -eq 'appt') {
            # an exam or an interview is something to get to, not to hand in: when, and where
            $lines += "Starts $(Format-JkTime $e.time) $($script:G.dot) in $(Format-JkDuration (Get-JkTimeLeft $due $now))"
            if ($e.note) { $lines += [string]$e.note }
            # what it will be like on the way there
            if ([string]$e.note -notmatch '(?i)\bonline\b') { try { $wx = Get-JkExamWeather $due; if ($wx) { $lines += "Weather: $wx" } } catch { } }
        } else {
            $lines += "Due $(Format-JkTime $e.time) $($script:G.dot) in $(Format-JkDuration (Get-JkTimeLeft $due $now))"
            $lines += "Finished? jk due done $dueId"
        }
        $accent = Get-JkCourseColor $e.course (Get-JkCourseMap $data)
    }
    elseif ($Missed) { $lines += "Missed while the computer was off $($script:G.dot) was due $(Format-JkTime $at.ToString('HH:mm')) $($at.ToString('ddd MMM d', $script:Inv))" }
    else { $lines += "Set $(Format-JkRelTime ([datetime]::Parse([string]$item.created, $script:Inv)))" }
    # reminders stay until dismissed; a class alert closes itself 10 minutes into the class, so a day
    # away from the PC does not leave a pile of stale "starts in 10m" cards
    $stay = 0
    if ($key.StartsWith('class:') -and $m) { $stay = [int][Math]::Max(60, ($m.Start.AddMinutes(10) - (Get-JkNow)).TotalSeconds) }
    $null = Show-JkNotify -Title ([string]$item.text) -Lines $lines -Accent $accent -Seconds $stay -Sound -Wait
}

# Same-day alerts: for each item due later today, a reminder alert.before ahead of it
# (default 2h). Run by the morning task and again at sign-in; today's keys are remembered in
# reminders.json, so an alert is set once even if it was cancelled or has already fired.
function Register-JkTodayAlerts {
    param([datetime]$Now = (Get-JkNow))
    $before = Get-JkConfig 'alert.before'
    if (-not $before -or $before -match '^(0|off|none)$') { return 0 }
    $secs = ConvertTo-JkSeconds $before
    $data = Get-JkDueData
    $cmap = Get-JkCourseMap $data
    $today = $Now.ToString('yyyy-MM-dd', $script:Inv)
    $rd = Get-JkReminderData
    $seen = @(@(Get-JkProp $rd 'alerted' @()) | Where-Object { ([string]$_).Contains($today) })
    $known = @($seen) + @($rd.items | ForEach-Object { [string](Get-JkProp $_ 'key') })
    $added = @()
    $n = 0
    foreach ($e in @($data.events)) {
        if ($e.done -or -not $e.time) { continue }
        # anything timed (interviews and OAs carry no weight), except work marked 0% and the
        # opening of a quiz window
        if ($e.weight -and (Get-JkWeightValue $e.weight) -le 0) { continue }
        if ([string]$e.title -match '(?i)\s+opens?$') { continue }
        $due = Get-JkEventDue $e
        if ($due.Date -ne $Now.Date -or $due -le $Now) { continue }
        $at = $due.AddSeconds(-$secs)
        if ($at -le $Now) {
            # the morning run happens on the first wake after 7:45, and a laptop asleep until 6 pm
            # is past the 5 pm warning for a 7 pm exam: warn now while there is time to act on it
            if (($due - $Now).TotalMinutes -lt 10) { continue }
            $at = $Now.AddMinutes(1)
        }
        $key = "due:$($e.id):$($e.date)"
        if ($known -contains $key) { continue }
        $text = "$(Get-JkCourseLabel $e $cmap) $($e.title)$(if ($e.kind -eq 'exam') { ' (exam)' }) at $(Format-JkTime $e.time)"
        $null = New-JkReminder -At $at -Text $text -Key $key -DueId ([int]$e.id)
        $added += $key
        $n++
    }
    $old = @(Get-JkProp $rd 'alerted' @())
    if ($n -or $old.Count -ne $seen.Count) {
        $lock = Enter-JkReminderLock
        try {
            $rd = Get-JkReminderData
            # keep what others added meanwhile (a class alert), drop other days
            $current = @(@(Get-JkProp $rd 'alerted' @()) | Where-Object { ([string]$_).Contains($today) })
            Set-JkProp $rd 'alerted' @(@($current) + @($added) | Select-Object -Unique)
            Save-JkReminderData $rd
        } finally { Exit-JkReminderLock $lock }
    }
    $n
}

# Class alerts: a popup alert.class (default 10m) before each class today. Only one waits at a
# time (each timer is a ~60 MB process): the morning task sets the first, and every alert sets
# the next as it fires. Keys go into the same per-day "alerted" list, so a cancelled one stays
# cancelled and a later sign-in moves on to the following class.
function Register-JkClassAlert {
    param([datetime]$Now = (Get-JkNow))
    $lead = Get-JkConfig 'alert.class'
    if (-not $lead -or $lead -match '^(0|off|none)$') { return $null }
    $secs = ConvertTo-JkSeconds $lead
    $today = $Now.ToString('yyyy-MM-dd', $script:Inv)
    # check-and-add as one step: the morning task and a firing alert can both get here at once
    $lock = Enter-JkReminderLock
    try {
        $rd = Get-JkReminderData
        if (@($rd.items | Where-Object { ([string](Get-JkProp $_ 'key' '')).StartsWith("class:$today") }).Count) { return $null }
        $alerted = @(@(Get-JkProp $rd 'alerted' @()) | Where-Object { ([string]$_).Contains($today) })
        $cmap = Get-JkCourseMap (Get-JkDueData -Cached)
        foreach ($m in @(Get-JkClassesOn $Now.Date)) {
            $at = $m.Start.AddSeconds(-$secs)
            if ($at -le $Now) {
                # woken (or signed in) inside the lead time: "starts in 5m" still helps, under 3 does not
                if (($m.Start - $Now).TotalMinutes -lt 3) { continue }
                $at = $Now.AddSeconds(30)
            }
            $key = "class:${today}:$($m.Start.ToString('HH:mm', $script:Inv)):$($m.Class.course):$($m.Class.kind)"
            if ($alerted -contains $key) { continue }
            $text = "$(Format-JkClassLabel $m.Class $cmap) at $(Format-JkTime $m.Start.ToString('HH:mm'))"
            $r = New-JkReminder -At $at -Text $text -Key $key
            $rd = Get-JkReminderData
            Set-JkProp $rd 'alerted' @($alerted + $key)
            Save-JkReminderData $rd
            return $r
        }
        $null
    } finally { Exit-JkReminderLock $lock }
}

function Format-JkRelTime([datetime]$When) {
    $span = (Get-Date) - $When
    if ($span.TotalMinutes -lt 1) { return 'just now' }
    (Format-JkDuration $span) + ' ago'
}

# After a reboot the sleeping processes are gone: re-arm future reminders, fire missed ones.
function Restore-JkReminders {
    $d = Get-JkReminderData
    foreach ($i in @($d.items)) {
        if (Test-JkBackgroundAlive ([int]$i.pid) ([string]$i.spawned)) { continue }
        $at = [datetime]::Parse([string]$i.at, $script:Inv)
        if ($at -gt (Get-Date)) { Start-JkReminderProcess $i }
        else { $null = Start-JkBackground -Script "Complete-JkReminder -Id $($i.id) -Missed" }
    }
}

function Write-JkReminderSet($Item) {
    $at = [datetime]::Parse([string]$Item.at, $script:Inv)
    $when = Format-JkTime $at.ToString('HH:mm')
    if ($at.Date -ne (Get-Date).Date) { $when = $at.ToString('ddd MMM d', $script:Inv) + ' ' + $when }
    Say ('  ' + (Paint 'bold amber' "$($script:G.circle) Reminder #$($Item.id)") + "  $($Item.text)" + (Paint 'gray' "  $($script:G.dot) $when (in $(Format-JkDuration ($at - (Get-Date))))"))
}

# jk in 20m take the laundry out
function Invoke-JkRemindIn {
    $a = @($args | ForEach-Object { [string]$_ })
    if ($a.Count -eq 0) { throw 'usage: jk in <20m|1h30m|2 hours|90s> <message>' }
    $d = Read-JkDurationWords $a
    $secs = $d.Seconds
    $text = ''
    if ($a.Count -gt $d.Used) { $text = ($a[$d.Used..($a.Count - 1)]) -join ' ' }
    $item = New-JkReminder -At (Get-JkLocalAfter $secs) -Text $text
    Write-JkReminderSet $item
}

# jk at 3:30pm call home   |   jk at tomorrow 9am submit form   |   jk at fri 17:00 ...
function Invoke-JkRemindAt {
    $a = @($args | ForEach-Object { [string]$_ })
    if ($a.Count -eq 0) { throw 'usage: jk at <time | day time> <message>' }
    $found = Resolve-JkAtTime $a (Get-Date)
    $text = ''
    if ($a.Count -gt $found.K) { $text = ($a[$found.K..($a.Count - 1)]) -join ' ' }
    $item = New-JkReminder -At $found.At -Text $text
    Write-JkReminderSet $item
}

# Finds the time at the start of "3:30pm call home" / "tomorrow 9am submit" / "5 leave";
# returns the moment and how many words it used.
function Resolve-JkAtTime([string[]]$Words, [datetime]$Now) {
    $a = $Words
    $now = $Now
    $found = $null
    for ($k = [Math]::Min(3, $a.Count); $k -ge 1; $k--) {
        $head = ($a[0..($k - 1)]) -join ' '
        $dt = $null
        try {
            $t = ConvertTo-JkTime $head
            $p = $t.Split(':')
            $dt = $now.Date.AddHours([int]$p[0]).AddMinutes([int]$p[1])
            # "jk at 5" without am/pm means the next 5 o'clock: 5 pm if it's already past 5 am
            if ($head -match '^\s*(\d{1,2})(:\d{2})?\s*$|^\s*[1-9]\d{2}\s*$' -and [int]$p[0] -ge 1 -and [int]$p[0] -le 11) {
                $pm = $dt.AddHours(12)
                if ($dt -le $now -and $pm -gt $now) { $dt = $pm }
            }
            if ($dt -le $now) { $dt = $dt.AddDays(1) }
        } catch {
            try {
                $w = ConvertFrom-JkWhen $head
                if ($w.Time) { $p = $w.Time.Split(':'); $dt = $w.Date.AddHours([int]$p[0]).AddMinutes([int]$p[1]) }
            } catch { }
        }
        if ($dt) { $found = @{ At = $dt; K = $k }; break }
    }
    if (-not $found) { throw "can't find a time in '$($a -join ' ')' (try: jk at 3:30pm ..., jk at tomorrow 9am ...)" }
    if ($found.At -le $now) { throw 'that time has already passed' }
    [pscustomobject]$found
}

function Show-JkReminders {
    $items = @(Get-JkReminderList)
    Write-JkHeader 'Reminders' "$($items.Count) pending"
    if ($items.Count -eq 0) { Say (Paint 'gray' '  None. Set one:  jk in 20m "stretch"   or   jk at 5pm "leave for bus"') }
    foreach ($i in $items) {
        $at = [datetime]::Parse([string]$i.at, $script:Inv)
        $alive = Test-JkBackgroundAlive ([int]$i.pid) ([string]$i.spawned)
        $state = ''
        if (-not $alive) { $state = Paint 'red' '  (timer not running - jk remind tick re-arms it)' }
        Say ('  ' + (Paint 'gray' ("#$($i.id)".PadLeft(4))) + '  ' + (Paint 'amber' (Fit ($at.ToString('ddd MMM d ', $script:Inv) + (Format-JkTime $at.ToString('HH:mm'))) 20)) + (Paint 'gray' (Fit ("in " + (Format-JkDuration ($at - (Get-Date)))) 12)) + [string]$i.text + $state)
    }
    Say ''
    $info = Get-JkTaskInfo
    if ($info) {
        $next = ''
        if ($info.NextRunTime) { $next = " $($script:G.dot) next run $($info.NextRunTime.ToString('ddd h:mm tt', $script:Inv))" }
        Say ('  ' + (Paint 'green' "$($script:G.check) morning brief installed") + (Paint 'gray' " ($($info.State)$next)"))
    } else {
        Say ('  ' + (Paint 'yellow' 'morning brief not installed') + (Paint 'gray' ' - run: jk remind install'))
    }
}

function Cancel-JkReminder {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Ids)
    if (-not $Ids) { throw 'usage: jk remind cancel <id>' }
    $classCancelled = $false
    $lock = Enter-JkReminderLock
    try {
        $d = Get-JkReminderData
        foreach ($r in $Ids) {
            $id = [int]($r.TrimStart('#'))
            $hit = @($d.items | Where-Object { [int]$_.id -eq $id })
            if (-not $hit) { Say (Paint 'red' "  no reminder #$id"); continue }
            if (Test-JkBackgroundAlive ([int]$hit[0].pid) ([string]$hit[0].spawned)) { Stop-JkProcessTree ([int]$hit[0].pid) }
            $d.items = @($d.items | Where-Object { [int]$_.id -ne $id })
            if (([string](Get-JkProp $hit[0] 'key' '')).StartsWith('class:')) { $classCancelled = $true }
            Say ((Paint 'yellow' '  cancelled') + "  #$id $($hit[0].text)")
        }
        Save-JkReminderData $d
    } finally { Exit-JkReminderLock $lock }
    # class alerts are chained: skipping one class must not silence the rest of the day
    if ($classCancelled) {
        $next = Register-JkClassAlert
        if ($next) { Say (Paint 'gray' "  next class alert: $($next.text)") }
    }
}

# ---------------------------------------------------------------- daily scheduled task

# The task's state through the Task Scheduler COM API: about 80 ms, where Get-ScheduledTask
# first loads the ScheduledTasks CIM module (about 1.2 s). $null when it is not installed.
function Get-JkTaskInfo {
    if ($env:JK_SANDBOX) { return $null }   # a sandboxed install has no task (and must not report the real one)
    try {
        $svc = New-Object -ComObject Schedule.Service
        $svc.Connect()
        $t = $svc.GetFolder('\').GetTask($script:JkTaskName)
    } catch { return $null }
    $states = @('Unknown', 'Disabled', 'Queued', 'Ready', 'Running')
    $state = 'Unknown'; if ([int]$t.State -ge 0 -and [int]$t.State -lt $states.Count) { $state = $states[[int]$t.State] }
    # "never" comes back as a date in 1899
    $last = $null; if (([datetime]$t.LastRunTime).Year -gt 2000) { $last = [datetime]$t.LastRunTime }
    $next = $null; if (([datetime]$t.NextRunTime).Year -gt 2000) { $next = [datetime]$t.NextRunTime }
    # an install from before the daily trigger kept local time
    $utc = $false
    try { foreach ($tr in $t.Definition.Triggers) { if ($tr.Type -eq 2 -and (Test-JkTriggerPinnedToUtc ([string]$tr.StartBoundary))) { $utc = $true } } } catch { }
    [pscustomobject]@{ State = $state; NextRunTime = $next; LastRunTime = $last; LastTaskResult = [int]$t.LastTaskResult; PinnedToUtc = $utc }
}

function Get-JkTaskCommand {
    $psd1 = Join-Path (Get-JkRoot) 'jk.psd1'
    "Import-Module '$($psd1.Replace("'", "''"))'; jk remind tick"
}

# A daily trigger at local wall-clock time. New-ScheduledTaskTrigger stores the start in UTC
# ("11:45:00Z" for 7:45 am in Waterloo), which Task Scheduler treats as "synchronize across time
# zones": the task keeps that UTC time, so after daylight saving time ends it fires at 6:45.
function New-JkDailyTrigger([datetime]$At) {
    $t = New-ScheduledTaskTrigger -Daily -At $At
    $t.StartBoundary = $At.ToString('yyyy-MM-ddTHH:mm:ss', $script:Inv)
    $t
}

# True when a trigger start carries a UTC offset or Z, i.e. it drifts an hour across DST changes.
function Test-JkTriggerPinnedToUtc([string]$StartBoundary) { $StartBoundary -match '(Z|[+-]\d{2}:\d{2})$' }

function Install-JkRemindTask {
    if ($env:JK_SANDBOX) { Say (Paint 'gray' "  scheduled task skipped (sandbox $env:JK_SANDBOX)"); return $false }
    $time = Get-JkConfig 'remind.time'
    $ps = Get-JkPowerShellExe
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$(Get-JkTaskCommand)`""
    if (Test-Path $conhost) { $action = New-ScheduledTaskAction -Execute $conhost -Argument "--headless `"$ps`" $psArgs" }
    else { $action = New-ScheduledTaskAction -Execute $ps -Argument $psArgs }
    $at = [datetime]::ParseExact($time, 'HH:mm', $script:Inv)
    $triggers = @(New-JkDailyTrigger $at)
    $logon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $logon.Delay = 'PT2M'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew
    $desc = 'jk: shows a popup for course deadlines due soon and re-arms jk reminders after a restart. Remove with: jk remind uninstall'
    $ok = $false
    try {
        Register-ScheduledTask -TaskName $script:JkTaskName -Action $action -Trigger ($triggers + $logon) -Settings $settings -Description $desc -Force -ErrorAction Stop | Out-Null
        $ok = $true
        Say ((Paint 'green' "  $($script:G.check) installed task '$($script:JkTaskName)'") + (Paint 'gray' " $($script:G.dot) daily at $(Format-JkTime $time) and 2 min after you sign in"))
    } catch {
        # logon triggers can need elevation on some machines; fall back to the daily trigger alone
        Register-ScheduledTask -TaskName $script:JkTaskName -Action $action -Trigger $triggers -Settings $settings -Description $desc -Force -ErrorAction Stop | Out-Null
        $ok = $true
        Say ((Paint 'green' "  $($script:G.check) installed task '$($script:JkTaskName)'") + (Paint 'gray' " $($script:G.dot) daily at $(Format-JkTime $time) (runs late if the PC was off)"))
    }
    $ok
}

function Uninstall-JkRemindTask {
    if ($env:JK_SANDBOX) { Say (Paint 'gray' '  scheduled task skipped (sandbox)'); return }
    if (Get-JkTaskInfo) {
        Unregister-ScheduledTask -TaskName $script:JkTaskName -Confirm:$false
        Say (Paint 'yellow' "  removed task '$($script:JkTaskName)'")
    } else { Say (Paint 'gray' "  task '$($script:JkTaskName)' was not installed") }
}

function Invoke-JkRemind {
    $a = @($args)
    if ($a.Count -eq 0) { Show-JkReminders; return }
    $first = ([string]$a[0]).ToLower()
    $rest = @()
    if ($a.Count -gt 1) { $rest = @($a[1..($a.Count - 1)]) }
    switch -Regex ($first) {
        '^(list|ls|status)$' { Show-JkReminders; return }
        '^(cancel|rm|stop|del)$' { Cancel-JkReminder @rest; return }
        '^(install|enable)$' { $null = Install-JkRemindTask; return }
        '^(uninstall|disable|remove)$' { Uninstall-JkRemindTask; return }
        '^(tick)$' {
            try { Limit-JkBackgroundLog } catch { }
            try { $null = Sync-JkBackupMirror } catch { Add-Content -LiteralPath (Get-JkPath 'background.log') -Value ((Get-Date -Format s) + ' backup mirror: ' + $_.Exception.Message) }
            Restore-JkReminders
            try { Restore-JkFocusTimer } catch { Add-Content -LiteralPath (Get-JkPath 'background.log') -Value ((Get-Date -Format s) + ' focus timer: ' + $_.Exception.Message) }
            # refresh deadlines from the saved calendar feed first (offline mornings just skip it)
            if (Get-JkConfig 'sync.url') { try { Invoke-JkDueSync -Quiet } catch { Add-Content -LiteralPath (Get-JkPath 'background.log') -Value ((Get-Date -Format s) + ' sync: ' + $_.Exception.Message) } }
            try { $null = Register-JkTodayAlerts } catch { Add-Content -LiteralPath (Get-JkPath 'background.log') -Value ((Get-Date -Format s) + ' alerts: ' + $_.Exception.Message) }
            try { $null = Register-JkClassAlert } catch { Add-Content -LiteralPath (Get-JkPath 'background.log') -Value ((Get-Date -Format s) + ' class alert: ' + $_.Exception.Message) }
            # a fresh forecast for the brief, the dashboard and the popup. Just woken, the Wi-Fi can
            # take a while to come back: try again for up to 45 s (offline mornings keep the old one)
            try {
                $tries = $(if ((Get-JkWeatherPlace) -and -not $env:JK_NOW) { 4 } else { 0 })
                for ($try = 0; $try -lt $tries; $try++) {
                    if ($try) { Start-Sleep -Seconds 15 }
                    $wx = Get-JkWeather -TimeoutSec 10
                    if ($wx -and -not $wx.Stale) { break }
                }
            } catch { }
            Invoke-JkDueRemind -Quiet
            return
        }
        '^(now|due)$' { Invoke-JkDueRemind -Force @rest; return }
        '^(test|demo)$' {
            $mode = Show-JkNotify -Title 'jk notifications work' -Lines @('This is what reminders, focus timers and deadline alerts look like.', 'Hover to keep it open; click x to dismiss.') -Accent $script:JkPalette.green -Seconds 10 -Sound
            Say (Paint 'green' "  sent a test notification ($mode)")
            return
        }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'remind'; return }
    }
    throw "unknown 'remind' action '$first' (try: jk remind help)"
}
