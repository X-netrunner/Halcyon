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
  halcyon-luna.py lessons                   what Luna learned from her mistakes (--json: {"lessons": [...]})
  halcyon-luna.py forget-lesson <n|all>     drop lesson number n (from `lessons`), or all of them
  halcyon-luna.py learn                     (internal) reflect on one exchange read from stdin as JSON and keep the lesson, if any

Learning from mistakes: after a turn where a tool failed, or when your next message corrects her ("no, that's wrong", "you
didn't ...", "try again"), a background job asks her fast model for ONE general rule that would have avoided it. Rules are kept in
~/.local/share/halcyon/luna/lessons.json and copied into her long-term memory as "Lesson learned: ..." facts, which she recalls
by meaning on every turn; her constitution (config/luna/constitution.md, set as agent.constitution_path in luna.toml unless you
use your own) tells her to follow them. Similar lessons are merged, at most 40 are kept, and the AI master switch stops it all.

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
        return "AI features are switched off (Settings > AI > AI features)."
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


# ---- learning from mistakes ---------------------------------------------------------------------------------------------------
LESSONS = os.path.join(os.path.dirname(DATA), "lessons.json")
LUNA_MEM = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local", "share"), "luna", "permanent_memory.json")
LUNA_TOML = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "luna", "luna.toml")
CONSTITUTION = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "config", "luna", "constitution.md")
LESSON_PREFIX = "Lesson learned: "
MAX_LESSONS = 40
OLLAMA = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")
if not OLLAMA.startswith("http"):
    OLLAMA = "http://" + OLLAMA

# Words that mean "that was wrong", at the start of the message or as a phrase anywhere in it. "no thanks" / "no problem" are not
# corrections, and a long message that only contains "no" somewhere is not one either.
_CORR_START = re.compile(r"^\s*(no+|nope|nah|wrong|incorrect|not (quite|really|that|this|what)|that'?s (not|wrong|incorrect)|"
                         r"that is (not|wrong|incorrect)|stop|wait|ugh|why did you|you (didn'?t|did not|forgot|missed|broke|ignored))\b",
                         re.IGNORECASE)
_CORR_ANY = re.compile(r"\b(not what i (asked|wanted|meant|said)|that'?s wrong|you got it wrong|(didn'?t|doesn'?t|does not|did not|still (doesn'?t|isn'?t|not)) work|"
                       r"try again|i (said|asked|told you)|still (wrong|broken)|undo (that|it)|you (forgot|missed|ignored)|wrong (file|one|answer|app|setting|folder|path))\b",
                       re.IGNORECASE)
_NOT_CORR = re.compile(r"^\s*no+[\s,.!]*(thanks|thank you|problem|worries|need|rush|hurry)\b", re.IGNORECASE)


def looks_like_correction(text):
    t = (text or "").strip()
    if not t or _NOT_CORR.search(t):
        return False
    return bool(_CORR_START.search(t)) or (len(t) < 400 and bool(_CORR_ANY.search(t)))


def _words(t):
    return {w for w in re.findall(r"[a-z0-9_]{3,}", (t or "").lower())
            if w not in {"the", "and", "for", "with", "that", "this", "when", "before", "after", "then", "from", "into", "use", "luna"}}


def _similar(a, b):
    wa, wb = _words(a), _words(b)
    return bool(wa and wb) and len(wa & wb) / len(wa | wb) >= 0.55


def load_lessons():
    d = read(LESSONS, {})
    items = d.get("lessons") if isinstance(d, dict) else None
    return [x for x in (items or []) if isinstance(x, dict) and str(x.get("text", "")).strip()]


def save_lessons(items):
    items = sorted(items, key=lambda x: (x.get("hits", 1), x.get("ts", 0)), reverse=True)[:MAX_LESSONS]
    os.makedirs(os.path.dirname(LESSONS), exist_ok=True)
    write(LESSONS, {"lessons": items})
    sync_luna_memory(items)
    return items


def sync_luna_memory(items):
    """Luna's long-term facts get exactly the current lessons (category "lesson"); her other facts are left as they are."""
    try:
        with open(LUNA_MEM) as f:
            facts = json.load(f)
        if not isinstance(facts, list):
            return
    except FileNotFoundError:
        facts = []
    except (OSError, ValueError):
        return                                      # unreadable: never overwrite what we cannot read
    keep = [x for x in facts if not (isinstance(x, dict) and x.get("category") == "lesson")]
    day = time.strftime("%Y-%m-%d")
    for it in items:
        keep.append({"content": LESSON_PREFIX + it["text"], "added": it.get("day", day), "category": "lesson"})
    os.makedirs(os.path.dirname(LUNA_MEM), exist_ok=True)
    tmp = LUNA_MEM + ".halcyon.tmp"
    with open(tmp, "w") as f:
        json.dump(keep, f, indent=2, ensure_ascii=False)
    os.replace(tmp, LUNA_MEM)


