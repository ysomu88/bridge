# Bridge: Architecture & Technical Reference

**Stack:** faster-whisper · Ollama (llama3.2) · Kokoro-82M ONNX · Piper TTS · Chatterbox Multilingual · eSpeak NG  
**Target:** RTX 3070 Ti (8 GB VRAM) · Windows 11 · `uv` package manager · `localtunnel` for remote access

---

## Architecture

```
Browser mic (Raw Float32 PCM stream)
        │
        ├─ VAD: ScriptProcessorNode → RMS dBFS → {"type":"vad","db":-28.3}
        │
        │  WebSocket /ws/stream?source=en&target=es&voice_id=...
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
        └─ TTS routing, in priority order:
                1. Chatterbox Multilingual: if session has a registered voice_id
                       └─ POST /api/voice/upload registered this voice earlier
                       └─ falls back to step 2/3 if cloning fails or language unsupported
                2. Piper: for Korean and German (Kokoro doesn't cover these)
                3. Kokoro-82M ONNX + eSpeak NG phonemizer: all other languages
                └─ raw int16 PCM chunks → websocket.send_bytes() → Web Audio API → speaker
```

### Why Raw Float32 PCM?

Early versions sent WebM/Opus container chunks via `MediaRecorder`. Individual WebM chunks cannot be decoded in isolation; they depend on codec headers that only exist in the first chunk, so server-side energy measurement always failed.

The current pipeline bypasses containers entirely. The browser's `ScriptProcessorNode` extracts raw float32 PCM directly from the microphone hardware track and sends it over the WebSocket. The server reconstructs the audio array with `np.frombuffer(data, dtype=np.float32)`, with no decoder, no file parsing, minimal latency.

---

## Supported Languages

| Language | STT Code | TTS Engine | Notes |
|---|---|---|---|
| English | `en` | Kokoro (`en-us`, `af_heart`) | |
| Spanish | `es` | Kokoro (`es`, `ef_dora`) | |
| French | `fr` | Kokoro (`fr-fr`, `ff_siwis`) | Requires eSpeak NG |
| Italian | `it` | Kokoro (`it`, `if_sara`) | Requires eSpeak NG |
| Japanese | `ja` | Kokoro (`ja`, `jf_alpha`) | Requires eSpeak NG |
| Chinese | `zh` | Kokoro (`cmn`, `zf_xiaobei`) | espeak lang code is `cmn`, not `zh` |
| Hindi | `hi` | Kokoro (`hi`, `hf_alpha`) | Requires eSpeak NG |
| Portuguese | `pt` | Kokoro (`pt-br`, `pf_dora`) | Requires eSpeak NG |
| Korean | `ko` | Piper (`piper-kss-korean`) | Voice model downloaded separately; see Piper section below |
| German | `de` | Piper (`de_DE-thorsten-high`) | Voice model downloaded separately; see Piper section below |
| Telugu | `te` | None | STT + translation only; no preset TTS engine supports it |

Voice cloning (Chatterbox Multilingual) covers a separate, broader language list; see the Voice Cloning section below. It supports German and Korean natively without Piper, but does not support Telugu either.

---

## VRAM Budget (RTX 3070 Ti, 8 GB)

| Component | VRAM |
|---|---|
| faster-whisper base (int8) | ~350 MB |
| Kokoro-82M (ONNX) | ~250 MB |
| Piper (Korean + German voices, CPU-only) | ~0 MB GPU |
| Ollama llama3.2 (3B, Q4) | ~2.0 GB |
| Chatterbox Multilingual (voice cloning, optional) | ~2-3 GB |
| OS / display / overhead | ~0.6 GB |
| **Total without voice cloning** | **~3.2 GB** ✅ |
| **Total with voice cloning enabled** | **~5.2-6.2 GB** ✅ |

Piper runs on CPU (`use_cuda=False`) by design; it's lightweight enough that GPU acceleration isn't worth the added complexity. Chatterbox is the only optional component; if `chatterbox-tts` fails to install or load, the server logs a warning and continues running with preset voices only, using no additional VRAM.

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
| Voice sample storage | `server.py` → `VOICE_SAMPLES_DIR` | `./voice_samples/` |
| Voice cloning recording length | `index.html` → `VOICE_SAMPLE_MS` | 15000 ms |
| Voice cloning cfg_weight | `server.py` → `_synthesise_chatterbox()` | 0.3 |
| Voice cloning exaggeration | `server.py` → `_synthesise_chatterbox()` | 0.5 |
| Max voice sample upload size | `server.py` → `MAX_VOICE_SAMPLE_BYTES` | 15 MB |

