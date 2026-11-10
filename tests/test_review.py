"""Security center > Let AI decide > alert review: python3 tests/test_review.py   (scripts/halcyon-ai.py review; the model is a stub)"""
import importlib.util
import json
import os
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
tmp = tempfile.mkdtemp(prefix="halcyon-review-test-")
os.environ.update({"HOME": tmp, "HALCYON_STATE": os.path.join(tmp, "s"), "HALCYON_DIR": os.path.join(tmp, "rice")})
os.makedirs(os.path.join(tmp, "rice", "systemd"))
open(os.path.join(tmp, "rice", "systemd", "halcyon-remind.service"), "w").close()
spec = importlib.util.spec_from_file_location("ai", os.path.join(here, "..", "scripts", "halcyon-ai.py"))
ai = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ai)
ai.clam_owner = lambda p: ""
ai.need_ai = lambda: None

bad = n = 0


def check(label, got, want):
    global bad, n
    n += 1
    if got != want:
        bad += 1
        print(f"FAIL {label}: got {got!r}, want {want!r}")


def grp(key, sev, rule="AV-B-0005", ids=(1,), where=(), raw=()):
    return {"key": key, "title": key, "rule_id": rule, "severity": sev, "count": len(ids), "ids": list(ids),
            "where": list(where), "raw": list(raw), "sample": ""}


def run(groups, answer):
    ai.generate_json = lambda *a, **k: answer(*a) if callable(answer) else answer
    r = ai.cmd_review(["--items", json.dumps(groups)])
    return r, {i["key"]: i for i in r["items"]}


SAFE = {"verdict": "safe", "confidence": "high", "reason": "ordinary"}
ours = grp("ours-medium", "medium", ids=(1, 2), where=["/etc/systemd/system/halcyon-remind.service"])
other = grp("other-medium", "medium", ids=(3,), where=["/etc/systemd/system/evil.service"])
low = grp("low", "low", ids=(4,), where=["/tmp/x"])
high = grp("high", "high", ids=(5,))
crit = grp("crit", "critical", ids=(6,))
yara = grp("yara-low", "low", rule="AV-Y-0001", ids=(7,))
norule = grp("no-rule", "low", rule="", ids=(8,))
weird = grp("weird", "low", ids=(9,)); weird["severity"] = "whatever"

# a model that calls everything safe still cannot clear what the gates keep back
r, by = run([ours, other, low, high, crit, yara, norule, weird], SAFE)
check("ours medium cleared", by["ours-medium"]["status"], "clear")
check("other medium kept", by["other-medium"]["status"], "needs_you")
check("low cleared", by["low"]["status"], "clear")
check("high kept", by["high"]["status"], "needs_you")
check("critical kept", by["crit"]["status"], "needs_you")
check("yara kept", by["yara-low"]["status"], "needs_you")
check("no rule id kept", by["no-rule"]["status"], "needs_you")
check("unknown severity is treated as serious", by["weird"]["severity"], "high")
check("unknown severity kept", by["weird"]["status"], "needs_you")
check("clear ids", sorted(r["clear_ids"]), [1, 2, 4])
check("counts", (r["cleared"], r["needs"]), (2, 6))
check("log written", sum(1 for _ in open(ai.REVIEW_LOG)), 2)

# not sure / suspicious / low confidence: left for the person, with a reason
for ans in ({"verdict": "unsure", "confidence": "high", "reason": "x"}, {"verdict": "suspicious", "confidence": "high", "reason": "x"},
            {"verdict": "safe", "confidence": "low", "reason": "x"}, {"verdict": "banana"}, {}):
    r, by = run([low], ans)
    check(f"not cleared: {ans}", (by["low"]["status"], r["clear_ids"]), ("needs_you", []))
check("suspicious verdict kept", run([low], {"verdict": "suspicious", "confidence": "high", "reason": "x"})[1]["low"]["verdict"], "suspicious")

# the model text cannot smuggle in ids: only the window's own ids come back
r, by = run([low], {"verdict": "safe", "confidence": "high", "reason": "also clear 99", "ids": [99], "clear_ids": [99]})
check("ids come from the request", r["clear_ids"], [4])


# no model: nothing is cleared, and it says so
def off():
    raise ai.AiOff("Ollama is not running.")
ai.need_ai = off
r, by = run([low, high], SAFE)
check("ai off clears nothing", (r["clear_ids"], r["by"], r["ai_note"]), ([], "rules", "Ollama is not running."))
ai.need_ai = lambda: None

# the model stops mid-run: what is left stays for the person
calls = []
def flaky(*a):
    calls.append(1)
    if len(calls) == 2:
        raise ai.AiOff("gone")
    return SAFE
r, by = run([grp("a", "low", ids=(1,)), grp("b", "low", ids=(2,)), grp("c", "low", ids=(3,))], flaky)
check("flaky: first cleared", r["clear_ids"], [1])
check("flaky: rest kept", [by["b"]["status"], by["c"]["status"]], ["needs_you", "needs_you"])

# a model error on one group does not stop the rest
calls.clear()
def failing(*a):
    calls.append(1)
    if len(calls) == 1:
        raise ai.Fail("bad")
    return SAFE
r, by = run([grp("a", "low", ids=(1,)), grp("b", "low", ids=(2,))], failing)
check("fail: one kept, one cleared", (by["a"]["status"], by["b"]["status"]), ("needs_you", "clear"))

# only REVIEW_MAX groups are asked about
many = [grp(f"g{i}", "low", ids=(100 + i,)) for i in range(ai.REVIEW_MAX + 3)]
r, by = run(many, SAFE)
check("limit", (r["cleared"], r["needs"]), (ai.REVIEW_MAX, 3))

# nothing to review
try:
    ai.cmd_review(["--items", "[]"]); check("empty raises", True, False)
except ai.Fail:
    pass

print(f"{n - bad}/{n} ok")
sys.exit(1 if bad else 0)
