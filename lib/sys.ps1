# sys.ps1 - machine status (jk sys) and port inspection (jk port).

function Get-JkSysSnapshot {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $load = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')
    [pscustomobject]@{
        Os        = $os
        Cpu       = $cpu
        Load      = $load
        TotalMem  = [double]$os.TotalVisibleMemorySize * 1KB
        FreeMem   = [double]$os.FreePhysicalMemory * 1KB
        Uptime    = (Get-Date) - $os.LastBootUpTime
        Battery   = $bat
        Disks     = $disks
    }
}

function Get-JkWifiName {
    try {
        $out = netsh wlan show interfaces 2>$null
        foreach ($l in $out) { if ($l -match '^\s*SSID\s*:\s*(.+)$') { return $Matches[1].Trim() } }
    } catch { }
    $null
}

function Invoke-JkSys {
    param([int]$Top = 6)
    $s = Get-JkSysSnapshot
    $w = Get-JkWidth
    $up = Format-JkDuration $s.Uptime
    Write-JkHeader 'System' "$($env:COMPUTERNAME) $($script:G.dot) up $up" -Sub ($s.Os.Caption -replace 'Microsoft ', '')
    $barW = [Math]::Max(16, [Math]::Min(36, $w - 48))
    $loadStyle = 'green'; if ($s.Load -ge 85) { $loadStyle = 'red' } elseif ($s.Load -ge 60) { $loadStyle = 'orange' }
    Say ('  ' + (Paint 'bold white' (Fit 'CPU' 9)) + (Get-JkBar ($s.Load / 100) $barW $loadStyle) + '  ' + (Paint 'white' ("{0,3}%" -f [int]$s.Load)) + (Paint 'gray' "  $($s.Cpu.Name.Trim() -replace '\s+', ' ')"))
    $used = $s.TotalMem - $s.FreeMem
    $memFrac = $used / $s.TotalMem
    $memStyle = 'green'; if ($memFrac -ge 0.9) { $memStyle = 'red' } elseif ($memFrac -ge 0.75) { $memStyle = 'orange' }
    Say ('  ' + (Paint 'bold white' (Fit 'Memory' 9)) + (Get-JkBar $memFrac $barW $memStyle) + '  ' + (Paint 'white' ("{0,3}%" -f [int]($memFrac * 100))) + (Paint 'gray' "  $(Format-JkSize $used) of $(Format-JkSize $s.TotalMem)"))
    foreach ($d in $s.Disks) {
        if (-not $d.Size) { continue }
        $frac = 1 - ($d.FreeSpace / $d.Size)
        $st = 'blue'; if ($frac -ge 0.95) { $st = 'red' } elseif ($frac -ge 0.85) { $st = 'orange' }
        Say ('  ' + (Paint 'bold white' (Fit "Disk $($d.DeviceID)" 9)) + (Get-JkBar $frac $barW $st) + '  ' + (Paint 'white' ("{0,3}%" -f [int]($frac * 100))) + (Paint 'gray' "  $(Format-JkSize $d.FreeSpace) free of $(Format-JkSize $d.Size)"))
    }
    if ($s.Battery) {
        $pct = [int]$s.Battery.EstimatedChargeRemaining
        $plugged = @(2, 6, 7, 8, 9) -contains [int]$s.Battery.BatteryStatus
        $st = 'green'; if ($pct -le 15) { $st = 'red' } elseif ($pct -le 35) { $st = 'orange' }
        $state = 'on battery'; if ($plugged) { $state = 'plugged in' }
        Say ('  ' + (Paint 'bold white' (Fit 'Battery' 9)) + (Get-JkBar ($pct / 100) $barW $st) + '  ' + (Paint 'white' ("{0,3}%" -f $pct)) + (Paint 'gray' "  $state"))
    }
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.InterfaceAlias -notmatch 'vEthernet|Loopback|WSL|Docker' } | ForEach-Object { "$($_.IPAddress) ($($_.InterfaceAlias))" })
    $wifi = Get-JkWifiName
    $net = ($ips -join ', ')
    if ($wifi) { $net = "Wi-Fi '$wifi'  $($script:G.dot)  $net" }
    if ($net) { Say ('  ' + (Paint 'bold white' (Fit 'Network' 9)) + (Paint 'muted' $net)) }
    if ($s.Uptime.TotalDays -ge 7) { Say ('  ' + (Paint 'yellow' "$($script:G.bullet) up for $([int]$s.Uptime.TotalDays) days $($script:G.dash) a restart usually helps sluggishness and finishes pending updates")) }

    Say ''
    Say (' ' + (Paint 'bold white' 'Top memory') + (Paint 'gray' '  (grouped by app)'))
    $procs = Get-Process | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Mem = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum; Count = $_.Count; Cpu = ($_.Group | Measure-Object CPU -Sum).Sum }
    } | Sort-Object Mem -Descending | Select-Object -First $Top
    $maxMem = ($procs | Measure-Object Mem -Maximum).Maximum
    foreach ($p in $procs) {
        $cnt = ''; if ($p.Count -gt 1) { $cnt = "$($p.Count) procs" }
        Say ('  ' + (Paint 'white' (Fit $p.Name 20)) + (Paint 'white' (Fit (Format-JkSize $p.Mem) 10 -Right)) + '  ' + (Get-JkBar ($p.Mem / $maxMem) 20 'purple') + (Paint 'gray' "  $cnt"))
    }
}