def add_lesson(text, kind, tool=""):
    text = " ".join(str(text).split()).strip().strip('"').strip()
    if text.lower().startswith(LESSON_PREFIX.lower()):
        text = text[len(LESSON_PREFIX):].strip()
    if not (15 <= len(text) <= 240) or re.search(r"(api[_ -]?key|password|token|secret)\s*[:=]", text, re.IGNORECASE):
        return None
    # a lesson is advice about HOW to work, never a payload: no links, no commands to run, nothing destructive. The reflected text
    # includes tool output and web pages Luna read, so a page must not be able to plant a "rule" in her long-term memory.
    if re.search(r"https?://|www\.|`|\$\(|\|\s*(sh|bash)\b|\b(rm\s+-|sudo\s|curl\s|wget\s|chmod\s|mkfs|dd\s+if=|base64|ignore (all|previous|your) )", text, re.IGNORECASE):
        return None
    # and allow-listed: plain words and ordinary punctuation only, at most 30 words, no domain names
    if not re.fullmatch(r"[A-Za-z0-9 ,.;:'()/%+_-]+", text) or len(text.split()) > 30 \
            or re.search(r"\b[a-z0-9-]+\.(com|net|org|io|sh|ru|xyz|dev|app|co|me|info)\b", text, re.IGNORECASE):
        return None
    items = load_lessons()
    now = int(time.time())
    for it in items:
        if _similar(it["text"], text):
            it["hits"] = int(it.get("hits", 1)) + 1
            it["ts"] = now
            if len(text) < len(it["text"]):         # the shorter wording of the same rule wins
                it["text"] = text
            save_lessons(items)
            return it
    it = {"text": text, "kind": kind, "tool": tool, "ts": now, "day": time.strftime("%Y-%m-%d"), "hits": 1}
    items.append(it)
    save_lessons(items)
    return it


