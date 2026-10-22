# core.ps1 - shared plumbing for jk: storage, config, colors, layout, dates, notifications.
# Source files stay ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI);
# every non-ASCII glyph is built from a code point here.

$script:Esc = [char]27
$script:JkUseColor = $false
$script:G = @{
    dot    = [string][char]0x00B7
    ell    = [string][char]0x2026
    bullet = [string][char]0x2022
    check  = [string][char]0x2713
    cross  = [string][char]0x2717
    star   = [string][char]0x2605
    arrow  = [string][char]0x2192
    up     = [string][char]0x2191
    down   = [string][char]0x2193
    full   = [string][char]0x2588
    shade  = [string][char]0x2591
    hline  = [string][char]0x2500
    vline  = [string][char]0x2502
    tri    = [string][char]0x25B8
    circle = [string][char]0x25CF
    ring   = [string][char]0x25CB
    dash   = [string][char]0x2013
}
# Partial blocks for smooth bars: 1/8 .. 7/8
$script:PartialBlocks = @(0x258F, 0x258E, 0x258D, 0x258C, 0x258B, 0x258A, 0x2589 | ForEach-Object { [string][char]$_ })

$script:JkPalette = @{
    red = 'F87171'; orange = 'FB923C'; amber = 'F2B04A'; yellow = 'FACC15'; green = '86EFAC'
    lime = 'A3D65C'; teal = '4FD1BE'; cyan = '67E8F9'; blue = '7C9CF8'; purple = 'B79BF6'
    pink = 'F472B6'; gray = '7E8794'; white = 'EEF1F5'; muted = 'B4BCC8'; ink = '161A21'
}

# ---------------------------------------------------------------- paths & storage

function Get-JkHome {
    $h = $env:JK_HOME
    if (-not $h) { $h = Join-Path $HOME '.jk' }
    if (-not (Test-Path -LiteralPath $h)) { New-Item -ItemType Directory -Path $h -Force | Out-Null }
    $h
}

function Get-JkPath([string]$Name) { Join-Path (Get-JkHome) $Name }

function Get-JkRoot { Split-Path -Parent $PSScriptRoot }

function Read-JkJson {
    param([string]$Name, $Default = $null)
    $p = Get-JkPath $Name
    if (-not (Test-Path -LiteralPath $p)) { return $Default }
    $text = [IO.File]::ReadAllText($p)
    if (-not $text.Trim()) { return $Default }
    try {
        $obj = ConvertFrom-Json -InputObject $text
    } catch {
        $bak = $p + '.corrupt-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $p -Destination $bak -Force
        Write-Warning "jk: $Name could not be parsed; a copy was saved to $bak"
        return $Default
    }
    , $obj
}

function Save-JkJson {
    param([string]$Name, $Object)
    $p = Get-JkPath $Name
    $json = ConvertTo-Json -InputObject $Object -Depth 12
    $tmp = "$p.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $p -Force
}

