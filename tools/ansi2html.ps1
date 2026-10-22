# ansi2html.ps1 - render jk's colored terminal output as an HTML page (for reviewing the look
# without a screenshot). Usage:
#   powershell -NoProfile -File tools\ansi2html.ps1 -Out preview.html -Commands 'jk|jk due|jk sys'
param([string]$Out = 'preview.html', [string]$Commands = 'jk', [int]$Width = 110, [string]$Background = '#0C0C0C', [string]$Foreground = '#CCCCCC')

$root = Split-Path -Parent $PSScriptRoot
$esc = [char]27
$blocks = foreach ($cmd in ($Commands -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    # Write-Host goes to the host (stream 6), not stdout: fold it into the output we capture
    $script = "`$env:JK_COLOR='always'; `$env:JK_WIDTH='$Width'; Import-Module '$root\jk.psd1'; & { $cmd } 6>&1 | ForEach-Object { `"`$_`" }"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $raw = (& powershell -NoProfile -EncodedCommand $enc 2>&1 | Out-String -Width 400)
    $html = New-Object Text.StringBuilder
    $open = $false
    $pos = 0
    foreach ($m in [regex]::Matches($raw, "$esc\[([0-9;]*)m")) {
        [void]$html.Append([Net.WebUtility]::HtmlEncode($raw.Substring($pos, $m.Index - $pos)))
        $pos = $m.Index + $m.Length
        if ($open) { [void]$html.Append('</span>'); $open = $false }
        $codes = @($m.Groups[1].Value -split ';' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
        if ($codes.Count -eq 0 -or ($codes.Count -eq 1 -and $codes[0] -eq 0)) { continue }
        $css = @()
        for ($i = 0; $i -lt $codes.Count; $i++) {
            switch ($codes[$i]) {
                1 { $css += 'font-weight:700' }
                2 { $css += 'opacity:.6' }
                3 { $css += 'font-style:italic' }
                4 { $css += 'text-decoration:underline' }
                9 { $css += 'text-decoration:line-through' }
                38 { if ($codes[$i + 1] -eq 2) { $css += ('color:rgb({0},{1},{2})' -f $codes[$i + 2], $codes[$i + 3], $codes[$i + 4]); $i += 4 } }
                48 { if ($codes[$i + 1] -eq 2) { $css += ('background:rgb({0},{1},{2})' -f $codes[$i + 2], $codes[$i + 3], $codes[$i + 4]); $i += 4 } }
            }
        }
        [void]$html.Append('<span style="' + ($css -join ';') + '">')
        $open = $true
    }
    [void]$html.Append([Net.WebUtility]::HtmlEncode($raw.Substring($pos)))
    if ($open) { [void]$html.Append('</span>') }
    "<div class='cmd'>PS&gt; $([Net.WebUtility]::HtmlEncode($cmd))</div><pre>$($html.ToString())</pre>"
}
$page = @"
<!doctype html><html><head><meta charset="utf-8"><title>jk preview</title>
<style>body{margin:0;padding:20px;background:$Background;color:$Foreground;font:14px/1.35 'Cascadia Mono','Cascadia Code',Consolas,monospace}
pre{margin:0 0 26px;white-space:pre;font:inherit}.cmd{color:#6A9955;margin:6px 0}</style></head><body>
$($blocks -join "`n")
</body></html>
"@
[IO.File]::WriteAllText($Out, $page, (New-Object Text.UTF8Encoding $false))
"wrote $Out"
