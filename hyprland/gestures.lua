-- Multi-finger touchpad gestures, handled by Hyprland itself. What each one does is chosen in
-- Settings > Touchpad gestures (3 or 4 fingers; swipe left / right / up / down, pinch in / out).
-- The choices are in ~/.local/state/island/gestures.conf (see inputconf.lua, scripts/input-conf.sh).
--
-- Out of the box:
--   4 fingers left / right        next / previous workspace
--                                 scripts/ws-nav.sh: "next" on the last workspace opens a new one,
--                                 "previous" on the first one jumps to the last; Settings > Workspaces
--   3 fingers up or down          toggle the scratch special workspace (do it again to come back)
--   4 fingers down                sleep (systemctl suspend)
--   3-finger pinch                toggle the workspace tree (island overview, same as SUPER+TAB)
--   3 fingers left / right, 4 fingers up, 4-finger pinch:  nothing, so your apps still get them
--
-- A gesture set to "Nothing" is NOT registered, so the apps see it (a browser can use a 3-finger swipe, for example).
-- Changing a gesture from "Nothing" to an action (or back) needs a Hyprland reload; Settings does it by itself.
-- Hyprland refuses a gesture that an earlier one would overshadow, so only specific directions are registered here:
-- no generic "swipe" or "vertical" gestures.
-- Single-finger edge gestures (volume / brightness / tracks) are the touchpad-gestures Rust service, not this file.
local vars = require("variables")
local ic = require("hyprland.inputconf")

local function run(id)
    return function() hl.dispatch(hl.dsp.exec_cmd(ic.run(id))) end
end

local function reg(fingers, direction, id)
    if not ic.active(id) then return end
    pcall(hl.gesture, { fingers = fingers, direction = direction, action = run(id) })
end

for _, set in ipairs({ { 3, vars.gestureFingers }, { 4, vars.gestureFingersMore } }) do
    local label, fingers = set[1], set[2]
    for _, d in ipairs({ "left", "right", "up", "down" }) do
        reg(fingers, d, "g" .. label .. "-" .. d)
    end
    -- pinch: in and out doing the same thing is ONE gesture; different things are two (Hyprland 0.51+ knows pinchin / pinchout)
    local pin, pout = "g" .. label .. "-pinchin", "g" .. label .. "-pinchout"
    if ic.active(pin) and ic.action(pin) == ic.action(pout) and ic.cmd(pin) == ic.cmd(pout) then
        reg(fingers, "pinch", pin)
    else
        reg(fingers, "pinchin", pin)
        reg(fingers, "pinchout", pout)
    end
end
