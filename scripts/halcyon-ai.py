#!/usr/bin/env python3
"""halcyon-ai.py: the small AI helpers of the desktop, one command each. They all ask the same local Ollama model as `ai` and the
notes (HALCYON_AI_MODEL, else MODEL= in ai-advisor.conf, else qwen2.5:3b-instruct), and they all stop when the master AI switch is
off (Settings > Performance > AI features). Nothing leaves this machine.

  halcyon-ai.py ask <question>                  one short answer (the launcher's  >ask ...). A question about Halcyon itself
                                                ("how do I turn off the constellations") is answered by howto below
  halcyon-ai.py howto <question>                a step-by-step guide to a Halcyon setting or command. The entries that match are
                                                looked up in Settings.qml and the launcher's commands, and only those are given to
                                                the model, so it names real switches; --json adds "open" (the Settings group or
                                                launcher command to go to). Works without the model too (the plain guide).
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
  halcyon-ai.py safety [--file LOG] [--notify]  review the newest safety-check log: sorts every finding into known noise (false
                                                positives), "confirm this" and "look at this", and says plainly whether everything is
                                                good. The verdict comes from fixed rules, so it works with the AI off; the model only
                                                explains what is left.
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
    if HOWTO_INTENT.search(q):
        hits = help_search(q)
        if hits and hits[0][0] >= HOWTO_MIN:
            return howto(q, hits)
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
    "app-volume":   ("the volume of ONE app that plays sound (Spotify, Discord, Firefox ...), not the speakers", "app", False),
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


# words that follow "mute" / precede "volume" but are not an app: "mute it", "sound volume 30" stay the speaker volume
NOT_APPS = {"the", "it", "all", "everything", "sound", "audio", "volume", "speaker", "speakers", "this", "that", "music", "system", "master", "computer", "laptop", "headphones"}


def _app_value(app, what):
    app = (app or "").lower()
    if app in NOT_APPS:
        return None
    if what in ("mute", "unmute"):
        return f"{app}|{what}"
    return f"{app}|{max(0, min(150, int(what)))}"


NUM = r"(\d+|one|two|three|four|five|six|seven|eight|nine|ten|first|second|third|fourth|fifth)"
DO_RULES = [
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
    (r"\b([a-z][\w-]{2,})\s+volume\s+(?:to\s+)?(\d{1,3})\s*(?:%|percent)?\s*$", "app-volume", lambda m: _app_value(m.group(1), m.group(2))),
    (r"\bvolume\s+(?:of|for|on)\s+([a-z][\w-]{2,})\s+(?:to\s+)?(\d{1,3})\s*(?:%|percent)?\s*$", "app-volume", lambda m: _app_value(m.group(1), m.group(2))),
    (r"\b(mute|unmute)\s+([a-z][\w-]{2,})\s*$", "app-volume", lambda m: _app_value(m.group(2), m.group(1))),
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
    if kind == "app":
        g = str(given or "").lower().strip()
        m = re.fullmatch(r"([\w .-]{1,40})\|(\d{1,3}|mute|unmute)", g)
        if not m or m.group(1).strip() in NOT_APPS:
            return None
        return f"{m.group(1).strip()}|{min(150, int(m.group(2))) if m.group(2).isdigit() else m.group(2)}"
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
    for pat, action, getv in DO_RULES:
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
               "pct": ' value: a number 0-100, or "up", "down", "mute"',
               "app": ' value: "<app name>|<0-150, mute or unmute>", e.g. "spotify|30"'}.get(kind, "")
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
             "power-mode": f"Power mode: {v}", "theme": "Theme: " + str(v),
             "app-volume": "Volume of " + str(v).split("|")[0] + ": " + str(v).split("|")[-1] + ("%" if str(v).split("|")[-1].isdigit() else "")}
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
    if a == "app-volume":
        app, what = str(v).split("|", 1)
        tools = os.path.join(RICE, "scripts", "halcyon-tools.py")
        args = ["mixer", "set", app, what] if what.isdigit() else ["mixer", what, app]
        rc, _ = sh(["python3", tools] + args, timeout=10)
        if rc != 0:
            raise Fail(f"Nothing called '{app}' is playing sound right now.")
        return True
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


# ------------------------------------------------------------------------------------------------ safety check review
# Reads what src/safety-check wrote (/var/log/halcyon/safety_check/safety_check_DATE.log) and decides, WITHOUT the model, what is
# known noise, what to confirm and what needs a look. Rules first, model second: a 3B model must not be the one that says "all good".
SAFETY_DIRS = ["/var/log/halcyon/safety_check", os.path.join(HOME, ".local", "state", "halcyon", "safety_check")]
RKH_LOG = "/var/log/rkhunter.log"
LOG_TS = re.compile(r"^\[\d\d:\d\d:\d\d\] ?")
SEC_RE = re.compile(r"^(\d)/7 \u2014 (.+)$")
TOOL_OF = {"1": "update", "2": "clamav", "3": "rkhunter", "4": "firewall", "5": "lynis", "6": "aide", "7": "backup"}
TOOL_LABEL = {"update": "System update", "clamav": "ClamAV", "rkhunter": "rkhunter", "firewall": "Firewall", "lynis": "Lynis",
              "aide": "AIDE", "backup": "Backup"}
PREFIX = re.compile(r"^(?:rkhunter stderr|rkhunter|AIDE stderr|AIDE|ufw status): ?")

# (tool, regex on the finding, verdict, why, how to check). "ok" = known harmless noise; "verify" = usually harmless, confirm it once;
# a finding that matches nothing is "look". Order matters: the first match wins, so the dangerous patterns come first.
SAFETY_RULES = [
    ("rkhunter", r"Found\s*\]|rootkit.*(found|infected)|Possible rootkits:\s*[1-9]", "look",
     "rkhunter says a known rootkit file or trace was found", "sudo grep -B2 -A3 -i 'found' /var/log/rkhunter.log"),
    ("rkhunter", r"/dev/shm|[Ss]uspicious file types|[Pp]romiscuous|hidden ports|[Ss]uspicious.*port", "look",
     "this kind of warning is not usually a side effect of normal use", "sudo grep -B1 -A3 'Warning' /var/log/rkhunter.log"),
    ("rkhunter", r"replaced by a script.*?/usr/bin/(egrep|fgrep|ldd|lwp-request|which|ifup|ifdown|unhide\.rb)\b"
                 r"|/usr/bin/(egrep|fgrep|ldd|lwp-request|which|ifup|ifdown|unhide\.rb)\b.*replaced by a script", "ok",
     "these programs are shell scripts in the package, rkhunter only expects binaries", "pacman -Qo /usr/bin/egrep"),
    ("rkhunter", r"[Hh]idden (file|director\w*) found: /(etc/\.(updated|pwd\.lock)|usr/share/man/man5/\.k5(login|identity)\.5\.gz"
                 r"|usr/lib/debug/\.build-id|dev/\.udev)", "ok",
     "a normal dot-file made by the system itself", "pacman -Qo THE_PATH"),
    ("rkhunter", r"SSH root access|PermitRootLogin|SSH and rkhunter configuration", "verify",
     "a setting, not an infection: it only matters if the SSH server is running", "systemctl is-active sshd"),
    ("rkhunter", r"file propert(y|ies)|[Ff]ile properties", "verify",
     "very often just the system update that ran first: new program versions have new fingerprints",
     "sudo pacman -Qkk 2>&1 | grep -v ' 0 altered files'"),
    ("rkhunter", r"[Aa]pplication|version|out-of-date|outdated", "verify",
     "an old-version note about a program, not an attack", "pacman -Qu"),
    ("rkhunter", r"[Hh]idden (file|director)", "verify",
     "dot-files in system folders are often harmless but name the file before deciding", "pacman -Qo THE_PATH"),
    ("rkhunter", r"Checking for (hidden files|file properties|prerequisites|SSH|application)|'strings' command|shared libraries", "verify",
     "the console only shows the check name; the exact file is in rkhunter's own log",
     "sudo grep -A2 'Warning' /var/log/rkhunter.log"),
    ("clamav", r"Eicar|EICAR", "ok", "the standard antivirus test file, harmless by design", "delete it if you did not mean to keep it"),
    ("clamav", r"Heuristics\.(Encrypted|PDF|OLE2)|\.Heuristics|Broken\.Executable|PUA\.", "verify",
     "a heuristic guess (password-protected archive, macro, unwanted-program signature), often a false positive",
     "sha256sum THE_FILE and look the hash up on virustotal.com (the hash only, never upload private files)"),
    ("aide", r"^/(etc/(passwd|shadow|group|gshadow|sudoers|ssh|pam\.d|systemd/system|cron|profile|ld\.so\.preload)|boot|usr/local/bin|root/\.ssh)",
     "look", "a security-relevant file changed or appeared", "pacman -Qo THE_PATH; ls -l THE_PATH"),
    ("aide", r"^/var/(log|cache|tmp|lib/(pacman|aide|systemd|NetworkManager|ollama|bluetooth))|^/etc/(resolv\.conf|ld\.so\.cache|adjtime|mtab)", "ok",
     "logs, caches and package/system state change all the time", ""),
    ("aide", r"^/(usr|opt)/", "verify",
     "expected after a system update; unexpected if you did not update", "pacman -Qo THE_PATH && pacman -Qkk $(pacman -Qqo THE_PATH)"),
    ("firewall", r"INACTIVE", "verify", "the firewall was off and the check switched it back on; find out why it was off",
     "systemctl is-enabled ufw; sudo ufw status verbose"),
    ("backup", r"not found|skipped|not connected|Failed to mount|not ext4", "verify",
     "not a security problem, but this time there is no backup", "plug in the backup disk and run the check again"),
]


def safety_logs():
    out = []
    for d in SAFETY_DIRS:
        try:
            out += [os.path.join(d, f) for f in os.listdir(d) if f.startswith("safety_check_") and f.endswith(".log")]
        except OSError:
            pass
    return sorted(out, key=lambda p: os.path.getmtime(p))


def last_run(lines):
    """A day's log holds every run of that day, one after another: only the last one counts."""
    idx = [i for i, l in enumerate(lines) if "Safety Check started" in l]
    return lines[idx[-1]:] if idx else lines