$script:DevPorts = @(80, 443, 1433, 3000, 3001, 4200, 5000, 5173, 5432, 5500, 6379, 8000, 8080, 8081, 8443, 8888, 9000, 9229, 27017, 3306)

function Invoke-JkPort {
    param([Parameter(Position = 0)][int]$Port, [switch]$Kill, [switch]$All)
    $conns = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
    $procs = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) { $procs[$p.Id] = $p }
    if ($Port) {
        $hits = @($conns | Where-Object { $_.LocalPort -eq $Port })
        if (-not $hits) { Say ((Paint 'green' "  port $Port is free") + " $($script:G.check)"); return }
        $pids = @($hits | Select-Object -ExpandProperty OwningProcess -Unique)
        foreach ($procId in $pids) {
            $p = $procs[[int]$procId]
            $name = '?'; if ($p) { $name = $p.ProcessName }
            $path = ''; try { if ($p) { $path = $p.Path } } catch { }
            Say ('  ' + (Paint 'bold white' "port $Port") + "  $($script:G.arrow)  " + (Paint 'bold cyan' $name) + (Paint 'gray' "  pid $procId  $path"))
            if ($Kill) {
                if ([int]$procId -le 4) { Say (Paint 'red' '  refusing to kill a system process'); continue }
                Stop-Process -Id $procId -Force -ErrorAction Stop
                Say (Paint 'yellow' "  killed $name (pid $procId) $($script:G.dash) port $Port is free now")
            }
        }
        if (-not $Kill) { Say (Paint 'gray' "  free it: jk port $Port -Kill") }
        return
    }
    $rows = $conns | Group-Object LocalPort | ForEach-Object {
        $c = $_.Group[0]
        $p = $procs[[int]$c.OwningProcess]
        $name = '?'; if ($p) { $name = $p.ProcessName }
        $addrs = @($_.Group | ForEach-Object { $_.LocalAddress } | Select-Object -Unique)
        [pscustomobject]@{ Port = [int]$_.Name; Pid = [int]$c.OwningProcess; Name = $name; Addr = ($addrs -join ', ') }
    } | Sort-Object Port
    if (-not $All) { $rows = @($rows | Where-Object { $_.Port -lt 49152 -and $_.Name -notmatch '^(svchost|System|lsass|wininit|services|spoolsv|Idle)$' }) }
    Write-JkHeader 'Listening ports' "$(@($rows).Count) shown$(if (-not $All) { ' (-All for system ones)' })"
    foreach ($r in $rows) {
        $st = 'white'; if ($script:DevPorts -contains $r.Port) { $st = 'bold cyan' }
        $scope = 'local only'
        if ($r.Addr -match '0\.0\.0\.0|::(?!1)|^::$') { $scope = 'all interfaces' }
        Say ('  ' + (Paint $st (Fit "$($r.Port)" 7 -Right)) + '  ' + (Paint 'white' (Fit $r.Name 22)) + ' ' + (Paint 'gray' (Fit "pid $($r.Pid)" 11)) + (Paint 'gray' $scope))
    }
    Say ''
    Say (Paint 'gray' "  jk port 8080  (who has it)  $($script:G.dot)  jk port 8080 -Kill  (free it)")
}
