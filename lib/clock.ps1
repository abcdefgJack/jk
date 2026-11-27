# clock.ps1 - jk time: the time where your people are, a time here in their time (and back), when
# you are both up for a call, and when the gap changes with the clocks.
#   jk time  |  jk time 8pm beijing  |  jk time 9am  |  jk time add london  |  jk time rm london
# With nothing set, the places come from your installed languages (Chinese (PRC) -> Beijing).

# Cities by the Windows zone they keep (Windows names some in its list, under its own spelling)
$script:JkCityZones = @{
    'China Standard Time'           = 'beijing', 'shanghai', 'shenzhen', 'guangzhou', 'hangzhou', 'chengdu', 'wuhan', 'nanjing', 'xian', 'tianjin', 'chongqing', 'suzhou', 'hong kong', 'macau'
    'Taipei Standard Time'          = 'taipei'
    'Tokyo Standard Time'           = 'tokyo', 'osaka'
    'Korea Standard Time'           = 'seoul', 'busan'
    'Singapore Standard Time'       = 'singapore', 'kuala lumpur', 'manila'
    'SE Asia Standard Time'         = 'bangkok', 'hanoi', 'jakarta', 'ho chi minh city'
    'India Standard Time'           = 'delhi', 'new delhi', 'mumbai', 'bangalore', 'bengaluru', 'kolkata', 'chennai', 'hyderabad'
    'Pakistan Standard Time'        = 'karachi', 'lahore', 'islamabad'
    'Arabian Standard Time'         = 'dubai', 'abu dhabi'
    'Iran Standard Time'            = 'tehran'
    'Russian Standard Time'         = 'moscow'
    'Turkey Standard Time'          = 'istanbul', 'ankara'
    'GMT Standard Time'             = 'london', 'dublin', 'lisbon'
    'Romance Standard Time'         = 'paris', 'madrid', 'brussels'
    'W. Europe Standard Time'       = 'berlin', 'rome', 'amsterdam', 'vienna', 'zurich', 'stockholm'
    'Eastern Standard Time'         = 'waterloo', 'toronto', 'ottawa', 'montreal', 'new york', 'boston', 'washington', 'kitchener', 'mississauga'
    'Central Standard Time'         = 'chicago', 'winnipeg', 'houston', 'dallas'
    'Mountain Standard Time'        = 'calgary', 'edmonton', 'denver'
    'Pacific Standard Time'         = 'vancouver', 'seattle', 'san francisco', 'los angeles', 'san jose'
    'Atlantic Standard Time'        = 'halifax'
    'AUS Eastern Standard Time'     = 'sydney', 'melbourne', 'canberra'
    'New Zealand Standard Time'     = 'auckland', 'wellington'
    'E. South America Standard Time' = 'sao paulo', 'rio de janeiro'
}
# The country of an installed language -> its main city
$script:JkLangCities = @{
    'CN' = 'Beijing'; 'HK' = 'Hong Kong'; 'MO' = 'Macau'; 'TW' = 'Taipei'; 'JP' = 'Tokyo'; 'KR' = 'Seoul'; 'SG' = 'Singapore'; 'MY' = 'Kuala Lumpur'
    'PH' = 'Manila'; 'TH' = 'Bangkok'; 'VN' = 'Hanoi'; 'ID' = 'Jakarta'; 'IN' = 'New Delhi'; 'PK' = 'Karachi'; 'AE' = 'Dubai'; 'IR' = 'Tehran'
    'RU' = 'Moscow'; 'TR' = 'Istanbul'; 'GB' = 'London'; 'FR' = 'Paris'; 'ES' = 'Madrid'; 'DE' = 'Berlin'; 'IT' = 'Rome'; 'BR' = 'Sao Paulo'
}

