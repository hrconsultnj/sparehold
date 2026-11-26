#!/usr/bin/env bash
# guardian.sh — the Agent Cache Guardian: what coding agents left behind, reviewed before anything moves
# ---------------------------------------------------------------------------
# Purpose: one on-demand sweep that finds agent-era storage — git worktrees
# whose branch is already merged, duplicated dependency caches, oversized
# package stores, and Sparehold's own old reports — and REMOVES only what a
# person reviewed row by row in the app (preview -> ticks -> apply). The
# scheduled deep clean never removes a checkout (worktree-safety-test.sh);
# this script is the one place removal exists, and it never runs on a
# schedule.
#
#   * A worktree is offered only when ALL of these hold: it is a linked
#     worktree (a .git FILE, never a primary checkout), not a non-main branch
#     inside a folder named main, not locked, not prunable, idle N days, a
#     clean tree, not a runtime root, no live coding session sitting in it, not
#     on the protect list, and its branch/SHA is merged into the repo's
#     main/integration branch — or, for the `main` release worktree itself,
#     `origin/main` exists, `HEAD == origin/main`, and no pending package
#     publish marker exists. Its
#     uncommitted work — if any appears between the preview and the apply —
#     is re-checked and the worktree is left alone: the Guardian never parks
#     a tree that changed since its review (tracked or ignored), because a
#     changed tree is not the one the person reviewed. (No refs/parked pin is ever
#     created here, so the ledger's "Parked changes" column stays empty for
#     Guardian rows; the column is the older deep clean's.)
#   * Local-only files that remain in a clean worktree (gitignored .env
#     copies, settings, notes — never rebuildable output by name) are copied
#     with ditto to reports/storage/parked-worktrees/<date>/<repo>/<name>
#     BEFORE the checkout goes, and every removal appends one row to
#     reports/storage/worktree-removals.md — the six-column ledger whose
#     Restore cell brings the worktree back exactly as it was. The row is
#     appended BEFORE `git worktree remove` so a crash can never lose the
#     receipt; a row whose worktree still exists is harmless.
#   * The branch is never deleted; the commits are never touched.
#   * Package stores are sized (pnpm store, npm cache, sccache, cargo
#     registry) and pruned with the engine's reviewed prune:pnpm / prune:npm
#     keys, worded exactly as storage-auto-clean.sh §3. Global-store
#     guidance (a project-local pnpm store-dir, SCCACHE_BASEDIRS, a shared
#     CARGO_TARGET_DIR) is printed as advice and is never an action: the app
#     never edits a person's tool configs.
#   * Dated report dirs (reports/{memory,storage}/<date>/ and
#     reports/storage/parked-worktrees/<date>/) older than their retention
#     age are offered; latest.md, worktree-removals.md, the plain .log files
#     and lock files are never candidates.
#
# SAFE BY DEFAULT: dry-run unless --apply is passed WITH a reviewed
# --only-paths list. The Guardian refuses to act on anything the app's review
# did not name. A macOS notification summarises every run.
#
# Usage:
#   ./storage/guardian.sh                          # preview (dry run)
#   ./storage/guardian.sh --apply --only-paths <file>   # act ONLY on the reviewed list
#   ./storage/guardian.sh --worktree-idle-days N --parked-days N --reports-days N --roots "dir1 dir2"
#
# Log-line contract with the app's GuardianReview parser (AnalyzersKit):
#   banner:  guardian.sh | mode=guardian idle=N parked=N reports=N | DRY RUN|APPLY | <date>
#   row:     [DRY|DELETED|FAILED]  <human size>  worktree  <path>  <repo>  <detail>
#            [DRY|DELETED|FAILED]  <human size>  retention  <path>  <detail>
#            (fields after the marker are separated by two spaces)
#   prunes:  [DRY]     prune:pnpm  ...   (exactly storage-auto-clean.sh §3's shapes)
#   kept:    (left alone: <path> — <reason>) / (kept: <path> — <reason>)
#            / (stale record: <path> — its folder is gone; git worktree prune clears it)
#   census:  info:<key>  <sentence>          guidance: guide:<key>  <sentence>
#   stores:  store:<id>  <human size>  <path>
# ---------------------------------------------------------------------------

set -u
_sparehold_paths="$(cd "$(dirname "$0")/.." && pwd)/lib/paths.sh"
[[ -f "$(dirname "$0")/paths.sh" ]] && _sparehold_paths="$(cd "$(dirname "$0")" && pwd)/paths.sh"
# The helper path is chosen at runtime. shellcheck follows the suite copy.
# shellcheck source=../lib/paths.sh
if [[ -f "$_sparehold_paths" ]]; then
  source "$_sparehold_paths"
fi
SPAREHOLD_USER_ROOT="$(sparehold_user_root)"
shopt -s nullglob

# ---------- defaults ----------
HOME_DIR="${HOME}"
DRY_RUN=1
ONLY_PATHS=""
WORKTREE_IDLE_DAYS=14        # a worktree must be idle this many days to be offered
PARKED_DAYS=30               # parked local-only files may go once they are this old
REPORTS_DAYS=90              # dated report dirs may go once they are this old
ROOTS="${HOME_DIR}/Projects"
LOG_DIR="${SPAREHOLD_USER_ROOT}/reports/storage"

