local vars = require("variables")
local home = os.getenv("HOME")
local ipc = "quickshell ipc -p " .. home .. "/.config/Halcyon/quickshell/island call island "

-- Shortcuts you changed (or added) in the island's cheatsheet (SUPER+/) are saved in this file; it is rewritten
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
-- SUPER+Q closes whatever island overlay is on top (settings, shortcuts, tree view, launcher ...) and only closes the
-- focused window when there is none (scripts/close.sh asks the island)
bind("close", vars.kbCloseWindow, hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/close.sh"))
bind("float", vars.kbToggleWindowFloating, hl.dsp.window.float())
bind("fullscreen", vars.kbWindowFullscreen, hl.dsp.window.fullscreen())
bind("pin", vars.kbPinWindow, hl.dsp.window.pin())

-- Mouse: hold SUPER and drag. Right button = move the window, left button = resize it (buttons are in variables.lua:
-- kbMouseMove / kbMouseResize). On a floating window it moves / resizes freely; on a tiled one, moving drops it onto
-- another tile (it swaps) and resizing drags the split. They are plain binds with { mouse = true } on purpose: the
-- cheatsheet only lists them (kind "text"), it does not remap them.
hl.bind(vars.kbMouseMove, hl.dsp.window.drag(), { mouse = true })
hl.bind(vars.kbMouseResize, hl.dsp.window.resize(), { mouse = true })

-- Workspaces 1-9  (SUPER+N goes to workspace N, SUPER+ALT+N moves the window there)
for i = 1, 9 do
    hl.bind(vars.kbGoToWs .. " + " .. i, hl.dsp.focus({ workspace = i }))
    hl.bind(vars.kbMoveWinToWs .. " + " .. i, hl.dsp.window.move({ workspace = i }))
end

-- Next / previous workspace: SUPER+CTRL+Right opens a new workspace after the last one, SUPER+CTRL+Left on the first one
-- jumps to the last (same as the 3 / 4 finger swipes; see scripts/ws-nav.sh and Settings > Workspaces)
bind("wsnext", "SUPER + CTRL + Right", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/ws-nav.sh next"))
bind("wsprev", "SUPER + CTRL + Left", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/ws-nav.sh prev"))

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
-- ASUS laptops: Fn+F3 / Fn+F4 are handled inside the kernel (no key event, so nothing above can fire) and can need two presses.
-- SUPER+F3 steps the light down one level, SUPER+F4 cycles it up and wraps to off, through the script (works on the lock screen too). Only bound when the
-- device exists, so other laptops are not affected.
do
    local f = io.open("/sys/class/leds/asus::kbd_backlight/brightness", "r")
    if f then
        f:close()
        local kb = home .. "/.config/Halcyon/scripts/kbd-backlight.sh"
        hl.bind("SUPER + F3", hl.dsp.exec_cmd(kb .. " down"), { locked = true })
        hl.bind("SUPER + F4", hl.dsp.exec_cmd(kb .. " cycle"), { locked = true })   -- 0 -> 1 -> 2 -> 3 -> 0
    end
end

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
bind("cheatsheet", "SUPER + slash", hl.dsp.exec_cmd(ipc .. "cheatsheet"))

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
bind("nextwall", "SUPER + SHIFT + W", hl.dsp.exec_cmd("quickshell ipc -p " .. home .. "/.config/Halcyon/quickshell/island call wallpaper next"))
bind("gestures", "SUPER + ALT + G", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/toggle_gestures.sh"))
bind("power", "SUPER + ALT + P", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/toggle_power.sh"))
bind("caffeine", "SUPER + ALT + C", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/caffeine.sh toggle"))   -- caffeine: screen stays awake
bind("focus", "SUPER + ALT + F", hl.dsp.exec_cmd(ipc .. "focus"))   -- focus mode: timer + do not disturb + blocked apps (start / stop)

-- Island
bind("quickterm", "SUPER + SHIFT + Return", hl.dsp.exec_cmd(ipc .. "quickterm"))   -- top-left quick terminal
bind("gaming", "SUPER + F10", hl.dsp.exec_cmd(ipc .. "gaming"))                 -- gaming mode on / off
bind("settings", "SUPER + F11", hl.dsp.exec_cmd(ipc .. "settings"))               -- rice settings window
bind("clearnotifs", vars.kbClearNotifs, hl.dsp.exec_cmd(ipc .. "clearnotifs"))
bind("apps", "SUPER + SHIFT + A", hl.dsp.exec_cmd(ipc .. "apps"))              -- background apps box (bottom-left)
bind("notifcenter", "SUPER + SHIFT + N", hl.dsp.exec_cmd(ipc .. "notifcenter"))   -- notification centre
bind("dnd", "SUPER + SHIFT + D", hl.dsp.exec_cmd(ipc .. "dnd"))
bind("theme", "SUPER + SHIFT + T", hl.dsp.exec_cmd(ipc .. "theme"))                 -- light / dark theme           -- do not disturb

-- Tapping SUPER on its own opens the launcher (no Space needed).
-- Runs on key RELEASE. A modifier key is reported with and without itself in the modifier mask depending on the
-- Hyprland version, so both spellings are bound; the island ignores the second trigger (350ms debounce), so
-- registering both is safe. super_tap.sh writes a file the island watches (a few ms) and falls back to IPC.
local superTapCmd = home .. "/.config/Halcyon/scripts/super_tap.sh"
for _, k in ipairs({ "SUPER_L", "SUPER_R", "SUPER + SUPER_L", "SUPER + SUPER_R" }) do
    pcall(hl.bind, k, hl.dsp.exec_cmd(superTapCmd), { release = true })
end

-- SUPER+TAB: live workspace tree (workspaces -> windows, special workspaces included)
bind("overview", "SUPER + TAB", hl.dsp.exec_cmd(ipc .. "overview"))
hl.bind("SUPER + GRAVE", hl.dsp.exec_cmd(home .. "/.config/hyprland.overview.sh"))

-- Shortcuts you added in the cheatsheet ("Your shortcuts"): key combination -> shell command
for _, c in ipairs(user.custom) do
    if type(c) == "table" and c.keys and c.keys ~= "" and c.cmd and c.cmd ~= "" then
        pcall(hl.bind, c.keys, hl.dsp.exec_cmd(c.cmd))
    end
end
