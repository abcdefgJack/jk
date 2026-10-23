# tidy.ps1 - Downloads organizer. Dry run by default; every apply is logged and undoable.
#   jk tidy            report: categories, biggest files, duplicates, stale installers
#   jk tidy apply      move loose files into category folders
#   jk tidy undo       put the last batch back
#   jk tidy dupes      list duplicate copies   (-Recycle sends extras to the Recycle Bin)
#   jk tidy old        installers/archives older than 30 days (-Recycle)

$script:TidyCategories = [ordered]@{
    'Installers' = @('.exe', '.msi', '.msix', '.msixbundle', '.appx', '.appxbundle', '.appinstaller')
    'Archives'   = @('.zip', '.rar', '.7z', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.iso', '.cab', '.img')
    'PDFs'       = @('.pdf')
    'Documents'  = @('.doc', '.docx', '.odt', '.rtf', '.txt', '.md', '.pages', '.tex', '.epub', '.log')
    'Slides'     = @('.ppt', '.pptx', '.key', '.odp')
    'Sheets'     = @('.xls', '.xlsx', '.xlsm', '.csv', '.tsv', '.ods', '.numbers')
    'Images'     = @('.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.bmp', '.svg', '.ico', '.tif', '.tiff', '.avif')
    'Video'      = @('.mp4', '.mov', '.mkv', '.avi', '.webm', '.wmv', '.m4v')
    'Audio'      = @('.mp3', '.wav', '.flac', '.m4a', '.ogg', '.aac', '.wma')
    'Code'       = @('.py', '.js', '.ts', '.java', '.cpp', '.c', '.h', '.hpp', '.cs', '.go', '.rs', '.ipynb', '.sh', '.ps1', '.sql', '.json', '.xml', '.yml', '.yaml', '.jar', '.class', '.r', '.m', '.kt', '.swift', '.php', '.rb', '.lua')
    'Web'        = @('.htm', '.html', '.mhtml', '.mht')
    'Fonts'      = @('.ttf', '.otf', '.woff', '.woff2')
    'Torrents'   = @('.torrent')
}
$script:TidyPartial = @('.crdownload', '.part', '.partial', '.download', '.tmp', '.opdownload')
$script:TidySkip = @('desktop.ini', 'thumbs.db')
$script:TidySkipExt = @('.lnk', '.url')

function Get-JkDownloadsPath {
    $cfg = Get-JkConfig 'tidy.path'
    if ($cfg) { return [Environment]::ExpandEnvironmentVariables($cfg) }
    try {
        $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($v) { return [Environment]::ExpandEnvironmentVariables($v) }
    } catch { }
    Join-Path $HOME 'Downloads'
}

# Long-form path (no 8.3 'JACKWA~1' parts) so it lines up with FullName of the files inside.
function Resolve-JkLongPath([string]$Path) { (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).FullName.TrimEnd('\') }

function Get-JkTidyCategory([string]$Ext) {
    $e = $Ext.ToLower()
    foreach ($k in $script:TidyCategories.Keys) { if ($script:TidyCategories[$k] -contains $e) { return $k } }
    'Other'
}

# Loose files in the folder, classified. Saved web pages keep their "<name>_files" folder.
function Get-JkTidyPlan {
    param([string]$Path, [int]$MinAgeDays = 2)
    $now = Get-Date
    $files = @(Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction SilentlyContinue | Where-Object {
            -not ($_.Attributes -band [IO.FileAttributes]::System) -and $script:TidySkip -notcontains $_.Name.ToLower() -and $script:TidySkipExt -notcontains $_.Extension.ToLower()
        })
    foreach ($f in $files) {
        $ext = $f.Extension.ToLower()
        $cat = Get-JkTidyCategory $ext
        $status = 'move'
        if ($script:TidyPartial -contains $ext) { $status = 'partial'; $cat = 'Partial' }
        elseif (($now - $f.LastWriteTime).TotalDays -lt $MinAgeDays) { $status = 'recent' }
        elseif ($f.Attributes -band [IO.FileAttributes]::Hidden) { $status = 'hidden' }
        $companion = $null
        if ($cat -eq 'Web') {
            $cdir = Join-Path $f.DirectoryName ($f.BaseName + '_files')
            if (Test-Path -LiteralPath $cdir) { $companion = $cdir }
        }
        [pscustomobject]@{ File = $f; Category = $cat; Status = $status; Companion = $companion; AgeDays = [int]($now - $f.LastWriteTime).TotalDays }
    }
}

function Get-JkUniquePath([string]$Dir, [string]$Name) {
    $p = Join-Path $Dir $Name
    if (-not (Test-Path -LiteralPath $p)) { return $p }
    $base = [IO.Path]::GetFileNameWithoutExtension($Name)
    $ext = [IO.Path]::GetExtension($Name)
    for ($i = 2; $i -lt 10000; $i++) {
        $p = Join-Path $Dir "$base ($i)$ext"
        if (-not (Test-Path -LiteralPath $p)) { return $p }
    }
    throw "could not find a free name for $Name in $Dir"
}

function Get-JkDuplicateGroups {
    param([object[]]$Files)
    $groups = @()
    $bySize = $Files | Where-Object { $_.Length -gt 0 } | Group-Object Length | Where-Object { $_.Count -gt 1 }
    foreach ($g in $bySize) {
        $hashed = foreach ($f in $g.Group) {
            try { [pscustomobject]@{ File = $f; Hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } } catch { }
        }
        foreach ($h in ($hashed | Group-Object Hash | Where-Object { $_.Count -gt 1 })) {
            # keep the cleanest name: no " (1)" / "copy" suffix, then the oldest
            $sorted = @($h.Group | Sort-Object @{ Expression = { if ($_.File.BaseName -match '\(\d+\)$|(?i)[ _-]copy( \d+)?$') { 1 } else { 0 } } }, @{ Expression = { $_.File.CreationTime } }, @{ Expression = { $_.File.Name.Length } })
            $groups += [pscustomobject]@{ Keep = $sorted[0].File; Extras = @($sorted | Select-Object -Skip 1 | ForEach-Object { $_.File }); Size = $g.Group[0].Length }
        }
    }
    $groups
}

function Send-JkToRecycleBin([string]$Path) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    if (Test-Path -LiteralPath $Path -PathType Container) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    } else {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    }
}

function Invoke-JkTidyRun {
    param([Parameter(Position = 0)][string]$Path, [switch]$Apply, [int]$MinAge = -1, [switch]$NoDupes)
    if (-not $Path) { $Path = Get-JkDownloadsPath }
    $Path = Resolve-JkLongPath $Path
    if ($MinAge -lt 0) { $MinAge = [int](Get-JkConfig 'tidy.minAge') }
    $plan = @(Get-JkTidyPlan -Path $Path -MinAgeDays $MinAge)
    if ($Apply) { Invoke-JkTidyApply $Path $plan; return }

    $w = Get-JkWidth
    $total = ($plan | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum
    if (-not $total) { $total = 0 }
    Write-JkHeader 'Tidy' "$($plan.Count) loose files $($script:G.dot) $(Format-JkSize $total)" -Sub $Path
    if ($plan.Count -eq 0) { Say (Paint 'green' "  Nothing to tidy. $($script:G.check)"); return }

    $byCat = $plan | Group-Object Category | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Count = $_.Count; Size = (($_.Group | ForEach-Object { $_.File.Length }) | Measure-Object -Sum).Sum; Moving = @($_.Group | Where-Object { $_.Status -eq 'move' }).Count }
    } | Sort-Object Size -Descending
    $maxSize = ($byCat | Measure-Object -Property Size -Maximum).Maximum
    if (-not $maxSize) { $maxSize = 1 }
    foreach ($c in $byCat) {
        Say ('  ' + (Paint 'bold white' (Fit $c.Name 12)) + (Paint 'muted' (Fit "$($c.Count) files" 11 -Right)) + (Paint 'white' (Fit (Format-JkSize $c.Size) 10 -Right)) + '  ' + (Get-JkBar ($c.Size / $maxSize) 24 'teal'))
    }

    Say ''
    Say (' ' + (Paint 'bold white' 'Biggest files'))
    foreach ($p in ($plan | Sort-Object { $_.File.Length } -Descending | Select-Object -First 6)) {
        Say ('  ' + (Paint 'white' (Fit (Format-JkSize $p.File.Length) 9 -Right)) + '  ' + (Fit $p.File.Name ([Math]::Max(20, $w - 34))) + (Paint 'gray' (Fit "$($p.AgeDays)d old" 10 -Right)))
    }

    $old = @($plan | Where-Object { ($_.Category -eq 'Installers' -or $_.Category -eq 'Archives') -and $_.AgeDays -ge 30 })
    $oldSize = ($old | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum
    Say ''
    if ($old.Count) {
        Say ('  ' + (Paint 'orange' "$($script:G.bullet) $($old.Count) installers/archives older than 30 days") + " $($script:G.dot) $(Format-JkSize $oldSize)" + (Paint 'gray' "   $($script:G.arrow) jk tidy old"))
    }
    if (-not $NoDupes) {
        $dupes = @(Get-JkDuplicateGroups ($plan | ForEach-Object { $_.File }))
        $extra = @($dupes | ForEach-Object { $_.Extras }).Count
        $dupSize = ($dupes | ForEach-Object { $_.Size * $_.Extras.Count } | Measure-Object -Sum).Sum
        if ($extra) {
            Say ('  ' + (Paint 'orange' "$($script:G.bullet) $extra duplicate copies") + " in $($dupes.Count) groups $($script:G.dot) $(Format-JkSize $dupSize) reclaimable" + (Paint 'gray' "   $($script:G.arrow) jk tidy dupes"))
        }
    }
    $recent = @($plan | Where-Object { $_.Status -eq 'recent' }).Count
    $partial = @($plan | Where-Object { $_.Status -eq 'partial' }).Count
    $moving = @($plan | Where-Object { $_.Status -eq 'move' })
    if ($recent -or $partial) {
        $bits = @()
        if ($recent) { $bits += "$recent newer than $MinAge days" }
        if ($partial) { $bits += "$partial unfinished downloads" }
        Say ('  ' + (Paint 'gray' ("$($script:G.bullet) left in place: " + ($bits -join ', '))))
    }
    $cats = @($moving | Group-Object Category).Count
    Say ''
    Say ('  ' + (Paint 'bold green' 'jk tidy apply') + " moves $($moving.Count) files into $cats folders inside $(Split-Path $Path -Leaf)\" + (Paint 'gray' "  (undo: jk tidy undo)"))
}

function Invoke-JkTidyApply([string]$Path, $Plan) {
    $moving = @($Plan | Where-Object { $_.Status -eq 'move' })
    if ($moving.Count -eq 0) { Say (Paint 'green' "  Nothing to move. $($script:G.check)"); return }
    $log = New-Object System.Collections.Generic.List[object]
    $failed = 0
    foreach ($p in $moving) {
        $destDir = Join-Path $Path $p.Category
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }
        try {
            $dest = Get-JkUniquePath $destDir $p.File.Name
            Move-Item -LiteralPath $p.File.FullName -Destination $dest -ErrorAction Stop
            $log.Add([pscustomobject]@{ from = $p.File.FullName; to = $dest })
            if ($p.Companion) {
                $cdest = Get-JkUniquePath $destDir (Split-Path $p.Companion -Leaf)
                Move-Item -LiteralPath $p.Companion -Destination $cdest -ErrorAction Stop
                $log.Add([pscustomobject]@{ from = $p.Companion; to = $cdest })
            }
        } catch {
            $failed++
            Say (Paint 'red' "  skipped $($p.File.Name): $($_.Exception.Message)")
        }
    }
    $dir = Get-JkPath 'tidy'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $name = (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json'
    Save-JkJson "tidy\$name" ([pscustomobject]@{ root = $Path; at = (Get-Date).ToString('s'); moves = $log.ToArray() })
    $summary = $moving | Group-Object Category | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) $($_.Count)" }
    Say ((Paint 'green' "  moved $($log.Count) items $($script:G.check)") + (Paint 'gray' "  $($summary -join ', ')"))
    if ($failed) { Say (Paint 'yellow' "  $failed files could not be moved (probably open in another program)") }
    Say (Paint 'gray' "  undo with: jk tidy undo")
}

function Undo-JkTidy {
    $dir = Get-JkPath 'tidy'
    $last = Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $last) { Say (Paint 'gray' '  Nothing to undo.'); return }
    $logData = Read-JkJson "tidy\$($last.Name)" $null
    $moves = @($logData.moves)
    [array]::Reverse($moves)
    $back = 0; $miss = 0
    foreach ($m in $moves) {
        if ((Test-Path -LiteralPath $m.to) -and -not (Test-Path -LiteralPath $m.from)) {
            Move-Item -LiteralPath $m.to -Destination $m.from
            $back++
        } else { $miss++ }
    }
    # remove category folders that the batch created and left empty
    foreach ($d in ($moves | ForEach-Object { Split-Path $_.to -Parent } | Select-Object -Unique)) {
        if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $d }
    }
    Move-Item -LiteralPath $last.FullName -Destination ($last.FullName + '.undone')
    Say ((Paint 'green' "  restored $back items $($script:G.check)") + $(if ($miss) { Paint 'yellow' "  ($miss had moved or been renamed since and were left alone)" } else { '' }))
}

