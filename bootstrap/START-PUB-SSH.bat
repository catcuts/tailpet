@echo off
rem Public-IP machine bootstrap - installs sshd offline + authorizes A's management key
rem for machines WITH public IP that do NOT join the tailnet
rem generated package: double-click this file, approve UAC, done
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PUB-SSH-Setup.ps1"
echo.
echo ==== Public sshd setup finished ====
pause
