@echo off
rem Dry run, Moderate level. Deletes NOTHING - just shows what could be freed. No admin needed.
setlocal
title Cleanuper - scan (dry run)
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Cleanuper.ps1" -Level Moderate
echo.
echo ---- finished, exit code %errorlevel% ----
pause
