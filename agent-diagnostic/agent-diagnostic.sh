#!/usr/bin/env bash
# agent-diagnostic.sh — the Agent Diagnostic: what led up to a freeze, read-only
# ---------------------------------------------------------------------------
# Purpose: after an unexpected restart or a freeze, rebuild the hour around
# the event from the records that already exist — crash reports, the unified
# log's purge lines, boots, the Memory Guard's log and flight-recorder ring,
# agent session files and every launchd job — and grade what it finds
# (confirmed / plausible / unknown) into TSVs the app parses into screens.
# The companion of the Cache Guardian: the Guardian is the before, this is
# the after. GitHub issue #19 is the spec; the blueprint lives in
# tasks-plans/research/drafts/blueprint-b-agent-diagnostic.md.
#
#   ./agent-diagnostic.sh                 # --all (timeline + jobs + setup + telemetry)
#   ./agent-diagnostic.sh --dry-run       # print the plan, write nothing
#   ./agent-diagnostic.sh --window EPOCH  # anchor the window on this moment instead of the newest report
#   ./agent-diagnostic.sh --jobs-only     # the launchd audit alone
#   ./agent-diagnostic.sh --timeline-only # crash reports + the timeline alone
#
# READ-ONLY, and it stays that way: it reads crash reports, the unified log
# (bounded by absolute --start/--end, never an unbounded query), launchd
# plists and the scripts they point at, agent config files and session
# files, the guard's own records. It never edits, stops, deletes or signals
# anything; it never EXECUTES what it inspects (scripts are read as text;
# a referenced path is only ever tested with [ -e ]). Its only writes are
# its own TSVs and run.log under <data root>/reports/agent-diagnostic/.
#
# Output (one run dir per invocation):
#   reports.tsv    the crash reports: header time vs file-name time, memory figures in GB
#   timeline.tsv   one axis: report / jetsam / purge / boot / gap / guard / recorder / session rows
#   jobs.tsv       every launchd job, its trigger, loaded state, purpose, and each finding with its line
#   setup.tsv      what Claude Code and Codex are set to, key names only where a key is sensitive
#   telemetry.tsv  what is recorded today, what is kept, what links records, what is missing
#   run.log        every step; its final line is "wrote: <the TSVs>", how the app finds them
#
# Runs under bash and /bin/bash (3.2): no associative arrays, no mapfile,
# no declare -g, no ${var,,}.

set -u

MODE="all"
WINDOW_ANCHOR=""
for arg in "$@"; do
  case "$arg" in
    --all) MODE="all" ;;
    --jobs-only) MODE="jobs" ;;
    --timeline-only) MODE="timeline" ;;
    --dry-run) DRY_RUN=1 ;;
    --window) : ;;
    --window=*) WINDOW_ANCHOR="${arg#--window=}" ;;
    *) if [ "${PREV_IS_WINDOW:-0}" = "1" ]; then WINDOW_ANCHOR="$arg"; PREV_IS_WINDOW=0; else PREV_IS_WINDOW=0; fi ;;
  esac
  [ "$arg" = "--window" ] && PREV_IS_WINDOW=1
done
DRY_RUN="${DRY_RUN:-0}"

# ---------- paths: the data root the suite already resolves (lib/paths.sh) ----------
HERE="$(cd "$(dirname "$0")" && pwd)"
_sparehold_paths="$(cd "$HERE/.." && pwd)/lib/paths.sh"
# shellcheck source=../lib/paths.sh
[[ -f "$_sparehold_paths" ]] && source "$_sparehold_paths"
SPAREHOLD_USER_ROOT="$(sparehold_user_root)"
ANALYZERS_ROOT="$(cd "$HERE/.." && pwd)"
[[ -f "${ANALYZERS_ROOT}/config.local.sh" ]] && source "${ANALYZERS_ROOT}/config.local.sh"
sparehold_apply_paths 2>/dev/null || true

# shared helpers, one enumeration each (never a second inventory)
# shellcheck source=../lib/launch-items.sh
[[ -f "${ANALYZERS_ROOT}/lib/launch-items.sh" ]] && source "${ANALYZERS_ROOT}/lib/launch-items.sh"

REPORTS_DIR="${SPAREHOLD_USER_ROOT}/reports/agent-diagnostic"
GUARD_LOG="${SPAREHOLD_USER_ROOT}/reports/memory/guard.log"
RING_FILE="${SPAREHOLD_USER_ROOT}/reports/memory/flight-recorder.tsv"
# the crash-report folder; ANALYZERS_DIAG_REPORTS replaces it (a test, or a Mac that keeps them elsewhere)
DIAG_REPORTS="${ANALYZERS_DIAG_REPORTS:-${HOME}/Library/Logs/DiagnosticReports}"

