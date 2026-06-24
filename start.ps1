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

# 3. Give Ollama a tiny 2-second head start to bind to its port
Start-Sleep -Seconds 2

# 4. Activate uv environment and launch the FastAPI server in this window
Write-Host "⚡ Activating environment and starting Uvicorn server..." -ForegroundColor Green
Write-Host ""
& ".\.venv\Scripts\Activate.ps1"
python server.py