# A city (or a Windows zone id) to its zone. Windows' own list names cities too: "(UTC+08:00) Beijing,
# Chongqing, Hong Kong, Urumqi".
function Resolve-JkClockZone([string]$Text) {
    $t = ($Text -replace '\s+', ' ').Trim().ToLowerInvariant()
    if (-not $t) { return $null }
    foreach ($id in $script:JkCityZones.Keys) { if (@($script:JkCityZones[$id]) -contains $t) { return [TimeZoneInfo]::FindSystemTimeZoneById($id) } }
    try { return [TimeZoneInfo]::FindSystemTimeZoneById($Text.Trim()) } catch { }
    $rx = '(?i)(^|[\s,)])' + [regex]::Escape($t) + '(,|$)'
    @([TimeZoneInfo]::GetSystemTimeZones() | Where-Object { $_.DisplayName -match $rx })[0]
}

function Format-JkClockName([string]$Text) {
    $t = ($Text -replace '\s+', ' ').Trim().ToLowerInvariant()
    # UTC, GMT, NYC
    if ($t -match '^[a-z]{2,3}$') { return $t.ToUpperInvariant() }
    # invariant: Turkish would title "istanbul" with a dotted capital I, which jk time rm istanbul then misses
    $script:Inv.TextInfo.ToTitleCase($t)
}

# The place or day word a typo was meant to be ("bejing" -> Beijing, "tomorow" -> tomorrow), or $null.
# One letter off, or two in a long word; short words are left alone (too many near neighbours).
function Get-JkClockGuess([string]$Text) {
    $t = ($Text -replace '\s+', ' ').Trim().ToLowerInvariant()
    if ($t.Length -lt 4) { return $null }
    $days = @('today', 'tomorrow', 'tonight') + $script:JkDayNames + $script:JkMonthNames
    $pool = @(foreach ($id in $script:JkCityZones.Keys) { $script:JkCityZones[$id] }) + @(Get-JkConfigPlaceNames) + $days
    $max = $(if ($t.Length -ge 7) { 2 } else { 1 })
    $best = $null; $bestD = $max + 1
    foreach ($c in $pool) {
        $c = ([string]$c).ToLowerInvariant()
        if ($c -eq $t) { return $null }
        $d = Get-JkEditDistance $t $c
        if ($d -lt $bestD) { $best = $c; $bestD = $d }
    }
    if (-not $best) { return $null }
    [pscustomobject]@{ Word = $best; Shown = $(if ($days -contains $best) { $best } else { Format-JkClockName $best }) }
}

function Get-JkConfigPlaceNames {
    @(([string](Get-JkConfig 'time.zones')) -split ';' | ForEach-Object { ($_.Split('=', 2))[0].Trim() } | Where-Object { $_ -and $_ -notmatch '^(off|none)$' })
}

# "Sun 8:00 pm", or "Fri Dec 25 8:00 pm" when the weekday alone would not say which day
function Format-JkClockMoment([datetime]$T, [bool]$WithDate) {
    $fmt = $(if ($WithDate) { 'ddd MMM d' } else { 'ddd' })
    "$($T.ToString($fmt, $script:Inv)) $(Format-JkTime $T.ToString('HH:mm', $script:Inv))"
}

# A time on a zone's clock, to UTC. The hour skipped when the clocks go forward has no answer; the
# hour repeated when they go back is read the second time round, and Twice says so.
function ConvertTo-JkClockUtc([datetime]$At, [TimeZoneInfo]$Zone, [string]$Where) {
    $at = [datetime]::SpecifyKind($At, 'Unspecified')
    if ($Zone.IsInvalidTime($at)) {
        throw "there is no $(Format-JkTime $at.ToString('HH:mm', $script:Inv)) $Where on $($at.ToString('ddd MMM d', $script:Inv)): the clocks go forward an hour that night"
    }
    [pscustomobject]@{ Utc = [TimeZoneInfo]::ConvertTimeToUtc($at, $Zone); Twice = $Zone.IsAmbiguousTime($at) }
}

