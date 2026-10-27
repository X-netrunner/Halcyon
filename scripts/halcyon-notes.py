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
Pictures and voice:
  notes clip-image [text]         -> the image on the clipboard becomes a note; with no image there, drag a screen region instead
  notes clip-stage                -> Ctrl+V in the notes panel: keeps the clipboard image (CLIP_STAGED:<path>) so a caption can be typed,
                                     then `notes image <path> <caption>` saves it. `notes clip-drop <path>` discards a staged image
  notes clip-paste [text]         -> (older, saves at once) Ctrl+V in the notes panel: the image on the clipboard becomes a note (prints CLIP_NONE and does nothing
                                     when there is no image, so the panel can paste the text instead)
  notes rec-toggle                -> one key for voice notes: starts a recording, the same key again saves it (Super + Shift + V)
  notes summary <idx_or_id>       -> a full summary of a note of any length (the short overview stays short; this one has no limit)
  notes ocr <idx_or_id>           -> read the text in a picture note (tesseract, offline, nothing invented) and keep it with the note
  notes describe <idx_or_id>      -> a short description of a picture note from a local vision model (only when NOTES_VLM is on)
  notes search <words>            -> find notes by what they say, what was said, the text in their pictures and their descriptions
  notes selftest                  -> checks Ollama, the models, Whisper, the recorder and tesseract and says what is missing
  notes rec-start [text] | rec-stop | rec-cancel | rec-status   -> a voice note: stop saves it, turns it into text and hands that to the AI
  notes transcribe <idx_or_id>    -> (re)do the speech-to-text of a voice note. Engines: whisper.cpp (whisper-cli + a ggml model),
                                     faster-whisper (pip) or openai-whisper. NOTES_STT_MODEL / NOTES_STT_LANG in notes.conf (or
                                     HALCYON_STT_MODEL / HALCYON_STT_LANG) pick the model file or name and the language (empty = auto)
  notes accept / dismiss <id>     -> answer "Make this a task?" (ask mode)
  notes repeat <idx_or_id> <daily|weekdays|weekly|monthly|none>   -> a task with a time that comes back ("every Monday 9am" in the note does it by itself)
  notes snooze <idx_or_id> <+10m|+1h|18:00>   -> put a reminder back (the Snooze buttons of the reminder notification run this)
  notes remind-check              -> what the timer runs: one notification for every task whose time has come
  notes conf | set KEY VALUE      -> NOTES_OCR 0|1 , NOTES_VLM 0|1 , NOTES_VLM_MODEL <name>|default , NOTES_AI 0|1 , NOTES_OVERVIEW 0|1 , NOTES_AI_MODE ask|auto , NOTES_NUDGE_HOURS 1..12 , NOTES_NUDGE_MAX 1..12 ,
                                     NOTES_NUDGE_FROM 0..23 , NOTES_NUDGE_TO 1..24   (~/.config/Halcyon/notes.conf)
