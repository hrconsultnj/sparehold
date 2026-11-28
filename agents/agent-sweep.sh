#!/usr/bin/env bash
# agent-sweep.sh — the agent inventory: what is on this Mac right now, read-only
# ---------------------------------------------------------------------------
# Purpose: one on-demand sweep that answers "what is running, and what is it
# working with" — the installed coding-agent CLIs (lib/coding-agents.tsv, the
# ONE list), the live sessions (the same exemption walk the Memory Guard
# uses), this Mac's headroom (the file the guard overwrites every tick), and
# the git worktrees under the Guardian's roots. The companion of the Cache
# Guardian (the before) and the Agent Diagnostic (the after): this is the
# DURING — what an agent or a person checks before spawning more work.
# The Ask agent reads the JSON through its readAgents capability; nothing in
# it is a decision Sparehold makes.
#
#   ./agent-sweep.sh            # write reports/agents/inventory.json
#   ./agent-sweep.sh --dry-run  # print the plan, write nothing
#
# READ-ONLY: it runs `command -v`, `git worktree list --porcelain`,
# `du -sk` on the worktrees it names, and reads the guard's own records. It
# never edits, stops, signals or deletes anything, and it never runs an
# agent binary — a CLI's presence is checked with command -v, never executed
# for a version banner. Its only write is its own inventory.json.
#
# JSON is written with printf (bash 3.2, no jq assumed): one object whose
# sections the app's AgentInventory parser names — agents, sessions,
# headroom, worktrees. Paths and commands are stripped of the two characters
# JSON cannot hold (a backslash and a double quote) rather than escaped.
#
# Runs under bash and /bin/bash (3.2).

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
_sparehold_paths="$(cd "$HERE/.." && pwd)/lib/paths.sh"
# shellcheck source=../lib/paths.sh
[[ -f "$_sparehold_paths" ]] && source "$_sparehold_paths"
SPAREHOLD_USER_ROOT="$(sparehold_user_root)"
ANALYZERS_ROOT="$(cd "$HERE/.." && pwd)"
[[ -f "${ANALYZERS_ROOT}/config.local.sh" ]] && source "${ANALYZERS_ROOT}/config.local.sh"
sparehold_apply_paths 2>/dev/null || true
# shellcheck source=../lib/live-sessions.sh
[[ -f "${ANALYZERS_ROOT}/lib/live-sessions.sh" ]] && source "${ANALYZERS_ROOT}/lib/live-sessions.sh"

OUT_DIR="${SPAREHOLD_USER_ROOT}/reports/agents"
OUT_FILE="${OUT_DIR}/inventory.json"
HEADROOM_FILE="${SPAREHOLD_USER_ROOT}/reports/memory/headroom.status"
GUARD_SEEN="${SPAREHOLD_USER_ROOT}/reports/storage/guardian-seen.tsv"
# the same roots the Guardian sweeps (its --roots default; GUARDIAN_ROOTS in
# config.local.sh says so in one line, so the two tools never drift apart)
ROOTS="${GUARDIAN_ROOTS:-${HOME}/Projects}"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# json_text: a string that can go inside JSON quotes — the two characters JSON
# cannot hold raw are dropped, not escaped (a path with a quote loses the quote)
json_text() { printf '%s' "$1" | tr -d '"\\'; }

# --- the plan ----------------------------------------------------------------
plan() {
  echo "== agent sweep — plan =="
  echo "agent list: ${ANALYZERS_ROOT}/lib/coding-agents.tsv"
  echo "headroom file: ${HEADROOM_FILE} $([[ -r "$HEADROOM_FILE" ]] && echo readable || echo absent)"
  echo "guardian worktree record: ${GUARD_SEEN} $([[ -r "$GUARD_SEEN" ]] && echo readable || echo absent)"
  echo "worktree roots: ${ROOTS} $([[ -d "${ROOTS%% *}" ]] && echo exists || echo absent)"
  echo "output would be: ${OUT_FILE}"
}
if [[ "$DRY_RUN" == "1" ]]; then plan; exit 0; fi

mkdir -p "$OUT_DIR" || { echo "agent-sweep: could not create ${OUT_DIR}" >&2; exit 1; }

# --- agents: which of the ONE list are installed ------------------------------
AGENTS_JSON=""
# the list's columns are: agent <TAB> kind <TAB> text
while IFS=$'\t' read -r name kind pattern _rest; do
  [[ "$kind" =~ ^(exe|fragment|interpreter|container)$ ]] || continue
  [[ -n "$pattern" && "$pattern" != "#" ]] || continue
  found=""
  if [[ "$kind" == "exe" ]]; then
    found="$(command -v -- "$pattern" 2>/dev/null)"
  elif [[ "$kind" == "container" ]]; then
    # a container agent is present when its image is on the machine — a read
    # of docker's own list, never a run of the agent
    if command -v docker >/dev/null 2>&1; then
      docker image list --format '{{.Repository}}' 2>/dev/null | grep -qx "$pattern" && found="docker image $pattern"
    fi
  else
    # fragment/interpreter: presence is the ps table's job (a session below);
    # "installed" is not claimed from a fragment — unknown, never a guess
    found=""
  fi
  [[ -n "$found" ]] || continue
  entry="{\"name\": \"$(json_text "${name:-$pattern}")\", \"kind\": \"$kind\", \"path\": \"$(json_text "$found")\"}"
  AGENTS_JSON="${AGENTS_JSON:+${AGENTS_JSON}, }${entry}"
