"""Security center > Let AI decide: python3 tests/test_decide.py   (scripts/halcyon-ai.py decide; the model is a stub)"""
import importlib.util
import json
import os
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
tmp = tempfile.mkdtemp(prefix="halcyon-decide-test-")
os.environ.update({"HOME": tmp, "HALCYON_STATE": os.path.join(tmp, "s")})
spec = importlib.util.spec_from_file_location("ai", os.path.join(here, "..", "scripts", "halcyon-ai.py"))
ai = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ai)

bad = n = 0


def check(label, got, want):
    global bad, n
    n += 1
    if got != want:
        bad += 1
        print(f"FAIL {label}: got {got!r}, want {want!r}")


ITEMS = [{"key": "alerts", "tone": "warn", "title": "2 alerts to review", "sub": "x"},
         {"key": "fw", "tone": "bad", "title": "Firewall is not responding", "sub": "y"}]
ARGS = ["--items", json.dumps(ITEMS)]

# no model (Ollama not there): the plain order, honestly labelled
def off(*a, **k):
    raise ai.AiOff("Ollama is not running.")
ai.generate_json = off
r = ai.cmd_decide(ARGS)
check("rules pick", r["pick"], "fw")
check("rules by", r["by"], "rules")
check("rules note", r["ai_note"], "Ollama is not running.")
check("rules order", r["order"], ["fw", "alerts"])

# model picks something that waits while a protection is down: the protection goes first, and it says so
ai.generate_json = lambda *a, **k: {"pick": "alerts", "order": ["alerts", "fw"], "why": "Alerts.", "notes": {"fw": "off", "zzz": "no"}}
r = ai.cmd_decide(ARGS)
check("override pick", r["pick"], "fw")
check("override flag", r["adjusted"], True)
check("override order", r["order"], ["fw", "alerts"])
check("unknown note dropped", r["notes"], {"fw": "off"})

# a model that agrees, with an order that misses a key and invents one
ai.generate_json = lambda *a, **k: {"pick": "fw", "order": ["bogus", "fw"], "why": "It is off.", "notes": {}}
r = ai.cmd_decide(ARGS)
check("ai by", r["by"], "ai")
check("order completed, invented key dropped", r["order"], ["fw", "alerts"])

# nonsense from the model: back to the plain order
ai.generate_json = lambda *a, **k: {"pick": "nope", "why": ""}
r = ai.cmd_decide(ARGS)
check("bad answer falls back", (r["by"], r["pick"]), ("rules", "fw"))

# nothing to decide / garbage input
for a in (["--items", "[]"], ["--items", "not json"], []):
    try:
        ai.cmd_decide(a); got = "no error"
    except ai.Fail:
        got = "Fail"
    check(f"empty input {a}", got, "Fail")

print(f"{n - bad}/{n} passed")
sys.exit(1 if bad else 0)
