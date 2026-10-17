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
"""
import contextlib
import fcntl
import json
import os
import sys
import tempfile
import time

STATE_DIR = os.path.expanduser("~/.local/state/island")
NOTES_FILE = os.path.join(STATE_DIR, "notes.json")

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
    # Notify if quickshell is listening
    try:
        import subprocess
        subprocess.run(["quickshell", "-p", os.path.expanduser("~/.config/Halcyon/quickshell/island"),
                        "ipc", "call", "island", "refreshNotes"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1)
    except Exception:
        pass
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
        print(f"{i:2d}. {pin}{status}{n.get('text', '')}{reset} \033[38;5;240m({date})\033[0m")
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

def main():
    args = sys.argv[1:]
    if not args:
        list_notes()
        return

    cmd = args[0]
    if cmd in READ_ONLY:
        run(cmd, args)
    else:
        with locked():
            run(cmd, args)

READ_ONLY = ("list", "ls", "json")

def run(cmd, args):
    if cmd in ("list", "ls"):
        list_notes()
    elif cmd == "json":
        print(json.dumps(load_notes()))
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
