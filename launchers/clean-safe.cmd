@echo off
rem Cleans the SAFE level (temp files and regenerable caches). Shows the plan, asks y/N. No admin needed
rem (admin-only items are skipped; use clean-safe-ADMIN.cmd to include them).
setlocal
title Cleanuper - clean Safe
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Cleanuper.ps1" -Level Safe -Apply
echo.
echo ---- finished, exit code %errorlevel% ----
pause
