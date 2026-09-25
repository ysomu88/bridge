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
    [ValidateSet('start', 'stop', 'restart', 'status', 'logs', 'tunnel', 'shutdown', 'cancel', 'help', 'ensure-task', '_run', '_tunnel_run')]
    [string]$Action = 'status',

    # start/tunnel: run in this console instead of in the background.
    # Useful for local debugging - NOT usable over SSH (dies with the session).
    [switch]$Foreground,

    # start: do NOT open a public localtunnel URL (personal use over Tailscale only).
    [switch]$NoTunnel,

    # start/tunnel: preferred public subdomain. If localtunnel finds it taken it
    # assigns a random one instead - the URL that was actually assigned is always
    # printed, so a collision is never a guessing game.
    [string]$Subdomain = 'bridge',

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
$TunnelLog  = Join-Path $LogDir 'tunnel.log'
$TunnelErr  = Join-Path $LogDir 'tunnel.err.log'
$TunnelState = Join-Path $LogDir 'tunnel.json'
$TunnelReq  = Join-Path $LogDir 'tunnel-req.txt'
$OllamaLog  = Join-Path $LogDir 'ollama.log'
$OllamaErr  = Join-Path $LogDir 'ollama.err.log'
$SelfPath   = $PSCommandPath

$TaskName   = 'BridgeStack'
$TunnelTask = 'BridgeTunnel'
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
    param([string]$Name = $TaskName)
    try {
        $t = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
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

    # Public tunnel
    $tun = Get-TunnelState
    if ($tun) {
        Write-Host ''
        if (Test-TunnelRunning) {
            Write-Ok ("Public URL     : {0}   <- share this with other users" -f $tun.Url)
        } else {
            Write-Warn ("Public tunnel has stopped (was {0}). Re-open with: .\bridge-remote.ps1 tunnel" -f $tun.Url)
        }
    }

    Write-Host ''
    Write-Info ("Logs: {0}" -f $LogDir)
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Public tunnel (localtunnel)
#
# Publishes http://localhost:8000 at https://<subdomain>.loca.lt so other people
# can use the server without joining your tailnet. Verified against localtunnel
# v2: it serves the page directly with no IP-password interstitial, and prints
# "your url is: https://<name>.loca.lt" on stdout once assigned.
#
# The requested subdomain is only a preference. If it is taken, localtunnel
# silently assigns a random name - so we read the URL back out of its output and
# always show what was ACTUALLY assigned, flagging the collision.
# ---------------------------------------------------------------------------
$script:TunnelUrlPattern = 'https://[A-Za-z0-9][A-Za-z0-9.-]*\.loca\.lt'

function Get-TunnelState {
    if (-not (Test-Path -LiteralPath $TunnelState)) { return $null }
    try {
        return (Get-Content -LiteralPath $TunnelState -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-TunnelRunning {
    $s = Get-TunnelState
    if (-not $s) { return $false }
    if ($s.Pid -and (Get-Process -Id ([int]$s.Pid) -ErrorAction SilentlyContinue)) { return $true }
    return $false
}

# Poll localtunnel's output until it reports a URL, then return that URL.
function Wait-TunnelUrl {
    param([int]$TimeoutSec = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $TunnelLog) {
            $hit = Select-String -Path $TunnelLog -Pattern $script:TunnelUrlPattern -AllMatches |
                Select-Object -Last 1
            if ($hit) {
                return ([regex]::Match($hit.Line, $script:TunnelUrlPattern)).Value
            }
        }
        Start-Sleep -Milliseconds 800
    }
    return $null
}

function Write-TunnelState {
    param([string]$Url, [int]$ProcessId, [string]$Requested)
    [pscustomobject]@{
        Url       = $Url
        Pid       = $ProcessId
        Requested = $Requested
        Started   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    } | ConvertTo-Json | Set-Content -LiteralPath $TunnelState -Encoding utf8
}

# The tunnel must NOT be a child of the calling shell. If `start` is run from an
# SSH session, sshd kills that session's entire process tree on disconnect, so the
# public URL would die the moment the phone's SSH app closed - while the server
# (owned by the BridgeStack task) carried on serving. The tunnel therefore gets
# its own on-demand task, for exactly the same reason the server does.
function Ensure-TunnelTask {
    if (Get-ScheduledTask -TaskName $TunnelTask -ErrorAction SilentlyContinue) { return 'Ready' }

    # Reuse the stack task's logon type, so -RunWithoutLogon covers the tunnel too.
    $logonType = 'Interactive'
    $stack = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($stack -and $stack.Principal -and $stack.Principal.LogonType) {
        $logonType = [string]$stack.Principal.LogonType
    }

    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" _tunnel_run' -f $SelfPath
    $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument $arguments -WorkingDirectory $RepoRoot
    $principal  = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
        -LogonType $logonType
    $settings   = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $TunnelTask -Action $taskAction -Principal $principal `
        -Settings $settings -Force `
        -Description 'Public localtunnel URL for Bridge, detached from any SSH session.' | Out-Null
    return 'Ready'
}

# _tunnel_run - worker executed BY the BridgeTunnel task (internal).
function Invoke-TunnelRun {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

    $wanted = 'bridge'
    if (Test-Path -LiteralPath $TunnelReq) {
        $txt = (Get-Content -LiteralPath $TunnelReq -Raw).Trim()
        if ($txt) { $wanted = $txt }
    }

    $npx = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if (-not $npx) { $npx = Get-Command npx -ErrorAction SilentlyContinue }
    if (-not $npx) {
        'npx not found - install Node.js' | Set-Content -LiteralPath $TunnelErr
        return 1
    }

    Remove-Item -LiteralPath $TunnelLog -Force -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $npx.Source `
        -ArgumentList 'localtunnel', '--port', $BridgePort, '--subdomain', $wanted `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $TunnelLog -RedirectStandardError $TunnelErr

    $url = Wait-TunnelUrl -TimeoutSec 60
    if (-not $url) {
        ('localtunnel reported no URL within 60s (requested: ' + $wanted + ')') |
            Add-Content -LiteralPath $TunnelErr
        return 1
    }

    Write-TunnelState -Url $url -ProcessId $proc.Id -Requested $wanted

    # Stay alive so the task owns the tunnel for as long as it is running.
    $proc.WaitForExit()
    Remove-Item -LiteralPath $TunnelState -Force -ErrorAction SilentlyContinue
    return 0
}

function Show-TunnelBanner {
    param([string]$Url, [string]$Requested)
    $assigned = ([uri]$Url).Host -replace '\.loca\.lt$', ''
    Write-Host ''
    Write-Host ('  ' + ('=' * 58)) -ForegroundColor DarkCyan
    Write-Host ("   PUBLIC URL  :  " + $Url) -ForegroundColor Green
    if ($Requested -and ($assigned -ne $Requested)) {
        Write-Host ("   NOTE: '" + $Requested + "' was already taken, so localtunnel assigned '" +
                    $assigned + "' instead.") -ForegroundColor Yellow
    }
    Write-Host ('  ' + ('=' * 58)) -ForegroundColor DarkCyan
    Write-Host '   Share that link. No password is needed (localtunnel v2 serves the page directly).' -ForegroundColor Gray
    Write-Host '   NOTE: it is a PUBLIC url - anyone with the link can use this server.' -ForegroundColor Yellow
    Write-Host ''
}

function Start-Tunnel {
    if (Test-TunnelRunning) {
        $s = Get-TunnelState
        Write-Host ''
        Write-Info 'A public tunnel is already running.'
        Show-TunnelBanner -Url $s.Url -Requested $s.Requested
        return 0
    }

    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    Remove-Item -LiteralPath $TunnelLog -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $TunnelErr -Force -ErrorAction SilentlyContinue

    $npx = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if (-not $npx) { $npx = Get-Command npx -ErrorAction SilentlyContinue }
    if (-not $npx) {
        Write-Fail 'npx not found - install Node.js to use the public tunnel.'
        return 1
    }

    $tunnelArgs = @('localtunnel', '--port', $BridgePort, '--subdomain', $Subdomain)

    if ($Foreground) {
        # Local console use: streaming here is fine, because this shell is the
        # session that stays open. Over SSH, use the task path below instead.
        Write-Info 'Starting public tunnel (output is followed in this console)...'
        $proc = Start-Process -FilePath $npx.Source -ArgumentList $tunnelArgs `
            -NoNewWindow -PassThru -RedirectStandardOutput $TunnelLog -RedirectStandardError $TunnelErr
        $url = Wait-TunnelUrl -TimeoutSec 60
        if (-not $url) {
            Write-Fail 'localtunnel did not report a URL within 60 seconds.'
            Show-LogTail -Path $TunnelErr -Lines 15
            Show-LogTail -Path $TunnelLog -Lines 15
            return 1
        }
        Write-TunnelState -Url $url -ProcessId $proc.Id -Requested $Subdomain
        Show-TunnelBanner -Url $url -Requested $Subdomain
        Write-Info 'Following tunnel output. Ctrl+C stops following (the tunnel keeps running).'
        Get-Content -LiteralPath $TunnelLog -Wait -ErrorAction SilentlyContinue
        return 0
    }

    # Detached path: the task owns the tunnel, so it survives this shell and any
    # SSH session being closed. The worker writes the state file, so clear the
    # old one first and then wait for the new URL to appear.
    try {
        $null = Ensure-TunnelTask
    } catch {
        Write-Fail ("Could not register the '{0}' task: {1}" -f $TunnelTask, $_.Exception.Message)
        return 1
    }

    Remove-Item -LiteralPath $TunnelState -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $TunnelReq -Value $Subdomain -Encoding ascii

    Write-Info ("Starting task '{0}' (detached from this session)..." -f $TunnelTask)
    try {
        Start-ScheduledTask -TaskName $TunnelTask
    } catch {
        Write-Fail ("Could not start the tunnel task: {0}" -f $_.Exception.Message)
        return 1
    }

    Write-Info 'Waiting for the tunnel to report its URL...'
    $deadline = (Get-Date).AddSeconds(75)
    $url = $null
    $assigned = $null
    while ((Get-Date) -lt $deadline) {
        $st = Get-TunnelState
        if ($st -and $st.Url) { $url = $st.Url; $assigned = $st.Requested; break }
        if ((Get-StackTaskState -Name $TunnelTask) -eq 'Ready' -and (Test-Path -LiteralPath $TunnelLog)) {
            break   # task already exited and never wrote state
        }
        Start-Sleep -Milliseconds 800
    }

    if (-not $url) {
        Write-Fail 'The tunnel did not report a URL in time.'
        Show-LogTail -Path $TunnelErr -Lines 15
        Show-LogTail -Path $TunnelLog -Lines 15
        return 1
    }

    Show-TunnelBanner -Url $url -Requested $assigned
    return 0
}

function Stop-Tunnel {
    $did = $false

    # Ending the task tears down the localtunnel process tree it owns.
    if ((Get-StackTaskState -Name $TunnelTask) -eq 'Running') {
        Write-Info ("Stopping task '{0}'..." -f $TunnelTask)
        try { Stop-ScheduledTask -TaskName $TunnelTask } catch { Write-Warn $_.Exception.Message }
        Start-Sleep -Seconds 2
        $did = $true
    }

    $s = Get-TunnelState
    if ($s -and $s.Pid) {
        $p = Get-Process -Id ([int]$s.Pid) -ErrorAction SilentlyContinue
        if ($p) {
            Write-Info ("Closing public tunnel (PID {0})..." -f $p.Id)
            $null = Invoke-Native 'taskkill.exe' @('/PID', [string]$p.Id, '/T', '/F')
            $did = $true
        }
    }

    # npx spawns a child node process, and a tunnel started from a foreground
    # console may not have a recorded PID - so also sweep by command line.
    $stray = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'localtunnel' })
    foreach ($n in $stray) {
        Write-Info ("Closing stray localtunnel process (PID {0})..." -f $n.ProcessId)
        $null = Invoke-Native 'taskkill.exe' @('/PID', [string]$n.ProcessId, '/T', '/F')
        $did = $true
    }

    Remove-Item -LiteralPath $TunnelState -Force -ErrorAction SilentlyContinue
    if ($did) { Write-Ok 'Public tunnel closed.' } else { Write-Info 'No public tunnel was running.' }
    return 0
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

    # Public URL for other people. On by default; -NoTunnel keeps the server
    # reachable only over your tailnet.
    if ($NoTunnel) {
        Write-Info 'Public tunnel skipped (-NoTunnel) - reachable over Tailscale only.'
    } else {
        $null = Start-Tunnel
    }

    Show-Status
    return 0
}

# ---------------------------------------------------------------------------
# stop
# ---------------------------------------------------------------------------
function Stop-Bridge {
    $did = $false

    # Take the public URL down first, so nobody can reach a half-dying server.
    $null = Stop-Tunnel

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
  .\bridge-remote.ps1 start                     Start Ollama + server + public URL
  .\bridge-remote.ps1 start -NoTunnel           Same, but no public URL (Tailscale only)
  .\bridge-remote.ps1 start -Subdomain myname   Ask for a specific public subdomain
  .\bridge-remote.ps1 start -ReadyTimeout 600   Slow first model load
  .\bridge-remote.ps1 tunnel                    Open the public URL on its own
  .\bridge-remote.ps1 stop                      Close the public URL, server + Ollama
  .\bridge-remote.ps1 stop -KeepOllama          Close the URL + server, keep Ollama
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
    'tunnel'   { exit (Start-Tunnel) }
    'shutdown' { exit (Invoke-ShutdownAction) }
    'cancel'   { exit (Invoke-CancelShutdown) }
    'help'     { exit (Show-Usage) }
    'ensure-task' {
        $state = Ensure-StackTask
        Write-Ok ("Scheduled task '{0}' is {1}." -f $TaskName, $state)
        exit 0
    }
    '_run'     { exit (Invoke-StackRun) }
    '_tunnel_run' { exit (Invoke-TunnelRun) }
    default    { exit (Show-Usage) }
}

