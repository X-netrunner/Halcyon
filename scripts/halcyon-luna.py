#!/usr/bin/env python3
"""halcyon-luna.py: the Luna window's sessions and answers (LunaCenter.qml, `>luna` in the launcher, `halcyon luna`).
Luna (the local assistant in ~/.local/bin/luna, see install.sh --luna) answers; this script keeps one saved conversation per
session so any of them can be opened again and continued where it stopped. Everything stays on this machine.

  halcyon-luna.py status                    is Luna installed, is the AI on                       (--json: one object)
  halcyon-luna.py list                      the saved sessions, newest first
  halcyon-luna.py show <id>                 one session's messages
  halcyon-luna.py new                       a new empty session, prints its id
  halcyon-luna.py rename <id> <title>       change a session's title
  halcyon-luna.py delete <id>               forget a session (its messages and Luna's memory of it; Luna's own long-term memory stays)
  halcyon-luna.py clear <id>                empty a session (its messages and Luna's memory of it) but keep the session
  halcyon-luna.py settings                  Luna's settings, as the terminal UI has them (categories, toggles, gates, API keys, models)
  halcyon-luna.py set <key> <json>          one setting by its key, e.g. set external.allow_halcyon_actions true
  halcyon-luna.py models                    what Ollama has and which model fills which role
  halcyon-luna.py voice                     is Luna able to speak (the voice files and packages), as JSON
  halcyon-luna.py speak                     read the text on stdin aloud in Luna's voice
  halcyon-luna.py stats                     how long her answers take (average, typical, per model)
  halcyon-luna.py model <name> [role]       /model: role model (default) | fast | deep | security
  halcyon-luna.py key <name>                store an API key: the key is read from STANDARD INPUT (never an argument), Luna keeps it in the
                                            OS keyring and luna.toml only refers to it
  halcyon-luna.py control <info|do|security> <action> [args...]   run a Halcyon control action yourself (the /status family)
  halcyon-luna.py chat <id> -- <text>       one turn: runs `luna --stdio --history <the session's file>`, so Luna sees the whole earlier
                                            conversation, and saves the exchange

--json (or --stream) prints one JSON object per line for the island:
  {"type": "activity", "kind": "step"|"tool_start"|"tool_end", "name", "summary", "ok", "secs"}   what Luna is doing right now
  {"type": "thinking", "delta"}   {"type": "reply", "text", "thinking", "model", "secs"}   {"type": "error", "error"}   {"type": "done"}
Sessions live in ~/.local/share/halcyon/luna/sessions/<id>.json (what the window shows) and <id>.history.json (Luna's rolling memory
of that conversation). Exit code 0 ok, 1 failed, 2 usage, 3 AI switched off / gaming mode / Luna missing.
"""
import contextlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
DATA = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local", "share"), "halcyon", "luna", "sessions")
GAMING_FLAG = "/dev/shm/halcyon-gamemode"
AI_OFF_FLAG = os.path.join(HOME, ".local", "state", "island", "ai-off")
MAX_TITLE = 60
PREFS = os.path.join(os.path.dirname(DATA), "prefs.json")
PREF_DEFAULTS = {"liveThink": False, "notifyDone": True, "speakReplies": False}      # the window's own switches (Luna's settings are luna.toml's)
MAX_TURNS = 400            # per session: the window shows the last ones, Luna's own window of memory is smaller anyway


class Fail(Exception):
    pass


class Off(Exception):
    """Exit 3: not something to retry (AI off, gaming mode, Luna not installed)."""


def luna_bin():
    p = os.environ.get("HALCYON_LUNA_BIN")
    if p:
        return p if os.access(p, os.X_OK) else None
    for c in (os.path.join(HOME, ".local", "bin", "luna"), shutil.which("luna")):
        if c and os.access(c, os.X_OK):
            return c
    return None


def ai_blocked():
    """Why Luna should not run now, or ''."""
    if os.path.lexists(GAMING_FLAG):
        return "Gaming mode is on: the AI is paused so the game keeps the GPU memory."
    if os.path.lexists(AI_OFF_FLAG):
        return "AI features are switched off (Settings > Performance > AI features)."
    return ""


def valid_id(sid):
    return re.fullmatch(r"[0-9]{10,14}-[0-9a-f]{4}", sid or "") is not None


def path(sid, hist=False):
    if not valid_id(sid):
        raise Fail("not a session id")
    return os.path.join(DATA, sid + (".history.json" if hist else ".json"))


