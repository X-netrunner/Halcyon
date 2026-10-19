#!/usr/bin/env bash
# The counter-scan rules of `sysmode`: ON only in stealth, OFF always allowed, and the saved choice survives a mode change.
# Pulls the two functions out of sysmode and runs them against temp files (no root, nothing real is touched).
set -u
cd "$(dirname "$0")/.." || exit 1
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
SYSMODE_MODE="$tmp/mode"
{
  awk '/^detect_mode\(\) \{/{p=1} p{print} p&&/^}/{exit}' sysmode/sysmode
  awk '/^COUNTER_CONF=/{p=1} /^# Entry point/{p=0} p{print}' sysmode/sysmode | sed '/^# ---/d'
} > "$tmp/funcs.sh"
# install(1) needs root for -o/-g: stand in for it
install() { local a=("$@"); local n=${#a[@]}; cp "${a[n-2]}" "${a[n-1]}"; }   # the last two arguments are source and target
# shellcheck disable=SC1090
source "$tmp/funcs.sh"
COUNTER_CONF="$tmp/recon-deceiver.conf"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2', want '$3')"; fail=1; fi; }

echo secure > "$SYSMODE_MODE"
set_counterscan on --yes >/dev/null 2>&1; check "refuses ON outside stealth" "$(counterscan_state)" off
echo stealth > "$SYSMODE_MODE"
set_counterscan on --yes >/dev/null 2>&1; check "ON in stealth" "$(counterscan_state)" on
echo secure > "$SYSMODE_MODE"
check "stays ON after leaving stealth" "$(counterscan_state)" on
set_counterscan off >/dev/null 2>&1; check "OFF allowed anywhere" "$(counterscan_state)" off
echo hacking > "$SYSMODE_MODE"
set_counterscan on --yes >/dev/null 2>&1; check "old name 'hacking' counts as stealth" "$(counterscan_state)" on
exit $fail
