<#
.SYNOPSIS
    Non-destructive test suite for aiznm_CLEANER.bat.

.DESCRIPTION
    Loads the PowerShell section of aiznm_CLEANER.bat in "library" mode (no
    menu, nothing runs by itself) and tests it against a brand-new sandbox
    folder created under your temporary folder. The real cleanup locations
    are never used: the program's trusted folder anchors are replaced with
    sandbox folders before any category code runs, and every target is
    checked to be inside the sandbox before a test is allowed to delete.

    Categories that act on system-wide state through Windows itself
    (Delivery Optimization, Recycle Bin) are never cleaned by this suite.

    Works on Windows PowerShell 5.1 (Windows 10) and PowerShell 7.
    On Windows it additionally tests the native verified-delete helper,
    real file locks, junctions and hard links inside the sandbox.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-AiznmCleaner.ps1
#>
param(
    [string]$BatPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'aiznm_CLEANER.bat'),
    [switch]$KeepSandbox
)

$ErrorActionPreference = 'Stop'
$BatPath = (Resolve-Path -LiteralPath $BatPath).Path
$env:AIZNM_MODE = 'library'
$env:AIZNM_STRICT = 'latest'
$batText = [IO.File]::ReadAllText($BatPath)
$markerText = '#' + '#AIZNM_PS_BEGIN##'
$payloadIndex = $batText.IndexOf($markerText)
if ($payloadIndex -lt 0) { throw 'Marker not found in BAT file.' }
. ([ScriptBlock]::Create($batText.Substring($payloadIndex)))
$ErrorActionPreference = 'Stop'
$script:QuietUi = $true
$onWin = $script:OnWindows

# ---------------------------------------------------------------- framework
$script:TestResults = New-Object 'System.Collections.Generic.List[object]'
function Invoke-TestCase {
    param([string]$Id, [string]$Name, [scriptblock]$Body)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = & $Body
        $status = 'PASS'; $detail = ''
        if ($r -is [string] -and $r -like 'SKIP:*') { $status = 'SKIP'; $detail = $r.Substring(5).Trim() }
        $script:TestResults.Add([pscustomobject]@{ Id = $Id; Name = $Name; Result = $status; Detail = $detail; Ms = $sw.ElapsedMilliseconds })
    } catch {
        $script:TestResults.Add([pscustomobject]@{ Id = $Id; Name = $Name; Result = 'FAIL'; Detail = ($_.Exception.Message + ' | ' + ((@($_.ScriptStackTrace -split "`r?`n") | Select-Object -First 3) -join ' <- ')); Ms = $sw.ElapsedMilliseconds })
    }
}
function Assert-That { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw ('Assertion failed: ' + $Message) } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ($Expected -ne $Actual) { throw ("Assertion failed: {0} (expected '{1}', got '{2}')" -f $Message, $Expected, $Actual) } }

