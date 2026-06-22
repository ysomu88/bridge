"""
Bridge — Real-Time Voice-to-Voice Translation Server
FastAPI + faster-whisper + Ollama + Kokoro-82M
Target: RTX 3070 Ti (8GB VRAM), Windows 11, uv package manager
"""

import asyncio
import io
import logging
import struct
import time
import uuid
from collections import deque
from contextlib import asynccontextmanager
from typing import Optional

import httpx
import numpy as np
import soundfile as sf
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
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
kokoro_pipeline = None  # KPipeline — loaded if kokoro is available


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
            compute_type="int8",  # <1 GB VRAM footprint
        )
        logger.info("✅ Whisper model loaded on CUDA.")
    except Exception as exc:
        logger.warning(f"CUDA unavailable for Whisper ({exc}). Falling back to CPU.")
        whisper_model = WhisperModel("base", device="cpu", compute_type="int8")
        logger.info("✅ Whisper model loaded on CPU.")

    # ── Kokoro TTS ─────────────────────────────────────────────────────────
    try:
        from kokoro import KPipeline  # type: ignore

        logger.info("Loading Kokoro-82M TTS pipeline (Spanish)…")
        kokoro_pipeline = KPipeline(lang_code="s")  # 's' = Spanish
        logger.info("✅ Kokoro TTS pipeline ready.")
    except ImportError:
        logger.warning(
            "kokoro library not found — TTS will be skipped. "
            "Install with: uv add kokoro-onnx"
        )
        kokoro_pipeline = None
    except Exception as exc:
        logger.error(f"Kokoro init failed: {exc}")
        kokoro_pipeline = None

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
# Per-session state
# ---------------------------------------------------------------------------
class SessionState:
    """
    Tracks audio accumulation and silence detection for a single WebSocket session.
    Uses a rolling deque of raw audio bytes + a simple energy-based silence detector.
    Silero VAD is exercised through faster-whisper's built-in vad_filter param.
    """

    SILENCE_THRESHOLD_DB: float = -40.0   # dBFS below which we call it silence
    SILENCE_DURATION_S: float = 0.50      # 500 ms of silence triggers processing
    CHUNK_SR: int = 16_000                # expected sample rate after resampling
    MIN_AUDIO_S: float = 0.30             # ignore buffers shorter than 300 ms

    def __init__(self, session_id: str):
        self.session_id = session_id
        self.audio_buffer = io.BytesIO()
        self.last_voice_time: float = time.monotonic()
        self.silence_frames: int = 0
        self.has_voice: bool = False

    def append_chunk(self, data: bytes) -> None:
        self.audio_buffer.write(data)

    def get_buffer_bytes(self) -> bytes:
        return self.audio_buffer.getvalue()

    def flush_buffer(self) -> None:
        self.audio_buffer = io.BytesIO()
        self.has_voice = False
        self.silence_frames = 0

    def buffer_duration_s(self) -> float:
        """Rough estimate based on 16-bit mono 16 kHz."""
        n_bytes = len(self.get_buffer_bytes())
        return n_bytes / (self.CHUNK_SR * 2)  # 2 bytes per int16 sample


# ---------------------------------------------------------------------------
# Audio helpers
# ---------------------------------------------------------------------------
def webm_bytes_to_float32(raw_bytes: bytes, target_sr: int = 16_000) -> Optional[np.ndarray]:
    """
    Decode browser-sent WebM/Opus bytes → numpy float32 mono @ target_sr.
    Returns None if audio is too short or decoding fails.
    """
    try:
        buf = io.BytesIO(raw_bytes)
        audio, sr = sf.read(buf, dtype="float32", always_2d=False)

        # Convert stereo → mono
        if audio.ndim == 2:
            audio = audio.mean(axis=1)

        # Resample if necessary
        if sr != target_sr:
            try:
                import resampy  # type: ignore
                audio = resampy.resample(audio, sr, target_sr)
            except ImportError:
                # Fallback: naive linear interpolation (acceptable for speech)
                ratio = target_sr / sr
                new_len = int(len(audio) * ratio)
                audio = np.interp(
                    np.linspace(0, len(audio) - 1, new_len),
                    np.arange(len(audio)),
                    audio,
                )

        if len(audio) / target_sr < SessionState.MIN_AUDIO_S:
            return None

        return audio.astype(np.float32)
    except Exception as exc:
        logger.debug(f"Audio decode failed: {exc}")
        return None


def is_silent(audio: np.ndarray, threshold_db: float = -40.0) -> bool:
    """True if RMS energy is below threshold_db dBFS."""
    rms = np.sqrt(np.mean(audio ** 2) + 1e-9)
    db = 20 * np.log10(rms)
    return db < threshold_db


