# cp.ps1 - competitive programming: scaffold, compile, test against samples, stress test.
#   jk cp new two-sum            folder + template + empty 1.in/1.out, opens the editor
#   jk cp add                    clipboard -> next sample input (then expected output)
#   jk cp                        compile (cached) and run every *.in, diff against *.out/*.ans
#   jk cp stress                 main vs brute on inputs from gen, stops at the first mismatch

$script:CpExts = @('.cpp', '.cc', '.cxx', '.c', '.py', '.java')
$script:JkCpBuildDir = '.jkcp'   # compiled binaries, next to the source (hidden)

# Windows NTSTATUS exit codes worth naming
$script:CpExitNames = @{
    '-1073741571' = 'stack overflow'
    '-1073741819' = 'access violation (bad pointer / out of bounds)'
    '-1073741676' = 'integer division by zero'
    '-1073741675' = 'integer overflow'
    '-1073740791' = 'abort / failed check (stack buffer overrun or assertion)'
    '-1073741795' = 'illegal instruction'
    '-1073741801' = 'out of memory'
    '3'           = 'abort() called (assert failed?)'
}

function Get-JkCpSource {
    param([string]$File, [string]$Dir = (Get-Location).ProviderPath)
    if ($File) {
        $f = Get-Item -LiteralPath $File -ErrorAction SilentlyContinue
        if (-not $f) {
            $f = Get-ChildItem -LiteralPath $Dir -File | Where-Object { $_.BaseName -eq $File -and $script:CpExts -contains $_.Extension.ToLower() } | Select-Object -First 1
        }
        if (-not $f) { throw "no source file '$File'" }
        return $f
    }
    $cands = @(Get-ChildItem -LiteralPath $Dir -File | Where-Object { $script:CpExts -contains $_.Extension.ToLower() -and $_.BaseName -notmatch '^(?i)(brute|naive|slow|gen|generator|checker|check|stress|validator)' })
    if ($cands.Count -eq 0) { return $null }
    $pref = @($cands | Where-Object { $_.BaseName -match '^(?i)(main|sol|solution|a)$' })
    if ($pref.Count) { return ($pref | Sort-Object LastWriteTime -Descending)[0] }
    ($cands | Sort-Object LastWriteTime -Descending)[0]
}

