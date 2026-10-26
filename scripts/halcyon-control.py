#!/usr/bin/env python3
"""halcyon-control.py: everything Luna can know about and do in Halcyon, in one place.

Luna (github.com/X-netrunner/LUNA-AI) calls this through three tools, one per tier, so her own gates decide what may run:

  halcyon_info      tier info      reads only, always allowed
  halcyon_do        tier do        changes Halcyon's own state (windows, settings, notes, modes). Needs [external] allow_halcyon_actions
  halcyon_security  tier security  firewall, antivirus and ClamAV state. Needs Luna's developer-signed capability gate, and admin rights
                                   (the password Luna already holds for sudo is passed in the environment, never on a command line)

  halcyon-control.py TIER ACTION [ARGS...] [--json]
  halcyon-control.py help [TIER]       every action, its tier and how to call it
  halcyon-control.py manual            the short "what Halcyon is and how to operate it" text Luna reads at the start of a session

An action only runs under its own tier: asking for `do` actions under `info` is refused here as well, so a mistake in Luna's
tool wiring cannot widen anything. Everything stays on this machine. Exit code 0 ok, 1 failed, 2 usage, 3 refused (wrong tier).
"""
import importlib.util
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
RICE = os.environ.get("HALCYON_DIR", os.path.join(HOME, ".config", "Halcyon"))
HERE = os.path.dirname(os.path.abspath(__file__))
ISLAND = os.path.join(RICE, "quickshell", "island")
STATE = os.environ.get("HALCYON_STATE") or os.path.join(HOME, ".local", "state", "island")
TIERS = ("info", "do", "security")
MAX_OUT = 6000


class Refused(Exception):
    pass


class Fail(Exception):
    pass


def ai():
    """halcyon-ai.py as a module (its docs search, settings index and the ClamAV helpers); loaded once."""
    if not hasattr(ai, "mod"):
        for base in (HERE, os.path.join(RICE, "scripts")):
            p = os.path.join(base, "halcyon-ai.py")
            if os.path.isfile(p):
                spec = importlib.util.spec_from_file_location("halcyon_ai", p)
                ai.mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(ai.mod)
                break
        else:
            raise Fail("halcyon-ai.py not found")
    return ai.mod


def run(argv, timeout=20, sudo=False, input_text=None):
    """(exit code, stdout+stderr text). With sudo=True the admin password Luna passes in LUNA_SUDO is fed to `sudo -S`."""
    if sudo and os.geteuid() != 0:
        pw = os.environ.get("LUNA_SUDO", "")
        argv = ["sudo", "-S", "-p", "", *argv] if pw else ["sudo", "-n", *argv]
        input_text = (pw + "\n") if pw else input_text
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, input=input_text)
    except FileNotFoundError:
        return 127, f"{argv[0] if argv[0] != 'sudo' else argv[-1]}: not installed"
    except subprocess.TimeoutExpired:
        return 124, "took too long"
    return r.returncode, ((r.stdout or "") + (r.stderr or "")).strip()


def island(*call):
    code, out = run(["quickshell", "ipc", "-p", ISLAND, "call", "island", *call], timeout=6)
    if code != 0:
        raise Fail("the island is not running or did not answer: " + out[:200])
    return out


def settings_opt():
    try:
        return json.load(open(os.path.join(STATE, "settings.json"), encoding="utf-8")).get("opt", {})
    except (OSError, ValueError, AttributeError):
        return {}


def clip(text):
    text = text.strip()
    return text if len(text) <= MAX_OUT else text[:MAX_OUT] + f"\n... ({len(text) - MAX_OUT} more characters)"


def arg_safe(v, what="value"):
    """Words that go to another program: no option look-alikes, no control characters."""
    v = str(v)
    if not v or v.startswith("-") or re.search(r"[\x00-\x1f]", v):
        raise Fail(f"bad {what}: {v[:40]!r}")
    return v


