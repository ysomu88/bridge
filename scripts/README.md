# Bridge Scripts Directory

This directory contains operational, setup, diagnostic, and remote-administration scripts for the **Bridge** voice translation server.

---

## 📋 Script Inventory

| Script | Needed? | Purpose & Details |
|---|:---:|---|
| **`start.ps1`** | **Yes** | **1-Click Local Launch**: Boots Ollama, waits for port `11434` to become responsive, activates `.venv`, and starts `server.py`. |
| **`bridge-remote.ps1`** | **Yes** | **Remote Stack Control**: Full operational engine to start, stop, restart, inspect status, tail logs, manage public tunnels, and trigger background daemon execution. |
| **`bridge.cmd`** | **Yes** | **Short CLI Alias**: Allows running `bridge start`, `bridge stop`, etc., from any terminal when `scripts/` is on `PATH`. |
| **`setup.ps1` / `setup.bat`** | **Yes** | **Automated Environment Installer**: 1-click setup automating PyTorch CUDA 12.4, Chatterbox Multilingual TTS (`--no-deps`), `overrides.txt` (numpy compatibility), and model downloads. |
| **`download_models.py`** | **Yes** | **Model Asset Downloader**: Automatically downloads Kokoro ONNX weights (`model.onnx`), `voices.json`, and German Thorsten Piper voice models if missing from clone. |
| **`setup-remote-access.ps1`** | **Yes** | **Host Provisioning**: One-time elevated setup script for OpenSSH Server, Tailscale integration, phone SSH keys, and `BridgeStack` scheduled task. |
| **`restart-tailscale.ps1`** | **Yes** | **Network Recovery Helper**: Restarts the Tailscale Windows service and resets virtual adapters when Tailscale hangs in `NoState`. |
| **`diagnose-ssh-firewall.ps1`** | **Yes** | **Firewall Diagnostic Tool**: Audits Windows Defender Firewall rules and applies minimum fixes when SSH over Tailscale times out. |

---

## ⚡ Quick Usage Examples

### 1. Initial Machine Setup
```powershell
.\scripts\setup.ps1
```
*(or run `.\scripts\setup.bat` from CMD)*

### 2. Launch Local Server
```powershell
.\scripts\start.ps1
```

### 3. Fetch Model Assets
```powershell
python scripts\download_models.py
```
*(Add `--include-korean` to also download optional Korean Piper voice weights)*

### 4. Remote Management & Monitoring
```powershell
.\scripts\bridge-remote.ps1 status
.\scripts\bridge-remote.ps1 start
.\scripts\bridge-remote.ps1 logs -Tail 80
.\scripts\bridge-remote.ps1 stop
```

---

## 📖 Related Documentation
- Full technical architecture & server guides: **[`../technical-setup/README.md`](../technical-setup/README.md)**
- Remote access & phone control guide: **[`../technical-setup/REMOTE_ACCESS.md`](../technical-setup/REMOTE_ACCESS.md)**
- Dependency troubleshooting & recovery: **[`../technical-setup/bridge-troubleshooting-guide.md`](../technical-setup/bridge-troubleshooting-guide.md)**
