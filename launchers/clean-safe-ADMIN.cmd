@echo off
rem ADMIN: cleans the SAFE level including admin-only items (C:\Windows\Temp, Windows Update download cache).
rem Re-launches itself elevated (UAC prompt), shows the plan, asks y/N.
setlocal
title Cleanuper - clean Safe (Administrator)
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
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Cleanuper.ps1" -Level Safe -Apply
echo.
echo ---- finished, exit code %errorlevel% ----
pause
