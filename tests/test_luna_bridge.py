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
case "$1" in --help) echo "      --stdio"; exit 0;; esac
ALL="$*"; H=""; while [ $# -gt 0 ]; do [ "$1" = "--history" ] && { H="$2"; shift; }; shift; done; ARGV="$ALL"
n=0
while IFS= read -r line; do
  case "$line" in
    *'"quit"'*) exit 0;;
    *'"settings_get"'*) echo '{"type":"ready"}'; echo '{"type":"settings","categories":[],"keys":[{"name":"tavily","set":false}],"models":{}}';;
    *'"models"'*) echo '{"type":"models","reachable":true,"installed":[{"name":"m:1b","gb":1.0}],"roles":{"model":"m:1b"}}';;
    *'"setting_set"'*) echo "$line" >> "$(dirname "$H")/.received"; echo '{"type":"saved","key":"k","value":true}';;
    *'"model_set"'*) case "$line" in *nope*) echo '{"type":"error","error":"Ollama does not have nope"}';; *) echo '{"type":"saved","key":"model.model","value":"x"}';; esac;;
    *'"key_set"'*) echo "$line" >> "$(dirname "$H")/.received"; echo "ARGV: $ARGV" >> "$(dirname "$H")/.received"; echo '{"type":"key_saved","name":"tavily","where":"keyring"}';;
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
# settings, models, model, keys, clear
code, out = run("settings")
check("settings: the first answer of type settings", (code, json.loads(out)["type"], json.loads(out)["keys"][0]["name"]), (0, "settings", "tavily"))
check("models", json.loads(run("models")[1])["roles"]["model"], "m:1b")
code, out = run("set", "external.allow_halcyon_actions", "true")
check("set sends the JSON value", (code, json.loads(out)["type"]), (0, "saved"))
check("model: a name Ollama lacks is an error event, exit 0 for the caller to show it", json.loads(run("model", "nope")[1])["type"], "error")
check("model: ok", json.loads(run("model", "x", "fast")[1])["type"], "saved")
sys.stdin = io.StringIO("sk-test-123456\n")
code, out = run("key", "tavily")
rec = open(os.path.join(lb.DATA, ".received")).read()
check("key: stored, and the answer never contains the key", (code, json.loads(out)["type"], "sk-test" in out), (0, "key_saved", False))
check("key: it reached Luna on stdin", '"value": "sk-test-123456"' in rec, True)
check("key: it was not in Luna's arguments", "sk-test" in rec.split("ARGV:")[-1], False)
run("chat", sid, "--json", "--", "one more")
run("clear", sid)
check("clear empties the session but keeps it", (json.load(open(lb.path(sid)))["turns"], os.path.exists(lb.path(sid, hist=True))), ([], False))
check("status: a Luna with --stdio is ready", json.loads(run("status", "--json")[1])["ok"], True)
old_luna = os.path.join(tmp, "oldluna")
open(old_luna, "w").write("#!/bin/sh\necho 'usage: luna [OPTIONS]'\n")
os.chmod(old_luna, 0o755)
os.environ["HALCYON_LUNA_BIN"] = old_luna
st = json.loads(run("status", "--json")[1])
check("status: a Luna without --stdio is flagged old, not ready", (st["old"], st["ok"]), (True, False))
os.environ["HALCYON_LUNA_BIN"] = fake
run("delete", sid)
check("delete removes both files", [f for f in os.listdir(lb.DATA) if f.startswith(sid)], [])
print(f"{n - bad}/{n} checks passed")
sys.exit(1 if bad else 0)
