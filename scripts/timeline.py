#!/usr/bin/env python3
"""timeline.py: the numbers behind the timelines in Settings (last wallpaper change, last system update, Focus streak).

  timeline.py conf      one line of JSON (what Settings reads while it is open)
  timeline.py status    the same as plain text, for a terminal

It only READS things that already exist and writes nothing:
  wallpaper   ~/.local/state/island/wallpaper-changed (one epoch number, written by island/scripts/wallpaper.sh each time the
              picture really changes). Before that file exists the date of ~/.local/state/island/wallpaper is used instead
              (wallpaper.sh rewrites that file on every change, so it is the same moment, give or take a re-pick of the same picture).
  update      the last "[ALPM] upgraded" line in /var/log/pacman.log (the last time pacman really replaced a package; an
              "up to date" -Syu does not count). No readable pacman log (not Arch, log rotated away) = unknown, nothing is guessed.
              Halcyon's own update is the date of ~/.local/state/halcyon/installed-commit.
  focus       ~/.local/state/island/focus-days.json (minutes per day, kept by focus-log.sh). A day counts when it reached the
              goal of the Focus widget (Widget builder > Focus timer & streak > "Minutes that count as a focus day"; 25 if there
              is no such widget), the same rule the widget uses: today still to be earned, the streak stands until the day ends.

All "since" numbers are calendar days (a change at 23:50 is "1 day" old at 00:10), -1 = unknown / never.
Test hooks: HOME, XDG_STATE_HOME, TIMELINE_NOW (epoch), HALCYON_PACMAN_LOG (path).
"""
import datetime
import json
import os
import re
import sys

HOME = os.path.expanduser("~")
ISLAND = os.path.join(HOME, ".local/state/island")
FOCUS_DAYS = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local/state"), "island", "focus-days.json")
PACMAN_LOG = os.environ.get("HALCYON_PACMAN_LOG") or "/var/log/pacman.log"
HAL_COMMIT = os.path.join(HOME, ".local/state/halcyon/installed-commit")


def now():
    try:
        return float(os.environ["TIMELINE_NOW"])
    except (KeyError, ValueError):
        return datetime.datetime.now().timestamp()


def day_of(epoch):
    return datetime.datetime.fromtimestamp(epoch).date()


def days_since(epoch):
    """Whole calendar days between that moment and now; -1 when there is no moment."""
    if not epoch or epoch <= 0:
        return -1
    return max(0, (day_of(now()) - day_of(epoch)).days)


