#!/usr/bin/env python3
"""halcyon-notes.py: Fast, lightweight notes manager for Halcyon.
Usage:
  notes : <text>          -> add a note (e.g. notes : hi i am srijan)
  notes <text>            -> add a note
  notes add "<text>"      -> add a note
  notes list              -> display all notes
  notes del <index_or_id> -> delete a note
  notes pin <index_or_id> -> toggle pin status
  notes done <idx_or_id>  -> toggle completed status
  notes clear             -> remove completed notes
  notes json              -> output raw JSON for QML widgets
Tasks (a note with a job and, optionally, a time to be reminded at):
  notes task <idx_or_id>          -> toggle "this note is a task"
  notes due <idx_or_id> <when>    -> remind me at <when>: 18:00 | 6pm | +30m | +2h | tomorrow 09:00 | 2026-10-20 14:30 | none
  notes tasks                     -> list the tasks only
  notes sort <idx_or_id>          -> let the local Ollama model decide if it is a task (what Enter does when Settings > Notes is on)
  notes due <idx_or_id> later     -> "later today": a few gentle nudges during the rest of today (every NOTES_NUDGE_HOURS hours,
                                     only between NOTES_NUDGE_FROM and NOTES_NUDGE_TO o'clock, at most NOTES_NUDGE_MAX times, then it stops)
  notes think <idx_or_id>         -> run the AI over this note again (it shows its short comment under the note)
  notes accept / dismiss <id>     -> answer "Make this a task?" (ask mode)
  notes remind-check              -> what the timer runs: one notification for every task whose time has come
  notes conf | set KEY VALUE      -> NOTES_AI 0|1 , NOTES_OVERVIEW 0|1 , NOTES_AI_MODE ask|auto , NOTES_NUDGE_HOURS 1..12 , NOTES_NUDGE_MAX 1..12 ,
                                     NOTES_NUDGE_FROM 0..23 , NOTES_NUDGE_TO 1..24   (~/.config/Halcyon/notes.conf)
"""
import contextlib
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HOME = os.path.expanduser("~")
RICE = os.environ.get("HALCYON_DIR", os.path.join(HOME, ".config", "Halcyon"))
STATE_DIR = os.path.join(HOME, ".local", "state", "island")
NOTES_FILE = os.path.join(STATE_DIR, "notes.json")
CONF_FILE = os.path.join(RICE, "notes.conf")
UNIT_DIR = os.path.join(HOME, ".config", "systemd", "user")
DUE_TIMER = "halcyon-notes-due.timer"
DUE_SERVICE = "halcyon-notes-due.service"

