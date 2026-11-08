#!/usr/bin/env bash
# Halcyon Music - build gate.
#
# Runs, in src/halcyon-music/ (its own Cargo workspace, separate from the repo's root workspace):
#   1. cargo check  --workspace --tests
#   2. cargo test   --workspace
#   3. cargo clippy --workspace --all-targets -- -D warnings
# and exits non-zero if any step fails. Every step runs even when an earlier one fails, so one
# run shows the whole picture. Output is also kept in docs/check-latest.log (overwritten each run).
#
# Usage: scripts/check.sh [--offline]
#   --offline   pass --offline to cargo (use only already-downloaded crates)
#   CARGO_FLAGS="--locked"   extra flags for every cargo command
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$SCRIPT_DIR/../src/halcyon-music"
LOG="$WS/docs/check-latest.log"

if ! command -v cargo >/dev/null 2>&1; then
    echo "check.sh: cargo not found. Install Rust (https://rustup.rs) and try again." >&2
    exit 127
fi
cd "$WS" || { echo "check.sh: cannot enter $WS" >&2; exit 2; }

FLAGS="${CARGO_FLAGS:-}"
[ "${1:-}" = "--offline" ] && FLAGS="$FLAGS --offline"

mkdir -p docs
: > "$LOG"
fail=0
declare -a summary=()

run() {
    local name="$1"; shift
    echo "==> $name: cargo $*" | tee -a "$LOG"
    # shellcheck disable=SC2086
    if cargo "$@" $FLAGS 2>&1 | tee -a "$LOG"; [ "${PIPESTATUS[0]}" -eq 0 ]; then
        summary+=("PASS  $name")
    else
        summary+=("FAIL  $name")
        fail=1
    fi
}

run "check"  check  --workspace --tests
run "test"   test   --workspace
# clippy flags go after `--`, so FLAGS must come before it: build the command by hand.
echo "==> clippy: cargo clippy --workspace --all-targets $FLAGS -- -D warnings" | tee -a "$LOG"
# shellcheck disable=SC2086
if cargo clippy --workspace --all-targets $FLAGS -- -D warnings 2>&1 | tee -a "$LOG"; [ "${PIPESTATUS[0]}" -eq 0 ]; then
    summary+=("PASS  clippy")
else
    summary+=("FAIL  clippy")
    fail=1
fi

echo
echo "---- summary ----" | tee -a "$LOG"
printf '%s\n' "${summary[@]}" | tee -a "$LOG"
exit "$fail"
