# aiznm CLEANER 3.1.0 — Technical report

Contents

* [B. Audit of the original v2.0 script](#b-audit-of-the-original-v20-script)
* [Architecture](#architecture)
* [Editions: Personal and Universal](#editions-personal-and-universal)
* [C. Research notes and sources](#c-research-notes-and-sources)
* [D. Safety matrix](#d-safety-matrix)
* [G. Before/after reporting methodology](#g-beforeafter-reporting-methodology)
* [H. Limitations](#h-limitations)

---

## B. Audit of the original v2.0 script

The whole of `aiznm CLEANER v2.0.bat` was read. It is preserved unchanged in
`backup/`. Findings are grouped by severity.

### Critical: deletes data, kills programs or reports false results

| # | Problem in v2.0 | Why it matters | What 3.0.0 does instead |
|---|---|---|---|
| 1 | `taskkill /f` on **msedge, chrome, firefox** before clearing caches | Force-killing loses unsaved form data, downloads and sessions. Edge may also be restarted by Startup boost. | Browsers are never closed. If a browser is running, that browser's category is **Skipped**, with an explanation. |
| 2 | `taskkill /f /im explorer.exe` to delete thumbnail caches | Kills any running file copy or move, closes every Explorer window, and briefly removes the taskbar. | Explorer is never closed. If any `thumbcache_*.db` is open, the whole category is skipped so the cache stays consistent. Disk Cleanup > Thumbnails is offered as the supported route. |
| 3 | `net stop wuauserv` / `bits`, deletes `SoftwareDistribution\Download`, then `net start`, all with output sent to `nul` | It can interrupt an in-progress update. It starts services that may have been stopped before, so their previous state isn't kept. Failures are invisible. | No services are stopped or started. Windows Update files are left to Disk Cleanup's **Windows Update Cleanup** (menu 7). |
| 4 | **Recycle Bin emptied** as part of "full clean", with no separate warning, and only for drive C: | Permanent loss of files the user may still want. | Opt-in only. Shows size and item count, then requires typing `EMPTY`. The result is checked afterwards by re-reading the Recycle Bin size. |
| 5 | **Shader caches** (DirectX, NVIDIA, AMD) always cleared | Forces shader recompilation, which means stutter and longer loads in games such as VALORANT. No benefit to FPS. | Opt-in only, with an explicit side-effects warning. Skipped while a known game is running. |
| 6 | **AMD** shader cache cleared on a PC with an NVIDIA GPU | Acts on hardware that isn't installed, just because a folder exists. | The AMD category is only available when an AMD adapter (PCI vendor 1002) is detected. On this PC it shows "Not applicable" and the folder is left alone. |
| 7 | **Every** file in `%TEMP%` and `%WINDIR%\Temp` deleted, including files an installer created seconds ago | Can break running installers, updates, or installations waiting for a restart. | Age rules: user Temp keeps anything created or changed in the last **24 h**. Windows Temp keeps anything from the last **7 days**, which is Microsoft's documented Disk Cleanup rule. Files queued in `PendingFileRenameOperations` are kept. Both Temp categories are skipped while an MSI install (`_MSIExecute` mutex) or Windows servicing is active. Windows Temp is also skipped while a Windows Update restart is pending. |
| 8 | **Fixed "[OK]" summary**: every line printed whether or not anything worked; all errors sent to `>nul 2>&1` | The success report could not be trusted. | Every category gets a measured status (Completed / Completed with skipped files / Partially completed / Failed / Skipped / Not applicable / Cancelled), counts and reasons. |
| 9 | "Total Space Recovered" set to **0 when free space went down** (`if($diff -lt 0){$diff=0}`) | Hides the real measurement. | The signed change is shown. If free space fell, the report says so and explains why. |
| 10 | **Most size estimates were always 0.** `Get-DirSize '$env:WINDIR\Temp'` and the same for SoftwareDistribution, DeliveryOptimization, CrashDumps, D3DSCache, NVIDIA and AMD paths use *single quotes*, so PowerShell never expands `$env:...`. `Test-Path` gets a literal path that doesn't exist. Reproduced in `docs/TEST_REPORT.md`. | The "reclaimable" table was wrong for 7 of its 13 lines. | Sizes are measured with the same function that later deletes, on fully resolved, validated paths. A folder that can't be read is shown as **unknown**, never as 0. |

### High: fragile or unsafe implementation

| # | Problem in v2.0 | 3.0.0 |
|---|---|---|
| 11 | Elevates at start-up, even to just look. It also relaunches with `cmd /k`, which leaves an extra window open. | Least privilege. The menu, scans, reports and inventory run unelevated. Only a confirmed cleanup that includes an admin-only category starts a second, visible, self-closing elevated window. A cancelled UAC prompt is handled. |
| 12 | A huge PowerShell program squeezed into one CMD variable (`set "SCAN_SCRIPT=..."`), with `""` quoting, `%` expansion and `EnableDelayedExpansion`. A `!` or `'` in the user's path, or in `%~f0`, breaks it. | The PowerShell code is a normal multi-line program stored after a marker in the same file. CMD passes only the file's path, through an environment variable, so no quoting is involved. Delayed expansion is off. Tested with paths containing `& ( ) ' % ! ^`, spaces and non-ASCII characters. |
| 13 | Results passed back by printing `[DATA]:a\|b\|c...` and splitting with `for /f "tokens=2 delims=:"`. Numbers are formatted in the current locale, so a German "12,34" would make the later `%TOTAL_RECLAIMABLE_MB%/1024` PowerShell expression an array. | No text round-trip between CMD and PowerShell. Admin results come back as JSON written to a validated file. All byte counts are 64-bit integers until displayed. |
| 14 | `del /f /s /q "%~1\*"` and `rd /s /q` on folder paths with **no validation**: no check for empty or unexpected values, the drive root, or junctions. | Every target is an *anchor plus fixed path segments*. Anchors are trusted only when the environment variable and the Windows known-folder API agree. Targets are refused if they are empty, relative, contain wildcards or `..`, are a drive root, are outside their anchor, or have a junction anywhere between anchor and target. Files are deleted one at a time. Junctions and symlinks are never followed. |
| 15 | Assumes **C:** everywhere (DeviceID 'C:', `Clear-RecycleBin -DriveLetter C`) | The system drive comes from the Windows folder. Free space is measured on every drive that a selected category touches. |
| 16 | `cleanmgr /autoclean` described as "Built-in Windows Storage Optimization" | Microsoft documents `/autoclean` as deleting "the files that are left behind after you upgrade Windows" [C1]. It is not a general cleanup and is not run. Disk Cleanup, Storage settings and Storage Sense can be opened from menu 7 instead. |
| 17 | Delivery Optimization deleted by hand from `%ProgramData%\Microsoft\Windows\DeliveryOptimization\Cache` | Uses Windows' own `Delete-DeliveryOptimizationCache` (pinned content kept), and only on request. Microsoft states the cache is cleared automatically [C10]. The folder location was not relied on (and could not be verified for 22H2). |
| 18 | `C:\$Recycle.Bin` measured for **all users** (when elevated), but `Clear-RecycleBin` empties only the **current user's** bin | Size and action now use the same scope: the current user's bins, through `SHQueryRecycleBinW` and `Clear-RecycleBin`. |
| 19 | `mode con: cols=100 lines=42` (destroys the scroll-back buffer) and `color 0A` (changes the console's colours) | Neither is used. The window is only widened when it is narrower than the layout, and the scroll-back is kept. Colours apply to text only. |
| 20 | Everything in one all-or-nothing Y/N | Category selection, per-category explanations, and separate confirmation for irreversible items. |
| 21 | No log | A timestamped report per run, with retention. |
| 22 | Crash dumps deleted regardless of age, including dumps from a crash minutes earlier | Only dumps older than 14 days, only in Windows' default dump locations. Custom dump folders are reported, never cleaned. |

### Medium / low

* Admin cleanup ran in the same process as everything else, so any bug in
  it ran with full rights. 3.0.0 limits the elevated window to a fixed list
  of admin categories. The request is validated, and the result file must
  be a specific name inside the user's own `aiznm_CLEANER\Exchange` folder,
  which must not be a junction.
* An admin cleaning a user-writable folder (`C:\Windows\Temp`) by path is
  open to *junction-swap* tricks by unprivileged programs. 3.0.0's elevated
  deletes open each file once and check, **through that same handle**, that
  it is not a link and that its real path is inside the approved folder.
  Only then is that handle marked for deletion. If that helper cannot be
  loaded, admin cleanup is refused rather than done a weaker way.
* No Ctrl+C handling. 3.0.0 reads Ctrl+C as a key, and stops at the next
  safe point.

---

## Architecture

```
Download/aiznm_CLEANER_Personal.bat and Download/aiznm_CLEANER_Universal.bat
 |- CMD launcher (about 70 lines)
 |    sets AIZNM_SELF=%~f0, finds 64-bit Windows PowerShell 5.1 by absolute path,
 |    runs a short bootstrap that reads THIS file and executes the text after
 |    the "##AIZNM_PS_BEGIN##" marker. CMD always exits before the marker.
 |
 \- PowerShell program (about 3,700 lines, ASCII, CRLF)
      1 UI helpers (single-key input, Ctrl+C as input, throttled progress line)
      2 anchors + path validation + logging + read-only safety gates
      3 native helper (C# compiled at first use by .NET Framework's own compiler)
      4 file engine: ONE walk function for both dry-run and delete
      5 category definitions and handlers
      6 elevation broker, selection/confirmation screens, cleanup run, report
      7 overview, inventory, reports, Windows tools, main menu
```

Both `.bat` files are generated from the same parts in `src/` by
`src/Build-AiznmCleaner.ps1`. The parts are concatenated, launcher
placeholders are filled in, and the result is checked to be ASCII and saved
with CRLF line endings. Only the small *edition profile* part differs
between the two editions. Test T50 rebuilds from `src/` and fails if a
shipped `.bat` differs by even one byte.

**Why one self-contained `.bat`, and not a separate `.ps1`?** That's what
you asked for, and it is workable: the PowerShell code is not squeezed into
CMD syntax. It is read from the file and run as normal PowerShell. A
separate `.ps1` would add no safety and would add a second file to keep in
step.

**Why `-ExecutionPolicy Bypass`?** It applies to that one PowerShell process
only (Process scope). It doesn't change any system setting. It is needed
because Windows 10's default *Restricted* policy blocks `.psm1` module
files [C6], including Windows' own DeliveryOptimization module.

**Elevation flow.** The normal window starts `Download/aiznm_CLEANER_Personal.bat` again with
`Start-Process -Verb RunAs`, which shows the standard UAC prompt. It passes
`--elevated <scan|clean> "<Id+Id>" "<result.json>"`. Ids are joined with `+`
because CMD splits arguments at commas, semicolons and `=` (a bug found and
fixed during testing). The elevated copy shows its own progress, writes
JSON results and closes itself after 5 seconds. The normal window reads
the results, deletes the exchange file and reports. Error 1223 (UAC
cancelled) is reported as *Cancelled*. Any other failure is reported as
*Failed*.

---

## Editions: Personal and Universal

| Aspect | Personal (`Download/aiznm_CLEANER_Personal.bat`) | Universal (`Download/aiznm_CLEANER_Universal.bat`) |
|---|---|---|
| Edition profile | `$script:Baseline` holds the documented hardware of one PC | `$script:Baseline = $null` |
| System overview, hardware | "documented baseline vs detected" (Matches / Differs / Not detected, including an XMP-off check against the documented DDR4-3600) | "as Windows reports it", with neutral hints: memory configured below its module rating (XMP/EXPO/DOCP may be off; never changed), BIOS age, GPU driver age, Secure Boot, battery |
| Platform notes | The PCIe 3.0 note for B560 + i9-10900F, and the documented monitors | None (nothing is assumed) |
| Everything else | Identical code | Identical code |

What makes the shared code universal, and not tied to one PC:

* **Graphics vendor.** Detected from PCI vendor IDs: 10DE NVIDIA, 1002 AMD,
  8086 Intel. Each vendor's shader-cache category is only offered when that
  vendor's adapter is present. Hybrid laptops (Intel + NVIDIA) get both.
* **Windows version.** Builds of 22000 and above are named Windows 11. The
  support line differs by version: Windows 10's end-of-support date, or a
  pointer to Windows Update on Windows 11. Windows 11 gets the
  `ms-settings:storagerecommendations` shortcut [C30].
* **Folders.** Every path comes from known-folder APIs, never from a drive
  letter. A redirected or unusual profile layout is refused, never guessed.
* **Window size.** Width and height are adapted to the console. Narrow
  windows drop the Files column, so rows never wrap.
* **Architecture.** 64-bit Windows PowerShell is always used, via
  `Sysnative` when launched from a 32-bit process. The Recycle Bin query has
  both the x64 and the x86 structure layout.
* **Not supported:** Windows 7 and 8.1 (Windows PowerShell 5.1 is not built
  in, and both are out of support). The PowerShell version check refuses
  with a message.

---

## C. Research notes and sources

How the sources were checked: this environment's network blocked
`learn.microsoft.com`, `support.microsoft.com` and `nvidia.com`. So
Microsoft documentation was read **from Microsoft's own documentation source
repositories on GitHub**, which hold the same text as Learn
(`MicrosoftDocs/windowsserverdocs`, `win32`, `PowerShell-Docs`,
`windows-powershell-docs`, `windows-driver-docs`, `windows-dev-docs`,
`dotnet/dotnet-api-docs`). Pages that could only be found through
web-search summaries are marked **(search only)**. Treat them as less
certain.

| Ref | Source | Key finding that shaped the design |
|---|---|---|
| C1 | cleanmgr — https://learn.microsoft.com/windows-server/administration/windows-commands/cleanmgr | `/autoclean`: "Automatically deletes the files that are left behind after you upgrade Windows." Temporary Files option: "You can safely delete temporary files that haven't been modified within the last week." This led to the decision not to run `/autoclean`, and to the 7-day rule for Windows Temp. |
| C2 | Collecting User-Mode Dumps (WER LocalDumps) — https://learn.microsoft.com/windows/win32/wer/collecting-user-mode-dumps | Default `DumpFolder` is `%LOCALAPPDATA%\CrashDumps`; default `DumpCount` is 10; the feature is not enabled by default and enabling it needs admin. This led to: app dumps handled only in the default folder, custom folders reported only, WER settings never changed. |
| C3 | Small / Kernel / Automatic memory dump — https://learn.microsoft.com/windows-hardware/drivers/debugger/small-memory-dump (and `kernel-memory-dump`, `automatic-memory-dump`) | Minidumps are kept in `%SystemRoot%\Minidump`. Kernel and automatic dumps are written to `%SystemRoot%\Memory.dmp` by default. These are the only system dump locations approved. |
| C4 | Clear-RecycleBin (5.1) — https://learn.microsoft.com/powershell/module/microsoft.powershell.management/clear-recyclebin?view=powershell-5.1 | Clears the **current user's** recycle bin. `-Force` skips the cmdlet's own prompt; the program's typed confirmation replaces it. |
| C5 | Start-Process (5.1) — https://learn.microsoft.com/powershell/module/microsoft.powershell.management/start-process?view=powershell-5.1 | `-Verb RunAs` is available for `.cmd`/`.exe` (and `.bat`). `-Wait` waits for the process and its descendants. Used for the elevation broker. |
| C6 | about_Execution_Policies (5.1) — https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1 | *Restricted* is the default on Windows clients and blocks `.psm1` modules. The *Process* scope only affects the current session. This is why `-ExecutionPolicy Bypass` is passed on the command line, with no system setting changed. |
| C7 | about_PowerShell_exe (5.1) — https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_powershell_exe?view=powershell-5.1 | Exit-code rules for `-Command`. The bootstrap therefore ends with an explicit `exit [int]$global:AIZNM_EXIT`. |
| C8 | _MSIExecute Mutex — https://learn.microsoft.com/windows/win32/msi/-msiexecute-mutex | Set while Windows Installer runs an install sequence. Temp cleanup is skipped while it exists. |
| C9 | Reparse points — https://learn.microsoft.com/windows/win32/fileio/reparse-points | Junctions and symbolic links are reparse points, so the engine checks `FileAttributes.ReparsePoint` and never follows or deletes them. |
| C10 | Delivery Optimization FAQ / KB4041707 — https://support.microsoft.com/help/4041707 **(search only)** | "Delivery Optimization in Windows 10 clears its cache automatically." Disk Cleanup has a "Delivery Optimization Files" option. So the category is opt-in and described as rarely needed. |
| C11 | DeliveryOptimization module — https://learn.microsoft.com/powershell/module/deliveryoptimization/delete-deliveryoptimizationcache | The syntax `Delete-DeliveryOptimizationCache [[-FileId]] [-IncludePinnedFiles] [-Force]` is confirmed. **Microsoft's page has no description text (placeholders only)**, so the exact behaviour isn't documented. The program checks that the cmdlet exists at run time, never passes `-IncludePinnedFiles`, and re-measures afterwards. |
| C12 | Launch Windows Settings (ms-settings URIs) — https://learn.microsoft.com/windows/apps/develop/launch/launch-settings | Storage = `ms-settings:storagesense`; Storage Sense = `ms-settings:storagepolicies`. Used in menu 7. |
| C13 | Free up drive space in Windows — https://support.microsoft.com/windows/free-up-drive-space-in-windows-85529ccb-c365-490d-b548-831022bc9b32 **(search only)** | Microsoft's route is Storage Sense, Cleanup recommendations, and Disk Cleanup > *Clean up system files*. Storage Sense works on the system drive only. This is why system-managed data is left to those tools. |
| C14 | Storage Sense — https://learn.microsoft.com/windows/configuration/storage/storage-sense and Policy CSP Storage **(search only)** | Storage Sense deletes "temporary files that aren't in use". Downloads and cloud content are only touched if the user configures it. This matches the in-use / age protections. |
| C15 | Windows 10 end of support — https://support.microsoft.com/windows/deployment/updates-lifecycle/windows-10-support-has-ended-on-october-14-2025 **(search only)** | General support ended 14 Oct 2025. Secondary sources report that the consumer ESU programme was extended to October 2027 (June 2026 update); **not verified against Microsoft**. The tool shows the end-of-support date and says it cannot read ESU enrolment. |
| C16 | File.Delete — https://learn.microsoft.com/dotnet/api/system.io.file.delete | `IOException` means the file is in use. `UnauthorizedAccessException` covers access denied and read-only files. No exception is thrown if the file is already gone. This is how errors are classified: in use, denied, other, vanished. |
| C17 | MoveFileEx — https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-movefileexa **(search only)** | Delayed operations are stored as REG_MULTI_SZ pairs in `Session Manager\PendingFileRenameOperations`. Those paths are excluded from deletion. |
| C18 | Edge Startup boost — https://support.microsoft.com/edge/get-help-with-startup-boost **(search only)** | Edge can keep processes running after its windows close. The skip message for Edge explains this. |
| C19 | Chromium source (GitHub mirror of chromium/src): `docs/user_data_dir.md`, `content/browser/storage_partition_impl.cc`, `components/services/storage/public/cpp/constants.cc` | On Windows the cache folder is inside the profile folder. "Code Cache" is the generated-code cache. "Service Worker", "CacheStorage", "ScriptCache", "IndexedDB" and similar folders are **website storage**, so they are never touched. Only the top-level `Cache`, `Code Cache` and `GPUCache` folders of folders containing `Preferences` are cleaned. |
| C20 | Firefox local vs roaming profile — support.mozilla.org community answers, e.g. https://support.mozilla.org/questions/1127728 **(community)** | `%LOCALAPPDATA%\Mozilla\Firefox\Profiles\<p>` holds the disk cache (`cache2`). The real profile (cookies, logins) is under Roaming, which is never touched. |
| C21 | NVIDIA shader cache — the NVIDIA Control Panel help page you linked **could not be opened from this environment**, and no official text was found by search | Only uncontroversial statements are made: it is the driver's compiled-shader cache, and clearing it forces recompilation. No performance claims. |
| C22 | Resizable BAR via `nvidia-smi` — community sources (Linux forums, Red Hat KB title) **(community)** | A BAR1 total of about the VRAM size means ReBAR is active; 256 MiB means it isn't. The program reports *Active* / *Not active* / *Inconclusive* and labels the check as a heuristic. |
| C23 | LiveKernelReports — Microsoft Tech Community and Eleven Forum threads **(community; no official Microsoft documentation found)** | These hold kernel live dumps, for example WATCHDOG for GPU timeouts, and can be large. Treated conservatively: admin, opt-in, `.dmp` files only, 14-day age rule. |
| C24 | Thumbnail cache — Wikipedia "Windows thumbnail cache" **(search only)** | `%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_*.db`, rebuilt on demand. |
| C25 | PSScriptAnalyzer 1.23.0 compatibility profiles (`win-48_x64_10.0.17763.0_5.1.17763.316…framework`) | Used to check every command and .NET type against a Windows 10 + PowerShell 5.1 baseline. |
| C26 | AMD shader cache folders — community reports, e.g. https://macmyths.com/amd-shader-cache-what-it-does-and-how-to-reset-it-safely/ and https://mundobytes.com/shader-cache-corrupta/ **(community; no official AMD path list found)** | `%LOCALAPPDATA%\AMD\DxCache`, `\DxcCache` (DX12) and `\GLCache`. A `VkCache` folder could not be confirmed, so it is not included. AMD Software's own "Reset Shader Cache" button is mentioned as the vendor route. |
| C27 | Intel shader cache — https://learn.microsoft.com/en-us/answers/a/7789987 (Microsoft Q&A) and https://rtech.support/guides/clearing-shader-cache/ **(search only / community)** | Sources disagree between `%LOCALAPPDATA%\Intel\ShaderCache` and `...\LocalLow\Intel\ShaderCache`, so both are handled (each only if present). |
| C28 | NVIDIA per-driver cache — https://github.com/Kkthnx/NvidiaShaderCleanup and https://forums.flightsimulator.com/t/nvidia-shader-cache-folder-gone/613487 **(community)** | Newer drivers (reported from 545.xx) use `%USERPROFILE%\AppData\LocalLow\NVIDIA\PerDriverVersion\DXCache` and `\GLCache`. Added alongside the older Local folders. The legacy `%ProgramData%\NVIDIA Corporation\NV_Cache` is not touched. |
| C29 | Opera GX cache location — Opera forum posts, e.g. https://forums.opera.com/post/311015 **(community)** | The cache is under `%LOCALAPPDATA%\Opera Software\Opera GX Stable\Cache\Cache_Data`. Cookies, IndexedDB and sessions are under Roaming. So only the Local `Cache` folder is cleaned, for Opera and Opera GX. |
| C30 | ms-settings URIs (Windows app docs source) — https://learn.microsoft.com/windows/apps/develop/launch/launch-settings | "Storage recommendations" is `ms-settings:storagerecommendations`. It is offered on Windows 11 only. |

Things that could **not** be verified, and how the code copes:

* Whether `Delete-DeliveryOptimizationCache` exists on 22H2. It is not in
  the 1809 compatibility profile, and a third-party source dates it to
  1903. Checked at run time; if missing, the category says *Not applicable*
  and points to Disk Cleanup.
* The exact output properties of `Get-DeliveryOptimizationPerfSnap`. Read
  defensively; if no size is found, it shows *unknown*.
* Whether `WmiMonitorID` is readable without admin. If not, monitor names
  fall back to the Windows display name.

---

## D. Safety matrix

Age = the newer of a file's *created* and *last modified* times. Files with
future timestamps count as recent. "Kept" items are never deleted.

| Category | Purpose | Target path (resolved and validated at run time) | Default | Permissions | Risk | Reversible | Locked / in-use files | Other protections |
|---|---|---|---|---|---|---|---|---|
| User temporary files | Leftovers from apps and installers | `%LOCALAPPDATA%\Temp`. Must equal both `GetTempPath()` and `%TEMP%`, otherwise refused. | **On** | User | Low | No (deleted, not recycled); data is disposable | Skipped and counted as "in use"; continues | ≥24 h old; files queued for restart kept; empty old folders removed except `Low`; skipped during MSI or servicing activity |
| Windows temporary files | SYSTEM-level leftovers | `%SystemRoot%\Temp` | **On** (UAC when run) | Admin | Low | No | Same | ≥7 days old; folders kept; skipped during installs/servicing or while a Windows Update restart is pending; verified-handle deletes only |
| Thumbnail cache | Explorer thumbnails | `%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_*.db` | Off | User | Low | Rebuilt automatically | Any file locked means the whole category is skipped; Explorer never closed | Exact filename pattern; not recursive |
| Delivery Optimization cache | Update pieces kept for peer sharing | Via `Delete-DeliveryOptimizationCache -Force` (no manual folder deletion) | Off | Admin | Low | Re-downloaded if needed | Handled by Windows | Pinned content kept; re-measured after |
| Edge / Chrome / Brave / Vivaldi cache | Browser disk caches | `%LOCALAPPDATA%\<vendor>\User Data\<profile>\{Cache, Code Cache, GPUCache}` (profiles = folders with `Preferences`) | Off (menu 5 preselects installed, closed browsers) | User | Low | Rebuilt while browsing | Browser running means the category is skipped; otherwise locked files are skipped | Cookies, logins, history, bookmarks, sessions, extensions and website storage untouched |
| Opera / Opera GX cache | Browser disk cache | `%LOCALAPPDATA%\Opera Software\{Opera Stable, Opera GX Stable}\Cache` | Off (menu 5 preselects installed, closed browsers) | User | Low | Rebuilt while browsing | `opera.exe` running means the category is skipped | The Roaming profile (cookies, logins, sessions) is never touched |
| Firefox cache | Browser disk cache | `%LOCALAPPDATA%\Mozilla\Firefox\Profiles\<p>\{cache2, startupCache}` | Off | User | Low | Rebuilt | Same | Roaming profile untouched |
| DirectX shader cache | Compiled shaders | `%LOCALAPPDATA%\D3DSCache` | Off | User | **Medium** (temporary stutter) | Rebuilt while playing | Skipped while a known game runs; locked files skipped | No FPS claims |
| NVIDIA shader cache | Driver-compiled shaders | `%LOCALAPPDATA%\NVIDIA\DXCache`, `\GLCache`; `%USERPROFILE%\AppData\LocalLow\NVIDIA\PerDriverVersion\DXCache`, `\GLCache` | Off; requires NVIDIA GPU | User | **Medium** | Rebuilt | Same | |
| AMD shader cache | Driver-compiled shaders | `%LOCALAPPDATA%\AMD\DxCache`, `\DxcCache`, `\GLCache` | Off; **only with an AMD GPU** | User | Medium | Rebuilt | Same | Folders left alone on PCs without AMD graphics |
| Intel graphics shader cache | Driver-compiled shaders | `%LOCALAPPDATA%\Intel\ShaderCache`; `%USERPROFILE%\AppData\LocalLow\Intel\ShaderCache` | Off; **only with an Intel GPU** | User | Medium | Rebuilt | Same | Folders left alone on PCs without Intel graphics |
| App crash dumps (old) | WER local dumps | `%LOCALAPPDATA%\CrashDumps\*.dmp` | Off | User | **Medium** (lose diagnostics) | No | Skipped | ≥14 days old; not recursive; custom folders only reported |
| Error reports - user (old) | WER report folders | `%LOCALAPPDATA%\Microsoft\Windows\WER\ReportArchive`, `\ReportQueue` | Off | User | Low | No | Skipped | ≥14 days old; empty old report folders removed |
| Error reports - system (old) | WER report folders | `%ProgramData%\Microsoft\Windows\WER\ReportArchive`, `\ReportQueue` | Off | Admin | Low | No | Skipped | ≥14 days old; verified-handle deletes |
| System crash dumps (old) | Blue-screen and live kernel dumps | `%SystemRoot%\MEMORY.DMP`, `%SystemRoot%\Minidump\*.dmp`, `%SystemRoot%\LiveKernelReports\**\*.dmp` | Off | Admin | **Medium** | No | Skipped | ≥14 days old; `.dmp` only; custom dump paths reported only |
| Recycle Bin | Deleted items | Current user's bins on all drives (`Clear-RecycleBin`) | Off + typed `EMPTY` | User | **High** | **No — permanent** | Windows handles it | Size shown first; result verified by re-querying |

Never cleaned (by design): Windows Update download cache, `Windows.old`,
WinSxS, the Windows Installer cache, Prefetch, restore points and shadow
copies, the page file and hibernation file, Program Files and ProgramData
(beyond the WER folders above), personal folders, browser profile data,
and all game and launcher folders.

---

## G. Before/after reporting methodology

1. **Estimate (scan).** For each category, the program sums the file
   lengths of the files that pass the **exact same eligibility test** the
   cleanup will use. It is the same function running in dry-run mode, so
   the preview and the deletion cannot disagree about the rules. Recent
   files, junctions and links, files queued for restart, and anything
   outside the approved folder are excluded and listed separately.
   * A folder that can't be read without admin shows **unknown**, not 0.
     Press **R** to measure it in an elevated window.
   * A partly readable folder shows `>=` (a lower bound).
   * Delivery Optimization uses the size Windows reports
     (`Get-DeliveryOptimizationPerfSnap`). The Recycle Bin uses
     `SHQueryRecycleBinW` (current user, all drives).
2. **Deleted file size.** This is the sum of the sizes of files actually
   deleted, read from each file just before it was deleted. It is a
   *logical* size.
3. **Measured change.** `DriveInfo.AvailableFreeSpace` (Win32
   `GetDiskFreeSpaceEx`) is read for every affected drive immediately
   before the first deletion and immediately after the last one. That
   includes the work done in the elevated window. The difference is shown
   **with its sign** and is never adjusted.
4. **Why the three numbers differ.** Time passes between the scan and the
   cleanup, so files can become old enough, appear, or disappear.
   * Files in use are skipped.
   * Windows allocates space in clusters: a 1-byte file still occupies 4 KB.
   * Compressed or sparse files take up less disk than their length.
   * Hard-linked files free nothing until the last link goes; the verified-delete helper (normally active on Windows) skips them.
   * A file still open elsewhere with delete-sharing is removed only when its last handle closes.
   * Other programs (Windows Update, launchers, browsers) write at the same time.
5. **Statuses** come from counts, not from reaching the end:
   * *Completed*: no problems.
   * *Completed with skipped files*: only in-use files or unreadable subfolders were skipped.
   * *Partially completed*: some access-denied or other errors, but something was deleted.
   * *Failed*: nothing deleted and errors, or a refused target.
   * Plus *Skipped*, *Not applicable* and *Cancelled*.
6. **Units.** Counters are `Int64`. Display uses 1024-based KB/MB/GB, as
   Windows Explorer does.

---

## H. Limitations

* **Not run on your PC.** This environment is Linux and has no Windows
  machine. Everything that only exists on Windows was verified only by static analysis, a C# 5 compile, struct-size checks against the Windows SDK layouts, and simulated tests:
  * UAC elevation
  * the native verified-delete helper
  * CIM/WMI, the registry, `Clear-RecycleBin`
  * the Delivery Optimization cmdlets
  * display mode enumeration and `nvidia-smi`
  * real Windows file locks

  Two Windows-only tests (T36, T37) are included for you to run. See `TEST_REPORT.md`.
* **Not an FPS tool.** Nothing here changes game, driver, power, network or
  scheduler settings. Shader-cache clearing is presented as a
  troubleshooting step with a temporary downside.
* Files in use can't be deleted, and the tool does not schedule deletion
  at restart (by design).
* The behaviour of Delivery Optimization's cmdlets is not described by
  Microsoft (C11). LiveKernelReports has no official documentation (C23).
* Not handled: Microsoft Store builds of Firefox; Edge Beta/Dev/Canary and
  other browser channels; game-specific shader caches, such as Steam's
  `shadercache` (they belong to game folders, which are off-limits).
* The AMD, Intel, newer-NVIDIA and Opera cache folder locations come from
  community sources (C26 to C29), not vendor documentation. A folder that
  doesn't exist simply shows "not present". None of them is cleaned without
  your selection.
* Universal edition: it was built to run on any Windows 10/11 PC, but it has
  only been tested in the Linux sandbox described in `TEST_REPORT.md`, like
  the Personal edition. Windows on ARM, Windows Server and non-English
  Windows are expected to work (no text output is parsed, except the power
  plan name in brackets), but have not been run.
* The inventory only knows games from Steam, Epic and Riot manifests, plus
  launchers listed in Windows' installed-apps registry. Xbox and Microsoft
  Store game sizes, and games installed by hand, are not detected. Riot,
  Steam and Epic file formats are undocumented; parsing is best-effort, and
  anything unconfirmed is labelled "POSSIBLE".
* Not detectable: PSU and cooler models, temperatures, fan curves, ESU
  enrolment, TPM details (needs admin), and BIOS settings. ReBAR status is
  a heuristic from `nvidia-smi`.
* PowerShell in *Constrained Language Mode* (set by system policy) is
  detected, and the tool refuses to run.
* A folder name containing two `%` signs (for example `%name%`) in your
  user-profile path could be mis-expanded by CMD when the elevated window is
  started. That part would then fail safely, refusing to run with "result
  location is not valid".
* Designed for Windows 10 22H2. Windows 11 is detected and mostly
  compatible, but untested.
* Antivirus or SmartScreen may warn about a downloaded `.bat` that starts
  PowerShell. This is expected; check the file's origin.
