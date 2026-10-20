"""Weekly sky: python3 tests/test_weekly_sky.py   (scripts/weekly-sky.py and the `done_at` / sky log of scripts/halcyon-notes.py)"""
import datetime as dt, importlib.util, json, os, subprocess, sys, tempfile, xml.dom.minidom

here = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(here, "..", "scripts", "weekly-sky.py")
tmp = tempfile.mkdtemp()
st = os.path.join(tmp, ".local", "state", "island")
os.makedirs(os.path.join(st, "calendar")); os.makedirs(os.path.join(tmp, ".cache", "island"))
os.environ.update(HOME=tmp, XDG_STATE_HOME="", XDG_CACHE_HOME="", WEEKLY_SKY_OUT=os.path.join(tmp, "out"))
del os.environ["XDG_STATE_HOME"]; del os.environ["XDG_CACHE_HOME"]
ts = lambda y, m, d, h=0, mi=0: dt.datetime(y, m, d, h, mi).timestamp()
NOW = ts(2026, 10, 20, 18)                                  # Tuesday 18:00; this week is Mon 19 Oct .. Sun 25 Oct
os.environ["WEEKLY_SKY_NOW"] = str(NOW)

spec = importlib.util.spec_from_file_location("weekly_sky", SCRIPT)
ws = importlib.util.module_from_spec(spec); spec.loader.exec_module(ws)

bad = 0
def check(name, cond, extra=""):
    global bad
    if not cond:
        bad += 1; print("FAIL", name, extra)

def put(name, data, jsonl=False):
    with open(os.path.join(st, name), "w") as fh:
        fh.write("\n".join(json.dumps(x) for x in data) + "\n" if jsonl else json.dumps(data))

# ---- no data: no stars, a calm sentence, dust only
sky = ws.build(0)
check("empty: no stars", sky["stars"] == [] and sky["lines"] == [])
check("empty: dust is there", len(sky["dust"]) == ws.DUST)
check("empty: sentence", sky["summary"].startswith("A quiet week so far"), sky["summary"])
check("week range", sky["range"] == "Oct 19 – Oct 25" and sky["isoWeek"] == "2026-W43", (sky["range"], sky["isoWeek"]))
check("fill is a quarter-ish of the week", 0.24 < sky["fill"] < 0.26, sky["fill"])
check("last week sentence has no 'so far'", ws.build(-1)["summary"] == "A quiet week: no stars")

# ---- data
put("focus-days.json", {"2026-10-19": 50, "2026-10-20": 75, "2026-10-21": 30, "2026-10-10": 200, "junk": "x"})
put("calendar/events.json", {"events": [
    {"id": "e1", "title": "Standup", "start": ts(2026, 10, 19, 10), "end": ts(2026, 10, 19, 10, 30), "allDay": False},
    {"id": "e2", "title": "Design review", "start": ts(2026, 10, 20, 14), "end": ts(2026, 10, 20, 15), "allDay": False},
    {"id": "e3", "title": "Later today", "start": ts(2026, 10, 20, 19), "end": ts(2026, 10, 20, 20), "allDay": False},
    {"id": "e4", "title": "Still running", "start": ts(2026, 10, 20, 17), "end": ts(2026, 10, 20, 19), "allDay": False},
    {"id": "b1", "title": "Sam's birthday", "start": ts(2026, 10, 20), "end": ts(2026, 10, 21), "allDay": True},
    {"id": "old", "title": "Last week", "start": ts(2026, 10, 14, 9), "end": ts(2026, 10, 14, 10), "allDay": False},
    {"title": "no id or times"}, "not a dict"]})
put("sky-events.jsonl", [
    {"t": ts(2026, 10, 19, 16), "kind": "task", "id": "n1", "text": "Pay rent"},
    {"t": ts(2026, 10, 20, 9), "kind": "task", "id": "n2", "text": "Email Priya"},
    {"t": ts(2026, 10, 20, 10), "kind": "untask", "id": "n2"},
    {"t": ts(2026, 10, 20, 11), "kind": "task", "id": "n3", "text": "Book flights"},
    {"t": ts(2026, 10, 20, 19), "kind": "task", "id": "n5", "text": "in the future"}], jsonl=True)
with open(os.path.join(st, "sky-events.jsonl"), "a") as fh: fh.write("this line is not json\n")
put("notes.json", [{"id": "n4", "text": "Old tick", "done": True, "done_at": ts(2026, 10, 19, 12)},
                   {"id": "n1", "text": "Pay rent", "done": True, "done_at": ts(2026, 10, 19, 16)},     # also in the log: counted once
                   {"id": "n6", "text": "never done"}, {"id": "n7", "text": "done, no time", "done": True}])
