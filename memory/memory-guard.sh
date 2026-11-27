#!/usr/bin/env bash
# guard.sh — RAM spike listener for macOS (companion to analyze.sh / auto-clean.sh)
# ---------------------------------------------------------------------------
# Watches kernel memory-pressure and per-process growth so a runaway dev
# process (playwright fleet, leaking node build, forgotten bundler) never
# freezes the machine mid-meeting again.
#
#   * WARNING pressure  → macOS notification naming the top offenders.
#   * CRITICAL pressure → dumps a forensic snapshot to ~/memory-reports/,
#                         then kills the BIGGEST safelisted offender.
#   * Hard cap          → a single safelisted process above --hard-cap-mb
#                         (default 6144) is killed even at normal pressure —
#                         this is the "package/playwright spiked" scenario.
#   * Spike detection   → a safelisted process growing >400 MB per tick is
#                         logged + notified before it becomes a problem.
#   * Flight recorder   → GUARD_FLIGHT_RECORDER (0 = off, the default): one
#                         memory-sample line per minute into the ring file
#                         reports/memory/flight-recorder.tsv (1 MiB cap, faster
#                         under pressure) so a freeze can be reconstructed.
#   * Dev pass          → every GUARD_DEV_SWEEP_SECS (default 120) it starts
#                         `memory-auto-clean.sh --apply --dev --quiet`, which
#                         stops dev tooling that has gone IDLE — emulators and
#                         simulators nobody drives, Gradle/Kotlin daemons with
#                         no build running, leftovers of failed builds, dev
#                         servers nobody is connected to. Busy tooling is never
#                         touched. 0 = off.
#
# ONLY dev tooling is ever killed (node/npx/bun/next/vite/playwright/headless
# chromium). Zoom, browsers, VS Code, Docker, screen recording and all system
# processes are on a hard never-kill list, and so is every live coding session
# (an agent in lib/coding-agents.tsv) with everything below it: its MCP servers,
# its dev servers, the commands it waits on. If that list cannot be read the
# guard stops nothing and says so (it still alerts).
#
# Designed to run forever under launchd (KeepAlive). Test with:
#   ./memory-guard.sh --once --verbose
#
# Pause/resume WITHOUT unloading the agent (e.g. during a heavy legit build):
#   touch ~/mac-analyzers/reports/memory/.guard-paused
#   rm    ~/mac-analyzers/reports/memory/.guard-paused
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

LOG_DIR="${SPAREHOLD_USER_ROOT}/reports/memory"
LOG_FILE="${LOG_DIR}/guard.log"
STATE_FILE="${LOG_DIR}/.guard-prev-snapshot"
CPU_STATE_FILE="${LOG_DIR}/.guard-cpu-hits"
PAUSE_FLAG="${LOG_DIR}/.guard-paused"

# optional per-machine config (gitignored) — see config.example.sh at repo root
ANALYZERS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Settings live in the user folder. When the engine runs from inside the
# app bundle, that bundle is replaced wholesale on every update, so the
# user copy is the one that must win.
[[ -f "${ANALYZERS_ROOT}/config.local.sh" ]] && source "${ANALYZERS_ROOT}/config.local.sh"
# shellcheck source=../lib/paths.sh
source "${ANALYZERS_ROOT}/lib/paths.sh"
sparehold_apply_paths

# ---------- tunables (env or flags) ----------
INTERVAL="${GUARD_INTERVAL:-15}"              # seconds between ticks
WARN_COOLDOWN="${GUARD_WARN_COOLDOWN:-300}"   # min seconds between WARNING notifications
KILL_COOLDOWN="${GUARD_KILL_COOLDOWN:-60}"    # min seconds between kills
HARD_CAP_MB="${GUARD_HARD_CAP_MB:-6144}"      # single safelisted proc above this → kill at ANY pressure
HARDCAP_KILL="${GUARD_HARDCAP_KILL:-1}"       # 0 = over-cap NOTIFIES instead of killing
PRESSURE_KILL="${GUARD_PRESSURE_KILL:-1}"     # 0 = critical pressure NOTIFIES instead of killing
SPIKE_MB="${GUARD_SPIKE_MB:-400}"             # growth per tick that flags a runaway…
SPIKE_MIN_MB="${GUARD_SPIKE_MIN_MB:-1024}"    # …once the process is at least this big
CPU_HOG_PCT="${GUARD_CPU_HOG_PCT:-150}"       # %CPU that counts as a hog…
CPU_HOG_TICKS="${GUARD_CPU_HOG_TICKS:-3}"     # …sustained for this many ticks → notify (NEVER kill)
DEV_SWEEP_SECS="${GUARD_DEV_SWEEP_SECS:-120}" # run the idle-dev-tooling pass this often (0 = off)
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
FALLBACK_FILE="${LOG_DIR}/.guard-fallback.tsv"   # what the app's rules engine tells this script (lib/guard-select.sh)

