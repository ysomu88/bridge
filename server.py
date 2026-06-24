"""
Bridge — Real-Time Voice-to-Voice Translation Server
FastAPI + faster-whisper + Ollama + Kokoro-82M
Target: RTX 3070 Ti (8GB VRAM), Windows 11, uv package manager
"""

import asyncio
import io
import json
import logging
import time
import uuid
from contextlib import asynccontextmanager
from typing import Optional

import httpx
import numpy as np
import soundfile as sf
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
from faster_whisper import WhisperModel

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("bridge")

# ---------------------------------------------------------------------------
# Global model references (loaded once at startup via lifespan)
# ---------------------------------------------------------------------------
whisper_model: Optional[WhisperModel] = None
kokoro_pipeline = None


# ---------------------------------------------------------------------------
# Lifespan: load / unload models
# ---------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    global whisper_model, kokoro_pipeline

    # ── Whisper (STT) ──────────────────────────────────────────────────────
    logger.info("Loading faster-whisper 'base' model on CUDA (int8)…")
    try:
        whisper_model = WhisperModel(
            "base",
            device="cuda",
            compute_type="int8",
        )
        logger.info("✅ Whisper model loaded on CUDA.")
    except Exception as exc:
        logger.warning(f"CUDA unavailable for Whisper ({exc}). Falling back to CPU.")
        whisper_model = WhisperModel("base", device="cpu", compute_type="int8")
        logger.info("✅ Whisper model loaded on CPU.")

    # ── Kokoro TTS ─────────────────────────────────────────────────────────
    try:
        from kokoro_onnx import Kokoro  # type: ignore

        logger.info("Initializing Kokoro-82M ONNX wrapper...")
        # kokoro-onnx downloads model.onnx and voices.json automatically on first run
        kokoro_pipeline = Kokoro("model.onnx", "voices.json")
        logger.info("✅ Kokoro TTS pipeline ready (Spanish).")
    except ImportError:
        logger.warning("kokoro-onnx not installed — TTS disabled. Run: uv pip install kokoro-onnx")
        kokoro_pipeline = None
    except Exception as exc:
        logger.error(f"Kokoro init failed: {exc}")
        logger.info("TTS disabled — fix the error above and restart to enable audio output.")
        kokoro_pipeline = None

    # ── Ollama connectivity check ───────────────────────────────────────────
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get("http://localhost:11434/api/tags")
            models = [m["name"] for m in resp.json().get("models", [])]
            if not any("llama3.2" in m for m in models):
                logger.warning(
                    "⚠️  llama3.2 not found in Ollama. Run: ollama pull llama3.2"
                )
            else:
                logger.info("✅ Ollama reachable, llama3.2 available.")
    except Exception:
        logger.warning("⚠️  Ollama not reachable at localhost:11434 — start it with: ollama serve")

    yield  # ── app runs ──

    # ── Cleanup ────────────────────────────────────────────────────────────
    logger.info("Shutting down — releasing model resources.")
    whisper_model = None
    kokoro_pipeline = None


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------
app = FastAPI(title="Bridge", lifespan=lifespan)


# ---------------------------------------------------------------------------
# VAD configuration (tunable without restarting)
# ---------------------------------------------------------------------------
# How it works: the browser sends raw PCM energy alongside every WebM chunk
# (see index.html). The server uses that energy value for silence detection,
# which sidesteps the WebM-chunk-decoding problem entirely.
#
# If you're getting false triggers from background noise, raise this value.
# Typical speech is around -20 to -10 dBFS. A quiet room idles at -50 to -40.
VAD_SILENCE_DB: float = -30.0       # dBFS below which we call it silence
VAD_SILENCE_DURATION_S: float = 0.8 # seconds of silence before triggering
VAD_MIN_SPEECH_S: float = 0.3       # ignore utterances shorter than this


# ---------------------------------------------------------------------------
# Per-session state
# ---------------------------------------------------------------------------
class SessionState:
    """Audio accumulation and VAD tracking for one WebSocket session."""

    CHUNK_SR: int = 16_000

    def __init__(self, session_id: str):
        self.session_id = session_id
        self.audio_buffer = io.BytesIO()
        self.has_voice: bool = False
        self.speech_start: Optional[float] = None
        self.silence_start: Optional[float] = None

    def append_chunk(self, data: bytes) -> None:
        self.audio_buffer.write(data)

    def get_buffer_bytes(self) -> bytes:
        return self.audio_buffer.getvalue()

    def flush_buffer(self) -> None:
        self.audio_buffer = io.BytesIO()
        self.has_voice = False
        self.speech_start = None
        self.silence_start = None

    def speech_duration_s(self) -> float:
        if self.speech_start is None:
            return 0.0
        return time.monotonic() - self.speech_start


