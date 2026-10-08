@echo off
rem LAN-only machine (C) bootstrap - installs sshd offline, authorizes B's key
rem generated package: double-click this file, approve UAC, done
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0LAN-SSH-Setup.ps1"
echo.
echo ==== LAN sshd setup finished ====
pause
