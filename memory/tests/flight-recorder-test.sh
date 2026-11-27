#!/usr/bin/env bash
# flight-recorder-test.sh — the memory guard's flight recorder (memory-guard.sh).
# Proves, on the recorder functions taken from the guard script itself (never
# copied here) and stand-in vm_stat / sysctl / df readings:
#   * knob 0 (the default) writes nothing — no ring file, no system log, no sync
#   * when on, the header is written first, then one 10-field tab-separated
#     sample appended DIRECTLY to the ring file and flushed (sync); the system
#     log is never touched and the figures come from the stock reads
#   * the fast rate: pressure >= 2 or swap growth since the previous sample
#     pulls the next sample in at the fast interval instead of the slow one
#   * the ring cap: an over-cap ring truncates to header + newest half, under
#     the byte cap, oldest samples gone, the sample that crossed it kept
#   * the four knobs are re-read from config.local.sh per tick (last
#     assignment wins, comments ignored, garbage ignored, switch immediate)
# Nothing here signals a process or touches anything outside its temp dir.
# Runs under bash AND /bin/bash (3.2): the file re-runs itself once per
# interpreter, with ANALYZERS_BASH_CANDIDATES=/nonexistent forcing the 3.2 path.
#   Usage: memory/tests/flight-recorder-test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
fail=0
check() { if [[ "$2" == "ok" ]]; then echo "PASS  $1"; else echo "FAIL  $1 ($2)"; fail=1; fi; }

# the whole file runs once per interpreter (check.sh invokes this file once)
if [[ -z "${FLIGHT_TEST_INTERP:-}" ]]; then
  rc=0
  for interp in bash /bin/bash; do
    echo "== interpreter: $interp ($("$interp" -c 'echo "bash $BASH_VERSION"'))"
    FLIGHT_TEST_INTERP="$interp" ANALYZERS_BASH_CANDIDATES=/nonexistent "$interp" "$0" || rc=1
  done
  exit "$rc"
fi

GUARD="$ROOT/memory/memory-guard.sh"
# the recorder's functions, read from the guard script (single source of truth).
# The pattern goes into a variable first: inside $( ) on bash 3.2 a `{` in a
# double-quoted word is mis-parsed, and the range pattern needs it.
for fn in flight_read_knobs flight_swap_mb flight_record; do
  pattern="/^${fn}() {/,/^}/p"
  eval "$(sed -n "$pattern" "$GUARD")"
done
if [[ -z "$(declare -f flight_record 2>/dev/null)" || -z "$(declare -f flight_read_knobs 2>/dev/null)" \
      || -z "$(declare -f flight_swap_mb 2>/dev/null)" ]]; then
  echo "FAIL  could not read the recorder functions from memory-guard.sh"
  exit 1
fi
RING_HEADER="$(sed -n "s/^RING_HEADER='\(.*\)'$/\1/p" "$GUARD")"
[[ -n "$RING_HEADER" ]] || { echo "FAIL  could not read RING_HEADER from memory-guard.sh"; exit 1; }

LOG_DIR="$TMP/reports/memory"
RING_FILE="${LOG_DIR}/flight-recorder.tsv"
CONFIG_LOCAL="$TMP/config.local.sh"
mkdir -p "$LOG_DIR"

# fixtures: one process table (the guard's `ps axo pid=,rss=,args=` shape) and
# stock command output to stand in for the machine's readings
PS_TABLE='  101 204800 node /opt/work/dev-server.js
  102 102400 /Applications/Safari.app/Contents/MacOS/Safari
  103 51200 claunch run --session'
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
SYNCS=0
sync() { SYNCS=$((SYNCS + 1)); }
LOGCALLS=0
log() { LOGCALLS=$((LOGCALLS + 1)); }   # the system log — the recorder must never come near it

