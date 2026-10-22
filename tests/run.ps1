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
        function script:Start-JkBackground { param([string]$Script, [hashtable]$Env = @{}) [pscustomobject]@{ Id = 0; StartTime = (Get-Date) } }
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
        Assert-Throws { Select-JkSections cs350 }
        Show-JkSectionCatalog
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
Test 'corrupt data file is backed up, not fatal' {
    [IO.File]::WriteAllText((Get-JkPath 'todo.json'), '{ not json')
    $t = Get-JkTodoData 3>$null
    Assert-Eq @($t.items).Count 0
    Assert-True (@(Get-ChildItem (Get-JkHome) -Filter 'todo.json.corrupt-*').Count -eq 1)
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
Test 'tab completion engine' {
    $names = { param($w, $t) @(Get-JkCompletions -Word $w -Tokens $t | ForEach-Object { $_.CompletionText }) }
    Assert-True ((& $names 'du' @('jk', 'du')) -contains 'due')
    Assert-True ((& $names '' @('jk', 'cp')) -contains 'stress')
    Assert-True ((& $names '' @('jk', 'cp', 'new', 'x')) -contains '-Lang')
    Assert-Eq ((& $names '' @('jk', 'cp', 'new', 'x', '-Lang')) -join ',') 'cpp,py,java,usaco'
    Assert-True ((& $names '' @('jk', 'due', 'add')) -contains 'cs350')
}

Remove-Module jk
Remove-Item $env:JK_HOME -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item env:JK_NOW, env:JK_HOME, env:JK_COLOR, env:JK_WIDTH -ErrorAction SilentlyContinue

Write-Host ''
if ($script:failed.Count) {
    Write-Host "$($script:passed) passed, $($script:failed.Count) failed" -ForegroundColor Red
    $script:failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "all $($script:passed) tests passed" -ForegroundColor Green
exit 0
