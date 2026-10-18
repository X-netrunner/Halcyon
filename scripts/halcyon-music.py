#!/usr/bin/env python3
"""halcyon-music.py: the data side of the lyrics and queue panel (media page > Lyrics / Queue, >lyrics and >queue in the launcher).

  halcyon-music.py lyrics [json]   lyrics of the song that is playing on your Spotify account
  halcyon-music.py queue [json] [N]  what plays next (default 30, at most 100)
  halcyon-music.py status          plain text: is spotify_player installed, how new, can it do lyrics / queue

With `json` (what the panel uses) the answer is ONE line of JSON, always, also when something is wrong:
  lyrics: {"ok": bool, "state": str, "message": str, "title": str, "artist": str, "lines": [str]}
  queue:  {"ok": bool, "state": str, "message": str, "now": {"title","artist"}|null, "total": int, "items": [{"title","artist","ms","kind"}]}
Without `json` it prints plain text for a terminal. Exit code 0 when it worked, 1 when it did not.

`state` says what went wrong, so the panel can say it in words: ok | missing (spotify_player not installed) | old (installed, too
old for lyrics) | auth (not logged in) | idle (nothing is playing) | none (no lyrics for this song) | error.

Where the data comes from: the `spotify_player` command line (`spotify_player lyrics`, `spotify_player get key queue`). It asks YOUR
Spotify account (the session spotify_player already has), so there is no third-party lyrics site and no key to set up. The lyrics
command exists since spotify_player 0.24.0; the queue command is older. Both work with the Spotify app, a phone or spotify_player
itself as the player: the queue and the "now playing" song are the account's, not one program's. When spotify_player is not running,
the command starts a short-lived client of its own just for this one answer.

It adds no process: every call is a one-shot command that exits when done, and Halcyon only runs it while the panel is open (and
once more when the song changes). Nothing is stored: no cache, no file, no log.
"""
import json
import re
import subprocess
import sys
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
def get_lyrics():
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
    base = {"title": title.strip(), "artist": artist.strip()}
    if body.strip() == "" or body.strip().lower() == "lyrics not found":
        return fail("none", "Spotify has no lyrics for this song.", dict(base, lines=[]))
    lines = [ln.rstrip() for ln in body.split("\n")]
    while lines and not lines[-1].strip():
        lines.pop()
    # long blank runs (instrumental breaks) become one blank line
    out_lines, blank = [], 0
    for ln in lines:
        if ln.strip():
            blank = 0
            out_lines.append(ln)
        else:
            blank += 1
            if blank == 1:
                out_lines.append("")
    return {"ok": True, "state": "ok", "message": "", "lines": out_lines[:600], **base}


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


def get_queue(limit=QUEUE_DEFAULT):
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
    print(head)
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
    b = binary()
    if b is None:
        print("spotify_player: not installed (Arch: spotify-player)")
        return 1
    v = version()
    print("spotify_player: %s (%s)" % (b, ".".join(map(str, v)) if v else "version unknown"))
    print("queue:  available")
    if v is None:
        print("lyrics: unknown (could not read the version; try `halcyon lyrics`)")
    elif v >= (0, 24, 0):
        print("lyrics: available")
    else:
        print("lyrics: NOT available (needs 0.24.0 or newer)")
    return 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]
    as_json = "json" in rest
    nums = [a for a in rest if a.isdigit()]
    if cmd == "lyrics":
        d = get_lyrics()
        if as_json:
            print(json.dumps(d, ensure_ascii=False))
            return 0 if d["ok"] else 1
        return print_lyrics(d)
    if cmd == "queue":
        d = get_queue(int(nums[0]) if nums else QUEUE_DEFAULT)
        if as_json:
            print(json.dumps(d, ensure_ascii=False))
            return 0 if d["ok"] else 1
        return print_queue(d)
    if cmd == "status":
        return status()
    print("halcyon-music.py: unknown command '%s' (lyrics | queue | status)" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