def parse_safety(text):
    """The log as {"items": [(tool, text)], "skipped": [...], "clean_counts": {...}, "errors": int|None, "done": bool}."""
    lines = last_run(text.splitlines())
    sec, items, skipped, counts = "", [], [], {}
    errors, done = None, False
    pending = []                                   # rkhunter "[ Warning ]" console lines
    for raw in lines:
        l = LOG_TS.sub("", raw).rstrip()
        m = SEC_RE.match(l.strip())
        if m:
            sec = TOOL_OF.get(m.group(1), "")
            continue
        body = PREFIX.sub("", l).strip()
        if not body:
            continue
        if "Errors found:" in body:
            with contextlib.suppress(ValueError):
                errors = int(body.rsplit(":", 1)[1].strip())
        if "Check complete" in body:
            done = True
        if body.startswith("! ") and ("not installed" in body or "not updated" in body or "No supported" in body):
            skipped.append(body[2:])
            continue
        if sec == "clamav":
            m = re.match(r"^(.*): (\S+) FOUND$", body)
            if m:
                items.append(("clamav", f"{m.group(1)}: {m.group(2)}"))
            m = re.match(r"^Infected files:\s*(\d+)", body)
            if m:
                counts["clamav"] = int(m.group(1))
        elif sec == "rkhunter":
            if "Warning" in body and "\u26a0" not in body[:2]:
                items.append(("rkhunter", re.sub(r"\s{2,}", " ", body)))
        elif sec == "aide":
            m = re.match(r"^(Added|Removed|Changed) entries:\s*(\d+)", body)
            if m:
                counts.setdefault("aide", 0)
                counts["aide"] += int(m.group(2))
                counts["aide_seen"] = True
                continue
            m = re.search(r"(?:^(?:changed|added|removed):\s*|\s:\s+)(/\S.*)$", body)
            if m:
                items.append(("aide", m.group(1).strip()))
        elif sec == "firewall":
            if "INACTIVE" in body:
                items.append(("firewall", body.lstrip("\u26a0 ").strip()))
            m = re.search(r"Status:\s*(\w+)", body)
            if m:
                counts["ufw"] = m.group(1).lower()
        elif sec == "lynis":
            m = re.search(r"Hardening index\s*:\s*(\d+)", body)
            if m:
                counts["lynis_index"] = int(m.group(1))
            if re.match(r"^! .+\[[A-Z]+-\d+\]", body):
                items.append(("lynis", body[2:].strip()))
        if body.startswith("\u26a0") and sec in ("update", "backup", "firewall"):
            if not (sec == "firewall" and "INACTIVE" in body):
                items.append((sec, body.lstrip("\u26a0 ").strip()))
    # rkhunter's console only says "[ Warning ]" next to a check name; the file is in its own log (root-only, so often unreadable).
    # When the log does carry the detail lines ("Warning: ..."), they say more than the bare check names: keep only those.
    bare = re.compile(r"\[\s*Warning\s*\]\s*$")
    if any(t == "rkhunter" and not bare.search(x) for t, x in items):
        items = [(t, x) for t, x in items if not (t == "rkhunter" and bare.search(x))]
    return {"items": items, "skipped": skipped, "counts": counts, "errors": errors, "done": done}


