function halcyon --description 'Open and control the Halcyon desktop from a terminal'
    # halcyon <command>: runs the same thing as the app menu's ">" commands and the keybinds, through the island's IPC.
    # Installed to ~/.config/fish/functions/halcyon.fish by install.sh / update.sh (scripts/user-setup.sh fish-commands).
    set -l names launcher settings notification-builder bar-builder desktop-builder widget-builder desktop-edit lock-widget-builder lock-desktop-edit bar wallpaper-gallery startup-view splash weekly-sky tour calendar notifications clear-notifications dnd cheatsheet power-menu quick-terminal overview gaming-mode caffeine lock theme reload notes notes-all clipboard screenshot screen-record extra-dim
    set -l calls launcher settings notifbuilder barbuilder desktopbuilder widgetbuilder desktopedit lockwidgetbuilder lockdesktopedit bar gallery startup splash weeklysky tour calendar notifcenter clearnotifs dnd cheatsheet power quickterm overview gaming caffeine lock theme reload notes notesAll clipboard screenshot record extradim
    set -l what "app menu and commands" "Settings" "notification box builder" "bar builder" "desktop builder: widget places & box activation zones" "widget builder: layout & look of each widget" "place the widgets right on the desktop" "lock screen: widget builder (layout & look of the lock screen's widgets)" "lock screen: place its widgets right on the screen" "top bar on / off (toggle)" "wallpaper gallery" "startup and processes" "play the login splash (moving stars and the sparkle)" "your week as stars: focus, tasks, events (save it as a picture)" "guided tour (replay)" "Google Calendar" "notification centre" "remove all notifications" "do not disturb (toggle)" "shortcuts tree" "power menu" "pop-out terminal" "workspace tree" "gaming mode (toggle)" "keep the screen awake (toggle)" "lock the screen" "light / dark theme (toggle)" "reload the island and Hyprland" "new-note panel on the side (type, Enter saves)" "all notes: search, pin, tick off" "clipboard history: search, click to copy it back" "screenshot panel: region, window, full screen" "screen recorder (toggle)" "extra dim screen (toggle)"

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
        printf "  %-20s %s\n" "music" "lyrics and queue panel (music lyrics | music queue to pick the tab)"
        printf "  %-20s %s\n" "lyrics" "print the lyrics of what plays, in the terminal (any source: .lrc file, lrclib.net, lyrics.ovh, spotify_player)"
        printf "  %-20s %s\n" "queue" "print what plays next, in the terminal"
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
    if test "$argv[1]" = clip
        switch "$rest[1]"
            case list ''
                python3 $HOME/.config/Halcyon/scripts/halcyon-clip.py json 40 | python3 -c "import sys,json; [print(e['id'].rjust(5), ' ', e['text'][:100]) for e in json.load(sys.stdin)['items']]"
            case '*'
                python3 $HOME/.config/Halcyon/scripts/halcyon-clip.py $rest
        end
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
