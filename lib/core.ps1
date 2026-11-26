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

# Rebuildable bulk (precompiled headers) lives here, not in the data folder that gets backed up.
function Get-JkCacheDir {
    $c = $env:JK_CACHE
    if (-not $c) { $c = Join-Path $env:LOCALAPPDATA 'jk' }
    if (-not (Test-Path -LiteralPath $c)) { New-Item -ItemType Directory -Path $c -Force | Out-Null }
    $c
}

function Get-JkPath([string]$Name) { Join-Path (Get-JkHome) $Name }

function Get-JkRoot { Split-Path -Parent $PSScriptRoot }

# state.json holds small stamps written by different processes (the morning task, the sync,
# the dashboard). Each change re-reads the file under a machine-wide lock, so one writer never
# saves an old copy over another's change (the morning popup waits on the user for a while).
function Set-JkState {
    param([string]$Name, $Value)
    $m = New-Object Threading.Mutex($false, 'Local\jk-state')
    try { $null = $m.WaitOne(10000) } catch { }
    try {
        $s = Read-JkJson 'state.json' $null
        if (-not $s) { $s = [pscustomobject]@{} }
        Set-JkProp $s $Name $Value
        Save-JkJson 'state.json' $s
    } finally {
        try { $m.ReleaseMutex() } catch { }
        $m.Dispose()
    }
}

# The local time $Seconds from now, counted in real time. Local-time arithmetic is wall-clock
# arithmetic: "jk in 2h" at 00:30 on the night clocks fall back would land at 02:30 by the clock,
# three real hours later.
function Get-JkLocalAfter([double]$Seconds, [datetime]$From = [DateTime]::UtcNow) {
    $From.ToUniversalTime().AddSeconds($Seconds).ToLocalTime()
}

# The real time from $From to $To, both local: Monday 7 pm from Saturday 11 pm is 44 hours by
# the clock but 45 lived ones the weekend clocks fall back.
function Get-JkTimeLeft([datetime]$To, [datetime]$From) {
    $To.ToUniversalTime() - $From.ToUniversalTime()
}

function Get-JkState([string]$Name, $Default = $null) { Get-JkProp (Read-JkJson 'state.json' $null) $Name $Default }

# A record no screen can read (a hand edit, a bad sync) is set aside when its file is loaded and
# written back unchanged when it is saved: one bad row never takes the screens down, and is never
# lost (jk doctor names it). $List is the property holding the records; $Test says whether one is
# readable, and may tidy it ("7pm" -> "19:00").
function Split-JkUnreadable($Data, [string]$List, [scriptblock]$Test) {
    $good = New-Object System.Collections.Generic.List[object]; $bad = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($Data.$List)) {
        $ok = $false; try { $ok = [bool](& $Test $r) } catch { }
        if ($ok) { $good.Add($r) } else { $bad.Add($r) }
    }
    if ($bad.Count) { $Data.$List = $good.ToArray(); Set-JkProp $Data 'unreadable' $bad.ToArray() }
}

# Runs $Save with the set-aside records back in $List, and takes them out again after.
function Save-JkWithUnreadable($Data, [string]$List, [scriptblock]$Save) {
    $bad = @(Get-JkProp $Data 'unreadable' @())
    if (-not $bad.Count) { & $Save; return }
    $good = @($Data.$List)
    $Data.$List = @($good + $bad); $Data.PSObject.Properties.Remove('unreadable')
    try { & $Save } finally { $Data.$List = $good; Set-JkProp $Data 'unreadable' $bad }
}

# A time as HH:mm, or $null when it is not one jk can read ("7pm" -> "19:00").
function Get-JkReadableTime([string]$Value) {
    if ($Value -match '^([01]?\d|2[0-3]):[0-5]\d$') { return $Value }
    $fixed = $null; try { $fixed = [string](ConvertTo-JkTime $Value) } catch { }
    if ($fixed -match '^([01]?\d|2[0-3]):[0-5]\d$') { return $fixed }
    $null
}

function Test-JkDateText([string]$Value) {
    $d = [datetime]::MinValue
    [datetime]::TryParseExact($Value, 'yyyy-MM-dd', $script:Inv, [Globalization.DateTimeStyles]::None, [ref]$d)
}

