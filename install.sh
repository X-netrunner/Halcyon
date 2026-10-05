#!/usr/bin/env bash
# Halcyon: ONE script that sets everything up on Arch Linux. Run it from the folder you downloaded:
#     ./install.sh            (asks for your password with sudo when it needs it)
#     ./install.sh --yes      (no questions: for a fresh machine / a script)
#
# What it does, in order
#   1. copies the rice to ~/.config/Halcyon (backs up an older copy)           -> everything refers to that path
#   2. installs the packages (Hyprland, Quickshell, fonts, audio, tools, ...) with pacman
#   3. builds the Rust helpers (hx, power-manager, touchpad-gestures)
#   4. makes Hyprland load Halcyon: ~/.config/hypr/hyprland.lua + a "Halcyon" login-screen session
#   5. user services (gestures, auto power) and system services (sysmode, honeypot / IDS at boot, RAM info)
#   6. wallpaper folder (a first wallpaper is made if it is empty) -> colours of the island AND your terminals
#   7. terminal colour files for foot / kitty / alacritty / ghostty, included once in each terminal's config
#   8. groups (input, video) and a final report
# Safe to run again any time: it only changes what is missing or old.
#
# Options:  --yes  no prompts          --no-packages  skip pacman / AUR       --no-sysmode  skip the hardening CLI + sudo services
#           --tty-autostart  start Halcyon automatically when you log in on tty1       -h  this help
set -uo pipefail

YES=0; PACKAGES=1; SYSMODE=1; TTY_AUTOSTART=0
for a in "$@"; do
  case "$a" in
    -y|--yes) YES=1 ;;
    --no-packages) PACKAGES=0 ;;
    --no-sysmode) SYSMODE=0 ;;
    --tty-autostart) TTY_AUTOSTART=1 ;;
    -h|--help) sed -n 2,22p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a (try --help)"; exit 2 ;;
  esac
done
[ "${SKIP_SYSMODE:-0}" = 1 ] && SYSMODE=0

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RICE="$HOME/.config/Halcyon"
BIN="$RICE/bin"
UNITS="$HOME/.config/systemd/user"
STAMP="$(date +%Y%m%d-%H%M%S)"
WARN=()

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '   \033[33m!\033[0m %s\n' "$*"; WARN+=("$*"); }
ask()  { [ "$YES" = 1 ] && return 0; read -r -p "$1 [Y/n] " r; [[ ! "$r" =~ ^[nN] ]]; }

[ "$(id -u)" -ne 0 ] || { echo "Run this as your normal user, not root (it uses sudo only where needed)."; exit 1; }
command -v sudo >/dev/null || { echo "sudo is required (pacman -S sudo)."; exit 1; }

# ------------------------------------------------------------------------------------------------ 1. rice folder
say "1/8  Halcyon folder"
if [ "$(readlink -f "$SRC")" != "$(readlink -f "$RICE")" ]; then
  if [ -d "$RICE" ] && [ -n "$(ls -A "$RICE" 2>/dev/null)" ]; then
    mkdir -p "$HOME/.config/Halcyon-backups"
    cp -a "$RICE" "$HOME/.config/Halcyon-backups/Halcyon-$STAMP" && ok "old copy saved in ~/.config/Halcyon-backups/Halcyon-$STAMP"
  fi
  mkdir -p "$RICE"
  # keep the things that belong to YOU: your own settings files, wallpapers are elsewhere
  tar -C "$SRC" --exclude='./src/*/target' --exclude='./bin' --exclude='./.git' -cf - . | tar -C "$RICE" -xf -
  ok "copied to $RICE"
else
  ok "already in $RICE"
