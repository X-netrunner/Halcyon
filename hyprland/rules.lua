local vars = require("variables")

-- Settings > Workspaces & windows > "No tiling" (scripts/floating-mode.sh): one rule floats every window. The script keeps a flag file and
-- switches this rule on and off live (halcyon_float_all is a global on purpose: `hyprctl eval` reaches it); a reload reads the flag again.
local floatAll = false
do
    local f = io.open((os.getenv("HOME") or "") .. "/.local/state/island/float-all")
    if f then floatAll = (f:read("*l") or ""):find("1", 1, true) ~= nil; f:close() end
end
halcyon_float_all = hl.window_rule({ name = "halcyon-float-all", match = { class = ".*" }, float = true, enabled = floatAll })

hl.window_rule({ match = { title = "Picture-in-Picture" }, float = true, pin = true })
hl.window_rule({ match = { class = "mpv" }, float = true })
hl.window_rule({ match = { class = "org.kde.polkit-kde-authentication-agent-1" }, float = true })
hl.window_rule({ match = { class = "pavucontrol" }, float = true })
hl.window_rule({ match = { class = "blueman-manager" }, float = true })
hl.window_rule({ match = { class = "nm-connection-editor" }, float = true })
hl.window_rule({ match = { class = "qalculate-gtk" }, float = true })
hl.window_rule({ match = { class = "gnome-calculator" }, float = true })
hl.window_rule({ match = { class = "org.gnome.Calculator" }, float = true })
hl.window_rule({ match = { class = "file-roller" }, float = true })
hl.window_rule({ match = { class = "org.gnome.FileRoller" }, float = true })
hl.window_rule({ match = { class = "ark" }, float = true })
hl.window_rule({ match = { class = "hyprland-share-picker" }, float = true })
hl.window_rule({ match = { class = "xdg-desktop-portal-gtk" }, float = true })
hl.window_rule({ match = { class = "zenity" }, float = true })
hl.window_rule({ match = { class = "yad" }, float = true })
hl.window_rule({ match = { class = "pinentry.*" }, float = true })
hl.window_rule({ match = { class = "polkit-gnome-authentication-agent-1" }, float = true })

hl.layer_rule({ match = { namespace = "notification" }, blur = true })

-- Frosted glass behind every island surface. Only pixels more opaque than ignore_alpha are blurred, so the
-- glass body gets frosted while the soft shadow around it stays clear.
-- Keep ignore_alpha ABOVE the shadow strength and BELOW the glass opacity (Pal.qml: glassBar 0.58 / glassBarOpen 0.74,
-- glass 0.80, glassSolid 0.94). The bar is the lightest, so it needs the lowest threshold.
-- Memory optimization: multi-pass Kawase blur only on compact floating bar & corner surfaces, plus the windows below.
-- island-overview stays unblurred: it draws a nearly solid backdrop (0.94), so a blur would not show anyway.
-- The power menu, Settings, the builders, the wallpaper gallery, Startup & processes, the calendar, the shortcut sheet and
-- the command tree are windows that exist only while open (each one is destroyed when it closes), so their blur costs nothing
-- while idle. Their backdrop is ~0.38 - 0.55 alpha, so the threshold 0.25 blurs the backdrop and the cards but not the soft
-- shadow edges. All of it follows Settings > Performance > Resource use like every other blur: Low turns decoration:blur
-- off (no blur here either), Medium / High blur it (size and passes come from the preset: a light blur on Medium).
local glass = {
    island = 0.40,
    ["island-notch"] = 0.40,
    ["island-panel"] = 0.55,
    ["island-notifs"] = 0.55,
    ["island-term"] = 0.55,
    ["island-chat"] = 0.55,
    ["island-apps"] = 0.55,
    ["island-power"] = 0.25,
    ["island-settings"] = 0.25,
    ["island-gallery"] = 0.25,
    ["island-barbuilder"] = 0.25,
    ["island-notifbuilder"] = 0.25,
    ["island-desktopbuilder"] = 0.25,
    ["island-widgetbuilder"] = 0.25,
    ["island-startup"] = 0.25,
    ["island-calendar"] = 0.25,
    ["island-keys"] = 0.25,
    ["island-cmds"] = 0.25,
    ["island-notes"] = 0.25,
    -- these exist only while open too; they were missing, so they drew with no frosted glass behind them
    ["island-clipboard"] = 0.25,
    ["island-music"] = 0.25,
    ["island-shot"] = 0.25,
    ["island-games"] = 0.25,
    ["island-security"] = 0.25,
    ["island-luna"] = 0.25,
    ["island-study"] = 0.25,
    ["island-display"] = 0.25,
    ["island-wifiqr"] = 0.25,
}
for ns, a in pairs(glass) do
    hl.layer_rule({ match = { namespace = ns }, blur = true, ignore_alpha = a })
end

-- Special workspaces: launch the app the first time the workspace is opened empty.
-- music and communication are NOT here any more: SUPER+M / SUPER+D run scripts/special.sh, which starts the app whenever
-- the workspace has no window (not only the first time). Which app: MUSIC_CMD / COMM_CMD at the top of that script,
-- or in ~/.config/Halcyon/special.conf. The island moves Spotify / Discord windows there when they open (island/Routes.js).
-- All three go through special.sh --run: your own command for that workspace (Settings > Workspaces & windows > Special
-- workspace commands) wins, else the default (variables.lua). SUPER+S (scratch) has no default: it opens empty unless you set one.
local run = (os.getenv("HOME") or "") .. "/.config/Halcyon/scripts/special.sh --run "
hl.workspace_rule({ workspace = "special:special", on_created_empty = run .. "special" })
hl.workspace_rule({ workspace = "special:sysmon", on_created_empty = run .. "sysmon " .. vars.sysmonCmd })
