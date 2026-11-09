@echo off
cd /d "%~dp0"
echo Preparing runtime update 1.0.8...
taskkill /F /IM nilit.exe >nul 2>&1
taskkill /F /IM nilit-export.exe >nul 2>&1
ping 127.0.0.1 -n 2 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Polling.ps1" -Mode Apply
set "NILIT_POLLING_RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %NILIT_POLLING_RESULT%
