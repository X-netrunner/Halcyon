#!/usr/bin/env bash
# The Halcyon boot splash: the login splash's stars and sparkle, played by Plymouth while Arch boots (and backwards on shutdown).
# Settings > Splash, sky & time of day > Boot splash (Plymouth), or by hand:
#   halcyon-plymouth.sh install    render the theme in your current colours and switch it on (asks for sudo; safe to run again,
#                                  e.g. after changing the accent: it only redoes what is needed)
#   halcyon-plymouth.sh remove     switch it off: the plymouth hook and the `splash` boot option come out, the initramfs is rebuilt
#   halcyon-plymouth.sh status     what is in place
#   halcyon-plymouth.sh preview    play it for 8 s (only from a text console, Ctrl+Alt+F3: Hyprland holds the screen otherwise)
#
# install does, in this order: pacman -S --needed plymouth python-pillow librsvg; renders the pictures (plymouth/render-assets.py,
# as you, not root) at your screen size; copies the theme to /usr/share/plymouth/themes/halcyon; makes it the default; adds the
# `plymouth` hook to /etc/mkinitcpio.conf after `udev` / `systemd`; adds `quiet splash` to the kernel command line (UKI:
# /etc/kernel/cmdline, systemd-boot entries, or GRUB); rebuilds the initramfs (mkinitcpio -P).
# Every file it edits is copied to <file>.before-halcyon-plymouth first (once), and the boot options it added are written to
# /etc/halcyon-plymouth.added, so remove takes out only what install put in.
set -euo pipefail

RICE="$HOME/.config/Halcyon"
THEME_DIR=/usr/share/plymouth/themes/halcyon
STATE=/etc/halcyon-plymouth.added
MKCONF=/etc/mkinitcpio.conf
PARAMS="quiet splash"
FILM=/usr/lib/halcyon/halcyon-plymouth-film
DROPIN_UNITS="plymouth-quit plymouth-poweroff plymouth-reboot plymouth-halt plymouth-kexec"

say()  { printf '\033[1;36m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] && die "run it as yourself, not root (it asks for sudo when it needs it)"

backup() { if sudo test -e "$1" && ! sudo test -e "$1.before-halcyon-plymouth"; then sudo cp -a "$1" "$1.before-halcyon-plymouth"; fi; }

# the theme colours: scheme/current.lua (primary, tertiary, background, onBackground), else the island's defaults
colour() {
  local v=""
  [[ -f "$RICE/scheme/current.lua" ]] && v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([0-9a-fA-F]\{6\}\)\".*/\1/p" "$RICE/scheme/current.lua" | head -1)
  echo "${v:-$2}"
}

# the biggest mode of the first connected screen (the built-in panel on a laptop), else 1920x1080
screen_size() {
  local s st
  for st in /sys/class/drm/card*-*/status; do
    [[ "$(cat "$st" 2>/dev/null)" == connected ]] || continue
    s=$(head -1 "$(dirname "$st")/modes" 2>/dev/null)
    [[ "$s" =~ ^[0-9]+x[0-9]+ ]] && { echo "${BASH_REMATCH[0]/x/ }"; return; }
  done
  echo "1920 1080"
}

# ---- kernel command line: add / take out words, wherever this machine keeps it
cmdline_files() {
  [[ -f /etc/kernel/cmdline ]] && echo /etc/kernel/cmdline
  sudo test -d /boot/loader/entries && sudo find /boot/loader/entries -maxdepth 1 -name '*.conf' 2>/dev/null
  [[ -f /etc/default/grub ]] && echo /etc/default/grub
  return 0
}
has_word() { grep -qE "(^|[[:space:]\"])$2([[:space:]\"]|$)" <<<"$1"; }