"""
import base64
import calendar
import contextlib
import difflib
import fcntl
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import importlib.util

HOME = os.path.expanduser("~")
RICE = os.environ.get("HALCYON_DIR", os.path.join(HOME, ".config", "Halcyon"))
STATE_DIR = os.path.join(HOME, ".local", "state", "island")
NOTES_FILE = os.path.join(STATE_DIR, "notes.json")
MEDIA_DIR = os.path.join(STATE_DIR, "notes_media")
REC_PID_FILE = os.path.join(STATE_DIR, "notes_recording.json")
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
    # A file that cannot be read is NOT the same as no notes: the next save would overwrite it with only the new note. Keep a copy first.
    with contextlib.suppress(OSError):
        if os.path.getsize(NOTES_FILE) > 2:
            shutil.copy2(NOTES_FILE, NOTES_FILE + ".corrupt-" + time.strftime("%Y%m%d-%H%M%S"))
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

def add_note(text, image=None, audio=None, stt=False):
    text = text.strip()
    if text.startswith(":"):
        text = text[1:].strip()
    typed = text
    if not text and not image and not audio:
        print("[!] Note cannot be empty.")
        return False
    if not text:
        if image:
            text = "Image Note"
        elif audio:
            text = "Voice Note"

    # Auto-detect image file path in text if not explicitly set
    if not image:
        clean = text[7:] if text.startswith("file://") else text
        if os.path.isfile(clean) and clean.lower().endswith(('.png', '.jpg', '.jpeg', '.webp', '.gif', '.svg', '.bmp')):
            image = os.path.abspath(clean)
        else:
            m = re.search(r'!\[.*?\]\((.*?)\)', text)
            if m:
                cand = m.group(1).strip()
                if cand.startswith("file://"):
                    cand = cand[7:]
                if os.path.isfile(cand):
                    image = os.path.abspath(cand)

    # Auto-detect audio file path in text if not explicitly set
    if not audio:
        clean = text[7:] if text.startswith("file://") else text
        if os.path.isfile(clean) and clean.lower().endswith(('.wav', '.mp3', '.ogg', '.opus', '.m4a', '.flac')):
            audio = os.path.abspath(clean)

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
    if image:
        item["image"] = image
    if audio:
        item["audio"] = audio
        if stt:
            item["stt"] = {"state": "working", "at": now}      # the words are being written down; the list says so
            if typed:
                item["typed"] = typed                          # what was typed before recording stays in front of the transcript
    notes.insert(0, item)
    save_notes(notes)
    extra = (" \033[38;5;111m[Image]\033[0m" if image else "") + (" \033[38;5;178m[Audio]\033[0m" if audio else "")
    print(f"\033[1;32m✓\033[0m Note added: \033[1m{text}\033[0m{extra}")
    refresh_ui()
    # sorting is a separate background process: saving is already done and never waits for the model
    if stt and audio:
        # a voice note is sorted by the AI only once it has words: the transcript step does that when it is done
        with contextlib.suppress(Exception):
            subprocess.Popen([sys.executable, os.path.abspath(__file__), "transcribe", item["id"]], start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    cf = read_conf()
    if image and cf["NOTES_OCR"] == "1" and _which("tesseract"):
        # the text in the picture is read in the background; saving never waits for it
        with contextlib.suppress(Exception):
            subprocess.Popen([sys.executable, os.path.abspath(__file__), "ocr", item["id"]], start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if ai_enabled() and cf["NOTES_SUMMARY"] == "1" and _word_count(text) >= 150:
        with contextlib.suppress(Exception):
            subprocess.Popen([sys.executable, os.path.abspath(__file__), "summary", item["id"]], start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if ai_enabled() and (cf["NOTES_AI"] == "1" or cf["NOTES_OVERVIEW"] == "1") and len(text) <= 6000:
        with contextlib.suppress(Exception):
            subprocess.Popen([sys.executable, os.path.abspath(__file__), "sort", item["id"]], start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return True

def add_note_locked(*a, **kw):
    """The picture and voice commands run without the big lock (a screen drag or a recording can take a long time and must not
    freeze every other note action): they take it only for the moment of writing."""
    with locked():
        ok = add_note(*a, **kw)
        sync_timer()
    return ok

IMG_TYPES = [("image/png", "png"), ("image/jpeg", "jpg"), ("image/webp", "webp"), ("image/gif", "gif"), ("image/bmp", "bmp")]
IMG_EXT = (".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg", ".bmp")

def _wlpaste(args, timeout=5):
    try:
        return subprocess.run(["wl-paste"] + args, capture_output=True, timeout=timeout)
    except Exception:
        return None

def _keep_image_file(src):
    """A picture somebody copied as a file: keep our own copy so the note survives the original being moved or deleted."""
    ext = os.path.splitext(src)[1].lower() or ".png"
    dst = os.path.join(MEDIA_DIR, f"img_{int(time.time() * 1000)}{ext}")
    shutil.copyfile(src, dst)
    return dst

def clipboard_image():
    """(path, None) with the picture on the clipboard saved in the media folder, or (None, why not)."""
    if not shutil.which("wl-paste"):
        return None, "wl-clipboard is not installed (pacman -S wl-clipboard)"
    r = _wlpaste(["--list-types"], 3)
    if r is None or r.returncode != 0:
        return None, "The clipboard is empty"
    types = r.stdout.decode("utf-8", "replace").split()
    for mime, ext in IMG_TYPES:
        if mime in types:
            path = os.path.join(MEDIA_DIR, f"img_{int(time.time() * 1000)}.{ext}")
            got = _wlpaste(["--no-newline", "-t", mime], 10)
            if got is not None and got.returncode == 0 and len(got.stdout) > 64:
                with open(path, "wb") as f:
                    f.write(got.stdout)
                return path, None
    # an image file copied in a file manager (a list of file:// links) or a path copied as text
    from urllib.parse import unquote, urlparse
    for mime in ("text/uri-list", "text/plain;charset=utf-8", "text/plain"):
        if mime in types:
            got = _wlpaste(["--no-newline", "-t", mime], 3)
            if got is None or got.returncode != 0:
                continue
            for line in got.stdout.decode("utf-8", "replace").splitlines():
                line = line.strip()
                cand = unquote(urlparse(line).path) if line.startswith("file://") else os.path.expanduser(line)
                if cand.lower().endswith(IMG_EXT) and os.path.isfile(cand):
                    return _keep_image_file(cand), None
    return None, "There is no picture on the clipboard"

def snip_region():
    """Drag a region of the screen (slurp + grim). (path, None) | (None, 'cancelled') | (None, why)."""
    if not (shutil.which("slurp") and shutil.which("grim")):
        return None, "There is no picture on the clipboard (and slurp + grim are needed to grab one from the screen)"
    time.sleep(0.6)                                    # the notes panel is sliding away: keep it out of the picture
    try:
        g = subprocess.run(["slurp", "-d"], capture_output=True, text=True, timeout=120)
    except Exception:
        return None, "cancelled"
    geom = g.stdout.strip()
    if g.returncode != 0 or not geom:
        return None, "cancelled"
    path = os.path.join(MEDIA_DIR, f"shot_{int(time.time() * 1000)}.png")
    r = subprocess.run(["grim", "-g", geom, path], capture_output=True)
    if r.returncode != 0 or not os.path.isfile(path) or os.path.getsize(path) < 64:
        with contextlib.suppress(OSError):
            os.unlink(path)
        return None, "grim could not take the picture"
    return path, None

def clip_image(text=""):
    """Clip img: the picture on the clipboard (a screenshot, a copied image, a copied image file) becomes a note.
    Nothing on the clipboard -> drag a region of the screen instead. Every outcome shows up as a notification, because the
    panel that asked has already slid away."""
    os.makedirs(MEDIA_DIR, exist_ok=True)
    path, why = clipboard_image()
    label = "Clipboard image"
    if not path:
        path, why = snip_region()
        label = "Screenshot"
        if not path and why == "cancelled":
            print("CLIP_CANCEL")
            return False
    if not path:
        print("CLIP_FAIL:" + (why or "no picture"))
        notify("Image note", why or "No picture to save", "dialog-warning")
        return False
    if add_note_locked(text or label, image=path):
        notify("Image added to notes", text or label, path)
        return True
    return False

def clip_paste(text=""):
    """Ctrl+V in the quick panel: only a picture that is really on the clipboard becomes a note (no screen-region fallback,
    no notification: the panel says "Saved" itself). Anything else prints CLIP_NONE and the panel pastes the text as usual."""
    os.makedirs(MEDIA_DIR, exist_ok=True)
    r = _wlpaste(["--list-types"], 3)
    types = r.stdout.decode("utf-8", "replace").split() if (r is not None and r.returncode == 0) else []
    if not any(m in types for m, _ in IMG_TYPES):
        # a copied image *file* (file:// link) counts too, but a plain path typed as text must stay text
        if "text/uri-list" not in types:
            print("CLIP_NONE")
            return False
    path, _why = clipboard_image()
    if not path:
        print("CLIP_NONE")
        return False
    if add_note_locked(text or "Clipboard image", image=path):
        print("CLIP_OK")
        return True
    print("CLIP_NONE")
    return False

def clip_stage():
    """Ctrl+V in the quick panel: the picture on the clipboard is KEPT but not saved as a note yet, so the panel can stay open
    and take a caption. Prints CLIP_STAGED:<path> (the panel shows the picture, Enter then saves it with `notes image`), or
    CLIP_NONE when there is no picture and the panel should paste the text instead."""
    os.makedirs(MEDIA_DIR, exist_ok=True)
    r = _wlpaste(["--list-types"], 3)
    types = r.stdout.decode("utf-8", "replace").split() if (r is not None and r.returncode == 0) else []
    if not any(m in types for m, _ in IMG_TYPES) and "text/uri-list" not in types:
        print("CLIP_NONE")
        return False
    path, _why = clipboard_image()
    if not path:
        print("CLIP_NONE")
        return False
    print("CLIP_STAGED:" + path)
    return True

def clip_drop(path=""):
    """Throw away a picture that was staged but never saved (the panel was closed or the picture was removed).
    Only files inside the notes media folder are ever deleted."""
    try:
        real = os.path.realpath(path)
        media = os.path.realpath(MEDIA_DIR) + os.sep
        if path and real.startswith(media) and os.path.basename(real).startswith("img_") and os.path.isfile(real):
            os.unlink(real)
            return True
    except OSError:
        pass
    return False

def shot_image(text=""):
    os.makedirs(MEDIA_DIR, exist_ok=True)
    now = time.time()
    nid = int(now * 1000)
    img_path = os.path.join(MEDIA_DIR, f"shot_{nid}.png")
    try:
        res = subprocess.run(["grim", img_path])
        if res.returncode == 0 and os.path.isfile(img_path):
            return add_note_locked(text or "Screenshot Note", image=img_path)
    except Exception as e:
        print(f"[!] Failed to grab screenshot: {e}")
    return False

# ---- voice notes: record -> text -> AI
def rec_command(path):
    """The recorder: 16 kHz mono is what the speech engines want, and keeps the file small."""
    if shutil.which("pw-record"):
        return ["pw-record", "--rate", "16000", "--channels", "1", path]
    if shutil.which("parecord"):
        return ["parecord", "--rate=16000", "--channels=1", "--file-format=wav", path]
    if shutil.which("arecord"):
        return ["arecord", "-q", "-f", "S16_LE", "-r", "16000", "-c", "1", path]
    return None

def _rec_info():
    try:
        with open(REC_PID_FILE, "r", encoding="utf-8") as f:
            info = json.load(f)
        pid = int(info.get("pid") or 0)
        os.kill(pid, 0)
        with open(f"/proc/{pid}/cmdline", "rb") as f:         # a pid that was reused by something else is not our recorder
            if b"record" not in f.read() and b"arecord" not in f.read():
                raise OSError
        return info
    except Exception:
        with contextlib.suppress(OSError):
            os.unlink(REC_PID_FILE)
        return None

def _stop_recorder(pid):
    with contextlib.suppress(OSError):
        os.kill(pid, signal.SIGINT)                          # SIGINT: the recorder finishes the file properly
    for _ in range(40):                                      # wait until it has really gone (the header is written at the end)
        try:
            os.kill(pid, 0)
        except OSError:
            return
        time.sleep(0.1)
    with contextlib.suppress(OSError):
        os.kill(pid, signal.SIGKILL)

def record_audio(text=""):
    os.makedirs(MEDIA_DIR, exist_ok=True)
    wav_path = os.path.join(MEDIA_DIR, f"rec_{int(time.time() * 1000)}.wav")
    cmd = rec_command(wav_path)
    if not cmd:
        print("[!] No recorder found (pipewire: pw-record)")
        return False
    print("\033[1;31mRecording voice note...\033[0m Press Enter or Ctrl+C to stop.")
    try:
        proc = subprocess.Popen(cmd)
        try:
            input()
        except (KeyboardInterrupt, EOFError):
            pass
        _stop_recorder(proc.pid)
        if os.path.isfile(wav_path) and os.path.getsize(wav_path) > 1000:
            print("\033[1;32m✓\033[0m Voice note saved.")
            return add_note_locked(text, audio=wav_path, stt=True)
        print("[!] Recording was empty or cancelled.")
        with contextlib.suppress(OSError):
            os.unlink(wav_path)
    except Exception as e:
        print(f"[!] Recording error: {e}")
    return False

def rec_start(text=""):
    os.makedirs(MEDIA_DIR, exist_ok=True)
    if _rec_info():
        print("REC_STARTED:already")
        return True
    now = time.time()
    wav_path = os.path.join(MEDIA_DIR, f"rec_{int(now * 1000)}.wav")
    cmd = rec_command(wav_path)
    if not cmd:
        print("REC_FAILED:No recorder found. Install pipewire (pw-record).")
        notify("Voice note", "No recorder found. Install pipewire (pw-record).", "dialog-warning")
        return False
    try:
        # its own session and no pipes: it must outlive this command (and the panel) and must not keep the caller's pipe open
        proc = subprocess.Popen(cmd, start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as e:
        print(f"REC_FAILED:{e}")
        return False
    time.sleep(0.4)
    if proc.poll() is not None:                              # it died at once: no microphone, no sound server ...
        print("REC_FAILED:The recorder stopped at once (is a microphone connected and unmuted?)")
        notify("Voice note", "The recorder stopped at once. Is a microphone connected and unmuted?", "dialog-warning")
        return False
    with open(REC_PID_FILE, "w", encoding="utf-8") as f:
        json.dump({"pid": proc.pid, "file": wav_path, "text": text, "start": now}, f)
    print(f"REC_STARTED:{proc.pid}")
    return True

def rec_stop():
    info = _rec_info()
    if not info:
        print("[!] No recording active.")
        return False
    wav_path = info.get("file")
    text = info.get("text") or ""
    _stop_recorder(int(info.get("pid") or 0))
    with contextlib.suppress(OSError):
        os.unlink(REC_PID_FILE)
    if wav_path and os.path.isfile(wav_path) and os.path.getsize(wav_path) > 1000:
        notify("Voice note saved", "Writing it down ...", "audio-input-microphone")
        return add_note_locked(text, audio=wav_path, stt=True)
    notify("Voice note", "The recording was empty.", "dialog-warning")
    return False

def rec_cancel():
    info = _rec_info()
    if not info:
        return False
    _stop_recorder(int(info.get("pid") or 0))
    with contextlib.suppress(OSError):
        os.unlink(REC_PID_FILE)
    with contextlib.suppress(OSError):
        os.unlink(info.get("file") or "")
    return True

def rec_status():
    info = _rec_info()
    if info:
        print(json.dumps({"recording": True, "file": info.get("file"), "started": info.get("start")}))
        return True
    print(json.dumps({"recording": False}))
    return False

def rec_toggle():
    """One key for voice notes: recording -> save it; not recording -> start. Meant for a Hyprland bind (it prints nothing the
    key press needs, and every state is said in a notification)."""
    if _rec_info():
        return rec_stop()
    ok = rec_start()
    if ok:
        notify("Voice note", "Recording. Press the same keys again to save it.", "audio-input-microphone")
    return ok

# ---- the text in a picture: tesseract (offline, copies what is there, cannot invent anything)
OCR_MISSING = "Reading the text in pictures needs tesseract: sudo pacman -S tesseract tesseract-data-eng"

def _clean_ocr(raw):
    """Lines that look like words stay; specks, borders and icons that tesseract turned into symbols go."""
    keep = []
    for line in raw.splitlines():
        line = re.sub(r"\s+", " ", line).strip()
        alnum = sum(ch.isalnum() for ch in line)
        if alnum >= 3 and alnum / len(line) >= 0.4:
            keep.append(line)
    text = "\n".join(keep).strip()
    if sum(ch.isalnum() for ch in text) < 8:
        return ""
    return text[:4000]

def run_ocr(path):
    """-> (text, None) ('' when the picture has no text), or (None, why not)."""
    exe = _which("tesseract")
    if not exe:
        return None, OCR_MISSING
    try:
        r = subprocess.run([exe, path, "stdout", "-l", "eng", "--psm", "3"], capture_output=True, timeout=90)
    except subprocess.TimeoutExpired:
        return None, "Reading the picture took too long."
    except OSError as e:
        return None, f"tesseract could not start: {e}"
    if r.returncode != 0:
        err = r.stderr.decode("utf-8", "replace")
        if "traineddata" in err or "eng" in err and "data" in err:
            return None, "tesseract has no English data: sudo pacman -S tesseract-data-eng"
        last = err.strip().splitlines()[-1] if err.strip() else ""
        return None, "tesseract could not read this picture" + (f": {last}" if last else "")
    return _clean_ocr(r.stdout.decode("utf-8", "replace")), None

def ocr_note(arg):
    t = find_note(load_notes(), arg)
    if not t or not t.get("image"):
        print("[!] That note has no picture.")
        return False
    nid, img = t.get("id"), t["image"]
    if not os.path.isfile(img):
        _patch_note(nid, lambda n: n.__setitem__("ocr", {"state": "fail", "at": time.time(), "msg": "The picture file is gone."}))
        return False
    _patch_note(nid, lambda n: n.__setitem__("ocr", {"state": "working", "at": time.time()}))
    text, err = run_ocr(img)
    if text is None:
        state = "none" if err == OCR_MISSING else "fail"
        _patch_note(nid, lambda n: n.__setitem__("ocr", {"state": state, "at": time.time(), "msg": err}))
        if sys.stdout.isatty():
            print("[!] " + err)
        return False
    _patch_note(nid, lambda n: n.__setitem__("ocr", {"state": "done" if text else "empty", "at": time.time(), "text": text}))
    if sys.stdout.isatty():
        print(text or "(no text found in the picture)")
    return True

# ---- a description of a picture from a local vision model (Ollama). Only when you ask: never automatically.
VLM_DEFAULT = "qwen2.5vl:3b"

def vlm_model():
    return (os.environ.get("HALCYON_VLM_MODEL") or read_conf().get("NOTES_VLM_MODEL", "") or VLM_DEFAULT).strip()

def _ground_description(text, ocr_text):
    """A small vision model likes to invent figures. A sentence that holds a number (2+ digits) which is not in the text read from
    the picture is dropped, the same rule the note overview follows. At most three sentences, no markdown."""
    text = re.sub(r"[*_`#>]+", "", text or "")
    text = re.sub(r"\s+", " ", text).strip()
    out = []
    for sent in re.split(r"(?<=[.!?])\s+", text):
        nums = re.findall(r"\d{2,}", sent)
        if nums and any(n not in (ocr_text or "") for n in nums):
            continue
        if sent.strip():
            out.append(sent.strip())
    return " ".join(out[:3])[:420]

def run_vlm(path, ocr_text=""):
    """-> (description, None) ('' when nothing usable came back), or (None, why not)."""
    model = vlm_model()
    if not ollama_up():
        return None, "Ollama is not running. Start it (sudo systemctl start ollama) and use Describe again."
    try:
        if os.path.getsize(path) > 12 * 1024 * 1024:
            return None, "The picture is too big to describe (over 12 MB)."
        with open(path, "rb") as f:
            b64 = base64.b64encode(f.read()).decode("ascii")
    except OSError as e:
        return None, f"The picture could not be read: {e}"
    prompt = ("Describe this picture for a note in at most two short sentences. Say only what is clearly visible. "
              "If something is unclear, say it is unclear. Do not guess names, places or numbers. ")
    if ocr_text:
        prompt += "Do not repeat the text in the picture; it was already read as: " + re.sub(r"\s+", " ", ocr_text)[:600]
    body = json.dumps({"model": model, "prompt": prompt, "images": [b64], "stream": False, "keep_alive": 0,
                       "options": {"temperature": 0, "num_predict": 160, "num_ctx": NUM_CTX}}).encode()
    try:
        import urllib.request, urllib.error
        req = urllib.request.Request(ollama_host() + "/api/generate", data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=300) as resp:           # the first answer also loads the model
            out = json.loads(resp.read().decode("utf-8", "replace")).get("response", "")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None, f"The picture model {model} is not installed. Run: ollama pull {model}"
        return None, f"Ollama answered with an error ({e.code})."
    except Exception:
        return None, "Ollama did not answer in time."
    return _ground_description(out, ocr_text), None

def describe_note(arg):
    cf = read_conf()
    if not ai_enabled():
        print("[!] " + ai_off_why())
        return False
    if cf["NOTES_VLM"] != "1":
        print("[!] Picture descriptions are off (Settings > Notes, or: notes set NOTES_VLM 1)")
        return False
    t = find_note(load_notes(), arg)
    if not t or not t.get("image"):
        print("[!] That note has no picture.")
        return False
    nid, img = t.get("id"), t["image"]
    if not os.path.isfile(img):
        _patch_note(nid, lambda n: n.__setitem__("describe", {"state": "fail", "at": time.time(), "msg": "The picture file is gone."}))
        return False
    ocr_text = ((t.get("ocr") or {}).get("text") or "")
    _patch_note(nid, lambda n: n.__setitem__("describe", {"state": "working", "at": time.time()}))
    text, err = run_vlm(img, ocr_text)
    if text is None:
        _patch_note(nid, lambda n: n.__setitem__("describe", {"state": "fail", "at": time.time(), "msg": err}))
        notify("Picture description", err, "dialog-warning")
        if sys.stdout.isatty():
            print("[!] " + err)
        return False
    if not text:
        msg = "The model's description did not match the picture's text, so it was left out rather than guess. Describe tries again."
        _patch_note(nid, lambda n: n.__setitem__("describe", {"state": "empty", "at": time.time(), "msg": msg}))
        if sys.stdout.isatty():
            print(msg)
        return False
    model = vlm_model()
    _patch_note(nid, lambda n: n.__setitem__("describe", {"state": "done", "at": time.time(), "text": text, "model": model}))
    if sys.stdout.isatty():
        print(f"[{model}]  {text}")
    return True

# ---- a full summary of a note of ANY length. The overview under a note is short on purpose; this one is not cut off anywhere:
# a long text is read in pieces, every piece gets its own gist and bullets, and all of them are kept. Every sentence is checked against
# the text it came from (the same rule as the overview): a sentence that says something the text does not is dropped, not shown.
SUMMARY_PIECE = 3200            # characters of the note one model call reads

def summary_source(n):
    """The words to summarise: the note itself, or for a picture note with no real words of its own what was read from / said about it."""
    t = (n.get("text") or "").strip()
    if n.get("image") and _word_count(t) < 8:
        return "\n".join(x for x in (((n.get("describe") or {}).get("text") or ""), ((n.get("ocr") or {}).get("text") or "")) if x).strip()
    return t

def _pieces(text, limit=SUMMARY_PIECE):
    units = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if len(line) <= limit:
            units.append(line)
        else:                                            # one very long paragraph: by sentence, and by length when there is no sentence end
            for sent in re.split(r"(?<=[.!?])\s+", line):
                while len(sent) > limit:
                    units.append(sent[:limit])
                    sent = sent[limit:]
                if sent:
                    units.append(sent)
    out, cur = [], ""
    for u in units:
        if cur and len(cur) + len(u) + 1 > limit:
            out.append(cur)
            cur = ""
        cur = (cur + "\n" + u) if cur else u
    if cur:
        out.append(cur)
    return out

def _summary_call(text, gist_only=False):
    """-> (gist, [bullets]) from the model for one piece of text, or None when Ollama does not answer. Not yet checked."""
    import urllib.request
    if gist_only:
        ask = ("Write ONE sentence that gives the main point of these notes together. Use ONLY facts written in them. Plain text.")
    else:
        ask = ("Summarise the text below for the person who saved it. Use ONLY facts that are written in it: no new numbers, causes or opinions. "
               "Keep its tenses: things still to do stay things to do and are never described as done. Write ONE sentence with the main point, "
               "then a list with one line per other important point, each line starting with '- '. Use as many lines as the text needs "
               "so that nothing important is missing. Plain text only: no headings, no bold.")
    prompt = ask + "\n\nText:\n" + text + "\n"
    body = json.dumps({"model": model_name(), "prompt": prompt, "stream": False, "think": False, "keep_alive": keep_alive(),
                       "options": {"temperature": 0, "num_predict": 700, "num_ctx": NUM_CTX}}).encode()
    try:
        req = urllib.request.Request(ollama_host() + "/api/generate", data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=240) as r:
            raw = json.loads(r.read().decode("utf-8", "replace")).get("response", "")
    except Exception:
        return None
    raw = re.sub(r"\*\*|__|`|^#+\s*", "", raw, flags=re.M)
    gist, bullets = "", []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        if re.match(r"^[-*\u2022]\s+", line):
            bullets.append(re.sub(r"^[-*\u2022]\s+", "", line).strip())
        elif not gist:
            gist = re.sub(r"\s+", " ", line)
        else:
            bullets.append(re.sub(r"\s+", " ", line))
    return gist, bullets

def summarise_text(text):
    """-> (summary text, None) or (None, why not). The gist first, then every checked bullet; nothing is cut off."""
    cl = checklist_of(text)
    if cl:
        return cl, None                                  # a list is already complete: shown as written
    gists, bullets = [], []
    for piece in _pieces(text):
        res = _summary_call(piece)
        if res is None:
            return None, "Ollama is not running (or did not answer), so there is no summary yet. Start it and use Summarise again."
        ns, nn = _stems(piece), _numbers(piece)
        g, bl = res
        if g and _grounded(g, ns, nn, piece):
            gists.append(g)
        for b in bl:
            if b and _grounded(b, ns, nn, piece) and all(_overlap(b, x) < 0.6 for x in bullets):
                bullets.append(b)
    # nothing written down may go missing: a point of the note that no kept line covers (its model line failed the check above,
    # e.g. "1 hour" for "1 hr") comes back in the note's own words, shortened
    for item in _points(text):
        if all(_overlap(item, x) < 0.35 for x in bullets + gists):
            bullets.append(_trim(item, 24))
    if not gists and not bullets:
        return "", None
    if len(gists) > 1:                                   # one sentence for the whole note, made from the pieces' own gists
        joined = "\n".join(gists)
        res = _summary_call(joined, gist_only=True)
        top = res[0] if res and res[0] and _grounded(res[0], _stems(joined), _numbers(joined), joined) else gists[0]
    else:
        top = gists[0] if gists else ""
    lines = ([top] if top else []) + ["- " + b for b in bullets]
    return "\n".join(lines), None

def summary_note(arg):
    if not ai_enabled():
        print("[!] " + ai_off_why())
        return False
    t = find_note(load_notes(), arg)
    if not t:
        print("[!] No such note.")
        return False
    nid, src = t.get("id"), summary_source(t)
    if _word_count(src) < 8:
        _patch_note(nid, lambda n: n.__setitem__("summary", {"state": "empty", "at": time.time(), "msg": "Too short to summarise (needs about 8 words)."}))
        return False
    _patch_note(nid, lambda n: n.__setitem__("summary", {"state": "working", "at": time.time()}))
    text, err = summarise_text(src)
    if text is None:
        _patch_note(nid, lambda n: n.__setitem__("summary", {"state": "fail", "at": time.time(), "msg": err}))
        if sys.stdout.isatty():
            print("[!] " + err)
        return False
    if not text:
        msg = "The model's summary did not match what the note says, so it was left out rather than guess. Summarise tries again."
        _patch_note(nid, lambda n: n.__setitem__("summary", {"state": "empty", "at": time.time(), "msg": msg}))
        if sys.stdout.isatty():
            print(msg)
        return False
    _patch_note(nid, lambda n: n.__setitem__("summary", {"state": "done", "at": time.time(), "text": text}))
    if sys.stdout.isatty():
        print(text)
    return True

# ---- search: what the note says, what was said, the text in its picture, its description, the AI line. Typos of one letter are fine.
def _note_fields(n):
    """(field name, weight, text) for every place a word can be found in a note."""
    return [("note", 3, n.get("text") or ""), ("transcript", 3, n.get("transcript") or ""),
            ("picture text", 2, (n.get("ocr") or {}).get("text") or ""), ("picture description", 2, (n.get("describe") or {}).get("text") or ""),
            ("overview", 1, (n.get("think") or {}).get("why") or ""), ("summary", 1, (n.get("summary") or {}).get("text") or "")]

def search_notes(query, notes=None):
    """-> [(index in the full list, note, [where the words were found]), ...] best first. Every word must be found somewhere."""
    terms = re.findall(r"\w+", (query or "").lower())
    if not terms:
        return []
    notes = load_notes() if notes is None else notes
    hits = []
    for i, n in enumerate(notes):
        if not isinstance(n, dict):
            continue
        fields = [(name, w, txt.lower()) for name, w, txt in _note_fields(n)]
        words = set()
        for _, _, txt in fields:
            words.update(re.findall(r"\w{4,}", txt))
        score, where, ok = 0, [], True
        for term in terms:
            found = [(name, w) for name, w, txt in fields if term in txt]
            if found:
                score += sum(w for _, w in found)
                where += [name for name, _ in found]
            elif len(term) >= 5 and difflib.get_close_matches(term, words, n=1, cutoff=0.8):
                score += 1
                where.append("note")
            else:
                ok = False
                break
        if ok:
            hits.append((score, i, n, sorted(set(where))))
    hits.sort(key=lambda h: (-h[0], h[1]))
    return [(i, n, where) for _, i, n, where in hits]

def search_cli(query):
    hits = search_notes(query)
    if not hits:
        print("Nothing found.")
        return
    for i, n, where in hits[:30]:
        first = (n.get("text") or "").strip().splitlines()[0] if (n.get("text") or "").strip() else "(no text)"
        extra = "" if where == ["note"] else "  \033[38;5;242m[found in: " + ", ".join(w for w in where) + "]\033[0m"
        print(f"{i + 1:>3}. {first[:90]}{extra}")

# ---- self-test: the things that were set up wrong so far, checked in one go
def selftest():
    cf = read_conf()
    bad = 0
    def line(ok, what, fix=""):
        nonlocal bad
        if not ok:
            bad += 1
        print(("  [ok] " if ok else "  [!!] ") + what + ("" if ok or not fix else f"\n         {fix}"))
    print("Notes: voice, AI and pictures")
    line(ai_enabled(), "AI features are switched on" if ai_enabled() else "AI features are switched off", "Settings > AI turns them on again")
    up = ollama_up()
    line(up, "Ollama is running" if up else "Ollama is not running", "systemctl start ollama   (pacman -S ollama if it is not installed)")
    installed = []
    if up:
        with contextlib.suppress(Exception):
            import urllib.request
            with urllib.request.urlopen(ollama_host() + "/api/tags", timeout=3) as resp:
                installed = [m.get("name", "") for m in json.loads(resp.read().decode("utf-8", "replace")).get("models", [])]
    def have_model(name):
        return any(m == name or m == name + ":latest" or (":" not in name and m.startswith(name + ":")) for m in installed)
    if up:
        line(have_model(model_name()), f"text model {model_name()} is installed" if have_model(model_name()) else f"text model {model_name()} is not installed",
             f"ollama pull {model_name()}")
        if cf["NOTES_VLM"] == "1":
            line(have_model(vlm_model()), f"picture model {vlm_model()} is installed" if have_model(vlm_model()) else f"picture model {vlm_model()} is not installed",
                 f"ollama pull {vlm_model()}")
    cli = _which("whisper-cli", "whisper-cpp", "whisper.cpp")
    py = False
    with contextlib.suppress(Exception):
        py = importlib.util.find_spec("faster_whisper") is not None
    oai = _which("whisper")
    line(bool(cli or py or oai), f"speech-to-text engine found ({cli or oai or 'faster-whisper'})" if (cli or py or oai) else "no speech-to-text engine", STT_MISSING)
    if cli:
        mf = stt_model_file()
        line(bool(mf), f"Whisper model found ({mf})" if mf else "whisper.cpp has no model", "yay -S whisper.cpp-model-base   (or set NOTES_STT_MODEL)")
    rc = rec_command("/tmp/halcyon-selftest.wav")
    line(bool(rc), "a recorder is available" if rc else "no recorder found", "sudo pacman -S pipewire")
    line(bool(shutil.which("wl-paste")), "wl-clipboard is installed (pasting pictures)" if shutil.which("wl-paste") else "wl-clipboard is missing",
         "sudo pacman -S wl-clipboard")
    tess = _which("tesseract")
    eng = False
    if tess:
        with contextlib.suppress(Exception):
            eng = "eng" in subprocess.run([tess, "--list-langs"], capture_output=True, timeout=10).stdout.decode("utf-8", "replace").split()
    line(bool(tess and eng), "tesseract is installed with English data (text in pictures)" if (tess and eng) else
         ("tesseract has no English data" if tess else "tesseract is not installed (text in pictures)"),
         "sudo pacman -S tesseract tesseract-data-eng")
    print("Everything is ready." if not bad else f"{bad} thing(s) to fix.")
    return bad == 0

# ---- speech to text. Offline engines only; the first one that is installed is used.
STT_MISSING = ("No speech-to-text engine found. Install one: whisper.cpp (sudo pacman -S whisper-cpp, plus yay -S whisper.cpp-model-base), "
               "or pip install faster-whisper")

def stt_setting(key):
    return (os.environ.get("HALCYON_" + key[len("NOTES_"):]) or read_conf().get(key, "") or "").strip()

def stt_model_file():
    """A whisper.cpp model (ggml-*.bin): the one set in NOTES_STT_MODEL, else the best one found in the usual places."""
    own = os.path.expanduser(stt_setting("NOTES_STT_MODEL"))
    if own and os.path.isfile(own):
        return own
    import glob
    dirs = [os.path.join(HOME, ".local", "share", "whisper.cpp", "models"), os.path.join(HOME, ".local", "share", "whisper.cpp"),
            os.path.join(HOME, ".cache", "whisper.cpp"), os.path.join(HOME, ".local", "share", "whisper"),
            "/usr/share/whisper.cpp/models", "/usr/share/whisper.cpp", "/usr/local/share/whisper.cpp/models",
            "/usr/share/whisper.cpp-model-*", "/opt/whisper.cpp/models"]
    found = []
    for d in dirs:
        for dd in glob.glob(d):
            found += glob.glob(os.path.join(dd, "ggml-*.bin"))
    if not found:
        return None
    def rank(f):
        b = os.path.basename(f)
        for i, k in enumerate(("base", "small", "tiny", "medium")):          # fast enough on a laptop first
            if k in b:
                return i
        return 9
    return sorted(found, key=rank)[0]

def _clean_words(t):
    t = re.sub(r"\[[A-Za-z_ ]+\]|\((?:music|silence|noise)[^)]*\)", " ", t or "", flags=re.I)    # [BLANK_AUDIO], (music) ...
    return re.sub(r"\s+", " ", t).strip()

FW_SCRIPT = ("import sys\nfrom faster_whisper import WhisperModel\n"
             "m = WhisperModel(sys.argv[2], device='cpu', compute_type='int8')\n"
             "segs, _ = m.transcribe(sys.argv[1], language=(sys.argv[3] or None), vad_filter=True)\n"
             "print(' '.join(s.text.strip() for s in segs))\n")

def _which(*names):
    """First of `names` found on PATH, or in the places a package or a pip/cargo install puts a program that the desktop
    session's own PATH (it is shorter than a terminal's) may not list. Returns the full path or None."""
    extra = os.pathsep.join([os.path.join(HOME, ".local", "bin"), os.path.join(HOME, ".cargo", "bin"), "/usr/local/bin",
                             "/usr/bin", "/opt/whisper.cpp/bin", "/opt/whisper.cpp/build/bin", "/opt/whisper/bin"])
    for n in names:
        hit = shutil.which(n) or shutil.which(n, path=extra)
        if hit:
            return hit
    return None

def run_stt(wav):
    """(text, None) | (None, why). An empty text means nothing was said."""
    lang = stt_setting("NOTES_STT_LANG")
    last = None
    cli = _which("whisper-cli", "whisper-cpp", "whisper.cpp")
    model = stt_model_file()
    if cli and model:
        cmd = [cli, "-m", model, "-f", wav, "-nt", "-np", "-t", str(min(8, os.cpu_count() or 4))]
        if ".en" not in os.path.basename(model):
            cmd += ["-l", lang or "auto"]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
            if r.returncode == 0:
                return _clean_words(r.stdout), None
            last = "whisper.cpp failed: " + (r.stderr or "").strip()[-160:]
        except Exception as e:
            last = f"whisper.cpp failed ({type(e).__name__})"
    if importlib.util.find_spec("faster_whisper"):
        name = stt_setting("NOTES_STT_MODEL")
        name = name if name and not os.path.isfile(os.path.expanduser(name)) else "base"
        try:
            r = subprocess.run([sys.executable, "-c", FW_SCRIPT, wav, name, lang], capture_output=True, text=True, timeout=1800)
            if r.returncode == 0:
                return _clean_words(r.stdout), None
            last = "faster-whisper failed: " + (r.stderr or "").strip()[-160:]
        except Exception as e:
            last = f"faster-whisper failed ({type(e).__name__})"
    oai = _which("whisper")
    if oai:
        with tempfile.TemporaryDirectory() as td:
            cmd = [oai, wav, "--model", "base", "--output_format", "txt", "--output_dir", td, "--fp16", "False"]
            if lang:
                cmd += ["--language", lang]
            try:
                r = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
                out = os.path.join(td, os.path.splitext(os.path.basename(wav))[0] + ".txt")
                if r.returncode == 0 and os.path.isfile(out):
                    with open(out, "r", encoding="utf-8") as f:
                        return _clean_words(f.read()), None
                last = "whisper failed: " + (r.stderr or "").strip()[-160:]
            except Exception as e:
                last = f"whisper failed ({type(e).__name__})"
    if last:
        return None, last
    if cli and not model:
        return None, "whisper.cpp is installed but no model was found. Install one (yay -S whisper.cpp-model-base) or set NOTES_STT_MODEL"
    return None, STT_MISSING

def _patch_note(nid, fn):
    with locked():
        notes = load_notes()
        n = next((x for x in notes if x.get("id") == nid), None)
        if n is None:
            return False
        fn(n)
        save_notes(notes)
    refresh_ui()
    return True

def transcribe_note(arg):
    """Voice note -> words -> the AI. Runs in the background after a recording; the model and the engine are used WITHOUT the lock."""
    t = find_note(load_notes(), arg)
    if not t or not t.get("audio"):
        print("[!] That note has no voice recording.")
        return False
    nid, wav, typed = t.get("id"), t["audio"], (t.get("typed") or "")
    if not os.path.isfile(wav):
        _patch_note(nid, lambda n: n.__setitem__("stt", {"state": "fail", "at": time.time(), "msg": "The recording file is gone."}))
        return False
    _patch_note(nid, lambda n: n.__setitem__("stt", {"state": "working", "at": time.time()}))
    text, err = run_stt(wav)
    if text is None:
        state = "none" if err == STT_MISSING else "fail"
        _patch_note(nid, lambda n: n.__setitem__("stt", {"state": state, "at": time.time(), "msg": err}))
        notify("Voice note", err, "dialog-warning")
        return False
    if not text:
        _patch_note(nid, lambda n: n.__setitem__("stt", {"state": "empty", "at": time.time(), "msg": "No words were heard in this recording."}))
        notify("Voice note", "No words were heard in the recording.", "dialog-information")
        return False
    def apply(n):
        n["transcript"] = text
        n["text"] = (typed + "\n" if typed else "") + text
        n["stt"] = {"state": "done", "at": time.time()}
        n.pop("think", None)                              # so the AI reads the new words (also after a second transcribe)
        n.pop("sorted", None)
    if not _patch_note(nid, apply):
        return False
    notify("Voice note written down", text[:160], "audio-input-microphone")
    cf = read_conf()
    if ai_enabled() and (cf["NOTES_AI"] == "1" or cf["NOTES_OVERVIEW"] == "1"):
        sort_note(nid)                                    # the same AI step every typed note gets
    return True

def play_audio(arg):
    n = find_note(load_notes(), arg)
    if not n or not n.get("audio"):
        print("[!] Note does not have audio.")
        return False
    audio_path = n["audio"]
    if not os.path.isfile(audio_path):
        print(f"[!] Audio file not found: {audio_path}")
        return False
    print(f"Playing: {audio_path}")
    player = next((p for p in ("pw-play", "paplay", "aplay") if shutil.which(p)), None)
    if player:
        subprocess.run([player, audio_path])
        return True
    print("[!] No audio player found (pw-play, paplay, aplay)")
    return False

def list_notes():
    notes = load_notes()
    if not notes:
        print("\033[38;5;244mNo notes yet. Add one with: notes : <your text>\033[0m")
        return
    print("\033[1;35mHalcyon Notes\033[0m")
    print("──────────────────────────────────────────────────")
    for i, n in enumerate(notes, 1):
        pin = "\033[1;33m★ \033[0m" if n.get("pinned") else "  "
        status = "\033[38;5;242m[✓] \033[9m" if n.get("done") else "\033[1m"
        reset = "\033[0m"
        date = n.get("date", "")
        task = "\033[38;5;214m☑ \033[0m" if n.get("task") else ""
        due = f" \033[38;5;214mdue {due_text(n['due'])}\033[0m" if n.get("due") else (" \033[38;5;214mlater today\033[0m" if n.get("later") else "")
        img_badge = " \033[38;5;111mimg\033[0m" if n.get("image") else ""
        aud_badge = " \033[38;5;178mvoice\033[0m" if n.get("audio") else ""
        print(f"{i:2d}. {pin}{task}{status}{n.get('text', '')}{reset}{img_badge}{aud_badge}{due} \033[38;5;240m({date})\033[0m")
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
            if removed.get("image") and str(removed["image"]).startswith(MEDIA_DIR):
                with contextlib.suppress(OSError):
                    os.unlink(removed["image"])
            if removed.get("audio") and str(removed["audio"]).startswith(MEDIA_DIR):
                with contextlib.suppress(OSError):
                    os.unlink(removed["audio"])
            print(f"\033[1;31m✗\033[0m Deleted: \"{removed.get('text')}\"")
            refresh_ui()
            sync_timer(notes)
            return
    except ValueError:
        pass
    for i, n in enumerate(notes):
        if n.get("id") == arg:
            removed = notes.pop(i)
            save_notes(notes)
            if removed.get("image") and str(removed["image"]).startswith(MEDIA_DIR):
                with contextlib.suppress(OSError):
                    os.unlink(removed["image"])
            if removed.get("audio") and str(removed["audio"]).startswith(MEDIA_DIR):
                with contextlib.suppress(OSError):
                    os.unlink(removed["audio"])
            print(f"\033[1;31m✗\033[0m Deleted: \"{removed.get('text')}\"")
            refresh_ui()
            sync_timer(notes)
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

SKY_LOG = os.path.join(STATE_DIR, "sky-events.jsonl")

def _sky_log(kind, nid, text=""):
    """The weekly sky (scripts/weekly-sky.py) draws one star per finished note. `done_at` on the note says when, but clearing the
    done notes deletes them, so each tick is also kept in this small append-only log ({"t", "kind": "task" | "untask", "id", "text"}).
    A failure here must never get in the way of ticking a note, so everything is swallowed."""
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(SKY_LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"t": time.time(), "kind": kind, "id": nid, "text": (text or "")[:80]}, ensure_ascii=False) + "\n")
        if os.path.getsize(SKY_LOG) > 400_000:                      # keep the last ~2000 ticks, the sky only ever looks back a few weeks
            with open(SKY_LOG, "r", encoding="utf-8") as fh:
                tail = fh.readlines()[-2000:]
            with open(SKY_LOG + ".tmp", "w", encoding="utf-8") as fh:
                fh.writelines(tail)
            os.replace(SKY_LOG + ".tmp", SKY_LOG)
    except Exception:
        pass

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
    if target and target.get("repeat") in REPEATS and not target.get("done"):
        # a repeating task is never finished by a tick: ticking before today's time skips today's, after it nothing changes
        due, now = target.get("due"), time.time()
        if due and due > now and due_text(due).startswith("Today"):
            target["due"] = next_due(due, target["repeat"], due)
            target.pop("anchor", None)
            target["reminded"] = False
            save_notes(notes)
        print(f"✓ Done for now, next {due_text(target['due']) if target.get('due') else 'time not set'}: \"{target.get('text')}\" (notes repeat <n> none stops it)")
        return
    if target:
        target["done"] = not target.get("done", False)
        if target["done"]:
            target["done_at"] = time.time()                       # when it was finished: a star in the weekly sky
            _sky_log("task", target.get("id", ""), target.get("text", ""))
        else:
            target.pop("done_at", None)
            _sky_log("untask", target.get("id", ""))
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
# Master AI switch: Settings > Performance > "AI features" (or: python3 ai-models.py master on|off). Off = this file exists.
# Nothing local is deleted and Ollama itself is left running; Halcyon just stops asking any model anything.
AI_OFF_FLAG = os.path.join(os.path.expanduser("~"), ".local", "state", "island", "ai-off")

# Gaming mode is on (scripts/gamemode.sh writes this file, and unloads the models): the GPU memory is the game's, so no model is
# loaded now. Notes are still saved, just without the AI sorting / overview. Only a regular file of ours counts: /dev/shm is
# writable by every local user.
GAMING_FLAG = "/dev/shm/halcyon-gamemode"

def gaming():
    try:
        st = os.lstat(GAMING_FLAG)
    except OSError:
        return False
    return (st.st_mode & 0o170000) == 0o100000 and st.st_uid == os.getuid()

def ai_switched_on():
    return not os.path.exists(AI_OFF_FLAG)

def ai_enabled():
    return ai_switched_on() and not gaming()

def ai_off_why():
    return "Gaming mode is on: the AI is paused so the game keeps the GPU memory." if ai_switched_on() else "AI features are switched off (Settings > AI)."

# The context window every Halcyon AI script asks for: Ollama loads the model again whenever it changes between two requests,
# so chat, agent, advisor, notes and the brief all use the same one (keep it equal in each of them).
NUM_CTX = 8192

CONF_DEFAULTS = {"NOTES_SUMMARY": "0", "NOTES_OCR": "1", "NOTES_VLM": "0", "NOTES_VLM_MODEL": "", "NOTES_AI": "0", "NOTES_OVERVIEW": "0", "NOTES_AI_MODE": "ask", "NOTES_NUDGE_HOURS": "3", "NOTES_NUDGE_MAX": "4",
                 "NOTES_NUDGE_FROM": "9", "NOTES_NUDGE_TO": "21", "NOTES_MODEL": "", "NOTES_STT_MODEL": "", "NOTES_STT_LANG": ""}
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
    c["NOTES_SUMMARY"] = "1" if c["NOTES_SUMMARY"] == "1" else "0"   # a full summary of every long note by itself: off unless switched on
    c["NOTES_OCR"] = "0" if c["NOTES_OCR"] == "0" else "1"       # reading the text in pictures is on unless switched off
    c["NOTES_VLM"] = "1" if c["NOTES_VLM"] == "1" else "0"       # describing pictures with a model is off unless switched on
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
            keep = [l.rstrip("\n") for l in f if not re.match(r"\s*(NOTES_AI(_MODE)?|NOTES_OVERVIEW|NOTES_SUMMARY|NOTES_OCR|NOTES_VLM(_MODEL)?|NOTES_MODEL|NOTES_STT_(MODEL|LANG)|NOTES_NUDGE_(HOURS|MAX|FROM|TO))=", l)]
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
    same_wd = False                                # the named weekday is today: today if the time is still ahead, else next week
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
                ahead = (i - lt.tm_wday) % 7
                if ahead == 0:
                    ahead, same_wd = 7, True
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
    if same_wd:
        t = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, hh, mm, 0, 0, 0, -1))
        if t > now + 5:
            return t
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
                       "keep_alive": keep_alive(), "options": {"temperature": 0, "num_predict": 130, "num_ctx": NUM_CTX}}).encode()
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
                       "keep_alive": keep_alive(), "options": {"temperature": 0, "num_predict": 40 + 3 * words, "num_ctx": NUM_CTX}}).encode()
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

def _points(text):
    """The separate points of a note: its numbered / bulleted items, else its lines, else its sentences (only ones with 4+ words)."""
    t = text.strip()
    parts = re.split(r"[\u2022\u25cf\u25aa\u25e6\u2023]|(?:^|\n)\s*(?:[-*]\s+|\d{1,2}[.)]\s+)", t)
    parts = [re.sub(r"\s+", " ", x).strip(" -*") for x in parts]
    if len([x for x in parts if x]) < 2:
        parts = [x.strip() for x in t.splitlines()]
    if len([x for x in parts if x]) < 2:
        parts = re.split(r"(?<=[.!?])\s+", t)
    return [x for x in parts if len(x.split()) >= 4]

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
    # every item in full and every item listed: an overview that cuts things off hides exactly what was written down
    lines = [f"Checklist, {len(items)} items"] + ["- " + x for x in items]
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
                       "keep_alive": keep_alive(), "options": {"temperature": 0, "num_predict": 220, "num_ctx": NUM_CTX}}).encode()
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
    """What the AI line says when the model's own sentence was unusable: the note itself, tidied and shortened at a word
    boundary. No "Note about:" prefix and never a trailing "..." (it looked like a bug in the list)."""
    t = re.sub(r"\s+", " ", text).strip()
    if not t:
        return ""
    if len(t) > 110:
        cut = t[:110]
        stop = max(cut.rfind(". "), cut.rfind("? "), cut.rfind("! "))
        cut = cut[:stop + 1] if stop >= 40 else cut[:cut.rfind(" ")] if " " in cut else cut
        t = cut
    t = t.rstrip(" ,;:-\u2013\u2014.\u2026")
    return t[:1].upper() + t[1:]

def title_of(why):
    """The first line of an overview as a one-line title for the list: no bullet, no trailing dots."""
    first = (why or "").split("\n")[0].strip()
    first = re.sub(r"^[-*\u2022]\s*", "", first).rstrip(" .\u2026")
    return first[:160]

PLAIN_WHY = "Looks like a plain note: nothing you have to do."      # the list does not show this one (it says nothing)

def make_why(task, due, later, conf):
    """What the AI line says when the model gave no sentence of its own (small models often skip it)."""
    if not task:
        return PLAIN_WHY
    if due:
        return f"Reminder set for {due_text(due).lower()}."
    if later:
        return f"A task for later today: I will nudge you every {conf['NOTES_NUDGE_HOURS']} h, at most {conf['NOTES_NUDGE_MAX']} times."
    return "A task with no time named, so no reminder."

CLOCK_RE = re.compile(r"\b(\d{1,2}(?::\d{2})?\s*(?:am|pm|a\\.m\\.|p\\.m\\.)|(?:[01]?\d|2[0-3]):[0-5]\d|(?<=\bat )\d{1,2}(?!\s*(?:items?|people|persons?|times?|pieces?|things?|kg|km|years?|days?|hours?|minutes?|mins?|dollars|rs|inr)\b))(?![\d:%])", re.I)

def note_time(text):
    """A clock time the note itself writes ('9:30 AM', 'at 6', '19:45'), as a spec parse_when understands, with the day word in front when
    the note names one. None when the note has none. A small model gets times wrong ('9:30 AM' became 'tomorrow 19:58'), so when the
    note says a time, that time wins. With several times ('at 8 and 20:00') the next one still to come is taken."""
    ms = list(CLOCK_RE.finditer(text))
    if not ms:
        return None
    day = re.search(r"\b(tomorrow|today|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b", text, re.I)
    specs = [(day.group(1).lower() + " " if day else "") + re.sub(r"\s+", "", m.group(1).lower()) for m in ms]
    now = time.time()
    best = None
    for sp in specs:
        try:
            ts = parse_when(sp, now)
        except ValueError:
            continue
        if ts and (best is None or ts < best[0]):
            best = (ts, sp)
    return best[1] if best else specs[0]

# ---- repeating tasks: "every Monday 9am", "daily at 8", "every weekday", "monthly"
REPEATS = ("daily", "weekdays", "weekly", "monthly")
_DAYNAMES = "monday|tuesday|wednesday|thursday|friday|saturday|sunday"
REPEAT_RES = (
    ("weekdays", re.compile(r"\bevery ?week ?days?\b|\bon week ?days\b|\bweek ?days\b|\bmon(?:day)? ?(?:to|-|through) ?fri(?:day)?\b", re.I)),
    ("daily", re.compile(r"\bevery ?day\b|\bdaily\b|\beach day\b", re.I)),
    ("monthly", re.compile(r"\bevery month\b|\bmonthly\b|\beach month\b", re.I)),
    ("weekly", re.compile(r"\bevery week\b|\bweekly\b|\beach week\b|\b(?:every|each) (?:" + _DAYNAMES + r")s?\b", re.I)),
)

def parse_repeat(text):
    """'daily' | 'weekdays' | 'weekly' | 'monthly' when the note says it repeats ('every Monday', 'daily', 'every weekday'), else None."""
    for kind, rx in REPEAT_RES:
        if rx.search(text or ""):
            return kind
    return None

def next_due(ts, repeat, after):
    """The first time of a repeating task that is later than `after`, stepping from ts at the same clock time (day, weekdays, week or
    month at a time, so a computer that was off for days does not fire once per missed day, and the time never drifts)."""
    lt = time.localtime(ts)
    y, mo, d, hh, mi = lt.tm_year, lt.tm_mon, lt.tm_mday, lt.tm_hour, lt.tm_min
    for _ in range(4000):
        if repeat == "monthly":
            mo += 1
            y, mo = y + (mo - 1) // 12, (mo - 1) % 12 + 1
            cand = time.mktime((y, mo, min(lt.tm_mday, calendar.monthrange(y, mo)[1]), hh, mi, 0, 0, 0, -1))
        else:
            d += 7 if repeat == "weekly" else 1
            cand = time.mktime((y, mo, d, hh, mi, 0, 0, 0, -1))
            if repeat == "weekdays" and time.localtime(cand).tm_wday >= 5:
                continue
        if cand > after:
            return cand
    return ts + 86400

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
    elif 7 <= h <= 11 and re.search(r"\b(tonight|evening|afternoon)\b", text, re.I) and not re.search(r"\b\d{1,2}(:\d{2})?\s*(am|a\.m\.)|\bmorning\b", text, re.I):
        ts += 12 * 3600                    # "tonight at 11" is 23:00, never 11:00 in the morning
    hasday = re.search(r"\b(tomorrow|today|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b|\d{4}-\d{1,2}-\d{1,2}", text, re.I)
    h = time.localtime(ts).tm_hour
    if (not hasday and 7 <= h <= 11 and ts - 12 * 3600 > now
            and not re.search(r"\b(morning|am|a\.m\.)\b|\d\s*(am|a\.m\.)", text, re.I)):
        ts -= 12 * 3600                    # "at 9" said at 10:11: parse_when already rolled to tomorrow 09:00, but 21:00 today is sooner
    elif ts - 86400 > now and not hasday:
        ts -= 86400                        # the +12 h above landed on tomorrow although the same time today is still to come
    if ts <= now and 7 <= time.localtime(ts).tm_hour <= 11 and ts + 12 * 3600 > now \
            and not re.search(r"\b(am|a\.m\.|morning)\b", text, re.I) and not re.search(r"\b\d{1,2}(:\d{2})?\s*(am|a\.m\.)", text, re.I):
        ts += 12 * 3600                    # "at 9" said at 10:11, no am / morning: the evening 9 (21:00) is still to come today
    if ts <= now:
        lt = time.localtime(now)
        if ts >= time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1)):
            ts += 86400                    # "at 3" said after 3 o'clock: the next one is tomorrow
        else:
            return None                    # a day that is already over
    return ts

# Words that make a note a task on their own: the person asked for a reminder or named a job. A small model (or the overview-only
# mode, where no task sorting runs at all) must not be what decides "give me a reminder to call my mom at 9" is just a note.
TASK_CUE_RE = re.compile(
    r"\bremind (?:me|us)\b"
    r"|\b(?:give|set|make|add|create|put)\b[^.\n]{0,25}\breminder\b"
    r"|^\s*reminder\b"
    r"|\bremember to\b|\bdon'?t forget\b|\bdo not forget\b|\bto-?do\b"
    r"|\b(?:i|we) (?:need|have|got) to\b(?!\s+(?:say|admit|confess|tell you|mention|point out)\b)"
    r"|\b(?:i|we) must\b(?!\s+(?:say|admit|confess|be|have|mention|add|note)\b)", re.I | re.M)

def explicit_task(text):
    """True when the note itself asks for a reminder or names a job to do (short notes only: an article is never a task)."""
    t = (text or "").strip()
    return 0 < len(t) <= 280 and t.count("\n") <= 3 and bool(TASK_CUE_RE.search(t)) and not code_label(t)

def apply_rule_task(nid, text, conf):
    """Make the note a task now (with its reminder time when it names one). Never touches a note that already has a task
    answer (a task, or one you turned back into a plain note by hand) or one that is done."""
    due = resolve_due(text, None)
    with locked():
        notes = load_notes()
        n = next((x for x in notes if x.get("id") == nid), None)
        if n is None or "task" in n or n.get("done"):
            return
        n["task"] = True
        n["ai"] = True
        n["sorted"] = True
        n.pop("suggest", None)
        if due:
            n["due"] = due
            n["reminded"] = False
            rep = parse_repeat(text)
            if rep:
                n["repeat"] = rep
        elif re.search(r"\blater\b", text, re.I):
            start_later(n, conf)
        save_notes(notes)
        sync_timer(notes)

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
    if not ai_enabled():
        print("[!] " + ai_off_why())
        return
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
        if explicit_task(text):
            apply_rule_task(nid, text, conf)
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
                if ov:
                    n["think"] = {"state": "done", "at": time.time(), "why": ov, "task": bool(n.get("task")), "real": True}
                else:
                    # nothing usable came back: say so instead of showing an empty line (it looked like the AI did not run at all)
                    miss = ("Too short to write an overview of (needs about 8 words)." if _word_count(text) < 8 else
                            "The AI's summary did not match what the note says, so it was left out rather than guess. Think tries again.")
                    n["think"] = {"state": "done", "at": time.time(), "why": miss, "task": bool(n.get("task")), "real": False}
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
        real = bool(say) or (not tiny and bool(plain_summary(text)))     # False = a status message (make_why), not an overview of the note
        why = say or (make_why(ans["task"], due, later, conf) if tiny else (plain_summary(text) or make_why(ans["task"], due, later, conf)))
        if ov_on and (len(text) > 140 or checklist_of(text)):
            ov2 = overview_of(text)
            if ov2:
                why, real = ov2, True
        if due and say and not (ov_on and (len(text) > 140 or checklist_of(text))):
            why = (why.rstrip(".") + f"  ·  reminder {due_text(due).lower()}")[:200]
        with locked():
            notes = load_notes()
            n = next((x for x in notes if x.get("id") == nid), None)
            if n is None:                                              # deleted in the meantime
                return
            think = {"state": "done", "at": time.time(), "why": why, "task": bool(ans["task"]), "real": bool(real)}
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
                            if parse_repeat(text):
                                n["repeat"] = parse_repeat(text)
                        elif later:
                            start_later(n, conf)
                    else:
                        n["suggest"] = {"due": due, "later": later, "repeat": parse_repeat(text) if due else None}
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
        n.pop("repeat", None)
        n.pop("anchor", None)
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
            print(f"Later today: a nudge about every {conf['NOTES_NUDGE_HOURS']} h from {time.strftime('%H:%M', time.localtime(first))}: \"{n.get('text')}\"")
        else:
            print(f"Later today: it is too late in the day for a nudge; it stays in your tasks: \"{n.get('text')}\"")
        return
    try:
        ts = parse_when(spec)
    except ValueError as e:
        print(f"[!] {e}")
        return
    n.pop("suggest", None)
    n["sorted"] = True
    clear_later(n)
    n.pop("anchor", None)
    if ts is None:
        n.pop("due", None)
        n.pop("reminded", None)
        n.pop("repeat", None)
        save_notes(notes)
        print(f"✓ No reminder: \"{n.get('text')}\"")
        return
    n["task"] = True
    n["due"] = ts
    n["reminded"] = False
    save_notes(notes)
    print(f"Reminder {due_text(ts)}: \"{n.get('text')}\"")

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
            if sg.get("repeat") in REPEATS:
                n["repeat"] = sg["repeat"]
        elif sg.get("later"):
            start_later(n, read_conf())
    save_notes(notes)
    print("✓ Task" if yes else "✓ Stays a note")

SNOOZE_CHOICES = (("snooze", "Snooze 10 min", "+10m"), ("hour", "Snooze 1 h", "+1h"))

def _has_actions():
    """notify-send 0.7.10+ can show buttons (--action) and wait for the click (--wait)."""
    exe = shutil.which("notify-send")
    if not exe:
        return False
    try:
        out = subprocess.run([exe, "--help"], capture_output=True, text=True, timeout=3)
        return "--action" in (out.stdout + out.stderr)
    except Exception:
        return False

def remind_with_buttons(n, late):
    """Show the reminder with Snooze / Done buttons. The waiting for a click runs on its own (systemd-run, so the minute timer's service
    ending does not kill it); False = buttons are not possible here and the caller shows the plain notification."""
    if not (_has_actions() and n.get("id")):
        return False
    cmd = [sys.executable, os.path.abspath(__file__), "remind-act", n["id"]] + (["late"] if late else [])
    try:
        if shutil.which("systemd-run"):
            cmd = ["systemd-run", "--user", "--quiet", "--collect", "--no-block"] + cmd
        subprocess.Popen(cmd, start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception:
        return False

def remind_act(ref, late=False):
    """Shows one reminder with buttons and waits up to 10 minutes for a click: Snooze 10 min / Snooze 1 h put the reminder back
    (a repeating task keeps its schedule), Done completes a one-time task. Never holds the notes lock while it waits."""
    n = find_note(load_notes(), ref)
    if not n:
        return
    nid = n.get("id")
    repeating = n.get("repeat") in REPEATS
    cmd = ["notify-send", "--wait", "-a", "Halcyon", "-i", "appointment-soon", "-u", "normal"]
    for key, label, _ in SNOOZE_CHOICES:
        cmd += ["-A", f"{key}={label}"]
    if not repeating:
        cmd += ["-A", "done=Done"]
    cmd += ["Reminder (a little late)" if late else "Reminder", (n.get("text") or "").strip()[:200]]
    try:
        act = subprocess.run(cmd, capture_output=True, text=True, timeout=600).stdout.strip()
    except Exception:
        return
    me = [sys.executable, os.path.abspath(__file__)]
    for key, _, spec in SNOOZE_CHOICES:
        if act == key:
            subprocess.run(me + ["snooze", nid, spec], timeout=20)
    if act == "done" and not repeating:
        cur = find_note(load_notes(), nid)
        if cur and not cur.get("done"):                  # never un-complete a note that was ticked in the meantime
            subprocess.run(me + ["done", nid], timeout=20)

def snooze_note(arg, spec):
    """Put a reminder back to <spec> (+10m ...) without touching a repeating task's schedule (its next time stays in `anchor`)."""
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
    if ts is None:
        print("[!] snooze needs a time like +10m")
        return
    if n.get("repeat") in REPEATS and not n.get("anchor") and n.get("due") and n["due"] > time.time():
        n["anchor"] = n["due"]                           # keep the real schedule while this one fires early/late
    n["task"] = True
    n["due"] = ts
    n["reminded"] = False
    save_notes(notes)
    print(f"Snoozed to {due_text(ts)}: \"{n.get('text')}\"")

