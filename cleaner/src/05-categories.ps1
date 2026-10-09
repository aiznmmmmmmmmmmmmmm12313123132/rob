
# -----------------------------------------------------------------------------
# 5a. Detection helpers used by categories (read-only)
# -----------------------------------------------------------------------------
$script:GpuCache = $null

function Get-NvidiaDisplayVersion {
    # Windows driver version 32.0.15.6094 -> NVIDIA version 560.94
    param([string]$WindowsVersion)
    if (-not $WindowsVersion) { return $null }
    $d = $WindowsVersion -replace '[^0-9]', ''
    if ($d.Length -lt 5) { return $null }
    $x = $d.Substring($d.Length - 5)
    return ('{0}.{1}' -f [int]$x.Substring(0, 3), $x.Substring(3))
}

function Get-GpuList {
    if ($null -ne $script:GpuCache) { return $script:GpuCache }
    $list = @()
    if ($script:OnWindows) {
        $vc = @()
        try { $vc = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop) } catch { }
        $regVram = @{}
        try {
            $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
            foreach ($k in @(Get-ChildItem -LiteralPath $classKey -ErrorAction Stop | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
                try {
                    $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop
                    $desc = $p.DriverDesc
                    $q = $p.'HardwareInformation.qwMemorySize'
                    if ($desc -and $q) { $regVram[[string]$desc] = [long]$q }
                } catch { }
            }
        } catch { }
        foreach ($v in $vc) {
            $pnp = [string]$v.PNPDeviceID
            $vendor = 'Other'
            if ($pnp -match 'VEN_10DE') { $vendor = 'NVIDIA' }
            elseif ($pnp -match 'VEN_1002') { $vendor = 'AMD' }
            elseif ($pnp -match 'VEN_8086') { $vendor = 'Intel' }
            $vram = $null
            if ($regVram.ContainsKey([string]$v.Name)) { $vram = $regVram[[string]$v.Name] }
            $nv = $null
            if ($vendor -eq 'NVIDIA') { $nv = Get-NvidiaDisplayVersion ([string]$v.DriverVersion) }
            $list += @{
                Name = [string]$v.Name; Vendor = $vendor; DriverVersion = [string]$v.DriverVersion
                DriverDate = $v.DriverDate; VramBytes = $vram; NvidiaVersion = $nv
                RefreshHz = $v.CurrentRefreshRate; Pnp = $pnp
            }
        }
    }
    $script:GpuCache = $list
    return $list
}

function Test-GpuVendor {
    param([string]$Vendor)
    foreach ($g in (Get-GpuList)) { if ($g.Vendor -eq $Vendor) { return $true } }
    return $false
}

$script:BrowserDefs = @(
    @{ Id = 'BrowserEdge';    Name = 'Microsoft Edge';  Process = 'msedge';  Kind = 'Chromium'; Segments = @('Microsoft', 'Edge', 'User Data') },
    @{ Id = 'BrowserChrome';  Name = 'Google Chrome';   Process = 'chrome';  Kind = 'Chromium'; Segments = @('Google', 'Chrome', 'User Data') },
    @{ Id = 'BrowserBrave';   Name = 'Brave';           Process = 'brave';   Kind = 'Chromium'; Segments = @('BraveSoftware', 'Brave-Browser', 'User Data') },
    @{ Id = 'BrowserVivaldi'; Name = 'Vivaldi';         Process = 'vivaldi'; Kind = 'Chromium'; Segments = @('Vivaldi', 'User Data') },
    # Opera keeps its profile (cookies, logins) under Roaming; the Local
    # folder below only holds its disk cache, and only "Cache" is cleaned.
    @{ Id = 'BrowserOpera';   Name = 'Opera';           Process = 'opera';   Kind = 'OperaLocal'; Segments = @('Opera Software', 'Opera Stable') },
    @{ Id = 'BrowserOperaGX'; Name = 'Opera GX';        Process = 'opera';   Kind = 'OperaLocal'; Segments = @('Opera Software', 'Opera GX Stable') },
    @{ Id = 'BrowserFirefox'; Name = 'Mozilla Firefox'; Process = 'firefox'; Kind = 'Firefox';  Segments = @('Mozilla', 'Firefox', 'Profiles') }
)

function Get-BrowserDef {
    param([string]$Id)
    foreach ($b in $script:BrowserDefs) { if ($b.Id -eq $Id) { return $b } }
    return $null
}

