#!/usr/bin/env python3
"""halcyon-music.py: the data side of the lyrics and queue panel (media page > Lyrics / Queue, >lyrics and >queue in the launcher).

  halcyon-music.py lyrics [json] [--title T --artist A --album B --duration SEC --url file://...]
                                   lyrics of the song that plays (any player: the panel passes what MPRIS says)
  halcyon-music.py source [auto|local|lrclib|ovh|spotify]   which lyrics source to use (no argument: show it)
  halcyon-music.py queue [json] [N]  what plays next (default 30, at most 100)
  halcyon-music.py ncspot [CMD]    send an ncspot command to the running ncspot (default "focus queue")
  halcyon-music.py status          plain text: is spotify_player installed, how new, can it do lyrics / queue

With `json` (what the panel uses) the answer is ONE line of JSON, always, also when something is wrong:
  lyrics: {"ok": bool, "state": str, "message": str, "title": str, "artist": str, "source": str, "lines": [str]}
  queue:  {"ok": bool, "state": str, "message": str, "now": {"title","artist"}|null, "total": int, "items": [{"title","artist","ms","kind"}]}
Without `json` it prints plain text for a terminal. Exit code 0 when it worked, 1 when it did not.

`state` says what went wrong, so the panel can say it in words: ok | missing (spotify_player not installed) | old (installed, too
old for lyrics) | auth (not logged in) | idle (nothing is playing) | none (no lyrics for this song) | error.

Where the lyrics come from (music.conf: LYRICS_SOURCE=auto, or one of them). spotify_player is OPTIONAL now:
  local    a .lrc / .txt file next to the song file (same name), when the player says where the file is. Offline, no account.
  lrclib   lrclib.net: a free lyrics database, no account and no key. Needs only the title and the artist of the song
           (any player that speaks MPRIS: Spotify app, a browser, mpv, Rhythmbox, VLC ...). One small HTTPS request per song.
  ovh      api.lyrics.ovh: a second free site, plain text, used only as a last resort in auto.
  spotify  the `spotify_player` command line (below), for people who have it and are logged in.
auto tries them in that order and stops at the first that has the song. Nothing is stored: no cache file, no log.
HALCYON_LRCLIB_URL / HALCYON_OVH_URL point the sites somewhere else (tests, a self-hosted LRCLIB).

The spotify source: the `spotify_player` command line (`spotify_player lyrics`, `spotify_player get key queue`). It asks YOUR
Spotify account (the session spotify_player already has), so there is no third-party lyrics site and no key to set up. The lyrics
command exists since spotify_player 0.24.0; the queue command is older. Both work with the Spotify app, a phone or spotify_player
itself as the player: the queue and the "now playing" song are the account's, not one program's. When spotify_player is not running,
the command starts a short-lived client of its own just for this one answer.

It adds no process: every call is a one-shot command that exits when done, and Halcyon only runs it while the panel is open (and
once more when the song changes). Nothing is stored: no cache, no file, no log.
"""
import json
import os
import time
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from shutil import which

TIMEOUT = 25          # seconds: a cold start has to log in first
QUEUE_DEFAULT = 30
QUEUE_MAX = 100
BINARIES = ("spotify_player", "spotify-player")


def binary():
    for b in BINARIES:
        p = which(b)
        if p:
            return p
    return None


