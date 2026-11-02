# weather.ps1 - jk weather: the forecast where you are, read for what it means: rain or snow from
# when to when, how cold it feels, the days ahead, and the weather at your next exam. From
# Open-Meteo (free, no key or account); the only thing sent is the place's coordinates.
#
# Hours come as unix instants and are turned into local time here: Open-Meteo's own local times
# keep today's UTC offset for the whole forecast, an hour off once the clocks change.

$script:JkWeatherHome = [pscustomobject]@{ Name = 'Waterloo, ON'; Lat = 43.4643; Lon = -80.5204 }
$script:JkProvinces = @{
    'Alberta' = 'AB'; 'British Columbia' = 'BC'; 'Manitoba' = 'MB'; 'New Brunswick' = 'NB'; 'Newfoundland and Labrador' = 'NL'
    'Nova Scotia' = 'NS'; 'Ontario' = 'ON'; 'Prince Edward Island' = 'PE'; 'Quebec' = 'QC'; 'Saskatchewan' = 'SK'
}
$script:JkWeatherCodes = @{
    0 = 'clear'; 1 = 'mostly clear'; 2 = 'partly cloudy'; 3 = 'cloudy'; 45 = 'fog'; 48 = 'freezing fog'
    51 = 'light drizzle'; 53 = 'drizzle'; 55 = 'heavy drizzle'; 56 = 'freezing drizzle'; 57 = 'freezing drizzle'
    61 = 'light rain'; 63 = 'rain'; 65 = 'heavy rain'; 66 = 'freezing rain'; 67 = 'freezing rain'
    71 = 'light snow'; 73 = 'snow'; 75 = 'heavy snow'; 77 = 'snow grains'
    80 = 'showers'; 81 = 'showers'; 82 = 'heavy showers'; 85 = 'snow showers'; 86 = 'heavy snow showers'
    95 = 'thunderstorms'; 96 = 'thunderstorms with hail'; 99 = 'thunderstorms with hail'
}
$script:JkDeg = [string][char]0x00B0

function Get-JkWeatherText([int]$Code) { $t = $script:JkWeatherCodes[$Code]; if (-not $t) { $t = 'cloudy' }; $t }
function Format-JkDeg([double]$T) { "$([int][Math]::Round($T, [MidpointRounding]::AwayFromZero))$script:JkDeg" }

# "7 pm", "12 am"
function Format-JkHour([datetime]$T) {
    $h = $T.Hour; $ap = $(if ($h -ge 12) { 'pm' } else { 'am' })
    $h12 = $h % 12; if ($h12 -eq 0) { $h12 = 12 }
    "$h12 $ap"
}

# "2-6 pm", "11 am-2 pm"
function Format-JkHourSpan([datetime]$From, [datetime]$To) {
    $a = Format-JkHour $From; $b = Format-JkHour $To
    if ($a.Split(' ')[1] -eq $b.Split(' ')[1] -and ($To - $From).TotalHours -lt 12) { $a = $a.Split(' ')[0] }
    "$a$($script:G.dash)$b"
}

# ---------------------------------------------------------------- places

# weather.place: empty = Waterloo; off = no weather on the dashboard, in the morning popup or in jk
# exam; "Toronto, ON (43.6532, -79.3832)" as jk weather set writes it; or a bare name, looked up once.
# -NoLookup never goes to the network (a bare name not looked up yet gives $null).
function Get-JkWeatherPlace([switch]$NoLookup) {
    $p = ([string](Get-JkConfig 'weather.place')).Trim()
    if (-not $p) { return $script:JkWeatherHome }
    if ($p -match '^(off|none|no|0)$') { return $null }
    $m = [regex]::Match($p, '^(?<name>.+?)\s*\(\s*(?<lat>-?\d+(?:\.\d+)?)\s*,\s*(?<lon>-?\d+(?:\.\d+)?)\s*\)$')
    if ($m.Success) {
        return [pscustomobject]@{ Name = $m.Groups['name'].Value; Lat = [double]::Parse($m.Groups['lat'].Value, $script:Inv); Lon = [double]::Parse($m.Groups['lon'].Value, $script:Inv) }
    }
    Resolve-JkWeatherPlace $p -NoLookup:$NoLookup
}

function Format-JkWeatherPlace($Place) {
    '{0} ({1}, {2})' -f $Place.Name, ([double]$Place.Lat).ToString('0.####', $script:Inv), ([double]$Place.Lon).ToString('0.####', $script:Inv)
}

