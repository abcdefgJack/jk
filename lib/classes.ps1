# classes.ps1 - weekly class schedule: what's on today, the next class, a timetable grid.
#   jk class                                today's classes and the next one
#   jk class week                           Mon-Fri timetable
#   jk class add cs350 tue,thu 4pm-5:20pm "MC 1056" [-Kind TUT]
#   jk class import [file]                  Quest > Class Schedule > List View, copied (clipboard) or saved
# Meetings skip reading week and holidays taken from the term (deadlines.json).

$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:DayNames = @('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat')
$script:HolidayRx = '(?i)thanksgiving|holiday|good friday|victoria|canada day|civic|labou?r day|family day|truth and reconciliation|no class'

function Get-JkClassData {
    $d = Read-JkJson 'classes.json' $null
    if (-not $d) { $d = [pscustomobject]@{ nextId = 1; items = @() } }
    if ($null -eq (Get-JkProp $d 'items')) { Set-JkProp $d 'items' @() }
    if (-not (Get-JkProp $d 'nextId')) { Set-JkProp $d 'nextId' 1 }
    $d
}

function Save-JkClassData($Data) {
    $Data.items = @($Data.items)
    Save-JkJson 'classes.json' $Data
    Clear-JkBriefCache
}

# "tue thu", "tue,thu", "TTh", "MWF", "MTWThF", "mon/wed/fri", "weekdays" -> @('Tue','Thu')
function ConvertTo-JkDays([string]$Text) {
    $t = $Text.Trim()
    if ($t -match '^(?i)weekdays?$') { return @('Mon', 'Tue', 'Wed', 'Thu', 'Fri') }
    $days = @()
    if ($t -cmatch '^(Mo|Tu|We|Th|Fr|Sa|Su)+$') {
        # newer Quest style: MoWe, TuTh, Fr
        $map2 = @{ Mo = 'Mon'; Tu = 'Tue'; We = 'Wed'; Th = 'Thu'; Fr = 'Fri'; Sa = 'Sat'; Su = 'Sun' }
        foreach ($m in [regex]::Matches($t, 'Mo|Tu|We|Th|Fr|Sa|Su')) { $days += $map2[$m.Value] }
    } elseif ($t -cmatch '^(Th|Su|Sa|M|T|W|R|F|S|U)+$') {
        $map = @{ M = 'Mon'; T = 'Tue'; W = 'Wed'; Th = 'Thu'; R = 'Thu'; F = 'Fri'; S = 'Sat'; Sa = 'Sat'; Su = 'Sun'; U = 'Sun' }
        foreach ($m in [regex]::Matches($t, 'Th|Su|Sa|M|T|W|R|F|S|U')) { $days += $map[$m.Value] }
    } else {
        foreach ($p in ($t -split '[\s,/&+]+' | Where-Object { $_ })) {
            $k = $p.ToLower()
            if ($k.Length -lt 2) { throw "can't read the day '$p' (use mon, tue, ... or Quest style TTh / MWF)" }
            $hit = @('sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat') | Where-Object { $k.StartsWith($_) -or $_.StartsWith($k) }
            if (@($hit).Count -ne 1) { throw "can't read the day '$p'" }
            $days += (Get-Culture).TextInfo.ToTitleCase(@($hit)[0])
        }
    }
    if (-not $days) { throw "no days in '$Text'" }
    @($days | Select-Object -Unique)
}

# "4pm-5:20pm", "16:00-17:20", "10:00AM - 11:20AM", "4-5:20pm" -> start/end HH:mm
function ConvertTo-JkTimeRange([string]$Text) {
    $parts = @($Text -split '\s*(?:-|\p{Pd}|to)\s*' | Where-Object { $_ })
    if ($parts.Count -ne 2) { throw "can't read the time range '$Text' (try 4pm-5:20pm or 16:00-17:20)" }
    $a = $parts[0].Trim(); $b = $parts[1].Trim()
    $end = ConvertTo-JkTime $b
    if ($a -notmatch '(?i)[ap]m?$' -and $b -match '(?i)p') {
        # "4-5:20pm": the start shares the end's pm unless that would put it after the end
        $start = ConvertTo-JkTime "$a pm"
        if ($start -gt $end) { $start = ConvertTo-JkTime "$a am" }
    } else { $start = ConvertTo-JkTime $a }
    if ($start -ge $end) { throw "the class would end before it starts ('$Text')" }
    [pscustomobject]@{ Start = $start; End = $end }
}

