# course.ps1 - jk <course>: one course on a screen.   jk cs341  |  jk cs 341  |  jk health
# What is next (its exam, its deadlines), the marks so far and what the rest needs, its classes,
# the study jk plan has for it today and the newest files in its folder, numbered for jk find -o.
# A word after it goes to that command for the course: jk cs341 exam, jk cs341 grep lu.

# The course a command line starts with ("cs341", "cs 341", "health", "350"): its record and the
# words after it, or $null. Named whole, so a typo is an unknown command, not a course it happens
# to be inside ("nt" is in intv).
function Resolve-JkCourseWords([string[]]$Words) {
    $w = @($Words | Where-Object { $_ })
    if (-not $w.Count) { return $null }
    Resolve-JkNamedCourse (Get-JkDueData -Cached) $w -Alone
}

# "cs 350", as LEARN and the outlines write it, is one course word for the commands that take a
# course first. jk due add cs 350 A5 dec 2 made a course "cs" titled "350 A5", and jk exam cs 350,
# jk grade target cs 350 85 and jk class add cs 350 ... did not know the course. A pair at the
# first or second word is joined when it names a course you have; after "add" it is always one
# (a new term's first deadline or class names a course jk has not seen yet).
function Join-JkCourseWords([object[]]$Words) {
    $w = @($Words)
    for ($i = 0; $i -le [Math]::Min(1, $w.Count - 2); $i++) {
        # a bare 350 arrives as a number, not text
        $a = [string]$w[$i]; $b = [string]$w[$i + 1]
        if ($a -notmatch '^[A-Za-z]{2,8}$' -or $b -notmatch '^\d{2,3}[A-Za-z]?$') { continue }
        $n = Get-JkNormKey "$a$b"
        $c = @(@((Get-JkDueData -Cached).courses) | Where-Object { (Get-JkNormKey ([string]$_.key)) -eq $n -or (Get-JkNormKey ([string]$_.code)) -eq $n })[0]
        $joined = $null
        if ($c) { $joined = Get-JkNormKey ([string]$c.code); if (-not $joined) { $joined = [string]$c.key } }
        elseif ($i -eq 1 -and [string]$w[0] -match '^(?i)(add|new|\+)$') { $joined = $n }
        if (-not $joined) { continue }
        return @(@($w | Select-Object -First $i) + @($joined) + @($w | Select-Object -Skip ($i + 2)))
    }
    $w
}

# "today 7:00 pm", "tomorrow 11:59 pm", "Mon Nov 9 6:00 pm"
function Format-JkWhenShort([datetime]$When, [datetime]$Now) {
    $day = $When.ToString('ddd MMM d', $script:Inv)
    if ($When.Date -eq $Now.Date) { $day = 'today' } elseif ($When.Date -eq $Now.Date.AddDays(1)) { $day = 'tomorrow' }
    "$day $(Format-JkTime $When.ToString('HH:mm', $script:Inv))"
}

# A word after the course: that command, for this course.
function Invoke-JkCourseAction($Course, [string[]]$Rest) {
    $key = Get-JkNormKey ([string]$Course.code); if (-not $key) { $key = [string]$Course.key }
    $verb = ([string]$Rest[0]).ToLower()
    $more = @($Rest | Select-Object -Skip 1)
    $argv = @(@($key) + $more)
    switch -Regex ($verb) {
        '^(exams?|midterms?|final)$' { Invoke-JkExams @argv; return }
        '^(papers?|past)$' { $pv = @(@($key, 'papers') + $more); Invoke-JkExams @pv; return }
        '^(grades?|marks?|g)$' { Invoke-JkGrade @argv; return }
        '^(grep|inside|lookup|where)$' { Invoke-JkGrep @argv; return }
        '^(due|deadlines?|d)$' { Invoke-JkDue @argv; return }
        '^(files?)$' { if ($more.Count) { Show-JkDueFiles @argv } else { Show-JkCourseBrief $Course }; return }
        '^(go|cd|open|folder)$' { Invoke-JkGo $key; return }
    }
    throw "after a course: exam, papers, grade, grep <words>, due, files <deadline> or go (jk $key grep $($Rest -join ' '))"
}

