#!/usr/bin/env bash
# agent-sweep-test.sh — the agent inventory sweep (agents/agent-sweep.sh).
# Proves, in a scratch world (stub PATH, fixture repos, fixture headroom):
#   * the installed agents come from the ONE list (lib/coding-agents.tsv):
#     an exe found on PATH is named with its path; a fragment is never claimed
#     as installed (unknown, never a guess)
#   * the sessions section carries the live-session walk's roots with their
#     commands, and session_count matches
#   * the headroom section folds the guard's file in and flags staleness:
#     a fresh file says stale=false, one the guard stopped ticking says true,
#     a missing file means no headroom section at all
#   * the worktrees come from the Guardian's walk (same find, same roots):
#     each linked worktree with its branch, size and merged-to-main verdict,
#     the primary checkout never listed as its own worktree
#   * a dry run writes nothing; the real run's JSON parses as one object with
#     the sections the app's parser names
# Nothing here runs an agent binary or touches anything outside its temp dir.
# Runs under bash AND /bin/bash (3.2).
#   Usage: agents/tests/agent-sweep-test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
TMP="$(mktemp -d)"
trap 'if [[ "${KEEP_TMP:-0}" == "1" ]]; then echo "kept: $TMP"; else rm -rf "$TMP"; fi' EXIT
fail=0
check() { if [[ "$2" == "ok" ]]; then echo "PASS  $1"; else echo "FAIL  $1 ($2)"; fail=1; fi; }

