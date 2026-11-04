#!/usr/bin/env bash
# halcyon-leak-watch.sh : find out WHAT grows while the desktop sits idle.
#   scripts/halcyon-leak-watch.sh [minutes=30] [every_seconds=60]      (leave the desktop alone while it runs)
# Every sample it records: zombies, the number of processes per program name, and for the biggest processes their PSS, anonymous
# (heap) memory, open files and threads. At the end it prints what GREW. Log: ~/.cache/island/leak-watch.log
#   zombies growing           -> some parent never reaps its children (the parent is listed)
#   process count growing     -> something starts a new copy every time (a clone / a leaked child)
#   one process' anon growing -> that process leaks (quickshell = QML / JS data, hx / cava = their own)
#   open files growing        -> a file / pipe is opened and never closed
mins=${1:-30}; every=${2:-60}; [ "$every" -ge 1 ] 2>/dev/null || every=60
log="$HOME/.cache/island/leak-watch.log"; mkdir -p "$(dirname "$log")"; : > "$log"
n=$(( mins * 60 / every )); [ "$n" -ge 2 ] || n=2
echo "sampling every ${every}s for ${mins} min (${n} samples). Log: $log"
sample() {
  local ts; ts=$(date +%s)
  echo "T $ts"
  echo "Z $(ps -eo stat= | grep -c '^Z')"
  ps -eo comm= | sort | uniq -c | awk '{print "C " $2 " " $1}'
  # every program that runs 2+ copies: who is each copy's parent? (D name|pid|ppid|parent name|age in s). A parent that is systemd / init
  # means the copy is an ORPHAN: whatever started it exited and left it running (that is how a leak of helper processes looks)
  ps -eo pid=,ppid=,etimes=,comm= | awk '{ pid=$1; pp=$2; et=$3; $1=$2=$3=""; sub(/^ +/, ""); c[pid]=$0; n[$0]++; P[pid]=pp; E[pid]=et }
    END { for (p in c) if (n[c[p]] >= 2 && c[p] !~ /^(kworker|ksoftirqd|migration|rcu_|cpuhp|irq\/|idle_inject|kcompactd)/)
      print "D " c[p] "|" p "|" P[p] "|" ((P[p] in c) ? c[P[p]] : "?") "|" E[p] }'
  for pid in $(ps -eo pid= --sort=-rss | head -n 12); do
    [ -r /proc/$pid/smaps_rollup ] || continue
    local comm pss anon fds thr
    comm=$(cat /proc/$pid/comm 2>/dev/null); [ -n "$comm" ] || continue
    pss=$(awk '/^Pss:/{s=$2} END{print int(s)}' /proc/$pid/smaps_rollup 2>/dev/null)
    anon=$(awk '/^Anonymous:/{s=$2} END{print int(s)}' /proc/$pid/smaps_rollup 2>/dev/null)
    fds=$(ls /proc/$pid/fd 2>/dev/null | wc -l)
    thr=$(awk '/^Threads:/{print $2}' /proc/$pid/status 2>/dev/null)
    echo "P $comm $pid $pss $anon $fds $thr"
  done
  echo "M $(awk '/^MemAvailable:/{print int($2)}' /proc/meminfo)"
  echo "E"
}
for ((i = 0; i < n; i++)); do sample >> "$log"; [ $i -lt $((n-1)) ] && sleep "$every"; done
echo; echo "================ what changed (first sample -> last sample) ================"
awk '
  $1=="T" { s++; next }
  $1=="Z" { if (s==1) z0=$2; zl=$2; next }
  $1=="M" { if (s==1) m0=$2; ml=$2; next }
  $1=="C" { if (s==1) c0[$2]=$3; cl[$2]=$3; seen[$2]=1; next }
  $1=="P" { k=$2" "$3; if (s==1) { p0[k]=$4; a0[k]=$5; f0[k]=$6; t0[k]=$7 } pl[k]=$4; al[k]=$5; fl[k]=$6; tl[k]=$7; ps[k]=1; next }
  END {
    printf "free RAM (MemAvailable): %.0f MB -> %.0f MB   (%+.0f MB)\n", m0/1024, ml/1024, (ml-m0)/1024
    printf "zombies: %d -> %d\n", z0, zl
    print "\nprocess names whose COUNT grew:"
    any=0; for (k in seen) if (cl[k]-c0[k] > 0) { printf "  %-24s %d -> %d\n", k, c0[k], cl[k]; any=1 }
    if (!any) print "  none"
    print "\nbiggest processes (PSS MB, anonymous MB, open files, threads), by growth:"
    for (k in ps) if (k in p0) printf "%8.1f MB PSS  %+8.1f MB anon  fds %d -> %d  threads %d -> %d   %s\n", (pl[k]-p0[k])/1024, (al[k]-a0[k])/1024, f0[k], fl[k], t0[k], tl[k], k | "sort -rn"
  }' "$log"
echo; echo "zombies right now (state, parent pid, pid, name, parent name):"
ps -eo stat=,ppid=,pid=,comm= | awk '$1 ~ /^Z/ {print}' | while read -r st pp pid cm; do echo "  $st $pp $pid $cm  (parent: $(cat /proc/$pp/comm 2>/dev/null))"; done
