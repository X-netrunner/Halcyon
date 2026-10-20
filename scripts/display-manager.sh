#!/usr/bin/env bash
# ==============================================================================================
# display-manager.sh : Multi-Monitor and Projector Presentation Manager for Halcyon / Hyprland
# Supports:
#   - Mirror / Clone Mode (essential for Projectors & Presentations)
#   - Extend Right / Extend Left
#   - External / Projector Only
#   - Laptop Screen Only
#   - Auto Preferred Setup
#
# Keybind: SUPER + P (or run: display-manager.sh menu)
# ==============================================================================================
set -euo pipefail

RICE="${HALCYON_DIR:-$HOME/.config/Halcyon}"
STATE_FILE="$HOME/.local/state/island/display-mode.env"
mkdir -p "$(dirname "$STATE_FILE")"

notify() {
    local title="$1" body="$2" icon="${3:-video-display}"
    command -v notify-send >/dev/null 2>&1 && notify-send -a "Display Manager" -i "$icon" "$title" "$body" || true
}

get_monitors_json() {
    hyprctl monitors all -j 2>/dev/null || echo "[]"
}

# Returns: "INTERNAL_NAME EXTERNAL_NAME"
detect_monitors() {
    local json internal="" external=""
    json="$(get_monitors_json)"

    # Identify internal display (eDP, LVDS, DSI)
    internal=$(echo "$json" | jq -r '.[] | select(.name | test("^(eDP|LVDS|DSI)")) | .name' | head -n1)
    
    # If not found by pattern, use the first monitor
    if [[ -z "$internal" ]]; then
        internal=$(echo "$json" | jq -r '.[0].name // empty')
    fi

    # Identify external displays (HDMI, DP, USB-C, VGA, or anything not internal)
    external=$(echo "$json" | jq -r --arg int "$internal" '.[] | select(.name != $int) | .name' | head -n1)

    echo "$internal $external"
}

apply_mirror() {
    local mons internal external
    mons=($(detect_monitors))
    internal="${mons[0]:-}"
    external="${mons[1]:-}"

    if [[ -z "$external" ]]; then
        notify "No External Display Detected" "Connect an external monitor or projector via HDMI / DisplayPort / USB-C." "dialog-warning"
        return 1
    fi

    # Mirror external to internal display with preferred mode
    hyprctl keyword monitor "$internal,preferred,0x0,1" >/dev/null
    hyprctl keyword monitor "$external,preferred,auto,1,mirror,$internal" >/dev/null

    echo "MODE=mirror" > "$STATE_FILE"
    echo "INTERNAL=$internal" >> "$STATE_FILE"
    echo "EXTERNAL=$external" >> "$STATE_FILE"

    notify "Projector Mirror Mode Active" "Cloning $internal onto $external (Both screens show identical content)." "video-display"
}

apply_extend_right() {
    local mons internal external
    mons=($(detect_monitors))
    internal="${mons[0]:-}"
    external="${mons[1]:-}"

    if [[ -z "$external" ]]; then
        notify "No External Display Detected" "Connect an external monitor or projector first." "dialog-warning"
        return 1
    fi

    hyprctl keyword monitor "$internal,preferred,0x0,1" >/dev/null
    hyprctl keyword monitor "$external,preferred,auto-right,1" >/dev/null

    echo "MODE=extend-right" > "$STATE_FILE"
    notify "Extended Display (Right)" "Extended workspace with $external on the right." "video-display"
}

apply_extend_left() {
    local mons internal external
    mons=($(detect_monitors))
    internal="${mons[0]:-}"
    external="${mons[1]:-}"

    if [[ -z "$external" ]]; then
        notify "No External Display Detected" "Connect an external monitor or projector first." "dialog-warning"
        return 1
    fi

    hyprctl keyword monitor "$external,preferred,0x0,1" >/dev/null
    hyprctl keyword monitor "$internal,preferred,auto-right,1" >/dev/null

    echo "MODE=extend-left" > "$STATE_FILE"
    notify "Extended Display (Left)" "Extended workspace with $external on the left." "video-display"
}

