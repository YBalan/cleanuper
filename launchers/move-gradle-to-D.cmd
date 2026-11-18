@echo off
rem Moves the Gradle user home from C: to another drive. Copy -> verify -> set GRADLE_USER_HOME -> delete old.
rem Shows the plan, asks y/N. No admin needed. Close Android Studio and stop Gradle daemons first.
rem HDD GUARD: Gradle's cache is thousands of small files; on a spinning disk builds get much slower, so the
rem tool REFUSES when the target drive is an HDD (it is, on D: of this PC). Set TARGET to an SSD folder to use it.
setlocal
title Cleanuper - move Gradle to another drive
cd /d "%~dp0.."
set "TARGET=D:\DevCache"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Move-Caches.ps1" -TargetRoot "%TARGET%" -What gradle -Apply
echo.
echo ---- finished, exit code %errorlevel% ----
pause
