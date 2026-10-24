# due.ps1 - course deadlines: list, add, complete, import, calendar/ICS export, reminders.

$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:CourseColors = @('F87171', '7C9CF8', '4FD1BE', 'B79BF6', 'F2B04A', 'F472B6', 'A3D65C', '67E8F9', 'FB923C', 'FACC15')

# ---------------------------------------------------------------- data

# -Cached returns a shared copy that is reused while the file is unchanged (path, mtime and
# size match). Only read-only callers use it; anything that edits gets a fresh object.
$script:JkDueCache = $null

function Get-JkDueData {
    param([switch]$Cached)
    if ($Cached) {
        $p = Get-JkPath 'deadlines.json'
        $stamp = "$p|none"
        if (Test-Path -LiteralPath $p) { $fi = Get-Item -LiteralPath $p; $stamp = "$p|$($fi.LastWriteTimeUtc.Ticks)|$($fi.Length)" }
        if ($script:JkDueCache -and $script:JkDueCache.Stamp -eq $stamp) { return $script:JkDueCache.Data }
        $fresh = Get-JkDueData
        $script:JkDueCache = @{ Stamp = $stamp; Data = $fresh }
        return $fresh
    }
    $d = Read-JkJson 'deadlines.json' $null
    if (-not $d) {
        $d = [pscustomobject]@{ version = 1; term = $null; courses = @(); events = @(); nextId = 1 }
    }
    foreach ($p in 'courses', 'events') { if ($null -eq (Get-JkProp $d $p)) { Set-JkProp $d $p @() } }
    if (-not (Get-JkProp $d 'nextId')) {
        $max = 0; foreach ($e in @($d.events)) { if ([int]$e.id -gt $max) { $max = [int]$e.id } }
        Set-JkProp $d 'nextId' ($max + 1)
    }
    $d
}

function Save-JkDueData($Data) {
    $Data.courses = @($Data.courses)
    $Data.events = @($Data.events | Sort-Object date, time, id)
    Save-JkJson 'deadlines.json' $Data
    $script:JkDueCache = $null
    Clear-JkBriefCache
    # keep an already-generated calendar page current (the reminder popup links to it)
    if (Test-Path -LiteralPath (Get-JkPath 'calendar.html')) { try { Export-JkDueHtml -NoOpen -Quiet } catch { } }
}

function Get-JkCourseMap($Data) {
    $m = @{}
    foreach ($c in @($Data.courses)) { $m[[string]$c.key] = $c }
    $m
}

function Get-JkEventDue($e) {
    $d = [datetime]::ParseExact([string]$e.date, 'yyyy-MM-dd', $script:Inv)
    if ($e.time) {
        $t = ([string]$e.time).Split(':')
        return $d.AddHours([int]$t[0]).AddMinutes([int]$t[1])
    }
    $d.AddHours(23).AddMinutes(59)
}

# An exam window stored as "X opens" + "X closes" (online midterms, quizzes). For either half,
# returns the shared title and both events; $null when $e is not one half of such a pair.
function Get-JkEventWindow($e, $Data) {
    $rx = '(?i)^(.*?)\s+(opens?|closes?)$'
    if ([string]$e.title -notmatch $rx) { return $null }
    $base = $Matches[1].Trim()
    $isOpen = $Matches[2] -like 'open*'
    $mine = Get-JkEventDue $e
    # weekly windows can share a title ("Quiz opens" every Monday): take the nearest other half,
    # the first closing after an opening or the last opening before a closing
    $best = $null; $bestGap = [double]::MaxValue
    foreach ($o in @($Data.events)) {
        if ($o.course -ne $e.course -or [int]$o.id -eq [int]$e.id) { continue }
        if ([string]$o.title -notmatch $rx -or $Matches[1].Trim() -ne $base -or ($Matches[2] -like 'open*') -eq $isOpen) { continue }
        $gap = ((Get-JkEventDue $o) - $mine).TotalMinutes
        if (-not $isOpen) { $gap = -$gap }
        if ($gap -ge 0 -and $gap -lt $bestGap) { $best = $o; $bestGap = $gap }
    }
    if (-not $best) { return $null }
    $open = $e; $close = $best
    if (-not $isOpen) { $open = $best; $close = $e }
    [pscustomobject]@{ Title = $base; Open = $open; Close = $close; Opens = (Get-JkEventDue $open); Closes = (Get-JkEventDue $close) }
}

function Get-JkCourseLabel($e, $cmap) {
    $c = $cmap[[string]$e.course]
    if ($c) { return [string]$c.code }
    [string]$e.course
}

function Get-JkCourseColor($key, $cmap) {
    $c = $cmap[[string]$key]
    if ($c -and $c.color) { return ([string]$c.color).TrimStart('#') }
    $script:JkPalette.muted
}

# Normalizes "CS 350", "cs350", "CS350" -> "cs350" for matching. Letters of any script
# survive, so folders such as a Chinese-named one stay addressable.
function Get-JkNormKey([string]$s) { ($s -replace '[^\p{L}\p{Nd}]', '').ToLower() }

function Resolve-JkCourse {
    param($Data, [string]$Name, [switch]$Create)
    $n = Get-JkNormKey $Name
    foreach ($c in @($Data.courses)) {
        if ((Get-JkNormKey $c.key) -eq $n -or (Get-JkNormKey $c.code) -eq $n) { return $c }
    }
    # unique prefix / substring match (e.g. "350" -> cs350, "health" -> health)
    $hits = @($Data.courses | Where-Object { (Get-JkNormKey $_.key).Contains($n) -or (Get-JkNormKey $_.code).Contains($n) })
    if ($hits.Count -eq 1 -and $n.Length -ge 2) { return $hits[0] }
    if (-not $Create) { return $null }
    $code = $Name.Trim()
    if ($code -match '^([A-Za-z]+)\s*(\d+\w*)$') { $code = $Matches[1].ToUpper() + ' ' + $Matches[2] }
    $c = [pscustomobject]@{
        key   = $n
        code  = $code
        name  = ''
        color = $script:CourseColors[@($Data.courses).Count % $script:CourseColors.Count]
        final = ''
    }
    $Data.courses = @($Data.courses) + $c
    $c
}

function New-JkEvent {
    param($Data, [string]$Course, [datetime]$Date, [string]$Time, [string]$Title, [string]$Weight, [string]$Note, [string]$Kind = 'due', [string]$End)
    $e = [pscustomobject][ordered]@{
        id     = [int]$Data.nextId
        course = $Course
        date   = $Date.ToString('yyyy-MM-dd', $script:Inv)
        time   = $Time
        end    = $End
        title  = $Title
        note   = $Note
        weight = $Weight
        kind   = $Kind
        done   = $false
        doneAt = $null
    }
    $Data.nextId = [int]$Data.nextId + 1
    $Data.events = @($Data.events) + $e
    $e
}

function Find-JkEvents {
    param($Data, [string[]]$Refs, [switch]$DoneOnly, [switch]$Any)
    $out = @()
    foreach ($r in $Refs) {
        if ($r -match '^#?(\d+)$') {
            $id = [int]$Matches[1]
            $e = @($Data.events | Where-Object { [int]$_.id -eq $id })
            if (-not $e) { throw "no deadline with id #$id (see 'jk due all')" }
            $out += $e
        } else {
            # text matches look at open items, or at finished ones when reopening
            $hits = @($Data.events | Where-Object { ($Any -or [bool]$_.done -eq [bool]$DoneOnly) -and ([string]$_.title).ToLower().Contains($r.ToLower()) })
            if ($hits.Count -eq 0) { throw "no $(if ($DoneOnly) { 'finished' } else { 'open' }) deadline matches '$r'" }
            if ($hits.Count -gt 1) {
                # prefer the single upcoming match over ones whose time already passed
                $now = Get-JkNow
                $future = @($hits | Where-Object { (Get-JkEventDue $_) -ge $now })
                if ($future.Count -eq 1) { $hits = $future }
                else { throw ("'$r' matches several deadlines: " + (($hits | ForEach-Object { "#$($_.id) $($_.title)" }) -join ', ')) }
            }
            $out += $hits
        }
    }
    $out
}

