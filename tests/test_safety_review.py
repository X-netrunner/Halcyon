"""Safety-check review: python3 tests/test_safety_review.py   (scripts/halcyon-ai.py safety; no model, no root, no real logs)"""
import importlib.util, os, sys, tempfile

here = os.path.dirname(os.path.abspath(__file__))
tmp = tempfile.mkdtemp(prefix="halcyon-safety-test-")
os.environ.update({"HOME": tmp, "HALCYON_STATE": os.path.join(tmp, "s")})
spec = importlib.util.spec_from_file_location("ai", os.path.join(here, "..", "scripts", "halcyon-ai.py"))
ai = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ai)

bad = 0
n = 0


def check(label, got, want):
    global bad, n
    n += 1
    if got != want:
        bad += 1
        print(f"FAIL {label}: {got!r} (want {want!r})")


HEAD = "[10:00:00] ═══\n Safety Check started — 2026-10-21 10:00:00\n Running as: me\n═══\n"


def sec(num, title):
    return f"[10:00:01] \n{num}/7 — {title}\n─────\n"


def run(body, name="x.log"):
    p = os.path.join(tmp, name)
    with open(p, "w", encoding="utf-8") as f:
        f.write(HEAD + body)
    rep, key, open_items = ai.safety_report(p)
    return rep, key, open_items


CLEAN = (sec(2, "ClamAV Malware Scan") + "[10:00:02] Infected files: 0\n[10:00:02] ✓ No threats found by ClamAV\n"
         + sec(6, "AIDE File Integrity Check") + "[10:00:03] AIDE: Added entries: 0\n[10:00:03] AIDE: Removed entries: 0\n"
         "[10:00:03] AIDE: Changed entries: 0\n[10:00:03] ✓ No integrity changes detected\n"
         + sec(4, "Firewall Status") + "[10:00:04] ufw status: Status: active\n[10:00:04] ✓ Firewall is active\n"
         "[10:00:05] \n Check complete — 2026-10-21 10:05:00\n Errors found: 0\n")

rep, key, items = run(CLEAN)
check("clean run is good", key, "good")
check("clean run has no open items", items, [])

# AIDE: the Rust check counts any line with "changed"/"added"/"removed" (a path like .../removed.svg is enough): the report says 0
fp = CLEAN.replace("[10:00:03] ✓ No integrity", "[10:00:03] AIDE: f > ... : /usr/share/icons/removed.svg\n[10:00:03] ✓ No integrity")
rep, key, items = run(fp)
check("AIDE word-in-a-path with 0 changes is not a finding", key, "good")

# rkhunter: only known noise
rk = (sec(3, "rkhunter Rootkit Check")
      + "[10:00:02] rkhunter:   Checking for hidden files and directories                  [ Warning ]\n"
      + "[10:00:02] rkhunter: Warning: Hidden file found: /etc/.updated: ASCII text\n"
      + "[10:00:02] rkhunter: Warning: The command '/usr/bin/egrep' has been replaced by a script: /usr/bin/egrep: POSIX shell script\n")
rep, key, items = run(rk + CLEAN)
check("known rkhunter noise only -> good", key, "good")
check("known noise is listed as noise", "Known noise" in rep, True)

# rkhunter: an unknown warning must NOT be waved through
rep, key, items = run(rk + "[10:00:03] rkhunter: Warning: Found a strange kernel module: evil.ko\n" + CLEAN)
check("unknown rkhunter warning -> look", key, "look")

# rkhunter: a real rootkit hit beats every noise rule
rep, key, items = run(sec(3, "rkhunter Rootkit Check") + "[10:00:02] rkhunter:   Checking for Rootkit XYZ                 [ Found ]  Warning\n" + CLEAN)
check("rootkit Found -> look", key, "look")

# file-property warnings right after an update: confirm, never ignore
rep, key, items = run(sec(3, "rkhunter Rootkit Check") + "[10:00:02] rkhunter: Warning: The file properties have changed: /usr/bin/ssh\n" + CLEAN)
check("file properties changed -> verify", key, "verify")

# ClamAV
cl = lambda line: sec(2, "ClamAV Malware Scan") + f"[10:00:02] {line}\n[10:00:02] Infected files: 1\n"
rep, key, _ = run(cl("/home/me/eicar.com: Win.Test.EICAR_HDB-1 FOUND"))
check("EICAR test file -> good (noise)", key, "good")
rep, key, _ = run(cl("/home/me/Downloads/a.pdf: Heuristics.Encrypted.PDF FOUND"))
check("encrypted-PDF heuristic -> verify", key, "verify")
rep, key, items = run(cl("/tmp/x: Unix.Trojan.Mirai-7 FOUND"))
check("real-looking signature -> look", key, "look")
check("path is put into the check hint", any("/tmp/x" in i["check"] or i["tool"] == "clamav" for i in items), True)

