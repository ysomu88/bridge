@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0technical-setup\setup.ps1" %*
endlocal