# ---------- flight recorder (off by default; the app writes these into config.local.sh's managed block) ----------
# Records one memory-sample line per interval into a ring file so the hour
# before a freeze can be reconstructed (Agent Diagnostic). Background work
# only: it runs after every guard duty in the tick, appends and truncates
# ONLY its own file below, and never goes near the system log (the first
# thing to stall in a memory hang). Stock macOS reads: vm_stat, sysctl
# vm.swapusage, df -k /, stat, tail, awk, date. bash 3.2 only.
FLIGHT_RECORDER="${GUARD_FLIGHT_RECORDER:-0}"              # 1 = record (0 = off, the default)
FLIGHT_INTERVAL="${GUARD_FLIGHT_INTERVAL:-60}"             # seconds between samples, slow rate
FLIGHT_FAST_INTERVAL="${GUARD_FLIGHT_FAST_INTERVAL:-10}"   # fast rate while pressure >= 2 or swap grows
FLIGHT_MAX_BYTES="${GUARD_FLIGHT_MAX_BYTES:-1048576}"      # 1 MiB ring cap
RING_FILE="${LOG_DIR}/flight-recorder.tsv"                 # the only file the recorder writes
# The headroom file: the present state an agent can check before spawning more
# work (the Agent Diagnostic's "during" half). Default ON — it records nothing
# new (the Monitor shows the same figures) and keeps no history; one small
# file, atomically replaced every tick. GUARD_HEADROOM=0 stops the writes and
# removes the file: an agent must never read a stale "fine" as current.
HEADROOM="${GUARD_HEADROOM:-1}"
HEADROOM_FILE="${LOG_DIR}/headroom.status"
RING_HEADER='# sparehold flight recorder v1: iso epoch disk_free_gb swap_used_mb swap_files wired_mb compressed_mb pressure procs top5'
# the copy the app writes (the data root's, the one sparehold_apply_paths prefers)
CONFIG_LOCAL="${SPAREHOLD_USER_ROOT}/config.local.sh"
LAST_FLIGHT_TS=0
LAST_FLIGHT_SWAP_MB=0

# what the guard is ALLOWED to kill (dev tooling only). Binary names are
# anchored ((^|/)name( |$)) so `bun` can't substring-match "usbaudio.bundle".
KILLABLE_RE='(^|/)(node|npm|npx|bun|tsx|deno)( |$)|next-server|next dev|vite|esbuild|webpack|turbo|tsup|vitest|jest|playwright|headless_shell|--headless|ms-playwright'
# what it must NEVER kill, even if it also matches above (checked second, wins)
PROTECT_RE='.local/bin/claude|(^|/)claude( |$)|Claude.app|Visual Studio Code|Code Helper|zoom.us|ZoomCef|Docker|OrbStack|Opera.app|Google Chrome.app|Safari|WindowServer|loginwindow|mds|Finder|screencapture|screencaptureui|QuickTime|CoreServices|iTerm'
[[ -n "${ANALYZERS_PROTECT_EXTRA:-}" ]] && PROTECT_RE="${PROTECT_RE}|${ANALYZERS_PROTECT_EXTRA}"

# The protect list is the guard's most important safety property, and an
# invalid pattern makes awk abort mid-tick — which would protect NOTHING
# while everything still looks healthy. Refuse to run instead.
if ! awk -v re="$PROTECT_RE" 'BEGIN { if ("probe" ~ re) exit 0; exit 0 }' </dev/null 2>/dev/null; then
  echo "FATAL: protected-apps list is not a valid pattern; refusing to start." >&2
  if [[ -f "${ANALYZERS_ROOT}/lib/notify.sh" ]]; then
    # shellcheck disable=SC1091
    source "${ANALYZERS_ROOT}/lib/notify.sh"
    notify "Memory Guard did not start" \
      "Your protected-apps list has an invalid entry, so nothing would be protected. Open Settings → Memory and fix the list." \
      2>/dev/null || true
  fi
  exit 78
fi

# the live AI-session exemption (CONTRIBUTING.md invariant 3), the same list the app and the cleaners read. Not being
# able to read it is never read as "no session is running": nothing is stopped (kill_proc), alerts continue.
LIVE_SESSIONS_OK=0
# shellcheck source=../lib/live-sessions.sh
if [[ -r "${ANALYZERS_ROOT}/lib/live-sessions.sh" ]] && source "${ANALYZERS_ROOT}/lib/live-sessions.sh" 2>/dev/null; then
  LIVE_SESSIONS_OK=1
