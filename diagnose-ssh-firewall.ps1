#Requires -Version 5.1
<#
    diagnose-ssh-firewall.ps1
    ==========================================================================
    SSH to this PC over Tailscale times out even though sshd is listening.
    A timeout (not "refused") means packets are being dropped, so this script
    dumps the firewall state, then applies the minimum fix needed.

    It is safe to run repeatedly, and it only ever touches rules that relate
    to the Tailscale interface - everything it changes is listed at the end.

    USAGE
      .\diagnose-ssh-firewall.ps1              # diagnose, then fix
      .\diagnose-ssh-firewall.ps1 -ReportOnly  # look only, change nothing
#>
[CmdletBinding()]
param(
    [switch]$ReportOnly
)

# Not 'Stop' on purpose: the netsecurity cmdlets write to stderr.
$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host ''
    Write-Host 'Administrator rights are needed to read/change firewall rules.' -ForegroundColor Yellow
    Write-Host 'Relaunching elevated - accept the UAC prompt...' -ForegroundColor Yellow
    $re = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit')
    if ($ReportOnly) { $re += '-ReportOnly' }
    $re += @('-File', ('"' + $PSCommandPath + '"'))
    Start-Process powershell -Verb RunAs -ArgumentList $re | Out-Null
    Write-Host 'Handed off to the elevated window - this one can be closed.' -ForegroundColor DarkGray
    exit 0
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Test-Port {
    param([string]$Target, [int]$Port, [int]$TimeoutMs = 4000)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $a = $c.BeginConnect($Target, $Port, $null, $null)
        if (-not $a.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $c.EndConnect($a)
        return $true
    } catch { return $false } finally { try { $c.Close() } catch { } }
}

function Get-SshBanner {
    param([string]$Target, [int]$Port = 22)
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.ReceiveTimeout = 4000
        $c.Connect($Target, $Port)
        $r = New-Object System.IO.StreamReader($c.GetStream())
        $banner = $r.ReadLine()
        $r.Close(); $c.Close()
        return $banner
    } catch { return $null }
}

$tailscaleExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$tsIp = $null
$tsStateNote = 'Tailscale not installed'
if (Test-Path -LiteralPath $tailscaleExe) {
    try { $tsIp = ((& $tailscaleExe ip -4 2>$null) | Select-Object -First 1) } catch { }
    if ($tsIp) {
        $tsIp = ([string]$tsIp).Trim()
        $tsStateNote = 'backend is healthy'
    } else {
        # No IP can mean two very different things - tell them apart.
        $st = (& $tailscaleExe status 2>&1 | Out-String)
        if ($st -match 'NoState') {
            $tsStateNote = 'BACKEND IS DOWN (NoState) - run .\restart-tailscale.ps1 first'
        } else {
            $tsStateNote = 'no tailnet IP - not logged in? run: tailscale up'
        }
    }
}

$tsAlias = $null
$adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceDescription -match 'Tailscale' -or $_.Name -match 'Tailscale' } |
    Select-Object -First 1
if ($adapter) { $tsAlias = $adapter.Name }

Write-Host ''
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host '   Tailscale SSH connectivity diagnosis' -ForegroundColor Cyan
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host ("Tailscale IP : {0}" -f $(if ($tsIp) { $tsIp } else { 'NOT FOUND' }))
Write-Host ("Tailscale if : {0}" -f $(if ($tsAlias) { $tsAlias } else { 'NOT FOUND' }))
Write-Host ''

# ---------------------------------------------------------------------------
# 1. Report
# ---------------------------------------------------------------------------
Write-Host '--- 1. Firewall profiles (DefaultInboundAction should be Block) ---' -ForegroundColor White
Get-NetFirewallProfile -ErrorAction SilentlyContinue |
    Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction |
    Format-Table -AutoSize

Write-Host '--- 2. Network categories (Tailscale is usually Public) ---' -ForegroundColor White
Get-NetConnectionProfile -ErrorAction SilentlyContinue |
    Select-Object InterfaceAlias, NetworkCategory, IPv4Connectivity |
    Format-Table -AutoSize

Write-Host '--- 3. The rule created by setup-remote-access.ps1 ---' -ForegroundColor White
$setupRule = Get-NetFirewallRule -Name 'Bridge-OpenSSH-TailscaleOnly' -ErrorAction SilentlyContinue
if ($setupRule) {
    $setupRule | Select-Object DisplayName, Enabled, Direction, Action, Profile | Format-List
    ($setupRule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue) |
        Select-Object RemoteAddress | Format-List
} else {
    Write-Host '  !! RULE NOT FOUND - this is very likely the cause' -ForegroundColor Red
}

Write-Host '--- 4. Enabled inbound BLOCK rules (these override Allow) ---' -ForegroundColor White
$blocks = @(Get-NetFirewallRule -Direction Inbound -Action Block -Enabled True -ErrorAction SilentlyContinue)
if ($blocks.Count -eq 0) {
    Write-Host '  (none)'
} else {
    $blocks | Select-Object DisplayName, Profile | Format-Table -AutoSize
}

Write-Host '--- 5. Tailscale-related rules ---' -ForegroundColor White
$tsRules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'Tailscale' })
if ($tsRules.Count -eq 0) { Write-Host '  (none)' }
else { $tsRules | Select-Object DisplayName, Enabled, Direction, Action, Profile | Format-Table -AutoSize }

