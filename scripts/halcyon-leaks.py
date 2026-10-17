#!/usr/bin/env python3
"""halcyon-leaks.py : read a halcyon-leak-watch.sh log and say what leaked, what jumped, and what is just noise.

  halcyon-leaks.py [LOG] [--json]        default LOG: ~/.cache/island/leak-watch.log

The arithmetic is done HERE (a small local model is bad at it and at telling "one jump" from "steady leak");
`advisor leaks` then hands the findings to the LLM only to explain them and pick next steps.

Log format (made by halcyon-leak-watch.sh), one block per sample:
  T <epoch>                      Z <zombies>                   C <name> <count>      (processes per program name)
  D <name>|<pid>|<ppid>|<parent name>|<age s>                  (every copy of a program that runs 2+ times: who is its parent)
  P <comm> <pid> <pss_kb> <anon_kb> <fds> <threads>            M <MemAvailable kb>   E (end of sample)
"""
import json
import os
import re
import sys
from datetime import datetime

DEFAULT_LOG = os.path.expanduser("~/.cache/island/leak-watch.log")

# kernel threads / per-cpu helpers: their names and counts change from sample to sample for no reason of ours
KERNEL = re.compile(
    r"^(kworker|ksoftirqd|migration|rcu_|cpuhp|irq/|idle_inject|kcompactd|khugepaged|jbd2|scsi_|nvme|loop\d|ext4|btrfs|xfs|"
    r"kswapd|oom_reaper|watchdog|netns|kintegrityd|blkcg|ata_|psimon|card\d|kthreadd|kdevtmpfs|kblockd|writeback|"
    r"mld|ipv6_addrconf|tpm_dev|hwrng|acpi_|ttm|gfx_|sdma|amdgpu|i915|nv_queue|nvidia|jbd|cryptd|kmpath|md$|raid)", re.I)

MIN_ANON_MB = 8.0        # smaller growth than this is allocator noise
MIN_STEP_MB = 8.0        # a single interval must add at least this to count as a "jump"
FD_GROWTH = 5            # open files / pipes
THREAD_GROWTH = 5


def _int(x, d=0):
    try:
        return int(float(x))
    except Exception:
        return d


def parse(path):
    samples, cur = [], None
    with open(path, errors="ignore") as f:
        for raw in f:
            p = raw.split()
            if not p:
                continue
            k = p[0]
            if k == "T" and len(p) >= 2:
                cur = {"t": _int(p[1]), "z": 0, "counts": {}, "procs": {}, "mem": 0, "dups": {}}
                samples.append(cur)
            elif cur is None:
                continue
            elif k == "Z" and len(p) >= 2:
                cur["z"] = _int(p[1])
            elif k == "M" and len(p) >= 2:
                cur["mem"] = _int(p[1])
            elif k == "C" and len(p) >= 3:
                cur["counts"][" ".join(p[1:-1])] = _int(p[-1])
            elif k == "D" and "|" in raw:
                f = raw.rstrip("\n")[2:].split("|")
                if len(f) >= 5:
                    cur["dups"].setdefault(f[0], []).append({"pid": _int(f[1]), "ppid": _int(f[2]), "parent": f[3], "age": _int(f[4])})
            elif k == "P" and len(p) >= 7:
                nums = [_int(x) for x in p[-5:]]            # pid pss anon fds threads (comm may hold spaces)
                comm = " ".join(p[1:-5])
                cur["procs"][(comm, nums[0])] = {"pss": nums[1], "anon": nums[2], "fds": nums[3], "thr": nums[4]}
    return samples


def parents_text(copies):
    """'2 under quickshell, 1 ORPHAN (parent exited: now under systemd)' from the D lines of the last sample."""
    if not copies:
        return ""
    by, orphans = {}, 0
    for c in copies:
        if c["parent"] in ("systemd", "init") or c["ppid"] == 1:
            orphans += 1
        else:
            by[c["parent"]] = by.get(c["parent"], 0) + 1
    parts = [f"{n} under {name}" for name, n in sorted(by.items(), key=lambda x: -x[1])]
    if orphans:
        parts.append(f"{orphans} ORPHAN{'S' if orphans > 1 else ''} (their parent exited and left them running, now under systemd)")
    return " Parents: " + ", ".join(parts) + "."


def hhmm(t):
    return datetime.fromtimestamp(t).strftime("%H:%M:%S")


