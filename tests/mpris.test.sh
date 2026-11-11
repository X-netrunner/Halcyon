#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/../src/halcyon-music" || exit 1
command -v dbus-run-session >/dev/null || { echo "skip: dbus-run-session is not installed"; exit 0; }
cargo test -q -p halcyon-musicd --test mpris_signals --no-run >/dev/null 2>&1 || { echo "FAIL build"; exit 1; }
HALCYON_PRIVATE_BUS=1 dbus-run-session -- cargo test -q -p halcyon-musicd --test mpris_signals 2>&1 | grep -E "test result|FAILED|panicked"
exit "${PIPESTATUS[0]}"
