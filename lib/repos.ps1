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

# git in one repo as a background process; its output is collected later by Receive-JkGit.
# Starting every call before reading any runs them side by side, and reading stdout as UTF-8
# keeps commit subjects in any language intact (the console code page would garble them).
function Start-JkGit([string]$Path, [string]$Arguments) {
    if (-not $script:JkGitExe) { $script:JkGitExe = (Get-Command git -ErrorAction Stop).Source }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $script:JkGitExe
    $psi.Arguments = "-C `"$Path`" $Arguments"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding $false
    $p = [Diagnostics.Process]::Start($psi)
    # drain both pipes asynchronously so a chatty process can never block on a full buffer
    [pscustomobject]@{ Proc = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
}

function Receive-JkGit($Job, [int]$TimeoutMs = 30000) {
    # a hung git (a fetch stuck on the network) is killed rather than waited on forever
    if (-not $Job.Out.Wait($TimeoutMs)) {
        try { $Job.Proc.Kill() } catch { }
        $Job.Proc.Dispose()
        return @()
    }
    $text = $Job.Out.Result
    $null = $Job.Err.Result
    $Job.Proc.WaitForExit()
    $Job.Proc.Dispose()
    @($text -split "`r?`n" | Where-Object { $_ -ne '' })
}

# Status of many repos at once: three git calls each, all started before any is read.
function Get-JkRepoStatuses([string[]]$Paths) {
    $jobs = @(foreach ($p in $Paths) {
            [pscustomobject]@{
                Path   = $p
                Status = (Start-JkGit $p 'status --porcelain=v1 -b')
                Log    = (Start-JkGit $p 'log -1 --format=%cr|%s')
                Remote = (Start-JkGit $p 'remote')
            }
        })
    foreach ($j in $jobs) {
        ConvertTo-JkRepoStatus -Path $j.Path -Lines (Receive-JkGit $j.Status) -Last (@(Receive-JkGit $j.Log) | Select-Object -First 1) -Remote (@(Receive-JkGit $j.Remote) | Select-Object -First 1)
    }
}

function Get-JkRepoStatus([string]$Path) { Get-JkRepoStatuses @($Path) }

function ConvertTo-JkRepoStatus {
    param([string]$Path, [string[]]$Lines, [string]$Last, [string]$Remote)
    $lines = @($Lines | Where-Object { $_ })
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
    $when = ''; $msg = ''
    if ($Last) { $parts = $Last.Split('|', 2); $when = $parts[0]; if ($parts.Count -gt 1) { $msg = $parts[1] } }
    [pscustomobject]@{ Path = $Path; Name = (Split-Path $Path -Leaf); Branch = $branch; Ahead = $ahead; Behind = $behind; Upstream = $upstream; Modified = $modified; Untracked = $untracked; When = $when; Msg = $msg; Remote = [string]$Remote }
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
        try {
            # all at once: fetches wait on the network, not the CPU
            $jobs = @(foreach ($r in $repos) { Start-JkGit $r 'fetch --quiet' })
            foreach ($j in $jobs) { $null = Receive-JkGit $j 60000 }
        } finally { $env:GIT_TERMINAL_PROMPT = $oldPrompt }
    }
    $st = @(Get-JkRepoStatuses $repos | Sort-Object @{ Expression = { if ($_.Modified + $_.Untracked + $_.Ahead + $_.Behind -gt 0) { 0 } else { 1 } } }, Name)
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
        Say ('  ' + $mark + ' ' + (Paint 'bold white' (Fit $r.Name 24)) + (Paint 'muted' (Fit $r.Branch 13)) + ' ' + $stateTxt)
        if ($r.When) { Say ('      ' + (Paint 'gray' (Fit "$($r.When): $($r.Msg)" ($w - 8)))) }
    }
    if (-not $Fetch) { Say ''; Say (Paint 'gray' "  behind counts use the last fetch; jk repos -Fetch refreshes them") }
}
