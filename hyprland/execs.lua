local vars = require("variables")
local home = os.getenv("HOME")
local rice = home .. "/.config/Halcyon"
-- fewer malloc arenas + earlier trim: the shells give freed memory back instead of holding it (a lot less resident RAM)
local mem = "MALLOC_ARENA_MAX=2 MALLOC_TRIM_THRESHOLD_=131072 "

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
    -- QSG_RENDER_LOOP=basic: all the island windows share one GPU context instead of one each (much less RAM)
    hl.exec_cmd(mem .. "QSG_RENDER_LOOP=basic " .. rice .. "/scripts/start-shell.sh island &")
    -- (the wallpaper layer is part of the island shell now: quickshell/island/Wallpaper.qml, no second process)

    -- polkit agent (the lightest one that is installed, see scripts/autostart-extras.sh), the Hyprland portal, and the optional
    -- tray applets (nm-applet / blueman-applet are OFF by default: the island has its own Wi-Fi / Bluetooth lists, and the two
    -- applets cost ~60-100 MB. Turn them on in ~/.config/Halcyon/autostart.conf)
    hl.exec_cmd(rice .. "/scripts/autostart-extras.sh &")
    -- (the Hyprland portal, the clipboard history watchers and the touchpad gestures are started by autostart-extras.sh too, so
    -- Settings > Startup & background can switch each of them off)
    hl.exec_cmd("XDG_MENU_PREFIX=arch- kbuildsycoca6 --noincremental &")
    -- started from the tty1 login (launch/halcyon-login.sh)? then make sure the lock screen really came up
    hl.exec_cmd(rice .. "/scripts/login-watchdog.sh &")
    -- idle lock + sleep, set in Settings > Sleep & lock (scripts/idle.sh runs hypridle with its own config)
    hl.exec_cmd(rice .. "/scripts/idle.sh start &")
end)
