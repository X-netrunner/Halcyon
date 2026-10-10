local scheme = require("scheme.current")

return {
    ------------------
    ---- HYPRLAND ----
    ------------------

    -- Apps
    -- terminal / browser / file manager are chosen in Settings > Default apps (scripts/apps.sh, saved in
    -- ~/.local/state/island/apps.env) and change live; the keybinds always go through it
    terminal                   = "~/.config/Halcyon/scripts/apps.sh run terminal",
    browser                    = "~/.config/Halcyon/scripts/apps.sh run browser",
    editor                     = "~/.config/Halcyon/scripts/apps.sh run editor",   -- Settings > Default apps > Code editor
    fileExplorer               = "~/.config/Halcyon/scripts/apps.sh run files",
    audioSettings              = "pavucontrol",
    -- (SUPER+M music and SUPER+D communication start their apps from scripts/special.sh, see MUSIC_CMD / COMM_CMD there)
    -- size of windows on special workspaces: compact (Settings / SUPER+TAB tree switch ON) or full (OFF); the island applies it live
    specialScaleCompact        = 0.84,
    specialScaleFull           = 1.0,
    sysmonCmd                  = "~/.config/Halcyon/scripts/apps.sh term-exec btop --force-utf",      -- CTRL+SHIFT+ESC special workspace
    todoCmd                    = "sh -c 'command -v todoist >/dev/null && exec todoist || exec xdg-open https://app.todoist.com'",  -- SUPER+R special workspace

    -- Touchpad
    touchpadDisableTyping      = true,
    touchpadScrollFactor       = 0.3,   -- Settings > Scroll sensitivity changes these live
    mouseScrollFactor          = 1.0,
    keyRepeatDelay             = 250,   -- ms before a held key starts repeating (Hyprland default 600)
    keyRepeatRate              = 35,    -- repeats per second once it does (Hyprland default 25)
    gestureFingers             = 3,
    workspaceSwipeFingers      = 4,
    gestureFingersMore         = 4,

    -- ===== LOOK (one place to tune the feel; hyprland/general.lua + decoration.lua read these) =====
    -- Spacing: a 4px rhythm. The floating bar already adds ~16px at the top, so the outer gap is
    -- generous but not wasteful.
    windowGapsIn               = 8,
    windowGapsOut              = 16,
    workspaceGaps              = 0,
    singleWindowGapsOut        = 16,

    -- Shape: round enough to feel soft, and the island/panels use concentric radii (see Pal.qml)
    windowRounding             = 18,
    windowRoundingPower        = 3.0,      -- 2.0 = plain circle corners, higher = softer "squircle"
    windowBorderSize           = 1,
    -- Neutral hairlines (not tinted) so they sit well with whatever wallpaper palette is active
    activeWindowBorderColour   = "rgba(ffffff30)",
    inactiveWindowBorderColour = "rgba(ffffff10)",

    -- Focus: no transparency games, just a gentle dim on windows you are not using
    dimInactive                = true,
    dimStrength                = 0.07,
    dimSpecial                 = 0.35,     -- backdrop behind SUPER+S / M / D / R overlays

    -- Frosted glass behind translucent things (bar, panels, notifications, overlays)
    blurEnabled                = true,
    blurSize                   = 7,
    blurPasses                 = 3,
    blurNoise                  = 0.022,    -- fine film grain: this is the "texture"
    blurVibrancy               = 0.14,
    blurSpecialWs              = true,
    blurPopups                 = true,
    blurInputMethods           = true,
    blurXray                   = false,

    -- Soft, wide, low-contrast shadow that lifts the focused window a little
    shadowEnabled              = true,
    shadowRange                = 32,
    shadowRenderPower          = 3,
    shadowColour               = "rgba(00000058)",
    shadowColourInactive       = "rgba(00000024)",

    -- Fonts
    uiFont                     = "Inter",

    -- Misc
    volumeStep                 = 10,
    volumeMax                  = 100,
    cursorTheme                = "sweet-cursors",
    cursorSize                 = 24,
    sleepGestureCmd            = "systemctl suspend-then-hibernate",

    ------------------
    ---- KEYBINDS ----
    ------------------

    -- Workspaces
    kbMoveWinToWs              = "SUPER + ALT",
    kbMoveWinToWsGroup         = "CTRL + SUPER + ALT",
    kbGoToWs                   = "SUPER",
    kbGoToWsGroup              = "CTRL + SUPER",
    kbNextWs                   = "CTRL + SUPER + Right",
    kbPrevWs                   = "CTRL + SUPER + Left",
    kbScrollNextWs             = "SUPER + mouse_down",
    kbScrollPrevWs             = "SUPER + mouse_up",

    -- Window Group
    kbWindowGroupCycleNext     = "ALT + TAB",
    kbWindowGroupCyclePrev     = "SHIFT + ALT + TAB",
    kbUngroup                  = "SUPER + U",
    kbToggleGroup              = "SUPER + Comma",

    -- Window Action
    -- Mouse: hold SUPER and drag. RIGHT button moves the window, LEFT button resizes it (the reverse of Hyprland's stock
    -- layout). Buttons: mouse:272 = left, mouse:273 = right, mouse:274 = middle. Swap the two lines to get the stock layout back.
    kbMouseMove                = "SUPER + mouse:273",
    kbMouseResize              = "SUPER + mouse:272",
    kbMoveWindow               = "SUPER + Z",
    kbResizeWindow             = "SUPER + X",
    kbWindowPip                = "SUPER + ALT + backslash",
    kbPinWindow                = "SUPER + P",
    kbWindowFullscreen         = "SUPER + F",
    kbWindowBorderedFullscreen = "SUPER + ALT + F",
    kbToggleWindowFloating     = "SUPER + ALT + space",
    kbCloseWindow              = "SUPER + Q",

    -- Special workspaces toggles
    kbSpecialWs                = "SUPER + S",
    kbSystemMonitorWs          = "CTRL + SHIFT + Escape",
    kbMusicWs                  = "SUPER + M",
    kbCommunicationWs          = "SUPER + D",
    kbTodoWs                   = "SUPER + R",

    -- Apps
    kbTerminal                 = "SUPER + T",
    kbBrowser                  = "SUPER + W",
    kbEditor                   = "SUPER + C",
    kbFileExplorer             = "SUPER + E",

    -- Misc
    kbSession                  = "CTRL + ALT + Delete",
    kbShowSidebar              = "SUPER + N",
    kbClearNotifs              = "CTRL + ALT + C",
    kbShowPanels               = "SUPER + K",
    kbLock                     = "SUPER + L",
    kbRestoreLock              = "SUPER + ALT + L",
}