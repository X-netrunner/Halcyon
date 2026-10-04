local vars = require("variables")

hl.window_rule({ match = { title = "Picture-in-Picture" }, float = true, pin = true })
hl.window_rule({ match = { class = "mpv" }, float = true })
hl.window_rule({ match = { class = "org.kde.polkit-kde-authentication-agent-1" }, float = true })
hl.window_rule({ match = { class = "pavucontrol" }, float = true })
hl.window_rule({ match = { class = "blueman-manager" }, float = true })
hl.window_rule({ match = { class = "nm-connection-editor" }, float = true })

hl.layer_rule({ match = { namespace = "waybar" }, blur = true })
hl.layer_rule({ match = { namespace = "notification" }, blur = true })

-- Frosted glass behind every island surface. Only pixels more opaque than ignore_alpha are blurred, so the
-- glass body gets frosted while the soft shadow around it stays clear.
-- Keep ignore_alpha ABOVE the shadow strength and BELOW the glass opacity (Pal.qml: glassBar 0.58 / glassBarOpen 0.74,
-- glass 0.80, glassSolid 0.94). The bar is the lightest, so it needs the lowest threshold.
local glass = { island = 0.40, ["island-panel"] = 0.55, ["island-notifs"] = 0.55, ["island-term"] = 0.55, ["island-overview"] = 0.55,
    -- full-screen overlays (power menu, settings): a dim sheet over everything, blurred behind it
    ["island-power"] = 0.2, ["island-settings"] = 0.2 }
for ns, a in pairs(glass) do
    hl.layer_rule({ match = { namespace = ns }, blur = true, ignore_alpha = a })
end

-- Special workspaces: launch the app the first time the workspace is opened empty
hl.workspace_rule({ workspace = "special:music", on_created_empty = vars.musicCmd })
hl.workspace_rule({ workspace = "special:sysmon", on_created_empty = vars.sysmonCmd })
hl.workspace_rule({ workspace = "special:communication", on_created_empty = vars.communicationCmd })
hl.workspace_rule({ workspace = "special:todo", on_created_empty = vars.todoCmd })
