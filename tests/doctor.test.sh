#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
cargo build -q -p hal 2>/dev/null || { echo "FAIL build hal"; exit 1; }
hal=$PWD/target/debug/hal
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home/.config/Halcyon/quickshell/island" "$tmp/run/halcyon"
chmod 700 "$tmp/run/halcyon"
touch "$tmp/home/.config/Halcyon/quickshell/island/shell.qml"
ln -s "$hal" "$tmp/bin/hal"
status() { printf '#!/bin/sh\necho %s\n' "'{\"schema\":\"halcyon.status/1\",\"component\":\"$1\",\"version\":\"9.9\",\"contract\":1,\"state\":\"$2\",\"detail\":\"stub\"}'" > "$tmp/bin/$3"; chmod +x "$tmp/bin/$3"; }
status ai-firewall ok ai-firewall
status ai-antivirus down ai-antivirus
printf '#!/bin/sh\necho "usage: luna [--voice]"\n' > "$tmp/bin/luna"; chmod +x "$tmp/bin/luna"
printf '#!/bin/sh\nsleep 10\n' > "$tmp/bin/halcyon-musicd"; chmod +x "$tmp/bin/halcyon-musicd"
printf '#!/bin/sh\ncase "$*" in *ai-firewall*) echo active;; *) echo inactive;; esac\n' > "$tmp/bin/systemctl"; chmod +x "$tmp/bin/systemctl"
out=$(PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" XDG_CONFIG_HOME="$tmp/home/.config" "$hal" doctor --json)
rc=$?
fail=0
check() { if printf '%s' "$out" | grep -q "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
check "a healthy component is ok" '"component":"ai-firewall","check":"health","level":"ok"'
check "a down component fails" '"component":"ai-antivirus","check":"health","level":"fail"'
check "an old component without the endpoint only warns" '"component":"luna","check":"health","level":"warn"'
check "a hung endpoint fails after the timeout" '"component":"halcyon-music","check":"health","level":"fail","detail":"did not answer within 3 s"'
check "a missing component is information, not an error" '"component":"halcyon-fm","check":"installed","level":"info"'
check "the shared runtime dir is checked" '"level":"ok","detail":"0700, yours"'
check "an inactive service warns" '"check":"ai-antivirus-responderd.service","level":"warn"'
if [ "$rc" = 1 ]; then echo "ok   a failure gives exit code 1"; else echo "FAIL exit code $rc"; fail=1; fi
exit "$fail"
