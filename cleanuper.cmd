@echo off
rem Launcher: runs Cleanuper.ps1 with Windows PowerShell, bypassing the execution-policy prompt.
rem Usage: cleanuper.cmd [same arguments as Cleanuper.ps1]   e.g.  cleanuper.cmd -Apply -Elevate
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Cleanuper.ps1" %*
