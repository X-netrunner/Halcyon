#!/bin/bash
# Start Halcyon (Hyprland with the Halcyon config) from a TTY, the login screen ("Halcyon" session) or start-halcyon.
#
# HYPRLAND_CONFIG has to name the config FILE (hyprland.lua), never the Halcyon folder. Hyprland takes that variable as
# "the" config file and prefers it over ~/.config/hypr/hyprland.lua; pointing it at a folder makes Hyprland fail to read
# its config and start with its built-in defaults (no island, no keybinds, nothing of Halcyon). That is what this script
# used to do. It now:
#   - finds the Halcyon folder from its own location,
#   - points HYPRLAND_CONFIG at <folder>/hyprland.lua (a folder value, from you or an old setup, is corrected),
#   - writes a short log to ~/.cache/island/launch.log (what it started, which config, which Hyprland).
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
RICE="${HALCYON_DIR:-$(dirname "$here")}"
[ -f "$RICE/hyprland.lua" ] || RICE="$HOME/.config/Halcyon"

cfg="${HYPRLAND_CONFIG:-}"
[ -d "$cfg" ] && cfg="${cfg%/}/hyprland.lua"          # a folder is not a config: use the file inside it
[ -n "$cfg" ] && [ -f "$cfg" ] || cfg="$RICE/hyprland.lua"
export HYPRLAND_CONFIG="$cfg"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ ! -d "$XDG_RUNTIME_DIR" ]; then mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null && chmod 700 "$XDG_RUNTIME_DIR"; fi
export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=Hyprland XDG_SESSION_DESKTOP=Hyprland

mkdir -p "$HOME/.cache/island" 2>/dev/null
log="$HOME/.cache/island/launch.log"
{
  echo "== $(date '+%F %T')  halcyon.sh  config=$cfg"
  command -v Hyprland >/dev/null 2>&1 && Hyprland --version 2>/dev/null | head -n1
  command -v quickshell >/dev/null 2>&1 || echo "WARNING: quickshell is not installed (sudo pacman -S quickshell)"
} >> "$log" 2>&1

# From the tty1 auto-login the console is still showing the boot splash (launch/halcyon-login.sh): text mode back before an error
text_console() { [ -t 0 ] && { python3 -c 'import fcntl; fcntl.ioctl(0, 0x4B3A, 0)' 2>/dev/null; printf '\033[?25h'; stty echo 2>/dev/null; }; }

if [ ! -f "$cfg" ]; then
  text_console
  echo "Halcyon: config not found: $cfg" | tee -a "$log" >&2
  echo "Run the installer again:  ./install.sh   (from the Halcyon folder)" >&2
  sleep 5; exit 1
fi

# Hyprland (and so everything it starts) gets fewer malloc arenas and trims freed memory back sooner: a lower resident size
# for a long-running session, at no visible cost on a laptop. Turn it off with  HALCYON_NO_MALLOC_TUNE=1  in your environment.
if [ -z "${HALCYON_NO_MALLOC_TUNE:-}" ]; then
  export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}" MALLOC_TRIM_THRESHOLD_="${MALLOC_TRIM_THRESHOLD_:-131072}"
fi

# GPU: ~/.config/Halcyon/gpu-mode = igpu | igpu-only | dgpu (change it with scripts/gpu-mode.sh). dgpu = the NVIDIA GPU draws the desktop.
mode=igpu; [ -s "$RICE/gpu-mode" ] && mode="$(head -n1 "$RICE/gpu-mode")"
if [ "$mode" = dgpu ] && [ -r /proc/driver/nvidia/version ]; then
  nv=""; others=""
  for c in /sys/class/drm/card[0-9]*; do
    [ -e "$c/device/vendor" ] || continue
    case "$c" in */card[0-9]*-*) continue ;; esac
    if [ "$(cat "$c/device/vendor")" = 0x10de ]; then nv="/dev/dri/${c##*/}"; else others="${others:+$others:}/dev/dri/${c##*/}"; fi
  done
  if [ -n "$nv" ]; then
    export AQ_DRM_DEVICES="$nv${others:+:$others}"        # first = renders, the others only scan out (hybrid laptop screens)
    export GBM_BACKEND=nvidia-drm __GLX_VENDOR_LIBRARY_NAME=nvidia LIBVA_DRIVER_NAME=nvidia NVD_BACKEND=direct
    echo "GPU mode: dgpu (AQ_DRM_DEVICES=$AQ_DRM_DEVICES)" >> "$log"
  else echo "GPU mode: dgpu asked for but no NVIDIA card found, using the default GPU" >> "$log"; fi
elif [ "$mode" = dgpu ]; then
  echo "GPU mode: dgpu asked for but the NVIDIA driver is not loaded, using the default GPU" >> "$log"
