@echo off
setlocal
title Agent Zero Update

echo ========================================
echo        AGENT ZERO UPDATE
echo ========================================
echo.
echo Dang kiem tra ban cap nhat on dinh...

set "AZ_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%AZ_POWERSHELL%" (
    echo.
    echo KHONG TIM THAY WINDOWS POWERSHELL
    echo Expected: %AZ_POWERSHELL%
    echo.
    pause
    exit /b 1
)

rem Keep Windows PowerShell module discovery independent from the host shell.
rem This prevents PowerShell 7 module paths from shadowing Windows PowerShell utilities.
set "AZ_WINDOWS_PSMODULEPATH=%USERPROFILE%\Documents\WindowsPowerShell\Modules;%ProgramFiles%\WindowsPowerShell\Modules;%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules"
set "PSModulePath=%AZ_WINDOWS_PSMODULEPATH%"

set "AZ_UPDATE_ENGINE=%~dp0payload\scripts\update-agent-zero.ps1"
set "AZ_UPDATE_TARGET=%~dp0.."
rem The trailing backslash in %%~dp0 can escape the closing quote passed to PowerShell.
set "AZ_UPDATE_KIT=%~dp0."

if not exist "%AZ_UPDATE_ENGINE%" (
    set "AZ_UPDATE_ENGINE=%~dp0scripts\update-agent-zero.ps1"
    set "AZ_UPDATE_TARGET=%~dp0.."
    set "AZ_UPDATE_KIT="
)

if not exist "%AZ_UPDATE_ENGINE%" (
    echo.
    echo AZ-UPDATE-ENGINE-MISSING
    echo Khong tim thay update-agent-zero.ps1 trong kit hoac ban cai.
    echo Hay mo UPDATE.md de xem cach khoi phuc bang agent AI hien tai.
    echo.
    pause
    exit /b 1
)

if defined AZ_UPDATE_KIT (
    "%AZ_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%AZ_UPDATE_ENGINE%" -TargetPath "%AZ_UPDATE_TARGET%" -LocalKitPath "%AZ_UPDATE_KIT%" -LauncherOwnsFailurePause %*
) else (
    "%AZ_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%AZ_UPDATE_ENGINE%" -TargetPath "%AZ_UPDATE_TARGET%" -LauncherOwnsFailurePause %*
)
set "AZ_UPDATE_EXIT=%ERRORLEVEL%"

echo.
if "%AZ_UPDATE_EXIT%"=="0" (
    echo Agent Zero update da ket thuc. Xem ket qua phia tren.
) else (
    echo UPDATE DA DUNG AN TOAN - exit code %AZ_UPDATE_EXIT%
    echo Ban cai cu va snapshot khong bi xoa.
)
echo.
pause
exit /b %AZ_UPDATE_EXIT%
