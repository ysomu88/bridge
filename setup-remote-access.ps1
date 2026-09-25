#Requires -Version 5.1
<#
    setup-remote-access.ps1  -  ONE-TIME, ELEVATED setup for phone control
    ==========================================================================
    Prepares this PC so you can drive the Bridge stack from your phone:

      1. Installs Tailscale (if missing) - a private network between your
         phone and this PC, so nothing is exposed to the public internet.
      2. Installs the built-in Windows OpenSSH Server and starts it at boot.
      3. Firewalls SSH so it is reachable ONLY over the Tailscale network.
      4. Authorises your phone's SSH key and disables password logins.
      5. Optionally registers the stack task so it can start with nobody
         logged in at the PC.

    Then pairing is done from your phone with any SSH app (Termius, Blink...).

    USAGE
      # Recommended: generate a key pair here, then import it into your phone
      .\setup-remote-access.ps1 -GenerateKeyPair

      # Or: generate the key in your phone app and paste its public half here
      .\setup-remote-access.ps1 -PublicKey "ssh-ed25519 AAAAC3Nza... you@phone"

      # Also let the stack start when nobody is logged in on the PC
      .\setup-remote-access.ps1 -GenerateKeyPair -RunWithoutLogon

    Run it from a normal prompt - it elevates itself via UAC.
#>
[CmdletBinding()]
param(
    # Public key text from your phone app, e.g. "ssh-ed25519 AAAAC3... phone"
    [string]$PublicKey,

    # Create a new key pair on this PC (private key goes to ~\.ssh\)
    [switch]$GenerateKeyPair,

    # Skip installing / configuring Tailscale
    [switch]$SkipTailscale,

    # Skip installing / configuring the OpenSSH Server
    [switch]$SkipOpenSSH,

    # Register the stack task to run with nobody logged on (prompts for your
    # Windows password once; Task Scheduler stores it in LSA secrets)
    [switch]$RunWithoutLogon
)

# Deliberately NOT 'Stop': icacls / ssh-keygen / taskkill write to stderr, and
# under $ErrorActionPreference='Stop' PowerShell 5.1 turns that into a
# terminating error that would abort this script mid-way through a
# security-sensitive change. Each step is verified explicitly instead.
$ErrorActionPreference = 'Continue'

$RepoRoot     = $PSScriptRoot
$LogDir       = Join-Path $RepoRoot 'remote_logs'
$LogFile      = Join-Path $LogDir 'setup.log'
$RemoteScript = Join-Path $RepoRoot 'bridge-remote.ps1'
$TaskName     = 'BridgeStack'

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log {
    param([string]$Text, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Text
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8
}
function Log-Ok  ([string]$t) { Write-Log $t 'OK'   }
function Log-Info([string]$t) { Write-Log $t 'INFO' }
function Log-Warn([string]$t) { Write-Log $t 'WARN' }
function Log-Fail([string]$t) { Write-Log $t 'FAIL' }

function Write-Summary {
    # Prints to the console AND appends to the log, so the "what do I do next"
    # block survives the elevated window closing.
    param([string]$Text = '', [string]$Color = 'Gray')
    if ($Text) { Write-Host $Text -ForegroundColor $Color }
    Add-Content -LiteralPath $LogFile -Value $Text -Encoding utf8
}

# ---------------------------------------------------------------------------
# Elevation - the steps below all need administrator rights
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host ''
    Write-Host 'Administrator rights are required (OpenSSH Server + firewall rules).' -ForegroundColor Yellow
    Write-Host 'Relaunching elevated - accept the UAC prompt...' -ForegroundColor Yellow

    $reArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        # Keep the elevated window open after the script finishes, otherwise it
        # closes instantly and you never get to read the summary below.
        '-NoExit'
    )
    if ($PublicKey)       { $reArgs += @('-PublicKey', ('"' + $PublicKey + '"')) }
    if ($GenerateKeyPair) { $reArgs += '-GenerateKeyPair' }
    if ($SkipTailscale)   { $reArgs += '-SkipTailscale' }
    if ($SkipOpenSSH)     { $reArgs += '-SkipOpenSSH' }
    if ($RunWithoutLogon) { $reArgs += '-RunWithoutLogon' }
    $reArgs += @('-File', ('"' + $PSCommandPath + '"'))

    Start-Process powershell -Verb RunAs -ArgumentList $reArgs | Out-Null
    Write-Host 'Handed off to the elevated window - this one can be closed.' -ForegroundColor DarkGray
    exit 0
}

