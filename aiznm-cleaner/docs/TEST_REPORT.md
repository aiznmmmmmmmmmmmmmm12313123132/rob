# aiznm CLEANER 3.1.0 — Test report (deliverable E)

## Where and how it was tested

| Item | Value |
|---|---|
| Machine | Cloud container: Ubuntu 24.04 (Linux), ext4. **No Windows machine was available.** |
| PowerShell used | PowerShell 7.4.6 (Core) for Linux. **Not** Windows PowerShell 5.1. |
| Static analysis | PSScriptAnalyzer 1.23.0. Rules: `PSUseCompatibleSyntax` (target 5.1), plus `PSUseCompatibleCommands` and `PSUseCompatibleTypes` against the Windows 10 / PowerShell 5.1 profile `win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework` |
| C# helper | Compiled with `-langversion:5`, the level the .NET Framework compiler used by Windows PowerShell 5.1 supports. Struct sizes compared with the Windows SDK layouts. |
| Your PC | **Not tested on your PC.** Nothing was run on any real Windows installation. |
| Destructive tests | Only inside a freshly created sandbox folder (`<temp>/aiznm-test-<guid>`), removed afterwards. The program's trusted-folder anchors were replaced with sandbox folders before any category code ran, and end-to-end tests refuse to start unless every resolved target is inside the sandbox. |

Run it yourself on Windows (recommended). It only touches its own sandbox:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-AiznmCleaner.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-AiznmCleaner.ps1 -BatPath .\aiznm_CLEANER_Universal.bat
```

The same suite runs against **both editions**.

## Results

| Edition | Result |
|---|---|
| Personal (`aiznm_CLEANER.bat`) | **48 passed, 0 failed, 2 skipped** |
| Universal (`aiznm_CLEANER_Universal.bat`) | **48 passed, 0 failed, 2 skipped** |

The two skipped tests (T36, T37) need Windows APIs.

| Id | Test | Result |
|---|---|---|
| T01 | BAT structure: ASCII only, CRLF only, no BOM, one marker, CMD part ends with `exit /b` before the PowerShell part, required labels exist, no PowerShell line starts with `:`, `rem` lines contain no `% \| < >`, PowerShell parses with 0 errors, CMD part contains no destructive commands | PASS |
| T02 | Size/count formatting: 64-bit, signed, negative, unknown | PASS |
| T03 | Path syntax: rejects empty, relative, wildcard, `..`, UNC, `C:foo`, alternate streams, NUL | PASS |
| T04 | Target specs: refused anchors and segments, drive root, outside the anchor, equal to the anchor; missing = not applicable | PASS |
| T05 | A junction or symlink between anchor and target refuses the target | PASS |
| T06 | Dry-run scan measures correctly and changes nothing (before/after snapshot identical) | PASS |
| T07 | Clean: old files deleted; recent files, root folder, recent folders and `Low` kept; Temp validated against LocalAppData | PASS |
| T08 | Links inside a target are not followed or deleted; data outside survives | PASS |
| T09 | File in use: skipped, counted, status "Completed with skipped files" (simulated on Linux, real lock on Windows) | PASS |
| T10 | Access denied gives "Partially completed"; all denied gives "Failed" (simulated) | PASS |
| T11 | Name-pattern mode (thumbcache): only matching top-level files | PASS |
| T12 | Single-file mode (MEMORY.DMP): exactly that file | PASS |
| T13 | Paths with spaces, `& ( ) ' % ! ^` and non-ASCII characters | PASS |
| T14 | Missing locations are "Not applicable", not errors | PASS |
| T15 | Files queued for the next restart are kept | PASS |
| T16 | Cancel mid-run stops at a safe point; status "Cancelled"; partial counts reported | PASS |
| T17 | Repeated run: second clean finds nothing; status "Completed" | PASS |
| T18 | Status rules matrix | PASS |
| T19 | Log created, written and rotated (own files only); same-second names don't collide; unwritable log reported, not thrown | PASS |
| T20 | Elevated request: only known admin categories; injection strings and commas refused | PASS |
| T21 | Elevated result path validation, including a junctioned Exchange folder | PASS |
| T22 | Elevated JSON round trip keeps Int64 sizes, arrays and samples; fatal and garbage input handled | PASS |
| T23 | Steam inventory: libraries, confirmed vs possible games; nothing changed | PASS |
| T24 | Riot / VALORANT and Epic manifests parsed read-only | PASS |
| T25 | Browser profiles: only Cache / Code Cache / GPUCache (cache2 / startupCache) deleted; Cookies, Login Data, History, Bookmarks, Local Storage, IndexedDB, Service Worker caches, Sessions, Extensions, Local State untouched | PASS |
| T26 | Running browser is skipped and its cache untouched | PASS |
| T27 | Shader caches skipped while a game runs; AMD category refused on an NVIDIA PC, folder untouched | PASS |
| T28 | Temp cleanup skipped while an installation is running | PASS |
| T29 | Admin categories refuse without admin rights; with admin, the 7-day Windows Temp rule is applied | PASS |
| T30 | Every category fully described; only low-risk Temp categories are defaults; all targets use approved anchors | PASS |
| T31 | Thumbnail cache all-or-nothing while a file is exclusively locked (real lock) | PASS |
| T32 | End-to-end: real category definitions on a sandbox profile, full cleanup run, report and log; admin categories correctly **refused** on Linux because the verified-delete helper is unavailable; personal paths shortened in the log | PASS |
| T33 | Drive snapshot values are Int64; negative deltas stay negative | PASS |
| T34 | Selection table and detail views render within 100 columns, one row per category | PASS |
| T35 | The CMD bootstrap command, run as-is, loads the program from a path with special characters (exit 0); a damaged file gives a friendly message and exit 70 | PASS |
| T36 | **Windows only**: native verified delete (inside root, outside root refused, read-only retry, hard link kept, lock = in use, file reached through a junction refused), Recycle Bin query, display query | SKIP (not run) |
| T37 | **Windows only**: real anchors validate; `%TEMP%` pointing elsewhere is refused | SKIP (not run) |
| T38 | Syntax-tree checks: no `a + b, c` precedence traps; every coloured text segment is a (text, colour) pair | PASS |
| T39 | Declined UAC: admin categories reported "Cancelled", user categories still run, overall status honest | PASS |
| T40 | Elevated argument line survives CMD parsing (no `, ; =` outside quotes); error 1223 means Cancelled, other errors mean Failed | PASS |
| T41 | Declining at the confirmation screen changes nothing | PASS |
| T42 | Recycle Bin is dropped unless exactly `EMPTY` is typed (`''`, `empty`, `EMPTY `, `yes`, Esc all refused) | PASS |
| T43 | Unknown and partial sizes are shown as "unknown" or ">=", never as 0 | PASS |
| T44 | Report states honestly when free space went down; nothing claimed as "recovered" | PASS |
| T45 | Edition profile:<ul><li>Personal: 7 baseline rows match the documented PC, and the XMP-off check works.</li><li>Universal: no baseline; generic hardware rows; an XMP kit running above its JEDEC rating isn't flagged, while memory below its rating is.</li><li>Both: empty hardware facts still render; Windows support text for 10/11/other; health-check flags (uptime, memory, pending restart).</li></ul> | PASS (both) |
| T46 | Vivaldi (per profile), Opera and Opera GX (Local `Cache` only): only cache deleted; cookies, `Local State` and other files kept; running `opera.exe` skips the category | PASS |
| T47 | Selection screen: one keyed row per applicable category, not-applicable ones named on one line, every line within 100 columns | PASS |
| T48 | Shader caches follow the detected vendor: NVIDIA LocalLow per-driver folder cleaned; Intel left alone on an NVIDIA-only PC; Intel (Local + LocalLow) and AMD (DxcCache + GLCache) cleaned when those adapters exist | PASS |
| T49 | Riot products detected generically: League of Legends confirmed; VALORANT without game files only "possible" | PASS |
| T50 | The tested `.bat` is byte-for-byte what `src/Build-AiznmCleaner.ps1` produces (no drift between editions) | PASS (both) |

