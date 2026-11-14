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
    # a record no screen can read (a hand edit, a bad sync: date "2026-13-01", time "soon") used to
    # crash the dashboard, jk due, the morning popup and the terminal line alike. It is set aside
    # here, written back as it was on save (Save-JkDueData), and named by jk doctor.
    Split-JkUnreadable $d 'events' { param($e) Repair-JkEvent $e }
    if (-not (Get-JkProp $d 'nextId')) {
        $max = 0; foreach ($e in @($d.events)) { if ([int]$e.id -gt $max) { $max = [int]$e.id } }
        Set-JkProp $d 'nextId' ($max + 1)
    }
    $d
}

function Save-JkDueData($Data) {
    $Data.courses = @($Data.courses)
    # the records set aside as unreadable go back into the file unchanged, never lost
    $Data.events = @($Data.events | Sort-Object date, time, id)
    Save-JkWithUnreadable $Data 'events' { Save-JkJson 'deadlines.json' $Data }
    $script:JkDueCache = $null
    Clear-JkBriefCache
    # keep an already-generated calendar page current (the reminder popup links to it)
    if (Test-Path -LiteralPath (Get-JkPath 'calendar.html')) { try { Export-JkDueHtml -NoOpen -Quiet } catch { } }
}

# Whether every screen can read an event: a real yyyy-MM-dd date, a numeric id, and a time and end
# that are HH:mm. A time written another way that jk reads anyway ("7pm") is put as "19:00".
function Repair-JkEvent($e) {
    if (-not (Test-JkDateText ([string]$e.date))) { return $false }
    if ([string]$e.id -notmatch '^\d+$') { return $false }
    foreach ($k in 'time', 'end') {
        $v = [string](Get-JkProp $e $k '')
        if (-not $v) { continue }
        $fixed = Get-JkReadableTime $v
        if (-not $fixed) { return $false }
        if ($fixed -ne $v) { $e.$k = $fixed }
    }
    $true
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

# "cs341 midterm 2" / "cs 341 a1": a course named first (one word, or two when the second is the
# number) and the words after it. Returns the course ($null when none) and the words left.
function Split-JkCourseWords($Data, [string[]]$Words) {
    $w = @($Words | Where-Object { $_ })
    foreach ($n in 2, 1) {
        if ($w.Count -le $n) { continue }
        if ($n -eq 2 -and $w[1] -notmatch '^\d') { continue }
        $c = Resolve-JkCourse $Data (($w[0..($n - 1)]) -join ' ')
        if ($c) { return , @($c, @($w | Select-Object -Skip $n)) }
    }
    , @($null, $w)
}

# Title words as patterns: "a1" also stands for "Assignment 1" and "q2" for "Quiz 2", and a word
# ending in a digit never matches a longer number ("a1" is not "A10").
function Get-JkTitleWordRx([string[]]$Tokens) {
    foreach ($tok in @($Tokens | Where-Object { $_ })) {
        $t = [regex]::Escape($tok.ToLower())
        if ($tok -match '^([a-zA-Z]+)(\d+)$') { "(?:$t(?!\d)|\b$([regex]::Escape($Matches[1].ToLower()))[a-z]*\s*$($Matches[2])(?!\d))" }
        elseif ($tok -match '\d$') { "$t(?!\d)" }
        else { $t }
    }
}

function Test-JkTitleWords([string]$Title, $Rx) {
    $t = $Title.ToLower()
    -not @($Rx | Where-Object { $t -notmatch $_ }).Count
}

function Find-JkEvents {
    param($Data, [string[]]$Refs, [switch]$DoneOnly, [switch]$Any)
    $out = @()
    $state = { param($e) $Any -or [bool]$e.done -eq [bool]$DoneOnly }
    $what = $(if ($Any) { '' } elseif ($DoneOnly) { 'finished ' } else { 'open ' })
    # several words that are not all ids name one item: "cs341 midterm 2", "quiz 3"
    $phrase = @($Refs | Where-Object { $_ }).Count -gt 1 -and @($Refs | Where-Object { $_ -notmatch '^#?\d+$' }).Count
    if ($phrase) {
        $sp = Split-JkCourseWords $Data $Refs
        $rx = @(Get-JkTitleWordRx @($sp[1]))
        $hits = @($Data.events | Where-Object { (& $state $_) -and (-not $sp[0] -or $_.course -eq $sp[0].key) -and $rx.Count -and (Test-JkTitleWords ([string]$_.title) $rx) })
        $hits = @(Select-JkOneEvent $hits ($sp[1] -join ' ') ($Refs -join ' '))
        if ($hits.Count -eq 1) { return $hits }
    }
    foreach ($r in $Refs) {
        if ($r -match '^#?(\d+)$') {
            $id = [int]$Matches[1]
            $e = @($Data.events | Where-Object { [int]$_.id -eq $id })
            if (-not $e) { throw "no deadline with id #$id (see 'jk due all')" }
            $out += $e
        } else {
            # text matches look at open items, or at finished ones when reopening
            $hits = @($Data.events | Where-Object { (& $state $_) -and ([string]$_.title).ToLower().Contains($r.ToLower()) })
            if ($hits.Count -eq 0) {
                if ($phrase) { throw "no $($what)deadline matches '$($Refs -join ' ')'" }
                throw "no $($what)deadline matches '$r'"
            }
            $out += @(Select-JkOneEvent $hits $r $r)
        }
    }
    $out
}

# Several deadlines match: the one titled exactly that ("A3" over "A3 File Systems"), else the
# single upcoming one over those already past; otherwise the choice is the user's.
function Select-JkOneEvent($Hits, [string]$Exact, [string]$Label) {
    $h = @($Hits)
    if ($h.Count -le 1) { return $h }
    $same = @($h | Where-Object { ([string]$_.title).Trim() -eq $Exact.Trim() })
    if ($same.Count -eq 1) { return $same }
    $now = Get-JkNow
    $future = @($h | Where-Object { (Get-JkEventDue $_) -ge $now })
    if ($future.Count -eq 1) { return $future }
    $map = Get-JkCourseMap (Get-JkDueData -Cached)
    throw ("'$Label' matches several deadlines: " + (($h | ForEach-Object { "#$($_.id) $(Get-JkCourseLabel $_ $map) $($_.title)" }) -join ', '))
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
        # the last days of December are still "Fall" by the month, but Fall is the term that just ended
        $season = Get-JkSeasonName $today
        if ($season -eq [string]$t.name) { $season = Get-JkSeasonName $today.AddMonths(1) }
        return [pscustomobject]@{ Name = $season; Start = $null; ClassesEnd = $null; ExamsStart = $null; ExamsEnd = $null; Week = $null; TotalWeeks = $null; Phase = 'next'; InBreak = $false; BreakName = ''; DaysToEnd = $null; DaysToExams = $null; Previous = [string]$t.name }
    }
    $inBreak = $breakMondays -contains (& $monday $today)
    $breakName = ''
    foreach ($b in @(Get-JkProp $t 'breaks' @())) {
        if ($today -ge (& $p $b.from) -and $today -le (& $p $b.to)) { $inBreak = $true; $breakName = [string](Get-JkProp $b 'name' 'Break') }
    }
    $total = $null
    if ($end) { $total = & $weekOf $end }
    # in the exam period: how many of your own exams are still ahead (an online window counts once)
    $examsLeft = $null
    if ($phase -eq 'exams') {
        $left = @{}
        foreach ($e in @($Data.events)) {
            if ($e.kind -ne 'exam' -or $e.done -or (Get-JkEventDue $e) -lt $Now) { continue }
            $left["$($e.course)|$(([string]$e.title -replace '(?i)\s+(opens?|closes?)$', '').Trim())"] = $true
        }
        $examsLeft = $left.Count
    }
    [pscustomobject]@{
        ExamsLeft   = $examsLeft
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
    # "classes end today", not "in 0d"; "exams tomorrow", not "in 1d"
    $inDays = { param([int]$n) if ($n -le 0) { 'today' } elseif ($n -eq 1) { 'tomorrow' } else { "in ${n}d" } }
    switch ($Info.Phase) {
        'before' { $parts += ('starts ' + $Info.Start.ToString('MMM d', $script:Inv)) }
        'classes' {
            if ($Info.InBreak) { $parts += $(if ($Info.BreakName) { $Info.BreakName } else { 'Break' }) }
            elseif ($Info.TotalWeeks) { $parts += "Week $($Info.Week) of $($Info.TotalWeeks)" }
            else { $parts += "Week $($Info.Week)" }
            if ($null -ne $Info.DaysToEnd) { $parts += "classes end $(& $inDays $Info.DaysToEnd)" }
            if ($null -ne $Info.DaysToExams) { $parts += "exams $(& $inDays $Info.DaysToExams)" }
        }
        'study' { $parts += "study break $($script:G.dot) exams $(& $inDays $Info.DaysToExams)" }
        'exams' {
            $parts += 'exam period'
            if ($Info.ExamsLeft -eq 0 -and $null -ne $Info.ExamsLeft) { $parts += "your exams are done $($script:G.check)" }
            elseif ($Info.ExamsLeft) { $parts += "$(Format-JkCount $Info.ExamsLeft 'exam') left" }
        }
        'after' { $parts += 'term over' }
        'next' { }
    }
    $parts -join " $($script:G.dot) "
}

# ---------------------------------------------------------------- rendering

# What a row whose time has come says in place of a countdown: an exam (or interview) being
# written is "now" and one finished is "over" ("passed" next to an exam reads as a pass), a quiz
# window that has opened is "open" until it closes, and a deadline gone by is "passed".
function Get-JkStartedLabel($e, $Data, [datetime]$Now) {
    $t = [string]$e.title
    if ($t -match '(?i)\s+opens?$') {
        $win = $null
        if ($Data) { $win = Get-JkEventWindow $e $Data }
        if (-not $win) { return 'opened' }
        if ($win.Closes -gt $Now) { return 'open' }
        return 'closed'
    }
    if ($t -match '(?i)\s+closes?$') { return 'closed' }
    if ($e.kind -in 'exam', 'appt') {
        if ((Get-JkExamEnd $e) -gt $Now) { return 'now' }
        return 'over'
    }
    'passed'
}

function Format-JkDueLine {
    param($e, $cmap, [int]$Width, [switch]$WithDate, [switch]$Countdown, [datetime]$Now = (Get-JkNow), $Data = $null)
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
    $span = Get-JkTimeLeft $due $Now
    if ($Countdown -and -not $done -and -not $past -and $span.TotalHours -le 48) { $left = Format-JkDuration $span }
    if ($Countdown -and -not $done -and $past) { $left = Get-JkStartedLabel $e $Data $Now }
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
        if ($left -eq 'now') { $ls = 'bold red' }
        elseif ($left -eq 'open') { $ls = 'green' }
        elseif ($left -and -not $past) {
            $h = $span.TotalHours
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
        Say ('  From LEARN:  ' + (Paint 'cyan' 'jk due sync') + (Paint 'gray' '   (in LEARN: Calendar > Subscribe, copy the link first)'))
        Say ('  By hand:     ' + (Paint 'cyan' 'jk due add cs350 "A3 File Systems" nov 25 8pm -Weight 10%'))
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
    # an online midterm is two rows, "opens" and "closes", and one exam
    $nExam = (Measure-JkDue $evs).Exams
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
        Say (Format-JkDueLine $e $cmap $w -Countdown:$useCountdown -Now $now -Data $data)
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

# A weight as it was stored: "17.5%", "20%" (Format-JkPct with no decimals gave "18%").
function Format-JkWeightPct([double]$W) {
    Format-JkPct $W $(if ([Math]::Abs($W - [Math]::Round($W)) -gt 0.001) { 1 } else { 0 })
}

# When an exam is over: its end time when known, else two hours after the start (a typical
# midterm); one with no time at all lasts the day. An online window's closing row is over when it
# closes: two more hours kept HEALTH 105's midterm, closed at 11:59 pm, the dashboard's "OPEN NOW"
# next exam until 1:59 am.
function Get-JkExamEnd($e) {
    $start = Get-JkEventDue $e
    if (-not $e.time) { return $start }
    if ([string]$e.title -match '(?i)\s+closes?$') { return $start }
    $end = [string](Get-JkProp $e 'end' '')
    if ($end -match '^(\d{1,2}):(\d{2})$') {
        $t = $start.Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2])
        if ($t -gt $start) { return $t }
    }
    $start.AddHours(2)
}

# jk exams: every remaining exam; jk exam cs370 [words]: one exam's brief.
function Invoke-JkExams {
    $a = @($args | ForEach-Object { [string]$_ } | Where-Object { $_ })
    if ($a.Count) { Show-JkExamBrief @a } else { Show-JkExams }
}

# Everything about one coming exam on a screen: when and where, what it is worth and what you need on
# it, the prep jk plan expects and has scheduled before it, what else is due first, and the files in
# the course folder named after it (numbered for jk find -o).
function Show-JkExamBrief {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Words)
    $data = Get-JkDueData
    $cmap = Get-JkCourseMap $data
    $now = Get-JkNow
    $w = @($Words | Where-Object { $_ })
    $course = $null
    if ($w.Count -eq 1) { $course = Resolve-JkCourse $data $w[0]; if ($course) { $w = @() } }
    elseif ($w.Count) { $sp = Split-JkCourseWords $data $w; $course = $sp[0]; $w = @($sp[1]) }
    $rx = @(Get-JkTitleWordRx $w)
    # an online window is one exam, at its opening while that is ahead
    $seen = @{}
    $cands = foreach ($e in @($data.events | Where-Object { $_.kind -eq 'exam' -and -not $_.done } | Sort-Object { Get-JkEventDue $_ }, id)) {
        if ($seen.ContainsKey([string]$e.id)) { continue }
        $win = Get-JkEventWindow $e $data
        if ($win) { $seen[[string]$win.Open.id] = $true; $seen[[string]$win.Close.id] = $true; $e = $win.Close }
        $end = Get-JkEventDue $e
        # one being written is still the one, until it is over (as jk exams and the dashboard have it):
        # "jk exam cs341" at 7 pm, in its 6:00-7:50 pm midterm, said no coming exam matched
        if ((Get-JkExamEnd $e) -le $now) { continue }
        if ($course -and $e.course -ne $course.key) { continue }
        $title = $(if ($win) { $win.Title } else { [string]$e.title })
        if ($rx.Count -and -not (Test-JkTitleWords $title $rx)) { continue }
        [pscustomobject]@{ E = $e; Win = $win; Title = $title; Start = $(if ($win) { $win.Opens } else { $end }); End = $end }
    }
    $x = @($cands | Sort-Object Start)[0]
    if (-not $x) {
        # a course named alone, past its last exam (or with none): say so, not that nothing matched
        if ($course -and -not $rx.Count) {
            $code = Get-JkCourseLabel ([pscustomobject]@{ course = $course.key }) $cmap
            $past = @($data.events | Where-Object { $_.kind -eq 'exam' -and $_.course -eq $course.key -and [string]$_.title -notmatch '(?i)\s+opens?$' } | Sort-Object { Get-JkEventDue $_ })
            if ($past.Count) {
                $last = $past[-1]; $t = ([string]$last.title -replace '(?i)\s+closes?$', '').Trim()
                throw "$code has no exam left: its $t was $((Get-JkEventDue $last).ToString('ddd MMM d', $script:Inv)) (jk grade $(Get-JkNormKey $code) for where the marks stand)"
            }
            # an entry like Interviews or OA is no course: nothing to add
            if ($code -notmatch '\d') { throw "$code has no exams (jk exams lists them all)" }
            throw "$code has no exams in jk (jk due add $(Get-JkNormKey $code) Midterm <date> <time> -Exam adds one)"
        }
        throw "no coming exam matches '$($Words -join ' ')' (jk exams lists them)"
    }
    $e = $x.E
    $label = "$(Get-JkCourseLabel $e $cmap) $($x.Title)"
    $left = $x.Start - $now
    $rel = $(if ($left.TotalSeconds -le 0) { $(if ($x.Win) { 'open now' } else { "under way, until $(Format-JkTime (Get-JkExamEnd $e).ToString('HH:mm', $script:Inv))" }) } elseif ($left.TotalHours -lt 24) { "in $(Format-JkDuration $left)" } else { Format-JkRelDay $x.Start $now })
    $c = @($data.courses | Where-Object { $_.key -eq $e.course })[0]
    Write-JkHeader $label $rel -Sub ([string]$c.name)
    $row = { param($k, $v) Say ('  ' + (Paint 'bold white' (Fit $k 9)) + $v) }
    $wrapRow = { param($k, $text, $style) Write-JkTip ('  ' + (Paint 'bold white' (Fit $k 9))) 11 $text $style -Indent 11 }

    $when = $x.Start.ToString('ddd MMM d', $script:Inv)
    if ($x.Win) { $when = "opens $when $(Format-JkTime $x.Start.ToString('HH:mm'))  $($script:G.dot)  closes $($x.End.ToString('ddd MMM d', $script:Inv)) $(Format-JkTime $x.End.ToString('HH:mm'))" }
    elseif ($e.time) {
        $when += ', ' + (Format-JkTime $e.time)
        $endT = [string](Get-JkProp $e 'end' ''); if ($endT) { $when += " $($script:G.dash) $(Format-JkTime $endT)" }
    }
    & $row 'when' (Paint 'white' $when)
    $notes = @(@([string]$e.note) + $(if ($x.Win) { @([string]$x.Win.Open.note) } else { @() }) | Where-Object { $_ } | Select-Object -Unique)
    # one row, without the times "when" already gives: a window's two notes ("11:59 pm - no
    # reopening", "6:00 am Dec 7 -> 11:59 pm Dec 8 - LEARN quiz") were two rows, both repeating them
    $parts = @()
    foreach ($src in @($(if ($x.Win) { $x.Win.Open }), $e) | Where-Object { $_ }) {
        foreach ($seg in @((Get-JkExamPlace $src) -split "\s*$([regex]::Escape($script:G.dot))\s*")) { if ($seg -and $parts -notcontains $seg) { $parts += $seg } }
    }
    if ($parts.Count) { & $wrapRow 'notes' ($parts -join " $($script:G.dot) ") 'muted' }
    # the weather on the way there, for one in person inside the forecast
    if (-not $x.Win -and $e.time -and ($notes -join ' ') -notmatch '(?i)\bonline\b' -and $x.Start -gt $now) {
        try { $wx = Get-JkExamWeather $x.Start; if ($wx) { & $wrapRow 'weather' $wx 'muted' } } catch { }
    }

    # what it is worth and what it needs
    $wt = Get-JkWeightValue ([string]$e.weight)
    $gd = Get-JkGradeData
    $m = Measure-JkGrade (Get-JkGradeItems $data $gd $e.course) (Get-JkGradeRules $data $e.course)
    $target = Get-JkTarget $gd $e.course
    if ($wt -gt 0) {
        $share = ''
        if ($m.Graded -gt 0 -and $m.Remaining -gt 0) { $share = "  ($([Math]::Round($wt / ($m.Remaining + $m.Unlisted) * 100))% of the marks still to come)" }
        & $row 'worth' ((Paint 'white' "$(Format-JkWeightPct $wt) of $(Get-JkCourseLabel $e $cmap)") + (Paint 'gray' $share))
    }
    if ($m.Graded -gt 0) {
        $need = Get-JkNeededText $target $m
        # when the target takes nearly everything, what the lower finishes take says more
        $lower = ''
        $restAll = $m.Remaining + [double]$m.Unlisted
        if ($restAll -gt 0.0001 -and 100 * ($target - $m.Banked) / $restAll -gt 90) {
            $bits = @(foreach ($t in 70, 60, 50) { if ($t -lt $target - 5) { $n = 100 * ($t - $m.Banked) / $restAll; if ($n -gt 0 -and $n -le 90) { "$t% takes $([int][Math]::Round($n))%" } } })
            if ($bits.Count) { $lower = " ($(@($bits | Select-Object -First 2) -join ', '))" }
        }
        & $wrapRow 'marks' "$(Format-JkPct $m.Average) on the $(Format-JkPct $m.Graded 0) graded so far; to finish at $(Format-JkPct $target 0) you need $($need[0]) on the rest, this exam included$lower" 'muted'
    } else {
        & $wrapRow 'marks' "none recorded for this course yet $($script:G.dash) jk grade fill, then this says what you need on it" 'gray'
    }
    # the course's exam pass rule, when this exam is still to be written for it
    try {
        foreach ($r in @(Measure-JkPassRules $data $gd $e.course | Where-Object { $_.Kind -eq 'exam' -and $null -ne $_.Need })) {
            $t = Format-JkPassRule $r
            & $wrapRow 'pass' $t[0] $t[1]
        }
    } catch { }
    # what a mark here would leave the rest needing (the what-if of jk grade <course> if, at four marks)
    $gitems = @(Get-JkGradeItems $data $gd $e.course)
    $gi = @($gitems | Where-Object { $_.Key -eq [string]$e.id -or ($x.Win -and $_.Key -eq [string]$x.Win.Open.id) })[0]
    if ($gi -and $null -eq $gi.Score -and $wt -gt 0) {
        $cells = foreach ($p in 60, 70, 80, 90) {
            $scores = @(@($gd.scores | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; score = [double]$_.score } }) | Where-Object { $_.id -ne $gi.Key }) + [pscustomobject]@{ id = [string]$gi.Key; score = [double]$p }
            $hypo = [pscustomobject]@{ scores = $scores; extras = $gd.extras; targets = $gd.targets; nextExtra = $gd.nextExtra }
            $mh = Measure-JkGrade (Get-JkGradeItems $data $hypo $e.course) (Get-JkGradeRules $data $e.course)
            $restH = $mh.Remaining + [double]$mh.Unlisted
            [pscustomobject]@{ Text = "$p $($script:G.arrow) $((Get-JkNeededText $target $mh)[0])"; Most = $mh.Banked + $restH; Mark = $p
                Reach = $(if ($restH -gt 0.0001) { 100 * ($target - $mh.Banked) / $restH -le 100 } else { $mh.Banked -ge $target }) }
        }
        $note = ''; if ($m.Graded -le 0) { $note = ' (no marks in yet, so all the other work counts as still to come)' }
        if (-not @($cells | Where-Object { $_.Reach }).Count) {
            # the target is gone whatever the mark ("60 -> 211% (!)" four times says nothing): where the
            # course can still end, with full marks on everything else
            $most = @($cells | ForEach-Object { "$($_.Mark) $($script:G.arrow) $([int][Math]::Floor($_.Most))%" })
            & $wrapRow 'if' "a mark here of $($most -join "  $($script:G.dot)  ") for the course at most, with full marks on the rest ($(Format-JkPct $target 0) is out of reach)" 'muted'
        }
        else { & $wrapRow 'if' "a mark here of $(@($cells | ForEach-Object { $_.Text }) -join "  $($script:G.dot)  ") on the rest, for $(Format-JkPct $target 0)$note" 'muted' }
    }

    # prep: jk plan's estimate for it, focus already credited, and the blocks scheduled before it
    try {
        $p = Get-JkPlanToday
        $it = $null
        if ($p) { $it = @($p.Items | Where-Object { $_.Key -eq "$($e.course)|#$($e.id)" })[0] }
        # hours before it starts, an estimate of the hours it deserved no longer helps
        if ($it -and ($x.End - $now).TotalHours -ge 3) {
            $before = 0.0; $today = 0.0
            foreach ($d in @($p.Schedule)) { $mins = [double]$d.Alloc[$it.Key]; $before += $mins; if ($d.Day -eq $now.Date) { $today = $mins } }
            $txt = "about $(Format-JkMinutes $it.Effort) of prep for $(Format-JkWeightPct $wt)"
            if ($it.Done -gt 0) { $txt += ", $(Format-JkMinutes $it.Done) of it logged" }
            # the plan is drawn a week ahead: for an exam past that, the week is not all of its prep
            $last = @($p.Schedule)[-1].Day
            $sched = $(if ($x.Start.Date -gt $last) { "; jk plan has $(Format-JkMinutes $before) of it in the next 7 days" } else { "; jk plan has $(Format-JkMinutes $before) before it" })
            if ($today -gt 0) { $sched += " ($(Format-JkMinutes $today) today)" }
            & $wrapRow 'prep' ($txt + $sched) 'muted'
        }
    } catch { }

    # what else lands in the week before it (competing for the same study days)
    $from = $x.Start.AddDays(-7); if ($from -lt $now) { $from = $now }
    $first = @($data.events | Where-Object { -not $_.done -and $_.id -ne $e.id -and -not ($x.Win -and $_.id -eq $x.Win.Open.id) -and ($d = Get-JkEventDue $_) -ge $from -and $d -lt $x.Start -and ([string]$_.title -notmatch '(?i)\sopens?$') } | Sort-Object { Get-JkEventDue $_ } | Select-Object -First 5)
    if ($first.Count) {
        $txt = ($first | ForEach-Object {
                $dd = Get-JkEventDue $_
                $t = [string]$_.title; $verb = ''
                # the closing half of an online window reads as the quiz itself, open until then
                if ($t -match '(?i)\s+closes?$' -and (Get-JkEventWindow $_ $data)) { $t = $t -replace '(?i)\s+closes?$', ''; $verb = 'closes ' }
                # a week out, the exam's own weekday is today's too: "today", not "Mon"
                $day = $dd.ToString('ddd', $script:Inv)
                if ($dd.Date -eq $now.Date) { $day = 'today' } elseif ($dd.Date -eq $now.Date.AddDays(1)) { $day = 'tomorrow' }
                # further off, a bare "Mon" reads as the coming Monday: say which
                elseif (($dd.Date - $now.Date).TotalDays -ge 7) { $day = $dd.ToString('ddd MMM d', $script:Inv) }
                "$(Get-JkCourseLabel $_ $cmap) $t ($verb$day $(Format-JkTime $dd.ToString('HH:mm')))"
            }) -join "  $($script:G.dot)  "
        & $wrapRow 'before' $txt 'muted'
    }

    # the course folder's files named after it
    $f = $null
    try { $f = Get-JkDueFileHits $data $e } catch { }
    Say ''
    if ($f -and @($f.Hits).Count) {
        $show = @($f.Hits | Select-Object -First 6)
        Save-JkFindLast $show
        Say (' ' + (Paint 'bold white' 'Files') + (Paint 'gray' "  named after it in $(Get-JkShortPath $f.Dir)"))
        Write-JkFindRows $show
    } elseif ($f -and @($f.All).Count) {
        # nothing named after it: the newest lecture material first (slides, notes, L11.pdf), then
        # whatever else changed last
        $study = '(?i)lecture|\blec|slides?|notes|module|chapter|review|practice|tutorial|\bL\d{1,2}\b'
        $lect = @($f.All | Where-Object { "$($_.Folder)\$($_.Name)" -match $study } | Sort-Object Modified -Descending)
        $rest = @($f.All | Where-Object { "$($_.Folder)\$($_.Name)" -notmatch $study } | Sort-Object Modified -Descending)
        $show = @(@($lect) + @($rest) | Select-Object -First 5)
        Save-JkFindLast $show
        Say (' ' + (Paint 'bold white' 'Files') + (Paint 'gray' "  none named after it; $(if ($lect.Count) { 'the newest lecture material' } else { 'the newest' }) in $(Get-JkShortPath $f.Dir)"))
        Write-JkFindRows $show
    } elseif ($f) { Say (Paint 'gray' "  $(Get-JkShortPath $f.Dir) is empty") }
    $key = Get-JkNormKey ([string]$c.code)
    if ($f) { Say ((Paint 'gray' '  a topic inside its PDFs and slides: ') + (Paint 'white' "jk grep $key <words>")) }
    Say (Paint 'gray' "  jk focus 50 $key $(($x.Title -replace '\s+', ' ').ToLower())  $($script:G.dot)  jk find -o 1 opens a file  $($script:G.dot)  jk grade $key")
}

