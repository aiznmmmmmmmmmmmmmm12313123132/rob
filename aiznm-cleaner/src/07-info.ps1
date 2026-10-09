
# -----------------------------------------------------------------------------
# 7a. System overview (read-only). Compares what Windows reports with the
#     documented baseline for this PC. Nothing here changes any setting.
# -----------------------------------------------------------------------------
function Get-CimSafe {
    param([string]$Class, [string]$Namespace = 'root\cimv2', [string]$Filter = $null)
    try {
        if ($Filter) { return @(Get-CimInstance -Namespace $Namespace -ClassName $Class -Filter $Filter -ErrorAction Stop) }
        return @(Get-CimInstance -Namespace $Namespace -ClassName $Class -ErrorAction Stop)
    } catch { return @() }
}

function Convert-WmiString {
    param([object]$Codes)
    if (-not $Codes) { return '' }
    return (-join (@($Codes) | Where-Object { $_ -ne 0 } | ForEach-Object { [char][int]$_ })).Trim()
}

function Get-DisplayFacts {
    $list = @()
    if (Initialize-Native) {
        try {
            foreach ($d in [AiznmNativeV3]::GetDisplays()) {
                $list += @{ Device = $d.Device; Monitor = $d.Monitor; MonitorId = $d.MonitorId; Primary = $d.Primary; Width = $d.Width; Height = $d.Height; Hz = $d.Hz; MaxHz = $d.MaxHzAtCurrent; Name = $null }
            }
        } catch { }
    }
    foreach ($m in (Get-CimSafe -Namespace 'root\wmi' -Class 'WmiMonitorID')) {
        $name = (Convert-WmiString $m.ManufacturerName) + ' ' + (Convert-WmiString $m.UserFriendlyName)
        $key = (([string]$m.InstanceName) -replace '_\d+$', '') -replace '\\', '#'
        foreach ($d in $list) {
            if ($d.MonitorId -and $key -and $d.MonitorId.IndexOf($key, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $d.Name = $name.Trim() }
        }
    }
    return $list
}

function Get-PowerPlanName {
    try {
        $exe = Join-Path (Get-Anchors).Windows.Path 'System32\powercfg.exe'
        $out = & $exe /getactivescheme 2>$null
        if ("$out" -match '\(([^)]+)\)\s*$') { return $Matches[1] }
    } catch { }
    return 'unknown'
}

function Get-HardwareFacts {
    $f = @{
        CpuName = $null; Cores = $null; Threads = $null; BaseMHz = $null; BoardMaker = $null; Board = $null
        BiosVersion = $null; BiosDate = $null; SmbiosSpec = $null; MemTotal = $null; MemSticks = $null
        MemParts = @(); MemMaker = @(); MemRated = $null; MemConfigured = $null; Uptime = $null
        Gpus = @(); Displays = @(); SecureBoot = $null; PowerPlan = 'unknown'
        Battery = $null; MemTotalKB = $null; MemFreeKB = $null
    }
    $cpu = @(Get-CimSafe 'Win32_Processor')
    if ($cpu.Count -gt 0) {
        $f.CpuName = (([string]$cpu[0].Name) -replace '\s+', ' ').Trim()
        $f.Cores = $cpu[0].NumberOfCores; $f.Threads = $cpu[0].NumberOfLogicalProcessors; $f.BaseMHz = $cpu[0].MaxClockSpeed
    }
    $bb = @(Get-CimSafe 'Win32_BaseBoard')
    if ($bb.Count -gt 0) { $f.BoardMaker = ([string]$bb[0].Manufacturer).Trim(); $f.Board = ([string]$bb[0].Product).Trim() }
    $bios = @(Get-CimSafe 'Win32_BIOS')
    if ($bios.Count -gt 0) {
        $f.BiosVersion = ([string]$bios[0].SMBIOSBIOSVersion).Trim()
        $f.BiosDate = $bios[0].ReleaseDate
        $f.SmbiosSpec = '{0}.{1}' -f $bios[0].SMBIOSMajorVersion, $bios[0].SMBIOSMinorVersion
    }
    $mem = @(Get-CimSafe 'Win32_PhysicalMemory')
    if ($mem.Count -gt 0) {
        $f.MemTotal = [long]0
        foreach ($m in $mem) { $f.MemTotal += [long]$m.Capacity }
        $f.MemSticks = $mem.Count
        $f.MemParts = @($mem | ForEach-Object { ([string]$_.PartNumber).Trim() } | Where-Object { $_ } | Select-Object -Unique)
        $f.MemMaker = @($mem | ForEach-Object { ([string]$_.Manufacturer).Trim() } | Where-Object { $_ } | Select-Object -Unique)
        $f.MemRated = ($mem | Measure-Object -Property Speed -Maximum).Maximum
        $f.MemConfigured = $null
        try { $f.MemConfigured = ($mem | Measure-Object -Property ConfiguredClockSpeed -Maximum).Maximum } catch { }
    }
    $os = @(Get-CimSafe 'Win32_OperatingSystem')
    if ($os.Count -gt 0 -and $os[0].LastBootUpTime) { $f.Uptime = (Get-Date) - $os[0].LastBootUpTime }
    if ($os.Count -gt 0) { $f.MemTotalKB = $os[0].TotalVisibleMemorySize; $f.MemFreeKB = $os[0].FreePhysicalMemory }
    $bat = @(Get-CimSafe 'Win32_Battery')
    if ($bat.Count -gt 0) {
        $state = 'on battery'
        switch ([int]$bat[0].BatteryStatus) { 2 { $state = 'plugged in' } 3 { $state = 'fully charged' } 6 { $state = 'charging' } 7 { $state = 'charging' } 8 { $state = 'charging' } 9 { $state = 'charging' } }
        $f.Battery = '{0}% ({1})' -f $bat[0].EstimatedChargeRemaining, $state
    }
    $f.Gpus = @(Get-GpuList)
    $f.Displays = @(Get-DisplayFacts)
    $f.SecureBoot = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
    $f.PowerPlan = Get-PowerPlanName
    return $f
}

function Get-BaselineRows {
    # PERSONAL edition: documented baseline for one PC, compared with what
    # Windows reports. Status: Matches / Differs / Not detected.
    param([hashtable]$F, [hashtable]$Os, [hashtable]$B)
    $rows = @()
    $det = 'not detected'; $st = 'Not detected'
    if ($F.CpuName) {
        $det = '{0} ({1}C/{2}T)' -f $F.CpuName, $F.Cores, $F.Threads
        if ($F.CpuName -match $B.CpuMatch -and [int]$F.Cores -eq $B.Cores -and [int]$F.Threads -eq $B.Threads) { $st = 'Matches' } else { $st = 'Differs' }
    }
    $rows += , @('CPU', $B.CpuText, $det, $st)
    $det = 'not detected'; $st = 'Not detected'
    if ($F.Board) { $det = ('{0} {1}' -f $F.BoardMaker, $F.Board).Trim(); if ($F.Board -match $B.BoardMatch) { $st = 'Matches' } else { $st = 'Differs' } }
    $rows += , @('Motherboard', $B.BoardText, $det, $st)
    $det = 'not detected'; $st = 'Not detected'
    if ($F.BiosVersion) {
        $det = $F.BiosVersion + (Format-BiosDate $F.BiosDate)
        if ($F.BiosVersion -eq $B.BiosVersion) { $st = 'Matches' } else { $st = 'Differs' }
    }
    $rows += , @('BIOS', $B.BiosText, $det, $st)
    $det = 'not detected'; $st = 'Not detected'
    if ($F.MemTotal) {
        $det = Format-MemoryText $F
        $partOk = (@($F.MemParts | Where-Object { $_ -match $B.MemPart }).Count -gt 0)
        if ([long]$F.MemTotal -eq [long]$B.MemTotal -and [int]$F.MemSticks -eq $B.MemSticks -and $partOk) {
            $st = 'Matches'
            if ($F.MemConfigured -and [int]$F.MemConfigured -lt ($B.MemSpeed - 100)) { $st = 'Differs (XMP off?)' }
        } else { $st = 'Differs' }
    }
    $rows += , @('Memory', $B.MemText, $det, $st)
    $det = 'not detected'; $st = 'Not detected'
    if ($F.Gpus.Count -gt 0) {
        $g = $F.Gpus[0]
        $nv = @($F.Gpus | Where-Object { $_.Name -match $B.GpuMatch })
        if ($nv.Count -gt 0) { $g = $nv[0] }
        $det = Format-GpuText $g
        if ($g.Name -match $B.GpuMatch) { $st = 'Matches' } else { $st = 'Differs' }
    }
    $rows += , @('Graphics', $B.GpuText, $det, $st)
    $det = $Os.Text; $st = 'Differs'
    if ([string]$Os.Build -eq $B.OsBuild) {
        $st = 'Matches'
        try { if ([int]$Os.Ubr -gt $B.OsUbr) { $st = 'Matches (newer update)' } } catch { }
    }
    $rows += , @('Windows', $B.OsText, $det, $st)
    $det = 'unknown'; $st = 'Not detected'
    if ($null -ne $F.SecureBoot) { if ([int]$F.SecureBoot -eq 1) { $det = 'On'; $st = 'Matches' } else { $det = 'Off'; $st = 'Differs' } }
    $rows += , @('Secure Boot', 'Enabled', $det, $st)
    return $rows
}

function Format-BiosDate {
    param([object]$Date)
    if (-not $Date) { return '' }
    try {
        $d = [DateTime]$Date
        $years = [Math]::Floor(((Get-Date) - $d).TotalDays / 365.25)
        $age = ''
        if ($years -ge 1) { $age = ', {0} year(s) old' -f $years }
        return (' (' + $d.ToString('yyyy-MM-dd') + $age + ')')
    } catch { return '' }
}

function Format-MemoryText {
    param([hashtable]$F)
    $cfg = 'unknown speed'
    if ($F.MemConfigured) { $cfg = '{0} MT/s' -f $F.MemConfigured }
    $per = ''
    if ([int]$F.MemSticks -gt 0) { $per = ' ({0} x {1})' -f $F.MemSticks, (Format-Bytes ([long]$F.MemTotal / [int]$F.MemSticks)) }
    $part = ($F.MemParts -join '/')
    if ($part) { $part = ' ' + $part }
    $rated = ''
    if ($F.MemRated) { $rated = ', module rating {0}' -f $F.MemRated }
    return ('{0}{1}{2} @ {3}{4}' -f (Format-Bytes $F.MemTotal), $per, $part, $cfg, $rated)
}

function Format-GpuText {
    param([hashtable]$G)
    $vr = ''
    if ($G.VramBytes) { $vr = ', ' + (Format-Bytes $G.VramBytes) }
    $drv = ''
    if ($G.NvidiaVersion) { $drv = ', driver ' + $G.NvidiaVersion }
    elseif ($G.DriverVersion) { $drv = ', driver ' + $G.DriverVersion }
    if ($G.DriverDate) {
        try {
            $months = [Math]::Floor(((Get-Date) - [DateTime]$G.DriverDate).TotalDays / 30.44)
            if ($months -ge 1) { $drv += (' ({0} month(s) old)' -f $months) }
        } catch { }
    }
    return ($G.Name + $vr + $drv)
}

function Get-HardwareRows {
    # UNIVERSAL edition: what Windows reports, with neutral hints.
    # Rows: @(item, detected text, colour, optional hint)
    param([hashtable]$F, [hashtable]$Os)
    $rows = @()
    if ($F.CpuName) {
        $clock = ''
        if ($F.BaseMHz) { $clock = ', {0:N2} GHz reported' -f ([double]$F.BaseMHz / 1000) }
        $rows += , @('CPU', ('{0} ({1} cores / {2} threads{3})' -f $F.CpuName, $F.Cores, $F.Threads, $clock), 'White', '')
    } else { $rows += , @('CPU', 'not detected', 'DarkGray', '') }
    if ($F.Board) { $rows += , @('Motherboard', ('{0} {1}' -f $F.BoardMaker, $F.Board).Trim(), 'White', '') }
    if ($F.BiosVersion) { $rows += , @('BIOS', ($F.BiosVersion + (Format-BiosDate $F.BiosDate)), 'White', 'Firmware is shown only; this tool never updates or changes BIOS settings.') }
    if ($F.MemTotal) {
        $hint = ''
        if ($F.MemConfigured -and $F.MemRated -and [int]$F.MemConfigured -lt [int]$F.MemRated) { $hint = 'Memory runs below the module rating. A memory profile (XMP/EXPO/DOCP) in BIOS may be off; check your board manual. Not changed here.' }
        $rows += , @('Memory', (Format-MemoryText $F), 'White', $hint)
    } else { $rows += , @('Memory', 'not detected', 'DarkGray', '') }
    foreach ($g in $F.Gpus) { $rows += , @('Graphics', (Format-GpuText $g), 'White', '') }
    if ($F.Gpus.Count -eq 0) { $rows += , @('Graphics', 'not detected', 'DarkGray', '') }
    $sb = 'unknown (legacy BIOS or not reported)'
    $sbc = 'DarkGray'
    if ($null -ne $F.SecureBoot) { if ([int]$F.SecureBoot -eq 1) { $sb = 'On'; $sbc = 'Green' } else { $sb = 'Off'; $sbc = 'Yellow' } }
    $rows += , @('Secure Boot', $sb, $sbc, '')
    if ($F.Battery) { $rows += , @('Battery', $F.Battery, 'White', '') }
    return $rows
}

function Get-WindowsSupportText {
    param([hashtable]$Os)
    if ($Os.IsWin11) { return @(('Windows 11 ' + $Os.Version + '. Check Settings > Windows Update to make sure this version still receives updates.'), 'Gray') }
    if ([string]$Os.ProductName -match 'Windows 10') { return @('Windows 10 general support ended on 14 Oct 2025. Extended Security Updates (ESU) enrolment cannot be read by this tool.', 'Yellow') }
    return @('Designed for Windows 10 and Windows 11 desktop editions.', 'Gray')
}

function Get-StartupItems {
    # Read-only list of programs that start with Windows (registry Run keys
    # and Startup folders). Nothing is enabled, disabled or removed here.
    $items = @()
    if (-not $script:OnWindows) { return $items }
    $skip = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')
    foreach ($k in @(@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'this user'), @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'all users'), @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'all users'))) {
        try {
            $p = Get-ItemProperty -LiteralPath $k[0] -ErrorAction Stop
            foreach ($prop in $p.PSObject.Properties) { if ($skip -notcontains $prop.Name) { $items += @{ Name = [string]$prop.Name; Scope = $k[1] } } }
        } catch { }
    }
    foreach ($f in @(@('Startup', 'this user'), @('CommonStartup', 'all users'))) {
        try {
            $dir = [Environment]::GetFolderPath($f[0])
            if ($dir -and [IO.Directory]::Exists($dir)) {
                foreach ($x in [IO.Directory]::GetFiles($dir)) {
                    $n = [IO.Path]::GetFileNameWithoutExtension($x)
                    if ($n -and $n -ne 'desktop') { $items += @{ Name = $n; Scope = $f[1] } }
                }
            }
        } catch { }
    }
    return $items
}

