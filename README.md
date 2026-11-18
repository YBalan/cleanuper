# Cleanuper

Safe, tiered cleanup of temp/cache files on a Windows dev machine: Windows temp, VS Code,
Visual Studio, Android Studio/Gradle, Docker, Claude (Code + Desktop), GitHub Copilot,
NuGet/npm/pip/Arduino caches.

**Dry run by default.** Nothing is deleted unless you pass `-Apply`.

```powershell
.\Cleanuper.ps1                        # dry run, Safe level: shows what would be freed
.\Cleanuper.ps1 -Level Moderate        # dry run, Safe + Moderate
.\Cleanuper.ps1 -Apply                 # delete Safe items (asks to confirm)
.\Cleanuper.ps1 -Apply -Elevate        # also admin-only items (UAC prompt)
.\Cleanuper.ps1 -Level Moderate -Skip nuget-packages -Apply
.\Cleanuper.ps1 -Only 'docker-*' -Apply
.\Cleanuper.ps1 -RepoRoots D:\source\repos -Level Moderate   # also .vs folders in your repos
.\Cleanuper.ps1 -List                  # every category, risk and description
.\Cleanuper.ps1 -Hogs                  # biggest folders in AppData etc. (report only)
```

`cleanuper.cmd` passes any arguments through (for use from a terminal). The report tables are sorted by size,
largest first. Works on Windows PowerShell 5.1 and PowerShell 7.

## Double-click launchers (`launchers\`)

Every launcher keeps its window open (`pause`) and ends by showing the exit code. Cleaning launchers show the
plan first and ask `y/N`.

| File | Admin | What it does |
|---|---|---|
| `cleanuper-menu.cmd` | optional (`A` restarts it elevated) | Menu: scan Safe/Moderate/Aggressive, clean Safe/Moderate, Docker prune, Docker disk shrink, biggest folders, list categories |
| `scan.cmd` | no | Dry run, Moderate level |
| `clean-safe.cmd` | no | Clean Safe level (admin-only items skipped) |
| `clean-safe-ADMIN.cmd` | **yes** (self-elevates) | Clean Safe level incl. `C:\Windows\Temp` and the Windows Update cache |
| `clean-moderate-ADMIN.cmd` | **yes** (self-elevates) | Clean Safe + Moderate incl. DISM component cleanup |
| `docker-ADMIN.cmd` | **yes** (self-elevates) | Step 1 prune (Docker running), step 2 shrink the WSL2 disk (Docker quit) |
| `move-nuget-to-D.cmd` | no | Moves the NuGet packages folder to `D:\DevCache` (see below) |
| `move-gradle-to-D.cmd` | no | Moves the Gradle home; **refused automatically when the target is an HDD** |
| `restore-nuget-to-C.cmd` | no | Undoes the NuGet move: copies back to `C:`, removes the variable |
| `restore-gradle-to-C.cmd` | no | Undoes the Gradle move |
| `hogs.cmd` | no | Report of the biggest folders, deletes nothing |

The menu's `M` entry opens the same four move/restore actions.

If UAC is declined, or elevation fails, the launcher says so and stops (it never loops).

## Moving NuGet and Gradle to another drive (`Move-Caches.ps1`)

Instead of deleting the 12 GB NuGet packages folder and the Gradle home, keep them and put them on a drive with space.

```powershell
.\Move-Caches.ps1 -What nuget                 # dry run: sizes, target, drive type and checks
.\Move-Caches.ps1 -What nuget -Apply          # asks y/N, then moves NuGet to D:\DevCache\nuget\packages
.\Move-Caches.ps1 -What gradle -Back -Apply   # brings Gradle back to C:\Users\<you>\.gradle
.\Move-Caches.ps1 -TargetRoot E:\Cache -Apply # another drive; -What nuget,gradle is the default
```

Per item: **copy (robocopy) -> verify (a list-only robocopy pass finds nothing left, plus file count and bytes) ->
set the user variable `NUGET_PACKAGES` / `GRADLE_USER_HOME` -> delete the old copy.** Any failure (copy error, locked
file, mismatch) stops that item before the variable is changed or anything is deleted; re-running resumes the copy.
It refuses a target that is not a fixed NTFS/ReFS disk or lacks free space, refuses to run while Visual Studio,
Android Studio or a Gradle daemon is open, and never reads OneDrive. No admin needed.

**HDD guard.** The target drive's media type is detected. Gradle's cache is thousands of small files and builds get
much slower on a spinning disk, so moving Gradle to an HDD is refused unless you pass `-AllowHdd`; NuGet only gets a
warning (package DLLs are read at build time, so expect somewhat slower builds). On this PC `D:` is an HDD and `C:` an
NVMe SSD, so use D: for cold data only.