# ---------------------------------------------------------------- term info

function Get-JkTermInfo {
    param($Data, [datetime]$Now = (Get-JkNow))
    $t = Get-JkProp $Data 'term'
    if (-not $t -or -not $t.start) { return $null }
    $p = { param($s) if ($s) { [datetime]::ParseExact([string]$s, 'yyyy-MM-dd', $script:Inv) } else { $null } }
    $start = & $p $t.start
    $end = & $p (Get-JkProp $t 'classesEnd')
    $exStart = & $p (Get-JkProp $t 'examsStart')
    $exEnd = & $p (Get-JkProp $t 'examsEnd')
    $monday = { param($d) $d.Date.AddDays(-(([int]$d.DayOfWeek + 6) % 7)) }
    $breakMondays = @()
    foreach ($b in @(Get-JkProp $t 'breaks' @())) {
        $bf = & $p $b.from; $bt = & $p $b.to
        $m = & $monday $bf
        if ($m -lt $bf) { $m = $m.AddDays(7) }
        while ($m -le $bt) { $breakMondays += $m; $m = $m.AddDays(7) }
    }
    $weekOf = {
        param($d)
        $mon = & $monday $d
        $raw = [int][Math]::Floor(($mon - (& $monday $start)).TotalDays / 7) + 1
        $before = @($breakMondays | Where-Object { $_ -lt $mon }).Count
        $raw - $before
    }
    $today = $Now.Date
    $phase = 'classes'
    if ($today -lt $start) { $phase = 'before' }
    elseif ($end -and $today -gt $end -and $exStart -and $today -lt $exStart) { $phase = 'study' }
    elseif ($exStart -and $today -ge $exStart -and (-not $exEnd -or $today -le $exEnd)) { $phase = 'exams' }
    elseif ($exEnd -and $today -gt $exEnd) { $phase = 'after' }
    # a week after the stored term's exams the next term has begun (its dates come from a new
    # calendar import; a LEARN sync brings only the deadlines): name it by the season and stop
    # describing the old one
    if ($phase -eq 'after' -and $today -ge $exEnd.AddDays(7)) {
        return [pscustomobject]@{ Name = (Get-JkSeasonName $today); Start = $null; ClassesEnd = $null; ExamsStart = $null; ExamsEnd = $null; Week = $null; TotalWeeks = $null; Phase = 'next'; InBreak = $false; BreakName = ''; DaysToEnd = $null; DaysToExams = $null; Previous = [string]$t.name }
    }
    $inBreak = $breakMondays -contains (& $monday $today)
    $breakName = ''
    foreach ($b in @(Get-JkProp $t 'breaks' @())) {
        if ($today -ge (& $p $b.from) -and $today -le (& $p $b.to)) { $inBreak = $true; $breakName = [string](Get-JkProp $b 'name' 'Break') }
    }
    $total = $null
    if ($end) { $total = & $weekOf $end }
    [pscustomobject]@{
        Name        = [string]$t.name
        Start       = $start
        ClassesEnd  = $end
        ExamsStart  = $exStart
        ExamsEnd    = $exEnd
        Week        = (& $weekOf $today)
        TotalWeeks  = $total
        Phase       = $phase
        InBreak     = $inBreak
        BreakName   = $breakName
        DaysToEnd   = $(if ($end) { [int]($end - $today).TotalDays } else { $null })
        DaysToExams = $(if ($exStart) { [int]($exStart - $today).TotalDays } else { $null })
    }
}

# Waterloo's three terms by month: Winter (Jan-Apr), Spring (May-Aug), Fall (Sep-Dec).
function Get-JkSeasonName([datetime]$Date) {
    $season = 'Fall'
    if ($Date.Month -le 4) { $season = 'Winter' } elseif ($Date.Month -le 8) { $season = 'Spring' }
    "$season $($Date.Year)"
}

function Format-JkTermLine($Info) {
    if (-not $Info) { return '' }
    $parts = @($Info.Name)
    switch ($Info.Phase) {
        'before' { $parts += ('starts ' + $Info.Start.ToString('MMM d', $script:Inv)) }
        'classes' {
            if ($Info.InBreak) { $parts += $(if ($Info.BreakName) { $Info.BreakName } else { 'Break' }) }
            elseif ($Info.TotalWeeks) { $parts += "Week $($Info.Week) of $($Info.TotalWeeks)" }
            else { $parts += "Week $($Info.Week)" }
            if ($null -ne $Info.DaysToEnd) { $parts += "classes end in $($Info.DaysToEnd)d" }
            if ($null -ne $Info.DaysToExams) { $parts += "exams in $($Info.DaysToExams)d" }
        }
        'study' { $parts += "study break $($script:G.dot) exams in $($Info.DaysToExams)d" }
        'exams' { $parts += 'exam period' }
        'after' { $parts += 'term over' }
        'next' { }
    }
    $parts -join " $($script:G.dot) "
}

# ---------------------------------------------------------------- rendering

function Format-JkDueLine {
    param($e, $cmap, [int]$Width, [switch]$WithDate, [switch]$Countdown, [datetime]$Now = (Get-JkNow))
    $due = Get-JkEventDue $e
    $past = $due -lt $Now
    $done = [bool]$e.done
    $color = Get-JkCourseColor $e.course $cmap
    $code = Get-JkCourseLabel $e $cmap
    $idTxt = ('#' + $e.id).PadLeft(4)
    if ($done) { $idTxt = (' ' + $script:G.check).PadLeft(4) }
    $datePart = ''
    if ($WithDate) { $datePart = $due.ToString('ddd MMM dd', $script:Inv) + '  ' }
    $tag = ''
    if ($e.kind -eq 'exam') { $tag = 'EXAM' } elseif ($e.kind -eq 'appt') { $tag = 'APPT' }
    $timeTxt = Format-JkTime ([string]$e.time)
    $left = ''
    if ($Countdown -and -not $done -and -not $past -and ($due - $Now).TotalHours -le 48) { $left = Format-JkDuration ($due - $Now) }
    if ($Countdown -and -not $done -and $past) { $left = 'passed' }
    $weight = [string]$e.weight
    # indent, id, gap, code, [date], space, title, space, tag(6), time(9), [countdown(9)], gap, weight(6)
    $fixed = 2 + 4 + 2 + 11 + $datePart.Length + 1 + 1 + 6 + 9 + 2 + 6
    if ($Countdown) { $fixed += 9 }
    $titleW = [Math]::Max(10, $Width - $fixed)

    $titleStyle = 'white'
    if ($e.kind -eq 'exam') { $titleStyle = 'bold white' }
    $dimAll = $done -or ($past -and -not $Countdown)
    $s = '  ' + (Paint 'gray' $idTxt) + '  '
    $s += Paint ("bold #$color") (Fit $code 11)
    if ($datePart) { $s += Paint 'muted' $datePart }
    $s += ' ' + (Paint $titleStyle (Fit ([string]$e.title) $titleW)) + ' '
    if ($tag) { $s += Paint "bold bg:#$color ink" (" $tag ") } else { $s += ' ' * 6 }
    $s += Paint 'muted' (Fit $timeTxt 9 -Right)
    if ($Countdown) {
        $ls = 'gray'
        if ($left -and $left -ne 'passed') {
            $h = ($due - $Now).TotalHours
            if ($h -le 12) { $ls = 'bold red' } elseif ($h -le 24) { $ls = 'orange' } else { $ls = 'yellow' }
        }
        $s += Paint $ls (Fit $left 9 -Right)
    }
    $s += '  ' + (Paint 'gray' (Fit $weight 6 -Right))
    if ($dimAll -and $script:JkUseColor) {
        $plain = $s -replace "$([char]27)\[[0-9;]*m", ''
        if ($done) { return (Paint 'gray strike' $plain) }
        return (Paint 'gray' $plain)
    }
    $s
}

