#!/bin/bash
# luna-voice-setup.sh: give Luna a voice (Kokoro text to speech, runs on this machine). Run it in a terminal:
#   bash ~/.config/Halcyon/scripts/luna-voice-setup.sh
# What it does, in order (it says each step before it runs it):
#   1. the Python packages that are heavy to build, from pacman (asks for your password; skipped when already there)
#   2. the Kokoro model and voice file (about 330 MB) from the kokoro-onnx v1.0 release on GitHub, into ~/.local/share/luna/kokoro
#   3. a small Python environment for Luna in ~/.local/share/luna/tts_env (kokoro-onnx, soundfile from PyPI)
#   4. [voice] in ~/.config/luna/luna.toml: the model path and the voice name (a backup luna.toml.before-voice is kept)
# Nothing else is touched. It only speaks when Luna's voice mode is basic (Settings > Voice & Audio) and "Read her answers aloud" is on.
set -u
BASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
DIR="$HOME/.local/share/luna/kokoro"
ENVDIR="$HOME/.local/share/luna/tts_env"
CFG="$HOME/.config/luna/luna.toml"
say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nStopped: %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null || die "python3 is not installed"
command -v curl >/dev/null || die "curl is not installed"

say "1/4  Python packages (numpy, onnxruntime, soundfile)"
if command -v pacman >/dev/null; then
    missing=""
    for p in python-numpy python-onnxruntime-cpu python-soundfile; do pacman -Qq "$p" >/dev/null 2>&1 || missing="$missing $p"; done
    if [ -n "$missing" ]; then
        echo "needs:$missing"
        sudo pacman -S --needed $missing || die "pacman could not install:$missing"
    else
        echo "already installed"
    fi
else
    echo "not an Arch system: the venv below will download these from PyPI instead (larger)"
fi

say "2/4  Kokoro model and voice file -> $DIR"
mkdir -p "$DIR"
for f in kokoro-v1.0.onnx voices-v1.0.bin; do
    if [ -s "$DIR/$f" ]; then echo "$f is already there"; continue; fi
    curl -fL --retry 3 -o "$DIR/$f.part" "$BASE/$f" || { rm -f "$DIR/$f.part"; die "could not download $f"; }
    mv "$DIR/$f.part" "$DIR/$f"
done

say "3/4  Python environment -> $ENVDIR"
if [ ! -x "$ENVDIR/bin/python3" ]; then
    python3 -m venv --system-site-packages "$ENVDIR" || die "could not create the environment"
fi
"$ENVDIR/bin/pip" install --quiet kokoro-onnx soundfile || die "pip could not install kokoro-onnx"

say "4/4  Luna's config ($CFG)"
if [ -f "$CFG" ]; then
    cp -n "$CFG" "$CFG.before-voice"
    python3 - "$CFG" "$DIR/kokoro-v1.0.onnx" <<'PY'
import re, sys
path, model = sys.argv[1], sys.argv[2]
s = open(path).read()
m = re.search(r"^\[voice\]\s*$", s, re.M)
if not m:
    s = s.rstrip("\n") + '\n\n[voice]\nmode = "basic"\n'
    m = re.search(r"^\[voice\]\s*$", s, re.M)
end = re.search(r"^\[", s[m.end():], re.M)
block_end = m.end() + (end.start() if end else len(s) - m.end())
block = s[m.end():block_end]
def put(block, key, val):
    line = '%s = "%s"' % (key, val)
    if re.search(r"^%s\s*=" % key, block, re.M):
        return re.sub(r"^%s\s*=.*$" % key, line, block, flags=re.M)
    return block.rstrip("\n") + "\n" + line + "\n"
block = put(block, "piper_model", model)
block = put(block, "piper_bin", "af_heart")
if not re.search(r"^mode\s*=", block, re.M):
    block = put(block, "mode", "basic")
s = s[:m.end()] + block + ("\n" if end else "") + s[block_end:]
open(path, "w").write(s)
PY
else
    echo "no luna.toml yet: run luna once, then run this again"
fi

say "Testing the voice"
if "$ENVDIR/bin/python3" -c "
from kokoro_onnx import Kokoro
import soundfile as sf
k = Kokoro('$DIR/kokoro-v1.0.onnx', '$DIR/voices-v1.0.bin')
s, sr = k.create('Hello, I am Luna.', voice='af_heart', speed=1.0, lang='en-us')
sf.write('/tmp/luna-voice-test.wav', s, sr)
" 2>/dev/null; then
    command -v pw-play >/dev/null && pw-play /tmp/luna-voice-test.wav || { command -v aplay >/dev/null && aplay -q /tmp/luna-voice-test.wav; }
    rm -f /tmp/luna-voice-test.wav
    echo "Done. Open Settings > Voice & Audio in Luna's window and turn on \"Read her answers aloud\"."
else
    die "the voice test failed: run this script again, or see the Voice Setup part of Luna's README"
fi
