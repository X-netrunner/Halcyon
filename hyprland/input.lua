local vars = require("variables")

hl.config({
    input = {
        kb_layout                   = "us",
        repeat_delay                = vars.keyRepeatDelay,
        repeat_rate                 = vars.keyRepeatRate,
        follow_mouse                = 1,
        mouse_refocus               = true,
        float_switch_override_focus = 0,
        numlock_by_default          = true,
        sensitivity                 = 0,
        scroll_factor               = vars.mouseScrollFactor,   -- mouse wheel (Settings > Scroll sensitivity)
        accel_profile               = "adaptive",
        left_handed                 = false,
        touchpad                    = {
            natural_scroll          = true,
            disable_while_typing    = vars.touchpadDisableTyping,
            scroll_factor           = vars.touchpadScrollFactor,
            drag_lock               = false,
            tap_to_click            = true,
            tap_button_map          = "lrm",
        },
    },
    dwindle = {
        preserve_split              = true,
        smart_split                 = false,
        smart_resizing              = true,
        special_scale_factor        = vars.specialScaleCompact,   -- the island switches it to specialScaleFull when "compact special workspaces" is off
        use_active_for_splits       = true,
    },
    master = {
        mfact                       = 0.55,
        orientation                 = "left",
        special_scale_factor        = vars.specialScaleCompact,
    }
})
