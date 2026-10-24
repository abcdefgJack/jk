# jk.psm1 - loads the toolkit and defines the `jk` entry point (plus `j`, a shortcut for `jk go`).

foreach ($lib in 'core', 'due', 'sync', 'classes', 'todo', 'focus', 'remind', 'grade', 'tidy', 'cp', 'go', 'find', 'sys', 'repos', 'speed', 'space', 'review', 'plan', 'jobs', 'dash', 'help', 'setup') {
    $f = Join-Path $PSScriptRoot "lib\$lib.ps1"
    if (Test-Path -LiteralPath $f) { . $f }
}

# name -> handler, aliases, one-line description (drives dispatch, `jk help` and tab completion)
$script:JkCommands = [ordered]@{
    'due'    = @{ Fn = 'Invoke-JkDue'; Aliases = @('d', 'deadlines'); Desc = 'course deadlines: upcoming, add, done, week grid, calendar, .ics, reminders' }
    'class'  = @{ Fn = 'Invoke-JkClass'; Aliases = @('classes', 'cls', 'timetable', 'schedule', 'sched'); Desc = 'class schedule: what is on today, the next class, a weekly timetable' }
    'week'   = @{ Fn = 'Show-JkDueWeek'; Aliases = @('wk'); Desc = 'the next two weeks as a Mon-Sun grid (same as jk due week)' }
    'exams'  = @{ Fn = 'Show-JkExams'; Aliases = @('exam', 'midterms'); Desc = 'every remaining exam with a countdown (same as jk due exams)' }
    'plan'   = @{ Fn = 'Invoke-JkPlan'; Aliases = @('study'); Desc = 'split today''s study time across upcoming exams and assignments; jk plan start' }
    'review' = @{ Fn = 'Show-JkReview'; Aliases = @('weekly', 'retro'); Desc = 'last 7 days done and slipped, next 7 days load, where the marks are' }
    'todo'   = @{ Fn = 'Invoke-JkTodo'; Aliases = @('t', 'todos'); Desc = 'quick personal to-do list' }
    'jobs'   = @{ Fn = 'Invoke-JkJobs'; Aliases = @('job', 'apps', 'applications'); Desc = 'job applications: did I apply to X?, what is waiting on me, weekly pace (read-only)' }
    'focus'  = @{ Fn = 'Invoke-JkFocus'; Aliases = @('f', 'pomo', 'pomodoro'); Desc = 'focus timer with a popup when time is up, plus weekly stats' }
    'in'     = @{ Fn = 'Invoke-JkRemindIn'; Aliases = @(); Desc = 'remind me in a while:  jk in 20m "take laundry out"' }
    'at'     = @{ Fn = 'Invoke-JkRemindAt'; Aliases = @(); Desc = 'remind me at a time:   jk at 3:30pm "call home"' }
    'remind' = @{ Fn = 'Invoke-JkRemind'; Aliases = @('reminders'); Desc = 'list/cancel reminders; install the daily deadline check' }
    'grade'  = @{ Fn = 'Invoke-JkGrade'; Aliases = @('g', 'grades', 'marks'); Desc = 'record marks, see your running average and what you need on the final' }
    'tidy'   = @{ Fn = 'Invoke-JkTidy'; Aliases = @('clean', 'downloads'); Desc = 'sort the Downloads folder into categories (dry run first, undoable)' }
    'cp'     = @{ Fn = 'Invoke-JkCp'; Aliases = @('contest'); Desc = 'competitive programming: new problem, compile+test samples, stress test' }
    'go'     = @{ Fn = 'Invoke-JkGo'; Aliases = @('cd', 'jump'); Desc = 'jump to a folder by fuzzy name (also: j <name>)' }
    'mark'   = @{ Fn = 'Invoke-JkMark'; Aliases = @('bookmark'); Desc = 'bookmark the current folder for jk go' }
    'find'   = @{ Fn = 'Invoke-JkFind'; Aliases = @('search', 'ff'); Desc = 'find a file by words in its name or folders (Desktop, Documents, Downloads); -o opens it' }
    'recent' = @{ Fn = 'Invoke-JkRecent'; Aliases = @('changed', 'latest'); Desc = 'files you changed in the last 2 days (or N), newest first; jk find -o 1 opens one' }
    'repos'  = @{ Fn = 'Invoke-JkRepos'; Aliases = @('git'); Desc = 'status of every git repo on the Desktop: dirty, ahead, behind' }
    'sys'    = @{ Fn = 'Invoke-JkSys'; Aliases = @('system', 'stats'); Desc = 'CPU, RAM, disks, battery, network, memory hogs' }
    'port'   = @{ Fn = 'Invoke-JkPort'; Aliases = @('ports'); Desc = 'what is listening on which port; free a port with -Kill' }
    'space'  = @{ Fn = 'Invoke-JkSpace'; Aliases = @('disk', 'du'); Desc = 'what is filling the disk: caches, temp, Docker, node_modules (read-only report)' }
    'speed'  = @{ Fn = 'Invoke-JkSpeed'; Aliases = @('startup', 'slow'); Desc = 'why new terminals are slow; jk speed fix makes the conda hook instant' }
    'brief'  = @{ Fn = 'Show-JkBrief'; Aliases = @(); Desc = 'one-line summary (shown when PowerShell starts)' }
    'config' = @{ Fn = 'Invoke-JkConfig'; Aliases = @('cfg', 'settings'); Desc = 'show or change settings' }
    'backup' = @{ Fn = 'Invoke-JkBackup'; Aliases = @('backups', 'restore'); Desc = 'daily snapshots of your jk data; restore a day' }
    'update' = @{ Fn = 'Update-Jk'; Aliases = @('upgrade'); Desc = 'pull the latest jk from GitHub and reload it' }
    'doctor' = @{ Fn = 'Invoke-JkDoctor'; Aliases = @('check'); Desc = 'check that compilers, reminders and the profile hook are set up' }
    'setup'  = @{ Fn = 'Invoke-JkSetup'; Aliases = @('install'); Desc = 'install/uninstall the profile banner and daily reminder task' }
    'help'   = @{ Fn = 'Show-JkHelp'; Aliases = @('h', '?', '-h', '--help'); Desc = 'help for a command:  jk help due' }
}

