#!/usr/bin/env bash
# Print the path of the user's profile picture, or nothing if there is none.
#   $1 = the path chosen in the tree (E on the laptop node); empty = look in the usual places
# Order: chosen path, ~/.face, ~/.face.icon, AccountsService icon, ~/.config/Halcyon/avatar.*, ~/Pictures/avatar.*
expand() { case "$1" in "~"*) printf '%s' "$HOME${1#\~}" ;; *) printf '%s' "$1" ;; esac; }
chosen=$(expand "${1:-}")
for f in "$chosen" "$HOME/.face" "$HOME/.face.icon" "/var/lib/AccountsService/icons/$(id -un)" \
         "$HOME"/.config/Halcyon/avatar.{png,jpg,jpeg,webp} "$HOME"/Pictures/avatar.{png,jpg,jpeg,webp}; do
  [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] && { printf '%s\n' "$f"; exit 0; }
done
exit 0
