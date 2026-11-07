# setup.ps1 - config, doctor, and install/uninstall of the profile hook + scheduled task.

$script:ProfileStart = '# >>> jk >>>'
$script:ProfileEnd = '# <<< jk <<<'

# What jk config set stores for a key. A value nothing can read used to be saved as typed and broke
# something later: remind.hours 2d stopped the morning popup, plan.hours 3h stopped jk plan, and a
# relative cp.root meant another folder in every terminal. Throws with what the key takes.
#   key = lowest, highest, whole numbers only, what the number counts
$script:JkConfigNumbers = @{
    'remind.hours'   = @(1, 336, $false, 'hours the morning popup looks ahead')
    'tidy.minAge'    = @(0, 3650, $true, 'days')
    'cp.timeout'     = @(0.1, 600, $false, 'seconds')
    'cp.port'        = @(1, 65535, $true, 'a port')
    'plan.hours'     = @(0, 24, $false, 'hours a day')
    'plan.examHours' = @(0, 24, $false, 'hours a day')
    'plan.examMin'   = @(0, 600, $false, 'minutes per percent')
    'plan.dueMin'    = @(0, 600, $false, 'minutes per percent')
}
$script:JkConfigFolders = @('cp.root', 'tidy.path', 'shots.path')
$script:JkConfigFolderLists = @('tidy.courses', 'find.roots', 'repos.roots')

function ConvertTo-JkConfigValue([string]$Key, [string]$Value) {
    $v = $Value.Trim()
    if ($script:JkConfigNumbers.ContainsKey($Key)) {
        $spec = $script:JkConfigNumbers[$Key]
        # "2,5" from a decimal-comma keyboard is 2.5
        $t = $v -replace '^(\d+),(\d+)$', '$1.$2'
        $n = 0.0
        $ok = $t -match '^\d+(\.\d+)?$' -and [double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)
        if ($ok -and $spec[2] -and $t.Contains('.')) { $ok = $false }
        if (-not $ok -or $n -lt $spec[0] -or $n -gt $spec[1]) {
            $kind = 'a number'; if ($spec[2]) { $kind = 'a whole number' }
            throw "$Key takes $kind from $($spec[0]) to $($spec[1]) ($($spec[3])), not '$v'"
        }
        return $t
    }
    switch ($Key) {
        'focus.minutes' {
            # any length jk focus reads ("25", "50m", "1h30m"), and nothing after it: a second word
            # would become the label of every session
            $words = @(-split $v)
            $d = $null; try { $d = Read-JkDurationWords $words } catch { }
            if (-not $d -or $d.Used -ne $words.Count -or $d.Seconds -le 0) { throw "focus.minutes takes a length such as 25, 50m or 1h30m, not '$v'" }
            return $v
        }
        'banner' {
            if ($v -match '^(on|yes|true|1)$') { return 'on' }
            if ($v -match '^(off|no|false|0)$') { return 'off' }
            throw "banner is on or off, not '$v'"
        }
        'cp.lang' {
            if ($v -match '^(cpp|py|java|usaco)$') { return $v.ToLower() }
            throw "cp.lang is cpp, py, java or usaco, not '$v'"
        }
    }
    # folders are stored in full, so every terminal means the same one; %VARIABLES% are kept as
    # written (they are expanded when read)
    $full = { param($p) $p = ([string]$p).Trim().Trim('"'); if (-not $p -or $p.Contains('%')) { return $p }; Get-JkFullPath $p }
    if ($script:JkConfigFolders -contains $Key) { return (& $full $v) }
    if ($script:JkConfigFolderLists -contains $Key) {
        if ($Key -eq 'tidy.courses' -and $v -match '^(off|none)$') { return 'off' }
        return (@($v -split ';' | ForEach-Object { & $full $_ } | Where-Object { $_ }) -join ';')
    }
    if ($Key -eq 'jobs.file' -and $v) {
        $p = & $full $v
        $real = [Environment]::ExpandEnvironmentVariables($p)
        # the folder that holds the tracker means the tracker
        if ([IO.Directory]::Exists($real)) {
            if ([IO.File]::Exists((Join-Path $real 'job_application_tracker.md'))) { return (Join-Path $p 'job_application_tracker.md') }
            throw "no job_application_tracker.md in $real"
        }
        if (-not [IO.File]::Exists($real)) { throw "no such file: $real" }
        return $p
    }
    $v
}

