# Bridge — Real-Time Voice Translation

[![Python](https://img.shields.io/badge/python-3.10+-blue.svg)](https://www.python.org)

## 🎤 What is Bridge?

**Bridge** is a local, real-time voice-to-voice translation app that runs entirely on your computer. Speak in English and hear your words translated to Spanish instantly — with live subtitles and adjustable silence detection.

No internet required. Everything runs locally on your machine.

---

## ✨ Features

- 🎙️ **Real-time translation** — ~1.5 second end-to-end latency
- 📝 **Live subtitles** — English transcription and Spanish translation side by side
- 🔊 **Natural voice output** — Kokoro-82M TTS streamed directly to your browser
- 🎚️ **Adjustable silence threshold** — drag the slider in the UI to tune for your environment
- 🔒 **100% local** — no data leaves your machine
- 💻 **Low VRAM** — runs on ~7 GB VRAM (RTX 3070 Ti tested)
- 📱 **Mobile-friendly** — connect any phone or tablet via browser on your LAN

---

## 🚀 Quick Start

### Prerequisites

- Python 3.10+
- NVIDIA GPU with CUDA 12.x drivers (recommended)
- [Ollama](https://ollama.com) installed and running

### 1. Pull the translation model

```powershell
ollama serve           # run in a separate terminal, keep it open
ollama pull llama3.2
```

### 2. Set up the environment

```powershell
uv venv .venv --python 3.11
.\.venv\Scripts\Activate.ps1
uv pip install -r requirements.txt
```

If CTranslate2 doesn't pick up your GPU automatically:

```powershell
pip install ctranslate2 --index-url https://download.pytorch.org/whl/cu121
```

### 3. Run Bridge

```powershell
python server.py
```

### 4. Open in browser

Navigate to **http://localhost:8000**, click **▶ Start Listening**, and speak.

---

## 🎚️ Tuning the silence threshold

If translation never triggers, your background noise level may be above the silence threshold. Watch the **Mic Level** bar while silent — the bar should sit below the threshold marker. If it doesn't, drag the **Silence threshold** slider to the right until the resting noise level falls below the marker.

Typical values:
| Environment | Suggested threshold |
|---|---|
| Quiet room | -40 to -35 dBFS |
| Normal room | -32 to -28 dBFS |
| Noisy environment | -25 to -20 dBFS |

---

## 📁 File Overview

| File | Purpose |
|---|---|
| `server.py` | FastAPI backend — WebSocket, Whisper STT, Ollama translation, Kokoro TTS |
| `index.html` | Browser client — mic capture, VAD meter, subtitle display, audio playback |
| `requirements.txt` | Python dependencies |
| `pyproject.toml` | uv/pip project config |
| `DOCUMENTATION.md` | Full architecture and troubleshooting reference |

---

## 🔧 Troubleshooting

**Translation never triggers after I stop talking**
→ Background noise is above the silence threshold. Drag the slider right until the level bar sits below the marker when you're not speaking.

**"Ollama not reachable"**
→ Run `ollama serve` in a separate PowerShell window first.

**"llama3.2 not found"**
→ Run `ollama pull llama3.2`.

**No audio from speaker**
→ Click anywhere on the page first (browser autoplay policy). Check the browser console for Web Audio errors.

**CUDA not detected for Whisper**
→ `pip install ctranslate2 --force-reinstall --index-url https://download.pytorch.org/whl/cu121`