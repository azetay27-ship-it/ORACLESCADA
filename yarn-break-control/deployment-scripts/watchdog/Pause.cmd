@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Pause.ps1" %*
set "NILIT_WATCHDOG_RESULT=%ERRORLEVEL%"
pause
exit /b %NILIT_WATCHDOG_RESULT%
