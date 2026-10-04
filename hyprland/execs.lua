local vars = require("variables")

-- Minimal autostart
hl.on("hyprland.start", function()
    hl.exec_cmd("/usr/lib/polkit-kde-authentication-agent-1 &")
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP &")
    hl.exec_cmd("/usr/lib/hyprland/xdg-desktop-portal-hyprland &")
    hl.exec_cmd("XDG_MENU_PREFIX=arch- kbuildsycoca6 --noincremental &")
    hl.exec_cmd("wl-paste --type text --watch cliphist store &")
    hl.exec_cmd("wl-paste --type image --watch cliphist store &")
    -- touchpad edge gestures (volume / brightness / track skip); install.sh sets the service up
    hl.exec_cmd("systemctl --user start touchpad-gestures.service &")
    -- notifications: the island is the notification daemon now (quickshell/island/Notifs.qml), so no dunst/mako
    -- free org.freedesktop.Notifications, start the island (it owns it) and only THEN the programs that may send
    -- notifications; the other way round, D-Bus could start mako / dunst first and the island would get none
    hl.exec_cmd("mkdir -p ~/.cache/island ~/.local/state/island")
    hl.exec_cmd("~/.config/Halcyon/scripts/notif-guard.sh")
    hl.exec_cmd("quickshell -p ~/.config/Halcyon/quickshell/island &")
    hl.exec_cmd("quickshell -p ~/.config/Halcyon/quickshell/wallpaper &")
    hl.exec_cmd("sleep 2 && nm-applet &")
    hl.exec_cmd("sleep 2 && blueman-applet &")
    hl.exec_cmd("hypridle &")
end)
