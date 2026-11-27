#!/bin/bash
# a job written with care: everything bounded, logged, guarded
LOG="$HOME/Library/Logs/clean-backup.log"
{
  echo "== clean backup $(date) =="
  timeout 300 rsync -a "$HOME/Documents/" "$HOME/Backup/Documents/"
} >> "$LOG" 2>&1
# keep the log bounded: never more than 5000 lines
tail -5000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
