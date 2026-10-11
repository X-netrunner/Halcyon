#!/usr/bin/env bash
# One JSON line every $1 seconds (default 2): {"gpu":<percent>,"state":"on|off|none"}
# Only runs while the performance page is open.
#   NVIDIA dGPU: "off" when it is runtime-suspended (we never poke nvidia-smi then, so this can't wake it)
#   AMD: /sys/class/drm/card*/device/gpu_busy_percent      none: no discrete GPU found
iv=${1:-2}
# wait without starting a `sleep` process: a timed read on a pipe nobody writes to
exec {nap}<> <(:)
pci=${PCI_ROOT:-/sys/bus/pci/devices}

nv=""
for d in "$pci"/*; do
  [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] || continue
  case "$(cat "$d/class" 2>/dev/null)" in 0x03*) nv=$d; break ;; esac
done
amd=""
if [ -z "$nv" ]; then
  for f in /sys/class/drm/card*/device/gpu_busy_percent; do
    [ -r "$f" ] && { amd=$f; break; }
  done
fi

num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

while true; do
  state=none; gpu=0
  if [ -n "$nv" ]; then
    rs=""; { read -r rs < "$nv/power/runtime_status"; } 2>/dev/null
    case "$rs" in
      suspended|suspending) state=off ;;
      *)
        out=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
        if [ -n "$out" ]; then state=on; gpu=$(num "${out//[[:space:]]/}"); else state=off; fi
        ;;
    esac
  elif [ -n "$amd" ]; then
    state=on; gpu=$(num "$(cat "$amd" 2>/dev/null)")
  fi
  printf '{"gpu":%d,"state":"%s"}\n' "$gpu" "$state"
  read -r -t "$iv" -u "$nap" _
done
