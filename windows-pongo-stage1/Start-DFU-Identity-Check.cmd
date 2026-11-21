@echo off
setlocal
title AiboOS SE - READ ONLY DFU Identity Diagnostic
echo.
echo This checks whether AiboOS can read your iPhone's CPID and iBoot
echo version. It does not change drivers, run checkm8 or boot Linux.
echo Your unique ECID / full serial will not be shown.
echo.
"%~dp0aiboos-dfu-identity.exe" --inspect
echo.
echo Send the CHlP / BOOTROM / MATCH or BLOCKED lines to ChatGPT.
echo Do NOT run the checkm8 exploit again until identity is verified.
echo.
pause
