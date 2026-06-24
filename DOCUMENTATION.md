# Bridge — Architecture & Technical Reference

**Stack:** faster-whisper (es) · Ollama (llama3.2) · Kokoro-82M ONNX (en-us)
**Target:** RTX 3070 Ti (8 GB VRAM) · Windows 11 · `uv` package manager · `localtunnel` Secure Ingress

---

## Architecture

```text
Browser mic (Raw Float32 PCM Stream)
        │
        ├─ VAD: AnalyserNode → RMS dBFS → {"type":"vad","db":-28.3}
        │
        │  WebSocket /ws/stream  (Binary PCM + JSON Text frames)
        ▼
  [FastAPI server.py]
        │
        ├─ Concurrency Fence: processing_lock = asyncio.Lock() (Protects 8GB VRAM allocation)
        ├─ VAD gate: silence threshold (default -35 dBFS, user-adjustable)
        │        └─ 500 ms consecutive silence → trigger pipeline (Physiological breath-tuned)
        │
        ├─ faster-whisper "base" (CUDA int8, <350 MB VRAM, language forced to "es")
        │        └─ Silero VAD filter (second-pass cleanup)
        │
        ├─ Ollama → llama3.2 (3B, Q4, ~2.0 GB VRAM)
        │        └─ strict system prompt: ES → EN only, zero conversational preamble
        │
        └─ Kokoro-82M ONNX (CUDA, ~250 MB VRAM) → English raw chunk streams
                 └─ websocket.send_bytes() → Gapless Web Audio Scheduling → speaker

```

### Why Raw Float32 PCM Streams? (Zero-Container Ingestion)

In legacy iterations, audio chunks were packaged into heavy WebM/Opus containers via the browser's `MediaRecorder`. This introduced massive overhead because WebM blobs cannot be decoded in isolation without initialized header meta-frames.

The optimized pipeline bypasses containers entirely. The client extracts raw floating-point data directly out of the microphone hardware track using the browser's Web Audio API.

* **Zero-Decoder Extraction:** Raw arrays are sent straight across the WebSocket every 100 milliseconds.
* **C-Speed Memory Mapping:** The server uses `np.frombuffer(binary_message, dtype=np.float32)` to reconstruct data vectors in place at C-speed. This completely strips out third-party disk-bound or file-descriptor parsing engines like `soundfile`, drastically lowering pipeline latency.

---

## VRAM Budget (RTX 3070 Ti, 8 GB)

| Component | VRAM |
| --- | --- |
| `faster-whisper` base (int8) | ~350 MB |
| `Kokoro-82M` (ONNX CUDA) | ~250 MB |
| Ollama `llama3.2` (3B, Q4) | ~2.0 GB |
| OS / display / desktop overhead | ~0.6 GB |
| **Total Allocation Envelope** | **~3.2 GB** ✅ |

### Memory Guard & Concurrency Control

Because the stack runs comfortably inside standard graphics memory allocations, resource exhaustion is protected via an internal cooperative mutex fence: `processing_lock = asyncio.Lock()`. If multiple clients speak at the same time, the server triggers an early return for colliding requests, dropping overlapping noise spikes instead of backing them up in an execution queue. This strictly protects your local GPU from VRAM thrashing or allocation page faults.

---

## Configuration Reference

| Setting | Location | Default |
| --- | --- | --- |
| Silence threshold (dBFS) | `server.py` → `VAD_SILENCE_DB` | -35.0 |
| Silence duration before trigger | `server.py` → `VAD_SILENCE_TIMEOUT_S` | 0.5 s |
| Transcription Target Language | `server.py` → `whisper_model.transcribe(..., language="es")` | `es` (Spanish) |
| Translation Platform Engine | `server.py` → `OLLAMA_MODEL` | `llama3.2` |
| TTS Target System Voice | `server.py` → `kokoro_pipeline.create(..., voice="af_bella", lang="en-us")` | `en-us` (English) |
| Client Ingestion Sample Rate | `index.html` → `navigator.mediaDevices.getUserMedia` | 16000 Hz |
| Client Audio Playback Sample Rate | `index.html` → `playbackCtx = new AudioContext(...)` | 24000 Hz |