# ============================================================================================= INFO (read only)
def a_overview(args):
    a = ai()
    out = []
    out.append("island: " + ("running" if run(["pgrep", "-x", "quickshell"])[0] == 0 else "NOT running"))
    out.append("gaming mode: " + ("on" if a.gaming() else "off") + "; AI features: " + ("on" if a.ai_enabled() else "off"))
    o = settings_opt()
    out.append(f"UI style: {o.get('uiStyle', 'new')}; Aggressive Memory Freeing: {'off' if o.get('lazyLoad') is False else 'on'}")
    gm = "igpu"
    try:
        gm = open(os.path.join(RICE, "gpu-mode"), encoding="utf-8").read().split()[0]
    except (OSError, IndexError):
        pass
    out.append("GPU mode: " + gm)
    for label, cmd in (("firewall", ["ai-firewall", "status"]), ("antivirus", ["ai-antivirus", "status"])):
        if shutil.which(cmd[0]):
            code, text = run(cmd, timeout=10)
            out.append(f"{label}: " + " | ".join(text.splitlines()[:4]) if text else f"{label}: no answer")
        else:
            out.append(f"{label}: not installed")
    out.append("ClamAV: " + ("installed" if shutil.which("clamscan") else "not installed"))
    if shutil.which("sysmode"):
        out.append("sysmode: " + (run(["sysmode", "status"], timeout=10)[1].splitlines() or ["?"])[0])
    code, text = run([sys.executable, os.path.join(HERE, "halcyon-notes.py"), "list"], timeout=10)
    out.append("notes: " + (str(len([l for l in text.splitlines() if l.strip()])) + " lines" if code == 0 else "unavailable"))
    return "\n".join(out)


def a_catalog(args):
    """Every launcher command and window, by id: the ids `do open ID` accepts."""
    items = [e for e in ai().help_index() if e["kind"] == "command"]
    return "\n".join(f"{e['id']}: {e['label']}: {' '.join(e['text'].split())[:110]}" for e in items)


def a_docs(args):
    if not args:
        raise Fail("usage: docs WORDS  (e.g. docs how do I change the lock screen background)")
    q = " ".join(args)
    a = ai()
    parts = []
    ctx = a.halcyon_context(q, limit=6, budget=3800)
    if ctx:
        parts.append(ctx)
    for sc, e in a.help_search(q, 5):
        parts.append(f"- Setting/command: {a._where(e)} [key {e.get('key') or e.get('id', '')}] {e['text'][:160].strip()}")
    return "\n".join(parts) or "Nothing in Halcyon's docs or settings matches that. Try other words, or `catalog`."


def a_settings(args):
    """Settings rows that match the words, with the key to set and the value now."""
    if not args:
        raise Fail("usage: settings WORDS")
    o = settings_opt()
    lines = []
    for sc, e in ai().help_search(" ".join(args), 8):
        if e["kind"] != "setting":
            continue
        key = e.get("key", "")
        now = o.get(key[4:], "(default)") if key.startswith("opt:") else "(see Settings)"
        opts = f" choices: {', '.join(e['opts'][:8])}" if e.get("opts") else ""
        how = key if key.startswith(("opt:", "st:")) else f"change in the Settings window: {ai()._where(e)}"
        lines.append(f"{how}: {e['label']} [{e['type']}] now {now}{opts} - {a_short(e['text'])}")
    return "\n".join(lines) or "No setting matches those words."


def a_short(t):
    return " ".join(str(t).split())[:140]


def a_notes(args):
    code, out = run([sys.executable, os.path.join(HERE, "halcyon-notes.py"), *(args or ["list"])[:1]], timeout=15)
    return out or "no notes"


def a_calendar(args):
    p = os.path.join(ISLAND, "scripts", "gcal.py")
    code, out = run([sys.executable, p, "events"], timeout=15)
    if code != 0:
        return "The calendar is not set up (Calendar window > connect), or it could not be read: " + out[:200]
    try:
        ev = json.loads(out)
        ev = ev.get("events", ev) if isinstance(ev, dict) else ev
        now = time.time()
        rows = []
        for e in ev:
            s = e.get("start") or e.get("ts") or 0
            if isinstance(s, (int, float)) and s >= now - 3600:
                rows.append((s, e.get("title") or e.get("summary") or "(no title)"))
        rows.sort()
        return "\n".join(f"{time.strftime('%a %d %b %H:%M', time.localtime(s))}  {t}" for s, t in rows[:15]) or "Nothing coming up."
    except (ValueError, AttributeError, TypeError):
        return clip(out)


def a_firewall(args):
    if not shutil.which("ai-firewall"):
        return "ai-firewall is not installed."
    sub = (args or ["status"])[0]
    if sub not in ("status", "history", "feeds", "posture", "check"):
        raise Fail("info firewall: status | history | feeds | posture")
    cmd = ["ai-firewall", sub] + ([] if sub != "feeds" else [])
    return clip(run(cmd, timeout=20)[1])