def read(p, default):
    try:
        with open(p, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def write(p, obj):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False)
    os.replace(tmp, p)


def new_session():
    sid = f"{int(time.time() * 1000)}-{os.urandom(2).hex()}"
    write(path(sid), {"id": sid, "title": "", "created": int(time.time()), "updated": int(time.time()), "turns": []})
    return sid


def list_sessions():
    out = []
    try:
        names = os.listdir(DATA)
    except OSError:
        return out
    for n in names:
        sid = n[:-5] if n.endswith(".json") and not n.endswith(".history.json") else ""
        if not valid_id(sid):
            continue
        s = read(path(sid), None)
        if not isinstance(s, dict):
            continue
        turns = s.get("turns", [])
        last = next((t.get("text", "") for t in reversed(turns) if t.get("role") == "luna"), "")
        out.append({"id": sid, "title": s.get("title") or "New chat", "updated": s.get("updated", 0), "count": len(turns),
                    "preview": " ".join(last.split())[:90]})
    return sorted(out, key=lambda x: -x["updated"])


def title_of(text):
    t = " ".join(text.split())
    return (t[: MAX_TITLE - 1].rstrip() + "…") if len(t) > MAX_TITLE else t


def luna_call(msg, want, timeout=40):
    """Start `luna --stdio`, send one message, return the first reply whose type is in `want` ({"type": "error"} included).
    Settings changes do not need a conversation, so the history file is a probe file that is never written."""
    b = luna_bin()
    if b is None:
        raise Off("Luna is not installed. Run install.sh --luna, or build it from github.com/X-netrunner/LUNA-AI.")
    os.makedirs(DATA, exist_ok=True)
    proc = subprocess.Popen([b, "--stdio", "--history", os.path.join(DATA, ".probe.history.json")], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1, start_new_session=True)
    deadline = time.time() + timeout
    try:
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()
        for line in proc.stdout:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev.get("type") in want or ev.get("type") == "error":
                return ev
            if time.time() > deadline:
                break
        raise Fail("Luna did not answer.")
    finally:
        with contextlib.suppress(Exception):
            proc.stdin.write(json.dumps({"type": "quit"}) + "\n")
            proc.stdin.close()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(Exception):
                os.killpg(proc.pid, signal.SIGTERM)


def cmd_clear(sid):
    p = path(sid)
    s = read(p, None)
    if not isinstance(s, dict):
        raise Fail("no such session")
    s["turns"] = []
    s["updated"] = int(time.time())
    write(p, s)
    with contextlib.suppress(OSError):
        os.remove(path(sid, hist=True))


