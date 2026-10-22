# jk.psm1 - loads the toolkit and defines the `jk` entry point (plus `j`, a shortcut for `jk go`).

foreach ($lib in 'core', 'due', 'todo', 'focus', 'remind', 'grade', 'tidy', 'cp', 'go', 'sys', 'repos', 'speed', 'dash', 'help', 'setup') {
    $f = Join-Path $PSScriptRoot "lib\$lib.ps1"
    if (Test-Path -LiteralPath $f) { . $f }
}

# name -> handler, aliases, one-line description (drives dispatch, `jk help` and tab completion)
$script:JkCommands = [ordered]@{
    'due'    = @{ Fn = 'Invoke-JkDue'; Aliases = @('d', 'deadlines'); Desc = 'course deadlines: upcoming, add, done, week grid, calendar, .ics, reminders' }
    'week'   = @{ Fn = 'Show-JkDueWeek'; Aliases = @('wk'); Desc = 'the next two weeks as a Mon-Sun grid (same as jk due week)' }
    'exams'  = @{ Fn = 'Show-JkExams'; Aliases = @('exam', 'midterms'); Desc = 'every remaining exam with a countdown (same as jk due exams)' }
    'todo'   = @{ Fn = 'Invoke-JkTodo'; Aliases = @('t', 'todos'); Desc = 'quick personal to-do list' }
    'focus'  = @{ Fn = 'Invoke-JkFocus'; Aliases = @('f', 'pomo', 'pomodoro'); Desc = 'focus timer with a popup when time is up, plus weekly stats' }
    'in'     = @{ Fn = 'Invoke-JkRemindIn'; Aliases = @(); Desc = 'remind me in a while:  jk in 20m "take laundry out"' }
    'at'     = @{ Fn = 'Invoke-JkRemindAt'; Aliases = @(); Desc = 'remind me at a time:   jk at 3:30pm "call home"' }
    'remind' = @{ Fn = 'Invoke-JkRemind'; Aliases = @('reminders'); Desc = 'list/cancel reminders; install the daily deadline check' }
    'grade'  = @{ Fn = 'Invoke-JkGrade'; Aliases = @('g', 'grades', 'marks'); Desc = 'record marks, see your running average and what you need on the final' }
    'tidy'   = @{ Fn = 'Invoke-JkTidy'; Aliases = @('clean', 'downloads'); Desc = 'sort the Downloads folder into categories (dry run first, undoable)' }
    'cp'     = @{ Fn = 'Invoke-JkCp'; Aliases = @('contest'); Desc = 'competitive programming: new problem, compile+test samples, stress test' }
    'go'     = @{ Fn = 'Invoke-JkGo'; Aliases = @('cd', 'jump'); Desc = 'jump to a folder by fuzzy name (also: j <name>)' }
    'mark'   = @{ Fn = 'Invoke-JkMark'; Aliases = @('bookmark'); Desc = 'bookmark the current folder for jk go' }
    'repos'  = @{ Fn = 'Invoke-JkRepos'; Aliases = @('git'); Desc = 'status of every git repo on the Desktop: dirty, ahead, behind' }
    'sys'    = @{ Fn = 'Invoke-JkSys'; Aliases = @('system', 'stats'); Desc = 'CPU, RAM, disks, battery, network, memory hogs' }
    'port'   = @{ Fn = 'Invoke-JkPort'; Aliases = @('ports'); Desc = 'what is listening on which port; free a port with -Kill' }
    'speed'  = @{ Fn = 'Invoke-JkSpeed'; Aliases = @('startup', 'slow'); Desc = 'why new terminals are slow; jk speed fix makes the conda hook instant' }
    'brief'  = @{ Fn = 'Show-JkBrief'; Aliases = @(); Desc = 'one-line summary (shown when PowerShell starts)' }
    'config' = @{ Fn = 'Invoke-JkConfig'; Aliases = @('cfg', 'settings'); Desc = 'show or change settings' }
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
    $script:JkUseColor = Test-JkColor
    $script:JkConfigCache = $null
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
    'due week'     = 'Show-JkDueWeek'
    'due course'   = 'Set-JkCourse'
    'todo add'     = 'Add-JkTodo'
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
    'mark'         = 'Invoke-JkMark'
    'sys'          = 'Invoke-JkSys'
    'grade add'    = 'Add-JkGradeExtra'
    'due all'      = 'Show-JkDueAll'
    'focus log'    = 'Show-JkFocusLog'
    'tidy undo'    = 'Undo-JkTidy'
    'port'         = 'Invoke-JkPort'
    'focus'        = 'Start-JkFocus'
    'week'         = 'Show-JkDueWeek'
    'grade'        = 'Show-JkGrade'
    'grade set'    = 'Set-JkGrade'
    'repos'        = 'Invoke-JkRepos'
}

$script:JkActions = @{
    'due'    = @('add', 'done', 'undone', 'edit', 'rm', 'all', 'past', 'week', 'exams', 'courses', 'course', 'cal', 'ics', 'remind', 'import', 'help')
    'todo'   = @('add', 'done', 'undo', 'rm', 'clear', 'edit', 'all', 'help')
    'focus'  = @('25', '50', '15', 'status', 'stop', 'log', 'help')
    'remind' = @('list', 'cancel', 'install', 'uninstall', 'status', 'test', 'help')
    'grade'  = @('set', 'clear', 'target', 'help')
    'tidy'   = @('scan', 'apply', 'undo', 'dupes', 'old', 'help')
    'cp'     = @('new', 'test', 'run', 'add', 'stress', 'open', 'clean', 'help')
    'config' = @('set', 'reset', 'edit', 'path')
    'setup'  = @('install', 'uninstall', 'status')
    'speed'  = @('fix', 'undo')
    'port'   = @()
    'go'     = @()
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
        if (($cmd -eq 'due' -and $action -eq 'add' -and $idx -eq 3) -or ($cmd -eq 'grade' -and $idx -eq 3 -and $action -ne 'set')) {
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
