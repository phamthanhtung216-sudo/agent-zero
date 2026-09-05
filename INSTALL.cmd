@echo off
setlocal
title Agent Zero Setup

echo ========================================
echo       AGENT ZERO WINDOWS LAUNCHER
echo ========================================
echo.
echo Dang mo PowerShell de chay installer...

set "AZ_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%AZ_POWERSHELL%" (
    echo.
    echo KHONG TIM THAY WINDOWS POWERSHELL
    echo Expected: %AZ_POWERSHELL%
    echo.
    echo Cua so nay duoc giu mo de ban doc loi.
    pause
    exit /b 1
)

"%AZ_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-agent-zero.ps1" -LauncherOwnsFailurePause %*
set "AZ_INSTALL_EXIT=%ERRORLEVEL%"

if "%AZ_INSTALL_EXIT%"=="0" exit /b 0

echo.
echo POWERSHELL KHONG KHOI DONG HOAC INSTALLER DA DUNG VI LOI
echo Exit code: %AZ_INSTALL_EXIT%
echo Cua so nay duoc giu mo de ban doc thong bao loi ben tren.
echo.
pause
exit /b %AZ_INSTALL_EXIT%
