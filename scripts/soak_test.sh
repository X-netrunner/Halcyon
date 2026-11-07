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
# Usage: scripts/soak_test.sh [minutes]      (default 5; e.g. 720 for 12 hours)
#   SOAK_REPORT=/path/report.md              where to write the report (default docs/soak_report.md)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOCKET_PATH="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/halcyon-music/ctl.sock"
REPORT_FILE="${SOAK_REPORT:-$SCRIPT_DIR/../docs/soak_report.md}"
mkdir -p "$(dirname "$REPORT_FILE")"

DURATION_MINS="${1:-5}"
END_TIME=$((SECONDS + DURATION_MINS * 60))
RSS_BUDGET_KB=153600 # 150 MB

echo "=== Starting Halcyon Music Soak Test ==="
echo "Duration: ${DURATION_MINS} minutes"
echo "Socket: ${SOCKET_PATH}"

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

START_PID="$(daemon_pid)"
if [ -z "$START_PID" ]; then
    echo "Error: the socket exists but no halcyon-musicd process was found."
    exit 1
fi
LAST_PID="$START_PID"

ACTIONS_TOTAL=0
SEND_FAILURES=0
DAEMON_RESTARTS=0
MAX_RSS_KB=0
OVER_BUDGET=0

send_or_count() {
    if ! send_cmd "$1" 2>/dev/null; then
        SEND_FAILURES=$((SEND_FAILURES + 1))
    fi
}

while [ "$SECONDS" -lt "$END_TIME" ]; do
    ACTION=$((RANDOM % 8))
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
        OVER_BUDGET=1
        echo "WARNING: daemon memory above the 150 MB budget: ${RSS_KB} KB"
    fi

    sleep 0.1
done

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
[ "$OVER_BUDGET" -eq 1 ] && PROBLEMS+=("memory went above the 150 MB budget (peak ${MAX_RSS_MB} MB)")
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
- **Peak daemon memory:** ${MAX_RSS_MB} MB (budget: 150 MB)
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
