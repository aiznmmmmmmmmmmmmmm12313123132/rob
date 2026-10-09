
# -----------------------------------------------------------------------------
# 6a. Elevation broker. The normal (non-admin) window asks Windows to start a
#     second, visible copy of this file elevated, passing only an action word,
#     category ids and a result-file path in our own folder. The elevated copy
#     re-checks everything itself and only accepts administrator categories.
# -----------------------------------------------------------------------------
function ConvertTo-Hashtable {
    param([object]$InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in @($InputObject.Keys)) { $h[[string]$k] = ConvertTo-Hashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $arr = @()
        foreach ($i in $InputObject) { $arr += , (ConvertTo-Hashtable $i) }
        return , $arr
    }
    return $InputObject
}

function Test-ExchangePath {
    # Returns $null when the result path is acceptable, else the reason.
    param([string]$Path)
    if (-not (Test-FullyQualifiedLocalPath $Path)) { return 'not a full local path' }
    $n = Get-NormalizedPath $Path
    if (-not $n) { return 'invalid path' }
    if ((Split-Path -Leaf $n) -notmatch '^elevated-[0-9a-f]{32}\.json$') { return 'unexpected file name' }
    $dir = Split-Path -Parent $n
    if ((Split-Path -Leaf $dir) -ne 'Exchange') { return 'unexpected folder' }
    $app = Split-Path -Parent $dir
    if ((Split-Path -Leaf $app) -ne 'aiznm_CLEANER') { return 'unexpected folder' }
    foreach ($d in @($dir, $app)) {
        $di = New-Object IO.DirectoryInfo($d)
        $di.Refresh()
        if (-not $di.Exists) { return 'folder does not exist' }
        if (($di.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return 'folder is a junction or link' }
    }
    if ([IO.File]::Exists($n) -or [IO.Directory]::Exists($n)) { return 'result file already exists' }
    return $null
}

function Write-ExchangeFile {
    param([string]$Path, [string]$Text)
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = $script:Utf8NoBom.GetBytes($Text)
        $fs.Write($bytes, 0, $bytes.Length)
    } finally { $fs.Dispose() }
}

function Test-ElevatedRequest {
    # Validates the elevated request. Returns @{ Ok; Reason; Ids }.
    param([string]$Action, [string]$Tasks)
    $r = @{ Ok = $false; Reason = ''; Ids = @() }
    if ($Action -ne 'scan' -and $Action -ne 'clean') { $r.Reason = 'Unknown action.'; return $r }
    # Ids are joined with '+' because CMD treats commas, semicolons and '='
    # as argument separators.
    if ($Tasks -notmatch '^[A-Za-z]{2,24}(\+[A-Za-z]{2,24}){0,15}$') { $r.Reason = 'Invalid category list.'; return $r }
    $ids = @($Tasks.Split('+') | Select-Object -Unique)
    foreach ($id in $ids) {
        $c = Get-Category $id
        if ($null -eq $c) { $r.Reason = "Unknown category '$id'."; return $r }
        if (-not $c.Admin) { $r.Reason = "Category '$id' does not need administrator rights and is not run elevated."; return $r }
    }
    $r.Ok = $true
    $r.Ids = $ids
    return $r
}

function Invoke-ElevatedHelper {
    param([string]$Action, [string[]]$Ids)
    $out = @{ Ok = $false; Cancelled = $false; Error = ''; Results = @(); ExitCode = $null }
    $ex = Initialize-AppDir 'Exchange'
    if (-not $ex) { $out.Error = 'The folder used to exchange results with the administrator window could not be created.'; return $out }
    $self = [string]$env:AIZNM_SELF
    if (-not $self -or -not [IO.File]::Exists($self)) { $out.Error = 'This program file could not be located, so the administrator helper cannot start.'; return $out }
    $file = Join-Path $ex ('elevated-' + [guid]::NewGuid().ToString('N') + '.json')
    $argLine = '--elevated {0} "{1}" "{2}"' -f $Action, ($Ids -join '+'), $file
    try {
        $p = Start-Process -FilePath $self -ArgumentList $argLine -Verb RunAs -PassThru -Wait -ErrorAction Stop
        try { $out.ExitCode = $p.ExitCode } catch { }
    } catch {
        $code = $null
        $e = $_.Exception
        while ($null -ne $e) {
            if ($e -is [ComponentModel.Win32Exception]) { $code = $e.NativeErrorCode }
            $e = $e.InnerException
        }
        if ($code -eq 1223) {
            $out.Cancelled = $true
            $out.Error = 'Administrator permission was not granted (the Windows UAC prompt was cancelled).'
        } else {
            $out.Error = 'The administrator helper could not be started: ' + (Get-InnerMessage $_.Exception)
        }
        return $out
    }
    if (-not [IO.File]::Exists($file)) {
        $out.Error = ('The administrator window closed without returning results (exit code {0}).' -f $out.ExitCode)
        return $out
    }
    $parsed = Read-ElevatedResult $file
    try { [IO.File]::Delete($file) } catch { }
    $out.Results = $parsed.Results
    $out.Error = $parsed.Error
    $out.Ok = $parsed.Ok
    return $out
}

function Read-ElevatedResult {
    # Parses the JSON written by the elevated copy. Results are re-shaped
    # into the same hashtables the normal window produces.
    param([string]$File)
    $r = @{ Ok = $false; Error = ''; Results = @() }
    try {
        $data = ConvertTo-Hashtable ([IO.File]::ReadAllText($File) | ConvertFrom-Json)
        if (-not ($data -is [hashtable])) { throw 'unexpected content' }
        if ($data['Fatal']) { $r.Error = [string]$data['Fatal'] }
        $list = @()
        foreach ($x in @($data['Results'])) {
            if ($x -is [hashtable] -and $x.ContainsKey('Id')) {
                if (-not ($x.Stats -is [hashtable])) { $x.Stats = New-WalkStats }
                foreach ($k in @('Extra', 'Notes', 'Targets')) { if ($null -eq $x[$k]) { if ($k -eq 'Extra') { $x[$k] = @{} } else { $x[$k] = @() } } }
                if (-not ($x.Stats.Samples -is [hashtable])) { $x.Stats.Samples = @{} }
                $list += $x
            }
        }
        $r.Results = $list
        $r.Ok = -not $data['Fatal']
    } catch {
        $r.Error = 'Results from the administrator window could not be read: ' + (Get-InnerMessage $_.Exception)
    }
    return $r
}