def a_antivirus(args):
    if not shutil.which("ai-antivirus"):
        return "ai-antivirus is not installed."
    sub = (args or ["status"])[0]
    if sub not in ("status", "alerts", "actions", "exceptions", "rules", "proposals"):
        raise Fail("info antivirus: status | alerts | actions | exceptions | rules | proposals")
    extra = ["--unacked"] if sub == "alerts" else []
    return clip(run(["ai-antivirus", sub, *extra], timeout=30)[1])


def a_clamav(args):
    a = ai()
    sub = (args or ["test"])[0]
    if sub == "test":
        return clip(a.cmd_clamav(["test"])["text"])
    if sub == "exceptions":
        return clip(a.cmd_clamav(["exceptions"])["text"])
    raise Fail("info clamav: test | exceptions   (a scan is a security action)")


def a_sysmode(args):
    if not shutil.which("sysmode"):
        return "sysmode is not installed."
    return clip(run(["sysmode", "status"], timeout=15)[1])


def a_updates(args):
    code, out = run(["checkupdates"], timeout=60) if shutil.which("checkupdates") else (127, "checkupdates is not installed (pacman-contrib)")
    return clip(out) if out else "No updates pending."


def a_luna_status(args):
    p = os.path.join(HERE, "halcyon-luna.py")
    return run([sys.executable, p, "status"], timeout=10)[1]


# ============================================================================================= DO (Halcyon's own state)
def a_open(args):
    if not args:
        raise Fail("usage: open COMMAND_ID  (ids: halcyon_info catalog)")
    cid = arg_safe(args[0], "command id")
    known = {e["id"] for e in ai().help_index() if e["kind"] == "command"}
    if cid not in known and cid not in ("closeTop",):
        raise Fail(f"no such command: {cid}. List them with: halcyon_info catalog")
    return island("closeTop") if cid == "closeTop" else (island("command", cid) or f"opened {cid}")


def a_set(args):
    """set opt:KEY VALUE (a Settings row) or st:KEY VALUE (Startup & background)."""
    if len(args) < 2:
        raise Fail("usage: set opt:KEY VALUE   (find the key with: halcyon_info settings WORDS)")
    key, raw = args[0], " ".join(args[1:])
    if key.startswith("opt:") and re.fullmatch(r"[A-Za-z0-9_]{1,40}", key[4:]):
        try:
            val = json.loads(raw)
        except ValueError:
            val = raw                       # a bare word such as: new, legacy, classic
        island("setopt", key[4:], json.dumps(val))
        return f"set {key} = {json.dumps(val)}"
    if key.startswith("st:") and re.fullmatch(r"[A-Z_]{2,24}", key[3:]):
        code, out = run(["bash", os.path.join(RICE, "scripts", "startup-conf.sh"), "set", key[3:], raw], timeout=20)
        if code != 0:
            raise Fail(out[:200] or "that value was refused")
        return f"set {key} = {raw}" + (" (takes effect at the next login)" if key == "st:GPU" else "")
    raise Fail("only opt:KEY and st:KEY settings can be changed from here (others: open the Settings window)")


def a_gaming(args):
    on = (args[:1] or [""])[0].lower()
    if on not in ("on", "off"):
        raise Fail("usage: gaming on|off")
    island("gamingset", "true" if on == "on" else "false")
    return f"gaming mode {on}"


def a_dnd(args):
    on = (args[:1] or [""])[0].lower()
    if on not in ("on", "off"):
        raise Fail("usage: dnd on|off")
    island("dndset", "true" if on == "on" else "false")
    return f"do not disturb {on}"


def a_profile(args):
    p = (args[:1] or [""])[0]
    if p not in ("work", "gaming", "battery", "night", "custom"):
        raise Fail("usage: profile work|gaming|battery|night|custom")
    return run([sys.executable, os.path.join(HERE, "halcyon-fx.py"), "profile", p], timeout=30)[1] or f"profile {p}"


