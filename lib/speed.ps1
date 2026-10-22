# speed.ps1 - why does a new PowerShell take so long?  jk speed / jk speed fix / jk speed undo
# The usual culprit is the `conda init` hook, which runs conda.exe (about 2 s) on every start.
# `jk speed fix` swaps it for an equivalent fast block: the base environment is activated
# from a cached recipe (same PATH entries and CONDA_* variables) and conda's own module loads
# the first time you type `conda`.

$script:CondaRegion = '(?ms)^#region conda initialize\r?\n.*?^#endregion[^\r\n]*'

function Get-JkProfileFiles {
    @('CurrentUserAllHosts', 'CurrentUserCurrentHost', 'AllUsersAllHosts', 'AllUsersCurrentHost') | ForEach-Object {
        $p = $PROFILE.$_
        if ($p -and (Test-Path -LiteralPath $p)) { [pscustomobject]@{ Kind = $_; Path = $p } }
    }
}

function Measure-JkShellStart([string[]]$ExtraArgs, [int]$Runs = 3) {
    $ps = Get-JkPowerShellExe
    $times = foreach ($i in 1..$Runs) {
        (Measure-Command { & $ps @ExtraArgs -Command 'exit' 2>$null | Out-Null }).TotalMilliseconds
    }
    ($times | Measure-Object -Minimum).Minimum
}

function Measure-JkScriptCost([string]$Path) {
    $ps = Get-JkPowerShellExe
    $cmd = "`$sw = [Diagnostics.Stopwatch]::StartNew(); . '$($Path.Replace("'", "''"))' *> `$null; `$sw.ElapsedMilliseconds"
    $out = & $ps -NoProfile -Command $cmd 2>$null | Select-Object -Last 1
    [int]$out
}

function Show-JkSpeed {
    Write-JkHeader 'Shell startup' 'best of 3 runs'
    $base = Measure-JkShellStart @('-NoProfile')
    $full = Measure-JkShellStart @()
    Say ('  ' + (Paint 'white' (Fit 'PowerShell with no profile' 34)) + (Paint 'muted' (Fit ('{0:N0} ms' -f $base) 9 -Right)))
    $style = 'green'; if ($full - $base -gt 1000) { $style = 'red' } elseif ($full - $base -gt 400) { $style = 'orange' }
    Say ('  ' + (Paint 'white' (Fit 'with your profiles' 34)) + (Paint $style (Fit ('{0:N0} ms' -f $full) 9 -Right)) + (Paint 'gray' ('   +{0:N0} ms' -f ($full - $base))))
    Say ''
    $condaFound = $false
    foreach ($f in Get-JkProfileFiles) {
        $cost = Measure-JkScriptCost $f.Path
        $st = 'muted'; if ($cost -gt 1000) { $st = 'red' } elseif ($cost -gt 300) { $st = 'orange' }
        Say ('  ' + (Paint 'white' (Fit $f.Kind 24)) + (Paint $st (Fit ('{0:N0} ms' -f $cost) 9 -Right)) + '  ' + (Paint 'gray' $f.Path))
        $text = [IO.File]::ReadAllText($f.Path)
        if ([regex]::IsMatch($text, $script:CondaRegion) -and $text -match 'shell\.powershell" "hook"') {
            $condaFound = $true
            Say ('    ' + (Paint 'orange' "$($script:G.bullet) conda init hook: runs conda.exe on every start"))
        } elseif ($text -match 'jk speed: fast conda') {
            Say ('    ' + (Paint 'green' "$($script:G.check) fast conda block (jk speed fix) is in place"))
        }
    }
    Say ''
    if ($condaFound) { Say ('  ' + (Paint 'bold green' 'jk speed fix') + ' makes conda activation instant (same python, same base env; undo: jk speed undo)') }
    else { Say (Paint 'gray' '  nothing obvious to fix') }
}

