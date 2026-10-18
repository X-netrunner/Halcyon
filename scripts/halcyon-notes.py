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
  notes accept / dismiss <id>     -> answer "Make this a task?" (ask mode)
  notes remind-check              -> what the timer runs: one notification for every task whose time has come
  notes conf | set KEY VALUE      -> NOTES_AI 0|1 , NOTES_AI_MODE ask|auto  (~/.config/Halcyon/notes.conf)
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
    if read_conf()["NOTES_AI"] == "1" and len(text) <= 280:
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
        due = f" \033[38;5;214m⏰ {due_text(n['due'])}\033[0m" if n.get("due") else ""
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
def read_conf():
    c = {"NOTES_AI": "0", "NOTES_AI_MODE": "ask"}
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
    if c["NOTES_AI_MODE"] not in ("ask", "auto"):
        c["NOTES_AI_MODE"] = "ask"
    return c

def write_conf(c):
    os.makedirs(os.path.dirname(CONF_FILE), exist_ok=True)
    keep = []
    try:                       # lines that are not ours stay as they are
        with open(CONF_FILE, "r", encoding="utf-8") as f:
            keep = [l.rstrip("\n") for l in f if not re.match(r"\s*NOTES_AI(_MODE)?=", l)]
    except OSError:
        pass
    fd, tmp = tempfile.mkstemp(prefix="notes.conf.", dir=os.path.dirname(CONF_FILE))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(f"NOTES_AI={c['NOTES_AI']}\nNOTES_AI_MODE={c['NOTES_AI_MODE']}\n")
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
    """The same model `ai` and the advisor use (HALCYON_AI_MODEL, else MODEL= in ai-advisor.conf)."""
    if os.environ.get("HALCYON_AI_MODEL"):
        return os.environ["HALCYON_AI_MODEL"].strip()
    try:
        with open(os.path.join(RICE, "ai-advisor.conf"), "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MODEL="):
                    return line.split("=", 1)[1].strip().strip('"\'') or "llama3.2:1b"
    except OSError:
        pass
    return "llama3.2:1b"

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

def sync_timer(notes=None):
    """The once-a-minute timer exists only while a task with a time is waiting. Nothing is installed or running for people
    who never use it."""
    if not shutil.which("systemctl"):
        return
    pending = bool(pending_due(load_notes() if notes is None else notes))
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
    """-> {"task": bool, "when": str|None}, or None when Ollama is not there / answers nonsense. Never raises."""
    import urllib.request
    now = time.time()
    today = time.strftime("%Y-%m-%d", time.localtime(now))
    tomorrow = time.strftime("%Y-%m-%d", time.localtime(now + 86400))
    prompt = (
        "You sort short personal notes. A TASK is something the writer has to do (maybe at a certain time). "
        "A NOTE is an idea, a fact, a thought, a quote or something to remember.\n"
        f"Now: {time.strftime('%Y-%m-%d %H:%M', time.localtime(now))} ({time.strftime('%A', time.localtime(now))}).\n"
        'Answer with JSON only: {"task": true or false, "when": "YYYY-MM-DD HH:MM" or null}. '
        '"when" only if the note names a time or a day, else null. A bare time ("at 6") is the next time it happens; '
        "without am/pm, small hours like 6 mean the evening.\n"
        f'Note: call mom at 6\n{{"task": true, "when": "{today} 18:00"}}\n'
        f'Note: dentist tomorrow at 9am\n{{"task": true, "when": "{tomorrow} 09:00"}}\n'
        'Note: buy milk\n{"task": true, "when": null}\n'
        'Note: idea: dark theme for the lock screen\n{"task": false, "when": null}\n'
        'Note: the wifi password is on the router\n{"task": false, "when": null}\n'
        f"Note: {text}\n"
    )
    body = json.dumps({"model": model_name(), "prompt": prompt, "stream": False, "format": "json", "think": False,
                       "keep_alive": keep_alive(), "options": {"temperature": 0, "num_predict": 60}}).encode()
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
    return {"task": out["task"], "when": when if isinstance(when, str) and when.strip() else None}

def resolve_due(text, when):
    """The model's guess -> an epoch, or None. Small models invent times, so a time is only taken when the note has a digit
    or a time word in it, and one that is already past is dropped."""
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

