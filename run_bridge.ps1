# run_bridge.ps1
Clear-Host
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "         BRIDGE REMOTE TUNNEL AUTOMATION SERVER           " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Fetch the Public IP (Tunnel Password)
Write-Host "Checking public IP address for tunnel authentication..." -ForegroundColor Yellow
try {
    $publicIP = (Invoke-WebRequest -Uri "https://icanhazip.com" -TimeoutSec 5 -UseBasicParsing).Content.Trim()
    
    # Copy to clipboard for easy sharing
    Set-Clipboard -Value $publicIP
    
    Write-Host "----------------------------------------------------------" -ForegroundColor Green
    Write-Host " TUNNEL PASSWORD (YOUR IP): $publicIP" -ForegroundColor Green
    Write-Host " [COPIED TO CLIPBOARD AUTOMATICALLY]                      " -ForegroundColor DarkGreen
    Write-Host "----------------------------------------------------------" -ForegroundColor Green
} catch {
    Write-Host "⚠️ Could not fetch public IP automatically. You may need to look it up manually." -ForegroundColor Khaki
}

Write-Host ""
Write-Host "Starting secure tunnel on port 8000 with subdomain 'bridge'..." -ForegroundColor Yellow
Write-Host "Press CTRL+C in this window to stop the tunnel at any time." -ForegroundColor DarkGray
Write-Host ""

# 2. Launch Localtunnel
npx localtunnel --port 8000 --subdomain bridge