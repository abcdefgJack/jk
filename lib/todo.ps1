# todo.ps1 - a tiny to-do list:  jk todo "email recruiter" -Due fri

function Get-JkTodoData {
    $d = Read-JkJson 'todo.json' $null
    if (-not $d) { $d = [pscustomobject]@{ nextId = 1; items = @() } }
    if ($null -eq (Get-JkProp $d 'items')) { Set-JkProp $d 'items' @() }
    if (-not (Get-JkProp $d 'nextId')) { Set-JkProp $d 'nextId' 1 }
    $d
}

function Save-JkTodoData($Data) {
    $Data.items = @($Data.items)
    Save-JkJson 'todo.json' $Data
    Clear-JkBriefCache
}

function Get-JkTodoDue($Item) {
    $d = Get-JkProp $Item 'due'
    if (-not $d) { return $null }
    [datetime]::Parse([string]$d, [Globalization.CultureInfo]::InvariantCulture)
}

function Format-JkTodoLine($Item, [int]$Width, [datetime]$Now = (Get-JkNow)) {
    $mark = $script:G.ring
    $style = 'white'
    if ($Item.done) { $mark = $script:G.check; $style = 'gray strike' }
    $dueTxt = ''
    $dueStyle = 'gray'
    $due = Get-JkTodoDue $Item
    if ($due) {
        $dueTxt = $due.ToString('ddd MMM d', [Globalization.CultureInfo]::InvariantCulture)
        if ($due.TimeOfDay.TotalMinutes -gt 0) { $dueTxt += ' ' + (Format-JkTime $due.ToString('HH:mm')) }
        $rel = Format-JkRelDay $due $Now
        $dueTxt += "  $rel"
        if (-not $Item.done) {
            $days = ($due.Date - $Now.Date).TotalDays
            if ($days -lt 0) { $dueStyle = 'bold red'; $dueTxt = "overdue $($script:G.dot) $dueTxt" }
            elseif ($days -eq 0) { $dueStyle = 'bold orange' }
            elseif ($days -le 2) { $dueStyle = 'yellow' }
        }
    }
    $textW = [Math]::Max(12, $Width - 8 - $dueTxt.Length - 2)
    '  ' + (Paint 'gray' ("$($Item.id)".PadLeft(3))) + ' ' + (Paint $(if ($Item.done) { 'green' } else { 'muted' }) $mark) + ' ' + (Paint $style (Fit ([string]$Item.text) $textW)) + '  ' + (Paint $dueStyle $dueTxt)
}

function Show-JkTodo {
    param([switch]$All)
    $d = Get-JkTodoData
    $now = Get-JkNow
    $open = @($d.items | Where-Object { -not $_.done } | Sort-Object @{ Expression = { $x = Get-JkTodoDue $_; if ($x) { $x } else { [datetime]::MaxValue } } }, id)
    $doneToday = @($d.items | Where-Object { $_.done -and $_.doneAt -and ([datetime]::Parse([string]$_.doneAt, [Globalization.CultureInfo]::InvariantCulture)).Date -eq $now.Date })
    $doneAll = @($d.items | Where-Object { $_.done })
    Write-JkHeader 'To-do' "$($open.Count) open $($script:G.dot) $($doneToday.Count) done today"
    $w = Get-JkWidth
    if ($open.Count -eq 0) { Say (Paint 'green' "  All clear. $($script:G.check)") }
    foreach ($i in $open) { Say (Format-JkTodoLine $i $w $now) }
    $shown = $doneToday
    if ($All) { $shown = $doneAll }
    if ($shown.Count) {
        Say ''
        foreach ($i in $shown) { Say (Format-JkTodoLine $i $w $now) }
    }
    Say ''
    Say (Paint 'gray' "  jk todo <text> [-Due fri]  $($script:G.dot)  jk todo done <id>  $($script:G.dot)  jk todo clear")
}

function Test-JkWhen([string]$Text) {
    try { $null = ConvertFrom-JkWhen $Text; $true } catch { $false }
}

