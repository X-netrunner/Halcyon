local vars = require("variables")
local home = os.getenv("HOME")
local ipc = "quickshell ipc -p " .. home .. "/.config/Halcyon/quickshell/island call island "

-- Shortcuts you changed (or added) in the island's cheatsheet (SUPER+ALT+/) are saved in this file; it is rewritten
-- by the island and applied with a Hyprland reload. Every bind below goes through bind(id, default keys, ...), so
-- a changed entry simply replaces the default keys ("none" turns it off). The ids and default keys must match
-- quickshell/island/Binds.js (that is what the cheatsheet draws).
local user = { keys = {}, custom = {} }
do
    local f = loadfile(home .. "/.local/state/island/binds.lua")
    if f then
        local ok, t = pcall(f)
        if ok and type(t) == "table" then
            user.keys = type(t.keys) == "table" and t.keys or {}
            user.custom = type(t.custom) == "table" and t.custom or {}
        end
    end
end
local function bind(id, default, action, opts)
    local keys = user.keys[id] or default
    if keys == nil or keys == "" or keys == "none" then return end
    if opts then hl.bind(keys, action, opts) else hl.bind(keys, action) end
end

-- Apps
bind("terminal", vars.kbTerminal, hl.dsp.exec_cmd(vars.terminal))
bind("browser", vars.kbBrowser, hl.dsp.exec_cmd(vars.browser))
bind("editor", vars.kbEditor, hl.dsp.exec_cmd(vars.editor))
bind("files", vars.kbFileExplorer, hl.dsp.exec_cmd(vars.fileExplorer))

-- Window actions
bind("close", vars.kbCloseWindow, hl.dsp.window.close())
bind("float", vars.kbToggleWindowFloating, hl.dsp.window.float())
bind("fullscreen", vars.kbWindowFullscreen, hl.dsp.window.fullscreen())
bind("pin", vars.kbPinWindow, hl.dsp.window.pin())

-- Workspaces 1-9  (SUPER+N goes to workspace N, SUPER+ALT+N moves the window there)
for i = 1, 9 do
    hl.bind(vars.kbGoToWs .. " + " .. i, hl.dsp.focus({ workspace = i }))
    hl.bind(vars.kbMoveWinToWs .. " + " .. i, hl.dsp.window.move({ workspace = i }))
end