The silence threshold can be adjusted live via the slider in the browser UI without restarting. Each WebSocket session maintains its own threshold.

---

## WebSocket Message Protocol

### Connection

```
ws://localhost:8000/ws/stream?source=en&target=es&voice_id=abc123def456
```

`source` and `target` are required (default to `en`/`es` if omitted). `voice_id` is optional: pass a registered voice profile id (from `POST /api/voice/upload`) to use a cloned voice for this session's TTS output. Omit it to use the standard preset voice pipeline.

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
| Text JSON | `{"type":"tts_config","sample_rate":22050}` | Sent before non-Kokoro TTS chunks (Piper is 22050 Hz, Chatterbox varies) so the client can recreate its AudioContext at the correct rate |
| Binary | Raw int16 PCM @ variable sample rate | TTS audio chunk; the rate depends on engine (Kokoro 24kHz, Piper 22050Hz, Chatterbox varies) |

### Voice Profile Management (REST)

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/voice/upload` | Upload a `multipart/form-data` audio file (`file` field). Converts WebM→WAV server-side, registers a voice profile, returns `{"voice_id": "...", "status": "registered"}` |
| `DELETE` | `/api/voice/{voice_id}` | Removes a voice profile and deletes its WAV file from disk |
| `GET` | `/api/voice/status` | Returns `{"available": bool, "active_profiles": int, "supported_languages": [...]}` (used by the client to decide whether to show the voice cloning UI at all) |

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

## Piper TTS (Korean, German)

Kokoro doesn't have voices for Korean or German. Piper fills this gap with two separately-downloaded voice models that load on CPU (`use_cuda=False`; these models are lightweight enough that GPU acceleration isn't worth the complexity):

```python
PIPER_VOICE_FILES = {
    "ko": ("piper_voices/piper-kss-korean.onnx", "piper_voices/piper-kss-korean.onnx.json"),
    "de": ("piper_voices/de_DE-thorsten-high.onnx", "piper_voices/de_DE-thorsten-high.onnx.json"),
}
```

If these files aren't present at startup, the server logs a warning and that language falls back to subtitles-only; translation still works, there's just no audio output.

A known quirk: Piper's `synthesize()` writes raw audio into a `wave.Wave_write` object that must have its format explicitly configured first (`setnchannels`, `setsampwidth`, `setframerate`) before the call; Piper doesn't set this itself, and omitting it throws `# channels not specified`.

Piper outputs at 22050 Hz, different from Kokoro's 24000 Hz. The server sends a `tts_config` message with the actual sample rate before streaming Piper audio, and the client recreates its `AudioContext` at that rate to avoid pitch/speed distortion.

---

## Voice Cloning (Chatterbox Multilingual)

Voice cloning is an optional layer on top of the preset-voice pipeline. It lets a user record a short reference clip of their own voice and have translated speech played back in that voice instead of a generic preset.

### Loading

`ChatterboxMultilingualTTS` loads once at startup via the lifespan handler, same pattern as Whisper and Kokoro:

```python
chatterbox_model = ChatterboxMultilingualTTS.from_pretrained(device="cuda")
```

If `chatterbox-tts` isn't installed, or CUDA loading fails (falls back to CPU with a warning), or the import fails entirely, `chatterbox_model` stays `None` and the feature is cleanly disabled: `GET /api/voice/status` reports `available: false`, and the client hides the recording UI.

### Voice profile lifecycle

1. Client records ~15 seconds of audio via `MediaRecorder` (WebM/Opus, same as the original STT pipeline used before the raw-PCM rewrite)
2. `POST /api/voice/upload` receives the blob, saves it temporarily, then converts it to WAV
3. The WAV conversion tries `torchaudio.load()` first; if that fails (its ffmpeg backend detection is unreliable on Windows even with ffmpeg on PATH), it falls back to `soundfile`, which has broader native codec support via libsndfile
4. The converted WAV is stored in `voice_samples/{voice_id}.wav` and registered in the in-memory `voice_profiles` dict
5. The client passes `voice_id` as a WebSocket query param on the next session: `SessionState.voice_id` carries it through to `synthesise_and_stream`