function Get-HealthRows {
    # Read-only checks that affect how responsive Windows feels.
    # Rows: @(item, text, colour)
    param([hashtable]$F, [hashtable]$Pending)
    $rows = @()
    foreach ($d in (Get-CimSafe 'Win32_LogicalDisk' -Filter 'DriveType=3')) {
        $size = [long]$d.Size; $free = [long]$d.FreeSpace
        if ($size -le 0) { continue }
        $pct = [Math]::Round(100.0 * $free / $size, 1)
        $txt = '{0} free of {1} ({2}%)' -f (Format-Bytes $free), (Format-Bytes $size), $pct
        $c = 'Green'
        if ($pct -lt 15) { $c = 'Yellow'; $txt += ' - getting low' }
        if ($pct -lt 8) { $c = 'Red'; $txt += '; updates and installs may fail. Free some space.' }
        $rows += , @(('Drive ' + $d.DeviceID), $txt, $c)
    }
    if ($F.MemTotalKB -and $F.MemFreeKB) {
        $usedPct = [Math]::Round(100.0 * ([double]$F.MemTotalKB - [double]$F.MemFreeKB) / [double]$F.MemTotalKB)
        $c = 'Green'
        $txt = '{0}% in use right now ({1} free)' -f $usedPct, (Format-Bytes ([long]$F.MemFreeKB * 1024))
        if ($usedPct -ge 85) { $c = 'Yellow'; $txt += ' - high; menu [8] lists the largest programs' }
        $rows += , @('Memory', $txt, $c)
    }
    if ($F.Uptime) {
        $c = 'Green'
        $txt = '{0} d {1} h since Windows last fully started' -f $F.Uptime.Days, $F.Uptime.Hours
        if ($F.Uptime.TotalDays -ge 7) { $c = 'Yellow'; $txt += ' - use Restart now and then (with Fast Startup, Shut down does not fully restart Windows)' }
        $rows += , @('Uptime', $txt, $c)
    }
    $rc = 'Green'
    if ($Pending.Any) { $rc = 'Yellow' }
    $rows += , @('Restart', $Pending.Text, $rc)
    $st = @(Get-StartupItems)
    $sc = 'Green'
    $stxt = '{0} program(s) start with Windows (list in menu [8]; manage in Task Manager > Startup)' -f $st.Count
    if ($st.Count -ge 15) { $sc = 'Yellow' }
    $rows += , @('Startup apps', $stxt, $sc)
    $rows += , @('Power plan', ($F.PowerPlan + ' (shown only; never changed)'), 'Gray')
    return $rows
}

