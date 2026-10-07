-- Multi-finger touchpad gestures, handled by Hyprland itself.
-- (The single-finger edge gestures for volume / brightness / tracks are the touchpad-gestures Rust service.)
--
--   3 fingers right / left        next / previous workspace (Settings > Workspaces > "Invert workspace scrolling" swaps them)
--   4 fingers left / right        next / previous workspace (Settings > Workspaces > "4-finger swipe" flips it)
--                                 scripts/ws-nav.sh: "next" on the last workspace opens a new one,
--                                 "previous" on the first one jumps to the last; Settings > Workspaces
--   3 fingers up or down          toggle the scratch special workspace (do it again to come back)
--   4 fingers down                sleep (systemctl suspend)
--   3-finger pinch                toggle the workspace tree (island overview, same as SUPER+TAB)
--
-- Hyprland refuses a gesture that an earlier one would overshadow, so only specific directions are
-- registered here: no generic "swipe" or "vertical" gestures for 3 or 4 fingers.
-- Swap a left/right pair for  { action = "workspace", direction = "horizontal" }  if you ever want the
-- 1:1 finger-following slide back.
local vars = require("variables")
local home = os.getenv("HOME")
local ipc = "quickshell ipc -p " .. home .. "/.config/Halcyon/quickshell/island call island "

local function run(cmd)
    return function() hl.dispatch(hl.dsp.exec_cmd(cmd)) end
end

-- plain "e+1" / "e-1" wrap around (the last workspace goes back to 1): ws-nav.sh makes a new workspace instead
local wsNav = home .. "/.config/Halcyon/scripts/ws-nav.sh"
-- 3 fingers: right = next, left = previous
hl.gesture({ fingers = vars.gestureFingers, direction = "right", action = run(wsNav .. " gesture-right") })
hl.gesture({ fingers = vars.gestureFingers, direction = "left",  action = run(wsNav .. " gesture-left") })
-- 4 fingers: left = next, right = previous (default; Settings > Workspaces > "4-finger swipe" flips it)
hl.gesture({ fingers = vars.gestureFingersMore, direction = "left",  action = run(wsNav .. " gesture4-left") })
hl.gesture({ fingers = vars.gestureFingersMore, direction = "right", action = run(wsNav .. " gesture4-right") })

local function scratch() hl.dispatch(hl.dsp.workspace.toggle_special("special")) end
hl.gesture({ fingers = vars.gestureFingers, direction = "up",   action = scratch })
hl.gesture({ fingers = vars.gestureFingers, direction = "down", action = scratch })

hl.gesture({ fingers = vars.gestureFingersMore, direction = "down", action = run("systemctl suspend") })

hl.gesture({ fingers = vars.gestureFingers, direction = "pinch", action = run(ipc .. "overview") })