### Synthesis routing

`synthesise_and_stream` checks for a registered voice_id **before** falling through to Piper or Kokoro:

```python
if session_voice_id and session_voice_id in voice_profiles:
    await _synthesise_chatterbox(translated_text, target_lang, websocket, loop, session_voice_id)
    return
```

`_synthesise_chatterbox` calls `chatterbox_model.generate()` with the user's reference WAV as `audio_prompt_path`:

```python
wav_tensor = chatterbox_model.generate(
    text,
    language_id=target_lang,
    audio_prompt_path=ref_path,
    cfg_weight=0.3,
    exaggeration=0.5,
)
```

`cfg_weight=0.3` (rather than the library default of 0.5) is intentional: Resemble AI's own guidance notes that low `cfg_weight` reduces the cloned voice inheriting an accent from the reference clip's language when the target language differs from the reference. Since users will commonly record in one language and translate to several others, this tradeoff favors more language-faithful output over slightly weaker voice similarity.

### Fallback behavior

Any failure in the cloning path (missing model, missing reference file, unsupported target language, or a runtime exception during generation) routes to `_synthesise_chatterbox_fallback`, which re-runs the same Piper/Kokoro logic as the normal pipeline. Translation never silently fails because of a voice cloning issue; worst case, the user hears a preset voice instead of their cloned one.

### Supported languages

Chatterbox Multilingual supports a different (and broader) language set than Kokoro/Piper combined:

```python
CHATTERBOX_LANGUAGES = {
    "ar", "da", "de", "el", "en", "es", "fi", "fr", "he", "hi", "it",
    "ja", "ko", "ms", "nl", "no", "pl", "pt", "ru", "sv", "sw", "tr", "zh",
}
```

Notably this includes German and Korean natively, without needing Piper. Telugu is not supported by Chatterbox either; there's currently no TTS engine in Bridge that covers it.

### Watermarking

Every Chatterbox output includes Resemble AI's PerTh (Perceptual Threshold) watermark: an inaudible signal embedded in the generated audio that survives compression and basic editing, used to verify the audio was AI-generated if ever needed. This is not configurable and not a privacy concern for Bridge's use case (live, in-the-moment conversational translation, not pre-recorded content distribution).

---

## Concurrency Model

Bridge uses Python's `asyncio` for concurrency: a single thread, single event loop. CPU-bound work (Whisper inference, audio decode) runs in a thread pool via `run_in_executor`. The Ollama HTTP call is natively async via `httpx.AsyncClient`.

A per-session `processing_lock` prevents race conditions when two silence triggers fire close together:

```python
async def process_utterance():
    if processing_lock.locked():
        return  # drop duplicate trigger
    async with processing_lock:
        raw = state.get_buffer_bytes()
        state.flush_buffer()
```

Each WebSocket connection gets its own `SessionState`: isolated audio buffer, VAD state, language pair, silence threshold, and optional voice_id for cloned-voice playback. Multiple devices can connect simultaneously and each runs an independent pipeline.

---

## 🚀 Setup & Machine Installation

This section details how to replicate and run the Bridge server on a new machine or fresh environment.

### Automated Installer (Recommended)

Bridge includes an automated installer that handles the entire multi-step setup (PyTorch CUDA 12.4, Chatterbox voice cloning, numba/numpy overrides, and model weight downloads) in a single command:

```powershell
.\setup.ps1
```
*(or run `.\setup.bat` from CMD, or `.\technical-setup\setup.ps1`)*

### Prerequisites

