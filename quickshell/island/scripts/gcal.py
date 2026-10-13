#!/usr/bin/env python3
"""Calendar for the island (>calendar): reads Google Calendar (or any calendar) through its private iCal address.

  gcal.py conf                  one line of JSON: is a calendar set up, when it last synced, the reminder times
  gcal.py add-url URL [NAME] [--replace]   add a calendar (--replace: instead of the ones set up now) (Google: Settings > your calendar > Integrate calendar > Secret address in iCal format)
  gcal.py clear                 forget every calendar and the cached events
  gcal.py remind 10,0           minutes before the start that a notification is sent (0 = at the start); "off" = none
  gcal.py sync                  download every calendar and write the events of the next months to the cache
  gcal.py events                print the cache (JSON)
  gcal.py notify                send the reminders that are due now (the island runs this once a minute)
  gcal.py inspect               what each calendar's feed really contains (counts, titles that say "Busy", to-do items); no secrets printed

Read-only: nothing is ever written to your calendar. Only the standard library is used.
State: ~/.local/state/island/calendar/  (config.json is private to you, events.json is the cache, fired.json = reminders sent)
Not included: Google *Tasks* (the to-do list) is not part of the iCal address, only calendar events are.
"""
import calendar as _cal
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request

try:
    from zoneinfo import ZoneInfo
except Exception:                                   # very old python: only UTC / local times
    ZoneInfo = None

STATE = os.path.join(os.path.expanduser("~"), ".local", "state", "island", "calendar")
CONF = os.path.join(STATE, "config.json")
CACHE = os.path.join(STATE, "events.json")
FIRED = os.path.join(STATE, "fired.json")
BACK_DAYS = 35            # how far back / forward the cache reaches
FORWARD_DAYS = 150
GRACE = 300               # a reminder that was due up to 5 minutes ago still goes out (suspend, a late tick)
LOCAL = dt.datetime.now().astimezone().tzinfo


