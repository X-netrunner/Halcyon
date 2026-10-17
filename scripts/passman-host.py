#!/usr/bin/env python3
"""passman-host.py: the native-messaging helper behind the browser's "save this login?" question.

The Halcyon passman browser extension (browser/passman-ext) starts this through the browser. It speaks the browser's
length-prefixed JSON on stdin/stdout. Only the extension may call it (the browser checks the extension id listed in
the host manifest that `passman browser` writes).  It NEVER sends a stored password back: it answers new / changed /
known / never, and saves what the extension hands it into the same vault `passman` uses.
"""
import importlib.util
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("halcyon_pass", os.path.join(HERE, "halcyon-pass.py"))
hp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hp)

NEVER_FILE = os.path.join(hp.STATE_DIR, "passman-never.json")


def read_msg():
    raw = sys.stdin.buffer.read(4)
    if len(raw) < 4:
        return None
    (n,) = struct.unpack("=I", raw)
    if n > 1_000_000:
        return None
    return json.loads(sys.stdin.buffer.read(n).decode("utf-8"))


def send(obj):
    data = json.dumps(obj).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("=I", len(data)) + data)
    sys.stdout.buffer.flush()


def never_list():
    try:
        with open(NEVER_FILE) as f:
            return set(json.load(f))
    except (OSError, ValueError):
        return set()


def text(v, limit):
    return v.strip()[:limit] if isinstance(v, str) else ""


def service_for(entries, host, user):
    """One entry per site; a second account on the same site becomes 'host (user)'."""
    key = hp.find_exact(entries, host)
    if key and entries[key].get("user", "") and user and entries[key]["user"] != user:
        return f"{host} ({user})"
    return host


def handle(m):
    kind = m.get("type")
    host = text(m.get("host"), 253).lower()
    if not host:
        return {"ok": False, "error": "no host"}
    if kind == "never":
        os.makedirs(hp.STATE_DIR, mode=0o700, exist_ok=True)
        with hp.locked():                       # two tabs saying "never" at once must not lose one of them
            tmp = NEVER_FILE + ".tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)     # 0600 from the start, not after the write
            with os.fdopen(fd, "w") as f:
                json.dump(sorted(never_list() | {host}), f)
            os.replace(tmp, NEVER_FILE)
        return {"ok": True}
    user, pwd = text(m.get("user"), 256), m.get("pass") if isinstance(m.get("pass"), str) else ""
    if not pwd:
        return {"ok": False, "error": "no password"}
    if kind == "check":
        if host in never_list():
            return {"ok": True, "status": "never"}
        entries = hp.load_vault().get("entries", {})
        key = hp.find_exact(entries, service_for(entries, host, user))
        if not key:
            return {"ok": True, "status": "new"}
        return {"ok": True, "status": "known" if entries[key].get("pass") == pwd else "changed"}
    if kind == "save":
        entries = hp.load_vault().get("entries", {})
        return {"ok": True, "result": hp.store_entry(service_for(entries, host, user), user, pwd)}
    return {"ok": False, "error": "unknown request"}


def main():
    while True:
        try:
            m = read_msg()
            if m is None:
                return
            send(handle(m))
        except hp.VaultError as e:
            send({"ok": False, "error": str(e).splitlines()[0]})
        except Exception as e:                       # never die silently: the extension would just see a closed pipe
            send({"ok": False, "error": type(e).__name__})


if __name__ == "__main__":
    main()