- **Python 3.12** (managed via `uv`)
- **NVIDIA GPU** with CUDA 12.x drivers (tested on RTX 3070 Ti, 8 GB VRAM)
- **[Ollama](https://ollama.com)** installed locally
- **[eSpeak NG](https://github.com/espeak-ng/espeak-ng/releases/latest)** installed (required for non-English Kokoro voice output)
- **Node.js & npm** (optional, for remote tunnel via `winget install OpenJS.NodeJS`)

> **Voice cloning note:** Voice cloning is optional and loads automatically if `chatterbox-tts` installs successfully. It adds roughly 2-3 GB VRAM on top of the base stack. If it fails to load, Bridge logs a warning and falls back to preset voices; nothing else breaks.

### Manual Step-by-Step Installation

If you prefer to configure the environment manually or need to debug individual packages:

```powershell
# 1. Create and activate virtual environment
uv venv .venv --python 3.12
.\.venv\Scripts\Activate.ps1

# 2. Base dependencies
uv pip install -r requirements.txt

# 3. PyTorch with CUDA 12.4
uv pip install --reinstall torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0 --index-url https://download.pytorch.org/whl/cu124

# 4. Chatterbox Multilingual TTS & dependencies (without dependency conflicts)
uv pip install "chatterbox-tts>=0.1.4" --no-deps
uv pip install "llvmlite>=0.43.0" "numba>=0.60.0" "librosa>=0.10.0" "resemble-perth" --no-deps
uv pip install conformer diffusers einops rotary-embedding-torch encodec vector-quantize-pytorch

# 5. Apply numpy override for numba compatibility
uv pip install -r overrides.txt

# 6. Fetch model assets
python scripts/download_models.py

# 7. Pull Ollama translation model
ollama pull llama3.2
```

---

## ⚡ Running Bridge

### Option A: One-click local launch

```powershell
.\start.ps1
```

Opens Ollama in a separate terminal, waits until it actually responds on `localhost:11434`, then activates the environment and starts the server. (On a cold start Ollama can take a while; the script polls for up to ~30 seconds before stopping with a clear error.)

### Option B: Remote access via tunnel

Browsers block microphone access over plain HTTP. To share Bridge with a remote user over the web:

```powershell
# Start the server
.\.venv\Scripts\Activate.ps1
python server.py

# Open the tunnel
.\run_bridge.ps1
```

This exposes a secure public endpoint (e.g. `https://bridge.loca.lt`) so anyone can connect directly to your local GPU pipeline from their mobile device or desktop browser.

> For safety, Bridge only accepts WebSocket connections whose Origin matches the Host they were opened against, so a random web page can't drive your GPU from another site. If you expose Bridge through a custom proxy that rewrites the Host header, add the extra origin to the `BRIDGE_ALLOWED_ORIGINS` environment variable (comma-separated).

### Option C: Manual launch

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

If translation doesn't trigger after you stop speaking, your background noise floor may be above the VAD threshold. Watch the **Mic Level** bar while silent; it should sit below the marker line. Drag the **Silence threshold** slider right until the resting noise level falls below the marker.

| Environment | Suggested threshold |
|---|---|
| Quiet room | -40 to -35 dBFS |
| Normal office | -32 to -28 dBFS |
| Noisy environment | -25 to -20 dBFS |

---

## 📁 Repository Structure

| Path | Purpose |
|---|---|
| `server.py` | FastAPI backend: WebSocket, Whisper STT, Ollama translation, Kokoro/Piper/Chatterbox TTS |
| `index.html` | Browser client: mic capture, VAD, subtitle display, audio playback |
| `setup.ps1` / `setup.bat` | Automated 1-click environment installer and model downloader |
| `start.ps1` | One-click local launch: boots Ollama, waits for it, starts the server |
| `run_bridge.ps1` | Standalone public-tunnel launcher (thin wrapper on `bridge-remote.ps1`) |
| `bridge-remote.ps1` | Remote control: start / stop / status / logs / shutdown the stack from your phone |
| `bridge.cmd` | Short entry point: with the folder on your `PATH`, type `bridge start` / `bridge stop` |
| `setup-remote-access.ps1` | One-time elevated setup: Tailscale, OpenSSH Server, phone SSH key, `BridgeStack` task |
| `restart-tailscale.ps1` | Recovery helper: a Tailscale backend stuck in `NoState` |
| `diagnose-ssh-firewall.ps1` | Troubleshooting report for SSH-over-Tailscale connectivity |
| `requirements.txt` | Python dependencies |
| `overrides.txt` | Dependency constraints (pins `numpy>=2.0.2,<3` for numba compatibility) |
| `scripts/download_models.py` | Automated model downloader for Kokoro ONNX and Piper voice files |
| `technical-setup/` | Technical setup guides, architecture reference, and installer scripts |
| `voice_samples/` | Locally recorded voice cloning reference clips (gitignored, swept at startup/shutdown) |
| `piper_voices/` | Optional Piper TTS voices: German Thorsten and optional Korean KSS |

**Documentation in `technical-setup/`:**

| Doc | Purpose |
|---|---|
| [`technical-setup/README.md`](README.md) | Full architecture and technical reference |
| [`technical-setup/REMOTE_ACCESS.md`](REMOTE_ACCESS.md) | Phone-control walkthrough: setup, one-tap snippets, security, troubleshooting |
| [`technical-setup/bridge-troubleshooting-guide.md`](bridge-troubleshooting-guide.md) | Install and setup problems, with the verified clean-install sequence |

---

## 🔒 What is and isn't public

This repo is public, so it is worth being explicit about what lives in it, and more importantly, what does not.

**Everything tracked here is meant to be public.** That is the source: `server.py`, `index.html`, the `.ps1` / `.cmd` launchers, the docs, and the CI config. The PowerShell scripts are *product*, not secrets. `bridge-remote.ps1` and `setup-remote-access.ps1` are the entire remote-control feature, and hiding them would give every other user a repo with no phone control.

**What is never committed**, and where it actually lives instead:

| Item | Real Location |
|---|---|
| Your SSH private key | `~\.ssh\`: outside this folder, and pattern-ignored in case it isn't |
| The public half of that key | `C:\ProgramData\ssh\administrators_authorized_keys`, ACL-locked to SYSTEM + Administrators |
| Your Windows account password | Task Scheduler's LSA secret store: read at runtime by `Get-Credential`, never written to a file |
| Model weights & voice files | `*.onnx`, `*.bin`, `voices.json`, `piper_voices/` |
| Your recorded voice clips | `voice_samples/`: deleted from disk at shutdown |
| Logs, tunnel URL, your IPs | `remote_logs/` |
| `.env` files and API keys | `.env.*` (a `.env.example` with blanks is welcome) |

**The rule to keep:** ignore *personal* scripts, track *shared* ones. `run_bridge.ps1` is a local convenience launcher and is gitignored; `bridge-remote.ps1` is part of the project and is tracked. If you ever write a script that genuinely embeds a secret, ignore **that one file by name** (never `*.ps1`), or better, read the secret from an ignored `.env.local` at runtime.

---

## Troubleshooting

### No voice output for non-English languages
Install eSpeak NG from https://github.com/espeak-ng/espeak-ng/releases/latest (`.msi` for Windows), then restart the server. The server sets the required env vars automatically; no manual configuration needed.

### Chinese TTS not working
The espeak lang code for Mandarin is `cmn`, not `zh`. This is already handled in `KOKORO_LANG_MAP` but worth knowing if you're debugging phonemizer errors directly.

### Piper synthesis fails with "# channels not specified"
Piper's `synthesize()` requires the output WAV file to have its format set first via `setnchannels`/`setsampwidth`/`setframerate`; it doesn't configure this itself. Already handled in `_synthesise_piper()`; if you're extending Piper to a new language, make sure any new synthesis call sets these before calling `voice.synthesize()`.

### Voice cloning loads on CPU instead of CUDA
Check that your installed `torch` build matches your CUDA version. `chatterbox-tts` pulls in PyTorch as a dependency, which can sometimes resolve to a CPU-only wheel depending on your pip/uv resolution order. Reinstalling with an explicit CUDA index URL usually fixes this:
```powershell
uv pip install --reinstall torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0 --index-url https://download.pytorch.org/whl/cu124
```

### Voice upload returns 500 "Could not process the audio sample"
The WebM→WAV conversion failed in both `torchaudio` and the `soundfile` fallback. Usually means the recording was empty, corrupted, or your system is missing ffmpeg. Try recording again; if it persists, check that ffmpeg is on PATH.

### Cloned voice doesn't sound like the target language's native accent
Expected behavior per Chatterbox's own documentation. If the reference clip's language differs from the target translation language, the output can inherit the reference's accent. `cfg_weight=0.3` mitigates this but doesn't eliminate it. For best fidelity, record the reference sample in your most commonly used target language.

### "Ollama not reachable at localhost:11434"
Run `ollama serve` in a separate terminal before starting the server, or use `.\start.ps1` which starts Ollama automatically.

### "llama3.2 not found"
Run `ollama pull llama3.2`.

### CUDA not detected for Whisper
```powershell
pip install ctranslate2 --force-reinstall --index-url https://download.pytorch.org/whl/cu121
```

### Translation never triggers
Background noise floor is above the silence threshold. Watch the Mic Level bar while silent; it should sit below the marker. Drag the Silence threshold slider right until it does.

### "The term '.\run_bridge.ps1' is not recognized"
Run this first to allow local script execution:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
```
