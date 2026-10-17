@echo off
rem ============================================================================
rem  AI Cockpit - locked-PC probe, batch-file edition (for PCs where even the
rem  .exe version cannot be started). Uses only programs that ship with Windows:
rem  cmd, reg, whoami, curl (Windows 10 1803 or newer), powershell.
rem  It changes nothing and installs nothing; it writes locked_pc_probe_bat_report.txt
rem  next to itself. It sends nothing anywhere except TLS connection attempts
rem  (no request data) to the host names listed below.
rem ============================================================================
setlocal enableextensions
set "OUT=%~dp0locked_pc_probe_bat_report.txt"
echo AI Cockpit - locked-PC probe (batch edition) > "%OUT%" 2>nul
if not exist "%OUT%" set "OUT=%TEMP%\locked_pc_probe_bat_report.txt"
echo AI Cockpit - locked-PC probe (batch edition) > "%OUT%"
call :log "Run on: %DATE% %TIME%"
call :log ""
call :log "== A. This PC =============================================="
for /f "tokens=*" %%i in ('ver') do call :log "%%i"
call :log "User: %USERDOMAIN%\%USERNAME%   Computer: %COMPUTERNAME%"
whoami /groups 2>nul | findstr /c:"S-1-16-12288" /c:"S-1-16-16384" >nul
if errorlevel 1 (call :log "[info] standard (non-elevated) user") else call :log "[info] elevated administrator or system"
call :log "This file: %~f0"
call :log ""
call :log "== B. Where this user may write ============================="
call :wtest "this folder" "%~dp0"
call :wtest "%%%%TEMP%%%%" "%TEMP%\"
call :wtest "%%%%LOCALAPPDATA%%%%" "%LOCALAPPDATA%\"
call :wtest "%%%%APPDATA%%%%" "%APPDATA%\"
call :log ""
call :log "== C. May a program run from a user-writable folder? ========"
rem A signed Microsoft program copied into a user folder: if even THIS is blocked, the PC uses path rules (AppLocker/SRP) that only allow chosen folders.
copy /y "%SystemRoot%\System32\whoami.exe" "%TEMP%\lpp_whoami_copy.exe" >nul 2>&1
if not exist "%TEMP%\lpp_whoami_copy.exe" (
  call :log "[WARN] could not copy a program into %%%%TEMP%%%% (security software?)"
) else (
  "%TEMP%\lpp_whoami_copy.exe" >nul 2>&1
  if errorlevel 1 (call :log "[FAIL] a signed Microsoft program was BLOCKED from running in %%%%TEMP%%%%: the PC allows programs only from chosen folders (path rules).") else call :log "[PASS] a signed Microsoft program ran from %%%%TEMP%%%%"
  del /q "%TEMP%\lpp_whoami_copy.exe" >nul 2>&1
)
call :log "       (This batch edition cannot test an UNSIGNED program; the .exe edition does. If the .exe could not start at all, the PC runs only signed or listed programs.)"
call :log ""
call :log "== D. Application control and PowerShell ====================="
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\SrpV2" >nul 2>&1
if errorlevel 1 (call :log "[info] no AppLocker rules in the registry") else (
  call :log "[WARN] AppLocker rules are defined (EnforcementMode 1 = enforced, 0 = audit only):"
  reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\SrpV2" /s 2>nul | findstr /i "EnforcementMode SrpV2" >> "%OUT%"
)
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers" /v DefaultLevel >nul 2>&1
if errorlevel 1 (
  call :log "[info] no Software Restriction Policy default level is set: nothing is blocked by default"
) else (
  call :log "[WARN] a Software Restriction Policy default level is set (0x40000 = Unrestricted, nothing blocked; 0x0 = Disallowed, everything not allowed by a rule is blocked):"
  reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers" /v DefaultLevel 2>nul | findstr DefaultLevel >> "%OUT%"
)
powershell -NoProfile -NonInteractive -Command "'PowerShell language mode: ' + $ExecutionContext.SessionState.LanguageMode; 'WDAC user-mode enforcement (0 off, 1 audit, 2 enforced): ' + (Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard).UsermodeCodeIntegrityPolicyEnforcementStatus" >> "%OUT%" 2>&1
if errorlevel 1 (call :log "[info] PowerShell could not be run") else call :log "[info] PowerShell answered: see the two lines at the end of this report"
call :log ""
call :log "== E. Network ==============================================="
for /f "tokens=3*" %%a in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable 2^>nul ^| findstr ProxyEnable') do call :log "ProxyEnable = %%a"
for /f "tokens=3*" %%a in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer 2^>nul ^| findstr ProxyServer') do call :log "ProxyServer = %%a %%b"
for /f "tokens=3*" %%a in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v AutoConfigURL 2^>nul ^| findstr AutoConfigURL') do call :log "AutoConfigURL (PAC) = %%a %%b"
where curl >nul 2>&1
if errorlevel 1 (
  call :log "[WARN] curl.exe is not available: connection tests skipped"
  goto :done
)
call :log "Reaching the AI services (a TLS connection, no data sent; http=404, 200 or 401 all mean REACHED):"
call :ctest api.anthropic.com
call :ctest generativelanguage.googleapis.com
call :ctest api.openai.com
call :ctest openrouter.ai
call :ctest huggingface.co
call :ctest api.groq.com
call :ctest cockpit.ruggi.site
call :ctest github.com
:done
call :log ""
call :log "== Done ====================================================="
call :log "Report saved: %OUT%"
call :log "Please send that file to whoever is helping you. Not covered: company policy about sending work data to AI services."
echo.
echo Press any key to close.
pause >nul
exit /b 0

:log
echo.%~1
echo.%~1>> "%OUT%"
exit /b 0

:wtest
set "T=%~2lpp_write_test_%RANDOM%.tmp"
( echo x > "%T%" ) 2>nul
if exist "%T%" (
  del /q "%T%" >nul 2>&1
  call :log "[PASS] can write in %~1  (%~2)"
) else call :log "[FAIL] CANNOT write in %~1  (%~2)"
exit /b 0

:ctest
set "R="
for /f "delims=" %%l in ('curl.exe -sS -o NUL --connect-timeout 6 --max-time 10 -w "http=%%{http_code} tls_verify=%%{ssl_verify_result} ip=%%{remote_ip}" "https://%~1/" 2^>^&1') do set "R=%%l"
if defined R (call :log "%~1 : %R%") else call :log "%~1 : no answer"
exit /b 0