export VERBOSE=0                 # read by flight_record, which is evaluated from the guard script
FLIGHT_RECORDER=0 FLIGHT_INTERVAL=60 FLIGHT_FAST_INTERVAL=10 FLIGHT_MAX_BYTES=1048576
export LAST_FLIGHT_TS=0 LAST_FLIGHT_SWAP_MB=0   # read and updated by flight_record (evaluated from the guard)

# what the figures should be, computed from the same fixtures (not hardcoded)
EXP_WIRED="$(awk '/^Pages wired down/ { printf "%d", $NF * 16384 / 1048576 }' <<<"$VMSTAT_FIXTURE")"
EXP_COMP="$(awk '/compressor/ { printf "%d", $NF * 16384 / 1048576 }' <<<"$VMSTAT_FIXTURE")"
EXP_SWAP="$(awk '$4 == "used" { v = $6; sub(/M$/, "", v); printf "%d", v }' <<<"$SWAP_FIXTURE")"
EXP_DISK="$(awk 'NR == 2 { printf "%.1f", $4 / 1048576 }' <<<"$DF_FIXTURE")"
EXP_TOP5="$(awk 'NF >= 3 { n = split($3, p, "/"); printf "%s%s:%d", (NR > 1 ? ";" : ""), p[n], $2 / 1024 }' <<<"$PS_TABLE")"

lines_in_ring() { wc -l < "$RING_FILE" | tr -d ' '; }

# --- off by default -----------------------------------------------------------
flight_record 1 1700000000 "$PS_TABLE"
check "knob 0 (the default): nothing written, nothing logged, nothing synced" \
  "$([[ ! -e "$RING_FILE" && "$LOGCALLS" -eq 0 && "$SYNCS" -eq 0 ]] && echo ok || echo "ring present: $([[ -e "$RING_FILE" ]] && echo yes || echo no), logcalls=$LOGCALLS syncs=$SYNCS")"

# --- on: direct write, header first, the sample's shape and figures -----------
FLIGHT_RECORDER=1
flight_record 1 1700000000 "$PS_TABLE"
sample="$(sed -n '2p' "$RING_FILE")"
fields="$(printf '%s\n' "$sample" | awk -F'\t' '{ print NF }')"
check "when on: the header lands first and one sample line follows" \
  "$([[ "$(sed -n '1p' "$RING_FILE")" == "$RING_HEADER" && "$(lines_in_ring)" == 2 ]] && echo ok || echo "lines=$(lines_in_ring)")"
check "a sample is 10 tab-separated fields" "$([[ "$fields" == 10 ]] && echo ok || echo "NF=$fields")"
iso="$(printf '%s\n' "$sample" | cut -f1)"
epoch="$(printf '%s\n' "$sample" | cut -f2)"
disk="$(printf '%s\n' "$sample" | cut -f3)"
swap="$(printf '%s\n' "$sample" | cut -f4)"
swapfiles="$(printf '%s\n' "$sample" | cut -f5)"
wired="$(printf '%s\n' "$sample" | cut -f6)"
comp="$(printf '%s\n' "$sample" | cut -f7)"
pressure="$(printf '%s\n' "$sample" | cut -f8)"
procs="$(printf '%s\n' "$sample" | cut -f9)"
top5="$(printf '%s\n' "$sample" | cut -f10)"
check "the figures come from the stock reads (disk free, swap, wired, compressor)" \
  "$([[ "$wired" == "$EXP_WIRED" && "$comp" == "$EXP_COMP" && "$swap" == "$EXP_SWAP" && "$disk" == "$EXP_DISK" ]] \
      && echo ok || echo "wired=$wired/$EXP_WIRED comp=$comp/$EXP_COMP swap=$swap/$EXP_SWAP disk=$disk/$EXP_DISK")"
check "pressure level, process count and the top-5 (command NAME only, no paths) come from the tick's table" \
  "$([[ "$pressure" == 1 && "$procs" == 3 && "$top5" == "$EXP_TOP5" ]] && echo ok || echo "pressure=$pressure procs=$procs top5=$top5 (want $EXP_TOP5)")"
