#!/usr/bin/env bash
# Compiles one of the island's shaders with Qt's qsb into ~/.cache/halcyon/<name>.frag.qsb:
#   build-shader.sh [branch]   branch.frag, the tree-view branches (without it: the CPU Shape branches)
#   build-shader.sh sky        sky.frag, the Halcyon sky's dithered glow (without it: the Canvas gradients, which can band)
# Controlled via native helper `hal build-shader` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../../../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" build-shader "$@"
fi

name="${1:-branch}"
case "$name" in branch|sky) ;; *) exit 2 ;; esac
src="$(dirname "$0")/../$name.frag"
dir="$HOME/.cache/halcyon"
out="$dir/$name.frag.qsb"
mkdir -p "$dir"
if [ -s "$out" ] && [ ! "$src" -nt "$out" ]; then echo "$out"; exit 0; fi
q="$(command -v qsb || command -v qsb-qt6 || ls /usr/lib/qt6/bin/qsb /usr/lib/*-linux-gnu/qt6/bin/qsb /usr/lib64/qt6/bin/qsb 2>/dev/null | head -n1)"
[ -n "$q" ] || exit 1
"$q" --qt6 -o "$out" "$src" >/dev/null 2>&1 && [ -s "$out" ] && echo "$out"
