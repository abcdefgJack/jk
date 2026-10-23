# go.ps1 - jump to folders by fuzzy name.  j co250  |  j co250/final  |  j -  |  jk mark
# Candidates: bookmarks, every folder on the Desktop, course folders, common user folders,
# and anything you have jumped to before (ranked by how often you go there).

$script:JkPrevDir = $null

function Get-JkGoData {
    $d = Read-JkJson 'bookmarks.json' $null
    if (-not $d) { $d = [pscustomobject]@{ marks = @(); visits = @() } }
    foreach ($p in 'marks', 'visits') { if ($null -eq (Get-JkProp $d $p)) { Set-JkProp $d $p @() } }
    $d
}

function Save-JkGoData($Data) { $Data.marks = @($Data.marks); $Data.visits = @($Data.visits); Save-JkJson 'bookmarks.json' $Data }

function Get-JkGoCandidates {
    $d = Get-JkGoData
    $list = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $add = {
        param($alias, $path, $source)
        if (-not $path) { return }
        # one path may carry several names (a bookmark plus its folder name)
        $k = $alias + '|' + $path.TrimEnd('\').ToLower()
        if ($seen.ContainsKey($k)) { return }
        $seen[$k] = $true
        $list.Add([pscustomobject]@{ Alias = $alias; Path = $path.TrimEnd('\'); Source = $source })
    }
    foreach ($m in @($d.marks)) { & $add ([string]$m.alias) ([string]$m.path) 'mark' }
    $desk = [Environment]::GetFolderPath('Desktop')
    $docs = [Environment]::GetFolderPath('MyDocuments')
    & $add 'desktop' $desk 'auto'
    & $add 'documents' $docs 'auto'
    & $add 'downloads' (Get-JkDownloadsPath) 'auto'
    & $add 'home' $HOME 'auto'
    & $add 'jk' (Get-JkRoot) 'auto'
    & $add 'jkdata' (Get-JkHome) 'auto'
    # "j jobs": the job-search folder, whatever it is called
    try { $jf = Find-JkJobsFile; if ($jf) { & $add 'jobs' (Split-Path $jf -Parent) 'auto' } } catch { }
    $cpRoot = [Environment]::ExpandEnvironmentVariables((Get-JkConfig 'cp.root'))
    if (Test-Path -LiteralPath $cpRoot) { & $add 'cp' $cpRoot 'auto' }
    $roots = @($desk)
    foreach ($r in $roots) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.StartsWith('.') })) {
            & $add (Get-JkNormKey $dir.Name) $dir.FullName 'auto'
            # one level deeper for "collection" folders such as Waterloo course\CO250
            if ($dir.Name -match '(?i)course|school|uni|class|projects?|repos?|code') {
                foreach ($sub in @(Get-ChildItem -LiteralPath $dir.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.StartsWith('.') })) {
                    & $add (Get-JkNormKey $sub.Name) $sub.FullName 'auto'
                }
            }
        }
    }
    foreach ($v in @($d.visits)) {
        if (Test-Path -LiteralPath $v.path) { & $add (Get-JkNormKey (Split-Path $v.path -Leaf)) ([string]$v.path) 'recent' }
    }
    $list
}

function Get-JkGoScore([string]$Query, $Cand, $Visits) {
    $q = Get-JkNormKey $Query
    if (-not $q) { return 0 }
    $alias = $Cand.Alias
    $leaf = Get-JkNormKey (Split-Path $Cand.Path -Leaf)
    $score = 0
    foreach ($name in @($alias, $leaf)) {
        if (-not $name) { continue }
        $s = 0
        if ($name -eq $q) { $s = 1000 }
        elseif ($name.StartsWith($q)) { $s = 600 - ($name.Length - $q.Length) }
        elseif ($name.Contains($q)) { $s = 400 - ($name.Length - $q.Length) }
        else {
            # subsequence: every query char appears in order
            $i = 0
            foreach ($ch in $name.ToCharArray()) { if ($i -lt $q.Length -and $ch -eq $q[$i]) { $i++ } }
            if ($i -eq $q.Length) { $s = 150 - ($name.Length - $q.Length) }
        }
        if ($s -gt $score) { $score = $s }
    }
    if ($score -le 0) { return 0 }
    if ($Cand.Source -eq 'mark') { $score += 60 }
    $v = $Visits[$Cand.Path.ToLower()]
    if ($v) { $score += [Math]::Min(120, [int](25 * [Math]::Log(1 + [double]$v))) }
    $score
}

function Find-JkGo([string]$Query) {
    $d = Get-JkGoData
    $visits = @{}
    foreach ($v in @($d.visits)) { $visits[([string]$v.path).ToLower()] = [int]$v.count }
    $best = $null; $bestScore = 0
    foreach ($c in (Get-JkGoCandidates)) {
        $s = Get-JkGoScore $Query $c $visits
        if ($s -gt $bestScore -or ($s -eq $bestScore -and $best -and $c.Path.Length -lt $best.Path.Length)) { $best = $c; $bestScore = $s }
    }
    $best
}

