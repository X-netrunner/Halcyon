#!/usr/bin/env python3
"""weekly-sky.py: your week as a sky. Every focus session, finished task and calendar event is one star.

  weekly-sky.py json   [--offset N]            the week as JSON: stars, constellation lines, dust, totals (what WeeklySky.qml draws)
  weekly-sky.py export [--offset N] [--out D]  write the share picture: weekly-sky-YYYY-Www.svg, and a .png next to it when
                                               rsvg-convert, ImageMagick, inkscape or python-cairosvg is installed; prints JSON
  weekly-sky.py svg    [--offset N] [--out F]  only the SVG (to a file, or to stdout without --out)
  weekly-sky.py status [--offset N]            the totals as one plain line

--offset 0 is this week (Monday 00:00 to the next Monday), -1 last week, -2 the week before ...

Where the stars come from (it only READS these, nothing is written except the exported picture):
  focus    ~/.local/state/island/focus-days.json  minutes per day (focus-log.sh). One star per ~25 minutes of that day, brighter for a
           longer stretch; today's stars are spread up to "now", so the sky fills in as the day goes on.
  task     ~/.local/state/island/sky-events.jsonl  one line each time a note is ticked off (halcyon-notes.py), so the star stays after
           "clear done"; ticking it off again takes the star away. Notes with a `done_at` that are not in the log count too.
  event    ~/.local/state/island/calendar/events.json  the calendar cache (gcal.py): timed events that have already ended. All-day
           events (birthdays, holidays) are not counted.
Nothing is ever invented: no data, no stars (the sky is then just dust, and the picture says so).

Positions are worked out from the time of the event and a hash of it, never from random(), so the same week always draws the same sky.
Test hooks: HOME, XDG_STATE_HOME, XDG_CACHE_HOME, WEEKLY_SKY_NOW (epoch), WEEKLY_SKY_OUT (export folder).
"""
import datetime as dt
import hashlib
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time

FOCUS_STAR_MIN = 25          # one focus star per this many minutes of a day
MAX_FOCUS_PER_DAY = 12
MAX_CHAIN = 10               # stars of one day that get joined by lines
DUST = 70
Y0, YS = 0.22, 0.56          # the band of the picture the stars live in (the heading is above it, the days below)


def home():
    return os.environ.get("HOME") or os.path.expanduser("~")


def state_dir():
    return os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(home(), ".local", "state"), "island")


def cache_dir():
    return os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(home(), ".cache"), "island")


def now():
    try:
        return float(os.environ["WEEKLY_SKY_NOW"])
    except (KeyError, ValueError):
        return time.time()


def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return default


# ------------------------------------------------------------------ the week
def week_bounds(offset=0):
    """(start epoch, end epoch, Monday as a date). Local time; built from dates, so a daylight-saving week is 167 or 169 hours, not wrong."""
    today = dt.datetime.fromtimestamp(now()).date()
    monday = today - dt.timedelta(days=today.weekday()) + dt.timedelta(weeks=int(offset))
    nxt = monday + dt.timedelta(days=7)
    ts = lambda d: dt.datetime.combine(d, dt.time.min).timestamp()
    return ts(monday), ts(nxt), monday


def h01(*parts):
    """Two stable numbers in 0..1 from any parts (the 'random' of the sky: same input, same star)."""
    d = hashlib.sha1("|".join(str(p) for p in parts).encode()).digest()
    return int.from_bytes(d[0:4], "big") / 4294967295.0, int.from_bytes(d[4:8], "big") / 4294967295.0


# ------------------------------------------------------------------ the data
def focus_stars(ws, we, cur):
    days = load_json(os.path.join(state_dir(), "focus-days.json"), {})
    out, minutes = [], 0
    if not isinstance(days, dict):
        return out, 0
    for i in range(7):
        day = dt.datetime.fromtimestamp(ws).date() + dt.timedelta(days=i)
        try:
            m = int(days.get(day.isoformat(), 0))
        except (TypeError, ValueError):
            m = 0
        if m <= 0:
            continue
        d0 = dt.datetime.combine(day, dt.time.min).timestamp()
        if d0 > cur:
            continue                                  # a day that has not started has no stars
        minutes += m
        k = max(1, min(MAX_FOCUS_PER_DAY, int(math.ceil(m / float(FOCUS_STAR_MIN)))))
        lo, hi = d0 + 8 * 3600, min(d0 + 20 * 3600, cur)
        if hi <= lo:                                  # today, before 08:00 (or after a night owl's midnight): spread over what has passed
            lo, hi = d0, max(cur, d0 + 1)
        per = m / float(k)
        for j in range(k):
            t = lo + (j + 0.5) * (hi - lo) / k
            out.append({"t": t, "kind": "focus", "w": max(0.15, min(1.0, per / 50.0)),
                        "label": "Focus, %d min" % int(round(per))})
    return out, minutes


