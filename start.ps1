# Clear the console window
Clear-Host

Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "  🚀 Waking up the Bridge Translation Stack...         " -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Verify the Python virtual environment exists
if (-not (Test-Path ".\.venv\Scripts\Activate.ps1")) {
    Write-Host "❌ Error: Virtual environment (.venv) not found!" -ForegroundColor Red
    Write-Host "Please run 'uv venv' and 'uv pip install -r requirements.txt' first." -ForegroundColor Yellow
    Write-Host ""
    Pause
    Exit
}

# 2. Boot up Ollama in a brand new, separate terminal window
Write-Host "🤖 Launching Ollama (llama3.2)..." -ForegroundColor Yellow
Start-Process powershell -ArgumentList "-NoExit", "-Command", "ollama serve"

# 3. Wait until Ollama has actually bound its HTTP port (poll up to ~30s)
#    instead of relying on a blind sleep — on a cold start llama3.2 can take
#    far longer than 2 seconds to come up, and the server's first translations
#    would otherwise silently fail against a port that isn't listening yet.
Write-Host "⏳ Waiting for Ollama to bind localhost:11434..." -ForegroundColor Yellow
$ollamaReady = $false
for ($attempt = 1; $attempt -le 30; $attempt++) {
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -TimeoutSec 2 -UseBasicParsing
        if ($resp.StatusCode -eq 200) {
            $ollamaReady = $true
            break
        }
    } catch {
        # Port not open yet (or still starting) — keep polling
    }
    Start-Sleep -Seconds 1
}

if ($ollamaReady) {
    Write-Host "✅ Ollama is up and responding." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "❌ Ollama did not respond on http://localhost:11434 within 30s." -ForegroundColor Red
    Write-Host "   Start it manually with 'ollama serve' and re-run this script." -ForegroundColor Yellow
    Write-Host ""
    Pause
    Exit
}

# 4. Activate uv environment and launch the FastAPI server in this window
Write-Host "⚡ Activating environment and starting Uvicorn server..." -ForegroundColor Green
Write-Host ""
& ".\.venv\Scripts\Activate.ps1"
python server.py