# ------------------------------------------------------------------ small helpers
def load(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def save(path, data, private=False):
    os.makedirs(STATE, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    if private:
        os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def conf():
    c = load(CONF, {})
    c.setdefault("calendars", [])
    c.setdefault("remind", [10, 0])
    return c


# ------------------------------------------------------------------ ICS parsing
def unfold(text):
    out = []
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if line[:1] in (" ", "\t") and out:
            out[-1] += line[1:]
        else:
            out.append(line)
    return out


def unescape(v):
    return v.replace("\\n", "\n").replace("\\N", "\n").replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\")


def parse_line(line):
    # NAME;PARAM=x;PARAM=y:value   (a ':' inside a quoted parameter is rare enough to ignore)
    if ":" not in line:
        return None
    head, value = line.split(":", 1)
    parts = head.split(";")
    params = {}
    for p in parts[1:]:
        if "=" in p:
            k, v = p.split("=", 1)
            params[k.upper()] = v.strip('"')
    return parts[0].upper(), params, value


def parse_when(value, params):
    """-> (datetime or date, is_all_day)"""
    value = value.strip()
    if params.get("VALUE") == "DATE" or re.fullmatch(r"\d{8}", value):
        return dt.date(int(value[0:4]), int(value[4:6]), int(value[6:8])), True
    m = re.fullmatch(r"(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)", value)
    if not m:
        raise ValueError(value)
    y, mo, d, h, mi, s = (int(m.group(i)) for i in range(1, 7))
    if m.group(7):
        tz = dt.timezone.utc
    else:
        tz = LOCAL
        name = params.get("TZID")
        if name and ZoneInfo:
            try:
                tz = ZoneInfo(name)
            except Exception:
                tz = LOCAL
    return dt.datetime(y, mo, d, h, mi, s, tzinfo=tz), False


def parse_events(text, calname):
    lines = unfold(text)
    raw = []
    cur = None
    for line in lines:
        if line == "BEGIN:VEVENT":
            cur = {"EX": [], "props": {}}
        elif line == "END:VEVENT":
            if cur is not None:
                raw.append(cur)
            cur = None
        elif cur is not None:
            p = parse_line(line)
            if not p:
                continue
            name, params, value = p
            if name == "EXDATE":
                for v in value.split(","):
                    try:
                        cur["EX"].append(parse_when(v, params)[0])
                    except Exception:
                        pass
            else:
                cur["props"].setdefault(name, (params, value))
    return raw


# ------------------------------------------------------------------ recurrence
WD = {"MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6}


def parse_rrule(s):
    r = {}
    for part in s.split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            r[k.upper()] = v
    return r


def nth_weekday_match(d, wd, n):
    """does date d fall on the n-th (negative: from the end) weekday wd of its month?"""
    if d.weekday() != wd:
        return False
    if n > 0:
        return (d.day - 1) // 7 + 1 == n
    last = _cal.monthrange(d.year, d.month)[1]
    return -((last - d.day) // 7 + 1) == n


def rule_matches(d, start, rule):
    freq = rule.get("FREQ", "")
    interval = max(1, int(rule.get("INTERVAL", "1") or 1))
    byday = []
    for tok in rule.get("BYDAY", "").split(","):
        m = re.fullmatch(r"([+-]?\d+)?(MO|TU|WE|TH|FR|SA|SU)", tok.strip())
        if m:
            byday.append((int(m.group(1)) if m.group(1) else 0, WD[m.group(2)]))
    bymd = [int(x) for x in rule.get("BYMONTHDAY", "").split(",") if re.fullmatch(r"-?\d+", x)]
    bymo = [int(x) for x in rule.get("BYMONTH", "").split(",") if x.isdigit()]
    if d < start:
        return False
    if freq == "DAILY":
        if (d - start).days % interval:
            return False
        return (not byday or any(d.weekday() == w for _, w in byday)) and (not bymo or d.month in bymo)
    if freq == "WEEKLY":
        wkst = WD.get(rule.get("WKST", "MO"), 0)
        sw = start - dt.timedelta(days=(start.weekday() - wkst) % 7)
        dw = d - dt.timedelta(days=(d.weekday() - wkst) % 7)
        if ((dw - sw).days // 7) % interval:
            return False
        days = [w for _, w in byday] or [start.weekday()]
        return d.weekday() in days
    if freq == "MONTHLY":
        if ((d.year - start.year) * 12 + d.month - start.month) % interval:
            return False
        if byday:
            return any(nth_weekday_match(d, w, n) if n else d.weekday() == w for n, w in byday)
        last = _cal.monthrange(d.year, d.month)[1]
        wanted = bymd or [start.day]
        return any((x if x > 0 else last + 1 + x) == d.day for x in wanted)
    if freq == "YEARLY":
        if (d.year - start.year) % interval:
            return False
        if d.month not in (bymo or [start.month]):
            return False
        if byday:
            return any(nth_weekday_match(d, w, n) if n else d.weekday() == w for n, w in byday)
        last = _cal.monthrange(d.year, d.month)[1]
        wanted = bymd or [start.day]
        return any((x if x > 0 else last + 1 + x) == d.day for x in wanted)
    return False


def occurrences(start, rrule, until_limit, from_limit):
    """dates (date objects) of a repeating event between from_limit and until_limit"""
    rule = parse_rrule(rrule)
    sd = start.date() if isinstance(start, dt.datetime) else start
    count = int(rule["COUNT"]) if rule.get("COUNT", "").isdigit() else None
    until = None
    if rule.get("UNTIL"):
        try:
            u, _ = parse_when(rule["UNTIL"], {})
            until = u.astimezone(start.tzinfo).date() if isinstance(u, dt.datetime) and isinstance(start, dt.datetime) else (u.date() if isinstance(u, dt.datetime) else u)
        except Exception:
            until = None
    out = []
    n = 0
    d = sd if count else max(sd, from_limit)
    end = min(until_limit, until) if until else until_limit
    while d <= end:
        if rule_matches(d, sd, rule):
            n += 1
            if count and n > count:
                break
            if d >= from_limit:
                out.append(d)
        d += dt.timedelta(days=1)
    return out


# ------------------------------------------------------------------ events -> epoch records
def to_epoch(x, allday):
    if allday:
        return int(dt.datetime(x.year, x.month, x.day, tzinfo=LOCAL).timestamp())
    return int(x.timestamp())


def build(raw, calname, win_from, win_to):
    out = []
    overrides = {}                                   # (uid, original start epoch) -> the changed instance
    plain = []
    for ev in raw:
        p = ev["props"]
        if "RECURRENCE-ID" in p:
            try:
                rid, _ = parse_when(p["RECURRENCE-ID"][1], p["RECURRENCE-ID"][0])
                overrides[(p.get("UID", ("", ""))[1], to_epoch(rid, isinstance(rid, dt.date) and not isinstance(rid, dt.datetime)))] = ev
            except Exception:
                pass
        else:
            plain.append(ev)
    wf = dt.datetime.fromtimestamp(win_from, LOCAL).date()
    wt = dt.datetime.fromtimestamp(win_to, LOCAL).date()

    def emit(ev, start, end, allday, uid):
        p = ev["props"]
        if p.get("STATUS", ("", ""))[1].upper() == "CANCELLED":
            return
        s = to_epoch(start, allday)
        e = to_epoch(end, allday) if end is not None else (s + (86400 if allday else 3600))
        if e <= win_from or s >= win_to:
            return
        out.append({
            "id": hashlib.sha1(("%s|%d" % (uid, s)).encode()).hexdigest()[:16],
            "title": unescape(p.get("SUMMARY", ("", "(no title)"))[1]).strip() or "(no title)",
            "start": s, "end": max(e, s), "allDay": allday,
            "loc": unescape(p.get("LOCATION", ("", ""))[1]).strip(),
            "desc": unescape(p.get("DESCRIPTION", ("", ""))[1]).strip()[:400],
            "cal": calname,
        })

    for ev in plain:
        p = ev["props"]
        try:
            if "DTSTART" not in p:
                continue
            start, allday = parse_when(p["DTSTART"][1], p["DTSTART"][0])
            end = None
            if "DTEND" in p:
                end, _ = parse_when(p["DTEND"][1], p["DTEND"][0])
            elif "DURATION" in p:
                m = re.fullmatch(r"P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?", p["DURATION"][1])
                if m:
                    w, d, h, mi, s = (int(x or 0) for x in m.groups())
                    delta = dt.timedelta(weeks=w, days=d, hours=h, minutes=mi, seconds=s)
                    end = (start + delta) if not allday else (start + dt.timedelta(days=max(1, delta.days)))
            uid = p.get("UID", ("", ""))[1] or str(id(ev))
            if "RRULE" in p:
                length = (end - start) if end is not None else None
                exd = set()
                for x in ev["EX"]:
                    exd.add(x if isinstance(x, dt.date) and not isinstance(x, dt.datetime) else x.astimezone(start.tzinfo).date() if isinstance(start, dt.datetime) else x.date())
                for day in occurrences(start, p["RRULE"][1], wt, wf - dt.timedelta(days=2)):
                    if day in exd:
                        continue
                    if allday:
                        st = day
                    else:
                        st = dt.datetime.combine(day, start.timetz().replace(tzinfo=None), tzinfo=start.tzinfo)
                    key = (uid, to_epoch(st, allday))
                    if key in overrides:
                        continue                    # replaced by the changed instance below
                    en = (st + length) if length is not None else None
                    emit(ev, st, en, allday, uid)
            else:
                emit(ev, start, end, allday, uid)
        except Exception:
            continue

    for (uid, _), ev in overrides.items():
        p = ev["props"]
        try:
            start, allday = parse_when(p["DTSTART"][1], p["DTSTART"][0])
            end = parse_when(p["DTEND"][1], p["DTEND"][0])[0] if "DTEND" in p else None
            emit(ev, start, end, allday, uid + "#mod")
        except Exception:
            continue
    return out


# ------------------------------------------------------------------ commands
def fetch(url):
    url = re.sub(r"^webcal://", "https://", url.strip(), flags=re.I)
    req = urllib.request.Request(url, headers={"User-Agent": "Halcyon-calendar/1"})
    with urllib.request.urlopen(req, timeout=25) as r:
        return r.read().decode("utf-8", "replace")


def cmd_sync():
    c = conf()
    if not c["calendars"]:
        print(json.dumps({"ok": False, "error": "no calendar set up"}))
        return 1
    now = int(dt.datetime.now().timestamp())
    wf, wt = now - BACK_DAYS * 86400, now + FORWARD_DAYS * 86400
    events, errors = [], []
    for cal in c["calendars"]:
        try:
            text = fetch(cal["url"])
            if "BEGIN:VCALENDAR" not in text:
                raise ValueError("that address did not return a calendar")
            events += build(parse_events(text, cal.get("name", "")), cal.get("name", ""), wf, wt)
        except Exception as e:                       # keep going: one broken calendar must not hide the others
            errors.append("%s: %s" % (cal.get("name") or "calendar", str(e)[:120]))
    events.sort(key=lambda e: (e["start"], e["title"]))
    old = load(CACHE, {})
    if errors and not events and old.get("events"):  # offline: keep showing the last good copy
        old["error"] = "; ".join(errors)
        save(CACHE, old)
        print(json.dumps({"ok": False, "error": old["error"]}))
        return 1
    save(CACHE, {"synced": now, "error": "; ".join(errors), "events": events})
    print(json.dumps({"ok": not errors, "events": len(events), "error": "; ".join(errors)}))
    return 0 if not errors else 1


def cmd_conf():
    c = conf()
    cache = load(CACHE, {})
    print(json.dumps({"configured": bool(c["calendars"]), "count": len(c["calendars"]),
                      "names": [x.get("name", "") for x in c["calendars"]],
                      "remind": c["remind"], "synced": cache.get("synced", 0), "error": cache.get("error", "")}))


def address_kind(url):
    if re.search(r"calendar\.google\.com/calendar/ical/.+/public/", url):
        return "public"                     # Google hides every title here: "Busy"
    if re.search(r"calendar\.google\.com/calendar/ical/.+/private-", url):
        return "private"
    return "other"


def cmd_add(url, name="", replace=False):
    if not re.match(r"^(https?|webcal)://", url.strip(), re.I):
        print(json.dumps({"ok": False, "error": "that is not a web address"}))
        return 1
    if address_kind(url) == "public":
        print(json.dumps({"ok": False, "error": "That is the public address: Google hides every event title there (it only says Busy). Copy the Secret address in iCal format instead, the one with private- in it."}))
        return 1
    c = conf()
    if replace:
        c["calendars"] = []                 # fixing a wrong address: the new one takes the place of the old
    url = url.strip()
    if not any(x["url"] == url for x in c["calendars"]):
        c["calendars"].append({"url": url, "name": name or "Calendar %d" % (len(c["calendars"]) + 1)})
    save(CONF, c, private=True)                      # the secret address is a password: only you can read this file
    return cmd_sync()


def cmd_clear():
    for p in (CONF, CACHE, FIRED):
        try:
            os.remove(p)
        except OSError:
            pass
    print(json.dumps({"ok": True}))


def cmd_remind(spec):
    c = conf()
    if spec.strip().lower() in ("off", "none", ""):
        c["remind"] = []
    else:
        c["remind"] = sorted({max(0, min(1440, int(x))) for x in spec.split(",") if x.strip().isdigit()}, reverse=True)
    save(CONF, c, private=True)
    print(json.dumps({"ok": True, "remind": c["remind"]}))


def fmt_time(ts):
    return dt.datetime.fromtimestamp(ts, LOCAL).strftime("%H:%M")


def cmd_notify():
    c = conf()
    offsets = c["remind"]
    cache = load(CACHE, {})
    if not offsets or not cache.get("events"):
        return 0
    now = int(dt.datetime.now().timestamp())
    fired = {k: v for k, v in load(FIRED, {}).items() if v > now - 3 * 86400}
    changed = False
    for ev in cache["events"]:
        if ev["allDay"]:
            # an all-day event: one notification at 08:00 on the day
            times = [(ev["start"] + 8 * 3600, -1)]
        else:
            times = [(ev["start"] - m * 60, m) for m in offsets]
        for due, m in times:
            if not (due <= now < due + GRACE):
                continue
            if not ev["allDay"] and now >= ev["end"] and ev["end"] > ev["start"]:
                continue
            key = "%s:%d" % (ev["id"], m)
            if key in fired:
                continue
            fired[key] = now
            changed = True
            if ev["allDay"]:
                body = "Today"
            elif m <= 0:
                body = "Starting now · %s" % fmt_time(ev["start"])
            else:
                body = "In %d min · %s" % (m, fmt_time(ev["start"])) if m < 60 else "In %s · %s" % ("%d h" % (m // 60) if m % 60 == 0 else "%d min" % m, fmt_time(ev["start"]))
            if ev.get("loc"):
                body += "\n" + ev["loc"]
            try:
                subprocess.Popen(["notify-send", "-a", "Calendar", "-i", "x-office-calendar", "-u", "normal", ev["title"], body],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                pass
    if changed:
        save(FIRED, fired)
    return 0


def cmd_inspect():
    c = conf()
    if not c["calendars"]:
        print("no calendar set up")
        return 1
    for cal in c["calendars"]:
        print("== %s" % (cal.get("name") or "calendar"))
        try:
            text = fetch(cal["url"])
        except Exception as e:
            print("   download failed: %s" % str(e)[:150])
            continue
        lines = unfold(text)
        name = next((l.split(":", 1)[1] for l in lines if l.upper().startswith("X-WR-CALNAME")), "?")
        todos = sum(1 for l in lines if l == "BEGIN:VTODO")
        raw = parse_events(text, "")
        titles = {}
        for ev in raw:
            t = unescape(ev["props"].get("SUMMARY", ("", ""))[1]).strip()
            titles[t] = titles.get(t, 0) + 1
        busy = [ev for ev in raw if unescape(ev["props"].get("SUMMARY", ("", ""))[1]).strip().lower() in ("busy", "")]
        print("   Google calls this calendar: %s" % name)
        print("   address kind: %s" % address_kind(cal["url"]))
        print("   events in the feed: %d   to-do items (VTODO): %d" % (len(raw), todos))
        print("   events whose title is 'Busy' or empty: %d" % len(busy))
        shown = 0
        for ev in busy:
            p = ev["props"]
            if shown >= 5:
                break
            shown += 1
            print("     - %s  class=%s  transp=%s  has-attendees=%s  organizer=%s" % (
                p.get("DTSTART", ("", "?"))[1], p.get("CLASS", ("", "-"))[1], p.get("TRANSP", ("", "-"))[1],
                "ATTENDEE" in p, "yes" if "ORGANIZER" in p else "no"))
        top = sorted(titles.items(), key=lambda kv: -kv[1])[:5]
        print("   most common titles: %s" % ", ".join("%s x%d" % (k or "(empty)", v) for k, v in top))
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 0
    a = argv[1]
    if a == "conf":
        cmd_conf()
    elif a == "add-url" and len(argv) >= 3:
        rest = [x for x in argv[2:] if not x.startswith("--")]
        return cmd_add(rest[0], rest[1] if len(rest) > 1 else "", "--replace" in argv)
    elif a == "clear":
        cmd_clear()
    elif a == "remind" and len(argv) >= 3:
        cmd_remind(argv[2])
    elif a == "sync":
        return cmd_sync()
    elif a == "events":
        print(json.dumps(load(CACHE, {"synced": 0, "error": "", "events": []})))
    elif a == "notify":
        return cmd_notify()
    elif a == "inspect":
        return cmd_inspect()
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