function Get-JkTermSkipDays {
    $data = Get-JkDueData -Cached
    $skip = @{}
    $t = Get-JkProp $data 'term'
    if (-not $t) { return $skip }
    foreach ($b in @(Get-JkProp $t 'breaks' @())) {
        $d = [datetime]::ParseExact([string]$b.from, 'yyyy-MM-dd', $script:Inv)
        $to = [datetime]::ParseExact([string]$b.to, 'yyyy-MM-dd', $script:Inv)
        while ($d -le $to) { $skip[$d.ToString('yyyy-MM-dd')] = [string](Get-JkProp $b 'name' 'Break'); $d = $d.AddDays(1) }
    }
    foreach ($m in @(Get-JkProp $t 'marks' @())) { if ([string]$m.name -match $script:HolidayRx) { $skip[[string]$m.date] = [string]$m.name } }
    $skip
}

function Get-JkClassRange($Class) {
    $data = Get-JkDueData -Cached
    $t = Get-JkProp $data 'term'
    $from = [string](Get-JkProp $Class 'from')
    $to = [string](Get-JkProp $Class 'to')
    if (-not $from -and $t) { $from = [string]$t.start }
    if (-not $to -and $t) { $to = [string](Get-JkProp $t 'classesEnd') }
    $f = [datetime]::MinValue; $e = [datetime]::MaxValue
    if ($from) { $f = [datetime]::ParseExact($from, 'yyyy-MM-dd', $script:Inv) }
    if ($to) { $e = [datetime]::ParseExact($to, 'yyyy-MM-dd', $script:Inv) }
    , @($f, $e)
}

# Every meeting on one date, as objects with Start/End datetimes, sorted by time.
function Get-JkClassesOn([datetime]$Date, $Data = (Get-JkClassData), $Skip = (Get-JkTermSkipDays)) {
    $day = $Date.Date
    $key = $day.ToString('yyyy-MM-dd')
    if ($Skip.ContainsKey($key)) { return @() }
    $dow = $script:DayNames[[int]$day.DayOfWeek]
    $out = foreach ($c in @($Data.items)) {
        if (@($c.days) -notcontains $dow) { continue }
        $r = Get-JkClassRange $c
        if ($day -lt $r[0] -or $day -gt $r[1]) { continue }
        $s = ([string]$c.start).Split(':'); $e = ([string]$c.end).Split(':')
        [pscustomobject]@{ Class = $c; Start = $day.AddHours([int]$s[0]).AddMinutes([int]$s[1]); End = $day.AddHours([int]$e[0]).AddMinutes([int]$e[1]) }
    }
    @($out | Sort-Object Start)
}

function Get-JkNextClass([datetime]$Now = (Get-JkNow), [int]$LookAheadDays = 21) {
    $data = Get-JkClassData
    if (@($data.items).Count -eq 0) { return $null }
    $skip = Get-JkTermSkipDays
    for ($i = 0; $i -le $LookAheadDays; $i++) {
        foreach ($m in (Get-JkClassesOn $Now.Date.AddDays($i) $data $skip)) { if ($m.End -gt $Now) { return $m } }
    }
    $null
}

function Format-JkClassLabel($Class, $cmap) {
    $code = [string]$Class.course
    $c = $cmap[[string]$Class.course]
    if ($c) { $code = [string]$c.code }
    $kind = [string]$Class.kind
    if ($kind) { "$code $kind" } else { $code }
}

# 8:30-9:50 am / 11:30 am-12:20 pm
function Format-JkTimeSpan([datetime]$Start, [datetime]$End) {
    $a = Format-JkTime $Start.ToString('HH:mm'); $b = Format-JkTime $End.ToString('HH:mm')
    if ($a.Substring($a.Length - 2) -eq $b.Substring($b.Length - 2)) { $a = $a.Substring(0, $a.Length - 3) }
    "$a-$b"
}

