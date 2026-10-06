@echo off
rem S bootstrap launcher - self-elevating, runs S-Setup.ps1 from same folder
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0S-Setup.ps1"
echo.
echo ==== S bootstrap finished (or paused for reboot) ====
pause