def a_note(args):
    if not args:
        raise Fail("usage: note add TEXT | del N | done N | pin N | due N WHEN | search WORDS")
    sub, rest = args[0], args[1:]
    if sub == "add" and rest:
        cmd = ["add", " ".join(rest)]
    elif sub in ("del", "done", "pin", "task") and len(rest) == 1 and re.fullmatch(r"[A-Za-z0-9_-]{1,40}", rest[0]):
        cmd = [sub, rest[0]]
    elif sub == "due" and len(rest) >= 2 and re.fullmatch(r"[A-Za-z0-9_-]{1,40}", rest[0]):
        cmd = ["due", rest[0], " ".join(rest[1:])]
    elif sub == "search" and rest:
        cmd = ["search", " ".join(rest)]
    else:
        raise Fail("usage: note add TEXT | del N | done N | pin N | due N WHEN | search WORDS")
    code, out = run([sys.executable, os.path.join(HERE, "halcyon-notes.py"), *cmd], timeout=30)
    if code != 0:
        raise Fail(out[:300])
    return out or "done"


def a_calendar_do(args):
    sub = (args[:1] or [""])[0]
    if sub not in ("sync", "remind"):
        raise Fail("usage: calendar sync | calendar remind 10,0|off")
    p = os.path.join(ISLAND, "scripts", "gcal.py")
    extra = [args[1]] if sub == "remind" and len(args) > 1 and re.fullmatch(r"(off|[0-9]{1,3}(,[0-9]{1,3})*)", args[1]) else []
    if sub == "remind" and not extra:
        raise Fail("usage: calendar remind 10,0|off")
    return run([sys.executable, p, sub, *extra], timeout=90)[1] or "done"


def a_connect_calendar(args):
    """The calendar's private iCal address: Luna keeps nothing, gcal.py stores it (private to you) and syncs."""
    if not args or not re.match(r"^https://", args[0]):
        raise Fail("usage: connect-calendar https://...ics   (Google Calendar > Settings > Integrate calendar > Secret address in iCal format)")
    return run([sys.executable, os.path.join(ISLAND, "scripts", "gcal.py"), "add-url", args[0]], timeout=90)[1] or "connected"


def a_luna_window(args):
    return island("luna") or "toggled the Luna window"


# ============================================================================================= SECURITY (admin rights)
def need_root_tool(name):
    if not shutil.which(name):
        raise Fail(f"{name} is not installed.")


def a_fw_ban(args):
    need_root_tool("ai-firewall")
    ip = arg_safe(args[0] if args else "", "address")
    if not re.fullmatch(r"[0-9a-fA-F:.]{3,45}(/[0-9]{1,3})?", ip):
        raise Fail("that is not an IP address")
    return run(["ai-firewall", "ban", ip], sudo=True, timeout=30)[1] or f"banned {ip}"


def a_fw_unban(args):
    need_root_tool("ai-firewall")
    ip = arg_safe(args[0] if args else "", "address")
    if not re.fullmatch(r"[0-9a-fA-F:.]{3,45}(/[0-9]{1,3})?", ip):
        raise Fail("that is not an IP address")
    return run(["ai-firewall", "unban", ip], sudo=True, timeout=30)[1] or f"lifted the ban on {ip}"


def a_fw_port(args, verb):
    need_root_tool("ai-firewall")
    if len(args) != 2 or args[0] not in ("tcp", "udp") or not re.fullmatch(r"[0-9]{1,5}(-[0-9]{1,5})?", args[1]):
        raise Fail(f"usage: fw-{verb} tcp|udp PORT[-PORT]")
    return run(["ai-firewall", verb, args[0], args[1]], sudo=True, timeout=30)[1] or f"{verb} {args[0]} {args[1]}"


def a_fw_open(args):
    return a_fw_port(args, "open")


def a_fw_close(args):
    return a_fw_port(args, "close")


def a_av_scan(args):
    need_root_tool("ai-antivirus")
    path = os.path.realpath(os.path.expanduser(arg_safe(args[0] if args else "", "path")))
    if not os.path.exists(path):
        raise Fail("no such path")
    code, out = run(["ai-antivirus", "scan", path], timeout=900)
    return clip(out) + ("\n(something was found)" if code == 1 else "")


def a_av_ack(args):
    need_root_tool("ai-antivirus")
    if args == ["all"]:
        return run(["ai-antivirus", "ack", "--all"], sudo=True, timeout=30)[1] or "acknowledged all"
    ids = [arg_safe(x, "alert id") for x in args]
    if not ids or not all(x.isdigit() for x in ids):
        raise Fail("usage: av-ack ID... | av-ack all")
    return run(["ai-antivirus", "ack", *ids], sudo=True, timeout=30)[1] or "acknowledged"


