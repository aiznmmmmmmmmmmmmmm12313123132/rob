
# -----------------------------------------------------------------------------
# 3. Native helper (compiled on first use with the C# compiler that ships with
#    .NET Framework; nothing is downloaded). Written for C# 5.
#    - DeleteSecure: opens the file/empty folder ONCE, proves through that same
#      handle that it is not a link and that its real (final) path is inside
#      the approved folder, then marks that handle for deletion. A junction
#      swapped in at the last moment therefore cannot redirect a delete.
#    - QueryRecycleBin: SHQueryRecycleBinW (size and item count, read-only).
#    - GetDisplays: current resolution/refresh per monitor (read-only).
# -----------------------------------------------------------------------------
$script:NativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class AiznmNativeV3
{
    public const int Deleted = 0, Vanished = 1, InUse = 2, Denied = 3, Reparse = 4, Outside = 5,
                     HardLinked = 6, NotEmpty = 7, Other = 8, ReadOnly = 9;

    const uint DELETE = 0x00010000;
    const uint FILE_READ_ATTRIBUTES = 0x0080;
    const uint FILE_WRITE_ATTRIBUTES = 0x0100;
    const uint SYNCHRONIZE = 0x00100000;
    const uint FILE_SHARE_ALL = 0x7;
    const uint OPEN_EXISTING = 3;
    const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    const uint ATTR_READONLY = 0x1, ATTR_DIRECTORY = 0x10, ATTR_NORMAL = 0x80, ATTR_REPARSE = 0x400;
    const uint ATTR_SETTABLE = 0x31A7;

    [StructLayout(LayoutKind.Sequential)]
    struct FILETIME_ { public uint Low; public uint High; }

    [StructLayout(LayoutKind.Sequential)]
    struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public FILETIME_ CreationTime;
        public FILETIME_ LastAccessTime;
        public FILETIME_ LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct FILE_BASIC_INFO
    {
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public long ChangeTime;
        public uint FileAttributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct FILE_DISPOSITION_INFO { [MarshalAs(UnmanagedType.U1)] public bool DeleteFile; }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle hFile, out BY_HANDLE_FILE_INFORMATION info);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle hFile, StringBuilder buffer, uint cchBuffer, uint flags);

    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "SetFileInformationByHandle")]
    static extern bool SetDisposition(SafeFileHandle hFile, int infoClass, ref FILE_DISPOSITION_INFO info, uint size);

    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "SetFileInformationByHandle")]
    static extern bool SetBasicInfo(SafeFileHandle hFile, int infoClass, ref FILE_BASIC_INFO info, uint size);

    static string LongPath(string p)
    {
        if (p.StartsWith(@"\\?\")) return p;
        if (p.Length >= 240) return @"\\?\" + p;
        return p;
    }

    static string FinalPath(SafeFileHandle h)
    {
        StringBuilder sb = new StringBuilder(1024);
        uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
        if (n == 0) return null;
        if (n >= sb.Capacity)
        {
            sb = new StringBuilder((int)n + 2);
            n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
            if (n == 0 || n >= sb.Capacity) return null;
        }
        string s = sb.ToString();
        if (s.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) return null;
        if (s.StartsWith(@"\\?\")) s = s.Substring(4);
        return s;
    }

    public static string GetFinalPath(string path, bool directory)
    {
        uint flags = directory ? FILE_FLAG_BACKUP_SEMANTICS : 0;
        using (SafeFileHandle h = CreateFileW(LongPath(path), FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero))
        {
            if (h.IsInvalid) return null;
            return FinalPath(h);
        }
    }

    static int MapError(int err)
    {
        switch (err)
        {
            case 2: case 3: return Vanished;
            case 32: case 33: return InUse;
            case 5: return Denied;
            case 145: return NotEmpty;
            default: return Other;
        }
    }

    public static int DeleteSecure(string path, string rootFinal, bool isDirectory, bool allowReadOnly, out long size, out int win32Error)
    {
        size = 0;
        win32Error = 0;
        if (string.IsNullOrEmpty(rootFinal) || string.IsNullOrEmpty(path)) return Outside;
        uint access = DELETE | FILE_READ_ATTRIBUTES | SYNCHRONIZE;
        if (allowReadOnly) access |= FILE_WRITE_ATTRIBUTES;
        uint flags = FILE_FLAG_OPEN_REPARSE_POINT | (isDirectory ? FILE_FLAG_BACKUP_SEMANTICS : 0);
        using (SafeFileHandle h = CreateFileW(LongPath(path), access, FILE_SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero))
        {
            if (h.IsInvalid) { win32Error = Marshal.GetLastWin32Error(); return MapError(win32Error); }
            BY_HANDLE_FILE_INFORMATION info;
            if (!GetFileInformationByHandle(h, out info)) { win32Error = Marshal.GetLastWin32Error(); return Other; }
            if ((info.FileAttributes & ATTR_REPARSE) != 0) return Reparse;
            bool isDir = (info.FileAttributes & ATTR_DIRECTORY) != 0;
            if (isDir != isDirectory) return Other;
            if (!isDir && info.NumberOfLinks > 1) return HardLinked;
            string fin = FinalPath(h);
            string root = rootFinal.TrimEnd('\\') + "\\";
            if (fin == null || !fin.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return Outside;
            if (!isDir) size = (((long)info.FileSizeHigh) << 32) | info.FileSizeLow;
            bool clearedReadOnly = false;
            if ((info.FileAttributes & ATTR_READONLY) != 0)
            {
                if (!allowReadOnly) return ReadOnly;
                FILE_BASIC_INFO b = new FILE_BASIC_INFO();
                uint attrs = (info.FileAttributes & ATTR_SETTABLE) & ~ATTR_READONLY;
                b.FileAttributes = attrs == 0 ? ATTR_NORMAL : attrs;
                if (!SetBasicInfo(h, 0, ref b, (uint)Marshal.SizeOf(typeof(FILE_BASIC_INFO))))
                {
                    win32Error = Marshal.GetLastWin32Error();
                    return Denied;
                }
                clearedReadOnly = true;
            }
            FILE_DISPOSITION_INFO d = new FILE_DISPOSITION_INFO();
            d.DeleteFile = true;
            if (!SetDisposition(h, 4, ref d, 1))
            {
                win32Error = Marshal.GetLastWin32Error();
                if (clearedReadOnly)
                {
                    FILE_BASIC_INFO r = new FILE_BASIC_INFO();
                    r.FileAttributes = info.FileAttributes & ATTR_SETTABLE;
                    SetBasicInfo(h, 0, ref r, (uint)Marshal.SizeOf(typeof(FILE_BASIC_INFO)));
                }
                return MapError(win32Error);
            }
            return Deleted;
        }
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    struct RBINFO64 { public int cbSize; public long Size; public long Items; }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct RBINFO32 { public int cbSize; public long Size; public long Items; }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHQueryRecycleBinW")]
    static extern int QueryRB64(string root, ref RBINFO64 info);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHQueryRecycleBinW")]
    static extern int QueryRB32(string root, ref RBINFO32 info);

    public static long[] QueryRecycleBin(string root)
    {
        if (IntPtr.Size == 8)
        {
            RBINFO64 i = new RBINFO64();
            i.cbSize = Marshal.SizeOf(typeof(RBINFO64));
            int hr = QueryRB64(root, ref i);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);
            return new long[] { i.Size, i.Items };
        }
        RBINFO32 j = new RBINFO32();
        j.cbSize = Marshal.SizeOf(typeof(RBINFO32));
        int hr2 = QueryRB32(root, ref j);
        if (hr2 != 0) Marshal.ThrowExceptionForHR(hr2);
        return new long[] { j.Size, j.Items };
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplayDevicesW(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplaySettingsW(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);

    public class DisplayInfo
    {
        public string Device; public string Adapter; public string Monitor; public string MonitorId;
        public bool Primary; public int Width; public int Height; public int Hz; public int Bpp;
        public int MaxHzAtCurrent; public int MaxWidth; public int MaxHeight;
    }

    public static List<DisplayInfo> GetDisplays()
    {
        List<DisplayInfo> list = new List<DisplayInfo>();
        for (uint i = 0; i < 32; i++)
        {
            DISPLAY_DEVICE ad = new DISPLAY_DEVICE();
            ad.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (!EnumDisplayDevicesW(null, i, ref ad, 0)) break;
            if ((ad.StateFlags & 0x1) == 0) continue;
            DisplayInfo d = new DisplayInfo();
            d.Device = ad.DeviceName;
            d.Adapter = ad.DeviceString;
            d.Primary = (ad.StateFlags & 0x4) != 0;
            DISPLAY_DEVICE mon = new DISPLAY_DEVICE();
            mon.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            if (EnumDisplayDevicesW(ad.DeviceName, 0, ref mon, 0x1)) { d.Monitor = mon.DeviceString; d.MonitorId = mon.DeviceID; }
            DEVMODE dm = new DEVMODE();
            dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            if (EnumDisplaySettingsW(ad.DeviceName, -1, ref dm))
            {
                d.Width = dm.dmPelsWidth; d.Height = dm.dmPelsHeight; d.Hz = dm.dmDisplayFrequency; d.Bpp = dm.dmBitsPerPel;
            }
            for (int m = 0; m < 5000; m++)
            {
                DEVMODE x = new DEVMODE();
                x.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
                if (!EnumDisplaySettingsW(ad.DeviceName, m, ref x)) break;
                if (x.dmPelsWidth == d.Width && x.dmPelsHeight == d.Height && x.dmDisplayFrequency > d.MaxHzAtCurrent) d.MaxHzAtCurrent = x.dmDisplayFrequency;
                if ((long)x.dmPelsWidth * x.dmPelsHeight > (long)d.MaxWidth * d.MaxHeight) { d.MaxWidth = x.dmPelsWidth; d.MaxHeight = x.dmPelsHeight; }
            }
            list.Add(d);
        }
        return list;
    }
}
'@

$script:NativeState = $null
$script:NativeError = $null
$script:NativeCodeNames = @('Deleted', 'Vanished', 'InUse', 'Denied', 'Reparse', 'Outside', 'HardLinked', 'NotEmpty', 'Other', 'ReadOnly')
$script:UseNativeDelete = $false

function Initialize-Native {
    if ($null -ne $script:NativeState) { return $script:NativeState }
    if (-not $script:OnWindows) {
        $script:NativeState = $false
        $script:NativeError = 'Native helper is only available on Windows.'
        return $false
    }
    if ('AiznmNativeV3' -as [type]) { $script:NativeState = $true; return $true }
    try {
        Add-Type -TypeDefinition $script:NativeSource -Language CSharp -ErrorAction Stop
        $script:NativeState = $true
    } catch {
        $script:NativeState = $false
        $script:NativeError = $_.Exception.Message
    }
    return $script:NativeState
}

function Set-DeleteMode {
    # Chooses how files are deleted for this process. Elevated work insists on
    # the handle-verified native method; if it is unavailable, admin cleanup is
    # refused rather than done in a weaker way.
    if (Initialize-Native) { $script:UseNativeDelete = $true; return @{ Ok = $true; Mode = 'verified handle delete' } }
    $script:UseNativeDelete = $false
    if (Test-IsAdmin) {
        return @{ Ok = $false; Mode = 'none'; Reason = 'The verified-delete helper could not be loaded (' + $script:NativeError + '). Administrator cleanup is refused.' }
    }
    return @{ Ok = $true; Mode = 'managed delete with link checks' }
}

# -----------------------------------------------------------------------------
# 4. File engine. The SAME function performs the dry-run scan and the clean,
#    so the preview and the deletion always use identical rules.
# -----------------------------------------------------------------------------
function New-WalkStats {
    return @{
        TotalFiles = [long]0; TotalBytes = [long]0
        EligibleFiles = [long]0; EligibleBytes = [long]0
        RecentFiles = [long]0; RecentBytes = [long]0
        PendingSkipped = [long]0; ReparseSkipped = [long]0; LinkSkipped = [long]0
        InaccessibleDirs = [long]0; RootUnreadable = $false
        Deleted = [long]0; DeletedBytes = [long]0
        InUse = [long]0; InUseBytes = [long]0
        Denied = [long]0; DeniedBytes = [long]0
        Other = [long]0; OtherBytes = [long]0
        Vanished = [long]0; Outside = [long]0
        DirsRemoved = [long]0
        Cancelled = $false
        Samples = @{}
    }
}

function Merge-WalkStats {
    param([hashtable]$Into, [hashtable]$From)
    foreach ($k in @($From.Keys)) {
        if ($k -eq 'Samples') {
            foreach ($sk in @($From.Samples.Keys)) {
                foreach ($s in @($From.Samples[$sk])) { Add-Sample $Into $sk $s }
            }
        }
        elseif ($From[$k] -is [bool]) { $Into[$k] = [bool]$Into[$k] -or $From[$k] }
        else { $Into[$k] = [long]$Into[$k] + [long]$From[$k] }
    }
}

function Add-Sample {
    param([hashtable]$Stats, [string]$Kind, [string]$Text)
    if (-not $Stats.Samples.ContainsKey($Kind)) { $Stats.Samples[$Kind] = @() }
    if (@($Stats.Samples[$Kind]).Count -lt $script:Policy.SampleLimit) { $Stats.Samples[$Kind] = @($Stats.Samples[$Kind]) + $Text }
}

function Get-IoErrorKind {
    param([Exception]$Exception)
    $ex = $Exception
    while ($ex -is [System.Management.Automation.RuntimeException] -and $null -ne $ex.InnerException) { $ex = $ex.InnerException }
    if ($ex -is [UnauthorizedAccessException]) { return 'Denied' }
    if ($ex -is [IO.FileNotFoundException] -or $ex -is [IO.DirectoryNotFoundException]) { return 'Vanished' }
    if ($ex -is [IO.PathTooLongException]) { return 'Other' }
    if ($ex -is [IO.IOException]) {
        $code = $ex.HResult -band 0xFFFF
        if ($code -eq 32 -or $code -eq 33) { return 'InUse' }
        if ($code -eq 145) { return 'NotEmpty' }
        return 'Other'
    }
    return 'Other'
}

function Get-InnerMessage {
    param([Exception]$Exception)
    $ex = $Exception
    while ($ex -is [System.Management.Automation.RuntimeException] -and $null -ne $ex.InnerException) { $ex = $ex.InnerException }
    return $ex.Message
}

function Invoke-FileDelete {
    # Deletes ONE file (or one empty folder). Never recursive. Returns
    # @{ Kind; Size; Detail }. Tests replace this function to simulate
    # locked or protected files without touching real files.
    param([string]$Path, [string]$RootFinal, [bool]$IsDirectory)
    if ($script:UseNativeDelete) {
        $size = [long]0
        $err = 0
        $code = [AiznmNativeV3]::DeleteSecure($Path, $RootFinal, $IsDirectory, $false, [ref]$size, [ref]$err)
        if ($code -eq 9) { $code = [AiznmNativeV3]::DeleteSecure($Path, $RootFinal, $IsDirectory, $true, [ref]$size, [ref]$err) }
        $detail = ''
        if ($err -ne 0) { $detail = (New-Object ComponentModel.Win32Exception($err)).Message }
        return @{ Kind = $script:NativeCodeNames[$code]; Size = [long]$size; Detail = $detail }
    }
    try {
        if ($IsDirectory) {
            $di = New-Object IO.DirectoryInfo($Path)
            $di.Refresh()
            if (-not $di.Exists) { return @{ Kind = 'Vanished'; Size = [long]0; Detail = '' } }
            if (($di.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return @{ Kind = 'Reparse'; Size = [long]0; Detail = '' } }
            if ($di.Parent -and (($di.Parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return @{ Kind = 'Outside'; Size = [long]0; Detail = 'parent became a link' } }
            $di.Delete()
            return @{ Kind = 'Deleted'; Size = [long]0; Detail = '' }
        }
        $fi = New-Object IO.FileInfo($Path)
        $fi.Refresh()
        if (-not $fi.Exists) { return @{ Kind = 'Vanished'; Size = [long]0; Detail = '' } }
        if (($fi.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return @{ Kind = 'Reparse'; Size = [long]0; Detail = '' } }
        $parent = $fi.Directory
        $parent.Refresh()
        if (($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return @{ Kind = 'Outside'; Size = [long]0; Detail = 'parent became a link' } }
        $size = [long]$fi.Length
        $ro = $fi.IsReadOnly
        if ($ro) { $fi.IsReadOnly = $false }
        try { $fi.Delete() }
        catch {
            if ($ro) { try { $fi.IsReadOnly = $true } catch { } }
            throw
        }
        return @{ Kind = 'Deleted'; Size = $size; Detail = '' }
    } catch {
        return @{ Kind = (Get-IoErrorKind $_.Exception); Size = [long]0; Detail = (Get-InnerMessage $_.Exception) }
    }
}

function Add-DeleteOutcome {
    param([hashtable]$Stats, [hashtable]$Outcome, [string]$Path, [long]$Length)
    $shown = Format-PathForLog $Path
    switch ($Outcome.Kind) {
        'Deleted'    { $Stats.Deleted += 1; $sz = $Outcome.Size; if ($sz -le 0) { $sz = $Length }; $Stats.DeletedBytes += $sz }
        'Vanished'   { $Stats.Vanished += 1 }
        'InUse'      { $Stats.InUse += 1; $Stats.InUseBytes += $Length; Add-Sample $Stats 'In use' $shown }
        'Denied'     { $Stats.Denied += 1; $Stats.DeniedBytes += $Length; Add-Sample $Stats 'Access denied' $shown }
        'ReadOnly'   { $Stats.Denied += 1; $Stats.DeniedBytes += $Length; Add-Sample $Stats 'Access denied' ($shown + ' (read-only)') }
        'Reparse'    { $Stats.ReparseSkipped += 1 }
        'HardLinked' { $Stats.LinkSkipped += 1 }
        'Outside'    { $Stats.Outside += 1; Add-Sample $Stats 'Refused (outside approved folder)' $shown }
        default      { $Stats.Other += 1; $Stats.OtherBytes += $Length; Add-Sample $Stats 'Other error' ($shown + ' - ' + $Outcome.Detail) }
    }
}

function Invoke-TargetWalk {
    # Scans (default) or cleans (-Delete) one validated target.
    #   Tree       : every file below the folder (optionally recursive)
    #   Files      : only files whose name matches NamePattern
    #   SingleFile : exactly one file
    # Junctions/symbolic links are never followed or deleted. Files younger
    # than MinAgeHours (newest of creation / last-write time) are kept.
    param([hashtable]$Spec, [hashtable]$Stats, [switch]$Delete, [hashtable]$Exclusions = $null, [string]$Label = '')
    if (-not $Spec.Valid -or -not $Spec.Exists) { return }
    $cutoff = [DateTime]::MaxValue
    if ($Spec.MinAgeHours -gt 0) { $cutoff = [DateTime]::UtcNow.AddHours(-1 * $Spec.MinAgeHours) }

    $rootDir = $Spec.Path
    if ($Spec.Kind -eq 'SingleFile') { $rootDir = Split-Path -Parent $Spec.Path }
    $rootFinal = $null
    if ($Delete -and $script:UseNativeDelete) {
        $rootFinal = [AiznmNativeV3]::GetFinalPath($rootDir, $true)
        if (-not $rootFinal) {
            $Stats.RootUnreadable = $true
            Add-Sample $Stats 'Refused (outside approved folder)' ((Format-PathForLog $rootDir) + ' - physical location could not be confirmed')
            return
        }
    }

    $verb = 'Scanning'
    if ($Delete) { $verb = 'Cleaning' }
    $seen = 0
    $dirsVisited = New-Object 'System.Collections.Generic.List[string]'
    $dirCreated = @{}
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $singleFile = ($Spec.Kind -eq 'SingleFile')
    $stack.Push($rootDir)
    $stop = $false

    while ($stack.Count -gt 0 -and -not $stop) {
        if (Test-CancelKey) { $Stats.Cancelled = $true; break }
        $dirPath = $stack.Pop()
        $isRoot = Test-SamePath $dirPath $rootDir
        $entries = $null
        try {
            $di = New-Object IO.DirectoryInfo($dirPath)
            $di.Refresh()
            if (-not $di.Exists) { continue }
            if (($di.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $Stats.ReparseSkipped += 1; continue }
            if ($singleFile) { $entries = @(New-Object IO.FileInfo($Spec.Path)) }
            else { $entries = $di.GetFileSystemInfos() }
        } catch {
            if ($isRoot) { $Stats.RootUnreadable = $true }
            else { $Stats.InaccessibleDirs += 1 }
            Add-Sample $Stats 'Folder could not be read' ((Format-PathForLog $dirPath) + ' - ' + (Get-InnerMessage $_.Exception))
            continue
        }
        if (-not $isRoot) { $dirsVisited.Add($dirPath); $dirCreated[$dirPath] = $di.CreationTimeUtc }

        foreach ($e in $entries) {
            $seen++
            if (($seen % 250) -eq 0) {
                if (Test-CancelKey) { $Stats.Cancelled = $true; $stop = $true; break }
                if ($Delete) { Write-ProgressLine ('{0} {1}: {2} files checked, {3} deleted' -f $verb, $Label, (Format-Count $seen), (Format-Count $Stats.Deleted)) }
                else { Write-ProgressLine ('{0} {1}: {2} files checked' -f $verb, $Label, (Format-Count $seen)) }
            }
            try {
                if ($singleFile) { $e.Refresh(); if (-not $e.Exists) { continue } }
                $full = $e.FullName
                if (-not (Test-PathUnder $full $rootDir)) { $Stats.Outside += 1; continue }
                if (($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $Stats.ReparseSkipped += 1; continue }
                if ($e -is [IO.DirectoryInfo]) {
                    if ($Spec.Recurse -and -not $singleFile) { $stack.Push($full) }
                    continue
                }
                if ($Spec.NamePattern -and ($e.Name -notmatch $Spec.NamePattern)) { continue }
                $len = [long]$e.Length
                $Stats.TotalFiles += 1
                $Stats.TotalBytes += $len
                if (Test-Excluded $full $Exclusions) { $Stats.PendingSkipped += 1; continue }
                $newest = $e.LastWriteTimeUtc
                if ($e.CreationTimeUtc -gt $newest) { $newest = $e.CreationTimeUtc }
                if ($newest -gt $cutoff) { $Stats.RecentFiles += 1; $Stats.RecentBytes += $len; continue }
                $Stats.EligibleFiles += 1
                $Stats.EligibleBytes += $len
                if ($Delete) {
                    $outcome = Invoke-FileDelete -Path $full -RootFinal $rootFinal -IsDirectory $false
                    Add-DeleteOutcome $Stats $outcome $full $len
                }
            } catch {
                $Stats.Other += 1
                Add-Sample $Stats 'Other error' ((Format-PathForLog ([string]$e.FullName)) + ' - ' + (Get-InnerMessage $_.Exception))
            }
        }
    }

    # Remove folders that are now empty (deepest first). Only folders this run
    # actually walked, never the target folder itself, never recent folders.
    if ($Delete -and $Spec.RemoveEmptyDirs -and -not $Stats.Cancelled -and -not $singleFile) {
        $ordered = @($dirsVisited | Sort-Object -Property Length -Descending)
        foreach ($d in $ordered) {
            try {
                $leaf = Split-Path -Leaf $d
                if (@($Spec.KeepDirNames) -contains $leaf) { continue }
                $di = New-Object IO.DirectoryInfo($d)
                $di.Refresh()
                if (-not $di.Exists) { continue }
                if (($di.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                # Age as it was when the walk started (our own deletions must not make a folder look new).
                $created = $di.CreationTimeUtc
                if ($dirCreated.ContainsKey($d)) { $created = $dirCreated[$d] }
                if ($created -gt $cutoff) { continue }
                if (@($di.GetFileSystemInfos()).Count -gt 0) { continue }
                $o = Invoke-FileDelete -Path $d -RootFinal $rootFinal -IsDirectory $true
                if ($o.Kind -eq 'Deleted') { $Stats.DirsRemoved += 1 }
            } catch { }
        }
    }
}

function Get-CleanStatus {
    # Turns counts into an honest status. Files kept because they are recent
    # or in use are expected; access-denied/other errors are problems.
    param([hashtable]$Stats)
    $problems = [long]$Stats.Denied + [long]$Stats.Other + [long]$Stats.Outside
    if ($Stats.Cancelled) { return 'Cancelled' }
    if ($Stats.RootUnreadable -and $Stats.Deleted -eq 0) { return 'Failed' }
    $skips = [long]$Stats.InUse + [long]$Stats.InaccessibleDirs
    if ($problems -eq 0 -and $skips -eq 0 -and -not $Stats.RootUnreadable) { return 'Completed' }
    if ($problems -eq 0 -and -not $Stats.RootUnreadable) { return 'Completed with skipped files' }
    if ($Stats.Deleted -gt 0) { return 'Partially completed' }
    return 'Failed'
}