check "iso is local-ISO with the offset colon and the epoch is the tick's now" \
  "$([[ "$epoch" == 1700000000 && "$iso" == ????-??-??T??:??:??[+-]??:?? ]] && echo ok || echo "iso=$iso epoch=$epoch")"
# the verdict is built at top level: a `case` inside $( ) confuses the
# bash 3.2 parser (its pattern `)` collides with the substitution's closer)
swapfiles_ok=ok
case "$swapfiles" in ''|*[!0-9]*) swapfiles_ok="got: $swapfiles" ;; esac
check "swap files is a plain count" "$swapfiles_ok"
check "appended straight to the ring: the system log was never touched and the line was flushed" \
  "$([[ "$LOGCALLS" -eq 0 && "$SYNCS" -ge 1 ]] && echo ok || echo "logcalls=$LOGCALLS syncs=$SYNCS")"
check "the swap it saw is remembered, as the fast-rate trigger's baseline" \
  "$([[ "$LAST_FLIGHT_SWAP_MB" == "$EXP_SWAP" ]] && echo ok || echo "LAST_FLIGHT_SWAP_MB=$LAST_FLIGHT_SWAP_MB (want $EXP_SWAP)")"

# --- the rates ----------------------------------------------------------------
LAST_FLIGHT_TS=1700000000; LAST_FLIGHT_SWAP_MB=$EXP_SWAP
flight_record 1 $((1700000000 + 59)) "$PS_TABLE"
check "slow rate: a calm tick 59s after a sample records nothing" \
  "$([[ "$(lines_in_ring)" == 2 ]] && echo ok || echo "lines=$(lines_in_ring)")"
flight_record 1 $((1700000000 + 60)) "$PS_TABLE"
check "slow rate: one interval later a sample lands" \
  "$([[ "$(lines_in_ring)" == 3 ]] && echo ok || echo "lines=$(lines_in_ring)")"
LAST_FLIGHT_TS=1700000000
flight_record 2 $((1700000000 + 9)) "$PS_TABLE"
check "fast rate: pressure 2 for only 9s records nothing" \
  "$([[ "$(lines_in_ring)" == 3 ]] && echo ok || echo "lines=$(lines_in_ring)")"
flight_record 2 $((1700000000 + 10)) "$PS_TABLE"
check "fast rate: pressure 2 pulls the next sample in at the fast interval" \
  "$([[ "$(lines_in_ring)" == 4 ]] && echo ok || echo "lines=$(lines_in_ring)")"
LAST_FLIGHT_TS=1700000000; LAST_FLIGHT_SWAP_MB=$((EXP_SWAP - 1))
flight_record 1 $((1700000000 + 30)) "$PS_TABLE"
check "fast rate: swap growth since the previous sample records early at calm pressure" \
  "$([[ "$(lines_in_ring)" == 5 ]] && echo ok || echo "lines=$(lines_in_ring)")"
LAST_FLIGHT_TS=1700000000; LAST_FLIGHT_SWAP_MB=$EXP_SWAP
flight_record 1 $((1700000000 + 30)) "$PS_TABLE"
check "steady swap inside the slow window records nothing" \
  "$([[ "$(lines_in_ring)" == 5 ]] && echo ok || echo "lines=$(lines_in_ring)")"
LAST_FLIGHT_TS=1700000000; LAST_FLIGHT_SWAP_MB=$((EXP_SWAP + 500))
flight_record 1 $((1700000000 + 30)) "$PS_TABLE"
check "shrinking swap records nothing" \
  "$([[ "$(lines_in_ring)" == 5 ]] && echo ok || echo "lines=$(lines_in_ring)")"

# --- the ring cap -------------------------------------------------------------
RING_FILE="$TMP/reports/memory2/flight-recorder.tsv"   # a fresh ring for the cap story
mkdir -p "$(dirname "$RING_FILE")"
printf '%s\n' "$RING_HEADER" > "$RING_FILE"
i=1
while [[ $i -le 12 ]]; do
  printf 'PREFILL-%02d %0109d\n' "$i" 0 >> "$RING_FILE"
  i=$((i + 1))