function Resolve-JkCommand([string]$Name) {
    $n = $Name.ToLower()
    if ($script:JkCommands.Contains($n)) { return $n }
    foreach ($k in $script:JkCommands.Keys) { if ($script:JkCommands[$k].Aliases -contains $n) { return $k } }
    $pref = @($script:JkCommands.Keys | Where-Object { $_.StartsWith($n) })
    if ($pref.Count -eq 1) { return $pref[0] }
    $null
}

function jk {
    # jk reports through its own messages; git and compilers it runs along the way must not leave
    # their exit codes behind for the prompt or a calling script
    $exitCode = $global:LASTEXITCODE
    try { Invoke-JkCommand @args }
    finally { if ($global:LASTEXITCODE -ne $exitCode) { $global:LASTEXITCODE = $exitCode } }
}

function Invoke-JkCommand {
    $script:JkUseColor = Test-JkColor
    $script:JkConfigCache = $null
    $light = (Get-JkConfig 'theme') -eq 'light'
    if ($light -ne [bool]$script:JkLightTheme) { $script:JkLightTheme = $light; $script:PaintCache = @{} }
    $a = @($args)
    if ($a.Count -eq 0) {
        try { Show-JkDashboard } catch { if ($env:JK_DEBUG) { throw }; Write-Host (Paint 'red' ('  jk: ' + $_.Exception.Message)) }
        return
    }
    $name = Resolve-JkCommand ([string]$a[0])
    if (-not $name) {
        Write-Host (Paint 'red' "  jk: unknown command '$($a[0])'.") (Paint 'gray' "Try 'jk help'.")
        return
    }
    $rest = @()
    if ($a.Count -gt 1) { $rest = @($a[1..($a.Count - 1)]) }
    $fn = $script:JkCommands[$name].Fn
    try {
        & $fn @rest
    } catch {
        if ($env:JK_DEBUG) { throw }
        Write-Host (Paint 'red' ('  jk: ' + $_.Exception.Message))
    }
}

function j { jk go @args }

# ---------------------------------------------------------------- tab completion

