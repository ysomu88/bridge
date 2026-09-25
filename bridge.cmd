@echo off
REM ---------------------------------------------------------------------------
REM  bridge.cmd - a short entry point for controlling Bridge from a phone.
REM
REM  Put this folder on your PATH (setup does that) and you can just type:
REM
REM      bridge                 status  (same as "bridge status")
REM      bridge start           Ollama + server + public URL
REM      bridge start -NoTunnel Ollama + server, no public URL
REM      bridge stop            close URL + server + Ollama
REM      bridge restart        stop then start
REM      bridge logs           tail the logs
REM      bridge logs -Tail 80  more log lines
REM      bridge tunnel         open the public URL on its own
REM      bridge shutdown 5     power the PC off in 5 minutes
REM      bridge cancel         abort a pending shutdown
REM      bridge help           full usage
REM
REM  Designed for a short SSH command: it lives next to bridge-remote.ps1, so
REM  there are no long paths to paste and it works from any directory.
REM ---------------------------------------------------------------------------
setlocal
set "SCRIPT=%~dp0bridge-remote.ps1"

if not exist "%SCRIPT%" (
    echo bridge-remote.ps1 not found next to this file: "%SCRIPT%"
    exit /b 1
)

if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" status
    exit /b %ERRORLEVEL%
)

REM "shutdown" reads its minutes from the 2nd argument, so map it explicitly.
if /i "%~1"=="shutdown" (
    if "%~2"=="" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" shutdown -Minutes 1
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" shutdown -Minutes %~2
    )
    exit /b %ERRORLEVEL%
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %* 
exit /b %ERRORLEVEL%
