
# -----------------------------------------------------------------------------
# 2a. Trusted folder anchors
#     Every cleanup location is "anchor + fixed relative path written in this
#     file". An anchor is only trusted when the environment variable and the
#     Windows known-folder API agree. If they disagree, everything under that
#     anchor is refused instead of guessed.
# -----------------------------------------------------------------------------
$script:Anchors = $null

function Test-FullyQualifiedLocalPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path.IndexOfAny([char[]]@('*', '?', '"', '<', '>', '|')) -ge 0) { return $false }
    if ($Path.IndexOf([char]0) -ge 0) { return $false }
    if ($Path -match '(^|[\\/])\.\.([\\/]|$)') { return $false }
    if ($script:OnWindows) {
        if ($Path -notmatch '^[A-Za-z]:\\') { return $false }
        if ($Path.Substring(2).IndexOf(':') -ge 0) { return $false }   # no alternate data streams
        return $true
    }
    return $Path.StartsWith('/')
}

function Get-NormalizedPath {
    param([string]$Path)
    if (-not (Test-FullyQualifiedLocalPath $Path)) { return $null }
    try { $full = [IO.Path]::GetFullPath($Path) } catch { return $null }
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd([char[]]@('\', '/')) }
    return $full
}

function Get-PathDepth {
    param([string]$Path)
    $root = [IO.Path]::GetPathRoot($Path)
    $rest = $Path.Substring($root.Length)
    return @($rest.Split([char[]]@('\', '/')) | Where-Object { $_ -ne '' }).Count
}

function Test-PathUnder {
    # True when $Path is strictly inside $Root (never equal to it).
    param([string]$Path, [string]$Root)
    if (-not $Path -or -not $Root) { return $false }
    $r = $Root.TrimEnd([char[]]@('\', '/')) + $script:Sep
    return $Path.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)
}

function Test-SamePath {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    return [string]::Equals($A.TrimEnd([char[]]@('\', '/')), $B.TrimEnd([char[]]@('\', '/')), [StringComparison]::OrdinalIgnoreCase)
}

function New-Anchor {
    param([string]$Name, [string]$EnvName, [string]$EnvValue, [string]$ApiValue, [int]$MinDepth = 1)
    $a = @{ Name = $Name; Path = $null; Ok = $false; Reason = '' }
    $e = Get-NormalizedPath $EnvValue
    $p = Get-NormalizedPath $ApiValue
    if (-not $p) { $a.Reason = "Windows did not report a valid $Name folder."; return $a }
    if (-not $e) { $a.Reason = "Environment variable %$EnvName% is missing or not a full local path."; return $a }
    if (-not (Test-SamePath $e $p)) {
        $a.Reason = "%$EnvName% ($e) does not match the Windows known folder ($p). Refusing to guess."
        return $a
    }
    if ((Get-PathDepth $p) -lt $MinDepth) { $a.Reason = "$Name folder ($p) is unexpectedly close to the drive root."; return $a }
    $a.Path = $p
    $a.Ok = $true
    return $a
}

function Get-Anchors {
    if ($null -ne $script:Anchors) { return $script:Anchors }
    $an = @{}
    $an.LocalAppData = New-Anchor 'LocalAppData' 'LOCALAPPDATA' $env:LOCALAPPDATA ([Environment]::GetFolderPath('LocalApplicationData')) 3
    if ($an.LocalAppData.Ok) {
        $leaf = Split-Path -Leaf $an.LocalAppData.Path
        $parentLeaf = Split-Path -Leaf (Split-Path -Parent $an.LocalAppData.Path)
        if ($leaf -ne 'Local' -or $parentLeaf -ne 'AppData') {
            $an.LocalAppData.Ok = $false
            $an.LocalAppData.Reason = "LocalAppData ($($an.LocalAppData.Path)) is not the usual ...\AppData\Local folder."
        }
    }
    $an.UserProfile = New-Anchor 'UserProfile' 'USERPROFILE' $env:USERPROFILE ([Environment]::GetFolderPath('UserProfile')) 1
    $an.Windows     = New-Anchor 'Windows' 'SystemRoot' $env:SystemRoot ([Environment]::GetFolderPath('Windows')) 1
    if ($an.Windows.Ok -and $env:windir -and -not (Test-SamePath (Get-NormalizedPath $env:windir) $an.Windows.Path)) {
        $an.Windows.Ok = $false
        $an.Windows.Reason = "%windir% and %SystemRoot% point to different folders."
    }
    $an.ProgramData = New-Anchor 'ProgramData' 'ProgramData' $env:ProgramData ([Environment]::GetFolderPath('CommonApplicationData')) 1

    # LocalLow has no .NET known-folder value; derive it only when the
    # profile layout is the standard one.
    $an.LocalLow = @{ Name = 'LocalLow'; Path = $null; Ok = $false; Reason = 'User profile layout could not be confirmed.' }
    if ($an.LocalAppData.Ok -and $an.UserProfile.Ok) {
        $expected = Join-Path (Join-Path $an.UserProfile.Path 'AppData') 'Local'
        if (Test-SamePath $expected $an.LocalAppData.Path) {
            $an.LocalLow = @{ Name = 'LocalLow'; Path = (Join-Path (Join-Path $an.UserProfile.Path 'AppData') 'LocalLow'); Ok = $true; Reason = '' }
        }
    }

    # Temp: the folder apps really use (GetTempPath) must be %LOCALAPPDATA%\Temp
    # (or a numbered per-session subfolder of it) and must agree with %TEMP%.
    # The Temp folder is itself the cleanup target, so it is validated
    # against its parent anchor (LocalAppData) rather than against itself.
    $an.Temp = @{ Name = 'Temp'; Path = $null; Ok = $false; Reason = ''; Parent = 'LocalAppData' }
    if (-not $an.LocalAppData.Ok) { $an.Temp.Reason = 'LocalAppData could not be verified.' }
    else {
        $api = Get-NormalizedPath ([IO.Path]::GetTempPath())
        $envTemp = Get-NormalizedPath $env:TEMP
        $base = Join-Path $an.LocalAppData.Path 'Temp'
        if (-not $api) { $an.Temp.Reason = 'Windows did not report a valid temporary folder.' }
        elseif (-not $envTemp -or -not (Test-SamePath $api $envTemp)) { $an.Temp.Reason = "%TEMP% ($envTemp) differs from the folder Windows reports ($api)." }
        elseif ((Test-SamePath $api $base) -or ((Test-PathUnder $api $base) -and ((Split-Path -Leaf $api) -match '^\d{1,3}$') -and (Test-SamePath (Split-Path -Parent $api) $base))) {
            $an.Temp.Path = $api; $an.Temp.Ok = $true
        }
        else { $an.Temp.Reason = "Your temporary folder ($api) is not inside %LOCALAPPDATA%\Temp, so it is not an approved cleanup location." }
    }
    $script:Anchors = $an
    return $an
}

function Get-SystemDriveRoot {
    $an = Get-Anchors
    if ($an.Windows.Ok) { return [IO.Path]::GetPathRoot($an.Windows.Path) }
    if ($env:SystemDrive -match '^[A-Za-z]:$') { return ($env:SystemDrive + '\') }
    return $null
}

function Format-PathForLog {
    # Shortens personal paths in logs: C:\Users\name\AppData\Local -> %LOCALAPPDATA%
    param([string]$Path)
    if (-not $Path) { return $Path }
    $an = $script:Anchors
    if ($null -eq $an) { return $Path }
    foreach ($pair in @(@('LocalAppData', '%LOCALAPPDATA%'), @('LocalLow', '%USERPROFILE%\AppData\LocalLow'), @('UserProfile', '%USERPROFILE%'), @('ProgramData', '%ProgramData%'), @('Windows', '%SystemRoot%'))) {
        $a = $an[$pair[0]]
        if ($a -and $a.Ok -and $a.Path) {
            if (Test-SamePath $Path $a.Path) { return $pair[1] }
            if (Test-PathUnder $Path $a.Path) { return $pair[1] + $Path.Substring($a.Path.TrimEnd([char[]]@('\', '/')).Length) }
        }
    }
    return $Path
}

# -----------------------------------------------------------------------------
# 2b. Target specifications and validation
# -----------------------------------------------------------------------------
function New-TargetSpec {
    # Builds a cleanup target from an anchor name and constant path segments.
    param(
        [string]$AnchorName,
        [string[]]$Segments,
        [string]$Label,
        [ValidateSet('Tree', 'Files', 'SingleFile')][string]$Kind = 'Tree',
        [bool]$Recurse = $true,
        [string]$NamePattern = $null,
        [double]$MinAgeHours = 0,
        [bool]$RemoveEmptyDirs = $false,
        [string[]]$KeepDirNames = @(),
        [hashtable]$AnchorsOverride = $null
    )
    $an = $AnchorsOverride
    if ($null -eq $an) { $an = Get-Anchors }
    $anchor = $an[$AnchorName]
    $spec = @{
        Label = $Label; AnchorName = $AnchorName; Anchor = $null; Path = $null
        Kind = $Kind; Recurse = $Recurse; NamePattern = $NamePattern; MinAgeHours = $MinAgeHours
        RemoveEmptyDirs = $RemoveEmptyDirs; KeepDirNames = $KeepDirNames
        Valid = $false; Exists = $false; Reason = ''
    }
    if ($null -eq $anchor -or -not $anchor.Ok) {
        $why = 'unknown anchor'
        if ($anchor) { $why = $anchor.Reason }
        $spec.Reason = "Refused: $why"
        return $spec
    }
    $spec.Anchor = $anchor.Path
    $p = $anchor.Path
    if (@($Segments).Count -eq 0) {
        # Target is the anchor folder itself (only allowed for anchors that
        # declare a verified parent, e.g. Temp under LocalAppData).
        $parentName = $null
        if ($anchor.ContainsKey('Parent')) { $parentName = $anchor['Parent'] }
        $parent = $null
        if ($parentName) { $parent = $an[$parentName] }
        if ($null -eq $parent -or -not $parent.Ok) {
            $spec.Reason = 'Refused: the folder has no verified parent folder.'
            return $spec
        }
        $spec.Anchor = $parent.Path
        $spec.Path = $anchor.Path
        return $spec
    }
    foreach ($s in $Segments) {
        if ([string]::IsNullOrWhiteSpace($s) -or $s -match '[\\/:*?"<>|]' -or $s -eq '.' -or $s -eq '..') {
            $spec.Reason = 'Refused: invalid path segment in definition.'
            return $spec
        }
        $p = Join-Path $p $s
    }
    $spec.Path = $p
    return $spec
}

function Test-TargetSpec {
    # Full safety validation. Sets Valid / Exists / Reason on the spec and
    # returns it. A target that cannot be proven safe is refused.
    param([hashtable]$Spec)
    $Spec.Valid = $false
    $Spec.Exists = $false
    if ($Spec.Reason -like 'Refused*') { return $Spec }
    $anchor = Get-NormalizedPath $Spec.Anchor
    $path = Get-NormalizedPath $Spec.Path
    if (-not $anchor) { $Spec.Reason = 'Refused: the trusted base folder is not a valid local path.'; return $Spec }
    if (-not $path) { $Spec.Reason = 'Refused: target is empty, relative, contains wildcards or is not a local path.'; return $Spec }
    $root = [IO.Path]::GetPathRoot($path)
    if (Test-SamePath $path $root) { $Spec.Reason = 'Refused: target is a drive root.'; return $Spec }
    if ((Get-PathDepth $path) -lt 2) { $Spec.Reason = 'Refused: target is too close to the drive root.'; return $Spec }
    if (-not (Test-PathUnder $path $anchor)) { $Spec.Reason = 'Refused: target is outside its trusted base folder.'; return $Spec }
    $Spec.Path = $path
    $Spec.Anchor = $anchor

    # Walk from the anchor down to the target. No component below the anchor
    # may be a junction, symbolic link or other reparse point.
    $rel = $path.Substring($anchor.Length).TrimStart([char[]]@('\', '/'))
    $cur = $anchor
    $parts = @($rel.Split([char[]]@('\', '/')) | Where-Object { $_ -ne '' })
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $cur = Join-Path $cur $parts[$i]
        $isLast = ($i -eq $parts.Count - 1)
        try {
            if ($isLast -and $Spec.Kind -eq 'SingleFile') { $item = New-Object IO.FileInfo($cur) }
            else { $item = New-Object IO.DirectoryInfo($cur) }
            $item.Refresh()
            if (-not $item.Exists) {
                $Spec.Valid = $true
                $Spec.Reason = 'Location does not exist (nothing to do).'
                return $Spec
            }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $Spec.Reason = "Refused: '$($parts[$i])' is a junction or symbolic link; it will not be followed."
                return $Spec
            }
        }
        catch {
            $Spec.Reason = 'Refused: could not inspect the location (' + $_.Exception.Message + ').'
            return $Spec
        }
    }
    $Spec.Valid = $true
    $Spec.Exists = $true
    $Spec.Reason = ''
    return $Spec
}

# -----------------------------------------------------------------------------
# 2c. Logging. One text log per run under %LOCALAPPDATA%\aiznm_CLEANER\Logs.
#     Logs contain counts, sizes, statuses and a few example paths per error
#     type (personal folders shortened to %LOCALAPPDATA% etc.). They never
#     contain file contents, cookies, passwords or full file lists.
# -----------------------------------------------------------------------------
$script:Log = @{ Path = $null; Enabled = $false; Failed = $false; LastError = $null; Dir = $null }
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-AppDataDir {
    param([string]$Child)
    $an = Get-Anchors
    if (-not $an.LocalAppData.Ok) { return $null }
    $base = Join-Path $an.LocalAppData.Path 'aiznm_CLEANER'
    if ($Child) { return (Join-Path $base $Child) }
    return $base
}

function Initialize-AppDir {
    # Creates (if needed) and returns one of our own folders, refusing
    # junctions so nothing we write can be redirected elsewhere.
    param([string]$Child)
    $dir = Get-AppDataDir $Child
    if (-not $dir) { return $null }
    try {
        foreach ($d in @((Split-Path -Parent $dir), $dir)) {
            if (-not [IO.Directory]::Exists($d)) { [void][IO.Directory]::CreateDirectory($d) }
            $di = New-Object IO.DirectoryInfo($d)
            if (($di.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
        }
        return $dir
    } catch { return $null }
}

function Start-RunLog {
    param([string]$Kind, [string]$Directory = $null)
    $script:Log = @{ Path = $null; Enabled = $false; Failed = $false; LastError = $null; Dir = $null }
    if (-not $Directory) { $Directory = Initialize-AppDir 'Logs' }
    if (-not $Directory) {
        $script:Log.Failed = $true
        $script:Log.LastError = 'The log folder could not be created under %LOCALAPPDATA%\aiznm_CLEANER.'
        return $false
    }
    $script:Log.Dir = $Directory
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    try {
        $path = $null
        for ($n = 1; $n -le 9 -and -not $path; $n++) {
            $suffix = ''
            if ($n -gt 1) { $suffix = [string]$n }
            $candidate = Join-Path $Directory ('aiznm_{0}_{1}{2}.log' -f $stamp, $Kind, $suffix)
            if ([IO.File]::Exists($candidate)) { continue }
            $fs = New-Object IO.FileStream($candidate, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $fs.Dispose()
            $path = $candidate
        }
        if (-not $path) { throw 'A unique log file name could not be created.' }
        $script:Log.Path = $path
        $script:Log.Enabled = $true
        Write-RunLog ('{0} {1} - {2} report' -f $script:AppName, $script:AppVersion, $Kind)
        Write-RunLog ('Started      : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
        return $true
    } catch {
        $script:Log.Failed = $true
        $script:Log.LastError = $_.Exception.Message
        return $false
    }
}

function Write-RunLog {
    param([string]$Line = '')
    if (-not $script:Log.Enabled) { return }
    try { [IO.File]::AppendAllText($script:Log.Path, $Line + "`r`n", $script:Utf8NoBom) }
    catch {
        $script:Log.Enabled = $false
        $script:Log.Failed = $true
        $script:Log.LastError = $_.Exception.Message
    }
}

function Write-LogSection {
    param([string]$Title)
    Write-RunLog ''
    Write-RunLog ('---- ' + $Title + ' ' + ('-' * [Math]::Max(3, 70 - $Title.Length)))
}

function Invoke-LogRetention {
    # Removes only our own old log files (exact name pattern, our folder only,
    # never recursive). Keeps the newest LogKeepCount and anything younger
    # than LogKeepDays.
    param([string]$Directory = $null, [int]$KeepCount = $script:Policy.LogKeepCount, [int]$KeepDays = $script:Policy.LogKeepDays)
    if (-not $Directory) { $Directory = Get-AppDataDir 'Logs' }
    $removed = 0
    if (-not $Directory -or -not [IO.Directory]::Exists($Directory)) { return $removed }
    try {
        $di = New-Object IO.DirectoryInfo($Directory)
        if (($di.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $removed }
        $logs = @($di.GetFiles() | Where-Object { $_.Name -match '^aiznm_\d{8}_\d{6}_[a-z]+\d?\.log$' -and (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) } | Sort-Object LastWriteTimeUtc -Descending)
        $cutoff = [DateTime]::UtcNow.AddDays(-$KeepDays)
        for ($i = 0; $i -lt $logs.Count; $i++) {
            if ($i -ge $KeepCount -or $logs[$i].LastWriteTimeUtc -lt $cutoff) {
                try { $logs[$i].Delete(); $removed++ } catch { }
            }
        }
    } catch { }
    # Leftover elevated-result files from interrupted runs (older than 1 day).
    $ex = Get-AppDataDir 'Exchange'
    if ($ex -and [IO.Directory]::Exists($ex)) {
        try {
            $old = [DateTime]::UtcNow.AddDays(-1)
            foreach ($f in (New-Object IO.DirectoryInfo($ex)).GetFiles()) {
                if ($f.Name -match '^elevated-[0-9a-f]{32}\.json$' -and $f.LastWriteTimeUtc -lt $old) { try { $f.Delete() } catch { } }
            }
        } catch { }
    }
    return $removed
}

# -----------------------------------------------------------------------------
# 2d. Environment facts and safety gates (all read-only)
# -----------------------------------------------------------------------------
function Test-IsAdmin {
    if (-not $script:OnWindows) { return $false }
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch { return $null }
}

function Get-OsInfo {
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $o = @{
        ProductName = Get-RegValue $k 'ProductName'
        DisplayVersion = Get-RegValue $k 'DisplayVersion'
        ReleaseId = Get-RegValue $k 'ReleaseId'
        Build = Get-RegValue $k 'CurrentBuild'
        Ubr = Get-RegValue $k 'UBR'
        Edition = Get-RegValue $k 'EditionID'
        Is64 = [Environment]::Is64BitOperatingSystem
    }
    $ver = $o.DisplayVersion
    if (-not $ver) { $ver = $o.ReleaseId }
    $o.Version = $ver
    $o.BuildText = '{0}.{1}' -f $o.Build, $o.Ubr
    $o.IsWin11 = $false
    try { if ([int]$o.Build -ge 22000) { $o.IsWin11 = $true } } catch { }
    $name = $o.ProductName
    if ($o.IsWin11 -and $name) { $name = $name -replace 'Windows 10', 'Windows 11' }
    $o.Text = '{0} {1} (build {2})' -f $name, $ver, $o.BuildText
    return $o
}

function Get-PendingRebootInfo {
    $r = @{ Servicing = $false; WindowsUpdate = $false; FileRenames = 0; Any = $false; Text = 'No restart pending' }
    if (-not $script:OnWindows) { return $r }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $r.Servicing = $true }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $r.WindowsUpdate = $true }
    $p = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations'
    if ($p) { $r.FileRenames = [int][Math]::Floor(@($p | Where-Object { $_ }).Count / 2) }
    $parts = @()
    if ($r.WindowsUpdate) { $parts += 'Windows Update' }
    if ($r.Servicing) { $parts += 'Windows servicing' }
    if ($parts.Count -gt 0) { $r.Any = $true; $r.Text = 'Restart pending (' + ($parts -join ', ') + ')' }
    elseif ($r.FileRenames -gt 0) { $r.Text = "No Windows Update restart pending ($($r.FileRenames) file operation(s) queued for next restart by installers)" }
    return $r
}

function Get-PendingRenameExclusions {
    # Files that installers asked Windows to replace/delete at the next
    # restart (MoveFileEx MOVEFILE_DELAY_UNTIL_REBOOT). These are never touched.
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $list = New-Object 'System.Collections.Generic.List[string]'
    if ($script:OnWindows) {
        foreach ($name in @('PendingFileRenameOperations', 'PendingFileRenameOperations2')) {
            $v = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' $name
            foreach ($entry in @($v)) {
                if (-not $entry) { continue }
                $p = ([string]$entry) -replace '^!', '' -replace '^\\\?\?\\', ''
                $n = Get-NormalizedPath $p
                if ($n -and $set.Add($n)) { $list.Add($n) }
            }
        }
    }
    return @{ Set = $set; List = $list }
}

function Test-Excluded {
    param([string]$Path, [hashtable]$Exclusions)
    if ($null -eq $Exclusions -or $Exclusions.List.Count -eq 0) { return $false }
    if ($Exclusions.Set.Contains($Path)) { return $true }
    foreach ($e in $Exclusions.List) { if (Test-PathUnder $Path $e) { return $true } }
    return $false
}

function Get-InstallActivity {
    # Returns a reason string when an installation or Windows servicing is
    # running right now, otherwise $null. Temp folders are left alone then.
    if (-not $script:OnWindows) { return $null }
    try {
        $m = $null
        if ([System.Threading.Mutex]::TryOpenExisting('Global\_MSIExecute', [ref]$m)) {
            if ($m) { $m.Dispose() }
            return 'A Windows Installer (MSI) installation is running.'
        }
    } catch [System.UnauthorizedAccessException] {
        return 'A Windows Installer (MSI) installation is running.'
    } catch { }
    $names = @('TiWorker', 'TrustedInstaller', 'wusa', 'SetupHost')
    foreach ($n in $names) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) {
            return "Windows servicing/setup is active ($n.exe is running)."
        }
    }
    return $null
}

function Get-ProcessNameSet {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try { foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) { [void]$set.Add($p.ProcessName) } } catch { }
    return $set
}

$script:KnownGameProcesses = @(
    'VALORANT-Win64-Shipping', 'VALORANT', 'cs2', 'csgo', 'FortniteClient-Win64-Shipping', 'r5apex', 'r5apex_dx12',
    'RobloxPlayerBeta', 'Overwatch', 'GTA5', 'GTA5_Enhanced', 'eldenring', 'RainbowSix', 'RainbowSix_Vulkan',
    'cod', 'ModernWarfare', 'BlackOps6', 'Minecraft.Windows', 'League of Legends',
    'dota2', 'RocketLeague', 'destiny2', 'TslGame', 'MarvelRivals-Win64-Shipping', 'FragPunk', 'deadlock', 'project8'
)

function Get-RunningGames {
    $set = Get-ProcessNameSet
    $found = @()
    foreach ($g in $script:KnownGameProcesses) { if ($set.Contains($g)) { $found += $g } }
    # Steam publishes the running game's app id here (0 = none).
    $sid = Get-RegValue 'HKCU:\Software\Valve\Steam' 'RunningAppID'
    if ($sid -and [int]$sid -ne 0) { $found += "Steam game (app $sid)" }
    return $found
}
