# ==============================================================================
# Bridge Automated Setup Script (PowerShell)
# Automates the complete environment setup, CUDA PyTorch configuration,
# Chatterbox voice cloning installation, numpy override, and model downloads.
# ==============================================================================

[CmdletBinding()]
param(
    [switch]$ForceReinstall,
    [switch]$IncludeKorean
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n[+] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

# Resolve root directory
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (Test-Path (Join-Path $ScriptDir "..\server.py")) {
    $RootDir = (Resolve-Path (Join-Path $ScriptDir "..")).Path
} else {
    $RootDir = (Resolve-Path $ScriptDir).Path
}

Set-Location $RootDir
Write-Host "=================================================================" -ForegroundColor Magenta
Write-Host " Bridge Voice Translation Server - Automated Setup" -ForegroundColor Magenta
Write-Host " Target Directory: $RootDir" -ForegroundColor Magenta
Write-Host "=================================================================" -ForegroundColor Magenta

# 1. Verify uv package manager
Write-Step "Checking for 'uv' package manager..."
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Warn "'uv' is not found on PATH. Attempting to install via winget/powershell..."
    try {
        winget install --id astral-sh.uv --exact --source winget --accept-source-agreements --accept-package-agreements
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    } catch {
        Write-Err "Could not automatically install uv. Please install uv from https://astral.sh/uv or run: powershell -ExecutionPolicy ByPass -c `"irm https://astral.sh/uv/install.ps1 | iex`""
        exit 1
    }
}
Write-Success "uv is available ($(uv --version))"

# 2. Virtual Environment Creation / Activation
Write-Step "Verifying Python 3.12 virtual environment (.venv)..."
if (-not (Test-Path ".venv\Scripts\Activate.ps1")) {
    Write-Host "Creating virtual environment with Python 3.12..." -ForegroundColor Gray
    uv venv .venv --python 3.12
}
Write-Success "Virtual environment ready."

$VenvPython = Join-Path $RootDir ".venv\Scripts\python.exe"

# 3. Base requirements installation
Write-Step "Installing base requirements from requirements.txt..."
uv pip install -r requirements.txt

# 4. Verified 3-step install from troubleshooting guide
# Step A: Install PyTorch with CUDA 12.4
Write-Step "[Step 1/3] Installing PyTorch with CUDA 12.4 (--index-url https://download.pytorch.org/whl/cu124)..."
uv pip install --reinstall torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0 --index-url https://download.pytorch.org/whl/cu124

# Step B: Install chatterbox-tts with --no-deps and supporting libraries
Write-Step "[Step 2/3] Installing chatterbox-tts (voice cloning) with --no-deps..."
uv pip install "chatterbox-tts>=0.1.4" --no-deps
uv pip install "llvmlite>=0.43.0" "numba>=0.60.0" "librosa>=0.10.0" "resemble-perth" --no-deps
uv pip install conformer diffusers einops rotary-embedding-torch encodec vector-quantize-pytorch

# Step C: Apply overrides.txt to resolve the numba / numpy conflict
Write-Step "[Step 3/3] Applying overrides.txt for numba/numpy compatibility..."
if (Test-Path "overrides.txt") {
    uv pip install -r overrides.txt
} else {
    uv pip install --reinstall "numpy>=2.0.2,<3"
}
Write-Success "3-step dependency installation complete!"

# 5. Fetch required model files
Write-Step "Downloading model files (Kokoro ONNX & Piper voices)..."
$DownloadScript = Join-Path $RootDir "scripts\download_models.py"
$DownloadArgs = @()
if ($ForceReinstall) { $DownloadArgs += "--force" }
if ($IncludeKorean) { $DownloadArgs += "--include-korean" }

& $VenvPython $DownloadScript @DownloadArgs
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Model downloader finished with warnings or errors. Check your internet connection."
}

# 6. Environment & Hardware Verification
Write-Step "Verifying installed environment and hardware acceleration..."
$VerifyScript = @"
import sys
import torch
import numpy as np

print(f' - Python version: {sys.version.split()[0]}')
print(f' - NumPy version: {np.__version__}')
print(f' - PyTorch version: {torch.__version__}')
cuda_ok = torch.cuda.is_available()
print(f' - CUDA Available: {cuda_ok}')
if cuda_ok:
    print(f' - Device: {torch.cuda.get_device_name(0)}')

try:
    import chatterbox
    print(' - Chatterbox TTS: Available [OK]')
except Exception as e:
    print(f' - Chatterbox TTS: Warning ({e})')

try:
    import perth
    w = perth.PerthImplicitWatermarker()
    print(' - PerTh Watermarking: Available [OK]')
except Exception as e:
    print(f' - PerTh Watermarking: Warning ({e})')
"@

& $VenvPython -c $VerifyScript

# 7. Check external prerequisites (Ollama and eSpeak NG)
Write-Step "Checking external dependencies..."
if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    Write-Warn "Ollama is not installed or not in PATH. Download it from https://ollama.com to enable translation."
} else {
    Write-Success "Ollama detected on PATH."
}

$EspeakPath = "C:\Program Files\eSpeak NG\espeak-ng.exe"
if (-not (Test-Path $EspeakPath)) {
    Write-Warn "eSpeak NG not found at '$EspeakPath'."
    Write-Warn "eSpeak NG is required for non-English Kokoro TTS. Download the installer from:"
    Write-Host " https://github.com/espeak-ng/espeak-ng/releases/latest" -ForegroundColor Cyan
} else {
    Write-Success "eSpeak NG detected at $EspeakPath."
}

Write-Host "`n=================================================================" -ForegroundColor Green
Write-Host " Setup complete! To start Bridge:" -ForegroundColor Green
Write-Host "   Local run:       .\start.ps1" -ForegroundColor Yellow
Write-Host "   Remote share:    .\bridge-remote.ps1 start" -ForegroundColor Yellow
Write-Host "=================================================================`n" -ForegroundColor Green
