#!/usr/bin/env python3
"""No-mercy memory freeing (Settings > Performance, opt:memRuthless) and the Security center changes of the same round.

  - every AI script keeps the local model 10 s (3 s for notes) after an answer when the option is on, and its old time when it is off
  - the Security center's log is a ListModel fed in batches (it used to copy and rebuild a 300-row array for every line)
  - the Firewall Center is part of the Security center: no separate window, the old sub-pages are there, a missing module is greyed out
"""
import importlib.util, json, os, re, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
S, Q = os.path.join(ROOT, "scripts"), os.path.join(ROOT, "quickshell", "island")
n = bad = 0


def ok(name, cond):
    global n, bad
    n += 1
    if not cond:
        bad += 1
        print("FAIL", name)


home = tempfile.mkdtemp()
state = os.path.join(home, ".local", "state", "island")
os.makedirs(state)
os.environ["HOME"] = home
os.environ.pop("HALCYON_STATE", None)
sys.path.insert(0, S)


def settings(opt):
    with open(os.path.join(state, "settings.json"), "w", encoding="utf-8") as f:
        json.dump({"opt": opt}, f)


def load(tag, name):
    spec = importlib.util.spec_from_file_location(tag, os.path.join(S, name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


for name in ("halcyon-chat", "halcyon-agent", "adaptive-advisor"):
    for opt, want in (({}, "3m"), ({"lazyLoad": False}, "30m"), ({"memRuthless": True}, "10s"), ({"memRuthless": True, "lazyLoad": False}, "10s"), ({"memRuthless": False}, "3m")):
        settings(opt)
        m = load("%s-%s" % (name.replace("-", "_"), json.dumps(opt, sort_keys=True)), name)
        ok("%s keeps the model %s with %s" % (name, want, opt), m.KEEP_ALIVE == want)

settings({"memRuthless": True})
ai = load("ai_a", "halcyon-ai")
ok("halcyon-ai: 10 s with no-mercy", ai.keep_alive_for_ai() == "10s")
settings({})
ai = load("ai_b", "halcyon-ai")
ok("halcyon-ai: 1 minute normally", ai.keep_alive_for_ai() == "1m")
settings({"lazyLoad": False})
ai = load("ai_c", "halcyon-ai")
ok("halcyon-ai: 5 minutes with the old switch off", ai.keep_alive_for_ai() == "5m")

notes = load("notes_a", "halcyon-notes")
settings({"memRuthless": True})
ok("notes: 3 s with no-mercy", notes.keep_alive() == "3s")
settings({})
ok("notes: 10 s normally", notes.keep_alive() == "10s")
settings({"lazyLoad": False})
ok("notes: 2 minutes with the old switch off", notes.keep_alive() == "2m")

study = load("study_a", "halcyon-study")
for opt, want in (({"memRuthless": True}, "10s"), ({}, "3m"), ({"lazyLoad": False}, "30m")):
    settings(opt)
    ok("study keeps the model %s with %s" % (want, opt), study.keep_alive() == want)

# ---- the shell and Settings know the option
shell = open(os.path.join(Q, "shell.qml"), encoding="utf-8").read()
sett = open(os.path.join(Q, "Settings.qml"), encoding="utf-8").read()
ok("shell.qml has the memRuthless default (off)", re.search(r"memRuthless:\s*false", shell) is not None)
ok("Settings has the toggle", 'key: "opt:memRuthless"' in sett and "def: false" in sett.split('key: "opt:memRuthless"')[1][:40])

# ---- the Security center
sc = open(os.path.join(Q, "SecurityCenter.qml"), encoding="utf-8").read()
ok("log: no array copy per line (logLines is gone)", "logLines" not in sc)
ok("log: lines go into a ListModel in batches", "ListModel { id: logModel }" in sc and "logFlushT" in sc and "logModel.append(b)" in sc)
ok("log: capped", "readonly property int logMax: 200" in sc and "logModel.remove(0, over)" in sc)
ok("log: tone is worked out once per line, not per row", "root.logTone(modelData)" not in sc and "c: logTone(t)" in sc)
ok("log: the list is emptied when the card closes", "onLogOpenChanged: { logClear()" in sc)
ok("firewall page has the sub-pages", all(('{ k: "%s"' % k) in sc for k in ("live", "rules", "feeds", "history", "doctor")) and 'root.fwSub === "rules"' in sc)
ok("firewall and antivirus are greyed, not hidden", "disabled: noFw" in sc and "disabled: noAv" in sc and "if (hasFw || !detected) a.push" not in sc)
ok("a missing module's page can not be opened", "function tabOff(t)" in sc and "if (tabOff(t)) return" in sc)
nav = open(os.path.join(Q, "CalmNav.qml"), encoding="utf-8").read()
ok("CalmNav greys and ignores a disabled item", "readonly property bool off: !!modelData.disabled" in nav and "if (!seg.off) nav.picked" in nav)
ok("FwCenter.qml is gone", not os.path.exists(os.path.join(Q, "FwCenter.qml")))
ok("nothing references the old window", "fwCenter" not in shell and "FwCenter" not in shell)
ok("the firewall command opens the Security center", 'securityCenter.toggleTo("firewall")' in shell)

print(n - bad, "of", n, "checks passed")
sys.exit(1 if bad else 0)
