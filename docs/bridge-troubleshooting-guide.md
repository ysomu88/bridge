# Bridge Project — Dependency Troubleshooting Guide

This documents the issues hit while setting up `bridge` (voice-to-voice
translation server) on Windows with an RTX 3070 Ti, what caused them, how
they were fixed, and how to diagnose them again if the environment breaks
in the future.

**Key context for this project:** it's built around **`uv`**, not plain
`pip`. The venv (`.venv`) doesn't have `pip` installed inside it at all —
that's intentional. Always use `uv pip install ...` for this project, never
a bare `pip install`. Mixing in a global/system `pip` is what caused most
of the pain below.

---

## Issue 1 — `numpy` version check fails with `found=None`

**Symptom:**
```
ValueError: Unable to compare versions for numpy>=1.17: need=1.17 found=None.
```

**Root cause:** Two separate problems stacked on top of each other:

1. The system `pip` on PATH (`where.exe pip`) pointed to a **global**
   Python install outside the project's `.venv`, while the actual
   interpreter running `python server.py` used the venv's own
   `site-packages`. Installing packages with the wrong `pip` silently
   writes to the wrong location.
2. The `numpy` package installed *inside* the venv had a corrupted
   `dist-info` folder — specifically, its `METADATA` file was missing.
   Python could still `import numpy` fine (the actual `.py`/binary files
   were there), but `importlib.metadata.version('numpy')` — which
   `transformers` uses internally to check dependency versions — came back
   `None` because it couldn't read a `Version:` field from anywhere.

**How to diagnose this again:**
```powershell
# Does the import work, and where does it live?
python -c "import numpy; print(numpy.__file__, numpy.__version__)"

# Can importlib.metadata read its version? (this is what actually broke)
python -c "import importlib.metadata as m; print(m.version('numpy'))"

# Is `pip`/`uv` even pointed at the venv?
where.exe pip
where.exe python
```
If `numpy.__file__` shows a path inside `.venv\Lib\site-packages\numpy`
but `importlib.metadata.version('numpy')` errors or returns `None`, the
dist-info is corrupted. If `where.exe pip` doesn't point inside
`.venv\Scripts\`, you're using the wrong pip entirely — use `uv pip` instead.

**Fix:**
```powershell
Remove-Item ".venv\Lib\site-packages\numpy" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item ".venv\Lib\site-packages\numpy-*.dist-info" -Recurse -Force -ErrorAction SilentlyContinue
uv pip install --no-cache "numpy>=1.26.0"
```

---

## Issue 2 — `uv` install fails with "Access is denied" mid-rename

**Symptom:**
```
error: Failed to install: numpy-2.5.1-...whl (numpy==2.5.1)
  Caused by: failed to rename file ... Access is denied. (os error 5)