# "now, ends 9:50 am" / "in 25m" / "tomorrow 8:30 am" for a meeting relative to now
function Get-JkClassWhen($Meeting, [datetime]$Now) {
    if ($Meeting.Start -le $Now -and $Meeting.End -gt $Now) { return @("now $($script:G.dot) ends $(Format-JkTime $Meeting.End.ToString('HH:mm'))", 'bold green') }
    $span = $Meeting.Start - $Now
    if ($Meeting.Start.Date -eq $Now.Date) {
        $st = 'white'; if ($span.TotalMinutes -le 15) { $st = 'bold orange' } elseif ($span.TotalMinutes -le 60) { $st = 'yellow' }
        return @("in $(Format-JkDuration $span)", $st)
    }
    $at = Format-JkTime $Meeting.Start.ToString('HH:mm')
    if (($Meeting.Start.Date - $Now.Date).TotalDays -eq 1) { return @("tomorrow $at", 'muted') }
    @("$($Meeting.Start.ToString('ddd', $script:Inv)) $at ($(Format-JkRelDay $Meeting.Start $Now))", 'muted')
}

function Show-JkClasses {
    $data = Get-JkClassData
    $now = Get-JkNow
    $due = Get-JkDueData
    $cmap = Get-JkCourseMap $due
    $skip = Get-JkTermSkipDays
    Write-JkHeader 'Classes' "$(@($data.items).Count) weekly meeting$(if (@($data.items).Count -ne 1) {'s'})" -Sub ($now.ToString('dddd, MMM d', $script:Inv))
    if (@($data.items).Count -eq 0) {
        Say (Paint 'yellow' '  No classes yet.')
        Say ('  ' + (Paint 'cyan' 'jk class add cs350 tue,thu 4pm-5:20pm "MC 1056"') + (Paint 'gray' '   or copy Quest > Class Schedule > List View, then: jk class import'))
        return
    }
    $todayKey = $now.Date.ToString('yyyy-MM-dd')
    $today = @(Get-JkClassesOn $now.Date $data $skip)
    if ($skip.ContainsKey($todayKey)) { Say ('  ' + (Paint 'green' "No classes today $($script:G.dash) $($skip[$todayKey]).")) }
    elseif ($today.Count -eq 0) { Say (Paint 'green' '  No classes today.') }
    foreach ($m in $today) {
        $when = Get-JkClassWhen $m $now
        $color = Get-JkCourseColor $m.Class.course $cmap
        $time = (Format-JkTime $m.Start.ToString('HH:mm')) + ' ' + $script:G.dash + ' ' + (Format-JkTime $m.End.ToString('HH:mm'))
        $line = '  ' + (Paint 'muted' (Fit $time 22)) + (Paint "bold #$color" (Fit (Format-JkClassLabel $m.Class $cmap) 16)) + (Paint 'white' (Fit ([string]$m.Class.room) 14))
        if ($m.End -le $now) { $line = Paint 'gray' ($line -replace "$([char]27)\[[0-9;]*m", '') ; $line += Paint 'gray' 'done' }
        else { $line += Paint $when[1] $when[0] }
        Say $line
    }
    $next = Get-JkNextClass $now
    if ($next -and $next.Start.Date -ne $now.Date) {
        $when = Get-JkClassWhen $next $now
        Say ''
        Say ('  ' + (Paint 'gray' 'next: ') + (Paint "bold #$(Get-JkCourseColor $next.Class.course $cmap)" (Format-JkClassLabel $next.Class $cmap)) + '  ' + (Paint 'muted' $when[0]) + (Paint 'gray' "  $($next.Class.room)"))
    }
    Say ''
    Say (Paint 'gray' "  jk class week  $($script:G.dot)  jk class list  $($script:G.dot)  jk class add  $($script:G.dot)  jk class import")
}