def triage(parsed):
    """-> list of dicts {tool, text, verdict, why, check}. verdict: ok | verify | look."""
    counts, out = parsed["counts"], []
    for tool, text in parsed["items"]:
        if tool == "aide" and counts.get("aide_seen") and counts.get("aide", 0) == 0:
            continue                                # the report itself says 0 added / removed / changed: a word in a path, not a change
        if tool == "clamav" and counts.get("clamav") == 0:
            continue
        hit = None
        for t, rx, verdict, why, check in SAFETY_RULES:
            if t == tool and re.search(rx, text):
                hit = {"verdict": verdict, "why": why, "check": check}
                break
        if hit is None:
            hit = {"verdict": "look", "why": "no rule knows this one, so it is treated as real until you have looked",
                   "check": "sudo less /var/log/halcyon/safety_check/"}
        if tool == "lynis":
            hit = {"verdict": "verify", "why": "a hardening suggestion from Lynis, not a sign of an attack", "check": "sudo lynis show details TEST-ID"}
        path = text.split(":", 1)[0] if tool == "clamav" else text
        hit["check"] = hit["check"].replace("THE_PATH", path if path.startswith("/") else "THE_PATH").replace("THE_FILE", path)
        if "THE_PATH" in hit["check"] or "THE_FILE" in hit["check"]:      # a bare check name: no file to point at yet
            hit["check"] = "sudo grep -B1 -A3 'Warning' /var/log/rkhunter.log   (names the exact file)"
        out.append(dict(hit, tool=tool, text=text))
    return out


