"""
Bridge — Real-Time Voice-to-Voice Translation Server
FastAPI + faster-whisper + Ollama + Kokoro-82M
Target: RTX 3070 Ti (8GB VRAM), Windows 11, uv package manager
"""

import os
import sys

# Dynamic runtime patching for NVIDIA CUDA DLLs and espeak-ng on Windows
if sys.platform == "win32":
    venv_base = os.path.join(os.path.dirname(__file__), ".venv", "Lib", "site-packages")
    cublas_path = os.path.join(venv_base, "nvidia", "cublas", "bin")
    cudnn_path = os.path.join(venv_base, "nvidia", "cudnn", "bin")

    if os.path.exists(cublas_path):
        os.environ["PATH"] = cublas_path + os.pathsep + os.environ["PATH"]
    if os.path.exists(cudnn_path):
        os.environ["PATH"] = cudnn_path + os.pathsep + os.environ["PATH"]

    # espeak-ng — required by kokoro-onnx for non-English phonemization
    # (Chinese, Hindi, Japanese, French, etc.)
    espeak_dir = r"C:\Program Files\eSpeak NG"
    espeak_dll = os.path.join(espeak_dir, "libespeak-ng.dll")
    espeak_exe = os.path.join(espeak_dir, "espeak-ng.exe")
    if os.path.exists(espeak_dll):
        os.environ["PHONEMIZER_ESPEAK_LIBRARY"] = espeak_dll
        os.environ["PHONEMIZER_ESPEAK_PATH"]    = espeak_exe
        os.environ["PATH"] = espeak_dir + os.pathsep + os.environ["PATH"]

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
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, UploadFile, File, HTTPException
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
piper_voices: dict = {}     # lang_code -> PiperVoice instance
chatterbox_model = None     # ChatterboxMultilingualTTS instance, shared across all cloned-voice sessions
voice_profiles: dict = {}   # voice_id -> absolute path to the user's reference WAV clip

VOICE_SAMPLES_DIR = os.path.join(os.path.dirname(__file__), "voice_samples")
CHATTERBOX_LANGUAGES = {
    "ar", "da", "de", "el", "en", "es", "fi", "fr", "he", "hi", "it",
    "ja", "ko", "ms", "nl", "no", "pl", "pt", "ru", "sv", "sw", "tr", "zh",
}


# ---------------------------------------------------------------------------
# Lifespan: load / unload models
# ---------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    global whisper_model, kokoro_pipeline, chatterbox_model

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

    # ── Piper TTS (Korean, German) ────────────────────────────────────────
    try:
        from piper import PiperVoice  # type: ignore
        import wave

        PIPER_VOICE_FILES = {
            "ko": ("piper_voices/piper-kss-korean.onnx", "piper_voices/piper-kss-korean.onnx.json"),
            "de": ("piper_voices/de_DE-thorsten-high.onnx", "piper_voices/de_DE-thorsten-high.onnx.json"),
        }

        for lang, (model_path, config_path) in PIPER_VOICE_FILES.items():
            if os.path.exists(model_path) and os.path.exists(config_path):
                try:
                    piper_voices[lang] = PiperVoice.load(model_path, config_path=config_path, use_cuda=False)
                    logger.info(f"✅ Piper voice loaded for '{lang}' ({model_path})")
                except Exception as exc:
                    logger.warning(f"⚠️  Piper failed to load voice for '{lang}': {exc}")
            else:
                logger.warning(
                    f"⚠️  Piper voice files not found for '{lang}'. "
                    f"Download to: {model_path} — see DOCUMENTATION.md for instructions."
                )
    except ImportError:
        logger.warning("piper-tts not installed — Korean/German TTS disabled. Run: uv pip install piper-tts")

    # ── Chatterbox Multilingual (voice cloning) ─────────────────────────────
    try:
        from chatterbox.mtl_tts import ChatterboxMultilingualTTS  # type: ignore

        logger.info("Loading Chatterbox Multilingual (voice cloning, ~2-3 GB VRAM)…")
        try:
            chatterbox_model = ChatterboxMultilingualTTS.from_pretrained(device="cuda")
            logger.info("✅ Chatterbox Multilingual loaded on CUDA.")
        except Exception as exc:
            logger.warning(f"CUDA unavailable for Chatterbox ({exc}). Falling back to CPU — cloning will be slow.")
            chatterbox_model = ChatterboxMultilingualTTS.from_pretrained(device="cpu")
            logger.info("✅ Chatterbox Multilingual loaded on CPU.")
    except ImportError:
        logger.warning(
            "chatterbox-tts not installed — voice cloning disabled. Run: uv pip install chatterbox-tts"
        )
        chatterbox_model = None
    except Exception as exc:
        logger.error(f"Chatterbox init failed: {exc}")
        chatterbox_model = None

    os.makedirs(VOICE_SAMPLES_DIR, exist_ok=True)

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
    piper_voices.clear()
    chatterbox_model = None
    voice_profiles.clear()

    # Privacy: delete all voice sample files from disk on shutdown.
    # Users' recorded voice clips should never persist beyond a single session.
    if os.path.isdir(VOICE_SAMPLES_DIR):
        deleted = 0
        for f in os.listdir(VOICE_SAMPLES_DIR):
            try:
                os.remove(os.path.join(VOICE_SAMPLES_DIR, f))
                deleted += 1
            except Exception as exc:
                logger.warning(f"Could not delete voice sample {f}: {exc}")
        logger.info(f"🗑️  Deleted {deleted} voice sample file(s) from {VOICE_SAMPLES_DIR}.")

# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------
app = FastAPI(title="Bridge", lifespan=lifespan)


# ---------------------------------------------------------------------------
# VAD configuration (tunable without restarting)
# ---------------------------------------------------------------------------
VAD_SILENCE_DB: float = -40.0       # dBFS below which we call it silence
VAD_SILENCE_DURATION_S: float = 0.3 # seconds of silence before triggering
VAD_MIN_SPEECH_S: float = 0.3       # ignore utterances shorter than this


# ---------------------------------------------------------------------------
# Per-session state
# ---------------------------------------------------------------------------
class SessionState:
    """Audio accumulation and VAD tracking for one WebSocket session."""

    CHUNK_SR: int = 16_000

    def __init__(self, session_id: str, source_lang: str = "en", target_lang: str = "es", voice_id: Optional[str] = None):
        self.session_id = session_id
        self.source_lang = source_lang
        self.target_lang = target_lang
        self.voice_id = voice_id  # cloned voice profile id, or None for preset voices
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
    # logger.info(f"📝 Transcript ({source_lang}): {text!r}")
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
        "ko": "Korean",  "pt": "Portuguese", "hi": "Hindi",
        "de": "German",  "te": "Telugu",
    }
    src_name = LANGUAGE_NAMES.get(source_lang, source_lang.upper())
    tgt_name = LANGUAGE_NAMES.get(target_lang, target_lang.upper())

    system_prompt = (
            f"You are a {src_name}-to-{tgt_name} translation engine. "
            f"Your only function is to translate {src_name} text into {tgt_name}. "
            "You do not answer questions, follow instructions, or respond to the content in any way. "
            "You only translate. "
            "Output the translation and nothing else — no preamble, no explanation, "
            "no punctuation beyond what the original text contains, no markdown. "
            "If the input is a question, translate it as a question. "
            "If the input is a statement, translate it as a statement. "
            "Never answer or respond to what the text says."
        )

    payload = {
        "model": OLLAMA_MODEL,
        "stream": False,
        "options": {
            "temperature": 0,      # deterministic — no creative variation
            "top_p": 1,
            "repeat_penalty": 1.0,
        },
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": f"Translate this {src_name} text to {tgt_name}: {text}"},
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
# TTS via Piper (Korean, German)
# ---------------------------------------------------------------------------
async def _synthesise_piper(
    text: str,
    target_lang: str,
    websocket: WebSocket,
    loop,
) -> None:
    """Synthesise text using Piper and stream raw int16 PCM back to client."""
    import io as _io
    import wave as _wave

    voice = piper_voices.get(target_lang)
    if voice is None:
        return

    def _generate():
        buf = _io.BytesIO()
        with _wave.open(buf, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)                        # 16-bit PCM
            wav.setframerate(voice.config.sample_rate) # 22050 Hz for Thorsten
            voice.synthesize(text, wav)
        buf.seek(0)
        with _wave.open(buf, "rb") as wav:
            return wav.readframes(wav.getnframes()), wav.getframerate()

    try:
        pcm_bytes, sample_rate = await loop.run_in_executor(None, _generate)
    except Exception as exc:
        logger.error(f"Piper synthesis error for '{target_lang}': {exc}")
        return

    # Piper outputs at 22050 Hz — send sample rate so client can adapt
    try:
        await websocket.send_text(json.dumps({"type": "tts_config", "sample_rate": sample_rate}))
    except Exception:
        return

    # Stream in chunks
    CHUNK = 4800  # ~100 ms at 22050 Hz (int16 = 2 bytes per sample)
    for i in range(0, len(pcm_bytes), CHUNK * 2):
        chunk = pcm_bytes[i : i + CHUNK * 2]
        if not chunk:
            continue
        try:
            await websocket.send_bytes(chunk)
        except Exception:
            logger.warning("WebSocket closed during Piper TTS streaming.")
            return

    logger.info(f"🔊 Piper TTS stream complete ({target_lang}).")


# ---------------------------------------------------------------------------
# TTS via Chatterbox Multilingual (voice cloning)
# ---------------------------------------------------------------------------
async def _synthesise_chatterbox(
    text: str,
    target_lang: str,
    websocket: WebSocket,
    loop,
    voice_id: str,
) -> None:
    """
    Synthesise text in the user's cloned voice via Chatterbox Multilingual,
    then stream raw int16 PCM back to the client.
    """
    if chatterbox_model is None:
        logger.warning("Chatterbox not loaded — falling back to preset voice.")
        return await _synthesise_chatterbox_fallback(text, target_lang, websocket, loop)

    ref_path = voice_profiles.get(voice_id)
    if ref_path is None or not os.path.exists(ref_path):
        logger.warning(f"Voice profile '{voice_id}' not found on disk — falling back to preset voice.")
        return await _synthesise_chatterbox_fallback(text, target_lang, websocket, loop)

    if target_lang not in CHATTERBOX_LANGUAGES:
        logger.warning(
            f"Chatterbox does not support '{target_lang}' — falling back to preset voice for this language."
        )
        return await _synthesise_chatterbox_fallback(text, target_lang, websocket, loop)

    def _generate():
        import torchaudio as ta  # local import — heavy, only needed here

        # cfg_weight=0 avoids the cloned voice inheriting an accent from the
        # reference clip's language when target_lang differs from it.
        wav_tensor = chatterbox_model.generate(
            text,
            language_id=target_lang,
            audio_prompt_path=ref_path,
            cfg_weight=0.3,
            exaggeration=0.5,
        )
        return wav_tensor, chatterbox_model.sr

    try:
        wav_tensor, sample_rate = await loop.run_in_executor(None, _generate)
    except Exception as exc:
        logger.error(f"Chatterbox synthesis error for voice '{voice_id}': {exc}")
        return await _synthesise_chatterbox_fallback(text, target_lang, websocket, loop)

    # wav_tensor is a torch tensor shaped [1, n_samples], float32 in [-1, 1]
    audio_array = wav_tensor.squeeze(0).cpu().numpy()

    try:
        await websocket.send_text(json.dumps({"type": "tts_config", "sample_rate": sample_rate}))
    except Exception:
        return

    pcm_int16 = (np.clip(audio_array, -1.0, 1.0) * 32767).astype(np.int16)
    pcm_bytes = pcm_int16.tobytes()

    CHUNK = 4800  # ~100-200ms depending on sample rate, 2 bytes/sample
    for i in range(0, len(pcm_bytes), CHUNK * 2):
        chunk = pcm_bytes[i : i + CHUNK * 2]
        if not chunk:
            continue
        try:
            await websocket.send_bytes(chunk)
        except Exception:
            logger.warning("WebSocket closed during Chatterbox TTS streaming.")
            return

    logger.info(f"🎙️  Chatterbox cloned-voice TTS stream complete ({target_lang}, voice={voice_id}).")


async def _synthesise_chatterbox_fallback(text: str, target_lang: str, websocket: WebSocket, loop) -> None:
    """If cloning fails for any reason, fall back to the normal preset-voice pipeline."""
    PIPER_LANGUAGES = {"ko", "de"}
    if target_lang in PIPER_LANGUAGES and target_lang in piper_voices:
        await _synthesise_piper(text, target_lang, websocket, loop)
        return

    if kokoro_pipeline is None:
        logger.warning("No fallback TTS engine available — subtitles only.")
        return

    KOKORO_LANG_MAP = {
        "en": ("en-us", "af_heart"), "es": ("es", "ef_dora"), "fr": ("fr-fr", "ff_siwis"),
        "it": ("it", "if_sara"), "ja": ("ja", "jf_alpha"), "zh": ("cmn", "zf_xiaobei"),
        "hi": ("hi", "hf_alpha"), "pt": ("pt-br", "pf_dora"),
    }
    kokoro_lang, voice_code = KOKORO_LANG_MAP.get(target_lang, ("en-us", "af_heart"))

    def _generate_chunks():
        try:
            samples, _ = kokoro_pipeline.create(text, voice=voice_code, speed=1.0, lang=kokoro_lang)
            chunk_size = 2400
            for i in range(0, len(samples), chunk_size):
                yield samples[i : i + chunk_size]
        except Exception as exc:
            logger.error(f"Kokoro fallback synthesis error: {exc}")

    try:
        chunks = await loop.run_in_executor(None, lambda: list(_generate_chunks()))
    except Exception as exc:
        logger.error(f"Kokoro fallback executor error: {exc}")
        return

    for audio_array in chunks:
        if audio_array is None or len(audio_array) == 0:
            continue
        pcm_int16 = (np.clip(audio_array, -1.0, 1.0) * 32767).astype(np.int16)
        try:
            await websocket.send_bytes(pcm_int16.tobytes())
        except Exception:
            return


# ---------------------------------------------------------------------------
# TTS via Kokoro-82M
# ---------------------------------------------------------------------------
async def synthesise_and_stream(
    translated_text: str,
    websocket: WebSocket,
    original_text: str,
    source_lang: str,
    target_lang: str,
    session_voice_id: Optional[str] = None,
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

    loop = asyncio.get_running_loop()

    # ── Route to a cloned voice via Chatterbox if this session has one ──
    if session_voice_id and session_voice_id in voice_profiles:
        await _synthesise_chatterbox(translated_text, target_lang, websocket, loop, session_voice_id)
        return

    # ── Route to Piper for languages Kokoro doesn't support ─────────────
    PIPER_LANGUAGES = {"ko", "de"}

    if target_lang in PIPER_LANGUAGES:
        if target_lang not in piper_voices:
            logger.warning(
                f"Piper voice for '{target_lang}' not loaded — subtitles only. "
                f"Download the voice files and place them in piper_voices/."
            )
            return
        await _synthesise_piper(translated_text, target_lang, websocket, loop)
        return

    if kokoro_pipeline is None:
        logger.warning("Kokoro not available — skipping TTS.")
        return

    # ── Kokoro for all other languages ────────────────────────────────────
    KOKORO_LANG_MAP = {
        "en": ("en-us", "af_heart"),
        "es": ("es",    "ef_dora"),
        "fr": ("fr-fr", "ff_siwis"),
        "it": ("it",    "if_sara"),
        "ja": ("ja",    "jf_alpha"),
        "zh": ("cmn",   "zf_xiaobei"),  # espeak uses 'cmn' for Mandarin, not 'zh'
        "hi": ("hi",    "hf_alpha"),
        "pt": ("pt-br", "pf_dora"),
    }
    # Telugu has no voice available in either Kokoro or official Piper — subtitles only
    KOKORO_UNSUPPORTED = {"te"}

    if target_lang in KOKORO_UNSUPPORTED:
        logger.warning(f"TTS not yet available for '{target_lang}' — subtitles only.")
        return

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
# Voice profile management (REST)
# ---------------------------------------------------------------------------
MAX_VOICE_SAMPLE_BYTES = 15 * 1024 * 1024  # 15 MB ceiling — a 10-30s WAV clip is well under this


@app.post("/api/voice/upload")
async def upload_voice_sample(file: UploadFile = File(...)):
    """
    Accept a short (10-30s) reference audio clip and register it as a voice
    profile. Returns a voice_id the client passes to /ws/stream to use this
    cloned voice for TTS playback.
    """
    if chatterbox_model is None:
        raise HTTPException(
            status_code=503,
            detail="Voice cloning is not available — chatterbox-tts is not installed or failed to load.",
        )

    contents = await file.read()
    if len(contents) > MAX_VOICE_SAMPLE_BYTES:
        raise HTTPException(status_code=413, detail="Voice sample too large — keep clips under 15 MB (~30s).")
    if len(contents) < 1000:
        raise HTTPException(status_code=400, detail="Voice sample too short or empty.")

    voice_id = str(uuid.uuid4())[:12]
    raw_ext = os.path.splitext(file.filename or "sample.webm")[1] or ".webm"
    raw_path = os.path.join(VOICE_SAMPLES_DIR, f"{voice_id}_raw{raw_ext}")
    wav_path = os.path.join(VOICE_SAMPLES_DIR, f"{voice_id}.wav")

    try:
        with open(raw_path, "wb") as f:
            f.write(contents)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Failed to save voice sample: {exc}")

    # Convert to WAV — the browser sends WebM/Opus, but Chatterbox's
    # audio_prompt_path needs a format torchaudio can load reliably.
    #
    # torchaudio's WebM/Opus support depends on its ffmpeg backend being
    # correctly detected, which is unreliable on Windows even with ffmpeg
    # on PATH. We try torchaudio first, then fall back to soundfile, which
    # has broader native codec support via libsndfile.
    loop = asyncio.get_running_loop()

    def _convert_to_wav():
        try:
            import torchaudio as ta
            waveform, sr = ta.load(raw_path)
            ta.save(wav_path, waveform, sr)
            return
        except Exception as exc:
            logger.warning(f"torchaudio could not decode voice sample, trying soundfile: {exc}")

        import soundfile as sf
        data, sr = sf.read(raw_path)
        sf.write(wav_path, data, sr)

    try:
        await loop.run_in_executor(None, _convert_to_wav)
    except Exception as exc:
        logger.error(f"Failed to convert voice sample to WAV (tried torchaudio and soundfile): {exc}")
        raise HTTPException(
            status_code=500,
            detail=(
                "Could not process the audio sample. This is usually an audio codec issue — "
                "try recording again, or check that ffmpeg is installed and on PATH."
            ),
        )
    finally:
        # Raw upload is no longer needed once the WAV conversion succeeds
        if os.path.exists(raw_path):
            os.remove(raw_path)

    voice_profiles[voice_id] = wav_path
    logger.info(f"🎙️  Registered new voice profile '{voice_id}' ({len(contents)} bytes) at {wav_path}")

    return {"voice_id": voice_id, "status": "registered"}


@app.delete("/api/voice/{voice_id}")
async def delete_voice_sample(voice_id: str):
    """Remove a voice profile and its underlying audio file."""
    path = voice_profiles.pop(voice_id, None)
    if path and os.path.exists(path):
        try:
            os.remove(path)
        except Exception as exc:
            logger.warning(f"Failed to delete voice sample file {path}: {exc}")
    return {"voice_id": voice_id, "status": "deleted"}


@app.get("/api/voice/status")
async def voice_cloning_status():
    """Lets the client check whether voice cloning is available before showing the UI for it."""
    return {
        "available": chatterbox_model is not None,
        "active_profiles": len(voice_profiles),
        "supported_languages": sorted(CHATTERBOX_LANGUAGES),
    }


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
    voice_id = params.get("voice_id", "").strip() or None

    session_id = str(uuid.uuid4())[:8]
    state = SessionState(session_id, source_lang, target_lang, voice_id)
    voice_note = f" | Voice: {voice_id}" if voice_id else " | Voice: preset"
    logger.info(f"[{session_id}] Client connected. Pipeline Route: {source_lang.upper()} -> {target_lang.upper()}{voice_note}")

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

        logger.info(f"[{session_id}] 🔄 Translating now")
        translated_text = await translate_text(original_text, state.source_lang, state.target_lang)
        if not translated_text:
            logger.warning(f"[{session_id}] ⚠️  Translation returned empty.")
            return

        await synthesise_and_stream(
            translated_text, websocket, original_text, state.source_lang, state.target_lang, state.voice_id
        )

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