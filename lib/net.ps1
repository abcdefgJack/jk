# net.ps1 - "is it the Wi-Fi or the internet?"
#   jk net     checks in order: an address on a network adapter, the router, the internet by number,
#              DNS, and the page Windows itself fetches to decide whether you are online, then says
#              in one line what is wrong and what to try.

# Windows' own connectivity probe (NCSI): a plain page that a sign-in portal cannot fake
$script:JkNcsiUrl = 'http://www.msftconnecttest.com/connecttest.txt'
$script:JkNcsiHost = 'www.msftconnecttest.com'
$script:JkNcsiBody = 'Microsoft Connect Test'
$script:JkVpnRx = '(?i)vpn|tap-|tap |wintun|wireguard|openvpn|tunnel|zerotier|tailscale|anyconnect|forticlient|globalprotect'

# Wi-Fi details from `netsh wlan show interfaces`. The signal is read from the one line whose value
# is a percentage, so it works whatever language Windows is in.
function ConvertFrom-JkWlanText([string[]]$Lines) {
    $r = [ordered]@{}
    foreach ($l in $Lines) {
        if ($l -match '^\s*SSID\s*:\s*(.+)$') { $r.Ssid = $Matches[1].Trim() }
        elseif ($l -match ':\s*(\d{1,3})\s*%\s*$') { $r.Signal = [int]$Matches[1] }
        elseif ($l -match '^\s*Radio type\s*:\s*(.+)$') { $r.Radio = $Matches[1].Trim() }
        elseif ($l -match '^\s*Band\s*:\s*(.+)$') { $r.Band = $Matches[1].Trim() }
    }
    if (-not $r.Contains('Ssid')) { return $null }
    [pscustomobject]$r
}

# The adapters that are up, with their IPv4 address and router; VPN adapters are marked.
function Get-JkNetLinks {
    foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up' -or $nic.NetworkInterfaceType -eq 'Loopback') { continue }
        if ("$($nic.Name) $($nic.Description)" -match '(?i)vEthernet|WSL|Docker|VirtualBox|VMware|Hyper-V|Loopback|Bluetooth') { continue }
        $props = $nic.GetIPProperties()
        $v4 = @($props.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | ForEach-Object { "$($_.Address)" })
        if (-not $v4.Count) { continue }
        $gw = @($props.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and "$($_.Address)" -ne '0.0.0.0' } | ForEach-Object { "$($_.Address)" })
        [pscustomobject]@{
            Name     = $nic.Name
            Wireless = $nic.NetworkInterfaceType -eq 'Wireless80211'
            Address  = $v4[0]
            Apipa    = $v4[0] -like '169.254.*'
            Gateway  = $(if ($gw.Count) { $gw[0] } else { $null })
            Vpn      = "$($nic.Name) $($nic.Description)" -match $script:JkVpnRx -or $nic.NetworkInterfaceType -in 'Ppp', 'Tunnel'
        }
    }
}

function Test-JkPing([string]$Target, [int]$Count = 3, [int]$TimeoutMs = 800) {
    $ok = @()
    $p = New-Object Net.NetworkInformation.Ping
    try {
        for ($i = 0; $i -lt $Count; $i++) {
            try { $r = $p.Send($Target, $TimeoutMs); if ($r.Status -eq 'Success') { $ok += [int]$r.RoundtripTime } } catch { }
        }
    } finally { $p.Dispose() }
    $ms = $null; if ($ok.Count) { $ms = [int](($ok | Measure-Object -Average).Average) }
    [pscustomobject]@{ Ok = $ok.Count -gt 0; Sent = $Count; Got = $ok.Count; Ms = $ms }
}

function Test-JkDns([string]$Name, [int]$TimeoutMs = 3000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $t = [Net.Dns]::GetHostAddressesAsync($Name)
        if ($t.Wait($TimeoutMs) -and @($t.Result).Count) { return [pscustomobject]@{ Ok = $true; Ms = [int]$sw.ElapsedMilliseconds } }
    } catch { }
    [pscustomobject]@{ Ok = $false; Ms = $null }
}

