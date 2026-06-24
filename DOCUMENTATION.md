# Bridge — Architecture & Technical Reference

**Stack:** faster-whisper · Ollama (llama3.2) · Kokoro-82M ONNX · eSpeak NG
**Target:** RTX 3070 Ti (8 GB VRAM) · Windows 11 · `uv` package manager · `localtunnel` for remote access

---

## Architecture

```
Browser mic (Raw Float32 PCM stream)
        │
        ├─ VAD: ScriptProcessorNode → RMS dBFS → {"type":"vad","db":-28.3}
        │
        │  WebSocket /ws/stream  (binary PCM + JSON text frames)
        ▼
  [FastAPI server.py]
        │
        ├─ VAD gate: silence threshold (default -40 dBFS, user-adjustable per session)
        │       └─ 500 ms consecutive silence → trigger pipeline
        │
        ├─ faster-whisper "base" (CUDA int8, <350 MB VRAM)
        │       └─ Silero VAD filter (second-pass cleanup)
        │       └─ Language: set from WebSocket query param (?source=en&target=es)
        │
        ├─ Ollama → llama3.2 (3B, Q4, ~2.0 GB VRAM)
        │       └─ Dynamic system prompt: "translate {src_language} to {tgt_language}"
        │
        └─ Kokoro-82M ONNX + eSpeak NG phonemizer → raw int16 PCM chunks
                └─ Language routed via KOKORO_LANG_MAP
                └─ websocket.send_bytes() → Web Audio API → speaker
```

### Why Raw Float32 PCM?

Early versions sent WebM/Opus container chunks via `MediaRecorder`. Individual WebM chunks cannot be decoded in isolation — they depend on codec headers that only exist in the first chunk, so server-side energy measurement always failed.

The current pipeline bypasses containers entirely. The browser's `ScriptProcessorNode` extracts raw float32 PCM directly from the microphone hardware track and sends it over the WebSocket. The server reconstructs the audio array with `np.frombuffer(data, dtype=np.float32)` — no decoder, no file parsing, minimal latency.

---

## Supported Languages

| Language | STT Code | Kokoro Lang | Kokoro Voice | Notes |
|---|---|---|---|---|
| English | `en` | `en-us` | `af_heart` | |
| Spanish | `es` | `es` | `ef_dora` | |
| French | `fr` | `fr-fr` | `ff_siwis` | Requires eSpeak NG |
| Italian | `it` | `it` | `if_sara` | Requires eSpeak NG |
| Japanese | `ja` | `ja` | `jf_alpha` | Requires eSpeak NG |
| Chinese | `zh` | `cmn` | `zf_xiaobei` | espeak lang code is `cmn`, not `zh` |
| Hindi | `hi` | `hi` | `hf_alpha` | Requires eSpeak NG |
| Portuguese | `pt` | `pt-br` | `pf_dora` | Requires eSpeak NG |
| Korean | `ko` | — | — | STT + translation only; TTS coming in future release |

---

## VRAM Budget (RTX 3070 Ti, 8 GB)

| Component | VRAM |
|---|---|
| faster-whisper base (int8) | ~350 MB |
| Kokoro-82M (ONNX) | ~250 MB |
| Ollama llama3.2 (3B, Q4) | ~2.0 GB |
| OS / display / overhead | ~0.6 GB |
| **Total** | **~3.2 GB** ✅ |

---

## Configuration Reference

| Setting | Location | Default |
|---|---|---|
| Silence threshold (dBFS) | `server.py` → `VAD_SILENCE_DB` | -40.0 |
| Silence duration before trigger | `server.py` → `VAD_SILENCE_DURATION_S` | 0.5 s |
| Minimum speech length | `server.py` → `VAD_MIN_SPEECH_S` | 0.3 s |
| Ollama model | `server.py` → `OLLAMA_MODEL` | `llama3.2` |
| Whisper model size | `server.py` → `WhisperModel(...)` | `base` |
| eSpeak NG path (Windows) | `server.py` → Windows startup block | `C:\Program Files\eSpeak NG` |
| TTS sample rate | `index.html` → `SAMPLE_RATE` | 24000 Hz |

The silence threshold can be adjusted live via the slider in the browser UI without restarting. Each WebSocket session maintains its own threshold.

---

## WebSocket Message Protocol

### Browser → Server

| Frame type | Format | Purpose |
|---|---|---|
| Binary | Raw float32 PCM (16 kHz mono) | Audio chunk (~256 ms at 4096 buffer size) |
| Text JSON | `{"type":"vad","db":-28.3}` | RMS energy of current chunk |
| Text JSON | `{"type":"set_threshold","db":-30}` | Update silence threshold for this session |

### Server → Browser

| Frame type | Format | Purpose |
|---|---|---|
| Text JSON | `{"type":"subtitle","src":"...","tgt":"...","en":"...","es":"..."}` | Transcription + translation |
| Binary | Raw int16 PCM @ 24 kHz | TTS audio chunk |

---

## eSpeak NG on Windows

Kokoro-82M uses `phonemizer` under the hood to convert text to phonemes before synthesis. For non-English languages, `phonemizer` requires the eSpeak NG shared library (`libespeak-ng.dll`) to be present on the system.

`server.py` sets the required environment variables automatically at startup:

```python
os.environ["PHONEMIZER_ESPEAK_LIBRARY"] = r"C:\Program Files\eSpeak NG\libespeak-ng.dll"
os.environ["PHONEMIZER_ESPEAK_PATH"]    = r"C:\Program Files\eSpeak NG\espeak-ng.exe"
```

These must be set **before** any phonemizer imports, which is why they live at the very top of `server.py` before any other imports.

If eSpeak NG is installed to a non-default path, update these two lines accordingly.

---

## Concurrency Model

Bridge uses Python's `asyncio` for concurrency — a single thread, single event loop. CPU-bound work (Whisper inference, audio decode) runs in a thread pool via `run_in_executor`. The Ollama HTTP call is natively async via `httpx.AsyncClient`.

A per-session `processing_lock` prevents race conditions when two silence triggers fire close together:

```python
async def process_utterance():
    if processing_lock.locked():
        return  # drop duplicate trigger
    async with processing_lock:
        raw = state.get_buffer_bytes()
        state.flush_buffer()
```

Each WebSocket connection gets its own `SessionState` — isolated audio buffer, VAD state, language pair, and silence threshold. Multiple devices can connect simultaneously and each runs an independent pipeline.

---

## Troubleshooting

### No voice output for non-English languages
Install eSpeak NG from https://github.com/espeak-ng/espeak-ng/releases/latest (`.msi` for Windows), then restart the server. The server sets the required env vars automatically — no manual configuration needed.

### Chinese TTS not working
The espeak lang code for Mandarin is `cmn`, not `zh`. This is already handled in `KOKORO_LANG_MAP` but worth knowing if you're debugging phonemizer errors directly.

### "Ollama not reachable at localhost:11434"
Run `ollama serve` in a separate terminal before starting the server.

### CUDA not detected for Whisper
```powershell
pip install ctranslate2 --force-reinstall --index-url https://download.pytorch.org/whl/cu121
```

### Translation never triggers
Background noise floor is above the silence threshold. Watch the Mic Level bar while silent — it should sit below the marker. Drag the Silence threshold slider right until it does.