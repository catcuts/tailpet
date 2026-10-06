@echo off
rem B bootstrap launcher - self-elevating, runs B-Setup.ps1 from same folder
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0B-Setup.ps1"
echo.
echo ==== B bootstrap finished ====
pause