Write-Host '--- 6. Test before any change ---' -ForegroundColor White
if ($tsIp) {
    $before = Test-Port $tsIp 22
    Write-Host ("  TCP {0}:22 -> {1}" -f $tsIp, $(if ($before) { 'OPEN' } else { 'TIMEOUT / BLOCKED' }))
} else {
    Write-Host '  skipped (no Tailscale IP)'
}
Write-Host ''

# ---------------------------------------------------------------------------
# 2. Fix
# ---------------------------------------------------------------------------
$changed = @()

if ($ReportOnly) {
    Write-Host '--- ReportOnly: no changes made ---' -ForegroundColor Yellow
} else {
    Write-Host '--- Applying fix ---' -ForegroundColor White

    # (a) Allow TCP 22 on the Tailscale virtual interface specifically. This is
    #     the rule Tailscale's own docs call for: the adapter sits on the Public
    #     profile, where Windows blocks inbound by default.
    if ($tsAlias) {
        $name = 'Bridge-SSH-TailscaleIface'
        Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
        try {
            New-NetFirewallRule -Name $name `
                -DisplayName 'OpenSSH (Tailscale interface only)' `
                -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow `
                -InterfaceAlias $tsAlias -Profile Any -ErrorAction Stop | Out-Null
            $changed += "created allow rule '$name' (interface $tsAlias)"
        } catch {
            Write-Host ("  !! could not create interface rule: " + $_.Exception.Message) -ForegroundColor Red
        }
    }

    # (b) Belt and braces: the same allow, scoped to the Tailscale CGNAT range
    #     instead of the interface, in case the adapter name differs.
    $cidrName = 'Bridge-SSH-TailscaleCIDR'
    Get-NetFirewallRule -Name $cidrName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    try {
        New-NetFirewallRule -Name $cidrName `
            -DisplayName 'OpenSSH (Tailscale 100.64.0.0/10 only)' `
            -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow `
            -RemoteAddress '100.64.0.0/10' -Profile Any -ErrorAction Stop | Out-Null
        $changed += "created allow rule '$cidrName' (100.64.0.0/10)"
    } catch {
        Write-Host ("  !! could not create CIDR rule: " + $_.Exception.Message) -ForegroundColor Red
    }

    # (c) A Block rule beats any Allow rule, so disable any inbound block that
    #     is explicitly bound to the Tailscale interface.
    if ($tsAlias) {
        foreach ($r in $blocks) {
            $ifFilter = $r | Get-NetFirewallInterfaceFilter -ErrorAction SilentlyContinue
            if ($ifFilter -and (@($ifFilter.InterfaceAlias) -contains $tsAlias)) {
                try {
                    Disable-NetFirewallRule -Name $r.Name -ErrorAction Stop
                    $changed += "disabled BLOCK rule '$($r.DisplayName)' (targeted $tsAlias)"
                } catch {
                    Write-Host ("  !! could not disable " + $r.DisplayName + ': ' + $_.Exception.Message) -ForegroundColor Red
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Verify + summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- Test after change ---' -ForegroundColor White
$after = $null
$banner = $null
if ($tsIp) {
    $after = Test-Port $tsIp 22
    Write-Host ("  TCP {0}:22 -> {1}" -f $tsIp, $(if ($after) { 'OPEN' } else { 'STILL BLOCKED' }))
    if ($after) {
        $banner = Get-SshBanner $tsIp 22
        Write-Host ("  SSH banner    : {0}" -f $(if ($banner) { $banner } else { '(none)' }))
    }
}
Write-Host ''

Write-Host '==============================================================' -ForegroundColor Cyan
if ($changed.Count -eq 0) {
    Write-Host '   No changes were made' -ForegroundColor Cyan
} else {
    Write-Host '   Changes made:' -ForegroundColor Cyan
    $changed | ForEach-Object { Write-Host ("     - " + $_) -ForegroundColor Gray }
}
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host ''

if ($after) {
    Write-Host '  FIXED. You can now connect from your phone.' -ForegroundColor Green
    Write-Host ('  Host address : bridge-pc   (port 22, user "{0}")' -f $env:USERNAME) -ForegroundColor Green
    Write-Host ''
    Write-Host '  To undo later:'
    Write-Host '    Get-NetFirewallRule -Name Bridge-SSH-TailscaleIface,Bridge-SSH-TailscaleCIDR | Remove-NetFirewallRule'
} else {
    Write-Host '  STILL BLOCKED. Likely causes, in order of probability:' -ForegroundColor Yellow
    Write-Host '   1. Third-party antivirus/firewall (Bitdefender, Norton, McAfee, ESET...)' -ForegroundColor Yellow
    Write-Host '      - add an inbound allow for TCP 22 in that product, or exclude sshd.exe' -ForegroundColor Yellow
    Write-Host '   2. A Tailscale ACL in the admin console blocking inbound (check Access Controls)' -ForegroundColor Yellow
    Write-Host '   3. Corporate/college policy on this machine blocking inbound entirely' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Paste the full output above and I will tell you exactly which one it is.' -ForegroundColor Yellow
}
Write-Host ''