fi
mkdir -p "$BIN" "$UNITS" "$HOME/.cache/island" "$HOME/.local/state/island" "$HOME/logs"
chmod +x "$RICE"/scripts/*.sh "$RICE"/launch/*.sh "$RICE"/quickshell/island/scripts/*.sh "$RICE"/sysmode/sysmode 2>/dev/null

# ------------------------------------------------------------------------------------------------ 2. packages
say "2/8  Packages"
if [ "$PACKAGES" = 1 ] && command -v pacman >/dev/null; then
  # core: the desktop. Every name here is in the official repos.
  CORE=(hyprland xdg-desktop-portal-hyprland hypridle hyprlock hyprsunset hyprutils
        quickshell qt6-base qt6-declarative qt6-svg qt6-wayland qt6-5compat
        rust imagemagick cava playerctl brightnessctl libnotify
        pipewire pipewire-pulse wireplumber libpulse pavucontrol
        networkmanager network-manager-applet bluez bluez-utils blueman power-profiles-daemon
        polkit polkit-kde-agent xdg-utils xdg-user-dirs
        grim slurp wl-clipboard cliphist fuzzel
        pciutils dmidecode lsof jq git base-devel zenity
        inter-font ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji)
  # a terminal, a browser and a file manager, only if you have none of that kind yet (you can change them in Settings > Default apps)
  have_any() { for c in "$@"; do command -v "$c" >/dev/null && return 0; done; return 1; }
  have_any foot kitty alacritty wezterm ghostty konsole gnome-terminal xterm || CORE+=(foot)
  have_any firefox chromium google-chrome-stable brave vivaldi-stable zen-browser librewolf floorp qutebrowser || CORE+=(firefox)
  have_any dolphin nautilus thunar nemo pcmanfm pcmanfm-qt caja || CORE+=(thunar)
  # sysmode (hardening profiles): optional, large
  SYS=(nmap tcpdump ufw audit docker python)
  TODO=()
  for p in "${CORE[@]}"; do pacman -Qq "$p" >/dev/null 2>&1 || TODO+=("$p"); done
  if [ "$SYSMODE" = 1 ]; then for p in "${SYS[@]}"; do pacman -Qq "$p" >/dev/null 2>&1 || TODO+=("$p"); done; fi
  if [ "${#TODO[@]}" -gt 0 ]; then
    echo "   to install: ${TODO[*]}"
    if ask "   install these with pacman now?"; then
      NC=(); [ "$YES" = 1 ] && NC=(--noconfirm)
      sudo pacman -S --needed "${NC[@]}" "${TODO[@]}" || {
        # one unknown name should not stop everything: retry one by one
        for p in "${TODO[@]}"; do sudo pacman -S --needed "${NC[@]}" "$p" >/dev/null 2>&1 || warn "could not install $p (name changed or not in the repos?)"; done
      }
    else warn "skipped packages; things may be missing"; fi
  else ok "all packages already installed"; fi
  # optional AUR extras (emoji picker, frozen screenshots): only when an AUR helper exists
  AURH=""; for h in yay paru; do command -v "$h" >/dev/null && AURH="$h" && break; done
  if [ -n "$AURH" ]; then
    for p in bemoji wayfreeze; do
      command -v "$p" >/dev/null || { [ "$YES" = 1 ] || ask "   install $p from the AUR ($AURH)?" ; } && "$AURH" -S --needed --noconfirm "$p" >/dev/null 2>&1 || true
    done
  else ok "no AUR helper found: bemoji (emoji picker) and wayfreeze (frozen screenshots) are optional, skipped"; fi
  systemctl is-enabled NetworkManager >/dev/null 2>&1 || sudo systemctl enable --now NetworkManager >/dev/null 2>&1 || true
  systemctl is-enabled bluetooth >/dev/null 2>&1 || sudo systemctl enable --now bluetooth >/dev/null 2>&1 || true
  systemctl is-enabled power-profiles-daemon >/dev/null 2>&1 || sudo systemctl enable --now power-profiles-daemon >/dev/null 2>&1 || true
  systemctl --user enable --now pipewire pipewire-pulse wireplumber >/dev/null 2>&1 || true
  if [ "$SYSMODE" = 1 ] && command -v docker >/dev/null; then sudo systemctl enable --now docker >/dev/null 2>&1 || true; fi
  xdg-user-dirs-update >/dev/null 2>&1 || true
elif [ "$PACKAGES" = 1 ]; then
  warn "pacman not found: this installer is for Arch / Arch-based systems. Install the packages from README.md by hand, then run again with --no-packages."
else ok "skipped (--no-packages)"; fi

if command -v Hyprland >/dev/null; then
  hv=$(Hyprland --version 2>/dev/null | grep -o 'v\?[0-9]\+\.[0-9]\+\(\.[0-9]\+\)\?' | head -n1 | tr -d v)
  case "$hv" in 0.[0-4]*|0.5[0-4]*) warn "Hyprland $hv found; Halcyon's config is written in Lua, which needs Hyprland 0.55 or newer (sudo pacman -Syu hyprland)" ;; *) ok "Hyprland ${hv:-installed}" ;; esac
else warn "Hyprland is not installed"; fi

# ------------------------------------------------------------------------------------------------ 3. build
say "3/8  Building the Rust helpers"
if command -v cargo >/dev/null; then
  systemctl --user stop power-manager.service touchpad-gestures.service 2>/dev/null || true
  pkill -x touchpad-gestures 2>/dev/null || true
  for d in hx power-manager touchpad-gestures; do
    [ -f "$RICE/src/$d/Cargo.toml" ] || { warn "missing $RICE/src/$d"; continue; }
    echo "   building $d (the first time takes a few minutes)"
    if (cd "$RICE/src/$d" && cargo build --release 2>&1 | tail -n 3); then
      if [ -f "$RICE/src/$d/target/release/$d" ]; then install -m755 "$RICE/src/$d/target/release/$d" "$BIN/$d" && ok "$d"; else warn "$d did not build (run: cd $RICE/src/$d && cargo build --release)"; fi
    fi
  done
else warn "cargo not found (sudo pacman -S rust): the island data feeds and power manager were not built"; fi

# ------------------------------------------------------------------------------------------------ 4. hyprland entry
say "4/8  Making Hyprland load Halcyon"
mkdir -p "$HOME/.config/hypr"
HL="$HOME/.config/hypr/hyprland.lua"
STUB='-- Halcyon: loads the whole rice from ~/.config/Halcyon (written by install.sh)
dofile(os.getenv("HOME") .. "/.config/Halcyon/hyprland.lua")'
if [ -f "$HL" ] && grep -q "Halcyon/hyprland.lua" "$HL"; then ok "~/.config/hypr/hyprland.lua already points at Halcyon"
else
  if [ -e "$HL" ] || [ -e "$HOME/.config/hypr/hyprland.conf" ]; then
    mkdir -p "$HOME/.config/hypr/backup-$STAMP"
    for f in hyprland.lua hyprland.conf; do [ -e "$HOME/.config/hypr/$f" ] && mv "$HOME/.config/hypr/$f" "$HOME/.config/hypr/backup-$STAMP/$f"; done
    ok "your old Hyprland config is in ~/.config/hypr/backup-$STAMP"
  fi
  printf '%s\n' "$STUB" > "$HL" && ok "~/.config/hypr/hyprland.lua now loads Halcyon"
fi
# a "Halcyon" session for the login screen (SDDM / GDM / greetd list /usr/share/wayland-sessions)
if [ -d /usr/share/wayland-sessions ] || sudo mkdir -p /usr/share/wayland-sessions 2>/dev/null; then
  printf '[Desktop Entry]\nName=Halcyon\nComment=Hyprland with the Halcyon island\nExec=%s/launch/halcyon.sh\nType=Application\nDesktopNames=Hyprland\n' "$RICE" | sudo tee /usr/share/wayland-sessions/halcyon.desktop >/dev/null && ok "login-screen session \"Halcyon\" added"
fi
if [ "$TTY_AUTOSTART" = 1 ]; then
  P="$HOME/.bash_profile"
  grep -q "halcyon.sh" "$P" 2>/dev/null || { printf '\n# Halcyon: start the desktop on tty1\nif [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = /dev/tty1 ]; then exec %s/launch/halcyon.sh; fi\n' "$RICE" >> "$P"; ok "tty1 now starts Halcyon on login (~/.bash_profile)"; }
fi

# ------------------------------------------------------------------------------------------------ 5. services
say "5/8  Services"
install -m644 "$RICE"/systemd/power-manager.service "$RICE"/systemd/touchpad-gestures.service "$UNITS/" 2>/dev/null && ok "user services installed (gestures start with the desktop, Auto power from the island)"
systemctl --user daemon-reload 2>/dev/null || true
if [ -x "$BIN/touchpad-gestures" ] && [ -n "${WAYLAND_DISPLAY:-}" ]; then systemctl --user start touchpad-gestures.service 2>/dev/null || true; fi

# RAM type / speed for the performance page: dmidecode needs root, so a system service saves it at every boot
if command -v dmidecode >/dev/null; then
  sudo install -Dm644 "$RICE/systemd/halcyon-ram.service" /etc/systemd/system/halcyon-ram.service \
    && sudo systemctl daemon-reload \
    && sudo systemctl enable --now halcyon-ram.service >/dev/null 2>&1 \
    && ok "RAM details saved (/var/lib/halcyon/dmi-memory.txt, refreshed every boot)" \
    || warn "could not set up the RAM info service; use Settings > Detect RAM details instead"
  [ -s /var/lib/halcyon/dmi-memory.txt ] || warn "dmidecode returned no memory info; the RAM card will show the size only"
else warn "dmidecode missing: the RAM card shows the size only (sudo pacman -S dmidecode, then run this again)"; fi

if [ "$SYSMODE" = 1 ]; then
  sudo install -Dm755 "$RICE/sysmode/sysmode" /usr/local/bin/sysmode
  [ -x "$BIN/hx" ] && sudo install -Dm755 "$BIN/hx" /usr/local/bin/hx
  sudo install -Dm644 "$RICE/sysmode/sysmode.8" /usr/local/share/man/man8/sysmode.8
  sudo install -Dm644 "$RICE/sysmode/sysmode.bash-completion" /usr/share/bash-completion/completions/sysmode
  sudo install -Dm644 "$RICE/sysmode/sysmode-daemons.service" /etc/systemd/system/sysmode-daemons.service
  sudo systemctl daemon-reload
  sudo systemctl enable sysmode-daemons.service >/dev/null 2>&1 && ok "sysmode installed; the honeypot and IDS come back at every boot when the mode is stealth" || warn "could not enable sysmode-daemons.service"
  [ -f /etc/sysmode.conf ] || printf 'SYS_USER=%s\nSYS_HOME=%s\n' "$USER" "$HOME" | sudo tee /etc/sysmode.conf >/dev/null
else ok "sysmode skipped (--no-sysmode)"; fi

# ------------------------------------------------------------------------------------------------ 6. wallpaper + palette
say "6/8  Wallpaper and colours"
WP="$HOME/Pictures/Wallpapers"
mkdir -p "$WP"
if [ -z "$(find "$WP" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null | head -n1)" ]; then
  if command -v magick >/dev/null || command -v convert >/dev/null; then
    IM=magick; command -v magick >/dev/null || IM=convert
    $IM -size 2560x1600 gradient:'#1b2340-#6a4c93' -rotate 15 -gravity center -crop 2560x1600+0+0 +repage "$WP/halcyon-default.png" 2>/dev/null \
      && ok "no wallpapers found: made a first one ($WP/halcyon-default.png). Put your own pictures in $WP; Settings > Next wallpaper picks a new one."
  else warn "no wallpapers in $WP and ImageMagick is missing"; fi
fi
first=$(find "$WP" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null | head -n1)
if [ -n "$first" ] && [ -x "$BIN/hx" ]; then
  "$BIN/hx" palette "$first" && ok "colours made from $(basename "$first")"
fi

# ------------------------------------------------------------------------------------------------ 7. terminals
say "7/8  Terminal colours that follow the wallpaper"
bash "$RICE/scripts/term-colors.sh" && ok "colour files written for foot, kitty, alacritty, ghostty, wezterm"
# include each file once, at the top of the terminal's own config (your settings stay yours)
add_line() { # file, marker, line
  mkdir -p "$(dirname "$1")"; [ -f "$1" ] || : > "$1"
  grep -q "$2" "$1" 2>/dev/null || { { printf '%s\n' "$3"; cat "$1"; } > "$1.new" && mv "$1.new" "$1"; ok "$(basename "$(dirname "$1")"): colours included"; }
}
command -v foot >/dev/null && add_line "$HOME/.config/foot/foot.ini" "halcyon-colors" "include=$HOME/.config/foot/halcyon-colors.ini"
command -v kitty >/dev/null && add_line "$HOME/.config/kitty/kitty.conf" "halcyon-colors" "include halcyon-colors.conf"
command -v ghostty >/dev/null && add_line "$HOME/.config/ghostty/config" "halcyon-colors" "config-file = halcyon-colors"
if command -v alacritty >/dev/null; then
  A="$HOME/.config/alacritty/alacritty.toml"; [ -f "$A" ] || : > "$A"
  grep -q "halcyon-colors" "$A" || { { printf '[general]\nimport = ["~/.config/alacritty/halcyon-colors.toml"]\n\n'; cat "$A"; } > "$A.new" && mv "$A.new" "$A"; ok "alacritty: colours included"; }
fi
command -v wezterm >/dev/null && ok "wezterm: add  local h = dofile(os.getenv('HOME')..'/.config/wezterm/halcyon-colors.lua'); config.colors = h  to your wezterm.lua (it cannot be included automatically)"
ok "open terminals are repainted on every wallpaper change; 'Terminal colours from wallpaper' in Settings does it on demand"

# ------------------------------------------------------------------------------------------------ 8. groups + report
say "8/8  Permissions"
NEEDGRP=()
for g in input video; do id -nG | tr ' ' '\n' | grep -qx "$g" || NEEDGRP+=("$g"); done
if [ "${#NEEDGRP[@]}" -gt 0 ]; then
  sudo usermod -aG "$(IFS=,; echo "${NEEDGRP[*]}")" "$USER" && ok "added you to: ${NEEDGRP[*]} (touchpad gestures, idle detection, brightness). LOG OUT AND IN AGAIN for it to apply." \
    || warn "could not add you to ${NEEDGRP[*]}: sudo usermod -aG input,video \$USER"
else ok "you are in the input and video groups"; fi

# screen + keyboard backlight "driver" layer: a udev rule so your user may write both without root, then a check that the
# kernel driver for your keyboard light is there (asus-wmi, thinkpad_acpi, dell-laptop, ... create /sys/class/leds/*kbd_backlight)
if [ -f "$RICE/udev/90-halcyon-backlight.rules" ]; then
  sudo install -Dm644 "$RICE/udev/90-halcyon-backlight.rules" /etc/udev/rules.d/90-halcyon-backlight.rules \
    && sudo udevadm control --reload 2>/dev/null && sudo udevadm trigger -s leds -s backlight 2>/dev/null \
    && ok "backlight rule installed (screen: group video, keyboard light: group input)" \
    || warn "could not install the backlight udev rule (sudo install -Dm644 $RICE/udev/90-halcyon-backlight.rules /etc/udev/rules.d/)"
fi
if ls /sys/class/leds/ 2>/dev/null | grep -qi 'kbd.backlight'; then ok "keyboard backlight driver found: $(ls /sys/class/leds | grep -i 'kbd.backlight' | head -n1)"
else
  echo "   no keyboard backlight device yet; checking which driver this laptop needs:"
  bash "$RICE/scripts/kbd-backlight.sh" doctor 2>&1 | sed 's/^/   /' | head -n 8
  warn "no keyboard backlight device found (a desktop or a hardware-only light is fine). Laptop? run: ~/.config/Halcyon/scripts/kbd-backlight.sh doctor --load"
fi
[ -s /etc/hostname ] || true

echo
echo "─────────────────────────────────────────────────────────────"
if [ "${#WARN[@]}" -gt 0 ]; then
  printf '\033[1;33mDone, with %d note(s):\033[0m\n' "${#WARN[@]}"; for w in "${WARN[@]}"; do echo "  - $w"; done
else printf '\033[1;32mDone. Everything installed.\033[0m\n'; fi
cat <<MSG

Start it:   log out, pick the "Halcyon" session on the login screen (or "Hyprland": it loads Halcyon too),
            or from a TTY run:  $RICE/launch/halcyon.sh
Already inside a running Halcyon?  restart the island:  pkill quickshell; quickshell -p $RICE/quickshell/island &
First keys: SUPER+ALT+/ cheatsheet · SUPER+TAB workspace tree · SUPER+SPACE launcher · Settings from the island
Hardening:  sudo sysmode doctor   (checks its own tools),   sudo sysmode stealth   (honeypot + IDS)
Problems:   journalctl --user -u touchpad-gestures -e    ·   re-run ./install.sh any time, it is safe
MSG
