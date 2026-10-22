# setup.ps1 - config, doctor, and install/uninstall of the profile hook + scheduled task.

$script:ProfileStart = '# >>> jk >>>'
$script:ProfileEnd = '# <<< jk <<<'

function Invoke-JkConfig {
    $a = @($args | ForEach-Object { [string]$_ })
    if ($a.Count -eq 0) {
        $all = Get-JkConfig
        $cfg = Read-JkJson 'config.json' $null
        Write-JkHeader 'Config' (Get-JkPath 'config.json')
        foreach ($k in $all.Keys) {
            $isSet = $cfg -and $cfg.PSObject.Properties[$k]
            $st = 'muted'; if ($isSet) { $st = 'white' }
            Say ('  ' + (Paint 'cyan' (Fit $k 16)) + (Paint $st $all[$k]) + $(if (-not $isSet) { Paint 'gray' '  (default)' } else { '' }))
        }
        Say ''
        Say (Paint 'gray' '  jk config set <key> <value>   |   jk config reset <key>   |   jk help config')
        return
    }
    switch -Regex ($a[0].ToLower()) {
        '^set$' {
            if ($a.Count -lt 3) { throw 'usage: jk config set <key> <value>' }
            $key = $a[1]; $val = ($a[2..($a.Count - 1)]) -join ' '
            if (-not $script:JkConfigDefaults.Contains($key)) { Say (Paint 'yellow' "  note: '$key' is not a known setting (known: $($script:JkConfigDefaults.Keys -join ', '))") }
            if ($key -eq 'remind.time') { $val = ConvertTo-JkTime $val }
            if ($key -eq 'notify' -and $val -notmatch '^(auto|popup|toast|off)$') { throw 'notify must be auto, popup, toast or off' }
            Set-JkConfig $key $val
            Clear-JkBriefCache
            Say ((Paint 'green' "  $key = $val") + " $($script:G.check)")
            if ($key -eq 'remind.time' -and (Get-ScheduledTask -TaskName $script:JkTaskName -ErrorAction SilentlyContinue)) { $null = Install-JkRemindTask }
            return
        }
        '^(reset|unset)$' {
            $cfg = Read-JkJson 'config.json' $null
            if ($cfg -and $cfg.PSObject.Properties[$a[1]]) { $cfg.PSObject.Properties.Remove($a[1]); Save-JkJson 'config.json' $cfg }
            $script:JkConfigCache = $null
            Say (Paint 'green' "  $($a[1]) reset to default ($(Get-JkConfig $a[1]))")
            return
        }
        '^edit$' { $p = Get-JkPath 'config.json'; if (-not (Test-Path $p)) { Save-JkJson 'config.json' ([pscustomobject]@{}) }; Open-JkInEditor $p; return }
        '^path$' { Say (Get-JkHome); return }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'config'; return }
    }
    # jk config <key>  -> print value
    Say (Get-JkConfig $a[0])
}

