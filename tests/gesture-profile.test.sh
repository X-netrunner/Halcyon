#!/usr/bin/env bash
# gesture-profile.sh: which layout counts as "niri" for the 4-finger gestures, and when does it reload Hyprland?
# Uses a fake `hyprctl` that only counts reloads, so no Hyprland is needed:  bash tests/gesture-profile.test.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0; n=0
export HOME="$T/home"; mkdir -p "$HOME/.config/Halcyon/hyprland" "$HOME/.local/state/island" "$T/bin"
S="$here/scripts/gesture-profile.sh"
GEN="$HOME/.config/Halcyon/hyprland/general.lua"; STATE="$HOME/.local/state/island"
cat > "$T/bin/hyprctl" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = reload ] && echo reload >> "$HOME/reloads.log"
FAKE
chmod +x "$T/bin/hyprctl"; export PATH="$T/bin:$PATH"

layout() { printf 'hl.config({\n    general = {\n        border_size = 2,\n        layout                  = "%s",\n    },\n})\n' "$1" > "$GEN"; }
float()  { printf '%s\n' "$1" > "$STATE/float-all"; }
stamp()  { if [ -n "$1" ]; then printf '%s\n' "$1" > "$STATE/gesture-profile"; else rm -f "$STATE/gesture-profile"; fi; }
reloads() { [ -f "$HOME/reloads.log" ] && wc -l < "$HOME/reloads.log" | tr -d ' ' || echo 0; }
check() { # check <label> <expected> <got>
  n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fails=$((fails+1)); fi
}
case_sync() { # case_sync <label> <layout> <float 0|1> <stamp> <expected reloads>
  rm -f "$HOME/reloads.log"; layout "$2"; float "$3"; stamp "$4"
  bash "$S" sync; check "$1" "$5" "$(reloads)"
}

# profile: only the scrolling layout with tiling on is "niri"; the No-tiling flag wins over a leftover scrolling in general.lua
layout dwindle;   float 0; check "profile dwindle"                  other "$(bash "$S" profile)"
layout scrolling; float 0; check "profile scrolling"                niri  "$(bash "$S" profile)"
layout scrolling; float 1; check "profile scrolling + no tiling"    other "$(bash "$S" profile)"
layout dwindle;   float 1; check "profile dwindle + no tiling"      other "$(bash "$S" profile)"
printf '    -- layout = "scrolling"\n' > "$GEN"; float 0
check "profile ignores a commented layout line"                      other "$(bash "$S" profile)"
rm -f "$GEN"; float 0; check "profile without general.lua"           other "$(bash "$S" profile)"
rm -f "$STATE/float-all"; layout scrolling; check "profile without float-all file" niri "$(bash "$S" profile)"

# sync: reload only when the profile moved
case_sync "dwindle -> scrolling reloads"            scrolling 0 other 1
case_sync "scrolling -> no tiling reloads"          scrolling 1 niri  1
case_sync "no tiling -> dwindle: nothing to do"     dwindle   0 other 0
case_sync "dwindle -> no tiling: nothing to do"     dwindle   1 other 0
case_sync "scrolling, already registered: no reload" scrolling 0 niri 0
case_sync "no stamp counts as other (old setup)"    dwindle   0 ""    0
case_sync "no stamp, scrolling: reloads once"       scrolling 0 ""    1
case_sync "no tiling -> scrolling reloads"          scrolling 0 other 1

# a second sync right after the reload (gestures.lua has rewritten the stamp) does nothing
rm -f "$HOME/reloads.log"; layout scrolling; float 0; stamp other
bash "$S" sync; stamp niri; bash "$S" sync
check "second sync after the stamp changed" 1 "$(reloads)"

bash "$S" bogus 2>/dev/null; check "unknown argument exits 2" 2 "$?"

echo; echo "$((n-fails))/$n passed"; [ "$fails" = 0 ]