function Get-BrowserProfiles {
    # Finds profile folders without reading any browser data. Chromium
    # profiles are folders that contain a "Preferences" file; Firefox local
    # profile folders hold only caches (the real profile is under Roaming).
    param([hashtable]$Def, [hashtable]$AnchorsOverride = $null)
    $r = @{ Installed = $false; Root = $null; Profiles = @(); Reason = '' }
    $rootSpec = New-TargetSpec -AnchorName 'LocalAppData' -Segments $Def.Segments -Label $Def.Name -AnchorsOverride $AnchorsOverride
    $null = Test-TargetSpec $rootSpec
    if (-not $rootSpec.Valid) { $r.Reason = $rootSpec.Reason; return $r }
    if (-not $rootSpec.Exists) { $r.Reason = 'Not installed for this user (no profile data found).'; return $r }
    $r.Installed = $true
    $r.Root = $rootSpec.Path
    if ($Def.Kind -eq 'OperaLocal') { $r.Profiles = @('main'); return $r }
    try {
        foreach ($d in (New-Object IO.DirectoryInfo($rootSpec.Path)).GetDirectories()) {
            if (($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($d.Name -notmatch '^[A-Za-z0-9 ._-]{1,80}$') { continue }
            if ($Def.Kind -eq 'Chromium') {
                if (-not [IO.File]::Exists((Join-Path $d.FullName 'Preferences'))) { continue }
            }
            $r.Profiles += $d.Name
        }
    } catch { $r.Reason = 'Profile folders could not be listed: ' + (Get-InnerMessage $_.Exception) }
    if ($r.Profiles.Count -eq 0 -and -not $r.Reason) { $r.Reason = 'No browser profiles found.' }
    return $r
}

function Get-BrowserTargets {
    param([hashtable]$Def, [hashtable]$AnchorsOverride = $null)
    $info = Get-BrowserProfiles $Def $AnchorsOverride
    $specs = @()
    $folders = @('Cache', 'Code Cache', 'GPUCache')
    if ($Def.Kind -eq 'Firefox') { $folders = @('cache2', 'startupCache') }
    if ($Def.Kind -eq 'OperaLocal') {
        if ($info.Installed) { $specs += New-TargetSpec -AnchorName 'LocalAppData' -Segments ($Def.Segments + @('Cache')) -Label 'Cache' -Kind 'Tree' -Recurse $true -AnchorsOverride $AnchorsOverride }
        return $specs
    }
    foreach ($p in $info.Profiles) {
        foreach ($f in $folders) {
            $specs += New-TargetSpec -AnchorName 'LocalAppData' -Segments ($Def.Segments + @($p, $f)) -Label ("$p\$f") -Kind 'Tree' -Recurse $true -AnchorsOverride $AnchorsOverride
        }
    }
    return $specs
}

function Test-BrowserRunning {
    param([hashtable]$Def)
    return [bool](Get-Process -Name $Def.Process -ErrorAction SilentlyContinue)
}

function Get-DeliveryOptimizationInfo {
    $r = @{ Available = $false; SizeBytes = $null; Files = $null; Note = '' }
    if (-not $script:OnWindows) { $r.Note = 'Windows only.'; return $r }
    try { Import-Module -Name DeliveryOptimization -DisableNameChecking -ErrorAction Stop -WarningAction SilentlyContinue }
    catch { $r.Note = 'The Windows Delivery Optimization PowerShell module is not available.'; return $r }
    if (-not (Get-Command -Name 'Delete-DeliveryOptimizationCache' -ErrorAction SilentlyContinue)) {
        $r.Note = 'This Windows version does not provide Delete-DeliveryOptimizationCache. Use Disk Cleanup instead.'
        return $r
    }
    $r.Available = $true
    try {
        $snap = Get-DeliveryOptimizationPerfSnap -ErrorAction Stop -WarningAction SilentlyContinue
        if ($snap) {
            foreach ($n in @('CacheSizeBytes', 'CacheSize')) { if ($snap.PSObject.Properties[$n]) { $r.SizeBytes = [long]$snap.$n; break } }
            foreach ($n in @('FileCount', 'NumberOfFiles', 'Files')) { if ($snap.PSObject.Properties[$n]) { $r.Files = [long]$snap.$n; break } }
        }
        if ($null -eq $r.SizeBytes) { $r.Note = 'Windows did not report the cache size.' }
    } catch {
        $r.Note = 'Cache size could not be read (' + (Get-InnerMessage $_.Exception) + ').'
    }
    return $r
}

function Get-RecycleBinInfo {
    $r = @{ Known = $false; Bytes = $null; Items = $null; Note = '' }
    if (-not (Initialize-Native)) { $r.Note = 'Size unavailable (helper not loaded).'; return $r }
    try {
        $q = [AiznmNativeV3]::QueryRecycleBin([NullString]::Value)
        $r.Known = $true
        $r.Bytes = [long]$q[0]
        $r.Items = [long]$q[1]
    } catch { $r.Note = 'Size unavailable (' + (Get-InnerMessage $_.Exception) + ').' }
    return $r
}

function Get-CustomDumpLocations {
    # Reports (never cleans) dump folders configured away from the defaults.
    $notes = @()
    if (-not $script:OnWindows) { return $notes }
    $ld = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps' 'DumpFolder'
    if ($ld) {
        $exp = [Environment]::ExpandEnvironmentVariables([string]$ld)
        $def = Join-Path (Get-Anchors).LocalAppData.Path 'CrashDumps'
        if (-not (Test-SamePath (Get-NormalizedPath $exp) $def)) { $notes += "Custom application dump folder configured ($exp) - not cleaned; only the default folder is approved." }
    }
    $cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
    $df = Get-RegValue $cc 'DumpFile'
    if ($df) {
        $exp = [Environment]::ExpandEnvironmentVariables([string]$df)
        if (-not (Test-SamePath (Get-NormalizedPath $exp) (Join-Path (Get-Anchors).Windows.Path 'MEMORY.DMP'))) { $notes += "Custom system dump file configured ($exp) - not cleaned." }
    }
    $md = Get-RegValue $cc 'MinidumpDir'
    if ($md) {
        $exp = [Environment]::ExpandEnvironmentVariables([string]$md)
        if (-not (Test-SamePath (Get-NormalizedPath $exp) (Join-Path (Get-Anchors).Windows.Path 'Minidump'))) { $notes += "Custom minidump folder configured ($exp) - not cleaned." }
    }
    return $notes
}

# -----------------------------------------------------------------------------
# 5b. Category definitions. Each one says what it removes, why, the side
#     effects, whether it needs admin rights and whether it is preselected.
#     Paths are anchor + constant segments only.
# -----------------------------------------------------------------------------
$script:CategoryList = $null

function Get-Categories {
    if ($null -ne $script:CategoryList) { return $script:CategoryList }
    $list = New-Object 'System.Collections.Generic.List[hashtable]'

    $list.Add(@{
        Id = 'UserTemp'; Name = 'User temporary files'; Group = 'Safe'; Default = $true; Admin = $false; Risk = 'Low'; Irreversible = $false
        Removes = 'Files in your own Temp folder (%LOCALAPPDATA%\Temp) created and last changed more than 24 hours ago, plus folders left empty.'
        Why = 'Apps and installers often leave temporary files behind. Removing old ones is the standard low-risk way to recover space.'
        Side = 'None expected. Files from the last 24 hours, files that are in use and files queued by an installer for the next restart are kept.'
        Regenerates = 'Not needed (leftovers)'; CloseFirst = 'Nothing required'
        Handler = 'Walk'
        Targets = { @(New-TargetSpec -AnchorName 'Temp' -Segments @() -Label 'Temp folder' -Kind 'Tree' -MinAgeHours $script:Policy.UserTempMinAgeHours -RemoveEmptyDirs $true -KeepDirNames @('Low')) }
        Gate = { Get-InstallActivity }
    })
    $list.Add(@{
        Id = 'WinTemp'; Name = 'Windows temporary files'; Group = 'Safe'; Default = $true; Admin = $true; Risk = 'Low'; Irreversible = $false
        Removes = 'Files in %SystemRoot%\Temp that have not been created or changed for 7 days (the rule Microsoft documents for Disk Cleanup). Folders are left in place.'
        Why = 'Windows components and installers that run as SYSTEM leave files here.'
        Side = 'None expected. Skipped automatically while an installation or Windows servicing is running, or while a Windows Update restart is pending.'
        Regenerates = 'Not needed (leftovers)'; CloseFirst = 'Finish any installations first'
        Handler = 'Walk'
        Targets = { @(New-TargetSpec -AnchorName 'Windows' -Segments @('Temp') -Label 'Windows Temp' -Kind 'Tree' -MinAgeHours $script:Policy.WinTempMinAgeHours) }
        Gate = {
            $a = Get-InstallActivity
            if ($a) { $a } else {
                $pr = Get-PendingRebootInfo
                if ($pr.Any) { 'A Windows Update/servicing restart is pending. Restart first, then clean Windows Temp.' } else { $null }
            }
        }
    })
    $list.Add(@{
        Id = 'Thumbnails'; Name = 'Thumbnail cache'; Group = 'Safe'; Default = $false; Admin = $false; Risk = 'Low'; Irreversible = $false
        Removes = 'Explorer thumbnail databases (thumbcache_*.db) in %LOCALAPPDATA%\Microsoft\Windows\Explorer.'
        Why = 'They can grow large over time, and clearing them fixes wrong or stale thumbnails.'
        Side = 'Explorer rebuilds thumbnails as you open folders (briefly slower browsing). Explorer is never closed: if it has the cache open, the whole category is skipped so the cache stays consistent. Disk Cleanup has a supported "Thumbnails" option.'
        Regenerates = 'Yes, automatically'; CloseFirst = 'Nothing (Explorer is not closed)'
        Handler = 'Thumbnails'
        Targets = { @(New-TargetSpec -AnchorName 'LocalAppData' -Segments @('Microsoft', 'Windows', 'Explorer') -Label 'Explorer thumbnail cache' -Kind 'Files' -Recurse $false -NamePattern '^thumbcache_[A-Za-z0-9_]+\.db$') }
    })
    $list.Add(@{
        Id = 'DeliveryOpt'; Name = 'Delivery Optimization cache'; Group = 'Safe'; Default = $false; Admin = $true; Risk = 'Low'; Irreversible = $false
        Removes = 'Windows Update / Store download pieces that Windows keeps to share with other PCs. Removed with Windows'' own Delete-DeliveryOptimizationCache command (pinned content is kept); the cache folder is never deleted by hand.'
        Why = 'Frees that space immediately instead of waiting for Windows to expire it.'
        Side = 'Windows already clears this cache automatically, so this is rarely needed. Updates keep working; other PCs cannot fetch those pieces from you until they are downloaded again.'
        Regenerates = 'Only if updates are downloaded again'; CloseFirst = 'Nothing'
        Handler = 'DeliveryOpt'
        Targets = { @() }
    })
    foreach ($b in $script:BrowserDefs) {
        $bid = $b.Id
        $list.Add(@{
            Id = $bid; Name = ($b.Name + ' cache'); Group = 'Browser'; Default = $false; Admin = $false; Risk = 'Low'; Irreversible = $false
            Removes = $(switch ($b.Kind) {
                'Firefox'    { $b.Name + ' disk caches only: the "cache2" and "startupCache" folders of each local profile folder.' }
                'OperaLocal' { $b.Name + ' disk cache only: the "Cache" folder in %LOCALAPPDATA%\' + ($b.Segments -join '\') + '. The profile itself lives under Roaming and is never touched.' }
                default      { $b.Name + ' disk caches only: the "Cache", "Code Cache" and "GPUCache" folders of each profile.' }
            })
            Why = 'Browser caches can grow to hundreds of megabytes.'
            Side = 'Websites load a little slower until the cache refills. Cookies, passwords, history, bookmarks, sessions, extensions and website storage are NOT touched. Skipped while the browser is running - it is never closed for you.'
            Regenerates = 'Yes, as you browse'; CloseFirst = ($b.Name + ' (all windows)')
            Handler = 'Browser'; Browser = $bid
            Targets = [ScriptBlock]::Create("Get-BrowserTargets (Get-BrowserDef '$bid')")
        })
    }
    $list.Add(@{
        Id = 'ShaderDirectX'; Name = 'DirectX shader cache'; Group = 'Advanced'; Default = $false; Admin = $false; Risk = 'Medium'; Irreversible = $false
        Removes = 'Compiled shaders stored by Windows'' graphics system in %LOCALAPPDATA%\D3DSCache.'
        Why = 'Only worth clearing when it has become very large or a game shows graphics problems after a driver change.'
        Side = 'Games and apps must compile shaders again: first launches and first matches can stutter or load slower until the cache is rebuilt. This does NOT increase FPS. Skipped while a game is running.'
        Regenerates = 'Yes, while you play'; CloseFirst = 'All games and launchers'
        Handler = 'Walk'
        Targets = { @(New-TargetSpec -AnchorName 'LocalAppData' -Segments @('D3DSCache') -Label 'D3DSCache' -Kind 'Tree') }
        Gate = { $g = @(Get-RunningGames); if ($g.Count -gt 0) { 'A game is running (' + ($g -join ', ') + '). Close it and run this again.' } else { $null } }
    })
    $list.Add(@{
        Id = 'ShaderNvidia'; Name = 'NVIDIA shader cache'; Group = 'Advanced'; Default = $false; Admin = $false; Risk = 'Medium'; Irreversible = $false
        Removes = 'Shaders compiled by the NVIDIA driver: %LOCALAPPDATA%\NVIDIA\DXCache and \GLCache, and (newer drivers) %USERPROFILE%\AppData\LocalLow\NVIDIA\PerDriverVersion\DXCache and \GLCache.'
        Why = 'Useful after driver problems or if the cache has grown very large. Not routine maintenance.'
        Side = 'Games re-compile shaders: expect stutter or longer loading in the first sessions afterwards. This does NOT increase FPS. Skipped while a game is running.'
        Regenerates = 'Yes, while you play'; CloseFirst = 'All games and launchers'
        Handler = 'Walk'
        Check = { if (Test-GpuVendor 'NVIDIA') { $null } else { 'No NVIDIA graphics adapter detected.' } }
        Targets = { @(
            (New-TargetSpec -AnchorName 'LocalAppData' -Segments @('NVIDIA', 'DXCache') -Label 'NVIDIA DXCache' -Kind 'Tree'),
            (New-TargetSpec -AnchorName 'LocalAppData' -Segments @('NVIDIA', 'GLCache') -Label 'NVIDIA GLCache' -Kind 'Tree'),
            (New-TargetSpec -AnchorName 'LocalLow' -Segments @('NVIDIA', 'PerDriverVersion', 'DXCache') -Label 'NVIDIA PerDriverVersion DXCache' -Kind 'Tree'),
            (New-TargetSpec -AnchorName 'LocalLow' -Segments @('NVIDIA', 'PerDriverVersion', 'GLCache') -Label 'NVIDIA PerDriverVersion GLCache' -Kind 'Tree')) }
        Gate = { $g = @(Get-RunningGames); if ($g.Count -gt 0) { 'A game is running (' + ($g -join ', ') + '). Close it and run this again.' } else { $null } }
    })
    $list.Add(@{
        Id = 'ShaderAmd'; Name = 'AMD shader cache'; Group = 'Advanced'; Default = $false; Admin = $false; Risk = 'Medium'; Irreversible = $false
        Removes = 'Shaders compiled by the AMD driver in %LOCALAPPDATA%\AMD\DxCache, \DxcCache and \GLCache - only when an AMD graphics adapter is present.'
        Why = 'Same purpose as the NVIDIA cache, for AMD hardware. AMD Software also has its own "Reset Shader Cache" button.'
        Side = 'Games re-compile shaders: stutter or longer loading at first. This does NOT increase FPS. Never offered on a PC without an AMD adapter, even if the folder exists.'
        Regenerates = 'Yes, while you play'; CloseFirst = 'All games and launchers'
        Handler = 'Walk'
        Check = { if (Test-GpuVendor 'AMD') { $null } else { 'No AMD graphics adapter detected. Folder left untouched even if it exists.' } }
        Targets = { @(
            (New-TargetSpec -AnchorName 'LocalAppData' -Segments @('AMD', 'DxCache') -Label 'AMD DxCache' -Kind 'Tree'),
            (New-TargetSpec -AnchorName 'LocalAppData' -Segments @('AMD', 'DxcCache') -Label 'AMD DxcCache' -Kind 'Tree'),
            (New-TargetSpec -AnchorName 'LocalAppData' -Segments @('AMD', 'GLCache') -Label 'AMD GLCache' -Kind 'Tree')) }
        Gate = { $g = @(Get-RunningGames); if ($g.Count -gt 0) { 'A game is running (' + ($g -join ', ') + '). Close it and run this again.' } else { $null } }
    })
    $list.Add(@{
        Id = 'ShaderIntel'; Name = 'Intel graphics shader cache'; Group = 'Advanced'; Default = $false; Admin = $false; Risk = 'Medium'; Irreversible = $false
        Removes = 'Shaders compiled by the Intel graphics driver in %LOCALAPPDATA%\Intel\ShaderCache and %USERPROFILE%\AppData\LocalLow\Intel\ShaderCache - only when an Intel graphics adapter is present.'
        Why = 'Useful after an Intel graphics driver update or graphics glitches. Not routine maintenance.'
        Side = 'Games re-compile shaders: stutter or longer loading at first. This does NOT increase FPS. Never offered without an Intel graphics adapter.'
        Regenerates = 'Yes, while you play'; CloseFirst = 'All games and launchers'
        Handler = 'Walk'
        Check = { if (Test-GpuVendor 'Intel') { $null } else { 'No Intel graphics adapter detected. Folder left untouched even if it exists.' } }
        Targets = { @(
            (New-TargetSpec -AnchorName 'LocalAppData' -Segments @('Intel', 'ShaderCache') -Label 'Intel ShaderCache' -Kind 'Tree'),
            (New-TargetSpec -AnchorName 'LocalLow' -Segments @('Intel', 'ShaderCache') -Label 'Intel ShaderCache (LocalLow)' -Kind 'Tree')) }
        Gate = { $g = @(Get-RunningGames); if ($g.Count -gt 0) { 'A game is running (' + ($g -join ', ') + '). Close it and run this again.' } else { $null } }
    })
    $list.Add(@{
        Id = 'AppCrashDumps'; Name = 'App crash dumps (old)'; Group = 'Advanced'; Default = $false; Admin = $false; Risk = 'Medium'; Irreversible = $false
        Removes = ('*.dmp files in %LOCALAPPDATA%\CrashDumps older than {0} days (the default Windows Error Reporting local-dump folder).' -f $script:Policy.DumpMinAgeDays)
        Why = 'Windows keeps up to 10 application crash dumps here by default; old ones are rarely needed.'
        Side = 'Those older crashes can no longer be analysed. Recent dumps are kept. Dumps in game or app folders are never touched. Windows Error Reporting settings are not changed.'
        Regenerates = 'No (diagnostic data)'; CloseFirst = 'Nothing'
        Handler = 'Walk'
        Targets = { @(New-TargetSpec -AnchorName 'LocalAppData' -Segments @('CrashDumps') -Label 'CrashDumps' -Kind 'Files' -Recurse $false -NamePattern '\.dmp$' -MinAgeHours ($script:Policy.DumpMinAgeDays * 24)) }
    })
    $list.Add(@{
        Id = 'WerUser'; Name = 'Error reports - user (old)'; Group = 'Advanced'; Default = $false; Admin = $false; Risk = 'Low'; Irreversible = $false
        Removes = ('Windows Error Reporting report files older than {0} days in %LOCALAPPDATA%\Microsoft\Windows\WER\ReportArchive and \ReportQueue.' -f $script:Policy.DumpMinAgeDays)
        Why = 'Archived and queued problem reports accumulate over time.'
        Side = 'Old unsent reports are discarded. Reporting settings are not changed.'
        Regenerates = 'No (diagnostic data)'; CloseFirst = 'Nothing'
        Handler = 'Walk'
        Targets = { @(
            (New-TargetSpec -AnchorName 'LocalAppData' -Segments @('Microsoft', 'Windows', 'WER', 'ReportArchive') -Label 'WER ReportArchive (user)' -Kind 'Tree' -MinAgeHours ($script:Policy.DumpMinAgeDays * 24) -RemoveEmptyDirs $true),
            (New-TargetSpec -AnchorName 'LocalAppData' -Segments @('Microsoft', 'Windows', 'WER', 'ReportQueue') -Label 'WER ReportQueue (user)' -Kind 'Tree' -MinAgeHours ($script:Policy.DumpMinAgeDays * 24) -RemoveEmptyDirs $true)) }
    })
    $list.Add(@{
        Id = 'WerSystem'; Name = 'Error reports - system (old)'; Group = 'Advanced'; Default = $false; Admin = $true; Risk = 'Low'; Irreversible = $false
        Removes = ('System-wide Windows Error Reporting files older than {0} days in %ProgramData%\Microsoft\Windows\WER\ReportArchive and \ReportQueue.' -f $script:Policy.DumpMinAgeDays)
        Why = 'Reports from services and system components accumulate here.'
        Side = 'Old unsent reports are discarded. Reporting settings are not changed.'
        Regenerates = 'No (diagnostic data)'; CloseFirst = 'Nothing'
        Handler = 'Walk'
        Targets = { @(
            (New-TargetSpec -AnchorName 'ProgramData' -Segments @('Microsoft', 'Windows', 'WER', 'ReportArchive') -Label 'WER ReportArchive (system)' -Kind 'Tree' -MinAgeHours ($script:Policy.DumpMinAgeDays * 24) -RemoveEmptyDirs $true),
            (New-TargetSpec -AnchorName 'ProgramData' -Segments @('Microsoft', 'Windows', 'WER', 'ReportQueue') -Label 'WER ReportQueue (system)' -Kind 'Tree' -MinAgeHours ($script:Policy.DumpMinAgeDays * 24) -RemoveEmptyDirs $true)) }
    })
    $list.Add(@{
        Id = 'SystemDumps'; Name = 'System crash dumps (old)'; Group = 'Advanced'; Default = $false; Admin = $true; Risk = 'Medium'; Irreversible = $false
        Removes = ('Blue-screen and live kernel dumps older than {0} days in their default locations: %SystemRoot%\MEMORY.DMP, %SystemRoot%\Minidump\*.dmp and %SystemRoot%\LiveKernelReports\...\*.dmp.' -f $script:Policy.DumpMinAgeDays)
        Why = 'A full MEMORY.DMP or GPU timeout dump (LiveKernelReports\WATCHDOG) can use several GB.'
        Side = 'Evidence for those crashes or GPU/driver timeouts is lost. Keep them while you are troubleshooting. Custom dump locations are reported, never cleaned.'
        Regenerates = 'No (diagnostic data)'; CloseFirst = 'Nothing'
        Handler = 'Walk'
        Targets = { @(
            (New-TargetSpec -AnchorName 'Windows' -Segments @('MEMORY.DMP') -Label 'MEMORY.DMP' -Kind 'SingleFile' -MinAgeHours ($script:Policy.DumpMinAgeDays * 24)),
            (New-TargetSpec -AnchorName 'Windows' -Segments @('Minidump') -Label 'Minidump' -Kind 'Files' -Recurse $false -NamePattern '\.dmp$' -MinAgeHours ($script:Policy.DumpMinAgeDays * 24)),
            (New-TargetSpec -AnchorName 'Windows' -Segments @('LiveKernelReports') -Label 'LiveKernelReports' -Kind 'Files' -Recurse $true -NamePattern '\.dmp$' -MinAgeHours ($script:Policy.DumpMinAgeDays * 24))) }
    })
    $list.Add(@{
        Id = 'RecycleBin'; Name = 'Recycle Bin (permanent)'; Group = 'Advanced'; Default = $false; Admin = $false; Risk = 'High'; Irreversible = $true
        Removes = 'Everything currently in your Recycle Bin, on all drives.'
        Why = 'Deleted files keep using disk space until the Recycle Bin is emptied.'
        Side = 'PERMANENT: emptied items can no longer be restored from the Recycle Bin. Requires typing a confirmation word.'
        Regenerates = 'No'; CloseFirst = 'Nothing'
        Handler = 'RecycleBin'
        Targets = { @() }
    })
    $script:CategoryList = $list
    return $list
}

function Get-Category {
    param([string]$Id)
    foreach ($c in (Get-Categories)) { if ($c.Id -eq $Id) { return $c } }
    return $null
}

# -----------------------------------------------------------------------------
# 5c. Per-category scan and clean
# -----------------------------------------------------------------------------
function New-CategoryResult {
    param([hashtable]$Cat)
    return @{
        Id = $Cat.Id; Name = $Cat.Name; Admin = [bool]$Cat.Admin; Group = $Cat.Group
        Applicable = $true; Reason = ''; Targets = @(); Stats = (New-WalkStats)
        SizeState = 'Known'; Extra = @{}; Status = ''; Detail = ''; Notes = @()
        Phase = 'scan'; Elevated = (Test-IsAdmin)
    }
}

function Get-ResolvedTargets {
    param([hashtable]$Cat)
    $specs = @()
    try { $specs = @(& $Cat.Targets) } catch { $specs = @() }
    foreach ($s in $specs) { $null = Test-TargetSpec $s }
    return $specs
}

function Invoke-WalkTargets {
    param([hashtable]$Cat, [hashtable]$Result, [switch]$Delete, [hashtable]$Exclusions)
    $specs = Get-ResolvedTargets $Cat
    $anyReadable = $false
    foreach ($s in $specs) {
        $t = @{ Label = $s.Label; Path = $s.Path; State = 'OK'; Reason = $s.Reason; Bytes = $null; Files = $null }
        if (-not $s.Valid) { $t.State = 'Refused'; $Result.Notes += ($s.Label + ': ' + $s.Reason) }
        elseif (-not $s.Exists) { $t.State = 'Missing' }
        else {
            $st = New-WalkStats
            Invoke-TargetWalk -Spec $s -Stats $st -Delete:$Delete -Exclusions $Exclusions -Label $Cat.Name
            $t.Bytes = $st.EligibleBytes
            $t.Files = $st.EligibleFiles
            if ($st.RootUnreadable) { $t.State = 'Unreadable' } else { $anyReadable = $true }
            Merge-WalkStats $Result.Stats $st
            if ($st.Cancelled) { $Result.Targets += $t; break }
        }
        $Result.Targets += $t
    }
    Clear-ProgressLine
    $existing = @($Result.Targets | Where-Object { $_.State -ne 'Missing' -and $_.State -ne 'Refused' })
    $refused = @($Result.Targets | Where-Object { $_.State -eq 'Refused' })
    if ($Result.Targets.Count -gt 0 -and $existing.Count -eq 0 -and $refused.Count -eq 0) {
        $Result.Applicable = $false
        $Result.Reason = 'Location not present on this PC.'
    }
    elseif ($refused.Count -gt 0 -and $existing.Count -eq 0) {
        $Result.Applicable = $false
        $Result.Reason = 'Refused by safety checks: ' + $refused[0].Reason
        $Result.Extra.Refused = $true
    }
    if (@($Result.Targets | Where-Object { $_.State -eq 'Unreadable' }).Count -gt 0) {
        if ($anyReadable) { $Result.SizeState = 'Partial' } else { $Result.SizeState = 'Unknown' }
    }
    elseif ($Result.Stats.InaccessibleDirs -gt 0) { $Result.SizeState = 'Partial' }
}

function Invoke-CategoryScan {
    # Dry run: measures what WOULD be removed. Never deletes anything.
    param([hashtable]$Cat, [hashtable]$Exclusions = $null)
    $r = New-CategoryResult $Cat
    if ($Cat.ContainsKey('Check') -and $Cat.Check) {
        $why = & $Cat.Check
        if ($why) { $r.Applicable = $false; $r.Reason = [string]$why; $r.Status = 'Not applicable'; return $r }
    }
    switch ($Cat.Handler) {
        'DeliveryOpt' {
            $d = Get-DeliveryOptimizationInfo
            if (-not $d.Available) { $r.Applicable = $false; $r.Reason = $d.Note; break }
            if ($null -ne $d.SizeBytes) { $r.Stats.EligibleBytes = [long]$d.SizeBytes } else { $r.SizeState = 'Unknown' }
            if ($null -ne $d.Files) { $r.Stats.EligibleFiles = [long]$d.Files }
            if ($d.Note) { $r.Notes += $d.Note }
        }
        'RecycleBin' {
            $b = Get-RecycleBinInfo
            if ($b.Known) { $r.Stats.EligibleBytes = $b.Bytes; $r.Stats.EligibleFiles = $b.Items } else { $r.SizeState = 'Unknown'; $r.Notes += $b.Note }
        }
        'Browser' {
            $def = Get-BrowserDef $Cat.Browser
            $info = Get-BrowserProfiles $def
            if (-not $info.Installed) { $r.Applicable = $false; $r.Reason = $info.Reason; break }
            $r.Extra.Profiles = @($info.Profiles)
            $r.Extra.Running = (Test-BrowserRunning $def)
            Invoke-WalkTargets -Cat $Cat -Result $r -Exclusions $Exclusions
            if ($r.Extra.Running) { $r.Notes += ($def.Name + ' is running - it will be skipped unless you close it first.') }
        }
        default {
            Invoke-WalkTargets -Cat $Cat -Result $r -Exclusions $Exclusions
            if ($Cat.Id -eq 'SystemDumps' -or $Cat.Id -eq 'AppCrashDumps') { foreach ($n in (Get-CustomDumpLocations)) { $r.Notes += $n } }
        }
    }
    if (-not $r.Applicable) { $r.Status = 'Not applicable' }
    if ($r.Stats.Cancelled) { $r.Status = 'Cancelled' }
    return $r
}

function Invoke-CategoryClean {
    # Re-validates everything and applies the same rules as the scan, this
    # time deleting eligible files one by one.
    param([hashtable]$Cat, [hashtable]$Exclusions = $null)
    $r = New-CategoryResult $Cat
    $r.Phase = 'clean'
    if ($Cat.Admin -and -not (Test-IsAdmin)) { $r.Status = 'Skipped'; $r.Detail = 'Administrator rights are required.'; return $r }
    if ($Cat.ContainsKey('Check') -and $Cat.Check) {
        $why = & $Cat.Check
        if ($why) { $r.Status = 'Not applicable'; $r.Detail = [string]$why; return $r }
    }
    if ($Cat.ContainsKey('Gate') -and $Cat.Gate) {
        $why = & $Cat.Gate
        if ($why) { $r.Status = 'Skipped'; $r.Detail = [string]$why; return $r }
    }
    switch ($Cat.Handler) {
        'DeliveryOpt' {
            $before = Get-DeliveryOptimizationInfo
            if (-not $before.Available) { $r.Status = 'Not applicable'; $r.Detail = $before.Note; return $r }
            if ($null -ne $before.SizeBytes) { $r.Stats.EligibleBytes = [long]$before.SizeBytes }
            try {
                Delete-DeliveryOptimizationCache -Force -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
                $after = Get-DeliveryOptimizationInfo
                if ($null -ne $before.SizeBytes -and $null -ne $after.SizeBytes) {
                    $freed = [long]$before.SizeBytes - [long]$after.SizeBytes
                    if ($freed -lt 0) { $freed = 0 }
                    $r.Stats.DeletedBytes = $freed
                    $r.Status = 'Completed'
                    $r.Detail = 'Windows reports the cache went from {0} to {1}.' -f (Format-Bytes $before.SizeBytes), (Format-Bytes $after.SizeBytes)
                } else {
                    $r.Status = 'Completed'
                    $r.Detail = 'Windows accepted the request without error; the cache size could not be re-measured.'
                }
            } catch {
                $r.Status = 'Failed'
                $r.Detail = 'Delete-DeliveryOptimizationCache failed: ' + (Get-InnerMessage $_.Exception)
            }
            return $r
        }
        'RecycleBin' {
            $b = Get-RecycleBinInfo
            if ($b.Known -and $b.Items -eq 0) { $r.Status = 'Completed'; $r.Detail = 'The Recycle Bin was already empty.'; return $r }
            if ($b.Known) { $r.Stats.EligibleBytes = $b.Bytes; $r.Stats.EligibleFiles = $b.Items }
            try {
                Clear-RecycleBin -Force -ErrorAction Stop
            } catch {
                $msg = Get-InnerMessage $_.Exception
                $r.Notes += ('Clear-RecycleBin reported: ' + $msg)
            }
            $a = Get-RecycleBinInfo
            if ($a.Known -and $b.Known) {
                $r.Stats.DeletedBytes = [Math]::Max([long]0, [long]$b.Bytes - [long]$a.Bytes)
                $r.Stats.Deleted = [Math]::Max([long]0, [long]$b.Items - [long]$a.Items)
                if ($a.Items -eq 0) { $r.Status = 'Completed'; $r.Detail = 'The Recycle Bin is now empty (verified).' }
                elseif ($r.Stats.Deleted -gt 0) { $r.Status = 'Partially completed'; $r.Detail = ('{0} item(s) remain in the Recycle Bin.' -f $a.Items) }
                else { $r.Status = 'Failed'; $r.Detail = 'The Recycle Bin could not be emptied.' }
            } else {
                if ($r.Notes.Count -gt 0) { $r.Status = 'Failed'; $r.Detail = $r.Notes[0] }
                else { $r.Status = 'Completed'; $r.Detail = 'Windows reported no error; the result could not be verified.' }
            }
            return $r
        }
        'Thumbnails' {
            $s = @(Get-ResolvedTargets $Cat)[0]
            if (-not $s.Valid) { $r.Status = 'Failed'; $r.Detail = $s.Reason; return $r }
            if (-not $s.Exists) { $r.Status = 'Not applicable'; $r.Detail = 'No thumbnail cache folder.'; return $r }
            $locked = 0
            try {
                foreach ($f in (New-Object IO.DirectoryInfo($s.Path)).GetFiles()) {
                    if ($f.Name -notmatch $s.NamePattern) { continue }
                    try { $fs = [IO.File]::Open($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None); $fs.Dispose() }
                    catch { $locked++ }
                }
            } catch { $r.Status = 'Failed'; $r.Detail = 'Folder could not be read: ' + (Get-InnerMessage $_.Exception); return $r }
            if ($locked -gt 0) {
                $r.Status = 'Skipped'
                $r.Detail = ('Windows Explorer is using {0} thumbnail database file(s). Skipped as a whole so the cache stays consistent (Explorer is never closed). Use Disk Cleanup > Thumbnails, or try again after signing out and back in.' -f $locked)
                return $r
            }
            Invoke-WalkTargets -Cat $Cat -Result $r -Delete -Exclusions $Exclusions
        }
        'Browser' {
            $def = Get-BrowserDef $Cat.Browser
            if (Test-BrowserRunning $def) {
                $r.Status = 'Skipped'
                $r.Detail = $def.Name + ' is running. Close it completely and run this again (it is never closed for you).'
                if ($def.Process -eq 'msedge') { $r.Detail += ' Edge can stay open in the background (Startup boost / background extensions).' }
                return $r
            }
            $info = Get-BrowserProfiles $def
            if (-not $info.Installed) { $r.Status = 'Not applicable'; $r.Detail = $info.Reason; return $r }
            Invoke-WalkTargets -Cat $Cat -Result $r -Delete -Exclusions $Exclusions
        }
        default {
            Invoke-WalkTargets -Cat $Cat -Result $r -Delete -Exclusions $Exclusions
        }
    }
    if ($r.Extra.ContainsKey('Refused') -and $r.Extra.Refused) { $r.Status = 'Failed'; $r.Detail = $r.Reason; return $r }
    if (-not $r.Applicable) { $r.Status = 'Not applicable'; $r.Detail = $r.Reason; return $r }
    $r.Status = Get-CleanStatus $r.Stats
    $st = $r.Stats
    if ($st.EligibleFiles -eq 0 -and $r.Status -eq 'Completed') { $r.Detail = 'Nothing was old enough or eligible to delete.' }
    else {
        $bits = @(('{0} deleted ({1})' -f (Format-Count $st.Deleted), (Format-Bytes $st.DeletedBytes)))
        if ($st.RecentFiles -gt 0) { $bits += ('{0} recent kept' -f (Format-Count $st.RecentFiles)) }
        if ($st.InUse -gt 0) { $bits += ('{0} in use' -f (Format-Count $st.InUse)) }
        if ($st.Denied -gt 0) { $bits += ('{0} access denied' -f (Format-Count $st.Denied)) }
        if ($st.Other -gt 0) { $bits += ('{0} other errors' -f (Format-Count $st.Other)) }
        if ($st.Outside -gt 0) { $bits += ('{0} refused (outside folder)' -f (Format-Count $st.Outside)) }
        if ($st.InaccessibleDirs -gt 0) { $bits += ('{0} folders unreadable' -f (Format-Count $st.InaccessibleDirs)) }
        if ($st.PendingSkipped -gt 0) { $bits += ('{0} queued for restart kept' -f (Format-Count $st.PendingSkipped)) }
        if ($st.ReparseSkipped + $st.LinkSkipped -gt 0) { $bits += ('{0} links kept' -f (Format-Count ($st.ReparseSkipped + $st.LinkSkipped))) }
        $r.Detail = $bits -join ', '
    }
    return $r
}
