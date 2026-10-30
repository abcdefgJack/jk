# Everything CI used to check, on this machine (there is no GitHub Actions budget): the suite as
# is, in UTC, in Pacific time and with German regional formats, side by side. Takes about as long
# as one run. Exit code 1 when any of them fails.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\check.ps1

$suite = Join-Path $PSScriptRoot 'run.ps1'
$variants = [ordered]@{
    'this machine'   = @()
    'UTC'            = @('-TimeZone', 'UTC')
    'Pacific time'   = @('-TimeZone', 'Pacific Standard Time')
    'German formats' = @('-Culture', 'de-DE')
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$jobs = [ordered]@{}
foreach ($name in $variants.Keys) {
    $jobs[$name] = Start-Job -ArgumentList $suite, $variants[$name] -ScriptBlock {
        param($Suite, $Extra)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Suite @Extra 2>&1 | ForEach-Object { "$_" }
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
    $fails = @($out | Where-Object { $_ -match '^\s+FAIL\s' } | ForEach-Object { $_.Trim() -replace '^FAIL\s+', '' })
    if (-not $sum) { $sum = 'did not finish'; $bad++ } elseif ($fails.Count -or $sum -notmatch '^all') { $bad++ }
    $color = 'Green'; if ($fails.Count -or $sum -notmatch '^all') { $color = 'Red' }
    Write-Host ('  {0,-16} {1}' -f $name, $sum) -ForegroundColor $color
    foreach ($f in $fails) { Write-Host "      $f" -ForegroundColor Red }
}
Write-Host ''
Write-Host ("  {0:N0}s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
if ($bad) { exit 1 }
