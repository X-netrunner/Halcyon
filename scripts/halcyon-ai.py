#!/usr/bin/env python3
"""halcyon-ai.py: the small AI helpers of the desktop, one command each. They all ask the same local Ollama model as `ai` and the
notes (HALCYON_AI_MODEL, else MODEL= in ai-advisor.conf, else qwen2.5:3b-instruct), and they all stop when the master AI switch is
off (Settings > Performance > AI features). Nothing leaves this machine.

  halcyon-ai.py ask <question>                  one short answer (the launcher's  >ask ...)
  halcyon-ai.py do <phrase> [--dry] [--yes]     plain English to one Halcyon action: "move this window to workspace 3", "gaming mode on"
                                                (the launcher's  >do ...). Clear phrases are understood without the model. Actions that end
                                                something (close a window, log out, restart, shut down, sleep) only run with --yes.
  halcyon-ai.py clip summarise|rewrite|shorter [--id ID] [--tone clear|formal|casual|shorter] [--copy]
                                                the copied text (or clipboard history entry ID), summarised or rewritten
  halcyon-ai.py brief [--refresh] [--notify] [--once]
                                                the daily brief: tasks, notes and the Focus streak in a few lines (desktop widget "Daily
                                                brief"; --notify --once = the morning card, at most one a day). Works without the model too.
  halcyon-ai.py explain unit <name> | island | last  [--notify] [--if-new]
                                                read the log of a failed service, or the island's QML errors, and say what went wrong and
                                                the likely fix. --if-new: only errors not explained before (what the automatic checks use)
  halcyon-ai.py organise [--apply]              notes: tags, groups and duplicates. Without --apply it only proposes (and saves the
                                                proposal); --apply carries out the saved proposal (a backup of notes.json is kept first)
  halcyon-ai.py lyrics meaning [--title T --artist A --album B --duration S --url U]
                                                what the playing song is about

Every command takes --json: one line {"ok": bool, "text": str, "error": str, ...} for the island. Exit code 0 ok, 1 failed, 2 usage,
3 AI switched off / Ollama not running.
"""
import contextlib
import difflib
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
RICE = os.environ.get("HALCYON_DIR", os.path.join(HOME, ".config", "Halcyon"))
HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.environ.get("HALCYON_STATE") or os.path.join(HOME, ".local", "state", "island")
CACHE = os.path.join(HOME, ".cache", "island")
SETTINGS = os.path.join(STATE, "settings.json")
AI_OFF_FLAG = os.path.join(HOME, ".local", "state", "island", "ai-off")
ISLAND_LOG = os.path.join(CACHE, "quickshell-island.log")
ISLAND_DIR = os.path.join(RICE, "quickshell", "island")
DEFAULT_MODEL = "qwen2.5:3b-instruct"


class AiOff(Exception):
    """The AI is switched off, or Ollama is not there: exit 3, the message says which."""


class Fail(Exception):
    pass


# ------------------------------------------------------------------------------------------------ helpers
def load_module(name, filename):
    """Another Halcyon script as a module (the installed copy first, then the one next to this file). None when it cannot load."""
    for p in (os.path.join(RICE, "scripts", filename), os.path.join(HERE, filename)):
        if os.path.isfile(p):
            try:
                spec = importlib.util.spec_from_file_location(name, p)
                m = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(m)
                return m
            except Exception:
                continue
    return None


def read_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, path)


def opt(key, default=None):
    """One of the island's settings (settings.json > opt)."""
    o = read_json(SETTINGS, {})
    o = o.get("opt", {}) if isinstance(o, dict) else {}
    return o.get(key, default) if isinstance(o, dict) else default


def sh(argv, timeout=8, data=None):
    """Run argv, return (code, stdout text). Never raises."""
    try:
        r = subprocess.run(argv, input=data, capture_output=True, timeout=timeout)
        return r.returncode, r.stdout.decode("utf-8", "replace")
    except FileNotFoundError:
        return 127, ""
    except (subprocess.TimeoutExpired, OSError):
        return 124, ""


def have(cmd):
    return shutil.which(cmd) is not None


def notify(title, body, icon="dialog-information"):
    if have("notify-send"):
        with contextlib.suppress(Exception):
            subprocess.run(["notify-send", "-a", "Halcyon", "-i", icon, title, body],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)


def qs(*call):
    """quickshell ipc call island <fn> [args]: True when the island answered."""
    code, _ = sh(["quickshell", "ipc", "-p", ISLAND_DIR, "call", *call], timeout=4)
    return code == 0


def plain(text):
    """The model's answer as plain text: no <think>, no markdown emphasis or headings, no 'Sure! Here is ...' opener."""
    t = re.sub(r"<think>.*?</think>", "", text or "", flags=re.S)
    t = re.sub(r"^\s*#+\s*", "", t, flags=re.M)
    t = re.sub(r"\*\*(.+?)\*\*|__(.+?)__", lambda m: m.group(1) or m.group(2), t)
    t = re.sub(r"^\s*[*•]\s+", "- ", t, flags=re.M)
    t = re.sub(r"^(sure|certainly|of course|here(?:'s| is| are))[^\n]{0,60}:\s*\n", "", t.strip(), flags=re.I)
    return t.strip()


# ------------------------------------------------------------------------------------------------ the model
def ai_enabled():
    return not os.path.exists(AI_OFF_FLAG)


def ollama_host():
    h = os.environ.get("OLLAMA_HOST", "127.0.0.1:11434")
    return h if h.startswith("http") else "http://" + h


def model_name():
    if os.environ.get("HALCYON_AI_MODEL"):
        return os.environ["HALCYON_AI_MODEL"].strip()
    try:
        with open(os.path.join(RICE, "ai-advisor.conf"), "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MODEL="):
                    return line.split("=", 1)[1].strip().strip("\"'") or DEFAULT_MODEL
    except OSError:
        pass
    return DEFAULT_MODEL


def need_ai():
    if not ai_enabled():
        raise AiOff("AI features are switched off (Settings > Performance > AI features).")


