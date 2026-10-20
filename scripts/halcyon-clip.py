#!/usr/bin/env python3
"""halcyon-clip.py: the data side of the clipboard history panel (>clipboard in the launcher).

  halcyon-clip.py json [N]     one line of JSON for the panel: the newest N entries (default 60, at most 300)
                               {"available": bool, "watching": bool, "total": int, "items": [{"id", "text", "image"}]}
  halcyon-clip.py copy ID      put entry ID back on the clipboard (wl-copy)
  halcyon-clip.py delete ID    forget one entry (a pinned one is unpinned)
  halcyon-clip.py pin ID       keep a text entry on top of the list, even after the history is cleared
  halcyon-clip.py unpin ID     let a pinned entry go (ID is the "p..." one the list shows)
  halcyon-clip.py clear        forget everything (cliphist wipe); pinned entries stay
  halcyon-clip.py status       plain text, for a terminal

Pins are the one thing kept here: the TEXT of an entry you pinned, in ~/.local/state/island/clip-pins.json (only you can read it;
pictures cannot be pinned). Do not pin a password.
It adds no process and keeps no history of its own: the history is cliphist's, filled by the two `wl-paste --watch` watchers that
Settings > Startup & background > Clipboard history already starts (see scripts/clip-store.sh, which keeps password-manager
copies out). Everything here is a one-shot command that exits when done.
"""
import hashlib
import json
import os
import re
import subprocess
import sys

TIMEOUT = 5
STATE = os.environ.get("HALCYON_STATE") or os.path.join(os.path.expanduser("~"), ".local", "state", "island")
PINS = os.path.join(STATE, "clip-pins.json")
PIN_MAX = 20000          # characters kept per pin
PIN_LIMIT = 30           # pins kept
IMG = re.compile(r"^\[\[\s*binary data\b", re.I)


def have(cmd):
    from shutil import which
    return which(cmd) is not None


