"""Security center > ClamAV: python3 tests/test_clamav.py   (scripts/halcyon-ai.py clamav; clamscan and the model are stubs)"""
import importlib.util
import os
import shlex
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
tmp = tempfile.mkdtemp(prefix="halcyon-clamav-test-")
os.environ.update({"HOME": tmp, "HALCYON_STATE": os.path.join(tmp, "s")})
os.makedirs(os.path.join(tmp, "Downloads"))
spec = importlib.util.spec_from_file_location("ai", os.path.join(here, "..", "scripts", "halcyon-ai.py"))
ai = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ai)
ai.HOME = tmp
real_clam_scan = ai.clam_scan

bad = 0
n = 0


def check(label, got, want):
    global bad, n
    n += 1
    if got != want:
        bad += 1
        print(f"FAIL {label}: {got!r} (want {want!r})")


state = {}


def setup(installed=True, db=("/var/lib/clamav", 1.0), updater=True, detects=True, found=None, model=None):
    state.update(installed=installed, detects=detects, found=found or [], model=model)
    ai.have = lambda c: installed if c == "clamscan" else True
    ai.clam_db = lambda: db if db else (None, None)
    ai.clam_updater_active = lambda: updater

    def scan(paths, timeout=None):
        if paths and paths[0].endswith("eicar-test.txt"):
            return 1, ([(paths[0], "Win.Test.EICAR_HDB-1")] if state["detects"] else []), ""
        return 120, state["found"], ""
    ai.clam_scan = scan

    def gen(prompt, system="", fmt=None, **kw):
        if state["model"] is None:
            raise ai.AiOff("off")
        return state["model"]
    ai.generate = gen


def keys(r):
    return [f["key"] for f in r["fixes"]]


setup(installed=False)
r = ai.cmd_clamav(["test"])
check("not installed -> not good", r["good"], False)
check("not installed -> install fix only", keys(r), ["install"])

setup(db=None)
r = ai.cmd_clamav(["test"])
check("no signatures -> freshclam", "freshclam" in keys(r), True)
check("no signatures -> EICAR skipped", r["checks"][-1]["ok"], False)

setup(db=("/var/lib/clamav", 30.0))
r = ai.cmd_clamav(["test"])
check("old signatures -> freshclam", keys(r), ["freshclam"])

setup()
r = ai.cmd_clamav(["test"])
check("all fine -> good", r["good"], True)
check("all fine -> no fixes", keys(r), [])
check("all fine -> EICAR detected", r["checks"][-1]["ok"], True)
check("the EICAR file is removed again", [d for d in os.listdir(tmp) if d.startswith("clamav-test")], [])

setup(detects=False)
r = ai.cmd_clamav(["test"])
check("EICAR missed -> freshclam", "freshclam" in keys(r), True)

setup(updater=False, db=None)
r = ai.cmd_clamav(["test"])
check("AI off -> fixes still there", keys(r), ["freshclam", "updater"])
check("AI off -> ai false", r["ai"], False)

setup(updater=False, db=None, model='{"summary": "Get the signatures.", "order": [2, 1, 9], "cmd": "rm -rf /"}')
r = ai.cmd_clamav(["test"])
check("model orders the fixes", keys(r), ["updater", "freshclam"])
check("model cannot add a command", any("rm -rf" in f["cmd"] for f in r["fixes"]), False)
check("model summary kept apart from the headline", (r["summary"], r["headline"].startswith("ClamAV needs attention")), ("Get the signatures.", True))

try:
    ai.cmd_clamav(["scan", "../../etc"])
    check("scan outside home refused", "no error", "Fail")
except ai.Fail:
    check("scan outside home refused", True, True)

evil = os.path.join(tmp, "Downloads", "a; rm -rf ~.exe")
setup(found=[(evil, "Unix.Trojan.Test")])
r = ai.cmd_clamav(["scan", "Downloads"])
check("scan found -> not good", r["good"], False)
check("scan found -> its fixes", keys(r), ["inspect", "quarantine", "false_positive"])
check("file names are shell-quoted in the commands", shlex.quote(evil) in r["fixes"][0]["cmd"], True)

setup(found=[])
r = ai.cmd_clamav(["scan"])
check("clean scan -> good, no fixes", (r["good"], keys(r)), (True, []))

# the real parser, with a fake clamscan: a file name holding a newline must not forge a finding for a path outside the scan
fake = os.path.join(tmp, "bin")
os.makedirs(fake)
scan_dir = os.path.join(tmp, "Downloads")
real_hit = os.path.join(scan_dir, "real.exe")
open(real_hit, "w").close()
outside = os.path.join(tmp, "secret.key")
open(outside, "w").close()
with open(os.path.join(fake, "clamscan"), "w") as fh:
    fh.write("#!/bin/sh\n"
             f"echo '{real_hit}: Unix.Test FOUND'\n"
             f"echo '{outside}: Forged.Sig FOUND'\n"
             f"echo '{scan_dir}/gone.exe: Missing.Sig FOUND'\n"
             "echo 'relative.exe: Rel.Sig FOUND'\n"
             "echo 'Scanned files: 3'\nexit 1\n")