Write-Host ''
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host '   Bridge remote access - one-time setup (elevated)' -ForegroundColor Cyan
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Log 'Setup started.'
Write-Log ("Repo: {0}" -f $RepoRoot)

$tailscaleExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'

# ---------------------------------------------------------------------------
# 1. Tailscale - the private network your phone reaches this PC through
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- 1/4  Tailscale ---' -ForegroundColor White

if ($SkipTailscale) {
    Log-Info 'Skipping Tailscale (-SkipTailscale).'
} elseif (Test-Path -LiteralPath $tailscaleExe) {
    Log-Ok 'Tailscale is already installed.'
} else {
    Log-Info 'Tailscale not found - attempting an unattended install with winget...'
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        $wingetOutput = & winget install --id Tailscale.Tailscale -e --silent `
            --accept-package-agreements --accept-source-agreements 2>&1
        $wingetOutput | ForEach-Object { Write-Log ('winget: ' + $_) }
        if (Test-Path -LiteralPath $tailscaleExe) {
            Log-Ok 'Tailscale installed.'
        } else {
            Log-Warn 'Tailscale does not appear to be installed yet - check the winget output above.'
        }
    } else {
        Log-Warn 'winget is not available on this PC.'
        Log-Warn 'Install Tailscale manually, then re-run this script: https://tailscale.com/download/windows'
    }
}

if (Test-Path -LiteralPath $tailscaleExe) {
    $tsStatus = (& $tailscaleExe status 2>&1 | Out-String).Trim()
    if (-not $tsStatus -or $tsStatus -match 'Logged out|stopped') {
        Log-Warn 'Tailscale is installed but NOT logged in.'
        Log-Warn 'Click the Tailscale tray icon (or run: tailscale up) and sign in - use the same account on your phone.'
    } else {
        Log-Ok 'Tailscale is running and logged in.'
    }
}

# ---------------------------------------------------------------------------
# 2. OpenSSH Server + firewall scoped to the tailnet
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- 2/4  OpenSSH Server ---' -ForegroundColor White

if ($SkipOpenSSH) {
    Log-Info 'Skipping OpenSSH Server (-SkipOpenSSH).'
} else {
    $capability = $null
    try {
        $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction Stop |
            Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1
    } catch {
        Log-Warn ('Could not query Windows capabilities: ' + $_.Exception.Message)
    }

    if ($null -eq $capability) {
        Log-Warn 'OpenSSH.Server capability not reported by Windows - skipping.'
    } elseif ($capability.State -eq 'Installed') {
        Log-Ok 'OpenSSH Server is already installed.'
    } else {
        Log-Info 'Installing the OpenSSH Server capability (needs internet / Windows Update)...'
        try {
            Add-WindowsCapability -Online -Name $capability.Name -ErrorAction Stop | Out-Null
            Log-Ok 'OpenSSH Server installed.'
        } catch {
            Log-Fail ('Could not install OpenSSH Server: ' + $_.Exception.Message)
        }
    }

    # sshd is a Windows service, so it comes up at boot *before* anyone logs in.
    $sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($sshd) {
        Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
        if ($sshd.Status -ne 'Running') { Start-Service -Name sshd -ErrorAction SilentlyContinue }
        $sshd.Refresh()
        Log-Ok ('sshd service: status={0}, startup={1}' -f $sshd.Status, $sshd.StartupType)

        # 100.64.0.0/10 is Tailscale's CGNAT range, so this rule can never be
        # hit from your Wi-Fi or wired LAN - only from your own tailnet devices.
        $ruleName = 'Bridge-OpenSSH-TailscaleOnly'
        Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
        New-NetFirewallRule -Name $ruleName -DisplayName 'OpenSSH (Tailscale only)' `
            -Description 'SSH reachable only from the Tailscale network (100.64.0.0/10).' `
            -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow `
            -RemoteAddress '100.64.0.0/10' -Profile Any -ErrorAction SilentlyContinue | Out-Null

        $created = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
        if ($created) {
            Log-Ok 'Firewall: TCP 22 allowed only from the Tailscale network.'
        } else {
            Log-Warn 'Could not create the Tailscale-scoped firewall rule - SSH may be refused.'
        }

        # The capability also ships a rule that opens SSH to everything. Turn it
        # off so SSH is not exposed on your local network.
        $broad = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
        if ($broad -and $broad.Enabled -eq 'True') {
            Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
            Log-Ok 'Disabled the default "OpenSSH-Server-In-TCP" rule (it would expose SSH to your LAN).'
        }
    } else {
        Log-Fail 'sshd service not found - OpenSSH Server did not install correctly.'
    }
}

