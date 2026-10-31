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

# bits/stdc++.h is most of a compile. A precompiled copy, one per compiler and set of flags in
# %LOCALAPPDATA%\jk (about 150 MB each, so not in the backed-up data folder), takes a compile from
# 1.7 s to 0.6 s. GCC uses it only when the flags match and quietly falls back otherwise.
# Returns the folder to pass as -I, or $null when there is none (a failed build is not retried).
function Get-JkCpPch($Gpp, [string[]]$Flags, [string]$Mode, [switch]$Quiet) {
    $root = Join-Path (Get-JkCacheDir) "cp-pch\$Mode"
    $cflags = @($Flags | Where-Object { $_ -notlike '-Wl,*' })
    $stamp = (Get-Item -LiteralPath $Gpp.Source).LastWriteTimeUtc.Ticks
    $key = "$($Gpp.Source)|$stamp|$($cflags -join ' ')"
    $gch = Join-Path $root 'bits\stdc++.h.gch'
    $keyFile = Join-Path $root 'key.txt'
    $failFile = Join-Path $root 'failed.txt'
    if ((Test-Path -LiteralPath $gch) -and (Test-Path -LiteralPath $keyFile) -and [IO.File]::ReadAllText($keyFile) -eq $key) { return $root }
    if ((Test-Path -LiteralPath $failFile) -and [IO.File]::ReadAllText($failFile) -eq $key) { return $null }
    New-Item -ItemType Directory -Path (Join-Path $root 'bits') -Force | Out-Null
    $hdr = Join-Path $root 'pch.h'
    [IO.File]::WriteAllText($hdr, "#include <bits/stdc++.h>`n")
    if (-not $Quiet) { Write-Host (Paint 'gray' "  precompiling bits/stdc++.h for $Mode builds (once)$($script:G.ell)") -NoNewline }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # built under another name and renamed: a compile running meanwhile never reads half a file
    $tmp = "$gch.$PID.tmp"
    $res = Invoke-JkProcess -Exe $Gpp.Source -ArgList ($cflags + @('-x', 'c++-header', $hdr, '-o', $tmp)) -InputText '' -TimeoutMs 180000 -WorkDir $root
    if (-not $Quiet) { Write-Host "`r" -NoNewline }
    if ($res.Code -ne 0 -or -not (Test-Path -LiteralPath $tmp)) {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        [IO.File]::WriteAllText($failFile, $key)
        return $null
    }
    Move-Item -LiteralPath $tmp -Destination $gch -Force
    [IO.File]::WriteAllText($keyFile, $key)
    Remove-Item -LiteralPath $failFile -ErrorAction SilentlyContinue
    if (-not $Quiet) { Say (Paint 'gray' "  precompiled bits/stdc++.h in $([Math]::Round($sw.Elapsed.TotalSeconds, 1))s $($script:G.dash) later $Mode compiles reuse it") }
    $root
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
            $pchArgs = @()
            if ($ext -ne '.c' -and [IO.File]::ReadAllText($Src.FullName) -match '#\s*include\s*<bits/stdc\+\+\.h>') {
                $pch = Get-JkCpPch $gpp $flags $(if ($DebugBuild) { 'debug' } else { 'release' }) -Quiet:$Quiet
                if ($pch) { $pchArgs = @("-I$pch") }
            }
            if (-not $Quiet) { Write-Host (Paint 'gray' "  compiling $($Src.Name)$($script:G.ell)") -NoNewline }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $allArgs = $flags + $pchArgs + @('-o', $exe, $Src.FullName)
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

# Samples next to the solution, in tests\ or test\ (where online-judge-tools puts them): N.in with
# N.out / .ans / .expected, and old USACO test data's I.N with O.N.
function Get-JkCpTests([string]$Dir) {
    $dirs = @($Dir) + @('tests', 'test' | ForEach-Object { Join-Path $Dir $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    $ins = @(); $usaco = @()
    foreach ($d in $dirs) {
        $ins += @(Get-ChildItem -LiteralPath $d -File -Filter '*.in' -ErrorAction SilentlyContinue)
        $usaco += @(Get-ChildItem -LiteralPath $d -File -Filter 'I.*' -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.\d+$' })
    }
    $ins = @($ins | Where-Object { $_.BaseName -notmatch '^stress' })
    $out = foreach ($i in $ins) {
        $ans = $null
        foreach ($ext in '.out', '.ans', '.expected') {
            $p = Join-Path $i.DirectoryName ($i.BaseName + $ext)
            if (Test-Path -LiteralPath $p) { $ans = $p; break }
        }
        [pscustomobject]@{ Name = $i.BaseName; In = $i.FullName; Ans = $ans }
    }
    $out = @($out) + @(foreach ($i in $usaco) {
            $p = Join-Path $i.DirectoryName ('O' + $i.Extension)
            [pscustomobject]@{ Name = $i.Name; In = $i.FullName; Ans = $(if (Test-Path -LiteralPath $p) { $p } else { $null }) }
        })
    @($out | Where-Object { $_ } | Sort-Object { Get-JkNaturalKey ([IO.Path]::GetFileName($_.In)) })
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
        [switch]$NoOpen,
        $Samples   # samples already in hand (from jk cp listen): objects with In and Out
    )
    if (-not $Name) { throw 'usage: jk cp new <name or problem link> [-Lang cpp|py|java|usaco] [-Here]' }
    # a problem link: the folder is named after it and the page's samples become 1.in/1.out, 2.in...
    $fetched = $null; $judge = ''
    if ($null -ne $Samples) { $fetched = [pscustomobject]@{ Tests = @($Samples); FileIO = '' } }
    elseif ($Name -match '^(?i)https?://') {
        $link = Get-JkJudgeLink $Name
        if (-not $link) { throw 'jk reads problem links from AtCoder, USACO, CSES and Codeforces; for another judge: jk cp new <name>, then jk cp add per sample' }
        $url = $Name; $Name = $link.Name; $judge = $link.Judge
        if ($judge -ne 'codeforces') {
            try { $fetched = ConvertFrom-JkJudgeHtml $judge (Invoke-JkWebText $url) }
            catch { Say (Paint 'yellow' "  could not read the page ($($_.Exception.Message)); the samples will have to be pasted: jk cp add") }
            # USACO: the old file-I/O problems get the USACO template under their file name; newer
            # ones read standard input like anywhere else
            if ($judge -eq 'usaco' -and $fetched -and -not $Lang) {
                if ($fetched.FileIO) { $Lang = 'usaco'; $Name = $fetched.FileIO } else { $Lang = 'cpp' }
            }
        }
    }
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
    # the page's samples, into files that are missing or still empty (never over ones you filled in)
    $got = 0
    if ($fetched) {
        $i = 0
        foreach ($t in @($fetched.Tests)) {
            $i++
            foreach ($pair in @(@("$i.in", $t.In), @("$i.out", $t.Out))) {
                $p = Join-Path $dir $pair[0]
                if (-not (Test-Path -LiteralPath $p) -or (Get-Item -LiteralPath $p).Length -eq 0) { Write-JkText $p $pair[1] }
            }
            $got++
        }
    }
    Set-Location -LiteralPath $dir
    $shown = Resolve-JkLongPath $dir   # C:\Users\JACKWA~1\... from a short TEMP or cp.root
    $what = "($outName, 1.in, 1.out)"
    if ($got) { $what = "($outName, $(Format-JkCount $got 'sample'))" }
    if ($fresh) { Say ((Paint 'green' "  created $($script:G.check)") + "  $shown" + (Paint 'gray' "  $what")) }
    else { Say ((Paint 'yellow' '  exists') + "  $shown" + (Paint 'gray' $(if ($got) { " - switched to it, $(Format-JkCount $got 'sample')" } else { ' - switched to it' }))) }
    if ($judge -eq 'codeforces') { Say (Paint 'gray' "  Codeforces turns away scripts: copy each sample's input, jk cp add, then its output") }
    if ($got) { Say (Paint 'gray' "  test: jk cp   $($script:G.dot)   stress: add brute.cpp + gen.py, then jk cp stress") }
    else { Say (Paint 'gray' "  paste samples: copy input $($script:G.arrow) jk cp add   $($script:G.dot)   test: jk cp   $($script:G.dot)   stress: add brute.cpp + gen.py, then jk cp stress") }
    if (-not $NoOpen) { Open-JkInEditor $src }
}

# ---- problems from a judge's page: jk cp new https://atcoder.jp/contests/abc300/tasks/abc300_a

function Invoke-JkWebText([string]$Url) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20 -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) jk' -ErrorAction Stop
    [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
}

# A <pre> block's text: tags out, entities decoded, Windows line ends trimmed per line, one final newline.
function ConvertFrom-JkPreHtml([string]$Html) {
    $t = [Net.WebUtility]::HtmlDecode(($Html -replace '(?i)<br\s*/?>', "`n" -replace '<[^>]+>', ''))
    $lines = @(($t -replace "`r", '') -split "`n" | ForEach-Object { $_.TrimEnd() })
    ($lines -join "`n").Trim("`n") + "`n"
}

# The samples on a judge's problem page, by judge: AtCoder ("Sample Input 1", or the Japanese
# headings when there is no English), USACO (<pre class='in'> / 'out', and the file name of the
# older file-I/O problems), CSES ("Input:" / "Output:").
function ConvertFrom-JkJudgeHtml([string]$Judge, [string]$Html) {
    $tests = @(); $io = ''
    $pair = { param($ins, $outs) for ($i = 0; $i -lt [Math]::Min(@($ins).Count, @($outs).Count); $i++) { [pscustomobject]@{ In = (ConvertFrom-JkPreHtml $ins[$i]); Out = (ConvertFrom-JkPreHtml $outs[$i]) } } }
    switch ($Judge) {
        'atcoder' {
            $part = $Html
            $en = [regex]::Match($Html, '(?s)<span class="lang-en">(.*)')
            if ($en.Success) { $part = $en.Groups[1].Value }
            $inH = 'Sample Input'; $outH = 'Sample Output'
            if ($part -notmatch $inH) { $inH = [string][char]0x5165 + [char]0x529B + [char]0x4F8B; $outH = [string][char]0x51FA + [char]0x529B + [char]0x4F8B }
            $ins = @([regex]::Matches($part, "(?s)<h3>$inH\s*\d+</h3>\s*<pre>(.*?)</pre>") | ForEach-Object { $_.Groups[1].Value })
            $outs = @([regex]::Matches($part, "(?s)<h3>$outH\s*\d+</h3>\s*<pre>(.*?)</pre>") | ForEach-Object { $_.Groups[1].Value })
            $tests = @(& $pair $ins $outs)
        }
        'usaco' {
            $ins = @([regex]::Matches($Html, "(?s)<pre class=['""]in['""]>(.*?)</pre>") | ForEach-Object { $_.Groups[1].Value })
            $outs = @([regex]::Matches($Html, "(?s)<pre class=['""]out['""]>(.*?)</pre>") | ForEach-Object { $_.Groups[1].Value })
            $tests = @(& $pair $ins $outs)
            $f = [regex]::Match($Html, '(?i)SAMPLE INPUT \(file ([A-Za-z0-9_]+)\.in\)')
            if ($f.Success) { $io = $f.Groups[1].Value }
            if (-not $tests.Count) {
                # the oldest problems are plain text: "SAMPLE INPUT (file x.in):", the data, then the next
                # capitalised heading ("INPUT DETAILS:", "SAMPLE OUTPUT ...") after a blank line
                $plain = ($Html -replace "`r", '')
                $grab = { param($what) $m = [regex]::Match($plain, "(?s)SAMPLE $what(?: \(file [^)]*\))?:[ \t]*\n(.*?)\n[ \t]*\n(?=[ \t]*([A-Z][A-Z ]+[A-Z]:|SAMPLE |<|$))"); if ($m.Success) { $m.Groups[1].Value } }
                $i1 = & $grab 'INPUT'; $o1 = & $grab 'OUTPUT'
                if ($i1 -and $o1) { $tests = @([pscustomobject]@{ In = (ConvertFrom-JkPreHtml $i1); Out = (ConvertFrom-JkPreHtml $o1) }) }
            }
        }
        'cses' {
            foreach ($m in [regex]::Matches($Html, '(?s)<p>Input:</p>\s*<pre>(.*?)</pre>\s*<p>Output:</p>\s*<pre>(.*?)</pre>')) {
                $tests += [pscustomobject]@{ In = (ConvertFrom-JkPreHtml $m.Groups[1].Value); Out = (ConvertFrom-JkPreHtml $m.Groups[2].Value) }
            }
        }
    }
    [pscustomobject]@{ Tests = @($tests); FileIO = $io }
}

# Which judge a link is, and a folder name for it. $null when it is no problem link jk knows.
function Get-JkJudgeLink([string]$Url) {
    if ($Url -match '(?i)atcoder\.jp/contests/[^/]+/tasks/([A-Za-z0-9_]+)') { return [pscustomobject]@{ Judge = 'atcoder'; Name = $Matches[1].ToLower() } }
    if ($Url -match '(?i)usaco\.org/.*cpid=(\d+)') { return [pscustomobject]@{ Judge = 'usaco'; Name = "usaco$($Matches[1])" } }
    if ($Url -match '(?i)cses\.fi/problemset/task/(\d+)') { return [pscustomobject]@{ Judge = 'cses'; Name = "cses$($Matches[1])" } }
    if ($Url -match '(?i)codeforces\.com/(?:contest|gym)/(\d+)/problem/([A-Za-z0-9]+)|codeforces\.com/problemset/problem/(\d+)/([A-Za-z0-9]+)') {
        $n = "cf$($Matches[1])$($Matches[3])$($Matches[2])$($Matches[4])"
        return [pscustomobject]@{ Judge = 'codeforces'; Name = $n }
    }
    $null
}

# ---- jk cp listen: problems sent by the Competitive Companion browser extension (the green + on a
# problem page), which works on Codeforces too: the browser has the page, no script has to fetch it.

# One HTTP request off a stream: the method, and the body as UTF-8 (Content-Length bytes).
function Read-JkHttpRequest([IO.Stream]$Stream) {
    $buf = New-Object byte[] 65536
    $data = New-Object System.Collections.Generic.List[byte]
    $headEnd = -1; $length = 0
    while ($true) {
        $n = $Stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $data.AddRange([byte[]]($buf[0..($n - 1)]))
        if ($headEnd -lt 0) {
            $text = [Text.Encoding]::ASCII.GetString($data.ToArray())
            $headEnd = $text.IndexOf("`r`n`r`n")
            if ($headEnd -ge 0) {
                $m = [regex]::Match($text.Substring(0, $headEnd), '(?im)^Content-Length:\s*(\d+)')
                if ($m.Success) { $length = [int]$m.Groups[1].Value }
            }
        }
        if ($headEnd -ge 0 -and $data.Count -ge $headEnd + 4 + $length) { break }
    }
    if ($headEnd -lt 0) { return $null }
    $all = $data.ToArray()
    $head = [Text.Encoding]::ASCII.GetString($all, 0, $headEnd)
    $body = [Text.Encoding]::UTF8.GetString($all, $headEnd + 4, [Math]::Min($length, $all.Length - $headEnd - 4))
    [pscustomobject]@{ Method = ($head -split ' ')[0]; Body = $body }
}

# A Competitive Companion problem (its JSON) as a jk problem: the folder name from the link (or the
# title), the samples, and the USACO template when the judge reads and writes files.
function ConvertFrom-JkCompanion($Json) {
    $p = $Json
    if ($p -is [string]) { $p = $p | ConvertFrom-Json }
    $name = $null
    $link = Get-JkJudgeLink ([string]$p.url)
    if ($link) { $name = $link.Name }
    if (-not $name) {
        # "A. Watermelon" -> watermelon; the group keeps contests apart only by its folder name
        $name = (([string]$p.name -replace '^[A-Z0-9]{1,3}[.:)]\s+', '') -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower()
        if (-not $name) { $name = 'problem' }
    }
    $lang = ''
    if ($p.input -and [string]$p.input.type -eq 'file' -and [string]$p.input.fileName -match '^([A-Za-z0-9_]+)\.in$') { $lang = 'usaco'; $name = $Matches[1] }
    $tests = @(foreach ($t in @($p.tests)) { [pscustomobject]@{ In = ConvertFrom-JkPreHtml ([Net.WebUtility]::HtmlEncode([string]$t.input)); Out = ConvertFrom-JkPreHtml ([Net.WebUtility]::HtmlEncode([string]$t.output)) } })
    $size = 1; if ($p.batch -and [int]$p.batch.size -gt 0) { $size = [int]$p.batch.size }
    [pscustomobject]@{ Name = $name; Lang = $lang; Tests = $tests; Title = [string]$p.name; Group = [string]$p.group; BatchSize = $size; Interactive = [bool]$p.interactive }
}

function Invoke-JkCpListen {
    param([int]$Port = 0, [int]$Timeout = 300, [switch]$NoOpen)
    if (-not $Port) { $Port = [int](Get-JkConfig 'cp.port') }
    $listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, $Port)
    try { $listener.Start() } catch { throw "port $Port is taken (another tool listening for Competitive Companion?): jk cp listen -Port 10046, and add that port in the extension's options" }
    $made = @(); $want = 1; $deadline = (Get-Date).AddSeconds($Timeout)
    Say (Paint 'gray' "  waiting on port ${Port}: press Competitive Companion's green + on the problem or contest (Ctrl+C stops)")
    try {
        while ($made.Count -lt $want -and (Get-Date) -lt $deadline) {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 100; continue }
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $stream.ReadTimeout = 5000
                $req = Read-JkHttpRequest $stream
                $ok = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                $stream.Write($ok, 0, $ok.Length)
            } finally { $client.Close() }
            if (-not $req -or $req.Method -ne 'POST' -or -not $req.Body.Trim()) { continue }
            $prob = ConvertFrom-JkCompanion $req.Body
            $want = [Math]::Max($want, $prob.BatchSize)
            # a contest arrives one problem at a time: each beside the others, the editor once at the end
            $here = (Get-Location).ProviderPath
            New-JkCpProblem $prob.Name -Lang $prob.Lang -Samples $prob.Tests -NoOpen 6>&1 | Where-Object { "$_" -match 'created|exists' } | ForEach-Object { Say "$_" }
            if ($prob.Interactive) { Say (Paint 'yellow' "    interactive: the samples show one exchange, so jk cp can only compare the output") }
            $made += (Get-Location).ProviderPath
            if ($made.Count -lt $want) { Set-Location -LiteralPath $here }
        }
    } finally { $listener.Stop() }
    if (-not $made.Count) { throw "nothing arrived in $Timeout s. Is the extension on, and does it send to port $Port? (its options: custom ports)" }
    if ($made.Count -lt $want) { Say (Paint 'yellow' "  $($made.Count) of $want problems arrived before the time ran out") }
    Set-Location -LiteralPath $made[0]
    Say (Paint 'gray' "  test: jk cp   $($script:G.dot)   $(if ($made.Count -gt 1) { 'cd ..\<next> for the others' } else { 'stress: add brute.cpp + gen.py, then jk cp stress' })")
    if (-not $NoOpen) { $src = Get-JkCpSource; if ($src) { Open-JkInEditor $src.FullName } }
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
    param([switch]$Pch)
    if ($Pch) {
        # the precompiled headers: rebuilt on the next compile that needs one
        $p = Join-Path (Get-JkCacheDir) 'cp-pch'
        if (Test-Path -LiteralPath $p) {
            $size = (Get-ChildItem -LiteralPath $p -Recurse -File -Force | Measure-Object Length -Sum).Sum
            Remove-Item -LiteralPath $p -Recurse -Force
            Say (Paint 'green' "  removed the precompiled headers ($(Format-JkSize $size)); the next compile rebuilds what it needs")
        } else { Say (Paint 'gray' '  no precompiled headers') }
        return
    }
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
        '^(listen|get|companion|cc)$' { Invoke-JkCpListen @rest; return }
        '^(test|t|check)$' { Invoke-JkCpTest @rest; return }
        '^(run|r)$' { Invoke-JkCpRun @rest; return }
        '^(add|paste|sample)$' { Add-JkCpTest @rest; return }
        '^(stress|s)$' { Invoke-JkCpStress @rest; return }
        '^(open|edit|o)$' { $src = Get-JkCpSource; if ($src) { Open-JkInEditor $src.FullName } else { Open-JkInEditor (Get-Location).ProviderPath }; return }
        '^(clean)$' { Clear-JkCp -Pch:(@($rest | Where-Object { "$_" -match '^-?pch$' }).Count -gt 0); return }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'cp'; return }
    }
    # jk cp main.cpp / jk cp -d / jk cp -Timeout 5
    Invoke-JkCpTest @a
}