# True only in a real terminal someone is typing into: never in CI, tests (JK_NONINTERACTIVE),
# the background task or a pipe, so a prompt can never hang a script.
function Test-JkInteractive {
    if ($env:JK_NONINTERACTIVE) { return $false }
    try { return [Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected } catch { return $false }
}

# background.log only grows (windowless timers and the morning task append to it): keep the
# newest lines.
function Limit-JkBackgroundLog([int]$Keep = 500) {
    $log = Get-JkPath 'background.log'
    if (-not (Test-Path -LiteralPath $log)) { return }
    $lines = @([IO.File]::ReadAllLines($log))
    if ($lines.Count -le $Keep) { return }
    [IO.File]::WriteAllLines($log, @($lines | Select-Object -Last $Keep))
}

# Another jk replacing the file holds it for an instant (the morning task, a banner in a new shell):
# that is a moment's wait, not an error.
function Read-JkFileText([string]$Path) {
    for ($try = 1; ; $try++) {
        try { return [IO.File]::ReadAllText($Path) }
        catch [IO.IOException], [UnauthorizedAccessException] {
            if ($try -ge 40 -or $_.Exception -is [IO.FileNotFoundException]) { throw }
            Start-Sleep -Milliseconds 25
        }
    }
}

# Puts a finished file in place in one step, for anyone reading it. Move-Item -Force deletes the old
# one first: for that instant another jk finds no file, reads it as "no data yet", and its next save
# writes the empty list over everything. [IO.File]::Replace leaves such a moment too (measured: two
# writers and two readers). This one is MoveFileEx with replace-existing, a rename over the old file.
# A reader holding the file open makes it wait, not fail.
function Move-JkFileOver([string]$From, [string]$To) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    for ($try = 1; ; $try++) {
        try {
            [Microsoft.VisualBasic.FileIO.FileSystem]::MoveFile($From, $To, $true)
            return
        }
        catch [IO.IOException], [UnauthorizedAccessException] {
            if ($try -ge 80) { try { [IO.File]::Delete($From) } catch { }; throw }
            Start-Sleep -Milliseconds 25
        }
        catch { try { [IO.File]::Delete($From) } catch { }; throw }
    }
}

# A damaged data file (cut short by a crash, emptied, or hand-edited into invalid JSON) is set
# aside and replaced by the newest backup that still reads. Carrying on with empty data instead
# would let the next save - the morning sync, a jk due add - make the loss permanent.
function Read-JkJson {
    param([string]$Name, $Default = $null)
    $p = Get-JkPath $Name
    if (-not (Test-Path -LiteralPath $p)) { return $Default }
    $text = Read-JkFileText $p
    $err = $null
    if (-not $text.Trim()) {
        # saves are atomic, so jk never leaves a data file empty: for one it backs up, that is damage
        if ($script:JkBackupFiles -notcontains $Name) { return $Default }
        $err = 'the file is empty'
    } else {
        try { return , (ConvertFrom-Json -InputObject $text) }
        catch { $err = (([string]$_.Exception.Message) -split "`r?`n")[0] }
    }
    $bak = $p + '.corrupt-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $p -Destination $bak -Force
    $good = $null
    if ($script:JkBackupFiles -contains $Name) { $good = Find-JkGoodBackup $Name }
    if ($good) {
        Copy-Item -LiteralPath $good.Path -Destination $p -Force
        Write-Warning "jk: $Name was damaged ($err). Restored $($good.From); the damaged file is $bak"
        return , $good.Object
    }
    Write-Warning "jk: $Name could not be read ($err); a copy was saved to $bak"
    $Default
}

# The newest copy of a data file that parses: the daily backups first, then the mirror.
function Find-JkGoodBackup([string]$Name) {
    $places = @(@{ Root = (Join-Path (Get-JkHome) 'backups'); Label = 'the backup of' })
    # never ask config.json for the mirror while config.json is the file being repaired
    if ($Name -ne 'config.json') {
        $m = $null
        try { $m = Get-JkConfig 'backup.mirror' } catch { }
        if ($m) { $places += @{ Root = $m; Label = 'the mirror copy of' } }
    }
    foreach ($pl in $places) {
        $days = @(Get-ChildItem -LiteralPath $pl.Root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending)
        foreach ($d in $days) {
            $f = Join-Path $d.FullName $Name
            if (-not (Test-Path -LiteralPath $f)) { continue }
            $t = [IO.File]::ReadAllText($f)
            if (-not $t.Trim()) { continue }
            try { $o = ConvertFrom-Json -InputObject $t } catch { continue }
            return [pscustomobject]@{ Path = $f; Object = $o; From = "$($pl.Label) $($d.Name)" }
        }
    }
    $null
}

function Save-JkJson {
    param([string]$Name, $Object)
    $p = Get-JkPath $Name
    Backup-JkFile $Name
    $json = ConvertTo-Json -InputObject $Object -Depth 12
    # this process's own temp name: two saves at once must not write into one file
    $tmp = "$p.$PID.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    Move-JkFileOver $tmp $p
}

# Before the first change of the day, the current version of a top-level data file is kept in
# backups\<yyyy-MM-dd>\ (30 days are kept). `jk backup restore <day>` brings a day back.
$script:JkBackupFiles = @('deadlines.json', 'classes.json', 'sections.json', 'grades.json', 'todo.json', 'focus.json', 'bookmarks.json', 'config.json')

function Backup-JkFile([string]$Name) {
    if ($script:JkBackupFiles -notcontains $Name) { return }
    $src = Get-JkPath $Name
    if (-not (Test-Path -LiteralPath $src)) { return }
    $day = (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $dir = Join-Path (Get-JkHome) "backups\$day"
    $dst = Join-Path $dir $Name
    if (Test-Path -LiteralPath $dst) { return }
    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            # a new day's folder is also the moment to drop folders older than 30 days
            $cut = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd')
            Get-ChildItem -LiteralPath (Join-Path (Get-JkHome) 'backups') -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' -and $_.Name -lt $cut } |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force
    } catch { }
}

