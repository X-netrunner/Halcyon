#!/usr/bin/env bash
# gpu-mode.sh dgpu | igpu | igpu-only | status
#   dgpu : the NVIDIA GPU draws the desktop (Hyprland + the island). Smoother with heavy blur, but the NVIDIA driver and the
#          GPU stay awake: more RAM (the NVIDIA userspace libs add ~100+ MB) and a lot more battery use.
#   igpu : the integrated GPU draws the desktop, the NVIDIA GPU sleeps until you run  prime-run <program>; Hyprland still
#          opens the NVIDIA GPU for its own ports (HDMI on many laptops), and on some laptops that alone keeps it awake.
#   igpu-only : as igpu, but Hyprland is not given the NVIDIA GPU at all, so it can really sleep (about 2.5 W less here).
#          Screens on the NVIDIA GPU's ports stay dark (unless one is connected when you log in); prime-run still works.
# Takes effect at the next login (Hyprland picks its GPU when it starts).
f="$HOME/.config/Halcyon/gpu-mode"
case "${1:-status}" in
  dgpu|igpu|igpu-only) mkdir -p "$(dirname "$f")"; echo "$1" > "$f"; echo "GPU mode: $1 (log out and back in to apply)" ;;
  status) echo "GPU mode: $(head -n1 "$f" 2>/dev/null || echo igpu)"
          [ -r /proc/driver/nvidia/version ] && echo "NVIDIA driver: loaded" || echo "NVIDIA driver: NOT loaded (dgpu mode is ignored without it)"
          pgrep -x Hyprland >/dev/null && for p in $(pgrep -x Hyprland); do grep -a -o 'AQ_DRM_DEVICES=[^[:cntrl:]]*' /proc/$p/environ 2>/dev/null; done; true ;;      # (status is not a failure just because Hyprland is not running)
  *) echo "usage: gpu-mode.sh dgpu|igpu|igpu-only|status" >&2; exit 2 ;;
esac
