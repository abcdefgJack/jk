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

function Get-JkReminderList { @((Get-JkReminderData).items | Sort-Object at) }

function New-JkReminder {
    param([datetime]$At, [string]$Text)
    if (-not $Text) { $Text = 'Reminder' }
    $d = Get-JkReminderData
    $id = [int](Get-JkProp $d 'nextId' 1)
    $d.nextId = $id + 1
    # spawn first, then save once with the pid: the timer needs over a second just to load,
    # so the record is on disk long before it can fire (no read-modify-write race)
    $p = Start-JkBackground -Script (Get-JkReminderScript $id $At)
    $item = [pscustomobject][ordered]@{ id = $id; text = $Text; at = $At.ToString('s', $script:Inv); created = (Get-Date).ToString('s', $script:Inv); pid = $p.Id; spawned = $p.StartTime.ToString('s', $script:Inv) }
    $d.items = @($d.items) + $item
    Save-JkReminderData $d
    $item
}

function Get-JkReminderScript([int]$Id, [datetime]$At) {
    "Wait-JkUntil '$($At.ToString('o', $script:Inv))'; Complete-JkReminder -Id $Id"
}

# Re-arms an existing reminder (after a restart).
function Start-JkReminderProcess($Item) {
    $at = [datetime]::Parse([string]$Item.at, $script:Inv)
    $p = Start-JkBackground -Script (Get-JkReminderScript ([int]$Item.id) $at)
    $d = Get-JkReminderData
    foreach ($i in @($d.items)) {
        if ([int]$i.id -eq [int]$Item.id) { $i.pid = $p.Id; $i.spawned = $p.StartTime.ToString('s', $script:Inv) }
    }
    Save-JkReminderData $d
}

# Runs in the background process when a reminder is due.
function Complete-JkReminder {
    param([int]$Id, [switch]$Missed)
    $d = Get-JkReminderData
    $item = @($d.items | Where-Object { [int]$_.id -eq $Id })
    if (-not $item) { return }
    $item = $item[0]
    $d.items = @($d.items | Where-Object { [int]$_.id -ne $Id })
    Save-JkReminderData $d
    $at = [datetime]::Parse([string]$item.at, $script:Inv)
    $lines = @()
    if ($Missed) { $lines += "Missed while the computer was off $($script:G.dot) was due $(Format-JkTime $at.ToString('HH:mm')) $($at.ToString('ddd MMM d', $script:Inv))" }
    else { $lines += "Set $(Format-JkRelTime ([datetime]::Parse([string]$item.created, $script:Inv)))" }
    $null = Show-JkNotify -Title ([string]$item.text) -Lines $lines -Accent $script:JkPalette.amber -Seconds 0 -Sound -Wait
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
    if ($a.Count -eq 0) { throw 'usage: jk in <20m|1h30m|90s> <message>' }
    $secs = ConvertTo-JkSeconds $a[0]
    $text = ''
    if ($a.Count -gt 1) { $text = ($a[1..($a.Count - 1)]) -join ' ' }
    $item = New-JkReminder -At ((Get-Date).AddSeconds($secs)) -Text $text
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
            if ($head -match '^\s*(\d{1,2})(:\d{2})?\s*$' -and [int]$p[0] -ge 1 -and [int]$p[0] -le 11) {
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
    $task = Get-ScheduledTask -TaskName $script:JkTaskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
        $next = ''
        if ($info -and $info.NextRunTime) { $next = " $($script:G.dot) next run $($info.NextRunTime.ToString('ddd h:mm tt', $script:Inv))" }
        Say ('  ' + (Paint 'green' "$($script:G.check) morning brief installed") + (Paint 'gray' " ($($task.State)$next)"))
    } else {
        Say ('  ' + (Paint 'yellow' 'morning brief not installed') + (Paint 'gray' ' - run: jk remind install'))
    }
}

function Cancel-JkReminder {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Ids)
    if (-not $Ids) { throw 'usage: jk remind cancel <id>' }
    $d = Get-JkReminderData
    foreach ($r in $Ids) {
        $id = [int]($r.TrimStart('#'))
        $hit = @($d.items | Where-Object { [int]$_.id -eq $id })
        if (-not $hit) { Say (Paint 'red' "  no reminder #$id"); continue }
        if (Test-JkBackgroundAlive ([int]$hit[0].pid) ([string]$hit[0].spawned)) { Stop-JkProcessTree ([int]$hit[0].pid) }
        $d.items = @($d.items | Where-Object { [int]$_.id -ne $id })
        Say ((Paint 'yellow' '  cancelled') + "  #$id $($hit[0].text)")
    }
    Save-JkReminderData $d
}

# ---------------------------------------------------------------- daily scheduled task

function Get-JkTaskCommand {
    $psd1 = Join-Path (Get-JkRoot) 'jk.psd1'
    "Import-Module '$($psd1.Replace("'", "''"))'; jk remind tick"
}

function Install-JkRemindTask {
    $time = Get-JkConfig 'remind.time'
    $ps = Get-JkPowerShellExe
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$(Get-JkTaskCommand)`""
    if (Test-Path $conhost) { $action = New-ScheduledTaskAction -Execute $conhost -Argument "--headless `"$ps`" $psArgs" }
    else { $action = New-ScheduledTaskAction -Execute $ps -Argument $psArgs }
    $at = [datetime]::ParseExact($time, 'HH:mm', $script:Inv)
    $triggers = @(New-ScheduledTaskTrigger -Daily -At $at)
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
    if (Get-ScheduledTask -TaskName $script:JkTaskName -ErrorAction SilentlyContinue) {
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
        '^(tick)$' { Restore-JkReminders; Invoke-JkDueRemind -Quiet; return }
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
