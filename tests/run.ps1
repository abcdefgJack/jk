# jk test suite. Run from anywhere:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "<repo>\tests\run.ps1"
# Uses a throwaway data folder and a pinned clock (Thu 2026-10-22 14:00), so it never
# touches your real ~\.jk data.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$env:JK_HOME = Join-Path $env:TEMP ('jk-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$env:JK_NOW = '2026-10-22T14:00:00'
$env:JK_COLOR = 'never'
$env:JK_WIDTH = '100'
Remove-Item env:JK_DEBUG -ErrorAction SilentlyContinue
$env:JK_NONINTERACTIVE = '1'   # never wait on a prompt
Import-Module (Join-Path $root 'jk.psd1') -Force
$jkm = Get-Module jk

$script:passed = 0
$script:failed = New-Object System.Collections.Generic.List[string]

function global:Assert-Eq($Actual, $Expected, [string]$Msg = '') {
    if ("$Actual" -cne "$Expected") { throw "expected [$Expected] but got [$Actual] $Msg" }
}
function global:Assert-True($Cond, [string]$Msg = 'condition was false') { if (-not $Cond) { throw $Msg } }
function global:Assert-Throws([scriptblock]$Block, [string]$Msg = 'expected an error') {
    $threw = $false
    try { & $Block } catch { $threw = $true }
    if (-not $threw) { throw $Msg }
}

function Test([string]$Name, [scriptblock]$Body) {
    try {
        $null = & $jkm $Body 6>$null
        $script:passed++
        Write-Host "  ok    $Name" -ForegroundColor DarkGreen
    } catch {
        $script:failed.Add("$Name : $($_.Exception.Message)")
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host 'source hygiene' -ForegroundColor Cyan
Test 'all PowerShell sources are pure ASCII (5.1 reads BOM-less files as ANSI)' {
    $bad = @(Get-ChildItem (Join-Path (Get-JkRoot) '*') -Recurse -Include *.ps1, *.psm1, *.psd1 | Where-Object {
            @([IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 }).Count -gt 0
        } | ForEach-Object { $_.Name })
    Assert-Eq ($bad -join ',') '' 'non-ASCII files'
}
Test 'every source file parses' {
    foreach ($f in Get-ChildItem (Get-JkRoot) -Recurse -Include *.ps1, *.psm1) {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
        Assert-Eq @($errs).Count 0 $f.Name
    }
}
Test 'helper calls are not given stray arguments (Paint "a" "b" + c pitfall)' {
    $limits = @{ Paint = 2; Fit = 3; Say = 1 }
    $hits = @()
    foreach ($f in Get-ChildItem (Join-Path (Get-JkRoot) 'lib') -Filter *.ps1) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $limits.ContainsKey([string]$n.GetCommandName()) }, $true)
        foreach ($c in $calls) {
            $argc = @($c.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] }).Count
            if ($argc -gt $limits[$c.GetCommandName()]) { $hits += "$($f.Name):$($c.Extent.StartLineNumber)" }
        }
    }
    Assert-Eq ($hits -join ', ') ''
}
Test 'no "a", "b" + $c inside list literals (comma binds tighter than +)' {
    $hits = @()
    foreach ($f in Get-ChildItem (Get-JkRoot) -Recurse -Include *.ps1, *.psm1) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        $bad = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and $n.Operator -eq 'Plus' -and $n.Left -is [System.Management.Automation.Language.ArrayLiteralAst] }, $true)
        foreach ($b in $bad) { $hits += "$($f.Name):$($b.Extent.StartLineNumber)" }
    }
    Assert-Eq ($hits -join ', ') ''
}
Test 'every command in the dispatch table resolves to a function' {
    foreach ($k in $script:JkCommands.Keys) { Assert-True (Get-Item "function:$($script:JkCommands[$k].Fn)" -ErrorAction SilentlyContinue) "missing $($script:JkCommands[$k].Fn)" }
    foreach ($k in $script:JkParamTargets.Keys) { Assert-True (Get-Item "function:$($script:JkParamTargets[$k])" -ErrorAction SilentlyContinue) "missing $($script:JkParamTargets[$k])" }
}

Write-Host ''
Write-Host 'dates and times' -ForegroundColor Cyan
Test 'relative and named dates (pinned to Thu Oct 22 2026)' {
    $cases = [ordered]@{
        'today' = '2026-10-22'; 'tomorrow' = '2026-10-23'; 'tmr' = '2026-10-23'; 'yesterday' = '2026-10-21'
        'fri' = '2026-10-23'; 'thu' = '2026-10-22'; 'next thu' = '2026-10-29'; 'monday' = '2026-10-26'
        '+3' = '2026-10-25'; '3d' = '2026-10-25'; '2w' = '2026-11-05'
        'oct 28' = '2026-10-28'; '28 oct' = '2026-10-28'; 'oct28' = '2026-10-28'; 'October 28th' = '2026-10-28'
        'dec 2' = '2026-12-02'; '12/2' = '2026-12-02'; '2026-12-04' = '2026-12-04'; '12/04/2026' = '2026-12-04'
        'jan 5' = '2027-01-05'; 'sep 1' = '2026-09-01'; 'aug 1' = '2027-08-01'; '28' = '2026-10-28'; '5' = '2026-11-05'
    }
    foreach ($k in $cases.Keys) { Assert-Eq ((ConvertTo-JkDate $k).ToString('yyyy-MM-dd')) $cases[$k] "for '$k'" }
    Assert-Throws { ConvertTo-JkDate 'someday' }
    Assert-Throws { ConvertTo-JkDate 'oct' }
}
Test 'times' {
    $cases = [ordered]@{ '8pm' = '20:00'; '8:30 pm' = '20:30'; '8:30PM' = '20:30'; '12am' = '00:00'; '12pm' = '12:00'; '2359' = '23:59'; 'noon' = '12:00'; 'midnight' = '23:59'; '20:00' = '20:00'; '9' = '09:00'; '7a' = '07:00' }
    foreach ($k in $cases.Keys) { Assert-Eq (ConvertTo-JkTime $k) $cases[$k] "for '$k'" }
    Assert-Throws { ConvertTo-JkTime '25:00' }
    Assert-Throws { ConvertTo-JkTime 'late' }
    Assert-Eq (Format-JkTime '20:05') '8:05 pm'
    Assert-Eq (Format-JkTime '00:30') '12:30 am'
}
Test 'date + time phrases' {
    $w = ConvertFrom-JkWhen 'nov 25 8pm'; Assert-Eq $w.Date.ToString('MM-dd') '11-25'; Assert-Eq $w.Time '20:00'
    $w = ConvertFrom-JkWhen 'fri at 11:59 pm'; Assert-Eq $w.Date.ToString('MM-dd') '10-23'; Assert-Eq $w.Time '23:59'
    $w = ConvertFrom-JkWhen 'tomorrow'; Assert-Eq $w.Time ''
    $w = ConvertFrom-JkWhen '2026-12-04 9am'; Assert-Eq $w.Date.ToString('yyyy-MM-dd') '2026-12-04'; Assert-Eq $w.Time '09:00'
    Assert-Throws { ConvertFrom-JkWhen 'whenever' }
}
Test 'durations' {
    Assert-Eq (ConvertTo-JkSeconds '25') 1500
    Assert-Eq (ConvertTo-JkSeconds '1h30m') 5400
    Assert-Eq (ConvertTo-JkSeconds '90s') 90
    Assert-Eq (ConvertTo-JkSeconds '1:30') 5400
    Assert-Eq (ConvertTo-JkSeconds '2 hours') 7200
    Assert-Throws { ConvertTo-JkSeconds 'abc' }
    Assert-Throws { ConvertTo-JkSeconds '20 parsecs' }
}
Test 'times pulled from calendar notes' {
    $d = [char]0x2013
    Assert-Eq (Get-JkTimeFromText "4:30 $d 6:20 pm $([char]0xB7) in person" 'Midterm').Time '16:30'
    Assert-Eq (Get-JkTimeFromText "4:30 $d 6:20 pm" 'Midterm').End '18:20'
    Assert-Eq (Get-JkTimeFromText "in class $([char]0xB7) 8:30 $d 9:50 am" 'Quiz 2').Time '08:30'
    Assert-Eq (Get-JkTimeFromText "11:30 - 1:20 pm" 'Lab').Time '11:30'
    Assert-Eq (Get-JkTimeFromText "open Sep 18 8am $d Sep 25 11pm" 'Assignment 1 closes').Time '23:00'
    Assert-Eq (Get-JkTimeFromText '11:59 pm' 'A1').Time '23:59'
    Assert-Eq (Get-JkTimeFromText 'Crowdmark' 'A1').Time ''
}

