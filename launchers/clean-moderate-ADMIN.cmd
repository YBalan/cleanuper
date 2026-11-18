@echo off
rem ADMIN: cleans SAFE + MODERATE including admin-only items (Windows Temp, Windows Update cache,
rem DISM component cleanup). Moderate includes Gradle caches, Android indexes/snapshots, CapCut old versions
rem + cache and the Recycle Bin - review the plan before answering y. The NuGet packages folder is listed but
rem never deleted (report-only); move it with move-nuget-to-D.cmd instead.
rem Re-launches itself elevated (UAC prompt).
setlocal
title Cleanuper - clean Moderate (Administrator)
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
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Cleanuper.ps1" -Level Moderate -Apply
echo.
echo ---- finished, exit code %errorlevel% ----
pause