function Show-JkTimetable {
    param([string]$Date, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra)
    $left = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($Extra)) { if ($x) { $left.Add([string]$x) } }
    if (-not $Date -and $left.Count) { $Date = $left[0]; $left.RemoveAt(0) }
    $Date = Join-JkLooseDate $Date $left
    $data = Get-JkClassData
    $now = Get-JkNow
    $ref = $now.Date
    if ($Date) { $ref = ConvertTo-JkDate $Date }
    $monday = $ref.AddDays(-(([int]$ref.DayOfWeek + 6) % 7))
    $cmap = Get-JkCourseMap (Get-JkDueData)
    $skip = Get-JkTermSkipDays
    $w = Get-JkWidth
    $days = 5
    if (@($data.items | Where-Object { @($_.days) -contains 'Sat' -or @($_.days) -contains 'Sun' }).Count) { $days = 7 }
    $colW = [Math]::Max(12, [int][Math]::Floor(($w - 2) / $days))
    Write-JkHeader 'Timetable' "week of $($monday.ToString('MMM d', $script:Inv))"
    $head = ' '
    $cols = @()
    for ($i = 0; $i -lt $days; $i++) {
        $d = $monday.AddDays($i)
        $st = 'bold muted'
        if ($d -eq $now.Date) { $st = 'bold bg:white ink' }
        $head += (Paint $st (Fit ($d.ToString('ddd MMM d', $script:Inv)) ($colW - 1))) + ' '
        $cols += , @(Get-JkClassesOn $d $data $skip)
    }
    Say $head
    $rows = ($cols | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
    if (-not $rows) {
        Say (Paint 'gray' '  (no classes this week)')
    }
    for ($r = 0; $r -lt $rows; $r++) {
        foreach ($part in 'time', 'name', 'room') {
            $line = ' '
            for ($i = 0; $i -lt $days; $i++) {
                $list = $cols[$i]
                if ($r -lt $list.Count) {
                    $m = $list[$r]
                    $color = Get-JkCourseColor $m.Class.course $cmap
                    $past = $m.End -lt $now
                    switch ($part) {
                        'time' { $txt = Format-JkTimeSpan $m.Start $m.End; $st = 'muted' }
                        'name' { $txt = (Format-JkClassLabel $m.Class $cmap); $st = "bold #$color" }
                        'room' { $txt = [string]$m.Class.room; $st = 'gray' }
                    }
                    if ($past) { $st = 'gray dim' }
                    $line += (Paint $st (Fit $txt ($colW - 1))) + ' '
                } else { $line += ' ' * $colW }
            }
            Say $line
        }
        Say ''
    }
    for ($i = 0; $i -lt $days; $i++) {
        $k = $monday.AddDays($i).ToString('yyyy-MM-dd')
        if ($skip.ContainsKey($k)) { Say (Paint 'gray' "  $($monday.AddDays($i).ToString('ddd', $script:Inv)): $($skip[$k]) (no classes)") }
    }
}

function Show-JkClassList {
    $data = Get-JkClassData
    $cmap = Get-JkCourseMap (Get-JkDueData)
    Write-JkHeader 'Weekly meetings' "$(@($data.items).Count) total"
    $order = @{ Mon = 1; Tue = 2; Wed = 3; Thu = 4; Fri = 5; Sat = 6; Sun = 7 }
    foreach ($c in @($data.items | Sort-Object course, { $order[@($_.days)[0]] }, start)) {
        $color = Get-JkCourseColor $c.course $cmap
        $r = Get-JkClassRange $c
        $range = ''
        if ($r[0] -ne [datetime]::MinValue) { $range = $r[0].ToString('MMM d', $script:Inv) + ' ' + $script:G.dash + ' ' + $r[1].ToString('MMM d', $script:Inv) }
        Say ('  ' + (Paint 'gray' ("#$($c.id)".PadLeft(4))) + '  ' + (Paint "bold #$color" (Fit (Format-JkClassLabel $c $cmap) 16)) + (Paint 'white' (Fit ((@($c.days) -join ' ')) 16)) + (Paint 'muted' (Fit ((Format-JkTime $c.start) + ' ' + $script:G.dash + ' ' + (Format-JkTime $c.end)) 22)) + (Paint 'white' (Fit ([string]$c.room) 14)) + (Paint 'gray' $range))
    }
}

