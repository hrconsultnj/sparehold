#!/usr/bin/env bash
# agent-diagnostic-test.sh — the Agent Diagnostic engine, on fixtures only.
# Nothing here reads the person's real crash reports, agent settings or
# launchd jobs: the crash reports, launchd folders, agent configs, guard log
# and flight-recorder ring are all fixtures in a scratch data root, aimed at
# the script with SPAREHOLD_DATA_DIR / ANALYZERS_DIAG_REPORTS /
# ANALYZERS_LAUNCH_DIRS. This proves: the timeline anchors on the HEADER time
# and shows a 67-minute save divergence as its own row (the issue's incident,
# inverted into a test); the jobs audit flags a missing path, an unbounded
# log, a dangerous line and a no-timeout call each with its line number; a
# clean job still gets its row; the planted secret VALUE appears nowhere;
# the ring joins the timeline; a dry run writes nothing; and the TSV headers
# are what the app's parsers expect. Runs under `bash` and /bin/bash (3.2).
#
# Usage: agent-diagnostic/tests/agent-diagnostic-test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../agent-diagnostic.sh"
FIXTURES="$HERE/fixtures"
[[ -f "$SCRIPT" ]] || { echo "SKIP: script not found"; exit 0; }

TMP="$(mktemp -d)"
# KEEP_TMP=1 leaves the scratch world up: debugging the engine against the
# exact fixtures the test builds (the world is printed at the end when kept)
trap 'if [[ "${KEEP_TMP:-0}" == "1" ]]; then echo "kept: $TMP"; else rm -rf "$TMP"; fi' EXIT
fail=0
check() { if [[ "$2" == "ok" ]]; then echo "PASS  $1"; else echo "FAIL  $1 ($2)"; fail=1; fi; }
# the engine runs under launchd's PATH in production, where grep is BSD grep —
# pin the same PATH here so the test judges the tool it will meet on the job
PATH="/usr/bin:/bin:/usr/sbin:/sbin"; export PATH

for sh in bash /bin/bash; do
  echo "== $sh =="

  # a fresh world every round (the loop runs the suite under bash, then /bin/bash)
  DATA="$TMP/data"; REPORTS="$TMP/DiagnosticReports"; LAUNCH="$TMP/LaunchAgents"; HOMEF="$TMP/home"
  rm -rf "$DATA" "$REPORTS" "$LAUNCH" "$HOMEF"
  mkdir -p "$DATA/reports/memory" "$DATA/reports/agent-diagnostic" "$REPORTS" "$LAUNCH" \
           "$HOMEF/.claude" "$HOMEF/.codex" "$HOMEF/Documents" "$HOMEF/Backup/Documents" "$HOMEF/Library/Logs"

  # the crash report whose HEADER time is 67 minutes before its FILE-NAME time.
  # The stamp is written in this Mac's own offset, so the divergence holds whatever the TZ is.
  offset="$(date '+%z')"
  capture_iso="$(date -v-134M '+%Y-%m-%dT%H:%M:%S').000${offset}"
  name_stamp="$(date -v-67M '+%Y-%m-%d-%H%M%S')"
  printf '{"bug_type":"210","captureTime":"%s","incident_id":"F1XTURE"}\n{"bug_type":"210","panicString":"lots of wired memory in the compressor","procName":"kernel_task","wired":"1300 MiB","pagesFree":82000}\n' \
    "$capture_iso" > "$REPORTS/MyApp-${name_stamp}.ips"
  # an earlier jetsam baseline, three hours BEFORE THE EVENT (times are event-relative
  # so the fixture world holds whatever minute the test runs at)
  event_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$(printf '%s' "$capture_iso" | sed -E 's/\.[0-9]+//')" "+%s")"
  jetsam_epoch=$((event_epoch - 3 * 3600))
  jetsam_iso="$(date -r "$jetsam_epoch" '+%Y-%m-%dT%H:%M:%S').000${offset}"
  printf '{"bug_type":"29","captureTime":"%s"}\n{"bug_type":"29","procName":"node","pagesFree":40000}\n' "$jetsam_iso" \
    > "$REPORTS/Node-$(date -r "$jetsam_epoch" '+%Y-%m-%d-%H%M%S').ips"

  # two launchd jobs: the careless one and the careful one
  cp "$FIXTURES/jobs-fixture/nightly-sync.sh" "$LAUNCH/nightly-sync.sh"; chmod +x "$LAUNCH/nightly-sync.sh"
  cp "$FIXTURES/jobs-fixture/clean-backup.sh" "$LAUNCH/clean-backup.sh"; chmod +x "$LAUNCH/clean-backup.sh"
  cat > "$LAUNCH/com.fixture.nightly-sync.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.fixture.nightly-sync</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>${LAUNCH}/nightly-sync.sh</string>
  </array>
  <key>StartInterval</key><integer>86400</integer>