cmdline_add() {
  local f added=""
  local files; files=$(cmdline_files)
  [[ -n "$files" ]] || { warn "could not find the kernel command line (no /etc/kernel/cmdline, systemd-boot entries or GRUB): add '$PARAMS' yourself"; return; }
  for w in $PARAMS; do
    local need=0
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      case "$f" in
        /etc/default/grub)  has_word "$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f")" "$w" || need=1 ;;
        /etc/kernel/cmdline) has_word "$(cat "$f")" "$w" || need=1 ;;
        *)                  has_word "$(sudo grep -E '^options' "$f")" "$w" || need=1 ;;
      esac
    done <<<"$files"
    [[ $need -eq 1 ]] && added="$added $w"
  done
  added="${added# }"
  [[ -n "$added" ]] || { say "kernel command line already has: $PARAMS"; return; }
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    backup "$f"
    for w in $added; do
      case "$f" in
        /etc/default/grub)
          has_word "$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f")" "$w" || sudo sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"/\1 $w\"/" "$f" ;;
        /etc/kernel/cmdline)
          has_word "$(cat "$f")" "$w" || sudo sed -i -E "1s/[[:space:]]*$/ $w/" "$f" ;;
        *)
          has_word "$(sudo grep -E '^options' "$f")" "$w" || sudo sed -i -E "s/^(options[[:space:]].*[^[:space:]])[[:space:]]*$/\1 $w/" "$f" ;;
      esac
    done
    say "kernel command line: added '$added' in $f"
  done <<<"$files"
  # remember only what was added here, so remove never takes out a `quiet` you had before
  local prev=""; [[ -f "$STATE" ]] && prev=$(cat "$STATE")
  echo "$prev $added" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sudo tee "$STATE" >/dev/null
  [[ -f /etc/default/grub ]] && command -v grub-mkconfig >/dev/null && sudo grub-mkconfig -o /boot/grub/grub.cfg
  return 0
}

cmdline_remove() {
  [[ -f "$STATE" ]] || { say "no boot options were added by Halcyon: kernel command line left as it is"; return; }
  local words f; words=$(cat "$STATE")
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    for w in $words; do
      case "$f" in
        /etc/default/grub) sudo sed -i -E "/^GRUB_CMDLINE_LINUX_DEFAULT=/{s/([\" ])$w( |\")/\1\2/; s/  +/ /g; s/\" /\"/; s/ \"$/\"/}" "$f" ;;
        /etc/kernel/cmdline) sudo sed -i -E "1{s/(^| )$w( |$)/\1\2/; s/  +/ /g; s/^ //; s/ $//}" "$f" ;;
        *) sudo sed -i -E "/^options/{s/ $w( |$)/\1/; s/  +/ /g; s/ $//}" "$f" ;;
      esac
    done
    say "kernel command line: took out '$words' in $f"
  done <<<"$(cmdline_files)"
  sudo rm -f "$STATE"
  [[ -f /etc/default/grub ]] && command -v grub-mkconfig >/dev/null && sudo grub-mkconfig -o /boot/grub/grub.cfg
  return 0
}

# ---- let the film finish: boot and shutdown
# Boot: systemd tells Plymouth to quit as soon as the system is up (~2 s after it appeared here), which cut the film off. The helper
# holds that quit until the film is done (at most 2 s more), and --retain-splash leaves its last frame on screen until Hyprland
# (the lock screen) draws, so there is no black flash in between.
# Shutdown: Plymouth's power-off screen starts only after tty1 (your Hyprland session) has stopped, and the machine was off before
# the film ended. If the desktop has just played its goodbye (it leaves /dev/shm/halcyon-goodbye), the screen stays dark: no second
# film. Otherwise the film plays and the power-off waits for it (at most 3.5 s, while the rest of the shutdown carries on).
film_install() {
  sudo install -d -m 755 "$(dirname "$FILM")"
  sudo tee "$FILM" >/dev/null <<'SH'
#!/bin/sh
# halcyon-plymouth-film boot | shutdown   (installed by ~/.config/Halcyon/scripts/halcyon-plymouth.sh; see film_install there)
pid=$(pidof plymouthd 2>/dev/null | cut -d' ' -f1)
elapsed() {      # seconds this plymouthd has been running
  if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
    awk -v hz="$(getconf CLK_TCK 2>/dev/null || echo 100)" -v up="$(cut -d' ' -f1 /proc/uptime)" '{ print up - $22 / hz }' "/proc/$pid/stat"
  else echo 999; fi
}
wait_film() {    # until plymouthd has shown for $1 s, waiting $2 s at the most
  n=0; max=$(awk -v m="$2" 'BEGIN { print int(m * 10) }')
  while [ "$n" -lt "$max" ] && awk -v e="$(elapsed)" -v w="$1" 'BEGIN { exit !(e < w) }'; do sleep 0.1; n=$((n + 1)); done
}
case "$1" in
  boot)     wait_film 3.3 2.0 ;;
  shutdown) if [ -e /dev/shm/halcyon-goodbye ]; then plymouth update --status=halcyon-bare 2>/dev/null
            else wait_film 3.3 3.5; fi ;;
