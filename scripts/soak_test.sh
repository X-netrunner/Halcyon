#!/usr/bin/env bash
# Halcyon Music - soak test.
# Sends random commands to the running daemon for a while and MEASURES what happens:
# commands that could not be sent, daemon restarts (the process id changing), peak memory
# (budget 150 MB) and whether the daemon still answers at the end. The report says PASS only
# when all of that is clean; otherwise it says FAIL and the script exits 1.
#
# It does not inject faults: those need the daemon to be started with HALCYON_MUSIC_FAULTS set
# (see crates/halcyon-musicd/src/faults.rs), which is a separate run.
#
# Release run (Part 9), on a real signed-in session:
#   SOAK_CONNECT=1 SOAK_MODEL=1 scripts/soak_test.sh 30
#
#   SOAK_CONNECT=1   the daemon must be running as a Spotify Connect device (started with
#                    HALCYON_CONNECT=1 and a build with --features connect). The run FAILS if the
#                    device is not registered at the start, or is gone / a different process at the end.
#   SOAK_MODEL=1     also asks for mixes and suggestions all the time so the built-in model works
#                    (Smart suggestions must be ON with the built-in model downloaded). The model's own
#                    memory is not counted against the 150 MB budget while it is loaded; instead the
#                    script waits for the model to unload (it does after 2 minutes idle) and then
#                    FAILS if the daemon is still above 150 MB, which would be a leak.
#
# Usage: scripts/soak_test.sh [minutes]      (default 5; e.g. 720 for 12 hours)
#   SOAK_REPORT=/path/report.md              where to write the report (default docs/soak_report.md)
#   SOAK_IDLE_WAIT=150                       seconds to wait for the model to unload (SOAK_MODEL=1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOCKET_PATH="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/halcyon-music/ctl.sock"
REPORT_FILE="${SOAK_REPORT:-$SCRIPT_DIR/../docs/soak_report.md}"
mkdir -p "$(dirname "$REPORT_FILE")"

DURATION_MINS="${1:-5}"
END_TIME=$((SECONDS + DURATION_MINS * 60))
RSS_BUDGET_KB=153600 # 150 MB
SOAK_CONNECT="${SOAK_CONNECT:-0}"
SOAK_MODEL="${SOAK_MODEL:-0}"
IDLE_WAIT="${SOAK_IDLE_WAIT:-150}"
CONNECT_FILE="$(dirname "$SOCKET_PATH")/connect.json"
FD_GROWTH_LIMIT=100 # open files may grow by this much over the run before it counts as a leak

echo "=== Starting Halcyon Music Soak Test ==="
echo "Duration: ${DURATION_MINS} minutes"
echo "Socket: ${SOCKET_PATH}"
[ "$SOAK_CONNECT" = 1 ] && echo "Connect check: on" || echo "Connect check: off"
[ "$SOAK_MODEL" = 1 ] && echo "Model workload: on" || echo "Model workload: off"

if [ ! -S "$SOCKET_PATH" ]; then
    echo "Error: Daemon socket not found at $SOCKET_PATH"
    echo "Make sure halcyon-musicd is running (systemctl --user start halcyon-musicd)"
    exit 1
fi

# Send one command line. Fails (non-zero) when the daemon cannot be reached.
send_cmd() {
    SOAK_SOCKET="$SOCKET_PATH" SOAK_CMD="$1" python3 - <<'PY'
import os, socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
s.connect(os.environ["SOAK_SOCKET"])
s.sendall(os.environ["SOAK_CMD"].encode() + b"\n")
s.close()
PY
}

# Ask the daemon who it is. Prints the Hello line, fails if there is no answer.
hello_line() {
    SOAK_SOCKET="$SOCKET_PATH" python3 - <<'PY'
import os, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
s.connect(os.environ["SOAK_SOCKET"])
s.sendall(b'{"version":1,"type":"hello"}\n')
buf = b""
while b"\n" not in buf:
    chunk = s.recv(4096)
    if not chunk:
        break
    buf += chunk
line = buf.split(b"\n", 1)[0].decode(errors="replace")
if '"hello"' not in line:
    sys.exit(1)
print(line)
PY
}

daemon_pid() {
    pgrep -u "$(id -u)" -x halcyon-musicd | head -n1 || true
}

daemon_rss_kb() {
    local pid
    pid="$(daemon_pid)"
    if [ -n "$pid" ]; then
        ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo 0
    else
        echo 0
    fi
}

daemon_fd_count() {
    local pid
    pid="$(daemon_pid)"
    if [ -n "$pid" ] && [ -d "/proc/$pid/fd" ]; then
        ls "/proc/$pid/fd" 2>/dev/null | wc -l | tr -d ' '
    else
        echo 0
    fi
}

