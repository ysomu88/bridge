# Bridge — Local Real-Time Voice-to-Voice Translation

**Stack:** faster-whisper · Ollama (OmniCoder-2-9B) · Kokoro-82M  
**Target:** RTX 3070 Ti (8 GB VRAM) · Windows 11 · `uv` package manager

---

## Architecture at a glance

```
Browser mic (100 ms WebM chunks)
        │  WebSocket /ws/stream
        ▼
  [FastAPI server.py]
        │
        ├─ faster-whisper "base" (CUDA int8, <1 GB VRAM)
        │       └─ Silero VAD → 500 ms silence boundary
        │
        ├─ Ollama  →  carstenuhlig/omnicoder-2-9b:q4_k_m
        │               └─ strict system prompt: EN → ES only
        │
        └─ Kokoro-82M TTS  →  raw PCM chunks
                └─ websocket.send_bytes() → browser Web Audio API
```

---

## Prerequisites

| Tool | Install |
|------|---------|
| Python 3.10+ | https://www.python.org |
| `uv` | `pip install uv` or https://docs.astral.sh/uv/ |
| CUDA 12.x drivers | NVIDIA Game Ready / Studio driver |
| Ollama | https://ollama.com — `winget install Ollama.Ollama` |
| Git (optional) | For cloning |

---

## Step 1 — Pull the Ollama model

```powershell
# Start Ollama (runs on localhost:11434)
ollama serve

# In a new terminal, pull the model
ollama pull carstenuhlig/omnicoder-2-9b:q4_k_m
```

Leave `ollama serve` running in the background.

---

## Step 2 — Create environment and install dependencies

```powershell
# From the project folder
uv venv .venv --python 3.11
.\.venv\Scripts\Activate.ps1

# Core dependencies
uv pip install fastapi "uvicorn[standard]" websockets soundfile numpy httpx

# STT — faster-whisper with CUDA support
uv pip install faster-whisper
# If CTranslate2 CUDA is missing, force the CUDA wheel:
pip install ctranslate2 --index-url https://download.pytorch.org/whl/cu121

# TTS — choose ONE:
uv pip install kokoro-onnx          # Recommended: ONNX, no PyTorch needed
# OR
uv pip install kokoro               # PyTorch variant (slightly higher quality)
```

### Kokoro voice model download

Kokoro downloads its model weights automatically on first run (~82 MB).  
If you need to pre-download:

```powershell
python -c "from kokoro import KPipeline; KPipeline(lang_code='s')"
```

---

## Step 3 — Run the server

```powershell
# Make sure .venv is active and ollama serve is running
python server.py
```

You should see:

```
INFO  Loading faster-whisper 'base' model on CUDA (int8)…
INFO  ✅ Whisper model loaded on CUDA.
INFO  Loading Kokoro-82M TTS pipeline (Spanish)…
INFO  ✅ Kokoro TTS pipeline ready.
INFO  Uvicorn running on http://0.0.0.0:8000
```

---

## Step 4 — Open the browser

Navigate to: **http://localhost:8000**

1. Click **▶ Start Listening**
2. Grant microphone permission
3. Speak English — subtitles and Spanish audio will follow in ~1–1.5 s
4. Click **⏹ Stop** to end the session

---

## VRAM Budget (RTX 3070 Ti, 8 GB)

| Component | VRAM |
|-----------|------|
| faster-whisper base (int8) | ~350 MB |
| Kokoro-82M (ONNX) | ~250 MB |
| Ollama (q4_k_m, 9B) | ~5.5–6 GB |
| OS / display / overhead | ~0.5 GB |
| **Total** | **~6.6–7.1 GB** ✅ |

> If Ollama and Whisper/Kokoro compete for VRAM, start `ollama serve` first.  
> Ollama auto-offloads to CPU when under pressure, but latency will increase.

---

## Configuration

| Setting | File | Variable |
|---------|------|----------|
| Ollama model name | `server.py` | `OLLAMA_MODEL` |
| Ollama URL | `server.py` | `OLLAMA_URL` |
| Silence threshold | `server.py` | `SessionState.SILENCE_DURATION_S` |
| Whisper model size | `server.py` | `WhisperModel("base", …)` → change to `"small"` for better accuracy |
| TTS voice | `server.py` | `kokoro_pipeline(text, voice="af_bella", …)` |
| TTS sample rate | `index.html` | `SAMPLE_RATE = 24000` |

---

## Troubleshooting

### "Ollama not reachable at localhost:11434"
Run `ollama serve` in a separate PowerShell window before starting the server.

### "CUDA unavailable for Whisper — falling back to CPU"
Reinstall CTranslate2 with the CUDA extra:
```powershell
pip install ctranslate2 --force-reinstall --index-url https://download.pytorch.org/whl/cu121
```

### No audio playback in browser
- Check browser console for Web Audio errors
- Chrome/Edge: click anywhere on the page first (autoplay policy requires user gesture)
- Verify the server is sending binary frames: watch for `[AUDIO] Scheduled N frames` in server logs

### MediaRecorder sends 0-byte chunks
Some browsers won't emit data if the tab is in the background. Keep the tab visible while speaking.

### Kokoro voice not found
Available Spanish voices: `af_bella`, `ef_dora`, `hf_alpha`, `hf_beta`  
See https://github.com/hexgrad/kokoro for the full voice list.

---

## Extending to other language pairs

1. Change `language="en"` in `transcribe()` to the source language code
2. Update `TRANSLATION_SYSTEM_PROMPT` with the new target language
3. Change `KPipeline(lang_code=...)` to the target language code:
   - `'a'` = American English, `'b'` = British English
   - `'e'` = Spanish (Spain), `'f'` = French, `'h'` = Hindi, `'j'` = Japanese
   - `'p'` = Brazilian Portuguese, `'z'` = Chinese (Mandarin)

---

## Multi-user / hardware isolation

Each WebSocket connection gets its own `SessionState` instance with an isolated
audio buffer and independent VAD tracking. Two phones connecting simultaneously
will each receive their own transcription → translation → TTS loop without
audio bleed between sessions.