# ---------------------------------------------------------------------------
# 3. Authorise your phone's SSH key (and turn password logins off)
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- 3/4  SSH keys ---' -ForegroundColor White

$adminKeyFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
$userKeyDir   = Join-Path $env:USERPROFILE '.ssh'
$userKeyFile  = Join-Path $userKeyDir 'authorized_keys'

$pubKeyText   = $null
$privateKey   = $null

if ($PublicKey) {
    $pubKeyText = $PublicKey.Trim()
    Log-Info 'Using the public key passed to -PublicKey.'
} elseif ($GenerateKeyPair) {
    if (-not (Test-Path -LiteralPath $userKeyDir)) {
        New-Item -ItemType Directory -Force -Path $userKeyDir | Out-Null
    }
    $privateKey = Join-Path $userKeyDir 'bridge_phone_ed25519'
    Remove-Item -LiteralPath $privateKey -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ($privateKey + '.pub') -Force -ErrorAction SilentlyContinue

    $keygenOutput = & ssh-keygen.exe -t ed25519 -f $privateKey -N '' -C 'bridge-phone' 2>&1
    $keygenOutput | ForEach-Object { Write-Log ('ssh-keygen: ' + $_) }

    if (Test-Path -LiteralPath ($privateKey + '.pub')) {
        $pubKeyText = (Get-Content -LiteralPath ($privateKey + '.pub') -Raw).Trim()
        Log-Ok 'Generated a new ed25519 key pair.'
    } else {
        Log-Fail 'ssh-keygen did not produce a key pair - pass -PublicKey instead.'
    }
} else {
    Log-Warn 'No key supplied. Re-run with -GenerateKeyPair or -PublicKey "<key>".'
    Log-Warn 'Until a key is authorised you cannot log in over SSH (password auth will be off).'
}

if ($pubKeyText) {
    # Members of Administrators must use administrators_authorized_keys - that is
    # what the "Match Group administrators" block in the default sshd_config reads.
    $isAdminUser = $true
    try {
        $isAdminUser = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop |
            Where-Object { ($_.Name -split '\\')[-1] -eq $env:USERNAME }).Count -gt 0
    } catch { }

    $target = if ($isAdminUser) { $adminKeyFile } else { $userKeyFile }
    $targetDir = Split-Path $target -Parent
    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    }

    $existing = @()
    if (Test-Path -LiteralPath $target) {
        $existing = @(Get-Content -LiteralPath $target -ErrorAction SilentlyContinue)
    }
    if ($existing -contains $pubKeyText) {
        Log-Ok ('That key is already authorised in {0}' -f $target)
    } else {
        Add-Content -LiteralPath $target -Value $pubKeyText -Encoding ascii
        Log-Ok ('Authorised key written to {0}' -f $target)
    }

    if ($target -eq $adminKeyFile) {
        # sshd refuses to read administrators_authorized_keys unless ONLY
        # SYSTEM + Administrators can access it.
        $icaclsOutput = & icacls.exe $target /inheritance:r /grant 'SYSTEM:F' 'BUILTIN\Administrators:F' 2>&1
        $icaclsOutput | ForEach-Object { Write-Log ('icacls: ' + $_) }
        Log-Ok 'Key file permissions locked to SYSTEM + Administrators.'
    }

    # Password auth off: the phone key is the only way in.
    $configPath = Join-Path $env:ProgramData 'ssh\sshd_config'
    if (Test-Path -LiteralPath $configPath) {
        Copy-Item -LiteralPath $configPath -Destination ($configPath + '.bridge.bak') -Force
        $cfg = Get-Content -LiteralPath $configPath -Raw
        if ($cfg -match '(?m)^\s*#?\s*PasswordAuthentication\s+') {
            $cfg = [regex]::Replace($cfg, '(?m)^\s*#?\s*PasswordAuthentication\s+\S+',
                                    'PasswordAuthentication no')
        } else {
            $cfg = $cfg.TrimEnd() + "`r`nPasswordAuthentication no`r`n"
        }
        Set-Content -LiteralPath $configPath -Value $cfg -Encoding ascii
        Restart-Service -Name sshd -ErrorAction SilentlyContinue
        Log-Ok 'Disabled SSH password authentication and restarted sshd.'
        Log-Info ('Backup of the original config: {0}' -f ($configPath + '.bridge.bak'))
    } else {
        Log-Warn ('sshd_config not found at {0} - skipping hardening.' -f $configPath)
    }
}

