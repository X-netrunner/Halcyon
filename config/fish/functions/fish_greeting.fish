function fish_greeting
    # Distro-aware greeting: Kali dragon when running inside a Kali
    # container (distrobox / pentest-box), Arch logo otherwise.
    set -l in_kali 0
    if grep -qiE '^ID="?kali' /etc/os-release 2>/dev/null
        set in_kali 1
    end

    # Fetch system info
    set -l user_host (id -un)"@"(prompt_hostname)
    set -l kernel (uname -r)
    set -l uptime (uptime -p | sed 's/^up //')
    set -l shell_ver (fish --version | awk '{print $3}')
    set -l shell "fish $shell_ver"
    set -l mem_used (free -h | awk '/^Mem:/ {print $3}' | sed 's/i/B/')
    set -l mem_total (free -h | awk '/^Mem:/ {print $2}' | sed 's/i/B/')
    set -l memory "$mem_used / $mem_total"

    set -l mode "N/A"
    if test "$in_kali" = 0
        and command -v sysmode &>/dev/null
        set mode (sysmode status 2>/dev/null | command grep 'Mode:' | sed -E 's/Mode: //g')
    end

    # Wallpaper accent color from Halcyon (with fallback to red)
    set -l acc_color (set_color -o red)
    if test -n "$fish_color_command" -a "$fish_color_command" != "normal"
        set acc_color (set_color -o $fish_color_command)
    else if test -f "$HOME/.cache/island/ansi.env"
        set -l acc_hex (grep -m1 '^A_ACC=' "$HOME/.cache/island/ansi.env" 2>/dev/null | cut -d= -f2 | tr -d '#')
        if test -n "$acc_hex"
            set acc_color (set_color -o $acc_hex)
        end
    end

    # Colors
    set -l red (set_color -o red)
    set -l blue (set_color -o blue)
    set -l grey (set_color 555)
    set -l reset (set_color normal)
    set -l title_color $acc_color
    set -l label_color (set_color -o white)
    set -l value_color (set_color normal)

    # Breathing room from the left edge
    set -l margin "      "

    set -l distro
    set -l logo
    set -l c1 $acc_color
    set -l c2 $grey
    set -l logo_width 38
    set -l i_user 0
    set -l i_dashes 0
    set -l i_distro 0
    set -l i_kernel 0
    set -l i_uptime 0
    set -l i_shell 0
    set -l i_memory 0
    set -l i_mode 0
    set -l i_dots 0

    if test "$in_kali" = 1
        set distro "Kali Linux"
        set title_color (set_color -o blue)
        set c1 $blue
        set c2 (set_color 888888)
        set logo_width 52
        set logo \
"@C1@.............." \
"            ..,;:ccc,." \
"          ......''';lxO,." \
".....''''..........,:ld;" \
"           .';;;:::;,,.x," \
"      ..'''.            0Xxoc:,.  ..." \
"  ....                ,ONkc;,;cokOdc',." \
" .                   OMo           ':@C2@dd@C1@o." \
"                    dMc               :OO;" \
"                    0M.                 .:o." \
"                    ;Wd" \
"                     ;XO," \
"                       ,d0Odlc;,.." \
"                           ..',;:cdOOd::,." \
"                                    .:d;.':;." \
"                                       'd,  .'" \
"                                         ;l   .." \
"                                          .o" \
"                                            c" \
"                                            .'" \
"                                             ."
        set i_user 3
        set i_dashes 4
        set i_distro 5
        set i_kernel 6
        set i_uptime 7
        set i_shell 8
        set i_memory 9
        set i_dots 21
    else
        set distro "Arch Linux"
        set title_color $acc_color
        set c1 $acc_color
        set logo_width 38
        set logo \
"                 00" \
"                 11" \
"                ====" \
"                .//" \
"                `o//:" \
"               `+o//o:" \
"              `+oo//oo:" \
"              -+oo//oo+:" \
"            `/:-:+//ooo+:" \
"           `/+++++//+++++:" \
"          `/++++++//++++++:" \
"         `/+++oooo//ooooooo/`" \
"        ./ooosssso//osssssso+`" \
"       .oossssso-`//`/ossssss+`" \
"      -osssssso.  //  :ssssssso." \
"     :osssssss/   //   osssso+++." \
"    /ossssssss/   //   +ssssooo/-" \
"  `/ossssso+/:-   //   -:/+osssso+-" \
" `+sso+:-`        //       `.-/+oso:" \
"`++:.             //            `-/+/" \
".`                /                `/"
        set i_user 6
        set i_dashes 7
        set i_distro 8
        set i_kernel 9
        set i_uptime 10
        set i_shell 11
        set i_memory 12
        set i_mode 13
        set i_dots 15
    end

    set -l logo_height (count $logo)

    for i in (seq 1 $logo_height)
        set -l raw $logo[$i]
        set -l logo_line "$c1$raw"
        set logo_line (string replace -a '@C1@' "$c1" -- "$logo_line")
        set logo_line (string replace -a '@C2@' "$c2" -- "$logo_line")

        set -l info_line ""
        switch $i
            case $i_user
                set info_line "$title_color$user_host$reset"
            case $i_dashes
                set info_line "$grey"(string repeat -n (string length "$user_host") -)"$reset"
            case $i_distro
                set info_line "$label_color"distro"     $value_color$distro$reset"
            case $i_kernel
                set info_line "$label_color"kernel"     $value_color$kernel$reset"
            case $i_uptime
                set info_line "$label_color"uptime"     $value_color$uptime$reset"
            case $i_shell
                set info_line "$label_color"shell"      $value_color$shell$reset"
            case $i_memory
                set info_line "$label_color"memory"     $value_color$memory$reset"
            case $i_mode
                set info_line "$label_color"mode"       $mode$reset"
            case $i_dots
                set -l dot "●"
                set info_line (string join "" (set_color red) $dot " " (set_color yellow) $dot " " (set_color green) $dot " " (set_color blue) $dot " " (set_color magenta) $dot " " (set_color cyan) $dot " " (set_color white) $dot $reset)
        end

        # Pad by visible width (escape codes must not count toward the column)
        set -l visible (string length -- (string replace -ra "\x1b\[[0-9;]*m" "" "$logo_line"))
        set -l pad (math "$logo_width - $visible")
        if test "$pad" -lt 0
            set pad 0
        end

        if test -n "$info_line"
            printf "%s%s%s%s   %s\n" "$margin" "$logo_line" (string repeat -n $pad " ") "$reset" "$info_line"
        else
            printf "%s%s%s%s\n" "$margin" "$logo_line" (string repeat -n $pad " ") "$reset"
        end
    end

    # Rotating shortcut tip
    set -l tips \
        "Super + E           → Launch Yazi file explorer" \
        "Ctrl + Shift + Esc  → Toggle dedicated Btop system monitor" \
        "Super + Alt + T     → Toggle Scrolling (Niri) / Dwindle layout" \
        "Super + / or F1     → Open full Keybinds Cheatsheet HUD" \
        "Super + M           → Toggle Spotify music workspace" \
        "Super + Alt + N     → Toggle Nightlight (Gamma)" \
        "Super + Alt + W     → Toggle Live Wallpaper" \
        "Super + V           → Open Clipboard History"
    set -l chosen (random choice $tips)
    echo
    set_color cyan
    printf "      💡 Tip: "
    set_color yellow
    echo "$chosen"
    set_color normal
    echo
end