function Invoke-JkConfig {
    $a = @($args | ForEach-Object { [string]$_ })
    if ($a.Count -eq 0) {
        $all = Get-JkConfig
        $cfg = Read-JkJson 'config.json' $null
        Write-JkHeader 'Config' (Get-JkPath 'config.json')
        # empty defaults that mean "work it out": say what they come to here
        $userDir = [Environment]::GetFolderPath('UserProfile').TrimEnd('\')
        $short = { param($p) if ($p -and $p.StartsWith($userDir + '\', [StringComparison]::OrdinalIgnoreCase)) { '~' + $p.Substring($userDir.Length) } else { $p } }
        $auto = [ordered]@{
            'tidy.path'    = { & $short (Get-JkDownloadsPath) }
            'tidy.courses' = { "$(Format-JkCount @((Get-JkCourseFolders).Keys).Count 'course folder') found on the Desktop" }
            'find.roots'   = { (@(Get-JkFindRoots) | ForEach-Object { & $short $_ }) -join '; ' }
            'shots.path'   = { & $short (Get-JkShotsPath) }
            'time.zones'   = { $p = @(Get-JkClockPlaces); if ($p.Count) { (@($p | ForEach-Object { $_.Name }) -join ', ') + ' (from your languages)' } else { 'none' } }
            'weather.place' = { $p = Get-JkWeatherPlace -NoLookup; if ($p) { $p.Name } else { 'off' } }
            'sync.url'     = { 'not connected yet - jk due sync' }
            'jobs.file'    = { $f = Find-JkJobsFile; if ($f) { "found $(& $short $f)" } else { 'none found on the Desktop' } }
        }
        foreach ($k in $all.Keys) {
            $isSet = $cfg -and $cfg.PSObject.Properties[$k]
            $st = 'muted'; if ($isSet) { $st = 'white' }
            $shown = [string]$all[$k]
            # feed links carry a private token: show only the start
            if ($k -like '*url*' -and $shown.Length -gt 36) { $shown = $shown.Substring(0, 36) + $script:G.ell }
            $tag = ''
            if (-not $isSet) {
                $tag = '  (default)'
                if (-not $shown -and $auto.Contains($k)) { try { $tag = "(default: $(& $auto[$k]))" } catch { } }
            }
            Say ('  ' + (Paint 'cyan' (Fit $k 16)) + (Paint $st $shown) + (Paint 'gray' $tag))
        }
        Say ''
        Say (Paint 'gray' '  jk config set <key> <value>   |   jk config reset <key>   |   jk help config')
        return
    }
    switch -Regex ($a[0].ToLower()) {
        '^set$' {
            if ($a.Count -lt 3) { throw 'usage: jk config set <key> <value>' }
            $key = $a[1]; $val = ($a[2..($a.Count - 1)]) -join ' '
            # nothing reads a misspelt setting: "tidy.cources" would be saved and do nothing, silently
            if (-not $script:JkConfigDefaults.Contains($key)) {
                $near = @($script:JkConfigDefaults.Keys | Where-Object { $_.Split('.')[0] -eq ([string]$key).Split('.')[0] })
                if (-not $near.Count) { $near = @($script:JkConfigDefaults.Keys) }
                throw "there is no setting '$key' (try: $($near -join ', '))"
            }
            # the mirror takes jk backup mirror's checks (a full path, outside the data folder) and its
            # first snapshot
            if ($key -eq 'backup.mirror') { Invoke-JkBackupMirror @('mirror', $val); return }
            $val = ConvertTo-JkConfigValue $key $val
            if ($key -eq 'remind.time') { $val = ConvertTo-JkTime $val }
            if ($key -eq 'notify' -and $val -notmatch '^(auto|popup|toast|off)$') { throw 'notify must be auto, popup, toast or off' }
            if ($key -eq 'theme' -and $val -notmatch '^(dark|light)$') { throw 'theme must be dark or light (your terminal background)' }
            if ($key -match '^alert\.(before|class)$' -and $val -notmatch '^(0|off|none)$') { $null = ConvertTo-JkSeconds $val }
            Set-JkConfig $key $val
            Clear-JkBriefCache
            $echo = $val
            if ($key -like '*url*' -and $echo.Length -gt 36) { $echo = $echo.Substring(0, 36) + $script:G.ell }
            Say ((Paint 'green' "  $key = $echo") + " $($script:G.check)")
            if (($script:JkConfigFolders + $script:JkConfigFolderLists) -contains $key) {
                $missing = @($val -split ';' | Where-Object { $_ -and $_ -ne 'off' -and -not [IO.Directory]::Exists([Environment]::ExpandEnvironmentVariables($_)) })
                if ($missing.Count) { Say (Paint 'gray' "  not there yet: $($missing -join '; ')") }
            }
            if ($key -eq 'remind.time' -and (Get-JkTaskInfo)) { $null = Install-JkRemindTask }
            return
        }
        '^(reset|unset)$' {
            if ($a.Count -lt 2) { throw 'usage: jk config reset <key>' }
            $cfg = Read-JkJson 'config.json' $null
            $stored = $cfg -and $cfg.PSObject.Properties[$a[1]]
            # one saved under a misspelt name can still be cleared
            if (-not $stored -and -not $script:JkConfigDefaults.Contains($a[1])) { throw "there is no setting '$($a[1])'" }
            if ($stored) { $cfg.PSObject.Properties.Remove($a[1]); Save-JkJson 'config.json' $cfg }
            $script:JkConfigCache = $null
            Say (Paint 'green' "  $($a[1]) reset to default ($(Get-JkConfig $a[1]))")
            return
        }
        '^edit$' { $p = Get-JkPath 'config.json'; if (-not (Test-Path -LiteralPath $p)) { Save-JkJson 'config.json' ([pscustomobject]@{}) }; Open-JkInEditor $p; return }
        '^path$' { Say (Get-JkHome); return }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'config'; return }
    }
    # jk config <key>  -> print value
    Say (Get-JkConfig $a[0])
}

# jk backup                 list the daily snapshots
# jk backup restore <day>   put that day's files back (current ones are set aside first)
# The daily backups live inside the data folder, so deleting that folder (or losing its drive)
# takes them too. A mirror keeps one snapshot of the data files per day somewhere else - another
# drive, a USB stick, a synced folder - written by the morning task; 30 days are kept there.
function Sync-JkBackupMirror([datetime]$Now = (Get-Date)) {
    $mirror = Get-JkConfig 'backup.mirror'
    if (-not $mirror) { return $null }
    if (-not (Test-Path -LiteralPath $mirror)) { New-Item -ItemType Directory -Path $mirror -Force | Out-Null }
    $day = $Now.ToString('yyyy-MM-dd', $script:Inv)
    $dir = Join-Path $mirror $day
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $n = 0
    foreach ($name in $script:JkBackupFiles) {
        $src = Get-JkPath $name
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $dir $name) -Force; $n++ }
    }
    # only day folders jk wrote are pruned. A mirror set on a folder that already had dated folders
    # of its own (photo imports, exports) used to lose every one older than 30 days, for good.
    $cut = $Now.AddDays(-30).ToString('yyyy-MM-dd', $script:Inv)
    foreach ($old in @(Get-ChildItem -LiteralPath $mirror -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' -and $_.Name -lt $cut })) {
        if (Test-JkSnapshotDir $old.FullName) { Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
    [pscustomobject]@{ Dir = $dir; Files = $n }
}

# A day folder of jk's backups: no subfolders and no files but the data files they copy. One that
# cannot be listed is not.
function Test-JkSnapshotDir([string]$Dir) {
    try { $items = @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction Stop) } catch { return $false }
    foreach ($i in $items) { if ($i.PSIsContainer -or $script:JkBackupFiles -notcontains $i.Name) { return $false } }
    $true
}

function Invoke-JkBackupMirror([string[]]$A) {
    if ($A.Count -lt 2) {
        $m = Get-JkConfig 'backup.mirror'
        if (-not $m) { Say (Paint 'gray' '  no mirror. jk backup mirror <folder on another drive, a USB stick or a synced folder>'); return }
        $days = @(Get-ChildItem -LiteralPath $m -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending)
        Say ('  ' + (Paint 'green' "$($script:G.check) mirror") + "  $m" + (Paint 'gray' "  $($script:G.dot) $($days.Count) day$(if ($days.Count -ne 1) {'s'}), latest $(if ($days) { $days[0].Name } else { 'none yet' })"))
        return
    }
    if ($A[1] -match '^(off|none|stop)$') {
        Invoke-JkConfig reset backup.mirror
        Say (Paint 'yellow' '  mirror off (snapshots already there are kept)')
        return
    }
    $path = ($A[1..($A.Count - 1)] -join ' ').Trim('"')
    if (-not [IO.Path]::IsPathRooted($path)) { throw 'give a full path, for example D:\jk-backup' }
    $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
    $homeFull = [IO.Path]::GetFullPath((Get-JkHome)).TrimEnd('\')
    if ($full -eq $homeFull -or $full.StartsWith($homeFull + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'the mirror must be outside the data folder, or it is lost along with it' }
    Set-JkConfig 'backup.mirror' $full
    $r = Sync-JkBackupMirror
    Say ((Paint 'green' "  mirror on $($script:G.check)") + "  $full" + (Paint 'gray' "  $($script:G.dot) today's snapshot: $($r.Files) files; the morning task adds one each day (30 kept)"))
}

# The newest day (on or before -Before, if given) whose snapshot holds <name>.json, from the local
# backups or else the mirror. $null when there is none.
function Get-JkNewestSnapshot([string]$Name, [string]$Before = '9999-12-31') {
    foreach ($root in @((Join-Path (Get-JkHome) 'backups'), (Get-JkConfig 'backup.mirror'))) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        $hit = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' -and $_.Name -le $Before -and (Test-Path -LiteralPath (Join-Path $_.FullName "$Name.json")) } | Sort-Object Name -Descending)
        if ($hit) { return $hit[0].Name }
    }
    $null
}

function Invoke-JkBackup {
    $a = @($args | ForEach-Object { [string]$_ })
    if ($a.Count -and $a[0] -match '^(mirror|copy)$') { Invoke-JkBackupMirror $a; return }
    $root = Join-Path (Get-JkHome) 'backups'
    $days = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending)
    if ($a.Count -eq 0 -or $a[0] -match '^(list|ls)$') {
        Write-JkHeader 'Backups' "$($days.Count) day$(if ($days.Count -ne 1) {'s'}) kept (30 max)" -Sub $root
        if (-not $days) { Say (Paint 'gray' '  none yet - a snapshot is taken before the first change of each day') }
        foreach ($d in $days) {
            $files = @(Get-ChildItem -LiteralPath $d.FullName -File | Where-Object { $_.Name -like '*.json' } | ForEach-Object { $_.BaseName })
            Say ('  ' + (Paint 'white' (Fit $d.Name 12)) + (Paint 'muted' ($files -join ', ')))
        }
        if ($days) {
            # a day keeps only the files that changed on it: the example names one that has deadlines
            $ex = @($days | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'deadlines.json') })[0]
            Say ''
            Say (Paint 'gray' "  jk backup restore $($days[0].Name)   (every file that day)")
            if ($ex) { Say (Paint 'gray' "  jk backup restore deadlines   (the newest snapshot of one file: $($ex.Name))") }
        }
        return
    }
    if ($a[0] -notmatch '^(restore|undo)$') { throw 'usage: jk backup  |  jk backup restore <yyyy-mm-dd> [deadlines|grades|todo|classes|...]  |  jk backup restore deadlines  |  jk backup mirror <folder>' }
    if ($a.Count -lt 2) { throw 'which day? see: jk backup' }
    # "jk backup restore deadlines": the newest snapshot of that file, here or in the mirror
    if ($a[1] -notmatch '^\d{4}-\d{2}-\d{2}$') {
        $want = $a[1].ToLower() -replace '\.json$', ''
        $day = Get-JkNewestSnapshot $want
        if (-not $day) { throw "no snapshot of $want.json yet (see: jk backup)" }
        $a = @($a[0], $day, $want)
    }
    $dir = Join-Path $root $a[1]
    if (-not (Test-Path -LiteralPath $dir)) {
        # the local backups go with the data folder; the mirror is what survives that
        $m = Get-JkConfig 'backup.mirror'
        if ($m -and (Test-Path -LiteralPath (Join-Path $m $a[1]))) { $dir = Join-Path $m $a[1]; Say (Paint 'gray' "  restoring from the mirror ($m)") }
        else { throw "no backup for '$($a[1])' (see: jk backup)" }
    }
    $pick = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.json')
    if ($a.Count -ge 3) {
        $want = $a[2].ToLower() -replace '\.json$', ''
        $pick = @($pick | Where-Object { $_.BaseName -eq $want })
        if (-not $pick) {
            # it did not change that day; point at the snapshot that holds it
            $older = Get-JkNewestSnapshot $want $a[1]
            if ($older) { throw "$($a[1]) has no $want.json (it did not change that day); the newest snapshot before it: jk backup restore $older $want" }
            throw "that day has no $want.json"
        }
    }
    $stamp = (Get-Date).ToString('HHmmss')
    $aside = Join-Path $root ((Get-Date).ToString('yyyy-MM-dd') + "-before-restore-$stamp")
    New-Item -ItemType Directory -Path $aside -Force | Out-Null
    foreach ($f in $pick) {
        $cur = Get-JkPath $f.Name
        if (Test-Path -LiteralPath $cur) { Copy-Item -LiteralPath $cur -Destination (Join-Path $aside $f.Name) -Force }
        Copy-Item -LiteralPath $f.FullName -Destination $cur -Force
        Say ((Paint 'green' "  restored $($script:G.check)") + "  $($f.Name) from $($a[1])")
    }
    Clear-JkBriefCache
    $script:JkConfigCache = $null
    Say (Paint 'gray' "  the files you had before are in $aside")
}

# jk update: fast-forward the jk checkout from GitHub and reload the module.
function Update-Jk {
    $root = Get-JkRoot
    if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) { throw "$root is not a git checkout" }
    # untracked files (a preview.html from tools\ansi2html) never block a fast-forward
    if (@(& git -C $root status --porcelain --untracked-files=no 2>$null).Count) { throw "the jk folder has uncommitted changes; commit or stash them first ($root)" }
    $before = (& git -C $root rev-parse HEAD 2>$null)
    $branch = (& git -C $root branch --show-current 2>$null)
    Say (Paint 'gray' "  pulling $branch$($script:G.ell)")
    $out = & git -C $root pull --ff-only 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git pull failed: $(($out | Select-Object -Last 2) -join ' ')" }
    $after = (& git -C $root rev-parse HEAD 2>$null)
    if ($before -eq $after) { Say (Paint 'green' "  already up to date $($script:G.check)"); return }
    Say (Paint 'green' "  updated $($script:G.check)")
    foreach ($l in @(& git -C $root log --oneline -n 15 "$before..$after" 2>$null)) { Say ('    ' + (Paint 'muted' $l)) }
    Import-Module (Join-Path $root 'jk.psd1') -Force -Global
    Say (Paint 'gray' '  module reloaded')
}

