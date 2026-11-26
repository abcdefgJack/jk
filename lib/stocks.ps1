# jk stocks - a watchlist at the US market open: the price, the day's move, the last weeks, and a
# range for the close worked out from how much each one has moved lately, with how often ranges
# like it held and how often the trend called the next day. Prices are Yahoo Finance's chart data
# (delayed, no account, no key), kept in the cache folder. Numbers from past prices only: no tips.

$script:JkStockRx = '^[A-Z0-9][A-Z0-9.\-=^]{0,14}$|^\^[A-Z0-9.]{1,12}$'
$script:JkSpark = @(0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, 0x2588 | ForEach-Object { [string][char]$_ })
$script:JkPm = [string][char]0x00B1
# How wide the ranges are, in typical daily moves (the spread of the last 20). Checked on two years
# of daily closes for every US-listed symbol and the Shanghai, Shenzhen, Hong Kong and Tokyo
# boards (tools/stocks-study), each day against the 20 days before it: 1.28 holds 4 days in 5, as a bell
# curve says; for 19 in 20 the fat tails need 2.3 where the bell curve says 1.96 (that held 92%).
$script:JkStockK = 1.2816
$script:JkStockK2 = 2.3

# ---------------------------------------------------------------- New York time

$script:JkNyZone = $null
function Get-JkNyZone {
    if (-not $script:JkNyZone) { $script:JkNyZone = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time') }
    $script:JkNyZone
}
# this machine's wall clock to New York's and back (the same in Waterloo; not on a trip)
function ConvertTo-JkNyTime([datetime]$Local) { [TimeZoneInfo]::ConvertTime([datetime]::SpecifyKind($Local, 'Unspecified'), [TimeZoneInfo]::Local, (Get-JkNyZone)) }
function ConvertFrom-JkNyTime([datetime]$Ny) { [TimeZoneInfo]::ConvertTime([datetime]::SpecifyKind($Ny, 'Unspecified'), (Get-JkNyZone), [TimeZoneInfo]::Local) }
function ConvertFrom-JkUnixToNy($Unix) { [TimeZoneInfo]::ConvertTimeFromUtc([DateTimeOffset]::FromUnixTimeSeconds([long]$Unix).UtcDateTime, (Get-JkNyZone)) }
# A New York time on the clock of $S's own exchange (Yahoo's gmtoffset: Shanghai is 13 hours on
# in winter), so a day there is named by its own date; with no offset, New York's.
function ConvertTo-JkMarketTime($S, [datetime]$Ny) {
    if ($null -eq $S.Offset) { return $Ny }
    $utc = [TimeZoneInfo]::ConvertTimeToUtc([datetime]::SpecifyKind($Ny, 'Unspecified'), (Get-JkNyZone))
    [datetime]::SpecifyKind($utc.AddSeconds([double]$S.Offset), 'Unspecified')
}

# ---------------------------------------------------------------- the watchlist

function Get-JkStockList {
    $v = ([string](Get-JkConfig 'stocks.watch')).Trim()
    if (-not $v -or $v -match '^(?i:off|none)$') { return @() }
    @($v -split '[;,\s]+' | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() } | Select-Object -Unique)
}

function Save-JkStockList([string[]]$Symbols) {
    $s = @($Symbols | Where-Object { $_ })
    Set-JkConfig 'stocks.watch' $(if ($s.Count) { $s -join ';' } else { 'none' })
}

# "nvda", "shop.to", "^gspc", "btc-usd": the symbol Yahoo knows it by, or $null
function ConvertTo-JkStockSymbol([string]$Word) {
    $w = $Word.Trim().ToUpperInvariant()
    if ($w -cmatch $script:JkStockRx) { return $w }
    $null
}

# ---------------------------------------------------------------- prices

# One GET to Yahoo's chart data: a year of daily bars plus the latest price. A pinned clock (tests,
# previews with JK_NOW) never goes out: its "now" is not the market's.
function Invoke-JkStockGet([string]$Symbol, [int]$TimeoutSec = 10) {
    if ($env:JK_NOW) { throw 'no live prices while JK_NOW pins the clock' }
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $url = 'https://query1.finance.yahoo.com/v8/finance/chart/' + [Uri]::EscapeDataString($Symbol) + '?range=1y&interval=1d'
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) jk' -ErrorAction Stop
    } catch {
        # an unknown symbol is a 404 that says so in its body
        $body = [string]$_.ErrorDetails.Message
        if ($body -match '"description"\s*:\s*"([^"]+)"') { throw "Yahoo has no $Symbol ($($Matches[1].ToLowerInvariant()))" }
        $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if ($code -eq 404) { throw "Yahoo has no $Symbol" }
        throw
    }
    [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
}

