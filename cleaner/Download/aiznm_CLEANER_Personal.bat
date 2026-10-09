@echo off
setlocal EnableExtensions DisableDelayedExpansion
rem ===========================================================================
rem  aiznm CLEANER 3.1.0  -  safe, transparent storage maintenance
rem  Personal edition for one documented Windows 10 Home 22H2 PC, Windows PowerShell 5.1
rem
rem  HOW THIS FILE IS BUILT
rem    Part 1 (this short CMD section) only starts Windows PowerShell 5.1.
rem    Part 2 (everything after the PS_BEGIN marker line further down) is a
rem    normal PowerShell program. PowerShell reads this same file, takes the
rem    text after the marker and runs it. CMD never parses Part 2, because
rem    Part 1 always ends with "exit /b" before CMD reaches it.
rem
rem    Nothing is downloaded, no files are extracted, and no system settings
rem    are changed. "-ExecutionPolicy Bypass" applies to this one PowerShell
rem    process only (Process scope); it is needed because Windows 10's default
rem    "Restricted" policy blocks Windows' own DeliveryOptimization module.
rem
rem  ADMINISTRATOR RIGHTS
rem    The menu, scans, reports and inventory run as a normal user. Only when
rem    you confirm a cleanup that includes an administrator-only category does
rem    the program ask Windows (UAC) to start a second, visible copy of this
rem    file with three arguments after --elevated: the action (scan or
rem    clean), the category ids joined with "+" (CMD splits arguments at
rem    commas) and the result-file path, each quoted where needed.
rem
rem  CHANGE LOG
rem    3.1.0  2026-10-09  Personal and Universal editions from one code base.
rem                       AMD, Intel and newer NVIDIA shader-cache folders,
rem                       Vivaldi, Opera and Opera GX caches, Windows 11,
rem                       read-only health check and startup-program list,
rem                       compact selection screens.
rem    3.0.0  2026-10-09  Complete rewrite of v2.0. Least privilege, preview
rem                       before deletion, measured before/after free space,
rem                       per-category results, logs, no forced closing of
rem                       browsers or Explorer, no service stop/start, shader
rem                       caches, dumps and Recycle Bin made opt-in only.
rem    2.0    (original)  Single elevated "clean everything" script.
rem ===========================================================================

title aiznm CLEANER
set "AIZNM_SELF=%~f0"
set "AIZNM_MODE=interactive"
set "AIZNM_ELEV_ACTION="
set "AIZNM_ELEV_TASKS="
set "AIZNM_ELEV_RESULT="

if /i not "%~1"=="--elevated" goto :aiznm_run
set "AIZNM_MODE=elevated"
set "AIZNM_ELEV_ACTION=%~2"
set "AIZNM_ELEV_TASKS=%~3"
set "AIZNM_ELEV_RESULT=%~4"
title aiznm CLEANER - administrator task

:aiznm_run
rem Always use the 64-bit Windows PowerShell 5.1 by absolute path.
set "AIZNM_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "AIZNM_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if exist "%AIZNM_PS%" goto :aiznm_start
echo.
echo  aiznm CLEANER could not find Windows PowerShell 5.1 at:
echo    %AIZNM_PS%
echo  Windows PowerShell is part of Windows 10. Nothing was changed.
echo.
pause
endlocal & exit /b 9009

:aiznm_start
"%AIZNM_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { $t=[IO.File]::ReadAllText($env:AIZNM_SELF); $m='#'+'#AIZNM_PS_BEGIN##'; $i=$t.IndexOf($m); if ($i -lt 0) { throw 'The PowerShell section of this file is missing or damaged.' }; $global:AIZNM_EXIT=1; . ([ScriptBlock]::Create($t.Substring($i))); exit [int]$global:AIZNM_EXIT } catch { Write-Host ''; Write-Host (' aiznm CLEANER could not start: ' + $_.Exception.Message) -ForegroundColor Red; Write-Host ' Nothing was changed.'; exit 70 }"
set "AIZNM_RC=%ERRORLEVEL%"
if /i "%AIZNM_MODE%"=="interactive" if not "%AIZNM_RC%"=="0" (
    echo.
    echo  aiznm CLEANER ended with exit code %AIZNM_RC%. See the message above.
    pause
)
endlocal & exit /b %AIZNM_RC%
##AIZNM_PS_BEGIN##
# =============================================================================
#  aiznm CLEANER - PowerShell section
#  Runs on Windows PowerShell 5.1 (Windows 10). Started by the CMD section at
#  the top of this file. Plain ASCII on purpose: no code page surprises.
#
#  Layout of this section
#    1. Settings, formatting and console helpers
#    2. Logging, trusted folder anchors and path validation
#    3. Native helper (secure delete, Recycle Bin size, display modes)
#    4. File engine (scan = dry run, clean = same rules + delete)
#    5. Cleanup categories and their handlers
#    6. Elevation broker, cleanup flow and before/after report
#    7. System overview, inventory, reports, Windows tools, main menu
# =============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$strictLevel = '1.0'
if ($env:AIZNM_STRICT -eq 'latest') { $strictLevel = 'Latest' }
Set-StrictMode -Version $strictLevel