# ---------------------------------------------------------------- sandbox
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('aiznm-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($sandbox)
$sandbox = (Resolve-Path -LiteralPath $sandbox).Path
$weird = 'odd name & co (x) ''q'' %PATH% !bang! ^caret ' + [char]0x00E9
$SB = @{}
foreach ($n in @('Profile', 'Windows', 'ProgramData', 'Outside')) { $SB[$n] = Join-Path $sandbox $n }
$SB.Profile = Join-Path $sandbox ('Users\' + $weird)
$SB.LocalAppData = Join-Path $SB.Profile 'AppData\Local'
$SB.Temp = Join-Path $SB.LocalAppData 'Temp'
foreach ($d in $SB.Values) { [void][IO.Directory]::CreateDirectory($d) }

function New-Anchor2 { param($Name, $Path) return @{ Name = $Name; Path = (Get-NormalizedPath $Path); Ok = $true; Reason = '' } }
$fakeAnchors = @{
    LocalAppData = New-Anchor2 'LocalAppData' $SB.LocalAppData
    UserProfile  = New-Anchor2 'UserProfile' $SB.Profile
    LocalLow     = New-Anchor2 'LocalLow' (Join-Path $SB.Profile 'AppData\LocalLow')
    Windows      = New-Anchor2 'Windows' $SB.Windows
    ProgramData  = New-Anchor2 'ProgramData' $SB.ProgramData
    Temp         = New-Anchor2 'Temp' $SB.Temp
}
$fakeAnchors.Temp.Parent = 'LocalAppData'
$script:Anchors = $fakeAnchors
$script:GpuCache = @(@{ Name = 'NVIDIA GeForce RTX 4060'; Vendor = 'NVIDIA'; DriverVersion = '32.0.15.6094'; NvidiaVersion = '560.94'; VramBytes = 8GB; DriverDate = $null; RefreshHz = 360; Pnp = 'PCI\VEN_10DE&DEV_2882' })

function New-TestFile {
    param([string]$Path, [int]$Bytes = 100, [double]$AgeHours = 48)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
    $t = [DateTime]::UtcNow.AddHours(-1 * $AgeHours)
    [IO.File]::SetLastWriteTimeUtc($Path, $t)
    [IO.File]::SetCreationTimeUtc($Path, $t)
}
function Set-DirAge { param([string]$Path, [double]$AgeHours) $t = [DateTime]::UtcNow.AddHours(-1 * $AgeHours); [IO.Directory]::SetCreationTimeUtc($Path, $t); [IO.Directory]::SetLastWriteTimeUtc($Path, $t) }
function Get-TreeSnapshot {
    param([string]$Root)
    $h = @{}
    if (-not [IO.Directory]::Exists($Root)) { return $h }
    foreach ($f in [IO.Directory]::GetFiles($Root, '*', [IO.SearchOption]::AllDirectories)) { $h[$f] = (New-Object IO.FileInfo($f)).Length }
    return $h
}
function New-DirLink {
    # Junction on Windows (no admin needed), symbolic link elsewhere.
    param([string]$Link, [string]$Target)
    if ($onWin) { New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null }
    else { New-Item -ItemType SymbolicLink -Path $Link -Target $Target | Out-Null }
}
function New-Spec {
    param([string]$Rel, [string]$Kind = 'Tree', [bool]$Recurse = $true, [string]$Pattern = $null, [double]$Age = 24, [bool]$RemoveEmpty = $true, [string[]]$Keep = @('Low'))
    $segs = @($Rel.Split([char[]]@('\', '/')) | Where-Object { $_ })
    $spec = New-TargetSpec -AnchorName 'LocalAppData' -Segments $segs -Label $Rel -Kind $Kind -Recurse $Recurse -NamePattern $Pattern -MinAgeHours $Age -RemoveEmptyDirs $RemoveEmpty -KeepDirNames $Keep -AnchorsOverride $fakeAnchors
    return (Test-TargetSpec $spec)
}
function Assert-InSandbox { param([string]$Path) if (-not (Test-PathUnder $Path $sandbox)) { throw "SAFETY STOP: $Path is outside the sandbox" } }

# Neutral environment facts so results do not depend on this PC's live state
# (a pending Windows Update restart, a running installer or game). Tests that
# need a specific state override these themselves.
${function:Get-InstallActivity} = { $null }
${function:Get-PendingRebootInfo} = { @{ Servicing = $false; WindowsUpdate = $false; FileRenames = 0; Any = $false; Text = 'No restart pending' } }
${function:Get-RunningGames} = { @() }
${function:Get-PendingRenameExclusions} = { @{ Set = (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)); List = (New-Object 'System.Collections.Generic.List[string]') } }

$origInvokeFileDelete = ${function:Invoke-FileDelete}
$origTestIsAdmin = ${function:Test-IsAdmin}
function Restore-Overrides { ${function:Invoke-FileDelete} = $origInvokeFileDelete; ${function:Test-IsAdmin} = $origTestIsAdmin }

# ================================================================ TESTS

Invoke-TestCase 'T01' 'BAT structure: ASCII, CRLF, single marker, CMD exits before payload, payload parses' {
    $bytes = [IO.File]::ReadAllBytes($BatPath)
    foreach ($b in $bytes) { if ($b -gt 126 -or ($b -lt 32 -and $b -ne 9 -and $b -ne 10 -and $b -ne 13)) { throw "non-ASCII byte $b" } }
    Assert-That ($bytes[0] -ne 0xEF) 'no UTF-8 BOM'
    for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -eq 10 -and ($i -eq 0 -or $bytes[$i - 1] -ne 13)) { throw "LF without CR at byte $i" } }
    Assert-Equal 1 ([regex]::Matches($batText, [regex]::Escape($markerText))).Count 'marker occurrences'
    $cmd = $batText.Substring(0, $payloadIndex)
    $cmdLines = $cmd -split "`r`n"
    $lastCode = @($cmdLines | Where-Object { $_.Trim() -and $_ -notmatch '^\s*rem\b' -and $_ -notmatch '^\s*::' }) | Select-Object -Last 1
    Assert-That ($lastCode -match '^\s*endlocal & exit /b') "CMD section must end with exit /b (got '$lastCode')"
    foreach ($l in $cmdLines) { if ($l -match '^\s*rem\b') { Assert-That ($l -notmatch '[%|<>]' -and $l -notmatch '\^\s*$') "rem line must not contain % | < > or a trailing caret: $l" } }
    foreach ($label in @(':aiznm_run', ':aiznm_start')) { Assert-That ($cmd -match ('(?m)^' + [regex]::Escape($label) + '\r?$')) "label $label" }
    $psLines = $batText.Substring($payloadIndex) -split "`r`n"
    $colon = @($psLines | Where-Object { $_ -match '^\s*:' })
    Assert-Equal 0 $colon.Count 'no payload line may start with ":" (CMD label confusion)'
    $tok = $null; $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($batText.Substring($payloadIndex), [ref]$tok, [ref]$err)
    Assert-Equal 0 $err.Count 'payload parse errors'
    Assert-That ($cmd -notmatch '(?i)taskkill|net stop|net start|del /|rd /s|Clear-RecycleBin|cleanmgr') 'CMD section contains no destructive commands'
}

Invoke-TestCase 'T02' 'Size and count formatting (64-bit, signed, unknown)' {
    Assert-Equal '0 B' (Format-Bytes 0) 'zero'
    Assert-Equal 'unknown' (Format-Bytes $null) 'null'
    Assert-Equal '1.00 KB' (Format-Bytes 1024) '1 KB'
    Assert-Equal '5.00 GB' (Format-Bytes ([long]5GB)) '5 GB (int64)'
    Assert-Equal '+1.50 MB' (Format-Bytes ([long]1572864) -Signed) 'signed positive'
    Assert-Equal '-2.00 GB' (Format-Bytes ([long]-2GB) -Signed) 'signed negative'
    Assert-Equal '-2.00 GB' (Format-Bytes ([long]-2GB)) 'negative without -Signed keeps sign'
    Assert-That ((Format-Bytes ([long]3TB)) -like '3.00 TB') 'TB'
    Assert-That ((Format-Count 1234567) -match '1.234.567|1,234,567|1 234 567') 'count grouping'
}

Invoke-TestCase 'T03' 'Path syntax validation rejects empty, relative, wildcard, traversal, UNC, drive-relative, streams' {
    foreach ($bad in @('', ' ', 'relative\path', 'Temp', '..\x', '*', 'C:\Temp\*', 'C:\a\..\b', '\\server\share\x', 'C:foo', 'C:\a:stream', ("C:\a" + [char]0))) {
        Assert-That (-not (Test-FullyQualifiedLocalPath $bad)) "should reject '$bad'"
    }
    if ($onWin) { Assert-That (Test-FullyQualifiedLocalPath 'C:\Windows\Temp') 'accepts C:\Windows\Temp' }
    else { Assert-That (Test-FullyQualifiedLocalPath '/tmp/x') 'accepts /tmp/x'; Assert-That (-not (Test-FullyQualifiedLocalPath 'C:\Windows')) 'rejects Windows syntax off-Windows' }
    Assert-Equal $null (Get-NormalizedPath '') 'normalize empty'
}

Invoke-TestCase 'T04' 'Target specs: refused anchors/segments/roots/outside; missing = not applicable; valid = exists' {
    $bad = @{ LocalAppData = @{ Name = 'LocalAppData'; Path = $null; Ok = $false; Reason = 'mismatch' } }
    $s = New-TargetSpec -AnchorName 'LocalAppData' -Segments @('Temp') -Label 'x' -AnchorsOverride $bad
    $null = Test-TargetSpec $s
    Assert-That (-not $s.Valid -and $s.Reason -like 'Refused*') 'failed anchor refused'
    foreach ($seg in @('..', 'a\b', 'a/b', '*', 'c:', '.', ' ')) {
        $s = New-TargetSpec -AnchorName 'LocalAppData' -Segments @($seg) -Label 'x' -AnchorsOverride $fakeAnchors
        $null = Test-TargetSpec $s
        Assert-That (-not $s.Valid) "segment '$seg' refused"
    }
    $root = [IO.Path]::GetPathRoot($sandbox)
    $s = @{ Label = 'root'; Anchor = $root; Path = $root; Kind = 'Tree'; Reason = '' }
    $null = Test-TargetSpec $s
    Assert-That (-not $s.Valid) 'drive root refused'
    $s = @{ Label = 'outside'; Anchor = $SB.LocalAppData; Path = $SB.Outside; Kind = 'Tree'; Reason = '' }
    $null = Test-TargetSpec $s
    Assert-That (-not $s.Valid -and $s.Reason -match 'outside') 'outside anchor refused'
    $s = @{ Label = 'equal'; Anchor = $SB.LocalAppData; Path = $SB.LocalAppData; Kind = 'Tree'; Reason = '' }
    $null = Test-TargetSpec $s
    Assert-That (-not $s.Valid) 'target equal to anchor refused'
    $s = New-Spec 'DoesNotExist\Sub'
    Assert-That ($s.Valid -and -not $s.Exists) 'missing target is valid but not existing'
    $s = New-Spec 'Temp'
    Assert-That ($s.Valid -and $s.Exists) 'Temp valid and exists'
}

Invoke-TestCase 'T05' 'A junction/symlink anywhere between anchor and target refuses the target' {
    $real = Join-Path $SB.Outside 'realcache'
    [void][IO.Directory]::CreateDirectory((Join-Path $real 'Cache'))
    New-TestFile (Join-Path $real 'Cache\keep.bin')
    $link = Join-Path $SB.LocalAppData 'LinkedVendor'
    New-DirLink $link $real
    $s = New-Spec 'LinkedVendor\Cache'
    Assert-That (-not $s.Valid -and $s.Reason -match 'junction|link') 'link component refused'
    Assert-That ([IO.File]::Exists((Join-Path $real 'Cache\keep.bin'))) 'target untouched'
}

Invoke-TestCase 'T06' 'Scan (dry run) measures correctly and changes NOTHING' {
    $base = Join-Path $SB.LocalAppData 'ScanOnly'
    New-TestFile (Join-Path $base 'old1.tmp') 1000 48
    New-TestFile (Join-Path $base 'sub\old2.tmp') 3000 100
    New-TestFile (Join-Path $base 'new.tmp') 500 1
    $before = Get-TreeSnapshot $base
    $st = New-WalkStats
    $spec = New-Spec 'ScanOnly'
    Invoke-TargetWalk -Spec $spec -Stats $st
    Assert-Equal 2 $st.EligibleFiles 'eligible files'
    Assert-Equal 4000 $st.EligibleBytes 'eligible bytes'
    Assert-Equal 1 $st.RecentFiles 'recent files'
    Assert-Equal 0 $st.Deleted 'nothing deleted'
    $after = Get-TreeSnapshot $base
    Assert-Equal $before.Count $after.Count 'file count unchanged'
    foreach ($k in $before.Keys) { Assert-That ($after.ContainsKey($k) -and $after[$k] -eq $before[$k]) "unchanged $k" }
}

Invoke-TestCase 'T07' 'Clean deletes only old files, keeps recent files, root, recent dirs and "Low"' {
    $base = $SB.Temp
    New-TestFile (Join-Path $base 'old.tmp') 2048 30
    New-TestFile (Join-Path $base 'fresh.tmp') 10 2
    New-TestFile (Join-Path $base 'olddir\deep\a.log') 100 72
    New-TestFile (Join-Path $base 'mixed\keep-new.txt') 100 1
    New-TestFile (Join-Path $base 'mixed\old.txt') 100 72
    [void][IO.Directory]::CreateDirectory((Join-Path $base 'Low'))
    [void][IO.Directory]::CreateDirectory((Join-Path $base 'newemptydir'))
    Set-DirAge (Join-Path $base 'olddir\deep') 72; Set-DirAge (Join-Path $base 'olddir') 72; Set-DirAge (Join-Path $base 'mixed') 72; Set-DirAge (Join-Path $base 'Low') 72
    $st = New-WalkStats
    # Built exactly like the UserTemp category: the Temp anchor itself is the target.
    $spec = New-TargetSpec -AnchorName 'Temp' -Segments @() -Label 'Temp' -Kind 'Tree' -MinAgeHours 24 -RemoveEmptyDirs $true -KeepDirNames @('Low') -AnchorsOverride $fakeAnchors
    $null = Test-TargetSpec $spec
    Assert-That ($spec.Valid -and $spec.Exists) ('temp spec valid: ' + $spec.Reason)
    Assert-Equal (Get-NormalizedPath $SB.LocalAppData) $spec.Anchor 'Temp is validated against LocalAppData'
    $noParent = @{ Temp = @{ Name = 'Temp'; Path = $SB.Temp; Ok = $true; Reason = '' } }
    $bad = New-TargetSpec -AnchorName 'Temp' -Segments @() -Label 'x' -AnchorsOverride $noParent
    Assert-That ($bad.Reason -like 'Refused*') 'anchor-as-target without verified parent is refused'
    Invoke-TargetWalk -Spec $spec -Stats $st -Delete
    Assert-That (-not [IO.File]::Exists((Join-Path $base 'old.tmp'))) 'old file deleted'
    Assert-That ([IO.File]::Exists((Join-Path $base 'fresh.tmp'))) 'recent file kept'
    Assert-That (-not [IO.Directory]::Exists((Join-Path $base 'olddir'))) 'old empty tree removed'
    Assert-That ([IO.File]::Exists((Join-Path $base 'mixed\keep-new.txt'))) 'recent file in mixed dir kept'
    Assert-That (-not [IO.File]::Exists((Join-Path $base 'mixed\old.txt'))) 'old file in mixed dir deleted'
    Assert-That ([IO.Directory]::Exists((Join-Path $base 'Low'))) 'Low kept'
    Assert-That ([IO.Directory]::Exists((Join-Path $base 'newemptydir'))) 'recent empty dir kept'
    Assert-That ([IO.Directory]::Exists($base)) 'root kept'
    Assert-Equal 3 $st.Deleted 'deleted count'
    Assert-Equal 'Completed' (Get-CleanStatus $st) 'status'
}

Invoke-TestCase 'T08' 'Links inside a target are never followed or deleted; outside data survives' {
    $sentinelDir = Join-Path $SB.Outside 'precious'
    New-TestFile (Join-Path $sentinelDir 'family-photo.jpg') 5000 500
    $base = Join-Path $SB.LocalAppData 'LinkTest'
    New-TestFile (Join-Path $base 'old.tmp') 10 100
    New-DirLink (Join-Path $base 'evil') $sentinelDir
    $fileLinkMade = $false
    try { New-Item -ItemType SymbolicLink -Path (Join-Path $base 'evil-file.lnk') -Target (Join-Path $sentinelDir 'family-photo.jpg') -ErrorAction Stop | Out-Null; $fileLinkMade = $true } catch { }
    $st = New-WalkStats
    Invoke-TargetWalk -Spec (New-Spec 'LinkTest' -Age 0) -Stats $st -Delete
    Assert-That ([IO.File]::Exists((Join-Path $sentinelDir 'family-photo.jpg'))) 'outside file survives'
    Assert-That ([IO.Directory]::Exists((Join-Path $base 'evil'))) 'link itself kept'
    Assert-That (-not [IO.File]::Exists((Join-Path $base 'old.tmp'))) 'normal old file deleted'
    $expected = 1
    if ($fileLinkMade) { $expected = 2; Assert-That ([IO.File]::Exists((Join-Path $base 'evil-file.lnk')) -or (Test-Path -LiteralPath (Join-Path $base 'evil-file.lnk'))) 'file link kept' }
    Assert-Equal $expected $st.ReparseSkipped 'reparse items skipped'
}

Invoke-TestCase 'T09' 'Files in use are skipped and reported (Completed with skipped files)' {
    $base = Join-Path $SB.LocalAppData 'LockTest'
    New-TestFile (Join-Path $base 'locked.dat') 777 100
    New-TestFile (Join-Path $base 'free.dat') 10 100
    $st = New-WalkStats
    $fs = $null
    $simulated = $false
    if ($onWin) {
        $fs = [IO.File]::Open((Join-Path $base 'locked.dat'), 'Open', 'ReadWrite', 'None')
    } else {
        $simulated = $true
        ${function:Invoke-FileDelete} = {
            param([string]$Path, [string]$RootFinal, [bool]$IsDirectory)
            if ($Path -like '*locked.dat') { return @{ Kind = 'InUse'; Size = [long]0; Detail = 'simulated sharing violation' } }
            & $origInvokeFileDelete -Path $Path -RootFinal $RootFinal -IsDirectory $IsDirectory
        }
    }
    try { Invoke-TargetWalk -Spec (New-Spec 'LockTest') -Stats $st -Delete }
    finally { if ($fs) { $fs.Dispose() }; Restore-Overrides }
    Assert-Equal 1 $st.InUse 'in-use count'
    Assert-Equal 777 $st.InUseBytes 'in-use bytes'
    Assert-Equal 1 $st.Deleted 'other file deleted'
    Assert-Equal 'Completed with skipped files' (Get-CleanStatus $st) 'status'
    Assert-That ([IO.File]::Exists((Join-Path $base 'locked.dat'))) 'locked file still there'
    if ($simulated) { return 'PASS' }
}

Invoke-TestCase 'T10' 'Access denied -> Partially completed; all denied -> Failed (simulated)' {
    $base = Join-Path $SB.LocalAppData 'DenyTest'
    New-TestFile (Join-Path $base 'a.dat') 10 100
    New-TestFile (Join-Path $base 'b.dat') 10 100
    ${function:Invoke-FileDelete} = {
        param([string]$Path, [string]$RootFinal, [bool]$IsDirectory)
        if ($Path -like '*a.dat') { return @{ Kind = 'Denied'; Size = [long]0; Detail = 'simulated' } }
        & $origInvokeFileDelete -Path $Path -RootFinal $RootFinal -IsDirectory $IsDirectory
    }
    try { $st = New-WalkStats; Invoke-TargetWalk -Spec (New-Spec 'DenyTest') -Stats $st -Delete } finally { Restore-Overrides }
    Assert-Equal 'Partially completed' (Get-CleanStatus $st) 'partial'
    Assert-Equal 1 @($st.Samples['Access denied']).Count 'denied sample logged'
    ${function:Invoke-FileDelete} = { param([string]$Path, [string]$RootFinal, [bool]$IsDirectory) return @{ Kind = 'Denied'; Size = [long]0; Detail = 'simulated' } }
    try { $st2 = New-WalkStats; Invoke-TargetWalk -Spec (New-Spec 'DenyTest') -Stats $st2 -Delete } finally { Restore-Overrides }
    Assert-Equal 'Failed' (Get-CleanStatus $st2) 'all denied fails'
    Assert-That ([IO.File]::Exists((Join-Path $base 'a.dat'))) 'denied file kept'
}

Invoke-TestCase 'T11' 'Name-pattern mode only touches matching files at top level' {
    $base = Join-Path $SB.LocalAppData 'Microsoft\Windows\Explorer'
    foreach ($n in @('thumbcache_32.db', 'thumbcache_idx.db', 'iconcache_32.db', 'thumbcache_256.db.bak', 'ExplorerStartupLog.etl')) { New-TestFile (Join-Path $base $n) 100 100 }
    New-TestFile (Join-Path $base 'sub\thumbcache_96.db') 100 100
    $spec = New-Spec 'Microsoft\Windows\Explorer' -Kind 'Files' -Recurse $false -Pattern '^thumbcache_[A-Za-z0-9_]+\.db$' -Age 0 -RemoveEmpty $false
    $st = New-WalkStats
    Invoke-TargetWalk -Spec $spec -Stats $st -Delete
    Assert-Equal 2 $st.Deleted 'two thumbcache files deleted'
    foreach ($n in @('iconcache_32.db', 'thumbcache_256.db.bak', 'ExplorerStartupLog.etl', 'sub\thumbcache_96.db')) { Assert-That ([IO.File]::Exists((Join-Path $base $n))) "kept $n" }
}

Invoke-TestCase 'T12' 'Single-file mode deletes exactly that file' {
    New-TestFile (Join-Path $SB.Windows 'MEMORY.DMP') 4096 400
    New-TestFile (Join-Path $SB.Windows 'MEMORY.DMP.keep') 10 400
    New-TestFile (Join-Path $SB.Windows 'notepad.exe') 10 400
    $spec = New-TargetSpec -AnchorName 'Windows' -Segments @('MEMORY.DMP') -Label 'MEMORY.DMP' -Kind 'SingleFile' -MinAgeHours 336 -AnchorsOverride $fakeAnchors
    $null = Test-TargetSpec $spec
    $st = New-WalkStats
    Invoke-TargetWalk -Spec $spec -Stats $st -Delete
    Assert-Equal 1 $st.Deleted 'one deleted'
    Assert-That (-not [IO.File]::Exists((Join-Path $SB.Windows 'MEMORY.DMP'))) 'dump deleted'
    Assert-That ([IO.File]::Exists((Join-Path $SB.Windows 'notepad.exe'))) 'neighbour kept'
    Assert-That ([IO.File]::Exists((Join-Path $SB.Windows 'MEMORY.DMP.keep'))) 'similar name kept'
}

Invoke-TestCase 'T13' 'Paths with spaces and & ( ) '' % ! ^ and non-ASCII characters' {
    Assert-That ($SB.LocalAppData -like "*$weird*") 'sandbox uses the odd name'
    $sub = Join-Path $SB.LocalAppData ('Weird ' + $weird)
    New-TestFile (Join-Path $sub ('file ' + $weird + '.tmp')) 10 100
    $spec = New-Spec ('Weird ' + $weird)
    $st = New-WalkStats
    Invoke-TargetWalk -Spec $spec -Stats $st -Delete
    Assert-Equal 1 $st.Deleted 'odd-name file deleted'
    Assert-That ([IO.Directory]::Exists($sub)) 'odd-name root kept'
}

Invoke-TestCase 'T14' 'Missing locations are "Not applicable", not errors' {
    $cat = @{ Id = 'X'; Name = 'Missing test'; Admin = $false; Group = 'Safe'; Handler = 'Walk'; Targets = { @(New-Spec 'Nope\Never') } }
    $r = Invoke-CategoryScan $cat
    Assert-That (-not $r.Applicable) 'not applicable'
    $c = Invoke-CategoryClean $cat
    Assert-Equal 'Not applicable' $c.Status 'clean status'
}

Invoke-TestCase 'T15' 'Files queued for the next restart (PendingFileRenameOperations) are kept' {
    $base = Join-Path $SB.LocalAppData 'PendingTest'
    New-TestFile (Join-Path $base 'queued.dll') 10 100
    New-TestFile (Join-Path $base 'qdir\inner.dll') 10 100
    New-TestFile (Join-Path $base 'normal.tmp') 10 100
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in @((Join-Path $base 'queued.dll'), (Join-Path $base 'qdir'))) { [void]$set.Add($p); $list.Add($p) }
    $st = New-WalkStats
    Invoke-TargetWalk -Spec (New-Spec 'PendingTest') -Stats $st -Delete -Exclusions @{ Set = $set; List = $list }
    Assert-Equal 2 $st.PendingSkipped 'pending skipped'
    Assert-That ([IO.File]::Exists((Join-Path $base 'queued.dll'))) 'queued kept'
    Assert-That ([IO.File]::Exists((Join-Path $base 'qdir\inner.dll'))) 'file in queued dir kept'
    Assert-That (-not [IO.File]::Exists((Join-Path $base 'normal.tmp'))) 'normal deleted'
}

Invoke-TestCase 'T16' 'Cancellation stops at a safe point and reports Cancelled' {
    $base = Join-Path $SB.LocalAppData 'CancelTest'
    for ($i = 0; $i -lt 600; $i++) { New-TestFile (Join-Path $base ('f{0:D4}.tmp' -f $i)) 1 100 }
    $script:cancelAfter = 100
    ${function:Invoke-FileDelete} = {
        param([string]$Path, [string]$RootFinal, [bool]$IsDirectory)
        $script:cancelAfter--
        if ($script:cancelAfter -le 0) { $script:CancelRequested = $true }
        & $origInvokeFileDelete -Path $Path -RootFinal $RootFinal -IsDirectory $IsDirectory
    }
    try { $st = New-WalkStats; Invoke-TargetWalk -Spec (New-Spec 'CancelTest') -Stats $st -Delete } finally { Restore-Overrides; $script:CancelRequested = $false }
    Assert-That $st.Cancelled 'cancel flag'
    Assert-Equal 'Cancelled' (Get-CleanStatus $st) 'status'
    $left = @([IO.Directory]::GetFiles($base)).Count
    Assert-That ($left -gt 0 -and $left -lt 600) "partial ($left left)"
    Assert-That ($st.Deleted -lt 600) 'stopped early'
}

Invoke-TestCase 'T17' 'Repeated runs: second clean finds nothing and still reports Completed' {
    $base = Join-Path $SB.LocalAppData 'RepeatTest'
    New-TestFile (Join-Path $base 'x.tmp') 10 100
    $st1 = New-WalkStats; Invoke-TargetWalk -Spec (New-Spec 'RepeatTest') -Stats $st1 -Delete
    $st2 = New-WalkStats; Invoke-TargetWalk -Spec (New-Spec 'RepeatTest') -Stats $st2 -Delete
    Assert-Equal 1 $st1.Deleted 'first run'
    Assert-Equal 0 $st2.EligibleFiles 'second run eligible'
    Assert-Equal 'Completed' (Get-CleanStatus $st2) 'second status'
}

Invoke-TestCase 'T18' 'Status rules' {
    $s = New-WalkStats; Assert-Equal 'Completed' (Get-CleanStatus $s) 'empty'
    $s = New-WalkStats; $s.Deleted = 5; $s.InUse = 1; Assert-Equal 'Completed with skipped files' (Get-CleanStatus $s) 'in use'
    $s = New-WalkStats; $s.Deleted = 5; $s.InaccessibleDirs = 1; Assert-Equal 'Completed with skipped files' (Get-CleanStatus $s) 'unreadable subfolder'
    $s = New-WalkStats; $s.Deleted = 5; $s.Other = 1; Assert-Equal 'Partially completed' (Get-CleanStatus $s) 'error'
    $s = New-WalkStats; $s.Outside = 1; Assert-Equal 'Failed' (Get-CleanStatus $s) 'outside only'
    $s = New-WalkStats; $s.RootUnreadable = $true; Assert-Equal 'Failed' (Get-CleanStatus $s) 'root unreadable'
    $s = New-WalkStats; $s.Cancelled = $true; $s.Deleted = 3; Assert-Equal 'Cancelled' (Get-CleanStatus $s) 'cancelled'
}

Invoke-TestCase 'T19' 'Logs: created, written, rotated (own files only); failure is reported, not thrown' {
    $logDir = Join-Path $sandbox 'logs'
    [void][IO.Directory]::CreateDirectory($logDir)
    Assert-That (Start-RunLog 'cleanup' $logDir) 'log started'
    Write-RunLog 'hello'
    Assert-That ([IO.File]::ReadAllText($script:Log.Path) -match 'hello') 'line written'
    for ($i = 0; $i -lt 50; $i++) {
        $p = Join-Path $logDir ('aiznm_20250101_{0:D6}_scan.log' -f $i)
        [IO.File]::WriteAllText($p, 'x'); [IO.File]::SetLastWriteTimeUtc($p, [DateTime]::UtcNow.AddMinutes(-1 * (100 + $i)))
    }
    [IO.File]::WriteAllText((Join-Path $logDir 'my-notes.txt'), 'keep me')
    [IO.File]::WriteAllText((Join-Path $logDir 'aiznm_bad_name.log'), 'keep me')
    $removed = Invoke-LogRetention -Directory $logDir -KeepCount 40 -KeepDays 90
    $left = @([IO.Directory]::GetFiles($logDir, 'aiznm_*_*_*.log') | Where-Object { (Split-Path -Leaf $_) -match '^aiznm_\d{8}_\d{6}_[a-z]+\.log$' }).Count
    Assert-Equal 40 $left 'kept newest 40'
    Assert-Equal 11 $removed 'removed 11'
    Assert-That ([IO.File]::Exists((Join-Path $logDir 'my-notes.txt'))) 'unrelated file untouched'
    Assert-That ([IO.File]::Exists((Join-Path $logDir 'aiznm_bad_name.log'))) 'non-matching name untouched'
    $first = $script:Log.Path
    Assert-That (Start-RunLog 'cleanup' $logDir) 'second log in the same second'
    Assert-That ($script:Log.Path -ne $first) 'same-second logs get distinct names'
    $blocker = Join-Path $sandbox 'not-a-dir'
    [IO.File]::WriteAllText($blocker, 'file')
    $ok = Start-RunLog 'cleanup' (Join-Path $blocker 'sub')
    Assert-That (-not $ok) 'unwritable log reported'
    Assert-That ($script:Log.Failed -and $script:Log.LastError) 'error captured'
    Write-RunLog 'ignored'
}

Invoke-TestCase 'T20' 'Elevated request validation refuses anything but known admin categories' {
    Assert-That (Test-ElevatedRequest 'clean' 'WinTemp+SystemDumps').Ok 'valid admin list'
    Assert-That (Test-ElevatedRequest 'scan' 'DeliveryOpt').Ok 'valid scan'
    foreach ($bad in @(@('clean', 'UserTemp'), @('clean', 'BrowserEdge'), @('clean', 'RecycleBin'), @('clean', 'WinTemp;calc'), @('clean', 'WinTemp,SystemDumps'), @('clean', 'WinTemp+..\x'), @('clean', ''), @('clean', 'Unknown'), @('delete', 'WinTemp'), @('clean', 'WinTemp "x"'), @('clean', 'WinTemp&calc'))) {
        Assert-That (-not (Test-ElevatedRequest $bad[0] $bad[1]).Ok) ("refuse {0} {1}" -f $bad[0], $bad[1])
    }
}

Invoke-TestCase 'T21' 'Elevated result path validation' {
    $ex = Join-Path $sandbox 'aiznm_CLEANER\Exchange'
    [void][IO.Directory]::CreateDirectory($ex)
    $good = Join-Path $ex ('elevated-' + ('a' * 32) + '.json')
    Assert-Equal $null (Test-ExchangePath $good) 'good path'
    Assert-That ($null -ne (Test-ExchangePath (Join-Path $ex 'elevated-xyz.json'))) 'bad name'
    Assert-That ($null -ne (Test-ExchangePath (Join-Path $sandbox ('elevated-' + ('a' * 32) + '.json')))) 'wrong folder'
    Assert-That ($null -ne (Test-ExchangePath 'relative\elevated-x.json')) 'relative'
    [IO.File]::WriteAllText($good, '{}')
    Assert-That ($null -ne (Test-ExchangePath $good)) 'existing file refused'
    $real = Join-Path $SB.Outside 'xchg'
    [void][IO.Directory]::CreateDirectory($real)
    $app2 = Join-Path $sandbox 'other\aiznm_CLEANER'
    [void][IO.Directory]::CreateDirectory($app2)
    New-DirLink (Join-Path $app2 'Exchange') $real
    Assert-That ((Test-ExchangePath (Join-Path $app2 ('Exchange\elevated-' + ('b' * 32) + '.json'))) -match 'junction|link') 'linked Exchange refused'
}

Invoke-TestCase 'T22' 'Elevated JSON round trip keeps 64-bit sizes, arrays and samples' {
    $cat = Get-Category 'WinTemp'
    $r = New-CategoryResult $cat
    $r.Status = 'Completed'; $r.Stats.DeletedBytes = [long]6GB; $r.Stats.Deleted = 3; $r.Stats.InUse = 1
    Add-Sample $r.Stats 'In use' '%SystemRoot%\Temp\x.tmp'
    $r.Targets = @(@{ Label = 'Windows Temp'; Path = 'C:\Windows\Temp'; State = 'OK'; Reason = ''; Bytes = [long]5GB; Files = 3 })
    $payload = @{ Version = '3'; Results = @($r); Fatal = $null }
    $file = Join-Path $sandbox 'roundtrip.json'
    [IO.File]::WriteAllText($file, ($payload | ConvertTo-Json -Depth 8 -Compress))
    $back = Read-ElevatedResult $file
    Assert-That $back.Ok 'parsed ok'
    Assert-Equal 1 $back.Results.Count 'one result'
    $x = $back.Results[0]
    Assert-Equal ([long]6GB) ([long]$x.Stats.DeletedBytes) 'int64 preserved'
    Assert-Equal 1 @($x.Targets).Count 'targets array'
    Assert-Equal 1 @($x.Stats.Samples['In use']).Count 'samples array'
    $tot = New-WalkStats; Merge-WalkStats $tot $x.Stats; Merge-WalkStats $tot $x.Stats
    Assert-Equal ([long]12GB) ([long]$tot.DeletedBytes) 'merge sums int64'
    [IO.File]::WriteAllText($file, '{"Fatal":"Request refused: x","Results":[]}')
    $f = Read-ElevatedResult $file
    Assert-That (-not $f.Ok -and $f.Error -like 'Request refused*') 'fatal propagated'
    [IO.File]::WriteAllText($file, 'not json')
    Assert-That (-not (Read-ElevatedResult $file).Ok) 'garbage handled'
}

Invoke-TestCase 'T23' 'Steam inventory: libraries, manifests, confirmed vs possible (read-only)' {
    $steam = Join-Path $sandbox 'Steam'
    $lib2 = Join-Path $sandbox 'SteamLibrary 2'
    New-TestFile (Join-Path $steam 'steamapps\common\Counter-Strike Global Offensive\game.bin') 10 1
    $vdf = '"libraryfolders"' + "`n{`n" + '  "0" { "path" "' + ($steam -replace '\\', '\\') + '" }' + "`n" + '  "1" { "path" "' + ($lib2 -replace '\\', '\\') + '" }' + "`n}`n"
    [IO.File]::WriteAllText((Join-Path $steam 'steamapps\libraryfolders.vdf'), $vdf)
    [IO.File]::WriteAllText((Join-Path $steam 'steamapps\appmanifest_730.acf'), '"AppState" { "appid" "730" "name" "Counter-Strike 2" "installdir" "Counter-Strike Global Offensive" "SizeOnDisk" "36000000000" "StateFlags" "4" }')
    [void][IO.Directory]::CreateDirectory((Join-Path $lib2 'steamapps'))
    [IO.File]::WriteAllText((Join-Path $lib2 'steamapps\appmanifest_1.acf'), '"AppState" { "appid" "1" "name" "Ghost Game" "installdir" "Ghost" "SizeOnDisk" "5" }')
    $before = Get-TreeSnapshot $sandbox
    $inv = Get-SteamInventory -SteamPathOverride $steam
    Assert-That (@($inv.Notes).Count -eq 0) ('steam notes: ' + (@($inv.Notes) -join '; '))
    Assert-That $inv.Installed 'steam found'
    Assert-Equal 2 @($inv.Libraries).Count 'two libraries'
    $cs = @($inv.Games | Where-Object { $_.Name -eq 'Counter-Strike 2' })[0]
    Assert-That ($cs.Confirmed -and [long]$cs.Bytes -eq 36000000000) 'CS2 confirmed with size'
    $ghost = @($inv.Games | Where-Object { $_.Name -eq 'Ghost Game' })[0]
    Assert-That (-not $ghost.Confirmed) 'manifest-only game is only "possible"'
    $after = Get-TreeSnapshot $sandbox
    Assert-Equal $before.Count $after.Count 'inventory changed nothing'
}

Invoke-TestCase 'T24' 'Riot / VALORANT and Epic manifests parsed read-only' {
    $pd = $SB.ProgramData
    $val = Join-Path $sandbox 'Riot Games\VALORANT\live'
    New-TestFile (Join-Path $val 'ShooterGame\Binaries\Win64\VALORANT-Win64-Shipping.exe') 10 1
    New-TestFile (Join-Path $pd 'Riot Games\RiotClientInstalls.json') 2 1
    $yamlPath = Join-Path $pd 'Riot Games\Metadata\valorant.live\valorant.live.product_settings.yaml'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $yamlPath))
    [IO.File]::WriteAllText($yamlPath, ('product_install_full_path: "' + ($val -replace '\\', '/') + '"' + "`nproduct_install_root: x`n"))
    $r = Get-RiotInventory -ProgramDataOverride $pd
    Assert-That ($r.Client -and $r.ValorantConfirmed) 'VALORANT confirmed'
    $man = Join-Path $pd 'Epic\EpicGamesLauncher\Data\Manifests'
    [void][IO.Directory]::CreateDirectory($man)
    $loc = Join-Path $sandbox 'Epic Games\Fortnite'
    [void][IO.Directory]::CreateDirectory($loc)
    [IO.File]::WriteAllText((Join-Path $man 'A.item'), (@{ DisplayName = 'Fortnite'; InstallLocation = $loc; InstallSize = 1000; bIsIncompleteInstall = $false } | ConvertTo-Json))
    [IO.File]::WriteAllText((Join-Path $man 'B.item'), (@{ DisplayName = 'Gone'; InstallLocation = (Join-Path $sandbox 'nope'); InstallSize = 5 } | ConvertTo-Json))
    $e = Get-EpicInventory -ProgramDataOverride $pd
    Assert-Equal 2 @($e.Games).Count 'two epic manifests'
    Assert-That (@($e.Games | Where-Object { $_.Name -eq 'Fortnite' })[0].Confirmed) 'Fortnite confirmed'
    Assert-That (-not @($e.Games | Where-Object { $_.Name -eq 'Gone' })[0].Confirmed) 'Gone only possible'
}