# The moment in the words that are left once the place is taken out, read on that clock ($Now).
# Every word has to be read: one left over ("8pm bejing") would otherwise be dropped without a word,
# and the answer given for a time nobody asked about.
function Read-JkClockWhen([string[]]$Words, [datetime]$Now, [string[]]$All) {
    $said = (@($All) -join ' ')
    $r = $null
    try { $r = Resolve-JkAtTime $Words $Now } catch {
        if (-not ([string]$_.Exception.Message).StartsWith("can't find a time")) { throw }
        $text = (@($Words) -join ' ')
        $g = Find-JkClockTypo $Words
        if ($g) { throw "can't read '$text' as a place or a time. Did you mean $($g.Shown)?  jk time $(Join-JkClockFix $said $g.Typo $g.Word)" }
        throw "can't read '$text' as a place or a time (jk time beijing, jk time 8pm beijing, jk time 9am fri)"
    }
    if ($r.K -lt @($Words).Count) {
        $read = (@($Words)[0..($r.K - 1)]) -join ' '
        $leftWords = @(@($Words)[$r.K..(@($Words).Count - 1)])
        $g = Find-JkClockTypo $leftWords
        $fix = $(if ($g) { ". Did you mean $($g.Shown)?  jk time $(Join-JkClockFix $said $g.Typo $g.Word)" } else { ' (jk time 8pm fri beijing, jk time 9am dec 3)' })
        throw "'$read' is a time, but '$($leftWords -join ' ')' is not a place or a day$fix"
    }
    $r.At
}

# The words, or one of them, as a typo for a place or a day: Typo (as typed), Word, Shown; or $null.
function Find-JkClockTypo([string[]]$Words) {
    $all = (@($Words) -join ' ')
    $g = Get-JkClockGuess $all
    if ($g) { return [pscustomobject]@{ Typo = $all; Word = $g.Word; Shown = $g.Shown } }
    foreach ($w in @($Words)) {
        $isTime = $true; try { $null = ConvertTo-JkTime $w } catch { $isTime = $false }
        if ($isTime) { continue }
        $g = Get-JkClockGuess $w
        if ($g) { return [pscustomobject]@{ Typo = $w; Word = $g.Word; Shown = $g.Shown } }
    }
    $null
}

# The words as typed, with the typo swapped for the guess
function Join-JkClockFix([string]$Said, [string]$Typo, [string]$Guess) {
    ([regex]('(?i)(?<!\S)' + [regex]::Escape($Typo) + '(?!\S)')).Replace($Said, $Guess, 1)
}