# A place name to coordinates through Open-Meteo's geocoder, remembered after the first look-up.
# "London, ON" is the Ontario one: what follows the comma picks the province, state or country.
function Resolve-JkWeatherPlace([string]$Text, [switch]$NoLookup) {
    $Text = $Text.Trim()
    $key = $Text.ToLowerInvariant()
    $file = Join-Path (Get-JkCacheDir) 'weather-places.json'
    $known = $null
    try { if ([IO.File]::Exists($file)) { $known = ConvertFrom-Json ([IO.File]::ReadAllText($file)) } } catch { }
    if (-not $known) { $known = [pscustomobject]@{} }
    $hit = Get-JkProp $known $key
    if ($hit) { return [pscustomobject]@{ Name = [string]$hit.Name; Lat = [double]$hit.Lat; Lon = [double]$hit.Lon } }
    if ($NoLookup) { return $null }
    $parts = $Text.Split(',', 2)
    $name = $parts[0].Trim(); $where = ''; if ($parts.Count -gt 1) { $where = $parts[1].Trim() }
    $find = { param($n) @((ConvertFrom-Json (Invoke-JkWeatherGet ('https://geocoding-api.open-meteo.com/v1/search?count=10&language=en&format=json&name=' + [uri]::EscapeDataString($n)))).results | Where-Object { $_ }) }
    $res = @(& $find $name)
    # "jk weather london, on" arrives without its comma (PowerShell reads one as a list): the last
    # word is then the region
    $words = @($name -split '\s+')
    if (-not $res.Count -and -not $where -and $words.Count -gt 1) {
        $where = $words[-1]; $name = (@($words | Select-Object -First ($words.Count - 1))) -join ' '
        $res = @(& $find $name)
    }
    if (-not $res.Count) { throw "no place called '$Text' found (a nearby city works: jk weather toronto)" }
    $pick = Select-JkGeoResult $res $where
    $place = [pscustomobject]@{ Name = (Format-JkGeoName $pick); Lat = [double]$pick.latitude; Lon = [double]$pick.longitude }
    Set-JkProp $known $key $place
    try { Write-JkText $file (ConvertTo-Json $known -Depth 3) } catch { }
    $place
}

function Select-JkGeoResult($Results, [string]$Where) {
    if ($Where) {
        foreach ($r in $Results) {
            $a1 = [string]$r.admin1
            if ($a1 -eq $Where -or $script:JkProvinces[$a1] -eq $Where.ToUpper() -or [string]$r.country_code -eq $Where -or
                ($Where.Length -ge 3 -and ($a1 -like "$Where*" -or [string]$r.country -like "$Where*"))) { return $r }
        }
    }
    $Results[0]
}

# "Toronto, ON", "Boston, Massachusetts", "Paris, France"
function Format-JkGeoName($R) {
    $a1 = [string]$R.admin1
    $region = [string]$R.country
    if ([string]$R.country_code -eq 'CA' -and $script:JkProvinces[$a1]) { $region = $script:JkProvinces[$a1] }
    elseif ([string]$R.country_code -eq 'US' -and $a1) { $region = $a1 }
    if ($region) { "$($R.name), $region" } else { [string]$R.name }
}

# ---------------------------------------------------------------- the forecast