function Write-JkText {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

# Ensures $Obj has a property $Name (PSCustomObject from JSON); returns its value.
function Set-JkProp {
    param($Obj, [string]$Name, $Value)
    if ($Obj.PSObject.Properties[$Name]) { $Obj.$Name = $Value }
    else { $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Get-JkProp {
    param($Obj, [string]$Name, $Default = $null)
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name] -and $null -ne $Obj.$Name) { return $Obj.$Name }
    $Default
}

# ---------------------------------------------------------------- config

$script:JkConfigDefaults = [ordered]@{
    'name'          = ($env:USERNAME -split '\s+')[0]
    'editor'        = 'code'
    'notify'        = 'auto'      # auto | toast | popup | off
    'banner'        = 'on'        # one-line brief when PowerShell starts
    'remind.time'   = '08:30'
    'remind.hours'  = '48'
    'cp.root'       = (Join-Path $HOME 'Desktop\cp')
    'cp.lang'       = 'cpp'
    'cp.std'        = 'c++20'
    'cp.timeout'    = '3'
    'tidy.path'     = ''          # empty = the Downloads folder
    'tidy.minAge'   = '2'
    'focus.minutes' = '25'
    'repos.roots'   = (Join-Path $HOME 'Desktop')
}

# Config is read once per `jk` call (the dispatcher clears the cache); Set-JkConfig refreshes it.
$script:JkConfigCache = $null

function Get-JkConfig {
    param([string]$Key)
    if ($null -eq $script:JkConfigCache) { $script:JkConfigCache = @{ Data = (Read-JkJson 'config.json' $null) } }
    $cfg = $script:JkConfigCache.Data
    if ($Key) {
        $v = Get-JkProp $cfg $Key $null
        if ($null -ne $v -and "$v" -ne '') { return "$v" }
        if ($script:JkConfigDefaults.Contains($Key)) { return [string]$script:JkConfigDefaults[$Key] }
        return $null
    }
    $all = [ordered]@{}
    foreach ($k in $script:JkConfigDefaults.Keys) { $all[$k] = Get-JkConfig $k }
    if ($cfg) { foreach ($p in $cfg.PSObject.Properties) { if (-not $all.Contains($p.Name)) { $all[$p.Name] = "$($p.Value)" } } }
    $all
}

function Set-JkConfig {
    param([string]$Key, [string]$Value)
    $cfg = Read-JkJson 'config.json' $null
    if (-not $cfg) { $cfg = [pscustomobject]@{} }
    Set-JkProp $cfg $Key $Value
    Save-JkJson 'config.json' $cfg
    $script:JkConfigCache = $null
}

# ---------------------------------------------------------------- color & layout

function Test-JkColor {
    if ($env:NO_COLOR) { return $false }
    if ($env:JK_COLOR -eq 'always') { return $true }
    if ($env:JK_COLOR -eq 'never') { return $false }
    try { if ([Console]::IsOutputRedirected) { return $false } } catch { }
    [bool]$Host.UI.SupportsVirtualTerminal
}

function ConvertTo-JkRgb([string]$Hex) {
    $h = $Hex.TrimStart('#')
    '{0};{1};{2}' -f [Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16)
}

# Paint 'bold red' 'text' -> ANSI-styled text (plain when color is off).
# Styles: bold dim italic under strike inverse, palette names, #RRGGBB, bg:<name|#hex>.
$script:PaintCache = @{}

function Paint {
    param([string]$Style, [string]$Text)
    if (-not $script:JkUseColor -or -not $Style) { return $Text }
    $pre = $script:PaintCache[$Style]
    if ($null -eq $pre) { $pre = Get-JkStylePrefix $Style; $script:PaintCache[$Style] = $pre }
    if (-not $pre) { return $Text }
    "$pre$Text$script:Esc[0m"
}

function Get-JkStylePrefix([string]$Style) {
    $codes = New-Object System.Collections.Generic.List[string]
    foreach ($s in ($Style -split '[\s,+]+')) {
        if (-not $s) { continue }
        $bg = $false
        if ($s.StartsWith('bg:')) { $bg = $true; $s = $s.Substring(3) }
        if ($s -eq 'bold') { $codes.Add('1') }
        elseif ($s -eq 'dim') { $codes.Add('2') }
        elseif ($s -eq 'italic') { $codes.Add('3') }
        elseif ($s -eq 'under') { $codes.Add('4') }
        elseif ($s -eq 'inverse') { $codes.Add('7') }
        elseif ($s -eq 'strike') { $codes.Add('9') }
        else {
            $hex = $null
            if ($s -match '^#?[0-9a-fA-F]{6}$') { $hex = $s }
            elseif ($script:JkPalette.ContainsKey($s)) { $hex = $script:JkPalette[$s] }
            if ($hex) {
                if ($bg) { $codes.Add('48;2;' + (ConvertTo-JkRgb $hex)) } else { $codes.Add('38;2;' + (ConvertTo-JkRgb $hex)) }
            }
        }
    }
    if ($codes.Count -eq 0) { return '' }
    "$script:Esc[" + ($codes -join ';') + 'm'
}

# ---------------------------------------------------------------- machine facts (fast, no CIM)

function Get-JkMemory {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $ci = New-Object Microsoft.VisualBasic.Devices.ComputerInfo
    [pscustomobject]@{ Total = [double]$ci.TotalPhysicalMemory; Free = [double]$ci.AvailablePhysicalMemory }
}

# Milliseconds since boot from the 32-bit tick counter (exact up to 49 days, enough for "restart?" hints).
function Get-JkUptime { [TimeSpan]::FromMilliseconds([double]([int64][Environment]::TickCount -band [int64]4294967295)) }

function Get-JkBattery {
    Add-Type -AssemblyName System.Windows.Forms
    $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
    $flags = [int]$ps.BatteryChargeStatus
    if ($flags -band 128 -or $flags -eq 255) { return $null }   # NoSystemBattery / Unknown
    [pscustomobject]@{ Percent = [int][Math]::Round($ps.BatteryLifePercent * 100); Plugged = ([string]$ps.PowerLineStatus -eq 'Online') }
}

function Get-JkVisibleLength([string]$Text) { ($Text -replace "$([char]27)\[[0-9;]*m", '').Length }

# Truncate (with an ellipsis) or pad plain text to exactly $Width columns.
function Fit {
    param([string]$Text, [int]$Width, [switch]$Right)
    if ($Width -le 0) { return '' }
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -gt $Width) { $Text = $Text.Substring(0, [Math]::Max(0, $Width - 1)) + $script:G.ell }
    if ($Right) { return $Text.PadLeft($Width) }
    $Text.PadRight($Width)
}