apply_external_only() {
    local mons internal external
    mons=($(detect_monitors))
    internal="${mons[0]:-}"
    external="${mons[1]:-}"

    if [[ -z "$external" ]]; then
        notify "No External Display Detected" "Cannot turn off laptop screen without an active external display." "dialog-error"
        return 1
    fi

    hyprctl keyword monitor "$internal,disable" >/dev/null
    hyprctl keyword monitor "$external,preferred,0x0,1" >/dev/null

    echo "MODE=external-only" > "$STATE_FILE"
    notify "Presentation Only (External)" "Laptop screen disabled. Displaying exclusively on $external." "video-display"
}

apply_internal_only() {
    local mons internal external
    mons=($(detect_monitors))
    internal="${mons[0]:-}"
    external="${mons[1]:-}"

    hyprctl keyword monitor "$internal,preferred,0x0,1" >/dev/null
    if [[ -n "$external" ]]; then
        hyprctl keyword monitor "$external,disable" >/dev/null
    fi

    echo "MODE=internal-only" > "$STATE_FILE"
    notify "Laptop Screen Only" "External display $external disabled. Output on $internal." "video-display"
}

apply_auto() {
    hyprctl keyword monitor ",preferred,auto,1" >/dev/null
    echo "MODE=auto" > "$STATE_FILE"
    notify "Displays Reset" "All connected displays set to auto-detect preferred layout." "video-display"
}

show_status() {
    local json mons internal external
    json="$(get_monitors_json)"
    mons=($(detect_monitors))
    internal="${mons[0]:-none}"
    external="${mons[1]:-none}"

    echo "================================================="
    echo "         Halcyon Display & Projector Status      "
    echo "================================================="
    echo "• Primary (Internal): $internal"
    echo "• Secondary (External): $external"
    echo ""
    echo "Active Monitors:"
    echo "$json" | jq -r '.[] | "  - \(.name) (\(.width)x\(.height)@\(.refreshRate | round)Hz) scale:\(.scale) pos:\(.x),\(.y) [\(if .disabled then "DISABLED" elif .mirrorOf != "none" then "MIRROR of \(.mirrorOf)" else "ACTIVE" end)]"'
    echo "================================================="
}

show_menu() {
    # If quickshell island is running, open the Halcyon native DisplayPicker
    if command -v quickshell >/dev/null 2>&1; then
        if quickshell ipc -p "${RICE}/quickshell/island" call island display 2>/dev/null; then
            exit 0
        fi
    fi

    local mons internal external choices choice
    mons=($(detect_monitors))
    internal="${mons[0]:-Laptop}"
    external="${mons[1]:-}"

    if [[ -z "$external" ]]; then
        choices="Laptop Only (No external monitor detected)\nReset / Auto-Detect Displays"
    else
        choices="Mirror Screen (Clone to Projector/TV: $external)\nExtend Right ($external on Right)\nExtend Left ($external on Left)\nProjector Only ($external Main, Laptop Off)\nLaptop Screen Only (Turn Off $external)\nReset to Auto Defaults"
    fi

    if command -v fuzzel >/dev/null 2>&1; then
        choice=$(echo -e "$choices" | fuzzel --dmenu --prompt="Display Mode > " -w 45 -l 7 -p "Select Mode: ") || exit 0
    elif command -v zenity >/dev/null 2>&1; then
        choice=$(echo -e "$choices" | zenity --list --column="Display Mode" --title="Halcyon Display & Projector Manager" --width=450 --height=320) || exit 0
    else
        show_status
        return
    fi

    case "$choice" in
        *"Mirror"*)         apply_mirror ;;
        *"Extend Right"*)   apply_extend_right ;;
        *"Extend Left"*)    apply_extend_left ;;
        *"Projector Only"*) apply_external_only ;;
        *"Laptop Screen"*)  apply_internal_only ;;
        *"Reset"*)          apply_auto ;;
    esac
}

case "${1:-menu}" in
    mirror)         apply_mirror ;;
    extend-right)   apply_extend_right ;;
    extend-left)    apply_extend_left ;;
    external-only)  apply_external_only ;;
    internal-only)  apply_internal_only ;;
    auto)           apply_auto ;;
    status)         show_status ;;
    menu)           show_menu ;;
    *)
        echo "Usage: $0 {menu|mirror|extend-right|extend-left|external-only|internal-only|auto|status}"
        exit 1
        ;;
esac
