local vars = require("variables")

hl.config({
    general = {
        border_size             = vars.windowBorderSize,
        gaps_in                 = vars.windowGapsIn,
        gaps_out                = vars.windowGapsOut,
        gaps_workspaces         = vars.workspaceGaps,
        ["col.active_border"]   = vars.activeWindowBorderColour,
        ["col.inactive_border"] = vars.inactiveWindowBorderColour,
        layout                  = "dwindle",
        resize_on_border        = true,
        extend_border_grab_area = 10,
        hover_icon_on_border    = true,
        allow_tearing           = false,
        no_focus_fallback       = true,
    }
})
