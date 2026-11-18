<#
.SYNOPSIS
  Moves the NuGet global-packages folder and/or the Gradle user home to another drive - or back.

.DESCRIPTION
  Per item: copy (robocopy) -> verify -> point (or un-point) the USER environment variable
  NUGET_PACKAGES / GRADLE_USER_HOME -> delete the old copy.
  Any failure (drive problem, copy error, locked file, failed verification) stops that item BEFORE the
  variable is changed or anything is deleted; re-running resumes. Dry run unless -Apply. No admin needed.

  HDD guard: Gradle's cache is thousands of small files and builds get much slower on a spinning disk,
  so moving Gradle to an HDD is refused unless -AllowHdd. NuGet only gets a warning.

  -Back reverses a move: copies the cache from where the variable points to the default location on the
  profile drive, removes the variable, then deletes the copy on the other drive.

.EXAMPLE
  .\Move-Caches.ps1 -What nuget                 # dry run: NuGet only
  .\Move-Caches.ps1 -What nuget -Apply          # move NuGet to D:\DevCache\nuget\packages
  .\Move-Caches.ps1 -What gradle -Back -Apply   # bring Gradle back to C:\Users\<you>\.gradle
  .\Move-Caches.ps1 -TargetRoot E:\Cache -Apply
#>
[CmdletBinding()]
param(
  [string]$TargetRoot = 'D:\DevCache',
  [string[]]$What = @('nuget', 'gradle'),   # nuget, gradle
  [switch]$Back,                             # restore to the default location instead of moving away
  [switch]$AllowHdd,                         # allow moving Gradle onto a spinning disk
  [switch]$Apply,
  [switch]$Yes,                              # skip the y/N prompt
  [switch]$NoEnvVars,                        # copy + delete only; you set/remove the variables yourself
  [string]$ProfileRoot = $env:USERPROFILE,   # where the default locations live (override only for tests)
  [switch]$PauseAtEnd
)

