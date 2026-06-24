# Bridge — Architecture & Technical Reference

**Stack:** faster-whisper · Ollama (llama3.2) · Kokoro-82M ONNX
**Target:** RTX 3070 Ti (8 GB VRAM) · Windows 11 · `uv` package manager

---

## Architecture

```
Browser mic (100 ms WebM chunks)
        │
        ├─ VAD: AnalyserNode → RMS dBFS → {"type":"vad","db":-28.3}
        │
        │  WebSocket /ws/stream  (binary + JSON text frames)
        ▼
  [FastAPI server.py]
        │
        ├─ VAD gate: silence threshold (default -35 dBFS, user-adjustable)
        │       └─ 800 ms consecutive silence → trigger pipeline
        │
        ├─ faster-whisper "base" (CUDA int8, <400 MB VRAM)
        │       └─ Silero VAD filter (second-pass cleanup)
        │
        ├─ Ollama → llama3.2
        │       └─ strict system prompt: EN → ES only, no filler
        │
        └─ Kokoro-82M ONNX → raw int16 PCM chunks
                └─ websocket.send_bytes() → Web Audio API → speaker
```

### Why client-side VAD?

WebM is a container format — individual 100 ms chunks cannot be decoded in
isolation because the codec context (headers) only exists in the first chunk.
Trying to run `soundfile.read()` on a single chunk returns nothing, which the
old server-side approach misread as silence. The fix: compute RMS energy in the
browser using `AnalyserNode.getFloatTimeDomainData()`, which has direct access
to the raw PCM samples, and send the dBFS value to the server as a JSON message.
The server uses that value for VAD decisions and only decodes the full WebM
buffer once, at transcription time, when all chunks are available.

---

## VRAM Budget (RTX 3070 Ti, 8 GB)

| Component | VRAM |
|---|---|
| faster-whisper base (int8) | ~350 MB |
| Kokoro-82M (ONNX) | ~250 MB |
| Ollama llama3.2 (3B, Q4) | ~2.0 GB |
| OS / display / overhead | ~0.5 GB |
| **Total** | **~3.1 GB** ✅ |

> llama3.2 (3B) uses far less VRAM than the original OmniCoder model (~6 GB),
> leaving plenty of headroom on a 3070 Ti.

---

## Configuration reference

| Setting | Location | Default |
|---|---|---|
| Silence threshold (dBFS) | `server.py` → `VAD_SILENCE_DB` | -35.0 |
| Silence duration before trigger | `server.py` → `VAD_SILENCE_DURATION_S` | 0.8 s |
| Minimum speech length | `server.py` → `VAD_MIN_SPEECH_S` | 0.3 s |
| Ollama model | `server.py` → `OLLAMA_MODEL` | `llama3.2` |
| Whisper model size | `server.py` → `WhisperModel(...)` | `base` |
| TTS voice | `server.py` → `_generate_chunks()` | `af_bella` |
| TTS sample rate | `index.html` → `SAMPLE_RATE` | 24000 Hz |

The silence threshold can also be adjusted live via the slider in the browser UI
without restarting the server. Each WebSocket session maintains its own threshold.

---

## WebSocket message protocol

### Browser → Server

| Frame type | Format | Purpose |
|---|---|---|
| Binary | Raw WebM/Opus bytes | Audio chunk (100 ms) |
| Text JSON | `{"type":"vad","db":-28.3}` | RMS energy of current chunk |
| Text JSON | `{"type":"set_threshold","db":-30}` | Update silence threshold |

### Server → Browser

| Frame type | Format | Purpose |
|---|---|---|
| Text JSON | `{"type":"subtitle","en":"...","es":"..."}` | Transcription + translation |
| Binary | Raw int16 PCM @ 24 kHz | TTS audio chunk |

---

## Installation

### Prerequisites

| Tool | Install |
|---|---|
| Python 3.10+ | https://www.python.org |
| `uv` | `pip install uv` |
| CUDA 12.x drivers | NVIDIA Game Ready / Studio driver |
| Ollama | `winget install Ollama.Ollama` |

### Steps

```powershell
# 1. Start Ollama and pull the model
ollama serve
ollama pull llama3.2

# 2. Create environment
uv venv .venv --python 3.11
.\.venv\Scripts\Activate.ps1
uv pip install -r requirements.txt

# 3. If CUDA isn't picked up for Whisper
pip install ctranslate2 --index-url https://download.pytorch.org/whl/cu121

# 4. Run
python server.py
```

---

## Troubleshooting

### Translation never triggers after silence

Watch the **Mic Level** bar while not speaking. The bar must sit below the
threshold marker for silence to be detected. Drag the **Silence threshold**
slider right (less negative) until resting noise falls below the marker.

### "Ollama not reachable at localhost:11434"

Run `ollama serve` in a separate terminal before starting the server.

### "llama3.2 not found in Ollama"

```powershell
ollama pull llama3.2
```

### No audio playback in browser

- Click anywhere on the page first (browser autoplay policy)
- Check browser console for Web Audio API errors
- Verify the server logs show `🔊 TTS stream complete`

### Kokoro voice error

Available voices vary by kokoro-onnx version. If `af_bella` fails, check
`voices.json` in your project directory for valid voice names.

### CUDA not detected for Whisper

```powershell
pip install ctranslate2 --force-reinstall --index-url https://download.pytorch.org/whl/cu121
```

---

## Multi-user / conversation mode

Each WebSocket connection is fully isolated — its own audio buffer, VAD state,
and silence threshold. Two people can connect from separate devices
(e.g. `http://192.168.x.x:8000` on your LAN) and each gets an independent
translation pipeline. Full bidirectional A↔B conversation mode (where each
speaker's mic routes to the other person's speaker) is not yet implemented.