def task_stars(ws, we, cur):
    seen = {}
    try:
        with open(os.path.join(state_dir(), "sky-events.jsonl"), "r", encoding="utf-8") as fh:
            for line in fh:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(e, dict) or not e.get("id"):
                    continue
                if e.get("kind") == "task":
                    seen[e["id"]] = (float(e.get("t", 0)), str(e.get("text", "")))
                elif e.get("kind") == "untask":
                    seen.pop(e["id"], None)
    except OSError:
        pass
    notes = load_json(os.path.join(state_dir(), "notes.json"), [])
    if isinstance(notes, list):
        for n in notes:
            if isinstance(n, dict) and n.get("done") and n.get("done_at") and n.get("id") and n["id"] not in seen:
                try:
                    seen[n["id"]] = (float(n["done_at"]), str(n.get("text", "")))
                except (TypeError, ValueError):
                    pass
    out = []
    for nid, (t, text) in seen.items():
        if ws <= t < we and t <= cur:
            first = (text.strip().splitlines() or [""])[0]
            out.append({"t": t, "kind": "task", "w": 0.55, "label": "Done: " + (first[:48] or "a task"), "id": nid})
    return out


def event_stars(ws, we, cur):
    cache = load_json(os.path.join(state_dir(), "calendar", "events.json"), {})
    evs = cache.get("events") if isinstance(cache, dict) else []
    out = []
    for ev in evs or []:
        try:
            if ev.get("allDay"):
                continue
            s, e = float(ev["start"]), float(ev.get("end", ev["start"]))
        except (KeyError, TypeError, ValueError, AttributeError):
            continue
        if not (ws <= s < we) or e > cur:
            continue                                  # only what has already happened
        dur = max(0.0, e - s)
        out.append({"t": s, "kind": "event", "w": max(0.25, min(0.8, 0.25 + dur / 7200.0 * 0.4)),
                    "label": str(ev.get("title") or "Event")[:48], "id": str(ev.get("id", ""))})
    return out


# ------------------------------------------------------------------ the sky
def build(offset=0):
    ws, we, monday = week_bounds(offset)
    cur = now()
    f, fmin = focus_stars(ws, we, cur)
    raw = f + task_stars(ws, we, cur) + event_stars(ws, we, cur)
    raw.sort(key=lambda s: (s["t"], s["kind"]))
    span = we - ws
    placed = []
    for i, s in enumerate(raw):
        a, b = h01(s["kind"], int(s["t"]), s.get("id", ""), i)
        x = 0.07 + 0.86 * ((s["t"] - ws) / span) + (a - 0.5) * 0.02
        y = Y0 + YS * b
        for _ in range(14):                           # nudge a star that lands on top of another one
            if all(math.hypot((x - p["x"]) * 1.78, y - p["y"]) > 0.045 for p in placed):
                break
            y = Y0 + (((y - Y0) + 0.223) % YS)                # step down the column, wrapping inside the sky band
        placed.append({"x": round(min(0.95, max(0.05, x)), 4), "y": round(y, 4), "kind": s["kind"], "w": round(s["w"], 3),
                       "t": int(s["t"]), "label": s["label"],
                       "day": dt.datetime.fromtimestamp(s["t"]).weekday()})
    # constellation lines: stars of one day are joined in time order; the last star of a day reaches for the first of the next day
    lines = []
    by_day = {}
    for i, s in enumerate(placed):
        by_day.setdefault(s["day"], []).append(i)
    prev_last = None
    for d in sorted(by_day):
        idx = by_day[d]
        chain = idx[:MAX_CHAIN]
        if prev_last is not None:
            lines.append([prev_last, chain[0], 1])
        for a, b in zip(chain, chain[1:]):
            lines.append([a, b, 0])
        prev_last = chain[-1]
    dust = []
    for i in range(DUST):
        a, b = h01("dust", int(ws), i)
        c, d = h01("dust2", int(ws), i)
        dust.append([round(0.02 + 0.96 * a, 4), round(0.04 + 0.84 * b, 4), round(0.6 + 1.6 * c, 2), round(0.12 + 0.34 * d, 2)])
    counts = {"focusMinutes": fmin, "focus": sum(1 for s in placed if s["kind"] == "focus"),
              "tasks": sum(1 for s in placed if s["kind"] == "task"), "events": sum(1 for s in placed if s["kind"] == "event")}
    end_day = monday + dt.timedelta(days=6)
    iso = monday.isocalendar()
    return {
        "offset": int(offset),
        "weekStart": int(ws), "weekEnd": int(we), "now": int(cur),
        "fill": round(max(0.0, min(1.0, (cur - ws) / span)), 4),      # how much of the week has happened: the sky fills in from the left
        "range": "%s – %s" % (monday.strftime("%b %-d"), end_day.strftime("%b %-d")),
        "isoWeek": "%d-W%02d" % (iso[0], iso[1]),
        "stars": placed, "lines": lines, "dust": dust, "counts": counts,
        "summary": summary_line(counts, offset == 0),
    }


