#!/bin/bash
# Fixture (redacted): a scheduled sync the jobs audit must flag.
# The audit's checks live in the engine script (phase two); this file pins
# the lines it has to name: 6 the bare git call, 7 the unbounded log append.
set -u
git fetch --all --prune
echo "$(date '+%Y-%m-%d %H:%M:%S') sync done" >> "$HOME/Library/Logs/sync-repos.log"