Invoke-TestCase 'T25' 'Browser profiles: only Cache/Code Cache/GPUCache (cache2/startupCache) are touched' {
    $ud = Join-Path $SB.LocalAppData 'Microsoft\Edge\User Data'
    $protected = @('Cookies', 'Network\Cookies', 'Login Data', 'History', 'Bookmarks', 'Preferences', 'Web Data', 'Local Storage\leveldb\000003.log', 'IndexedDB\x\y.ldb', 'Service Worker\CacheStorage\abc\data', 'Service Worker\ScriptCache\index', 'Sessions\Session_1', 'Extensions\abc\1.0\manifest.json')
    foreach ($p in @('Default', 'Profile 1')) {
        foreach ($f in $protected) { New-TestFile (Join-Path $ud "$p\$f") 50 500 }
        New-TestFile (Join-Path $ud "$p\Cache\Cache_Data\f_000001") 1000 500
        New-TestFile (Join-Path $ud "$p\Code Cache\js\index") 200 500
        New-TestFile (Join-Path $ud "$p\GPUCache\data_0") 300 500
    }
    New-TestFile (Join-Path $ud 'System Profile\Cache\x') 10 500
    New-TestFile (Join-Path $ud 'Crashpad\reports\r.dmp') 10 500
    New-TestFile (Join-Path $ud 'Local State') 10 500
    $info = Get-BrowserProfiles (Get-BrowserDef 'BrowserEdge') $fakeAnchors
    Assert-That $info.Installed 'edge found'
    Assert-Equal 2 @($info.Profiles).Count 'two real profiles'
    $cat = Get-Category 'BrowserEdge'
    ${function:Test-BrowserRunning} = { param($Def) $false }
    $scan = Invoke-CategoryScan $cat
    Assert-Equal 3000 ([long]$scan.Stats.EligibleBytes) 'estimate = caches only'
    $res = Invoke-CategoryClean $cat
    Assert-Equal 'Completed' $res.Status 'edge clean status'
    Assert-Equal 6 ([long]$res.Stats.Deleted) 'six cache files deleted'
    foreach ($p in @('Default', 'Profile 1')) { foreach ($f in $protected) { Assert-That ([IO.File]::Exists((Join-Path $ud "$p\$f"))) "protected $p\$f kept" } }
    Assert-That ([IO.File]::Exists((Join-Path $ud 'System Profile\Cache\x'))) 'non-profile folder untouched'
    Assert-That ([IO.File]::Exists((Join-Path $ud 'Local State'))) 'Local State untouched'
    $ff = Join-Path $SB.LocalAppData 'Mozilla\Firefox\Profiles\abcd1234.default-release'
    New-TestFile (Join-Path $ff 'cache2\entries\E1') 400 500
    New-TestFile (Join-Path $ff 'startupCache\startupCache.8.little') 100 500
    New-TestFile (Join-Path $ff 'safebrowsing\x.vlpset') 100 500
    $fres = Invoke-CategoryClean (Get-Category 'BrowserFirefox')
    Assert-Equal 2 ([long]$fres.Stats.Deleted) 'firefox caches deleted'
    Assert-That ([IO.File]::Exists((Join-Path $ff 'safebrowsing\x.vlpset'))) 'other firefox data kept'
}

