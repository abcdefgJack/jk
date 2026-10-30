# Fresh-install smoke test: runs install.ps1, uses jk the way a person would (a new shell that finds
# the module through its link and loads the profile hook, real commands), then uninstalls and
# checks nothing is left behind.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1         sandboxed (anywhere)
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1 -Real   the real thing (CI only)
# Sandboxed, JK_SANDBOX sends the module link, the profile hook and the data to a throwaway folder
# and skips Task Scheduler, so it is safe on a machine in daily use. -Real changes the real profile,
# scheduled tasks and module path, so it refuses to run outside GitHub Actions.
param([switch]$Real)

$ErrorActionPreference = 'Stop'
if ($Real -and $env:GITHUB_ACTIONS -ne 'true') { throw 'smoke.ps1 -Real installs and uninstalls jk for real; it only runs in CI (GITHUB_ACTIONS=true). Leave out -Real for the sandboxed run.' }
$root = Split-Path -Parent $PSScriptRoot
$script:failed = @()
function Check([string]$Name, [scriptblock]$Cond) {
    if (& $Cond) { Write-Host "  ok    $Name" -ForegroundColor DarkGreen }
    else { Write-Host "  FAIL  $Name" -ForegroundColor Red; $script:failed += $Name }
}
function Show([object[]]$Lines) { foreach ($l in $Lines) { Write-Host "  | $l" } }

$sandbox = $null
if ($Real) {
    $link = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules\jk'
    $profilePath = $PROFILE.CurrentUserCurrentHost
    $dataDir = Join-Path $HOME '.jk'
    $shellPrefix = ''
} else {
    $sandbox = Join-Path $env:TEMP ('jk-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    $env:JK_SANDBOX = $sandbox
    $env:JK_HOME = Join-Path $sandbox 'data'
    $link = Join-Path $sandbox 'Modules\jk'
    $profilePath = Join-Path $sandbox 'profile.ps1'
    $dataDir = $env:JK_HOME
    # the new shell finds jk only through the sandbox link (the real install is taken off its path)
    # and runs the sandbox profile the way PowerShell would run the real one
    $paths = @(($env:PSModulePath -split ';') | Where-Object { $_ -and $_ -notmatch 'WindowsPowerShell\\Modules$' -or $_ -match '^C:\\(Program Files|Windows)' })
    $shellPrefix = "`$env:PSModulePath = '$(Join-Path $sandbox 'Modules');$($paths -join ';')'; . '$profilePath'; "
    Write-Host "sandbox: $sandbox" -ForegroundColor DarkGray
}

try {
    Write-Host 'install' -ForegroundColor Cyan
    Show @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install.ps1') 2>&1 | ForEach-Object { "$_" })
    Check 'module linked into the module path' { Test-Path -LiteralPath (Join-Path $link 'jk.psd1') }
    Check 'profile hook installed' { (Test-Path -LiteralPath $profilePath) -and ([IO.File]::ReadAllText($profilePath)).Contains('# >>> jk >>>') }
    if ($Real) { Check 'morning task registered' { [bool](Get-ScheduledTask -TaskName 'jk-remind' -ErrorAction SilentlyContinue) } }

    Write-Host 'a new shell, the way a person uses it' -ForegroundColor Cyan
    # no Import-Module: jk must autoload from the module path, with the profile hook loaded too
    $cmd = $shellPrefix + "`$env:JK_COLOR = 'never'; (Get-Command jk).Module.Path; jk due add cs999 'Smoke test' tomorrow 5pm -Weight 5; jk; jk due; jk exams; jk week; jk class; jk plan; jk grade; jk todo 'water plants'; jk todo; jk remind; jk review; jk jobs; jk net; jk doctor"
    if ($Real) { $out = @(& powershell -ExecutionPolicy Bypass -Command $cmd 2>&1 | ForEach-Object { "$_" }) }
    else { $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | ForEach-Object { "$_" }) }
    Show $out
    $text = $out -join "`n"
    Check 'every command ran without a jk error' { -not ($out | Where-Object { $_ -match '^\s*jk: ' }) }
    Check 'jk autoloaded through the link' { $text.Contains($link) }
    Check 'the deadline was added and listed' { $text -match 'Smoke test' }
    Check 'the to-do was added' { $text -match 'water plants' }
    Check 'doctor found the module and named the task' { $text -match 'module on PSModulePath' -and $text -match 'daily reminder task' }
    if (-not $Real) { Check 'nothing written to the real data folder' { -not ($text -match [regex]::Escape((Join-Path $HOME '.jk'))) } }

    Write-Host 'uninstall' -ForegroundColor Cyan
    Show @(& powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module '$root\jk.psd1'; jk setup uninstall" 2>&1 | ForEach-Object { "$_" })
    Check 'profile hook removed' { -not ([IO.File]::ReadAllText($profilePath)).Contains('# >>> jk >>>') }
    if ($Real) { Check 'morning task removed' { -not (Get-ScheduledTask -TaskName 'jk-remind' -ErrorAction SilentlyContinue) } }
    Check 'module link removed' { -not (Test-Path -LiteralPath $link) }
    Check 'data folder kept' { Test-Path -LiteralPath (Join-Path $dataDir 'deadlines.json') }
} finally {
    if ($sandbox) {
        # a junction left behind must go on its own: a recursive delete in Windows PowerShell can
        # walk through it into its target, the jk folder itself
        if (Test-Path -LiteralPath $link) { $item = Get-Item -LiteralPath $link -Force; if ($item.LinkType) { $item.Delete() } }
        $links = @(Get-ChildItem -LiteralPath $sandbox -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue)
        if ($links.Count) { Write-Host "  left $sandbox in place: it still holds a link ($($links[0].FullName))" -ForegroundColor Yellow }
        else { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
        Remove-Item env:JK_SANDBOX, env:JK_HOME -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($script:failed) { throw "smoke test failed: $($script:failed -join '; ')" }
Write-Host 'smoke test passed' -ForegroundColor Green
