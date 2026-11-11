#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
awk '/^aifw_take_over\(\) \{/{p=1} p{print} p&&/^}/{exit}' install.sh > "$tmp/funcs.sh"
# shellcheck disable=SC1091
source "$tmp/funcs.sh"

log="$tmp/calls"
as_root() { "$@"; }
sleep() { :; }
log_task() { :; }
warn_later() { echo "warn: $1" >> "$log"; }
ufw() { echo "ufw $*" >> "$log"; }
systemctl() {
    case "$1" in
        is-active)
            n=$(cat "$tmp/n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$tmp/n"
            [[ " $ACTIVE " == *" $n "* ]] ;;
        show) cat "$tmp/restarts.$(cat "$tmp/n" 2>/dev/null || echo 0)" 2>/dev/null || echo 0 ;;
        is-enabled) [[ "$*" == *ufw* ]] ;;
        *) echo "systemctl $*" >> "$log" ;;
    esac
}
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2', want '$3')"; fail=1; fi; }
reset() { : > "$log"; rm -f "$tmp/n" "$tmp"/restarts.*; }
turned_off() { grep -c "disable" "$log"; }

reset; export DRY_RUN=true; ACTIVE=""
aifw_take_over; check "dry run succeeds" "$?" 0
check "dry run touches nothing" "$(turned_off)" 0

export DRY_RUN=false
reset; ACTIVE="1 2 3 4 5"
aifw_take_over; check "steady firewall takes over" "$?" 0
check "ufw and firewalld are turned off" "$(turned_off)" 2

reset; ACTIVE=""
aifw_take_over; check "dead firewall does not take over" "$?" 1
check "dead firewall keeps ufw" "$(grep -c "disable --now ufw" "$log")" 0
check "dead firewall is stopped" "$(grep -c "disable --now ai-firewall" "$log")" 1
check "dead firewall hands back to ufw (Conflicts= had stopped it)" "$(grep -c "start ufw.service" "$log")" 1

reset; ACTIVE="1 2 3 5"
aifw_take_over; check "flapping firewall (dropped at check 4) keeps ufw" "$?" 1
check "flapping firewall keeps ufw" "$(grep -c "disable --now ufw" "$log")" 0

reset; ACTIVE="1 2 3 4 5"; echo 3 > "$tmp/restarts.5"
aifw_take_over; check "firewall that restarted meanwhile keeps ufw" "$?" 1
check "restarted firewall keeps ufw" "$(grep -c "start ufw.service" "$log")" 1

exit "$fail"
