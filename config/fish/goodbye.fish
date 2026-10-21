# Halcyon: poweroff / reboot / shutdown now / systemctl poweroff|reboot typed in a terminal play the goodbye splash first
# (the stars drawn back in, about 2.4 s), exactly like the power menu. The island then runs the real command.
# Installed as ~/.config/fish/conf.d/halcyon-goodbye.fish by scripts/user-setup.sh.
# Only the plain forms are caught; anything with other options (shutdown +10, poweroff --force, systemctl reboot --firmware-setup ...)
# goes straight to the real command, and so does everything when the island is not running (a text console, ssh, Halcyon stopped).
# `sudo poweroff` runs the real command too. Skip it once:  command poweroff

function __halcyon_goodbye --argument-names action
    set -q WAYLAND_DISPLAY; or return 1
    command -q quickshell; or return 1
    timeout 3 quickshell ipc -p $HOME/.config/Halcyon/quickshell/island call island goodbye $action >/dev/null 2>&1
end

function poweroff --wraps poweroff --description 'Power off (with the Halcyon goodbye splash)'
    if test (count $argv) -eq 0; and __halcyon_goodbye shutdown
        return 0
    end
    command poweroff $argv
end

function reboot --wraps reboot --description 'Reboot (with the Halcyon goodbye splash)'
    if test (count $argv) -eq 0; and __halcyon_goodbye reboot
        return 0
    end
    command reboot $argv
end

function shutdown --wraps shutdown --description 'Shut down (now: with the Halcyon goodbye splash)'
    # a bare `shutdown` waits a minute (that is what it does): only the immediate forms are caught
    switch (string join ' ' -- $argv)
        case now 0 '-h now' '-P now' 'now -h' '-h 0' '-P 0'
            __halcyon_goodbye shutdown; and return 0
        case '-r now' 'now -r' '-r 0'
            __halcyon_goodbye reboot; and return 0
    end
    command shutdown $argv
end

function systemctl --wraps systemctl --description 'systemctl (poweroff / reboot: with the Halcyon goodbye splash)'
    if test (count $argv) -eq 1
        switch $argv[1]
            case poweroff
                __halcyon_goodbye shutdown; and return 0
            case reboot
                __halcyon_goodbye reboot; and return 0
        end
    end
    command systemctl $argv
end
