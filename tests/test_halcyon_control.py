"""Luna's Halcyon tools: python3 tests/test_halcyon_control.py   (scripts/halcyon-control.py; the island and every program are stubbed)"""
import importlib.util
import io
import json
import os
import sys
import tempfile
from contextlib import redirect_stderr, redirect_stdout

here = os.path.dirname(os.path.abspath(__file__))
tmp = tempfile.mkdtemp(prefix="halcyon-control-test-")
os.environ.update({"HOME": tmp, "HALCYON_STATE": os.path.join(tmp, "s"), "HALCYON_DIR": os.path.join(here, "..")})
spec = importlib.util.spec_from_file_location("hc", os.path.join(here, "..", "scripts", "halcyon-control.py"))
hc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hc)
bad = n = 0
calls = []


def check(label, got, want):
    global bad, n
    n += 1
    if got != want:
        bad += 1
        print(f"FAIL {label}: {got!r} (want {want!r})")


def fake_run(argv, timeout=20, sudo=False, input_text=None):
    calls.append(("run", list(argv), sudo))
    return 0, "ok"


def fake_island(*call):
    calls.append(("island", list(call), False))
    return ""


hc.run = fake_run
hc.island = fake_island
hc.shutil.which = lambda c: "/usr/bin/" + c


def go(*args):
    calls.clear()
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = hc.main(["x", *args])
    return code, out.getvalue() + err.getvalue()


code, out = go("info", "open", "settings")
check("a do action under info is refused, and says which tier", (code, "do action" in out, calls), (3, True, []))
code, out = go("do", "fw-ban", "1.2.3.4")
check("a security action under do is refused", (code, calls), (3, []))
code, out = go("security", "gaming", "on")
check("a do action under security is refused", (code, calls), (3, []))
code, out = go("info", "nothing")
check("an unknown action is a failure with the list", (code, "overview" in out), (1, True))

code, out = go("do", "open", "../../etc")
check("open: only known command ids", code, 1)
code, out = go("do", "open", "study")
check("open: a known id goes to the island", (code, calls), (0, [("island", ["command", "study"], False)]))
code, out = go("do", "set", "opt:uiStyle", "legacy")
check("set opt: goes to setopt as JSON", calls, [("island", ["setopt", "uiStyle", '"legacy"'], False)])
code, out = go("do", "set", "opt:hideHints", "true")
check("set opt: a JSON value stays JSON", calls[-1][1], ["setopt", "hideHints", "true"])
code, out = go("do", "set", "opt:../x", "1")
check("set: a bad key is refused", code, 1)
code, out = go("do", "set", "hy:gaps", "3")
check("set: other key kinds are not changeable from here", code, 1)
code, out = go("do", "gaming", "maybe")
check("gaming needs on or off", code, 1)
code, out = go("do", "note", "add", "buy milk")
check("note add", (code, calls[-1][1][-2:]), (0, ["add", "buy milk"]))
code, out = go("do", "note", "del", "1; rm -rf ~")
check("note del takes an id only", code, 1)
code, out = go("do", "connect-calendar", "file:///etc/passwd")
check("a calendar address must be https", code, 1)

for ip in ("1.2.3.4", "2001:db8::1"):
    code, out = go("security", "fw-ban", ip)
    check(f"fw-ban {ip} runs ai-firewall with admin rights", (code, calls[-1][1], calls[-1][2]), (0, ["ai-firewall", "ban", ip], True))
for evil in ("--help", "1.2.3.4; reboot", "$(id)", ""):
    code, out = go("security", "fw-ban", evil)
    check(f"fw-ban refuses {evil!r}", (code, calls), (1, []))
code, out = go("security", "fw-open", "tcp", "22")
check("fw-open", calls[-1][1], ["ai-firewall", "open", "tcp", "22"])
code, out = go("security", "fw-open", "icmp", "22")
check("fw-open: protocol is tcp or udp", code, 1)
code, out = go("security", "av-exception", "add", "program", "/")
check("av-exception: not a broad path", code, 1)
code, out = go("security", "av-exception", "add", "folder", HOME_ := os.path.expanduser("~"))
check("av-exception: not the whole home folder", code, 1)
code, out = go("security", "av-exception", "add", "program", "/opt/tool/run", "My tool")
check("av-exception: one exact path, named", (code, calls[-1][1]), (0, ["ai-antivirus", "exceptions", "add", "--name", "My tool", "program", "/opt/tool/run"]))
code, out = go("security", "av-ack", "3", "4")
check("av-ack by id", calls[-1][1], ["ai-antivirus", "ack", "3", "4"])
code, out = go("security", "av-ack", "3;4")
check("av-ack: ids are numbers", code, 1)

# the admin password travels in the environment and on stdin of `sudo -S`, never in the arguments
captured = {}
real_run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(real_run)


class R:
    returncode = 0
    stdout = "done"
    stderr = ""


def fake_sub(argv, **kw):
    captured.update(argv=argv, input=kw.get("input"))
    return R()


real_run.subprocess.run = fake_sub
os.environ["LUNA_SUDO"] = "s3cret-pass"
real_run.os.geteuid = lambda: 1000
real_run.run(["ai-firewall", "ban", "1.2.3.4"], sudo=True)
check("sudo -S, the password is on stdin", (captured["argv"][:4], captured["input"]), (["sudo", "-S", "-p", ""], "s3cret-pass\n"))
check("the password is not in any argument", any("s3cret" in a for a in captured["argv"]), False)
del os.environ["LUNA_SUDO"]
real_run.run(["ai-firewall", "ban", "1.2.3.4"], sudo=True)
check("no password: sudo -n (fails instead of hanging)", captured["argv"][:2], ["sudo", "-n"])

code, out = go("help")
check("help lists every tier", all(f"[{t}]" in out for t in hc.TIERS), True)
code, out = go("manual")
check("the manual names all three tools", all(t in out for t in ("halcyon_info", "halcyon_do", "halcyon_security")), True)
print(f"{n - bad}/{n} checks passed")
sys.exit(1 if bad else 0)
