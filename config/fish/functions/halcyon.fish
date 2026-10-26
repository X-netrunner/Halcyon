function halcyon --description 'Open and control the Halcyon desktop from a terminal'
    # halcyon <command>: runs the same thing as the app menu's ">" commands and the keybinds, through the island's IPC.
    # Installed to ~/.config/fish/functions/halcyon.fish by install.sh / update.sh (scripts/user-setup.sh fish-commands).
    set -l names launcher settings notification-builder bar-builder desktop-builder lock-builder widget-builder desktop-edit lock-widget-builder lock-desktop-edit bar wallpaper-gallery startup-view splash weekly-sky focus-graph tour calendar notifications clear-notifications dnd cheatsheet power-menu quick-terminal overview gaming-mode caffeine lock theme reload notes notes-all clipboard screenshot screen-record extra-dim games study
    set -l calls launcher settings notifbuilder barbuilder desktopbuilder lockdesktopbuilder widgetbuilder desktopedit lockwidgetbuilder lockdesktopedit bar gallery startup splash weeklysky focusgraph tour calendar notifcenter clearnotifs dnd cheatsheet power quickterm overview gaming caffeine lock theme reload notes notesAll clipboard screenshot record extradim gamecenter study
    set -l what "app menu and commands" "Settings" "notification box builder" "bar builder" "desktop builder: widget places & box activation zones" "lock screen builder: background, blur, tint, stars, widgets" "widget builder: layout & look of each widget" "place the widgets right on the desktop" "lock screen: widget builder (layout & look of the lock screen's widgets)" "lock screen: place its widgets right on the screen" "top bar on / off (toggle)" "wallpaper gallery" "startup and processes" "play the login splash (moving stars and the sparkle)" "your week as stars: focus, tasks, events (save it as a picture)" "focus streak: flame, today, 14 days, 12 weeks, milestones, start a session" "guided tour (replay)" "Google Calendar" "notification centre" "remove all notifications" "do not disturb (toggle)" "shortcuts tree" "power menu" "pop-out terminal" "workspace tree" "gaming mode (toggle)" "keep the screen awake (toggle)" "lock the screen" "light / dark theme (toggle)" "reload the island and Hyprland" "new-note panel on the side (type, Enter saves)" "all notes: search, pin, tick off" "clipboard history: search, click to copy it back" "screenshot panel: region, window, full screen" "screen recorder (toggle)" "extra dim screen (toggle)" "game center: your games, Proton versions, system check" "study center: ask your PDFs and notes, summaries, quizzes, flashcards"

    if test (count $argv) -eq 0; or contains -- $argv[1] -h --help help
        echo "Usage: halcyon <command>"
        echo
        for i in (seq (count $names))
            printf "  %-20s %s\n" $names[$i] $what[$i]
        end
        printf "  %-20s %s\n" "safe-mode" "effects off if the desktop misbehaves; 'safe-mode back' restores (works without the island)"
        printf "  %-20s %s\n" "profile" "work | gaming | battery | night | custom: stars, blur, motion, brightness, top bar"
        printf "  %-20s %s\n" "shot" "shot region|window|full [copy|save|both]: take it now, no panel (works without the island)"
        printf "  %-20s %s\n" "clip" "clip list|status|clear: the clipboard history from a terminal"
        printf "  %-20s %s\n" "luna" "Luna window; luna list|show|new|chat: your saved chats from a terminal"
        printf "  %-20s %s\n" "study" "Study Center window; study add|ask|list|remove|make: your files from a terminal"
        printf "  %-20s %s\n" "music" "lyrics and queue panel (music lyrics | music queue to pick the tab)"
        printf "  %-20s %s\n" "lyrics" "print the lyrics of what plays, in the terminal (any source: .lrc file, lrclib.net, lyrics.ovh, spotify_player)"
        printf "  %-20s %s\n" "queue" "print what plays next, in the terminal"
        printf "  %-20s %s\n" "colorpick" "pick a pixel on screen: its colour is copied (colorpick hex|rgb|hsl)"
        printf "  %-20s %s\n" "measure" "drag a box on screen: its size in pixels is copied"
        printf "  %-20s %s\n" "wifi-qr" "QR code of the Wi-Fi you are on (wifi-qr --text prints the code text)"
        printf "  %-20s %s\n" "updates" "updates check|now|status|run: pending pacman / AUR updates"
        printf "  %-20s %s\n" "snippets" "snippets list|add|rm|copy|type|pick: text you paste often ({date} {time} {clip})"
        printf "  %-20s %s\n" "windows" "windows last|next|prev|pick|list: flip between open windows"
        printf "  %-20s %s\n" "mixer" "mixer list|set|mute: volume per app (mixer set spotify 30)"
        printf "  %-20s %s\n" "zoom" "zoom in|out|reset|toggle: magnify the whole screen"
        printf "  %-20s %s\n" "vpn" "vpn status|up|down|toggle: NetworkManager VPN / WireGuard / Tailscale"
        printf "  %-20s %s\n" "ai" "ai ask|do|clip|brief|explain|safety|organise|lyrics|updates|study|commit: the local AI helpers (halcyon ai --help)"
        printf "  %-20s %s\n" "selftest" "selftest [--quick] [--rust] [DIR]: the CI checks on this machine, plus is the island running and loaded"
        return 0
    end

    # these two run a script, not the island, so they still work when the island is stuck or not running (also from a TTY)
    if contains -- $argv[1] safe-mode profile
        python3 $HOME/.config/Halcyon/scripts/halcyon-fx.py $argv
        return $status
    end

    # the screenshot engine and the clipboard history helper, also without the island
    set -l rest
    test (count $argv) -gt 1; and set rest $argv[2..-1]
    if test "$argv[1]" = shot
        python3 $HOME/.config/Halcyon/scripts/halcyon-shot.py $rest
        return $status
    end
    # halcyon study = the window; halcyon study add notes.pdf / ask "..." / list / make cards: the library from a terminal
    if test "$argv[1]" = study; and test (count $rest) -gt 0
        python3 $HOME/.config/Halcyon/scripts/halcyon-study.py $rest
        return $status
    end
    # halcyon luna = the window; halcyon luna list / show ID / new / chat ID -- "...": the saved chats from a terminal
    if test "$argv[1]" = luna; and test (count $rest) -gt 0
        python3 $HOME/.config/Halcyon/scripts/halcyon-luna.py $rest
        return $status
    end
    if test "$argv[1]" = clip
        switch "$rest[1]"
            case list ''
                python3 $HOME/.config/Halcyon/scripts/halcyon-clip.py json 40 | python3 -c "import sys,json; [print(e['id'].rjust(5), ' ', e['text'][:100]) for e in json.load(sys.stdin)['items']]"
            case '*'
                python3 $HOME/.config/Halcyon/scripts/halcyon-clip.py $rest
        end
        return $status
    end

    # the local AI helpers (scripts/halcyon-ai.py): ask, do, clip, brief, explain, safety, organise, lyrics, updates, study, commit. Only `do` needs the island
    if test "$argv[1]" = ai
        python3 $HOME/.config/Halcyon/scripts/halcyon-ai.py $rest
        return $status
    end

    # the CI checks here, read-only (scripts/halcyon-selftest.sh); also without the island
    if test "$argv[1]" = selftest
        bash $HOME/.config/Halcyon/scripts/halcyon-selftest.sh $rest
        return $status
    end

    # the everyday tools (scripts/halcyon-tools.py): colour picker, Wi-Fi QR, updates, snippets, windows, mixer, phone, zoom, VPN
    if contains -- $argv[1] colorpick measure wifi-qr updates snippets snippet windows mixer zoom vpn
        python3 $HOME/.config/Halcyon/scripts/halcyon-tools.py $argv
        return $status
    end

    # lyrics / queue in the terminal: the same helper the panel uses, so no island is needed
    if contains -- $argv[1] lyrics queue
        python3 $HOME/.config/Halcyon/scripts/halcyon-music.py $argv[1] $rest
        return $status
    end
    if test "$argv[1]" = music
        switch "$rest[1]"
            case queue
                quickshell ipc -p $HOME/.config/Halcyon/quickshell/island call island queue >/dev/null 2>&1; or begin; echo "halcyon: the island is not running" >&2; return 1; end
            case status
                python3 $HOME/.config/Halcyon/scripts/halcyon-music.py status
            case source
                python3 $HOME/.config/Halcyon/scripts/halcyon-music.py source $rest[2..-1]
            case '*'
                quickshell ipc -p $HOME/.config/Halcyon/quickshell/island call island lyrics >/dev/null 2>&1; or begin; echo "halcyon: the island is not running" >&2; return 1; end
        end
        return $status
    end

    set -l i (contains -i -- $argv[1] $names)
    if test -z "$i"
        echo "halcyon: unknown command '$argv[1]' (halcyon --help lists them)" >&2
        return 2
    end
    if not command -q quickshell
        echo "halcyon: quickshell is not installed" >&2
        return 1
    end
    if not quickshell ipc -p $HOME/.config/Halcyon/quickshell/island call island $calls[$i] >/dev/null 2>&1
        echo "halcyon: the island is not running. Log in to Halcyon, or run ~/.config/Halcyon/scripts/start-shell.sh island" >&2
        return 1
    end
end
