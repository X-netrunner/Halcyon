local vars = require("variables")
local home = os.getenv("HOME")
local ipc = "quickshell ipc -p " .. home .. "/.config/Halcyon/quickshell/island call island "

-- Shortcuts you changed (or added) in the island's cheatsheet (SUPER+/) are saved in this file; it is rewritten
-- by the island and applied with a Hyprland reload. Every bind below goes through bind(id, default keys, ...), so
-- a changed entry simply replaces the default keys ("none" turns it off). The ids and default keys must match
-- quickshell/island/Binds.js (that is what the cheatsheet draws).
local user = { keys = {}, custom = {} }
do
    local path = home .. "/.local/state/island/binds.lua"
    local f = loadfile(path)
    local bad = false
    if f then
        local ok, t = pcall(f)
        if ok and type(t) == "table" then
            user.keys = type(t.keys) == "table" and t.keys or {}
            user.custom = type(t.custom) == "table" and t.custom or {}
        else
            bad = true
        end
    else
        local h = io.open(path, "r")      -- the file is there but does not parse (no file = nothing to load, not an error)
        if h then h:close(); bad = true end
    end
    if bad then    -- do not lose the shortcuts silently: say so (fix them in the cheatsheet, SUPER + /)
        pcall(hl.exec_cmd, "hyprctl notify 3 12000 'rgb(ff6b6b)' 'Halcyon: your shortcuts file could not be read, the default shortcuts are used. Open the cheatsheet (SUPER + /) and save them again.' >/dev/null 2>&1")
    end
end
local function bind(id, default, action, opts)
    local keys = user.keys[id] or default
    if keys == nil or keys == "" or keys == "none" or action == nil then return end
    if type(keys) == "string" then
        keys = keys:gsub("%s*,%s*", " + ")
    end
    if opts then
        pcall(hl.bind, keys, action, opts)
    else
        pcall(hl.bind, keys, action)
    end
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

-- Move focus between windows with SUPER+arrows. In the scrolling (niri) layout left / right walk the columns and the
-- view scrolls with you, so you can always get back to what you opened earlier; up / down walk the windows in a column.
-- SUPER+SHIFT+arrows moves the focused window the same way. (SUPER+CTRL+Left/Right stays workspace next / previous.)
for _, d in ipairs({ { "left", "Left" }, { "right", "Right" }, { "up", "Up" }, { "down", "Down" } }) do
    bind("focus_" .. d[1], "SUPER + " .. d[2], hl.dsp.focus({ direction = d[1] }))
    bind("movewin_" .. d[1], "SUPER + SHIFT + " .. d[2], hl.dsp.window.move({ direction = d[1] }))