def ago(epoch):
    """'never' / 'just now' / '5 min ago' / '3 h ago' / 'yesterday' / '9 days ago' (a short sentence for the detail line)."""
    if not epoch or epoch <= 0:
        return "unknown"
    secs = max(0, now() - epoch)
    d = days_since(epoch)
    if d == 0:
        if secs < 90:
            return "just now"
        if secs < 3600:
            return "%d min ago" % round(secs / 60)
        return "%d h ago" % int(secs // 3600)
    if d == 1:
        return "yesterday"
    return "%d days ago" % d


def stamp_text(epoch):
    if not epoch or epoch <= 0:
        return ""
    return datetime.datetime.fromtimestamp(epoch).strftime("%d %b %Y, %H:%M").lstrip("0")


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def mtime(path):
    try:
        return os.stat(path).st_mtime
    except OSError:
        return 0.0


# ------------------------------------------------------------------------------------------------------------- wallpaper
def wallpaper_epoch():
    try:
        with open(os.path.join(ISLAND, "wallpaper-changed"), encoding="utf-8") as fh:
            v = float(fh.read().strip().split()[0])
        if 0 < v <= now() + 86400:
            return v, "stamp"
    except (OSError, ValueError, IndexError):
        pass
    m = mtime(os.path.join(ISLAND, "wallpaper"))
    return (m, "file") if m > 0 else (0.0, "none")


# ---------------------------------------------------------------------------------------------------------------- update
_ALPM = re.compile(rb"^\[([^\]]+)\] \[ALPM\] upgraded ")
_FULL = re.compile(rb"^\[([^\]]+)\] \[PACMAN\] starting full system upgrade")


def _parse_stamp(raw):
    s = raw.decode("ascii", "ignore").strip()
    for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
        try:
            return datetime.datetime.strptime(s, fmt).timestamp()
        except ValueError:
            continue
    return 0.0


def pacman_epoch(path=None, max_bytes=64 * 1024 * 1024):
    """Time of the last package upgrade in pacman's log, read from the END of the file in chunks (the log can be many MB)."""
    path = path or PACMAN_LOG
    try:
        size = os.path.getsize(path)
        fh = open(path, "rb")
    except OSError:
        return 0.0
    with fh:
        pos, carry, full = size, b"", 0.0
        while pos > 0 and size - pos < max_bytes:
            step = min(1024 * 1024, pos)
            pos -= step
            fh.seek(pos)
            chunk = fh.read(step) + carry
            lines = chunk.split(b"\n")
            carry = lines[0] if pos > 0 else b""
            for line in reversed(lines[1:] if pos > 0 else lines):
                m = _ALPM.match(line)
                if m:
                    t = _parse_stamp(m.group(1))
                    if t > 0:
                        return t
                if not full:
                    m = _FULL.match(line)
                    if m:
                        full = _parse_stamp(m.group(1))
        return full


# ------------------------------------------------------------------------------------------------------------------ focus
def focus_goal():
    st = read_json(os.path.join(ISLAND, "settings.json"))
    try:
        items = st["opt"]["deskWidgets"]["items"]
        pick = [i for i in items if isinstance(i, dict) and i.get("type") == "focus"]
        pick.sort(key=lambda i: bool(i.get("off")))        # a widget that is switched on wins
        g = int(round(float(pick[0]["opts"]["goal"])))
        return max(5, min(180, g))
    except Exception:
        return 25


def focus_stats(goal):
    raw = read_json(FOCUS_DAYS)
    days = {}
    if isinstance(raw, dict):
        for k, v in raw.items():
            try:
                d = datetime.date.fromisoformat(str(k))
                days[d] = max(0, int(v))
            except (ValueError, TypeError):
                continue
    today = day_of(now())
    out = {"focusGoal": goal, "focusTracked": bool(days), "focusToday": days.get(today, 0), "focusStreak": 0, "focusBest": 0,
           "focusLast": -1}
    if not days:
        return out
    hit = sorted(d for d, m in days.items() if m >= goal)
    if hit:
        out["focusLast"] = max(0, (today - hit[-1]).days)
    d = today if days.get(today, 0) >= goal else today - datetime.timedelta(days=1)
    n = 0
    while days.get(d, 0) >= goal and n < 4000:
        n += 1
        d -= datetime.timedelta(days=1)
    out["focusStreak"] = n
    best = run = 0
    prev = None
    for d in hit:
        run = run + 1 if prev is not None and (d - prev).days == 1 else 1
        best = max(best, run)
        prev = d
    out["focusBest"] = max(best, n)
    return out


# ------------------------------------------------------------------------------------------------------------------- main
def collect():
    w, wsrc = wallpaper_epoch()
    u = pacman_epoch()
    h = mtime(HAL_COMMIT)
    out = {
        "wallSince": days_since(w), "wallAgo": ago(w), "wallAt": stamp_text(w), "wallSource": wsrc,
        "updSince": days_since(u), "updAgo": ago(u), "updAt": stamp_text(u), "updSource": "pacman" if u > 0 else "none",
        "halSince": days_since(h), "halAgo": ago(h), "halAt": stamp_text(h),
    }
    out.update(focus_stats(focus_goal()))
    return out


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "conf"
    if cmd == "conf":
        print(json.dumps(collect(), separators=(",", ":")))
        return 0
    if cmd == "status":
        c = collect()
        print("wallpaper changed : %s (%s)" % (c["wallAgo"], c["wallAt"] or "no record"))
        print("system updated    : %s (%s)" % (c["updAgo"], c["updAt"] or "no readable pacman log"))
        print("Halcyon updated   : %s (%s)" % (c["halAgo"], c["halAt"] or "no record"))
        print("focus streak      : %d day(s), best %d, a day counts from %d min, today %d min" % (
            c["focusStreak"], c["focusBest"], c["focusGoal"], c["focusToday"]))
        return 0
    sys.stderr.write("usage: timeline.py conf | status\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