# One GET to Open-Meteo. A pinned clock (tests, previews with JK_NOW) never goes out: its "now" is not
# the forecast's.
function Invoke-JkWeatherGet([string]$Url, [int]$TimeoutSec = 6) {
    if ($env:JK_NOW) { throw 'no live weather while JK_NOW pins the clock' }
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -UserAgent 'jk (PowerShell)' -ErrorAction Stop
    [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
}

# Yesterday too, so today's high and low cover the whole day whatever the UTC date.
function Get-JkWeatherUrl($Place) {
    'https://api.open-meteo.com/v1/forecast?latitude=' + ([double]$Place.Lat).ToString('0.####', $script:Inv) +
    '&longitude=' + ([double]$Place.Lon).ToString('0.####', $script:Inv) +
    '&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m' +
    '&hourly=temperature_2m,apparent_temperature,precipitation_probability,precipitation,snowfall,weather_code,wind_speed_10m,wind_gusts_10m' +
    '&daily=sunrise,sunset&timeformat=unixtime&timezone=auto&past_days=1&forecast_days=6'
}

# Hours on this machine's clock, which knows when the clocks change; a place in another zone reads
# on its own clock instead, at its offset now (Offset set, and ConvertTo-JkWeatherClock moves a time
# from here onto it).
function ConvertFrom-JkWeatherJson([string]$Text, $Place, [datetime]$Fetched) {
    $r = ConvertFrom-Json $Text
    $h = $r.hourly
    $n = @($h.time).Count
    if (-not $n) { throw 'the forecast came back without hours' }
    $off = $null
    if ($null -ne $r.utc_offset_seconds) {
        $o = [TimeSpan]::FromSeconds([double]$r.utc_offset_seconds)
        # against this machine's offset when it was fetched: one kept from before the clocks changed is still from here
        if ($o -ne [TimeZoneInfo]::Local.GetUtcOffset($Fetched.ToUniversalTime())) { $off = $o }
    }
    $loc = { param($u) [DateTimeOffset]::FromUnixTimeSeconds([long]$u).UtcDateTime.ToLocalTime() }
    if ($null -ne $off) { $loc = { param($u) [DateTimeOffset]::FromUnixTimeSeconds([long]$u).UtcDateTime.Add($off) } }
    $hours = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $n; $i++) {
        $hours.Add([pscustomobject]@{
                At = & $loc $h.time[$i]; Temp = [double]$h.temperature_2m[$i]; Feels = [double]$h.apparent_temperature[$i]
                Pop = [int]$h.precipitation_probability[$i]; Rain = [double]$h.precipitation[$i]; Snow = [double]$h.snowfall[$i]
                Code = [int]$h.weather_code[$i]; Wind = [double]$h.wind_speed_10m[$i]; Gust = [double]$h.wind_gusts_10m[$i]
            })
    }
    $sun = @(@(foreach ($k in 'sunrise', 'sunset') { foreach ($u in @($r.daily.$k)) { if ($u) { [pscustomobject]@{ Kind = $k; At = & $loc $u } } } }) | Sort-Object At)
    $cur = $null
    if ($r.current -and $r.current.time) {
        $c = $r.current
        $cur = [pscustomobject]@{ At = & $loc $c.time; Temp = [double]$c.temperature_2m; Feels = [double]$c.apparent_temperature; Code = [int]$c.weather_code; Wind = [double]$c.wind_speed_10m }
    }
    [pscustomobject]@{ Place = $Place; Fetched = $Fetched; Stale = $false; Current = $cur; Hours = $hours.ToArray(); Sun = $sun; Offset = $off }
}

function ConvertTo-JkWeatherClock($W, [datetime]$At) {
    if ($null -ne $W.Offset) { return $At.ToUniversalTime().Add($W.Offset) }
    $At
}

# The forecast for $Place: the cached copy while it is under $MaxAgeHours old, else a fresh one
# (cached for next time unless -NoSave). Offline, a copy up to a day old comes back marked Stale;
# with none, $null and the reason in $script:JkWeatherError. -CacheOnly never goes to the network.
function Get-JkWeather {
    param($Place, [double]$MaxAgeHours = 1, [switch]$CacheOnly, [int]$TimeoutSec = 6, [switch]$NoSave)
    $script:JkWeatherError = ''
    if (-not $Place) { $Place = Get-JkWeatherPlace -NoLookup:$CacheOnly; if (-not $Place) { return $null } }
    $id = ([double]$Place.Lat).ToString('0.####', $script:Inv) + '|' + ([double]$Place.Lon).ToString('0.####', $script:Inv)
    $file = Join-Path (Get-JkCacheDir) 'weather.txt'
    $text = $null; $age = -1.0; $fetched = [datetime]::MinValue
    try {
        if ([IO.File]::Exists($file)) {
            $t = [IO.File]::ReadAllText($file)
            $nl = $t.IndexOf("`n"); $bar = $t.IndexOf('|')
            if ($nl -gt 0 -and $bar -gt 0 -and $bar -lt $nl -and $t.Substring($bar + 1, $nl - $bar - 1) -eq $id) {
                $fetched = [DateTimeOffset]::Parse($t.Substring(0, $bar), $script:Inv).UtcDateTime
                $age = ([DateTime]::UtcNow - $fetched).TotalHours
                $text = $t.Substring($nl + 1)
            }
        }
    } catch { $text = $null }
    if ($text -and $age -ge 0 -and $age -lt $MaxAgeHours) { try { return ConvertFrom-JkWeatherJson $text $Place $fetched } catch { $text = $null } }
    $errFile = Join-Path (Get-JkCacheDir) 'weather.error'
    if (-not $CacheOnly) {
        try {
            $new = Invoke-JkWeatherGet (Get-JkWeatherUrl $Place) $TimeoutSec
            $at = [DateTime]::UtcNow
            # read before it is kept: a garbled reply is never cached
            $w = ConvertFrom-JkWeatherJson $new $Place $at
            if (-not $NoSave) {
                try { Write-JkText $file ($at.ToString('o', $script:Inv) + "|$id`n" + $new) } catch { }
                try { [IO.File]::Delete($errFile) } catch { }
            }
            return $w
        } catch {
            $script:JkWeatherError = $_.Exception.Message
            # why the kept forecast is getting old, for jk weather to say
            if (-not $NoSave -and -not $env:JK_NOW) { try { Write-JkText $errFile ((Get-Date).ToString('s', $script:Inv) + ' ' + $script:JkWeatherError) } catch { } }
        }
    }
    # offline, or not asked to fetch: an older forecast still beats none (it reaches six days out)
    if ($text -and $age -ge 0 -and $age -lt 48) {
        try { $w = ConvertFrom-JkWeatherJson $text $Place $fetched; $w.Stale = $true; return $w } catch { }
    }
    $null
}

