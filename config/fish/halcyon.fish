# Halcyon: fish colours + the Starship prompt (installed to ~/.config/fish/conf.d/halcyon.fish by install.sh / app-themes.sh).
# The colours come from the wallpaper: scripts/app-themes.sh writes ~/.cache/island/halcyon-colors.fish on every wallpaper change,
# and the handler below loads it before every prompt (only when the file changed). It runs AFTER config.fish, so a colour theme
# set there (or with `fish_config`) cannot hide it, and shells that are already open follow the wallpaper too.
# Delete this file to go back to your own fish colours.
status is-interactive; or return

set -g __halcyon_colors_file $HOME/.cache/island/halcyon-colors.fish
function __halcyon_colors --on-event fish_prompt
    test -f $__halcyon_colors_file; or return
    set -l m (stat -c %Y $__halcyon_colors_file 2>/dev/null)
    test "$m" = "$__halcyon_colors_mtime"; and return
    set -g __halcyon_colors_mtime $m
    source $__halcyon_colors_file
end
__halcyon_colors

# the prompt: Starship (only when ~/.config/fish/config.fish does not start it already)
if type -q starship; and not grep -qs 'starship init fish' $HOME/.config/fish/config.fish
    starship init fish | source
end
