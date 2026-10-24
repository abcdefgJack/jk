# space.ps1 - where did the disk go?  jk space  |  jk space clean <temp|conda|pip|npm>
# Measures the usual developer-machine space hogs (caches, temp, Docker's disk, old node_modules)
# without touching anything; cleanups only run when you ask for one by name.

# Folder size via robocopy's list-only mode: fast, and it shrugs off access-denied folders.
function Get-JkFolderSize([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { return [pscustomobject]@{ Bytes = [double]$item.Length; Files = 1 } }
    $null_target = Join-Path $env:TEMP 'jk-null-target-never-created'
    $out = & robocopy.exe $Path $null_target /L /S /NJH /NFL /NDL /BYTES /XJ /R:0 /W:0 /NC /NS /NP 2>$null
    $global:LASTEXITCODE = 0   # robocopy exits 1 for "would copy files"; that is not a failure here
    $bytes = 0.0; $files = 0
    foreach ($l in $out) {
        if ($l -match '^\s*Bytes\s*:\s*(\d+)') { $bytes = [double]$Matches[1] }
        if ($l -match '^\s*Files\s*:\s*(\d+)') { $files = [int]$Matches[1] }
    }
    [pscustomobject]@{ Bytes = $bytes; Files = $files }
}

function Get-JkSpaceTargets {
    $la = $env:LOCALAPPDATA; $ra = $env:APPDATA
    $condaRoot = $null
    foreach ($c in @($env:CONDA_PREFIX, $env:_CONDA_ROOT, 'C:\Miniconda3', 'C:\ProgramData\Miniconda3', "$HOME\miniconda3", "$HOME\anaconda3")) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'pkgs'))) { $condaRoot = $c; break }
    }
    $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    $list = @(
        @{ Key = 'downloads'; Name = 'Downloads folder'; Path = (Get-JkDownloadsPath); Fix = 'jk tidy old  (old installers/archives)  /  jk tidy dupes' }
        @{ Key = 'recycle'; Name = 'Recycle Bin (C:)'; Path = "C:\`$Recycle.Bin\$sid"; Fix = 'empty it: right-click the Recycle Bin > Empty' }
        @{ Key = 'temp'; Name = 'Your temp folder'; Path = $env:TEMP; Fix = 'jk space clean temp  (files older than 7 days)'; Clean = 'temp' }
        @{ Key = 'conda'; Name = 'conda package cache'; Path = $(if ($condaRoot) { Join-Path $condaRoot 'pkgs' }); Fix = 'jk space clean conda  (conda clean --all)'; Clean = 'conda' }
        @{ Key = 'pip'; Name = 'pip cache'; Path = (Join-Path $la 'pip\cache'); Fix = 'jk space clean pip  (pip cache purge)'; Clean = 'pip' }
        @{ Key = 'npm'; Name = 'npm cache'; Path = (Join-Path $la 'npm-cache'); Fix = 'jk space clean npm  (npm cache clean --force)'; Clean = 'npm' }
        @{ Key = 'gradle'; Name = 'Gradle caches'; Path = (Join-Path $HOME '.gradle\caches'); Fix = 'safe to delete; rebuilt on the next build' }
        @{ Key = 'maven'; Name = 'Maven repository'; Path = (Join-Path $HOME '.m2\repository'); Fix = 'safe to delete; re-downloaded on the next build' }
        @{ Key = 'docker'; Name = 'Docker Desktop disk'; Path = (Join-Path $la 'Docker\wsl'); Fix = 'docker system prune -a, then Docker Desktop > Troubleshoot > Clean / Purge data' }
        @{ Key = 'chrome'; Name = 'Chrome cache'; Path = (Join-Path $la 'Google\Chrome\User Data\Default\Cache'); Fix = 'Chrome > Settings > Privacy > Delete browsing data > Cached images and files' }
        @{ Key = 'vscode'; Name = 'VS Code caches'; Path = (Join-Path $ra 'Code\CachedData'); Fix = 'old CachedData versions can go (VS Code keeps the current one)' }
        @{ Key = 'cursor'; Name = 'Cursor caches'; Path = (Join-Path $ra 'Cursor\CachedData'); Fix = 'old CachedData versions can go' }
        @{ Key = 'jetbrains'; Name = 'JetBrains caches/logs'; Path = (Join-Path $la 'JetBrains'); Fix = 'jk space clean jetbrains  (caches of IDE versions no longer installed)' }
        @{ Key = 'crashdumps'; Name = 'Crash dumps'; Path = (Join-Path $la 'CrashDumps'); Fix = 'safe to delete' }
    )
    foreach ($t in $list) { if ($t.Path) { [pscustomobject]$t } }
}