def analyze(path=DEFAULT_LOG):
    if not os.path.isfile(path):
        return {"error": f"no leak-watch log at {path}. Record one first: advisor leaks watch 30 60"}
    S = parse(path)
    if len(S) < 3:
        return {"error": f"only {len(S)} sample(s) in {path}: need at least 3 (run it for 20+ minutes)"}
    t0, t1 = S[0]["t"], S[-1]["t"]
    hours = max(1e-6, (t1 - t0) / 3600.0)
    out = {"log": path, "samples": len(S), "start": t0, "end": t1, "minutes": round((t1 - t0) / 60.0, 1),
           "interval_s": round((t1 - t0) / max(1, len(S) - 1)), "findings": [], "facts": []}
    F = out["findings"]

    # ---- memory overall
    if S[0]["mem"] and S[-1]["mem"]:
        d = (S[-1]["mem"] - S[0]["mem"]) / 1024.0
        out["facts"].append(f"free RAM (MemAvailable) {S[0]['mem']/1024:.0f} MB -> {S[-1]['mem']/1024:.0f} MB ({d:+.0f} MB)")

    # ---- zombies
    zs = [s["z"] for s in S]
    if zs[-1] > 0:
        F.append({"sev": "warn" if zs[-1] < 5 else "bad", "kind": "zombies",
                  "text": f"{zs[-1]} zombie process(es) at the end (start {zs[0]}, max {max(zs)}): some parent never reaps its children. "
                          "Find the parent: ps -eo stat,ppid,pid,comm | awk '$1 ~ /^Z/'"})
    elif max(zs) > 0:
        F.append({"sev": "info", "kind": "zombies", "text": f"zombies appeared (max {max(zs)}) but were all reaped by the end: harmless."})
    else:
        out["facts"].append("zombies: 0 in every sample")

    # ---- process counts (clones). Kernel threads are ignored.
    names = set()
    for s in S:
        names.update(s["counts"])
    skipped = 0
    for n in sorted(names):
        if KERNEL.match(n):
            skipped += 1
            continue
        series = [s["counts"].get(n, 0) for s in S]
        c0, cl = series[0], series[-1]
        if max(series) <= c0:
            continue
        first_up = next(i for i, c in enumerate(series) if c > c0)
        held = min(series[-3:]) > c0
        if held and cl - c0 >= 3 and series[-1] >= series[len(series) // 2]:
            F.append({"sev": "bad", "kind": "clones", "name": n,
                      "text": f"'{n}' multiplied: {c0} -> {cl} copies and they were still there at the end (first extra copy at {hhmm(S[first_up]['t'])}). "
                              "Something starts a new copy and never lets the old one finish." + parents_text(S[-1]["dups"].get(n))})
        elif held:
            orph = [c for c in S[-1]["dups"].get(n, []) if c["parent"] in ("systemd", "init") or c["ppid"] == 1]
            F.append({"sev": "warn" if orph else "info", "kind": "clones", "name": n,
                      "text": f"'{n}': {c0} -> {cl} and stayed there (from {hhmm(S[first_up]['t'])}): a helper that was started once, not a runaway." + parents_text(S[-1]["dups"].get(n))})
        else:
            F.append({"sev": "info", "kind": "clones", "name": n,
                      "text": f"'{n}' count went up (max {max(series)}) but came back down: transient, no leak."})
    if skipped:
        out["facts"].append(f"{skipped} kernel-thread names (kworker, ksoftirqd ...) ignored: they differ between samples by design")

    # ---- per process: anonymous (heap) memory, open files, threads
    keys = {}
    for i, s in enumerate(S):
        for k, v in s["procs"].items():
            keys.setdefault(k, []).append((i, v))
    for (comm, pid), rows in keys.items():
        if len(rows) < 3 or KERNEL.match(comm):
            continue
        idx = [i for i, _ in rows]
        ts = [S[i]["t"] for i in idx]
        anon = [v["anon"] / 1024.0 for _, v in rows]
        total = anon[-1] - anon[0]
        label = f"{comm} (pid {pid})"
        if total >= MIN_ANON_MB:
            diffs = [anon[j + 1] - anon[j] for j in range(len(anon) - 1)]
            jmax = max(range(len(diffs)), key=lambda j: diffs[j])
            big = [j for j, d in enumerate(diffs) if d >= max(MIN_STEP_MB, 0.25 * total)]
            up = sum(1 for d in diffs if d > 0.3)
            frac_up = up / len(diffs)
            per_h = total / ((ts[-1] - ts[0]) / 3600.0 or 1e-6)
            if diffs[jmax] >= 0.6 * total and diffs[jmax] >= MIN_STEP_MB:
                a, b = ts[jmax], ts[jmax + 1]
                tail = anon[jmax + 1:]
                kept = (max(tail) - min(tail)) < 0.15 * max(diffs[jmax], 1) if len(tail) > 1 else True
                F.append({"sev": "warn", "kind": "step", "name": label, "mb": round(total, 1), "t_from": a, "t_to": b,
                          "text": f"{label}: ONE jump of {diffs[jmax]:.0f} MB between {hhmm(a)} and {hhmm(b)} (epoch {a} .. {b}); "
                                  f"{'it was never given back' if kept else 'it shrank again later'}. Total {anon[0]:.0f} -> {anon[-1]:.0f} MB. "
                                  "Not a steady leak: something allocated a lot at once at that moment (a window / image / overlay loaded, a timer fired). "
                                  "If that event repeats, RAM creeps up and stays up."})
            elif len(big) >= 2:
                F.append({"sev": "warn", "kind": "stairs", "name": label, "mb": round(total, 1),
                          "text": f"{label}: grew in {len(big)} separate jumps (+{total:.0f} MB in {out['minutes']:.0f} min, at "
                                  + ", ".join(hhmm(ts[j + 1]) for j in big[:6]) + "): an event that allocates and keeps memory is happening repeatedly."})
            elif frac_up >= 0.65 and per_h > 5:
                F.append({"sev": "bad", "kind": "leak", "name": label, "mb": round(total, 1), "mb_per_hour": round(per_h, 1),
                          "text": f"{label}: STEADY leak, +{total:.0f} MB in {out['minutes']:.0f} min (about {per_h:.0f} MB/hour, "
                                  f"~{per_h*8:.0f} MB per 8 hours); it grew at {up} of {len(diffs)} intervals."})
            else:
                F.append({"sev": "info", "kind": "growth", "name": label, "mb": round(total, 1),
                          "text": f"{label}: +{total:.0f} MB but irregular (not steady, no single jump): probably caches settling. Re-check with a longer run."})
        fd_d = rows[-1][1]["fds"] - rows[0][1]["fds"]
        if fd_d >= FD_GROWTH:
            F.append({"sev": "bad", "kind": "fds", "name": label,
                      "text": f"{label}: open files / pipes {rows[0][1]['fds']} -> {rows[-1][1]['fds']}: something is opened and never closed. "
                              f"See what: ls -l /proc/{pid}/fd | tail"})
        th_d = rows[-1][1]["thr"] - rows[0][1]["thr"]
        if th_d >= THREAD_GROWTH:
            F.append({"sev": "bad", "kind": "threads", "name": label,
                      "text": f"{label}: threads {rows[0][1]['thr']} -> {rows[-1][1]['thr']}: threads are started and never end."})

    order = {"bad": 0, "warn": 1, "info": 2}
    F.sort(key=lambda f: order.get(f["sev"], 3))
    sev = [f["sev"] for f in F]
    out["verdict"] = ("leak" if "bad" in sev else "jump" if "warn" in sev else "clean")
    return out


def render(res):
    if "error" in res:
        return res["error"]
    L = [f"leak-watch: {res['samples']} samples over {res['minutes']} min (every ~{res['interval_s']} s), "
         f"{hhmm(res['start'])} -> {hhmm(res['end'])}"]
    L += ["  " + f for f in res["facts"]]
    mark = {"bad": "LEAK ", "warn": "JUMP ", "info": "note "}
    for f in res["findings"]:
        L.append(f"  [{mark.get(f['sev'], '')}] {f['text']}")
    L.append({"leak": "VERDICT: something is leaking (see the LEAK lines).",
              "jump": "VERDICT: no steady leak, but a memory jump that was never given back (see JUMP).",
              "clean": "VERDICT: clean: no leak, no clones, no zombies in this run."}[res["verdict"]])
    return "\n".join(L)


if __name__ == "__main__":
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    r = analyze(a[0] if a else DEFAULT_LOG)
    print(json.dumps(r, indent=1) if "--json" in sys.argv else render(r))
    sys.exit(2 if "error" in r else 0)
