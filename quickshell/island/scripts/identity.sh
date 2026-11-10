#!/usr/bin/env bash
# 5 lines: username, full name (from passwd), hostname, OS pretty name, laptop model
# Controlled via native helper `hal identity` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../../../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" identity "$@"
fi

u=$(id -un)
printf '%s\n' "$u"
getent passwd "$u" | cut -d: -f5 | cut -d, -f1
cat /etc/hostname 2>/dev/null || uname -n
( . /etc/os-release 2>/dev/null; printf '%s\n' "${PRETTY_NAME:-Arch Linux}" )
cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo ""