sky = ws.build(0)
kinds = [s["kind"] for s in sky["stars"]]
labels = [s["label"] for s in sky["stars"]]
check("counts", sky["counts"] == {"focusMinutes": 125, "focus": 5, "tasks": 3, "events": 2}, sky["counts"])
check("an event that is still running is not a star yet", "Still running" not in labels, labels)
check("future event and future tick are left out", "Later today" not in labels and not any("future" in l for l in labels))
check("all-day events are not counted", not any("birthday" in l for l in labels))
check("an un-ticked task loses its star", not any("Priya" in l for l in labels))
check("a tick in the log and in notes.json counts once", sum("Pay rent" in l for l in labels) == 1)
check("last week's event is not in this week", "Last week" not in labels)
check("tomorrow's focus minutes (data from a day that has not started) are ignored", sky["counts"]["focusMinutes"] == 125)
check("stars are in time order", [s["t"] for s in sky["stars"]] == sorted(s["t"] for s in sky["stars"]))
check("every star is inside the picture band", all(0.04 <= s["x"] <= 0.96 and ws.Y0 - 1e-9 <= s["y"] <= ws.Y0 + ws.YS + 1e-9 for s in sky["stars"]))
check("every line points at real stars", all(0 <= a < len(sky["stars"]) and 0 <= b < len(sky["stars"]) and a != b for a, b, _ in sky["lines"]))
check("lines: one chain per day plus bridges", len(sky["lines"]) == len(sky["stars"]) - 1, (len(sky["lines"]), len(sky["stars"])))
check("summary", sky["summary"] == "2 h 05 min focus · 3 tasks done · 2 events", sky["summary"])
check("today's focus stars are spread up to now", all(s["t"] <= NOW for s in sky["stars"]))

# ---- same week, same sky
check("deterministic", json.dumps(ws.build(0), sort_keys=True) == json.dumps(ws.build(0), sort_keys=True))
r = subprocess.run([sys.executable, SCRIPT, "json"], capture_output=True, text=True)
check("json command", r.returncode == 0 and json.loads(r.stdout)["counts"]["tasks"] == 3, r.stderr)

# ---- the picture
doc = ws.svg(sky)
try:
    xml.dom.minidom.parseString(doc.encode()); ok = True
except Exception as e:
    ok = False; print(e)
check("svg is well-formed XML", ok)
check("svg has the title, the dates and the numbers", "My week in stars" in doc and "Oct 19" in doc and "3 tasks done" in doc)
hostile = dict(sky, summary="<script>alert(1)</script> & \"x\"", range="a<b")
check("svg escapes text", "<script>" not in ws.svg(hostile))
out = ws.export(sky)
check("export writes the svg", out["ok"] and os.path.exists(out["svg"]) and os.stat(out["svg"]).st_mode & 0o044, out)
check("export name has the ISO week", out["svg"].endswith("weekly-sky-2026-W43.svg"))
r = subprocess.run([sys.executable, SCRIPT, "export", "--out", os.path.join(tmp, "o2")], capture_output=True, text=True)
check("export command prints json", r.returncode == 0 and json.loads(r.stdout)["ok"], r.stdout + r.stderr)

# ---- arguments
check("bad offset", subprocess.run([sys.executable, SCRIPT, "json", "--offset", "x"], capture_output=True).returncode == 2)
check("future offset is clamped to this week", json.loads(subprocess.run([sys.executable, SCRIPT, "json", "--offset", "5"], capture_output=True, text=True).stdout)["offset"] == 0)
check("unknown command", subprocess.run([sys.executable, SCRIPT, "nope"], capture_output=True).returncode == 2)
check("status", subprocess.run([sys.executable, SCRIPT, "status"], capture_output=True, text=True).stdout.startswith("Oct 19"))

# ---- the notes side: ticking a note records done_at and a log line, un-ticking removes both
nspec = importlib.util.spec_from_file_location("hn", os.path.join(here, "..", "scripts", "halcyon-notes.py"))
sys.argv = ["notes"]
hn = importlib.util.module_from_spec(nspec); nspec.loader.exec_module(hn)
hn.save_notes([{"id": "n_1", "text": "buy milk", "created": 1, "done": False}])
os.remove(os.path.join(st, "sky-events.jsonl"))
hn.done_note("n_1")
n = hn.load_notes()[0]
check("tick: done and done_at", n["done"] is True and abs(n["done_at"] - __import__("time").time()) < 5, n)
log = [json.loads(l) for l in open(os.path.join(st, "sky-events.jsonl"))]
check("tick: a log line", len(log) == 1 and log[0]["kind"] == "task" and log[0]["id"] == "n_1" and log[0]["text"] == "buy milk", log)
hn.done_note("n_1")
n = hn.load_notes()[0]
log = [json.loads(l) for l in open(os.path.join(st, "sky-events.jsonl"))]
check("untick: done_at gone, untask logged", n["done"] is False and "done_at" not in n and log[-1]["kind"] == "untask", (n, log))

print("ok" if not bad else "%d failed" % bad)
sys.exit(1 if bad else 0)