fi
GUARD_SELECT_OK=0
# shellcheck source=../lib/guard-select.sh
if [[ -r "${ANALYZERS_ROOT}/lib/guard-select.sh" ]] && source "${ANALYZERS_ROOT}/lib/guard-select.sh" 2>/dev/null; then
  GUARD_SELECT_OK=1
fi

# What the app's rules engine tells this script, when it tells anything: only that the guard is paused (the Never Close
# list is read where the candidates are chosen). The file can narrow what the guard does and nothing else: the cap and the
# stop switches come from config.local.sh alone, so an old or wrong file cannot lower a cap or turn a stop on.
# Read again at every tick: the app writes the file whenever the lists change.
FALLBACK_PAUSE=0
read_fallback() {
  [[ "$GUARD_SELECT_OK" -eq 1 && -r "$FALLBACK_FILE" ]] || return 0
  local fb
  fb="$(guard_fallback_value "$FALLBACK_FILE" pause)"; FALLBACK_PAUSE=0; [[ "$fb" == 1 ]] && FALLBACK_PAUSE=1
  return 0
}

# The four FLIGHT knobs are re-read from config.local.sh every tick (one awk
# pass over the file the guard already reads) so the app's switch takes effect
# at the next tick without restarting the guard — the same reason read_fallback
# re-reads the pause. Only a plain integer changes a value; a commented line,
# quotes or anything else keep what the guard started with.
flight_read_knobs() {
  [[ -r "$CONFIG_LOCAL" ]] || return 0
  local line
  line="$(awk -v q="\"'" '
    # q holds the two quote characters: building the class from it strips both
    # kinds of quoting (the string alone would match a two-char sequence only)
    function flightval() { v = $0; sub(/^[^=]*=/, "", v); sub(/[[:space:]]*#.*$/, "", v); gsub("[" q "]", "", v); gsub(/[[:space:]]/, "", v) }
    /^[[:space:]]*GUARD_FLIGHT_RECORDER=/     { flightval(); rec = v }
    /^[[:space:]]*GUARD_FLIGHT_INTERVAL=/     { flightval(); slow = v }
    /^[[:space:]]*GUARD_FLIGHT_FAST_INTERVAL=/{ flightval(); fast = v }
    /^[[:space:]]*GUARD_FLIGHT_MAX_BYTES=/    { flightval(); cap = v }
    /^[[:space:]]*GUARD_HEADROOM=/            { flightval(); hr = v }
    # "|", not a tab: empty leading fields must survive the read, and tab is
    # IFS whitespace — a config carrying only GUARD_HEADROOM would collapse
    # the four empties and land the value in a recorder knob
    END { printf "%s|%s|%s|%s|%s\n", rec, slow, fast, cap, hr }
  ' "$CONFIG_LOCAL" 2>/dev/null)"
  local rec slow fast cap hr
  IFS='|' read -r rec slow fast cap hr <<<"$line"
  case "$rec" in 0|1) FLIGHT_RECORDER="$rec" ;; esac
  case "$slow" in ''|*[!0-9]*) ;; *) FLIGHT_INTERVAL="$slow" ;; esac
  case "$fast" in ''|*[!0-9]*) ;; *) FLIGHT_FAST_INTERVAL="$fast" ;; esac
  case "$cap" in ''|*[!0-9]*) ;; *) FLIGHT_MAX_BYTES="$cap" ;; esac
  case "$hr" in 0|1) HEADROOM="$hr" ;; esac
  return 0
}

# swap in use, whole MB — one stock read, 0 when it cannot be read
flight_swap_mb() {
  sysctl -n vm.swapusage 2>/dev/null | awk '
    $4 == "used" { v = $6; sub(/M$/, "", v); printf "%d", v; seen = 1 }
    END { if (!seen) printf "0" }'
}

# wired and compressed memory, whole MB, one vm_stat read ("wired comp") —
# the shared read behind the recorder's sample and the headroom file, so the
# two never drift apart on what the figures mean
flight_vm_mb() {
  vm_stat 2>/dev/null | awk '
    /page size of/   { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) page = $i }
    /^Pages wired down/ { v = $NF; sub(/\./, "", v); wired = v }
    /^Pages (occupied|stored) by compressor/ { v = $NF; sub(/\./, "", v); comp = v }
    END {
      if (page == "") page = 16384
      printf "%d %d", (wired == "" ? 0 : wired) * page / 1048576, (comp == "" ? 0 : comp) * page / 1048576
    }'
}

