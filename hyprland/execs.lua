local vars = require("variables")
local home = os.getenv("HOME")
local rice = home .. "/.config/Halcyon"

-- Autostart. Every command runs through /bin/sh, so "&" and "&&" work; the island and the wallpaper shell are started by
-- scripts/start-shell.sh, which waits for the Wayland socket, logs to ~/.cache/island/quickshell-<name>.log, restarts a
-- crashed shell and tells you (a Hyprland notification) when it cannot start at all.
hl.on("hyprland.start", function()
    -- the session environment first: portals, polkit, the notification D-Bus name and every program started from a
    -- launcher need to know which Wayland session this is
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_DESKTOP HYPRLAND_INSTANCE_SIGNATURE QT_QPA_PLATFORMTHEME &")
    hl.exec_cmd("mkdir -p ~/.cache/island ~/.local/state/island")

    -- notifications: the island is the notification daemon now (quickshell/island/Notifs.qml), so no dunst/mako.
    -- start-shell.sh island frees org.freedesktop.Notifications (scripts/notif-guard.sh) right before the island starts
    hl.exec_cmd(rice .. "/scripts/start-shell.sh island &")
    hl.exec_cmd(rice .. "/scripts/start-shell.sh wallpaper &")

    -- polkit agent and the Hyprland portal (Arch puts the portal in /usr/lib/, other distributions in /usr/lib/hyprland/)
    hl.exec_cmd("/usr/lib/polkit-kde-authentication-agent-1 &")
    hl.exec_cmd("for p in /usr/lib/hyprland/xdg-desktop-portal-hyprland /usr/lib/xdg-desktop-portal-hyprland; do [ -x \"$p\" ] && exec \"$p\"; done &")
    hl.exec_cmd("XDG_MENU_PREFIX=arch- kbuildsycoca6 --noincremental &")
    hl.exec_cmd("wl-paste --type text --watch cliphist store &")
    hl.exec_cmd("wl-paste --type image --watch cliphist store &")
    -- touchpad edge gestures (volume / brightness / track skip); install.sh sets the service up
    hl.exec_cmd("systemctl --user start touchpad-gestures.service &")
    -- started from the tty1 login (launch/halcyon-login.sh)? then make sure the lock screen really came up
    hl.exec_cmd(rice .. "/scripts/login-watchdog.sh &")
    hl.exec_cmd("sleep 2 && nm-applet &")
    hl.exec_cmd("sleep 2 && blueman-applet &")
    -- idle lock + sleep, set in Settings > Sleep & lock (scripts/idle.sh runs hypridle with its own config)
    hl.exec_cmd(rice .. "/scripts/idle.sh start &")
end)
