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
check("fix commands stop option parsing before the file names", all(" -- " in f["cmd"] for f in r["fixes"][:2]), True)

print(f"{n - bad}/{n} checks passed")
sys.exit(1 if bad else 0)