`-Back` reverses a move: copy to the default location, verify, **remove** the variable, delete the other-drive copy
(extra files already present in the default folder are kept). After any move, restart Visual Studio, Android Studio
and open terminals (they read the variables at start). If Android Studio has "Service directory path" set explicitly
(Settings > Build > Gradle), check it points to the right folder. The `gradle-caches` cleanup category acts on wherever
`GRADLE_USER_HOME` points; `nuget-packages` is report-only (shown, never deleted).

## CapCut (`capcut-*` categories, Moderate)

CapCut keeps everything under `%LOCALAPPDATA%\CapCut`: `Apps\<version>` (one ~1.5-1.8 GB folder per update, older ones
are never removed by the app), `User Data\Cache` (regenerable) and `User Data\Projects` (your drafts).
`capcut-old-versions` removes all but the newest 2 version folders and `capcut-cache` clears the cache; both skip while
CapCut is running, and **Projects are never touched**. Moving the whole folder to an HDD is not recommended: the cache
is read while you scrub the timeline and the app files at start-up, both of which get slower.

## Risk levels

| Level | Meaning | Examples |
|---|---|---|
| **Safe** (default) | Regenerated automatically, no user data | `%TEMP%`, VS Code/VS caches, npm/pip/NuGet HTTP caches, Arduino `staging`, Claude/Copilot caches and logs |
| **Moderate** | Regenerable, but costs time or bandwidth | Gradle caches, CapCut old versions + cache, Android Studio indexes, AVD snapshots, orphaned VS Code workspace data, Recycle Bin, DISM component cleanup |
| **Aggressive** | May need re-setup or loses history | Claude/Copilot history older than `-HistoryDays`, VS installer cache, `bin/obj` in repos |
| **explicit-only** | Never part of a level; only via `-Only <id>` | `docker-volumes` (data loss) |
| **report-only** | Listed with its size, never deleted, not counted in the total, even if you answer Yes | `nuget-packages` (12 GB: move it with `move-nuget-to-D.cmd` instead of deleting) |

## Safety rules built into the engine

- **OneDrive is never read, scanned or modified.** Any path inside your OneDrive folder(s) is refused before the file
  system is touched, including `-RepoRoots`, `-Hogs`, and VS Code workspaces that live there (those are kept).
- No external `find`/`find.exe` is ever invoked; enumeration uses PowerShell and .NET only.
- Dry run unless `-Apply`; confirmation prompt unless `-Yes`; every `-Apply` run writes `logs\cleanuper-*.log`.
- Junctions/symlinks are never followed (a link is removed, its target is untouched); a target that *is* a link is refused.
- Every path passes an allow/deny check first: drive roots, profile root, `AppData`, Documents/Desktop/Downloads,
  `System32`, `WinSxS`, `Windows\Installer`, `Program Files`, `Package Cache` are always refused.
- Age gates (`-MinAgeHours`, default 24) protect files a running tool is using; locked files are skipped and counted.
- Claude Code `projects\*\memory` folders are never deleted, whatever the level.
- Tools that must be closed (Visual Studio, Android Studio, Gradle daemon, emulator, VS installer) make their
  categories **skip** with a reason instead of risking corruption.
- VS Code orphan detection fails safe: a workspace is only removed when its folder URI parses to a local
  drive path, that drive is mounted, and the path is missing.

## Docker

Prune categories need the daemon running (`docker info` must succeed); otherwise they are skipped.
Docker's data lives in a WSL2 disk file wherever Docker Desktop was told to put it (found via the WSL registration);
on this machine that is `D:\Docker\wsl\data`, so pruning/compacting frees **D:, not C:**. The scan table flags such
rows ("frees drive D:, not C:") and leaves them out of the C: total.

Pruning does **not** shrink the WSL2 disk file itself. To actually give the space back, quit Docker
Desktop and run `.\Cleanuper.ps1 -CompactOnly -Apply -Elevate` (or use `launchers\docker-ADMIN.cmd`, which does
prune then compact). It runs `wsl --shutdown`, then `Optimize-VHD` or `diskpart compact vdisk`.

`-Only` wildcards never select explicit-only categories, so `-Only 'docker-*'` will not prune volumes;
that needs the exact id `-Only docker-volumes`.

## Deliberately not touched

`C:\Windows\Installer` and `C:\ProgramData\Package Cache` (needed to repair/uninstall apps), `WinSxS`
(use the `win-component-cleanup` category), AVD images in `~\.android\avd`, installed toolchains
(`Arduino15\packages`, `.platformio\packages`), Claude Desktop's data folder `%LOCALAPPDATA%\Claude-Data` (its own README says not to delete or move anything in it;
free space from Claude > Settings > This computer > System > Storage), and other apps' data (Teams, WhatsApp...).
`-Hogs` lists them so you can decide.