```

**Root cause:** Windows file locking. Another process (a leftover
`python.exe`, an open VS Code window with its Python language server
indexing the venv, a Jupyter kernel, etc.) had a file inside the package
open, so `uv` couldn't replace it during install.

**How to diagnose:** Check for stray Python processes, and close any
editor/IDE window that has the project folder open.
```powershell
Get-Process python* -ErrorAction SilentlyContinue
```

**Fix:**
```powershell
Stop-Process -Name python -Force -ErrorAction SilentlyContinue
# Also fully close VS Code / any other editor touching this folder, then retry the install.
```

---

## Issue 3 — `torch`/`torchvision` version mismatch (CPU vs CUDA, or mismatched versions)

**Symptom:** Import errors cascading up through
`torchvision._meta_registrations` → `transformers` → chatterbox, e.g.:
```
ModuleNotFoundError: Could not import module 'LlamaModel'...
```
or `torch.cuda.is_available()` returning `False` when it shouldn't.

**Root cause:** `torch`, `torchvision`, and `torchaudio` must all come from
the **same build/index** (matching CUDA version, or all CPU-only). A plain
`uv pip install torch torchvision torchaudio` without specifying an index
pulls default PyPI wheels, which may be CPU-only or a different CUDA
version than what's already installed for the other two — causing a silent
mismatch.

**How to diagnose:**
```powershell
python -c "import torch, torchvision; print(torch.__version__, torchvision.__version__)"
python -c "import torch; print(torch.cuda.is_available())"
nvidia-smi   # check the "CUDA Version" shown top-right — this is the max your driver supports
```
If the version strings don't have matching suffixes (e.g. one says `+cpu`
and another says `+cu121`), or `cuda.is_available()` is `False` on a
machine with a GPU, that's the mismatch.

**Fix:** Install all three together, explicitly, from the matching PyTorch
CUDA index (adjust `cu124` to whatever your driver supports per `nvidia-smi`):
```powershell
uv pip install --reinstall torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0 --index-url https://download.pytorch.org/whl/cu124
```
Note: `--reinstall` is required if a same-numbered-but-wrong-build version
is already "installed" — otherwise `uv` sees the version number matches
and skips reinstalling, even though the actual build (CPU vs CUDA) is wrong.

---

## Issue 4 — `numba` requires an older `numpy` than what's installed

**Symptom:**
```
ImportError: Numba needs NumPy 2.4 or less. Got NumPy 2.5.
```

**Root cause:** `requirements.txt` only pins `numpy>=1.26.0` with no upper
bound, so `uv` can resolve to a numpy version too new for `numba` (a
transitive dependency via `librosa`, used by chatterbox-tts).

**How it actually got fixed here:** reinstalling `torch` (Issue 3) pulled
in `numpy==2.4.4` as one of *its* dependencies, which happened to satisfy
numba's constraint. If this resurfaces on its own:
```powershell
python -c "import numpy; print(numpy.__version__)"
uv pip install --reinstall "numpy>=1.26.0,<2.5"
```
Check numba's current numpy ceiling if this keeps happening — it moves as
numba releases new versions:
```powershell
uv pip show numba
```

---

## Issue 5 — Chatterbox voice cloning fails: `'Perth' object has no attribute 'apply_watermark'`

**This is the important one to understand, not just copy-paste past.**

**Symptom:** Server starts fine, but voice-cloned synthesis fails at the
watermarking step:
```
'Perth' object has no attribute 'apply_watermark'
```

**Root cause — a real problem in this fork's `requirements.txt`, not just
environment drift:**

The correct dependency for chatterbox-tts's audio watermarking is a PyPI
package called **`resemble-perth`**, which installs into a folder named
`perth/` and exposes a class called `PerthImplicitWatermarker`. This is
what Resemble AI's own documentation and every other chatterbox deployment
guide use.

This fork's `requirements.txt` instead has you manually install a
**separate, bare-named package literally called `perth`** (not
`resemble-perth`) — a name with no verifiable, well-documented identity —
and then **patches chatterbox's actual source code** (`mtl_tts.py`,
`tts.py`, `tts_turbo.py`, `vc.py`) to replace every reference to
`PerthImplicitWatermarker` with `Perth`, rerouting the watermarking call
through this unverified package instead.

Since both packages install into a folder with the same name (`perth/`),
installing both into the same venv can also corrupt each other's files —
in this case it wiped out `resemble-perth`'s `__init__.py`, turning the
import into an empty Python namespace package.

**How to diagnose:**
```powershell
# Check what's actually installed under the "perth" name
uv pip list | Select-String -Pattern "perth"

# Check if it's a real module or an empty namespace package
python -c "import perth; print(perth.__file__)"
# A real package prints a path. `None` means it's an empty namespace
# package — a strong sign something is missing/corrupted.

# Confirm which class actually exists
python -c "import perth; print(dir(perth))"

