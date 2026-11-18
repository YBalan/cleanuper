@echo off
rem Report only: the biggest folders in AppData / profile / ProgramData. Deletes nothing. Takes a few minutes.
setlocal
title Cleanuper - biggest folders
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Cleanuper.ps1" -Hogs
echo.
echo ---- finished, exit code %errorlevel% ----
pause
