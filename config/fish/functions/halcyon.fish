function halcyon --description 'Open and control the Halcyon desktop from a terminal'
    # halcyon <command>: runs the same thing as the app menu's ">" commands and the keybinds, through the island's IPC.
    # Installed to ~/.config/fish/functions/halcyon.fish by install.sh / update.sh (scripts/user-setup.sh fish-commands).
    set -l names launcher settings notification-builder bar-builder desktop-builder widget-builder desktop-edit bar wallpaper-gallery startup-view tour calendar notifications clear-notifications dnd cheatsheet power-menu quick-terminal overview gaming-mode caffeine lock theme reload notes screen-record extra-dim
    set -l calls launcher settings notifbuilder barbuilder desktopbuilder widgetbuilder desktopedit bar gallery startup tour calendar notifcenter clearnotifs dnd cheatsheet power quickterm overview gaming caffeine lock theme reload notes record extradim
    set -l what "app menu and commands" "Settings" "notification box builder" "bar builder" "desktop builder: widget places & box activation zones" "widget builder: layout & look of each widget" "place the widgets right on the desktop" "top bar on / off (toggle)" "wallpaper gallery" "startup and processes" "guided tour (replay)" "Google Calendar" "notification centre" "remove all notifications" "do not disturb (toggle)" "shortcuts tree" "power menu" "pop-out terminal" "workspace tree" "gaming mode (toggle)" "keep the screen awake (toggle)" "lock the screen" "light / dark theme (toggle)" "reload the island and Hyprland" "quick notes overlay" "screen recorder (toggle)" "extra dim screen (toggle)"

    if test (count $argv) -eq 0; or contains -- $argv[1] -h --help help
        echo "Usage: halcyon <command>"
        echo
        for i in (seq (count $names))
            printf "  %-20s %s\n" $names[$i] $what[$i]
        end
        return 0
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