def summary_line(c, current=True):
    parts = []
    m = c["focusMinutes"]
    if m:
        parts.append("%s focus" % (("%d h %02d min" % (m // 60, m % 60)) if m >= 60 else ("%d min" % m)))
    if c["tasks"]:
        parts.append("%d task%s done" % (c["tasks"], "" if c["tasks"] == 1 else "s"))
    if c["events"]:
        parts.append("%d event%s" % (c["events"], "" if c["events"] == 1 else "s"))
    return " · ".join(parts) if parts else ("A quiet week so far: no stars yet" if current else "A quiet week: no stars")


# ------------------------------------------------------------------ the picture
def palette():
    p = load_json(os.path.join(cache_dir(), "palette.json"), {})
    g = lambda k, d: p.get(k) if isinstance(p, dict) and isinstance(p.get(k), str) and p.get(k).startswith("#") else d
    return {"bg": g("bg", "#0b0d1a"), "accent": g("accent", "#b9a4ff"), "accent2": g("accent2", "#7ec8ff"), "text": g("text", "#eceaf6"),
            "muted": g("muted", "#8f8da8")}


def esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def sparkle(cx, cy, r, fill, extra=""):
    c = r * 0.16
    rh = r * 0.84
    return ('<path d="M%.1f,%.1f Q%.1f,%.1f %.1f,%.1f Q%.1f,%.1f %.1f,%.1f Q%.1f,%.1f %.1f,%.1f Q%.1f,%.1f %.1f,%.1f Z" fill="%s"%s/>'
            % (cx, cy - r, cx + c, cy - c, cx + rh, cy, cx + c, cy + c, cx, cy + r, cx - c, cy + c, cx - rh, cy, cx - c, cy - c, cx, cy - r, fill, extra))


def svg(sky, W=1600, H=900):
    pal = palette()
    col = {"focus": pal["accent"], "task": pal["accent2"], "event": pal["text"]}
    o = []
    o.append('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="Inter, \'DejaVu Sans\', sans-serif">' % (W, H, W, H))
    o.append('<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="%s"/><stop offset="1" stop-color="#000000" stop-opacity="0.55"/></linearGradient>' % esc(pal["bg"]))
    for k, c in col.items():
        o.append('<radialGradient id="g-%s"><stop offset="0" stop-color="%s" stop-opacity="0.55"/><stop offset="1" stop-color="%s" stop-opacity="0"/></radialGradient>' % (k, esc(c), esc(c)))
    o.append('</defs>')
    o.append('<rect width="%d" height="%d" fill="%s"/><rect width="%d" height="%d" fill="url(#bg)"/>' % (W, H, esc(pal["bg"]), W, H))
    # the days: faint verticals and letters
    names = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
    for i, n in enumerate(names):
        cx = W * (0.07 + 0.86 * (i + 0.5) / 7)
        o.append('<text x="%.1f" y="%.1f" fill="%s" fill-opacity="0.55" font-size="15" letter-spacing="3" text-anchor="middle">%s</text>' % (cx, H * 0.89, esc(pal["muted"]), n))
        if i:
            x = W * (0.07 + 0.86 * i / 7)
            o.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-opacity="0.08"/>' % (x, H * 0.12, x, H * 0.84, esc(pal["text"])))
    for x, y, r, a in sky["dust"]:
        o.append('<circle cx="%.1f" cy="%.1f" r="%.2f" fill="%s" fill-opacity="%.2f"/>' % (x * W, y * H, r, esc(pal["text"]), a))
    st = sky["stars"]
    for a, b, bridge in sky["lines"]:
        o.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-opacity="%s" stroke-width="1.2"%s/>'
                 % (st[a]["x"] * W, st[a]["y"] * H, st[b]["x"] * W, st[b]["y"] * H, esc(pal["text"]),
                    "0.10" if bridge else "0.28", ' stroke-dasharray="3 6"' if bridge else ""))
    for s in st:
        cx, cy, r = s["x"] * W, s["y"] * H, 7 + 15 * s["w"]
        c = col[s["kind"]]
        o.append('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="url(#g-%s)"/>' % (cx, cy, r * 3.2, s["kind"]))
        o.append(sparkle(cx, cy, r, esc(c)))
        o.append('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="#ffffff" fill-opacity="0.9"/>' % (cx, cy, max(1.4, r * 0.18)))
    # heading
    o.append('<text x="%.1f" y="%.1f" fill="%s" font-size="44" font-weight="300" letter-spacing="2">%s</text>' % (W * 0.07, H * 0.085, esc(pal["text"]), "My week in stars" if sky["offset"] == 0 else "A week in stars"))
    o.append('<text x="%.1f" y="%.1f" fill="%s" fill-opacity="0.75" font-size="20" letter-spacing="1">%s  ·  %s</text>' % (W * 0.07, H * 0.085 + 34, esc(pal["muted"]), esc(sky["range"]), esc(sky["summary"])))
    # legend and footer
    lx = W * 0.07
    for k, name in (("focus", "focus session"), ("task", "task done"), ("event", "calendar event")):
        o.append(sparkle(lx, H * 0.955, 8, esc(col[k])))
        o.append('<text x="%.1f" y="%.1f" fill="%s" fill-opacity="0.7" font-size="15">%s</text>' % (lx + 16, H * 0.955 + 5, esc(pal["muted"]), name))
        lx += 190
    o.append('<text x="%.1f" y="%.1f" fill="%s" fill-opacity="0.6" font-size="15" letter-spacing="6" text-anchor="end">HALCYON</text>' % (W * 0.93, H * 0.955 + 5, esc(pal["text"])))
    o.append('</svg>')
    return "\n".join(o)


def pictures_dir():
    if os.environ.get("WEEKLY_SKY_OUT"):
        return os.environ["WEEKLY_SKY_OUT"]
    base = os.path.join(home(), "Pictures")
    try:
        r = subprocess.run(["xdg-user-dir", "PICTURES"], capture_output=True, text=True, timeout=3)
        if r.returncode == 0 and r.stdout.strip() and os.path.isdir(r.stdout.strip()):
            base = r.stdout.strip()
    except Exception:
        pass
    return os.path.join(base, "Halcyon")


def to_png(svg_path, png_path, W=1600):
    """Whichever converter exists. Returns True when png_path was written."""
    tries = []
    if shutil.which("rsvg-convert"):
        tries.append(["rsvg-convert", "-w", str(W), "-o", png_path, svg_path])
    for im in ("magick", "convert"):
        if shutil.which(im):
            tries.append([im, "-background", "none", "-density", "144", svg_path, png_path])
            break
    if shutil.which("inkscape"):
        tries.append(["inkscape", svg_path, "--export-type=png", "--export-filename=" + png_path, "-w", str(W)])
    for cmd in tries:
        try:
            if subprocess.run(cmd, capture_output=True, timeout=60).returncode == 0 and os.path.getsize(png_path) > 0:
                return True
        except Exception:
            pass
    try:
        import cairosvg
        cairosvg.svg2png(url=svg_path, write_to=png_path, output_width=W)
        return os.path.getsize(png_path) > 0
    except Exception:
        return False


def export(sky, out_dir=None):
    out_dir = out_dir or pictures_dir()
    os.makedirs(out_dir, exist_ok=True)
    base = os.path.join(out_dir, "weekly-sky-" + sky["isoWeek"])
    # written to a temp name and moved: an interrupted export never leaves half a picture under the real name
    fd, tmp = tempfile.mkstemp(prefix="sky.", suffix=".svg", dir=out_dir)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(svg(sky))
    os.chmod(tmp, 0o644)                              # mkstemp makes it private; this is a picture meant to be shared
    os.replace(tmp, base + ".svg")
    png = base + ".png"
    ok = to_png(base + ".svg", png)
    if not ok and os.path.exists(png) and os.path.getsize(png) == 0:
        os.remove(png)
    return {"ok": True, "svg": base + ".svg", "png": png if ok else "", "dir": out_dir,
            "note": "" if ok else "No PNG: install librsvg (rsvg-convert), ImageMagick or inkscape for a PNG; the SVG opens in any browser."}


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]
    offset, out = 0, None
    i = 0
    while i < len(rest):
        if rest[i] == "--offset" and i + 1 < len(rest):
            try:
                offset = int(rest[i + 1])
            except ValueError:
                print("--offset needs a whole number (0 = this week, -1 = last week)", file=sys.stderr)
                return 2
            i += 2
        elif rest[i] == "--out" and i + 1 < len(rest):
            out = rest[i + 1]
            i += 2
        else:
            print("unknown option: " + rest[i], file=sys.stderr)
            return 2
    offset = max(-520, min(0, offset))               # never the future, never more than ten years back
    sky = build(offset)
    if cmd == "json":
        print(json.dumps(sky, separators=(",", ":")))
    elif cmd == "status":
        print("%s: %s" % (sky["range"], sky["summary"]))
    elif cmd == "svg":
        if out:
            with open(out, "w", encoding="utf-8") as fh:
                fh.write(svg(sky))
        else:
            print(svg(sky))
    elif cmd == "export":
        try:
            print(json.dumps(export(sky, out)))
        except OSError as e:
            print(json.dumps({"ok": False, "error": "Could not write the picture: %s" % e.strerror}))
            return 1
    else:
        print("unknown command: " + cmd, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
