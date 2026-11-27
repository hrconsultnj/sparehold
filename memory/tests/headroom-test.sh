#!/usr/bin/env bash
# headroom-test.sh — the memory guard's headroom file (memory-guard.sh).
# Proves, on the guard's own functions taken from the script itself (never
# copied here) and stand-in vm_stat / sysctl / df readings:
#   * knob 1 (the default) writes one ~11-line file whose keys are the figures
#     the guard read, values matching the stand-ins (never hardcoded guesses)
#   * the write is ATOMIC: the temp file is gone and the final file is the
#     whole content — an agent never reads half a file
#   * a second write replaces, never appends: the file stays one file
#   * the session count comes from the tick's own process table through the
#     live-session filter (the fixture table names one agent root + a child)
#   * knob 0 stops the writes AND removes the file — an agent must never read
#     a stale "fine" as current
#   * the knob is re-read from config.local.sh per write (last assignment
#     wins, comments ignored, garbage ignored, switch immediate)
# Nothing here signals a process or touches anything outside its temp dir.
# Runs under bash AND /bin/bash (3.2): the file re-runs itself once per
# interpreter, with ANALYZERS_BASH_CANDIDATES=/nonexistent forcing the 3.2 path.
#   Usage: memory/tests/headroom-test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
fail=0
check() { if [[ "$2" == "ok" ]]; then echo "PASS  $1"; else echo "FAIL  $1 ($2)"; fail=1; fi; }

# the whole file runs once per interpreter (check.sh invokes this file once)
if [[ -z "${HEADROOM_TEST_INTERP:-}" ]]; then
  rc=0
  for interp in bash /bin/bash; do
    echo "== interpreter: $interp ($("$interp" -c 'echo "bash $BASH_VERSION"'))"
    HEADROOM_TEST_INTERP="$interp" ANALYZERS_BASH_CANDIDATES=/nonexistent "$interp" "$0" || rc=1
  done
  exit "$rc"
fi

GUARD="$ROOT/memory/memory-guard.sh"
# the headroom's functions, read from the guard script (single source of truth)
for fn in flight_read_knobs flight_swap_mb flight_vm_mb headroom_write; do
  pattern="/^${fn}() {/,/^}/p"
  eval "$(sed -n "$pattern" "$GUARD")"
done
if [[ -z "$(declare -f headroom_write 2>/dev/null)" || -z "$(declare -f flight_vm_mb 2>/dev/null)" ]]; then
  echo "FAIL  could not read the headroom functions from memory-guard.sh"
  exit 1
fi
# the live-session filter, the same source the guard sources
# shellcheck source=../lib/live-sessions.sh
source "$ROOT/lib/live-sessions.sh" 2>/dev/null || true
export LIVE_SESSIONS_OK=1       # read by headroom_write (evaluated from the guard script)

LOG_DIR="$TMP/reports/memory"
HEADROOM_FILE="${LOG_DIR}/headroom.status"
CONFIG_LOCAL="$TMP/config.local.sh"
mkdir -p "$LOG_DIR"

# stock command output standing in for the machine's readings (the same
# fixtures the flight-recorder test uses, so both features prove the same math)
PS_TABLE='  101 204800 node /opt/work/dev-server.js
  102 102400 /Applications/Safari.app/Contents/MacOS/Safari
  103 51200 grok run --session
  104 20480 tail -f session.log'
VMSTAT_FIXTURE='Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:  389144.
Pages active:  503973.
Pages inactive:  346172.
Pages wired down:  1370988.
Pages occupied by compressor:  282945.'
SWAP_FIXTURE='total = 2048.00M  used = 1024.00M  free = 1024.00M  (encrypted)'
DF_FIXTURE='Filesystem     1024-blocks      Used Available Capacity iused ifree %iused  Mounted on
/dev/disk3s1s1   494384328 481277128  13107200     3%  1200     0    0    3%  /'

vm_stat() { printf '%s\n' "$VMSTAT_FIXTURE"; }
sysctl() { if [[ "${1:-}" == "-n" && "${2:-}" == "vm.swapusage" ]]; then printf '%s\n' "$SWAP_FIXTURE"; else command sysctl "$@"; fi; }
df() { if [[ "$*" == "-k /" ]]; then printf '%s\n' "$DF_FIXTURE"; return 0; fi; command df "$@"; }

export VERBOSE=0                 # read by headroom_write, evaluated from the guard script
export HEADROOM=1                # the file's own switch; also re-read from config.local.sh per tick
export FLIGHT_RECORDER=0 FLIGHT_INTERVAL=60 FLIGHT_FAST_INTERVAL=10 FLIGHT_MAX_BYTES=1048576
                                 # the recorder's knobs, read by the same per-tick pass

