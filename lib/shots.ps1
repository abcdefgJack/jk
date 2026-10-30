# shots.ps1 - the Screenshots folder (Win+PrtScn, Snipping Tool): years of files in one folder.
#   jk shots                count and size per month, the newest numbered for jk find -o
#   jk shots file           move screenshots from before this month into YYYY-MM folders (jk tidy undo)
#   jk shots old            screenshots older than a year; -Months 6 to choose, -Recycle to bin them

$script:JkShotExt = @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic', '.mp4')

function Get-JkShotsPath {
    $cfg = Get-JkConfig 'shots.path'
    if ($cfg) { return [Environment]::ExpandEnvironmentVariables($cfg) }
    Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Screenshots'
}

# Every screenshot under the folder (month folders included), shaped like jk find's rows. The top
# level and each subfolder are listed on their own: a folder given as C:\Users\JACKWA~1\... lists
# its children under the long name, so cutting one path by the other's length goes wrong.
function Get-JkShots([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $root = Get-Item -LiteralPath $Path
    $row = { param($f, $folder, $loose) [pscustomobject]@{ Name = $f.Name; Folder = $folder; Size = $f.Length; Modified = $f.LastWriteTime; Path = $f.FullName; Loose = $loose; Item = $f } }
    $isShot = { param($f) $script:JkShotExt -contains $f.Extension.ToLower() }
    foreach ($f in @(Get-ChildItem -LiteralPath $root.FullName -File -Force -ErrorAction SilentlyContinue)) { if (& $isShot $f) { & $row $f $root.Name $true } }
    foreach ($d in @(Get-ChildItem -LiteralPath $root.FullName -Directory -Recurse -Force -ErrorAction SilentlyContinue)) {
        $rel = $d.FullName.Substring($root.FullName.TrimEnd('\').Length).TrimStart('\')
        foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -File -Force -ErrorAction SilentlyContinue)) { if (& $isShot $f) { & $row $f $rel $false } }
    }
}

function Show-JkShots {
    param([string]$Path = (Get-JkShotsPath), [int]$Newest = 8)
    $shots = @(Get-JkShots $Path)
    $total = ($shots | Measure-Object Size -Sum).Sum
    Write-JkHeader 'Screenshots' "$(Format-JkCount $shots.Count 'file') $($script:G.dot) $(Format-JkSize ([double]$total))" -Sub (Get-JkShortPath $Path)
    if (-not $shots.Count) { Say (Paint 'gray' "  none in $Path (jk config set shots.path <folder>)"); return }
    # the last twelve months, newest first
    $now = Get-Date
    $byMonth = @{}
    foreach ($s in $shots) { $k = $s.Modified.ToString('yyyy-MM', $script:Inv); $byMonth[$k] = [int]$byMonth[$k] + 1 }
    $months = @(for ($i = 0; $i -lt 12; $i++) { $now.AddMonths(-$i).ToString('yyyy-MM', $script:Inv) })
    $max = [Math]::Max(1, ($months | ForEach-Object { [int]$byMonth[$_] } | Measure-Object -Maximum).Maximum)
    foreach ($m in $months) {
        $n = [int]$byMonth[$m]
        Say ('  ' + (Paint 'muted' $m) + '  ' + (Get-JkBar ($n / $max) 30 'teal') + '  ' + (Paint 'white' "$n"))
    }
    $older = @($shots | Where-Object { $_.Modified -lt $now.AddMonths(-11).Date.AddDays(1 - $now.AddMonths(-11).Day) }).Count
    if ($older) { Say (Paint 'gray' "  + $older from before that") }
    Say ''
    Say (' ' + (Paint 'bold white' 'Newest'))
    $show = @($shots | Sort-Object Modified -Descending | Select-Object -First $Newest)
    Save-JkFindLast $show
    Write-JkFindRows $show -Ago
    $loose = @(Get-JkShotsToFile $shots $now).Count
    $old = @($shots | Where-Object { $_.Modified -lt $now.AddMonths(-12) })
    $tips = @("jk find -o 1 opens the newest")
    if ($loose) { $tips += "jk shots file sorts $loose older ones into month folders (jk tidy undo puts them back)" }
    if ($old.Count) { $tips += "jk shots old: $($old.Count) older than a year ($(Format-JkSize ([double](($old | Measure-Object Size -Sum).Sum))))" }
    foreach ($t in $tips) { Say (Paint 'gray' "  $t") }
}

# Loose screenshots from before this month: the ones jk shots file moves.
function Get-JkShotsToFile($Shots, [datetime]$Now) {
    $thisMonth = $Now.ToString('yyyy-MM', $script:Inv)
    @($Shots | Where-Object { $_.Loose -and $_.Modified.ToString('yyyy-MM', $script:Inv) -lt $thisMonth })
}

# Moves loose screenshots from before this month into YYYY-MM folders beside them. Logged the way
# jk tidy logs a batch, so jk tidy undo puts them back.
function Invoke-JkShotsFile {
    param([string]$Path = (Get-JkShotsPath))
    $todo = @(Get-JkShotsToFile @(Get-JkShots $Path) (Get-Date))
    if (-not $todo.Count) { Say (Paint 'green' "  Nothing to file: only this month's screenshots are loose. $($script:G.check)"); return }
    $log = New-Object System.Collections.Generic.List[object]
    $failed = 0
    foreach ($s in $todo) {
        $dir = Join-Path $Path ($s.Modified.ToString('yyyy-MM', $script:Inv))
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        try {
            $dest = Get-JkUniquePath $dir $s.Name
            Move-Item -LiteralPath $s.Path -Destination $dest -ErrorAction Stop
            $log.Add([pscustomobject]@{ from = $s.Path; to = $dest })
        } catch { $failed++ }
    }
    $dirLog = Get-JkPath 'tidy'
    if (-not (Test-Path $dirLog)) { New-Item -ItemType Directory -Path $dirLog | Out-Null }
    Save-JkJson "tidy\$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').json" ([pscustomobject]@{ root = $Path; at = (Get-Date).ToString('s'); moves = $log.ToArray() })
    $months = @($log | ForEach-Object { Split-Path (Split-Path $_.to -Parent) -Leaf } | Select-Object -Unique).Count
    Say ((Paint 'green' "  filed $(Format-JkCount $log.Count 'screenshot') into $(Format-JkCount $months 'month folder') $($script:G.check)") + (Paint 'gray' '  (jk tidy undo puts them back)'))
    if ($failed) { Say (Paint 'yellow' "  $failed could not be moved (open in another program?)") }
}

function Invoke-JkShotsOld {
    param([string]$Path = (Get-JkShotsPath), [int]$Months = 12, [switch]$Recycle)
    $cut = (Get-Date).AddMonths(-$Months)
    $old = @(Get-JkShots $Path | Where-Object { $_.Modified -lt $cut } | Sort-Object Modified)
    $size = [double](($old | Measure-Object Size -Sum).Sum)
    Write-JkHeader 'Old screenshots' "$(Format-JkCount $old.Count 'file') $($script:G.dot) $(Format-JkSize $size)" -Sub "older than $(Format-JkCount $Months 'month') (before $($cut.ToString('MMM d yyyy', $script:Inv)))"
    if (-not $old.Count) { Say (Paint 'green' "  None. $($script:G.check)"); return }
    foreach ($g in ($old | Group-Object { $_.Modified.ToString('yyyy', $script:Inv) })) {
        Say ('  ' + (Paint 'white' $g.Name) + (Paint 'gray' "  $(Format-JkCount $g.Count 'file') $($script:G.dot) $(Format-JkSize ([double](($g.Group | Measure-Object Size -Sum).Sum)))"))
    }
    Say ''
    if ($Recycle) {
        $n = 0
        foreach ($s in $old) { try { Send-JkToRecycleBin $s.Path; $n++ } catch { } }
        Say ((Paint 'green' "  sent $n screenshots to the Recycle Bin $($script:G.check)") + (Paint 'gray' " $($script:G.dot) restore them from there if needed"))
    } else {
        Say (Paint 'gray' "  jk shots old -Recycle sends these to the Recycle Bin (recoverable); -Months 24 keeps two years instead")
    }
}

function Invoke-JkShots {
    $a = @($args)
    if ($a.Count -eq 0) { Show-JkShots; return }
    $first = ([string]$a[0]).ToLower()
    $rest = @(); if ($a.Count -gt 1) { $rest = @($a[1..($a.Count - 1)]) }
    switch -Regex ($first) {
        '^(file|sort|apply)$' { Invoke-JkShotsFile @rest; return }
        '^(old|stale)$' { Invoke-JkShotsOld @rest; return }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'shots'; return }
    }
    Show-JkShots @a
}
