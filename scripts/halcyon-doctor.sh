#!/usr/bin/env bash
# halcyon-doctor.sh: why does Halcyon not look / work right?  Read-only: it changes nothing.
#   - are Hyprland, Quickshell and their Qt modules installed, and is the Hyprland new enough (Lua config: 0.55+)?
#   - does Hyprland accept the Halcyon config, and is it the config that is really loaded?
#   - is the island (Quickshell) running? if not: the last lines of its log, and how to start it by hand
#   - drivers: GPU (NVIDIA / Intel / AMD), keyboard light, gaming mode
# Run it from a terminal (SUPER+T) or from a text console (Ctrl+Alt+F3).
RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$R" "$N" "$*"; }
hdr()  { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
have() { command -v "$1" >/dev/null 2>&1; }

hdr "Hyprland"
if have Hyprland; then
  v=$(Hyprland --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
  if [ -n "$v" ] && [ "$(printf '%s\n0.55\n' "$v" | sort -V | head -n1)" != "0.55" ]; then bad "Hyprland $v is too old: the Halcyon config is Lua and needs 0.55 or newer (sudo pacman -Syu hyprland)"
  else ok "Hyprland ${v:-installed}"; fi
else bad "Hyprland is not installed (sudo pacman -S hyprland)"; fi
[ -f "$RICE/hyprland.lua" ] && ok "Halcyon files: $RICE" || bad "$RICE/hyprland.lua is missing: run ./install.sh from the Halcyon folder"
cfg="${HYPRLAND_CONFIG:-}"
if [ -n "$cfg" ]; then
  if [ -d "$cfg" ]; then bad "HYPRLAND_CONFIG=$cfg is a FOLDER. It must be the file (…/hyprland.lua), otherwise Hyprland starts with its defaults. unset it, or start with: start-halcyon"
  elif [ "$cfg" != "$RICE/hyprland.lua" ]; then warn "HYPRLAND_CONFIG points to $cfg (not Halcyon's hyprland.lua)"
  else ok "HYPRLAND_CONFIG = $cfg"; fi
fi
stub="$HOME/.config/hypr/hyprland.lua"
if [ -f "$stub" ] && grep -q "Halcyon/hyprland.lua" "$stub"; then ok "$stub loads Halcyon"
elif [ -f "$stub" ]; then warn "$stub exists but does not load Halcyon (the Halcyon session / start-halcyon does not need it; the plain Hyprland session does). Re-run ./install.sh to fix it"
else warn "no $stub (the plain Hyprland session would use its default config; the Halcyon session / start-halcyon is fine)"; fi
if have Hyprland && [ -f "$RICE/hyprland.lua" ]; then
  out=$(timeout 40 env HYPRLAND_CONFIG="$RICE/hyprland.lua" Hyprland --verify-config -c "$RICE/hyprland.lua" 2>&1)
  if grep -q 'config ok' <<<"$out"; then ok "Hyprland accepts the Halcyon config"
  elif grep -q 'Config parsing result' <<<"$out"; then bad "Hyprland reports errors in the config:"; sed -n '/Config parsing result/,$p' <<<"$out" | sed '1,2d' | head -n 15 | sed 's/^/      /'
  else warn "could not check the config here"; fi
fi
if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  have hyprctl && hyprctl configerrors 2>/dev/null | grep -v '^$' | head -n 10 | sed 's/^/      /'
fi

hdr "Quickshell (the island)"
if have quickshell; then ok "$(quickshell --version 2>&1 | head -n1)"; else bad "quickshell is not installed (sudo pacman -S quickshell)"; fi
for q in QtQuick/Layouts QtQuick/Shapes QtQuick/Effects QtQuick/Controls Qt/labs/folderlistmodel; do
  d=""; for base in /usr/lib/qt6/qml /usr/lib/qt/qml /usr/lib64/qt6/qml; do [ -d "$base/$q" ] && d=1; done
  [ -n "$d" ] && ok "Qt module $q" || bad "Qt module $q is missing (sudo pacman -S qt6-declarative qt6-5compat qt6-svg qt6-wayland)"
done
for sh in island; do   # the wallpaper layer is part of the island shell now (quickshell/island/Wallpaper.qml)
  if pgrep -f "quickshell.* -p .*quickshell/$sh" >/dev/null 2>&1 || pgrep -f "qs .*-p .*quickshell/$sh" >/dev/null 2>&1; then ok "the $sh shell is running"
  else
    bad "the $sh shell is NOT running"
    lg="$HOME/.cache/island/quickshell-$sh.log"
    if [ -s "$lg" ]; then echo "      last lines of $lg:"; tail -n 12 "$lg" | sed 's/^/      | /'
    else echo "      no log yet: it was never started. In Halcyon, run:  $RICE/scripts/start-shell.sh $sh"; fi
  fi
done
echo "  ${D}to see the errors live:  pkill quickshell; quickshell -p $RICE/quickshell/island${N}"
have notify-send || warn "notify-send missing (sudo pacman -S libnotify)"

hdr "Graphics"
gpus=$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display')
[ -n "$gpus" ] && echo "$gpus" | sed 's/^/  /' || warn "no GPU listed by lspci (virtual machine?)"
if grep -qi nvidia <<<"$gpus"; then
  if [ -r /proc/driver/nvidia/version ]; then ok "NVIDIA kernel driver loaded: $(head -n1 /proc/driver/nvidia/version | cut -c1-80)"
  else bad "an NVIDIA GPU is present but its driver is not loaded (reboot after install.sh, or: lsmod | grep nvidia; journalctl -b -k | grep -i nvidia)"; fi
  have nvidia-smi && ok "nvidia-smi works: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -n1)" || warn "nvidia-smi missing (nvidia-utils)"
fi
grep -qi intel <<<"$gpus" && { have vainfo && ok "Intel video acceleration: $(vainfo 2>/dev/null | grep -m1 'Driver version' | cut -c1-70)" || warn "vainfo missing (libva-utils), Intel media driver: intel-media-driver"; }
have vulkaninfo && { vulkaninfo --summary 2>/dev/null | grep -m3 'deviceName' | sed 's/^ */  Vulkan: /'; } || warn "vulkaninfo missing (vulkan-tools)"

hdr "Keyboard light"
if compgen -G "/sys/class/leds/*kbd?backlight*" >/dev/null; then ok "found: $(basename "$(ls -d /sys/class/leds/*kbd?backlight* | head -n1)")"
else warn "no keyboard light device: $RICE/scripts/kbd-backlight.sh doctor   (a desktop has none)"; fi
id -nG | tr ' ' '\n' | grep -qx input && ok "you are in the input group" || warn "not in the input group: sudo usermod -aG input \$USER, then log in again"
id -nG | tr ' ' '\n' | grep -qx video && ok "you are in the video group" || warn "not in the video group: sudo usermod -aG video \$USER, then log in again"

hdr "App themes (wallpaper colours in the apps)"
[ -f "$HOME/.cache/island/ansi.env" ] && ok "colours ready (~/.cache/island/ansi.env)" || warn "no colours yet: run $RICE/scripts/term-colors.sh --now"
A_ACC=$(sed -n 's/^A_ACC=//p' "$HOME/.cache/island/ansi.env" 2>/dev/null | head -n1)
[ -n "${STARSHIP_CONFIG:-}" ] && warn "STARSHIP_CONFIG is set ($STARSHIP_CONFIG): Starship reads THAT file, not ~/.config/starship.toml"
if have starship; then grep -q "HALCYON STARSHIP PALETTE" "$HOME/.config/starship.toml" 2>/dev/null && ok "Starship: Halcyon prompt + palette" || warn "Starship is installed but ~/.config/starship.toml is not the Halcyon one: $RICE/scripts/user-setup.sh app-themes"
  [ -n "${A_ACC:-}" ] && { grep -qi "^accent *= *\"$A_ACC\"" "$HOME/.config/starship.toml" 2>/dev/null && ok "Starship: colours match the wallpaper" || warn "Starship: palette is not the wallpaper's: $RICE/scripts/app-themes.sh --now  (then: tail ~/.cache/island/app-themes.log)"; }
else warn "starship not installed (sudo pacman -S starship)"; fi
if have fish; then
  grep -q __halcyon_colors "$HOME/.config/fish/conf.d/halcyon.fish" 2>/dev/null && ok "fish: Halcyon colours (re-applied at every prompt)" || warn "fish: colours missing or old: $RICE/scripts/app-themes.sh --now"
  [ -n "${A_ACC:-}" ] && grep -qi "fish_color_command ${A_ACC#\#}" "$HOME/.cache/island/halcyon-colors.fish" 2>/dev/null && ok "fish: colours match the wallpaper" || warn "fish: colours are not the wallpaper's: $RICE/scripts/app-themes.sh --now  (then: tail ~/.cache/island/app-themes.log)"
fi
have btop && { grep -q 'color_theme *= *"halcyon"' "$HOME/.config/btop/btop.conf" 2>/dev/null && ok "btop: halcyon theme" || warn "btop: not using the halcyon theme (run user-setup.sh app-themes)"; }
have yazi && { grep -q halcyon "$HOME/.config/yazi/theme.toml" 2>/dev/null && ok "yazi: halcyon flavor" || warn "yazi: not using the halcyon flavor (run user-setup.sh app-themes)"; }
have thunar && { grep -q ">>> halcyon >>>" "$HOME/.config/gtk-3.0/gtk.css" 2>/dev/null && ok "Thunar / GTK: halcyon colours" || warn "Thunar: run $RICE/scripts/gtk-theme.sh"; }
if have spicetify; then
  [ -f "$HOME/.config/spotify/prefs" ] && ok "Spotify (spicetify): theme written; after a Spotify update run $RICE/scripts/app-themes.sh --now" || warn "Spotify: start it once and log in, then run $RICE/scripts/app-themes.sh --now"
else warn "spicetify not installed (AUR: spicetify-cli): Spotify keeps its own colours"; fi
if have vesktop || [ -d "$HOME/.config/Vencord" ]; then [ -f "$HOME/.config/vesktop/themes/halcyon.theme.css" ] || [ -f "$HOME/.config/Vencord/themes/halcyon.theme.css" ] && ok "Discord (Vesktop / Vencord): halcyon theme file written" || warn "Discord theme missing: run $RICE/scripts/app-themes.sh --setup"
else warn "Discord: stock Discord cannot be themed. Install Vesktop (AUR: vesktop) to get the Halcyon colours"; fi

hdr "Gaming mode"
[ -x /usr/local/bin/halcyon-tune ] && ok "halcyon-tune installed" || warn "halcyon-tune missing: Gaming mode only changes visuals (run ./install.sh)"
sudo -n /usr/local/bin/halcyon-tune >/dev/null 2>&1; [ $? -eq 2 ] && ok "halcyon-tune runs without a password" || warn "halcyon-tune asks for a password (the sudoers rule is missing: run ./install.sh)"
have gamemoded && ok "GameMode installed" || warn "gamemode missing (sudo pacman -S gamemode)"
have powerprofilesctl && ok "power profile: $(powerprofilesctl get 2>/dev/null)" || warn "power-profiles-daemon missing"
echo

hdr "sysmode, prompt badge, reminders"
if have sysmode; then
  if [ -f "$RICE/sysmode/sysmode" ] && ! cmp -s "$RICE/sysmode/sysmode" "$(command -v sysmode)"; then warn "the installed sysmode differs from the one in $RICE/sysmode (run ./update.sh to install the new one)"; else ok "sysmode is the one from the rice"; fi
  m=; [ -r /etc/sysmode.mode ] && read -r m < /etc/sysmode.mode
  case "$m" in
    relaxed|secure|stealth|lockdown) ok "mode file: $m" ;;
    cyber|hacking) warn "mode file still says '$m' (the old name): current sysmode reads it fine; any switch ('sudo sysmode relaxed') rewrites it" ;;
    "") warn "no /etc/sysmode.mode yet: the prompt asks 'sysmode status' until you switch mode once" ;;
    *) warn "mode file says '$m': the prompt shows [mx]" ;;
  esac
  sc="$HOME/.config/starship.toml"
  if [ -f "$sc" ] && grep -q '^\[custom\.sysmode\]' "$sc"; then
    grep -qF "halcyon-sysmode-badge v2" "$sc" && ok "starship badge: current" || warn "starship.toml has an old sysmode badge (./update.sh or scripts/app-themes.sh fixes it)"
  fi
else ok "sysmode is not installed (skipped)"; fi
if [ -f "$RICE/scripts/remind.sh" ]; then bash "$RICE/scripts/remind.sh" status 2>/dev/null | sed 's/^/  /'; fi
echo

hdr "System & Process Health"
gvfs_pid=$(pgrep -x gvfsd-metadata 2>/dev/null | head -n1)
if [ -n "$gvfs_pid" ]; then
  gvfs_cpu=$(ps -p "$gvfs_pid" -o %cpu= 2>/dev/null | tr -d ' ' | cut -d. -f1)
  if [ -n "$gvfs_cpu" ] && [ "$gvfs_cpu" -gt 50 ]; then
    bad "gvfsd-metadata (PID $gvfs_pid) is consuming ${gvfs_cpu}% CPU! Corrupted GVFS metadata loop (fix: pkill -x gvfsd-metadata; rm -f ~/.local/share/gvfs-metadata/home*)"
  else
    ok "gvfsd-metadata healthy"
  fi
else
  ok "no gvfsd-metadata process running"
fi
zombies=$(ps -eo stat 2>/dev/null | grep -c '^[Zz]' || true)
zombies=${zombies:-0}
if [ "$zombies" -gt 0 ] 2>/dev/null; then
  warn "$zombies zombie (defunct) process(es) detected"
else
  ok "no zombie processes"
fi
avail_mb=$(awk '/MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
if [ "$avail_mb" -gt 0 ] && [ "$avail_mb" -lt 1024 ]; then
  warn "Low available memory: ${avail_mb} MB available"
else
  ok "available RAM: ${avail_mb} MB"
fi
echo
