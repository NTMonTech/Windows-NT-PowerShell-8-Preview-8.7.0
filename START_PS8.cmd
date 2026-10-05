@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Windows PowerShell 8 Preview 8.7.0
cd /d "%~dp0"
set "NT_PS8_HOME=%~dp0"
if exist "A:\" (
  if not exist "A:\NTPS8_RUNTIME_TEMP" mkdir "A:\NTPS8_RUNTIME_TEMP"
  if exist "A:\NTPS8_RUNTIME_TEMP" (
    set "TEMP=A:\NTPS8_RUNTIME_TEMP"
    set "TMP=A:\NTPS8_RUNTIME_TEMP"
  )
)
where py.exe >nul 2>nul
if not errorlevel 1 (
  py -3 "%~dp0src\pwsh8.py" %*
  if errorlevel 1 pause
  exit /b
)
where python.exe >nul 2>nul
if not errorlevel 1 (
  python "%~dp0src\pwsh8.py" %*
  if errorlevel 1 pause
  exit /b
)
if exist "%~dp0vendor\pwsh7\pwsh.exe" (
  "%~dp0vendor\pwsh7\pwsh.exe" -NoLogo -NoExit -NoProfile -File "%~dp0NTPS8.Profile.ps1"
  exit /b %ERRORLEVEL%
)
if defined NT_PWSH_EXE if exist "%NT_PWSH_EXE%" (
  "%NT_PWSH_EXE%" -NoLogo -NoExit -NoProfile -File "%~dp0NTPS8.Profile.ps1"
  exit /b %ERRORLEVEL%
)
echo [ERROR] This source project needs Python 3 or a bundled PowerShell 7 runtime.
echo To check available engines without installing: 
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0NTPS8.Bootstrap.ps1" -Check
echo Run PREPARE_BUNDLED_PWSH.ps1 to prepare the engine on drive A:.
pause
exit /b 2
