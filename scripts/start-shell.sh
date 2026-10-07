#!/usr/bin/env bash
# start-shell.sh island | wallpaper        start one Quickshell shell of Halcyon and keep it running
#
# Started by hyprland/execs.lua. Compared with a bare `quickshell -p ... &` it
#   - waits until the Wayland socket exists (the shell is useless, and exits at once, before that),
#   - finds the binary (quickshell, or its short name qs) and says clearly when it is not installed,
#   - frees the notification D-Bus name for the island (scripts/notif-guard.sh) right before it starts,
#   - writes everything Quickshell prints (QML errors included) to ~/.cache/island/quickshell-<name>.log,
#   - starts it again when it crashes (a growing pause; it gives up after 4 crashes in a row and shows a notification),
#   - never runs twice for the same shell.
# Run it by hand in a terminal inside Halcyon to see what is wrong:   ~/.config/Halcyon/scripts/start-shell.sh island
name="${1:-island}"
case "$name" in island|wallpaper) ;; *) echo "usage: start-shell.sh island|wallpaper" >&2; exit 2 ;; esac

RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
dir="$RICE/quickshell/$name"
state="$HOME/.cache/island"
mkdir -p "$state" "$HOME/.local/state/island"
log="$state/quickshell-$name.log"
[ "$(stat -c %s "$log" 2>/dev/null || echo 0)" -gt 1048576 ] && : > "$log"      # keep it small

say() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$name" "$*" >> "$log"; }
alert() {   # a message you can actually see, plus the log
  say "PROBLEM: $*"
  command -v hyprctl >/dev/null 2>&1 && hyprctl notify 3 15000 "rgb(ff6b6b)" "Halcyon ($name): $*" >/dev/null 2>&1
  command -v notify-send >/dev/null 2>&1 && notify-send -a Halcyon -u critical "Halcyon: $name shell" "$*" >/dev/null 2>&1
  echo "start-shell.sh: $*" >&2
}

# one supervisor per shell
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/halcyon-shell-$name.lock"
flock -n 9 || { say "already running: nothing to do"; exit 0; }

qs="$(command -v quickshell || command -v qs || true)"
[ -n "$qs" ] || { alert "quickshell is not installed (sudo pacman -S quickshell, or run ./install.sh)"; exit 1; }
[ -f "$dir/shell.qml" ] || { alert "$dir/shell.qml is missing: run ./install.sh again"; exit 1; }

# the Wayland socket (Hyprland creates it before it runs the autostart, but be patient anyway: up to 15 s)
for _ in $(seq 1 150); do
  [ -n "${WAYLAND_DISPLAY:-}" ] && [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$WAYLAND_DISPLAY" ] && break
  sleep 0.1
done
[ -n "${WAYLAND_DISPLAY:-}" ] || { alert "no WAYLAND_DISPLAY: not started from inside a Wayland session"; exit 1; }

# Ensure UTF-8 locale for Wayland and xkbcommon compose tables
case "${LANG:-}" in
  *.[uU][tT][fF]-8|*.[uU][tT][fF]8) ;;
  *) export LANG="${LANG:-en_US}.UTF-8" ;;
esac

# On hybrid AMD + NVIDIA systems, keep Quickshell on the integrated GPU (Mesa/Radeon)
# and prevent loading NVIDIA's 60MB shader compiler blob (libnvidia-gpucomp.so) into RAM
if [ -f /usr/share/glvnd/egl_vendor.d/50_mesa.json ]; then
  export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
fi
if [ -f /usr/share/vulkan/icd.d/radeon_icd.json ]; then
  export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/radeon_icd.json
  export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json
fi

# Quickshell links jemalloc. Without tuning, jemalloc retains hundreds of megabytes across multi-core arenas.
# Restrict to 2 arenas and immediately purge dirty/muzzy pages back to the kernel.
export MALLOC_CONF="narenas:2,dirty_decay_ms:0,muzzy_decay_ms:0,background_thread:true"

say "using $qs ($("$qs" --version 2>&1 | head -n1)) on $WAYLAND_DISPLAY, QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-}"
[ "$name" = island ] && bash "$RICE/scripts/notif-guard.sh" 2>/dev/null

fails=0
while :; do
  t0=$(date +%s)
  say "starting: $qs -p $dir"
  "$qs" -p "$dir" >> "$log" 2>&1 9>&-
  rc=$?
  up=$(( $(date +%s) - t0 ))
  say "exited with code $rc after ${up}s"
  case "$rc" in 0|130|143) break ;; esac            # closed on purpose (quickshell kill, Ctrl+C, log out)
  if [ "$up" -lt 10 ]; then fails=$((fails + 1)); else fails=0; fi
  if [ "$fails" -ge 4 ]; then
    alert "it crashed $fails times in a row. Last lines: $(tail -n 3 "$log" | tr '\n' ' ' | cut -c1-300)  (full log: $log)"
    exit 1
  fi
  sleep "$((fails + 1))"
done
exit 0