# JK_SANDBOX (tests\smoke.ps1): install and uninstall into that folder instead of the real module
# path, profile and Task Scheduler, so the full round trip can run on a machine in daily use.
function Get-JkModuleLink {
    if ($env:JK_SANDBOX) { return Join-Path $env:JK_SANDBOX 'Modules\jk' }
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules\jk'
}

# The hook prints the cached one-line brief without loading the module (new shells stay
# fast) and registers a stub completer that imports jk on the first <Tab>.
function Get-JkProfileBlock {
    @'
# >>> jk >>>
# jk toolkit (jk setup uninstall removes this block)
if ($Host.Name -eq 'ConsoleHost' -and [Environment]::UserInteractive -and -not ([Environment]::GetCommandLineArgs() -match '^-NonI')) {
    $jkHome = $env:JK_HOME; if (-not $jkHome) { $jkHome = Join-Path $HOME '.jk' }
    $jkCache = $null; try { $jkCache = [IO.File]::ReadAllLines((Join-Path $jkHome 'brief.cache')) } catch { }
    if ($jkCache -and $jkCache[0] -eq (Get-Date).ToString('yyyy-MM-dd HH')) { if ($jkCache.Count -gt 1 -and $jkCache[1]) { Write-Host $jkCache[1] } }
    else { try { jk brief } catch { } }
    Remove-Variable jkHome, jkCache -ErrorAction SilentlyContinue
}
Register-ArgumentCompleter -Native -CommandName jk, j -ScriptBlock {
    param($w, $ast, $pos)
    $m = Get-Module jk; if (-not $m) { $m = Import-Module jk -PassThru }
    & $m { param($w, $ast, $pos) Invoke-JkCompleter $w $ast $pos } $w $ast $pos
}
# <<< jk <<<
'@ -replace "`r?`n", "`r`n"
}