function Say([string]$Line = '') { Write-Host $Line }

function Get-JkWidth {
    if ($env:JK_WIDTH) { return [int]$env:JK_WIDTH }
    try {
        $w = $Host.UI.RawUI.WindowSize.Width
        if ($w -ge 40) { return [Math]::Min($w - 1, 130) }
    } catch { }
    100
}

function Get-JkBar {
    param([double]$Fraction, [int]$Width = 20, [string]$Style = 'blue', [string]$EmptyStyle = 'gray dim')
    if ($Fraction -lt 0) { $Fraction = 0 }
    if ($Fraction -gt 1) { $Fraction = 1 }
    $eighths = [int][Math]::Round($Fraction * $Width * 8)
    $full = [int][Math]::Floor($eighths / 8)
    $rem = $eighths % 8
    $bar = $script:G.full * $full
    $used = $full
    if ($rem -gt 0 -and $used -lt $Width) { $bar += $script:PartialBlocks[$rem - 1]; $used++ }
    $empty = $script:G.shade * ($Width - $used)
    (Paint $Style $bar) + (Paint $EmptyStyle $empty)
}

function Format-JkSize([double]$Bytes) {
    if ($Bytes -ge 1000MB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1000KB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    '{0:N0} B' -f $Bytes
}

function Format-JkDuration([TimeSpan]$Span) {
    $neg = $Span.Ticks -lt 0
    if ($neg) { $Span = $Span.Negate() }
    if ($Span.TotalDays -ge 1) { $s = '{0}d {1}h' -f [int][Math]::Floor($Span.TotalDays), $Span.Hours }
    elseif ($Span.TotalHours -ge 1) { $s = '{0}h {1:00}m' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes }
    elseif ($Span.TotalMinutes -ge 1) { $s = '{0}m' -f [int][Math]::Floor($Span.TotalMinutes) }
    else { $s = '{0}s' -f [int][Math]::Floor($Span.TotalSeconds) }
    if ($neg) { "-$s" } else { $s }
}

function Write-JkHeader {
    param([string]$Title, [string]$Right = '', [string]$Sub = '', [string]$Style = 'bold white')
    $w = Get-JkWidth
    $left = ' ' + $Title.ToUpper()
    if ($Sub) { $left += '  ' + $Sub }
    $gap = [Math]::Max(2, $w - $left.Length - $Right.Length - 1)
    Say ''
    $head = Paint $Style (' ' + $Title.ToUpper())
    if ($Sub) { $head += '  ' + (Paint 'gray' $Sub) }
    Say ($head + (' ' * $gap) + (Paint 'gray' $Right))
    Say (Paint 'gray dim' (' ' + ($script:G.hline * ($w - 1))))
}

# ---------------------------------------------------------------- time & dates

# JK_NOW pins "now" for tests, e.g. $env:JK_NOW = '2026-10-22T14:00'
function Get-JkNow {
    if ($env:JK_NOW) { return [datetime]::Parse($env:JK_NOW, [Globalization.CultureInfo]::InvariantCulture) }
    Get-Date
}

$script:MonthMap = @{ jan = 1; feb = 2; mar = 3; apr = 4; may = 5; jun = 6; jul = 7; aug = 8; sep = 9; sept = 9; oct = 10; nov = 11; dec = 12 }
$script:DowMap = @{ sun = 0; mon = 1; tue = 2; tues = 2; wed = 3; thu = 4; thur = 4; thurs = 4; fri = 5; sat = 6 }

function Resolve-JkYear([int]$Month, [int]$Day, [datetime]$Today) {
    $d = New-Object DateTime $Today.Year, $Month, $Day
    if ($d -lt $Today.AddDays(-60)) { $d = $d.AddYears(1) }
    $d
}

# Accepts: today, tomorrow/tmr, yesterday, +3, 3d, 2w, mon..sun, next fri,
# oct 28, 28 oct, october 28 2026, 10/28, 2026-10-28, bare day-of-month (28).
function ConvertTo-JkDate {
    param([string]$Text, [datetime]$Now = (Get-JkNow))
    if ($Text -is [datetime]) { return ([datetime]$Text).Date }
    $t = ($Text -replace '[,\.]', ' ').Trim().ToLower() -replace '\s+', ' '
    $today = $Now.Date
    if ($t -match '^(today|tod|now)$') { return $today }
    if ($t -match '^(tomorrow|tmr|tmrw|tom)$') { return $today.AddDays(1) }
    if ($t -match '^(yesterday|yday)$') { return $today.AddDays(-1) }
    if ($t -match '^\+(\d+)$') { return $today.AddDays([int]$Matches[1]) }
    if ($t -match '^\+?(\d+) ?d(ays?)?$') { return $today.AddDays([int]$Matches[1]) }
    if ($t -match '^\+?(\d+) ?w(eeks?)?$') { return $today.AddDays(7 * [int]$Matches[1]) }
    if ($t -match '^(next )?([a-z]+)$' -and $script:DowMap.ContainsKey($Matches[2].Substring(0, [Math]::Min(3, $Matches[2].Length))) -and $Matches[2].Length -ge 3) {
        $key = $Matches[2]
        $abbr = $key.Substring(0, 3)
        $valid = @('sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday') | Where-Object { $_.StartsWith($key) }
        if ($valid) {
            $target = $script:DowMap[$abbr]
            $delta = ($target - [int]$today.DayOfWeek + 7) % 7
            if ($Matches[1]) { $delta += 7 }
            return $today.AddDays($delta)
        }
    }
    if ($t -match '^(\d{4})-(\d{1,2})-(\d{1,2})$') { return New-Object DateTime ([int]$Matches[1]), ([int]$Matches[2]), ([int]$Matches[3]) }
    if ($t -match '^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})$') {
        $y = [int]$Matches[3]; if ($y -lt 100) { $y += 2000 }
        return New-Object DateTime $y, ([int]$Matches[1]), ([int]$Matches[2])
    }
    if ($t -match '^(\d{1,2})[/-](\d{1,2})$') { return Resolve-JkYear ([int]$Matches[1]) ([int]$Matches[2]) $today }
    if ($t -match '^([a-z]{3,9}) ?(\d{1,2})(?:st|nd|rd|th)?(?: (\d{4}))?$' -and $script:MonthMap.ContainsKey($Matches[1].Substring(0, 3))) {
        $m = $script:MonthMap[$Matches[1].Substring(0, 3)]
        if ($Matches[3]) { return New-Object DateTime ([int]$Matches[3]), $m, ([int]$Matches[2]) }
        return Resolve-JkYear $m ([int]$Matches[2]) $today
    }
    if ($t -match '^(\d{1,2})(?:st|nd|rd|th)? ?([a-z]{3,9})(?: (\d{4}))?$' -and $script:MonthMap.ContainsKey($Matches[2].Substring(0, 3))) {
        $m = $script:MonthMap[$Matches[2].Substring(0, 3)]
        if ($Matches[3]) { return New-Object DateTime ([int]$Matches[3]), $m, ([int]$Matches[1]) }
        return Resolve-JkYear $m ([int]$Matches[1]) $today
    }
    if ($t -match '^(\d{1,2})(?:st|nd|rd|th)?$') {
        $d = [int]$Matches[1]
        $cand = New-Object DateTime $today.Year, $today.Month, 1
        if ($d -lt $today.Day) { $cand = $cand.AddMonths(1) }
        return $cand.AddDays($d - 1)
    }
    throw "can't understand the date '$Text' (try 2026-10-28, oct 28, fri, tomorrow, +3)"
}

# Accepts: 8pm, 8:30 pm, 20:00, 2359, noon, midnight/eod (23:59). Returns 'HH:mm'.
function ConvertTo-JkTime {
    param([string]$Text)
    $t = $Text.Trim().ToLower() -replace '\.', ''
    if ($t -match '^(noon)$') { return '12:00' }
    if ($t -match '^(midnight|eod|end of day)$') { return '23:59' }
    if ($t -match '^(\d{1,2})(?::(\d{2}))? ?(am|pm|a|p)?$') {
        $h = [int]$Matches[1]; $mi = 0
        if ($Matches[2]) { $mi = [int]$Matches[2] }
        $ap = $Matches[3]
        if ($ap -like 'p*' -and $h -lt 12) { $h += 12 }
        if ($ap -like 'a*' -and $h -eq 12) { $h = 0 }
        if ($h -gt 23 -or $mi -gt 59) { throw "invalid time '$Text'" }
        return '{0:00}:{1:00}' -f $h, $mi
    }
    if ($t -match '^(\d{2})(\d{2})$') {
        $h = [int]$Matches[1]; $mi = [int]$Matches[2]
        if ($h -gt 23 -or $mi -gt 59) { throw "invalid time '$Text'" }
        return '{0:00}:{1:00}' -f $h, $mi
    }
    throw "can't understand the time '$Text' (try 8pm, 20:00, 11:59 pm)"
}

function Format-JkTime([string]$HHmm) {
    if (-not $HHmm) { return '' }
    $p = $HHmm.Split(':')
    $h = [int]$p[0]; $m = [int]$p[1]
    $ap = 'am'; if ($h -ge 12) { $ap = 'pm' }
    $h12 = $h % 12; if ($h12 -eq 0) { $h12 = 12 }
    '{0}:{1:00} {2}' -f $h12, $m, $ap
}

function Format-JkRelDay([datetime]$Date, [datetime]$Now = (Get-JkNow)) {
    $n = [int]($Date.Date - $Now.Date).TotalDays
    if ($n -eq 0) { return 'today' }
    if ($n -eq 1) { return 'tomorrow' }
    if ($n -eq -1) { return 'yesterday' }
    if ($n -gt 1) { return "in $n days" }
    "$(-$n) days ago"
}

# Natural sort key: pads digit runs so 2.in sorts before 10.in.
function Get-JkNaturalKey([string]$s) { [regex]::Replace($s, '\d+', { param($m) $m.Value.PadLeft(12, '0') }) }

# ---------------------------------------------------------------- background work

function Get-JkPowerShellExe { Join-Path $PSHOME 'powershell.exe' }

# Runs a script block in a detached, windowless PowerShell that has jk loaded.
# Returns the process so callers can record its PID.
function Start-JkBackground {
    param([string]$Script, [hashtable]$Env = @{})
    $psd1 = Join-Path (Get-JkRoot) 'jk.psd1'
    $prelude = "`$env:JK_HOME = '" + (Get-JkHome).Replace("'", "''") + "'; "
    foreach ($k in $Env.Keys) { $prelude += "`$env:$k = '" + ([string]$Env[$k]).Replace("'", "''") + "'; " }
    $prelude += "`$jkm = Import-Module '" + $psd1.Replace("'", "''") + "' -Force -PassThru; "
    # run inside the module's scope (the helpers are private); failures in a windowless
    # process are invisible, so they go to background.log
    $log = (Join-Path (Get-JkHome) 'background.log').Replace("'", "''")
    $full = $prelude + "& `$jkm { try { $Script } catch { Add-Content -LiteralPath '$log' -Value ((Get-Date -Format s) + ' ' + `$_.Exception.Message + ' @ ' + `$_.ScriptStackTrace) } }"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
    $ps = Get-JkPowerShellExe
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $argsList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded)
    if (Test-Path $conhost) {
        Start-Process -FilePath $conhost -ArgumentList (@('--headless', $ps) + $argsList) -WindowStyle Hidden -PassThru
    } else {
        Start-Process -FilePath $ps -ArgumentList $argsList -WindowStyle Hidden -PassThru
    }
}