# "<command> <action>" -> function whose parameters complete after a dash
$script:JkParamTargets = @{
    'due'          = 'Show-JkDue'
    'due add'      = 'Add-JkDue'
    'due edit'     = 'Edit-JkDue'
    'due cal'      = 'Export-JkDueHtml'
    'due ics'      = 'Export-JkDueIcs'
    'due remind'   = 'Invoke-JkDueRemind'
    'due import'   = 'Import-JkDueHtml'
    'due sync'     = 'Invoke-JkDueSync'
    'due week'     = 'Show-JkDueWeek'
    'due course'   = 'Set-JkCourse'
    'todo add'     = 'Add-JkTodo'
    'class add'    = 'Add-JkClass'
    'class import' = 'Import-JkClasses'
    'class week'   = 'Show-JkTimetable'
    'tidy'         = 'Invoke-JkTidyRun'
    'tidy scan'    = 'Invoke-JkTidyRun'
    'tidy apply'   = 'Invoke-JkTidyRun'
    'tidy dupes'   = 'Invoke-JkTidyDupes'
    'tidy old'     = 'Invoke-JkTidyOld'
    'cp new'       = 'New-JkCpProblem'
    'cp test'      = 'Invoke-JkCpTest'
    'cp run'       = 'Invoke-JkCpRun'
    'cp stress'    = 'Invoke-JkCpStress'
    'cp add'       = 'Add-JkCpTest'
    'go'           = 'Invoke-JkGo'
    'find'         = 'Invoke-JkFind'
    'recent'       = 'Invoke-JkRecent'
    'mark'         = 'Invoke-JkMark'
    'sys'          = 'Invoke-JkSys'
    'grade add'    = 'Add-JkGradeExtra'
    'due all'      = 'Show-JkDueAll'
    'focus log'    = 'Show-JkFocusLog'
    'tidy undo'    = 'Undo-JkTidy'
    'space'        = 'Show-JkSpace'
    'space clean'  = 'Invoke-JkSpaceClean'
    'port'         = 'Invoke-JkPort'
    'focus'        = 'Start-JkFocus'
    'week'         = 'Show-JkDueWeek'
    'grade'        = 'Show-JkGrade'
    'grade set'    = 'Set-JkGrade'
    'repos'        = 'Invoke-JkRepos'
}

$script:JkActions = @{
    'due'    = @('add', 'done', 'undone', 'edit', 'rm', 'all', 'past', 'week', 'exams', 'courses', 'course', 'cal', 'ics', 'sync', 'remind', 'import', 'help')
    'todo'   = @('add', 'done', 'undo', 'rm', 'clear', 'edit', 'all', 'help')
    'class'  = @('week', 'list', 'next', 'pick', 'add', 'rm', 'import', 'help')
    'focus'  = @('25', '50', '15', 'status', 'stop', 'log', 'help')
    'remind' = @('list', 'now', 'cancel', 'install', 'uninstall', 'status', 'test', 'help')
    'grade'  = @('set', 'clear', 'add', 'target', 'help')
    'tidy'   = @('scan', 'apply', 'undo', 'dupes', 'old', 'help')
    'cp'     = @('new', 'test', 'run', 'add', 'stress', 'open', 'clean', 'help')
    'config' = @('set', 'reset', 'edit', 'path', 'help')
    'setup'  = @('install', 'uninstall', 'status', 'help')
    'speed'  = @('fix', 'undo', 'help')
    'backup' = @('list', 'restore', 'mirror')
    'plan'   = @('start', 'help')
    'jobs'   = @('todo', 'skipped', 'edit', 'path', 'help')
    'space'  = @('clean', 'help')
    'port'   = @()
    'go'     = @()
    'find'   = @()
    'recent' = @()
    'help'   = @()
}