def set_repeat(arg, kind):
    notes = load_notes()
    n = find_note(notes, arg)
    if not n:
        print(f"[!] Note not found: {arg}")
        return
    kind = (kind or "").strip().lower()
    if kind in ("none", "off", "no", "stop", "-"):
        n.pop("repeat", None)
        n.pop("anchor", None)
        save_notes(notes)
        print(f"✓ No repeat: \"{n.get('text')}\"")
        return
    kind = {"day": "daily", "everyday": "daily", "weekday": "weekdays", "week": "weekly", "month": "monthly"}.get(kind, kind)
    if kind not in REPEATS:
        print("usage: notes repeat <number> <daily | weekdays | weekly | monthly | none>")
        return
    if not n.get("due"):
        print(f"[!] Give it a time first: notes due {arg} 9am")
        return
    n["task"] = True
    n["repeat"] = kind
    n.pop("anchor", None)
    save_notes(notes)
    print(f"Repeats {kind}, next {due_text(n['due'])}: \"{n.get('text')}\"")

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
            if not remind_with_buttons(n, late):
                notify("Reminder" if not late else "Reminder (a little late)", (n.get("text") or "").strip()[:200])
            rep = n.get("repeat")
            if rep in REPEATS:
                a = n.get("anchor")
                if a and a > now:                    # a snooze came back: the next scheduled time is unchanged
                    nxt = a
                else:
                    nxt = next_due(a or n["due"], rep, now)
                n["anchor"] = nxt
                n["due"] = nxt
                n["reminded"] = False
            else:
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
        due = f"  \033[38;5;214mdue {due_text(n['due'])}\033[0m" if n.get("due") else ""
        box = "\033[38;5;242m[✓] \033[9m" if n.get("done") else "[ ] \033[1m"
        print(f"{box}{n.get('text', '')}\033[0m{due}")

