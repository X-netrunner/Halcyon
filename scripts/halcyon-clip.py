#!/usr/bin/env python3
"""halcyon-clip.py: the data side of the clipboard history panel (>clipboard in the launcher).

  halcyon-clip.py json [N]     one line of JSON for the panel: the newest N entries (default 60, at most 300)
                               {"available": bool, "watching": bool, "total": int, "items": [{"id", "text", "image"}]}
  halcyon-clip.py copy ID      put entry ID back on the clipboard (wl-copy)
  halcyon-clip.py delete ID    forget one entry
  halcyon-clip.py clear        forget everything (cliphist wipe)
  halcyon-clip.py status       plain text, for a terminal

It adds no process and keeps no history of its own: the history is cliphist's, filled by the two `wl-paste --watch` watchers that
Settings > Startup & background > Clipboard history already starts (see scripts/clip-store.sh, which keeps password-manager
copies out). Everything here is a one-shot command that exits when done.
"""
import json
import re
import subprocess
import sys

TIMEOUT = 5
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


def cmd_json(n):
    items = raw_list()
    n = max(1, min(300, n))
    return {
        "available": have("cliphist") and have("wl-copy"),
        "watching": watching(),
        "total": len(items),
        "items": [entry(i, t) for i, t in items[:n]],
    }



def cmd_copy(i):
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
    fn = {"copy": cmd_copy, "delete": cmd_delete}.get(c)
    if c == "clear":
        code, msg = cmd_clear()
    elif fn and len(a) > 1:
        code, msg = fn(a[1])
    else:
        print("usage: halcyon-clip.py json [N] | copy ID | delete ID | clear | status", file=sys.stderr)
        return 2
    print(msg, file=sys.stderr if code else sys.stdout)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv))