# optional per-machine config (gitignored) — same load order as storage-auto-clean.sh
ANALYZERS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Settings live in the user folder. When the engine runs from inside the
# app bundle, that bundle is replaced wholesale on every update, so the
# user copy is the one that must win.
[[ -f "${ANALYZERS_ROOT}/config.local.sh" ]] && source "${ANALYZERS_ROOT}/config.local.sh"
# shellcheck source=../lib/paths.sh
source "${ANALYZERS_ROOT}/lib/paths.sh"
sparehold_apply_paths
LOG_FILE="${LOG_DIR}/guardian.log"
LOCK_FILE="${LOG_DIR}/.guardian.lock"
REPORTS_ROOT="${SPAREHOLD_USER_ROOT}/reports"
PARK_ROOT="${REPORTS_ROOT}/storage/parked-worktrees"
WT_MANIFEST="${REPORTS_ROOT}/storage/worktree-removals.md"

# ---------- args ----------
ORIG_ARGS="$*"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)              DRY_RUN=0 ;;
    --dry-run)            DRY_RUN=1 ;;
    --worktree-idle-days) WORKTREE_IDLE_DAYS="${2:-14}"; shift ;;
    --parked-days)        PARKED_DAYS="${2:-30}"; shift ;;
    --reports-days)       REPORTS_DAYS="${2:-90}"; shift ;;
    --roots)              ROOTS="${2:-}"; shift ;;
    --only-paths)         ONLY_PATHS="${2:-}"; shift ;;
    -h|--help)            sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# The Guardian removes checkouts: an apply with no reviewed list would repeat
# the October 2026 unattended deep clean. Only the app's review builds one.
if [[ "$DRY_RUN" -eq 0 && -z "$ONLY_PATHS" ]]; then
  echo "guardian: --apply needs a reviewed --only-paths list (the app's Cache Guardian review writes one)." >&2
  exit 78
fi

# ---------- interactive menu (bare terminal run) ----------
# Preview only: removal is a reviewed, app-only act (the review writes the
# --only-paths list an apply is allowed to act on).
INTERACTIVE=0
INVOKED="flags: ${ORIG_ARGS:-(none — defaults)}"
if [[ -z "$ORIG_ARGS" ]] && { [[ -t 0 ]] || [[ "${FORCE_INTERACTIVE:-0}" == "1" ]]; }; then
  INTERACTIVE=1
  echo ""
  echo "  guardian — the Agent Cache Guardian"
  echo "  ------------------------------------"
  echo "  1) Preview what agents left behind (merged worktrees, package stores, old reports)"
  echo "  q) Quit"
  echo ""
  read -rp "  Choose [1]: " choice
  case "${choice:-1}" in
    1) ;;
    q|Q) exit 0 ;;
    *) echo "  Unknown choice '${choice}' — exiting."; exit 2 ;;
  esac
  INVOKED="interactive menu: choice ${choice:-1}"
fi

mkdir -p "$LOG_DIR" "$PARK_ROOT"

# ---------- single-instance lock ----------
if [[ -e "$LOCK_FILE" ]]; then
  if kill -0 "$(cat "$LOCK_FILE" 2>/dev/null)" 2>/dev/null; then
    echo "guardian already running (pid $(cat "$LOCK_FILE")); exiting." >&2
    exit 0
  fi
fi
echo "$$" > "$LOCK_FILE"
REPOS_FILE="$(mktemp -t guardian-repos)"
WT_CANDIDATES="$(mktemp -t guardian-wt)"
SEEN_FILE="$REPORTS_ROOT/storage/guardian-seen.tsv"   # worktree<TAB>seen-sha: the preview's fingerprint of the tree's whole visible state   # worktree<TAB>repo<TAB>branch<TAB>base<TAB>sha<TAB>kb<TAB>depn<TAB>depKB<TAB>seen-sha
LIVE_CWDS_FILE=""
cleanup_tmp() {
  rm -f "$LOCK_FILE" ${RUNTIME_ROOTS_FILE:+"$RUNTIME_ROOTS_FILE"} \
        ${REPOS_FILE:+"$REPOS_FILE"} ${LIVE_CWDS_FILE:+"$LIVE_CWDS_FILE"} \
        ${WT_CANDIDATES:+"$WT_CANDIDATES"}
}
trap cleanup_tmp EXIT

# ---------- helpers ----------
TOTAL_KB=0
WT_OFFERED=0; WT_REMOVED=0; WT_KEPT=0; WT_MAIN=0; WT_STALE=0; WT_DIRTY=0
RET_OFFERED=0; RET_REMOVED=0
TS_NOW="$(date '+%Y-%m-%d %H:%M:%S')"

human() {  # KB -> human
  awk -v kb="$1" 'BEGIN{
    if (kb>=1048576) printf "%.1f GB", kb/1048576;
    else if (kb>=1024) printf "%.0f MB", kb/1024;
    else printf "%d KB", kb }'
}

log() { echo "$*" | tee -a "$LOG_FILE"; }

# shared notifier — with alerter installed, clicking the notification opens
# this script's log (see lib/notify.sh); inline fallback keeps it standalone.
if [[ -f "${ANALYZERS_ROOT}/lib/notify.sh" ]]; then
  # shellcheck source=../lib/notify.sh
  source "${ANALYZERS_ROOT}/lib/notify.sh"
else
  notify() {  # title, message  (no-op if osascript missing / headless)
    command -v osascript >/dev/null 2>&1 || return 0
    osascript -e "display notification \"${2//\"/\'}\" with title \"${1//\"/\'}\" sound name \"Glass\"" >/dev/null 2>&1 || true
  }
fi

group() { log ""; log "### $1"; }

