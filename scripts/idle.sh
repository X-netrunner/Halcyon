#!/usr/bin/env bash
# Idle behaviour: lock the screen after a while, sleep after a long while. Both are set in the island's Settings.
# It writes a hypridle config of its own (~/.local/state/island/hypridle.conf) and runs hypridle with it, so your
# own ~/.config/hypr/hypridle.conf is not touched. hypridle honours Caffeine (systemd-inhibit), so a caffeinated
# session never locks or sleeps.
#   idle.sh start             write the config from the saved values and (re)start hypridle   (autostart runs this)
#   idle.sh apply LOCK SLEEP  minutes, 0 = never; restarts hypridle only if something changed
state="$HOME/.local/state/island"; envf="$state/idle.env"; conf="$state/hypridle.conf"
mkdir -p "$state"
IDLE_LOCK=5; IDLE_SLEEP=30
[ -f "$envf" ] && . "$envf"

num() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }

write_conf() {
  local lock sleep_m
  lock=$(num "$IDLE_LOCK" 5); sleep_m=$(num "$IDLE_SLEEP" 30)
  # sleep is counted from when you stop touching the computer, so it has to come after the lock
  if [ "$lock" -gt 0 ] && [ "$sleep_m" -gt 0 ] && [ "$sleep_m" -le "$lock" ]; then sleep_m=$((lock + 1)); fi
  local lockcmd="$HOME/.config/Halcyon/scripts/lock.sh"
  {
    echo "general {"
    echo "    lock_cmd = $lockcmd"
    echo "    before_sleep_cmd = $lockcmd"
    echo "}"
    if [ "$lock" -gt 0 ]; then
      echo; echo "listener {"; echo "    timeout = $((lock * 60))"; echo "    on-timeout = $lockcmd"; echo "}"
    fi
    if [ "$sleep_m" -gt 0 ]; then
      echo; echo "listener {"; echo "    timeout = $((sleep_m * 60))"; echo "    on-timeout = systemctl suspend"; echo "}"
    fi
  } > "$1"
}

restart() {
  command -v hypridle >/dev/null || { echo "hypridle is not installed (pacman -S hypridle)" >&2; exit 1; }
  pkill -x hypridle 2>/dev/null
  sleep 0.3
  setsid nohup hypridle -c "$conf" >/dev/null 2>&1 </dev/null &
}

case "$1" in
  start)
    write_conf "$conf"; restart ;;
  apply)
    IDLE_LOCK=$(num "$2" 5); IDLE_SLEEP=$(num "$3" 30)
    printf 'IDLE_LOCK=%s\nIDLE_SLEEP=%s\n' "$IDLE_LOCK" "$IDLE_SLEEP" > "$envf"
    write_conf "$conf.new"
    if ! cmp -s "$conf" "$conf.new" || ! pgrep -x hypridle >/dev/null; then mv "$conf.new" "$conf"; restart; else rm -f "$conf.new"; fi ;;
  *) echo "usage: idle.sh start | apply LOCK_MIN SLEEP_MIN   (0 = never)" >&2; exit 2 ;;
esac
