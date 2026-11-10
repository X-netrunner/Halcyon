#!/usr/bin/env bash
# special.sh: when does it start the app, and when does it only toggle the workspace?
# Uses a fake `hyprctl` (answers from fixture files, logs every dispatch), so no Hyprland is needed:  bash tests/special.test.sh
# The JSON cases need jq (installed on the CI runner); the plain-text fallback cases run with jq hidden from PATH.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0; n=0
export HOME="$T/home" XDG_RUNTIME_DIR="$T/run"; mkdir -p "$HOME/.config/Halcyon" "$HOME/.local/state/island" "$XDG_RUNTIME_DIR" "$T/bin"
cp "$here/scripts/special.sh" "$T/special.sh"
printf "MUSIC_CMD='touch \"%s/launched-music\"'\nCOMM_CMD='touch \"%s/launched-comm\"'\n" "$T" "$T" > "$HOME/.config/Halcyon/special.conf"

cat > "$T/bin/hyprctl" <<'FAKE'
#!/usr/bin/env bash
# fixtures: $T/mon.json $T/cli.json $T/mon.txt $T/cli.txt ; dispatches are appended to $T/dispatch.log
case "$*" in
  "monitors -j") cat "$FIX/mon.json" ;;  "clients -j") cat "$FIX/cli.json" ;;
  "monitors")    cat "$FIX/mon.txt" ;;   "clients")    cat "$FIX/cli.txt" ;;
  dispatch*)     echo "$*" >> "$FIX/dispatch.log" ;;
esac
FAKE
chmod +x "$T/bin/hyprctl"; export FIX="$T"

# state(): visible=0/1 for special:music, windows = list of "workspace|class"
state() {
  local visible=$1; shift
  local mon cl="" txt="" w ws cls sep=""
  if [ "$visible" = 1 ]; then mon='[{"specialWorkspace":{"name":"special:music"}}]'; else mon='[{"specialWorkspace":{"name":""}}]'; fi
  echo "$mon" > "$T/mon.json"
  if [ "$visible" = 1 ]; then echo "special workspace: -98 (special:music) on monitor eDP-1" > "$T/mon.txt"; else echo "special workspace: 0 () on monitor eDP-1" > "$T/mon.txt"; fi
  : > "$T/cli.txt"
  for w in "$@"; do
    ws=${w%%|*}; cls=${w#*|}
    cl+="$sep{\"class\":\"$cls\",\"workspace\":{\"name\":\"$ws\"}}"; sep=","
    printf 'Window 1 -> x:\n\tworkspace: 1 (%s)\n\tclass: %s\n' "$ws" "$cls" >> "$T/cli.txt"
  done
  echo "[$cl]" > "$T/cli.json"
  rm -f "$T/dispatch.log" "$T/launched-music" "$T/launched-comm" "$XDG_RUNTIME_DIR"/halcyon-special-*.stamp
}
run() { # run <label> <path> <name> [--show] ; sleep: setsid -f is asynchronous
  PATH="$2" bash "$T/special.sh" "${@:3}" >/dev/null 2>&1; sleep 0.25
}
check() { # check <label> <expect launch 0/1> <expect toggles>
  local got=0 tog=0; [ -e "$T/launched-music" ] && got=1
  [ -f "$T/dispatch.log" ] && tog=$(grep -c toggle_special "$T/dispatch.log")
  n=$((n+1))
  if [ "$got" = "$2" ] && [ "$tog" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (launched=$got want $2, toggles=$tog want $3)"; fails=$((fails+1)); fi
}

suite() { # suite <tag> <PATH>
  local P=$2 t=$1
  state 0;                                  run x "$P" music;            check "$t: empty and hidden -> shown and app started" 1 1
  state 0 "special:music|spotify";          run x "$P" music;            check "$t: has a window -> only toggled" 0 1
  state 1 "special:music|spotify";          run x "$P" music;            check "$t: showing with a window -> hidden, no start" 0 1
  state 1 "special:music|spotify";          run x "$P" music --show;     check "$t: --show never hides" 0 0
  state 1;                                  run x "$P" music --show;     check "$t: showing but empty (--show) -> app started" 1 0
  state 0 "2|Spotify";                      run x "$P" music;            check "$t: app already running on workspace 2 -> not started twice" 0 1
  state 0 "2|firefox";                      run x "$P" music;            check "$t: an unrelated window elsewhere does not block the start" 1 1
  state 0;                                  run x "$P" music; run x "$P" music; check "$t: two quick presses start one copy (8 s stamp)" 1 2
  state 0; echo '[]' > "$T/cli.json";       run x "$P" sysmon;           check "$t: workspaces without an app never start anything" 0 1
}

# a PATH with the basics but no jq (the text fallback)
mkdir -p "$T/nojq"; for b in bash sed grep tr cat head date setsid mkdir rm touch sleep sh dirname; do p=$(command -v "$b") && ln -sf "$p" "$T/nojq/$b"; done
ln -sf "$T/bin/hyprctl" "$T/nojq/hyprctl"

if command -v jq >/dev/null 2>&1; then suite json "$T/bin:$PATH"; else echo "skip json cases (jq not installed)"; fi
suite text "$T/nojq"

# a hyprctl that does not answer must never start the app (the old text-match bug)
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/hyprctl-dead"; chmod +x "$T/bin/hyprctl-dead"
if command -v jq >/dev/null 2>&1; then
  mkdir -p "$T/dead"; ln -sf "$T/bin/hyprctl-dead" "$T/dead/hyprctl"
  state 0; run x "$T/dead:$PATH" music; check "json: hyprctl silent -> app NOT started" 0 0
fi
echo "$((n-fails))/$n passed"; exit $((fails>0))