# $1 = pressure level, $2 = now (epoch), $3 = the tick's ps table (reused —
# the recorder spawns no ps of its own). One TSV line appended straight to the
# ring file and flushed, then the size cap keeps the newest half.
flight_record() {
  flight_read_knobs
  [[ "$FLIGHT_RECORDER" == "1" ]] || return 0
  local level="${1:-1}" now="${2:-0}" ptable="${3:-}"
  local swap_mb="" elapsed=$((now - LAST_FLIGHT_TS))
  if [[ "$level" -ge 2 ]]; then
    [[ "$elapsed" -ge "$FLIGHT_FAST_INTERVAL" ]] || return 0
  elif [[ "$elapsed" -lt "$FLIGHT_FAST_INTERVAL" ]]; then
    return 0
  elif [[ "$elapsed" -lt "$FLIGHT_INTERVAL" ]]; then
    # inside the slow window but past the fast one: only growth of swap since
    # the previous sample pulls the rate up (the one extra read, recorder-only)
    swap_mb="$(flight_swap_mb)"
    [[ "$swap_mb" -gt "$LAST_FLIGHT_SWAP_MB" ]] || return 0
  fi

  # figures, each from one stock macOS read; a read that fails leaves 0
  local iso
  iso="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  [[ ${#iso} -eq 24 ]] && iso="${iso:0:22}:${iso:22}"     # +0100 → +01:00
  [[ -n "$swap_mb" ]] || swap_mb="$(flight_swap_mb)"
  [[ -n "$swap_mb" ]] || swap_mb=0
  local swap_files=0 sf
  for sf in /System/Volumes/VM/swapfile*; do [[ -e "$sf" ]] && swap_files=$((swap_files + 1)); done
  local vm_parts wired_mb=0 comp_mb=0
  vm_parts="$(flight_vm_mb)"
  wired_mb="${vm_parts%% *}"; comp_mb="${vm_parts#* }"
  [[ -n "$wired_mb" ]] || wired_mb=0
  [[ -n "$comp_mb" ]] || comp_mb=0
  local disk_gb
  disk_gb="$(df -k / 2>/dev/null | awk 'NR == 2 { printf "%.1f", $4 / 1048576 }')"
  [[ -n "$disk_gb" ]] || disk_gb=0
  local procs=0 top5=""
  if [[ -n "$ptable" ]]; then
    procs="$(printf '%s\n' "$ptable" | awk 'END { print NR }')"
    # top 5 by RSS, command NAME only — never args or paths
    top5="$(printf '%s\n' "$ptable" | sort -k2,2 -rn | awk '
      NF >= 3 { n = split($3, p, "/"); line = line p[n] ":" int($2 / 1024) ";"; if (++kept >= 5) exit }
      END { sub(/;$/, "", line); print line }')"
    [[ -n "$top5" ]] || top5="-"
  fi

  # append directly to the ring (never through the system log) and flush
  [[ -f "$RING_FILE" ]] || printf '%s\n' "$RING_HEADER" > "$RING_FILE" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$iso" "$now" "$disk_gb" "$swap_mb" "$swap_files" "$wired_mb" "$comp_mb" \
    "$level" "$procs" "$top5" >> "$RING_FILE" 2>/dev/null || return 0
  sync -f "$RING_FILE" 2>/dev/null || sync    # the line is on disk before we return
  LAST_FLIGHT_TS=$now
  LAST_FLIGHT_SWAP_MB=$swap_mb
  [[ "$VERBOSE" -eq 1 ]] && echo "flight recorder: sample written to $RING_FILE"
  # ring cap: over the limit, keep the header and the newest half of the lines
  # (tmp + mv, so a reader never sees a torn file; the guard's single-writer
  # lock is the only lock this needs)
  local size tmp
  size="$(stat -f '%z' "$RING_FILE" 2>/dev/null)"
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  if [[ "$size" -gt "$FLIGHT_MAX_BYTES" ]]; then
    tmp="${RING_FILE}.tmp"
    awk 'NR == FNR { total = NR; next } FNR == 1 { print; next } FNR > total / 2 { print }' \
      "$RING_FILE" "$RING_FILE" > "$tmp" 2>/dev/null && mv -f "$tmp" "$RING_FILE"
  fi
  return 0
}

ONCE=0
VERBOSE=0
ORIG_ARGS="$*"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)         ONCE=1 ;;
    --verbose)      VERBOSE=1 ;;
    --interval)     INTERVAL="${2:-15}"; shift ;;
    --hard-cap-mb)  HARD_CAP_MB="${2:-6144}"; shift ;;
    -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$LOG_DIR"

