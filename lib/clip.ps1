# clip.ps1 - jk clip: the clipboard's text, counted and cleaned.
#   jk clip            words, characters and lines, with a preview
#   jk clip unwrap     text copied from a PDF: wrapped lines joined into paragraphs, split words mended
#   jk clip plain      the same text with its formatting dropped (fonts, links, colours)

# bullets that start a new line even inside a paragraph: - * + and the round/square/dash glyphs
$script:JkBulletRx = & {
    $glyphs = -join @([char]0x2022, [char]0x25CF, [char]0x25AA, [char]0x25E6, [char]0x2013, [char]0x2014)
    '^\s*([-*+' + [regex]::Escape($glyphs) + ']|\(?\d{1,2}[.)]|\(?[a-z][.)])\s+'
}

# Rejoin text wrapped at a fixed width (a PDF, an email): the lines of a paragraph become one,
# "optimi-" + "zation" becomes "optimization", and Chinese lines join without a space. Blank
# lines and bullets stay, and so does the end of a paragraph that has no blank line after it: a
# line well short of the others that ends a sentence.
function ConvertFrom-JkWrappedText([string]$Text) {
    $lines = @(($Text -replace "`r`n?", "`n") -split "`n")
    $width = [int](@($lines | ForEach-Object { $_.TrimEnd().Length }) | Measure-Object -Maximum).Maximum
    $paras = New-Object System.Collections.Generic.List[string]
    $cur = ''
    $mended = 0
    foreach ($raw in $lines) {
        $l = $raw.Trim()
        if ($l -eq '') {
            if ($cur) { $paras.Add($cur); $cur = '' }
            if ($paras.Count -and $paras[$paras.Count - 1] -ne '') { $paras.Add('') }
            continue
        }
        if ($cur -and $l -match $script:JkBulletRx) { $paras.Add($cur); $cur = '' }
        if (-not $cur) { $cur = $l }
        elseif ($cur -cmatch '\p{L}-$' -and $l -cmatch '^\p{Ll}') { $cur = $cur.Substring(0, $cur.Length - 1) + $l; $mended++ }
        # a real hyphen at the end of the line ("COVID-" + "19", "Hartree-" + "Fock") stays, unspaced
        elseif ($cur -cmatch '\p{L}-$' -and $l -cmatch '^[\p{Lu}\p{Nd}]') { $cur += $l }
        elseif ("$($cur[-1])" -match $script:JkWideRx -and "$($l[0])" -match $script:JkWideRx) { $cur += $l }
        else { $cur += " $l" }
        if ($width -ge 30 -and $raw.TrimEnd().Length -lt 0.6 * $width -and $l -match '[.!?:;)"]$') { $paras.Add($cur); $cur = '' }
    }
    if ($cur) { $paras.Add($cur) }
    while ($paras.Count -and $paras[$paras.Count - 1] -eq '') { $paras.RemoveAt($paras.Count - 1) }
    [pscustomobject]@{ Text = (@($paras) -join "`n"); Mended = $mended; Paragraphs = @($paras | Where-Object { $_ -ne '' }).Count }
}

# Words the way a word limit counts them, with Chinese, Japanese and Korean counted by character.
function Measure-JkText([string]$Text) {
    [pscustomobject]@{
        Words  = [regex]::Matches($Text, "[\p{Lu}\p{Ll}\p{Lt}\p{Nd}][\p{Lu}\p{Ll}\p{Lt}\p{Nd}'\-]*").Count
        Cjk    = [regex]::Matches($Text, '\p{Lo}').Count
        Chars  = $Text.Length
        NoSpace = ($Text -replace '\s', '').Length
        Lines  = @(($Text -replace "`r`n?", "`n").TrimEnd("`n") -split "`n").Count
    }
}

function Format-JkTextCounts($M) {
    $bits = @(Format-JkCount $M.Words 'word')
    if ($M.Cjk) { $bits += "$($M.Cjk) CJK characters" }
    $bits += "$($M.Chars) characters ($($M.NoSpace) without spaces)"
    $bits += Format-JkCount $M.Lines 'line'
    $bits -join " $($script:G.dot) "
}

function Get-JkClipText {
    $t = Get-JkClipboardText
    if (-not $t -or -not $t.Trim()) { throw 'the clipboard has no text' }
    $t
}

function Show-JkClip {
    $t = Get-JkClipText
    $m = Measure-JkText $t
    $w = Get-JkWidth
    Write-JkHeader 'Clipboard' (Format-JkTextCounts $m)
    foreach ($l in @(($t -replace "`r`n?", "`n") -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 3)) { Say ('  ' + (Paint 'muted' (Fit $l.Trim() ($w - 3)).TrimEnd())) }
    Say ''
    Say ((Paint 'gray' '  jk clip unwrap ') + (Paint 'muted' 'join lines wrapped by a PDF') + (Paint 'gray' "  $($script:G.dot)  jk clip plain ") + (Paint 'muted' 'drop the formatting'))
}

function Invoke-JkClipUnwrap {
    $t = Get-JkClipText
    $r = ConvertFrom-JkWrappedText $t
    $before = (Measure-JkText $t).Lines
    Set-Clipboard -Value $r.Text
    $note = "$before lines $($script:G.arrow) $(Format-JkCount $r.Paragraphs 'paragraph')"
    if ($r.Mended) { $note += ", $(Format-JkCount $r.Mended 'split word') mended" }
    Say ((Paint 'green' "  unwrapped $($script:G.check)  ") + $note + (Paint 'gray' '  (on the clipboard now)'))
}

function Invoke-JkClipPlain {
    $t = Get-JkClipText
    Set-Clipboard -Value $t
    Say ((Paint 'green' "  plain text $($script:G.check)  ") + (Format-JkTextCounts (Measure-JkText $t)) + (Paint 'gray' '  (formatting dropped)'))
}

function Invoke-JkClip {
    $a = @($args)
    if ($a.Count -eq 0) { Show-JkClip; return }
    $first = ([string]$a[0]).ToLower()
    switch -Regex ($first) {
        '^(count|wc|words)$' { Show-JkClip; return }
        '^(unwrap|join|fix|pdf)$' { Invoke-JkClipUnwrap; return }
        '^(plain|text|strip)$' { Invoke-JkClipPlain; return }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'clip'; return }
    }
    throw "unknown 'clip' action '$first' (try: jk clip help)"
}
