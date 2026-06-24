# Bridge — Real-Time Voice Translation

[![Python](https://img.shields.io/badge/python-3.12-blue.svg)](https://www.python.org)

## 🎤 What is Bridge?

**Bridge** is a local, real-time voice-to-voice translation engine that runs entirely on your local machine. Speak in English and hear your words translated to Spanish instantly — featuring live streaming subtitles, optimized low-latency voice detection, and immediate audio feedback.

No cloud APIs. No subscriptions. 100% private, local compute.

<div align="center">
  <img src="docs/UI.png" width="600"/>
</div>

---

## ✨ Features

- 🎙️ **Real-time translation** — Low end-to-end processing latency.
- 🚀 **Streamlined Audio Pipeline** — Transmits raw Float32 PCM audio arrays natively over WebSockets directly into NumPy memory arrays at C-speed, eliminating heavy container decoding steps.
- 📝 **Live subtitles** — English transcription and Spanish translation rendered side by side.
- 🔊 **Natural voice output** — Ultra-fast inference via `kokoro-onnx` streamed directly back to your browser client.
- 🎚️ **Optimized VAD Detection** — Configured for natural human conversational pauses (~400-500ms), reducing delivery delay when you finish speaking.
- 🔒 **100% local** — Zero data leaves your machine.
- 💻 **Low VRAM footprint** — Fits comfortably on an 8 GB VRAM budget (optimized and tested on an RTX 3070 Ti running Windows 11).
- 📱 **Mobile-friendly** — Connect any phone or tablet via browser over your Local Area Network (LAN).
- 🎤 *Additional language support coming soon (only EN/ES available now)*
---

## 🚀 Quick Start

### Prerequisites

- Python 3.12 (Managed via `uv` recommended)
- NVIDIA GPU with CUDA 12.x runtimes
- [Ollama](https://ollama.com) installed locally

### 1. Set up the environment

Clone the repository and spin up your virtual environment using `uv` for speed:

```powershell
uv venv .venv --python 3.12
.\.venv\Scripts\Activate.ps1
uv pip install -r requirements.txt

```

### 2. Pull the translation engine

Ensure your local Ollama environment is populated with the matching execution model:

```powershell
ollama pull llama3.2

```

---

## ⚡ Automation & Execution

You can run the stack using manually separated terminal shells, or launch it with one-click automation profiles.

### Option A: Native VS Code Task Automation (Recommended)

If developing inside VS Code, a workspace task runner is ready out-of-the-box.

1. Open the project root folder in VS Code.
2. Press **`Ctrl + Shift + B`**.
3. VS Code will spin up a parallel terminal cluster, launch your background Ollama engine, load the `uv` environment, and boot your FastAPI instance concurrently.

### Option B: Local PowerShell Automation Script

For running the stack standalone from a native terminal frame without opening an IDE layout:

```powershell
.\start.ps1

```

*(This automatically checks your paths, binds Ollama in a separate pipeline, and routes your core FastAPI logs to the current viewport).*

### Option C: Manual Launch

If you prefer managing the terminals independently:

```powershell
# Terminal 1: Background Engine
ollama run llama3.2

# Terminal 2: Python Application Server
.\.venv\Scripts\Activate.ps1
python server.py

```

Open your browser to **`http://localhost:8000`**, click **▶ Start Listening**, and speak.

---

## 🎚️ Tuning the silence threshold

If translation execution fails to trigger after you finish speaking, your ambient background noise floor might sit above the digital Voice Activity Detection (VAD) threshold.

Watch the **Mic Level** meter while remaining completely silent. The signal should sit below the threshold marker. If it peaks or hovers over it, adjust the **Silence threshold** slider rightwards until your room's resting noise level rests below the trigger ceiling.

| Environment Profile | Suggested Target Range |
| --- | --- |
| Isolation / Quiet Room | -40 to -35 dBFS |
| Standard Room / Office | -32 to -28 dBFS |
| Busy / Noisy Environment | -25 to -20 dBFS |

---

## 📁 File Architecture

| File | Subsystem Role |
| --- | --- |
| `server.py` | FastAPI Asynchronous Backend — WebSocket lifecycle, Faster-Whisper STT, Ollama API translation interface, `kokoro-onnx` TTS pipeline. |
| `index.html` | Client Interface — Native HTML5 Audio capture, raw PCM stream conversion, live VAD monitoring, side-by-side subtitle render matrix. |
| `start.ps1` | Native PowerShell cluster bootstrapper. |
| `.vscode/tasks.json` | Project-scoped background build task orchestrator. |
| `requirements.txt` | Explicit Python tracking matrix (`uv` optimized). |
| `.gitignore` | Configured to track collaborative shared environments (`tasks.json`) while securely blocking local model blobs (`*.onnx`, `*.bin`) and active virtual environments. |

---

## 🔧 Troubleshooting

**"The system ignores or clips my speech mid-sentence"**
→ Your `VAD_SILENCE_TIMEOUT_S` configuration in `server.py` may be set tighter than your natural breathing cadences. Try resetting the constant closer to human baseline breathing loops (`0.4` or `0.5` seconds) to balance speech continuity with speed.

**"The term '.\start.ps1' is not recognized..."**
→ If Windows blocks script execution due to localized execution profiles, run this single assignment command in your PowerShell terminal frame to permit local runtime execution:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process

```

**"Ollama not reachable"**
→ Ensure the Ollama background host engine is executing. Run `ollama run llama3.2` to verify local availability.

**"CUDA/cuBLAS runtime DLL execution errors on Windows"**
→ The environment targets CUDA 12 runtimes natively. If you encounter missing library logs during heavy STT transcribing operations, confirm that `nvidia-cublas-cu12` and `nvidia-cudnn-cu12` loaded cleanly from your `requirements.txt` validation pass.