function Get-JkCompletions {
    param([string]$Word, [string[]]$Tokens)
    $mk = { param($text, $list, $tip) [System.Management.Automation.CompletionResult]::new($text, $list, 'ParameterValue', $tip) }
    $idx = $Tokens.Count
    if ($Word) { $idx = $Tokens.Count - 1 }
    if ($idx -le 1) {
        return $script:JkCommands.Keys | Where-Object { $_ -like "$Word*" } | ForEach-Object { & $mk $_ $_ $script:JkCommands[$_].Desc }
    }
    $cmd = Resolve-JkCommand $Tokens[1]
    if (-not $cmd) { return }
    $action = ''
    if ($idx -ge 3) { $action = ([string]$Tokens[2]).ToLower() }

    if ($Word.StartsWith('-')) {
        $key = $cmd
        if ($action -and $script:JkParamTargets.ContainsKey("$cmd $action")) { $key = "$cmd $action" }
        $fn = $script:JkParamTargets[$key]
        if (-not $fn) { return }
        $fi = Get-Item "function:$fn" -ErrorAction SilentlyContinue
        if (-not $fi) { return }
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters
        return $fi.Parameters.Keys | Where-Object { $common -notcontains $_ -and "-$_" -like "$Word*" } | ForEach-Object { & $mk "-$_" "-$_" $_ }
    }

    # PowerShell never routes "-<Tab>" on a param-less function to a custom completer, so the
    # parameter names are offered on an empty <Tab> instead, and values after a -Param.
    $key = $cmd
    if ($action -and $script:JkParamTargets.ContainsKey("$cmd $action")) { $key = "$cmd $action" }
    $targetFn = $script:JkParamTargets[$key]
    $prevTok = ''
    if ($Word) { if ($Tokens.Count -ge 2) { $prevTok = [string]$Tokens[-2] } } elseif ($Tokens.Count) { $prevTok = [string]$Tokens[-1] }
    if ($prevTok.StartsWith('-') -and $targetFn) {
        $fi = Get-Item "function:$targetFn" -ErrorAction SilentlyContinue
        $pname = $prevTok.TrimStart('-')
        $pm = $null
        if ($fi) { $pm = @($fi.Parameters.Values | Where-Object { $_.Name -like "$pname*" -or @($_.Aliases) -contains $pname })[0] }
        if ($pm -and $pm.ParameterType -ne [switch]) {
            $set = @($pm.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | ForEach-Object { $_.ValidValues })
            if ($pm.Name -eq 'Course') { $set = @((Get-JkDueData).courses | ForEach-Object { [string]$_.key }) }
            $set = @($set | Where-Object { $_ })
            if ($set.Count) { return $set | Where-Object { $_ -like "$Word*" } | ForEach-Object { & $mk $_ $_ $_ } }
            return
        }
    }

    # jk find -o <Tab>: the numbered results of the last search, each showing its file name
    if ($cmd -eq 'find' -and $prevTok -match '^-(o|e|c|p|open|explorer|code|print)$') {
        $n = 0
        return @(foreach ($p in @(Get-JkFindLast)) { $n++; if ("$n" -like "$Word*") { & $mk "$n" "$n  $(Split-Path $p -Leaf)" $p } })
    }

    $vals = @()
    if ($idx -eq 2) {
        if ($cmd -eq 'help') { $vals = @($script:JkCommands.Keys) }
        elseif ($cmd -eq 'go') { $vals = @(Get-JkGoCandidates | ForEach-Object { $_.Alias }) }
        elseif ($cmd -eq 'config') { $vals = @($script:JkActions['config']) + @($script:JkConfigDefaults.Keys) }
        elseif ($cmd -eq 'grade' -or $cmd -eq 'due') {
            $vals = @($script:JkActions[$cmd]) + @((Get-JkDueData).courses | ForEach-Object { [string]$_.key })
        }
        elseif ($script:JkActions.ContainsKey($cmd)) { $vals = @($script:JkActions[$cmd]) }
    } elseif ($idx -ge 3) {
        if ($cmd -eq 'due' -and $action -match '^(done|undone|edit|rm|x)$') {
            $data = Get-JkDueData
            $cmap = Get-JkCourseMap $data
            $now = Get-JkNow
            # upcoming soonest-first, then the recently passed ones
            $evs = @($data.events | Where-Object { ($action -eq 'undone') -eq [bool]$_.done } | Sort-Object @{ Expression = { if ((Get-JkEventDue $_) -ge $now) { 0 } else { 1 } } }, @{ Expression = { [Math]::Abs(((Get-JkEventDue $_) - $now).TotalHours) } } | Select-Object -First 30)
            return $evs | Where-Object { "$($_.id)" -like "$Word*" } | ForEach-Object {
                $tip = "#$($_.id)  $(Get-JkCourseLabel $_ $cmap)  $($_.title)  ($($_.date))"
                & $mk "$($_.id)" $tip $tip
            }
        }
        if ($cmd -eq 'class' -and $action -match '^(rm|remove|del)$') {
            $cd = Get-JkClassData
            return @($cd.items) | Where-Object { "$($_.id)" -like "$Word*" } | ForEach-Object {
                $tip = "#$($_.id)  $($_.course) $($_.kind)  $(@($_.days) -join ' ')  $($_.start)-$($_.end)  $($_.room)"
                & $mk "$($_.id)" $tip $tip
            }
        }
        if (($cmd -eq 'due' -and $action -eq 'add' -and $idx -eq 3) -or ($cmd -eq 'class' -and $action -eq 'add' -and $idx -eq 3) -or ($cmd -eq 'grade' -and $idx -eq 3 -and $action -ne 'set')) {
            $vals = @((Get-JkDueData).courses | ForEach-Object { [string]$_.key })
        }
        if ($cmd -eq 'grade' -and $action -eq 'set' -and $idx -eq 3) {
            $data = Get-JkDueData
            $cmap = Get-JkCourseMap $data
            return @($data.events | Where-Object { $_.weight -and $_.weight -ne '0%' }) | Where-Object { "$($_.id)" -like "$Word*" } | ForEach-Object {
                $tip = "#$($_.id)  $(Get-JkCourseLabel $_ $cmap)  $($_.title)  ($($_.weight))"
                & $mk "$($_.id)" $tip $tip
            }
        }
        if ($cmd -eq 'todo' -and $action -match '^(done|undo|rm|edit)$') {
            $t = Get-JkTodoData
            return @($t.items | Where-Object { ($action -eq 'undo') -eq [bool]$_.done }) | Where-Object { "$($_.id)" -like "$Word*" } | ForEach-Object { & $mk "$($_.id)" "$($_.id)  $($_.text)" $_.text }
        }
        if ($cmd -eq 'config' -and $action -eq 'set' -and $idx -eq 3) { $vals = @($script:JkConfigDefaults.Keys) }
        if ($cmd -eq 'remind' -and $action -eq 'cancel') { $vals = @(Get-JkReminderList | ForEach-Object { "$($_.id)" }) }
    }
    $out = @($vals | Where-Object { $_ -like "$Word*" } | Select-Object -Unique | ForEach-Object { & $mk $_ $_ $_ })
    if (-not $Word -and $idx -ge 2 -and $targetFn -and ($idx -ge 3 -or $out.Count -eq 0)) {
        $fi = Get-Item "function:$targetFn" -ErrorAction SilentlyContinue
        if ($fi) {
            $common = [System.Management.Automation.PSCmdlet]::CommonParameters
            $positional = @($fi.Parameters.Values | Where-Object { $_.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Position -ge 0 } } | ForEach-Object { $_.Name })
            $out += @($fi.Parameters.Keys | Where-Object { $common -notcontains $_ -and $positional -notcontains $_ } | ForEach-Object { & $mk "-$_" "-$_" "option -$_" })
        }
    }
    $out
}

# Entry point for both this module's completer and the lightweight one in the profile hook
# (which imports the module on the first <Tab> so new shells start fast).
function Invoke-JkCompleter($WordToComplete, $CommandAst, $CursorPosition) {
    $tokens = @($CommandAst.CommandElements | Where-Object { $_.Extent.StartOffset -lt $CursorPosition } | ForEach-Object { $_.Extent.Text.Trim('"', "'") })
    if ($tokens.Count -gt 0 -and $tokens[0] -eq 'j') { $tokens = @('jk', 'go') + @($tokens | Select-Object -Skip 1) }
    try { Get-JkCompletions -Word $WordToComplete -Tokens $tokens } catch { }
}

Register-ArgumentCompleter -Native -CommandName 'jk', 'j' -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    Invoke-JkCompleter $wordToComplete $commandAst $cursorPosition
}

Export-ModuleMember -Function jk, j