# ---------------------------------------------------------------------------
# Audio helpers
# ---------------------------------------------------------------------------
def webm_bytes_to_float32(raw_bytes: bytes, target_sr: int = 16_000) -> Optional[np.ndarray]:
    """
    Decode a complete WebM/Opus (or OGG/Opus) buffer → numpy float32 mono @ target_sr.
    Uses PyAV (FFmpeg) which handles any browser audio container on Windows.
    Falls back to soundfile if PyAV is unavailable.
    Returns None if decoding fails or audio is too short.
    """
    # Log the first 4 bytes so we can see the container format magic bytes
    magic = raw_bytes[:4].hex() if len(raw_bytes) >= 4 else "??"
    logger.debug(f"Audio buffer magic bytes: {magic} (1a45dfa3=WebM, 4f676753=OGG)")

    # ── Try PyAV first (FFmpeg-backed, handles WebM/Opus on Windows) ──────
    try:
        import av  # type: ignore
        buf = io.BytesIO(raw_bytes)
        container = av.open(buf, format=None)  # let FFmpeg auto-detect format
        frames = []
        for frame in container.decode(audio=0):
            frames.append(frame.to_ndarray())
        if not frames:
            logger.warning("PyAV decoded 0 frames")
            return None
        audio = np.concatenate(frames, axis=-1).mean(axis=0).astype(np.float32)
        sr = container.streams.audio[0].codec_context.sample_rate
        container.close()

        if sr != target_sr:
            ratio = target_sr / sr
            new_len = int(len(audio) * ratio)
            audio = np.interp(
                np.linspace(0, len(audio) - 1, new_len),
                np.arange(len(audio)),
                audio,
            )

        min_samples = int(VAD_MIN_SPEECH_S * target_sr)
        if len(audio) < min_samples:
            logger.debug(f"Audio too short: {len(audio)} samples < {min_samples} minimum")
            return None

        logger.debug(f"PyAV decoded {len(audio)/target_sr:.2f}s of audio at {sr}Hz")
        return audio.astype(np.float32)

    except ImportError:
        logger.debug("PyAV not available, falling back to soundfile")
    except Exception as exc:
        logger.warning(f"PyAV decode failed: {exc} — falling back to soundfile")

    # ── Fallback: soundfile (works if libsndfile has WebM support) ────────
    try:
        buf = io.BytesIO(raw_bytes)
        audio, sr = sf.read(buf, dtype="float32", always_2d=False)

        if audio.ndim == 2:
            audio = audio.mean(axis=1)

        if sr != target_sr:
            ratio = target_sr / sr
            new_len = int(len(audio) * ratio)
            audio = np.interp(
                np.linspace(0, len(audio) - 1, new_len),
                np.arange(len(audio)),
                audio,
            )

        min_samples = int(VAD_MIN_SPEECH_S * target_sr)
        if len(audio) < min_samples:
            return None

        return audio.astype(np.float32)
    except Exception as exc:
        logger.warning(f"soundfile decode also failed: {exc}")
        return None




# ---------------------------------------------------------------------------
# Transcription
# ---------------------------------------------------------------------------
async def transcribe(audio: np.ndarray) -> str:
    """Run faster-whisper in a thread pool so we don't block the event loop."""
    if whisper_model is None:
        return ""

    loop = asyncio.get_running_loop()

    def _run() -> str:
        segments, _ = whisper_model.transcribe(
            audio,
            language="en",
            beam_size=5,
            vad_filter=True,
            vad_parameters={
                "min_silence_duration_ms": 500,
                "threshold": 0.5,
            },
        )
        return " ".join(seg.text.strip() for seg in segments).strip()

    text = await loop.run_in_executor(None, _run)
    logger.info(f"📝 Transcript: {text!r}")
    return text


# ---------------------------------------------------------------------------
# Translation via Ollama
# ---------------------------------------------------------------------------
OLLAMA_URL = "http://localhost:11434/api/chat"
OLLAMA_MODEL = "llama3.2"
TRANSLATION_SYSTEM_PROMPT = (
    "You are a silent, professional real-time translator. "
    "The user sends English text. "
    "You reply ONLY with the Spanish translation — no preamble, no explanations, "
    "no markdown, no extra punctuation beyond what the original contains. "
    "One translation per message. Nothing else."
)