def conf_json():
    c = read_conf()
    print(json.dumps({"NOTES_SUMMARY": c["NOTES_SUMMARY"] == "1", "NOTES_OCR": c["NOTES_OCR"] == "1", "NOTES_VLM": c["NOTES_VLM"] == "1", "NOTES_VLM_MODEL": c["NOTES_VLM_MODEL"],
                      "tesseract": bool(_which("tesseract")), "vlmModel": vlm_model(),
                      "NOTES_AI": c["NOTES_AI"] == "1", "NOTES_OVERVIEW": c["NOTES_OVERVIEW"] == "1", "NOTES_AI_MODE": c["NOTES_AI_MODE"],
                      "NOTES_NUDGE_HOURS": c["NOTES_NUDGE_HOURS"], "NOTES_NUDGE_MAX": c["NOTES_NUDGE_MAX"],
                      "NOTES_NUDGE_FROM": c["NOTES_NUDGE_FROM"], "NOTES_NUDGE_TO": c["NOTES_NUDGE_TO"], "NOTES_MODEL": c["NOTES_MODEL"],
                      "NOTES_STT_MODEL": c.get("NOTES_STT_MODEL", ""), "NOTES_STT_LANG": c.get("NOTES_STT_LANG", ""),
                      "aiEnabled": ai_switched_on(), "ollama": ollama_up() if (ai_enabled() and "1" in (c["NOTES_AI"], c["NOTES_OVERVIEW"])) else None, "model": model_name()}))