function Get-JkProfilePath {
    if ($env:JK_SANDBOX) { return Join-Path $env:JK_SANDBOX 'profile.ps1' }
    $PROFILE.CurrentUserCurrentHost
}

function Test-JkProfileHook {
    $p = Get-JkProfilePath
    (Test-Path -LiteralPath $p) -and ([IO.File]::ReadAllText($p)).Contains($script:ProfileStart)
}

function Install-JkProfileHook {
    param([string]$Path = (Get-JkProfilePath))
    $p = $Path
    $dir = Split-Path $p -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $text = ''
    $bak = "$p.jk-hook-backup"
    if (Test-Path -LiteralPath $p) {
        $text = [IO.File]::ReadAllText($p)
        # the profile as it was before jk ever touched it: written once, never replaced by a later
        # install (which would back up the already-hooked file), and not shared with jk speed
        if (-not (Test-Path -LiteralPath $bak) -and -not $text.Contains($script:ProfileStart)) { Copy-Item -LiteralPath $p -Destination $bak }
    }
    $text = Remove-JkProfileBlock $text
    $text = $text.TrimEnd() + "`r`n`r`n" + (Get-JkProfileBlock) + "`r`n"
    # keep the profile's encoding PowerShell-5.1-friendly (UTF-8 with BOM handles any non-ASCII already there)
    [IO.File]::WriteAllText($p, $text.TrimStart(), (New-Object Text.UTF8Encoding $true))
    $bakNote = ''; if (Test-Path -LiteralPath $bak) { $bakNote = ' (original: .jk-hook-backup)' }
    Say ((Paint 'green' "  $($script:G.check) profile hook added") + (Paint 'gray' " $($script:G.dot) $p$bakNote"))
}

