@echo off
rem Moves the NuGet packages folder from C: to D:  (D:\DevCache\nuget\packages).
rem Copy -> verify -> set user variable NUGET_PACKAGES -> delete the old copy. Shows the plan, asks y/N.
rem No admin needed. Close Visual Studio first (the launcher refuses to run while it is open).
rem NOTE: if the target drive is an HDD, builds that read many package files get somewhat slower;
rem restore-nuget-to-C.cmd undoes the move. Edit TARGET to use another drive or folder.
setlocal
title Cleanuper - move NuGet to D:
cd /d "%~dp0.."
set "TARGET=D:\DevCache"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Move-Caches.ps1" -TargetRoot "%TARGET%" -What nuget -Apply
echo.
echo ---- finished, exit code %errorlevel% ----
pause