# The places jk time shows: time.zones ("Beijing=China Standard Time;London=GMT Standard Time"), or
# with nothing set, one per installed language from another country (English ones aside).
function Get-JkClockPlaces {
    $cfg = ([string](Get-JkConfig 'time.zones')).Trim()
    if ($cfg -match '^(off|none)$') { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    if ($cfg) {
        foreach ($pair in $cfg -split ';') {
            $kv = $pair.Split('=', 2)
            if ($kv.Count -lt 2) { continue }
            try { $out.Add([pscustomobject]@{ Name = $kv[0].Trim(); Zone = [TimeZoneInfo]::FindSystemTimeZoneById($kv[1].Trim()); Auto = $false }) } catch { }
        }
        return $out.ToArray()
    }
    $geo = ''
    try { $geo = [string](Get-ItemProperty 'HKCU:\Control Panel\International\Geo' -ErrorAction Stop).Name } catch { }
    $langs = @()
    try { $langs = @((Get-ItemProperty 'HKCU:\Control Panel\International\User Profile' -ErrorAction Stop).Languages) } catch { }
    @(Get-JkClockAutoPlaces $langs $geo)
}

# "zh-Hans-CN" -> Beijing, unless that country is home ($Geo, "CA") or keeps this machine's clock.
function Get-JkClockAutoPlaces([string[]]$Langs, [string]$Geo) {
    $out = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($l in @($Langs)) {
        if ([string]$l -match '^en\b') { continue }
        $region = @(([string]$l).Split('-') | Where-Object { $_ -cmatch '^[A-Z]{2}$' })[-1]
        if (-not $region -or $region -eq $Geo -or -not $script:JkLangCities[$region]) { continue }
        $city = $script:JkLangCities[$region]
        if ($seen[$city]) { continue }
        $seen[$city] = $true
        $z = Resolve-JkClockZone $city
        if ($z -and $z.Id -ne [TimeZoneInfo]::Local.Id) { $out.Add([pscustomobject]@{ Name = $city; Zone = $z; Auto = $true }) }
    }
    $out.ToArray()
}

function Save-JkClockPlaces($Places) {
    Set-JkConfig 'time.zones' ((@($Places | ForEach-Object { "$($_.Name)=$($_.Zone.Id)" }) -join ';'))
}

# Hours ahead of (or behind) here at a moment: +13 for Beijing from Waterloo in winter.
function Get-JkClockGap([TimeZoneInfo]$There, [TimeZoneInfo]$Here, [datetime]$Utc) {
    ($There.GetUtcOffset($Utc) - $Here.GetUtcOffset($Utc)).TotalHours
}

function Format-JkClockGap([double]$Gap) {
    if ($Gap -eq 0) { return 'same time' }
    $h = [Math]::Abs($Gap)
    $txt = $(if ($h -eq [Math]::Floor($h)) { "$h" + 'h' } else { '{0}h {1}m' -f [Math]::Floor($h), [int](($h - [Math]::Floor($h)) * 60) })
    $(if ($Gap -gt 0) { "$txt ahead" } else { "$txt behind" })
}

# The next time the gap changes in the next $Days: at what moment (here), from what to what, and
# whose clocks moved.
function Get-JkClockGapChange([TimeZoneInfo]$There, [TimeZoneInfo]$Here, [datetime]$UtcNow, [int]$Days = 21) {
    $UtcNow = [datetime]::SpecifyKind($UtcNow, 'Utc')
    $g0 = Get-JkClockGap $There $Here $UtcNow
    $t = $UtcNow
    $prev = $t
    for ($i = 1; $i -le $Days * 24; $i++) {
        $t = $UtcNow.AddHours($i)
        $g = Get-JkClockGap $There $Here $t
        if ($g -ne $g0) {
            # narrow it to the minute: the change happens on a quarter hour at worst
            $lo = $prev; $hi = $t
            while (($hi - $lo).TotalMinutes -gt 1) { $mid = $lo.AddTicks([long](($hi - $lo).Ticks / 2)); if ((Get-JkClockGap $There $Here $mid) -eq $g0) { $lo = $mid } else { $hi = $mid } }
            $at = [datetime]::SpecifyKind($hi, 'Utc').AddSeconds(-$hi.Second).AddMilliseconds(-$hi.Millisecond)
            if ($at.Minute % 15) { $at = $at.AddMinutes(15 - $at.Minute % 15) }
            $side = $(if ($Here.GetUtcOffset($at) -ne $Here.GetUtcOffset($at.AddHours(-2))) { 'here' } else { 'there' })
            return [pscustomobject]@{ Utc = $at; Before = $g0; After = $g; Side = $side }
        }
        $prev = $t
    }
    $null
}

# Stretches starting in the next day when it is 8 am-11 pm here and 9 am-10 pm there, as local times
# here. One that starts before the day is out runs to its real end, not to where the day stops.
function Get-JkCallWindows([TimeZoneInfo]$There, [TimeZoneInfo]$Here, [datetime]$UtcNow) {
    $start = [datetime]::SpecifyKind($UtcNow, 'Utc')
    $start = $start.AddMinutes(-($start.Minute % 30)).AddSeconds(-$start.Second).AddMilliseconds(-$start.Millisecond)
    $out = New-Object System.Collections.Generic.List[object]
    $cur = $null
    for ($i = 0; $i -lt 96; $i++) {
        $u = $start.AddMinutes(30 * $i)
        $h = [TimeZoneInfo]::ConvertTimeFromUtc($u, $Here); $x = [TimeZoneInfo]::ConvertTimeFromUtc($u, $There)
        $hm = $h.Hour + $h.Minute / 60; $xm = $x.Hour + $x.Minute / 60
        $ok = $hm -ge 8 -and $hm -lt 23 -and $xm -ge 9 -and $xm -lt 22
        if ($ok) {
            if ($cur) { $cur.End = $h.AddMinutes(30) }
            elseif ($i -lt 48) { $cur = [pscustomobject]@{ Start = $h; End = $h.AddMinutes(30); Now = ($i -eq 0) }; $out.Add($cur) }
        } else {
            $cur = $null
            if ($i -ge 48) { break }
        }
    }
    $out.ToArray()
}

# "7 am", "7:30 pm"
function Format-JkClockTime([datetime]$T) {
    if ($T.Minute) { return Format-JkTime $T.ToString('HH:mm', $script:Inv) }
    $h = $T.Hour; $ap = $(if ($h -ge 12) { 'pm' } else { 'am' }); $h12 = $h % 12; if ($h12 -eq 0) { $h12 = 12 }
    "$h12 $ap"
}

# "now-11 pm, 8-9 am tomorrow" (here)
function Format-JkCallWindows($Windows, [datetime]$HereNow) {
    @(foreach ($w in @($Windows | Select-Object -First 2)) {
            $a = $(if ($w.Now) { 'now' } else { Format-JkClockTime $w.Start })
            $b = Format-JkClockTime $w.End
            if (-not $w.Now -and $a.Split(' ')[-1] -eq $b.Split(' ')[-1] -and ($w.End - $w.Start).TotalHours -lt 12) { $a = $a.Split(' ')[0] }
            $day = ''
            if ($w.Start.Date -gt $HereNow.Date) { $day = ' tomorrow' }
            elseif (-not $w.Now -and $w.Start.Hour -ge 17) { $day = ' tonight' }
            "$a$($script:G.dash)$b$day"
        }) -join ', '
}

function Get-JkClockNowUtc { (Get-JkNow).ToUniversalTime() }

function Show-JkClock {
    $places = @(Get-JkClockPlaces)
    $here = [TimeZoneInfo]::Local
    $utc = Get-JkClockNowUtc
    $hn = [TimeZoneInfo]::ConvertTimeFromUtc($utc, $here)
    $abbr = $(if ($here.IsDaylightSavingTime($hn)) { $here.DaylightName } else { $here.StandardName })
    Write-JkHeader 'Time' $abbr -Sub "$($hn.ToString('ddd MMM d', $script:Inv)), $(Format-JkTime $hn.ToString('HH:mm', $script:Inv)) here"
    if (-not $places.Count) {
        Say (Paint 'gray' '  No other places yet.  jk time add beijing  (any big city, or a Windows zone name)')
        return
    }
    foreach ($p in $places) { Write-JkClockPlace $p $here $utc $hn }
    Say ''
    if (@($places | Where-Object { $_.Auto }).Count) { Say (Paint 'gray' "  $((@($places | Where-Object { $_.Auto } | ForEach-Object { $_.Name })) -join ', ') from your installed languages") }
    Say (Paint 'gray' "  jk time 8pm $($places[0].Name.ToLower())  $($script:G.dot)  jk time 9am  $($script:G.dot)  jk time add <city>  $($script:G.dot)  jk time rm <city>")
}

# One place: its time, the gap, awake or asleep, any change coming, and when you are both up.
function Write-JkClockPlace($P, [TimeZoneInfo]$Here, [datetime]$Utc, [datetime]$HereNow) {
    $x = [TimeZoneInfo]::ConvertTimeFromUtc($Utc, $P.Zone)
    $gap = Get-JkClockGap $P.Zone $Here $Utc
    $xm = $x.Hour + $x.Minute / 60
    $up = $xm -ge 8 -and $xm -lt 22.5
    $state = $(if ($up) { Paint 'green' 'awake' } else { Paint 'gray' 'asleep' })
    $day = $x.ToString('ddd', $script:Inv)
    Say ('  ' + (Paint 'bold white' (Fit $P.Name 13)) + (Paint 'white' (Fit "$day $(Format-JkTime $x.ToString('HH:mm', $script:Inv))" 14)) + (Paint 'muted' (Fit (Format-JkClockGap $gap) 15)) + $state)
    $ch = Get-JkClockGapChange $P.Zone $Here $Utc
    if ($ch) {
        # as the clock reads just before: "2 am", not the "1 am" it turns into
        $when = [TimeZoneInfo]::ConvertTimeFromUtc($ch.Utc.AddMinutes(-1), $Here).AddMinutes(1)
        $rel = Format-JkRelDay $when.Date $HereNow.Date
        if ($rel -like 'in *') { $rel = $when.ToString('ddd MMM d', $script:Inv) }
        if ($rel -eq 'tomorrow' -and $when.Hour -lt 6 -and $HereNow.Hour -ge 18) { $rel = 'tonight' }
        $who = $(if ($ch.Side -eq 'here') { 'the clocks here' } else { "the clocks in $($P.Name)" })
        $dir = $(if ($ch.Side -eq 'here') { $(if ($Here.GetUtcOffset($ch.Utc) -lt $Here.GetUtcOffset($ch.Utc.AddHours(-2))) { 'go back' } else { 'go forward' }) } else { $(if ($P.Zone.GetUtcOffset($ch.Utc) -lt $P.Zone.GetUtcOffset($ch.Utc.AddHours(-2))) { 'go back' } else { 'go forward' }) })
        Say ((' ' * 15) + (Paint 'amber' "$(Format-JkClockGap $ch.After) from $(Format-JkClockTime $when) $rel") + (Paint 'gray' ", when $who $dir an hour"))
    }
    $win = @(Get-JkCallWindows $P.Zone $Here $Utc)
    if ($win.Count) { Say ((' ' * 15) + (Paint 'gray' 'both up for a call: ') + (Paint 'muted' (Format-JkCallWindows $win $HereNow)) + (Paint 'gray' ' (your time)')) }
}

# "jk time beijing": that place now, on your list or not; $false when the words name no place.
function Show-JkClockFor([string[]]$Words) {
    $text = (@($Words) -join ' ').Trim()
    $known = @(Get-JkClockPlaces | Where-Object { $_.Name -ieq $text })[0]
    $zone = $(if ($known) { $known.Zone } else { Resolve-JkClockZone $text })
    if (-not $zone) { return $false }
    $here = [TimeZoneInfo]::Local
    $utc = Get-JkClockNowUtc
    Say ''
    Write-JkClockPlace ([pscustomobject]@{ Name = $(if ($known) { $known.Name } else { Format-JkClockName $text }); Zone = $zone }) $here $utc ([TimeZoneInfo]::ConvertTimeFromUtc($utc, $here))
    Say ''
    if (-not $known) { Say (Paint 'gray' "  jk time add $($text.ToLower()) keeps it on your list") }
    $true
}

# "8pm beijing" (there -> here), "beijing sun 8pm", "8pm beijing tomorrow", "9am" (here -> every place).
# A moment a week or more off shows its date: the weekday alone would not say which week.
function Convert-JkClockTime([string[]]$Words) {
    $w = @($Words | Where-Object { $_ })
    $places = @(Get-JkClockPlaces)
    $place = $null; $rest = $w
    # the place: the longest run of words that names one, at the end, the start, or in between
    foreach ($n in 3, 2, 1) {
        if ($w.Count -le $n) { continue }
        foreach ($s in @(@($w.Count - $n) + @(0..($w.Count - $n - 1)))) {
            $cand = ($w[$s..($s + $n - 1)]) -join ' '
            $known = @($places | Where-Object { $_.Name -ieq $cand })[0]
            $z = $(if ($known) { $known.Zone } else { Resolve-JkClockZone $cand })
            if ($z) {
                $place = [pscustomobject]@{ Name = $(if ($known) { $known.Name } else { Format-JkClockName $cand }); Zone = $z }
                $rest = @(for ($i = 0; $i -lt $w.Count; $i++) { if ($i -lt $s -or $i -ge $s + $n) { $w[$i] } })
                break
            }
        }
        if ($place) { break }
    }
    $here = [TimeZoneInfo]::Local
    $utc = Get-JkClockNowUtc
    $rows = @()
    if ($place) {
        # a time there: read against their clock ("tomorrow" is their tomorrow)
        $thereNow = [TimeZoneInfo]::ConvertTimeFromUtc($utc, $place.Zone)
        $savedNow = $env:JK_NOW
        try { $env:JK_NOW = $thereNow.ToString('s', $script:Inv); $at = Read-JkClockWhen $rest $thereNow $w } finally { $env:JK_NOW = $savedNow }
        $c = ConvertTo-JkClockUtc $at $place.Zone "in $($place.Name)"
        $h = [TimeZoneInfo]::ConvertTimeFromUtc($c.Utc, $here)
        $long = ($c.Utc - $utc).TotalDays -ge 6
        $rows += [pscustomobject]@{ From = "$(Format-JkClockMoment $at $long) in $($place.Name)"; To = "$(Format-JkClockMoment $h $long) here"; Up = ($h.Hour -ge 8 -and $h.Hour -lt 23); Who = 'you'; Twice = $(if ($c.Twice) { "$(Format-JkTime $at.ToString('HH:mm', $script:Inv)) comes twice in $($place.Name)" } else { '' }) }
    } else {
        $hereNow = [TimeZoneInfo]::ConvertTimeFromUtc($utc, $here)
        $at = Read-JkClockWhen $w $hereNow $w
        if (-not $places.Count) { throw 'no other places to convert to: jk time add beijing, or name one: jk time 8pm london' }
        $c = ConvertTo-JkClockUtc $at $here 'here'
        $long = ($c.Utc - $utc).TotalDays -ge 6
        foreach ($p in $places) {
            $x = [TimeZoneInfo]::ConvertTimeFromUtc($c.Utc, $p.Zone)
            $rows += [pscustomobject]@{ From = "$(Format-JkClockMoment $at $long) here"; To = "$(Format-JkClockMoment $x $long) in $($p.Name)"; Up = ($x.Hour -ge 8 -and $x.Hour -lt 22); Who = 'they'; Twice = $(if ($c.Twice) { "$(Format-JkTime $at.ToString('HH:mm', $script:Inv)) comes twice here" } else { '' }) }
        }
    }
    $rows
}

function Invoke-JkTime {
    $a = @($args | ForEach-Object { [string]$_ } | Where-Object { $_ })
    if (-not $a.Count) { Show-JkClock; return }
    $rest = (@($a | Select-Object -Skip 1) -join ' ').Trim()
    switch -Regex ($a[0].ToLower()) {
        '^(help|-h|--help|\?)$' { Show-JkHelp time; return }
        '^(add|\+)$' {
            if (-not $rest) { throw 'usage: jk time add <city>   e.g. jk time add beijing' }
            $z = Resolve-JkClockZone $rest
            if (-not $z) { throw "no time zone found for '$rest' (a big city nearby works, or a Windows zone such as 'China Standard Time')" }
            $places = @(Get-JkClockPlaces | Where-Object { $_.Name -ine $rest })
            Save-JkClockPlaces (@($places) + [pscustomobject]@{ Name = (Format-JkClockName $rest); Zone = $z })
            Say ((Paint 'green' "  $($script:G.check) $(Format-JkClockName $rest)") + (Paint 'gray' "  ($($z.DisplayName))"))
            Show-JkClock
            return
        }
        '^(rm|remove|del|delete|-)$' {
            if (-not $rest) { throw 'usage: jk time rm <city>' }
            $places = @(Get-JkClockPlaces)
            $keep = @($places | Where-Object { $_.Name -ine $rest })
            if ($keep.Count -eq $places.Count) { throw "'$rest' is not on the list ($(@($places | ForEach-Object { $_.Name }) -join ', '))" }
            # emptied by hand: say so, or the installed languages would bring the places back
            if ($keep.Count) { Save-JkClockPlaces $keep } else { Set-JkConfig 'time.zones' 'off' }
            Say (Paint 'green' "  removed $rest")
            return
        }
        '^(off)$' { Set-JkConfig 'time.zones' 'off'; Say (Paint 'green' '  no places (jk time add <city> starts again)'); return }
    }
    if (Show-JkClockFor $a) { return }
    $rows = @(Convert-JkClockTime $a)
    Say ''
    foreach ($r in $rows) {
        $note = ''
        if (-not $r.Up) { $note = Paint 'gray' $(if ($r.Who -eq 'you') { '   (late or early for you)' } else { '   (likely asleep there)' }) }
        Say ('  ' + (Paint 'white' $r.From) + (Paint 'gray' "  $($script:G.arrow)  ") + (Paint 'bold white' $r.To) + $note)
    }
    $twice = @($rows | Where-Object { $_.Twice })[0]
    if ($twice) { Say (Paint 'amber' "  $($twice.Twice) that night, as the clocks go back an hour: this is the second one.") }
    Say ''
}
