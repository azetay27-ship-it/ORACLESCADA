@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0StopKeeper.ps1"
set "NILIT_KEEPER_RESULT=%ERRORLEVEL%"
pause
exit /b %NILIT_KEEPER_RESULT%