def set_conf(k, v):
    c = read_conf()
    if k in ("NOTES_AI", "NOTES_OVERVIEW", "NOTES_SUMMARY", "NOTES_OCR", "NOTES_VLM"):
        c[k] = "1" if str(v).lower() in ("1", "true", "on", "yes") else "0"
    elif k == "NOTES_AI_MODE" and v in ("ask", "auto"):
        c[k] = v
    elif k in ("NOTES_MODEL", "NOTES_STT_MODEL", "NOTES_VLM_MODEL") and re.fullmatch(r"[A-Za-z0-9._:/@+-]{0,100}", str(v)):
        c[k] = "" if str(v).lower() in ("default", "none", "-") else str(v)      # "default" = use default again
    elif k == "NOTES_STT_LANG" and re.fullmatch(r"[A-Za-z_-]{0,20}", str(v)):
        c[k] = "" if str(v).lower() in ("default", "auto", "none", "-") else str(v)
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
    elif cmd in UNLOCKED:
        run(cmd, args)          # a screen drag / a recording can take minutes: they take the lock only to write the note
    else:
        with locked():
            run(cmd, args)
            if cmd not in ("conf", "set"):
                sync_timer()        # the minute timer only runs while a task with a time is waiting

READ_ONLY = ("list", "ls", "json", "tasks", "conf", "rec-status")
NO_LOCK = ("sort", "think", "transcribe")
UNLOCKED = ("remind-act", "clip-image", "clip-img", "paste-image", "clip-paste", "clip-stage", "clip-drop", "shot-image", "screenshot", "record", "voice", "rec-start", "rec-stop", "rec-cancel", "rec-toggle", "ocr", "describe", "summary", "selftest", "search", "play")

