@echo off
rem tailpet C-machine SSH server installer - offline, machine-agnostic.
rem Needs OpenSSH-Win64.zip (or extracted OpenSSH-Win64 folder) NEXT TO THIS SCRIPT.
rem Binds nothing: no hub/token/IP/publickey. Password auth uses each account's
rem EXISTING Windows login password - this script never changes any password.
setlocal EnableExtensions

rem absolute powershell path: PATH can be broken inside elevated contexts
set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PWSH%" (
    echo [ERROR] PowerShell not found: %PWSH%
    echo Install PowerShell first, then re-run this script.
    echo.
    pause
    exit /b 1
)

set "OPENSSH_DIR=%ProgramFiles%\OpenSSH"
set "ZIP_SRC=%~dp0OpenSSH-Win64.zip"

echo === tailpet install-sshd (offline OpenSSH Server) ===
echo Target dir: %OPENSSH_DIR%
echo.

if exist "%ZIP_SRC%" goto extract
if exist "%~dp0OpenSSH-Win64\sshd.exe" goto copydir
echo [ERROR] OpenSSH-Win64.zip not found next to this script.
echo Keep install-sshd.bat and OpenSSH-Win64.zip in the SAME folder.
echo.
pause
exit /b 1

:copydir
if exist "%OPENSSH_DIR%\sshd.exe" goto have_payload
echo Found extracted OpenSSH-Win64 beside script - copying...
if not exist "%OPENSSH_DIR%" mkdir "%OPENSSH_DIR%"
xcopy "%~dp0OpenSSH-Win64\*" "%OPENSSH_DIR%\" /e /i /y >nul
goto have_payload

:extract
rem zip may store files at top level or under an OpenSSH-Win64 folder - accept both
if exist "%OPENSSH_DIR%\sshd.exe" goto have_payload
if exist "%OPENSSH_DIR%\OpenSSH-Win64\sshd.exe" goto have_payload
echo Extracting OpenSSH-Win64.zip ...
if not exist "%OPENSSH_DIR%" mkdir "%OPENSSH_DIR%"
"%PWSH%" -NoProfile -Command "$s = New-Object -ComObject Shell.Application; $s.NameSpace('%OPENSSH_DIR%').CopyHere($s.NameSpace('%ZIP_SRC%').Items(), 16)"
rem Shell COM CopyHere is async - poll for payload
set /a tries=0
:waitloop
if exist "%OPENSSH_DIR%\sshd.exe" goto have_payload
if exist "%OPENSSH_DIR%\OpenSSH-Win64\sshd.exe" goto have_payload
ping -n 3 127.0.0.1 >nul
set /a tries+=1
if %tries% lss 90 goto waitloop
echo [ERROR] extraction timed out. Target dir contents:
dir /b "%OPENSSH_DIR%" 2>nul
echo.
pause
exit /b 1

:have_payload
if exist "%OPENSSH_DIR%\OpenSSH-Win64\sshd.exe" (
    set "PAYLOAD=%OPENSSH_DIR%\OpenSSH-Win64"
) else (
    set "PAYLOAD=%OPENSSH_DIR%"
)
goto install

:install
echo Payload ready: %PAYLOAD%
pushd "%PAYLOAD%"
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File ".\install-sshd.ps1"
set "INS_RC=%errorlevel%"
popd
if not "%INS_RC%"=="0" echo [WARN] install-sshd.ps1 exited %INS_RC% - continuing.
echo.

rem install-sshd.ps1 does NOT create a firewall rule - add it here (idempotent)
echo Adding firewall rule: inbound TCP 22 allow ...
netsh advfirewall firewall delete rule name="OpenSSH-Server-In-TCP" >nul 2>&1
netsh advfirewall firewall add rule name="OpenSSH-Server-In-TCP" dir=in action=allow protocol=TCP localport=22 >nul
if %errorlevel% neq 0 echo [WARN] firewall rule add failed ^(errorlevel %errorlevel%^).

rem install-sshd.ps1 leaves the service Manual - switch to auto + start now
sc config sshd start= auto >nul 2>&1
net start sshd >nul 2>&1

echo Waiting for sshd to listen on 22 ...
set /a tries=0
:svcloop
netstat -an | findstr /C:":22 " | findstr /i "LISTENING" >nul && goto up
ping -n 2 127.0.0.1 >nul
set /a tries+=1
if %tries% lss 15 goto svcloop

echo [ERROR] sshd is NOT listening on 22.
sc query sshd | findstr /i "STATE"
echo Hint: check sshd log at %ProgramData%\ssh\logs\sshd.log
echo.
pause
exit /b 1

:up
netstat -an | findstr /C:":22 " | findstr /i "LISTENING"
echo.
echo === DONE: sshd installed, auto-start ON, listening on 22 ===
echo Password = each account's EXISTING Windows login password (none was changed).
echo   Blank-password accounts cannot log in over the network - set one if needed:
echo   net user administrator *
echo Test from the B machine:
echo   ssh-p ^<password^> administrator@^<this-machine-IP^> hostname
echo.
pause
