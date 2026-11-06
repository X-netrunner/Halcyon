#!/bin/sh
# greetd runs "exec $@" through a shell with $@ unquoted (arguments are split at spaces, quotes are not re-read). The login screen
# must therefore pass only plain words. This test imitates greetd's expansion and checks the wrapper still starts and logs.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
bad() { echo "FAIL: $*"; fail=1; }

# 1. the greeter never hands greetd a shell script as one argument
grep -E 'Greetd\.launch' "$here/greeter/shell.qml" | grep -q -- '"-c"' && bad "Greetd.launch uses \"-c\" with a script argument"
[ -s "$here/greeter/halcyon-session" ] || bad "greeter/halcyon-session is missing or empty"

# 2. wrapper under greetd's expansion: no word may contain a space, and the session must really run and be logged
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# the installer (scripts/halcyon-greeter.sh, mode_of) gives the wrapper mode 755 wherever it puts it, so the test runs a copy with that mode:
# a checkout or a zip that dropped the executable bit must not fail a test of what the wrapper DOES
cp "$here/greeter/halcyon-session" "$tmp/halcyon-session" 2>/dev/null; chmod 755 "$tmp/halcyon-session"
wrapper="$tmp/halcyon-session"
printf '#!/bin/sh\necho ran "$@"\nexit 3\n' > "$tmp/fake-session"; chmod 755 "$tmp/fake-session"
set -- "$wrapper" "$tmp/fake-session" --flag
( HOME="$tmp/home"; export HOME; mkdir -p "$HOME"; sh -c 'exec $@' sh "$@" ); rc=$?
[ "$rc" = 3 ] || bad "wrapper exit code was $rc, expected 3 (the session's own)"
log="$tmp/home/.cache/island/greeter-session.log"
grep -q 'ran --flag' "$log" 2>/dev/null || bad "session output missing from the log"
grep -q 'session command ended: exit 3' "$log" 2>/dev/null || bad "end line missing from the log"

# 3. no argument-less session
( HOME="$tmp/home"; export HOME; sh -c 'exec $@' sh "$wrapper" ) >/dev/null 2>&1
[ "$?" = 1 ] || bad "wrapper without a command should exit 1"

[ "$fail" = 0 ] && echo "greeter-launch: ok"
exit "$fail"