function Write-JkText {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

# Text worth keeping between shells: a dashboard section that takes a few hundred ms to work out
# in a fresh terminal. Recomputed only when $Key changes (build it from Get-JkFileStamp of the
# files the text comes from, plus the hour or day). Kept in cache\<name>.txt, the key on line 1.
function Get-JkCached([string]$Name, [string]$Key, [scriptblock]$Compute) {
    $p = Join-Path (Get-JkHome) "cache\$Name.txt"
    try {
        if ([IO.File]::Exists($p)) {
            $t = [IO.File]::ReadAllText($p)
            $nl = $t.IndexOf("`n")
            if ($nl -ge 0 -and $t.Substring(0, $nl) -eq $Key) { return $t.Substring($nl + 1) }
        }
    } catch { }
    $v = [string](& $Compute)
    try {
        $dir = Split-Path $p
        if (-not [IO.Directory]::Exists($dir)) { $null = [IO.Directory]::CreateDirectory($dir) }
        Write-JkText $p ($Key + "`n" + $v)
    } catch { }
    $v
}

# "<ticks>-<length>" per file (or "-" for a missing one): any save changes it.
function Get-JkFileStamp([string[]]$Paths) {
    @(foreach ($p in $Paths) { $fi = New-Object IO.FileInfo $p; if ($fi.Exists) { "$($fi.LastWriteTimeUtc.Ticks)-$($fi.Length)" } else { '-' } }) -join '|'
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
    'theme'         = 'dark'      # dark | light (terminal background)
    'remind.time'   = '08:30'
    'remind.hours'  = '48'
    'alert.before'  = '2h'        # popup this long before items due today (off to disable)
    'alert.class'   = '10m'       # popup this long before each class (off to disable)
    'cp.root'       = (Join-Path $HOME 'Desktop\cp')
    'cp.lang'       = 'cpp'
    'cp.std'        = 'c++20'
    'cp.timeout'    = '3'
    'cp.port'       = '10043'     # where jk cp listen waits for Competitive Companion
    'tidy.path'     = ''          # empty = the Downloads folder
    'tidy.minAge'   = '2'
    'tidy.courses'  = ''          # where course folders live (a;b); empty = the Desktop, off = never file by course
    'shots.path'    = ''          # screenshots folder for jk shots; empty = Pictures\Screenshots
    'time.zones'    = ''          # jk time add <city>; empty = from your installed languages, off = none
    'weather.place' = ''          # jk weather set <place>; empty = Waterloo, off = no weather on the dashboard
    'stocks.watch'  = 'SPY;QQQ'   # jk stocks add/rm; none = no watchlist
    'stocks.time'   = ''          # the weekday stock popup (HH:mm); empty = the US open, 9:30 New York; off = none
    'focus.minutes' = '25'
    'plan.hours'    = '3'         # daily study budget for jk plan
    'plan.examHours' = '6'        # the same during the study break and the exam period (no classes)
    'plan.examMin'  = '15'        # prep minutes per percent of grade, exams
    'plan.dueMin'   = '30'        # work minutes per percent of grade, assignments
    'plan.skip'     = ''          # courses jk plan leaves out (health105;pd10); off = none
    'repos.roots'   = (Join-Path $HOME 'Desktop')
    'find.roots'    = ''          # folders jk find searches (a;b); empty = Desktop, Documents, Downloads
    'sync.url'      = ''          # calendar feed for jk due sync (LEARN > Calendar > Subscribe)
    'jobs.file'     = ''          # job tracker table; empty = job_application_tracker.md in a Desktop folder
    'backup.mirror' = ''          # a folder outside ~\.jk for a daily snapshot (jk backup mirror <folder>)
}

# Config is read once per `jk` call (the dispatcher clears the cache); Set-JkConfig refreshes it.
$script:JkConfigCache = $null

# Settings whose stored value is checked when read (jk config edit writes whatever is typed): one
# nothing can use falls back to its default, and jk doctor names it. remind.time "7:45 sharp" broke
# the catch-up at unlock, remind.hours "two days" the morning popup, plan.hours "lots" jk plan.
$script:JkConfigChecked = @('remind.time', 'remind.hours', 'alert.before', 'alert.class', 'notify', 'theme', 'banner', 'focus.minutes', 'cp.lang', 'cp.timeout', 'cp.port', 'tidy.minAge', 'plan.hours', 'plan.examHours', 'plan.examMin', 'plan.dueMin')

function Get-JkConfig {
    param([string]$Key)
    if ($null -eq $script:JkConfigCache) { $script:JkConfigCache = @{ Data = (Read-JkJson 'config.json' $null); Checked = @{}; Bad = @{} } }
    $cfg = $script:JkConfigCache.Data
    if ($Key) {
        $v = Get-JkProp $cfg $Key $null
        if ($null -ne $v -and "$v" -ne '' -and $script:JkConfigChecked -contains $Key) {
            $c = $script:JkConfigCache
            if (-not $c.Checked.ContainsKey($Key)) {
                try { $c.Checked[$Key] = [string](ConvertTo-JkConfigValue $Key "$v") } catch { $c.Checked[$Key] = $null; $c.Bad[$Key] = "$v" }
            }
            if ($null -ne $c.Checked[$Key]) { return $c.Checked[$Key] }
            return [string]$script:JkConfigDefaults[$Key]
        }
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
    # the explicit JK_COLOR wins over the generic NO_COLOR convention
    if ($env:JK_COLOR -eq 'always') { return $true }
    if ($env:JK_COLOR -eq 'never') { return $false }
    if ($env:NO_COLOR) { return $false }
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

# Light terminal backgrounds (jk config set theme light): text colors flip to dark, course
# colors are darkened so they stay readable, and "today" markers invert.
function Convert-JkStyleForLight([string]$Style) {
    $tokens = @($Style -split '[\s,+]+' | Where-Object { $_ })
    $invert = ($tokens -contains 'bg:white')
    $out = foreach ($t in $tokens) {
        switch -Regex ($t) {
            '^white$' { '1F2937'; break }
            '^muted$' { '4B5563'; break }
            '^gray$' { '6B7280'; break }
            '^bg:white$' { 'bg:1F2937'; break }
            '^ink$' { if ($invert) { 'FFFFFF' } else { $t }; break }
            '^#?[0-9a-fA-F]{6}$' {
                $h = $t.TrimStart('#')
                $rgb = @(0, 2, 4 | ForEach-Object { [int]([Convert]::ToInt32($h.Substring($_, 2), 16) * 0.62) })
                '{0:X2}{1:X2}{2:X2}' -f $rgb[0], $rgb[1], $rgb[2]
                break
            }
            '^(red|orange|amber|yellow|green|lime|teal|cyan|blue|purple|pink)$' {
                $h = $script:JkPalette[$t]
                $rgb = @(0, 2, 4 | ForEach-Object { [int]([Convert]::ToInt32($h.Substring($_, 2), 16) * 0.62) })
                '{0:X2}{1:X2}{2:X2}' -f $rgb[0], $rgb[1], $rgb[2]
                break
            }
            default { $t }
        }
    }
    $out -join ' '
}

function Get-JkStylePrefix([string]$Style) {
    if ($script:JkLightTheme) { $Style = Convert-JkStyleForLight $Style }
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

function Get-JkVisibleLength([string]$Text) { Get-JkTextWidth ($Text -replace "$([char]27)\[[0-9;]*m", '') }

# CJK and fullwidth characters take two terminal columns ("Desktop\<three hanzi>" is 14 wide, not 11)
$script:JkWideRx = & {
    # code-point ranges (kept as numbers so this file stays ASCII)
    $r = @(0x1100, 0x115F, 0x2E80, 0x303E, 0x3041, 0x33FF, 0x3400, 0x4DBF, 0x4E00, 0x9FFF, 0xA000, 0xA4CF, 0xAC00, 0xD7A3, 0xF900, 0xFAFF, 0xFE30, 0xFE4F, 0xFF00, 0xFF60, 0xFFE0, 0xFFE6)
    $set = for ($k = 0; $k -lt $r.Count; $k += 2) { [string][char]$r[$k] + '-' + [char]$r[$k + 1] }
    '[' + ($set -join '') + ']'
}

function Get-JkTextWidth([string]$Text) {
    if ($Text -notmatch $script:JkWideRx) { return $Text.Length }
    $Text.Length + [regex]::Matches($Text, $script:JkWideRx).Count
}

# Truncate (with an ellipsis) or pad plain text to exactly $Width columns.
function Fit {
    param([string]$Text, [int]$Width, [switch]$Right)
    if ($Width -le 0) { return '' }
    if ($null -eq $Text) { $Text = '' }
    if ($Text -match $script:JkWideRx) {
        $cols = Get-JkTextWidth $Text
        if ($cols -gt $Width) {
            $sb = New-Object Text.StringBuilder
            $cols = 1
            foreach ($ch in $Text.ToCharArray()) {
                $cw = 1; if ("$ch" -match $script:JkWideRx) { $cw = 2 }
                if ($cols + $cw -gt $Width) { break }
                [void]$sb.Append($ch); $cols += $cw
            }
            $Text = $sb.ToString() + $script:G.ell
        }
        $pad = ' ' * ($Width - $cols)
        if ($Right) { return $pad + $Text }
        return $Text + $pad
    }
    if ($Text.Length -gt $Width) { $Text = $Text.Substring(0, [Math]::Max(0, $Width - 1)) + $script:G.ell }
    if ($Right) { return $Text.PadLeft($Width) }
    $Text.PadRight($Width)
}

# A line wider than the window wraps and breaks every column under it, so Say cuts it at the
# window's width (colour codes kept, an ellipsis where it was cut). Output with no window to
# measure is left alone.
function Say([string]$Line = '') {
    $limit = Get-JkLineLimit
    if ($limit -gt 0 -and ($Line.Length -gt $limit -or ($Line.Length * 2 -gt $limit -and $Line -match $script:JkWideRx))) {
        $Line = (@($Line -split "`n") | ForEach-Object { Limit-JkLine $_ $limit }) -join "`n"
    }
    Write-Host $Line
}

function Get-JkLineLimit {
    if ($env:JK_WIDTH) { return [int]$env:JK_WIDTH }
    try { $w = $Host.UI.RawUI.WindowSize.Width; if ($w -ge 20) { return $w - 1 } } catch { }
    0
}

$script:JkAnsiAt = New-Object regex '\G\x1b\[[0-9;]*m'

function Limit-JkLine([string]$Line, [int]$Width) {
    if ((Get-JkVisibleLength $Line) -le $Width) { return $Line }
    $sb = New-Object Text.StringBuilder
    $cols = 0; $i = 0
    while ($i -lt $Line.Length) {
        $m = $script:JkAnsiAt.Match($Line, $i)
        if ($m.Success) { [void]$sb.Append($m.Value); $i += $m.Length; continue }
        $cw = 1; if ("$($Line[$i])" -match $script:JkWideRx) { $cw = 2 }
        if ($cols + $cw -gt $Width - 1) { break }
        [void]$sb.Append($Line[$i]); $cols += $cw; $i++
    }
    [void]$sb.Append($script:G.ell)
    if ($Line.IndexOf([char]27) -ge 0) { [void]$sb.Append("$([char]27)[0m") }
    $sb.ToString()
}

# Word-wrap plain text into lines of at most $Width columns.
function Split-JkWords([string]$Text, [int]$Width) {
    $out = New-Object System.Collections.Generic.List[string]
    $cur = ''
    foreach ($word in ($Text -split ' ')) {
        if ($cur -eq '') { $cur = $word; continue }
        if ((Get-JkTextWidth "$cur $word") -le $Width) { $cur = "$cur $word" } else { $out.Add($cur); $cur = $word }
    }
    if ($cur -ne '') { $out.Add($cur) }
    @($out)
}

# "1 file" / "3 files" ("1 copy" / "2 copies" with an explicit plural)
function Format-JkCount([int]$N, [string]$Noun, [string]$Plural = '') {
    if ($N -eq 1) { return "1 $Noun" }
    if (-not $Plural) { $Plural = $Noun + 's' }
    "$N $Plural"
}

# Typing slips between two words: letters added, dropped, changed or swapped ("nvdia" -> "nvidia" is 1,
# "tesal" -> "tesla" is 1). Words whose lengths differ by more than 2 are not compared (99).
function Get-JkEditDistance([string]$A, [string]$B) {
    $n = $A.Length; $m = $B.Length
    if ([Math]::Abs($n - $m) -gt 2) { return 99 }
    # row i of the table is d[i*w .. i*w+m]
    $w = $m + 1
    $d = New-Object 'int[]' (($n + 1) * $w)
    for ($i = 0; $i -le $n; $i++) { $d[$i * $w] = $i }
    for ($j = 0; $j -le $m; $j++) { $d[$j] = $j }
    for ($i = 1; $i -le $n; $i++) {
        for ($j = 1; $j -le $m; $j++) {
            $cost = 1; if ($A[$i - 1] -ceq $B[$j - 1]) { $cost = 0 }
            $up = $d[($i - 1) * $w + $j] + 1
            $left = $d[$i * $w + $j - 1] + 1
            $diag = $d[($i - 1) * $w + $j - 1] + $cost
            $v = [Math]::Min([Math]::Min($up, $left), $diag)
            if ($i -gt 1 -and $j -gt 1 -and $A[$i - 1] -ceq $B[$j - 2] -and $A[$i - 2] -ceq $B[$j - 1]) {
                $swap = $d[($i - 2) * $w + $j - 2] + 1
                if ($swap -lt $v) { $v = $swap }
            }
            $d[$i * $w + $j] = $v
        }
    }
    $d[$n * $w + $m]
}

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
    # a narrow window shortens the right-hand note rather than wrapping the header
    $room = $w - (Get-JkTextWidth $left) - 3
    if ((Get-JkTextWidth $Right) -gt $room) { if ($room -ge 12) { $Right = (Fit $Right $room).TrimEnd() } else { $Right = '' } }
    $gap = [Math]::Max(2, $w - (Get-JkTextWidth $left) - (Get-JkTextWidth $Right) - 1)
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

$script:JkMonthNames = @('january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december')
$script:JkDayNames = @('sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday')

# Where a name cut short sits in a list ("sep", "sept", "thur"), or -1. Only the name itself counts,
# not any word that starts like one ("novel 2" is not Nov 2, "sunny" is not Sunday).
function Get-JkNameIndex([string[]]$Names, [string]$Word) {
    if ($Word.Length -lt 3) { return -1 }
    for ($i = 0; $i -lt $Names.Count; $i++) { if ($Names[$i].StartsWith($Word, [StringComparison]::Ordinal)) { return $i } }
    -1
}

# A real month with a day it does not have is a typo to report, not something to read around:
# "nov 31" must not become Dec 31 with "nov" left over for a title.
function New-JkDate([int]$Year, [int]$Month, [int]$Day) {
    if ($Month -lt 1 -or $Month -gt 12) { throw "there is no month $Month (dates go month/day, as in 10/28)" }
    if ($Day -lt 1 -or $Day -gt [DateTime]::DaysInMonth($Year, $Month)) {
        throw "no such date: $((New-Object DateTime 2000, $Month, 1).ToString('MMM', $script:Inv)) $Day $Year"
    }
    New-Object DateTime $Year, $Month, $Day
}

# The errors that callers trying other readings of the words have to let through.
function Test-JkNoSuchDate($Err) { ([string]$Err.Exception.Message).StartsWith('no such date') }

# Words after a time that can only be its day: "tomorrow", "fri", "dec 25", "12/2", "2026-12-04".
# Not "3d" or a bare number ("5pm 3d printer", "Quiz 3"), and not tom/tod/now, which after a time
# are as likely a name or a word ("call at 7pm tom"). ConvertTo-JkDate still has to read them.
function Test-JkDayAfterTime([string]$Text) {
    $Text.Trim().ToLower() -match '^(?!(tom|tod|now)$)[a-z]|^\d{4}-\d{1,2}-\d{1,2}$|^\d{1,2}/\d{1,2}(/\d{2,4})?$|^\d{1,2}(st|nd|rd|th)?( of)? [a-z]{3,}'
}

# This year's unless that is over 60 days ago, then next year's. Feb 29 is judged by the end of this
# year's February, so it means the coming February or nothing, never a leap year further off.
function Resolve-JkYear([int]$Month, [int]$Day, [datetime]$Today) {
    if ($Month -lt 1 -or $Month -gt 12) { return (New-JkDate $Today.Year $Month $Day) }
    $year = $Today.Year
    $near = [Math]::Max(1, [Math]::Min($Day, [DateTime]::DaysInMonth($year, $Month)))
    if ((New-Object DateTime $year, $Month, $near) -lt $Today.AddDays(-60)) { $year++ }
    New-JkDate $year $Month $Day
}

# Accepts: today, tomorrow/tmr, yesterday, +3, 3d, 2w, next week, mon..sun, this fri, next fri,
# oct 28, 28 oct, 28th of oct, october 28 2026, 10/28, 2026-10-28, bare day-of-month (28), and a
# weekday in front of a date, as jk prints it (Mon Nov 9), which has to agree with the date.
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
    if ($t -eq 'next week') { return $today.AddDays(7) }
    if ($t -match '^(next |this )?([a-z]+)$') {
        $isNext = $Matches[1] -eq 'next '
        $target = Get-JkNameIndex $script:JkDayNames $Matches[2]
        if ($target -ge 0) {
            $delta = ($target - [int]$today.DayOfWeek + 7) % 7
            if ($isNext) { $delta += 7 }
            return $today.AddDays($delta)
        }
    }
    # "Mon Nov 9": a wrong weekday means one of the two is wrong, and only the typist knows which.
    # A plain number after it stays a time: "fri 5" is Friday at 5.
    if ($t -match '^([a-z]{3,9}) (\S.*)$') {
        $wd = Get-JkNameIndex $script:JkDayNames $Matches[1]
        $rest = $Matches[2]
        if ($wd -ge 0 -and $rest -match '\d' -and $rest -match '[a-z/-]') {
            $d = ConvertTo-JkDate $rest -Now $Now
            if ([int]$d.DayOfWeek -ne $wd) { throw "no such date: $($d.ToString('MMM d yyyy', $script:Inv)) is a $($d.DayOfWeek), not a $((Get-Culture).TextInfo.ToTitleCase($script:JkDayNames[$wd]))" }
            return $d
        }
    }
    if ($t -match '^(\d{4})-(\d{1,2})-(\d{1,2})$') { return New-JkDate ([int]$Matches[1]) ([int]$Matches[2]) ([int]$Matches[3]) }
    if ($t -match '^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})$') {
        $y = [int]$Matches[3]; if ($y -lt 100) { $y += 2000 }
        return New-JkDate $y ([int]$Matches[1]) ([int]$Matches[2])
    }
    if ($t -match '^(\d{1,2})/(\d{1,2})$') { return Resolve-JkYear ([int]$Matches[1]) ([int]$Matches[2]) $today }
    # with a dash it may not be a date at all ("Read 4-31 fri"), so an impossible one is just not a date
    if ($t -match '^(\d{1,2})-(\d{1,2})$') {
        $first = [int]$Matches[1]; $second = [int]$Matches[2]
        try { return Resolve-JkYear $first $second $today } catch { throw "can't understand the date '$Text' (try 2026-10-28, oct 28, fri, tomorrow, +3)" }
    }
    if ($t -match '^([a-z]{3,9}) ?(\d{1,2})(?:st|nd|rd|th)?(?: (\d{4}))?$') {
        $m = (Get-JkNameIndex $script:JkMonthNames $Matches[1]) + 1
        if ($m -ge 1) {
            if ($Matches[3]) { return New-JkDate ([int]$Matches[3]) $m ([int]$Matches[2]) }
            return Resolve-JkYear $m ([int]$Matches[2]) $today
        }
    }
    if ($t -match '^(\d{1,2})(?:st|nd|rd|th)?(?: of)? ?([a-z]{3,9})(?: (\d{4}))?$') {
        $m = (Get-JkNameIndex $script:JkMonthNames $Matches[2]) + 1
        if ($m -ge 1) {
            if ($Matches[3]) { return New-JkDate ([int]$Matches[3]) $m ([int]$Matches[1]) }
            return Resolve-JkYear $m ([int]$Matches[1]) $today
        }
    }
    if ($t -match '^(\d{1,2})(?:st|nd|rd|th)?$') {
        # the next date with that day number (skipping months that are too short)
        $d = [int]$Matches[1]
        if ($d -lt 1 -or $d -gt 31) { throw "there is no day $d in a month" }
        $cand = New-Object DateTime $today.Year, $today.Month, 1
        if ($d -lt $today.Day) { $cand = $cand.AddMonths(1) }
        while ([DateTime]::DaysInMonth($cand.Year, $cand.Month) -lt $d) { $cand = $cand.AddMonths(1) }
        return $cand.AddDays($d - 1)
    }
    throw "can't understand the date '$Text' (try 2026-10-28, oct 28, fri, tomorrow, +3)"
}

$script:JkMonthRx = '(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?$'

# `-From sep 9` binds "sep" to -From and leaves "9" over. Given an option's value and the
# leftover words, returns the value extended with as many leftovers as make it a valid date.
function Join-JkLooseDate([string]$Value, [System.Collections.Generic.List[string]]$Extra) {
    if (-not $Value) { return $Value }
    $ok = $true
    try { $null = ConvertTo-JkDate $Value } catch { $ok = $false }
    while (-not $ok -and $Extra.Count -gt 0) {
        $Value = "$Value $($Extra[0])"
        $Extra.RemoveAt(0)
        try { $null = ConvertTo-JkDate $Value; $ok = $true } catch { }
    }
    $Value
}

# Accepts: 8pm, 8:30 pm, 20:00, 2359, 930, 220pm, noon, midnight/eod (23:59). Returns 'HH:mm'.
function ConvertTo-JkTime {
    param([string]$Text)
    $t = $Text.Trim().ToLower() -replace '\.', ''
    if ($t -match '^(noon)$') { return '12:00' }
    if ($t -match '^(midnight|eod|end of day)$') { return '23:59' }
    if ($t -match '^(\d{1,2})(?::(\d{2}))? ?(am|pm|a|p)?$') {
        $h = [int]$Matches[1]; $mi = 0
        if ($Matches[2]) { $mi = [int]$Matches[2] }
        $ap = $Matches[3]
        # "15:00 am" and "0 pm" contradict themselves; "15:20pm" and "0:30 am" only say a thing twice
        if (($ap -like 'a*' -and $h -gt 12) -or ($ap -like 'p*' -and $h -eq 0)) { throw "invalid time '$Text'" }
        if ($ap -like 'p*' -and $h -lt 12) { $h += 12 }
        if ($ap -like 'a*' -and $h -eq 12) { $h = 0 }
        if ($h -gt 23 -or $mi -gt 59) { throw "invalid time '$Text'" }
        return '{0:00}:{1:00}' -f $h, $mi
    }
    if ($t -match '^(\d{1,2})(\d{2})$') {
        $h = [int]$Matches[1]; $mi = [int]$Matches[2]
        if ($h -gt 23 -or $mi -gt 59) { throw "invalid time '$Text'" }
        return '{0:00}:{1:00}' -f $h, $mi
    }
    # the colon left out: "220pm", "1130am"
    if ($t -match '^(\d{1,2})(\d{2}) ?(am|pm|a|p)$') {
        $h = [int]$Matches[1]; $mi = [int]$Matches[2]; $ap = $Matches[3]
        if ($h -lt 1 -or $h -gt 12 -or $mi -gt 59) { throw "invalid time '$Text'" }
        if ($ap -like 'p*' -and $h -lt 12) { $h += 12 }
        if ($ap -like 'a*' -and $h -eq 12) { $h = 0 }
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

# A day gone by, for "overdue since ...": its weekday while that names one day ("Tue"), with the
# date from a week back on ("Tue Oct 6"), where the weekday alone would point at the wrong week.
function Format-JkPastDay([datetime]$Date, [datetime]$Now = (Get-JkNow)) {
    if (($Now.Date - $Date.Date).TotalDays -ge 7) { return $Date.ToString('ddd MMM d', $script:Inv) }
    $Date.ToString('ddd', $script:Inv)
}

# The same going forward: "Thu" for the coming days, the date from a week out, where the weekday is
# today's own ("Sun Nov 29" on a Sunday, not "Sun"). -Short gives the date alone, for a narrow column.
function Format-JkComingDay([datetime]$Date, [datetime]$Now = (Get-JkNow), [switch]$Short) {
    if (($Date.Date - $Now.Date).TotalDays -ge 7) { return $Date.ToString($(if ($Short) { 'MMM d' } else { 'ddd MMM d' }), $script:Inv) }
    $Date.ToString('ddd', $script:Inv)
}

# A path as typed, made full. Inside a folder with [ in its name, PowerShell 5.1 finds nothing by a
# relative -LiteralPath, so anything a person types goes through this before it is looked up.
function Get-JkFullPath([string]$Path) {
    try { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) } catch { $Path }
}

# Whether a program that takes its arguments through the Windows code page (g++, javac, pdftotext)
# can be handed this path: anything outside the code page reaches it as "?" and the file is not found.
function Test-JkAnsiPath([string]$Path) {
    $enc = [Text.Encoding]::Default
    $enc.GetString($enc.GetBytes($Path)) -ceq $Path
}

# Natural sort key: pads digit runs so 2.in sorts before 10.in.
function Get-JkNaturalKey([string]$s) { [regex]::Replace($s, '\d+', { param($m) $m.Value.PadLeft(12, '0') }) }

# ---------------------------------------------------------------- background work

function Get-JkPowerShellExe { Join-Path $PSHOME 'powershell.exe' }

# Runs a script block in a detached, windowless PowerShell that has jk loaded.
# Returns the process so callers can record its PID.
# The command line a background process runs. With -WaitUntil it sleeps first and only then
# loads the module: a waiting timer holds about 60 MB instead of 95, and when it fires it runs
# the current code even if jk was updated in the meantime.
function Get-JkBackgroundCommand {
    param([string]$Script, [hashtable]$Env = @{}, [string]$WaitUntil)
    $psd1 = Join-Path (Get-JkRoot) 'jk.psd1'
    $prelude = ''
    if ($WaitUntil) {
        # polls instead of one long sleep so a laptop that suspends mid-wait still fires
        # promptly after it wakes up. Counted in UTC: the night clocks fall back, 1:30 comes twice,
        # and a timer for the second one (-05:00) compared by the clock fired at the first.
        $prelude += "`$at = [DateTimeOffset]::Parse('" + $WaitUntil.Replace("'", "''") + "', [Globalization.CultureInfo]::InvariantCulture).UtcDateTime; "
        $prelude += "while (`$true) { `$left = (`$at - [DateTime]::UtcNow).TotalSeconds; if (`$left -le 0) { break }; Start-Sleep -Milliseconds ([int]([Math]::Min(`$left, 15) * 1000)) }; "
    }
    $prelude += "`$env:JK_HOME = '" + (Get-JkHome).Replace("'", "''") + "'; "
    foreach ($k in $Env.Keys) { $prelude += "`$env:$k = '" + ([string]$Env[$k]).Replace("'", "''") + "'; " }
    $prelude += "`$jkm = Import-Module '" + $psd1.Replace("'", "''") + "' -Force -PassThru; "
    # run inside the module's scope (the helpers are private); failures in a windowless
    # process are invisible, so they go to background.log
    $log = (Join-Path (Get-JkHome) 'background.log').Replace("'", "''")
    $prelude + "& `$jkm { try { $Script } catch { Add-Content -LiteralPath '$log' -Value ((Get-Date -Format s) + ' ' + `$_.Exception.Message + ' @ ' + `$_.ScriptStackTrace) } }"
}

function Start-JkBackground {
    param([string]$Script, [hashtable]$Env = @{}, [string]$WaitUntil)
    $full = Get-JkBackgroundCommand -Script $Script -Env $Env -WaitUntil $WaitUntil
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))
    $ps = Get-JkPowerShellExe
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $argsList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded)
    if (Test-Path -LiteralPath $conhost) {
        Start-Process -FilePath $conhost -ArgumentList (@('--headless', $ps) + $argsList) -WindowStyle Hidden -PassThru
    } else {
        Start-Process -FilePath $ps -ArgumentList $argsList -WindowStyle Hidden -PassThru
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

# The card's XAML on its own, so a test can lay it out and look at it without showing a window.
function New-JkPopupXaml([string]$Title, [string[]]$Lines = @(), [string]$Accent = '7C9CF8', [string]$Open = '', [string]$OpenLabel = 'Open') {
    # a value starting with { is a markup extension in XAML: "{Quiz} 3 closes" would stop the card
    # from being read at all, and that morning's popup with it. {} in front says "plain text".
    $x = { param($s) $e = [Security.SecurityElement]::Escape([string]$s); if ($e.StartsWith('{')) { '{}' + $e } else { $e } }
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
    $xaml
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
    $win = [Windows.Markup.XamlReader]::Parse((New-JkPopupXaml $Title $Lines $Accent $Open $OpenLabel))
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

    # Several popups at once (a reminder and a focus timer, say) stack instead of overlapping:
    # each claims the lowest free slot through a named mutex held until it closes.
    $slot = 0; $slotMutex = $null
    for ($i = 0; $i -lt 4; $i++) {
        $created = $false
        $mx = [System.Threading.Mutex]::new($true, "Local\jk-popup-slot-$i", [ref]$created)
        if ($created) { $slot = $i; $slotMutex = $mx; break }
        $mx.Dispose()
    }
    $win.Add_Loaded({
        $offset = $slot * ($win.ActualHeight - 8)
        # never above the screen, where the title and the close button would be out of reach: a tall
        # card, or a second one stacked over it, overlaps instead
        $target = [Math]::Max($area.Top + 4, $area.Bottom - $win.ActualHeight - 4 - $offset)
        $win.Top = $target + 20
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
            Add-Content -LiteralPath (Join-Path (Get-JkHome) 'background.log') -Value ('{0} popup shown "{1}" slot {8} {2:N0}x{3:N0} at left {4:N0}, settling at top {5:N0} (work area {6:N0}x{7:N0})' -f (Get-Date -Format s), $Title, $win.ActualWidth, $win.ActualHeight, $win.Left, $target, $area.Width, $area.Height, $slot)
        }
    })
    if ($Sound) { try { [System.Media.SystemSounds]::Asterisk.Play() } catch { } }
    # Show() + a private dispatcher loop (not ShowDialog) so the card never takes keyboard focus.
    $win.Add_Closed({
        if ($slotMutex) { try { $slotMutex.ReleaseMutex() } catch { }; $slotMutex.Dispose() }
        $win.Dispatcher.InvokeShutdown()
    })
    $win.Show()
    [System.Windows.Threading.Dispatcher]::Run()
}
