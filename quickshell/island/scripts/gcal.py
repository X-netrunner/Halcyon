#!/usr/bin/env python3
"""Calendar for the island (>calendar): reads Google Calendar (or any calendar) through its private iCal address.

  gcal.py conf                  one line of JSON: is a calendar set up, when it last synced, the reminder times
  gcal.py add-url URL [NAME] [--replace]   add a calendar (--replace: instead of the ones set up now) (Google: Settings > your calendar > Integrate calendar > Secret address in iCal format)
  gcal.py clear                 forget every calendar and the cached events
  gcal.py remind 10,0           minutes before the start that a notification is sent (0 = at the start); "off" = none
  gcal.py sync                  download every calendar and write the events of the next months to the cache
  gcal.py events                print the cache (JSON)
  gcal.py notify [flags]        the once-a-minute worker (the island runs it): reminders, nagging, auto Focus mode. Flags:
                                  --no-remind  --nag EVERY_MIN  --giveup MIN  --focus  --all-tasks
  gcal.py done ID | undone ID   mark an event as finished (stops the nagging); stored here only, never sent to Google
  gcal.py task ID on|off        mark an event as a task (nagged / auto Focus when those are on)
  gcal.py import-birthdays [FILE]   contacts .vcf (Google: contacts.google.com > Export > vCard) -> the managed block in ~/.config/Halcyon/birthdays.txt; no FILE = newest .vcf in Downloads
  gcal.py inspect               what each calendar's feed really contains (counts, titles that say "Busy", to-do items); no secrets printed

Read-only: nothing is ever written to your calendar. Only the standard library is used.
State: ~/.local/state/island/calendar/  (config.json is private to you, events.json is the cache, fired.json = reminders sent)
Not included: Google *Tasks* (the to-do list) is not part of the iCal address, only calendar events are.
"""
import calendar as _cal
import csv
import datetime as dt
import io
import urllib.parse
import zipfile
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
DONE = os.path.join(STATE, "done.json")            # event id -> when it was marked done
TASKS = os.path.join(STATE, "tasks.json")          # event id -> true: events you marked as tasks
NAGGED = os.path.join(STATE, "nagged.json")        # event id -> when the last nag went out
AUTOFOCUS = os.path.join(STATE, "autofocus.json")  # {"fired": {id: ts}, "active": id, "end": ts}
BIRTHDAYS_JSON = os.path.join(STATE, "birthdays.json")
BIRTHDAYS_FILE = os.path.join(os.path.expanduser("~"), ".config", "Halcyon", "birthdays.txt")
HOLIDAYS_JSON = os.path.join(STATE, "holidays.json")
HOLIDAYS_FILE = os.path.join(os.path.expanduser("~"), ".config", "Halcyon", "holidays.txt")
SELF = os.path.abspath(__file__)
FOCUS_SH = os.path.join(os.path.expanduser("~"), ".config", "Halcyon", "scripts", "focus.sh")
BACK_DAYS = 35            # how far back / forward the cache reaches
FORWARD_DAYS = 150
MAX_FEED = 25 * 1048576   # biggest calendar feed that is read
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
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    tmp = path + ".tmp"
    # the file is CREATED with the right mode. It used to be written with the default one (readable by everyone) and chmod-ed
    # afterwards, so the secret calendar address sat world-readable for a moment, and for good if the chmod never ran.
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600 if private else 0o644)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    if private:
        os.chmod(tmp, 0o600)                         # a leftover .tmp from an older run may have had another mode
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
        if line in ("BEGIN:VEVENT", "BEGIN:VTODO"):
            cur = {"EX": [], "props": {}, "is_todo": (line == "BEGIN:VTODO")}
        elif line in ("END:VEVENT", "END:VTODO"):
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
            "desc": unescape(p.get("DESCRIPTION", ("", ""))[1]).strip()[:4000],
            "cal": calname,
        })

    for ev in plain:
        p = ev["props"]
        try:
            if "DTSTART" not in p and "DUE" in p:
                p["DTSTART"] = p["DUE"]
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
    url = url.strip()
    if url.startswith("file://") or (url.startswith("/") and os.path.isfile(url)):
        fp = url.replace("file://", "")
        with open(fp, "r", encoding="utf-8", errors="replace") as f:
            return f.read(MAX_FEED)
    url = re.sub(r"^webcal://", "https://", url, flags=re.I)
    if not re.match(r"^https://", url, re.I):         # the address is a password: never send it unencrypted
        raise ValueError("only https:// calendar addresses are accepted")
    ua = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Halcyon-calendar/1"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": ua})
        with urllib.request.urlopen(req, timeout=25) as r:
            data = r.read(MAX_FEED + 1)                   # a feed is a few hundred KB; do not read an endless stream into memory
        if len(data) > MAX_FEED:
            raise ValueError("the calendar feed is larger than %d MB" % (MAX_FEED // 1048576))
        return data.decode("utf-8", "replace")
    except Exception as urllib_err:
        try:
            res = subprocess.run(["curl", "-sSL", "--max-time", "25", "-A", ua, url],
                                 capture_output=True, timeout=30)
            if res.returncode == 0 and res.stdout:
                if len(res.stdout) > MAX_FEED:
                    raise ValueError("the calendar feed is larger than %d MB" % (MAX_FEED // 1048576))
                return res.stdout.decode("utf-8", "replace")
        except Exception:
            pass
        raise urllib_err


TIMEZONE_REGIONS = {
    "Asia/Kolkata": ("India", "indian"),
    "Asia/Calcutta": ("India", "indian"),
    "America/New_York": ("United States", "usa"),
    "America/Chicago": ("United States", "usa"),
    "America/Denver": ("United States", "usa"),
    "America/Los_Angeles": ("United States", "usa"),
    "America/Phoenix": ("United States", "usa"),
    "Europe/London": ("United Kingdom", "uk"),
    "America/Toronto": ("Canada", "canadian"),
    "America/Vancouver": ("Canada", "canadian"),
    "America/Montreal": ("Canada", "canadian"),
    "Australia/Sydney": ("Australia", "australian"),
    "Australia/Melbourne": ("Australia", "australian"),
    "Australia/Brisbane": ("Australia", "australian"),
    "Australia/Perth": ("Australia", "australian"),
    "Europe/Berlin": ("Germany", "german"),
    "Europe/Paris": ("France", "french"),
    "Asia/Tokyo": ("Japan", "japanese"),
    "Asia/Singapore": ("Singapore", "singapore"),
    "Europe/Rome": ("Italy", "italian"),
    "Europe/Madrid": ("Spain", "spain"),
    "America/Sao_Paulo": ("Brazil", "brazilian"),
    "America/Mexico_City": ("Mexico", "mexican"),
    "Europe/Amsterdam": ("Netherlands", "dutch"),
    "Asia/Seoul": ("South Korea", "south_korea"),
    "Asia/Dubai": ("United Arab Emirates", "united_arab_emirates"),
    "Europe/Zurich": ("Switzerland", "switzerland"),
    "Europe/Stockholm": ("Sweden", "swedish"),
    "Europe/Oslo": ("Norway", "norwegian"),
    "Europe/Helsinki": ("Finland", "finnish"),
    "Europe/Warsaw": ("Poland", "polish"),
    "Europe/Vienna": ("Austria", "austrian"),
    "Europe/Brussels": ("Belgium", "belgian"),
    "Europe/Dublin": ("Ireland", "irish"),
    "Pacific/Auckland": ("New Zealand", "new_zealand"),
}


def detect_system_region():
    tz = ""
    try:
        if os.path.islink("/etc/localtime"):
            target = os.readlink("/etc/localtime")
            parts = target.split("zoneinfo/")
            if len(parts) > 1:
                tz = parts[1]
    except Exception:
        pass
    if not tz:
        try:
            res = subprocess.run(["timedatectl", "show", "-p", "Timezone", "--value"], capture_output=True, text=True, timeout=5)
            if res.returncode == 0 and res.stdout.strip():
                tz = res.stdout.strip()
        except Exception:
            pass
    if not tz and os.path.isfile("/etc/timezone"):
        try:
            with open("/etc/timezone") as f:
                tz = f.read().strip()
        except Exception:
            pass

    country, code = TIMEZONE_REGIONS.get(tz, ("India", "indian"))
    if tz and tz not in TIMEZONE_REGIONS:
        if tz.startswith("America/"):
            country, code = "United States", "usa"
        elif tz.startswith("Australia/"):
            country, code = "Australia", "australian"
        elif tz.startswith("Europe/"):
            country, code = "United Kingdom", "uk"
        elif tz.startswith("Asia/"):
            country, code = "India", "indian"

    url = f"https://calendar.google.com/calendar/ical/en.{code}%23holiday%40group.v.calendar.google.com/public/basic.ics"
    return {"timezone": tz, "country": country, "code": code, "url": url}


def load_birthday_events(win_from, win_to):
    events = []
    b_list = []
    bj = load(BIRTHDAYS_JSON, [])
    if isinstance(bj, list):
        b_list.extend(bj)

    if os.path.isfile(BIRTHDAYS_FILE):
        try:
            with open(BIRTHDAYS_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    m = re.match(r"^(\d{1,2})[-/](\d{1,2})\s+([^(]+)(?:\((\d{4})\))?", line)
                    if m:
                        b_list.append({"name": m.group(3).strip(), "month": int(m.group(1)), "day": int(m.group(2)), "year": int(m.group(4)) if m.group(4) else None})
                    else:
                        m2 = re.match(r"^(\d{4})[-/](\d{1,2})[-/](\d{1,2})\s+(.+)", line)
                        if m2:
                            b_list.append({"name": m2.group(4).strip(), "year": int(m2.group(1)), "month": int(m2.group(2)), "day": int(m2.group(3))})
        except Exception:
            pass

    wf_date = dt.datetime.fromtimestamp(win_from, LOCAL).date()
    wt_date = dt.datetime.fromtimestamp(win_to, LOCAL).date()

    # the same person from birthdays.json and birthdays.txt (or two imports) shows once; later entries win
    seen = {}
    for b in b_list:
        seen[(str(b.get("name", "")).strip().lower(), b.get("month"), b.get("day"))] = b
    b_list = list(seen.values())

    for b in b_list:
        name = b.get("name", "").strip()
        mo = b.get("month", 1)
        day = b.get("day", 1)
        birth_year = b.get("year")
        if not name:
            continue
        for y in range(wf_date.year - 1, wt_date.year + 2):
            try:
                if mo == 2 and day == 29 and not _cal.isleap(y):
                    d = dt.date(y, 2, 28)
                else:
                    d = dt.date(y, mo, day)
            except Exception:
                continue

            s = int(dt.datetime(d.year, d.month, d.day, tzinfo=LOCAL).timestamp())
            e = s + 86400
            if e <= win_from or s >= win_to:
                continue

            age_str = ""
            if birth_year and 1900 <= birth_year < y:
                age = y - birth_year
                suffix = "th" if 11 <= (age % 100) <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(age % 10, "th")
                age_str = f" ({age}{suffix})"

            title = f"{name}'s Birthday{age_str}"
            uid = f"birthday-{name}-{mo}-{day}"
            events.append({
                "id": hashlib.sha1(f"{uid}|{s}".encode()).hexdigest()[:16],
                "title": title,
                "start": s,
                "end": e,
                "allDay": True,
                "loc": "",
                "desc": f"Birthday celebration for {name}" + (f" (Born {birth_year})" if birth_year else ""),
                "cal": "Birthdays",
            })
    return events


def load_holiday_events(win_from, win_to):
    events = []
    h_list = []
    hj = load(HOLIDAYS_JSON, [])
    if isinstance(hj, list):
        h_list.extend(hj)

    if os.path.isfile(HOLIDAYS_FILE):
        try:
            with open(HOLIDAYS_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    m = re.match(r"^(\d{1,2})[-/](\d{1,2})\s+(.+)", line)
                    if m:
                        h_list.append({"name": m.group(3).strip(), "month": int(m.group(1)), "day": int(m.group(2))})
                    else:
                        m2 = re.match(r"^(\d{4})[-/](\d{1,2})[-/](\d{1,2})\s+(.+)", line)
                        if m2:
                            h_list.append({"name": m2.group(4).strip(), "year": int(m2.group(1)), "month": int(m2.group(2)), "day": int(m2.group(3))})
        except Exception:
            pass

    wf_date = dt.datetime.fromtimestamp(win_from, LOCAL).date()
    wt_date = dt.datetime.fromtimestamp(win_to, LOCAL).date()

    for h in h_list:
        name = h.get("name", "").strip()
        mo = h.get("month", 1)
        day = h.get("day", 1)
        spec_year = h.get("year")
        if not name:
            continue
        years = [spec_year] if spec_year else range(wf_date.year - 1, wt_date.year + 2)
        for y in years:
            try:
                if mo == 2 and day == 29 and not _cal.isleap(y):
                    d = dt.date(y, 2, 28)
                else:
                    d = dt.date(y, mo, day)
            except Exception:
                continue

            s = int(dt.datetime(d.year, d.month, d.day, tzinfo=LOCAL).timestamp())
            e = s + 86400
            if e <= win_from or s >= win_to:
                continue

            title = f"{name}"
            uid = f"holiday-{name}-{mo}-{day}"
            events.append({
                "id": hashlib.sha1(f"{uid}|{s}".encode()).hexdigest()[:16],
                "title": title,
                "start": s,
                "end": e,
                "allDay": True,
                "loc": "",
                "desc": f"Holiday: {name}",
                "cal": "Holidays",
            })
    return events


def _vcf_unquote(value, params):
    """Decode a vCard 2.1 QUOTED-PRINTABLE value (old Android / Outlook exports)."""
    if "QUOTED-PRINTABLE" in params.upper():
        import quopri
        try:
            return quopri.decodestring(value.encode("latin-1", "replace")).decode("utf-8", "replace")
        except Exception:
            return value
    return value


def parse_vcf(text):
    """Contacts with a birthday -> [{name, year|None, month, day}]. Handles folded lines, Google/Apple/Outlook BDAY styles."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"=\n(?=[ \t]*[^:\n]*=)", "", text)           # 2.1 soft line breaks inside quoted-printable values
    text = re.sub(r"\n[ \t]", "", text)                           # RFC 6350 folded lines
    birthdays = []
    for card in re.findall(r"BEGIN:VCARD.*?END:VCARD", text, re.DOTALL | re.IGNORECASE):
        fn, n_name, bday = "", "", ""
        for line in card.split("\n"):
            if ":" not in line:
                continue
            head, value = line.split(":", 1)
            head = head.split(".", 1)[-1] if "." in head.split(";", 1)[0] else head   # item1.BDAY -> BDAY
            key, _, params = head.partition(";")
            key = key.strip().upper()
            value = _vcf_unquote(value.strip(), params)
            if key == "FN":
                fn = value
            elif key == "N" and not n_name:
                parts = [x.strip() for x in value.split(";")]
                n_name = " ".join(x for x in (parts[3] if len(parts) > 3 else "", parts[1] if len(parts) > 1 else "",
                                              parts[2] if len(parts) > 2 else "", parts[0], parts[4] if len(parts) > 4 else "") if x)
            elif key == "BDAY":
                bday = value
        name = (fn or n_name).replace("\\,", ",").strip()
        if not name or not bday:
            continue
        m = re.search(r"(\d{4})-?(\d{2})-?(\d{2})", bday)
        year = None
        if m:
            year, mo, day = int(m.group(1)), int(m.group(2)), int(m.group(3))
            if year < 1900:                                       # 1604 / 0000 / 1900 are what apps store for "no year"
                year = None
        else:
            m = re.search(r"--(\d{2})-?(\d{2})", bday)
            if not m:
                continue
            mo, day = int(m.group(1)), int(m.group(2))
        if 1 <= mo <= 12 and 1 <= day <= 31:
            birthdays.append({"name": name, "year": year, "month": mo, "day": day})
    return birthdays


def cmd_sync():
    c = conf()
    now = int(dt.datetime.now().timestamp())
    wf, wt = now - BACK_DAYS * 86400, now + FORWARD_DAYS * 86400
    events, errors = [], []
    for cal in c.get("calendars", []):
        try:
            text = fetch(cal["url"])
            if "BEGIN:VCALENDAR" not in text:
                raise ValueError("that address did not return a calendar")
            events += build(parse_events(text, cal.get("name", "")), cal.get("name", ""), wf, wt)
        except Exception as e:                       # keep going: one broken calendar must not hide the others
            errors.append("%s: %s" % (cal.get("name") or "calendar", str(e)[:120]))
    try:
        events += load_birthday_events(wf, wt)
    except Exception as be:
        errors.append("birthdays: %s" % str(be)[:100])
    try:
        events += load_holiday_events(wf, wt)
    except Exception as he:
        errors.append("holidays: %s" % str(he)[:100])

    if not c.get("calendars") and not events:
        print(json.dumps({"ok": False, "error": "no calendar, holidays or birthdays set up"}))
        return 1

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
    has_birthdays = os.path.isfile(BIRTHDAYS_FILE) or bool(load(BIRTHDAYS_JSON, []))
    has_holidays = os.path.isfile(HOLIDAYS_FILE) or bool(load(HOLIDAYS_JSON, []))
    configured = bool(c["calendars"]) or has_birthdays or has_holidays
    print(json.dumps({"configured": configured, "count": len(c["calendars"]),
                      "names": [x.get("name", "") for x in c["calendars"]],
                      "has_holidays": has_holidays,
                      "has_birthdays": has_birthdays,
                      "remind": c["remind"], "synced": cache.get("synced", 0), "error": cache.get("error", "")}))


def address_kind(url):
    if re.search(r"calendar\.google\.com/calendar/ical/.+/public/", url):
        return "public"
    if re.search(r"calendar\.google\.com/calendar/ical/.+/private-", url):
        return "private"
    return "other"


def cmd_add(url, name="", replace=False):
    url = url.strip()
    if not re.match(r"^(https|webcal)://", url, re.I):
        print(json.dumps({"ok": False, "error": "that is not a secure web address (it has to start with https:// or webcal://)"}))
        return 1

    # Fetch feed first to validate and extract metadata (name, holiday/birthday detection)
    try:
        text = fetch(url)
        if "BEGIN:VCALENDAR" not in text:
            print(json.dumps({"ok": False, "error": "That address did not return a valid calendar feed."}))
            return 1
    except Exception as e:
        print(json.dumps({"ok": False, "error": "Could not download calendar: %s" % str(e)[:120]}))
        return 1

    # Automatically extract calendar name from feed header if not explicitly given
    if not name:
        m = re.search(r"^X-WR-CALNAME:(.+)$", text, re.M)
        if m:
            detected = unescape(m.group(1).strip())
            if detected:
                name = detected

    # Only reject public links if Google is actively hiding all event titles as "Busy"
    # Public holiday and birthday feeds contain actual event titles, so they pass.
    raw_evs = parse_events(text, name or "Calendar")
    busy_count = 0
    total_evs = 0
    for ev in raw_evs:
        p = ev.get("props", {})
        if "SUMMARY" in p:
            total_evs += 1
            if p["SUMMARY"][1].strip().lower() == "busy":
                busy_count += 1
    if total_evs >= 3 and busy_count == total_evs:
        print(json.dumps({"ok": False, "error": "Google hides every title on this public address (all events say 'Busy'). For personal calendars, copy the 'Secret address in iCal format' instead."}))
        return 1

    c = conf()
    if replace:
        c["calendars"] = []                 # fixing a wrong address: the new one takes the place of the old

    final_name = name or ("Calendar %d" % (len(c["calendars"]) + 1))
    found = False
    for x in c["calendars"]:
        if x.get("url") == url:
            x["name"] = final_name
            found = True
            break
    if not found:
        c["calendars"].append({"url": url, "name": final_name})

    save(CONF, c, private=True)
    return cmd_sync()


def cmd_clear():
    for p in (CONF, CACHE, FIRED, DONE, TASKS, NAGGED, AUTOFOCUS):
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


def send(title, body, ev_id=None, urgent=False):
    """A notification from \"Calendar\". With an ev_id it gets a Done button: a tiny `sh` waits for the click (notify-send -A
    waits), then marks the event done. Without a click it just ends when the notification is closed."""
    base = ["notify-send", "-a", "Calendar", "-i", "x-office-calendar", "-u", "critical" if urgent else "normal"]
    try:
        if ev_id:
            script = ('a=$("$@" 2>/dev/null); [ "$a" = done ] && python3 "$SELF" done "$ID"')
            env = dict(os.environ, SELF=SELF, ID=ev_id)
            subprocess.Popen(["sh", "-c", script, "sh"] + base + ["-A", "done=Done", "-w", title, body], env=env,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        else:
            subprocess.Popen(base + [title, body], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def focus_status():
    try:
        r = subprocess.run(["bash", FOCUS_SH, "status"], capture_output=True, text=True, timeout=6)
        return json.loads(r.stdout or "{}")
    except Exception:
        return {}


def emit_next(flags, nxt):
    """--next: print when this worker next has anything to do ({"next": unix seconds, 0 = nothing planned), so the island can
    sleep until then instead of starting Python every minute."""
    if "--next" in flags:
        print(json.dumps({"ok": True, "next": min(nxt) if nxt else 0}))


def cmd_notify(flags):
    c = conf()
    cache = load(CACHE, {})
    events = cache.get("events") or []
    if not events:
        emit_next(flags, [])
        return 0
    remind_on = "--no-remind" not in flags
    nag_every = int(flags[flags.index("--nag") + 1]) * 60 if "--nag" in flags else 0
    giveup = int(flags[flags.index("--giveup") + 1]) * 60 if "--giveup" in flags else 10800
    auto_focus = "--focus" in flags
    all_tasks = "--all-tasks" in flags
    offsets = c["remind"] if remind_on else []
    now = int(dt.datetime.now().timestamp())
    done = load(DONE, {})
    tasks = load(TASKS, {})
    fired = {k: v for k, v in load(FIRED, {}).items() if v > now - 3 * 86400}
    nagged = {k: v for k, v in load(NAGGED, {}).items() if v > now - 4 * 86400}
    changed = False
    nag_changed = False

    def is_task(ev):
        return all_tasks or bool(tasks.get(ev["id"]))

    for ev in events:
        task = is_task(ev)
        finished = ev["id"] in done
        # ---- reminders
        if offsets and not finished:
            times = [(ev["start"] + 8 * 3600, -1)] if ev["allDay"] else [(ev["start"] - m * 60, m) for m in offsets]
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
                send(ev["title"], body, ev["id"] if task else None)
        # ---- nagging: from the start until it is marked done (or the give-up time after its end)
        if nag_every and task and not finished and not ev["allDay"]:
            end = max(ev["end"], ev["start"])
            if ev["start"] + nag_every <= now < end + giveup:
                last = nagged.get(ev["id"], ev["start"])
                if now - last >= nag_every:
                    nagged[ev["id"]] = now
                    nag_changed = True
                    # the text never changes, so each nag replaces the one before it in the notification centre
                    send("Not done yet: " + ev["title"], "Started at %s. Press Done when you have finished it." % fmt_time(ev["start"]), ev["id"], urgent=True)
    if changed:
        save(FIRED, fired)
    if nag_changed:
        save(NAGGED, nagged)

    # ---- auto Focus mode: a Focus session for the length of a task that is running now
    af = load(AUTOFOCUS, {"fired": {}})
    af["fired"] = {k: v for k, v in af.get("fired", {}).items() if v > now - 3 * 86400}
    dirty = False
    if af.get("active"):
        gone = af["active"] in done or now >= af.get("end", 0)
        if gone:
            if af["active"] in done and now < af.get("end", 0):
                subprocess.run(["bash", FOCUS_SH, "stop"], capture_output=True, timeout=8)     # finished early: end the session too
            af.pop("active", None); af.pop("end", None); dirty = True
    if auto_focus and not af.get("active"):
        for ev in events:
            if ev["allDay"] or ev["id"] in done or not is_task(ev) or ev["id"] in af["fired"]:
                continue
            if not (ev["start"] <= now < ev["end"]) or ev["end"] - ev["start"] < 600:
                continue
            if focus_status().get("on"):
                break                                    # you already run a session: leave it alone
            mins = max(1, min(480, -(-(ev["end"] - now) // 60)))
            subprocess.run(["bash", FOCUS_SH, "start", str(mins), "single"], capture_output=True, timeout=10)
            af["fired"][ev["id"]] = now
            af["active"], af["end"] = ev["id"], ev["end"]
            dirty = True
            if remind_on:
                send("Focus mode on", "%s · until %s" % (ev["title"], fmt_time(ev["end"])))
            break
    if dirty:
        save(AUTOFOCUS, af)

    # ---- the next moment anything above can fire (reminder, nag, auto Focus start / end)
    if "--next" in flags:
        nxt = []
        for ev in events:
            if ev["id"] in done:
                continue
            task = is_task(ev)
            if offsets:
                times = [(ev["start"] + 8 * 3600, -1)] if ev["allDay"] else [(ev["start"] - m * 60, m) for m in offsets]
                nxt.extend(due for due, _m in times if due > now)
            if nag_every and task and not ev["allDay"]:
                end = max(ev["end"], ev["start"])
                if now < end + giveup:
                    t = ev["start"] + nag_every
                    if ev["id"] in nagged:
                        t = max(t, nagged[ev["id"]] + nag_every)
                    nxt.append(max(t, now + 1))
        if af.get("active"):
            nxt.append(af.get("end", 0))
        elif auto_focus:
            for ev in events:
                if ev["allDay"] or ev["id"] in done or not is_task(ev) or ev["id"] in af["fired"]:
                    continue
                if ev["end"] - ev["start"] < 600 or ev["end"] <= now:
                    continue
                nxt.append(ev["start"] if ev["start"] > now else now + 60)    # running now but a session is on: look again soon
        emit_next(flags, [t for t in nxt if t > now])
    return 0


def cmd_done(ev_id, on=True):
    d = load(DONE, {})
    if on:
        d[ev_id] = int(dt.datetime.now().timestamp())
    else:
        d.pop(ev_id, None)
    save(DONE, d)
    print(json.dumps({"ok": True}))


def cmd_task(ev_id, on):
    t = load(TASKS, {})
    if on:
        t[ev_id] = True
    else:
        t.pop(ev_id, None)
    save(TASKS, t)
    print(json.dumps({"ok": True}))


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


def cmd_detect_region():
    r = detect_system_region()
    print(json.dumps({"ok": True, "region": r}))
    return 0


def cmd_add_holidays(code=None):
    reg = detect_system_region()
    target_code = (code or reg["code"]).lower().strip()
    target_country = reg["country"]
    for tz_k, (c_name, c_code) in TIMEZONE_REGIONS.items():
        if c_code.lower() == target_code:
            target_country = c_name
            break
    url = f"https://calendar.google.com/calendar/ical/en.{target_code}%23holiday%40group.v.calendar.google.com/public/basic.ics"
    cal_name = f"Holidays ({target_country})"

    c = conf()
    exists = False
    for item in c.setdefault("calendars", []):
        if target_code in item.get("url", "") or "holiday" in item.get("name", "").lower():
            item["url"] = url
            item["name"] = cal_name
            exists = True
            break
    if not exists:
        c["calendars"].append({"url": url, "name": cal_name})
    save(CONF, c, private=True)
    res = cmd_sync()
    print(json.dumps({"ok": res == 0, "country": target_country, "code": target_code, "name": cal_name, "url": url}))
    return res


def cmd_add_birthday(name, date_str, year=None):
    name = name.strip()
    m = re.match(r"^(\d{4})?[-/]?(\d{1,2})[-/](\d{1,2})$", date_str)
    if not m:
        print(json.dumps({"ok": False, "error": "Invalid date format. Use MM-DD (e.g. 05-12) or YYYY-MM-DD"}))
        return 1
    yr = int(m.group(1)) if m.group(1) else (int(year) if year else None)
    mo = int(m.group(2))
    day = int(m.group(3))

    bj = load(BIRTHDAYS_JSON, [])
    updated = False
    for b in bj:
        if b.get("name", "").lower() == name.lower():
            b["month"] = mo
            b["day"] = day
            b["year"] = yr
            updated = True
            break
    if not updated:
        bj.append({"name": name, "month": mo, "day": day, "year": yr})
    save(BIRTHDAYS_JSON, bj)
    import io as _io
    old_stdout = sys.stdout
    try:
        sys.stdout = _io.StringIO()
        cmd_sync()
    finally:
        sys.stdout = old_stdout
    print(json.dumps({"ok": True, "name": name, "month": mo, "day": day, "year": yr}))
    return 0


IMPORT_BEGIN = "# >>> imported from contacts (managed by Halcyon: importing again replaces everything up to the end marker) >>>"
IMPORT_END = "# <<< end of imported contacts <<<"


def _valid_md(mo, da):
    """A real calendar day: 02-30 and 04-31 are rejected (they used to be saved and then never shown), 02-29 is kept."""
    return 1 <= mo <= 12 and 1 <= da <= _cal.monthrange(2024, mo)[1]


def parse_bday_date_any(raw):
    """Parses any date format from Google Contacts CSV, Outlook CSV, Apple/Android vCard:
    YYYY-MM-DD, --MM-DD, MM/DD/YYYY, DD/MM/YYYY, MM-DD, 'Oct 14, 1998', '14 October' -> (year|None, month, day) or None."""
    if not raw:
        return None
    s = str(raw).strip()
    m = re.search(r"(\d{4})[-/](\d{1,2})[-/](\d{1,2})", s)
    if m:
        yr, mo, da = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if yr < 1900 or yr > 2100:
            yr = None
        if _valid_md(mo, da):
            return yr, mo, da
    m = re.search(r"--(\d{2})-?(\d{2})", s)
    if m:
        mo, da = int(m.group(1)), int(m.group(2))
        if _valid_md(mo, da):
            return None, mo, da
    m = re.match(r"^(\d{4})(\d{2})(\d{2})$", s)
    if m:
        yr, mo, da = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if yr < 1900 or yr > 2100:
            yr = None
        if _valid_md(mo, da):
            return yr, mo, da
    m = re.match(r"^(\d{1,2})[-/](\d{1,2})(?:[-/](\d{2,4}))?$", s)
    if m:
        a, b, y_s = int(m.group(1)), int(m.group(2)), m.group(3)
        yr = None
        if y_s:
            yr = int(y_s)
            if yr < 100:
                yr += 1900 if yr > 30 else 2000
            if yr < 1900 or yr > 2100:
                yr = None
        mo, da = (b, a) if (a > 12 and b <= 12) else (a, b)
        if _valid_md(mo, da):
            return yr, mo, da
    months = {"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
              "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12}
    m = re.search(r"([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:,?\s*(\d{4}))?", s)
    if m and m.group(1)[:3].lower() in months:
        mo, da = months[m.group(1)[:3].lower()], int(m.group(2))
        yr = int(m.group(3)) if m.group(3) else None
        if _valid_md(mo, da):
            return yr, mo, da
    m = re.search(r"(\d{1,2})\s+([A-Za-z]{3,9})\.?(?:,?\s*(\d{4}))?", s)
    if m and m.group(2)[:3].lower() in months:
        mo, da = months[m.group(2)[:3].lower()], int(m.group(1))
        yr = int(m.group(3)) if m.group(3) else None
        if _valid_md(mo, da):
            return yr, mo, da
    return None


def parse_contacts_csv(text):
    """Parses Google Contacts CSV or Outlook CSV export for birthdays."""
    out = []
    try:
        reader = csv.DictReader(io.StringIO(text.lstrip("\ufeff")))
        for row in reader:
            if not isinstance(row, dict):
                continue
            bday_raw = ""
            for k, v in row.items():
                if k and "birthday" in k.lower() and v and v.strip():
                    bday_raw = v.strip()
                    break
            if not bday_raw:
                continue
            parsed = parse_bday_date_any(bday_raw)
            if not parsed:
                continue
            yr, mo, da = parsed
            name = (
                row.get("Name")
                or " ".join(
                    p.strip()
                    for p in [
                        row.get("First Name") or row.get("Given Name") or "",
                        row.get("Middle Name") or row.get("Additional Name") or "",
                        row.get("Last Name") or row.get("Family Name") or "",
                    ]
                    if p and p.strip()
                )
                or row.get("Nickname")
                or row.get("File As")
                or ""
            ).strip()
            if name:
                out.append({"name": name, "year": yr, "month": mo, "day": da})
    except Exception:
        pass
    return out


def find_contacts_vcf():
    """Newest contacts export (.vcf, .vcard, Google Contacts .csv, or .zip) in Downloads, Documents, Desktop, home, or local contacts."""
    import glob
    home = os.path.expanduser("~")
    found = []
    for d in ("Downloads", "Documents", "Desktop", "", ".local/share/contacts", ".contacts"):
        base_dir = os.path.join(home, d)
        if not os.path.isdir(base_dir):
            continue
        for pat in ("*.vcf", "*.vcard", "*.csv", "*.ics", "*.zip"):
            for p in glob.glob(os.path.join(base_dir, pat)):
                bn = os.path.basename(p).lower()
                try:
                    mt = os.path.getmtime(p)
                    if bn.endswith((".vcf", ".vcard")):
                        with open(p, "r", encoding="utf-8", errors="replace") as f:
                            if "BEGIN:VCARD" in f.read(4096).upper():
                                found.append((2 if "contact" in bn else 1, mt, p))
                    elif bn.endswith(".csv") and any(k in bn for k in ("contact", "google", "outlook", "birthday", "export")):
                        with open(p, "r", encoding="utf-8", errors="replace") as f:
                            head_line = f.readline().lower()
                            if "birthday" in head_line and ("name" in head_line or "given" in head_line):
                                found.append((2, mt, p))
                    elif bn.endswith(".ics") and any(k in bn for k in ("birthday", "contact", "addressbook")):
                        found.append((1, mt, p))
                    elif bn.endswith(".zip") and any(k in bn for k in ("contact", "ical", "calendar", "takeout", "birthday")):
                        found.append((1, mt, p))
                except Exception:
                    pass
    found.sort(key=lambda x: (x[1], x[0]), reverse=True)
    return found[0][2] if found else None


def _split_import_block(lines):
    """-> (lines before the managed block, lines after it); no block -> (all lines, [])."""
    try:
        a = next(i for i, l in enumerate(lines) if l.startswith("# >>> imported from contacts"))
    except StopIteration:
        return lines, []
    b = next((i for i, l in enumerate(lines) if i > a and l.startswith("# <<< end of imported contacts")), len(lines) - 1)
    return lines[:a], lines[b + 1:]


def cmd_import_birthdays(file_path=None):
    path = os.path.expanduser(file_path) if file_path else find_contacts_vcf()
    if not path or not os.path.isfile(path):
        msg = (f"File not found: {file_path}" if file_path else
               "No contacts .vcf found in Downloads. At contacts.google.com choose Export > vCard (for Google Contacts), save it, then try again.")
        print(json.dumps({"ok": False, "error": msg}))
        return 1
    new_birthdays = []
    if path.lower().endswith(".zip") and zipfile.is_zipfile(path):
        try:
            with zipfile.ZipFile(path, "r") as zf:
                for zname in zf.namelist():
                    zl = zname.lower()
                    if zl.endswith((".vcf", ".vcard", ".csv", ".ics")):
                        ztxt = zf.read(zname).decode("utf-8-sig", errors="replace")
                        if "BEGIN:VCARD" in ztxt.upper():
                            new_birthdays.extend(parse_vcf(ztxt))
                        elif zl.endswith(".csv"):
                            new_birthdays.extend(parse_contacts_csv(ztxt))
                        elif "BEGIN:VCALENDAR" in ztxt.upper() and ("birthday" in zl or "contacts" in zl or "addressbook" in zl):
                            for ev in parse_events(ztxt, "Birthdays"):
                                p = ev.get("props", {})
                                summary = unescape(p.get("SUMMARY", ("", ""))[1]).strip()
                                dtstart = p.get("DTSTART", ("", ""))[1]
                                if summary and dtstart:
                                    clean_name = re.sub(r"['’]s Birthday.*| Birthday$", "", summary, flags=re.I).replace("🎂", "").strip()
                                    m = re.match(r"(\d{4})(\d{2})(\d{2})", dtstart)
                                    if m and clean_name:
                                        new_birthdays.append({"name": clean_name, "year": None, "month": int(m.group(2)), "day": int(m.group(3))})
        except Exception as e:
            print(json.dumps({"ok": False, "error": str(e)}))
            return 1
        content = ""
    else:
        try:
            with open(path, "r", encoding="utf-8-sig", errors="replace") as f:
                content = f.read()
        except Exception as e:
            print(json.dumps({"ok": False, "error": str(e)}))
            return 1

    if content and "BEGIN:VCARD" in content.upper():
        new_birthdays = parse_vcf(content)
    elif content and path.lower().endswith(".csv"):
        new_birthdays = parse_contacts_csv(content)
    elif content and "BEGIN:VCALENDAR" in content.upper():
        raw = parse_events(content, "Birthdays")
        for ev in raw:
            p = ev.get("props", {})
            summary = unescape(p.get("SUMMARY", ("", ""))[1]).strip()
            dtstart = p.get("DTSTART", ("", ""))[1]
            if summary and dtstart:
                clean_name = re.sub(r"'s Birthday.*", "", summary, flags=re.I).strip()
                m = re.match(r"(\d{4})(\d{2})(\d{2})", dtstart)
                if m:
                    new_birthdays.append({"name": clean_name, "year": None, "month": int(m.group(2)), "day": int(m.group(3))})
    else:
        for line in content.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r"^(\d{1,2})[-/](\d{1,2})\s+([^(]+)(?:\((\d{4})\))?", line)
            if m:
                new_birthdays.append({"name": m.group(3).strip(), "month": int(m.group(1)), "day": int(m.group(2)), "year": int(m.group(4)) if m.group(4) else None})

    if not new_birthdays:
        print(json.dumps({"ok": False, "error": "No birthdays found in " + os.path.basename(path) + ". Contacts need a birthday set to show up."}))
        return 1

    # lines you typed yourself stay exactly as they are; the imported ones live between two marker lines
    existing = []
    if os.path.isfile(BIRTHDAYS_FILE):
        with open(BIRTHDAYS_FILE, "r", encoding="utf-8") as f:
            existing = f.read().splitlines()
    before, after = _split_import_block(existing)
    typed = set()
    for l in before + after:
        m = re.match(r"^(?:\d{4}[-/])?\d{1,2}[-/]\d{1,2}\s+([^(]+)", l.strip())
        if m:
            typed.add(m.group(1).strip().lower())

    out, seen, skipped = [], set(), 0
    for b in sorted(new_birthdays, key=lambda x: (x["month"], x["day"], x["name"].lower())):
        name = re.sub(r"\s*\(.*?\)", "", b["name"]).strip() or b["name"]
        key = (name.lower(), b["month"], b["day"])
        if name.lower() in typed or key in seen:
            skipped += 1
            continue
        seen.add(key)
        out.append(f"{b['month']:02d}-{b['day']:02d} {name}" + (f" ({b['year']})" if b.get("year") else ""))

    block = [IMPORT_BEGIN, f"# source: {os.path.basename(path)}  ({dt.date.today().isoformat()})"] + out + [IMPORT_END]
    head = list(before)
    while head and not head[-1].strip():
        head.pop()
    lines = head + ([""] if head else []) + block + ([""] + after if any(x.strip() for x in after) else [])
    os.makedirs(os.path.dirname(BIRTHDAYS_FILE), exist_ok=True)
    tmp = BIRTHDAYS_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, BIRTHDAYS_FILE)

    cmd_sync()
    print(json.dumps({"ok": True, "count": len(out), "skipped": skipped, "file": os.path.basename(path)}))
    return 0


def cmd_add_holiday(date_str, name):
    name = name.strip()
    m = re.match(r"^(\d{4})?[-/]?(\d{1,2})[-/](\d{1,2})$", date_str.strip())
    if not m:
        print(json.dumps({"ok": False, "error": "Invalid date format. Use MM-DD (e.g. 12-25) or YYYY-MM-DD"}))
        return 1
    y, mo, d = m.group(1), int(m.group(2)), int(m.group(3))
    formatted = f"{y}-{mo:02d}-{d:02d}" if y else f"{mo:02d}-{d:02d}"
    line = f"{formatted} {name}\n"
    os.makedirs(os.path.dirname(HOLIDAYS_FILE), exist_ok=True)
    with open(HOLIDAYS_FILE, "a", encoding="utf-8") as f:
        f.write(line)
    res = cmd_sync()
    print(json.dumps({"ok": res == 0, "name": name, "date": formatted}))
    return res


def cmd_list_countries():
    countries = [
        {"country": "India", "code": "indian"},
        {"country": "United States", "code": "usa"},
        {"country": "United Kingdom", "code": "uk"},
        {"country": "Canada", "code": "canadian"},
        {"country": "Australia", "code": "australian"},
        {"country": "Germany", "code": "german"},
        {"country": "France", "code": "french"},
        {"country": "Japan", "code": "japanese"},
        {"country": "Brazil", "code": "brazilian"},
        {"country": "Italy", "code": "italian"},
        {"country": "Spain", "code": "spanish"},
        {"country": "Netherlands", "code": "dutch"},
        {"country": "Singapore", "code": "singapore"},
        {"country": "United Arab Emirates", "code": "united_arab_emirates"},
    ]
    print(json.dumps({"ok": True, "countries": countries}))
    return 0




def cmd_list_birthdays():
    """Returns all birthdays from birthdays.txt and birthdays.json sorted by upcoming date."""
    b_list = []
    bj = load(BIRTHDAYS_JSON, [])
    if isinstance(bj, list):
        b_list.extend(bj)
    if os.path.isfile(BIRTHDAYS_FILE):
        try:
            with open(BIRTHDAYS_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    m = re.match(r"^(\d{1,2})[-/](\d{1,2})\s+([^(]+)(?:\((\d{4})\))?", line)
                    if m:
                        b_list.append({"name": m.group(3).strip(), "month": int(m.group(1)), "day": int(m.group(2)), "year": int(m.group(4)) if m.group(4) else None})
                    else:
                        m2 = re.match(r"^(\d{4})[-/](\d{1,2})[-/](\d{1,2})\s+(.+)", line)
                        if m2:
                            b_list.append({"name": m2.group(4).strip(), "year": int(m2.group(1)), "month": int(m2.group(2)), "day": int(m2.group(3))})
        except Exception:
            pass
    seen = {}
    for b in b_list:
        nm = str(b.get("name", "")).strip()
        mo = int(b.get("month", 0) or 0)
        da = int(b.get("day", 0) or 0)
        if not nm or not (1 <= mo <= 12 and 1 <= da <= 31):
            continue
        key = (nm.lower(), mo, da)
        if key not in seen or (b.get("year") and not seen[key].get("year")):
            seen[key] = {"name": nm, "month": mo, "day": da, "year": b.get("year")}
    today = dt.date.today()
    out = []
    for b in seen.values():
        mo, da, yr = b["month"], b["day"], b.get("year")
        try:
            nxt = dt.date(today.year, mo, da)
        except ValueError:
            nxt = dt.date(today.year, 2, 28)
        if nxt < today:
            try:
                nxt = dt.date(today.year + 1, mo, da)
            except ValueError:
                nxt = dt.date(today.year + 1, 2, 28)
        days_until = (nxt - today).days
        age_next = (nxt.year - int(yr)) if (yr and int(yr) <= nxt.year) else None
        out.append({
            "name": b["name"],
            "month": mo,
            "day": da,
            "mmdd": f"{mo:02d}-{da:02d}",
            "year": yr,
            "daysUntil": days_until,
            "ageNext": age_next,
        })
    out.sort(key=lambda x: (x["daysUntil"], x["name"].lower()))
    print(json.dumps({"ok": True, "count": len(out), "birthdays": out}, ensure_ascii=False))
    return 0


def cmd_remove_birthday(name):
    target = (name or "").strip().lower()
    if not target:
        print(json.dumps({"ok": False, "error": "Missing name"}))
        return 1
    bj = load(BIRTHDAYS_JSON, [])
    if isinstance(bj, list):
        bj = [b for b in bj if str(b.get("name", "")).strip().lower() != target]
        save(BIRTHDAYS_JSON, bj)
    if os.path.isfile(BIRTHDAYS_FILE):
        try:
            with open(BIRTHDAYS_FILE, "r", encoding="utf-8") as f:
                lines = f.read().splitlines()
            kept = []
            for ln in lines:
                s_ln = ln.strip()
                if not s_ln or s_ln.startswith("#"):
                    kept.append(ln)
                    continue
                m = re.match(r"^(?:\d{4}[-/])?\d{1,2}[-/]\d{1,2}\s+([^(]+)", s_ln)
                if m and m.group(1).strip().lower() == target:
                    continue
                kept.append(ln)
            with open(BIRTHDAYS_FILE, "w", encoding="utf-8") as f:
                f.write("\n".join(kept) + "\n")
        except Exception:
            pass
    cmd_sync()
    print(json.dumps({"ok": True}))
    return 0


def cmd_auto_grab():
    """Scans ~/Downloads for newly exported Google Contacts (.vcf/.csv) or Google Calendar (.ics/.zip) files
    and imports them automatically so users don't have to copy-paste URLs or pick files."""
    scan_file = os.path.join(STATE, "autoscan.json")
    seen = load(scan_file, {})
    added_cals = 0
    added_bdays = 0
    last_file = ""

    # 1. Check newest contacts export
    cand = find_contacts_vcf()
    if cand and os.path.isfile(cand):
        mt = round(os.path.getmtime(cand), 2)
        if seen.get("bday:" + cand) != mt:
            seen["bday:" + cand] = mt
            # Run silent import
            import io as _io
            old_stdout = sys.stdout
            buf = _io.StringIO()
            try:
                sys.stdout = buf
                rc = cmd_import_birthdays(cand)
            finally:
                sys.stdout = old_stdout
            if rc == 0:
                try:
                    r = json.loads(buf.getvalue().strip().splitlines()[-1])
                    if r.get("ok"):
                        added_bdays += int(r.get("count", 0))
                        last_file = os.path.basename(cand)
                except Exception:
                    pass

    # 2. Check ~/Downloads for Google Calendar export .zip or .ics
    dl = os.path.join(os.path.expanduser("~"), "Downloads")
    if os.path.isdir(dl):
        c = conf()
        existing_urls = {x.get("url") for x in c.get("calendars", [])}
        local_ics_dir = os.path.join(STATE, "imported_ics")
        for fn in sorted(os.listdir(dl)):
            full = os.path.join(dl, fn)
            if not os.path.isfile(full):
                continue
            low = fn.lower()
            mt = round(os.path.getmtime(full), 2)
            if seen.get("cal:" + full) == mt:
                continue
            if low.endswith(".ics") and not any(k in low for k in ("birthday", "contact")):
                seen["cal:" + full] = mt
                try:
                    with open(full, "r", encoding="utf-8", errors="replace") as f:
                        txt = f.read(MAX_FEED)
                    if "BEGIN:VCALENDAR" in txt:
                        os.makedirs(local_ics_dir, mode=0o700, exist_ok=True)
                        dest = os.path.join(local_ics_dir, fn)
                        with open(dest, "w", encoding="utf-8") as wf:
                            wf.write(txt)
                        u = "file://" + dest
                        if u not in existing_urls:
                            m = re.search(r"^X-WR-CALNAME:(.+)$", txt, re.M)
                            cname = unescape(m.group(1).strip()) if m else os.path.splitext(fn)[0]
                            c["calendars"].append({"url": u, "name": cname})
                            existing_urls.add(u)
                            added_cals += 1
                            last_file = fn
                except Exception:
                    pass
            elif low.endswith(".zip") and ("ical" in low or "@gmail" in low or "calendar" in low):
                seen["cal:" + full] = mt
                try:
                    if zipfile.is_zipfile(full):
                        with zipfile.ZipFile(full, "r") as zf:
                            for zname in zf.namelist():
                                if not zname.lower().endswith(".ics"):
                                    continue
                                raw = zf.read(zname).decode("utf-8", errors="replace")
                                if "BEGIN:VCALENDAR" not in raw:
                                    continue
                                if "addressbook#contacts" in zname or "birthday" in zname.lower():
                                    # Extract birthday events from Google Calendar export zip!
                                    os.makedirs(local_ics_dir, mode=0o700, exist_ok=True)
                                    b_ics = os.path.join(local_ics_dir, "google_birthdays_export.ics")
                                    with open(b_ics, "w", encoding="utf-8") as wf:
                                        wf.write(raw)
                                    import io as _io
                                    old_stdout = sys.stdout
                                    buf = _io.StringIO()
                                    try:
                                        sys.stdout = buf
                                        rc = cmd_import_birthdays(b_ics)
                                    finally:
                                        sys.stdout = old_stdout
                                    if rc == 0:
                                        try:
                                            r = json.loads(buf.getvalue().strip().splitlines()[-1])
                                            if r.get("ok"):
                                                added_bdays += int(r.get("count", 0))
                                        except Exception:
                                            pass
                                else:
                                    os.makedirs(local_ics_dir, mode=0o700, exist_ok=True)
                                    safe_bn = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(zname))
                                    dest = os.path.join(local_ics_dir, safe_bn)
                                    with open(dest, "w", encoding="utf-8") as wf:
                                        wf.write(raw)
                                    u = "file://" + dest
                                    if u not in existing_urls:
                                        m = re.search(r"^X-WR-CALNAME:(.+)$", raw, re.M)
                                        cname = unescape(m.group(1).strip()) if m else os.path.splitext(os.path.basename(zname))[0]
                                        c["calendars"].append({"url": u, "name": cname})
                                        existing_urls.add(u)
                                        added_cals += 1
                                        last_file = fn
                except Exception:
                    pass
        if added_cals > 0:
            save(CONF, c, private=True)

    save(scan_file, seen)
    if added_cals > 0 or added_bdays > 0:
        import io as _io
        old_stdout = sys.stdout
        try:
            sys.stdout = _io.StringIO()
            cmd_sync()
        finally:
            sys.stdout = old_stdout
    print(json.dumps({
        "ok": True,
        "addedCalendars": added_cals,
        "addedBirthdays": added_bdays,
        "file": last_file,
    }))
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
        out = load(CACHE, {"synced": 0, "error": "", "events": []})
        out["done"] = sorted(load(DONE, {}).keys())
        out["tasks"] = sorted(load(TASKS, {}).keys())
        print(json.dumps(out))
    elif a == "notify":
        return cmd_notify(argv[2:])
    elif a in ("done", "undone") and len(argv) >= 3:
        cmd_done(argv[2], a == "done")
    elif a == "task" and len(argv) >= 4:
        cmd_task(argv[2], argv[3] == "on")
    elif a == "inspect":
        return cmd_inspect()
    elif a == "detect-region":
        return cmd_detect_region()
    elif a == "add-holidays":
        return cmd_add_holidays(argv[2] if len(argv) >= 3 else None)
    elif a == "add-holiday" and len(argv) >= 4:
        return cmd_add_holiday(argv[2], argv[3])
    elif a == "list-countries":
        return cmd_list_countries()
    elif a == "add-birthday" and len(argv) >= 4:
        return cmd_add_birthday(argv[2], argv[3], argv[4] if len(argv) >= 5 else None)
    elif a == "list-birthdays":
        return cmd_list_birthdays()
    elif a == "remove-birthday" and len(argv) >= 3:
        return cmd_remove_birthday(argv[2])
    elif a == "auto-grab":
        return cmd_auto_grab()
    elif a == "import-birthdays":
        return cmd_import_birthdays(argv[2] if len(argv) >= 3 else None)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