Write-Host ''
Write-Host 'deadlines' -ForegroundColor Cyan
$sampleHtml = @'
<title>Fall 2026 Deadline Calendar</title>
<style>:root{--cs350:#B91C1C;} :root[data-theme="dark"]{--cs350:#F87171; --health:#F2B04A;}</style>
<script>
const COURSES = {
  cs350:{code:"CS 350",name:"Operating Systems",cls:"cs350",final:"Thu Dec 17"},
  health:{code:"HEALTH 105",name:"Mental Health Literacy",cls:"health",final:null},
};
const EVENTS = [
  {c:"cs350",d:"2026-10-28",n:"A2A Synchronization",t:"8:00 pm",w:"8%"},
  {c:"cs350",d:"2026-10-29",n:"Midterm",t:"4:30 - 6:20 pm, room TBA",w:"25%",exam:true},
  {c:"cs350",d:"2026-12-17",n:"FINAL",t:"4:00 - 6:30 pm",w:"40%",exam:true},
  {c:"health",d:"2026-10-19",n:"Assignment 1",t:"11:59 pm",w:"10%"},
  {c:"health",d:"2026-10-26",n:"Assignment 2",t:"11:59 pm",w:"10%"},
  {c:"health",d:"2026-11-02",n:"Assignment 3",t:"11:59 pm, best 2 of 3 count",w:"10%"},
  {c:"health",d:"2026-10-26",n:"Midterm opens",t:"6:00 am",w:"30%",exam:true},
  {c:"health",d:"2026-10-27",n:"Midterm closes",t:"11:59 pm",w:"30%",exam:true},
];
const MARKS = {"2026-09-08":"Classes start","2026-12-08":"Last day","2026-12-10":"Exams start","2026-12-23":"Exams end"};
const BREAK = ["2026-10-10","2026-10-18"];
</script>
'@
$htmlPath = Join-Path $env:JK_HOME 'sample-calendar.html'
New-Item -ItemType Directory -Path $env:JK_HOME -Force | Out-Null
[IO.File]::WriteAllText($htmlPath, $sampleHtml, (New-Object Text.UTF8Encoding $false))

Test 'import an HTML calendar (courses, colors, times, term)' {
    Import-JkDueHtml $htmlPath
    $d = Get-JkDueData
    Assert-Eq @($d.events).Count 8
    Assert-Eq @($d.courses).Count 2
    $cs = Resolve-JkCourse $d 'CS 350'
    Assert-Eq $cs.color 'F87171' 'dark-theme color wins'
    $mid = @($d.events | Where-Object { $_.title -eq 'Midterm' })[0]
    Assert-Eq $mid.time '16:30'; Assert-Eq $mid.end '18:20'; Assert-Eq $mid.kind 'exam'
    Assert-Eq $d.term.name 'Fall 2026'
    Assert-Eq $d.term.examsStart '2026-12-10'
    Import-JkDueHtml $htmlPath
    Assert-Eq @((Get-JkDueData).events).Count 8 're-import adds no duplicates'
}
Test 'term week, reading week and exam phase' {
    $d = Get-JkDueData
    $i = Get-JkTermInfo $d ([datetime]'2026-10-22')
    Assert-Eq $i.Week 6; Assert-Eq $i.TotalWeeks 13; Assert-Eq $i.Phase 'classes'; Assert-Eq $i.DaysToExams 49
    Assert-True (Get-JkTermInfo $d ([datetime]'2026-10-14')).InBreak 'Oct 14 is reading week'
    Assert-Eq (Get-JkTermInfo $d ([datetime]'2026-12-15')).Phase 'exams'
    Assert-Eq (Get-JkTermInfo $d ([datetime]'2026-12-09')).Phase 'study'
}
Test 'course lookup by key, code, or unique fragment' {
    $d = Get-JkDueData
    Assert-Eq (Resolve-JkCourse $d 'cs350').key 'cs350'
    Assert-Eq (Resolve-JkCourse $d 'CS350').key 'cs350'
    Assert-Eq (Resolve-JkCourse $d '350').key 'cs350'
    Assert-Eq (Resolve-JkCourse $d 'health').key 'health'
    Assert-Eq (Resolve-JkCourse $d 'nope') $null
}
Test 'add / done by text / edit / remove' {
    Add-JkDue cs350 'A3 File Systems' nov 25 8pm -Weight 10
    $d = Get-JkDueData
    $e = @($d.events | Where-Object { $_.title -eq 'A3 File Systems' })[0]
    Assert-Eq $e.date '2026-11-25'; Assert-Eq $e.time '20:00'; Assert-Eq $e.weight '10%'
    Set-JkDueDone 'file sys'
    Assert-True (@((Get-JkDueData).events | Where-Object { $_.title -eq 'A3 File Systems' })[0].done)
    Set-JkDueDone -Undo $e.id
    Edit-JkDue $e.id -Date 'nov 26' -Time 9pm -Exam
    $e2 = @((Get-JkDueData).events | Where-Object { $_.id -eq $e.id })[0]
    Assert-Eq $e2.date '2026-11-26'; Assert-Eq $e2.time '21:00'; Assert-Eq $e2.kind 'exam'
    Remove-JkDue $e.id
    Assert-Eq @((Get-JkDueData).events | Where-Object { $_.id -eq $e.id }).Count 0
    Assert-Throws { Set-JkDueDone 'a' } 'ambiguous text must not mark anything'
}
Test 'new course is created on the fly with a color' {
    Add-JkDue 'stat231' 'Quiz 1' 'oct 30'
    $c = Resolve-JkCourse (Get-JkDueData) 'stat231'
    Assert-Eq $c.code 'STAT 231'
    Assert-True ($c.color -match '^[0-9A-F]{6}$')
}
Test 'upcoming window and reminder selection' {
    $soon = @(Get-JkDueSoon -Hours 168)
    Assert-True ($soon.Count -ge 3) 'several items in the next week'
    Assert-True (@($soon | Where-Object { (Get-JkEventDue $_) -lt (Get-JkNow) }).Count -eq 0) 'nothing in the past'
}
Test 'renders the list views without errors' {
    Show-JkDue; Show-JkDueAll; Show-JkDueAll -Course cs350; Show-JkExams; Show-JkDueWeek; Show-JkCourses; Show-JkDashboard; Show-JkBrief -Force
}
Test 'an online exam window (opens + closes) shows as one exam' {
    $d = Get-JkDueData
    $win = Get-JkEventWindow @($d.events | Where-Object { $_.title -eq 'Midterm closes' })[0] $d
    Assert-Eq $win.Title 'Midterm'
    Assert-Eq $win.Opens.ToString('s') '2026-10-26T06:00:00'
    Assert-Eq $win.Closes.ToString('s') '2026-10-27T23:59:00'
    Assert-True ($null -eq (Get-JkEventWindow @($d.events | Where-Object { $_.title -eq 'A2A Synchronization' })[0] $d)) 'not a window'
    $out = (Show-JkExams 6>&1 | ForEach-Object { "$_" }) -join "`n"
    Assert-Eq ([regex]::Matches($out, 'Midterm\s+Mon Oct 26 6:00 am').Count) 1 'one row for the window'
    Assert-True ($out -match 'open until Tue Oct 27 11:59 pm') 'closing time on the note line'
    Assert-True ($out -notmatch 'Midterm (opens|closes)') 'both halves merged'
    $dash = (Show-JkDashboard 6>&1 | ForEach-Object { "$_" }) -join "`n"
    Assert-True ($dash -match 'NEXT EXAM\s+HEALTH 105 Midterm  in 4 days . Mon Oct 26 6:00 am . Tue 11:59 pm') 'dashboard callout spans the window'
}
Test 'weekly review renders, counts slipped items' {
    Show-JkReview
    $slipped = @((Get-JkDueData).events | Where-Object { -not $_.done -and $_.kind -eq 'due' -and (Get-JkEventDue $_) -lt (Get-JkNow) -and (Get-JkEventDue $_) -ge (Get-JkNow).Date.AddDays(-6) })
    Assert-True ($slipped.Count -ge 1) 'the Oct 19 assignment counts as slipped'
}
Test 'calendar page embeds parseable data' {
    $out = Join-Path $env:JK_HOME 'cal-test.html'
    Export-JkDueHtml -Out $out -NoOpen
    $html = [IO.File]::ReadAllText($out)
    Assert-True (-not $html.Contains('/*JK_DATA*/')) 'placeholder replaced'
    $json = [regex]::Match($html, 'const DATA = (\{.*?\});\r?\n').Groups[1].Value
    $obj = ConvertFrom-Json $json
    Assert-True (@($obj.events).Count -ge 8)
}
Test 'ICS export: valid structure, 75-octet folding, escaping' {
    $out = Join-Path $env:JK_HOME 'test.ics'
    Export-JkDueIcs -Out $out
    $text = [IO.File]::ReadAllText($out)
    Assert-True $text.StartsWith("BEGIN:VCALENDAR`r`n")
    Assert-True $text.TrimEnd().EndsWith('END:VCALENDAR')
    Assert-Eq ([regex]::Matches($text, 'BEGIN:VEVENT').Count) ([regex]::Matches($text, 'END:VEVENT').Count)
    foreach ($line in ($text -split "`r`n")) { Assert-True ([Text.Encoding]::UTF8.GetByteCount($line) -le 75) "line too long: $line" }
    Assert-Eq (ConvertTo-JkIcsText 'a,b;c\d') 'a\,b\;c\\d'
    # every summary says what it is: Due:, Exam: (or Appt:)
    $summaries = @([regex]::Matches(($text -replace "`r`n ", ''), '(?m)^SUMMARY:(.*)$') | ForEach-Object { $_.Groups[1].Value })
    Assert-True (@($summaries | Where-Object { $_ -like 'Exam: *' }).Count -ge 1) 'exams are labelled'
    Assert-Eq @($summaries | Where-Object { $_ -notmatch '^(Due|Exam|Appt): ' }).Count 0 'nothing unlabelled'
}

Test 'jk at: bare hours mean the next such hour, day + time phrases' {
    $at = { param($words, $now) (Resolve-JkAtTime $words ([datetime]$now)).At.ToString('MM-dd HH:mm') }
    Assert-Eq (& $at @('5', 'leave') '2026-10-22 14:00') '10-22 17:00' 'afternoon: 5 means 5 pm'
    Assert-Eq (& $at @('5', 'leave') '2026-10-22 03:00') '10-22 05:00' 'before dawn: 5 means 5 am'
    Assert-Eq (& $at @('9', 'class') '2026-10-22 22:00') '10-23 09:00' 'late evening: tomorrow 9 am'
    Assert-Eq (& $at @('3:30pm', 'call') '2026-10-22 14:00') '10-22 15:30'
    Assert-Eq (& $at @('2pm', 'x') '2026-10-22 14:30') '10-23 14:00' 'explicit pm already past rolls to tomorrow'
    Assert-Eq (& $at @('tomorrow', '9am', 'submit') '2026-10-22 14:00') '10-23 09:00'
    Assert-Eq (Resolve-JkAtTime @('tomorrow', '9am', 'submit', 'form') ([datetime]'2026-10-22 14:00')).K 2
    Assert-Throws { Resolve-JkAtTime @('whenever') ([datetime]'2026-10-22 14:00') }
}
Test 'same-day alerts: once per item, skip 0% and window openings, 2h ahead, can be turned off' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'alerts-home'
    $orig = ${function:Start-JkBackground}
    try {
        # no real timers in tests
        function script:Start-JkBackground { param([string]$Script, [hashtable]$Env = @{}, [string]$WaitUntil) $script:LastJob = "$Script @ $WaitUntil"; [pscustomobject]@{ Id = 0; StartTime = (Get-Date) } }
        Import-JkDueHtml $htmlPath | Out-Null
        $d = Get-JkDueData
        $iv = Resolve-JkCourse $d 'intv' -Create
        $null = New-JkEvent $d -Course $iv.key -Date ([datetime]'2026-10-28') -Time '15:30' -Title 'Interview' -Kind 'appt'
        $null = New-JkEvent $d -Course 'cs350' -Date ([datetime]'2026-10-28') -Time '17:00' -Title 'Practice set' -Weight '0%'
        $null = New-JkEvent $d -Course 'health' -Date ([datetime]'2026-10-28') -Time '16:00' -Title 'Quiz 3 opens' -Weight '5%'
        Save-JkDueData $d
        $now = [datetime]'2026-10-28T09:00'
        Assert-Eq (Register-JkTodayAlerts -Now $now) 2 'A2A (8 pm) and the interview (no weight); not the 0% set or the quiz opening'
        $items = @((Get-JkReminderData).items | Sort-Object at)
        Assert-True ($items[0].text -like '* Interview at 3:30 pm') "interview: $($items[0].text)"
        $r = $items[1]
        Assert-Eq $r.at '2026-10-28T18:00:00' '2 hours before 8 pm'
        Assert-True ($r.text -like 'CS 350 A2A Synchronization at 8:00 pm*')
        Assert-True ($script:LastJob -like "Complete-JkReminder -Id $($r.id) @ 2026-10-28T18:00:00*") "timer: $($script:LastJob)"
        # only the A2A alert from here on
        $rd = Get-JkReminderData; $rd.items = @($r); Save-JkReminderData $rd
        Assert-Eq (Register-JkTodayAlerts -Now $now) 0 'a second morning run adds nothing'
        Assert-Eq (Register-JkTodayAlerts -Now ([datetime]'2026-10-28T19:00')) 0 'too late to warn 2 hours ahead'
        $script:PopupCalls = 0
        $origNotify = ${function:Show-JkNotify}
        function script:Show-JkNotify { param([string]$Title, [string[]]$Lines) $script:PopupLines = $Lines; $script:PopupCalls++; 'stub' }
        try {
            # finished before the alert fires: no popup, and the alert clears itself
            Set-JkDueDone ([string]$r.dueId)
            Complete-JkReminder -Id ([int]$r.id)
            Assert-Eq $script:PopupCalls 0 'no popup for a finished item'
            Assert-Eq @((Get-JkReminderData).items).Count 0 'alert removed'
            # fired or cancelled: signing in again later that day does not set it again
            Set-JkDueDone -Undo ([string]$r.dueId)
            Assert-Eq (Register-JkTodayAlerts -Now $now) 0 'remembered for the day'
            # still open and still due that evening: the popup says when, and how to close it
            $a = New-JkReminder -At ([datetime]'2026-10-28T18:00') -Text 'x' -DueId ([int]$r.dueId)
            Complete-JkReminder -Id ([int]$a.id)
            Assert-Eq $script:PopupCalls 1 'popup for an open item'
            Assert-True ($script:PopupLines[0] -like 'Due 8:00 pm*') "first line: $($script:PopupLines[0])"
            Assert-Eq $script:PopupLines[1] "Finished? jk due done $($r.dueId)"
            # an exam alert says when it starts and where, not "due" / "finished?"
            $mid = @((Get-JkDueData).events | Where-Object { $_.course -eq 'cs350' -and $_.title -eq 'Midterm' })[0]
            $a = New-JkReminder -At ([datetime]'2026-10-29T14:30') -Text 'x' -DueId ([int]$mid.id)
            Complete-JkReminder -Id ([int]$a.id)
            Assert-True ($script:PopupLines[0] -like 'Starts 4:30 pm*') "exam line: $($script:PopupLines[0])"
            Assert-True (-not ($script:PopupLines -match 'Finished\?')) 'no "finished?" for an exam'
            $script:PopupCalls--
            # the end of an online window says it closes, and asks whether it was written
            $cl = @((Get-JkDueData).events | Where-Object { $_.course -eq 'health' -and $_.title -eq 'Midterm closes' })[0]
            $a = New-JkReminder -At ([datetime]'2026-10-27T21:59') -Text 'x' -DueId ([int]$cl.id)
            Complete-JkReminder -Id ([int]$a.id)
            Assert-True ($script:PopupLines[0] -like 'Closes 11:59 pm*' -and $script:PopupLines[-1] -eq "Written it? jk due done $($cl.id)") "closes: $($script:PopupLines -join ' / ')"
            $script:PopupCalls--
            # moved to another day after the alert was set: stay quiet
            $d = Get-JkDueData
            @($d.events | Where-Object { [int]$_.id -eq [int]$r.dueId })[0].date = '2026-10-29'
            Save-JkDueData $d
            $a = New-JkReminder -At ([datetime]'2026-10-28T18:00') -Text 'x' -DueId ([int]$r.dueId)
            Complete-JkReminder -Id ([int]$a.id)
            Assert-Eq $script:PopupCalls 1 'no popup once the deadline moved'
        } finally { Set-Item function:script:Show-JkNotify $origNotify }
        Assert-Throws { Invoke-JkConfig set alert.before soon } 'bad durations are refused'
        Set-JkConfig 'alert.before' 'off'
        Assert-Eq (Register-JkTodayAlerts -Now ([datetime]'2026-10-29T08:00')) 0 'turned off'
    } finally {
        Set-Item function:script:Start-JkBackground $orig
        $env:JK_HOME = $saved
        $script:JkConfigCache = $null
    }
}
Test 'morning task: the daily trigger keeps local time across daylight saving changes' {
    $t = New-JkDailyTrigger ([datetime]::ParseExact('07:45', 'HH:mm', [Globalization.CultureInfo]::InvariantCulture))
    Assert-True ($t.StartBoundary -match 'T07:45:00$') "start: $($t.StartBoundary)"
    Assert-True (-not (Test-JkTriggerPinnedToUtc $t.StartBoundary)) 'stored as local time'
    # what earlier installs stored (doctor flags these)
    Assert-True (Test-JkTriggerPinnedToUtc '2026-10-22T07:45:00-04:00')
    Assert-True (Test-JkTriggerPinnedToUtc '2026-10-24T11:45:00Z')
    Assert-True (-not (Test-JkTriggerPinnedToUtc '2026-10-24T07:45:00'))
}
Test 'focus after a restart: time left gets a new timer, a passed end is logged at its length' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'focus-restart'; $script:JkConfigCache = $null
    $orig = ${function:Start-JkBackground}
    function script:Start-JkBackground { param([string]$Script, [hashtable]$Env = @{}, [string]$WaitUntil) $script:Rearmed += , "$WaitUntil|$Script"; [pscustomobject]@{ Id = $PID; StartTime = (Get-Process -Id $PID).StartTime } }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    try {
        $script:Rearmed = @()
        # a 50-minute block started 20 minutes ago; a restart took its timer
        $start = (Get-Date).AddMinutes(-20)
        Save-JkJson 'focus.json' ([pscustomobject]@{ sessions = @(); active = [pscustomobject]@{ id = 'abc12345'; label = 'cs350 a2a'; start = $start.ToString('s', $inv); seconds = 3000; pid = 999999; spawned = '2000-01-01T00:00:00' } })
        Restore-JkFocusTimer
        $a = (Get-JkFocusData).active
        Assert-True ($a -and [int]$a.pid -eq $PID) 'still running, on a new timer'
        Assert-Eq $script:Rearmed.Count 1
        Assert-True ($script:Rearmed[0] -like "*|Complete-JkFocusSession -Id 'abc12345'") "timer: $($script:Rearmed[0])"
        $fires = [datetime]::Parse(($script:Rearmed[0] -split '\|')[0], $inv, [Globalization.DateTimeStyles]::RoundtripKind)
        Assert-True ([Math]::Abs(($fires - [datetime]::Parse($start.ToString('s', $inv), $inv).AddMinutes(50)).TotalSeconds) -lt 2) "fires at the original end: $fires"
        # a 25-minute block whose end passed while the machine was off
        Save-JkJson 'focus.json' ([pscustomobject]@{ sessions = @(); active = [pscustomobject]@{ id = 'def67890'; label = 'co367'; start = (Get-Date).AddHours(-2).ToString('s', $inv); seconds = 1500; pid = 999999; spawned = '2000-01-01T00:00:00' } })
        Restore-JkFocusTimer
        $fd = Get-JkFocusData
        Assert-True (-not $fd.active) 'closed'
        Assert-Eq "$($fd.sessions[0].actual) $($fd.sessions[0].completed)" '25 True' 'logged at its planned length'
    } finally { Set-Item function:script:Start-JkBackground $orig; $env:JK_HOME = $saved; $script:JkConfigCache = $null }
}
Test 'morning brief: once per 3 hours, and a future stamp never silences it' {
    $orig = ${function:Show-JkNotify}
    $script:BriefCalls = 0
    function script:Show-JkNotify { $script:BriefCalls++; 'stub' }
    try {
        Save-JkJson 'state.json' ([pscustomobject]@{ lastRemind = '2026-10-22T12:30:00' })
        Invoke-JkDueRemind -Quiet -Hours 200
        Assert-Eq $script:BriefCalls 0 'reminded 90 minutes ago'
        Save-JkJson 'state.json' ([pscustomobject]@{ lastRemind = '2026-10-28T07:45:00' })
        Invoke-JkDueRemind -Quiet -Hours 200
        Assert-Eq $script:BriefCalls 1 'a stamp from the future is ignored'
        Assert-Eq (Read-JkJson 'state.json' $null).lastRemind '2026-10-22T14:00:00' 'and replaced with now'
    } finally { Set-Item function:script:Show-JkNotify $orig }
}
Test 'exam mornings: the title says so, and exam lines carry the end time and what to bring' {
    $d = $script:G.dot; $dash = $script:G.dash; $arrow = $script:G.arrow
    Assert-Eq (Get-JkExamNote ([pscustomobject]@{ note = "4:30 $dash 6:20 pm $d in person, room TBA" })) 'in person, room TBA'
    Assert-Eq (Get-JkExamNote ([pscustomobject]@{ note = "6:00 am Oct 26 $arrow 11:59 pm Oct 27 $d LEARN quiz, ~60$($dash)70 min" })) "LEARN quiz, ~60$($dash)70 min"
    Assert-Eq (Get-JkExamNote ([pscustomobject]@{ note = "7:30 $dash 10:00 pm $d room TBA $d one handwritten sheet, no calculator" })) "room TBA $d one handwritten sheet, no calculator"
    Assert-Eq (Get-JkExamNote ([pscustomobject]@{ note = '11:59 pm' })) ''
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'exam-morning'; $script:JkConfigCache = $null
    $orig = ${function:Show-JkNotify}
    function script:Show-JkNotify { param([string]$Title, [string[]]$Lines) $script:ExamTitle = $Title; $script:ExamLines = $Lines; 'stub' }
    try {
        Add-JkDue cs350 'Midterm' oct 29 4:30pm -Exam -End 6:20pm -Note "4:30 $dash 6:20 pm $d in person, room TBA"
        Add-JkDue cs341 'Assignment 2' oct 30 11:59pm
        $env:JK_NOW = '2026-10-29T07:45:00'
        Invoke-JkDueRemind -Quiet -Force
        Assert-True ($script:ExamTitle -like 'Exam today: * Midterm 4:30 pm') "title: $($script:ExamTitle)"
        Assert-True (@($script:ExamLines | Where-Object { $_ -like "Today 4:30-6:20 pm $dash * Midterm (exam) $d in person, room TBA" }).Count -eq 1) "lines: $($script:ExamLines -join ' / ')"
        # the day before is an ordinary morning
        $env:JK_NOW = '2026-10-28T07:45:00'
        Invoke-JkDueRemind -Quiet -Force
        Assert-True ($script:ExamTitle -like '* in the next 48h') "the day before: $($script:ExamTitle)"
    } finally { Set-Item function:script:Show-JkNotify $orig; $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null }
}
Test 'dashboard cache: kept for the same key, redone when the data changes' {
    $script:Computed = 0
    $one = Get-JkCached 'probe' 'k1' { $script:Computed++; 'first' }
    $two = Get-JkCached 'probe' 'k1' { $script:Computed++; 'second' }
    Assert-Eq "$one $two $script:Computed" 'first first 1' 'same key: computed once'
    Assert-Eq (Get-JkCached 'probe' 'k2' { 'third' }) 'third' 'a new key recomputes'
    Set-Content -LiteralPath (Join-Path $env:JK_HOME 'cache\probe.txt') -Value 'garbage without a key line' -NoNewline
    Assert-Eq (Get-JkCached 'probe' 'k2' { 'fourth' }) 'fourth' 'a damaged cache file is just recomputed'
    # the study line follows a new deadline at once, not an hour later
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'dash-cache'; $script:JkConfigCache = $null
    try {
        Add-JkDue cs350 'Big one' oct 23 8pm -Weight 30
        $before = @(Show-JkDashboard 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'STUDY TODAY' })
        Add-JkDue cs341 'Other one' oct 23 8pm -Weight 30
        $after = @(Show-JkDashboard 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'STUDY TODAY' })
        Assert-True ($before[0] -notmatch 'CS341' -and $after[0] -match 'CS341') "before: $before / after: $after"
    } finally { $env:JK_HOME = $saved; $script:JkConfigCache = $null }
}
Test 'grade fill: each past graded item once, marks recorded and checked off at their due time' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'grade-fill'; $script:JkConfigCache = $null
    $origTI = ${function:Test-JkInteractive}
    try {
        Add-JkDue cs350 'A1' oct 7 8pm -Weight 8
        Add-JkDue health 'Quiz opens' oct 10 9am -Weight 5 -Exam
        Add-JkDue health 'Quiz closes' oct 11 9pm -Weight 5 -Exam
        Add-JkDue cs341 'A2' oct 30 11:59pm -Weight 4
        Add-JkDue cs350 'Reading' oct 1
        $items = @(Get-JkUnmarkedItems)
        Assert-Eq $items.Count 2 'past and graded only, the quiz window once'
        Assert-True ($items[1].Label -like '* Quiz') "label: $($items[1].Label)"
        $script:Answers = New-Object System.Collections.Generic.Queue[string]
        foreach ($x in '7/8', 'x', '90') { $script:Answers.Enqueue($x) }
        function script:Read-Host { param($Prompt) $script:Answers.Dequeue() }
        function script:Test-JkInteractive { $true }
        Invoke-JkGradeFill
        Assert-Eq @(Get-JkUnmarkedItems).Count 0 'a typo is asked again, then both are marked'
        Assert-Eq (@((Get-JkGradeData).scores | ForEach-Object { "$($_.score)" }) -join ',') '87.5,90'
        $d = Get-JkDueData
        $a1 = @($d.events | Where-Object { $_.title -eq 'A1' })[0]
        Assert-Eq "$($a1.done) $($a1.doneAt)" 'True 2026-10-07T20:00:00' 'done as of its due time, not today'
        Assert-True @($d.events | Where-Object { $_.title -eq 'Quiz opens' })[0].done 'the opening half too'
        Assert-True (-not @($d.events | Where-Object { $_.title -eq 'A2' })[0].done) 'future items untouched'
    } finally {
        Remove-Item function:script:Read-Host -ErrorAction SilentlyContinue
        Set-Item function:script:Test-JkInteractive $origTI
        $env:JK_HOME = $saved; $script:JkConfigCache = $null
    }
}
Test 'morning brief: to-dos due today or overdue ride along, and are enough on their own' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'todo-brief'; $script:JkConfigCache = $null
    $orig = ${function:Show-JkNotify}
    function script:Show-JkNotify { param([string]$Title, [string[]]$Lines) $script:TodoTitle = $Title; $script:TodoLines = $Lines; 'stub' }
    try {
        # the pinned clock is Thu Oct 22 2026, 2 pm
        Add-JkTodo email the TA -Due 'today 5pm'
        Add-JkTodo return library book -Due 'oct 20'
        Add-JkTodo buy ink -Due 'oct 30'
        $script:TodoTitle = $null
        Invoke-JkDueRemind -Quiet -Force
        Assert-Eq $script:TodoTitle '2 to-dos due (1 overdue)'
        Assert-Eq ($script:TodoLines -join ' / ') 'To-do: return library book (overdue since Tue), email the TA by 5:00 pm'
        # done ones drop out, and with nothing left the brief stays quiet
        $d = Get-JkTodoData; foreach ($i in $d.items) { $i.done = $true }; Save-JkTodoData $d
        $script:TodoTitle = $null
        Invoke-JkDueRemind -Quiet -Force
        Assert-Eq $script:TodoTitle $null 'nothing to say'
    } finally { Set-Item function:script:Show-JkNotify $orig; $env:JK_HOME = $saved; $script:JkConfigCache = $null }
}
Test 'morning brief: an exam up to 3 days out still gets a popup; an open window says so' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'exam-ahead'; $script:JkConfigCache = $null
    $orig = ${function:Show-JkNotify}
    function script:Show-JkNotify { param([string]$Title, [string[]]$Lines) $script:AheadTitle = $Title; $script:AheadLines = $Lines; 'stub' }
    try {
        # Sat Nov 14, 7:45: nothing in the next 48 hours, a midterm on Monday evening
        Add-JkDue cs370 'Midterm 2' nov 16 7pm -Exam
        $env:JK_NOW = '2026-11-14T07:45:00'
        $script:AheadTitle = $null
        Invoke-JkDueRemind -Quiet -Force
        Assert-True ($script:AheadTitle -like '* Midterm 2 in 2 days (Mon 7:00 pm)') "title: $($script:AheadTitle)"
        Assert-True ($script:AheadLines[0] -like 'Mon 7:00 pm * Midterm 2 (exam)') "line: $($script:AheadLines[0])"
        # an online quiz that opened this morning and closes tonight
        Add-JkDue health 'Quiz opens' nov 14 6am -Exam
        Add-JkDue health 'Quiz closes' nov 14 11:59pm -Exam
        Invoke-JkDueRemind -Quiet -Force
        Assert-True (@($script:AheadLines | Where-Object { $_ -like '* Quiz closes (exam, open now)*' }).Count -eq 1) "lines: $($script:AheadLines -join ' / ')"
    } finally { Set-Item function:script:Show-JkNotify $orig; $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null }
}
Test 'finals season: the term line counts exams left, and a study day gets its brief' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'finals'; $script:JkConfigCache = $null
    $orig = ${function:Show-JkNotify}
    function script:Show-JkNotify { param([string]$Title, [string[]]$Lines) $script:FinTitle = $Title; $script:FinLines = $Lines; 'stub' }
    try {
        Add-JkDue cs350 'FINAL' dec 17 4pm -Exam -Weight 40
        Add-JkDue co367 'FINAL' dec 19 7:30pm -Exam -Weight 50
        $d = Get-JkDueData
        Set-JkProp $d 'term' ([pscustomobject]@{ name = 'Fall 2026'; start = '2026-09-08'; classesEnd = '2026-12-08'; examsStart = '2026-12-10'; examsEnd = '2026-12-22' })
        Save-JkDueData $d
        $dot = $script:G.dot
        # Mon Dec 14: three days to the next final, nothing due within 48 hours
        $env:JK_NOW = '2026-12-14T07:45:00'
        Assert-Eq (Format-JkTermLine (Get-JkTermInfo (Get-JkDueData) (Get-JkNow))) "Fall 2026 $dot exam period $dot 2 exams left"
        $script:FinTitle = $null
        Invoke-JkDueRemind -Quiet -Force
        Assert-True ($script:FinTitle -like 'Next exam: * FINAL Thu 4:00 pm (in 3 days)') "title: $($script:FinTitle)"
        Assert-True (@($script:FinLines | Where-Object { $_ -like 'Study today: *' }).Count -eq 1) "lines: $($script:FinLines -join ' / ')"
        # after the last one
        $env:JK_NOW = '2026-12-20T07:45:00'
        Assert-Eq (Format-JkTermLine (Get-JkTermInfo (Get-JkDueData) (Get-JkNow))) "Fall 2026 $dot exam period $dot your exams are done $($script:G.check)"
    } finally { Set-Item function:script:Show-JkNotify $orig; $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null }
}
Test 'Sunday mornings look at the whole week' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'week-ahead'; $script:JkConfigCache = $null
    $orig = ${function:Show-JkNotify}
    function script:Show-JkNotify { param([string]$Title, [string[]]$Lines) $script:WeekTitle = $Title; $script:WeekLines = $Lines; 'stub' }
    try {
        # Sun Nov 22: nothing in the next two days, but an exam window and an assignment later on
        Add-JkDue cs350 'Quiz opens' nov 25 9am -Exam
        Add-JkDue cs350 'Quiz closes' nov 26 9pm -Exam
        Add-JkDue cs341 'A4' nov 27 11:59pm
        Add-JkDue cs341 'A5' dec 5 11:59pm
        $env:JK_NOW = '2026-11-22T07:45:00'
        $script:WeekTitle = $null
        Invoke-JkDueRemind -Quiet -Force
        Assert-Eq $script:WeekTitle 'Nothing due in the next two days' 'the week alone is worth the popup'
        Assert-True ($script:WeekLines[0] -like "This week: 1 due, 1 exam $($script:G.dash) * Quiz Wed") "line: $($script:WeekLines[0])"
        # a weekday morning with nothing close (no exam within 3 days either) stays quiet
        $env:JK_NOW = '2026-11-30T07:45:00'
        $script:WeekTitle = $null
        Invoke-JkDueRemind -Quiet -Force
        Assert-Eq $script:WeekTitle $null 'no popup on a quiet Monday'
    } finally { Set-Item function:script:Show-JkNotify $orig; $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null }
}
Test 'jobs: reads the tracker table, sorts rows into applied / waiting / ruled out, finds by company' {
    $md = Join-Path $env:JK_HOME 'tracker.md'
    $d = [string][char]0x2014
    $lines = @(
        '# Job Application Tracker', '',
        '| Date | Company | Role | Location / term | Status | Link |',
        '|---|---|---|---|---|---|',
        "| 2026-10-06 | Robinhood | Software Developer Intern, Backend (Summer 2027) (gh 1) | Toronto | Submitted successfully via Greenhouse embed $d 'Thank you' | https://x.test/1 |",
        "| 2026-09-15 | IBM | Data Services Developer Intern (WW 1) | Markham | NOT SUBMITTED $d IBMid login now requires MFA enrollment | https://x.test/2 |",
        "| 2026-09-20 | IBM | Data Services Developer Intern (WW 2) | Markham | Submitted via WaterlooWorks | https://x.test/3 |",
        "| 2026-09-04 | Geotab | Data Scientist | Oakville | Not submitted $d posted salary minimum below C`$30/hour | |",
        "| 2026-09-25 | Semgrep | Software Engineer Intern \| Cloud | Remote | NOT SUBMITTED $d form includes a human-verification question | https://x.test/4 |",
        "| 2026-10-01 | Tesla | Internship | Palo Alto | Queued $d apply after the password reset | |",
        "| 2026-10-02 | Acme | Intern | Remote | SKIPPED $d requires US work authorization | |",
        "| 2026-10-03 | Beta | Intern | Remote | Direct Greenhouse application submitted | |"
    )
    [IO.File]::WriteAllLines($md, $lines, (New-Object Text.UTF8Encoding $false))
    Set-JkConfig 'jobs.file' $md
    try {
        $rows = @(Get-JkJobs)
        Assert-Eq $rows.Count 8
        Assert-Eq (($rows | ForEach-Object { $_.State }) -join ',') 'applied,todo,applied,skip,todo,todo,skip,applied'
        Assert-True (@($rows | Where-Object { $_.Company -eq 'IBM' -and $_.State -eq 'todo' })[0].Resolved) 'blocked, then applied later: no longer waiting'
        Assert-Eq $rows[4].Role 'Software Engineer Intern | Cloud' 'an escaped bar stays inside its cell'
        Assert-Eq (Get-JkJobNote $rows[0]) 'via Greenhouse'
        Assert-Eq (Get-JkJobNote $rows[1]) 'IBMid login now requires MFA enrollment'
        $sum = (Show-JkJobs 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($sum -match '3 applied\s+! 2 waiting on you \(1 from the last 21 days\)\s+. 2 ruled out') "summary counts: $(@($sum -split "`n" | Where-Object { $_ -match 'applied' })[0])"
        # Semgrep (Sep 25) has waited 27 days: stale; Tesla (Oct 1) 21 days: not yet
        Assert-True (Test-JkJobStale $rows[4] (Get-JkNow)) 'Semgrep is stale'
        Assert-True (-not (Test-JkJobStale $rows[5] (Get-JkNow))) 'Tesla is not stale yet'
        Assert-True ($sum -notmatch 'IBMid') 'the resolved IBM row is not listed as waiting'
        $hit = (Find-JkJobs 'robinhood backend' 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($hit -match '1 row . 1 applied' -and $hit -match 'https://x.test/1') 'found, with its link'
        $none = (Find-JkJobs 'stripe' 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($none -match 'Not in the tracker') 'no match says so'
        # weekly review on Oct 22: nothing sent Oct 16-22 or Oct 9-15 (latest is Oct 6); Tesla still waiting
        $rev = (Show-JkReview 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($rev -match 'job search\s+0 applications sent \(week before: 0\)\s+.\s+1 waiting on you') "review line: $(@($rev -split "`n" | Where-Object { $_ -match 'job search' })[0])"
        # the dashboard shows only the recent blocker (Tesla), not the stale one (Semgrep)
        $dash = (Show-JkDashboard 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($dash -match 'JOBS\s+1 application waiting on you' -and $dash -match 'Tesla' -and $dash -notmatch 'Semgrep') 'dashboard jobs section'
        # cached parse is reused until the file changes
        $null = Get-JkJobs -Cached
        $script:JkJobsCache.Rows[0].Company = 'from-cache'
        Assert-Eq @(Get-JkJobs -Cached)[0].Company 'from-cache' 'same parse while unchanged'
        Add-Content -LiteralPath $md -Value "| 2026-10-04 | Gamma | Intern | Remote | Submitted via Ashby | |"
        $again = @(Get-JkJobs -Cached)
        Assert-Eq $again.Count 9 'a changed file is read again'
        Assert-Eq $again[0].Company 'Robinhood'
    } finally { Invoke-JkConfig reset jobs.file }
}
Test 'doctor flags a stale LEARN feed and this week''s background errors' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'doctor-home'
    $script:JkConfigCache = $null
    try {
        New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
        Set-JkConfig 'sync.url' 'https://example.test/feed.ics'
        # doctor reads the wall clock (it reports on the real machine), so stamps are relative to it
        Save-JkJson 'state.json' ([pscustomobject]@{ lastSync = (Get-Date).AddDays(-5).ToString('s', $script:Inv) })
        Set-Content -LiteralPath (Get-JkPath 'background.log') -Value @(
            ((Get-Date).AddDays(-30).ToString('s', $script:Inv) + ' old: ignored'),
            ((Get-Date).AddHours(-2).ToString('s', $script:Inv) + ' sync: The remote name could not be resolved'))
        $out = (Invoke-JkDoctor 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($out -match 'LEARN feed\s+last synced 5 days ago') 'stale feed'
        Assert-True ($out -match 'background errors\s+1 this week, latest: sync: The remote name') 'recent error only'
    } finally { $env:JK_HOME = $saved; $script:JkConfigCache = $null }
}
Test 'task status via COM: a missing task is $null, and the list says how to install it' {
    $orig = $script:JkTaskName
    $script:JkTaskName = 'jk-test-no-such-task-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    try {
        Assert-True ($null -eq (Get-JkTaskInfo)) 'missing task'
        $out = (Show-JkReminders 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($out -match 'morning brief not installed') 'install hint'
    } finally { $script:JkTaskName = $orig }
}
Test 'listening ports from netstat: IPv4 and IPv6, only foreign port 0, any language' {
    $lines = @(
        '  Proto  Local Address          Foreign Address        State           PID',
        '  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1180',
        '  TCP    127.0.0.1:5173         0.0.0.0:0              ABHOEREN        4242',
        '  TCP    192.168.2.14:51234     142.250.1.1:443        ESTABLISHED     900',
        '  TCP    [::]:445               [::]:0                 LISTENING       4',
        '  TCP    [::1]:8080             [::]:0                 LISTENING       777'
    )
    $l = @(Get-JkListeners -Lines $lines)
    Assert-Eq $l.Count 4 'the established connection is not a listener'
    Assert-Eq (($l | ForEach-Object { "$($_.LocalAddress)|$($_.LocalPort)|$($_.OwningProcess)" }) -join ' ') '0.0.0.0|135|1180 127.0.0.1|5173|4242 ::|445|4 ::1|8080|777'
    # and the real table parses (every Windows box listens on something, e.g. 135)
    Assert-True (@(Get-JkListeners).Count -gt 0) 'real netstat'
}
Test 'jk sys: CPU load from GetSystemTimes, addresses from .NET' {
    $l = Get-JkCpuLoad 100
    Assert-True ($null -ne $l -and $l -ge 0 -and $l -le 100) "load: $l"
    $null = @(Get-JkIPv4)
    $out = (Invoke-JkSys 6>&1 | ForEach-Object { "$_" }) -join "`n"
    Assert-True ($out -match 'CPU\s+\S+\s+\d+%') 'CPU row'
    Assert-True ($out -match 'Memory\s+\S+\s+\d+%') 'memory row'
}
Test 'repos: git status of every repo in parallel, counts and UTF-8 subjects' {
    $root = Join-Path $env:JK_HOME 'repos-root'
    $a = Join-Path $root 'alpha'
    $b = Join-Path $root 'nested\beta'
    New-Item -ItemType Directory -Force -Path $a, $b | Out-Null
    foreach ($r in $a, $b) {
        $null = & git -C $r init -q 2>&1
        $null = & git -C $r config user.email 'test@example.test'
        $null = & git -C $r config user.name 'test'
    }
    Set-Content -LiteralPath (Join-Path $a 'f.txt') -Value 'x'
    $null = & git -C $a add f.txt 2>&1
    $subject = 'fix ' + [string][char]0x4E2D + [string][char]0x6587
    $null = & git -C $a commit -q -m $subject 2>&1
    Set-Content -LiteralPath (Join-Path $a 'f.txt') -Value 'y'
    Set-Content -LiteralPath (Join-Path $a 'new.txt') -Value 'n'
    $found = @(Find-JkRepos @($root) 3)
    Assert-Eq $found.Count 2 'both repos found, including the nested one'
    $st = @(Get-JkRepoStatuses $found | Sort-Object Name)
    Assert-Eq $st[0].Name 'alpha'
    Assert-Eq "$($st[0].Modified)/$($st[0].Untracked)" '1/1' 'one changed, one new'
    Assert-Eq $st[0].Msg $subject 'the subject survives as UTF-8'
    Assert-Eq $st[1].Name 'beta'
    Assert-Eq "$($st[1].Msg)|$($st[1].Remote)" '|' 'no commits, no remote'
}
Test 'what''s new: each item once, three per run; a fresh setup sees none' {
    $state = Read-JkJson 'state.json' $null
    if (-not $state) { $state = [pscustomobject]@{} }
    Set-JkProp $state 'newsSeen' @()
    Save-JkJson 'state.json' $state
    $n = $script:JkNews.Count
    $first = (Show-JkDashboard 6>&1 | ForEach-Object { "$_" }) -join "`n"
    Assert-Eq ([regex]::Matches($first, '(?m)^\s+new\s{2}').Count) ([Math]::Min(3, $n)) 'first run: three'
    Assert-True ($first -match "new\s+$([regex]::Escape($script:JkNews[0].Cmd))") 'newest first'
    # the rest, three at a time, each exactly once
    $shown = [Math]::Min(3, $n)
    for ($run = 2; $run -le 10 -and $shown -lt $n; $run++) {
        $next = (Show-JkDashboard 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $k = [regex]::Matches($next, '(?m)^\s+new\s{2}').Count
        Assert-Eq $k ([Math]::Min(3, $n - $shown)) "run $run"
        $shown += $k
    }
    Assert-Eq $shown $n 'every item announced'
    Assert-Eq @(Pop-JkNews).Count 0 'then nothing'
    # a fresh setup: no newsSeen yet and no deadlines
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'news-fresh'
    try {
        New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
        Assert-Eq @(Pop-JkNews).Count 0 'fresh setup: nothing to catch up on'
        Assert-Eq @((Read-JkJson 'state.json' $null).newsSeen).Count $n 'all marked seen'
    } finally { $env:JK_HOME = $saved; $script:JkConfigCache = $null }
}
Test 'class alerts: 10 minutes before, one timer at a time, chained, quiet if dropped' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'class-alerts-home'
    $orig = ${function:Start-JkBackground}
    $origNotify = ${function:Show-JkNotify}
    try {
        Import-JkDueHtml $htmlPath | Out-Null
        function script:Start-JkBackground { param([string]$Script, [hashtable]$Env = @{}, [string]$WaitUntil) [pscustomobject]@{ Id = 0; StartTime = (Get-Date) } }
        $script:Shown = @()
        function script:Show-JkNotify { param([string]$Title, [string[]]$Lines, $Accent, [int]$Seconds) $script:Shown += , ($Title + ' | ' + ($Lines -join ' | ')); $script:ShownSeconds = $Seconds; 'stub' }
        $mkc = { param($id, $course, $start, $end, $room) [pscustomobject]@{ id = $id; course = $course; kind = 'LEC'; days = @('Thu'); start = $start; end = $end; room = $room; from = ''; to = '' } }
        Save-JkClassData ([pscustomobject]@{ nextId = 3; items = @((& $mkc 1 'cs350' '10:00' '11:20' 'MC 4040'), (& $mkc 2 'health' '13:00' '14:20' 'online')) })
        # an in-class quiz during the 10:00 lecture
        $dq = Get-JkDueData
        $null = New-JkEvent $dq -Course 'cs350' -Date ([datetime]'2026-10-22') -Time '10:00' -Title 'Quiz 1' -Kind 'exam' -Weight '5%'
        # and the course's midterm that evening
        $null = New-JkEvent $dq -Course 'cs350' -Date ([datetime]'2026-10-22') -Time '18:00' -Title 'Midterm' -Kind 'exam' -Weight '25%'
        Save-JkDueData $dq
        $now = [datetime]'2026-10-22T08:00'
        $r = Register-JkClassAlert -Now $now
        Assert-Eq $r.at '2026-10-22T09:50:00' '10 minutes before the first class'
        Assert-True ($r.text -like 'CS 350 LEC at 10:00 am') "text: $($r.text)"
        Assert-True ($null -eq (Register-JkClassAlert -Now $now)) 'one pending at a time'
        # it fires: "starts in", and the next class is set before the popup shows
        $env:JK_NOW = '2026-10-22T09:50:00'
        Complete-JkReminder -Id ([int]$r.id)
        Assert-Eq $script:Shown.Count 1
        Assert-True ($script:Shown[0] -match 'Starts in 10m . MC 4040') "popup: $($script:Shown[0])"
        Assert-True ($script:Shown[0] -match 'Quiz 1 \(exam\), 5% in this class') "names the in-class quiz: $($script:Shown[0])"
        Assert-True ($script:Shown[0] -match 'Midterm later today at 6:00 pm, 25%') "and the exam later that day: $($script:Shown[0])"
        Assert-Eq $script:ShownSeconds 1200 'closes itself 10 minutes into the class (20 minutes after a 9:50 alert)'
        $next = @((Get-JkReminderData).items)
        Assert-Eq "$($next.Count) $($next[0].at)" '1 2026-10-22T12:50:00' 'chained to the 1 pm class'
        # dropped from the timetable before it fires: no popup, nothing left to chain
        $cd = Get-JkClassData; $cd.items = @($cd.items | Where-Object { $_.course -ne 'health' }); Save-JkClassData $cd
        Complete-JkReminder -Id ([int]$next[0].id)
        Assert-Eq $script:Shown.Count 1 'no popup for a dropped class'
        Assert-Eq @((Get-JkReminderData).items).Count 0
        # a later sign-in the same morning does not re-arm an alert that already fired
        Assert-True ($null -eq (Register-JkClassAlert -Now ([datetime]'2026-10-22T09:00'))) 'remembered for the day'
        Set-JkConfig 'alert.class' 'off'
        Assert-True ($null -eq (Register-JkClassAlert -Now ([datetime]'2026-10-29T08:00'))) 'turned off'
    } finally {
        $env:JK_NOW = '2026-10-22T14:00:00'
        Set-Item function:script:Start-JkBackground $orig
        Set-Item function:script:Show-JkNotify $origNotify
        $env:JK_HOME = $saved
        $script:JkConfigCache = $null
    }
}
Test 'cancelling a class alert moves on to the next class' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'class-cancel-home'
    $orig = ${function:Start-JkBackground}
    try {
        Import-JkDueHtml $htmlPath | Out-Null
        function script:Start-JkBackground { param([string]$Script, [hashtable]$Env = @{}, [string]$WaitUntil) [pscustomobject]@{ Id = 0; StartTime = (Get-Date) } }
        $mkc = { param($id, $course, $start, $end) [pscustomobject]@{ id = $id; course = $course; kind = 'LEC'; days = @('Thu'); start = $start; end = $end; room = ''; from = ''; to = '' } }
        Save-JkClassData ([pscustomobject]@{ nextId = 3; items = @((& $mkc 1 'cs350' '10:00' '11:20'), (& $mkc 2 'health' '13:00' '14:20')) })
        $env:JK_NOW = '2026-10-29T08:00:00'
        $r = Register-JkClassAlert
        Assert-Eq $r.at '2026-10-29T09:50:00'
        Cancel-JkReminder ([string]$r.id)
        $items = @((Get-JkReminderData).items)
        Assert-Eq "$($items.Count) $($items[0].at)" '1 2026-10-29T12:50:00' 'the 1 pm class still gets its alert'
    } finally {
        $env:JK_NOW = '2026-10-22T14:00:00'
        Set-Item function:script:Start-JkBackground $orig
        $env:JK_HOME = $saved
        $script:JkConfigCache = $null
    }
}
Test 'review fixes: ics unescape, course codes, drive roots, exact role match' {
    Assert-Eq (ConvertFrom-JkIcsText 'C:\\new\, a\nb\;c') "C:\new, a`nb;c" 'one pass, left to right'
    $d = Get-JkDueData
    $ev = [pscustomobject]@{ Summary = 'Quiz 1'; Categories = ''; Location = ''; Description = 'LEC 001 only; AFM 425 students write at 4:30' }
    Assert-True ($null -eq (Find-JkIcsCourse $ev $d)) 'codes in the description do not invent a course'
    $ev2 = [pscustomobject]@{ Summary = 'Quiz 1'; Categories = ''; Location = ''; Description = 'for CS 350 students' }
    Assert-Eq (Find-JkIcsCourse $ev2 $d).key 'cs350' 'a known course in the description still matches'
    Assert-Eq (Get-JkGitDirArg 'D:\') 'D:\.'
    Assert-Eq (Get-JkGitDirArg 'C:\x') 'C:\x'
    $md = Join-Path $env:JK_HOME 'tracker-roles.md'
    $dash = [string][char]0x2014
    [IO.File]::WriteAllLines($md, @(
            '| Date | Company | Role | Location | Status | Link |', '|---|---|---|---|---|---|',
            "| 2026-10-01 | Robinhood | Software Developer Intern (gh 1) | Toronto | NOT SUBMITTED $dash sign-in pending | |",
            '| 2026-10-06 | Robinhood | Software Developer Intern, Web (gh 2) | Toronto | Submitted via Greenhouse | |'), (New-Object Text.UTF8Encoding $false))
    $rows = @(Get-JkJobs -Path $md)
    Assert-True (-not $rows[0].Resolved) 'a different role does not resolve the blocked one'
}
Test 'review fixes 2: weekly windows, done exams, state writes, log trim, doctor' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'review2-home'
    $script:JkConfigCache = $null
    try {
        Import-JkDueHtml $htmlPath | Out-Null
        $d = Get-JkDueData
        # two weekly windows with identical titles pair with their own halves
        $o1 = New-JkEvent $d -Course 'health' -Date ([datetime]'2026-11-02') -Time '06:00' -Title 'Quiz opens' -Kind 'exam'
        $c1 = New-JkEvent $d -Course 'health' -Date ([datetime]'2026-11-03') -Time '23:59' -Title 'Quiz closes' -Kind 'exam'
        $o2 = New-JkEvent $d -Course 'health' -Date ([datetime]'2026-11-09') -Time '06:00' -Title 'Quiz opens' -Kind 'exam'
        $c2 = New-JkEvent $d -Course 'health' -Date ([datetime]'2026-11-10') -Time '23:59' -Title 'Quiz closes' -Kind 'exam'
        Save-JkDueData $d
        Assert-Eq (Get-JkEventWindow $o2 $d).Close.id $c2.id 'second opening pairs with the second closing'
        Assert-Eq (Get-JkEventWindow $c1 $d).Open.id $o1.id 'first closing pairs with the first opening'
        # a finished exam is not listed
        $before = (Show-JkExams 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Set-JkDueDone ([string]@($d.events | Where-Object { $_.title -eq 'Midterm' -and $_.course -eq 'cs350' })[0].id)
        $after = (Show-JkExams 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($before -match 'CS 350\s+Midterm' -and $after -notmatch 'CS 350\s+Midterm') 'done exam dropped from jk exams'
        # state writes keep each other's keys
        Set-JkState 'lastRemind' '2026-10-22T07:45:00'
        $null = Pop-JkNews
        Assert-Eq (Get-JkState 'lastRemind') '2026-10-22T07:45:00' 'news did not overwrite lastRemind'
        Assert-True (@(Get-JkState 'newsSeen').Count -gt 0) 'news recorded'
        # background.log is trimmed to the newest lines
        [IO.File]::WriteAllLines((Get-JkPath 'background.log'), @(1..600 | ForEach-Object { "2026-10-01T00:00:00 line $_" }))
        Limit-JkBackgroundLog
        $kept = @([IO.File]::ReadAllLines((Get-JkPath 'background.log')))
        Assert-Eq "$($kept.Count) $($kept[-1])" '500 2026-10-01T00:00:00 line 600'
        # a malformed sync stamp does not stop doctor
        Set-JkConfig 'sync.url' 'https://example.test/feed.ics'
        Set-JkState 'lastSync' 'not a date'
        $doc = (Invoke-JkDoctor 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($doc -match 'LEARN feed\s+connected, no sync recorded' -and $doc -match 'data read') 'doctor runs to the end'
    } finally { $env:JK_HOME = $saved; $script:JkConfigCache = $null }
}
Test 'review fixes 3: same-title items, todo keywords, focus credit, process tree' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'review3-home'
    $script:JkConfigCache = $null
    try {
        Import-JkDueHtml $htmlPath | Out-Null
        $d = Get-JkDueData
        # two separate weekly quizzes with the same title stay separate in grades and the plan
        $q1 = New-JkEvent $d -Course 'cs350' -Date ([datetime]'2026-10-27') -Time '23:59' -Title 'Quiz' -Weight '3%'
        $q2 = New-JkEvent $d -Course 'cs350' -Date ([datetime]'2026-11-03') -Time '23:59' -Title 'Quiz' -Weight '3%'
        Save-JkDueData $d
        $items = @(Get-JkGradeItems $d (Get-JkGradeData) 'cs350' | Where-Object { $_.Title -eq 'Quiz' })
        Assert-Eq $items.Count 2 'both quizzes graded'
        # the health midterm window still counts once, at its closing
        $mid = @(Get-JkGradeItems $d (Get-JkGradeData) 'health' | Where-Object { $_.Title -eq 'Midterm' })
        Assert-Eq $mid.Count 1 'window counted once'
        $plan = @(Get-JkPlanItems -Now ([datetime]'2026-10-22T14:00') | Where-Object { $_.Title -eq 'Quiz' })
        Assert-Eq $plan.Count 2 'both quizzes planned'
        # focus spent before a finished item does not count toward the next one
        $fd = Get-JkFocusData
        $fd.sessions = @([pscustomobject]@{ label = 'cs350 a2a'; start = '2026-10-21T10:00:00'; planned = 300; actual = 300; completed = $true })
        Save-JkFocusData $fd
        $a2a = @($d.events | Where-Object { $_.title -eq 'A2A Synchronization' })[0]
        $before = @(Get-JkPlanItems -Now ([datetime]'2026-10-22T14:00') | Where-Object { $_.Title -eq 'Midterm' -and $_.Course -eq 'cs350' })[0].Done
        $d2 = Get-JkDueData; $x = @($d2.events | Where-Object { $_.id -eq $a2a.id })[0]; $x.done = $true; Set-JkProp $x 'doneAt' '2026-10-22T09:00:00'; Save-JkDueData $d2
        $after = @(Get-JkPlanItems -Now ([datetime]'2026-10-22T14:00') | Where-Object { $_.Title -eq 'Midterm' -and $_.Course -eq 'cs350' })[0].Done
        Assert-True ($before -gt 0 -and $after -eq 0) "credit before/after finishing A2A: $before / $after"
        # "jk todo clear the desk" adds a to-do instead of purging finished ones
        Add-JkTodo 'old' ; Set-JkTodoDone 1
        Invoke-JkTodo clear the desk
        $t = @((Get-JkTodoData).items)
        Assert-Eq (($t | ForEach-Object { $_.text }) -join ',') 'old,clear the desk' 'nothing purged'
        # the process tree helper copes with a pid that is gone
        Stop-JkProcessTree 999999
        # a squeezed evening still gets whole blocks, biggest share first
        $mk = { param($k, $eff) [pscustomobject]@{ Key = $k; Course = 'x'; Title = $k; Due = [datetime]'2026-11-20T23:59'; Weight = 5; Kind = 'due'; Id = 0; Effort = $eff; Done = 0.0 } }
        $sched = @(Get-JkPlanSchedule -Items @((& $mk 'a' 400), (& $mk 'b' 300), (& $mk 'c' 300)) -Now ([datetime]'2026-10-22T20:00') -Days 1 -BudgetMin 180 -TodayLeftFraction 0.25)
        $total = 0; foreach ($v in $sched[0].Alloc.Values) { $total += $v }
        Assert-Eq "$total $($sched[0].Alloc['a'])" '25 25' '45 minutes left: one block, to the biggest share'
    } finally { $env:JK_HOME = $saved; $script:JkConfigCache = $null }
}
Test 'data safety: cp clean spares the data folder, tidy recycles only loose downloads, temp keeps fresh folders' {
    $root = Join-Path $env:JK_HOME ('safety-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    # cp clean: the build cache goes; a .jk that is the data folder, or holds data, stays
    $savedHome = $env:JK_HOME
    $dataDir = Join-Path $root '.jk'
    New-Item -ItemType Directory -Force -Path (Join-Path $root '.jkcp'), $dataDir | Out-Null
    Set-Content -LiteralPath (Join-Path $root '.jkcp\a.exe.stamp') -Value 'x'
    Push-Location $root
    try {
        $env:JK_HOME = $dataDir
        Save-JkJson 'deadlines.json' ([pscustomobject]@{ events = @() })
        Clear-JkCp
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.jkcp'))) 'build cache removed'
        Assert-True (Test-Path -LiteralPath (Join-Path $dataDir 'deadlines.json')) 'the data folder survives jk cp clean'
        # an old-style build cache named .jk, holding only compiled files, is cleaned
        $env:JK_HOME = $savedHome
        Remove-Item -LiteralPath $dataDir -Recurse -Force
        New-Item -ItemType Directory -Path $dataDir | Out-Null
        Set-Content -LiteralPath (Join-Path $dataDir 'a.exe') -Value 'x'
        Set-Content -LiteralPath (Join-Path $dataDir 'a.exe.stamp') -Value 'x'
        Clear-JkCp
        Assert-True (-not (Test-Path -LiteralPath $dataDir)) 'legacy build-only .jk removed'
    } finally { Pop-Location; $env:JK_HOME = $savedHome }
    # tidy: loose files and jk's category folders count; the inside of other folders never does
    $dl = Join-Path $root 'Downloads'
    New-Item -ItemType Directory -Force -Path (Join-Path $dl 'Installers'), (Join-Path $dl 'tool\bin') | Out-Null
    foreach ($f in 'setup.exe', 'setup (1).exe', 'Installers\old.msi', 'tool\bin\tool.exe', 'tool\bin\tool-copy.exe') { Set-Content -LiteralPath (Join-Path $dl $f) -Value 'same bytes' }
    $dl = Resolve-JkLongPath $dl   # as the tidy commands do (TEMP may be an 8.3 path)
    $loose = @(Get-JkLooseDownloads $dl | ForEach-Object { $_.FullName.Substring($dl.Length + 1) } | Sort-Object)
    Assert-Eq ($loose -join ',') 'Installers\old.msi,setup (1).exe,setup.exe' 'no files from inside tool\'
    # space clean temp: an old empty folder goes, a fresh one stays
    $savedTemp = $env:TEMP
    $tmp = Join-Path $root 'temp'
    $oldDir = Join-Path $tmp 'old-empty'; $newDir = Join-Path $tmp 'new-empty'
    New-Item -ItemType Directory -Force -Path $oldDir, $newDir | Out-Null
    (Get-Item -LiteralPath $oldDir).CreationTime = (Get-Date).AddDays(-30)
    (Get-Item -LiteralPath $oldDir).LastWriteTime = (Get-Date).AddDays(-30)
    try {
        $env:TEMP = $tmp
        Invoke-JkSpaceClean temp
        Assert-True ((-not (Test-Path -LiteralPath $oldDir)) -and (Test-Path -LiteralPath $newDir)) 'only the old empty folder is removed'
    } finally { $env:TEMP = $savedTemp }
}
Test 'profile safety: speed undo swaps only the conda block; hook backup is the pre-jk original' {
    $dir = Join-Path $env:JK_HOME ('prof-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $p = Join-Path $dir 'profile.ps1'
    $orig = "#region conda initialize`r`n# !! Contents within this block are managed by 'conda init' !!`r`n(& `"C:\x\conda.exe`" `"shell.powershell`" `"hook`") | Out-String | Invoke-Expression`r`n#endregion"
    $fast = "#region conda initialize`r`n# jk speed: fast conda.`r`n`$Env:PATH = `"C:\x;`" + `$Env:PATH`r`n#endregion"
    [IO.File]::WriteAllText("$p.jk-backup", "Set-Alias ll ls`r`n$orig`r`n")
    [IO.File]::WriteAllText($p, "Set-Alias ll ls`r`n$fast`r`nfunction added-later { 'kept' }`r`n")
    Undo-JkSpeedFix -Files @([pscustomobject]@{ Kind = 'test'; Path = $p })
    $after = [IO.File]::ReadAllText($p)
    Assert-True ($after.Contains('shell.powershell') -and $after -notmatch 'jk speed: fast conda') 'original conda block is back'
    Assert-True ($after.Contains('function added-later')) 'lines added after the fix survive'
    # profile hook: the first install keeps the pre-jk profile; a second install does not replace it
    $hp = Join-Path $dir 'Microsoft.PowerShell_profile.ps1'
    [IO.File]::WriteAllText($hp, "Write-Host 'mine'`r`n")
    Install-JkProfileHook -Path $hp
    Install-JkProfileHook -Path $hp
    Assert-Eq ([IO.File]::ReadAllText("$hp.jk-hook-backup")).Trim() "Write-Host 'mine'" 'backup is the original'
    Assert-Eq ([regex]::Matches([IO.File]::ReadAllText($hp), [regex]::Escape($script:ProfileStart)).Count) 1 'one hook block'
    # "j jobs" reaches the job tracker's folder
    $jd = Join-Path $dir 'job hunt'
    New-Item -ItemType Directory -Force -Path $jd | Out-Null
    Set-Content -LiteralPath (Join-Path $jd 'job_application_tracker.md') -Value '| Date | Company | Role | Location | Status | Link |'
    Set-JkConfig 'jobs.file' (Join-Path $jd 'job_application_tracker.md')
    try { Assert-Eq (Find-JkGo 'jobs').Path $jd } finally { Invoke-JkConfig reset jobs.file }
}
Test 'backup mirror: daily snapshot outside the data folder, restore after losing it' {
    $saved = $env:JK_HOME
    $base = Join-Path $saved ('mirror-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $env:JK_HOME = Join-Path $base 'data'
    $script:JkConfigCache = $null
    try {
        Import-JkDueHtml $htmlPath | Out-Null
        $count = @((Get-JkDueData).events).Count
        Assert-Throws { Invoke-JkBackup mirror (Join-Path $env:JK_HOME 'inside') } 'a mirror inside the data folder is refused'
        $m = Join-Path $base 'mirror'
        Invoke-JkBackup mirror $m
        $day = (Get-Date).ToString('yyyy-MM-dd')
        Assert-True (Test-Path -LiteralPath (Join-Path $m "$day\deadlines.json")) "today's snapshot"
        New-Item -ItemType Directory -Path (Join-Path $m '2000-01-01') | Out-Null
        $null = Sync-JkBackupMirror
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $m '2000-01-01'))) 'snapshots older than 30 days are pruned'
        # the whole data folder is lost (local backups with it): the mirror brings it back
        Remove-Item -LiteralPath $env:JK_HOME -Recurse -Force
        $script:JkConfigCache = $null
        Set-JkConfig 'backup.mirror' $m
        Invoke-JkBackup restore $day
        Assert-Eq @((Get-JkDueData).events).Count $count 'deadlines restored from the mirror'
        Invoke-JkBackup mirror off
        Assert-Eq (Get-JkConfig 'backup.mirror') '' 'mirror off'
    } finally { $env:JK_HOME = $saved; $script:JkConfigCache = $null }
}
Test 'timers count real time across a daylight-saving change' {
    # 00:30 on the night US/Canadian clocks fall back (Nov 1 2026, 07:30 UTC in Pacific time).
    # In a zone without DST this is plain arithmetic; the CI run in Pacific time crosses the change.
    $from = [datetime]::SpecifyKind([datetime]'2026-11-01T07:30:00', 'Utc')
    $at = Get-JkLocalAfter 7200 $from
    Assert-Eq $at.ToUniversalTime().ToString('s') '2026-11-01T09:30:00' 'two real hours later'
    # the timer's wait-until string keeps that instant
    $iso = $at.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    $back = [datetime]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    Assert-Eq $back.ToUniversalTime().ToString('s') '2026-11-01T09:30:00' "round trip of $iso"
    # the same night in Eastern time: 05:00 UTC is 01:00 EDT, and the clocks fall back at 06:00 UTC
    Assert-Eq (Get-JkLocalAfter 7200 ([datetime]::SpecifyKind([datetime]'2026-11-01T05:00:00', 'Utc'))).ToUniversalTime().ToString('s') '2026-11-01T07:00:00'
    # and across spring forward (Mar 14 2027, 09:30 UTC = 01:30 PST)
    $spring = Get-JkLocalAfter 3600 ([datetime]::SpecifyKind([datetime]'2027-03-14T09:30:00', 'Utc'))
    Assert-Eq $spring.ToUniversalTime().ToString('s') '2027-03-14T10:30:00' 'one real hour later'
}
Test 'mornings: afternoon exams get study time that day; windows read "closes today" / "open until"' {
    $mk = { param($k, $due) [pscustomobject]@{ Key = $k; Course = 'x'; Title = $k; Due = [datetime]$due; Weight = 25; Kind = 'exam'; Id = 0; Effort = 300; Done = 0.0 } }
    $s = @(Get-JkPlanSchedule -Items @((& $mk 'pm-midterm' '2026-10-29T16:30'), (& $mk 'am-quiz' '2026-10-29T08:30')) -Now ([datetime]'2026-10-29T08:05') -Days 1 -BudgetMin 180)
    Assert-True ($s[0].Alloc['pm-midterm'] -gt 0) 'the morning before a 4:30 pm exam is used'
    Assert-True (-not $s[0].Alloc.ContainsKey('am-quiz')) 'no study block for something 25 minutes away'
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'mornings-home'
    $script:JkConfigCache = $null
    $origNotify = ${function:Show-JkNotify}
    try {
        Import-JkDueHtml $htmlPath | Out-Null
        $env:JK_NOW = '2026-10-27T08:05:00'
        $dash = (Show-JkDashboard 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($dash -match 'OPEN NOW . closes today 11:59 pm') 'closes today'
        $env:JK_NOW = '2026-10-25T08:05:00'
        function script:Show-JkNotify { param([string]$Title, [string[]]$Lines) $script:BriefLines = $Lines; 'stub' }
        Invoke-JkDueRemind -Quiet -Force
        Assert-True (@($script:BriefLines | Where-Object { $_ -match 'Midterm opens \(exam\), open until Tue 11:59 pm' }).Count -eq 1) "popup: $($script:BriefLines -join ' / ')"
    } finally {
        Set-Item function:script:Show-JkNotify $origNotify
        $env:JK_NOW = '2026-10-22T14:00:00'
        $env:JK_HOME = $saved
        $script:JkConfigCache = $null
    }
}
Test 'first LEARN sync links to items typed in by hand instead of duplicating them' {
    Assert-Eq (Get-JkIcsTitle 'Assignment 2 Dropbox - Due' 'CS 341').Title 'Assignment 2'
    Assert-Eq (Get-JkIcsTitle 'Midterm 1 - Availability Ends' 'HEALTH 105').Title 'Midterm 1'
    Assert-Eq (Get-JkTitleKey 'Assignment 3 closes') (Get-JkTitleKey 'Assignment 3 Dropbox')
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'firstsync-home'
    $script:JkConfigCache = $null
    try {
        Import-JkDueHtml $htmlPath | Out-Null
        $before = @((Get-JkDueData).events)
        $f = Join-Path $env:JK_HOME 'learn.ics'
        $ev = { param($uid, $utc, $sum, $loc) @('BEGIN:VEVENT', "UID:$uid", "DTSTART:$utc", "DTEND:$utc", "SUMMARY:$sum", "LOCATION:$loc", 'END:VEVENT') }
        # 8 pm EDT Oct 28 = 00:00 UTC Oct 29; 11:59 pm EDT Oct 27 = 03:59 UTC Oct 28
        $a2a = (Get-JkEventDue @($before | Where-Object { $_.title -eq 'A2A Synchronization' })[0]).ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'")
        $mid = (Get-JkEventDue @($before | Where-Object { $_.title -eq 'Midterm closes' })[0]).ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'")
        [IO.File]::WriteAllLines($f, @('BEGIN:VCALENDAR', 'VERSION:2.0') +
            (& $ev 'l-1' $a2a 'A2A Synchronization Dropbox - Due' 'CS 350 - Operating Systems (Fall 2026)') +
            (& $ev 'l-2' $mid 'Midterm - Availability Ends' 'HEALTH 105 - Mental Health Literacy (Fall 2026)') +
            (& $ev 'l-3' '20261204T045900Z' 'Final Project Dropbox - Due' 'HEALTH 105 - Mental Health Literacy (Fall 2026)') + @('END:VCALENDAR'))
        Invoke-JkDueSync $f
        $after = @((Get-JkDueData).events)
        Assert-Eq $after.Count ($before.Count + 1) 'only the final project is new'
        $linked = @($after | Where-Object { (Get-JkProp $_ 'uid') -in 'l-1', 'l-2' })
        Assert-Eq (($linked | ForEach-Object { $_.title } | Sort-Object) -join ',') 'A2A Synchronization,Midterm closes' 'hand-typed titles kept'
        $fp = @($after | Where-Object { (Get-JkProp $_ 'uid') -eq 'l-3' })[0]
        Assert-Eq "$($fp.title)|$($fp.kind)|$($fp.note)" 'Final Project|due|' 'a final project is not an exam; no course-name note'
        # LEARN moves A2A a day: a sync by hand lists it, the morning task's quiet sync keeps it
        # for the morning popup, which says it once
        $moveTo = { param([int]$Days) [IO.File]::WriteAllLines($f, @('BEGIN:VCALENDAR', 'VERSION:2.0') + (& $ev 'l-1' ([datetime]::ParseExact($a2a, "yyyyMMdd'T'HHmmss'Z'", $null, 'AdjustToUniversal').AddDays($Days).ToString("yyyyMMdd'T'HHmmss'Z'")) 'A2A Synchronization Dropbox - Due' 'CS 350 - Operating Systems (Fall 2026)') + @('END:VCALENDAR')) }
        & $moveTo 1
        $out = (Invoke-JkDueSync $f 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($out -match 'moved #\d+ CS 350 A2A Synchronization\s+Wed Oct 28 8:00 pm \S Thu Oct 29 8:00 pm') "sync by hand: $out"
        & $moveTo 2
        Invoke-JkDueSync $f -Quiet
        Assert-Eq ((Get-JkState 'syncMoved' @()) -join '|') 'CS 350 A2A Synchronization to Fri Oct 30 8:00 pm'
        $origNotify = ${function:Show-JkNotify}
        function script:Show-JkNotify { param([string]$Title, [string[]]$Lines) $script:MovedLines = $Lines; 'stub' }
        try {
            Invoke-JkDueRemind -Quiet -Force
            Assert-True (@($script:MovedLines | Where-Object { $_ -eq 'LEARN moved: CS 350 A2A Synchronization to Fri Oct 30 8:00 pm' }).Count -eq 1) "popup: $($script:MovedLines -join ' / ')"
            Assert-Eq @(Get-JkState 'syncMoved' @() | Where-Object { $_ }).Count 0 'said once'
        } finally { Set-Item function:script:Show-JkNotify $origNotify }
    } finally { $env:JK_HOME = $saved; $script:JkConfigCache = $null }
}
Test 'term phases: no section nudge after classes; next-term pointer; bigger exam-period budget' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'phases-home'
    $script:JkConfigCache = $null
    try {
        Import-JkDueHtml $htmlPath | Out-Null
        Save-JkJson 'sections.json' ([pscustomobject]@{ items = @([pscustomobject]@{ course = 'cs350'; kind = 'LEC'; section = '001'; days = @('Tue'); start = '10:00'; end = '11:20'; room = 'MC 4040' }) })
        Set-JkState 'newsSeen' @($script:JkNews | ForEach-Object { $_.Id })
        $env:JK_NOW = '2026-10-22T09:00:00'
        $during = (Show-JkDashboard 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($during -match 'add your class sections') 'during classes: nudge'
        Assert-Eq (Get-JkPlanBudgetKey) 'plan.hours'
        $env:JK_NOW = '2026-12-15T09:00:00'
        $exams = (Show-JkDashboard 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($exams -notmatch 'add your class sections') 'exam period: no section nudge'
        Assert-Eq (Get-JkPlanBudgetKey) 'plan.examHours'
        Assert-Eq (Get-JkPlanToday).Budget 360 'six hours a day during exams'
        $env:JK_NOW = '2026-12-28T09:00:00'
        $after = (Show-JkDashboard 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($after -match 'jk due sync\s+\+\s+jk class import\s+\S.* is over' -and $after -notmatch 'add your class sections') 'after the term: next-term pointer, command first'
        # a week past the exams the next term is under way: named by season, old term no longer described
        $env:JK_NOW = '2027-01-06T09:00:00'
        Assert-Eq (Format-JkTermLine (Get-JkTermInfo (Get-JkDueData) (Get-JkNow))) 'Winter 2027'
        $jan = (Show-JkDashboard 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($jan -match "jk class import\s+bring in Winter 2027's deadlines" -and $jan -notmatch 'term over|is over') 'new term with nothing in it yet'
        Add-JkDue cs999 'Lab 1' 'jan 15' 5pm | Out-Null
        $jan2 = (Show-JkDashboard 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($jan2 -notmatch "bring in .*'s deadlines") 'quiet once the new term has deadlines'
        Assert-Eq (Get-JkSeasonName ([datetime]'2027-06-01')) 'Spring 2027'
    } finally {
        $env:JK_NOW = '2026-10-22T14:00:00'
        $env:JK_HOME = $saved
        $script:JkConfigCache = $null
    }
}
Test 'a damaged data file is replaced by the newest backup that reads' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved ('heal-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $script:JkConfigCache = $null
    try {
        Import-JkDueHtml $htmlPath | Out-Null
        $good = [IO.File]::ReadAllText((Get-JkPath 'deadlines.json'))
        $n = @((Get-JkDueData).events).Count
        # two backup days: the newer one is itself damaged, the older one is good
        foreach ($day in '2026-10-20', '2026-10-21') { New-Item -ItemType Directory -Force -Path (Join-Path $env:JK_HOME "backups\$day") | Out-Null }
        [IO.File]::WriteAllText((Join-Path $env:JK_HOME 'backups\2026-10-20\deadlines.json'), $good)
        [IO.File]::WriteAllText((Join-Path $env:JK_HOME 'backups\2026-10-21\deadlines.json'), '{"events": [')
        # cut short by a crash
        [IO.File]::WriteAllText((Get-JkPath 'deadlines.json'), $good.Substring(0, [int]($good.Length / 2)))
        $all = @(Get-JkDueData 3>&1)
        $w = @($all | Where-Object { $_ -is [Management.Automation.WarningRecord] }) -join ' '
        $d = @($all | Where-Object { $_ -isnot [Management.Automation.WarningRecord] })[0]
        Assert-Eq @($d.events).Count $n 'deadlines are back'
        Assert-True ("$w" -match 'Restored the backup of 2026-10-20') "warning: $w"
        Assert-True (@(Get-ChildItem -LiteralPath $env:JK_HOME -Filter 'deadlines.json.corrupt-*').Count -eq 1) 'the damaged file is kept'
        Assert-Eq @((Get-JkDueData).events).Count $n 'the file on disk is repaired, not just this read'
        # an emptied file counts as damage too
        [IO.File]::WriteAllText((Get-JkPath 'deadlines.json'), '')
        Assert-Eq @((Get-JkDueData 3>$null).events).Count $n 'empty file restored'
        # a hand edit that breaks config.json falls back to the last good config, not to defaults
        Set-JkConfig 'remind.time' '07:45'
        New-Item -ItemType Directory -Force -Path (Join-Path $env:JK_HOME 'backups\2026-10-19') | Out-Null
        [IO.File]::WriteAllText((Join-Path $env:JK_HOME 'backups\2026-10-19\config.json'), '{ "remind.time": "07:45" }')
        [IO.File]::WriteAllText((Get-JkPath 'config.json'), "{`n  `"remind.time`": `"07:45`",`n}")
        $script:JkConfigCache = $null
        Assert-Eq (Get-JkConfig 'remind.time' 3>$null) '07:45' 'the last good config is used'
        # a file jk does not back up (state) still just falls back
        [IO.File]::WriteAllText((Get-JkPath 'state.json'), '{"lastRemind": ')
        Assert-True ($null -eq (Read-JkJson 'state.json' $null 3>$null)) 'state falls back'
    } finally { $env:JK_HOME = $saved; $script:JkConfigCache = $null }
}
Test 'counts read "1 file", "2 files", "1 copy", "2 copies"' {
    Assert-Eq (Format-JkCount 1 'file') '1 file'
    Assert-Eq (Format-JkCount 2 'file') '2 files'
    Assert-Eq (Format-JkCount 0 'session') '0 sessions'
    Assert-Eq (Format-JkCount 1 'duplicate copy' 'duplicate copies') '1 duplicate copy'
    Assert-Eq (Format-JkCount 3 'duplicate copy' 'duplicate copies') '3 duplicate copies'
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved ('plural-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    try {
        $fd = Get-JkFocusData
        $fd.sessions = @([pscustomobject]@{ label = 'x'; start = (Get-Date).ToString('s'); planned = 25; actual = 25; completed = $true })
        Save-JkFocusData $fd
        $log = (Show-JkFocusLog 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($log -match '\b1 session\b' -and $log -notmatch '1 sessions') 'focus log says "1 session"'
    } finally { $env:JK_HOME = $saved }
}
Test 'background timers sleep before loading the module, then run in its scope' {
    $cmd = Get-JkBackgroundCommand -Script 'x' -WaitUntil '2026-10-22T14:00:00'
    Assert-True ($cmd.IndexOf('while') -ge 0 -and $cmd.IndexOf('while') -lt $cmd.IndexOf('Import-Module')) 'waits first'
    Assert-True ((Get-JkBackgroundCommand -Script 'x') -notmatch 'while') 'no wait without -WaitUntil'
    # a real process: due in 2 seconds, then calls a private helper from inside the module
    $flag = Join-Path $env:JK_HOME 'fired.txt'
    $at = (Get-Date).AddSeconds(2).ToString('o', $script:Inv)
    $cmd = Get-JkBackgroundCommand -Script "Set-Content -LiteralPath '$flag' -Value (Get-JkHome)" -WaitUntil $at
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $t = [Diagnostics.Stopwatch]::StartNew()
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc
    Assert-True ($t.Elapsed.TotalSeconds -ge 1.5) "returned after $($t.Elapsed.TotalSeconds)s"
    Assert-Eq (Get-Content -LiteralPath $flag) $env:JK_HOME 'ran in the module scope with JK_HOME passed through'
}
Test 'reopen and grade by title text, including finished items' {
    $d = Get-JkDueData
    $e = @($d.events | Where-Object { $_.title -eq 'A2A Synchronization' })[0]
    Set-JkDueDone 'a2a sync'
    Set-JkDueDone -Undo 'a2a sync'
    Assert-True (-not @((Get-JkDueData).events | Where-Object { $_.id -eq $e.id })[0].done) 'reopened by text'
    Set-JkDueDone 'a2a sync'
    Set-JkGrade 'a2a sync' '9/10'
    Assert-Eq @((Get-JkGradeData).scores | Where-Object { [string]$_.id -eq [string]$e.id })[0].score 90
    Set-JkDueDone -Undo $e.id
    Clear-JkGrade $e.id
}

Write-Host ''
Write-Host 'classes' -ForegroundColor Cyan
Test 'day lists and time ranges' {
    Assert-Eq ((ConvertTo-JkDays 'tue,thu') -join ' ') 'Tue Thu'
    Assert-Eq ((ConvertTo-JkDays 'TTh') -join ' ') 'Tue Thu'
    Assert-Eq ((ConvertTo-JkDays 'MWF') -join ' ') 'Mon Wed Fri'
    Assert-Eq ((ConvertTo-JkDays 'MTWThF') -join ' ') 'Mon Tue Wed Thu Fri'
    Assert-Eq ((ConvertTo-JkDays 'mon/wed') -join ' ') 'Mon Wed'
    Assert-Eq ((ConvertTo-JkDays 'weekdays').Count) 5
    Assert-Eq ((ConvertTo-JkDays 'MoWe') -join ' ') 'Mon Wed'
    Assert-Eq ((ConvertTo-JkDays 'TuTh') -join ' ') 'Tue Thu'
    Assert-Eq ((ConvertTo-JkDays 'Monday,Wednesday') -join ' ') 'Mon Wed'
    Assert-Throws { ConvertTo-JkDays 'someday' }
    $r = ConvertTo-JkTimeRange '4pm-5:20pm'; Assert-Eq "$($r.Start) $($r.End)" '16:00 17:20'
    $r = ConvertTo-JkTimeRange '4-5:20pm'; Assert-Eq "$($r.Start) $($r.End)" '16:00 17:20'
    $r = ConvertTo-JkTimeRange '11:30-12:20pm'; Assert-Eq "$($r.Start) $($r.End)" '11:30 12:20'
    $r = ConvertTo-JkTimeRange '10:00AM - 11:20AM'; Assert-Eq "$($r.Start) $($r.End)" '10:00 11:20'
    $r = ConvertTo-JkTimeRange '16:00-17:20'; Assert-Eq "$($r.Start) $($r.End)" '16:00 17:20'
    Assert-Throws { ConvertTo-JkTimeRange '5pm-4pm' }
}
Test 'Quest list view parsing (continuation rows, tests)' {
    $q = "CS 341 - Algorithms`nClass Nbr`tSection`tComponent`tDays & Times`tRoom`tInstructor`tStart/End Date`n5678`t001`tLEC`tTTh 10:00AM - 11:20AM`tMC 2065`tSome Prof`t09/08/2026 - 12/08/2026`n5680`t051`tTST`tM 7:00PM - 8:50PM`tPAC 1`tTBA`t11/09/2026 - 11/09/2026`nCS 350 - Operating Systems`n6001`t002`tLEC`tMW 4:00PM - 5:20PM`tMC 1056`tProf`t09/08/2026 - 12/08/2026`n`t`t`tF 4:00PM - 4:50PM`tDC 1350`tProf`t09/08/2026 - 12/08/2026"
    $p = ConvertFrom-JkQuestText $q
    Assert-Eq @($p.Classes).Count 3
    Assert-Eq @($p.Tests).Count 1
    $c = @($p.Classes)[2]
    Assert-Eq $c.Course 'CS 350'; Assert-Eq $c.Kind 'LEC'; Assert-Eq (@($c.Days) -join ' ') 'Fri'; Assert-Eq $c.Room 'DC 1350'; Assert-Eq $c.From '2026-09-08'
    Assert-Eq @($p.Tests)[0].Date '2026-11-09'
    # newer Quest day codes and outline.uwaterloo.ca rows
    $p2 = ConvertFrom-JkQuestText "CS 370 - Numerical Computation`n7001`t001`tLEC`tTuTh 1:00PM - 2:20PM`tDC 1351`tProf`t09/08/2026 - 12/08/2026`nSTAT 341 002 [LEC] Monday, Wednesday - 02:30PM - 03:50PM EIT 1015 Some Prof prof@uwaterloo.ca"
    Assert-Eq @($p2.Classes).Count 2
    Assert-Eq (@(@($p2.Classes)[0].Days) -join ' ') 'Tue Thu'
    $o = @($p2.Classes)[1]
    Assert-Eq "$($o.Course) $($o.Kind) $(@($o.Days) -join ',') $($o.Start)-$($o.End) $($o.Room)" 'STAT 341 LEC Mon,Wed 14:30-15:50 EIT 1015'
}
Test 'meetings skip breaks and holidays; next class' {
    Add-JkClass cs350 @('tue', 'thu') '8:30am-9:50am' 'MC 2017'
    Add-JkClass cs350 mon '4-5:20pm' 'MC 1056' -From sep 9
    Assert-Eq @(Get-JkClassesOn ([datetime]'2026-10-22')).Count 1 'Thu Oct 22 has the TTh class'
    Assert-Eq @(Get-JkClassesOn ([datetime]'2026-10-13')).Count 0 'reading week'
    Assert-Eq @(Get-JkClassesOn ([datetime]'2026-12-15')).Count 0 'after classes end'
    $n = Get-JkNextClass ([datetime]'2026-10-22T09:00')
    Assert-Eq $n.Start.ToString('MM-dd HH:mm') '10-22 08:30' 'in progress counts as next'
    $n = Get-JkNextClass ([datetime]'2026-10-22T10:00')
    Assert-Eq $n.Start.ToString('MM-dd HH:mm') '10-26 16:00'
    Show-JkClasses; Show-JkTimetable; Show-JkClassList
}

Test 'section catalog: pick adds meetings, skips duplicates, flags clashes' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'pick-home'
    try {
        Import-JkDueHtml $htmlPath
        $mk = { param($course, $kind, $section, $days, $start, $end, $room) [pscustomobject]@{ course = $course; kind = $kind; section = $section; days = @($days); start = $start; end = $end; room = $room } }
        Save-JkJson 'sections.json' ([pscustomobject]@{ items = @(
                    (& $mk 'cs350' 'LEC' '001' @('Tue', 'Thu') '10:00' '11:20' 'MC 4040'),
                    (& $mk 'cs350' 'LEC' '002' @('Tue', 'Thu') '13:00' '14:20' 'MC 4040'),
                    (& $mk 'health' 'LEC' '081' @('Tue') '10:30' '11:00' 'online')) })
        Select-JkSections cs350 1
        Select-JkSections cs350 001
        $items = @((Get-JkClassData).items)
        Assert-Eq $items.Count 1 'second pick of the same section is skipped'
        Assert-Eq "$($items[0].start)-$($items[0].end) $($items[0].room)" '10:00-11:20 MC 4040'
        Assert-True (Test-JkClassOverlap $items[0] ([pscustomobject]@{ days = @('Tue'); start = '10:30'; end = '11:00' })) 'overlap detected'
        Assert-True (-not (Test-JkClassOverlap $items[0] ([pscustomobject]@{ days = @('Wed'); start = '10:30'; end = '11:00' }))) 'different day is no clash'
        Assert-Throws { Select-JkSections cs350 009 }
        Assert-Throws { Select-JkSections cs350 health 081 }
        $one = (Select-JkSections cs350 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($one -match 'LEC 002' -and $one -notmatch 'LEC 081') 'one course shows only its sections'
        Assert-True ($one -match 'jk class pick cs350 \d{3} ') 'and an example for that course'
        Show-JkSectionCatalog
        # the interactive prompt: answers are read one course and kind at a time
        Assert-True (-not (Test-JkInteractive)) 'tests never prompt'
        $script:Answers = New-Object System.Collections.Generic.Queue[string]
        foreach ($x in @('7', '81')) { $script:Answers.Enqueue($x) }
        function script:Read-Host { param($Prompt) $script:Prompts += , [string]$Prompt; $script:Answers.Dequeue() }
        $script:Prompts = @()
        try {
            $pairs = @(Read-JkSectionPicks)
            Assert-Eq ($pairs -join ' ') 'health 081' 'a wrong number is asked again; cs350 is already picked'
            Assert-Eq $script:Prompts.Count 2
            Assert-True ($script:Prompts[0] -match 'HEALTH.*LEC \(081\)') "prompt: $($script:Prompts[0])"
            # jk class pick <course> asks about that course alone
            $script:Answers.Enqueue('81'); $script:Prompts = @()
            Assert-Eq (@(Read-JkSectionPicks -Course health) -join ' ') 'health 081'
            Assert-Eq $script:Prompts.Count 1 'one question, for that course'
            Assert-Eq @(Read-JkSectionPicks -Course cs350).Count 0 'a course already on the timetable is not asked about'
        } finally { Remove-Item function:script:Read-Host }
    } finally { $env:JK_HOME = $saved }
}

Write-Host ''
Write-Host 'study plan' -ForegroundColor Cyan
Test 'plan items: weights to effort, exam windows once, focus subtracts' {
    $items = @(Get-JkPlanItems -Now ([datetime]'2026-10-22T14:00'))
    $mid = @($items | Where-Object { $_.Course -eq 'health' -and $_.Title -eq 'Midterm' })
    Assert-Eq $mid.Count 1 'opens/closes pair is one item'
    Assert-Eq $mid[0].Due.ToString('MM-dd HH:mm') '10-26 06:00' 'prepare for the opening'
    Assert-Eq $mid[0].Effort (30 * 15) 'exam: 30% x 15 min'
    $a2a = @($items | Where-Object { $_.Title -eq 'A2A Synchronization' })[0]
    Assert-Eq $a2a.Effort (8 * 30) 'assignment: 8% x 30 min'
    $fd = Get-JkFocusData
    $fd.sessions = @($fd.sessions) + [pscustomobject]@{ label = 'cs350 a2a'; start = '2026-10-21T19:00:00'; planned = 60; actual = 60; completed = $true }
    Save-JkFocusData $fd
    $items2 = @(Get-JkPlanItems -Now ([datetime]'2026-10-22T14:00'))
    $cs350 = @($items2 | Where-Object { $_.Course -eq 'cs350' })
    $doneSum = ($cs350 | Measure-Object -Property Done -Sum).Sum
    Assert-Eq ([Math]::Round($doneSum)) 60 'logged focus is shared across the course items'
}
Test 'plan schedule: nothing after due, soon items get a block, budget respected' {
    $now = [datetime]'2026-10-22T09:00'
    $items = @(Get-JkPlanItems -Now $now)
    $sched = @(Get-JkPlanSchedule -Items $items -Now $now -Days 7 -BudgetMin 180)
    foreach ($s in $sched) {
        $sum = 0; foreach ($v in $s.Alloc.Values) { $sum += $v }
        Assert-True ($sum -le 180 + 25 * $items.Count) "day $($s.Day.ToString('MM-dd')) way over budget: $sum"
        foreach ($k in $s.Alloc.Keys) {
            $it = @($items | Where-Object { $_.Key -eq $k })[0]
            Assert-True ($s.Day -le $it.Due.Date) "$($it.Title) scheduled after its due date"
            if ($s.Day -eq $it.Due.Date) { Assert-True ($it.Due.Hour -ge 18) "$($it.Title) scheduled on the morning it is due" }
        }
    }
    $mid = @($items | Where-Object { $_.Course -eq 'health' -and $_.Title -eq 'Midterm' })[0]
    $sunday = @($sched | Where-Object { $_.Day -eq [datetime]'2026-10-25' })[0]
    Assert-True ($sunday.Alloc[$mid.Key] -ge 25) 'the day before the midterm gets at least one block'
    Show-JkPlan
}

Write-Host ''
Write-Host 'calendar feed sync' -ForegroundColor Cyan
$feedText = @(
    'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//D2L//LEARN//EN',
    'BEGIN:VEVENT', 'UID:d2l-1001', 'SUMMARY:Assignment 4 - Due',
    'DESCRIPTION:CS 350 - Operating Systems (Fall 2026)\, see LEARN', 'DTSTART:20261202T010000Z', 'DTEND:20261202T010000Z',
    'BEGIN:VALARM', 'DESCRIPTION:this alarm text must not replace the event description', 'TRIGGER:-PT15M', 'END:VALARM',
    'END:VEVENT',
    'BEGIN:VEVENT', 'UID:d2l-1002', 'SUMMARY:CS 341: Midterm 3 - Due', 'DTSTART;TZID=America/Toronto:20261130T190000',
    'DTEND;TZID=America/Toronto:20261130T205000', 'LOCATION:PAC 1', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:d2l-1003', 'SUMMARY:STAT 231 Project proposal - Due with a very long title that the server', ' folds onto a second line', 'DTSTART;VALUE=DATE:20261204', 'DTEND;VALUE=DATE:20261205', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:d2l-1004', 'SUMMARY:Quiz 7 - Availability Starts', 'DTSTART:20261110T130000Z', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:d2l-1005', 'SUMMARY:CO 367 LEC', 'DTSTART:20261027T083000', 'DTEND:20261027T095000', 'RRULE:FREQ=WEEKLY;BYDAY=TU,TH', 'END:VEVENT',
    'BEGIN:VEVENT', 'UID:d2l-1006', 'SUMMARY:Old thing - Due', 'DTSTART:20250101T120000Z', 'END:VEVENT',
    'END:VCALENDAR') -join "`r`n"
# Expected local time for a Toronto wall-clock time, whatever zone the test machine is in.
function global:Get-TorontoAsLocal([string]$When) {
    $t = [datetime]::ParseExact($When, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    [TimeZoneInfo]::ConvertTime($t, [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time'), [TimeZoneInfo]::Local)
}
Test 'ics parsing: folding, alarms, time zones, all-day, recurrence' {
    $evs = @(ConvertFrom-JkIcs $feedText)
    Assert-Eq $evs.Count 6
    Assert-Eq $evs[0].Description 'CS 350 - Operating Systems (Fall 2026), see LEARN' 'alarm text kept out, \, unescaped'
    Assert-Eq ($evs[1].Start.When.ToString('yyyy-MM-dd HH:mm')) ((Get-TorontoAsLocal '2026-11-30 19:00').ToString('yyyy-MM-dd HH:mm')) 'TZID America/Toronto converted to local'
    $z = [datetime]::SpecifyKind([datetime]'2026-12-02 01:00', 'Utc').ToLocalTime()
    Assert-Eq ($evs[0].Start.When.ToString('yyyy-MM-dd HH:mm')) ($z.ToString('yyyy-MM-dd HH:mm')) 'UTC converted to local'
    Assert-True $evs[2].Start.AllDay
    Assert-True $evs[2].Summary.EndsWith('folds onto a second line') 'folded line joined'
    Assert-True $evs[4].Recurring
    $utc = $evs[0].Start.When
    Assert-Eq $utc.Kind 'Local' 'UTC times converted to local'
}
Test 'sync: course detection, cleanup, skip rules, idempotent re-sync, moved dates' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'sync-home'
    try {
        $f = Join-Path $saved 'feed.ics'
        [IO.File]::WriteAllText($f, $feedText)
        Invoke-JkDueSync $f
        $d = Get-JkDueData
        Assert-Eq @($d.events).Count 3 'starts marker, weekly class and the year-old item are skipped'
        $a4 = @($d.events | Where-Object { [string]$_.uid -eq 'd2l-1001' })[0]
        Assert-Eq $a4.course 'cs350' 'course found in the description'
        Assert-Eq $a4.title 'Assignment 4'
        $m3 = @($d.events | Where-Object { [string]$_.uid -eq 'd2l-1002' })[0]
        $m3when = Get-TorontoAsLocal '2026-11-30 19:00'
        Assert-Eq "$($m3.course) $($m3.title) $($m3.kind) $($m3.date) $($m3.time)" "cs341 Midterm 3 exam $($m3when.ToString('yyyy-MM-dd')) $($m3when.ToString('HH:mm'))"
        $p = @($d.events | Where-Object { [string]$_.uid -eq 'd2l-1003' })[0]
        Assert-Eq "$($p.course) $($p.time)" 'stat231 ' 'new course created; all-day has no time'
        Set-JkDueDone $a4.id
        Invoke-JkDueSync $f
        Assert-Eq @((Get-JkDueData).events).Count 3 're-sync adds nothing'
        [IO.File]::WriteAllText($f, $feedText.Replace('20261130T190000', '20261201T190000'))
        Invoke-JkDueSync $f
        $d2 = Get-JkDueData
        Assert-Eq @($d2.events | Where-Object { [string]$_.uid -eq 'd2l-1002' })[0].date ((Get-TorontoAsLocal '2026-12-01 19:00').ToString('yyyy-MM-dd')) 'moved date updated in place'
        Assert-True @($d2.events | Where-Object { [string]$_.uid -eq 'd2l-1001' })[0].done 'done mark survives a sync'
        # your own edits survive re-syncs until the feed changes that item
        $proj = @($d2.events | Where-Object { [string]$_.uid -eq 'd2l-1003' })[0]
        Edit-JkDue $proj.id -Time 5pm -Title 'Proposal (renamed by me)'
        [IO.File]::WriteAllText($f, $feedText.Replace('20261130T190000', '20261201T190000'))
        Invoke-JkDueSync $f
        $p2 = @((Get-JkDueData).events | Where-Object { [string]$_.uid -eq 'd2l-1003' })[0]
        Assert-Eq "$($p2.title) $($p2.time)" 'Proposal (renamed by me) 17:00' 'unchanged feed keeps your edits'
        [IO.File]::WriteAllText($f, $feedText.Replace('20261130T190000', '20261201T190000').Replace('DTSTART;VALUE=DATE:20261204', 'DTSTART;VALUE=DATE:20261206'))
        Invoke-JkDueSync $f
        $p3 = @((Get-JkDueData).events | Where-Object { [string]$_.uid -eq 'd2l-1003' })[0]
        Assert-Eq $p3.date '2026-12-06' 'a moved date in the feed still wins'
        Assert-Throws { Invoke-JkDueSync (Join-Path $saved 'nope.ics') }
    } finally { $env:JK_HOME = $saved }
}
Test 'feed links are recognised on the clipboard or in a paste' {
    Assert-Eq (Find-JkFeedLink '  "https://learn.uwaterloo.ca/d2l/le/calendar/feed/user/feed.ics?token=abc"  ') 'https://learn.uwaterloo.ca/d2l/le/calendar/feed/user/feed.ics?token=abc'
    Assert-Eq (Find-JkFeedLink 'webcal://example.test/x') 'webcal://example.test/x'
    Assert-Eq (Find-JkFeedLink 'https://example.test/cal/term.ics') 'https://example.test/cal/term.ics'
    Assert-True ($null -eq (Find-JkFeedLink 'https://github.com/abcdefgJack/jk')) 'an ordinary page is not a feed'
    Assert-True ($null -eq (Find-JkFeedLink 'see https://x.test/feed.ics for details')) 'only a bare link counts'
    Assert-True ($null -eq (Find-JkFeedLink '')) 'empty'
    # with no saved feed and prompts off, the error explains where to get the link
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'nofeed-home'
    $script:JkConfigCache = $null
    try {
        $msg = ''
        try { Invoke-JkDueSync } catch { $msg = $_.Exception.Message }
        Assert-True ($msg -match 'Calendar > Subscribe') "error: $msg"
    } finally { $env:JK_HOME = $saved; $script:JkConfigCache = $null }
}
Test 'sync round trip: jk''s own ics export reproduces the deadlines' {
    $saved = $env:JK_HOME
    $out = Join-Path $saved 'roundtrip.ics'
    Export-JkDueIcs -Out $out -NoClasses
    $orig = @((Get-JkDueData).events | Where-Object { -not $_.done -and (Get-JkEventDue $_) -ge (Get-JkNow).Date.AddDays(-7) })
    $env:JK_HOME = Join-Path $saved 'roundtrip-home'
    try {
        Import-JkDueHtml $htmlPath | Out-Null
        $d = Get-JkDueData
        $d.events = @(); Save-JkDueData $d
        Invoke-JkDueSync $out
        $back = @((Get-JkDueData).events)
        Assert-Eq $back.Count $orig.Count 'same number of items'
        foreach ($o in $orig) {
            $b = @($back | Where-Object { $_.course -eq $o.course -and $_.title -eq $o.title })
            Assert-Eq $b.Count 1 "found $($o.course) $($o.title)"
            Assert-Eq "$($b[0].date) $($b[0].time) $($b[0].weight)" "$($o.date) $($o.time) $($o.weight)" "$($o.title)"
        }
    } finally { $env:JK_HOME = $saved }
}

Write-Host ''
Write-Host 'grades' -ForegroundColor Cyan
Test 'percent parsing' {
    Assert-Eq (ConvertTo-JkPercent '17/20') 85
    Assert-Eq (ConvertTo-JkPercent '85%') 85
    Assert-Eq (ConvertTo-JkPercent '92.5') 92.5
    Assert-Throws { ConvertTo-JkPercent 'A+' }
}
Test 'weighted average, opens/closes counted once, best-k-of-n rule' {
    $d = Get-JkDueData
    $ev = { param($t) @($d.events | Where-Object { $_.course -eq 'health' -and $_.title -eq $t })[0].id }
    Set-JkGrade (& $ev 'Assignment 1') 100
    Set-JkGrade (& $ev 'Assignment 2') 40
    Set-JkGrade (& $ev 'Assignment 3') 80
    Set-JkGrade (& $ev 'Midterm opens') '27/30'
    $items = Get-JkGradeItems (Get-JkDueData) (Get-JkGradeData) 'health'
    Assert-Eq @($items | Where-Object { $_.Title -eq 'Midterm' }).Count 1 'midterm window counts once'
    $rules = @(Get-JkGradeRules (Get-JkDueData) 'health')
    Assert-Eq $rules[0].Keep 2
    $m = Measure-JkGrade $items $rules
    # best 2 of 3 assignments: 100 and 80 at 10% each = 18; midterm 90% of 30 = 27 -> 45 of 50
    Assert-Eq ([Math]::Round($m.Banked, 2)) 45
    Assert-Eq $m.Graded 50
    Assert-Eq ([Math]::Round($m.Average, 2)) 90
    Assert-Eq $m.Remaining 0
    Assert-Eq $m.Dropped.Count 1
}
Test 'needed-on-the-rest math' {
    $m = [pscustomobject]@{ Banked = 27.0; Graded = 30.0; Remaining = 70.0 }
    Assert-Eq (Get-JkNeededText 80 $m)[0] '76%'
    Assert-Eq (Get-JkNeededText 20 $m)[0] 'locked in'
    Assert-Eq (Get-JkNeededText 95 $m)[1] 'orange'
    Assert-Eq (Get-JkNeededText 99 $m)[1] 'red' 'needs more than 100%'
    Show-JkGrade cs350; Show-JkGradeOverview
}

Write-Host ''
Write-Host 'to-do' -ForegroundColor Cyan
Test 'add, due parsing, done, clear renumbers' {
    Add-JkTodo email the TA -Due 'tomorrow 5pm'
    Add-JkTodo buy ink -Due fri 6pm
    Add-JkTodo read chapter 4
    $t = Get-JkTodoData
    Assert-Eq @($t.items).Count 3
    Assert-Eq (@($t.items)[1].text) 'buy ink' 'trailing time moved to -Due'
    Assert-Eq (Get-JkTodoDue @($t.items)[1]).ToString('MM-dd HH:mm') '10-23 18:00'
    Set-JkTodoDone 1
    Clear-JkTodo
    $t = Get-JkTodoData
    Assert-Eq @($t.items).Count 2
    Assert-Eq (@($t.items | Sort-Object id)[0].id) 1 'renumbered'
    Show-JkTodo
}

Write-Host ''
Write-Host 'competitive programming helpers' -ForegroundColor Cyan
Test 'token comparison with float tolerance' {
    Assert-True (Compare-JkOutput "3`n1 2" "3 1 2`n").Ok
    Assert-True (Compare-JkOutput '0.3333333' '0.33333334').Ok
    Assert-True (-not (Compare-JkOutput '0.333' '0.334').Ok)
    Assert-True (Compare-JkOutput '10' '1e1').Ok 'numeric 1e1 equals 10'
    $r = Compare-JkOutput '1 2 3' '1 2'
    Assert-True (-not $r.Ok); Assert-Eq $r.Index 2; Assert-Eq $r.Got '<end of output>'
    Assert-True (-not (Compare-JkOutput 'YES' 'yes').Ok) 'case sensitive'
}
Test 'argument quoting for process start' {
    Assert-Eq (Join-JkArgs @('a', 'b c', '')) 'a "b c" ""'
    Assert-Eq (Join-JkArgs @('C:\x y\')) '"C:\x y\\"'
}
Test 'source discovery prefers main over brute/gen' {
    $dir = Join-Path $env:JK_HOME 'cp-disc'
    New-Item -ItemType Directory $dir -Force | Out-Null
    foreach ($n in 'brute.cpp', 'gen.py', 'main.cpp') { Set-Content (Join-Path $dir $n) '' }
    Assert-Eq (Get-JkCpSource -Dir $dir).Name 'main.cpp'
    Assert-Eq (Find-JkCpHelper 'brute|naive' $dir).Name 'brute.cpp'
}
Test 'cp add: clipboard to numbered samples, CRLF normalized, empty template reused' {
    $dir = Join-Path $env:JK_HOME 'cp-add'
    New-Item -ItemType Directory $dir -Force | Out-Null
    Set-Content (Join-Path $dir '1.in') -Value '' -NoNewline
    Push-Location $dir
    try {
        function script:Get-JkClipboardText { $script:FakeClip }
        $script:FakeClip = "3`r`n1 2 3`r`n"; Add-JkCpTest -In
        $script:FakeClip = '6'; Add-JkCpTest -Out
        $script:FakeClip = "2`r`n10 20"; Add-JkCpTest -In
        Assert-Eq ([IO.File]::ReadAllText((Join-Path $dir '1.in'))) "3`n1 2 3`n"
        Assert-Eq ([IO.File]::ReadAllText((Join-Path $dir '1.out'))) "6`n"
        Assert-Eq ([IO.File]::ReadAllText((Join-Path $dir '2.in'))) "2`n10 20`n"
        $script:FakeClip = '   '
        Assert-Throws { Add-JkCpTest -In } 'empty clipboard is rejected'
    } finally { Pop-Location }
}
if (Get-Command g++ -ErrorAction SilentlyContinue) {
    Test 'compile, run, PASS/WA/RTE end to end (g++)' {
        $dir = Join-Path $env:JK_HOME 'cp-e2e'
        New-Item -ItemType Directory $dir -Force | Out-Null
        Set-Content (Join-Path $dir 'main.cpp') "#include <bits/stdc++.h>`nint main(){ long long a,b; std::cin>>a>>b; if(a<0){ int* p=nullptr; *p=1; } std::cout<<a+b<<std::endl; }" -Encoding ascii
        Set-Content (Join-Path $dir '1.in') '1 2'; Set-Content (Join-Path $dir '1.out') '3'
        $src = Get-Item (Join-Path $dir 'main.cpp')
        $run = Build-JkCp $src -Quiet
        $r = Invoke-JkProcess -Exe $run.Exe -InputText "40 2`n" -WorkDir $dir
        Assert-Eq $r.Out.Trim() '42' 'stdin must arrive without a BOM'
        $r = Invoke-JkProcess -Exe $run.Exe -InputText "-1 2`n" -WorkDir $dir -TimeoutMs 5000
        Assert-Eq $r.Code -1073741819 'access violation reported, not a hang'
        Assert-True ($r.Ms -lt 4000) 'crash must not wait for Windows Error Reporting'
        Assert-True ($r.PeakMB -gt 0) 'peak memory measured'
        $again = Build-JkCp $src -Quiet
        Assert-True (-not $again.Compiled) 'second build hits the cache'
    }
}

Write-Host ''
Write-Host 'files, folders, misc' -ForegroundColor Cyan
Test 'battery wear: design capacity from the battery report, health in plain words' {
    $xml = '<?xml version="1.0" encoding="utf-8"?><BatteryReport xmlns="http://schemas.microsoft.com/battery/2012"><Batteries><Battery><Id>BIF0_9</Id><DesignCapacity>52007</DesignCapacity><FullChargeCapacity>33676</FullChargeCapacity></Battery></Batteries></BatteryReport>'
    Assert-Eq (ConvertFrom-JkBatteryReport $xml) 52007
    Assert-Eq (ConvertFrom-JkBatteryReport ($xml -replace '</Batteries>', '<Battery><DesignCapacity>1000</DesignCapacity></Battery></Batteries>')) 53007 'two batteries add up'
    $f = @(Format-JkBatteryHealth ([pscustomobject]@{ Design = 52007; Full = 33676; Health = 33676 / 52007 }))
    Assert-Eq $f[0] 'health 65% (holds 33.7 of 52.0 Wh)'
    Assert-True ($f[1] -match 'about 65% as long') 'a worn battery says what that means'
    Assert-Eq (@(Format-JkBatteryHealth ([pscustomobject]@{ Design = 50000; Full = 45000; Health = 0.9 }))[1]) '' 'a healthy one says nothing more'
}
Test 'tidy categories and collision-free names' {
    Assert-Eq (Get-JkTidyCategory '.EXE') 'Installers'
    Assert-Eq (Get-JkTidyCategory '.pdf') 'PDFs'
    Assert-Eq (Get-JkTidyCategory '.weird') 'Other'
    $dir = Join-Path $env:JK_HOME 'uniq'
    New-Item -ItemType Directory $dir -Force | Out-Null
    Set-Content (Join-Path $dir 'a.pdf') 'x'
    Assert-Eq (Split-Path (Get-JkUniquePath $dir 'a.pdf') -Leaf) 'a (2).pdf'
    Assert-Eq (Split-Path (Get-JkUniquePath $dir 'b.pdf') -Leaf) 'b.pdf'
}
Test 'tidy apply + undo round-trips exactly' {
    $dir = Join-Path $env:JK_HOME 'dl'
    New-Item -ItemType Directory $dir -Force | Out-Null
    foreach ($n in 'x.pdf', 'y.exe', 'z.jpg', 'page.html', 'keep.crdownload') { Set-Content (Join-Path $dir $n) $n }
    New-Item -ItemType Directory (Join-Path $dir 'page_files') | Out-Null
    Set-Content (Join-Path $dir 'page_files\s.css') 'css'
    Get-ChildItem $dir -File | ForEach-Object { $_.LastWriteTime = (Get-Date).AddDays(-10) }
    $before = (Get-ChildItem $dir -Recurse | ForEach-Object { $_.FullName.Substring($dir.Length) } | Sort-Object) -join '|'
    Invoke-JkTidyRun $dir -Apply
    Assert-True (Test-Path (Join-Path $dir 'PDFs\x.pdf'))
    Assert-True (Test-Path (Join-Path $dir 'Web\page_files\s.css')) 'saved page keeps its _files folder'
    Assert-True (Test-Path (Join-Path $dir 'keep.crdownload')) 'partial downloads stay put'
    Undo-JkTidy
    $after = (Get-ChildItem $dir -Recurse | ForEach-Object { $_.FullName.Substring($dir.Length) } | Sort-Object) -join '|'
    Assert-Eq $after $before
}
Test 'tidy files course downloads into their course folders, and undo brings them back' {
    $top = Join-Path $env:JK_HOME 'courses'
    $coll = Join-Path $top 'Waterloo course'
    foreach ($d in 'CS245', 'Stat 230', 'CS341', 'CO367\materials') { New-Item -ItemType Directory (Join-Path $coll $d) -Force | Out-Null }
    Set-Content (Join-Path $coll 'CO367\materials\CO367_A1.pdf') 'filed'
    $dl = Join-Path $top 'dl'
    New-Item -ItemType Directory $dl -Force | Out-Null
    foreach ($n in 'CS245-F25-A05.pdf', 'STAT_230_002_27.pdf', 'cs341piazza__Lab_1.pdf', 'CS234_A3.md', 'cs245 vs cs341.pdf', 'notes.pdf') { Set-Content (Join-Path $dl $n) $n }
    Set-Content (Join-Path $dl 'CO367_A1.pdf') 'filed'   # same name and size as the copy already filed
    Get-ChildItem $dl -File | ForEach-Object { $_.LastWriteTime = (Get-Date).AddDays(-10) }
    Set-JkConfig 'tidy.courses' $top
    try {
        $folders = Get-JkCourseFolders
        Assert-Eq (($folders.Keys | Sort-Object) -join ',') 'co367,cs245,cs341,stat230'
        Assert-Eq (Get-JkFileCourse 'cs341piazza__Lab_1.pdf' $folders) 'cs341' 'a glued-on letter falls back to the number'
        Assert-Eq (Get-JkFileCourse 'STAT231W26Lec003Slides.pdf' $folders) '' 'no folder for stat231'
        Assert-Eq (Get-JkFileCourse 'cs245 vs cs341.pdf' $folders) '' 'two courses: left to the categories'
        $dl = Resolve-JkLongPath $dl
        $coll = Resolve-JkLongPath $coll
        $before = (Get-ChildItem $top -Recurse | ForEach-Object { $_.FullName.Substring($top.Length) } | Sort-Object) -join '|'
        Invoke-JkTidyRun $dl -Apply
        Assert-True (Test-Path (Join-Path $coll 'CS245\CS245-F25-A05.pdf'))
        Assert-True (Test-Path (Join-Path $coll 'Stat 230\STAT_230_002_27.pdf'))
        Assert-True (Test-Path (Join-Path $coll 'CS341\cs341piazza__Lab_1.pdf'))
        Assert-True (Test-Path (Join-Path $dl 'PDFs\CO367_A1.pdf')) 'an already-filed copy goes with the rest'
        Assert-True (Test-Path (Join-Path $dl 'PDFs\cs245 vs cs341.pdf'))
        Assert-True (Test-Path (Join-Path $dl 'Documents\CS234_A3.md'))
        Undo-JkTidy
        $after = (Get-ChildItem $top -Recurse | ForEach-Object { $_.FullName.Substring($top.Length) } | Sort-Object) -join '|'
        Assert-Eq $after $before 'undo restores Downloads and leaves the emptied course folders in place'
    } finally { Set-JkConfig 'tidy.courses' '' }
}
Test 'duplicate detection keeps the clean name' {
    $dir = Join-Path $env:JK_HOME 'dupes'
    New-Item -ItemType Directory $dir -Force | Out-Null
    Set-Content (Join-Path $dir 'notes.pdf') 'same'; Set-Content (Join-Path $dir 'notes (1).pdf') 'same'; Set-Content (Join-Path $dir 'other.pdf') 'diff'
    $g = @(Get-JkDuplicateGroups (Get-ChildItem $dir -File))
    Assert-Eq $g.Count 1
    Assert-Eq $g[0].Keep.Name 'notes.pdf'
}
Test 'folder size via robocopy list mode (no exit-code leak)' {
    $dir = Join-Path $env:JK_HOME 'sizeprobe'
    New-Item -ItemType Directory (Join-Path $dir 'sub') -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $dir 'a.bin'), (New-Object byte[] 1000))
    [IO.File]::WriteAllBytes((Join-Path $dir 'sub\b.bin'), (New-Object byte[] 2345))
    $s = Get-JkFolderSize $dir
    Assert-Eq $s.Bytes 3345
    Assert-Eq $s.Files 2
    Assert-Eq $global:LASTEXITCODE 0
    Assert-Eq (Get-JkFolderSize (Join-Path $dir 'missing')) $null
    Assert-Eq (Get-JkFolderSize (Join-Path $dir 'a.bin')).Bytes 1000
}
Test 'jk leaves $LASTEXITCODE as it found it' {
    # doctor runs g++/python/javac/git --version; none of that may surface as a failed command
    $global:LASTEXITCODE = 0
    $null = jk doctor 6>&1
    Assert-Eq $global:LASTEXITCODE 0
    cmd /c exit 7
    $null = jk help 6>&1
    Assert-Eq $global:LASTEXITCODE 7
    $global:LASTEXITCODE = 0
}
Test 'jk find: every word in the name or folders, best first, skipping deps and links' {
    $top = Join-Path $env:JK_HOME 'findroot'
    $a3 = Join-Path $top 'Waterloo course\CO250\A3'
    foreach ($d in $a3, (Join-Path $top 'CS350'), (Join-Path $top 'proj\node_modules\pkg'), (Join-Path $top '.git')) { New-Item -ItemType Directory $d -Force | Out-Null }
    foreach ($f in "$a3\co250_a3.pdf", "$a3\a3_notes.txt", "$a3\data3.csv", "$top\CS350\a2a.pdf", "$top\CS350\a2a.aux", "$top\proj\node_modules\pkg\co250_a3.pdf", "$top\.git\co250_a3.pdf") { Set-Content -LiteralPath $f 'x' }
    # a junction back into the tree must not list its files twice
    $null = New-Item -ItemType Junction -Path (Join-Path $top 'link') -Target (Join-Path $top 'Waterloo course')
    # results carry long paths; TEMP may be an 8.3 one (JACKWA~1)
    $top = Resolve-JkLongPath $top
    $a3 = Join-Path $top 'Waterloo course\CO250\A3'
    $hits = @(Find-JkFiles @('co250', 'a3') @($top))
    Assert-Eq (($hits | ForEach-Object { $_.Name }) -join ',') 'co250_a3.pdf,a3_notes.txt,data3.csv'
    Assert-Eq $hits[0].Folder 'findroot\Waterloo course\CO250\A3'
    # the type word keeps just that type; LaTeX by-products rank after the real file
    Assert-Eq ((@(Find-JkFiles @('co250', 'pdf') @($top)) | ForEach-Object { $_.Name }) -join ',') 'co250_a3.pdf'
    Assert-Eq ((@(Find-JkFiles @('a2a') @($top)) | ForEach-Object { $_.Name }) -join ',') 'a2a.pdf,a2a.aux'
    Assert-Eq @(Find-JkFiles @('nothing-like-this') @($top)).Count 0

    # the list remembers its results: -p <n> prints one, a bad number says how many there were
    Set-JkConfig 'find.roots' $top
    $null = Invoke-JkFind co250 a3
    # jk find -o <Tab> offers those results by number, showing each name
    $tab = @(Get-JkCompletions -Word '' -Tokens @('jk', 'find', '-o'))
    Assert-Eq (($tab | ForEach-Object { $_.CompletionText }) -join ',') '1,2,3'
    Assert-Eq $tab[1].ListItemText '2  a3_notes.txt'
    Assert-Eq $tab[1].ToolTip "$a3\a3_notes.txt"
    Assert-Eq (@(Get-JkCompletions -Word '3' -Tokens @('jk', 'find', '-e', '3')) | ForEach-Object { $_.CompletionText }) '3'
    Assert-Eq (Invoke-JkFind -p 2) "$a3\a3_notes.txt"
    Assert-Throws { Invoke-JkFind -p 7 }
    # with words, -p prints the best match and keeps the list for -p <n>
    Assert-Eq (Invoke-JkFind a2a -p) "$top\CS350\a2a.pdf"
    Assert-Eq (Invoke-JkFind -p 2) "$top\CS350\a2a.aux"
    Assert-Throws { Invoke-JkFind -o }
    Set-JkConfig 'find.roots' ''
    Remove-Item -LiteralPath (Join-Path $top 'link') -Force -Recurse
}
Test 'jk recent: files changed since a cut-off, newest first, without lock files and by-products' {
    $top = Join-Path $env:JK_HOME 'recentroot'
    New-Item -ItemType Directory (Join-Path $top 'notes') -Force | Out-Null
    $now = Get-Date
    # minutes ago
    $files = [ordered]@{ 'notes\new.md' = 1; 'notes\older.pdf' = 30; 'notes\~$draft.docx' = 2; 'notes\paper.aux' = 2; 'stale.txt' = 7200 }
    foreach ($k in $files.Keys) { $p = Join-Path $top $k; Set-Content -LiteralPath $p 'x'; (Get-Item -LiteralPath $p).LastWriteTime = $now.AddMinutes(-$files[$k]) }
    $hits = @(Find-JkFiles @() @($top) -Since $now.AddDays(-2) | Where-Object { -not (Test-JkRecentNoise $_) } | Sort-Object Modified -Descending)
    Assert-Eq (($hits | ForEach-Object { $_.Name }) -join ',') 'new.md,older.pdf'
    Assert-Eq @(Find-JkFiles @() @($top)).Count 0 'no words and no cut-off finds nothing'
    Set-JkConfig 'find.roots' $top
    try {
        $out = (Invoke-JkRecent 2 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($out -match '2 files') "header: $out"
        Assert-Eq (Split-Path (Invoke-JkFind -p 1) -Leaf) 'new.md' 'jk find -p 1 uses the recent list'
        Assert-Throws { Invoke-JkRecent 0 }
    } finally { Set-JkConfig 'find.roots' '' }
}
Test 'jk clip: unwraps PDF text and counts words the way a word limit does' {
    $pdf = @(
        'The gradient method is one of the simplest and most widely used optimi-',
        'zation algorithms. At each step it moves along the negative gradient of',
        'the objective, which is the steepest descent direction.',
        'It needs a step size.',
        '- choose a starting point x0 and a tolerance for the stopping rule here',
        '- repeat until the norm of the gradient is small (see the COVID-',
        '19 example and the Hartree-',
        'Fock one)',
        '',
        '',
        'A new paragraph after blank lines.'
    ) -join "`r`n"
    $r = ConvertFrom-JkWrappedText $pdf
    $want = @(
        'The gradient method is one of the simplest and most widely used optimization algorithms. At each step it moves along the negative gradient of the objective, which is the steepest descent direction. It needs a step size.',
        '- choose a starting point x0 and a tolerance for the stopping rule here',
        '- repeat until the norm of the gradient is small (see the COVID-19 example and the Hartree-Fock one)',
        '',
        'A new paragraph after blank lines.'
    ) -join "`n"
    Assert-Eq $r.Text $want
    Assert-Eq "$($r.Mended) $($r.Paragraphs)" '1 4'
    # Chinese lines join without a space
    $zh = ([string][char]0x8FD9 + [char]0x662F + [char]0x88AB) + "`n" + ([string][char]0x6362 + [char]0x884C + [char]0x3002)
    Assert-Eq (ConvertFrom-JkWrappedText $zh).Text ($zh -replace "`n", '')
    $m = Measure-JkText "Hello world, it's 2026.`n$zh"
    Assert-Eq "$($m.Words) $($m.Cjk) $($m.Lines)" '4 5 3'
}
Test 'jk due files: the course folder''s files named after a deadline' {
    Assert-Eq ((Get-JkTitleFileTokens 'Assignment 2') -join ',') 'a2,a02,assignment 2,hw2,asst2'
    Assert-Eq ((Get-JkTitleFileTokens 'A2A Synchronization') -join ',') 'a2a'
    Assert-Eq ((Get-JkTitleFileTokens 'Quiz 1 closes') -join ',') 'quiz 1,q1'
    Assert-Eq ((Get-JkTitleFileTokens 'Midterm') -join ',') 'midterm'
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'due-files'; $script:JkConfigCache = $null
    try {
        $top = Join-Path $env:JK_HOME 'desk'
        $c = Join-Path $top 'Waterloo course\CS341'
        New-Item -ItemType Directory (Join-Path $c 'A2'), (Join-Path $c 'A3') -Force | Out-Null
        foreach ($f in 'A2.tex', 'A2.aux', 'A2\notes.md', 'A3\draft.md', 'a22.pdf', 'syllabus.pdf') { Set-Content (Join-Path $c $f) 'x' }
        Set-JkConfig 'tidy.courses' $top
        Add-JkDue cs341 'Assignment 2' oct 30 11:59pm -Weight 4
        Add-JkDue cs341 'Assignment 3' nov 13 11:59pm -Weight 4
        Add-JkDue cs341 'Midterm 2' nov 9 6pm -Exam
        Show-JkDueFiles cs341 assignment
        Assert-Eq (@(Get-JkFindLast | ForEach-Object { Split-Path $_ -Leaf }) -join ',') 'A2.tex,notes.md' 'the nearest one; name before folder; no a22 or .aux'
        Show-JkDueFiles cs341 3
        Assert-Eq (@(Get-JkFindLast | ForEach-Object { Split-Path $_ -Leaf }) -join ',') 'draft.md'
        Show-JkDueFiles cs341 midterm
        Assert-True (@(Get-JkFindLast).Count -ge 4) 'nothing named after it: the newest files instead'
        # jk plan start names the files of the item it starts on
        $origFocus = ${function:Start-JkFocus}
        function script:Start-JkFocus { param($Minutes, $Label) }
        try {
            $out = (Start-JkPlanBlock 6>&1 | ForEach-Object { "$_" }) -join "`n"
            Assert-True ($out -match 'files: 1 A2\.tex\s+2 notes\.md') "plan start: $out"
            Assert-Eq (Split-Path (Invoke-JkFind -p 1) -Leaf) 'A2.tex'
        } finally { Set-Item function:script:Start-JkFocus $origFocus }
        Add-JkDue cs999 'Essay' nov 20
        Assert-Throws { Show-JkDueFiles cs999 essay }
    } finally { Set-JkConfig 'tidy.courses' ''; $env:JK_HOME = $saved; $script:JkConfigCache = $null }
}
Test 'Fit counts CJK characters as two columns' {
    $cjk = [string][char]0x6295 + [char]0x5DE5 + [char]0x4F5C
    Assert-Eq (Get-JkTextWidth "Desktop\$cjk") 14
    Assert-Eq (Get-JkTextWidth (Fit $cjk 10)) 10
    $cut = Fit "ab$cjk" 7
    Assert-Eq (Get-JkTextWidth $cut) 7
    Assert-True $cut.EndsWith($script:G.ell) 'a cut string ends in an ellipsis'
    Assert-Eq (Get-JkTextWidth (Fit $cjk 4 -Right)) 4
    Assert-Eq (Fit 'plain' 7) 'plain  '
}
Test 'fuzzy folder scoring: exact > prefix > substring > subsequence' {
    $c = { param($a) [pscustomobject]@{ Alias = $a; Path = "C:\x\$a"; Source = 'auto' } }
    $v = @{}
    $exact = Get-JkGoScore 'cs350' (& $c 'cs350') $v
    $prefix = Get-JkGoScore 'cs3' (& $c 'cs350') $v
    $sub = Get-JkGoScore '350' (& $c 'cs350') $v
    $seq = Get-JkGoScore 'c35' (& $c 'cs350') $v
    Assert-True ($exact -gt $prefix -and $prefix -gt $sub -and $sub -gt $seq -and $seq -gt 0)
    Assert-Eq (Get-JkGoScore 'zzz' (& $c 'cs350') $v) 0
}
Test 'light theme darkens text and course colors, inverts the today marker' {
    Assert-Eq (Convert-JkStyleForLight 'bold white') 'bold 1F2937'
    Assert-Eq (Convert-JkStyleForLight '#F87171') '9A4646'
    Assert-Eq (Convert-JkStyleForLight 'bold bg:white ink') 'bold bg:1F2937 FFFFFF'
    Assert-Eq (Convert-JkStyleForLight 'bold bg:#F2B04A ink') 'bold bg:#F2B04A ink' 'badges keep their fill and dark text'
}
Test 'config defaults, set and reset' {
    Assert-Eq (Get-JkConfig 'cp.lang') 'cpp'
    Set-JkConfig 'cp.lang' 'py'
    Assert-Eq (Get-JkConfig 'cp.lang') 'py'
    Invoke-JkConfig reset cp.lang
    Assert-Eq (Get-JkConfig 'cp.lang') 'cpp'
}
Test 'corrupt data file with no backup: set aside, not fatal' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved ('nobackup-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    try {
        New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
        [IO.File]::WriteAllText((Get-JkPath 'todo.json'), '{ not json')
        $t = Get-JkTodoData 3>$null
        Assert-Eq @($t.items).Count 0
        Assert-True (@(Get-ChildItem (Get-JkHome) -Filter 'todo.json.corrupt-*').Count -eq 1)
    } finally { $env:JK_HOME = $saved }
}
Test 'daily backup before the first change, restore round-trip' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'backup-home'
    try {
        Add-JkTodo first item
        $day = (Get-Date).ToString('yyyy-MM-dd')
        Assert-True (-not (Test-Path (Join-Path $env:JK_HOME "backups\$day\todo.json"))) 'nothing to back up before the file existed'
        Add-JkTodo second item
        $snap = Join-Path $env:JK_HOME "backups\$day\todo.json"
        Assert-True (Test-Path $snap) 'snapshot taken before the second save'
        Assert-Eq @((ConvertFrom-Json ([IO.File]::ReadAllText($snap))).items).Count 1
        Add-JkTodo third item
        Assert-Eq @((ConvertFrom-Json ([IO.File]::ReadAllText($snap))).items).Count 1 'one snapshot per day'
        Invoke-JkBackup restore $day todo
        Assert-Eq @((Get-JkTodoData).items).Count 1 'restored to the start-of-day state'
        $aside = @(Get-ChildItem (Join-Path $env:JK_HOME 'backups') -Directory | Where-Object { $_.Name -like '*before-restore*' })
        Assert-Eq $aside.Count 1
        Assert-Eq @((ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $aside[0].FullName 'todo.json')))).items).Count 3 'current state set aside'
        Assert-Throws { Invoke-JkBackup restore 1999-01-01 }
    } finally { $env:JK_HOME = $saved }
}
Test 'every view works on a brand-new, empty data folder' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'empty-home'
    $script:JkConfigCache = $null
    try {
        Show-JkDashboard; Show-JkBrief -Force; Show-JkDue; Show-JkDueAll; Show-JkDueWeek; Show-JkExams
        Show-JkClasses; Show-JkTimetable; Show-JkReview; Show-JkGradeOverview; Show-JkTodo; Show-JkFocusLog
        Show-JkReminders; Show-JkGoList
        Export-JkDueIcs -Out (Join-Path $env:JK_HOME 'e.ics'); Export-JkDueHtml -NoOpen -Out (Join-Path $env:JK_HOME 'e.html')
    } finally { $env:JK_HOME = $saved; $script:JkConfigCache = $null }
}
Test 'help renders for every topic' {
    Show-JkHelp
    foreach ($k in $script:JkHelpTopics.Keys) { Show-JkHelp $k }
}
Test 'narrow windows: lines are cut instead of wrapping; help rewraps without losing words' {
    $esc = [char]27
    $line = "$esc[1mbold$esc[0m " + ('x' * 50)
    $cut = Limit-JkLine $line 20
    Assert-Eq (Get-JkVisibleLength $cut) 20
    Assert-True $cut.StartsWith("$esc[1mbold$esc[0m") 'colour codes survive the cut'
    Assert-True $cut.EndsWith("$esc[0m") 'a cut coloured line resets its colour'
    Assert-Eq (Limit-JkLine 'short' 20) 'short'
    Assert-Eq ((Split-JkWords 'one two three four' 9) -join '|') 'one two|three|four'
    $saved = $env:JK_WIDTH
    try {
        $env:JK_WIDTH = '60'
        foreach ($topic in $script:JkHelpTopics.Keys) {
            foreach ($l in @(Show-JkHelp $topic 6>&1 | ForEach-Object { "$_" } | Select-Object -Skip 3)) {
                Assert-True ((Get-JkVisibleLength $l) -le 60) "help $topic overflows: $l"
                Assert-True (-not $l.Contains($script:G.ell)) "help $topic lost words: $l"
            }
        }
        $out = @(& { jk; jk due; jk week; jk exams; jk help; jk plan; jk review; jk grade; jk grade cs350 } 6>&1 | ForEach-Object { "$_" })
        Assert-True ($out.Count -gt 40) 'the views printed'
        foreach ($l in $out) { Assert-True ((Get-JkVisibleLength $l) -le 60) "overflows 60: $l" }
    } finally { $env:JK_WIDTH = $saved }
}
Test 'tab completion engine' {
    $names = { param($w, $t) @(Get-JkCompletions -Word $w -Tokens $t | ForEach-Object { $_.CompletionText }) }
    Assert-True ((& $names 'du' @('jk', 'du')) -contains 'due')
    Assert-True ((& $names '' @('jk', 'cp')) -contains 'stress')
    Assert-True ((& $names '' @('jk', 'cp', 'new', 'x')) -contains '-Lang')
    Assert-Eq ((& $names '' @('jk', 'cp', 'new', 'x', '-Lang')) -join ',') 'cpp,py,java,usaco'
    Assert-True ((& $names '' @('jk', 'due', 'add')) -contains 'cs350')
}
Test 'every router action is offered by tab completion' {
    # the first name in each '^(name|alias...)' pattern of a router is its action; tick is the
    # morning task's entry point; the rest are value checks, not actions
    $skip = @{ remind = @('tick'); config = @('auto', 'dark'); port = @('svchost') }
    $missing = foreach ($cmd in $script:JkActions.Keys) {
        $fn = Get-Item "function:$($script:JkCommands[$cmd].Fn)"
        $found = [regex]::Matches($fn.Definition, "'\^\(([a-z][a-z0-9]*)[|)]") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        foreach ($act in $found) {
            if (@($script:JkActions[$cmd]) -notcontains $act -and @($skip[$cmd]) -notcontains $act) { "$cmd $act" }
        }
    }
    Assert-Eq (@($missing) -join ', ') ''
}
Test 'jk help <command> names every action' {
    $missing = foreach ($cmd in $script:JkActions.Keys) {
        $topic = $script:JkHelpTopics[$cmd]
        if (-not $topic) { continue }
        # words on the help lines for this command ("jk todo done 2 | undo 2 | rm 2")
        $words = @($topic -split "`r?`n" | Where-Object { $_ -match "^jk $cmd\b" } | ForEach-Object { $_ -split '[^\w-]+' })
        foreach ($act in @($script:JkActions[$cmd])) {
            if ($act -match '^\d+$' -or $act -eq 'help') { continue }
            if ($words -notcontains $act) { "$cmd $act" }
        }
    }
    Assert-Eq (@($missing) -join ', ') ''
}

Remove-Module jk
Remove-Item $env:JK_HOME -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item env:JK_NOW, env:JK_HOME, env:JK_COLOR, env:JK_WIDTH, env:JK_NONINTERACTIVE -ErrorAction SilentlyContinue

Write-Host ''
if ($script:failed.Count) {
    Write-Host "$($script:passed) passed, $($script:failed.Count) failed" -ForegroundColor Red
    $script:failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "all $($script:passed) tests passed" -ForegroundColor Green
exit 0
