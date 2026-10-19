-- Multi-finger touchpad gestures, handled by Hyprland + touchpad-gestures live 1:1 tracker.
-- What each one does is chosen in Settings > Touchpad gestures (3 or 4 fingers; swipe left / right / up / down, pinch in / out).
-- The choices are in ~/.local/state/island/gestures.conf (see inputconf.lua, scripts/input-conf.sh).
--
-- Smooth 1:1 Finger-Following Enhancement:
--   When horizontal 3-finger or 4-finger swipes are set to next / previous workspace ("ws-next" / "ws-prev"),
--   they use Hyprland's native continuous workspace gesture ("horizontal", action = "workspace") and
--   workspace_swipe_* tuning so workspaces slide 1:1 with your fingers in real time instead of
--   waiting for the swipe to end!
local vars = require("variables")
local ic = require("hyprland.inputconf")

local function is_ws_pair(l_id, r_id)
    local la, ra = ic.action(l_id), ic.action(r_id)
    return (la == "ws-next" or la == "ws-prev") and (ra == "ws-next" or ra == "ws-prev")
end

local ws3 = is_ws_pair("g3-left", "g3-right")
local ws4 = is_ws_pair("g4-left", "g4-right")
-- Hyprland's workspace_swipe_invert defaults to TRUE: swiping left then goes to the NEXT workspace (content follows the
-- fingers). So "left = next" needs invert = true, and "left = previous" needs invert = false.
local left_act = (ws4 and ic.action("g4-left")) or (ws3 and ic.action("g3-left")) or "ws-next"
local swipe_invert = (left_act == "ws-next")

pcall(hl.config, {
    gestures = {
        workspace_swipe_distance           = vars.workspaceSwipeDistance or 380,
        workspace_swipe_invert             = swipe_invert,
        workspace_swipe_min_speed_to_force = vars.workspaceSwipeMinSpeed or 30,
        workspace_swipe_cancel_ratio       = vars.workspaceSwipeCancelRatio or 0.38,
        workspace_swipe_create_new         = true,
        workspace_swipe_forever            = true,
    }
})

local function run(id)
    return function() hl.dispatch(hl.dsp.exec_cmd(ic.run(id))) end
end

local function reg(fingers, direction, id)
    if not ic.active(id) then return end
    pcall(hl.gesture, { fingers = fingers, direction = direction, action = run(id) })
end

for _, set in ipairs({ { 3, vars.gestureFingers }, { 4, vars.gestureFingersMore } }) do
    local label, fingers = set[1], set[2]
    local l_id, r_id = "g" .. label .. "-left", "g" .. label .. "-right"
    if is_ws_pair(l_id, r_id) then
        -- Native 1:1 continuous finger-following workspace swipe in Hyprland 0.51+
        pcall(hl.gesture, { fingers = fingers, direction = "horizontal", action = "workspace" })
    else
        reg(fingers, "left", l_id)
        reg(fingers, "right", r_id)
    end
    for _, d in ipairs({ "up", "down" }) do
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
