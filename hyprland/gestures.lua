-- Multi-finger touchpad gestures, handled by Hyprland itself.
-- (The single-finger edge gestures for volume / brightness / tracks are the touchpad-gestures Rust service.)
--
--   3 or 4 fingers right / left   next / previous workspace
--   3 fingers up or down          toggle the scratch special workspace (do it again to come back)
--   4 fingers down                sleep (systemctl suspend)
--   2-finger pinch                toggle the workspace tree (island overview, same as SUPER+TAB)
--
-- Hyprland refuses a gesture that an earlier one would overshadow, so only specific directions are
-- registered here: no generic "swipe" or "vertical" gestures for 3 or 4 fingers.
-- Swap a left/right pair for  { action = "workspace", direction = "horizontal" }  if you ever want the
-- 1:1 finger-following slide back.
local vars = require("variables")
local home = os.getenv("HOME")
local ipc = "quickshell ipc -p " .. home .. "/.config/Halcyon/quickshell/island call island "

local function workspace(rel)
    return function() hl.dispatch(hl.dsp.focus({ workspace = rel })) end
end

local function run(cmd)
    return function() hl.dispatch(hl.dsp.exec_cmd(cmd)) end
end

for _, fingers in ipairs({ vars.gestureFingers, vars.gestureFingersMore }) do
    hl.gesture({ fingers = fingers, direction = "right", action = workspace("e+1") })
    hl.gesture({ fingers = fingers, direction = "left",  action = workspace("e-1") })
end

local function scratch() hl.dispatch(hl.dsp.workspace.toggle_special("special")) end
hl.gesture({ fingers = vars.gestureFingers, direction = "up",   action = scratch })
hl.gesture({ fingers = vars.gestureFingers, direction = "down", action = scratch })

hl.gesture({ fingers = vars.gestureFingersMore, direction = "down", action = run("systemctl suspend") })

hl.gesture({ fingers = 2, direction = "pinch", action = run(ipc .. "overview") })