# --only-paths <file>: act ONLY on paths listed in the file, one per line.
# The sweep still derives its own findings from scratch — an approved set can
# only ever SHRINK what gets touched. A list that went stale between the
# preview and the apply is therefore safe by construction.
approved() {
  [[ -z "${ONLY_PATHS}" ]] && return 0
  approved_list_has "$1"
}

# Commands that are not paths (a prune) are reviewed as rows too, keyed
# `prune:<id>`. The Guardian never runs without a list (see the arg check),
# so there is no unattended fallback here.
command_approved() {
  [[ -z "${ONLY_PATHS}" ]] && return 0
  approved_list_has "$1"
}

# The reviewed list is read once (lib/approved-list.sh). A list that cannot
# be checked stops the run.
if [[ -n "${ONLY_PATHS}" ]]; then
  if ! source "${ANALYZERS_ROOT}/lib/approved-list.sh" 2>/dev/null; then
    echo "FATAL: lib/approved-list.sh is missing — refusing to run with a reviewed list it cannot check." >&2
    exit 78
  fi
  approved_list_load "${ONLY_PATHS}"
fi

# prune_result <command> <exit status>: says how a prune command ended.
prune_result() {
  if [[ "$2" -eq 0 ]]; then log "  done: $1"; else log "  failed: $1 (exit $2)"; fi
}

# reclaim is not used here; worktree and retention removals log their own
# marker rows (the `worktree` / `retention` words the app's parser reads).

# protected <path> — the user's protect list (ANALYZERS_PROTECT_EXTRA, regex
# alternatives) always wins, here as in the memory guard. A path on it is
# never offered as a removable row; if one slips into a reviewed list anyway,
# the check below still refuses it.
protected() {
  [[ -n "${ANALYZERS_PROTECT_EXTRA:-}" ]] || return 1
  printf '%s\n' "$1" | grep -qiE -- "${ANALYZERS_PROTECT_EXTRA}"
}