# Fetches the forecast in a background process for the next look: at most every 10 minutes, and
# never under a pinned clock or in tests.
function Start-JkWeatherRefresh {
    if ($env:JK_NOW -or $env:JK_NONINTERACTIVE) { return }
    $mark = Join-Path (Get-JkCacheDir) 'weather.refresh'
    try {
        if ([IO.File]::Exists($mark) -and ([DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($mark)).TotalMinutes -lt 10) { return }
        [IO.File]::WriteAllText($mark, '')
    } catch { return }
    $null = Start-JkBackground -Script '$null = Get-JkWeather -MaxAgeHours 0.25 -TimeoutSec 15'
}

# ---------------------------------------------------------------- reading it

# The hour of the forecast that $At falls in.
function Get-JkWeatherHour($W, [datetime]$At) {
    $best = $null
    foreach ($h in $W.Hours) { if ($h.At -le $At) { $best = $h } else { break } }
    if ($best -and ($At - $best.At).TotalMinutes -lt 61) { $best } else { $null }
}

# Wet: a 50% or better chance of a measurable amount.
function Test-JkWetHour($H) { $H.Pop -ge 50 -and ($H.Rain -ge 0.1 -or $H.Snow -ge 0.1) }

function Get-JkWetKind($H) {
    if ($H.Code -in 56, 57, 66, 67) { return 'freezing rain' }
    if ($H.Snow -ge 0.1 -or $H.Code -in 71, 73, 75, 77, 85, 86) { return 'snow' }
    if ($H.Code -ge 95) { return 'thunderstorms' }
    'rain'
}

# Wet stretches between $From and $To. One dry hour inside does not split a stretch.
function Get-JkWetSpells($W, [datetime]$From, [datetime]$To) {
    $out = New-Object 'System.Collections.Generic.List[object]'
    $cur = $null; $gap = 0
    foreach ($h in $W.Hours) {
        if ($h.At.AddHours(1) -le $From -or $h.At -ge $To) { continue }
        if (Test-JkWetHour $h) {
            if ($cur -and $gap -le 1) { $cur.End = $h.At.AddHours(1) }
            else { $cur = [pscustomobject]@{ Start = $h.At; End = $h.At.AddHours(1); Pop = 0; Mm = 0.0; Cm = 0.0; Kinds = @(); Kind = '' }; $out.Add($cur) }
            $cur.Pop = [Math]::Max($cur.Pop, $h.Pop); $cur.Mm += $h.Rain; $cur.Cm += $h.Snow
            $k = Get-JkWetKind $h; if ($cur.Kinds -notcontains $k) { $cur.Kinds += $k }
            $gap = 0
        } elseif ($cur) { $gap++ }
    }
    foreach ($s in $out) {
        $k = $s.Kinds
        $s.Kind = $(if ($k -contains 'freezing rain') { 'freezing rain' }
            elseif ($k -contains 'snow' -and ($k -contains 'rain' -or $k -contains 'thunderstorms')) { 'rain and snow' }
            elseif ($k -contains 'snow') { 'snow' } elseif ($k -contains 'thunderstorms') { 'thunderstorms' } else { 'rain' })
    }
    $out.ToArray()
}

# "rain 2-6 pm (80%)", "snow from 9 pm (70%, 4 cm)", "rain until 10 am (60%)", "rain all day (90%, 14 mm)"
function Format-JkSpell($S, [datetime]$From, [datetime]$To, [string]$Day = '', [string]$All = 'all day') {
    $starts = $S.Start -gt $From; $ends = $S.End -lt $To
    $span = $(if ($starts -and $ends) { Format-JkHourSpan $S.Start $S.End } elseif ($starts) { 'from ' + (Format-JkHour $S.Start) } elseif ($ends) { 'until ' + (Format-JkHour $S.End) } else { $All })
    if ($Day) { $span = "$Day $span" }
    $amt = @("$($S.Pop)%")
    if ($S.Cm -ge 1) { $amt += "$([int][Math]::Round($S.Cm)) cm" } elseif ($S.Mm -ge 5) { $amt += "$([int][Math]::Round($S.Mm)) mm" }
    "$($S.Kind) $span ($($amt -join ', '))"
}

# '' for a stretch starting today (or under way), else "overnight" (before 6 am) or "tomorrow".
function Get-JkSpellDay($S, [datetime]$Now) {
    if ($S.Start -le $Now -or $S.Start.Date -eq $Now.Date) { return '' }
    $(if ($S.Start.Hour -lt 6) { 'overnight' } else { 'tomorrow' })
}

# One day: high and low, the wet stretches between 6 am and midnight (from now, today), or else the
# sky by day, and what to take along.
function Get-JkWeatherDay($W, [datetime]$Date, [datetime]$Now) {
    $Date = $Date.Date
    $hrs = @($W.Hours | Where-Object { $_.At.Date -eq $Date })
    if ($hrs.Count -lt 20) { return $null }
    $from = $Date.AddHours(6); if ($Date -eq $Now.Date -and $Now -gt $from) { $from = $Now }
    $to = $Date.AddDays(1)
    $spells = @(Get-JkWetSpells $W $from $to)
    $awake = @($hrs | Where-Object { $_.At.AddHours(1) -gt $from -and $_.At.Hour -ge 7 })
    if (-not $awake.Count) { $awake = @($hrs | Select-Object -Last 1) }
    $byDay = @($hrs | Where-Object { $_.At.Hour -ge 8 -and $_.At.Hour -lt 20 })
    $sky = Get-JkWeatherText ([int]@($byDay | Group-Object Code | Sort-Object Count -Descending)[0].Name)
    $pop = ($awake | Measure-Object Pop -Maximum).Maximum
    $coldest = ($awake | Measure-Object Feels -Minimum).Minimum
    $gust = ($awake | Measure-Object Gust -Maximum).Maximum
    $text = $sky
    if ($spells.Count) {
        $all = $(if ($from -gt $Date.AddHours(6)) { 'for the rest of the day' } else { 'all day' })
        $text = (@($spells | ForEach-Object { Format-JkSpell $_ $from $to '' $all }) -join ', ')
    }
    elseif ($pop -ge 30) {
        $wettest = @($awake | Sort-Object Pop -Descending)[0]
        $text += ", $pop% chance of $(if ($wettest.Temp -le 1) { 'snow' } else { 'rain' })"
    }
    $advice = @()
    $kinds = @($spells | ForEach-Object { $_.Kind })
    if (@($kinds | Where-Object { $_ -match 'rain|thunder' }).Count) { $advice += 'umbrella' }
    if (($spells | Measure-Object Cm -Sum).Sum -ge 2) { $advice += 'boots' }
    if ($kinds -contains 'freezing rain') { $advice += 'icy sidewalks' }
    if ($coldest -le -10) { $advice += "feels like $(Format-JkDeg $coldest)" }
    if ($gust -ge 60) { $advice += "gusts to $([int]$gust) km/h" }
    [pscustomobject]@{
        Date = $Date; High = ($hrs | Measure-Object Temp -Maximum).Maximum; Low = ($hrs | Measure-Object Temp -Minimum).Minimum
        Sky = $sky; Spells = $spells; Text = $text; Advice = $advice
    }
}

# A day in a few characters for jk week: "12/0 rain", "17/2 clear"; Wet when a stretch of it is.
function Get-JkWeatherDayShort($W, [datetime]$Date, [datetime]$Now) {
    $d = Get-JkWeatherDay $W $Date $Now
    if (-not $d) { return $null }
    $word = switch -Regex ($d.Sky) {
        '^(clear|mostly clear)$' { 'clear'; break }
        '^partly' { 'mixed'; break }
        'fog' { 'fog'; break }
        'thunder' { 'storms'; break }
        # wet by the sky's look but under the odds of a wet stretch: maybe
        'snow' { 'snow?'; break }
        'rain|drizzle|showers' { 'rain?'; break }
        default { 'cloudy' }
    }
    $wet = [bool]$d.Spells.Count
    if ($wet) {
        $word = switch ($d.Spells[0].Kind) { 'rain and snow' { 'sleet' } 'thunderstorms' { 'storms' } 'freezing rain' { 'ice' } default { $d.Spells[0].Kind } }
    }
    [pscustomobject]@{ Text = "$(Format-JkDeg $d.High)/$(Format-JkDeg $d.Low) $word"; Wet = $wet }
}

# "13 deg, cloudy at 7:00 pm, 30% chance of rain" (with what to take); '' past the forecast's end.
function Get-JkWeatherAtText($W, [datetime]$At) {
    $h = Get-JkWeatherHour $W $At
    if (-not $h) { return '' }
    $s = "$(Format-JkDeg $h.Temp), $(Get-JkWeatherText $h.Code) at $(Format-JkTime $At.ToString('HH:mm', $script:Inv))"
    if ([Math]::Abs($h.Feels - $h.Temp) -ge 3) { $s += " (feels $(Format-JkDeg $h.Feels))" }
    $wet = @(Get-JkWetSpells $W $At.AddHours(-1) $At.AddHours(1))
    if ($wet.Count) { $s += "; $($wet[0].Kind) around then ($($wet[0].Pop)%), take an umbrella" }
    elseif ($h.Pop -ge 20) { $s += ", $($h.Pop)% chance of $(if ($h.Temp -le 1) { 'snow' } else { 'rain' })" }
    $s
}

# The dashboard's line: now, the next wet stretch in the next 18 hours, then today's high (after
# 5 pm, tomorrow's high and low). Pieces: Now, Wet, Next.
function Get-JkWeatherLine($W, [datetime]$Now) {
    $cur = $W.Current
    if (-not $cur -or [Math]::Abs(($cur.At - $Now).TotalMinutes) -gt 90) { $cur = Get-JkWeatherHour $W $Now }
    if (-not $cur) { return $null }
    $nowTxt = "$(Format-JkDeg $cur.Temp) $(Get-JkWeatherText $cur.Code)"
    if ([Math]::Abs($cur.Feels - $cur.Temp) -ge 3) { $nowTxt += ", feels $(Format-JkDeg $cur.Feels)" }
    $to = $Now.AddHours(18)
    $wet = ''
    $s = @(Get-JkWetSpells $W $Now $to)[0]
    if ($s) { $wet = Format-JkSpell $s $Now $to (Get-JkSpellDay $s $Now) 'for the next 18 hours' }
    $next = ''
    if ($Now.Hour -lt 17) { $d = Get-JkWeatherDay $W $Now.Date $Now; if ($d) { $next = "high $(Format-JkDeg $d.High)" } }
    else { $d = Get-JkWeatherDay $W $Now.Date.AddDays(1) $Now; if ($d) { $next = "tomorrow $(Format-JkDeg $d.High) / $(Format-JkDeg $d.Low)" } }
    [pscustomobject]@{ Now = $nowTxt; Wet = $wet; Next = $next }
}

# The dashboard's line from the cache only; a stale or missing forecast is fetched in the
# background for next time.
function Get-JkDashWeather([datetime]$Now) {
    $place = Get-JkWeatherPlace -NoLookup
    if (-not $place) {
        if ([string](Get-JkConfig 'weather.place') -notmatch '^(off|none|no|0)$') { Start-JkWeatherRefresh }
        return ''
    }
    $w = Get-JkWeather -Place $place -CacheOnly
    if (-not $w -or $w.Stale) { Start-JkWeatherRefresh }
    if (-not $w) { return '' }
    $l = Get-JkWeatherLine $w (ConvertTo-JkWeatherClock $w $Now)
    if (-not $l) { return '' }
    $sep = Paint 'gray' "  $($script:G.dot)  "
    $parts = @(Paint 'muted' $l.Now)
    if ($l.Wet) { $parts += Paint 'cyan' $l.Wet }
    if ($l.Next) { $parts += Paint 'muted' $l.Next }
    ($parts -join $sep)
}

# The brief's note, only when it matters in the next 12 hours: "rain 2-6 pm", "snow from 9 pm",
# "feels -14" (the kept forecast only: the brief prints as a terminal opens).
function Get-JkBriefWeather([datetime]$Now) {
    $place = Get-JkWeatherPlace -NoLookup
    if (-not $place) { return '' }
    $w = Get-JkWeather -Place $place -CacheOnly -MaxAgeHours 3
    # a terminal opening is a good moment to fetch a fresh one for next time, in the background
    if (-not $w -or $w.Stale) { Start-JkWeatherRefresh }
    if (-not $w) { return '' }
    $Now = ConvertTo-JkWeatherClock $w $Now
    $to = $Now.AddHours(12)
    $s = @(Get-JkWetSpells $w $Now $to)[0]
    if ($s) { return ((Format-JkSpell $s $Now $to (Get-JkSpellDay $s $Now) 'for the next 12 hours') -replace '\s*\([^)]*\)$', '') }
    $next = @($w.Hours | Where-Object { $_.At.AddHours(1) -gt $Now -and $_.At -lt $to })
    if ($next.Count) {
        $cold = ($next | Measure-Object Feels -Minimum).Minimum
        if ($cold -le -10) { return "feels $(Format-JkDeg $cold)" }
    }
    ''
}

# The morning popup's line: "Weather: 4 now, high 9; rain 2-6 pm (80%), take an umbrella".
function Get-JkMorningWeather([datetime]$Now) {
    $place = Get-JkWeatherPlace
    if (-not $place) { return '' }
    $w = Get-JkWeather -Place $place -TimeoutSec 8
    if (-not $w) { return '' }
    $Now = ConvertTo-JkWeatherClock $w $Now
    $d = Get-JkWeatherDay $w $Now.Date $Now
    if (-not $d) { return '' }
    $h = Get-JkWeatherHour $w $Now
    $s = 'Weather: '
    if ($h) { $s += "$(Format-JkDeg $h.Temp) now, " }
    $s += "high $(Format-JkDeg $d.High); $($d.Text)"
    if ($d.Advice.Count) { $s += " $($script:G.dot) $($d.Advice -join ', ')" }
    $s
}

# jk exam's row: the weather when an in-person exam starts, while it is inside the forecast.
function Get-JkExamWeather([datetime]$At) {
    $place = Get-JkWeatherPlace
    if (-not $place) { return '' }
    $w = Get-JkWeather -Place $place -MaxAgeHours 3 -TimeoutSec 4
    if (-not $w) { return '' }
    Get-JkWeatherAtText $w (ConvertTo-JkWeatherClock $w $At)
}

# ---------------------------------------------------------------- jk weather

function Show-JkWeather {
    param($Place, [switch]$NoSave)
    if (-not $Place) { $Place = Get-JkWeatherPlace; if (-not $Place) { $Place = $script:JkWeatherHome } }
    $now = Get-JkNow
    $w = Get-JkWeather -Place $Place -MaxAgeHours 0.5 -NoSave:$NoSave
    if (-not $w) {
        $why = $script:JkWeatherError; if (-not $why) { $why = 'no reply' }
        throw "no forecast for $($Place.Name): $why (jk net checks the connection)"
    }
    $width = Get-JkWidth
    $asOf = "as of $(Format-JkTime $w.Fetched.ToLocalTime().ToString('HH:mm', $script:Inv))"
    if ($w.Stale) { $asOf = "offline: forecast from $($w.Fetched.ToLocalTime().ToString('ddd', $script:Inv)) $(Format-JkTime $w.Fetched.ToLocalTime().ToString('HH:mm', $script:Inv))" }
    Write-JkHeader 'Weather' $asOf -Sub $Place.Name
    $row = { param($k, $v) Say ('  ' + (Paint 'bold white' (Fit $k 10)) + $v) }
    if ($w.Stale) {
        $why = $script:JkWeatherError
        try { $ef = Join-Path (Get-JkCacheDir) 'weather.error'; if (-not $why -and [IO.File]::Exists($ef)) { $why = [IO.File]::ReadAllText($ef).Trim() } } catch { }
        if ($why) { Say (Paint 'gray' "  could not refresh: $why  (jk net checks the connection)") }
    }
    $now = ConvertTo-JkWeatherClock $w $now
    if ($null -ne $w.Offset) {
        $sign = $(if ($w.Offset -lt [TimeSpan]::Zero) { '-' } else { '+' })
        & $row 'clock' (Paint 'muted' "times are local there (UTC$sign$([Math]::Abs($w.Offset.TotalHours))), where it is $(Format-JkTime $now.ToString('HH:mm', $script:Inv)) $($now.ToString('ddd', $script:Inv))")
    }

    $l = Get-JkWeatherLine $w $now
    if ($l) {
        $cur = $w.Current
        if (-not $cur -or [Math]::Abs(($cur.At - $now).TotalMinutes) -gt 90) { $cur = Get-JkWeatherHour $w $now }
        $bits = @($l.Now, "wind $([int]$cur.Wind) km/h")
        $sun = @($w.Sun | Where-Object { $_.At -gt $now })[0]
        if ($sun) { $bits += "$($sun.Kind) $(Format-JkTime $sun.At.ToString('HH:mm', $script:Inv))" }
        & $row 'now' (Paint 'white' ($bits -join "  $($script:G.dot)  "))
    }

    # the next hours: time, temperature, and the chance of rain or snow when any is worth a look
    $cols = [Math]::Max(4, [Math]::Min(12, [int][Math]::Floor(($width - 12) / 6)))
    $next = @($w.Hours | Where-Object { $_.At -gt $now } | Select-Object -First $cols)
    if ($next.Count) {
        Say ''
        $lead = '  ' + (Fit 'next hours' 10)
        Say ($lead + (Paint 'gray' (($next | ForEach-Object { Fit ((Format-JkHour $_.At) -replace ' ', '') 6 -Right }) -join '')))
        Say ((' ' * 12) + (Paint 'white' (($next | ForEach-Object { Fit (Format-JkDeg $_.Temp) 6 -Right }) -join '')))
        if (@($next | Where-Object { $_.Pop -ge 20 }).Count) {
            $cells = foreach ($h in $next) {
                $c = $(if ($h.Pop -ge 20) { "$($h.Pop)%" } else { '' })
                $st = $(if (Test-JkWetHour $h) { 'cyan' } else { 'gray' })
                Paint $st (Fit $c 6 -Right)
            }
            Say ('  ' + (Paint 'gray' (Fit 'rain/snow' 10)) + ($cells -join ''))
        }
    }

    # today and the days ahead
    Say ''
    for ($i = 0; $i -lt 5; $i++) {
        $date = $now.Date.AddDays($i)
        $d = Get-JkWeatherDay $w $date $now
        if (-not $d) { continue }
        $label = $(if ($i -eq 0) { 'today' } elseif ($i -eq 1) { 'tomorrow' } else { $date.ToString('ddd MMM d', $script:Inv) })
        $temps = "$(Format-JkDeg $d.High) / $(Format-JkDeg $d.Low)"
        $text = $d.Text
        if ($d.Advice.Count) { $text += "  $($script:G.arrow) $($d.Advice -join ', ')" }
        $leadTxt = '  ' + (Paint 'bold white' (Fit $label 11)) + (Paint 'white' (Fit $temps 12))
        $style = $(if ($d.Spells.Count) { 'cyan' } else { 'muted' })
        Write-JkTip $leadTxt 25 $text $style -Indent 25
    }

    # exams and appointments to get to while the forecast reaches them (here, not somewhere else)
    $last = @($w.Hours)[-1].At
    $data = Get-JkDueData -Cached
    $cmap = Get-JkCourseMap $data
    $go = @($data.events | Where-Object { $null -eq $w.Offset } | Where-Object { -not $_.done -and $_.time -and $_.kind -in 'exam', 'appt' -and [string]$_.title -notmatch '(?i)\s+(opens?|closes?)$' -and [string]$_.note -notmatch '(?i)\bonline\b' } |
        Where-Object { $due = Get-JkEventDue $_; $due -gt $now -and $due -le $last } | Sort-Object { Get-JkEventDue $_ } | Select-Object -First 3)
    if ($go.Count) {
        Say ''
        foreach ($e in $go) {
            $due = Get-JkEventDue $e
            $txt = Get-JkWeatherAtText $w $due
            if (-not $txt) { continue }
            $lead = "  $(Get-JkCourseLabel $e $cmap) $($e.title), $($due.ToString('ddd', $script:Inv)): "
            Write-JkTip ('  ' + (Paint 'bold white' $lead.Trim()) + ' ') ((Get-JkTextWidth $lead.Trim()) + 3) $txt 'muted' -Indent 4
        }
    }
    Say ''
    Say (Paint 'gray' "  jk weather toronto  $($script:G.dot)  jk weather set <place>  $($script:G.dot)  jk weather off  $($script:G.dot)  forecast: Open-Meteo")
}

function Invoke-JkWeather {
    $a = @($args | ForEach-Object { [string]$_ } | Where-Object { $_ })
    if (-not $a.Count) { Show-JkWeather; return }
    $first = $a[0].ToLower()
    $rest = (@($a | Select-Object -Skip 1) -join ' ').Trim()
    switch -Regex ($first) {
        '^(help|-h|--help|\?)$' { Show-JkHelp weather; return }
        '^(off|hide)$' {
            Set-JkConfig 'weather.place' 'off'
            Say ((Paint 'green' "  weather off: not on the dashboard, in the morning popup or in jk exam") + (Paint 'gray' '  (jk weather set waterloo turns it back on)'))
            return
        }
        '^(set|home|here)$' {
            if (-not $rest) { throw 'usage: jk weather set <place>   e.g. jk weather set toronto, or jk weather set waterloo, on' }
            if ($rest -match '^(?:waterloo|uw|default)$') { Set-JkConfig 'weather.place' ''; $p = $script:JkWeatherHome }
            else { $p = Resolve-JkWeatherPlace $rest; Set-JkConfig 'weather.place' (Format-JkWeatherPlace $p) }
            Say ((Paint 'green' "  $($script:G.check) weather for $($p.Name)") + (Paint 'gray' '  (dashboard, morning popup, jk exam)'))
            Show-JkWeather -Place $p
            return
        }
    }
    # any other words are a place, just this once
    Show-JkWeather -Place (Resolve-JkWeatherPlace ($a -join ' ')) -NoSave
}
