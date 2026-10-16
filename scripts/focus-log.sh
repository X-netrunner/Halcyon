#!/usr/bin/env bash
# The Focus streak's memory: how many minutes you focused on each day.
#   focus-log.sh add MINUTES     add minutes to today (the island calls this once a minute while a work phase runs)
#   focus-log.sh json            print { "2026-10-16": 42, ... } (the last 400 days)
# Stored in ~/.local/state/island/focus-days.json. Needs python3 (Focus mode needs it too).
f="${XDG_STATE_HOME:-$HOME/.local/state}/island/focus-days.json"
mkdir -p "$(dirname "$f")"
exec python3 - "$f" "$@" <<'PY'
import json, os, sys, datetime
path, cmd = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "json")
try:
    with open(path) as fh: d = json.load(fh)
    if not isinstance(d, dict): d = {}
except Exception:
    d = {}
if cmd == "add":
    try: m = max(0, min(600, int(sys.argv[3])))
    except Exception: m = 0
    k = datetime.date.today().isoformat()
    d[k] = int(d.get(k, 0)) + m
    keep = sorted(d)[-400:]
    d = {x: d[x] for x in keep}
    tmp = path + ".tmp"
    with open(tmp, "w") as fh: json.dump(d, fh)
    os.replace(tmp, path)
else:
    print(json.dumps({x: d[x] for x in sorted(d)[-400:]}))
PY
