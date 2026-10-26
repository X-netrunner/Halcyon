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

# ---- which GPU and which renderer the island draws with
# On a hybrid laptop keep Quickshell on the integrated GPU (Mesa) and out of NVIDIA's 60MB shader compiler blob
# (libnvidia-gpucomp.so). Only when there REALLY is a non-NVIDIA GPU: on a desktop with only an NVIDIA card, forcing the Mesa EGL
# vendor left Quickshell with no usable GPU driver (software rendering, or no window at all).
# (not in dGPU mode, see scripts/gpu-mode.sh: there the island draws on the NVIDIA GPU like the compositor does)
#
# Renderer: $RICE/renderer = auto | opengl | vulkan (install.sh --renderer, asked by --choose; HALCYON_RENDERER overrides it once).
# auto picks OpenGL wherever it works. Measured on an Intel laptop (whole island, idle): OpenGL 185 MB + 178 MB of GPU buffers,
# Vulkan 176 MB + 712 MB. On integrated graphics those buffers ARE system RAM, and Vulkan keeps a swapchain and memory pools per
# window (the island has many). The LLVM pages Vulkan avoids are already resident for Hyprland (it draws with Mesa GL), so
# skipping them frees nothing. Idle power is the same either way (the island redraws little), so nothing pays for the extra RAM.
# auto only takes Vulkan when there is no usable OpenGL (no Mesa EGL on a non-NVIDIA machine) but a Vulkan driver is there.
gpu_mode="igpu"; [ -s "$RICE/gpu-mode" ] && gpu_mode="$(head -n1 "$RICE/gpu-mode")"
renderer="${HALCYON_RENDERER:-}"; [ -z "$renderer" ] && [ -s "$RICE/renderer" ] && renderer="$(head -n1 "$RICE/renderer")"
case "$renderer" in opengl|vulkan) ;; *) renderer=auto ;; esac
other_gpu=0; amd_gpu=0; intel_gpu=0
for c in /sys/class/drm/card[0-9]*; do
  case "$c" in */card[0-9]*-*) continue ;; esac
  v="$(cat "$c/device/vendor" 2>/dev/null)"
  [ -n "$v" ] || continue
  [ "$v" != 0x10de ] && other_gpu=1
  [ "$v" = 0x1002 ] && amd_gpu=1
  [ "$v" = 0x8086 ] && intel_gpu=1
done
# first existing file of the given paths / globs, none of them an i686 or hasvk one unless asked: no `ls | grep` parsing
first_file() { local skip="$1" f; shift; for f in "$@"; do [ -f "$f" ] || continue; case "$f" in *i686*) continue ;; esac; [ -n "$skip" ] && case "$f" in *"$skip"*) continue ;; esac; printf '%s\n' "$f"; return 0; done; return 1; }
mesa_egl="$(first_file "" /usr/share/glvnd/egl_vendor.d/50_mesa.json /etc/glvnd/egl_vendor.d/50_mesa.json)"
vk_icd=""
if [ "$gpu_mode" != dgpu ] && [ "$other_gpu" = 1 ]; then
  # the Vulkan driver of the integrated GPU (never NVIDIA's): Intel ANV (hasvk for old Intel), AMD RADV
  if [ "$intel_gpu" = 1 ]; then
    vk_icd="$(first_file hasvk /usr/share/vulkan/icd.d/*intel*.json /etc/vulkan/icd.d/*intel*.json /usr/local/share/vulkan/icd.d/*intel*.json)"
    [ -z "$vk_icd" ] && vk_icd="$(first_file "" /usr/share/vulkan/icd.d/*hasvk*.json /etc/vulkan/icd.d/*hasvk*.json)"
  elif [ "$amd_gpu" = 1 ]; then
    vk_icd="$(first_file "" /usr/share/vulkan/icd.d/*radeon*.json /etc/vulkan/icd.d/*radeon*.json /usr/local/share/vulkan/icd.d/*radeon*.json)"
  fi
  # EGL stays on Mesa whichever renderer draws: anything in the process that still asks for OpenGL must not load NVIDIA's EGL
  # (that wakes the dGPU and maps its blob)
  [ -n "$mesa_egl" ] && export __EGL_VENDOR_LIBRARY_FILENAMES="$mesa_egl"
  if [ -n "$vk_icd" ]; then export VK_DRIVER_FILES="$vk_icd" VK_ICD_FILENAMES="$vk_icd"; fi
fi
if [ "$renderer" = auto ]; then
  renderer=opengl
  [ "$other_gpu" = 1 ] && [ -z "$mesa_egl" ] && [ -n "$vk_icd" ] && renderer=vulkan
fi
# Vulkan asked for but no Vulkan driver at all on this machine: Qt would show no window, so draw with OpenGL instead
if [ "$renderer" = vulkan ] && [ -z "$vk_icd" ] && [ -z "$(ls /usr/share/vulkan/icd.d/*.json /etc/vulkan/icd.d/*.json 2>/dev/null)" ]; then
  say "renderer: vulkan was chosen but no Vulkan driver is installed, using opengl"; renderer=opengl
