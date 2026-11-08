# One test from tests\run.ps1 with every check reported, instead of stopping at the first that fails.
# Use it to show that a new test fails against the old code, check by check:
#   git stash push -- lib
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\each.ps1 -Name '<test title>'
#   git stash pop
# Runs on throwaway data, cache and sandbox folders, with the suite's pinned clock. The data folder
# is given in its 8.3 form (C:\Users\JACKWA~1\...), as tests\check.ps1 runs often get it: a long-name
# folder once hid two tests' path mistakes that the full run then caught.
# Limits: a statement that throws outside an assert ends the test there (STOP and why), and so does a
# test that uses run.ps1's own fixtures ($htmlPath and the like). Exit code 1 when anything failed.

param([Parameter(Mandatory)][string]$Name, [string]$Repo)
# (5.1 leaves $PSScriptRoot empty in a script's param defaults)
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }

$errs = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'tests\run.ps1'), [ref]$null, [ref]$errs)
$cmd = @($ast.FindAll({ param($n)
            $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Test' -and
            $n.CommandElements.Count -ge 3 -and $n.CommandElements[1].SafeGetValue() -eq $Name }, $true))[0]
if (-not $cmd) { throw "no test named '$Name' in tests\run.ps1" }
$text = $cmd.CommandElements[2].ScriptBlock.EndBlock.Extent.Text

$root = Join-Path ([IO.Path]::GetTempPath()) "jk-each-$PID"
New-Item -ItemType Directory -Force -Path $root | Out-Null
try { $root = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($root).ShortPath } catch { }
$env:JK_HOME = Join-Path $root 'home'
$env:JK_CACHE = Join-Path $root 'cache'
$env:JK_SANDBOX = Join-Path $root 'sandbox'
$env:JK_NONINTERACTIVE = '1'
$env:JK_COLOR = 'never'
$env:JK_WIDTH = '100'   # run.ps1's: at 110 a doctor line cut at 100 passed here and failed there
$env:JK_NOW = '2026-10-22T14:00:00'
New-Item -ItemType Directory -Force -Path $env:JK_HOME | Out-Null
$failed = 0
try {
    Import-Module (Join-Path $Repo 'jk.psm1') -Force -DisableNameChecking
    $lines = & (Get-Module jk) {
        param($text)
        $script:EachResults = New-Object System.Collections.Generic.List[string]
        # script-scoped: the test body runs in this scope and may have a $note of its own
        # a passing check shows the first line of its message (some carry a command's whole output,
        # for the failure case); a failing one shows all of it
        $script:EachNote = {
            param($ok, $msg, $extra)
            if ($ok) {
                $first = ([string]$msg -split "`n")[0]
                if ($first.Length -gt 100) { $first = $first.Substring(0, 97) + '...' }
                $script:EachResults.Add("pass  $first")
            } else { $script:EachResults.Add("FAIL  $msg$extra") }
        }
        function script:Assert-Eq($Actual, $Expected, [string]$Msg = '') { & $script:EachNote ("$Actual" -ceq "$Expected") $Msg "  (expected [$Expected], got [$Actual])" }
        function script:Assert-True($Cond, [string]$Msg = 'condition was false') { & $script:EachNote ([bool]$Cond) $Msg '' }
        function script:Assert-Throws([scriptblock]$Block, [string]$Msg = 'expected an error') {
            $threw = $false
            try { $null = & $Block } catch { $threw = $true }
            & $script:EachNote $threw $Msg ''
        }
        try { $null = . ([scriptblock]::Create($text)) 6>$null } catch { $script:EachResults.Add("STOP  $($_.Exception.Message)") }
        $script:EachResults
    } $text
    foreach ($l in $lines) {
        if ($l -notmatch '^pass') { $failed++ }
        $color = 'DarkGreen'; if ($l -notmatch '^pass') { $color = 'Red' }
        Write-Host $l -ForegroundColor $color
    }
} finally {
    Remove-Module jk -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failed) { exit 1 }
