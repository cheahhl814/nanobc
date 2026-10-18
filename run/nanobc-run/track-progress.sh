#!/bin/bash
# track-progress.sh — periodic progress tracker for long local basecalling runs.
#
# Writes one line to a log file at the chosen interval:
#   <time> | RUNNING|FINISHED/STOPPED | <N> of <TOTAL> files done | output size | GPU state
# Stops automatically when the tmux session ends (run finished, success or failure)
# or when the done-file count reaches TOTAL.
#
# Usage:
#   track-progress.sh <tmux_session> <output_dir> <total_files> <log_file> [interval_seconds]
#
# The tracking frequency is the USER'S choice; the default is 7200 s (every 2 hours).
# Examples of common intervals: 3600 = every 1 hour, 1800 = every 30 min, 21600 = every 6 hours.
#
# Examples:
#   LSK run, default 2h:  track-progress.sh basecalling_PR001 /path/outdir/dorado_basecall_lsk 73 /path/runs/PR001/progress.log
#   LSK run, every 1h:    track-progress.sh basecalling_PR001 /path/outdir/dorado_basecall_lsk 73 /path/runs/PR001/progress.log 3600
#   Demux:                track-progress.sh basecalling_PR001 /path/outdir/fastq 0 /path/runs/PR001/progress.log
#
# Launch in background (survives logout/reboot of the chat session):
#   nohup bash track-progress.sh <args...> > /dev/null 2>&1 &

TMUX_SESSION="$1"
OUTDIR="$2"
TOTAL="${3:-0}"
LOG="$4"
INTERVAL="${5:-7200}"   # user-chosen frequency; default every 2 hours

if [ -z "$TMUX_SESSION" ] || [ -z "$OUTDIR" ] || [ -z "$LOG" ]; then
  echo "Usage: track-progress.sh <tmux_session> <output_dir> <total_files> <log_file> [interval_seconds]"
  echo "  interval_seconds: how often to log progress (default 7200 = every 2 hours)"
  exit 1
fi

echo "==== Progress tracker started $(date '+%Y-%m-%d %H:%M') | logging every ${INTERVAL}s ====" >> "$LOG"

while true; do
  done=$(ls "$OUTDIR"/*.fastq.gz 2>/dev/null | wc -l)
  size=$(du -sh "$OUTDIR" 2>/dev/null | cut -f1)
  [ -n "$size" ] || size="-"
  gpu=$(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used --format=csv,noheader 2>/dev/null || echo "nvidia-smi unavailable")

  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    status="RUNNING"
  else
    status="FINISHED/STOPPED"
  fi

  echo "$(date '+%Y-%m-%d %H:%M') | $status | $done of $TOTAL files done | output size: $size | GPU: $gpu" >> "$LOG"

  if [ "$status" = "FINISHED/STOPPED" ]; then
    echo "==== Tracker stopping: run no longer active ====" >> "$LOG"
    break
  fi
  if [ "$TOTAL" -gt 0 ] && [ "$done" -ge "$TOTAL" ]; then
    echo "==== Tracker stopping: all $TOTAL files done ====" >> "$LOG"
    break
  fi

  sleep "$INTERVAL"
done