def luna_has_stdio(b):
    """Luna builds before the window existed have no --stdio mode: say so instead of failing on the first message."""
    try:
        r = subprocess.run([b, "--help"], capture_output=True, text=True, timeout=10, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return "--stdio" in (r.stdout + r.stderr)


def cmd_prefs(rest):
    p = dict(PREF_DEFAULTS)
    cur = read(PREFS, {})
    if isinstance(cur, dict):
        p.update({k: v for k, v in cur.items() if k in PREF_DEFAULTS and isinstance(v, bool)})
    if len(rest) >= 2:
        if rest[0] not in PREF_DEFAULTS:
            raise Fail("no such option: " + rest[0])
        p[rest[0]] = rest[1].lower() in ("1", "true", "yes", "on")
        write(PREFS, p)
    return {"type": "prefs", **p}


def cmd_stats():
    """How long her answers take: from the `secs` saved with every answer, over all chats (the newest 400 answers)."""
    rows = []
    for s in list_sessions():
        d = read(path(s["id"]), None)
        for t in (d or {}).get("turns", []):
            if t.get("role") == "luna" and not t.get("bad") and (t.get("secs") or 0) > 0:
                rows.append((t.get("ts", 0), float(t["secs"]), shorten_model(t.get("model", ""))))
    rows.sort(reverse=True)
    rows = rows[:400]
    if not rows:
        return {"type": "stats", "n": 0, "avg": 0, "median": 0, "models": []}
    secs = sorted(r[1] for r in rows)
    by = {}
    for _, sec, m in rows:
        by.setdefault(m or "?", []).append(sec)
    models = sorted(({"name": m, "n": len(v), "avg": round(sum(v) / len(v), 1)} for m, v in by.items()), key=lambda x: -x["n"])
    return {"type": "stats", "n": len(rows), "avg": round(sum(secs) / len(secs), 1), "median": round(secs[len(secs) // 2], 1), "models": models}


def shorten_model(n):
    n = str(n or "")
    return n[:-7] if n.endswith(":latest") else n


def cmd_gate():
    """The no-refusal switch as data: luna --security-status prints it. Changing it needs the developer key, in a terminal."""
    b = luna_bin()
    if b is None:
        raise Off("Luna is not installed.")
    r = subprocess.run([b, "--security-status"], capture_output=True, text=True, timeout=20)
    out = {"type": "gate", "state": "", "requested": False, "key": False, "effective": False}
    for line in r.stdout.splitlines():
        m = re.match(r"\s*(.*?)\s*:\s*(.*)$", line)
        if not m:
            continue
        k, v = m.group(1).lower(), m.group(2).strip()
        if out["state"] == "" and k.startswith("security tier"):
            out["state"] = v
        elif k.startswith("requested"):
            out["requested"] = v == "true"
        elif k.startswith("developer key"):
            out["key"] = v == "true"
        elif k.startswith("effective"):
            out["effective"] = v == "true"
            break                       # the second block is the capability switch
    return out


def cmd_status():
    b = luna_bin()
    why = ai_blocked()
    old = b is not None and not luna_has_stdio(b)
    return {"installed": b is not None, "path": b or "", "blocked": why, "old": old, "ok": b is not None and not old and not why,
            "sessions": len(list_sessions())}


def emit(o, as_json):
    if as_json:
        print(json.dumps(o, ensure_ascii=False), flush=True)


def cmd_chat(sid, text, as_json):
    p = path(sid)
    s = read(p, None)
    if not isinstance(s, dict):
        raise Fail("no such session")
    text = text.strip()
    if not text:
        raise Fail("Ask something.")
    b = luna_bin()
    if b is None:
        raise Off("Luna is not installed. Run install.sh --luna, or build it from github.com/X-netrunner/LUNA-AI.")
    why = ai_blocked()
    if why:
        raise Off(why)
    s["turns"].append({"role": "you", "text": text, "ts": int(time.time())})
    if not s.get("title"):
        s["title"] = title_of(text)
    s["updated"] = int(time.time())
    write(p, s)
    proc = subprocess.Popen([b, "--stdio", "--history", path(sid, hist=True)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, bufsize=1, start_new_session=True)

    def stop(*_):
        with contextlib.suppress(Exception):
            os.killpg(proc.pid, signal.SIGTERM)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    proc.stdin.write(json.dumps({"type": "turn", "text": text}) + "\n")
    proc.stdin.flush()
    tools, reply, err = [], None, ""
    pend, last = "", time.time()        # the reasoning arrives a word at a time: sent in pieces of about 0.2 s

    def flush():
        nonlocal pend, last
        if pend:
            emit({"type": "thinking", "delta": pend}, as_json)
            pend = ""
        last = time.time()
    for line in proc.stdout:
        try:
            ev = json.loads(line)
        except ValueError:
            continue                    # a tool that printed something of its own
        kind = ev.get("type")
        if kind == "thinking":
            pend += str(ev.get("delta", ""))
            if time.time() - last > 0.2:
                flush()
        elif kind == "activity":
            flush()
            if ev.get("kind") == "tool_start":
                tools.append({"name": ev.get("name", ""), "summary": ev.get("summary", "")[:200]})
            emit(ev, as_json)
        elif kind == "reply":
            flush()
            reply = ev
            emit(ev, as_json)
            break
        elif kind == "error":
            flush()
            err = str(ev.get("error", "Luna failed."))
            emit(ev, as_json)
            break
    with contextlib.suppress(Exception):
        proc.stdin.write(json.dumps({"type": "quit"}) + "\n")
        proc.stdin.close()
    try:
        proc.wait(timeout=8)
    except subprocess.TimeoutExpired:
        stop()
    s = read(p, s)
    if reply is not None:
        s["turns"].append({"role": "luna", "text": reply.get("text", ""), "model": reply.get("model", ""), "secs": reply.get("secs", 0),
                           "thinking": reply.get("thinking") or "", "tools": tools, "ts": int(time.time())})
    else:
        s["turns"].append({"role": "luna", "text": err or "Stopped.", "bad": True, "tools": tools, "ts": int(time.time())})
        if not err:
            emit({"type": "error", "error": "Stopped."}, as_json)
    s["turns"] = s["turns"][-MAX_TURNS:]
    s["updated"] = int(time.time())
    write(p, s)
    emit({"type": "done"}, as_json)
    return 0 if reply is not None else 1


def main(argv):
    as_json = "--json" in argv or "--stream" in argv
    args = [a for a in argv[1:] if a not in ("--json", "--stream")]
    if not args:
        print(__doc__.strip())
        return 2
    cmd, rest = args[0], args[1:]
    try:
        if cmd == "status":
            st = cmd_status()
            print(json.dumps(st) if as_json else ("Luna is ready." if st["ok"] else (st["blocked"] or ("This Luna is too old for the window: update it." if st["old"] else "Luna is not installed."))))
        elif cmd == "list":
            items = list_sessions()
            print(json.dumps({"sessions": items}) if as_json else "\n".join(f"{i['id']}  {i['title']}" for i in items))
        elif cmd == "show" and rest:
            s = read(path(rest[0]), None)
            if s is None:
                raise Fail("no such session")
            print(json.dumps(s, ensure_ascii=False) if as_json else "\n".join(f"{t['role']}: {t['text']}" for t in s["turns"]))
        elif cmd == "new":
            sid = new_session()
            print(json.dumps({"id": sid}) if as_json else sid)
        elif cmd == "rename" and len(rest) >= 2:
            s = read(path(rest[0]), None)
            if s is None:
                raise Fail("no such session")
            s["title"] = title_of(" ".join(rest[1:])) or s.get("title", "")
            write(path(rest[0]), s)
        elif cmd == "delete" and rest:
            for p in (path(rest[0]), path(rest[0], hist=True)):
                with contextlib.suppress(OSError):
                    os.remove(p)
        elif cmd == "clear" and rest:
            cmd_clear(rest[0])
        elif cmd == "settings":
            print(json.dumps(luna_call({"type": "settings_get"}, {"settings"})))
        elif cmd == "pref":
            print(json.dumps(cmd_prefs(rest)))
        elif cmd == "voice":
            print(json.dumps(luna_call({"type": "voice_status"}, {"voice"})))
        elif cmd == "speak":
            text = sys.stdin.readline().strip()[:4000]   # on stdin (one line): an answer in an argument would show in `ps`
            if not text:
                raise Fail("Nothing to read.")
            print(json.dumps(luna_call({"type": "speak", "text": text}, {"spoke"}, timeout=240)))
        elif cmd == "stats":
            print(json.dumps(cmd_stats()))
        elif cmd == "gate":
            print(json.dumps(cmd_gate()))
        elif cmd == "models":
            print(json.dumps(luna_call({"type": "models"}, {"models"})))
        elif cmd == "set" and len(rest) >= 2:
            raw = " ".join(rest[1:])
            try:
                val = json.loads(raw)
            except ValueError:
                val = raw
            print(json.dumps(luna_call({"type": "setting_set", "key": rest[0], "value": val}, {"saved"})))
        elif cmd == "model" and rest:
            print(json.dumps(luna_call({"type": "model_set", "name": rest[0], "role": rest[1] if len(rest) > 1 else "model"}, {"saved"})))
        elif cmd == "key" and len(rest) == 1:
            value = sys.stdin.readline().rstrip("\n")      # from stdin: a key in an argument would show in `ps`
            print(json.dumps(luna_call({"type": "key_set", "name": rest[0], "value": value}, {"key_saved"})))
        elif cmd == "control" and len(rest) >= 2 and rest[0] in ("info", "do", "security"):
            ctl = os.path.join(os.path.dirname(os.path.abspath(__file__)), "halcyon-control.py")
            r = subprocess.run([sys.executable, ctl, *rest], capture_output=True, text=True, timeout=300)
            print(json.dumps({"type": "control", "ok": r.returncode == 0, "text": (r.stdout + r.stderr).strip()}))
        elif cmd == "chat" and rest:
            sep = rest.index("--") if "--" in rest else len(rest)
            text = " ".join(rest[sep + 1:]) if sep < len(rest) else " ".join(rest[1:])
            return cmd_chat(rest[0], text, as_json)
        else:
            print(__doc__.strip(), file=sys.stderr)
            return 2
    except Off as e:
        if as_json:
            print(json.dumps({"type": "error", "error": str(e), "off": True}), flush=True)
        else:
            print(str(e), file=sys.stderr)
        return 3
    except Fail as e:
        if as_json:
            print(json.dumps({"type": "error", "error": str(e)}), flush=True)
        else:
            print(str(e), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