# `-Due dec 18 5pm` without quotes binds only "dec": the rest lands at the end of the text. Gives
# those words back to the due date; returns the due text and the words left.
function Join-JkDueWords([string]$Due, [string[]]$Words, [switch]$TakeAll) {
    $w = @($Words | Where-Object { $_ })
    $min = 1; if ($TakeAll) { $min = 0 }   # adding keeps a word of text; editing needs none
    if (-not $Due -or $w.Count -lt $min + 1) { return , @($Due, $w) }
    if (-not (Test-JkWhen $Due)) {
        for ($k = 1; $k -le [Math]::Min(3, $w.Count - $min); $k++) {
            $cand = "$Due $(($w[($w.Count - $k)..($w.Count - 1)]) -join ' ')"
            if (Test-JkWhen $cand) { return , @($cand, @($w | Select-Object -First ($w.Count - $k))) }
        }
    } elseif ($w.Count -ge $min + 1 -and $w[-1] -match '^\d{1,2}(:\d{2})?\s*(am|pm)$|^\d{1,2}:\d{2}$') {
        # `-Due tomorrow 6pm`
        return , @("$Due $($w[-1])", @($w | Select-Object -First ($w.Count - 1)))
    }
    , @($Due, $w)
}

# "pay rent nov 1", "email prof by friday", "call mom at 7pm": a date phrase at the end of the
# words is the due date. After by/due/on/before/until/at anything jk reads as a date counts; with
# no such word, only what is plainly a date (a weekday or month name, tomorrow, 7pm, 10/30), so
# "read chapter 4" and "dry clothes in the sun" stay text. Returns the due text ('' for none) and
# the words left. A quoted text arrives as one word and is left alone.
function Split-JkTrailingWhen([string[]]$Words) {
    $w = @($Words)
    $conn = '^(by|due|on|before|until|till|at)$'
    $plain = '(?i)\b(today|tonight|tomorrow|tmrw?|next|monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues?|thu|thurs?|fri)\b|\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\s+\d|^\d{1,2}\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)|\d\s*(am|pm)\b|\d:\d\d|^\d{4}-\d{2}-\d{2}$|^\d{1,2}/\d{1,2}(/\d{2,4})?$|^in\s+(\d+|a|an|one)\s+(days?|weeks?)$|\b(sat|sun|wed)\b.*\d|^(next|this)\s'
    for ($k = [Math]::Min(4, $w.Count - 1); $k -ge 1; $k--) {
        $phrase = ($w[($w.Count - $k)..($w.Count - 1)]) -join ' '
        if ($w[$w.Count - $k] -match $conn) { continue }
        $hasConn = $w[$w.Count - $k - 1] -match $conn
        $keep = $w.Count - $k - $(if ($hasConn) { 1 } else { 0 })
        if ($keep -lt 1) { continue }
        if ($phrase -match '^\+?\d+[dw]?$') { continue }   # "chapter 4", "print 3d"
        if (-not $hasConn -and $phrase -notmatch $plain) { continue }
        if (-not (Test-JkWhen $phrase)) { continue }
        return , @($phrase, @($w[0..($keep - 1)]))
    }
    , @('', $w)
}

function ConvertTo-JkTodoDue([string]$Due) {
    $w = ConvertFrom-JkWhen $Due
    $dt = $w.Date
    if ($w.Time) { $p = $w.Time.Split(':'); $dt = $dt.AddHours([int]$p[0]).AddMinutes([int]$p[1]) }
    $dt.ToString('s', [Globalization.CultureInfo]::InvariantCulture)
}

function Add-JkTodo {
    param([Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Text, [string]$Due)
    $words = @($Text | Where-Object { $_ -ne $null -and "$_" -ne '' })
    $r = Join-JkDueWords $Due $words; $Due = $r[0]; $words = @($r[1])
    if (-not $Due) { $r = Split-JkTrailingWhen $words; $Due = $r[0]; $words = @($r[1]) }
    $t = (@($words) -join ' ').Trim()
    if (-not $t) { throw 'usage: jk todo add <text> [-Due fri|tomorrow 5pm|oct 30]' }
    $d = Get-JkTodoData
    $dueIso = $null
    if ($Due) { $dueIso = ConvertTo-JkTodoDue $Due }
    $item = [pscustomobject][ordered]@{ id = [int]$d.nextId; text = $t; created = (Get-JkNow).ToString('s', [Globalization.CultureInfo]::InvariantCulture); due = $dueIso; done = $false; doneAt = $null }
    $d.nextId = [int]$d.nextId + 1
    $d.items = @($d.items) + $item
    Save-JkTodoData $d
    Say ((Paint 'green' "  added $($script:G.check)") + (Format-JkTodoLine $item ((Get-JkWidth) - 10)))
}

function Find-JkTodo($Data, [string[]]$Refs, [switch]$DoneOnly, [switch]$Any) {
    foreach ($r in $Refs) {
        if ($r -match '^\d+$') {
            $hit = @($Data.items | Where-Object { [int]$_.id -eq [int]$r })
            if (-not $hit) { throw "no to-do #$r" }
            $hit[0]
        } else {
            $hit = @($Data.items | Where-Object { ($Any -or [bool]$_.done -eq [bool]$DoneOnly) -and ([string]$_.text).ToLower().Contains($r.ToLower()) })
            if ($hit.Count -ne 1) { throw "'$r' matches $($hit.Count) $(if ($Any) { '' } elseif ($DoneOnly) { 'finished ' } else { 'open ' })to-dos; use the number" }
            $hit[0]
        }
    }
}

function Set-JkTodoDone {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Refs, [switch]$Undo)
    if (-not $Refs) { throw "usage: jk todo $(if ($Undo) { 'undo' } else { 'done' }) <id> [...]" }
    $d = Get-JkTodoData
    foreach ($i in @(Find-JkTodo $d $Refs -DoneOnly:$Undo)) {
        $i.done = -not $Undo
        Set-JkProp $i 'doneAt' $(if ($Undo) { $null } else { (Get-JkNow).ToString('s', [Globalization.CultureInfo]::InvariantCulture) })
        if ($Undo) { Say ((Paint 'yellow' '  reopened') + "  $($i.id) $($i.text)") }
        else { Say ((Paint 'green' "  done $($script:G.check)") + "  $($i.id) $($i.text)") }
    }
    Save-JkTodoData $d
}