end

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
bind("wsnext", vars.kbNextWs, hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/ws-nav.sh next"))
bind("wsprev", vars.kbPrevWs, hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/ws-nav.sh prev"))

-- Mouse scroll: hold SUPER and scroll wheel to cycle workspaces (wheel-down = next, wheel-up = prev)
bind("ws_scroll_down", vars.kbScrollNextWs, hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/ws-nav.sh wheel-down"))
bind("ws_scroll_up", vars.kbScrollPrevWs, hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/ws-nav.sh wheel-up"))

-- Special workspaces (overlay on top of the current workspace)
--   SUPER+S            scratch workspace   (SUPER+ALT+S sends the focused window there)
--   SUPER+M            music               (starts Spotify the first time / when it has no window: scripts/special.sh)
--   CTRL+SHIFT+ESC     system monitor      (opens vars.sysmonCmd the first time)
--   SUPER+D            communication       (starts Vesktop / Discord the first time: scripts/special.sh)
--   SUPER+R            the Halcyon calendar (quickshell/island/Calendar.qml; Settings > Calendar). Not a workspace any more.
bind("scratch", vars.kbSpecialWs, hl.dsp.workspace.toggle_special("special"))
bind("toscratch", "SUPER + ALT + S", hl.dsp.window.move({ workspace = "special:special" }))
bind("music", vars.kbMusicWs, hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/special.sh music"))
bind("sysmon", vars.kbSystemMonitorWs, hl.dsp.workspace.toggle_special("sysmon"))
bind("comm", vars.kbCommunicationWs, hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/special.sh communication"))
bind("todo", vars.kbTodoWs, hl.dsp.exec_cmd(ipc .. "calendar"))      -- id stays "todo": saved shortcut changes and gestures keep working

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
bind("shot", "Print", hl.dsp.exec_cmd("mkdir -p ~/Pictures/Screenshots && grim ~/Pictures/Screenshots/$(date +%s).png"))
bind("shotplain", "SUPER + SHIFT + Print", hl.dsp.exec_cmd("mkdir -p ~/Pictures/Screenshots && g=$(slurp) && [ -n \"$g\" ] && grim -g \"$g\" ~/Pictures/Screenshots/$(date +%s).png"))

bind("shotarea", "SUPER + SHIFT + S", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/screenshot-area.sh"))
bind("shotpanel", "SUPER + CTRL + S", hl.dsp.exec_cmd(ipc .. "screenshot"))   -- the screenshot panel: Region / Window / Full screen, then Copy / Save / Both

-- Clipboard
-- the island's clipboard panel (search, pins, pictures, AI); if the island is not running, the plain fuzzel list as before
bind("clipboard", "SUPER + V", hl.dsp.exec_cmd(ipc .. "clipboard || (cliphist list | fuzzel -d | cliphist decode | wl-copy)"))

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
bind("display", "SUPER + P", hl.dsp.exec_cmd(ipc .. "display"))   -- display / projector switcher (mirror, extend)
bind("caffeine", "SUPER + ALT + C", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/caffeine.sh toggle"))   -- caffeine: screen stays awake
bind("focus", "SUPER + ALT + F", hl.dsp.exec_cmd(ipc .. "focus"))   -- focus mode: timer + do not disturb + blocked apps (start / stop)

-- Island
bind("quickterm", "SUPER + SHIFT + Return", hl.dsp.exec_cmd(ipc .. "quickterm"))   -- top-left quick terminal
-- the list of console commands (tree view): only when sysmode is set up, because most of the commands are its
do
    local f = io.open("/usr/local/bin/sysmode", "r")
    if f then
        f:close()
        bind("cmdlist", "SUPER + ALT + slash", hl.dsp.exec_cmd(ipc .. "cmdlist"))
    end
end
bind("gaming", "SUPER + F10", hl.dsp.exec_cmd(ipc .. "gaming"))                 -- gaming mode on / off
-- safe mode on / off: blur, shadows, animations, stars and motion off and back. Goes straight to the script (not through the island), so it works when the island is stuck
bind("safemode", "SUPER + ALT + F12", hl.dsp.exec_cmd("python3 " .. home .. "/.config/Halcyon/scripts/halcyon-fx.py safe-mode toggle"))
bind("settings", "SUPER + I", hl.dsp.exec_cmd(ipc .. "settings"))                 -- rice settings window (SUPER + I)
bind("settings_alt", "SUPER + F11", hl.dsp.exec_cmd(ipc .. "settings"))           -- rice settings window (legacy fallback)
bind("clearnotifs", vars.kbClearNotifs, hl.dsp.exec_cmd(ipc .. "clearnotifs"))
bind("apps", "SUPER + SHIFT + A", hl.dsp.exec_cmd(ipc .. "apps"))              -- background apps box (bottom-left)
bind("notifcenter", "SUPER + SHIFT + N", hl.dsp.exec_cmd(ipc .. "notifcenter"))   -- notification centre
bind("notes", "SUPER + N", hl.dsp.exec_cmd(ipc .. "notes"))                     -- quick notes menu (SUPER + N)
-- voice note with one key: first press starts recording, the same keys again save it and write it down (straight to the script, so it works without the panel)
bind("voicenote", "SUPER + SHIFT + V", hl.dsp.exec_cmd("python3 " .. home .. "/.config/Halcyon/scripts/halcyon-notes.py rec-toggle"))
bind("extradim", "SUPER + ALT + D", hl.dsp.exec_cmd(ipc .. "extradim"))         -- extra dim mode (SUPER + ALT + D)
bind("record", "SUPER + ALT + R", hl.dsp.exec_cmd(home .. "/.config/Halcyon/scripts/screen-record.sh toggle")) -- screen recorder
-- everyday tools: `hal tools` (Rust, src/hal/src/tools.rs) starts in ~1 ms instead of Python's ~30 ms; scripts/halcyon-tools.py
-- is the fallback when hal is not built
local function tool(args)
    local hal = home .. "/.config/Halcyon/bin/hal"
    return hl.dsp.exec_cmd("[ -x '" .. hal .. "' ] && exec '" .. hal .. "' tools " .. args ..
        " || exec python3 '" .. home .. "/.config/Halcyon/scripts/halcyon-tools.py' " .. args)
end
bind("colorpick", "SUPER + SHIFT + C", tool("colorpick"))   -- colour picker
bind("measure", "SUPER + ALT + M", tool("measure"))   -- measure a box on the screen
bind("zoom", "SUPER + ALT + Z", tool("zoom toggle"))   -- magnifier
bind("snippets", "SUPER + ALT + V", tool("snippets pick"))   -- paste a saved text
bind("winlast", "ALT + Tab", hl.dsp.focus({ last = true }))   -- flip to the previous window
bind("winpick", "ALT + SHIFT + Tab", tool("windows pick"))   -- list of windows, most recent first
bind("dnd", "SUPER + SHIFT + D", hl.dsp.exec_cmd(ipc .. "dnd"))
bind("theme", "SUPER + SHIFT + T", hl.dsp.exec_cmd(ipc .. "theme"))                 -- light / dark theme

-- Tapping SUPER on its own opens the launcher (no Space needed).
-- Runs on key RELEASE on purpose: until the key comes up, Hyprland cannot tell a lone tap from the start of SUPER+T / SUPER+Q ...,
-- so a press bind would flash the launcher on every shortcut. The launcher's speed is set in Settings > Mouse, touchpad & keyboard
-- > Launcher speed (Normal / Quick / Instant): that is the part that can be shortened. A modifier key is reported with and without itself in the modifier mask depending on the
-- Hyprland version, so both spellings are bound; the island ignores the second trigger (350ms debounce), so
-- registering both is safe. super_tap.sh writes a file the island watches (a few ms) and falls back to IPC.
local superTapCmd = home .. "/.config/Halcyon/scripts/super_tap.sh"
for _, k in ipairs({ "SUPER_L", "SUPER_R", "SUPER + SUPER_L", "SUPER + SUPER_R" }) do
    pcall(hl.bind, k, hl.dsp.exec_cmd(superTapCmd), { release = true })
end

-- SUPER+TAB: live workspace tree (workspaces -> windows, special workspaces included)
bind("overview", "SUPER + TAB", hl.dsp.exec_cmd(ipc .. "overview"))

-- Shortcuts you added in the cheatsheet ("Your shortcuts"): key combination -> shell command
for _, c in ipairs(user.custom) do
    if type(c) == "table" and c.keys and c.keys ~= "" and c.cmd and c.cmd ~= "" then
        pcall(hl.bind, c.keys, hl.dsp.exec_cmd(c.cmd))
    end
end

-- An empty submap: no binds at all. scripts/login-watchdog.sh switches to it while the lock screen is still coming up at login
-- (up to ~20 s on a slow start), so no shortcut can open anything on the unlocked desktop, and switches back to "reset" once the
-- lock is up. pcall: a Hyprland build without hl.define_submap just loses this extra guard, the config still loads.
pcall(hl.define_submap, "halcyon-locking", function() end)