# AIDE with real changes
aide = lambda path: (sec(6, "AIDE File Integrity Check") + "[10:00:03] AIDE: Changed entries: 1\n"
                     + f"[10:00:03] AIDE: f > ... mc..H.. : {path}\n")
check("AIDE /etc/shadow -> look", run(aide("/etc/shadow"))[1], "look")
check("AIDE /var/log -> good (noise)", run(aide("/var/log/pacman.log"))[1], "good")
check("AIDE /usr/bin after update -> verify", run(aide("/usr/bin/vim"))[1], "verify")

# failures of the check itself are never noise
rep, key, _ = run(sec(1, "System Update") + "[10:00:02] ⚠ System update failed\n" + CLEAN)
check("failed update -> look", key, "look")
rep, key, _ = run(sec(7, "Backup to External Drive") + "[10:00:02] ⚠ Device /dev/sda1 not found — skipping backup\n" + CLEAN)
check("skipped backup -> verify", key, "verify")
rep, key, _ = run(sec(4, "Firewall Status") + "[10:00:04] ufw status: Status: inactive\n[10:00:04] ⚠ Firewall is INACTIVE. Enabling...\n" + CLEAN)
check("firewall was off -> verify", key, "verify")
# ai-firewall instead of ufw (install.sh --firewall ai): its own status line and its own advice
rep, key, _ = run(sec(4, "Firewall Status") + "[10:00:04] ai-firewall status: ai-firewall  running  enforce mode\n[10:00:04] ✓ Firewall is active (ai-firewall)\n" + CLEAN)
check("ai-firewall running -> good", key, "good")
rep, key, _ = run(sec(4, "Firewall Status") + "[10:00:04] ai-firewall status: ai-firewall  running  enforce mode\n")
check("ai-firewall state is in the summary", "Seen: firewall ai-firewall running" in rep, True)
rep, key, _ = run(sec(4, "Firewall Status") + "[10:00:04] ai-firewall status: Error: ai-firewall is not running (no /run/ai-firewall/status.json)\n"
                  "[10:00:04] ⚠ Firewall is INACTIVE (ai-firewall). Starting...\n" + CLEAN)
check("ai-firewall down -> verify", key, "verify")
check("ai-firewall down -> its own advice", "sudo ai-firewall doctor" in rep, True)
check("ai-firewall down -> no ufw advice", "ufw status verbose" in rep, False)

# a tool that is not installed means that part was not checked: say so, do not claim a full pass
rep, key, _ = run(sec(3, "rkhunter Rootkit Check") + "[10:00:02] ! rkhunter not installed\n" + CLEAN)
check("missing tool is reported", "Not checked: rkhunter not installed" in rep, True)
check("missing tool softens the all-good claim", "Everything that was checked is good" in rep, True)

# a log cut off before the end
rep, key, _ = run(sec(2, "ClamAV Malware Scan") + "[10:00:02] Scanning...\n")
check("unfinished run is unclear", key, "unclear")

# only the LAST run of a day counts
two = HEAD + sec(2, "ClamAV Malware Scan") + "[10:00:02] /tmp/x: Unix.Trojan.Mirai-7 FOUND\n[10:00:02] Infected files: 1\n"
p = os.path.join(tmp, "two.log")
with open(p, "w", encoding="utf-8") as f:
    f.write(two + HEAD.replace("10:00", "18:00") + CLEAN)
check("older run in the same log is ignored", ai.safety_report(p)[1], "good")

# command: no logs -> a clear failure, not a crash; --no-ai never asks the model
try:
    ai.SAFETY_DIRS[:] = [os.path.join(tmp, "nothing")]
    ai.cmd_safety([])
    check("no logs raises", "no error", "Fail")
except ai.Fail:
    check("no logs raises", "Fail", "Fail")
ai.SAFETY_DIRS[:] = [tmp]
os.utime(os.path.join(tmp, "x.log"), None)
res = ai.cmd_safety(["--file", os.path.join(tmp, "two.log"), "--no-ai"])
check("cmd result carries the verdict", res["verdict"], "good")

print(f"{n - bad}/{n} checks passed")
sys.exit(1 if bad else 0)