def run(args, timeout=TIMEOUT):
    """(returncode, stdout, stderr) as text, or (None, "", reason) when it could not run at all."""
    b = binary()
    if b is None:
        return None, "", "missing"
    try:
        r = subprocess.run([b] + args, capture_output=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return None, "", "timeout"
    except OSError as e:
        return None, "", str(e)
    return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")


def version():
    """(major, minor, patch) of the installed spotify_player, None when unknown."""
    rc, out, _ = run(["--version"], timeout=8)
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", out or "")
    return tuple(int(x) for x in m.groups()) if m else None


def classify(rc, err, out=""):
    """Turn a failed run into (state, message) in plain words."""
    if rc is None:
        if err == "missing":
            return "missing", "spotify_player is not installed. Install it (Arch: spotify-player) and run: spotify_player authenticate"
        if err == "timeout":
            return "error", "spotify_player did not answer in time. Check the network and try again."
        return "error", "spotify_player could not be started (%s)." % err.strip()[:120]
    text = (err + "\n" + out).lower()
    if "no active playback" in text or "no track currently playing" in text or "no playback" in text:
        return "idle", "Nothing is playing on your Spotify account right now."
    if "unrecognized subcommand" in text or "unexpected argument" in text or "invalid value" in text or "invalid subcommand" in text:
        return "old", "This spotify_player is too old for that. Lyrics need version 0.24.0 or newer."
    if any(k in text for k in ("authenticat", "credential", "login", "log in", "unauthorized", "401", "no cached", "token")):
        return "auth", "spotify_player is not logged in. Run in a terminal: spotify_player authenticate"
    line = ""
    for ln in (err or out).splitlines():
        if ln.strip():
            line = ln.strip()
    return "error", (line[:160] or "spotify_player failed.")


def fail(state, message, extra=None):
    d = {"ok": False, "state": state, "message": message}
    if extra:
        d.update(extra)
    return d


# ------------------------------------------------------------------ lyrics
SOURCES = ("auto", "local", "lrclib", "ovh", "spotify")
CONF = os.path.join(os.environ.get("HALCYON_DIR", os.path.expanduser("~/.config/Halcyon")), "music.conf")
LRCLIB = os.environ.get("HALCYON_LRCLIB_URL", "https://lrclib.net/api")
OVH = os.environ.get("HALCYON_OVH_URL", "https://api.lyrics.ovh/v1")
UA = "Halcyon-rice (lyrics panel)"
NET_TIMEOUT = 8


def read_source():
    try:
        with open(CONF, "r", encoding="utf-8") as f:
            for line in f:
                k, _, v = line.partition("=")
                if k.strip() == "LYRICS_SOURCE" and v.strip().strip('"') in SOURCES:
                    return v.strip().strip('"')
    except OSError:
        pass
    return "auto"


def write_source(v):
    keep = []
    try:
        with open(CONF, "r", encoding="utf-8") as f:
            keep = [l.rstrip("\n") for l in f if not l.strip().startswith("LYRICS_SOURCE=")]
    except OSError:
        pass
    os.makedirs(os.path.dirname(CONF), exist_ok=True)
    tmp = CONF + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("LYRICS_SOURCE=%s\n" % v)
        for l in keep:
            f.write(l + "\n")
    os.replace(tmp, CONF)


TS = re.compile(r"^\s*(\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]\s*)+")
META = re.compile(r"^\s*\[(ar|ti|al|au|by|offset|length|re|ve|id):.*\]\s*$", re.I)


def tidy(text):
    """Plain lines from lyrics text: LRC time stamps and tags removed, runs of blank lines folded into one, at most 600 lines."""
    out, blank = [], 0
    for ln in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if META.match(ln):
            continue
        ln = TS.sub("", ln).rstrip()
        if ln.strip():
            blank = 0
            out.append(ln)
        else:
            blank += 1
            if blank == 1 and out:
                out.append("")
    while out and not out[-1].strip():
        out.pop()
    return out[:600]


TS_ANY = re.compile(r"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]")


def tidy_synced(text):
    """LRC text with time stamps -> (lines, times) with times in seconds, one per line, or None when the text has no time stamps.
    Used by the lyrics widget to light the line that plays; the plain panel just shows the lines."""
    rows = []
    for ln in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if META.match(ln):
            continue
        head = TS.match(ln)
        if not head:
            continue
        body = ln[head.end():].rstrip()
        for m, sec, frac in TS_ANY.findall(head.group(0)):
            t = int(m) * 60 + int(sec) + (int(frac) / (10 ** len(frac)) if frac else 0.0)
            rows.append((t, body))
    if len(rows) < 2:
        return None
    rows.sort(key=lambda r: r[0])
    lines, times = [], []
    for t, body in rows:
        if not body.strip():
            if not lines or lines[-1] == "":
                continue
            body = ""
        lines.append(body)
        times.append(round(t, 2))
    while lines and not lines[-1].strip():
        lines.pop()
        times.pop()
    return (lines[:600], times[:600]) if lines else None


def first_artist(a):
    return re.split(r"\s*(?:,|;|&| feat\.? | ft\.? | x )\s*", a or "", maxsplit=1, flags=re.I)[0].strip()


def clean_title(t):
    """'Song - Remastered 2011' / 'Song (feat. X)' -> 'Song' (the plain title matches more often in a lyrics database)."""
    t = re.sub(r"\s*[-\u2013]\s*(remaster(ed)?|live|mono|stereo|single version|radio edit|deluxe|bonus).*$", "", t or "", flags=re.I)
    t = re.sub(r"\s*[(\[](feat|ft|with|remaster|live|mono|stereo|deluxe|bonus)[^)\]]*[)\]]", "", t, flags=re.I)
    return t.strip()


def http_json(url):
    """(status, parsed JSON or None). A missing song is status 404, a dead network / timeout is None."""
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=NET_TIMEOUT) as r:
            return r.status, json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        return e.code, None
    except (urllib.error.URLError, OSError, ValueError, TimeoutError):
        return None, None