# Check what the chatterbox source is actually calling
Select-String -Path ".venv\Lib\site-packages\chatterbox\tts.py" -Pattern "perth"
```

**Fix — remove the unverified package and restore the real dependency:**
```powershell
uv pip uninstall perth -y
Remove-Item ".venv\Lib\site-packages\perth" -Recurse -Force -ErrorAction SilentlyContinue
uv pip install --reinstall --no-cache resemble-perth
```

**Then revert the source patch** in all four files (this replaces the
exact call, not a blind global search-and-replace, since "Perth" also
appears as a substring inside "PerthImplicitWatermarker" itself):
```powershell
(Get-Content ".venv\Lib\site-packages\chatterbox\tts.py") -replace "perth\.Perth\(\)","perth.PerthImplicitWatermarker()" | Set-Content ".venv\Lib\site-packages\chatterbox\tts.py"
(Get-Content ".venv\Lib\site-packages\chatterbox\mtl_tts.py") -replace "perth\.Perth\(\)","perth.PerthImplicitWatermarker()" | Set-Content ".venv\Lib\site-packages\chatterbox\mtl_tts.py"
(Get-Content ".venv\Lib\site-packages\chatterbox\tts_turbo.py") -replace "perth\.Perth\(\)","perth.PerthImplicitWatermarker()" | Set-Content ".venv\Lib\site-packages\chatterbox\tts_turbo.py"
(Get-Content ".venv\Lib\site-packages\chatterbox\vc.py") -replace "perth\.Perth\(\)","perth.PerthImplicitWatermarker()" | Set-Content ".venv\Lib\site-packages\chatterbox\vc.py"
```

**Verify:**
```powershell
python -c "import perth; w = perth.PerthImplicitWatermarker(); print(hasattr(w, 'apply_watermark'))"
# Should print True
```

**Longer-term recommendation:** since `chatterbox\` lives inside
`site-packages` (not your own project code), any fresh `uv pip install` of
chatterbox-tts will re-fetch unpatched source and you won't need this
patch at all *if* you skip installing the bare `perth` package in the
first place. Consider editing your local copy of `requirements.txt` to
drop the `perth` line entirely and rely on `resemble-perth` being pulled
in normally as chatterbox-tts's real dependency. Also worth flagging this
line to whoever maintains the fork, since as written it silently swaps in
an unverified package in place of a legitimate one.

---

## Recommended full clean-install sequence (from scratch)

If the environment gets wiped or corrupted again, here's the order that
worked, run entirely with `uv pip` (never plain `pip`):

```powershell
# 1. Base requirements
uv pip install -r requirements.txt

# 2. chatterbox-tts without its (incomplete) declared deps
uv pip install "chatterbox-tts>=0.1.4" --no-deps

# 3. Its missing deps, also without deps (to avoid pulling a numpy conflict)
uv pip install "llvmlite>=0.43.0" "numba>=0.60.0" "librosa>=0.10.0" "resemble-perth" --no-deps
#    ^ NOTE: use "resemble-perth" here, NOT bare "perth" — see Issue 5 above.
#    The original requirements.txt says "perth" — override that.

# 4. Remaining supporting packages, normal resolution
uv pip install conformer diffusers einops rotary-embedding-torch encodec vector-quantize-pytorch

# 5. Re-run full requirements to reconcile everything
uv pip install -r requirements.txt

# 6. Force torch/torchvision/torchaudio onto matching CUDA builds
#    (check `nvidia-smi` first for your driver's supported CUDA version)
uv pip install --reinstall torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0 --index-url https://download.pytorch.org/whl/cu124

# 7. Pin numpy below numba's ceiling if it drifted upward again
uv pip install --reinstall "numpy>=1.26.0,<2.5"

# 8. espeak-ng (OS-level, not pip) — needed for non-English TTS phonemization
Start-Process "https://github.com/espeak-ng/espeak-ng/releases/latest"
#    Download and run the .msi manually.

# 9. Full verification pass
python -c "import numpy; print('numpy', numpy.__version__)"
python -c "import torch, torchvision; print('torch', torch.__version__, 'torchvision', torchvision.__version__, 'cuda:', torch.cuda.is_available())"
python -c "import perth; w = perth.PerthImplicitWatermarker(); print('perth OK:', hasattr(w, 'apply_watermark'))"
python -c "import chatterbox; print('chatterbox OK')"

# 10. Run it
python server.py
```

---

## General debugging habits that helped

- **Always use `uv pip`, never bare `pip`**, for this project — the venv
  has no `pip` installed at all, so a bare `pip install` always means
  you're accidentally hitting a global Python install instead.
- When an import error mentions a version but `pip show` and
  `numpy.__version__` (or similar) disagree, suspect **corrupted
  dist-info metadata** or **two installs shadowing each other**, not a
  real version conflict.
- `--reinstall` (or `--force-reinstall`) matters when a package is
  "technically" the right version number but the actual build is wrong
  (e.g. CPU vs CUDA) — a plain install will skip it as "already
  satisfied."
- "Access is denied" during install on Windows usually means a lingering
  process (stray `python.exe`, an open IDE) has a file locked — close
  everything touching the venv before retrying.
- If two packages might install into a folder with the *same name*
  (e.g. `perth`), be suspicious of **exactly this kind of failure mode**:
  installing both can silently merge/corrupt each other's files. Check
  `Get-ChildItem .venv\Lib\site-packages -Filter "*<name>*"` to see
  everything under a given name before assuming there's only one package
  involved.