function Find-JkCpHelper([string]$Pattern, [string]$Dir) {
    Get-ChildItem -LiteralPath $Dir -File | Where-Object { $_.BaseName -match "^(?i)($Pattern)$" -and $script:CpExts -contains $_.Extension.ToLower() } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Join-JkArgs([string[]]$List) {
    ($List | ForEach-Object {
            if ($_ -eq '') { '""' }
            elseif ($_ -match '[\s"]') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
            else { $_ }
        }) -join ' '
}

# Compiles when needed (cached by source hash + flags) and returns how to run it.
function Build-JkCp {
    param([IO.FileInfo]$Src, [switch]$DebugBuild, [switch]$Quiet)
    $ext = $Src.Extension.ToLower()
    # not ".jk": that is the data folder's name, and a solution saved in ~ would build into it
    $buildDir = Join-Path $Src.DirectoryName $script:JkCpBuildDir
    if (-not (Test-Path -LiteralPath $buildDir)) { (New-Item -ItemType Directory -Path $buildDir).Attributes = 'Hidden,Directory' }
    switch -Regex ($ext) {
        '^\.(cpp|cc|cxx|c)$' {
            $gpp = Get-Command g++ -ErrorAction SilentlyContinue
            if ($ext -eq '.c') { $gpp = Get-Command gcc -ErrorAction SilentlyContinue }
            if (-not $gpp) { throw 'g++ was not found on PATH (winget install BrechtSanders.WinLibs.POSIX.UCRT)' }
            $std = Get-JkConfig 'cp.std'
            $flags = @('-O2', '-Wall', '-Wextra', '-Wshadow', '-Wno-unused-result', '-DLOCAL', '-Wl,--stack,268435456')
            if ($ext -ne '.c') { $flags = @("-std=$std") + $flags }
            $tag = ''
            if ($DebugBuild) {
                $flags = @($flags | Where-Object { $_ -ne '-O2' }) + @('-O0', '-g', '-D_GLIBCXX_DEBUG', '-D_GLIBCXX_DEBUG_PEDANTIC', '-ftrapv', '-fno-omit-frame-pointer')
                $tag = '-dbg'
            }
            $exe = Join-Path $buildDir ($Src.BaseName + $tag + '.exe')
            $stampFile = "$exe.stamp"
            $hash = (Get-FileHash -LiteralPath $Src.FullName -Algorithm SHA1).Hash + '|' + ($flags -join ' ') + '|' + $gpp.Source
            if ((Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $stampFile) -and ([IO.File]::ReadAllText($stampFile) -eq $hash)) {
                return [pscustomobject]@{ Exe = $exe; Args = @(); Compiled = $false; Lang = 'cpp' }
            }
            if (-not $Quiet) { Write-Host (Paint 'gray' "  compiling $($Src.Name)$($script:G.ell)") -NoNewline }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $allArgs = $flags + @('-o', $exe, $Src.FullName)
            $res = Invoke-JkProcess -Exe $gpp.Source -ArgList $allArgs -InputText '' -TimeoutMs 120000 -WorkDir $Src.DirectoryName
            $sw.Stop()
            if (-not $Quiet) { Write-Host "`r" -NoNewline }
            # drop the folder prefix so diagnostics read "main.cpp:4:62: error ..."
            $diag = ($res.Err + $res.Out).Trim().Replace($Src.DirectoryName + '\', '')
            if ($res.Code -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
                if (-not $Quiet) { Say (Paint 'red' "  compile error in $($Src.Name)") }
                Write-JkCompilerOutput $diag
                throw "compilation failed ($($Src.Name))"
            }
            [IO.File]::WriteAllText($stampFile, $hash)
            if (-not $Quiet) {
                $warn = ([regex]::Matches($diag, 'warning:')).Count
                $msg = "  compiled $($Src.Name) in $([Math]::Round($sw.Elapsed.TotalSeconds, 1))s"
                if ($DebugBuild) { $msg += ' (debug: _GLIBCXX_DEBUG, -ftrapv)' }
                if ($warn) { Say ((Paint 'gray' $msg) + (Paint 'yellow' "  $warn warning$(if ($warn -ne 1) {'s'})")); Write-JkCompilerOutput $diag -MaxLines 12 }
                else { Say (Paint 'gray' $msg) }
            }
            return [pscustomobject]@{ Exe = $exe; Args = @(); Compiled = $true; Lang = 'cpp' }
        }
        '^\.py$' {
            $py = Get-Command python -ErrorAction SilentlyContinue
            if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
            if (-not $py) { throw 'python was not found on PATH' }
            return [pscustomobject]@{ Exe = $py.Source; Args = @('-X', 'utf8', $Src.FullName); Compiled = $false; Lang = 'py' }
        }
        '^\.java$' {
            $javac = Get-Command javac -ErrorAction SilentlyContinue
            $java = Get-Command java -ErrorAction SilentlyContinue
            if (-not $javac -or -not $java) { throw 'javac/java were not found on PATH' }
            $cls = $Src.BaseName
            $stampFile = Join-Path $buildDir "$cls.java.stamp"
            $hash = (Get-FileHash -LiteralPath $Src.FullName -Algorithm SHA1).Hash
            $classFile = Join-Path $buildDir "$cls.class"
            if (-not ((Test-Path $classFile) -and (Test-Path $stampFile) -and ([IO.File]::ReadAllText($stampFile) -eq $hash))) {
                if (-not $Quiet) { Write-Host (Paint 'gray' "  compiling $($Src.Name)$($script:G.ell)") -NoNewline }
                $res = Invoke-JkProcess -Exe $javac.Source -ArgList @('-encoding', 'UTF-8', '-d', $buildDir, $Src.FullName) -InputText '' -TimeoutMs 120000 -WorkDir $Src.DirectoryName
                if (-not $Quiet) { Write-Host "`r" -NoNewline }
                if ($res.Code -ne 0) { Write-JkCompilerOutput ($res.Err + $res.Out); throw "compilation failed ($($Src.Name))" }
                [IO.File]::WriteAllText($stampFile, $hash)
                if (-not $Quiet) { Say (Paint 'gray' "  compiled $($Src.Name)") }
            }
            return [pscustomobject]@{ Exe = $java.Source; Args = @('-Xss256m', '-Dfile.encoding=UTF-8', '-cp', $buildDir, $cls); Compiled = $true; Lang = 'java' }
        }
    }
    throw "don't know how to build $($Src.Name)"
}

function Write-JkCompilerOutput([string]$Text, [int]$MaxLines = 40) {
    $lines = @($Text -split "`r?`n" | Where-Object { $_ -ne '' })
    foreach ($l in ($lines | Select-Object -First $MaxLines)) {
        $st = 'muted'
        if ($l -match 'error:|Error') { $st = 'red' } elseif ($l -match 'warning:') { $st = 'yellow' } elseif ($l -match 'note:') { $st = 'gray' }
        Say ('    ' + (Paint $st $l))
    }
    if ($lines.Count -gt $MaxLines) { Say (Paint 'gray' "    $($lines.Count - $MaxLines) more lines$($script:G.ell)") }
}

function Get-JkPeakMemory($Proc) {
    if (-not ('JkPsapi' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class JkPsapi {
    [StructLayout(LayoutKind.Sequential)]
    public struct Counters {
        public uint cb; public uint PageFaultCount;
        public UIntPtr PeakWorkingSetSize; public UIntPtr WorkingSetSize;
        public UIntPtr QuotaPeakPagedPoolUsage; public UIntPtr QuotaPagedPoolUsage;
        public UIntPtr QuotaPeakNonPagedPoolUsage; public UIntPtr QuotaNonPagedPoolUsage;
        public UIntPtr PagefileUsage; public UIntPtr PeakPagefileUsage;
    }
    [DllImport("psapi.dll", SetLastError = true)]
    static extern bool GetProcessMemoryInfo(IntPtr process, out Counters counters, uint size);
    [DllImport("kernel32.dll")]
    public static extern uint SetErrorMode(uint mode);
    public static long Peak(IntPtr process) {
        Counters c;
        if (!GetProcessMemoryInfo(process, out c, (uint)Marshal.SizeOf(typeof(Counters)))) return -1;
        return (long)c.PeakWorkingSetSize.ToUInt64();
    }
}
'@
    }
    try { return [JkPsapi]::Peak($Proc.Handle) } catch { return -1 }
}

# Runs a program with stdin text; captures stdout/stderr, wall time and peak memory.
function Invoke-JkProcess {
    param([string]$Exe, [string[]]$ArgList = @(), [string]$InputText = '', [int]$TimeoutMs = 3000, [string]$WorkDir = (Get-Location).ProviderPath)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = Join-JkArgs $ArgList
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding $false
    $psi.StandardErrorEncoding = New-Object Text.UTF8Encoding $false
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $psi
    # .NET builds the child's stdin writer from Console.InputEncoding; on a UTF-8 console
    # that writer emits a BOM (EF BB BF) first, which breaks `cin >> n` and int(input()).
    # Swap in a BOM-less UTF-8 encoding just for Start().
    $origIn = $null
    try {
        $enc = [Console]::InputEncoding
        if ($enc.GetPreamble().Length -gt 0) { $origIn = $enc; [Console]::InputEncoding = New-Object Text.UTF8Encoding $false }
    } catch { $origIn = $null }
    # Children inherit the error mode: without this a crash (null deref, failed .at(),
    # abort) opens Windows Error Reporting, the process hangs, and it looks like a TLE.
    $null = Get-JkPeakMemory $null
    $oldMode = [JkPsapi]::SetErrorMode(0x8003)   # FAILCRITICALERRORS | NOGPFAULTERRORBOX | NOOPENFILEERRORBOX
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { [void]$p.Start() }
    finally {
        [void][JkPsapi]::SetErrorMode($oldMode)
        if ($origIn) { try { [Console]::InputEncoding = $origIn } catch { } }
    }
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    try {
        if ($InputText) {
            $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($InputText)
            $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        }
        $p.StandardInput.Close()
    } catch { }
    $peak = 0
    $timedOut = $false
    while (-not $p.WaitForExit(10)) {
        try { $p.Refresh(); if ($p.PeakWorkingSet64 -gt $peak) { $peak = $p.PeakWorkingSet64 } } catch { }
        if ($sw.ElapsedMilliseconds -gt $TimeoutMs) {
            $timedOut = $true
            try { $p.Kill() } catch { }
            break
        }
    }
    $sw.Stop()
    $p.WaitForExit()
    $code = 0
    try { $code = $p.ExitCode } catch { }
    # sampling misses short runs; the OS keeps the exact peak while we hold the handle
    $exact = Get-JkPeakMemory $p
    if ($exact -gt $peak) { $peak = $exact }
    [pscustomobject]@{
        Out      = $outTask.Result
        Err      = $errTask.Result
        Code     = $code
        Ms       = [int]$sw.ElapsedMilliseconds
        TimedOut = $timedOut
        PeakMB   = [Math]::Round($peak / 1MB, 1)
    }
}

# Token-wise comparison; numbers containing '.' or 'e' are compared with 1e-6 tolerance.
function Compare-JkOutput([string]$Expected, [string]$Actual) {
    $e = @($Expected -split '\s+' | Where-Object { $_ -ne '' })
    $a = @($Actual -split '\s+' | Where-Object { $_ -ne '' })
    $n = [Math]::Min($e.Count, $a.Count)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    for ($i = 0; $i -lt $n; $i++) {
        if ($e[$i] -ceq $a[$i]) { continue }
        $x = 0.0; $y = 0.0
        $isNum = [double]::TryParse($e[$i], [Globalization.NumberStyles]::Float, $inv, [ref]$x) -and [double]::TryParse($a[$i], [Globalization.NumberStyles]::Float, $inv, [ref]$y)
        if ($isNum -and ($e[$i] -match '[.eE]' -or $a[$i] -match '[.eE]')) {
            $diff = [Math]::Abs($x - $y)
            if ($diff -le 1e-6 -or $diff -le 1e-6 * [Math]::Abs($x)) { continue }
        }
        return [pscustomobject]@{ Ok = $false; Index = $i; Expected = $e[$i]; Got = $a[$i] }
    }
    if ($e.Count -ne $a.Count) {
        $exp = '<end of output>'; $got = '<end of output>'
        if ($e.Count -gt $n) { $exp = $e[$n] }
        if ($a.Count -gt $n) { $got = $a[$n] }
        return [pscustomobject]@{ Ok = $false; Index = $n; Expected = $exp; Got = $got }
    }
    [pscustomobject]@{ Ok = $true; Index = -1; Expected = ''; Got = '' }
}

function Write-JkSideBySide([string]$Expected, [string]$Actual, [int]$MaxLines = 14) {
    $el = @(($Expected.TrimEnd() -split "`r?`n") | ForEach-Object { $_.TrimEnd() })
    $al = @(($Actual.TrimEnd() -split "`r?`n") | ForEach-Object { $_.TrimEnd() })
    $w = Get-JkWidth
    $col = [int][Math]::Floor(($w - 12) / 2)
    $first = -1
    $n = [Math]::Max($el.Count, $al.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = ''; $y = ''
        if ($i -lt $el.Count) { $x = $el[$i] }
        if ($i -lt $al.Count) { $y = $al[$i] }
        if ((($x -split '\s+' | Where-Object { $_ }) -join ' ') -cne (($y -split '\s+' | Where-Object { $_ }) -join ' ')) { $first = $i; break }
    }
    $start = [Math]::Max(0, $first - 3)
    if ($first -lt 0) { $start = 0 }
    Say ('      ' + (Paint 'gray' (Fit 'expected' $col)) + '   ' + (Paint 'gray' 'got'))
    for ($i = $start; $i -lt [Math]::Min($n, $start + $MaxLines); $i++) {
        $x = ''; $y = ''
        if ($i -lt $el.Count) { $x = $el[$i] }
        if ($i -lt $al.Count) { $y = $al[$i] }
        $same = (($x -split '\s+' | Where-Object { $_ }) -join ' ') -ceq (($y -split '\s+' | Where-Object { $_ }) -join ' ')
        $ln = Paint 'gray' (("{0}" -f ($i + 1)).PadLeft(4))
        if ($same) { Say ("  $ln " + (Paint 'muted' (Fit $x $col)) + '   ' + (Paint 'muted' (Fit $y $col))) }
        else { Say ("  $ln " + (Paint 'green' (Fit $x $col)) + (Paint 'red' ' ! ') + (Paint 'bold red' (Fit $y $col))) }
    }
    if ($n -gt $start + $MaxLines) { Say (Paint 'gray' "       $($n - $start - $MaxLines) more lines$($script:G.ell)") }
}

function Get-JkCpTests([string]$Dir) {
    $ins = @(Get-ChildItem -LiteralPath $Dir -File -Filter '*.in' -ErrorAction SilentlyContinue)
    $sub = Join-Path $Dir 'tests'
    if (Test-Path -LiteralPath $sub) { $ins += @(Get-ChildItem -LiteralPath $sub -File -Filter '*.in') }
    $ins = @($ins | Where-Object { $_.BaseName -notmatch '^stress' } | Sort-Object { Get-JkNaturalKey $_.Name })
    foreach ($i in $ins) {
        $ans = $null
        foreach ($ext in '.out', '.ans', '.expected') {
            $p = Join-Path $i.DirectoryName ($i.BaseName + $ext)
            if (Test-Path -LiteralPath $p) { $ans = $p; break }
        }
        [pscustomobject]@{ Name = $i.BaseName; In = $i.FullName; Ans = $ans }
    }
}

function Get-JkVerdictText($Res, [int]$TimeoutMs) {
    if ($Res.TimedOut) { return @('TLE', 'bold orange', "killed after $([Math]::Round($TimeoutMs / 1000.0, 1))s") }
    if ($Res.Code -ne 0) {
        $name = $script:CpExitNames["$($Res.Code)"]
        $detail = "exit code $($Res.Code)"
        if ($Res.Code -lt 0) { $detail = 'exit code 0x{0:X8}' -f $Res.Code }
        if ($name) { $detail += " $($script:G.dot) $name" }
        return @('RTE', 'bold red', $detail)
    }
    $null
}

function Invoke-JkCpTest {
    param([Parameter(Position = 0)][string]$File, [double]$Timeout = 0, [Alias('d')][switch]$DebugBuild, [Alias('v')][switch]$ShowStderr)
    $src = Get-JkCpSource $File
    if (-not $src) { throw "no source file here ($((Get-Location).ProviderPath)). Start one with: jk cp new <name>" }
    if (-not $Timeout) { $Timeout = [double](Get-JkConfig 'cp.timeout') }
    $tms = [int]($Timeout * 1000)
    $run = Build-JkCp $src -DebugBuild:$DebugBuild
    $tests = @(Get-JkCpTests $src.DirectoryName)
    if ($tests.Count -eq 0) {
        Say (Paint 'yellow' '  no tests (*.in) here. Copy a sample input and run: jk cp add')
        return
    }
    Write-JkHeader "Testing $($src.Name)" "$($tests.Count) test$(if ($tests.Count -ne 1) {'s'}) $($script:G.dot) limit ${Timeout}s"
    $pass = 0; $maxMs = 0; $maxMb = 0.0
    foreach ($t in $tests) {
        $inText = [IO.File]::ReadAllText($t.In)
        $res = Invoke-JkProcess -Exe $run.Exe -ArgList $run.Args -InputText $inText -TimeoutMs $tms -WorkDir $src.DirectoryName
        if ($res.Ms -gt $maxMs) { $maxMs = $res.Ms }
        if ($res.PeakMB -gt $maxMb) { $maxMb = $res.PeakMB }
        $v = Get-JkVerdictText $res $tms
        $stats = Paint 'gray' ("{0,6} ms  {1,6} MB" -f $res.Ms, $res.PeakMB)
        if (-not $v) {
            $expected = $null
            if ($t.Ans) { $expected = [IO.File]::ReadAllText($t.Ans); if (-not $expected.Trim()) { $expected = $null } }
            if ($null -ne $expected) {
                $cmp = Compare-JkOutput $expected $res.Out
                if ($cmp.Ok) { $v = @('PASS', 'bold green', '') } else { $v = @('WA', 'bold red', "token $($cmp.Index + 1): expected '$($cmp.Expected)', got '$($cmp.Got)'") }
            } else { $v = @('RAN', 'bold cyan', 'no expected output yet') }
        }
        if ($v[0] -eq 'PASS') { $pass++ }
        Say ('  ' + (Paint $v[1] (Fit $v[0] 5)) + ' ' + (Paint 'white' (Fit $t.Name 14)) + $stats + '  ' + (Paint 'muted' $v[2]))
        if ($v[0] -eq 'WA') { Write-JkSideBySide $expected $res.Out }
        if ($v[0] -eq 'RAN') {
            foreach ($l in (@($res.Out.TrimEnd() -split "`r?`n") | Select-Object -First 15)) { Say ('      ' + $l) }
        }
        $err = $res.Err.TrimEnd()
        if ($err -and ($v[0] -ne 'PASS' -or $ShowStderr)) {
            $el = @($err -split "`r?`n")
            foreach ($l in ($el | Select-Object -First 12)) { Say ('      ' + (Paint 'gray' "stderr $($script:G.vline) ") + (Paint 'muted' $l)) }
            if ($el.Count -gt 12) { Say (Paint 'gray' "      $($el.Count - 12) more stderr lines$($script:G.ell)") }
        } elseif ($err -and $v[0] -eq 'PASS') {
            $count = @($err -split "`r?`n").Count
            Say (Paint 'gray' "        ($count line$(if ($count -ne 1) {'s'}) of debug output on stderr - jk cp -v shows it)")
        }
        if ($v[0] -eq 'RTE' -and $res.Code -eq -1073741819 -and $run.Lang -eq 'cpp' -and -not $DebugBuild) {
            Say (Paint 'gray' "        tip: jk cp -d rebuilds with _GLIBCXX_DEBUG to pinpoint out-of-range access")
        }
    }
    Say ''
    $style = 'bold green'
    if ($pass -ne $tests.Count) { $style = 'bold red' }
    Say ('  ' + (Paint $style "$pass/$($tests.Count) passed") + (Paint 'gray' "  $($script:G.dot) max $maxMs ms $($script:G.dot) peak $maxMb MB"))
}

function Invoke-JkCpRun {
    param([Parameter(Position = 0)][string]$File, [Alias('d')][switch]$DebugBuild)
    $src = Get-JkCpSource $File
    if (-not $src) { throw 'no source file here' }
    $run = Build-JkCp $src -DebugBuild:$DebugBuild
    Say (Paint 'gray' "  running $($src.Name) $($script:G.dot) type input, then Ctrl+Z and Enter to finish")
    & $run.Exe @($run.Args)
    Say (Paint 'gray' "  exit code $LASTEXITCODE")
}

function New-JkCpProblem {
    param(
        [Parameter(Position = 0)][string]$Name,
        [ValidateSet('cpp', 'py', 'java', 'usaco', '')][string]$Lang = '',
        [switch]$Here,
        [switch]$NoOpen
    )
    if (-not $Name) { throw 'usage: jk cp new <name> [-Lang cpp|py|java|usaco] [-Here]' }
    if (-not $Lang) { $Lang = Get-JkConfig 'cp.lang' }
    $root = (Get-Location).ProviderPath
    if (-not $Here) { $root = [Environment]::ExpandEnvironmentVariables((Get-JkConfig 'cp.root')) }
    $dir = Join-Path $root $Name
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tplDir = Join-Path (Get-JkRoot) 'templates\cp'
    $map = @{ cpp = @('main.cpp', 'main.cpp'); usaco = @('usaco.cpp', 'main.cpp'); py = @('main.py', 'main.py'); java = @('Main.java', 'Main.java') }
    $tplName = $map[$Lang][0]; $outName = $map[$Lang][1]
    $src = Join-Path $dir $outName
    $fresh = -not (Test-Path -LiteralPath $src)
    if ($fresh) {
        $text = [IO.File]::ReadAllText((Join-Path $tplDir $tplName))
        $text = $text.Replace('{{NAME}}', ($Name -replace '[^A-Za-z0-9_]', '')).Replace('{{DATE}}', (Get-Date -Format 'yyyy-MM-dd'))
        Write-JkText $src $text
        foreach ($f in '1.in', '1.out') { $p = Join-Path $dir $f; if (-not (Test-Path $p)) { Write-JkText $p '' } }
    }
    Set-Location -LiteralPath $dir
    if ($fresh) { Say ((Paint 'green' "  created $($script:G.check)") + "  $dir" + (Paint 'gray' "  ($outName, 1.in, 1.out)")) }
    else { Say ((Paint 'yellow' '  exists') + "  $dir" + (Paint 'gray' ' - switched to it')) }
    Say (Paint 'gray' "  paste samples: copy input $($script:G.arrow) jk cp add   $($script:G.dot)   test: jk cp   $($script:G.dot)   stress: add brute.cpp + gen.py, then jk cp stress")
    if (-not $NoOpen) { Open-JkInEditor $src }
}

function Open-JkInEditor([string]$Path) {
    $ed = Get-JkConfig 'editor'
    $cmd = Get-Command $ed -ErrorAction SilentlyContinue
    if (-not $cmd) { Say (Paint 'gray' "  (editor '$ed' not found; set one with: jk config set editor cursor)"); return }
    try { & $cmd.Source $Path | Out-Null } catch { Say (Paint 'gray' "  could not open $ed") }
}

# Clipboard text with a short retry (another app may briefly hold the clipboard open).
function Get-JkClipboardText {
    for ($i = 0; $i -lt 4; $i++) {
        try { return [string](Get-Clipboard -Raw -ErrorAction Stop) } catch { Start-Sleep -Milliseconds 120 }
    }
    throw 'could not read the clipboard (another app may be holding it) - try again'
}

# Saves the clipboard as the next sample: N.in, then (after you copy it) N.out.
function Add-JkCpTest {
    param([switch]$In, [switch]$Out, [string]$Name)
    $dir = (Get-Location).ProviderPath
    $norm = { param($s) (($s -replace "`r`n", "`n") -replace "`r", "`n").TrimEnd() + "`n" }
    $existing = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.in' | Where-Object { $_.BaseName -match '^\d+$' } | ForEach-Object { [int]$_.BaseName })
    if ($Out) {
        $n = $Name
        if (-not $n) { $n = [string](($existing | Measure-Object -Maximum).Maximum) }
        if (-not $n) { throw 'no N.in yet; run jk cp add first' }
        Write-JkText (Join-Path $dir "$n.out") (& $norm (Get-JkClipboardText))
        Say ((Paint 'green' "  saved $n.out $($script:G.check)"))
        return
    }
    $n = $Name
    if (-not $n) {
        $n = 1
        # reuse an empty N.in (the template's 1.in) before creating a new number
        while ((Test-Path (Join-Path $dir "$n.in")) -and ((Get-Item (Join-Path $dir "$n.in")).Length -gt 0)) { $n++ }
    }
    $clip = Get-JkClipboardText
    if (-not $clip -or -not $clip.Trim()) { throw 'the clipboard is empty - copy the sample input first' }
    Write-JkText (Join-Path $dir "$n.in") (& $norm $clip)
    $lines = @($clip.Trim() -split "`r?`n").Count
    Say ((Paint 'green' "  saved $n.in $($script:G.check)") + (Paint 'gray' " ($lines line$(if ($lines -ne 1) {'s'}))"))
    if ($In) { return }
    if (-not [Environment]::UserInteractive) { return }
    Write-Host (Paint 'cyan' '  now copy the expected output and press Enter (or type s to skip) ') -NoNewline
    $ans = Read-Host
    if ($ans -match '^s') { return }
    $clip2 = Get-JkClipboardText
    if ($clip2 -eq $clip) { Say (Paint 'yellow' '  clipboard still holds the input - skipped the .out (run: jk cp add -Out)'); return }
    Write-JkText (Join-Path $dir "$n.out") (& $norm $clip2)
    Say ((Paint 'green' "  saved $n.out $($script:G.check)"))
}

function Invoke-JkCpStress {
    param(
        [Parameter(Position = 0)][string]$Sol,
        [string]$Brute,
        [string]$Gen,
        [int]$N = 500,
        [int]$Seed = 1,
        [double]$Timeout = 0
    )
    $dir = (Get-Location).ProviderPath
    $solF = Get-JkCpSource $Sol
    $bruteF = $null; if ($Brute) { $bruteF = Get-JkCpSource $Brute } else { $bruteF = Find-JkCpHelper 'brute|naive|slow' $dir }
    $genF = $null; if ($Gen) { $genF = Get-JkCpSource $Gen } else { $genF = Find-JkCpHelper 'gen|generator' $dir }
    if (-not $solF -or -not $bruteF -or -not $genF) {
        throw 'stress needs a solution, brute.(cpp|py) and gen.(cpp|py) in this folder (gen gets the seed as its first argument)'
    }
    if (-not $Timeout) { $Timeout = [double](Get-JkConfig 'cp.timeout') }
    $tms = [int]($Timeout * 1000)
    $rs = Build-JkCp $solF; $rb = Build-JkCp $bruteF; $rg = Build-JkCp $genF
    Say (Paint 'gray' "  stress: $($solF.Name) vs $($bruteF.Name), inputs from $($genF.Name), $N rounds")
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $N; $i++) {
        $s = $Seed + $i
        $g = Invoke-JkProcess -Exe $rg.Exe -ArgList (@($rg.Args) + @("$s")) -TimeoutMs 10000 -WorkDir $dir
        if ($g.Code -ne 0 -or $g.TimedOut) { Say ''; throw "generator failed on seed $s (exit $($g.Code)) $($g.Err)" }
        $a = Invoke-JkProcess -Exe $rs.Exe -ArgList $rs.Args -InputText $g.Out -TimeoutMs $tms -WorkDir $dir
        $b = Invoke-JkProcess -Exe $rb.Exe -ArgList $rb.Args -InputText $g.Out -TimeoutMs ([Math]::Max($tms, 10000)) -WorkDir $dir
        $bad = $null
        $va = Get-JkVerdictText $a $tms
        if ($va) { $bad = "$($va[0]) in $($solF.Name): $($va[2])" }
        elseif ($b.Code -ne 0 -or $b.TimedOut) { $bad = "brute failed (exit $($b.Code))" }
        else {
            $cmp = Compare-JkOutput $b.Out $a.Out
            if (-not $cmp.Ok) { $bad = "WA: token $($cmp.Index + 1) expected '$($cmp.Expected)', got '$($cmp.Got)'" }
        }
        # progress every 10 rounds where a terminal rewrites it in place; the failing round always
        if (((($i % 10) -eq 0) -and (Test-JkInteractive)) -or $bad) { Write-Host ("`r  " + (Paint 'gray' "round $($i + 1)/$N  seed $s  ")) -NoNewline }
        if ($bad) {
            Say ''
            # keep the counterexample as the next numbered sample so plain `jk cp` re-checks it
            $k = 1
            while (Test-Path -LiteralPath (Join-Path $dir "$k.in")) { $k++ }
            Write-JkText (Join-Path $dir "$k.in") $g.Out
            $saved = "$k.in"
            if ($b.Code -eq 0 -and -not $b.TimedOut) { Write-JkText (Join-Path $dir "$k.out") $b.Out; $saved += " + $k.out (brute's answer)" }
            Say ('  ' + (Paint 'bold red' 'MISMATCH') + "  seed $s $($script:G.dot) $bad")
            Say (Paint 'gray' "  input (saved as $saved):")
            $inLines = @($g.Out.TrimEnd() -split "`r?`n")
            foreach ($l in ($inLines | Select-Object -First 12)) { Say ('    ' + $l) }
            if ($inLines.Count -gt 12) { Say (Paint 'gray' "    $($inLines.Count - 12) more lines$($script:G.ell)") }
            if (-not $va -and $b.Code -eq 0) { Write-JkSideBySide $b.Out $a.Out }
            Say (Paint 'gray' "  fix it, then: jk cp   (runs every sample, including this one)")
            return
        }
    }
    $sw.Stop()
    Say ''
    Say ('  ' + (Paint 'bold green' "$N/$N matched $($script:G.check)") + (Paint 'gray' " in $([Math]::Round($sw.Elapsed.TotalSeconds, 1))s"))
}

function Clear-JkCp {
    $here = (Get-Location).ProviderPath
    $removed = @()
    $dir = Join-Path $here $script:JkCpBuildDir
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force; $removed += $script:JkCpBuildDir }
    # older versions built into ".jk". Only remove one that is plainly a build cache: never the jk
    # data folder (~\.jk by default) and never a folder holding data files.
    $legacy = Join-Path $here '.jk'
    if (Test-Path -LiteralPath $legacy) {
        $isHome = (Resolve-JkLongPath $legacy) -eq (Resolve-JkLongPath (Get-JkHome))
        $hasData = @(Get-ChildItem -LiteralPath $legacy -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -notmatch '^\.(exe|stamp|class|jar|o|obj|pdb|ilk)$' }).Count -gt 0
        if ($isHome -or $hasData) { Say (Paint 'gray' "  left .jk alone: it is $(if ($isHome) { 'your jk data folder' } else { 'not just compiled files' })") }
        else { Remove-Item -LiteralPath $legacy -Recurse -Force; $removed += '.jk' }
    }
    if ($removed) { Say (Paint 'green' "  removed build cache ($($removed -join ', '))") }
    else { Say (Paint 'gray' '  no build cache here') }
}

function Invoke-JkCp {
    $a = @($args)
    if ($a.Count -eq 0) {
        if (Get-JkCpSource) { Invoke-JkCpTest } else { Show-JkHelp 'cp' }
        return
    }
    $first = ([string]$a[0]).ToLower()
    $rest = @()
    if ($a.Count -gt 1) { $rest = @($a[1..($a.Count - 1)]) }
    switch -Regex ($first) {
        '^(new|init|make)$' { New-JkCpProblem @rest; return }
        '^(test|t|check)$' { Invoke-JkCpTest @rest; return }
        '^(run|r)$' { Invoke-JkCpRun @rest; return }
        '^(add|paste|sample)$' { Add-JkCpTest @rest; return }
        '^(stress|s)$' { Invoke-JkCpStress @rest; return }
        '^(open|edit|o)$' { $src = Get-JkCpSource; if ($src) { Open-JkInEditor $src.FullName } else { Open-JkInEditor (Get-Location).ProviderPath }; return }
        '^(clean)$' { Clear-JkCp; return }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'cp'; return }
    }
    # jk cp main.cpp / jk cp -d / jk cp -Timeout 5
    Invoke-JkCpTest @a
}
