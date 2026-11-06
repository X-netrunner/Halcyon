#!/usr/bin/env bash
# The console's sudo shim (scripts/console-bin/sudo) only works when it is executable, because the console finds it through PATH.
# The installer must make it so (this was why the console never asked for the password), and the console fixes it itself otherwise.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fail=1; }

grep -q 'scripts/console-bin/\*' "$here/install.sh" && ok "install.sh makes console-bin/* executable" || no "install.sh does not chmod console-bin/*"
grep -q 'chmod +x \\"$cb/sudo\\"' "$here/quickshell/island/QuickTerm.qml" && ok "the console repairs a shim that lost its executable bit" || no "QuickTerm.qml does not repair the shim"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/shim" "$tmp/real"
printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]" "$a"; done; echo\n' > "$tmp/real/sudo"; chmod +x "$tmp/real/sudo"
cp "$here/scripts/console-bin/sudo" "$tmp/shim/sudo"; chmod +x "$tmp/shim/sudo"
out=$(PATH="$tmp/shim:$tmp/real:$PATH" HALCYON_SUDO_PROMPT=MARK sh -c 'sudo id' | tr -d '\n')
[ "$out" = "[-S][-p][MARK][id]" ] && ok "in the console sudo gets -S and the prompt marker" || no "shim output: $out"
out=$(PATH="$tmp/shim:$tmp/real:$PATH" env -u HALCYON_SUDO_PROMPT sh -c 'sudo id' | tr -d '\n')
[ "$out" = "[id]" ] && ok "outside the console it is plain sudo" || no "plain: $out"
exit $fail