function Show-SystemOverview {
    Show-Header 'SYSTEM OVERVIEW' 'Read-only. Nothing is changed.'
    Write-UI '  Collecting information...' DarkGray
    $os = Get-OsInfo
    $f = Get-HardwareFacts
    $pr = Get-PendingRebootInfo
    Show-Header 'SYSTEM OVERVIEW' 'Read-only. Nothing is changed.'
    Write-Section 'Windows'
    Write-KeyValue 'Windows' ('{0}, {1}' -f $os.Text, $(if ($os.Is64) { '64-bit' } else { '32-bit' })) White
    $sup = Get-WindowsSupportText $os
    Write-KeyValue 'Support' $sup[0] $sup[1]
    Write-KeyValue 'PowerShell' ([string]$PSVersionTable.PSVersion) Gray
    Write-KeyValue 'Account' $(if (Test-IsAdmin) { 'Running as administrator' } else { 'Standard rights (admin is requested only when needed)' }) Gray

    $w1 = 12
    if ($script:Baseline) {
        Write-Section 'Hardware: documented baseline vs detected'
        $w2 = 22
        $w3 = [Math]::Max(30, $script:UiWidth - $w1 - $w2 - 2)
        foreach ($r in (Get-BaselineRows $f $os $script:Baseline)) {
            $c = 'Green'
            if ($r[3] -match '^Differs') { $c = 'Yellow' }
            if ($r[3] -eq 'Not detected') { $c = 'DarkGray' }
            Write-Segments @(@(('  ' + (Format-Cell $r[0] $w1) + ' '), 'White'), @(((Format-Cell $r[3] $w2) + ' '), $c), @((Get-Fit $r[2] $w3), 'Gray'))
            Write-Segments @(@(('  ' + (Format-Cell '' $w1) + ' '), 'Gray'), @(((Format-Cell 'documented' $w2) + ' '), 'DarkGray'), @((Get-Fit $r[1] $w3), 'DarkGray'))
        }
    } else {
        Write-Section 'Hardware (as Windows reports it)'
        $w3 = [Math]::Max(30, $script:UiWidth - $w1 - 1)
        foreach ($r in (Get-HardwareRows $f $os)) {
            Write-Segments @(@(('  ' + (Format-Cell $r[0] $w1) + ' '), 'DarkGray'), @((Get-Fit $r[1] $w3), $r[2]))
            if ($r[3]) { foreach ($l in (Get-WrappedLines $r[3] ($w3 - 2))) { Write-UI ('  ' + (' ' * ($w1 + 3)) + $l) Yellow } }
        }
    }

    Write-Section 'Displays (current mode as Windows reports it)'
    if ($f.Displays.Count -eq 0) { Write-UI '  Display modes could not be read.' DarkGray }
    foreach ($d in $f.Displays) {
        $nm = $d.Name
        if (-not $nm) { $nm = $d.Monitor }
        $prim = ''
        if ($d.Primary) { $prim = ' (primary)' }
        Write-Segments @(@(('  {0}{1}' -f $nm, $prim).PadRight(38), 'White'), @(('{0} x {1} @ {2} Hz' -f $d.Width, $d.Height, $d.Hz), 'Green'))
        if ($d.MaxHz -gt $d.Hz) {
            Write-Wrapped ('{0} Hz is offered at this resolution. If that is unexpected, check Settings > Display > Advanced display. (Not changed here.)' -f $d.MaxHz) Yellow 4
        }
    }
    if ($script:Baseline -and $script:Baseline.DisplaysNote) { Write-UI ('  ' + $script:Baseline.DisplaysNote) DarkGray }

    Write-Section 'Health check (read-only)'
    foreach ($r in (Get-HealthRows $f $pr)) {
        $lines = @(Get-WrappedLines $r[1] ($script:UiWidth - $w1 - 1))
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $k = ''
            if ($i -eq 0) { $k = $r[0] }
            Write-Segments @(@(('  ' + (Format-Cell $k $w1) + ' '), 'DarkGray'), @($lines[$i], $r[2]))
        }
    }

    Write-Section 'Storage'
    $ld = @(Get-CimSafe 'Win32_LogicalDisk' -Filter 'DriveType=3')
    Write-UI ('  ' + (Format-Cell 'Drive' 6) + ' ' + (Format-Cell 'Label' 16) + ' ' + (Format-Cell 'Format' 7) + ' ' + (Format-Cell 'Size' 10 'Right') + ' ' + (Format-Cell 'Used' 10 'Right') + ' ' + (Format-Cell 'Free' 10 'Right') + ' ' + (Format-Cell 'Free %' 7 'Right')) DarkGray
    foreach ($d in $ld) {
        $size = [long]$d.Size; $free = [long]$d.FreeSpace
        $pct = 0
        if ($size -gt 0) { $pct = [Math]::Round(100.0 * $free / $size, 1) }
        $c = 'Gray'
        if ($pct -lt 15) { $c = 'Yellow' }
        if ($pct -lt 8) { $c = 'Red' }
        Write-UI ('  ' + (Format-Cell ([string]$d.DeviceID) 6) + ' ' + (Format-Cell ([string]$d.VolumeName) 16) + ' ' + (Format-Cell ([string]$d.FileSystem) 7) + ' ' + (Format-Cell (Format-Bytes $size) 10 'Right') + ' ' + (Format-Cell (Format-Bytes ($size - $free)) 10 'Right') + ' ' + (Format-Cell (Format-Bytes $free) 10 'Right') + ' ' + (Format-Cell ('{0}%' -f $pct) 7 'Right')) $c
    }
    $pd = @()
    try { $pd = @(Get-PhysicalDisk -ErrorAction Stop) } catch { }
    if ($pd.Count -gt 0) {
        foreach ($p in $pd) { Write-UI ('  Disk: {0}  {1}  {2} {3}' -f $p.FriendlyName, (Format-Bytes ([long]$p.Size)), $p.MediaType, $p.BusType) DarkGray }
    } else {
        foreach ($p in (Get-CimSafe 'Win32_DiskDrive')) { Write-UI ('  Disk: {0}  {1}  {2}' -f $p.Model, (Format-Bytes ([long]$p.Size)), $p.InterfaceType) DarkGray }
    }
    Write-Section 'Not detectable by this tool'
    Write-Wrapped 'Power supply and cooler models, temperatures and fan curves, TPM details (needs administrator), BIOS settings, and Windows 10 ESU enrolment. Resizable BAR on NVIDIA cards can be checked in [8] Inventory through NVIDIA''s own nvidia-smi (read-only).' DarkGray 2
    Wait-AnyKey
}

