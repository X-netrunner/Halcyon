# Completions for the `halcyon` command (config/fish/functions/halcyon.fish).
complete -c halcyon -f
set -l __halcyon_cmds \
    "launcher:app menu and commands" "settings:Settings" "notification-builder:notification box builder" "bar-builder:bar builder" "desktop-builder:desktop builder" "lock-builder:lock screen builder" "widget-builder:widget builder" "desktop-edit:place widgets on the desktop" "lock-widget-builder:lock screen widget builder" "lock-desktop-edit:place widgets on the lock screen" "bar:top bar on / off (toggle)" \
    "wallpaper-gallery:wallpaper gallery" "startup-view:startup and processes" "splash:play the login splash" "weekly-sky:your week as stars" "focus-graph:focus streak graph (Settings > Focus mode)" "tour:guided tour (replay)" "calendar:Google Calendar" "notifications:notification centre" \
    "clear-notifications:remove all notifications" "dnd:do not disturb (toggle)" "cheatsheet:shortcuts tree" "power-menu:power menu" \
    "quick-terminal:pop-out terminal" "overview:workspace tree" "gaming-mode:gaming mode (toggle)" "caffeine:keep the screen awake (toggle)" \
    "lock:lock the screen" "theme:light / dark theme (toggle)" "reload:reload the island and Hyprland" \
    "notes:new-note panel on the side (type, Enter saves)" "notes-all:all notes: search, pin, tick off" \
    "clipboard:clipboard history panel" "screenshot:screenshot panel"
for __e in $__halcyon_cmds
    set -l __p (string split -m1 : $__e)
    complete -c halcyon -n __fish_use_subcommand -a $__p[1] -d $__p[2]
end
complete -c halcyon -n __fish_use_subcommand -a safe-mode -d "effects off if the desktop misbehaves (works without the island)"
complete -c halcyon -n "__fish_seen_subcommand_from safe-mode" -a "on back toggle status" -d "safe mode"
complete -c halcyon -n __fish_use_subcommand -a profile -d "work | gaming | battery | night | custom"
complete -c halcyon -n "__fish_seen_subcommand_from profile" -a "work gaming battery night custom list status" -d "profile"
complete -c halcyon -n __fish_use_subcommand -a shot -d "take a screenshot now: region | window | full"
complete -c halcyon -n "__fish_seen_subcommand_from shot" -a "region window full copy save both conf" -d "screenshot"
complete -c halcyon -n __fish_use_subcommand -a clip -d "clipboard history from a terminal"
complete -c halcyon -n "__fish_seen_subcommand_from clip" -a "list status clear" -d "clipboard history"
complete -c halcyon -n __fish_use_subcommand -a music -d "lyrics and queue panel"
complete -c halcyon -n "__fish_seen_subcommand_from music" -a "lyrics queue status" -d "music panel"
complete -c halcyon -n __fish_use_subcommand -a lyrics -d "print the lyrics of what plays (any player)"
complete -c halcyon -n __fish_use_subcommand -a queue -d "print what plays next"
complete -c halcyon -n __fish_use_subcommand -a ai -d "local AI helpers: ask, do, clip, brief, explain, safety, organise, lyrics"
complete -c halcyon -n "__fish_seen_subcommand_from ai; and not __fish_seen_subcommand_from ask do clip brief explain safety organise lyrics" -a "ask do clip brief explain safety organise lyrics" -d "AI helper"
complete -c halcyon -n "__fish_seen_subcommand_from ai; and __fish_seen_subcommand_from clip" -a "summarise rewrite" -d "clipboard text"
complete -c halcyon -n "__fish_seen_subcommand_from ai; and __fish_seen_subcommand_from explain" -a "last island unit show" -d "explain"
complete -c halcyon -n "__fish_seen_subcommand_from ai; and __fish_seen_subcommand_from lyrics" -a "meaning" -d "lyrics"
# the everyday tools (scripts/halcyon-tools.py)
complete -c halcyon -n __fish_use_subcommand -a selftest -d "run the CI checks here: syntax, QML, tests, is the island loaded"
complete -c halcyon -n "__fish_seen_subcommand_from selftest" -a "--quick --rust" -d "quick: only what breaks a login; rust: clippy gate"
complete -c halcyon -n __fish_use_subcommand -a colorpick -d "pick a pixel: copy its colour"
complete -c halcyon -n "__fish_seen_subcommand_from colorpick" -a "hex rgb hsl" -d "colour format"
complete -c halcyon -n __fish_use_subcommand -a measure -d "drag a box: copy its size in pixels"
complete -c halcyon -n __fish_use_subcommand -a wifi-qr -d "QR code of the current Wi-Fi"
complete -c halcyon -n "__fish_seen_subcommand_from wifi-qr" -a "--text" -d "print the code text instead"
complete -c halcyon -n __fish_use_subcommand -a updates -d "pending pacman / AUR updates"
complete -c halcyon -n "__fish_seen_subcommand_from updates" -a "check now status run" -d "updates"
complete -c halcyon -n __fish_use_subcommand -a snippets -d "text you paste often"
complete -c halcyon -n "__fish_seen_subcommand_from snippets" -a "list add rm copy type pick" -d "snippets"
complete -c halcyon -n __fish_use_subcommand -a windows -d "flip between open windows"
complete -c halcyon -n "__fish_seen_subcommand_from windows" -a "last next prev pick list" -d "windows"
complete -c halcyon -n __fish_use_subcommand -a mixer -d "volume per app"
complete -c halcyon -n "__fish_seen_subcommand_from mixer" -a "list pick set mute unmute" -d "mixer"
complete -c halcyon -n __fish_use_subcommand -a phone -d "KDE Connect: send, ring, text"
complete -c halcyon -n "__fish_seen_subcommand_from phone" -a "devices send text ring ping" -d "phone"
complete -c halcyon -n __fish_use_subcommand -a zoom -d "magnify the whole screen"
complete -c halcyon -n "__fish_seen_subcommand_from zoom" -a "in out reset toggle" -d "zoom"
complete -c halcyon -n __fish_use_subcommand -a vpn -d "VPN on / off"
complete -c halcyon -n "__fish_seen_subcommand_from vpn" -a "status list up down toggle" -d "VPN"