Invoke-TestCase 'T26' 'Running browser is skipped, never closed' {
    $ud = Join-Path $SB.LocalAppData 'Google\Chrome\User Data'
    New-TestFile (Join-Path $ud 'Default\Preferences') 10 500
    New-TestFile (Join-Path $ud 'Default\Cache\Cache_Data\f_1') 100 500
    ${function:Test-BrowserRunning} = { param($Def) $true }
    $r = Invoke-CategoryClean (Get-Category 'BrowserChrome')
    Assert-Equal 'Skipped' $r.Status 'skipped'
    Assert-That ([IO.File]::Exists((Join-Path $ud 'Default\Cache\Cache_Data\f_1'))) 'cache untouched while running'
    ${function:Test-BrowserRunning} = { param($Def) $false }
    $scan = Invoke-CategoryScan (Get-Category 'BrowserBrave')
    Assert-That (-not $scan.Applicable) 'Brave not installed -> not applicable'
}

Invoke-TestCase 'T27' 'Shader caches: skipped while a game runs; AMD never offered on NVIDIA PC' {
    New-TestFile (Join-Path $SB.LocalAppData 'NVIDIA\DXCache\abc.nvph') 100 500
    New-TestFile (Join-Path $SB.LocalAppData 'AMD\DxCache\x.bin') 100 500
    $orig = ${function:Get-RunningGames}
    ${function:Get-RunningGames} = { @('VALORANT-Win64-Shipping') }
    try { $r = Invoke-CategoryClean (Get-Category 'ShaderNvidia') } finally { ${function:Get-RunningGames} = $orig }
    Assert-Equal 'Skipped' $r.Status 'skipped while game runs'
    Assert-That ([IO.File]::Exists((Join-Path $SB.LocalAppData 'NVIDIA\DXCache\abc.nvph'))) 'nvidia cache kept'
    $a = Invoke-CategoryScan (Get-Category 'ShaderAmd')
    Assert-That (-not $a.Applicable -and $a.Reason -match 'No AMD') 'AMD not applicable'
    $ac = Invoke-CategoryClean (Get-Category 'ShaderAmd')
    Assert-Equal 'Not applicable' $ac.Status 'AMD clean refused'
    Assert-That ([IO.File]::Exists((Join-Path $SB.LocalAppData 'AMD\DxCache\x.bin'))) 'AMD folder untouched'
    $n = Invoke-CategoryClean (Get-Category 'ShaderNvidia')
    Assert-Equal 'Completed' $n.Status 'nvidia cleaned when no game runs'
}

