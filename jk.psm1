# jk.psm1 - loads the toolkit and defines the `jk` entry point (plus `j`, a shortcut for `jk go`).

foreach ($lib in 'core', 'due', 'sync', 'classes', 'todo', 'focus', 'papers', 'remind', 'grade', 'tidy', 'cp', 'go', 'find', 'grep', 'clip', 'shots', 'pdf', 'sys', 'net', 'weather', 'stocks', 'clock', 'course', 'next', 'repos', 'speed', 'space', 'review', 'plan', 'jobs', 'dash', 'help', 'setup') {
    $f = Join-Path $PSScriptRoot "lib\$lib.ps1"
    if (Test-Path -LiteralPath $f) { . $f }
}

# name -> handler, aliases, one-line description (drives dispatch, `jk help` and tab completion)
$script:JkCommands = [ordered]@{
    'due'    = @{ Fn = 'Invoke-JkDue'; Aliases = @('d', 'deadlines'); Desc = 'course deadlines: upcoming, add, done, week grid, calendar, .ics, reminders' }
    'class'  = @{ Fn = 'Invoke-JkClass'; Aliases = @('classes', 'cls', 'timetable', 'schedule', 'sched'); Desc = 'class schedule: what is on today, the next class, a weekly timetable' }
    'week'   = @{ Fn = 'Show-JkDueWeek'; Aliases = @('wk', 'w'); Desc = 'the next two weeks as a Mon-Sun grid (same as jk due week)' }
    'exams'  = @{ Fn = 'Invoke-JkExams'; Aliases = @('exam', 'midterms'); Desc = 'every remaining exam with a countdown; jk exam cs370 for one exam on a screen' }
    'plan'   = @{ Fn = 'Invoke-JkPlan'; Aliases = @('study'); Desc = 'split today''s study time across upcoming exams and assignments; jk plan week, jk plan start' }
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
    'grep'   = @{ Fn = 'Invoke-JkGrep'; Aliases = @('inside', 'lookup', 'where'); Desc = 'words inside your course files: lecture PDFs page by page, slides, notes, notebooks; -o opens at the page' }
    'clip'   = @{ Fn = 'Invoke-JkClip'; Aliases = @('clipboard', 'cb'); Desc = 'clipboard text: word count; unwrap lines copied from a PDF; drop formatting' }
    'recent' = @{ Fn = 'Invoke-JkRecent'; Aliases = @('changed', 'latest'); Desc = 'files you changed in the last 2 days (or N), newest first; jk find -o 1 opens one' }
    'repos'  = @{ Fn = 'Invoke-JkRepos'; Aliases = @('git'); Desc = 'status of every git repo on the Desktop: dirty, ahead, behind' }
    'sys'    = @{ Fn = 'Invoke-JkSys'; Aliases = @('system', 'stats'); Desc = 'CPU, RAM, disks, battery, network, memory hogs' }
    'pdf'    = @{ Fn = 'Invoke-JkPdf'; Aliases = @('topdf', 'scan'); Desc = 'photos of handwritten work (and PDFs) into one PDF for LEARN or Crowdmark: upright, a page each' }
    'shots'  = @{ Fn = 'Invoke-JkShots'; Aliases = @('screenshots', 'shot'); Desc = 'the Screenshots folder: per month, the newest to open, file the rest into month folders' }
    'next'   = @{ Fn = 'Show-JkNext'; Aliases = @('now', 'what'); Desc = 'the one thing to do now, and what follows: an exam, a class, work due tonight, study' }
    'time'   = @{ Fn = 'Invoke-JkTime'; Aliases = @('clock', 'tz', 'world'); Desc = 'the time where your people are, 8pm beijing in your time and back, when you are both up to call' }
    'weather' = @{ Fn = 'Invoke-JkWeather'; Aliases = @('wx', 'forecast', 'rain'); Desc = 'the forecast read for you: rain or snow from when, how cold it feels, the days ahead, at your exam' }
    'stocks' = @{ Fn = 'Invoke-JkStocks'; Aliases = @('stock', 'market', 'ticker', 'quote'); Desc = 'your watchlist at the US open: the day, the weeks, a likely range for the close and how often such ranges held' }
    'net'    = @{ Fn = 'Invoke-JkNet'; Aliases = @('wifi', 'internet', 'online'); Desc = 'is it the Wi-Fi or the internet? address, router, internet, DNS and web checked in order' }
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

# Words people type for something jk has under another name: jk today is the dashboard.
$script:JkCommandWords = [ordered]@{
    'jk'           = @('today', 'dash', 'dashboard', 'home', 'overview', 'summary')
    'jk due 2'     = @('tomorrow', 'tmrw', 'tmr')
    'jk grade'     = @('gpa', 'avg', 'average', 'score', 'scores')
    'jk exams'     = @('final', 'finals', 'quiz', 'quizzes', 'test', 'tests', 'midterm')
    'jk focus'     = @('timer', 'study-timer', 'tomato')
    'jk due cal'   = @('cal', 'calendar', 'ics')
    'jk todo'      = @('task', 'tasks', 'list')
    'jk in'        = @('alarm', 'remindme', 'later')
    'jk plan week' = @('checklist', 'routine')
}

# What an unknown first word was probably meant to be: a word jk knows by another name, or a
# command, alias or course one or two typos away (two only when one of the words has 5 letters).
# Up to three, the closest first; @() when nothing is near.
function Get-JkCommandGuess([string]$Word) {
    $w = $Word.ToLowerInvariant()
    if (-not $w) { return @() }
    foreach ($k in $script:JkCommandWords.Keys) { if ($script:JkCommandWords[$k] -contains $w) { return @($(if ($k -eq 'jk') { 'jk (the dashboard)' } else { $k })) } }
    $pool = [ordered]@{}
    foreach ($k in $script:JkCommands.Keys) {
        if (-not $pool.Contains($k)) { $pool[$k] = "jk $k" }
        foreach ($al in @($script:JkCommands[$k].Aliases)) { if ($al -match '^[a-z]{2,}$' -and -not $pool.Contains($al)) { $pool[$al] = "jk $k" } }
    }
    foreach ($k in $script:JkCommandWords.Keys) { foreach ($x in $script:JkCommandWords[$k]) { if (-not $pool.Contains($x)) { $pool[$x] = $k } } }
    try {
        $subj = @{}
        foreach ($c in @((Get-JkDueData -Cached).courses)) {
            $ck = Get-JkNormKey ([string]$c.code); if (-not $ck) { $ck = [string]$c.key }
            if ($ck -and -not $pool.Contains($ck)) { $pool[$ck] = "jk $ck" }
            # "health" alone is HEALTH 105 when no other course starts with it (jk health works)
            if ($ck -match '^([a-z]{4,})\d') { $subj[$Matches[1]] = @($subj[$Matches[1]]) + $ck }
        }
        foreach ($s in $subj.Keys) { if (@($subj[$s] | Where-Object { $_ }).Count -eq 1 -and -not $pool.Contains($s)) { $pool[$s] = "jk $s" } }
    } catch { }
    if ($w.Length -lt 2) { return @() }
    $i = 0
    $hits = foreach ($cand in $pool.Keys) {
        $i++
        $d = Get-JkEditDistance $w $cand
        # "gr" is one letter from "go" and from "grep": too short to say which
        if ($d -eq 0) { return @() }
        $max = $(if ([Math]::Max($w.Length, $cand.Length) -ge 5) { 2 } else { 1 })
        if ($d -le $max -and $d -lt $cand.Length - 1) { [pscustomobject]@{ Shown = $pool[$cand]; D = $d; I = $i } }
    }
    # the closest first; on a tie, commands before aliases before other words (the pool's order)
    @($hits | Sort-Object D, I | ForEach-Object { if ($_.Shown -eq 'jk') { 'jk (the dashboard)' } else { $_.Shown } } | Select-Object -Unique -First 3)
}

function jk {
    # jk reports through its own messages; git and compilers it runs along the way must not leave
    # their exit codes behind for the prompt or a calling script
    $exitCode = $global:LASTEXITCODE
    try { Invoke-JkCommand @args }
    finally { if ($global:LASTEXITCODE -ne $exitCode) { $global:LASTEXITCODE = $exitCode } }
}

# What a command line names: @{ Command } or @{ Course = (Resolve-JkCourseWords) }, or $null. A
# course (jk cs341, jk co 367) is that course on a screen. An exact command or alias always wins;
# a word that plainly is a course wins over a command it merely starts ("co" -> config); a looser
# match ("health") only when no command takes the word. Tab completion asks the same question.
function Resolve-JkRoute([string[]]$Words) {
    $a = @($Words)
    if (-not $a.Count) { return $null }
    $first = ([string]$a[0]).ToLower()
    $exact = $script:JkCommands.Contains($first) -or @($script:JkCommands.Values | Where-Object { $_.Aliases -contains $first }).Count
    $courseish = $first -match '^[a-z]{2,8}\d{2,3}[a-z]?$' -or ($a.Count -ge 2 -and $first -match '^[a-z]{2,8}$' -and [string]$a[1] -match '^\d{2,3}[A-Za-z]?$')
    $name = $null
    if ($exact -or -not $courseish) { $name = Resolve-JkCommand $first }
    if ($name) { return @{ Command = $name } }
    $cw = $null
    try { $cw = Resolve-JkCourseWords $a } catch { }
    if ($cw) { return @{ Course = $cw } }
    if ($courseish) { $name = Resolve-JkCommand $first; if ($name) { return @{ Command = $name } } }
    $null
}

# What PowerShell says when a word does not fit a command, in words that mean something here. Every
# command goes through this, so no command has to guard each of its options against it.
function Format-JkErrorText([string]$Message, [string]$Command = '') {
    $short = { param([string]$v) if ($v.Length -gt 30) { $v.Substring(0, 30) + $script:G.ell } else { $v } }
    $help = $(if ($Command) { " (jk help $Command)" } else { '' })
    $number = 'to type "System\.(?:Int32|Int64|Double)"'
    # a number, only too big ("jk in 99999999999" works it out in seconds first): not "expected a number"
    if ($Message -match 'Value was either too large or too small for an? \w+') { return 'that number is out of range' }
    if ($Message -match "(?s)^Cannot process argument transformation on parameter '(\w+)'\. Cannot convert value `"(.*)`" $number") { return "expected a number for $($Matches[1].ToLower()), not '$(& $short $Matches[2])'" }
    if ($Message -match "(?s)^Cannot convert value `"(.*)`" $number") { return "expected a number, not '$(& $short $Matches[1])'" }
    if ($Message -match "(?s)^A positional parameter cannot be found that accepts argument '(.*)'\.") { return "unexpected word '$(& $short $Matches[1])'$help" }
    if ($Message -match "^A parameter cannot be found that matches parameter name '(.*)'\.") { return "there is no -$($Matches[1]) option$help" }
    if ($Message -match "^Missing an argument for parameter '(\w+)'") { return "-$($Matches[1]) needs a value$help" }
    if ($Message -match "^Parameter cannot be processed because the parameter name '(\w+)' is ambiguous") { return "-$($Matches[1]) could mean more than one option$help" }
    if ($Message -match "^Cannot validate argument on parameter '(\w+)'\. The argument `".*`" does not belong to the set `"(.*)`" specified") {
        $param = $Matches[1]
        return "-$param takes $((@($Matches[2] -split '[;,]' | Where-Object { $_ })) -join ', ')"
    }
    if ($Message -match '^Cannot validate argument on parameter .*(minimum|maximum) allowed') { return 'that number is out of range' }
    $inner = $Message
    if ($Message -match '(?s)^Exception calling "[\w.]+" with "\d+" argument\(s\): "(.*)"\s*$') { $inner = $Matches[1] }
    if ($inner -match '(?i)out of (the )?range|un-representable') { return 'that number is out of range' }
    if ($inner -match "^Illegal characters in path|^The given path's format is not supported") { return 'that path has characters Windows does not allow (: * ? " < > |)' }
    $inner
}

function Invoke-JkCommand {
    $script:JkUseColor = Test-JkColor
    $script:JkConfigCache = $null
    $light = (Get-JkConfig 'theme') -eq 'light'
    if ($light -ne [bool]$script:JkLightTheme) { $script:JkLightTheme = $light; $script:PaintCache = @{} }
    $a = @($args)
    if ($a.Count -eq 0) {
        try { Show-JkDashboard } catch { if ($env:JK_DEBUG) { throw }; Write-Host (Paint 'red' ('  jk: ' + (Format-JkErrorText $_.Exception.Message))) }
        return
    }
    $route = Resolve-JkRoute ([string[]]$a)
    if ($route -and $route.Course) {
        try { if ($route.Course.Rest.Count) { Invoke-JkCourseAction $route.Course.Course $route.Course.Rest } else { Show-JkCourseBrief $route.Course.Course } }
        catch { if ($env:JK_DEBUG) { throw }; Write-Host (Paint 'red' ('  jk: ' + (Format-JkErrorText $_.Exception.Message))) }
        return
    }
    $name = $null; if ($route) { $name = $route.Command }
    if (-not $name) {
        $guess = @(Get-JkCommandGuess ([string]$a[0]))
        if ($guess.Count) { Write-Host (Paint 'red' "  jk: unknown command '$($a[0])'.") (Paint 'white' "Did you mean $(($guess | ForEach-Object { $_ }) -join ' or ')?") (Paint 'gray' "(jk help lists them all)") }
        else { Write-Host (Paint 'red' "  jk: unknown command '$($a[0])'.") (Paint 'gray' "Try 'jk help'.") }
        return
    }
    $rest = @()
    if ($a.Count -gt 1) { $rest = @($a[1..($a.Count - 1)]) }
    $fn = $script:JkCommands[$name].Fn
    try {
        & $fn @rest
    } catch {
        if ($env:JK_DEBUG) { throw }
        Write-Host (Paint 'red' ('  jk: ' + (Format-JkErrorText $_.Exception.Message $name)))
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
    'cp listen'    = 'Invoke-JkCpListen'
    'cp add'       = 'Add-JkCpTest'
    'go'           = 'Invoke-JkGo'
    'find'         = 'Invoke-JkFind'
    'grep'         = 'Invoke-JkGrep'
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
    'grade import' = 'Import-JkGrades'
    'repos'        = 'Invoke-JkRepos'
    'shots old'    = 'Invoke-JkShotsOld'
    'pdf'          = 'Invoke-JkPdf'
}

$script:JkActions = @{
    'due'    = @('add', 'done', 'undone', 'edit', 'rm', 'files', 'all', 'past', 'week', 'exams', 'courses', 'course', 'cal', 'ics', 'sync', 'remind', 'import', 'help')
    'todo'   = @('add', 'done', 'undo', 'rm', 'clear', 'edit', 'all', 'help')
    'class'  = @('week', 'list', 'next', 'pick', 'add', 'rm', 'import', 'help')
    'focus'  = @('25', '50', '15', 'status', 'stop', 'log', 'add', 'undo', 'help')
    'remind' = @('list', 'now', 'cancel', 'install', 'uninstall', 'status', 'test', 'help')
    'grade'  = @('fill', 'import', 'set', 'clear', 'add', 'target', 'pass', 'help')
    'tidy'   = @('scan', 'apply', 'undo', 'dupes', 'old', 'help')
    'cp'     = @('new', 'listen', 'test', 'run', 'add', 'stress', 'open', 'clean', 'help')
    'config' = @('set', 'reset', 'edit', 'path', 'help')
    'setup'  = @('install', 'uninstall', 'status', 'help')
    'speed'  = @('fix', 'undo', 'help')
    'backup' = @('list', 'restore', 'mirror')
    'plan'   = @('start', 'week', 'did', 'help')
    'jobs'   = @('todo', 'skipped', 'edit', 'path', 'help')
    'space'  = @('clean', 'help')
    'port'   = @()
    'net'    = @('speed', 'help')
    'weather' = @('set', 'off', 'help')
    'stocks' = @('add', 'rm', 'list', 'popup', 'help')
    'time'   = @('add', 'rm', 'off', 'help')
    'shots'  = @('find', 'file', 'old', 'forget', 'help')
    'pdf'    = @()
    'go'     = @()
    'find'   = @()
    'grep'   = @('all', 'help')
    'recent' = @()
    'clip'   = @('ocr', 'unwrap', 'count', 'plain', 'help')
    'help'   = @()
}

function Get-JkCompletions {
    param([string]$Word, [string[]]$Tokens)
    $mk = { param($text, $list, $tip) [System.Management.Automation.CompletionResult]::new($text, $list, 'ParameterValue', $tip) }
    $idx = $Tokens.Count
    if ($Word) { $idx = $Tokens.Count - 1 }
    if ($idx -le 1) {
        $cmds = @($script:JkCommands.Keys | Where-Object { $_ -like "$Word*" } | ForEach-Object { & $mk $_ $_ $script:JkCommands[$_].Desc })
        # this term's course codes too: jk cs341 is that course on a screen
        $courses = @()
        try {
            $courses = @(foreach ($c in @((Get-JkDueData -Cached).courses)) {
                    $k = Get-JkNormKey ([string]$c.code); if (-not $k) { $k = [string]$c.key }
                    if ($k -like "$Word*" -and -not $script:JkCommands.Contains($k)) { & $mk $k $k "$($c.code)$(if ($c.name) { " $($c.name)" }): the course on a screen" }
                })
        } catch { }
        return @($cmds + $courses)
    }
    # the words before the one being typed decide what it is
    $done = @($Tokens | Select-Object -Skip 1)
    if ($Word -and $done.Count) { $done = @($done | Select-Object -First ($done.Count - 1)) }
    $route = Resolve-JkRoute $done
    if ($route -and $route.Course) {
        # right after the course: what can follow it
        if ($route.Course.Rest.Count) { return }
        $acts = [ordered]@{ exam = 'its next exam on a screen'; grade = 'its marks and what the rest needs'; grep = 'words inside its PDFs, slides and notes'; due = 'its deadlines'; files = 'the files for one of its deadlines'; go = 'jump to its folder' }
        return @($acts.Keys | Where-Object { $_ -like "$Word*" } | ForEach-Object { & $mk $_ $_ $acts[$_] })
    }
    $cmd = $null; if ($route) { $cmd = $route.Command }
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
        return @(foreach ($p in @(Get-JkFindLast)) { $n++; $f = ($p -split "`t")[0]; if ("$n" -like "$Word*") { & $mk "$n" "$n  $(Split-Path $f -Leaf)" $f } })
    }

    $vals = @()
    if ($idx -eq 2) {
        if ($cmd -eq 'help') { $vals = @($script:JkCommands.Keys) }
        elseif ($cmd -eq 'go') { $vals = @(Get-JkGoCandidates | ForEach-Object { $_.Alias }) }
        elseif ($cmd -eq 'config') { $vals = @($script:JkActions['config']) + @($script:JkConfigDefaults.Keys) }
        elseif ($cmd -in 'grade', 'due', 'exams', 'grep') {
            $vals = @(@($script:JkActions[$cmd]) + @((Get-JkDueData).courses | ForEach-Object { [string]$_.key }) | Where-Object { $_ })
        }
        elseif ($script:JkActions.ContainsKey($cmd)) { $vals = @($script:JkActions[$cmd]) }
    } elseif ($idx -ge 3) {
        if ($cmd -eq 'due' -and $action -match '^(done|undone|edit|rm|x|files|work)$') {
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
