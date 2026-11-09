#!/usr/bin/env bash
# screen-record.sh window: click a window, record the rectangle it fills, name the file window_*, stop with the same command.
# Fake hyprctl / slurp / wf-recorder, no compositor needed:  bash tests/screen-record-window.test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.config/Halcyon" "$HOME/.local/state/island" "$T/bin"
ln -s "$here/scripts" "$HOME/.config/Halcyon/scripts"
echo none > "$HOME/.local/state/island/rec-audio"; echo "$T/rec" > "$HOME/.local/state/island/rec-dir"
cat > "$T/bin/hyprctl" <<'EOF2'
#!/usr/bin/env bash
case "$1" in
 clients) echo '[{"mapped":true,"hidden":false,"workspace":{"id":1},"at":[100,50],"size":[800,600],"class":"firefox","title":"Docs"},{"mapped":true,"hidden":false,"workspace":{"id":7},"at":[0,0],"size":[300,300],"class":"away","title":"other workspace"}]';;
 monitors) echo '[{"activeWorkspace":{"id":1},"specialWorkspace":{"id":0},"focused":true,"name":"eDP-1"}]';;
esac
EOF2
printf '#!/usr/bin/env bash\nif [ "$1" = "-r" ]; then head -n1 | awk "{print \\$1\\" \\"\\$2}"; else echo "10,10 20x20"; fi\n' > "$T/bin/slurp"
cat > "$T/bin/wf-recorder" <<'EOF2'
#!/usr/bin/env bash
echo "$*" >> "$HOME/wf.args"; f=""; while [ $# -gt 0 ]; do [ "$1" = "-f" ] && f="$2"; shift; done
trap 'echo data > "$f"; exit 0' INT TERM; while :; do sleep 0.1; done
EOF2
printf '#!/usr/bin/env bash\necho "$*" >> "$HOME/notes.log"\n' > "$T/bin/notify-send"
chmod +x "$T/bin/"*; export PATH="$T/bin:$PATH"
S="$here/scripts/screen-record.sh"; fails=0; n=0
check() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fails=$((fails+1)); fi; }

bash "$S" window >/dev/null
check "starts recording" recording "$(bash "$S" status)"
check "records the window's rectangle (only windows on the visible workspace are offered)" "-g 100,50 800x600" "$(sed -E 's/^(-g [^ ]+ [^ ]+).*/\1/' "$HOME/wf.args")"
check "file is called window_*.mp4" window "$(basename "$(cat "$HOME/.local/state/island/record.file")" | cut -d_ -f1)"
check "the notice says Window" 1 "$(grep -c 'Window is recording' "$HOME/notes.log")"
sleep 0.3; bash "$S" window >/dev/null; sleep 0.3
check "the same command stops it" idle "$(bash "$S" status)"
check "the file is kept" 1 "$(ls "$T/rec" | wc -l | tr -d ' ')"
check "list and last know window_ files" "$(ls "$T/rec")" "$(bash "$S" list | xargs -n1 basename)"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/slurp"; rm -f "$HOME/wf.args"
bash "$S" window >/dev/null
check "a cancelled pick records nothing" "idle no" "$(bash "$S" status) $([ -f "$HOME/wf.args" ] && echo yes || echo no)"
echo; echo "$((n-fails))/$n passed"; [ "$fails" = 0 ]
