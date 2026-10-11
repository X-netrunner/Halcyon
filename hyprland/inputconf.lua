-- What Settings > Touchpad gestures / Mouse buttons chose (scripts/input-conf.sh writes ~/.local/state/island/gestures.conf,
-- one `id=action` line each, and `id.cmd=...` for the actions that run a command).
-- gestures.lua and mouse.lua read it through this module. The defaults are the same as in scripts/input-conf.sh: keep them in step.
local home = os.getenv("HOME")

local function flag(name)
    local f = io.open(home .. "/.local/state/island/" .. name)
    if not f then return nil end
    local v = f:read("*l")
    f:close()
    return v
end

local swipeRight = flag("ws-swipe4") == "right"   -- older setting: which 4-finger swipe means "next workspace"
local defaults = {
    ["g3-up"] = "scratch", ["g3-down"] = "scratch",
    ["g3-pinchin"] = "overview", ["g3-pinchout"] = "overview",
    ["g4-left"] = swipeRight and "ws-prev" or "ws-next",
    ["g4-right"] = swipeRight and "ws-next" or "ws-prev",
    ["g4-down"] = "sleep",
}

local actions, cmds = {}, {}
local f = io.open(home .. "/.local/state/island/gestures.conf")
if f then
    for line in f:lines() do
        local k, v = line:match("^([%w%._%-]+)=(.*)$")
        if k then
            local id = k:match("^(.+)%.cmd$")
            if id then cmds[id] = v else actions[k] = v end
        end
    end
    f:close()
end

local M = {}
M.script = home .. "/.config/Halcyon/scripts/input-conf.sh"
function M.action(id) return actions[id] or defaults[id] or "none" end
function M.cmd(id) return cmds[id] or "" end
-- "Open an app" / "Run a command" with nothing picked yet does nothing, so it does not take the gesture / button away from the apps either
function M.active(id)
    local a = M.action(id)
    if a == "none" or a == "" then return false end
    if (a == "app" or a == "cmd") and M.cmd(id) == "" then return false end
    return true
end
-- the command Hyprland runs for a gesture / button
function M.run(id) return M.script .. " run " .. id end
return M