def safety_verdict(parsed, found):
    look = [f for f in found if f["verdict"] == "look"]
    verify = [f for f in found if f["verdict"] == "verify"]
    noise = [f for f in found if f["verdict"] == "ok"]
    if not parsed["items"] and not parsed["done"]:
        return "unclear", "The log has no finished run: the check may have been stopped half way."
    if look:
        return "look", f"{len(look)} thing{'s' if len(look) != 1 else ''} need a look."
    if verify:
        return "verify", f"Probably fine. {len(verify)} thing{'s' if len(verify) != 1 else ''} to confirm once."
    if noise:
        return "good", f"Everything is good. {len(noise)} warning{'s were' if len(noise) != 1 else ' was'} known noise (false positives)."
    return "good", "Everything is good: no findings."


def safety_report(path, as_notify=False):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    parsed = parse_safety(text)
    found = triage(parsed)
    key, headline = safety_verdict(parsed, found)
    out = [f"Safety check log: {os.path.basename(path)}", f"Verdict: {headline}"]
    for verdict, title in (("look", "Needs a look"), ("verify", "Confirm once"), ("ok", "Known noise (false positives)")):
        group = [f for f in found if f["verdict"] == verdict]
        if not group:
            continue
        out.append(f"\n{title} ({len(group)})")
        for f in group[:12]:
            out.append(f"- {TOOL_LABEL.get(f['tool'], f['tool'])}: {f['text'][:200]}")
            out.append(f"    {f['why']}." + (f" Check: {f['check']}" if f["check"] and verdict != "ok" else ""))
        if len(group) > 12:
            out.append(f"- ... and {len(group) - 12} more (see the log)")
    c = parsed["counts"]
    seen = [f"ClamAV: {c['clamav']} infected" if "clamav" in c else "", f"firewall {c['ufw']}" if "ufw" in c else "",
            f"Lynis hardening index {c['lynis_index']}" if "lynis_index" in c else ""]
    seen = [x for x in seen if x]
    if seen:
        out.append("\nSeen: " + ", ".join(seen))
    if parsed["skipped"]:
        out.append("Not checked: " + "; ".join(parsed["skipped"]) + ". Those parts say nothing about your system.")
    if parsed["errors"] is not None and parsed["errors"] > len([f for f in found if f["verdict"] != "ok"]):
        out.append(f"The check itself counted {parsed['errors']} issue(s): its word matching is cruder than these rules, "
                   "so a higher number there is not by itself a problem.")
    report = "\n".join(out)
    if key == "good" and parsed["skipped"]:
        report = report.replace("Everything is good", "Everything that was checked is good", 1)
    if as_notify:
        notify("Halcyon safety check", headline, "dialog-warning" if key in ("look", "unclear") else "security-high")
    return report, key, [f for f in found if f["verdict"] != "ok"]


