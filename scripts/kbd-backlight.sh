#!/usr/bin/env bash
# Keyboard backlight: status / up / down / set / toggle, and a "doctor" that explains why it is missing.
#   kbd-backlight.sh status          device, level (percent)
#   kbd-backlight.sh up|down [pct]   step (default 25%; the hardware has few levels, so a step always moves at least one)
#   kbd-backlight.sh set PCT         0-100
#   kbd-backlight.sh toggle          off <-> last level
#   kbd-backlight.sh doctor          is there a driver? can you write it? what to install  (add --load to try modprobe, asks sudo)
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bl="$here/backlight.sh"
state="$HOME/.local/state/island"; last="$state/kbd-last"
mkdir -p "$state"
line=$(bash "$bl" kbd | head -n1)
read -r dev cur max <<<"$line"

need_dev() { [ -n "$dev" ] || { echo "no keyboard backlight found (try: kbd-backlight.sh doctor)" >&2; exit 1; }; }
pct() { echo $(( cur * 100 / max )); }
setraw() { bash "$bl" set leds "$dev" "$1"; }

doctor() {
  echo "== keyboard backlight"
  if [ -n "$dev" ]; then echo "found: $dev  ($cur / $max)"; else echo "no /sys/class/leds/*kbd_backlight device"; fi
  vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null); prod=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
  echo "machine: ${vendor:-?} ${prod:-?}"
  if [ -n "$dev" ]; then
    f="/sys/class/leds/$dev/brightness"
    if [ -w "$f" ]; then echo "writable: yes"; else
      echo "writable: no directly (brightnessctl / logind can still do it)."
      id -nG | tr ' ' '\n' | grep -qx input || echo "  -> you are not in the 'input' group: sudo usermod -aG input \$USER  (then log in again)"
      [ -f /etc/udev/rules.d/90-halcyon-backlight.rules ] || echo "  -> udev rule missing: sudo install -Dm644 $here/../udev/90-halcyon-backlight.rules /etc/udev/rules.d/90-halcyon-backlight.rules && sudo udevadm control --reload && sudo udevadm trigger -s leds -s backlight"
    fi
    exit 0
  fi
  # no device: the kernel driver for this laptop is not loaded (or does not exist)
  mod=""; extra=""
  case "$vendor $prod" in
    *ASUS*)        mod="asus_nb_wmi"; extra="(asus-wmi creates asus::kbd_backlight; asusctl from the AUR adds profiles)" ;;
    *LENOVO*|*Lenovo*) case "$prod" in *ThinkPad*|*thinkpad*) mod="thinkpad_acpi" ;; *) mod="ideapad_laptop" ;; esac ;;
    *Dell*)        mod="dell_laptop"; extra="(also dell_smm_hwmon)" ;;
    *HP*|*Hewlett*) mod="hp_wmi"; extra="(only some HP models have a software-controlled keyboard light)" ;;
    *SAMSUNG*|*Samsung*) mod="samsung_laptop" ;;
    *Apple*)       mod="applesmc"; extra="(MacBooks: applesmc gives smc::kbd_backlight)" ;;
    *System76*)    mod="system76_acpi"; extra="(system76-dkms / system76-acpi-dkms from the AUR on non-System76 kernels)" ;;
    *TUXEDO*|*Clevo*|*SCHENKER*|*XMG*|*Eluktronics*) extra="install tuxedo-drivers-dkms (AUR); it creates rgb:kbd_backlight" ;;
    *MSI*|*Micro-Star*) mod="msi_ec"; extra="(msi-ec-dkms from the AUR on older kernels, or openrgb for per-key RGB boards)" ;;
    *Framework*)   mod="cros_kbd_led_backlight"; extra="(Framework: chromeos::kbd_backlight)" ;;
    *Acer*)        mod="acer_wmi"; extra="(Predator / Nitro 4-zone RGB: linuwu-sense-dkms from the AUR)" ;;
    *HUAWEI*|*Huawei*|*HONOR*) mod="huawei_wmi" ;;
    *Razer*)       extra="Razer keyboards are not a standard keyboard light: pacman -S openrazer-daemon, then polychromatic" ;;
  esac
  echo "(install.sh does this for you: it detects the laptop and loads / installs the driver. Re-run ./install.sh after a kernel change.)"
  if [ -n "$mod" ]; then
    echo "likely driver: $mod $extra"
    if modinfo "$mod" >/dev/null 2>&1; then
      if lsmod | grep -q "^$mod"; then echo "  $mod is loaded but exposes no keyboard light: this model may have none, or it is hardware-only (Fn key)."
      else
        echo "  $mod exists but is not loaded."
        if [ "$1" = --load ]; then
          sudo modprobe "$mod" && sleep 1 && ls /sys/class/leds | grep -i kbd && { echo "$mod" | sudo tee /etc/modules-load.d/halcyon-kbd.conf >/dev/null; echo "  loaded, and kept for every boot (/etc/modules-load.d/halcyon-kbd.conf)"; } || echo "  loading it did not create a keyboard light."
        else echo "  try:  $0 doctor --load"; fi
      fi
    else echo "  your kernel has no $mod module."; fi
  elif [ -n "$extra" ]; then echo "$extra"
  else echo "no known driver for this machine. Some keyboards only have a hardware (Fn) light, or need openrgb / a vendor tool."; fi
  exit 1
}

case "$1" in
  status|"") need_dev; echo "$dev $(pct)%" ;;
  up|down)
    need_dev
    step=$(( max * ${2:-25} / 100 )); [ "$step" -lt 1 ] && step=1
    if [ "$1" = up ]; then new=$(( cur + step )); [ "$new" -gt "$max" ] && new=$max; else new=$(( cur - step )); [ "$new" -lt 0 ] && new=0; fi
    [ "$cur" -gt 0 ] && echo "$cur" > "$last"
    setraw "$new" ;;
  set) need_dev; new=$(( max * ${2:-0} / 100 )); [ "$new" -gt "$max" ] && new=$max; [ "$cur" -gt 0 ] && echo "$cur" > "$last"; setraw "$new" ;;
  toggle)
    need_dev
    if [ "$cur" -gt 0 ]; then echo "$cur" > "$last"; setraw 0
    else v=$(cat "$last" 2>/dev/null); case "$v" in ''|*[!0-9]*) v=$max ;; esac; [ "$v" -lt 1 ] && v=$max; setraw "$v"; fi ;;
  doctor) doctor "$2" ;;
  *) echo "usage: kbd-backlight.sh status | up|down [pct] | set PCT | toggle | doctor [--load]" >&2; exit 2 ;;
esac
