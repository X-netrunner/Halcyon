#!/usr/bin/env bash
# screen-record.sh: inbuilt on-demand recorder for Halcyon. Runs ONLY when you start it; completely idle otherwise.
#
#   screen-record.sh toggle | start | stop | status
#   screen-record.sh open      open the recordings folder
#   screen-record.sh last      play the newest recording
#   screen-record.sh list      print the recordings (newest first)
#
# Settings > Recording writes three one-line flag files in ~/.local/state/island (read on every start):
#   rec-kind    screen | audio     a screen video, or sound only
#   rec-audio   none | system | mic | both    what sound goes in (system = what you hear, mic = the default microphone)
#   rec-dir     (optional) the folder; default ~/Videos/Recordings
#
# Video comes from wf-recorder / wl-screenrec / gpu-screen-recorder (the first one installed). Sound is recorded next to it by
# ffmpeg (PipeWire / PulseAudio) and joined to the video when you stop, so every combination works with every recorder.

STATE_DIR="$HOME/.local/state/island"
PID_FILE="$STATE_DIR/record.pid"          # the video recorder
APID_FILE="$STATE_DIR/record.apid"        # the ffmpeg sound recorder
OUT_FILE_INFO="$STATE_DIR/record.file"    # the file you will get
VTMP_INFO="$STATE_DIR/record.vtmp"        # video-only file while sound is recorded separately
ATMP_INFO="$STATE_DIR/record.atmp"        # sound-only file
mkdir -p "$STATE_DIR"

flag() { local v; v=$(head -n1 "$STATE_DIR/$1" 2>/dev/null); echo "${v:-$2}"; }
REC_DIR=$(flag rec-dir "$HOME/Videos/Recordings")
REC_DIR="${REC_DIR/#\~/$HOME}"
KIND=$(flag rec-kind screen)
AUDIO=$(flag rec-audio system)
case "$KIND" in screen|audio) ;; *) KIND=screen ;; esac
case "$AUDIO" in none|system|mic|both) ;; *) AUDIO=system ;; esac
[ "$KIND" = audio ] && [ "$AUDIO" = none ] && AUDIO=both      # "audio only" with no sound would record nothing

alive() { [ -f "$1" ] && { local p; p=$(cat "$1" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }; }
is_recording() { alive "$PID_FILE" || alive "$APID_FILE"; }
note() { notify-send -a Halcyon "$@" 2>/dev/null; }

stop_pid() {      # stop_pid <pidfile>: Ctrl+C the recorder so it finishes its file; TERM, then KILL, only if it will not stop
    local p; p=$(cat "$1" 2>/dev/null)
    [ -n "$p" ] || { rm -f "$1"; return 0; }
    local sig
    for sig in INT TERM KILL; do
        kill "-$sig" "$p" 2>/dev/null || break
        for _ in $(seq 1 30); do kill -0 "$p" 2>/dev/null || break 2; sleep 0.1; done
    done
    rm -f "$1"
}

stop_recording() {
    if ! is_recording; then
        rm -f "$PID_FILE" "$APID_FILE" "$OUT_FILE_INFO" "$VTMP_INFO" "$ATMP_INFO"
        echo idle; exit 0
    fi
    local out vtmp atmp
    out=$(cat "$OUT_FILE_INFO" 2>/dev/null); vtmp=$(cat "$VTMP_INFO" 2>/dev/null); atmp=$(cat "$ATMP_INFO" 2>/dev/null)
    stop_pid "$PID_FILE"
    stop_pid "$APID_FILE"
    if [ -n "$vtmp" ] && [ -n "$atmp" ]; then
        # join the picture and the sound (the picture is copied, only the sound is encoded: quick)
        if [ -s "$vtmp" ] && [ -s "$atmp" ]; then
            if ffmpeg -nostdin -loglevel error -y -i "$vtmp" -i "$atmp" -map 0:v:0 -map 1:a:0 -c:v copy -c:a copy -shortest -movflags +faststart "$out" 2>/dev/null && [ -s "$out" ]; then
                rm -f "$vtmp" "$atmp"
            else
                mv -f "$vtmp" "$out"; note -u normal "Recording saved without sound" "Joining the sound failed; the sound is kept as $(basename "$atmp")"
            fi
        elif [ -s "$vtmp" ]; then
            mv -f "$vtmp" "$out"; rm -f "$atmp"
        fi
    fi
    rm -f "$OUT_FILE_INFO" "$VTMP_INFO" "$ATMP_INFO"
    if [ -n "$out" ] && [ -s "$out" ]; then
        note -i video-x-generic -t 4000 "Recording saved" "$(basename "$out")"
    else
        note -t 3000 "Recording stopped" "Nothing was saved."
    fi
    echo stopped; exit 0
}

# ---- sound sources (PipeWire / PulseAudio names)
sys_source() { local s; s=$(pactl get-default-sink 2>/dev/null); [ -n "$s" ] && echo "$s.monitor"; }
mic_source() { pactl get-default-source 2>/dev/null; }

start_sound() {      # start_sound <file>: ffmpeg -> file. Returns 1 if it could not start.
    local file=$1 sys mic args=()
    command -v ffmpeg >/dev/null 2>&1 || return 2
    command -v pactl  >/dev/null 2>&1 || return 3
    sys=$(sys_source); mic=$(mic_source)
    case "$AUDIO" in
        system) [ -n "$sys" ] || return 4; args=(-f pulse -i "$sys") ;;
        mic)    [ -n "$mic" ] || return 4; args=(-f pulse -i "$mic") ;;
        both)   [ -n "$sys" ] && [ -n "$mic" ] || return 4
                args=(-f pulse -i "$sys" -f pulse -i "$mic" -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0[a]" -map "[a]") ;;
    esac
    ffmpeg -nostdin -loglevel error -y "${args[@]}" -ac 2 -c:a aac -b:a 160k "$file" >/dev/null 2>&1 &
    echo $! > "$APID_FILE"
    sleep 0.3
    alive "$APID_FILE" || { rm -f "$APID_FILE" "$file"; return 5; }
}

