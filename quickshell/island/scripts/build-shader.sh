#!/usr/bin/env bash
# Compiles branch.frag (tree-branch shader) with Qt's qsb into ~/.cache/halcyon/branch.frag.qsb.
# Prints the .qsb path when it is usable (freshly built, or an up-to-date one already there), nothing otherwise.
# qsb comes with qt6-shadertools. Without it the tree view simply keeps the CPU Shape branches.
src="$(dirname "$0")/../branch.frag"
dir="$HOME/.cache/halcyon"
out="$dir/branch.frag.qsb"
mkdir -p "$dir"
if [ -s "$out" ] && [ ! "$src" -nt "$out" ]; then echo "$out"; exit 0; fi
q="$(command -v qsb || ls /usr/lib/qt6/bin/qsb 2>/dev/null | head -n1)"
[ -n "$q" ] || exit 1
"$q" --qt6 -o "$out" "$src" >/dev/null 2>&1 && [ -s "$out" ] && echo "$out"