# The reply read: daily closes by the exchange's own date (one a day, the last kept), the latest
# price and the session Yahoo names (today's once it is near, else the last one). Yahoo can leave
# the last day's close empty once the session is over (Shanghai does): the latest price is it.
function ConvertFrom-JkStockJson([string]$Text, [string]$Symbol) {
    $j = ConvertFrom-Json $Text
    if ($j.chart.error) { throw "Yahoo has no $Symbol ($(([string]$j.chart.error.description).ToLowerInvariant()))" }
    $res = @($j.chart.result)[0]
    if (-not $res -or -not $res.meta) { throw "no prices for $Symbol" }
    $m = $res.meta
    $q = @($res.indicators.quote)[0]
    $ts = @($res.timestamp)
    $off = $(if ($null -ne $m.gmtoffset) { [double]$m.gmtoffset } else { $null })
    $byDay = [ordered]@{}
    for ($i = 0; $i -lt $ts.Count; $i++) {
        $c = $q.close[$i]
        if ($null -eq $c -and $i -eq $ts.Count - 1 -and $null -ne $m.regularMarketPrice -and [long]$m.regularMarketTime -ge [long]$ts[$i]) { $c = $m.regularMarketPrice }
        if ($null -eq $c) { continue }
        $d = $(if ($null -ne $off) { [DateTimeOffset]::FromUnixTimeSeconds([long]$ts[$i] + [long]$off).UtcDateTime.Date } else { (ConvertFrom-JkUnixToNy $ts[$i]).Date })
        $byDay[$d.ToString('yyyy-MM-dd', $script:Inv)] = [pscustomobject]@{ Date = $d; Close = [double]$c }
    }
    $bars = @($byDay.Values)
    if (-not $bars.Count) { throw "no prices for $Symbol" }
    $reg = $m.currentTradingPeriod.regular
    $price = $(if ($null -ne $m.regularMarketPrice) { [double]$m.regularMarketPrice } else { $bars[-1].Close })
    $name = [string]$m.longName; if (-not $name) { $name = [string]$m.shortName }
    [pscustomobject]@{
        Symbol = $(if ($m.symbol) { ([string]$m.symbol).ToUpperInvariant() } else { $Symbol })
        Name = $name.Trim(); Currency = [string]$m.currency; Exchange = [string]$m.fullExchangeName
        Price = $price; PriceAt = $(if ($m.regularMarketTime) { ConvertFrom-JkUnixToNy $m.regularMarketTime } else { $bars[-1].Date })
        Open = $(if ($reg) { ConvertFrom-JkUnixToNy $reg.start } else { $null }); Close = $(if ($reg) { ConvertFrom-JkUnixToNy $reg.end } else { $null })
        High52 = $(if ($null -ne $m.fiftyTwoWeekHigh) { [double]$m.fiftyTwoWeekHigh } else { ($bars | Measure-Object Close -Maximum).Maximum })
        Low52 = $(if ($null -ne $m.fiftyTwoWeekLow) { [double]$m.fiftyTwoWeekLow } else { ($bars | Measure-Object Close -Minimum).Minimum })
        Bars = $bars; Fetched = [datetime]::MinValue; Stale = $false; Offset = $off
    }
}

function Get-JkStockCachePath([string]$Symbol) {
    $dir = Join-Path (Get-JkCacheDir) 'stocks'
    if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    Join-Path $dir (($Symbol -replace '[^A-Za-z0-9.\-=]', '_') + '.json')
}

# $Symbol's prices: the cached copy while it is under $MaxAgeMinutes old, else a fresh one. Offline,
# the kept copy comes back marked Stale; with none, $null and the reason in $script:JkStockError.
# Under a pinned clock the kept copy is the market (tests and previews seed it).
function Get-JkStock {
    param([string]$Symbol, [double]$MaxAgeMinutes = 5, [switch]$CacheOnly, [int]$TimeoutSec = 10)
    $script:JkStockError = ''
    $file = Get-JkStockCachePath $Symbol
    $text = $null; $fetched = [datetime]::MinValue
    try {
        if ([IO.File]::Exists($file)) {
            $t = [IO.File]::ReadAllText($file)
            $nl = $t.IndexOf("`n")
            if ($nl -gt 0) { $fetched = [DateTimeOffset]::Parse($t.Substring(0, $nl).Trim(), $script:Inv).UtcDateTime; $text = $t.Substring($nl + 1) }
        }
    } catch { $text = $null }
    $fresh = $text -and ($env:JK_NOW -or ([DateTime]::UtcNow - $fetched).TotalMinutes -lt $MaxAgeMinutes)
    if ($fresh -or ($text -and $CacheOnly)) {
        try { $s = ConvertFrom-JkStockJson $text $Symbol; $s.Fetched = $fetched; $s.Stale = -not $fresh; return $s } catch { $text = $null }
    }
    if (-not $CacheOnly) {
        try {
            $new = Invoke-JkStockGet $Symbol $TimeoutSec
            $at = [DateTime]::UtcNow
            # read before it is kept: a garbled reply is never cached
            $s = ConvertFrom-JkStockJson $new $Symbol
            $s.Fetched = $at
            try { Write-JkText $file ($at.ToString('o', $script:Inv) + "`n" + $new) } catch { }
            return $s
        } catch { $script:JkStockError = $_.Exception.Message }
    }
    if ($text) { try { $s = ConvertFrom-JkStockJson $text $Symbol; $s.Fetched = $fetched; $s.Stale = $true; return $s } catch { } }
    if (-not $script:JkStockError) { $script:JkStockError = "no prices kept for $Symbol" }
    $null
}

# ---------------------------------------------------------------- the numbers

function Get-JkStdDev([double[]]$X) {
    $n = $X.Count
    if ($n -lt 2) { return 0.0 }
    $mean = 0.0; foreach ($v in $X) { $mean += $v }; $mean /= $n
    $ss = 0.0; foreach ($v in $X) { $ss += ($v - $mean) * ($v - $mean) }
    [Math]::Sqrt($ss / ($n - 1))
}

# Where the market is for $S at $Now: 'open', 'after' (today's session is over), 'pre' (today's
# is still to come) or 'idle' (no session today that Yahoo has named: a weekend, a holiday, the
# night before Yahoo moves on to the new day).
function Get-JkStockState($S, [datetime]$Now) {
    if (-not $S.Open) { return 'idle' }
    $ny = ConvertTo-JkNyTime $Now
    # "today" is the exchange's: Shanghai's Friday session opens on a Thursday evening in New York
    $today = (ConvertTo-JkMarketTime $S $ny).Date
    $open = ConvertTo-JkMarketTime $S $S.Open
    if ($open.Date -ne $today) {
        # Yahoo can name yesterday's session for a while into the day: a price traded today after
        # the open says today's is on (hours as usual; a half day shows once Yahoo catches up)
        $at = $(if ($S.PriceAt -is [datetime]) { ConvertTo-JkMarketTime $S $S.PriceAt } else { $null })
        if ($at -and $at.Date -eq $today -and $at.TimeOfDay -ge $open.TimeOfDay -and $open.Date -lt $today) {
            $days = ($today - $open.Date).Days
            $S.Open = $S.Open.AddDays($days); $S.Close = $S.Close.AddDays($days)
        } else { return 'idle' }
    }
    if ($ny -lt $S.Open) { return 'pre' }
    if ($ny -lt $S.Close) { return 'open' }
    'after'
}

