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

`cleanuper.cmd` is a launcher for double-click / `cmd` use (bypasses the execution-policy prompt).
Works on Windows PowerShell 5.1 and PowerShell 7.

## Risk levels

| Level | Meaning | Examples |
|---|---|---|
| **Safe** (default) | Regenerated automatically, no user data | `%TEMP%`, VS Code/VS caches, npm/pip/NuGet HTTP caches, Arduino `staging`, Claude/Copilot caches and logs |
| **Moderate** | Regenerable, but costs time or bandwidth | NuGet packages (re-restored), Gradle caches, Android Studio indexes, AVD snapshots, orphaned VS Code workspace data, Recycle Bin, DISM component cleanup |
| **Aggressive** | May need re-setup or loses history | Claude/Copilot history older than `-HistoryDays`, Claude Desktop runtime copies, VS installer cache, `bin/obj` in repos |
| **explicit-only** | Never part of a level; only via `-Only <id>` | `claude-desktop-vm` (Cowork VM image), `docker-volumes` (data loss) |

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
Pruning does **not** shrink the WSL2 disk file on `C:`. To actually give the space back, quit Docker
Desktop and run `.\Cleanuper.ps1 -Only 'docker-*' -CompactVhdx -Apply -Elevate`
(runs `wsl --shutdown`, then `Optimize-VHD` or `diskpart compact vdisk`).

## Deliberately not touched

`C:\Windows\Installer` and `C:\ProgramData\Package Cache` (needed to repair/uninstall apps), `WinSxS`
(use the `win-component-cleanup` category), AVD images in `~\.android\avd`, installed toolchains
(`Arduino15\packages`, `.platformio\packages`), and other apps' data (CapCut, Teams, WhatsApp...).
`-Hogs` lists them so you can decide.