def a_av_exception(args):
    need_root_tool("ai-antivirus")
    if len(args) < 2 or args[0] not in ("add", "remove"):
        raise Fail("usage: av-exception add program|folder PATH [name] | av-exception remove PATH")
    if args[0] == "remove":
        return run(["ai-antivirus", "exceptions", "remove", arg_safe(args[1], "path")], sudo=True, timeout=30)[1] or "removed"
    if len(args) < 3 or args[1] not in ("program", "folder"):
        raise Fail("usage: av-exception add program|folder /absolute/path [name]")
    path = arg_safe(args[2], "path")
    if not os.path.isabs(os.path.expanduser(path)) or path in ("/", "/usr", "/bin", "/etc", "/home", HOME):
        raise Fail("an exception needs one specific absolute path, not a broad folder")
    cmd = ["ai-antivirus", "exceptions", "add", *(["--name", " ".join(args[3:])] if len(args) > 3 else []), args[1], path]
    return run(cmd, sudo=True, timeout=30)[1] or "added"


def a_clam_scan(args):
    folder = args[0] if args else "Downloads"
    try:
        return clip(ai().cmd_clamav(["scan", folder])["text"])
    except Exception as e:
        raise Fail(str(e))


def a_clam_forget(args):
    if len(args) != 1 or not args[0].isdigit():
        raise Fail("usage: clam-forget N  (numbers: halcyon_info clamav exceptions)")
    try:
        return ai().cmd_clamav(["forget", args[0]])["text"]
    except Exception as e:
        raise Fail(str(e))


ACTIONS = {
    "info": {
        "overview": (a_overview, "", "state of the island, gaming mode, AI, GPU, firewall, antivirus, ClamAV, sysmode, notes"),
        "catalog": (a_catalog, "", "every launcher command and window by id (what `do open` accepts)"),
        "docs": (a_docs, "WORDS", "search Halcyon's docs and Settings for an answer, with the setting keys"),
        "settings": (a_settings, "WORDS", "Settings rows that match, their key and current value"),
        "notes": (a_notes, "", "the notes, listed"),
        "calendar": (a_calendar, "", "the next events of the connected calendar"),
        "firewall": (a_firewall, "status|history|feeds|posture", "ai-firewall, read only"),
        "antivirus": (a_antivirus, "status|alerts|actions|exceptions|rules|proposals", "ai-antivirus, read only"),
        "clamav": (a_clamav, "test|exceptions", "does ClamAV work (installed, signatures, updater, EICAR); the exceptions it keeps"),
        "sysmode": (a_sysmode, "", "the current sysmode profile and its checks"),
        "updates": (a_updates, "", "pending pacman updates"),
        "luna": (a_luna_status, "", "is Luna's window ready, how many chats"),
    },
    "do": {
        "open": (a_open, "COMMAND_ID", "open any Halcyon window or run a launcher command by id (closeTop closes the top window)"),
        "set": (a_set, "opt:KEY VALUE", "change a Settings row (opt:KEY) or a Startup setting (st:KEY)"),
        "gaming": (a_gaming, "on|off", "gaming mode"),
        "dnd": (a_dnd, "on|off", "do not disturb"),
        "profile": (a_profile, "work|gaming|battery|night|custom", "the effects profile"),
        "note": (a_note, "add TEXT | del N | done N | pin N | due N WHEN | search WORDS", "the notes"),
        "calendar": (a_calendar_do, "sync | remind 10,0|off", "sync the calendar, or change when reminders fire"),
        "connect-calendar": (a_connect_calendar, "https://...ics", "connect a calendar from its private iCal address (Halcyon stores it for you)"),
        "luna-window": (a_luna_window, "", "toggle the Luna window"),
    },
    "security": {
        "fw-ban": (a_fw_ban, "IP", "ban an address in ai-firewall (admin)"),
        "fw-unban": (a_fw_unban, "IP", "lift a ban (admin)"),
        "fw-open": (a_fw_open, "tcp|udp PORT[-PORT]", "open an inbound port (admin; edits the firewall config)"),
        "fw-close": (a_fw_close, "tcp|udp PORT[-PORT]", "close an inbound port (admin)"),
        "av-scan": (a_av_scan, "PATH", "scan a file or folder with ai-antivirus"),
        "av-ack": (a_av_ack, "ID... | all", "mark ai-antivirus alerts as seen (admin)"),
        "av-exception": (a_av_exception, "add program|folder PATH [name] | remove PATH", "a narrow ai-antivirus exception (admin; never a broad folder)"),
        "clam-scan": (a_clam_scan, "[FOLDER in your home]", "ClamAV scan; the model judges findings and may except false positives"),
        "clam-forget": (a_clam_forget, "N", "remove a ClamAV exception"),
    },
}


