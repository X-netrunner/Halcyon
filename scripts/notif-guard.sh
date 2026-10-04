#!/usr/bin/env bash
# The island is the notification daemon (org.freedesktop.Notifications). Only ONE program can own that D-Bus name, and
# whoever asks first wins. Programs that start before the island (nm-applet, blueman-applet, polkit agent ...) can make
# D-Bus launch mako / dunst / swaync / a desktop's notifyd on demand, and then the island silently gets no notifications.
# This runs right before the island starts: it stops those daemons so the island can take the name.
for d in mako dunst swaync xfce4-notifyd notification-daemon mate-notification-daemon deadd-notification-center fnott; do
  pkill -x "$d" 2>/dev/null
done
# caelestia ships its own quickshell notification server
pkill -f 'quickshell.*caelestia' 2>/dev/null
pkill -f 'qs .*-c caelestia' 2>/dev/null
exit 0