def cmd_safety(args):
    path = argval(args, "--file")
    if not path:
        logs = safety_logs()
        if not logs:
            raise Fail("No safety-check log found (looked in " + " and ".join(SAFETY_DIRS) + "). Run the safety check first.")
        path = logs[-1]
    if not os.path.isfile(path):
        raise Fail(f"No such log: {path}")
    report, key, open_items = safety_report(path, "--notify" in args)
    note = ""
    if open_items and "--no-ai" not in args:
        listing = "\n".join(f"- [{f['verdict']}] {f['tool']}: {f['text'][:200]}  (rule note: {f['why']})" for f in open_items[:8])
        try:
            note = plain(generate(
                "Findings from a Linux security check, already sorted by fixed rules:\n" + listing + "\n",
                system=("You explain security-scan findings to the owner of a Linux desktop. For each finding give one plain sentence: "
                        "what it means and whether it is likely a false positive or worth acting on, and the one next step. "
                        "Only talk about the findings listed; do not add others, do not claim a system is infected or safe, and "
                        "never suggest deleting user data or system files. If you are not sure, say so."),
                num_predict=380, temperature=0.1, timeout=120))
        except (AiOff, Fail) as e:
            note = "(AI notes unavailable: " + str(e) + " The rule-based result above stands on its own.)"
    text = report + (("\n\nAI notes on the open items\n" + note) if note else "")
    return {"text": text, "verdict": key, "open": len(open_items)}


# ------------------------------------------------------------------------------------------------ howto: a guide to Halcyon itself
# The model is small and knows nothing about Halcyon, so it is never asked to remember: the question is matched against the real
# Settings rows (Settings.qml: group, label, description, the Advanced fold) and the launcher commands (Launcher.qml), and the model
# only picks the entry that answers and words the steps. Steps that do not name the entry's own label are thrown away and the plain
# guide (built from the entry) is shown instead.
HOWTO_INTENT = re.compile(r"\b(how|where|turn|switch|disable|enable|hide|show|change|set|stop|remove|get rid|make|can i|toggle|"
                          r"off|on|setting|settings|option)\b", re.I)
HOWTO_MIN = 4               # a label word or two: below it, >ask treats the question as a general one
HELP_STOP = set("""a an the i me my to of in on off it its is are be do does did can could would should how what where when which
    want wanna like please just turn switch set make get rid stop start enable disable change toggle remove this that
    there with for from and or not no any all some them they you your halcyon desktop thing things way using use""".split())
STR_FIELD = re.compile(r'(\w+): "((?:\\.|[^"\\])*)"')


def _unq(v):
    try:
        return json.loads('"' + v + '"')
    except ValueError:
        return v


def _stem(w):
    for suf in ("ations", "ation", "ings", "ing", "ies", "es", "ed", "s"):
        if len(w) > len(suf) + 3 and w.endswith(suf):
            return w[: -len(suf)]
    return w