# ---------------------------------------------------------------------------
# 4. Optional: let the stack task run when nobody is logged on
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- 4/4  Stack task ---' -ForegroundColor White

if (Test-Path -LiteralPath $RemoteScript) {
    $taskOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RemoteScript ensure-task 2>&1
    $taskOut | ForEach-Object { Write-Log ('task: ' + $_) }

    if ($RunWithoutLogon) {
        Write-Host ''
        Write-Host 'Enter your Windows password so Task Scheduler can start the stack' -ForegroundColor Yellow
        Write-Host 'even when nobody is logged on at this PC.' -ForegroundColor Yellow
        $cred = Get-Credential -UserName ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
            -Message 'Windows password for the BridgeStack task'
        if ($cred) {
            $plain = $cred.GetNetworkCredential().Password
            $changeOut = & schtasks.exe /Change /TN $TaskName /RU $cred.UserName /RP $plain 2>&1
            $changeOut | ForEach-Object { Write-Log ('schtasks: ' + $_) }
            $verify = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if ($verify -and $verify.Principal.LogonType -eq 'Password') {
                Log-Ok 'Task now runs whether or not you are logged on.'
            } else {
                Log-Warn 'Could not confirm the logon type - check with: schtasks /query /tn BridgeStack /v /fo list'
            }
        } else {
            Log-Warn 'No credential entered - the task still needs an interactive logon.'
        }
    } else {
        Log-Info 'Task left as on-demand with an Interactive logon.'
        Log-Warn 'If this PC boots to the login screen and nobody logs in, the task cannot start.'
        Log-Warn 'Fix that by re-running this script with -RunWithoutLogon (or by logging in first).'
    }
} else {
    Log-Fail ('bridge-remote.ps1 not found at {0}' -f $RemoteScript)
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
$tsName = $null
if (Test-Path -LiteralPath $tailscaleExe) {
    try {
        $tsJson = & $tailscaleExe status --json 2>$null | ConvertFrom-Json
        if ($tsJson -and $tsJson.Self -and $tsJson.Self.DNSName) {
            $tsName = ($tsJson.Self.DNSName -replace '\.$', '')
        }
    } catch { }
}
$sshHost = if ($tsName) { $tsName } else { '<this-pc>.<your-tailnet>.ts.net' }

Write-Summary ''
Write-Summary '==============================================================' 'Cyan'
Write-Summary '   Setup finished' 'Cyan'
Write-Summary '==============================================================' 'Cyan'
Write-Summary ''
Write-Summary '  NEXT STEPS' 'White'
Write-Summary ''
Write-Summary '  1. On your phone: install Tailscale, sign in with the SAME account'
Write-Summary '     you used on this PC, and turn the VPN switch ON.'
Write-Summary ''
Write-Summary '  2. On your phone: install an SSH app (Termius is a good free one).'
Write-Summary ('     Add a host:  address {0}   user {1}' -f $sshHost, $env:USERNAME) 'Green'
if ($env:USERNAME -match '\s') {
    Write-Summary '     NOTE: that username contains a space - quote it in the app.' 'Yellow'
}
if ($privateKey) {
    Write-Summary ('     Import this private key into the app: {0}' -f $privateKey) 'Green'
} else {
    Write-Summary '     Your own key was authorised via -PublicKey - nothing to import.' 'Green'
}
Write-Summary ''
Write-Summary '  3. Save these as one-tap snippets in the app:' 'White'
Write-Summary '       powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\Documents\PythonScripts\bridge\bridge-remote.ps1" status'
Write-Summary '       powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\Documents\PythonScripts\bridge\bridge-remote.ps1" start'
Write-Summary '       powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\Documents\PythonScripts\bridge\bridge-remote.ps1" stop'
Write-Summary '       powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\Documents\PythonScripts\bridge\bridge-remote.ps1" shutdown -Minutes 5'
Write-Summary ''
Write-Summary '  4. To use the translation UI from your phone, open:' 'White'
Write-Summary ('       http://{0}:8000' -f $sshHost) 'Green'
Write-Summary ''
Write-Summary ('  Full log: {0}' -f $LogFile) 'DarkGray'
Write-Summary ''
Write-Summary '  (This summary is also written to the log above, in case this window closes.)'
Log-Ok 'Done. See REMOTE_ACCESS.md for the walkthrough and troubleshooting.'
