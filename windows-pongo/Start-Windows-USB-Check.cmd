@echo off
setlocal
title AiboOS iPhone SE - Windows Pongo USB Tool (EXPERIMENTAL)
echo.
echo AiboOS SE (2016) Windows-native Pongo USB tool
echo ----------------------------------------------
echo This only checks USB mode. It DOES NOT install, jailbreak,
echo flash, erase, or boot your iPhone automatically.
echo.
"%~dp0aiboos-pongo.exe" --list
echo.
"%~dp0aiboos-pongo.exe" --probe
echo.
echo If PongoOS is absent, that is expected: the Windows first-stage
echo loader has NOT yet been validated for this iPhone.
echo.
pause