# Prints "name|pid" when connect.json exists and its process is alive; prints nothing otherwise.
connect_registered() {
    SOAK_CONNECT_FILE="$CONNECT_FILE" python3 - <<'PY' 2>/dev/null
import json, os, sys
try:
    d = json.load(open(os.environ["SOAK_CONNECT_FILE"]))
    os.kill(int(d["pid"]), 0)
    print(f'{d["name"]}|{d["pid"]}')
except Exception:
    sys.exit(0)
PY
}

START_PID="$(daemon_pid)"
if [ -z "$START_PID" ]; then
    echo "Error: the socket exists but no halcyon-musicd process was found."
    exit 1
fi
LAST_PID="$START_PID"
START_FDS="$(daemon_fd_count)"
START_FDS="${START_FDS:-0}"

CONNECT_START=""
if [ "$SOAK_CONNECT" = 1 ]; then
    CONNECT_START="$(connect_registered || true)"
    if [ -z "$CONNECT_START" ]; then
        echo "Error: SOAK_CONNECT=1 but Halcyon is not registered as a Connect device."
        echo "Start the daemon with HALCYON_CONNECT=1 (build: --features connect) and check: halcyon-musicd --doctor"
        exit 1
    fi
    echo "Connect device at start: ${CONNECT_START%%|*}"
fi

ACTIONS_TOTAL=0
SEND_FAILURES=0
DAEMON_RESTARTS=0
MAX_RSS_KB=0
OVER_BUDGET=0
ABOVE_BUDGET_WITH_MODEL=0

send_or_count() {
    if ! send_cmd "$1" 2>/dev/null; then
        SEND_FAILURES=$((SEND_FAILURES + 1))
    fi
}

while [ "$SECONDS" -lt "$END_TIME" ]; do
    ACTION=$((RANDOM % 9))
    ACTIONS_TOTAL=$((ACTIONS_TOTAL + 1))

    case $ACTION in
        0) send_or_count "{\"version\":1,\"type\":\"seek\",\"position_ms\":$((RANDOM % 200000))}" ;;
        1) send_or_count '{"version":1,"type":"next"}' ;;
        2) send_or_count '{"version":1,"type":"previous"}' ;;
        3) send_or_count "{\"version\":1,\"type\":\"set_volume\",\"volume\":$((RANDOM % 100))}" ;;
        4) if [ $((RANDOM % 2)) -eq 1 ]; then SHUF=true; else SHUF=false; fi
           send_or_count "{\"version\":1,\"type\":\"set_shuffle\",\"shuffle\":$SHUF}" ;;
        5) send_or_count '{"version":1,"type":"cycle_repeat"}' ;;
        6) send_or_count '{"version":1,"type":"get_state"}'
           send_or_count '{"version":1,"type":"get_home_feed"}' ;;
        7) send_or_count '{"version":1,"type":"probe_endpoints"}' ;;
        8) if [ "$SOAK_MODEL" = 1 ]; then
               # Mixes and suggestions are what wake the built-in model.
               send_or_count '{"version":1,"type":"get_mixes"}'
               send_or_count '{"version":1,"type":"get_suggestions"}'
               send_or_count '{"version":1,"type":"get_llm_status"}'
           else
               send_or_count '{"version":1,"type":"get_state"}'
           fi ;;
    esac

    # A different process id means the daemon crashed and was restarted (or was restarted by hand).
    PID_NOW="$(daemon_pid)"
    if [ -n "$PID_NOW" ] && [ "$PID_NOW" != "$LAST_PID" ]; then
        DAEMON_RESTARTS=$((DAEMON_RESTARTS + 1))
        echo "NOTE: the daemon process changed ($LAST_PID -> $PID_NOW)"
        LAST_PID="$PID_NOW"
    fi

    RSS_KB="$(daemon_rss_kb)"
    RSS_KB="${RSS_KB:-0}"
    if [ "$RSS_KB" -gt "$MAX_RSS_KB" ]; then
        MAX_RSS_KB=$RSS_KB
    fi
    if [ "$RSS_KB" -gt "$RSS_BUDGET_KB" ]; then
        if [ "$SOAK_MODEL" = 1 ]; then
            # The loaded model is excluded from the budget; the idle check below decides.
            ABOVE_BUDGET_WITH_MODEL=1
        else
            OVER_BUDGET=1
            echo "WARNING: daemon memory above the 150 MB budget: ${RSS_KB} KB"
        fi
    fi

    sleep 0.1
done

