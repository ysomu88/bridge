#Requires -Version 5.1
<#
    restart-tailscale.ps1
    ==========================================================================
    Recovers a Tailscale backend that is wedged in "state: NoState".

    Symptom this fixes:
      tailscale status  ->  "unexpected state: NoState"
                             "Tailscale is starting. Please wait."
      and connections to the PC's 100.x tailnet address time out, because
      the virtual adapter exists but there is no working tunnel behind it.

    What it does: stops the service, restarts it, and waits for the backend to
    report a real state.

    HONEST LIMITATION: on the machine where this was first hit, a service
    restart did NOT clear the NoState state (the process count stayed the same
    before and after - two tailscaled.exe processes is normal on Windows, not a
    bug). A reboot is the reliable fix. Keep this script as a cheap first
    attempt before resorting to one.
#>
[CmdletBinding()]
param()

# Not 'Stop' on purpose: the Tailscale CLI and service cmdlets write to stderr.
$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host ''
    Write-Host 'Administrator rights are required to restart the Tailscale service.' -ForegroundColor Yellow
    Write-Host 'Relaunching elevated - accept the UAC prompt...' -ForegroundColor Yellow
    $re = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"' + $PSCommandPath + '"'))
    Start-Process powershell -Verb RunAs -ArgumentList $re | Out-Null
    Write-Host 'Handed off to the elevated window - this one can be closed.' -ForegroundColor DarkGray
    exit 0
}

$ts = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'

function Get-TsIp {
    try {
        $out = & $ts ip -4 2>&1
        if ($LASTEXITCODE -eq 0) { return (([string]($out | Select-Object -First 1)).Trim()) }
    } catch { }
    return $null
}

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

Write-Host ''
Write-Host '=== BEFORE ===' -ForegroundColor Cyan
Write-Host ('  tailscaled processes : {0}' -f @(Get-Process tailscaled -ErrorAction SilentlyContinue).Count)
Write-Host ('  service              : {0}' -f (Get-Service Tailscale -ErrorAction SilentlyContinue).Status)
$before = & $ts status 2>&1 | Select-Object -First 3
Write-Host '  status               :' -NoNewline
$before | ForEach-Object { Write-Host (' ' + $_) -ForegroundColor DarkGray }
Write-Host ''

Write-Host '--- Restarting the backend ---' -ForegroundColor White

Stop-Service -Name Tailscale -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

$stale = @(Get-Process tailscaled -ErrorAction SilentlyContinue)
if ($stale.Count -gt 0) {
    Write-Host ("  killing {0} tailscaled process(es):" -f $stale.Count)
    foreach ($p in $stale) {
        try {
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            Write-Host ("    killed PID {0}" -f $p.Id)
        } catch {
            Write-Host ("    !! could not kill PID {0}: {1}" -f $p.Id, $_.Exception.Message) -ForegroundColor Red
        }
    }
} else {
    Write-Host '  no stray tailscaled processes'
}
Start-Sleep -Seconds 2

Start-Service -Name Tailscale -ErrorAction SilentlyContinue
Write-Host '  service started - waiting up to 60s for the backend...'

$ip = $null
for ($i = 1; $i -le 30; $i++) {
    Start-Sleep -Seconds 2
    $ip = Get-TsIp
    if ($ip) { Write-Host ("  backend came up after ~{0}s" -f ($i * 2)); break }
}

Write-Host ''
Write-Host '=== AFTER ===' -ForegroundColor Cyan
Write-Host ('  tailscaled processes : {0}' -f @(Get-Process tailscaled -ErrorAction SilentlyContinue).Count)
Write-Host ('  service              : {0}' -f (Get-Service Tailscale -ErrorAction SilentlyContinue).Status)
Write-Host ('  tailnet IP           : {0}' -f $(if ($ip) { $ip } else { 'STILL NOT AVAILABLE' }))

if ($ip) {
    try {
        $j = & $ts status --json 2>$null | ConvertFrom-Json
        $dns = ($j.Self.DNSName -replace '\.$', '')
        Write-Host ('  MagicDNS name        : {0}' -f $dns)
    } catch { }

    Write-Host ''
    Write-Host '--- SSH reachability over the tailnet ---' -ForegroundColor White
    $open = Test-Port $ip 22
    Write-Host ("  TCP {0}:22 -> {1}" -f $ip, $(if ($open) { 'OPEN - your phone can connect' } else { 'STILL BLOCKED' })) `
        -ForegroundColor $(if ($open) { 'Green' } else { 'Red' })

    if ($open) {
        try {
            $c = New-Object System.Net.Sockets.TcpClient
            $c.ReceiveTimeout = 4000
            $c.Connect($ip, 22)
            $r = New-Object System.IO.StreamReader($c.GetStream())
            Write-Host ('  SSH banner           : ' + $r.ReadLine()) -ForegroundColor Green
            $r.Close(); $c.Close()
        } catch { }
    }
} else {
    Write-Host ''
    Write-Host '  The backend is still not up. Next steps:' -ForegroundColor Yellow
    Write-Host '   1. Re-authenticate:  & "$env:ProgramFiles\Tailscale\tailscale.exe" up' -ForegroundColor Yellow
    Write-Host '   2. If that still fails, reboot the PC and sign in to Tailscale again.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Paste the output above if it is still broken and I will dig further.' -ForegroundColor DarkGray
Write-Host ''