# Builds the fast block from what `conda activate base` would do right now.
function New-JkFastCondaBlock([string]$CondaExe) {
    $root = Split-Path (Split-Path $CondaExe -Parent) -Parent
    # join the raw lines ourselves: Out-String would wrap the long PATH line at the console width
    $act = @(& $CondaExe 'shell.powershell' 'activate' 'base') -join "`n"
    $pathLine = [regex]::Match($act, '(?m)^\$Env:PATH = "([^"\r\n]*)"').Groups[1].Value
    if (-not $pathLine) { throw 'could not read the activation PATH from conda' }
    $prefix = @()
    foreach ($e in ($pathLine -split ';')) {
        if ($e -match '[\r\n]') { throw 'unexpected line break in the activation PATH' }
        if ($e.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $prefix += $e } else { break }
    }
    if ($prefix.Count -eq 0) { throw 'conda activation did not add any PATH entries' }
    $vars = @()
    foreach ($m in [regex]::Matches($act, '(?m)^\$Env:(\w+) = "([^"]*)"\s*$')) {
        if ($m.Groups[1].Value -ne 'PATH') { $vars += '    $Env:' + $m.Groups[1].Value + ' = "' + $m.Groups[2].Value + '"' }
    }
    $sources = @([regex]::Matches($act, '(?m)^\. "([^"]+)"\s*$') | ForEach-Object { '    if (Test-Path "' + $_.Groups[1].Value + '") { . "' + $_.Groups[1].Value + '" }' })
    $psm1 = Join-Path $root 'shell\condabin\Conda.psm1'
    $lines = @(
        '#region conda initialize',
        "# !! Contents within this block are managed by 'conda init' !!",
        '# jk speed: fast conda. Activates base from a cached recipe instead of running conda.exe on every start;',
        "# conda's module loads the first time you run conda. Original block: profile.ps1.jk-backup (jk speed undo).",
        "If (Test-Path `"$CondaExe`") {",
        ('    $Env:PATH = "' + ($prefix -join ';') + ';" + $Env:PATH')
    ) + $vars + $sources + @(
        '    function global:prompt {',
        '        if (-not (Get-Module Conda) -and $Env:CONDA_PROMPT_MODIFIER) { Write-Host -NoNewline $Env:CONDA_PROMPT_MODIFIER }',
        '        "PS $($ExecutionContext.SessionState.Path.CurrentLocation)$(''>'' * ($NestedPromptLevel + 1)) "',
        '    }',
        '    function global:conda {',
        '        Remove-Item Function:\conda -ErrorAction SilentlyContinue',
        "        Import-Module `"$psm1`" -ArgumentList @{ ChangePs1 = `$True } -Global",
        '        Invoke-Conda @args',
        '    }',
        '}',
        '#endregion'
    )
    $lines -join "`r`n"
}

# python / env / PATH-prefix as a brand-new shell sees them. -Script, when given, is
# dot-sourced in a -NoProfile shell instead of loading the real profiles.
function Get-JkShellFingerprint([string]$Script) {
    $ps = Get-JkPowerShellExe
    # full PATH, trailing backslashes ignored (conda normalizes "C:\x\" to "C:\x")
    $probe = '"JKFP:{0}|{1}|{2}|{3}" -f (Get-Command python -ErrorAction SilentlyContinue).Source, $env:CONDA_DEFAULT_ENV, $env:CONDA_PREFIX, (($env:PATH -split '';'' | ForEach-Object { $_.TrimEnd(''\'') }) -join '';'')'
    $argList = @()
    if ($Script) { $probe = ". '" + $Script.Replace("'", "''") + "' *> `$null; " + $probe; $argList += '-NoProfile' }
    # -EncodedCommand: Windows PowerShell mangles double quotes passed to native programs
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
    $out = & $ps @argList -EncodedCommand $enc 2>$null | Where-Object { "$_" -like 'JKFP:*' } | Select-Object -First 1
    if (-not $out) { throw 'could not read the state of a new shell' }
    ([string]$out).Substring(5)
}

function Invoke-JkSpeedFix {
    $f = @(Get-JkProfileFiles | Where-Object { [regex]::IsMatch([IO.File]::ReadAllText($_.Path), $script:CondaRegion) -and ([IO.File]::ReadAllText($_.Path)) -match 'shell\.powershell" "hook"' })
    if (-not $f) { Say (Paint 'gray' '  no conda init hook found - nothing to do'); return }
    $path = $f[0].Path
    $text = [IO.File]::ReadAllText($path)
    $exe = [regex]::Match($text, '"([^"]+conda\.exe)"').Groups[1].Value
    if (-not (Test-Path -LiteralPath $exe)) { throw "conda.exe not found at $exe" }
    Say (Paint 'gray' "  reading what 'conda activate base' does$($script:G.ell)")
    $before = Get-JkShellFingerprint
    $block = New-JkFastCondaBlock $exe
    $new = [regex]::Replace($text, $script:CondaRegion, { param($m) $block })
    # dry run in throwaway shells before the real profile is touched
    $tmpOld = Join-Path $env:TEMP 'jk-speed-old.ps1'
    $tmpNew = Join-Path $env:TEMP 'jk-speed-new.ps1'
    [IO.File]::WriteAllText($tmpOld, $text, (New-Object Text.UTF8Encoding $true))
    [IO.File]::WriteAllText($tmpNew, $new, (New-Object Text.UTF8Encoding $true))
    try {
        $dryOld = Get-JkShellFingerprint $tmpOld
        $dryNew = Get-JkShellFingerprint $tmpNew
    } finally { Remove-Item -LiteralPath $tmpOld, $tmpNew -ErrorAction SilentlyContinue }
    if ($dryOld -ne $dryNew) { throw "the fast block would change new shells (old: $dryOld / new: $dryNew); profile left untouched" }
    Copy-Item -LiteralPath $path -Destination "$path.jk-backup" -Force
    [IO.File]::WriteAllText($path, $new, (New-Object Text.UTF8Encoding $true))
    $after = Get-JkShellFingerprint
    if ($after -ne $before) {
        Copy-Item -LiteralPath "$path.jk-backup" -Destination $path -Force
        throw "new shells would differ (before: $before / after: $after) - restored the original profile"
    }
    $parts = $after.Split('|')
    Say ((Paint 'green' "  $($script:G.check) fast conda block installed") + (Paint 'gray' " $($script:G.dot) $path (backup: .jk-backup)"))
    Say (Paint 'gray' "  verified: python = $($parts[0]), env = $($parts[1])")
    $base = Measure-JkShellStart @('-NoProfile')
    $full = Measure-JkShellStart @()
    Say ('  startup now ' + (Paint 'bold green' ('{0:N0} ms' -f $full)) + (Paint 'gray' (' (no-profile baseline {0:N0} ms)' -f $base)))
}

function Undo-JkSpeedFix {
    $done = $false
    foreach ($f in Get-JkProfileFiles) {
        $bak = "$($f.Path).jk-backup"
        if ((Test-Path -LiteralPath $bak) -and ([IO.File]::ReadAllText($f.Path)) -match 'jk speed: fast conda') {
            Copy-Item -LiteralPath $bak -Destination $f.Path -Force
            Say (Paint 'yellow' "  restored the original conda block in $($f.Path)")
            $done = $true
        }
    }
    if (-not $done) { Say (Paint 'gray' '  nothing to undo') }
}

function Invoke-JkSpeed {
    $a = @($args | ForEach-Object { [string]$_ })
    $action = ''
    if ($a.Count) { $action = $a[0].ToLower() }
    switch -Regex ($action) {
        '^$' { Show-JkSpeed; return }
        '^(fix|apply)$' { Invoke-JkSpeedFix; return }
        '^(undo|revert)$' { Undo-JkSpeedFix; return }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'speed'; return }
    }
    throw "unknown 'speed' action '$action' (jk speed | jk speed fix | jk speed undo)"
}