# Fetches the NCSI page without following redirects: a sign-in portal shows up as a redirect or as
# some other page in its place.
function Test-JkWeb([int]$TimeoutMs = 4000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $resp = $null
    try {
        $req = [Net.HttpWebRequest]::Create($script:JkNcsiUrl)
        $req.Timeout = $TimeoutMs; $req.ReadWriteTimeout = $TimeoutMs
        $req.AllowAutoRedirect = $false
        $req.UserAgent = 'Microsoft NCSI'
        try { $resp = $req.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { throw } }
        $code = [int]$resp.StatusCode
        $body = ''
        try { $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $body = $sr.ReadToEnd(); $sr.Dispose() } catch { }
        $ms = [int]$sw.ElapsedMilliseconds
        if ($code -eq 200 -and $body.Trim() -eq $script:JkNcsiBody) { return [pscustomobject]@{ Ok = $true; Captive = $false; Ms = $ms; Status = $code } }
        return [pscustomobject]@{ Ok = $false; Captive = $true; Ms = $ms; Status = $code }
    } catch {
        return [pscustomobject]@{ Ok = $false; Captive = $false; Ms = $null; Status = 0 }
    } finally { if ($resp) { $resp.Close() } }
}

# One line on what is wrong, from what the probes found. Pure, so every case can be tested offline.
#   $P: Link (primary adapter or $null), Wifi (ConvertFrom-JkWlanText or $null), Vpn (name or $null),
#       Gateway / Internet (Test-JkPing), Dns (Test-JkDns), Web (Test-JkWeb)
function Get-JkNetVerdict($P) {
    $v = { param($level, $text, $hint) [pscustomobject]@{ Level = $level; Text = $text; Hint = $hint } }
    $ssid = ''; if ($P.Wifi) { $ssid = " '$($P.Wifi.Ssid)'" }
    $sig = $null; if ($P.Wifi -and $null -ne $P.Wifi.Signal) { $sig = [int]$P.Wifi.Signal }
    if (-not $P.Link) { return & $v 'bad' 'Not connected: no network adapter has an address' 'turn Wi-Fi on and pick a network, or plug in the cable' }
    if ($P.Link.Apipa) { return & $v 'bad' "Joined$ssid, but the router handed out no address" 'disconnect and reconnect; if it keeps happening, restart the router' }
    if ($P.Web.Ok) {
        # a router that never answers ping is just set up that way; only a partial or slow answer counts
        $bits = @()
        if ($null -ne $sig -and $sig -lt 40) { $bits += "signal $sig%" }
        if ($P.Gateway.Got -gt 0 -and $P.Gateway.Got -lt $P.Gateway.Sent) { $bits += "$($P.Gateway.Sent - $P.Gateway.Got) of $($P.Gateway.Sent) router pings lost" }
        if ($P.Gateway.Ok -and $P.Gateway.Ms -gt 60) { $bits += "router $($P.Gateway.Ms) ms" }
        if ($bits.Count) { return & $v 'warn' "Online, but the Wi-Fi link is weak ($($bits -join ', '))" 'move closer to the router, or pick its 5 GHz network' }
        $lat = @()
        if ($P.Gateway.Ok) { $lat += "router $($P.Gateway.Ms) ms" }
        if ($P.Internet.Ok) { $lat += "internet $($P.Internet.Ms) ms" }
        return & $v 'ok' "Online$(if ($lat.Count) { ': ' + ($lat -join ' ' + $script:G.dot + ' ') })" ''
    }
    if ($P.Web.Captive) { return & $v 'warn' "A sign-in page is in the way$ssid (campus guest, hotel or cafe Wi-Fi)" 'open http://neverssl.com in a browser to get the login page' }
    if ($P.Internet.Ok -and -not $P.Dns.Ok) { return & $v 'bad' 'DNS is failing: the internet answers by number, but names do not resolve' 'ipconfig /flushdns, then reconnect; if it persists, set the adapter''s DNS to 1.1.1.1' }
    if ($P.Internet.Ok) { return & $v 'warn' 'The internet answers, but web requests fail' 'a proxy, VPN or firewall is in the way - try with the VPN off' }
    if ($P.Gateway.Ok) { return & $v 'bad' 'The router answers, but nothing past it does: its internet connection is down' 'restart the router or modem; check the provider''s outage page from your phone' }
    $why = 'the router does not answer'
    if ($null -ne $sig -and $sig -lt 40) { $why += " (signal $sig%)" }
    & $v 'bad' "Nothing gets through: $why" 'reconnect to the Wi-Fi; if other devices are offline too, restart the router'
}