Invoke-TestCase 'T28' 'Temp cleanup is skipped during an installation' {
    New-TestFile (Join-Path $SB.Temp 'during-install.tmp') 10 100
    $orig = ${function:Get-InstallActivity}
    ${function:Get-InstallActivity} = { 'A Windows Installer (MSI) installation is running.' }
    try { $r = Invoke-CategoryClean (Get-Category 'UserTemp') } finally { ${function:Get-InstallActivity} = $orig }
    Assert-Equal 'Skipped' $r.Status 'skipped'
    Assert-That ([IO.File]::Exists((Join-Path $SB.Temp 'during-install.tmp'))) 'temp file kept'
}

Invoke-TestCase 'T29' 'Admin categories refuse to run without admin rights; run correctly when elevated' {
    New-TestFile (Join-Path $SB.Windows 'Temp\old-setup.log') 100 400
    New-TestFile (Join-Path $SB.Windows 'Temp\recent-setup.log') 100 24
    $r = Invoke-CategoryClean (Get-Category 'WinTemp')
    if (-not (& $origTestIsAdmin)) { Assert-Equal 'Skipped' $r.Status 'not admin -> skipped'; Assert-That ([IO.File]::Exists((Join-Path $SB.Windows 'Temp\old-setup.log'))) 'kept' }
    ${function:Test-IsAdmin} = { $true }
    try { $r2 = Invoke-CategoryClean (Get-Category 'WinTemp') } finally { Restore-Overrides }
    Assert-Equal 'Completed' $r2.Status 'elevated clean'
    Assert-That (-not [IO.File]::Exists((Join-Path $SB.Windows 'Temp\old-setup.log'))) 'week-old file deleted'
    Assert-That ([IO.File]::Exists((Join-Path $SB.Windows 'Temp\recent-setup.log'))) 'one-day-old file kept (7-day rule)'
}