# ---------- interactive control panel (double-click / bare terminal run) ----------
# launchd starts the daemon with no args AND no TTY, so it skips this.
if [[ -z "$ORIG_ARGS" ]] && { [[ -t 0 ]] || [[ "${FORCE_INTERACTIVE:-0}" == "1" ]]; }; then
  GUARD_PID="$(cat "${LOG_DIR}/.guard.lock" 2>/dev/null)"
  if [[ -n "$GUARD_PID" ]] && kill -0 "$GUARD_PID" 2>/dev/null; then
    GUARD_STATE="RUNNING (pid ${GUARD_PID})$([[ -e "$PAUSE_FLAG" ]] && echo ' — PAUSED')"
  else
    GUARD_STATE="NOT RUNNING"; GUARD_PID=""
  fi
  echo ""
  echo "  memory-guard — RAM spike listener"
  echo "  ---------------------------------"
  echo "  Background guard: ${GUARD_STATE}"
  echo ""
  echo "  1) Show recent activity (last 20 log lines)"
  echo "  2) Pause guard actions"
  echo "  3) Resume guard actions"
  echo "  4) Single diagnostic tick (verbose; only if guard not running)"
  echo "  q) Quit"
  echo ""
  read -rp "  Choose [1]: " choice
  case "${choice:-1}" in
    1) echo ""; tail -20 "$LOG_FILE" 2>/dev/null || echo "  (no log yet)" ;;
    2) touch "$PAUSE_FLAG"; echo "  paused — guard keeps polling but takes no action." ;;
    3) rm -f "$PAUSE_FLAG"; echo "  resumed." ;;
    4) if [[ -n "$GUARD_PID" ]]; then
         echo "  guard already running (pid ${GUARD_PID}) — pause/uninstall it first."
       else
         ONCE=1; VERBOSE=1
       fi ;;
    q|Q) exit 0 ;;
    *) echo "  Unknown choice '${choice}' — exiting."; exit 2 ;;
  esac
  if [[ "$ONCE" -ne 1 ]]; then
    echo ""
    read -rp "  Done — press Enter to close this window… " _
    exit 0
  fi
fi

# ---------- single-instance lock ----------
LOCK_FILE="${LOG_DIR}/.guard.lock"
if [[ -e "$LOCK_FILE" ]] && kill -0 "$(cat "$LOCK_FILE" 2>/dev/null)" 2>/dev/null; then
  echo "guard already running (pid $(cat "$LOCK_FILE")); exiting." >&2
  exit 0
fi
echo "$$" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE" "$STATE_FILE" "$CPU_STATE_FILE"; exit 0' EXIT INT TERM

# ---------- helpers ----------
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
  [[ "$VERBOSE" -eq 1 ]] && echo "$*"
}

# shared notifier — with alerter installed, clicking the notification opens
# this script's log (see lib/notify.sh); inline fallback keeps it standalone.
if [[ -f "${ANALYZERS_ROOT}/lib/notify.sh" ]]; then
  source "${ANALYZERS_ROOT}/lib/notify.sh"
else
  notify() {  # title, message, [sound]
    command -v osascript >/dev/null 2>&1 || return 0
    osascript -e "display notification \"${2//\"/\'}\" with title \"${1//\"/\'}\" sound name \"${3:-Glass}\"" >/dev/null 2>&1 || true
  }
fi

# short human label for a ps args string
short_name() {
  echo "$1" | awk '{ n=split($1, p, "/"); printf "%s", p[n]; if (NF>1) printf " %s", $2 }' | cut -c1-60
}

# SIGTERM → wait ≤5s → SIGKILL. Args: pid, rss_kb, reason, args
kill_proc() {
  local pid="$1" rsskb="$2" reason="$3" args="$4" name
  name="$(short_name "$args")"
  # fail closed: without the list of coding agents no process can be told from a live session's, so none is stopped. Asked
  # again at the moment of the stop (not only at start): the list can be gone or emptied while the guard runs.
  if [[ "$LIVE_SESSIONS_OK" -ne 1 ]] || ! live_session_list_ok; then
    log "KILL-SKIPPED [$reason] pid=$pid  the list of coding agents could not be read  $args"
    return 1
  fi
  kill -TERM "$pid" 2>/dev/null || { log "KILL-FAIL pid=$pid already gone"; return 1; }
  local i=0
  while kill -0 "$pid" 2>/dev/null && [[ $i -lt 5 ]]; do sleep 1; i=$((i+1)); done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  LAST_KILL_TS=$(date +%s)
  log "KILLED [$reason] pid=$pid rss=$((rsskb/1024))MB  $args"
  # notification: process identity as SUBTITLE, plain-English what/why as body
  # (log line above stays machine-parseable — the app/plugin parse it)
  local gb; gb=$(awk -v kb="$rsskb" 'BEGIN{printf "%.1f", kb/1048576}')
  notify "Memory Guard — process stopped" \
    "Was using ${gb} GB of memory (${reason}). Click to see the details." \
    "Sosumi" "" "${name}"
}

