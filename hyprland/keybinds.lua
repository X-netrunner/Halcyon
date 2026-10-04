local vars = require("variables")
local home = os.getenv("HOME")

-- Apps
hl.bind(vars.kbTerminal, hl.dsp.exec_cmd(vars.terminal))
hl.bind(vars.kbBrowser, hl.dsp.exec_cmd(vars.browser))
hl.bind(vars.kbEditor, hl.dsp.exec_cmd(vars.editor))
hl.bind(vars.kbFileExplorer, hl.dsp.exec_cmd(vars.fileExplorer))

-- Window actions
hl.bind(vars.kbCloseWindow, hl.dsp.window.close())
hl.bind(vars.kbToggleWindowFloating, hl.dsp.window.float())
hl.bind(vars.kbWindowFullscreen, hl.dsp.window.fullscreen())
hl.bind(vars.kbPinWindow, hl.dsp.window.pin())

-- Workspaces 1-9  (SUPER+N goes to workspace N, SUPER+ALT+N moves the window there)
for i = 1, 9 do
    hl.bind(vars.kbGoToWs .. " + " .. i, hl.dsp.focus({ workspace = i }))
    hl.bind(vars.kbMoveWinToWs .. " + " .. i, hl.dsp.window.move({ workspace = i }))
end

-- Special workspaces (overlay on top of the current workspace)
--   SUPER+S            scratch workspace   (SUPER+ALT+S sends the focused window there)
--   SUPER+M            music               (opens vars.musicCmd the first time)
--   CTRL+SHIFT+ESC     system monitor      (opens vars.sysmonCmd the first time)
--   SUPER+D            communication       (opens vars.communicationCmd the first time)
--   SUPER+R            todo                (opens vars.todoCmd the first time)
hl.bind(vars.kbSpecialWs, hl.dsp.workspace.toggle_special("special"))
hl.bind("SUPER + ALT + S", hl.dsp.window.move({ workspace = "special:special" }))
hl.bind(vars.kbMusicWs, hl.dsp.workspace.toggle_special("music"))
hl.bind(vars.kbSystemMonitorWs, hl.dsp.workspace.toggle_special("sysmon"))
hl.bind(vars.kbCommunicationWs, hl.dsp.workspace.toggle_special("communication"))
hl.bind(vars.kbTodoWs, hl.dsp.workspace.toggle_special("todo"))

-- Media/Volume/Brightness
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 10%+"))
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 10%-"))
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"))
hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"))
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("brightnessctl set 10%+"))
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl set 10%-"))

hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"))
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"))
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"))
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"))
hl.bind("XF86AudioStop", hl.dsp.exec_cmd("playerctl stop"))

-- Screenshots
hl.bind("Print", hl.dsp.exec_cmd("grim ~/Pictures/Screenshots/$(date +%s).png"))
hl.bind("SUPER + SHIFT + Print", hl.dsp.exec_cmd("grim -g \"$(slurp)\" ~/Pictures/Screenshots/$(date +%s).png"))

hl.bind("SUPER + SHIFT + S", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/screenshot-area.sh"))

-- Clipboard
hl.bind("SUPER + V", hl.dsp.exec_cmd("cliphist list | fuzzel -d | cliphist decode | wl-copy"))

-- Cheatsheet: searchable list of every bind / gesture / sysmode command (also ">keybinds" in the launcher)
hl.bind("SUPER + ALT + slash", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/cheatsheet.sh"))

-- Lock / Session
hl.bind(vars.kbLock, hl.dsp.exec_cmd("hyprlock"))
hl.bind(vars.kbSession, hl.dsp.exec_cmd("wlogout"))

-- Custom Toggles
hl.bind("XF86TouchpadToggle", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/toggle_touchpad.sh"))
hl.bind("SUPER + Y", hl.dsp.layout("swapsplit"))
hl.bind("SUPER + ALT + T", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/toggle_layout.sh"))
hl.bind("SUPER + ALT + N", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/toggle_nightlight.sh"))
hl.bind("SUPER + period", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/emoji.sh"))
hl.bind("SUPER + ALT + W", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/toggle_livewallpaper.sh"))
hl.bind("SUPER + ALT + G", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/toggle_gestures.sh"))
hl.bind("SUPER + ALT + P", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/toggle_power.sh"))

-- Island
local ipc = "quickshell ipc -p " .. home .. "/.config/Halcyon/quickshell/island call island "
hl.bind("SUPER + SHIFT + Return", hl.dsp.exec_cmd(ipc .. "quickterm"))   -- top-left quick terminal
hl.bind("SUPER + F10", hl.dsp.exec_cmd(ipc .. "gaming"))                 -- gaming mode on / off
hl.bind("SUPER + F11", hl.dsp.exec_cmd(ipc .. "settings"))               -- rice settings window
hl.bind(vars.kbClearNotifs, hl.dsp.exec_cmd(ipc .. "clearnotifs"))
hl.bind("SUPER + SHIFT + N", hl.dsp.exec_cmd(ipc .. "notifcenter"))   -- notification centre
hl.bind("SUPER + SHIFT + D", hl.dsp.exec_cmd(ipc .. "dnd"))           -- do not disturb

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

hl.bind("SUPER + space", hl.dsp.exec_cmd(ipc .. "launcher"))
-- SUPER+TAB: live workspace tree (workspaces -> windows, special workspaces included)
hl.bind("SUPER + TAB", hl.dsp.exec_cmd(ipc .. "overview"))
hl.bind("SUPER + GRAVE", hl.dsp.exec_cmd(home .. "/.config/hyprland.overview.sh"))