async def translate_to_spanish(english_text: str) -> str:
    """Send text to local Ollama and return Spanish translation."""
    if not english_text.strip():
        return ""

    payload = {
        "model": OLLAMA_MODEL,
        "stream": False,
        "messages": [
            {"role": "system", "content": TRANSLATION_SYSTEM_PROMPT},
            {"role": "user", "content": english_text},
        ],
    }

    try:
        async with httpx.AsyncClient(timeout=20.0) as client:
            resp = await client.post(OLLAMA_URL, json=payload)
            if resp.status_code == 404:
                logger.error(
                    f"Ollama model '{OLLAMA_MODEL}' not found. "
                    f"Run: ollama pull {OLLAMA_MODEL}"
                )
                return ""
            resp.raise_for_status()
            translation = resp.json()["message"]["content"].strip()
            logger.info(f"🌐 Translation: {translation!r}")
            return translation
    except httpx.ConnectError:
        logger.error("Ollama not reachable at localhost:11434 — is it running?")
        return ""
    except Exception as exc:
        logger.error(f"Translation error: {exc}")
        return ""


# ---------------------------------------------------------------------------
# TTS via Kokoro-82M
# ---------------------------------------------------------------------------
async def synthesise_and_stream(
    text: str,
    websocket: WebSocket,
    english_text: str,
) -> None:
    """Synthesise Spanish text and stream PCM bytes back to client."""
    if not text:
        return

    # Push subtitle update first so the UI updates immediately
    try:
        await websocket.send_text(
            json.dumps({"type": "subtitle", "en": english_text, "es": text})
        )
    except Exception:
        return

    if kokoro_pipeline is None:
        logger.warning("Kokoro not available — skipping TTS.")
        return

    loop = asyncio.get_running_loop()

    def _generate_chunks():
        try:
            stream = kokoro_pipeline.create(text, voice="af_bella", speed=1.0, lang="es")
            for samples, sample_rate in stream:
                yield samples
        except Exception as exc:
            logger.error(f"Kokoro voice synthesis error: {exc}")
            logger.info(
                "If the error mentions a missing voice, check that 'af_bella' exists "
                "in voices.json. Available voices vary by kokoro-onnx version."
            )

    try:
        chunks = await loop.run_in_executor(None, lambda: list(_generate_chunks()))
    except Exception as exc:
        logger.error(f"Kokoro executor error: {exc}")
        return

    for audio_array in chunks:
        if audio_array is None or len(audio_array) == 0:
            continue
        pcm_int16 = (np.clip(audio_array, -1.0, 1.0) * 32767).astype(np.int16)
        try:
            await websocket.send_bytes(pcm_int16.tobytes())
        except Exception:
            logger.warning("WebSocket closed during TTS streaming.")
            return

    logger.info("🔊 TTS stream complete.")


