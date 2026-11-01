#!/bin/sh
# What this machine offers the login screen, one fact per line:  key <TAB> value.  (read by shell.qml; the root-owned copy lives in
# /usr/local/share/halcyon-greeter.) Only root-owned files are read, never anything in a home folder, so nothing a user can write
# decides what the login screen does.
#
#   fingerprint 1    /etc/pam.d/greetd has a pam_fprintd line (halcyon-greeter.sh fingerprint on). PAM still decides; this only
#                    tells the screen to start the check by itself and to say "touch the reader".
#   layouts us,de    the keyboard layouts cage was started with (XKB_DEFAULT_LAYOUT in /etc/greetd/config.toml)
#   kbtoggle Alt+Shift   the key that switches between them (from XKB_DEFAULT_OPTIONS), when it is one of the usual ones
pam="${HALCYON_PAM_GREETD:-/etc/pam.d/greetd}"
conf="${HALCYON_GREETD_CONF:-/etc/greetd/config.toml}"

if [ -r "$pam" ] && grep -Eq '^[[:space:]]*auth[[:space:]]+[^#]*pam_fprintd\.so' "$pam"; then
  printf 'fingerprint\t1\n'
fi

if [ -r "$conf" ]; then
  cmd=$(sed -n 's/^[[:space:]]*command[[:space:]]*=//p' "$conf" | head -n 1)
  l=$(printf '%s\n' "$cmd" | sed -n 's/.*XKB_DEFAULT_LAYOUT=\([A-Za-z0-9_,-]*\).*/\1/p')
  o=$(printf '%s\n' "$cmd" | sed -n 's/.*XKB_DEFAULT_OPTIONS=\([A-Za-z0-9_:,-]*\).*/\1/p')
  [ -n "$l" ] && printf 'layouts\t%s\n' "$l"
  case ",$o," in
    *,grp:alt_shift_toggle,*)  printf 'kbtoggle\tAlt+Shift\n' ;;
    *,grp:ctrl_shift_toggle,*) printf 'kbtoggle\tCtrl+Shift\n' ;;
    *,grp:alt_space_toggle,*)  printf 'kbtoggle\tAlt+Space\n' ;;
    *,grp:win_space_toggle,*)  printf 'kbtoggle\tSuper+Space\n' ;;
    *,grp:ctrl_alt_toggle,*)   printf 'kbtoggle\tCtrl+Alt\n' ;;
    *,grp:caps_toggle,*)       printf 'kbtoggle\tCaps Lock\n' ;;
  esac
fi
exit 0