# Loose downloads: files directly in the folder plus those jk tidy sorted into its own category
# folders. Never the inside of other folders (unzipped programs, cloned repos, projects), where a
# "duplicate" or an old .exe is part of something that works.
function Get-JkLooseDownloads([string]$Path) {
    $dirs = @($Path) + @(@($script:TidyCategories.Keys) + @('Other') | ForEach-Object { Join-Path $Path $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    foreach ($d in $dirs) {
        Get-ChildItem -LiteralPath $d -File -Force -ErrorAction SilentlyContinue | Where-Object { $script:TidySkip -notcontains $_.Name.ToLower() -and $script:TidySkipExt -notcontains $_.Extension.ToLower() }
    }
}

function Invoke-JkTidyDupes {
    param([Parameter(Position = 0)][string]$Path, [switch]$Recycle)
    if (-not $Path) { $Path = Get-JkDownloadsPath }
    $Path = Resolve-JkLongPath $Path
    $files = @(Get-JkLooseDownloads $Path)
    Say (Paint 'gray' "  hashing same-size files among $($files.Count)$($script:G.ell)")
    $groups = @(Get-JkDuplicateGroups $files | Sort-Object { $_.Size * $_.Extras.Count } -Descending)
    $extraCount = @($groups | ForEach-Object { $_.Extras }).Count
    $reclaim = ($groups | ForEach-Object { $_.Size * $_.Extras.Count } | Measure-Object -Sum).Sum
    Write-JkHeader 'Duplicates' "$extraCount extra copies $($script:G.dot) $(Format-JkSize $reclaim)" -Sub $Path
    if (-not $groups) { Say (Paint 'green' "  No duplicates. $($script:G.check)"); return }
    $w = Get-JkWidth
    foreach ($g in ($groups | Select-Object -First 25)) {
        Say ('  ' + (Paint 'green' "keep ") + (Fit ($g.Keep.FullName.Substring($Path.Length).TrimStart('\')) ($w - 18)) + (Paint 'gray' (Fit (Format-JkSize $g.Size) 9 -Right)))
        foreach ($x in $g.Extras) { Say ('  ' + (Paint 'red' "  dup ") + (Paint 'muted' (Fit ($x.FullName.Substring($Path.Length).TrimStart('\')) ($w - 9)))) }
    }
    if ($groups.Count -gt 25) { Say (Paint 'gray' "  $($groups.Count - 25) more groups$($script:G.ell)") }
    if ($Recycle) {
        $n = 0
        foreach ($g in $groups) { foreach ($x in $g.Extras) { try { Send-JkToRecycleBin $x.FullName; $n++ } catch { Say (Paint 'red' "  could not recycle $($x.Name): $($_.Exception.Message)") } } }
        Say ((Paint 'green' "  sent $n copies to the Recycle Bin $($script:G.check)") + (Paint 'gray' ' (restore them from there if needed)'))
    } else {
        Say ''
        Say (Paint 'gray' "  jk tidy dupes -Recycle  sends the 'dup' copies to the Recycle Bin (recoverable)")
    }
}

function Invoke-JkTidyOld {
    param([Parameter(Position = 0)][string]$Path, [int]$Days = 30, [switch]$Recycle)
    if (-not $Path) { $Path = Get-JkDownloadsPath }
    $Path = Resolve-JkLongPath $Path
    $now = Get-Date
    $exts = @($script:TidyCategories['Installers']) + @($script:TidyCategories['Archives'])
    $files = @(Get-JkLooseDownloads $Path | Where-Object { $exts -contains $_.Extension.ToLower() -and ($now - $_.LastWriteTime).TotalDays -ge $Days } | Sort-Object Length -Descending)
    $size = ($files | Measure-Object -Property Length -Sum).Sum
    Write-JkHeader 'Old installers & archives' "$($files.Count) files $($script:G.dot) $(Format-JkSize $size)" -Sub "older than $Days days"
    $w = Get-JkWidth
    foreach ($f in ($files | Select-Object -First 30)) {
        Say ('  ' + (Paint 'white' (Fit (Format-JkSize $f.Length) 9 -Right)) + '  ' + (Fit $f.FullName.Substring($Path.Length).TrimStart('\') ([Math]::Max(20, $w - 36))) + (Paint 'gray' (Fit ("$([int]($now - $f.LastWriteTime).TotalDays)d old") 10 -Right)))
    }
    if ($files.Count -gt 30) { Say (Paint 'gray' "  $($files.Count - 30) more$($script:G.ell)") }
    if ($Recycle) {
        $n = 0
        foreach ($f in $files) { try { Send-JkToRecycleBin $f.FullName; $n++ } catch { Say (Paint 'red' "  could not recycle $($f.Name)") } }
        Say ((Paint 'green' "  sent $n files to the Recycle Bin $($script:G.check)") + (Paint 'gray' " $($script:G.dot) $(Format-JkSize $size) (empty the bin to actually free the space)"))
    } elseif ($files.Count) {
        Say ''
        Say (Paint 'gray' "  jk tidy old -Recycle  sends these to the Recycle Bin (recoverable). -Days 90 to be pickier.")
    }
}

function Invoke-JkTidy {
    $a = @($args)
    if ($a.Count -eq 0) { Invoke-JkTidyRun; return }
    $first = ([string]$a[0]).ToLower()
    $rest = @()
    if ($a.Count -gt 1) { $rest = @($a[1..($a.Count - 1)]) }
    switch -Regex ($first) {
        '^(scan|report|status)$' { Invoke-JkTidyRun @rest; return }
        '^(apply|run|go|do)$' { Invoke-JkTidyRun -Apply @rest; return }
        '^(undo|revert)$' { Undo-JkTidy; return }
        '^(dupes|dups|duplicates)$' { Invoke-JkTidyDupes @rest; return }
        '^(old|stale|installers)$' { Invoke-JkTidyOld @rest; return }
        '^(help|-h|--help|\?)$' { Show-JkHelp 'tidy'; return }
    }
    Invoke-JkTidyRun @a
}
