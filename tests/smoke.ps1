# Fresh-install smoke test, for CI only: runs install.ps1 on a clean Windows machine, uses jk the
# way a person would (a new shell, the profile loaded, real commands), then uninstalls and checks
# nothing is left behind. It changes the real profile, scheduled tasks and module path, so it
# refuses to run outside GitHub Actions.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'smoke.ps1 installs and uninstalls jk for real; it only runs in CI (GITHUB_ACTIONS=true)' }
$root = Split-Path -Parent $PSScriptRoot
$script:failed = @()
function Check([string]$Name, [scriptblock]$Cond) {
    if (& $Cond) { Write-Host "  ok    $Name" -ForegroundColor DarkGreen }
    else { Write-Host "  FAIL  $Name" -ForegroundColor Red; $script:failed += $Name }
}
function Show([object[]]$Lines) { foreach ($l in $Lines) { Write-Host "  | $l" } }

Write-Host 'install' -ForegroundColor Cyan
Show @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install.ps1') 2>&1 | ForEach-Object { "$_" })
$link = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules\jk'
$profilePath = $PROFILE.CurrentUserCurrentHost
Check 'module linked into the user module path' { Test-Path -LiteralPath (Join-Path $link 'jk.psd1') }
Check 'profile hook installed' { (Test-Path -LiteralPath $profilePath) -and ([IO.File]::ReadAllText($profilePath)).Contains('# >>> jk >>>') }
Check 'morning task registered' { [bool](Get-ScheduledTask -TaskName 'jk-remind' -ErrorAction SilentlyContinue) }

Write-Host 'a new shell, the way a person uses it' -ForegroundColor Cyan
# no Import-Module: jk must autoload from the module path, with the profile hook loaded too
$cmd = "`$env:JK_COLOR = 'never'; jk due add cs999 'Smoke test' tomorrow 5pm -Weight 5; jk; jk due; jk exams; jk week; jk class; jk plan; jk grade; jk todo 'water plants'; jk todo; jk remind; jk review; jk jobs; jk doctor"
$out = @(& powershell -ExecutionPolicy Bypass -Command $cmd 2>&1 | ForEach-Object { "$_" })
Show $out
$text = $out -join "`n"
Check 'every command ran without a jk error' { -not ($out | Where-Object { $_ -match '^\s*jk: ' }) }
Check 'the deadline was added and listed' { $text -match 'Smoke test' }
Check 'the to-do was added' { $text -match 'water plants' }
Check 'doctor found the module and the task' { $text -match 'module on PSModulePath' -and $text -match 'daily reminder task' }

Write-Host 'uninstall' -ForegroundColor Cyan
Show @(& powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module '$root\jk.psd1'; jk setup uninstall" 2>&1 | ForEach-Object { "$_" })
Check 'profile hook removed' { -not ([IO.File]::ReadAllText($profilePath)).Contains('# >>> jk >>>') }
Check 'morning task removed' { -not (Get-ScheduledTask -TaskName 'jk-remind' -ErrorAction SilentlyContinue) }
Check 'module link removed' { -not (Test-Path -LiteralPath $link) }
Check 'data folder kept' { Test-Path -LiteralPath (Join-Path $HOME '.jk\deadlines.json') }

Write-Host ''
if ($script:failed) { throw "smoke test failed: $($script:failed -join '; ')" }
Write-Host 'smoke test passed' -ForegroundColor Green