function Remove-JkProfileBlock([string]$Text) {
    $s = [regex]::Escape($script:ProfileStart); $e = [regex]::Escape($script:ProfileEnd)
    [regex]::Replace($Text, "(\r?\n)*$s[\s\S]*?$e\r?\n?", "`r`n")
}

function Uninstall-JkProfileHook {
    $p = Get-JkProfilePath
    if (-not (Test-JkProfileHook)) { Say (Paint 'gray' '  profile hook was not installed'); return }
    $text = Remove-JkProfileBlock ([IO.File]::ReadAllText($p))
    [IO.File]::WriteAllText($p, $text.Trim() + "`r`n", (New-Object Text.UTF8Encoding $true))
    Say (Paint 'yellow' "  removed profile hook from $p")
}

# Puts the module on PSModulePath via a junction, so `jk` autoloads in every new shell.
function Install-JkModuleLink {
    $link = Get-JkModuleLink
    $root = Get-JkRoot
    if ((Resolve-Path -LiteralPath $root).ProviderPath -eq $link) { return }
    if (Test-Path -LiteralPath $link) {
        $item = Get-Item -LiteralPath $link -Force
        if ($item.LinkType -eq 'Junction' -and ($item.Target -contains $root -or "$($item.Target)" -eq $root)) { Say (Paint 'gray' "  module link already in place ($link)"); return }
        if ($item.LinkType) { $item.Delete() }
        else { throw "$link exists and is a real folder; remove it or run jk from there" }
    }
    $parent = Split-Path $link -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    New-Item -ItemType Junction -Path $link -Target $root | Out-Null
    Say ((Paint 'green' "  $($script:G.check) module linked") + (Paint 'gray' " $($script:G.dot) $link $($script:G.arrow) $root"))
}