# Sleeps until a wall-clock time. Polls instead of one long sleep so a laptop that
# suspends mid-wait still fires promptly after it wakes up.
function Wait-JkUntil([string]$Iso) {
    $at = [datetime]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    if ($at.Kind -eq 'Utc') { $at = $at.ToLocalTime() }
    while ($true) {
        $left = ($at - (Get-Date)).TotalSeconds
        if ($left -le 0) { break }
        Start-Sleep -Milliseconds ([int]([Math]::Min($left, 15) * 1000))
    }
}

# ---------------------------------------------------------------- notifications

function Get-JkToastSetting {
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        return [string][Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Setting
    } catch { return 'Unavailable' }
}

# Shows a notification. Mode comes from config 'notify':
#   auto  -> Windows toast when notifications are enabled, otherwise jk's own popup
#   toast | popup | off
# -Wait blocks until a popup closes (used by background processes); otherwise the
# popup is shown from a detached process so the terminal is not blocked.
function Show-JkNotify {
    param(
        [string]$Title,
        [string[]]$Lines = @(),
        [string]$Accent = '7C9CF8',
        [string]$Open = '',
        [string]$OpenLabel = 'Open',
        [int]$Seconds = 12,
        [switch]$Sound,
        [switch]$Wait
    )
    $mode = Get-JkConfig 'notify'
    if ($mode -eq 'off') { return 'off' }
    if ($mode -eq 'auto') {
        if ((Get-JkToastSetting) -eq 'Enabled') { $mode = 'toast' } else { $mode = 'popup' }
    }
    if ($mode -eq 'toast') {
        Show-JkToast -Title $Title -Lines $Lines -Open $Open
        return 'toast'
    }
    if ($Wait) {
        Show-JkPopup -Title $Title -Lines $Lines -Accent $Accent -Open $Open -OpenLabel $OpenLabel -Seconds $Seconds -Sound:$Sound
    } else {
        $payload = [pscustomobject]@{ Title = $Title; Lines = @($Lines); Accent = $Accent; Open = $Open; OpenLabel = $OpenLabel; Seconds = $Seconds; Sound = [bool]$Sound }
        $json = (ConvertTo-Json -InputObject $payload -Depth 4 -Compress).Replace("'", "''")
        $null = Start-JkBackground -Script "`$p = ConvertFrom-Json '$json'; Show-JkPopup -Title `$p.Title -Lines @(`$p.Lines) -Accent `$p.Accent -Open `$p.Open -OpenLabel `$p.OpenLabel -Seconds `$p.Seconds -Sound:`$p.Sound"
    }
    'popup'
}