-- Special workspaces (overlay on top of the current workspace)
--   SUPER+S            scratch workspace   (SUPER+ALT+S sends the focused window there)
--   SUPER+M            music               (starts Spotify the first time / when it has no window: scripts/special.sh)
--   CTRL+SHIFT+ESC     system monitor      (opens vars.sysmonCmd the first time)
--   SUPER+D            communication       (starts Vesktop / Discord the first time: scripts/special.sh)
--   SUPER+R            todo                (opens vars.todoCmd the first time)
bind("scratch", vars.kbSpecialWs, hl.dsp.workspace.toggle_special("special"))
bind("toscratch", "SUPER + ALT + S", hl.dsp.window.move({ workspace = "special:special" }))
bind("music", vars.kbMusicWs, hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/special.sh music"))
bind("sysmon", vars.kbSystemMonitorWs, hl.dsp.workspace.toggle_special("sysmon"))
bind("comm", vars.kbCommunicationWs, hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/special.sh communication"))
bind("todo", vars.kbTodoWs, hl.dsp.workspace.toggle_special("todo"))

-- Media/Volume/Brightness
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 10%+"))
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 10%-"))
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"))
hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"))
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("brightnessctl set 10%+"))
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl set 10%-"))
-- keyboard backlight (scripts/kbd-backlight.sh; `kbd-backlight.sh doctor` explains a missing driver). The bar slides in by itself.
hl.bind("XF86KbdBrightnessUp", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/kbd-backlight.sh up"))
hl.bind("XF86KbdBrightnessDown", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/kbd-backlight.sh down"))
hl.bind("XF86KbdLightOnOff", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/kbd-backlight.sh toggle"))

hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"))
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"))
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"))
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"))
hl.bind("XF86AudioStop", hl.dsp.exec_cmd("playerctl stop"))

-- Screenshots
bind("shot", "Print", hl.dsp.exec_cmd("grim ~/Pictures/Screenshots/$(date +%s).png"))
bind("shotplain", "SUPER + SHIFT + Print", hl.dsp.exec_cmd("grim -g \"$(slurp)\" ~/Pictures/Screenshots/$(date +%s).png"))

bind("shotarea", "SUPER + SHIFT + S", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/screenshot-area.sh"))

-- Clipboard
bind("clipboard", "SUPER + V", hl.dsp.exec_cmd("cliphist list | fuzzel -d | cliphist decode | wl-copy"))

-- Cheatsheet: searchable list of every bind / gesture / sysmode command (also ">keybinds" in the launcher)
bind("cheatsheet", "SUPER + ALT + slash", hl.dsp.exec_cmd(ipc .. "cheatsheet"))

-- Lock / Session
bind("lock", vars.kbLock, hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/lock.sh"))
bind("session", vars.kbSession, hl.dsp.exec_cmd("wlogout"))

-- Custom Toggles
hl.bind("XF86TouchpadToggle", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/toggle_touchpad.sh"))
bind("swapsplit", "SUPER + Y", hl.dsp.layout("swapsplit"))
bind("layout", "SUPER + ALT + T", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/toggle_layout.sh"))
bind("nightlight", "SUPER + ALT + N", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/toggle_nightlight.sh"))
bind("emoji", "SUPER + period", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/emoji.sh"))
bind("livewall", "SUPER + ALT + W", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/toggle_livewallpaper.sh"))
bind("gestures", "SUPER + ALT + G", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/toggle_gestures.sh"))
bind("power", "SUPER + ALT + P", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/toggle_power.sh"))
bind("caffeine", "SUPER + ALT + C", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/caffeine.sh toggle"))   -- caffeine: screen stays awake

-- Island
bind("quickterm", "SUPER + SHIFT + Return", hl.dsp.exec_cmd(ipc .. "quickterm"))   -- top-left quick terminal
bind("gaming", "SUPER + F10", hl.dsp.exec_cmd(ipc .. "gaming"))                 -- gaming mode on / off
bind("settings", "SUPER + F11", hl.dsp.exec_cmd(ipc .. "settings"))               -- rice settings window
bind("clearnotifs", vars.kbClearNotifs, hl.dsp.exec_cmd(ipc .. "clearnotifs"))
bind("apps", "SUPER + SHIFT + A", hl.dsp.exec_cmd(ipc .. "apps"))              -- background apps box (bottom-left)
bind("notifcenter", "SUPER + SHIFT + N", hl.dsp.exec_cmd(ipc .. "notifcenter"))   -- notification centre
bind("dnd", "SUPER + SHIFT + D", hl.dsp.exec_cmd(ipc .. "dnd"))
bind("theme", "SUPER + SHIFT + T", hl.dsp.exec_cmd(ipc .. "theme"))                 -- light / dark theme           -- do not disturb

-- Tapping SUPER on its own (press + release, nothing else in between) opens the drawer.
-- Hyprland's Lua API has no "catchall" key (that was the error on this line), so instead every
-- ordinary key gets a tiny non-consuming marker bind: SUPER+<key> flags SUPER as "used" while the
-- key still reaches its real bind / the focused app untouched. Result: SUPER+T etc. never pop the
-- drawer when you let go of SUPER.
-- If the drawer never opens, delete the marker loop below (the SUPER+Space fallback still works).
local superUsed = false
local function markUsed() superUsed = true end

local markKeys = {}
for c = string.byte("a"), string.byte("z") do markKeys[#markKeys + 1] = string.char(c) end
for d = 0, 9 do markKeys[#markKeys + 1] = tostring(d) end
for f = 1, 12 do markKeys[#markKeys + 1] = "F" .. f end
for _, k in ipairs({ "space", "Tab", "grave", "comma", "period", "slash", "semicolon", "apostrophe",
                     "bracketleft", "bracketright", "backslash", "minus", "equal", "Return",
                     "BackSpace", "Escape", "Left", "Right", "Up", "Down", "Print" }) do
    markKeys[#markKeys + 1] = k
end
for _, mods in ipairs({ "SUPER", "SUPER + SHIFT", "SUPER + ALT", "SUPER + CTRL" }) do
    for _, k in ipairs(markKeys) do
        pcall(hl.bind, mods .. " + " .. k, markUsed, { non_consuming = true })
    end
end

hl.bind("SUPER + SUPER_L", function()
    if not superUsed then hl.dispatch(hl.dsp.exec_cmd(ipc .. "launcher")) end
    superUsed = false
end, { release = true })

bind("launcher", "SUPER + space", hl.dsp.exec_cmd(ipc .. "launcher"))
-- SUPER+TAB: live workspace tree (workspaces -> windows, special workspaces included)
bind("overview", "SUPER + TAB", hl.dsp.exec_cmd(ipc .. "overview"))
hl.bind("SUPER + GRAVE", hl.dsp.exec_cmd(home .. "/.config/hyprland.overview.sh"))

-- Shortcuts you added in the cheatsheet ("Your shortcuts"): key combination -> shell command
for _, c in ipairs(user.custom) do
    if type(c) == "table" and c.keys and c.keys ~= "" and c.cmd and c.cmd ~= "" then
        pcall(hl.bind, c.keys, hl.dsp.exec_cmd(c.cmd))
    end
end
