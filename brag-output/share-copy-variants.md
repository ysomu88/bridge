# Share Copy Variants: Bridge

## LinkedIn (Succinct & Technically Bulletproof)
I built Bridge — conversational speech-to-speech translation in your own cloned voice, running 100% on a single consumer GPU workstation. 🎙️⚡

Zero cloud AI dependencies. Zero subscriptions. All speech recognition, LLM reasoning, and neural voice synthesis run locally on private hardware.

You don't need a GPU to test it — I'm hosting the stack on an RTX 3070 Ti so you can try it live from your mobile browser:

1. Record a 15-second voice sample on your phone.
2. Speak naturally in English (or any supported language).
3. Bridge translates and speaks back in your target language using your real vocal tone and cadence.

How it works under the hood:
• STT: faster-whisper (CUDA int8, <350MB VRAM)
• LLM: Llama 3.2 3B via Ollama (Q4, pinned in VRAM)
• TTS: Chatterbox Multilingual (zero-shot voice cloning with PerTh watermarking)
• Transport: Low-latency raw Float32 PCM streaming over WebSockets
• Hardware: RTX 3070 Ti (8 GB VRAM) — total stack footprint ~6.2 GB
• Latency: ~5–8s cascade per utterance on local consumer hardware (condensed in video for demonstration).

Language support:
• 9 languages with full voice cloning & preset synthesis (EN, ES, FR, IT, JA, ZH, PT, HI, DE)
• Korean: Full voice cloning supported natively (preset voices via Piper weights)
• Telugu: Subtitles-only (STT + translation)

Try it live from your phone: https://tinyurl.com/bridge-app
(Note: Running on a single GPU with serialized inference, so you may see a brief queue if traffic spikes!)

Open source on GitHub: https://github.com/ysomu88/bridge

---

## LinkedIn (Alternative: Narrative / Builder Focus)
Most speech translation pipelines either depend on multi-hop cloud APIs with monthly subscriptions, or require a $5,000 dual-4090 rig.

I wanted to see how far I could push a single 8 GB consumer GPU (RTX 3070 Ti) to handle the complete bidirectional voice-to-voice pipeline privately on-device:

• Speech-to-Text: faster-whisper (CUDA int8, ~350 MB VRAM)
• LLM Translation: Llama 3.2 3B via Ollama (4-bit quantized, ~2.2 GB VRAM)
• Voice Cloning: Chatterbox Multilingual with speaker-conditioning caching (~3 GB VRAM)

The entire stack runs at ~6.2 GB VRAM footprint with ~5–8s cascade turnaround, streaming raw Float32 PCM back to mobile browsers over WebSockets.

Test it live from your phone: https://tinyurl.com/bridge-app
Codebase on GitHub: https://github.com/ysomu88/bridge

---

## Twitter / X / Threads
Speak English. Hear 11 languages in your own cloned voice. 🎙️⚡

I built Bridge — conversational speech-to-speech translation running 100% on a consumer RTX 3070 Ti with zero cloud AI dependencies.

No setup required on your end — test it live from your phone:
https://tinyurl.com/bridge-app
