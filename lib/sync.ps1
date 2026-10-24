# sync.ps1 - jk due sync: keep deadlines current from a calendar feed.
#   jk due sync <url>     first time: LEARN > Calendar > Subscribe gives a private .ics link
#   jk due sync           again later (the link is remembered; the morning task also runs it)
#   jk due sync file.ics  any exported calendar file
# Items are matched by the feed's UID (or by course + date + title the first time), so a
# re-sync updates moved dates instead of duplicating; done marks, weights and notes are kept.

$script:Inv = [Globalization.CultureInfo]::InvariantCulture

# One pass, left to right: "\\n" is a backslash and an n, not a newline.
function ConvertFrom-JkIcsText([string]$s) {
    if ($null -eq $s) { return '' }
    [regex]::Replace($s, '\\([\\;,nN])', { param($m) if ($m.Groups[1].Value -match '^[nN]$') { "`n" } else { $m.Groups[1].Value } })
}

# Returns @{ When = <local datetime>; AllDay = <bool> } for a DTSTART/DTEND value.
function ConvertFrom-JkIcsDate([string]$Value, [string]$Params) {
    $v = $Value.Trim()
    if ($Params -match '(?i)VALUE=DATE(?!-)' -or $v -match '^\d{8}$') {
        return @{ When = [datetime]::ParseExact($v.Substring(0, 8), 'yyyyMMdd', $script:Inv); AllDay = $true }
    }
    if ($v -match '^\d{8}T\d{6}Z$') {
        $utc = [datetime]::ParseExact($v, "yyyyMMdd'T'HHmmss'Z'", $script:Inv, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
        return @{ When = $utc.ToLocalTime(); AllDay = $false }
    }
    if ($v -match '^\d{8}T\d{4,6}$') {
        $fmt = "yyyyMMdd'T'HHmmss"; if ($v.Length -eq 13) { $fmt = "yyyyMMdd'T'HHmm" }
        $t = [datetime]::ParseExact($v, $fmt, $script:Inv)
        $tz = [regex]::Match($Params, '(?i)TZID="?([^;":]+)').Groups[1].Value
        if ($tz) {
            # IANA names the feeds use -> Windows zones; anything unknown is taken as local time
            $map = @{ 'America/Toronto' = 'Eastern Standard Time'; 'America/New_York' = 'Eastern Standard Time'; 'America/Chicago' = 'Central Standard Time'; 'America/Denver' = 'Mountain Standard Time'; 'America/Vancouver' = 'Pacific Standard Time'; 'America/Los_Angeles' = 'Pacific Standard Time'; 'UTC' = 'UTC'; 'Etc/UTC' = 'UTC' }
            $win = $map[$tz]; if (-not $win) { $win = $tz }
            try {
                $zone = [TimeZoneInfo]::FindSystemTimeZoneById($win)
                $t = [TimeZoneInfo]::ConvertTime([datetime]::SpecifyKind($t, 'Unspecified'), $zone, [TimeZoneInfo]::Local)
            } catch { }
        }
        return @{ When = $t; AllDay = $false }
    }
    throw "unreadable calendar date '$Value'"
}

# Parses VEVENTs (alarms inside an event are skipped so their DESCRIPTION cannot leak in).
function ConvertFrom-JkIcs([string]$Text) {
    $unfolded = [regex]::Replace($Text, '\r?\n[ \t]', '')
    $events = New-Object System.Collections.Generic.List[object]
    $cur = $null; $depth = 0
    foreach ($line in ($unfolded -split '\r?\n')) {
        if ($line -eq 'BEGIN:VEVENT') { $cur = @{ Summary = ''; Description = ''; Location = ''; Categories = ''; Uid = ''; Start = $null; End = $null; Recurring = $false }; $depth = 0; continue }
        if ($null -eq $cur) { continue }
        if ($line -eq 'END:VEVENT') { if ($cur.Start) { $events.Add([pscustomobject]$cur) }; $cur = $null; continue }
        if ($line -match '^BEGIN:') { $depth++; continue }
        if ($line -match '^END:') { $depth--; continue }
        if ($depth -gt 0) { continue }
        $m = [regex]::Match($line, '^([A-Za-z-]+)((?:;[^:]*)?):(.*)$')
        if (-not $m.Success) { continue }
        $value = $m.Groups[3].Value
        switch ($m.Groups[1].Value.ToUpper()) {
            'SUMMARY' { $cur.Summary = ConvertFrom-JkIcsText $value }
            'DESCRIPTION' { $cur.Description = ConvertFrom-JkIcsText $value }
            'LOCATION' { $cur.Location = ConvertFrom-JkIcsText $value }
            'CATEGORIES' { $cur.Categories = ConvertFrom-JkIcsText $value }
            'UID' { $cur.Uid = $value.Trim() }
            'RRULE' { $cur.Recurring = $true }
            'DTSTART' { $cur.Start = ConvertFrom-JkIcsDate $value $m.Groups[2].Value }
            'DTEND' { $cur.End = ConvertFrom-JkIcsDate $value $m.Groups[2].Value }
        }
    }
    $events
}

# Course code from the event text: prefers codes already known to jk. A new course is only
# made from the title, the categories, or a code that opens the description (LEARN writes
# "CS 350 - Operating Systems (Fall 2026)" there); a code mentioned further on ("LEC 001",
# "AFM 425 students write at 4:30") must not invent one.
function Find-JkIcsCourse($Item, $Data) {
    $rx = '\b([A-Z]{2,6})[ -]?(\d{3}[A-Z]?)\b'
    $codesIn = { param($t) [regex]::Matches($t, $rx) | Where-Object { $_.Groups[1].Value -notmatch '^(LEC|LAB|TUT|SEM|SEC|TST|ROOM|RM)$' } | ForEach-Object { "$($_.Groups[1].Value) $($_.Groups[2].Value)" } | Select-Object -Unique }
    $all = @(& $codesIn "$($Item.Summary) | $($Item.Categories) | $($Item.Location) | $($Item.Description)")
    foreach ($c in $all) { $hit = Resolve-JkCourse $Data $c; if ($hit) { return $hit } }
    $lead = ''
    if ([string]$Item.Description -match '^\s*([A-Z]{2,6}[ -]?\d{3}[A-Z]?)\b') { $lead = $Matches[1] }
    $own = @(& $codesIn "$($Item.Summary) | $($Item.Categories) | $lead")
    if ($own.Count) { return (Resolve-JkCourse $Data $own[0] -Create) }
    $null
}

# "CS 350: Assignment 2 - Due" -> Assignment 2; "Due: CS 350 A2A (8%)" (jk's own export) -> A2A + 8%
function Get-JkIcsTitle([string]$Summary, [string]$CourseCode) {
    $t = $Summary
    $weight = ''
    $wm = [regex]::Match($t, '\s*\((\d+(?:\.\d+)?)%\)\s*$')
    if ($wm.Success) { $weight = $wm.Groups[1].Value + '%'; $t = $t.Substring(0, $wm.Index) }
    $t = [regex]::Replace($t, '^(?i)(due|exam|appt)\s*:\s*', '')
    if ($CourseCode) {
        $pat = [regex]::Escape($CourseCode).Replace('\ ', '[ -]?')
        $t = [regex]::Replace($t, "(?i)\b$pat\b\s*[:\-|]*\s*", '')
    }
    # LEARN's own labels: "Assignment 2 Dropbox - Due", "Midterm 1 - Availability Ends", ...
    for ($i = 0; $i -lt 3; $i++) {
        $t = [regex]::Replace($t, '(?i)\s*[-:]\s*(due|due date|availability ends|end date|deadline)\s*$', '')
        $t = [regex]::Replace($t, '(?i)\s+(dropbox|submission folder|assignment folder|submission)\s*$', '')
    }
    $t = $t.Trim(' ', '-', ':', '|')
    if (-not $t) { $t = $Summary.Trim() }
    [pscustomobject]@{ Title = $t; Weight = $weight }
}

# A calendar-feed link in some text (the clipboard, a paste): webcal://, or http(s) to an .ics or
# a calendar/feed path such as LEARN's /d2l/le/calendar/feed/... Returns the link or $null.
# What a title is about, for matching a feed item to one typed in by hand: "Assignment 3 closes",
# "Assignment 3 Dropbox" and "Assignment 3" all give "assignment3".
function Get-JkTitleKey([string]$Title) {
    $t = [regex]::Replace($Title, '(?i)\b(dropbox|submission folder|assignment folder|submission|availability (starts|ends)|opens?|closes?|due( date)?|deadline)\b', ' ')
    ($t -replace '[^\p{L}\p{Nd}]', '').ToLower()
}

function Find-JkFeedLink([string]$Text) {
    $t = ([string]$Text).Trim().Trim('"', "'", '<', '>')
    if ($t -notmatch '^(?i)(https?|webcal)://\S+$') { return $null }
    if ($t -match '^(?i)webcal://' -or $t -match '(?i)\.ics(\?|$)|/calendar|/ical|/feed') { return $t }
    $null
}

function Invoke-JkDueSync {
    param([Parameter(Position = 0)][string]$Source, [switch]$Quiet, [int]$PastDays = 7, [int]$AheadDays = 200)
    $saved = Get-JkConfig 'sync.url'
    if (-not $Source) { $Source = $saved }
    if (-not $Source -and -not $Quiet -and (Test-JkInteractive)) {
        # first time: the link was most likely just copied from LEARN, so offer the clipboard
        # (after a yes: it becomes the feed the morning task syncs every day), else ask for a paste
        $clip = $null
        try { $clip = Find-JkFeedLink ([string](Get-Clipboard -Raw -ErrorAction Stop)) } catch { }
        if ($clip) {
            $hostName = ([Uri]($clip -replace '^(?i)webcal://', 'https://')).Host
            $ans = [string](Read-Host "  Use the calendar link on your clipboard ($hostName)? [Y/n]")
            if ($ans.Trim() -match '^(|y|yes)$') { $Source = $clip }
        }
        if (-not $Source) {
            Say (Paint 'gray' '  In LEARN open Calendar > Subscribe and copy the link.')
            $pasted = [string](Read-Host '  Paste it here (Enter to cancel)')
            if ($pasted.Trim()) {
                $Source = Find-JkFeedLink $pasted
                if (-not $Source) { throw "that is not a calendar link (expected webcal:// or an https link to the feed)" }
            }
        }
    }
    if (-not $Source) {
        throw 'no calendar feed yet. In LEARN open Calendar > Subscribe, copy the link, then run: jk due sync "<link>"'
    }
    $isUrl = $Source -match '^(?i)(https?|webcal)://'
    if ($isUrl) {
        $url = $Source -replace '^(?i)webcal://', 'https://'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        # decode the raw bytes as UTF-8 (calendar feeds are UTF-8; PS 5.1 may guess ISO-8859-1)
        $text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    } else {
        if (-not (Test-Path -LiteralPath $Source)) { throw "no such file: $Source" }
        $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Source).ProviderPath)
    }
    if ($text -notmatch 'BEGIN:VCALENDAR') { throw 'that does not look like a calendar feed (.ics)' }
    $feed = @(ConvertFrom-JkIcs $text)
    $now = Get-JkNow
    $from = $now.Date.AddDays(-$PastDays); $to = $now.Date.AddDays($AheadDays)
    $data = Get-JkDueData
    $added = @(); $updated = 0; $same = 0; $skipped = 0
    foreach ($ev in $feed) {
        $when = $ev.Start.When
        if ($ev.End -and -not $ev.Start.AllDay -and -not $ev.End.AllDay) {
            # a deadline is the end of a short slot ("due 11:59 pm" events are often 11:29-11:59);
            # longer slots (exams) start when they start
            $mins = ($ev.End.When - $when).TotalMinutes
            if ($mins -ge 0 -and ($mins -le 30 -or ($mins -le 60 -and $ev.Summary -match '(?i)\bdue\b'))) { $when = $ev.End.When }
        }
        if ($when -lt $from -or $when -gt $to) { $skipped++; continue }
        # weekly class meetings and "availability starts" markers are not deadlines
        if ($ev.Recurring -or $ev.Summary -match '(?i)availability starts|start date|\bopens?\s*$') { $skipped++; continue }
        $course = Find-JkIcsCourse $ev $data
        $courseKey = 'other'; $code = ''
        if ($course) { $courseKey = $course.key; $code = [string]$course.code }
        else { $null = Resolve-JkCourse $data 'other' -Create }
        $parsed = Get-JkIcsTitle $ev.Summary $code
        $title = $parsed.Title
        $date = $when.Date.ToString('yyyy-MM-dd', $script:Inv)
        $time = ''; if (-not $ev.Start.AllDay) { $time = $when.ToString('HH:mm', $script:Inv) }
        $kind = 'due'
        if ($title -match '(?i)\b(midterm|exam|final|test|quiz)\b' -and $title -notmatch '(?i)\bfinal\s+(project|report|paper|presentation|essay|submission)\b' -and $ev.Summary -notmatch '^(?i)due\s*:') { $kind = 'exam' }
        $uid = [string]$ev.Uid
        $hit = $null
        if ($uid) { $hit = @($data.events | Where-Object { [string](Get-JkProp $_ 'uid') -eq $uid })[0] }
        $kept = $false
        if (-not $hit) {
            # first sync: link to the item typed in by hand (same course and day, same subject
            # once LEARN's "Dropbox" / "Availability Ends" and your "opens" / "closes" are set aside)
            $key = Get-JkTitleKey $title
            $hit = @($data.events | Where-Object { $_.course -eq $courseKey -and $_.date -eq $date -and -not (Get-JkProp $_ 'uid') -and (Get-JkTitleKey ([string]$_.title)) -eq $key })[0]
            # your title, weight and notes stay: only the date and time follow the feed from now on
            if ($hit -and ([string]$hit.title -replace '[^\p{L}\p{Nd}]', '').ToLower() -ne ($title -replace '[^\p{L}\p{Nd}]', '').ToLower()) { $kept = $true }
        }
        # what the feed said, kept on the item: your own edits stay put until the feed itself changes
        $src = "$date|$time|$title"
        if ($hit) {
            if ([string](Get-JkProp $hit 'src') -eq $src) { $same++ }
            else {
                $newTime = $time
                # an all-day feed entry should not wipe a time you added for the same day
                if (-not $newTime -and $hit.time -and $hit.date -eq $date) { $newTime = [string]$hit.time }
                $newTitle = $title; if ($kept) { $newTitle = [string]$hit.title }
                $changed = ($hit.date -ne $date) -or ([string]$hit.time -ne $newTime) -or ([string]$hit.title -ne $newTitle)
                $hit.date = $date; $hit.time = $newTime; $hit.title = $newTitle
                if ($changed) { $updated++ } else { $same++ }
                Set-JkProp $hit 'src' $src
            }
            if ($uid) { Set-JkProp $hit 'uid' $uid }
            continue
        }
        # LEARN puts the course's name in LOCATION; only a real place is worth keeping as the note
        $note = [string]$ev.Location
        if ($code -and $note -match ('(?i)' + [regex]::Escape($code).Replace('\ ', '[ -]?'))) { $note = '' }
        $e = New-JkEvent -Data $data -Course $courseKey -Date $when.Date -Time $time -Title $title -Kind $kind -Note $note -Weight $parsed.Weight
        Set-JkProp $e 'src' $src
        if ($uid) { Set-JkProp $e 'uid' $uid }
        $added += $e
    }
    Save-JkDueData $data
    if ($isUrl -and $Source -ne $saved) { Set-JkConfig 'sync.url' $Source }
    Set-JkState 'lastSync' ((Get-Date).ToString('s', $script:Inv))
    if ($Quiet) { return }
    $origin = 'file'; if ($isUrl) { $origin = ([Uri]($Source -replace '^(?i)webcal://', 'https://')).Host }
    Say ((Paint 'green' "  synced $($script:G.check)") + "  $($added.Count) new, $updated updated, $same unchanged" + (Paint 'gray' "  $($script:G.dot) $(Format-JkCount $feed.Count 'event') in the feed from $origin"))
    $cmap = Get-JkCourseMap $data
    foreach ($e in ($added | Sort-Object date, time | Select-Object -First 15)) { Say (Format-JkDueLine $e $cmap ((Get-JkWidth)) -WithDate) }
    if ($added.Count -gt 15) { Say (Paint 'gray' "  +$($added.Count - 15) more  $($script:G.arrow) jk due all") }
    if ($added | Where-Object { -not $_.weight }) { Say (Paint 'gray' '  feeds carry no grade weights: add them with jk due edit <id> -Weight 8 for jk grade and jk plan') }
}