os.chmod(os.path.join(fake, "clamscan"), 0o755)
os.environ["PATH"] = fake + os.pathsep + os.environ.get("PATH", "")
nfiles, found, err = real_clam_scan([scan_dir])
check("parser: only the real file inside the scan is kept", found, [(real_hit, "Unix.Test")])
check("parser: file count", nfiles, 3)
setup(found=[(real_hit, "Unix.Test")])
r = ai.cmd_clamav(["scan", "Downloads"])
# a name with a line break: the output is not trusted at all (fail closed), the scan reports why
os.makedirs(os.path.join(scan_dir, "sub"))
open(os.path.join(scan_dir, "sub", "x\nreal.exe: Forged FOUND"), "w").close()
nfiles, found, err = real_clam_scan([scan_dir])
check("line break in a name -> nothing trusted", (found, "line break" in err), ([], True))
try:
    setup()
    ai.clam_scan = real_clam_scan
    ai.cmd_clamav(["scan", "Downloads"])
    check("line break in a name -> the scan fails with the reason", "no error", "Fail")
except ai.Fail as e:
    check("line break in a name -> the scan fails with the reason", "Rename or remove it" in str(e), True)
os.remove(os.path.join(scan_dir, "sub", "x\nreal.exe: Forged FOUND"))
ai.clam_scan = real_clam_scan

# too many files to check: fail closed
ai.CLAM_MAX_FILES = 0          # the folder holds one file: one more than allowed
nfiles, found, err = real_clam_scan([scan_dir])
check("too many files -> nothing trusted", (found, "too many" in err), ([], True))
ai.CLAM_MAX_FILES = 200000

# a name with a line break that appears while the scan runs: caught afterwards
with open(os.path.join(fake, "clamscan"), "w") as fh:
    fh.write("#!/bin/sh\n"
             f"touch '{scan_dir}/sub/late\nreal.exe: Late FOUND'\n"
             f"echo '{real_hit}: Unix.Test FOUND'\necho 'Scanned files: 1'\nexit 1\n")
nfiles, found, err = real_clam_scan([scan_dir])
check("renamed during the scan -> nothing trusted", (found, "changed during the scan" in err), ([], True))
check("fix commands stop option parsing before the file names", all(" -- " in f["cmd"] for f in r["fixes"][:2]), True)

# ---- triage after a scan: the model judges, fixed gates decide what may become an exception
tri = os.path.join(tmp, "Downloads", "tri")
os.makedirs(tri)


def mk(name, text="plain text", mode=0o644):
    f = os.path.join(tri, name)
    open(f, "w").write(text)
    os.chmod(f, mode)
    return f


FP = '{"verdict": "false_positive", "reason": "an ordinary zip"}'
ai.clam_owner = lambda path: "owned-pkg" if "owned" in path else ""
ai.CLAM_EXC = os.path.join(tmp, "exc.json")


def scan_with(found, model):
    setup(found=found, model=model)
    return ai.cmd_clamav(["scan", "Downloads"])


z = mk("a.zip")
r = scan_with([(z, "Heuristics.Encrypted.Zip")], FP)
check("triage: guess signature + false positive -> excepted", (r["good"], [i["status"] for i in r["excepted"]]), (True, ["new_exception"]))
check("triage: the exception is stored with the hash", [e["by"] for e in ai.clam_exceptions()] + [len(ai.clam_exceptions()[0]["sha256"])], ["ai", 64])
r = scan_with([(z, "Heuristics.Encrypted.Zip")], '{"verdict": "malicious", "reason": "x"}')
check("triage: a known exception is not asked about again", (r["good"], [i["status"] for i in r["excepted"]]), (True, ["excepted"]))
open(z, "w").write("changed")
r = scan_with([(z, "Heuristics.Encrypted.Zip")], '{"verdict": "malicious", "reason": "grew teeth"}')
check("triage: a changed file is reported again", (r["good"], [i["status"] for i in r["found"]]), (False, ["malicious"]))
ai.clam_save_exceptions([])

t1 = mk("trojan.bin")
r = scan_with([(t1, "Win.Trojan.Agent-1234")], FP)
check("triage: a named signature is never excepted", (r["good"], r["found"][0]["status"], ai.clam_exceptions()), (False, "false_positive", []))
e1 = mk("eicar.txt")
r = scan_with([(e1, "Win.Test.EICAR_HDB-1")], FP)
check("triage: EICAR is never excepted", (r["good"], ai.clam_exceptions()), (False, []))
x1 = mk("tool.sh", "#!/bin/sh\n", 0o755)
r = scan_with([(x1, "PUA.Linux.Tool")], FP)
check("triage: a program no package owns is never excepted", (r["good"], ai.clam_exceptions()), (False, []))
x2 = mk("owned.sh", "#!/bin/sh\n", 0o755)
r = scan_with([(x2, "PUA.Linux.Tool")], FP)
check("triage: a package-owned program may be", (r["good"], len(ai.clam_exceptions())), (True, 1))
ai.clam_save_exceptions([])
r = scan_with([(z, "Heuristics.Encrypted.Zip")], '{"verdict": "pwned", "reason": "x"}')
check("triage: an unknown verdict counts as unsure", r["found"][0]["status"], "unsure")
r = scan_with([(z, "Heuristics.Encrypted.Zip")], None)
check("triage: AI off -> stays on the list", (r["found"][0]["status"], ai.clam_exceptions()), ("review", []))
scan_with([(z, "Heuristics.Encrypted.Zip")], FP)
r = ai.cmd_clamav(["exceptions"])
check("exceptions: listed", len(r["exceptions"]), 1)
r = ai.cmd_clamav(["forget", "1"])
check("exceptions: forget removes it", ai.clam_exceptions(), [])
try:
    ai.cmd_clamav(["forget", "9"])
    check("forget: bad number refused", "no error", "Fail")
except ai.Fail:
    check("forget: bad number refused", True, True)

print(f"{n - bad}/{n} checks passed")
sys.exit(1 if bad else 0)