function Write-JkDayHeader([datetime]$Day, [datetime]$Now, $Info) {
    $n = [int]($Day.Date - $Now.Date).TotalDays
    $rel = Format-JkRelDay $Day $Now
    $style = 'gray'
    if ($n -eq 0) { $style = 'bold red'; $rel = 'TODAY' }
    elseif ($n -eq 1) { $style = 'bold orange' }
    elseif ($n -le 3) { $style = 'yellow' }
    $label = $Day.ToString('ddd MMM d', $script:Inv)
    Say (' ' + (Paint 'bold white' $label) + '  ' + (Paint $style $rel))
}

function Show-JkDue {
    param([int]$Days = 14, [string]$Course)
    $data = Get-JkDueData
    if (@($data.events).Count -eq 0) {
        Say ''
        Say (Paint 'yellow' '  No deadlines yet.')
        Say ('  Add one:     ' + (Paint 'cyan' 'jk due add cs350 "A3 File Systems" nov 25 8pm -Weight 10%'))
        Say ('  Or import:   ' + (Paint 'cyan' 'jk due import "<path to calendar.html>"'))
        return
    }
    $cmap = Get-JkCourseMap $data
    $now = Get-JkNow
    $w = Get-JkWidth
    $horizon = $now.Date.AddDays($Days + 1)
    $evs = @($data.events | Where-Object { -not $_.done } | ForEach-Object {
            $due = Get-JkEventDue $_
            if ($due -lt $horizon -and $due.Date -ge $now.Date) { $_ }
        } | Sort-Object { Get-JkEventDue $_ }, id)
    if ($Course) {
        $c = Resolve-JkCourse $data $Course
        if (-not $c) { throw "unknown course '$Course'" }
        $evs = @($evs | Where-Object { $_.course -eq $c.key })
    }
    $info = Get-JkTermInfo $data $now
    $nExam = @($evs | Where-Object { $_.kind -eq 'exam' }).Count
    $sub = "next $Days days $($script:G.dot) $($evs.Count) item$(if ($evs.Count -ne 1) {'s'})"
    if ($nExam) { $sub += " $($script:G.dot) $nExam exam$(if ($nExam -ne 1) {'s'})" }
    Write-JkHeader 'Deadlines' (Format-JkTermLine $info) -Sub $sub
    if ($evs.Count -eq 0) {
        Say (Paint 'green' "  Nothing due in the next $Days days. $($script:G.check)")
    }
    # the "time left" column only appears when something is actually within 48 hours
    $useCountdown = @($evs | Where-Object { ((Get-JkEventDue $_) - $now).TotalHours -le 48 }).Count -gt 0
    $lastDay = $null
    foreach ($e in $evs) {
        $day = (Get-JkEventDue $e).Date
        if ($day -ne $lastDay) {
            if ($lastDay) { Say '' }
            Write-JkDayHeader $day $now $info
            $lastDay = $day
        }
        Say (Format-JkDueLine $e $cmap $w -Countdown:$useCountdown -Now $now)
    }
    $later = @($data.events | Where-Object { -not $_.done -and (Get-JkEventDue $_) -ge $horizon }).Count
    Say ''
    $hint = "jk due done <id>  $($script:G.dot)  jk due all  $($script:G.dot)  jk due add  $($script:G.dot)  jk due cal"
    if ($later) { $hint = "+$later later  $($script:G.dot)  " + $hint }
    Say (Paint 'gray' "  $hint")
}

function Show-JkDueAll {
    param([string]$Course, [switch]$PastOnly)
    $data = Get-JkDueData
    $cmap = Get-JkCourseMap $data
    $now = Get-JkNow
    $w = Get-JkWidth
    $evs = @($data.events | Sort-Object { Get-JkEventDue $_ }, id)
    $title = 'All deadlines'
    $sub = ''
    if ($Course) {
        $c = Resolve-JkCourse $data $Course
        if (-not $c) { throw "unknown course '$Course'" }
        $evs = @($evs | Where-Object { $_.course -eq $c.key })
        $title = [string]$c.code
        $sub = [string]$c.name
    }
    if ($PastOnly) { $evs = @($evs | Where-Object { (Get-JkEventDue $_) -lt $now }); $title = 'Past deadlines' }
    $open = @($evs | Where-Object { -not $_.done -and (Get-JkEventDue $_) -ge $now }).Count
    Write-JkHeader $title "$(Format-JkCount $evs.Count 'item') $($script:G.dot) $open open" -Sub $sub
    $lastMonth = ''
    foreach ($e in $evs) {
        $due = Get-JkEventDue $e
        $m = $due.ToString('MMMM yyyy', $script:Inv)
        if ($m -ne $lastMonth) {
            if ($lastMonth) { Say '' }
            Say (' ' + (Paint 'bold white' $m))
            $lastMonth = $m
        }
        Say (Format-JkDueLine $e $cmap $w -WithDate -Now $now)
    }
    if ($Course -and $c.final) { Say ''; Say ('  ' + (Paint 'bold' 'Final: ') + [string]$c.final) }
}

function Show-JkExams {
    $data = Get-JkDueData
    $cmap = Get-JkCourseMap $data
    $now = Get-JkNow
    $w = Get-JkWidth
    $evs = @($data.events | Where-Object { $_.kind -eq 'exam' -and -not $_.done -and (Get-JkEventDue $_) -ge $now.Date } | Sort-Object { Get-JkEventDue $_ })
    # an online window ("X opens" + "X closes") is one exam: one row
    $rows = New-Object System.Collections.Generic.List[object]
    $merged = @{}
    foreach ($e in $evs) {
        if ($merged.ContainsKey([string]$e.id)) { continue }
        $win = Get-JkEventWindow $e $data
        if ($win) { $merged[[string]$win.Open.id] = $true; $merged[[string]$win.Close.id] = $true }
        $rows.Add([pscustomobject]@{ E = $e; Win = $win })
    }
    Write-JkHeader 'Upcoming exams' "$($rows.Count) left this term"
    foreach ($row in $rows) {
        $e = $row.E
        $win = $row.Win
        $due = Get-JkEventDue $e
        $title = [string]$e.title
        $when = $due.ToString('ddd MMM d', $script:Inv)
        if ($e.time) { $when += ' ' + (Format-JkTime $e.time) }
        $notes = @([string]$e.note)
        if ($win) {
            $title = $win.Title
            $closeTxt = $win.Closes.ToString('ddd MMM d', $script:Inv) + ' ' + (Format-JkTime $win.Closes.ToString('HH:mm', $script:Inv))
            $notes = @([string]$win.Open.note, [string]$win.Close.note)
            if ($win.Opens -ge $now) {
                $due = $win.Opens
                $when = $due.ToString('ddd MMM d', $script:Inv) + ' ' + (Format-JkTime $due.ToString('HH:mm', $script:Inv))
                $notes = @("open until $closeTxt") + $notes
            } else {
                $due = $win.Closes
                $when = 'open now'
                $notes = @("closes $closeTxt") + $notes
            }
        }
        $days = [int]($due.Date - $now.Date).TotalDays
        $color = Get-JkCourseColor $e.course $cmap
        $countTxt = "{0,3}d" -f $days
        $style = 'gray'
        if ($days -le 3) { $style = 'bold red' } elseif ($days -le 7) { $style = 'orange' } elseif ($days -le 14) { $style = 'yellow' }
        $line = '  ' + (Paint $style $countTxt) + '  ' + (Paint "bold #$color" (Fit (Get-JkCourseLabel $e $cmap) 11)) + (Paint 'bold white' (Fit $title 22)) + ' ' + (Paint 'muted' (Fit $when 22)) + (Paint 'gray' (Fit ([string]$e.weight) 6 -Right))
        Say $line
        $note = @($notes | Where-Object { $_ }) -join " $($script:G.dot) "
        if ($note) { Say ('                     ' + (Paint 'gray' (Fit $note ($w - 22)).TrimEnd())) }
    }
}

