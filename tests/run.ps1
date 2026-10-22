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

Write-Host ''
Write-Host 'classes' -ForegroundColor Cyan
Test 'day lists and time ranges' {
    Assert-Eq ((ConvertTo-JkDays 'tue,thu') -join ' ') 'Tue Thu'
    Assert-Eq ((ConvertTo-JkDays 'TTh') -join ' ') 'Tue Thu'
    Assert-Eq ((ConvertTo-JkDays 'MWF') -join ' ') 'Mon Wed Fri'
    Assert-Eq ((ConvertTo-JkDays 'MTWThF') -join ' ') 'Mon Tue Wed Thu Fri'
    Assert-Eq ((ConvertTo-JkDays 'mon/wed') -join ' ') 'Mon Wed'
    Assert-Eq ((ConvertTo-JkDays 'weekdays').Count) 5
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
