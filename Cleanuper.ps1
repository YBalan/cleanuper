<#
.SYNOPSIS
  Cleanuper - safe, tiered cleanup of temp/cache files for a Windows dev machine.

.DESCRIPTION
  Targets: Windows temp, VS Code, Visual Studio, Android Studio/Gradle, Docker,
  Claude (Code + Desktop), GitHub Copilot, NuGet/npm/pip/Arduino caches.

  DRY RUN BY DEFAULT. Nothing is deleted unless -Apply is given.

  Risk levels (cumulative):
    Safe       Regenerated automatically, no user data (temp files, caches, logs).
    Moderate   Regenerable but costs time/bandwidth (re-download, re-index) or
               is old history (undo checkpoints, orphaned workspace data).
    Aggressive May need manual re-setup or lose history (transcripts, VM images,
               installer caches). Review the list before using.

  Categories flagged ExplicitOnly are never part of a level; select them with -Only.

.EXAMPLE
  .\Cleanuper.ps1                       # dry run, Safe level
  .\Cleanuper.ps1 -Level Moderate       # dry run, Safe + Moderate
  .\Cleanuper.ps1 -Apply                # delete Safe items (asks to confirm)
  .\Cleanuper.ps1 -Apply -Elevate       # same, plus admin-only items (UAC prompt)
  .\Cleanuper.ps1 -Only 'docker-*' -Apply
  .\Cleanuper.ps1 -Level Moderate -Skip nuget-packages -Apply
  .\Cleanuper.ps1 -List                 # show every category
  .\Cleanuper.ps1 -Hogs                 # biggest folders in AppData (report only)
#>
[CmdletBinding()]
param(
  [ValidateSet('Safe', 'Moderate', 'Aggressive')][string]$Level = 'Safe',
  [string[]]$Only,            # category ids / wildcards; overrides -Level
  [string[]]$Skip,            # category ids / wildcards to exclude
  [switch]$Apply,             # actually delete (default is dry run)
  [int]$MinAgeHours = 24,     # items newer than this are kept in age-gated targets
  [int]$HistoryDays = 30,     # retention for Claude/Copilot history categories
  [string[]]$RepoRoots,       # folders to scan for .vs and bin/obj (e.g. D:\source\repos)
  [switch]$List,              # list categories and exit
  [switch]$Hogs,              # report largest folders and exit
  [switch]$CompactVhdx,       # after Docker prune: shrink Docker's WSL2 disk (admin)
  [switch]$Yes,               # skip the confirmation prompt
  [switch]$Elevate,           # relaunch as administrator
  [switch]$PauseAtEnd
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ----------------------------------------------------------------- helpers ---
$Risk = @{ Safe = 1; Moderate = 2; Aggressive = 3 }
$AGE = -1   # marker: "use -MinAgeHours"

function Test-IsAdmin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-Size([double]$b) {
  if ($b -ge 1GB) { '{0:N2} GB' -f ($b / 1GB) }
  elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) }
  elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b / 1KB) }
  else { '{0} B' -f [int64]$b }
}

function Get-FreeSpace { (Get-PSDrive -Name C -ErrorAction SilentlyContinue).Free }

function Write-Log([string]$Message) {
  if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value ('{0:s}  {1}' -f (Get-Date), $Message) -ErrorAction SilentlyContinue }
}

# A target = one folder (or file). Contents are removed; with -Self the folder itself goes too.
# -Age: 0 = no age filter, $AGE = -MinAgeHours, N = N hours.  -Keep: names never deleted at any depth.
function Tgt {
  param([string]$Path, [switch]$Self, [int]$Age = 0, [string[]]$Keep)
  [pscustomobject]@{ Path = $Path; Self = [bool]$Self; Age = $Age; Keep = $Keep }
}
function TgtGlob {
  param([string]$Glob, [switch]$Self, [int]$Age = 0, [string[]]$Keep)
  $literalPrefix = ($Glob -split '[*?\[]')[0]
  if ($literalPrefix -and (Test-UnderOneDrive $literalPrefix)) { return }   # never enumerate inside OneDrive
  Get-ChildItem -Path $Glob -Force -ErrorAction SilentlyContinue |
    ForEach-Object { Tgt $_.FullName -Self:$Self -Age $Age -Keep $Keep }
}

function Test-Running([string[]]$Names) {
  foreach ($n in $Names) { if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $n } }
  $null
}
function Test-GradleDaemon {
  $p = Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'GradleDaemon' }
  [bool]$p
}