Invoke-TestCase 'T30' 'Category definitions are complete and conservative' {
    $allowedAnchors = @('LocalAppData', 'Temp', 'Windows', 'ProgramData', 'LocalLow')
    foreach ($c in (Get-Categories)) {
        foreach ($k in @('Id', 'Name', 'Group', 'Removes', 'Why', 'Side', 'Regenerates', 'CloseFirst', 'Handler', 'Risk')) { Assert-That ([bool]$c[$k]) "$($c.Id) has $k" }
        if ($c.Default) { Assert-That ($c.Risk -eq 'Low' -and -not $c.Irreversible -and $c.Group -eq 'Safe') "$($c.Id) default only if low risk" }
        foreach ($s in @(& $c.Targets)) {
            Assert-That ($allowedAnchors -contains $s.AnchorName) "$($c.Id) anchor $($s.AnchorName)"
            if ($s.Path) { Assert-InSandbox $s.Path }
        }
    }
    Assert-That ((Get-Category 'RecycleBin').Irreversible -and -not (Get-Category 'RecycleBin').Default) 'recycle bin opt-in + irreversible'
    foreach ($id in @('ShaderDirectX', 'ShaderNvidia', 'ShaderAmd', 'AppCrashDumps', 'SystemDumps', 'BrowserEdge', 'DeliveryOpt', 'Thumbnails')) { Assert-That (-not (Get-Category $id).Default) "$id is opt-in" }
    Assert-Equal 2 @((Get-Categories) | Where-Object { $_.Default }).Count 'only two defaults (temp folders)'
}

Invoke-TestCase 'T31' 'Thumbnail cache is all-or-nothing when Explorer holds a file' {
    $base = Join-Path $SB.LocalAppData 'Microsoft\Windows\Explorer'
    foreach ($n in @('thumbcache_32.db', 'thumbcache_idx.db')) { New-TestFile (Join-Path $base $n) 100 100 }
    $fs = [IO.File]::Open((Join-Path $base 'thumbcache_idx.db'), 'Open', 'ReadWrite', 'None')
    $lockWorks = $true
    try { $fs2 = [IO.File]::Open((Join-Path $base 'thumbcache_idx.db'), 'Open', 'ReadWrite', 'None'); $fs2.Dispose(); $lockWorks = $false } catch { }
    try { $r = Invoke-CategoryClean (Get-Category 'Thumbnails') } finally { $fs.Dispose() }
    if (-not $lockWorks) { return 'SKIP: this platform does not enforce exclusive opens' }
    Assert-Equal 'Skipped' $r.Status 'skipped as a whole'
    Assert-That ([IO.File]::Exists((Join-Path $base 'thumbcache_32.db'))) 'unlocked file kept for consistency'
    $r2 = Invoke-CategoryClean (Get-Category 'Thumbnails')
    Assert-Equal 'Completed' $r2.Status 'cleaned when not locked'
}

Invoke-TestCase 'T32' 'End-to-end: real categories on a sandbox profile -> cleanup run, measured report and log' {
    New-TestFile (Join-Path $SB.Temp 'e2e-old.tmp') 5000 100
    New-TestFile (Join-Path $SB.Temp 'e2e-new.tmp') 5000 1
    New-TestFile (Join-Path $SB.LocalAppData 'CrashDumps\game.exe.111.dmp') 7000 (24 * 30)
    New-TestFile (Join-Path $SB.LocalAppData 'CrashDumps\game.exe.222.dmp') 7000 (24 * 2)
    New-TestFile (Join-Path $SB.LocalAppData 'Microsoft\Windows\WER\ReportArchive\AppCrash_x\Report.wer') 300 (24 * 30)
    Set-DirAge (Join-Path $SB.LocalAppData 'Microsoft\Windows\WER\ReportArchive\AppCrash_x') (24 * 30)
    New-TestFile (Join-Path $SB.LocalAppData 'Microsoft\Windows\WER\ReportArchive\AppCrash_new\Report.wer') 300 1
    New-TestFile (Join-Path $SB.Windows 'Minidump\010125-1.dmp') 9000 (24 * 60)
    New-TestFile (Join-Path $SB.Windows 'LiveKernelReports\WATCHDOG\WATCHDOG-1.dmp') 9000 (24 * 60)
    New-TestFile (Join-Path $SB.Windows 'LiveKernelReports\WATCHDOG\notes.txt') 10 (24 * 60)
    New-TestFile (Join-Path $SB.ProgramData 'Microsoft\Windows\WER\ReportQueue\Kernel_x\Report.wer') 300 (24 * 30)
    $ids = @('UserTemp', 'WinTemp', 'AppCrashDumps', 'WerUser', 'WerSystem', 'SystemDumps', 'ShaderDirectX')
    $cats = @($ids | ForEach-Object { Get-Category $_ })
    foreach ($c in $cats) { foreach ($s in (Get-ResolvedTargets $c)) { if ($s.Path) { Assert-InSandbox $s.Path } } }
    ${function:Test-IsAdmin} = { $true }
    try {
        $scan = Invoke-ScanCategories $cats
        Invoke-CleanupRun -Ids $ids -ScanResults $scan
    } finally { Restore-Overrides }
    Assert-That (-not [IO.File]::Exists((Join-Path $SB.Temp 'e2e-old.tmp'))) 'old temp deleted'
    Assert-That ([IO.File]::Exists((Join-Path $SB.Temp 'e2e-new.tmp'))) 'new temp kept'
    Assert-That (-not [IO.File]::Exists((Join-Path $SB.LocalAppData 'CrashDumps\game.exe.111.dmp'))) '30-day dump deleted'
    Assert-That ([IO.File]::Exists((Join-Path $SB.LocalAppData 'CrashDumps\game.exe.222.dmp'))) '2-day dump kept'
    if ($onWin) {
        Assert-That (-not [IO.File]::Exists((Join-Path $SB.Windows 'LiveKernelReports\WATCHDOG\WATCHDOG-1.dmp'))) 'old live kernel dump deleted'
        Assert-That (-not [IO.File]::Exists((Join-Path $SB.Windows 'Minidump\010125-1.dmp'))) 'old minidump deleted'
    } else {
        # Without the Windows-only verified-delete helper, admin work must be refused, not done a weaker way.
        Assert-That ([IO.File]::Exists((Join-Path $SB.Windows 'LiveKernelReports\WATCHDOG\WATCHDOG-1.dmp'))) 'admin category refused without native helper'
        Assert-That ([IO.File]::ReadAllText($script:Log.Path) -match 'verified-delete helper could not be loaded') 'refusal reason logged'
    }
    Assert-That ([IO.File]::Exists((Join-Path $SB.Windows 'LiveKernelReports\WATCHDOG\notes.txt'))) 'non-dmp file kept'
    Assert-That (-not [IO.Directory]::Exists((Join-Path $SB.LocalAppData 'Microsoft\Windows\WER\ReportArchive\AppCrash_x'))) 'old report folder removed'
    Assert-That ([IO.File]::Exists((Join-Path $SB.LocalAppData 'Microsoft\Windows\WER\ReportArchive\AppCrash_new\Report.wer'))) 'recent report kept'
    $log = [IO.File]::ReadAllText($script:Log.Path)
    foreach ($needle in @('Free space before', 'Results per category', 'measured change', 'Overall status', 'Estimated (scan)')) { Assert-That ($log -match [regex]::Escape($needle)) "log has '$needle'" }
    Assert-That ($script:Log.Path -like "$sandbox*") 'log written inside sandbox (fake LocalAppData)'
    Assert-That ($log -notmatch [regex]::Escape($SB.LocalAppData)) 'personal path shortened in log'
}

