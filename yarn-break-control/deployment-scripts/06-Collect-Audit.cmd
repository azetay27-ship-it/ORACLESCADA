@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0watchdog\Collect-Watchdog-Audit.ps1"
set "NILIT_EF_RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %NILIT_EF_RESULT%
