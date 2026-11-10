# Halcyon: one-time hints for the classic commands (installed to ~/.config/fish/conf.d/hints.fish by install.sh / update.sh).
# Each one prints its hint the first time you use that command in a shell, then stays quiet. Delete that file to turn them off.
# Only for interactive shells, so scripts that run under fish are not touched.
status is-interactive; or return

function grep --description 'Search text in files'
    if not set -q __hint_grep_shown
        set -g __hint_grep_shown 1
        echo -e "\e[33m[*]	Hint: Try using 'rg' (ripgrep) for much faster searches and better defaults!\e[0m" >&2
    end
    command grep $argv
end

function find --description 'Search for files'
    if not set -q __hint_find_shown
        set -g __hint_find_shown 1
        echo -e "\e[33m[*]	Hint: Try using 'fd' for a faster and more intuitive way to find files, or 'fzf' for interactive searching!\e[0m" >&2
    end
    command find $argv
end

function history --description 'View command history'
    if not set -q __hint_history_shown
        set -g __hint_history_shown 1
        echo -e "\e[33m[*]	Hint: Try pressing Ctrl+R for an interactive search powered by fzf!\e[0m" >&2
    end
    builtin history $argv
end

function cd --description 'Change directory'
    if not set -q __hint_cd_shown
        set -g __hint_cd_shown 1
        echo -e "\e[33m[*]	Hint: Try using 'z' (zoxide) to jump to frequent directories instantly!\e[0m" >&2
    end
    builtin cd $argv
end

function cat --description 'Concatenate and print files'
    if not set -q __hint_cat_shown
        set -g __hint_cat_shown 1
        echo -e "\e[33m[*]	Hint: Try using 'bat' for syntax highlighting and better paging!\e[0m" >&2
    end
    command cat $argv
end

function top --description 'Display Linux processes'
    if not set -q __hint_top_shown
        set -g __hint_top_shown 1
        echo -e "\e[33m[*]	Hint: Try using 'btop' or 'htop' for a much better process overview!\e[0m" >&2
    end
    command top $argv
end

function ls --description 'List directory contents'
    if not set -q __hint_ls_shown
        set -g __hint_ls_shown 1
        echo -e "\e[33m[*]	Hint: Try using 'eza' for icons, better colors, and directory grouping!\e[0m" >&2
    end
    if command -q eza
        eza --icons --group-directories-first $argv
    else
        command ls $argv
    end
end

function yazi --description 'Terminal file manager'
    if not set -q __hint_yazi_shown
        set -g __hint_yazi_shown 1
        echo -e "\e[36m[*]	Shortcut Reminder: Press Super + E anywhere to open your file manager instantly!\e[0m" >&2
    end
    command yazi $argv
end

function btop --description 'Resource monitor'
    if not set -q __hint_btop_shown
        set -g __hint_btop_shown 1
        echo -e "\e[36m[*]	Shortcut Reminder: Press Ctrl + Shift + Esc to toggle your dedicated Btop workspace!\e[0m" >&2
    end
    command btop $argv
end