Invoke-TestCase 'T33' 'Drive measurements are 64-bit and deltas may be negative' {
    $root = [IO.Path]::GetPathRoot($sandbox)
    $snap = Get-DriveSnapshot @($root)
    Assert-That ($snap.Contains($root) -and $snap[$root].Total -gt 0 -and $snap[$root].Free -is [long]) 'snapshot'
    $b = [ordered]@{ 'C:\' = @{ Free = [long]100GB; Total = [long]500GB } }
    $a = [ordered]@{ 'C:\' = @{ Free = [long]99GB; Total = [long]500GB } }
    $d = @(Get-DriveDeltas $b $a)
    Assert-Equal ([long]-1GB) ([long]$d[0].Delta) 'negative delta reported as negative'
}

Invoke-TestCase 'T34' 'Tables and detail views render within the layout width' {
    $script:QuietUi = $false
    $script:UiWidth = 96
    $cats = @(Get-Categories)
    $results = @{}
    foreach ($c in $cats) { $results[$c.Id] = Invoke-CategoryScan $c }
    $sel = @{}; foreach ($c in $cats) { $sel[$c.Id] = [bool]$c.Default }
    $records = & { Write-CategoryTable -Cats $cats -Results $results -Selected $sel -WithKeys } 6>&1
    $script:QuietUi = $true
    $lines = @(); $cur = ''
    foreach ($rec in $records) {
        $md = $rec.MessageData
        $txt = [string]$md
        $noNl = $false
        if ($md -and $md.PSObject.Properties['NoNewLine']) { $noNl = [bool]$md.NoNewLine; $txt = [string]$md.Message }
        $cur += $txt
        if (-not $noNl) { $lines += $cur; $cur = '' }
    }
    $rows = @($lines | Where-Object { $_ -match '^\s+\[[A-Q]\]' })
    Assert-Equal $cats.Count $rows.Count 'one row per category'
    foreach ($l in $lines) { Assert-That ($l.TrimEnd().Length -le 100) ("line too wide ({0}): {1}" -f $l.Length, $l) }
    foreach ($c in $cats) { $null = Get-CategoryDetailLines $c $results[$c.Id] }
}

Invoke-TestCase 'T35' 'CMD bootstrap loads the payload from a path with special characters and reports exit codes' {
    $copyDir = Join-Path $sandbox 'boot & (dir) %x% !y! ^z'
    [void][IO.Directory]::CreateDirectory($copyDir)
    $copy = Join-Path $copyDir 'aiznm_CLEANER.bat'
    [IO.File]::Copy($BatPath, $copy)
    $m = [regex]::Match($batText, '-Command "(.*)"\r\n')
    Assert-That $m.Success 'bootstrap command found'
    $boot = $m.Groups[1].Value
    $exe = (Get-Process -Id $PID).Path
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -Command "' + $boot + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['AIZNM_SELF'] = $copy
    $psi.EnvironmentVariables['AIZNM_MODE'] = 'library'
    $p = [Diagnostics.Process]::Start($psi)
    $null = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    Assert-Equal 0 $p.ExitCode 'library mode via bootstrap exits 0'
    [IO.File]::WriteAllText($copy, ($batText.Substring(0, $payloadIndex) + 'nothing here'))
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    Assert-Equal 70 $p.ExitCode 'damaged file -> exit 70'
    Assert-That ($out -match 'could not start') 'friendly message'
}

Invoke-TestCase 'T36' 'Native verified delete (Windows only): deletes inside root, refuses outside root, hard links and locks' {
    if (-not $onWin) { return 'SKIP: native helper exists only on Windows' }
    if (-not (Initialize-Native)) { throw ('native helper failed to compile: ' + $script:NativeError) }
    $base = Join-Path $SB.LocalAppData 'NativeTest'
    New-TestFile (Join-Path $base 'a.tmp') 123 100
    New-TestFile (Join-Path $base 'ro.tmp') 10 100
    (New-Object IO.FileInfo((Join-Path $base 'ro.tmp'))).IsReadOnly = $true
    New-TestFile (Join-Path $SB.Outside 'victim.txt') 10 100
    $root = [AiznmNativeV3]::GetFinalPath($base, $true)
    Assert-That ([bool]$root) 'root final path'
    $size = [long]0; $err = 0
    Assert-Equal 0 ([AiznmNativeV3]::DeleteSecure((Join-Path $base 'a.tmp'), $root, $false, $false, [ref]$size, [ref]$err)) 'deleted'
    Assert-Equal 123 $size 'size reported'
    Assert-Equal 5 ([AiznmNativeV3]::DeleteSecure((Join-Path $SB.Outside 'victim.txt'), $root, $false, $false, [ref]$size, [ref]$err)) 'outside refused'
    Assert-That ([IO.File]::Exists((Join-Path $SB.Outside 'victim.txt'))) 'victim intact'
    Assert-Equal 9 ([AiznmNativeV3]::DeleteSecure((Join-Path $base 'ro.tmp'), $root, $false, $false, [ref]$size, [ref]$err)) 'read-only flagged first'
    Assert-Equal 0 ([AiznmNativeV3]::DeleteSecure((Join-Path $base 'ro.tmp'), $root, $false, $true, [ref]$size, [ref]$err)) 'read-only deleted on retry'
    New-TestFile (Join-Path $base 'h1.tmp') 10 100
    try { New-Item -ItemType HardLink -Path (Join-Path $base 'h2.tmp') -Target (Join-Path $base 'h1.tmp') -ErrorAction Stop | Out-Null; Assert-Equal 6 ([AiznmNativeV3]::DeleteSecure((Join-Path $base 'h1.tmp'), $root, $false, $false, [ref]$size, [ref]$err)) 'hard link kept' } catch [System.Management.Automation.RuntimeException] { if ($_.Exception.Message -like 'Assertion*') { throw } }
    New-TestFile (Join-Path $base 'lock.tmp') 10 100
    $fs = [IO.File]::Open((Join-Path $base 'lock.tmp'), 'Open', 'ReadWrite', 'None')
    try { Assert-Equal 2 ([AiznmNativeV3]::DeleteSecure((Join-Path $base 'lock.tmp'), $root, $false, $false, [ref]$size, [ref]$err)) 'locked -> InUse' } finally { $fs.Dispose() }
    $junction = Join-Path $base 'jn'
    New-DirLink $junction $SB.Outside
    Assert-Equal 5 ([AiznmNativeV3]::DeleteSecure((Join-Path $junction 'victim.txt'), $root, $false, $false, [ref]$size, [ref]$err)) 'file reached through junction is outside the root'
    Assert-That ([IO.File]::Exists((Join-Path $SB.Outside 'victim.txt'))) 'victim intact after junction attempt'
    $rb = [AiznmNativeV3]::QueryRecycleBin([NullString]::Value)
    Assert-That ($rb.Count -eq 2) 'recycle bin query (read-only) returns size and count'
    $disp = [AiznmNativeV3]::GetDisplays()
    Assert-That ($null -ne $disp) 'display query works'
}

Invoke-TestCase 'T37' 'Windows anchors (Windows only): real anchors validate; TEMP mismatch is refused' {
    if (-not $onWin) { return 'SKIP: anchor checks need Windows known-folder APIs' }
    $saved = $script:Anchors
    try {
        $script:Anchors = $null
        $real = Get-Anchors
        Assert-That ($real.LocalAppData.Ok -and $real.Windows.Ok -and $real.ProgramData.Ok) 'real anchors verified'
        $oldTemp = $env:TEMP
        try {
            $env:TEMP = $sandbox
            $script:Anchors = $null
            $a2 = Get-Anchors
            Assert-That (-not $a2.Temp.Ok) 'TEMP pointing elsewhere is refused'
        } finally { $env:TEMP = $oldTemp }
    } finally { $script:Anchors = $saved }
}

Invoke-TestCase 'T38' 'Static checks: no "a + b, c" precedence traps; every coloured segment is a (text, colour) pair' {
    $tok = $null; $err = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($batText.Substring($payloadIndex), [ref]$tok, [ref]$err)
    $traps = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and $n.Operator -eq 'Plus' -and $n.Right -is [System.Management.Automation.Language.ArrayLiteralAst] }, $true))
    Assert-Equal 0 $traps.Count ('precedence traps: ' + (($traps | ForEach-Object { 'L' + $_.Extent.StartLineNumber }) -join ', '))
    $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-Segments' }, $true))
    Assert-That ($calls.Count -gt 20) 'found Write-Segments calls'
    foreach ($c in $calls) {
        $arg = $c.CommandElements[1]
        if ($arg -isnot [System.Management.Automation.Language.ArrayExpressionAst]) { continue }
        $inner = @($arg.SubExpression.Statements)
        if ($inner.Count -ne 1) { continue }
        $expr = $inner[0].PipelineElements[0].Expression
        $elements = @()
        if ($expr -is [System.Management.Automation.Language.ArrayLiteralAst]) { $elements = @($expr.Elements) }
        elseif ($expr -is [System.Management.Automation.Language.ArrayExpressionAst]) { throw ('L{0}: single segment must be written as @(, @(text, colour))' -f $c.Extent.StartLineNumber) }
        foreach ($e in $elements) {
            if ($e -is [System.Management.Automation.Language.ArrayExpressionAst]) {
                $pe = $e.SubExpression.Statements[0].PipelineElements[0].Expression
                $n = 1
                if ($pe -is [System.Management.Automation.Language.ArrayLiteralAst]) { $n = $pe.Elements.Count }
                Assert-Equal 2 $n ('segment at L{0} must be a (text, colour) pair: {1}' -f $e.Extent.StartLineNumber, $e.Extent.Text)
            }
        }
    }
}

Invoke-TestCase 'T39' 'Declined UAC: admin categories reported Cancelled, user categories still run, nothing hidden' {
    New-TestFile (Join-Path $SB.Windows 'Temp\uac-old.log') 100 400
    New-TestFile (Join-Path $SB.Temp 'uac-user-old.tmp') 100 100
    $origHelper = ${function:Invoke-ElevatedHelper}
    ${function:Test-IsAdmin} = { $false }
    ${function:Invoke-ElevatedHelper} = { param($Action, $Ids) @{ Ok = $false; Cancelled = $true; Error = 'Administrator permission was not granted (the Windows UAC prompt was cancelled).'; Results = @(); ExitCode = $null } }
    try {
        $cats = @((Get-Category 'WinTemp'), (Get-Category 'UserTemp'))
        $scan = Invoke-ScanCategories $cats
        Invoke-CleanupRun -Ids @('WinTemp', 'UserTemp') -ScanResults $scan
    } finally { ${function:Invoke-ElevatedHelper} = $origHelper; Restore-Overrides }
    Assert-That ([IO.File]::Exists((Join-Path $SB.Windows 'Temp\uac-old.log'))) 'admin target untouched'
    Assert-That (-not [IO.File]::Exists((Join-Path $SB.Temp 'uac-user-old.tmp'))) 'user category still ran'
    $log = [IO.File]::ReadAllText($script:Log.Path)
    Assert-That ($log -match '\[Cancelled\] Windows temporary files') 'admin category logged as Cancelled'
    Assert-That ($log -match 'UAC prompt was cancelled') 'reason logged'
    Assert-That ($log -match 'Overall status    : Completed with problems or cancellations') 'overall status honest'
}