function Show-JkToast {
    param([string]$Title, [string[]]$Lines = @(), [string]$Open = '')
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    $x = { param($s) [Security.SecurityElement]::Escape([string]$s) }
    $launch = ''
    if ($Open) { $launch = " activationType='protocol' launch='" + (& $x ([Uri]$Open).AbsoluteUri) + "'" }
    $body = (& $x ($Lines -join "`n"))
    $xmlText = "<toast$launch><visual><binding template='ToastGeneric'><text>$(& $x $Title)</text><text>$body</text></binding></visual></toast>"
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml($xmlText)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    $toast.Group = 'jk'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show($toast)
}

# jk's own notification: a small dark card that slides in above the taskbar,
# never steals focus, pauses its timer while hovered, and works even when
# Windows notifications are turned off.
function Show-JkPopup {
    param(
        [string]$Title,
        [string[]]$Lines = @(),
        [string]$Accent = '7C9CF8',
        [string]$Open = '',
        [string]$OpenLabel = 'Open',
        [int]$Seconds = 12,
        [switch]$Sound
    )
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $x = { param($s) [Security.SecurityElement]::Escape([string]$s) }
    $accentHex = '#' + $Accent.TrimStart('#')
    $lineXaml = ''
    foreach ($l in $Lines) {
        $lineXaml += "<TextBlock Text='$(& $x $l)' Foreground='#C9D1DC' FontSize='12.5' TextWrapping='Wrap' Margin='0,3,0,0'/>"
    }
    $openXaml = ''
    if ($Open) {
        $openXaml = "<Button Name='OpenBtn' Content='$(& $x $OpenLabel)' HorizontalAlignment='Left' Margin='0,12,0,0' Padding='12,5' Cursor='Hand' Foreground='#161A21' Background='$accentHex' BorderThickness='0' FontWeight='SemiBold' FontSize='12'/>"
    }
    $xaml = @"
<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
        xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        WindowStyle='None' AllowsTransparency='True' Background='Transparent'
        Topmost='True' ShowInTaskbar='False' ShowActivated='False' ResizeMode='NoResize'
        SizeToContent='Height' Width='392' FontFamily='Segoe UI'>
  <Border Margin='12' CornerRadius='10' Background='#1A1E25' BorderBrush='#2E343E' BorderThickness='1'>
    <Border.Effect><DropShadowEffect BlurRadius='18' ShadowDepth='3' Opacity='0.45' Color='Black'/></Border.Effect>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width='4'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>
      <Border Grid.Column='0' CornerRadius='10,0,0,10' Background='$accentHex'/>
      <StackPanel Grid.Column='1' Margin='14,12,12,14'>
        <Grid>
          <StackPanel Orientation='Horizontal'>
            <Border CornerRadius='4' Background='$accentHex' Padding='5,0' Margin='0,1,8,0' VerticalAlignment='Center'>
              <TextBlock Text='jk' Foreground='#161A21' FontWeight='Bold' FontSize='11'/>
            </Border>
            <TextBlock Text='$(& $x $Title)' Foreground='#EEF1F5' FontSize='14' FontWeight='SemiBold' TextWrapping='Wrap' MaxWidth='290'/>
          </StackPanel>
          <TextBlock Name='CloseBtn' Text='&#x2715;' HorizontalAlignment='Right' VerticalAlignment='Top' Foreground='#7E8794' FontSize='12' Cursor='Hand' Padding='4,0,0,4'/>
        </Grid>
        $lineXaml
        $openXaml
      </StackPanel>
    </Grid>
  </Border>
</Window>
"@
    $win = [Windows.Markup.XamlReader]::Parse($xaml)
    $area = [System.Windows.SystemParameters]::WorkArea
    $win.Left = $area.Right - $win.Width - 4
    $win.Opacity = 0
    $close = $win.FindName('CloseBtn')
    $close.Add_MouseLeftButtonUp({ $win.Close() })
    $btn = $win.FindName('OpenBtn')
    if ($btn) { $btn.Add_Click({ try { Start-Process $Open } catch { }; $win.Close() }) }
    $win.Add_MouseLeftButtonUp({ if (-not $Open) { $win.Close() } })

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds([Math]::Max(1, $Seconds))
    $timer.Add_Tick({ $timer.Stop(); $win.Close() })
    $win.Add_MouseEnter({ $timer.Stop() })
    $win.Add_MouseLeave({ if ($Seconds -gt 0) { $timer.Start() } })

    $win.Add_Loaded({
        $win.Top = $area.Bottom - $win.ActualHeight + 16
        $target = $area.Bottom - $win.ActualHeight - 4
        $dur = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(260))
        $ease = New-Object System.Windows.Media.Animation.CubicEase
        $ease.EasingMode = 'EaseOut'
        $slide = New-Object System.Windows.Media.Animation.DoubleAnimation ($win.Top), $target, $dur
        $slide.EasingFunction = $ease
        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation 0, 1, $dur
        $win.BeginAnimation([System.Windows.Window]::TopProperty, $slide)
        $win.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
        if ($Seconds -gt 0) { $timer.Start() }
        if ($env:JK_TRACE) {
            Add-Content -LiteralPath (Join-Path (Get-JkHome) 'background.log') -Value ('{0} popup shown "{1}" {2:N0}x{3:N0} at left {4:N0}, settling at top {5:N0} (work area {6:N0}x{7:N0})' -f (Get-Date -Format s), $Title, $win.ActualWidth, $win.ActualHeight, $win.Left, $target, $area.Width, $area.Height)
        }
    })
    if ($Sound) { try { [System.Media.SystemSounds]::Asterisk.Play() } catch { } }
    # Show() + a private dispatcher loop (not ShowDialog) so the card never takes keyboard focus.
    $win.Add_Closed({ $win.Dispatcher.InvokeShutdown() })
    $win.Show()
    [System.Windows.Threading.Dispatcher]::Run()
}
