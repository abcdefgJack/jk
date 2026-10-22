# repos.ps1 - one screen for every git repo under your project roots.

function Find-JkRepos {
    param([string[]]$Roots, [int]$Depth = 3)
    $found = New-Object System.Collections.Generic.List[string]
    $walk = $null
    $walk = {
        param($dir, $level)
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { $found.Add($dir); return }
        if ($level -ge $Depth) { return }
        foreach ($sub in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)) {
            if ($sub.Name -match '^(node_modules|\.venv|venv|__pycache__|target|build|dist|\..+)$') { continue }
            & $walk $sub.FullName ($level + 1)
        }
    }
    foreach ($r in $Roots) { if (Test-Path -LiteralPath $r) { & $walk $r 0 } }
    $found
}

function Get-JkRepoStatus([string]$Path) {
    $lines = @(& git -C $Path status --porcelain=v1 -b 2>$null)
    $head = ''
    if ($lines.Count) { $head = $lines[0] }
    $branch = '?'; $ahead = 0; $behind = 0; $upstream = $false
    if ($head -match '^## (?:No commits yet on )?([^\.\s]+)(?:\.\.\.(\S+))?(?: \[(.+)\])?') {
        $branch = $Matches[1]
        if ($Matches[2]) { $upstream = $true }
        if ($Matches[3]) {
            if ($Matches[3] -match 'ahead (\d+)') { $ahead = [int]$Matches[1] }
            if ($Matches[3] -match 'behind (\d+)') { $behind = [int]$Matches[1] }
        }
    }
    $changes = @($lines | Select-Object -Skip 1)
    $untracked = @($changes | Where-Object { $_.StartsWith('??') }).Count
    $modified = $changes.Count - $untracked
    $last = (& git -C $Path log -1 --format='%cr|%s' 2>$null)
    $when = ''; $msg = ''
    if ($last) { $parts = ([string]$last).Split('|', 2); $when = $parts[0]; if ($parts.Count -gt 1) { $msg = $parts[1] } }
    $remote = (& git -C $Path remote 2>$null | Select-Object -First 1)
    [pscustomobject]@{ Path = $Path; Name = (Split-Path $Path -Leaf); Branch = $branch; Ahead = $ahead; Behind = $behind; Upstream = $upstream; Modified = $modified; Untracked = $untracked; When = $when; Msg = $msg; Remote = [string]$remote }
}

function Invoke-JkRepos {
    param([string]$Root, [switch]$Fetch, [int]$Depth = 3)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is not on PATH' }
    $roots = @()
    if ($Root) { $roots = @($Root) } else { $roots = @((Get-JkConfig 'repos.roots') -split ';' | Where-Object { $_ } | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) }) }
    $repos = @(Find-JkRepos $roots $Depth)
    if ($Fetch) {
        Say (Paint 'gray' "  fetching $($repos.Count) repos$($script:G.ell)")
        # never sit waiting on a credential prompt for a repo that needs a login
        $oldPrompt = $env:GIT_TERMINAL_PROMPT
        $env:GIT_TERMINAL_PROMPT = '0'
        try { foreach ($r in $repos) { & git -C $r fetch --quiet 2>$null | Out-Null } }
        finally { $env:GIT_TERMINAL_PROMPT = $oldPrompt }
    }
    $st = @($repos | ForEach-Object { Get-JkRepoStatus $_ } | Sort-Object @{ Expression = { if ($_.Modified + $_.Untracked + $_.Ahead + $_.Behind -gt 0) { 0 } else { 1 } } }, Name)
    $dirty = @($st | Where-Object { $_.Modified + $_.Untracked -gt 0 }).Count
    $unpushed = @($st | Where-Object { $_.Ahead -gt 0 }).Count
    Write-JkHeader 'Repos' "$($st.Count) repos $($script:G.dot) $dirty with changes $($script:G.dot) $unpushed unpushed" -Sub ($roots -join '; ')
    $w = Get-JkWidth
    foreach ($r in $st) {
        $state = @()
        if ($r.Modified) { $state += Paint 'orange' "$($r.Modified) changed" }
        if ($r.Untracked) { $state += Paint 'yellow' "$($r.Untracked) new" }
        if ($r.Ahead) { $state += Paint 'cyan' "$($script:G.up)$($r.Ahead) unpushed" }
        if ($r.Behind) { $state += Paint 'purple' "$($script:G.down)$($r.Behind) behind" }
        if (-not $r.Remote) { $state += Paint 'gray' 'no remote' }
        elseif (-not $r.Upstream -and $r.Branch -ne '?') { $state += Paint 'gray' 'no upstream' }
        $mark = Paint 'green' $script:G.check
        if ($r.Modified + $r.Untracked + $r.Ahead + $r.Behind -gt 0) { $mark = Paint 'orange' $script:G.circle }
        $stateTxt = $state -join (Paint 'gray' ', ')
        if (-not $stateTxt) { $stateTxt = Paint 'gray' 'clean' }
        Say ('  ' + $mark + ' ' + (Paint 'bold white' (Fit $r.Name 24)) + (Paint 'muted' (Fit $r.Branch 14)) + $stateTxt)
        if ($r.When) { Say ('      ' + (Paint 'gray' (Fit "$($r.When): $($r.Msg)" ($w - 8)))) }
    }
    if (-not $Fetch) { Say ''; Say (Paint 'gray' "  behind counts use the last fetch; jk repos -Fetch refreshes them") }
}
