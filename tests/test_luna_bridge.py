"""Luna window's sessions: python3 tests/test_luna_bridge.py   (scripts/halcyon-luna.py with a fake `luna --stdio`; nothing real is started)"""
import importlib.util
import io
import json
import os
import stat
import sys
import tempfile
from contextlib import redirect_stdout

here = os.path.dirname(os.path.abspath(__file__))
tmp = tempfile.mkdtemp(prefix="halcyon-luna-test-")
fake = os.path.join(tmp, "luna")
with open(fake, "w") as fh:
    fh.write('''#!/bin/sh
H=""; while [ $# -gt 0 ]; do [ "$1" = "--history" ] && { H="$2"; shift; }; shift; done
n=0
while IFS= read -r line; do
  case "$line" in
    *'"quit"'*) exit 0;;
    *'"turn"'*) n=$((n+1))
      echo '{"type":"thinking","delta":"hm "}'; echo '{"type":"thinking","delta":"ok"}'
      echo '{"type":"activity","kind":"tool_start","name":"run_shell","summary":"ls"}'; echo 'stray line from a tool'
      case "$line" in *boom*) echo '{"type":"error","error":"model failed"}';; *)
        echo "{\\"type\\":\\"reply\\",\\"text\\":\\"seen $(wc -c < "$H" 2>/dev/null || echo 0) bytes\\",\\"thinking\\":null,\\"model\\":\\"fake:1b\\",\\"secs\\":0.1}"
        echo "[1,2,3]" >> "$H";;
      esac;;
  esac
done
''')
os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)
os.environ.update({"HOME": tmp, "XDG_DATA_HOME": os.path.join(tmp, "d"), "HALCYON_LUNA_BIN": fake})
spec = importlib.util.spec_from_file_location("lb", os.path.join(here, "..", "scripts", "halcyon-luna.py"))
lb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lb)
bad = n = 0


def check(label, got, want):
    global bad, n
    n += 1
    if got != want:
        bad += 1
        print(f"FAIL {label}: {got!r} (want {want!r})")


def run(*a):
    buf = io.StringIO()
    with redirect_stdout(buf):
        code = lb.main(["x", *a])
    return code, buf.getvalue()


code, out = run("new")
sid = out.strip()
check("new session id is valid", lb.valid_id(sid), True)
code, out = run("chat", sid, "--json", "--", "hello luna, how are you today")
evs = [json.loads(l) for l in out.splitlines()]
check("a stray line from a tool is ignored", [e["type"] for e in evs], ["thinking", "activity", "reply", "done"])
check("reasoning arrives in one piece", evs[0]["delta"], "hm ok")
check("the first turn sees no history", evs[2]["text"], "seen 0 bytes")
code, out = run("chat", sid, "--json", "--", "and again")
check("the second turn gets the same history file", json.loads(out.splitlines()[-2])["text"].startswith("seen ") and "seen 0 " not in out, True)
s = json.load(open(lb.path(sid)))
check("both turns are saved", [t["role"] for t in s["turns"]], ["you", "luna", "you", "luna"])
check("the title is the first question", s["title"], "hello luna, how are you today")
check("the tool Luna used is kept with its answer", s["turns"][1]["tools"][0]["name"], "run_shell")
code, out = run("chat", sid, "--json", "--", "boom")
check("a failed turn exits 1 and says why", (code, "model failed" in out), (1, True))
check("a failed turn is saved as a bad answer", json.load(open(lb.path(sid)))["turns"][-1].get("bad"), True)
code, out = run("rename", sid, "Renamed chat")
check("rename", json.loads(run("list", "--json")[1])["sessions"][0]["title"], "Renamed chat")
check("list counts the turns", json.loads(run("list", "--json")[1])["sessions"][0]["count"], 6)
check("a path is not a session id", run("show", "../../etc/passwd")[0], 1)
code, out = run("chat", sid, "--json", "--", "   ")
check("an empty question is refused", code, 1)
open("/dev/shm/halcyon-gamemode.test", "w").close()
lb.GAMING_FLAG = "/dev/shm/halcyon-gamemode.test"
code, out = run("chat", sid, "--json", "--", "hi")
os.remove("/dev/shm/halcyon-gamemode.test")
check("gaming mode: exit 3, nothing started", (code, json.loads(out).get("off")), (3, True))
lb.GAMING_FLAG = "/nonexistent"
os.environ["HALCYON_LUNA_BIN"] = "/nonexistent"
check("Luna missing: exit 3", run("chat", sid, "--json", "--", "hi")[0], 3)
os.environ["HALCYON_LUNA_BIN"] = fake
run("delete", sid)
check("delete removes both files", [f for f in os.listdir(lb.DATA) if f.startswith(sid)], [])
print(f"{n - bad}/{n} checks passed")
sys.exit(1 if bad else 0)
