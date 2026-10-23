# jobs.ps1 - jk jobs: a read-only view of the job-application tracker, a markdown table
# (Date | Company | Role | Location | Status | Link) kept in a folder on the Desktop.
# Answers "did I already apply to X?", lists what is blocked on you (sign-ins, MFA, take-homes,
# queued applications) and shows the weekly pace. jk never writes to the tracker.
#
#   jk jobs                 summary: applied / waiting on you / skipped, per-week pace
#   jk jobs stripe          every row for a company or role, with its link
#   jk jobs todo            everything still waiting on you
#   jk jobs skipped         what was ruled out, and why
#   jk jobs edit            open the tracker

$script:Inv = [Globalization.CultureInfo]::InvariantCulture

# config jobs.file, else the first Desktop folder holding job_application_tracker.md
function Find-JkJobsFile {
    $cfg = Get-JkConfig 'jobs.file'
    if ($cfg) {
        if (Test-Path -LiteralPath $cfg) { return $cfg }
        throw "jobs.file not found: $cfg  (jk config reset jobs.file searches the Desktop again)"
    }
    $desk = [Environment]::GetFolderPath('Desktop')
    foreach ($dir in @(Get-ChildItem -LiteralPath $desk -Directory -ErrorAction SilentlyContinue)) {
        $f = Join-Path $dir.FullName 'job_application_tracker.md'
        if (Test-Path -LiteralPath $f) { return $f }
    }
    $null
}

# applied | todo (waiting on you: sign-in, MFA, take-home, queued, half-filled) |
# skip (ruled out: not eligible, closed, below the pay floor, decided against)
function Get-JkJobState([string]$Status) {
    $s = $Status.Trim()
    if ($s -match '^(SKIPPED|CANCELLED|Closed|Not eligible|Withdrawn|Excluded|User decided not|Decided not)') { return 'skip' }
    if ($s -match '^not submitted' -and $s -match 'C\$\d+\s*/\s*h|below|floor|threshold|no longer|not found|delisted|not eligible') { return 'skip' }
    if ($s -match '^(submitted|applied|direct\b[^.;]*\bsubmitted)' -or $s -match '^[^.;]{0,40}\bsubmitted successfully') { return 'applied' }
    'todo'
}

# Comparable role name: "SWE Intern, Backend (Summer 2027) (gh 123)" -> "swe intern backend"
function Get-JkJobKey([string]$Role) {
    (($Role -replace '\([^)]*\)', ' ') -replace '[^A-Za-z0-9]+', ' ').Trim().ToLower()
}

