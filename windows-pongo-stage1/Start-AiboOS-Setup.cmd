@echo off
setlocal
title AiboOS SE 2016 - Automatic Windows Preparation
echo.
echo AiboOS automated Windows preparation
echo DFU check / Apple driver backup / USB access test.
echo This will NOT replace a driver, exploit, reboot, or erase your iPhone.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0AiboOS-Windows-Setup.ps1"
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
  echo USB preparation passed. iPhone was not changed.
) else (
  echo Preparation did not pass. Read the explanation above.
)
echo.
pause
exit /b %RC%