function Add-JkClass {
    param(
        [Parameter(Position = 0)][string]$Course,
        [Parameter(Position = 1)][string[]]$Days,   # tue,thu arrives as an array
        [Parameter(Position = 2)][string]$Time,
        [Parameter(Position = 3)][string]$Room = '',
        [string]$Kind = 'LEC',
        [string]$From,
        [string]$To,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra
    )
    $left = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($Extra)) { if ($x) { $left.Add([string]$x) } }
    $From = Join-JkLooseDate $From $left
    $To = Join-JkLooseDate $To $left
    if ($left.Count) { throw "unexpected words: $($left -join ' ') (quote a room with spaces: 'MC 1056')" }
    if (-not $Course -or -not $Days -or -not $Time) { throw 'usage: jk class add <course> <days> <start-end> ["room"] [-Kind LEC|TUT|LAB] [-From sep 8] [-To dec 8]' }
    $due = Get-JkDueData
    $c = Resolve-JkCourse $due $Course -Create
    if (-not (Resolve-JkCourse (Get-JkDueData) $Course)) { Save-JkDueData $due }
    $range = ConvertTo-JkTimeRange $Time
    $d = Get-JkClassData
    $item = [pscustomobject][ordered]@{
        id     = [int]$d.nextId
        course = $c.key
        kind   = $Kind.ToUpper()
        days   = @(ConvertTo-JkDays ($Days -join ','))
        start  = $range.Start
        end    = $range.End
        room   = $Room
        from   = $(if ($From) { (ConvertTo-JkDate $From).ToString('yyyy-MM-dd', $script:Inv) } else { '' })
        to     = $(if ($To) { (ConvertTo-JkDate $To).ToString('yyyy-MM-dd', $script:Inv) } else { '' })
    }
    $d.nextId = [int]$d.nextId + 1
    $d.items = @($d.items) + $item
    Save-JkClassData $d
    Say ((Paint 'green' "  added $($script:G.check)") + "  #$($item.id) $($c.code) $($item.kind)  $(@($item.days) -join ' ')  $(Format-JkTime $item.start) $($script:G.dash) $(Format-JkTime $item.end)  $Room")
}

function Remove-JkClass {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Ids)
    if (-not $Ids) { throw 'usage: jk class rm <id> [...]   (ids: jk class list)' }
    $d = Get-JkClassData
    $nums = @($Ids | ForEach-Object { [int]($_.TrimStart('#')) })
    $gone = @($d.items | Where-Object { $nums -contains [int]$_.id })
    if (-not $gone) { throw "no class with id $($Ids -join ', ')" }
    $d.items = @($d.items | Where-Object { $nums -notcontains [int]$_.id })
    Save-JkClassData $d
    foreach ($g in $gone) { Say ((Paint 'red' '  removed') + "  #$($g.id) $($g.course) $($g.kind) $(@($g.days) -join ' ') $($g.start)") }
}