function Remove-JkTodo {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Refs)
    $d = Get-JkTodoData
    $hits = @(Find-JkTodo $d $Refs -Any)
    $ids = @($hits | ForEach-Object { [int]$_.id })
    $d.items = @($d.items | Where-Object { $ids -notcontains [int]$_.id })
    Save-JkTodoData $d
    foreach ($i in $hits) { Say ((Paint 'red' '  removed') + "  $($i.id) $($i.text)") }
}

# Drops finished items and renumbers the rest from 1 so ids stay short.
function Clear-JkTodo {
    $d = Get-JkTodoData
    $open = @($d.items | Where-Object { -not $_.done } | Sort-Object id)
    $removed = @($d.items).Count - $open.Count
    $n = 1
    foreach ($i in $open) { $i.id = $n; $n++ }
    $d.items = $open
    $d.nextId = $n
    Save-JkTodoData $d
    Say ((Paint 'green' "  cleared $removed finished item$(if ($removed -ne 1) {'s'})") + (Paint 'gray' ' (open items renumbered)'))
}

function Edit-JkTodo {
    param([Parameter(Position = 0)][string]$Ref, [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Text, [string]$Due, [switch]$NoDue)
    if (-not $Ref) { throw 'usage: jk todo edit <id> [new text] [-Due fri] [-NoDue]' }
    $d = Get-JkTodoData
    $i = @(Find-JkTodo $d @($Ref) -Any)[0]
    $words = @($Text | Where-Object { $_ })
    $r = Join-JkDueWords $Due $words -TakeAll; $Due = $r[0]; $words = @($r[1])
    if ($words) { $i.text = ($words -join ' ') }
    if ($Due) { Set-JkProp $i 'due' (ConvertTo-JkTodoDue $Due) }
    if ($NoDue) { Set-JkProp $i 'due' $null }
    Save-JkTodoData $d
    Say ((Paint 'green' '  updated') + (Format-JkTodoLine $i ((Get-JkWidth) - 10)))
}

function Invoke-JkTodo {
    $a = @($args)
    if ($a.Count -eq 0) { Show-JkTodo; return }
    $first = [string]$a[0]
    $rest = @()
    if ($a.Count -gt 1) { $rest = @($a[1..($a.Count - 1)]) }
    switch -Regex ($first.ToLower()) {
        '^(add|new|\+)$' { Add-JkTodo @rest; return }
        '^(done|x|check|finish)$' {
            # "finish essay tonight" is a new to-do; "finish 3" checks one off
            if ($first -match '^(?:check|finish)$' -and @($rest | Where-Object { "$_" -notmatch '^\d+$' }).Count) { Add-JkTodo @a } else { Set-JkTodoDone @rest }
            return
        }
        '^(undo|undone|reopen)$' { Set-JkTodoDone -Undo @rest; return }
        '^(rm|remove|del|delete)$' { Remove-JkTodo @rest; return }
        # with more words it is a to-do ("clear the desk"), not the destructive cleanup
        '^(clear|clean|purge)$' { if ($rest.Count) { Add-JkTodo @a } else { Clear-JkTodo }; return }
        '^(edit|set)$' { Edit-JkTodo @rest; return }
        '^(all|ls|list)$' { if ($rest.Count) { Add-JkTodo @a } else { Show-JkTodo -All }; return }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'todo'; return }
    }
    # anything else is the text of a new item:  jk todo buy milk -Due tomorrow
    Add-JkTodo @a
}
