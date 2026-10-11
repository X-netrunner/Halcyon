#!/usr/bin/env bash
set -euo pipefail

REPO="/home/netrunner/Projects/Halcyon"
SRC="${1:-$HOME/.config/Halcyon}"

cd "$REPO"

echo "=== Syncing from $SRC ==="
rsync -av --delete --exclude='.git' "$SRC/" .

echo "=== Staging all changes ==="
git add -A

echo "=== Committing ==="
git commit -S -m "sync: $(date '+%Y-%m-%d %H:%M')" || { echo "Nothing to commit"; exit 0; }

echo "=== Pushing (force-with-lease) ==="
git push --force-with-lease origin main

echo "=== Done ==="