done
FLIGHT_MAX_BYTES=1200
LAST_FLIGHT_TS=1700000000; LAST_FLIGHT_SWAP_MB=$EXP_SWAP
flight_record 1 $((1700000000 + 600)) "$PS_TABLE"
size="$(stat -f '%z' "$RING_FILE" 2>/dev/null)"
[[ -n "$size" ]] || size=0
check "over the cap: header + newest half, back under the byte cap" \
  "$([[ "$size" -le 1200 && "$(lines_in_ring)" == 8 && "$(sed -n '1p' "$RING_FILE")" == "$RING_HEADER" ]] \
      && echo ok || echo "size=$size lines=$(lines_in_ring)")"
check "the oldest half is gone and exactly the newest six prefill lines survive" \
  "$(if grep -q 'PREFILL-0[1-6]' "$RING_FILE"; then echo "an old line survived"; \
     elif [[ "$(grep -c 'PREFILL-' "$RING_FILE")" == 6 ]]; then echo ok; else echo "kept $(grep -c 'PREFILL-' "$RING_FILE")"; fi)"
check "the sample that crossed the cap is kept (newest wins)" \
  "$(grep -q "$((1700000000 + 600))" "$RING_FILE" && echo ok || echo "new sample lost")"

# --- the knobs are re-read from config.local.sh --------------------------------
printf '%s\n' \
  '#GUARD_FLIGHT_RECORDER=1 — a commented line is not a setting' \
  'GUARD_FLIGHT_RECORDER=0' \
  'GUARD_FLIGHT_RECORDER=1' \
  'GUARD_FLIGHT_INTERVAL="120"' \
  'GUARD_FLIGHT_FAST_INTERVAL=5  # fast' \
  'GUARD_FLIGHT_MAX_BYTES=2048' \
  > "$CONFIG_LOCAL"
FLIGHT_RECORDER=0 FLIGHT_INTERVAL=60 FLIGHT_FAST_INTERVAL=10 FLIGHT_MAX_BYTES=1048576
flight_read_knobs
check "knobs re-read from config.local.sh: last assignment wins, quotes and trailing comments stripped" \
  "$([[ "$FLIGHT_RECORDER" == 1 && "$FLIGHT_INTERVAL" == 120 && "$FLIGHT_FAST_INTERVAL" == 5 && "$FLIGHT_MAX_BYTES" == 2048 ]] \
      && echo ok || echo "rec=$FLIGHT_RECORDER slow=$FLIGHT_INTERVAL fast=$FLIGHT_FAST_INTERVAL max=$FLIGHT_MAX_BYTES")"
printf 'GUARD_FLIGHT_RECORDER=0\n' > "$CONFIG_LOCAL"
flight_read_knobs
check "flipping the file flips the switch at the next read — no guard restart" \
  "$([[ "$FLIGHT_RECORDER" == 0 ]] && echo ok || echo "rec=$FLIGHT_RECORDER")"
printf 'GUARD_FLIGHT_INTERVAL=abc\nGUARD_FLIGHT_RECORDER=7\n' > "$CONFIG_LOCAL"
flight_read_knobs
check "garbage in the file changes nothing (integers only; the switch is only 0 or 1)" \
  "$([[ "$FLIGHT_INTERVAL" == 120 && "$FLIGHT_RECORDER" == 0 ]] && echo ok || echo "slow=$FLIGHT_INTERVAL rec=$FLIGHT_RECORDER")"
CONFIG_LOCAL="$TMP/nosuchfile"
flight_read_knobs
check "a config that cannot be read leaves the knobs alone" \
  "$([[ "$FLIGHT_RECORDER" == 0 && "$FLIGHT_INTERVAL" == 120 ]] && echo ok || echo "rec=$FLIGHT_RECORDER slow=$FLIGHT_INTERVAL")"

exit "$fail"
