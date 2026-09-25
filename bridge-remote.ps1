#Requires -Version 5.1
<#
    bridge-remote.ps1  -  Bridge remote control
    ==========================================================================
    Start / stop / inspect / shut down the Bridge translation stack from
    anywhere - typically over SSH from a phone (e.g. Termius).

    WHY A SCHEDULED TASK INSTEAD OF Start-Process?
    Windows OpenSSH sshd tears down its whole process tree when the session
    disconnects, so a server launched directly by an SSH command dies the
    moment you close the SSH app. Processes launched by the Task Scheduler
    service are owned by that service instead, so they survive session
    teardown. `start` therefore registers an on-demand task ("BridgeStack")
    and runs it, rather than spawning a child of this shell.

    ACTIONS
      start      Start Ollama (if needed) + the Bridge server, wait until ready
      stop       Stop the Bridge server (and Ollama unless -KeepOllama)
      restart    stop, then start
      status     Health summary + the URL to open from your phone
      logs       Tail the server / Ollama logs
      shutdown   Schedule a Windows shutdown (cancel with 'cancel')
      cancel     Abort a pending shutdown
      help       Show usage
      _run       INTERNAL - the foreground worker the BridgeStack task runs.
                 Do not call this directly; use 'start'.

    EXAMPLES
      .\bridge-remote.ps1 status
      .\bridge-remote.ps1 start
      .\bridge-remote.ps1 start -ReadyTimeout 600      # slow first model load
      .\bridge-remote.ps1 stop -KeepOllama
      .\bridge-remote.ps1 logs -Tail 80
      .\bridge-remote.ps1 shutdown -Minutes 5
      .\bridge-remote.ps1 cancel
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'status', 'logs', 'shutdown', 'cancel', 'help', 'ensure-task', '_run')]
    [string]$Action = 'status',

    # start: run the stack in this console instead of via the scheduled task.
    # Useful for local debugging - NOT usable over SSH (dies with the session).
    [switch]$Foreground,

    # stop: leave Ollama running (only stop the Bridge FastAPI server).
    [switch]$KeepOllama,

    # shutdown: minutes to wait before powering off (minimum 1).
    [int]$Minutes = 1,

    # logs: how many trailing lines to show per log file.
    [int]$Tail = 40,

    # start: seconds to wait for the server to bind port 8000.
    [int]$ReadyTimeout = 300
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths & constants
# ---------------------------------------------------------------------------
$RepoRoot   = $PSScriptRoot
$VenvPython = Join-Path $RepoRoot '.venv\Scripts\python.exe'
$LogDir     = Join-Path $RepoRoot 'remote_logs'
$ServerLog  = Join-Path $LogDir 'server.log'
$ServerErr  = Join-Path $LogDir 'server.err.log'
$WorkerLog  = Join-Path $LogDir 'worker.log'
$OllamaLog  = Join-Path $LogDir 'ollama.log'
$OllamaErr  = Join-Path $LogDir 'ollama.err.log'
$SelfPath   = $PSCommandPath

$TaskName   = 'BridgeStack'
$BridgePort = 8000
$OllamaPort = 11434

# ---------------------------------------------------------------------------
# Output helpers (ASCII only - renders reliably in SSH terminals)
# ---------------------------------------------------------------------------
function Write-Head([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
}
function Write-Ok([string]$Text)   { Write-Host ("  [OK] " + $Text) -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host ("  [--] " + $Text) -ForegroundColor Gray }
function Write-Warn([string]$Text) { Write-Host ("  [!!] " + $Text) -ForegroundColor Yellow }
function Write-Fail([string]$Text) { Write-Host ("  [XX] " + $Text) -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Native-command helper
#
# PowerShell 5.1 turns a native process's stderr into a *terminating* error when
# $ErrorActionPreference is 'Stop' - and taskkill/shutdown both write to stderr.
# That would abort this script mid-action. This wrapper relaxes the preference
# for just the call and returns the exit code plus captured output.
# ---------------------------------------------------------------------------
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $captured = & $Exe @Arguments 2>&1
        $code = $LASTEXITCODE
        $text = @()
        if ($null -ne $captured) {
            $text = @($captured | ForEach-Object { [string]$_ })
        }
        return [pscustomobject]@{ ExitCode = $code; Output = $text }
    } finally {
        $ErrorActionPreference = $previous
    }
}

