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

function Add-JkTodo {
    param([Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Text, [string]$Due)
    $words = @($Text | Where-Object { $_ -ne $null -and "$_" -ne '' })
    # `-Due tomorrow 6pm` without quotes leaves "6pm" at the end of the text: give it back to -Due
    if ($Due -and $words.Count -gt 1 -and $words[-1] -match '^\d{1,2}(:\d{2})?\s*(am|pm)$|^\d{1,2}:\d{2}$') {
        $Due = "$Due $($words[-1])"
        $words = @($words[0..($words.Count - 2)])
    }
    $t = ($words -join ' ').Trim()
    if (-not $t) { throw 'usage: jk todo add <text> [-Due fri|tomorrow 5pm|oct 30]' }
    $d = Get-JkTodoData
    $dueIso = $null
    if ($Due) {
        $w = ConvertFrom-JkWhen $Due
        $dt = $w.Date
        if ($w.Time) { $p = $w.Time.Split(':'); $dt = $dt.AddHours([int]$p[0]).AddMinutes([int]$p[1]) }
        $dueIso = $dt.ToString('s', [Globalization.CultureInfo]::InvariantCulture)
    }
    $item = [pscustomobject][ordered]@{ id = [int]$d.nextId; text = $t; created = (Get-JkNow).ToString('s', [Globalization.CultureInfo]::InvariantCulture); due = $dueIso; done = $false; doneAt = $null }
    $d.nextId = [int]$d.nextId + 1
    $d.items = @($d.items) + $item
    Save-JkTodoData $d
    Say ((Paint 'green' "  added $($script:G.check)") + (Format-JkTodoLine $item ((Get-JkWidth) - 10)))
}

function Find-JkTodo($Data, [string[]]$Refs) {
    foreach ($r in $Refs) {
        if ($r -match '^\d+$') {
            $hit = @($Data.items | Where-Object { [int]$_.id -eq [int]$r })
            if (-not $hit) { throw "no to-do #$r" }
            $hit[0]
        } else {
            $hit = @($Data.items | Where-Object { -not $_.done -and ([string]$_.text).ToLower().Contains($r.ToLower()) })
            if ($hit.Count -ne 1) { throw "'$r' matches $($hit.Count) open to-dos; use the number" }
            $hit[0]
        }
    }
}

function Set-JkTodoDone {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Refs, [switch]$Undo)
    if (-not $Refs) { throw 'usage: jk todo done <id> [...]' }
    $d = Get-JkTodoData
    foreach ($i in @(Find-JkTodo $d $Refs)) {
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
    $hits = @(Find-JkTodo $d $Refs)
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
    $d = Get-JkTodoData
    $i = @(Find-JkTodo $d @($Ref))[0]
    if ($Text) { $i.text = ($Text -join ' ') }
    if ($Due) {
        $w = ConvertFrom-JkWhen $Due
        $dt = $w.Date
        if ($w.Time) { $p = $w.Time.Split(':'); $dt = $dt.AddHours([int]$p[0]).AddMinutes([int]$p[1]) }
        Set-JkProp $i 'due' ($dt.ToString('s', [Globalization.CultureInfo]::InvariantCulture))
    }
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
        '^(done|x|check|finish)$' { Set-JkTodoDone @rest; return }
        '^(undo|undone|reopen)$' { Set-JkTodoDone -Undo @rest; return }
        '^(rm|remove|del|delete)$' { Remove-JkTodo @rest; return }
        '^(clear|clean|purge)$' { Clear-JkTodo; return }
        '^(edit|set)$' { Edit-JkTodo @rest; return }
        '^(all|ls|list)$' { Show-JkTodo -All; return }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'todo'; return }
    }
    # anything else is the text of a new item:  jk todo buy milk -Due tomorrow
    Add-JkTodo @a
}
