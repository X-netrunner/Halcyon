#!/usr/bin/env bash
# gpu-mode.sh dgpu | igpu | igpu-only | status
# Controlled via native helper `hal gpu-mode` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" gpu-mode "$@"
fi

f="$HOME/.config/Halcyon/gpu-mode"
case "${1:-status}" in
  dgpu|igpu|igpu-only) mkdir -p "$(dirname "$f")"; echo "$1" > "$f"; echo "GPU mode: $1 (log out and back in to apply)" ;;
  status) echo "GPU mode: $(head -n1 "$f" 2>/dev/null || echo igpu)"
          [ -r /proc/driver/nvidia/version ] && echo "NVIDIA driver: loaded" || echo "NVIDIA driver: NOT loaded (dgpu mode is ignored without it)"
          pgrep -x Hyprland >/dev/null && for p in $(pgrep -x Hyprland); do grep -a -o 'AQ_DRM_DEVICES=[^[:cntrl:]]*' /proc/$p/environ 2>/dev/null; done; true ;;
  *) echo "usage: gpu-mode.sh dgpu|igpu|igpu-only|status" >&2; exit 2 ;;
esac