elif [ "$mode" = igpu-only ]; then
  # Hyprland opens every GPU it finds; holding the NVIDIA one (for its HDMI port) keeps it awake, about 2.5 W at 0 % load.
  # igpu-only hands Hyprland only the other GPUs: the NVIDIA one sleeps (prime-run still wakes it), its ports stay dark.
  # An NVIDIA card with a screen connected at login is kept, so a docked laptop never comes up black.
  keep=""; others=""; nvbusy=0
  for c in /sys/class/drm/card[0-9]*; do
    [ -e "$c/device/vendor" ] || continue
    case "$c" in */card[0-9]*-*) continue ;; esac
    if [ "$(cat "$c/device/vendor")" = 0x10de ]; then
      grep -qx connected "$c"/"${c##*/}"-*/status 2>/dev/null && { nvbusy=1; keep="${keep:+$keep:}/dev/dri/${c##*/}"; }
    else others="${others:+$others:}/dev/dri/${c##*/}"; fi
  done
  if [ -n "$others" ]; then
    export AQ_DRM_DEVICES="$others${keep:+:$keep}"
    echo "GPU mode: igpu-only (AQ_DRM_DEVICES=$AQ_DRM_DEVICES${keep:+, NVIDIA kept: a screen is on it})" >> "$log"
  else echo "GPU mode: igpu-only asked for but there is no other GPU, using the default" >> "$log"; fi
fi

# From the tty1 login (launch/halcyon-login.sh) the console still shows the boot splash: Hyprland's start-up text (its logo and
# log lines) would be drawn over it, so it goes to the launch log instead
if [ "${HALCYON_LOGIN_LOCK:-}" = 1 ]; then exec >>"$log" 2>&1; fi
# Started by the Halcyon login manager (greeter/shell.qml sets HALCYON_FROM_GREETER): nobody is looking at this session's output, and a
# session that dies at once leaves nothing behind but "session closed" in the greetd journal. So it all goes to the launch log: the
# environment the session got, what Hyprland printed, how it ended, and Hyprland's own log / crash report.
if [ "${HALCYON_FROM_GREETER:-}" = 1 ]; then
  {
    echo "-- started by the login manager as $(id -un) (uid $(id -u)), tty: $(tty 2>&1)"
    echo "-- XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-} ($(ls -ld "${XDG_RUNTIME_DIR:-/nonexistent}" 2>&1 | cut -c1-60))"
    echo "-- XDG_SESSION_ID=${XDG_SESSION_ID:-unset} XDG_SEAT=${XDG_SEAT:-unset} XDG_VTNR=${XDG_VTNR:-unset} XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-unset} DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unset}"
    echo "-- groups: $(id -Gn)"
    command -v loginctl >/dev/null 2>&1 && loginctl show-session "${XDG_SESSION_ID:-self}" -p Type -p Class -p Active -p State -p Seat -p VTNr 2>&1 | tr '\n' ' ' | sed 's/^/-- logind: /'; echo
    echo "-- libseat: $(ls -l /run/seatd.sock 2>&1 | cut -c1-70)"
  } >> "$log" 2>&1
  t0=$(date +%s)
  if command -v start-hyprland >/dev/null 2>&1; then start-hyprland >>"$log" 2>&1
  elif command -v Hyprland >/dev/null 2>&1; then Hyprland >>"$log" 2>&1
  else echo "Hyprland is not installed" >>"$log"; false; fi
  rc=$?
  {
    echo "== $(date '+%F %T')  Hyprland ended: exit $rc after $(( $(date +%s) - t0 )) s"
    hl=$(ls -t "${XDG_RUNTIME_DIR:-/nonexistent}"/hypr/*/hyprland.log 2>/dev/null | head -n1)
    [ -n "$hl" ] && { echo "-- last lines of $hl:"; tail -n 25 "$hl"; }
    cr=$(ls -t "$HOME"/.cache/hyprland/hyprlandCrashReport*.txt 2>/dev/null | head -n1)
    [ -n "$cr" ] && [ $(( $(date +%s) - $(stat -c %Y "$cr") )) -lt 120 ] && echo "-- crash report: $cr"
  } >> "$log" 2>&1
  exit "$rc"
fi
if command -v start-hyprland >/dev/null 2>&1; then exec start-hyprland; fi     # Hyprland's own start wrapper (0.53 and newer)
if command -v Hyprland >/dev/null 2>&1; then exec Hyprland; fi
text_console
echo "Halcyon: Hyprland is not installed (sudo pacman -S hyprland), then run ./install.sh" | tee -a "$log" >&2
sleep 5; exit 1
