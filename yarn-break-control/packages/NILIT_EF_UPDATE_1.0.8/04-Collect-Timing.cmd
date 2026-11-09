@echo off
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Collect-Timing.ps1"
set "NILIT_POLLING_RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %NILIT_POLLING_RESULT%