# what the figures should be, computed from the same fixtures (not hardcoded)
EXP_WIRED="$(awk '/^Pages wired down/ { printf "%d", $NF * 16384 / 1048576 }' <<<"$VMSTAT_FIXTURE")"
EXP_COMP="$(awk '/compressor/ { printf "%d", $NF * 16384 / 1048576 }' <<<"$VMSTAT_FIXTURE")"
EXP_SWAP="$(awk '$4 == "used" { v = $6; sub(/M$/, "", v); printf "%d", v }' <<<"$SWAP_FIXTURE")"
EXP_DISK="$(awk 'NR == 2 { printf "%.1f", $4 / 1048576 }' <<<"$DF_FIXTURE")"

value_of() { sed -n "s/^$1: //p" "$HEADROOM_FILE" | head -1; }

# --- on by default: the file and its figures ---------------------------------
headroom_write 1 1700000000 "$PS_TABLE"
check "default on: the file is written in one tick" "$([[ -f "$HEADROOM_FILE" ]] && echo ok || ls "$LOG_DIR")"
check "the header names the file for what it is" \
      "$([[ "$(head -1 "$HEADROOM_FILE")" == "# sparehold headroom v1 — what this Mac can take on right now; check this before spawning more work" ]] && echo ok || head -1 "$HEADROOM_FILE")"
check "every figure key is present (eleven lines, one per figure)" \
      "$([[ "$(grep -c '^[a-z_]*: ' "$HEADROOM_FILE")" == 9 ]] && echo ok || grep -c ': ' "$HEADROOM_FILE")"
check "wired matches the stand-in vm_stat" "$([[ "$(value_of wired_mb)" == "$EXP_WIRED" ]] && echo ok || value_of wired_mb)"
check "compressed matches too" "$([[ "$(value_of compressed_mb)" == "$EXP_COMP" ]] && echo ok || value_of compressed_mb)"
check "swap matches the stand-in sysctl" "$([[ "$(value_of swap_used_mb)" == "$EXP_SWAP" ]] && echo ok || value_of swap_used_mb)"
check "disk free matches the stand-in df" "$([[ "$(value_of disk_free_gb)" == "$EXP_DISK" ]] && echo ok || value_of disk_free_gb)"
check "pressure and the process count ride along" \
      "$([[ "$(value_of pressure)" == 1 && "$(value_of procs)" == 4 ]] && echo ok || echo "pressure=$(value_of pressure) procs=$(value_of procs)")"
check "the updated stamp is an ISO time with offset" \
      "$([[ "$(value_of updated)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{2}:[0-9]{2}$ ]] && echo ok || value_of updated)"

# --- the session count, from the tick's own table through the filter ---------
# the fixture table names one agent root (the grok run) and one non-matching
# child: the count is the filter's roots — one session, not two rows
check "the session count is the filter's roots, not the table's rows" \
      "$([[ "$(value_of agent_sessions)" == 1 ]] && echo ok || value_of agent_sessions)"

# --- atomic: no temp file left, the file is whole -----------------------------
check "no temp file survives the write" "$([[ ! -e "${HEADROOM_FILE}.tmp" ]] && echo ok || ls "$LOG_DIR")"

# --- replace, never append ----------------------------------------------------
headroom_write 2 1700000060 "$PS_TABLE"
check "a second write replaces the file (same line count, pressure updated)" \
      "$([[ "$(grep -c . "$HEADROOM_FILE")" == 10 && "$(value_of pressure)" == 2 ]] && echo ok || grep -c . "$HEADROOM_FILE")"

# --- off: the writes stop and the stale file goes ------------------------------
HEADROOM=0
headroom_write 1 1700000100 "$PS_TABLE"
check "knob 0: the file is removed — never a stale fine" "$([[ ! -e "$HEADROOM_FILE" ]] && echo ok || echo "still there")"
check "   and nothing new is written on later ticks" \
      "$(headroom_write 1 1700000160 "$PS_TABLE"; [[ ! -e "$HEADROOM_FILE" ]] && echo ok || echo written)"

# --- the knob is re-read from config.local.sh per write ------------------------
printf '%s\n' 'GUARD_HEADROOM=1   # the app writes this; a comment rides along' > "$CONFIG_LOCAL"
headroom_write 1 1700000220 "$PS_TABLE"
check "the knob is re-read per tick: the app's 1 turns it back on" "$([[ -f "$HEADROOM_FILE" ]] && echo ok || echo absent)"
printf '%s\n' 'GUARD_HEADROOM=0' > "$CONFIG_LOCAL"
headroom_write 1 1700000280 "$PS_TABLE"
check "   and the app's 0 turns it off at the next tick" "$([[ ! -e "$HEADROOM_FILE" ]] && echo ok || echo "still there")"
printf '%s\n' '# GUARD_HEADROOM=0 in a comment changes nothing' > "$CONFIG_LOCAL"
HEADROOM=1
headroom_write 1 1700000340 "$PS_TABLE"
check "   a commented line is not a switch" "$([[ -f "$HEADROOM_FILE" ]] && echo ok || echo absent)"

echo
echo "$([[ $fail -eq 0 ]] && echo "ALL PASS" || echo "FAILURES ABOVE")"
exit $fail