def load_notes():
    if not os.path.isfile(NOTES_FILE):
        return []
    try:
        with open(NOTES_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            if isinstance(data, list):
                return data
    except Exception:
        pass
    return []

@contextlib.contextmanager
def locked():
    """One writer at a time. The notes menu, the widget and a `notes ...` typed in a terminal can all change the file
    within the same moment; each one reads the list, changes it and writes it back, so without a lock the second
    writer silently erased what the first one had just done."""
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(NOTES_FILE + ".lock", "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lk, fcntl.LOCK_UN)

def save_notes(notes):
    os.makedirs(STATE_DIR, exist_ok=True)
    # a temp file of its own (the fixed name ".tmp" was shared by every writer), then an atomic swap
    fd, temp_file = tempfile.mkstemp(prefix="notes.", suffix=".tmp", dir=STATE_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(notes, f, indent=2, ensure_ascii=False)
        os.chmod(temp_file, 0o600)
        os.replace(temp_file, NOTES_FILE)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(temp_file)
        raise

def add_note(text):
    text = text.strip()
    if text.startswith(":"):
        text = text[1:].strip()
    if not text:
        print("[!] Note cannot be empty.")
        return False
    notes = load_notes()
    now = time.time()
    dt = time.strftime("%Y-%m-%d %H:%M", time.localtime(now))
    # two notes added in the same millisecond used to get the same id, and then "delete / pin / done" hit the first one
    ids = {n.get("id") for n in notes if isinstance(n, dict)}
    nid = int(now * 1000)
    while f"n_{nid}" in ids:
        nid += 1
    item = {
        "id": f"n_{nid}",
        "text": text,
        "created": now,
        "date": dt,
        "pinned": False,
        "done": False
    }
    notes.insert(0, item)
    save_notes(notes)
    print(f"\033[1;32m✓\033[0m Note added: \033[1m{text}\033[0m")
    refresh_ui()
    # sorting is a separate background process: saving is already done and never waits for the model
    cf = read_conf()
    if (cf["NOTES_AI"] == "1" or cf["NOTES_OVERVIEW"] == "1") and len(text) <= 6000:
        with contextlib.suppress(Exception):
            subprocess.Popen([sys.executable, os.path.abspath(__file__), "sort", item["id"]], start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return True

def list_notes():
    notes = load_notes()
    if not notes:
        print("\033[38;5;244mNo notes yet. Add one with: notes : <your text>\033[0m")
        return
    print("\033[1;35m📝 Halcyon Notes\033[0m")
    print("──────────────────────────────────────────────────")
    for i, n in enumerate(notes, 1):
        pin = "\033[1;33m★ \033[0m" if n.get("pinned") else "  "
        status = "\033[38;5;242m[✓] \033[9m" if n.get("done") else "\033[1m"
        reset = "\033[0m"
        date = n.get("date", "")
        task = "\033[38;5;214m☑ \033[0m" if n.get("task") else ""
        due = f" \033[38;5;214m⏰ {due_text(n['due'])}\033[0m" if n.get("due") else (" \033[38;5;214m⏰ later today\033[0m" if n.get("later") else "")
        print(f"{i:2d}. {pin}{task}{status}{n.get('text', '')}{reset}{due} \033[38;5;240m({date})\033[0m")
    print("──────────────────────────────────────────────────")
    print("\033[38;5;244mCommands: notes del <num> | notes pin <num> | notes done <num>\033[0m")

def del_note(arg):
    notes = load_notes()
    idx = None
    try:
        idx = int(arg) - 1
        if 0 <= idx < len(notes):
            removed = notes.pop(idx)
            save_notes(notes)
            print(f"\033[1;31m✗\033[0m Deleted: \"{removed.get('text')}\"")
            return
    except ValueError:
        pass
    for i, n in enumerate(notes):
        if n.get("id") == arg:
            removed = notes.pop(i)
            save_notes(notes)
            print(f"\033[1;31m✗\033[0m Deleted: \"{removed.get('text')}\"")
            return
    print(f"[!] Note not found: {arg}")

def pin_note(arg):
    notes = load_notes()
    target = None
    try:
        idx = int(arg) - 1
        if 0 <= idx < len(notes):
            target = notes[idx]
    except ValueError:
        for n in notes:
            if n.get("id") == arg:
                target = n
                break
    if target:
        target["pinned"] = not target.get("pinned", False)
        # Move pinned notes to top
        notes.sort(key=lambda x: (not x.get("pinned", False), -x.get("created", 0)))
        save_notes(notes)
        state = "Pinned" if target["pinned"] else "Unpinned"
        print(f"\033[1;33m★\033[0m {state}: \"{target.get('text')}\"")
    else:
        print(f"[!] Note not found: {arg}")

def done_note(arg):
    notes = load_notes()
    target = None
    try:
        idx = int(arg) - 1
        if 0 <= idx < len(notes):
            target = notes[idx]
    except ValueError:
        for n in notes:
            if n.get("id") == arg:
                target = n
                break
    if target:
        target["done"] = not target.get("done", False)
        save_notes(notes)
        state = "Completed" if target["done"] else "Uncompleted"
        print(f"✓ {state}: \"{target.get('text')}\"")
    else:
        print(f"[!] Note not found: {arg}")

def clear_done():
    notes = load_notes()
    rem = [n for n in notes if not n.get("done")]
    cleared = len(notes) - len(rem)
    save_notes(rem)
    print(f"✓ Cleared {cleared} completed note(s).")

# =====================================================================================================================
#  Tasks: "call mom at 6" -> a task with a time, and a notification when the time comes
# =====================================================================================================================
CONF_DEFAULTS = {"NOTES_AI": "0", "NOTES_OVERVIEW": "0", "NOTES_AI_MODE": "ask", "NOTES_NUDGE_HOURS": "3", "NOTES_NUDGE_MAX": "4",
                 "NOTES_NUDGE_FROM": "9", "NOTES_NUDGE_TO": "21", "NOTES_MODEL": ""}
DEFAULT_MODEL = "qwen2.5:3b-instruct"      # what the notes AI was tested and tuned on (fast, keeps facts and tenses straight)
CONF_RANGE = {"NOTES_NUDGE_HOURS": (1, 12), "NOTES_NUDGE_MAX": (1, 12), "NOTES_NUDGE_FROM": (0, 23), "NOTES_NUDGE_TO": (1, 24)}

def read_conf():
    c = dict(CONF_DEFAULTS)
    try:
        with open(CONF_FILE, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    c[k.strip()] = v.strip().strip('"')
    except OSError:
        pass
    if c["NOTES_AI"] != "1":
        c["NOTES_AI"] = "0"
    if c["NOTES_OVERVIEW"] != "1":
        c["NOTES_OVERVIEW"] = "0"
    if c["NOTES_AI_MODE"] not in ("ask", "auto"):
        c["NOTES_AI_MODE"] = "ask"
    for k, (lo, hi) in CONF_RANGE.items():
        try:
            c[k] = str(min(hi, max(lo, int(c[k]))))
        except ValueError:
            c[k] = CONF_DEFAULTS[k]
    if int(c["NOTES_NUDGE_TO"]) <= int(c["NOTES_NUDGE_FROM"]):        # an empty window would mean "never": use the default one
        c["NOTES_NUDGE_FROM"], c["NOTES_NUDGE_TO"] = CONF_DEFAULTS["NOTES_NUDGE_FROM"], CONF_DEFAULTS["NOTES_NUDGE_TO"]
    return c

def write_conf(c):
    os.makedirs(os.path.dirname(CONF_FILE), exist_ok=True)
    keep = []
    try:                       # lines that are not ours stay as they are
        with open(CONF_FILE, "r", encoding="utf-8") as f:
            keep = [l.rstrip("\n") for l in f if not re.match(r"\s*(NOTES_AI(_MODE)?|NOTES_OVERVIEW|NOTES_MODEL|NOTES_NUDGE_(HOURS|MAX|FROM|TO))=", l)]
    except OSError:
        pass
    fd, tmp = tempfile.mkstemp(prefix="notes.conf.", dir=os.path.dirname(CONF_FILE))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        for k in CONF_DEFAULTS:
            f.write(f"{k}={c[k]}\n")
        for l in keep:
            f.write(l + "\n")
    os.replace(tmp, CONF_FILE)

def ollama_host():
    h = os.environ.get("OLLAMA_HOST", "127.0.0.1:11434")
    return h if h.startswith("http") else "http://" + h

def ollama_up():
    """Is Ollama listening? (a quarter of a second at most, so Settings never waits on it)"""
    import socket
    from urllib.parse import urlparse
    u = urlparse(ollama_host())
    try:
        with socket.create_connection((u.hostname or "127.0.0.1", u.port or 11434), timeout=0.25):
            return True
    except OSError:
        return False

def model_name():
    """The model the notes AI asks: HALCYON_AI_MODEL, else NOTES_MODEL (notes set NOTES_MODEL <name>; empty = not set), else the one
    `ai` and the advisor use (MODEL= in ai-advisor.conf), else qwen2.5:3b-instruct."""
    if os.environ.get("HALCYON_AI_MODEL"):
        return os.environ["HALCYON_AI_MODEL"].strip()
    own = read_conf().get("NOTES_MODEL", "").strip()
    if own:
        return own
    try:
        with open(os.path.join(RICE, "ai-advisor.conf"), "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MODEL="):
                    return line.split("=", 1)[1].strip().strip('"\'') or DEFAULT_MODEL
    except OSError:
        pass
    return DEFAULT_MODEL

DAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

def parse_when(spec, now=None):
    """'18:00' '6pm' '6:30 pm' '+30m' '+2h' '+1d' 'tomorrow' 'tomorrow 09:00' '2026-10-20 14:30' 'none' -> epoch, or None for none.
    A time with no day means the next time it happens. Raises ValueError for anything else."""
    now = time.time() if now is None else now
    s = (spec or "").strip().lower()
    if s in ("", "none", "off", "clear", "no", "-"):
        return None
    m = re.fullmatch(r"\+\s*(\d+)\s*(m|min|h|hr|d)", s)
    if m:
        n = int(m.group(1))
        return now + n * {"m": 60, "min": 60, "h": 3600, "hr": 3600, "d": 86400}[m.group(2)]
    lt = time.localtime(now)
    day = None                                     # (y, m, d) when the text names a day
    rest = s
    m = re.match(r"(\d{4})-(\d{1,2})-(\d{1,2})\s*(.*)", rest)
    if m:
        day = (int(m.group(1)), int(m.group(2)), int(m.group(3)))
        rest = m.group(4)
    elif rest.startswith("tomorrow"):
        t = time.localtime(now + 86400)
        day = (t.tm_year, t.tm_mon, t.tm_mday)
        rest = rest[8:].strip()
    elif rest.startswith("today") or rest.startswith("tonight"):
        day = (lt.tm_year, lt.tm_mon, lt.tm_mday)
        rest = rest.split(None, 1)[1] if " " in rest else ""
    else:
        for i, name in enumerate(DAYS):
            if rest.startswith(name[:3]):
                ahead = (i - lt.tm_wday) % 7 or 7
                t = time.localtime(now + ahead * 86400)
                day = (t.tm_year, t.tm_mon, t.tm_mday)
                rest = rest.split(None, 1)[1] if " " in rest else ""
                break
    hh, mm = 9, 0                                   # a day with no time = 09:00
    timed = False
    if rest:
        m = re.fullmatch(r"(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?", rest)
        if not m:
            raise ValueError(f"cannot read a time from: {spec}")
        hh, mm = int(m.group(1)), int(m.group(2) or 0)
        ap = (m.group(3) or "").replace(".", "")
        if ap == "pm" and hh < 12:
            hh += 12
        if ap == "am" and hh == 12:
            hh = 0
        if hh > 23 or mm > 59:
            raise ValueError(f"not a time: {spec}")
        timed = True
    elif day is None:
        raise ValueError(f"cannot read a time from: {spec}")
    if day is None:                                 # only a time: today if it is still ahead, else tomorrow
        t = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, hh, mm, 0, 0, 0, -1))
        return t if t > now + 5 else t + 86400
    return time.mktime((day[0], day[1], day[2], hh, mm, 0, 0, 0, -1))

def find_note(notes, arg):
    try:
        i = int(arg) - 1
        if 0 <= i < len(notes):
            return notes[i]
    except ValueError:
        pass
    for n in notes:
        if n.get("id") == arg:
            return n
    return None

def due_text(ts):
    d = time.localtime(ts)
    t0 = time.localtime()
    days = (time.mktime((d.tm_year, d.tm_mon, d.tm_mday, 0, 0, 0, 0, 0, -1)) - time.mktime((t0.tm_year, t0.tm_mon, t0.tm_mday, 0, 0, 0, 0, 0, -1))) / 86400
    hm = time.strftime("%H:%M", d)
    return ("Today " + hm) if round(days) == 0 else ("Tomorrow " + hm) if round(days) == 1 else time.strftime("%-d %b ", d) + hm

# ---- "later today": a few gentle nudges instead of one reminder at a clock time
def day_window(t, conf):
    """(start of the day, nudge window start, nudge window end, end of the day) as epochs, for the local day of t."""
    lt = time.localtime(t)
    base = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
    nxt = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday + 1, 0, 0, 0, 0, 0, -1))
    return base, base + int(conf["NOTES_NUDGE_FROM"]) * 3600, min(base + int(conf["NOTES_NUDGE_TO"]) * 3600, nxt), nxt

def start_later(n, conf, now=None):
    """Mark a note as "later today": the first nudge comes NOTES_NUDGE_HOURS from now (never before the window opens), then the same
    gap again, at most NOTES_NUDGE_MAX times, only inside the window, and all of it ends at midnight. Said after the window closed
    for the day = it means tomorrow. A note with a clock time (due) and "later" exclude each other."""
    now = time.time() if now is None else now
    base, fr, to, end = day_window(now, conf)
    if now >= to:                                         # "later" at 22:00 = tomorrow
        base, fr, to, end = day_window(end + 3600, conf)
    first = max(now + int(conf["NOTES_NUDGE_HOURS"]) * 3600, fr)
    n["task"] = True
    n.pop("due", None)
    n.pop("reminded", None)
    n["later"] = end
    n["nudges"] = 0
    n["nudge_at"] = first if first < to else None         # None: too late today for even one nudge
    return n["nudge_at"]

def clear_later(n):
    for k in ("later", "nudge_at", "nudges"):
        n.pop(k, None)

def refresh_ui():
    """Tell the notes window (if the island is running) to read the file again."""
    try:
        subprocess.run(["quickshell", "-p", os.path.join(RICE, "quickshell", "island"), "ipc", "call", "island", "refreshNotes"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1)
    except Exception:
        pass

def notify(title, body, icon="appointment-soon"):
    if shutil.which("notify-send"):
        with contextlib.suppress(Exception):
            subprocess.run(["notify-send", "-a", "Halcyon", "-i", icon, title, body],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)

def pending_due(notes):
    return [n for n in notes if isinstance(n, dict) and n.get("task") and n.get("due") and not n.get("done") and not n.get("reminded")]

def pending_nudge(notes):
    return [n for n in notes if isinstance(n, dict) and n.get("task") and n.get("nudge_at") and not n.get("done")]

def sync_timer(notes=None):
    """The once-a-minute timer exists only while a task with a time is waiting. Nothing is installed or running for people
    who never use it."""
    if not shutil.which("systemctl"):
        return
    notes = load_notes() if notes is None else notes
    pending = bool(pending_due(notes) or pending_nudge(notes))
    wants = os.path.join(UNIT_DIR, "timers.target.wants", DUE_TIMER)       # the link `enable` makes
    if not pending and not os.path.lexists(wants):
        return                                                            # not on, nothing to switch off: no systemctl at all
    def sc(*a):
        try:
            return subprocess.run(["systemctl", "--user", *a], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8).returncode
        except Exception:
            return 1
    if pending:
        fresh = False
        for u in (DUE_SERVICE, DUE_TIMER):
            dst = os.path.join(UNIT_DIR, u)
            src = os.path.join(RICE, "systemd", u)
            if not os.path.exists(dst) and os.path.exists(src):
                os.makedirs(UNIT_DIR, exist_ok=True)
                shutil.copyfile(src, dst)
                fresh = True
        if fresh:
            sc("daemon-reload")
        if sc("is-active", "--quiet", DUE_TIMER) != 0:
            sc("enable", "--now", DUE_TIMER)
    elif sc("is-enabled", "--quiet", DUE_TIMER) == 0 or sc("is-active", "--quiet", DUE_TIMER) == 0:
        sc("disable", "--now", DUE_TIMER)

# ---- the model decides: task or plain note? (only when Settings > Notes is on; never in the way of saving)
TIME_WORDS = re.compile(r"\d|today|tonight|tomorrow|morning|evening|afternoon|noon|midnight|monday|tuesday|wednesday|thursday|friday|saturday|sunday|\bin an? (hour|minute)|next week", re.I)

def keep_alive():
    """How long Ollama keeps the model in memory after a note was sorted. With Settings > Performance > "Aggressive Memory Freeing"
    on (the default in Low / Medium resource use) it is let go after 10 s; otherwise it stays 2 minutes so a few notes in a row are quick."""
    try:
        with open(os.path.join(STATE_DIR, "settings.json"), "r", encoding="utf-8") as f:
            lazy = (json.load(f).get("opt") or {}).get("lazyLoad", True)
    except (OSError, ValueError, AttributeError):
        lazy = True
    return "10s" if lazy is not False else "2m"

def ask_model(text):
    """-> {"task": bool, "when": str|None, "later": bool, "why": str (the model's one-sentence summary of the note)}, or None when Ollama is not there / answers nonsense. Never raises."""
    import urllib.request
    now = time.time()
    today = time.strftime("%Y-%m-%d", time.localtime(now))
    tomorrow = time.strftime("%Y-%m-%d", time.localtime(now + 86400))
    prompt = (
        "You sort short personal notes. A TASK is something the writer has to do (maybe at a certain time). "
        "A NOTE is an idea, a fact, a thought, a quote, a question or something to remember.\n"
        f"Now: {time.strftime('%Y-%m-%d %H:%M', time.localtime(now))} ({time.strftime('%A', time.localtime(now))}).\n"
        'Answer with JSON only: {"task": true or false, "when": "YYYY-MM-DD HH:MM" or null, "later": true or false, "summary": "one sentence"}. '
        '"when" only if the note names a clock time or a day in its own words, else null. A bare time ("at 6") is the next time it happens; '
        "without am/pm, small hours like 6 mean the evening. "
        '"later" is true only for a task meant for later today with no clock time ("later", "this evening", "some time today"). '
        '"summary" is a short overview of what the note is ABOUT: say what the task or idea involves, in plain words, at most 18 words. '
        "Describe the subject itself. Do not talk about reminders, times or what you decided, and never copy the wording of the examples.\n"
        f'Note: call mom at 6\n{{"task": true, "when": "{today} 18:00", "later": false, "summary": "A phone call to your mom this evening."}}\n'
        f'Note: dentist tomorrow at 9am\n{{"task": true, "when": "{tomorrow} 09:00", "later": false, "summary": "A dental appointment tomorrow morning."}}\n'
        'Note: water the plants later\n{"task": true, "when": null, "later": true, "summary": "Watering the house plants, a quick chore for today."}\n'
        'Note: how to make pancakes\n{"task": true, "when": null, "later": false, "summary": "Making pancakes: mix batter, rest it, fry in a hot pan, flip once."}\n'
        'Note: idea: dark theme for the lock screen\n{"task": false, "when": null, "later": false, "summary": "An idea for a dark theme on the lock screen."}\n'
        'Note: the wifi password is on the router\n{"task": false, "when": null, "later": false, "summary": "Where to find the wifi password: on the router."}\n'
        f"Note: {text}\n"
    )
    body = json.dumps({"model": model_name(), "prompt": prompt, "stream": False, "format": "json", "think": False,
                       "keep_alive": keep_alive(), "options": {"temperature": 0, "num_predict": 130}}).encode()
    try:
        req = urllib.request.Request(ollama_host() + "/api/generate", data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = json.loads(r.read().decode("utf-8", "replace")).get("response", "")
        m = re.search(r"\{.*\}", raw, re.S)
        out = json.loads(m.group(0) if m else raw)
    except Exception:
        return None
    if not isinstance(out, dict) or not isinstance(out.get("task"), bool):
        return None
    when = out.get("when")
    why = out.get("summary") if isinstance(out.get("summary"), str) else out.get("why")   # "why" = older answers
    why = re.sub(r"\s+", " ", why).strip().strip('"') if isinstance(why, str) else ""
    if not why or parrots_example(text, why):
        why = summarise_only(text) or ""    # the model copied an example (or said nothing): ask it again, only for the summary
    return {"task": out["task"], "when": when if isinstance(when, str) and when.strip() else None,
            "later": out.get("later") is True, "why": why[:160]}

def summarise_only(text, words=18):
    """A second, tiny question with no examples to copy from: one sentence about what the note is. "" when that fails too."""
    import urllib.request
    prompt = (f"Summarise this personal note in one short sentence (at most {words} words). Say what it is about and what it involves. "
              "Do not mention reminders or times. Answer with the sentence only.\n\nNote: " + text + "\n")
    body = json.dumps({"model": model_name(), "prompt": prompt, "stream": False, "think": False,
                       "keep_alive": keep_alive(), "options": {"temperature": 0, "num_predict": 40 + 3 * words}}).encode()
    try:
        req = urllib.request.Request(ollama_host() + "/api/generate", data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = json.loads(r.read().decode("utf-8", "replace")).get("response", "")
    except Exception:
        return None
    out = re.sub(r"\s+", " ", raw).strip().strip('"')
    return "" if parrots_example(text, out) else out[:240]

def clean_overview(raw):
    """The model's overview as plain lines: no markdown, no 'Here's a summary:' opener, bullets as '- ', at most 8 lines."""
    out = []
    for ln in raw.replace("\r", "").split("\n"):
        ln = re.sub(r"\*\*|__|`", "", ln).strip()
        ln = re.sub(r"^(#+\s*|[*\u2022\u2013]\s+)", lambda m: "- " if m.group(1)[0] in "*\u2022\u2013" else "", ln)
        if not ln or re.match(r"^(here'?s|here is|sure|okay|summary)\b.*:\s*$", ln, re.I):
            continue
        out.append(ln)
    return "\n".join(out[:8])[:700]

CODE_START = re.compile(r"^\s*(\$ |sudo |#!/|#include|import |from \w+ import |def |class |fn |let |const |var |function |pub |use |impl |if ?\(|for ?\(|while ?\(|[{}]\s*$)")

def code_label(text):
    """A static line for a note that is source code or terminal commands (a language model only grabs lines of it): "" when the
    note is ordinary text."""
    t = text.strip().strip('"\u201c\u201d\u0027').strip()      # a snippet pasted inside quotes
    lines = [l for l in t.split("\n") if l.strip()]
    m = re.search(r"```\s*([A-Za-z0-9+#_-]*)", t)
    if not m:
        hits = sum(1 for l in lines if CODE_START.match(l) or l.rstrip().endswith((";", "{", "}")))
        if len(lines) < 2 or hits < 0.6 * len(lines):
            return ""
    lang = (m.group(1).lower() if m else "")
    names = {"rs": "Rust", "rust": "Rust", "py": "Python", "python": "Python", "js": "JavaScript", "javascript": "JavaScript",
             "ts": "TypeScript", "sh": "Shell", "bash": "Shell", "fish": "Shell", "c": "C", "cpp": "C++", "go": "Go", "lua": "Lua",
             "qml": "QML", "json": "JSON", "html": "HTML", "css": "CSS"}
    if lang in names:
        lang = names[lang]
    else:
        if re.search(r"\bfn \w+|let mut |\bimpl\b|println!", t): lang = "Rust"
        elif re.search(r"^\s*(def \w+\(|import \w+|from \w+ import)", t, re.M): lang = "Python"
        elif re.search(r"#include|std::|int main", t): lang = "C/C++"
        elif re.search(r"\bfunction\b|=>|console\.log|\bconst \w+ =", t): lang = "JavaScript"
        elif re.search(r"^\s*(\$ |sudo |#!/)", t, re.M): lang = "Shell"
        else: lang = ""
    n = len([l for l in lines if not l.strip().startswith("```")])
    what = "Terminal commands" if lang == "Shell" else ("Code snippet" + (f" ({lang})" if lang else ""))
    return f"{what}, {n} line{'s' if n != 1 else ''}"

# a to-do must never come back as a done thing: these words may only be in an overview when the note itself says them
DONE_WORDS = ("fixed", "completed", "finished", "resolved", "solved", "done", "paid", "sent", "called", "booked", "bought",
              "cleaned", "submitted", "installed", "updated", "created", "cancelled", "canceled", "cleared")

def _tense_ok(piece, note):
    low_note = set(re.findall(r"[a-z]+", note.lower()))
    return all(w in low_note for w in re.findall(r"[a-z]+", piece.lower()) if w in DONE_WORDS)

def _word_count(text):
    return len(re.findall(r"\w+", text))

def _sentences(text):
    return [x.strip() for x in re.split(r"(?<=[.!?])\s+|\n+", text) if len(x.strip()) > 12]

STOPWORDS = set("""about after also and any are been before between both but can could did does each from had has have her his how into its
just may more most much must not off only other our out over per she should some such than that the their them then there these they this
those through too under until upon very was were what when where which while who whom will with within without would you your""".split())

def _stems(text):
    """The words of a text (3+ letters), lower case; _grounded compares them by their first letters so that 'resumed' / 'resume',
    'week' / 'weeks' and 'dip' / 'dipped' count as the same word."""
    return set(re.findall(r"[a-z]{3,}", text.lower()))

def _has_word(w, note_words):
    """The word, or a form of it ('dip' / 'dipped', 'week' / 'weeks', 'resume' / 'resumed'), is in the note."""
    n = min(5, len(w))
    for x in note_words:
        if w[:n] == x[:n] and len(x) >= n:
            return True
        short, long_ = (w, x) if len(w) <= len(x) else (x, w)
        if len(short) >= 3 and long_.startswith(short) and len(long_) - len(short) <= 3:
            return True
    return False

def _numbers(text):
    """Every number in a text as it is written ('2:00', '14', '1.2', '45'), without a trailing dot or comma."""
    return {re.sub(r"[.,:]+$", "", n) for n in re.findall(r"\d[\d.,:]*", text)}

def _grounded(piece, note_stems, note_nums, note=None):
    """Is this line made of what the note says? Every number must be a number of the note, and at most 30% of its content words
    may be missing from the note. A small model invents ('reduces latency by up to 90%', 'exceeded expectations'); this is what
    keeps those lines off the screen."""
    if not _numbers(piece) <= note_nums:
        return False
    if note is not None and not _tense_ok(piece, note):
        return False
    words = [w for w in re.findall(r"[a-z]{4,}", piece.lower()) if w not in STOPWORDS]
    if not words:
        return True
    missing = [w for w in words if not _has_word(w, note_stems)]
    return len(missing) <= 0.3 * len(words)

def checklist_of(text):
    """A note that is a list of 3+ bullets / dashes / numbers: shown as it is (no model, so nothing can be dropped, invented or put
    in the wrong tense): 'Checklist, 4 items' and the items. \"\" when the note is not a list."""
    t = text.strip()
    marks = len(re.findall(r"[\u2022\u25cf\u25aa\u25e6\u2023]|(?:^|\n)\s*(?:[-*]\s+|\d{1,2}[.)]\s+)", t))
    if marks < 3:
        return ""
    parts = re.split(r"[\u2022\u25cf\u25aa\u25e6\u2023]|\n\s*(?:[-*]\s+|\d{1,2}[.)]\s+)", t)
    items = [re.sub(r"\s+", " ", x).strip(" -*\n") for x in parts]
    items = [x for x in items if x]
    if len(items) < 3:
        return ""
    lines = [f"Checklist, {len(items)} items"] + ["- " + (x if len(x) <= 70 else x[:67].rstrip() + "...") for x in items[:6]]
    if len(items) > 6:
        lines.append(f"- and {len(items) - 6} more")
    return "\n".join(lines)

NEG_RE = re.compile(r"\b(fell|fall|falls|fallen|dip|dipped|drop|dropped|decline|declined|down|loss|losses|lower|slump|slumped|cut|cuts|worse|reduced|shrank)\b", re.I)
ORDINAL_RE = re.compile(r"^(first|second|third|fourth|finally|however|despite)\b", re.I)

def _trim(s, n=22):
    """A sentence of at most n words: whole when short, else its first clause, else its first n words."""
    s = re.sub(r"\s+", " ", s).strip()
    if len(s.split()) <= n:
        return s
    for piece in re.split(r",\s+|;\s+", s):
        if 6 <= len(piece.split()) <= n:
            return piece
    return " ".join(s.split()[:n]) + "..."

def _percents(text):
    return set(re.findall(r"\d[\d.,]*\s*%", text))

def missing_bad_news(lines, text):
    """A small model likes good news: a decline that has a figure in the note ('net income fell by 3%', 'the stock dipped 4%') and
    is not in any line of the overview is added from the note's own words (as a clause of the note, so it is grounded)."""
    shown = " ".join(lines)
    extra = []
    for sent in _sentences(text):
        if not NEG_RE.search(sent):
            continue
        for clause in re.split(r",\s+(?:while|but|and)\s+|;\s+|\s+while\s+|\s+but\s+", sent):
            if NEG_RE.search(clause):
                pc = _percents(clause)
                if pc and not any(re.search(r"(?<![\d.,])" + re.escape(x.replace(" ", "")), shown.replace(" ", "")) for x in pc):
                    c = _trim(clause.strip().rstrip("."))
                    extra.append("- " + c[:1].upper() + c[1:])
    return extra

def _content(x):
    return {w[:5] for w in re.findall(r"[a-z]{4,}", x.lower()) if w not in STOPWORDS}

def _overlap(a, b):
    """How much of the shorter text's content words are in the other (0..1)."""
    A, B = _content(a), _content(b)
    return len(A & B) / min(len(A), len(B)) if A and B else 0.0

PIVOT_RE = re.compile(r"^(however|but|yet|later|by \d|by (?:noon|evening|afternoon|the end)|in the end|eventually|finally|update|turned out)\b|\bturned out\b|\bconfirm(?:ed|ing)\b", re.I)
INITIAL_RE = re.compile(r"\b(initial(?:ly)?|early|suggested|reported|rumou?rs?|expected|planned|forecast|predicted|at first|originally)\b", re.I)

def pivot_index(sents):
    """Index of the sentence where a note turns around ('However, ... / By 2 PM ... confirmed'), when it first says what was
    expected or reported; None for a note that does not correct itself."""
    for i, sx in enumerate(sents):
        if i >= 1 and PIVOT_RE.search(sx) and any(INITIAL_RE.search(y) for y in sents[:i]):
            return i
    return None

def overview_of(text):
    """What the AI line shows under a note when Settings > Notes > AI overview is on: a one-sentence summary for a short note;
    for a longer one a headline (the main point, or the FINAL outcome when the note corrects itself) and up to 3 short bullets.
    Faithful before clever: the model may only use what the note says, and every line it writes is checked against the note
    (_grounded); lines that are not are dropped. When nothing is left, the note's own first and last sentences are shown.
    "" when Ollama does not answer."""
    import urllib.request
    text = text.strip()
    code = code_label(text)
    if code:
        return code                                      # source code / terminal commands: a static line, the model is not asked
    cl = checklist_of(text)
    if cl:
        return cl                                        # a list of items: shown as written, the model is not asked
    if _word_count(text) < 8:
        return ""                                        # too little to summarise: a small model only guesses (and "invents" a context)
    if len(text) <= 140 and "\n" not in text:
        out = summarise_only(text, 18)
        if out is None:
            return None
        return out if out and _grounded(out, _stems(text), _numbers(text), text) else ""
    prompt = (
        "You write a short overview of a note for the person who saved it. Use ONLY facts that are written in the note. "
        "Do not add numbers, causes, opinions or anything else that is not in the note. Keep the tenses of the note: things still to do "
        "(remember to, need to, todo, a checklist) stay things to do and are never described as done, fixed or completed unless the "
        "note says so. Reply with JSON only: "
        '{"headline": "one sentence", "points": ["short bullet", "short bullet"]}.\n'
        "headline: one sentence with the main point. If the note first says one thing and later says it turned out "
        "differently (a rumour, a plan, a forecast that changed), the headline says what finally happened.\n"
        "If the note has both good and bad news (growth and a decline, a gain and a loss), the headline says the main result and the bullets keep the bad news too; never leave a decline out.\n"
        "points: 2 or 3 short bullets with the most important facts of the note, using its own numbers.\n\n"
        "Note:\n" + text[:4000] + "\n")
    body = json.dumps({"model": model_name(), "prompt": prompt, "stream": False, "format": "json", "think": False,
                       "keep_alive": keep_alive(), "options": {"temperature": 0, "num_predict": 220}}).encode()
    try:
        req = urllib.request.Request(ollama_host() + "/api/generate", data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=90) as r:
            raw = json.loads(r.read().decode("utf-8", "replace")).get("response", "")
    except Exception:
        return None
    try:
        m = re.search(r"\{.*\}", raw, re.S)
        d = json.loads(m.group(0) if m else raw)
        head = re.sub(r"\s+", " ", str(d.get("headline") or "")).strip()
        pts = [re.sub(r"\s+", " ", re.sub(r"\*\*|__|`", "", str(x))).strip(" -*\u2022") for x in (d.get("points") or []) if isinstance(x, str)]
    except (ValueError, AttributeError, TypeError):
        head, pts = "", []
    ns, nn = _stems(text), _numbers(text)
    head = head if head and _grounded(head, ns, nn, text) else ""
    keep = [x for x in pts if x and len(x.split()) <= 20 and _grounded(x, ns, nn, text)][:3]
    sents = _sentences(text)
    piv = pivot_index(sents)
    if piv is not None and sents:                        # the note corrects itself: the overview says what finally happened
        def at(x):
            return max(range(len(sents)), key=lambda i: _overlap(x, sents[i]))
        late = [x for x in keep if at(x) >= piv]
        if head and at(head) < piv:
            head = max(late, key=lambda x: (at(x), len(x))) if late else _trim(sents[-1])
        keep = [x for x in late if x != head]
    if piv is not None and not head and sents:           # corrected note and the model gave no headline: the final outcome is the headline
        c = _trim(sents[-1])
        head = c[:1].upper() + c[1:]
    uniq = []
    for x in keep:                                       # a bullet that is the headline again (0.85) or says an earlier bullet again (0.6) is dropped
        if (not head or _overlap(x, head) < 0.85) and all(_overlap(x, y) < 0.6 for y in uniq):
            uniq.append(x)
    keep = uniq
    bad = missing_bad_news([head] + keep, text)[:2]        # the declines the model skipped, from the note's own words
    if bad:                                              # make room: bullets with a % or $ figure stay, the ones without go first
        keep = sorted(keep, key=lambda x: 0 if re.search(r"\d\s*%|\$", x) else 1)[:4 - len(bad)]
    lines = ([head] if head else []) + ["- " + x for x in keep] + bad
    if not keep and _word_count(text) >= 60:             # a long note with a headline only: its own marked-up sentences ('First, ... Second, ...')
        marked = [_trim(x) for x in _sentences(text) if ORDINAL_RE.match(x)][:3]
        lines += ["- " + x for x in marked if _grounded(x, ns, nn, text)]
    if piv is None and _word_count(text) >= 60 and len(lines) < 5:   # a "Despite ... / However ..." caveat the overview does not mention
        shown = " ".join(lines)
        for sx in sents:
            if re.match(r"(despite|however|although|but)\b", sx, re.I) and _overlap(sx, shown) < 0.5:
                c = _trim(sx)
                if _grounded(c, ns, nn, text):
                    for piece in [c] + re.split(r",\s+", c):
                        if 6 <= len(piece.split()) <= 22 and not re.match(r"(despite|however|although|but)\b", piece, re.I):
                            lines.append("- " + piece[:1].upper() + piece[1:]); break
                break
    if not lines:                                        # nothing the note backs up: show the note's own words, never an invention
        sents = _sentences(text)
        pick = [sents[0]] + ([sents[-1]] if len(sents) > 1 else [])
        lines = [x[:200] for x in pick]
    return "\n".join(lines)[:600]

EXAMPLE_WORDS = ("mom", "dentist", "plants", "pancake", "wifi", "wi-fi", "router", "lock screen", "dark theme")

def parrots_example(text, summary):
    """Small models sometimes answer with the sentence of one of the prompt's examples. A summary that names an example's
    subject the note itself never mentions is that: it is thrown away."""
    t, sm = text.lower(), summary.lower()
    return any(w in sm and w not in t for w in EXAMPLE_WORDS)

def plain_summary(text):
    """What the AI line says when the model's own sentence was unusable: the note itself, shortened."""
    t = re.sub(r"\s+", " ", text).strip()
    return ("Note about: " + (t[:90] + ("..." if len(t) > 90 else ""))) if t else ""

def make_why(task, due, later, conf):
    """What the AI line says when the model gave no sentence of its own (small models often skip it)."""
    if not task:
        return "Looks like a plain note: nothing you have to do."
    if due:
        return f"Reminder set for {due_text(due).lower()}."
    if later:
        return f"A task for later today: I will nudge you every {conf['NOTES_NUDGE_HOURS']} h, at most {conf['NOTES_NUDGE_MAX']} times."
    return "A task with no time named, so no reminder."

CLOCK_RE = re.compile(r"\b(\d{1,2}(?::\d{2})?\s*(?:am|pm|a\\.m\\.|p\\.m\\.)|(?:[01]?\d|2[0-3]):[0-5]\d|(?<=\bat )\d{1,2})(?![\d:%])", re.I)

def note_time(text):
    """A clock time the note itself writes ('9:30 AM', 'at 6', '19:45'), as a spec parse_when understands, with the day word in front when
    the note names one. None when the note has none. A small model gets times wrong ('9:30 AM' became 'tomorrow 19:58'), so when the
    note says a time, that time wins."""
    m = CLOCK_RE.search(text)
    if not m:
        return None
    clock = re.sub(r"\s+", "", m.group(1).lower())
    day = re.search(r"\b(tomorrow|today|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b", text, re.I)
    return (day.group(1).lower() + " " if day else "") + clock

def resolve_due(text, when):
    """The model's guess -> an epoch, or None. Small models invent times, so a time is only taken when the note has a digit
    or a time word in it, and one that is already past is dropped."""
    when = note_time(text) or when          # the time written in the note beats the model's guess
    if not when or not TIME_WORDS.search(text):
        return None
    now = time.time()
    try:
        ts = parse_when(when, now)
    except ValueError:
        return None
    if ts is None:
        return None
    # "at 6" with no am/pm: the model may say 06:00; a reminder at 6 is far more often 18:00
    h = time.localtime(ts).tm_hour
    if 1 <= h <= 6 and not re.search(r"\b(am|a\.m\.|morning|night)\b", text, re.I) and time.localtime(ts).tm_min == 0:
        ts += 12 * 3600
    if ts <= now:
        lt = time.localtime(now)
        if ts >= time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1)):
            ts += 86400                    # "at 3" said after 3 o'clock: the next one is tomorrow
        else:
            return None                    # a day that is already over
    return ts

def finish_think(nid, think):
    """Write the AI line of one note (the notes window shows it under the text) and nothing else."""
    with locked():
        notes = load_notes()
        n = next((x for x in notes if x.get("id") == nid), None)
        if n is None:
            return
        if think is None:
            n.pop("think", None)
        else:
            n["think"] = think
        save_notes(notes)
    refresh_ui()

def sort_note(arg, force=False):
    """Run in the background after saving. The model is asked WITHOUT holding the lock (it can take seconds); only the small
    updates take it. While it works the note carries think = {"state": "thinking"} so the notes window can say so, and whatever
    happens (Ollama down, a crash) that flag is replaced before this returns.
    force (notes think): ask again about a note that was sorted before; a note that already is a task stays as it is, only the
    AI line is renewed."""
    conf = read_conf()
    sort_on, ov_on = conf["NOTES_AI"] == "1", conf["NOTES_OVERVIEW"] == "1"
    if not (sort_on or ov_on):
        print("[!] The notes AI is off (Settings > Notes, or: notes set NOTES_AI 1 / notes set NOTES_OVERVIEW 1)")
        return
    notes = load_notes()
    target = find_note(notes, arg)
    if not target:
        print(f"[!] Note not found: {arg}")
        return
    nid, text = target.get("id"), (target.get("text") or "").strip()
    if not text or len(text) > 6000 or (not force and (target.get("sorted") or target.get("think"))):
        return
    finish_think(nid, {"state": "thinking", "at": time.time()})
    try:
        if not sort_on or len(text) > 280 or text.count("\n") > 3 or code_label(text):
            # no task sorting (it is off, or the note is long: an article is never a task): only the overview of what it says
            ov = overview_of(text)
            if ov is None:
                finish_think(nid, {"state": "offline", "at": time.time(),
                                   "why": "Ollama is not running (or did not answer), so there is no overview yet. Start it and use Think on this note."})
                return
            with locked():
                notes = load_notes()
                n = next((x for x in notes if x.get("id") == nid), None)
                if n is None:
                    return
                n["sorted"] = True
                n["think"] = {"state": "done", "at": time.time(), "why": ov, "task": bool(n.get("task"))}
                save_notes(notes)
            refresh_ui()
            return
        ans = ask_model(text)
        if ans is None:
            finish_think(nid, {"state": "offline", "at": time.time(),
                               "why": "Ollama is not running (or did not answer), so this stays a plain note. Start it and use Think again on this note."})
            return
        due = resolve_due(text, ans["when"]) if ans["task"] else None
        later = bool(ans["task"] and ans["later"] and not due)
        tiny = _word_count(text) < 8
        say = ans["why"] if (ans["why"] and not tiny and _grounded(ans["why"], _stems(text), _numbers(text), text)) else ""
        why = say or (make_why(ans["task"], due, later, conf) if tiny else (plain_summary(text) or make_why(ans["task"], due, later, conf)))
        if ov_on and (len(text) > 140 or checklist_of(text)):
            why = overview_of(text) or why
        if due and say and not (ov_on and (len(text) > 140 or checklist_of(text))):
            why = (why.rstrip(".") + f"  ·  reminder {due_text(due).lower()}")[:200]
        with locked():
            notes = load_notes()
            n = next((x for x in notes if x.get("id") == nid), None)
            if n is None:                                              # deleted in the meantime
                return
            think = {"state": "done", "at": time.time(), "why": why, "task": bool(ans["task"])}
            if n.get("done") or (not force and "task" in n):            # done or set by hand in the meantime: only the AI line
                n["think"] = think
            else:
                n["sorted"] = True
                n["think"] = think
                if ans["task"] and "task" not in n:
                    if conf["NOTES_AI_MODE"] == "auto":
                        n["task"] = True
                        n["ai"] = True
                        if due:
                            n["due"] = due
                            n["reminded"] = False
                        elif later:
                            start_later(n, conf)
                    else:
                        n["suggest"] = {"due": due, "later": later}
            save_notes(notes)
            sync_timer(notes)
        refresh_ui()
    except Exception as e:
        finish_think(nid, {"state": "offline", "at": time.time(), "why": "The AI could not finish this note (%s)." % type(e).__name__})

def toggle_task(arg):
    notes = load_notes()
    n = find_note(notes, arg)
    if not n:
        print(f"[!] Note not found: {arg}")
        return
    n["task"] = not n.get("task", False)
    n.pop("suggest", None)
    n["sorted"] = True
    if not n["task"]:
        n.pop("due", None)
        n.pop("reminded", None)
        clear_later(n)
    save_notes(notes)
    print(("✓ Task: " if n["task"] else "✓ Plain note: ") + f"\"{n.get('text')}\"")

def set_due(arg, spec):
    notes = load_notes()
    n = find_note(notes, arg)
    if not n:
        print(f"[!] Note not found: {arg}")
        return
    if (spec or "").strip().lower() in ("later", "later today", "today later", "nudge", "nudges"):
        n.pop("suggest", None)
        n["sorted"] = True
        conf = read_conf()
        first = start_later(n, conf)
        save_notes(notes)
        if first:
            print(f"⏰ Later today: a nudge about every {conf['NOTES_NUDGE_HOURS']} h from {time.strftime('%H:%M', time.localtime(first))}: \"{n.get('text')}\"")
        else:
            print(f"⏰ Later today: it is too late in the day for a nudge; it stays in your tasks: \"{n.get('text')}\"")
        return
    try:
        ts = parse_when(spec)
    except ValueError as e:
        print(f"[!] {e}")
        return
    n.pop("suggest", None)
    n["sorted"] = True
    clear_later(n)
    if ts is None:
        n.pop("due", None)
        n.pop("reminded", None)
        save_notes(notes)
        print(f"✓ No reminder: \"{n.get('text')}\"")
        return
    n["task"] = True
    n["due"] = ts
    n["reminded"] = False
    save_notes(notes)
    print(f"⏰ Reminder {due_text(ts)}: \"{n.get('text')}\"")

def answer_suggestion(arg, yes):
    notes = load_notes()
    n = find_note(notes, arg)
    if not n:
        print(f"[!] Note not found: {arg}")
        return
    sg = n.pop("suggest", None) or {}
    if yes:
        n["task"] = True
        n["ai"] = True
        if sg.get("due"):
            n["due"] = sg["due"]
            n["reminded"] = False
        elif sg.get("later"):
            start_later(n, read_conf())
    save_notes(notes)
    print("✓ Task" if yes else "✓ Stays a note")

def remind_check():
    """What the timer runs every minute: one notification for each task whose time has come (once), and a gentle nudge for each
    "later today" task whose next nudge has come (every NOTES_NUDGE_HOURS hours, inside the window, at most NOTES_NUDGE_MAX, until midnight)."""
    now = time.time()
    conf = read_conf()
    hours, maxn = int(conf["NOTES_NUDGE_HOURS"]), int(conf["NOTES_NUDGE_MAX"])
    notes = load_notes()
    changed = False
    for n in pending_due(notes):
        if n["due"] <= now:
            late = now - n["due"] > 600
            notify("Reminder" if not late else "Reminder (a little late)", (n.get("text") or "").strip()[:200])
            n["reminded"] = True
            changed = True
    for n in notes:
        if not isinstance(n, dict) or not n.get("later"):
            continue
        if now > n["later"] or n.get("done") or not n.get("task"):       # the day is over (or it is done): no more nudges
            clear_later(n)
            changed = True
            continue
        if not n.get("nudge_at") or now < n["nudge_at"]:
            continue
        _, fr, to, _ = day_window(now, conf)
        if now < fr:                                                      # woke up before the window: wait for it
            n["nudge_at"] = fr
        elif now >= to or n.get("nudges", 0) >= maxn:                     # window closed for today / enough nudges
            n["nudge_at"] = None
        else:
            notify("Still on your list", (n.get("text") or "").strip()[:200])
            n["nudges"] = n.get("nudges", 0) + 1
            nxt = now + hours * 3600
            n["nudge_at"] = nxt if (nxt < to and nxt < n["later"] and n["nudges"] < maxn) else None
        changed = True
    if changed:
        save_notes(notes)
    sync_timer(notes)
    if changed:
        refresh_ui()

def list_tasks():
    notes = [n for n in load_notes() if n.get("task")]
    if not notes:
        print("\033[38;5;244mNo tasks. Make one with: notes task <num>  or  notes due <num> 18:00\033[0m")
        return
    print("\033[1;35m☑ Halcyon Tasks\033[0m")
    for n in notes:
        due = f"  \033[38;5;214m⏰ {due_text(n['due'])}\033[0m" if n.get("due") else ""
        box = "\033[38;5;242m[✓] \033[9m" if n.get("done") else "[ ] \033[1m"
        print(f"{box}{n.get('text', '')}\033[0m{due}")

def conf_json():
    c = read_conf()
    print(json.dumps({"NOTES_AI": c["NOTES_AI"] == "1", "NOTES_OVERVIEW": c["NOTES_OVERVIEW"] == "1", "NOTES_AI_MODE": c["NOTES_AI_MODE"],
                      "NOTES_NUDGE_HOURS": c["NOTES_NUDGE_HOURS"], "NOTES_NUDGE_MAX": c["NOTES_NUDGE_MAX"],
                      "NOTES_NUDGE_FROM": c["NOTES_NUDGE_FROM"], "NOTES_NUDGE_TO": c["NOTES_NUDGE_TO"], "NOTES_MODEL": c["NOTES_MODEL"],
                      "ollama": ollama_up() if "1" in (c["NOTES_AI"], c["NOTES_OVERVIEW"]) else None, "model": model_name()}))

def set_conf(k, v):
    c = read_conf()
    if k in ("NOTES_AI", "NOTES_OVERVIEW"):
        c[k] = "1" if str(v).lower() in ("1", "true", "on", "yes") else "0"
    elif k == "NOTES_AI_MODE" and v in ("ask", "auto"):
        c[k] = v
    elif k == "NOTES_MODEL" and re.fullmatch(r"[A-Za-z0-9._:/@+-]{0,100}", str(v)):
        c[k] = "" if str(v).lower() in ("default", "none", "-") else str(v)      # "default" = use the advisor's model again
    elif k in CONF_RANGE and str(v).isdigit() and CONF_RANGE[k][0] <= int(v) <= CONF_RANGE[k][1]:
        c[k] = str(int(v))
    else:
        print(f"[!] unknown key or value: {k}={v}")
        return
    write_conf(c)

def main():
    args = sys.argv[1:]
    if not args:
        list_notes()
        return

    cmd = args[0]
    if cmd in READ_ONLY:
        run(cmd, args)
    elif cmd in NO_LOCK and len(args) == 2 and is_ref(args[1]):
        run(cmd, args)          # these take the lock themselves, only for the part that writes
    else:
        with locked():
            run(cmd, args)
            if cmd not in ("conf", "set"):
                sync_timer()        # the minute timer only runs while a task with a time is waiting

READ_ONLY = ("list", "ls", "json")
NO_LOCK = ("sort", "think")

def is_ref(a):
    return a.isdigit() or a.startswith("n_")

def run(cmd, args):
    # the new words only count as commands when they are used like commands, so "notes set the table" is still a note
    if (cmd in ("tasks", "conf", "remind-check") and len(args) > 1) \
            or (cmd in ("task", "sort", "think", "accept", "dismiss") and not (len(args) == 2 and is_ref(args[1]))) \
            or (cmd == "due" and not (len(args) > 2 and is_ref(args[1]))) \
            or (cmd == "set" and not (len(args) == 3 and args[1] in CONF_DEFAULTS)):
        add_note(" ".join(args))
        return
    if cmd in ("list", "ls"):
        list_notes()
    elif cmd == "json":
        print(json.dumps(load_notes()))
    elif cmd == "tasks":
        list_tasks()
    elif cmd == "conf":
        conf_json()
    elif cmd == "set":
        if len(args) > 2:
            set_conf(args[1], args[2])
        else:
            print("usage: notes set NOTES_AI 0|1  |  NOTES_OVERVIEW 0|1  |  NOTES_AI_MODE ask|auto  |  NOTES_MODEL <ollama name>|default  |  NOTES_NUDGE_HOURS 1..12  |  NOTES_NUDGE_MAX 1..12  |  NOTES_NUDGE_FROM 0..23  |  NOTES_NUDGE_TO 1..24")
    elif cmd == "sort":
        if len(args) > 1:
            sort_note(args[1])
        else:
            print("usage: notes sort <number or id>")
    elif cmd == "think":
        if len(args) > 1:
            t0 = time.time()
            sort_note(args[1], force=True)
            if sys.stdout.isatty():                      # typed in a terminal: show what the AI line now says (and which model, how long)
                n = find_note(load_notes(), args[1]) or {}
                th = n.get("think") or {}
                print(f"[{model_name()}]  {time.time() - t0:.1f}s")
                print(th.get("why") or "(empty AI line: the note is too short, or the model's sentence did not match the note and was dropped)")
        else:
            print("usage: notes think <number or id>")
    elif cmd == "task":
        if len(args) > 1:
            toggle_task(args[1])
        else:
            print("usage: notes task <number>")
    elif cmd == "due":
        if len(args) > 2:
            set_due(args[1], " ".join(args[2:]))
        else:
            print("usage: notes due <number> <18:00 | 6pm | +30m | +2h | tomorrow 09:00 | later | none>")
    elif cmd in ("accept", "dismiss"):
        if len(args) > 1:
            answer_suggestion(args[1], cmd == "accept")
        else:
            print(f"usage: notes {cmd} <id>")
    elif cmd == "remind-check":
        remind_check()
    elif cmd in ("del", "rm", "delete"):
        if len(args) > 1:
            del_note(args[1])
        else:
            print("usage: notes del <number>")
    elif cmd == "pin":
        if len(args) > 1:
            pin_note(args[1])
        else:
            print("usage: notes pin <number>")
    elif cmd in ("done", "check"):
        if len(args) > 1:
            done_note(args[1])
        else:
            print("usage: notes done <number>")
    elif cmd == "clear":
        clear_done()
    elif cmd in ("add", "new"):
        add_note(" ".join(args[1:]))
    else:
        # Any string like "notes : hi i am srijan" or "notes buy milk"
        add_note(" ".join(args))

if __name__ == "__main__":
    main()