function Show-JkCourses {
    $data = Get-JkDueData
    $now = Get-JkNow
    Write-JkHeader 'Courses' (Format-JkCount @($data.courses).Count 'course')
    foreach ($c in @($data.courses)) {
        $evs = @($data.events | Where-Object { $_.course -eq $c.key })
        $open = @($evs | Where-Object { -not $_.done -and (Get-JkEventDue $_) -ge $now }).Count
        $next = $evs | Where-Object { -not $_.done -and (Get-JkEventDue $_) -ge $now } | Sort-Object { Get-JkEventDue $_ } | Select-Object -First 1
        $nextTxt = ''
        if ($next) { $nextTxt = "next: $($next.title) ($(Format-JkRelDay (Get-JkEventDue $next) $now))" }
        Say ('  ' + (Paint 'gray' (Fit $c.key 9)) + (Paint "bold #$(([string]$c.color).TrimStart('#'))" (Fit $c.code 12)) + (Fit ([string]$c.name) 26) + (Paint 'muted' (Fit "$open open" 9)) + (Paint 'gray' $nextTxt))
    }
}

# ---------------------------------------------------------------- week grid

function Show-JkDueWeek {
    param([int]$Weeks = 2)
    $data = Get-JkDueData
    $cmap = Get-JkCourseMap $data
    $now = Get-JkNow
    $w = Get-JkWidth
    # seven columns and a leading space within the window; 7 still fits "Mon 19"
    $colW = [Math]::Max(7, [int][Math]::Floor(($w - 1) / 7))
    $monday = $now.Date.AddDays(-(([int]$now.DayOfWeek + 6) % 7))
    $info = Get-JkTermInfo $data $now
    Write-JkHeader 'Week view' (Format-JkTermLine $info)
    for ($wk = 0; $wk -lt $Weeks; $wk++) {
        $start = $monday.AddDays(7 * $wk)
        $head = ' '
        for ($i = 0; $i -lt 7; $i++) {
            $d = $start.AddDays($i)
            $txt = Fit ($d.ToString('ddd d', $script:Inv)) ($colW - 1)
            $st = 'bold muted'
            if ($d -eq $now.Date) { $st = 'bold bg:white ink' } elseif ($d -lt $now.Date) { $st = 'gray dim' }
            $head += (Paint $st $txt) + ' '
        }
        Say $head
        $cells = @()
        $max = 0
        for ($i = 0; $i -lt 7; $i++) {
            $d = $start.AddDays($i).ToString('yyyy-MM-dd', $script:Inv)
            $list = @($data.events | Where-Object { $_.date -eq $d } | Sort-Object { if ($_.kind -eq 'exam') { 0 } else { 1 } }, time)
            $cells += , $list
            if ($list.Count -gt $max) { $max = $list.Count }
        }
        if ($max -eq 0) { Say (Paint 'gray' '  (nothing)') }
        for ($r = 0; $r -lt $max; $r++) {
            $line = ' '
            for ($i = 0; $i -lt 7; $i++) {
                $list = $cells[$i]
                if ($r -lt $list.Count) {
                    $e = $list[$r]
                    $code = (Get-JkCourseLabel $e $cmap) -replace '\s', ''
                    $txt = Fit ("$code $($e.title)") ($colW - 1)
                    $color = Get-JkCourseColor $e.course $cmap
                    $st = "#$color"
                    if ($e.kind -eq 'exam') { $st = "bold bg:#$color ink" }
                    if ($e.done) { $st = 'gray strike' }
                    elseif ((Get-JkEventDue $e) -lt $now) { $st = 'gray dim' }
                    $line += (Paint $st $txt) + ' '
                } else { $line += ' ' * $colW }
            }
            Say $line
        }
        Say ''
    }
}

# ---------------------------------------------------------------- mutations

# jk due add <course> <title> <when...> [-Weight 8%] [-Note ..] [-Exam] [-End 18:20]
#   <when> examples: "nov 25 8pm", fri 11:59pm, tomorrow, 2026-12-04, +3
function Add-JkDue {
    param(
        [Parameter(Position = 0)][string]$Course,
        [Parameter(Position = 1)][string]$Title,
        [Parameter(Position = 2, ValueFromRemainingArguments = $true)][string[]]$When,
        [string]$Weight,
        [string]$Note,
        [string]$End,
        [switch]$Exam,
        [switch]$Appt
    )
    if (-not $Course -or -not $Title -or -not $When) {
        throw 'usage: jk due add <course> "<title>" <date> [time] [-Weight 8%] [-Exam] [-Note text]'
    }
    $data = Get-JkDueData
    $c = Resolve-JkCourse $data $Course -Create
    $parsed = ConvertFrom-JkWhen ($When -join ' ')
    if ($Weight -and $Weight -match '^\d+(\.\d+)?$') { $Weight += '%' }
    $kind = 'due'
    if ($Exam) { $kind = 'exam' } elseif ($Appt) { $kind = 'appt' }
    if ($End) { $End = ConvertTo-JkTime $End }
    $e = New-JkEvent -Data $data -Course $c.key -Date $parsed.Date -Time $parsed.Time -Title $Title -Weight $Weight -Note $Note -Kind $kind -End $End
    Save-JkDueData $data
    $cmap = Get-JkCourseMap $data
    Say ((Paint 'green' "  added $($script:G.check)") + '  ' + (Format-JkDueLine $e $cmap ((Get-JkWidth) - 12) -WithDate).TrimStart())
    if ((Get-JkEventDue $e) -lt (Get-JkNow)) {
        Say (Paint 'yellow' "  note: that is in the past ($($parsed.Date.ToString('ddd MMM d yyyy', $script:Inv))) - fix with: jk due edit $($e.id) -Date <date>")
    }
}

# Splits "nov 25 8pm" / "fri at 11:59 pm" / "tomorrow" into a date and optional time.
function ConvertFrom-JkWhen([string]$Text) {
    $tokens = @(($Text -replace '\s+at\s+', ' ').Trim() -split '\s+' | Where-Object { $_ })
    for ($k = $tokens.Count; $k -ge 1; $k--) {
        $dTxt = ($tokens[0..($k - 1)]) -join ' '
        $tTxt = ''
        if ($k -lt $tokens.Count) { $tTxt = ($tokens[$k..($tokens.Count - 1)]) -join ' ' }
        try { $d = ConvertTo-JkDate $dTxt } catch { continue }
        $t = ''
        if ($tTxt) { try { $t = ConvertTo-JkTime $tTxt } catch { continue } }
        return [pscustomobject]@{ Date = $d; Time = $t }
    }
    throw "can't understand when '$Text' (examples: nov 25 8pm, fri 11:59pm, tomorrow, 2026-12-04)"
}