# How far a day may move on its exchange: Shanghai and Shenzhen stop a stock at 10% from the last
# close, 20% on the ChiNext and STAR boards (300/301, 688/689), 5% for one marked ST. 0: no limit.
function Get-JkStockLimit($S) {
    $sym = [string]$S.Symbol
    if ($sym -notmatch '^(\d{6})\.(SS|SZ)$') { return 0.0 }
    if ($Matches[1] -match '^(300|301|688|689)') { return 0.20 }
    if ([string]$S.Name -match '(^|[^A-Za-z])\*?ST([^A-Za-z]|$)') { return 0.05 }
    0.10
}

# Everything the screens say about one symbol. Settled closes are the days before today's session
# once it has begun; the range is for the next close after them (today's, or the next day's), the
# usual daily move being the spread of the last 20 daily changes. The record walks the last 120
# days: did each day's close land inside the range the 20 days before it gave, and did "above its
# 20-day average" call the next day up (and below it, down)?
function Get-JkStockStats($S, [datetime]$Now, [int]$Window = 20, [int]$Back = 120) {
    $state = Get-JkStockState $S $Now
    $bars = @($S.Bars)
    $live = $state -in 'open', 'after'
    $sessionDay = $(if ($live) { (ConvertTo-JkMarketTime $S $S.Open).Date } else { $null })
    $settled = @($bars | Where-Object { -not $live -or $_.Date -lt $sessionDay })
    $c = [double[]]@($settled | ForEach-Object { $_.Close })
    $n = $c.Count
    $ret = New-Object 'double[]' ([Math]::Max(0, $n - 1))
    for ($i = 1; $i -lt $n; $i++) { $ret[$i - 1] = [Math]::Log($c[$i] / $c[$i - 1]) }
    $ref = $(if ($n) { $c[$n - 1] } else { $S.Price })
    # the latest price: today's while it trades, else the last close
    $price = $(if ($live) { $S.Price } else { $ref })
    $all = [double[]]@(@($c) + $(if ($live) { @($S.Price) } else { @() }))
    $m = $all.Count
    $chg = { param([int]$k) if ($m -gt $k) { $all[$m - 1] / $all[$m - 1 - $k] - 1 } else { $null } }
    $day = $(if ($live) { & $chg 1 } elseif ($n -ge 2) { $c[$n - 1] / $c[$n - 2] - 1 } else { $null })
    $sig = $(if ($ret.Count -ge 5) { Get-JkStdDev ([double[]]@($ret | Select-Object -Last $Window)) } else { 0.0 })
    $sigBefore = $(if ($ret.Count -ge 2 * $Window) { Get-JkStdDev ([double[]]@($ret | Select-Object -Last (2 * $Window) | Select-Object -First $Window)) } else { 0.0 })
    $avg = $(if ($n -ge $Window) { ([double[]]@($c | Select-Object -Last $Window) | Measure-Object -Average).Average } else { 0.0 })
    # the record
    $tried = 0; $held = 0; $calls = 0; $right = 0; $ups = 0
    $from = [Math]::Max($Window + 1, $n - $Back)
    for ($t = $from; $t -lt $n; $t++) {
        # day t's change is ret[t-1]; the 20 changes before it are ret[t-1-Window .. t-2]
        $prior = New-Object 'double[]' $Window
        [Array]::Copy($ret, $t - 1 - $Window, $prior, 0, $Window)
        $st = Get-JkStdDev $prior
        if ($st -le 0) { continue }
        $tried++
        if ([Math]::Abs($ret[$t - 1]) -le $script:JkStockK * $st) { $held++ }
        if ($ret[$t - 1] -gt 0) { $ups++ }
        $sum = 0.0; for ($k = $t - $Window; $k -lt $t; $k++) { $sum += $c[$k] }
        $mean = $sum / $Window
        if ($c[$t - 1] -ne $mean -and $ret[$t - 1] -ne 0) {
            $calls++
            if (($c[$t - 1] -gt $mean) -eq ($ret[$t - 1] -gt 0)) { $right++ }
        }
    }
    $spread = $script:JkStockK * $sig; $spread2 = $script:JkStockK2 * $sig
    $lo = $ref * [Math]::Exp(-$spread); $hi = $ref * [Math]::Exp($spread)
    $lo2 = $ref * [Math]::Exp(-$spread2); $hi2 = $ref * [Math]::Exp($spread2)
    # no range past the day's limit: the exchange stops the price there
    $limit = Get-JkStockLimit $S
    if ($limit -gt 0) {
        $floor = $ref * (1 - $limit); $cap = $ref * (1 + $limit)
        $lo = [Math]::Max($lo, $floor); $hi = [Math]::Min($hi, $cap); $lo2 = [Math]::Max($lo2, $floor); $hi2 = [Math]::Min($hi2, $cap)
    }
    [pscustomobject]@{
        Symbol = $S.Symbol; State = $state; Price = $price; Ref = $ref; RefDay = $(if ($n) { $settled[-1].Date } else { $null })
        Day = $day; D5 = & $chg 5; D21 = & $chg 21; D63 = & $chg 63; Year = $(if ($m -ge 2) { $all[$m - 1] / $all[0] - 1 } else { $null })
        Sigma = $sig; SigmaBefore = $sigBefore; Avg20 = $avg; Spread = $spread
        Lo = $lo; Hi = $hi; Lo2 = $lo2; Hi2 = $hi2; Limit = $limit
        Inside = $(if ($live -and $sig -gt 0) { $price -ge $lo -and $price -le $hi } else { $null })
        Trend = $(if ($avg -le 0) { 0 } elseif ($price -gt $avg) { 1 } elseif ($price -lt $avg) { -1 } else { 0 })
        Tried = $tried; Held = $held; Calls = $calls; Right = $right; Ups = $ups
        Closes = $all
    }
}

