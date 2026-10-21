hl.config({
    misc = {
        disable_hyprland_logo     = true,
        disable_splash_rendering  = true,
        font_family               = "Inter",
        force_default_wallpaper   = 0,
        disable_autoreload        = false,
        vrr                       = 2,    -- 2 = only for fullscreen apps (1 = always: flicker on some laptop panels)
        mouse_move_enables_dpms   = true,
        key_press_enables_dpms    = true,
        always_follow_on_dnd      = true,
        animate_manual_resizes    = true,
        enable_swallow            = false,
        focus_on_activate         = false,   -- true = an app can pull you to its window (a Vesktop / Spotify update); false = it is only marked urgent
        allow_session_lock_restore = true,
        background_color          = "rgb(14161f)",
    }
})