def lyrics_local(meta):
    """A .lrc / .txt with the same name as the song file, when the player gave a file:// address."""
    u = meta.get("url") or ""
    if not u.startswith("file://"):
        return None
    base = os.path.splitext(urllib.parse.unquote(urllib.parse.urlparse(u).path))[0]
    for ext in (".lrc", ".txt"):
        try:
            with open(base + ext, "r", encoding="utf-8", errors="replace") as f:
                raw = f.read(200000)
        except OSError:
            continue
        sy = tidy_synced(raw) if ext == ".lrc" else None
        if sy:
            return "ok", sy[0], sy[1]
        lines = tidy(raw)
        if lines:
            return "ok", lines
    return None


def _norm(t):
    """lower case, letters and digits only: 'K/DA' ~ 'kda', 'NEVER GOING BACK' ~ 'nevergoingback'."""
    return re.sub(r"[^0-9a-z]+", "", (t or "").lower())


def lyrics_lrclib(meta):
    """-> ("ok", lines[, times]) | ("none", None) | ("net", None) | None (not enough to ask with).

    LRCLIB is asked several ways, because each misses songs the others find: the exact /get (with the album, then without it:
    the album or the length often differ by a second), the field search (track + artist), and the free search (q = "title
    artist"), which finds names like K/DA that the field search does not. A candidate WITH time stamps beats one without, then
    the closest length, so the lyrics widget gets the synced version whenever the site has one."""
    title, artist = clean_title(meta.get("title")), first_artist(meta.get("artist"))
    if not title:
        return None
    dur = meta.get("duration") or 0
    cands, seen, net_ok = [], set(), False

    def add(d):
        for x in (d if isinstance(d, list) else [d]):
            if isinstance(x, dict) and (x.get("syncedLyrics") or x.get("plainLyrics") or x.get("instrumental")):
                k = x.get("id") or (x.get("trackName"), x.get("artistName"), x.get("duration"))
                if k not in seen:
                    seen.add(k)
                    cands.append(x)

    def ask(path, q):
        nonlocal net_ok
        url = "%s/%s?%s" % (LRCLIB, path, urllib.parse.urlencode(q))
        st, d = http_json(url)
        if st in (429, 502, 503, 504):              # "the server is busy, retry in a moment": once, after a moment
            time.sleep(1.5)
            st, d = http_json(url)
        if st is not None and st < 500 and st != 429:
            net_ok = True
        if st == 200 and d is not None:
            add(d)
        return st

    base = {"track_name": title, "artist_name": artist}
    if dur:
        base["duration"] = str(int(round(dur)))
    if meta.get("album"):
        ask("get", dict(base, album_name=meta["album"]))
    if not any(c.get("syncedLyrics") for c in cands):
        ask("get", base)
    if not any(c.get("syncedLyrics") for c in cands):
        ask("search", {"track_name": title, "artist_name": artist})
    if not any(c.get("syncedLyrics") for c in cands):
        ask("search", {"q": (title + " " + artist).strip()})
    if not cands and not net_ok:
        return "net", None

    # keep the ones that really are this song (same title, the artist named), then: synced first, the closest length first
    nt, na = _norm(title), _norm(artist)
    def same(c):
        ct = _norm(clean_title(c.get("trackName") or ""))
        ca = _norm(c.get("artistName") or "")
        return (ct == nt or (nt and nt in ct) or (ct and ct in nt)) and (not na or na in ca or ca in na)
    good = [c for c in cands if same(c)] or cands
    good.sort(key=lambda c: (0 if c.get("syncedLyrics") else 1, abs((c.get("duration") or dur) - dur) if dur else 0))
    for c in good:
        if c.get("instrumental"):
            return "none", None
        sy = tidy_synced(c.get("syncedLyrics") or "")      # with times: the lyrics widget lights the line that plays
        if sy:
            return "ok", sy[0], sy[1]
        lines = tidy(c.get("plainLyrics") or c.get("syncedLyrics") or "")
        if lines:
            return "ok", lines
    return "none", None


