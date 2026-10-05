#!/usr/bin/env bash
# Idle behaviour: dim the screen (and switch the keyboard light off) after a while, lock after a while, sleep after a long while.
# All three are set in the island's Settings > Sleep & lock. Dimming goes to the lowest screen brightness and puts everything
# back the moment you touch the computer again (scripts/idle-dim.sh).
# It writes a hypridle config of its own (~/.local/state/island/hypridle.conf) and runs hypridle with it, so your
# own ~/.config/hypr/hypridle.conf is not touched. hypridle honours Caffeine (systemd-inhibit), so a caffeinated
# session never locks or sleeps.
#   idle.sh start             write the config from the saved values and (re)start hypridle   (autostart runs this)
#   idle.sh apply LOCK SLEEP [DIM]  minutes, 0 = never; restarts hypridle only if something changed
state="$HOME/.local/state/island"; envf="$state/idle.env"; conf="$state/hypridle.conf"
mkdir -p "$state"
IDLE_LOCK=5; IDLE_SLEEP=30; IDLE_DIM=3
[ -f "$envf" ] && . "$envf"

num() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }

write_conf() {
  local lock sleep_m dim
  lock=$(num "$IDLE_LOCK" 5); sleep_m=$(num "$IDLE_SLEEP" 30); dim=$(num "$IDLE_DIM" 3)
  # sleep is counted from when you stop touching the computer, so it has to come after the lock
  if [ "$lock" -gt 0 ] && [ "$sleep_m" -gt 0 ] && [ "$sleep_m" -le "$lock" ]; then sleep_m=$((lock + 1)); fi
  local lockcmd="$HOME/.config/Halcyon/scripts/lock.sh"
  {
    echo "general {"
    echo "    lock_cmd = $lockcmd"
    echo "    before_sleep_cmd = $lockcmd"
    echo "}"
    if [ "$dim" -gt 0 ]; then
      echo; echo "listener {"; echo "    timeout = $((dim * 60))"
      echo "    on-timeout = $HOME/.config/Halcyon/scripts/idle-dim.sh dim"
      echo "    on-resume = $HOME/.config/Halcyon/scripts/idle-dim.sh undim"; echo "}"
    fi
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
    IDLE_LOCK=$(num "$2" 5); IDLE_SLEEP=$(num "$3" 30); IDLE_DIM=$(num "$4" "${IDLE_DIM:-3}")
    printf 'IDLE_LOCK=%s\nIDLE_SLEEP=%s\nIDLE_DIM=%s\n' "$IDLE_LOCK" "$IDLE_SLEEP" "$IDLE_DIM" > "$envf"
    write_conf "$conf.new"
    if ! cmp -s "$conf" "$conf.new" || ! pgrep -x hypridle >/dev/null; then mv "$conf.new" "$conf"; restart; else rm -f "$conf.new"; fi ;;
  *) echo "usage: idle.sh start | apply LOCK_MIN SLEEP_MIN [DIM_MIN]   (0 = never)" >&2; exit 2 ;;
esac
