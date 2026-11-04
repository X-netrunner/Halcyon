#!/usr/bin/env bash
# halcyon-mem-where.sh : WHERE Quickshell's memory is. halcyon-mem.sh says how much; this splits one process (default: the island)
# by kind, using PSS (shared pages split fairly between the processes that map them).
# Controlled via native helper `hal mem where` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" mem where "$@"
fi

pid=${1:-$(pgrep -x quickshell | head -n1)}
[ -n "$pid" ] && [ -r /proc/$pid/smaps ] || { echo "no quickshell process found (pass a pid)"; exit 1; }
echo "pid $pid: $(tr '\0' ' ' < /proc/$pid/cmdline | cut -c1-90)"
awk '
  /^[0-9a-f]+-[0-9a-f]+ / { name = ($6 == "" ? "[anon]" : $6); for (i = 7; i <= NF; i++) name = name " " $i; next }
  /^Pss:/ {
    kb = $2
    k = "other"
    if (name == "[anon]" || name == "[heap]") k = "anon / heap (program data)"
    else if (name ~ /\/memfd:|\/dev\/shm|wayland|\/SYSV|\(deleted\)/) k = "shm / memfd (window buffers)"
    else if (name ~ /\/dev\/dri|\/dev\/nvidia|\/dev\/kfd|\/dev\/shm\/nv/) k = "gpu device memory"
    else if (name ~ /(mesa|radeon|amdgpu|vulkan|nvidia|libGL|libEGL|libgbm|libdrm|iris|llvm|libLLVM|dri\/)/) k = "gpu drivers (libraries)"
    else if (name ~ /libQt6|\/qt6\/|qml/) k = "Qt libraries and QML plugins"
    else if (name ~ /\.(ttf|otf|ttc)|fonts/) k = "fonts"
    else if (name ~ /\.so/) k = "other libraries"
    else if (name ~ /icons|\.cache|\.png|\.svg/) k = "icons / cache files"
    t[k] += kb; tot += kb
  }
  END { for (k in t) printf "%7.1f MB  %s\n", t[k] / 1024, k; printf "%7.1f MB  TOTAL (PSS)\n", tot / 1024 }
' /proc/$pid/smaps | sort -rn
echo; echo "RSS (counts shared pages in full): $(awk '/^VmRSS:/{print int($2/1024)" MB"}' /proc/$pid/status)"