# forensic snapshot for post-mortems ("what actually spiked?")
dump_forensics() {
  local f
  f="${LOG_DIR}/$(date +%Y-%m-%d)/guard-critical-$(date +%H%M%S).log"
  mkdir -p "$(dirname "$f")"
  {
    echo "=== memory guard forensic snapshot: $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo "--- pressure ---"
    sysctl kern.memorystatus_vm_pressure_level vm.swapusage 2>/dev/null
    top -l 1 -n 0 2>/dev/null | grep -E "PhysMem|VM:"
    echo "--- top 25 by RSS ---"
    ps axo rss,pid,ppid,etime,args | sort -rn | head -25
  } > "$f"
  log "FORENSICS written: $f"
}

# ---------- main loop ----------
LAST_WARN_TS=0
LAST_KILL_TS=0
LAST_DEV_SWEEP_TS=0
log "guard started (pid $$, interval=${INTERVAL}s, hard-cap=${HARD_CAP_MB}MB)"

# rotate log at ~5 MB on startup
if [[ -f "$LOG_FILE" && $(stat -f '%z' "$LOG_FILE" 2>/dev/null || echo 0) -gt 5242880 ]]; then
  mv "$LOG_FILE" "${LOG_FILE}.1"
fi

# ---------- headroom file: the present state an agent can check (default on) ----------
# One atomically-replaced file per tick. The figures are the same stock reads
# the recorder takes; the session count is the live-session exemption's ROOTS
# counted from the tick's own process table (no extra ps). Nothing here has
# history — the Monitor shows the same figures, and Sparehold never reads this
# file back for any decision: agents check it, the agent decides.
headroom_write() {
  flight_read_knobs
  if [[ "$HEADROOM" != "1" ]]; then
    rm -f "${HEADROOM_FILE}.tmp" "$HEADROOM_FILE" 2>/dev/null   # a switched-off guard must not leave a stale "fine"
    return 0
  fi
  local level="${1:-1}" now="${2:-0}" ptable="${3:-}"
  local swap_mb swap_files=0 sf wired_mb=0 comp_mb=0 disk_gb sessions=0 roots="" iso
  swap_mb="$(flight_swap_mb)"; [[ -n "$swap_mb" ]] || swap_mb=0
  for sf in /System/Volumes/VM/swapfile*; do [[ -e "$sf" ]] && swap_files=$((swap_files + 1)); done
  local vm
  vm="$(flight_vm_mb)"
  wired_mb="${vm%% *}"; comp_mb="${vm#* }"
  [[ -n "$wired_mb" ]] || wired_mb=0
  [[ -n "$comp_mb" ]] || comp_mb=0
  disk_gb="$(df -k / 2>/dev/null | awk 'NR == 2 { printf "%.1f", $4 / 1048576 }')"
  [[ -n "$disk_gb" ]] || disk_gb=0
  if [[ "$LIVE_SESSIONS_OK" -eq 1 ]]; then
    # the tick's table is pid rss args; the session filter reads pid args —
    # strip both leading numbers and put the pid back, no extra ps
    if declare -F _live_session_filter >/dev/null 2>&1; then
      roots="$(printf '%s\n' "$ptable" | awk '{ pid = $1; sub(/^[ \t]*[0-9]+[ \t]+/, ""); sub(/^[ \t]*[0-9]+[ \t]+/, ""); print pid " " $0 }' | _live_session_filter | tr '\n' ' ')"
    else
      roots="$(live_session_roots)"
    fi
    sessions="$(printf '%s' "$roots" | awk '{ print NF }')"
  fi
  iso="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  [[ ${#iso} -eq 24 ]] && iso="${iso:0:22}:${iso:22}"
  # the whole file lands as one rename: an agent never reads half a file
  printf '%s\n' \
    "# sparehold headroom v1 — what this Mac can take on right now; check this before spawning more work" \
    "disk_free_gb: $disk_gb" \
    "swap_used_mb: $swap_mb" \
    "swap_files: $swap_files" \
    "wired_mb: $wired_mb" \
    "compressed_mb: $comp_mb" \
    "pressure: $level" \
    "procs: $(printf '%s\n' "$ptable" | awk 'END { print NR }')" \
    "agent_sessions: $sessions" \
    "updated: $iso" \
    > "${HEADROOM_FILE}.tmp" 2>/dev/null || return 0
  mv "${HEADROOM_FILE}.tmp" "$HEADROOM_FILE" 2>/dev/null || return 0
}

