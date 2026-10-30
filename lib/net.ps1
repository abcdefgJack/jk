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

function Invoke-JkNet {
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
