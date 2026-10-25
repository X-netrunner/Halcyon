"""How >ask routes a question: python3 tests/test_ask_routing.py   (scripts/halcyon-ai.py ask; the model is a stub, nothing is sent)

  small talk          a fixed reply, no model call (works with the AI off too)
  general questions   answered by the model directly, never turned into a Halcyon settings guide or sent to ai-firewall
  Halcyon questions   "turn off the constellations" -> the settings guide; "what is halcyon" -> the docs
"""
import importlib.util
import os
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
tmp = tempfile.mkdtemp(prefix="halcyon-ask-test-")
os.environ.update({"HOME": tmp, "HALCYON_STATE": os.path.join(tmp, "s"), "HALCYON_DIR": os.path.join(here, "..")})
spec = importlib.util.spec_from_file_location("ai", os.path.join(here, "..", "scripts", "halcyon-ai.py"))
ai = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ai)

calls = []


def fake_generate(prompt, system="", fmt=None, **kw):
    calls.append({"prompt": prompt, "system": system, "fmt": fmt})
    return '{"entry": 1, "action": "", "note": ""}' if fmt == "json" else "an answer"


ai.generate = fake_generate
ai.firewall_ask = lambda q: calls.append({"firewall": q}) or {"text": "from ai-firewall"}
ai.shutil.which = lambda c: "/usr/bin/" + c          # pretend ai-firewall is installed, so a wrong route would show

bad = 0
n = 0


def route(q):
    calls.clear()
    r = ai.cmd_ask(q.split())
    if r.get("kind") == "smalltalk":
        return "smalltalk"
    if r.get("kind") == "howto":
        return "howto"
    if any("firewall" in c for c in calls):
        return "firewall"
    if any("From Halcyon's own docs" in c.get("prompt", "") for c in calls):
        return "docs"
    return "general"


def check(q, want):
    global bad, n
    n += 1
    got = route(q)
    if got != want:
        bad += 1
        print(f"FAIL {q!r}: {got} (want {want})")


for q in ("hi", "Hello!", "hey there", "thanks", "Thank you so much!", "ok", "bye", "how are you?"):
    check(q, "smalltalk")
calls.clear()
ai.cmd_ask(["hi"])
n += 1
if calls:
    bad += 1
    print("FAIL small talk called the model")

for q in ("how do I install numpy", "explain how a firewall works", "what is dns", "how do notifications work on android",
          "write a haiku about rain", "how many ml in a cup", "what are good wallpaper sites", "difference between tcp and udp"):
    check(q, "general")

for q in ("how do I turn off the constellations", "hide the bar", "change the wallpaper"):
    check(q, "howto")

for q in ("what is halcyon", "who are you"):
    check(q, "docs")

check("my ssh connection is blocked", "firewall")

print(f"{n - bad}/{n} checks passed")
sys.exit(1 if bad else 0)
