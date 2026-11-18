@echo off
rem Interactive menu. The window stays open; every action ends with "pause" and returns here.
rem Choose A to restart the menu as Administrator (UAC prompt); cleaning then also covers admin-only items.
setlocal EnableExtensions
title Cleanuper menu
cd /d "%~dp0.."
set "CU=%~dp0..\Cleanuper.ps1"

set "ADMIN=no"
fltmc >nul 2>&1 && set "ADMIN=YES"
set "EMPTY=0"

:menu
cls
echo ============================================================
echo   CLEANUPER      running as administrator: %ADMIN%
echo ============================================================
echo   SCAN   dry run, deletes nothing
echo     1  Safe level
echo     2  Moderate level
echo     3  Aggressive level
echo   CLEAN  shows the plan and asks y/N before deleting
echo     4  Safe level
echo     5  Moderate level
echo   DOCKER
echo     6  Prune build cache, stopped containers, unused images
echo     7  Shrink the Docker WSL2 disk   needs admin, quit Docker Desktop first
echo   INFO
echo     8  Biggest folders, report only
echo     9  List all categories
echo   CACHES   NuGet / Gradle between C: and D:
echo     M  Open the move / restore menu
echo   A  Restart this menu as Administrator
echo   0  Exit
echo ------------------------------------------------------------
set "C="
set /p "C=Select option: "
rem safety valve: input closed/redirected (set /p then returns empty instantly) -> stop instead of looping forever
if not defined C ( set /a EMPTY+=1 ) else ( set "EMPTY=0" )
if %EMPTY% GEQ 25 exit /b 1

if "%C%"=="1" call :run -Level Safe
if "%C%"=="2" call :run -Level Moderate
if "%C%"=="3" call :run -Level Aggressive
if "%C%"=="4" call :run -Level Safe -Apply
if "%C%"=="5" call :run -Level Moderate -Apply
if "%C%"=="6" call :run -Only "docker-build-cache,docker-containers,docker-images" -Apply
if "%C%"=="7" call :compact
if "%C%"=="8" call :run -Hogs
if "%C%"=="9" call :run -List
if /i "%C%"=="M" goto :movemenu
if /i "%C%"=="A" goto :elevate
if "%C%"=="0" exit /b 0
goto :menu

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%CU%" %*
echo.
echo ---- finished, exit code %errorlevel% ----
pause
exit /b

:movemenu
cls
echo ============================================================
echo   MOVE / RESTORE CACHES      target D:\DevCache
echo   Gradle is refused automatically when the target is an HDD.
echo ============================================================
echo     1  Move NuGet packages     C: to D:
echo     2  Move Gradle home        C: to D:
echo     3  Restore NuGet packages  back to C:
echo     4  Restore Gradle home     back to C:
echo     0  Back to the main menu
echo ------------------------------------------------------------
set "M="
set /p "M=Select option: "
if "%M%"=="1" call :mv -What nuget -Apply
if "%M%"=="2" call :mv -What gradle -Apply
if "%M%"=="3" call :mv -What nuget -Back -Apply
if "%M%"=="4" call :mv -What gradle -Back -Apply
goto :menu

:mv
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Move-Caches.ps1" -TargetRoot "D:\DevCache" %*
echo.
echo ---- finished, exit code %errorlevel% ----
pause
exit /b

:compact
if not "%ADMIN%"=="YES" (
  echo.
  echo This option needs administrator rights. Choose A to restart the menu as Administrator.
  pause
  exit /b
)
call :run -CompactOnly -Apply
exit /b

:elevate
if "%ADMIN%"=="YES" (
  echo Already running as administrator.
  pause
  goto :menu
)
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
if errorlevel 1 ( echo Elevation was cancelled. & pause & goto :menu )
exit /b
