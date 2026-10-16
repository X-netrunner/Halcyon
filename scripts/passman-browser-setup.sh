#!/usr/bin/env bash
# passman-browser-setup.sh: lets Brave / Chromium-family browsers ask "save this login?" and store it in the Halcyon vault.
# Run it with:  passman browser     (safe to run again)
set -e
RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
HOST_NAME="com.halcyon.passman"
EXT_ID="bihpjkcllcnpjnnlcejklbnffgkkcfkf"                                   # fixed by the key in browser/passman-ext/manifest.json
HOST="$RICE/scripts/passman-host.py"
[ -f "$HOST" ] || { echo "[!] $HOST not found"; exit 1; }
chmod +x "$HOST"

n=0
for dir in BraveSoftware/Brave-Browser chromium google-chrome google-chrome-beta vivaldi microsoft-edge; do
  base="$HOME/.config/$dir"
  [ -d "$base" ] || continue
  mkdir -p "$base/NativeMessagingHosts"
  cat > "$base/NativeMessagingHosts/$HOST_NAME.json" <<JSON
{
  "name": "$HOST_NAME",
  "description": "Halcyon passman: saves logins into the Halcyon vault",
  "path": "$HOST",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXT_ID/"]
}
JSON
  echo "  host registered for $dir"
  n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "[!] No Chromium-family browser profile found in ~/.config (open the browser once, then run this again)."; exit 1; }

cat <<MSG

One step left, in the browser (once):
  1. open  brave://extensions   (chrome://extensions in other browsers)
  2. turn on Developer mode, click "Load unpacked"
  3. pick  $RICE/browser/passman-ext
After that, a login shows "Save password for <site>?" (Save / Not now / Never).
Tip: turn off the browser's own "Offer to save passwords" (brave://settings/passwords) so only one asks.
Bring your old Brave logins in:  Export in brave://password-manager/settings, then  passman import <file.csv>
MSG
