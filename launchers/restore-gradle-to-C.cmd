@echo off
rem Undo move-gradle-to-D: copies the Gradle home back to C:\Users\<you>\.gradle, verifies, removes the
rem GRADLE_USER_HOME user variable, then deletes the copy on the other drive. Shows the plan, asks y/N.
rem No admin needed. Close Android Studio and stop Gradle daemons first.
setlocal
title Cleanuper - restore Gradle to C:
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Move-Caches.ps1" -What gradle -Back -Apply
echo.
echo ---- finished, exit code %errorlevel% ----
pause