</dict></plist>
PLIST
  cat > "$LAUNCH/com.fixture.clean-backup.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.fixture.clean-backup</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>${LAUNCH}/clean-backup.sh</string>
  </array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>3</integer></dict>
</dict></plist>
PLIST

  cp "$FIXTURES/claude-settings-fixture.json" "$HOMEF/.claude/settings.json"
  cp "$FIXTURES/codex-config-fixture.toml" "$HOMEF/.codex/config.toml"

  # the guard was watching, and the recorder was on — both INSIDE the window
  # (the window is captureTime - 60 min .. captureTime + 10 min), every figure
  # event-relative so the fixture world holds at any minute the test runs
  guard_line="$(date -r "$event_epoch" '+%Y-%m-%d %H:%M:%S') PRESSURE critical for 3 samples — watching"
  printf '%s\n' "$guard_line" > "$DATA/reports/memory/guard.log"
  {
    grep '^#' "$FIXTURES/ring-fixture.tsv"
    # slow-rate samples 50..40 min before the event, then the 10-second fast
    # stretch (disk falling, pressure 2) the recorder is for
    for back in 50 49 48 47 46 45 44 43 42 41 40; do
      epoch=$((event_epoch - back * 60))
      iso="$(date -r "$epoch" '+%Y-%m-%dT%H:%M:%S%z')"
      printf '%s\t%s\t%s\t0\t0\t5300\t2100\t1\t412\tXcode:2100;node:980\n' "$iso" "$epoch" "12.$((50 - back))"
    done
    for k in 9 8 7 6 5 4 3 2 1 0; do
      epoch=$((event_epoch - 360 - k * 10))
      iso="$(date -r "$epoch" '+%Y-%m-%dT%H:%M:%S%z')"
      printf '%s\t%s\t%s\t900\t1\t6100\t3200\t2\t431\tXcode:2100;node:1200\n' "$iso" "$epoch" "9.$((9 - k))"
    done
  } > "$DATA/reports/memory/flight-recorder.tsv"

  # a dry run: the plan is printed and NOTHING is written
  before="$(find "$DATA" -type f | wc -l | tr -d ' ')"
  out="$(SPAREHOLD_DATA_DIR="$DATA" HOME="$HOMEF" ANALYZERS_DIAG_REPORTS="$REPORTS" ANALYZERS_LAUNCH_DIRS="$LAUNCH" ANALYZERS_DIAG_LOG_SHOW=true \
        "$sh" "$SCRIPT" --dry-run 2>&1)"
  after="$(find "$DATA" -type f | wc -l | tr -d ' ')"
  check "[$sh] a dry run prints the plan and writes nothing" \
        "$([[ "$out" == *'== agent diagnostic — plan =='* && "$out" == *window:* && "$before" == "$after" ]] && echo ok || echo "$out")"

  # the real run
  out="$(SPAREHOLD_DATA_DIR="$DATA" HOME="$HOMEF" ANALYZERS_DIAG_REPORTS="$REPORTS" ANALYZERS_LAUNCH_DIRS="$LAUNCH" ANALYZERS_DIAG_LOG_SHOW=true \
        "$sh" "$SCRIPT" --window "$event_epoch" 2>&1)"
  run_dir="$(printf '%s\n' "$out" | sed -n 's/.*wrote //p')"
  [[ -d "$run_dir" ]] || { check "[$sh] the run wrote its folder" "no run dir ($out)"; continue; }

  T_REPORTS="$run_dir/reports.tsv"; T_TL="$run_dir/timeline.tsv"; T_JOBS="$run_dir/jobs.tsv"
  T_SETUP="$run_dir/setup.tsv"; T_TELE="$run_dir/telemetry.tsv"; LOG="$run_dir/run.log"

  check "[$sh] all five TSVs and run.log are written" \
        "$([[ -f "$T_REPORTS" && -f "$T_TL" && -f "$T_JOBS" && -f "$T_SETUP" && -f "$T_TELE" && -f "$LOG" ]] && echo ok || ls "$run_dir")"
  check "[$sh] run.log's final line is 'wrote:' with the TSVs the app looks for" \
        "$([[ "$(tail -1 "$LOG")" == 'wrote: reports.tsv timeline.tsv jobs.tsv setup.tsv telemetry.tsv' ]] && echo ok || tail -2 "$LOG")"

  # the header time, not the file time, anchors everything
  hdr_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$(printf '%s' "$capture_iso" | sed -E 's/\.[0-9]+//')" "+%s")"
  file_epoch="$((hdr_epoch + 67 * 60))"
  report_row="$(grep '^MyApp-' "$T_REPORTS" | head -1)"
  check "[$sh] reports.tsv carries the header time" \
        "$([[ "$(printf '%s' "$report_row" | cut -f4)" == "$hdr_epoch" ]] && echo ok || printf '%s\n' "$report_row")"
  check "[$sh] the save divergence is its own row in the timeline" \
        "$([[ "$(grep -c 'saved .* min after it happened' "$T_TL")" -ge 1 ]] && echo ok || grep -c . "$T_TL")"
  check "[$sh] reports.tsv says the file was saved 67 minutes after the header time" \
        "$([[ "$(awk -F '\t' '$1 ~ /^MyApp-/ { print $6 }' "$T_REPORTS")" == "67" ]] && echo ok || awk -F '\t' '$1 ~ /^MyApp-/ { print $6 }' "$T_REPORTS")"
  check "[$sh] the timeline's report row anchors on the header time, never the file name" \
        "$([[ "$(awk -F '\t' '$1 == "report" && $3 == '"$hdr_epoch"' { c++ } END { print c+0 }' "$T_TL")" -ge 1 && "$(awk -F '\t' '$1 == "report" && $3 == '"$file_epoch"' { c++ } END { print c+0 }' "$T_TL")" == 0 ]] && echo ok || awk -F '\t' '$1 == "report" { print $3 }' "$T_TL" | sort -u)"
  check "[$sh] the earlier jetsam report is a baseline row, present not dropped" \
        "$([[ "$(grep -c '^jetsam' "$T_TL")" -ge 1 ]] && echo ok || grep -c . "$T_TL")"

  # the jobs audit, line numbers and all (checks name the job, so the other
  # fixture's rows can never satisfy them by accident)
  check "[$sh] the careless job's missing paths are flagged confirmed, with line numbers" \
        "$([[ "$(awk -F '\t' '$1 == "com.fixture.nightly-sync" && $8 == "missing-path" && $11 == "confirmed"' "$T_JOBS" | wc -l | tr -d ' ')" -ge 2 && "$(awk -F '\t' '$1 == "com.fixture.nightly-sync" && $8 == "missing-path" { print $9; exit }' "$T_JOBS")" -ge 6 ]] && echo ok || awk -F '\t' '$8 == "missing-path"' "$T_JOBS")"
  check "[$sh] the careless job's unbounded log append is flagged with its line" \
        "$([[ "$(awk -F '\t' '$1 == "com.fixture.nightly-sync" && $8 == "unbounded-log" { c++ } END { print c+0 }' "$T_JOBS")" -ge 1 ]] && echo ok || awk -F '\t' '$8 == "unbounded-log"' "$T_JOBS")"
  check "[$sh] the dangerous git push is flagged confirmed, naming the line" \
        "$([[ "$(awk -F '\t' '$1 == "com.fixture.nightly-sync" && $8 == "dangerous-action" && $11 == "confirmed" && $10 ~ /git push/ { c++ } END { print c+0 }' "$T_JOBS")" -ge 1 ]] && echo ok || awk -F '\t' '$8 == "dangerous-action"' "$T_JOBS")"
  check "[$sh] a no-timeout call is flagged plausible" \
        "$([[ "$(awk -F '\t' '$1 == "com.fixture.nightly-sync" && $8 == "no-timeout" && $11 == "plausible" { c++ } END { print c+0 }' "$T_JOBS")" -ge 1 ]] && echo ok || echo none)"
  check "[$sh] the careful job is listed clean, not absent" \
        "$([[ "$(awk -F '\t' '$1 == "com.fixture.clean-backup" && $8 == "clean" { c++ } END { print c+0 }' "$T_JOBS")" -eq 1 ]] && echo ok || awk -F '\t' '$1 == "com.fixture.clean-backup"' "$T_JOBS")"
  check "[$sh] every job's trigger is a sentence, never a raw plist dump" \
        "$([[ "$(awk -F '\t' 'NR>1 && $4 == "" { c++ } END { print c+0 }' "$T_JOBS")" == 0 ]] && echo ok || echo "an empty trigger")"

  # the setup report: names only where a key is sensitive
  check "[$sh] the planted secret VALUE appears nowhere in the run's output" \
        "$([[ "$(grep -rc 'sk-fixture-secret-value\|ghp-fixture-token-value\|tok-fixture-codex-value' "$run_dir" | grep -v ':0' | grep -c .)" == 0 ]] && echo ok || grep -rl 'sk-fixture-secret-value' "$run_dir")"
  check "[$sh] the secret KEY names are present with their value unread" \
        "$([[ "$(grep -c '<value not read>' "$T_SETUP")" -ge 2 ]] && echo ok || grep secret "$T_SETUP")"
  check "[$sh] the concurrency key's value is read and cited (the one allowed)" \
        "$([[ "$(awk -F '\t' '$3 == "MAX_PARALLEL_SUBAGENTS" && $4 == "100" { c++ } END { print c+0 }' "$T_SETUP")" == 1 ]] && echo ok || awk -F '\t' '$3' "$T_SETUP")"
  check "[$sh] the permission mode is read" \
        "$([[ "$(awk -F '\t' '$2 == "permission-mode" && $4 == "acceptEdits" { c++ } END { print c+0 }' "$T_SETUP")" == 1 ]] && echo ok || echo missing)"
  check "[$sh] the hooks are named, PreToolUse among them" \
        "$([[ "$(awk -F '\t' '$2 == "hook" && $3 == "PreToolUse" { c++ } END { print c+0 }' "$T_SETUP")" == 1 ]] && echo ok || grep hook "$T_SETUP")"
  check "[$sh] the codex sandbox mode is read" \
        "$([[ "$(awk -F '\t' '$1 == "codex" && $3 == "sandbox_mode" && $4 == "workspace-write" { c++ } END { print c+0 }' "$T_SETUP")" == 1 ]] && echo ok || grep codex "$T_SETUP")"

  # guard + recorder rows join the axis
  check "[$sh] the guard's pressure line is in the window's timeline" \
        "$([[ "$(grep -c '^guard' "$T_TL")" -ge 1 ]] && echo ok || grep -c . "$T_TL")"
  check "[$sh] the recorder's ring rows are in the timeline" \
        "$([[ "$(grep -c '^recorder' "$T_TL")" -ge 1 ]] && echo ok || echo none)"

  # telemetry, said honestly from disk
  check "[$sh] the coverage table has the four layers" \
        "$([[ "$(awk -F '\t' 'NR>1 { print $1 }' "$T_TELE" | sort -u | grep -cE '^(host|agent|process|workflow)$')" == 4 ]] && echo ok || cat "$T_TELE")"

  # every row is exactly the shape the parsers expect
  check "[$sh] every jobs row has exactly 11 fields" \
        "$([[ "$(awk -F '\t' 'NR>1 && NF != 11 { c++ } END { print c+0 }' "$T_JOBS")" == 0 ]] && echo ok || awk -F '\t' 'NR>1 && NF != 11 { print NF }' "$T_JOBS")"