function Find-JkNodeModules([string[]]$Roots, [int]$Depth = 4) {
    $found = New-Object System.Collections.Generic.List[string]
    $walk = $null
    $walk = {
        param($dir, $level)
        foreach ($sub in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($sub.Name -eq 'node_modules') { $found.Add($sub.FullName); continue }
            if ($sub.Name.StartsWith('.') -or $sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($level -lt $Depth) { & $walk $sub.FullName ($level + 1) }
        }
    }
    foreach ($r in $Roots) { if (Test-Path -LiteralPath $r) { & $walk $r 0 } }
    $found
}

function Show-JkSpace {
    param([switch]$NoNodeModules)
    $drive = New-Object IO.DriveInfo ($env:SystemDrive)
    $usedFrac = 1 - $drive.AvailableFreeSpace / $drive.TotalSize
    Write-JkHeader 'Disk space' "$($env:SystemDrive) $(Format-JkSize $drive.AvailableFreeSpace) free of $(Format-JkSize $drive.TotalSize)"
    $st = 'blue'; if ($usedFrac -ge 0.9) { $st = 'red' } elseif ($usedFrac -ge 0.8) { $st = 'orange' }
    Say ('  ' + (Get-JkBar $usedFrac 50 $st) + '  ' + (Paint 'white' ('{0:N0}% used' -f ($usedFrac * 100))))
    Say ''
    $rows = @()
    $targets = @(Get-JkSpaceTargets)
    $i = 0
    # a progress line that rewrites itself, only where a terminal can show it that way (captured
    # output would collect every step on one line)
    $live = Test-JkInteractive
    $clear = "`r" + (' ' * ((Get-JkWidth) - 1)) + "`r"
    foreach ($t in $targets) {
        $i++
        if ($live) { Write-Host ($clear + '  ' + (Paint 'gray' ("measuring {0}/{1}  {2}" -f $i, $targets.Count, $t.Name))) -NoNewline }
        $s = Get-JkFolderSize $t.Path
        if ($s -and $s.Bytes -gt 0) { $rows += [pscustomobject]@{ Name = $t.Name; Bytes = $s.Bytes; Files = $s.Files; Fix = $t.Fix; Path = $t.Path } }
    }
    if (-not $NoNodeModules) {
        if ($live) { Write-Host ($clear + '  ' + (Paint 'gray' "looking for node_modules under the Desktop$($script:G.ell)")) -NoNewline }
        $nm = @(Find-JkNodeModules @([Environment]::GetFolderPath('Desktop')))
        $nmBytes = 0.0
        $nmList = @()
        foreach ($p in $nm) { $s = Get-JkFolderSize $p; if ($s) { $nmBytes += $s.Bytes; $nmList += [pscustomobject]@{ Path = $p; Bytes = $s.Bytes; Age = [int]((Get-Date) - (Get-Item -LiteralPath $p).LastWriteTime).TotalDays } } }
        if ($nmBytes -gt 0) { $rows += [pscustomobject]@{ Name = "node_modules ($($nm.Count) projects)"; Bytes = $nmBytes; Files = 0; Fix = 'delete node_modules of projects you are not working on (npm install brings it back)'; Path = '' } }
    }
    if ($live) { Write-Host $clear -NoNewline }
    $rows = @($rows | Sort-Object Bytes -Descending)
    $total = ($rows | Measure-Object Bytes -Sum).Sum
    $max = ($rows | Measure-Object Bytes -Maximum).Maximum
    if (-not $max) { $max = 1 }
    $w = Get-JkWidth
    foreach ($r in $rows) {
        $sz = 'muted'; if ($r.Bytes -ge 5GB) { $sz = 'bold red' } elseif ($r.Bytes -ge 1GB) { $sz = 'orange' } elseif ($r.Bytes -ge 200MB) { $sz = 'yellow' }
        Say ('  ' + (Paint 'white' (Fit $r.Name 28)) + (Paint $sz (Fit (Format-JkSize $r.Bytes) 10 -Right)) + '  ' + (Get-JkBar ($r.Bytes / $max) 18 'teal'))
        Say ('      ' + (Paint 'gray' (Fit $r.Fix ($w - 8)).TrimEnd()))
    }
    if ($nmList.Count) {
        Say ''
        Say (' ' + (Paint 'bold white' 'Biggest node_modules') + (Paint 'gray' '  (age = days since last change)'))
        foreach ($n in ($nmList | Sort-Object Bytes -Descending | Select-Object -First 6)) {
            Say ('  ' + (Paint 'white' (Fit (Format-JkSize $n.Bytes) 10 -Right)) + (Paint 'gray' (Fit "$($n.Age)d" 7 -Right)) + '  ' + (Paint 'muted' (Fit $n.Path ($w - 22)).TrimEnd()))
        }
    }
    Say ''
    Say ('  ' + (Paint 'bold white' ('{0} in these places' -f (Format-JkSize $total))) + (Paint 'gray' '  -  nothing was changed; cleanups run only when you name one'))
}

# JetBrains IDEs keep a cache folder per version (%LOCALAPPDATA%\JetBrains\CLion2023.1) and an
# upgrade leaves the old one behind. "CLion 2024.2.1" as Windows lists it -> CLion2024.2.
$script:JkJetBrainsNames = [ordered]@{
    'IntelliJ IDEA Community Edition' = 'IdeaIC'; 'IntelliJ IDEA' = 'IntelliJIdea'; 'PyCharm Community Edition' = 'PyCharmCE'; 'PyCharm' = 'PyCharm'
    'CLion' = 'CLion'; 'WebStorm' = 'WebStorm'; 'Rider' = 'Rider'; 'DataGrip' = 'DataGrip'; 'GoLand' = 'GoLand'; 'PhpStorm' = 'PhpStorm'; 'RustRover' = 'RustRover'
}

function ConvertTo-JkJetBrainsKey([string]$DisplayName) {
    if ($DisplayName -notmatch '^(?<p>.+?)\s+(?<y>\d{4})\.(?<m>\d+)') { return $null }
    $p = $Matches['p'].Trim(); $ver = "$($Matches['y']).$($Matches['m'])"
    if ($script:JkJetBrainsNames.Contains($p)) { return $script:JkJetBrainsNames[$p] + $ver }
    $null
}

function Get-JkInstalledJetBrains {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | ForEach-Object { ConvertTo-JkJetBrainsKey ([string]$_.DisplayName) } | Where-Object { $_ })
}