esac
exit 0
SH
  sudo chmod 755 "$FILM"
  local u
  for u in $DROPIN_UNITS; do
    sudo install -d -m 755 "/etc/systemd/system/$u.service.d"
    if [[ "$u" == plymouth-quit ]]; then
      printf '[Service]\nExecStartPre=-%s boot\nExecStart=\nExecStart=-/usr/bin/plymouth quit --retain-splash\n' "$FILM" | sudo tee "/etc/systemd/system/$u.service.d/halcyon.conf" >/dev/null
    else
      printf '[Service]\nExecStartPost=-%s shutdown\n' "$FILM" | sudo tee "/etc/systemd/system/$u.service.d/halcyon.conf" >/dev/null
    fi
  done
  sudo systemctl daemon-reload
  say "boot and shutdown wait for the film to finish ($FILM, drop-ins for: $DROPIN_UNITS)"
}
film_remove() {
  local u
  for u in $DROPIN_UNITS; do sudo rm -f "/etc/systemd/system/$u.service.d/halcyon.conf"; sudo rmdir "/etc/systemd/system/$u.service.d" 2>/dev/null || true; done
  sudo rm -f "$FILM"; sudo rmdir "$(dirname "$FILM")" 2>/dev/null || true
  sudo systemctl daemon-reload
}

# ---- mkinitcpio: the plymouth hook goes right after udev (or systemd), before any encrypt hook so the password prompt is drawn
hook_present() { grep -qE '^HOOKS=\(.*\bplymouth\b.*\)' "$MKCONF"; }
hook_add() {
  [[ -f "$MKCONF" ]] || { warn "$MKCONF not found: add the plymouth hook to your initramfs yourself"; return 1; }
  if hook_present; then say "mkinitcpio already has the plymouth hook"; return 0; fi
  backup "$MKCONF"
  if grep -qE '^HOOKS=\(.*\bsystemd\b' "$MKCONF"; then sudo sed -i -E '/^HOOKS=\(/s/\bsystemd\b/systemd plymouth/' "$MKCONF"
  elif grep -qE '^HOOKS=\(.*\budev\b' "$MKCONF"; then sudo sed -i -E '/^HOOKS=\(/s/\budev\b/udev plymouth/' "$MKCONF"
  else sudo sed -i -E '/^HOOKS=\(/s/\bbase\b/base plymouth/' "$MKCONF"; fi
  say "mkinitcpio: $(grep -E '^HOOKS=' "$MKCONF")"
}
hook_remove() {
  hook_present || { say "mkinitcpio has no plymouth hook"; return 0; }
  backup "$MKCONF"
  sudo sed -i -E '/^HOOKS=\(/{s/ plymouth\b//; s/\(plymouth /(/}' "$MKCONF"
  say "mkinitcpio: $(grep -E '^HOOKS=' "$MKCONF")"
}