def _words(t):
    return [_stem(w) for w in re.findall(r"[a-z0-9]+", t.lower()) if w not in HELP_STOP and len(w) > 1]


def help_index():
    """Every Settings row and launcher command as {kind, label, where, text, open, ...}."""
    out = []
    try:
        src = open(os.path.join(ISLAND_DIR, "Settings.qml"), encoding="utf-8").read()
    except OSError:
        src = ""
    pages = {}
    for m in re.finditer(r'\{ id: "([^"]+)", sub: "[^"]*", groups: \[([^\]]*)\] \}', src):
        for g in re.findall(r'"(\w+)"', m.group(2)):
            pages[g] = m.group(1)
    gm = list(re.finditer(r'^ {8}\{ id: "(\w+)", title: "([^"]+)", section: "([^"]+)", items: \[', src, re.M))
    for i, g in enumerate(gm):
        body = src[g.end(): gm[i + 1].start() if i + 1 < len(gm) else len(src)]
        gid, title = g.group(1), g.group(2)
        for line in re.findall(r"^ {12}\{ type: .*$", body, re.M):
            f = {k: _unq(v) for k, v in STR_FIELD.findall(line)}
            if not f.get("label"):
                continue
            opts = [_unq(x) for x in re.findall(r'(?:o|ch)\("[^"]*", "((?:\\.|[^"\\])*)"\)', line)]
            out.append({"kind": "setting", "type": f.get("type", ""), "label": f["label"], "group": gid, "title": title,
                        "page": pages.get(gid, g.group(3)), "adv": "adv: true" in line, "opts": opts, "btn": f.get("btn", ""),
                        "text": " ".join([f.get("desc", ""), f.get("why", ""), " ".join(opts)]), "open": {"settings": gid}})
    try:
        lsrc = open(os.path.join(ISLAND_DIR, "Launcher.qml"), encoding="utf-8").read()
    except OSError:
        lsrc = ""
    for line in re.findall(r'^ {8}\{ id: "[\w-]+", name: .*$', lsrc, re.M):
        f = {k: _unq(v) for k, v in STR_FIELD.findall(line)}
        if f.get("id") and f.get("name"):
            out.append({"kind": "command", "label": f["name"], "id": f["id"], "title": "", "page": "", "adv": False, "opts": [],
                        "text": f.get("desc", "") + " " + f.get("kw", ""), "open": {"command": f["id"]}})
    return out


def help_search(q, limit=6):
    """[(score, entry)] best first. Label words count most, then the group, then the description and keywords."""
    qw = set(_words(q))
    if not qw:
        return []
    ql = q.lower()
    res = []
    for e in help_index():
        lw, tw, dw = set(_words(e["label"])), set(_words(e["title"])), set(_words(e["text"]))
        s = 3 * len(qw & lw) + 2 * len(qw & tw) + len(qw & dw)
        if not s:
            continue
        s += 2 * len(qw & lw) / max(1, len(lw))        # the question covers most of the label: "Moving stars in bars"
        if e["label"].lower() in ql:
            s += 5
        if re.search(r"\b(off = none|master switch|everywhere|anywhere)\b", e["text"], re.I):
            s += 1          # the main switch of a feature beats its details
        if e["kind"] == "command":
            s -= 1          # a Settings row is usually what "turn X off" means
        res.append((round(s, 1), e))
    res.sort(key=lambda x: -x[0])
    return res[:limit]


def _where(e):
    if e["kind"] == "command":
        return f'the launcher command "{e["label"]}" (type >{e["label"].lower()})'
    return f'Settings > {e["page"]} > {e["title"]}' + (' (under "Advanced" in that group)' if e["adv"] else "") + f' > "{e["label"]}"'


