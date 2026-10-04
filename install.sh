#!/usr/bin/env bash
# One-shot setup for Halcyon: builds the Rust helpers that ship in src/ (power-manager, touchpad-gestures,
# hx = the island data feeds + sysmode status / IDS / dossier), installs their user services, and
# (optionally) installs the `sysmode` CLI system-wide. No Python is needed by the island any more.
#   ./install.sh                  everything
#   SKIP_SYSMODE=1 ./install.sh   skip the sudo step for sysmode
set -euo pipefail

RICE="${RICE:-$HOME/.config/Halcyon}"
BIN="$RICE/bin"
UNITS="$HOME/.config/systemd/user"

command -v cargo >/dev/null || { echo "cargo not found (pacman -S rust)"; exit 1; }
for d in power-manager touchpad-gestures hx; do
  [ -f "$RICE/src/$d/Cargo.toml" ] || { echo "missing $RICE/src/$d (is the rice at $RICE?)"; exit 1; }
done

mkdir -p "$BIN" "$UNITS"
systemctl --user stop power-manager.service touchpad-gestures.service 2>/dev/null || true
pkill -x touchpad-gestures 2>/dev/null || true   # also an old copy started by hand / by an older config
for d in power-manager touchpad-gestures hx; do
  echo "== building $d"
  (cd "$RICE/src/$d" && cargo build --release)
  install -m755 "$RICE/src/$d/target/release/$d" "$BIN/$d"
done

install -m644 "$RICE"/systemd/*.service "$UNITS/"
chmod +x "$RICE"/scripts/*.sh "$RICE"/launch/*.sh

systemctl --user daemon-reload
systemctl --user start touchpad-gestures.service || echo "touchpad-gestures failed to start (journalctl --user -u touchpad-gestures)"

if [ "${SKIP_SYSMODE:-0}" != 1 ]; then
  echo "== installing sysmode (sudo)"
  sudo install -Dm755 "$RICE/sysmode/sysmode" /usr/local/bin/sysmode
  sudo install -Dm755 "$BIN/hx" /usr/local/bin/hx     # sysmode uses it for `dossier` and the IDS daemon
  sudo install -Dm644 "$RICE/sysmode/sysmode.8" /usr/local/share/man/man8/sysmode.8
  # brings the honeypot / IDS back after every reboot while the saved mode is stealth
  sudo install -Dm644 "$RICE/sysmode/sysmode-daemons.service" /etc/systemd/system/sysmode-daemons.service
  sudo systemctl daemon-reload
  sudo systemctl enable sysmode-daemons.service >/dev/null 2>&1 || echo "   could not enable sysmode-daemons.service"
  sudo install -Dm644 "$RICE/sysmode/sysmode.bash-completion" /usr/share/bash-completion/completions/sysmode
  echo "   sysmode doctor  checks its own dependencies"
fi

# RAM type / speed / channels for the performance page: dmidecode needs root, so save its output once
# (an empty / failed read no longer overwrites a good cache file; re-run scripts/refresh-ram.sh any time)
if command -v dmidecode >/dev/null; then
  echo "== reading RAM info (sudo dmidecode)"
  bash "$RICE/scripts/refresh-ram.sh" >/dev/null 2>&1 || echo "   skipped (no sudo?); the page will show size only. Try: ~/.config/Halcyon/scripts/refresh-ram.sh"
else
  echo "note: dmidecode not installed (sudo pacman -S dmidecode), then run ~/.config/Halcyon/scripts/refresh-ram.sh; until then the RAM card shows size only"
fi

id -nG | tr ' ' '\n' | grep -qx input || echo "note: you are not in the 'input' group; gestures and idle detection read /dev/input (sudo usermod -aG input \$USER, then re-login)"
id -nG | tr ' ' '\n' | grep -qx video || echo "note: you are not in the 'video' group; the top-edge brightness gesture runs as a background service and brightnessctl may not be allowed to write the backlight there (sudo usermod -aG video \$USER, then re-login)"

missing=""
for c in python3 foot pkexec fuzzel brightnessctl playerctl grim slurp wl-copy pactl nmcli bluetoothctl lspci lsblk hyprsunset bemoji wayfreeze; do
  command -v "$c" >/dev/null || missing="$missing $c"
done
[ -z "$missing" ] || echo "optional/missing tools (python3 is now only needed by the recon-deceiver honeypot):$missing   (pactl = audio menu, lspci = GPU name, hyprsunset = nightlight, bemoji = emoji picker, wayfreeze = frozen screenshots)"

echo "restart the island to pick up the changes:  pkill quickshell; quickshell -p $RICE/quickshell/island &"
echo "gestures not working?  journalctl --user -u touchpad-gestures -e   (needs the input group, brightnessctl, wpctl, playerctl)"
echo "done. Auto power: click Auto in the island (or SUPER+ALT+P). Cheatsheet: SUPER+ALT+/"