function Show-JkExams {
    $data = Get-JkDueData
    $cmap = Get-JkCourseMap $data
    $now = Get-JkNow
    $w = Get-JkWidth
    # an exam stays until it is over (not until midnight): the evening after it is no longer "0d"
    $evs = @($data.events | Where-Object { $_.kind -eq 'exam' -and -not $_.done -and (Get-JkExamEnd $_) -gt $now } | Sort-Object { Get-JkEventDue $_ })
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
    # under each course's next exam: what its marks need (the target, and the pass rule)
    $gd = $null; try { $gd = Get-JkGradeData } catch { }
    $needShown = @{}
    foreach ($row in $rows) {
        $e = $row.E
        $win = $row.Win
        $due = Get-JkEventDue $e
        $title = [string]$e.title
        $when = $due.ToString('ddd MMM d', $script:Inv)
        if ($e.time) { $when += ' ' + (Format-JkTime $e.time) }
        # with the room of the class it is held in ("in class, MC 2017")
        $notes = @([string]$e.note)
        $xc = Get-JkExamClass $e
        if ($xc -and $xc.Class.room -and -not ([string]$e.note).Contains([string]$xc.Class.room)) { $notes = @("$(@(([string]$e.note) -split " $([regex]::Escape($script:G.dot)) ")[0]), $($xc.Class.room)") + @(@(([string]$e.note) -split " $([regex]::Escape($script:G.dot)) ") | Select-Object -Skip 1) }
        if ($win) {
            $title = $win.Title
            $closeTxt = $win.Closes.ToString('ddd MMM d', $script:Inv) + ' ' + (Format-JkTime $win.Closes.ToString('HH:mm', $script:Inv))
            # the halves' notes without the times the row already gives ("6:00 am Dec 7 -> 11:59 pm
            # Dec 8" and "11:59 pm"), each part once: "LEARN quiz", "no reopening"
            $notes = @(@((Get-JkExamNote $win.Open) -split " $([regex]::Escape($script:G.dot)) ") + @((Get-JkExamNote $win.Close) -split " $([regex]::Escape($script:G.dot)) ") | Where-Object { $_ } | Select-Object -Unique)
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
        if (-not $win -and $due -le $now) { $countTxt = ' now' }
        $style = 'gray'
        if ($days -le 3) { $style = 'bold red' } elseif ($days -le 7) { $style = 'orange' } elseif ($days -le 14) { $style = 'yellow' }
        $line = '  ' + (Paint $style $countTxt) + '  ' + (Paint "bold #$color" (Fit (Get-JkCourseLabel $e $cmap) 11)) + (Paint 'bold white' (Fit $title 22)) + ' ' + (Paint 'muted' (Fit $when 22)) + (Paint 'gray' (Fit ([string]$e.weight) 6 -Right))
        Say $line
        $note = @($notes | Where-Object { $_ }) -join " $($script:G.dot) "
        if ($note) { Say ('                     ' + (Paint 'gray' (Fit $note ($w - 22)).TrimEnd())) }
        if ($gd -and -not $needShown.ContainsKey([string]$e.course)) {
            $needShown[[string]$e.course] = $true
            $txt = ''
            try { $txt = Get-JkExamNeedLine $data $gd ([string]$e.course) } catch { }
            if ($txt) { Say ('                     ' + (Paint 'muted' (Fit $txt ($w - 22)).TrimEnd())) }
        }
    }
}

# One line for jk exams: what the rest of a course needs for its target, and what an exam pass rule
# needs ("for 80%: 99% on the rest . to pass, the FINAL needs 59%"). '' when there are no marks.
function Get-JkExamNeedLine($Data, $GradeData, [string]$Course) {
    $m = Measure-JkGrade (Get-JkGradeItems $Data $GradeData $Course) (Get-JkGradeRules $Data $Course)
    $bits = @()
    if ($m.Graded -gt 0) {
        $target = Get-JkTarget $GradeData $Course
        $bits += "for $(Format-JkPct $target 0): $((Get-JkNeededText $target $m)[0]) on the rest"
    }
    foreach ($r in @(Measure-JkPassRules $Data $GradeData $Course | Where-Object { $_.Kind -eq 'exam' -and $null -ne $_.Need -and $null -ne $_.Average -and -not $_.Held })) {
        # only with marks behind it (as jk grade lists them): with none, "the exams left" would
        # count a midterm already written but not yet marked
        $what = $(if (@($r.Left).Count -eq 1) { "the $(@($r.Left)[0])" } else { 'the exams left' })
        $bits += "to pass, $what $(if (@($r.Left).Count -eq 1) { 'needs' } else { 'need' }) $([int][Math]::Ceiling($r.Need - 0.0001))%"
    }
    $bits -join " $($script:G.dot) "
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

# A title in fewer characters, for a cell too narrow for it: "Assignment 6" -> "A6", "Midterm 2" ->
# "Mid 2", "Quiz 3" -> "Q3", and a window's "closes" (its deadline) dropped. Other words stay.
function Get-JkShortTitle([string]$Title) {
    $t = $Title -replace '(?i)\bAssignment\s*#?\s*(\d+[a-z]?)\b', 'A$1'
    $t = $t -replace '(?i)\bQuiz\s*#?\s*(\d+)\b', 'Q$1'
    $t = $t -replace '(?i)\bHomework\s*#?\s*(\d+)\b', 'HW$1'
    $t = $t -replace '(?i)\bProblem Set\s*#?\s*(\d+)\b', 'PS$1'
    $t = $t -replace '(?i)\bMidterm\b', 'Mid'
    $t = $t -replace '(?i)\bAssignment\b', 'Asst'
    $t = $t -replace '(?i)\bProject\b', 'Proj'
    ($t -replace '(?i)\s+closes?$', '').Trim()
}

function Show-JkDueWeek {
    param([int]$Weeks = 2)
    # a term and a half at most: "jk due week 99999" would draw 99999 weeks, for a quarter of an hour
    if ($Weeks -lt 1 -or $Weeks -gt 26) { throw 'jk week takes 1 to 26 weeks (jk due all lists everything)' }
    $data = Get-JkDueData
    $cmap = Get-JkCourseMap $data
    $now = Get-JkNow
    $w = Get-JkWidth
    # seven columns and a leading space within the window; 7 still fits "Mon 19"
    $colW = [Math]::Max(7, [int][Math]::Floor(($w - 1) / 7))
    $monday = $now.Date.AddDays(-(([int]$now.DayOfWeek + 6) % 7))
    $info = Get-JkTermInfo $data $now
    Write-JkHeader 'Week view' (Format-JkTermLine $info)
    $dayStyle = { param($d) if ($d -eq $now.Date) { 'bold bg:white ink' } elseif ($d -lt $now.Date) { 'gray dim' } else { 'bold muted' } }
    $itemStyle = { param($e)
        $color = Get-JkCourseColor $e.course $cmap
        if ($e.done) { 'gray strike' } elseif ((Get-JkEventDue $e) -lt $now) { 'gray dim' } elseif ($e.kind -eq 'exam') { "bold bg:#$color ink" } else { "#$color" }
    }
    # under ~100 columns a cell is too narrow to say anything ("HEALTH105..."): a line per day
    # instead, the day's items in full, wrapping under themselves
    if ($colW -lt 14) {
        for ($wk = 0; $wk -lt $Weeks; $wk++) {
            $start = $monday.AddDays(7 * $wk)
            for ($i = 0; $i -lt 7; $i++) {
                $d = $start.AddDays($i)
                $key = $d.ToString('yyyy-MM-dd', $script:Inv)
                $list = @($data.events | Where-Object { $_.date -eq $key } | Sort-Object { if ($_.kind -eq 'exam') { 0 } else { 1 } }, time)
                $lead = ' ' + (Paint (& $dayStyle $d) ($d.ToString('ddd d', $script:Inv))) + (' ' * (8 - $d.ToString('ddd d', $script:Inv).Length))
                if (-not $list.Count) { Say ($lead + (Paint 'gray' $script:G.dash)); continue }
                $line = $lead; $used = 9
                foreach ($e in $list) {
                    $txt = "$(Get-JkCourseLabel $e $cmap) $($e.title)"
                    $tw = Get-JkTextWidth $txt
                    $sep = ''; if ($used -gt 9) { $sep = Paint 'gray' "  $($script:G.dot)  "; $sepW = 5 } else { $sepW = 0 }
                    if ($used -gt 9 -and $used + $sepW + $tw -gt $w) { Say $line; $line = ' ' * 9; $used = 9; $sep = ''; $sepW = 0 }
                    $line += $sep + (Paint (& $itemStyle $e) $txt); $used += $sepW + $tw
                }
                Say $line
            }
            Say ''
        }
        return
    }
    # the kept forecast, for a line under the days it reaches (none for a place in another zone)
    $wx = $null
    try { $p = Get-JkWeatherPlace -NoLookup; if ($p) { $wx = Get-JkWeather -Place $p -CacheOnly; if ($wx -and $null -ne $wx.Offset) { $wx = $null } } } catch { }
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
        if ($wx) {
            $row = ' '; $any = $false
            for ($i = 0; $i -lt 7; $i++) {
                $d = $start.AddDays($i)
                $txt = ''; $st = 'gray'
                if ($d -ge $now.Date) {
                    $s = $null; try { $s = Get-JkWeatherDayShort $wx $d $now } catch { }
                    if ($s) { $txt = $s.Text; $any = $true; if ($s.Wet) { $st = 'cyan' } }
                }
                $row += (Paint $st (Fit $txt ($colW - 1))) + ' '
            }
            if ($any) { Say $row }
        }
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
                    # too long for the cell: "HEALTH105 A6", not "HEALTH105 As..." three times a day
                    $txt = "$code $($e.title)"
                    if ((Get-JkTextWidth $txt) -gt ($colW - 1)) { $txt = "$code $(Get-JkShortTitle ([string]$e.title))" }
                    $txt = Fit $txt ($colW - 1)
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
    $w = @($When | Where-Object { $_ })
    # "Midterm 2 nov 19": a number between the title and a month and day belongs to the title
    if ($w.Count -ge 3 -and $w[0] -match '^\d{1,2}$' -and $w[1] -match "^(?i)$($script:JkMonthRx)" -and $w[2] -match '^\d{1,2}(st|nd|rd|th)?,?$') {
        $Title = "$Title $($w[0])"; $w = @($w | Select-Object -Skip 1)
    }
    # "nov 19 7-8:50pm": an exam's start and end in one go
    $whenTxt = $w -join ' '
    if (-not $End -and $whenTxt -match '^(?<pre>.*?)\s*(?<range>\d{1,2}(?::\d{2})?\s*(?:am|pm)?\s*(?:-|\p{Pd})\s*\d{1,2}(?::\d{2})?\s*(?:am|pm)?)$') {
        $pre = $Matches['pre']; $rangeTxt = $Matches['range']
        try { $r = ConvertTo-JkTimeRange $rangeTxt; $End = $r.End; $w = @("$pre $($r.Start)".Trim() -split '\s+') } catch { }
    }
    # A4 Paging dec 2 8pm without quotes: the words before the date are the rest of the title;
    # "due nov 6", "on fri", "by mon" read past the leading word
    $parsed = $null
    for ($i = 0; $i -lt $w.Count -and -not $parsed; $i++) {
        $rest = @($w | Select-Object -Skip $i)
        if ($rest.Count -gt 1 -and $rest[0] -match '^(?i)(due|on|by|at)$') { $rest = @($rest | Select-Object -Skip 1) }
        try {
            $parsed = ConvertFrom-JkWhen ($rest -join ' ')
            if ($i) { $Title = "$Title $(@($w | Select-Object -First $i) -join ' ')" }
        } catch { if (Test-JkNoSuchDate $_) { throw } }   # "nov 31": a typo, not title words before "31"
    }
    if (-not $parsed) { $parsed = ConvertFrom-JkWhen ($When -join ' ') }   # says what it could not read
    if ($Weight -and $Weight -match '^\d+(\.\d+)?$') { $Weight += '%' }
    $kind = 'due'
    if ($Exam) { $kind = 'exam' } elseif ($Appt) { $kind = 'appt' }
    if ($End) { $End = ConvertTo-JkTime (Get-JkDayTimeText $End) }
    $e = New-JkEvent -Data $data -Course $c.key -Date $parsed.Date -Time $parsed.Time -Title $Title -Weight $Weight -Note $Note -Kind $kind -End $End
    Save-JkDueData $data
    $cmap = Get-JkCourseMap $data
    Say ((Paint 'green' "  added $($script:G.check)") + '  ' + (Format-JkDueLine $e $cmap ((Get-JkWidth) - 12) -WithDate).TrimStart())
    if ((Get-JkEventDue $e) -lt (Get-JkNow)) {
        Say (Paint 'yellow' "  note: that is in the past ($($parsed.Date.ToString('ddd MMM d yyyy', $script:Inv))) - fix with: jk due edit $($e.id) -Date <date>")
    }
    # the same item already there (from LEARN, or typed before): moving that one is usually meant
    $twin = @($data.events | Where-Object { $_.id -ne $e.id -and $_.course -eq $e.course -and -not $_.done -and ([string]$_.title).Trim() -eq $Title.Trim() })
    foreach ($t in $twin) {
        $when = ([datetime]::ParseExact([string]$t.date, 'yyyy-MM-dd', $script:Inv)).ToString('ddd MMM d', $script:Inv)
        Say (Paint 'yellow' "  note: $($c.code) already has $($t.title) on $when (#$($t.id)) - if this one replaces it: jk due rm $($t.id)")
    }
}

# A bare hour after a date: "fri 5" is 5 pm. Nobody schedules 5 in the morning without saying so;
# from 7 on it could be either, and the reading is printed back.
function Get-JkDayTimeText([string]$Text) {
    if ($Text -match '^\s*[1-6](:\d{2})?\s*$') { return "$($Text.Trim()) pm" }
    $Text
}

# Splits "nov 25 8pm" / "fri at 11:59 pm" / "tomorrow" into a date and optional time; the time can
# come first ("5pm fri", "11:59 pm dec 2", "8pm tonight"). Everyday phrasings are rewritten first:
# "tonight" / "eod" (today 11:59 pm), "in 3 days" / "in a week" (+3, +7); and a time on its own
# ("8pm") means today, or tomorrow once that time has passed.
function ConvertFrom-JkWhen([string]$Text) {
    $w = ($Text -replace '\s+(?:at|@)\s+', ' ').Trim().ToLower()
    if ($w -match '^(tonight|eod|end of (the )?day)$') { $w = 'today 11:59pm' }
    elseif ($w -match '^tonight\s+') { $w = ($w -replace '^tonight\s+((?:1[01]|[1-9])(?::\d{2})?)$', 'tonight $1pm') -replace '^tonight', 'today' }
    if ($w -match '^in\s+(\d+|a|an|one)\s+(days?|weeks?)\b(.*)$') {
        # read every group before any other -match: each one replaces $Matches
        $n = $Matches[1]; $unit = $Matches[2]; $rest = $Matches[3]
        if ($n -notmatch '^\d+$') { $n = 1 }
        $mult = 1; if ($unit -like 'week*') { $mult = 7 }
        $w = ('+' + ([int]$n * $mult) + $rest).Trim()
    }
    $tokens = @($w -split '\s+' | Where-Object { $_ })
    for ($k = $tokens.Count; $k -ge 1; $k--) {
        $dTxt = ($tokens[0..($k - 1)]) -join ' '
        $tTxt = ''
        if ($k -lt $tokens.Count) { $tTxt = ($tokens[$k..($tokens.Count - 1)]) -join ' ' }
        try { $d = ConvertTo-JkDate $dTxt } catch { if (Test-JkNoSuchDate $_) { throw }; continue }
        $t = ''
        if ($tTxt) { try { $t = ConvertTo-JkTime (Get-JkDayTimeText $tTxt) } catch { continue } }
        return [pscustomobject]@{ Date = $d; Time = $t }
    }
    # the time first: only a plain time (am/pm, a colon, noon) before words that can only be a day,
    # so "Quiz 3 fri" keeps its 3 and "5pm 3d" is not a date
    for ($k = [Math]::Min(2, $tokens.Count - 1); $k -ge 1; $k--) {
        $tTxt = (($tokens[0..($k - 1)]) -join ' ') -replace '\.', ''
        $dTxt = (($tokens[$k..($tokens.Count - 1)]) -join ' ') -replace '^tonight$', 'today'
        if ($tTxt -notmatch '^(\d{1,4}(:\d{2})? ?(am|pm|a|p)|\d{1,2}:\d{2}|noon|midnight)$' -or -not (Test-JkDayAfterTime $dTxt)) { continue }
        try { $t = ConvertTo-JkTime $tTxt } catch { continue }
        try { $d = ConvertTo-JkDate $dTxt } catch { if (Test-JkNoSuchDate $_) { throw }; continue }
        return [pscustomobject]@{ Date = $d; Time = $t }
    }
    # a time alone
    try {
        $t = ConvertTo-JkTime $w
        $now = Get-JkNow
        $d = $now.Date
        $p = $t.Split(':')
        if ($d.AddHours([int]$p[0]).AddMinutes([int]$p[1]) -le $now) { $d = $d.AddDays(1) }
        return [pscustomobject]@{ Date = $d; Time = $t }
    } catch { }
    throw "can't understand when '$Text' (examples: nov 25 8pm, fri 11:59pm, tomorrow, in 3 days, 8pm, tonight, 2026-12-04)"
}

function Set-JkDueDone {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Refs, [switch]$Undo)
    if (-not $Refs) { throw "usage: jk due $(if ($Undo) { 'undone' } else { 'done' }) <id|text> [...]" }
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
    # "-Date nov 8 5pm" / "-Date nov 8 at 5pm": the time after the date
    if ($Date -and -not $Time -and $left.Count) {
        $tw = @($left | Where-Object { $_ -notmatch '^(?i)at$' }) -join ' '
        $ok = $true; try { $null = ConvertTo-JkTime $tw } catch { $ok = $false }
        if ($ok) { $Time = $tw; $left.Clear() }
    }
    if ($left.Count) { throw "unexpected words: $($left -join ' ') (quote values with spaces)" }
    if (-not $Ref) { throw 'usage: jk due edit <id> [-Title ..] [-Date ..] [-Time ..] [-Weight ..] [-Note ..] [-Course ..] [-Exam|-Due|-Appt] [-NoTime]' }
    $data = Get-JkDueData
    $e = @(Find-JkEvents $data @($Ref))[0]
    if ($Title) { $e.title = $Title }
    if ($Date) {
        # the same phrases as adding: "in 3 days", "tonight", "nov 8 5pm" in quotes
        $pw = ConvertFrom-JkWhen $Date
        $e.date = $pw.Date.ToString('yyyy-MM-dd', $script:Inv)
        if ($pw.Time -and -not $Time) { $e.time = $pw.Time }
    }
    if ($Time) { $e.time = ConvertTo-JkTime (Get-JkDayTimeText $Time) }
    if ($NoTime) { $e.time = '' }
    if ($End) { Set-JkProp $e 'end' (ConvertTo-JkTime (Get-JkDayTimeText $End)) }
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
    $rows = @($Soon | Where-Object { $_.kind -eq 'exam' -and (Get-JkEventDue $_).Date -eq $Now.Date })
    if (-not $rows.Count) { return $null }
    # an online exam that opens and closes today is one exam: its closing row ("by 11:59 pm") says it
    $today = @($rows | Group-Object { "$($_.course)|$(([string]$_.title -replace '(?i)\s+(opens?|closes?)$', '').Trim())" } | ForEach-Object {
            $c = @($_.Group | Where-Object { [string]$_.title -match '(?i)\s+closes?$' })
            if ($c.Count) { $c[0] } else { $_.Group[0] }
        } | Sort-Object { Get-JkEventDue $_ })
    $names = @(foreach ($e in $today) {
        $t = ([string]$e.title -replace '(?i)\s+(opens?|closes?)$', '').Trim()
        $at = ''
        if ($e.time) { $at = ' ' + (Format-JkTime $e.time); if ([string]$e.title -match '(?i)\s+closes?$') { $at = ", by$at" } }
        "$(Get-JkCourseLabel $e $Cmap) $t$at"
    })
    if ($today.Count -eq 1) { return "Exam today: $($names[0])" }
    "$($today.Count) exams today: " + (@($today | ForEach-Object { "$(Get-JkCourseLabel $_ $Cmap) $(([string]$_.title -replace '(?i)\s+(opens?|closes?)$', '').Trim())" }) -join ', ')
}

# The title when the next two days hold an exam but today does not: "Exam tomorrow: CS 350
# Midterm 4:30 pm (+2 more due)", "Exam Mon: HEALTH 105 Midterm 1 opens 6:00 am". $null without one.
function Get-JkExamSoonTitle($Soon, $Cmap, [datetime]$Now, $Data) {
    $x = @($Soon | Where-Object { $_.kind -eq 'exam' } | Sort-Object { Get-JkEventDue $_ })[0]
    if (-not $x) { return $null }
    $d = Get-JkEventDue $x
    $day = $d.ToString('ddd', $script:Inv)
    if ($d.Date -eq $Now.Date.AddDays(1)) { $day = 'tomorrow' }
    $t = "Exam ${day}: $(Get-JkCourseLabel $x $Cmap) $($x.title)"
    if ($x.time) { $t += ' ' + (Format-JkTime $d.ToString('HH:mm', $script:Inv)) }
    # an online window that has opened can be written today: "Exam open now: ... closes tomorrow 11:59 pm"
    if ($Data -and [string]$x.title -match '(?i)\s+closes?$') {
        $win = Get-JkEventWindow $x $Data
        if ($win -and $win.Opens -le $Now) {
            $t = "Exam open now: $(Get-JkCourseLabel $x $Cmap) $(([string]$x.title -replace '(?i)\s+closes?$', '').Trim()), closes $day"
            if ($x.time) { $t += ' ' + (Format-JkTime $d.ToString('HH:mm', $script:Inv)) }
        }
    }
    # what else the two days hold, counted as the dashboard does: this exam's other half is not more,
    # and neither is a quiz window's opening
    $xKey = "$($x.course)|$(([string]$x.title -replace '(?i)\s+(opens?|closes?)$', '').Trim())"
    $m = Measure-JkDue @($Soon | Where-Object { "$($_.course)|$(([string]$_.title -replace '(?i)\s+(opens?|closes?)$', '').Trim())" -ne $xKey -or $_.kind -ne 'exam' })
    $more = @()
    if ($m.Due) { $more += "+$($m.Due) more due" }
    if ($m.Exams) { $more += "+$(Format-JkCount $m.Exams 'exam')" }
    if ($more.Count) { $t += " ($($more -join ', '))" }
    $t
}

# How many things a list of rows is: Due, the deadlines (a quiz window's opening is not one: its
# "closes" is), and Exams, each exam once (an online one is two rows, "opens" and "closes").
function Measure-JkDue($Events) {
    $ev = @($Events | Where-Object { $_ })
    $exams = @($ev | Where-Object { $_.kind -eq 'exam' } | ForEach-Object { "$($_.course)|$(([string]$_.title -replace '(?i)\s+(opens?|closes?)$', '').Trim())" } | Select-Object -Unique).Count
    $due = @($ev | Where-Object { $_.kind -ne 'exam' -and [string]$_.title -notmatch '(?i)\s+opens?$' }).Count
    [pscustomobject]@{ Due = $due; Exams = $exams }
}

# "2 due, 1 exam", "3 exams", "4 due"; "0 due" for none.
function Format-JkDueCounts($M) {
    $parts = @()
    if ($M.Due -or -not $M.Exams) { $parts += "$($M.Due) due" }
    if ($M.Exams) { $parts += Format-JkCount $M.Exams 'exam' }
    $parts -join ', '
}

# Sunday's look at the week: "This week: 9 due, 3 exams - CO 367 Quiz 2 Thu, CS 350 Midterm Thu,
# CS 370 Midterm Mon". An online exam's opens/closes pair counts once. $null when the week is empty.
function Get-JkWeekAheadLine($Data, $Cmap, [datetime]$Now) {
    $end = $Now.Date.AddDays(8)
    $week = @($Data.events | Where-Object { -not $_.done -and ($d = Get-JkEventDue $_) -ge $Now -and $d -lt $end } | Sort-Object { Get-JkEventDue $_ })
    if (-not $week.Count) { return $null }
    $seen = @{}
    $exams = @(foreach ($e in ($week | Where-Object { $_.kind -eq 'exam' })) {
        $t = ([string]$e.title -replace '(?i)\s+(opens?|closes?)$', '').Trim()
        $k = "$($e.course)|$t"
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $dd = Get-JkEventDue $e
        # this morning's is "today", and next Sunday's has its date: a bare "Sun" reads as today
        "$(Get-JkCourseLabel $e $Cmap) $t $(if ($dd.Date -eq $Now.Date) { 'today' } else { Format-JkComingDay $dd $Now })"
    })
    # a quiz window's opening is not something due: its "closes" is the one deadline
    $other = (Measure-JkDue $week).Due
    $txt = "This week: $other due"
    if ($exams.Count) {
        $txt += ", $(Format-JkCount $exams.Count 'exam') $($script:G.dash) " + (@($exams | Select-Object -First 3) -join ', ')
        if ($exams.Count -gt 3) { $txt += ", +$($exams.Count - 3) more" }
    }
    $txt
}

function Invoke-JkDueRemind {
    param([double]$Hours = 0, [switch]$Quiet, [switch]$Force)
    if (-not $Hours) { $Hours = [double](Get-JkConfig 'remind.hours') }
    $state = Read-JkJson 'state.json' $null
    if (-not $state) { $state = [pscustomobject]@{} }
    $now = Get-JkNow
    $last = Get-JkProp $state 'lastRemind'
    if (-not $Force -and $last) {
        # a stamp from the future (clock change, pinned test clock) must not silence the brief, and
        # one that cannot be read counts as never: it threw, and cost the popup every morning
        $lastDt = [datetime]::MinValue
        if ([datetime]::TryParse([string]$last, $script:Inv, [Globalization.DateTimeStyles]::None, [ref]$lastDt) -and $lastDt -le $now -and ($now - $lastDt).TotalHours -lt 3) { if (-not $Quiet) { Say (Paint 'gray' '  reminded less than 3h ago; use -Force') }; return }
    }
    $soon = @(Get-JkDueSoon -Hours $Hours)
    # an exam up to three days out is worth a morning's notice too: the weekend before a Monday
    # midterm is when the studying happens
    $examsAhead = @()
    if ($Hours -lt 72) {
        $examsAhead = @(Get-JkDueSoon -Hours 72 | Where-Object { $_.kind -eq 'exam' -and (Get-JkEventDue $_) -gt $now.AddHours($Hours) -and [string]$_.title -notmatch '(?i)\s+closes?$' })
    }
    # the rest of today's classes ride along, so the morning popup doubles as a day brief
    $classes = @()
    try { $classes = @(Get-JkClassesOn $now.Date | Where-Object { $_.Start -gt $now }) } catch { }
    $data = Get-JkDueData
    $cmap = Get-JkCourseMap $data
    # Sundays also look at the whole week, and that alone is reason enough for the popup
    $weekLine = $null
    if ($now.DayOfWeek -eq 'Sunday') { $weekLine = Get-JkWeekAheadLine $data $cmap $now }
    # open to-dos due today (or already overdue) ride along too, and are reason enough on their own
    $todos = @()
    try { $todos = @((Get-JkTodoData).items | Where-Object { -not $_.done -and ($td = Get-JkTodoDue $_) -and $td.Date -le $now.Date } | Sort-Object { Get-JkTodoDue $_ }) } catch { }
    # deadlines the overnight LEARN sync moved, said once
    $movedNotes = @(@(Get-JkState 'syncMoved' @()) | Where-Object { $_ })
    # in the study break and the exam period every day is a study day: planned study time is
    # reason enough for the brief, which then leads with the next exam
    $plan = $null; $studyDay = $false; $nextExam = $null
    try {
        $info = Get-JkTermInfo $data $now
        if ($info -and $info.Phase -in 'study', 'exams') {
            $plan = Get-JkPlanToday
            if ($plan -and $plan.Today.Alloc.Count) {
                $studyDay = $true
                $nextExam = @($data.events | Where-Object { $_.kind -eq 'exam' -and -not $_.done -and (Get-JkEventDue $_) -ge $now } | Sort-Object { Get-JkEventDue $_ })[0]
            }
        }
    } catch { }
    # freezing rain, deep snow, a bitter wind chill: worth the popup even on a quiet day
    $wxWarn = ''; try { $wxWarn = Get-JkMorningWarning $now } catch { }
    if ($soon.Count -eq 0 -and $classes.Count -eq 0 -and -not $weekLine -and -not $todos.Count -and -not $examsAhead.Count -and -not $studyDay -and -not $movedNotes.Count -and -not $wxWarn) { if (-not $Quiet) { Say (Paint 'green' "  nothing due in the next $Hours hours and no more classes today") }; return }
    $lines = @()
    if ($movedNotes.Count) {
        $more = ''; if ($movedNotes.Count -gt 3) { $more = "; +$($movedNotes.Count - 3) more" }
        $lines += "LEARN moved: $(@($movedNotes | Select-Object -First 3) -join '; ')$more"
    }
    if ($weekLine) { $lines += $weekLine }
    # a class that holds an exam is that exam, said below with its room
    $classes = @($classes | Where-Object { $m = $_; -not @($data.events | Where-Object { -not $_.done -and $_.kind -eq 'exam' -and $_.course -eq $m.Class.course -and ($c = Get-JkExamClass $_) -and $c.Start -eq $m.Start }).Count })
    if ($classes.Count) {
        $lines += 'Classes today: ' + (($classes | ForEach-Object { "$(Format-JkTime $_.Start.ToString('HH:mm')) $(Format-JkClassLabel $_.Class $cmap)$(if ($_.Class.room) { " ($($_.Class.room))" })" }) -join ', ')
    }
    foreach ($e in (@($soon | Select-Object -First 6) + $examsAhead)) {
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
        # the end of a window that has already opened: it can be written now
        $openNow = $false
        if ([string]$e.title -match '(?i)\s+closes?$') {
            $win = Get-JkEventWindow $e $data
            $openNow = [bool]($win -and $win.Opens -le $now)
        }
        if ($openNow -and $e.kind -ne 'exam') { $txt += ' (open now)' }
        if ($e.kind -eq 'exam') {
            $txt += $(if ($openNow) { ' (exam, open now)' } else { ' (exam)' })
            # where and what to bring: "in person, room TBA", "one handwritten sheet, no calculator",
            # "in class, MC 2017"
            $note = Get-JkExamPlace $e
            if ($note) { $txt += " $($script:G.dot) $note" }
        }
        # an opening is not a deadline: say until when the window runs. Closing the day it opens,
        # just the time; a week or more off, the date ("Mon Nov 16"), since a bare "Mon" reads as this one
        if ([string]$e.title -match '(?i)\s+opens?$') {
            $win = Get-JkEventWindow $e $data
            if ($win) {
                $until = Format-JkTime $win.Closes.ToString('HH:mm', $script:Inv)
                if ($win.Closes.Date -ne $win.Opens.Date) { $until = "$(Format-JkComingDay $win.Closes $now) $until" }
                $txt += ", open until $until"
            }
        }
        $lines += $txt
    }
    if ($soon.Count -gt 6) { $lines += "+$($soon.Count - 6) more" }
    # the day's weather rides along after what is due (never a reason for the popup on its own)
    try { $wx = Get-JkMorningWeather $now; if ($wx) { $lines += $wx } } catch { }
    if ($todos.Count) {
        $names = @($todos | Select-Object -First 3 | ForEach-Object {
                $td = Get-JkTodoDue $_
                $t = [string]$_.text
                if ($td.Date -lt $now.Date) { $t += " (overdue since $(Format-JkPastDay $td $now))" }
                elseif ($td.TimeOfDay.TotalMinutes -gt 0) { $t += " by $(Format-JkTime $td.ToString('HH:mm', $script:Inv))" }
                $t
            })
        $more = ''; if ($todos.Count -gt 3) { $more = ", +$($todos.Count - 3) more" }
        $lines += "To-do: $($names -join ', ')$more"
    }
    # today's study blocks ride along (they never trigger a popup on their own)
    try {
        if (-not $plan) { $plan = Get-JkPlanToday }
        if ($plan -and $plan.Today.Alloc.Count) {
            $byCourse = @{}
            foreach ($it in $plan.Items) { if ($plan.Today.Alloc.ContainsKey($it.Key)) { $byCourse[$it.Course] = [double]$byCourse[$it.Course] + $plan.Today.Alloc[$it.Key] } }
            $lines += 'Study today: ' + ((Get-JkPlanCourseOrder $plan $byCourse | ForEach-Object { "$(Get-JkCourseLabel ([pscustomobject]@{ course = $_ }) $cmap) $(Format-JkMinutes $byCourse[$_])" }) -join ', ')
        }
    } catch { }
    if ($soon.Count) {
        $accent = Get-JkCourseColor $soon[0].course $cmap
        # deadlines, not rows: a quiz window's opening is not one (its closing is)
        $nDue = (Measure-JkDue $soon).Due
        $title = "$(Format-JkCount $nDue 'deadline') in the next $([int]$Hours)h"
        if (-not $nDue) {
            # only an opening in the two days: "CS 341 Quiz 5 opens tomorrow 9:00 am"
            $o = $soon[0]; $od = Get-JkEventDue $o
            $title = "$(Get-JkCourseLabel $o $cmap) $($o.title) $(Format-JkRelDay $od $now)$(if ($o.time) { ' ' + (Format-JkTime $od.ToString('HH:mm', $script:Inv)) })"
        }
        # an exam today leads, in its course's colour
        $examTitle = Get-JkExamDayTitle $soon $cmap $now
        if ($examTitle) {
            $title = $examTitle
            $first = @($soon | Where-Object { $_.kind -eq 'exam' -and (Get-JkEventDue $_).Date -eq $now.Date })[0]
            $accent = Get-JkCourseColor $first.course $cmap
        } else {
            # an exam tomorrow or the day after leads too, in its course's colour
            $soonTitle = Get-JkExamSoonTitle $soon $cmap $now $data
            if ($soonTitle) {
                $title = $soonTitle
                $accent = Get-JkCourseColor (@($soon | Where-Object { $_.kind -eq 'exam' } | Sort-Object { Get-JkEventDue $_ })[0]).course $cmap
            }
        }
    } elseif ($examsAhead.Count) {
        # nothing in the next two days, an exam soon after: "CS 370 Midterm in 2 days (Mon 7:00 pm)"
        $x = $examsAhead[0]
        $xd = Get-JkEventDue $x
        $accent = Get-JkCourseColor $x.course $cmap
        $title = "$(Get-JkCourseLabel $x $cmap) $(([string]$x.title -replace '(?i)\s+(opens?|closes?)$', '').Trim()) in $([int]($xd.Date - $now.Date).TotalDays) days ($($xd.ToString('ddd', $script:Inv)) $(Format-JkTime $xd.ToString('HH:mm', $script:Inv)))"
    } elseif ($classes.Count) {
        $accent = Get-JkCourseColor $classes[0].Class.course $cmap
        $title = "$($classes.Count) class$(if ($classes.Count -ne 1) {'es'}) today, nothing due soon"
    } elseif ($studyDay -and -not $todos.Count) {
        # "Next exam: CS 350 FINAL Thu 4:00 pm (in 3 days)"
        $accent = $script:JkPalette.blue
        $title = 'Study day'
        if ($nextExam) {
            $xd = Get-JkEventDue $nextExam
            $accent = Get-JkCourseColor $nextExam.course $cmap
            $title = "Next exam: $(Get-JkCourseLabel $nextExam $cmap) $(([string]$nextExam.title -replace '(?i)\s+(opens?|closes?)$', '').Trim()) $($xd.ToString('ddd', $script:Inv)) $(Format-JkTime $xd.ToString('HH:mm', $script:Inv)) (in $(Format-JkCount ([int]($xd.Date - $now.Date).TotalDays) 'day'))"
        }
    } elseif ($movedNotes.Count -and -not $todos.Count) {
        $accent = $script:JkPalette.amber
        $title = "$(Format-JkCount $movedNotes.Count 'deadline') moved on LEARN"
    } elseif ($todos.Count) {
        $accent = $script:JkPalette.amber
        $title = "$(Format-JkCount $todos.Count 'to-do') due today"
        $late = @($todos | Where-Object { (Get-JkTodoDue $_).Date -lt $now.Date }).Count
        if ($late) { $title = "$(Format-JkCount $todos.Count 'to-do') due ($late overdue)" }
    } elseif ($wxWarn) {
        $accent = $script:JkPalette.cyan
        $title = $wxWarn
    } else {
        # a Sunday with nothing in the next two days: the week ahead is the news
        $accent = $script:JkPalette.blue
        $title = 'Nothing due in the next two days'
    }
    $cal = Get-JkPath 'calendar.html'
    if (-not (Test-Path -LiteralPath $cal)) { Export-JkDueHtml -NoOpen -Quiet }
    $mode = Show-JkNotify -Title $title -Lines $lines -Accent $accent -Open $cal -OpenLabel 'Open calendar' -Seconds 20 -Sound -Wait:$Quiet
    Set-JkState 'lastRemind' ($now.ToString('s', $script:Inv))
    if ($movedNotes.Count) { Set-JkState 'syncMoved' @() }
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
        '^(files|work)$' { Show-JkDueFiles @rest; return }
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