function Uninstall-JkModuleLink {
    $link = Get-JkModuleLink
    if (Test-Path -LiteralPath $link) {
        $item = Get-Item -LiteralPath $link -Force
        if ($item.LinkType -eq 'Junction') { $item.Delete(); Say (Paint 'yellow' "  removed module link $link") }
    }
}

function Invoke-JkSetup {
    $a = @($args | ForEach-Object { [string]$_ })
    $action = 'status'
    if ($a.Count) { $action = $a[0].ToLower() }
    switch -Regex ($action) {
        '^install$' {
            Say ''
            Install-JkModuleLink
            Install-JkProfileHook
            try { $null = Install-JkRemindTask } catch { Say (Paint 'red' "  could not register the scheduled task: $($_.Exception.Message)") }
            if (@((Get-JkDueData).events).Count) { Export-JkDueHtml -NoOpen }
            Say ''
            Say ('  ' + (Paint 'bold green' 'jk is installed.') + ' Open a new terminal and type ' + (Paint 'cyan' 'jk') + '.')
            return
        }
        '^(uninstall|remove)$' {
            Uninstall-JkProfileHook
            Uninstall-JkRemindTask
            Uninstall-JkModuleLink
            Say (Paint 'gray' "  your data is still in $(Get-JkHome) - delete that folder to remove it too")
            if (@(Get-JkProfileFiles | Where-Object { ([IO.File]::ReadAllText($_.Path)) -match 'jk speed: fast conda' }).Count) {
                Say (Paint 'gray' '  the fast conda block in profile.ps1 stays (it does not need jk); jk speed undo, run before uninstalling, restores the original')
            }
            return
        }
        '^(status)$' { Invoke-JkDoctor; return }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'setup'; return }
    }
    throw "unknown setup action '$action' (install | uninstall | status)"
}