---

## WebSocket Message Protocol

### Browser → Server

| Frame Type | Format | Purpose |
| --- | --- | --- |
| Binary | Raw Float32 PCM Stream | 100ms streaming voice buffer frame |
| Text JSON | `{"type":"vad","db":-28.3}` | Native browser client RMS energy metric |
| Text JSON | `{"type":"set_threshold","db":-30}` | Real-time live dynamic slider synchronization |

### Server → Browser

| Frame Type | Format | Purpose |
| --- | --- | --- |
| Text JSON | `{"type":"subtitle","es":"...","en":"..."}` | Side-by-side translation subtitle text block |
| Binary | Raw Signed Int16 PCM @ 24 kHz | Native sequential TTS synthesizer voice stream |

---

## Installation & Deployment

### Prerequisites

| Tool / Runtime | Deployment Target Link |
| --- | --- |
| Python 3.12 | https://www.python.org |
| `uv` Package Engine | Installed globally (`pip install uv`) |
| CUDA 12.x Core Suite | NVIDIA Studio / Game Ready Run-times |
| Node.js & npm | `winget install OpenJS.NodeJS` (Required for remote tunnels) |
| Ollama Daemon | Core local installer architecture |

### Execution Workflow

```powershell
# 1. Populate the localized Ollama weight cache
ollama pull llama3.2

# 2. Build local python sandbox environment via uv
uv venv .venv --python 3.12
.\.venv\Scripts\Activate.ps1
uv pip install -r requirements.txt

# 3. Boot application core backend
python server.py

# 4. Optional: Expose endpoint to external users over HTTPS/WSS
.\run_bridge.ps1

```

---

## Remote Access Automation (Hosting for Others)

Browsers enforce strict client security layer protections (`navigator.mediaDevices.getUserMedia`), instantly disabling mic recording pipelines on any standard unencrypted `http://` domain that is not explicitly evaluated as `localhost`.

To host the application from your machine for an external browser user, you must run a secure TLS proxy tunnel. Bridge includes a customized automation script `run_bridge.ps1` that wraps over `localtunnel` to streamline this configuration:

1. **Keep `python server.py` running** in its initial workspace frame.
2. Open a separate PowerShell console window and invoke the deployment script: `.\run_bridge.ps1`.
3. The script automatically fetches your public WAN IP address, drops it directly into your clipboard, and exposes a clean public link (e.g., `https://bridge.loca.lt`).
4. **Share with your user:** Send them the URL link and paste your IP address. The user submits the IP as the entry password on the anti-phishing protection landing screen, and the application safely proxies secure WebSockets (`wss://`) back to your GPU hardware layer.

---

## Troubleshooting

### Translation never triggers after speaking

* Check the **Mic Level** UI visualizer bar while keeping your room silent. The incoming audio line must drop entirely below the threshold marker point for the server silence duration countdown to start.
* Drag the **Silence threshold** slider rightward (less negative, e.g., to `-28`) until ambient desk fans or background hums drop completely below the trigger marker line.

### "npx: term is not recognized" when initializing tunnels

* Node.js is missing or path variables are not loaded. Run `winget install OpenJS.NodeJS`, close out your PowerShell windows completely, and start a fresh terminal frame to register the node system execution parameters.

### No audio playback output in remote browser

* Ensure the user explicitly clicks anywhere on the client dashboard interface page first. Modern desktop and mobile browsers enforce absolute autoplay restrictions that prevent programmatic audio rendering streams until a manual user gesture activates the playback audio context.

### CUDA or cuBLAS runtime initialization errors

* The underlying transcription engine targets CUDA 12 runtimes natively on Windows. If initialization fails, run this command inside your activated environment to force the underlying CTranslate2 layer libraries to synchronize with your system drivers:
```powershell
pip install ctranslate2 --force-reinstall --index-url [https://download.pytorch.org/whl/cu121](https://download.pytorch.org/whl/cu121)