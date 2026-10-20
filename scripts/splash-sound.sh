#!/usr/bin/env bash
# Soft sounds for the splash (Settings > Splash, sky & time of day > "Soft sounds with the splash"; off by default).
#   splash-sound.sh login | unlock | shutdown     play that sound (login / unlock rise, shutdown falls)
#   splash-sound.sh make                          only (re)write the three files and print where they are
# No sound files ship with Halcyon: each one is a few shimmering sine notes that python3 (standard library only) writes
# once to ~/.cache/island/sounds/ (about 150 KB each) and every later play just plays that file. Quiet on purpose: peak
# volume is about 22 %, with a slow attack and a long fade. Played with pw-play, paplay, aplay or ffplay, whichever is
# installed first; with none of them (or no sound card) nothing happens and nothing is printed.
set -u
dir="${XDG_CACHE_HOME:-$HOME/.cache}/island/sounds"
kind="${1:-login}"
mkdir -p "$dir" 2>/dev/null || exit 0

make_all() {
python3 - "$dir" <<'PY' 2>/dev/null
import math, os, struct, sys, wave
out = sys.argv[1]
RATE = 44100
# note name -> Hz (a pentatonic set, so any order sounds friendly)
N = {"C5": 523.25, "D5": 587.33, "E5": 659.25, "G5": 783.99, "A5": 880.00, "C6": 1046.50, "E6": 1318.51, "G6": 1567.98}

def render(notes, total, path, peak=0.22):
    n = int(RATE * total)
    buf = [0.0] * n
    for (hz, start, length) in notes:
        a = int(start * RATE); m = int(length * RATE)
        for i in range(m):
            j = a + i
            if j >= n: break
            t = i / RATE
            att = min(1.0, t / 0.06)                       # slow attack: no click
            dec = math.exp(-3.2 * i / m)                   # long soft fade
            # a pure tone, a faint octave above it (the shimmer) and a very slight detune for width
            v = math.sin(2 * math.pi * hz * t) + 0.28 * math.sin(2 * math.pi * hz * 2 * t) + 0.12 * math.sin(2 * math.pi * hz * 1.003 * t)
            buf[j] += v * att * dec
    top = max(1e-9, max(abs(x) for x in buf))
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        # the last 80 ms fade to silence whatever the tail was doing
        fade = int(0.08 * RATE)
        frames = bytearray()
        for i, x in enumerate(buf):
            g = x / top * peak
            if i > n - fade: g *= (n - i) / fade
            frames += struct.pack("<h", int(max(-1, min(1, g)) * 32767))
        w.writeframes(bytes(frames))

up = [(N["C5"], 0.00, 1.1), (N["G5"], 0.16, 1.1), (N["C6"], 0.32, 1.2), (N["E6"], 0.50, 1.3), (N["G6"], 0.70, 1.4)]
down = [(N["G6"], 0.00, 1.0), (N["E6"], 0.20, 1.1), (N["C6"], 0.42, 1.2), (N["G5"], 0.66, 1.3), (N["C5"], 0.92, 1.6)]
render(up, 2.4, os.path.join(out, "login.wav"))
render([(f, s * 0.8, l * 0.8) for (f, s, l) in up], 1.9, os.path.join(out, "unlock.wav"), 0.18)
render(down, 2.9, os.path.join(out, "shutdown.wav"))
PY
}

case "$kind" in
  make) make_all; ls -1 "$dir"/*.wav 2>/dev/null; exit 0 ;;
  login|unlock|shutdown) ;;
  *) echo "usage: splash-sound.sh login|unlock|shutdown|make" >&2; exit 2 ;;
esac

f="$dir/$kind.wav"
[ -s "$f" ] || make_all
[ -s "$f" ] || exit 0
if   command -v pw-play >/dev/null 2>&1; then exec pw-play "$f" >/dev/null 2>&1
elif command -v paplay  >/dev/null 2>&1; then exec paplay "$f" >/dev/null 2>&1
elif command -v aplay   >/dev/null 2>&1; then exec aplay -q "$f" >/dev/null 2>&1
elif command -v ffplay  >/dev/null 2>&1; then exec ffplay -nodisp -autoexit -loglevel quiet "$f" >/dev/null 2>&1
fi
exit 0