# -----------------------------------------------------------------------------
# 1. Settings
# -----------------------------------------------------------------------------
$script:AppName    = 'aiznm CLEANER'
$script:AppVersion = '3.1.0'
$script:AppDate    = '2026-10-09'
$script:OnWindows  = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
$script:Sep        = [IO.Path]::DirectorySeparatorChar
$script:CancelRequested = $false
$script:QuietUi    = $false
$script:IsElevatedChild = $false
$script:UiWidth    = 96
$script:ProgressWatch = [Diagnostics.Stopwatch]::StartNew()
$script:ProgressShown = $false
# Keys used for category rows. R, S and X are reserved for commands.
$script:RowKeys    = 'ABCDEFGHIJKLMNOPQTUVWYZ'

# Conservative cleanup policy. Changing these values changes what is eligible.
$script:Policy = @{
    UserTempMinAgeHours = 24     # user Temp: keep anything created/changed in the last 24 h
    WinTempMinAgeHours  = 168    # Windows Temp: Microsoft's Disk Cleanup rule (older than one week)
    DumpMinAgeDays      = 14     # crash dumps / error reports: keep the last two weeks for diagnosis
    LogKeepCount        = 40     # newest log files kept
    LogKeepDays         = 90     # log files older than this are removed (own log folder only)
    SampleLimit         = 5      # example paths per error type kept in the log
}

# -----------------------------------------------------------------------------
# Formatting helpers
# -----------------------------------------------------------------------------
function Format-Bytes {
    param([object]$Bytes, [switch]$Signed)
    if ($null -eq $Bytes) { return 'unknown' }
    [double]$b = [double]$Bytes
    $sign = ''
    if ($b -lt 0) { $sign = '-'; $b = -$b }
    elseif ($Signed -and $b -gt 0) { $sign = '+' }
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $i = 0
    while ($b -ge 1024 -and $i -lt 4) { $b = $b / 1024; $i++ }
    if ($i -eq 0) { return ('{0}{1:N0} B' -f $sign, $b) }
    if ($b -ge 100) { return ('{0}{1:N0} {2}' -f $sign, $b, $units[$i]) }
    if ($b -ge 10)  { return ('{0}{1:N1} {2}' -f $sign, $b, $units[$i]) }
    return ('{0}{1:N2} {2}' -f $sign, $b, $units[$i])
}

function Format-Count {
    param([object]$Value)
    if ($null -eq $Value) { return '?' }
    return ('{0:N0}' -f [long]$Value)
}

function Format-Duration {
    param([TimeSpan]$Span)
    if ($Span.TotalHours -ge 1) { return ('{0}h {1:D2}m {2:D2}s' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds) }
    if ($Span.TotalMinutes -ge 1) { return ('{0}m {1:D2}s' -f $Span.Minutes, $Span.Seconds) }
    return ('{0:N1}s' -f $Span.TotalSeconds)
}

function Get-Fit {
    # Shortens text to a width ("text..."). -Middle keeps the start and end,
    # which suits long paths.
    param([string]$Text, [int]$Width, [switch]$Middle)
    if ($null -eq $Text) { $Text = '' }
    if ($Width -lt 4) { return $Text.Substring(0, [Math]::Min($Text.Length, [Math]::Max(0, $Width))) }
    if ($Text.Length -le $Width) { return $Text }
    $keep = $Width - 3
    if (-not $Middle) { return $Text.Substring(0, $keep).TrimEnd() + '...' }
    $head = [int][Math]::Ceiling($keep * 0.45)
    $tail = $keep - $head
    return $Text.Substring(0, $head) + '...' + $Text.Substring($Text.Length - $tail)
}

