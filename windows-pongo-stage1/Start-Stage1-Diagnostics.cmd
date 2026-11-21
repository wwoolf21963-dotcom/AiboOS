@echo off
setlocal
title AiboOS SE First Stage - SAFE DIAGNOSTIC ONLY
echo.
echo AiboOS SE Windows first-stage experiment
echo This does NOT install, jailbreak, or boot anything from this launcher.
echo.
"%~dp0aiboos-pongo-stage1.exe" --selftest
"%~dp0aiboos-pongo-stage1.exe" --probe
"%~dp0aiboos-pongo-stage1.exe" --test-dfu-access
echo.
echo Diagnostic only. No USB changes made.
echo Do not attempt DFU without a verified recovery/driver procedure.
pause