done

# the TSV headers, exactly what the app's parsers expect
hdr_check() {
  for sh in bash /bin/bash; do :; done
  DATA2="$TMP/hdr"; mkdir -p "$DATA2/reports/memory"
  out="$(SPAREHOLD_DATA_DIR="$DATA2" HOME="$TMP/empty-home" ANALYZERS_DIAG_REPORTS="$TMP/none" ANALYZERS_LAUNCH_DIRS="$TMP/none" \
        bash "$SCRIPT" --dry-run 2>/dev/null)"
  check "the headers are pinned in the script (jobs 11, timeline 5, setup 6, telemetry 4, reports 8 fields)" \
        "$([[ "$(grep -c 'sparehold agent diagnostic jobs v1: label plist script trigger loaded last_run purpose check_id line_no line_text grade' "$SCRIPT")" == 1 && \
              "$(grep -c 'sparehold agent diagnostic timeline v1: kind iso epoch summary source' "$SCRIPT")" == 1 && \
              "$(grep -c 'sparehold agent diagnostic setup v1: tool topic key value grade citation' "$SCRIPT")" == 1 && \
              "$(grep -c 'sparehold agent diagnostic telemetry v1: layer records retention links gap' "$SCRIPT")" == 1 && \
              "$(grep -c 'sparehold agent diagnostic reports v1: path bug_type event_iso event_epoch file_iso divergence_min proc panic_first_line' "$SCRIPT")" == 1 ]] && echo ok || grep 'sparehold .* v1:' "$SCRIPT")"
}

hdr_check
echo
echo "$([[ $fail -eq 0 ]] && echo "ALL PASS" || echo "FAILURES ABOVE")"
exit $fail
