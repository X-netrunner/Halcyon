#!/usr/bin/env bash
set -euo pipefail

REPO="/home/netrunner/Projects/Halcyon"
SRC="${1:-$HOME/.config/Halcyon}"
MSG="${2:-"sync: $(date '+%Y-%m-%d %H:%M')"}"  # 2nd arg = custom message

cd "$REPO"

# Preserve the script itself (in case source doesn't have it)
SCRIPT_CONTENT="$(cat /home/netrunner/.config/Halcyon/sync-and-push.sh 2>/dev/null || true)"

echo "=== Syncing from $SRC ==="
rsync -av --delete --exclude='.git' --exclude='sync-and-push.sh' "$SRC/" .

# Restore script if it was deleted
if [[ -n "$SCRIPT_CONTENT" && ! -f sync-and-push.sh ]]; then
    echo "$SCRIPT_CONTENT" > sync-and-push.sh
    chmod +x sync-and-push.sh
fi

echo "=== Staging all changes ==="
git add -A

echo "=== Committing ==="
git commit -S -m "$MSG" || { echo "Nothing to commit"; exit 0; }

echo "=== Fetching latest remote ==="
git fetch origin

echo "=== Pushing (force-with-lease) ==="
git push --force-with-lease origin main

echo "=== Done ==="