# "co250/final" -> resolve "co250", then fuzzy-match each further segment among subfolders
function Resolve-JkGoPath([string]$Query) {
    $parts = @($Query -split '[\\/]' | Where-Object { $_ })
    if ($parts.Count -eq 0) { return $null }
    if (Test-Path -LiteralPath $Query -PathType Container) { return (Resolve-Path -LiteralPath $Query).ProviderPath }
    $hit = Find-JkGo $parts[0]
    if (-not $hit) { return $null }
    $path = $hit.Path
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $subs = @(Get-ChildItem -LiteralPath $path -Directory -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Alias = (Get-JkNormKey $_.Name); Path = $_.FullName; Source = 'auto' } })
        $best = $null; $bs = 0
        foreach ($s in $subs) { $sc = Get-JkGoScore $parts[$i] $s @{}; if ($sc -gt $bs) { $bs = $sc; $best = $s } }
        if (-not $best) { throw "no folder matching '$($parts[$i])' inside $path" }
        $path = $best.Path
    }
    $path
}

function Add-JkVisit([string]$Path) {
    $d = Get-JkGoData
    $hit = @($d.visits | Where-Object { ([string]$_.path).ToLower() -eq $Path.ToLower() })
    if ($hit) { $hit[0].count = [int]$hit[0].count + 1; $hit[0].last = (Get-Date).ToString('s') }
    else { $d.visits = @($d.visits) + [pscustomobject]@{ path = $Path; count = 1; last = (Get-Date).ToString('s') } }
    # keep the 200 most recent
    $d.visits = @($d.visits | Sort-Object last -Descending | Select-Object -First 200)
    Save-JkGoData $d
}

function Invoke-JkGo {
    param(
        [Parameter(Position = 0)][string]$Query,
        [Alias('e')][switch]$Explorer,
        [Alias('c')][switch]$Code,
        [Alias('p')][switch]$Print
    )
    if (-not $Query) { Show-JkGoList; return }
    if ($Query -eq '-') {
        if (-not $script:JkPrevDir) { throw 'no previous folder yet' }
        $target = $script:JkPrevDir
    } else {
        $target = Resolve-JkGoPath $Query
        if (-not $target) { throw "nothing matches '$Query' (see: jk go)" }
    }
    if ($Print) { return $target }
    Add-JkVisit $target
    if ($Explorer) { Start-Process explorer.exe $target; Say ((Paint 'green' '  opened in Explorer ') + $target); return }
    if ($Code) { Open-JkInEditor $target; Say ((Paint 'green' '  opened in editor ') + $target); return }
    $script:JkPrevDir = (Get-Location).ProviderPath
    Set-Location -LiteralPath $target
    Say ((Paint 'gray' "  $($script:G.arrow) ") + (Paint 'bold cyan' $target))
}

function Show-JkGoList {
    $d = Get-JkGoData
    Write-JkHeader 'Jump list' "j <name>  $($script:G.dot)  j name/sub  $($script:G.dot)  j -  $($script:G.dot)  -e explorer  -c editor"
    $w = Get-JkWidth
    if (@($d.marks).Count) {
        Say (' ' + (Paint 'bold white' 'Bookmarks'))
        foreach ($m in @($d.marks | Sort-Object alias)) { Say ('  ' + (Paint 'cyan' (Fit $m.alias 16)) + (Paint 'muted' (Fit $m.path ($w - 20)))) }
        Say ''
    }
    $top = @($d.visits | Sort-Object { [int]$_.count } -Descending | Select-Object -First 12)
    if ($top.Count) {
        Say (' ' + (Paint 'bold white' 'Most visited'))
        foreach ($v in $top) { Say ('  ' + (Paint 'gray' (Fit "$($v.count)x" 6 -Right)) + '  ' + (Paint 'muted' (Fit $v.path ($w - 12)))) }
        Say ''
    }
    $auto = @(Get-JkGoCandidates | Where-Object { $_.Source -eq 'auto' })
    Say (' ' + (Paint 'bold white' 'Also matches') + (Paint 'gray' "  ($($auto.Count) folders)"))
    $line = '  '
    foreach ($a in $auto) {
        if ((Get-JkVisibleLength $line) + $a.Alias.Length + 2 -gt $w) { Say $line; $line = '  ' }
        $line += (Paint 'muted' $a.Alias) + '  '
    }
    if ($line.Trim()) { Say $line }
}

function Invoke-JkMark {
    param([Parameter(Position = 0)][string]$Alias, [string]$Path, [switch]$Remove)
    $d = Get-JkGoData
    if ($Remove) {
        if (-not $Alias) { throw 'usage: jk mark <alias> -Remove' }
        $d.marks = @($d.marks | Where-Object { $_.alias -ne $Alias })
        Save-JkGoData $d
        Say (Paint 'yellow' "  removed bookmark '$Alias'")
        return
    }
    if (-not $Path) { $Path = (Get-Location).ProviderPath }
    if (-not $Alias) { $Alias = Get-JkNormKey (Split-Path $Path -Leaf) }
    $Alias = $Alias.ToLower()
    $d.marks = @($d.marks | Where-Object { $_.alias -ne $Alias }) + [pscustomobject]@{ alias = $Alias; path = $Path }
    Save-JkGoData $d
    Say ((Paint 'green' "  bookmarked $($script:G.check)") + "  $(Paint 'cyan' $Alias) $($script:G.arrow) $Path" + (Paint 'gray' "   (j $Alias)"))
}