def plain_steps(q, e, action=""):
    """The steps, straight from the entry. action (the model's reading of the question): on | off | one of the choices | ""."""
    act = action.strip().lower()
    # the question's own words win over the model's reading (small models answer "on" to "turn X off")
    q_off = re.search(r"\b(off|disable|hide|stop|remove|get rid|no more|without|less)\b", q, re.I) is not None
    q_on = re.search(r"\b(turn on|switch on|enable|show|start|make)\b", q, re.I) is not None
    off = q_off or (not q_on and act == "off")
    if e["kind"] == "command":
        return [f'Open the launcher and type  >{e["label"].lower()}', "Press Enter."]
    steps = ["Open Settings (press Enter here, or type  >settings  in the launcher).",
             f'Go to the "{e["page"]}" page, group "{e["title"]}".']
    if e["adv"]:
        steps.append('Open "Advanced" at the bottom of that group.')
    t, lab = e["type"], e["label"]
    if t == "toggle":
        steps.append(f'Switch "{lab}" {"off" if off else "on"}.')
    elif t == "seg" and e["opts"]:
        pick = next((o for o in e["opts"] if act and act == o.lower()), None)
        pick = pick or next((o for o in e["opts"] if off and re.match(r"(off|none|no)\b", o, re.I)), None)
        pick = pick or next((o for o in e["opts"] if set(_words(o)) & set(_words(q))), None)
        steps.append(f'Under "{lab}", pick "{pick}".' if pick else f'Under "{lab}", pick one of: {", ".join(e["opts"])}.')
    elif t == "chips":
        steps.append(f'In "{lab}", {"untick" if off else "tick"} the boxes you want ({", ".join(e["opts"])}).')
    elif t == "action":
        steps.append(f'Press "{e["btn"] or lab}" next to "{lab}".')
    else:
        steps.append(f'Change "{lab}".')
    return steps


def howto(q, hits=None):
    hits = hits if hits is not None else help_search(q)
    if not hits or hits[0][0] < 2:
        raise Fail("I could not find a Halcyon setting or command for that. Try other words, or search in Settings.")
    refs = "\n".join(f'[{i + 1}] "{e["label"]}" ({e.get("type") or e["kind"]}' + (f'; choices: {", ".join(e["opts"])}' if e["opts"] else "")
                     + f'). In {e["title"] or "the launcher"}. ' + e["text"][:300] for i, (_, e) in enumerate(hits))
    pick, action, note, by_ai = hits[0][1], "", "", True
    # the model reads the question and the entries; where things are and what they are called comes from the entries themselves
    try:
        d = generate_json(
            f"Question: {q}\n\nEntries:\n{refs}",
            system=("You are the built-in help of Halcyon, a Linux desktop. Pick the ONE entry that does what the question asks "
                    "(prefer the main switch of a feature over its details). Reply with JSON: {\"entry\": <its number, 0 if no "
                    "entry fits>, \"action\": \"on\" or \"off\" for a switch, the exact choice for a list of choices, \"\" "
                    "otherwise, \"note\": \"one or two short sentences: what it changes and anything worth knowing, using only "
                    "what the entry says\"}"),
            num_predict=200)
        n = int(d.get("entry", 0) or 0)
        if n == 0:
            raise Fail("I could not find a Halcyon setting for that. Try other words, or search in Settings.")
        if 1 <= n <= len(hits):
            pick = hits[n - 1][1]
        action = str(d.get("action") or "")
        note = " ".join(plain(str(d.get("note") or "")).split())
    except AiOff:
        by_ai = False
    except (Fail, ValueError, TypeError) as e:
        if "could not find" in str(e):
            raise
        by_ai = False
    steps = plain_steps(q, pick, action)
    text = "\n".join(f"{i + 1}. {x}" for i, x in enumerate(steps)) + (("\n" + note) if note else "")
    return {"text": text, "kind": "howto", "steps": steps, "note": note, "where": _where(pick), "open": pick["open"], "ai": by_ai}


def cmd_howto(args):
    q = " ".join(a for a in args if not a.startswith("--")).strip()
    if not q:
        raise Fail("Say what you want to change, e.g.  howto turn off the constellations")
    return howto(q)


# ------------------------------------------------------------------------------------------------ main
COMMANDS = {"ask": cmd_ask, "howto": cmd_howto, "do": cmd_do, "clip": cmd_clip, "brief": cmd_brief, "explain": cmd_explain,
            "safety": cmd_safety, "organise": cmd_organise, "organize": cmd_organise, "lyrics": cmd_lyrics}


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
