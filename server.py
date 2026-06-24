"""
Bridge — Real-Time Voice-to-Voice Translation Server
FastAPI + faster-whisper + Ollama + Kokoro-82M
Target: RTX 3070 Ti (8GB VRAM), Windows 11, uv package manager
"""

import os
import sys

# Dynamic runtime patching for NVIDIA CUDA DLLs on Windows
if sys.platform == "win32":
    venv_base = os.path.join(os.path.dirname(__file__), ".venv", "Lib", "site-packages")
    cublas_path = os.path.join(venv_base, "nvidia", "cublas", "bin")
    cudnn_path = os.path.join(venv_base, "nvidia", "cudnn", "bin")
    
    if os.path.exists(cublas_path):
        os.environ["PATH"] = cublas_path + os.pathsep + os.environ["PATH"]
    if os.path.exists(cudnn_path):
        os.environ["PATH"] = cudnn_path + os.pathsep + os.environ["PATH"]

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
        logger.info("✅ Kokoro TTS pipeline ready (Bi-directional).")
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
VAD_SILENCE_DB: float = -40.0       # dBFS below which we call it silence
VAD_SILENCE_DURATION_S: float = 0.1 # seconds of silence before triggering
VAD_MIN_SPEECH_S: float = 0.3       # ignore utterances shorter than this


# ---------------------------------------------------------------------------
# Per-session state
# ---------------------------------------------------------------------------
class SessionState:
    """Audio accumulation and VAD tracking for one WebSocket session."""

    CHUNK_SR: int = 16_000

    def __init__(self, session_id: str, source_lang: str = "en", target_lang: str = "es"):
        self.session_id = session_id
        self.source_lang = source_lang
        self.target_lang = target_lang
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
    Directly converts raw incoming PCM Float32 bytes from the browser 
    into a NumPy array, completely bypassing container parsers.
    """
    if not raw_bytes:
        return None

    try:
        audio = np.frombuffer(raw_bytes, dtype=np.float32).copy()

        min_samples = int(VAD_MIN_SPEECH_S * target_sr)
        if len(audio) < min_samples:
            logger.debug(f"Audio buffer too short: {len(audio)} samples < {min_samples} minimum.")
            return None

        logger.debug(f"Successfully processed {len(audio)/target_sr:.2f}s of raw PCM audio.")
        return audio

    except Exception as exc:
        logger.error(f"❌ Direct raw PCM buffer conversion failed: {exc}")
        return None


# ---------------------------------------------------------------------------
# Transcription
# ---------------------------------------------------------------------------
async def transcribe(audio: np.ndarray, source_lang: str) -> str:
    """Run faster-whisper in a thread pool configured with session language parameters."""
    if whisper_model is None:
        return ""

    loop = asyncio.get_running_loop()

    def _run() -> str:
        segments, _ = whisper_model.transcribe(
            audio,
            language=source_lang,
            beam_size=5,
            vad_filter=True,
            vad_parameters={
                "min_silence_duration_ms": 500,
                "threshold": 0.5,
            },
        )
        return " ".join(seg.text.strip() for seg in segments).strip()

    text = await loop.run_in_executor(None, _run)
    logger.info(f"📝 Transcript ({source_lang}): {text!r}")
    return text


# ---------------------------------------------------------------------------
# Translation via Ollama
# ---------------------------------------------------------------------------
OLLAMA_URL = "http://localhost:11434/api/chat"
OLLAMA_MODEL = "llama3.2"


async def translate_text(text: str, source_lang: str, target_lang: str) -> str:
    """Send text to local Ollama and return translation mapped across active source/target paths."""
    if not text.strip():
        return ""

    LANGUAGE_NAMES = {
        "en": "English", "es": "Spanish", "fr": "French",
        "it": "Italian", "ja": "Japanese", "zh": "Chinese",
        "ko": "Korean",  "pt": "Portuguese",
    }
    src_name = LANGUAGE_NAMES.get(source_lang, source_lang.upper())
    tgt_name = LANGUAGE_NAMES.get(target_lang, target_lang.upper())

    system_prompt = (
        "You are a silent, professional real-time translator. "
        f"The user sends {src_name} text. "
        f"You reply ONLY with the {tgt_name} translation — no preamble, no explanations, "
        "no markdown, no extra punctuation beyond what the original contains. "
        "One translation per message. Nothing else."
    )

    payload = {
        "model": OLLAMA_MODEL,
        "stream": False,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": text},
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
            logger.info(f"🌐 Translation ({tgt_name}): {translation!r}")
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
    translated_text: str,
    websocket: WebSocket,
    original_text: str,
    source_lang: str,
    target_lang: str,
) -> None:
    """Synthesise target text and stream PCM bytes back to client with layout routing indicators."""
    if not translated_text:
        return

    # Pack subtitle properties context-aware for UI mapping blocks
    try:
        payload = {
            "type": "subtitle",
            "src": original_text,
            "tgt": translated_text,
            "en": original_text if source_lang == "en" else translated_text,
            "es": translated_text if target_lang == "es" else original_text
        }
        await websocket.send_text(json.dumps(payload))
    except Exception:
        return

    if kokoro_pipeline is None:
        logger.warning("Kokoro not available — skipping TTS.")
        return

    loop = asyncio.get_running_loop()
    
    # Kokoro language codes and default voices per language
    KOKORO_LANG_MAP = {
        "en": ("en-us", "af_heart"),
        "es": ("es",    "ef_dora"),
        "fr": ("fr-fr", "ff_siwis"),
        "it": ("it",    "if_sara"),
        "ja": ("ja",    "jf_alpha"),
        "zh": ("zh",    "zf_xiaobei"),
        "ko": ("ko",    "kf_alpha"),
        "pt": ("pt-br", "pf_dora"),
    }
    kokoro_lang, voice_code = KOKORO_LANG_MAP.get(target_lang, ("en-us", "af_heart"))

    def _generate_chunks():
        try:
            samples, sample_rate = kokoro_pipeline.create(
                translated_text, voice=voice_code, speed=1.0, lang=kokoro_lang
            )
            
            chunk_size = 2400
            for i in range(0, len(samples), chunk_size):
                yield samples[i : i + chunk_size]

        except Exception as exc:
            logger.error(f"Kokoro voice synthesis error: {exc}")

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
    
    # Extract structural routing values directly from initialization queries
    params = websocket.query_params
    source_lang = params.get("source", "en").lower()
    target_lang = params.get("target", "es").lower()
    
    session_id = str(uuid.uuid4())[:8]
    state = SessionState(session_id, source_lang, target_lang)
    logger.info(f"[{session_id}] Client connected. Pipeline Route: {source_lang.upper()} -> {target_lang.upper()}")

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

        logger.info(f"[{session_id}] 🔄 Transcribing {len(audio)/16000:.1f}s of audio via '{state.source_lang}' stream config...")
        original_text = await transcribe(audio, state.source_lang)
        if not original_text:
            logger.warning(f"[{session_id}] ⚠️  Whisper returned empty transcript.")
            return

        logger.info(f"[{session_id}] 🔄 Translating: {original_text!r}")
        translated_text = await translate_text(original_text, state.source_lang, state.target_lang)
        if not translated_text:
            logger.warning(f"[{session_id}] ⚠️  Translation returned empty.")
            return

        await synthesise_and_stream(translated_text, websocket, original_text, state.source_lang, state.target_lang)

    vad_silence_db: float = VAD_SILENCE_DB

    try:
        while True:
            message = await websocket.receive()

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