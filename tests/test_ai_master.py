#!/usr/bin/env python3
"""The master AI switch (Settings > AI > AI features) covers every AI feature: python3 tests/test_ai_master.py
Runs the scripts with a throw-away HOME that has the ai-off flag, and reads the QML as text (no Qt needed)."""
import json, os, re, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE); S = os.path.join(ROOT, "scripts"); Q = os.path.join(ROOT, "quickshell", "island")
home = tempfile.mkdtemp(); os.makedirs(os.path.join(home, ".local", "state", "island"))
flag = os.path.join(home, ".local", "state", "island", "ai-off")
env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=os.path.join(home, ".config"), XDG_STATE_HOME=os.path.join(home, ".local", "state"))
n = 0
def ok(name, cond):
    global n
    if not cond: print("FAIL", name); sys.exit(1)
    n += 1; print("ok  ", name)
def run(*a, stdin=None): return subprocess.run(a, input=stdin, capture_output=True, text=True, env=env, timeout=30)

open(flag, "w").write("off\n")
r = run("python3", os.path.join(S, "halcyon-aichat.py"), "stream", stdin=json.dumps({"prompt": "hi", "provider": "openai"}))
ok("chatbox refuses a hosted provider while the switch is off", r.returncode == 1 and "switched off" in r.stdout)
r = run("python3", os.path.join(S, "halcyon-aichat.py"), "stream", stdin=json.dumps({"prompt": "hi", "provider": "ollama"}))
ok("chatbox refuses Ollama while the switch is off", r.returncode == 1 and "switched off" in r.stdout)
r = run("python3", os.path.join(S, "halcyon-aichat.py"), "status")
ok("chatbox status says the switch is off", json.loads(r.stdout).get("aiOff") is True)
r = run("python3", os.path.join(S, "halcyon-study.py"), "ask", "x")
ok("Study Center ask is refused", r.returncode == 3 or "switched off" in (r.stdout + r.stderr))
r = run("bash", os.path.join(S, "av-ai-idle.sh"), "status")
ok("antivirus analyzer reports off while the switch is off", r.stdout.strip() == "off")
os.unlink(flag)
r = run("python3", os.path.join(S, "halcyon-aichat.py"), "status")
ok("chatbox status says on when the flag is gone", json.loads(r.stdout).get("aiOff") is False)

src = open(os.path.join(Q, "Settings.qml"), encoding="utf-8").read()
ok("master switch is on the AI page", re.search(r'\{ id: "AI", sub: "[^"]*", groups: \["aimaster"', src) is not None)
ok("no message still points at Settings > Performance > AI", not any("Performance > AI" in open(os.path.join(dp, f), encoding="utf-8", errors="ignore").read()
   for base in (S, Q) for dp, _, fs in os.walk(base) for f in fs if f.endswith((".py", ".sh", ".qml"))))
ok("security and firewall Ask boxes check aiOn", all("!aiOn" in open(os.path.join(Q, f), encoding="utf-8").read() for f in ("SecurityCenter.qml", "FwCenter.qml")))
ok("every aiCovers row has a component", "SetAiCovers" in src and os.path.exists(os.path.join(Q, "SetAiCovers.qml")))
print(n, "passed")