# nearest ancestor dir containing .git  (echoes path, or empty)
repo_root() {
  local d="$1"
  while [[ "$d" != "/" && -n "$d" ]]; do
    [[ -d "$d/.git" || -f "$d/.git" ]] && { echo "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

# is_idle <dir> <days>  -> exit 0 if NO meaningful file modified within <days>
# (ignores heavy regenerable dirs so a fresh build cache doesn't mark a repo active)
is_idle() {
  local dir="$1" days="$2" hit
  hit=$(find "$dir" \
        \( -name node_modules -o -name .git -o -name .cache -o -name target -o -name .build -o -name DerivedData \
           -o -name .next -o -name .turbo -o -name dist -o -name build -o -name .vite -o -name .svelte-kit \
           -o -name .nuxt -o -name .parcel-cache \) -prune \
        -o -type f -mtime "-${days}" -print -quit 2>/dev/null)
  [[ -z "$hit" ]]
}

# Repo roots something LIVE runs from — a running process whose command line
# names a path under the roots, or a LOADED LaunchAgent pointing there, or a
# shell/agent session whose working directory is inside one. Built once, on
# first use; "fresh" rescans now (the late look, immediately before acting).
RUNTIME_ROOTS_FILE=""
is_runtime_root() {  # <dir> [fresh]
  if [[ "${2:-}" == "fresh" && -n "$RUNTIME_ROOTS_FILE" ]]; then rm -f "$RUNTIME_ROOTS_FILE"; RUNTIME_ROOTS_FILE=""; fi
  if [[ -z "$RUNTIME_ROOTS_FILE" ]]; then
    RUNTIME_ROOTS_FILE="$(mktemp -t guardian-runtime)"
    local roots_re="" r loaded plist p rr
    for r in $ROOTS; do roots_re="${roots_re:+${roots_re}|}$(printf '%s' "$r" | sed 's/[.[\*^$+?(){}|]/\\&/g')"; done
    loaded="$(launchctl list 2>/dev/null | awk 'NR>1{print $3}')"
    {
      ps -axo command= 2>/dev/null
      # working directories too: a shell or agent session sitting in a
      # checkout names no path on its command line
      lsof -a -u "$(id -u)" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | sed 's#$#/#'
      for plist in "$HOME"/Library/LaunchAgents/*.plist; do
        printf '%s\n' "$loaded" | grep -qxF "$(basename "$plist" .plist)" && cat "$plist"
      done
    } | grep -oE "(${roots_re})/[^ <\"']+" | sort -u | while IFS= read -r p; do
      rr="$(repo_root "$p" || true)"; [[ -n "$rr" ]] && echo "$rr"
    done | sort -u > "$RUNTIME_ROOTS_FILE"
  fi
  grep -qxF -- "$1" "$RUNTIME_ROOTS_FILE"
}

# The live AI-session exemption (lib/live-sessions.sh over lib/coding-agents.tsv):
# every working directory of every process inside a live coding session, so a
# worktree an agent is sitting in stays "kept" whatever its merge state.
live_cwds_file() {  # echoes the cache file path, building it on first use
  if [[ -z "$LIVE_CWDS_FILE" ]]; then
    LIVE_CWDS_FILE="$(mktemp -t guardian-live)"
    if [[ -f "${ANALYZERS_ROOT}/lib/live-sessions.sh" ]]; then
      # shellcheck source=../lib/live-sessions.sh
      source "${ANALYZERS_ROOT}/lib/live-sessions.sh"
      local pid
      for pid in $(live_session_exempt 2>/dev/null || true); do
        lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
      done > "$LIVE_CWDS_FILE"
    fi
  fi
  printf '%s\n' "$LIVE_CWDS_FILE"
}

# live_session_in <dir> -> exit 0 when a live session's working directory is
# <dir> or anywhere inside it
live_session_in() {
  local f p
  f="$(live_cwds_file)"
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    case "$p" in "$1"|"$1"/*) return 0 ;; esac
  done < "$f"
  return 1
}

# The integration branch of a repo: origin's default, else the primary
# checkout's own branch, else main.
base_branch() {  # <repo>
  local b
  b="$(git -C "$1" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"; b="${b#origin/}"
  if [[ -n "$b" ]]; then printf '%s\n' "$b"; return 0; fi
  b="$(git -C "$1" symbolic-ref --short HEAD 2>/dev/null)"
  if [[ -n "$b" ]]; then printf '%s\n' "$b"; return 0; fi
  printf 'main\n'
}

# Dependency dirs of a worktree (rebuildable output by name), one per line.
wt_dep_dirs() {  # <worktree>
  find "$1" -maxdepth 4 -mindepth 1 \
    \( -type d \( -name .git -o -name .composure -o -name .claude \) -prune \) -o \
    \( -type d \( -name node_modules -o -name target -o -name DerivedData -o -name .build -o -name .swiftpm \
       -o -name Pods -o -name .gradle -o -name .expo -o -name .next -o -name dist -o -name build -o -name .turbo \) \
       -prune -print \) 2>/dev/null
}

# Local-only files of a clean worktree: gitignored paths whose NAME is not
# rebuildable output (.env, settings, local databases, notes). One per line.
wt_local_only() {  # <worktree>
  git -C "$1" status --porcelain -z --ignored=matching 2>/dev/null | tr '\0' '\n' \
    | sed -n 's/^!! //p' \
    | while IFS= read -r p; do
        p="${p%/}"
        [[ -n "$p" ]] || continue
        case "${p##*/}" in node_modules|target|DerivedData|.build|.swiftpm|Pods|.gradle|.expo|.next|dist|build|.turbo) continue ;; esac
        [[ -e "$1/$p" ]] && printf '%s\n' "$p"
      done
}

wt_manifest() {  # <markdown table row> — the ledger is the restore path
  if [[ ! -f "$WT_MANIFEST" ]]; then
    printf '%s\n' "# Worktrees removed by Sparehold" "" \
      "Each row says how to bring a worktree back exactly as it was: re-create the checkout on its branch, re-apply its parked changes, copy its local-only files back." "" \
      "| When | Worktree | Branch | Parked changes | Local-only files | Restore |" \
      "|---|---|---|---|---|---|" > "$WT_MANIFEST"
  fi
  printf '%s\n' "$1" >> "$WT_MANIFEST"
}

# ---------- header ----------
log "=================================================================="
log " guardian.sh  |  mode=guardian idle=${WORKTREE_IDLE_DAYS} parked=${PARKED_DAYS} reports=${REPORTS_DAYS}  |  $([[ $DRY_RUN -eq 1 ]] && echo 'DRY RUN' || echo 'APPLY')  |  ${TS_NOW}"
log " roots=${ROOTS}  worktree-idle>${WORKTREE_IDLE_DAYS}d  parked>${PARKED_DAYS}d  reports>${REPORTS_DAYS}d"
log " input: ${INVOKED}"
log "=================================================================="

# ---------- G1. Worktrees merged into their integration branch ----------
# Candidates are re-derived from scratch on EVERY run, preview and apply
# alike; a reviewed list can only shrink what is acted on.
group "G1. Git worktrees whose branch is merged into the repo's main branch, idle >${WORKTREE_IDLE_DAYS}d"

wt_keep() {  # <worktree> <reason>
  WT_KEPT=$((WT_KEPT + 1))
  log "  (kept: $1 — $2)"
}

# wt_consider <repo> <worktree> <head-sha> <branch|""> <locked 0|1> <prunable 0|1>
wt_consider() {
  local repo="$1" wt="$2" sha="$3" br="$4" locked="$5" stale="$6"
  local name base kb depn=0 depkb=0 deps d depkb_one depnote orig_main cdir merged_into alt
  [[ -d "$wt" ]] || return 0
  # linked worktrees carry a .git FILE; a .git directory is a primary checkout
  [[ -f "$wt/.git" ]] || return 0
  if [[ "$stale" == "1" ]]; then
    WT_STALE=$((WT_STALE + 1))
    log "  (stale record: ${wt} — its folder is gone; git worktree prune clears it)"
    return 0
  fi
  name="${wt##*/}"
  # A folder named main holding a non-main branch stays excluded.
  if [[ "$name" == "main" && "$br" != "main" ]]; then WT_MAIN=$((WT_MAIN + 1)); return 0; fi
  orig_main=""
  if [[ "$br" == "main" ]]; then
    orig_main="$(git -C "$repo" rev-parse --verify -q refs/remotes/origin/main 2>/dev/null || true)"
    # No origin/main (local-only repo) -> keep main as a standing skip.
    if [[ -z "$orig_main" ]]; then WT_MAIN=$((WT_MAIN + 1)); return 0; fi
    cdir="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null || true)"
    if [[ -n "$cdir" && "$cdir" != /* ]]; then cdir="$repo/$cdir"; fi
    if [[ -n "$cdir" && -e "$cdir/composure-pending-npm-publish" ]]; then
      wt_keep "$wt" "a package publish is pending from main"
      return 0
    fi
  fi
  [[ "$locked" == "1" ]] && { wt_keep "$wt" "it is locked"; return 0; }
  protected "$wt" && { wt_keep "$wt" "it is on your protect list"; return 0; }
  # something live runs from it: never a candidate, never even a kept row
  # (this includes the checkout this session is working in)
  is_runtime_root "$wt" && { WT_KEPT=$((WT_KEPT + 1)); return 0; }
  is_idle "$wt" "$WORKTREE_IDLE_DAYS" || { wt_keep "$wt" "it was modified in the last ${WORKTREE_IDLE_DAYS}d"; return 0; }
  # a worktree with any uncommitted or untracked change is never parked by
  # the Guardian: its changes belong to unmerged work
  if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null | head -1)" ]]; then
    WT_DIRTY=$((WT_DIRTY + 1))
    log "  (left alone: ${wt} — it has uncommitted changes)"
    return 0
  fi
  # no live coding session sits in it
  live_session_in "$wt" && { wt_keep "$wt" "a live session is sitting in it"; return 0; }
  # the merge / sync test: main compares against origin/main; feature and
  # detached-HEAD worktrees compare against base_branch or integration branches
  if [[ "$br" == "main" ]]; then
    base="origin/main"
    if [[ "$sha" != "$orig_main" ]]; then
      wt_keep "$wt" "its branch main is not merged into ${base}"
      return 0
    fi
  else
    base="$(base_branch "$repo")"
    merged_into=""
    if git -C "$repo" merge-base --is-ancestor "$sha" "$base" 2>/dev/null; then
      merged_into="$base"
    else
      for alt in development develop origin/development origin/develop; do
        if git -C "$repo" rev-parse --verify -q "$alt" >/dev/null 2>&1 \
           && git -C "$repo" merge-base --is-ancestor "$sha" "$alt" 2>/dev/null; then
          merged_into="$alt"
          break
        fi
      done
    fi
    if [[ -z "$merged_into" ]]; then
      wt_keep "$wt" "its branch ${br:-at ${sha:0:10}} is not merged into ${base}"
      return 0
    fi
    base="$merged_into"
  fi
  # census: dependency dirs and their size (rebuildable output by name)
  deps="$(wt_dep_dirs "$wt")"
  if [[ -n "$deps" ]]; then
    while IFS= read -r d; do
      [[ -n "$d" ]] || continue
      depkb_one="$(du -sk "$d" 2>/dev/null | awk '{print $1}')"; depkb_one="${depkb_one:-0}"
      depn=$((depn + 1)); depkb=$((depkb + depkb_one))
    done <<< "$deps"
  fi
  kb="$(du -sk "$wt" 2>/dev/null | awk '{print $1}')"; kb="${kb:-0}"
  # fingerprint the whole visible state (tracked + ignored): the apply re-computes
  # it and leaves the worktree alone when anything changed since this preview —
  # the review described the tree as it stood, not whatever it became
  seen="$(git -C "$wt" status --porcelain --ignored=matching 2>/dev/null | shasum | awk '{print $1}')"
  # only a preview records the fingerprint: an apply that re-swept first would
  # compare a tree against itself, and the person never reviewed what this run
  # just looked at — the reviewed list is what counts
  if [[ "$DRY_RUN" -eq 1 ]]; then
    mkdir -p "$(dirname "$SEEN_FILE")"
    printf '%s\t%s\n' "$wt" "$seen" >> "$SEEN_FILE"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$wt" "$repo" "${br:-detached ${sha:0:10}}" "$base" "$sha" "$kb" "$depn" "$depkb" "$seen" >> "$WT_CANDIDATES"
  WT_OFFERED=$((WT_OFFERED + 1))
  # a preview identifies; only the apply's deletions count as freed
  [[ "$DRY_RUN" -eq 1 ]] && TOTAL_KB=$((TOTAL_KB + kb))
  depnote=""
  [[ "$depn" -gt 0 ]] && depnote=" · ${depn} dep dirs ($(human "$depkb"))"
  log "  [DRY]     $(printf '%10s' "$(human "$kb")")  worktree  ${wt}  ${repo}  branch ${br:-detached ${sha:0:10}} merged into ${base} · idle ${WORKTREE_IDLE_DAYS}d+${depnote}"
  return 0
}

# one dependency line per repo for the census (G2), one repo line for G3's guidance
note_repo() {  # <repo>
  grep -qxF -- "$1" "$REPOS_FILE" 2>/dev/null || printf '%s\n' "$1" >> "$REPOS_FILE"
}

for root in $ROOTS; do
  [[ -d "$root" ]] || continue
  while IFS= read -r gitdir; do
    repo="$(dirname "$gitdir")"
    note_repo "$repo"
    first=1; wt=""; sha=""; br=""; locked=0; stale=0
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) wt="${line#worktree }"; sha=""; br=""; locked=0; stale=0 ;;
        "HEAD "*)     sha="${line#HEAD }" ;;
        "branch "*)   br="${line#branch refs/heads/}" ;;
        locked*)      locked=1 ;;
        prunable*)    stale=1 ;;
        "")           if [[ $first -eq 0 && -n "$wt" ]]; then
                        wt_consider "$repo" "$wt" "$sha" "$br" "$locked" "$stale"
                      fi
                      first=0; wt="" ;;
      esac
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null; echo "")
  done < <(find "$root" \( -name node_modules \) -prune \
             -o -type d -name .git -prune -print 2>/dev/null)
done
log "  (kept ${WT_KEPT} recent, live, locked, protected or unmerged; left ${WT_DIRTY} with uncommitted changes alone; ${WT_MAIN} on main or named main; ${WT_STALE} stale records)"

# ---------- G2. Duplication census (advisory; never an action) ----------
# One row per project with >= 2 worktrees: how many dependency dirs the
# worktrees carry between them — what a shared package store or build
# directory would hold once instead of N times.
group "G2. Projects whose worktrees duplicate dependency folders (advisory)"
census_hits="$(LC_ALL=C awk -F'\t' '{ n[$2]++; d[$2]+=$7; k[$2]+=$8 }
               END { for (r in n) if (n[r] >= 2) printf "%d\t%d\t%d\t%s\n", n[r], d[r], k[r], r }' "$WT_CANDIDATES" 2>/dev/null \
              | sort -t"$(printf '\t')" -k3 -nr)"
if [[ -n "$census_hits" ]]; then
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    IFS="$(printf '\t')" read -r nwt ndep depkb repo <<< "$row"
    proj="${repo##*/}"
    log "  info:${proj}  ${nwt} worktrees carry ${ndep} dependency folders, $(human "$depkb") between them · repo ${repo} — one shared package store or build directory would hold a single copy"
  done <<< "$census_hits"
else
  log "  (no project has two or more worktrees)"
fi

# ---------- G3. Package stores (sizes, prunes, global-store guidance) ----------
group "G3. Package stores and prunes"
if command -v pnpm >/dev/null 2>&1; then
  pstore="$(pnpm store path 2>/dev/null || true)"
  if [[ -n "$pstore" && -d "$pstore" ]]; then
    pk="$(du -sk "$pstore" 2>/dev/null | awk '{print $1}')"; pk="${pk:-0}"
    log "  store:pnpm  $(printf '%10s' "$(human "$pk")")  ${pstore}"
  fi
  # launchd starts us with cwd=/ (read-only system volume); pnpm writes a temp
  # file into the cwd and dies with EROFS, so prune from $HOME.
  if [[ "$DRY_RUN" -eq 1 ]]; then log "  [DRY]     prune:pnpm  Unused packages in the pnpm store (size not known until it runs)"
  elif ! command_approved prune:pnpm; then log "  [SKIP]    prune:pnpm  not in the reviewed list"
  else log "  running: pnpm store prune"; rc=0; (cd "$HOME" && pnpm store prune) >>"$LOG_FILE" 2>&1 || rc=$?; prune_result "pnpm store prune" "$rc"; fi
fi
if command -v npm >/dev/null 2>&1; then
  cacache="${HOME}/.npm/_cacache"
  if [[ -d "$cacache" ]]; then
    nk="$(du -sk "$cacache" 2>/dev/null | awk '{print $1}')"; nk="${nk:-0}"
    log "  store:npm  $(printf '%10s' "$(human "$nk")")  ${cacache}"
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then log "  [DRY]     prune:npm  The whole npm cache, which downloads again when needed (size not known until it runs)"
  elif ! command_approved prune:npm; then log "  [SKIP]    prune:npm  not in the reviewed list"
  else log "  running: npm cache clean --force"; rc=0; npm cache clean --force >>"$LOG_FILE" 2>&1 || rc=$?; prune_result "npm cache clean --force" "$rc"; fi
fi
if command -v sccache >/dev/null 2>&1; then
  scdir="${SCCACHE_DIR:-${HOME}/Library/Caches/Mozilla.sccache}"
  if [[ -d "$scdir" ]]; then
    sk="$(du -sk "$scdir" 2>/dev/null | awk '{print $1}')"; sk="${sk:-0}"
    log "  store:sccache  $(printf '%10s' "$(human "$sk")")  ${scdir}"
  fi
else
  log "  (sccache not installed)"
fi
if [[ -d "${HOME}/.cargo/registry" ]]; then
  ck="$(du -sk "${HOME}/.cargo/registry" 2>/dev/null | awk '{print $1}')"; ck="${ck:-0}"
  log "  store:cargo  $(printf '%10s' "$(human "$ck")")  ${HOME}/.cargo/registry"
fi
# Global-store guidance: advice rows, never an action (the app never edits a
# person's tool configs).
guide_n=0
while IFS= read -r repo; do
  [[ -f "$repo/.npmrc" ]] || continue
  if grep -qiE '^[[:space:]]*store-dir[[:space:]]*=' "$repo/.npmrc" 2>/dev/null; then
    log "  guide:pnpm-store-dir  ${repo}/.npmrc sets a project-local pnpm store-dir — its packages are copied per project instead of linked to one global store"
    guide_n=$((guide_n + 1))
  fi
done < "$REPOS_FILE"
if command -v sccache >/dev/null 2>&1 && [[ -s "$WT_CANDIDATES" ]]; then
  basedirs="${SCCACHE_BASEDIRS:-}"
  shared=0
  if [[ -n "$basedirs" ]]; then
    while IFS= read -r cand; do
      wt_path="$(printf '%s' "$cand" | cut -f1)"
      IFS=':' read -ra bd_list <<< "$basedirs"
      for bd in "${bd_list[@]}"; do
        case "$wt_path" in "$bd"|"$bd"/*) shared=1; break ;; esac
      done
      [[ "$shared" -eq 1 ]] && break
    done < "$WT_CANDIDATES"
  fi
  if [[ "$shared" -eq 0 ]]; then
    log "  guide:sccache-basedirs  sccache is installed, but SCCACHE_BASEDIRS does not name any worktree root — worktree builds cannot share one cache; set it to the folder your projects live in"
    guide_n=$((guide_n + 1))
  fi
fi
if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
  log "  guide:cargo-target-dir  CARGO_TARGET_DIR points at one shared folder (${CARGO_TARGET_DIR}); concurrent builds contend on its lock — per-checkout targets build in parallel safely"
  guide_n=$((guide_n + 1))
fi
[[ "$guide_n" -eq 0 ]] && log "  (no global-store guidance for this Mac)"

# ---------- G4. Retention: Sparehold's own dated report dirs ----------
# Dated run dirs and parked-worktrees dirs past their age are offered.
# latest.md, worktree-removals.md, the plain .log files and lock files are
# never candidates (they are not dated dirs).
dir_age_days() {  # <dir named YYYY-MM-DD> -> age in days, or empty
  local d="${1##*/}" secs now
  printf '%s' "$d" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || return 0
  secs="$(date -j -f '%Y-%m-%d' "$d" '+%s' 2>/dev/null)" || return 0
  [[ -n "$secs" ]] || return 0
  now="$(date '+%s')"
  echo $(( (now - secs) / 86400 ))
}

offer_retention() {  # <dir> <kind-note> <age limit in days>
  local p="$1" note="$2" limit="$3" kb age
  [[ -d "$p" ]] || return 0
  age="$(dir_age_days "$p")"
  [[ -n "$age" ]] || return 0
  [[ "$age" -gt "$limit" ]] || return 0
  protected "$p" && return 0
  kb="$(du -sk "$p" 2>/dev/null | awk '{print $1}')"; kb="${kb:-0}"
  RET_OFFERED=$((RET_OFFERED + 1))
  # a preview identifies; only the apply's deletions count as freed
  [[ "$DRY_RUN" -eq 1 ]] && TOTAL_KB=$((TOTAL_KB + kb))
  log "  [DRY]     $(printf '%10s' "$(human "$kb")")  retention  ${p}  ${note} · ${age}d old"
  return 0
}

apply_retention() {  # <dir> <kind-note> <age limit in days>
  local p="$1" note="$2" limit="$3" kb age
  [[ -d "$p" ]] || return 0
  age="$(dir_age_days "$p")"
  [[ -n "$age" ]] || return 0
  [[ "$age" -gt "$limit" ]] || return 0
  if ! approved "$p"; then log "  [SKIP]    not in approved set  $p"; return 0; fi
  protected "$p" && { log "  [SKIP]    on the protect list  $p"; return 0; }
  kb="$(du -sk "$p" 2>/dev/null | awk '{print $1}')"; kb="${kb:-0}"
  if rm -rf "$p" 2>/dev/null || { chmod -R u+w "$p" 2>/dev/null; rm -rf "$p" 2>/dev/null; }; then
    TOTAL_KB=$((TOTAL_KB + kb))
    RET_REMOVED=$((RET_REMOVED + 1))
    log "  [DELETED] $(printf '%10s' "$(human "$kb")")  retention  ${p}  ${note} · ${age}d old"
  else
    log "  [FAILED]  $(printf '%10s' "$(human "$kb")")  retention  ${p}  ${note} · ${age}d old"
  fi
}

group "G4. Sparehold's own reports past their age (parked>${PARKED_DAYS}d, runs>${REPORTS_DAYS}d)"
for d in "$REPORTS_ROOT/memory"/*/ "$REPORTS_ROOT/storage"/*/; do
  case "$d" in */parked-worktrees/*) continue ;; esac
  d="${d%/}"
  if [[ "$DRY_RUN" -eq 1 ]]; then offer_retention "$d" "report run" "$REPORTS_DAYS"; else apply_retention "$d" "report run" "$REPORTS_DAYS"; fi
done
for d in "$PARK_ROOT"/*/; do
  d="${d%/}"
  if [[ "$DRY_RUN" -eq 1 ]]; then offer_retention "$d" "parked worktree files" "$PARKED_DAYS"; else apply_retention "$d" "parked worktree files" "$PARKED_DAYS"; fi
done

# ---------- apply: park + remove, per reviewed candidate ----------
# The order per candidate, every time (the park flow):
#   late looks (runtime root fresh, live session) -> re-check the tree is
#   still exactly what the review saw -> ditto local-only files aside -> append the ledger row
#   BEFORE the remove (the receipt can never be lost) -> git worktree remove.
# The branch is never deleted; a failure leaves everything as it was.
wt_apply() {  # <worktree<TAB>repo<TAB>branch<TAB>base<TAB>sha<TAB>kb<TAB>depn<TAB>depKB>
  local row="$1"
  local wt repo br base sha kb
  wt="$(printf '%s' "$row" | awk -F'\t' '{print $1}')"
  repo="$(printf '%s' "$row" | awk -F'\t' '{print $2}')"
  br="$(printf '%s' "$row" | awk -F'\t' '{print $3}')"
  base="$(printf '%s' "$row" | awk -F'\t' '{print $4}')"
  sha="$(printf '%s' "$row" | awk -F'\t' '{print $5}')"
  kb="$(printf '%s' "$row" | awk -F'\t' '{print $6}')"
  local name park="" park_rel precious rel restore ref parked_note seen
  name="${wt##*/}"
  # re-check against the PREVIEW's fingerprint, never a fresh one: the preview
  # recorded the tree's whole visible state (tracked + ignored); anything that
  # changed since — a tracked edit, a build cache that grew, a new file — means
  # this is not the tree the person reviewed, so it is left alone for a fresh
  # preview. No record means no preview in this app offered it: never removed.
  seen="$(awk -F'\t' -v w="$wt" '$1 == w { print $2 }' "$SEEN_FILE" 2>/dev/null | tail -1)"
  if [[ -z "$seen" ]]; then
    log "  [SKIP]    no preview of this worktree in this app  $wt"; return 0
  fi
  if [[ "$(git -C "$wt" status --porcelain --ignored=matching 2>/dev/null | shasum | awk '{print $1}')" != "$seen" ]]; then
    log "  (left alone: ${wt} — it changed since the preview)"
    return 0
  fi
  if ! approved "$wt"; then log "  [SKIP]    not in approved set  $wt"; return 0; fi
  if protected "$wt"; then log "  [SKIP]    on the protect list  $wt"; return 0; fi
  # the late look: a session may have started in it since the run began
  if is_runtime_root "$wt" fresh; then
    log "  [SKIP]    something started running in it just now  $wt"; return 0
  fi
  if live_session_in "$wt"; then
    log "  [SKIP]    a live session is sitting in it  $wt"; return 0
  fi
  [[ -d "$wt" ]] || { log "  [SKIP]    already gone  $wt"; return 0; }
  # 1. copy local-only files aside (gitignored, not rebuildable by name)
  precious="$(wt_local_only "$wt")"
  if [[ -n "$precious" ]]; then
    # mirror the repo's path under $HOME, so two repos named alike never share
    # a folder; a repo outside $HOME keeps its absolute path, slash stripped
    park_rel="${repo#"$HOME"/}"
    [[ "$park_rel" == "$repo" ]] && park_rel="${repo#/}"
    park="${PARK_ROOT}/$(date '+%Y-%m-%d')/${park_rel}/${name}"
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      if ! { mkdir -p "$park/$(dirname "$rel")" && ditto "$wt/$rel" "$park/$rel"; } 2>>"$LOG_FILE"; then
        log "  [FAILED]  $(printf '%10s' "$(human "$kb")")  worktree  ${wt}  ${repo}  branch ${br} merged into ${base} · couldn't copy ${rel} aside — left as it was"
        return 0
      fi
    done <<< "$precious"
    log "  (parked: ${park} — $(human "$(du -sk "$park" 2>/dev/null | awk '{print $1}')") of ${name}'s local-only files, copied aside before the remove)"
  fi
  # 2. append the ledger row BEFORE the remove: the receipt can never be lost.
  #    A row whose worktree still exists is harmless — its restore command is
  #    idempotent enough to re-run after a failed worktree add.
  ref="$br"; [[ "$br" == detached\ * ]] && ref="${br#detached }"
  restore="\`git -C '${repo}' worktree add '${wt}' ${ref}\`"
  [[ -n "$park" ]] && restore="${restore}, then \`ditto '${park}' '${wt}'\`"
  wt_manifest "| $(date '+%Y-%m-%d %H:%M') | \`${wt}\` | ${br} |  | ${park:+\`${park}\`} | ${restore} |"
  # 3. remove the checkout; the branch and its commits are never touched
  if git -C "$repo" worktree remove "$wt" >>"$LOG_FILE" 2>&1; then
    TOTAL_KB=$((TOTAL_KB + kb))
    WT_REMOVED=$((WT_REMOVED + 1))
    parked_note=""
    [[ -n "$park" ]] && parked_note=" · local files parked ${park}"
    log "  [DELETED] $(printf '%10s' "$(human "$kb")")  worktree  ${wt}  ${repo}  branch ${br} merged into ${base}${parked_note} · ledger ${WT_MANIFEST}"
  else
    log "  [FAILED]  $(printf '%10s' "$(human "$kb")")  worktree  ${wt}  ${repo}  branch ${br} merged into ${base} · git refused to remove it — left as it was"
  fi
  return 0
}

if [[ "$DRY_RUN" -eq 0 && -s "$WT_CANDIDATES" ]]; then
  group "G1b. Removing the reviewed worktrees (park first, remove last)"
  while IFS= read -r row; do
    [[ -n "$row" ]] && wt_apply "$row"
  done < "$WT_CANDIDATES"
fi

# ---------- summary ----------
RUN_FREED_KB="$TOTAL_KB"

log ""
log "=================================================================="
if [[ "$DRY_RUN" -eq 1 ]]; then
  log " DRY RUN — identified ~$(human "$RUN_FREED_KB") reclaimable. Apply only through the Sparehold app's Cache Guardian (it writes the reviewed list), or --apply --only-paths <file>."
  notify "Cache Guardian (dry run)" "Would free ~$(human "$RUN_FREED_KB"): ${WT_OFFERED} worktree(s), ${RET_OFFERED} old report dir(s)."
else
  log " DONE — freed ~$(human "$RUN_FREED_KB") [mode=guardian]."
  notify "Cache Guardian" "Freed ~$(human "$RUN_FREED_KB"): removed ${WT_REMOVED} worktree(s) and ${RET_REMOVED} old report dir(s). The ledger lists how to restore each one."
fi
log " Free space now: $(df -h /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4" avail ("$5" used)"}')"
log "=================================================================="

# ---------- interactive follow-through ----------
if [[ "$INTERACTIVE" -eq 1 ]]; then
  echo ""
  echo "  Removal is a reviewed act: open the Sparehold app's Cache Guardian, review the rows,"
  echo "  and apply there — or pass --apply --only-paths <file> with the reviewed list."
  echo ""
  read -rp "  Done — press Enter to close this window… " _
fi