def manual():
    """What Luna is told about Halcyon at the start of a session: short, true on every install."""
    lines = [
        "HALCYON (this computer's desktop; you are part of it). Halcyon is a Hyprland desktop built around one floating \"island\" "
        "(bar, launcher, notifications, music, settings in one place), with three parts that work best together: ai-firewall "
        "(eBPF firewall), ai-antivirus (behaviour-based EDR; ClamAV is an optional extra scanner) and you, Luna. Everything is local.",
        "You operate it with three tools, never by guessing shell commands:",
        "- halcyon_info ACTION ARGS: read only. Start with `overview`; then `docs WORDS` for any how-do-I question, `settings WORDS` for a "
        "Settings row and its key, `catalog` for every window/command id, `notes`, `calendar`, `firewall`, `antivirus`, `clamav`, `sysmode`, `updates`.",
        "- halcyon_do ACTION ARGS: changes Halcyon itself: `open ID` (any window or command), `set opt:KEY VALUE`, `gaming on|off`, `dnd on|off`, "
        "`profile NAME`, `note add|del|done|pin|due ...`, `calendar sync`, `connect-calendar URL`. Needs the user's switch (Luna settings > Control Halcyon).",
        "- halcyon_security ACTION ARGS: firewall and antivirus state: `fw-ban IP`, `fw-unban IP`, `fw-open|fw-close tcp PORT`, `av-scan PATH`, "
        "`av-ack`, `av-exception ...`, `clam-scan`, `clam-forget`. Admin rights and the capability gate apply. Use the existing `sysmode` tool for sysmode profiles.",
        "Rules: read first, then act; act only on what the user asked; say what you changed. If a gate refuses, tell the user which switch opens it "
        "(they flip it in Luna settings); never work around a gate with run_shell. Firewall and antivirus changes are only made on an explicit request.",
    ]
    return "\n".join(lines)


def help_text(tier=None):
    out = []
    for t in TIERS:
        if tier and t != tier:
            continue
        out.append(f"[{t}]")
        for name, (_, usage, doc) in ACTIONS[t].items():
            out.append(f"  {name} {usage}".rstrip() + f"\n      {doc}")
    return "\n".join(out)


def main(argv):
    as_json = "--json" in argv
    args = [a for a in argv[1:] if a != "--json"]
    if not args:
        print(__doc__.strip())
        return 2
    if args[0] == "help":
        print(help_text(args[1] if len(args) > 1 else None))
        return 0
    if args[0] == "manual":
        print(manual())
        return 0
    if len(args) < 2 or args[0] not in TIERS:
        print("usage: halcyon-control.py info|do|security ACTION [ARGS...]   (halcyon-control.py help)", file=sys.stderr)
        return 2
    tier, action, rest = args[0], args[1], args[2:]
    try:
        entry = ACTIONS[tier].get(action)
        if entry is None:
            other = [t for t in TIERS if action in ACTIONS[t] and t != tier]
            if other:
                raise Refused(f"'{action}' is a {other[0]} action, not {tier}: use halcyon_{other[0] if other[0] != 'info' else 'info'}")
            raise Fail(f"unknown {tier} action '{action}'. Actions: " + ", ".join(ACTIONS[tier]))
        text = entry[0](rest)
        print(json.dumps({"ok": True, "text": text}) if as_json else text)
        return 0
    except Refused as e:
        print(json.dumps({"ok": False, "error": str(e), "refused": True}) if as_json else str(e), file=sys.stderr if not as_json else sys.stdout)
        return 3
    except Fail as e:
        print(json.dumps({"ok": False, "error": str(e)}) if as_json else str(e), file=sys.stderr if not as_json else sys.stdout)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