tick() {
  read_fallback
  [[ -e "$PAUSE_FLAG" || "$FALLBACK_PAUSE" == 1 ]] && return 0
  local now level
  now=$(date +%s)
  level=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 1)

  # --- 0. idle dev tooling: hand off to the reaper in the background (it has
  #        its own lock, so a slow pass never stacks; it logs only when it acts) ---
  if [[ "$DEV_SWEEP_SECS" -gt 0 && $((now - LAST_DEV_SWEEP_TS)) -ge "$DEV_SWEEP_SECS" \
        && -x "${SELF_DIR}/memory-auto-clean.sh" ]]; then
    LAST_DEV_SWEEP_TS=$now
    # Its errors go to a file that holds the LAST pass only (each pass starts
    # it again), so a pass that cannot run leaves a trace without growing a
    # log every two minutes. Empty file = the last pass had nothing to say.
    "${SELF_DIR}/memory-auto-clean.sh" --apply --dev --quiet </dev/null >/dev/null 2>"${LOG_DIR}/guard-dev-pass.err" &
  fi

  # snapshot of KILLABLE-and-not-PROTECTED candidates: pid \t rss_kb \t args
  # (a live coding session and everything below it is dropped, then the person's Never Close paths: lib/guard-select.sh)
  local snap exempt="" ptable never=""
  ptable=$(ps axo pid=,rss=,args=)
  [[ -r "$FALLBACK_FILE" ]] && never="$FALLBACK_FILE"
  snap=$(echo "$ptable" | guard_select_candidates "$KILLABLE_RE" "$PROTECT_RE" "$$" "" "$never")
  if [[ -n "$snap" && "$LIVE_SESSIONS_OK" -eq 1 ]]; then
    exempt="$(live_session_exempt | tr '\n' ' ')"
    snap=$(echo "$ptable" | guard_select_candidates "$KILLABLE_RE" "$PROTECT_RE" "$$" "$exempt" "$never")
  fi

  # --- 1. hard cap: single runaway dev process, any pressure level ---
  if [[ -n "$snap" && $((now - LAST_KILL_TS)) -ge "$KILL_COOLDOWN" ]]; then
    local big bpid brss bargs
    big=$(echo "$snap" | sort -t$'\t' -k2 -rn | head -1)
    bpid=$(echo "$big" | cut -f1); brss=$(echo "$big" | cut -f2); bargs=$(echo "$big" | cut -f3)
    if [[ -n "$brss" && "$brss" -gt $((HARD_CAP_MB * 1024)) ]]; then
      if [[ "$HARDCAP_KILL" == "1" ]]; then
        dump_forensics
        kill_proc "$bpid" "$brss" "hard-cap ${HARD_CAP_MB}MB" "$bargs"
      elif [[ $((now - LAST_WARN_TS)) -ge "$WARN_COOLDOWN" ]]; then
        # kill disabled in settings → notify-only, never silent
        LAST_WARN_TS=$now
        log "CAP-EXCEEDED (kill disabled) pid=$bpid rss=$((brss/1024))MB  $bargs"
        # pid attached → the notification carries a "Stop Process" button
        notify "Memory Guard — over the cap" \
          "Using $(awk -v kb="$brss" 'BEGIN{printf "%.1f", kb/1048576}') GB — cap kills are off, so nothing was stopped." \
          "Glass" "" "$(short_name "$bargs")" "$bpid"
      fi
    fi
  fi

  # --- 2. spike detection vs previous tick ---
  if [[ -f "$STATE_FILE" && -n "$snap" ]]; then
    local spikes
    spikes=$(awk -F'\t' -v growkb=$((SPIKE_MB * 1024)) -v minkb=$((SPIKE_MIN_MB * 1024)) '
      NR==FNR { prev[$1]=$2; next }
      ($1 in prev) && ($2 - prev[$1] > growkb) && ($2 >= minkb) {
        printf "pid=%s +%dMB now %dMB  %s\n", $1, ($2-prev[$1])/1024, $2/1024, $3 }
    ' "$STATE_FILE" <(echo "$snap"))
    if [[ -n "$spikes" ]]; then
      log "SPIKE $spikes"
      if [[ $((now - LAST_WARN_TS)) -ge "$WARN_COOLDOWN" ]]; then
        LAST_WARN_TS=$now
        # first spike line: "pid=N +GREWmb now TOTALmb  name…" → human phrasing
        # with the process identity as the notification SUBTITLE
        local sp_line sp_name sp_body sp_pid
        sp_line="$(echo "$spikes" | head -1)"
        sp_pid="$(echo "$sp_line" | awk '{ sub(/^pid=/,"",$1); print $1 }')"
        sp_name="$(echo "$sp_line" | awk '{ $1=$2=$3=$4=""; sub(/^ +/,""); print }' | cut -c1-80)"
        sp_body="$(echo "$sp_line" | awk '{ grew=$2; total=$4; sub(/^\+/,"",grew); sub(/MB$/,"",grew); sub(/MB$/,"",total);
          printf "Grew to %.1f GB (+%.1f GB in the last 15s). Watching — nothing killed yet.", total/1024, grew/1024 }')"
        # pid attached → the notification carries a "Stop Process" button
        notify "Memory Guard — process climbing" "$sp_body" "Glass" "" "$sp_name" "$sp_pid"
      fi
    fi
  fi
  echo "$snap" > "$STATE_FILE"

  # --- 3. pressure levels ---
  if [[ "$level" -eq 2 ]]; then
    log "PRESSURE warning (level 2)"
    if [[ $((now - LAST_WARN_TS)) -ge "$WARN_COOLDOWN" ]]; then
      LAST_WARN_TS=$now
      local tops
      tops=$(ps axo rss,comm | sort -rn | head -3 | awk '{n=split($2,p,"/"); printf "%s %dMB; ", p[n], $1/1024}')
      notify "Memory Guard — pressure WARNING" "System compressing/swapping. Top: ${tops}" "Glass"
    fi
  elif [[ "$level" -ge 4 ]]; then
    log "PRESSURE CRITICAL (level $level)"
    dump_forensics
    if [[ -n "$snap" && $((now - LAST_KILL_TS)) -ge "$KILL_COOLDOWN" ]]; then
      local big bpid brss bargs
      big=$(echo "$snap" | sort -t$'\t' -k2 -rn | head -1)
      bpid=$(echo "$big" | cut -f1); brss=$(echo "$big" | cut -f2); bargs=$(echo "$big" | cut -f3)
      if [[ "$PRESSURE_KILL" != "1" ]]; then
        # kill disabled in settings → notify-only, never silent
        log "PRESSURE-CRITICAL (kill disabled)"
        notify "Memory Guard — pressure CRITICAL" "Pressure kills are off in Settings — close apps manually (see guard-critical log)." "Sosumi"
      elif [[ -n "$brss" && "$brss" -gt 512000 ]]; then   # only worth killing if >500 MB
        kill_proc "$bpid" "$brss" "pressure-critical" "$bargs"
      else
        notify "Memory Guard — pressure CRITICAL" "No big dev process to kill — close apps manually (see guard-critical log)." "Sosumi"
      fi
    fi
  fi

  # --- 4. sustained CPU hogs (notify-only — CPU is NEVER a kill reason) ---
  local cpu_now
  cpu_now=$(ps axo pid=,pcpu=,args= | awk -v th="$CPU_HOG_PCT" '
    $2+0 >= th && $1+0 > 500 { pid=$1; $1=$2=""; sub(/^ +/,"");
      gsub(/\t/," "); printf "%s\t%.80s\n", pid, $0 }')
  if [[ -n "$cpu_now" ]]; then
    local hits_new alert
    hits_new=$(echo "$cpu_now" | awk -F'\t' -v prevf="$CPU_STATE_FILE" '
      BEGIN { while ((getline line < prevf) > 0) { split(line, a, "\t"); prev[a[1]]=a[2] } }
      { c = ($1 in prev ? prev[$1]+1 : 1); printf "%s\t%d\t%s\n", $1, c, $2 }')
    echo "$hits_new" > "$CPU_STATE_FILE"
    alert=$(echo "$hits_new" | awk -F'\t' -v n="$CPU_HOG_TICKS" '$2==n {printf "pid=%s %s; ", $1, $3}')
    if [[ -n "$alert" ]]; then
      log "CPU-HOG sustained >=${CPU_HOG_PCT}% for ${CPU_HOG_TICKS} ticks: $alert"
      if [[ $((now - LAST_WARN_TS)) -ge "$WARN_COOLDOWN" ]]; then
        LAST_WARN_TS=$now
        notify "Memory Guard — sustained CPU hog" "$(echo "$alert" | cut -c1-120)" "Glass"
      fi
    fi
  else
    : > "$CPU_STATE_FILE"
  fi

  # --- 5. flight recorder: one memory sample into its own ring file (off by
  #        default). Runs after every guard duty above; skipped wholesale by
  #        the pause check at the top of the tick, like the rest. Reuses the
  #        tick's ps table — it spawns no ps of its own.
  flight_record "$level" "$now" "$ptable"

  # --- 6. the headroom file: the present state, atomically replaced (default on) ---
  headroom_write "$level" "$now" "$ptable"
}

while :; do
  tick
  [[ "$ONCE" -eq 1 ]] && { log "single tick done (--once)"; exit 0; }
  sleep "$INTERVAL"
done