function Format-Cell {
    param([string]$Text, [int]$Width, [string]$Align = 'Left')
    $t = Get-Fit $Text $Width
    if ($Align -eq 'Right') { return $t.PadLeft($Width) }
    return $t.PadRight($Width)
}

# -----------------------------------------------------------------------------
# Console helpers
# -----------------------------------------------------------------------------
function Get-ConsoleWidth {
    try { $w = [Console]::WindowWidth; if ($w -gt 20) { return $w } } catch { }
    return 100
}

function Write-UI {
    param([string]$Text = '', [ConsoleColor]$Color = [ConsoleColor]::Gray, [switch]$NoNewline)
    if ($script:QuietUi) { return }
    Clear-ProgressLine
    if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline }
    else { Write-Host $Text -ForegroundColor $Color }
}

function Write-Segments {
    # Writes one line made of coloured pieces: @( @('text', 'Color'), ... )
    param([object[]]$Parts)
    if ($script:QuietUi) { return }
    Clear-ProgressLine
    foreach ($p in $Parts) { Write-Host ([string]$p[0]) -ForegroundColor ([ConsoleColor]$p[1]) -NoNewline }
    Write-Host ''
}

function Write-Rule {
    param([string]$Char = '-', [ConsoleColor]$Color = [ConsoleColor]::DarkGray)
    Write-UI ('  ' + ($Char * $script:UiWidth)) $Color
}

function Write-Section {
    param([string]$Title)
    Write-UI ''
    Write-UI ('  ' + $Title.ToUpperInvariant()) Cyan
    Write-UI ('  ' + ('-' * [Math]::Min($script:UiWidth, $Title.Length))) DarkCyan
}

function Write-KeyValue {
    param([string]$Key, [string]$Value, [ConsoleColor]$Color = [ConsoleColor]::White, [int]$KeyWidth = 16)
    Write-Segments @(@(('  ' + $Key.PadRight($KeyWidth)), 'DarkGray'), @($Value, $Color))
}

function Write-Wrapped {
    # Word-wraps a paragraph to the UI width with an indent.
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray, [int]$Indent = 2)
    $max = $script:UiWidth - ($Indent - 2)
    $line = ''
    foreach ($word in ($Text -split '\s+')) {
        if ($word -eq '') { continue }
        if ($line.Length -eq 0) { $line = $word }
        elseif (($line.Length + 1 + $word.Length) -le $max) { $line = $line + ' ' + $word }
        else { Write-UI ((' ' * $Indent) + $line) $Color; $line = $word }
    }
    if ($line.Length -gt 0) { Write-UI ((' ' * $Indent) + $line) $Color }
}

function Clear-ScreenSafe {
    if ($script:QuietUi -or $script:IsElevatedChild) { return }
    try { [Console]::Clear() } catch { }
}

function Show-Header {
    param([string]$Title, [string]$Subtitle = '')
    Clear-ScreenSafe
    $w = $script:UiWidth
    $left = ' {0}  v{1}' -f $script:AppName.ToUpperInvariant(), $script:AppVersion
    if ($script:EditionTag) { $left += '  ' + $script:EditionTag }
    $right = 'Safe storage maintenance '
    Write-UI ''
    Write-UI ('  ' + ('=' * $w)) DarkCyan
    Write-Segments @(@('  ', 'Gray'), @($left, 'Cyan'), @((' ' * [Math]::Max(1, $w - $left.Length - $right.Length)), 'Gray'), @($right, 'DarkGray'))
    Write-UI ('  ' + ('=' * $w)) DarkCyan
    Write-Segments @(@('  ', 'Gray'), @((' ' + $Title), 'White'))
    if ($Subtitle) { Write-Segments @(@('  ', 'Gray'), @((' ' + $Subtitle), 'DarkGray')) }
    Write-Rule
}

function Write-StatusTag {
    # Returns the colour used for a result status.
    param([string]$Status)
    switch -Regex ($Status) {
        '^Completed$'            { return [ConsoleColor]::Green }
        '^Completed with'        { return [ConsoleColor]::Green }
        '^Partially'             { return [ConsoleColor]::Yellow }
        '^Skipped'               { return [ConsoleColor]::Yellow }
        '^Cancelled'             { return [ConsoleColor]::Yellow }
        '^Failed|^Refused'       { return [ConsoleColor]::Red }
        '^Not applicable'        { return [ConsoleColor]::DarkGray }
        default                  { return [ConsoleColor]::Gray }
    }
}