sound_problem() {
    case "$1" in
        2) echo "ffmpeg is not installed (sudo pacman -S ffmpeg), so there is no sound" ;;
        3) echo "pactl is not installed (sudo pacman -S libpulse), so there is no sound" ;;
        4) echo "No audio device found for '$AUDIO' (is PipeWire running?)" ;;
        *) echo "The sound recorder did not start" ;;
    esac
}

start_recording() {
    mkdir -p "$REC_DIR"
    local ts out base=""
    ts=$(date +%Y-%m-%d_%H-%M-%S)

    # ---------------- sound only
    if [ "$KIND" = audio ]; then
        out="$REC_DIR/audio_${ts}.m4a"
        if start_sound "$out"; then
            echo "$out" > "$OUT_FILE_INFO"
            note -i audio-input-microphone -t 3000 "Audio recording started" "Click Record again or press Super+Alt+R to finish."
            echo recording; return 0
        else
            note -u critical "Audio recorder" "$(sound_problem $?)"
            echo failed; exit 1
        fi
    fi

    # ---------------- screen (+ sound)
    out="$REC_DIR/recording_${ts}.mp4"
    local vout=$out withsound=0 problem=""
    if [ "$AUDIO" != none ]; then
        base="$STATE_DIR/record-${ts}"
        if start_sound "$base.m4a"; then
            withsound=1; vout="$base.mp4"
            echo "$base.m4a" > "$ATMP_INFO"; echo "$vout" > "$VTMP_INFO"
        else
            problem=$(sound_problem $?)
        fi
    fi

    if command -v wf-recorder >/dev/null 2>&1; then
        wf-recorder -f "$vout" --pixel-format yuv420p >/dev/null 2>&1 &
    elif command -v wl-screenrec >/dev/null 2>&1; then
        wl-screenrec -f "$vout" >/dev/null 2>&1 &
    elif command -v gpu-screen-recorder >/dev/null 2>&1; then
        gpu-screen-recorder -w screen -f 60 -o "$vout" >/dev/null 2>&1 &
    else
        stop_pid "$APID_FILE"; rm -f "$ATMP_INFO" "$VTMP_INFO"; [ -n "$base" ] && rm -f "$base.m4a"
        note -u critical "Screen recorder" "Please install wf-recorder: sudo pacman -S wf-recorder"
        echo missing_tool; exit 1
    fi
    echo $! > "$PID_FILE"
    echo "$out" > "$OUT_FILE_INFO"

    sleep 0.3
    if alive "$PID_FILE"; then
        local what="Screen is recording"
        [ "$withsound" = 1 ] && what="Screen and sound ($AUDIO) are recording"
        note -i media-record -t 3500 "Recording started" "$what. Click Record again or press Super+Alt+R to finish."
        [ -n "$problem" ] && note -u normal "Recording without sound" "$problem"
        echo recording
    else
        stop_pid "$APID_FILE"
        rm -f "$PID_FILE" "$OUT_FILE_INFO" "$VTMP_INFO" "$ATMP_INFO"; [ -n "$base" ] && rm -f "$base.m4a"
        note -u critical "Screen recorder" "The recording did not start."
        echo failed; exit 1
    fi
}

newest() { ls -1t "$REC_DIR"/recording_* "$REC_DIR"/audio_* 2>/dev/null | head -n1; }

cmd="${1:-toggle}"
case "$cmd" in
    status) is_recording && echo recording || echo idle ;;
    stop)   stop_recording ;;
    start)  is_recording && echo already_recording || start_recording ;;
    toggle) is_recording && stop_recording || start_recording ;;
    open)   mkdir -p "$REC_DIR"; xdg-open "$REC_DIR" >/dev/null 2>&1 & ;;
    last)   f=$(newest); if [ -n "$f" ]; then xdg-open "$f" >/dev/null 2>&1 & else note -t 3000 "Recordings" "No recordings yet in $REC_DIR"; fi ;;
    list)   ls -1t "$REC_DIR"/recording_* "$REC_DIR"/audio_* 2>/dev/null ;;
    *)      echo "usage: screen-record.sh toggle | start | stop | status | open | last | list" >&2; exit 1 ;;
esac