# With the model on: stop asking, let it unload, then measure again. Above budget now = a leak.
IDLE_RSS_KB=0
if [ "$SOAK_MODEL" = 1 ]; then
    echo "Waiting ${IDLE_WAIT} s for the built-in model to unload..."
    sleep "$IDLE_WAIT"
    IDLE_RSS_KB="$(daemon_rss_kb)"
    IDLE_RSS_KB="${IDLE_RSS_KB:-0}"
    if [ "$IDLE_RSS_KB" -gt "$RSS_BUDGET_KB" ]; then
        OVER_BUDGET=1
    fi
fi

END_FDS="$(daemon_fd_count)"
END_FDS="${END_FDS:-0}"

CONNECT_END=""
if [ "$SOAK_CONNECT" = 1 ]; then
    CONNECT_END="$(connect_registered || true)"
fi

# Is the daemon still healthy at the end?
FINAL_ANSWERS="no"
HELLO=""
if HELLO="$(hello_line 2>/dev/null)"; then
    FINAL_ANSWERS="yes"
fi

MAX_RSS_MB="$(python3 -c "print(f'{$MAX_RSS_KB / 1024:.2f}')")"

PROBLEMS=()
[ "$SEND_FAILURES" -gt 0 ] && PROBLEMS+=("$SEND_FAILURES command(s) could not be sent to the daemon")
[ "$DAEMON_RESTARTS" -gt 0 ] && PROBLEMS+=("the daemon process changed $DAEMON_RESTARTS time(s)")
if [ "$OVER_BUDGET" -eq 1 ]; then
    if [ "$SOAK_MODEL" = 1 ]; then
        PROBLEMS+=("memory is still above the 150 MB budget $((IDLE_WAIT)) s after the model went idle ($((IDLE_RSS_KB / 1024)) MB)")
    else
        PROBLEMS+=("memory went above the 150 MB budget (peak ${MAX_RSS_MB} MB)")
    fi
fi
[ $((END_FDS - START_FDS)) -gt "$FD_GROWTH_LIMIT" ] && PROBLEMS+=("open files grew from $START_FDS to $END_FDS (a leak?)")
if [ "$SOAK_CONNECT" = 1 ]; then
    if [ -z "$CONNECT_END" ]; then
        PROBLEMS+=("the Connect device was no longer registered at the end")
    elif [ "${CONNECT_END##*|}" != "${CONNECT_START##*|}" ]; then
        PROBLEMS+=("the Connect device came back under a different process (it restarted during the run)")
    fi
fi
[ "$FINAL_ANSWERS" != "yes" ] && PROBLEMS+=("the daemon did not answer at the end")

if [ "${#PROBLEMS[@]}" -eq 0 ]; then
    STATUS="PASS"
    PROBLEM_TEXT="none"
else
    STATUS="FAIL"
    PROBLEM_TEXT="$(printf '%s; ' "${PROBLEMS[@]}")"
fi

cat > "$REPORT_FILE" <<REPORT
# Halcyon Music - Soak Test Report

- **Date:** $(date -u +"%Y-%m-%d %H:%M:%SZ")
- **Test duration:** ${DURATION_MINS} minutes
- **Commands sent:** ${ACTIONS_TOTAL}
- **Commands that could not be sent:** ${SEND_FAILURES}
- **Daemon restarts seen (process id changed):** ${DAEMON_RESTARTS}
- **Peak daemon memory:** ${MAX_RSS_MB} MB (budget: 150 MB$([ "$SOAK_MODEL" = 1 ] && echo ", not counted while the built-in model is loaded"))
- **Model workload:** $([ "$SOAK_MODEL" = 1 ] && echo "on; memory ${IDLE_WAIT} s after the model went idle: $((IDLE_RSS_KB / 1024)) MB (peak seen above budget while loaded: $([ "$ABOVE_BUDGET_WITH_MODEL" = 1 ] && echo yes || echo no))" || echo "off")
- **Connect device:** $([ "$SOAK_CONNECT" = 1 ] && echo "checked; start: ${CONNECT_START%%|*}, end: $([ -n "$CONNECT_END" ] && echo "${CONNECT_END%%|*}" || echo "gone")" || echo "not checked")
- **Open files (start -> end):** ${START_FDS} -> ${END_FDS}
- **Daemon answers at the end:** ${FINAL_ANSWERS}
- **Status:** ${STATUS}
- **Problems:** ${PROBLEM_TEXT}

Not covered by this run: fault injection (network drop, audio stall, expired token). Start the
daemon with \`HALCYON_MUSIC_FAULTS=network_drop,audio_stall,auth_expired\` for that.
REPORT

echo "=== Soak Test Completed: ${STATUS} ==="
echo "Report written to: $REPORT_FILE"
cat "$REPORT_FILE"

[ "$STATUS" = "PASS" ]
