# Completions for the `halcyon` command (config/fish/functions/halcyon.fish).
complete -c halcyon -f
set -l __halcyon_cmds \
    "launcher:app menu and commands" "settings:Settings" "notification-builder:notification box builder" "bar-builder:bar builder" \
    "wallpaper-gallery:wallpaper gallery" "startup-view:startup and processes" "tour:guided tour (replay)" "calendar:Google Calendar" "notifications:notification centre" \
    "clear-notifications:remove all notifications" "dnd:do not disturb (toggle)" "cheatsheet:shortcuts tree" "power-menu:power menu" \
    "quick-terminal:pop-out terminal" "overview:workspace tree" "gaming-mode:gaming mode (toggle)" "caffeine:keep the screen awake (toggle)" \
    "lock:lock the screen" "theme:light / dark theme (toggle)" "reload:reload the island and Hyprland"
for __e in $__halcyon_cmds
    set -l __p (string split -m1 : $__e)
    complete -c halcyon -n __fish_use_subcommand -a $__p[1] -d $__p[2]
end
