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
    if ($t -match '^0+(\.0+)?$|^0+:00$') { throw "a duration can't be zero (try 25, 25m, 1h30m, 90s)" }
    if ($t -match '^\d+(\.\d+)?$') { return [int]([double]$t * 60) }
    if ($t -match '^(\d+):(\d{2})$') { return [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 }
    # "1h30": the minutes without their m
    if ($t -match '^(\d+)h(\d{1,2})$') { return [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 }
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

# The duration at the start of what was typed, and how many words it took: "20m", "1h30",
# "2 hours", "1h 30m", or a bare number of minutes ("45 call"). The rest is the message.
$script:JkUnitWord = '^(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)$'

function Read-JkDurationWords([string[]]$Words) {
    $parts = @(); $i = 0
    $lw = @($Words | ForEach-Object { ([string]$_).ToLower() })
    # "jk focus for 30 minutes"
    if ($lw.Count -gt 1 -and $lw[0] -eq 'for') { $i = 1 }
    $start = $i
    while ($i -lt $lw.Count) {
        $w = $lw[$i]
        $next = ''; if ($i + 1 -lt $lw.Count) { $next = $lw[$i + 1] }
        # "half an hour", "a quarter of an hour"
        $tail = ($lw[$i..([Math]::Min($i + 4, $lw.Count - 1))]) -join ' '
        if ($tail -match '^(?:a\s+)?(half|quarter)\s+(?:of\s+)?(?:an\s+)?hour\b') {
            $parts += $(if ($Matches[1] -eq 'half') { '30m' } else { '15m' })
            $i += @($Matches[0] -split '\s+').Count
            continue
        }
        # "an hour", "a minute"
        if ($w -match '^(a|an|one)$' -and $next -match $script:JkUnitWord) { $w = '1' }
        if ($w -match '^\d+(\.\d+)?$' -and $next -match $script:JkUnitWord) {
            $parts += $w + $next; $i += 2
            # "an hour and a half"
            if (($lw[$i..([Math]::Min($i + 2, $lw.Count - 1))] -join ' ') -eq 'and a half' -and $next -match '^[hm]') {
                $parts += $(if ($next -like 'h*') { '30m' } else { '30s' }); $i += 3
            }
            continue
        }
        if ($w -match '^(\d+(\.\d+)?(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s))+$' -or $w -match '^\d+h\d{1,2}$') { $parts += $w; $i++; continue }
        # "1 hour and 30 minutes"
        if ($w -eq 'and' -and $parts.Count -and $next -match '^\d') { $i++; continue }
        if ($i -eq $start -and $w -match '^\d+(\.\d+)?$|^\d+:\d{2}$') { $parts += $w; $i++; break }
        break
    }
    if (-not $parts.Count) { throw "can't understand the duration '$($Words[0])' (try 25, 25m, 1h30m, 2 hours, 90s)" }
    [pscustomobject]@{ Seconds = (ConvertTo-JkSeconds ($parts -join '')); Used = $i }
}

function Get-JkFocusData {
    $d = Read-JkJson 'focus.json' $null
    if (-not $d) { $d = [pscustomobject]@{ active = $null; sessions = @() } }
    if ($null -eq (Get-JkProp $d 'sessions')) { Set-JkProp $d 'sessions' @() }
    if (-not $d.PSObject.Properties['active']) { Set-JkProp $d 'active' $null }
    # a session whose start or minutes no screen can read is kept aside, not counted (core.ps1)
    Split-JkUnreadable $d 'sessions' {
        param($s)
        $x = [datetime]::MinValue; $n = 0.0
        if (-not [datetime]::TryParse([string]$s.start, $script:Inv, [Globalization.DateTimeStyles]::None, [ref]$x)) { return $false }
        foreach ($k in 'actual', 'minutes') { $v = Get-JkProp $s $k $null; if ($null -ne $v -and -not [double]::TryParse([string]$v, [Globalization.NumberStyles]::Float, $script:Inv, [ref]$n)) { return $false } }
        $true
    }
    $d
}

function Save-JkFocusData($Data) { $Data.sessions = @($Data.sessions); Save-JkWithUnreadable $Data 'sessions' { Save-JkJson 'focus.json' $Data } }

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
    # a session whose timer a restart took is re-armed (or closed) first, never silently replaced
    Restore-JkFocusTimer
    $d = Get-JkFocusData
    if ($d.active -and (Test-JkBackgroundAlive ([int]$d.active.pid) ([string]$d.active.spawned))) {
        $null = Show-JkFocusStatus
        Say (Paint 'gray' "  A session is already running. 'jk focus stop' ends it early.")
        return
    }
    if (-not $Minutes) { $Minutes = Get-JkConfig 'focus.minutes' }
    # "jk focus 2 hours cs350": the unit word belongs to the length, not the label
    $words = @(@($Minutes) + @($Label) | Where-Object { $_ })
    $dur = Read-JkDurationWords $words
    $secs = $dur.Seconds
    $Label = @($words | Select-Object -Skip $dur.Used)
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

# After a restart (a Windows update in the middle of a block) the timer process is gone. A session
# with time left gets a new timer for its original end, so the popup still comes; one whose end
# has passed is logged at its planned length and closed.
function Restore-JkFocusTimer {
    $d = Get-JkFocusData
    $a = $d.active
    if (-not $a -or (Test-JkBackgroundAlive ([int]$a.pid) ([string]$a.spawned))) { return }
    $start = [datetime]::Parse([string]$a.start, $script:Inv)
    $planned = [double]$a.seconds / 60
    $end = $start.AddSeconds([double]$a.seconds)
    if ($end -gt (Get-Date).AddSeconds(30)) {
        $proc = Start-JkBackground -Script "Complete-JkFocusSession -Id '$($a.id)'" -WaitUntil ($end.ToString('o', $script:Inv))
        $a.pid = $proc.Id
        $a.spawned = $proc.StartTime.ToString('s', $script:Inv)
        Save-JkFocusData $d
        return
    }
    $elapsed = [Math]::Min(((Get-Date) - $start).TotalMinutes, $planned)
    if ($elapsed -ge 1) { $d.sessions = @($d.sessions) + [pscustomobject]@{ label = [string]$a.label; start = [string]$a.start; planned = $planned; actual = [Math]::Round($elapsed, 1); completed = ($elapsed -ge $planned) } }
    $d.active = $null
    Save-JkFocusData $d
}

function Show-JkFocusStatus {
    Restore-JkFocusTimer
    $d = Get-JkFocusData
    $a = $d.active
    if (-not $a) { return $false }
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
    if ($Days -lt 1 -or $Days -gt 366) { throw 'jk focus log takes 1 to 366 days' }
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

# Time worked without the timer (an afternoon in the library, a study group): logged as a session
# that ends now, or at 10 pm the day before with "yesterday", so jk plan, jk next and the focus log
# count it like a timed block.
function Add-JkFocusLog {
    $words = @($args | ForEach-Object { [string]$_ } | Where-Object { $_ })
    if (-not $words.Count) { throw 'usage: jk focus add <length> <label>  (jk focus add 1h30m cs350 a3, or ... yesterday)' }
    $dur = Read-JkDurationWords $words
    $mins = [Math]::Round($dur.Seconds / 60.0, 1)
    if ($mins -lt 1) { throw 'jk focus add logs a minute or more' }
    if ($mins -gt 720) { throw "$(Format-JkMinutes $mins) at once is more than 12 hours: log each sitting on its own" }
    $lenText = ($words[0..($dur.Used - 1)] -join ' ')
    $rest = @($words | Select-Object -Skip $dur.Used)
    $now = Get-JkNow
    $end = $now
    if ($rest.Count -and $rest[-1] -match '^(?i)(yesterday|yday|yest)$') {
        $end = $now.Date.AddDays(-1).AddHours(22)
        $rest = @($rest | Select-Object -First ($rest.Count - 1))
    }
    if ($rest.Count -and $rest[0] -match '^(?i)on$') { $rest = @($rest | Select-Object -Skip 1) }
    $lbl = ($rest -join ' ').Trim()
    $start = $end.AddMinutes(-$mins)
    $d = Get-JkFocusData
    $d.sessions = @($d.sessions) + [pscustomobject]@{ label = $lbl; start = $start.ToString('s', $script:Inv); planned = $mins; actual = $mins; completed = $true; added = $true }
    Save-JkFocusData $d
    # the day's total, as the focus log counts it: by the day each session starts
    $dayIso = $start.ToString('yyyy-MM-dd', $script:Inv)
    $dayTotal = 0.0
    foreach ($s in @($d.sessions)) { if (([string]$s.start).StartsWith($dayIso)) { $dayTotal += [double]$s.actual } }
    $dayWord = $start.ToString('ddd MMM d', $script:Inv)
    if ($start.Date -eq $now.Date) { $dayWord = 'today' } elseif ($start.Date -eq $now.Date.AddDays(-1)) { $dayWord = 'yesterday' }
    $what = ''
    if ($lbl) { $what = ' on ' + (Paint "bold #$(Get-JkLabelColor $lbl)" (Format-JkFocusLabel $lbl)) }
    Say ''
    Say ('  ' + (Paint 'bold green' "$($script:G.check) Logged") + " $(Format-JkMinutes $mins)$what" + (Paint 'gray' "  $($script:G.dot)  focused $dayWord $(Format-JkMinutes $dayTotal)"))
    $c = $null
    if ($lbl) { $c = Resolve-JkCourse (Get-JkDueData -Cached) (($lbl -split '\s+')[0]) }
    if (-not $c) {
        Say (Paint 'gray' "    No course in the label, so jk plan does not count it: begin it with one (jk focus add $lenText cs350 ...).")
    } else {
        # what is left of the course in today's plan
        $line = "    jk plan counts it toward $($c.code)'s deadlines."
        try {
            if ($start.Date -eq $now.Date) {
                $left = 0.0; $want = 0.0
                foreach ($r in @(Get-JkPlanLeft (Get-JkPlanToday) (Get-JkTodayFocusByCourse $now))) {
                    if ($r.Item.Course -eq [string]$c.key) { $left += $r.Left; $want += $r.Want }
                }
                if ($want -gt 0 -and $left -le 0) { $line = "    $($c.code) is covered for today in jk plan $($script:G.check)" }
                elseif ($want -gt 0) { $line = "    $($c.code) in today's plan: $(Format-JkMinutes $left) to go  $($script:G.dot)  jk plan" }
            }
        } catch { }
        Say (Paint 'gray' $line)
    }
    Say (Paint 'gray' '    jk focus undo takes it back')
}

# Takes back the newest logged session (jk focus add's or the timer's), saying what it was.
function Undo-JkFocusLog {
    $d = Get-JkFocusData
    $all = @($d.sessions)
    if (-not $all.Count) { Say (Paint 'gray' '  Nothing logged to take back.'); return }
    $last = $all[-1]
    $d.sessions = @($all | Select-Object -First ($all.Count - 1))
    Save-JkFocusData $d
    $lbl = Format-JkFocusLabel ([string]$last.label); if (-not $lbl) { $lbl = 'no label' }
    $at = [datetime]::Parse([string]$last.start, $script:Inv)
    Say ((Paint 'yellow' '  Taken back') + " $(Format-JkMinutes ([double]$last.actual)) on $lbl" + (Paint 'gray' "  $($script:G.dot)  from $($at.ToString('ddd MMM d', $script:Inv)) $(Format-JkTime $at.ToString('HH:mm'))"))
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
        '^(add|did|done|record)$' { Add-JkFocusLog @rest; return }
        '^(undo|unlog)$' { Undo-JkFocusLog; return }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'focus'; return }
    }
    # jk focus 50 cs350 a2a   |   jk focus for half an hour   |   jk focus cs350 (default length)
    $isDuration = $true
    try { $null = Read-JkDurationWords @($a | ForEach-Object { [string]$_ }) } catch { $isDuration = $false }
    if ($isDuration) { Start-JkFocus @a } else { Start-JkFocus '' @a }
}