# -----------------------------------------------------------------------------
# 7b. Gaming and storage inventory (read-only). Uses launcher manifests,
#     registry uninstall entries and process names. Never crawls drives.
# -----------------------------------------------------------------------------
function Read-SteamLibraryPaths {
    param([string]$Path)
    $paths = @()
    try {
        $t = [IO.File]::ReadAllText($Path)
        foreach ($m in [regex]::Matches($t, '"path"\s+"([^"]+)"', 'IgnoreCase')) { $paths += ($m.Groups[1].Value -replace '\\\\', '\') }
    } catch { }
    return $paths
}

function Read-AcfManifest {
    param([string]$Path)
    $r = @{}
    try {
        $t = [IO.File]::ReadAllText($Path)
        foreach ($k in @('appid', 'name', 'installdir', 'SizeOnDisk', 'StateFlags', 'LastUpdated')) {
            $m = [regex]::Match($t, '"' + $k + '"\s+"([^"]*)"', 'IgnoreCase')
            if ($m.Success) { $r[$k] = $m.Groups[1].Value }
        }
    } catch { }
    return $r
}

function Get-SteamInventory {
    param([string]$SteamPathOverride = $null)
    $r = @{ Installed = $false; Path = $null; Libraries = @(); Games = @(); Notes = @() }
    $sp = $SteamPathOverride
    if (-not $sp) { $sp = Get-RegValue 'HKCU:\Software\Valve\Steam' 'SteamPath' }
    if (-not $sp) { $sp = Get-RegValue 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' 'InstallPath' }
    if (-not $sp) { $r.Notes += 'Steam is not registered for this user.'; return $r }
    $sp = ([string]$sp) -replace '/', $script:Sep
    if (-not [IO.Directory]::Exists($sp)) { $r.Notes += "Steam is registered at $sp but that folder does not exist."; return $r }
    $r.Installed = $true
    $r.Path = $sp
    $libs = New-Object 'System.Collections.Generic.List[string]'
    $libs.Add($sp)
    $vdf = Join-Path (Join-Path $sp 'steamapps') 'libraryfolders.vdf'
    if ([IO.File]::Exists($vdf)) {
        foreach ($p in (Read-SteamLibraryPaths $vdf)) {
            $dup = $false
            foreach ($x in $libs) { if (Test-SamePath $x $p) { $dup = $true } }
            if (-not $dup) { $libs.Add($p) }
        }
    } else { $r.Notes += 'libraryfolders.vdf not found; only the main Steam folder was checked.' }
    foreach ($lib in $libs) {
        $apps = Join-Path $lib 'steamapps'
        $libInfo = @{ Path = $lib; Exists = [IO.Directory]::Exists($apps); Games = 0; Bytes = [long]0 }
        if ($libInfo.Exists) {
            try {
                foreach ($f in (New-Object IO.DirectoryInfo($apps)).GetFiles('appmanifest_*.acf')) {
                    $m = Read-AcfManifest $f.FullName
                    if (-not $m.ContainsKey('name')) { continue }
                    $dir = $null
                    if ($m['installdir']) { $dir = Join-Path (Join-Path $apps 'common') $m['installdir'] }
                    $confirmed = [bool]($dir -and [IO.Directory]::Exists($dir))
                    $size = [long]0
                    if ($m['SizeOnDisk']) { [void][long]::TryParse([string]$m['SizeOnDisk'], [ref]$size) }
                    $r.Games += @{ Name = $m['name']; AppId = $m['appid']; Library = $lib; Bytes = $size; Confirmed = $confirmed; StateFlags = $m['StateFlags'] }
                    $libInfo.Games++
                    $libInfo.Bytes += $size
                }
            } catch { $r.Notes += ('Library could not be read: ' + $lib) }
        }
        $r.Libraries += $libInfo
    }
    return $r
}

$script:RiotProductNames = @{ 'valorant' = 'VALORANT'; 'league_of_legends' = 'League of Legends'; 'bacon' = 'Legends of Runeterra' }

function Get-RiotInventory {
    # Reads Riot's own product metadata (fixed folder, no drive crawling).
    param([string]$ProgramDataOverride = $null)
    $r = @{ Client = $false; Products = @(); ValorantPath = $null; ValorantConfirmed = $false; Vanguard = 'not found'; Notes = @() }
    $pd = $ProgramDataOverride
    if (-not $pd) { $an = Get-Anchors; if ($an.ProgramData.Ok) { $pd = $an.ProgramData.Path } }
    if (-not $pd) { $r.Notes += 'ProgramData could not be verified.'; return $r }
    $riot = Join-Path $pd 'Riot Games'
    if ([IO.File]::Exists((Join-Path $riot 'RiotClientInstalls.json'))) { $r.Client = $true }
    $meta = Join-Path $riot 'Metadata'
    if ([IO.Directory]::Exists($meta)) {
        try {
            foreach ($d in (New-Object IO.DirectoryInfo($meta)).GetDirectories()) {
                if (($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $yaml = Join-Path $d.FullName ($d.Name + '.product_settings.yaml')
                if (-not [IO.File]::Exists($yaml)) { continue }
                try {
                    $m = [regex]::Match([IO.File]::ReadAllText($yaml), 'product_install_full_path:\s*"?([^"\r\n]+)"?')
                    if (-not $m.Success) { continue }
                    $p = $m.Groups[1].Value.Trim() -replace '/', $script:Sep
                    $id = ($d.Name -split '\.')[0]
                    $name = $id
                    if ($script:RiotProductNames.ContainsKey($id)) { $name = $script:RiotProductNames[$id] }
                    $confirmed = [IO.Directory]::Exists($p)
                    if ($id -eq 'valorant') {
                        $exe = Join-Path $p (Join-Path 'ShooterGame' (Join-Path 'Binaries' (Join-Path 'Win64' 'VALORANT-Win64-Shipping.exe')))
                        $confirmed = [IO.File]::Exists($exe)
                        $r.ValorantPath = $p
                        $r.ValorantConfirmed = $confirmed
                    }
                    $r.Products += @{ Id = $id; Name = $name; Path = $p; Confirmed = $confirmed }
                } catch { $r.Notes += ('Riot settings file could not be read: ' + $d.Name) }
            }
        } catch { }
    }
    if ($script:OnWindows) {
        $svc = Get-Service -Name 'vgc' -ErrorAction SilentlyContinue
        $drv = Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\vgk'
        if ($svc -or $drv) { $r.Vanguard = 'installed'; if ($svc) { $r.Vanguard += (' (vgc service ' + $svc.Status + ')') } }
    }
    return $r
}

function Get-EpicInventory {
    param([string]$ProgramDataOverride = $null)
    $r = @{ Present = $false; Games = @(); Notes = @() }
    $pd = $ProgramDataOverride
    if (-not $pd) { $an = Get-Anchors; if ($an.ProgramData.Ok) { $pd = $an.ProgramData.Path } }
    if (-not $pd) { return $r }
    $dir = Join-Path $pd (Join-Path 'Epic' (Join-Path 'EpicGamesLauncher' (Join-Path 'Data' 'Manifests')))
    if (-not [IO.Directory]::Exists($dir)) { return $r }
    $r.Present = $true
    try {
        foreach ($f in (New-Object IO.DirectoryInfo($dir)).GetFiles('*.item')) {
            try {
                $j = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
                $loc = [string]$j.InstallLocation
                $size = [long]0
                if ($j.PSObject.Properties['InstallSize']) { $size = [long]$j.InstallSize }
                $incomplete = $false
                if ($j.PSObject.Properties['bIsIncompleteInstall']) { $incomplete = [bool]$j.bIsIncompleteInstall }
                $r.Games += @{ Name = [string]$j.DisplayName; Path = $loc; Bytes = $size; Confirmed = ($loc -and [IO.Directory]::Exists($loc) -and -not $incomplete) }
            } catch { $r.Notes += ('Unreadable manifest: ' + $f.Name) }
        }
    } catch { }
    return $r
}

function Get-UninstallEntries {
    $list = @()
    if (-not $script:OnWindows) { return $list }
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall')
    foreach ($k in $keys) {
        foreach ($sub in @(Get-ChildItem -LiteralPath $k -ErrorAction SilentlyContinue)) {
            try {
                $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction Stop
                $name = [string]$p.DisplayName
                if (-not $name) { continue }
                if ($p.PSObject.Properties['SystemComponent'] -and [int]$p.SystemComponent -eq 1) { continue }
                if ($p.PSObject.Properties['ParentKeyName'] -and $p.ParentKeyName) { continue }
                $list += @{ Name = $name.Trim(); Version = [string]$p.DisplayVersion; Publisher = [string]$p.Publisher; Location = [string]$p.InstallLocation }
            } catch { }
        }
    }
    return $list
}

$script:LauncherPatterns = @(
    @('Steam', '^Steam$'), @('Epic Games Launcher', '^Epic Games Launcher'), @('Riot Client / VALORANT', '^(Riot Client|VALORANT)'),
    @('Riot Vanguard', '^Riot Vanguard'), @('Battle.net', '^Battle\.net'), @('EA app', '^(EA app|EA Desktop|Origin)$'),
    @('Ubisoft Connect', '^(Ubisoft Connect|Uplay)'), @('GOG GALAXY', '^GOG GALAXY'), @('Rockstar Games Launcher', '^Rockstar Games Launcher'),
    @('Discord', '^Discord$'), @('NVIDIA app / GeForce Experience', '^(NVIDIA app|NVIDIA GeForce Experience)'), @('OBS Studio', '^OBS Studio'),
    @('Opera / Opera GX', '^Opera'), @('Vivaldi', '^Vivaldi'), @('HyperX NGENUITY', 'NGENUITY')
)

$script:ProcessGroups = @(
    @('Game launcher', '^(steam|steamwebhelper|EpicGamesLauncher|RiotClientServices|RiotClientUx|RiotClientUxRender|Battle\.net|EADesktop|EABackgroundService|upc|UbisoftConnect|GalaxyClient|RockstarService|LauncherPatcher)$'),
    @('Overlay / recording', '^(Discord|GameOverlayUI|NVIDIA Overlay|nvsphelper64|GameBar|GameBarFTServer|XboxGameBarWidgets|obs64|Medal|Overwolf|Streamlabs OBS|ShareX)$'),
    @('Peripherals / RGB / audio', '^(NGenuity2|NGENUITY|HyperX.*|iCUE|Corsair.*|ArmouryCrate.*|LightingService|AuraWallpaperService|RazerCentralService|Razer Synapse.*|lghub.*|SteelSeriesGG.*|SignalRgb|NZXT CAM|MSI\.CentralServer|MSI_Center.*|OpenRGB|WootilityHelper|Wooting.*)$'),
    @('Desktop customisation', '^(wallpaper32|wallpaper64|Rainmeter|TranslucentTB|StartAllBack.*)$'),
    @('Browser', '^(msedge|chrome|firefox|brave|opera|vivaldi)$'),
    @('Anti-cheat', '^(vgc|vgtray|EasyAntiCheat.*|BEService|FACEIT.*|faceit.*)$'),
    @('Cloud sync', '^(OneDrive|Dropbox|GoogleDriveFS|iCloudDrive|iCloudServices)$'),
    @('GPU software', '^(NVDisplay\.Container|nvcontainer|NVIDIA Web Helper|NVIDIA app|NVIDIA Share|RadeonSoftware|AMDRSServ|AMDRSSrcExt|IntelGraphicsSoftware.*|igfxEM|IGCC)$')
)

function Get-ProcessSummary {
    $groups = @{}
    $byName = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $n = $p.ProcessName
        if (-not $byName.ContainsKey($n)) { $byName[$n] = @{ Name = $n; Count = 0; Bytes = [long]0 } }
        $byName[$n].Count++
        try { $byName[$n].Bytes += [long]$p.WorkingSet64 } catch { }
    }
    foreach ($e in $byName.Values) {
        foreach ($g in $script:ProcessGroups) {
            if ($e.Name -match $g[1]) {
                if (-not $groups.ContainsKey($g[0])) { $groups[$g[0]] = @() }
                $groups[$g[0]] += $e
            }
        }
    }
    $top = @($byName.Values | Sort-Object { $_.Bytes } -Descending | Select-Object -First 12)
    return @{ Groups = $groups; Top = $top; Total = $byName.Count }
}

function Invoke-ReadOnlyTool {
    # Runs a vendor query tool (no changes) with a timeout and returns stdout.
    param([string]$Exe, [string]$Arguments, [int]$TimeoutMs = 15000)
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [Diagnostics.Process]::Start($psi)
        $task = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch { }; return $null }
        return $task.Result
    } catch { return $null }
}

function Get-NvidiaSmiInfo {
    $r = @{ Ran = $false; Note = ''; Name = $null; Driver = $null; VramMiB = $null; Bar1MiB = $null; GenCur = $null; GenMax = $null; WidthCur = $null; WidthMax = $null; ReBar = 'unknown' }
    $an = Get-Anchors
    $cands = @()
    if ($an.Windows.Ok) { $cands += (Join-Path $an.Windows.Path 'System32\nvidia-smi.exe') }
    if ($env:ProgramFiles) { $cands += (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe') }
    $exe = $null
    foreach ($c in $cands) { if ([IO.File]::Exists($c)) { $exe = $c; break } }
    if (-not $exe) { $r.Note = 'nvidia-smi.exe (installed with the NVIDIA driver) was not found.'; return $r }
    $q = Invoke-ReadOnlyTool $exe '--query-gpu=name,driver_version,memory.total,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv,noheader,nounits'
    if ($q) {
        $first = @($q -split "`r?`n" | Where-Object { $_.Trim() })[0]
        $v = @($first -split ',' | ForEach-Object { $_.Trim() })
        if ($v.Count -ge 7) {
            $r.Ran = $true
            $r.Name = $v[0]; $r.Driver = $v[1]; $r.VramMiB = $v[2]; $r.GenCur = $v[3]; $r.GenMax = $v[4]; $r.WidthCur = $v[5]; $r.WidthMax = $v[6]
        }
    }
    $m = Invoke-ReadOnlyTool $exe '-q -d MEMORY'
    if ($m) {
        $mm = [regex]::Match($m, 'BAR1 Memory Usage[\s\S]*?Total\s*:\s*(\d+)\s*MiB')
        if ($mm.Success) {
            $r.Bar1MiB = [int]$mm.Groups[1].Value
            $vram = 0
            [void][int]::TryParse([string]$r.VramMiB, [ref]$vram)
            if ($vram -gt 0 -and $r.Bar1MiB -ge [int]($vram * 0.9)) { $r.ReBar = 'Active (BAR1 = {0} MiB, matches VRAM)' -f $r.Bar1MiB }
            elseif ($r.Bar1MiB -le 256) { $r.ReBar = 'Not active (BAR1 = {0} MiB)' -f $r.Bar1MiB }
            else { $r.ReBar = 'Inconclusive (BAR1 = {0} MiB)' -f $r.Bar1MiB }
        }
    }
    if (-not $r.Ran) { $r.Note = 'nvidia-smi did not return data.' }
    return $r
}

function Show-Inventory {
    Show-Header 'GAMING AND STORAGE INVENTORY' 'Read-only. Uses launcher manifests and registry entries; drives are not crawled.'
    Write-UI '  Collecting information (this can take a few seconds)...' DarkGray
    $lines = New-Object 'System.Collections.Generic.List[object]'
    $add = { param($t, $c) if (-not $c) { $c = 'Gray' }; $lines.Add(@([string]$t, [string]$c)) }
    $unknown = @()

    & $add '  STORAGE' 'Cyan'
    $drv = @(Get-CimSafe 'Win32_LogicalDisk' -Filter 'DriveType=3')
    foreach ($d in $drv) {
        & $add ('    {0}  {1,-16} {2,10} free of {3,10}' -f $d.DeviceID, (Get-Fit ([string]$d.VolumeName) 16), (Format-Bytes ([long]$d.FreeSpace)), (Format-Bytes ([long]$d.Size))) 'White'
    }
    $pd = @()
    try { $pd = @(Get-PhysicalDisk -ErrorAction Stop) } catch { }
    foreach ($p in $pd) { & $add ('    Physical disk: {0} ({1}, {2}, {3})' -f $p.FriendlyName, (Format-Bytes ([long]$p.Size)), $p.MediaType, $p.BusType) 'Gray' }
    if ($pd.Count -eq 0) { foreach ($p in (Get-CimSafe 'Win32_DiskDrive')) { & $add ('    Physical disk: {0} ({1}, {2})' -f $p.Model, (Format-Bytes ([long]$p.Size)), $p.InterfaceType) 'Gray' } }
    & $add '' 'Gray'

    & $add '  STEAM' 'Cyan'
    $st = Get-SteamInventory
    if ($st.Installed) {
        & $add ('    Client: {0}' -f $st.Path) 'White'
        foreach ($l in $st.Libraries) {
            $state = 'missing'
            if ($l.Exists) { $state = '{0} game manifest(s), {1}' -f $l.Games, (Format-Bytes $l.Bytes) }
            & $add ('    Library: {0}  ({1})' -f $l.Path, $state) 'Gray'
        }
        $games = @($st.Games | Sort-Object { $_.Bytes } -Descending)
        foreach ($g in $games) {
            $tag = 'confirmed'
            $col = 'Gray'
            if (-not $g.Confirmed) { $tag = 'POSSIBLE - manifest only, folder missing'; $col = 'DarkGray' }
            & $add ('      {0,-44} {1,10}  {2}' -f (Get-Fit $g.Name 44), (Format-Bytes $g.Bytes), $tag) $col
        }
        if ($games.Count -eq 0) { & $add '      No installed game manifests found.' 'DarkGray' }
    }
    foreach ($n in $st.Notes) { & $add ('    ' + $n) 'DarkGray' }
    & $add '' 'Gray'

    & $add '  RIOT GAMES' 'Cyan'
    $rt = Get-RiotInventory
    & $add ('    Riot Client: {0}' -f $(if ($rt.Client) { 'present (RiotClientInstalls.json found)' } else { 'not found' })) 'Gray'
    foreach ($rp in $rt.Products) {
        $vs = 'POSSIBLE - recorded path, game files not found'
        $col = 'DarkGray'
        if ($rp.Confirmed) { $vs = 'confirmed'; $col = 'White' }
        & $add ('    {0}: {1}  (drive {2}, {3})' -f $rp.Name, $rp.Path, ([IO.Path]::GetPathRoot($rp.Path)), $vs) $col
    }
    if ($rt.Products.Count -eq 0) { & $add '    No Riot games found in Riot metadata.' 'DarkGray' }
    & $add ('    Riot Vanguard: {0}' -f $rt.Vanguard) 'Gray'
    foreach ($n in $rt.Notes) { & $add ('    ' + $n) 'DarkGray' }
    & $add '' 'Gray'

    & $add '  EPIC GAMES' 'Cyan'
    $ep = Get-EpicInventory
    if (-not $ep.Present) { & $add '    Epic Games Launcher manifests not found.' 'DarkGray' }
    foreach ($g in @($ep.Games | Sort-Object { $_.Bytes } -Descending)) {
        $tag = 'confirmed'
        if (-not $g.Confirmed) { $tag = 'POSSIBLE - folder missing or incomplete' }
        & $add ('      {0,-44} {1,10}  {2}' -f (Get-Fit $g.Name 44), (Format-Bytes $g.Bytes), $tag) 'Gray'
    }
    & $add '' 'Gray'

    & $add '  LAUNCHERS AND RELATED APPS (from Windows "installed apps" entries)' 'Cyan'
    $un = @(Get-UninstallEntries)
    foreach ($lp in $script:LauncherPatterns) {
        $hit = @($un | Where-Object { $_.Name -match $lp[1] })
        if ($hit.Count -gt 0) { & $add ('    {0,-32} {1}' -f $lp[0], ($hit[0].Name + ' ' + $hit[0].Version).Trim()) 'Gray' }
    }
    if ($script:OnWindows) {
        foreach ($ax in @(@('Xbox app', 'Microsoft.GamingApp'), @('Xbox Game Bar', 'Microsoft.XboxGamingOverlay'), @('HyperX NGENUITY (Store)', '*NGENUITY*'))) {
            try {
                $pkg = @(Get-AppxPackage -Name $ax[1] -ErrorAction Stop)
                if ($pkg.Count -gt 0) { & $add ('    {0,-32} {1}' -f $ax[0], $pkg[0].Version) 'Gray' }
            } catch { }
        }
    }
    & $add '' 'Gray'

    & $add '  BROWSERS' 'Cyan'
    foreach ($b in $script:BrowserDefs) {
        $info = Get-BrowserProfiles $b
        if ($info.Installed) { & $add ('    {0,-18} {1} profile(s){2}' -f $b.Name, $info.Profiles.Count, $(if (Test-BrowserRunning $b) { ', running now' } else { '' })) 'Gray' }
        else { & $add ('    {0,-18} not found for this user' -f $b.Name) 'DarkGray' }
    }
    & $add '' 'Gray'

    & $add '  GRAPHICS' 'Cyan'
    foreach ($g in (Get-GpuList)) {
        $v = ''
        if ($g.VramBytes) { $v = ', ' + (Format-Bytes $g.VramBytes) }
        $drvText = $g.DriverVersion
        if ($g.NvidiaVersion) { $drvText = '{0} (Windows {1})' -f $g.NvidiaVersion, $g.DriverVersion }
        & $add ('    {0}{1}, driver {2}' -f $g.Name, $v, $drvText) 'White'
    }
    $smi = Get-NvidiaSmiInfo
    if ($smi.Ran) {
        & $add ('    nvidia-smi: driver {0}, PCIe gen {1} of {2} (max), width x{3} of x{4}' -f $smi.Driver, $smi.GenCur, $smi.GenMax, $smi.WidthCur, $smi.WidthMax) 'Gray'
        $pcieNote = '      PCIe generation drops at idle to save power; check it while a game runs.'
        if ($script:Baseline -and $script:Baseline.PlatformNote) { $pcieNote += ' ' + $script:Baseline.PlatformNote }
        & $add $pcieNote 'DarkGray'
        & $add ('    Resizable BAR: {0}' -f $smi.ReBar) 'White'
    } else { & $add ('    nvidia-smi: ' + $smi.Note) 'DarkGray'; $unknown += 'Resizable BAR status' }
    & $add '' 'Gray'

    & $add '  BACKGROUND PROCESSES RIGHT NOW (information only - nothing is closed)' 'Cyan'
    $ps = Get-ProcessSummary
    foreach ($gname in @($ps.Groups.Keys | Sort-Object)) {
        $names = @($ps.Groups[$gname] | ForEach-Object { $_.Name }) -join ', '
        & $add ('    {0,-26} {1}' -f $gname, (Get-Fit $names ($script:UiWidth - 30))) 'Gray'
    }
    & $add ('    Largest by memory (of {0} process names):' -f $ps.Total) 'DarkGray'
    foreach ($t in $ps.Top) { & $add ('      {0,-34} {1,10}  x{2}' -f (Get-Fit $t.Name 34), (Format-Bytes $t.Bytes), $t.Count) 'Gray' }
    & $add '' 'Gray'

    & $add '  PROGRAMS THAT START WITH WINDOWS (information only - nothing is changed)' 'Cyan'
    $startup = @(Get-StartupItems)
    foreach ($s in ($startup | Sort-Object { $_.Name })) { & $add ('    {0,-44} {1}' -f (Get-Fit $s.Name 44), $s.Scope) 'Gray' }
    if ($startup.Count -eq 0) { & $add '    None found in the Run keys or Startup folders.' 'DarkGray' }
    else { & $add '    Turn off the ones you do not need in Task Manager > Startup (this tool never changes them).' 'DarkGray' }
    & $add '' 'Gray'

    & $add ('  INSTALLED APPLICATIONS: {0} entries (full list in the inventory report file)' -f $un.Count) 'Cyan'
    & $add '' 'Gray'
    & $add '  COULD NOT BE DETERMINED' 'Cyan'
    $unknown += @('power supply and cooler models', 'temperatures and fan curves', 'games installed outside Steam/Epic/Riot manifests', 'Microsoft Store / Xbox game install sizes')
    foreach ($u in $unknown) { & $add ('    - ' + $u) 'DarkGray' }

    $logOk = Start-RunLog 'inventory'
    if ($logOk) {
        [void](Invoke-LogRetention)
        Write-LogEnvironment
        foreach ($l in $lines) { Write-RunLog ([string]$l[0]) }
        Write-LogSection 'Installed applications (names and versions only)'
        foreach ($e in @($un | Sort-Object { $_.Name } -Unique)) { Write-RunLog ('  {0}  {1}' -f $e.Name, $e.Version) }
        $lines.Add(@(('  Inventory report saved: ' + $script:Log.Path), 'Cyan'))
    } else { $lines.Add(@(('  Inventory report could not be saved: ' + $script:Log.LastError), 'Yellow')) }
    Show-Header 'GAMING AND STORAGE INVENTORY' 'Read-only. "confirmed" = manifest and folder found; "POSSIBLE" = only a record was found.'
    Show-Lines $lines
    Wait-AnyKey
}

# -----------------------------------------------------------------------------
# 7c. Reports and logs
# -----------------------------------------------------------------------------
function Get-ReportFiles {
    $dir = Get-AppDataDir 'Logs'
    if (-not $dir -or -not [IO.Directory]::Exists($dir)) { return @() }
    try {
        return @((New-Object IO.DirectoryInfo($dir)).GetFiles() | Where-Object { $_.Name -match '^aiznm_\d{8}_\d{6}_[a-z]+\d?\.log$' } | Sort-Object LastWriteTimeUtc -Descending)
    } catch { return @() }
}

function Show-ReportsMenu {
    while ($true) {
        Show-Header 'REPORTS AND LOGS' 'Every scan, cleanup and inventory writes a report here.'
        $dir = Get-AppDataDir 'Logs'
        Write-KeyValue 'Folder' ([string]$dir) Cyan
        Write-KeyValue 'Retention' ('newest {0} kept; reports older than {1} days removed automatically' -f $script:Policy.LogKeepCount, $script:Policy.LogKeepDays) DarkGray
        Write-UI ''
        $files = @(Get-ReportFiles | Select-Object -First 9)
        if ($files.Count -eq 0) { Write-UI '  No reports yet. Run a scan or cleanup first.' DarkGray }
        for ($i = 0; $i -lt $files.Count; $i++) {
            $f = $files[$i]
            $kind = (($f.BaseName -split '_')[-1]) -replace '\d+$', ''
            Write-Segments @(@(('  [{0}] ' -f ($i + 1)), 'Cyan'), @(('{0}  ' -f $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')), 'White'), @((Format-Cell $kind 10), 'Gray'), @(('{0,8}  ' -f (Format-Bytes $f.Length)), 'DarkGray'), @($f.Name, 'DarkGray'))
        }
        Write-UI ''
        Write-UI '  [1-9] view a report here   [L] open the latest in Notepad   [O] open the folder   [Esc] back' Cyan
        $valid = @('L', 'O')
        for ($i = 1; $i -le $files.Count; $i++) { $valid += [string]$i }
        $k = Read-Choice -Valid $valid -AllowEscape
        if ($k -eq 'ESC') { return }
        if ($k -eq 'O') {
            if ($dir -and [IO.Directory]::Exists($dir)) { try { Start-Process -FilePath (Join-Path (Get-Anchors).Windows.Path 'explorer.exe') -ArgumentList ('"' + $dir + '"') } catch { } }
            continue
        }
        if ($k -eq 'L') {
            if ($files.Count -gt 0) { try { Start-Process -FilePath (Join-Path (Get-Anchors).Windows.Path 'System32\notepad.exe') -ArgumentList ('"' + $files[0].FullName + '"') } catch { } }
            continue
        }
        $f = $files[[int]$k - 1]
        Show-Header ('REPORT: ' + $f.Name) ''
        $lines = @()
        try {
            foreach ($l in [IO.File]::ReadAllLines($f.FullName)) {
                $c = 'Gray'
                if ($l -match '^\[Completed') { $c = 'Green' }
                elseif ($l -match '^\[(Failed|Partially)') { $c = 'Red' }
                elseif ($l -match '^\[(Skipped|Cancelled)') { $c = 'Yellow' }
                elseif ($l -match '^----') { $c = 'Cyan' }
                $lines += , @(('  ' + $l), $c)
            }
        } catch { $lines += , @(('  Could not read the report: ' + $_.Exception.Message), 'Red') }
        Show-Lines $lines
        Wait-AnyKey 'Press any key to go back...'
    }
}

# -----------------------------------------------------------------------------
# 7d. Built-in Windows tools
# -----------------------------------------------------------------------------
function Show-WindowsTools {
    while ($true) {
        Show-Header 'WINDOWS CLEANUP TOOLS' 'Windows manages some data itself. These built-in tools are the supported way to clean it.'
        Write-UI ''
        Write-Segments @(@('  [1] ', 'Cyan'), @('Disk Cleanup for the system drive', 'White'))
        Write-Wrapped 'Click "Clean up system files" inside it for Windows Update Cleanup, previous Windows installations, upgrade logs and driver packages. You choose every box yourself.' DarkGray 6
        Write-Segments @(@('  [2] ', 'Cyan'), @('Settings > Storage', 'White'))
        Write-Wrapped 'Shows what uses space and offers temporary-file cleanup managed by Windows.' DarkGray 6
        Write-Segments @(@('  [3] ', 'Cyan'), @('Storage Sense settings', 'White'))
        Write-Wrapped 'Lets Windows clean temporary files and the Recycle Bin on a schedule. Downloads and cloud files are only touched if you choose so.' DarkGray 6
        $win11 = (Get-OsInfo).IsWin11
        $valid = @('1', '2', '3')
        if ($win11) {
            Write-Segments @(@('  [4] ', 'Cyan'), @('Cleanup recommendations (Windows 11)', 'White'))
            Write-Wrapped 'Windows 11 suggests large or unused files, cloud-synced files and unused apps. You review each one.' DarkGray 6
            $valid += '4'
        }
        Write-UI ''
        Write-Wrapped 'Note: "cleanmgr /autoclean" (used by the old v2.0 script) is documented by Microsoft as deleting the files left behind after a Windows upgrade. It is not a general cleanup, so this program does not run it silently.' DarkGray 2
        Write-UI ''
        Write-UI '  [Esc] back' Cyan
        $k = Read-Choice -Valid $valid -AllowEscape
        if ($k -eq 'ESC') { return }
        try {
            switch ($k) {
                '1' {
                    $drive = (Get-SystemDriveRoot)
                    $letter = 'C'
                    if ($drive) { $letter = $drive.Substring(0, 1) }
                    Start-Process -FilePath (Join-Path (Get-Anchors).Windows.Path 'System32\cleanmgr.exe') -ArgumentList ('/d ' + $letter)
                }
                '2' { Start-Process 'ms-settings:storagesense' }
                '3' { Start-Process 'ms-settings:storagepolicies' }
                '4' { Start-Process 'ms-settings:storagerecommendations' }
            }
            Write-UI '  Opened. Use the Windows window; this menu stays here.' Green
        } catch { Write-UI ('  Could not open it: ' + (Get-InnerMessage $_.Exception)) Yellow }
        Start-Sleep -Milliseconds 1200
    }
}

# -----------------------------------------------------------------------------
# 7e. Main menu and entry point
# -----------------------------------------------------------------------------
function Show-MainMenu {
    while ($true) {
        $sub = 'Nothing is deleted without a preview and your confirmation.'
        if ($script:Edition -eq 'Universal') { $sub = 'For any Windows 10/11 PC. Nothing is deleted without a preview and your confirmation.' }
        Show-Header 'MAIN MENU' $sub
        Write-DriveLine
        $acct = 'standard rights - administrator is requested only for admin-only cleanup'
        if (Test-IsAdmin) { $acct = 'running as administrator' }
        Write-Segments @(@('  Account      ', 'DarkGray'), @($acct, 'Gray'))
        $an = Get-Anchors
        foreach ($k in @('LocalAppData', 'Temp', 'Windows')) { if (-not $an[$k].Ok) { Write-Segments @(@('  Note         ', 'DarkGray'), @((Get-Fit $an[$k].Reason ($script:UiWidth - 13)), 'Yellow')) } }
        Write-UI ''
        $items = @(
            @('1', 'System overview', 'read-only hardware, Windows and storage summary'),
            @('2', 'Scan for cleanup candidates', 'analyse every category, delete nothing'),
            @('3', 'Preview and select cleanup', 'choose categories, review sizes, confirm'),
            @('4', 'Quick safe cleanup', 'old temporary files only, with preview'),
            @('5', 'Browser cache cleanup', 'Edge, Chrome, Brave, Vivaldi, Opera, Firefox'),
            @('6', 'Advanced cleanup', 'shader caches, old crash dumps, Recycle Bin'),
            @('7', 'Windows cleanup tools', 'Disk Cleanup, Storage settings, Storage Sense'),
            @('8', 'Gaming and storage inventory', 'read-only games, launchers, drives, processes'),
            @('9', 'Reports and logs', 'view previous reports'),
            @('0', 'Exit', '')
        )
        foreach ($it in $items) {
            $label = $it[1]
            $dots = ' ' + ('.' * [Math]::Max(2, 32 - $label.Length)) + ' '
            if (-not $it[2]) { $dots = '' }
            Write-Segments @(@(('  [' + $it[0] + '] '), 'Cyan'), @($label, 'White'), @($dots, 'DarkGray'), @($it[2], 'Gray'))
        }
        Write-UI ''
        Write-UI '  Press a number.' DarkGray
        $k = Read-Choice -Valid @('1', '2', '3', '4', '5', '6', '7', '8', '9', '0') -AllowEscape
        $script:CancelRequested = $false
        switch ($k) {
            '1' { Show-SystemOverview }
            '2' { Show-ScanReport }
            '3' { Start-CleanupFlow -Title 'PREVIEW AND SELECT CLEANUP' -Groups @('Safe', 'Browser', 'Advanced') }
            '4' { Start-CleanupFlow -Title 'QUICK SAFE CLEANUP' -Groups @('Safe') -Quick }
            '5' { Start-CleanupFlow -Title 'BROWSER CACHE CLEANUP' -Groups @('Browser') -BrowserMode -Banner 'Only cache folders are touched. Cookies, passwords, history, bookmarks, sessions and extensions are never touched. Open browsers are skipped, never closed.' }
            '6' { Start-CleanupFlow -Title 'ADVANCED CLEANUP' -Groups @('Advanced') -Banner 'Opt-in items with side effects. Shader caches cause temporary stutter while they rebuild and do not raise FPS. Dumps are diagnostic evidence. Emptying the Recycle Bin is permanent.' }
            '7' { Show-WindowsTools }
            '8' { Show-Inventory }
            '9' { Show-ReportsMenu }
            '0' { return }
            'ESC' { if (Read-YesNo 'Exit aiznm CLEANER?' 'Y') { return } }
        }
    }
}

function Test-RuntimeSupported {
    if ($PSVersionTable.PSVersion.Major -lt 5) { return 'Windows PowerShell 5.1 or newer is required.' }
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { return 'PowerShell is restricted by a system policy (Constrained Language Mode). The cleaner will not run in that mode.' }
    if (-not $script:OnWindows) { return 'This program runs on Windows only.' }
    return $null
}

function Start-Interactive {
    $global:AIZNM_EXIT = 0
    $problem = Test-RuntimeSupported
    if ($problem) {
        Write-Host ''
        Write-Host ('  aiznm CLEANER cannot run: ' + $problem) -ForegroundColor Red
        Write-Host '  Nothing was changed.'
        $global:AIZNM_EXIT = 64
        return
    }
    Initialize-Console
    try {
        [void](Get-Anchors)
        Show-MainMenu
        Clear-ScreenSafe
        Write-UI ''
        Write-UI ('  Thanks for using {0}. Reports are kept in %LOCALAPPDATA%\aiznm_CLEANER\Logs.' -f $script:EditionTitle) Cyan
        Write-UI ''
    } catch {
        $global:AIZNM_EXIT = 1
        Write-UI ''
        Write-UI ('  Unexpected error: ' + $_.Exception.Message) Red
        if ($_.InvocationInfo) { Write-UI ('  At line {0}: {1}' -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim()) DarkGray }
        Write-UI '  Any cleanup that was running stopped at a safe point. Check the latest report under [9].' Yellow
        Wait-AnyKey 'Press any key to close...'
    } finally {
        Restore-Console
    }
}

switch ([string]$env:AIZNM_MODE) {
    'library'  { $global:AIZNM_EXIT = 0 }
    'elevated' {
        $problem = Test-RuntimeSupported
        if ($problem) { Write-Host ('  ' + $problem) -ForegroundColor Red; $global:AIZNM_EXIT = 64; Start-Sleep -Seconds 6 }
        else { Invoke-ElevatedEntry }
    }
    default    { Start-Interactive }
}
