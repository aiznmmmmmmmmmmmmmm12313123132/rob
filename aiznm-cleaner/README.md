# aiznm CLEANER 3.1.0

A safe, transparent storage-maintenance tool for Windows. It shows you what
it is going to delete before it deletes anything, and it measures free space
before and after so you can see what actually changed. Each edition is a
single `.bat` file and uses only what ships with Windows: CMD and Windows
PowerShell 5.1.

## Two editions

| | `Download/aiznm_CLEANER_Personal.bat` (Personal) | `Download/aiznm_CLEANER_Universal.bat` (Universal) |
|---|---|---|
| Made for | One documented PC (i9-10900F / PRIME B560-PLUS / RTX 4060, Windows 10 Home 22H2) | **Any** Windows 10 or Windows 11 PC, any hardware, desktop or laptop |
| System overview | Compares what Windows detects with that PC's documented baseline (Matches / Differs) | Shows the detected hardware with neutral hints: memory below its module rating, monitor below its best refresh rate, BIOS and driver age, battery |
| Cleanup, safety rules, UI, logs | Identical | Identical |

Both editions share the same code, so a fix in one is a fix in both. On a
PC that isn't yours, use the Universal edition.

Both editions automatically adapt to the PC they run on:
* **Graphics:** NVIDIA, AMD and Intel shader caches are only offered when that kind of graphics card is actually present.
* **Browsers:** Edge, Chrome, Brave, Vivaldi, Opera, Opera GX and Firefox are found per profile.
* **Games:** Steam, Epic and Riot games are found from the launchers' own records.
* **Windows 11:** gets its extra "Cleanup recommendations" shortcut.
* **Laptops:** battery level is shown.
* **Small windows:** tables shrink so nothing wraps.

> **This is not an FPS booster.** Deleting caches and temporary files frees
> disk space. It does not make VALORANT, or any other game, run at a higher
> frame rate. Clearing shader caches can briefly cause *more* stutter while
> they are rebuilt.

## Files

| File | What it is |
|---|---|
| `Download/aiznm_CLEANER_Personal.bat` | **Personal edition.** Double-click to run. |
| `Download/aiznm_CLEANER_Universal.bat` | **Universal edition** for any Windows 10/11 PC. Double-click to run. |
| `src/` | The shared source both `.bat` files are built from, plus `Build-AiznmCleaner.ps1`. You only need this to change the program. |
| `backup/aiznm CLEANER v2.0 (original, backed up 2026-10-09).bat.txt` | Your original v2.0 script, unchanged. The extra `.txt` stops it being run by accident. |
| `docs/TECHNICAL_REPORT.md` | Audit of v2.0, research notes with sources, safety matrix, before/after methodology and limitations (deliverables B, C, D, G, H). |
| `docs/TEST_REPORT.md` | What was tested, how, the results, and what is still unverified (deliverable E). |
| `tests/Test-AiznmCleaner.ps1` | Test suite. It only works inside a throw-away sandbox folder, so you can run it on your PC. |
| `CHANGELOG.md` | Version history. |

---

## User guide (deliverable F)

### 1. Running it

1. Put `Download/aiznm_CLEANER_Personal.bat` in any folder. Spaces and unusual characters in
   the folder name are fine.
2. Double-click it. **Do not** use "Run as administrator". The program asks
   for administrator rights itself, only when a task you choose really needs
   them.
3. If Windows SmartScreen says "Windows protected your PC" (common for any
   downloaded `.bat`), check that the file came from your own repository,
   then click *More info* and *Run anyway*. You can also right-click the file,
   choose *Properties*, then tick *Unblock*.

Requirements: Windows 10 with the built-in Windows PowerShell 5.1. Nothing is
downloaded or installed.

### 2. Moving around

Every screen works with single key presses:

* **Number keys** choose a main-menu item.
* **Letters** select or unselect a category on the selection screens.
* **Enter** continues. **Esc** goes back.
* **Ctrl+C** never kills the program in the middle of a deletion. It works
  like Esc: "stop safely after the current file".

### 3. Main menu