Other checks:

* **PSScriptAnalyzer compatibility (5.1 / Windows 10)**, run on both
  editions. No syntax or .NET type problems. One command was flagged: `Delete-DeliveryOptimizationCache`
  is not in the 1809 profile. It is checked at run time; if missing, the
  category shows "Not applicable".
* **C# helper.** Compiles at C# 5. Marshalled sizes match the SDK:
  * BY_HANDLE_FILE_INFORMATION 52 bytes
  * FILE_BASIC_INFO 40
  * FILE_DISPOSITION_INFO 1
  * SHQUERYRBINFO 24 (x64) / 20 (x86)
  * DISPLAY_DEVICEW 840
  * DEVMODEW 220
* **Screen rendering.** Every screen was rendered with simulated key
  presses into a text capture and reviewed for layout: main menu, scan
  results, selection, details, confirmation with typed EMPTY, cleanup
  progress, report, browser flow, overview, inventory, reports viewer and
  Windows tools.

## Bugs found by this testing, and fixed before delivery

3.1.0 round:
* A new `'Windows 11 ' + $Os.Version + '...', 'Gray'` line had the same
  comma-versus-`+` trap. The syntax-tree check (T38) caught it automatically
  before any run.
* The new "categories that apply" filter made the old row-count test
  ambiguous. The tests now match only category rows; the program was
  correct.

3.0.0 round:

