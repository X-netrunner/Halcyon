#!/usr/bin/env bash
# halcyon-shot.py: the screen freezes when Super + Shift + S is pressed (before the panel) and always lets go again.
# Fake wayfreeze / grim / slurp / quickshell, no compositor needed:  bash tests/shot-freeze.test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd); S="$here/scripts/halcyon-shot.py"
T=$(mktemp -d); trap 'for p in $(cat "$T"/state/shot-freeze.pid 2>/dev/null); do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT
export HOME="$T/home" HALCYON_STATE="$T/state" HALCYON_SHOT_DIR="$T/shots"; mkdir -p "$HOME" "$T/bin"
printf '#!/usr/bin/env bash\necho x >> "$HOME/wf.log"; trap "exit 0" TERM; while :; do sleep 0.1; done\n' > "$T/bin/wayfreeze"
printf '#!/usr/bin/env bash\necho x >> "$HOME/qs.log"; exit ${QS_FAIL:-0}\n' > "$T/bin/quickshell"
printf '#!/usr/bin/env bash\nexec cat >/dev/null\n' > "$T/bin/wl-copy"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/notify-send"
printf '#!/usr/bin/env bash\necho "10,10 50x50"\n' > "$T/bin/slurp"
cat > "$T/bin/grim" <<'EOF2'
#!/usr/bin/env bash
pid=$(cat "$HALCYON_STATE/shot-freeze.pid" 2>/dev/null)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo frozen > "$HOME/grim.state"; else echo live > "$HOME/grim.state"; fi
for a in "$@"; do last="$a"; done; if [ "$last" = "-" ]; then printf PNG; else printf PNG > "$last"; fi
EOF2
chmod +x "$T/bin/"*; export PATH="$T/bin:$PATH"
fails=0; n=0
check() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fails=$((fails+1)); fi; }
st() { local pid; pid=$(cat "$HALCYON_STATE/shot-freeze.pid" 2>/dev/null); if [ -n "$pid" ] && [ -d "/proc/$pid" ] && ! grep -q '^State:.*Z' "/proc/$pid/status"; then echo frozen; else echo live; fi; }
calls() { [ -f "$HOME/$1" ] && wc -l < "$HOME/$1" | tr -d ' ' || echo 0; }

python3 "$S" panel;               check "panel freezes, then opens the panel" "frozen 1" "$(st) $(calls qs.log)"
python3 "$S" panel;               check "second press: still one freeze, panel toggled" "frozen 1 2" "$(st) $(calls wf.log) $(calls qs.log)"
python3 "$S" unfreeze; sleep .2;  check "unfreeze (panel closed with Esc)" live "$(st)"
python3 "$S" panel; python3 "$S" full copy; sleep .2
check "Full screen takes the frozen picture, then lets go" "frozen live" "$(cat "$HOME/grim.state") $(st)"
python3 "$S" region save; sleep .2
check "Region freezes by itself when the panel did not" "frozen live 1" "$(cat "$HOME/grim.state") $(st) $(ls "$T/shots" | wc -l | tr -d ' ')"
python3 "$S" panel; cp "$T/bin/slurp" "$T/slurp.ok"; printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/slurp"
python3 "$S" region; sleep .2;    check "cancelled selection lets go, no file" "live 1" "$(st) $(ls "$T/shots" | wc -l | tr -d ' ')"
cp "$T/slurp.ok" "$T/bin/slurp"
python3 "$S" panel; python3 "$S" window; sleep .2; check "nothing to pick lets go" live "$(st)"
QS_FAIL=1 python3 "$S" panel; rc=$?; sleep .2; check "no panel running: never leave it frozen" "1 live" "$rc $(st)"
python3 "$S" panel; kill -9 "$(cat "$HALCYON_STATE/shot-freeze.pid")"; sleep .2; python3 "$S" panel
check "a dead freeze (stale pid) is replaced" frozen "$(st)"; python3 "$S" unfreeze; sleep .2
mv "$T/bin/wayfreeze" "$T/bin/wf.off"; python3 "$S" panel; rc=$?
check "without wayfreeze the panel still opens" "0 live" "$rc $(st)"
echo; echo "$((n-fails))/$n passed"; [ "$fails" = 0 ]