# Cache folders no installed IDE uses. The newest of each product always stays, in case that IDE
# came from somewhere Windows does not list (JetBrains Toolbox).
function Get-JkStaleJetBrainsCaches([string]$Root = (Join-Path $env:LOCALAPPDATA 'JetBrains'), [string[]]$Installed = @(Get-JkInstalledJetBrains)) {
    $dirs = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Za-z]+\d{4}\.\d+$' } | ForEach-Object {
            $null = $_.Name -match '^([A-Za-z]+)(\d{4})\.(\d+)$'
            [pscustomobject]@{ Dir = $_; Product = $Matches[1]; Version = [version]"$($Matches[2]).$($Matches[3])" }
        })
    $newest = @{}
    foreach ($d in $dirs) { if (-not $newest.ContainsKey($d.Product) -or $d.Version -gt $newest[$d.Product]) { $newest[$d.Product] = $d.Version } }
    @($dirs | Where-Object { $Installed -notcontains $_.Dir.Name -and $_.Version -ne $newest[$_.Product] } | ForEach-Object { $_.Dir })
}

function Invoke-JkSpaceClean {
    param([Parameter(Position = 0)][string]$What, [int]$Days = 7)
    switch -Regex ($What) {
        '^temp$' {
            $cut = (Get-Date).AddDays(-$Days)
            $files = @(Get-ChildItem -LiteralPath $env:TEMP -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut -and $_.LastAccessTime -lt $cut })
            $freed = 0.0; $n = 0; $skipped = 0
            foreach ($f in $files) {
                try { $len = $f.Length; Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $freed += $len; $n++ } catch { $skipped++ }
            }
            # then empty folders past the same cut-off, deepest first (a fresh empty folder may be
            # one a running installer or build is about to fill)
            Get-ChildItem -LiteralPath $env:TEMP -Recurse -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut -and $_.CreationTime -lt $cut } | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
                if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
            }
            Say ((Paint 'green' "  freed $(Format-JkSize $freed) $($script:G.check)") + (Paint 'gray' "  $n temp files older than $Days days removed$(if ($skipped) { ", $skipped in use were skipped" })"))
        }
        '^conda$' {
            $conda = $env:CONDA_EXE
            if (-not $conda) { $c = Get-Command conda.exe -ErrorAction SilentlyContinue; if ($c) { $conda = $c.Source } }
            if (-not $conda -or -not (Test-Path $conda)) { foreach ($p in 'C:\Miniconda3\Scripts\conda.exe', "$HOME\miniconda3\Scripts\conda.exe", "$HOME\anaconda3\Scripts\conda.exe") { if (Test-Path $p) { $conda = $p; break } } }
            if (-not $conda) { throw 'conda.exe not found' }
            & $conda clean --all --yes
        }
        '^pip$' {
            $py = Get-Command python -ErrorAction SilentlyContinue
            if (-not $py) { throw 'python not found' }
            & $py.Source -m pip cache purge
        }
        '^npm$' {
            if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { throw 'npm not found' }
            & npm cache clean --force
        }
        '^(jetbrains|jb)$' {
            $stale = @(Get-JkStaleJetBrainsCaches)
            if (-not $stale.Count) { Say (Paint 'green' "  no caches of old JetBrains IDE versions $($script:G.check)"); return }
            $freed = 0.0
            foreach ($d in $stale) {
                $size = 0.0; $s = Get-JkFolderSize $d.FullName; if ($s) { $size = $s.Bytes }
                try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop; $freed += $size; Say ('  ' + (Paint 'gray' 'removed ') + (Paint 'white' $d.Name) + (Paint 'gray' "  $(Format-JkSize $size)")) }
                catch { Say (Paint 'orange' "  could not remove $($d.Name) (an IDE using it may be open)") }
            }
            Say ((Paint 'green' "  freed $(Format-JkSize $freed) $($script:G.check)") + (Paint 'gray' '  caches of IDE versions no longer installed; your settings (AppData\Roaming) stay'))
        }
        default { throw 'usage: jk space clean temp|conda|pip|npm|jetbrains   (other items list the right tool to use)' }
    }
}

function Invoke-JkSpace {
    $a = @($args)
    if ($a.Count -eq 0) { Show-JkSpace; return }
    $first = ([string]$a[0]).ToLower()
    $rest = @()
    if ($a.Count -gt 1) { $rest = @($a[1..($a.Count - 1)]) }
    switch -Regex ($first) {
        '^(clean|free)$' { Invoke-JkSpaceClean @rest; return }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'space'; return }
    }
    Show-JkSpace @a
}