function Invoke-JkDoctor {
    Write-JkHeader 'jk doctor' "data: $(Get-JkHome)"
    $ok = { param($label, $detail) Say ('  ' + (Paint 'green' $script:G.check) + ' ' + (Paint 'white' (Fit $label 24)) + (Paint 'gray' $detail)) }
    $bad = { param($label, $detail) Say ('  ' + (Paint 'red' $script:G.cross) + ' ' + (Paint 'white' (Fit $label 24)) + (Paint 'orange' $detail)) }
    $meh = { param($label, $detail) Say ('  ' + (Paint 'yellow' '!') + ' ' + (Paint 'white' (Fit $label 24)) + (Paint 'muted' $detail)) }

    $link = Get-JkModuleLink
    if ((Test-Path -LiteralPath $link) -or (Get-JkRoot) -eq $link) { & $ok 'module on PSModulePath' $link } else { & $bad 'module on PSModulePath' 'not linked - jk setup install' }
    if (Test-JkProfileHook) { & $ok 'profile hook' (Get-JkProfilePath) } else { & $meh 'profile hook' 'not installed (optional) - jk setup install' }
    $info = Get-JkTaskInfo
    if ($info) {
        $d = "$($info.State)"
        if ($info.NextRunTime) { $d += " $($script:G.dot) next $($info.NextRunTime.ToString('ddd h:mm tt', $script:Inv))" }
        if ($info.LastRunTime) { $d += " $($script:G.dot) last result $($info.LastTaskResult)" }
        if ($info.PinnedToUtc) { & $meh 'daily reminder task' 'set in UTC, so it fires an hour early after DST ends - jk remind install' }
        elseif ($info.LastRunTime -and $info.LastTaskResult -ne 0 -and $info.State -ne 'Running') { & $meh 'daily reminder task' "$d (non-zero: see background.log)" }
        else { & $ok 'daily reminder task' $d }
    } else { & $meh 'daily reminder task' 'not installed - jk remind install' }
    $slow = @(Get-JkProfileFiles | Where-Object { ([IO.File]::ReadAllText($_.Path)) -match 'shell\.powershell" "hook"' })
    if ($slow) { & $meh 'shell startup' "conda init hook adds ~2 s to every new terminal - jk speed fix" }
    else { & $ok 'shell startup' 'no slow conda hook in your profiles' }
    $ts = Get-JkToastSetting
    $mode = Get-JkConfig 'notify'
    if ($ts -eq 'Enabled') { & $ok 'notifications' "Windows toasts enabled $($script:G.dot) mode $mode" }
    else { & $ok 'notifications' "Windows toasts are off ($ts), jk uses its own popup $($script:G.dot) mode $mode" }
    $ev = @((Get-JkDueData).events)
    if ($ev.Count) { & $ok 'deadlines' "$(Format-JkCount $ev.Count 'event') $($script:G.dot) $(Format-JkCount @((Get-JkDueData).courses).Count 'course')" } else { & $meh 'deadlines' 'none yet - jk due import <calendar.html> or jk due add' }
    # the LEARN feed: the morning task syncs daily, so a stale stamp means it has been failing
    if (Get-JkConfig 'sync.url') {
        $lastDt = $null
        try { $lastDt = [datetime]::Parse([string](Get-JkState 'lastSync'), $script:Inv) } catch { }
        if (-not $lastDt) { & $meh 'LEARN feed' 'connected, no sync recorded yet - jk due sync' }
        else {
            $ago = (Get-Date) - $lastDt
            if ($ago.TotalDays -gt 2) { & $meh 'LEARN feed' "last synced $([int]$ago.TotalDays) days ago - jk due sync (errors: background.log)" }
            else { & $ok 'LEARN feed' "synced $(Format-JkRelTime $lastDt)" }
        }
    } else { & $meh 'LEARN feed' 'not connected - LEARN > Calendar > Subscribe, then jk due sync "<link>"' }
    $mirror = Get-JkConfig 'backup.mirror'
    if ($mirror) {
        $latest = @(Get-ChildItem -LiteralPath $mirror -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1)
        if ($latest) { & $ok 'backup mirror' "$mirror $($script:G.dot) latest $($latest[0].Name)" } else { & $meh 'backup mirror' "$mirror has no snapshot yet - jk backup mirror $mirror" }
    } else { & $meh 'backup mirror' 'off (optional): backups live inside the data folder - jk backup mirror <folder elsewhere>' }
    try {
        $jf = Find-JkJobsFile
        if ($jf) {
            $n = @(Get-JkJobs $jf).Count
            $unread = @(Get-JkJobsUnread)
            if ($unread.Count) { & $meh 'job tracker' "$(Format-JkCount $n 'row') $($script:G.dot) $(Format-JkCount $unread.Count 'row') not read: $($unread[0])" }
            else { & $ok 'job tracker' "$(Format-JkCount $n 'row') $($script:G.dot) $jf" }
        }
        else { & $meh 'job tracker' 'none found (optional) - jk config set jobs.file <path>' }
    } catch { & $bad 'job tracker' $_.Exception.Message }
    # windowless timers and the morning task log failures here instead of showing them
    $log = Get-JkPath 'background.log'
    $recent = @(); $lines = @()
    if (Test-Path -LiteralPath $log) {
        $since = (Get-Date).AddDays(-7)
        $lines = @(Get-Content -LiteralPath $log)
        # each morning run's own summary line is a record, not an error
        $recent = @($lines | Where-Object { $_ -notmatch '^\S+ tick: ' -and $_ -match '^(\d{4}-\d{2}-\d{2}T[\d:]+)' -and [datetime]::Parse($Matches[1], $script:Inv) -ge $since })
    }
    # the last morning run: when, and whether it got a forecast
    $tick = @($lines | Where-Object { $_ -match '^(\S+) tick: ' })
    if ($tick.Count -and $tick[-1] -match '^(\S+) tick: .*weather (\w+)') {
        $when = Format-JkRelTime ([datetime]::Parse($Matches[1], $script:Inv)); $wx = $Matches[2]
        if ($wx -in 'fresh', 'skipped') { & $ok 'last morning run' "$when $($script:G.dot) forecast $wx" }
        else { & $meh 'last morning run' "$when $($script:G.dot) no fresh forecast ($wx): jk weather says why" }
    }
    if ($recent.Count) { & $meh 'background errors' "$($recent.Count) this week, latest: $(Fit ($recent[-1] -replace '^\S+\s+', '') 60)  ($log)" }
    else { & $ok 'background errors' 'none this week' }
    $exposed = @(Get-JkExposedServices (Get-JkListeners) (Get-JkProcessNames))
    foreach ($x in $exposed) { & $meh 'open to the network' "$($x.Name) ($($x.Ports -join ', ')) answers other devices too - see jk port" }
    if (-not $exposed.Count) { & $ok 'open to the network' 'no database listens beyond this PC' }
    # the kept forecast: the morning task, a terminal opening and the dashboard refresh it
    try {
        $wp = Get-JkWeatherPlace -NoLookup
        if (-not $wp) { & $ok 'weather' 'off (jk weather set <place> turns it on)' }
        else {
            $wx = Get-JkWeather -Place $wp -CacheOnly -MaxAgeHours 6
            $why = ''; $ef = Join-Path (Get-JkCacheDir) 'weather.error'
            if ([IO.File]::Exists($ef)) { $why = [IO.File]::ReadAllText($ef).Trim() }
            if ($wx -and -not $wx.Stale) { & $ok 'weather' "$($wp.Name) $($script:G.dot) forecast fetched $(Format-JkRelTime $wx.Fetched.ToLocalTime())" }
            elseif ($wx) { & $meh 'weather' "forecast fetched $(Format-JkRelTime $wx.Fetched.ToLocalTime())$(if ($why) { "; last try: $why" }) - jk weather" }
            else { & $meh 'weather' "no forecast kept yet$(if ($why) { "; last try: $why" }) - jk weather" }
        }
    } catch { & $meh 'weather' $_.Exception.Message }
    # free space, and whether it is going fast
    try {
        $drv = New-Object IO.DriveInfo ($env:SystemDrive)
        $txt = "$($env:SystemDrive) $(Format-JkSize $drv.AvailableFreeSpace) free of $(Format-JkSize $drv.TotalSize)"
        $drop = Get-JkDiskDrop $drv.AvailableFreeSpace (Get-JkNow)
        if ($drv.AvailableFreeSpace / $drv.TotalSize -lt 0.1) { & $bad 'disk space' "$txt - jk space" }
        elseif ($drop) { & $meh 'disk space' "$txt, $(Format-JkDiskDrop $drop) - jk space" }
        else { & $ok 'disk space' $txt }
    } catch { }
    # what jk grep reads PDFs with
    $ptt = Find-JkPdfToText
    if ($ptt) { & $ok 'PDF text (jk grep)' $ptt }
    elseif (Get-Command python -ErrorAction SilentlyContinue) { & $meh 'PDF text (jk grep)' 'no pdftotext: pypdf is used if installed (slower); MiKTeX or Git for Windows bring pdftotext' }
    else { & $meh 'PDF text (jk grep)' 'no pdftotext or Python: jk grep searches notes and slides but not PDFs' }
    foreach ($tool in @(@('g++', 'C++ for jk cp'), @('python', 'Python for jk cp'), @('javac', 'Java for jk cp'), @('git', 'git for jk repos'))) {
        $c = Get-Command $tool[0] -ErrorAction SilentlyContinue
        if ($c) {
            $ver = ''
            # read all of it: cutting the pipeline short kills the tool and leaves exit code -1
            try { $ver = "$(@(& $c.Source --version 2>&1)[0])" -replace '\s+', ' ' } catch { }
            & $ok $tool[0] ("$ver").Trim()
        } else { & $meh $tool[0] "not found ($($tool[1]))" }
    }
    $ed = Get-JkConfig 'editor'
    if (Get-Command $ed -ErrorAction SilentlyContinue) { & $ok 'editor' $ed } else { & $bad 'editor' "'$ed' not found - jk config set editor <cmd>" }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = Get-JkDueData; $null = Get-JkTodoData
    $sw.Stop()
    & $ok 'data read' "$($sw.ElapsedMilliseconds) ms"
}