def run(cmd, data=None, timeout=TIMEOUT):
    try:
        return subprocess.run(cmd, input=data, capture_output=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None


def raw_list():
    """[(id, preview)] newest first, [] when cliphist is missing or empty."""
    if not have("cliphist"):
        return []
    r = run(["cliphist", "list"])
    if r is None or r.returncode != 0:
        return []
    out = []
    for line in r.stdout.decode("utf-8", "replace").splitlines():
        i, sep, text = line.partition("\t")
        if not sep or not i.strip().isdigit():
            continue
        out.append((i.strip(), text))
    return out


def watching():
    r = run(["pgrep", "-f", r"wl-pas[t].*--watch.*(clip-store|cliphist)"])
    return r is not None and r.returncode == 0


def entry(i, text):
    img = bool(IMG.match(text))
    t = " ".join(text.split())
    if len(t) > 400:
        t = t[:400] + "..."
    return {"id": i, "text": t, "image": img}


def read_pins():
    """[text, ...] oldest pin first; [] when there is none or the file is unreadable."""
    try:
        with open(PINS, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return []
    return [t for t in d if isinstance(t, str) and t.strip()] if isinstance(d, list) else []


def write_pins(pins):
    try:
        os.makedirs(STATE, exist_ok=True)
        tmp = PINS + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(pins, f, ensure_ascii=False)
        os.replace(tmp, PINS)
        return True
    except OSError:
        return False


def pin_id(text):
    return "p" + hashlib.sha1(text.encode("utf-8")).hexdigest()[:10]


def cmd_json(n):
    items = raw_list()
    n = max(1, min(300, n))
    pins = read_pins()
    pinned = []
    for t in reversed(pins):                       # the newest pin on top
        e = entry(pin_id(t), t)
        e["pin"] = True
        pinned.append(e)
    heads = set(p["text"][:80] for p in pinned)
    rest = [entry(i, t) for i, t in items[:n]]
    rest = [e for e in rest if e["image"] or e["text"][:80] not in heads]   # a pinned text is not listed twice
    return {
        "available": have("cliphist") and have("wl-copy"),
        "watching": watching(),
        "total": len(items),
        "items": pinned + rest,
    }


def cmd_pin(i):
    if not i.isdigit():
        return 2, "halcyon-clip: the id must be a number"
    if not have("cliphist"):
        return 1, "halcyon-clip: cliphist is not installed"
    r = run(["cliphist", "decode"], data=(i + "\t").encode())
    if r is None or r.returncode != 0 or not r.stdout:
        return 1, "halcyon-clip: that entry is gone"
    if b"\x00" in r.stdout[:512]:
        return 1, "halcyon-clip: only text can be pinned"
    text = r.stdout.decode("utf-8", "replace")
    if IMG.match(text) or not text.strip():
        return 1, "halcyon-clip: only text can be pinned"
    text = text[:PIN_MAX]
    pins = [p for p in read_pins() if p != text] + [text]
    return (0, "pinned") if write_pins(pins[-PIN_LIMIT:]) else (1, "halcyon-clip: could not save the pin")


def cmd_unpin(i):
    pins = read_pins()
    keep = [p for p in pins if pin_id(p) != i]
    if len(keep) == len(pins):
        return 1, "halcyon-clip: that pin is gone"
    return (0, "unpinned") if write_pins(keep) else (1, "halcyon-clip: could not save")


def copy_text(text):
    try:
        p = subprocess.Popen(["wl-copy"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        p.stdin.write(text.encode("utf-8"))
        p.stdin.close()
        p.wait(timeout=TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return 1, "halcyon-clip: wl-copy failed"
    return 0, "copied"



def cmd_copy(i):
    if i.startswith("p"):
        if not have("wl-copy"):
            return 1, "halcyon-clip: wl-clipboard is needed"
        for t in read_pins():
            if pin_id(t) == i:
                return copy_text(t)
        return 1, "halcyon-clip: that pin is gone"
    if not i.isdigit():
        return 2, "halcyon-clip: the id must be a number"
    if not (have("cliphist") and have("wl-copy")):
        return 1, "halcyon-clip: cliphist and wl-clipboard are needed"
    r = run(["cliphist", "decode"], data=(i + "\t").encode())
    if r is None or r.returncode != 0 or not r.stdout:
        return 1, "halcyon-clip: that entry is gone"
    # wl-copy forks into the background to serve the clipboard; give it the bytes on stdin and do not wait for the paste
    try:
        p = subprocess.Popen(["wl-copy"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        p.stdin.write(r.stdout)
        p.stdin.close()
        p.wait(timeout=TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return 1, "halcyon-clip: wl-copy failed"
    return 0, "copied"


def cmd_delete(i):
    if i.startswith("p"):
        return cmd_unpin(i)
    if not i.isdigit():
        return 2, "halcyon-clip: the id must be a number"
    if not have("cliphist"):
        return 1, "halcyon-clip: cliphist is not installed"
    r = run(["cliphist", "delete"], data=(i + "\t").encode())
    return (0, "deleted") if r is not None and r.returncode == 0 else (1, "halcyon-clip: could not delete")


def cmd_clear():
    if not have("cliphist"):
        return 1, "halcyon-clip: cliphist is not installed"
    r = run(["cliphist", "wipe"])
    return (0, "history cleared") if r is not None and r.returncode == 0 else (1, "halcyon-clip: could not clear")


def main(argv):
    a = argv[1:]
    c = a[0] if a else "status"
    if c == "json":
        try:
            n = int(a[1]) if len(a) > 1 else 60
        except ValueError:
            n = 60
        print(json.dumps(cmd_json(n), ensure_ascii=False))
        return 0
    if c == "status":
        d = cmd_json(5)
        if not d["available"]:
            print("clipboard history: cliphist and/or wl-clipboard are not installed")
            return 1
        print("clipboard history: %d entries, watcher %s" % (d["total"], "running" if d["watching"] else "OFF (Settings > Startup & background)"))
        return 0
    fn = {"copy": cmd_copy, "delete": cmd_delete, "pin": cmd_pin, "unpin": cmd_unpin}.get(c)
    if c == "clear":
        code, msg = cmd_clear()
    elif fn and len(a) > 1:
        code, msg = fn(a[1])
    else:
        print("usage: halcyon-clip.py json [N] | copy ID | delete ID | pin ID | unpin ID | clear | status", file=sys.stderr)
        return 2
    print(msg, file=sys.stderr if code else sys.stdout)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv))