# ---------------------------------------------------------------- words and marks

function Format-JkPrice([double]$P) {
    if ([Math]::Abs($P) -ge 1000) { return $P.ToString('#,0.00', $script:Inv) }
    if ([Math]::Abs($P) -lt 1) { return $P.ToString('0.0000', $script:Inv) }
    $P.ToString('0.00', $script:Inv)
}

function Format-JkStockPct($X, [int]$Digits = 1) {
    if ($null -eq $X) { return '' }
    $f = '+0.' + ('0' * $Digits) + '%;-0.' + ('0' * $Digits) + '%;0.' + ('0' * $Digits) + '%'
    ([double]$X).ToString($f, $script:Inv)
}

function Get-JkPctStyle($X) { if ($null -eq $X -or [double]$X -eq 0) { 'gray' } elseif ([double]$X -gt 0) { 'green' } else { 'red' } }

function Get-JkSparkline([double[]]$Values, [int]$Width = 20) {
    $v = @($Values | Select-Object -Last $Width)
    if ($v.Count -lt 2) { return '' }
    $min = ($v | Measure-Object -Minimum).Minimum; $max = ($v | Measure-Object -Maximum).Maximum
    $span = [double]$max - [double]$min
    -join @(foreach ($x in $v) { if ($span -le 0) { $script:JkSpark[3] } else { $script:JkSpark[[int][Math]::Floor(([double]$x - $min) / $span * 7.999)] } })
}

function Format-JkPctOf([int]$Part, [int]$Whole) { if ($Whole -le 0) { return '' } ; '{0}%' -f [int][Math]::Round(100.0 * $Part / $Whole) }

# Which market a symbol trades on, in words: Toronto stays open on US Thanksgiving.
function Get-JkMarketName($S) {
    $e = [string]$S.Exchange
    if (-not $e -or $e -match '^(?i:nyse|nasdaq|bats|cboe|snp|dji|nyq|nms|pcx|ase|opr)') { return 'US market' }
    if ($e -eq 'CCC') { return 'crypto' }
    if ($e -match '^(?i:hkse|hkg)') { return 'Hong Kong market' }
    "$e market"
}

# What the market is doing, for the header.
function Get-JkMarketWords($S, [datetime]$Now) {
    $state = Get-JkStockState $S $Now
    $mk = Get-JkMarketName $S
    $loc = { param($ny) Format-JkTime ((ConvertFrom-JkNyTime $ny).ToString('HH:mm', $script:Inv)) }
    switch ($state) {
        'open' { return "$mk open until $(& $loc $S.Close)" }
        'after' { return "$mk closed at $(& $loc $S.Close)" }
        'pre' { return "$mk opens at $(& $loc $S.Open)" }
    }
    $mt = ConvertTo-JkMarketTime $S (ConvertTo-JkNyTime $Now)
    if ($mt.DayOfWeek -in 'Saturday', 'Sunday') { return "$mk closed for the weekend" }
    # past the open (on the exchange's clock) with fresh prices and still no session today: a holiday
    $opensAt = $(if ($S.Open) { (ConvertTo-JkMarketTime $S $S.Open).TimeOfDay } else { [TimeSpan]'09:30:00' })
    if (-not $S.Stale -and $mt.TimeOfDay -ge $opensAt.Add([TimeSpan]'00:01:00')) { return "$mk closed today" }
    "last close $($S.Bars[-1].Date.ToString('ddd MMM d', $script:Inv))"
}

# The record across the list, as two sentences: how often ranges like these held, and how often
# the trend called the next day (next to a coin and to "it goes up", which stocks do on just over
# half of days).
function Get-JkStockRecordLines($All) {
    $tried = 0; $held = 0; $calls = 0; $right = 0; $ups = 0
    foreach ($x in @($All)) { $tried += $x.Tried; $held += $x.Held; $calls += $x.Calls; $right += $x.Right; $ups += $x.Ups }
    if ($tried -lt 20) { return @() }
    $days = [int][Math]::Round([double]$tried / [Math]::Max(1, @($All).Count))
    $hitPct = 100.0 * $held / $tried
    $callPct = $(if ($calls) { 100.0 * $right / $calls } else { 0.0 })
    $upPct = 100.0 * $ups / $tried
    $verdict = $(if ($calls -lt 20) { 'too few days to tell' } elseif ([Math]::Abs($callPct - 50) -lt 5) { 'a coin flip, so read it as noise' } elseif ($callPct -gt 50) { 'a little better than a coin, over few days' } else { 'worse than a coin' })
    @(
        "Ranges like these held on $([int][Math]::Round($hitPct))% of the last $days days (aim: 80%, 4 in 5)",
        "The trend called the next day $([int][Math]::Round($callPct))% of the time (a coin: 50%; up days: $([int][Math]::Round($upPct))%): $verdict"
    )
}

$script:JkStockFoot = 'From past prices only, not advice ' + [string][char]0x00B7 + ' Yahoo Finance, delayed'

# ---------------------------------------------------------------- the screens

function Get-JkStocksFor([string[]]$Symbols, [double]$MaxAgeMinutes = 5) {
    $out = @()
    foreach ($sym in $Symbols) {
        $s = Get-JkStock $sym -MaxAgeMinutes $MaxAgeMinutes
        $out += [pscustomobject]@{ Symbol = $sym; Stock = $s; Error = $script:JkStockError }
    }
    $out
}