# ---------------------------------------------------------------------------
# Probing helpers
# ---------------------------------------------------------------------------
function Test-PortOpen {
    param([int]$Port, [string]$Target = '127.0.0.1', [int]$TimeoutMs = 700)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Target, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Get-PortOwner {
    param([int]$Port)
    try {
        $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if ($null -eq $conn) { return $null }
        return Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    } catch {
        return $null
    }
}

function Get-OllamaExe {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
        (Join-Path $env:ProgramFiles  'Ollama\ollama.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $cmd = Get-Command ollama -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Show-LogTail {
    param([string]$Path, [int]$Lines = 40)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Write-Host ''
    Write-Host ("--- " + (Split-Path $Path -Leaf) + " ---") -ForegroundColor DarkCyan
    Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host ("  " + $_) }
}

# Tailscale discovery - used to print the URL you can open from your phone.
# Returns $null when Tailscale is not installed / not logged in.
function Get-TailscaleSelf {
    $exe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        $cmd = Get-Command tailscale -ErrorAction SilentlyContinue
        if ($cmd) { $exe = $cmd.Source } else { return $null }
    }

    $name = $null
    $ip   = $null
    try {
        $json = & $exe status --json 2>$null | ConvertFrom-Json
        if ($json -and $json.Self) {
            if ($json.Self.DNSName) { $name = ($json.Self.DNSName -replace '\.$', '') }
            if ($json.Self.TailscaleIPs) { $ip = ($json.Self.TailscaleIPs | Select-Object -First 1) }
        }
    } catch { }

    if (-not $ip) {
        try { $ip = ((& $exe ip -4 2>$null) | Select-Object -First 1) } catch { }
        if ($ip) { $ip = ([string]$ip).Trim() }
    }
    if (-not ($name -or $ip)) { return $null }
    return [pscustomobject]@{ Name = $name; IP = $ip; Exe = $exe }
}

# ---------------------------------------------------------------------------
# Scheduled-task plumbing
#
# The task owns the server's process tree, so it survives this shell (and any
# SSH session) going away. No trigger: it runs only when we ask it to.
# ---------------------------------------------------------------------------
function Get-StackTaskState {
    try {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -eq $t) { return 'Missing' }
        return [string]$t.State
    } catch {
        return 'Unknown'
    }
}

# Task Scheduler reports HRESULT-ish codes; translate the ones we actually see.
function Get-TaskResultNote {
    param([int]$Code)
    switch ($Code) {
        0      { return 'ok' }
        267009 { return 'still running' }
        267011 { return 'has not run yet' }
        267014 { return 'terminated early' }
        default { return "result code $Code" }
    }
}

function Ensure-StackTask {
    param([string]$LogonType = 'Interactive')
    $state = Get-StackTaskState
    if ($state -ne 'Missing') { return $state }

    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" _run' -f $SelfPath
    $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument $arguments -WorkingDirectory $RepoRoot
    $principal  = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
        -LogonType $LogonType
    # ExecutionTimeLimit 0 (PT0S) = never time the server out.
    $settings   = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Principal $principal `
        -Settings $settings -Force `
        -Description 'Bridge translation stack (Ollama + FastAPI server), detached from any SSH session.' |
        Out-Null

    return (Get-StackTaskState)
}