# jk backup                 list the daily snapshots
# jk backup restore <day>   put that day's files back (current ones are set aside first)
function Invoke-JkBackup {
    $a = @($args | ForEach-Object { [string]$_ })
    $root = Join-Path (Get-JkHome) 'backups'
    $days = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending)
    if ($a.Count -eq 0 -or $a[0] -match '^(list|ls)$') {
        Write-JkHeader 'Backups' "$($days.Count) day$(if ($days.Count -ne 1) {'s'}) kept (30 max)" -Sub $root
        if (-not $days) { Say (Paint 'gray' '  none yet - a snapshot is taken before the first change of each day') }
        foreach ($d in $days) {
            $files = @(Get-ChildItem -LiteralPath $d.FullName -File | Where-Object { $_.Name -like '*.json' } | ForEach-Object { $_.BaseName })
            Say ('  ' + (Paint 'white' (Fit $d.Name 12)) + (Paint 'muted' ($files -join ', ')))
        }
        if ($days) { Say ''; Say (Paint 'gray' "  jk backup restore $($days[0].Name)   (or one file: jk backup restore $($days[0].Name) deadlines)") }
        return
    }
    if ($a[0] -notmatch '^(restore|undo)$') { throw 'usage: jk backup  |  jk backup restore <yyyy-mm-dd> [deadlines|grades|todo|classes|...]' }
    if ($a.Count -lt 2) { throw 'which day? see: jk backup' }
    $dir = Join-Path $root $a[1]
    if (-not (Test-Path -LiteralPath $dir)) { throw "no backup for '$($a[1])' (see: jk backup)" }
    $pick = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.json')
    if ($a.Count -ge 3) {
        $want = $a[2].ToLower() -replace '\.json$', ''
        $pick = @($pick | Where-Object { $_.BaseName -eq $want })
        if (-not $pick) { throw "that day has no $want.json" }
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

function Get-JkModuleLink { Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules\jk' }

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

function Get-JkProfilePath { $PROFILE.CurrentUserCurrentHost }

function Test-JkProfileHook {
    $p = Get-JkProfilePath
    (Test-Path -LiteralPath $p) -and ([IO.File]::ReadAllText($p)).Contains($script:ProfileStart)
}

function Install-JkProfileHook {
    $p = Get-JkProfilePath
    $dir = Split-Path $p -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $text = ''
    if (Test-Path -LiteralPath $p) {
        $text = [IO.File]::ReadAllText($p)
        Copy-Item -LiteralPath $p -Destination "$p.jk-backup" -Force
    }
    $text = Remove-JkProfileBlock $text
    $text = $text.TrimEnd() + "`r`n`r`n" + (Get-JkProfileBlock) + "`r`n"
    # keep the profile's encoding PowerShell-5.1-friendly (UTF-8 with BOM handles any non-ASCII already there)
    [IO.File]::WriteAllText($p, $text.TrimStart(), (New-Object Text.UTF8Encoding $true))
    Say ((Paint 'green' "  $($script:G.check) profile hook added") + (Paint 'gray' " $($script:G.dot) $p (backup: .jk-backup)"))
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
    $task = Get-ScheduledTask -TaskName $script:JkTaskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
        $d = "$($task.State)"
        if ($info.NextRunTime) { $d += " $($script:G.dot) next $($info.NextRunTime.ToString('ddd h:mm tt'))" }
        if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $d += " $($script:G.dot) last result $($info.LastTaskResult)" }
        & $ok 'daily reminder task' $d
    } else { & $meh 'daily reminder task' 'not installed - jk remind install' }
    $slow = @(Get-JkProfileFiles | Where-Object { ([IO.File]::ReadAllText($_.Path)) -match 'shell\.powershell" "hook"' })
    if ($slow) { & $meh 'shell startup' "conda init hook adds ~2 s to every new terminal - jk speed fix" }
    else { & $ok 'shell startup' 'no slow conda hook in your profiles' }
    $ts = Get-JkToastSetting
    $mode = Get-JkConfig 'notify'
    if ($ts -eq 'Enabled') { & $ok 'notifications' "Windows toasts enabled $($script:G.dot) mode $mode" }
    else { & $ok 'notifications' "Windows toasts are off ($ts), jk uses its own popup $($script:G.dot) mode $mode" }
    $ev = @((Get-JkDueData).events)
    if ($ev.Count) { & $ok 'deadlines' "$($ev.Count) events $($script:G.dot) $(@((Get-JkDueData).courses).Count) courses" } else { & $meh 'deadlines' 'none yet - jk due import <calendar.html> or jk due add' }
    foreach ($tool in @(@('g++', 'C++ for jk cp'), @('python', 'Python for jk cp'), @('javac', 'Java for jk cp'), @('git', 'git for jk repos'))) {
        $c = Get-Command $tool[0] -ErrorAction SilentlyContinue
        if ($c) {
            $ver = ''
            try { $ver = (& $c.Source --version 2>&1 | Select-Object -First 1) -replace '\s+', ' ' } catch { }
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