function Show-JkStocks {
    param([string[]]$Symbols = @(), [double]$MaxAgeMinutes = 5)
    $now = Get-JkNow
    $syms = @($Symbols | Where-Object { $_ })
    if (-not $syms.Count) { $syms = @(Get-JkStockList) }
    if (-not $syms.Count) {
        Write-JkHeader 'Stocks'
        Say ('  ' + (Paint 'gray' 'nothing on the watchlist: ') + 'jk stocks add SPY QQQ NVDA')
        Say ''
        return
    }
    $got = @(Get-JkStocksFor $syms $MaxAgeMinutes)
    # each market on the list once, in list order, while they fit: one says "US market open until
    # 4:00 pm"; with more, "US open until 4:00 pm, Shanghai opens at 8:30 pm"
    $right = $now.ToString('ddd MMM d', $script:Inv)
    $words = @(); $seen = @{}
    foreach ($g in @($got | Where-Object { $_.Stock })) {
        $mk = Get-JkMarketName $g.Stock
        if ($seen.ContainsKey($mk)) { continue }
        $seen[$mk] = 1
        $words += , (Get-JkMarketWords $g.Stock $now)
    }
    if ($words.Count -gt 1) { $words = @($words | ForEach-Object { $_ -replace '^(.+?) market ', '$1 ' }) }
    foreach ($wd in $words) {
        $more = " $($script:G.dot) $wd"
        if ($right.Length -gt 10 -and $right.Length + $more.Length + 12 -gt (Get-JkWidth)) { break }
        $right += $more
    }
    Write-JkHeader 'Stocks' -Right $right
    $w = Get-JkWidth
    $stats = @()
    foreach ($g in $got) {
        if (-not $g.Stock) {
            Say ('  ' + (Paint 'bold white' (Fit $g.Symbol 9)) + (Paint 'yellow' "no prices: $($g.Error)"))
            continue
        }
        $s = $g.Stock
        $x = Get-JkStockStats $s $now
        $stats += $x
        $cur = $(if ($s.Currency -and $s.Currency -ne 'USD') { " $($s.Currency)" } else { '' })
        $line = '  ' + (Paint 'bold white' (Fit $s.Symbol 9)) + (Fit ((Format-JkPrice $x.Price) + $cur) 13 -Right) + '  ' + (Paint (Get-JkPctStyle $x.Day) (Fit (Format-JkStockPct $x.Day 2) 8 -Right))
        $tail = ''
        foreach ($p in @(@('5d', $x.D5), @('1m', $x.D21), @('3m', $x.D63), @('1y', $x.Year))) {
            if ($null -ne $p[1]) { $tail += '   ' + (Paint 'gray' $p[0]) + ' ' + (Paint (Get-JkPctStyle $p[1]) (Format-JkStockPct $p[1])) }
        }
        $spark = Get-JkSparkline $x.Closes 20
        if ((Get-JkVisibleLength ($line + $tail)) + 24 -le $w) { $tail += '   ' + (Paint 'gray' $spark) }
        Say ($line + $tail)
        Say ('           ' + (Get-JkStockRangeText $x $s))
    }
    $rec = @(Get-JkStockRecordLines $stats)
    Say (Paint 'gray dim' (' ' + ($script:G.hline * ($w - 1))))
    foreach ($l in $rec) { Say ('  ' + (Paint 'gray' $l)) }
    $stale = @($got | Where-Object { $_.Stock -and $_.Stock.Stale })
    if ($stale.Count) { Say ('  ' + (Paint 'yellow' "offline: prices kept from $((($stale[0].Stock.Fetched).ToLocalTime()).ToString('ddd h:mm tt', $script:Inv).ToLowerInvariant())")) }
    $hint = $(if ((Get-JkStockList).Count -le 2) { ' ' + $script:G.dot + ' jk stocks add NVDA' } else { ' ' + $script:G.dot + ' jk stocks SPY for one' })
    Say ('  ' + (Paint 'gray dim' ($script:JkStockFoot + $hint)))
    Say ''
}

# The second line of a symbol: the range for the close and where the price is against it.
function Get-JkStockRangeText($X, $S, [switch]$Plain) {
    $p = { param($style, $t) if ($Plain) { $t } else { Paint $style $t } }
    if ($X.Sigma -le 0) { return (& $p 'gray' 'too few days of prices for a range') }
    $rng = "$(Format-JkPrice $X.Lo) - $(Format-JkPrice $X.Hi)"
    $pm = "$script:JkPm$(Format-JkStockPct $X.Spread | ForEach-Object { $_.TrimStart('+') })"
    $trend = $(switch ($X.Trend) { 1 { "above its 20-day average $($script:G.up)" } -1 { "below its 20-day average $($script:G.down)" } default { 'at its 20-day average' } })
    switch ($X.State) {
        'open' {
            $where = $(if ($X.Inside) { & $p 'green' 'inside so far' } elseif ($X.Price -gt $X.Hi) { & $p 'yellow' 'above it so far' } else { & $p 'yellow' 'below it so far' })
            return (& $p 'gray' "close likely $rng ($pm, 4 days in 5) ") + $where + (& $p 'gray' " $($script:G.dot) $trend")
        }
        'after' {
            $where = $(if ($X.Inside) { & $p 'green' "closed inside $($script:G.check)" } elseif ($X.Price -gt $X.Hi) { & $p 'yellow' 'closed above it' } else { & $p 'yellow' 'closed below it' })
            return (& $p 'gray' "the range was $rng ($pm) ") + $where + (& $p 'gray' " $($script:G.dot) $trend")
        }
    }
    & $p 'gray' "next close likely $rng ($pm, 4 days in 5) $($script:G.dot) $trend"
}

