#!/usr/bin/env bash
# The AI Antivirus analyzer must not run for good once "AI review of antivirus alerts" is on (scripts/av-ai-watch.sh, av-ai-idle.sh):
#   - an analyzer that is already running with no alert waiting is stopped by the watcher (it used to stop only one it had started itself)
#   - stopping it also unloads its model from Ollama at once (keep_alive 0)
#   - a new alert starts it again
# Everything outside is faked (systemctl, sudo, ai-antivirus, curl); nothing real is touched.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
fail=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fail=1; }

tmp=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home/.local/state/island" "$tmp/etc"
log="$tmp/calls.log"; : > "$log"
export HOME="$tmp/home"

# the analyzer is "active"; sudo records what halcyon-tune was asked
cat > "$tmp/bin/systemctl" <<EOS
#!/bin/sh
[ "\$1" = is-active ] && { [ -e "$tmp/stopped" ] && exit 3; exit 0; }
exit 0
EOS
cat > "$tmp/bin/sudo" <<EOS
#!/bin/sh
echo "sudo \$*" >> "$log"
case "\$*" in *"av-ai pause"*) touch "$tmp/stopped" ;; *"av-ai resume"*) rm -f "$tmp/stopped" ;; esac
exit 0
EOS
cat > "$tmp/bin/curl" <<EOS
#!/bin/sh
echo "curl \$*" >> "$log"
exit 0
EOS
# a `timeout` that just runs its command (the watcher and the unload wrap calls in it)
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$tmp/bin/timeout"
# ai-antivirus: no alerts at all
printf '#!/bin/sh\necho "{\\"alerts_24h\\": 0, \\"unacked\\": 0, \\"db_readable\\": true}"\n' > "$tmp/bin/ai-antivirus"
chmod +x "$tmp/bin/"*

# av-ai-idle.sh reads the model from /etc/ai-antivirus/ai-antivirus.toml: use a copy of the script that looks in the test dir
sed "s#/etc/ai-antivirus/ai-antivirus.toml#$tmp/etc/ai-antivirus.toml#" "$here/scripts/av-ai-idle.sh" > "$tmp/av-ai-idle.sh"
cp "$here/scripts/av-ai-watch.sh" "$tmp/av-ai-watch.sh"
printf '[ai]\nenabled = true\nmodel = "qwen2.5:3b-instruct"\n' > "$tmp/etc/ai-antivirus.toml"

# 1. stop unloads the model
PATH="$tmp/bin:$PATH" bash "$tmp/av-ai-idle.sh" stop; sleep 0.5
grep -q 'av-ai pause' "$log" && ok "stop pauses the analyzer unit" || no "stop did not pause the unit"
grep -q 'curl.*keep_alive' "$log" && grep -q 'qwen2.5:3b-instruct' "$log" && ok "stop unloads the model (keep_alive 0)" || no "stop did not unload the model: $(cat "$log")"

rm -f "$tmp/stopped"
# 2. the watcher stops an analyzer it did not start, with no alert waiting
: > "$log"
PATH="$tmp/bin:$PATH" HALCYON_AV_POLL=1 HALCYON_AV_HOLD=3 bash "$tmp/av-ai-watch.sh" &
w=$!
sleep 8
kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
grep -q 'av-ai pause' "$log" && ok "an analyzer already running with no alert is stopped" || no "the watcher left the analyzer running: $(cat "$log")"
[ "$(grep -c 'av-ai pause' "$log")" -le 2 ] && ok "it is stopped once, not on every poll" || no "stopped on every poll: $(grep -c 'av-ai pause' "$log")"

# 3. an alert starts it
: > "$log"; rm -f "$HOME/.local/state/island/av-ai-watch.lock"
printf '#!/bin/sh\nn=$(cat "%s/n" 2>/dev/null || echo 0); echo $((n+1)) > "%s/n"\nprintf "{\\"alerts_24h\\": %%s, \\"unacked\\": %%s, \\"db_readable\\": true}" "$n" "$n"\n' "$tmp" "$tmp" > "$tmp/bin/ai-antivirus"
touch "$tmp/stopped"      # the unit is not active this time, so only an alert can start it
PATH="$tmp/bin:$PATH" HALCYON_AV_POLL=1 HALCYON_AV_HOLD=3 bash "$tmp/av-ai-watch.sh" &
w=$!
sleep 6
kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
grep -q 'av-ai resume' "$log" && ok "a new alert starts the analyzer" || no "an alert did not start it: $(cat "$log")"

# 4. the no-mercy setting shortens the hold
grep -q 'memRuthless' "$here/scripts/av-ai-watch.sh" && ok "the watcher reads the no-mercy setting" || no "the watcher ignores memRuthless"
exit $fail
