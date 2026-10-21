@echo off
rem tailpet agent installer - outbound long-poll agent.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "try { Start-Process -FilePath '%~f0' -Verb RunAs } catch { Write-Host 'UAC declined - right-click and Run as administrator'; pause }"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0agent.ps1" -Install
pause