def is_ref(a):
    return a.isdigit() or a.startswith("n_")

def run(cmd, args):
    # the new words only count as commands when they are used like commands, so "notes set the table" is still a note
    if (cmd in ("tasks", "conf", "remind-check") and len(args) > 1) \
            or (cmd in ("task", "sort", "think", "transcribe", "accept", "dismiss", "ocr", "describe", "summary") and not (len(args) == 2 and is_ref(args[1]))) \
            or (cmd in ("selftest", "rec-toggle") and len(args) > 1) \
            or (cmd == "due" and not (len(args) > 2 and is_ref(args[1]))) \
            or (cmd in ("snooze", "repeat") and not (len(args) > 2 and is_ref(args[1]))) \
            or (cmd == "remind-act" and not (len(args) in (2, 3) and is_ref(args[1]))) \
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
            print("usage: notes set NOTES_SUMMARY 0|1  |  NOTES_OCR 0|1  |  NOTES_VLM 0|1  |  NOTES_VLM_MODEL <name>|default  |  NOTES_AI 0|1  |  NOTES_OVERVIEW 0|1  |  NOTES_AI_MODE ask|auto  |  NOTES_MODEL <name>|default  |  NOTES_STT_MODEL <model>|default  |  NOTES_STT_LANG <lang>|default  |  NOTES_NUDGE_HOURS 1..12  |  NOTES_NUDGE_MAX 1..12  |  NOTES_NUDGE_FROM 0..23  |  NOTES_NUDGE_TO 1..24")
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
    elif cmd == "remind-act":
        remind_act(args[1], len(args) > 2 and args[2] == "late")
    elif cmd == "snooze":
        if len(args) > 2:
            snooze_note(args[1], " ".join(args[2:]))
        else:
            print("usage: notes snooze <number or id> <+10m | +1h | 18:00 ...>")
    elif cmd == "repeat":
        if len(args) > 2:
            set_repeat(args[1], args[2])
        else:
            print("usage: notes repeat <number or id> <daily | weekdays | weekly | monthly | none>")
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
    elif cmd == "clear" and len(args) == 1:       # the Clear completed button; it was documented but never connected, so it saved a note "clear"
        clear_done()
    elif cmd in ("clip-image", "clip-img", "paste-image"):
        clip_image(" ".join(args[1:]))
    elif cmd == "clip-paste":
        clip_paste(" ".join(args[1:]))
    elif cmd == "clip-stage":
        clip_stage()
    elif cmd == "clip-drop":
        clip_drop(args[1] if len(args) > 1 else "")
    elif cmd in ("shot-image", "screenshot"):
        shot_image(" ".join(args[1:]))
    elif cmd in ("image", "img"):
        if len(args) > 1:
            img_path = os.path.abspath(args[1])
            text = " ".join(args[2:]) if len(args) > 2 else ""
            if os.path.isfile(img_path):
                add_note(text or os.path.basename(img_path), image=img_path)
            else:
                print(f"[!] Image not found: {img_path}")
        else:
            print("usage: notes image <path> [text]")
    elif cmd in ("record", "voice"):
        record_audio(" ".join(args[1:]))
    elif cmd == "rec-toggle":
        rec_toggle()
    elif cmd == "summary":
        if len(args) > 1:
            summary_note(args[1])
        else:
            print("usage: notes summary <number or id>")
    elif cmd == "ocr":
        if len(args) > 1:
            ocr_note(args[1])
        else:
            print("usage: notes ocr <number or id>")
    elif cmd == "describe":
        if len(args) > 1:
            describe_note(args[1])
        else:
            print("usage: notes describe <number or id>")
    elif cmd == "search":
        search_cli(" ".join(args[1:]))
    elif cmd == "selftest":
        sys.exit(0 if selftest() else 1)
    elif cmd == "rec-start":
        rec_start(" ".join(args[1:]))
    elif cmd == "rec-stop":
        rec_stop()
    elif cmd == "rec-cancel":
        rec_cancel()
    elif cmd == "transcribe":
        if len(args) > 1:
            transcribe_note(args[1])
        else:
            print("usage: notes transcribe <number or id>")
    elif cmd == "rec-status":
        rec_status()
    elif cmd == "play":
        if len(args) > 1:
            play_audio(args[1])
        else:
            print("usage: notes play <idx_or_id>")
    elif cmd in ("add", "new"):
        raw_args = args[1:]
        img = None
        aud = None
        txt_parts = []
        i = 0
        while i < len(raw_args):
            if raw_args[i] in ("--image", "-i") and i + 1 < len(raw_args):
                img = raw_args[i+1]
                i += 2
            elif raw_args[i] in ("--audio", "-a") and i + 1 < len(raw_args):
                aud = raw_args[i+1]
                i += 2
            else:
                txt_parts.append(raw_args[i])
                i += 1
        add_note(" ".join(txt_parts), image=img, audio=aud)
    else:
        # Any string like "notes : hi i am srijan" or "notes buy milk"
        add_note(" ".join(args))

if __name__ == "__main__":
    main()
