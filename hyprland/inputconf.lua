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

-- Which layout is on: "niri" = the scrolling layout with tiling on, "other" = dwindle, or no tiling at all (floating).
-- general.lua is the source of truth for the tiling layout (scripts/toggle_layout.sh edits it) and ~/.local/state/island/float-all
-- is the "No tiling" flag (scripts/floating-mode.sh). Floating mode keeps `layout = "scrolling"` in general.lua underneath,
-- so the flag has to win. scripts/gesture-profile.sh reads the same two files: keep them in step.
local function detect_niri()
    local ff = flag("float-all")
    if ff and ff:find("1", 1, true) then return false end
    local f = io.open(home .. "/.config/Halcyon/hyprland/general.lua", "r")
    if not f then return false end
    local layout
    for line in f:lines() do
        layout = line:match('^%s*layout%s*=%s*"(%a+)"')    -- same anchor as the sed in toggle_layout.sh (a commented line does not count)
        if layout then break end
    end
    f:close()
    return layout == "scrolling"
end
local niri = detect_niri()

-- In the niri layout the workspaces run up / down, so the 4-finger swipes turn a quarter turn: the swipe that does X in the
-- other layouts is the one 90 degrees on from it. Each swipe on the left is filled by the setting on the right:
--   up    <- left   (default: next workspace)
--   down  <- right  (default: previous workspace)
--   left  <- down   (default: sleep)
--   right <- up     (default: nothing)
-- It is a lookup on top of what Settings saved (never a different default), so it keeps working after Settings has written
-- every gesture into gestures.conf, and a gesture you changed turns with the rest. 3-finger swipes and pinches stay put.
local TURN = { up = "left", down = "right", left = "down", right = "up" }
local function slot(id)
    if niri then
        local d = id:match("^g4%-(%a+)$")
        if d and TURN[d] then return "g4-" .. TURN[d] end
    end
    return id
end

local M = {}
M.script = home .. "/.config/Halcyon/scripts/input-conf.sh"
M.niri = niri
function M.action(id) local s = slot(id); return actions[s] or defaults[s] or "none" end
function M.cmd(id) return cmds[slot(id)] or "" end
-- "Open an app" / "Run a command" with nothing picked yet does nothing, so it does not take the gesture / button away from the apps either
function M.active(id)
    local a = M.action(id)
    if a == "none" or a == "" then return false end
    if (a == "app" or a == "cmd") and M.cmd(id) == "" then return false end
    return true
end
-- the command Hyprland runs for a gesture / button (the turned id, so hal input run needs no idea of the layout)
function M.run(id) return M.script .. " run " .. slot(id) end
-- Remember which profile this load registered: scripts/gesture-profile.sh sync reloads Hyprland only when the layout has
-- moved to the other one. Written on every load, so it can never be older than what is registered.
function M.stamp()
    local f = io.open(home .. "/.local/state/island/gesture-profile", "w")
    if f then f:write(niri and "niri" or "other", "\n"); f:close() end
end
return M