# ---------------------------------------------------------------------------
# WebSocket endpoint
# ---------------------------------------------------------------------------
@app.websocket("/ws/stream")
async def ws_stream(websocket: WebSocket):
    await websocket.accept()
    session_id = str(uuid.uuid4())[:8]
    state = SessionState(session_id)
    logger.info(f"[{session_id}] Client connected.")

    # Lock ensures only one transcription pipeline runs at a time per session,
    # preventing double-processing if two silence triggers fire close together.
    processing_lock = asyncio.Lock()

    async def process_utterance():
        if processing_lock.locked():
            logger.debug(f"[{session_id}] Pipeline busy — skipping duplicate trigger.")
            return
        async with processing_lock:
            raw = state.get_buffer_bytes()
            state.flush_buffer()

        if not raw:
            return

        loop = asyncio.get_running_loop()
        logger.info(f"[{session_id}] 🔄 Decoding {len(raw)} bytes of audio...")
        audio = await loop.run_in_executor(None, webm_bytes_to_float32, raw)
        if audio is None:
            logger.warning(f"[{session_id}] ⚠️  Audio decode returned None — buffer too short or corrupt. ({len(raw)} bytes)")
            return

        logger.info(f"[{session_id}] 🔄 Transcribing {len(audio)/16000:.1f}s of audio...")
        english = await transcribe(audio)
        if not english:
            logger.warning(f"[{session_id}] ⚠️  Whisper returned empty transcript — was the audio too quiet or noisy?")
            return

        logger.info(f"[{session_id}] 🔄 Translating: {english!r}")
        spanish = await translate_to_spanish(english)
        if not spanish:
            logger.warning(f"[{session_id}] ⚠️  Translation returned empty — check Ollama is running and llama3.2 is pulled.")
            return

        await synthesise_and_stream(spanish, websocket, english)

    # ── Main receive loop ──────────────────────────────────────────────────
    # VAD strategy: the browser computes RMS dBFS for each 100ms chunk and
    # sends it as a JSON "vad" message alongside the binary audio chunks.
    # This sidesteps the problem of trying to decode individual WebM chunks
    # on the server (WebM requires the full container header to decode).
    # Per-session silence threshold — can be updated by the client at runtime
    vad_silence_db: float = VAD_SILENCE_DB

    try:
        while True:
            message = await websocket.receive()

            # Starlette sends a disconnect dict instead of raising WebSocketDisconnect
            # when using the raw receive() method. Check for it explicitly.
            if message.get("type") == "websocket.disconnect":
                raise WebSocketDisconnect(code=message.get("code", 1000))

            # ── Binary audio chunk ─────────────────────────────────────
            if "bytes" in message and message["bytes"]:
                state.append_chunk(message["bytes"])

            # ── VAD energy report from browser ─────────────────────────
            elif "text" in message and message["text"]:
                try:
                    msg = json.loads(message["text"])
                except json.JSONDecodeError:
                    continue

                msg_type = msg.get("type")

                # Allow the client to update the silence threshold at runtime
                if msg_type == "set_threshold":
                    new_db = float(msg.get("db", VAD_SILENCE_DB))
                    vad_silence_db = max(-60.0, min(-10.0, new_db))
                    logger.info(f"[{session_id}] Silence threshold updated to {vad_silence_db:.1f} dBFS")
                    continue

                if msg_type != "vad":
                    continue

                db: float = msg.get("db", -99.0)
                now = time.monotonic()
                is_speech = db > vad_silence_db

                logger.debug(f"[{session_id}] VAD {db:.1f} dBFS {'🗣' if is_speech else '🔇'}")

                # Send live dB back to the client so the UI meter is accurate
                try:
                    await websocket.send_text(json.dumps({"type": "vad_echo", "db": db}))
                except Exception:
                    pass

                if is_speech:
                    if not state.has_voice:
                        logger.info(f"[{session_id}] 🗣  Voice detected ({db:.1f} dBFS)")
                        state.speech_start = now
                    state.has_voice = True
                    state.silence_start = None
                else:
                    if state.has_voice:
                        if state.silence_start is None:
                            state.silence_start = now

                        silent_for = now - state.silence_start
                        if silent_for >= VAD_SILENCE_DURATION_S:
                            speech_dur = state.speech_duration_s()
                            logger.info(
                                f"[{session_id}] 🔇 {VAD_SILENCE_DURATION_S*1000:.0f} ms silence "
                                f"after {speech_dur:.1f}s of speech — processing."
                            )
                            state.has_voice = False
                            state.silence_start = None
                            asyncio.create_task(process_utterance())

    except (WebSocketDisconnect, RuntimeError) as exc:
        if isinstance(exc, RuntimeError) and "disconnect" not in str(exc).lower():
            logger.error(f"[{session_id}] Unexpected error: {exc}", exc_info=True)
        else:
            logger.info(f"[{session_id}] Client disconnected.")
        if state.has_voice and len(state.get_buffer_bytes()) > 0:
            logger.info(f"[{session_id}] Processing final utterance on disconnect.")
            asyncio.create_task(process_utterance())
        else:
            state.flush_buffer()
    except Exception as exc:
        logger.error(f"[{session_id}] Unexpected error: {exc}", exc_info=True)
        state.flush_buffer()
    finally:
        logger.info(f"[{session_id}] Session closed.")


# ---------------------------------------------------------------------------
# Serve the frontend
# ---------------------------------------------------------------------------
@app.get("/", response_class=HTMLResponse)
async def root():
    try:
        with open("index.html", "r", encoding="utf-8") as f:
            return HTMLResponse(content=f.read())
    except FileNotFoundError:
        return HTMLResponse(content="<h1>index.html not found</h1>", status_code=404)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    uvicorn.run(
        "server:app",
        host="0.0.0.0",
        port=8000,
        reload=False,
        ws_ping_interval=20,
        ws_ping_timeout=30,
        log_level="info",
    )