function Set-JkDueDone {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Refs, [switch]$Undo)
    if (-not $Refs) { throw 'usage: jk due done <id|text> [...]' }
    $data = Get-JkDueData
    $cmap = Get-JkCourseMap $data
    $hits = Find-JkEvents $data $Refs -DoneOnly:$Undo
    foreach ($e in $hits) {
        if ($Undo) { $e.done = $false; Set-JkProp $e 'doneAt' $null }
        else { $e.done = $true; Set-JkProp $e 'doneAt' ((Get-JkNow).ToString('s', $script:Inv)) }
    }
    Save-JkDueData $data
    foreach ($e in $hits) {
        if ($Undo) { Say ((Paint 'yellow' '  reopened') + "  #$($e.id) $(Get-JkCourseLabel $e $cmap) $($e.title)") }
        else { Say ((Paint 'green' "  done $($script:G.check)") + "  #$($e.id) $(Get-JkCourseLabel $e $cmap) $($e.title)") }
    }
    if (-not $Undo) {
        $left = @($data.events | Where-Object { -not $_.done -and (Get-JkEventDue $_) -ge (Get-JkNow) -and (Get-JkEventDue $_) -lt (Get-JkNow).AddDays(7) }).Count
        Say (Paint 'gray' "  $left left in the next 7 days")
    }
}

function Remove-JkDue {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Refs)
    if (-not $Refs) { throw 'usage: jk due rm <id> [...]' }
    $data = Get-JkDueData
    $hits = @(Find-JkEvents $data $Refs)
    $ids = @($hits | ForEach-Object { [int]$_.id })
    $data.events = @($data.events | Where-Object { $ids -notcontains [int]$_.id })
    Save-JkDueData $data
    foreach ($e in $hits) { Say ((Paint 'red' '  removed') + "  #$($e.id) $($e.title) ($($e.date))") }
}

function Edit-JkDue {
    param(
        [Parameter(Position = 0)][string]$Ref,
        [string]$Title, [string]$Date, [string]$Time, [string]$Weight, [string]$Note,
        [string]$Course, [string]$End, [switch]$Exam, [switch]$Due, [switch]$Appt, [switch]$NoTime,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra
    )
    $left = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($Extra)) { if ($x) { $left.Add([string]$x) } }
    $Date = Join-JkLooseDate $Date $left
    # "-Time 4:30 pm" leaves "pm" over
    if ($Time -and $left.Count -and $left[0] -match '^(?i)[ap]\.?m\.?$') { $Time = "$Time $($left[0])"; $left.RemoveAt(0) }
    if ($left.Count) { throw "unexpected words: $($left -join ' ') (quote values with spaces)" }
    if (-not $Ref) { throw 'usage: jk due edit <id> [-Title ..] [-Date ..] [-Time ..] [-Weight ..] [-Note ..] [-Course ..] [-Exam|-Due|-Appt] [-NoTime]' }
    $data = Get-JkDueData
    $e = @(Find-JkEvents $data @($Ref))[0]
    if ($Title) { $e.title = $Title }
    if ($Date) { $e.date = (ConvertTo-JkDate $Date).ToString('yyyy-MM-dd', $script:Inv) }
    if ($Time) { $e.time = ConvertTo-JkTime $Time }
    if ($NoTime) { $e.time = '' }
    if ($End) { Set-JkProp $e 'end' (ConvertTo-JkTime $End) }
    if ($PSBoundParameters.ContainsKey('Weight')) { if ($Weight -match '^\d+(\.\d+)?$') { $Weight += '%' }; $e.weight = $Weight }
    if ($PSBoundParameters.ContainsKey('Note')) { $e.note = $Note }
    if ($Course) { $e.course = (Resolve-JkCourse $data $Course -Create).key }
    if ($Exam) { $e.kind = 'exam' } elseif ($Due) { $e.kind = 'due' } elseif ($Appt) { $e.kind = 'appt' }
    Save-JkDueData $data
    $cmap = Get-JkCourseMap $data
    Say ((Paint 'green' '  updated') + '  ' + (Format-JkDueLine $e $cmap ((Get-JkWidth) - 12) -WithDate).TrimStart())
}

function Set-JkCourse {
    param([Parameter(Position = 0)][string]$Key, [string]$Code, [string]$Name, [string]$Color, [string]$Final)
    if (-not $Key) { throw 'usage: jk due course <key> [-Code "CS 350"] [-Name ..] [-Color #F87171] [-Final ..]' }
    $data = Get-JkDueData
    $c = Resolve-JkCourse $data $Key -Create
    if ($Code) { $c.code = $Code }
    if ($Name) { $c.name = $Name }
    if ($Color) { $c.color = $Color.TrimStart('#') }
    if ($PSBoundParameters.ContainsKey('Final')) { $c.final = $Final }
    Save-JkDueData $data
    Show-JkCourses
}

# ---------------------------------------------------------------- import from an HTML calendar

# Pulls the time of day out of free text such as "8:00 pm", "4:30 - 6:20 pm",
# "in class 8:30 - 9:50 am" or "open Sep 18 8am - Sep 25 11pm" (closing time).
function Get-JkTimeFromText {
    param([string]$Text, [string]$Title = '')
    $res = [pscustomobject]@{ Time = ''; End = '' }
    if (-not $Text) { $Text = '' }
    $all = "$Title $Text"
    $range = [regex]::Match($Text, '(?i)(\d{1,2}):(\d{2})\s*(am|pm)?\s*\p{Pd}\s*(\d{1,2}):(\d{2})\s*(am|pm)')
    $times = [regex]::Matches($all, '(?i)\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b')
    $conv = { param($h, $m, $ap) ConvertTo-JkTime ("{0}:{1} {2}" -f $h, $(if ($m) { $m } else { '00' }), $ap) }
    if ($Title -match '(?i)\bclos') {
        if ($times.Count -gt 0) { $t = $times[$times.Count - 1]; $res.Time = & $conv $t.Groups[1].Value $t.Groups[2].Value $t.Groups[3].Value }
        return $res
    }
    if ($range.Success) {
        $ap2 = $range.Groups[6].Value
        $ap1 = $range.Groups[3].Value
        if (-not $ap1) {
            $ap1 = $ap2
            # "11:30 - 1:20 pm" -> the start is in the morning
            if ($ap2 -eq 'pm' -and [int]$range.Groups[1].Value -gt [int]$range.Groups[4].Value -and [int]$range.Groups[1].Value -ne 12) { $ap1 = 'am' }
        }
        $res.Time = & $conv $range.Groups[1].Value $range.Groups[2].Value $ap1
        $res.End = & $conv $range.Groups[4].Value $range.Groups[5].Value $ap2
        return $res
    }
    if ($times.Count -gt 0) {
        $t = $times[0]
        $res.Time = & $conv $t.Groups[1].Value $t.Groups[2].Value $t.Groups[3].Value
    }
    $res
}

