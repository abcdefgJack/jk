# help.ps1 - `jk help` and `jk help <command>`.

$script:JkHelpTopics = @{
    'due' = @'
jk due                         deadlines in the next 14 days, grouped by day, with countdowns
jk due 30                      ... the next 30 days
jk due cs350                   everything for one course (past ones dimmed, done ones struck)
jk due all | past | exams      whole term | what's behind you | every remaining exam
jk exam cs370 [midterm]        one exam on a screen: when, worth, what you need on it, prep planned,
                               what lands the week before, its files in the course folder (jk find -o 1)
jk due week                    two-week grid (Mon-Sun columns)
jk due add cs350 "A4 Paging" dec 2 8pm -Weight 10      add (date: dec 2, fri, tomorrow, in 3 days, tonight, 8pm, 2026-12-02)
jk due add cs341 Midterm 3 nov 30 7-9pm -Exam          quotes optional; 7-9pm sets the end time
jk due done 23 | jk due done a2a                        mark done by id or by part of the title
jk due done cs341 midterm 2                             or course and title words (a1 = Assignment 1)
jk due undone 23 | jk due rm 23
jk due files 24                the files in its course folder named after it (A2.tex, A2\..., a2a.pdf)
jk due edit 24 -Date oct 30 -Time 4:30pm -Note "room MC 2065"
jk due courses                 courses with open counts; jk due course cs350 -Color F87171 -Final "Dec 17 4pm"
jk due cal                     open a calendar web page generated from your data
jk due ics                     write an .ics file to import into Google Calendar / Outlook
jk due remind                  pop up anything due in the next 48h (the daily task does this)
jk due import <file.html>      import a calendar page that has COURSES/EVENTS arrays
jk due sync "<feed link>"      pull deadlines from LEARN (Calendar > Subscribe) or any .ics link/file;
                               re-syncs update moved dates, keep done marks; the link is remembered
jk due sync                    sync again (the morning task does this daily once a link is saved);
                               the first time, it opens LEARN's calendar, then takes the link you copy
                               from Subscribe off the clipboard (or a paste)
Tab completion knows ids, so `jk due done <Tab>` cycles through upcoming items.
'@
    'class'  = @'
jk class                       today's classes (now / in 25m / done) and the next one
jk class week                  Mon-Fri timetable for this week (reading week and holidays left out)
jk class week -Date nov 2      another week
jk class add cs350 tue thu 4pm-5:20pm MC 1056        add a weekly meeting (days: tue thu  tth  MWF  weekdays)
jk class add cs341 fri 230-320pm MC 4060 TUT    tutorial / lab: TUT or LAB after the room (or -Kind TUT)
jk class pick                  every section of your courses (from the outlines), then asks which are yours
                               (type 3 or 003 per course; Enter skips)
jk class pick cs350            just that course: its sections, then which one is yours
jk class pick cs341 003 cs350 002 cs370 001     adds them with days, times and rooms; warns on clashes
jk class import                Quest > Class Schedule > List View: select all, copy, run this
jk class import page.txt       ... or from a saved copy. Midterm (TST) slots fill in deadline times.
                               Also reads TTh / MoWe day codes and outline.uwaterloo.ca rows like
                               CS 350 001 [LEC] Monday, Wednesday - 04:00PM - 05:20PM MC 1056
jk class list | jk class rm 3 | jk class next
Classes run from the term start to the last day of classes unless -From / -To say otherwise.
'@
    'todo'   = @'
jk todo                        open items (soonest due first) and what you finished today
jk todo email the TA           add (anything that is not a sub-command becomes the text)
jk todo pay rent nov 1         a date at the end is the due date (by fri, at 7pm, tomorrow, in 2 weeks);
                               quote the text to keep it as typed: jk todo "meet on sun"
jk todo add buy ink -Due fri   add with a due date (fri, tomorrow 5pm, oct 30); the morning popup lists it
                               that day, and keeps listing it as overdue until it is done
jk todo done 2 | undo 2 | rm 2 | edit 2 new text -Due mon
jk todo all                    include finished items
jk todo clear                  drop finished items and renumber
'@
    'focus'  = @'
jk focus                       start a 25-minute block (or show the running one)
jk focus 50 cs350 a2a          50 minutes, labelled - the label's course colours it
jk focus 1h30m reading         any length: 25, 25m, 1h, 1h30m, 1:30, for half an hour
jk focus stop                  end early (time so far is logged)
jk focus status                the running block: time left and label
jk focus log                   last 7 days as a bar chart, totals by label, streak
A popup slides in when time is up, even if Windows notifications are off.
'@
    'remind' = @'
jk in 20m take the laundry out      popup in 20 minutes (20m, 1h30, 2 hours, an hour, half an hour, 90s, 45)
jk at 3:30pm call home              popup at a time today (or tomorrow if already past)
jk at tomorrow 9am submit form      also: fri 17:00, dec 3 10am
jk remind | jk remind list          pending reminders + daily-task status
jk remind cancel 3
jk remind install                   morning brief popup (today's classes, deadlines within 48h, exams within 3 days) at remind.time
                                    (jk config set remind.time 7:45am) and on sign-in; re-arms reminders after a restart
jk remind uninstall | jk remind test | jk remind now
Same-day alerts: the morning task also sets a popup 2 hours before each deadline or appointment
that day (not 0% work or quiz openings; skipped if you mark it done first).
jk config set alert.before 90m   or   off
Class alerts: a popup 10 minutes before each class on your timetable (skips breaks and holidays).
jk config set alert.class 5m   or   off
'@
    'grade'  = @'
jk grade                       every course: graded so far, average, and what you need on the rest
jk grade cs350                 one course in detail, with a "to finish with X you need Y" table
jk grade fill                  go through every past graded item with no mark: type it, Enter skips
jk grade set 23 17/20          record a mark for deadline #23 (85, 85%, 17/20, 17 out of 20 all work)
jk grade cs341 midterm 1 72%   or name it by course and title words (a1 = Assignment 1, q2 = Quiz 2)
jk grade clear 23
jk grade target cs350 85       default target is 80%; jk grade target 85 changes it for every course
jk grade add cs350 "Participation" -Weight 5 -Score 100     parts that are not deadlines
Weights come from your deadlines; "best 6 of 8" in a note drops the lowest automatically.
'@
    'tidy'   = @'
jk tidy | jk tidy scan         report on Downloads: categories, biggest files, duplicates, old installers
jk tidy apply                  move loose files into Installers\, PDFs\, Images\ ... (newer than 2 days stay);
                               files named after a course (CS245-F25-A05.pdf, STAT_230_002_27.pdf) go to that
                               course's folder (Desktop\Waterloo course\CS245) instead; tidy.courses off to stop
jk tidy undo                   put the last batch back exactly where it was
jk tidy dupes [-Recycle]       find identical files (by content hash); -Recycle bins the extra copies
jk tidy old [-Days 90] [-Recycle]   installers/archives you probably do not need any more, and partial
                                    downloads nobody has touched for a week
  (both look at loose downloads and jk's category folders only, never inside unzipped programs or repos)
jk tidy "C:\some\folder"       any other folder
Nothing is ever deleted permanently: -Recycle uses the Recycle Bin.
'@
    'cp'     = @'
jk cp new A                    make <cp.root>\A with main.cpp + 1.in/1.out, cd there, open editor
jk cp new A -Lang py|java|usaco   -Here  (create in the current folder instead)
jk cp add                      clipboard -> next N.in, then copy the expected output and press Enter
jk cp | jk cp test             compile (cached) and run every *.in; diff with *.out / *.ans
                               (also in tests\ or test\, and old USACO data: I.1 with O.1)
jk cp -d                       debug build: _GLIBCXX_DEBUG bounds checks, -ftrapv overflow traps
jk cp -v                       also show stderr (dbg(...) output) for passing tests
jk cp -Timeout 5               per-test limit in seconds (default 3)
jk cp run                      compile and run interactively
jk cp open | jk cp clean       open the solution in your editor | delete the compiled cache (.jkcp)
jk cp stress                   main vs brute.cpp|py on inputs from gen.cpp|py <seed>; stops at the first mismatch
Compiled with -std=c++20 -O2 -Wall -DLOCAL and a 256 MB stack (deep recursion just works).
bits/stdc++.h is precompiled once (~4 s, ~150 MB in %LOCALAPPDATA%\jk), then compiles take ~0.6 s;
jk cp clean pch removes it.
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
    'find'   = @'
jk find co250 a3               files whose name or folders hold every word, best first
                               (Desktop, Documents and Downloads, walked live: new files show up at once)
jk find cs350 pdf              a word that is a file type keeps just that type
jk find -o 2                   open result 2 of the last search;  -e 2 shows it in Explorer, -c 2 your editor
                               (jk find -o <Tab> cycles through the results by name)
jk find a3 sol -o              open the best match straight away;  -p prints its path: cp (jk find a3 -p) .
jk find notes -All             up to 200 results (15 by default)
jk find lab -Root D:\school    somewhere else (or: jk config set find.roots "C:\a;D:\b")
jk recent                      files you changed in the last 2 days, newest first (jk recent 7, jk recent 0.5)
                               the numbers work with jk find -o / -e / -c / -p, like a search's
Skips hidden folders, links and dependency/build folders (node_modules, venv, bin, obj, build, dist, target).
'@
    'clip'   = @'
jk clip | jk clip count        what is on the clipboard: words (Chinese counted by character), characters, lines
jk clip unwrap                 text copied from a PDF: wrapped lines become paragraphs, "optimi-" + "zation" is
                               mended, bullets and blank lines stay; the result goes back on the clipboard
jk clip plain                  the same text with its formatting dropped, ready to paste anywhere
'@
    'sys'    = @'
jk sys                         CPU load, memory, every disk, battery, Wi-Fi/IP, apps using the most RAM
                               battery health: today's full charge against what it held new (from Windows'
                               battery report, read once and cached)
jk port                        listening ports with the owning app (dev ports highlighted); a database
                               other devices can reach is flagged with the setting that keeps it local
jk port 8080                   who is on 8080;   jk port 8080 -Kill   frees it
'@
    'shots'  = @'
jk shots                       the Screenshots folder (Win+PrtScn, Snipping Tool): count per month for a year,
                               the newest numbered (jk find -o 1 opens the latest)
jk shots file                  move screenshots from before this month into YYYY-MM folders beside them;
                               jk tidy undo puts them back
jk shots old                   those older than a year by year and size; -Months 6 to choose, -Recycle to
                               send them to the Recycle Bin (recoverable)
jk config set shots.path D:\Shots   another folder (default: Pictures\Screenshots)
'@
    'net'    = @'
jk net                         is it the Wi-Fi or the internet? checks in order: an address, the router,
                               the internet (1.1.1.1), DNS, and the page Windows fetches to decide it is
                               online - then one line on what is wrong and what to try
                               (weak signal, no address from the router, router down, DNS failing,
                               a sign-in page in the way, or a VPN)
Also: jk wifi, jk internet, jk online.
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
jk config set theme light      for terminals with a light background (default: dark)
jk config set cp.root D:\cp    where jk cp new puts problems;  cp.lang cpp|py|java;  cp.std c++17
jk config set tidy.minAge 7    keep files newer than 7 days in place
jk config reset <key> | jk config edit | jk config path
'@
    'jobs'   = @'
jk jobs                        applied / waiting on you / ruled out, applications per week, most-applied companies
jk jobs stripe                 did I already apply? every row for a company or role, with links
jk jobs robinhood backend      all words must match (company, role or location)
jk jobs todo                   everything still waiting on you: sign-ins, MFA, take-homes, queued
jk jobs skipped                what was ruled out, and why
jk jobs edit | jk jobs path    open the tracker | print where it is
Reads job_application_tracker.md (a markdown table: Date | Company | Role | Location | Status | Link)
from a Desktop folder, or jk config set jobs.file <path>. Read-only: jk never changes the tracker.
A blocked row counts as done once a later row applies to the same company and role.
'@
    'space'  = @'
jk space                       sizes of Downloads, Recycle Bin, temp, conda/pip/npm caches, Gradle, Maven,
                               Docker's disk, browser/editor caches and every node_modules under the Desktop
jk space -NoNodeModules        skip the node_modules search (faster)
jk space clean temp            delete temp files older than 7 days (-Days 30 to keep more)
jk space clean conda           conda clean --all   (also: pip, npm)
jk space clean jetbrains       caches of JetBrains IDE versions no longer installed (CLion2023.1 after 2024.2)
The report never deletes anything; each row names the right tool to free that space.
'@
    'speed'  = @'
jk speed                       time a new PowerShell with and without your profiles, and each profile file
jk speed fix                   replace the conda init hook (about 2 s per terminal) with an instant equivalent:
                               same PATH entries and CONDA_* variables, conda loads on first use.
                               Verifies python and the active env are unchanged, else rolls back.
jk speed undo                  put the original conda block back (only that block; later profile edits stay)
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
$script:JkHelpTopics['recent'] = $script:JkHelpTopics['find']
$script:JkHelpTopics['doctor'] = $script:JkHelpTopics['setup']
$script:JkHelpTopics['update'] = "jk update                      git pull --ff-only in the jk folder, list what changed, reload the module`n                               (refuses if tracked files have uncommitted changes)"
$script:JkHelpTopics['plan'] = "jk plan                        today's study blocks per course, and the next 7 days if you follow the plan`njk plan start                  start a 25-minute focus block on the most urgent item`n                               Work per item = weight x 15 min (exams) or x 30 min (assignments), minus focus`n                               already logged on that course, spread over the days left.`njk config set plan.hours 4     daily budget (default 3)   plan.examMin / plan.dueMin tune the estimates`njk config set plan.examHours 8 the budget during the study break and exams (default 6, no classes then)"
$script:JkHelpTopics['backup'] = "jk backup | jk backup list     days with a snapshot (taken before the first change of each day, 30 kept)`njk backup restore 2026-10-21   put that day's files back; the current ones are set aside first`njk backup restore 2026-10-21 deadlines    just one file`njk backup restore deadlines    the newest snapshot of one file (a day keeps only the files that changed on it)`njk backup mirror D:\jk-backup  also keep a daily snapshot outside the data folder (another drive, USB, synced folder);`n                               restore reads it when the local backups are gone.  jk backup mirror off"

# An example command, wrapped like a shell line: the rest continues four spaces in.
function Write-JkHelpCommand([string]$Cmd, [int]$Width) {
    $lead = '  '
    foreach ($chunk in (Split-JkWords $Cmd ($Width - 6))) { Say ($lead + (Paint 'cyan' $chunk)); $lead = '      ' }
}

# Help lines wrap in a narrow window rather than being cut: a description continues under itself,
# and a command too long to leave it room puts the description on the lines below.
function Write-JkHelpBlock([string]$Text) {
    $w = Get-JkWidth
    $lines = @($Text -split "`r?`n")
    $i = 0
    while ($i -lt $lines.Count) {
        $l = $lines[$i]; $i++
        if ($l -match '^(jk [^ ].*?|j [^ ].*?)(\s{2,})(.*)$') {
            $cmd = $Matches[1]; $gap = $Matches[2]; $desc = $Matches[3]
            # indented lines under a description continue it
            $more = @()
            while ($i -lt $lines.Count -and $lines[$i] -match '^\s{8,}\S') { $more += $lines[$i]; $i++ }
            $col = 2 + $cmd.Length + $gap.Length
            if ($col + (Get-JkTextWidth $desc) -le $w -and -not @($more | Where-Object { 2 + (Get-JkTextWidth $_) -gt $w }).Count) {
                Say ('  ' + (Paint 'cyan' $cmd) + $gap + (Paint 'muted' $desc))
                foreach ($x in $more) { Say ('  ' + (Paint 'muted' $x)) }
                continue
            }
            $desc = (@($desc) + @($more | ForEach-Object { $_.Trim() })) -join ' '
            $head = '  ' + (Paint 'cyan' $cmd) + $gap
            if ($col -gt $w - 24) { Write-JkHelpCommand $cmd $w; $col = [Math]::Min(33, [Math]::Max(4, $w - 40)); $head = ' ' * $col }
            $first = $true
            foreach ($chunk in (Split-JkWords $desc ($w - $col))) {
                if ($first) { Say ($head + (Paint 'muted' $chunk)); $first = $false } else { Say ((' ' * $col) + (Paint 'muted' $chunk)) }
            }
        } elseif ($l -match '^(jk |j )') {
            Write-JkHelpCommand $l $w
        } elseif ($l -match '^(\s{8,})(.*)$') {
            $col = [Math]::Min(2 + $Matches[1].Length, [Math]::Max(4, $w - 40))
            foreach ($chunk in (Split-JkWords $Matches[2] ($w - $col))) { Say ((' ' * $col) + (Paint 'muted' $chunk)) }
        } else {
            # a run of plain lines is one paragraph: kept as written when it fits, rewrapped when not
            $para = @($l)
            while ($i -lt $lines.Count -and $lines[$i] -and $lines[$i] -notmatch '^(jk |j |\s{8,})') { $para += $lines[$i]; $i++ }
            if (-not @($para | Where-Object { 2 + (Get-JkTextWidth $_) -gt $w }).Count) { foreach ($x in $para) { Say ('  ' + (Paint 'gray' $x)) }; continue }
            foreach ($chunk in (Split-JkWords (($para | ForEach-Object { $_.Trim() }) -join ' ') ($w - 4))) { Say ('  ' + (Paint 'gray' $chunk)) }
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
    $w = Get-JkWidth
    $groups = [ordered]@{
        'School'   = @('class', 'due', 'week', 'exams', 'plan', 'grade', 'todo', 'review')
        'Time'     = @('focus', 'in', 'at', 'remind')
        'Code'     = @('cp', 'repos', 'port')
        'Machine'  = @('find', 'recent', 'go', 'mark', 'clip', 'tidy', 'space', 'sys', 'speed')
        'jk'       = @('brief', 'config', 'backup', 'update', 'doctor', 'setup', 'help')
    }
    foreach ($g in $groups.Keys) {
        Say (' ' + (Paint 'bold white' $g))
        foreach ($c in $groups[$g]) {
            $al = @($script:JkCommands[$c].Aliases | Where-Object { $_ -notmatch '^-' })
            $alTxt = ''
            if ($al.Count) { $alTxt = ' (' + ($al -join ', ') + ')' }
            $desc = $script:JkCommands[$c].Desc
            if (15 + (Get-JkTextWidth ($desc + $alTxt)) -le $w) { Say ('   ' + (Paint 'cyan' (Fit "jk $c" 12)) + (Paint 'muted' $desc) + (Paint 'gray' $alTxt)); continue }
            # too wide: wrap the description under itself, aliases on its last line if they fit
            $chunks = @(Split-JkWords $desc ($w - 15))
            $last = $chunks[-1]
            if ($alTxt -and 15 + (Get-JkTextWidth ($last + $alTxt)) -gt $w) { $chunks += ''; $alTxt = $alTxt.TrimStart() }
            for ($k = 0; $k -lt $chunks.Count; $k++) {
                $lead = '   ' + (' ' * 12); if ($k -eq 0) { $lead = '   ' + (Paint 'cyan' (Fit "jk $c" 12)) }
                $tail = ''; if ($k -eq $chunks.Count - 1) { $tail = Paint 'gray' $alTxt }
                Say ($lead + (Paint 'muted' $chunks[$k]) + $tail)
            }
        }
        Say ''
    }
    foreach ($pair in @(@('jk', 'dashboard: next exam, this week, to-dos, focus, machine'), @('jk help <command>', 'examples for one command   |   Tab completes commands, ids and options'))) {
        $lead = '  ' + (Fit $pair[0] 18)
        foreach ($chunk in (Split-JkWords $pair[1] ([Math]::Max(20, $w - 21)))) { Say (Paint 'gray' ($lead + $chunk)); $lead = ' ' * 20 }
    }
}
