local vars = require("variables")

hl.env("EDITOR", vars.editor)
hl.env("BROWSER", vars.browser)
hl.env("TERMINAL", vars.terminal)
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")
hl.env("GDK_BACKEND", "wayland,x11")
hl.env("QT_QPA_PLATFORM", "wayland;xcb")
hl.env("SDL_VIDEODRIVER", "wayland")
hl.env("CLUTTER_BACKEND", "wayland")
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "wayland")
hl.env("OZONE_PLATFORM", "wayland")
hl.env("QT_AUTO_SCREEN_SCALE_FACTOR", "1")
hl.env("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1")
hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
hl.env("MOZ_ENABLE_WAYLAND", "1")
hl.env("_JAVA_AWT_WM_NONREPARENTING", "1")
hl.env("NIXOS_OZONE_WL", "1")
hl.env("WLR_RENDERER_ALLOW_SOFTWARE", "1")
do
    local f = io.open("/etc/xdg/menus/arch-applications.menu", "r")
    if f then
        f:close()
        hl.env("XDG_MENU_PREFIX", "arch-")
    else
        local kf = io.open("/etc/xdg/menus/kf6-applications.menu", "r")
        if kf then
            kf:close()
            hl.env("XDG_MENU_PREFIX", "kf6-")
        end
    end
end
hl.env("QT_STYLE_OVERRIDE", "kvantum")

-- GPU specific variables written by install.sh (NVIDIA video acceleration ...). Optional: no file = nothing happens.
pcall(dofile, (os.getenv("HOME") or "") .. "/.config/Halcyon/gpu.lua")