done < "${ANALYZERS_ROOT}/lib/coding-agents.tsv"

# --- sessions: the same walk the Memory Guard's exemption uses ----------------
SESSIONS_JSON=""
SESSION_COUNT=0
if command -v live_session_roots >/dev/null 2>&1; then
  roots="$(live_session_roots)"
  for pid in $roots; do
    args="$(ps -p "$pid" -o args= 2>/dev/null | head -1)"
    [[ -n "$args" ]] || continue
    SESSION_COUNT=$((SESSION_COUNT + 1))
    entry="{\"pid\": $pid, \"command\": \"$(json_text "${args:0:120}")\"}"
    SESSIONS_JSON="${SESSIONS_JSON:+${SESSIONS_JSON}, }${entry}"
  done
fi

# --- headroom: the guard's file, folded in verbatim with a staleness flag -----
HEADROOM_JSON=""
HEADROOM_STALE="unknown"
if [[ -r "$HEADROOM_FILE" ]]; then
  disk="$(sed -n 's/^disk_free_gb: //p' "$HEADROOM_FILE" | head -1)"
  swap="$(sed -n 's/^swap_used_mb: //p' "$HEADROOM_FILE" | head -1)"
  pressure="$(sed -n 's/^pressure: //p' "$HEADROOM_FILE" | head -1)"
  wired="$(sed -n 's/^wired_mb: //p' "$HEADROOM_FILE" | head -1)"
  comp="$(sed -n 's/^compressed_mb: //p' "$HEADROOM_FILE" | head -1)"
  updated="$(sed -n 's/^updated: //p' "$HEADROOM_FILE" | head -1)"
  # stale = the guard has not ticked for over two minutes (its own cadence is 15s):
  # an agent reading a stale file is reading history, and the JSON says so
  iso_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$(printf '%s' "$updated" | sed -E 's/([+-][0-9]{2}):([0-9]{2})$/\1\2/')" "+%s" 2>/dev/null)"
  now="$(date +%s)"
  if [[ -n "$iso_epoch" && -n "$now" ]]; then
    age=$((now - iso_epoch))
    [[ "$age" -le 120 ]] && HEADROOM_STALE="false" || HEADROOM_STALE="true"
  fi
  HEADROOM_JSON=", \"headroom\": {\"disk_free_gb\": ${disk:-null}, \"swap_used_mb\": ${swap:-null}, \"wired_mb\": ${wired:-null}, \"compressed_mb\": ${comp:-null}, \"pressure\": ${pressure:-null}, \"updated\": \"$(json_text "$updated")\", \"stale\": $HEADROOM_STALE}"
fi

# --- worktrees: the Guardian's roots and walk, read-only ----------------------
# the same find the Guardian runs (node_modules pruned, .git directories one
# per repo) so the two tools never discover different sets
WT_JSON=""
for root in $ROOTS; do
  [[ -d "$root" ]] || continue
  while IFS= read -r gitdir; do
    repo="$(dirname "$gitdir")"
    wt=""; br=""
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) wt="${line#worktree }" ;;
        "branch "*) br="${line#branch refs/heads/}" ;;
        "")
          [[ -n "$wt" && ! "$wt" -ef "$repo" ]] || { wt=""; br=""; continue; }
          [[ -d "$wt" ]] || { wt=""; br=""; continue; }
          kb="$(du -sk "$wt" 2>/dev/null | awk '{print $1}')"; kb="${kb:-0}"
          merged=""
          if [[ -n "$br" ]]; then
            git -C "$wt" merge-base --is-ancestor "$br" main >/dev/null 2>&1 && merged="true" || merged="false"
          fi
          entry="{\"path\": \"$(json_text "$wt")\", \"branch\": \"$(json_text "${br:-detached}")\", \"kb\": $kb, \"merged_to_main\": ${merged:-null}}"
          WT_JSON="${WT_JSON:+${WT_JSON}, }${entry}"
          wt=""; br="" ;;
      esac
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null; echo "")
  done < <(find "$root" \( -name node_modules \) -prune -o -type d -name .git -prune -print 2>/dev/null)
done

# --- write the inventory (one printf, the app's parser names the sections) ----
printf '{\n  "swept_at": "%s",\n  "agents": [%s],\n  "session_count": %s,\n  "sessions": [%s]%s,\n  "worktrees": [%s]\n}\n' \
  "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
  "$AGENTS_JSON" \
  "$SESSION_COUNT" \
  "$SESSIONS_JSON" \
  "$HEADROOM_JSON" \
  "$WT_JSON" > "${OUT_FILE}.tmp" 2>/dev/null || { echo "agent-sweep: could not write ${OUT_FILE}.tmp" >&2; exit 1; }
mv "${OUT_FILE}.tmp" "$OUT_FILE" || { echo "agent-sweep: could not move the inventory into place" >&2; exit 1; }
echo "agent-sweep: wrote ${OUT_FILE}"