# Parses the text of Quest's Class Schedule "List View" (copy the page, or save it as .txt):
#   CS 341 - Algorithms
#   ...
#   5678   001   LEC   TTh 10:00AM - 11:20AM   MC 2065   Some Prof   09/08/2026 - 12/08/2026
# Rows with a blank class number continue the section above. TST rows (midterms) become exams.
function ConvertFrom-JkQuestText([string]$Text) {
    $classes = @(); $tests = @()
    $course = $null; $component = $null
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.TrimEnd()
        # outline.uwaterloo.ca schedule row: STAT 341 002 [LEC] Monday, Wednesday - 02:30PM - 03:50PM EIT 1015 ...
        $om = [regex]::Match($line, '(?<subj>[A-Z]{2,8})\s+(?<num>\d{3}[A-Z]?)\s+\d{3}\s+\[(?<kind>[A-Z]{3})\]\s+(?<days>(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*(?:\s*,\s*(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*)*)\s*-\s*(?<s>\d{1,2}:\d{2}\s*(?i:[AP]M))\s*-\s*(?<e>\d{1,2}:\d{2}\s*(?i:[AP]M))\s*(?<room>[A-Z0-9]{2,5}\s+\d{3,4}[A-Z]?)?')
        if ($om.Success) {
            $classes += [pscustomobject]@{
                Course = "$($om.Groups['subj'].Value) $($om.Groups['num'].Value)"; Kind = $om.Groups['kind'].Value
                Days = @(ConvertTo-JkDays ($om.Groups['days'].Value -replace '\s', ''))
                Start = ConvertTo-JkTime ($om.Groups['s'].Value -replace '\s', ''); End = ConvertTo-JkTime ($om.Groups['e'].Value -replace '\s', '')
                Room = $om.Groups['room'].Value; From = ''; To = ''
            }
            continue
        }
        if ($line -match '^\s*([A-Z]{2,8})\s+(\d{3}[A-Z]?)\s+-\s+(.+?)\s*$') { $course = "$($Matches[1]) $($Matches[2])"; continue }
        if (-not $course) { continue }
        $cm = [regex]::Match($line, '\b(LEC|TUT|LAB|SEM|TST|PRJ|DIS|STU|CLN|ORL|RDG|WRK)\b')
        if ($cm.Success) { $component = $cm.Value }
        # day codes are case-sensitive (TTh, MWF); AM/PM is not
        $tm = [regex]::Match($line, '\b((?:Mo|Tu|We|Th|Fr|Sa|Su|M|T|W|F|S)+)\s+(\d{1,2}:\d{2}\s*(?i:[AP]M))\s*-\s*(\d{1,2}:\d{2}\s*(?i:[AP]M))')
        if (-not $tm.Success -or -not $component) { continue }
        $after = $line.Substring($tm.Index + $tm.Length)
        $cells = @($after -split "`t|\s{2,}" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $room = ''
        if ($cells.Count) { $room = $cells[0] }
        $dates = [regex]::Matches($after, '(\d{2})/(\d{2})/(\d{4})')
        $from = ''; $to = ''
        if ($dates.Count -ge 1) { $from = '{0}-{1}-{2}' -f $dates[0].Groups[3].Value, $dates[0].Groups[1].Value, $dates[0].Groups[2].Value }
        if ($dates.Count -ge 2) { $to = '{0}-{1}-{2}' -f $dates[1].Groups[3].Value, $dates[1].Groups[1].Value, $dates[1].Groups[2].Value }
        $start = ConvertTo-JkTime ($tm.Groups[2].Value -replace '\s', '')
        $end = ConvertTo-JkTime ($tm.Groups[3].Value -replace '\s', '')
        if ($component -eq 'TST' -and $from -and $from -eq $to) {
            $tests += [pscustomobject]@{ Course = $course; Date = $from; Start = $start; End = $end; Room = $room }
            continue
        }
        $classes += [pscustomobject]@{ Course = $course; Kind = $component; Days = @(ConvertTo-JkDays $tm.Groups[1].Value); Start = $start; End = $end; Room = $room; From = $from; To = $to }
    }
    [pscustomobject]@{ Classes = $classes; Tests = $tests }
}

