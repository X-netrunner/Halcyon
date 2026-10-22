#!/usr/bin/env bash
# Soft sounds for the splash (Settings > Splash, sky & time of day > "Soft sounds with the splash"; off by default).
#   splash-sound.sh login | unlock | shutdown     play that sound (login / unlock rise, shutdown falls)
#   splash-sound.sh make                          only (re)write the three files and print where they are
# No sound files ship with Halcyon: python3 (standard library only) writes them once to ~/.cache/island/sounds/ and every later
# play just plays the file. Calm and spacious on purpose, nothing that rings or clicks: soft pure tones that fade in over about a
# second and drift a little in pitch, a low hum under them, a breath of filtered noise that slowly opens (or closes), a faint
# high shimmer, and a long soft room. Login opens up (C major 9), unlock is a short warm swell, shutdown settles downwards.
# SOUND_VERSION: bump it when the sounds change, so cached copies are written again.
# Played with pw-play, paplay, aplay or ffplay, whichever is installed first; with none of them nothing happens.
set -u
dir="${XDG_CACHE_HOME:-$HOME/.cache}/island/sounds"
kind="${1:-login}"
mkdir -p "$dir" 2>/dev/null || exit 0

SOUND_VERSION=3
make_all() {
python3 - "$dir" <<'PY' 2>/dev/null
import math, os, random, struct, sys, wave
out = sys.argv[1]
RATE = 44100
TAU = 2 * math.pi

def hz(note):
    """'C4' -> Hz (A4 = 440)."""
    names = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    return 440.0 * 2 ** ((names[note[0]] + 12 * (int(note[-1]) - 4)) / 12)

def swell(t, length, attack, release):
    """0..1, sine-shaped in and out: nothing starts or stops sharply."""
    if t <= 0 or t >= length:
        return 0.0
    a = math.sin(0.5 * math.pi * min(1.0, t / attack)) ** 2
    r = math.sin(0.5 * math.pi * min(1.0, (length - t) / release)) ** 2
    return a * r

def tone(L, R, f, start, length, gain, attack, release, pan=0.0, glide=0.0, bright=0.12):
    """A soft voice: three copies a few cents apart, each drifting slowly in pitch (a wide, airy chorus), the second harmonic only
    a whisper. glide = the pitch change over the note as a fraction (-0.02 = settles 2 % down)."""
    a, m = int(start * RATE), int(length * RATE)
    gl, gr = gain * math.sqrt(0.5 * (1 - pan)), gain * math.sqrt(0.5 * (1 + pan))
    for k, (cents, rate, ph0) in enumerate(((-6, 0.17, 0.0), (0, 0.23, 2.1), (7, 0.19, 4.2))):
        ph = 0.0
        base = f * 2 ** (cents / 1200)
        side = (k - 1) * 0.35                                  # the three copies sit left, middle, right
        kl, kr = math.sqrt(0.5 * (1 - side)), math.sqrt(0.5 * (1 + side))
        for i in range(m):
            j = a + i
            if j >= len(L):
                break
            t = i / RATE
            fr = base * (1 + glide * t / length) * (1 + 0.0025 * math.sin(TAU * rate * t + ph0))
            ph += TAU * fr / RATE
            v = (math.sin(ph) + bright * math.sin(2 * ph)) * swell(t, length, attack, release) / 3
            L[j] += v * gl * kl
            R[j] += v * gr * kr

def air(L, R, start, length, gain, cut0, cut1, seed):
    """A breath of space: noise through a soft two-pole low-pass whose cutoff moves from cut0 to cut1 Hz, panned slowly."""
    rnd = random.Random(seed)
    a, m = int(start * RATE), int(length * RATE)
    y1 = y2 = 0.0
    for i in range(m):
        j = a + i
        if j >= len(L):
            break
        t = i / RATE
        c = cut0 + (cut1 - cut0) * (t / length)
        k = 1 - math.exp(-TAU * c / RATE)
        y1 += k * (rnd.uniform(-1, 1) - y1)
        y2 += k * (y1 - y2)
        v = y2 * swell(t, length, length * 0.45, length * 0.5) * gain
        p = math.sin(TAU * 0.11 * t)                           # drifts from side to side
        L[j] += v * math.sqrt(0.5 * (1 - 0.6 * p))
        R[j] += v * math.sqrt(0.5 * (1 + 0.6 * p))

def room(x, delays, mix):
    """A long soft room: four parallel combs with a damping low-pass in the loop (no metallic ring), then two all-passes."""
    n = len(x)
    acc = [0.0] * n
    for d, g in delays:
        buf = [0.0] * n
        lp = 0.0
        for i in range(n):
            fb = buf[i - d] if i >= d else 0.0
            lp += 0.45 * (fb - lp)                             # the echoes lose their top end as they fade: warm, not tinny
            buf[i] = x[i] + g * lp
        for i in range(n):
            acc[i] += buf[i]
    y = [v / len(delays) for v in acc]
    for d in (347, 113):
        z = [0.0] * n
        for i in range(n):
            xd = y[i - d] if i >= d else 0.0
            zd = z[i - d] if i >= d else 0.0
            z[i] = -0.6 * y[i] + xd + 0.6 * zd
        y = z
    return [a * (1 - mix) + b * mix for a, b in zip(x, y)]

def write(path, L, R, peak):
    L = room(L, [(1557, 0.86), (1617, 0.85), (1491, 0.87), (1422, 0.88)], 0.42)
    R = room(R, [(1580, 0.86), (1640, 0.85), (1514, 0.87), (1445, 0.88)], 0.42)
    n = len(L)
    top = max(1e-9, max(max(abs(v) for v in L), max(abs(v) for v in R)))
    fade = int(0.6 * RATE)
    frames = bytearray()
    for i in range(n):
        g = peak / top
        if i > n - fade:
            g *= math.sin(0.5 * math.pi * (n - i) / fade) ** 2
        frames += struct.pack("<hh", int(max(-1, min(1, L[i] * g)) * 32767), int(max(-1, min(1, R[i] * g)) * 32767))
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(bytes(frames))

def buf(secs):
    n = int(RATE * secs)
    return [0.0] * n, [0.0] * n

# login: the room opens up. A low hum, then C major 9 fades in voice by voice, the air brightens, a faint shimmer at the top.
L, R = buf(5.0)
tone(L, R, hz("C2"), 0.0, 4.6, 0.55, 1.4, 2.0, bright=0.05)
tone(L, R, hz("C3"), 0.1, 4.4, 0.40, 1.2, 2.0, -0.2)
tone(L, R, hz("G3"), 0.4, 4.2, 0.32, 1.2, 2.0, 0.25)
tone(L, R, hz("E4"), 0.8, 3.9, 0.26, 1.1, 2.0, -0.3)
tone(L, R, hz("B4"), 1.2, 3.6, 0.20, 1.1, 2.0, 0.3)
tone(L, R, hz("D5"), 1.6, 3.3, 0.16, 1.0, 1.9, 0.0)
tone(L, R, hz("G6"), 1.9, 3.0, 0.035, 1.3, 1.6, 0.5, bright=0.0)      # the shimmer: barely there
tone(L, R, hz("D6"), 2.2, 2.7, 0.03, 1.2, 1.5, -0.5, bright=0.0)
air(L, R, 0.0, 4.8, 0.55, 250, 1400, 7)
write(os.path.join(out, "login.wav"), L, R, 0.36)

# unlock: a short warm swell, open (a sus2 chord), no tune
L, R = buf(3.2)
tone(L, R, hz("G2"), 0.0, 2.9, 0.45, 0.7, 1.6, bright=0.05)
tone(L, R, hz("G3"), 0.05, 2.8, 0.35, 0.7, 1.6, -0.25)
tone(L, R, hz("A3"), 0.25, 2.6, 0.26, 0.7, 1.5, 0.25)
tone(L, R, hz("D4"), 0.45, 2.4, 0.22, 0.7, 1.5, 0.0)
tone(L, R, hz("D6"), 0.8, 2.1, 0.03, 0.9, 1.2, 0.4, bright=0.0)
air(L, R, 0.0, 3.0, 0.45, 400, 1100, 11)
write(os.path.join(out, "unlock.wav"), L, R, 0.30)

# shutdown: everything settles a little downward and the air closes, like drifting off
L, R = buf(3.6)
tone(L, R, hz("A2"), 0.0, 3.3, 0.50, 0.6, 2.2, glide=-0.015, bright=0.05)
tone(L, R, hz("E3"), 0.0, 3.2, 0.36, 0.6, 2.2, -0.25, glide=-0.015)
tone(L, R, hz("B3"), 0.1, 3.0, 0.26, 0.6, 2.1, 0.25, glide=-0.015)
tone(L, R, hz("C4"), 0.2, 2.9, 0.20, 0.6, 2.0, 0.0, glide=-0.015)
tone(L, R, hz("E6"), 0.0, 1.8, 0.03, 0.6, 1.2, 0.4, bright=0.0)
air(L, R, 0.0, 3.4, 0.45, 1200, 200, 13)
write(os.path.join(out, "shutdown.wav"), L, R, 0.30)
PY
echo "$SOUND_VERSION" >"$dir/.version" 2>/dev/null
}

case "$kind" in
  make) make_all; ls -1 "$dir"/*.wav 2>/dev/null; exit 0 ;;
  login|unlock|shutdown) ;;
  *) echo "usage: splash-sound.sh login|unlock|shutdown|make" >&2; exit 2 ;;
esac

f="$dir/$kind.wav"
# cached copies from an older version of the sounds are written again
{ [ -s "$f" ] && [ "$(cat "$dir/.version" 2>/dev/null)" = "$SOUND_VERSION" ]; } || make_all
[ -s "$f" ] || exit 0
if   command -v pw-play >/dev/null 2>&1; then exec pw-play "$f" >/dev/null 2>&1
elif command -v paplay  >/dev/null 2>&1; then exec paplay "$f" >/dev/null 2>&1
elif command -v aplay   >/dev/null 2>&1; then exec aplay -q "$f" >/dev/null 2>&1
elif command -v ffplay  >/dev/null 2>&1; then exec ffplay -nodisp -autoexit -loglevel quiet "$f" >/dev/null 2>&1
fi
exit 0
