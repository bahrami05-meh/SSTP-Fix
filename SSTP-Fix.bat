@echo off
rem ===========================================================================
rem  SSTP-Fix.bat  -  one-click repair for "VPN connects, internet dies ~60 s"
rem  Double-click = apply the fix. From an elevated prompt:
rem      SSTP-Fix.bat              apply the fix
rem      SSTP-Fix.bat status       show current state
rem      SSTP-Fix.bat diag         record a 90 s timeline (connect the VPN)
rem      SSTP-Fix.bat restore      undo everything (uses the latest backup)
rem      SSTP-Fix.bat dryrun       show what would change, change nothing
rem  Keep SSTP-Fix.ps1 in the same folder as this file.
rem ===========================================================================
setlocal EnableExtensions
title SSTP VPN Fix
color 07
pushd "%~dp0" 2>nul || (echo Cannot open the script folder. & pause & exit /b 1)

set "MODE=%~1"
if "%MODE%"=="" set "MODE=fix"
if /i "%MODE%"=="help" goto usage
if /i "%MODE%"=="-h"   goto usage
if /i "%MODE%"=="/?"   goto usage

set "PSMODE="
if /i "%MODE%"=="fix"     set "PSMODE=-Mode Fix"
if /i "%MODE%"=="apply"   set "PSMODE=-Mode Fix"
if /i "%MODE%"=="status"  set "PSMODE=-Mode Status"
if /i "%MODE%"=="diag"    set "PSMODE=-Mode Diag -DiagSeconds 90"
if /i "%MODE%"=="restore" set "PSMODE=-Mode Restore"
if /i "%MODE%"=="undo"    set "PSMODE=-Mode Restore"
if /i "%MODE%"=="dryrun"  set "PSMODE=-Mode DryRun"
if not defined PSMODE (
    echo   Unknown option "%MODE%".
    goto usage
)

echo ===========================================================================
echo   SSTP VPN fix  -  Windows 11
echo ===========================================================================
echo.

rem ---------------------------------------------------------------- elevate --
net session >nul 2>&1
if errorlevel 1 (
    echo   Administrator rights are required. Requesting elevation...
    if "%~1"=="" (
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%~1' -Verb RunAs"
    )
    popd
    exit /b
)

if not exist "%~dp0SSTP-Fix.ps1" (
    echo   ERROR: SSTP-Fix.ps1 is missing.
    echo          Both files must sit in the same folder.
    echo.
    pause
    popd
    exit /b 1
)

rem keep any extra switches such as -KeepFallback or -ForceNcsi
set "EXTRA="
shift
:collect
if "%~1"=="" goto run
set "EXTRA=%EXTRA% %1"
shift
goto collect

:run
echo   Mode: %MODE%
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SSTP-Fix.ps1" %PSMODE%%EXTRA%
set "RC=%ERRORLEVEL%"

echo.
echo ===========================================================================
if "%RC%"=="0" (
    echo   Done.
) else (
    echo   Finished with exit code %RC% - see the messages above.
)
echo ===========================================================================
echo.
pause
popd
exit /b %RC%

:usage
echo   Usage:
echo     SSTP-Fix.bat              apply the fix
echo     SSTP-Fix.bat status       show current state
echo     SSTP-Fix.bat diag         record a 90 s timeline
echo     SSTP-Fix.bat restore      undo everything
echo     SSTP-Fix.bat dryrun       preview only
echo.
echo   Optional switches (append after the mode):
echo     -KeepFallback             do not pin profiles to SSTP
echo     -ForceNcsi                restart NlaSvc after each connect
echo.
pause
popd
exit /b 0