def sort_note(arg):
    """Run in the background after saving. The model is asked WITHOUT holding the lock (it can take seconds); only the small
    update at the end takes it."""
    conf = read_conf()
    if conf["NOTES_AI"] != "1":
        print("[!] Notes AI is off (Settings > Notes, or: notes set NOTES_AI 1)")
        return
    notes = load_notes()
    target = find_note(notes, arg)
    if not target:
        print(f"[!] Note not found: {arg}")
        return
    nid, text = target.get("id"), (target.get("text") or "").strip()
    if not text or len(text) > 280 or text.count("\n") > 3 or "task" in target or target.get("sorted"):
        return
    ans = ask_model(text)
    if ans is None:
        print("[!] Ollama did not answer; the note stays a plain note.")
        return
    due = resolve_due(text, ans["when"]) if ans["task"] else None
    with locked():
        notes = load_notes()
        n = next((x for x in notes if x.get("id") == nid), None)
        if n is None or "task" in n or n.get("done"):          # deleted, done or set by hand in the meantime
            return
        n["sorted"] = True
        if ans["task"]:
            if conf["NOTES_AI_MODE"] == "auto":
                n["task"] = True
                n["ai"] = True
                if due:
                    n["due"] = due
                    n["reminded"] = False
            else:
                n["suggest"] = {"due": due}
        save_notes(notes)
        sync_timer(notes)
    refresh_ui()

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
    save_notes(notes)
    print(("✓ Task: " if n["task"] else "✓ Plain note: ") + f"\"{n.get('text')}\"")

def set_due(arg, spec):
    notes = load_notes()
    n = find_note(notes, arg)
    if not n:
        print(f"[!] Note not found: {arg}")
        return
    try:
        ts = parse_when(spec)
    except ValueError as e:
        print(f"[!] {e}")
        return
    n.pop("suggest", None)
    n["sorted"] = True
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
    save_notes(notes)
    print("✓ Task" if yes else "✓ Stays a note")

def remind_check():
    """What the timer runs every minute: one notification for each task whose time has come (once)."""
    now = time.time()
    notes = load_notes()
    changed = False
    for n in pending_due(notes):
        if n["due"] <= now:
            late = now - n["due"] > 600
            notify("Reminder" if not late else "Reminder (a little late)", (n.get("text") or "").strip()[:200])
            n["reminded"] = True
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
    print(json.dumps({"NOTES_AI": c["NOTES_AI"] == "1", "NOTES_AI_MODE": c["NOTES_AI_MODE"],
                      "ollama": ollama_up() if c["NOTES_AI"] == "1" else None, "model": model_name()}))

def set_conf(k, v):
    c = read_conf()
    if k == "NOTES_AI":
        c[k] = "1" if str(v).lower() in ("1", "true", "on", "yes") else "0"
    elif k == "NOTES_AI_MODE" and v in ("ask", "auto"):
        c[k] = v
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
NO_LOCK = ("sort",)

def is_ref(a):
    return a.isdigit() or a.startswith("n_")

def run(cmd, args):
    # the new words only count as commands when they are used like commands, so "notes set the table" is still a note
    if (cmd in ("tasks", "conf", "remind-check") and len(args) > 1) \
            or (cmd in ("task", "sort", "accept", "dismiss") and not (len(args) == 2 and is_ref(args[1]))) \
            or (cmd == "due" and not (len(args) > 2 and is_ref(args[1]))) \
            or (cmd == "set" and not (len(args) == 3 and args[1] in ("NOTES_AI", "NOTES_AI_MODE"))):
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
            print("usage: notes set NOTES_AI 0|1  |  notes set NOTES_AI_MODE ask|auto")
    elif cmd == "sort":
        if len(args) > 1:
            sort_note(args[1])
        else:
            print("usage: notes sort <number or id>")
    elif cmd == "task":
        if len(args) > 1:
            toggle_task(args[1])
        else:
            print("usage: notes task <number>")
    elif cmd == "due":
        if len(args) > 2:
            set_due(args[1], " ".join(args[2:]))
        else:
            print("usage: notes due <number> <18:00 | 6pm | +30m | +2h | tomorrow 09:00 | none>")
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