function Import-JkClasses {
    param([Parameter(Position = 0)][string]$Path, [switch]$Replace)
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path)) { throw "no such file: $Path" }
        $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath)
    }
    else { $text = Get-JkClipboardText }
    $parsed = ConvertFrom-JkQuestText $text
    if (@($parsed.Classes).Count -eq 0 -and @($parsed.Tests).Count -eq 0) {
        throw "found no class meetings. In Quest open Class Schedule, choose List View, select all (Ctrl+A), copy, then run: jk class import"
    }
    $d = Get-JkClassData
    if ($Replace) { $d.items = @(); $d.nextId = 1 }
    $due = Get-JkDueData
    $added = 0; $skipped = 0
    foreach ($c in $parsed.Classes) {
        $course = Resolve-JkCourse $due $c.Course -Create
        $dup = @($d.items | Where-Object { $_.course -eq $course.key -and $_.kind -eq $c.Kind -and $_.start -eq $c.Start -and ((@($_.days) -join ',') -eq (@($c.Days) -join ',')) })
        if ($dup) { $skipped++; continue }
        $d.items = @($d.items) + [pscustomobject][ordered]@{ id = [int]$d.nextId; course = $course.key; kind = $c.Kind; days = @($c.Days); start = $c.Start; end = $c.End; room = $c.Room; from = $c.From; to = $c.To }
        $d.nextId = [int]$d.nextId + 1
        $added++
    }
    $tests = 0
    foreach ($t in $parsed.Tests) {
        $course = Resolve-JkCourse $due $t.Course -Create
        $date = [datetime]::ParseExact($t.Date, 'yyyy-MM-dd', $script:Inv)
        $exists = @($due.events | Where-Object { $_.course -eq $course.key -and $_.date -eq $t.Date -and $_.kind -eq 'exam' })
        if ($exists) {
            # fill in the time/room the calendar did not know yet
            foreach ($e in $exists) { if (-not $e.time) { $e.time = $t.Start; Set-JkProp $e 'end' $t.End }; if ($t.Room -and [string]$e.note -notmatch [regex]::Escape($t.Room)) { $e.note = (([string]$e.note + " $($script:G.dot) $($t.Room)").Trim(" $($script:G.dot)")) } }
        } else {
            $null = New-JkEvent -Data $due -Course $course.key -Date $date -Time $t.Start -End $t.End -Title 'Test (from Quest)' -Note $t.Room -Kind 'exam'
        }
        $tests++
    }
    Save-JkDueData $due
    Save-JkClassData $d
    Say ((Paint 'green' "  imported $($script:G.check)") + "  $added weekly meetings" + $(if ($skipped) { " ($skipped already there)" } else { '' }) + $(if ($tests) { ", $tests test slots merged into deadlines" } else { '' }))
    # a whole outline table has every section; you are only in one lecture per course
    $multi = @($d.items | Group-Object { "$($_.course)|$($_.kind)" } | Where-Object { $_.Count -gt 1 -and ($_.Name -like '*|LEC') })
    $cmap = Get-JkCourseMap (Get-JkDueData)
    foreach ($g in $multi) {
        $ids = ($g.Group | ForEach-Object { "#$($_.id)" }) -join ' '
        $code = Format-JkClassLabel ([pscustomobject]@{ course = $g.Group[0].course; kind = '' }) $cmap
        Say ('  ' + (Paint 'yellow' "! $($g.Count) lecture sections for $code") + (Paint 'gray' " ($ids) - keep yours: jk class rm <id>  (jk class list shows times and rooms)"))
    }
}

function Invoke-JkClass {
    $a = @($args)
    if ($a.Count -eq 0) { Show-JkClasses; return }
    $first = ([string]$a[0]).ToLower()
    $rest = @()
    if ($a.Count -gt 1) { $rest = @($a[1..($a.Count - 1)]) }
    switch -Regex ($first) {
        '^(week|wk|grid|timetable)$' { Show-JkTimetable @rest; return }
        '^(list|ls|all)$' { Show-JkClassList; return }
        '^(add|new|\+)$' { Add-JkClass @rest; return }
        '^(rm|remove|del|delete)$' { Remove-JkClass @rest; return }
        '^(import|quest)$' { Import-JkClasses @rest; return }
        '^(next)$' {
            $n = Get-JkNextClass
            if (-not $n) { Say (Paint 'gray' '  no upcoming classes'); return }
            $cmap = Get-JkCourseMap (Get-JkDueData)
            $w = Get-JkClassWhen $n (Get-JkNow)
            Say ('  ' + (Paint "bold #$(Get-JkCourseColor $n.Class.course $cmap)" (Format-JkClassLabel $n.Class $cmap)) + '  ' + (Paint $w[1] $w[0]) + (Paint 'gray' "  $($n.Class.room)"))
            return
        }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'class'; return }
    }
    throw "unknown 'class' action '$first' (try: jk class help)"
}
