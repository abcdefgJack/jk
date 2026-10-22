# help.ps1 - `jk help` and `jk help <command>`.

$script:JkHelpTopics = @{
    'due' = @'
jk due                         deadlines in the next 14 days, grouped by day, with countdowns
jk due 30                      ... the next 30 days
jk due cs350                   everything for one course (past ones dimmed, done ones struck)
jk due all | past | exams      whole term | what's behind you | every remaining exam
jk due week                    two-week grid (Mon-Sun columns)
jk due add cs350 "A4 Paging" dec 2 8pm -Weight 10      add (date: dec 2, fri, tomorrow, +3, 2026-12-02)
jk due add cs341 "Midterm 3" nov 30 7pm -Exam -End 9pm
jk due done 23 | jk due done a2a                        mark done by id or by part of the title
jk due undone 23 | jk due rm 23
jk due edit 24 -Date oct 30 -Time 4:30pm -Note "room MC 2065"
jk due courses                 courses with open counts; jk due course cs350 -Color F87171 -Final "Dec 17 4pm"
jk due cal                     open a calendar web page generated from your data
jk due ics                     write an .ics file to import into Google Calendar / Outlook
jk due remind                  pop up anything due in the next 48h (the daily task does this)
jk due import <file.html>      import a calendar page that has COURSES/EVENTS arrays
Tab completion knows ids, so `jk due done <Tab>` cycles through upcoming items.
'@
    'class'  = @'
jk class                       today's classes (now / in 25m / done) and the next one
jk class week                  Mon-Fri timetable for this week (reading week and holidays left out)
jk class week -Date nov 2     another week
jk class add cs350 tue,thu 4pm-5:20pm "MC 1056"        add a weekly meeting (days: tue,thu  TTh  MWF  weekdays)
jk class add cs341 fri 2:30-3:20pm "MC 4060" -Kind TUT    tutorial / lab: -Kind TUT|LAB
jk class import                Quest > Class Schedule > List View: select all, copy, run this
jk class import page.txt       ... or from a saved copy. Midterm (TST) slots fill in deadline times.
jk class list | jk class rm 3 | jk class next
Classes run from the term start to the last day of classes unless -From / -To say otherwise.
'@
    'todo'   = @'
jk todo                        open items (soonest due first) and what you finished today
jk todo email the TA           add (anything that is not a sub-command becomes the text)
jk todo add buy ink -Due fri   add with a due date (fri, tomorrow 5pm, oct 30)
jk todo done 2 | undo 2 | rm 2 | edit 2 new text -Due mon
jk todo all                    include finished items
jk todo clear                  drop finished items and renumber
'@
    'focus'  = @'
jk focus                       start a 25-minute block (or show the running one)
jk focus 50 cs350 a2a          50 minutes, labelled - the label's course colours it
jk focus 1h30m reading         any length: 25, 25m, 1h, 1h30m, 1:30
jk focus stop                  end early (time so far is logged)
jk focus log                   last 7 days as a bar chart, totals by label, streak
A popup slides in when time is up, even if Windows notifications are off.
'@
    'remind' = @'
jk in 20m take the laundry out      popup in 20 minutes (20m, 1h30m, 90s, 45)
jk at 3:30pm call home              popup at a time today (or tomorrow if already past)
jk at tomorrow 9am submit form      also: fri 17:00, dec 3 10am
jk remind                           pending reminders + daily-task status
jk remind cancel 3
jk remind install                   morning brief popup (today's classes + deadlines within 48h) at remind.time
                                    (jk config set remind.time 7:45am) and on sign-in; re-arms reminders after a restart
jk remind uninstall | jk remind test | jk remind now
'@
    'grade'  = @'
jk grade                       every course: graded so far, average, and what you need on the rest
jk grade cs350                 one course in detail, with a "to finish with X you need Y" table
jk grade set 23 17/20          record a mark for deadline #23 (85, 85%, 17/20 all work)
jk grade clear 23
jk grade target cs350 85       default target is 80%
jk grade add cs350 "Participation" -Weight 5 -Score 100     parts that are not deadlines
Weights come from your deadlines; "best 6 of 8" in a note drops the lowest automatically.
'@
    'tidy'   = @'
jk tidy                        report on Downloads: categories, biggest files, duplicates, old installers
jk tidy apply                  move loose files into Installers\, PDFs\, Images\ ... (newer than 2 days stay)
jk tidy undo                   put the last batch back exactly where it was
jk tidy dupes [-Recycle]       find identical files (by content hash); -Recycle bins the extra copies
jk tidy old [-Days 90] [-Recycle]   installers/archives you probably do not need any more
jk tidy "C:\some\folder"       any other folder
Nothing is ever deleted permanently: -Recycle uses the Recycle Bin.
'@
    'cp'     = @'
jk cp new A                    make <cp.root>\A with main.cpp + 1.in/1.out, cd there, open editor
jk cp new A -Lang py|java|usaco   -Here  (create in the current folder instead)
jk cp add                      clipboard -> next N.in, then copy the expected output and press Enter
jk cp                          compile (cached) and run every *.in; diff with *.out / *.ans
jk cp -d                       debug build: _GLIBCXX_DEBUG bounds checks, -ftrapv overflow traps
jk cp -v                       also show stderr (dbg(...) output) for passing tests
jk cp -Timeout 5               per-test limit in seconds (default 3)
jk cp run                      compile and run interactively
jk cp stress                   main vs brute.cpp|py on inputs from gen.cpp|py <seed>; stops at the first mismatch
Compiled with -std=c++20 -O2 -Wall -DLOCAL and a 256 MB stack (deep recursion just works).
Floating-point answers match within 1e-6. Exit codes like 0xC0000005 are explained.
'@
    'go'     = @'
j co250                        jump to the best fuzzy match (also: jk go co250)
j co250/final                  then into a matching subfolder
j -                            back to where you were
j co250 -e | -c                open in Explorer | in your editor instead of cd-ing
jk go                          bookmarks, most-visited folders and everything j can match
jk mark [alias]                bookmark the current folder;  jk mark old -Remove
Candidates: bookmarks, Desktop folders (and course folders inside them), Documents,
Downloads, home, and every folder you have jumped to; frequent ones rank higher.
'@
    'sys'    = @'
jk sys                         CPU load, memory, every disk, battery, Wi-Fi/IP, apps using the most RAM
jk port                        listening ports with the owning app (dev ports highlighted)
jk port 8080                   who is on 8080;   jk port 8080 -Kill   frees it
'@
    'repos'  = @'
jk repos                       every git repo under the Desktop: branch, changes, unpushed/behind, last commit
jk repos -Fetch                fetch first so "behind" is current
jk repos -Root C:\code         another root (or: jk config set repos.roots "C:\a;C:\b")
'@
    'config' = @'
jk config                      show all settings
jk config set editor cursor    editor used by jk cp / j -c  (code, cursor, notepad...)
jk config set name Jack        name on the dashboard
jk config set notify popup     auto | popup | toast | off
jk config set banner off       hide the one-line summary when PowerShell starts
jk config set cp.root D:\cp    where jk cp new puts problems;  cp.lang cpp|py|java;  cp.std c++17
jk config set tidy.minAge 7    keep files newer than 7 days in place
jk config reset <key> | jk config edit | jk config path
'@
    'space'  = @'
jk space                       sizes of Downloads, Recycle Bin, temp, conda/pip/npm caches, Gradle, Maven,
                               Docker's disk, browser/editor caches and every node_modules under the Desktop
jk space -NoNodeModules       skip the node_modules search (faster)
jk space clean temp           delete temp files older than 7 days (-Days 30 to keep more)
jk space clean conda          conda clean --all   (also: pip, npm)
The report never deletes anything; each row names the right tool to free that space.
'@
    'speed'  = @'
jk speed                       time a new PowerShell with and without your profiles, and each profile file
jk speed fix                   replace the conda init hook (about 2 s per terminal) with an instant equivalent:
                               same PATH entries and CONDA_* variables, conda loads on first use.
                               Verifies python and the active env are unchanged, else rolls back.
jk speed undo                  restore the original conda block from the backup
'@
    'setup'  = @'
jk setup install               profile banner + daily reminder task + calendar page (safe to re-run)
jk setup status                what is installed
jk setup uninstall             remove the profile lines and the scheduled task (your data stays in ~\.jk)
jk doctor                      check compilers, module path, notifications, task and profile
'@
}
$script:JkHelpTopics['in'] = $script:JkHelpTopics['remind']
$script:JkHelpTopics['week'] = $script:JkHelpTopics['due']
$script:JkHelpTopics['review'] = "jk review                      the last 7 days (deadlines and to-dos finished, focus per course, what slipped)`n                               and the next 7 (load per day, which course has the most marks due)`njk review -Days 14             a longer window"
$script:JkHelpTopics['exams'] = $script:JkHelpTopics['due']
$script:JkHelpTopics['at'] = $script:JkHelpTopics['remind']
$script:JkHelpTopics['port'] = $script:JkHelpTopics['sys']
$script:JkHelpTopics['mark'] = $script:JkHelpTopics['go']
$script:JkHelpTopics['doctor'] = $script:JkHelpTopics['setup']

function Write-JkHelpBlock([string]$Text) {
    foreach ($l in ($Text -split "`r?`n")) {
        if ($l -match '^(jk [^ ].*?|j [^ ].*?)(\s{2,})(.*)$') {
            Say ('  ' + (Paint 'cyan' $Matches[1]) + $Matches[2] + (Paint 'muted' $Matches[3]))
        } elseif ($l -match '^(jk |j )') {
            Say ('  ' + (Paint 'cyan' $l))
        } elseif ($l -match '^\s{8,}') {
            Say ('  ' + (Paint 'muted' $l))
        } else {
            Say ('  ' + (Paint 'gray' $l))
        }
    }
}

function Show-JkHelp {
    param([Parameter(Position = 0)][string]$Topic)
    if ($Topic) {
        $name = Resolve-JkCommand $Topic
        if (-not $name) { $name = $Topic.ToLower() }
        $text = $script:JkHelpTopics[$name]
        if (-not $text) { throw "no help for '$Topic'" }
        Write-JkHeader "jk $name" ($script:JkCommands[$name].Desc)
        Write-JkHelpBlock $text
        return
    }
    Write-JkHeader 'jk' "v$((Get-Module jk).Version) $($script:G.dot) your command-line sidekick"
    $groups = [ordered]@{
        'School'   = @('class', 'due', 'week', 'exams', 'grade', 'todo', 'review')
        'Time'     = @('focus', 'in', 'at', 'remind')
        'Code'     = @('cp', 'repos', 'port')
        'Machine'  = @('tidy', 'space', 'sys', 'go', 'mark', 'speed')
        'jk'       = @('brief', 'config', 'doctor', 'setup', 'help')
    }
    foreach ($g in $groups.Keys) {
        Say (' ' + (Paint 'bold white' $g))
        foreach ($c in $groups[$g]) {
            $al = @($script:JkCommands[$c].Aliases | Where-Object { $_ -notmatch '^-' })
            $alTxt = ''
            if ($al.Count) { $alTxt = Paint 'gray' (' (' + ($al -join ', ') + ')') }
            Say ('   ' + (Paint 'cyan' (Fit "jk $c" 12)) + (Paint 'muted' $script:JkCommands[$c].Desc) + $alTxt)
        }
        Say ''
    }
    Say (Paint 'gray' '  jk                dashboard: next exam, this week, to-dos, focus, machine')
    Say (Paint 'gray' '  jk help <command> examples for one command   |   Tab completes commands, ids and options')
}