def generate(prompt, system="", fmt=None, num_predict=300, temperature=0.2, timeout=90):
    """One answer from the local model. Raises AiOff when it is switched off / not running, Fail on anything else."""
    need_ai()
    body = {"model": model_name(), "prompt": prompt, "stream": False, "think": False,
            "keep_alive": "5m", "options": {"temperature": temperature, "num_predict": num_predict}}
    if system:
        body["system"] = system
    if fmt:
        body["format"] = fmt
    req = urllib.request.Request(ollama_host() + "/api/generate", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            out = json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        detail = ""
        with contextlib.suppress(Exception):
            detail = json.loads(e.read().decode("utf-8", "replace")).get("error", "")
        if "not found" in detail:
            raise Fail(f"The model {model_name()} is not installed. Run: ollama pull {model_name()}")
        raise Fail(f"Ollama answered with an error: {detail or e}")
    except (urllib.error.URLError, ConnectionError):
        raise AiOff("Ollama is not running. Start it with: systemctl start ollama")
    except TimeoutError:
        raise Fail("The model took too long to answer.")
    except ValueError:
        raise Fail("Ollama's answer could not be read.")
    return re.sub(r"<think>.*?</think>", "", out.get("response", ""), flags=re.S).strip()


def generate_json(prompt, system="", num_predict=400):
    raw = generate(prompt, system=system, fmt="json", num_predict=num_predict, temperature=0)
    m = re.search(r"\{.*\}", raw, re.S)
    try:
        return json.loads(m.group(0) if m else raw)
    except ValueError:
        raise Fail("The model did not answer in the expected form. Try again, or pick a bigger model.")


# ------------------------------------------------------------------------------------------------ ask
def cmd_ask(args):
    q = " ".join(a for a in args if not a.startswith("--")).strip()
    if not q:
        raise Fail("Ask something, e.g.  ask how many ml in a cup")
    ans = generate(q, system=(
        "You answer quick questions typed into a desktop launcher. Answer in one or two short sentences of plain text: no markdown, "
        "no lists, no preamble. If it is a calculation or a fact, give the result first. If you are not sure, say so briefly."),
        num_predict=160, temperature=0.3, timeout=60)
    ans = " ".join(plain(ans).split())
    if not ans:
        raise Fail("The model gave no answer.")
    return {"text": ans}


# ------------------------------------------------------------------------------------------------ do: plain English -> one action
# id: (what it does, how the value is given, needs --yes)
#   value kinds: none | state (on / off / toggle) | ws (1..20) | pct (0..100, or up / down) | choice:<a|b|c>
DO_ACTIONS = {
    "workspace":    ("go to workspace N", "ws", False),
    "move-window":  ("move the focused window to workspace N", "ws", False),
    "float":        ("float / tile the focused window (toggle)", "none", False),
    "fullscreen":   ("fullscreen the focused window (toggle)", "none", False),
    "close-window": ("close the focused window", "none", True),
    "gaming":       ("Gaming mode", "state", False),
    "caffeine":     ("keep the screen awake (Caffeine)", "state", False),
    "dnd":          ("Do not disturb", "state", False),
    "theme":        ("light or dark theme", "choice:light|dark|toggle", False),
    "nightlight":   ("night light, warmer screen (toggle)", "none", False),
    "volume":       ("speaker volume in percent, or up / down / mute", "pct", False),
    "brightness":   ("screen brightness in percent, or up / down", "pct", False),
    "wallpaper":    ("the next wallpaper", "none", False),
    "power-mode":   ("power mode", "choice:saver|balanced|performance|auto", False),
    "focus":        ("start / stop a Focus session (toggle)", "none", False),
    "lock":         ("lock the screen", "none", False),
    "screenshot":   ("the screenshot panel", "none", False),
    "record":       ("start / stop the screen recorder", "none", False),
    "notes":        ("a new note", "none", False),
    "clipboard":    ("the clipboard history", "none", False),
    "lyrics":       ("the lyrics of the playing song", "none", False),
    "calendar":     ("the calendar", "none", False),
    "settings":     ("Settings", "none", False),
    "notifications": ("the notification centre", "none", False),
    "wifi":         ("Wi-Fi on / off (toggle)", "none", False),
    "bluetooth":    ("Bluetooth on / off (toggle)", "none", False),
    "bar":          ("the top bar on / off (toggle)", "none", False),
    "desktop-builder": ("the desktop builder", "none", False),
    "widget-builder":  ("the widget builder", "none", False),
    "sleep":        ("suspend / sleep", "none", True),
    "logout":       ("log out", "none", True),
    "restart":      ("restart the computer", "none", True),
    "shutdown":     ("shut the computer down", "none", True),
}
NUM_WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
             "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5}


def _num(s):
    s = (s or "").strip().lower()
    if s.isdigit():
        return int(s)
    return NUM_WORDS.get(s)


def _state(p):
    if re.search(r"\b(off|disable|stop|deactivate|end|quit|exit|leave)\b", p):
        return "off"
    if re.search(r"\b(on|enable|start|activate|enter|turn on|switch on)\b", p):
        return "on"
    return "toggle"


NUM = r"(\d+|one|two|three|four|five|six|seven|eight|nine|ten|first|second|third|fourth|fifth)"
RULES = [
    (rf"\b(move|send|put|throw|shift)\b.*\b(window|app|this|it)\b.*\b(workspace|ws|desktop|space)\s*{NUM}\b", "move-window", lambda m: _num(m.group(4))),
    (rf"\b(move|send|put)\b.*\bto\s+(workspace|ws|desktop)\s*{NUM}\b", "move-window", lambda m: _num(m.group(3))),
    (rf"\b(move|send|put|throw|shift)\b.*\b{NUM}\s+(workspace|ws|desktop|space)\b", "move-window", lambda m: _num(m.group(2))),
    (rf"\b(go|switch|jump|take me|show)\b.*\b{NUM}\s+(workspace|ws|desktop|space)\b", "workspace", lambda m: _num(m.group(2))),
    (rf"\b(go|switch|jump|take me|show)\b.*\b(workspace|ws|desktop)\s*{NUM}\b", "workspace", lambda m: _num(m.group(3))),
    (rf"^\s*(workspace|ws)\s*{NUM}\s*$", "workspace", lambda m: _num(m.group(2))),
    (r"\bgam(e|ing)\b", "gaming", None),
    (r"\b(caffeine|stay awake|keep (the )?(screen )?awake)\b", "caffeine", None),
    (r"\b(do not disturb|don'?t disturb|dnd)\b", "dnd", None),
    (r"\bnight ?light\b|\bblue light\b", "nightlight", None),
    (r"\b(dark|light)\s+(theme|mode)\b|\btheme\b", "theme", None),
    (r"\b(volume|sound|audio)\b|\b(mute|unmute)\b", "volume", None),
    (r"\bbrightness\b|\b(dim|brighten)\b.*\bscreen\b", "brightness", None),
    (r"\b(next|new|change|another|random)\b.*\bwallpaper\b", "wallpaper", None),
    (r"\b(battery saver|power saver|saver mode|balanced|performance mode|power mode)\b", "power-mode", None),
    (r"\bfull ?screen\b", "fullscreen", None),
    (r"\b(float|floating|tile|tiling)\b", "float", None),
    (r"\bclose\b.*\b(window|this|app)\b", "close-window", None),
    (r"\block\b.*\bscreen\b|^\s*lock\s*$", "lock", None),
    (r"\bscreenshot\b|\bscreen ?shot\b", "screenshot", None),
    (r"\brecord(ing)?\b.*\bscreen\b|\bscreen ?record", "record", None),
    (r"\bfocus\b", "focus", None),
    (r"\bwi-?fi\b", "wifi", None),
    (r"\bbluetooth\b", "bluetooth", None),
    (r"\b(log ?out|sign out)\b", "logout", None),
    (r"\b(restart|reboot)\b", "restart", None),
    (r"\b(shut ?down|power off|poweroff)\b", "shutdown", None),
    (r"\b(suspend|sleep)\b", "sleep", None),
]


def _pct(p):
    """'50%' / 'to 40' -> 40, 'up' / 'louder' -> 'up', 'down' / 'quieter' -> 'down', 'mute' -> 'mute'."""
    if re.search(r"\bunmute\b", p):
        return "unmute"
    if re.search(r"\bmute\b|\bsilence\b", p):
        return "mute"
    m = re.search(r"(\d{1,3})\s*(%|percent)?", p)
    if m:
        return max(0, min(100, int(m.group(1))))
    if re.search(r"\b(up|louder|raise|increase|higher|more|brighter)\b", p):
        return "up"
    if re.search(r"\b(down|quieter|lower|decrease|less|dimmer|dim)\b", p):
        return "down"
    if re.search(r"\b(max|maximum|full)\b", p):
        return 100
    return None


def value_for(action, p, given=None):
    kind = DO_ACTIONS[action][1]
    if kind == "ws":
        v = given if isinstance(given, int) else _num(str(given)) if given is not None else None
        return v if isinstance(v, int) and 1 <= v <= 20 else None
    if kind == "state":
        g = str(given).lower() if given is not None else ""
        return g if g in ("on", "off", "toggle") else _state(p)
    if kind == "pct":
        if isinstance(given, (int, float)) and not isinstance(given, bool):
            return max(0, min(100, int(given)))
        return _pct(str(given)) if given is not None and _pct(str(given)) is not None else _pct(p)
    if kind.startswith("choice:"):
        opts = kind[7:].split("|")
        g = str(given).lower() if given is not None else ""
        if g in opts:
            return g
        if action == "theme":
            return "dark" if re.search(r"\bdark\b", p) else ("light" if re.search(r"\blight\b", p) else "toggle")
        if action == "power-mode":
            for word, v in (("saver", "saver"), ("battery", "saver"), ("balanced", "balanced"), ("performance", "performance"), ("auto", "auto")):
                if word in p:
                    return v
            return None
        return None
    return None


def plan_by_rules(phrase):
    p = phrase.lower().strip()
    for pat, action, getv in RULES:
        m = re.search(pat, p)
        if not m:
            continue
        v = getv(m) if getv else value_for(action, p)
        if DO_ACTIONS[action][1] != "none" and v is None:
            continue
        return {"action": action, "value": v}
    return None


def plan_by_model(phrase):
    lines = []
    for k, (what, kind, _) in DO_ACTIONS.items():
        val = {"none": "", "state": ' value: "on", "off" or "toggle"', "ws": " value: the workspace number",
               "pct": ' value: a number 0-100, or "up", "down", "mute"'}.get(kind, "")
        if kind.startswith("choice:"):
            val = " value: one of " + ", ".join(f'"{c}"' for c in kind[7:].split("|"))
        lines.append(f"- {k}: {what}.{val}")
    out = generate_json(
        "Map the user's request to ONE action from this list, or to none if nothing fits. A \"desktop\" or \"space\" with a number "
        "means a workspace.\n" + "\n".join(lines) +
        '\nAnswer with JSON only: {"action": "<id>" or null, "value": <value or null>}.\n'
        'Example: "send this to space 4" -> {"action": "move-window", "value": 4}\n'
        'Example: "make it quieter" -> {"action": "volume", "value": "down"}\n'
        'Example: "what is the weather" -> {"action": null, "value": null}\n'
        f"Request: {phrase}\n", num_predict=60)
    a = out.get("action") if isinstance(out, dict) else None
    if a not in DO_ACTIONS:
        return None
    v = value_for(a, phrase.lower(), out.get("value"))
    if DO_ACTIONS[a][1] != "none" and v is None:
        return None
    return {"action": a, "value": v}


def describe(plan):
    a, v = plan["action"], plan["value"]
    names = {"workspace": f"Go to workspace {v}", "move-window": f"Move the window to workspace {v}",
             "volume": f"Volume {v}" + ("%" if isinstance(v, int) else ""), "brightness": f"Brightness {v}" + ("%" if isinstance(v, int) else ""),
             "power-mode": f"Power mode: {v}", "theme": "Theme: " + str(v)}
    if a in names:
        return names[a]
    what = DO_ACTIONS[a][0]
    what = what[0].upper() + what[1:]
    return what + (f": {v}" if DO_ACTIONS[a][1] == "state" and v != "toggle" else "")


def run_plan(plan):
    a, v = plan["action"], plan["value"]
    hy = lambda d: sh(["hyprctl", "dispatch", d], timeout=4)[0] == 0
    scr = lambda name, *x: sh(["bash", os.path.join(RICE, "scripts", name), *x], timeout=10)[0] == 0
    if a == "workspace":
        return hy(f"hl.dsp.focus({{ workspace = {int(v)} }})")
    if a == "move-window":
        return hy(f"hl.dsp.window.move({{ workspace = {int(v)} }})")
    if a == "float":
        return hy("hl.dsp.window.float()")
    if a == "fullscreen":
        return hy("hl.dsp.window.fullscreen()")
    if a == "close-window":
        return hy("hl.dsp.window.close()")
    if a in ("gaming", "caffeine", "dnd"):
        if v == "toggle":
            return qs("island", a)
        return qs("island", a + "set", "true" if v == "on" else "false")     # the island leaves it alone when it already is that way
    if a == "theme":
        cur = ""
        with contextlib.suppress(OSError):
            cur = open(os.path.join(STATE, "theme")).read().strip()
        if v in ("light", "dark") and cur == v:
            return True
        return qs("island", "theme")
    if a == "nightlight":
        return scr("toggle_nightlight.sh")
    if a == "volume":
        if not have("wpctl"):
            raise Fail("Volume needs wpctl (wireplumber).")
        sink = "@DEFAULT_AUDIO_SINK@"
        if v == "mute":
            return sh(["wpctl", "set-mute", sink, "1"])[0] == 0
        if v == "unmute":
            return sh(["wpctl", "set-mute", sink, "0"])[0] == 0
        arg = "5%+" if v == "up" else ("5%-" if v == "down" else f"{int(v)}%")
        sh(["wpctl", "set-mute", sink, "0"])
        return sh(["wpctl", "set-volume", "-l", "1.0", sink, arg])[0] == 0
    if a == "brightness":
        if not have("brightnessctl"):
            raise Fail("Brightness needs brightnessctl.")
        arg = "10%+" if v == "up" else ("10%-" if v == "down" else f"{max(1, int(v))}%")
        return sh(["brightnessctl", "-q", "set", arg])[0] == 0
    if a == "wallpaper":
        return qs("wallpaper", "next")
    if a == "power-mode":
        return qs("island", "command", "profile-" + {"saver": "power-saver"}.get(v, v))
    simple = {"focus": ("focus",), "lock": ("lock",), "screenshot": ("screenshot",), "record": ("record",), "notes": ("notes",),
              "clipboard": ("clipboard",), "lyrics": ("lyrics",), "calendar": ("calendar",), "settings": ("settings",),
              "notifications": ("notifcenter",), "bar": ("bar",), "desktop-builder": ("desktopbuilder",), "widget-builder": ("widgetbuilder",),
              "wifi": ("command", "wifi"), "bluetooth": ("command", "bluetooth"), "sleep": ("command", "suspend"),
              "logout": ("command", "logout"), "restart": ("goodbye", "reboot"), "shutdown": ("goodbye", "shutdown")}
    if a in simple:
        return qs("island", *simple[a])
    raise Fail(f"Unknown action {a}")


def cmd_do(args):
    phrase = " ".join(a for a in args if not a.startswith("--")).strip()
    dry, yes = "--dry" in args, "--yes" in args
    if not phrase:
        raise Fail("Say what to do, e.g.  do move this window to workspace 3")
    plan = plan_by_rules(phrase)
    how = "rules"
    if plan is None:
        try:
            plan = plan_by_model(phrase)
        except AiOff as e:
            raise Fail("I did not understand that, and the model that could is not available: " + str(e))
        how = "model"
    if plan is None:
        raise Fail("I could not match that to a Halcyon action. Try e.g. \"move this window to workspace 3\" or \"gaming mode on\".")
    risky = DO_ACTIONS[plan["action"]][2]
    out = {"action": plan["action"], "value": plan["value"], "say": describe(plan), "how": how, "confirm": risky, "done": False}
    if dry or (risky and not yes):
        out["text"] = out["say"] + (" (press Enter again to do it)" if risky and not dry else "")
        return out
    if not run_plan(plan):
        raise Fail(out["say"] + ": that did not work (is the island running?)")
    out["done"] = True
    out["text"] = "Done: " + out["say"]
    return out


# ------------------------------------------------------------------------------------------------ clipboard actions
MAX_CLIP = 12000


def clip_text(cid):
    """The text of clipboard history entry cid ("p..." = a pin), or what is on the clipboard now."""
    if cid:
        if cid.startswith("p"):
            mod = load_module("halcyon_clip", "halcyon-clip.py")
            if mod:
                for t in mod.read_pins():
                    if mod.pin_id(t) == cid:
                        return t
            raise Fail("That pinned entry is gone.")
        if not cid.isdigit():
            raise Fail("The entry id must be a number.")
        try:
            r = subprocess.run(["cliphist", "decode"], input=(cid + "\t").encode(), capture_output=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            raise Fail("The clipboard history needs cliphist.")
        if r.returncode != 0 or not r.stdout:
            raise Fail("That entry is gone from the history.")
        data = r.stdout
    else:
        try:
            r = subprocess.run(["wl-paste", "-n", "-t", "text"], capture_output=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            raise Fail("Reading the clipboard needs wl-clipboard.")
        if r.returncode != 0 or not r.stdout:
            raise Fail("There is no text on the clipboard.")
        data = r.stdout
    if b"\x00" in data[:4096]:
        raise Fail("That is a picture, not text. (Screenshot panel > Text reads the words in a picture onto the clipboard.)")
    t = data.decode("utf-8", "replace").strip()
    if not t:
        raise Fail("There is no text to work on.")
    return t


def copy_out(text):
    with contextlib.suppress(OSError, subprocess.SubprocessError):
        p = subprocess.Popen(["wl-copy"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        p.stdin.write(text.encode("utf-8"))
        p.stdin.close()
        p.wait(timeout=5)
        return True
    return False


def argval(args, name, default=""):
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return args[i + 1]
    return default


def cmd_clip(args):
    what = (args[0] if args else "").lower()
    what = {"summarize": "summarise", "summary": "summarise", "tl;dr": "summarise", "tldr": "summarise",
            "rewrite": "rewrite", "fix": "rewrite", "summarise": "summarise", "shorter": "shorter"}.get(what, "")
    if not what:
        raise Fail("clip summarise | rewrite | shorter")
    if what == "shorter":
        what, args = "rewrite", list(args) + ["--tone", "shorter"]
    text = clip_text(argval(args, "--id"))
    cut = len(text) > MAX_CLIP
    text = text[:MAX_CLIP]
    if what == "summarise":
        n = len(text.split())
        system = ("Summarise the text the user gives you. Plain text, no markdown headings. "
                  + ("Answer in one or two sentences." if n < 150 else "Answer with at most five short lines starting with '- '.")
                  + " Keep names, numbers and dates exactly as written. Do not add anything that is not in the text.")
        out = generate(text, system=system, num_predict=260)
    else:
        tone = (argval(args, "--tone") or "clear").lower()
        how = {"clear": "clearer and easier to read, with grammar and spelling fixed", "formal": "more formal and polite",
               "casual": "more relaxed and friendly", "shorter": "shorter, keeping every important point"}.get(tone, "clearer")
        system = (f"Rewrite the text the user gives you to be {how}. Keep its language, meaning, names and numbers. "
                  "Answer with the rewritten text only, no comments.")
        out = generate(text, system=system, num_predict=min(2000, 80 + len(text) // 2), temperature=0.3)
    out = plain(out) if what == "summarise" else out.strip().strip('"')
    if not out:
        raise Fail("The model gave no answer.")
    res = {"text": out, "kind": what, "cut": cut}
    if "--copy" in args:
        res["copied"] = copy_out(out)
    return res


# ------------------------------------------------------------------------------------------------ daily brief
BRIEF = os.path.join(CACHE, "brief.json")
BRIEF_SEEN = os.path.join(STATE, "brief-card-day")


def focus_goal():
    """The Focus streak goal (minutes a day): the Focus widget's own, else 25 (what the widgets use by default)."""
    for key in ("deskWidgets", "lockDeskWidgets"):
        lay = opt(key) or {}
        for it in (lay.get("items") or []) if isinstance(lay, dict) else []:
            if isinstance(it, dict) and it.get("type") in ("focus", "focusgraph"):
                g = (it.get("opts") or {}).get("goal")
                if isinstance(g, (int, float)) and g > 0:
                    return int(g)
    return 25


def focus_facts():
    import datetime
    days = read_json(os.path.join(STATE, "focus-days.json"), {})
    days = days if isinstance(days, dict) else {}
    goal = focus_goal()
    today = datetime.date.today()
    m = lambda d: int(days.get(d.isoformat(), 0) or 0)
    d = today if m(today) >= goal else today - datetime.timedelta(days=1)
    streak = 0
    while m(d) >= goal and streak < 4000:
        streak += 1
        d -= datetime.timedelta(days=1)
    best, run, prev = 0, 0, None
    for k in sorted(days):
        try:
            dt = datetime.date.fromisoformat(k)
        except ValueError:
            continue
        if int(days[k] or 0) < goal:
            run = 0
        else:
            run = run + 1 if prev is not None and prev == dt - datetime.timedelta(days=1) and run else 1
        prev = dt
        best = max(best, run)
    yday = m(today - datetime.timedelta(days=1))
    return {"streak": streak, "best": max(best, streak), "today": m(today), "yesterday": yday, "goal": goal, "tracked": bool(days)}


def note_facts():
    notes = read_json(os.path.join(STATE, "notes.json"), [])
    notes = [n for n in notes if isinstance(n, dict)] if isinstance(notes, list) else []
    now = time.time()
    eod = time.mktime(time.localtime(now)[:3] + (23, 59, 59, 0, 0, -1))
    short = lambda n: " ".join(str(n.get("text") or n.get("why") or "").split())[:90] or "(a picture or voice note)"
    open_tasks = [n for n in notes if n.get("task") and not n.get("done")]
    due = lambda n: float(n.get("due") or 0)
    overdue = [n for n in open_tasks if due(n) and due(n) < now]
    today = [n for n in open_tasks if due(n) and now <= due(n) <= eod]
    later = [n for n in open_tasks if n.get("later") and not due(n)]
    undated = [n for n in open_tasks if not due(n) and not n.get("later")]
    recent = [n for n in notes if not n.get("task") and float(n.get("created") or 0) > now - 86400]
    pinned = [n for n in notes if n.get("pinned") and not n.get("done")]
    hm = lambda n: time.strftime("%H:%M", time.localtime(due(n)))
    return {
        "overdue": [short(n) for n in overdue][:5],
        "today": [f"{hm(n)} {short(n)}" for n in sorted(today, key=due)][:6],
        "later": [short(n) for n in later][:4],
        "open": len(open_tasks),
        "undated": [short(n) for n in undated][:4],
        "pinned": [short(n) for n in pinned][:3],
        "recent_notes": len(recent),
    }


def cal_facts():
    """Today's calendar events (the gcal cache the Calendar uses), and the next one in the coming week when today is empty."""
    cache = read_json(os.path.join(STATE, "calendar", "events.json"), {})
    evs = [e for e in (cache.get("events") or []) if isinstance(e, dict)] if isinstance(cache, dict) else []
    now = time.time()
    sod = time.mktime(time.localtime(now)[:3] + (0, 0, 0, 0, 0, -1))
    eod = sod + 86400
    title = lambda e: " ".join(str(e.get("title") or "").split())[:70] or "(no title)"
    hm = lambda e: "all day" if e.get("allDay") else time.strftime("%H:%M", time.localtime(float(e.get("start") or 0)))
    start = lambda e: float(e.get("start") or 0)
    today = sorted([e for e in evs if sod <= start(e) < eod and (e.get("allDay") or float(e.get("end") or start(e)) >= now)], key=start)
    nxt = sorted([e for e in evs if eod <= start(e) < eod + 6 * 86400], key=start)[:1]
    return {"today": [f"{hm(e)} {title(e)}" for e in today][:4],
            "next": [f"{time.strftime('%A', time.localtime(start(e)))} {hm(e)} {title(e)}" for e in nxt]}


MILESTONES = (3, 7, 14, 30, 60, 100, 200, 365)


def brief_plain(f, nf, cf):
    parts = []
    if cf["today"]:
        parts.append("On the calendar today: " + "; ".join(cf["today"][:3]) + ".")
    elif cf["next"]:
        parts.append("Nothing on the calendar today; next up: " + cf["next"][0] + ".")
    if nf["overdue"]:
        parts.append(f"{len(nf['overdue'])} overdue: " + "; ".join(nf["overdue"][:2]) + ".")
    if nf["today"]:
        parts.append("Tasks today: " + "; ".join(nf["today"][:3]) + ".")
    elif nf["undated"] or nf["later"]:
        names = (nf["later"] + nf["undated"])[:2]
        parts.append(f"{nf['open']} open task{'s' if nf['open'] != 1 else ''}, none with a time today: " + "; ".join(names) + ".")
    elif not nf["overdue"]:
        parts.append("No tasks waiting.")
    if nf["pinned"]:
        parts.append("Pinned: " + nf["pinned"][0] + ".")
    if f["tracked"]:
        left = max(0, f["goal"] - f["today"])
        if f["streak"]:
            nxt = next((m for m in MILESTONES if m > f["streak"]), None)
            s = f"Focus streak: {f['streak']} day{'s' if f['streak'] != 1 else ''} (best {f['best']})"
            s += f", {left} more min today keeps it" if left else ", today's goal is done"
            if nxt and nxt - f["streak"] <= 3:
                s += f"; {nxt - f['streak']} day{'s' if nxt - f['streak'] != 1 else ''} to the {nxt}-day badge"
            parts.append(s + ".")
        else:
            parts.append(f"No focus streak right now: {f['goal']} min of Focus today starts one" +
                         (f" (yesterday: {f['yesterday']} min)." if f["yesterday"] else "."))
    return " ".join(parts)


def greeting():
    h = time.localtime().tm_hour
    return "Good morning" if 4 <= h < 12 else ("Good afternoon" if h < 18 else "Good evening")


def grounded(out, facts_text):
    """Small models like to invent a task "at 17:00" or a streak that is not there: every number in the answer must be in the facts,
    and it may not talk about overdue things when nothing is overdue."""
    have = set(re.findall(r"\d+", facts_text))
    if any(n not in have for n in re.findall(r"\d+", out)):
        return False
    return "overdue" in facts_text.lower() or "overdue" not in out.lower()


def make_brief():
    f, nf, cf = focus_facts(), note_facts(), cal_facts()
    text, ai = brief_plain(f, nf, cf), False
    if ai_enabled():
        # the facts stay exactly as written (a small model reworded "next up: Thursday" into "today"); the model only adds one short,
        # warm opening line on top, and that line may not hold a number, a day, a time or anything overdue the facts do not mention
        system = ("You write ONE short, warm opening line (at most 12 words) for someone's daily brief. It sets the mood from the "
                  "facts; the facts themselves are shown right after it, so never repeat them. Never use digits, days, dates or times.\n"
                  "Examples of good lines:\n"
                  "A calm day ahead, with room for whatever you choose.\n"
                  "Your streak is alive, so keep the momentum going.\n"
                  "A full plate today, so take it one thing at a time.\n"
                  "A couple of things slipped, but they are quick to catch up on.\n"
                  "Answer with the line only.")
        for _ in range(2):
            with contextlib.suppress(AiOff, Fail):
                out = generate("Facts:\n" + text + "\n\nThe opening line:", system=system, num_predict=40, temperature=0.7, timeout=60)
                line = " ".join(plain(out).split()).strip('"')
                bad = re.search(r"\d|monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|yesterday|morning|evening|"
                                r"afternoon|hello|\bhi\b|good (day|night)|badge|overdue", line, re.I)
                if 8 < len(line) < 110 and not bad and line.count(".") <= 1 and grounded(line, text):
                    text, ai = line.rstrip(".!") + ". " + text, True
                    break
    d = {"day": time.strftime("%Y-%m-%d"), "at": int(time.time()), "greeting": greeting(), "text": text, "ai": ai,
         "focus": f, "tasks": nf, "calendar": cf}
    write_json(BRIEF, d)
    return d


def cmd_brief(args):
    d = read_json(BRIEF, {})
    notes_mtime = 0
    with contextlib.suppress(OSError):
        notes_mtime = os.path.getmtime(os.path.join(STATE, "notes.json"))
    fresh = (isinstance(d, dict) and d.get("day") == time.strftime("%Y-%m-%d") and time.time() - d.get("at", 0) < 3 * 3600
             and d.get("at", 0) >= notes_mtime)
    if "--refresh" in args or not fresh:
        d = make_brief()
    else:
        d["greeting"] = greeting()
    if "--notify" in args:
        today = time.strftime("%Y-%m-%d")
        seen = ""
        with contextlib.suppress(OSError):
            seen = open(BRIEF_SEEN).read().strip()
        if "--once" not in args or seen != today:
            notify(d["greeting"], d["text"], "view-calendar-day")
            os.makedirs(STATE, exist_ok=True)
            with open(BRIEF_SEEN, "w") as fh:
                fh.write(today)
    d["text"] = d.get("text", "")
    return d


# ------------------------------------------------------------------------------------------------ explain errors
SEEN = os.path.join(CACHE, "explain-seen.json")
LAST = os.path.join(CACHE, "explain-last.txt")
QML_ERR = re.compile(r"(TypeError|ReferenceError|SyntaxError|is not a type|is not defined|Cannot read property|Cannot assign|"
                     r"Unable to assign|Type error|failed to load|Failed to load|unknown signal|Unexpected token|"
                     r"Binding loop|Cannot call method|\bERROR\b|\bcaught\b.*\bexception\b)", re.I)
QML_LOC = re.compile(r"((?:file://)?/[^\s:]+\.(?:qml|js)):(\d+)|@([\w./-]+\.(?:qml|js))\[(\d+)")   # file:///x/A.qml:12  or  @A.qml[12:-1]
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def err_key(line):
    """The same error from another object or run: no time, no colours, no addresses or type numbers."""
    t = ANSI.sub("", line)
    t = re.sub(r"0x[0-9a-f]+|_QMLTYPE_\d+|\b\d{2}:\d{2}:\d{2}\S*", "", t)
    return " ".join(t.split())[:300]


def seen_before(key):
    s = read_json(SEEN, [])
    s = s if isinstance(s, list) else []
    if key in s:
        return True
    write_json(SEEN, (s + [key])[-100:])
    return False


def unit_info(unit):
    if not re.match(r"^[A-Za-z0-9:_.@\\-]+$", unit):
        raise Fail(f"Not a unit name: {unit}")
    for scope in (["--user"], []):
        code, out = sh(["systemctl", *scope, "show", unit, "-p", "LoadState,ActiveState,Result,ExecMainStatus,NRestarts"])
        props = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
        if props.get("LoadState") == "loaded":
            _, log = sh(["journalctl", *scope, "-u", unit, "-n", "60", "--no-pager", "-o", "short-iso"], timeout=10)
            return ("user" if scope else "system"), props, log
    raise Fail(f"There is no unit called {unit}.")


def explain_unit(unit):
    scope, props, log = unit_info(unit)
    log = "\n".join(log.strip().splitlines()[-60:])
    sig = hashlib.sha1((unit + "\n" + "\n".join(l.split(" ", 1)[-1] for l in log.splitlines()[-8:])).encode()).hexdigest()
    fix = "systemctl " + ("--user " if scope == "user" else "") + "restart " + unit
    prompt = (f"A {scope} systemd service on Arch Linux (Hyprland desktop \"Halcyon\") failed.\nUnit: {unit}\n"
              f"State: {json.dumps(props)}\nLast log lines:\n{log}\n")
    return unit, prompt, sig, fix


def island_errors():
    try:
        with open(ISLAND_LOG, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()[-4000:]
    except OSError:
        raise Fail("There is no island log yet (" + ISLAND_LOG + ").")
    # only the code that runs now: the log keeps every run, so start after the last launch or reload of the island
    for i in range(len(lines) - 1, -1, -1):
        if re.search(r"INFO: (Launching config|Reloading configuration)", ANSI.sub("", lines[i])):
            lines = lines[i:]
            break
    errs, seen = [], set()
    for l in lines:
        l = ANSI.sub("", l).strip()
        if QML_ERR.search(l) and not re.search(r"\b(debug|info)\b:|quickshell\.dbus|StatusNotifierItem", l, re.I):
            k = err_key(l)
            if k not in seen:
                seen.add(k)
                errs.append(l[-400:])
    return errs[-12:]


def main_error(errs):
    """The one error to explain: the deepest "caused by" of a load failure (its root), else the newest one that names a place,
    else the newest of all."""
    deep = [e for e in errs if "caused by" in e and QML_LOC.search(e)]
    located = [e for e in errs if QML_LOC.search(e)]
    return (deep or located or errs)[-1]


def one_context(e):
    m = QML_LOC.search(e)
    if not m:
        return ""
    if m.group(1):
        path, line = m.group(1).replace("file://", ""), int(m.group(2))
    else:
        path, line = os.path.join(ISLAND_DIR, m.group(3)), int(m.group(4))
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            src = f.readlines()
    except OSError:
        return ""
    a, b = max(0, line - 6), min(len(src), line + 5)
    return f"{os.path.basename(path)} lines {a + 1}-{b}:\n" + "".join(f"{i + 1:5} {src[i]}" for i in range(a, b))


def explain_island():
    errs = island_errors()
    if not errs:
        return None
    main = main_error(errs)
    sig = hashlib.sha1(err_key(main).encode()).hexdigest()
    ctx = one_context(main)
    others = [e for e in errs if e != main][-4:]
    prompt = ("The Quickshell (Qt 6 QML) desktop shell \"Halcyon island\" logged this error:\n" + main +
              ("\n\nThe code there:\n" + ctx if ctx else "") +
              ("\n\nOther recent lines from the same log (only for background):\n" + "\n".join(others) if others else "") +
              "\n\nExplain the first error only. Only name files and lines that appear above.\n")
    return "the island", prompt, sig, "halcyon reload"


def failed_units():
    out = []
    for scope in (["--user"], []):
        _, t = sh(["systemctl", *scope, "list-units", "--failed", "--plain", "--no-legend", "--no-pager"])
        out += [l.split()[0] for l in t.splitlines() if l.split()]
    mine = [u for u in out if re.search(r"halcyon|power-manager|touchpad-gestures|quickshell|hypr|honeypot", u)]
    return mine + [u for u in out if u not in mine]


def cmd_explain(args):
    what = args[0] if args else "last"
    notify_on, if_new = "--notify" in args, "--if-new" in args
    if if_new and (opt("aiExplain") is False or not ai_enabled()):
        return {"text": "", "skipped": "switched off"}
    if what == "unit":
        if len(args) < 2 or args[1].startswith("--"):
            raise Fail("explain unit <name>")
        job = explain_unit(args[1])
    elif what == "island":
        job = explain_island()
        if job is None:
            return {"text": "No errors in the island's log.", "nothing": True}
    elif what == "last":
        units = failed_units()
        job = explain_unit(units[0]) if units else explain_island()
        if job is None:
            return {"text": "Nothing has failed: no failed services and no errors in the island's log.", "nothing": True}
    else:
        raise Fail("explain unit <name> | island | last")
    name, prompt, sig, fix = job
    if if_new and seen_before(sig):
        return {"text": "", "skipped": "seen"}
    out = plain(generate(prompt, system=(
        "You explain errors on a Linux desktop to its owner. Answer in plain text with exactly two parts:\n"
        "What went wrong: one or two sentences, in plain words, naming the real cause from the log (quote the key line briefly).\n"
        "Fix: the most likely fix: an exact command, or the file and line to change and how. If the log does not show the cause, "
        f"say what to check next. A restart is `{fix}`; only suggest it when nothing better fits. Never suggest deleting user data."),
        num_predict=320, temperature=0.1, timeout=120))
    if not out:
        raise Fail("The model gave no answer.")
    full = f"{name}\n\n{out}\n"
    os.makedirs(CACHE, exist_ok=True)
    with open(LAST, "w", encoding="utf-8") as fh:
        fh.write(full)
    if notify_on:
        first = out.split("\n\n")[0] if "\n\n" in out else out
        notify(f"Halcyon: {name} hit a problem", (first[:300] + ("…" if len(first) > 300 else "")) +
               "\n(full answer: halcyon ai explain show)", "dialog-warning")
    return {"text": out, "name": name}


# ------------------------------------------------------------------------------------------------ organise notes
PLAN = os.path.join(CACHE, "organise-plan.json")
TAG_RE = re.compile(r"^[\w][\w \-]{0,19}$", re.U)


def norm_text(t):
    return " ".join(re.sub(r"[^\w\s]", " ", (t or "").lower()).split())


def find_duplicates(notes):
    """Groups of notes that say the same thing (text notes only, done ones too: a finished task and its copy are still a pair)."""
    cand = [n for n in notes if n.get("text") and not n.get("image") and not n.get("audio") and len(norm_text(n["text"])) >= 3]
    groups, used = [], set()
    for i, a in enumerate(cand):
        if a["id"] in used:
            continue
        ta = norm_text(a["text"])
        g = [a]
        for b in cand[i + 1:]:
            if b["id"] in used or bool(a.get("task")) != bool(b.get("task")):
                continue
            tb = norm_text(b["text"])
            short = min(len(ta), len(tb))
            r = difflib.SequenceMatcher(None, ta, tb).ratio()
            if ta == tb or (short >= 12 and r >= 0.88) or (short >= 12 and (ta in tb or tb in ta) and r >= 0.5):
                g.append(b)
        if len(g) > 1:
            used.update(n["id"] for n in g)
            # keep the pinned one, else the one not done, else the oldest
            g.sort(key=lambda n: (not n.get("pinned"), bool(n.get("done")), float(n.get("created") or 0)))
            groups.append([n["id"] for n in g])
    return groups


def cmd_organise(args):
    notesmod = load_module("halcyon_notes", "halcyon-notes.py")
    if notesmod is None:
        raise Fail("halcyon-notes.py could not be loaded.")
    if "--apply" in args:
        return apply_plan(notesmod)
    notes = [n for n in notesmod.load_notes() if isinstance(n, dict) and n.get("id")]
    if not notes:
        return {"text": "There are no notes to organise.", "tags": {}, "groups": [], "duplicates": []}
    by_id = {n["id"]: n for n in notes}
    dups = find_duplicates(notes)
    tags, groups, ai = {}, [], False
    live = [n for n in notes if not n.get("done")][-60:]
    if live and ai_enabled():
        listing = "\n".join(f'{n["id"]}: {" ".join(str(n.get("text") or n.get("why") or n.get("ocr") or "").split())[:180]}' for n in live)
        try:
            out = generate_json(
                "Personal notes, one per line as id: text\n" + listing + "\n\n"
                'Answer with JSON only: {"notes": [{"id": "<id>", "tags": ["tag", ...]}], "groups": [{"name": "<group>", "ids": ["<id>", ...]}]}.\n'
                "Give every note 1 to 3 short lowercase tags (one or two words each, like \"uni\", \"shopping\", \"linux\", \"ideas\"). Reuse the same "
                "tags across notes wherever they fit, so they group well. Groups: 2 to 6 named groups of notes that belong together; a note "
                "may be in no group. Use only the ids given.", num_predict=60 + 28 * len(live))
            for e in out.get("notes", []) if isinstance(out, dict) else []:
                if isinstance(e, dict) and e.get("id") in by_id and isinstance(e.get("tags"), list):
                    t = [str(x).strip().lower() for x in e["tags"] if isinstance(x, str) and TAG_RE.match(str(x).strip())][:3]
                    if t:
                        tags[e["id"]] = list(dict.fromkeys(t))
            for g in out.get("groups", []) if isinstance(out, dict) else []:
                if isinstance(g, dict) and isinstance(g.get("name"), str) and isinstance(g.get("ids"), list):
                    ids = [i for i in g["ids"] if i in by_id]
                    if len(ids) >= 2 and g["name"].strip():
                        groups.append({"name": g["name"].strip()[:30], "ids": list(dict.fromkeys(ids))})
            ai = True
        except (AiOff, Fail):
            pass
    plan = {"at": int(time.time()), "tags": tags, "groups": groups[:6], "duplicates": dups, "ai": ai,
            "count": len(notes), "notes_mtime": os.path.getmtime(notesmod.NOTES_FILE) if os.path.exists(notesmod.NOTES_FILE) else 0}
    write_json(PLAN, plan)
    short = lambda i: " ".join(str(by_id[i].get("text") or "").split())[:60]
    lines = []
    if dups:
        lines.append(f"{len(dups)} set{'s' if len(dups) != 1 else ''} of duplicates to merge:")
        lines += [f"  - \"{short(g[0])}\" ({len(g)} copies)" for g in dups[:8]]
    if groups:
        lines.append("Groups: " + ", ".join(f"{g['name']} ({len(g['ids'])})" for g in groups[:6]))
    if tags:
        cnt = {}
        for t in tags.values():
            for x in t:
                cnt[x] = cnt.get(x, 0) + 1
        lines.append(f"Tags for {len(tags)} notes: " + ", ".join(k for k, _ in sorted(cnt.items(), key=lambda kv: -kv[1])[:10]))
    if not lines:
        lines.append("Nothing to change: no duplicates" + ("" if ai else " (tags and groups need the AI, which is off or not running)") + ".")
    elif not ai:
        lines.append("(Tags and groups need the AI, which is off or not running: only duplicates are proposed.)")
    plan["text"] = "\n".join(lines)
    plan["changes"] = bool(dups or tags or groups)
    return plan


def apply_plan(notesmod):
    plan = read_json(PLAN, None)
    if not isinstance(plan, dict) or time.time() - plan.get("at", 0) > 3600:
        raise Fail("No recent proposal to apply. Run  organise  first and look at what it proposes.")
    with notesmod.locked():
        notes = notesmod.load_notes()
        by_id = {n.get("id"): n for n in notes if isinstance(n, dict)}
        backup = notesmod.NOTES_FILE + ".bak-organise"
        with contextlib.suppress(OSError):
            shutil.copy2(notesmod.NOTES_FILE, backup)
        tagged = merged = 0
        group_of = {}
        for g in plan.get("groups", []):
            for i in g.get("ids", []):
                group_of.setdefault(i, g["name"])
        for i, t in plan.get("tags", {}).items():
            if i in by_id:
                by_id[i]["tags"] = list(dict.fromkeys((by_id[i].get("tags") or []) + t))[:5]
                tagged += 1
        for i, name in group_of.items():
            if i in by_id:
                by_id[i]["group"] = name
        drop = set()
        for g in plan.get("duplicates", []):
            ids = [i for i in g if i in by_id and i not in drop]
            if len(ids) < 2:
                continue
            keep = by_id[ids[0]]
            have_lines = {norm_text(l) for l in keep["text"].splitlines()}
            for j in ids[1:]:
                other = by_id[j]
                extra = [l for l in other.get("text", "").splitlines() if l.strip() and norm_text(l) not in have_lines]
                if extra and norm_text(other["text"]) != norm_text(keep["text"]):
                    keep["text"] = keep["text"].rstrip() + "\n" + "\n".join(extra)
                    have_lines.update(norm_text(l) for l in extra)
                both = list(dict.fromkeys((keep.get("tags") or []) + (other.get("tags") or [])))[:5]
                if both:
                    keep["tags"] = both
                keep["pinned"] = bool(keep.get("pinned") or other.get("pinned"))
                if keep.get("task") and not keep.get("due") and other.get("due") and not other.get("done"):
                    keep["due"] = other["due"]
                drop.add(j)
                merged += 1
        notes = [n for n in notes if not (isinstance(n, dict) and n.get("id") in drop)]
        notesmod.save_notes(notes)
    with contextlib.suppress(OSError):
        os.unlink(PLAN)
    with contextlib.suppress(Exception):
        notesmod.sync_timer()
    notesmod.refresh_ui()
    msg = f"Tagged {tagged} note{'s' if tagged != 1 else ''}, merged {merged} duplicate{'s' if merged != 1 else ''}."
    return {"text": msg + f" A copy of the notes from before is in {backup}.", "tagged": tagged, "merged": merged}


# ------------------------------------------------------------------------------------------------ lyrics
LYR_CACHE = os.path.join(CACHE, "lyrics-ai.json")


def cmd_lyrics(args):
    what = (args[0] if args else "meaning").lower()
    if what != "meaning":
        raise Fail("lyrics meaning")
    music = load_module("halcyon_music", "halcyon-music.py")
    if music is None:
        raise Fail("halcyon-music.py could not be loaded.")
    meta = {}
    for k in ("title", "artist", "album", "url"):
        v = argval(args, "--" + k)
        if v:
            meta[k] = v
    with contextlib.suppress(ValueError):
        meta["duration"] = float(argval(args, "--duration", "0") or 0)
    need_ai()
    d = music.get_lyrics(meta)
    title, artist = d.get("title") or meta.get("title", ""), d.get("artist") or meta.get("artist", "")
    if not d.get("ok"):
        if not title:
            raise Fail(d.get("message") or "No lyrics for this song.")
        lines = []
    else:
        lines = [l for l in d.get("lines", []) if isinstance(l, str)]
    key = hashlib.sha1(f"{title}\x01{artist}\x01{what}".encode()).hexdigest()
    cache = read_json(LYR_CACHE, {})
    cache = cache if isinstance(cache, dict) else {}
    if key in cache and "--refresh" not in args:
        return {"text": cache[key], "title": title, "artist": artist, "kind": what, "cached": True}
    words = "\n".join(lines)[:5000]
    out = plain(generate(
        f"Song: {title}" + (f" by {artist}" if artist else "") + ("\n\nLyrics:\n" + words if words else "\n(No lyrics were found.)"),
        system=("Explain in three or four short sentences what this song is about: its story or theme, the mood, and any line "
                "that is easy to miss. Plain text, no lists. Quote at most a few words of the lyrics. If you do not know the song "
                "and there are no lyrics, say so instead of guessing."), num_predict=240, temperature=0.4))
    if not out:
        raise Fail("The model gave no answer.")
    cache[key] = out
    if len(cache) > 30:
        cache = dict(list(cache.items())[-30:])
    write_json(LYR_CACHE, cache)
    return {"text": out, "title": title, "artist": artist, "kind": what}


# ------------------------------------------------------------------------------------------------ main
COMMANDS = {"ask": cmd_ask, "do": cmd_do, "clip": cmd_clip, "brief": cmd_brief, "explain": cmd_explain,
            "organise": cmd_organise, "organize": cmd_organise, "lyrics": cmd_lyrics}


def main(argv):
    as_json = "--json" in argv
    args = [a for a in argv[1:] if a != "--json"]
    if not args or args[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return 0 if args else 2
    if args[0] == "explain" and args[1:2] == ["show"]:
        try:
            print(open(LAST, encoding="utf-8").read().rstrip())
            return 0
        except OSError:
            print("Nothing has been explained yet.")
            return 1
    fn = COMMANDS.get(args[0])
    if fn is None:
        print(f"halcyon-ai: unknown command '{args[0]}' (halcyon-ai.py --help)", file=sys.stderr)
        return 2
    try:
        res, code = dict(fn(args[1:]), ok=True, error=""), 0
    except AiOff as e:
        res, code = {"ok": False, "text": "", "error": str(e), "off": True}, 3
    except Fail as e:
        res, code = {"ok": False, "text": "", "error": str(e)}, 1
    except KeyboardInterrupt:
        return 130
    if as_json:
        print(json.dumps(res, ensure_ascii=False))
    elif res["ok"]:
        if res.get("text"):
            print(res["text"])
    else:
        print("halcyon-ai: " + res["error"], file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv))