# OneDrive is never read, scanned or modified. Pure string checks: these never touch the file system
# (the only listing is of the profile root's own entries, to learn "OneDrive - <org>" folder names).
function Get-OneDriveRoots {
  if ($null -eq $script:OneDriveRoots) {
    $list = @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)
    try { $list += [IO.Directory]::GetDirectories($env:USERPROFILE, 'OneDrive*') } catch {}
    $script:OneDriveRoots = @($list | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') } | Select-Object -Unique)
  }
  $script:OneDriveRoots
}
function Test-UnderOneDrive([string]$Path) {
  try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $true }   # unparseable: treat as protected
  foreach ($d in Get-OneDriveRoots) {
    if ($full -ieq $d -or $full.StartsWith($d + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  $false
}

# Defense in depth: refuse anything that is not clearly a cache location.
function Test-SafeTarget([string]$Path) {
  try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
  if (Test-UnderOneDrive $full) { return $false }
  $root = [IO.Path]::GetPathRoot($full).TrimEnd('\')
  if ($full -ieq $root) { return $false }
  $rest = $full.Substring($root.Length).Trim('\')
  # the system-designated temp folder may be shallow (e.g. TEMP=C:\Temp); everything else needs depth >= 2
  $isTemp = [bool](@($env:TEMP, $env:TMP) | Where-Object { $_ -and $full -ieq $_.TrimEnd('\') })
  if (-not $isTemp -and ($rest -split '\\').Count -lt 2) { return $false }
  $pf86 =${env:ProgramFiles(x86)}
  $exact = @($env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $env:ProgramData, $env:WINDIR,
    $env:ProgramFiles, $pf86, "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Documents",
    "$env:USERPROFILE\Downloads", "$env:USERPROFILE\Pictures", "$env:USERPROFILE\Music",
    "$env:USERPROFILE\Videos", "$env:USERPROFILE\OneDrive", "$env:USERPROFILE\source") | Where-Object { $_ }
  foreach ($d in $exact) { if ($full -ieq $d.TrimEnd('\')) { return $false } }
  $prefix = @("$env:WINDIR\System32", "$env:WINDIR\SysWOW64", "$env:WINDIR\WinSxS", "$env:WINDIR\Installer",
    $env:ProgramFiles, $pf86, "$env:ProgramData\Package Cache") | Where-Object { $_ }
  foreach ($d in $prefix) {
    $d = $d.TrimEnd('\')
    if ($full -ieq $d -or $full.StartsWith($d + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
  }
  $true
}

# --------------------------------------------------------------- the engine ---
# Walks a folder WITHOUT following junctions/symlinks. Returns $true if the folder
# is (or, in dry run, would be) empty afterwards.
function Sweep-Dir {
  param([IO.DirectoryInfo]$Dir, $Acc, [string[]]$Keep, $CutoffUtc, [bool]$Delete)
  $empty = $true
  try { $items = @($Dir.EnumerateFileSystemInfos()) }
  catch { $Acc.Errors += ('enumerate {0}: {1}' -f $Dir.FullName, $_.Exception.Message); return $false }

  foreach ($e in $items) {
    if ($Keep -and ($Keep -contains $e.Name)) { $empty = $false; continue }
    $isLink = [bool]($e.Attributes -band [IO.FileAttributes]::ReparsePoint)
    $isDir = [bool]($e.Attributes -band [IO.FileAttributes]::Directory)

    if ($isDir -and -not $isLink) {
      if (Sweep-Dir -Dir $e -Acc $Acc -Keep $Keep -CutoffUtc $CutoffUtc -Delete $Delete) {
        if ($Delete) { try { $e.Delete() } catch { $empty = $false; $Acc.Locked++ } }
      }
      else { $empty = $false }
      continue
    }

    # file, or a link treated as a leaf (the link is removed, its target is never touched)
    if ($CutoffUtc) {
      $newest = $e.LastWriteTimeUtc; if ($e.CreationTimeUtc -gt $newest) { $newest = $e.CreationTimeUtc }
      if ($newest -gt $CutoffUtc) { $empty = $false; $Acc.Young++; continue }
    }
    $len = 0L; if (-not $isDir -and -not $isLink) { $len = $e.Length }
    if ($Delete) {
      try {
        if (-not $isDir -and $e.IsReadOnly) { $e.IsReadOnly = $false }
        $e.Delete(); $Acc.Bytes += $len; $Acc.Files++
      }
      catch { $Acc.Locked++; $empty = $false; if ($Acc.Errors.Count -lt 5) { $Acc.Errors += ('{0}: {1}' -f $e.FullName, $_.Exception.Message) } }
    }
    else { $Acc.Bytes += $len; $Acc.Files++ }
  }
  return $empty
}

function Invoke-Sweep {
  param([string]$Path, [bool]$Self, [string[]]$Keep, [int]$AgeHours, [bool]$Delete)
  $acc = [pscustomobject]@{ Bytes = [int64]0; Files = 0; Locked = 0; Young = 0; Errors = @() }
  $cutoff = $null; if ($AgeHours -gt 0) { $cutoff = (Get-Date).AddHours(-$AgeHours).ToUniversalTime() }
  if (Test-UnderOneDrive $Path) { $acc.Errors += "skipped, inside OneDrive (never touched): $Path"; return $acc }

  if ([IO.File]::Exists($Path)) {            # single-file target
    $f = New-Object IO.FileInfo $Path
    if ($cutoff -and [Math]::Max($f.LastWriteTimeUtc.Ticks, $f.CreationTimeUtc.Ticks) -gt $cutoff.Ticks) { $acc.Young++; return $acc }
    if ($Delete) { try { $f.IsReadOnly = $false; $f.Delete(); $acc.Bytes += $f.Length; $acc.Files++ } catch { $acc.Locked++ } }
    else { $acc.Bytes += $f.Length; $acc.Files++ }
    return $acc
  }

  $root = New-Object IO.DirectoryInfo $Path
  if (-not $root.Exists) { return $acc }
  if ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    $acc.Errors += "skipped, target is a junction/symlink: $Path"; return $acc
  }
  $empty = Sweep-Dir -Dir $root -Acc $acc -Keep $Keep -CutoffUtc $cutoff -Delete $Delete
  if ($Self -and $Delete -and $empty) { try { $root.Delete() } catch { $acc.Locked++ } }
  $acc
}

function Get-RepoDirs {
  param([string[]]$Roots, [string[]]$Names, [scriptblock]$Accept, [int]$MaxDepth = 8)
  $skip = '.git', 'node_modules', '.hg', '.svn'
  $stack = New-Object System.Collections.Stack
  foreach ($r in $Roots) { if ($r -and -not (Test-UnderOneDrive $r) -and (Test-Path -LiteralPath $r)) { $stack.Push([pscustomobject]@{ P = $r; D = 0 }) } }
  while ($stack.Count) {
    $item = $stack.Pop(); $path = $item.P; $depth = $item.D
    try { $subs = [IO.Directory]::GetDirectories($path) } catch { continue }
    foreach ($s in $subs) {
      if (Test-UnderOneDrive $s) { continue }
      try { if ([IO.File]::GetAttributes($s) -band [IO.FileAttributes]::ReparsePoint) { continue } } catch { continue }
      $n = [IO.Path]::GetFileName($s)
      if ($Names -contains $n) { if (& $Accept $path) { $s }; continue }
      if ($skip -contains $n) { continue }
      if ($depth -lt $MaxDepth) { $stack.Push([pscustomobject]@{ P = $s; D = $depth + 1 }) }
    }
  }
}

# ------------------------------------------------------------ docker helpers ---
function Get-DockerBlock {
  if ($null -ne $script:DockerBlock) { return $script:DockerBlock }
  $script:DockerBlock = ''
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { $script:DockerBlock = 'docker CLI not found' }
  else {
    & docker info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $script:DockerBlock = 'Docker daemon not running (start Docker Desktop)' }
  }
  $script:DockerBlock
}
function ConvertFrom-DockerSize([string]$s) {
  if ($s -match '([\d\.]+)\s*([kKMGT]?B)') {
    $n = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    $m = switch ($Matches[2].ToUpper()) { 'KB' { 1e3 } 'MB' { 1e6 } 'GB' { 1e9 } 'TB' { 1e12 } default { 1 } }
    return [int64]($n * $m)
  }
  [int64]0
}
function Get-DockerReclaimable([string]$Type) {
  if (-not $script:DockerDf) {
    $script:DockerDf = @(& docker system df --format '{{json .}}' 2>$null | ForEach-Object { $_ | ConvertFrom-Json })
  }
  $row = $script:DockerDf | Where-Object { $_.Type -like "$Type*" } | Select-Object -First 1
  if ($row) { ConvertFrom-DockerSize $row.Reclaimable } else { [int64]0 }
}
function Invoke-DockerPrune([string[][]]$Commands) {
  $total = [int64]0
  foreach ($c in $Commands) {
    $out = & docker @c 2>&1
    foreach ($line in $out) { if ("$line" -match 'Total reclaimed space:\s*(.+)$') { $total += ConvertFrom-DockerSize $Matches[1] } }
  }
  $script:DockerDf = $null
  $total
}

# -------------------------------------------------------------- categories ---
function Get-Categories {
  # Script scope on purpose: the Targets scriptblocks below run after this function has returned,
  # so they must resolve these names dynamically (plain locals would be empty by then).
  $script:gLocal = $env:LOCALAPPDATA; $script:gRoam = $env:APPDATA; $script:gUser = $env:USERPROFILE; $script:gTemp = $env:TEMP
  $script:gHist = $HistoryDays * 24
  $script:gGradle = if ($env:GRADLE_USER_HOME) { $env:GRADLE_USER_HOME } else { "$env:USERPROFILE\.gradle" }
  $script:gNuget = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { "$env:USERPROFILE\.nuget\packages" }
  $cats = New-Object System.Collections.ArrayList
  function Add-Cat {
    param([string]$Id, [string]$Group, [string]$Risk, [string]$Desc, [scriptblock]$Targets,
      [switch]$Admin, [switch]$ExplicitOnly, [scriptblock]$Precheck, [scriptblock]$Estimate, [scriptblock]$Run)
    [void]$cats.Add([pscustomobject]@{ Id = $Id; Group = $Group; Risk = $Risk; Desc = $Desc; Targets = $Targets
        Admin = [bool]$Admin; ExplicitOnly = [bool]$ExplicitOnly; Precheck = $Precheck; Estimate = $Estimate; Run = $Run })
  }

  # ---- Windows
  Add-Cat 'user-temp' 'Windows' Safe 'User %TEMP% (older than -MinAgeHours; Claude session temp excluded)' {
    Tgt $gTemp -Age $AGE -Keep 'claude' }
  Add-Cat 'win-temp' 'Windows' Safe 'C:\Windows\Temp (older than -MinAgeHours)' -Admin {
    Tgt "$env:WINDIR\Temp" -Age $AGE }
  Add-Cat 'win-update-download' 'Windows' Safe 'Windows Update download cache' -Admin {
    Tgt "$env:WINDIR\SoftwareDistribution\Download" }
  Add-Cat 'win-caches' 'Windows' Safe 'Crash dumps, error reports, INetCache, DirectX shader cache' {
    Tgt "$gLocal\CrashDumps" -Age $AGE; Tgt "$gLocal\Microsoft\Windows\WER" -Age $AGE
    Tgt "$gLocal\Microsoft\Windows\INetCache" -Age $AGE; Tgt "$gLocal\D3DSCache" -Age $AGE }
  Add-Cat 'recycle-bin' 'Windows' Moderate 'Empty the Recycle Bin on C:' -Estimate {
    $sum = 0L; try { $bin = (New-Object -ComObject Shell.Application).NameSpace(0xA); foreach ($i in $bin.Items()) { $sum += [int64]$i.Size } } catch {}; $sum
  } -Run {
    $b = & { $s = 0L; try { $bin = (New-Object -ComObject Shell.Application).NameSpace(0xA); foreach ($i in $bin.Items()) { $s += [int64]$i.Size } } catch {}; $s }
    Clear-RecycleBin -DriveLetter C -Force -ErrorAction SilentlyContinue; $b }
  Add-Cat 'win-component-cleanup' 'Windows' Moderate 'DISM component store cleanup (WinSxS superseded files; takes minutes)' -Admin -Estimate { -1 } -Run {
    & dism.exe /Online /Cleanup-Image /StartComponentCleanup | Out-Null; -1 }

  # ---- VS Code
  Add-Cat 'vscode-caches' 'VS Code' Safe 'VS Code / Insiders caches, cached VSIXs, logs, abandoned extension temp folders' {
    foreach ($d in "$gRoam\Code", "$gRoam\Code - Insiders") {
      foreach ($s in 'Cache', 'CachedData', 'CachedExtensionVSIXs', 'CachedProfilesData', 'Code Cache', 'GPUCache',
        'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'Service Worker\CacheStorage', 'Service Worker\ScriptCache') { Tgt "$d\$s" }
      Tgt "$d\logs" -Age $AGE; Tgt "$d\Crashpad\completed" -Age $AGE
    }
    TgtGlob "$gUser\.vscode*\extensions\.????????-????-????-????-????????????" -Self -Age $AGE }
  Add-Cat 'vscode-obsolete-extensions' 'VS Code' Moderate 'Old extension versions VS Code itself marked obsolete (.obsolete)' {
    foreach ($ext in Get-ChildItem "$gUser\.vscode*\extensions\.obsolete" -Force -ErrorAction SilentlyContinue) {
      try { $o = Get-Content -LiteralPath $ext.FullName -Raw | ConvertFrom-Json } catch { continue }
      foreach ($p in $o.PSObject.Properties) { if ($p.Value) { Tgt (Join-Path $ext.DirectoryName $p.Name) -Self } }
    } }
  Add-Cat 'vscode-orphan-workspaces' 'VS Code' Moderate 'workspaceStorage of folders that no longer exist (incl. their chat history)' {
    foreach ($ws in Get-ChildItem "$gRoam\Code*\User\workspaceStorage" -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem $_.FullName -Directory -Force -ErrorAction SilentlyContinue }) {
      $j = Join-Path $ws.FullName 'workspace.json'; if (-not (Test-Path -LiteralPath $j)) { continue }
      try { $o = Get-Content -LiteralPath $j -Raw | ConvertFrom-Json } catch { continue }
      $uri = if ($o.folder) { $o.folder } else { $o.workspace }
      if (-not $uri -or $uri -notmatch '^file:///') { continue }       # remote/UNC workspaces: keep
      # Manual parse: [Uri].LocalPath mangles "%3A" drive colons and truncates at '#'.
      $p = [Uri]::UnescapeDataString($uri.Substring(8)) -replace '/', '\'
      if ($p -notmatch '^[A-Za-z]:\\') { continue }                     # unparseable: keep (fail safe)
      if (Test-UnderOneDrive $p) { continue }                           # never probe OneDrive paths: keep
      $drive = [IO.Path]::GetPathRoot($p)
      if ((Test-Path -LiteralPath $drive) -and -not (Test-Path -LiteralPath $p)) { Tgt $ws.FullName -Self }
    } }
  Add-Cat 'vscode-cpptools-ipch' 'VS Code' Moderate 'C/C++ extension IntelliSense precompiled headers (rebuilt on demand)' {
    Tgt "$gLocal\Microsoft\vscode-cpptools\ipch" }

  # ---- Visual Studio
  $vsBlock = { $n = Test-Running 'devenv'; if ($n) { 'Visual Studio is running (close it)' } }
  Add-Cat 'visualstudio-caches' 'Visual Studio' Safe 'MEF ComponentModelCache, Roslyn cache, WebView2 cache' -Precheck $vsBlock {
    TgtGlob "$gLocal\Microsoft\VisualStudio\*\ComponentModelCache"
    Tgt "$gLocal\Microsoft\VisualStudio\Roslyn"; Tgt "$gLocal\Microsoft\VisualStudio\WebView2Cache" }
  Add-Cat 'repo-vs-folders' 'Visual Studio' Moderate '.vs folders inside your repos (needs -RepoRoots; reopening solutions re-indexes)' -Precheck {
    if (-not $RepoRoots) { 'pass -RepoRoots <folder>' } elseif (Test-Running 'devenv') { 'Visual Studio is running (close it)' } } {
    foreach ($d in Get-RepoDirs -Roots $RepoRoots -Names '.vs' -Accept { $true }) { Tgt $d -Self } }
  Add-Cat 'repo-build-output' 'Visual Studio' Aggressive 'bin/ and obj/ next to *proj files in your repos (needs -RepoRoots; forces rebuild)' -Precheck {
    if (-not $RepoRoots) { 'pass -RepoRoots <folder>' } elseif (Test-Running 'devenv') { 'Visual Studio is running (close it)' } } {
    foreach ($d in Get-RepoDirs -Roots $RepoRoots -Names 'bin', 'obj' -Accept { param($parent) [bool][IO.Directory]::GetFiles($parent, '*proj').Count }) { Tgt $d -Self } }
  Add-Cat 'vs-installer-cache' 'Visual Studio' Aggressive 'VS installer package cache (ProgramData\Microsoft\VisualStudio\Packages); offline repair needs re-download' -Admin -Precheck {
    $n = Test-Running 'vs_installer', 'vs_installerservice', 'setup'; if ($n) { "VS installer is running ($n)" } } {
    Tgt "$env:ProgramData\Microsoft\VisualStudio\Packages" }

  # ---- Android Studio / Gradle
  $asBlock = { $n = Test-Running 'studio64'; if ($n) { 'Android Studio is running (close it)' } }
  Add-Cat 'androidstudio-temp' 'Android' Safe 'Android Studio logs/tmp, ~\.android\cache, SDK download leftovers' -Precheck $asBlock {
    TgtGlob "$gLocal\Google\AndroidStudio*\log"; TgtGlob "$gLocal\Google\AndroidStudio*\tmp"
    Tgt "$gUser\.android\cache"; Tgt "$gLocal\Android\Sdk\.temp"; Tgt "$gLocal\Android\Sdk\.downloadIntermediates" }
  Add-Cat 'androidstudio-index' 'Android' Moderate 'Android Studio caches + indexes (equivalent to "Invalidate Caches"; slow first start)' -Precheck $asBlock {
    foreach ($n in 'caches', 'index', 'compile-server') { TgtGlob "$gLocal\Google\AndroidStudio*\$n" } }
  Add-Cat 'androidstudio-old-versions' 'Android' Moderate 'System folders of older Android Studio versions (newest kept; settings in %APPDATA% untouched)' -Precheck $asBlock {
    $vers = Get-ChildItem "$gLocal\Google" -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^AndroidStudio(\d+(\.\d+)+)$' } |
      ForEach-Object { [pscustomobject]@{ Dir = $_; Ver = [version]($_.Name -replace '^AndroidStudio', '') } } | Sort-Object Ver
    if ($vers.Count -gt 1) { foreach ($v in $vers | Select-Object -First ($vers.Count - 1)) { Tgt $v.Dir.FullName -Self } } }
  Add-Cat 'android-avd-snapshots' 'Android' Moderate 'Emulator quick-boot snapshots (emulator cold-boots next time; AVDs themselves are kept)' -Precheck {
    $n = Test-Running 'qemu-system-x86_64', 'qemu-system-aarch64', 'emulator'; if ($n) { "emulator is running ($n)" } } {
    TgtGlob "$gUser\.android\avd\*.avd\snapshots" }
  Add-Cat 'gradle-temp' 'Android' Safe 'Gradle daemon logs and .tmp (older than -MinAgeHours)' {
    Tgt "$gGradle\.tmp"; Tgt "$gGradle\daemon" -Age $AGE }
  Add-Cat 'gradle-caches' 'Android' Moderate 'Gradle caches (dependencies re-downloaded on next build)' -Precheck {
    if (Test-Running 'studio64') { 'Android Studio is running (close it)' } elseif (Test-GradleDaemon) { 'a Gradle daemon is running (gradlew --stop)' } } {
    Tgt "$gGradle\caches" }
  Add-Cat 'gradle-wrapper-dists' 'Android' Aggressive 'Downloaded Gradle distributions (wrapper re-downloads per project)' -Precheck {
    if (Test-GradleDaemon) { 'a Gradle daemon is running (gradlew --stop)' } } {
    Tgt "$gGradle\wrapper\dists" }

  # ---- Docker
  Add-Cat 'docker-build-cache' 'Docker' Safe 'Dangling images + build cache older than -MinAgeHours' -Precheck { Get-DockerBlock } -Estimate {
    Get-DockerReclaimable 'Build' } -Run {
    Invoke-DockerPrune @(, @('builder', 'prune', '-f', '--filter', "until=$($MinAgeHours)h"); , @('image', 'prune', '-f')) }
  Add-Cat 'docker-containers' 'Docker' Moderate 'Stopped containers (their writable layers are lost)' -Precheck { Get-DockerBlock } -Estimate {
    Get-DockerReclaimable 'Containers' } -Run { Invoke-DockerPrune @(, @('container', 'prune', '-f')) }
  Add-Cat 'docker-images' 'Docker' Moderate 'All images not used by a container (re-pulled when needed)' -Precheck { Get-DockerBlock } -Estimate {
    Get-DockerReclaimable 'Images' } -Run { Invoke-DockerPrune @(, @('image', 'prune', '-a', '-f')) }
  Add-Cat 'docker-volumes' 'Docker' Aggressive 'Unused anonymous volumes (DATA LOSS if you relied on them)' -ExplicitOnly -Precheck { Get-DockerBlock } -Estimate {
    Get-DockerReclaimable 'Local Volumes' } -Run { Invoke-DockerPrune @(, @('volume', 'prune', '-f')) }

  # ---- Claude
  Add-Cat 'claude-code' 'Claude' Safe 'Claude Code caches, debug logs, shell snapshots, telemetry (older than 72h)' {
    foreach ($n in 'cache', 'debug', 'shell-snapshots', 'telemetry', 'statsig', 'paste-cache', 'image-cache') { Tgt "$gUser\.claude\$n" -Age 72 }
    Tgt "$gTemp\claude" -Age 72 }
  Add-Cat 'claude-code-file-history' 'Claude' Moderate 'Claude Code undo checkpoints (file-history) older than -HistoryDays' {
    Tgt "$gUser\.claude\file-history" -Age $gHist }
  Add-Cat 'claude-code-transcripts' 'Claude' Aggressive 'Claude Code session transcripts older than -HistoryDays (loses --resume; memory/ folders are kept)' {
    Tgt "$gUser\.claude\projects" -Age $gHist -Keep 'memory' }
  Add-Cat 'claude-desktop-caches' 'Claude' Safe 'Claude Desktop browser/GPU caches' {
    foreach ($base in @(@(Get-ChildItem "$gLocal\Claude-Data" -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object FullName) + "$gRoam\Claude")) {
      foreach ($s in 'Cache', 'Code Cache', 'GPUCache', 'GrShaderCache', 'DawnCache', 'Service Worker\CacheStorage') { Tgt "$base\$s" } } }
  Add-Cat 'claude-desktop-runtime' 'Claude' Aggressive 'Claude Desktop bundled claude-code / claude-code-vm copies (re-downloaded by the app)' {
    foreach ($n in 'claude-code', 'claude-code-vm') { TgtGlob "$gLocal\Claude-Data\*\$n" } }
  Add-Cat 'claude-desktop-vm' 'Claude' Aggressive 'Claude Desktop VM bundle (vm_bundles). Can hold Cowork session files - EXPLICIT ONLY' -ExplicitOnly {
    TgtGlob "$gLocal\Claude-Data\*\vm_bundles" }

  # ---- GitHub Copilot
  Add-Cat 'copilot-cache' 'Copilot' Safe 'Copilot CLI staged updater + logs (older than -MinAgeHours)' {
    Tgt "$gUser\.copilot\updater" -Age $AGE; Tgt "$gUser\.copilot\logs" -Age $AGE }
  Add-Cat 'copilot-db-backups' 'Copilot' Moderate 'Copilot CLI pre-update database backups' {
    TgtGlob "$gUser\.copilot\*.pre-update-backup-*" -Self; TgtGlob "$gUser\.copilot\*.pre-migration-backup" -Self }
  Add-Cat 'copilot-sessions' 'Copilot' Aggressive 'Copilot CLI session history older than -HistoryDays' {
    Tgt "$gUser\.copilot\session-state" -Age $gHist }

  # ---- package caches
  Add-Cat 'nuget-cache' 'Packages' Safe 'NuGet HTTP + plugin caches' {
    Tgt "$gLocal\NuGet\v3-cache"; Tgt "$gLocal\NuGet\plugins-cache"; Tgt "$gLocal\NuGet\Cache" }
  Add-Cat 'nuget-packages' 'Packages' Moderate 'NuGet global packages folder (restored again on next build)' { Tgt $gNuget }
  Add-Cat 'node-caches' 'Packages' Safe 'npm and Yarn download caches' {
    Tgt "$gLocal\npm-cache\_cacache"; Tgt "$gLocal\npm-cache\_logs"; Tgt "$gLocal\Yarn\Cache" }
  Add-Cat 'python-caches' 'Packages' Safe 'pip and uv download caches' { Tgt "$gLocal\pip\Cache"; Tgt "$gLocal\uv\cache" }
  Add-Cat 'arduino-staging' 'Packages' Safe 'Arduino15\staging (downloaded archives of already-installed cores)' { Tgt "$gLocal\Arduino15\staging" }
  Add-Cat 'platformio-cache' 'Packages' Safe 'PlatformIO download cache' { Tgt "$gUser\.platformio\.cache" }

  $cats
}

# --------------------------------------------------------- run one category ---
function Invoke-Category {
  param($Cat, [bool]$Delete)
  $r = [pscustomobject]@{ Bytes = [int64]0; Files = 0; Locked = 0; Young = 0; Errors = @(); Unknown = $false }
  if ($Cat.Run) {
    if ($Delete) { $v = & $Cat.Run } else { $v = & $Cat.Estimate }
    $v = @($v)[-1]
    if ($null -eq $v -or $v -lt 0) { $r.Unknown = $true } else { $r.Bytes = [int64]$v }
    return $r
  }
  foreach ($t in @(& $Cat.Targets)) {
    if (-not $t -or -not $t.Path) { continue }
    if (Test-UnderOneDrive $t.Path) { $r.Errors += "skipped, inside OneDrive (never touched): $($t.Path)"; continue }
    if (-not (Test-Path -LiteralPath $t.Path)) { continue }
    if (-not (Test-SafeTarget $t.Path)) { $r.Errors += "REFUSED unsafe path: $($t.Path)"; continue }
    $hours = $t.Age; if ($hours -lt 0) { $hours = $MinAgeHours }
    $a = Invoke-Sweep -Path $t.Path -Self $t.Self -Keep $t.Keep -AgeHours $hours -Delete $Delete
    $r.Bytes += $a.Bytes; $r.Files += $a.Files; $r.Locked += $a.Locked; $r.Young += $a.Young; $r.Errors += $a.Errors
  }
  $r
}

function Invoke-CompactVhdx {
  param([bool]$Delete)
  $files = @(Get-ChildItem "$env:LOCALAPPDATA\Docker" -Recurse -Filter *.vhdx -Force -ErrorAction SilentlyContinue)
  if (-not $files) { Write-Host '  No Docker WSL2 disks found.'; return }
  foreach ($f in $files) { Write-Host ('  {0}  ({1})' -f $f.FullName, (Format-Size $f.Length)) }
  if (-not $Delete) { Write-Host '  (dry run: would run "wsl --shutdown" and compact the disks above)'; return }
  if (-not (Test-IsAdmin)) { Write-Host '  Compaction needs an elevated shell (use -Elevate).' -ForegroundColor Yellow; return }
  if (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue) {
    Write-Host '  Quit Docker Desktop first (right-click tray icon > Quit), then re-run.' -ForegroundColor Yellow; return }
  & wsl.exe --shutdown
  foreach ($f in $files) {
    $before = $f.Length
    if (Get-Command Optimize-VHD -ErrorAction SilentlyContinue) { Optimize-VHD -Path $f.FullName -Mode Full -ErrorAction SilentlyContinue }
    else {
      $s = Join-Path $env:TEMP 'cleanuper-diskpart.txt'
      "select vdisk file=`"$($f.FullName)`"`r`nattach vdisk readonly`r`ncompact vdisk`r`ndetach vdisk`r`nexit" | Set-Content -LiteralPath $s -Encoding ASCII
      & diskpart.exe /s $s | Out-Null; Remove-Item -LiteralPath $s -Force -ErrorAction SilentlyContinue
    }
    $after = (Get-Item -LiteralPath $f.FullName).Length
    Write-Host ('  compacted {0}: {1} -> {2}' -f $f.Name, (Format-Size $before), (Format-Size $after)) -ForegroundColor Green
  }
}

function Show-Hogs {
  Write-Host "`nLargest folders (report only, nothing is deleted). This can take a few minutes..." -ForegroundColor Cyan
  foreach ($base in $env:LOCALAPPDATA, $env:APPDATA, "$env:USERPROFILE", $env:ProgramData) {
    Write-Host "`n$base" -ForegroundColor White
    Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
      if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
      if ((Test-UnderOneDrive $_.FullName) -or $_.Name -match 'OneDrive') { return }   # OneDrive is never scanned
      $a = Invoke-Sweep -Path $_.FullName -Self $false -Keep $null -AgeHours 0 -Delete $false
      [pscustomobject]@{ Bytes = $a.Bytes; Name = $_.Name }
    } | Sort-Object Bytes -Descending | Select-Object -First 8 | ForEach-Object {
      Write-Host ('  {0,12}  {1}' -f (Format-Size $_.Bytes), $_.Name) }
  }
  Write-Host "`nDeliberately NOT cleaned by this tool:" -ForegroundColor Cyan
  @('C:\Windows\Installer          - MSI patch/repair store; deleting breaks uninstall/repair of installed apps',
    'C:\ProgramData\Package Cache  - installer bootstrap cache needed for repair/uninstall',
    'C:\Windows\WinSxS             - use the win-component-cleanup category (DISM), never delete by hand',
    '~\.android\avd                - your emulator images (use android-avd-snapshots for the cache part)',
    '%LOCALAPPDATA%\Arduino15\packages, ~\.platformio\packages - installed toolchains',
    'Your OneDrive folder           - never read, scanned or modified by this tool',
    'App data of CapCut, Teams, WhatsApp, Office, Autodesk ... - clean via each app''s own settings') |
    ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

# Allow dot-sourcing for tests without running the tool.
if ($MyInvocation.InvocationName -eq '.') { return }

# ------------------------------------------------------------------- main ---
$IsAdmin = Test-IsAdmin
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Skip = @($Skip | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$RepoRoots = @($RepoRoots | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
foreach ($rr in @($RepoRoots)) {
  if (Test-UnderOneDrive $rr) { Write-Host "Ignoring -RepoRoots inside OneDrive (never touched): $rr" -ForegroundColor Yellow }
}
$RepoRoots = @($RepoRoots | Where-Object { -not (Test-UnderOneDrive $_) })

if ($Elevate -and -not $IsAdmin) {
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-PauseAtEnd')
  foreach ($k in $PSBoundParameters.Keys) {
    if ($k -in 'Elevate', 'PauseAtEnd') { continue }
    $v = $PSBoundParameters[$k]
    if ($v -is [switch]) { if ($v) { $argList += "-$k" } }
    elseif ($v -is [array]) { $argList += "-$k"; $argList += ('"{0}"' -f ($v -join ',')) }
    else { $argList += "-$k"; $argList += ('"{0}"' -f $v) }
  }
  Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argList -Verb RunAs
  return
}

$all = Get-Categories

if ($List) {
  $all | Sort-Object Group, @{ e = { $Risk[$_.Risk] } }, Id | ForEach-Object {
    $flags = @(); if ($_.Admin) { $flags += 'admin' }; if ($_.ExplicitOnly) { $flags += 'explicit-only' }
    $c = switch ($_.Risk) { 'Safe' { 'Green' } 'Moderate' { 'Yellow' } default { 'Red' } }
    Write-Host ('{0,-28} ' -f $_.Id) -NoNewline
    Write-Host ('{0,-10} ' -f $_.Risk) -NoNewline -ForegroundColor $c
    Write-Host ('{0,-14} {1}' -f ($flags -join ','), $_.Desc)
  }
  return
}
if ($Hogs) { Show-Hogs; return }

# select categories
if ($Only.Count) {
  $sel = @($all | Where-Object { $id = $_.Id; [bool]($Only | Where-Object { $id -like $_ }) })
  foreach ($o in $Only) { if (-not ($all | Where-Object { $_.Id -like $o })) { Write-Host "Unknown category: $o (see -List)" -ForegroundColor Red; exit 2 } }
}
else { $sel = @($all | Where-Object { $Risk[$_.Risk] -le $Risk[$Level] -and -not $_.ExplicitOnly }) }
if ($Skip.Count) { $sel = @($sel | Where-Object { $id = $_.Id; -not ($Skip | Where-Object { $id -like $_ }) }) }

$mode = if ($Apply) { 'APPLY' } else { 'DRY RUN' }
Write-Host ''
Write-Host ("Cleanuper  [{0}]  level={1}{2}  admin={3}  C: free={4}" -f $mode, $Level, $(if ($Only.Count) { ' (-Only)' } else { '' }), $IsAdmin, (Format-Size (Get-FreeSpace))) -ForegroundColor Cyan
if ($Apply) {
  $logDir = Join-Path $PSScriptRoot 'logs'
  New-Item -ItemType Directory -Force -Path $logDir -ErrorAction SilentlyContinue | Out-Null
  $script:LogFile = Join-Path $logDir ('cleanuper-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
  Write-Log "level=$Level only=$($Only -join ',') skip=$($Skip -join ',') minAgeHours=$MinAgeHours historyDays=$HistoryDays admin=$IsAdmin"
}

# preflight + scan
Write-Host "`nScanning..." -ForegroundColor DarkGray
$plan = foreach ($c in $sel) {
  $reason = $null
  if ($c.Admin -and -not $IsAdmin) { $reason = 'needs admin (-Elevate)' }
  elseif ($c.Precheck) { $reason = & $c.Precheck }
  $res = $null
  if (-not $reason) { Write-Host ("  {0}" -f $c.Id) -ForegroundColor DarkGray; $res = Invoke-Category -Cat $c -Delete $false }
  [pscustomobject]@{ Cat = $c; Reason = $reason; Res = $res }
}

function Show-Plan($rows, [bool]$After) {
  Write-Host ''
  Write-Host ('{0,-28} {1,-10} {2,12} {3,8}  {4}' -f 'CATEGORY', 'RISK', $(if ($After) { 'FREED' } else { 'RECLAIMABLE' }), 'FILES', 'NOTE') -ForegroundColor White
  foreach ($row in $rows) {
    $c = $row.Cat; $col = switch ($c.Risk) { 'Safe' { 'Green' } 'Moderate' { 'Yellow' } default { 'Red' } }
    Write-Host ('{0,-28} ' -f $c.Id) -NoNewline
    Write-Host ('{0,-10} ' -f $c.Risk) -NoNewline -ForegroundColor $col
    if ($row.Reason) { Write-Host ('{0,12} {1,8}  SKIPPED: {2}' -f '-', '-', $row.Reason) -ForegroundColor DarkYellow; continue }
    $sz = if ($row.Res.Unknown) { 'n/a' } else { Format-Size $row.Res.Bytes }
    $note = @(); if ($row.Res.Young) { $note += "$($row.Res.Young) too new, kept" }; if ($row.Res.Locked) { $note += "$($row.Res.Locked) locked/skipped" }
    if ($row.Res.Errors.Count) { $note += "$($row.Res.Errors.Count) warning(s)" }
    Write-Host ('{0,12} {1,8}  {2}' -f $sz, $row.Res.Files, ($note -join '; '))
  }
}

Show-Plan $plan $false
$runnable = @($plan | Where-Object { -not $_.Reason })
$total = ($runnable | ForEach-Object { $_.Res.Bytes } | Measure-Object -Sum).Sum
Write-Host ('{0}' -f ('-' * 70))
Write-Host ('Total reclaimable (estimate): {0}' -f (Format-Size $total)) -ForegroundColor Cyan
foreach ($row in $runnable) { foreach ($e in $row.Res.Errors) { if ($e -like 'REFUSED*' -or $e -like 'skipped*') { Write-Host "  ! $($row.Cat.Id): $e" -ForegroundColor Red } } }

if ($CompactVhdx) { Write-Host "`nDocker WSL2 disk compaction:" -ForegroundColor Cyan }

if (-not $Apply) {
  if ($CompactVhdx) { Invoke-CompactVhdx -Delete $false }
  Write-Host "`nDry run only - nothing was deleted. Re-run with -Apply to clean." -ForegroundColor Cyan
  if ($PauseAtEnd) { Read-Host 'Press Enter to close' | Out-Null }
  return
}

if (-not $runnable.Count) { Write-Host 'Nothing to do.'; if ($PauseAtEnd) { Read-Host 'Press Enter to close' | Out-Null }; return }
if (-not $Yes) {
  $ans = Read-Host ("`nDelete about {0} across {1} categories? [y/N]" -f (Format-Size $total), $runnable.Count)
  if ($ans -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; if ($PauseAtEnd) { Read-Host 'Press Enter to close' | Out-Null }; return }
}

$freeBefore = Get-FreeSpace
Write-Host ''
$done = foreach ($row in $runnable) {
  Write-Host ("Cleaning {0} ..." -f $row.Cat.Id) -ForegroundColor DarkGray
  $res = Invoke-Category -Cat $row.Cat -Delete $true
  Write-Log ("{0}: freed={1} files={2} locked={3} young={4}" -f $row.Cat.Id, (Format-Size $res.Bytes), $res.Files, $res.Locked, $res.Young)
  foreach ($e in $res.Errors) { Write-Log "  $e" }
  [pscustomobject]@{ Cat = $row.Cat; Reason = $null; Res = $res }
}
Show-Plan @($done) $true
$skipped = @($plan | Where-Object { $_.Reason })
foreach ($s in $skipped) { Write-Log ("{0}: SKIPPED {1}" -f $s.Cat.Id, $s.Reason) }

if ($CompactVhdx) { Invoke-CompactVhdx -Delete $true }

$freed = ($done | ForEach-Object { $_.Res.Bytes } | Measure-Object -Sum).Sum
$freeAfter = Get-FreeSpace
Write-Host ('{0}' -f ('-' * 70))
Write-Host ('Deleted: {0}   C: free before: {1}   after: {2}   (delta {3})' -f (Format-Size $freed), (Format-Size $freeBefore), (Format-Size $freeAfter), (Format-Size ($freeAfter - $freeBefore))) -ForegroundColor Green
Write-Host ('Log: {0}' -f $script:LogFile) -ForegroundColor DarkGray
Write-Host 'Note: the Recycle Bin / OneDrive / VHDX files may only release space after the app is restarted or the disk is compacted.' -ForegroundColor DarkGray
if ($PauseAtEnd) { Read-Host 'Press Enter to close' | Out-Null }
