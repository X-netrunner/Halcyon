"""Notes tasks in the calendar: python3 tests/test_note_tasks_calendar.py   (quickshell/island/scripts/gcal.py)"""
import importlib.util, json, os, sys, tempfile, time

here = os.path.dirname(os.path.abspath(__file__))
sys.argv = ["gcal.py"]
spec = importlib.util.spec_from_file_location("gcal", os.path.join(here, "..", "quickshell", "island", "scripts", "gcal.py"))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

now = time.time()
notes = [
    {"id": "n_1", "text": "call mom at 9\nsecond line", "task": True, "due": now + 3600},        # shows, title = first line
    {"id": "n_2", "text": "water plants later", "task": True, "later": True},                      # no time: not on a day
    {"id": "n_3", "text": "not a task", "task": False, "due": now + 7200},                        # a plain note: never
    {"id": "n_4", "text": "dentist", "task": True, "due": now + 86400, "done": True},             # shows, already ticked
    {"id": "n_5", "text": "x" * 200, "task": True, "due": now + 2 * 86400},                      # long title is cut
    {"id": "n_6", "text": "old", "task": True, "due": now - 100 * 86400},                         # outside the window
    {"id": "n_7", "text": "   ", "task": True, "due": now + 5000},                                 # nothing to show
    {"id": "n_8", "text": "bad due", "task": True, "due": "soon"},                                 # not a time
]
bad = 0
def check(name, ok):
    global bad
    if not ok:
        bad += 1; print("FAIL", name)

with tempfile.TemporaryDirectory() as d:
    g.NOTES_FILE = os.path.join(d, "notes.json")
    check("no file -> nothing", g.load_note_task_events(now - 86400, now + 10 * 86400) == ([], []))
    with open(g.NOTES_FILE, "w") as f:
        f.write("{not json")
    check("broken file -> nothing, no crash", g.load_note_task_events(now - 86400, now + 10 * 86400) == ([], []))
    with open(g.NOTES_FILE, "w") as f:
        json.dump(notes, f)
    ev, done = g.load_note_task_events(now - 35 * 86400, now + 150 * 86400)
    check("three events (mom, dentist, long)", [e["title"][:5] for e in ev] == ["call ", "denti", "xxxxx"])
    check("first line is the title", ev[0]["title"] == "call mom at 9")
    check("long title cut to 90", len(ev[2]["title"]) == 90 and ev[2]["title"].endswith("\u2026"))
    check("start is the due time, 30 minutes long", ev[0]["start"] == int(notes[0]["due"]) and ev[0]["end"] - ev[0]["start"] == 1800)
    check("timed, in the Notes calendar", not ev[0]["allDay"] and ev[0]["cal"] == "Notes")
    check("only the ticked one is done", done == [ev[1]["id"]])
    check("ids are stable and unique", len({e["id"] for e in ev}) == 3 and ev[0]["id"] == g.load_note_task_events(now - 35 * 86400, now + 150 * 86400)[0][0]["id"])
    notes[0]["due"] += 7200
    with open(g.NOTES_FILE, "w") as f:
        json.dump(notes, f)
    ev2, _ = g.load_note_task_events(now - 35 * 86400, now + 150 * 86400)
    check("a new time moves the event and gives it a new id", ev2[0]["start"] == int(notes[0]["due"]) and ev2[0]["id"] != ev[0]["id"])

print("ok" if not bad else f"{bad} failed")
sys.exit(1 if bad else 0)
