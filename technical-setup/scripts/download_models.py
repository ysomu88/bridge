#!/usr/bin/env python3
"""
Model download script for Bridge.
Delegates to scripts/download_models.py or runs self-contained.
"""
import sys
from pathlib import Path

# If root scripts/download_models.py exists, import and run it
root_script = Path(__file__).resolve().parent.parent.parent / "scripts" / "download_models.py"
if root_script.exists():
    import importlib.util
    spec = importlib.util.spec_from_file_location("download_models_root", root_script)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.main()
else:
    print(f"Error: {root_script} not found.", file=sys.stderr)
    sys.exit(1)