| Key | Item | Changes anything? |
|---|---|---|
| 1 | **System overview**: Windows version and support status; hardware (compared with your baseline in the Personal edition); current refresh rate of each monitor; a **health check** (free space, memory in use, uptime, pending restart, startup-program count, power plan); drives | No (read-only) |
| 2 | **Scan for cleanup candidates**: measures every category under the safety rules | No (read-only) |
| 3 | **Preview and select cleanup**: all categories, with low-risk defaults preselected | Only after you confirm |
| 4 | **Quick safe cleanup**: old temporary files only (yours, plus Windows Temp) | Only after you confirm |
| 5 | **Browser cache cleanup**: Edge, Chrome, Brave, Vivaldi, Opera, Opera GX and Firefox cache folders | Only after you confirm |
| 6 | **Advanced cleanup**: shader caches, old crash dumps / error reports, Recycle Bin | Only after you confirm |
| 7 | **Windows cleanup tools**: opens Disk Cleanup, Storage settings or Storage Sense | Windows' own tools |
| 8 | **Gaming and storage inventory**: Steam libraries and games, Riot games (VALORANT, League of Legends), Epic, launchers, browsers, GPU driver, Resizable BAR (via NVIDIA's own `nvidia-smi`), drives, background processes, programs that start with Windows | No (read-only) |
| 9 | **Reports and logs**: view earlier reports, open the log folder | No |
| 0 | Exit | |

### 4. Previewing and selecting

Options 3 to 6 always start with a **scan**, which deletes nothing. You then
see a table like this:

```
  Key  Sel  Category                         Est. size  Files Admin Risk   Notes
  [A]  [x]  User temporary files                155 MB     40 -     Low    1 recent kept
  [B]  [x]  Windows temporary files            unknown      - Yes   Low    needs admin to measure (R)
  [E]  [ ]  Microsoft Edge cache               59.0 MB      2 -     Low    1 profile(s)
  [F]  [ ]  Google Chrome cache                 120 MB      1 -     Low    OPEN - will be skipped
```

* Press a **letter** to select or unselect that category. Categories that don't apply to this PC (for example, a browser that isn't installed) are listed on one line under the table instead of taking up rows.
* **`?`** then a letter shows the full explanation: what it removes, why,
  side effects, whether it regenerates, what to close first, whether it
  needs admin, the exact folders and their sizes.
* **`R`** measures administrator-only folders, such as Windows Temp. Windows asks for
  permission and a small window measures them. This is read-only.
* **`S`** restores the recommended selection. **`X`** clears everything.
* **Enter** goes to the confirmation screen.

### 5. Confirming, and irreversible actions

The confirmation screen lists exactly what will run, the estimated total,
which items need administrator rights, and warnings that apply right now (an
open browser, a running game, an installation in progress).

* You must answer **Y** to start. Anything else cancels, and nothing changes.
* **Recycle Bin:** you must also type `EMPTY` exactly. Anything else leaves
  the Recycle Bin alone.
* **Administrator items:** Windows shows its normal UAC prompt. If you click
  *No*, those items are reported as *Cancelled* and everything else still runs.

### 6. During and after the cleanup

Each category reports one of these statuses:

* **Completed**: everything eligible was deleted.
* **Completed with skipped files**: some files were in use and were left alone. This is normal.
* **Partially completed**: some files could not be deleted (for example, access denied).
* **Failed**: nothing could be done. The reason is shown.
* **Skipped**: a safety condition applied, such as the browser being open, a game running, or an installation in progress.
* **Not applicable**: the folder or program isn't on this PC.
* **Cancelled**: you stopped it, or declined the UAC prompt.

The report then shows:

* free space **before** and **after**, measured by Windows, and the real change (it can be negative)
* the estimate from the scan, and the size of the files actually deleted
* how many files were deleted, kept on purpose, or failed, and why
* how long it took, whether a restart is needed (normally not), and where the log is saved

### 7. Cancelling safely

* Before confirming: press **Esc** or answer **N**. Nothing is deleted.
* During a scan or cleanup: press **Esc** or **Ctrl+C**. The program stops
  after the current file, and reports what was done as *Cancelled*.
* Closing the window with X during a cleanup is also safe for your data:
  each file is deleted on its own, and nothing is left half-written. Only the
  log for that run may be incomplete.

### 8. Logs

Reports are saved in `%LOCALAPPDATA%\aiznm_CLEANER\Logs`. You can paste that
into the Explorer address bar, or use menu **9**.

* One file per scan, cleanup or inventory, for example `aiznm_20261009_194500_cleanup.log`.
* Contents: counts, sizes, statuses, Windows version, and a few example
  paths per error type, with your user folder shortened to `%LOCALAPPDATA%`.
  No file contents, cookies, passwords or full file lists.
* The newest 40 reports are kept. Reports older than 90 days are removed
  automatically. Only files the program created itself are ever removed.

### 9. What it never touches

Downloads, Documents, Desktop, Pictures and other personal folders; browser
cookies, passwords, history, bookmarks, sessions and extensions; Steam,
Riot / VALORANT / Vanguard and other game or launcher files; Windows Update
folders (use Disk Cleanup instead); Prefetch; the component store
(WinSxS); Program Files; restore points; the page file; services; the
registry; BIOS, GPU or power settings. Browsers, Explorer and games are
**never** closed for you.

### 10. Running the tests on your PC (optional)

The test suite creates a temporary sandbox folder and only ever works inside
it. Your real files and folders are never used.

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-AiznmCleaner.ps1
```

Test the Universal edition by adding
`-BatPath .\Download\aiznm_CLEANER_Universal.bat` to the end of that command.

On Windows it also runs the two Windows-only tests: the verified-delete
helper, real file locks, junctions and hard links, and the real folder
checks. Please share the result. Those two tests could not be run where this
version was built.

### 11. Changing the program (optional)

Edit the files in `src/`, then rebuild both editions:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Build-AiznmCleaner.ps1
```

Test T50 fails if a `.bat` file no longer matches what `src/` produces.