for sh in bash /bin/bash; do
  # ---- the scratch world: fresh for every interpreter (the fixture git world
  # must not be re-initialized on the second pass) ----
  TMP="$TMP/$(basename "$sh")"; mkdir -p "$TMP"
  TREE="$TMP/tree"; mkdir -p "$TREE/lib" "$TREE/agents" "$TMP/stubs"
  cp "$ROOT"/lib/*.sh "$ROOT"/lib/*.tsv "$TREE/lib/" 2>/dev/null
  cp "$ROOT"/agents/agent-sweep.sh "$TREE/agents/"
  # one scratch repo with a linked worktree, merged and one not
  PROJECTS="$TMP/Projects"; mkdir -p "$PROJECTS"
  git() { /usr/bin/git -c user.name=t -c user.email=t@x.invalid -c commit.gpgsign=false "$@"; }
  export -f git 2>/dev/null || true
  repo="$PROJECTS/fixture-repo"; mkdir -p "$repo"
  git init -q -b main "$repo"
  (cd "$repo" && echo one > a.txt && git add -A && git commit -q -m one \
     && git checkout -q -b feature/merged-branch && echo two > a.txt && git commit -q -am two \
     && git checkout -q main && git merge -q feature/merged-branch >/dev/null \
     && git worktree add -q "$PROJECTS/fixture-wt" -b feature/open-branch >/dev/null 2>&1 \
     && echo three > b.txt && git add -A && git commit -q -m three \
     && (cd "$PROJECTS/fixture-wt" && echo wt > c.txt && git add -A && git commit -q -m wt))
  # the "installed" claude is a stub the PATH finds — read with command -v, never run
  printf '#!/bin/sh\necho stub\n' > "$TMP/stubs/claude"; chmod +x "$TMP/stubs/claude"
  DATA="$TMP/data"; mkdir -p "$DATA/reports/memory" "$DATA/reports/agents"
  # a fresh headroom file (the guard's exact shape)
  iso="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf '# sparehold headroom v1 — what this Mac can take on right now; check this before spawning more work\ndisk_free_gb: 12.5\nswap_used_mb: 40\nswap_files: 0\nwired_mb: 5300\ncompressed_mb: 2100\npressure: 1\nprocs: 412\nagent_sessions: 1\nupdated: %s\n' "$iso" > "$DATA/reports/memory/headroom.status"

  SPAREHOLD_DATA_DIR="$DATA" HOME="$TMP/home" GUARDIAN_ROOTS="$PROJECTS" \
    PATH="$TMP/stubs:$PATH" "$sh" "$TREE/agents/agent-sweep.sh" >/dev/null 2>&1
  inv="$DATA/reports/agents/inventory.json"

  check "[$sh] the inventory is written and the tmp file is gone" \
        "$([[ -f "$inv" && ! -e "$inv.tmp" ]] && echo ok || ls "$DATA/reports/agents/")"
  check "[$sh] the JSON parses (python reads it as one object)" \
        "$(python3 -c "import json,sys; d=json.load(open('$inv')); sys.exit(0 if all(k in d for k in ('agents','sessions','session_count','worktrees','swept_at')) else 1)" 2>/dev/null && echo ok || echo "unparsable: $(head -2 "$inv")")"
  # the installed agent: the fixture list's Claude Code exe row names claude,
  # which the stub PATH answers; a fragment row is never claimed installed
  agents="$(python3 -c "import json,sys; d=json.load(open('$inv')); print('|'.join(a['name']+'='+a['kind'] for a in d['agents']))" 2>/dev/null)"
  check "[$sh] an exe found on PATH is named installed" \
        "$([[ "$agents" == *"Claude Code=exe"* ]] && echo ok || echo "$agents")"
  check "[$sh] a fragment row is never claimed installed (unknown, not a guess)" \
        "$([[ "$agents" != *"fragment"* ]] && echo ok || echo "$agents")"
  check "[$sh] the agent's path is the stub's (read, never run)" \
        "$(python3 -c "import json,sys; d=json.load(open('$inv')); p=[a['path'] for a in d['agents'] if a['name']=='Claude Code']; sys.exit(0 if p and p[0].endswith('/claude') else 1)" 2>/dev/null && echo ok || echo wrong)"

  # sessions: the fixture world's own processes are the walk's answer — the
  # section exists and its count matches its rows
  check "[$sh] session_count matches the sessions rows" \
        "$(python3 -c "import json,sys; d=json.load(open('$inv')); sys.exit(0 if d['session_count'] == len(d['sessions']) else 1)" 2>/dev/null && echo ok || echo mismatch)"

  # headroom: fresh file → figures folded in, stale=false
  check "[$sh] the headroom figures are folded in from the guard's file" \
        "$(python3 -c "import json,sys; d=json.load(open('$inv')); h=d.get('headroom',{}); sys.exit(0 if h.get('disk_free_gb')==12.5 and h.get('pressure')==1 else 1)" 2>/dev/null && echo ok || echo missing)"
  check "[$sh] a fresh headroom file says stale=false" \
        "$(python3 -c "import json,sys; d=json.load(open('$inv')); sys.exit(0 if d['headroom']['stale'] is False else 1)" 2>/dev/null && echo ok || echo "stale=$(python3 -c "import json; print(json.load(open('$inv'))['headroom']['stale'])")")"

  # worktrees: the Guardian's walk — the linked worktree listed, the primary not
  wtinfo="$(python3 -c "import json,sys; d=json.load(open('$inv')); print('|'.join(w['branch']+'='+str(w['kb']>0)+'='+str(w['merged_to_main']) for w in d['worktrees']))" 2>/dev/null)"
  check "[$sh] the linked worktree is listed with its branch and a size" \
        "$([[ "$wtinfo" == *"feature/open-branch=True=False"* ]] && echo ok || echo "$wtinfo")"
  check "[$sh] the primary checkout is never its own worktree row" \
        "$(python3 -c "import json,sys; d=json.load(open('$inv')); sys.exit(0 if all(not w['path'].endswith('/fixture-repo') or w['branch']!='main' for w in d['worktrees']) else 1)" 2>/dev/null && echo ok || echo "primary listed")"

  # a stale headroom: the guard stopped ticking (the file's updated line is an hour old)
  old_iso="$(date -v-1H '+%Y-%m-%dT%H:%M:%S%z')"
  sed -i '' "s/^updated: .*/updated: $old_iso/" "$DATA/reports/memory/headroom.status"
  SPAREHOLD_DATA_DIR="$DATA" HOME="$TMP/home" GUARDIAN_ROOTS="$PROJECTS" PATH="$TMP/stubs:$PATH" \
    "$sh" "$TREE/agents/agent-sweep.sh" >/dev/null 2>&1
  check "[$sh] a headroom file the guard stopped ticking says stale=true" \
        "$(python3 -c "import json,sys; d=json.load(open('$inv')); sys.exit(0 if d['headroom']['stale'] is True else 1)" 2>/dev/null && echo ok || echo "stale flag wrong")"

  # no headroom file: no headroom section, no invention
  rm -f "$DATA/reports/memory/headroom.status"
  SPAREHOLD_DATA_DIR="$DATA" HOME="$TMP/home" GUARDIAN_ROOTS="$PROJECTS" PATH="$TMP/stubs:$PATH" \
    "$sh" "$TREE/agents/agent-sweep.sh" >/dev/null 2>&1
  check "[$sh] no headroom file means no headroom section (never invented)" \
        "$(python3 -c "import json,sys; d=json.load(open('$inv')); sys.exit(0 if 'headroom' not in d else 1)" 2>/dev/null && echo ok || echo "invented")"

  # dry run writes nothing
  before="$(find "$DATA" -type f | wc -l | tr -d ' ')"
  SPAREHOLD_DATA_DIR="$DATA" HOME="$TMP/home" GUARDIAN_ROOTS="$PROJECTS" PATH="$TMP/stubs:$PATH" \
    "$sh" "$TREE/agents/agent-sweep.sh" --dry-run >/dev/null 2>&1
  after="$(find "$DATA" -type f | wc -l | tr -d ' ')"
  check "[$sh] a dry run writes nothing" "$([[ "$before" == "$after" ]] && echo ok || echo "wrote files")"
done

echo
echo "$([[ $fail -eq 0 ]] && echo "ALL PASS" || echo "FAILURES ABOVE")"
exit $fail