def lyrics_ovh(meta):
    title, artist = clean_title(meta.get("title")), first_artist(meta.get("artist"))
    if not title or not artist:
        return None
    st, d = http_json("%s/%s/%s" % (OVH, urllib.parse.quote(artist, safe=""), urllib.parse.quote(title, safe="")))
    if st is None:
        return "net", None
    if st == 200 and isinstance(d, dict):
        lines = tidy(d.get("lyrics") or "")
        # a miss comes back as a French "sorry, we do not have these lyrics yet" text, not as a 404: never show that
        if lines and not re.search(r"nous n'avons pas encore les paroles|d[ée]sol[ée]", " ".join(lines[:2]), re.I) and len(lines) >= 3:
            return "ok", lines
    return "none", None


def lyrics_spotify():
    """The `spotify_player` command line, as before. Returns the old-style answer dict."""
    empty = {"title": "", "artist": "", "lines": []}
    rc, out, err = run(["lyrics"])
    if rc != 0:
        st, msg = classify(rc, err, out)
        if st == "old":
            v = version()
            if v is not None and v >= (0, 24, 0):      # the command exists: the refusal was about something else
                st, msg = "error", (err.strip().splitlines() or ["spotify_player failed."])[-1][:160]
        return fail(st, msg, empty)
    text = out.replace("\r\n", "\n").strip("\n")
    if not text.strip():
        return fail("error", "spotify_player returned nothing.", empty)
    # the first line is "Title - Artist, Artist", then an empty line, then the lyrics (or "Lyrics not found")
    head, sep, body = text.partition("\n\n")
    if not sep:
        head, body = text, ""
    title, artist = head.strip(), ""
    if " - " in head:
        title, _, artist = head.rpartition(" - ")      # a title can hold " - " ("Song - Remastered"), an artist list does not
    body = body.strip("\n")
    base = {"title": title.strip(), "artist": artist.strip(), "source": "spotify"}
    if body.strip() == "" or body.strip().lower() == "lyrics not found":
        return fail("none", "Spotify has no lyrics for this song.", dict(base, lines=[]))
    return {"ok": True, "state": "ok", "message": "", "lines": tidy(body), **base}


def meta_from_mpris():
    """What the player says it plays, for the terminal (`halcyon lyrics`: the panel passes this itself). Needs `playerctl`; {} without."""
    pc = which("playerctl")
    if not pc:
        return {}
    try:
        r = subprocess.run([pc, "metadata", "--format", "{{title}}\t{{artist}}\t{{album}}\t{{mpris:length}}\t{{xesam:url}}"],
                           capture_output=True, timeout=3, stdin=subprocess.DEVNULL)
    except (subprocess.TimeoutExpired, OSError):
        return {}
    if r.returncode != 0:
        return {}
    f = (r.stdout.decode("utf-8", "replace").rstrip("\n").split("\t") + [""] * 5)[:5]
    try:
        dur = int(f[3]) / 1000000.0 if f[3] else 0
    except ValueError:
        dur = 0
    return {k: v for k, v in (("title", f[0]), ("artist", f[1]), ("album", f[2]), ("duration", dur), ("url", f[4])) if v}