function Import-JkDueHtml {
    param([Parameter(Position = 0)][string]$Path, [switch]$Replace)
    if (-not $Path) { throw 'usage: jk due import <calendar.html> [-Replace]' }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $html = [IO.File]::ReadAllText($full)

    $colors = @{}
    foreach ($m in [regex]::Matches($html, '--([a-z0-9]+):\s*#([0-9A-Fa-f]{6})')) { $colors[$m.Groups[1].Value] = $m.Groups[2].Value.ToUpper() }

    $courses = @()
    $courseRx = '(?<key>\w+)\s*:\s*\{\s*code\s*:\s*"(?<code>[^"]*)"\s*,\s*name\s*:\s*"(?<name>[^"]*)"(?:\s*,\s*cls\s*:\s*"(?<cls>[^"]*)")?(?:\s*,\s*final\s*:\s*(?:"(?<final>[^"]*)"|null))?'
    $i = 0
    foreach ($m in [regex]::Matches($html, $courseRx)) {
        $key = $m.Groups['key'].Value
        $cls = $m.Groups['cls'].Value; if (-not $cls) { $cls = $key }
        $color = $colors[$cls]; if (-not $color) { $color = $script:CourseColors[$i % $script:CourseColors.Count] }
        $courses += [pscustomobject]@{ key = $key; code = $m.Groups['code'].Value; name = $m.Groups['name'].Value; color = $color; final = $m.Groups['final'].Value }
        $i++
    }

    $events = @()
    foreach ($m in [regex]::Matches($html, '\{\s*c\s*:\s*"[^"]+"[^{}]*\}')) {
        $o = $m.Value
        $get = {
            param($k)
            $mm = [regex]::Match($o, '\b' + $k + '\s*:\s*"((?:[^"\\]|\\.)*)"')
            if ($mm.Success) { $mm.Groups[1].Value } else { '' }
        }
        $kind = 'due'
        if ($o -match '\bexam\s*:\s*true') { $kind = 'exam' } elseif ($o -match '\bappt\s*:\s*true') { $kind = 'appt' }
        $t = & $get 't'
        $n = & $get 'n'
        $tm = Get-JkTimeFromText $t $n
        $events += [pscustomobject]@{ course = (& $get 'c'); date = (& $get 'd'); title = $n; note = $t; weight = (& $get 'w'); kind = $kind; time = $tm.Time; end = $tm.End }
    }
    if ($events.Count -eq 0) { throw "no events found in $full (expected objects like {c:`"cs350`",d:`"2026-10-28`",n:`"A2A`"})" }

    $marks = @{}
    $mb = [regex]::Match($html, 'MARKS\s*=\s*\{([^}]*)\}')
    if ($mb.Success) { foreach ($m in [regex]::Matches($mb.Groups[1].Value, '"(\d{4}-\d{2}-\d{2})"\s*:\s*"([^"]*)"')) { $marks[$m.Groups[1].Value] = $m.Groups[2].Value } }
    $breaks = @()
    $bb = [regex]::Match($html, 'BREAK\s*=\s*\[\s*"(\d{4}-\d{2}-\d{2})"\s*,\s*"(\d{4}-\d{2}-\d{2})"\s*\]')
    if ($bb.Success) {
        $bname = 'Reading week'
        $breaks += [pscustomobject]@{ from = $bb.Groups[1].Value; to = $bb.Groups[2].Value; name = $bname }
    }
    $findMark = { param($rx) foreach ($k in $marks.Keys) { if ($marks[$k] -match $rx) { return $k } } $null }
    $termName = ''
    $tm2 = [regex]::Match($html, '(Fall|Winter|Spring|Summer)\s+(\d{4})')
    if ($tm2.Success) { $termName = $tm2.Value }
    $term = $null
    $start = & $findMark '(?i)classes start|first day'
    if ($start) {
        $term = [pscustomobject]@{
            name       = $termName
            start      = $start
            classesEnd = (& $findMark '(?i)last day|classes end')
            examsStart = (& $findMark '(?i)exams start')
            examsEnd   = (& $findMark '(?i)exams end')
            breaks     = @($breaks)
            marks      = @($marks.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ date = $_; name = $marks[$_] } })
        }
    }

    $data = Get-JkDueData
    if ($Replace) { $data.events = @(); $data.courses = @(); $data.nextId = 1 }
    if ($term -and ($Replace -or -not (Get-JkProp $data 'term'))) { Set-JkProp $data 'term' $term }
    foreach ($c in $courses) {
        $existing = Resolve-JkCourse $data $c.key
        if (-not $existing) { $data.courses = @($data.courses) + $c }
    }
    $added = 0; $skipped = 0
    foreach ($ev in ($events | Sort-Object date)) {
        $dup = @($data.events | Where-Object { $_.course -eq $ev.course -and $_.date -eq $ev.date -and $_.title -eq $ev.title })
        if ($dup.Count) { $skipped++; continue }
        $d = [datetime]::ParseExact($ev.date, 'yyyy-MM-dd', $script:Inv)
        $null = New-JkEvent -Data $data -Course $ev.course -Date $d -Time $ev.time -Title $ev.title -Weight $ev.weight -Note $ev.note -Kind $ev.kind -End $ev.end
        $added++
    }
    Save-JkDueData $data
    Say ((Paint 'green' "  imported $($script:G.check)") + "  $(Format-JkCount $added 'event'), $(Format-JkCount $courses.Count 'course')" + $(if ($skipped) { " ($skipped already present)" } else { '' }) + $(if ($term) { " $($script:G.dot) term: $($term.name)" } else { '' }))
}

# ---------------------------------------------------------------- HTML calendar & ICS

function Export-JkDueHtml {
    param([string]$Out, [switch]$NoOpen, [switch]$Quiet)
    $data = Get-JkDueData
    if (-not $Out) { $Out = Get-JkPath 'calendar.html' }
    $tpl = [IO.File]::ReadAllText((Join-Path (Get-JkRoot) 'templates\calendar.html'))
    $classes = @()
    try { $classes = @((Get-JkClassData).items) } catch { }
    $payload = [pscustomobject]@{
        generated = (Get-JkNow).ToString('s', $script:Inv)
        term      = (Get-JkProp $data 'term')
        courses   = @($data.courses)
        events    = @($data.events)
        classes   = $classes
    }
    $json = (ConvertTo-Json -InputObject $payload -Depth 8 -Compress).Replace('</', '<\/')
    $html = $tpl.Replace('/*JK_DATA*/null', $json)
    Write-JkText $Out $html
    if (-not $Quiet) { Say ((Paint 'green' "  calendar written $($script:G.check)") + "  $Out") }
    if (-not $NoOpen) { Start-Process $Out }
}