# ---- jk net speed: latency, download and upload against Cloudflare's speed test (speed.cloudflare.com),
# each direction capped at about 8 seconds so a slow link does not hang it.
$script:JkSpeedBase = 'https://speed.cloudflare.com'

# The Cloudflare site that answered, from a cf-ray header ("a53720f2dac3ab3c-YYZ" -> YYZ).
function Get-JkCfColo([string]$Ray) { if ($Ray -match '-([A-Z]{3})$') { $Matches[1] } else { '' } }

# What the numbers are good for, in a line. Pure, for the tests.
function Get-JkSpeedVerdict([double]$DownMbps, [double]$UpMbps, [double]$LatencyMs) {
    $v = { param($level, $text) [pscustomobject]@{ Level = $level; Text = $text } }
    if ($DownMbps -lt 1.5) { return & $v 'bad' 'Very slow: pages crawl, video will not play smoothly' }
    $bits = @()
    if ($DownMbps -lt 5) { $bits += 'enough for pages and SD video, slow for downloads' }
    elseif ($DownMbps -lt 25) { $bits += 'fine for HD video and big downloads' }
    else { $bits += 'fast: 4K video and big downloads are no trouble' }
    $level = 'ok'
    if ($UpMbps -gt 0 -and $UpMbps -lt 1.5) { $bits += 'upload too slow for video calls'; $level = 'warn' }
    elseif ($UpMbps -gt 0 -and $UpMbps -lt 3) { $bits += 'video calls may stutter on upload'; $level = 'warn' }
    if ($LatencyMs -gt 150) { $bits += "high latency ($([int]$LatencyMs) ms): calls and games lag"; $level = 'warn' }
    if ($DownMbps -lt 5 -and $level -eq 'ok') { $level = 'warn' }
    & $v $level (($bits -join '; ').Substring(0, 1).ToUpper() + ($bits -join '; ').Substring(1))
}

function Measure-JkLatency([int]$Count = 5) {
    $times = @(); $ray = ''
    for ($i = 0; $i -lt $Count; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $req = [Net.HttpWebRequest]::Create("$script:JkSpeedBase/__down?bytes=0"); $req.Timeout = 5000
            $resp = $req.GetResponse(); $times += $sw.Elapsed.TotalMilliseconds; $ray = [string]$resp.Headers['cf-ray']; $resp.Close()
        } catch { }
    }
    if (-not $times.Count) { return $null }
    # the first request also sets up TLS: the median of the others is the line's latency
    $warm = @($times | Select-Object -Skip 1); if (-not $warm.Count) { $warm = $times }
    $sorted = @($warm | Sort-Object)
    [pscustomobject]@{ Ms = $sorted[[int][Math]::Floor(($sorted.Count - 1) / 2)]; Colo = (Get-JkCfColo $ray) }
}

function Measure-JkDownload([int]$Bytes = 25000000, [double]$MaxSeconds = 8) {
    $req = [Net.HttpWebRequest]::Create("$script:JkSpeedBase/__down?bytes=$Bytes"); $req.Timeout = 10000; $req.ReadWriteTimeout = 10000
    $resp = $req.GetResponse()
    try {
        $s = $resp.GetResponseStream(); $buf = New-Object byte[] 65536; $got = 0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $MaxSeconds) { $n = $s.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $got += $n }
        $secs = [Math]::Max(0.001, $sw.Elapsed.TotalSeconds)
    } finally { $resp.Close() }
    [pscustomobject]@{ Mbps = $got * 8 / 1e6 / $secs; Bytes = $got }
}