# Dot-sourcing Cleanuper.ps1 re-runs ITS param block in this scope, so capture our own values first.
$cfg = [pscustomobject]@{
  Root = $TargetRoot; Profile = $ProfileRoot
  What = @($What | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
  Back = [bool]$Back; AllowHdd = [bool]$AllowHdd
  Apply = [bool]$Apply; Yes = [bool]$Yes; NoEnv = [bool]$NoEnvVars; Pause = [bool]$PauseAtEnd
}
. (Join-Path $PSScriptRoot 'Cleanuper.ps1')   # reuse its helpers (OneDrive guard, process checks, sweep engine)

function Stop-Here { if ($cfg.Pause) { Read-Host 'Press Enter to close' | Out-Null } }

function Set-UserEnvVar([string]$Name, [string]$Value) {
  [Environment]::SetEnvironmentVariable($Name, $Value, 'User')      # persistent; also broadcasts the change
  [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')   # this process
}
function Remove-UserEnvVar([string]$Name) {
  [Environment]::SetEnvironmentVariable($Name, [NullString]::Value, 'User')   # real null = delete + broadcast
  if ((Get-Item 'HKCU:\Environment').GetValueNames() -contains $Name) {        # belt and braces: no empty leftovers
    Remove-ItemProperty -Path 'HKCU:\Environment' -Name $Name -ErrorAction SilentlyContinue }
  Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
}

function Get-DriveProblem([string]$Path, [int64]$NeedBytes) {
  $root = [IO.Path]::GetPathRoot($Path)
  if (-not $root -or $root -notmatch '^[A-Za-z]:\\') { return "not a local drive path: $Path" }
  try { $di = New-Object IO.DriveInfo $root } catch { return "drive not found: $root" }
  if (-not $di.IsReady) { return "drive $root is not ready" }
  if ($di.DriveType -ne 'Fixed') { return "drive $root is '$($di.DriveType)', not a fixed disk (builds would break when it is unplugged)" }
  if ($di.DriveFormat -notin 'NTFS', 'ReFS') { return "drive $root is $($di.DriveFormat); NTFS or ReFS is required" }
  if ($di.AvailableFreeSpace -lt $NeedBytes) {
    return ('drive {0} has only {1} free, about {2} needed' -f $root, (Format-Size $di.AvailableFreeSpace), (Format-Size $NeedBytes)) }
  $null
}

function Get-DriveMedia([string]$Path) {   # 'SSD' | 'HDD' | 'Unknown'
  try {
    $letter = ([IO.Path]::GetPathRoot($Path))[0]
    $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
    $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [int]$_.DeviceId -eq $part.DiskNumber } | Select-Object -First 1
    if ($pd -and "$($pd.MediaType)" -in 'SSD', 'HDD') { return "$($pd.MediaType)" }
  } catch {}
  'Unknown'
}

# After the copy: a robocopy list-only pass must find nothing left to copy (extras in the destination are fine).
function Test-CopyComplete([string]$Src, [string]$Dst) {
  & robocopy.exe $Src $Dst /E /L /COPY:DAT /XJ /R:0 /W:0 /NJH /NJS /NFL /NDL /NP | Out-Null
  ($LASTEXITCODE -band 29) -eq 0     # 1 would-copy, 4 mismatch, 8 failed, 16 fatal
}

$defs = @(
  [pscustomobject]@{ Id = 'nuget'; Name = 'NuGet global packages'; Var = 'NUGET_PACKAGES'; SlowOnHdd = $false
    Default = "$($cfg.Profile)\.nuget\packages"; Sub = 'nuget\packages'
    Block = { if (Test-Running 'devenv') { 'Visual Studio is running (close it)' } } },
  [pscustomobject]@{ Id = 'gradle'; Name = 'Gradle user home'; Var = 'GRADLE_USER_HOME'; SlowOnHdd = $true
    Default = "$($cfg.Profile)\.gradle"; Sub = 'gradle'
    Block = { if (Test-Running 'studio64') { 'Android Studio is running (close it)' } elseif (Test-GradleDaemon) { 'a Gradle daemon is running (run: gradlew --stop)' } } }
)

$unknown = @($cfg.What | Where-Object { $_ -notin $defs.Id })
if ($unknown) { Write-Host "Unknown -What value(s): $($unknown -join ', ')  (use: nuget, gradle)" -ForegroundColor Red; exit 2 }

$media = $null; if (-not $cfg.Back) { $media = Get-DriveMedia $cfg.Root }
$title = if ($cfg.Back) { 'Restore caches to their default location' } else { 'Move caches' }
Write-Host ''
Write-Host ('{0}  [{1}]  {2}  C: free={3}' -f $title, $(if ($cfg.Apply) { 'APPLY' } else { 'DRY RUN' }),
  $(if ($cfg.Back) { 'profile drive' } else { "target=$($cfg.Root) ($media)" }), (Format-Size (Get-FreeSpace))) -ForegroundColor Cyan

# ---- plan
$plan = foreach ($d in ($defs | Where-Object { $cfg.What -contains $_.Id })) {
  $cur = [Environment]::GetEnvironmentVariable($d.Var)
  $dflt = [IO.Path]::GetFullPath($d.Default).TrimEnd('\')
  if ($cfg.Back) { $src = $null; if ($cur) { $src = [IO.Path]::GetFullPath($cur).TrimEnd('\') }; $dst = $dflt }
  else {
    if (-not $cur) { $cur = $d.Default }
    $src = [IO.Path]::GetFullPath($cur).TrimEnd('\')
    $dst = [IO.Path]::GetFullPath((Join-Path $cfg.Root $d.Sub)).TrimEnd('\')
  }
  $row = [pscustomobject]@{ Def = $d; Src = $src; Dst = $dst; Action = 'move'; Reason = $null; Note = $null; Bytes = [int64]0; Files = 0 }
  if ($cfg.Back -and -not $src) { $row.Action = 'skip'; $row.Reason = "not moved: $($d.Var) is not set (already using the default location)" }
  elseif ((Test-UnderOneDrive $src) -or (Test-UnderOneDrive $dst)) { $row.Action = 'skip'; $row.Reason = 'inside OneDrive (never touched)' }
  elseif ($src -ieq $dst) { $row.Action = 'skip'; $row.Reason = 'already at the target' }
  elseif ([IO.Path]::GetPathRoot($src) -ieq [IO.Path]::GetPathRoot($dst)) { $row.Action = 'skip'; $row.Reason = "already on drive $([IO.Path]::GetPathRoot($src))" }
  elseif (-not $cfg.Back -and $d.SlowOnHdd -and $media -eq 'HDD' -and -not $cfg.AllowHdd) {
    $row.Action = 'skip'; $row.Reason = "target drive is an HDD; $($d.Name) is thousands of small files and builds get much slower there (override: -AllowHdd)" }
  else {
    $blocked = & $d.Block
    if ($blocked) { $row.Action = 'skip'; $row.Reason = $blocked }
    elseif (-not (Test-Path -LiteralPath $src)) {
      $row.Action = 'envonly'
      $row.Reason = if ($cfg.Back) { "source folder does not exist; only the variable $($d.Var) will be removed" } else { 'source folder does not exist; only the variable will be set' } }
    elseif (-not (Test-SafeTarget $src)) { $row.Action = 'skip'; $row.Reason = "refusing unsafe source path $src" }
    else {
      Write-Host ("  measuring {0} ..." -f $d.Name) -ForegroundColor DarkGray
      $m = Invoke-Sweep -Path $src -Self $false -Keep $null -AgeHours 0 -Delete $false
      $row.Bytes = $m.Bytes; $row.Files = $m.Files
      if (-not $cfg.Back -and $media -eq 'HDD') { $row.Note = 'target is an HDD: builds reading many small files will be slower than on C: (the restore launcher undoes this)' }
    }
  }
  $row
}

$needBytes = [int64](($plan | Where-Object { $_.Action -eq 'move' } | ForEach-Object { $_.Bytes } | Measure-Object -Sum).Sum * 1.1) + 1GB
$driveProblem = $null
$checkPath = if ($cfg.Back) { $cfg.Profile } else { $cfg.Root }
if ($plan | Where-Object { $_.Action -in 'move', 'envonly' }) { $driveProblem = Get-DriveProblem $checkPath $needBytes }
if ($driveProblem) { foreach ($r in $plan) { if ($r.Action -ne 'skip') { $r.Action = 'skip'; $r.Reason = $driveProblem } } }

Write-Host ''
foreach ($r in $plan) {
  Write-Host ('{0}' -f $r.Def.Name) -ForegroundColor White
  if ($r.Src) { Write-Host ('   from   {0}' -f $r.Src) }
  Write-Host ('   to     {0}' -f $r.Dst)
  switch ($r.Action) {
    'move' {
      # (not named $what: PowerShell variable names are case-insensitive and would clobber the -What parameter)
      $steps = if ($cfg.Back) { "will copy back, verify, REMOVE $($r.Def.Var), then delete the old copy" } else { "will copy, verify, set $($r.Def.Var), then delete the old copy" }
      Write-Host ('   size   {0}  ({1} files)   -> {2}' -f (Format-Size $r.Bytes), $r.Files, $steps) -ForegroundColor Green
      if ($r.Note) { Write-Host ('   WARNING: {0}' -f $r.Note) -ForegroundColor Yellow }
    }
    'envonly' { Write-Host ('   {0}' -f $r.Reason) -ForegroundColor Green }
    default { Write-Host ('   SKIPPED: {0}' -f $r.Reason) -ForegroundColor DarkYellow }
  }
}
$todo = @($plan | Where-Object { $_.Action -in 'move', 'envonly' })
if (-not $todo.Count) { Write-Host "`nNothing to do." -ForegroundColor Cyan; Stop-Here; return }
Write-Host ("`nDrive check OK, about {0} needed." -f (Format-Size $needBytes)) -ForegroundColor DarkGray

if (-not $cfg.Apply) {
  Write-Host "`nDry run only - nothing was changed. Re-run with -Apply (or use the launcher) to proceed." -ForegroundColor Cyan
  Stop-Here; return
}
if (-not $cfg.Yes) {
  $q = if ($cfg.Back) { 'Copy back, remove the environment variables and delete the other-drive copies?' } else { 'Copy, switch the environment variables and delete the old copies?' }
  $ans = Read-Host "`n$q [y/N]"
  if ($ans -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; Stop-Here; return }
}

# ---- apply
$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir -ErrorAction SilentlyContinue | Out-Null
$script:LogFile = Join-Path $logDir ('move-caches-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
Write-Log "back=$($cfg.Back) target=$($cfg.Root) what=$($cfg.What -join ',') noEnv=$($cfg.NoEnv)"
$freeBefore = Get-FreeSpace
$results = foreach ($r in $todo) {
  $name = $r.Def.Name; $ok = $false; $msg = ''
  Write-Host ("`n{0}" -f $name) -ForegroundColor White
  try {
    New-Item -ItemType Directory -Force -Path $r.Dst -ErrorAction Stop | Out-Null
    if ($r.Action -eq 'move') {
      Write-Host '  copying (this can take several minutes) ...' -ForegroundColor DarkGray
      & robocopy.exe $r.Src $r.Dst /E /COPY:DAT /DCOPY:DAT /XJ /R:1 /W:1 /MT:16 /NFL /NDL /NP | Out-Host
      $rc = $LASTEXITCODE
      Write-Log "$name robocopy exit=$rc"
      if ($rc -ge 8) { throw "robocopy failed (exit $rc, a file may be locked); nothing was changed or deleted" }
      Write-Host '  verifying ...' -ForegroundColor DarkGray
      if (-not (Test-CopyComplete $r.Src $r.Dst)) { throw 'verification failed: files are missing or differ in the copy; variable NOT changed, old copy NOT deleted' }
      if (-not $cfg.Back) {
        $a = Invoke-Sweep -Path $r.Src -Self $false -Keep $null -AgeHours 0 -Delete $false
        $b = Invoke-Sweep -Path $r.Dst -Self $false -Keep $null -AgeHours 0 -Delete $false
        if ($a.Bytes -ne $b.Bytes -or $a.Files -ne $b.Files) {
          throw ('verification mismatch: source {0} / {1} files, copy {2} / {3} files; variable NOT changed, old copy NOT deleted' -f (Format-Size $a.Bytes), $a.Files, (Format-Size $b.Bytes), $b.Files) }
      }
    }
    if ($cfg.NoEnv) {
      if ($cfg.Back) { Write-Host ('  not changing the variable (-NoEnvVars). Remove it yourself:  reg delete HKCU\Environment /v {0} /f' -f $r.Def.Var) -ForegroundColor Yellow }
      else { Write-Host ('  not changing the variable (-NoEnvVars). Set it yourself:  setx {0} "{1}"' -f $r.Def.Var, $r.Dst) -ForegroundColor Yellow }
    }
    elseif ($cfg.Back) { Remove-UserEnvVar $r.Def.Var; Write-Host ('  removed user variable {0}' -f $r.Def.Var) -ForegroundColor Green }
    else { Set-UserEnvVar $r.Def.Var $r.Dst; Write-Host ('  set user variable {0} = {1}' -f $r.Def.Var, $r.Dst) -ForegroundColor Green }
    if ($r.Action -eq 'move') {
      $del = Invoke-Sweep -Path $r.Src -Self $true -Keep $null -AgeHours 0 -Delete $true
      Write-Log "$name old copy deleted: $(Format-Size $del.Bytes), $($del.Files) files, $($del.Locked) left (locked)"
      # tidy now-empty parent folders, but only below the cache root we created
      $p = Split-Path $r.Src -Parent
      while ($p -and $p.Length -gt $cfg.Root.TrimEnd('\').Length -and $p.StartsWith($cfg.Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        try { if ([IO.Directory]::GetFileSystemEntries($p).Count -eq 0) { [IO.Directory]::Delete($p) } else { break } } catch { break }
        $p = Split-Path $p -Parent
      }
      if ($del.Locked) { $msg = "old copy mostly deleted; $($del.Locked) locked item(s) remain in $($r.Src) - delete it after closing your IDEs" }
      else { $msg = "old copy deleted ($(Format-Size $del.Bytes))" }
    }
    $ok = $true
  }
  catch { $msg = $_.Exception.Message }
  Write-Log "$name ok=$ok $msg"
  Write-Host ('  {0}' -f $msg) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
  [pscustomobject]@{ Name = $name; Ok = $ok }
}

$freeAfter = Get-FreeSpace
Write-Host ('-' * 70)
Write-Host ('C: free before: {0}   after: {1}   (delta {2})' -f (Format-Size $freeBefore), (Format-Size $freeAfter), (Format-Size ($freeAfter - $freeBefore))) -ForegroundColor Green
if (-not $cfg.NoEnv -and ($results | Where-Object { $_.Ok })) {
  Write-Host 'Now RESTART Visual Studio, Android Studio and any open terminals - they read the variables at start.' -ForegroundColor Yellow
  Write-Host 'Android Studio: if Settings > Build > Gradle > "Service directory path" is set explicitly, check it points to the right Gradle folder.' -ForegroundColor DarkGray
}
Write-Host ('Log: {0}' -f $script:LogFile) -ForegroundColor DarkGray
Stop-Here
if ($results | Where-Object { -not $_.Ok }) { exit 1 }
exit 0   # explicit: a leftover robocopy status code (e.g. 2 = "extra files") must not leak as the exit code