# One symbol on a screen: the moves, the year's high and low, how lively it has been, the ranges
# for the next close and the next week, the record, and the last ten days against their ranges.
function Show-JkStock([string]$Symbol) {
    $now = Get-JkNow
    $s = Get-JkStock $Symbol
    if (-not $s) { throw "no prices for ${Symbol}: $script:JkStockError" }
    $x = Get-JkStockStats $s $now
    $sub = $s.Name
    Write-JkHeader $s.Symbol -Sub $sub -Right "$($s.Currency) $($script:G.dot) $(Get-JkMarketWords $s $now)"
    $row = { param($k, $v) Say ('  ' + (Paint 'gray' (Fit $k 12)) + $v) }
    $dayWord = $(switch ($x.State) { 'open' { 'today so far' } 'after' { 'today' } default { "on $($x.RefDay.ToString('ddd MMM d', $script:Inv))" } })
    & $row 'price' ((Paint 'bold white' (Format-JkPrice $x.Price)) + '  ' + (Paint (Get-JkPctStyle $x.Day) (Format-JkStockPct $x.Day 2)) + (Paint 'gray' " $dayWord"))
    $moves = @()
    foreach ($p in @(@('5 days', $x.D5), @('1 month', $x.D21), @('3 months', $x.D63), @('1 year', $x.Year))) {
        if ($null -ne $p[1]) { $moves += (Paint 'gray' "$($p[0]) ") + (Paint (Get-JkPctStyle $p[1]) (Format-JkStockPct $p[1])) }
    }
    & $row 'moved' ($moves -join '   ')
    $off = $(if ($s.High52 -gt 0) { 1 - $x.Price / $s.High52 } else { 0 })
    $offText = $(if ($off -le 0.005) { 'at its high' } else { "$(Format-JkStockPct $off | ForEach-Object { $_.TrimStart('+') }) below the high" })
    & $row '52 weeks' ("$(Format-JkPrice $s.Low52) - $(Format-JkPrice $s.High52)" + (Paint 'gray' "  $offText"))
    if ($x.Sigma -gt 0) {
        $lively = ''
        if ($x.SigmaBefore -gt 0) {
            $r = $x.Sigma / $x.SigmaBefore
            $lively = $(if ($r -ge 1.25) { ', livelier than the 20 days before' } elseif ($r -le 0.8) { ', calmer than the 20 days before' } else { ', about as before' })
        }
        & $row 'a day' ("$script:JkPm$((Format-JkStockPct $x.Sigma 2).TrimStart('+'))" + (Paint 'gray' " a typical move (the last 20 days$lively)"))
        $nextWord = $(if ($x.State -in 'open', 'after') { 'today' } else { 'next close' })
        & $row $nextWord ("$(Format-JkPrice $x.Lo) - $(Format-JkPrice $x.Hi)" + (Paint 'gray' ' (4 days in 5)    ') + "$(Format-JkPrice $x.Lo2) - $(Format-JkPrice $x.Hi2)" + (Paint 'gray' ' (19 in 20)'))
        $wk = $x.Spread * [Math]::Sqrt(5.0)
        if ($x.Limit -gt 0) { & $row 'day limit' ("$script:JkPm$([int][Math]::Round(100 * $x.Limit))%" + (Paint 'gray' " $(Format-JkPrice ($x.Ref * (1 - $x.Limit))) - $(Format-JkPrice ($x.Ref * (1 + $x.Limit))), where the exchange stops it")) }
        & $row 'a week out' ("$(Format-JkPrice ($x.Ref * [Math]::Exp(-$wk))) - $(Format-JkPrice ($x.Ref * [Math]::Exp($wk)))" + (Paint 'gray' " $script:JkPm$((Format-JkStockPct $wk).TrimStart('+')), 4 in 5"))
    }
    if ($x.Avg20 -gt 0) {
        $tw = $(switch ($x.Trend) { 1 { "above its 20-day average ($(Format-JkPrice $x.Avg20)) $($script:G.up)" } -1 { "below its 20-day average ($(Format-JkPrice $x.Avg20)) $($script:G.down)" } default { 'at its 20-day average' } })
        $rec = $(if ($x.Calls) { Paint 'gray' "  called the next day $(Format-JkPctOf $x.Right $x.Calls) of $($x.Calls) days" } else { '' })
        & $row 'trend' ($tw + $rec)
    }
    if ($x.Tried) { & $row 'ranges held' ((Format-JkPctOf $x.Held $x.Tried) + (Paint 'gray' " of the last $($x.Tried) days (aim: 80%)")) }
    & $row '6 months' (Paint 'blue' (Get-JkSparkline $x.Closes ([Math]::Min(63, [Math]::Max(20, (Get-JkWidth) - 20)))))
    # the last ten settled days, each against the range the 20 days before it gave
    $sessionDay = (ConvertTo-JkMarketTime $s $s.Open).Date
    $bars = @($s.Bars | Where-Object { $x.State -notin 'open', 'after' -or $_.Date -lt $sessionDay })
    $c = [double[]]@($bars | ForEach-Object { $_.Close })
    $n = $c.Count
    if ($n -ge 32) {
        Say ''
        Say ('  ' + (Paint 'gray' 'the last 10 days against their ranges'))
        for ($t = $n - 10; $t -lt $n; $t++) {
            $prior = [double[]]@(for ($k = $t - 20; $k -lt $t; $k++) { [Math]::Log($c[$k] / $c[$k - 1]) })
            $st = Get-JkStdDev $prior
            $lo = $c[$t - 1] * [Math]::Exp(-$script:JkStockK * $st); $hi = $c[$t - 1] * [Math]::Exp($script:JkStockK * $st)
            $ok = $c[$t] -ge $lo -and $c[$t] -le $hi
            $mark = $(if ($ok) { Paint 'green' $script:G.check } else { Paint 'yellow' $script:G.cross })
            $chg = $c[$t] / $c[$t - 1] - 1
            Say ('   ' + (Paint 'gray' (Fit $bars[$t].Date.ToString('ddd MMM d', $script:Inv) 12)) + (Fit (Format-JkPrice $c[$t]) 11 -Right) + '  ' + (Paint (Get-JkPctStyle $chg) (Fit (Format-JkStockPct $chg 2) 8 -Right)) + (Paint 'gray' "   $(Format-JkPrice $lo) - $(Format-JkPrice $hi)  ") + $mark)
        }
    }
    if ($s.Stale) { Say ('  ' + (Paint 'yellow' "offline: prices kept from $(($s.Fetched.ToLocalTime()).ToString('ddd h:mm tt', $script:Inv).ToLowerInvariant())")) }
    Say ('  ' + (Paint 'gray dim' $script:JkStockFoot))
    Say ''
}

