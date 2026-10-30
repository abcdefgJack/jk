# Everything CI used to check, on this machine (there is no GitHub Actions budget): the suite as
# is, in UTC, in Pacific time and with German regional formats, plus the install round trip in a
# sandbox, side by side. Takes about as long as one run. Exit code 1 when any of them fails.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\check.ps1

$suite = Join-Path $PSScriptRoot 'run.ps1'
$smoke = Join-Path $PSScriptRoot 'smoke.ps1'
$variants = [ordered]@{
    'this machine'   = @($suite)
    'UTC'            = @($suite, '-TimeZone', 'UTC')
    'Pacific time'   = @($suite, '-TimeZone', 'Pacific Standard Time')
    'German formats' = @($suite, '-Culture', 'de-DE')
    'install'        = @($smoke)
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$jobs = [ordered]@{}
foreach ($name in $variants.Keys) {
    $jobs[$name] = Start-Job -ArgumentList (, $variants[$name]) -ScriptBlock {
        param($Run)
        $extra = @($Run | Select-Object -Skip 1)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Run[0] @extra 2>&1 | ForEach-Object { "$_" }
    }
}
Write-Host "running the suite $($variants.Count) ways at once..." -ForegroundColor DarkGray
$null = $jobs.Values | Wait-Job

$bad = 0
Write-Host ''
foreach ($name in $jobs.Keys) {
    $out = @(Receive-Job $jobs[$name])
    Remove-Job $jobs[$name]
    $sum = @($out | Where-Object { $_ -match '^(all \d+ tests passed|\d+ passed, \d+ failed)' })[-1]
    if ($name -eq 'install') {
        $sum = $null
        if (@($out | Where-Object { $_ -eq 'smoke test passed' }).Count) { $sum = "all $(@($out | Where-Object { $_ -match '^\s+ok\s' }).Count) install checks passed" }
        elseif (@($out | Where-Object { $_ -match 'smoke test failed' }).Count) { $sum = 'install round trip failed' }
    }
    # each failure with the reason printed on the line after it
    $fails = @(for ($i = 0; $i -lt $out.Count; $i++) {
            if ($out[$i] -notmatch '^\s+FAIL\s') { continue }
            $why = ''; if ($i + 1 -lt $out.Count -and $out[$i + 1] -match '^\s{8}\S') { $why = ': ' + $out[$i + 1].Trim() }
            ($out[$i].Trim() -replace '^FAIL\s+', '') + $why
        })
    if (-not $sum) { $sum = 'did not finish'; $bad++ } elseif ($fails.Count -or $sum -notmatch '^all') { $bad++ }
    $color = 'Green'; if ($fails.Count -or $sum -notmatch '^all') { $color = 'Red' }
    Write-Host ('  {0,-16} {1}' -f $name, $sum) -ForegroundColor $color
    foreach ($f in $fails) { Write-Host "      $f" -ForegroundColor Red }
}
Write-Host ''
Write-Host ("  {0:N0}s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
if ($bad) { exit 1 }
