# Bridge — Real-Time Voice Translation

## 🎤 What is Bridge?

**Bridge** is a local, real-time voice-to-voice translation engine that runs entirely on your machine. Speak in any supported language and hear the translation spoken back instantly — with live streaming subtitles and immediate audio feedback.

No cloud APIs. No subscriptions. 100% private, local compute.

<div align="center">
  <img src="docs/UI.png" width="600"/>

  [![Build Status](https://github.com/ysomu88/bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/ysomu88/bridge/actions)
</div>

---

## ✨ Features

- 🎙️ **Real-time translation** — Low end-to-end processing latency
- 🌍 **9 languages supported** — English, Spanish, French, Italian, Japanese, Chinese, Hindi, Korean, and Portuguese
- 🔄 **Any direction** — Pick source and target from dropdowns, swap with one click
- 🚀 **Streamlined audio pipeline** — Raw Float32 PCM sent directly over WebSocket into NumPy, no container decoding overhead
- 📝 **Live subtitles** — Source and translation rendered side by side, updating in real time
- 🔊 **Natural voice output** — Ultra-fast TTS streamed back to your browser
- 🎙️ **Voice cloning playback** — Optionally hear the translation in *your own voice* from a 15-second sample, instead of a preset voice
- 💻 **Low VRAM footprint** — Fits comfortably on 8 GB VRAM (tested on RTX 3070 Ti, Windows 11)
- 🌐 **Remote sharing ready** — Tunnel your pipeline so external users can connect from any browser

---

## 🌍 Supported Languages

| Language | Speak (STT) | Translate | Voice (TTS) |
|---|---|---|---|
| 🇺🇸 English | ✅ | ✅ | ✅ |
| 🇪🇸 Spanish | ✅ | ✅ | ✅ |
| 🇫🇷 French | ✅ | ✅ | ✅ |
| 🇮🇹 Italian | ✅ | ✅ | ✅ |
| 🇯🇵 Japanese | ✅ | ✅ | ✅ |
| 🇨🇳 Chinese | ✅ | ✅ | ✅ |
| 🇮🇳 Hindi | ✅ | ✅ | ✅ |
| 🇧🇷 Portuguese | ✅ | ✅ | ✅ |
| 🇰🇷 Korean | ✅ | ✅ | 🔜 |

> Korean voice output, German, and Telugu are coming in a future release.

---

## 🎙️ Voice Cloning Playback

Instead of hearing translations in a preset voice, you can clone your own voice from a short recording and have translations played back as if you said them.

1. Click **Record a 15s sample** in the Playback Voice panel and speak naturally for the full 15 seconds — the recording stops automatically
2. Once uploaded, check **Use my cloned voice**
3. Start a session as normal — translated audio now plays back in your own voice

Voice cloning supports a different language list than the rest of Bridge:

Arabic, Danish, German, Greek, English, Spanish, Finnish, French, Hebrew, Hindi, Italian, Japanese, Korean, Malay, Dutch, Norwegian, Polish, Portuguese, Russian, Swedish, Swahili, Turkish, Chinese

If your target language isn't on that list (Telugu, for example), or if cloning fails for any reason mid-session, Bridge falls back automatically to the normal preset voice — translation never stops working.

Recorded voice samples are stored locally in `voice_samples/` and never leave your machine. They are not committed to git.

> For best results, match the language of your reference recording to your most common target language. If they differ, the cloned voice may carry a slight accent from the reference clip's language.

---

## 🚀 Quick Start

### Prerequisites

- Python 3.12 (managed via `uv`)
- NVIDIA GPU with CUDA 12.x drivers
- [Ollama](https://ollama.com) installed locally
- [eSpeak NG](https://github.com/espeak-ng/espeak-ng/releases/latest) installed (required for non-English voice output)
- Node.js & npm (for remote tunnel via `winget install OpenJS.NodeJS`)

> Voice cloning is optional and loads automatically if `chatterbox-tts` installs successfully. It adds roughly 2-3 GB VRAM on top of the rest of the stack. If it fails to load, Bridge logs a warning and falls back to preset voices — nothing else breaks.

### 1. Set up the environment

```powershell
uv venv .venv --python 3.12
.\.venv\Scripts\Activate.ps1
uv pip install -r requirements.txt
```

### 2. Pull the translation model

```powershell
ollama pull llama3.2
```

---

## ⚡ Running Bridge

### Option A: One-click local launch

```powershell
.\start.ps1
```

Opens Ollama in a separate terminal, activates the environment, and starts the server.

### Option B: Remote access via tunnel

Browsers block microphone access over plain HTTP. To share Bridge with a remote user:

```powershell
# In one terminal — start the server
.\.venv\Scripts\Activate.ps1
python server.py

# In another terminal — open the tunnel
.\run_bridge.ps1
```

This exposes a secure public endpoint at **https://bridge.loca.lt** so anyone can connect directly to your local GPU pipeline from their browser.

### Option C: Manual

```powershell
# Terminal 1
ollama serve

# Terminal 2
.\.venv\Scripts\Activate.ps1
python server.py
```

Then open **http://localhost:8000**, pick your languages, click **▶ Start Listening**, and speak.

---

## 🎚️ Tuning the silence threshold

If translation doesn't trigger after you stop speaking, your background noise floor may be above the VAD threshold. Watch the **Mic Level** bar while silent — it should sit below the marker line. Drag the **Silence threshold** slider right until the resting noise level falls below the marker.

| Environment | Suggested threshold |
|---|---|
| Quiet room | -40 to -35 dBFS |
| Normal office | -32 to -28 dBFS |
| Noisy environment | -25 to -20 dBFS |

---

## 📁 Files

| File | Purpose |
|---|---|
| `server.py` | FastAPI backend — WebSocket, Whisper STT, Ollama translation, Kokoro TTS |
| `index.html` | Browser client — mic capture, VAD, subtitle display, audio playback |
| `start.ps1` | One-click local launch script |
| `requirements.txt` | Python dependencies |
| `DOCUMENTATION.md` | Full architecture and technical reference |
| `TECHNICAL_WALKTHROUGH.md` | Step-by-step explanation of how it works |
| `voice_samples/` | Locally recorded voice cloning reference clips (gitignored) |

---

## 🔧 Troubleshooting

**Translation never triggers after I stop speaking**
→ Drag the Silence threshold slider right until background noise sits below the marker line. See the tuning table above.

**No voice output for non-English languages**
→ Install [eSpeak NG](https://github.com/espeak-ng/espeak-ng/releases/latest) (download the `-x64.msi` file and run with default settings), then restart the server.

**"Voice cloning isn't available on this server"**
→ `chatterbox-tts` failed to install or load. Run `uv pip install chatterbox-tts torchaudio` and check the server startup log for the specific error.

**Cloned voice sounds accented or off**
→ Normal if your reference recording's language doesn't match your target translation language — see the Voice Cloning section above for accent tips.

**Voice upload fails with "Could not process the audio sample"**
→ Usually a codec issue converting your browser's recording to WAV. Make sure ffmpeg is installed and on PATH, or try recording again.

**"Ollama not reachable"**
→ Run `ollama serve` in a separate terminal before starting the server.

**"llama3.2 not found"**
→ Run `ollama pull llama3.2`.

**No audio playback**
→ Click anywhere on the page first — browsers require a user gesture before playing audio. Check the browser console for Web Audio errors.

**"The term '.\run_bridge.ps1' is not recognized"**
→ Run this first to allow local script execution:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
```

**CUDA not detected for Whisper**
```powershell
pip install ctranslate2 --force-reinstall --index-url https://download.pytorch.org/whl/cu121
```