STAMP="$(date '+%Y-%m-%d')"
STAMP_HMS="$(date '+%H%M%S')"
RUN_DIR="${REPORTS_DIR}/${STAMP}/agent-diagnostic-${STAMP_HMS}"

# ---------- small time helpers (macOS date, bash 3.2) ----------

# iso_to_epoch "2026-11-21T10:10:10.000Z" -> epoch seconds ("" when unparsable)
iso_to_epoch() {
  local iso
  # the fraction goes, Z becomes +0000, and a colon offset (-05:00) loses it: BSD date's %z wants -0500
  iso="$(printf '%s' "$1" | sed -E 's/\.[0-9]+//; s/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')"
  date -j -f "%Y-%m-%dT%H:%M:%S%z" "$iso" "+%s" 2>/dev/null
}

# epoch_to_iso: the run speaks local time with its offset, like the reports do
epoch_to_iso() { date -r "$1" "+%Y-%m-%dT%H:%M:%S%z" 2>/dev/null; }

# file_name_time "Foo-2026-11-21-111733.ips" -> "2026-11-21T11:17:33+<local offset>" ("")
file_name_time() {
  local stamp
  stamp="$(printf '%s' "$1" | sed -nE 's/.*-([0-9]{4}-[0-9]{2}-[0-9]{2})-([0-9]{6})\.ips.*/\1T\2/p')"
  [[ -n "$stamp" ]] || return 0
  # HHMMSS becomes HH:MM:SS so iso_to_epoch can parse it
  stamp="$(printf '%s' "$stamp" | sed -E 's/T([0-9]{2})([0-9]{2})([0-9]{2})$/T\1:\2:\3/')"
  local offset
  offset="$(date '+%z')"
  printf '%s%s\n' "$stamp" "$offset"
}

# the .ips header's JSON fields, read with sed off the first line (no jq assumed)
ips_header_field() {  # $1 = file, $2 = field
  head -1 "$1" 2>/dev/null | sed -nE "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p"
}

# a first line for a report's body: panicString (panics), else the first exception line
ips_first_line() {
  sed -n '2,$p' "$1" 2>/dev/null | sed -nE 's/.*"panicString"[[:space:]]*:[[:space:]]*"([^"]{1,160}).*/\1/p
s/.*"exception"[[:space:]]*:[[:space:]]*\{[^}]*"signal"[[:space:]]*:[[:space:]]*"([^"]{1,60}).*/exception signal \1/p' | head -1
}

# ---------- the plan ----------