# ---------------------------------------------------------------------------
# Transcription
# ---------------------------------------------------------------------------
async def transcribe(audio: np.ndarray) -> str:
    """Run faster-whisper in a thread pool so we don't block the event loop."""
    if whisper_model is None:
        return ""

    loop = asyncio.get_event_loop()

    def _run() -> str:
        segments, info = whisper_model.transcribe(
            audio,
            language="en",
            beam_size=5,
            vad_filter=True,               # Silero VAD built into faster-whisper
            vad_parameters={
                "min_silence_duration_ms": 500,   # 500 ms silence boundary
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
OLLAMA_MODEL = "carstenuhlig/omnicoder-2-9b:q4_k_m"  # or "llama3.2", etc.
TRANSLATION_SYSTEM_PROMPT = (
    "You are a silent, professional real-time translator. "
    "The user sends English text. "
    "You reply ONLY with the Spanish translation — no preamble, no explanations, "
    "no markdown, no extra punctuation beyond what the original contains. "
    "One translation per message. Nothing else."
)


async def translate_to_spanish(english_text: str) -> str:
    """Send text to local Ollama instance and return Spanish translation."""
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
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.post(OLLAMA_URL, json=payload)
            resp.raise_for_status()
            data = resp.json()
            translation = data["message"]["content"].strip()
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
    """
    Feed `text` (Spanish) to Kokoro pipeline.
    Stream raw audio bytes + subtitle JSON back over WebSocket.
    """
    if not text:
        return

    # First, push subtitle update to the client
    import json
    subtitle_msg = json.dumps(
        {"type": "subtitle", "en": english_text, "es": text}
    )
    try:
        await websocket.send_text(subtitle_msg)
    except Exception:
        return

    if kokoro_pipeline is None:
        logger.warning("Kokoro not available — skipping TTS.")
        return

    loop = asyncio.get_event_loop()

    def _generate_chunks():
        """Yield (samples, sample_rate) pairs from Kokoro."""
        # Kokoro KPipeline yields (graphemes, phonemes, audio_array) tuples
        for gs, ps, audio in kokoro_pipeline(text, voice="af_bella", speed=1.0):
            yield audio

    try:
        chunks = await loop.run_in_executor(None, lambda: list(_generate_chunks()))
    except Exception as exc:
        logger.error(f"Kokoro synthesis error: {exc}")
        return

    for audio_array in chunks:
        if audio_array is None or len(audio_array) == 0:
            continue

        # Convert float32 array → 16-bit PCM bytes for browser Web Audio API
        pcm_int16 = (np.clip(audio_array, -1.0, 1.0) * 32767).astype(np.int16)
        raw_bytes = pcm_int16.tobytes()

        try:
            await websocket.send_bytes(raw_bytes)
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

    # Background task: process utterances as they complete
    processing_lock = asyncio.Lock()

    async def process_utterance():
        """Pull audio from buffer, transcribe, translate, synthesise."""
        async with processing_lock:
            raw = state.get_buffer_bytes()
            state.flush_buffer()

        if not raw:
            return

        audio = await asyncio.get_event_loop().run_in_executor(
            None, webm_bytes_to_float32, raw
        )
        if audio is None:
            logger.debug(f"[{session_id}] Audio too short — skipped.")
            return

        # STT
        english = await transcribe(audio)
        if not english:
            return

        # Translation
        spanish = await translate_to_spanish(english)
        if not spanish:
            return

        # TTS → stream back
        await synthesise_and_stream(spanish, websocket, english)

    # ── Main receive loop ──────────────────────────────────────────────────
    try:
        silence_start: Optional[float] = None
        SILENCE_THRESHOLD = 0.50  # seconds

        while True:
            data = await websocket.receive_bytes()
            state.append_chunk(data)

            # Quick energy check on the last chunk to detect voice/silence
            # We do a lightweight decode of just this chunk for VAD purposes
            try:
                chunk_buf = io.BytesIO(data)
                chunk_audio, _ = sf.read(chunk_buf, dtype="float32", always_2d=False)
                if chunk_audio.ndim == 2:
                    chunk_audio = chunk_audio.mean(axis=1)
                chunk_silent = is_silent(chunk_audio)
            except Exception:
                chunk_silent = True  # can't decode → treat as silence

            now = time.monotonic()

            if not chunk_silent:
                state.has_voice = True
                silence_start = None
            else:
                if state.has_voice and silence_start is None:
                    silence_start = now

                if (
                    state.has_voice
                    and silence_start is not None
                    and (now - silence_start) >= SILENCE_THRESHOLD
                ):
                    logger.info(
                        f"[{session_id}] 500 ms silence detected — triggering processing."
                    )
                    asyncio.create_task(process_utterance())
                    silence_start = None

    except WebSocketDisconnect:
        logger.info(f"[{session_id}] Client disconnected — flushing session buffer.")
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