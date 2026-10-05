local home = os.getenv("HOME")
local hypr = home .. "/.config/Halcyon"
package.path = package.path .. ";" .. hypr .. "/?.lua"

local function maybe_create(file, content)
    local f = io.open(file)
    if f then
        f:close()
        return
    end
    f = io.open(file, "w")
    if f then
        if content then f:write(content) end
        f:close()
    end
end

local function maybe_copy(src, dst)
    local out = io.open(dst)
    if out then
        out:close()
        return
    end
    local input = io.open(src, "r")
    if not input then return end
    out = io.open(dst, "w")
    if out then
        out:write(input:read("*a"))
        out:close()
    end
    input:close()
end

-- a reload runs this file again: forget the modules loaded last time, otherwise `require` hands back the old
-- (cached) copies and edits to hyprland/*.lua, variables.lua or scheme/current.lua would not be picked up
for name in pairs(package.loaded) do
    if name:match("^hyprland%.") or name:match("^scheme%.") or name == "variables" or name == "hypr-user" then
        package.loaded[name] = nil
    end
end

maybe_copy(hypr .. "/scheme/default.lua", hypr .. "/scheme/current.lua")

hl.monitor({
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = 1,
})

require("hyprland.env")
require("hyprland.general")
require("hyprland.input")
require("hyprland.misc")
require("hyprland.animations")
require("hyprland.decoration")
require("hyprland.group")
require("hyprland.execs")

hl.on("hyprland.start", function()
    hl.exec_cmd("hyprctl setcursor Adwaita 24")
end)

require("hyprland.rules")
require("hyprland.gestures")
require("hyprland.keybinds")

maybe_create(hypr .. "/hypr-user.lua", "-- Your custom user config here\n")
pcall(require, "hypr-user")
