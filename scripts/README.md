# Bridge Scripts Directory

This directory contains operational, runtime, diagnostic, and remote-administration scripts for the **Bridge** voice translation server.

> **Note on Setup & Installation Scripts:**  
> All environment setup installers (`setup.ps1`, `setup.bat`) and model weight downloaders (`download_models.py`) are located in **[`../technical-setup/`](../technical-setup/)** alongside the architecture reference and troubleshooting documentation.

---

## 📋 Script Inventory

| Script | Needed? | Purpose & Details |
|---|:---:|---|
| **`start.ps1`** | **Yes** | **1-Click Local Launch**: Boots Ollama, waits for port `11434` to become responsive, activates `.venv`, and starts `server.py`. |
| **`bridge-remote.ps1`** | **Yes** | **Remote Stack Control**: Full operational engine to start, stop, restart, inspect status, tail logs, manage public tunnels, and trigger background daemon execution. |
| **`bridge.cmd`** | **Yes** | **Short CLI Alias**: Allows running `bridge start`, `bridge stop`, etc., from any terminal when `scripts/` is on `PATH`. |
| **`setup-remote-access.ps1`** | **Yes** | **Host Provisioning**: One-time elevated setup script for OpenSSH Server, Tailscale integration, phone SSH keys, and `BridgeStack` scheduled task. |
| **`restart-tailscale.ps1`** | **Yes** | **Network Recovery Helper**: Restarts the Tailscale Windows service and resets virtual adapters when Tailscale hangs in `NoState`. |
| **`diagnose-ssh-firewall.ps1`** | **Yes** | **Firewall Diagnostic Tool**: Audits Windows Defender Firewall rules and applies minimum fixes when SSH over Tailscale times out. |

---

## ⚡ Quick Usage Examples

### 1. Launch Local Server
```powershell
.\scripts\start.ps1
```

### 2. Remote Management & Monitoring
```powershell
.\scripts\bridge-remote.ps1 status
.\scripts\bridge-remote.ps1 start
.\scripts\bridge-remote.ps1 logs -Tail 80
.\scripts\bridge-remote.ps1 stop
```

### 3. Machine Setup & Installation
For setting up the environment, PyTorch CUDA 12.4, Chatterbox, and downloading models, see:
```powershell
.\technical-setup\setup.ps1
```
*(or run `.\technical-setup\setup.bat` from CMD)*

---

## 📖 Related Documentation
- Full technical architecture & setup guides: **[`../technical-setup/README.md`](../technical-setup/README.md)**
- Remote access & phone control guide: **[`../technical-setup/REMOTE_ACCESS.md`](../technical-setup/REMOTE_ACCESS.md)**
- Dependency troubleshooting & recovery: **[`../technical-setup/bridge-troubleshooting-guide.md`](../technical-setup/bridge-troubleshooting-guide.md)**