def estimate_times(lines, duration):
    """Plain lyrics only (no site has time stamps for the song): a start time per line, spread over the song by how long each
    line is (a long line takes longer to sing), leaving a short intro and outro. A guess, marked `approx`, never stored."""
    if duration < 30 or len(lines) < 4:
        return None
    w = [0.6 if not ln.strip() else 1.0 + len(ln.strip()) / 28.0 for ln in lines]
    start, end = duration * 0.07, duration * 0.95
    total, t, out = sum(w), start, []
    for x in w:
        out.append(round(t, 2))
        t += (end - start) * x / total
    return out


def get_lyrics(meta=None, source=None):
    """Try the chosen source (auto: local, lrclib, ovh, spotify_player) and answer with the first that has the song."""
    meta = meta or {}
    if not meta.get("title"):
        meta = meta_from_mpris()
    source = source or read_source()
    base = {"title": meta.get("title", ""), "artist": meta.get("artist", ""), "source": "", "lines": []}
    if source == "spotify":
        return lyrics_spotify()
    order = {"auto": ("local", "lrclib", "ovh", "spotify"), "local": ("local",), "lrclib": ("lrclib",), "ovh": ("ovh",)}[source]
    have_meta = bool(meta.get("title"))
    net_down = False
    for name in order:
        if name == "spotify":
            if which("spotify_player") or which("spotify-player"):
                d = lyrics_spotify()
                if d["ok"]:
                    return d
            continue
        r = {"local": lyrics_local, "lrclib": lyrics_lrclib, "ovh": lyrics_ovh}[name](meta)
        if r is None:
            continue
        if r[0] == "ok":
            out = {"ok": True, "state": "ok", "message": "", **dict(base, source=name, lines=r[1])}
            if len(r) > 2 and r[2]:
                out["times"] = r[2]            # seconds, one per line (synced lyrics only)
            elif meta.get("duration"):
                est = estimate_times(r[1], float(meta["duration"]))
                if est:
                    out["times"] = est         # no time stamps anywhere: an even guess, so a line can still be lit
                    out["approx"] = True       # (the panel and the widget say "timing estimated")
            return out
        if r[0] == "net":
            net_down = True
    if not have_meta and source != "auto":
        return fail("idle", "Nothing is playing, or the player does not say which song it is.", base)
    if not have_meta:
        # no title from the player: spotify_player may still know the account's song
        if which("spotify_player") or which("spotify-player"):
            return lyrics_spotify()
        return fail("idle", "Nothing is playing, or the player does not say which song it is.", base)
    if net_down:
        return fail("error", "The lyrics site could not be reached. Check the network and press R.", base)
    return fail("none", "No lyrics found for this song.", base)


# ------------------------------------------------------------------ queue
def ms_of(v):
    """Milliseconds from whatever the Spotify client library wrote: a number, or {secs, nanos}."""
    if isinstance(v, bool):
        return 0
    if isinstance(v, (int, float)):
        return max(0, int(v))
    if isinstance(v, dict):
        try:
            return max(0, int(v.get("secs", 0)) * 1000 + int(v.get("nanos", 0)) // 1000000)
        except (TypeError, ValueError):
            return 0
    return 0


def item_of(o):
    """{title, artist, ms, kind} from one queue entry (a track or a podcast episode), None when it is not an entry."""
    if not isinstance(o, dict):
        return None
    title = str(o.get("name") or "").strip()
    if not title:
        return None
    kind = "track"
    artist = ""
    arts = o.get("artists")
    if isinstance(arts, list):
        artist = ", ".join(str(a.get("name", "")).strip() for a in arts if isinstance(a, dict) and a.get("name"))
    if not artist and isinstance(o.get("show"), dict):          # a podcast episode
        kind = "episode"
        artist = str(o["show"].get("name") or "").strip()
    elif str(o.get("type", "")).lower() == "episode":
        kind = "episode"
    ms = ms_of(o.get("duration_ms", o.get("duration")))
    return {"title": title[:200], "artist": artist[:200], "ms": ms, "kind": kind}


# ------------------------------------------------------------------ ncspot
# ncspot (the other terminal Spotify client) has no queue in MPRIS and no "list the queue" command, but it has two things:
#   its socket ($XDG_RUNTIME_DIR/ncspot/ncspot.sock): the song that plays, as JSON, the moment you connect; it also takes ncspot
#     commands ("focus queue", "next" ...), one per line
#   userstate.cbor in its config folder: the whole queue and where in it you are, written by ncspot when it closes
# So the queue tab shows the live song and the queue as ncspot last saved it (marked as such while ncspot runs: songs you
# queued since then are only in ncspot itself, which "Open in ncspot" jumps to).
def ncspot_sock():
    """ncspot.sock in ncspot's runtime folder (a second ncspot names its own ncspot.<pid>.sock): the first one there, "" when none."""
    import glob
    d = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid(), "ncspot")
    socks = sorted(glob.glob(os.path.join(d, "ncspot*.sock")), key=lambda p: (p != os.path.join(d, "ncspot.sock"), p))
    return socks[0] if socks else ""