newest_report_epoch() {
  local best="" f iso t
  for f in "$DIAG_REPORTS"/*.ips; do
    [[ -e "$f" ]] || return 0
    iso="$(ips_header_field "$f" captureTime)"
    [[ -n "$iso" ]] || continue
    t="$(iso_to_epoch "$iso")"
    [[ -n "$t" ]] || continue
    if [[ -z "$best" || "$t" -gt "$best" ]]; then best="$t"; fi
  done
  printf '%s\n' "$best"
}

if [[ -n "$WINDOW_ANCHOR" ]]; then
  EVENT_EPOCH="$WINDOW_ANCHOR"
  EVENT_SOURCE="asked-for window anchor"
else
  EVENT_EPOCH="$(newest_report_epoch)"
  EVENT_SOURCE="the newest crash report's header time"
fi

if [[ -n "$EVENT_EPOCH" ]]; then
  WIN_START=$((EVENT_EPOCH - 3600))
  WIN_END=$((EVENT_EPOCH + 600))
else
  # nothing to anchor on (no reports readable): the jobs audit still runs
  WIN_START=0; WIN_END=0
fi

plan() {
  echo "== agent diagnostic — plan =="
  echo "mode: ${MODE}"
  echo "crash reports: ${DIAG_REPORTS} $([[ -r "$DIAG_REPORTS" ]] && echo readable || echo "NOT readable (no Full Disk Access for the engine?)")"
  if [[ -n "$EVENT_EPOCH" ]]; then
    echo "event: $(epoch_to_iso "$EVENT_EPOCH") (epoch $EVENT_EPOCH, from ${EVENT_SOURCE})"
    echo "window: $(epoch_to_iso "$WIN_START") .. $(epoch_to_iso "$WIN_END")"
  else
    echo "event: none found — the timeline will say the window could not be anchored"
  fi
  echo "guard log: ${GUARD_LOG} $([[ -r "$GUARD_LOG" ]] && echo readable || echo absent)"
  echo "flight recorder ring: ${RING_FILE} $([[ -r "$RING_FILE" ]] && echo readable || echo absent)"
  echo "launchd plists: $(launch_plist_files 2>/dev/null | grep -c .) files"
  echo "output would be: ${RUN_DIR}"
}

if [[ "$DRY_RUN" == "1" ]]; then
  plan
  exit 0
fi

mkdir -p "$RUN_DIR" || { echo "agent-diagnostic: could not create ${RUN_DIR}" >&2; exit 1; }
LOG="$RUN_DIR/run.log"
T_REPORTS="$RUN_DIR/reports.tsv"
T_TIMELINE="$RUN_DIR/timeline.tsv"
T_JOBS="$RUN_DIR/jobs.tsv"
T_SETUP="$RUN_DIR/run-setup.tsv"   # renamed to setup.tsv when complete, so a half run is never parsed
T_TELEMETRY="$RUN_DIR/telemetry.tsv"

note() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

note "== agent diagnostic ${MODE} =="
note "run dir: ${RUN_DIR}"

# ---------- 1. crash reports ----------

do_reports() {
  printf '%s\n' "# sparehold agent diagnostic reports v1: path bug_type event_iso event_epoch file_iso divergence_min proc panic_first_line" > "$T_REPORTS"
  local f iso t file_iso div proc first bug base
  for f in "$DIAG_REPORTS"/*.ips; do
    [[ -e "$f" ]] || break
    [[ -r "$f" ]] || { log "unreadable report skipped: ${f}"; continue; }
    iso="$(ips_header_field "$f" captureTime)"
    [[ -n "$iso" ]] || { note "no captureTime in $(basename "$f") — kept out of the reports table"; continue; }
    t="$(iso_to_epoch "$iso")"
    [[ -n "$t" ]] || continue
    base="$(basename "$f")"
    file_iso="$(file_name_time "$base")"
    div=""
    if [[ -n "$file_iso" ]]; then
      ft="$(iso_to_epoch "$file_iso")"
      [[ -n "$ft" ]] && div=$(( (ft - t) / 60 ))
    fi
    bug="$(ips_header_field "$f" bug_type)"
    proc="$(sed -n '2,$p' "$f" | sed -nE 's/.*"procName"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)"
    first="$(ips_first_line "$f")"
    # tabs never reach the TSV
    first="${first//$'\t'/  }"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$base" "$bug" "$iso" "$t" "${file_iso:--}" "${div:--}" "${proc:--}" "${first:--}" >> "$T_REPORTS"
  done
  note "reports.tsv: $(($(grep -c . "$T_REPORTS") - 1)) report row(s)"
}
[[ "$MODE" = "all" || "$MODE" = "timeline" ]] && do_reports

# ---------- 2. the timeline (rows collected in epoch order, gap-filled at the end) ----------

TL_TMP="$RUN_DIR/.timeline-parts"
: > "$TL_TMP"
tl_row() {  # kind epoch summary source
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$(epoch_to_iso "$2")" "$2" "$(printf '%s' "$3" | tr '\t' ' ' | cut -c 1-200)" "$4" >> "$TL_TMP"
}

do_timeline() {
  if [[ -z "$EVENT_EPOCH" ]]; then
    tl_row gap "$(date '+%s')" "no crash report readable — the window could not be anchored (Full Disk Access?)" "agent-diagnostic"
    return 0
  fi
  # report + jetsam rows from the reports table (the screen shows happened vs saved from reports.tsv)
  local line kind_min
  tail -n +2 "$T_REPORTS" 2>/dev/null | while IFS=$'\t' read -r base bug iso t file_iso div proc first; do
    [[ -n "$t" ]] || continue
    if [ "$t" -ge "$WIN_START" ] && [ "$t" -le "$WIN_END" ]; then
      case "$bug" in
        29) kind_min="jetsam (earlier memory baseline)" ;;
        *)  kind_min="report (bug_type ${bug:-unknown})" ;;
      esac
      tl_row report "$t" "${kind_min}: ${base} — ${proc:-unknown process} ${first:+· ${first}}" "DiagnosticReports"
      if [ "${div:--}" != "-" ] && [ "${div:-0}" -ge 5 ] 2>/dev/null; then
        tl_row report "$t" "saved ${div} min after it happened: the file name says ${file_iso}, the report's header says ${iso}" "DiagnosticReports"
      fi
    elif [ "$bug" = "29" ]; then
      tl_row jetsam "$t" "jetsam baseline outside the window: ${base} ${proc:+(${proc})}" "DiagnosticReports"
    fi
  done
  # the unified log, bounded by absolute times; the purge provider is the incident's free-disk witness
  # (ANALYZERS_DIAG_LOG_SHOW replaces the binary — a test points it at "true" so nothing real is read)
  local purge_lines
  purge_lines="$("${LOG_SHOW:-log}" show --start "$(date -r "$WIN_START" '+%Y-%m-%d %H:%M:%S')" --end "$(date -r "$WIN_END" '+%Y-%m-%d %H:%M:%S')" \
    --style syslog --predicate 'subsystem == "com.apple.CacheDelete" OR processImagePath CONTAINS "CacheDelete"' 2>/dev/null \
    | grep -E '[0-9]+([.][0-9]+)? ?(GB|MB)' | head -200)"
  if [[ -z "$purge_lines" ]]; then
    purge_lines="$("${LOG_SHOW:-log}" show --start "$(date -r "$WIN_START" '+%Y-%m-%d %H:%M:%S')" --end "$(date -r "$WIN_END" '+%Y-%m-%d %H:%M:%S')" \
      --style syslog 2>/dev/null | grep -iE 'free disk|purgeable' | grep -E '[0-9]+([.][0-9]+)? ?(GB|MB)' | head -200)"
  fi
  if [[ -n "$purge_lines" ]]; then
    printf '%s\n' "$purge_lines" | while IFS= read -r pl; do
      message="$(printf '%s' "$pl" | sed -E 's/^[0-9-]+ [0-9:.]+[^ ]* +//' | cut -c 1-160)"
      epoch="$(date -j -f "%Y-%m-%d %H:%M:%S" "$(printf '%s' "$pl" | awk '{print $1, substr($2, 1, 8)}')" "+%s" 2>/dev/null)"
      [[ -n "$epoch" ]] && tl_row purge "$epoch" "$message" "unified log"
    done
  else
    tl_row gap "$EVENT_EPOCH" "unified log no longer covers the window (its retention is short) — the free-disk series is gone" "unified log"
  fi
  # boots inside the window
  last reboot 2>/dev/null | head -30 | while IFS= read -r bl; do
    bepoch="$(printf '%s' "$bl" | sed -E 's/^reboot[[:space:]]+~[[:space:]]+//' | date -j -f "%a %b %d %H:%M:%S %Y" "$(cut -c1-24)" "+%s" 2>/dev/null)"
    [[ -n "$bepoch" ]] || continue
    if [ "$bepoch" -ge "$WIN_START" ] && [ "$bepoch" -le "$WIN_END" ]; then
      tl_row boot "$bepoch" "$(printf '%s' "$bl" | cut -c 1-160)" "last reboot"
    fi
  done
  # the guard's own record, when it was watching
  if [[ -r "$GUARD_LOG" ]]; then
    grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} ' "$GUARD_LOG" | while IFS= read -r gl; do
      gepoch="$(date -j -f "%Y-%m-%d %H:%M:%S" "$(printf '%s' "$gl" | cut -c 1-19)" "+%s" 2>/dev/null)" || continue
      [[ -n "$gepoch" ]] || continue
      if [ "$gepoch" -ge "$WIN_START" ] && [ "$gepoch" -le "$WIN_END" ]; then
        tl_row guard "$gepoch" "$(printf '%s' "$gl" | cut -c 21-180)" "guard.log"
      fi
    done
  fi
  # the flight recorder's ring, when it was on (the format the recorder pins: DEC-2, ten columns)
  if [[ -r "$RING_FILE" ]]; then
    tail -n +2 "$RING_FILE" | while IFS=$'\t' read -r iso epoch disk swap swapf wired compressed pressure procs top5; do
      [[ "$epoch" =~ ^[0-9]+$ ]] || continue
      if [ "$epoch" -ge "$WIN_START" ] && [ "$epoch" -le "$WIN_END" ]; then
        tl_row recorder "$epoch" "disk free ${disk:-?} GB, swap ${swap:-?} MB in ${swapf:-?} file(s), wired ${wired:-?} MB, compressed ${compressed:-?} MB, pressure ${pressure:-?}, ${procs:-?} processes, top ${top5:-unknown}" "flight-recorder.tsv"
      fi
    done
  fi
  # agent session files touched in the window (the documented folders only)
  for d in "${HOME}/.claude/projects" "${HOME}/.codex/sessions"; do
    [[ -d "$d" ]] || continue
    find "$d" -type f -newermt "@$WIN_START" ! -newermt "@$((WIN_END + 1))" 2>/dev/null | head -40 | while IFS= read -r sf; do
      sePOCH="$(stat -f %m "$sf" 2>/dev/null)" && tl_row session "$sePOCH" "agent session file touched: $(basename "$sf")" "$d"
    done
  done
}
[[ "$MODE" = "all" || "$MODE" = "timeline" ]] && do_timeline

# fold the parts into one axis, filling gaps >= 15 min with a gap row
fold_timeline() {
  printf '%s\n' "# sparehold agent diagnostic timeline v1: kind iso epoch summary source" > "$T_TIMELINE"
  sort -t $'\t' -k 3,3n -s "$TL_TMP" > "$TL_TMP.sorted" 2>/dev/null || cp "$TL_TMP" "$TL_TMP.sorted"
  mv "$TL_TMP.sorted" "$TL_TMP"
  prev=""
  while IFS=$'\t' read -r kind iso epoch summary source; do
    if [[ -n "$prev" ]] && [ "$epoch" -gt "$prev" ] 2>/dev/null; then
      delta=$((epoch - prev))
      if [ "$delta" -ge 900 ]; then
        mid=$(( (epoch + prev) / 2 ))
        printf '%s\t%s\t%s\t%s\t%s\n' "gap" "$(epoch_to_iso "$mid")" "$mid" "nothing recorded for $((delta / 60)) minutes" "agent-diagnostic" >> "$T_TIMELINE"
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$iso" "$epoch" "$summary" "$source" >> "$T_TIMELINE"
    prev="$epoch"
  done < "$TL_TMP"
  rm -f "$TL_TMP"
  note "timeline.tsv: $(($(grep -c . "$T_TIMELINE") - 1)) row(s) in the window"
}
[[ "$MODE" = "all" || "$MODE" = "timeline" ]] && fold_timeline

# ---------- 3. the launchd jobs audit ----------

do_jobs() {
  printf '%s\n' "# sparehold agent diagnostic jobs v1: label plist script trigger loaded last_run purpose check_id line_no line_text grade" > "$T_JOBS"
  while IFS= read -r plist; do
    [[ -n "$plist" ]] || continue
    label="$(basename "$plist" .plist)"
    target="$(plist_target "$plist" 2>/dev/null)"
    script="$target"
    # a job run BY an interpreter points at its script in ProgramArguments[1] —
    # auditing the interpreter's binary would audit bash, not the job
    case "$target" in
      */bash|*/sh|*/zsh|*/perl|*/ruby|*/python*|*/osascript|*/env|bash|sh|zsh|perl|ruby|python*|env)
        next="$(plutil -extract ProgramArguments.1 raw -o - "$plist" 2>/dev/null)"
        [[ -n "$next" ]] && script="$next" ;;
    esac
    trigger=""
    si="$(plutil -extract StartInterval raw -o - "$plist" 2>/dev/null)"
    [[ -n "$si" ]] && trigger="every ${si}s"
    if plutil -extract StartCalendarInterval xml1 -o - "$plist" >/dev/null 2>&1; then
      trigger="${trigger:+${trigger} + }scheduled (calendar)"
    fi
    plutil -extract RunAtLoad raw -o - "$plist" 2>/dev/null | grep -qi true && trigger="${trigger:+${trigger} + }at load"
    plutil -extract KeepAlive xml1 -o - "$plist" >/dev/null 2>&1 && trigger="${trigger:+${trigger} + }kept alive"
    [[ -z "$trigger" ]] && trigger="on demand"
    case "$plist" in
      /Library/LaunchDaemons/*) loaded="system (not checked)" ;;
      *) launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1 && loaded="loaded" || loaded="not loaded" ;;
    esac
    if [[ "$loaded" = "loaded" ]]; then
      last_run="$(launchctl print "gui/$(id -u)/${label}" 2>/dev/null | grep -E 'state:|last exit code' | head -2 | sed 's/^[[:space:]]*//' | tr '\n' ' ' | sed 's/  */ /g')"
    else
      last_run="-"
    fi
    purpose="unknown"
    if [[ -n "$script" && -f "$script" ]]; then
      purpose="$(sed -n '2,8p' "$script" | grep '^#' | head -1 | sed 's/^#[[:space:]]*//; s/[[:space:]]*$//')"
    fi
    [[ -z "$purpose" ]] && purpose="$(plutil -extract Comment raw -o - "$plist" 2>/dev/null)"
    [[ -z "$purpose" ]] && purpose="unknown"
    findings="$RUN_DIR/.findings.${label}.tsv"
    : > "$findings"

    if [[ -n "$script" && -r "$script" ]]; then
      # the checks read the script as text; nothing in it is ever run. grep -I
      # answers "is this text" without reading a binary into the line loop.
      if LC_ALL=C grep -qI . "$script" 2>/dev/null; then
      n=0
      while IFS= read -r line; do
        n=$((n + 1))
        shown="${line//$'\t'/  }"
        dangerous=0
        case "$shown" in
          *git\ push*|*git\ merge*|*git\ commit*|*gh\ pr\ merge*|*osascript*keystroke*|*cliclick*)
            printf '%s\t%s\t%s\t%s\n' "dangerous-action" "$n" "$shown" "confirmed" >> "$findings"
            dangerous=1 ;;
        esac
        if [ "$dangerous" -eq 0 ]; then
          for tool in git find curl ssh scp rsync osascript npm pnpm gh; do
            case "$shown" in
              *"$tool "*)
                [[ "$shown" == *timeout* || "$shown" == *"alarm"* ]] || \
                  printf '%s\t%s\t%s\t%s\n' "no-timeout" "$n" "$shown" "plausible" >> "$findings"
                break ;;
            esac
          done
        fi
        case "$shown" in
          *">> "*.log*|*"> "*.log*)
            # unbounded when no trim exists anywhere: a size check, a rotation,
            # or a tail/head that writes BACK (a bare `tail -5 log` only reads)
            grep -qE -- '-size|rotat|logrotate|(tail|head)[^>]*>' "$script" || \
              printf '%s\t%s\t%s\t%s\n' "unbounded-log" "$n" "$shown" "plausible" >> "$findings" ;;
        esac
        for token in $shown; do
          case "$token" in
            /*|~/*|[a-zA-Z]/?*)
              case "$token" in *\"*|*\'*) continue ;; esac
              p="${token%\"}"; p="${p%\'}"
              [[ -e "$p" ]] || printf '%s\t%s\t%s\t%s\n' "missing-path" "$n" "$shown" "confirmed" >> "$findings" ;;
          esac
        done
      done < "$script"
      # a script that never writes a log at all
      grep -qE '>>|tee |logger ' "$script" || grep -qE 'StandardOutPath|StandardErrorPath' "$plist" || \
        printf '%s\t%s\t%s\t%s\n' "no-log" "-" "the script writes no log and the plist names none" "confirmed" >> "$findings"
      fi
    elif [[ -n "$script" ]]; then
      [[ -e "$script" ]] || printf '%s\t%s\t%s\t%s\n' "missing-path" "-" "the plist's program is not on disk: ${script}" "confirmed" >> "$findings"
    fi
    # the job's own error log ending in the same message three times
    err_log="$(plutil -extract StandardErrorPath raw -o - "$plist" 2>/dev/null)"
    err_log="${err_log/#\~/$HOME}"
    if [[ -n "$err_log" && -r "$err_log" ]]; then
      repeated="$(tail -50 "$err_log" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.]+[[:space:]]*//; s/\[[0-9]+\]//g; s/[[:space:]]+$//' | sort | uniq -c | sort -rn | head -1)"
      count="${repeated%%[[:space:]]*}"
      if [ "${count:-0}" -ge 3 ] 2>/dev/null; then
        text="${repeated#*[[:space:]]}"
        printf '%s\t%s\t%s\t%s\n' "repeating-error" "-" "${text}" "confirmed" >> "$findings"
      fi
    fi
    # a job born near the event is a suspect, not a verdict
    if [[ -n "$EVENT_EPOCH" && -e "$plist" ]]; then
      born="$(stat -f %B "$plist" 2>/dev/null)"
      [[ -n "$born" ]] && delta=$((born - EVENT_EPOCH)) && [ "${delta#-}" -le 1800 ] && \
        printf '%s\t%s\t%s\t%s\n' "created-near-incident" "-" "created ${delta}s around the event" "plausible" >> "$findings"
    fi

    if [[ ! -s "$findings" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$plist" "${script:--}" "$trigger" "$loaded" "$last_run" "$purpose" "clean" "-" "-" "clean" >> "$T_JOBS"
    else
      while IFS=$'\t' read -r cid noline text grade; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$plist" "${script:--}" "$trigger" "$loaded" "$last_run" "$purpose" "$cid" "$noline" "${text//$'\t'/  }" "$grade" >> "$T_JOBS"
      done < "$findings"
    fi
    rm -f "$findings"
  done < <(launch_plist_files 2>/dev/null)
  note "jobs.tsv: $(($(grep -c . "$T_JOBS") - 1)) row(s) over $(launch_plist_files 2>/dev/null | grep -c .) job(s)"
}
[[ "$MODE" = "all" || "$MODE" = "jobs" ]] && do_jobs

# ---------- 4. the agent setup report (names only where a key is sensitive) ----------

do_setup() {
  printf '%s\n' "# sparehold agent diagnostic setup v1: tool topic key value grade citation" > "$T_SETUP"
  row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$T_SETUP"; }
  sensitive_key() {  # the name-only allowlist: the VALUE is never read
    printf '%s' "$1" | grep -Eiq '(key|token|secret|apikey|api_key|authorization|password|credential)'
  }
  # Claude Code: ~/.claude/settings.json (+ settings.local.json)
  for cfg in "${HOME}/.claude/settings.json" "${HOME}/.claude/settings.local.json"; do
    if [[ ! -e "$cfg" ]]; then
      row "claude-code" "config" "$cfg" "not found where the tool documents" "unknown" "-"
      continue
    fi
    mode="$(sed -n 's/.*"defaultMode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" | head -1)"
    row "claude-code" "permission-mode" "permissions.defaultMode" "${mode:-<not set>}" "confirmed" "${cfg}: permissions.defaultMode"
    for event in PreToolUse PostToolUse Stop SessionStart Notification UserPromptSubmit; do
      grep -q "\"${event}\"" "$cfg" && row "claude-code" "hook" "${event}" "hooked" "confirmed" "${cfg}: hooks.${event}"
    done
    grep -q -- "--dangerously-skip-permissions" "$cfg" && \
      row "claude-code" "permission-mode" "--dangerously-skip-permissions" "recorded in settings" "confirmed" "${cfg}"
    # concurrency-shaped env keys: the only keys whose VALUES are read
    grep -oE '"[A-Za-z0-9_]*(CONCURREN|MAX_PARALLEL|PARALLEL)[A-Za-z0-9_]*"[[:space:]]*:[[:space:]]*"?[A-Za-z0-9.]+' "$cfg" | while IFS= read -r hit; do
      k="$(printf '%s' "$hit" | sed -E 's/^"([^"]+)".*/\1/')"
      v="$(printf '%s' "$hit" | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"?//')"
      row "claude-code" "concurrency" "$k" "$v" "confirmed" "${cfg}: env ${k}"
    done
    # sensitive keys by name: the value string is never read
    grep -oE '"[A-Za-z0-9_]*"[[:space:]]*:' "$cfg" | sed 's/[":[:space:]]//g' | sort -u | while IFS= read -r k; do
      sensitive_key "$k" && row "claude-code" "secret" "$k" "<value not read>" "confirmed" "${cfg}: ${k} (name only)"
    done
    grep -q '"mcpServers"' "$cfg" && \
      sed -n '/"mcpServers"/,/^\}/p' "$cfg" | grep -oE '"[a-zA-Z0-9_.-]+"' | tr -d '"' | grep -v mcpServers | sort -u | head -20 | \
      while IFS= read -r s; do row "claude-code" "connector" "$s" "configured" "confirmed" "${cfg}: mcpServers.${s}"; done
  done
  # Codex: ~/.codex/config.toml
  cfg="${HOME}/.codex/config.toml"
  if [[ ! -e "$cfg" ]]; then
    row "codex" "config" "$cfg" "not found where the tool documents" "unknown" "-"
  else
    for k in approval_policy sandbox_mode; do
      v="$(grep -E "^${k}[[:space:]]*=" "$cfg" | head -1 | sed -E "s/^${k}[[:space:]]*=[[:space:]]*\"?([^\"#]*).*/\1/; s/[[:space:]]+$//")"
      [[ -n "$v" ]] && row "codex" "permission-mode" "$k" "$v" "confirmed" "${cfg}: ${k}"
    done
    grep -oE '^\[mcp_servers\.[A-Za-z0-9_.-]+\]' "$cfg" | sed 's/\[mcp_servers\.//; s/\]//' | sort -u | head -20 | \
      while IFS= read -r s; do row "codex" "connector" "$s" "configured" "confirmed" "${cfg}: mcp_servers.${s}"; done
    grep -inE '(key|token|secret|password)[[:space:]]*=' "$cfg" | while IFS= read -r hit; do
      k="$(printf '%s' "$hit" | sed -E 's/^[0-9]+://; s/[[:space:]]*=.*//')"
      row "codex" "secret" "$k" "<value not read>" "confirmed" "${cfg}: ${k} (name only)"
    done
  fi
  # sessions in the window + stale candidates, from the same folders the timeline reads
  if [[ -n "$EVENT_EPOCH" ]]; then
    boot="$(last reboot 2>/dev/null | head -2 | tail -1 | sed -E 's/^reboot[[:space:]]+~[[:space:]]+//' | cut -c1-24)"
    boot_epoch="$(date -j -f "%a %b %d %H:%M:%S %Y" "$boot" "+%s" 2>/dev/null)"
    for d in "${HOME}/.claude/projects" "${HOME}/.codex/sessions"; do
      [[ -d "$d" ]] || continue
      touched="$(find "$d" -type f -newermt "@$WIN_START" ! -newermt "@$((WIN_END + 1))" 2>/dev/null | grep -c .)"
      [[ "$touched" -gt 0 ]] && row "$(basename "$(dirname "$d")")" "sessions-in-window" "$d" "${touched} file(s) touched in the window" "confirmed" "file mtimes"
      if [[ -n "$boot_epoch" ]]; then
        stale="$(find "$d" -type f ! -newermt "@$boot_epoch" 2>/dev/null | grep -c .)"
        [[ "$stale" -gt 0 ]] && row "$(basename "$(dirname "$d")")" "stale-candidate" "$d" "${stale} file(s) last written before the last boot" "plausible" "file mtimes vs last reboot"
      fi
    done
  fi
  mv "$T_SETUP" "$RUN_DIR/setup.tsv"
  note "setup.tsv: $(($(grep -c . "$RUN_DIR/setup.tsv") - 1)) row(s)"
}
[[ "$MODE" = "all" ]] && do_setup

# ---------- 5. telemetry coverage (what exists on disk, said honestly) ----------

do_telemetry() {
  printf '%s\n' "# sparehold agent diagnostic telemetry v1: layer records retention links gap" > "$T_TELEMETRY"
  guard_lines=0
  [[ -r "$GUARD_LOG" ]] && guard_lines="$(grep -cE 'SPIKE|PRESSURE|KILLED' "$GUARD_LOG")"
  dumps=0
  [[ -d "${SPAREHOLD_USER_ROOT}/reports/memory" ]] && dumps="$(find "${SPAREHOLD_USER_ROOT}/reports/memory" -name 'guard-critical-*.log' 2>/dev/null | grep -c .)"
  ring=absent
  [[ -r "$RING_FILE" ]] && ring=present
  headroom=absent
  [[ -r "${SPAREHOLD_USER_ROOT}/reports/memory/headroom.status" ]] && headroom=present
  sessions=0
  [[ -d "${HOME}/.claude/projects" ]] && sessions="$(find "${HOME}/.claude/projects" -name '*.jsonl' 2>/dev/null | grep -c .)"
  printf '%s\n' \
    "host	guard.log lines: ${guard_lines}; headroom file: ${headroom}	~5 MB rotation	pid	$( [[ "$ring" = present ]] && echo "none — the flight recorder is on" || echo "wired/swap/free-disk over time: the flight recorder is the answer (off right now); the headroom file answers what the Mac can take on now" )" \
    "agent	session files on disk: ${sessions}	each tool's own policy	none across tools	a cross-tool correlation key does not exist" \
    "process	forensic dumps at critical pressure: ${dumps}	with the reports	pid	only the critical moment, never a series" \
    "workflow	rule-outcomes.jsonl (would-have rows)	$([[ -f "${SPAREHOLD_USER_ROOT}/reports/memory/rule-outcomes.jsonl" ]] && echo kept || echo absent)	rule id	nothing links a rule row to an agent session" \
    >> "$T_TELEMETRY"
  note "telemetry.tsv: 4 layer rows from disk"
}
[[ "$MODE" = "all" ]] && do_telemetry

# ---------- done ----------
note "done"
printf '%s\n' "wrote: reports.tsv timeline.tsv jobs.tsv setup.tsv telemetry.tsv" >> "$LOG"
echo "agent-diagnostic: wrote ${RUN_DIR}"
exit 0
