#!/usr/bin/env bash
# halcyon-doctor.sh: why does Halcyon not look / work right?  Read-only: it changes nothing,
#   except with --fix, which offers to install the optional tools it found missing (it asks first, and uses your package manager).
#   - are Hyprland, Quickshell and their Qt modules installed, and is the Hyprland new enough (Lua config: 0.55+)?
#   - does Hyprland accept the Halcyon config, and is it the config that is really loaded?
#   - is the island (Quickshell) running? if not: the last lines of its log, and how to start it by hand
#   - drivers: GPU (NVIDIA / Intel / AMD), keyboard light, gaming mode
# Run it from a terminal (SUPER+T) or from a text console (Ctrl+Alt+F3).
RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
FIX=0; for a in "$@"; do case "$a" in --fix) FIX=1 ;; -h|--help) sed -n 2,9p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac; done
G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$R" "$N" "$*"; }
hdr()  { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
have() { command -v "$1" >/dev/null 2>&1; }

if command -v apt-get >/dev/null 2>&1 && ! command -v pacman >/dev/null 2>&1; then
  PKG_INSTALL="sudo apt install"
  PKG_UPGRADE="sudo apt update && sudo apt install"
else
  PKG_INSTALL="sudo pacman -S"
  PKG_UPGRADE="sudo pacman -Syu"
fi

hdr "Hyprland"
if have Hyprland; then
  v=$(Hyprland --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
  if [ -n "$v" ] && [ "$(printf '%s\n0.55\n' "$v" | sort -V | head -n1)" != "0.55" ]; then bad "Hyprland $v is too old: the Halcyon config is Lua and needs 0.55 or newer ($PKG_UPGRADE hyprland)"
  else ok "Hyprland ${v:-installed}"; fi
else bad "Hyprland is not installed ($PKG_INSTALL hyprland)"; fi
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
if have quickshell; then ok "$(quickshell --version 2>&1 | head -n1)"; else bad "quickshell is not installed ($PKG_INSTALL quickshell)"; fi
for q in QtQuick/Layouts QtQuick/Shapes QtQuick/Effects QtQuick/Controls Qt/labs/folderlistmodel; do
  d=""; for base in /usr/lib/qt6/qml /usr/lib/qt/qml /usr/lib64/qt6/qml /usr/lib/x86_64-linux-gnu/qt6/qml /usr/lib/*-linux-gnu/qt6/qml; do [ -d "$base/$q" ] && d=1; done
  if [ -n "$d" ]; then ok "Qt module $q"
  elif [[ "$PKG_INSTALL" == *"apt"* ]]; then bad "Qt module $q is missing ($PKG_INSTALL qml6-module-qtquick-layouts qml6-module-qtquick-shapes qml6-module-qtquick-effects qml6-module-qtquick-controls qml6-module-qt-labs-folderlistmodel qml6-module-qt5compat-graphicaleffects libqt6svg6 qt6-wayland)"
  else bad "Qt module $q is missing ($PKG_INSTALL qt6-declarative qt6-5compat qt6-svg qt6-wayland)"; fi
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
have notify-send || warn "notify-send missing ($PKG_INSTALL libnotify)"

hdr "Graphics"
gpus=$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display')
[ -n "$gpus" ] && echo "$gpus" | sed 's/^/  /' || warn "no GPU listed by lspci (virtual machine?)"
if grep -qi nvidia <<<"$gpus"; then
  if [ -r /proc/driver/nvidia/version ]; then ok "NVIDIA kernel driver loaded: $(head -n1 /proc/driver/nvidia/version | cut -c1-80)"
  else bad "an NVIDIA GPU is present but its driver is not loaded (reboot after install.sh, or: lsmod | grep nvidia; journalctl -b -k | grep -i nvidia)"; fi
  nv_susp=0
  for d in /sys/bus/pci/devices/*; do
    if [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] && [[ "$(cat "$d/class" 2>/dev/null)" == 0x03* ]]; then
      [ "$(cat "$d/power/runtime_status" 2>/dev/null)" = "suspended" ] && nv_susp=1
    fi
  done
  if [ "$nv_susp" = 1 ]; then ok "NVIDIA dGPU sleeping in D3cold (skipped nvidia-smi to avoid waking GPU)"
  elif have nvidia-smi; then ok "nvidia-smi works: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -n1)"
  else warn "nvidia-smi missing (nvidia-utils)"; fi
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
if have starship && [ -e "$HOME/.local/state/island/keep-prompt" ]; then ok "Starship: your own prompt is kept, Halcyon does not touch it (./install.sh --choose to change that)"
elif have starship; then grep -q "HALCYON STARSHIP PALETTE" "$HOME/.config/starship.toml" 2>/dev/null && ok "Starship: Halcyon prompt + palette" || warn "Starship is installed but ~/.config/starship.toml is not the Halcyon one: $RICE/scripts/user-setup.sh app-themes"
  [ -n "${A_ACC:-}" ] && [ ! -e "$HOME/.local/state/island/keep-prompt" ] && { grep -qi "^accent *= *\"$A_ACC\"" "$HOME/.config/starship.toml" 2>/dev/null && ok "Starship: colours match the wallpaper" || warn "Starship: palette is not the wallpaper's: $RICE/scripts/app-themes.sh --now  (then: tail ~/.cache/island/app-themes.log)"; }
else warn "starship not installed ($PKG_INSTALL starship)"; fi
if have fish; then
  grep -q __halcyon_colors "$HOME/.config/fish/conf.d/halcyon.fish" 2>/dev/null && ok "fish: Halcyon colours (re-applied at every prompt)" || warn "fish: colours missing or old: $RICE/scripts/app-themes.sh --now"
  [ -n "${A_ACC:-}" ] && grep -qi "fish_color_command ${A_ACC#\#}" "$HOME/.cache/island/halcyon-colors.fish" 2>/dev/null && ok "fish: colours match the wallpaper" || warn "fish: colours are not the wallpaper's: $RICE/scripts/app-themes.sh --now  (then: tail ~/.cache/island/app-themes.log)"
fi
have btop && { grep -q 'color_theme *= *"halcyon"' "$HOME/.config/btop/btop.conf" 2>/dev/null && ok "btop: halcyon theme" || warn "btop: not using the halcyon theme (run user-setup.sh app-themes)"; }
have yazi && { grep -q halcyon "$HOME/.config/yazi/theme.toml" 2>/dev/null && ok "yazi: halcyon flavor" || warn "yazi: not using the halcyon flavor (run user-setup.sh app-themes)"; }
have micro && { grep -q '"colorscheme" *: *"halcyon"' "$HOME/.config/micro/settings.json" 2>/dev/null && ok "micro: halcyon colorscheme (transparent)" || warn "micro: not using the halcyon colorscheme (run user-setup.sh app-themes)"; }
have thunar && { grep -q ">>> halcyon >>>" "$HOME/.config/gtk-3.0/gtk.css" 2>/dev/null && ok "Thunar / GTK: halcyon colours" || warn "Thunar: run $RICE/scripts/gtk-theme.sh"; }
if have spicetify; then
  [ -f "$HOME/.config/spotify/prefs" ] && ok "Spotify (spicetify): theme written; after a Spotify update run $RICE/scripts/app-themes.sh --now" || warn "Spotify: start it once and log in, then run $RICE/scripts/app-themes.sh --now"
else warn "spicetify not installed (AUR: spicetify-cli): Spotify keeps its own colours"; fi
have spotify_player && { grep -q 'name = "halcyon"' "$HOME/.config/spotify-player/theme.toml" 2>/dev/null && grep -q '^theme *= *"halcyon"' "$HOME/.config/spotify-player/app.toml" 2>/dev/null && ok "spotify-player: halcyon theme (first run: spotify_player authenticate)" || warn "spotify-player: not using the halcyon theme (run user-setup.sh app-themes)"; }
if have vesktop || [ -d "$HOME/.config/Vencord" ]; then [ -f "$HOME/.config/vesktop/themes/halcyon.theme.css" ] || [ -f "$HOME/.config/Vencord/themes/halcyon.theme.css" ] && ok "Discord (Vesktop / Vencord): halcyon theme file written" || warn "Discord theme missing: run $RICE/scripts/app-themes.sh --setup"
else warn "Discord: stock Discord cannot be themed. Install Vesktop (AUR: vesktop) to get the Halcyon colours"; fi

hdr "Gaming mode"
[ -x /usr/local/bin/halcyon-tune ] && ok "halcyon-tune installed" || warn "halcyon-tune missing: Gaming mode only changes visuals (run ./install.sh)"
sudo -n /usr/local/bin/halcyon-tune >/dev/null 2>&1; [ $? -eq 2 ] && ok "halcyon-tune runs without a password" || warn "halcyon-tune asks for a password (the sudoers rule is missing: run ./install.sh)"
have gamemoded && ok "GameMode installed" || warn "gamemode missing ($PKG_INSTALL gamemode)"
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

hdr "Optional tools (a missing one only switches its own feature off)"
# name|what needs it|package
opt_tools='cava|audio visualiser in the music widgets|cava
magick|wallpaper colours (hx palette), portrait sky|imagemagick
brightnessctl|brightness keys and the top-edge gesture|brightnessctl
playerctl|media keys, now playing|playerctl
wl-copy|clipboard history|wl-clipboard
grim|screenshots|grim
slurp|area screenshots|slurp
clamscan|leak and malware checks (halcyon-leaks)|clamav
dmidecode|exact hardware names in the specs panel (needs root)|dmidecode
nmap|sysmode counter-recon|nmap
tcpdump|sysmode packet capture|tcpdump
ufw|sysmode firewall and honeypot bans|ufw
docker|sysmode honeypot runtime|docker
python3|Notes, local AI, calendar import, lyrics, Focus mode|python'
missing=0; miss_pkgs=()
while IFS='|' read -r cmd what pkg; do
  [ -n "$cmd" ] || continue
  if have "$cmd"; then ok "$cmd"
  else warn "$cmd not found: $what ($PKG_INSTALL $pkg)"; missing=$((missing+1)); miss_pkgs+=("$pkg"); fi
done <<<"$opt_tools"
[ "$missing" -eq 0 ] && ok "every optional tool is installed"
if [ "$missing" -gt 0 ]; then
  if [ "$FIX" = 1 ]; then
    case "$PKG_INSTALL" in *apt*) miss_pkgs=("${miss_pkgs[@]/#python/python3}") ;; esac   # apt calls it python3
    printf '\nInstall %s missing package(s)?  %s %s\n' "$missing" "$PKG_INSTALL" "${miss_pkgs[*]}"
    printf 'Install now? [y/N] '; read -r ans
    case "$ans" in y|Y|yes|Yes) $PKG_INSTALL "${miss_pkgs[@]}" ;; *) echo "skipped" ;; esac
  else
    printf '  %sTip:%s run  halcyon-doctor.sh --fix  to install the missing optional tools in one go.\n' "$D" "$N"
  fi
fi
echo