def ncspot_running():
    try:
        return subprocess.run(["pgrep", "-x", "ncspot"], capture_output=True, timeout=2).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def ncspot_mpris_now():
    """What ncspot plays, from MPRIS (playerctl -p ncspot), for when its socket is not there."""
    if not which("playerctl"):
        return None
    try:
        r = subprocess.run(["playerctl", "-p", "ncspot", "metadata", "--format", "{{title}}\t{{artist}}\t{{mpris:trackid}}"],
                           capture_output=True, timeout=2, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return None
    f = (r.stdout.decode("utf-8", "replace").rstrip("\n").split("\t") + ["", "", ""])[:3]
    if r.returncode != 0 or not f[0]:
        return None
    tid = f[2].rsplit("/", 1)[-1] if f[2] else ""
    return {"title": f[0], "artist": f[1], "id": tid}


def ncspot_send(line, read=False):
    """Send one command to a running ncspot (or just read its status); the status dict, True, or None when it is not running."""
    import socket
    path = ncspot_sock()
    if not path:
        return None
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.settimeout(1.5)
        c.connect(path)
    except OSError:
        return None
    try:
        if line:
            c.sendall((line.strip() + "\n").encode())
        if not read:
            return True
        buf = b""
        while b"\n" not in buf and len(buf) < 200000:
            part = c.recv(65536)
            if not part:
                break
            buf += part
        try:
            return json.loads(buf.split(b"\n")[0].decode("utf-8", "replace"))
        except ValueError:
            return {}
    except OSError:
        return {} if read else None
    finally:
        c.close()


def cbor(data):
    """A small CBOR reader (what ncspot's userstate.cbor uses): maps, arrays, text, numbers, true / false / null."""
    pos = 0

    def item():
        nonlocal pos
        b = data[pos]; pos += 1
        major, info = b >> 5, b & 31
        if info < 24:
            n = info
        elif info in (24, 25, 26, 27):
            k = 1 << (info - 24)
            n = int.from_bytes(data[pos:pos + k], "big"); pos += k
        elif info == 31:
            n = None
        else:
            raise ValueError("cbor")
        if major == 0:
            return n
        if major == 1:
            return -1 - n
        if major in (2, 3):
            if n is None:
                parts = []
                while data[pos] != 0xFF:
                    parts.append(item())
                pos += 1
                v = b"".join(p if isinstance(p, bytes) else p.encode() for p in parts)
            else:
                v = data[pos:pos + n]; pos += n
            return v.decode("utf-8", "replace") if major == 3 else v
        if major == 4:
            out = []
            if n is None:
                while data[pos] != 0xFF:
                    out.append(item())
                pos += 1
            else:
                for _ in range(n):
                    out.append(item())
            return out
        if major == 5:
            out = {}
            if n is None:
                while data[pos] != 0xFF:
                    k = item(); out[k] = item()
                pos += 1
            else:
                for _ in range(n):
                    k = item(); out[k] = item()
            return out
        if major == 6:
            return item()
        if major == 7:
            return {20: False, 21: True, 22: None, 23: None}.get(info, n)
        raise ValueError("cbor")
    return item()


def ncspot_item(p):
    """{title, artist, ms, kind} from one queue entry of ncspot ({"Track": {...}} or {"Episode": {...}})."""
    if not isinstance(p, dict) or not p:
        return None
    kind, o = next(iter(p.items()))
    if not isinstance(o, dict):
        return None
    title = str(o.get("title") or o.get("name") or "").strip()
    if not title:
        return None
    arts = o.get("artists")
    artist = ", ".join(str(a) for a in arts) if isinstance(arts, list) else str(o.get("publisher") or "")
    ms = o.get("duration") if isinstance(o.get("duration"), int) else 0
    return {"title": title[:200], "artist": artist[:200], "ms": max(0, ms), "kind": "episode" if kind == "Episode" else "track",
            "id": str(o.get("id") or "")}


def ncspot_queue(limit):
    live = ncspot_send("", read=True)                  # None: no socket to talk to
    if live is None and ncspot_running():
        live = {}                                      # it runs, its socket is not there: what plays comes from MPRIS
    now = None
    if live == {}:
        now = ncspot_mpris_now()
    if isinstance(live, dict) and isinstance(live.get("playable"), dict):
        pl = live["playable"]
        arts = pl.get("artists")
        now = {"title": str(pl.get("title") or ""), "artist": ", ".join(arts) if isinstance(arts, list) else "", "id": str(pl.get("id") or "")}
    items, cur = [], None
    try:
        with open(os.path.join(os.path.expanduser("~/.config/ncspot"), "userstate.cbor"), "rb") as f:
            st = cbor(f.read())
        qs = st.get("queuestate") or {}
        items = [x for x in (ncspot_item(p) for p in (qs.get("queue") or [])) if x]
        cur = qs.get("current_track")
    except (OSError, ValueError, IndexError, AttributeError, TypeError):
        pass
    # what comes after the song that plays (found by its id when ncspot runs, else where ncspot stopped)
    at = None
    if now and now["id"]:
        at = next((i for i, x in enumerate(items) if x["id"] == now["id"]), None)
    if at is None and isinstance(cur, int):
        at = cur
    nxt = items[at + 1:] if at is not None else items
    if now is None and at is not None and at < len(items):
        now = items[at]
    if live is None and not items:
        return None
    for x in nxt:
        x.pop("id", None)
    msg = ""
    if live is not None and nxt:
        msg = "As ncspot last saved it: songs queued since then are in ncspot."
    elif live is not None and not nxt:
        msg = "ncspot shares its queue when it closes; open it in ncspot to see what is next."
    return {"ok": True, "state": "ok", "message": msg, "source": "ncspot", "running": live is not None,
            "now": now and {"title": now["title"], "artist": now["artist"]}, "total": len(nxt), "items": nxt[:limit]}


def get_queue(limit=QUEUE_DEFAULT):
    """ncspot when it runs (or when spotify_player is not installed and ncspot has a saved queue), else spotify_player."""
    limit = max(1, min(QUEUE_MAX, limit))
    if ncspot_sock() or ncspot_running() or (binary() is None and which("ncspot")):
        d = ncspot_queue(limit)
        if d is not None:
            return d
        if binary() is None:
            return fail("idle", "ncspot is not running. Start it and play something: its queue shows here.",
                        {"now": None, "total": 0, "items": [], "source": "ncspot", "running": False})
    return get_queue_spotify_player(limit)


def get_queue_spotify_player(limit=QUEUE_DEFAULT):
    limit = max(1, min(QUEUE_MAX, limit))
    rc, out, err = run(["get", "key", "queue"])
    if rc != 0:
        st, msg = classify(rc, err, out)
        if st == "old":
            st, msg = "error", (err.strip().splitlines() or ["spotify_player failed."])[-1][:160]
        return fail(st, msg, {"now": None, "total": 0, "items": []})
    try:
        d = json.loads(out)
    except ValueError:
        return fail("error", "spotify_player's queue answer could not be read.", {"now": None, "total": 0, "items": []})
    if not isinstance(d, dict):
        return fail("error", "spotify_player's queue answer could not be read.", {"now": None, "total": 0, "items": []})
    now = item_of(d.get("currently_playing"))
    rows = d.get("queue")
    items = []
    if isinstance(rows, list):
        for o in rows:
            it = item_of(o)
            if it:
                items.append(it)
    total = len(items)
    if now is None and total == 0:
        return fail("idle", "The queue is empty and nothing is playing.", {"now": None, "total": 0, "items": []})
    return {"ok": True, "state": "ok", "message": "", "now": now and {"title": now["title"], "artist": now["artist"]},
            "total": total, "items": items[:limit]}


# ------------------------------------------------------------------ output
def clock(ms):
    s = ms // 1000
    return "%d:%02d" % (s // 60, s % 60)


def print_lyrics(d):
    if not d["ok"]:
        print(d["message"], file=sys.stderr)
        return 1
    head = d["title"] + ((" - " + d["artist"]) if d["artist"] else "")
    print(head + (("   [%s]" % d["source"]) if d.get("source") else ""))
    print()
    print("\n".join(d["lines"]))
    return 0


def print_queue(d):
    if not d["ok"]:
        print(d["message"], file=sys.stderr)
        return 1
    if d["now"]:
        print("Now: %s%s" % (d["now"]["title"], (" - " + d["now"]["artist"]) if d["now"]["artist"] else ""))
    for i, it in enumerate(d["items"], 1):
        print("%3d  %s%s  %s" % (i, it["title"], (" - " + it["artist"]) if it["artist"] else "", clock(it["ms"]) if it["ms"] else ""))
    if d["total"] > len(d["items"]):
        print("     ... and %d more" % (d["total"] - len(d["items"])))
    return 0


def status():
    print("lyrics source: %s  (halcyon-music.py source auto|local|lrclib|ovh|spotify)" % read_source())
    print("lyrics: local files, lrclib.net and api.lyrics.ovh need nothing installed; any player that speaks MPRIS works")
    b = binary()
    if b is None:
        print("spotify_player: not installed (optional: gives the Spotify queue and Spotify's own lyrics; Arch: spotify-player)")
        return 0
    v = version()
    print("spotify_player: %s (%s)" % (b, ".".join(map(str, v)) if v else "version unknown"))
    print("queue:  available")
    if v is None:
        print("spotify lyrics: unknown (could not read the version)")
    elif v >= (0, 24, 0):
        print("spotify lyrics: available")
    else:
        print("spotify lyrics: NOT available (needs 0.24.0 or newer)")
    return 0


def parse_meta(rest):
    """--title T --artist A --album B --duration SEC --url U  ->  dict (what the panel got from the player)."""
    meta, i = {}, 0
    while i < len(rest):
        a = rest[i]
        if a in ("--title", "--artist", "--album", "--duration", "--url") and i + 1 < len(rest):
            v = rest[i + 1]
            if a == "--duration":
                try:
                    v = float(v)
                except ValueError:
                    v = 0
                if v > 100000:                          # milliseconds, not seconds
                    v = v / 1000.0
            meta[a[2:]] = v
            i += 2
        else:
            i += 1
    return meta


def source_cmd(rest):
    if not rest:
        print(read_source())
        return 0
    if rest[0] not in SOURCES:
        print("halcyon-music.py: source must be one of: %s" % ", ".join(SOURCES), file=sys.stderr)
        return 2
    write_source(rest[0])
    print("lyrics source: %s" % rest[0])
    return 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]
    as_json = "json" in rest
    nums = [a for a in rest if a.isdigit()]
    if cmd == "lyrics":
        d = get_lyrics(parse_meta(rest))
        if as_json:
            print(json.dumps(d, ensure_ascii=False))
            return 0 if d["ok"] else 1
        return print_lyrics(d)
    if cmd == "source":
        return source_cmd(rest)
    if cmd == "queue":
        d = get_queue(int(nums[0]) if nums else QUEUE_DEFAULT)
        if as_json:
            print(json.dumps(d, ensure_ascii=False))
            return 0 if d["ok"] else 1
        return print_queue(d)
    if cmd == "status":
        return status()
    if cmd == "ncspot":                       # halcyon-music.py ncspot "focus queue": a command to the running ncspot
        return 0 if ncspot_send(" ".join(rest) or "focus queue") else 1
    print("halcyon-music.py: unknown command '%s' (lyrics | queue | source | status)" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