# Progress is a single line that is overwritten in place, throttled so that
# console output never slows the scan down.
function Write-ProgressLine {
    param([string]$Text, [switch]$Force)
    if ($script:QuietUi) { return }
    if (-not $Force -and $script:ProgressWatch.ElapsedMilliseconds -lt 150) { return }
    $script:ProgressWatch.Restart()
    $w = [Math]::Max(20, (Get-ConsoleWidth) - 2)
    $t = Get-Fit ('  ' + $Text) $w
    try { Write-Host ("`r" + $t.PadRight($w)) -NoNewline -ForegroundColor DarkGray; $script:ProgressShown = $true } catch { }
}

function Clear-ProgressLine {
    if (-not $script:ProgressShown) { return }
    $script:ProgressShown = $false
    $w = [Math]::Max(20, (Get-ConsoleWidth) - 2)
    try { Write-Host ("`r" + (' ' * $w) + "`r") -NoNewline } catch { }
}

# -----------------------------------------------------------------------------
# Keyboard input. Ctrl+C is read as a key (TreatControlCAsInput), so pressing
# it never kills the program half-way through a deletion: it is handled as
# "cancel / back" at a safe point instead.
# -----------------------------------------------------------------------------
function Test-IsCancelKey {
    param([ConsoleKeyInfo]$Key)
    if ($Key.Key -eq [ConsoleKey]::Escape) { return $true }
    if ($Key.Key -eq [ConsoleKey]::C -and (($Key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) { return $true }
    if ([int]$Key.KeyChar -eq 3) { return $true }
    return $false
}

function Clear-KeyBuffer {
    try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }
}

function Test-CancelKey {
    # Non-blocking check used inside long loops. Esc or Ctrl+C requests a stop.
    if ($script:CancelRequested) { return $true }
    if ($script:QuietUi) { return $false }
    try {
        while ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if (Test-IsCancelKey $k) { $script:CancelRequested = $true }
        }
    } catch { }
    return $script:CancelRequested
}

function Read-Choice {
    # Waits for one of the allowed keys. Returns the upper-case character,
    # 'ENTER' or 'ESC'.
    param([string[]]$Valid, [switch]$AllowEnter, [switch]$AllowEscape)
    Clear-KeyBuffer
    while ($true) {
        $k = $null
        try { $k = [Console]::ReadKey($true) }
        catch {
            $line = Read-Host
            if ($null -eq $line -or $line -eq '') { if ($AllowEnter) { return 'ENTER' } else { continue } }
            $c = $line.Trim().ToUpperInvariant()
            if ($c -eq 'ESC' -and $AllowEscape) { return 'ESC' }
            if ($Valid -contains $c) { return $c }
            continue
        }
        if (Test-IsCancelKey $k) { if ($AllowEscape) { return 'ESC' } else { continue } }
        if ($k.Key -eq [ConsoleKey]::Enter) { if ($AllowEnter) { return 'ENTER' } else { continue } }
        $c = ([string]$k.KeyChar).ToUpperInvariant()
        if ($c -ne '' -and $Valid -contains $c) { return $c }
    }
}

function Read-YesNo {
    param([string]$Prompt, [string]$Default = 'N')
    $hint = '[y/N]'
    if ($Default -eq 'Y') { $hint = '[Y/n]' }
    Write-Segments @(@(('  ' + $Prompt + ' '), 'White'), @(($hint + ' '), 'DarkGray'))
    $c = Read-Choice -Valid @('Y', 'N') -AllowEnter -AllowEscape
    if ($c -eq 'ENTER') { $c = $Default }
    if ($c -eq 'ESC') { $c = 'N' }
    return ($c -eq 'Y')
}