function Show-JkCourseBrief($Course) {
    $data = Get-JkDueData
    $cmap = Get-JkCourseMap $data
    $now = Get-JkNow
    $c = $Course
    $key = Get-JkNormKey ([string]$c.code); if (-not $key) { $key = [string]$c.key }
    $dir = Get-JkCourseFolderFor $data $c.key
    Write-JkHeader (Get-JkCourseLabel ([pscustomobject]@{ course = $c.key }) $cmap) $(if ($dir) { Get-JkShortPath $dir } else { '' }) -Sub ([string]$c.name)
    $row = { param($k, $v) Say ('  ' + (Paint 'bold white' (Fit $k 9)) + $v) }
    $wrapRow = { param($k, $text, $style) Write-JkTip ('  ' + (Paint 'bold white' (Fit $k 9))) 11 $text $style -Indent 11 }

    # what is next: its exam, then up to four deadlines (an online quiz shows once, at its close)
    # (an exam being written stays until it is over, as on every other screen)
    $up = @($data.events | Where-Object { $_.course -eq $c.key -and -not $_.done -and [string]$_.title -notmatch '(?i)\sopens?$' -and ((Get-JkEventDue $_) -ge $now -or ($_.kind -eq 'exam' -and (Get-JkExamEnd $_) -gt $now)) } | Sort-Object { Get-JkEventDue $_ })
    $exam = @($up | Where-Object { $_.kind -eq 'exam' })[0]
    if ($exam) {
        $d = Get-JkEventDue $exam
        $days = [int]($d.Date - $now.Date).TotalDays
        $in = $(if ($days -ge 2) { " (in $days days)" } else { '' })
        $t = ([string]$exam.title -replace '(?i)\s+closes?$', '').Trim()
        # the closing half of an online window: "closes Tue Dec 8 11:59 pm"
        $verb = $(if ([string]$exam.title -match '(?i)\s+closes?$') { 'closes ' } else { '' })
        $whenTxt = "$verb$(Format-JkWhenShort $d $now)$in"
        if ($d -le $now) { $whenTxt = "under way, until $(Format-JkTime (Get-JkExamEnd $exam).ToString('HH:mm', $script:Inv))" }
        & $row 'exam' ((Paint 'bold white' $t) + (Paint 'muted' "  $whenTxt$(if ($exam.weight) { "  $($script:G.dot)  $($exam.weight)" })") + (Paint 'gray' "   $($script:G.arrow) jk exam $key"))
    }
    $dues = @($up | Where-Object { $_.kind -ne 'exam' } | Select-Object -First 4)
    if ($dues.Count) {
        & $wrapRow 'due' (($dues | ForEach-Object { "$(([string]$_.title -replace '(?i)\s+closes?$', '').Trim()) ($(Format-JkWhenShort (Get-JkEventDue $_) $now))" }) -join "  $($script:G.dot)  ") 'white'
        $more = @($up | Where-Object { $_.kind -ne 'exam' }).Count - $dues.Count
        if ($more -gt 0) { Say ((' ' * 11) + (Paint 'gray' "+$more more $($script:G.arrow) jk due $key")) }
    }
    if (-not $up.Count) { & $row 'next' (Paint 'green' "nothing coming up $($script:G.check)") }

    # a real course has marks and classes; an entry like Interviews has neither, so no hints about them
    $real = [string]$c.code -match '\d'
    # the marks so far, and what the rest needs
    try {
        $gd = Get-JkGradeData
        $m = Measure-JkGrade (Get-JkGradeItems $data $gd $c.key) (Get-JkGradeRules $data $c.key)
        $target = Get-JkTarget $gd $c.key
        if ($m.Graded -gt 0) {
            $need = Get-JkNeededText $target $m
            & $wrapRow 'marks' "$(Format-JkPct $m.Average) on the $(Format-JkPct $m.Graded 0) graded so far; $($need[0]) on the rest for $(Format-JkPct $target 0)  $($script:G.arrow) jk grade $key" 'muted'
        } elseif ($real) { & $row 'marks' (Paint 'gray' "none recorded yet $($script:G.dash) jk grade import $key copies them from LEARN") }
    } catch { }

    # its classes
    $cls = @((Get-JkClassData).items | Where-Object { $_.course -eq $c.key })
    if ($cls.Count) {
        & $wrapRow 'classes' (($cls | ForEach-Object { "$($_.kind) $(@($_.days) -join '/') $(Format-JkTime $_.start)$(if ($_.end) { "$($script:G.dash)$(Format-JkTime $_.end)" })$(if ($_.room) { " $($script:G.dot) $($_.room)" })" }) -join "   ") 'muted'
    } elseif ($real) { & $row 'classes' (Paint 'gray' "not on your timetable $($script:G.dash) jk class pick $key") }

    # the study jk plan has for it today, less what is already done; jk plan start only when what it
    # begins is this course (otherwise it starts another one), else a focus block on this one
    try {
        $p = Get-JkPlanToday
        if ($p) {
            $logged = Get-JkTodayFocusByCourse $now
            $mine = @(Get-JkPlanLeft $p $logged | Where-Object { $_.Item.Course -eq $c.key -and $_.Want -gt 0 })
            $want = 0.0; $left = 0.0
            foreach ($r in $mine) { $want += $r.Want; $left += $r.Left }
            if ($want -gt 0) {
                if ($left -le 0) { & $row 'study' (Paint 'green' "$(Format-JkMinutes $want) today, done $($script:G.check)") }
                else {
                    $txt = $(if ($left -lt $want) { "$(Format-JkMinutes $left) left of $(Format-JkMinutes $want) today" } else { "$(Format-JkMinutes $want) today" })
                    $next = Get-JkPlanNext $p $logged
                    $hint = 'jk plan start'
                    if (-not $next -or $next.Course -ne $c.key) {
                        $top = @($mine | Where-Object { $_.Left -gt 0 } | Sort-Object @{ e = { - $_.Left } }, @{ e = { $_.Item.Due } })[0]
                        $hint = "jk focus $($script:PlanBlock) $key $(([string]$top.Item.Title).ToLower())"
                    }
                    & $row 'study' ((Paint 'white' $txt) + (Paint 'gray' "   $($script:G.arrow) $hint"))
                }
            }
        }
    } catch { }

    # the newest files in its folder: what you were last working on
    if ($dir) {
        $files = @(Find-JkFiles @() @($dir) -Since ([datetime]'1900-01-01') | Where-Object { -not (Test-JkRecentNoise $_) } | Sort-Object Modified -Descending | Select-Object -First 5)
        Say ''
        if ($files.Count) {
            Save-JkFindLast $files
            Say (' ' + (Paint 'bold white' 'Newest files') + (Paint 'gray' "  in $(Get-JkShortPath $dir)"))
            Write-JkFindRows $files
        } else { Say (Paint 'gray' "  $(Get-JkShortPath $dir) is empty"); Say '' }
    } else { Say ''; Say (Paint 'gray' "  no folder for it found (jk config set tidy.courses <the folder holding your course folders>)"); Say '' }
    Say (Paint 'gray' "  jk $key exam  $($script:G.dot)  jk $key grade  $($script:G.dot)  jk $key grep <words>  $($script:G.dot)  jk $key files <deadline>  $($script:G.dot)  j $key")
}
