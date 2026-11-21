@echo off
setlocal
title AiboOS SE 2016 - READ ONLY Check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Windows-Readiness.ps1"
set "RESULT=%ERRORLEVEL%"
echo.
echo Readiness check ended. This did NOT boot or change your iPhone.
pause
exit /b %RESULT%
