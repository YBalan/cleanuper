@echo off
rem Undo move-nuget-to-D: copies the NuGet packages back to C:\Users\<you>\.nuget\packages, verifies, removes the
rem NUGET_PACKAGES user variable, then deletes the copy on the other drive. Shows the plan, asks y/N. No admin needed.
setlocal
title Cleanuper - restore NuGet to C:
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Move-Caches.ps1" -What nuget -Back -Apply
echo.
echo ---- finished, exit code %errorlevel% ----
pause
