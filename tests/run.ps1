# jk test suite. Run from anywhere:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "<repo>\tests\run.ps1"
# Uses a throwaway data folder and a pinned clock (Thu 2026-10-22 14:00), so it never
# touches your real ~\.jk data. JK_SANDBOX points the profile, module link and morning task at a
# throwaway place too, and the last test fails if the real ones changed during the run.
#   -Culture de-DE   run with another culture's formats (decimal comma, day-first dates) for this
#                    process only; Windows' regional settings are left alone
#   -TimeZone UTC    run as if this machine were in another time zone ('Pacific Standard Time'), for
#                    this process only; the system's zone is left alone
# tests\check.ps1 runs all of these side by side.

param([string]$Culture, [string]$TimeZone)

$ErrorActionPreference = 'Stop'
if ($Culture) {
    $ci = [Globalization.CultureInfo]::GetCultureInfo($Culture)
    [Threading.Thread]::CurrentThread.CurrentCulture = $ci
    [Globalization.CultureInfo]::DefaultThreadCurrentCulture = $ci
    Write-Host "culture: $($ci.Name)  (1234.5 -> $((1234.5).ToString('N1')))"
}
if ($TimeZone) {
    # .NET Framework keeps the local zone, and this year's offset and DST rule, in a private cache
    # (TimeZoneInfo.s_cachedData). Replacing both makes DateTime.Now, Get-Date and every local/UTC
    # conversion in this process act as that zone. Processes the tests start see the real zone.
    $tz = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZone)
    $bf = [Reflection.BindingFlags]'NonPublic,Instance'
    $cd = [TimeZoneInfo].GetField('s_cachedData', [Reflection.BindingFlags]'NonPublic,Static').GetValue($null)
    $cd.GetType().GetField('m_localTimeZone', $bf).SetValue($cd, $tz)
    $year = [DateTime]::UtcNow.Year
    $rule = $null
    foreach ($r in $tz.GetAdjustmentRules()) { if ($r.DateStart.Year -le $year -and $r.DateEnd.Year -ge $year) { $rule = $r } }
    $ctor = [TimeZoneInfo].GetNestedType('OffsetAndRule', [Reflection.BindingFlags]'NonPublic').GetConstructors($bf + [Reflection.BindingFlags]'Public')[0]
    $cd.GetType().GetField('m_oneYearLocalFromUtc', $bf).SetValue($cd, $ctor.Invoke([object[]]@([int]$year, $tz.BaseUtcOffset, $rule)))
    Write-Host "time zone: $([TimeZoneInfo]::Local.Id)  (now $((Get-Date).ToString('HH:mm zzz')))"
}
$root = Split-Path -Parent $PSScriptRoot
# The real install as it stands, read directly (jk's own functions are redirected below). A test
# once ran jk setup uninstall and jk speed undo for real: the morning task, the module link and the
# profile block were gone for four days before anyone noticed.
function global:Get-RealInstallStamp {
    $docs = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell'
    $files = foreach ($n in 'profile.ps1', 'Microsoft.PowerShell_profile.ps1') {
        $p = Join-Path $docs $n
        if (Test-Path -LiteralPath $p) { "$n=$((Get-Item -LiteralPath $p).LastWriteTimeUtc.Ticks)" } else { "$n=none" }
    }
    $link = Get-Item -LiteralPath (Join-Path $docs 'Modules\jk') -Force -ErrorAction SilentlyContinue
    $task = 'none'
    try { $svc = New-Object -ComObject Schedule.Service; $svc.Connect(); $task = "$($svc.GetFolder('\').GetTask('jk-remind').Definition.Triggers.Count) triggers" } catch { }
    (@($files) + "link=$(if ($link) { $link.Target } else { 'none' })" + "task=$task") -join '; '
}
$global:JkRealInstall = Get-RealInstallStamp
$env:JK_HOME = Join-Path $env:TEMP ('jk-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$env:JK_CACHE = "$env:JK_HOME-cache"   # beside the data folder: one test deletes that wholesale
$env:JK_SANDBOX = "$env:JK_HOME-sandbox"   # the profile, module link and morning task are never the real ones
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
    $cases = [ordered]@{ '8pm' = '20:00'; '8:30 pm' = '20:30'; '8:30PM' = '20:30'; '12am' = '00:00'; '12pm' = '12:00'; '2359' = '23:59'; 'noon' = '12:00'; 'midnight' = '23:59'; '20:00' = '20:00'; '9' = '09:00'; '7a' = '07:00'; '220pm' = '14:20'; '1130am' = '11:30'; '1130 pm' = '23:30'; '930' = '09:30' }
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
    # everyday phrasings (the pinned clock is Thu Oct 22, 2 pm)
    $f = { param($s) $r = ConvertFrom-JkWhen $s; "$($r.Date.ToString('MM-dd')) $($r.Time)".Trim() }
    Assert-Eq (& $f 'in 3 days') '10-25'
    Assert-Eq (& $f 'in 3 days 5pm') '10-25 17:00' 'the time after "in N days" is kept'
    Assert-Eq (& $f 'in 2 weeks 9am') '11-05 09:00'
    Assert-Eq (& $f 'in a week') '10-29'
    Assert-Eq (& $f 'tonight') '10-22 23:59'
    Assert-Eq (& $f 'tonight 10pm') '10-22 22:00'
    Assert-Eq (& $f 'eod') '10-22 23:59'
    Assert-Eq (& $f '8pm') '10-22 20:00' 'a time alone is today'
    Assert-Eq (& $f '9am') '10-23 09:00' 'or tomorrow once it has passed'
}
Test 'a date as jk prints it reads back, and a date that does not exist is reported, not read around' {
    $cases = [ordered]@{
        'Thu Oct 22' = '2026-10-22'; 'Mon Oct 26' = '2026-10-26'; 'monday, october 26' = '2026-10-26'; 'mon 26 oct' = '2026-10-26'; 'mon 10/26' = '2026-10-26'
        'fri 23rd' = '2026-10-23'; 'Fri Dec 4 2026' = '2026-12-04'; 'this fri' = '2026-10-23'; 'this thu' = '2026-10-22'; 'next week' = '2026-10-29'
        '26th of oct' = '2026-10-26'; 'sept 30' = '2026-09-30'; 'thurs' = '2026-10-22'; 'tues' = '2026-10-27'
    }
    foreach ($k in $cases.Keys) { Assert-Eq ((ConvertTo-JkDate $k).ToString('yyyy-MM-dd')) $cases[$k] "for '$k'" }
    $why = { param($s) try { $null = ConvertTo-JkDate $s; '' } catch { $_.Exception.Message } }
    Assert-True ((& $why 'tue oct 26') -like 'no such date: Oct 26 2026 is a Monday, not a Tuesday') (& $why 'tue oct 26')
    foreach ($typo in 'nov 31', '31 nov', 'feb 30', '2/30', '2026-02-30', '2/30/2026', 'feb 29') {
        Assert-True ((& $why $typo) -like 'no such date*') "'$typo': $(& $why $typo)"
    }
    # words that only look like dates are not dates, so they stay available as title words
    foreach ($word in 'novel 2', 'marking 5', 'sunny', '13/25', '4-31', '1-40') {
        $m = & $why $word
        Assert-True ($m -and $m -notlike 'no such date*') "'$word': $m"
    }
    # Feb 29 means the coming February or nothing
    Assert-Eq ((ConvertTo-JkDate 'feb 29' -Now ([datetime]'2027-11-05')).ToString('yyyy-MM-dd')) '2028-02-29'
    Assert-Eq ((ConvertTo-JkDate 'feb 29' -Now ([datetime]'2028-01-10')).ToString('yyyy-MM-dd')) '2028-02-29'
    Assert-Throws { ConvertTo-JkDate 'feb 29' -Now ([datetime]'2028-06-01') } 'the next February has no 29th'
    # times that contradict themselves
    Assert-Eq (ConvertTo-JkTime '0:30 am') '00:30'
    Assert-Eq (ConvertTo-JkTime '15:20pm') '15:20' 'says the same thing twice, which is fine'
    foreach ($bad in '0pm', '15:00 am') { Assert-Throws { ConvertTo-JkTime $bad } "'$bad'" }
    $r = ConvertTo-JkTimeRange '14:00-15:20pm'; Assert-Eq "$($r.Start) $($r.End)" '14:00 15:20' 'a 24-hour start before a pm end'
    # with a time
    $f = { param($s) $w = ConvertFrom-JkWhen $s; "$($w.Date.ToString('MM-dd')) $($w.Time)".Trim() }
    Assert-Eq (& $f 'mon oct 26 6pm') '10-26 18:00'
    Assert-Eq (& $f 'nov 9 @ 5pm') '11-09 17:00'
    Assert-Eq (& $f 'fri 5') '10-23 17:00' 'a bare hour after a date is not 5 in the morning'
    Assert-Eq (& $f 'fri 5:30') '10-23 17:30'
    Assert-Eq (& $f 'fri 5am') '10-23 05:00' 'unless it says so'
    Assert-Eq (& $f 'fri 9') '10-23 09:00' 'from 7 on the clock reading stands'
    Assert-Eq (& $f 'fri 17') '10-23 17:00'
    Assert-Eq (& $f 'tonight 8') '10-22 20:00'
    Assert-Eq (& $f 'tonight 20:00') '10-22 20:00'
    Assert-Throws { ConvertFrom-JkWhen 'tue oct 26 6pm' } 'a wrong weekday is not read around'
    # jk at takes as many words as a date and time can have, and leaves the rest as the message
    $at = { param([string]$s) $x = Resolve-JkAtTime ($s -split ' ') (Get-JkNow); "$($x.At.ToString('MM-dd HH:mm'))/$($x.K)" }
    Assert-Eq (& $at 'nov 9 5 pm submit') '11-09 17:00/4' 'not 5 am with "pm submit" as the message'
    Assert-Eq (& $at 'mon oct 26 5pm call') '10-26 17:00/4'
    Assert-Eq (& $at 'mon oct 26 5 pm') '10-26 17:00/5'
    Assert-Eq (& $at 'fri 5 leave') '10-23 17:00/2'
    Assert-Eq (& $at '5pm call home now please') '10-22 17:00/1'
    $whyAt = try { $null = Resolve-JkAtTime @('tue', 'oct', '26', '5pm', 'call') (Get-JkNow); '' } catch { $_.Exception.Message }
    Assert-True ($whyAt -like '*is a Monday*') $whyAt
    # scores
    Assert-Eq (ConvertTo-JkPercent '.5') 0.5
    Assert-Eq (ConvertTo-JkPercent '.5/1') 50
    Assert-Eq (ConvertTo-JkPercent '17 out of 20') 85
}
Test 'durations' {
    Assert-Throws { ConvertTo-JkSeconds '0' } 'a reminder for right now is a mistake'
    Assert-Throws { ConvertTo-JkSeconds '0:00' }
    Assert-Eq (ConvertTo-JkSeconds '25') 1500
    Assert-Eq (ConvertTo-JkSeconds '1h30m') 5400
    Assert-Eq (ConvertTo-JkSeconds '90s') 90
    Assert-Eq (ConvertTo-JkSeconds '1:30') 5400
    Assert-Eq (ConvertTo-JkSeconds '2 hours') 7200
    Assert-Eq (ConvertTo-JkSeconds '1h30') 5400
    Assert-Throws { ConvertTo-JkSeconds 'abc' }
    Assert-Throws { ConvertTo-JkSeconds '20 parsecs' }
    # what jk in / jk focus take from the front of what was typed: seconds, words used
    $rd = { param([string]$s) $r = Read-JkDurationWords ($s -split ' '); "$($r.Seconds)/$($r.Used)" }
    Assert-Eq (& $rd '2 hours study') '7200/2' 'a spelled-out unit is part of the length'
    Assert-Eq (& $rd '10 minutes break') '600/2'
    Assert-Eq (& $rd '1h 30m stretch') '5400/2'
    Assert-Eq (& $rd '1h30 stretch') '5400/1'
    # spoken lengths
    Assert-Eq (& $rd 'half an hour call mom') '1800/3'
    Assert-Eq (& $rd 'an hour and a half reading') '5400/5'
    Assert-Eq (& $rd 'a minute tea') '60/2'
    Assert-Eq (& $rd 'for 30 minutes cs350') '1800/3'
    Assert-Eq (& $rd 'a quarter of an hour x') '900/5'
    Assert-Eq (& $rd '1 hour and 30 minutes x') '5400/5'
    Assert-Throws { Read-JkDurationWords @('half', 'x') }
    Assert-Eq (& $rd '45 call') '2700/1'
    Assert-Eq (& $rd '20m 3 things') '1200/1' 'a message starting with a number keeps it'
    Assert-Throws { Read-JkDurationWords @('soon', 'please') }
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
Test 'jk plan follows a pass rule too: with an easy target but exams at 38.75%, the final still gets more time, and the note says what it needs to pass' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH
    $env:JK_HOME = Join-Path $saved 'passplan-home'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $dd = Get-JkDueData; $a = Resolve-JkCourse $dd 'cs370' -Create
        $a1 = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-10-05') -Time '23:59' -Title 'Assignment 1' -Weight '7%'
        $a2 = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-10-26') -Time '23:59' -Title 'Assignment 2' -Weight '7%'
        $mid = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-11-02') -Time '19:00' -Title 'Midterm' -Kind 'exam' -Weight '32%'
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-11-16') -Time '23:59' -Title 'Assignment 3' -Weight '7%'
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-12-04') -Time '23:59' -Title 'Assignment 4' -Weight '7%'
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-12-10') -Time '16:00' -End '18:30' -Title 'FINAL' -Kind 'exam' -Weight '40%'
        Save-JkDueData $dd
        # a target of 50%: the total is comfortable (44% on the rest), so by the target alone the course gets less
        [IO.File]::WriteAllText((Join-Path $env:JK_HOME 'grades.json'), "{""scores"":[{""id"":""$($a1.id)"",""score"":100},{""id"":""$($a2.id)"",""score"":100},{""id"":""$($mid.id)"",""score"":38.75}],""extras"":[],""targets"":[{""course"":""$($a.key)"",""target"":50}],""nextExtra"":1}")
        $env:JK_NOW = '2026-11-13T10:00:00'
        $f = { $it = @(Get-JkPlanItems | Where-Object { $_.Title -eq 'FINAL' })[0]; if ($it) { "$([double]$it.Factor)" } else { 'absent' } }
        Assert-Eq (& $f) 'absent' 'by the target alone, the final waits until two weeks before'
        # the rule: the exams must average 50%, so the final needs 59% against 38.75% so far
        $null = Invoke-JkGrade pass $a.key exams 50 6>&1
        Assert-Eq (& $f) '1.4' 'the pass rule gives the final 1.4 times the time, from 5 weeks out'
        $env:JK_WIDTH = '160'
        $notes = @(Show-JkPlan 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'by your marks' })
        Assert-True ($notes.Count -eq 1 -and $notes[0] -match 'CS 370 exams x1\.4, from 5 weeks out .+ to pass, the exams must average 50%: 39% so far, the FINAL needs 59%') "the note: $($notes -join ' / ')"
        # the assignments, at 100%, are not given more by it
        $a3 = @(Get-JkPlanItems | Where-Object { $_.Title -eq 'Assignment 3' })[0]
        Assert-True ([double]$a3.Factor -lt 1) "the assignments keep the target's share: $($a3.Factor)"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'jk grade pass: the exams must average 50% (CS 370: the final needs 59%), shown in jk grade, jk exam and the overview; cap, off and bad input' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH
    $env:JK_HOME = Join-Path $saved 'passrule-home'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $dd = Get-JkDueData; $a = Resolve-JkCourse $dd 'cs370' -Create; $b = Resolve-JkCourse $dd 'cs350' -Create
        $a1 = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-10-05') -Time '23:59' -Title 'Assignment 1' -Weight '7%'
        $a2 = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-10-26') -Time '23:59' -Title 'Assignment 2' -Weight '7%'
        $mid = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-11-02') -Time '19:00' -Title 'Midterm' -Kind 'exam' -Weight '32%'
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-11-16') -Time '23:59' -Title 'Assignment 3' -Weight '7%'
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-12-04') -Time '23:59' -Title 'Assignment 4' -Weight '7%'
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-12-10') -Time '16:00' -End '18:30' -Title 'FINAL' -Kind 'exam' -Weight '40%'
        $null = New-JkEvent -Data $dd -Course $b.key -Date ([datetime]'2026-12-17') -Time '16:00' -End '18:30' -Title 'FINAL' -Kind 'exam' -Weight '40%'
        Save-JkDueData $dd
        [IO.File]::WriteAllText((Join-Path $env:JK_HOME 'grades.json'), "{""scores"":[{""id"":""$($a1.id)"",""score"":100},{""id"":""$($a2.id)"",""score"":100},{""id"":""$($mid.id)"",""score"":38.75}],""extras"":[],""targets"":[],""nextExtra"":1}")
        $env:JK_NOW = '2026-11-13T10:00:00'; $env:JK_WIDTH = '140'
        $lines = { param($sb) @(& $sb 6>&1 | ForEach-Object { "$_" }) }
        $g = & $lines { Invoke-JkGrade pass cs370 exams 50 }
        Assert-True ((($g | Where-Object { $_ -match '^\s+pass\s' }) -join ' ') -match 'the exams \(72% of the course\) must average 50% to pass: 38[.,]8% so far, the FINAL needs 59%') "jk grade cs370: $(($g | Where-Object { $_ -match 'pass' }) -join ' / ')"
        $r = @(Measure-JkPassRules (Get-JkDueData) (Get-JkGradeData) $a.key)[0]
        Assert-Eq "$($r.Weight)|$([Math]::Round($r.Need, 1))|$($r.Held)" '72|59|False' 'the numbers: 72% of exams, 59% on the final'
        $x = & $lines { Invoke-JkExams cs370 }
        Assert-True (@($x | Where-Object { $_ -match '^\s+pass\s+the exams .* the FINAL needs 59%' }).Count -eq 1) "jk exam cs370: $(($x | Where-Object { $_ -match 'pass' }) -join ' / ')"
        # CS 350: two rules and a cap; nothing marked yet, so the overview leaves it out
        $null = & $lines { Invoke-JkGrade pass cs350 exams 50 work 50 cap 46 }
        $c = & $lines { Show-JkGrade cs350 }
        Assert-True (@($c | Where-Object { $_ -match '^\s+pass\s+the exams .* or the course is capped at 46%' }).Count -eq 1 -and @($c | Where-Object { $_ -match '^\s+pass\s+the assignments and other work' }).Count -eq 1) "jk grade cs350: $(($c | Where-Object { $_ -match 'pass' }) -join ' / ')"
        $o = & $lines { Show-JkGradeOverview }
        $op = @($o | Where-Object { $_ -match '^\s+pass\s' })
        Assert-True ($op.Count -eq 1 -and $op[0] -match 'CS 370: the exams') "the overview lists only a rule with marks behind it: $($op -join ' / ')"
        # a final of 60 holds it
        $g2 = Get-JkGradeData; $fin = @((Get-JkDueData).events | Where-Object { $_.course -eq $a.key -and $_.title -eq 'FINAL' })[0]
        $g2.scores = @($g2.scores) + [pscustomobject]@{ id = [string]$fin.id; score = 60 }; Save-JkGradeData $g2
        Assert-True (@(Measure-JkPassRules (Get-JkDueData) (Get-JkGradeData) $a.key)[0].Held) 'with 60 on the final the rule holds'
        Assert-Throws { Invoke-JkGrade pass cs370 exams lots 6>$null } 'a percent is required'
        Assert-Throws { Invoke-JkGrade pass cs370 quizzes 50 6>$null } 'an unknown kind is refused'
        $null = & $lines { Invoke-JkGrade pass cs370 off }
        Assert-Eq @(Get-JkPassRules (Get-JkGradeData) $a.key).Count 0 'off removes it'
        Assert-Eq @(Get-JkPassRules (Get-JkGradeData) $b.key).Count 2 'and leaves the other course alone'
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'jk exam with the target out of reach says where the course can still end, what 70% and 60% take, and that the week is only part of the prep' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH
    $env:JK_HOME = Join-Path $saved 'outofreach-home'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $dd = Get-JkDueData; $a = Resolve-JkCourse $dd 'cs370' -Create; $b = Resolve-JkCourse $dd 'co367' -Create
        $a1 = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-10-05') -Time '23:59' -Title 'Assignment 1' -Weight '7%'
        $a2 = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-10-26') -Time '23:59' -Title 'Assignment 2' -Weight '7%'
        $mid = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-11-02') -Time '19:00' -Title 'Midterm' -Kind 'exam' -Weight '32%'
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-11-16') -Time '23:59' -Title 'Assignment 3' -Weight '7%'
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-12-10') -Time '16:00' -End '18:30' -Title 'FINAL' -Kind 'exam' -Weight '40%'
        $null = New-JkEvent -Data $dd -Course $b.key -Date ([datetime]'2026-11-19') -Time '08:30' -End '09:50' -Title 'Quiz 3' -Kind 'exam' -Weight '20%'
        Save-JkDueData $dd
        [IO.File]::WriteAllText((Join-Path $env:JK_HOME 'grades.json'), "{""scores"":[{""id"":""$($a1.id)"",""score"":100},{""id"":""$($a2.id)"",""score"":100},{""id"":""$($mid.id)"",""score"":38.75}],""extras"":[],""targets"":[],""nextExtra"":1}")
        $env:JK_NOW = '2026-11-13T10:00:00'; $env:JK_WIDTH = '130'
        $brief = @(Invoke-JkExams $a.key 6>&1 | ForEach-Object { "$_" })
        # a row and the lines it wraps onto
        $row = { param($lines, $k)
            $out = @(); $on = $false
            foreach ($l in $lines) { if ($l -match "^\s+$k\s") { $on = $true; $out += $l } elseif ($on -and $l -match '^\s{11}\S') { $out += $l.Trim() } else { $on = $false } }
            ($out -join ' ') }
        $if = & $row $brief 'if'
        Assert-True ($if -match '60 . 64%' -and $if -match '90 . 76%' -and $if -match 'for the course at most' -and $if -match '80% is out of reach' -and $if -notmatch '\(!\)') "the if row: $if"
        $marks = & $row $brief 'marks'
        Assert-True ($marks -match 'you need 99% on the rest' -and $marks -match '\(70% takes 81%, 60% takes 62%\)') "the marks row: $marks"
        $prep = & $row $brief 'prep'
        Assert-True ($prep -match 'jk plan has \S+( \S+)? of it in the next 7 days') "prep, an exam four weeks off: $prep"
        # a course with no marks, its quiz inside the week: as before
        $q = @(Invoke-JkExams $b.key 6>&1 | ForEach-Object { "$_" })
        Assert-True ((& $row $q 'if') -match '60 . 85%') "no marks: what the rest needs, as before: $(& $row $q 'if')"
        Assert-True ((& $row $q 'prep') -match 'before it') "prep, an exam this week: $(& $row $q 'prep')"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'a week that runs into the study break plans those days at plan.examHours, the class days before at plan.hours' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'daybudget-home'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $dd = Get-JkDueData; $a = Resolve-JkCourse $dd 'cs370' -Create; $b = Resolve-JkCourse $dd 'cs341' -Create
        Set-JkProp $dd 'term' ([pscustomobject]@{ name = 'Fall 2026'; start = '2026-09-08'; classesEnd = '2026-12-08'; examsStart = '2026-12-10'; examsEnd = '2026-12-22' })
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-12-10') -Time '16:00' -End '18:30' -Title 'FINAL' -Kind 'exam' -Weight '40%'
        $null = New-JkEvent -Data $dd -Course $b.key -Date ([datetime]'2026-12-12') -Time '12:30' -End '15:00' -Title 'FINAL' -Kind 'exam' -Weight '44%'
        Save-JkDueData $dd
        $env:JK_NOW = '2026-12-05T07:00:00'
        $p = Get-JkPlanToday
        $by = @{}; foreach ($s in $p.Schedule) { $by[$s.Day.ToString('MMM d', $script:Inv)] = [int]$s.Budget }
        Assert-Eq "$($by['Dec 5'])|$($by['Dec 8'])|$($by['Dec 9'])|$($by['Dec 10'])" '180|180|360|360' 'Sat and the last day of classes at 3 h, the study break and the exam period at 6 h'
        $planned = 0.0; foreach ($v in @($p.Schedule | Where-Object { $_.Day -eq [datetime]'2026-12-09' })[0].Alloc.Values) { $planned += $v }
        Assert-True ($planned -gt 180) "Dec 9 is planned past 3 hours: $planned minutes"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'jk plan leaves out the courses in plan.skip (their deadlines stay in jk due), and jk plan week lists each day as a checklist' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH
    $env:JK_HOME = Join-Path $saved 'planskip-home'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $dd = Get-JkDueData; $a = Resolve-JkCourse $dd 'cs370' -Create; $h = Resolve-JkCourse $dd 'health105' -Create
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-11-16') -Time '23:59' -Title 'Assignment 3' -Weight '7%'
        $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-11-16') -Time '23:59' -Title 'Assignment 7' -Weight '7.5%'
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-11-19') -Time '08:30' -Title 'Quiz 3' -Kind 'exam' -Weight '20%'
        Save-JkDueData $dd
        $env:JK_NOW = '2026-11-13T09:00:00'; $env:JK_WIDTH = '100'
        Assert-Eq (@(Get-JkPlanItems | ForEach-Object { $_.Course } | Sort-Object -Unique) -join ',') "$($a.key),$($h.key)" 'both courses are planned to begin with'
        try { $null = Invoke-JkConfig set plan.skip 'HEALTH 105' 6>&1 } catch { }
        Assert-Eq (Get-JkConfig 'plan.skip') ([string]$h.key) 'the course is stored by its key'
        Assert-Eq (@(Get-JkPlanItems | ForEach-Object { $_.Course } | Select-Object -Unique) -join ',') ([string]$a.key) 'jk plan leaves it out'
        Assert-True ((@(Show-JkDue 6>&1 | ForEach-Object { "$_" }) -join "`n") -match 'HEALTH 105\s+Assignment 7') 'its deadline stays in jk due'
        Assert-Throws { Invoke-JkConfig set plan.skip nosuchcourse 6>$null } 'a name that is no course is refused'
        $week = @(); try { $week = @(Show-JkPlanWeek 6>&1 | ForEach-Object { "$_" }) } catch { $week = @("error: $($_.Exception.Message)") }
        $all = $week -join "`n"
        Assert-True (@($week | Where-Object { $_ -match '^ (Fri Nov 13|Sat Nov 14|Sun Nov 15|Mon Nov 16|Tue Nov 17|Wed Nov 18|Thu Nov 19)\b' }).Count -eq 7) "seven days: $all"
        Assert-True ($all -match 'CS 370\s+Assignment 3\s+due Mon\s+\d' -and $all -match 'CS 370\s+Quiz 3\s+exam Thu\s+\d') "each day's blocks say what and by when: $all"
        Assert-True ($all -match '! due 11:59 pm\s+CS 370 Assignment 3' -and $all -match '! exam 8:30 am\s+CS 370 Quiz 3') "and what is handed in or written that day: $all"
        Assert-True ($all -notmatch 'Assignment 7' -and $all -match 'left out: HEALTH 105') "the course left out is named, not listed: $all"
        Assert-True ($all -match 'the week\s+\d+h \d+m: CS 370 ') "the week's total: $all"
        try { $null = Invoke-JkConfig set plan.skip off 6>&1 } catch { }
        Assert-Eq (@(Get-JkPlanItems | ForEach-Object { $_.Course } | Select-Object -Unique).Count) 2 'off brings it back'
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'jk plan follows the marks: a failed midterm gives the final more time and plans it from 5 weeks out; assignments at 100% and a course with no marks are unchanged' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'planmarks-home'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $dd = Get-JkDueData; $a = Resolve-JkCourse $dd 'cs370' -Create; $b = Resolve-JkCourse $dd 'cs341' -Create
        $a1 = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-10-05') -Time '23:59' -Title 'Assignment 1' -Weight '7%'
        $mid = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-11-02') -Time '19:00' -Title 'Midterm' -Kind 'exam' -Weight '32%'
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-11-16') -Time '23:59' -Title 'Assignment 3' -Weight '7%'
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-12-10') -Time '16:00' -End '18:30' -Title 'FINAL' -Kind 'exam' -Weight '40%'
        $null = New-JkEvent -Data $dd -Course $b.key -Date ([datetime]'2026-12-12') -Time '12:30' -End '15:00' -Title 'FINAL' -Kind 'exam' -Weight '44%'
        Save-JkDueData $dd
        $env:JK_NOW = '2026-11-13T09:00:00'
        $marks = { param($m) [IO.File]::WriteAllText((Join-Path $env:JK_HOME 'grades.json'), "{""scores"":[{""id"":""$($a1.id)"",""score"":100},{""id"":""$($mid.id)"",""score"":$m}],""extras"":[],""targets"":[],""nextExtra"":1}") }
        $row = { param($title) $it = @(Get-JkPlanItems | Where-Object { $_.Title -eq $title -and $_.Course -eq $a.key })[0]; if ($it) { "$([double]$it.Factor)|$([Math]::Round($it.Effort))" } else { 'absent' } }
        # no marks at all: by weight, two weeks ahead
        Assert-Eq "$(& $row 'Assignment 3')|$(& $row 'FINAL')" '1|210|absent' 'no marks: the assignment by weight, the final not yet'
        # midterm 38.75%: 80% takes 99% on the rest, so the exams get 1.39 times the time, from now
        & $marks 38.75
        Assert-Eq "$(& $row 'Assignment 3')|$(& $row 'FINAL')" '1|210|1.39|834' 'a failed midterm: the final from 5 weeks out with more time, the assignment (100% so far) as it was'
        Assert-True (-not @(Get-JkPlanItems | Where-Object { $_.Course -eq $b.key }).Count) 'a course with no marks: its final waits until two weeks before'
        $notes = @(Show-JkPlan 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'by your marks' })
        Assert-True ($notes.Count -eq 1 -and $notes[0] -match 'CS 370 exams x1\.4, from 5 weeks out . 50% so far, 80% takes 99% on the rest') "jk plan says why: $($notes -join ' / ')"
        # focus on the course goes to the assignment due Monday first, not mostly to the final
        Save-JkFocusData ([pscustomobject]@{ active = $null; sessions = @([pscustomobject]@{ start = '2026-11-13T08:00:00'; minutes = 50; actual = 50; label = "$($a.key) assignment 3" }) })
        $done = @(Get-JkPlanItems | Where-Object { $_.Course -eq $a.key } | Sort-Object Due | ForEach-Object { [Math]::Round($_.Done) }) -join '|'
        Assert-Eq $done '50|0' 'focus counts toward the nearer item first'
        # midterm 95%: ahead of the target, so a little less, and the final at two weeks as usual
        & $marks 95
        Assert-Eq "$(& $row 'Assignment 3')|$(& $row 'FINAL')" '0.8|168|absent' 'ahead of the target: less time, the final not yet'
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'jk class pick: a catalog section whose time cannot be read is left out, the rest still list and can be picked; 1pm is read as 13:00' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'badcatalog-home'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $dd = Get-JkDueData; $a = Resolve-JkCourse $dd 'cs341' -Create; $b = Resolve-JkCourse $dd 'cs350' -Create; Save-JkDueData $dd
        $sec = { param($course, $n, $start, $end) "{""course"":""$course"",""kind"":""LEC"",""section"":""$n"",""days"":[""Tue"",""Thu""],""start"":""$start"",""end"":""$end"",""room"":""MC 2017""}" }
        [IO.File]::WriteAllText((Join-Path $env:JK_HOME 'sections.json'), "{""items"":[$(& $sec $a.key '001' 'morning' '14:20'),$(& $sec $b.key '001' '1pm' '14:20'),$(& $sec $b.key '002' '16:00' '17:20')]}")
        $env:JK_NOW = '2026-11-09T09:00:00'
        $cat = @(Get-JkSectionCatalog)
        Assert-Eq "$($cat.Count)|$($cat[0].start)" '2|13:00' 'the unreadable section is left out, 1pm is 13:00'
        $threw = $null; try { $null = Select-JkSections 6>&1 } catch { $threw = $_.Exception.Message }
        Assert-True (-not $threw) "jk class pick lists the rest: $threw"
        $threw = $null; try { $null = Select-JkSections $b.key 001 6>&1 } catch { $threw = $_.Exception.Message }
        $mine = @((Get-JkClassData).items | Where-Object { $_.course -eq $b.key })
        Assert-True (-not $threw -and $mine.Count -eq 1 -and $mine[0].start -eq '13:00') "and a readable section can be picked: [$threw] $($mine | ConvertTo-Json -Compress)"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'an unreadable popup stamp counts as never (the popup still shows), and a mark that is not a number is set aside, kept on save and named' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'stampgrade-home'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    $origNotify = ${function:Show-JkNotify}; $origPlan = ${function:Get-JkPlanToday}
    function script:Show-JkNotify { param([string]$Title) $script:StampTitle = $Title; 'stub' }
    function script:Get-JkPlanToday { $null }
    try {
        $dd = Get-JkDueData; $c = Resolve-JkCourse $dd 'cs341' -Create
        $e = New-JkEvent -Data $dd -Course $c.key -Date ([datetime]'2026-11-09') -Time '23:59' -Title 'Assignment 3' -Weight '4%'
        $null = New-JkEvent -Data $dd -Course $c.key -Date ([datetime]'2026-11-02') -Time '23:59' -Title 'Assignment 2' -Weight '4%'
        Save-JkDueData $dd
        [IO.File]::WriteAllText((Join-Path $env:JK_HOME 'state.json'), '{"lastRemind":"x"}')
        $env:JK_NOW = '2026-11-09T07:45:00'; $script:StampTitle = $null
        $threw = $null; try { Invoke-JkDueRemind -Quiet } catch { $threw = $_.Exception.Message }
        Assert-True (-not $threw -and $script:StampTitle) "the morning popup shows with an unreadable stamp: [$threw] [$($script:StampTitle)]"
        $a2 = @((Get-JkDueData).events | Where-Object { $_.title -eq 'Assignment 2' })[0]
        [IO.File]::WriteAllText((Join-Path $env:JK_HOME 'grades.json'), "{""scores"":[{""id"":""$($a2.id)"",""score"":""great""}],""extras"":[],""targets"":{},""nextExtra"":1}")
        $failed = @()
        foreach ($v in @({ Invoke-JkGrade }, { Invoke-JkGrade cs341 }, { Invoke-JkExams 6>$null })) { try { $null = & $v 6>&1 } catch { if ($_.Exception.Message -notmatch 'no coming exam') { $failed += $_.Exception.Message } } }
        Assert-True (-not $failed.Count) "jk grade and jk grade cs341 work: $($failed -join ' / ')"
        $g = Get-JkGradeData; Save-JkGradeData $g
        $raw = [IO.File]::ReadAllText((Join-Path $env:JK_HOME 'grades.json')) | ConvertFrom-Json
        Assert-True (@($raw.scores | Where-Object { $_.score -eq 'great' }).Count -eq 1 -and -not $raw.PSObject.Properties['unreadable']) 'the mark is kept as it was after a save'
        $doc = @(Invoke-JkDoctor 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'unreadable mark\s' })
        Assert-Eq $doc.Count 1 "jk doctor names it: $($doc -join ' / ')"
    } finally {
        Set-Item function:script:Show-JkNotify $origNotify; Set-Item function:script:Get-JkPlanToday $origPlan
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'a setting typed into config.json that nothing can use falls back to its default and jk doctor names it; jk config set still refuses it' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'badconfig-home'; $script:JkConfigCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        [IO.File]::WriteAllText((Join-Path $env:JK_HOME 'config.json'), '{"remind.time":"7:45 sharp","remind.hours":"two days","plan.hours":"3,5","alert.before":"two hours","notify":"loud","editor":"code"}')
        $env:JK_NOW = '2026-11-09T09:00:00'; $script:JkConfigCache = $null
        Assert-Eq "$(Get-JkConfig 'remind.time')|$(Get-JkConfig 'remind.hours')|$(Get-JkConfig 'plan.hours')|$(Get-JkConfig 'alert.before')|$(Get-JkConfig 'notify')|$(Get-JkConfig 'editor')" '08:30|48|3.5|2h|auto|code' 'defaults stand in; 3,5 is read as 3.5; the rest as stored'
        $failed = @()
        foreach ($v in @({ $null = Test-JkMorningRunMissed }, { $null = Register-JkTodayAlerts }, { Show-JkPlan }, { Invoke-JkDueRemind -Quiet -Force })) { try { $null = & $v 6>&1 } catch { $failed += $_.Exception.Message } }
        Assert-True (-not $failed.Count) "the catch-up check, alerts, plan and popup work: $($failed -join ' / ')"
        $doc = @(Invoke-JkDoctor 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'setting (remind|plan|alert|notify)' })
        Assert-True ($doc.Count -eq 4 -and ($doc -join ' ') -match "setting remind\.time\s+'7:45 sharp' cannot be used, so 08:30 is") "jk doctor: $($doc -join ' / ')"
        Assert-Throws { Invoke-JkConfig set notify loud 6>$null } 'jk config set notify loud is refused, as before'
        Assert-Throws { Invoke-JkConfig set remind.hours 'two days' 6>$null } 'jk config set remind.hours "two days" is refused, as before'
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null
    }
}
Test 'an unreadable reminder (at soon, id b) is set aside: the good one is still re-armed and fires, a save keeps it, jk doctor names it; and a failing step does not stop the morning run' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'badreminder-home'; $script:JkConfigCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    $origBg = ${function:Start-JkBackground}; $origNotify = ${function:Show-JkNotify}
    function script:Start-JkBackground { param([string]$Script, [hashtable]$Env = @{}, [string]$WaitUntil) $script:BgCalls += @($Script); [pscustomobject]@{ Id = 999999; StartTime = (Get-Date) } }
    function script:Show-JkNotify { 'stub' }
    $tickFns = 'Restore-JkReminders', 'Sync-JkBackupMirror', 'Restore-JkFocusTimer', 'Register-JkTodayAlerts', 'Register-JkClassAlert', 'Register-JkStocksAlert', 'Update-JkDiskLog', 'Invoke-JkDueRemind', 'Limit-JkBackgroundLog'
    $origTick = @{}; foreach ($f in $tickFns) { $origTick[$f] = (Get-Item "function:$f").ScriptBlock }
    try {
        $good = '{"id":1,"text":"call home","at":"2026-11-09T20:00:00","created":"2026-11-08T10:00:00","pid":999998,"spawned":"2026-11-08T10:00:00","key":"","dueId":0}'
        $bad1 = '{"id":2,"text":"x","at":"soon","created":"2026-11-08T10:00:00","pid":1,"spawned":"2026-11-08T10:00:00","key":"","dueId":0}'
        $bad2 = '{"id":"b","text":"y","at":"2026-11-09T21:00:00","created":"2026-11-08T10:00:00","pid":1,"spawned":"2026-11-08T10:00:00","key":"","dueId":0}'
        [IO.File]::WriteAllText((Join-Path $env:JK_HOME 'reminders.json'), "{""nextId"":3,""items"":[$good,$bad1,$bad2]}")
        $env:JK_NOW = '2026-11-09T07:45:00'
        $script:BgCalls = @()
        $threw = $null; try { Restore-JkReminders } catch { $threw = $_.Exception.Message }
        Assert-True (-not $threw -and @($script:BgCalls | Where-Object { $_ -match 'Complete-JkReminder -Id 1\b' }).Count -eq 1) "the morning restore re-arms the good one: [$threw] $($script:BgCalls -join ' / ')"
        $threw = $null; try { $null = Show-JkReminders 6>&1 } catch { $threw = $_.Exception.Message }
        Assert-True (-not $threw) "jk remind lists: $threw"
        $threw = $null; try { Complete-JkReminder -Id 1 } catch { $threw = $_.Exception.Message }
        Assert-True (-not $threw) "the good one fires: $threw"
        $raw = [IO.File]::ReadAllText((Join-Path $env:JK_HOME 'reminders.json')) | ConvertFrom-Json
        Assert-True (@($raw.items).Count -eq 2 -and @($raw.items | Where-Object { $_.at -eq 'soon' }).Count -eq 1 -and @($raw.items | Where-Object { [string]$_.id -eq 'b' }).Count -eq 1) "after it fired, the two unreadable ones are kept: $(@($raw.items) | ConvertTo-Json -Compress)"
        $doc = @(Invoke-JkDoctor 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'unreadable reminder\s' })
        Assert-True ($doc.Count -eq 1 -and $doc[0] -match '\+1 more') "jk doctor: $($doc -join ' / ')"
        # the morning run: a step that throws is logged, and the rest still run
        $script:TickRan = @()
        function script:Restore-JkReminders { throw 'boom' }
        foreach ($f in $tickFns | Where-Object { $_ -ne 'Restore-JkReminders' }) { Set-Item "function:script:$f" ([scriptblock]::Create("`$script:TickRan += '$f'")) }
        $threw = $null; try { Invoke-JkTick } catch { $threw = $_.Exception.Message }
        Assert-True (-not $threw -and $script:TickRan -contains 'Register-JkTodayAlerts' -and $script:TickRan -contains 'Invoke-JkDueRemind') "the morning run goes on past a failing step: [$threw] ran: $($script:TickRan -join ', ')"
        $log = [IO.File]::ReadAllText((Get-JkPath 'background.log'))
        Assert-True ($log -match 'reminders: boom') "and logs it: $log"
        # the popup step too: logged, and the run ends normally
        function script:Invoke-JkDueRemind { throw 'popup broke' }
        $threw = $null; try { Invoke-JkTick } catch { $threw = $_.Exception.Message }
        $log = [IO.File]::ReadAllText((Get-JkPath 'background.log'))
        Assert-True (-not $threw -and $log -match 'popup: popup broke') "a failing popup is logged, the run ends normally: [$threw]"
    } finally {
        foreach ($f in $tickFns) { Set-Item "function:script:$f" $origTick[$f] }
        Set-Item function:script:Start-JkBackground $origBg; Set-Item function:script:Show-JkNotify $origNotify
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null
    }
}
Test 'an unreadable to-do, class or focus session is set aside too: views work, a save keeps it, jk doctor names it; a class at 9am is read as 09:00' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'unreadable2-home'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $w = { param($f, $j) [IO.File]::WriteAllText((Join-Path $env:JK_HOME $f), $j) }
        & $w 'todo.json' '{"nextId":3,"items":[{"id":1,"text":"email the TA","due":"soon","done":false},{"id":2,"text":"buy ink","due":"2026-11-10T17:00:00","done":false}]}'
        & $w 'classes.json' '{"nextId":3,"items":[{"id":1,"course":"co367","kind":"LEC","days":["Tue","Thu"],"start":"morning","end":"09:50","room":"MC 2017","from":"","to":""},{"id":2,"course":"cs341","kind":"LEC","days":["Tue"],"start":"9am","end":"10:20","room":"DWE 3522","from":"","to":""}]}'
        & $w 'focus.json' '{"active":null,"sessions":[{"start":"yesterday","minutes":25,"actual":25,"label":"cs341"},{"start":"2026-11-10T08:00:00","minutes":25,"actual":25,"label":"cs341"}]}'
        $env:JK_NOW = '2026-11-10T09:00:00'
        Assert-Eq "$(@((Get-JkTodoData).items).Count)|$(@((Get-JkClassData).items).Count)|$(@((Get-JkFocusData).sessions).Count)" '1|1|1' 'one of each read'
        Assert-Eq ([string]@((Get-JkClassData).items)[0].start) '09:00' '9am read as 09:00'
        $failed = @()
        foreach ($v in @({ Show-JkDashboard }, { Invoke-JkTodo }, { Invoke-JkClass }, { Invoke-JkClass week }, { Invoke-JkFocus log }, { Show-JkPlan }, { Show-JkReview })) { try { $null = & $v 6>&1 } catch { $failed += $_.Exception.Message } }
        Assert-True (-not $failed.Count) "every view works: $($failed -join ' / ')"
        # saves keep the unreadable ones as they were
        $t = Get-JkTodoData; Save-JkTodoData $t; $c = Get-JkClassData; Save-JkClassData $c; $f = Get-JkFocusData; Save-JkFocusData $f
        $rt = [IO.File]::ReadAllText((Join-Path $env:JK_HOME 'todo.json')) | ConvertFrom-Json
        $rc = [IO.File]::ReadAllText((Join-Path $env:JK_HOME 'classes.json')) | ConvertFrom-Json
        $rf = [IO.File]::ReadAllText((Join-Path $env:JK_HOME 'focus.json')) | ConvertFrom-Json
        Assert-True (@($rt.items | Where-Object { $_.due -eq 'soon' }).Count -eq 1 -and @($rc.items | Where-Object { $_.start -eq 'morning' }).Count -eq 1 -and @($rf.sessions | Where-Object { $_.start -eq 'yesterday' }).Count -eq 1 -and -not $rt.PSObject.Properties['unreadable']) 'each kept as it was after a save'
        $doc = @(Invoke-JkDoctor 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'unreadable (to-do|class|focus log)\s' })
        Assert-Eq $doc.Count 3 "jk doctor names one of each: $($doc -join ' / ')"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'a deadline no screen can read (date 2026-13-01) is set aside: every view still works, a save keeps it as it was, jk doctor names it; 7pm is read as 19:00' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'unreadable-home'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $json = @'
{ "version": 1, "nextId": 4, "term": null,
  "courses": [ { "key": "cs341", "code": "CS 341", "name": "Algorithms", "color": "#7C9CF8" } ],
  "events": [
    { "id": 1, "course": "cs341", "date": "2026-11-10", "time": "23:59", "title": "Assignment 3", "kind": "due" },
    { "id": 2, "course": "cs341", "date": "2026-13-01", "time": "23:59", "title": "Assignment 4", "kind": "due" },
    { "id": 3, "course": "cs341", "date": "2026-11-11", "time": "7pm", "title": "Midterm 2", "kind": "exam" }
  ] }
'@
        [IO.File]::WriteAllText((Join-Path $env:JK_HOME 'deadlines.json'), $json)
        $env:JK_NOW = '2026-11-09T09:00:00'
        $d = Get-JkDueData
        Assert-Eq "$(@($d.events).Count)|$(@(Get-JkProp $d 'unreadable' @()).Count)" '2|1' 'two readable, one set aside'
        Assert-Eq ([string]@($d.events | Where-Object { $_.id -eq 3 })[0].time) '19:00' '7pm read as 19:00'
        $failed = @()
        foreach ($v in @({ Show-JkDashboard }, { Show-JkDue }, { Show-JkNext }, { Show-JkReview }, { $null = Get-JkBriefLine }, { Show-JkDueAll })) { try { $null = & $v 6>&1 } catch { $failed += $_.Exception.Message } }
        Assert-True (-not $failed.Count) "every view works: $($failed -join ' / ')"
        # a save (adding a deadline) writes the unreadable record back unchanged
        $d = Get-JkDueData; $null = New-JkEvent -Data $d -Course 'cs341' -Date ([datetime]'2026-11-20') -Time '23:59' -Title 'Assignment 5'; Save-JkDueData $d
        $raw = [IO.File]::ReadAllText((Join-Path $env:JK_HOME 'deadlines.json')) | ConvertFrom-Json
        $kept = @($raw.events | Where-Object { [string]$_.id -eq '2' })[0]
        Assert-True ($kept -and $kept.date -eq '2026-13-01' -and $kept.title -eq 'Assignment 4' -and @($raw.events).Count -eq 4 -and -not $raw.PSObject.Properties['unreadable']) "kept as it was: $($raw.events | ConvertTo-Json -Compress)"
        $doc = @(Invoke-JkDoctor 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'unreadable deadline\s' })
        Assert-True ($doc.Count -eq 1 -and $doc[0] -match "#2 Assignment 4: date '2026-13-01'") "jk doctor: $($doc -join ' / ')"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'a course page keeps an exam being written as its exam, under way until its end, then the next one' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'coursexam-home'; $script:JkConfigCache = $null
    try {
        $dd = Get-JkDueData; $a = Resolve-JkCourse $dd 'cs341' -Create
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-11-09') -Time '18:00' -End '19:50' -Title 'Midterm 2' -Kind 'exam' -Weight '20%'
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-12-12') -Time '12:30' -End '15:00' -Title 'FINAL' -Kind 'exam' -Weight '44%'
        Save-JkDueData $dd
        $examRow = { param($now) $env:JK_NOW = $now; [string]@(Show-JkCourseBrief (Resolve-JkCourse (Get-JkDueData) 'cs341') 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match '^\s+exam\s' })[0] }
        $r = & $examRow '2026-11-09T15:00:00'; Assert-True ($r -match 'Midterm 2\s+today 6:00 pm') "3 pm: $r"
        $r = & $examRow '2026-11-09T18:40:00'; Assert-True ($r -match 'Midterm 2\s+under way, until 7:50 pm') "6:40 pm, in it: $r"
        $r = & $examRow '2026-11-09T19:50:00'; Assert-True ($r -match 'FINAL\s+Sat Dec 12') "7:50 pm, over: $r"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null
    }
}
Test 'jk next: an exam with no end time is under way for two hours, as the dashboard has it; an online window opening is not' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'nextnoend-home'; $script:JkConfigCache = $null
    try {
        $dd = Get-JkDueData; $a = Resolve-JkCourse $dd 'cs341' -Create; $b = Resolve-JkCourse $dd 'cs350' -Create; $h = Resolve-JkCourse $dd 'health105' -Create
        $null = New-JkEvent -Data $dd -Course $b.key -Date ([datetime]'2026-11-17') -Time '19:00' -Title 'Midterm' -Kind 'exam'
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-11-18') -Time '18:00' -End '19:50' -Title 'Midterm 2' -Kind 'exam'
        $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-11-19') -Time '06:00' -Title 'Midterm opens' -Kind 'exam'
        $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-11-21') -Time '23:59' -Title 'Midterm closes' -Kind 'exam'
        Save-JkDueData $dd
        $first = { param($now) $env:JK_NOW = $now; [string]@(Get-JkNextSteps (Get-JkNow))[0].Text }
        Assert-Eq (& $first '2026-11-17T20:00:00') 'CS 350 Midterm, under way until 9:00 pm' 'an hour into one with no end time'
        Assert-Eq (& $first '2026-11-18T19:00:00') 'CS 341 Midterm 2, under way until 7:50 pm' 'one with an end time, as before'
        $w = & $first '2026-11-19T07:00:00'
        Assert-True ($w -notmatch 'under way') "an hour after a window opens, not an exam under way: $w"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null
    }
}
Test 'jk exam <course> during the exam shows it, under way until its end, then moves on; an open online window still says open now' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'briefduring-home'; $script:JkConfigCache = $null
    try {
        $dd = Get-JkDueData; $a = Resolve-JkCourse $dd 'cs341' -Create; $b = Resolve-JkCourse $dd 'cs350' -Create; $h = Resolve-JkCourse $dd 'health105' -Create
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-11-09') -Time '18:00' -End '19:50' -Title 'Midterm 2' -Kind 'exam'
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-12-12') -Time '12:30' -End '15:00' -Title 'FINAL' -Kind 'exam'
        $null = New-JkEvent -Data $dd -Course $b.key -Date ([datetime]'2026-11-09') -Time '19:00' -Title 'Midterm' -Kind 'exam'
        $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-11-08') -Time '06:00' -Title 'Quiz opens' -Kind 'exam'
        $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-11-10') -Time '23:59' -Title 'Quiz closes' -Kind 'exam'
        Save-JkDueData $dd
        $head = { param($now, $course) $env:JK_NOW = $now; $l = @(Invoke-JkExams $course 6>&1 | ForEach-Object { "$_" } | Where-Object { $_.Trim() }); $l[0] }
        $r = try { & $head '2026-11-09T19:00:00' 'cs341' } catch { "error: $($_.Exception.Message)" }
        Assert-True ($r -match 'CS 341 MIDTERM 2.*under way, until 7:50 pm') "7 pm, in the midterm: $r"
        $r = try { & $head '2026-11-09T19:50:00' 'cs341' } catch { "error: $($_.Exception.Message)" }
        Assert-True ($r -match 'CS 341 FINAL') "7:50 pm, it ended: $r"
        # no end time: two hours
        $r = try { & $head '2026-11-09T20:00:00' 'cs350' } catch { "error: $($_.Exception.Message)" }
        Assert-True ($r -match 'CS 350 MIDTERM.*under way, until 9:00 pm') "an hour into one with no end time: $r"
        $r = try { & $head '2026-11-09T12:00:00' 'health105' } catch { "error: $($_.Exception.Message)" }
        Assert-True ($r -match 'HEALTH 105 QUIZ.*open now') "an online window: $r"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null
    }
}
Test 'at an exam''s end time it is over on every screen: the dashboard and jk exams agree with jk due at 10:00 pm for a 7:30-10:00 pm final' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'examend-home'; $script:JkConfigCache = $null
    try {
        $dd = Get-JkDueData; $c = Resolve-JkCourse $dd 'co367' -Create
        $null = New-JkEvent -Data $dd -Course $c.key -Date ([datetime]'2026-12-19') -Time '19:30' -End '22:00' -Title 'FINAL' -Kind 'exam' -Weight '50%'
        Save-JkDueData $dd
        $look = { param($now) $env:JK_NOW = $now
            [pscustomobject]@{
                Dash  = [string]@(Show-JkDashboard 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'NEXT EXAM' })[0]
                Exams = [string]@(Invoke-JkExams 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'CO 367\s+FINAL' })[0]
                Due   = [string]@(Show-JkDue 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'CO 367\s+FINAL' })[0] } }
        $r = & $look '2026-12-19T21:59:00'
        Assert-True ($r.Dash -match 'CO 367 FINAL\s+NOW' -and $r.Exams -and $r.Due -match '\snow\s') "9:59 pm, under way everywhere: $($r.Dash) | $($r.Exams) | $($r.Due)"
        $r = & $look '2026-12-19T22:00:00'
        Assert-True ($r.Dash -notmatch 'CO 367 FINAL' -and -not $r.Exams -and $r.Due -match '\sover\s') "10:00 pm, over everywhere: [$($r.Dash)] | [$($r.Exams)] | $($r.Due)"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null
    }
}
Test 'an online exam is over when its window closes: after 11:59 pm the dashboard and jk exams move on (not until 1:59 am)' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'winclose-home'; $script:JkConfigCache = $null
    try {
        $dd = Get-JkDueData; $h = Resolve-JkCourse $dd 'health105' -Create; $f = Resolve-JkCourse $dd 'cs370' -Create
        $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-12-07') -Time '06:00' -Title 'Midterm 2 opens' -Kind 'exam' -Weight '17.5%'
        $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-12-08') -Time '23:59' -Title 'Midterm 2 closes' -Kind 'exam' -Weight '17.5%'
        $null = New-JkEvent -Data $dd -Course $f.key -Date ([datetime]'2026-12-10') -Time '16:00' -Title 'FINAL' -Kind 'exam' -Weight '40%'
        # an exam in a room with no end time: two hours, as before
        $null = New-JkEvent -Data $dd -Course $f.key -Date ([datetime]'2026-12-12') -Time '18:00' -Title 'Lab exam' -Kind 'exam'
        Save-JkDueData $dd
        $look = { param($now) $env:JK_NOW = $now
            $d = @(Show-JkDashboard 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'NEXT EXAM' })[0]
            $x = @(Invoke-JkExams 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match '^\s+\S+\s+(HEALTH 105|CS 370)\s' })
            [pscustomobject]@{ Dash = $d; Exams = $x } }
        $r = & $look '2026-12-08T23:30:00'
        Assert-True ($r.Dash -match 'HEALTH 105 Midterm 2\s+OPEN NOW') "open, 11:30 pm: $($r.Dash)"
        $r = & $look '2026-12-09T00:30:00'
        Assert-True ($r.Dash -match 'NEXT EXAM\s+CS 370 FINAL') "closed at 11:59 pm, 12:30 am: $($r.Dash)"
        Assert-True (-not @($r.Exams | Where-Object { $_ -match 'HEALTH 105' }).Count) "jk exams no longer lists it: $($r.Exams -join ' / ')"
        $env:JK_NOW = '2026-12-12T19:00:00'
        Assert-Eq (Get-JkStartedLabel @((Get-JkDueData).events | Where-Object { $_.title -eq 'Lab exam' })[0] (Get-JkDueData) (Get-JkNow)) 'now' 'a room exam with no end time is still on an hour in'
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null
    }
}
Test 'jk exam prep row gives the weight as stored: of prep for 17.5%, not 18%' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'prepweight-home'; $script:JkConfigCache = $null
    try {
        $dd = Get-JkDueData; $h = Resolve-JkCourse $dd 'health105' -Create
        $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-11-12') -Time '18:00' -End '19:30' -Title 'Midterm 2' -Kind 'exam' -Weight '17.5%'
        Save-JkDueData $dd
        $env:JK_NOW = '2026-11-09T09:00:00'
        $brief = @(Invoke-JkExams 'health105' 6>&1 | ForEach-Object { "$_" })
        $prep = @($brief | Where-Object { $_ -match '^\s+prep\s' })[0]
        Assert-True ($prep -match 'of prep for 17[.,]5%') "prep: $prep"
        $worth = @($brief | Where-Object { $_ -match '^\s+worth\s' })[0]
        Assert-True ($worth -match 'worth\s+17[.,]5% of HEALTH 105') "worth: $worth"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null
    }
}
Test 'jk exam: worth 17.5% (not 18%), one notes row without the times its when row gives; jk review fits a week in 80 columns' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH
    $env:JK_HOME = Join-Path $saved 'exambrief-home'; $script:JkConfigCache = $null
    try {
        $dd = Get-JkDueData; $h = Resolve-JkCourse $dd 'health105' -Create; $f = Resolve-JkCourse $dd 'cs370' -Create
        $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-12-07') -Time '06:00' -Title 'Midterm 2 opens' -Kind 'exam' -Weight '17.5%' -Note "6:00 am Dec 7 $($script:G.arrow) 11:59 pm Dec 8 $($script:G.dot) LEARN quiz"
        $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-12-08') -Time '23:59' -Title 'Midterm 2 closes' -Kind 'exam' -Weight '17.5%' -Note "11:59 pm $($script:G.dot) no reopening"
        $null = New-JkEvent -Data $dd -Course $f.key -Date ([datetime]'2026-12-10') -Time '16:00' -End '18:30' -Title 'FINAL' -Kind 'exam' -Weight '40%' -Note "4:00 $($script:G.dash) 6:30 pm $($script:G.dot) room TBA (Odyssey)"
        $null = New-JkEvent -Data $dd -Course $f.key -Date ([datetime]'2026-11-09') -Time '23:59' -Title 'Assignment 3' -Weight '7%'
        Save-JkDueData $dd
        $env:JK_NOW = '2026-11-08T20:30:00'
        $brief = @(Invoke-JkExams 'health105' 6>&1 | ForEach-Object { "$_" })
        $notes = @($brief | Where-Object { $_ -match '^\s+notes\s' })
        Assert-True ($notes.Count -eq 1 -and $notes[0] -match 'notes\s+LEARN quiz . no reopening\s*$') "one notes row, no times: $($notes -join ' / ')"
        $worth = @($brief | Where-Object { $_ -match '^\s+worth\s' })[0]
        Assert-True ($worth -match 'worth\s+17[.,]5% of HEALTH 105') "worth: $worth"
        $fin = @(Invoke-JkExams 'cs370' 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match '^\s+notes\s' })
        Assert-True ($fin.Count -eq 1 -and $fin[0] -match 'notes\s+room TBA \(Odyssey\)\s*$') "a final's note, its times in 'when': $($fin -join ' / ')"
        # jk review in an 80-column window: the week's strip on one line, tod through Sun
        $env:JK_WIDTH = '79'
        $rev = @(Show-JkReview 6>&1 | ForEach-Object { "$_" })
        $strip = @($rev | Where-Object { $_ -match '^\s+tod\s' })
        Assert-True ($strip.Count -eq 1 -and $strip[0] -match '\bSun\s*$') "the strip: $($strip -join ' / ') / next: $(@($rev)[([array]::IndexOf($rev, $strip[0]) + 1)])"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $script:JkConfigCache = $null
    }
}
Test 'the dashboard study line ending in jk plan start leads with the course that begins, after focus on another too' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'studyline-home'; $script:JkConfigCache = $null
    $origPlan = ${function:Get-JkPlanToday}; $origFocus = ${function:Get-JkTodayFocusByCourse}
    try {
        $dd = Get-JkDueData; $c = Resolve-JkCourse $dd 'cs341' -Create; $h = Resolve-JkCourse $dd 'health105' -Create
        Save-JkDueData $dd
        $env:JK_NOW = '2026-11-09T07:50:00'
        $mk = { param($k, $course, $title, $due) [pscustomobject]@{ Key = $k; Course = $course; Title = $title; Due = [datetime]$due; Id = 0 } }
        $script:StubPlan = [pscustomobject]@{ Items = @((& $mk 'k1' $c.key 'Midterm 2' '2026-11-09T18:00'), (& $mk 'k2' $h.key 'Assignment 6' '2026-11-09T23:59')); Today = [pscustomobject]@{ Alloc = @{ k1 = 75.0; k2 = 75.0 } } }
        function script:Get-JkPlanToday { $script:StubPlan }
        function script:Get-JkTodayFocusByCourse { param($Now) $script:StubFocus }
        $script:StubFocus = @{}
        $line = [string](Get-JkPlanLine)
        Assert-True ($line -match '^\W*CS341 1h 15m') "nothing done yet, the midterm (due first): $line"
        # 50 minutes on CS 341: jk plan start now begins HEALTH 105, so it leads
        $script:StubFocus = @{ ([string]$c.key) = 50.0 }
        $line = [string](Get-JkPlanLine)
        Assert-True ($line -match '^\W*HEALTH105 1h 15m\W+CS341 50m/1h 15m') "after 50m on CS 341: $line"
        Assert-Eq ([string](Get-JkPlanNext $script:StubPlan $script:StubFocus).Course) ([string]$h.key) 'and that is what jk plan start begins'
    } finally {
        Set-Item function:script:Get-JkPlanToday $origPlan; Set-Item function:script:Get-JkTodayFocusByCourse $origFocus
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null
    }
}
Test 'a course page offers jk plan start only when that begins this course, else its own focus block; and jk plan keeps a gap between columns at 80 columns' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH
    $origPlan = ${function:Get-JkPlanToday}; $origFocus = ${function:Get-JkTodayFocusByCourse}
    try {
        # jk plan in an 80-column terminal, planned for real: "HEALTH 105 A6  today", not "Assignment 6today"
        $env:JK_HOME = Join-Path $saved 'plan80-home'; $script:JkConfigCache = $null
        $dd = Get-JkDueData; $h = Resolve-JkCourse $dd 'health105' -Create
        $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-11-10') -Time '23:59' -Title 'Assignment 6' -Weight '7.5%'
        Save-JkDueData $dd
        $env:JK_NOW = '2026-11-09T07:50:00'; $env:JK_WIDTH = '79'
        $out = @(Show-JkPlan 6>&1 | ForEach-Object { "$_" })
        $row = @($out | Where-Object { $_ -match 'HEALTH 105' })[0]
        Assert-True ($row -match 'HEALTH 105 A6\s+tmrw') "80 columns: $row"
        $env:JK_WIDTH = $savedW

        # the course pages on Monday: the midterm (6 pm) and the assignment (11:59 pm), 1h 15m each
        $env:JK_HOME = Join-Path $saved 'coursehint-home'; $script:JkConfigCache = $null
        $dd = Get-JkDueData; $c = Resolve-JkCourse $dd 'cs341' -Create; $h = Resolve-JkCourse $dd 'health105' -Create
        Save-JkDueData $dd
        $mk = { param($k, $course, $title, $due) [pscustomobject]@{ Key = $k; Course = $course; Title = $title; Due = [datetime]$due; Id = 0 } }
        $script:StubPlan = [pscustomobject]@{ Items = @((& $mk 'k1' $c.key 'Midterm 2' '2026-11-09T18:00'), (& $mk 'k2' $h.key 'Assignment 6' '2026-11-09T23:59')); Today = [pscustomobject]@{ Alloc = @{ k1 = 75.0; k2 = 75.0 } } }
        function script:Get-JkPlanToday { $script:StubPlan }
        function script:Get-JkTodayFocusByCourse { param($Now) $script:StubFocus }
        $study = { param($course) $dd2 = Get-JkDueData; @(Show-JkCourseBrief (Resolve-JkCourse $dd2 $course) 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match '^\s+study\s' })[0] }
        $script:StubFocus = @{}
        $r = & $study 'cs341'; Assert-True ($r -match '1h 15m today\s+. jk plan start$') "CS 341, which jk plan start begins: $r"
        $r = & $study 'health105'
        Assert-True ($r -match '1h 15m today\s+. jk focus 25 health105 assignment 6$') "HEALTH 105, which it does not: $r"
        # 50 minutes on CS 341: what is left, and jk plan start now begins HEALTH 105
        $script:StubFocus = @{ ([string]$c.key) = 50.0 }
        $r = & $study 'cs341'; Assert-True ($r -match '25m left of 1h 15m today\s+. jk focus 25 cs341 midterm 2$') "CS 341 after 50m: $r"
        $r = & $study 'health105'; Assert-True ($r -match '1h 15m today\s+. jk plan start$') "HEALTH 105 now leads: $r"
        $script:StubFocus = @{ ([string]$c.key) = 80.0 }
        $r = & $study 'cs341'; Assert-True ($r -match '1h 15m today, done') "CS 341 done for today: $r"
    } finally {
        Set-Item function:script:Get-JkPlanToday $origPlan; Set-Item function:script:Get-JkTodayFocusByCourse $origFocus
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $script:JkConfigCache = $null
    }
}
Test 'two courses with the same study time or the same share of marks: the one due first leads (dashboard, popup, jk review), either way round' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $origPlan = ${function:Get-JkPlanToday}; $origFocus = ${function:Get-JkTodayFocusByCourse}; $origNotify = ${function:Show-JkNotify}
    function script:Get-JkPlanToday { $script:StubPlan }
    function script:Get-JkTodayFocusByCourse { param($Now) @{} }
    function script:Show-JkNotify { param([string]$Title, [string[]]$Lines) $script:TieLines = $Lines; 'stub' }
    try {
        foreach ($round in 1, 2) {
            $env:JK_HOME = Join-Path $saved "tie-home$round"; $script:JkConfigCache = $null
            $dd = Get-JkDueData
            $c = Resolve-JkCourse $dd 'cs341' -Create; $h = Resolve-JkCourse $dd 'health105' -Create
            # round 1: CS 341 due first; round 2: HEALTH 105 due first. Same study time, same weight.
            $cDue = $(if ($round -eq 1) { '18:00' } else { '23:30' }); $hDue = $(if ($round -eq 1) { '23:30' } else { '18:00' })
            $null = New-JkEvent -Data $dd -Course $c.key -Date ([datetime]'2026-11-09') -Time $cDue -Title 'Midterm 2' -Weight '10%'
            $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-11-09') -Time $hDue -Title 'Assignment 6' -Weight '10%'
            Save-JkDueData $dd
            $env:JK_NOW = '2026-11-09T07:50:00'
            $mk = { param($k, $course, $title, $due) [pscustomobject]@{ Key = $k; Course = $course; Title = $title; Due = [datetime]"2026-11-09T$due"; Id = 0 } }
            $script:StubPlan = [pscustomobject]@{ Items = @((& $mk 'k1' $c.key 'Midterm 2' $cDue), (& $mk 'k2' $h.key 'Assignment 6' $hDue)); Today = [pscustomobject]@{ Alloc = @{ k1 = 75.0; k2 = 75.0 } } }
            $lead = $(if ($round -eq 1) { 'CS' } else { 'HEALTH' })
            $line = [string](Get-JkPlanLine)
            Assert-True ($line -match "^\W*$lead") "round ${round}, dashboard STUDY TODAY leads with $($lead): $line"
            $script:TieLines = $null; Invoke-JkDueRemind -Quiet -Force
            $study = @($script:TieLines | Where-Object { $_ -like 'Study today:*' })[0]
            Assert-True ($study -match "^Study today: $lead") "round ${round}, popup: $study"
            $env:JK_NOW = '2026-11-08T20:00:00'
            $rev = @(Show-JkReview 6>&1 | ForEach-Object { "$_" })
            $sugg = @($rev | Where-Object { $_ -match 'suggestion:' })[0]
            Assert-True ($sugg -match "start with $lead") "round ${round}, review: $sugg"
        }
    } finally {
        Set-Item function:script:Get-JkPlanToday $origPlan; Set-Item function:script:Get-JkTodayFocusByCourse $origFocus; Set-Item function:script:Show-JkNotify $origNotify
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null
    }
}
Test 'jk next leads its study with what jk plan start begins: a tie goes to the earlier deadline, and focus already done comes off (25m left of 1h 15m)' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'nextplan-home'; $script:JkConfigCache = $null
    $origPlan = ${function:Get-JkPlanToday}; $origFocus = ${function:Get-JkTodayFocusByCourse}
    try {
        $dd = Get-JkDueData
        $c = Resolve-JkCourse $dd 'cs341' -Create; $h = Resolve-JkCourse $dd 'health105' -Create; $o = Resolve-JkCourse $dd 'cs350' -Create
        Save-JkDueData $dd
        $env:JK_NOW = '2026-11-09T07:50:00'
        # Monday's real plan: the midterm (6 pm) and an assignment (11:59 pm) at 1h 15m each, the plan's order
        $mk = { param($k, $course, $title, $due) [pscustomobject]@{ Key = $k; Course = $course; Title = $title; Due = [datetime]$due; Id = 0 } }
        $script:StubPlan = [pscustomobject]@{
            Items = @((& $mk 'k1' $c.key 'Midterm 2' '2026-11-09T18:00'), (& $mk 'k2' $h.key 'Assignment 6' '2026-11-09T23:59'), (& $mk 'k3' $o.key 'A2B Concurrency' '2026-11-11T20:00'))
            Today = [pscustomobject]@{ Alloc = @{ k1 = 75.0; k2 = 75.0; k3 = 25.0 } } }
        function script:Get-JkPlanToday { $script:StubPlan }
        $script:StubFocus = @{}
        function script:Get-JkTodayFocusByCourse { param($Now) $script:StubFocus }
        $steps = @(Get-JkNextSteps (Get-JkNow))
        $txt = ($steps | ForEach-Object { "$($_.Text) => $($_.Hint)" }) -join ' / '
        Assert-True ($steps[0].Text -eq 'Study CS 341 Midterm 2: 1h 15m planned today' -and $steps[0].Hint -eq 'jk plan start') "a tie, the earlier deadline leads: $txt"
        Assert-True ($steps[1].Text -like 'Study HEALTH 105 Assignment 6: *' -and $steps[1].Hint -match '^jk focus 25 \S+ assignment 6$') "the next one has its own focus command: $txt"
        # 50 minutes on CS 341 so far: the assignment now has the most left, and leads
        $script:StubFocus = @{ ([string]$c.key) = 50.0 }
        $steps = @(Get-JkNextSteps (Get-JkNow))
        $txt = ($steps | ForEach-Object { "$($_.Text) => $($_.Hint)" }) -join ' / '
        $first = $(try { Get-JkPlanNext $script:StubPlan $script:StubFocus } catch { $null })
        Assert-True ($steps[0].Text -like 'Study HEALTH 105 Assignment 6: 1h 15m*' -and $steps[0].Hint -eq 'jk plan start' -and $first.Key -eq 'k2') "after 50m on CS 341: $txt"
        Assert-True (@($steps | Where-Object { $_.Text -eq 'Study CS 341 Midterm 2: 25m left of 1h 15m today' }).Count -eq 1) "what is left of it: $txt"
    } finally {
        Set-Item function:script:Get-JkPlanToday $origPlan; Set-Item function:script:Get-JkTodayFocusByCourse $origFocus
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null
    }
}
Test 'the morning popup and jk review count as the dashboard does: +2 more due (not +3), one online exam today (not 2 exams), 1 deadline for a quiz window' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $origNotify = ${function:Show-JkNotify}; $origPlan = ${function:Get-JkPlanToday}
    function script:Show-JkNotify { param([string]$Title, [string[]]$Lines) $script:CountTitle = $Title; 'stub' }
    function script:Get-JkPlanToday { $null }
    $popup = { param($home2, $now) $env:JK_HOME = Join-Path $saved $home2; $script:JkConfigCache = $null; $env:JK_NOW = $now; $script:CountTitle = $null; Invoke-JkDueRemind -Quiet -Force; [string]$script:CountTitle }
    $add = { param($home2, $course, $date, $time, $title, $kind)
        $env:JK_HOME = Join-Path $saved $home2; $script:JkConfigCache = $null
        $dd = Get-JkDueData; $c = Resolve-JkCourse $dd $course -Create
        $null = New-JkEvent -Data $dd -Course $c.key -Date ([datetime]$date) -Time $time -Title $title -Kind $(if ($kind) { $kind } else { 'due' })
        Save-JkDueData $dd }
    try {
        # an exam tomorrow, an assignment and a quiz window (opens and closes) within the two days
        & $add 'cnt-a' 'cs341' '2026-11-09' '18:00' 'Midterm 2' 'exam'
        & $add 'cnt-a' 'health105' '2026-11-09' '23:59' 'Assignment 6'
        & $add 'cnt-a' 'cs341' '2026-11-09' '09:00' 'Quiz 5 opens'
        & $add 'cnt-a' 'cs341' '2026-11-09' '21:00' 'Quiz 5 closes'
        $t = & $popup 'cnt-a' '2026-11-08T07:45:00'
        Assert-True ($t -match '^Exam tomorrow: CS 341 Midterm 2 6:00 pm \(\+2 more due\)$') "exam tomorrow: $t"
        # an online midterm that opens and closes today
        & $add 'cnt-b' 'health105' '2026-11-09' '06:00' 'Midterm opens' 'exam'
        & $add 'cnt-b' 'health105' '2026-11-09' '23:59' 'Midterm closes' 'exam'
        $t = & $popup 'cnt-b' '2026-11-09T05:30:00'
        Assert-True ($t -match '^Exam today: HEALTH 105 Midterm, by 11:59 pm$') "one online exam today: $t"
        # nothing but a quiz window: one deadline; nothing but an opening: what opens, and when
        & $add 'cnt-c' 'cs341' '2026-11-09' '09:00' 'Quiz 5 opens'
        & $add 'cnt-c' 'cs341' '2026-11-09' '21:00' 'Quiz 5 closes'
        $t = & $popup 'cnt-c' '2026-11-08T07:45:00'
        Assert-True ($t -eq '1 deadline in the next 48h') "a quiz window: $t"
        & $add 'cnt-d' 'cs341' '2026-11-09' '09:00' 'Quiz 6 opens'
        $t = & $popup 'cnt-d' '2026-11-08T07:45:00'
        Assert-True ($t -eq 'CS 341 Quiz 6 opens tomorrow 9:00 am') "only an opening: $t"
        # jk review's look ahead: the online midterm is one exam
        $env:JK_HOME = Join-Path $saved 'cnt-b'; $script:JkConfigCache = $null; $env:JK_NOW = '2026-11-08T20:00:00'
        $rev = @(Show-JkReview 6>&1 | ForEach-Object { "$_" })
        $line = @($rev | Where-Object { $_ -match '\d+ items?\s' })[0]
        Assert-True ($line -match '2 items\s+.\s+1 exam\b') "review: $line"
    } finally {
        Set-Item function:script:Show-JkNotify $origNotify; Set-Item function:script:Get-JkPlanToday $origPlan
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null
    }
}
Test 'the dashboard week header says 2 due, 2 exams, not 6 due: an exam is not due, and an online exam or a quiz window counts once' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'dashcount-home'; $script:JkConfigCache = $null
    try {
        $dd = Get-JkDueData
        $c = Resolve-JkCourse $dd 'cs341' -Create; $h = Resolve-JkCourse $dd 'health105' -Create
        $null = New-JkEvent -Data $dd -Course $c.key -Date ([datetime]'2026-11-10') -Time '18:00' -Title 'Midterm 2' -Kind 'exam'
        $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-11-11') -Time '06:00' -Title 'Midterm opens' -Kind 'exam'
        $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-11-12') -Time '23:59' -Title 'Midterm closes' -Kind 'exam'
        $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-11-10') -Time '23:59' -Title 'Assignment 6'
        $null = New-JkEvent -Data $dd -Course $c.key -Date ([datetime]'2026-11-11') -Time '09:00' -Title 'Quiz 5 opens'
        $null = New-JkEvent -Data $dd -Course $c.key -Date ([datetime]'2026-11-11') -Time '23:59' -Title 'Quiz 5 closes'
        Save-JkDueData $dd
        $env:JK_NOW = '2026-11-09T09:00:00'
        $dash = @(Show-JkDashboard 6>&1 | ForEach-Object { "$_" })
        $head = @($dash | Where-Object { $_ -match 'THIS WEEK' })[0]
        # six rows: two exams (one of them online), the assignment, and the quiz (its opening is not due)
        Assert-True ($head -match 'THIS WEEK\s+2 due, 2 exams in 7 days\s*$') "header: $head"
        $fmt = try { "$(Format-JkDueCounts ([pscustomobject]@{ Due = 0; Exams = 3 }))|$(Format-JkDueCounts ([pscustomobject]@{ Due = 4; Exams = 0 }))|$(Format-JkDueCounts ([pscustomobject]@{ Due = 0; Exams = 0 }))|$(Format-JkDueCounts ([pscustomobject]@{ Due = 1; Exams = 1 }))" } catch { "error: $($_.Exception.Message)" }
        Assert-Eq $fmt '3 exams|4 due|0 due|1 due, 1 exam' 'the wordings'
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null
    }
}
Test 'jk week: a title too long for its cell is shortened (HEALTH105 A6, CS341 Mid 2), not cut to HEALTH105 As...; one that fits stays whole' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH
    $env:JK_HOME = Join-Path $saved 'weekshort-home'; $script:JkConfigCache = $null
    try {
        $dd = Get-JkDueData
        $h = Resolve-JkCourse $dd 'health105' -Create; $c = Resolve-JkCourse $dd 'cs341' -Create; $o = Resolve-JkCourse $dd 'co367' -Create
        $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-11-16') -Time '23:59' -Title 'Assignment 7'
        $null = New-JkEvent -Data $dd -Course $o.key -Date ([datetime]'2026-11-16') -Time '23:00' -Title 'Assignment 4 closes'
        $null = New-JkEvent -Data $dd -Course $c.key -Date ([datetime]'2026-11-17') -Time '18:00' -Title 'Midterm 2' -Kind 'exam'
        $null = New-JkEvent -Data $dd -Course $c.key -Date ([datetime]'2026-11-18') -Time '12:00' -Title 'Lab 4'
        Save-JkDueData $dd
        $env:JK_NOW = '2026-11-15T10:00:00'; $env:JK_WIDTH = '100'
        $out = (@(Show-JkDueWeek 6>&1 | ForEach-Object { "$_" }) -join "`n")
        foreach ($want in 'HEALTH105 A7', 'CO367 A4 ', 'CS341 Mid 2', 'CS341 Lab 4') { Assert-True ($out.Contains($want)) "a cell reads '$want': $out" }
        Assert-True (-not $out.Contains('HEALTH105 As')) "no cut 'HEALTH105 As...': $out"
        # wide enough for the whole title, it stays whole
        $env:JK_WIDTH = '130'
        $wide = (@(Show-JkDueWeek 6>&1 | ForEach-Object { "$_" }) -join "`n")
        Assert-True ($wide.Contains('CS341 Midterm 2')) "at 130 columns: $wide"
        $short = try { "$(Get-JkShortTitle 'Assignment 6')|$(Get-JkShortTitle 'Midterm 2 opens')|$(Get-JkShortTitle 'Assignment 4 closes')|$(Get-JkShortTitle 'Quiz 3')|$(Get-JkShortTitle 'A3 File Systems')" } catch { "error: $($_.Exception.Message)" }
        Assert-Eq $short 'A6|Mid 2 opens|A4|Q3|A3 File Systems' 'the short forms'
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $script:JkConfigCache = $null
    }
}
Test 'the term line on the last day of classes says classes end today, and exams tomorrow the day before; not in 0d, in 1d' {
    $dot = " $($script:G.dot) "
    $line = { param($phase, $toEnd, $toExams) Format-JkTermLine ([pscustomobject]@{ Name = 'Fall 2026'; Phase = $phase; InBreak = $false; BreakName = ''; Week = 13; TotalWeeks = 13; DaysToEnd = $toEnd; DaysToExams = $toExams }) }
    Assert-Eq (& $line 'classes' 0 2) "Fall 2026${dot}Week 13 of 13${dot}classes end today${dot}exams in 2d" 'Tue Dec 8, the last day of classes'
    Assert-Eq (& $line 'classes' 1 3) "Fall 2026${dot}Week 13 of 13${dot}classes end tomorrow${dot}exams in 3d" 'the day before'
    Assert-Eq (& $line 'study' $null 1) "Fall 2026${dot}study break${dot}exams tomorrow" 'Wed Dec 9, the study break'
    Assert-Eq (& $line 'classes' 30 32) "Fall 2026${dot}Week 13 of 13${dot}classes end in 30d${dot}exams in 32d" 'weeks out, as before'
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
Test 'jk exam <course> after its last exam says so, with the date, instead of "no coming exam matches"' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'exam-after'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $d = Get-JkDueData; $a = Resolve-JkCourse $d 'cs350' -Create; $null = Resolve-JkCourse $d 'cs341' -Create
        $null = New-JkEvent -Data $d -Course $a.key -Date ([datetime]'2026-10-29') -Time '16:30' -Title 'Midterm' -Kind 'exam' -Weight '20%'
        $null = New-JkEvent -Data $d -Course $a.key -Date ([datetime]'2026-12-17') -Time '16:00' -End '18:30' -Title 'FINAL' -Kind 'exam' -Weight '40%'
        Save-JkDueData $d
        $env:JK_NOW = '2026-12-17T20:00:00'
        $m = try { Show-JkExamBrief cs350 6>&1 | Out-Null; '' } catch { $_.Exception.Message }
        Assert-Eq $m 'CS 350 has no exam left: its FINAL was Thu Dec 17 (jk grade cs350 for where the marks stand)'
        $m = try { Show-JkExamBrief cs341 6>&1 | Out-Null; '' } catch { $_.Exception.Message }
        Assert-True ($m -match '^CS 341 has no exams in jk \(jk due add cs341 ') "a course with none: $m"
        # an entry that is no course gets no advice to add a midterm
        $d = Get-JkDueData; $null = Resolve-JkCourse $d 'interviews' -Create; Save-JkDueData $d
        $m = try { Show-JkExamBrief interviews 6>&1 | Out-Null; '' } catch { $_.Exception.Message }
        Assert-True ($m -match 'has no exams \(jk exams lists them all\)$' -and $m -notmatch 'Midterm') "not a course: $m"
        # title words that match nothing keep the old message
        $m = try { Show-JkExamBrief cs350 quiz 6>&1 | Out-Null; '' } catch { $_.Exception.Message }
        Assert-True ($m -match "^no coming exam matches 'cs350 quiz'") "title words: $m"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'jk exams: under each course''s next exam, what its marks need for the target and to pass' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH
    $env:JK_HOME = Join-Path $saved 'exams-needs'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $env:JK_NOW = '2026-11-13T20:00:00'; $env:JK_WIDTH = '130'
        $d = Get-JkDueData; $a = Resolve-JkCourse $d 'cs370' -Create; $b = Resolve-JkCourse $d 'cs350' -Create
        $a1 = New-JkEvent -Data $d -Course $a.key -Date ([datetime]'2026-10-05') -Time '23:59' -Title 'Assignment 1' -Weight '7%'
        $a2 = New-JkEvent -Data $d -Course $a.key -Date ([datetime]'2026-10-26') -Time '23:59' -Title 'Assignment 2' -Weight '7%'
        $mid = New-JkEvent -Data $d -Course $a.key -Date ([datetime]'2026-11-02') -Time '19:00' -Title 'Midterm' -Kind 'exam' -Weight '32%'
        $null = New-JkEvent -Data $d -Course $a.key -Date ([datetime]'2026-11-16') -Time '23:59' -Title 'Assignment 3' -Weight '7%'
        $null = New-JkEvent -Data $d -Course $a.key -Date ([datetime]'2026-12-04') -Time '23:59' -Title 'Assignment 4' -Weight '7%'
        $null = New-JkEvent -Data $d -Course $a.key -Date ([datetime]'2026-12-10') -Time '16:00' -Title 'FINAL' -Kind 'exam' -Weight '40%'
        $null = New-JkEvent -Data $d -Course $b.key -Date ([datetime]'2026-10-29') -Time '16:30' -Title 'Midterm' -Kind 'exam' -Weight '25%'
        $null = New-JkEvent -Data $d -Course $b.key -Date ([datetime]'2026-12-17') -Time '16:00' -Title 'FINAL' -Kind 'exam' -Weight '40%'
        Save-JkDueData $d
        [IO.File]::WriteAllText((Join-Path $env:JK_HOME 'grades.json'), "{""scores"":[{""id"":""$($a1.id)"",""score"":100},{""id"":""$($a2.id)"",""score"":100},{""id"":""$($mid.id)"",""score"":38.75}],""extras"":[],""targets"":[{""course"":""$($a.key)"",""target"":80}],""nextExtra"":1,""pass"":[{""course"":""$($a.key)"",""kind"":""exam"",""min"":50},{""course"":""$($b.key)"",""kind"":""exam"",""min"":50}]}")
        $out = @(Show-JkExams 6>&1 | ForEach-Object { "$_" })
        $txt = $out -join "`n"
        $dot = [regex]::Escape($script:G.dot)
        Assert-True ($txt -match "for 80%: 99% on the rest $dot to pass, the FINAL needs 59%") "CS 370: $txt"
        # CS 350: a rule but no marks, so nothing to say yet (its midterm is written, just not marked)
        $i = [array]::FindIndex([string[]]$out, [Predicate[string]] { param($l) $l -match 'CS 350\s+FINAL' })
        Assert-True ($i -ge 0 -and ($i + 1 -ge $out.Count -or $out[$i + 1] -notmatch 'to pass|on the rest')) "CS 350: $txt"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'jk exams: an online window''s note line says the window once, then what its notes add' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH
    $env:JK_HOME = Join-Path $saved 'window-note'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $env:JK_NOW = '2026-11-13T20:00:00'; $env:JK_WIDTH = '120'
        $d = Get-JkDueData; $h = Resolve-JkCourse $d 'health105' -Create
        $o = New-JkEvent -Data $d -Course $h.key -Date ([datetime]'2026-12-07') -Time '06:00' -Title 'Midterm 2 opens' -Kind 'exam' -Weight '17.5%'
        $c = New-JkEvent -Data $d -Course $h.key -Date ([datetime]'2026-12-08') -Time '23:59' -Title 'Midterm 2 closes' -Kind 'exam' -Weight '17.5%'
        $o.note = "6:00 am Dec 7 $($script:G.arrow) 11:59 pm Dec 8 $($script:G.dot) LEARN quiz"
        $c.note = "11:59 pm $($script:G.dot) no reopening"
        Save-JkDueData $d
        $out = @(Show-JkExams 6>&1 | ForEach-Object { "$_" })
        $i = [array]::FindIndex([string[]]$out, [Predicate[string]] { param($l) $l -match 'HEALTH 105\s+Midterm 2\s' })
        Assert-True ($i -ge 0) 'the row'
        $note = $out[$i + 1].Trim()
        $dot = [regex]::Escape($script:G.dot)
        Assert-True ($note -match "^open until Tue Dec 8 11:59 pm $dot LEARN quiz $dot no reopening$") "the note line: $note"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'an exam is "in 30m", then "now" until it ends, then gone (end time known, or two hours)' {
    $savedNow = $env:JK_NOW
    $line = { ((Show-JkExams 6>&1 | ForEach-Object { "$_" }) | Where-Object { $_ -match 'CS 350\s+Midterm' }) -join '' }
    $dash = { ((Show-JkDashboard 6>&1 | ForEach-Object { "$_" }) | Where-Object { $_ -match 'NEXT EXAM' }) -join '' }
    try {
        # the CS 350 midterm: Thu Oct 29, 4:30 - 6:20 pm
        $env:JK_NOW = '2026-10-29T16:00:00'
        Assert-True ((& $line) -match '^\s+0d') 'later today: 0d'
        Assert-True ((& $dash) -match 'CS 350 Midterm\s+TODAY, in 30m') "dashboard: $(& $dash)"
        Assert-True ((& $dash) -match 'jk exam cs350') 'points at its brief'
        $env:JK_NOW = '2026-10-29T17:00:00'
        Assert-True ((& $line) -match '^\s+now\s') "under way: $(& $line)"
        Assert-True ((& $dash) -match 'CS 350 Midterm\s+NOW') 'the dashboard keeps it while it is on'
        Assert-True ((& $dash) -notmatch 'jk exam') 'no brief hint while it is being written'
        $env:JK_NOW = '2026-10-29T18:45:00'
        Assert-Eq (& $line) '' 'over at 6:20 pm, so gone from the list'
        Assert-True ((& $dash) -notmatch 'CS 350 Midterm') 'and from the callout'
        # no end time: two hours
        $e = [pscustomobject]@{ date = '2026-11-02'; time = '19:00'; end = '' }
        Assert-Eq (Get-JkExamEnd $e).ToString('HH:mm') '21:00'
    } finally { $env:JK_NOW = $savedNow }
}
Test 'the shell-start brief: today''s items carry their time; a week out is a date, not today''s weekday' {
    $savedNow = $env:JK_NOW; $savedHome = $env:JK_HOME
    try {
        # Thu Oct 29: the CS 350 midterm at 4:30 pm today
        $env:JK_NOW = '2026-10-29T09:00:00'
        $l = (Get-JkBriefLine) -replace "$([char]27)\[[0-9;]*m", ''
        Assert-True ($l -match 'CS350 Midterm today 4:30 pm') "today: $l"
        # Thu Oct 22, in a data folder of its own: Wed Oct 28 is "Wed"; Thu Oct 29 is "Oct 29", not "Thu"
        $env:JK_HOME = Join-Path $savedHome 'brief-home'
        $env:JK_NOW = '2026-10-22T09:00:00'
        $d = Get-JkDueData
        $null = New-JkEvent -Data $d -Course 'cs350' -Date ([datetime]'2026-10-28') -Time '20:00' -Title 'Soon thing' -Kind 'due'
        $null = New-JkEvent -Data $d -Course 'cs350' -Date ([datetime]'2026-10-29') -Time '23:00' -Title 'Week-out thing' -Kind 'due'
        Save-JkDueData $d
        $l = (Get-JkBriefLine) -replace "$([char]27)\[[0-9;]*m", ''
        Assert-True ($l -match 'Soon thing Wed') "weekday within the week: $l"
        Assert-True ($l -match 'Week-out thing Oct 29') "a week out is its date, never today's weekday: $l"
    } finally { $env:JK_NOW = $savedNow; $env:JK_HOME = $savedHome }
}
Test 'jk exam <course>: when, worth, prep, what lands the week before, and its files' {
    $courses = Join-Path $env:JK_HOME 'exam-courses'
    New-Item -ItemType Directory (Join-Path $courses 'CS350\review') -Force | Out-Null
    foreach ($n in 'review\midterm-review.pdf', 'Midterm_2025_solutions.pdf', 'a2a.pdf') { Set-Content (Join-Path $courses "CS350\$n") 'x' }
    $saved = Get-JkConfig 'tidy.courses'
    Set-JkConfig 'tidy.courses' $courses
    try {
        $out = @(& { jk exam cs350 } 6>&1 | ForEach-Object { "$_" })
        $text = $out -join "`n"
        Assert-True ($text -match 'CS 350 MIDTERM') "header: $($out[1])"
        Assert-True ($text -match 'when\s+Thu Oct 29, 4:30 pm') 'when'
        Assert-True ($text -match 'worth\s+25% of CS 350') 'worth'
        Assert-True ($text -match '(?s)before\s+.*CS 350 A2A Synchronization \(Wed 8:00 pm\)') 'the A2A due the day before (the row may wrap)'
        Assert-True ($text -match 'HEALTH 105 Midterm \(closes Tue 11:59 pm\)' -and $text -notmatch 'Midterm closes') 'an online window reads as the quiz, open until it closes'
        Assert-True ($text -match 'prep\s+about \d+h') 'jk plan estimate'
        Assert-True ($text -match '(?s)if\s+a mark here of 60 . \d+%.*70 . \d+%.*90 . \d+%') 'what each mark here would leave the rest needing'
        $files = @($out | Where-Object { $_ -match '^\s+\d+\s{2}' })
        Assert-Eq $files.Count 2 'the two midterm files, not a2a.pdf'
        Assert-True (@(Get-JkFindLast).Count -eq 2) 'numbered for jk find -o'
        # an online window reads as one exam with its opening and closing
        New-Item -ItemType Directory (Join-Path $courses 'HEALTH105\lectures') -Force | Out-Null
        Set-Content (Join-Path $courses 'HEALTH105\lectures\week5.pdf') 'x'; (Get-Item (Join-Path $courses 'HEALTH105\lectures\week5.pdf')).LastWriteTime = [datetime]'2026-10-15'
        Set-Content (Join-Path $courses 'HEALTH105\a5.docx') 'x'; (Get-Item (Join-Path $courses 'HEALTH105\a5.docx')).LastWriteTime = [datetime]'2026-10-21'
        $hOut = @(& { jk exam health } 6>&1 | ForEach-Object { "$_" })
        $h = $hOut -join "`n"
        Assert-True ($h -match 'opens Mon Oct 26 6:00 am\s+.\s+closes Tue Oct 27 11:59 pm') 'window'
        # nothing named after it: lecture material first, though the assignment is newer
        $rows = @($hOut | Where-Object { $_ -match '^\s+\d+\s{2}' })
        Assert-True ($h -match 'none named after it; the newest lecture material' -and $rows[0] -match 'week5\.pdf' -and $rows[1] -match 'a5\.docx') "fallback files: $($rows -join ' | ')"
        Assert-True ($h -match 'jk grep health105 <words>') 'points to jk grep'
        Assert-Throws { Show-JkExamBrief cs350 nonsense }
        Assert-True (((Invoke-JkExams 6>&1 | ForEach-Object { "$_" }) -join "`n") -match 'UPCOMING EXAMS') 'no words: the list'
        # "a1-final" is the last version of A1, not the final exam
        New-Item -ItemType Directory (Join-Path $courses 'CS350\tmp\a1-final') -Force | Out-Null
        foreach ($n in 'A1-final.txt', 'a2_final.pdf', 'report-final.docx', 'tmp\a1-final\page-4.png', 'Final-review.pdf', 'practice_final_2024.pdf', 'CS350 final.pdf') { Set-Content (Join-Path $courses "CS350\$n") 'x' }
        $names = @((Get-JkDueFileHits (Get-JkDueData) ([pscustomobject]@{ course = 'cs350'; title = 'Final' })).Hits | ForEach-Object { $_.Name } | Sort-Object) -join '|'
        Assert-Eq $names (@('Final-review.pdf', 'practice_final_2024.pdf', 'CS350 final.pdf' | Sort-Object) -join '|')
        # a week or more off, a bare weekday would read as the coming one; hours before, no prep estimate
        $savedNow = $env:JK_NOW
        try {
            $env:JK_NOW = '2026-10-15T09:00:00'
            $far = @(& { jk exam cs350 } 6>&1 | ForEach-Object { "$_" }) -join "`n"
            Assert-True ($far -match 'A2A Synchronization\s+\(Wed\s+Oct\s+28\s+8:00\s+pm\)') "names the date: $far"
            $env:JK_NOW = '2026-10-29T15:00:00'
            $soon = @(& { jk exam cs350 } 6>&1 | ForEach-Object { "$_" }) -join "`n"
            Assert-True ($soon -match 'CS 350 MIDTERM' -and $soon -notmatch 'prep\s+about') "no prep estimate 90 minutes out: $soon"
        } finally { $env:JK_NOW = $savedNow }
    } finally { Set-JkConfig 'tidy.courses' $saved }
}
Test 'jk week refuses a silly length instead of drawing it for a quarter of an hour' {
    Assert-Throws { Show-JkDueWeek 99999 }
    Assert-Throws { Show-JkDueWeek 0 }
    Assert-Throws { Show-JkDueWeek -1 }
    Assert-True (@(Show-JkDueWeek 26 6>&1).Count -gt 0) 'half a year still draws'
    foreach ($n in 99999, 0, -1) { Assert-Throws { Show-JkReview $n } "jk review $n"; Assert-Throws { Show-JkFocusLog $n } "jk focus log $n" }
    Assert-True (@(Show-JkReview 30 6>&1).Count -gt 0) 'jk review 30 still draws'
    Assert-True (@(Show-JkFocusLog 30 6>&1).Count -gt 0) 'jk focus log 30 still draws'
    Assert-Throws { Invoke-JkPort 99999 }
}
Test 'a cleanup refuses an age of zero or less, which would make everything old' {
    # a throwaway TEMP: if this guard ever goes, the test must not take the real temp files with it
    $box = Join-Path $env:JK_HOME 'age-guards'
    $fakeTemp = Join-Path $box 'temp'
    foreach ($sub in $fakeTemp, (Join-Path $box 'downloads'), (Join-Path $box 'shots')) { $null = New-Item -ItemType Directory -Path $sub -Force }
    $files = @((Join-Path $fakeTemp 'build.tmp'), (Join-Path $box 'downloads\setup.exe'), (Join-Path $box 'shots\Screenshot.png'))
    foreach ($f in $files) { Write-JkText $f 'x' }
    $savedTemp = $env:TEMP
    $env:TEMP = $fakeTemp
    try {
        foreach ($n in 0, -1, -5) {
            Assert-Throws { Invoke-JkSpaceClean temp -Days $n } "jk space clean temp -Days $n"
            Assert-Throws { Invoke-JkTidyOld (Join-Path $box 'downloads') -Days $n -Recycle } "jk tidy old -Days $n -Recycle"
            Assert-Throws { Invoke-JkShotsOld $n -Path (Join-Path $box 'shots') -Recycle } "jk shots old $n -Recycle"
        }
        foreach ($f in $files) { Assert-True (Test-Path -LiteralPath $f) "$f is still there" }
    } finally { $env:TEMP = $savedTemp }
    Assert-Throws { Show-JkShots 0 -Path (Join-Path $box 'shots') }
    $rounds = try { Invoke-JkCpStress -N 0; '' } catch { $_.Exception.Message }
    Assert-True ($rounds -match 'rounds') "no rounds is not a pass: $rounds"
}
Test 'PowerShell''s own errors read as jk''s' {
    $f = { param($m, $c) Format-JkErrorText $m $c }
    Assert-Eq (& $f 'Cannot process argument transformation on parameter ''Weeks''. Cannot convert value "[" to type "System.Int32". Error: "Input string was not in a correct format."' 'due') "expected a number for weeks, not '['"
    Assert-Eq (& $f 'Cannot convert value "cs341" to type "System.Int32". Error: "Input string was not in a correct format."') "expected a number, not 'cs341'"
    Assert-Eq (& $f "A positional parameter cannot be found that accepts argument 'x'." 'grade') "unexpected word 'x' (jk help grade)"
    Assert-Eq (& $f "A parameter cannot be found that matches parameter name 'Foo'." 'due') 'there is no -Foo option (jk help due)'
    Assert-Eq (& $f "Missing an argument for parameter 'Weight'. Specify a parameter of type 'System.String' and try again." 'due') '-Weight needs a value (jk help due)'
    Assert-Eq (& $f 'Exception calling "AddDays" with "1" argument(s): "Value to add was out of range. Parameter name: value"') 'that number is out of range'
    Assert-Eq (& $f 'Exception calling "ReadAllText" with "1" argument(s): "Could not find file ''x''."') "Could not find file 'x'."
    Assert-Eq (& $f 'no deadline with id #0') 'no deadline with id #0' 'jk''s own messages pass through'
    # a long value is cut, and end to end
    Assert-Eq (& $f 'Cannot validate argument on parameter ''Lang''. The argument "rust" does not belong to the set "cpp;py;java;usaco;" specified by the ValidateSet attribute. Supply an argument that is in the set and then try the command again.') '-Lang takes cpp, py, java, usaco'
    Assert-Eq (& $f 'Cannot validate argument on parameter ''First''. The -1 argument is less than the minimum allowed range of 0. Supply an argument that is greater than or equal to 0 and then try the command again.') 'that number is out of range'
    Assert-Eq (& $f 'Cannot validate argument on parameter ''Name''. Something else.') 'Cannot validate argument on parameter ''Name''. Something else.' 'only what it can read is rewritten'
    Assert-True ((& $f 'Illegal characters in path.') -match 'characters Windows does not allow') 'a bad path'
    Assert-True ((& $f "The given path's format is not supported.") -match 'characters Windows does not allow') 'a bad path, the other way of saying it'
    Assert-True ((& $f "Cannot convert value `"$('x' * 3000)`" to type `"System.Int32`". Error").Length -lt 80) 'a long value is cut'
    # and from a real command line, where -Lang is an option and not a word
    $said = @(& { jk cp new x -Lang rust } 6>&1 | ForEach-Object { "$_" }) -join ' '
    Assert-True ($said -match '-Lang takes cpp, py, java, usaco') $said
    $said = @(& { jk cp new x -Nope 3 } 6>&1 | ForEach-Object { "$_" }) -join ' '
    Assert-True ($said -match 'there is no -Nope option') $said
    $said = @(& { jk week nonsense } 6>&1 | ForEach-Object { "$_" }) -join ' '
    Assert-True ($said -match "expected a number for weeks, not 'nonsense'") $said
    $said = @(& { jk class rm cs341 } 6>&1 | ForEach-Object { "$_" }) -join ' '
    Assert-True ($said -match "'cs341' is not a class id") $said
    $said = @(& { jk remind cancel cs341 } 6>&1 | ForEach-Object { "$_" }) -join ' '
    Assert-True ($said -match "'cs341' is not a reminder number") $said
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
Test 'countdowns count real hours: Monday 7 pm from Saturday 11 pm the weekend clocks fall back' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'fallback-home'
    try {
        $from = [datetime]'2026-10-31T23:00:00'; $to = [datetime]'2026-11-02T19:00:00'
        # 44 hours by the clock, plus what the zone gains overnight: an hour in Eastern or Pacific, none in UTC
        $tz = [TimeZoneInfo]::Local
        $want = 44 + ($tz.GetUtcOffset($from) - $tz.GetUtcOffset($to)).TotalHours
        Assert-Eq (Get-JkTimeLeft $to $from).TotalHours $want 'real hours'
        Import-JkDueHtml $htmlPath | Out-Null
        $d = Get-JkDueData
        $null = New-JkEvent -Data $d -Course 'cs350' -Date ([datetime]'2026-11-02') -Time '19:00' -Title 'Fallback midterm' -Kind 'exam'
        Save-JkDueData $d
        $env:JK_NOW = '2026-10-31T23:00:00'
        $text = @(& { jk due 3 } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $cd = Format-JkDuration ([timespan]::FromHours($want))
        Assert-True ($text -match "Fallback midterm.*\s$([regex]::Escape($cd))\s") "countdown $cd"
    } finally { $env:JK_HOME = $saved; $env:JK_NOW = $savedNow }
}
Test 'an exam held in a class takes the class room: jk next names it and drops the class line, jk brief shows one item' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH
    $env:JK_HOME = Join-Path $saved 'exam-room'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $env:JK_WIDTH = '160'
        $d = Get-JkDueData; $o = Resolve-JkCourse $d 'co367' -Create
        $q = New-JkEvent -Data $d -Course $o.key -Date ([datetime]'2026-11-19') -Time '08:30' -End '09:50' -Title 'Quiz 3' -Kind 'exam' -Weight '20%'
        $q.note = 'in class'
        Save-JkDueData $d
        Save-JkClassData ([pscustomobject]@{ nextId = 2; items = @([pscustomobject]@{ id = 1; course = $o.key; kind = 'LEC'; days = @('Tue', 'Thu'); start = '08:30'; end = '09:50'; room = 'MC 2017'; from = ''; to = '' }) })
        Assert-Eq (Get-JkExamPlace $q) 'in class, MC 2017'
        $env:JK_NOW = '2026-11-19T07:30:00'
        $next = (Show-JkNext 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($next -match 'leave in time . in class, MC 2017') "the room: $next"
        Assert-True ($next -notmatch 'CO 367 LEC') "no separate class line: $next"
        $brief = (Get-JkBriefLine) -replace "$([char]27)\[[0-9;]*m", ''
        Assert-True ($brief -match 'CO367 Quiz 3 today 8:30 am MC 2017' -and $brief -notmatch 'LEC') "brief: $brief"
        $ex = (Show-JkExamBrief co367 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($ex -match 'notes\s+in class, MC 2017') "jk exam: $ex"
        $exs = (Show-JkExams 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($exs -match 'in class, MC 2017') "jk exams: $exs"
        # a Tuesday lecture is still a class
        $env:JK_NOW = '2026-11-17T08:10:00'
        $next = (Show-JkNext 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($next -match 'CO 367 LEC in MC 2017 at 8:30 am') "a plain class: $next"
        Assert-True (((Get-JkBriefLine) -replace "$([char]27)\[[0-9;]*m", '') -match 'CO367 LEC 8:30 am MC 2017') 'and on the brief'
        # the morning popup: one line for the quiz, with the room, and no class line for it
        $origNotify = ${function:Show-JkNotify}
        function script:Show-JkNotify { param([string]$Title, [string[]]$Lines) $script:PopupLines = $Lines; 'stub' }
        try {
            $env:JK_NOW = '2026-11-19T07:45:00'
            Invoke-JkDueRemind -Force -Quiet 6>&1 | Out-Null
            $pl = $script:PopupLines -join ' / '
            Assert-True ($pl -match 'CO 367 Quiz 3 \(exam\) . in class, MC 2017' -and $pl -notmatch 'Classes today') "popup: $pl"
        } finally { Set-Item function:script:Show-JkNotify $origNotify }
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'an exam tomorrow before 11 am gets a 9 pm alert tonight, once, that says when it starts' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'eve-alert'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    $orig = ${function:Start-JkBackground}; $origNotify = ${function:Show-JkNotify}
    try {
        function script:Start-JkBackground { param([string]$Script, [hashtable]$Env = @{}, [string]$WaitUntil) [pscustomobject]@{ Id = 0; StartTime = (Get-Date) } }
        function script:Show-JkNotify { param([string]$Title, [string[]]$Lines) $script:PopupTitle = $Title; $script:PopupLines = $Lines; 'stub' }
        $d = Get-JkDueData; $o = Resolve-JkCourse $d 'co367' -Create; $c = Resolve-JkCourse $d 'cs370' -Create
        $q = New-JkEvent -Data $d -Course $o.key -Date ([datetime]'2026-11-19') -Time '08:30' -End '09:50' -Title 'Quiz 3' -Kind 'exam' -Weight '20%'
        $null = New-JkEvent -Data $d -Course $c.key -Date ([datetime]'2026-11-19') -Time '16:00' -Title 'Midterm' -Kind 'exam' -Weight '30%'
        Save-JkDueData $d
        $env:JK_NOW = '2026-11-18T10:00:00'
        Assert-Eq (Register-JkTodayAlerts -Now ([datetime]'2026-11-18T10:00')) 1 'the 8:30 am quiz, not the 4 pm midterm'
        $r = @((Get-JkReminderData).items)[0]
        Assert-Eq $r.at '2026-11-18T21:00:00' 'at 9 pm'
        Assert-Eq $r.text 'CO 367 Quiz 3 (exam) tomorrow at 8:30 am'
        Assert-Eq (Register-JkTodayAlerts -Now ([datetime]'2026-11-18T18:00')) 0 'once'
        # it fires that evening: when it starts, and the alarm
        $env:JK_NOW = '2026-11-18T21:00:00'
        Complete-JkReminder -Id ([int]$r.id)
        Assert-True ($script:PopupLines[0] -like 'Starts 8:30 am tomorrow*' -and $script:PopupLines[-1] -match 'set an alarm') "popup: $($script:PopupLines -join ' / ')"
        # held in its Thursday class: the popup says where
        $env:JK_NOW = '2026-11-18T21:00:00'
        $d = Get-JkDueData; @($d.events | Where-Object { $_.id -eq $q.id })[0].note = 'in class'; Save-JkDueData $d
        Save-JkClassData ([pscustomobject]@{ nextId = 2; items = @([pscustomobject]@{ id = 1; course = $o.key; kind = 'LEC'; days = @('Tue', 'Thu'); start = '08:30'; end = '09:50'; room = 'MC 2017'; from = ''; to = '' }) })
        $a = New-JkReminder -At ([datetime]'2026-11-18T21:00') -Text 'x' -Key "eve:$($q.id):2026-11-18" -DueId ([int]$q.id)
        Complete-JkReminder -Id ([int]$a.id)
        Assert-True ($script:PopupLines -contains 'in class, MC 2017') "where: $($script:PopupLines -join ' / ')"
        # first awake at 10 pm: in a minute; at 11 pm or later, too late to be useful
        $rd = Get-JkReminderData; $rd.items = @(); Set-JkProp $rd 'alerted' @(); Save-JkReminderData $rd
        Assert-Eq (Register-JkTodayAlerts -Now ([datetime]'2026-11-18T23:10')) 0 'after 11 pm: nothing'
        Assert-Eq (Register-JkTodayAlerts -Now ([datetime]'2026-11-18T22:00')) 1 'at 10 pm: now'
        Assert-Eq @((Get-JkReminderData).items)[0].at '2026-11-18T22:01:00'
    } finally {
        Set-Item function:script:Start-JkBackground $orig; Set-Item function:script:Show-JkNotify $origNotify
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
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
        Assert-Eq (Register-JkTodayAlerts -Now ([datetime]'2026-10-28T19:00')) 0 'already set that morning'
        # first awake at 7 pm (asleep through the morning run): the 8 pm A2A is warned about in a minute,
        # not skipped; 5 minutes before is too late to be useful
        $rd = Get-JkReminderData; $keep = @($rd.items); $keepAlerted = @(Get-JkProp $rd 'alerted' @())
        $rd.items = @(); Set-JkProp $rd 'alerted' @(); Save-JkReminderData $rd
        Assert-Eq (Register-JkTodayAlerts -Now ([datetime]'2026-10-28T19:55')) 0 'five minutes before: no alert'
        Assert-Eq (Register-JkTodayAlerts -Now ([datetime]'2026-10-28T19:00')) 1 'a late wake still warns'
        Assert-Eq @((Get-JkReminderData).items)[0].at '2026-10-28T19:01:00' 'in a minute'
        $rd = Get-JkReminderData; $rd.items = $keep; Set-JkProp $rd 'alerted' $keepAlerted; Save-JkReminderData $rd
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
            # asleep through the warning and the deadline: open work gets a late word within a day;
            # after that, or for an exam that is over, nothing useful is left to say
            $nowSaved = $env:JK_NOW
            try {
                $env:JK_NOW = '2026-10-29T10:20:00'
                $a = New-JkReminder -At ([datetime]'2026-10-28T18:00') -Text 'x' -DueId ([int]$r.dueId)
                Complete-JkReminder -Id ([int]$a.id)
                Assert-Eq $script:PopupCalls 2 'a late word for work still open'
                Assert-True ($script:PopupLines[0] -like 'Its deadline passed while this PC was off or asleep (8:00 pm Wed)*') "late: $($script:PopupLines[0])"
                Assert-Eq $script:PopupLines[1] "Handed in? jk due done $($r.dueId)"
                $script:PopupCalls--
                $env:JK_NOW = '2026-10-30T10:00:00'
                $a = New-JkReminder -At ([datetime]'2026-10-28T18:00') -Text 'x' -DueId ([int]$r.dueId)
                Complete-JkReminder -Id ([int]$a.id)
                Assert-Eq $script:PopupCalls 1 'more than a day late: quiet'
                $env:JK_NOW = '2026-10-29T18:00:00'
                $a = New-JkReminder -At ([datetime]'2026-10-29T14:30') -Text 'x' -DueId ([int]$mid.id)
                Complete-JkReminder -Id ([int]$a.id)
                Assert-Eq $script:PopupCalls 1 'an exam that is over: quiet'
            } finally { $env:JK_NOW = $nowSaved }
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
        # the day before leads with it too
        $env:JK_NOW = '2026-10-28T07:45:00'
        Invoke-JkDueRemind -Quiet -Force
        Assert-True ($script:ExamTitle -like 'Exam tomorrow: * Midterm 4:30 pm*') "the day before: $($script:ExamTitle)"
        # a morning with only an assignment due keeps the plain count
        $env:JK_NOW = '2026-10-30T07:45:00'
        Invoke-JkDueRemind -Quiet -Force
        Assert-True ($script:ExamTitle -like '* in the next 48h') "after the exam: $($script:ExamTitle)"
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
Test 'morning brief: an exam in the next two days leads, an opened window says it is open' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'exam-soon'; $script:JkConfigCache = $null
    $orig = ${function:Show-JkNotify}
    function script:Show-JkNotify { param([string]$Title, [string[]]$Lines) $script:SoonTitle = $Title; 'stub' }
    try {
        Add-JkDue health 'Quiz opens' nov 23 6am -Exam
        Add-JkDue health 'Quiz closes' nov 24 11:59pm -Exam
        Add-JkDue cs341 'A4' nov 24 11:59pm
        $env:JK_NOW = '2026-11-22T07:45:00'
        Invoke-JkDueRemind -Quiet -Force
        # only the opening falls in the next 48 hours
        Assert-True ($script:SoonTitle -like 'Exam tomorrow: * Quiz opens 6:00 am') "before it opens: $($script:SoonTitle)"
        $env:JK_NOW = '2026-11-23T07:45:00'
        Invoke-JkDueRemind -Quiet -Force
        Assert-True ($script:SoonTitle -like 'Exam open now: * Quiz, closes tomorrow 11:59 pm (+1 more due)') "once open: $($script:SoonTitle)"
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
Test 'days ahead say which week: a week today on a Sunday, and plan items two weeks out' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'coming-days'; $script:JkConfigCache = $null
    $orig = ${function:Show-JkNotify}
    function script:Show-JkNotify { param([string]$Title, [string[]]$Lines) $script:ComingLines = $Lines; 'stub' }
    try {
        # Sun Nov 22: a quiz on Wednesday, and a midterm a week today
        Add-JkDue cs350 'Quiz' nov 25 9am -Exam
        Add-JkDue cs370 'Midterm' nov 29 7pm -Exam
        Add-JkDue cs341 'A9' dec 2 11:59pm -Weight 8
        $env:JK_NOW = '2026-11-22T07:45:00'
        $script:ComingLines = $null
        Invoke-JkDueRemind -Quiet -Force
        $line = @($script:ComingLines | Where-Object { $_ -like 'This week:*' })[0]
        Assert-True ($line -like '*Quiz Wed*') "this week's Wednesday stays Wed: $line"
        Assert-True ($line -like '*Midterm Sun Nov 29*') "a week today has its date, not Sun: $line"
        # jk plan's column: A9 is ten days off, a Wednesday that is not this one
        $plan = @(& { jk plan } 6>&1 | ForEach-Object { "$_" })
        $row = @($plan | Where-Object { $_ -match '\bA9\b' })[0]
        Assert-True ($row -match 'Dec 2 . 8%') "the plan row: $row"
        $row = @($plan | Where-Object { $_ -match '\bQuiz\b' })[0]
        if ($row) { Assert-True ($row -match 'Wed . ') "three days off stays a weekday: $row" }
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
Test 'jk review -Days 14 says 14 days throughout and keeps the strip''s last days; jk todo rm alone says how' {
    $p = Get-JkPath 'deadlines.json'
    $saved = $null; if (Test-Path -LiteralPath $p) { $saved = [IO.File]::ReadAllText($p) }
    $md = Join-Path (Get-JkHome) 'review-jobs.md'
    [IO.File]::WriteAllLines($md, @('| Date | Company | Role | Location | Status | Link |', '|---|---|---|---|---|---|',
            '| 2026-10-20 | Alpha | Intern | Remote | Submitted via Ashby | |', '| 2026-10-01 | Beta | Intern | Remote | Submitted via Ashby | |',
            '| 2026-09-20 | Gamma | Intern | Remote | Submitted via Ashby | |'), (New-Object Text.UTF8Encoding $false))
    Set-JkConfig 'jobs.file' $md
    try {
        # one deadline a day for the next 14 days, on top of whatever the suite has there already
        $data = Get-JkDueData
        $c = Resolve-JkCourse $data 'rv101' -Create
        foreach ($i in 0..14) { $null = New-JkEvent -Data $data -Course $c.key -Date (Get-JkNow).Date.AddDays($i) -Time '23:59' -Title "Rv$i" -Weight '1%' -Kind 'due' }
        Save-JkDueData $data
        $out = @(Show-JkReview -Days 14 6>&1 | ForEach-Object { "$_" })
        $text = $out -join "`n"
        Assert-True ($text -match 'Last 14 days' -and $text -notmatch 'Last 7 days') 'looking back'
        Assert-True ($text -match 'Next 14 days') 'looking ahead'
        # Oct 9-22, against Sep 25-Oct 8
        Assert-True ($text -match 'job search\s+1 application sent \(14 days before: 1\)') "jobs: $(@($out | Where-Object { $_ -match 'job search' })[0])"
        Assert-True ($text -match 'due in the next 14 days' -and $text -notmatch 'this week') 'where the marks are'
        # the strip: every day's dot is on screen, not cut off at the edge
        $start = [Array]::FindIndex([string[]]$out, [Predicate[string]] { param($l) $l -match '^\s+tod ' })
        $strip = @(for ($i = $start; $i -ge 0 -and $i -lt $out.Count -and $out[$i].Trim(); $i++) { $out[$i] })
        $want = @((Get-JkDueData).events | Where-Object { -not $_.done -and $_.kind -ne 'exam' -and (Get-JkEventDue $_) -ge (Get-JkNow) -and (Get-JkEventDue $_).Date -le (Get-JkNow).Date.AddDays(14) }).Count
        $dots = ([regex]::Matches(($strip -join ''), [regex]::Escape($script:G.ring))).Count
        Assert-Eq $dots $want "a dot for each deadline in the 15 days: $($strip -join ' / ')"
        Assert-True (@($strip | Where-Object { (Get-JkVisibleLength $_) -gt [int]$env:JK_WIDTH -or $_.EndsWith($script:G.ell) }).Count -eq 0) 'no strip line runs off the screen'
        Assert-True ($strip.Count -ge 2) 'a fortnight takes more than one line'
        # the week keeps its words
        $week = (Show-JkReview 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($week -match 'Last 7 days' -and $week -match '\(week before: ' -and $week -match 'due this week') 'jk review'
        Assert-Throws { Remove-JkTodo } 'jk todo rm with nothing named says how, rather than nothing'
    } finally {
        Invoke-JkConfig reset jobs.file
        Remove-Item -LiteralPath $md -ErrorAction SilentlyContinue
        if ($null -ne $saved) { [IO.File]::WriteAllText($p, $saved) } else { Remove-Item -LiteralPath $p -ErrorAction SilentlyContinue }
        $script:JkDueCache = $null; Clear-JkBriefCache
    }
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
            ((Get-Date).AddHours(-2).ToString('s', $script:Inv) + ' sync: The remote name could not be resolved'),
            ((Get-Date).AddHours(-1).ToString('s', $script:Inv) + ' tick: cache C:\x; weather stale; place set'))
        $out = (Invoke-JkDoctor 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($out -match 'LEARN feed\s+last synced 5 days ago') 'stale feed'
        Assert-True ($out -match 'background errors\s+1 this week, latest: sync: The remote name') 'recent error only; a morning run''s summary is not an error'
        Assert-True ($out -match 'last morning run\s+.*no fresh forecast \(stale\)') "the morning run, as it last went: $out"
        # the forecast: none kept yet, and why the last try failed
        $ef = Join-Path (Get-JkCacheDir) 'weather.error'
        $wf = Join-Path (Get-JkCacheDir) 'weather.txt'
        $keptWeather = $null; if (Test-Path -LiteralPath $wf) { $keptWeather = [IO.File]::ReadAllText($wf); Remove-Item -LiteralPath $wf }
        Set-Content -LiteralPath $ef -Value '2026-11-02T07:45:03 The remote name could not be resolved'
        try {
            $out = (Invoke-JkDoctor 6>&1 | ForEach-Object { "$_" }) -join "`n"
            Assert-True ($out -match 'weather\s+no forecast kept yet; last try: 2026-11-02T07:45:03 The remote name') 'weather: why it is missing'
            Assert-True ($out -match 'disk space\s+\w: [\d.,]+ \w?B free of') 'disk space'
            Assert-True ($out -match 'PDF text \(jk grep\)\s+') 'what jk grep reads PDFs with'
        } finally {
            Remove-Item -LiteralPath $ef -ErrorAction SilentlyContinue
            if ($null -ne $keptWeather) { [IO.File]::WriteAllText($wf, $keptWeather) }
        }
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
Test 'jk remind says whether a PC asleep at 7:45 still gets its brief (the unlock task)' {
    $origInfo = ${function:Get-JkTaskInfo}
    $script:HasUnlock = $false
    function script:Get-JkTaskInfo([string]$Name = $script:JkTaskName) {
        if ($Name -eq $script:JkTaskName -or $script:HasUnlock) { [pscustomobject]@{ State = 'Ready'; NextRunTime = [datetime]'2026-10-23T07:45'; LastRunTime = $null; LastTaskResult = 0; PinnedToUtc = $false } }
    }
    try {
        $out = (Show-JkReminders 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($out -match 'no catch-up after sleep - a PC asleep then skips the brief; run: jk remind install') "without it: $out"
        $script:HasUnlock = $true
        $out = (Show-JkReminders 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($out -match 'if the PC sleeps through it, it runs when you unlock' -and $out -notmatch 'no catch-up') "with it: $out"
    } finally { Set-Item function:script:Get-JkTaskInfo $origInfo }
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
Test 'databases open to the network: grouped ports, the setting and file that keep them local' {
    $lines = @(
        '  TCP    0.0.0.0:3306           0.0.0.0:0              LISTENING       6968',
        '  TCP    0.0.0.0:33060          0.0.0.0:0              LISTENING       6968',
        '  TCP    [::]:3306              [::]:0                 LISTENING       6968',
        '  TCP    127.0.0.1:6379         0.0.0.0:0              LISTENING       500',
        '  TCP    0.0.0.0:5432           0.0.0.0:0              LISTENING       600',
        '  TCP    0.0.0.0:8080           0.0.0.0:0              LISTENING       700'
    )
    $names = @{ 6968 = 'mysqld'; 500 = 'redis-server'; 600 = 'postgres'; 700 = 'java' }
    $x = @(Get-JkExposedServices (Get-JkListeners -Lines $lines) $names)
    Assert-Eq (($x | ForEach-Object { "$($_.Name):$($_.Ports -join ',')" }) -join ' ') 'mysqld:3306,33060 postgres:5432' 'redis is local only; a dev server is not a database'
    Assert-True ($x[0].Fix -match 'mysqlx-bind-address') 'the X protocol port has its own setting'
    $cases = [ordered]@{
        '"C:\Program Files\MySQL\MySQL Server 8.0\bin\mysqld.exe" --defaults-file="C:\ProgramData\MySQL\MySQL Server 8.0\my.ini" MySQL80' = 'C:\ProgramData\MySQL\MySQL Server 8.0\my.ini'
        '"C:/Program Files/PostgreSQL/16/bin/pg_ctl.exe" runservice -N "postgresql-x64-16" -D "C:/Program Files/PostgreSQL/16/data" -w'   = 'C:\Program Files\PostgreSQL\16\data\postgresql.conf'
        '"C:\Program Files\MongoDB\Server\7.0\bin\mongod.exe" --config "C:\Program Files\MongoDB\Server\7.0\bin\mongod.cfg" --service'   = 'C:\Program Files\MongoDB\Server\7.0\bin\mongod.cfg'
        '"C:\Program Files\Redis\redis-server.exe" --service-run "C:\Program Files\Redis\redis.windows-service.conf"'                    = 'C:\Program Files\Redis\redis.windows-service.conf'
    }
    foreach ($k in $cases.Keys) { Assert-Eq (Get-JkDbServiceInfo 'x' $k 'svc').File $cases[$k] }
    # the real registry walk answers quickly whether or not a database is installed
    $sw = [Diagnostics.Stopwatch]::StartNew(); $null = Get-JkDbServiceInfo 'no-such-db-exe'; $sw.Stop()
    Assert-True ($sw.ElapsedMilliseconds -lt 1500) "registry walk took $($sw.ElapsedMilliseconds) ms"
}
Test 'jk grep: words inside course files by page, phrase first, one course or all, -o at the page' {
    $courses = Join-Path $env:JK_HOME 'grep-courses'
    $c350 = Join-Path $courses 'CS350'; $other = Join-Path $courses 'MATH999'
    New-Item -ItemType Directory (Join-Path $c350 'text'), $other -Force | Out-Null
    $saved = Get-JkConfig 'tidy.courses'
    $origOpen = ${function:Open-JkPdfAtPage}
    try {
        Set-JkConfig 'tidy.courses' $courses
        Set-Content (Join-Path $c350 'notes.md') "# Week 3`nsome text`nThe condition number of A is large." -Encoding UTF8
        Set-Content (Join-Path $other 'other.md') 'condition number elsewhere' -Encoding UTF8
        Set-Content (Join-Path $c350 'review.html') '<html><style>.x{}</style><p><span>condition</span> <b>number</b> &amp; stability</p></html>' -Encoding UTF8
        # slides: a .pptx is a zip of slide XML
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $pptx = Join-Path $c350 'lec05.pptx'
        $z = [IO.Compression.ZipFile]::Open($pptx, 'Create')
        foreach ($s in @(@(1, '<a:t>Runge Kutta</a:t><a:t>schemes</a:t>'), @(2, '<a:t>LU with partial pivoting &amp; more</a:t>'))) {
            $sw = New-Object IO.StreamWriter ($z.CreateEntry("ppt/slides/slide$($s[0]).xml").Open()); $sw.Write("<p:sld><a:p>$($s[1])</a:p></p:sld>"); $sw.Dispose()
        }
        $z.Dispose()
        Set-Content (Join-Path $c350 'lab.ipynb') '{"cells":[{"cell_type":"markdown","source":["# Newton"]},{"cell_type":"code","source":["def secant(f):\n","    return 1"]}]}' -Encoding UTF8
        # PDFs: their text seeded in the cache as pdftotext would leave it (no pdftotext needed)
        $pdf = { param($name, [string[]]$pages) $p = Join-Path $c350 $name; Set-Content $p "pdf $name"; Save-JkTextCache (Get-Item -LiteralPath $p) (($pages -join "`f") + "`f") }
        & $pdf 'course_notes.pdf' @('Contents 1.5 condition . . . . . . . . . . . . 3 number . . . . . 4 more . . . . . . 5', 'boundary condition and a number', 'the condition number of A measures how errors grow; condition number again')
        & $pdf 'a2.pdf' @('Q1: show the condi-' + "`n" + 'tion number is the worst case')
        & $pdf 'a2 (1).pdf' @('Q1: show the condi-' + "`n" + 'tion number is the worst case')
        Set-Content (Join-Path $c350 'text\a2.txt') 'condition number copied out of a2.pdf'
        Set-Content (Join-Path $c350 'a2.txt') 'condition number copied out of a2.pdf'
        & $pdf 'handwritten.pdf' @('')
        Assert-True ($null -ne (Read-JkTextCache (Get-Item (Join-Path $c350 'a2.pdf')))) 'cache read back'
        Set-Content (Join-Path $c350 'a2.pdf') 'changed'
        Assert-True ($null -eq (Read-JkTextCache (Get-Item (Join-Path $c350 'a2.pdf')))) 'a changed file is read again'
        & $pdf 'a2.pdf' @('Q1: show the condi-' + "`n" + 'tion number is the worst case')

        $out = @(& { jk grep cs350 condition number } 6>&1 | ForEach-Object { "$_" })
        $rows = @($out | Where-Object { $_ -match '^\s+\d+\s{2}' })
        $text = $out -join "`n"
        Assert-True ($rows[0] -match 'course_notes\.pdf\s+p\.3\s') "the page with the phrase, twice, first: $($rows[0])"
        Assert-True ($text -match 'a2\.pdf\s+p\.1\s.*condition number is the worst' -and $text -notmatch 'a2 \(1\)\.pdf') 'a line-end hyphen joined; the duplicate download shows once'
        Assert-True ($text -notmatch 'a2\.txt') 'a .txt copied out of a PDF is left to the PDF'
        Assert-True ($text -match 'notes\.md\s+line 3\s') 'a note by line'
        Assert-True ($text -match 'review\.html\s+line 1\s+condition number & stability') 'html without its tags'
        Assert-True ($text -notmatch 'other\.md') 'one course only'
        $toc = [array]::IndexOf(@($rows | ForEach-Object { $_ -match 'p\.1\s+Contents' }), $true)
        $weak = [array]::IndexOf(@($rows | ForEach-Object { $_ -match 'p\.2\s+boundary' }), $true)
        Assert-True ($toc -gt $weak -or $toc -lt 0) 'a table of contents ranks below a real page'
        Assert-True ($text -match '1 PDF with no text inside' -or (Get-Item (Join-Path $c350 'handwritten.pdf')).Length -le 50KB) 'handwritten counted (only when it is a real size)'

        # find.last keeps the page; jk find -o opens the PDF there
        $last = @(Get-JkFindLast)
        Assert-True ($last[0] -match "course_notes\.pdf`t3$") "page kept: $($last[0])"
        $script:Opened = $null
        function script:Open-JkPdfAtPage([string]$Path, [int]$Page) { $script:Opened = "$(Split-Path $Path -Leaf)@$Page" }
        jk find -o 1
        Assert-Eq $script:Opened 'course_notes.pdf@3' 'opened at its page'

        $t2 = @(& { jk grep cs350 runge kutta } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($t2 -match 'lec05\.pptx\s+slide 1\s') 'slides by number'
        $t3 = @(& { jk grep cs350 'partial pivoting &' } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($t3 -match 'lec05\.pptx\s+slide 2\s') 'a quoted phrase, entities decoded'
        $t4 = @(& { jk grep cs350 secant } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($t4 -match 'lab\.ipynb\s+cell 2\s') 'notebooks by cell'
        $t5 = @(& { jk grep all condition number } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($t5 -match 'other\.md' -and $t5 -match 'every course') 'jk grep all: every course folder'
        $t6 = @(& { jk grep cs350 zebra } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($t6 -match 'Nothing has all of those words') 'nothing found says so'
        $f6 = @(& { Invoke-JkFind -Root $courses zzqqx } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($f6 -match 'jk grep zzqqx') 'jk find with no name match points to jk grep'

        # the page in each PDF app
        Assert-Eq (Get-JkPdfPageArgs 'C:\Program Files\Edge\msedge.exe' 'C:\x y\a#1.pdf' 4) '"file:///C:/x%20y/a%231.pdf#page=4"'
        Assert-Eq (Get-JkPdfPageArgs 'C:\Tools\SumatraPDF.exe' 'C:\x y\a.pdf' 4) '-page 4 "C:\x y\a.pdf"'
        Assert-True ($null -eq (Get-JkPdfPageArgs 'C:\Tools\viewer.exe' 'C:\a.pdf' 4)) 'no page for an unknown app'

        # a real PDF through pdftotext, when one is installed
        if (Find-JkPdfToText) {
            $real = Join-Path $other 'real.pdf'
            $objs = @('<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>')
            foreach ($i in 0, 1) { $objs += "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 200] /Resources << /Font << /F1 7 0 R >> >> /Contents $(5 + $i) 0 R >>" }
            foreach ($s in 'Gaussian elimination', 'the eigenvalue of the matrix') { $c = "BT /F1 12 Tf 20 100 Td ($s) Tj ET"; $objs += "<< /Length $($c.Length) >>`nstream`n$c`nendstream" }
            $objs += '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
            $sb = New-Object Text.StringBuilder; [void]$sb.Append("%PDF-1.4`n"); $offs = @()
            for ($k = 0; $k -lt $objs.Count; $k++) { $offs += $sb.Length; [void]$sb.Append("$($k + 1) 0 obj`n$($objs[$k])`nendobj`n") }
            $x = $sb.Length; [void]$sb.Append("xref`n0 $($objs.Count + 1)`n0000000000 65535 f `n")
            foreach ($o in $offs) { [void]$sb.Append(('{0:D10} 00000 n ' -f $o) + "`n") }
            [void]$sb.Append("trailer << /Size $($objs.Count + 1) /Root 1 0 R >>`nstartxref`n$x`n%%EOF`n")
            [IO.File]::WriteAllText($real, $sb.ToString(), [Text.Encoding]::ASCII)
            $t7 = @(& { jk grep math999 eigenvalue } 6>&1 | ForEach-Object { "$_" }) -join "`n"
            Assert-True ($t7 -match 'real\.pdf\s+p\.2\s+the eigenvalue of the matrix') "pdftotext, by page: $t7"
            # a name outside the code page reaches pdftotext as "?": it reads a plain copy instead, and
            # an empty result cached before that was fixed is read once more
            $cn = -join ([char[]](0x738B, 0x73CF))
            $cnDir = Join-Path $env:JK_HOME "$cn notes"; $null = New-Item -ItemType Directory -Path $cnDir -Force
            $cnPdf = Join-Path $cnDir "$cn.pdf"; [IO.File]::Copy($real, $cnPdf, $true)
            $cnFile = Get-Item -LiteralPath $cnPdf
            if (-not (Test-JkAnsiPath $cnPdf)) {
                $cached = Get-JkTextCachePath $cnFile.FullName
                $null = New-Item -ItemType Directory -Path (Split-Path $cached) -Force
                Write-JkText $cached "v1|$($cnFile.Length)|$($cnFile.LastWriteTimeUtc.Ticks)`n"
            }
            $doc = @(Get-JkGrepDocs @($cnFile))[0]
            Assert-True (-not $doc.Empty) 'a PDF named outside the code page is read'
            Assert-True ($doc.Pages[1] -match 'the eigenvalue') "its pages: $($doc.Pages -join ' / ')"
            Assert-Eq @(Get-ChildItem -LiteralPath (Join-Path (Get-JkCacheDir) 'text') -Filter '*.pdf').Count 0 'the copy is gone'
            $v1 = Get-Item -LiteralPath $real
            Assert-True ((Get-JkTextStamp $v1).StartsWith('v1|')) 'anything else keeps the text it has'
            # enough at once for the progress bar: every one read, none twice
            $many = Join-Path $other 'many'; $null = New-Item -ItemType Directory $many -Force
            1..22 | ForEach-Object { Copy-Item $real (Join-Path $many "copy$_.pdf") }
            $ErrorActionPreference = 'Stop'
            Update-JkPdfTexts @(Get-ChildItem $many -Filter *.pdf) 6>$null
            Assert-True (@(Get-ChildItem $many -Filter *.pdf | Where-Object { $null -eq (Read-JkTextCache $_) }).Count -eq 0) 'all 22 read and kept'
        }
    } finally {
        Set-Item function:script:Open-JkPdfAtPage $origOpen
        Set-JkConfig 'tidy.courses' $saved
    }
}
Test 'jk time: the gap and when it changes, call windows, places from languages, conversions' {
    $cn = [TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time')
    $et = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
    $uk = [TimeZoneInfo]::FindSystemTimeZoneById('GMT Standard Time')
    $U = { param([string]$s) [datetime]::SpecifyKind([datetime]::Parse($s, $script:Inv), 'Utc') }
    Assert-Eq (Get-JkClockGap $cn $et (& $U '2026-10-31T12:00:00')) 12 'Beijing 12h ahead before the fall back'
    Assert-Eq (Get-JkClockGap $cn $et (& $U '2026-11-02T12:00:00')) 13 'then 13h'
    $ch = Get-JkClockGapChange $cn $et (& $U '2026-10-31T12:00:00')
    Assert-Eq "$($ch.Utc.ToString('yyyy-MM-ddTHH:mm', $script:Inv)) $($ch.Before)>$($ch.After) $($ch.Side)" '2026-11-01T06:00 12>13 here' 'Waterloo falls back at 2 am EDT'
    $ch = Get-JkClockGapChange $uk $et (& $U '2026-10-20T12:00:00')
    Assert-Eq "$($ch.Utc.ToString('yyyy-MM-ddTHH:mm', $script:Inv)) $($ch.Before)>$($ch.After) $($ch.Side)" '2026-10-25T01:00 5>4 there' 'London falls back a week earlier'
    Assert-True ($null -eq (Get-JkClockGapChange $cn $cn (& $U '2026-10-31T12:00:00'))) 'no change, no note'
    $win = @(Get-JkCallWindows $cn $et (& $U '2026-11-01T03:00:00'))
    Assert-Eq "$($win[0].Start.ToString('MM-dd HH:mm', $script:Inv))-$($win[0].End.ToString('HH:mm', $script:Inv))" '11-01 08:00-09:00' 'after 11 pm here: 8-9 am, their 9-10 pm'
    Assert-Eq "$($win[1].Start.ToString('HH:mm', $script:Inv))" '20:00' 'then from 8 pm, their 9 am'
    Assert-Eq (Format-JkCallWindows $win ([datetime]'2026-10-31T23:00')) "8$($script:G.dash)9 am tomorrow, 8$($script:G.dash)11 pm tomorrow" 'the second runs to 11 pm, past where the next 24 hours end'
    $places = @(Get-JkClockAutoPlaces @('en-US', 'zh-Hans-CN', 'en-CA') 'CA')
    Assert-Eq "$($places.Name)|$($places.Zone.Id)" 'Beijing|China Standard Time' 'a Chinese (PRC) keyboard means Beijing'
    Assert-Eq (@(Get-JkClockAutoPlaces @('ko-KR', 'zh-Hant-TW', 'fr-CA') 'CA').Name -join ',') 'Seoul,Taipei' 'home country and English ones aside'
    foreach ($c in 'Shanghai', 'hong kong', 'China Standard Time', 'Urumqi') { Assert-Eq (Resolve-JkClockZone $c).Id 'China Standard Time' $c }
    Assert-True ($null -eq (Resolve-JkClockZone 'nowhereville')) 'unknown city'
    Assert-Eq "$(Format-JkClockGap 13)|$(Format-JkClockGap -5)|$(Format-JkClockGap 5.5)|$(Format-JkClockGap 0)" '13h ahead|5h behind|5h 30m ahead|same time'

    $savedNow = $env:JK_NOW; $savedZones = [string](Get-JkConfig 'time.zones')
    try {
        Set-JkConfig 'time.zones' 'Beijing=China Standard Time'
        $env:JK_NOW = '2026-10-31T22:00:00'
        $text = @(& { jk time } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($text -match 'Beijing\s+\w{3} \d{1,2}:\d{2} [ap]m\s+\d+h ahead') "row: $text"
        $utc = ([datetime]'2026-10-31T22:00:00').ToUniversalTime()
        if (Get-JkClockGapChange $cn ([TimeZoneInfo]::Local) $utc) { Assert-True ($text -match '\d+h ahead from 2 am tonight, when the clocks here go back an hour') 'the change, as the clock reads before it' }
        else { Assert-True ($text -notmatch 'when the clocks') 'no change in this zone' }
        # 8pm there, in my time
        $rows = @(Convert-JkClockTime @('8pm', 'beijing'))
        $there = [TimeZoneInfo]::ConvertTimeFromUtc($utc, $cn)
        $t8 = $there.Date.AddHours(20); if ($t8 -le $there) { $t8 = $t8.AddDays(1) }
        $mine = [TimeZoneInfo]::ConvertTimeFromUtc([TimeZoneInfo]::ConvertTimeToUtc([datetime]::SpecifyKind($t8, 'Unspecified'), $cn), [TimeZoneInfo]::Local)
        Assert-Eq $rows[0].To "$($mine.ToString('ddd', $script:Inv)) $(Format-JkTime $mine.ToString('HH:mm', $script:Inv)) here" 'there -> here'
        Assert-Eq (@(Convert-JkClockTime @('beijing', '8pm'))[0].To) $rows[0].To 'the place first works too'
        $rows = @(Convert-JkClockTime @('9am'))
        Assert-True ($rows[0].To -match ' in Beijing$' -and $rows[0].From -match '9:00 am here$') "here -> there: $($rows[0].From) / $($rows[0].To)"
        # a place alone: that place now, whether on the list or not
        $one = @(& { jk time beijing } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($one -match 'Beijing\s+\w{3} \d{1,2}:\d{2} [ap]m\s+\d+h ahead' -and $one -notmatch 'jk time add') "on the list: $one"
        $two = @(& { jk time new york } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($two -match 'New York\s+\w{3} \d{1,2}:\d{2} [ap]m' -and $two -match 'jk time add new york keeps it') "not on it: $two"
        Assert-True ((@(& { jk time nowhereville } 6>&1 | ForEach-Object { "$_" }) -join "`n") -match "can't read 'nowhereville' as a place or a time") 'neither a place nor a time still says so'
        jk time add london
        Assert-Eq ([string](Get-JkConfig 'time.zones')) 'Beijing=China Standard Time;London=GMT Standard Time' 'added'
        jk time rm beijing
        jk time rm london
        Assert-Eq ([string](Get-JkConfig 'time.zones')) 'off' 'emptied by hand stays empty (not refilled from languages)'
        Assert-Eq @(Get-JkClockPlaces).Count 0 'off'
        Assert-Throws { Invoke-JkTime add nowhereville } 'an unknown city is refused'
    } finally { $env:JK_NOW = $savedNow; Set-JkConfig 'time.zones' $savedZones }
}
Test 'jk time reads every word: a day after the time, a place anywhere, typos named, the skipped hour refused' {
    # jk at as well: the day can come after the time; words that only might be a day stay in the message
    $at = { param([string]$s) $x = Resolve-JkAtTime ($s -split ' ') ([datetime]'2026-10-22 14:00'); "$($x.At.ToString('MM-dd HH:mm', $script:Inv))/$($x.K)" }
    Assert-Eq (& $at '8pm tomorrow call') '10-23 20:00/2' 'the day after the time'
    Assert-Eq (& $at '9am dec 25 xmas') '12-25 09:00/3'
    Assert-Eq (& $at '5 fri leave') '10-23 17:00/2' 'a bare hour after a day is pm, as in fri 5'
    Assert-Eq (& $at '8 pm tomorrow') '10-23 20:00/3'
    Assert-Eq (& $at '7pm tom call') '10-22 19:00/1' 'tom is a name as often as tomorrow'
    Assert-Eq (& $at '5pm 3d printer') '10-22 17:00/1' 'not three days on'
    Assert-Eq (& $at '5pm 3 things') '10-22 17:00/1' 'not the 3rd'
    Assert-Eq (& $at '6pm march madness') '10-22 18:00/1'
    Assert-Throws { Resolve-JkAtTime @('8pm', 'nov', '31') ([datetime]'2026-10-22 14:00') } 'nov 31 is a typo to report'

    $cn = [TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time')
    $et = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
    $savedNow = $env:JK_NOW; $savedZones = [string](Get-JkConfig 'time.zones')
    try {
        Set-JkConfig 'time.zones' 'Beijing=China Standard Time'
        $env:JK_NOW = '2026-10-22T14:00:00'
        # their tomorrow, read on their clock: not the next 8 pm there with "tomorrow" dropped
        $there = [TimeZoneInfo]::ConvertTimeFromUtc((Get-JkNow).ToUniversalTime(), $cn)
        $next = "$($there.Date.AddDays(1).ToString('ddd', $script:Inv)) 8:00 pm in Beijing"
        Assert-Eq (@(Convert-JkClockTime @('8pm', 'tomorrow', 'beijing'))[0].From) $next 'the day after the time'
        Assert-Eq (@(Convert-JkClockTime @('8pm', 'beijing', 'tomorrow'))[0].From) $next 'the place in the middle'
        $xmas = @(Convert-JkClockTime @('8pm', 'dec', '25', 'beijing'))[0]
        Assert-Eq $xmas.From 'Fri Dec 25 8:00 pm in Beijing' 'a date weeks off, shown with its date'
        Assert-True ($xmas.To -match '^\w{3} Dec 2[45] \d') "both sides: $($xmas.To)"
        # a word that is not read is named, with the fix
        $why = try { $null = Convert-JkClockTime @('8pm', 'bejing'); '' } catch { $_.Exception.Message }
        Assert-True ($why -match "'bejing' is not a place or a day" -and $why -match 'jk time 8pm beijing$') "not 8 pm here with the place dropped: $why"
        $why = try { $null = Convert-JkClockTime @('8pm', 'tomorow', 'beijing'); '' } catch { $_.Exception.Message }
        Assert-True ($why -match 'Did you mean tomorrow\?\s+jk time 8pm tomorrow beijing$') $why
        $why = try { $null = Convert-JkClockTime @('8pm', 'xyz', 'beijing'); '' } catch { $_.Exception.Message }
        Assert-True ($why -match "'xyz' is not a place or a day \(") "no guess for a short word: $why"
        $one = @(& { jk time bejing } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($one -match 'Did you mean Beijing\?\s+jk time beijing') $one
        # the hour the clocks skip has no answer; the hour they repeat is said
        $why = try { $null = Convert-JkClockTime @('1:30am', 'mar', '28', 'london'); '' } catch { $_.Exception.Message }
        Assert-True ($why -like 'there is no 1:30 am in London on Sun Mar 28*') "London goes from 1 to 2 am on Mar 28 2027: $why"
        $r = @(Convert-JkClockTime @('1:30am', 'sun', 'london'))[0]
        Assert-True ($r.Twice -like '1:30 am comes twice in London*') "Oct 25, as London goes back: [$($r.Twice)]"
        $second = [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::SpecifyKind([datetime]'2026-10-25T01:30', 'Utc'), [TimeZoneInfo]::Local)
        Assert-Eq $r.To "$($second.ToString('ddd', $script:Inv)) $(Format-JkTime $second.ToString('HH:mm', $script:Inv)) here" 'the second 1:30, in GMT'
        # a gap of 13 characters keeps a space before awake/asleep
        $wide = @(& { jk time 'Chatham Islands Standard Time' } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($wide -match '\d+h 45m (ahead|behind)\s+(awake|asleep)') $wide
        Assert-Eq (Format-JkClockName 'utc') 'UTC'
        # a call window that starts in the next 24 hours runs to its real end
        $win = @(Get-JkCallWindows $et $et ([datetime]::SpecifyKind([datetime]'2026-10-22T18:00', 'Utc')))
        Assert-Eq (Format-JkCallWindows $win ([datetime]'2026-10-22T14:00')) "now$($script:G.dash)10 pm, 9 am$($script:G.dash)10 pm tomorrow" 'not 9 am-2 pm, where the 24 hours stop'
    } finally { $env:JK_NOW = $savedNow; Set-JkConfig 'time.zones' $savedZones }
}
Test 'disk filling up fast: a reading a day, 4 GB gone in three days is said' {
    $p = Join-Path (Get-JkCacheDir) 'disk.log'
    $saved = $null; if (Test-Path -LiteralPath $p) { $saved = [IO.File]::ReadAllText($p) }
    try {
        Remove-Item -LiteralPath $p -ErrorAction SilentlyContinue
        Update-JkDiskLog (66.3GB) ([datetime]'2026-11-01T09:00')
        Update-JkDiskLog (60GB) ([datetime]'2026-11-01T20:00')
        Update-JkDiskLog (63GB) ([datetime]'2026-11-02T09:00')
        $log = @(Get-JkDiskLog)
        Assert-Eq $log.Count 2 'one reading a day'
        Assert-Eq $log[0].Free ([double][long](66.3GB)) 'the first of the day is kept'
        $d = Get-JkDiskDrop (59.5GB) ([datetime]'2026-11-03T09:00')
        Assert-True ((Format-JkDiskDrop $d) -match '^-6[.,]8 GB since Sun$') "the drop: $(Format-JkDiskDrop $d)"
        Assert-True ($null -eq (Get-JkDiskDrop (63.5GB) ([datetime]'2026-11-03T09:00'))) 'under 4 GB: quiet'
        Assert-True ($null -eq (Get-JkDiskDrop (50GB) ([datetime]'2026-11-08T09:00'))) 'readings over three days old do not count'
        Update-JkDiskLog (59.5GB) ([datetime]'2026-11-03T09:00')
        Assert-True ((Get-JkDiskTrend) -match '^\S{3}  66[.,]3 GB . 59[.,]5 GB free over 3 days$') "trend: $(Get-JkDiskTrend)"
        for ($i = 0; $i -lt 30; $i++) { Update-JkDiskLog (50GB) ([datetime]'2026-12-01').AddDays($i) }
        Assert-Eq @(Get-JkDiskLog).Count 21 'three weeks kept'
    } finally {
        if ($null -ne $saved) { [IO.File]::WriteAllText($p, $saved) } else { Remove-Item -LiteralPath $p -ErrorAction SilentlyContinue }
    }
}
Test 'jk grep: a first word is a course only when it plainly names one; every course folder counts' {
    $courses = Join-Path $env:JK_HOME 'grep-scope'
    foreach ($n in 'CS350', 'CO367', 'HEALTH105', 'MATH999') { New-Item -ItemType Directory (Join-Path $courses $n) -Force | Out-Null }
    $mkc = { param($key, $code) [pscustomobject]@{ key = $key; code = $code; name = '' } }
    $data = [pscustomobject]@{ courses = @((& $mkc 'cs350' 'CS 350'), (& $mkc 'co367' 'CO 367'), (& $mkc 'health' 'HEALTH 105'), (& $mkc 'intv' 'Interviews'), (& $mkc 'oa' 'OA'), (& $mkc 'cs999' 'CS 999')) }
    $saved = Get-JkConfig 'tidy.courses'
    Set-JkConfig 'tidy.courses' $courses
    try {
        $f = { param([string]$q) $r = Get-JkGrepFolders $data ($q -split ' '); "$($r[2])|$(@($r[1]) -join ' ')|$(@($r[0] | ForEach-Object { Split-Path $_ -Leaf }) -join ',')" }
        $term = "this term's courses"
        $all = 'CS350,CO367,HEALTH105'
        # ordinary words inside a course's name stay words, and nothing is lost
        foreach ($q in 'in place sorting', 'he said', 'al gorithm', 'co prime', 'oa questions', 'dynamic programming') { Assert-Eq (& $f $q) "$term|$q|$all" $q }
        # this term's scope reaches a course whose key is not its folder's name
        Assert-True ((& $f 'stigma') -match 'HEALTH105') 'one word: this term, HEALTH105 included'
        # a course plainly named: by key, code, either spelling, or number
        foreach ($q in 'health stigma', 'health105 stigma') { Assert-Eq (& $f $q) 'HEALTH 105|stigma|HEALTH105' $q }
        foreach ($q in 'cs350 semaphore', 'cs 350 semaphore', '350 semaphore') { Assert-Eq (& $f $q) 'CS 350|semaphore|CS350' $q }
        Assert-Eq (& $f 'math999 eigenvalue') 'MATH999|eigenvalue|MATH999' 'a past course: by its folder'
        Assert-Eq (& $f 'all eigenvalue').Split('|')[0] 'every course' 'jk grep all'
        $msg = ''; try { $null = Get-JkGrepFolders $data @('cs999', 'x') } catch { $msg = $_.Exception.Message }
        Assert-True ($msg -match '^no folder found for CS 999 \(jk config set tidy\.courses') "a real course with no folder says so: $msg"
    } finally { Set-JkConfig 'tidy.courses' $saved }
}
Test 'jk shots find: the words in screenshots, read once, newest first, kept when filed' {
    $dir = Join-Path $env:JK_HOME 'shots-find'
    New-Item -ItemType Directory (Join-Path $dir '2026-10') -Force | Out-Null
    Add-Type -AssemblyName System.Drawing
    $mk = { param($path, $text, [datetime]$when)
        $bmp = New-Object Drawing.Bitmap 900, 110
        $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::White)
        if ($text) { $font = New-Object Drawing.Font 'Segoe UI', 30; $g.DrawString($text, $font, [Drawing.Brushes]::Black, 10, 25); $font.Dispose() }
        $g.Dispose(); $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        (Get-Item -LiteralPath $path).LastWriteTime = $when
    }
    $newest = Join-Path $dir 'Screenshot 2026-11-01 101010.png'
    & $mk $newest 'Take one step of Backward Euler' ([datetime]'2026-11-01T10:10')
    & $mk (Join-Path $dir '2026-10\Screenshot 2026-10-01 090909.png') 'The page table and the TLB' ([datetime]'2026-10-01T09:09')
    & $mk (Join-Path $dir 'Screenshot 2026-09-01 080808.png') '' ([datetime]'2026-09-01T08:08')
    $savedPath = Get-JkConfig 'shots.path'
    $idx = Get-JkShotsIndexPath
    Remove-Item -LiteralPath $idx -ErrorAction SilentlyContinue
    Set-JkConfig 'shots.path' $dir
    try {
        $ocr = $true; try { $null = Initialize-JkOcr } catch { $ocr = $false }
        if (-not $ocr) {
            # no OCR language on this machine: the search and its output still work from an index
            $shots = @(Get-JkShots $dir)
            [IO.File]::WriteAllLines($idx, [string[]]@($shots | ForEach-Object { (Get-JkShotKey $_) + "`t" + $(if ($_.Name -match '101010') { 'Take one step of Backward Euler' } elseif ($_.Name -match '090909') { 'The page table and the TLB' } else { '' }) }))
        } else {
            $u = Update-JkShotsIndex -Seconds 60
            Assert-Eq "$($u.Read) $($u.Left) $($u.Now)" '3 0 3' 'every screenshot read once'
            Assert-Eq (Update-JkShotsIndex -Seconds 60).Now 0 'nothing read twice'
            # read with other languages than last time (Chinese just installed): all of them again
            Set-Content -LiteralPath "$idx.langs" -Value 'xx-XX'
            Assert-Eq (Update-JkShotsIndex -Seconds 60).Now 3 'a new OCR language reads everything again'
            # a language of yours Windows cannot read in pictures is named, with where to add it
            $missing = @(Get-JkOcrMissing)
            Assert-True (@($missing | Where-Object { $_ -match '^English' }).Count -eq 0) "English is read: $($missing -join ', ')"
            $zhOcr = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | Where-Object { $_.LanguageTag -like 'zh*' }).Count
            if (@(Get-JkProfileLanguages | Where-Object { $_ -like 'zh*' }).Count -and -not $zhOcr) {
                Assert-True (@($missing | Where-Object { $_ -match '^Chinese \(Simplified' }).Count -eq 1) "Chinese named while its OCR is missing: $($missing -join ', ')"
                Assert-True ((@(& { jk shots find euler } 6>&1 | ForEach-Object { "$_" }) -join "`n") -match '(?s)Chinese \(Simplified[^)]*\) text is not read yet.*Optical character recognition') 'and how to add it'
            }
        }
        $t1 = @(& { jk shots find backward euler } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($t1 -match '1 screenshot . 3 of 3 read' -and $t1 -match 'Screenshot 2026-11-01 101010\.png' -and $t1 -match '(?i)backward euler') "found by its words: $t1"
        Assert-True ((Split-Path @(Get-JkFindLast)[0] -Leaf) -eq 'Screenshot 2026-11-01 101010.png') 'numbered for jk find -o'
        $t2 = @(& { jk shots find 'page table' } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($t2 -match 'Screenshot 2026-10-01 090909\.png\s+Oct 1\s+2026-10') "a phrase, in its month folder: $t2"
        Assert-True ((@(& { jk shots find zebra } 6>&1 | ForEach-Object { "$_" }) -join "`n") -match 'None of the screenshots') 'nothing found says so'
        # filed into a month folder (jk shots file): what was read is kept
        New-Item -ItemType Directory (Join-Path $dir '2026-11') -Force | Out-Null
        Move-Item -LiteralPath $newest -Destination (Join-Path $dir '2026-11')
        if ($ocr) { Assert-Eq (Update-JkShotsIndex -Seconds 60).Now 0 'a moved screenshot is not read again' }
        Assert-True ((@(& { jk shots find backward euler } 6>&1 | ForEach-Object { "$_" }) -join "`n") -match '101010\.png\s+\S[^\n]*?\s2026-11\s*(\n|$)') 'found where it is now (its date reads against the real clock)'
        # the background reader at work: a search reads nothing itself, and says what is left
        $mark = Get-JkShotsIndexMark
        & $mk (Join-Path $dir 'Screenshot 2026-11-02 070707.png') 'Quarterly pivot table' ([datetime]'2026-11-02T07:07')
        $held = [IO.File]::ReadAllText($idx)
        [IO.File]::WriteAllText($mark, '')
        $t3 = @(& { jk shots find quarterly } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-Eq ([IO.File]::ReadAllText($idx)) $held 'nothing read twice while it runs'
        Assert-True ($t3 -match '3 of 4 read' -and $t3 -match '1 older screenshots not read yet: reading them in the background') "says so: $t3"
        Remove-Item -LiteralPath $mark
        # jk shots forget takes the mark away: a reader that sees it gone stops and writes nothing
        if ($ocr) {
            $stopped = Update-JkShotsIndex -Seconds 60 -StopFile (Join-Path $env:JK_HOME 'no-such-mark')
            Assert-Eq "$($stopped.Now) $($stopped.Left)" '0 1' 'stopped before reading anything'
            Assert-Eq ([IO.File]::ReadAllText($idx)) $held 'and left nothing behind'
        }
        [IO.File]::WriteAllText($mark, '')
        jk shots forget
        Assert-True (-not (Test-Path -LiteralPath $idx)) 'forget deletes the text'
        Assert-True (-not (Test-Path -LiteralPath $mark)) 'and stops a background reader'
    } finally {
        Set-JkConfig 'shots.path' $savedPath
        Remove-Item -LiteralPath $idx, "$idx.langs" -ErrorAction SilentlyContinue
    }
}
Test 'jk clip ocr: the text in a snip on the clipboard, lines kept, put back as text' {
    $ocr = $true; try { $null = Initialize-JkOcr } catch { $ocr = $false }
    if (-not $ocr) { return }
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object Drawing.Bitmap 900, 170
    $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::White)
    $font = New-Object Drawing.Font 'Segoe UI', 28
    $g.DrawString('Forward Euler is explicit', $font, [Drawing.Brushes]::Black, 10, 15)
    $g.DrawString('Backward Euler is implicit', $font, [Drawing.Brushes]::Black, 10, 90)
    $font.Dispose(); $g.Dispose()
    # the clipboard is stood in for: a test never touches the real one
    $script:ClipPic = $bmp; $script:ClipOut = $null
    function script:Get-Clipboard { [CmdletBinding()] param([string]$Format, [switch]$Raw) if ($Format -eq 'Image') { if ($script:ClipPic) { return $script:ClipPic.Clone() }; return $null }; if ($Format -eq 'FileDropList') { return $null }; '' }
    function script:Set-Clipboard { [CmdletBinding()] param($Value) $script:ClipOut = $Value }
    try {
        $out = @(& { jk clip ocr } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ([string]$script:ClipOut -match '(?s)Forward Euler is explicit\s*\n\s*Backward Euler is implicit') "both lines, in order, on the clipboard: $script:ClipOut"
        Assert-True ($out -match 'read .\s+\d+ words' -and $out -match 'on the clipboard now') "says what it read: $out"
        Assert-True ((@(& { jk clip } 6>&1 | ForEach-Object { "$_" }) -join "`n") -match 'holds a picture.*jk clip ocr') 'jk clip points a picture at jk clip ocr'
        $script:ClipPic = $null
        Assert-Throws { Invoke-JkClipOcr } 'no picture: says how to snip one'
    } finally {
        Remove-Item function:script:Get-Clipboard, function:script:Set-Clipboard -ErrorAction SilentlyContinue
        $bmp.Dispose()
    }
}
Test 'the suite is sandboxed: jk setup and jk speed cannot reach the real profile, link or task' {
    # checked first: if any of these fails, the commands below are never run
    Assert-True ($env:JK_SANDBOX) 'JK_SANDBOX is set'
    Assert-True ((Get-JkModuleLink).StartsWith($env:JK_SANDBOX)) "module link: $(Get-JkModuleLink)"
    Assert-True ((Get-JkProfilePath).StartsWith($env:JK_SANDBOX)) "profile: $(Get-JkProfilePath)"
    Assert-True ($null -eq (Get-JkTaskInfo)) 'the real task is not reported'
    Assert-Eq @(Get-JkProfileFiles).Count 0 'jk speed sees no profile outside the sandbox'
    $before = Get-RealInstallStamp
    foreach ($label in 'setup uninstall', 'speed undo', 'speed fix', 'remind uninstall') {
        $argv = @($label -split ' ')
        $null = @(& { jk @argv } 6>&1 2>&1)
    }
    Assert-Eq (Get-RealInstallStamp) $before 'the real install is as it was'
    # and a profile in the sandbox is the one jk speed works on
    $sp = Get-JkProfilePath
    New-Item -ItemType Directory (Split-Path $sp) -Force | Out-Null
    Set-Content -LiteralPath $sp -Value '# sandbox profile'
    try { Assert-Eq @(Get-JkProfileFiles)[0].Path $sp } finally { Remove-Item -LiteralPath $sp -ErrorAction SilentlyContinue }
}
Test 'a missing, disabled or silent morning task is said on the dashboard' {
    $now = [datetime]'2026-11-06T09:00'
    $task = { param($state, $last) [pscustomobject]@{ State = $state; LastRunTime = $last; NextRunTime = $null; LastTaskResult = 0; PinnedToUtc = $false } }
    $gone = @(Get-JkTaskProblem $null $now)
    Assert-True ($gone[0] -eq 'jk setup install' -and $gone[1] -match 'gone.*no morning popup') "gone: $gone"
    $off = @(Get-JkTaskProblem (& $task 'Disabled' ([datetime]'2026-11-06T07:45')) $now)
    Assert-True ($off[0] -eq 'jk remind install' -and $off[1] -match 'switched off') "off: $off"
    $quiet = @(Get-JkTaskProblem (& $task 'Ready' ([datetime]'2026-11-02T07:45')) $now)
    Assert-True ($quiet[0] -eq 'jk remind install' -and $quiet[1] -match 'has not run since Mon Nov 2') "silent: $quiet"
    Assert-Eq @(Get-JkTaskProblem (& $task 'Ready' ([datetime]'2026-11-06T07:45')) $now).Count 0 'ran this morning'
    Assert-Eq @(Get-JkTaskProblem (& $task 'Ready' $null) $now).Count 0 'just installed, never run yet'
    # a sandbox has no task, so the dashboard does not cry wolf there (or in these tests)
    Assert-True (((Show-JkDashboard 6>&1 | ForEach-Object { "$_" }) -join "`n") -notmatch 'morning task') 'no warning in a sandbox'
}
Test 'three mornings run at unlock are not a silent morning task' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'tasklast-home'; $script:JkConfigCache = $null
    try {
        $now = [datetime]'2026-11-06T09:00'
        # jk-remind itself last ran Mon Nov 2; the PC slept through 7:45 since, and each morning ran at unlock
        $task = [pscustomobject]@{ State = 'Ready'; LastRunTime = [datetime]'2026-11-02T07:45'; NextRunTime = $null; LastTaskResult = 0; PinnedToUtc = $false }
        Set-JkState 'lastTick' '2026-11-06T08:52:10'
        Assert-Eq @(Get-JkTaskProblem $task $now).Count 0 'ran at unlock this morning'
        # really silent: the newest run of either names the day
        Set-JkState 'lastTick' '2026-11-03T08:00:00'
        $p = @(Get-JkTaskProblem $task $now)
        Assert-True ($p[1] -match 'has not run since Tue Nov 3') "silent since the last unlock run: $p"
        # a stamp from the future (test clock, clock change) is not a run
        Set-JkState 'lastTick' '2026-11-09T08:00:00'
        $p = @(Get-JkTaskProblem $task $now)
        Assert-True ($p[1] -match 'has not run since Mon Nov 2') "future stamp: $p"
    } finally { $env:JK_HOME = $saved; $script:JkConfigCache = $null }
}
Test 'every safe command and action runs on an empty install without a PowerShell error' {
    # What runs here is listed, rather than what to skip: a skip list that named "setup" and "speed"
    # let jk setup uninstall and jk speed undo through. A new command or action fails this test until
    # it is placed on one side or the other.
    $run = @(
        'due', 'due add', 'due done', 'due undone', 'due edit', 'due rm', 'due files', 'due all', 'due past', 'due week', 'due exams', 'due courses', 'due course',
        'class', 'class week', 'class list', 'class next', 'class add', 'class rm', 'week', 'exams', 'plan', 'plan week', 'review',
        'todo', 'todo add', 'todo done', 'todo undo', 'todo rm', 'todo clear', 'todo edit', 'todo all', 'focus status', 'focus log', 'focus add', 'focus undo', 'plan did',
        'remind', 'remind list', 'remind cancel', 'remind status', 'grade', 'grade set', 'grade clear', 'grade add', 'grade target', 'grade pass',
        'next', 'time', 'time add', 'time rm', 'time off', 'weather', 'weather set', 'weather off', 'stocks list', 'stocks rm', 'brief', 'config', 'config path', 'backup', 'backup list', 'help'
    )
    # these reach past the data folder: timers and popups, a browser or editor, the clipboard, the
    # network, real folders, the profile and the morning task, or they wait for someone at the keyboard
    $leave = @(
        'in', 'at', 'focus', 'focus 25', 'focus 50', 'focus 15', 'focus stop', 'plan start', 'due cal', 'due ics', 'due sync', 'due remind', 'due import',
        'class pick', 'class import', 'jobs', 'jobs todo', 'jobs skipped', 'jobs edit', 'jobs path', 'remind now', 'remind install', 'remind uninstall', 'remind test',
        'grade fill', 'grade import', 'tidy', 'tidy scan', 'tidy apply', 'tidy undo', 'tidy dupes', 'tidy old',
        'cp', 'cp new', 'cp listen', 'cp test', 'cp run', 'cp add', 'cp stress', 'cp open', 'cp clean', 'go', 'mark', 'find', 'grep', 'grep all', 'recent', 'repos', 'sys', 'pdf',
        'clip', 'clip ocr', 'clip unwrap', 'clip count', 'clip plain', 'shots', 'shots find', 'shots file', 'shots old', 'shots forget',
        'stocks', 'stocks add', 'stocks popup', 'net', 'net speed', 'port', 'space', 'space clean', 'speed', 'speed fix', 'speed undo', 'config set', 'config reset', 'config edit',
        'backup restore', 'backup mirror', 'update', 'doctor', 'setup', 'setup install', 'setup uninstall', 'setup status'
    )
    $all = @(foreach ($c in $script:JkCommands.Keys) { $c; foreach ($x in @($script:JkActions[$c]) | Where-Object { $_ -and $_ -ne 'help' }) { "$c $x" } })
    Assert-Eq (@($all | Where-Object { $run -notcontains $_ -and $leave -notcontains $_ }) -join ', ') '' 'on neither list'
    Assert-Eq (@($run | Where-Object { $leave -contains $_ }) -join ', ') '' 'on both lists'
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'empty-install'; $script:JkConfigCache = $null
    $bad = '(?i)exception|you cannot call a method|null-valued|is not recognized as|cannot be found|cannot index into'
    $problems = @()
    try {
        foreach ($label in $run) {
            $argv = @($label -split ' ')
            $out = @(& { jk @argv } 6>&1 2>&1 | ForEach-Object { "$_" })
            $hit = @($out | Where-Object { $_ -match $bad })[0]
            if ($hit) { $problems += "$label -> $($hit.Trim())" }
        }
        Assert-Eq ($problems -join ' | ') '' 'no command fails on empty data'
        # a word that does not fit gets jk's own message, not PowerShell's, and a huge number no hang
        $raw = '(?i)System\.Int32|positional parameter|argument transformation|exception calling|null-valued|cannot index into|is not recognized as|out of range\. parameter'
        $tails = @(, @('[')) + @(, @('99999')) + @(, @('1', '[')) + @(, @('cs341'))
        foreach ($label in $run) {
            foreach ($tail in $tails) {
                $argv = @($label -split ' ') + @($tail)
                $out = @(& { jk @argv } 6>&1 2>&1 | ForEach-Object { "$_" })
                $hit = @($out | Where-Object { $_ -match $raw })[0]
                if ($hit) { $problems += "jk $($argv -join ' ') -> $($hit.Trim())" }
            }
        }
        Assert-Eq ($problems -join ' | ') '' 'PowerShell error text on screen'
        # a bare action asks for what it needs, by its own name
        Assert-True ((@(& { jk due undone } 6>&1 | ForEach-Object { "$_" }) -join ' ') -match 'usage: jk due undone') 'jk due undone'
        Assert-True ((@(& { jk todo undo } 6>&1 | ForEach-Object { "$_" }) -join ' ') -match 'usage: jk todo undo') 'jk todo undo'
        Assert-True ((@(& { jk todo edit } 6>&1 | ForEach-Object { "$_" }) -join ' ') -match 'usage: jk todo edit <id>') 'jk todo edit'
    } finally { $env:JK_HOME = $saved; $script:JkConfigCache = $null }
}
Test 'jk next: an exam soon, a class soon, work due tonight, then the study planned' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'next-home'; $script:JkConfigCache = $null
    try {
        $d = Get-JkDueData
        $c370 = Resolve-JkCourse $d 'cs370' -Create; $hl = Resolve-JkCourse $d 'health105' -Create; $null = Resolve-JkCourse $d 'co367' -Create
        $null = New-JkEvent -Data $d -Course $c370.key -Date ([datetime]'2026-11-02') -Time '17:00' -Title 'Midterm' -Kind 'exam' -Note 'in person, MC 2065'
        $null = New-JkEvent -Data $d -Course $hl.key -Date ([datetime]'2026-11-02') -Time '23:59' -Title 'Assignment 5' -Kind 'due' -Weight '7.5%'
        $null = New-JkEvent -Data $d -Course $hl.key -Date ([datetime]'2026-11-05') -Time '23:59' -Title 'Assignment 6' -Kind 'due' -Weight '7.5%'
        Save-JkDueData $d
        Save-JkClassData ([pscustomobject]@{ nextId = 2; items = @([pscustomobject]@{ id = 1; course = 'co367'; kind = 'LEC'; days = @('Mon'); start = '13:30'; end = '14:50'; room = 'MC 2017'; from = ''; to = '' }) })
        $env:JK_NOW = '2026-11-02T13:00:00'
        $steps = @(Get-JkNextSteps (Get-JkNow))
        Assert-True ($steps[0].Text -match '^CS 370 Midterm at 5:00 pm \(in 4h 00m\)' -and $steps[0].Hint -match '^leave in time . in person, MC 2065 . jk exam cs370$') "the exam first: $($steps[0].Text) / $($steps[0].Hint)"
        Assert-True ($steps[1].Text -match '^CO 367 LEC in MC 2017 at 1:30 pm \(in 30m\)') "then the class: $($steps[1].Text)"
        Assert-True ($steps[2].Text -match '^HEALTH 105 Assignment 5, due 11:59 pm' -and $steps[2].Hint -match 'jk due done \d+') "then tonight's work: $($steps[2].Text)"
        Assert-True (-not @($steps | Where-Object { $_.Text -match 'Assignment 6' -and $_.Text -notmatch '^Study' }).Count) 'work due in three days is not "now"'
        $out = @(& { jk next } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($out -match '(?s)now\s+CS 370 Midterm.*then\s+CO 367 LEC.*then\s+HEALTH 105 Assignment 5') "the screen: $out"
        # a quiet evening: nothing within reach, so what comes next and when
        $env:JK_NOW = '2026-11-03T23:30:00'
        $quiet = @(Get-JkNextSteps (Get-JkNow))
        Assert-True ($quiet[0].Text -match '^Nothing pressing\. Next: HEALTH 105 Assignment 6, Thu Nov 5 \(in 2 days\)' -or $quiet[0].Text -match '^Study ') "quiet: $($quiet[0].Text)"
        # a deadline with no time is due today all day; an online quiz closing tonight is work to do
        $d = Get-JkDueData
        $null = New-JkEvent -Data $d -Course $c370.key -Date ([datetime]'2026-11-10') -Title 'Reading' -Kind 'due' -Weight '5%'
        $null = New-JkEvent -Data $d -Course $hl.key -Date ([datetime]'2026-11-10') -Time '06:00' -Title 'Quiz opens' -Kind 'exam'
        $null = New-JkEvent -Data $d -Course $hl.key -Date ([datetime]'2026-11-10') -Time '23:59' -Title 'Quiz closes' -Kind 'exam' -Weight '10%'
        Save-JkDueData $d
        $env:JK_NOW = '2026-11-10T08:00:00'
        $texts = @(Get-JkNextSteps (Get-JkNow))
        Assert-True (@($texts | Where-Object { $_.Text -eq 'CS 370 Reading, due today' }).Count -eq 1) "no time, 16 hours off, still today: $(@($texts | ForEach-Object { $_.Text }) -join ' / ')"
        Assert-True (@($texts | Where-Object { $_.Text -match 'Quiz closes' }).Count -eq 0) 'a quiz closing 16 hours off is not yet now'
        # during an exam that is what is happening; after it, it is not
        $d = Get-JkDueData
        $null = New-JkEvent -Data $d -Course $c370.key -Date ([datetime]'2026-11-12') -Time '10:00' -End '12:00' -Title 'Long exam' -Kind 'exam' -Note 'in person, MC 1'
        Save-JkDueData $d
        $env:JK_NOW = '2026-11-12T11:00:00'
        $during = @(Get-JkNextSteps (Get-JkNow))
        Assert-True ($during[0].Text -match '^CS 370 Long exam, under way until 12:00 pm$' -and $during[0].Hint -match 'in person, MC 1') "during: $($during[0].Text) / $($during[0].Hint)"
        $env:JK_NOW = '2026-11-12T12:30:00'
        Assert-True (-not @(Get-JkNextSteps (Get-JkNow) | Where-Object { $_.Text -match 'Long exam' }).Count) 'over at its end time'
        $env:JK_NOW = '2026-11-10T13:00:00'
        $texts = @(Get-JkNextSteps (Get-JkNow))
        $q = @($texts | Where-Object { $_.Text -match '^HEALTH 105 Quiz closes 11:59 pm \(in 10h 59m\)' })
        Assert-True ($q.Count -eq 1 -and $q[0].Hint -match '^write it, then jk due done \d+$') "the quiz, 11 hours from closing: $(@($texts | ForEach-Object { $_.Text }) -join ' / ')"
        Assert-True (@($texts | Where-Object { $_.Text -match '^Study .*(Reading|Quiz)' }).Count -eq 0) 'what is listed as due is not listed again as study'
    } finally { $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null }
}
Test 'overdue since and the next deadline say which day: a date from a week back, the clock later today' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'pastday-home'; $script:JkConfigCache = $null
    $origNotify = ${function:Show-JkNotify}; $origPlan = ${function:Get-JkPlanToday}
    function script:Show-JkNotify { param([string]$Title, [string[]]$Lines) $script:PastLines = $Lines; 'stub' }
    # no study planned, so jk next can have nothing pressing
    function script:Get-JkPlanToday { $null }
    try {
        $env:JK_NOW = '2026-10-22T09:00:00'
        Add-JkTodo return library book -Due 'oct 6'
        Add-JkTodo email the TA -Due 'oct 20'
        $script:PastLines = $null
        Invoke-JkDueRemind -Quiet -Force
        Assert-Eq (@($script:PastLines | Where-Object { $_ -like 'To-do:*' }) -join '') 'To-do: return library book (overdue since Tue Oct 6), email the TA (overdue since Tue)' 'the popup: two Tuesdays, told apart'
        $steps = @(Get-JkNextSteps (Get-JkNow))
        Assert-True (@($steps | Where-Object { $_.Text -eq 'return library book (overdue since Tue Oct 6)' }).Count -eq 1) "jk next, 16 days back: $(@($steps | ForEach-Object { $_.Text }) -join ' / ')"
        Assert-True (@($steps | Where-Object { $_.Text -eq 'email the TA (overdue since Tue)' }).Count -eq 1) 'two days back, the weekday is enough'
        # nothing pressing and the next deadline tonight: its clock, not "(in 0 days)"
        $td = Get-JkTodoData; foreach ($i in $td.items) { $i.done = $true }; Save-JkTodoData $td
        $dd = Get-JkDueData; $c = Resolve-JkCourse $dd 'cs341' -Create
        $null = New-JkEvent -Data $dd -Course $c.key -Date ([datetime]'2026-10-22') -Time '23:59' -Title 'A5' -Kind 'due'
        Save-JkDueData $dd
        $q = @(Get-JkNextSteps (Get-JkNow))[0].Text
        Assert-True ($q -match '^Nothing pressing\. Next: CS 341 A5, today 11:59 pm \(in 14h 59m\)$') "later today: $q"
        $env:JK_NOW = '2026-10-21T09:00:00'
        $q = @(Get-JkNextSteps (Get-JkNow))[0].Text
        Assert-True ($q -match '^Nothing pressing\. Next: CS 341 A5, tomorrow 11:59 pm \(in ') "tomorrow, not (in 1 days): $q"
        $env:JK_NOW = '2026-10-15T09:00:00'
        Assert-Eq @(Get-JkNextSteps (Get-JkNow))[0].Text 'Nothing pressing. Next: CS 341 A5, Thu Oct 22 (in 7 days)' 'a week off: the date'
        # the helper jk space's "+2 GB since ..." uses too: a week back is today's weekday, so it takes the date
        Assert-Eq "$(Format-JkPastDay ([datetime]'2026-10-16') ([datetime]'2026-10-22'))|$(Format-JkPastDay ([datetime]'2026-10-15T18:00') ([datetime]'2026-10-22T09:00'))" 'Fri|Thu Oct 15'
    } finally {
        Set-Item function:script:Show-JkNotify $origNotify; Set-Item function:script:Get-JkPlanToday $origPlan
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null
    }
}
Test 'a window open for a week names the day it closes: Mon Nov 16, not a second Mon; the same day, just the time' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'weekwin-home'; $script:JkConfigCache = $null
    $origNotify = ${function:Show-JkNotify}; $origPlan = ${function:Get-JkPlanToday}
    function script:Show-JkNotify { param([string]$Title, [string[]]$Lines) $script:WinLines = $Lines; 'stub' }
    function script:Get-JkPlanToday { $null }
    try {
        $dd = Get-JkDueData; $c = Resolve-JkCourse $dd 'cs341' -Create
        # an online midterm open Monday to the Monday after, and a quiz open one afternoon
        $null = New-JkEvent -Data $dd -Course $c.key -Date ([datetime]'2026-11-09') -Time '09:00' -Title 'Midterm opens' -Kind 'exam'
        $null = New-JkEvent -Data $dd -Course $c.key -Date ([datetime]'2026-11-16') -Time '23:59' -Title 'Midterm closes' -Kind 'exam'
        $null = New-JkEvent -Data $dd -Course $c.key -Date ([datetime]'2026-11-09') -Time '13:00' -Title 'Quiz 5 opens'
        $null = New-JkEvent -Data $dd -Course $c.key -Date ([datetime]'2026-11-09') -Time '23:59' -Title 'Quiz 5 closes'
        Save-JkDueData $dd
        # Sunday morning; both open tomorrow
        $env:JK_NOW = '2026-11-08T08:05:00'
        $script:WinLines = $null
        Invoke-JkDueRemind -Quiet -Force
        $all = $script:WinLines -join ' / '
        Assert-True (@($script:WinLines | Where-Object { $_ -match 'CS 341 Midterm opens \(exam\), open until Mon Nov 16 11:59 pm$' }).Count -eq 1) "popup, a week-long window: $all"
        Assert-True (@($script:WinLines | Where-Object { $_ -match 'CS 341 Quiz 5 opens, open until 11:59 pm$' }).Count -eq 1) "popup, closing the day it opens: $all"
        # Sunday's count: the quiz is one thing due, not its opening and its closing
        Assert-True (@($script:WinLines | Where-Object { $_ -like 'This week: 1 due, 1 exam*' }).Count -eq 1) "week line: $all"
        # the dashboard's NEXT EXAM callout gives the range
        $dash = (Show-JkDashboard 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($dash -match 'Mon Nov 9 9:00 am . Mon Nov 16 11:59 pm') "dashboard: $(@($dash -split "`n" | Where-Object { $_ -match 'NEXT EXAM' }) -join '')"
    } finally {
        Set-Item function:script:Show-JkNotify $origNotify; Set-Item function:script:Get-JkPlanToday $origPlan
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null
    }
}
Test 'jk due: an exam being written says now and one finished says over, not passed; an open quiz window says open; one online midterm counts once' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'started-home'; $script:JkConfigCache = $null
    try {
        $dd = Get-JkDueData; $c = Resolve-JkCourse $dd 'cs341' -Create; $h = Resolve-JkCourse $dd 'health105' -Create
        $null = New-JkEvent -Data $dd -Course $c.key -Date ([datetime]'2026-11-09') -Time '18:00' -End '19:50' -Title 'Midterm 2' -Kind 'exam'
        $null = New-JkEvent -Data $dd -Course $c.key -Date ([datetime]'2026-11-09') -Time '12:00' -Title 'Lab 4'
        $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-11-09') -Time '06:00' -Title 'Midterm opens' -Kind 'exam'
        $null = New-JkEvent -Data $dd -Course $h.key -Date ([datetime]'2026-11-10') -Time '23:59' -Title 'Midterm closes' -Kind 'exam'
        Save-JkDueData $dd
        $row = { param($now, $title) $env:JK_NOW = $now; $l = @(Show-JkDue 6>&1 | ForEach-Object { "$_" }); @($l | Where-Object { $_ -match " $title " })[0] + ' || ' + @($l | Where-Object { $_ -match 'DEADLINES' })[0] }
        $r = & $row '2026-11-09T18:40:00' 'Midterm 2'
        Assert-True ($r -match 'EXAM\s+6:00 pm\s+now\s') "under way: $r"
        $r = & $row '2026-11-09T23:20:00' 'Midterm 2'
        Assert-True ($r -match 'EXAM\s+6:00 pm\s+over\s') "finished: $r"
        $r = & $row '2026-11-09T18:40:00' 'Midterm opens'
        Assert-True ($r -match 'EXAM\s+6:00 am\s+open\s') "the quiz window, open until tomorrow night: $r"
        # a deadline gone by is still "passed"; the two midterms are 2 exams, not 3
        $r = & $row '2026-11-09T18:40:00' 'Lab 4'
        Assert-True ($r -match '12:00 pm\s+passed\s') "a deadline: $r"
        Assert-True ($r -match '4 items . 2 exams') "the header: $r"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null
    }
}
Test 'a PC that slept through 7:45 gets the morning run at unlock, once; unlocks otherwise do nothing' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW
    $env:JK_HOME = Join-Path $saved 'unlock-home'; $script:JkConfigCache = $null
    $origTick = ${function:Invoke-JkTick}; $origInfo = ${function:Get-JkTaskInfo}
    function script:Invoke-JkTick([switch]$CatchUp) { $script:TickRuns += @("catch-up=$([bool]$CatchUp)"); Set-JkState 'lastTick' ((Get-JkNow).ToString('s', $script:Inv)) }
    try {
        Set-JkConfig 'remind.time' '07:45'
        $miss ={ param($now, $last) if ($last) { Set-JkState 'lastTick' $last } else { Set-JkState 'lastTick' $null }; [bool](Test-JkMorningRunMissed ([datetime]$now)) }
        Assert-Eq "$(& $miss '2026-11-08T09:44' '2026-11-07T07:45:02')|$(& $miss '2026-11-08T09:44' '2026-11-08T07:00:10')|$(& $miss '2026-11-08T09:44' '')" 'True|True|True' 'slept through: last run yesterday, or only at a 7:00 sign-in, or never'
        Assert-Eq "$(& $miss '2026-11-08T09:44' '2026-11-08T07:45:03')|$(& $miss '2026-11-08T07:30' '2026-11-07T07:45:02')" 'False|False' 'ran at 7:45; or 7:45 has not come yet'
        Assert-Eq (& $miss '2026-11-08T09:44' '2026-11-09T07:45:00') 'True' 'a stamp from the future is not a run'
        # the unlock task's command: missed, it runs once; the next unlock finds it done. (Code without
        # the stubbed Invoke-JkTick would do a real morning run here, popup and all: stop instead.)
        if (-not (Get-Command Test-JkMorningRunMissed -ErrorAction SilentlyContinue)) { throw 'no catch-up in this code, so the real tick is not run' }
        Set-JkState 'lastTick' '2026-11-07T07:45:02'
        $env:JK_NOW = '2026-11-08T09:44:31'
        $script:TickRuns = @()
        jk remind tick -IfMissed
        jk remind tick -IfMissed
        Assert-Eq ($script:TickRuns -join ',') 'catch-up=True' 'one catch-up for two unlocks'
        # the 7:45 trigger and sign-in keep running it every time
        jk remind tick
        Assert-Eq ($script:TickRuns -join ',') 'catch-up=True,catch-up=False'
        # what the second task runs and when
        Assert-True ((Get-JkTaskCommand 'tick -IfMissed') -match "; jk remind tick -IfMissed$") (Get-JkTaskCommand 'tick -IfMissed')
        $tr = New-JkUnlockTrigger
        Assert-Eq "$($tr.StateChange)|$($tr.Delay)|$($tr.UserId)" "8|PT1M|$env:USERDOMAIN\$env:USERNAME" 'at unlock, a minute later, for this user'
        # jk doctor names an install from before it
        function script:Get-JkTaskInfo([string]$Name = $script:JkTaskName) { if ($Name -eq $script:JkTaskName) { [pscustomobject]@{ State = 'Ready'; NextRunTime = $null; LastRunTime = $null; LastTaskResult = 0; PinnedToUtc = $false } } }
        $doc = (Invoke-JkDoctor 6>&1 | ForEach-Object { "$_" }) -join "`n"
        # whole, with its command, at the suite's width (100) too
        Assert-True ($doc -match '(?m)catch-up at unlock\s+missing: asleep at 7:45 am, no popup - jk remind install\r?$') "doctor:$(@($doc -split "`n" | Where-Object { $_ -match 'catch-up|reminder task' }) -join ' / ')"
    } finally {
        Set-Item function:script:Invoke-JkTick $origTick; Set-Item function:script:Get-JkTaskInfo $origInfo
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $script:JkConfigCache = $null
    }
}
Test 'the time before the day: jk due add A5 5pm fri and jk todo call mom 5pm fri keep the time, not as title words' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'timefirst-home'; $script:JkConfigCache = $null
    try {
        # the pinned clock is Thu Oct 22, 2 pm
        $f = { param($s) try { $r = ConvertFrom-JkWhen $s; "$($r.Date.ToString('MM-dd')) $($r.Time)".Trim() } catch { "ERR $($_.Exception.Message)" } }
        Assert-Eq "$(& $f '5pm fri')|$(& $f '11:59 pm dec 2')|$(& $f 'noon tomorrow')|$(& $f '8pm tonight')|$(& $f '9am 12/2')" '10-23 17:00|12-02 23:59|10-23 12:00|10-22 20:00|12-02 09:00' 'time, then day'
        Assert-True ((& $f '5pm nov 31') -like 'ERR no such date*') "a typo in the day is named: $(& $f '5pm nov 31')"
        Assert-True ((& $f '5pm 3d') -like 'ERR *' -and (& $f '3 fri') -like 'ERR *') 'not a day after a time: 3d; not a time before a day: a bare 3'
        # the newest (events are kept in date order)
        $last = { $e = @((Get-JkDueData).events | Sort-Object { [int]$_.id })[-1]; "$($e.title)|$($e.date) $($e.time)" }
        $null = Add-JkDue cs341 A5 5pm fri 6>&1
        Assert-Eq (& $last) 'A5|2026-10-23 17:00' 'jk due add cs341 A5 5pm fri'
        $null = Add-JkDue cs341 A6 due 11:59pm dec 2 6>&1
        Assert-Eq (& $last) 'A6|2026-12-02 23:59' 'jk due add cs341 A6 due 11:59pm dec 2'
        $null = Add-JkDue cs341 Quiz 3 fri 6>&1
        Assert-Eq (& $last) 'Quiz 3|2026-10-23 ' 'the 3 of Quiz 3 is still the title'
        $id = @((Get-JkDueData).events | Where-Object { $_.title -eq 'A5' })[0].id
        $r = try { $null = Edit-JkDue $id -Date 5pm mon 6>&1; $e = @((Get-JkDueData).events | Where-Object { $_.id -eq $id })[0]; "$($e.date) $($e.time)" } catch { "ERR $($_.Exception.Message)" }
        Assert-Eq $r '2026-10-26 17:00' 'jk due edit -Date 5pm mon'
        $todo = { $t = @((Get-JkTodoData).items | Sort-Object { [int]$_.id })[-1]; "$($t.text)|$($t.due)" }
        $null = Add-JkTodo call mom 5pm fri 6>&1
        Assert-Eq (& $todo) 'call mom|2026-10-23T17:00:00' 'jk todo call mom 5pm fri'
        $null = Add-JkTodo call mom -Due 5pm fri 6>&1
        Assert-Eq (& $todo) 'call mom|2026-10-23T17:00:00' '-Due 5pm fri: Friday, not today'
        $null = Add-JkTodo submit form 11:59pm dec 2 6>&1
        Assert-Eq (& $todo) 'submit form|2026-12-02T23:59:00'
        $null = Add-JkTodo call dad 8pm tonight 6>&1
        Assert-Eq (& $todo) 'call dad|2026-10-22T20:00:00'
        # "tom" before a time is a name; after "by" it is tomorrow
        $null = Add-JkTodo call tom at 7pm 6>&1
        Assert-Eq (& $todo) 'call tom|2026-10-22T19:00:00' 'call tom at 7pm'
        $null = Add-JkTodo call mom by tom 6>&1
        Assert-Eq (& $todo) 'call mom|2026-10-23T00:00:00' 'by tom'
        # jk at reads as before
        $at = { param([string]$s) $x = Resolve-JkAtTime ($s -split ' ') (Get-JkNow); "$($x.At.ToString('MM-dd HH:mm'))/$($x.K)" }
        Assert-Eq "$(& $at '8pm tomorrow call')|$(& $at '7pm tom')|$(& $at '5pm 3d printer')" '10-23 20:00/2|10-22 19:00/1|10-22 17:00/1'
    } finally {
        $env:JK_HOME = $saved; $script:JkConfigCache = $null
    }
}
Test 'jk <course>: one course on a screen; a word after it goes to that command' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'course-home'; $script:JkConfigCache = $null
    try {
        Import-JkDueHtml $htmlPath | Out-Null
        $d = Get-JkDueData
        $co = Resolve-JkCourse $d 'co250' -Create
        $null = New-JkEvent -Data $d -Course $co.key -Date ([datetime]'2026-10-30') -Time '23:59' -Title 'Assignment 6' -Kind 'due'
        Save-JkDueData $d
        $text = @(& { jk cs350 } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($text -match 'CS 350') "header: $text"
        Assert-True ($text -match 'exam\s+Midterm\s+Thu Oct 29 4:30 pm \(in 7 days\)') 'its exam, with how far off'
        Assert-True ($text -match '(?s)due\s+.*A2A Synchronization \(Wed Oct 28 8:00 pm\)') 'its deadlines'
        Assert-True ($text -match 'marks\s+' -and $text -match 'classes\s+') 'marks and classes rows'
        Assert-True ((@(& { jk cs 350 } 6>&1 | ForEach-Object { "$_" }) -join "`n") -match 'exam\s+Midterm') 'jk cs 350 too'
        # "co" alone is the start of config, but co 250 is plainly a course
        Assert-True ((@(& { jk co 250 } 6>&1 | ForEach-Object { "$_" }) -join "`n") -match '(?s)CO 250.*Assignment 6 \(Fri Oct 30 11:59 pm\)') 'jk co 250 is the course, not jk config'
        Assert-True ((@(& { jk cs350 exam } 6>&1 | ForEach-Object { "$_" }) -join "`n") -match 'CS 350 MIDTERM') 'jk cs350 exam = jk exam cs350'
        Assert-True ((@(& { jk cs350 dance } 6>&1 | ForEach-Object { "$_" }) -join "`n") -match 'after a course: exam, papers, grade') 'an unknown word says what works'
        Assert-True ((@(& { jk blorp } 6>&1 | ForEach-Object { "$_" }) -join "`n") -match "unknown command 'blorp'") 'not a course either'
        # a course is named whole: a typo that happens to sit inside one is not that course
        foreach ($typo in 'ea', 'alt', 's35') { Assert-True ((@(& { jk $typo } 6>&1 | ForEach-Object { "$_" }) -join "`n") -match 'unknown command') "jk $typo" }
        Assert-True ((@(& { jk 350 } 6>&1 | ForEach-Object { "$_" }) -join "`n") -match 'CS 350') 'its number is enough'
        # an entry like Interviews is no course: no hints about its marks or classes
        $d = Get-JkDueData; $null = Resolve-JkCourse $d 'intv' -Create; Save-JkDueData $d
        $iv = @(& { jk intv } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($iv -notmatch 'jk grade import|jk class pick') "no course hints: $iv"
        Assert-True ((@(& { jk rec 14 } 6>&1 | ForEach-Object { "$_" }) -join "`n") -notmatch 'unknown command') 'a command prefix with a number still reaches the command when no course is called that'
    } finally { $env:JK_HOME = $saved; $script:JkConfigCache = $null }
}
Test 'an unknown command says what was probably meant: a typo, a swapped course number, or a word jk knows by another name' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'guess-home'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $d = Get-JkDueData; $null = Resolve-JkCourse $d 'cs341' -Create; $null = Resolve-JkCourse $d 'health105' -Create; Save-JkDueData $d
        $say = { param($w) (@(& { jk $w } 6>&1 | ForEach-Object { "$_" }) -join "`n") }
        Assert-True ((& $say 'gard') -match "unknown command 'gard'\. Did you mean jk grade\?") 'a typo: gard'
        Assert-True ((& $say 'exmas') -match 'Did you mean jk exams\?') 'two letters swapped: exmas'
        Assert-True ((& $say 'cs314') -match 'Did you mean jk cs341\?') 'a course number with two digits swapped'
        Assert-True ((& $say 'today') -match 'Did you mean jk \(the dashboard\)\?') 'today is the dashboard'
        Assert-True ((& $say 'dashbaord') -match 'Did you mean jk \(the dashboard\)\?') 'a typo of a word jk knows by another name'
        Assert-True ((& $say 'time2') -match 'Did you mean jk time or jk focus\?') 'a tie: the command before the word'
        Assert-True ((& $say 'helth') -match 'Did you mean jk health') 'a course by its name alone'
        Assert-True ((& $say 'tomorrow') -match 'Did you mean jk due 2\?') 'tomorrow'
        Assert-True ((& $say 'gpa') -match 'Did you mean jk grade\?') 'gpa'
        Assert-True ((& $say 'midterm') -match 'Did you mean jk exams\?') 'midterm (the alias is midterms)'
        # an alias's typo names the command it belongs to
        Assert-True ((& $say 'pomodro') -match 'Did you mean jk focus\?') 'pomodro'
        # nothing near: the old line, no guess
        $b = & $say 'blorp'
        Assert-True ($b -match "unknown command 'blorp'\. Try 'jk help'" -and $b -notmatch 'Did you mean') "blorp: $b"
        # a two-letter word is not guessed at: "zz" is not one letter from anything worth naming
        Assert-True ((& $say 'zz') -notmatch 'Did you mean') 'zz'
        Assert-Eq (@(Get-JkCommandGuess 'grade').Count) 0 'a real command is not guessed at'
    } finally { $env:JK_HOME = $saved; $script:JkConfigCache = $null; $script:JkDueCache = $null }
}
Test 'jk space: what grew since an earlier run (500 MB or more, 12 hours or more before)' {
    $p = Join-Path (Get-JkCacheDir) 'space.log'
    $saved = $null; if (Test-Path -LiteralPath $p) { $saved = [IO.File]::ReadAllText($p) }
    try {
        Remove-Item -LiteralPath $p -ErrorAction SilentlyContinue
        $rows = { param([double]$emu, [double]$chat) @([pscustomobject]@{ Key = 'emulator1'; Bytes = $emu }, [pscustomobject]@{ Key = 'wechat'; Bytes = $chat }, [pscustomobject]@{ Key = $null; Bytes = 1GB }) }
        Add-JkSpaceLog (& $rows 20GB 9.6GB) ([datetime]'2026-10-31T22:00')
        Add-JkSpaceLog (& $rows 25GB 9.6GB) ([datetime]'2026-11-02T10:00')
        $log = @(Get-JkSpaceLog)
        Assert-Eq $log.Count 4 'two runs, two places each (a row without a key is not kept)'
        $g = Get-JkSpaceGrowth $log 'emulator1' (26.2GB) ([datetime]'2026-11-02T18:00')
        Assert-True ($g -and [Math]::Round($g.Grew / 1GB, 1) -eq 6.2 -and $g.Since.DayOfWeek -eq 'Saturday') 'measured against the last run 12h or more before (Saturday, not this morning)'
        Assert-True ($null -eq (Get-JkSpaceGrowth $log 'wechat' (9.9GB) ([datetime]'2026-11-02T18:00'))) 'under 500 MB: nothing to say'
        Assert-True ($null -eq (Get-JkSpaceGrowth $log 'emulator1' (40GB) ([datetime]'2026-10-31T23:00'))) 'nothing 12h before: no claim'
        1..250 | ForEach-Object { Add-JkSpaceLog (& $rows 1GB 1GB) ([datetime]'2026-12-01') }
        Assert-Eq @(Get-JkSpaceLog).Count 400 'the log keeps the newest 400 lines'
    } finally {
        if ($null -ne $saved) { [IO.File]::WriteAllText($p, $saved) } else { Remove-Item -LiteralPath $p -ErrorAction SilentlyContinue }
    }
}
Test 'jk weather: rain or snow from when, what to take, the exam, kept for an hour' {
    $savedNow = $env:JK_NOW; $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'weather-home'; $script:JkConfigCache = $null
    $orig = ${function:Invoke-JkWeatherGet}
    $origBg = ${function:Start-JkBackground}
    $files = @('weather.txt', 'weather-places.json', 'weather.refresh', 'weather.error' | ForEach-Object { Join-Path (Get-JkCacheDir) $_ })
    try {
        $files | ForEach-Object { Remove-Item -LiteralPath $_ -ErrorAction SilentlyContinue }
        # a pinned clock never goes to the network
        $env:JK_NOW = '2026-11-03T08:00:00'
        Assert-True ($null -eq (Get-JkWeather)) 'no live fetch under JK_NOW'
        Assert-True ($script:JkWeatherError -match 'JK_NOW') "why: $script:JkWeatherError"

        # six days from Nov 2, built from local times so every zone reads the same hours
        $unix = { param([datetime]$t) (New-Object DateTimeOffset ($t.ToUniversalTime())).ToUnixTimeSeconds() }
        $H = @{ time = @(); temperature_2m = @(); apparent_temperature = @(); precipitation_probability = @(); precipitation = @(); snowfall = @(); weather_code = @(); wind_speed_10m = @(); wind_gusts_10m = @() }
        $t0 = [datetime]'2026-11-02T00:00:00'
        for ($i = 0; $i -lt 144; $i++) {
            $t = $t0.AddHours($i)
            $temp = [Math]::Round($t.Hour / 2.0, 1); $feels = $temp - 2; $pop = 0; $mm = 0.0; $cm = 0.0; $code = 3; $gust = 20
            if ($t.Date -eq [datetime]'2026-11-03' -and $t.Hour -ge 14 -and $t.Hour -lt 18) { $pop = 80; $mm = 1.0; $code = 63 }
            if (($t.Date -eq [datetime]'2026-11-05' -and $t.Hour -ge 21) -or ($t.Date -eq [datetime]'2026-11-06' -and $t.Hour -lt 3)) { $pop = 70; $mm = 1.0; $cm = 1.0; $code = 73; $temp = -2; $feels = -6 }
            if ($t.Date -eq [datetime]'2026-11-06' -and $t.Hour -eq 7) { $pop = 60; $mm = 0.5; $code = 66 }
            if ($t.Date -eq [datetime]'2026-11-06' -and $t.Hour -ge 7 -and $t.Hour -le 9) { $feels = -15 }
            if ($t.Date -eq [datetime]'2026-11-07' -and $t.Hour -eq 12) { $gust = 70 }
            $H.time += (& $unix $t); $H.temperature_2m += $temp; $H.apparent_temperature += $feels; $H.precipitation_probability += $pop
            $H.precipitation += $mm; $H.snowfall += $cm; $H.weather_code += $code; $H.wind_speed_10m += 12; $H.wind_gusts_10m += $gust
        }
        $script:WxFixture = ConvertTo-Json -Depth 4 -Compress @{
            current = @{ time = (& $unix ([datetime]'2026-11-03T08:00')); temperature_2m = 4; apparent_temperature = 0; weather_code = 3; wind_speed_10m = 12 }
            hourly  = $H
            daily   = @{ sunrise = @((& $unix ([datetime]'2026-11-03T06:55'))); sunset = @((& $unix ([datetime]'2026-11-03T17:05'))) }
        }
        $script:WxCalls = @()
        function script:Invoke-JkWeatherGet {
            param([string]$Url, [int]$TimeoutSec = 6)
            $script:WxCalls += $Url
            if ($Url -match 'geocoding') {
                if ($Url -match 'name=london$') { return '{"results":[{"name":"London","latitude":51.5085,"longitude":-0.1257,"country_code":"GB","country":"United Kingdom","admin1":"England"},{"name":"London","latitude":42.9834,"longitude":-81.233,"country_code":"CA","country":"Canada","admin1":"Ontario"}]}' }
                return '{}'
            }
            $script:WxFixture
        }
        function script:Start-JkBackground { param([string]$Script, [hashtable]$Env = @{}, [string]$WaitUntil) $script:WxBg = $Script; [pscustomobject]@{ Id = 0; StartTime = (Get-Date) } }

        $w = Get-JkWeather
        Assert-Eq $script:WxCalls.Count 1 'fetched once'
        Assert-True ($script:WxCalls[0] -match 'latitude=43\.4643&longitude=-80\.5204' -and $script:WxCalls[0] -match 'timeformat=unixtime') "Waterloo by default, as instants: $($script:WxCalls[0])"
        $null = Get-JkWeather
        Assert-Eq $script:WxCalls.Count 1 'the kept forecast is used within the hour'
        Assert-Eq (Get-JkWeatherHour $w ([datetime]'2026-11-03T14:30')).Pop 80 'hours land on local time'

        $text = @(& { jk weather } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($text -match 'today\s+12. / 0.\s+rain 2.6 pm \(80%\)\s+. umbrella') "today: $text"
        Assert-True ($text -match 'Thu Nov 5\s+10. / -2.\s+snow from 9 pm \(70%, 3 cm\)\s+. boots') 'snow from 9 pm, boots'
        Assert-True ($text -match 'Fri Nov 6 .*freezing rain 7.8 am \(60%\)\s+. umbrella, icy sidewalks, feels like -15.') 'freezing rain and a wind chill'
        Assert-True ($text -match 'Sat Nov 7 .*gusts to 70 km/h') 'wind'
        Assert-True ($text -match 'now\s+4. cloudy, feels 0.') 'now, with how it feels'
        $week = @(& { Show-JkDueWeek } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($week -match "12$($script:JkDeg)/0$($script:JkDeg) rain\s+12$($script:JkDeg)/0$($script:JkDeg) cloudy\s+10$($script:JkDeg)/-2$($script:JkDeg) snow\s+12$($script:JkDeg)/-2$($script:JkDeg) ice") "week grid: the forecast under its days: $week"

        # the dashboard's line, the morning popup, an exam in the rain
        $l = Get-JkWeatherLine $w ([datetime]'2026-11-03T08:00')
        Assert-Eq "$($l.Now) | $($l.Wet) | $($l.Next)" "4$($script:JkDeg) cloudy, feels 0$($script:JkDeg) | rain 2$($script:G.dash)6 pm (80%) | high 12$($script:JkDeg)"
        $l = Get-JkWeatherLine $w ([datetime]'2026-11-05T20:00')
        Assert-True ($l.Wet -match '^snow 9 pm.3 am \(70%, 6 cm\)$' -and $l.Next -match '^tomorrow 12. / -2.$') "evening: $($l.Wet) | $($l.Next)"
        Assert-True ((Get-JkMorningWeather ([datetime]'2026-11-03T08:00')) -match '^Weather: 4. now, high 12.; rain 2.6 pm \(80%\) . umbrella$') 'morning popup line'
        Assert-True ((Get-JkExamWeather ([datetime]'2026-11-03T16:30')) -match '^8., rain at 4:30 pm; rain around then \(80%\), take an umbrella$') "exam: $(Get-JkExamWeather ([datetime]'2026-11-03T16:30'))"
        Assert-True ((Get-JkDashWeather ([datetime]'2026-11-03T08:00')) -match 'rain 2.6 pm') 'dashboard line from the kept forecast'
        # the "starts in 2h" alert of an exam says what it will be like on the way there
        $d = Get-JkDueData
        $c = Resolve-JkCourse $d 'cs350' -Create
        $null = New-JkEvent -Data $d -Course $c.key -Date ([datetime]'2026-11-03') -Time '16:30' -Title 'Midterm' -Kind 'exam'
        Save-JkDueData $d
        $ev = @((Get-JkDueData).events | Where-Object { $_.title -eq 'Midterm' })[0]
        $env:JK_NOW = '2026-11-03T14:30:00'
        $origN = ${function:Show-JkNotify}
        try {
            function script:Show-JkNotify { param([string]$Title, [string[]]$Lines, $Accent, [int]$Seconds) $script:WxShown = $Lines -join ' | '; 'stub' }
            $r = New-JkReminder -At ([datetime]'2026-11-03T14:30') -Text 'CS 350 Midterm' -Key "due:$($ev.id):2026-11-03" -DueId ([int]$ev.id)
            Complete-JkReminder -Id $r.id
            Assert-True ($script:WxShown -match 'Weather: 8., rain at 4:30 pm; rain around then \(80%\), take an umbrella') "exam alert: $script:WxShown"
        } finally { Set-Item function:script:Show-JkNotify $origN; $env:JK_NOW = '2026-11-03T08:00:00' }

        # bad weather is reason enough for the morning popup on a quiet day; ordinary weather is not
        Assert-Eq (Get-JkMorningWarning ([datetime]'2026-11-06T06:00')) "Freezing rain 7$($script:G.dash)8 am: icy sidewalks" 'freezing rain'
        Assert-Eq (Get-JkMorningWarning ([datetime]'2026-11-05T06:00')) '' '3 cm of snow is not a warning (5 is)'
        Assert-Eq (Get-JkWeatherWarning ([pscustomobject]@{ Spells = @(); Coldest = -24.4; Gust = 20 })) "Feels like -24$($script:JkDeg) today: bundle up" 'a bitter wind chill'
        Assert-Eq (Get-JkWeatherWarning ([pscustomobject]@{ Spells = @([pscustomobject]@{ Kind = 'snow'; Start = [datetime]'2026-12-01T21:00'; End = [datetime]'2026-12-02T03:00'; Cm = 8.4; Mm = 6 }); Coldest = -5; Gust = 20 })) '8 cm of snow from 9 pm: boots' 'deep snow'
        $origN = ${function:Show-JkNotify}
        try {
            $script:WxTitle = $null
            function script:Show-JkNotify { param([string]$Title, [string[]]$Lines, $Accent, [int]$Seconds) $script:WxTitle = $Title; $script:WxLines = $Lines -join ' | '; 'stub' }
            $env:JK_NOW = '2026-11-06T06:00:00'
            Invoke-JkDueRemind -Force -Quiet
            Assert-Eq $script:WxTitle "Freezing rain 7$($script:G.dash)8 am: icy sidewalks" 'the warning opens a quiet morning'
            Assert-True ($script:WxLines -match 'Weather: .*freezing rain 7.8 am') "with the day's weather: $script:WxLines"
            $script:WxTitle = $null
            $env:JK_NOW = '2026-11-04T06:00:00'
            Invoke-JkDueRemind -Force -Quiet
            Assert-True ($null -eq $script:WxTitle) 'an ordinary day with nothing due stays quiet'
        } finally { Set-Item function:script:Show-JkNotify $origN; $env:JK_NOW = '2026-11-03T08:00:00' }

        # an older forecast: read up to two days on, marked stale; a failed refresh says why
        $wf = Join-Path (Get-JkCacheDir) 'weather.txt'
        $body = [IO.File]::ReadAllText($wf); $bar = $body.IndexOf('|')
        $age = { param([double]$h) [IO.File]::WriteAllText($wf, [DateTime]::UtcNow.AddHours(-$h).ToString('o', $script:Inv) + $body.Substring($bar)) }
        & $age 30
        $w30 = Get-JkWeather -CacheOnly
        Assert-True ($w30 -and $w30.Stale) 'a day and a half old: still read, marked stale'
        & $age 60
        Assert-True ($null -eq (Get-JkWeather -CacheOnly)) 'older than two days: not used'
        & $age 30
        $fixtureGet = ${function:Invoke-JkWeatherGet}
        $env:JK_NOW = ''
        try {
            function script:Invoke-JkWeatherGet { param([string]$Url, [int]$TimeoutSec = 6) throw 'The remote name could not be resolved' }
            Assert-True ((Get-JkWeather -MaxAgeHours 0).Stale) 'offline: the kept one'
            Assert-True ([IO.File]::ReadAllText((Join-Path (Get-JkCacheDir) 'weather.error')) -match 'could not be resolved') 'the failure is noted'
            $off = @(& { jk weather } 6>&1 | ForEach-Object { "$_" }) -join "`n"
            Assert-True ($off -match 'offline: forecast from' -and $off -match 'could not refresh: .*could not be resolved') "jk weather says why: $off"
        } finally { Set-Item function:script:Invoke-JkWeatherGet $fixtureGet; $env:JK_NOW = '2026-11-03T08:00:00' }
        $null = Get-JkWeather -MaxAgeHours 0
        Assert-True (-not (Test-Path -LiteralPath (Join-Path (Get-JkCacheDir) 'weather.error'))) 'a good fetch clears the note'
        # the brief speaks up only for rain, snow or a bitter wind chill in the next 12 hours
        Assert-Eq (Get-JkBriefWeather ([datetime]'2026-11-03T08:00')) "rain 2$($script:G.dash)6 pm" 'brief: rain today'
        Assert-Eq (Get-JkBriefWeather ([datetime]'2026-11-05T20:00')) "snow 9 pm$($script:G.dash)3 am" 'brief: snow tonight'
        Assert-Eq (Get-JkBriefWeather ([datetime]'2026-11-06T05:00')) "freezing rain 7$($script:G.dash)8 am" 'brief: an hour of freezing rain'
        Assert-Eq (Get-JkBriefWeather ([datetime]'2026-11-06T08:00')) "feels -15$($script:JkDeg)" 'brief: the wind chill'
        Assert-Eq (Get-JkBriefWeather ([datetime]'2026-11-04T08:00')) '' 'brief: nothing on a dry, mild day'
        $env:JK_NOW = '2026-11-03T08:00:00'
        $brief = (Get-JkBriefLine) -replace "$([char]27)\[[0-9;]*m", ''
        Assert-True ($brief -match "rain 2.6 pm") "in the brief line: $brief"

        # another zone reads on its own clock
        $far = ConvertFrom-JkWeatherJson ($script:WxFixture.Substring(0, $script:WxFixture.Length - 1) + ',"utc_offset_seconds":' + [int]([TimeZoneInfo]::Local.GetUtcOffset([datetime]'2026-11-03').TotalSeconds + 10800) + '}') $script:JkWeatherHome ([DateTime]::UtcNow)
        Assert-Eq $far.Offset.TotalSeconds ([TimeZoneInfo]::Local.GetUtcOffset([datetime]'2026-11-03').TotalSeconds + 10800) 'offset kept'
        Assert-Eq (ConvertTo-JkWeatherClock $far ([datetime]'2026-11-03T08:00')).ToString('HH:mm') '11:00' 'three hours ahead'

        # places: london, on (the comma lost to PowerShell) is the Ontario one; numbers stay invariant
        $p = Resolve-JkWeatherPlace 'london on'
        Assert-Eq "$($p.Name) $($p.Lat)" 'London, ON 42.9834' 'the region from the last word'
        $n = $script:WxCalls.Count; $null = Resolve-JkWeatherPlace 'London On'
        Assert-Eq $script:WxCalls.Count $n 'looked up once'
        Set-JkConfig 'weather.place' 'London, ON (42.9834, -81.233)'
        Assert-True ((Get-JkWeatherUrl (Get-JkWeatherPlace)) -match 'latitude=42\.9834&longitude=-81\.233&') 'a set place, in invariant numbers'
        $script:WxBg = $null
        $null = Get-JkDashWeather ([datetime]'2026-11-03T08:00')
        $env:JK_NOW = ''
        $null = Get-JkDashWeather ([datetime]'2026-11-03T08:00')
        $env:JK_NOW = '2026-11-03T08:00:00'
        Assert-True ($null -eq $script:WxBg) 'no background fetch in tests (JK_NONINTERACTIVE) or under a pinned clock'
        jk weather off
        Assert-True ($null -eq (Get-JkWeatherPlace)) 'off'
        Assert-Eq (Get-JkDashWeather ([datetime]'2026-11-03T08:00')) '' 'nothing on the dashboard when off'
    } finally {
        Set-Item function:script:Invoke-JkWeatherGet $orig
        Set-Item function:script:Start-JkBackground $origBg
        $files | ForEach-Object { Remove-Item -LiteralPath $_ -ErrorAction SilentlyContinue }
        $env:JK_NOW = $savedNow; $env:JK_HOME = $saved; $script:JkConfigCache = $null
    }
}
Test 'jk net: Wi-Fi details in any language, and one verdict per kind of failure' {
    $en = @('    Name                   : Wi-Fi', '    SSID                   : eduroam', '    BSSID                  : aa:bb', '    Radio type             : 802.11ax', '    Band                   : 5 GHz', '    Signal                 : 65% ')
    $w = ConvertFrom-JkWlanText $en
    Assert-Eq "$($w.Ssid)|$($w.Signal)|$($w.Band)" 'eduroam|65|5 GHz'
    $zhSignal = [string][char]0x4FE1 + [char]0x53F7   # the Chinese label, built so this file stays ASCII
    Assert-Eq (ConvertFrom-JkWlanText @('    SSID                   : Home', "    $zhSignal                   : 31%")).Signal 31 'signal found by its percent sign'
    Assert-Eq (ConvertFrom-JkWlanText @('There is no wireless interface on the system.')) $null
    $ping = { param($sent, $got, $ms) [pscustomobject]@{ Ok = $got -gt 0; Sent = $sent; Got = $got; Ms = $ms } }
    $ok = [pscustomobject]@{ Ok = $true; Ms = 20; Captive = $false }
    $fail = [pscustomobject]@{ Ok = $false; Ms = $null; Captive = $false }
    $link = [pscustomobject]@{ Name = 'Wi-Fi'; Address = '10.0.0.5'; Apipa = $false; Gateway = '10.0.0.1'; Wireless = $true }
    $wifi = [pscustomobject]@{ Ssid = 'eduroam'; Signal = 70 }
    $mk = { param($l, $wf, $gw, $inet, $dns, $web) [pscustomobject]@{ Link = $l; Wifi = $wf; Vpn = $null; Gateway = $gw; Internet = $inet; Dns = $dns; Web = $web } }
    $cases = @(
        @((& $mk $null $null (& $ping 0 0 $null) (& $ping 0 0 $null) $fail $fail), 'bad', '^Not connected'),
        @((& $mk ([pscustomobject]@{ Name = 'Wi-Fi'; Address = '169.254.3.4'; Apipa = $true; Gateway = $null }) $wifi (& $ping 0 0 $null) (& $ping 0 0 $null) $fail $fail), 'bad', "Joined 'eduroam', but the router handed out no address"),
        @((& $mk $link $wifi (& $ping 3 3 4) (& $ping 2 2 9) $ok $ok), 'ok', '^Online: router 4 ms . internet 9 ms$'),
        @((& $mk $link $wifi (& $ping 3 0 $null) (& $ping 2 0 $null) $ok $ok), 'ok', '^Online$'),
        @((& $mk $link ([pscustomobject]@{ Ssid = 'x'; Signal = 30 }) (& $ping 3 2 90) (& $ping 2 2 30) $ok $ok), 'warn', 'weak \(signal 30%, 1 of 3 router pings lost, router 90 ms\)'),
        @((& $mk $link $wifi (& $ping 3 3 4) (& $ping 2 0 $null) $ok ([pscustomobject]@{ Ok = $false; Ms = 30; Captive = $true })), 'warn', 'sign-in page'),
        @((& $mk $link $wifi (& $ping 3 3 4) (& $ping 2 2 9) $fail $fail), 'bad', '^DNS is failing'),
        @((& $mk $link $wifi (& $ping 3 3 4) (& $ping 2 2 9) $ok $fail), 'warn', 'web requests fail'),
        @((& $mk $link $wifi (& $ping 3 3 4) (& $ping 2 0 $null) $fail $fail), 'bad', 'router answers, but nothing past it'),
        @((& $mk $link ([pscustomobject]@{ Ssid = 'x'; Signal = 20 }) (& $ping 3 0 $null) (& $ping 2 0 $null) $fail $fail), 'bad', 'router does not answer \(signal 20%\)')
    )
    foreach ($c in $cases) {
        $v = Get-JkNetVerdict $c[0]
        Assert-Eq $v.Level $c[1] $v.Text
        Assert-True ($v.Text -match $c[2]) "verdict: $($v.Text)"
        Assert-True ($v.Level -eq 'ok' -or $v.Hint) "a problem comes with something to try: $($v.Text)"
    }
    $null = @(Get-JkNetLinks)   # the real adapters read without errors
}
Test 'jk net speed: the Cloudflare site from cf-ray, and what the numbers are good for' {
    Assert-Eq (Get-JkCfColo 'a53720f2dac3ab3c-YYZ') 'YYZ'
    Assert-Eq (Get-JkCfColo '') ''
    $v = { param($d, $u, $l) $r = Get-JkSpeedVerdict $d $u $l; "$($r.Level): $($r.Text)" }
    Assert-True ((& $v 283 180 31) -match '^ok: Fast') 'fast'
    Assert-True ((& $v 12 8 30) -match '^ok: Fine for HD video') 'HD'
    Assert-True ((& $v 4 3 30) -match '^warn: Enough for pages') 'slow-ish download is a warning'
    Assert-True ((& $v 50 2 30) -match '^warn: .*video calls may stutter') 'weak upload'
    Assert-True ((& $v 50 1 30) -match 'too slow for video calls') 'very weak upload'
    Assert-True ((& $v 50 20 220) -match '^warn: .*high latency \(220 ms\)') 'latency'
    Assert-True ((& $v 1 1 30) -match '^bad: Very slow') 'very slow'
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
    for ($run = 2; $run -le [Math]::Ceiling($n / 3) + 1 -and $shown -lt $n; $run++) {
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
        # a week later, both classes back, woken at 9:55: the 10:00 class still gets "starts in 5m"
        Save-JkClassData ([pscustomobject]@{ nextId = 3; items = @((& $mkc 1 'cs350' '10:00' '11:20' 'MC 4040'), (& $mkc 2 'health' '13:00' '14:20' 'online')) })
        $late = Register-JkClassAlert -Now ([datetime]'2026-10-29T09:55')
        Assert-Eq $late.at '2026-10-29T09:55:30' 'inside the lead time: alert now'
        $rd = Get-JkReminderData; $rd.items = @(); Set-JkProp $rd 'alerted' @(); Save-JkReminderData $rd
        # woken at 9:58: too close to help, so the chain moves on to the 1 pm class
        $late = Register-JkClassAlert -Now ([datetime]'2026-10-29T09:58')
        Assert-Eq $late.at '2026-10-29T12:50:00' 'under three minutes: the next class instead'
        $rd = Get-JkReminderData; $rd.items = @(); Set-JkProp $rd 'alerted' @(); Save-JkReminderData $rd
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
Test 'jobs search: whole words, spelling variants, near misses, a misread date, subcommand words' {
    $md = Join-Path $env:JK_HOME 'tracker-search.md'
    $e = [string][char]0xE9
    [IO.File]::WriteAllLines($md, @(
            '| Date | Company | Role | Location / term | Status | Link |', '|---|---|---|---|---|---|',
            '| 2026-09-20 | AMD | Software Engineering Intern/Co-op | Markham, Winter 2027 | Submitted successfully via AMD Canada iCIMS | |',
            '| 2026-09-21 | AMD | Graphics Intern/Co-op | Markham | Submitted successfully via AMD iCIMS | |',
            '| 2026-09-22 | NVIDIA | Developer Technology Intern | Toronto | Submitted via Workday | |',
            '| 2026-09-23 | Jane Street | Software Engineer Internship | New York | Submitted via Greenhouse | |',
            '| 2026-09-24 | Tower Research Capital | Software Developer Intern | New York | Submitted via Greenhouse | |',
            "| 2026-09-25 | Soci${e}t${e} G${e}n${e}rale | Quant Intern | Montr${e}al | Submitted via Workday | |",
            '| 2026-09-26 | OpenText | Software Developer Co-op | Waterloo | Submitted via WaterlooWorks | |',
            '| 2026-09-27 | Huawei Canada | Software Intern | Ottawa | Submitted via Workday | |',
            '| 2026-09-27 | RTX / Pratt & Whitney Canada | Software Intern | Longueuil | Submitted via Workday | |',
            '| 2026-09-27 | Amazon Development Centre Canada ULC | SDE Intern | Toronto | Submitted via Amazon Jobs | |',
            '| 2026-02-30 | Typo Corp | Intern | Remote | Submitted via Lever | |'), (New-Object Text.UTF8Encoding $false))
    Set-JkConfig 'jobs.file' $md
    function script:Invoke-Item { Say 'OPENED THE TRACKER' }
    try {
        $find = { param($q) (Find-JkJobs $q 6>&1 | ForEach-Object { "$_" }) -join "`n" }
        $rows = @(Get-JkJobs)
        Assert-Eq $rows.Count 10 'a row with no such date is left out, and the rest still read'
        Assert-True ((& $find 'ea') -match '0 rows') 'a short word matches whole words: "ea" is not inside "research"'
        Assert-True ((& $find 'coop') -match '3 rows') 'co-op found as coop'
        Assert-True ((& $find 'janestreet') -match '1 row') 'a name typed run together'
        Assert-True ((& $find 'societe generale') -match '1 row') 'accents ignored'
        Assert-True ((& $find 'intern markham') -match '2 rows') 'the start of a word still finds it'
        $near = & $find 'amd canada'
        Assert-True ($near -notmatch 'Not in the tracker' -and $near -match 'AMD\s+2 rows, 2 applied' -and $near -notmatch 'Huawei') "the company alone matched: $near"
        Assert-True ((& $find 'ubisoft canada') -match 'Not in the tracker') 'a word in many names (canada) names none of them'
        Assert-True ((& $find 'pratt toronto') -match 'RTX / Pratt') 'a rarer word inside a name still does'
        $typo = & $find 'nvdia'
        Assert-True ($typo -notmatch 'Not in the tracker' -and $typo -match 'NVIDIA\s+1 row, 1 applied') "one typo away: $typo"
        Assert-True ((& $find 'ubisoft') -match 'Not in the tracker') 'truly absent still says so'
        $open = (Invoke-JkJobs open text 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($open -notmatch 'OPENED' -and $open -match 'OpenText') "two words starting with a subcommand are a search: $open"
        $sum = (Show-JkJobs 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($sum -match '1 row not read: line 13, no such date 2026-02-30 \(Typo Corp\)') "the summary names the row it skipped: $sum"
    } finally { Remove-Item function:script:Invoke-Item -ErrorAction SilentlyContinue; Invoke-JkConfig reset jobs.file }
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
Test 'jk plan week html: the week as a page, a box per study block, titles escaped, and the terminal checklist unchanged' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH
    $env:JK_HOME = Join-Path $saved 'week-html'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $env:JK_NOW = '2026-11-13T10:00:00'; $env:JK_WIDTH = '120'
        $d = Get-JkDueData; $a = Resolve-JkCourse $d 'cs341' -Create; $o = Resolve-JkCourse $d 'co367' -Create
        $null = New-JkEvent -Data $d -Course $a.key -Date ([datetime]'2026-11-16') -Time '23:59' -Title 'A3 <graphs> & flows' -Weight '4%'
        $null = New-JkEvent -Data $d -Course $o.key -Date ([datetime]'2026-11-19') -Time '19:00' -Title 'Quiz 3' -Kind 'exam' -Weight '20%'
        Save-JkDueData $d
        $days = @(Get-JkPlanWeekDays)
        $blocks = 0; foreach ($x in $days) { $blocks += @($x.Blocks).Count }
        Assert-Eq $days.Count 7 'seven days'
        $f = Join-Path $env:JK_HOME 'week.html'
        Export-JkPlanWeekHtml -Out $f -NoOpen 6>&1 | Out-Null
        $h = [IO.File]::ReadAllText($f)
        Assert-Eq ([regex]::Matches($h, '<input type="checkbox"').Count) $blocks "a box per block ($blocks)"
        Assert-True ($h -match 'data-id="2026-11-13\|cs341\|#\d+"') 'each box keyed by day and item'
        Assert-True ($h -match 'A3 &lt;graphs&gt; &amp; flows' -and $h -notmatch '<graphs>') 'titles escaped'
        Assert-True ($h -match 'exam 7:00 pm' -and $h -match 'Thursday, Nov 19') 'what is written that day'
        # jk plan week html goes to the page; plain jk plan week is the checklist as before
        $t = (Show-JkPlanWeek 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($t -match 'Fri Nov 13\s+today' -and $t -match 'jk plan week html to tick off') "terminal: $t"
        $null = Invoke-JkPlan week html 6>&1
        Assert-True (Test-Path -LiteralPath (Get-JkPath 'plan-week.html')) 'jk plan week html writes ~\.jk\plan-week.html (not opened in a sandbox)'
        # the morning run makes it today's week, once it exists
        $env:JK_NOW = '2026-11-14T08:00:00'
        # every other step stubbed: a test never runs a real tick
        $stubs = 'Restore-JkReminders', 'Sync-JkBackupMirror', 'Restore-JkFocusTimer', 'Register-JkTodayAlerts', 'Register-JkClassAlert', 'Register-JkStocksAlert', 'Update-JkDiskLog', 'Invoke-JkDueRemind', 'Limit-JkBackgroundLog', 'Start-JkBackground', 'Invoke-JkDueSync', 'Get-JkWeather'
        $orig = @{}; foreach ($fn in $stubs) { $orig[$fn] = (Get-Item "function:$fn").ScriptBlock; Set-Item "function:script:$fn" { } }
        try { Invoke-JkTick 6>&1 | Out-Null } finally { foreach ($fn in $stubs) { Set-Item "function:script:$fn" $orig[$fn] } }
        $h2 = [IO.File]::ReadAllText((Get-JkPath 'plan-week.html'))
        Assert-True ($h2 -match 'Sat Nov 14 - Fri Nov 20' -and $h2 -notmatch 'Friday, Nov 13') 'refreshed by the morning run'
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'jk plan: an exam day holds only the time before the exam, and the days before take the rest' {
    $mk = { param($k, $due, $eff) [pscustomobject]@{ Key = $k; Course = 'x'; Title = $k; Due = [datetime]$due; Weight = 40; Kind = 'exam'; Id = 0; Effort = $eff; Done = 0.0 } }
    $sum = { param($sched, $k) $t = 0; foreach ($s in $sched) { $t += [double]$s.Alloc[$k] }; $t }
    # a 12:30 pm final, 10 hours of prep, 6-hour days from Tuesday
    $sched = @(Get-JkPlanSchedule -Items @(& $mk 'noon' '2026-12-12T12:30' 600) -Now ([datetime]'2026-12-08T09:00') -Days 5 -BudgetMin 360)
    $day = $sched[4].Alloc['noon']; $eve = $sched[3].Alloc['noon']
    Assert-True ($day -le 150) "the morning of a 12:30 exam: 9 to 11:30 at most, got $day"
    Assert-True ($eve -gt $day) "the day before takes more: $eve vs $day"
    Assert-True ((& $sum $sched 'noon') -ge 575) "all of it still planned: $(& $sum $sched 'noon')"
    # a 7:30 pm final keeps a whole day; an 11:59 pm deadline too
    $late = @(Get-JkPlanSchedule -Items @(& $mk 'eve' '2026-12-12T19:30' 600) -Now ([datetime]'2026-12-08T09:00') -Days 5 -BudgetMin 360)
    Assert-True ($late[4].Alloc['eve'] -ge 100) "an evening exam's day is a study day like the others: $($late[4].Alloc['eve'])"
}
Test 'jk focus add logs time worked without the timer: jk plan counts it, yesterday ends at 10 pm, no course says so, jk focus undo takes it back' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH
    $env:JK_HOME = Join-Path $saved 'focus-add'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $env:JK_NOW = '2026-11-13T15:00:00'; $env:JK_WIDTH = '100'
        $d = Get-JkDueData; $a = Resolve-JkCourse $d 'cs341' -Create
        $null = New-JkEvent -Data $d -Course $a.key -Date ([datetime]'2026-11-13') -Time '23:59' -Title 'Assignment 4' -Weight '10%'
        Save-JkDueData $d
        $say = { param([scriptblock]$Run) (@(& $Run 6>&1 | ForEach-Object { "$_" }) -join "`n") }
        # nothing on the timer yet: jk plan says how to count time studied without it
        $plan = & $say { Show-JkPlan }
        Assert-True ($plan -match 'no timer\? jk plan did 1h cs341') "the hint: $plan"
        $before = @(Get-JkPlanItems -Now (Get-JkNow))[0].Done
        $out = & $say { Invoke-JkFocus add 1h30m cs341 a4 }
        Assert-True ($out -match 'Logged 1h 30m on CS 341 a4' -and $out -match 'focused today 1h 30m') "the line: $out"
        # the 1h 30m is part of today's plan, not taken off it: 2h 55m planned today (the 3-hour day,
        # its last day), 1h 25m of it to go - not "covered" by a plan shrunk to the rest of the day
        Assert-True ($out -match 'CS 341 in today''s plan: 1h 25m to go') "today's plan: $out"
        $bar = @((& $say { Show-JkPlan }) -split "`n" | Where-Object { $_ -match '1h 30m of 2h 55m focused today' })
        Assert-Eq $bar.Count 1 'the plan counts it as done today'
        # the bar is about half full ([Math]::Min(1, 0.51) once rounded it to a full or an empty bar)
        $full = ($bar[0].ToCharArray() | Where-Object { "$_" -eq $script:G.full }).Count
        Assert-True ($full -ge 14 -and $full -le 16) "1h 30m of 2h 55m: $full of 30 blocks full"
        $s = @((Get-JkFocusData).sessions)
        Assert-Eq "$($s.Count) $($s[0].start) $($s[0].actual) $($s[0].added)" '1 2026-11-13T13:30:00 90 True' 'a session that ends now'
        $after = @(Get-JkPlanItems -Now (Get-JkNow))[0].Done
        Assert-Eq ($after - $before) 90 'jk plan counts it'
        Assert-True ((& $say { Show-JkPlan }) -notmatch 'no timer\?') 'no hint once time is logged'
        # jk plan did, "2 hours", "on", yesterday
        $out = & $say { Invoke-JkPlan did 2 hours on cs341 yesterday }
        $s = @((Get-JkFocusData).sessions)
        Assert-Eq "$($s[1].label) $($s[1].start) $($s[1].actual)" 'cs341 2026-11-12T20:00:00 120' 'yesterday: ending at 10 pm the day before'
        Assert-True ($out -match 'focused yesterday 2h 00m' -and $out -match 'toward CS 341') "yesterday's line: $out"
        # a label with no course is logged, with word that jk plan cannot count it
        $out = & $say { Invoke-JkFocus add 20m reading }
        Assert-True ($out -match 'Logged 20m on reading' -and $out -match 'No course in the label.*jk focus add 20m cs350') "no course: $out"
        # undo takes back the newest
        $out = & $say { Invoke-JkFocus undo }
        Assert-True ($out -match 'Taken back 20m on reading') "undo: $out"
        Assert-Eq (@((Get-JkFocusData).sessions).Count) 2 'two left'
        # too long, too short, nothing
        foreach ($case in @(@(@('13h', 'x'), 'more than 12 hours'), @(@('30s', 'x'), 'a minute or more'), @(@(), 'usage: jk focus add'))) {
            $e = ''; $argv = @($case[0])
            try { Add-JkFocusLog @argv } catch { $e = "$_" }
            Assert-True ($e -match $case[1]) "jk focus add $($argv -join ' '): $e"
        }
        Assert-Eq (@((Get-JkFocusData).sessions).Count) 2 'nothing logged by a refusal'
    } finally { $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $script:JkConfigCache = $null; $script:JkDueCache = $null }
}
Test 'jk stocks: the watchlist, a range for the close from the last 20 days, how often such ranges held and the trend called the next day, and a popup at the US open' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH; $savedCache = $env:JK_CACHE
    $env:JK_HOME = Join-Path $saved 'stocks-home'; $env:JK_CACHE = Join-Path $saved 'stocks-cache'; $script:JkConfigCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME, $env:JK_CACHE | Out-Null
    $origBg = ${function:Start-JkBackground}; $origNotify = ${function:Show-JkNotify}
    try {
        function script:Start-JkBackground { param([string]$Script, [hashtable]$Env = @{}, [string]$WaitUntil) [pscustomobject]@{ Id = 0; StartTime = (Get-Date) } }
        $script:Shown = @()
        function script:Show-JkNotify { param([string]$Title, [string[]]$Lines, $Accent, [int]$Seconds, [switch]$Sound, [switch]$Wait) $script:Shown += , ($Title + ' | ' + ($Lines -join ' | ')); 'stub' }
        $ny = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
        $unix = { param([datetime]$nyTime) [DateTimeOffset]::new([TimeZoneInfo]::ConvertTimeToUtc([datetime]::SpecifyKind($nyTime, 'Unspecified'), $ny)).ToUnixTimeSeconds() }
        # 141 weekdays of closes up to $last, moving +1% and -1% in turn (so a typical day is 1.03%:
        # every day lands in its range, and "above its average" always calls the next day wrong);
        # Yahoo names the session of $session, and -Live adds today's bar at $price
        $seed = {
            param([string]$sym, [datetime]$last, [datetime]$session, [double]$price = 0, [string]$exch = 'NYSEArca', [string]$cur = 'USD', $liveDay = $null)
            $days = @(); $d = $last
            while ($days.Count -lt 141) { if ($d.DayOfWeek -notin 'Saturday', 'Sunday') { $days = @($d) + $days }; $d = $d.AddDays(-1) }
            $closes = @(); $c = 100.0
            for ($i = 0; $i -lt 141; $i++) { if ($i) { $c = $c * [Math]::Exp($(if ($i % 2) { 0.01 } else { -0.01 })) }; $closes += [Math]::Round($c, 4) }
            $ts = @($days | ForEach-Object { & $unix $_.AddHours(9.5) })
            if ($price) { $ts += & $unix $(if ($liveDay) { ([datetime]$liveDay).AddHours(11) } else { $session.AddHours(11) }); $closes += $price }
            $p = $(if ($price) { $price } else { $closes[-1] })
            $j = [ordered]@{ chart = [ordered]@{ result = @([ordered]@{
                            meta = [ordered]@{ currency = $cur; symbol = $sym; fullExchangeName = $exch; longName = "$sym Fund"; regularMarketPrice = $p; regularMarketTime = $ts[-1]; fiftyTwoWeekHigh = 120.0; fiftyTwoWeekLow = 90.0
                                currentTradingPeriod = [ordered]@{ regular = [ordered]@{ start = (& $unix $session.AddHours(9.5)); end = (& $unix $session.AddHours(16)) } } }
                            timestamp = $ts; indicators = [ordered]@{ quote = @([ordered]@{ close = $closes }) } }); error = $null } }
            Write-JkText (Get-JkStockCachePath $sym) ((Get-Date).ToUniversalTime().ToString('o') + "`n" + (ConvertTo-Json $j -Depth 10 -Compress))
            $closes
        }
        $say = { param([scriptblock]$Run) @(& $Run 6>&1 | ForEach-Object { "$_" }) }
        # New York's wall clock on this machine's (the check also runs in UTC and Pacific time)
        $here = { param([string]$nyText) [TimeZoneInfo]::ConvertTime([datetime]::Parse($nyText, $script:Inv), $ny, [TimeZoneInfo]::Local) }
        $hm = { param([string]$nyText) Format-JkTime (& $here $nyText).ToString('HH:mm') }
        $env:JK_WIDTH = '120'
        Assert-Eq ((Get-JkStockList) -join ',') 'SPY,QQQ' 'a watchlist to start from'
        # Wednesday before the open: the range for the next close, the record
        $wed = [datetime]'2026-11-25'
        $cl = & $seed 'SPY' $wed.AddDays(-1) $wed
        $null = & $seed 'QQQ' $wed.AddDays(-1) $wed
        $env:JK_NOW = (& $here '2026-11-25T08:00:00').ToString('s')
        $txt = (& $say { Invoke-JkStocks }) -join "`n"
        $sig = [Math]::Sqrt(20.0 / 19) * 0.01
        $lo = Format-JkPrice ($cl[-1] * [Math]::Exp(-$sig)); $hi = Format-JkPrice ($cl[-1] * [Math]::Exp($sig))
        Assert-True ($txt -match "US market opens at $(& $hm '2026-11-25T09:30')") "before the open: $txt"
        Assert-True ($txt -match "SPY\s+$([regex]::Escape((Format-JkPrice $cl[-1])))\s+$([regex]::Escape((Format-JkStockPct ($cl[-1] / $cl[-2] - 1) 2)))" -and $txt -match "next close likely $lo - $hi \(.1\.0%, 2 days in 3\)") "the row and its range ($lo - $hi): $txt"
        Assert-True ($txt -match 'held on 100% of the last 120 days' -and $txt -match 'called the next day 0% of the time \(a coin: 50%; up days: 50%\): worse than a coin') "the record: $txt"
        Assert-True ($txt -match 'From past prices only, not advice') 'says what it is'
        # one on a screen: the ranges, the trend's record, the last ten days each inside its range
        $txt = (& $say { Invoke-JkStocks spy }) -join "`n"
        Assert-True ($txt -match 'SPY  SPY Fund' -and $txt -match 'ranges held\s+100% of the last 120 days' -and $txt -match 'called the next day 0% of 120 days') "jk stocks spy: $txt"
        Assert-Eq ([regex]::Matches($txt, "$([char]0x2713)").Count) 10 'the last 10 days, each inside its range'
        # 11 am, trading 5% up: outside the range so far; the popup at the open says the same
        $null = & $seed 'SPY' $wed.AddDays(-1) $wed ([Math]::Round($cl[-1] * 1.05, 2))
        $env:JK_NOW = (& $here '2026-11-25T11:00:00').ToString('s')
        $txt = (& $say { Invoke-JkStocks }) -join "`n"
        Assert-True ($txt -match "US market open until $(& $hm '2026-11-25T16:00')" -and $txt -match 'SPY\s+\S+\s+\+5\.00%' -and $txt -match 'above it so far') "while it trades: $txt"
        $p = Get-JkStocksPopup -Tries 1
        Assert-True ($p.Title -match '^Stocks at the open . Wed Nov 25' -and $p.Lines[0] -match "^SPY \S+ \+5\.00% . close likely $lo-$hi" -and ($p.Lines -join ' | ') -match 'Ranges held 100% of the last 120 days') "popup: $($p.Title) | $($p.Lines -join ' | ')"
        # Yahoo still naming yesterday's session while today trades: today's price says it is on
        $null = & $seed 'QQQ' $wed.AddDays(-1) $wed.AddDays(-1) 105 'NasdaqGS' 'USD' $wed
        $q = Get-JkStock 'QQQ'
        Assert-Eq "$(Get-JkStockState $q (& $here '2026-11-25T11:30:00')) $($q.Open.ToString('s'))" 'open 2026-11-25T09:30:00' 'a lagging session'
        $null = & $seed 'QQQ' $wed.AddDays(-1) $wed
        # the timer: 40 s into the US open on a weekday, once a day; none at the weekend, after the
        # close, or when switched off; stocks.time moves it
        $env:JK_NOW = (& $here '2026-11-25T07:45:00').ToString('s')
        $r = Register-JkStocksAlert -Now ([datetime]::Parse($env:JK_NOW, $script:Inv))
        $want = (& $here '2026-11-25T09:30:40').ToString('s')
        Assert-Eq "$($r.at) $($r.key)" "$want stocks:2026-11-25" 'at the open'
        Assert-True ($null -eq (Register-JkStocksAlert -Now (& $here '2026-11-25T08:10:00'))) 'once a day (the sign-in run sets no second)'
        Assert-True ($null -eq (Register-JkStocksAlert -Now (& $here '2026-11-28T07:45:00'))) 'not on a Saturday'
        Assert-True ($null -eq (Register-JkStocksAlert -Now (& $here '2026-11-27T18:00:00'))) 'not after the close'
        $r2 = Register-JkStocksAlert -Now (& $here '2026-11-27T10:15:00')
        Assert-Eq $r2.at (& $here '2026-11-27T10:16:00').ToString('s') 'woken after the open: a minute later'
        Set-JkConfig 'stocks.time' '9:45'
        Assert-Eq (Get-JkStocksAlertTime ([datetime]'2026-12-01')).ToString('s') '2026-12-01T09:45:00' 'stocks.time moves it'
        $null = & $say { Invoke-JkStocks popup off }
        Assert-True ($null -eq (Register-JkStocksAlert -Now (& $here '2026-12-01T07:45:00'))) 'off'
        $null = & $say { Invoke-JkStocks popup on }
        Assert-Eq (Get-JkConfig 'stocks.time') '' 'on: back to the open'
        # it fires on its day with the prices; one left from another day stays quiet
        $env:JK_NOW = (& $here '2026-11-25T09:30:40').ToString('s')
        Complete-JkReminder -Id ([int]$r.id)
        Assert-True ($script:Shown.Count -eq 1 -and $script:Shown[0] -match '^Stocks at the open . Wed Nov 25 \| SPY ') "fired: $($script:Shown -join ' // ')"
        $env:JK_NOW = (& $here '2026-11-28T09:30:40').ToString('s')
        Complete-JkReminder -Id ([int]$r2.id) -Missed
        Assert-Eq $script:Shown.Count 1 'a missed one from another day says nothing'
        # Thanksgiving: fresh prices and no session today - no popup, and the header says so;
        # Toronto trades that day, so a list with SHOP.TO still gets one
        $env:JK_NOW = (& $here '2026-11-26T10:00:00').ToString('s')
        $null = & $seed 'SPY' $wed $wed; $null = & $seed 'QQQ' $wed $wed
        Assert-True ($null -eq (Get-JkStocksPopup -Tries 1)) 'no popup on a market holiday'
        Assert-True (((& $say { Invoke-JkStocks }) -join ' ') -match 'US market closed today') 'closed today'
        $null = & $seed 'SHOP.TO' $wed ([datetime]'2026-11-26') 0 'Toronto' 'CAD'
        Save-JkStockList @('SPY', 'SHOP.TO')
        $p = Get-JkStocksPopup -Tries 1
        Assert-True ($p -and ($p.Lines -join ' | ') -match 'SHOP\.TO ') "Toronto open: $($p.Title) | $($p.Lines -join ' | ')"
        Assert-True (((& $say { Invoke-JkStocks shop.to }) -join ' ') -match "CAD . Toronto market open until $(& $hm '2026-11-26T16:00')") 'its own market'
        # the list: add (checked when it can be), already there, not a symbol; rm
        $txt = (& $say { Invoke-JkStocks add nvda spy }) -join ' '
        Assert-True ($txt -match 'NVDA \(not checked: no live prices' -and $txt -match 'SPY is already on the list' -and $txt -match 'watching SPY, SHOP\.TO, NVDA') "add: $txt"
        $e = ''; try { Invoke-JkStocks add 'two words!' 6>$null } catch { $e = "$_" }
        Assert-True ($e -match 'is not a ticker symbol') "not a symbol: $e"
        $txt = (& $say { Invoke-JkStocks rm shop.to }) -join ' '
        Assert-True ($txt -match 'removed SHOP\.TO' -and $txt -match 'watching SPY, NVDA' -and -not (Test-Path (Get-JkStockCachePath 'SHOP.TO'))) "rm: $txt"
        $e = ''; try { Invoke-JkStocks rm xyz 6>$null } catch { $e = "$_" }
        Assert-True ($e -match 'XYZ is not on the list \(SPY, NVDA\)') "rm one not there: $e"
        $e = ''; try { Invoke-JkStocks 'what?' 6>$null } catch { $e = "$_" }
        Assert-True ($e -match "unknown 'stocks' action") "a word that is not a symbol: $e"
        # numbers
        Assert-Eq "$(Format-JkPrice 1234.5) $(Format-JkPrice 0.5) $(Format-JkStockPct 0.0123) $(Format-JkStockPct -0.05 2)" '1,234.50 0.5000 +1.2% -5.00%' 'prices and percents'
        Assert-Eq (Get-JkSparkline @(1, 2, 3, 4, 5, 6, 7, 8) 8) (-join @(0x2581..0x2588 | ForEach-Object { [char]$_ })) 'the sparkline'
    } finally {
        Set-Item function:script:Start-JkBackground $origBg; Set-Item function:script:Show-JkNotify $origNotify
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $env:JK_CACHE = $savedCache; $script:JkConfigCache = $null
    }
}
Test 'jk exam <course> papers: the past papers for its next exam, paired with their solutions, newest term first, and which are done' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH
    $env:JK_HOME = Join-Path $saved 'papers-home'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    $top = Join-Path $env:JK_HOME 'courses'; $dir = Join-Path $top 'CS370'
    foreach ($sub in 'past-exams', 'mock', 'slides') { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    # three finals (one only as solutions, one with them), two midterms; slides, an assignment's
    # last version and a Word copy are not papers
    foreach ($n in 'past-exams\cs-370-1029-final.pdf', 'past-exams\cs-370-1029-final-sol.pdf', 'past-exams\cs-370-1069-final-sol.pdf', 'past-exams\cs-370-1009-final.pdf',
        'past-exams\cs-370-1029-midterm.pdf', 'mock\CS370-mock-midterm.pdf', 'slides\final-review-slides.pdf', 'a1-final.pdf', 'past-exams\cs-370-1029-final.docx') { Set-Content -LiteralPath (Join-Path $dir $n) 'x' }
    $savedC = Get-JkConfig 'tidy.courses'
    try {
        Set-JkConfig 'tidy.courses' $top
        $env:JK_NOW = '2026-11-25T10:00:00'; $env:JK_WIDTH = '110'
        $d = Get-JkDueData; $c = Resolve-JkCourse $d 'cs370' -Create
        $null = New-JkEvent -Data $d -Course $c.key -Date ([datetime]'2026-12-10') -Time '16:00' -Title 'FINAL' -Weight '40%' -Kind 'exam'
        Save-JkDueData $d
        $say = { param([scriptblock]$Run) @(& $Run 6>&1 | ForEach-Object { "$_" }) }
        $out = & $say { Invoke-JkExams cs370 papers }
        $rows = @($out | Where-Object { $_ -match '^\s+\d+ ' })
        Assert-Eq $rows.Count 5 "three finals and two midterms: $($out -join ' | ')"
        Assert-True ($rows[0] -match '^\s+1 .*F2006 cs-370-1069-final-sol\.pdf\s+solutions only') "newest first: $($rows[0])"
        Assert-True ($rows[1] -match 'F2002 cs-370-1029-final\.pdf\s+\+ solutions') "paired: $($rows[1])"
        Assert-True ($rows[2] -match 'F2000 cs-370-1009-final\.pdf\s+no solutions') "no solutions: $($rows[2])"
        Assert-True ($rows[3] -match 'F2002 cs-370-1029-midterm\.pdf' -and $rows[4] -match 'CS370-mock-midterm\.pdf') "the midterms after: $($rows[3]) / $($rows[4])"
        Assert-True (($out -join "`n") -match 'Midterms\s+earlier material') 'the midterms are a section of their own'
        Assert-True (($out -join "`n") -match 'next: jk find -o 2 opens the F2002 paper') "next skips the solutions-only paper: $($out -join ' | ')"
        Assert-Eq ((@(Get-JkFindLast) | ForEach-Object { Split-Path $_ -Leaf }) -join ',') 'cs-370-1069-final-sol.pdf,cs-370-1029-final.pdf,cs-370-1009-final.pdf,cs-370-1029-midterm.pdf,CS370-mock-midterm.pdf' 'jk find -o opens them by number'
        # done, with a mark; what to check it against and what is next
        $txt = (& $say { Invoke-JkExams cs370 did 2 17/20 }) -join ' '
        Assert-True ($txt -match 'Done F2002 cs-370-1029-final\.pdf .*85% .*1 of 5 done' -and $txt -match 'jk exam cs370 sol 2' -and $txt -match 'next: the F2000 paper') "did: $txt"
        $txt = (& $say { Invoke-JkExams cs370 papers }) -join "`n"
        Assert-True ($txt -match 'cs-370-1029-final\.pdf\s+done Nov 25\s+.\s+85%' -and $txt -match '1 of 5 done') "kept: $txt"
        # jk exam's own screen, and the course page's word
        $txt = (& $say { Show-JkExamBrief cs370 }) -join "`n"
        Assert-True ($txt -match 'papers\s+3 finals and 2 midterms in the folder, 1 done') "the exam screen: $txt"
        $txt = (& $say { Invoke-JkCourseAction (Resolve-JkCourse (Get-JkDueData) 'cs370') @('papers') }) -join "`n"
        Assert-True ($txt -match 'PAST PAPERS' -and $txt -match '1 of 5 done') 'jk cs370 papers'
        $txt = (& $say { Invoke-JkExams cs370 undid 2 }) -join ' '
        Assert-True ($txt -match 'Not done F2002' -and @((Get-JkPaperData).done).Count -eq 0) "undid: $txt"
        # jk plan start on the final names the next paper to sit, one jk find -o away; the timer is stubbed
        $origFocus = ${function:Start-JkFocus}
        function script:Start-JkFocus { param($Minutes, $Label) }
        try {
            $env:JK_NOW = '2026-12-05T10:00:00'
            $txt = (& $say { Start-JkPlanBlock }) -join "`n"
            Assert-True ($txt -match 'paper: F2002 cs-370-1029-final\.pdf .* jk find -o 1 .* jk exam cs370 did 2 when done') "plan start: $txt"
            Assert-Eq (Split-Path @(Get-JkFindLast)[0] -Leaf) 'cs-370-1029-final.pdf' 'jk find -o 1 opens it'
            # and the morning popup, under its study line
            Assert-Eq (Get-JkPlanPaperHint (Get-JkPlanToday) (Get-JkDueData) $c.key) 'Next past paper: CS 370 F2002 cs-370-1029-final.pdf (jk exam cs370 papers)' 'the popup line'
        } finally { Set-Item function:script:Start-JkFocus $origFocus; $env:JK_NOW = '2026-11-25T10:00:00' }
        # a week with nothing on the timer: jk review says how studying still counts
        $txt = (& $say { Show-JkReview }) -join "`n"
        Assert-True ($txt -match '0m focused\s+\(studied without the timer\? jk plan did 2h cs350\)') "review: $txt"
        # refusals in jk's words
        $cases = @(
            @(@('cs370', 'did', '9'), 'which paper\? a number from jk exam cs370 papers \(1 to 5\)'),
            @(@('cs370', 'did', '1', '140'), 'between 0 and 100'),
            @(@('cs370', 'did', '1', 'abc'), 'a mark is 74, 74% or 17/20'),
            @(@('cs370', 'sol', '3'), 'no solutions for cs-370-1009-final\.pdf'),
            @(@('cs370', 'did'), 'usage: jk exam cs370 did <n> \[mark\]'))
        foreach ($case in $cases) {
            $e = ''; $argv = @($case[0])
            try { Invoke-JkExams @argv 6>$null } catch { $e = "$_" }
            Assert-True ($e -match $case[1]) "jk exam $($argv -join ' '): $e"
        }
        # names
        Assert-Eq "$((Get-JkPaperTerm 'F19-midterm.pdf').Label) $((Get-JkPaperTerm 'cs-370-1011-final').Label) [$((Get-JkPaperTerm 'cs-251-1216-midterm').Label)]" 'F2019 W2001 []' 'terms'
        Assert-Eq (Get-JkPaperStem 'CS245-Practice-Mid-Term-No-Solutions.pdf') (Get-JkPaperStem 'CS245-Practice-Mid-Term-Solutions.pdf') 'No-Solutions pairs with Solutions'
        Assert-True (-not (Test-JkPaperIsSolution 'CS245-Practice-Mid-Term-No-Solutions.pdf') -and -not (Test-JkPaperIsSolution 'monkey-final.pdf') -and (Test-JkPaperIsSolution 'W19-midterm-sol.pdf')) 'which are solutions'
        Assert-True (-not (Test-JkPaperName 'NOT-MIDTERM_02d-slides.pdf' 'midterm') -and (Test-JkPaperName 'mt_practice.pdf' 'midterm') -and (Test-JkPaperName 'CS245-Sample-Final-Exam.pdf' 'final')) 'which are papers'
        # a folder with none says how they are found, and no "0 of 0"
        $d = Get-JkDueData; $h = Resolve-JkCourse $d 'health105' -Create; New-Item -ItemType Directory -Force -Path (Join-Path $top 'HEALTH105') | Out-Null
        $null = New-JkEvent -Data $d -Course $h.key -Date ([datetime]'2026-12-07') -Time '06:00' -Title 'Midterm 2' -Weight '17.5%' -Kind 'exam'
        Save-JkDueData $d
        $txt = (& $say { Invoke-JkExams health papers }) -join ' '
        Assert-True ($txt -match 'no past midterms in the folder' -and $txt -notmatch '0 of 0') "none: $txt"
    } finally { Set-JkConfig 'tidy.courses' $savedC; $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $script:JkConfigCache = $null; $script:JkDueCache = $null }
}
Test 'jk plan counts part of a day as part of a day: an exam at 3 pm on 10-hour days leaves 2.5 days from two days before, not 2' {
    # [Math]::Max(1, 2.5) is 2 in PowerShell: an integer first argument picks the integer overload
    $it = [pscustomobject]@{ Key = 'f'; Course = 'x'; Title = 'f'; Due = [datetime]'2026-12-10T15:00'; Weight = 40; Kind = 'exam'; Id = 0; Effort = 600; Done = 0.0 }
    $s = @(Get-JkPlanSchedule -Items @($it) -Now ([datetime]'2026-12-08T09:00') -Days 1 -BudgetMin 600)
    Assert-Eq $s[0].Alloc['f'] 250 '600 minutes over 2.5 days, in 25-minute blocks'
}
Test 'jk plan: on a squeezed day, work whose last day it is (due tonight, or tomorrow morning) comes first, and finals weeks out wait' {
    $mk = { param($k, $due, $eff, $kind) [pscustomobject]@{ Key = $k; Course = $k; Title = $k; Due = [datetime]$due; Weight = 10; Kind = $kind; Id = 0; Effort = $eff; Done = 0.0 } }
    $finals = @((& $mk 'fin1' '2026-12-10T16:00' 760 'exam'), (& $mk 'fin2' '2026-12-12T12:30' 845 'exam'))
    # 5 hours of an assignment due at 8 tonight, a 3-hour day: all of the day goes to it
    $s = @(Get-JkPlanSchedule -Items (@(& $mk 'a3' '2026-11-25T20:00' 300 'due') + $finals) -Now ([datetime]'2026-11-25T08:00') -Days 2 -BudgetMin 180)
    Assert-Eq "$($s[0].Alloc['a3']) $([int]$s[0].Alloc['fin1']) $([int]$s[0].Alloc['fin2'])" '175 0 0' 'tonight''s assignment takes the day'
    Assert-True ($s[1].Alloc['fin1'] -ge 50 -and $s[1].Alloc['fin2'] -ge 50) "tomorrow the finals share the day: $($s[1].Alloc['fin1']) / $($s[1].Alloc['fin2'])"
    # less than the day: tonight's 50 minutes and a 9 am quiz's 100 in full, the finals share the rest
    $s = @(Get-JkPlanSchedule -Items (@((& $mk 'small' '2026-11-25T20:00' 50 'due'), (& $mk 'quiz' '2026-11-26T09:00' 100 'exam')) + $finals) -Now ([datetime]'2026-11-25T08:00') -Days 1 -BudgetMin 180)
    $rest = [int]$s[0].Alloc['fin1'] + [int]$s[0].Alloc['fin2']
    Assert-Eq "$($s[0].Alloc['small']) $($s[0].Alloc['quiz']) $rest" '50 100 25' 'the last-day items in full, the rest to the finals'
    # a day with no last-day work shares as before: in proportion to each ask
    $s = @(Get-JkPlanSchedule -Items (@(& $mk 'a4' '2026-12-04T23:59' 1200 'due') + $finals) -Now ([datetime]'2026-11-25T08:00') -Days 1 -BudgetMin 180)
    Assert-True ($s[0].Alloc['fin1'] -ge 25 -and $s[0].Alloc['fin2'] -ge 25 -and $s[0].Alloc['a4'] -ge 75 -and $s[0].Need -gt 180) "shared: $($s[0].Alloc['a4']) / $($s[0].Alloc['fin1']) / $($s[0].Alloc['fin2'])"
}
Test 'jk plan warns of a squeeze only when a whole day is short: an evening with 45 minutes left is not' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH
    $env:JK_HOME = Join-Path $saved 'squeeze-home'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $dd = Get-JkDueData; $a = Resolve-JkCourse $dd 'cs341' -Create
        $null = New-JkEvent -Data $dd -Course $a.key -Date ([datetime]'2026-11-16') -Time '23:59' -Title 'Assignment 4' -Weight '10%'
        Save-JkDueData $dd
        $env:JK_WIDTH = '160'
        $warn = { @(Show-JkPlan 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'squeezed' }) }
        # the day's asks fit in a 3-hour day, but at 8 pm only a quarter of it is left
        $env:JK_NOW = '2026-11-13T20:00:00'
        $p = Get-JkPlanToday
        Assert-True ($p.Today.Need -le 180 -and $p.Today.Need -gt $p.Today.Budget * 1.15) "the case: a day wants $($p.Today.Need)m, the evening has $($p.Today.Budget)m"
        Assert-Eq (& $warn).Count 0 'no warning for an evening that is short by the clock'
        # a 1-hour day is short whatever the time: the warning names the fix
        $null = Invoke-JkConfig set plan.hours 1 6>&1; $script:JkConfigCache = $null
        $w = @(& $warn)
        Assert-True ($w.Count -eq 1 -and $w[0] -match 'a day, more than your 1h 00m: the plan is squeezed \(jk config set plan\.hours [2-3]\)') "the warning: $($w -join ' / ')"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'jk space clean caches runs temp, conda, pip and npm in turn, skips one that cannot run, and says what it freed' {
    $orig = ${function:Invoke-JkSpaceCleanStep}
    $script:Steps = @()
    # never the real conda, pip or npm here
    function script:Invoke-JkSpaceCleanStep([string]$Step, [int]$Days) { $script:Steps += "$Step/$Days"; if ($Step -eq 'npm') { throw 'npm not found' }; "cleaned $Step" }
    try {
        $out = (Invoke-JkSpaceClean caches -Days 9 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-Eq ($script:Steps -join ',') 'temp/9,conda/9,pip/9,npm/9' 'all four, in order, with -Days'
        Assert-True ($out -match 'cleaned conda' -and $out -match 'skipped: npm not found') "each step said: $out"
        Assert-True ($out -match 'freed .+ in all') 'a total at the end'
    } finally { Set-Item function:script:Invoke-JkSpaceCleanStep $orig }
    $m = try { Invoke-JkSpaceClean bogus; '' } catch { $_.Exception.Message }
    Assert-True ($m -match 'caches\|temp\|conda') "usage names caches: $m"
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
Test 'backup mirror prunes only day folders it wrote, and config set takes the mirror checks' {
    $saved = $env:JK_HOME
    $base = Join-Path $saved ('mirror2-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $env:JK_HOME = Join-Path $base 'data'
    $script:JkConfigCache = $null
    try {
        Import-JkDueHtml $htmlPath | Out-Null
        # a folder that already holds dated folders of its own: photo imports, an export
        $m = Join-Path $base 'Pictures'
        $photos = Join-Path $m '2019-05-04'
        $mixed = Join-Path $m '2019-05-05'
        $nested = Join-Path $m '2019-05-06'
        $ours = Join-Path $m '2000-01-02'
        foreach ($d in $photos, $mixed, (Join-Path $nested 'raw'), $ours) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        Set-Content -LiteralPath (Join-Path $photos 'IMG_0001.jpg') -Value 'x'
        Set-Content -LiteralPath (Join-Path $mixed 'deadlines.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $mixed 'notes.txt') -Value 'mine'
        foreach ($f in 'deadlines.json', 'config.json') { Set-Content -LiteralPath (Join-Path $ours $f) -Value '{}' }
        Invoke-JkBackup mirror $m 6>&1 | Out-Null
        # stored in full; $m may be the 8.3 form of the same folder (C:\Users\JACKWA~1\...)
        $stored = Get-JkConfig 'backup.mirror'
        Assert-Eq (Resolve-JkLongPath $stored) (Resolve-JkLongPath $m) 'the mirror is set'
        Assert-True (Test-Path -LiteralPath (Join-Path $photos 'IMG_0001.jpg')) 'a dated folder of photos is kept'
        Assert-True (Test-Path -LiteralPath (Join-Path $mixed 'notes.txt')) 'a dated folder with a file jk did not write is kept'
        Assert-True (Test-Path -LiteralPath (Join-Path $nested 'raw')) 'a dated folder with a subfolder is kept'
        Assert-True (-not (Test-Path -LiteralPath $ours)) 'an old snapshot of jk''s own is still pruned'
        # config set stored any folder, skipping the checks jk backup mirror makes
        Assert-Throws { Invoke-JkConfig set backup.mirror (Join-Path $env:JK_HOME 'inside') 6>&1 | Out-Null } 'config set refuses a mirror inside the data folder'
        Assert-Throws { Invoke-JkConfig set backup.mirror 'relative\mirror' 6>&1 | Out-Null } 'and a relative one'
        Assert-Eq (Get-JkConfig 'backup.mirror') $stored 'the mirror is unchanged'
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
        $stored = (Get-JkDueData).term
        $env:JK_NOW = ([datetime]::ParseExact([string]$stored.examsEnd, 'yyyy-MM-dd', $null)).AddDays(7).ToString('s')
        Assert-Eq (Format-JkTermLine (Get-JkTermInfo (Get-JkDueData) (Get-JkNow))) 'Winter 2027' "the last of December is past $($stored.name), though the month is still its season"
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
Test 'the popup card reads any title, and a crowded morning still fits a laptop screen' {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $measure = {
        param([string]$Title, [string[]]$Lines)
        $win = [Windows.Markup.XamlReader]::Parse((New-JkPopupXaml $Title $Lines 'F87C7C' 'file:///C:/x.html' 'Open calendar'))
        $card = $win.Content; $win.Content = $null
        $card.Measure((New-Object System.Windows.Size ($win.Width, [double]::PositiveInfinity)))
        $card.DesiredSize.Height
    }
    # what a title can hold: quotes, ampersands, angle brackets, and a brace up front
    foreach ($t in "Read 'Ch 3' & <notes>", '{Quiz} 3 closes', 'Lab {1}', '100% done "now"', (-join ([char[]](0x7B2C, 0x4E8C, 0x6B21)))) {
        $h = & $measure $t @("Today 11:59 pm - $t")
        Assert-True ($h -gt 50) "'$t' lays out ($h px)"
    }
    # everything the morning popup can hold at once: six deadlines (the rest as "+N more"), exams,
    # classes, weather, to-dos, the study plan, LEARN's moves
    $long = 'Today 11:59 pm - CS 341 Assignment 9 - Dynamic Programming and the Very Long Title That Goes On (8%)'
    $busy = @('Classes today: 8:30 am CO 367 LEC (MC 2017), 10:00 am CS 341 LEC (DWE 3522), 1:00 pm CS 350 LEC (STC 0060), 4:00 pm CS 370 TUT (MC 4045)') + @(1..6 | ForEach-Object { $long }) +
        @('Tomorrow 6:00 pm - HEALTH 105 Midterm 2 (exam, online window, 90 minutes)', 'In 2 days 4:00 pm - CS 370 Final (exam) - room TBA', '+4 more', 'Weather: rain from 3 pm, 9 mm; take an umbrella. High 6, low -2, gusts 50 km/h', 'To-do: email the prof about the regrade, print the notes, buy a planner, +3 more', 'Study today: CS 341 1h 40m, CS 350 1h 10m, HEALTH 105 25m, CO 367 25m', 'LEARN moved: CS 350 A3 to Fri Nov 13 8:00 pm; CS 341 A4 to Mon Nov 16 11:59 pm')
    # the parts Show-JkPopup wires up are there to find
    $w = [Windows.Markup.XamlReader]::Parse((New-JkPopupXaml 'x' @('y') 'F87C7C' 'file:///C:/x.html' 'Open calendar'))
    Assert-True ($w.FindName('CloseBtn') -and $w.FindName('OpenBtn')) 'close and open buttons'
    Assert-True (-not ([Windows.Markup.XamlReader]::Parse((New-JkPopupXaml 'x' @('y')))).FindName('OpenBtn')) 'no open button without a link'
    $h = & $measure '9 deadlines in the next 48h and 2 exams in 3 days' $busy
    # a 1920x1080 screen at 125% leaves 816 px above the taskbar (this laptop's); on a smaller one the
    # card's top stays on screen and only its bottom would tuck under the taskbar
    Assert-True ($h -lt 760) "a crowded morning is $([int]$h) px tall"
}
Test 'saving while another jk reads or saves: nothing fails, and a read is never empty' {
    # Move-Item -Force deletes the old file first: nearly 5% of reads under this load found no file,
    # read that as "no data yet", and a save after one would have written an empty list over the data
    $box = Join-Path $env:JK_HOME 'race'
    $null = New-Item -ItemType Directory -Path (Join-Path $box 'home') -Force
    $worker = Join-Path $box 'worker.ps1'
    Write-JkText $worker @'
param([string]$Role, [string]$Home2, [string]$Module, [string]$Out, [string]$Start)
$env:JK_HOME = $Home2
Import-Module $Module -Force -DisableNameChecking
$begin = [datetime]::Parse($Start)
while ((Get-Date) -lt $begin) { Start-Sleep -Milliseconds 20 }
$r = & (Get-Module jk) {
    param($Role, $until)
    $ok = 0; $bad = @{}; $seen = $false; $i = 0
    while ((Get-Date) -lt $until) {
        $i++
        try {
            if ($Role -eq 'write') { Save-JkJson 'todo.json' ([pscustomobject]@{ nextId = 9; items = @(1..30 | ForEach-Object { [pscustomobject]@{ id = $_; text = "item $PID $i" } }) }) }
            else {
                $d = Read-JkJson 'todo.json' $null
                if ($d) { $seen = $true; if (@($d.items).Count -ne 30) { throw 'a short file' } }
                elseif ($seen) { throw 'read as empty' }
            }
            $ok++
        } catch { $m = ([string]$_.Exception.Message) -replace '\d+', 'N'; $bad[$m] = [int]$bad[$m] + 1 }
    }
    "$Role ok=$ok " + (($bad.Keys | ForEach-Object { "[$($bad[$_]) x $_]" }) -join ' ')
} $Role $begin.AddSeconds(3)
# a file of its own: the four workers stop at the same moment, and a second append to one shared
# file fails with "being used by another process" (14 rounds in 15 when they finish together)
[IO.File]::WriteAllText("$Out.$PID", "$r`n")
'@
    $out = Join-Path $box 'out.txt'
    $start = (Get-Date).AddSeconds(4).ToString('o')
    $module = Join-Path (Get-JkRoot) 'jk.psd1'
    $procs = @(foreach ($role in 'write', 'write', 'read', 'read') {
            $psi = New-Object Diagnostics.ProcessStartInfo (Get-JkPowerShellExe), ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $worker + '" -Role ' + $role + ' -Home2 "' + (Join-Path $box 'home') + '" -Module "' + $module + '" -Out "' + $out + '" -Start "' + $start + '"')
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            [Diagnostics.Process]::Start($psi)
        })
    foreach ($p in $procs) { Assert-True ($p.WaitForExit(60000)) 'a worker did not finish' }
    $lines = @(Get-ChildItem -LiteralPath $box -Filter 'out.txt.*' | ForEach-Object { Get-Content -LiteralPath $_.FullName })
    Assert-Eq $lines.Count 4 "every worker reported: $($lines -join ' / ')"
    foreach ($l in $lines) { Assert-True ($l -match '^(write|read) ok=[1-9]\d* $') $l }
    $left = @(Get-ChildItem -LiteralPath (Join-Path $box 'home') -File -Force | Where-Object { $_.Name -ne 'todo.json' -and $_.Name -notmatch '^backups$' } | ForEach-Object { $_.Name })
    Assert-Eq ($left -join ', ') '' 'nothing left behind, nothing marked damaged'
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
Test 'background timers wait in real time: the second 1:30 the night clocks fall back is not the first' {
    # "jk in 2h" at 00:30 EDT on Nov 1: 1:30 EST, an hour after the clock first reads 1:30
    $cmd = Get-JkBackgroundCommand -Script 'x' -WaitUntil '2026-11-01T01:30:00.0000000-05:00'
    $at = $null
    Invoke-Expression ([regex]::Match($cmd, '\$at = [^;]+;').Value)
    Assert-Eq $at.ToString("yyyy-MM-dd'T'HH:mm'Z'", $script:Inv) '2026-11-01T06:30Z' 'target kept its offset'
    Assert-True ($cmd -match '\$at - \[DateTime\]::UtcNow' -and $cmd -notmatch 'Get-Date\)\)\.TotalSeconds') 'counts down against the UTC clock'
    # a target with no offset is the local wall-clock time on that day
    $cmd = Get-JkBackgroundCommand -Script 'x' -WaitUntil '2026-11-02T17:00:00'
    Invoke-Expression ([regex]::Match($cmd, '\$at = [^;]+;').Value)
    Assert-Eq $at.ToLocalTime().ToString('yyyy-MM-dd HH:mm', $script:Inv) '2026-11-02 17:00' 'no offset: local time that day'
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
Test 'jk due add: unquoted titles, "due nov 6", exam time ranges, a twin noted; names by course and words' {
    $file = Get-JkPath 'deadlines.json'
    $saved = [IO.File]::ReadAllText($file)
    try {
        $out = @(& {
                jk due add cs350 A4 Paging dec 2 8pm -Weight 10
                jk due add cs350 midterm 2 nov 19 7-8:50pm -Exam
                jk due add cs350 A3 due nov 6 at 11:59pm
                jk due add cs350 Midterm oct 30 -Exam
                jk due add cs350 A4 dec 9
            } 6>&1 | ForEach-Object { "$_" })
        $ev = { param($t) @((Get-JkDueData).events | Where-Object { $_.course -eq 'cs350' -and $_.title -ceq $t }) }
        $a4 = @(& $ev 'A4 Paging')[0]
        Assert-Eq "$($a4.date) $($a4.time) $($a4.weight)" '2026-12-02 20:00 10%' 'words before the date join the title'
        $m2 = @(& $ev 'midterm 2')[0]
        Assert-Eq "$($m2.date) $($m2.time)-$($m2.end) $($m2.kind)" '2026-11-19 19:00-20:50 exam' 'the 2 stays in the title; 7-8:50pm is start and end'
        $a3 = @(& $ev 'A3')[0]
        Assert-Eq "$($a3.date) $($a3.time)" '2026-11-06 23:59' '"due nov 6 at 11:59pm"'
        $orig = @(& $ev 'Midterm' | Where-Object { $_.date -eq '2026-10-29' })[0]
        Assert-True (@($out | Where-Object { $_ -match "already has Midterm on Thu Oct 29 \(#$($orig.id)\)" }).Count -eq 1) "twin noted: $($out -join ' / ')"
        # an exact title wins over a longer one; course + words name one item
        $short = @(& $ev 'A4')[0]
        Assert-Eq @(Find-JkEvents (Get-JkDueData) @('A4'))[0].id $short.id '"A4" is A4, not A4 Paging'
        Set-JkDueDone health assignment 2
        $h2 = @((Get-JkDueData).events | Where-Object { $_.course -eq 'health' -and $_.title -eq 'Assignment 2' })[0]
        Assert-True $h2.done 'health assignment 2 checked off'
        Set-JkDueDone -Undo health a2
        Assert-True (-not @((Get-JkDueData).events | Where-Object { $_.id -eq $h2.id })[0].done) 'reopened as "health a2"'
        Assert-Throws { Find-JkEvents (Get-JkDueData) @('cs350', 'midterm') } 'two cs350 midterms ahead'
        # edit -Date takes a time after the date, and the phrases add takes
        $null = @(& { jk due edit $a4.id -Date nov 8 5pm } 6>&1)
        $x = @((Get-JkDueData).events | Where-Object { $_.id -eq $a4.id })[0]
        Assert-Eq "$($x.date) $($x.time)" '2026-11-08 17:00'
        $null = @(& { jk due edit $a4.id -Date in 3 days } 6>&1)
        Assert-Eq @((Get-JkDueData).events | Where-Object { $_.id -eq $a4.id })[0].date '2026-10-25'
    } finally { [IO.File]::WriteAllText($file, $saved) }
}
Test 'jk due add: a weekday stays out of the title, and an impossible date adds nothing' {
    $file = Get-JkPath 'deadlines.json'
    $saved = [IO.File]::ReadAllText($file)
    try {
        $null = @(& { Add-JkDue -Course cs350 -Title 'Weekday' -When @('Mon', 'Oct', '26', '6pm') } 6>&1)
        $hit = @((Get-JkDueData).events | Where-Object { $_.title -like 'Weekday*' })
        Assert-Eq $hit.Count 1
        Assert-Eq "$($hit[0].title) $($hit[0].date) $($hit[0].time)" 'Weekday 2026-10-26 18:00'
        $null = @(& { Add-JkDue -Course cs350 -Title 'Read' -When @('4-31', 'fri') } 6>&1)
        $hit = @((Get-JkDueData).events | Where-Object { $_.title -like 'Read*' })
        Assert-Eq "$($hit[0].title) $($hit[0].date)" 'Read 4-31 2026-10-23' 'a chapter range is not a mistyped date'
        $before = @((Get-JkDueData).events).Count
        foreach ($when in @(@('nov', '31', '8pm'), @('tue', 'oct', '26', '6pm'))) {
            $m = try { $null = @(& { Add-JkDue -Course cs350 -Title 'Typo' -When $when } 6>&1); '' } catch { $_.Exception.Message }
            Assert-True ($m -like 'no such date*') "$($when -join ' '): $m"
        }
        Assert-Eq @((Get-JkDueData).events).Count $before 'nothing added'
        # -Time and -End read a bare hour the same way as the date does
        $id = @((Get-JkDueData).events | Where-Object { $_.title -eq 'Weekday' })[0].id
        $null = @(& { Edit-JkDue $id -Time 5 -End 6:30 } 6>&1)
        $x = @((Get-JkDueData).events | Where-Object { $_.id -eq $id })[0]
        Assert-Eq "$($x.time) $($x.end)" '17:00 18:30'
    } finally { [IO.File]::WriteAllText($file, $saved) }
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
    # the same codes typed in lowercase, without "tue"/"thu" turning into codes
    foreach ($k in @{ 'tth' = 'Tue Thu'; 'mwf' = 'Mon Wed Fri'; 'tr' = 'Tue Thu'; 'mtwthf' = 'Mon Tue Wed Thu Fri'; 'th' = 'Thu'; 'tu' = 'Tue'; 'su' = 'Sun' }.GetEnumerator()) {
        Assert-Eq ((ConvertTo-JkDays $k.Key) -join ' ') $k.Value "for '$($k.Key)'"
    }
    Assert-Throws { ConvertTo-JkDays 'mh' }
    $r = ConvertTo-JkTimeRange '1-220pm'; Assert-Eq "$($r.Start) $($r.End)" '13:00 14:20' 'colon left out'
}
Test 'jk class add: days with spaces, lowercase codes' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'add-home'
    try {
        $null = @(& {
                jk class add cs350 tue thu 4pm-5:20pm 'MC 1056'
                jk class add cs341 tth 1-220pm DC 1351 -From sep 8
                jk class add cs370 mon wed fri 930-1020am -Kind TUT
                jk class add cs370 F 3-4pm e7 4053 LAB
                jk class add cs370 W 7-8pm MC 1056 extra
            } 6>&1)
        $items = @((Get-JkClassData).items)
        Assert-Eq $items.Count 4 'a stray word is still refused'
        $got = @($items | ForEach-Object { "$($_.course) $($_.kind) $(@($_.days) -join ',') $($_.start)-$($_.end) $($_.room) $($_.from)".Trim() })
        Assert-Eq $got[0] 'cs350 LEC Tue,Thu 16:00-17:20 MC 1056'
        Assert-Eq $got[1] 'cs341 LEC Tue,Thu 13:00-14:20 DC 1351 2026-09-08' 'unquoted room, then a loose -From date'
        Assert-Eq $got[2] 'cs370 TUT Mon,Wed,Fri 09:30-10:20'
        Assert-Eq $got[3] 'cs370 LAB Fri 15:00-16:00 E7 4053' 'kind word after the room'
    } finally { $env:JK_HOME = $saved }
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
Test 'class import with nothing copied: opens Quest, then reads the copied page' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'quest-home'
    $script:JkConfigCache = $null
    $quest = "CS 341 - Algorithms`nClass Nbr`tSection`tComponent`tDays & Times`tRoom`tInstructor`tStart/End Date`n5678`t001`tLEC`tTTh 10:00AM - 11:20AM`tMC 2065`tSome Prof`t09/08/2026 - 12/08/2026"
    $script:Answers = New-Object System.Collections.Generic.Queue[string]
    $script:Opened = @(); $script:Clip = ''
    $origTI = ${function:Test-JkInteractive}; $origOpen = ${function:Open-JkUrl}; $origClip = ${function:Get-JkClipboardText}
    function script:Read-Host { param($Prompt) $script:Answers.Dequeue() }
    function script:Test-JkInteractive { $true }
    function script:Open-JkUrl { param($Url) $script:Opened += $Url; $script:Clip = $quest }
    function script:Get-JkClipboardText { $script:Clip }
    try {
        foreach ($x in '', '') { $script:Answers.Enqueue($x) }
        $null = @(Import-JkClasses 6>&1)
        Assert-Eq ($script:Opened -join ' ') $script:JkQuestUrl 'Quest opened'
        $c = @((Get-JkClassData).items)
        Assert-Eq "$($c.Count) $($c[0].course) $(@($c[0].days) -join ',') $($c[0].start) $($c[0].room)" '1 cs341 Tue,Thu 10:00 MC 2065' 'read off the clipboard after Enter'
        # q cancels quietly; Enter with nothing copied still explains where to copy from
        $script:Clip = ''; $script:Opened = @()
        foreach ($x in 'n', 'q') { $script:Answers.Enqueue($x) }
        $null = @(Import-JkClasses 6>&1)
        Assert-Eq $script:Opened.Count 0 'n leaves the browser closed'
        foreach ($x in 'n', '') { $script:Answers.Enqueue($x) }
        $msg = ''; try { Import-JkClasses 6>$null } catch { $msg = $_.Exception.Message }
        Assert-True ($msg -match 'List View') "error: $msg"
    } finally {
        Remove-Item function:script:Read-Host -ErrorAction SilentlyContinue
        Set-Item function:script:Test-JkInteractive $origTI
        Set-Item function:script:Open-JkUrl $origOpen
        Set-Item function:script:Get-JkClipboardText $origClip
        $env:JK_HOME = $saved; $script:JkConfigCache = $null
    }
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
            # q stops asking at once instead of reading "00q" as a section
            $script:Answers.Enqueue('q'); $script:Prompts = @()
            Assert-Eq @(Read-JkSectionPicks -Course health).Count 0 'q picks nothing'
            Assert-Eq $script:Prompts.Count 1 'and asks nothing more'
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
    Assert-True ($null -eq (Find-JkFeedLink $script:JkLearnCalendarUrl)) 'the calendar page itself is not the feed'
}
Test 'first sync: opens LEARN''s calendar, then reads the copied link off the clipboard' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'firstsync-home'
    $script:JkConfigCache = $null
    $ics = Join-Path $saved 'firstsync.ics'
    Set-Content $ics "BEGIN:VCALENDAR`r`nBEGIN:VEVENT`r`nUID:fs-1`r`nSUMMARY:Assignment 9 - Due`r`nDTSTART:20261105T235900`r`nDTEND:20261105T235900`r`nLOCATION:CS 350 - Operating Systems`r`nEND:VEVENT`r`nEND:VCALENDAR`r`n" -Encoding ascii
    $script:Answers = New-Object System.Collections.Generic.Queue[string]
    $script:Opened = @(); $script:Clip = $null
    $origTI = ${function:Test-JkInteractive}; $origOpen = ${function:Open-JkUrl}; $origClip = ${function:Get-JkClipboardFeed}
    function script:Read-Host { param($Prompt) $script:Answers.Dequeue() }
    function script:Test-JkInteractive { $true }
    function script:Open-JkUrl { param($Url) $script:Opened += $Url; $script:Clip = $ics }
    function script:Get-JkClipboardFeed { $script:Clip }
    try {
        # Enter = open LEARN; Enter = "copied it": the link comes off the clipboard
        foreach ($x in '', '') { $script:Answers.Enqueue($x) }
        $null = @(Invoke-JkDueSync 6>&1)
        Assert-Eq ($script:Opened -join ' ') $script:JkLearnCalendarUrl 'LEARN calendar opened'
        Assert-True (@((Get-JkDueData).events | Where-Object { [string]$_.uid -eq 'fs-1' }).Count -eq 1) 'synced from the copied link'
        # no browser, then q: nothing happens
        $script:Opened = @(); $script:Clip = $null
        foreach ($x in 'n', 'q') { $script:Answers.Enqueue($x) }
        $null = @(Invoke-JkDueSync 6>&1)
        Assert-Eq $script:Opened.Count 0 'n leaves the browser closed'
        # Enter with nothing copied says so instead of syncing nothing
        foreach ($x in 'n', '') { $script:Answers.Enqueue($x) }
        Assert-Throws { Invoke-JkDueSync 6>$null }
    } finally {
        Remove-Item function:script:Read-Host -ErrorAction SilentlyContinue
        Set-Item function:script:Test-JkInteractive $origTI
        Set-Item function:script:Open-JkUrl $origOpen
        Set-Item function:script:Get-JkClipboardFeed $origClip
        $env:JK_HOME = $saved; $script:JkConfigCache = $null
    }
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
    # weight not entered yet is still to come, not gone: a 100 on a 30% midterm can still reach 80
    $one = { param($w, $s) [pscustomobject]@{ Key = "k$w"; Title = "Item $w"; Weight = [double]$w; Score = $s; Date = ''; Extra = $false } }
    $part = Measure-JkGrade @(& $one 30 100.0) @()
    Assert-Eq "$($part.Remaining) $($part.Unlisted)" '0 70'
    Assert-Eq (Get-JkNeededText 80 $part)[0] '71%' 'not "out of reach"'
    # all of it entered: over is over, and a rounding short of 100 changes nothing
    foreach ($w in 100, 99.6) {
        $full = Measure-JkGrade @(& $one $w 70.0) @()
        Assert-Eq $full.Unlisted 0 "weights of $w"
        Assert-Eq (Get-JkNeededText 80 $full)[0] 'out of reach' "weights of $w"
    }
    Assert-Eq (Get-JkNeededText 60 (Measure-JkGrade @(& $one 100 70.0) @()))[0] 'done'
}
Test 'jk grade <course> if <item> <mark>: the course as it would stand, nothing saved' {
    $file = Join-Path $env:JK_HOME 'grades.json'
    $before = [IO.File]::ReadAllText($file)
    $out = (& { jk grade cs350 if midterm 70 } 6>&1 | ForEach-Object { "$_" }) -join "`n"
    # [.,]: the German-formats run writes 25,0%
    Assert-True ($out -match 'Midterm\s+25[.,]0%\s+70[.,]0%') "assumed row: $out"
    Assert-True ($out -match 'then: average 70[.,]0% over 25[.,]0%') 'the average with that mark'
    Assert-True ($out -match 'to finish with' -and $out -match 'you need') 'what the rest would need'
    Assert-Eq ([IO.File]::ReadAllText($file)) $before 'nothing recorded (the "mark at the end means set" rule does not apply)'
    # two at once, the way PowerShell hands over "a2a 9/10, midterm 70" (the comma made an array)
    $two = (Show-JkGradeWhatIf cs350 @('a2a', '9/10', 'midterm', '70') 6>&1 | ForEach-Object { "$_" }) -join "`n"
    Assert-True ($two -match 'A2A Synchronization\s+8[.,]0%\s+90[.,]0%' -and $two -match 'Midterm\s+25[.,]0%\s+70[.,]0%') "both: $two"
    Assert-True ($two -match 'then: average 74[.,]8% over 33[.,]0%') "weighted together: (7.2 + 17.5) / 33 = 74.8: $two"
    Assert-Throws { Show-JkGradeWhatIf cs350 @('bonus', '5') }
    Assert-Eq ([IO.File]::ReadAllText($file)) $before 'still nothing saved'
}
Test 'jk grade import with no course reads the course from the copied page' {
    $saved = $env:JK_HOME
    $env:JK_HOME = Join-Path $saved 'import-detect'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $d = Get-JkDueData; $a = Resolve-JkCourse $d 'cs350' -Create; $null = Resolve-JkCourse $d 'cs341' -Create; $null = Resolve-JkCourse $d 'co367' -Create
        $null = New-JkEvent -Data $d -Course $a.key -Date ([datetime]'2026-10-01') -Time '20:00' -Title 'A1 Threads' -Weight '10%'
        Save-JkDueData $d
        Assert-Eq ([string](Find-JkCourseInText $d "CS 350 - Operating Systems (Fall 2026)`nGrades`nA1 Threads`t9 / 10`t90 %`nview CS350 home").code) 'CS 350' 'named in the header and a link'
        Assert-True ($null -eq (Find-JkCourseInText $d "Grades`nA1`t9 / 10")) 'named nowhere'
        Assert-True ($null -eq (Find-JkCourseInText $d "CS 350 and CS 341 share a TA")) 'two named equally: no guess'
        Assert-True ($null -eq (Find-JkCourseInText $d "CS 3501 notes")) 'CS 3501 is not CS 350'
        $f = Join-Path $env:JK_HOME 'page.txt'
        [IO.File]::WriteAllText($f, "CS 350 - Operating Systems (Fall 2026)`nGrades`nGrade Item`tPoints`tGrade`nA1 Threads`t9 / 10`t90 %")
        $out = (Import-JkGrades -Path $f -Yes 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($out -match "the copied page is CS 350's") "said which: $out"
        Assert-Eq @(Get-JkGradeItems (Get-JkDueData) (Get-JkGradeData) $a.key | Where-Object { $_.Title -eq 'A1 Threads' })[0].Score 90 'recorded for CS 350'
        [IO.File]::WriteAllText($f, "Grades`nA1`t9 / 10`t90 %")
        $m = try { Import-JkGrades -Path $f 6>&1 | Out-Null; '' } catch { $_.Exception.Message }
        Assert-True ($m -match '^usage: jk grade import <course>') "no course on the page: $m"
    } finally { $env:JK_HOME = $saved; $script:JkConfigCache = $null; $script:JkDueCache = $null }
}
Test 'grade import: a copied LEARN Grades page becomes marks, matched by title, on a yes' {
    $page = "Grades`nFinal Calculated Grade`t-`nGrade Item`tPoints`tWeight Achieved`tGrade`nAssignments`t `t `t`nAssignment 01 - Stigma`t9 / 10`t9 / 10`t90 %`nAssignment 2`t- / 10`t- / 10`nMidterm`t27 / 30`t27 / 30`t90 %`tView feedback`nParticipation`t5 / 5`t2 / 2`t100 %"
    # LEARN's own totals must never be offered as extra parts of the grade (they would count twice)
    $totals = "Assignments`t9 / 10`t9 / 20`t90 %`nAssignment 1`t9 / 10`t9 / 10`t90 %`nQuizzes`t4 / 5`t8 / 10`t80 %`nQuiz 1`t4 / 5`t8 / 10`t80 %`nFinal Calculated Grade`t88 / 100`t`t88 %"
    $tf = Join-Path $env:JK_HOME 'totals.txt'; [IO.File]::WriteAllText($tf, $totals)
    $tout = (Import-JkGrades health -Path $tf 6>&1 | ForEach-Object { "$_" }) -join "`n"
    Assert-True ($tout -match 'Assignments\s.*a total LEARN adds up' -and $tout -match 'Final Calculated Grade\s.*a total LEARN adds up') "totals: $tout"
    Assert-True ($tout -match 'Quizzes\s.*a total LEARN adds up') 'quizzes is the plural of quiz'
    Assert-True ($tout -notmatch 'jk grade add health "(Assignments|Quizzes|Final Calculated Grade)"') 'no add command for a total'
    $rows = @(ConvertFrom-JkGradesText $page)
    Assert-Eq (($rows | ForEach-Object { $_.Title }) -join '|') 'Assignment 01 - Stigma|Assignment 2|Midterm|Participation' 'headers and category rows skipped'
    Assert-Eq "$($rows[0].Pct) $($rows[1].Pct) $($rows[3].Weight)" '90  2' 'points to percent; "- / 10" ungraded; the weight column'
    Assert-Eq @(ConvertFrom-JkGradesText "Quiz 3`t85 %")[0].Pct 85 'a percentage alone'
    $items = @(Get-JkGradeItems (Get-JkDueData) (Get-JkGradeData) 'health')
    $find = { param($t) $i = Find-JkGradeRowItem ([pscustomobject]@{ Title = $t }) $items; if ($i) { $i.Title } else { '-' } }
    Assert-Eq (& $find 'Assignment 01 - Stigma') 'Assignment 1' 'padded number, extra words'
    Assert-Eq (& $find 'A3') 'Assignment 3' 'shorthand'
    Assert-Eq (& $find 'Assignment 10') '-' 'no Assignment 10 here, and not Assignment 1'
    Assert-Eq (& $find 'Midterm') 'Midterm' 'the online window'
    $grades = Join-Path $env:JK_HOME 'grades.json'; $dl = Get-JkPath 'deadlines.json'
    $savedG = [IO.File]::ReadAllText($grades); $savedD = [IO.File]::ReadAllText($dl)
    $file = Join-Path $env:JK_HOME 'health-grades.txt'; [IO.File]::WriteAllText($file, $page)
    try {
        Clear-JkGrade (@($items | Where-Object { $_.Title -eq 'Assignment 1' })[0].Key) 6>$null
        $pre = (Import-JkGrades health -Path $file 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($pre -match '-Yes records them') 'without -Yes (and no prompt) it only shows'
        Assert-True ($pre -match 'jk grade add health "Participation" -Weight 2 -Score 5/5') "unmatched hint: $pre"
        $null = @(Import-JkGrades health -Path $file -Yes 6>&1)
        $after = @(Get-JkGradeItems (Get-JkDueData) (Get-JkGradeData) 'health')
        Assert-Eq @($after | Where-Object { $_.Title -eq 'Assignment 1' })[0].Score 90
        Assert-Eq @($after | Where-Object { $_.Title -eq 'Midterm' })[0].Score 90
        $a1 = @((Get-JkDueData).events | Where-Object { $_.course -eq 'health' -and $_.title -eq 'Assignment 1' })[0]
        Assert-True $a1.done 'a marked item is checked off'
        $again = (Import-JkGrades health -Path $file -Yes 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($again -match 'Nothing new to record') 'a second import changes nothing'
        # nothing copied, prompts on: LEARN opens and the copied page is read after Enter
        $script:Answers = New-Object System.Collections.Generic.Queue[string]
        $script:Opened = @(); $script:Clip = ''
        $origTI = ${function:Test-JkInteractive}; $origOpen = ${function:Open-JkUrl}; $origClip = ${function:Get-JkClipboardText}
        function script:Read-Host { param($Prompt) $script:Answers.Dequeue() }
        function script:Test-JkInteractive { $true }
        function script:Open-JkUrl { param($Url) $script:Opened += $Url; $script:Clip = "Assignment 3`t7 / 10`t7 / 10`t70 %" }
        function script:Get-JkClipboardText { $script:Clip }
        try {
            foreach ($x in '', '', '') { $script:Answers.Enqueue($x) }   # open LEARN, copied, yes record
            $null = @(Import-JkGrades health 6>&1)
            Assert-Eq ($script:Opened -join ' ') $script:JkLearnHomeUrl 'LEARN opened'
            Assert-Eq @(Get-JkGradeItems (Get-JkDueData) (Get-JkGradeData) 'health' | Where-Object { $_.Title -eq 'Assignment 3' })[0].Score 70
        } finally {
            Remove-Item function:script:Read-Host -ErrorAction SilentlyContinue
            Set-Item function:script:Test-JkInteractive $origTI
            Set-Item function:script:Open-JkUrl $origOpen
            Set-Item function:script:Get-JkClipboardText $origClip
        }
    } finally { [IO.File]::WriteAllText($grades, $savedG); [IO.File]::WriteAllText($dl, $savedD) }
}
Test 'marks by course and title words, scores with spaces, one target for every course' {
    $file = Join-Path $env:JK_HOME 'grades.json'
    $saved = [IO.File]::ReadAllText($file)
    try {
        foreach ($k in @{ '17 out of 20' = 85; '85 %' = 85; '17 / 20' = 85; '8.5/10' = 85 }.GetEnumerator()) { Assert-Eq (ConvertTo-JkPercent $k.Key) $k.Value "for '$($k.Key)'" }
        $null = @(& {
                jk grade health a1 9/10              # no "set", a1 = Assignment 1
                jk grade set health midterm 24 / 30  # the opens/closes window is one item
                jk grade cs350 a2 8 out of 10        # a2 = A2A here, the only one in the fixture
            } 6>&1)
        $gd = Get-JkGradeData
        $score = { param($course, $title) @(Get-JkGradeItems (Get-JkDueData) $gd $course | Where-Object { $_.Title -eq $title })[0].Score }
        Assert-Eq (& $score health 'Assignment 1') 90
        Assert-Eq (& $score health 'Midterm') 80
        Assert-Eq (& $score cs350 'A2A Synchronization') 80
        Assert-Throws { Set-JkGrade health assignment 5/10 } 'three assignments match'
        Assert-Throws { Set-JkGrade cs350 midterm } 'no mark given'
        Assert-Eq (Resolve-JkGradeRef (Get-JkDueData) $gd @('cs350', 'nonsense')) '' 'nothing graded by that name'
        $null = @(& { jk grade target 85; jk grade target cs350 90; jk grade target 70 health } 6>&1)
        $gd = Get-JkGradeData
        Assert-Eq (Get-JkTarget $gd 'cs350') 90
        Assert-Eq (Get-JkTarget $gd 'health') 70 'percent first, course second'
        Assert-Eq (Get-JkTarget $gd 'cs341') 85 'the default for the rest'
    } finally { [IO.File]::WriteAllText($file, $saved) }
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
Test 'a date at the end of a to-do is its due date; plain words and quoted text stay text' {
    # pinned clock: Thu Oct 22 14:00
    $cases = [ordered]@{
        'email prof about the midterm by friday' = 'email prof about the midterm|10-23 00:00'
        'buy groceries tomorrow'                 = 'buy groceries|10-23 00:00'
        'call mom at 7pm'                        = 'call mom|10-22 19:00'
        'submit co-op ranking due oct 28 5pm'    = 'submit co-op ranking|10-28 17:00'
        'pay rent nov 1'                         = 'pay rent|11-01 00:00'
        'read chapter 4 before mon'              = 'read chapter 4|10-26 00:00'
        'renew passport in 2 weeks'              = 'renew passport|11-05 00:00'
        'watch lecture 5 next mon'               = 'watch lecture 5|11-02 00:00'
        'read chapter 4'                         = 'read chapter 4|'
        'dry clothes in the sun'                 = 'dry clothes in the sun|'
        'print 3d'                               = 'print 3d|'
        'email Jan'                              = 'email Jan|'
        'tomorrow'                               = 'tomorrow|'
    }
    foreach ($k in $cases.Keys) {
        $r = Split-JkTrailingWhen @($k -split ' ')
        $due = ''; if ($r[0]) { $due = ([datetime](ConvertTo-JkTodoDue $r[0])).ToString('MM-dd HH:mm') }
        Assert-Eq "$(@($r[1]) -join ' ')|$due" $cases[$k] "for '$k'"
    }
    Assert-Eq (Split-JkTrailingWhen @('meet on sun'))[0] '' 'one quoted word is left as typed'
    $file = Join-Path $env:JK_HOME 'todo.json'
    $saved = $null; if (Test-Path $file) { $saved = [IO.File]::ReadAllText($file) }
    try {
        Remove-Item $file -ErrorAction SilentlyContinue
        $null = @(& { jk todo 'book flight home' -Due dec 18; jk todo finish essay tonight } 6>&1)
        $items = @((Get-JkTodoData).items | Sort-Object id)
        Assert-Eq "$($items[0].id) $($items[0].text)" '1 book flight home' '-Due dec 18 keeps the text whole'
        Assert-Eq (Get-JkTodoDue $items[0]).ToString('MM-dd') '12-18' 'the day number goes back to -Due'
        Assert-Eq "$($items[1].text) $([bool]$items[1].done)" 'finish essay False' '"finish <words>" adds a to-do'
        $null = @(& { jk todo edit 1 -Due tomorrow 6pm } 6>&1)
        $one = @((Get-JkTodoData).items | Where-Object { $_.id -eq 1 })[0]
        Assert-Eq "$($one.text) $((Get-JkTodoDue $one).ToString('MM-dd HH:mm'))" 'book flight home 10-23 18:00' 'edit -Due tomorrow 6pm leaves the text alone'
        $null = @(& { jk todo finish 2; jk todo rm essay } 6>&1)
        Assert-Eq @((Get-JkTodoData).items).Count 1 'finish <n> checks it off; rm finds a finished one by text'
    } finally { if ($null -ne $saved) { [IO.File]::WriteAllText($file, $saved) } else { Remove-Item $file -ErrorAction SilentlyContinue } }
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
Test 'brackets in a folder name are not a wildcard: jk cp add keeps the samples, jk pdf finds the files' {
    $cn = -join ([char[]](0x738B, 0x73CF))
    $dir = Join-Path $env:JK_HOME 'A [easy version]'
    $null = New-Item -ItemType Directory -Path $dir -Force
    Write-JkText (Join-Path $dir '1.in') 'FIRST'
    $orig = ${function:Get-JkClipboardText}
    Push-Location -LiteralPath $dir
    try {
        function script:Get-JkClipboardText { 'NEW' }
        $null = @(Add-JkCpTest -In 6>&1)
        Assert-Eq ([IO.File]::ReadAllText((Join-Path $dir '1.in'))) 'FIRST' 'a filled sample is not overwritten'
        Assert-Eq ([IO.File]::ReadAllText((Join-Path $dir '2.in'))).Trim() 'NEW' 'the next number is used'
    } finally { Pop-Location; Set-Item function:script:Get-JkClipboardText $orig }
    # jk pdf: a name as typed is that file; only then is it a pattern
    $scans = Join-Path $env:JK_HOME 'Sc[a]ns'
    $null = New-Item -ItemType Directory -Path $scans -Force
    foreach ($n in 'page[1].png', 'page[2].png', "$cn.png") { Write-JkText (Join-Path $scans $n) 'x' }
    $leaf = { param([string[]]$Items) @(Resolve-JkPdfInputs $Items | ForEach-Object { Split-Path $_ -Leaf } | Sort-Object) -join '|' }
    $every = @("$cn.png", 'page[1].png', 'page[2].png' | Sort-Object) -join '|'
    Assert-Eq (& $leaf @((Join-Path $scans '*.png'))) $every 'a pattern in a folder with brackets'
    Assert-Eq (& $leaf @((Join-Path $scans 'page[2].png'))) 'page[2].png' 'by its full name'
    Push-Location -LiteralPath $scans
    try {
        Assert-Eq (& $leaf @('page[1].png')) 'page[1].png' 'by a relative name'
        Assert-Eq (& $leaf @("$cn.png")) "$cn.png"
        Assert-Eq (& $leaf @('*.png')) $every
        Assert-Throws { Resolve-JkPdfInputs @('nothing.png') } 'a plain name that is not there'
    } finally { Pop-Location }
}
Test 'a relative path works from inside a folder with [ in its name' {
    # PowerShell 5.1 finds nothing by a relative -LiteralPath there, though the file is right beside it
    $dir = Join-Path $env:JK_HOME 'B [hard]'
    $null = New-Item -ItemType Directory -Path (Join-Path $dir 'sub') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $dir 'empty') -Force
    Write-JkText (Join-Path $dir 'main.py') 'print(1)'
    Write-JkText (Join-Path $dir 'sub\main.cpp') 'int main(){}'
    Write-JkText (Join-Path $dir 'cal.ics') 'not a calendar'
    Write-JkText (Join-Path $dir 'times.txt') 'nothing readable'
    Push-Location -LiteralPath $dir
    $savedGo = [IO.File]::Exists((Get-JkPath 'bookmarks.json'))
    try {
        Assert-Eq (Get-JkCpSource 'main.py').Name 'main.py' 'jk cp test main.py'
        Assert-Eq (Get-JkCpSource 'main').Name 'main.py' 'by its name without the extension'
        Assert-Eq (Get-JkCpSource 'sub').Name 'main.cpp' 'a problem folder: the solution in it'
        Assert-Throws { Get-JkCpSource 'empty' } 'a folder with no solution'
        Assert-Throws { Get-JkCpSource 'nothing.cpp' }
        Assert-Eq (Split-Path (Resolve-JkLongPath 'sub') -Leaf) 'sub' 'jk tidy sub'
        Assert-Eq (Split-Path (Resolve-JkGoPath 'sub') -Leaf) 'sub' 'j sub'
        $m = try { $null = Invoke-JkDueSync 'cal.ics' 6>&1; '' } catch { $_.Exception.Message }
        Assert-True ($m -match 'does not look like a calendar') "jk due sync finds the file: $m"
        $m = try { $null = Import-JkClasses 'times.txt' 6>&1; '' } catch { $_.Exception.Message }
        Assert-True ($m -notmatch 'no such file') "jk class import finds the file: $m"
        # a bookmark keeps the whole path, and only ever to a folder
        $null = @(Invoke-JkMark bracketed -Path 'sub' 6>&1)
        $mark = @((Get-JkGoData).marks | Where-Object { $_.alias -eq 'bracketed' })[0]
        Assert-True ([IO.Path]::IsPathRooted([string]$mark.path) -and $mark.path.EndsWith('B [hard]\sub')) "bookmark: $($mark.path)"
        $null = @(Invoke-JkMark bracketed -Remove 6>&1)
        Assert-Throws { Invoke-JkMark nothing -Path 'nosuchfolder' }
    } finally { Pop-Location }
    # jk tidy takes a folder, and a drive's root stays a root
    Assert-Throws { Invoke-JkTidyRun -Path (Join-Path $dir 'main.py') } 'a file is not a folder'
    Assert-Throws { Invoke-JkTidyOld (Join-Path $dir 'main.py') }
    Assert-Throws { Invoke-JkTidyDupes (Join-Path $dir 'main.py') }
    Assert-Throws { Invoke-JkTidyRun -Path 'no such folder' }
    Assert-Eq (Resolve-JkLongPath 'C:\') 'C:\' 'C: alone would mean the current folder on C'
    # a problem's name has to be able to be a folder, and stays inside the problems folder
    foreach ($bad in '*', 'a:b', 'what?', '..', '.', '..\up', ' ') {
        $m = try { $null = New-JkCpProblem $bad -Here -NoOpen 6>&1; '' } catch { $_.Exception.Message }
        Assert-True ($m -match "can't name a folder") "'$bad': $m"
    }
}
Test 'jk config: a misspelt setting is refused, not saved to do nothing' {
    $m = try { Invoke-JkConfig set tidy.cources x; '' } catch { $_.Exception.Message }
    Assert-True ($m -match "no setting 'tidy\.cources'" -and $m -match 'tidy\.courses') "suggests its neighbours: $m"
    Assert-Eq (Get-JkConfig 'tidy.cources') $null 'nothing saved'
    $m = try { Invoke-JkConfig set 1 x; '' } catch { $_.Exception.Message }
    Assert-True ($m -match "no setting '1'") $m
    Assert-Throws { Invoke-JkConfig reset } 'reset of what?'
    Assert-Throws { Invoke-JkConfig reset nosuchkey }
    # one saved under a wrong name by an older version can still be cleared
    Set-JkConfig 'old.typo' 'x'
    $null = @(Invoke-JkConfig reset old.typo 6>&1)
    Assert-Eq (Get-JkConfig 'old.typo') $null 'cleared'
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
    Test 'jk cp builds and runs in folders with brackets, an apostrophe, an ampersand or a Chinese name' {
        $cn = -join ([char[]](0x738B, 0x73CF))
        foreach ($name in 'A [easy version]', "o'brien", 'c&d 100%', "$cn x") {
            $dir = Join-Path $env:JK_HOME "cp-names\$name"
            $null = New-Item -ItemType Directory -Path $dir -Force
            Write-JkText (Join-Path $dir 'main.cpp') "#include <iostream>`nint main(){ long long a,b; std::cin>>a>>b; std::cout<<a+b<<std::endl; }`n"
            $src = Get-Item -LiteralPath (Join-Path $dir 'main.cpp')
            $run = Build-JkCp $src -Quiet
            $r = Invoke-JkProcess -Exe $run.Exe -ArgList $run.Args -InputText "40 2`n" -WorkDir $dir
            Assert-Eq $r.Out.Trim() '42' "release, in $name"
            Assert-True (-not (Build-JkCp $src -Quiet).Compiled) "the second build hits the cache, in $name"
        }
        $dir = Join-Path $env:JK_HOME "cp-names\$cn x"
        $src = Get-Item -LiteralPath (Join-Path $dir 'main.cpp')
        $run = Build-JkCp $src -DebugBuild -Quiet
        Assert-Eq (Invoke-JkProcess -Exe $run.Exe -ArgList $run.Args -InputText "1 2`n" -WorkDir $dir).Out.Trim() '3' 'the debug build too'
        # a compile error still names the file as typed, not by a mangled path
        Write-JkText (Join-Path $dir 'bad.cpp') "int main(){ return x; }`n"
        $bad = Get-Item -LiteralPath (Join-Path $dir 'bad.cpp')
        $said = @(& { try { $null = Build-JkCp $bad -Quiet } catch { "threw: $($_.Exception.Message)" } } 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($said -match 'bad\.cpp:1' -and $said -match 'threw: compilation failed') $said
        # the file's own name cannot be worked around: say what to do
        if (-not (Test-JkAnsiPath $cn)) {
            Write-JkText (Join-Path $dir "$cn.cpp") "int main(){}`n"
            $named = Get-Item -LiteralPath (Join-Path $dir "$cn.cpp")
            $m = try { $null = Build-JkCp $named -Quiet; '' } catch { $_.Exception.Message }
            Assert-True ($m -match 'rename it') "named outside the code page: $m"
        }
    }
    if (Get-Command javac -ErrorAction SilentlyContinue) {
        Test 'jk cp builds and runs Java in a folder with brackets or a Chinese name' {
            $cn = -join ([char[]](0x738B, 0x73CF))
            foreach ($name in 'J [hard]', "$cn java") {
                $dir = Join-Path $env:JK_HOME "cp-names\$name"
                $null = New-Item -ItemType Directory -Path $dir -Force
                Write-JkText (Join-Path $dir 'Main.java') 'import java.util.*;public class Main{public static void main(String[] x){Scanner s=new Scanner(System.in);System.out.println(s.nextInt()+s.nextInt());}}'
                $src = Get-Item -LiteralPath (Join-Path $dir 'Main.java')
                $run = Build-JkCp $src -Quiet
                $r = Invoke-JkProcess -Exe $run.Exe -ArgList $run.Args -InputText "40 2`n" -WorkDir $dir -TimeoutMs 30000
                Assert-Eq $r.Out.Trim() '42' "in $name"
            }
        }
    }
    Test 'bits/stdc++.h is precompiled once per set of flags, outside the data folder; a failure is not retried' {
        $gpp = Get-Command g++
        $flags = @('-std=c++17', '-O2', '-DLOCAL', '-Wl,--stack,268435456')
        $root = Get-JkCpPch $gpp $flags 'release' -Quiet
        Assert-True ($root -and $root.StartsWith($env:JK_CACHE)) "pch under JK_CACHE: $root"
        Assert-True (Test-Path (Join-Path $root 'bits\stdc++.h.gch')) 'the header is built'
        Assert-True ([IO.File]::ReadAllText((Join-Path $root 'key.txt')) -notmatch '--stack') 'linker flags are not part of it'
        $t = (Get-Item (Join-Path $root 'bits\stdc++.h.gch')).LastWriteTimeUtc
        $null = Get-JkCpPch $gpp $flags 'release' -Quiet
        Assert-Eq (Get-Item (Join-Path $root 'bits\stdc++.h.gch')).LastWriteTimeUtc $t 'reused, not rebuilt'
        # GCC really picks it up (-H marks a used precompiled header with "!")
        $src = Join-Path $env:JK_HOME 'cp-e2e\main.cpp'
        $h = Invoke-JkProcess -Exe $gpp.Source -ArgList @('-std=c++17', '-O2', '-DLOCAL', "-I$root", '-H', '-fsyntax-only', $src) -InputText '' -TimeoutMs 60000 -WorkDir $root
        $first = @($h.Err -split "`r?`n" | Where-Object { $_ })[0]
        Assert-True ($first -match '^!.*stdc\+\+\.h\.gch') "used: $first"
        # a set of flags the compiler rejects: no header, remembered, not tried again
        $bad = @('-std=c++99nonsense')
        Assert-Eq (Get-JkCpPch $gpp $bad 'broken' -Quiet) $null
        $fail = Join-Path $env:JK_CACHE 'cp-pch\broken\failed.txt'
        Assert-True (Test-Path $fail) 'failure remembered'
        $sw = [Diagnostics.Stopwatch]::StartNew(); $null = Get-JkCpPch $gpp $bad 'broken' -Quiet; $sw.Stop()
        Assert-True ($sw.ElapsedMilliseconds -lt 500) "not retried ($($sw.ElapsedMilliseconds) ms)"
    }
    Test 'jk cp new templates compile cleanly (release, debug, judge) and dbg prints nested containers' {
        foreach ($t in 'main.cpp', 'usaco.cpp') {
            $dir = Join-Path $env:JK_HOME "cp-tpl-$($t -replace '\W', '')"
            New-Item -ItemType Directory $dir -Force | Out-Null
            $src = ([IO.File]::ReadAllText((Join-Path (Get-JkRoot) "templates\cp\$t"))).Replace('{{NAME}}', 'x').Replace('{{DATE}}', 'today')
            # what a solution does with it: dbg on a container of pairs, a map of vectors, strings and literals
            $src = $src -replace '(?m)^(\s*)return 0;', "`$1vector<pair<int,string>> v{{1,`"a`"}}; map<int,vector<int>> m{{2,{3,4}}}; string s=`"hi`"; dbg(v, m, s, `"lit`", 5); cout << `"ok`" << `"\n`";`n`$1return 0;"
            [IO.File]::WriteAllText((Join-Path $dir 'main.cpp'), $src)
            $f = Get-Item (Join-Path $dir 'main.cpp')
            foreach ($dbgBuild in $false, $true) {
                $run = Build-JkCp $f -Quiet -DebugBuild:$dbgBuild
                $r = Invoke-JkProcess -Exe $run.Exe -InputText '' -WorkDir $dir
                Assert-Eq $r.Out.Trim() 'ok' "$t debug=$dbgBuild"
                Assert-True ($r.Err -match '\{\(2, \{3, 4\}\)\}' -and $r.Err -match '\{\(1, a\)\}') "$t dbg output: $($r.Err)"
            }
            # the judge compiles without -DLOCAL: dbg and the printers compile away, no warnings
            $j = Invoke-JkProcess -Exe (Get-Command g++).Source -ArgList @('-std=c++20', '-O2', '-Wall', '-Wextra', '-o', (Join-Path $dir 'judge.exe'), $f.FullName) -InputText '' -TimeoutMs 120000 -WorkDir $dir
            Assert-Eq $j.Code 0 "$t judge build: $($j.Err)"
            Assert-True ($j.Err -notmatch 'warning:') "$t judge build warnings: $($j.Err)"
        }
    }
}
Test 'jk cp new <problem link>: AtCoder, USACO (both page styles), CSES samples; Codeforces named only' {
    # page shapes as the judges serve them (trimmed)
    $jaIn = [string][char]0x5165 + [char]0x529B + [char]0x4F8B; $jaOut = [string][char]0x51FA + [char]0x529B + [char]0x4F8B
    $pages = @{
        'atcoder' = "<span class=""lang-ja""><h3>$jaIn 1</h3><pre>9 9</pre></span><span class=""lang-en""><h3>Input</h3><pre><var>N</var></pre><h3>Sample Input 1</h3><pre>3 125 175`n200 300 400`n</pre><h3>Sample Output 1</h3><pre>2`n</pre><p>We &lt;have&gt;</p><h3>Sample Input 2</h3><pre>1 1 1`n2`n</pre><h3>Sample Output 2</h3><pre>1`n</pre></span>"
        'usaco'   = "<h4>SAMPLE INPUT:</h4><pre class='in'>`n2 4`n7 9`n</pre><h4>SAMPLE OUTPUT:</h4> <pre class='out'>`n7`n</pre>"
        'usacoold' = "range 1...10,000).`n`nSAMPLE INPUT (file haybales.in):`n`n4`n2`n10`n7`n1`n`nINPUT DETAILS:`n`nThere are 4 piles.`n`nSAMPLE OUTPUT (file haybales.out):`n`n7`n`nOUTPUT DETAILS:`n`nBy moving"
        'cses'    = "<h1 id=""example"">Example</h1> <p>Input:</p> <pre>3`n</pre> <p>Output:</p> <pre>3 10 5 16 8 4 2 1`n</pre></div>"
    }
    $at = ConvertFrom-JkJudgeHtml 'atcoder' $pages.atcoder
    Assert-Eq $at.Tests.Count 2 'English samples only, not the input format block'
    Assert-Eq $at.Tests[0].In "3 125 175`n200 300 400`n"
    Assert-Eq $at.Tests[1].Out "1`n"
    Assert-Eq (ConvertFrom-JkJudgeHtml 'atcoder' "<h3>$jaIn 1</h3><pre>5</pre><h3>$jaOut 1</h3><pre>6</pre>").Tests[0].Out "6`n" 'a Japanese-only page'
    $us = ConvertFrom-JkJudgeHtml 'usaco' $pages.usaco
    Assert-Eq "$($us.Tests.Count) $($us.FileIO)|$($us.Tests[0].In)" "1 |2 4`n7 9`n" 'leading newline dropped; standard input'
    $old = ConvertFrom-JkJudgeHtml 'usaco' $pages.usacoold
    Assert-Eq "$($old.FileIO)|$($old.Tests[0].In)|$($old.Tests[0].Out)" "haybales|4`n2`n10`n7`n1`n|7`n" 'plain-text samples and the file name'
    Assert-Eq (ConvertFrom-JkJudgeHtml 'cses' $pages.cses).Tests[0].Out "3 10 5 16 8 4 2 1`n"
    Assert-Eq (Get-JkJudgeLink 'https://atcoder.jp/contests/abc300/tasks/abc300_a').Name 'abc300_a'
    Assert-Eq (Get-JkJudgeLink 'https://codeforces.com/problemset/problem/4/A').Name 'cf4A'
    Assert-Eq (Get-JkJudgeLink 'https://codeforces.com/contest/1900/problem/C2').Name 'cf1900C2'
    Assert-Eq (Get-JkJudgeLink 'https://example.com/x') $null
    # end to end with the page fetch stubbed: folder, samples, the USACO template only for file I/O
    $root = Join-Path $env:JK_HOME 'cp-links'
    New-Item -ItemType Directory $root -Force | Out-Null
    $origWeb = ${function:Invoke-JkWebText}
    $here = Get-Location
    try {
        function script:Invoke-JkWebText { param($Url) if ($Url -match 'cpid=94') { $script:Pg.usacoold } elseif ($Url -match 'usaco') { $script:Pg.usaco } else { $script:Pg.atcoder } }
        $script:Pg = $pages
        Set-Location $root
        $null = @(New-JkCpProblem 'https://atcoder.jp/contests/abc300/tasks/abc300_a' -Here -NoOpen 6>&1)
        Assert-Eq ([IO.File]::ReadAllText((Join-Path $root 'abc300_a\2.in'))) "1 1 1`n2`n" 'samples written'
        Set-Location $root
        $null = @(New-JkCpProblem 'https://usaco.org/index.php?page=viewproblem2&cpid=94' -Here -NoOpen 6>&1)
        Assert-True ([IO.File]::ReadAllText((Join-Path $root 'haybales\main.cpp')) -match 'setIO\("haybales"\)') 'file I/O: the USACO template, under its file name'
        Set-Location $root
        $null = @(New-JkCpProblem 'https://usaco.org/index.php?page=viewproblem2&cpid=1301' -Here -NoOpen 6>&1)
        Assert-True ([IO.File]::ReadAllText((Join-Path $root 'usaco1301\main.cpp')) -notmatch 'freopen') 'standard input: the plain template'
        # a sample already filled in is never overwritten
        Set-Content (Join-Path $root 'abc300_a\1.out') 'mine'
        Set-Location $root
        $null = @(New-JkCpProblem 'https://atcoder.jp/contests/abc300/tasks/abc300_a' -Here -NoOpen 6>&1)
        Assert-Eq ((Get-Content (Join-Path $root 'abc300_a\1.out')) -join '') 'mine'
        Set-Location $root
        $cf = (New-JkCpProblem 'https://codeforces.com/contest/4/problem/A' -Here -NoOpen 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($cf -match 'jk cp add' -and (Test-Path (Join-Path $root 'cf4A\main.cpp'))) 'Codeforces: the folder, and how to paste'
    } finally { Set-Item function:script:Invoke-JkWebText $origWeb; Set-Location $here }
}
Test 'jk cp listen: Competitive Companion problems, one or a whole contest, over localhost' {
    # the request reader: headers, then exactly Content-Length bytes of UTF-8
    $body = '{"name":"A. Caf' + [char]0xE9 + '"}'
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $raw = [Text.Encoding]::ASCII.GetBytes("POST / HTTP/1.1`r`nHost: localhost`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`n`r`n") + $bytes
    $req = Read-JkHttpRequest (New-Object IO.MemoryStream (, [byte[]]$raw))
    Assert-Eq "$($req.Method) $($req.Body)" "POST $body"
    # the JSON: named by its link, by its title without one, the USACO template for file I/O
    $cf = ConvertFrom-JkCompanion '{"name":"A. Watermelon","url":"https://codeforces.com/problemset/problem/4/A","tests":[{"input":"8\n","output":"YES\n"}],"input":{"type":"stdin"},"batch":{"id":"x","size":3}}'
    Assert-Eq "$($cf.Name) $($cf.BatchSize) $($cf.Tests[0].Out.Trim())" 'cf4A 3 YES'
    Assert-Eq (ConvertFrom-JkCompanion '{"name":"C. Two Sums & More","url":"https://judge.example/x","tests":[]}').Name 'two-sums-more'
    $us = ConvertFrom-JkCompanion '{"name":"Hay","url":"","tests":[],"input":{"type":"file","fileName":"haybales.in"}}'
    Assert-Eq "$($us.Name) $($us.Lang)" 'haybales usaco'
    # end to end: a background job posts a two-problem contest to the listener, like the extension
    $root = Join-Path $env:JK_HOME 'cc-root'
    New-Item -ItemType Directory $root -Force | Out-Null
    $savedRoot = Get-JkConfig 'cp.root'
    Set-JkConfig 'cp.root' $root
    $here = Get-Location
    # one Windows says is free: a random pick landed on a port another program held
    $probe = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, 0); $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
    $job = Start-Job -ArgumentList $port -ScriptBlock { param($p)
        # every field the extension sends (its README's example, two problems of one contest)
        $mk = { param($l, $in, $out) '{"name":"' + $l + '. X","group":"Codeforces Round 2000 (Div. 2)","url":"https://codeforces.com/contest/2000/problem/' + $l + '","interactive":false,"memoryLimit":256,"timeLimit":2000,"tests":[{"input":"' + $in + '","output":"' + $out + '"}],"testType":"single","input":{"type":"stdin"},"output":{"type":"stdout"},"languages":{"java":{"mainClass":"Main","taskClass":"X"}},"batch":{"id":"123e67c8-03c6-44a4-a3f9-5918def8bac4","size":2}}' }
        for ($try = 0; $try -lt 50; $try++) {
            try { $null = Invoke-WebRequest -Uri "http://127.0.0.1:$p/" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes((& $mk 'A' '1 2\n' '3\n'))) -ContentType 'application/json' -UseBasicParsing; break } catch { Start-Sleep -Milliseconds 200 }
        }
        $null = Invoke-WebRequest -Uri "http://127.0.0.1:$p/" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes((& $mk 'B' '5\n' '25\n'))) -ContentType 'application/json' -UseBasicParsing
    }
    try {
        $null = @(Invoke-JkCpListen -Port $port -Timeout 60 -NoOpen 6>&1)
        Assert-Eq ([IO.File]::ReadAllText((Join-Path $root 'cf2000A\1.in'))) "1 2`n" 'first problem and its sample'
        Assert-Eq ([IO.File]::ReadAllText((Join-Path $root 'cf2000B\1.out'))) "25`n" 'the whole contest arrives'
        Assert-Eq (Resolve-JkLongPath (Get-Location).ProviderPath) (Resolve-JkLongPath (Join-Path $root 'cf2000A')) 'left in the first problem'
        # the judge's link and limits kept beside it, for jk cp test
        $pt = [IO.File]::ReadAllText((Join-Path $root 'cf2000B\problem.txt'))
        Assert-True ($pt -match 'B\. X \(Codeforces Round 2000 \(Div\. 2\)\)' -and $pt -match 'https://codeforces\.com/contest/2000/problem/B' -and $pt -match 'time 2 s, memory 256 MB') "problem.txt: $pt"
        $lim = Get-JkCpLimits (Join-Path $root 'cf2000B')
        Assert-Eq "$($lim.TimeMs) $($lim.MemoryMb)" '2000 256'
        Assert-Eq (Format-JkCpLimitNote 900 12 $lim) '' 'well inside'
        Assert-Eq (Format-JkCpLimitNote 1700 12 $lim) 'close to the 2 s limit'
        Assert-Eq (Format-JkCpLimitNote 2100 300 $lim) 'over the 2 s limit, over 256 MB'
        Assert-Eq (Format-JkCpLimitNote 2100 300 $null) '' 'no problem.txt: nothing to say'
        Save-JkCpLimits $root '' 1500 0
        Assert-Eq (Get-JkCpLimits $root).TimeMs 1500 'a fractional second'
    } finally {
        Receive-Job $job -Wait -ErrorAction SilentlyContinue | Out-Null; Remove-Job $job -Force
        Set-JkConfig 'cp.root' $savedRoot; Set-Location $here
    }
}
Test 'cp samples: N.in with .out/.ans, tests\ and test\ folders, old USACO I.N / O.N' {
    $dir = Join-Path $env:JK_HOME 'cp-samples'
    New-Item -ItemType Directory (Join-Path $dir 'test'), (Join-Path $dir 'tests') -Force | Out-Null
    foreach ($n in '1.in', '1.out', '2.in', '2.ans', 'I.1', 'O.1', 'I.10', 'O.10', 'I.2', 'test\sample-1.in', 'test\sample-1.out', 'tests\big.in', 'stress.in', 'I.txt') { Set-Content (Join-Path $dir $n) 'x' }
    $t = @(Get-JkCpTests $dir)
    Assert-Eq (($t | ForEach-Object { $_.Name }) -join ' ') '1 2 big I.1 I.2 I.10 sample-1' 'natural order; stress inputs and I.txt are not samples'
    Assert-Eq (Split-Path @($t | Where-Object { $_.Name -eq 'I.10' })[0].Ans -Leaf) 'O.10'
    Assert-Eq @($t | Where-Object { $_.Name -eq 'I.2' })[0].Ans $null 'I.2 has no O.2'
    Assert-Eq (Split-Path @($t | Where-Object { $_.Name -eq '2' })[0].Ans -Leaf) '2.ans'
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
Test 'jk pdf: photos upright, a page each, a valid PDF; natural order; images and PDFs merged; nothing overwritten' {
    Add-Type -AssemblyName System.Drawing
    $dir = Join-Path $env:JK_HOME 'pdf-work'
    New-Item -ItemType Directory $dir -Force | Out-Null
    $mk = { param($name, $w, $h, $orientation)
        $b = New-Object Drawing.Bitmap $w, $h
        $g = [Drawing.Graphics]::FromImage($b); $g.Clear([Drawing.Color]::SteelBlue); $g.Dispose()
        if ($orientation) {
            # an EXIF orientation tag, the way a phone held sideways writes it
            $pi = [Runtime.Serialization.FormatterServices]::GetUninitializedObject([Drawing.Imaging.PropertyItem])
            $pi.Id = 0x0112; $pi.Type = 3; $pi.Len = 2; $pi.Value = [byte[]]($orientation, 0)
            $b.SetPropertyItem($pi)
        }
        $fmt = [Drawing.Imaging.ImageFormat]::Jpeg; if ($name -like '*.png') { $fmt = [Drawing.Imaging.ImageFormat]::Png }
        $b.Save((Join-Path $dir $name), $fmt); $b.Dispose()
    }
    & $mk 'IMG_10.jpg' 300 200 0      # landscape
    & $mk 'IMG_2.jpg' 400 200 6       # stored sideways, tagged "rotate 90"
    & $mk 'notes.png' 200 300 0
    Assert-Eq (Get-JkRotateFlip 6) 'Rotate90FlipNone'
    $j = ConvertTo-JkJpegBytes (Join-Path $dir 'IMG_2.jpg')
    Assert-Eq "$($j.Width)x$($j.Height)" '200x400' 'turned upright by its EXIF tag'
    Assert-Eq "$($j.Bytes[0]) $($j.Bytes[1])" '255 216' 'JPEG bytes'
    $here = Get-Location
    try {
        Set-Location $dir
        $null = @(Invoke-JkPdf '*.jpg' 'notes.png' 6>&1)
        $out = Join-Path $dir 'pdf-work.pdf'
        $bytes = [IO.File]::ReadAllBytes($out)
        $text = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
        Assert-True ($text.StartsWith('%PDF-1.4') -and $text.TrimEnd().EndsWith('%%EOF')) 'header and trailer'
        Assert-Eq ([regex]::Matches($text, '/Type /Page\b').Count) 3 'a page per image'
        $boxes = @([regex]::Matches($text, '/MediaBox \[0 0 ([\d.]+) ([\d.]+)\]') | ForEach-Object { "$($_.Groups[1].Value)x$($_.Groups[2].Value)" })
        Assert-Eq ($boxes -join ' ') '612x792 792x612 612x792' 'IMG_2 (upright: portrait) before IMG_10 (landscape), then the PNG'
        # every xref offset points at its object
        $start = [int]([regex]::Match($text, 'startxref\s+(\d+)').Groups[1].Value)
        $entries = @([regex]::Matches($text.Substring($start), '(\d{10}) 00000 n') | ForEach-Object { [int]$_.Groups[1].Value })
        for ($k = 0; $k -lt $entries.Count; $k++) { Assert-True ($text.Substring($entries[$k]).StartsWith("$($k + 1) 0 obj")) "xref entry $($k + 1)" }
        # a second run never overwrites: "pdf-work (2).pdf"
        $null = @(Invoke-JkPdf '*.jpg' 6>&1)
        Assert-True (Test-Path (Join-Path $dir 'pdf-work (2).pdf')) 'kept the first, wrote a second'
        # images and a PDF together, when pypdf or pdfunite is there to merge
        $canMerge = $false
        $py = Get-Command python -ErrorAction SilentlyContinue
        if ($py) { $r = Invoke-JkProcess -Exe $py.Source -ArgList @('-c', 'import pypdf') -InputText '' -TimeoutMs 30000 -WorkDir $dir; $canMerge = $r.Code -eq 0 }
        if (-not $canMerge) { $canMerge = [bool](Get-Command pdfunite -ErrorAction SilentlyContinue) }
        if ($canMerge) {
            $null = @(Invoke-JkPdf 'notes.png' 'pdf-work.pdf' -Out 'all.pdf' 6>&1)
            $all = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes((Join-Path $dir 'all.pdf')))
            Assert-Eq ([regex]::Matches($all, '/Type\s*/Page\b').Count) 4 'one image page + the three'
        }
        Assert-Throws { Invoke-JkPdf 'nothing-here.jpg' 6>$null }
    } finally { Set-Location $here }
}
Test 'jk shots: per month and newest; file sorts older ones into month folders; tidy undo puts them back' {
    $dir = Join-Path $env:JK_HOME 'Screenshots'
    New-Item -ItemType Directory $dir -Force | Out-Null
    $now = Get-Date
    $mk = { param($name, $monthsAgo) $p = Join-Path $dir $name; Set-Content $p 'x'; (Get-Item $p).LastWriteTime = $now.AddMonths(-$monthsAgo).AddDays(-1); $p }
    $null = & $mk 'Screenshot new.png' 0
    $a = & $mk 'Screenshot a.png' 2
    $null = & $mk 'Screenshot b.png' 2
    $c = & $mk (([string][char]0x5C4F + [char]0x5E55) + ' c.png') 14   # a Chinese-named one, over a year old
    Set-Content (Join-Path $dir 'notes.txt') 'not a screenshot'
    (Get-Item (Join-Path $dir 'Screenshot new.png')).LastWriteTime = $now
    Assert-Eq @(Get-JkShots $dir).Count 4 'images only'
    $out = (Show-JkShots -Path $dir 6>&1 | ForEach-Object { "$_" }) -join "`n"
    Assert-True ($out -match 'jk shots file sorts 3 older ones') "file tip: $out"
    Assert-True ($out -match 'jk shots old: 1 older than a year') 'old tip'
    Assert-Eq (Split-Path @(Get-JkFindLast)[0] -Leaf) 'Screenshot new.png' 'newest first, numbered for jk find -o'
    $null = @(Invoke-JkShotsFile -Path $dir 6>&1)
    $month = $now.AddMonths(-2).AddDays(-1).ToString('yyyy-MM')
    Assert-True (Test-Path (Join-Path $dir "$month\Screenshot a.png")) 'filed by month'
    Assert-True (Test-Path (Join-Path $dir 'Screenshot new.png')) "this month's stay loose"
    Assert-True (Test-Path (Join-Path $dir 'notes.txt')) 'other files untouched'
    Assert-Eq @(Get-JkShots $dir).Count 4 'still counted inside the month folders'
    $null = @(Undo-JkTidy 6>&1)
    Assert-True ((Test-Path $a) -and (Test-Path $c)) 'jk tidy undo puts them back'
    Assert-True (-not (Test-Path (Join-Path $dir $month))) 'and removes the emptied month folder'
    $old = (Invoke-JkShotsOld -Path $dir 6>&1 | ForEach-Object { "$_" }) -join "`n"
    Assert-True ($old -match '1 file') "old: $old"
}
Test 'tidy: a partial download left for a week is offered by tidy old; nothing to move says so' {
    $dir = Join-Path $env:JK_HOME 'dl-partial'
    New-Item -ItemType Directory $dir -Force | Out-Null
    foreach ($n in 'live.crdownload', 'dead.tmp', 'new.pdf') { Set-Content (Join-Path $dir $n) $n }
    (Get-Item (Join-Path $dir 'dead.tmp')).LastWriteTime = (Get-Date).AddDays(-500)
    $out = (Invoke-JkTidyRun $dir -NoDupes 6>&1 | ForEach-Object { "$_" }) -join "`n"
    Assert-True ($out -match '1 partial download abandoned \(untouched for 500\+ days\)') "abandoned line: $out"
    Assert-True ($out -match 'left in place: 1 newer than 2 days, 1 unfinished download(?!s)') 'the live one is still unfinished'
    Assert-True ($out -match 'nothing for jk tidy apply to move right now' -and $out -notmatch 'moves 0') 'no "moves 0 files: into their course folders"'
    $old = (Invoke-JkTidyOld $dir 6>&1 | ForEach-Object { "$_" }) -join "`n"
    Assert-True ($old -match 'dead\.tmp' -and $old -notmatch 'live\.crdownload') 'only the abandoned one'
    # jk config says what an empty default comes to
    $cfg = (& { jk config } 6>&1 | ForEach-Object { "$_" }) -join "`n"
    Assert-True ($cfg -match 'tidy\.path\s+\(default: \S' -and $cfg -match 'sync\.url\s+\(default: not connected yet') "config: $cfg"
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
Test 'jk brief: an exam this week makes the line even behind three earlier deadlines, shown in date order' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH
    $env:JK_HOME = Join-Path $saved 'brief-exam'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $env:JK_NOW = '2026-11-13T20:00:00'; $env:JK_WIDTH = '200'
        $d = Get-JkDueData; $o = Resolve-JkCourse $d 'co367' -Create; $c = Resolve-JkCourse $d 'cs370' -Create; $h = Resolve-JkCourse $d 'health105' -Create
        $null = New-JkEvent -Data $d -Course $o.key -Date ([datetime]'2026-11-16') -Time '23:00' -Title 'Assignment 4' -Weight '5%'
        $null = New-JkEvent -Data $d -Course $h.key -Date ([datetime]'2026-11-16') -Time '23:59' -Title 'Assignment 7' -Weight '7.5%'
        $null = New-JkEvent -Data $d -Course $c.key -Date ([datetime]'2026-11-16') -Time '23:59' -Title 'Assignment 3' -Weight '7%'
        $null = New-JkEvent -Data $d -Course $o.key -Date ([datetime]'2026-11-19') -Time '08:30' -Title 'Quiz 3' -Kind 'exam' -Weight '20%'
        $null = New-JkEvent -Data $d -Course $c.key -Date ([datetime]'2026-11-20') -Time '23:59' -Title 'Assignment 9' -Weight '4%'
        Save-JkDueData $d
        $strip = { param($l) $l -replace "$([char]27)\[[0-9;]*m", '' }
        $line = & $strip (Get-JkBriefLine)
        Assert-True ($line -match 'CO367 Quiz 3 Thu') "the quiz is on the line: $line"
        Assert-True ($line -match 'Assignment 4 Mon .+ Quiz 3 Thu' -and $line -match '\+2') "date order, two more: $line"
        # anything due tomorrow still comes first
        $env:JK_NOW = '2026-11-15T20:00:00'
        $line = & $strip (Get-JkBriefLine)
        Assert-True (([regex]::Matches($line, 'tmrw')).Count -eq 3 -and $line -notmatch 'Quiz 3') "three due tomorrow beat the quiz: $line"
        # a narrow window drops the least pressing first, not the last on the line
        $env:JK_NOW = '2026-11-13T20:00:00'; $env:JK_WIDTH = '70'
        $line = & $strip (Get-JkBriefLine)
        Assert-True ($line -match 'Quiz 3') "narrow: the quiz stays: $line"
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'the dashboard nudges for missing marks before class sections, naming the course with the most weight missing' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH
    $env:JK_HOME = Join-Path $saved 'marks-nudge'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
    try {
        $env:JK_NOW = '2026-11-13T20:00:00'; $env:JK_WIDTH = '160'
        $d = Get-JkDueData
        Set-JkProp $d 'term' ([pscustomobject]@{ name = 'Fall 2026'; start = '2026-09-08'; classesEnd = '2026-12-08'; examsStart = '2026-12-10'; examsEnd = '2026-12-22' })
        $a = Resolve-JkCourse $d 'cs350' -Create; $b = Resolve-JkCourse $d 'cs341' -Create; $h = Resolve-JkCourse $d 'health105' -Create
        $null = New-JkEvent -Data $d -Course $a.key -Date ([datetime]'2026-10-01') -Time '20:00' -Title 'A1' -Weight '10%'
        $null = New-JkEvent -Data $d -Course $a.key -Date ([datetime]'2026-10-29') -Time '16:30' -Title 'Midterm' -Kind 'exam' -Weight '20%'
        $null = New-JkEvent -Data $d -Course $b.key -Date ([datetime]'2026-10-09') -Time '23:59' -Title 'Assignment 1' -Weight '4%'
        $null = New-JkEvent -Data $d -Course $h.key -Date ([datetime]'2026-10-20') -Time '23:59' -Title 'Midterm 1' -Kind 'exam' -Weight '35%'
        $null = New-JkEvent -Data $d -Course $a.key -Date ([datetime]'2026-12-17') -Time '16:00' -Title 'FINAL' -Kind 'exam' -Weight '40%'
        Save-JkDueData $d
        $n = Get-JkMarksNudge (Get-JkDueData) (Get-JkNow)
        Assert-Eq $n[0] 'jk grade import health105' 'by weight missing: HEALTH 105, 35%'
        $null = Invoke-JkConfig set plan.skip health105 6>&1; $script:JkConfigCache = $null
        $n = Get-JkMarksNudge (Get-JkDueData) (Get-JkNow)
        Assert-Eq $n[0] 'jk grade import cs350' 'a course left out of jk plan is not the one named'
        Assert-True ($n[1] -match '^4 past items have no mark yet \(CS 350 30% of the course\)') "why: $($n[1])"
        $dash = (Show-JkDashboard 6>&1 | ForEach-Object { "$_" }) -join "`n"
        Assert-True ($dash -match 'jk grade import cs350' -and $dash -notmatch 'jk class pick') "the dashboard shows it, ahead of class sections: $dash"
        # two missing are not worth a nudge
        $null = Invoke-JkGrade cs350 a1 80% 6>&1
        $null = Invoke-JkGrade cs350 midterm 70% 6>&1
        Assert-True ($null -eq (Get-JkMarksNudge (Get-JkDueData) (Get-JkNow))) 'fewer than 3 missing: no nudge'
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
}
Test 'jk review: a deadline that passed without a check mark, with a file named after it written by the deadline, reads as probably handed in' {
    $saved = $env:JK_HOME; $savedNow = $env:JK_NOW; $savedW = $env:JK_WIDTH
    $env:JK_HOME = Join-Path $saved 'handed-in'; $script:JkConfigCache = $null; $script:JkDueCache = $null
    try {
        $top = Join-Path $env:JK_HOME 'desk'
        $c = Join-Path $top 'Waterloo course\HEALTH105'
        New-Item -ItemType Directory $c -Force | Out-Null
        Set-JkConfig 'tidy.courses' $top
        $env:JK_NOW = '2026-11-13T20:00:00'; $env:JK_WIDTH = '120'
        $d = Get-JkDueData; $h = Resolve-JkCourse $d 'health105' -Create
        $a6 = New-JkEvent -Data $d -Course $h.key -Date ([datetime]'2026-11-09') -Time '23:59' -Title 'Assignment 6' -Weight '7.5%'
        $a5 = New-JkEvent -Data $d -Course $h.key -Date ([datetime]'2026-11-10') -Time '23:59' -Title 'Assignment 5' -Weight '7.5%'
        $a4 = New-JkEvent -Data $d -Course $h.key -Date ([datetime]'2026-11-11') -Time '23:59' -Title 'Assignment 4' -Weight '7.5%'
        Save-JkDueData $d
        # A6: a draft written that afternoon. A5: only the handout, two weeks before. A4: a file after the deadline
        $mk = { param($n, $t) $p = Join-Path $c $n; Set-Content $p 'x'; (Get-Item $p).LastWriteTime = [datetime]$t }
        & $mk 'HEALTH105_Assignment6_Draft.pdf' '2026-11-09T13:47'
        & $mk 'HEALTH105_Assignment5.pdf' '2026-10-27T10:00'
        & $mk 'Assignment4_notes.md' '2026-11-12T09:00'
        $out = @(Show-JkReview 6>&1 | ForEach-Object { "$_" })
        $txt = $out -join "`n"
        Assert-True ($txt -match '3 passed without a check mark') 'all three slipped'
        Assert-True ($txt -match 'HEALTH105_Assignment6_Draft\.pdf changed Mon 1:47 pm, before it was due') "A6's draft: $txt"
        Assert-True ($txt -notmatch 'HEALTH105_Assignment5\.pdf changed' -and $txt -notmatch 'Assignment4_notes\.md changed') 'not the handout two weeks before, not a file after the deadline'
        Assert-True ($txt -match "handed in\? jk due done $($a6.id)\s*$" -or ($out | Where-Object { $_ -match "handed in\? jk due done $($a6.id)$" })) 'the command, for A6 alone'
    } finally {
        $env:JK_HOME = $saved; $env:JK_NOW = $savedNow; $env:JK_WIDTH = $savedW; $script:JkConfigCache = $null; $script:JkDueCache = $null
    }
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
Test 'space clean jetbrains: only caches of versions no longer installed, never the newest' {
    Assert-Eq (ConvertTo-JkJetBrainsKey 'CLion 2024.2.1') 'CLion2024.2'
    Assert-Eq (ConvertTo-JkJetBrainsKey 'IntelliJ IDEA 2025.1.1.1') 'IntelliJIdea2025.1'
    Assert-Eq (ConvertTo-JkJetBrainsKey 'IntelliJ IDEA Community Edition 2024.3') 'IdeaIC2024.3'
    Assert-Eq (ConvertTo-JkJetBrainsKey 'PyCharm Community Edition 2023.3.3') 'PyCharmCE2023.3'
    Assert-Eq (ConvertTo-JkJetBrainsKey 'Google Chrome 130.0') $null
    $root = Join-Path $env:JK_HOME 'jb'
    foreach ($n in 'CLion2023.1', 'CLion2024.2', 'IntelliJIdea2025.1', 'PyCharmCE2022.1', 'PyCharmCE2023.3', 'consentOptions') { New-Item -ItemType Directory (Join-Path $root $n) -Force | Out-Null }
    $stale = @(Get-JkStaleJetBrainsCaches $root @('CLion2024.2', 'IntelliJIdea2025.1') | ForEach-Object { $_.Name } | Sort-Object)
    Assert-Eq ($stale -join ',') 'CLion2023.1,PyCharmCE2022.1' 'the newest PyCharmCE stays though Windows does not list it'
}
Test 'dashboard: tight on memory, the machine line names the biggest app' {
    $origMem = ${function:Get-JkMemory}; $origHogs = ${function:Get-JkMemoryHogs}
    function script:Get-JkMemoryHogs { param([int]$Top) [pscustomobject]@{ Name = 'chrome'; Mem = 3GB; Count = 28; Cpu = 0 } }
    try {
        function script:Get-JkMemory { [pscustomobject]@{ Total = 16GB; Free = 1.6GB } }
        $line = @(Show-JkDashboard 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'RAM' })[0]
        # sizes follow the culture: 3.0 GB, or 3,0 GB in the German CI pass
        Assert-True ($line -match 'RAM 90% \(chrome 3[.,]0 GB\)') "tight: $line"
        function script:Get-JkMemory { [pscustomobject]@{ Total = 16GB; Free = 8GB } }
        $line = @(Show-JkDashboard 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match 'RAM' })[0]
        Assert-True ($line -match 'RAM 50%' -and $line -notmatch 'chrome') "roomy: $line"
    } finally { Set-Item function:script:Get-JkMemory $origMem; Set-Item function:script:Get-JkMemoryHogs $origHogs }
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
Test 'config set: numbers and choices are checked, paths are stored in full' {
    $keys = 'remind.hours', 'plan.hours', 'cp.port', 'cp.timeout', 'tidy.minAge', 'focus.minutes', 'banner', 'cp.lang', 'cp.root', 'find.roots', 'tidy.courses', 'jobs.file'
    $set = { param($k, $v) Invoke-JkConfig set $k $v 6>&1 | Out-Null }
    $dir = Join-Path $env:JK_HOME 'cfg paths'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    try {
        # a value nothing can read used to be saved, and broke the morning run or jk plan later
        # (2d would not do: PowerShell reads it as the decimal number 2 before jk sees it)
        Assert-Throws { & $set remind.hours 48h } 'remind.hours takes a number of hours'
        Assert-Throws { & $set plan.hours 30 } 'more study hours than a day has'
        Assert-Throws { & $set cp.port 70000 } 'no such port'
        Assert-Throws { & $set cp.timeout 0 } 'a time limit of zero'
        Assert-Throws { & $set tidy.minAge 1.5 } 'tidy.minAge counts whole days'
        Assert-Throws { & $set focus.minutes soon } 'focus.minutes takes a length'
        Assert-Throws { & $set focus.minutes '50m later' } 'and only a length: the rest would become the label'
        Assert-Throws { & $set banner maybe } 'banner is on or off'
        Assert-Throws { & $set cp.lang rust } 'a language jk cp has'
        $msg = try { & $set plan.hours 30; '' } catch { $_.Exception.Message }
        Assert-True ($msg -match 'plan\.hours takes a number from 0 to 24') "says what it takes: $msg"
        & $set plan.hours '2,5'
        Assert-Eq (Get-JkConfig 'plan.hours') '2.5' 'a decimal comma is stored as a point'
        & $set focus.minutes 50m
        Assert-Eq (Get-JkConfig 'focus.minutes') '50m' 'a length with its unit'
        & $set banner no
        Assert-Eq (Get-JkConfig 'banner') 'off' 'no means off'
        & $set cp.lang Java
        Assert-Eq (Get-JkConfig 'cp.lang') 'java'
        Push-Location -LiteralPath $dir
        try {
            # the folder as the terminal has it: the long name even when $dir is 8.3 (JACKWA~1)
            $here = (Get-Location).ProviderPath
            & $set cp.root 'contests'
            & $set find.roots 'notes; %USERPROFILE%\Documents'
            & $set tidy.courses off
        } finally { Pop-Location }
        Assert-Eq (Get-JkConfig 'cp.root') (Join-Path $here 'contests') 'a relative folder is stored in full'
        Assert-Eq (Get-JkConfig 'find.roots') ((Join-Path $here 'notes') + ';%USERPROFILE%\Documents') 'each folder of a list, environment variables kept'
        Assert-Eq (Get-JkConfig 'tidy.courses') 'off' 'off stays off'
        Assert-Throws { & $set jobs.file (Join-Path $dir 'none.md') } 'a tracker that is not there'
        Set-Content -LiteralPath (Join-Path $dir 'job_application_tracker.md') -Value '| Date | Company | Role | Location | Status | Link |'
        & $set jobs.file $dir
        Assert-Eq (Get-JkConfig 'jobs.file') (Join-Path $dir 'job_application_tracker.md') 'the folder holding the tracker means the tracker'
    } finally { foreach ($k in $keys) { Invoke-JkConfig reset $k 6>&1 | Out-Null } }
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
        # a day keeps only what changed on it: by name alone, the newest snapshot of the file;
        # a day without it points at the one that has it
        $older = Join-Path $env:JK_HOME 'backups\2026-01-02'
        New-Item -ItemType Directory $older -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $older 'grades.json') -Value '{"scores":[],"extras":[],"targets":[],"nextExtra":1}'
        Assert-Eq (Get-JkNewestSnapshot 'grades') '2026-01-02'
        Assert-Eq (Get-JkNewestSnapshot 'todo') $day
        $msg = ''; try { Invoke-JkBackup restore $day grades } catch { $msg = $_.Exception.Message }
        Assert-True ($msg -match 'jk backup restore 2026-01-02 grades') "points at the snapshot: $msg"
        Add-JkTodo fourth item
        Invoke-JkBackup restore todo
        Assert-Eq @((Get-JkTodoData).items).Count 1 'restore todo = the newest snapshot of todo.json'
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
        # the week: a line per day with titles in full, not 10-column cells cut to "HEALTH105..."
        $week = @(Show-JkDueWeek 6>&1 | ForEach-Object { "$_" })
        $wed = @($week | Where-Object { $_ -match '^ Wed 28 ' })
        Assert-True ($wed.Count -eq 1 -and $wed[0] -match 'CS 350 A2A Synchronization') "Wed 28: $($wed -join ' / ')"
        Assert-True (@($week | Where-Object { $_ -match '^ Sat 24 ' }).Count -eq 1) 'every day has its line, empty ones too'
        $dayLines = @($week | Where-Object { $_ -match '^ (Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d|^ {9}\S' })
        Assert-True (-not @($dayLines | Where-Object { $_.Contains($script:G.ell) }).Count) "nothing cut: $($dayLines -join ' / ')"
        # a tip that does not fit wraps under itself instead of losing its end
        $tip = @(Write-JkTip '  new  jk net  ' 15 'Wi-Fi up but nothing loads? says whether it is the signal, the router, DNS or a sign-in page' 6>&1 | ForEach-Object { "$_" })
        Assert-True ($tip.Count -ge 2 -and -not @($tip | Select-Object -Skip 1 | Where-Object { -not $_.StartsWith(' ' * 15) }).Count -and -not ($tip -join '').Contains($script:G.ell)) "tip: $($tip -join ' / ')"
        Assert-Eq (($tip | ForEach-Object { $_.Trim() }) -join ' ') 'new  jk net  Wi-Fi up but nothing loads? says whether it is the signal, the router, DNS or a sign-in page' 'every word kept'
        $env:JK_WIDTH = '120'
        Assert-Eq @(Write-JkTip '  new  jk net  ' 15 'short enough' 6>&1).Count 1 'one line when it fits'
        Assert-True (@(Show-JkDueWeek 6>&1 | ForEach-Object { "$_" } | Where-Object { $_ -match '^ Mon 26 +Tue 27' }).Count -eq 1) 'wide windows keep the grid'
    } finally { $env:JK_WIDTH = $saved }
}
Test 'tab completion engine' {
    $names = { param($w, $t) @(Get-JkCompletions -Word $w -Tokens $t | ForEach-Object { $_.CompletionText }) }
    Assert-True ((& $names 'du' @('jk', 'du')) -contains 'due')
    Assert-True ((& $names '' @('jk', 'cp')) -contains 'stress')
    Assert-True ((& $names '' @('jk', 'cp', 'new', 'x')) -contains '-Lang')
    Assert-Eq ((& $names '' @('jk', 'cp', 'new', 'x', '-Lang')) -join ',') 'cpp,py,java,usaco'
    Assert-True ((& $names '' @('jk', 'due', 'add')) -contains 'cs350')
    # course codes: as the first word (jk cs341 is the course on a screen), and what can follow one
    Assert-True ((& $names 'cs3' @('jk', 'cs3')) -contains 'cs350') 'a course code as the first word'
    Assert-Eq ((& $names '' @('jk', 'cs350')) -join ',') 'exam,grade,grep,due,files,go' 'after a course'
    Assert-Eq ((& $names 'g' @('jk', 'cs', '350', 'g')) -join ',') 'grade,grep,go' 'after "cs 350"'
    Assert-True ((& $names '' @('jk', 'exam')) -contains 'cs350') 'jk exam <Tab> offers the courses'
    Assert-True ((& $names '' @('jk', 'grep')) -contains 'all') 'jk grep <Tab>: all, and the courses'
    Assert-True ((& $names '' @('jk', 'due')) -contains 'add') 'a command still completes its own words'
    Assert-Eq (Resolve-JkRoute @('co', '367')).Command 'config' 'no course called that here: the command it starts, as before'
}
Test 'no command takes a bare word into an option by accident (implicit positions)' {
    # PowerShell numbers a function's parameters in order when none says otherwise, so a catch-all for
    # the words beside another numbered parameter once had "jk pdf *.jpg *.png" bind *.png to -Out
    $common = [System.Management.Automation.Cmdlet]::CommonParameters + [System.Management.Automation.Cmdlet]::OptionalCommonParameters
    $entry = @($script:JkCommands.Values | ForEach-Object { $_.Fn }) + @($script:JkParamTargets.Values) | Select-Object -Unique
    $shape = {
        param($f)
        # PowerShell writes the positions it hands out into the attributes, so only the source says
        # which were written by hand (param() blocks and function F($x) signatures alike)
        $written = @{}
        $ast = $f.ScriptBlock.Ast
        $pas = @()
        if ($ast -is [Management.Automation.Language.FunctionDefinitionAst]) {
            if ($ast.Parameters) { $pas += @($ast.Parameters) }
            if ($ast.Body.ParamBlock) { $pas += @($ast.Body.ParamBlock.Parameters) }
        } elseif ($ast.ParamBlock) { $pas += @($ast.ParamBlock.Parameters) }
        foreach ($pa in $pas) {
            $written[$pa.Name.VariablePath.UserPath] = @($pa.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' } | ForEach-Object { $_.NamedArguments | Where-Object { $_.ArgumentName -eq 'Position' } }).Count -gt 0
        }
        foreach ($set in $f.ParameterSets) {
            $ps = @($set.Parameters | Where-Object { $common -notcontains $_.Name -and $_.Position -ge 0 -and $_.ParameterType -ne [switch] -and -not $written[$_.Name] })
            # the trap: a catch-all for the words beside another parameter PowerShell numbered too,
            # so the words are shared out between them
            if (@($ps | Where-Object { $_.ValueFromRemainingArguments }).Count -and @($ps | Where-Object { -not $_.ValueFromRemainingArguments }).Count) { ($ps | ForEach-Object { $_.Name }) -join ', ' }
        }
    }
    $bad = foreach ($name in $entry) {
        $f = Get-Item "function:$name" -ErrorAction SilentlyContinue
        if ($f) { $hit = @(& $shape $f); if ($hit.Count) { "$name ($($hit[0]))" } }
    }
    Assert-Eq (@($bad | Select-Object -Unique) -join '; ') ''
    # and the check itself catches the shape that went wrong ("jk pdf *.jpg *.png" binding *.png to -Out)
    function script:Test-JkOldShape { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Files, [string]$Out) }
    function script:Test-JkNewShape { [CmdletBinding(PositionalBinding = $false)] param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Files, [string]$Out) }
    try {
        Assert-Eq @(& $shape (Get-Item function:Test-JkOldShape)).Count 1 'the old jk pdf signature is caught'
        Assert-Eq @(& $shape (Get-Item function:Test-JkNewShape)).Count 0 'PositionalBinding off is fine'
    } finally { Remove-Item function:script:Test-JkOldShape, function:script:Test-JkNewShape }
}
Test 'the README names every command' {
    $readme = [IO.File]::ReadAllText((Join-Path (Get-JkRoot) 'README.md'))
    $missing = @($script:JkCommands.Keys | Where-Object { $readme -notmatch "``jk $_(\s|``)" })
    Assert-Eq ($missing -join ', ') '' 'commands the README never mentions (as `jk <command>`)'
}
Test 'jk help lists every command in its index, once' {
    $listed = @($script:JkHelpGroups.Values | ForEach-Object { $_ })
    $missing = @($script:JkCommands.Keys | Where-Object { $listed -notcontains $_ })
    Assert-Eq ($missing -join ', ') '' 'commands missing from the jk help index'
    Assert-Eq (@($listed | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }) -join ', ') '' 'listed twice'
    Assert-Eq (@($listed | Where-Object { -not $script:JkCommands.Contains($_) }) -join ', ') '' 'no such command'
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
Test 'file commands take a path literally: a [ in a name is not a wildcard' {
    # Test-Path $p is false for an existing "A [easy]\1.in", and jk cp add wrote over that sample
    $cmds = 'Test-Path', 'Get-Item', 'Get-ChildItem', 'Get-Content', 'Set-Content', 'Add-Content', 'Copy-Item', 'Move-Item', 'Rename-Item', 'Remove-Item', 'Resolve-Path', 'Out-File', 'Get-FileHash', 'Invoke-Item'
    $root = Get-JkRoot
    $found = foreach ($f in @(Get-ChildItem (Join-Path $root 'lib') -Filter *.ps1) + (Get-Item (Join-Path $root 'jk.psm1'))) {
        $errs = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
        foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $cmds -contains $n.GetCommandName() }, $true)) {
            $el = @($c.CommandElements)
            $loose = $false
            for ($i = 1; $i -lt $el.Count; $i++) {
                $e = $el[$i]
                if ($e -is [Management.Automation.Language.CommandParameterAst]) {
                    if ($e.ParameterName -ieq 'Path') { $loose = $true }
                    # the value of a parameter is not a positional path
                    if ($e.ParameterName -notmatch '^(?i)(Force|Recurse|File|Directory)$' -and -not $e.Argument) { $i++ }
                    continue
                }
                if ($e -is [Management.Automation.Language.StringConstantExpressionAst]) { continue }
                if ($e -is [Management.Automation.Language.VariableExpressionAst] -and $e.Splatted) { continue }
                if ($e.Extent.Text -match '^"function:') { continue }   # a command, not a file
                $loose = $true
            }
            if ($loose) { "$($f.Name):$($c.Extent.StartLineNumber) $($c.Extent.Text)" }
        }
    }
    Assert-Eq (@($found) -join "`n") '' 'paths passed without -LiteralPath'
}
Test 'no function assigns over a reserved variable, or puts a non-boolean in its own switch' {
    # names ignore case: $all in a function with [switch]$All throws, but only on a path that runs,
    # and $home is $HOME, which is read-only
    $reserved = 'home', 'pid', 'host', 'pshome', 'psversiontable', 'shellid', 'true', 'false', 'input', 'args', 'matches', 'error', 'this', 'foreach', 'switch', 'myinvocation', 'psscriptroot', 'pscommandpath', 'event', 'sender', 'profile', 'psitem', 'stacktrace', 'executioncontext', 'pscmdlet', 'psboundparameters'
    $root = Get-JkRoot
    $found = foreach ($f in @(Get-ChildItem (Join-Path $root 'lib') -Filter *.ps1) + (Get-Item (Join-Path $root 'jk.psm1'))) {
        $errs = $null; $ast = [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
        foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $params = @(); if ($fn.Parameters) { $params += @($fn.Parameters) }; if ($fn.Body.ParamBlock) { $params += @($fn.Body.ParamBlock.Parameters) }
            $switches = @($params | Where-Object { @($_.Attributes | Where-Object { $_ -is [Management.Automation.Language.TypeConstraintAst] -and $_.TypeName.FullName -eq 'switch' }).Count } | ForEach-Object { $_.Name.VariablePath.UserPath.ToLower() })
            foreach ($a in $fn.Body.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                $left = $a.Left; if ($left -is [Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
                if ($left -isnot [Management.Automation.Language.VariableExpressionAst]) { continue }
                $n = $left.VariablePath.UserPath.ToLower()
                if ($reserved -contains $n -or ($switches -contains $n -and $a.Right.Extent.Text -notmatch '^\$(true|false)$')) { "$($f.Name):$($a.Extent.StartLineNumber) `$$n" }
            }
        }
    }
    Assert-Eq (@($found) -join ', ') ''
}
Test 'this whole run left the real install alone: profiles, module link, morning task' {
    Assert-Eq (Get-RealInstallStamp) $global:JkRealInstall 'a test reached the real machine'
}

Remove-Module jk
Remove-Item $env:JK_HOME, $env:JK_CACHE -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $env:JK_SANDBOX) {
    # a junction must go on its own: a recursive delete can walk through it into the jk folder itself
    if (@(Get-ChildItem -LiteralPath $env:JK_SANDBOX -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue).Count) { Write-Host "left $env:JK_SANDBOX in place: it holds a link" -ForegroundColor Yellow }
    else { Remove-Item -LiteralPath $env:JK_SANDBOX -Recurse -Force -ErrorAction SilentlyContinue }
}
Remove-Item env:JK_NOW, env:JK_HOME, env:JK_CACHE, env:JK_SANDBOX, env:JK_COLOR, env:JK_WIDTH, env:JK_NONINTERACTIVE -ErrorAction SilentlyContinue

Write-Host ''
if ($script:failed.Count) {
    Write-Host "$($script:passed) passed, $($script:failed.Count) failed" -ForegroundColor Red
    $script:failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host "all $($script:passed) tests passed" -ForegroundColor Green
exit 0
