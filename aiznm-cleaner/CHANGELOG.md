# Change log

## 3.1.0 — 2026-10-09

### New: Universal edition (`aiznm_CLEANER_Universal.bat`)
- Works on any Windows 10 or Windows 11 PC. Its System overview shows detected hardware with neutral hints in place of a personal baseline: memory below its module rating, monitor below its best refresh rate, BIOS and driver age, and battery on laptops.
- The Personal and Universal editions are built from one shared source (`src/`) by `src/Build-AiznmCleaner.ps1`, so fixes always reach both. Test T50 checks that the shipped files match the source.

### Both editions
- Shader caches:
  - AMD (`DxCache`, `DxcCache`, `GLCache`) and Intel (`ShaderCache`, Local and LocalLow) are offered only when that graphics vendor is detected.
  - NVIDIA's newer `LocalLow\NVIDIA\PerDriverVersion` cache folders were added.
- New browsers: Vivaldi (each profile), plus Opera and Opera GX. For Opera, only the `Cache` folder in Local is cleaned; the profile under Roaming is never touched.
- A read-only health check in System overview: free space, memory in use, uptime and the Fast Startup note, pending restart, number of startup programs, and power plan.
- Inventory additions:
  - Programs that start with Windows are listed. Nothing is changed.
  - All Riot games are detected from Riot's metadata.
  - More background apps are recognised: RGB and peripheral tools, cloud sync, AMD and Intel graphics software.
- Windows 11: a "Cleanup recommendations" shortcut in Windows cleanup tools, and correct Windows 11 naming.
- Selection screens show only categories that apply to this PC; the rest are named on one line.
- Tables adapt to narrow windows, and the window grows to 42 lines when the screen allows.

## 3.0.0 — 2026-10-09

A complete rewrite of `aiznm CLEANER v2.0.bat`. The original is kept unchanged in
`backup/aiznm CLEANER v2.0 (original, backed up 2026-10-09).bat.txt`.

### Safety
- No forced closing of browsers, Explorer or games. An open browser is skipped, and so is a locked thumbnail cache.
- No stopping or starting of Windows services. The Windows Update download folder is never deleted by hand; use Disk Cleanup from menu 7 instead.
- Least privilege: the menu, scans, reports and inventory run without admin rights. A separate, visible elevated window is used only for admin-only categories you confirm.
- Every target is a trusted folder plus fixed path segments. Paths are checked: no empty values, wildcards, `..`, drive roots, folders outside the trusted folder, or junctions on the way.
- Files are deleted one at a time. Junctions and symlinks are never followed. Elevated deletes check, through the file's own handle, that it really is inside the approved folder.
- Age rules: user Temp keeps files from the last 24 h, Windows Temp keeps the last 7 days, crash dumps and error reports keep the last 14 days.
- Files queued for the next restart are kept. Temp cleanup pauses while an installation or Windows servicing is running, and Windows Temp also waits for a pending Windows Update restart.
- Shader caches, crash dumps, Delivery Optimization and the Recycle Bin are opt-in only. Emptying the Recycle Bin requires typing `EMPTY`.
- The AMD shader cache is only offered when an AMD graphics card is present.
- `cleanmgr /autoclean` is no longer run. It only removes files left behind by a Windows upgrade.

### Transparency
- A read-only scan uses exactly the same rules as the cleanup. Sizes that can't be measured show as "unknown" or ">=", never as 0.
- A per-category explanation (`?`): what is removed, why, side effects, whether it regenerates, what to close first, whether admin is needed, the exact folders and sizes.
- A confirmation screen lists what will run, the estimate, admin items and the warnings that apply right now.
- The report shows measured free space before and after, with its sign; the estimate; the size of files actually deleted; files deleted, kept and failed; a status per category; time taken; restart advice; and the log path.
- A timestamped log per run in `%LOCALAPPDATA%\aiznm_CLEANER\Logs`. The newest 40 are kept, for up to 90 days. Personal paths are shortened.

### New read-only features
- System overview that compares detected hardware with your documented baseline, and shows each monitor's current refresh rate.
- Gaming and storage inventory: Steam libraries and games, VALORANT / Riot, Epic, launchers, browsers, GPU driver, Resizable BAR through `nvidia-smi`, drives and background processes.
- Report viewer, and shortcuts to Disk Cleanup, Storage settings and Storage Sense.

### Fixed from v2.0
- 7 of the 13 size estimates were always 0, because single-quoted `'$env:...'` paths are never expanded.
- The "[OK]" summary was printed no matter what happened, and errors were hidden with `>nul`.
- A negative free-space change was shown as 0.
- Measurements and actions assumed drive C:.
- The Recycle Bin was measured for all users but emptied only for the current user.
- `mode con` destroyed the console's scroll-back buffer.
- Fragile quoting between CMD and PowerShell broke on `!`, `'` or `%` in paths, and locale-formatted numbers broke later calculations.

## 2.0 — original
Single elevated "clean everything" script. See the audit in `docs/TECHNICAL_REPORT.md`.