function Invoke-ElevatedEntry {
    # Runs inside the elevated copy. Shows its own progress, writes results,
    # closes itself.
    $script:IsElevatedChild = $true
    $global:AIZNM_EXIT = 3
    Initialize-Console
    $resultPath = [string]$env:AIZNM_ELEV_RESULT
    try {
        Write-UI ''
        Write-UI ('  ' + ('=' * $script:UiWidth)) DarkCyan
        Write-UI ('   {0} v{1} - ADMINISTRATOR TASK' -f $script:AppName.ToUpperInvariant(), $script:AppVersion) Cyan
        Write-UI ('  ' + ('=' * $script:UiWidth)) DarkCyan
        Write-UI '   Started from your aiznm CLEANER window. Results are shown there when this finishes.' DarkGray
        Write-UI '   Press Esc or Ctrl+C to stop safely after the current file.' DarkGray
        Write-UI ''
        $pathError = Test-ExchangePath $resultPath
        if ($pathError) {
            Write-UI ('  Refusing to run: the result location is not valid ({0}). Nothing was changed.' -f $pathError) Red
            Start-Sleep -Seconds 8
            return
        }
        $payload = @{ Version = $script:AppVersion; Action = [string]$env:AIZNM_ELEV_ACTION; StartedUtc = [DateTime]::UtcNow.ToString('o'); Results = @(); Fatal = $null; DeleteMode = '' }
        $req = Test-ElevatedRequest ([string]$env:AIZNM_ELEV_ACTION) ([string]$env:AIZNM_ELEV_TASKS)
        if (-not $req.Ok) { $payload.Fatal = 'Request refused: ' + $req.Reason }
        elseif (-not (Test-IsAdmin)) { $payload.Fatal = 'This window is not running with administrator rights.' }
        else {
            $excl = Get-PendingRenameExclusions
            if ($payload.Action -eq 'clean') {
                $mode = Set-DeleteMode
                $payload.DeleteMode = $mode.Mode
                if (-not $mode.Ok) { $payload.Fatal = $mode.Reason }
            }
            if (-not $payload.Fatal) {
                $i = 0
                foreach ($id in $req.Ids) {
                    $i++
                    $cat = Get-Category $id
                    if ($script:CancelRequested) {
                        $res = New-CategoryResult $cat
                        $res.Status = 'Cancelled'; $res.Detail = 'Not started (stopped by you).'
                    } else {
                        Write-UI ('  [{0}/{1}] {2} - {3}...' -f $i, $req.Ids.Count, $cat.Name, $(if ($payload.Action -eq 'clean') { 'cleaning' } else { 'measuring' })) White
                        if ($payload.Action -eq 'clean') { $res = Invoke-CategoryClean $cat $excl }
                        else { $res = Invoke-CategoryScan $cat $excl }
                    }
                    if ($payload.Action -eq 'clean') {
                        Write-Segments @(@('        ', 'Gray'), @($res.Status, (Write-StatusTag $res.Status)), @($(if ($res.Detail) { ' - ' + $res.Detail } else { '' }), 'Gray'))
                    } else {
                        Write-UI ('        estimated {0}' -f (Format-Bytes $res.Stats.EligibleBytes)) Gray
                    }
                    $payload.Results += $res
                }
            }
        }
        $payload.FinishedUtc = [DateTime]::UtcNow.ToString('o')
        Write-ExchangeFile $resultPath ($payload | ConvertTo-Json -Depth 8 -Compress)
        if ($payload.Fatal) { Write-UI ('  ' + $payload.Fatal) Red; $global:AIZNM_EXIT = 4 } else { $global:AIZNM_EXIT = 0 }
        Write-UI ''
        Write-UI '  Finished. This window closes in 5 seconds (press any key to close now).' DarkGray
        Clear-KeyBuffer
        for ($t = 0; $t -lt 50; $t++) {
            try { if ([Console]::KeyAvailable) { break } } catch { }
            Start-Sleep -Milliseconds 100
        }
    } catch {
        $global:AIZNM_EXIT = 5
        Write-UI ('  Unexpected error: ' + $_.Exception.Message) Red
        try {
            if (-not (Test-ExchangePath $resultPath)) {
                Write-ExchangeFile $resultPath (@{ Version = $script:AppVersion; Results = @(); Fatal = ('Unexpected error in the administrator window: ' + $_.Exception.Message) } | ConvertTo-Json -Depth 4 -Compress)
            }
        } catch { }
        Start-Sleep -Seconds 8
    } finally {
        Restore-Console
    }
}

# -----------------------------------------------------------------------------
# 6b. Drive measurements
# -----------------------------------------------------------------------------
function Get-DriveSnapshot {
    param([string[]]$Roots)
    $snap = [ordered]@{}
    foreach ($r in $Roots) {
        try {
            $d = New-Object IO.DriveInfo($r)
            if ($d.IsReady) {
                $snap[$r] = @{ Root = $r; Total = [long]$d.TotalSize; Free = [long]$d.AvailableFreeSpace; TotalFree = [long]$d.TotalFreeSpace; Label = [string]$d.VolumeLabel; Format = [string]$d.DriveFormat }
            }
        } catch { }
    }
    return $snap
}

function Get-FixedDriveRoots {
    $roots = @()
    try { foreach ($d in [IO.DriveInfo]::GetDrives()) { if ($d.DriveType -eq [IO.DriveType]::Fixed -and $d.IsReady) { $roots += $d.RootDirectory.FullName } } } catch { }
    return $roots
}

function Get-TargetDriveRoots {
    param([object[]]$Cats)
    $set = New-Object 'System.Collections.Generic.List[string]'
    $sys = Get-SystemDriveRoot
    if ($sys) { $set.Add($sys) }
    foreach ($c in $Cats) {
        $roots = @()
        if ($c.Handler -eq 'RecycleBin') { $roots = Get-FixedDriveRoots }
        else { foreach ($s in (Get-ResolvedTargets $c)) { if ($s.Path) { $roots += [IO.Path]::GetPathRoot($s.Path) } } }
        foreach ($r in $roots) {
            $dup = $false
            foreach ($x in $set) { if (Test-SamePath $x $r) { $dup = $true } }
            if (-not $dup) { $set.Add($r) }
        }
    }
    return @($set)
}

function Get-DriveDeltas {
    # Measured change per drive from two snapshots (can be negative).
    param([System.Collections.IDictionary]$Before, [System.Collections.IDictionary]$After)
    $rows = @()
    foreach ($k in @($Before.Keys)) {
        if (-not $After.Contains($k)) { continue }
        $b = $Before[$k]; $a = $After[$k]
        $rows += @{ Root = $k; Before = [long]$b.Free; After = [long]$a.Free; Delta = ([long]$a.Free - [long]$b.Free); Total = [long]$a.Total }
    }
    return $rows
}

