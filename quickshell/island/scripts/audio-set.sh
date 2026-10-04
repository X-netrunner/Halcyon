#!/usr/bin/env bash
# audio-set.sh sink|source <name>: make it the default, and move what is already playing / recording onto it
kind=$1; name=$2
[ -n "$name" ] || exit 1
if [ "$kind" = "sink" ]; then
  pactl set-default-sink "$name"
  pactl list short sink-inputs 2>/dev/null | cut -f1 | while read -r id; do pactl move-sink-input "$id" "$name" 2>/dev/null; done
else
  pactl set-default-source "$name"
  pactl list short source-outputs 2>/dev/null | cut -f1 | while read -r id; do pactl move-source-output "$id" "$name" 2>/dev/null; done
fi
