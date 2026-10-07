#!/usr/bin/env python3
# Per-attacker dossier built from the honeypot logs.
# Re-written in Rust for speed & lightweight execution.
import os
import sys

_DIR = os.path.dirname(os.path.abspath(__file__))
_CANDIDATES = [
    os.path.join(_DIR, "attacker-dossier"),
    os.path.expanduser("~/CustomHyprScripts/attacker-dossier/target/release/attacker-dossier"),
]
for _bin in _CANDIDATES:
    if os.path.isfile(_bin) and os.access(_bin, os.X_OK):
        os.execv(_bin, [_bin] + sys.argv[1:])

import collections
import datetime
import json
import os
import re
import sys

LOGS = os.path.expanduser("~/logs")
ANY_IP = re.compile(r"\b(\d{1,3}(?:\.\d{1,3}){3})\b")


def ts(t):
    if not t:
        return "-"
    try:
        d = datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))
        return d.astimezone().strftime("%m-%d %H:%M")
    except Exception:
        return t[:16]


def clean(s):
    return re.sub(r"[\x00-\x1f\x7f]", "?", s)


def load_cowrie():
    agg = collections.defaultdict(lambda: {"sessions": 0, "logins": collections.Counter(), "cmds": [], "last": ""})
    login_events = []
    p = os.path.join(LOGS, "cowrie", "cowrie.json")
    if not os.path.isfile(p):
        return agg, login_events
    with open(p, "r", errors="replace") as f:
        for line in f:
            try:
                e = json.loads(line)
            except Exception:
                continue
            ip, ev = e.get("src_ip"), e.get("eventid")
            if not ip or not ev:
                continue
            d = agg[ip]
            t = e.get("timestamp") or ""
            if ev == "cowrie.session.connect":
                d["sessions"] += 1
            elif ev == "cowrie.login.success":
                d["logins"][(e.get("username"), e.get("password"))] += 1
                login_events.append((ip, e.get("username"), e.get("password"), t))
            elif ev == "cowrie.command.input":
                c = e.get("input")
                if c and (not d["cmds"] or d["cmds"][-1] != c):
                    d["cmds"].append(c)
            if t > d["last"]:
                d["last"] = t
    return agg, login_events


def load_recon():
    agg = collections.defaultdict(lambda: collections.Counter())
    p = os.path.join(LOGS, "recon-attempts.log")
    if not os.path.isfile(p):
        return agg
    with open(p, "rb") as f:
        text = f.read().decode("utf-8", "replace")
    for line in text.splitlines():
        if "[ALERT]" not in line:
            continue
        m = ANY_IP.search(line)
        if not m:
            continue
        ip = m.group(1)
        label = re.sub(r"^\[[^\]]*\]\s*\[ALERT\]\s*", "", line.strip())
        label = re.sub(
            r"\s*\b(?:from|Source IP|Banning IP)\s+\d{1,3}(?:\.\d{1,3}){3}\b", "", label
        )
        agg[ip][clean(label)] += 1
    return agg


def main():
    target_ip = sys.argv[1].strip() if len(sys.argv) > 1 else None
    cow, login_events = load_cowrie()
    recon = load_recon()

    if target_ip:
        print(f"=== Detailed Attacker Dossier for IP: {target_ip} ===")
        c = cow.get(target_ip) or {"sessions": 0, "logins": collections.Counter(), "cmds": [], "last": ""}
        r = recon.get(target_ip) or collections.Counter()
        print(f"  Total Cowrie SSH Sessions : {c['sessions']}")
        print(f"  Last Cowrie Hit           : {ts(c['last'])}")
        if c["logins"]:
            creds = ", ".join(f"{u}:{p}" for (u, p), _ in c["logins"].most_common(10))
            print(f"  Captured SSH Credentials  : {clean(creds)}")
        if c["cmds"]:
            print("  Executed Shell Commands   :")
            for cmd in c["cmds"]:
                print(f"    $ {clean(cmd)}")
        if r:
            print("  Decoy Port Activity       :")
            for k, v in r.most_common():
                print(f"    - {k} (x{v})")

        scan_log = os.path.join(LOGS, "attacker-scans.log")
        if os.path.isfile(scan_log):
            print("\n  Counter-Scan Intel        :")
            with open(scan_log, "r", errors="replace") as f:
                content = f.read()
                if target_ip in content:
                    blocks = content.split("===== COUNTER-SCAN")
                    for b in blocks:
                        if target_ip in b:
                            lines = [ln for ln in b.splitlines() if ln.strip()]
                            for ln in lines[:10]:
                                print(f"    {ln}")
                else:
                    print("    No counter-scan data recorded for this IP.")
        return

    print("=== Cowrie SSH Honeypot ===")
    sess = sum(d["sessions"] for d in cow.values())
    logn = sum(sum(d["logins"].values()) for d in cow.values())
    cmds = sum(len(d["cmds"]) for d in cow.values())
    print(f"  sessions {sess}   logins captured {logn}   commands {cmds}")
    for ip, u, p, t in login_events[-6:]:
        print(f"    {u}:{p}  @ {ip}  {ts(t)}")

    print("\n=== Attacker Dossiers (by activity) ===")
    ips = set(cow) | set(recon)
    if not ips:
        print("  No attacker activity yet.")
        return
    rows = []
    for ip in ips:
        c = cow.get(ip) or {"sessions": 0, "logins": collections.Counter(), "cmds": [], "last": ""}
        r = recon.get(ip) or collections.Counter()
        total = c["sessions"] + sum(c["logins"].values()) + len(c["cmds"]) + sum(r.values())
        rows.append((ip, total, c, r))
    rows.sort(key=lambda x: x[1], reverse=True)
    for ip, total, c, r in rows:
        print(f"\n  {ip}   activity: {total}   (last cowrie hit {ts(c['last'])})")
        if c["logins"]:
            creds = ", ".join(f"{u}:{p}" for (u, p), _ in c["logins"].most_common(5))
            print(f"    SSH creds:  {clean(creds)}")
        if c["cmds"]:
            print(f"    Commands:   {', '.join(c['cmds'][:6])}")
        if r:
            for k, v in r.most_common(5):
                print(f"    decoy:      {k}  (x{v})")


if __name__ == "__main__":
    main()