# ---------------------------------------------------------------------------
# _run  -  the worker executed BY the BridgeStack task (internal)
#
# Ollama is started detached (it must outlive this shell), then the Bridge
# server runs in the foreground so the task host owns it for its whole life.
# ---------------------------------------------------------------------------
function Invoke-StackRun {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "bridge-remote worker start $stamp" | Set-Content -LiteralPath $WorkerLog

    # ── 1. Ollama ──────────────────────────────────────────────────────────
    if (Test-PortOpen -Port $OllamaPort) {
        "[ollama] already listening on $OllamaPort - reusing existing instance" |
            Add-Content -LiteralPath $WorkerLog
    } else {
        $ollamaExe = Get-OllamaExe
        if (-not $ollamaExe) {
            "[ollama] ERROR: ollama.exe not found. Install it from https://ollama.com/download" |
                Add-Content -LiteralPath $WorkerLog
            return 1
        }
        "[ollama] launching: $ollamaExe serve" | Add-Content -LiteralPath $WorkerLog
        Start-Process -FilePath $ollamaExe -ArgumentList 'serve' -WindowStyle Hidden `
            -RedirectStandardOutput $OllamaLog -RedirectStandardError $OllamaErr | Out-Null

        $deadline = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $deadline -and -not (Test-PortOpen -Port $OllamaPort)) {
            Start-Sleep -Seconds 1
        }
        if (-not (Test-PortOpen -Port $OllamaPort)) {
            "[ollama] ERROR: did not bind port $OllamaPort within 90s" |
                Add-Content -LiteralPath $WorkerLog
            return 1
        }
        "[ollama] ready." | Add-Content -LiteralPath $WorkerLog
    }

    # ── 2. Bridge FastAPI server ────────────────────────────────────────────
    if (-not (Test-Path -LiteralPath $VenvPython)) {
        "[server] ERROR: venv python not found at $VenvPython" |
            Add-Content -LiteralPath $WorkerLog
        return 1
    }

    "[server] launching: $VenvPython server.py" | Add-Content -LiteralPath $WorkerLog
    
    # NOTE: never pipe the server's output with `2>&1 | Out-File`. Under
    # $ErrorActionPreference='Stop', PowerShell turns a native process's stderr
    # into a terminating NativeCommandError, which would abort this worker and
    # kill the server. Start-Process redirects at the OS level instead, and -u
    # keeps Python unbuffered so remote_logs/server.log grows live.
    $exitCode = 1
    try {
        $proc = Start-Process -FilePath $VenvPython -ArgumentList '-u', 'server.py' `
            -WorkingDirectory $RepoRoot -WindowStyle Hidden -Wait -PassThru `
            -RedirectStandardOutput $ServerLog -RedirectStandardError $ServerErr
        $exitCode = $proc.ExitCode
    } catch {
        "[server] ERROR: $($_.Exception.Message)" | Add-Content -LiteralPath $WorkerLog
    }

    "[server] process exited at $(Get-Date -Format 'HH:mm:ss') with code $exitCode" |
        Add-Content -LiteralPath $WorkerLog
    return $exitCode
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
function Show-Status {
    Write-Head 'Bridge remote status'

    $taskState = Get-StackTaskState
    $taskLine  = "Scheduled task : $taskState"
    if ($taskState -eq 'Missing') {
        Write-Info ($taskLine + " (will be created on first 'start')")
    } else {
        Write-Info $taskLine
        try {
            $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
            if ($info -and $info.LastRunTime -and $info.LastRunTime.Year -gt 1900) {
                $note = Get-TaskResultNote -Code ([int]$info.LastTaskResult)
                Write-Info ("Last task run  : {0}  ({1})" -f $info.LastRunTime, $note)
            }
        } catch { }
    }

    # Ollama
    if (Test-PortOpen -Port $OllamaPort) {
        $modelNote = 'could not query model list'
        try {
            $tags = Invoke-RestMethod -Uri "http://localhost:$OllamaPort/api/tags" -TimeoutSec 3
            $names = @($tags.models | ForEach-Object { $_.name })
            if (@($names | Where-Object { $_ -like 'llama3.2*' }).Count -gt 0) {
                $modelNote = 'llama3.2 available'
            } else {
                $modelNote = 'llama3.2 MISSING - run: ollama pull llama3.2'
            }
        } catch { }
        Write-Ok ("Ollama         : listening on {0} - {1}" -f $OllamaPort, $modelNote)
    } else {
        Write-Warn ("Ollama         : not listening on {0}" -f $OllamaPort)
    }

    # Bridge server
    $bridgeUp = Test-PortOpen -Port $BridgePort
    if ($bridgeUp) {
        $procNote = 'owner unknown'
        $proc = Get-PortOwner -Port $BridgePort
        if ($proc) {
            $up = (Get-Date) - $proc.StartTime
            $upTxt = "{0}h {1}m {2}s" -f [int]$up.TotalHours, $up.Minutes, $up.Seconds
            $procNote = "PID {0} ({1}), up {2}" -f $proc.Id, $proc.ProcessName, $upTxt
        }
        Write-Ok ("Bridge server  : listening on {0} - {1}" -f $BridgePort, $procNote)

        $httpNote = 'no HTTP response yet (models may still be loading)'
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$BridgePort/" -TimeoutSec 5 -UseBasicParsing
            if ($resp.StatusCode -eq 200) { $httpNote = 'HTTP 200 - UI is being served' }
        } catch { }
        Write-Info ("HTTP check     : {0}" -f $httpNote)
    } else {
        Write-Warn ("Bridge server  : not listening on {0}" -f $BridgePort)
    }

    # How to reach it from your phone
    Write-Host ''
    if ($bridgeUp) {
        Write-Info ("From this PC   : http://localhost:{0}" -f $BridgePort)
        $ts = Get-TailscaleSelf
        if ($ts) {
            if ($ts.Name) { Write-Ok ("From your phone : http://{0}:{1}" -f $ts.Name, $BridgePort) }
            if ($ts.IP)   { Write-Ok ("   (or by IP)  : http://{0}:{1}" -f $ts.IP, $BridgePort) }
        } else {
            Write-Warn 'Tailscale not detected - install it to reach this server from outside your home network.'
        }
    } else {
        Write-Info 'Server is down. Start it with: .\bridge-remote.ps1 start'
    }
    Write-Host ''
    Write-Info ("Logs: {0}" -f $LogDir)
    Write-Host ''
}

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------
function Start-Bridge {
    if (Test-PortOpen -Port $BridgePort) {
        Write-Warn ("Bridge is already listening on port {0} - nothing to do." -f $BridgePort)
        Show-Status
        return 0
    }

    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

    try {
        $taskState = Ensure-StackTask
    } catch {
        Write-Fail ("Could not register the '{0}' scheduled task: {1}" -f $TaskName, $_.Exception.Message)
        return 1
    }
    Write-Info ("Scheduled task : {0}" -f $taskState)

    if ($Foreground) {
        Write-Info 'Running the stack in THIS console (-Foreground). Press Ctrl+C to stop.'
        Write-Warn 'Foreground mode dies with this shell - do not use it over SSH.'
        return (Invoke-StackRun)
    }

    if ($taskState -eq 'Running') {
        Write-Warn 'The stack task is already running - waiting for the server to bind...'
    } else {
        Write-Info ("Starting task '{0}' (detached from this session)..." -f $TaskName)
        try {
            Start-ScheduledTask -TaskName $TaskName
        } catch {
            Write-Fail ("Could not start the task: {0}" -f $_.Exception.Message)
            Write-Info ("If this PC was just powered on with nobody logged in, the '{0}' task" -f $TaskName)
            Write-Info 'cannot run with an Interactive logon. Either log in on the PC first, or run'
            Write-Info 'setup-remote-access.ps1 -RunWithoutLogon once to register it with your password.'
            return 1
        }
    }

    Write-Info ("Waiting up to {0}s for the models to load..." -f $ReadyTimeout)
    $deadline   = (Get-Date).AddSeconds($ReadyTimeout)
    $graceUntil = (Get-Date).AddSeconds(15)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        if (Test-PortOpen -Port $BridgePort) { $ready = $true; break }
        # Left 'Running' before the port opened => the worker died.
        if ((Get-Date) -gt $graceUntil -and (Get-StackTaskState) -eq 'Ready') { break }
        Start-Sleep -Seconds 2
    }

    if (-not $ready) {
        Write-Fail ("Bridge did not start listening on port {0}." -f $BridgePort)
        Show-LogTail -Path $WorkerLog -Lines 20
        Show-LogTail -Path $ServerLog -Lines 30
        Show-LogTail -Path $ServerErr -Lines 20
        try {
            $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
            if ($info) {
                Write-Info ("Task last result: {0}" -f (Get-TaskResultNote -Code ([int]$info.LastTaskResult)))
            }
        } catch { }
        return 1
    }

    Write-Ok 'Bridge is up.'
    Show-Status
    return 0
}

# ---------------------------------------------------------------------------
# stop
# ---------------------------------------------------------------------------
function Stop-Bridge {
    $did = $false

    if ((Get-StackTaskState) -eq 'Running') {
        Write-Info ("Stopping scheduled task '{0}'..." -f $TaskName)
        try { Stop-ScheduledTask -TaskName $TaskName } catch { Write-Warn $_.Exception.Message }
        $did = $true
        Start-Sleep -Seconds 2
    }

    # Belt & braces - catch anything still holding the port (e.g. start.ps1)
    $proc = Get-PortOwner -Port $BridgePort
    if ($proc) {
        Write-Info ("Releasing port {0} (PID {1} / {2})..." -f $BridgePort, $proc.Id, $proc.ProcessName)
        $null = Invoke-Native 'taskkill.exe' @('/PID', [string]$proc.Id, '/T', '/F')
        $did = $true
        Start-Sleep -Seconds 1
    }

    if (-not $KeepOllama) {
        $running = @(Get-Process -Name 'ollama', 'ollama app', 'ollama_llama_server' -ErrorAction SilentlyContinue)
        if ($running.Count -gt 0) {
            Write-Info 'Stopping Ollama (-KeepOllama to leave it running)...'
            # 'ollama app.exe' is the tray app: it respawns the server process, so
            # it has to go too or Ollama comes straight back.
            foreach ($name in @('ollama app.exe', 'ollama.exe', 'ollama_llama_server.exe')) {
                $null = Invoke-Native 'taskkill.exe' @('/IM', $name, '/T', '/F')
            }
            $did = $true
            Start-Sleep -Seconds 2
        }
    } else {
        Write-Info 'Leaving Ollama running (-KeepOllama).'
    }

    if (Test-PortOpen -Port $BridgePort) {
        Write-Warn ("Port {0} is still open - something may have restarted the server." -f $BridgePort)
        return 1
    }
    if (-not $KeepOllama -and (Test-PortOpen -Port $OllamaPort)) {
        Write-Warn ("Ollama is still listening on {0} - another Ollama instance may be running." -f $OllamaPort)
    }
    if ($did) { Write-Ok 'Bridge stopped.' } else { Write-Info 'Bridge was not running.' }
    return 0
}

# ---------------------------------------------------------------------------
# logs
# ---------------------------------------------------------------------------
function Show-Logs {
    Write-Head 'Bridge logs'
    $found = $false
    foreach ($p in @($WorkerLog, $ServerLog, $ServerErr, $OllamaLog, $OllamaErr)) {
        if (Test-Path -LiteralPath $p) {
            Show-LogTail -Path $p -Lines $Tail
            $found = $true
        }
    }
    if (-not $found) { Write-Info 'No logs yet - start the stack first.' }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# shutdown / cancel
# ---------------------------------------------------------------------------
function Invoke-ShutdownAction {
    $mins    = [Math]::Max(1, $Minutes)
    $seconds = [int]($mins * 60)

    Write-Head 'Remote shutdown'
    Write-Warn ("This PC will power off in {0} minute(s)." -f $mins)
    Write-Info 'Cancel any time before then with:  .\bridge-remote.ps1 cancel'

    Write-Info 'Stopping the Bridge stack first...'
    Stop-Bridge

    # NOTE: the /c comment must not contain double quotes - embedded quotes
    # mangle the native command line and shutdown.exe falls back to printing
    # its usage text.
    $result = Invoke-Native 'shutdown.exe' @(
        '/s', '/t', [string]$seconds,
        '/c', 'Bridge remote shutdown - abort with shutdown /a before the timer ends'
    )
    if ($result.ExitCode -eq 0) {
        Write-Ok ("Shutdown scheduled in {0}s. Open SSH sessions will drop now." -f $seconds)
        return 0
    }
    Write-Fail ("shutdown.exe returned exit code {0}." -f $result.ExitCode)
    foreach ($line in $result.Output) {
        if ($line.Trim()) { Write-Info $line.Trim() }
    }
    return 1
}

function Invoke-CancelShutdown {
    Write-Head 'Cancel pending shutdown'
    $result = Invoke-Native 'shutdown.exe' @('/a')
    foreach ($line in $result.Output) {
        if ($line.Trim()) { Write-Info $line.Trim() }
    }
    if ($result.ExitCode -eq 0) {
        Write-Ok 'Pending shutdown aborted.'
    } else {
        Write-Warn 'No shutdown was pending (or it could not be aborted).'
    }
    return 0
}

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------
function Show-Usage {
    Write-Head 'bridge-remote.ps1 - usage'
    @'
  .\bridge-remote.ps1 status                    Health + the URL for your phone
  .\bridge-remote.ps1 start                     Start Ollama + the Bridge server
  .\bridge-remote.ps1 start -ReadyTimeout 600   Slow first model load
  .\bridge-remote.ps1 stop                      Stop server + Ollama
  .\bridge-remote.ps1 stop -KeepOllama          Stop only the Bridge server
  .\bridge-remote.ps1 restart                   Stop, then start
  .\bridge-remote.ps1 logs -Tail 80             Tail the logs
  .\bridge-remote.ps1 shutdown -Minutes 5       Power the PC off in 5 minutes
  .\bridge-remote.ps1 cancel                    Abort a pending shutdown
  .\bridge-remote.ps1 help                      This text

  Over SSH from your phone (paste into Termius as a snippet):
    powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\Documents\PythonScripts\bridge\bridge-remote.ps1" status
'@ | ForEach-Object { Write-Host $_ -ForegroundColor Gray }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
switch ($Action) {
    'start'    { exit (Start-Bridge) }
    'stop'     { exit (Stop-Bridge) }
    'restart'  { $null = Stop-Bridge; Start-Sleep -Seconds 2; exit (Start-Bridge) }
    'status'   { Show-Status; exit 0 }
    'logs'     { Show-Logs; exit 0 }
    'shutdown' { exit (Invoke-ShutdownAction) }
    'cancel'   { exit (Invoke-CancelShutdown) }
    'help'     { exit (Show-Usage) }
    'ensure-task' {
        $state = Ensure-StackTask
        Write-Ok ("Scheduled task '{0}' is {1}." -f $TaskName, $state)
        exit 0
    }
    '_run'     { exit (Invoke-StackRun) }
    default    { exit (Show-Usage) }
}

