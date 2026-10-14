#!/usr/bin/env bash
# ==============================================================================
# printer.sh : Printer Management Helper for Halcyon
# Supports system-config-printer GUI and CUPS web management
# ==============================================================================
set -euo pipefail

notify() {
    local title="$1" body="$2" icon="${3:-printer}"
    command -v notify-send >/dev/null 2>&1 && notify-send -a "Printer Manager" -i "$icon" "$title" "$body" || true
}

open_cups_web() {
    if ! systemctl is-active --quiet cups.service 2>/dev/null; then
        notify "Starting CUPS..." "Attempting to start local print service." "printer"
        systemctl start cups.service 2>/dev/null || sudo systemctl start cups.service 2>/dev/null || true
    fi
    xdg-open "http://localhost:631/admin" 2>/dev/null || xdg-open "http://localhost:631/" 2>/dev/null || true
}

if command -v system-config-printer >/dev/null 2>&1; then
    # If CUPS isn't running, start it
    if ! systemctl is-active --quiet cups.service 2>/dev/null; then
        systemctl start cups.service 2>/dev/null || true
    fi
    exec system-config-printer "$@"
elif command -v lpstat >/dev/null 2>&1; then
    notify "Opening CUPS Print Manager" "Connecting to localhost:631 in your browser..." "printer"
    open_cups_web
elif systemctl list-unit-files 2>/dev/null | grep -q "cups.service"; then
    notify "Starting CUPS" "Starting cups.service and opening browser manager..." "printer"
    open_cups_web
else
    notify "Printer Tools Needed" "Install CUPS and graphical manager:\nsudo pacman -S cups system-config-printer" "dialog-information"
    echo "To configure printers in Halcyon, install CUPS and the GUI manager:"
    echo "  sudo pacman -S cups system-config-printer cups-pdf"
    echo "  sudo systemctl enable --now cups.service"
fi