# -Cached reuses the last parse while the file is unchanged (path, mtime, size): the dashboard
# reads the tracker on every `jk`.
function Get-JkJobs {
    param([string]$Path, [switch]$Cached)
    if (-not $Path) { $Path = Find-JkJobsFile }
    if (-not $Path) { return @() }
    $fi = Get-Item -LiteralPath $Path
    $stamp = "$Path|$($fi.LastWriteTimeUtc.Ticks)|$($fi.Length)"
    if ($Cached -and $script:JkJobsCache -and $script:JkJobsCache.Stamp -eq $stamp) { return $script:JkJobsCache.Rows }
    $cols = @{ date = 0; company = 1; role = 2; where = 3; status = 4; link = 5 }
    $rows = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($ln in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        $t = $ln.Trim()
        if (-not $t.StartsWith('|')) { continue }
        # "\|" inside a cell is a literal bar, not a column break
        $cells = @(($t.Trim('|') -replace '\\\|', [string][char]1).Split('|') | ForEach-Object { $_.Replace([string][char]1, '|').Trim() })
        if ($cells -contains 'Company' -and $cells -contains 'Status') {
            # a header row: map the columns by name, so a reordered table still reads right
            for ($i = 0; $i -lt $cells.Count; $i++) {
                switch -Regex ($cells[$i]) {
                    '^date' { $cols.date = $i }
                    '^company' { $cols.company = $i }
                    '^(role|position|title)' { $cols.role = $i }
                    '^(location|where)' { $cols.where = $i }
                    '^status' { $cols.status = $i }
                    '^(link|url)' { $cols.link = $i }
                }
            }
            continue
        }
        $cell = @{}
        foreach ($k in @($cols.Keys)) { $cell[$k] = $(if ($cols[$k] -lt $cells.Count) { $cells[$cols[$k]] } else { '' }) }
        if ($cell.date -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
        $rows.Add([pscustomobject]@{
                N        = $n
                Date     = [datetime]::ParseExact($cell.date, 'yyyy-MM-dd', $script:Inv)
                Company  = $cell.company
                Role     = $cell.role
                Where    = $cell.where
                Status   = $cell.status
                Link     = $cell.link
                State    = (Get-JkJobState $cell.status)
                Resolved = $false
            })
        $n++
    }
    # a row that was blocked and then applied to (same company, same role) is no longer waiting.
    # Roles must match exactly once ids in brackets are dropped: "Intern" vs "Intern, Web" are
    # different applications.
    $applied = @($rows | Where-Object { $_.State -eq 'applied' })
    foreach ($r in $rows) {
        if ($r.State -ne 'todo') { continue }
        $k = Get-JkJobKey $r.Role
        if (-not $k) { continue }
        foreach ($a in $applied) {
            if ($a.Company -ne $r.Company -or $a.Date -lt $r.Date) { continue }
            if ((Get-JkJobKey $a.Role) -eq $k) { $r.Resolved = $true; break }
        }
    }
    $script:JkJobsCache = @{ Stamp = $stamp; Rows = $rows.ToArray() }
    $rows.ToArray()
}

# Applications blocked on you in the last JkJobStaleDays, newest first (for the dashboard).
function Get-JkJobsWaiting([datetime]$Now = (Get-JkNow)) {
    @(Get-JkJobs -Cached | Where-Object { $_.State -eq 'todo' -and -not $_.Resolved -and -not (Test-JkJobStale $_ $Now) } | Sort-Object Date, N -Descending)
}

# The useful part of a status: "via Greenhouse" for applications, the reason for the rest.
function Get-JkJobNote($Row) {
    $s = [string]$Row.Status
    if ($Row.State -eq 'applied') {
        # case-sensitive: "via AMD Canada iCIMS" -> "via AMD Canada", "via Greenhouse embed" -> "via Greenhouse"
        if ($s -cmatch '\b[Vv]ia\s+([A-Za-z][\w.]*(?:\s+[A-Z][\w.]*)?)') { return "via $($Matches[1])" }
        return 'submitted'
    }
    # drop a short leading state ("NOT SUBMITTED -", "Blocked -") and keep the reason
    if ($s -match '^(.{0,26}?)\s\p{Pd}\s+(.+)$') { return $Matches[2] }
    $s
}

# Rows still waiting after this many days are dimmed: the posting has likely moved on.
$script:JkJobStaleDays = 21

function Test-JkJobStale($Row, [datetime]$Now) {
    $Row.State -eq 'todo' -and ($Now.Date - $Row.Date).TotalDays -gt $script:JkJobStaleDays
}

function Format-JkJobLine($Row, [int]$Width, [datetime]$Now = (Get-JkNow)) {
    $stale = Test-JkJobStale $Row $Now
    $glyph = switch ($Row.State) {
        'applied' { Paint 'green' $script:G.check }
        'todo' { if ($stale) { Paint 'gray' '!' } else { Paint 'amber' '!' } }
        default { Paint 'gray' $script:G.dash }
    }
    $nameStyle = 'bold white'; $roleStyle = ''
    if ($stale) { $nameStyle = 'muted'; $roleStyle = 'muted' }
    $roleW = [Math]::Max(18, [int](($Width - 30) * 0.42))
    $noteW = [Math]::Max(10, $Width - 2 - 7 - 2 - 18 - $roleW - 2)
    '  ' + (Paint 'muted' (Fit $Row.Date.ToString('MMM d', $script:Inv) 7)) + $glyph + ' ' + (Paint $nameStyle (Fit $Row.Company 17)) + ' ' + (Paint $roleStyle (Fit $Row.Role $roleW)) + '  ' + (Paint 'gray' (Fit (Get-JkJobNote $Row) $noteW).TrimEnd())
}

function Show-JkJobs {
    $path = Find-JkJobsFile
    if (-not $path) {
        Say ((Paint 'yellow' '  No job_application_tracker.md in a Desktop folder.') + (Paint 'gray' '  jk config set jobs.file <path to the tracker>'))
        return
    }
    $rows = @(Get-JkJobs $path)
    $now = Get-JkNow
    $w = Get-JkWidth
    $applied = @($rows | Where-Object { $_.State -eq 'applied' })
    $todo = @($rows | Where-Object { $_.State -eq 'todo' -and -not $_.Resolved })
    $skip = @($rows | Where-Object { $_.State -eq 'skip' })
    $right = "$($rows.Count) rows"
    if ($rows.Count) { $right += " $($script:G.dot) last entry $(Format-JkRelDay (@($rows | Sort-Object Date)[-1].Date) $now)" }
    Write-JkHeader 'Jobs' $right -Sub (Split-Path $path -Leaf)
    $fresh = @($todo | Where-Object { -not (Test-JkJobStale $_ $now) }).Count
    $freshTxt = ''
    if ($todo.Count) { $freshTxt = Paint 'gray' " ($fresh from the last $($script:JkJobStaleDays) days)" }
    Say ('  ' + (Paint 'green' "$($script:G.check) $($applied.Count) applied") + '   ' + (Paint 'amber' "! $($todo.Count) waiting on you") + $freshTxt + '   ' + (Paint 'gray' "$($script:G.dash) $($skip.Count) ruled out"))

    # applications per week (Mon-Sun), the last 8 weeks
    $monday = $now.Date.AddDays(-(([int]$now.DayOfWeek + 6) % 7))
    $weeks = @(0..7 | ForEach-Object { $monday.AddDays(-7 * (7 - $_)) })
    $counts = @($weeks | ForEach-Object { $wk = $_; @($applied | Where-Object { $_.Date -ge $wk -and $_.Date -lt $wk.AddDays(7) }).Count })
    $max = [Math]::Max(1, ($counts | Measure-Object -Maximum).Maximum)
    Say ''
    Say (' ' + (Paint 'bold white' 'Applied per week'))
    for ($i = 0; $i -lt $weeks.Count; $i++) {
        $label = $weeks[$i].ToString('MMM d', $script:Inv)
        if ($i -eq $weeks.Count - 1) { $label = 'this wk' }
        Say ('  ' + (Paint 'muted' (Fit $label 8)) + (Get-JkBar ($counts[$i] / $max) 30 'green') + ' ' + (Paint 'gray' ([string]$counts[$i])))
    }

    if ($todo.Count) {
        Say ''
        Say (' ' + (Paint 'bold white' 'Waiting on you') + (Paint 'gray' "  sign-ins, MFA, take-homes, queued; newest first, dimmed after $($script:JkJobStaleDays) days"))
        foreach ($r in @($todo | Sort-Object Date, N -Descending | Select-Object -First 8)) { Say (Format-JkJobLine $r $w $now) }
        if ($todo.Count -gt 8) { Say (Paint 'gray' "  +$($todo.Count - 8) more  $($script:G.dot)  jk jobs todo") }
    }

    $top = @($applied | Group-Object Company | Sort-Object Count -Descending | Select-Object -First 6)
    if ($top.Count) {
        Say ''
        Say ('  ' + (Paint 'gray' 'Most applied: ') + (($top | ForEach-Object { "$($_.Name) $($_.Count)" }) -join (Paint 'gray' "  $($script:G.dot)  ")))
    }
    Say ''
    Say (Paint 'gray' "  jk jobs <company or role>  $($script:G.dot)  jk jobs todo  $($script:G.dot)  jk jobs skipped  $($script:G.dot)  jk jobs edit")
}

function Show-JkJobList {
    param([ValidateSet('todo', 'skip')][string]$State)
    $rows = @(Get-JkJobs)
    $w = Get-JkWidth
    $pick = @($rows | Where-Object { $_.State -eq $State -and -not $_.Resolved } | Sort-Object Date, N -Descending)
    $title = 'Waiting on you'; if ($State -eq 'skip') { $title = 'Ruled out' }
    Write-JkHeader "Jobs $($script:G.dot) $title" "$($pick.Count) row$(if ($pick.Count -ne 1) { 's' })"
    if (-not $pick.Count) { Say (Paint 'green' '  Nothing here.'); return }
    foreach ($r in $pick) { Say (Format-JkJobLine $r $w) }
}

# "Did I already apply?": every row whose company, role or location has all the words.
function Find-JkJobs {
    param([string]$Query)
    $rows = @(Get-JkJobs)
    $w = Get-JkWidth
    $words = @($Query.ToLower() -split '\s+' | Where-Object { $_ })
    $hits = @($rows | Where-Object {
            $hay = "$($_.Company) $($_.Role) $($_.Where)".ToLower()
            -not @($words | Where-Object { -not $hay.Contains($_) }).Count
        } | Sort-Object Date, N -Descending)
    $nApplied = @($hits | Where-Object { $_.State -eq 'applied' }).Count
    Write-JkHeader "Jobs $($script:G.dot) $Query" "$($hits.Count) row$(if ($hits.Count -ne 1) { 's' }) $($script:G.dot) $nApplied applied"
    if (-not $hits.Count) {
        Say ('  ' + (Paint 'green' "Not in the tracker: no application matches '$Query' yet."))
        return
    }
    foreach ($r in $hits) {
        Say (Format-JkJobLine $r $w)
        if ($r.Link -match '^https?://') { Say ('                 ' + (Paint 'gray dim' (Fit $r.Link ($w - 18)).TrimEnd())) }
    }
}

function Invoke-JkJobs {
    $a = @($args | ForEach-Object { [string]$_ })
    if ($a.Count -eq 0) { Show-JkJobs; return }
    switch -Regex ($a[0].ToLower()) {
        '^(todo|waiting|blocked)$' { Show-JkJobList -State todo; return }
        '^(skipped|skip|ruled)$' { Show-JkJobList -State skip; return }
        '^(edit|open)$' {
            $p = Find-JkJobsFile
            if (-not $p) { throw 'no tracker found; jk config set jobs.file <path>' }
            Invoke-Item -LiteralPath $p
            return
        }
        '^(path|file|where)$' { Say (Find-JkJobsFile); return }
        '^help$' { Show-JkHelp 'jobs'; return }
        default { Find-JkJobs ($a -join ' ') }
    }
}
