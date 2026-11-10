local vars = require("variables")

hl.config({
    decoration = {
        rounding              = vars.windowRounding,
        rounding_power        = vars.windowRoundingPower,
        active_opacity        = 1.0,
        inactive_opacity      = 1.0,
        fullscreen_opacity    = 1.0,

        dim_inactive          = vars.dimInactive,
        dim_strength          = vars.dimStrength,
        dim_special           = vars.dimSpecial,
        dim_around            = 0.45,

        shadow                = {
            enabled           = vars.shadowEnabled,
            range             = vars.shadowRange,
            render_power      = vars.shadowRenderPower,
            color             = vars.shadowColour,
            color_inactive    = vars.shadowColourInactive,
        },
        blur                  = {
            enabled           = vars.blurEnabled,
            size              = vars.blurSize,
            passes            = vars.blurPasses,
            ignore_opacity    = true,
            new_optimizations = true,
            xray              = vars.blurXray,
            noise             = vars.blurNoise,
            contrast          = 0.96,
            brightness        = 1.0,
            vibrancy          = vars.blurVibrancy,
            special           = vars.blurSpecialWs,
            popups            = vars.blurPopups,
            input_methods     = vars.blurInputMethods,
        },
    }
})
