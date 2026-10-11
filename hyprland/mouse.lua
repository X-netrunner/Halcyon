-- Mouse buttons chosen in Settings > Mouse buttons (middle, back, forward and the extra buttons of a gaming mouse).
-- Left and right click are never touched (Settings > Mouse, touchpad & keyboard > "Left-handed buttons" swaps them).
-- Same file as the gestures: ~/.local/state/island/gestures.conf (inputconf.lua, scripts/input-conf.sh).
--
-- A button set to "Default" is NOT registered, so the app under the pointer keeps getting it (back / forward in a browser,
-- middle-click paste ...). A button that does something is taken by Hyprland, apps no longer see it.
-- Only the plain button counts: SUPER + button (move / resize a window, keybinds.lua) is not affected.
local ic = require("hyprland.inputconf")

-- Linux button codes: 274 middle, 275 side ("back"), 276 extra ("forward"), 277 / 278 / 279 more buttons
for _, code in ipairs({ 274, 275, 276, 277, 278, 279 }) do
    local id = "m" .. code
    if ic.active(id) then
        local key = "mouse:" .. code
        local a = ic.action(id)
        if a == "drag" then
            pcall(hl.bind, key, hl.dsp.window.drag(), { mouse = true })      -- hold the button and move the mouse: moves the window
        elseif a == "resize" then
            pcall(hl.bind, key, hl.dsp.window.resize(), { mouse = true })
        else
            pcall(hl.bind, key, hl.dsp.exec_cmd(ic.run(id)))
        end
    end
end
