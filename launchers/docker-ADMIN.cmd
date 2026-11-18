@echo off
rem ADMIN: two steps. (1) prune Docker build cache, stopped containers and unused images - Docker Desktop must be
rem RUNNING. (2) shrink the WSL2 disk file on C: so the space is really returned - Docker Desktop must be QUIT.
rem Named volumes / data volumes are never touched. Re-launches itself elevated (UAC prompt).
setlocal
title Cleanuper - Docker prune + compact (Administrator)
cd /d "%~dp0.."
fltmc >nul 2>&1
if errorlevel 1 (
  if /i "%~1"=="elevated" (
    echo Could not obtain administrator rights.
    pause
    exit /b 1
  )
  echo Requesting administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated' -Verb RunAs"
  if errorlevel 1 ( echo Elevation was cancelled. & pause )
  exit /b
)
echo === Step 1 of 2: prune - Docker Desktop must be running ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Cleanuper.ps1" -Only "docker-build-cache,docker-containers,docker-images" -Apply
echo.
echo === Step 2 of 2: shrink the WSL2 disk ===
echo Now QUIT Docker Desktop: tray icon, right click, Quit. Wait until it has fully exited.
echo If you only wanted the prune, close this window instead.
pause
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Cleanuper.ps1" -CompactOnly -Apply
echo.
echo ---- finished, exit code %errorlevel% ----
pause
