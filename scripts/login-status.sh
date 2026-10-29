#!/usr/bin/env bash
# Helper for Halcyon Settings to detect and manage login manager / lock-screen autologin
# Controlled via native helper `hal login-status` (src/hal).
hal="$(dirname "$(readlink -f "$0")")/../bin/hal"; [ -x "$hal" ] || hal="$HOME/.config/Halcyon/bin/hal"
if [ -x "$hal" ]; then
  exec "$hal" login-status "$@"
fi

action="${1:-status}"

case "$action" in
    status)
        mode="console"
        dm="none"
        autologin="false"

        # Check active display manager
        if systemctl is-enabled display-manager.service >/dev/null 2>&1; then
            dm="$(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" .service 2>/dev/null)"
            mode="display-manager"
        else
            for s in sddm gdm gdm3 lightdm greetd ly lxdm cosmic-greeter; do
                if systemctl is-enabled "$s.service" >/dev/null 2>&1; then
                    dm="$s"
                    mode="display-manager"
                    break
                fi
            done
        fi

        # Check tty1 autologin dropin
        if [ -f /etc/systemd/system/getty@tty1.service.d/halcyon-autologin.conf ]; then
            autologin="true"
            mode="lock-screen"
        fi

        printf '{"mode":"%s","dm":"%s","autologin":%s}\n' "$mode" "$dm" "$autologin"
        ;;
    enable-lock)
        rice="${HALCYON_DIR:-$HOME/.config/Halcyon}"
        if [ -x "$rice/install.sh" ]; then
            pkexec bash "$rice/install.sh" --lock-login --no-packages --no-drivers --yes
        fi
        ;;
    remove-lock)
        rice="${HALCYON_DIR:-$HOME/.config/Halcyon}"
        if [ -x "$rice/install.sh" ]; then
            pkexec bash "$rice/install.sh" --remove-lock-login
        fi
        ;;
    *)
        echo "Usage: $0 [status|enable-lock|remove-lock]" >&2
        exit 1
        ;;
esac
