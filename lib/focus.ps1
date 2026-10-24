# focus.ps1 - focus timer:  jk focus 50 cs350 a2a   ->  popup when time is up, stats with jk focus log

$script:Inv = [Globalization.CultureInfo]::InvariantCulture

# True when $ProcessId is still the background process jk started (guards against PID reuse).
function Test-JkBackgroundAlive {
    param([int]$ProcessId, [string]$StartedIso)
    if (-not $ProcessId) { return $false }
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    if ($p.ProcessName -notmatch '^(conhost|powershell)$') { return $false }
    if ($StartedIso) {
        try {
            $started = [datetime]::Parse($StartedIso, $script:Inv)
            if ([Math]::Abs(($p.StartTime - $started).TotalSeconds) -gt 120) { return $false }
        } catch { }
    }
    $true
}

# taskkill /T ends the whole tree at once (conhost and the PowerShell inside it); finding the
# children through CIM instead costs about a second just to load the module.
function Stop-JkProcessTree([int]$ProcessId) {
    try { $null = & "$env:SystemRoot\System32\taskkill.exe" /PID $ProcessId /T /F 2>&1 } catch { }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

# "25", "25m", "1h", "1h30m", "90s", "1:30" (h:mm) -> seconds
function ConvertTo-JkSeconds([string]$Text) {
    $t = $Text.Trim().ToLower()
    if ($t -match '^\d+(\.\d+)?$') { return [int]([double]$t * 60) }
    if ($t -match '^(\d+):(\d{2})$') { return [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 }
    $total = 0.0
    $rest = $t
    # longest unit names first so "2 hours" is not read as "2 h" + "ours"
    foreach ($m in [regex]::Matches($t, '(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)(?![a-z])')) {
        $v = [double]$m.Groups[1].Value
        switch -Regex ($m.Groups[2].Value) {
            '^h' { $total += $v * 3600 }
            '^m' { $total += $v * 60 }
            '^s' { $total += $v }
        }
        $rest = $rest.Replace($m.Value, '')
    }
    if ($total -le 0 -or $rest.Trim()) { throw "can't understand the duration '$Text' (try 25, 25m, 1h30m, 90s)" }
    [int]$total
}

function Get-JkFocusData {
    $d = Read-JkJson 'focus.json' $null
    if (-not $d) { $d = [pscustomobject]@{ active = $null; sessions = @() } }
    if ($null -eq (Get-JkProp $d 'sessions')) { Set-JkProp $d 'sessions' @() }
    if (-not $d.PSObject.Properties['active']) { Set-JkProp $d 'active' $null }
    $d
}

function Save-JkFocusData($Data) { $Data.sessions = @($Data.sessions); Save-JkJson 'focus.json' $Data }

function Get-JkFocusMinutes([datetime]$Since, $Data = (Get-JkFocusData)) {
    $sum = 0.0
    foreach ($s in @($Data.sessions)) {
        if ([datetime]::Parse([string]$s.start, $script:Inv) -ge $Since) { $sum += [double]$s.actual }
    }
    $sum
}

function Format-JkMinutes([double]$Minutes) {
    if ($Minutes -gt 0 -and $Minutes -lt 1) { return ('{0}s' -f [int][Math]::Round($Minutes * 60)) }
    $m = [int][Math]::Round($Minutes)
    if ($m -ge 60) { return ('{0}h {1:00}m' -f [int][Math]::Floor($m / 60), ($m % 60)) }
    "${m}m"
}

function Get-JkLabelColor([string]$Label) {
    if (-not $Label) { return $script:JkPalette.blue }
    $data = Get-JkDueData -Cached
    $first = ($Label -split '\s+')[0]
    $c = Resolve-JkCourse $data $first
    if ($c -and $c.color) { return ([string]$c.color).TrimStart('#') }
    $script:JkPalette.blue
}

# "health midterm 1" -> "HEALTH 105 midterm 1" for display (the stored label keeps the key,
# which is what attributes the time to the course)
function Format-JkFocusLabel([string]$Label) {
    if (-not $Label) { return $Label }
    $words = @($Label -split '\s+')
    $c = Resolve-JkCourse (Get-JkDueData -Cached) $words[0]
    if (-not $c) { return $Label }
    (@([string]$c.code) + @($words | Select-Object -Skip 1)) -join ' '
}

function Start-JkFocus {
    param(
        [Parameter(Position = 0)][string]$Minutes,
        [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Label
    )
    $d = Get-JkFocusData
    if ($d.active -and (Test-JkBackgroundAlive ([int]$d.active.pid) ([string]$d.active.spawned))) {
        $null = Show-JkFocusStatus
        Say (Paint 'gray' "  A session is already running. 'jk focus stop' ends it early.")
        return
    }
    if (-not $Minutes) { $Minutes = Get-JkConfig 'focus.minutes' }
    $secs = ConvertTo-JkSeconds $Minutes
    $lbl = ($Label -join ' ').Trim()
    $now = Get-Date
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $end = Get-JkLocalAfter $secs
    $endIso = $end.ToString('o', $script:Inv)
    $proc = Start-JkBackground -Script "Complete-JkFocusSession -Id '$id'" -WaitUntil $endIso
    $d.active = [pscustomobject]@{
        id      = $id
        label   = $lbl
        start   = $now.ToString('s', $script:Inv)
        seconds = $secs
        pid     = $proc.Id
        spawned = $proc.StartTime.ToString('s', $script:Inv)
    }
    Save-JkFocusData $d
    $what = ''
    if ($lbl) { $what = " on " + (Paint "bold #$(Get-JkLabelColor $lbl)" (Format-JkFocusLabel $lbl)) }
    Say ''
    Say ('  ' + (Paint 'bold green' "$($script:G.circle) Focus") + " for $(Format-JkMinutes ($secs / 60))$what" + (Paint 'gray' "  $($script:G.dot) ends $(Format-JkTime $end.ToString('HH:mm'))"))
    Say (Paint 'gray' "    A popup will tell you when time is up.  jk focus  (status)  $($script:G.dot)  jk focus stop")
}

# Runs in the background process when the timer fires.
function Complete-JkFocusSession {
    param([string]$Id)
    $d = Get-JkFocusData
    if (-not $d.active -or [string]$d.active.id -ne $Id) { return }
    $a = $d.active
    $mins = [double]$a.seconds / 60
    $d.sessions = @($d.sessions) + [pscustomobject]@{ label = [string]$a.label; start = [string]$a.start; planned = $mins; actual = $mins; completed = $true }
    $d.active = $null
    Save-JkFocusData $d
    $today = Get-JkFocusMinutes ((Get-Date).Date) $d
    $title = 'Focus session complete'
    $lines = @()
    if ($a.label) { $lines += "$(Format-JkFocusLabel ([string]$a.label)) $($script:G.dot) $(Format-JkMinutes $mins)" } else { $lines += "$(Format-JkMinutes $mins) of focused work" }
    $lines += "Take a 5-minute break. Focused today: $(Format-JkMinutes $today)."
    $null = Show-JkNotify -Title $title -Lines $lines -Accent (Get-JkLabelColor ([string]$a.label)) -Seconds 30 -Sound -Wait
}

function Stop-JkFocus {
    $d = Get-JkFocusData
    if (-not $d.active) { Say (Paint 'gray' '  No focus session is running.'); return }
    $a = $d.active
    if (Test-JkBackgroundAlive ([int]$a.pid) ([string]$a.spawned)) { Stop-JkProcessTree ([int]$a.pid) }
    $elapsed = ((Get-Date) - [datetime]::Parse([string]$a.start, $script:Inv)).TotalMinutes
    $elapsed = [Math]::Min($elapsed, [double]$a.seconds / 60)
    if ($elapsed -ge 1) {
        $d.sessions = @($d.sessions) + [pscustomobject]@{ label = [string]$a.label; start = [string]$a.start; planned = [double]$a.seconds / 60; actual = [Math]::Round($elapsed, 1); completed = $false }
    }
    $d.active = $null
    Save-JkFocusData $d
    Say ((Paint 'yellow' '  Focus stopped') + " after $(Format-JkMinutes $elapsed)" + $(if ($elapsed -lt 1) { ' (not logged)' } else { ' (logged)' }))
}

function Show-JkFocusStatus {
    $d = Get-JkFocusData
    $a = $d.active
    if (-not $a) { return $false }
    if (-not (Test-JkBackgroundAlive ([int]$a.pid) ([string]$a.spawned))) {
        # timer process is gone (reboot/logoff): close the session at its planned length if that time passed
        $start = [datetime]::Parse([string]$a.start, $script:Inv)
        $planned = [double]$a.seconds / 60
        $elapsed = [Math]::Min(((Get-Date) - $start).TotalMinutes, $planned)
        if ($elapsed -ge 1) { $d.sessions = @($d.sessions) + [pscustomobject]@{ label = [string]$a.label; start = [string]$a.start; planned = $planned; actual = [Math]::Round($elapsed, 1); completed = ($elapsed -ge $planned) } }
        $d.active = $null
        Save-JkFocusData $d
        return $false
    }
    $start = [datetime]::Parse([string]$a.start, $script:Inv)
    $total = [double]$a.seconds
    $elapsed = ((Get-Date) - $start).TotalSeconds
    $left = [TimeSpan]::FromSeconds([Math]::Max(0, $total - $elapsed))
    $color = Get-JkLabelColor ([string]$a.label)
    $lbl = Format-JkFocusLabel ([string]$a.label)
    if (-not $lbl) { $lbl = 'focus' }
    Say ''
    Say ('  ' + (Paint "bold #$color" "$($script:G.circle) $lbl") + '  ' + (Get-JkBar ($elapsed / $total) 28 "#$color") + '  ' + (Paint 'bold white' ('{0}:{1:00}' -f [int][Math]::Floor($left.TotalMinutes), $left.Seconds)) + (Paint 'gray' ' left'))
    $true
}

function Show-JkFocusLog {
    param([int]$Days = 7)
    $d = Get-JkFocusData
    $today = (Get-Date).Date
    $since = $today.AddDays(-($Days - 1))
    $sessions = @($d.sessions | Where-Object { [datetime]::Parse([string]$_.start, $script:Inv) -ge $since })
    $total = ($sessions | Measure-Object -Property actual -Sum).Sum
    if (-not $total) { $total = 0 }
    Write-JkHeader 'Focus log' "last $Days days $($script:G.dot) $(Format-JkMinutes $total) $($script:G.dot) $(Format-JkCount $sessions.Count 'session')"
    $perDay = @{}
    foreach ($s in $sessions) { $k = ([datetime]::Parse([string]$s.start, $script:Inv)).Date.ToString('yyyy-MM-dd'); $perDay[$k] = [double]$perDay[$k] + [double]$s.actual }
    $max = 60.0
    foreach ($v in $perDay.Values) { if ($v -gt $max) { $max = $v } }
    for ($i = 0; $i -lt $Days; $i++) {
        $day = $since.AddDays($i)
        $v = [double]$perDay[$day.ToString('yyyy-MM-dd')]
        $lbl = $day.ToString('ddd MMM d', $script:Inv)
        $st = 'muted'; if ($day -eq $today) { $st = 'bold white' }
        Say ('  ' + (Paint $st (Fit $lbl 11)) + ' ' + (Get-JkBar ($v / $max) 36 'green') + '  ' + (Paint 'white' (Format-JkMinutes $v)))
    }
    $byLabel = $sessions | Group-Object { if ($_.label) { ([string]$_.label).ToLower() } else { '(unlabeled)' } } | ForEach-Object {
        [pscustomobject]@{ Label = $_.Name; Minutes = ($_.Group | Measure-Object -Property actual -Sum).Sum; Count = $_.Count }
    } | Sort-Object Minutes -Descending
    if ($byLabel) {
        Say ''
        Say (' ' + (Paint 'bold white' 'By label'))
        foreach ($b in $byLabel) {
            Say ('  ' + (Paint "#$(Get-JkLabelColor $b.Label)" (Fit $b.Label 24)) + (Paint 'white' (Fit (Format-JkMinutes $b.Minutes) 9 -Right)) + (Paint 'gray' ("  $($b.Count) session" + $(if ($b.Count -ne 1) { 's' } else { '' }))))
        }
    }
    # days with any session, parsed once
    $activeDays = @{}
    foreach ($s in @($d.sessions)) { $activeDays[([datetime]::Parse([string]$s.start, $script:Inv)).ToString('yyyy-MM-dd')] = $true }
    $streak = 0
    for ($i = 0; $i -lt 365; $i++) {
        if ($activeDays.ContainsKey($today.AddDays(-$i).ToString('yyyy-MM-dd'))) { $streak++ } elseif ($i -gt 0) { break }
    }
    if ($streak -gt 1) { Say ''; Say ('  ' + (Paint 'orange' "$($script:G.star) $streak-day focus streak")) }
}

function Invoke-JkFocus {
    $a = @($args)
    if ($a.Count -eq 0) {
        if (-not (Show-JkFocusStatus)) { Start-JkFocus }
        return
    }
    $first = ([string]$a[0]).ToLower()
    $rest = @()
    if ($a.Count -gt 1) { $rest = @($a[1..($a.Count - 1)]) }
    switch -Regex ($first) {
        '^(status|st)$' { if (-not (Show-JkFocusStatus)) { Say (Paint 'gray' '  No focus session is running. Start one: jk focus 25 cs350') }; return }
        '^(stop|cancel|end|abort)$' { Stop-JkFocus; return }
        '^(log|stats|history)$' { Show-JkFocusLog @rest; return }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'focus'; return }
    }
    # jk focus 50 cs350 a2a   |   jk focus cs350 (default length)
    $isDuration = $true
    try { $null = ConvertTo-JkSeconds $first } catch { $isDuration = $false }
    if ($isDuration) { Start-JkFocus @a } else { Start-JkFocus '' @a }
}