function Measure-JkUpload([int]$Bytes = 8000000, [double]$MaxSeconds = 8) {
    $req = [Net.HttpWebRequest]::Create("$script:JkSpeedBase/__up"); $req.Method = 'POST'; $req.ContentType = 'application/octet-stream'
    $req.ContentLength = $Bytes; $req.Timeout = 15000; $req.ReadWriteTimeout = 15000; $req.AllowWriteStreamBuffering = $false
    $chunk = New-Object byte[] 65536; $sent = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $st = $req.GetRequestStream()
    try {
        while ($sent -lt $Bytes) {
            if ($sw.Elapsed.TotalSeconds -ge $MaxSeconds) { $req.Abort(); break }
            $n = [Math]::Min($chunk.Length, $Bytes - $sent); $st.Write($chunk, 0, $n); $sent += $n
        }
    } catch { } finally { try { $st.Close() } catch { } }
    if ($sent -ge $Bytes) { try { $req.GetResponse().Close() } catch { } }
    $secs = [Math]::Max(0.001, $sw.Elapsed.TotalSeconds)
    [pscustomobject]@{ Mbps = $sent * 8 / 1e6 / $secs; Bytes = $sent }
}

function Invoke-JkNetSpeed {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $wifi = $null; try { $wifi = ConvertFrom-JkWlanText @(netsh wlan show interfaces 2>$null) } catch { }
    Say (Paint 'gray' '  measuring (up to ~15 s; uses up to ~30 MB)...')
    $lat = Measure-JkLatency
    if (-not $lat) { throw 'Cloudflare''s speed test did not answer: jk net says what is wrong with the connection' }
    $down = $null; $up = $null
    try { $down = Measure-JkDownload } catch { }
    try { $up = Measure-JkUpload } catch { }
    $sub = "Cloudflare $($lat.Colo)".Trim()
    if ($wifi) { $sub += " $($script:G.dot) Wi-Fi '$($wifi.Ssid)'"; if ($null -ne $wifi.Signal) { $sub += " $($wifi.Signal)%" } }
    Write-JkHeader 'Network speed' (Format-JkTime ((Get-Date).ToString('HH:mm', $script:Inv))) -Sub $sub
    $max = [Math]::Max(1.0, [Math]::Max([double]$down.Mbps, [double]$up.Mbps))
    $row = { param($k, $v, $frac) Say ('  ' + (Paint 'bold white' (Fit $k 10)) + (Paint 'white' (Fit $v 12 -Right)) + '  ' + $(if ($null -ne $frac) { Get-JkBar $frac 28 'teal' } else { '' })) }
    & $row 'latency' "$([int]$lat.Ms) ms" $null
    & $row 'download' $(if ($down) { '{0:N1} Mbps' -f $down.Mbps } else { 'failed' }) $(if ($down) { $down.Mbps / $max } else { $null })
    & $row 'upload' $(if ($up) { '{0:N1} Mbps' -f $up.Mbps } else { 'failed' }) $(if ($up) { $up.Mbps / $max } else { $null })
    Say ''
    $v = Get-JkSpeedVerdict ([double]$down.Mbps) ([double]$up.Mbps) $lat.Ms
    Say ('  ' + (Paint (@{ ok = 'bold green'; warn = 'bold yellow'; bad = 'bold red' }[$v.Level]) $v.Text))
    if ($wifi -and $null -ne $wifi.Signal -and $wifi.Signal -lt 50 -and $v.Level -ne 'ok') { Say (Paint 'gray' "  the Wi-Fi signal is $($wifi.Signal)%: closer to the router (or its 5 GHz network) usually helps most") }
}

