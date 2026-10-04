#!/usr/bin/env bash
# 5 lines: username, full name (from passwd), hostname, OS pretty name, laptop model
u=$(id -un)
printf '%s\n' "$u"
getent passwd "$u" | cut -d: -f5 | cut -d, -f1
cat /etc/hostname 2>/dev/null || hostname
( . /etc/os-release 2>/dev/null; printf '%s\n' "${PRETTY_NAME:-Arch Linux}" )
cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo ""