function Read-LineSafe {
    # Simple line editor built on ReadKey so it works while Ctrl+C is treated
    # as input. Returns $null when the user presses Esc or Ctrl+C.
    param([string]$Prompt, [int]$MaxLength = 40)
    Write-UI ('  ' + $Prompt) White -NoNewline
    Clear-KeyBuffer
    $sb = New-Object System.Text.StringBuilder
    while ($true) {
        $k = $null
        try { $k = [Console]::ReadKey($true) }
        catch { Write-UI ''; return (Read-Host) }
        if (Test-IsCancelKey $k) { Write-UI ''; return $null }
        if ($k.Key -eq [ConsoleKey]::Enter) { Write-UI ''; return $sb.ToString() }
        if ($k.Key -eq [ConsoleKey]::Backspace) {
            if ($sb.Length -gt 0) { [void]$sb.Remove($sb.Length - 1, 1); Write-Host "`b `b" -NoNewline }
            continue
        }
        $ch = $k.KeyChar
        if ([int]$ch -ge 32 -and [int]$ch -lt 127 -and $sb.Length -lt $MaxLength) {
            [void]$sb.Append($ch); Write-Host $ch -NoNewline -ForegroundColor Cyan
        }
    }
}

function Wait-AnyKey {
    param([string]$Text = 'Press any key to return to the menu...')
    if ($script:QuietUi) { return }
    Write-UI ''
    Write-UI ('  ' + $Text) DarkGray
    Clear-KeyBuffer
    try { [void][Console]::ReadKey($true) } catch { [void](Read-Host) }
}

function Initialize-Console {
    # Widen the window a little if it is narrower than the layout. Keeps a
    # large scroll-back buffer (the old script's "mode con" destroyed it).
    try {
        $raw = $Host.UI.RawUI
        $want = $script:UiWidth + 4
        $buf = $raw.BufferSize
        if ($buf.Width -lt $want) {
            $raw.BufferSize = New-Object System.Management.Automation.Host.Size ($want, [Math]::Max($buf.Height, 3000))
        }
        $win = $raw.WindowSize
        $max = $raw.MaxPhysicalWindowSize
        $newW = $win.Width
        $newH = $win.Height
        if ($win.Width -lt $want -and $max.Width -ge $want) { $newW = $want }
        # Taller window (up to 42 lines) when the screen allows it, so tables fit.
        $wantH = [Math]::Min(42, $max.Height)
        if ($win.Height -lt $wantH -and $raw.BufferSize.Height -ge $wantH) { $newH = $wantH }
        if ($newW -ne $win.Width -or $newH -ne $win.Height) {
            $raw.WindowSize = New-Object System.Management.Automation.Host.Size ($newW, $newH)
        }
    } catch { }
    $cw = Get-ConsoleWidth
    $script:UiWidth = [Math]::Max(76, [Math]::Min(96, $cw - 4))
    try { $raw = $Host.UI.RawUI; $script:OriginalTitle = $raw.WindowTitle; $raw.WindowTitle = $script:EditionTitle } catch { }
    try { [Console]::TreatControlCAsInput = $true } catch { }
}

function Restore-Console {
    try { [Console]::TreatControlCAsInput = $false } catch { }
    Clear-ProgressLine
}

# -----------------------------------------------------------------------------
# Edition profile: PERSONAL. Built for one specific PC. The documented
# baseline below is only compared with what Windows reports in System
# overview; it never changes what is cleaned.
# -----------------------------------------------------------------------------
$script:Edition      = 'Personal'
$script:EditionTitle = 'aiznm CLEANER'
$script:EditionTag   = ''
$script:Baseline = @{
    CpuText = 'Intel Core i9-10900F, 10C/20T'; CpuMatch = '10900F'; Cores = 10; Threads = 20
    BoardText = 'ASUS PRIME B560-PLUS'; BoardMatch = 'B560-PLUS'
    BiosText = '2001 (2023-02-01)'; BiosVersion = '2001'
    MemText = '16 GB (2x8) CMK16GX4M2Z3600C18, DDR4-3600'; MemTotal = 16GB; MemSticks = 2; MemPart = 'CMK16GX4M2Z3600C18'; MemSpeed = 3600
    GpuText = 'MSI GeForce RTX 4060, 8 GB'; GpuMatch = 'RTX 4060'
    OsText = 'Windows 10 Home 22H2, build 19045.6466'; OsBuild = '19045'; OsUbr = 6466
    SecureBoot = $true
    DisplaysNote = 'Documented: AOC Q27G4SDR 2560x1440 up to 360 Hz; Samsung F24G3xTF 1920x1080 (120/144 Hz unconfirmed).'
    PlatformNote = 'The B560 + i9-10900F platform provides PCIe 3.0.'
}

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