function Invoke-JkNet {
    if (@($args).Count -and ([string]$args[0]) -match '^(?i)(speed|test|speedtest)$') { Invoke-JkNetSpeed; return }
    if (@($args).Count -and ([string]$args[0]) -match '^(?i)(help|-h|--help|\?)$') { Show-JkHelp 'net'; return }
    $links = @(Get-JkNetLinks)
    $vpn = @($links | Where-Object { $_.Vpn })
    $link = @($links | Where-Object { -not $_.Vpn -and $_.Gateway } | Sort-Object { -not $_.Wireless })[0]
    if (-not $link) { $link = @($links | Where-Object { -not $_.Vpn })[0] }
    $wifi = $null
    if (-not $link -or $link.Wireless) { try { $wifi = ConvertFrom-JkWlanText @(netsh wlan show interfaces 2>$null) } catch { } }
    $sub = 'not connected'
    if ($wifi) {
        $sub = "Wi-Fi '$($wifi.Ssid)'"
        if ($null -ne $wifi.Signal) { $sub += " $($script:G.dot) signal $($wifi.Signal)%" }
        if ($wifi.Band) { $sub += " $($script:G.dot) $($wifi.Band)" }
    } elseif ($link) { $sub = $link.Name }
    Write-JkHeader 'Network' $(if ($vpn.Count) { "VPN on: $($vpn[0].Name)" } else { '' }) -Sub $sub

    $none = [pscustomobject]@{ Ok = $false; Sent = 0; Got = 0; Ms = $null; Captive = $false }
    $p = [pscustomobject]@{ Link = $link; Wifi = $wifi; Vpn = $(if ($vpn.Count) { $vpn[0].Name } else { $null }); Gateway = $none; Internet = $none; Dns = $none; Web = $none }
    $row = { param($ok, $label, $what, $detail)
        $mark = Paint 'red' $script:G.cross
        if ($ok -eq 'ok') { $mark = Paint 'green' $script:G.check } elseif ($ok -eq 'warn') { $mark = Paint 'yellow' '!' } elseif ($ok -eq 'skip') { $mark = Paint 'gray' '-' }
        Say ('  ' + $mark + ' ' + (Paint 'white' (Fit $label 10)) + (Paint 'muted' (Fit $what 26)) + (Paint 'gray' $detail))
    }
    if ($link) {
        & $row $(if ($link.Apipa) { 'bad' } else { 'ok' }) 'address' $link.Address $(if ($link.Apipa) { 'self-assigned: the router gave none' } else { "($($link.Name))" })
        if (-not $link.Apipa) {
            if ($link.Gateway) {
                $p.Gateway = Test-JkPing $link.Gateway 3 800
                & $row $(if ($p.Gateway.Got -eq 3) { 'ok' } elseif ($p.Gateway.Ok) { 'warn' } else { 'bad' }) 'router' $link.Gateway $(if ($p.Gateway.Ok) { "$($p.Gateway.Ms) ms$(if ($p.Gateway.Got -lt 3) { ", $($p.Gateway.Got) of 3 answered" })" } else { 'no answer' })
            } else { & $row 'bad' 'router' '(none)' 'the adapter has no default gateway' }
            $p.Internet = Test-JkPing '1.1.1.1' 2 1000
            & $row $(if ($p.Internet.Ok) { 'ok' } else { 'bad' }) 'internet' '1.1.1.1' $(if ($p.Internet.Ok) { "$($p.Internet.Ms) ms" } else { 'no answer' })
            $p.Dns = Test-JkDns $script:JkNcsiHost
            & $row $(if ($p.Dns.Ok) { 'ok' } else { 'bad' }) 'DNS' $script:JkNcsiHost $(if ($p.Dns.Ok) { "$($p.Dns.Ms) ms" } else { 'no answer' })
            $p.Web = Test-JkWeb
            $webTxt = 'no answer'
            if ($p.Web.Ok) { $webTxt = "$($p.Web.Ms) ms" } elseif ($p.Web.Captive) { $webTxt = "got another page instead (HTTP $($p.Web.Status))" }
            & $row $(if ($p.Web.Ok) { 'ok' } elseif ($p.Web.Captive) { 'warn' } else { 'bad' }) 'web' 'msftconnecttest.com' $webTxt
        }
    }
    $verdict = Get-JkNetVerdict $p
    Say ''
    $st = @{ ok = 'bold green'; warn = 'bold yellow'; bad = 'bold red' }[$verdict.Level]
    Say ('  ' + (Paint $st $verdict.Text))
    if ($verdict.Hint) { Say (Paint 'gray' "  try: $($verdict.Hint)") }
    if ($p.Vpn -and $verdict.Level -ne 'ok') { Say (Paint 'gray' "  a VPN is on ($($p.Vpn)): if this only happens with it on, the VPN is the problem") }
}