function Write-DriveLine {
    $sys = Get-SystemDriveRoot
    if (-not $sys) { return }
    $s = Get-DriveSnapshot @($sys)
    if ($s.Contains($sys)) {
        $d = $s[$sys]
        $used = $d.Total - $d.TotalFree
        Write-Segments @(@('  System drive ', 'DarkGray'), @($sys.TrimEnd('\'), 'White'), @('   free ', 'DarkGray'), @((Format-Bytes $d.Free), 'Green'), @(' of ', 'DarkGray'), @((Format-Bytes $d.Total), 'White'), @(('   used {0}' -f (Format-Bytes $used)), 'DarkGray'))
    }
}

# -----------------------------------------------------------------------------
# 6c. Scan, selection and confirmation screens
# -----------------------------------------------------------------------------
function Invoke-ScanCategories {
    param([object[]]$Cats)
    $excl = Get-PendingRenameExclusions
    $results = @{}
    $script:CancelRequested = $false
    $i = 0
    foreach ($c in $Cats) {
        $i++
        Write-ProgressLine ('Scanning [{0}/{1}] {2}...  (Esc to stop)' -f $i, $Cats.Count, $c.Name) -Force
        $results[$c.Id] = Invoke-CategoryScan $c $excl
        if ($script:CancelRequested) { break }
    }
    Clear-ProgressLine
    return $results
}

function Get-SizeText {
    param([hashtable]$Res)
    if ($null -eq $Res) { return 'not scanned' }
    if (-not $Res.Applicable) { return '-' }
    switch ($Res.SizeState) {
        'Unknown' { return 'unknown' }
        'Partial' { return ('>=' + (Format-Bytes $Res.Stats.EligibleBytes)) }
        default { return (Format-Bytes $Res.Stats.EligibleBytes) }
    }
}

function Get-RowNote {
    param([hashtable]$Cat, [hashtable]$Res)
    if ($null -eq $Res) { return '' }
    if (-not $Res.Applicable) {
        $why = [string]$Res.Reason
        if ($why -match '^Refused') { return 'REFUSED (safety) - see ?' }
        if ($why -match 'not present') { return 'not present on this PC' }
        if ($why -match '^Not installed') { return 'not installed' }
        if ($why -match 'No AMD') { return 'no AMD graphics card' }
        if ($why -match 'No NVIDIA') { return 'no NVIDIA graphics card' }
        if ($why -match 'No Intel') { return 'no Intel graphics' }
        if ($why -match 'module|cmdlet|does not provide') { return 'not available - see ?' }
        return $why
    }
    if ($Res.Extra.ContainsKey('Running') -and $Res.Extra.Running) { return 'OPEN - will be skipped' }
    if ($Res.SizeState -eq 'Unknown' -and $Cat.Admin) { return 'needs admin to measure (R)' }
    if ($Cat.Irreversible) { return 'PERMANENT, typed confirm' }
    $bits = @()
    if ($Res.Extra.ContainsKey('Profiles')) { $bits += ('{0} profile(s)' -f @($Res.Extra.Profiles).Count) }
    if ($Res.Stats.RecentFiles -gt 0) { $bits += ('{0} recent kept' -f (Format-Count $Res.Stats.RecentFiles)) }
    if ($Cat.Risk -eq 'Medium') { $bits += 'side effects - see ?' }
    return ($bits -join ', ')
}

function Get-WrappedLines {
    param([string]$Text, [int]$Width)
    $lines = @()
    $line = ''
    foreach ($word in ($Text -split '\s+')) {
        if ($word -eq '') { continue }
        if ($line.Length -eq 0) { $line = $word }
        elseif (($line.Length + 1 + $word.Length) -le $Width) { $line = $line + ' ' + $word }
        else { $lines += $line; $line = $word }
    }
    if ($line.Length -gt 0) { $lines += $line }
    return $lines
}

function Get-CategoryDetailLines {
    # Full description of one category plus its scan numbers, as
    # @( @(text, colour), ... ). Used on screen and (as text) in logs.
    param([hashtable]$Cat, [hashtable]$Res)
    $out = New-Object 'System.Collections.Generic.List[object]'
    $w = $script:UiWidth - 22
    $out.Add(@(('  ' + $Cat.Name.ToUpperInvariant()), 'Cyan'))
    $rows = @(
        @('What it removes', $Cat.Removes),
        @('Why it helps', $Cat.Why),
        @('Side effects', $Cat.Side),
        @('Regenerated', $Cat.Regenerates),
        @('Close first', $Cat.CloseFirst),
        @('Administrator', $(if ($Cat.Admin) { 'Yes - Windows will ask (UAC) when you start the cleanup' } else { 'No' })),
        @('Risk', $Cat.Risk),
        @('Default', $(if ($Cat.Default) { 'Preselected (low risk)' } else { 'Opt-in only' })),
        @('Reversible', $(if ($Cat.Irreversible) { 'NO - permanent' } else { 'No (deleted, not moved to the Recycle Bin), but the data is not personal' }))
    )
    foreach ($row in $rows) {
        $wrapped = @(Get-WrappedLines ([string]$row[1]) $w)
        for ($i = 0; $i -lt $wrapped.Count; $i++) {
            $k = ''
            if ($i -eq 0) { $k = $row[0] }
            $out.Add(@(('    ' + $k.PadRight(17) + ' ' + $wrapped[$i]), 'Gray'))
        }
    }
    if ($Res) {
        if (-not $Res.Applicable) { $out.Add(@(('    {0} {1}' -f 'Status'.PadRight(17), $Res.Reason), 'DarkGray')) }
        foreach ($t in @($Res.Targets)) {
            $sz = 'n/a'
            if ($t.State -eq 'OK') { $sz = '{0} in {1} file(s)' -f (Format-Bytes $t.Bytes), (Format-Count $t.Files) }
            elseif ($t.State -eq 'Missing') { $sz = 'not present' }
            elseif ($t.State -eq 'Unreadable') { $sz = 'cannot be read without administrator rights' }
            elseif ($t.State -eq 'Refused') { $sz = $t.Reason }
            $out.Add(@(('    {0} {1}' -f 'Location'.PadRight(17), $t.Path), 'White'))
            $out.Add(@(('    {0} {1}' -f ''.PadRight(17), $sz), 'DarkGray'))
        }
        if ($Res.Applicable) {
            $st = $Res.Stats
            $out.Add(@(('    {0} {1} in {2} file(s) eligible now' -f 'Estimate'.PadRight(17), (Get-SizeText $Res), (Format-Count $st.EligibleFiles)), 'Green'))
            if ($st.RecentFiles -gt 0) { $out.Add(@(('    {0} {1} recent file(s) ({2}) will be kept' -f ''.PadRight(17), (Format-Count $st.RecentFiles), (Format-Bytes $st.RecentBytes)), 'DarkGray')) }
            if ($st.PendingSkipped -gt 0) { $out.Add(@(('    {0} {1} file(s) queued for the next restart will be kept' -f ''.PadRight(17), (Format-Count $st.PendingSkipped)), 'DarkGray')) }
            if ($st.ReparseSkipped + $st.LinkSkipped -gt 0) { $out.Add(@(('    {0} {1} junction/link item(s) will not be followed' -f ''.PadRight(17), (Format-Count ($st.ReparseSkipped + $st.LinkSkipped))), 'DarkGray')) }
            if ($st.InaccessibleDirs -gt 0) { $out.Add(@(('    {0} {1} folder(s) could not be read; real size may be larger' -f ''.PadRight(17), (Format-Count $st.InaccessibleDirs)), 'DarkGray')) }
        }
        foreach ($n in @($Res.Notes)) { if ($n) { $out.Add(@(('    {0} {1}' -f 'Note'.PadRight(17), $n), 'Yellow')) } }
    }
    return $out
}

function Show-Lines {
    # Prints coloured lines and pauses every screenful.
    param([object[]]$Lines)
    $page = 20
    try { $page = [Math]::Max(10, [Console]::WindowHeight - 4) } catch { }
    $n = 0
    foreach ($l in $Lines) {
        Write-UI ([string]$l[0]) ([ConsoleColor]$l[1])
        $n++
        if ($n -ge $page) {
            $n = 0
            Write-UI '  -- more --  [Space/Enter] next page   [Esc] stop' DarkGray -NoNewline
            $k = Read-Choice -Valid @(' ') -AllowEnter -AllowEscape
            Write-Host ("`r" + (' ' * 60) + "`r") -NoNewline
            if ($k -eq 'ESC') { return }
        }
    }
}

function Write-CategoryTable {
    param([object[]]$Cats, [hashtable]$Results, [hashtable]$Selected, [switch]$WithKeys)
    $nameW = 31; $sizeW = 10; $filesW = 6; $adminW = 5; $riskW = 6
    # Narrow windows: shorter names and no Files column, so rows never wrap.
    $showFiles = $true
    if ($script:UiWidth -lt 90) { $nameW = 27; $showFiles = $false }
    $fixed = 2 + $nameW + 1 + $sizeW + 1 + $adminW + 1 + $riskW + 1
    if ($showFiles) { $fixed += $filesW + 1 }
    if ($WithKeys) { $fixed += 9 }
    $noteW = [Math]::Max(10, $script:UiWidth + 2 - $fixed)
    $head = '  '
    if ($WithKeys) { $head += 'Key  Sel  ' }
    $head += (Format-Cell 'Category' $nameW) + ' ' + (Format-Cell 'Est. size' $sizeW 'Right') + ' '
    if ($showFiles) { $head += (Format-Cell 'Files' $filesW 'Right') + ' ' }
    $head += (Format-Cell 'Admin' $adminW) + ' ' + (Format-Cell 'Risk' $riskW) + ' ' + 'Notes'
    Write-UI $head DarkGray
    Write-Rule
    $letters = $script:RowKeys
    for ($i = 0; $i -lt $Cats.Count; $i++) {
        $c = $Cats[$i]
        $res = $Results[$c.Id]
        $applicable = ($null -ne $res -and $res.Applicable)
        $isSel = ($Selected -and $Selected.ContainsKey($c.Id) -and $Selected[$c.Id])
        $color = [ConsoleColor]::Gray
        if (-not $applicable) { $color = [ConsoleColor]::DarkGray }
        elseif ($isSel) { $color = [ConsoleColor]::White }
        $parts = @(, @('  ', 'Gray'))
        if ($WithKeys) {
            $parts += , @(('[' + $letters[$i] + ']  '), 'Cyan')
            $mark = '[ ]  '
            if ($isSel) { $mark = '[x]  ' }
            if (-not $applicable) { $mark = ' -   ' }
            $mc = 'DarkGray'
            if ($isSel) { $mc = 'Green' }
            $parts += , @($mark, $mc)
        }
        $sizeText = Get-SizeText $res
        $files = '-'
        if ($applicable -and $res.SizeState -ne 'Unknown' -and ($res.Stats.EligibleFiles -gt 0 -or $res.Stats.EligibleBytes -eq 0)) { $files = Format-Count $res.Stats.EligibleFiles }
        $adm = '-'
        if ($c.Admin) { $adm = 'Yes' }
        $riskColor = 'Gray'
        if ($c.Risk -eq 'Medium') { $riskColor = 'Yellow' }
        if ($c.Risk -eq 'High') { $riskColor = 'Red' }
        if (-not $applicable) { $riskColor = 'DarkGray' }
        $note = Get-RowNote $c $res
        $noteColor = 'DarkGray'
        if ($note -match '^OPEN|PERMANENT') { $noteColor = 'Yellow' }
        $parts += , @(((Format-Cell $c.Name $nameW) + ' '), $color)
        $parts += , @(((Format-Cell $sizeText $sizeW 'Right') + ' '), $(if ($applicable) { 'Green' } else { 'DarkGray' }))
        if ($showFiles) { $parts += , @(((Format-Cell $files $filesW 'Right') + ' '), $color) }
        $parts += , @(((Format-Cell $adm $adminW) + ' '), $color)
        $parts += , @(((Format-Cell $c.Risk $riskW) + ' '), $riskColor)
        $parts += , @((Get-Fit $note $noteW), $noteColor)
        Write-Segments $parts
    }
    Write-Rule
}

function Get-SelectionSummary {
    param([object[]]$Cats, [hashtable]$Results, [hashtable]$Selected)
    $s = @{ Count = 0; Bytes = [long]0; Unknown = 0; Admin = @(); Ids = @() }
    foreach ($c in $Cats) {
        if (-not ($Selected.ContainsKey($c.Id) -and $Selected[$c.Id])) { continue }
        $res = $Results[$c.Id]
        if ($null -eq $res -or -not $res.Applicable) { continue }
        $s.Count++
        $s.Ids += $c.Id
        if ($res.SizeState -eq 'Unknown') { $s.Unknown++ } else { $s.Bytes += [long]$res.Stats.EligibleBytes }
        if ($c.Admin) { $s.Admin += $c.Name }
    }
    return $s
}

function Show-SelectionScreen {
    # Lets the user toggle categories. Returns 'CONTINUE' or 'BACK'.
    param([string]$Title, [object[]]$Cats, [hashtable]$Results, [hashtable]$Selected, [string]$Banner = '')
    $AllCats = $Cats
    $letters = $script:RowKeys
    $message = ''
    while ($true) {
        # Only categories that apply to this PC get a row and a key; the rest
        # are listed on one line (full details stay in the Scan report).
        $Cats = @($AllCats | Where-Object { $Results[$_.Id] -and $Results[$_.Id].Applicable })
        $hidden = @($AllCats | Where-Object { -not ($Results[$_.Id] -and $Results[$_.Id].Applicable) } | ForEach-Object { $_.Name })
        Show-Header $Title 'Choose what to clean. Nothing is deleted on this screen.'
        Write-DriveLine
        if ($Banner) { Write-Wrapped $Banner Yellow 2 }
        Write-UI ''
        if ($Cats.Count -eq 0) {
            Write-UI '  None of these categories applies to this PC right now.' White
            if ($hidden.Count -gt 0) { Write-Wrapped ('Not applicable here: ' + ($hidden -join ', ') + '.') DarkGray 2 }
            Wait-AnyKey
            return 'BACK'
        }
        Write-CategoryTable -Cats $Cats -Results $Results -Selected $Selected -WithKeys
        if ($hidden.Count -gt 0) { Write-Wrapped ('Not applicable here: ' + ($hidden -join ', ') + '.') DarkGray 2 }
        $sum = Get-SelectionSummary $Cats $Results $Selected
        $est = Format-Bytes $sum.Bytes
        if ($sum.Unknown -gt 0) { $est += (' + {0} category(ies) of unknown size' -f $sum.Unknown) }
        Write-Segments @(@('  Selected: ', 'DarkGray'), @(('{0} categor{1}' -f $sum.Count, $(if ($sum.Count -eq 1) { 'y' } else { 'ies' })), 'White'), @('   Estimated: ', 'DarkGray'), @($est, 'Green'))
        if ($sum.Admin.Count -gt 0) { Write-Segments @(@('  Administrator prompt: ', 'DarkGray'), @(('yes, for ' + ($sum.Admin -join ', ')), 'Yellow')) }
        Write-UI ''
        $lastKey = $letters[$Cats.Count - 1]
        Write-UI ('  [A-{0}] select/unselect   [?] explain a category   [S] recommended   [X] clear all' -f $lastKey) Cyan
        Write-UI '  [R] measure admin-only items   [Enter] review and confirm   [Esc] back to menu' Cyan
        if ($message) { Write-UI ''; Write-UI ('  ' + $message) Yellow; $message = '' }
        $valid = @('?', 'S', 'X', 'R')
        for ($i = 0; $i -lt $Cats.Count; $i++) { $valid += [string]$letters[$i] }
        $k = Read-Choice -Valid $valid -AllowEnter -AllowEscape
        if ($k -eq 'ESC') { return 'BACK' }
        if ($k -eq 'ENTER') {
            if ($sum.Count -eq 0) { $message = 'Nothing is selected yet.'; continue }
            return 'CONTINUE'
        }
        if ($k -eq 'S') { foreach ($c in $Cats) { $Selected[$c.Id] = ($c.Default -and $Results[$c.Id] -and $Results[$c.Id].Applicable) }; continue }
        if ($k -eq 'X') { foreach ($c in $Cats) { $Selected[$c.Id] = $false }; continue }
        if ($k -eq 'R') {
            $ids = @($Cats | Where-Object { $_.Admin -and $Results[$_.Id] -and $Results[$_.Id].Applicable -and $Results[$_.Id].SizeState -ne 'Known' } | ForEach-Object { $_.Id })
            if ($ids.Count -eq 0) { $message = 'All administrator categories are already measured.'; continue }
            if (Test-IsAdmin) {
                $excl = Get-PendingRenameExclusions
                foreach ($id in $ids) { $Results[$id] = Invoke-CategoryScan (Get-Category $id) $excl }
                continue
            }
            Write-UI ''
            Write-UI '  Windows will ask for administrator permission to MEASURE (read-only) these items.' Yellow
            Write-UI '  A second window opens briefly. Nothing is deleted.' DarkGray
            $h = Invoke-ElevatedHelper 'scan' $ids
            if ($h.Cancelled) { $message = 'Administrator permission was not granted; sizes stay unknown.' }
            elseif ($h.Error) { $message = $h.Error }
            foreach ($r in $h.Results) { if ($r -and $r.Id) { $Results[[string]$r.Id] = $r } }
            continue
        }
        if ($k -eq '?') {
            Write-UI ''
            Write-UI ('  Which category? Press A-{0} (Esc to cancel)' -f $lastKey) Cyan
            $valid2 = @()
            for ($i = 0; $i -lt $Cats.Count; $i++) { $valid2 += [string]$letters[$i] }
            $k2 = Read-Choice -Valid $valid2 -AllowEscape
            if ($k2 -eq 'ESC') { continue }
            $c = $Cats[$letters.IndexOf($k2)]
            Show-Header ('ABOUT: ' + $c.Name) 'Read-only description and scan details'
            Show-Lines (Get-CategoryDetailLines $c $Results[$c.Id])
            Wait-AnyKey 'Press any key to go back...'
            continue
        }
        $idx = $letters.IndexOf($k)
        if ($idx -ge 0 -and $idx -lt $Cats.Count) {
            $c = $Cats[$idx]
            $res = $Results[$c.Id]
            if ($null -eq $res -or -not $res.Applicable) {
                $why = 'not applicable'
                if ($res) { $why = $res.Reason }
                $message = ('{0} cannot be selected: {1}' -f $c.Name, $why)
                continue
            }
            $Selected[$c.Id] = -not ($Selected.ContainsKey($c.Id) -and $Selected[$c.Id])
        }
    }
}

function Show-ConfirmScreen {
    # Final review. Returns the list of category ids to run, or $null.
    param([object[]]$Cats, [hashtable]$Results, [hashtable]$Selected, [string]$Hint = '')
    $chosen = @($Cats | Where-Object { $Selected.ContainsKey($_.Id) -and $Selected[$_.Id] -and $Results[$_.Id] -and $Results[$_.Id].Applicable })
    Show-Header 'CONFIRM CLEANUP' 'Last check before anything is deleted.'
    Write-DriveLine
    Write-UI ''
    Write-UI '  Deleted files do NOT go to the Recycle Bin. Only the items below are touched.' White
    Write-UI ''
    $nameW = 32
    Write-UI ('  ' + (Format-Cell 'Category' $nameW) + ' ' + (Format-Cell 'Estimated' 11 'Right') + '   ' + (Format-Cell 'Admin' 6) + 'What happens') DarkGray
    Write-Rule
    $total = [long]0
    $unknown = 0
    foreach ($c in $chosen) {
        $res = $Results[$c.Id]
        if ($res.SizeState -eq 'Unknown') { $unknown++ } else { $total += [long]$res.Stats.EligibleBytes }
        $what = 'old files deleted; recent/in-use kept'
        switch ($c.Handler) {
            'DeliveryOpt' { $what = 'Windows deletes its own DO cache' }
            'RecycleBin'  { $what = 'PERMANENTLY empties the Recycle Bin' }
            'Browser'     { $what = 'caches only; skipped if browser open' }
            'Thumbnails'  { $what = 'skipped whole if Explorer uses it' }
        }
        $adm = '-'
        if ($c.Admin) { $adm = 'Yes' }
        $col = 'White'
        if ($c.Risk -eq 'Medium') { $col = 'Yellow' }
        if ($c.Risk -eq 'High') { $col = 'Red' }
        Write-Segments @(@(('  ' + (Format-Cell $c.Name $nameW) + ' '), $col), @(((Format-Cell (Get-SizeText $res) 11 'Right') + '   '), 'Green'), @((Format-Cell $adm 6), 'Gray'), @((Get-Fit $what ($script:UiWidth - $nameW - 21)), 'Gray'))
    }
    Write-Rule
    $est = Format-Bytes $total
    if ($unknown -gt 0) { $est += (' + {0} of unknown size' -f $unknown) }
    Write-KeyValue 'Estimated total' $est Green
    $admins = @($chosen | Where-Object { $_.Admin })
    if ($admins.Count -gt 0) {
        Write-KeyValue 'Administrator' ('Windows will ask (UAC) for: ' + (($admins | ForEach-Object { $_.Name }) -join ', ')) Yellow
        Write-KeyValue '' 'A second window shows that part of the work and closes itself.' DarkGray
    }

    # Warnings that apply right now
    $warn = @()
    foreach ($c in $chosen) {
        $res = $Results[$c.Id]
        if ($res.Extra.ContainsKey('Running') -and $res.Extra.Running) { $warn += ($c.Name + ': the browser is open and will be skipped. Close it first if you want it cleaned.') }
        if ($c.Risk -eq 'Medium') { $warn += ($c.Name + ': ' + $c.Side) }
    }
    $games = @()
    if (@($chosen | Where-Object { $_.Id -like 'Shader*' }).Count -gt 0) { $games = @(Get-RunningGames) }
    if ($games.Count -gt 0) { $warn += ('Running game detected (' + ($games -join ', ') + '): shader caches will be skipped.') }
    if (@($chosen | Where-Object { $_.Id -eq 'UserTemp' -or $_.Id -eq 'WinTemp' }).Count -gt 0) {
        $act = Get-InstallActivity
        if ($act) { $warn += ('Temporary-file cleanup will be skipped: ' + $act) }
    }
    if ($warn.Count -gt 0) {
        Write-Section 'Please read'
        foreach ($w in $warn) { foreach ($line in (Get-WrappedLines $w ($script:UiWidth - 4))) { Write-UI ('   ' + $line) Yellow } }
    }

    $final = @($chosen | ForEach-Object { $_.Id })
    $rb = @($chosen | Where-Object { $_.Handler -eq 'RecycleBin' })
    if ($rb.Count -gt 0) {
        $res = $Results['RecycleBin']
        Write-Section 'Irreversible action'
        Write-UI ('   The Recycle Bin holds {0} in {1} item(s). Emptying it is PERMANENT.' -f (Get-SizeText $res), (Format-Count $res.Stats.EligibleFiles)) Red
        $typed = Read-LineSafe 'Type EMPTY to include it, or just press Enter to leave the Recycle Bin alone: '
        if ($typed -cne 'EMPTY') {
            $final = @($final | Where-Object { $_ -ne 'RecycleBin' })
            Write-UI '   Recycle Bin will NOT be emptied.' Green
            if ($final.Count -eq 0) { Write-UI ''; Write-UI '  Nothing left to do. No files were changed.' White; Wait-AnyKey; return $null }
        }
    }
    Write-UI ''
    if ($Hint) { Write-Wrapped $Hint DarkGray 2 }
    if (-not (Read-YesNo 'Start the cleanup now?' 'N')) {
        Write-UI '  Cancelled. No files were changed.' Green
        Start-Sleep -Milliseconds 900
        return $null
    }
    return $final
}

# -----------------------------------------------------------------------------
# 6d. Running the cleanup and the before/after report
# -----------------------------------------------------------------------------
function Write-LogEnvironment {
    $os = Get-OsInfo
    Write-RunLog ('Program      : {0} {1} ({2})' -f $script:AppName, $script:AppVersion, $script:AppDate)
    Write-RunLog ('Windows      : {0}, {1}' -f $os.Text, $(if ($os.Is64) { '64-bit' } else { '32-bit' }))
    Write-RunLog ('PowerShell   : {0} ({1})' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
    Write-RunLog ('Elevated     : {0}' -f $(if (Test-IsAdmin) { 'Yes' } else { 'No' }))
    Write-RunLog ('System drive : {0}' -f (Get-SystemDriveRoot))
    Write-RunLog ('Restart state: {0}' -f (Get-PendingRebootInfo).Text)
    $an = Get-Anchors
    foreach ($k in @('LocalAppData', 'Temp', 'Windows', 'ProgramData')) {
        if (-not $an[$k].Ok) { Write-RunLog ('Anchor check : {0} refused - {1}' -f $k, $an[$k].Reason) }
    }
}

function Write-LogResult {
    param([hashtable]$Res, [hashtable]$Estimate)
    $st = $Res.Stats
    Write-RunLog ('[{0}] {1}' -f $Res.Status, $Res.Name)
    if ($Res.Detail) { Write-RunLog ('    Detail   : ' + $Res.Detail) }
    if ($Estimate) { Write-RunLog ('    Estimate : {0} bytes in {1} files ({2})' -f $Estimate.Stats.EligibleBytes, $Estimate.Stats.EligibleFiles, $Estimate.SizeState) }
    Write-RunLog ('    Deleted  : {0} files, {1} bytes; eligible at clean time {2} files, {3} bytes' -f $st.Deleted, $st.DeletedBytes, $st.EligibleFiles, $st.EligibleBytes)
    Write-RunLog ('    Kept     : recent {0}, in use {1}, queued-for-restart {2}, links {3}' -f $st.RecentFiles, $st.InUse, $st.PendingSkipped, ([long]$st.ReparseSkipped + [long]$st.LinkSkipped))
    Write-RunLog ('    Problems : access denied {0}, other {1}, refused-outside {2}, unreadable folders {3}' -f $st.Denied, $st.Other, $st.Outside, $st.InaccessibleDirs)
    foreach ($t in @($Res.Targets)) { Write-RunLog ('    Location : {0} [{1}]' -f (Format-PathForLog ([string]$t.Path)), $t.State) }
    if ($st.Samples) {
        foreach ($k in @($st.Samples.Keys)) { foreach ($s in @($st.Samples[$k])) { Write-RunLog ('    Example  : {0}: {1}' -f $k, $s) } }
    }
    foreach ($n in @($Res.Notes)) { if ($n) { Write-RunLog ('    Note     : ' + $n) } }
}

function Write-ResultLine {
    param([int]$Index, [int]$Count, [hashtable]$Res)
    Write-Segments @(@(('  [{0}/{1}] ' -f $Index, $Count), 'DarkGray'), @((Format-Cell $Res.Name 34), 'White'), @(' ', 'Gray'), @($Res.Status, (Write-StatusTag $Res.Status)))
    if ($Res.Detail) { foreach ($l in (Get-WrappedLines $Res.Detail ($script:UiWidth - 8))) { Write-UI ('        ' + $l) DarkGray } }
}

function Invoke-CleanupRun {
    param([string[]]$Ids, [hashtable]$ScanResults)
    $cats = @($Ids | ForEach-Object { Get-Category $_ })
    Show-Header 'CLEANUP IN PROGRESS' 'Press Esc or Ctrl+C to stop safely after the current file.'

    $logOk = Start-RunLog 'cleanup'
    if (-not $logOk) {
        Write-UI ('  The log file could not be created: ' + $script:Log.LastError) Yellow
        if (-not (Read-YesNo 'Continue without a log file?' 'N')) { Write-UI '  Cancelled. No files were changed.' Green; Wait-AnyKey; return }
    } else { [void](Invoke-LogRetention) }
    Write-LogEnvironment
    Write-LogSection 'Selection and estimates (from the scan)'
    foreach ($c in $cats) {
        $e = $ScanResults[$c.Id]
        Write-RunLog ('{0,-36} estimate {1} ({2} files, {3})' -f $c.Name, (Format-Bytes $e.Stats.EligibleBytes), $e.Stats.EligibleFiles, $e.SizeState)
    }

    $roots = Get-TargetDriveRoots $cats
    $before = Get-DriveSnapshot $roots
    $pendingBefore = Get-PendingRebootInfo
    $excl = Get-PendingRenameExclusions
    $mode = Set-DeleteMode
    Write-RunLog ('Delete mode  : ' + $mode.Mode)
    Write-LogSection 'Free space before'
    foreach ($k in @($before.Keys)) { Write-RunLog ('{0} free {1} bytes ({2}) of {3} bytes' -f $k, $before[$k].Free, (Format-Bytes $before[$k].Free), $before[$k].Total) }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $script:CancelRequested = $false
    $results = New-Object 'System.Collections.Generic.List[hashtable]'
    $admin = @($cats | Where-Object { $_.Admin })
    $user = @($cats | Where-Object { -not $_.Admin })
    $n = $cats.Count
    $idx = 0
    Write-UI ''

    if ($admin.Count -gt 0) {
        if (Test-IsAdmin) {
            foreach ($c in $admin) {
                $idx++
                if ($script:CancelRequested) { $r = New-CategoryResult $c; $r.Status = 'Cancelled'; $r.Detail = 'Not started (stopped by you).' }
                elseif (-not $mode.Ok) { $r = New-CategoryResult $c; $r.Status = 'Failed'; $r.Detail = $mode.Reason }
                else { Write-ProgressLine ('Cleaning {0}...' -f $c.Name) -Force; $r = Invoke-CategoryClean $c $excl }
                $results.Add($r); Write-ResultLine $idx $n $r
            }
        } else {
            Write-UI ('  Administrator permission is needed for: ' + (($admin | ForEach-Object { $_.Name }) -join ', ')) Yellow
            Write-UI '  Windows will show a UAC prompt now. A second window shows the progress and closes itself.' DarkGray
            $h = Invoke-ElevatedHelper 'clean' @($admin | ForEach-Object { $_.Id })
            $byId = @{}
            foreach ($r in $h.Results) { if ($r -and $r.Id) { $byId[[string]$r.Id] = $r } }
            if ($h.Error) { Write-RunLog ('Elevated helper: ' + $h.Error) }
            foreach ($c in $admin) {
                $idx++
                if ($byId.ContainsKey($c.Id)) { $r = $byId[$c.Id] }
                else {
                    $r = New-CategoryResult $c
                    if ($h.Cancelled) { $r.Status = 'Cancelled'; $r.Detail = 'Administrator permission was not granted, so this was not run.' }
                    else { $r.Status = 'Failed'; $r.Detail = $h.Error; if (-not $r.Detail) { $r.Detail = 'No result was returned by the administrator window.' } }
                }
                $results.Add($r); Write-ResultLine $idx $n $r
            }
        }
    }
    foreach ($c in $user) {
        $idx++
        if ($script:CancelRequested) { $r = New-CategoryResult $c; $r.Status = 'Cancelled'; $r.Detail = 'Not started (stopped by you).' }
        else { Write-ProgressLine ('Cleaning {0}...' -f $c.Name) -Force; $r = Invoke-CategoryClean $c $excl }
        $results.Add($r); Write-ResultLine $idx $n $r
    }
    Clear-ProgressLine
    $sw.Stop()
    $after = Get-DriveSnapshot $roots

    Write-LogSection 'Results per category'
    foreach ($r in $results) { Write-LogResult $r $ScanResults[$r.Id] }
    Show-CleanupReport -Results $results -Before $before -After $after -Elapsed $sw.Elapsed -ScanResults $ScanResults -PendingBefore $pendingBefore
}

function Get-RestartAdvice {
    param([object[]]$Results, [hashtable]$PendingBefore)
    $inUse = [long]0
    foreach ($r in $Results) { $inUse += [long]$r.Stats.InUse }
    $lines = @()
    if ($PendingBefore.Any) { $lines += ('Recommended, but not because of this cleanup: ' + $PendingBefore.Text + ' already existed before it started.') }
    else { $lines += 'Not required. None of these cleanup categories needs a restart.' }
    if ($inUse -gt 0) { $lines += ('{0} file(s) were in use and were left alone; they may become removable once the programs using them close.' -f (Format-Count $inUse)) }
    return $lines
}

function Show-CleanupReport {
    param([object[]]$Results, [System.Collections.IDictionary]$Before, [System.Collections.IDictionary]$After, [TimeSpan]$Elapsed, [hashtable]$ScanResults, [hashtable]$PendingBefore)
    $tot = New-WalkStats
    $estimate = [long]0
    $estUnknown = 0
    foreach ($r in $Results) {
        Merge-WalkStats $tot $r.Stats
        $e = $ScanResults[$r.Id]
        if ($e) { if ($e.SizeState -eq 'Unknown') { $estUnknown++ } else { $estimate += [long]$e.Stats.EligibleBytes } }
    }
    $deltas = @(Get-DriveDeltas $Before $After)
    $statusCounts = @{}
    foreach ($r in $Results) { $statusCounts[$r.Status] = 1 + [int]$statusCounts[$r.Status] }

    Write-UI ''
    Write-UI ('  ' + ('=' * $script:UiWidth)) DarkCyan
    Write-UI '   CLEANUP REPORT' Cyan
    Write-UI ('  ' + ('=' * $script:UiWidth)) DarkCyan
    Write-Section 'Measured free space (from Windows, before and after)'
    foreach ($d in $deltas) {
        $col = 'Green'
        if ($d.Delta -lt 0) { $col = 'Yellow' }
        Write-Segments @(@((('  Drive {0}' -f $d.Root.TrimEnd('\')).PadRight(12) + ' '), 'White'), @(('before {0}' -f (Format-Bytes $d.Before)).PadRight(20), 'Gray'), @(('after {0}' -f (Format-Bytes $d.After)).PadRight(20), 'Gray'), @('change ', 'DarkGray'), @((Format-Bytes $d.Delta -Signed), $col))
    }
    if ($deltas.Count -eq 0) { Write-UI '  Free space could not be measured.' Yellow }
    Write-Section 'What the cleanup did'
    $estText = Format-Bytes $estimate
    if ($estUnknown -gt 0) { $estText += (' (+ {0} category(ies) not measurable before cleaning)' -f $estUnknown) }
    Write-KeyValue 'Estimated (scan)' $estText Gray 24
    Write-KeyValue 'Deleted file size' ((Format-Bytes $tot.DeletedBytes) + '  (sum of the sizes of files actually deleted)') Green 24
    Write-KeyValue 'Files deleted' (Format-Count $tot.Deleted) White 24
    $kept = '{0} recent, {1} in use, {2} queued for restart, {3} links' -f (Format-Count $tot.RecentFiles), (Format-Count $tot.InUse), (Format-Count $tot.PendingSkipped), (Format-Count ([long]$tot.ReparseSkipped + [long]$tot.LinkSkipped))
    Write-KeyValue 'Files kept on purpose' $kept Gray 24
    $prob = [long]$tot.Denied + [long]$tot.Other + [long]$tot.Outside
    $pc = 'Green'
    if ($prob -gt 0) { $pc = 'Yellow' }
    Write-KeyValue 'Files that failed' ('{0} (access denied {1}, other {2}, refused {3})' -f (Format-Count $prob), (Format-Count $tot.Denied), (Format-Count $tot.Other), (Format-Count $tot.Outside)) $pc 24
    Write-KeyValue 'Time taken' (Format-Duration $Elapsed) Gray 24
    $adv = @(Get-RestartAdvice $Results $PendingBefore)
    Write-KeyValue 'Restart' $adv[0] White 24
    for ($i = 1; $i -lt $adv.Count; $i++) { Write-KeyValue '' $adv[$i] DarkGray 24 }
    $logText = 'not written'
    if ($script:Log.Enabled -and $script:Log.Path) { $logText = $script:Log.Path }
    elseif ($script:Log.LastError) { $logText = 'not written: ' + $script:Log.LastError }
    Write-KeyValue 'Log file' $logText Cyan 24

    Write-Section 'Per category'
    $nameW = 32; $statW = 28
    Write-UI ('  ' + (Format-Cell 'Category' $nameW) + ' ' + (Format-Cell 'Status' $statW) + ' ' + (Format-Cell 'Estimated' 10 'Right') + ' ' + (Format-Cell 'Deleted' 10 'Right') + ' ' + (Format-Cell 'Files' 8 'Right')) DarkGray
    foreach ($r in $Results) {
        $e = $ScanResults[$r.Id]
        Write-Segments @(@(('  ' + (Format-Cell $r.Name $nameW) + ' '), 'White'), @(((Format-Cell $r.Status $statW) + ' '), (Write-StatusTag $r.Status)), @(((Format-Cell (Get-SizeText $e) 10 'Right') + ' '), 'Gray'), @(((Format-Cell (Format-Bytes $r.Stats.DeletedBytes) 10 'Right') + ' '), 'Green'), @((Format-Cell (Format-Count $r.Stats.Deleted) 8 'Right'), 'Gray'))
    }

    # Explanations only where they apply
    $notes = @()
    $sumDelta = [long]0
    foreach ($d in $deltas) { $sumDelta += $d.Delta }
    if ($deltas.Count -gt 0) {
        if ($sumDelta -lt 0) {
            $notes += ('Free space went DOWN by {0} while the cleanup ran, although {1} of files were deleted. Other programs (for example Windows Update, a launcher or a browser) wrote data at the same time. This is the real measurement; nothing was hidden.' -f (Format-Bytes (-1 * $sumDelta)), (Format-Bytes $tot.DeletedBytes))
        } elseif ([Math]::Abs($sumDelta - [long]$tot.DeletedBytes) -gt [Math]::Max([long]50MB, [long]($tot.DeletedBytes * 0.1))) {
            $notes += 'The measured change differs from the deleted file size. That is normal: deleted sizes are file lengths, while Windows measures disk clusters; compressed or hard-linked files, the Delivery Optimization/Recycle Bin handlers and other programs writing at the same time all move the numbers.'
        }
    }
    if ([long]$tot.DeletedBytes -lt $estimate) { $notes += 'Less was deleted than estimated because files were in use, became recent, were removed by their own program, or could not be accessed. Those files were left alone.' }
    foreach ($r in $Results) {
        if ($r.Status -match '^Failed|^Partially') { $notes += ($r.Name + ': ' + $r.Detail) }
        if ([long]$r.Stats.Outside -gt 0) { $notes += ($r.Name + ': some items resolved to a location outside the approved folder (for example through a junction) and were NOT deleted.') }
    }
    if ($notes.Count -gt 0) {
        Write-Section 'Notes'
        foreach ($nt in $notes) {
            $w = @(Get-WrappedLines $nt ($script:UiWidth - 4))
            for ($i = 0; $i -lt $w.Count; $i++) { $p = '   '; if ($i -eq 0) { $p = ' - ' }; Write-UI ('  ' + $p + $w[$i]) Gray }
        }
    }
    if (-not $script:Log.Enabled -and $script:Log.Path) { Write-UI ''; Write-UI ('  Warning: writing to the log stopped part-way: ' + $script:Log.LastError) Yellow }

    Write-LogSection 'Summary'
    foreach ($d in $deltas) { Write-RunLog ('{0} free before {1} after {2} measured change {3} bytes ({4})' -f $d.Root, $d.Before, $d.After, $d.Delta, (Format-Bytes $d.Delta -Signed)) }
    Write-RunLog ('Estimated (scan)  : {0} bytes (+{1} unmeasured categories)' -f $estimate, $estUnknown)
    Write-RunLog ('Deleted file size : {0} bytes in {1} files' -f $tot.DeletedBytes, $tot.Deleted)
    Write-RunLog ('Kept              : ' + $kept)
    Write-RunLog ('Failed            : {0}' -f $prob)
    Write-RunLog ('Elapsed           : ' + (Format-Duration $Elapsed))
    foreach ($a in $adv) { Write-RunLog ('Restart           : ' + $a) }
    foreach ($nt in $notes) { Write-RunLog ('Note              : ' + $nt) }
    $overall = 'Completed'
    foreach ($r in $Results) { if ($r.Status -match '^Failed|^Partially|^Cancelled') { $overall = 'Completed with problems or cancellations' } }
    Write-RunLog ('Overall status    : ' + $overall)
    Write-RunLog ('Finished          : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
    Wait-AnyKey
}

# -----------------------------------------------------------------------------
# 6e. Menu-level cleanup flows
# -----------------------------------------------------------------------------
function Start-CleanupFlow {
    param([string]$Title, [string[]]$Groups, [switch]$Quick, [string]$Banner = '', [switch]$BrowserMode)
    $cats = @(Get-Categories | Where-Object { $Groups -contains $_.Group })
    Show-Header $Title 'Scanning the selected categories. Nothing is deleted. (Esc to stop)'
    Write-UI ''
    $results = Invoke-ScanCategories $cats
    if ($script:CancelRequested) {
        $script:CancelRequested = $false
        Write-UI '  Scan stopped. No files were changed.' Yellow
        Wait-AnyKey
        return
    }
    $selected = @{}
    foreach ($c in $cats) {
        $res = $results[$c.Id]
        $on = ($c.Default -and $res.Applicable)
        if ($BrowserMode) { $on = ($res.Applicable -and -not ($res.Extra.ContainsKey('Running') -and $res.Extra.Running)) }
        $selected[$c.Id] = [bool]$on
    }
    $skipSelection = [bool]$Quick
    while ($true) {
        if (-not $skipSelection) {
            $choice = Show-SelectionScreen -Title $Title -Cats $cats -Results $results -Selected $selected -Banner $Banner
            if ($choice -eq 'BACK') { return }
        }
        $skipSelection = $false
        $sum = Get-SelectionSummary $cats $results $selected
        if ($sum.Count -eq 0) {
            Show-Header $Title ''
            Write-UI '  Nothing to clean: none of these categories is present or selected.' White
            Wait-AnyKey
            return
        }
        $hint = ''
        if ($Quick) { $hint = 'Want to include or leave out something? Answer N and use [3] Preview and select cleanup.' }
        $ids = Show-ConfirmScreen $cats $results $selected $hint
        if ($null -eq $ids) {
            if ($Quick) { return }
            continue
        }
        Invoke-CleanupRun -Ids $ids -ScanResults $results
        return
    }
}

function Show-ScanReport {
    $cats = @(Get-Categories)
    Show-Header 'SCAN FOR CLEANUP CANDIDATES' 'Read-only analysis of every category. Nothing is deleted. (Esc to stop)'
    Write-UI ''
    $results = Invoke-ScanCategories $cats
    $logOk = Start-RunLog 'scan'
    if ($logOk) { [void](Invoke-LogRetention) }
    Write-LogEnvironment
    while ($true) {
        Show-Header 'SCAN RESULTS' 'Read-only. Estimates show what is eligible right now under the safety rules.'
        Write-DriveLine
        Write-UI ''
        Write-CategoryTable -Cats $cats -Results $results -Selected @{}
        $def = [long]0; $all = [long]0; $unk = 0
        foreach ($c in $cats) {
            $r = $results[$c.Id]
            if ($null -eq $r -or -not $r.Applicable) { continue }
            if ($r.SizeState -eq 'Unknown') { $unk++; continue }
            $all += [long]$r.Stats.EligibleBytes
            if ($c.Default) { $def += [long]$r.Stats.EligibleBytes }
        }
        Write-KeyValue 'Preselected (low risk)' (Format-Bytes $def) Green 26
        $allText = Format-Bytes $all
        if ($unk -gt 0) { $allText += (' + {0} unknown (press R to measure)' -f $unk) }
        Write-KeyValue 'All categories' $allText Gray 26
        Write-KeyValue 'Handled by Windows tools' 'Windows Update Cleanup, old Windows installs, upgrade logs: menu [7]' DarkGray 26
        if ($script:CancelRequested) { Write-UI '  Scan was stopped early; some categories were not measured.' Yellow }
        if ($logOk) { Write-KeyValue 'Scan report' $script:Log.Path Cyan 26 }
        Write-UI ''
        Write-UI '  [V] view full details of every category   [R] measure admin-only items   [3] continue to Preview & Select' Cyan
        Write-UI '  [Esc] back to menu' Cyan
        $k = Read-Choice -Valid @('V', 'R', '3') -AllowEscape
        if ($k -eq 'ESC') { break }
        if ($k -eq 'V') {
            Show-Header 'SCAN DETAILS' 'Every category: what, why, side effects, locations and numbers'
            $lines = New-Object 'System.Collections.Generic.List[object]'
            foreach ($c in $cats) { foreach ($l in (Get-CategoryDetailLines $c $results[$c.Id])) { $lines.Add($l) }; $lines.Add(@('', 'Gray')) }
            Show-Lines $lines
            Wait-AnyKey 'Press any key to go back...'
        }
        if ($k -eq 'R') {
            $ids = @($cats | Where-Object { $_.Admin -and $results[$_.Id] -and $results[$_.Id].Applicable -and $results[$_.Id].SizeState -ne 'Known' } | ForEach-Object { $_.Id })
            if ($ids.Count -gt 0) {
                if (Test-IsAdmin) { $excl = Get-PendingRenameExclusions; foreach ($id in $ids) { $results[$id] = Invoke-CategoryScan (Get-Category $id) $excl } }
                else {
                    $h = Invoke-ElevatedHelper 'scan' $ids
                    foreach ($r in $h.Results) { if ($r -and $r.Id) { $results[[string]$r.Id] = $r } }
                    if ($h.Error) { Write-UI ('  ' + $h.Error) Yellow; Start-Sleep -Seconds 2 }
                }
            }
        }
        if ($k -eq '3') {
            Write-LogSection 'Scan results'
            foreach ($c in $cats) { foreach ($l in (Get-CategoryDetailLines $c $results[$c.Id])) { Write-RunLog ([string]$l[0]) } }
            $selected = @{}
            foreach ($c in $cats) { $selected[$c.Id] = [bool]($c.Default -and $results[$c.Id] -and $results[$c.Id].Applicable) }
            $choice = Show-SelectionScreen -Title 'PREVIEW AND SELECT CLEANUP' -Cats $cats -Results $results -Selected $selected
            if ($choice -eq 'CONTINUE') {
                $ids = Show-ConfirmScreen $cats $results $selected
                if ($null -ne $ids) { Invoke-CleanupRun -Ids $ids -ScanResults $results }
            }
            return
        }
    }
    Write-LogSection 'Scan results'
    foreach ($c in $cats) { foreach ($l in (Get-CategoryDetailLines $c $results[$c.Id])) { Write-RunLog ([string]$l[0]) } }
}