do_install() {
  [[ -f "$RICE/plymouth/halcyon.script" && -f "$RICE/plymouth/render-assets.py" ]] || die "the theme files are missing from $RICE/plymouth (run ./install.sh or update.sh again)"
  say "packages: plymouth python-pillow librsvg"
  sudo pacman -S --needed --noconfirm plymouth python-pillow librsvg

  local work; work=$(mktemp -d); trap "rm -rf '$work'" EXIT
  local W H; read -r W H < <(screen_size)
  local a1 a2 bg tx
  a1=$(colour primary 9aa9d4); a2=$(colour tertiary c2add8); bg=$(colour background 14161f); tx=$(colour onBackground dcdde8)
  say "rendering for ${W}x${H} in #$a1 / #$a2"
  python3 -I "$RICE/plymouth/render-assets.py" "$work/theme" "$W" "$H" "$a1" "$a2" "$bg" "$tx" >/dev/null
  { cat "$work/theme/layout.script"; echo; cat "$RICE/plymouth/halcyon.script"; } > "$work/theme/halcyon.script"
  rm -f "$work/theme/layout.script"
  cat > "$work/theme/halcyon.plymouth" <<EOF
[Plymouth Theme]
Name=Halcyon
Description=Moving stars and the Halcyon sparkle (the Halcyon login splash, for boot and shutdown)
ModuleName=script

[script]
ImageDir=$THEME_DIR
ScriptFile=$THEME_DIR/halcyon.script
EOF
  sudo rm -rf "$THEME_DIR"
  sudo install -d -m 755 "$THEME_DIR"
  sudo install -m 644 "$work/theme/"* "$THEME_DIR/"
  say "theme installed in $THEME_DIR"
  sudo plymouth-set-default-theme halcyon
  film_install
  hook_add || true
  cmdline_add
  say "rebuilding the initramfs (mkinitcpio -P) ..."
  sudo mkinitcpio -P
  say "done: the Halcyon boot splash plays from the next boot. Changed your accent colour? Run this again."
  [[ -f /etc/kernel/cmdline ]] && grep -q -- '--splash' /etc/mkinitcpio.d/*.preset 2>/dev/null && \
    say "note: your UKI preset also shows the Arch logo for a moment before Plymouth (the --splash line in /etc/mkinitcpio.d/*.preset)"
  return 0
}

do_remove() {
  hook_remove
  cmdline_remove
  if command -v plymouth-set-default-theme >/dev/null && [[ "$(plymouth-set-default-theme 2>/dev/null)" == halcyon ]]; then
    sudo plymouth-set-default-theme bgrt 2>/dev/null || sudo plymouth-set-default-theme spinner 2>/dev/null || true
  fi
  sudo rm -rf "$THEME_DIR"
  film_remove
  say "rebuilding the initramfs (mkinitcpio -P) ..."
  sudo mkinitcpio -P
  say "done: no boot splash from the next boot (the plymouth package is still installed: sudo pacman -Rns plymouth to remove it)"
}

do_status() {
  if [[ -f "$THEME_DIR/halcyon.script" ]]; then echo "theme:        installed ($THEME_DIR)"; else echo "theme:        not installed"; fi
  if command -v plymouth-set-default-theme >/dev/null; then echo "default:      $(plymouth-set-default-theme 2>/dev/null)"; else echo "plymouth:     not installed"; fi
  if hook_present 2>/dev/null; then echo "mkinitcpio:   plymouth hook in place"; else echo "mkinitcpio:   no plymouth hook"; fi
  if grep -qw splash /proc/cmdline; then echo "this boot:    splash on"; else echo "this boot:    splash off (no 'splash' on the kernel command line)"; fi
  [[ -f "$STATE" ]] && echo "added by us:  $(cat "$STATE")"
  if [[ -x "$FILM" ]]; then echo "film:         boot and shutdown wait for it to finish"; else echo "film:         not set up (boot / shutdown may cut it short: run install)"; fi
  return 0
}

do_preview() {
  [[ -f "$THEME_DIR/halcyon.script" ]] || die "not installed yet: halcyon-plymouth.sh install"
  if [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
    die "Plymouth needs the whole screen: switch to a text console (Ctrl+Alt+F3), log in and run this there"
  fi
  sudo plymouthd --mode="${2:-boot}"
  sudo plymouth show-splash
  sleep "${1:-8}"
  sudo plymouth quit
}

case "${1:-}" in
  install) do_install ;;
  remove)  do_remove ;;
  status)  do_status ;;
  preview) do_preview "${2:-8}" "${3:-boot}" ;;
  *) echo "usage: halcyon-plymouth.sh install | remove | status | preview [seconds] [boot|shutdown]" >&2; exit 2 ;;
esac
