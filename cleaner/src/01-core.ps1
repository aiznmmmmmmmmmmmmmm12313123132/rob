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
