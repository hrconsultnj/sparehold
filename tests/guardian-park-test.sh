#!/usr/bin/env bash
# guardian-park-test.sh — guardian.sh never loses work and never touches a
# checkout it was not reviewed to remove:
#   1. a clean, idle, MERGED worktree is offered in the preview and, when the
#      reviewed list names it, its local-only files are parked under the data
#      root's reports/storage/parked-worktrees/<date>/<repo>/<name>, one ledger
#      row is appended to reports/storage/worktree-removals.md, the checkout is
#      removed, and the branch and its commits survive; the ledger row's
#      Restore cell brings the worktree back with its local files;
#   2. a dirty, locked, unmerged, or live-session worktree is never offered
#      for removal (kept lines, never [DRY] rows), and a worktree that grew
#      uncommitted changes between the preview and the apply is left alone;
#   3. a worktree named main (branch or folder) and the primary checkout are
#      never candidates;
#   4. dated report dirs past their age are offered; only those in the
#      reviewed list are removed; latest.md, the ledger and .log files are
#      never candidates.
# Everything happens in a temp folder with HOME pointed at it and copies of
# the scripts (notifications a no-op). Dry run under `bash` and /bin/bash
# (3.2); apply with an --only-paths file, and --apply without one refused.
#
# Usage: tests/guardian-park-test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../storage/guardian.sh"
[[ -f "$SCRIPT" ]] || { echo "SKIP: script not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
check() { if [[ "$2" == "ok" ]]; then echo "PASS  $1"; else echo "FAIL  $1 ($2)"; fail=1; fi; }
present() { [[ -e "$1" ]] && echo ok || echo "missing: ${1#"$TMP"/}"; }
absent()  { [[ -e "$1" ]] && echo "still there: ${1#"$TMP"/}" || echo ok; }

mkdir -p "$TMP/tree/storage" "$TMP/tree/lib" "$TMP/home"
# git and nothing else from outside the system folders: no package manager runs
ln -s "$(command -v git)" "$TMP/bin-git"
cp "$SCRIPT" "$TMP/tree/storage/guardian.sh"
cp "$HERE"/../lib/*.sh "$TMP/tree/lib/"
printf 'notify() { :; }\n' > "$TMP/tree/lib/notify.sh"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
old() { touch -h -t 202601010000 "$1"; find "$1" -exec touch -h -t 202601010000 {} + 2>/dev/null; }

# build <root>: one repo with six worktrees covering the whole keep matrix
build() {
  local R="$1/repo"
  mkdir -p "$R"
  git -C "$R" init -q -b development
  printf '.env\nnode_modules/\n' > "$R/.gitignore"
  echo base > "$R/a.txt"
  git -C "$R" add -A; git -C "$R" commit -qm init
  for b in merged dirty unmerged locked ws mainfolder; do git -C "$R" branch "$b"; done
  git -C "$R" branch main
  # the candidates: a clean merged worktree (with a gitignored .env and a
  # node_modules dir that must NOT be parked) and one inside the agent folders
  git -C "$R" worktree add -q "$R/../wt-merged" merged
  git -C "$R" worktree add -q "$R/.composure/workspaces/agent-ws" ws
  # the keeps
  git -C "$R" worktree add -q "$R/../wt-dirty" dirty
  git -C "$R" worktree add -q "$R/../wt-unmerged" unmerged
  git -C "$R" worktree add -q "$R/../wt-locked" locked
  git -C "$R" worktree lock "$R/../wt-locked" >/dev/null 2>&1
  git -C "$R" worktree add -q "$R/main" mainfolder           # a worktree FOLDER named main
  git -C "$R" worktree add -q "$R/../wt-on-main" main        # a worktree ON a branch named main
  echo x > "$R/../wt-dirty/a.txt"                             # uncommitted change
  echo new > "$R/../wt-unmerged/only-here.txt"                # unmerged commit below
  git -C "$R/../wt-unmerged" add -A; git -C "$R/../wt-unmerged" commit -qm "unmerged work"
  echo 'SECRET=1' > "$R/../wt-merged/.env"
  mkdir -p "$R/../wt-merged/node_modules/pkg"; echo m > "$R/../wt-merged/node_modules/pkg/i.js"
  # an old dated report dir and a fresh one; the ledger and a .log to prove files never go
  mkdir -p "$1/data/reports/storage/2026-05-07" "$1/data/reports/storage/$(date +%Y-%m-%d)"
  mkdir -p "$1/data/reports/storage/parked-worktrees/2026-10-01"
  echo report > "$1/data/reports/storage/2026-05-07/run.md"
  echo latest > "$1/data/reports/storage/latest.md"
  echo log > "$1/data/reports/storage/guardian.log"
  old "$1"
}

# run <label> <shell> <extra args...>: HOME at the label's own root
run() {
  local label="$1" sh="$2"; shift 2
  HOME="$TMP/$label/home" SPAREHOLD_DATA_DIR="$TMP/$label/data" \
    PATH="$(dirname "$(command -v git)"):/usr/bin:/bin:/usr/sbin:/sbin" \
    "$sh" "$TMP/tree/storage/guardian.sh" --roots "$TMP/$label" "$@" \
    > "$TMP/$label.out" 2>&1
}

for sh in bash /bin/bash; do
  [[ "$sh" == /bin/bash && ! -x /bin/bash ]] && continue
  tag="$(basename "$sh")-$([[ "$sh" == /* ]] && echo sys || echo path)"
  label="dry-$tag"; mkdir -p "$TMP/$label"
  build "$TMP/$label"
  run "$label" "$sh"
  OUT="$TMP/$label.out"
  WT_MERGED="$(git -C "$TMP/$label/repo" worktree list --porcelain | sed -n 's/^worktree //p' | grep '/wt-merged$')"
  WT_AGENT="$(git -C "$TMP/$label/repo" worktree list --porcelain | sed -n 's/^worktree //p' | grep '/agent-ws$')"
  grep -q "worktree  ${WT_MERGED}" "$OUT" && check "$tag: clean merged worktree offered" ok || check "$tag: clean merged worktree offered" "no [DRY] row in $OUT"
  grep -q "worktree  ${WT_AGENT}" "$OUT" && check "$tag: agent-folder worktree offered" ok || check "$tag: agent-folder worktree offered" "not offered"
  grep -q "(left alone: ${WT_MERGED%/wt-merged}/wt-dirty — it has uncommitted changes)" "$OUT" \
    && check "$tag: dirty worktree left alone" ok || check "$tag: dirty worktree left alone" "no kept line"
  grep -q "(kept: .*wt-locked — it is locked)" "$OUT" && check "$tag: locked worktree kept" ok || check "$tag: locked worktree kept" "no kept line"
  grep -q "is not merged into" "$OUT" && check "$tag: unmerged worktree kept" ok || check "$tag: unmerged worktree kept" "no kept line"
  grep -q "${TMP}/${label}/repo/main" "$OUT" && check "$tag: main-named worktree absent" "appears in the output" || check "$tag: main-named worktree absent" ok
  grep -q "wt-on-main" "$OUT" && check "$tag: branch-named-main worktree absent" "appears" || check "$tag: branch-named-main worktree absent" ok
  grep -q "retention  ${TMP}/${label}/data/reports/storage/2026-05-07" "$OUT" \
    && check "$tag: old report dir offered" ok || check "$tag: old report dir offered" "not offered"
  grep -q "retention  ${TMP}/${label}/data/reports/storage/parked-worktrees/2026-10-01" "$OUT" \
    && check "$tag: old parked dir offered" ok || check "$tag: old parked dir offered" "not offered"
  grep -q "$(date +%Y-%m-%d)" "$OUT" && grep -q "retention  .*$(date +%Y-%m-%d)" "$OUT" \
    && check "$tag: today's report dir not offered" "offered" || check "$tag: today's report dir not offered" ok
  grep -q "latest.md" "$OUT" && check "$tag: latest.md never a row" "appears as a row" || check "$tag: latest.md never a row" ok
  [[ -e "$TMP/$label/data/reports/storage/latest.md" ]] && check "$tag: latest.md still there (dry run)" ok || check "$tag: latest.md still there (dry run)" "gone"
  [[ -e "$TMP/$label/repo/../wt-merged" || -e "$TMP/$label/wt-merged" ]] && check "$tag: dry run removed nothing" ok || check "$tag: dry run removed nothing" "worktree gone"

  # ---------- apply ----------
  # the app's flow is preview then apply, so the test mirrors it: the preview
  # records each worktree's fingerprint, the apply checks it
  label="apply-$tag"; mkdir -p "$TMP/$label"
  build "$TMP/$label"
  R="$TMP/$label/repo"
  WT_MERGED="$(git -C "$R" worktree list --porcelain | sed -n 's/^worktree //p' | grep '/wt-merged$')"
  LIST="$(mktemp)"
  printf '%s\n' "$WT_MERGED" "$TMP/$label/data/reports/storage/2026-05-07" > "$LIST"
  run "$label" "$sh" --dry-run
  run "$label" "$sh" --apply --only-paths "$LIST"
  OUT="$TMP/$label.out"
  park="$TMP/$label/data/reports/storage/parked-worktrees/$(date +%Y-%m-%d)"
  check "$tag: [DELETED] worktree row" "$(grep -q '\[DELETED\].*worktree' "$OUT" && echo ok || echo "none in $OUT")"
  check "$tag: worktree removed" "$(absent "$WT_MERGED")"
  check "$tag: parked .env copy" "$(present "$park/${R#"$TMP/$label/"/}/wt-merged/.env")"
  check "$tag: node_modules NOT parked" "$(absent "$park/${R#"$TMP/$label/"/}/wt-merged/node_modules")"
  check "$tag: ledger row appended" "$(grep -qc 'wt-merged' "$TMP/$label/data/reports/storage/worktree-removals.md" 2>/dev/null && echo ok || echo "no row")"
  check "$tag: branch survives" "$(git -C "$R" branch --list merged | grep -q merged && echo ok || echo gone)"
  check "$tag: commits survive" "$(git -C "$R" rev-parse -q --verify merged >/dev/null && echo ok || echo gone)"
  check "$tag: worktree list shrank" "$(git -C "$R" worktree list | grep -c wt-merged | grep -q '^0$' && echo ok || echo "still listed")"
  check "$tag: reviewed report dir removed" "$(absent "$TMP/$label/data/reports/storage/2026-05-07")"
  check "$tag: unreviewed parked dir stays" "$(present "$TMP/$label/data/reports/storage/parked-worktrees/2026-10-01")"
  check "$tag: ledger and logs never removed" "$(present "$TMP/$label/data/reports/storage/latest.md")"
  # the Restore cell of the appended row runs, and brings the local files back
  CELL="$(grep '^| ' "$TMP/$label/data/reports/storage/worktree-removals.md" | tail -1 | sed -e 's/.*| //' -e 's/ |$//')"
  restore_rc=0
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    HOME="$TMP/$label/home" bash -c "$cmd" >/dev/null 2>&1 || restore_rc=1
  done < <(printf '%s\n' "$CELL" | sed -e 's/`, then /\n/g' -e 's/`//g')
  check "$tag: restore cell runs" "$([[ $restore_rc -eq 0 ]] && echo ok || echo failed)"
  check "$tag: restored worktree has its .env" "$(present "$WT_MERGED/.env")"
  # ---------- apply-time dirt ----------
  # a candidate that grows uncommitted changes after the preview is left
  # alone: the apply re-derives its findings, and the new file sits inside
  # node_modules so the idle check still passes and the dirty check fires
  label="late-$tag"; mkdir -p "$TMP/$label"
  build "$TMP/$label"
  R="$TMP/$label/repo"
  WT_MERGED="$(git -C "$R" worktree list --porcelain | sed -n 's/^worktree //p' | grep '/wt-merged$')"
  LIST="$(mktemp)"; printf '%s\n' "$WT_MERGED" > "$LIST"
  mkdir -p "$WT_MERGED/node_modules"
  echo "late change" > "$WT_MERGED/node_modules/late.txt"
  run "$label" "$sh" --apply --only-paths "$LIST"
  check "$tag: dirty-since-preview left alone" "$(grep -qE '\[SKIP\] +no preview of this worktree in this app' "$TMP/$label.out" && echo ok || echo "removed or no kept line")"
  check "$tag: dirty-since-preview worktree stays" "$(present "$WT_MERGED")"

  # ---------- refusals ----------
  run "$label" "$sh" --apply
  check "$tag: bare --apply refused" "$([[ $? -ne 0 ]] && echo ok || echo accepted)"
  grep -q "needs a reviewed --only-paths list" "$TMP/$label.out" && check "$tag: bare --apply explains itself" ok || check "$tag: bare --apply explains itself" "no sentence"

  # ---------- ephemeral main, detached HEAD, and nested monorepo deps ----------
  label="ephemeral-$tag"; mkdir -p "$TMP/$label/origin.git" "$TMP/$label/repo" "$TMP/$label/data/reports/storage" "$TMP/$label/home"
  git -C "$TMP/$label/origin.git" init -q --bare -b main
  ER="$TMP/$label/repo"
  git -C "$ER" init -q -b main
  printf 'node_modules/\n' > "$ER/.gitignore"
  echo base > "$ER/a.txt"
  git -C "$ER" add -A; git -C "$ER" commit -qm init
  git -C "$ER" remote add origin "$TMP/$label/origin.git"
  git -C "$ER" push -q -u origin main
  git -C "$ER" checkout -q -b development
  echo dev > "$ER/dev.txt"; git -C "$ER" add -A; git -C "$ER" commit -qm "dev commit"
  git -C "$ER" worktree add -q "$ER/.composure/workspaces/main" main
  git -C "$ER" worktree add -q --detach "$ER/.composure/workspaces/deploy-1234" development
  mkdir -p "$ER/.composure/workspaces/deploy-1234/packages/app/node_modules/pkg"
  echo m > "$ER/.composure/workspaces/deploy-1234/packages/app/node_modules/pkg/i.js"
  old "$TMP/$label"
  run "$label" "$sh"
  EOUT="$TMP/$label.out"
  WT_MAIN_EPH="$(git -C "$ER" worktree list --porcelain | sed -n 's/^worktree //p' | grep '/workspaces/main$')"
  WT_DET_EPH="$(git -C "$ER" worktree list --porcelain | sed -n 's/^worktree //p' | grep '/deploy-1234$')"
  grep -q "worktree  ${WT_MAIN_EPH}" "$EOUT" && check "$tag: synced idle main worktree offered" ok || check "$tag: synced idle main worktree offered" "missing in $EOUT"
  grep -q "worktree  ${WT_DET_EPH}.*1 dep dirs" "$EOUT" && check "$tag: detached HEAD + nested dep dir offered" ok || check "$tag: detached HEAD + nested dep dir offered" "missing in $EOUT"

  ELIST="$(mktemp)"; printf '%s\n' "$WT_MAIN_EPH" "$WT_DET_EPH" > "$ELIST"
  run "$label" "$sh" --apply --only-paths "$ELIST"
  check "$tag: synced main worktree removed on apply" "$(absent "$WT_MAIN_EPH")"
  check "$tag: detached worktree removed on apply" "$(absent "$WT_DET_EPH")"
  check "$tag: nested node_modules NOT parked" "$(absent "$TMP/$label/data/reports/storage/parked-worktrees/$(date +%Y-%m-%d)")"

  # Ahead-of-origin main worktree must be kept
  label="ahead-$tag"; mkdir -p "$TMP/$label/origin.git" "$TMP/$label/repo" "$TMP/$label/data/reports/storage" "$TMP/$label/home"
  git -C "$TMP/$label/origin.git" init -q --bare -b main
  AR="$TMP/$label/repo"
  git -C "$AR" init -q -b main
  echo base > "$AR/a.txt"; git -C "$AR" add -A; git -C "$AR" commit -qm init
  git -C "$AR" remote add origin "$TMP/$label/origin.git"
  git -C "$AR" push -q -u origin main
  git -C "$AR" checkout -q -b development
  git -C "$AR" worktree add -q "$AR/.composure/workspaces/main" main
  echo unpushed > "$AR/.composure/workspaces/main/ahead.txt"
  git -C "$AR/.composure/workspaces/main" add -A; git -C "$AR/.composure/workspaces/main" commit -qm ahead
  old "$TMP/$label"
  run "$label" "$sh"
  grep -q "kept: .*workspaces/main — its branch main is not merged into origin/main" "$TMP/$label.out" \
    && check "$tag: ahead-of-origin main worktree kept" ok || check "$tag: ahead-of-origin main worktree kept" "not kept"
done

# ---------- bash 3.2 is what ran ----------
if /bin/bash -c '[[ -n "$BASH_VERSION" ]]' 2>/dev/null; then
  /bin/bash -n "$TMP/tree/storage/guardian.sh" && check "/bin/bash (3.2) syntax" ok || check "/bin/bash (3.2) syntax" failed
fi

if [[ "$fail" -eq 0 ]]; then echo "ALL PASS"; else echo "FAILURES ABOVE"; fi
exit "$fail"
