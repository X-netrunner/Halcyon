"""Task detection: python3 tests/test_task_detect.py   (pure functions of scripts/halcyon-notes.py, time is frozen)"""
import datetime, importlib.util, os, sys, tempfile, time

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("hn", os.path.join(here, "..", "scripts", "halcyon-notes.py"))
hn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hn)

def at(h, m=0):
    return datetime.datetime.now().replace(hour=h, minute=m, second=0, microsecond=0).timestamp()

def due(now_h, text):
    time.time = lambda: at(now_h)
    ts = hn.resolve_due(text, None)
    return datetime.datetime.fromtimestamp(ts).strftime("%H:%M") if ts else None

CUES = [("remind me to call mom at 9", True), ("I need to buy milk", True), ("don't forget the keys", True),
        ("I must say this is great", False), ("I have to admit I like it", False), ("I must be going", False),
        ("buy milk", False)]
DUES = [(9, "call dad tonight at 11", "23:00"), (9, "remind me at 11 pm", "23:00"), (14, "at 9 tonight pay rent", "21:00"),
        (10, "at 9 call mom", "21:00"), (9, "meeting 9:30 AM", "09:30"), (9, "buy milk at 3 items", None),
        (7, "take pills at 8 and 20:00", "08:00"), (9, "take pills at 8 and 20:00", "20:00"), (14, "remind me at 6 to cook", "18:00"), (8, "at 9 call mom", "09:00")]

bad = 0
for text, want in CUES:
    got = hn.explicit_task(text)
    if got != want: bad += 1; print(f"FAIL cue  {text!r}: {got} (want {want})")
for h, text, want in DUES:
    got = due(h, text)
    if got != want: bad += 1; print(f"FAIL due  {h}:00 {text!r}: {got} (want {want})")
# parse_when, now = Tue 2026-10-20 10:11
def pw(spec, hour=10, minute=11):
    n = datetime.datetime(2026, 10, 20, hour, minute).timestamp()
    try: t = hn.parse_when(spec, n)
    except ValueError: return "ValueError"
    return datetime.datetime.fromtimestamp(t).strftime("%a %d %H:%M") if t else None
WHEN = [("18:00", "Tue 20 18:00"), ("6pm", "Tue 20 18:00"), ("+30m", "Tue 20 10:41"), ("tomorrow", "Wed 21 09:00"),
        ("9:00", "Wed 21 09:00"), ("12am", "Wed 21 00:00"), ("12pm", "Tue 20 12:00"), ("friday 9am", "Fri 23 09:00"),
        ("tuesday 9am", "Tue 27 09:00"), ("none", None), ("25:00", "ValueError"), ("blah", "ValueError")]
for spec, want in WHEN:
    got = pw(spec)
    if got != want: bad += 1; print(f"FAIL when {spec!r}: {got} (want {want})")
if pw("tuesday 9am", 8, 0) != "Tue 20 09:00": bad += 1; print("FAIL when 'tuesday 9am' said on Tuesday 08:00 must be today")

# ---- repeating tasks
def D(y, m, d, h=9, mi=0): return datetime.datetime(y, m, d, h, mi).timestamp()
def fmt(t): return datetime.datetime.fromtimestamp(t).strftime("%a %d %b %H:%M")
NEXT = [("daily", D(2026, 10, 20), D(2026, 10, 20, 10), "Wed 21 Oct 09:00"),
        ("weekdays", D(2026, 10, 23), D(2026, 10, 23, 10), "Mon 26 Oct 09:00"),
        ("weekly", D(2026, 10, 20), D(2026, 10, 20, 10), "Tue 27 Oct 09:00"),
        ("monthly", D(2026, 1, 31), D(2026, 1, 31, 10), "Sat 28 Feb 09:00"),
        ("monthly", D(2026, 12, 15), D(2026, 12, 15, 10), "Fri 15 Jan 09:00"),
        ("daily", D(2026, 10, 20), D(2026, 10, 30, 10), "Sat 31 Oct 09:00")]       # off for 10 days: one next time, no catching up
for kind, base, after, want in NEXT:
    got = fmt(hn.next_due(base, kind, after))
    if got != want: bad += 1; print(f"FAIL next_due {kind}: {got} (want {want})")
REP = [("every monday 9am call", "weekly"), ("daily at 8 take pills", "daily"), ("every weekday standup", "weekdays"),
       ("monthly rent", "monthly"), ("buy milk", None)]
for text, want in REP:
    if hn.parse_repeat(text) != want: bad += 1; print(f"FAIL repeat {text!r}: {hn.parse_repeat(text)}")

# remind_check on a repeating and a one-time task (files and notifications are stubbed)
tmp = tempfile.mkdtemp()
hn.STATE_DIR = tmp
hn.NOTES_FILE = os.path.join(tmp, "notes.json")
sent = []
hn.notify = lambda t, b, icon="x": sent.append(b)
hn.remind_with_buttons = lambda n, late: False
hn.sync_timer = lambda notes=None: None
hn.refresh_ui = lambda: None
now = D(2026, 10, 30, 10)
time.time = lambda: now
hn.save_notes([{"id": "n_1", "text": "pills", "task": True, "due": D(2026, 10, 20), "repeat": "daily"},
               {"id": "n_2", "text": "rent", "task": True, "due": D(2026, 10, 29)}])
hn.remind_check()
a, b = hn.load_notes()
if sent != ["pills", "rent"]: bad += 1; print("FAIL remind_check sent", sent)
if fmt(a["due"]) != "Sat 31 Oct 09:00" or a.get("reminded"): bad += 1; print("FAIL repeating task not rolled:", fmt(a["due"]), a.get("reminded"))
if not b.get("reminded"): bad += 1; print("FAIL one-time task not marked reminded")
# a snooze comes back: the schedule (anchor) is kept
hn.snooze_note("n_1", "+10m")
a = hn.load_notes()[0]
if fmt(a["due"]) != "Fri 30 Oct 10:10" or fmt(a["anchor"]) != "Sat 31 Oct 09:00": bad += 1; print("FAIL snooze", fmt(a["due"]), a.get("anchor"))
now = D(2026, 10, 30, 10, 11)
sent.clear(); hn.remind_check()
a = hn.load_notes()[0]
if fmt(a["due"]) != "Sat 31 Oct 09:00" or sent != ["pills"]: bad += 1; print("FAIL snooze came back:", fmt(a["due"]), sent)
# "remind me ... every day at 8pm" becomes a repeating task by itself
now = D(2026, 10, 30, 10)
hn.save_notes([{"id": "n_9", "text": "remind me to take pills every day at 8pm"}])
hn.apply_rule_task("n_9", "remind me to take pills every day at 8pm", hn.read_conf())
c = hn.load_notes()[0]
if not c.get("task") or c.get("repeat") != "daily" or fmt(c.get("due", 0)) != "Fri 30 Oct 20:00": bad += 1; print("FAIL rule task repeat:", c)
print("ok" if not bad else f"{bad} failed")
sys.exit(1 if bad else 0)
