#!/usr/bin/env bash
# Fuzzy-searchable cheatsheet of every shortcut, gesture and CLI helper in Halcyon.
# SUPER+ALT+/  |  launcher: ">keybinds"  |  quickshell ipc ... call island cheatsheet
# Pure reference: type to filter, Esc to close. Keep it in sync with hyprland/keybinds.lua,
# hyprland/gestures.lua and variables.lua when you change a bind.

# toggle: pressing the shortcut again closes it
pkill -f 'fuzzel.*--prompt=Keys' 2>/dev/null && exit 0

cat << 'LIST' | fuzzel --dmenu --prompt="Keys > " --lines=18 --width=72
 APPS
󰌌  Super + T                 Terminal (foot)
󰌌  Super + E                 File explorer (yazi)
󰌌  Super + W                 Browser (Firefox)
󰌌  Super + C                 Code editor (Codium)

 WINDOWS
󰌌  Super + Q                 Close window
󰌌  Super + F                 Fullscreen
󰌌  Super + P                 Pin window
󰌌  Super + Alt + Space       Toggle floating
󰌌  Super + Y                 Swap split
󰌌  Super + Alt + T           Toggle layout (dwindle / scrolling)

 WORKSPACES
󰌌  Super + 1..9              Go to workspace
󰌌  Super + Alt + 1..9        Move window to workspace
󰌌  Super + S                 Scratch workspace (overlay)
󰌌  Super + Alt + S           Send window to scratch
󰌌  Super + M                 Music (starts Spotify if nothing is there; ncmpcpp if no Spotify)
󰌌  Ctrl + Shift + Esc        System monitor (btop)
󰌌  Super + D                 Communication (starts Vesktop / Discord if nothing is there)
󰌌  Super + R                 Tasks (Todoist)

 ISLAND
󰌌  Tap Super / Super + Space Launcher: apps, ".", ">" commands, "=" calculator
󰌌  Super + Tab               Live workspace / window tree
󰌌  Super + Alt + /           This cheatsheet
󰌌  Super + Shift + N         Notification centre (or hover the right edge)
󰌌  Super + Shift + D         Do not disturb on / off (or the DND chip in the panel)
󰌌  Super + Shift + Enter     Quick console (hover / click the top-left corner)
󰊖  Super + F10               Gaming mode on / off
󰒓  Super + F11               Rice settings
󰌌  Ctrl + Alt + C            Clear all notifications
󰌌  Click / right-click popup Dismiss it / hide all popups (centre keeps them)
󰌌  Drag bar left / right     Performance page / media page
󰌌  Hover bottom-right corner Wi-Fi, Bluetooth, volume, brightness, power mode, caffeine
󰌌  Hover bottom-left corner  Background apps: what keeps running without a window

 TOGGLES
󰌌  Super + Alt + P           Auto power manager on / off
󰅶  Super + Alt + C           Caffeine on / off (screen stays awake, no idle lock / sleep)
󰀻  Super + Shift + A         Background apps box (Spotify, Discord ... open / quit)
󰌌  Super + Alt + G           Touchpad music gestures on / off
󰌌  Super + Alt + W           Live wallpaper on / off
󰌌  Super + Alt + N           Nightlight on / off
󰌌  Fn + touchpad key         Touchpad on / off

 TOUCHPAD
»  Right edge, slide up/down Volume up / down
»  Top edge, slide right/left Brightness up / down
»  Left edge, flick up/down  Next / previous track
»  3-4 fingers right / left  Next / previous workspace
»  3 fingers up or down      Scratch workspace (again to return)
»  4 fingers down            Sleep
»  2-finger pinch            Workspace tree

 SYSTEM
󰌌  Super + V                 Clipboard history
󰌌  Super + Period            Emoji picker
󰌌  Print                     Screenshot (full)
󰌌  Super + Shift + S         Screenshot area (freeze, save + copy)
󰌌  Super + Shift + Print     Screenshot area (plain, save only)
󰌌  Super + L                 Lock screen
󰌌  Ctrl + Alt + Delete       Session menu

 SYSMODE (terminal, needs sudo)
  sysmode status              Show active profile and key kernel metrics
  sysmode secure              Daily hardening
  sysmode cyber               Relaxed training lab
  sysmode stealth             Decoy / counter-recon lab
  sysmode lockdown            Fortress mode (reboot to exit)
  sysmode verify | doctor     Audit the profile | check dependencies
LIST
