@echo off
setlocal

echo =================================================================
echo  Bridge Voice Translation Server - Automated Setup
echo =================================================================

REM Run PowerShell setup script with bypass execution policy
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*

if %ERRORLEVEL% neq 0 (
    echo.
    echo [ERROR] Setup encountered an error.
    exit /b %ERRORLEVEL%
)

endlocal