def _toml_value(key):
    """One `key = "value"` from luna.toml (first match, any section)."""
    try:
        with open(LUNA_TOML) as f:
            for line in f:
                m = re.match(r'\s*' + re.escape(key) + r'\s*=\s*"([^"]*)"', line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return ""


def ensure_constitution():
    """Point Luna at Halcyon's constitution (deciding, failing well, following her lessons), unless luna.toml names one already."""
    if not os.path.isfile(CONSTITUTION) or not os.path.isfile(LUNA_TOML):
        return
    try:
        with open(LUNA_TOML) as f:
            txt = f.read()
    except OSError:
        return
    if re.search(r"(?m)^\s*constitution_path\s*=", txt):
        return
    line = 'constitution_path = "%s"   # Halcyon: deciding, failing well, following her lessons (remove to use the shipped one)\n' % CONSTITUTION
    if re.search(r"(?m)^\[agent\]\s*$", txt):
        txt = re.sub(r"(?m)^(\[agent\]\s*\n)", lambda m: m.group(1) + line, txt, count=1)
    else:
        txt = txt.rstrip("\n") + "\n\n[agent]\n" + line
    tmp = LUNA_TOML + ".halcyon.tmp"
    with open(tmp, "w") as f:
        f.write(txt)
    os.replace(tmp, LUNA_TOML)


REFLECT = ("You review one exchange of Luna, a local desktop assistant on Arch Linux (desktop: Halcyon), to learn from her mistake. "
           "Write ONE rule for Luna that says what to do INSTEAD next time: name the right tool, app, place or step. "
           "If a later tool call succeeded, the rule says to use that approach first. If the user corrected her, the rule says what "
           "the user meant by such a request. General enough for similar requests, concrete, an instruction, at most 25 words. "
           "Examples: 'For Halcyon settings like the bar, use halcyon_do instead of hyprctl commands.' "
           "'When the user says notes, open the Halcyon notes window, not a text file.' "
           "No personal data, secrets, file contents or quotes. Only if the failure was outside Luna's control (no network, the "
           "user changed their mind) answer NONE. Output exactly one line: LESSON: <rule>   or   NONE")


def reflect_model():
    return os.environ.get("HALCYON_LUNA_REFLECT_MODEL") or _toml_value("model") or _toml_value("fast_model") or "qwen3.5:4b"


def ask_reflection(payload, timeout=90):
    import urllib.request
    parts = []
    if payload.get("kind") == "correction":
        parts.append("Earlier request: " + str(payload.get("prev_user", ""))[:600])
        parts.append("Luna answered: " + str(payload.get("prev_reply", ""))[:900])
        if payload.get("prev_tools"):
            parts.append("Tools Luna used: " + "; ".join(payload["prev_tools"])[:400])
        parts.append("The user then said (a correction): " + str(payload.get("user", ""))[:600])
    else:
        parts.append("Request: " + str(payload.get("user", ""))[:600])
        parts.append("Tool calls that FAILED: " + "; ".join(payload.get("failures", []))[:600])
        if payload.get("tools"):
            parts.append("All tool calls, in order: " + "; ".join(payload["tools"])[:500])
        parts.append("Luna's final answer: " + str(payload.get("reply", ""))[:900])
    body = json.dumps({"model": reflect_model(), "stream": False, "think": False, "options": {"temperature": 0.2, "num_predict": 120},
                       "messages": [{"role": "system", "content": REFLECT}, {"role": "user", "content": "\n".join(parts)}]}).encode()
    req = urllib.request.Request(OLLAMA.rstrip("/") + "/api/chat", data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        out = json.load(r).get("message", {}).get("content", "")
    out = re.sub(r"(?s)<think>.*?</think>", "", out).strip()
    for line in out.splitlines():
        m = re.match(r"\s*\**LESSON\**\s*:\s*(.+)", line, re.IGNORECASE)
        if m:
            return m.group(1).strip()
    return None


def cmd_learn():
    if ai_blocked():
        return 3
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 2
    try:
        lesson = ask_reflection(payload)
    except Exception:
        return 1                                    # Ollama down or slow: nothing learned this time, nothing broken
    if lesson:
        add_lesson(lesson, payload.get("kind", "tool"), (payload.get("failed_tools") or [""])[0])
    return 0


def spawn_learning(payload):
    """Reflect in the background: the window gets its answer now, the lesson lands a few seconds later."""
    with contextlib.suppress(Exception):
        p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "learn"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, text=True, start_new_session=True)
        p.stdin.write(json.dumps(payload))
        p.stdin.close()


def learning_payload(s, text, tools, failed, reply_text):
    """What to reflect on after this turn, or None. `s` is the session BEFORE Luna's answer to `text` was added."""
    turns = s.get("turns", [])
    if looks_like_correction(text):
        # the turns end with [..., you(prev), luna(prev), you(text)]
        prev_luna = turns[-2] if len(turns) >= 2 and turns[-2].get("role") == "luna" else None
        prev_you = turns[-3] if len(turns) >= 3 and turns[-3].get("role") == "you" else None
        if prev_luna and prev_you:
            return {"kind": "correction", "user": text, "prev_user": prev_you.get("text", ""), "prev_reply": prev_luna.get("text", ""),
                    "prev_tools": ["%s(%s)" % (t.get("name", ""), t.get("summary", "")[:80]) for t in prev_luna.get("tools", [])]}
    if failed and reply_text:
        return {"kind": "tool", "user": text, "reply": reply_text, "failed_tools": [f["name"] for f in failed],
                "failures": ["%s(%s)" % (f["name"], f.get("summary", "")[:100]) for f in failed],
                "tools": ["%s%s" % (t.get("name", ""), "" if t.get("ok", True) else " [failed]") for t in tools]}
    return None


def cmd_lessons(as_json):
    items = load_lessons()
    if as_json:
        print(json.dumps({"lessons": items}, ensure_ascii=False))
    elif not items:
        print("Luna has not learned anything from a mistake yet.")
    else:
        for i, it in enumerate(items, 1):
            print("%2d. %s%s" % (i, it["text"], "  (x%d)" % it["hits"] if it.get("hits", 1) > 1 else ""))
    return 0


def cmd_forget_lesson(which):
    items = load_lessons()
    if which == "all":
        items = []
    else:
        try:
            n = int(which)
        except ValueError:
            raise Fail("forget-lesson takes a number from `lessons`, or all")
        if not 1 <= n <= len(items):
            raise Fail("no lesson %d" % n)
        items = sorted(items, key=lambda x: (x.get("hits", 1), x.get("ts", 0)), reverse=True)
        del items[n - 1]
    save_lessons(items)
    return 0


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
    with contextlib.suppress(Exception):
        ensure_constitution()
    before = dict(s, turns=list(s["turns"]))
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
            elif ev.get("kind") == "tool_end" and ev.get("ok") is False:
                for t in reversed(tools):               # the last started call of that name is the one that ended
                    if t["name"] == ev.get("name", "") and "ok" not in t:
                        t["ok"] = False
                        break
                else:
                    tools.append({"name": ev.get("name", ""), "summary": "", "ok": False})
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
    failed = [t for t in tools if t.get("ok") is False]
    lp = learning_payload(before, text, tools, failed, reply.get("text", "") if reply is not None else "")
    if lp:
        spawn_learning(lp)
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
        elif cmd == "lessons":
            return cmd_lessons(as_json)
        elif cmd == "forget-lesson" and rest:
            return cmd_forget_lesson(rest[0])
        elif cmd == "learn":
            return cmd_learn()
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