# ---------------------------------------------------------------- the 9:30 popup

# When the morning stock popup comes: stocks.time (HH:mm on this machine's clock), or by default
# 40 seconds after the US open (9:30 in New York, wherever this PC is), so the first prices are in.
function Get-JkStocksAlertTime([datetime]$Day) {
    $t = ([string](Get-JkConfig 'stocks.time')).Trim()
    if ($t -match '^(?i:off|none|0)$') { return $null }
    if ($t -match '^(\d{1,2}):(\d{2})$' -and [int]$Matches[1] -lt 24 -and [int]$Matches[2] -lt 60) { return $Day.Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2]) }
    $nyDay = (ConvertTo-JkNyTime $Day.Date.AddHours(12)).Date
    ConvertFrom-JkNyTime ($nyDay.AddHours(9).AddMinutes(30).AddSeconds(40))
}

# Run by the morning task (and at sign-in): on a weekday with a watchlist, one popup at the open.
# A PC that wakes after the open gets it a minute later; one that wakes after the close, none.
# The key goes into the day's "alerted" list, so a cancelled one stays cancelled.
function Register-JkStocksAlert {
    param([datetime]$Now = (Get-JkNow))
    if (-not @(Get-JkStockList).Count) { return $null }
    $at = Get-JkStocksAlertTime $Now
    if (-not $at) { return $null }
    $ny = ConvertTo-JkNyTime $Now
    if ($ny.DayOfWeek -in 'Saturday', 'Sunday') { return $null }
    $closeAt = ConvertFrom-JkNyTime ($ny.Date.AddHours(16))
    if ($Now -ge $closeAt) { return $null }
    if ($at -le $Now) { $at = $Now.AddMinutes(1) }
    $today = $Now.ToString('yyyy-MM-dd', $script:Inv)
    $key = "stocks:$today"
    $lock = Enter-JkReminderLock
    try {
        $rd = Get-JkReminderData
        $alerted = @(@(Get-JkProp $rd 'alerted' @()) | Where-Object { ([string]$_).Contains($today) })
        if ($alerted -contains $key -or @($rd.items | Where-Object { [string](Get-JkProp $_ 'key' '') -eq $key }).Count) { return $null }
        $r = New-JkReminder -At $at -Text 'Stocks at the open' -Key $key
        $rd = Get-JkReminderData
        Set-JkProp $rd 'alerted' @($alerted + $key)
        Save-JkReminderData $rd
        return $r
    } finally { Exit-JkReminderLock $lock }
}

# The popup's title and lines, or $null when there is nothing to say (no list; no session today
# because of a holiday). Just woken, the Wi-Fi can take a while: a few tries before it gives up.
function Get-JkStocksPopup {
    param([datetime]$Now = (Get-JkNow), [int]$Tries = 3, [int]$Show = 6)
    $syms = @(Get-JkStockList)
    if (-not $syms.Count) { return $null }
    $got = @()
    for ($try = 0; $try -lt $Tries; $try++) {
        if ($try) { Start-Sleep -Seconds 15 }
        $got = @(Get-JkStocksFor $syms 1)
        if (@($got | Where-Object { $_.Stock -and -not $_.Stock.Stale }).Count) { break }
    }
    $ok = @($got | Where-Object { $_.Stock })
    if (-not $ok.Count) { return [pscustomobject]@{ Title = 'Stocks: no prices'; Lines = @("Could not reach Yahoo Finance: $($got[0].Error)", 'jk stocks tries again') } }
    # fresh prices and no session today anywhere on the list: a market holiday, nothing to report
    $trading = @($ok | Where-Object { (Get-JkStockState $_.Stock $Now) -ne 'idle' })
    if (-not $trading.Count -and -not @($ok | Where-Object { $_.Stock.Stale }).Count) { return $null }
    $first = $(if ($trading.Count) { $trading[0].Stock } else { $ok[0].Stock })
    $state = Get-JkStockState $first $Now
    $lines = @(); $stats = @()
    foreach ($g in @($ok | Select-Object -First $Show)) {
        $x = Get-JkStockStats $g.Stock $Now
        $stats += $x
        $l = "$($x.Symbol) $(Format-JkPrice $x.Price) $(Format-JkStockPct $x.Day 2)"
        if ($x.Sigma -gt 0) {
            $l += " $($script:G.dot) close likely $(Format-JkPrice $x.Lo)-$(Format-JkPrice $x.Hi)"
            if ($x.State -eq 'after') { $l += $(if ($x.Inside) { ", closed inside" } else { ', closed outside' }) }
            $l += $(switch ($x.Trend) { 1 { " $($script:G.up)" } -1 { " $($script:G.down)" } default { '' } })
        }
        $lines += $l
    }
    if ($ok.Count -gt $Show) { $lines += "+$($ok.Count - $Show) more: jk stocks" }
    foreach ($b in @($got | Where-Object { -not $_.Stock })) { $lines += "$($b.Symbol): no prices" }
    $rec = @(Get-JkStockRecordLines $stats)
    if ($rec.Count) { $lines += ($rec[0] -replace '^Ranges like these held on', 'Ranges held') }
    $lines += $script:JkStockFoot
    $title = $(switch ($state) { 'open' { "Stocks at the open $($script:G.dot) $($Now.ToString('ddd MMM d', $script:Inv))" } 'after' { 'Stocks: today''s close' } 'pre' { 'Stocks before the open' } default { 'Stocks' } })
    [pscustomobject]@{ Title = $title; Lines = $lines }
}