Invoke-TestCase 'T40' 'Elevated argument line survives CMD parsing rules (no comma/semicolon/equals separators)' {
    $captured = $null
    $origSP = ${function:Start-Process}
    function global:Start-Process { param($FilePath, $ArgumentList, $Verb, [switch]$PassThru, [switch]$Wait, $ErrorAction) $script:captured = $ArgumentList; throw (New-Object ComponentModel.Win32Exception(1223)) }
    $savedSelf = $env:AIZNM_SELF
    $env:AIZNM_SELF = $BatPath
    try { $h = Invoke-ElevatedHelper 'clean' @('WinTemp', 'SystemDumps') }
    finally { Remove-Item function:\global:Start-Process -ErrorAction SilentlyContinue; $env:AIZNM_SELF = $savedSelf }
    Assert-That $h.Cancelled 'UAC cancel (error 1223) recognised'
    Assert-That ($script:captured -match '^--elevated clean "WinTemp\+SystemDumps" "[^"]+elevated-[0-9a-f]{32}\.json"$') ('argument line: ' + $script:captured)
    $unquoted = ($script:captured -replace '"[^"]*"', '')
    Assert-That ($unquoted -notmatch '[,;=]') 'no CMD separators outside quotes'
    function global:Start-Process { param($FilePath, $ArgumentList, $Verb, [switch]$PassThru, [switch]$Wait, $ErrorAction) throw (New-Object InvalidOperationException('The system cannot find the file specified')) }
    $env:AIZNM_SELF = $BatPath
    try { $h2 = Invoke-ElevatedHelper 'clean' @('WinTemp') }
    finally { Remove-Item function:\global:Start-Process -ErrorAction SilentlyContinue; $env:AIZNM_SELF = $savedSelf }
    Assert-That (-not $h2.Cancelled -and $h2.Error -match 'could not be started') 'other elevation failures are reported as failures, not cancellations'
}

Invoke-TestCase 'T41' 'Declining at the confirmation screen changes nothing' {
    New-TestFile (Join-Path $SB.Temp 'decline.tmp') 100 100
    $cats = @((Get-Category 'UserTemp'))
    $res = Invoke-ScanCategories $cats
    $sel = @{ UserTemp = $true }
    $origRC = ${function:Read-Choice}
    ${function:Read-Choice} = { param([string[]]$Valid, [switch]$AllowEnter, [switch]$AllowEscape) 'N' }
    try { $ids = Show-ConfirmScreen $cats $res $sel } finally { ${function:Read-Choice} = $origRC }
    Assert-Equal $null $ids 'nothing returned'
    Assert-That ([IO.File]::Exists((Join-Path $SB.Temp 'decline.tmp'))) 'file untouched'
}

Invoke-TestCase 'T42' 'Recycle Bin is dropped unless EMPTY is typed exactly' {
    $cats = @((Get-Category 'UserTemp'), (Get-Category 'RecycleBin'))
    $origRB = ${function:Get-RecycleBinInfo}
    ${function:Get-RecycleBinInfo} = { @{ Known = $true; Bytes = [long]1GB; Items = [long]3; Note = '' } }
    $origRC = ${function:Read-Choice}; $origRL = ${function:Read-LineSafe}
    try {
        $res = Invoke-ScanCategories $cats
        $sel = @{ UserTemp = $true; RecycleBin = $true }
        ${function:Read-Choice} = { param([string[]]$Valid, [switch]$AllowEnter, [switch]$AllowEscape) 'Y' }
        foreach ($typed in @('', 'empty', 'EMPTY ', 'yes', $null)) {
            ${function:Read-LineSafe} = [ScriptBlock]::Create("param(`$Prompt, `$MaxLength) " + $(if ($null -eq $typed) { '$null' } else { "'" + $typed + "'" }))
            $ids = @(Show-ConfirmScreen $cats $res $sel)
            Assert-That ($ids -notcontains 'RecycleBin') ("typed '{0}' must not include the Recycle Bin" -f $typed)
            Assert-That ($ids -contains 'UserTemp') 'other selection kept'
        }
        ${function:Read-LineSafe} = { param($Prompt, $MaxLength) 'EMPTY' }
        $ids = @(Show-ConfirmScreen $cats $res $sel)
        Assert-That ($ids -contains 'RecycleBin') 'exact EMPTY includes it'
    } finally { ${function:Read-Choice} = $origRC; ${function:Read-LineSafe} = $origRL; ${function:Get-RecycleBinInfo} = $origRB }
}

Invoke-TestCase 'T43' 'Unknown and partial sizes are shown as such, never as 0' {
    $r = New-CategoryResult (Get-Category 'WinTemp')
    $r.SizeState = 'Unknown'
    Assert-Equal 'unknown' (Get-SizeText $r) 'unknown'
    $r.SizeState = 'Partial'; $r.Stats.EligibleBytes = [long]2048
    Assert-Equal '>=2.00 KB' (Get-SizeText $r) 'partial lower bound'
    $r.Applicable = $false
    Assert-Equal '-' (Get-SizeText $r) 'not applicable'
    $dir = Join-Path $SB.LocalAppData 'Unreadable'
    [void][IO.Directory]::CreateDirectory($dir)
    $cat = @{ Id = 'U'; Name = 'Unreadable test'; Admin = $true; Group = 'Safe'; Handler = 'Walk'; Targets = { @(New-Spec 'Unreadable') } }
    $origWalk = ${function:Invoke-TargetWalk}
    ${function:Invoke-TargetWalk} = { param([hashtable]$Spec, [hashtable]$Stats, [switch]$Delete, [hashtable]$Exclusions, [string]$Label) $Stats.RootUnreadable = $true }
    try { $s = Invoke-CategoryScan $cat } finally { ${function:Invoke-TargetWalk} = $origWalk }
    Assert-Equal 'Unknown' $s.SizeState 'unreadable root -> Unknown'
    Assert-Equal 'needs admin to measure (R)' (Get-RowNote $cat $s) 'row note explains'
}

Invoke-TestCase 'T44' 'Report states honestly when free space went DOWN during cleanup' {
    $logDir = Join-Path $sandbox 'logs-report'
    [void][IO.Directory]::CreateDirectory($logDir)
    $null = Start-RunLog 'cleanup' $logDir
    $r = New-CategoryResult (Get-Category 'UserTemp')
    $r.Status = 'Completed'; $r.Stats.Deleted = 10; $r.Stats.DeletedBytes = [long]500MB
    $scan = @{ UserTemp = (New-CategoryResult (Get-Category 'UserTemp')) }
    $scan.UserTemp.Stats.EligibleBytes = [long]500MB
    $before = [ordered]@{ 'C:\' = @{ Root = 'C:\'; Free = [long]10GB; Total = [long]100GB; TotalFree = [long]10GB } }
    $after = [ordered]@{ 'C:\' = @{ Root = 'C:\'; Free = [long]9GB; Total = [long]100GB; TotalFree = [long]9GB } }
    Show-CleanupReport -Results @($r) -Before $before -After $after -Elapsed ([TimeSpan]::FromSeconds(3)) -ScanResults $scan -PendingBefore @{ Any = $false; Text = '' }
    $log = [IO.File]::ReadAllText($script:Log.Path)
    Assert-That ($log -match 'measured change -1073741824 bytes') 'negative change logged as negative'
    Assert-That ($log -match 'went DOWN') 'explanation given'
    Assert-That ($log -notmatch 'recovered') 'no claim of recovered space'
}

# ---------------------------------------------------------------- report
Restore-Overrides
$pass = @($script:TestResults | Where-Object { $_.Result -eq 'PASS' }).Count
$fail = @($script:TestResults | Where-Object { $_.Result -eq 'FAIL' }).Count
$skip = @($script:TestResults | Where-Object { $_.Result -eq 'SKIP' }).Count
Write-Host ''
Write-Host ('aiznm CLEANER test suite - {0} on PowerShell {1} ({2})' -f $(if ($onWin) { 'Windows' } else { [Environment]::OSVersion.Platform }), $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
Write-Host ('Sandbox: ' + $sandbox)
foreach ($t in $script:TestResults) {
    $c = 'Green'
    if ($t.Result -eq 'FAIL') { $c = 'Red' } elseif ($t.Result -eq 'SKIP') { $c = 'Yellow' }
    Write-Host ('  [{0}] {1} {2}' -f $t.Result, $t.Id, $t.Name) -ForegroundColor $c
    if ($t.Detail) { Write-Host ('         ' + $t.Detail) -ForegroundColor DarkGray }
}
Write-Host ('Total: {0} passed, {1} failed, {2} skipped' -f $pass, $fail, $skip)
if (-not $KeepSandbox) {
    # Remove only the sandbox this run created (exact generated name).
    if ((Split-Path -Leaf $sandbox) -match '^aiznm-test-[0-9a-f]{32}$') {
        Get-ChildItem -LiteralPath $sandbox -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue | ForEach-Object { try { [IO.Directory]::Delete($_.FullName) } catch { try { [IO.File]::Delete($_.FullName) } catch { } } }
        Get-ChildItem -LiteralPath $sandbox -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { try { $_.IsReadOnly = $false } catch { } }
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($fail -gt 0) { exit 1 } else { exit 0 }
