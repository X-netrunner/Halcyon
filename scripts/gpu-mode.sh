#!/usr/bin/env bash
# gpu-mode.sh dgpu | igpu | status
#   dgpu : the NVIDIA GPU draws the desktop (Hyprland + the island). Smoother with heavy blur, but the NVIDIA driver and the
#          GPU stay awake: more RAM (the NVIDIA userspace libs add ~100+ MB) and a lot more battery use.
#   igpu : the integrated GPU draws the desktop, the NVIDIA GPU sleeps until you run  prime-run <program>.
# Takes effect at the next login (Hyprland picks its GPU when it starts).
f="$HOME/.config/Halcyon/gpu-mode"
case "${1:-status}" in
  dgpu|igpu) mkdir -p "$(dirname "$f")"; echo "$1" > "$f"; echo "GPU mode: $1 (log out and back in to apply)" ;;
  status) echo "GPU mode: $(head -n1 "$f" 2>/dev/null || echo igpu)"
          [ -r /proc/driver/nvidia/version ] && echo "NVIDIA driver: loaded" || echo "NVIDIA driver: NOT loaded (dgpu mode is ignored without it)"
          pgrep -x Hyprland >/dev/null && for p in $(pgrep -x Hyprland); do grep -a -o 'AQ_DRM_DEVICES=[^[:cntrl:]]*' /proc/$p/environ 2>/dev/null; done ;;
  *) echo "usage: gpu-mode.sh dgpu|igpu|status" >&2; exit 2 ;;
esac
