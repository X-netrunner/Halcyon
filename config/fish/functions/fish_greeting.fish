function fish_greeting
    # Terminal greeting: a logo, some system info and a shortcut tip.
    # Which logo is chosen in Settings > Terminal greeting (or with scripts/greeting-conf.sh); the choice lives in
    # ~/.config/Halcyon/greeting.conf as a line  LOGO=<name>:
    #   adaptive  the logo of the system you are on (read from /etc/os-release): Arch family -> Arch, BlackArch, Kali, anything else -> Linux
    #   arch / blackarch / kali / linux   always that one
    #   custom    your own ASCII art from ~/.config/Halcyon/greeting-custom.txt
    #   none      no logo, just the info        off   no greeting at all
    # Logos are plain text files in config/fish/greeting/logos/. In a logo (and in your custom file) @C1@ switches to the main
    # colour and @C2@ to the second one; a line without markers is in the main colour. Colour codes already in the text work too.
    set -l rice $HALCYON_DIR
    test -n "$rice"; or set rice $HOME/.config/Halcyon

    set -l choice adaptive
    if test -r $rice/greeting.conf
        set -l v (string match -rg '^LOGO=(\w+)' < $rice/greeting.conf)
        set -q v[1]; and set choice $v[1]
    end
    contains -- $choice adaptive arch blackarch kali linux custom none off; or set choice adaptive
    test "$choice" = off; and return

    # what system is this (one read of os-release; PRETTY_NAME is shown as "distro", so CachyOS says CachyOS, not Arch)
    set -l os_id ""
    set -l os_like ""
    set -l os_name ""
    if test -r /etc/os-release
        set -l t (string match -rg '^ID="?([^"]*)' < /etc/os-release)
        set -q t[1]; and set os_id (string lower -- $t[1])
        set t (string match -rg '^ID_LIKE="?([^"]*)' < /etc/os-release)
        set -q t[1]; and set os_like (string lower -- $t[1])
        set t (string match -rg '^PRETTY_NAME="?([^"]*)' < /etc/os-release)
        set -q t[1]; and set os_name $t[1]
    end
    test -n "$os_name"; or set os_name Linux
    set -l in_kali 0
    test "$os_id" = kali; and set in_kali 1

    # the logo "adaptive" would pick
    set -l auto linux
    switch "$os_id"
        case blackarch
            set auto blackarch
        case kali
            set auto kali
        case arch cachyos endeavouros manjaro garuda artix arcolinux
            set auto arch
        case '*'
            if string match -qi '*blackarch*' -- "$os_name"
                set auto blackarch
            else if string match -qr '(^| )arch( |$)' -- "$os_like"
                set auto arch
            end
    end
    set -l pick $auto
    test "$choice" != adaptive; and set pick $choice
    # "custom" without a usable file quietly falls back to adaptive
    if test "$pick" = custom; and not test -s $rice/greeting-custom.txt
        set pick $auto
    end

    # Fetch system info using /proc/uptime and /proc/meminfo (zero awk/sed/free child processes on every new terminal)
    set -l user_host $USER"@"(prompt_hostname)
    set -l kernel (uname -r)
    set -l uptime "?"
    if test -r /proc/uptime
        read -l up_raw < /proc/uptime
        set -l up_sec (string split '.' -- (string split ' ' -- $up_raw)[1])[1]
        set -l d (math -s0 "$up_sec / 86400")
        set -l h (math -s0 "($up_sec % 86400) / 3600")
        set -l m (math -s0 "($up_sec % 3600) / 60")
        set -l parts
        test $d -gt 0; and set -a parts "$d day"(test $d -gt 1; and echo s)
        test $h -gt 0; and set -a parts "$h hour"(test $h -gt 1; and echo s)
        test $m -gt 0 -o (count $parts) -eq 0; and set -a parts "$m minute"(test $m -ne 1; and echo s)
        set uptime (string join ", " -- $parts)
    end
    set -l shell "fish $version"
    set -l memory "? / ?"
    if test -r /proc/meminfo
        set -l mt 0
        set -l ma 0
        while read -l k v rest
            switch $k
                case 'MemTotal:'
                    set mt $v
                case 'MemAvailable:'
                    set ma $v
                    break
            end
        end < /proc/meminfo
        if test $mt -gt 0
            set -l used_gb (math -s1 "($mt - $ma) / 1048576")
            set -l tot_gb (math -s1 "$mt / 1048576")
            set memory (printf '%sGB / %sGB' $used_gb $tot_gb)
        end
    end

    # sysmode: read the mode file directly (cyber = old name of relaxed, hacking = old name of stealth)
    set -l mode "N/A"
    if test "$in_kali" = 0
        set -l sm
        test -r /etc/sysmode.mode; and read -l sm </etc/sysmode.mode
        switch "$sm"
            case relaxed cyber
                set mode (set_color -o yellow)"RELAXED"(set_color normal)
            case secure
                set mode (set_color -o green)"SECURE"(set_color normal)
            case stealth hacking
                set mode (set_color -o cyan)"STEALTH"(set_color normal)
            case lockdown
                set mode (set_color -o red)"LOCKDOWN / FORTRESS"(set_color normal)
            case ''
                # never switched yet: ask sysmode once
                if command -q sysmode
                    set mode (sysmode status 2>/dev/null | command grep 'Mode:' | sed -E 's/Mode: //g')
                end
            case '*'
                set mode (set_color -o magenta)"CUSTOM / MIXED"(set_color normal)
        end
    end

    # Wallpaper accent color from Halcyon (with fallback to red)
    set -l acc_color (set_color -o red)
    if test -n "$fish_color_command" -a "$fish_color_command" != "normal"
        set acc_color (set_color -o $fish_color_command)
    else if test -r "$HOME/.cache/island/ansi.env"
        set -l acc_hex (string match -rg '^A_ACC=#?([0-9a-fA-F]{6})' < "$HOME/.cache/island/ansi.env")
        if set -q acc_hex[1]
            set acc_color (set_color -o $acc_hex[1])
        end
    end

    # Colors
    set -l red (set_color -o red)
    set -l blue (set_color -o blue)
    set -l grey (set_color 555)
    set -l reset (set_color normal)
    set -l label_color (set_color -o white)
    set -l value_color (set_color normal)

    # Breathing room from the left edge
    set -l margin "      "

    # colours: @C1@ = c1, @C2@ = c2 (Kali and BlackArch keep their own colours, everything else follows the wallpaper)
    set -l c1 $acc_color
    set -l c2 $grey
    set -l title_color $acc_color
    switch $pick
        case kali
            set c1 $blue
            set c2 (set_color 888888)
            set title_color $blue
        case blackarch
            set c1 $red
            set c2 (set_color 888888)
            set title_color $red
    end

    # the logo lines (none = no logo)
    set -l logo
    switch $pick
        case none
        case custom
            set logo (command cat $rice/greeting-custom.txt)
        case '*'
            set -l f $rice/config/fish/greeting/logos/$pick.txt
            test -r $f; and set logo (command cat $f)
    end
    if set -q logo[1]
        # tidy: Windows line ends, tabs, blank lines at the end, at most 40 rows
        set logo (string replace -a \r '' -- $logo)
        set logo (string replace -a \t '    ' -- $logo)
        while set -q logo[1]; and not string match -qr '\S' -- "$logo[-1]"
            set -e logo[-1]
        end
        set -q logo[41]; and set logo $logo[1..40]
    end

    # colour each line and measure it by its visible width (escape codes must not count toward the column)
    set -l rendered
    set -l widths
    set -l maxw 0
    for raw in $logo
        set -l line (string replace -a '@C1@' "$c1" -- "$c1$raw")
        set line (string replace -a '@C2@' "$c2" -- "$line")
        set -l w (string length -- (string replace -ra "\x1b(\[[0-9;:]*[A-Za-z]|\(B)" "" -- "$line"))
        set -a rendered $line
        set -a widths $w
        test $w -gt $maxw; and set maxw $w
    end

    # the info block, as lines
    set -l dot "●"
    set -l info "$title_color$user_host$reset"
    set -a info "$grey"(string repeat -n (string length "$user_host") -)"$reset"
    set -a info "$label_color"distro"     $value_color$os_name$reset"
    set -a info "$label_color"kernel"     $value_color$kernel$reset"
    set -a info "$label_color"uptime"     $value_color$uptime$reset"
    set -a info "$label_color"shell"      $value_color$shell$reset"
    set -a info "$label_color"memory"     $value_color$memory$reset"
    test "$in_kali" = 0; and set -a info "$label_color"mode"       $mode$reset"
    set -a info ""
    set -a info (string join "" (set_color red) $dot " " (set_color yellow) $dot " " (set_color green) $dot " " (set_color blue) $dot " " (set_color magenta) $dot " " (set_color cyan) $dot " " (set_color white) $dot $reset)

    # the info sits in the vertical middle of the logo (at the top when the logo is shorter than the info)
    set -l n_logo (count $rendered)
    set -l n_info (count $info)
    set -l off 0
    test $n_logo -gt $n_info; and set off (math -s0 "floor(($n_logo - $n_info) / 2)")
    set -l rows $n_logo
    test (math "$off + $n_info") -gt $rows; and set rows (math "$off + $n_info")

    for r in (seq 1 $rows)
        set -l text ""
        set -l ri (math "$r - $off")
        if test $ri -ge 1; and test $ri -le $n_info
            set text $info[$ri]
        end

        if test $n_logo -eq 0
            printf "%s%s\n" "$margin" "$text"
            continue
        end

        set -l left ""
        set -l pad $maxw
        if test $r -le $n_logo
            set left $rendered[$r]
            set pad (math "$maxw - $widths[$r]")
        end
        set -l spaces ""
        test $pad -gt 0; and set spaces (string repeat -n $pad " ")

        if test -n "$text"
            printf "%s%s%s%s   %s\n" "$margin" "$left" "$spaces" "$reset" "$text"
        else
            printf "%s%s%s%s\n" "$margin" "$left" "$spaces" "$reset"
        end
    end

    # Rotating shortcut tip
    set -l tips \
        "Super + E           → Open your configured file manager" \
        "Ctrl + Shift + Esc  → Toggle dedicated Btop system monitor" \
        "Super + Alt + T     → Toggle Scrolling (Niri) / Dwindle layout" \
        "Super + /           → Open full Keybinds Cheatsheet HUD" \
        "Super + ← →         → Focus the previous / next window (columns in Scrolling layout)" \
        "Super + I           → Open Halcyon Settings" \
        "Super + M           → Toggle Music workspace" \
        "Super + Alt + N     → Toggle Nightlight (Gamma)" \
        "Super + Alt + W     → Toggle Live Wallpaper" \
        "Super + V           → Open Clipboard History"
    set -l chosen (random choice $tips)
    echo
    set_color cyan
    printf "      Tip: "
    set_color yellow
    echo "$chosen"
    set_color normal
    echo
end
