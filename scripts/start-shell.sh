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
# (wait a few seconds: after `pkill quickshell` the old supervisor needs a moment to notice and let go of the lock. With -n the new
#  one found it still held, said "already running" and quit, and then nothing was left running at all)
flock -w 6 9 || { say "already running: nothing to do"; exit 0; }

qs="$(command -v quickshell || command -v qs || true)"
[ -n "$qs" ] || { alert "quickshell is not installed (Arch: sudo pacman -S quickshell | Debian/Ubuntu: run ./install.sh)"; exit 1; }
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

# On a hybrid laptop keep Quickshell on the integrated GPU (Mesa) and out of NVIDIA's 60MB shader compiler blob
# (libnvidia-gpucomp.so). Only when there REALLY is a non-NVIDIA GPU: on a desktop with only an NVIDIA card, forcing the Mesa EGL
# vendor left Quickshell with no usable GPU driver (software rendering, or no window at all).
# (not in dGPU mode, see scripts/gpu-mode.sh: there the island draws on the NVIDIA GPU like the compositor does)
gpu_mode="igpu"; [ -s "$RICE/gpu-mode" ] && gpu_mode="$(head -n1 "$RICE/gpu-mode")"
other_gpu=0; amd_gpu=0
for c in /sys/class/drm/card[0-9]*; do
  case "$c" in */card[0-9]*-*) continue ;; esac
  v="$(cat "$c/device/vendor" 2>/dev/null)"
  [ -n "$v" ] || continue
  [ "$v" != 0x10de ] && other_gpu=1
  [ "$v" = 0x1002 ] && amd_gpu=1
done
if [ "$gpu_mode" != dgpu ] && [ "$other_gpu" = 1 ] && [ -f /usr/share/glvnd/egl_vendor.d/50_mesa.json ]; then
  export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
fi
radeon_icd="$(ls /usr/share/vulkan/icd.d/radeon_icd*.json 2>/dev/null | head -n1)"
if [ "$gpu_mode" != dgpu ] && [ "$amd_gpu" = 1 ] && [ -n "$radeon_icd" ]; then
  export VK_DRIVER_FILES="$radeon_icd"
  export VK_ICD_FILENAMES="$radeon_icd"
fi

# Quickshell links jemalloc. Without tuning, jemalloc retains hundreds of megabytes across multi-core arenas.
# Restrict to 2 arenas and immediately purge dirty/muzzy pages back to the kernel.
# (decay of 0 returned pages on every free = constant madvise calls and page faults; a short delay keeps most of the RAM saving
#  for far less CPU. Override from the environment to A/B test:  HALCYON_JE_DIRTY_MS / HALCYON_JE_MUZZY_MS)
export MALLOC_CONF="narenas:2,dirty_decay_ms:${HALCYON_JE_DIRTY_MS:-1000},muzzy_decay_ms:${HALCYON_JE_MUZZY_MS:-3000},background_thread:true"
# Also tune glibc malloc (for Qt/driver allocations), QML V4 JS GC threshold, and QtQuick RHI atlas size:
export MALLOC_TRIM_THRESHOLD_=131072       # same value as hyprland/execs.lua (they used to disagree)
# (no MALLOC_MMAP_THRESHOLD_: forcing 64 KB allocations into their own mmap costs a syscall + page faults each time;
#  QV4_GC_MAX_ALLOC is not a Qt variable and did nothing)
export MALLOC_ARENA_MAX=2
export QSG_ATLAS_WIDTH=1024
export QSG_ATLAS_HEIGHT=1024

say "using $qs ($("$qs" --version 2>&1 | head -n1)) on $WAYLAND_DISPLAY, QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-}"
[ "$name" = island ] && bash "$RICE/scripts/notif-guard.sh" 2>/dev/null

# the log was only trimmed when the shell (re)started: a QML warning loop in a long session could grow it without limit.
# Check every 10 minutes (the shell appends with >>, so truncating in place is safe). The lock fd is closed for this helper.
( while sleep 600; do [ "$(stat -c %s "$log" 2>/dev/null || echo 0)" -gt 4194304 ] && : > "$log"; done ) 9>&- &
trim_pid=$!
trap 'kill "$trim_pid" 2>/dev/null' EXIT

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