| Bug | Effect if shipped | Found by |
|---|---|---|
| User Temp (the main default category) was rejected by the "must be strictly inside the anchor" rule, because the Temp folder *is* the anchor | User temporary files would **never** have been cleaned; shown as "Refused" | T32 end-to-end log |
| `@(' ' + $Title, 'White')`: comma binds tighter than `+` | **Crash on the very first screen** | Screen rendering; now guarded by T38 |
| `@(@('  ','Gray'))` flattened to a 2-item array | Selection screen crash | T34 |
| Single target returned unrolled, so `$specs[0]` was `$null` | Thumbnail category always reported "Failed" | T31 |
| Category ids joined with commas on the elevated command line | CMD splits at commas, so the elevated window would get the wrong result path and refuse to run every multi-category admin cleanup | Code review of Windows-only paths; now T40 |
| Folder age read after deleting its contents | Old empty folders kept on some file systems | T07 |
| Two logs in the same second used the same name | Second report silently not written | Screen rendering; now in T19 |
| `<scan\|clean>` written inside a `rem` line | Risk of CMD treating `\|` and `<` as pipe or redirect | Review; now checked in T01 |

## The 24 requested scenarios

| # | Scenario | How it was covered | Status |
|---|---|---|---|
| 1 | Normal launch as standard user | T35 runs the real bootstrap command; menu rendered by the preview harness. A real double-click on Windows was **not** performed. | Partly verified |
| 2 | Administrator cancellation | T39 (simulated cancel), T40 (error 1223 recognised) | Verified (simulated) |
| 3 | Read-only scan | T06, T23, preview | Verified |
| 4 | Empty cache directories | T17, T14 | Verified |
| 5 | Missing browsers | T26 (Brave), preview (Firefox) | Verified |
| 6 | Multiple browser profiles | T25 | Verified |
| 7 | Browser currently running | T26, preview (Chrome) | Verified |
| 8 | Files locked by another application | T31 (real exclusive lock), T09 (simulated on Linux, real on Windows), T36 (Windows) | Verified on Linux; Windows part pending |
| 9 | Access-denied errors | T10 (simulated) | Verified (simulated) |
| 10 | Paths containing spaces | T13, T35 | Verified |
| 11 | Missing directory | T14, T04 | Verified |
| 12 | Malformed or empty path | T03, T04 | Verified |
| 13 | Insufficient permissions | T29, T10, T43 (unreadable gives unknown) | Verified (simulated) |
| 14 | Junction / reparse point | T05, T08, T21; T36 on Windows (real junction plus handle check) | Verified on Linux (symlinks); Windows junction test pending |
| 15 | User cancels before cleanup | T41 | Verified |
| 16 | User declines Recycle Bin | T42 | Verified |
| 17 | Partial cleanup failure | T10, T32 | Verified |
| 18 | Failed elevation | T40 (non-1223 error is reported as Failed) | Verified (simulated) |
| 19 | Full or nearly full drive | Not reproducible here. By reasoning: scanning only reads; a log that can't be written is reported (T19), and you are asked before continuing without one. Overview marks drives under 10 % free. | **Not performed** |
| 20 | Failure to write a log | T19 | Verified |
| 21 | Incorrect or unavailable size information | T43, T22 | Verified |
| 22 | Measured free space does not increase | T44, T33 | Verified |
| 23 | Repeated executions | T17, T19 (same-second logs), the preview ran several flows back to back | Verified |
| 24 | Windows PowerShell 5.1 baseline | Static compatibility analysis and a C# 5 compile only. **Not executed on 5.1.** | Static only |

## Still unverified (please run T36/T37 and a first scan on your PC)

* Real UAC elevation round trip: the second window, the JSON hand-back,
  and the 5-second auto-close.
* The native verified-delete helper on NTFS, and real junction-swap refusal.
* `Clear-RecycleBin` and `SHQueryRecycleBinW` against your real Recycle Bin.
* The `Delete-DeliveryOptimizationCache` and `Get-DeliveryOptimizationPerfSnap`
  output on 22H2.
* CIM/WMI hardware facts, display modes, `WmiMonitorID` names, `nvidia-smi`
  parsing on your RTX 4060.
* Console behaviour in conhost: colours, Ctrl+C as input, window widening.

Suggested first run on your PC: menu **2** (read-only scan), then menu
**1** and **8** (read-only). Review the numbers, then try menu **4**.

## Evidence for the v2.0 measurement bug (audit item 10)

```powershell
$env:WINDIR = '/tmp'
function Get-DirSize($p) { if (Test-Path $p) { "measured: $p" } else { "NOT measured (Test-Path false) for literal path: $p" } }
Get-DirSize '$env:WINDIR\Temp'    # -> NOT measured (Test-Path false) for literal path: $env:WINDIR\Temp
Get-DirSize "$env:WINDIR"         # -> measured: /tmp
```