fi
# a renderer set from outside (QSG_RHI_BACKEND in the environment) still wins
[ -z "${QSG_RHI_BACKEND:-}" ] && export QSG_RHI_BACKEND="$renderer"

# Quickshell links jemalloc. Without tuning, jemalloc retains hundreds of megabytes across multi-core arenas.
# Restrict to 2 arenas, disable retain so freed pages unmap cleanly, and purge dirty/muzzy pages back to the kernel.
# (decay of 0 returned pages on every free = constant madvise calls and page faults; a short delay keeps most of the RAM saving
#  for far less CPU. Override from the environment to A/B test:  HALCYON_JE_DIRTY_MS / HALCYON_JE_MUZZY_MS)
[ -z "${MALLOC_CONF:-}" ] && export MALLOC_CONF="narenas:2,retain:false,dirty_decay_ms:${HALCYON_JE_DIRTY_MS:-1000},muzzy_decay_ms:${HALCYON_JE_MUZZY_MS:-2000},background_thread:true"
# Also tune glibc malloc (for Qt/driver allocations), QML V4 JS GC threshold, and QtQuick RHI atlas size:
export MALLOC_TRIM_THRESHOLD_=131072       # same value as hyprland/execs.lua (they used to disagree)
export MALLOC_ARENA_MAX=2
export QSG_ATLAS_WIDTH=1024
export QSG_ATLAS_HEIGHT=1024
export QSG_RENDER_LOOP="${QSG_RENDER_LOOP:-basic}"
# Qt's Wayland text-input warns "Trying to enable ... but ... has focus" every time focus moves between the island's text fields:
# harmless, and it was most of the log (thousands of lines), hiding the real QML errors. Rules you set yourself still apply.
export QT_LOGGING_RULES="qt.qpa.wayland.textinput.warning=false${QT_LOGGING_RULES:+;$QT_LOGGING_RULES}"

say "using $qs ($("$qs" --version 2>&1 | head -n1)) on $WAYLAND_DISPLAY, QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-}, renderer=$QSG_RHI_BACKEND (gpu mode $gpu_mode)"
[ "$name" = island ] && bash "$RICE/scripts/notif-guard.sh" 2>/dev/null

# One idle helper loop (a second one for the caches was a third process): every 10 minutes the log is cut if it grew past 4 MB
# (a QML warning loop in a long session could grow it without limit; the shell appends with >>, so truncating in place is safe),
# and about 10 minutes after start, then every 6 hours, Halcyon's own caches are kept under their limits when Aggressive Memory Freeing
# is on (scripts/cache-trim.py, at the lowest priority). The lock fd is closed for this helper.
( n=0
  while sleep 600; do
    [ "$(stat -c %s "$log" 2>/dev/null || echo 0)" -gt 4194304 ] && : > "$log"
    # n counts 10-minute rounds: round 1 trims the caches (about 10 minutes in), then every 36th (6 hours)
    [ $((n % 36)) -eq 0 ] && nice -n 19 python3 "$RICE/scripts/cache-trim.py" >/dev/null 2>&1
    n=$((n + 1))
  done ) 9>&- &
trim_pid=$!
trap 'kill "$trim_pid" 2>/dev/null' EXIT INT TERM

fails=0
# Last-known-good settings: 60 s after a start that is still running, settings.json is copied to settings.json.good. If the shell then
# crashes twice in a row right after a start (a setting it cannot load), that copy is put back once, the broken file is kept as
# settings.json.crashed, and you get a notification. Nothing else is touched.
sf="$HOME/.local/state/island/settings.json"
restored=0
snap_pid=""
while :; do
  t0=$(date +%s)
  say "starting: $qs -p $dir"
  [ -n "$snap_pid" ] && kill "$snap_pid" 2>/dev/null
  ( sleep 60; pgrep -f -- "$qs -p $dir" >/dev/null 2>&1 && [ -s "$sf" ] && cp -f "$sf" "$sf.good" ) 9>&- >/dev/null 2>&1 &
  snap_pid=$!
  "$qs" -p "$dir" >> "$log" 2>&1 9>&-
  rc=$?
  up=$(( $(date +%s) - t0 ))
  say "exited with code $rc after ${up}s"
  case "$rc" in 0|130|143) break ;; esac            # closed on purpose (quickshell kill, Ctrl+C, log out)
  if [ "$up" -lt 10 ]; then fails=$((fails + 1)); else fails=0; fi
  if [ "$fails" -ge 2 ] && [ "$restored" = 0 ] && [ -s "$sf.good" ] && ! cmp -s "$sf" "$sf.good"; then
    restored=1
    cp -f "$sf" "$sf.crashed" 2>/dev/null
    if cp -f "$sf.good" "$sf"; then
      say "restored the last working settings (the broken file is $sf.crashed)"
      alert "it crashed on start, so your last working settings were put back (the broken file is kept as settings.json.crashed)."
      fails=0
    fi
  fi
  if [ "$fails" -ge 4 ]; then
    alert "it crashed $fails times in a row. Last lines: $(tail -n 3 "$log" | tr '\n' ' ' | cut -c1-300)  (full log: $log)"
    exit 1
  fi
  sleep "$((fails + 1))"
done
exit 0