function ConvertTo-JkIcsText([string]$s) {
    if ($null -eq $s) { return '' }
    $s.Replace('\', '\\').Replace(';', '\;').Replace(',', '\,').Replace("`r", '').Replace("`n", '\n')
}

# Folds a content line at 75 octets as RFC 5545 requires (UTF-8 aware).
function Format-JkIcsLine([string]$Line) {
    $enc = [Text.Encoding]::UTF8
    if ($enc.GetByteCount($Line) -le 75) { return $Line }
    $sb = New-Object Text.StringBuilder
    $cur = ''
    $limit = 75
    foreach ($ch in $Line.ToCharArray()) {
        if ($enc.GetByteCount($cur + $ch) -gt $limit) {
            [void]$sb.Append($cur).Append("`r`n ")
            $cur = ''
            $limit = 74
        }
        $cur += $ch
    }
    [void]$sb.Append($cur)
    $sb.ToString()
}

function Export-JkDueIcs {
    param([string]$Out, [switch]$Open, [switch]$IncludeDone, [switch]$NoClasses)
    $data = Get-JkDueData
    $cmap = Get-JkCourseMap $data
    if (-not $Out) { $Out = Get-JkPath 'deadlines.ics' }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ', $script:Inv)
    $termName = [string](Get-JkProp (Get-JkProp $data 'term') 'name' 'Deadlines')
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('BEGIN:VCALENDAR'); $L.Add('VERSION:2.0'); $L.Add('PRODID:-//jk//deadlines//EN'); $L.Add('CALSCALE:GREGORIAN')
    $L.Add('METHOD:PUBLISH'); $L.Add('X-WR-CALNAME:' + (ConvertTo-JkIcsText "$termName deadlines"))
    $count = 0
    foreach ($e in @($data.events)) {
        if ($e.done -and -not $IncludeDone) { continue }
        $code = Get-JkCourseLabel $e $cmap
        # "Due:", "Exam:" or "Appt:" says what it is at a glance in a calendar app (sync strips it again)
        $prefix = 'Due'
        if ($e.kind -eq 'exam') { $prefix = 'Exam' } elseif ($e.kind -eq 'appt') { $prefix = 'Appt' }
        $summary = "${prefix}: $code $($e.title)"
        if ($e.weight -and $e.weight -ne '0%') { $summary += " ($($e.weight))" }
        $L.Add('BEGIN:VEVENT')
        $L.Add("UID:jk-$($e.id)-$($e.course)@jk.local")
        $L.Add("DTSTAMP:$stamp")
        $d = [datetime]::ParseExact([string]$e.date, 'yyyy-MM-dd', $script:Inv)
        if ($e.time) {
            $st = Get-JkEventDue $e
            if ($e.kind -eq 'due') { $en = $st; $st = $st.AddMinutes(-30) }
            elseif ($e.end) { $p = ([string]$e.end).Split(':'); $en = $d.AddHours([int]$p[0]).AddMinutes([int]$p[1]) }
            else { $en = $st.AddHours(1) }
            $L.Add('DTSTART:' + $st.ToString('yyyyMMddTHHmmss', $script:Inv))
            $L.Add('DTEND:' + $en.ToString('yyyyMMddTHHmmss', $script:Inv))
        } else {
            $L.Add('DTSTART;VALUE=DATE:' + $d.ToString('yyyyMMdd', $script:Inv))
            $L.Add('DTEND;VALUE=DATE:' + $d.AddDays(1).ToString('yyyyMMdd', $script:Inv))
        }
        $L.Add('SUMMARY:' + (ConvertTo-JkIcsText $summary))
        $desc = @()
        if ($e.note) { $desc += [string]$e.note }
        if ($e.weight) { $desc += "Weight: $($e.weight)" }
        $desc += "jk id #$($e.id)"
        $L.Add('DESCRIPTION:' + (ConvertTo-JkIcsText ($desc -join "`n")))
        $L.Add('CATEGORIES:' + (ConvertTo-JkIcsText $code))
        foreach ($trig in @('-P1D', '-PT3H')) {
            $L.Add('BEGIN:VALARM'); $L.Add('ACTION:DISPLAY'); $L.Add('DESCRIPTION:' + (ConvertTo-JkIcsText $summary)); $L.Add("TRIGGER:$trig"); $L.Add('END:VALARM')
        }
        $L.Add('END:VEVENT')
        $count++
    }
    # weekly classes as recurring events; reading week and holidays become EXDATEs
    $nClasses = 0
    if (-not $NoClasses) {
        $byDay = @{ Mon = 'MO'; Tue = 'TU'; Wed = 'WE'; Thu = 'TH'; Fri = 'FR'; Sat = 'SA'; Sun = 'SU' }
        $skip = Get-JkTermSkipDays
        foreach ($c in @((Get-JkClassData).items)) {
            $r = Get-JkClassRange $c
            if ($r[0] -eq [datetime]::MinValue -or $r[1] -eq [datetime]::MaxValue) { continue }
            $first = $r[0]
            while ($first -le $r[1] -and @($c.days) -notcontains $script:DayNames[[int]$first.DayOfWeek]) { $first = $first.AddDays(1) }
            if ($first -gt $r[1]) { continue }
            $s = ([string]$c.start).Split(':'); $e = ([string]$c.end).Split(':')
            $st = $first.AddHours([int]$s[0]).AddMinutes([int]$s[1])
            $en = $first.AddHours([int]$e[0]).AddMinutes([int]$e[1])
            $ex = @()
            $d = $first
            while ($d -le $r[1]) {
                if ($skip.ContainsKey($d.ToString('yyyy-MM-dd')) -and @($c.days) -contains $script:DayNames[[int]$d.DayOfWeek]) {
                    $ex += $d.AddHours([int]$s[0]).AddMinutes([int]$s[1]).ToString('yyyyMMddTHHmmss', $script:Inv)
                }
                $d = $d.AddDays(1)
            }
            $label = Format-JkClassLabel $c $cmap
            $L.Add('BEGIN:VEVENT')
            $L.Add("UID:jk-class-$($c.id)-$($c.course)@jk.local")
            $L.Add("DTSTAMP:$stamp")
            $L.Add('DTSTART:' + $st.ToString('yyyyMMddTHHmmss', $script:Inv))
            $L.Add('DTEND:' + $en.ToString('yyyyMMddTHHmmss', $script:Inv))
            $L.Add('RRULE:FREQ=WEEKLY;BYDAY=' + ((@($c.days) | ForEach-Object { $byDay[$_] }) -join ',') + ';UNTIL=' + $r[1].ToString('yyyyMMdd', $script:Inv) + 'T235959')
            if ($ex.Count) { $L.Add('EXDATE:' + ($ex -join ',')) }
            $L.Add('SUMMARY:' + (ConvertTo-JkIcsText $label))
            if ($c.room) { $L.Add('LOCATION:' + (ConvertTo-JkIcsText ([string]$c.room))) }
            $L.Add('CATEGORIES:' + (ConvertTo-JkIcsText (Get-JkCourseLabel ([pscustomobject]@{ course = $c.course }) $cmap)))
            $L.Add('END:VEVENT')
            $nClasses++
        }
    }
    $L.Add('END:VCALENDAR')
    $text = (($L | ForEach-Object { Format-JkIcsLine $_ }) -join "`r`n") + "`r`n"
    Write-JkText $Out $text
    $classTxt = ''
    if ($nClasses) { $classTxt = " + $nClasses weekly classes" }
    Say ((Paint 'green' "  exported $($script:G.check)") + "  $count events$classTxt $($script:G.arrow) $Out")
    Say (Paint 'gray' '  Import into Google Calendar (Settings > Import) or Outlook to get phone reminders 1 day and 3 hours before.')
    if ($Open) { Start-Process $Out }
}

# ---------------------------------------------------------------- reminders

function Get-JkDueSoon {
    param([double]$Hours = 48)
    $data = Get-JkDueData
    $now = Get-JkNow
    @($data.events | Where-Object { -not $_.done } | Where-Object {
            $due = Get-JkEventDue $_
            $due -ge $now -and $due -le $now.AddHours($Hours)
        } | Sort-Object { Get-JkEventDue $_ })
}

# Shows a popup/toast for anything due in the next N hours. -Quiet suppresses console
# output (scheduled runs); repeated runs within 3 hours are skipped unless -Force.
# An exam's note without the times the popup already shows: "4:30 - 6:20 pm <dot> in person, room
# TBA" keeps "in person, room TBA", and a window's "6:00 am Oct 26 -> 11:59 pm Oct 27" goes too.
function Get-JkExamNote($Item) {
    $note = [string]$Item.note
    if (-not $note) { return '' }
    $sep = [regex]::Escape($script:G.dot)
    $keep = foreach ($seg in ($note -split "\s*$sep\s*")) {
        $s = $seg.Trim()
        if (-not $s) { continue }
        if ($s -match '(?i)\d(:\d{2})?\s*(am|pm)\b') {
            $rest = $s -replace '(?i)\d{1,2}(:\d{2})?\s*(am|pm)?', '' -replace '(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b', '' -replace "[\s\-$($script:G.dash)$($script:G.arrow)]", ''
            if (-not $rest) { continue }
        }
        $s
    }
    @($keep) -join " $($script:G.dot) "
}

# The morning popup's title on an exam day: "Exam today: CS 350 Midterm 4:30 pm", or for an online
# window that closes today "Exam today: HEALTH 105 Midterm 1, by 11:59 pm". $null on other days.
function Get-JkExamDayTitle($Soon, $Cmap, [datetime]$Now) {
    $today = @($Soon | Where-Object { $_.kind -eq 'exam' -and (Get-JkEventDue $_).Date -eq $Now.Date })
    if (-not $today.Count) { return $null }
    $names = @(foreach ($e in $today) {
        $t = ([string]$e.title -replace '(?i)\s+(opens?|closes?)$', '').Trim()
        $at = ''
        if ($e.time) { $at = ' ' + (Format-JkTime $e.time); if ([string]$e.title -match '(?i)\s+closes?$') { $at = ", by$at" } }
        "$(Get-JkCourseLabel $e $Cmap) $t$at"
    })
    if ($today.Count -eq 1) { return "Exam today: $($names[0])" }
    "$($today.Count) exams today: " + (@($today | ForEach-Object { "$(Get-JkCourseLabel $_ $Cmap) $(([string]$_.title -replace '(?i)\s+(opens?|closes?)$', '').Trim())" }) -join ', ')
}

function Invoke-JkDueRemind {
    param([double]$Hours = 0, [switch]$Quiet, [switch]$Force)
    if (-not $Hours) { $Hours = [double](Get-JkConfig 'remind.hours') }
    $state = Read-JkJson 'state.json' $null
    if (-not $state) { $state = [pscustomobject]@{} }
    $now = Get-JkNow
    $last = Get-JkProp $state 'lastRemind'
    if (-not $Force -and $last) {
        $lastDt = [datetime]::Parse([string]$last, $script:Inv)
        # a stamp from the future (clock change, pinned test clock) must not silence the brief
        if ($lastDt -le $now -and ($now - $lastDt).TotalHours -lt 3) { if (-not $Quiet) { Say (Paint 'gray' '  reminded less than 3h ago; use -Force') }; return }
    }
    $soon = @(Get-JkDueSoon -Hours $Hours)
    # the rest of today's classes ride along, so the morning popup doubles as a day brief
    $classes = @()
    try { $classes = @(Get-JkClassesOn $now.Date | Where-Object { $_.Start -gt $now }) } catch { }
    if ($soon.Count -eq 0 -and $classes.Count -eq 0) { if (-not $Quiet) { Say (Paint 'green' "  nothing due in the next $Hours hours and no more classes today") }; return }
    $data = Get-JkDueData
    $cmap = Get-JkCourseMap $data
    $lines = @()
    if ($classes.Count) {
        $lines += 'Classes today: ' + (($classes | ForEach-Object { "$(Format-JkTime $_.Start.ToString('HH:mm')) $(Format-JkClassLabel $_.Class $cmap)$(if ($_.Class.room) { " ($($_.Class.room))" })" }) -join ', ')
    }
    foreach ($e in ($soon | Select-Object -First 6)) {
        $due = Get-JkEventDue $e
        $when = Format-JkRelDay $due $now
        if ($when -like 'in *') { $when = $due.ToString('ddd', $script:Inv) }
        $when = $when.Substring(0, 1).ToUpper() + $when.Substring(1)
        if ($e.time) {
            # an exam runs from its time to its end: "4:30-6:20 pm"
            $span = Format-JkTime $e.time
            if ($e.end) { $p = ([string]$e.end).Split(':'); $span = Format-JkTimeSpan $due ($due.Date.AddHours([int]$p[0]).AddMinutes([int]$p[1])) }
            $when += ' ' + $span
        }
        $txt = "$when $($script:G.dash) $(Get-JkCourseLabel $e $cmap) $($e.title)"
        if ($e.kind -eq 'exam') {
            $txt += ' (exam)'
            # where and what to bring: "in person, room TBA", "one handwritten sheet, no calculator"
            $note = Get-JkExamNote $e
            if ($note) { $txt += " $($script:G.dot) $note" }
        }
        # an opening is not a deadline: say until when the window runs
        if ([string]$e.title -match '(?i)\s+opens?$') {
            $win = Get-JkEventWindow $e $data
            if ($win) { $txt += ", open until $($win.Closes.ToString('ddd', $script:Inv)) $(Format-JkTime $win.Closes.ToString('HH:mm', $script:Inv))" }
        }
        $lines += $txt
    }
    if ($soon.Count -gt 6) { $lines += "+$($soon.Count - 6) more" }
    # today's study blocks ride along (they never trigger a popup on their own)
    try {
        $plan = Get-JkPlanToday
        if ($plan -and $plan.Today.Alloc.Count) {
            $byCourse = @{}
            foreach ($it in $plan.Items) { if ($plan.Today.Alloc.ContainsKey($it.Key)) { $byCourse[$it.Course] = [double]$byCourse[$it.Course] + $plan.Today.Alloc[$it.Key] } }
            $lines += 'Study today: ' + (($byCourse.Keys | Sort-Object { $byCourse[$_] } -Descending | ForEach-Object { "$(Get-JkCourseLabel ([pscustomobject]@{ course = $_ }) $cmap) $(Format-JkMinutes $byCourse[$_])" }) -join ', ')
        }
    } catch { }
    if ($soon.Count) {
        $accent = Get-JkCourseColor $soon[0].course $cmap
        $title = "$($soon.Count) deadline$(if ($soon.Count -ne 1) {'s'}) in the next $([int]$Hours)h"
        # an exam today leads, in its course's colour
        $examTitle = Get-JkExamDayTitle $soon $cmap $now
        if ($examTitle) {
            $title = $examTitle
            $first = @($soon | Where-Object { $_.kind -eq 'exam' -and (Get-JkEventDue $_).Date -eq $now.Date })[0]
            $accent = Get-JkCourseColor $first.course $cmap
        }
    } else {
        $accent = Get-JkCourseColor $classes[0].Class.course $cmap
        $title = "$($classes.Count) class$(if ($classes.Count -ne 1) {'es'}) today, nothing due soon"
    }
    $cal = Get-JkPath 'calendar.html'
    if (-not (Test-Path $cal)) { Export-JkDueHtml -NoOpen -Quiet }
    $mode = Show-JkNotify -Title $title -Lines $lines -Accent $accent -Open $cal -OpenLabel 'Open calendar' -Seconds 20 -Sound -Wait:$Quiet
    Set-JkState 'lastRemind' ($now.ToString('s', $script:Inv))
    if (-not $Quiet) { Say ((Paint 'green' "  reminder shown ($mode)") + "  $title") }
}

# ---------------------------------------------------------------- router

function Invoke-JkDue {
    $a = @($args)
    if ($a.Count -eq 0) { Show-JkDue; return }
    $first = [string]$a[0]
    $rest = @()
    if ($a.Count -gt 1) { $rest = @($a[1..($a.Count - 1)]) }
    switch -Regex ($first.ToLower()) {
        '^(add|new|\+)$' { Add-JkDue @rest; return }
        '^(done|finish|x|check)$' { Set-JkDueDone @rest; return }
        '^(undone|undo|reopen)$' { Set-JkDueDone -Undo @rest; return }
        '^(rm|remove|del|delete)$' { Remove-JkDue @rest; return }
        '^(edit|set|mv|move)$' { Edit-JkDue @rest; return }
        '^(all|term|list|ls)$' { Show-JkDueAll @rest; return }
        '^(past|history)$' { Show-JkDueAll -PastOnly; return }
        '^(exams?|tests?|midterms?)$' { Show-JkExams; return }
        '^(week|wk|grid)$' { Show-JkDueWeek @rest; return }
        '^(cal|calendar|html|open)$' { Export-JkDueHtml @rest; return }
        '^(ics|ical|export)$' { Export-JkDueIcs @rest; return }
        '^(import)$' { Import-JkDueHtml @rest; return }
        '^(sync|pull|feed)$' { Invoke-JkDueSync @rest; return }
        '^(remind|notify|ping)$' { Invoke-JkDueRemind @rest; return }
        '^(courses)$' { Show-JkCourses; return }
        '^(course)$' { Set-JkCourse @rest; return }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'due'; return }
        '^\d+$' { Show-JkDue -Days ([int]$first); return }
        '^-' { Show-JkDue @a; return }
    }
    $data = Get-JkDueData
    $c = Resolve-JkCourse $data $first
    if ($c) { Show-JkDueAll -Course $c.key; return }
    throw "unknown 'due' action '$first' (try: jk due help)"
}