# ---------------------------------------------------------------- the command

function Add-JkStocks([string[]]$Words) {
    if (-not $Words.Count) { throw 'usage: jk stocks add <symbol> ...   e.g. jk stocks add NVDA SHOP.TO ^GSPC' }
    $list = @(Get-JkStockList)
    $added = @()
    foreach ($w in $Words) {
        $sym = ConvertTo-JkStockSymbol $w
        if (-not $sym) { throw "'$w' is not a ticker symbol (letters, digits, . - ^ =, as in BRK-B or SHOP.TO)" }
        if ($list -contains $sym) { Say (Paint 'gray' "  $sym is already on the list"); continue }
        $s = Get-JkStock $sym -MaxAgeMinutes 0
        if (-not $s -and $script:JkStockError -match '^Yahoo has no') { throw $script:JkStockError }
        $list += $sym; $added += $sym
        if ($s) { Say ((Paint 'green' "  $($script:G.check) $sym") + (Paint 'gray' " $($s.Name) $($script:G.dot) $(Format-JkPrice $s.Price) $($s.Currency)")) }
        else { Say ((Paint 'green' "  $($script:G.check) $sym") + (Paint 'yellow' " (not checked: $script:JkStockError)")) }
    }
    if ($added.Count) { Save-JkStockList $list }
    Say (Paint 'gray' "  watching $($list -join ', ')")
}

function Remove-JkStocks([string[]]$Words) {
    if (-not $Words.Count) { throw 'usage: jk stocks rm <symbol> ...' }
    $list = @(Get-JkStockList)
    foreach ($w in $Words) {
        $sym = $w.Trim().ToUpperInvariant()
        if ($list -notcontains $sym) { throw "$sym is not on the list ($(if ($list.Count) { $list -join ', ' } else { 'it is empty' }))" }
        $list = @($list | Where-Object { $_ -ne $sym })
        try { [IO.File]::Delete((Get-JkStockCachePath $sym)) } catch { }
        Say (Paint 'yellow' "  removed $sym")
    }
    Save-JkStockList $list
    Say (Paint 'gray' "  watching $(if ($list.Count) { $list -join ', ' } else { 'nothing (jk stocks add SPY)' })")
}

function Set-JkStocksPopup([string[]]$Words) {
    $w = (($Words -join ' ').Trim()).ToLowerInvariant()
    $when = { param($d) $t = Get-JkStocksAlertTime $d; if ($t) { Format-JkTime $t.ToString('HH:mm', $script:Inv) } }
    if ($w -match '^(off|none|no)$') { Set-JkConfig 'stocks.time' 'off'; Say ((Paint 'yellow' '  no stock popup in the morning') + (Paint 'gray' '  (jk stocks popup on brings it back)')); return }
    if ($w -match '^(on|yes|open|default)$') { Set-JkConfig 'stocks.time' ''; Say ((Paint 'green' "  $($script:G.check) stock popup at the US open") + (Paint 'gray' " ($(& $when (Get-JkNow)) here), weekdays")); return }
    if ($w) {
        $found = Resolve-JkAtTime @($w -split '\s+') (Get-JkNow)
        if (-not $found) { throw "usage: jk stocks popup 9:45 | on | off   ('$w' is not a time)" }
        Set-JkConfig 'stocks.time' $found.At.ToString('HH:mm', $script:Inv)
        Say ((Paint 'green' "  $($script:G.check) stock popup at $(Format-JkTime $found.At.ToString('HH:mm', $script:Inv))") + (Paint 'gray' ', weekdays'))
        return
    }
    # no words: the popup now, as it would come
    $p = Get-JkStocksPopup -Tries 1
    if (-not $p) { Say (Paint 'gray' '  no popup: the US market is closed today, or the list is empty'); return }
    $mode = Show-JkNotify -Title $p.Title -Lines $p.Lines -Accent $script:JkPalette.blue -Seconds 20
    Say (Paint 'green' "  sent the stock popup ($mode)$(if ($t = & $when (Get-JkNow)) { " $($script:G.dot) it comes by itself at $t on weekdays" })")
}

function Invoke-JkStocks {
    $a = @($args | ForEach-Object { [string]$_ } | Where-Object { $_ })
    if (-not $a.Count) { Show-JkStocks; return }
    $first = $a[0].ToLowerInvariant()
    $rest = @($a | Select-Object -Skip 1)
    switch -Regex ($first) {
        '^(help|-h|--help|\?)$' { Show-JkHelp stocks; return }
        '^(add|watch|\+)$' { Add-JkStocks $rest; return }
        '^(rm|remove|del|drop|unwatch|-)$' { Remove-JkStocks $rest; return }
        '^(list|ls)$' { $l = @(Get-JkStockList); Say "  $(if ($l.Count) { $l -join ', ' } else { 'nothing on the list (jk stocks add SPY)' })"; return }
        '^(popup|alert)$' { Set-JkStocksPopup $rest; return }
    }
    $syms = @($a | ForEach-Object { ConvertTo-JkStockSymbol $_ })
    if (@($syms | Where-Object { -not $_ }).Count) { throw "unknown 'stocks' action '$($a[0])' (try: jk stocks help)" }
    if ($syms.Count -eq 1) { Show-JkStock $syms[0]; return }
    Show-JkStocks -Symbols $syms
}
