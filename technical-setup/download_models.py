"""
Model download script for Bridge.
Downloads required model files for Kokoro and Piper TTS if they are missing from the clone:
- Kokoro ONNX model: model.onnx
- Kokoro voices: voices.json
- Piper German voice: piper_voices/de_DE-thorsten-high.onnx
- Piper German config: piper_voices/de_DE-thorsten-high.onnx.json
- Optional Korean voice: piper_voices/piper-kss-korean.onnx + .json (--include-korean)
"""

import argparse
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# Base URLs
MODELS = [
    {
        "name": "Kokoro ONNX Model (v0.19)",
        "dest": "model.onnx",
        "url": "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files/kokoro-v0_19.onnx",
        "required": True,
    },
    {
        "name": "Kokoro Voices Config",
        "dest": "voices.json",
        "url": "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files/voices.json",
        "required": True,
    },
    {
        "name": "Piper German Voice (Thorsten High)",
        "dest": "piper_voices/de_DE-thorsten-high.onnx",
        "url": "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/thorsten/high/de_DE-thorsten-high.onnx",
        "required": True,
    },
    {
        "name": "Piper German Voice Config",
        "dest": "piper_voices/de_DE-thorsten-high.onnx.json",
        "url": "https://huggingface.co/rhasspy/piper-voices/resolve/main/de/de_DE/thorsten/high/de_DE-thorsten-high.onnx.json",
        "required": True,
    },
]

OPTIONAL_KOREAN = [
    {
        "name": "Piper Korean Voice (KSS Medium)",
        "dest": "piper_voices/piper-kss-korean.onnx",
        "url": "https://huggingface.co/rhasspy/piper-voices/resolve/main/ko/ko_KR/kss/medium/ko_KR-kss-medium.onnx",
        "required": False,
    },
    {
        "name": "Piper Korean Voice Config",
        "dest": "piper_voices/piper-kss-korean.onnx.json",
        "url": "https://huggingface.co/rhasspy/piper-voices/resolve/main/ko/ko_KR/kss/medium/ko_KR-kss-medium.onnx.json",
        "required": False,
    },
]


def format_bytes(num_bytes: int) -> str:
    """Format bytes into human-readable string."""
    for unit in ["B", "KB", "MB", "GB"]:
        if abs(num_bytes) < 1024.0:
            return f"{num_bytes:3.1f} {unit}"
        num_bytes /= 1024.0
    return f"{num_bytes:.1f} TB"


def download_file(url: str, dest_path: Path, name: str, force: bool = False) -> bool:
    """Download a file with progress reporting."""
    if dest_path.exists() and dest_path.stat().st_size > 0 and not force:
        size_str = format_bytes(dest_path.stat().st_size)
        print(f"[OK] {name} already exists ({dest_path.name}, {size_str}) - skipping.")
        return True

    dest_path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = dest_path.with_suffix(dest_path.suffix + ".tmp")

    print(f"\n--> Downloading {name}...")
    print(f"    Source: {url}")
    print(f"    Destination: {dest_path}")

    headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) BridgeModelDownloader/1.0"}
    req = urllib.request.Request(url, headers=headers)

    try:
        with urllib.request.urlopen(req, timeout=30) as resp, open(temp_path, "wb") as out_file:
            total_size = int(resp.headers.get("Content-Length", 0))
            downloaded = 0
            start_time = time.time()
            last_report = start_time

            chunk_size = 1024 * 1024  # 1 MB chunk

            while True:
                chunk = resp.read(chunk_size)
                if not chunk:
                    break
                out_file.write(chunk)
                downloaded += len(chunk)

                now = time.time()
                if now - last_report >= 0.5 or (total_size and downloaded >= total_size):
                    elapsed = max(now - start_time, 0.001)
                    speed = downloaded / elapsed
                    speed_str = f"{format_bytes(int(speed))}/s"
                    if total_size > 0:
                        pct = (downloaded / total_size) * 100
                        print(
                            f"\r    Progress: {pct:5.1f}% [{format_bytes(downloaded)} / {format_bytes(total_size)}] @ {speed_str} ",
                            end="",
                            flush=True,
                        )
                    else:
                        print(
                            f"\r    Downloaded: {format_bytes(downloaded)} @ {speed_str} ",
                            end="",
                            flush=True,
                        )
                    last_report = now

            print()  # newline after progress

        # Rename temp file to target
        if temp_path.exists():
            if dest_path.exists():
                dest_path.unlink()
            temp_path.rename(dest_path)

        final_size = dest_path.stat().st_size
        print(f"    Completed successfully: {format_bytes(final_size)} saved.")
        return True

    except (urllib.error.URLError, OSError, TimeoutError, Exception) as e:  # noqa: BLE001
        print(f"\n[ERROR] Failed to download {name}: {e}", file=sys.stderr)
        if temp_path.exists():
            try:
                temp_path.unlink()
            except OSError:
                pass
        return False


def get_repo_root() -> Path:
    """Find repository root by looking for server.py or pyproject.toml / requirements.txt."""
    current = Path(__file__).resolve().parent
    for p in [current, current.parent, current.parent.parent]:
        if (p / "server.py").exists() or (p / "requirements.txt").exists():
            return p
    return Path.cwd()


def main():
    parser = argparse.ArgumentParser(description="Download model assets for Bridge voice translation server.")
    parser.add_argument("--force", action="store_true", help="Force re-download even if files exist.")
    parser.add_argument("--include-korean", action="store_true", help="Also download optional Korean Piper voice model.")
    args = parser.parse_args()

    repo_root = get_repo_root()
    print("=" * 65)
    print("Bridge Model Asset Downloader")
    print(f"Target repository root: {repo_root}")
    print("=" * 65)

    download_queue = list(MODELS)
    if args.include_korean:
        download_queue.extend(OPTIONAL_KOREAN)

    failed = []
    for item in download_queue:
        dest_path = repo_root / item["dest"]
        success = download_file(item["url"], dest_path, item["name"], force=args.force)
        if not success:
            failed.append(item["name"])

    print("\n" + "=" * 65)
    if failed:
        print(f"[WARNING] {len(failed)} download(s) failed:")
        for name in failed:
            print(f" - {name}")
        sys.exit(1)
    else:
        print("[SUCCESS] All model assets are ready!")
        print("=" * 65)


if __name__ == "__main__":
    main()
