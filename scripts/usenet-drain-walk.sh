#!/bin/bash
set -euo pipefail
#
# Walk the usenet outbox down, one bounded pass at a time, and stop when the
# passes stop moving anything.
#
# WHY THIS EXISTS
#
# The drain is held down on purpose. scripts/usenet-blackhole.timer is disabled
# and docs/MAINTENANCE.md's "Holding the usenet ingest down" says not to arm it,
# because of what an unattended pass did on 2026-09-20: it took all 21 finished
# releases at once -- two of them 30-38 GB -- drove io full avg10 to 81.91% in
# twelve minutes, and took four reboots to recover. The outbox stood at 588
# NZBs that night and has not been below the mark since.
#
# What was missing is not permission to run unattended. It is a loop that runs
# ONE pass, reads it, and stops when a pass does not move anything -- which is
# what a person does when they follow the documented procedure, and what stops
# being practical at 600 releases.
#
# WHAT IT DOES
#
#   * takes a cheap progress fingerprint (outbox depth, staging bytes, watch
#     folder contents, state file size and mtime) before each pass, and again
#     every --poll seconds while the pass runs;
#   * kills that pass's whole process group when the fingerprint has not
#     changed for --pass-stall seconds, so a hung fetch cannot hold the walk;
#   * after each pass, asks whether the drain moved anywhere at all.
#     --max-barren passes in a row that did not ends the walk.
#
# WHY KILLING A PASS MOVES THE WALK ON
#
# The fetch set is the least-recently-attempted releases first, and run() marks
# `last_fetch_attempt` for the releases it is about to fetch BEFORE fetching
# them (scripts/lib/usenet_blackhole.py). A killed pass therefore sends the
# releases it was working on to the back of the queue and the next pass attempts
# different ones. That holds across a SIGKILL, not just a SIGTERM -- which is why
# nothing here has to remember which release was stuck.
#
# WHAT IT DOES NOT DO
#
#   * It never writes logs/usenet-blackhole-state.json. That file is the Python
#     half's, on a resume contract, and a second writer on it is the coupling
#     trap scripts/usenet-blackhole.sh's pressure gate avoids on purpose.
#   * It never deletes an NZB. The outbox is the arrs' work queue, and clearing
#     it is not a producer's business.
#   * It never arms, disarms, stops or starts usenet-blackhole.timer. If that
#     timer is active this refuses to run instead: two drains on one outbox is
#     the load this file exists to avoid.
#
# Usage:
#   ./scripts/usenet-drain-walk.sh                    # dry run: print the plan
#   ./scripts/usenet-drain-walk.sh --apply            # walk until the mark clears
#   ./scripts/usenet-drain-walk.sh --apply --max-passes 8 -v
#   ./scripts/usenet-drain-walk.sh --apply --pass-stall 900 --poll 30
#   ./scripts/usenet-drain-walk.sh --apply --report-dry-run
#   ./scripts/usenet-drain-walk.sh --apply --max-skipped 3
#
# --apply is required to run a pass, the same rule scripts/usenet-blackhole.sh
# follows and for the same reason: the mode an operator uses to decide whether
# applying is safe must not be the mode that applies.
#
# It runs in the foreground and stops for one of six reasons, each printed and
# logged when it happens: the outbox dropped below the high-water mark (the
# point at which the producers start running again), --max-passes was reached,
# --max-hours elapsed, --max-barren passes in a row made no progress, the I/O
# pressure gate refused --max-skipped passes in a row, or someone interrupted
# it. The refused case is deliberately not folded into the barren one: a pass
# the gate refused never started, so it says the host was busy, not that the
# drain is stuck.
#
# It exits 0 when the outbox ends below the mark, 3 when it does not, 1 for a
# precondition it refused and 2 for a bad argument. A walk that gave up on a
# stuck drain and a walk that cleared the queue are not the same observable
# result, the rule scripts/sync-nas.sh is built on.
#
# Every flag that shapes a pass -- --max-inflight, --stall-hours,
# --timeout-hours, --report-failures, --report-dry-run -- is passed through to
# scripts/usenet-blackhole.sh unchanged. The defaults here are the ones its
# systemd unit runs with, so a walk and a timer pass are the same amount of
# work on the same box.
#
# Prerequisites: python3, and the TORBOX_API_KEY in .env that the pass needs.
#
# ⚠️  Generated with LLM assistance and human-reviewed. Dry run is the default.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAS_STACK_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$NAS_STACK_DIR/.env"

# shellcheck source=scripts/lib/env-file.sh
. "${SCRIPT_DIR}/lib/env-file.sh"
# shellcheck source=scripts/lib/queue_high_water.sh
. "${SCRIPT_DIR}/lib/queue_high_water.sh"

PASS_SCRIPT="$SCRIPT_DIR/usenet-blackhole.sh"
STATUS_SCRIPT="$SCRIPT_DIR/usenet-blackhole-status.sh"

# The four places a pass can leave a mark, resolved the same way
# scripts/usenet-blackhole.sh resolves them and from the same environment
# overrides, so a test can point both at one fixture tree. The outbox is not
# re-derived: outbox_dir() is the single spelling of it, shared with the two
# producers that must pace themselves against the same directory.
MEDIA_ROOT_VALUE="$(media_root)"
NZB_DIR="$(outbox_dir)"
WATCH_DIR="${USENET_WATCH_DIR:-$MEDIA_ROOT_VALUE/usenet/blackhole/complete}"
STAGING_DIR="${USENET_STAGING_DIR:-$MEDIA_ROOT_VALUE/usenet/blackhole/staging}"
STATE_PATH="${USENET_STATE_PATH:-$NAS_STACK_DIR/logs/usenet-blackhole-state.json}"
LOG_FILE="${USENET_DRAIN_LOG:-$NAS_STACK_DIR/logs/usenet-drain-walk.log}"
LOCK_DIR="$NAS_STACK_DIR/logs/usenet-drain-walk.lock"

APPLY=false
VERBOSE=false
FORCE=false
REPORT_FAILURES=false
REPORT_DRY_RUN=false
STALL_HOURS=""
TIMEOUT_HOURS=""

# The walk's own bounds. They are deliberately generous per pass and tight per
# walk: one pass is minutes, and twelve of them with a cooldown is under the
# four-hour wall clock, so a walk that has to be killed by hand means something
# the counters below did not catch.
MAX_PASSES=12
MAX_HOURS=4
MAX_BARREN=4

# Consecutive passes the I/O pressure gate may refuse before the walk stands
# down. The gate refuses when /proc/pressure/io's full avg10 sits at or above
# PSI_IO_LIMIT, which is the host protecting itself and not a fault to retry
# through -- so this is expressed in skip-cooldowns (5 minutes each): 6 is half
# an hour of a host that is too busy to start a pass. Measured 2026-09-22: the
# longest refusal streak in a 12-pass run was 2, twice, with the threshold at 4.
MAX_SKIPPED=6

# Ten minutes of a completely static fingerprint is the definition of a pass
# that is not moving. It is well above the longest quiet stretch a healthy fetch
# has -- a 38 GB payload on this pool writes continuously, and its bytes are in
# the fingerprint -- and well below --stall-hours, which is TorBox's own bound
# on a download and is measured in hours. This one bounds the process.
POLL_SECONDS=30
PASS_STALL_SECONDS=600

# A pause between passes, so the pool is not handed one pass's writeback as the
# next one's input. --skip-cooldown is longer and is used when the pressure gate
# refused a pass: the host read as stalled, and hammering it every minute is the
# behaviour that made the gate necessary.
COOLDOWN_SECONDS=60
SKIP_COOLDOWN_SECONDS=300

# After SIGTERM, how long to wait before SIGKILL. A python fetch thread inside a
# zip write does not always come back out of the first signal, and a walk that
# left one behind would be running two fetches at once with only one of them
# accounted for.
KILL_GRACE_SECONDS=30

# 6 is the value scripts/usenet-blackhole.service runs with; 0 would be the
# script's own default and would mean uncapped, which is not a default to
# inherit by accident.
MAX_INFLIGHT=6

# A flag that takes a value must get one, and the definition sits above the loop
# that calls it: bash resolves a function at the call, not at the parse, and a
# `require_value` defined below the loop is not defined for the first flag that
# needs it.
#
# Without this, `--poll` at the end of argv reads `${2-}` as empty and the
# numeric check below reports a missing value as a malformed one, which sends
# the reader looking at the value instead of at the missing argument.
require_value() {
  local flag="$1" argc="$2" value="$3"
  if [[ "$argc" -lt 2 || -z "$value" ]]; then
    echo "ERROR: $flag needs a value" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true ;;
    --verbose|-v) VERBOSE=true ;;
    --force) FORCE=true ;;
    --report-failures) REPORT_FAILURES=true ;;
    --report-dry-run) REPORT_DRY_RUN=true ;;
    --max-passes) require_value "$1" "$#" "${2-}"; MAX_PASSES="$2"; shift ;;
    --max-passes=*) MAX_PASSES="${1#*=}" ;;
    --max-hours) require_value "$1" "$#" "${2-}"; MAX_HOURS="$2"; shift ;;
    --max-hours=*) MAX_HOURS="${1#*=}" ;;
    --max-barren) require_value "$1" "$#" "${2-}"; MAX_BARREN="$2"; shift ;;
    --max-barren=*) MAX_BARREN="${1#*=}" ;;
    --max-skipped) require_value "$1" "$#" "${2-}"; MAX_SKIPPED="$2"; shift ;;
    --max-skipped=*) MAX_SKIPPED="${1#*=}" ;;
    --poll) require_value "$1" "$#" "${2-}"; POLL_SECONDS="$2"; shift ;;
    --poll=*) POLL_SECONDS="${1#*=}" ;;
    --pass-stall) require_value "$1" "$#" "${2-}"; PASS_STALL_SECONDS="$2"; shift ;;
    --pass-stall=*) PASS_STALL_SECONDS="${1#*=}" ;;
    --cooldown) require_value "$1" "$#" "${2-}"; COOLDOWN_SECONDS="$2"; shift ;;
    --cooldown=*) COOLDOWN_SECONDS="${1#*=}" ;;
    --skip-cooldown) require_value "$1" "$#" "${2-}"; SKIP_COOLDOWN_SECONDS="$2"; shift ;;
    --skip-cooldown=*) SKIP_COOLDOWN_SECONDS="${1#*=}" ;;
    --kill-grace) require_value "$1" "$#" "${2-}"; KILL_GRACE_SECONDS="$2"; shift ;;
    --kill-grace=*) KILL_GRACE_SECONDS="${1#*=}" ;;
    --max-inflight) require_value "$1" "$#" "${2-}"; MAX_INFLIGHT="$2"; shift ;;
    --max-inflight=*) MAX_INFLIGHT="${1#*=}" ;;
    --stall-hours) require_value "$1" "$#" "${2-}"; STALL_HOURS="$2"; shift ;;
    --stall-hours=*) STALL_HOURS="${1#*=}" ;;
    --timeout-hours) require_value "$1" "$#" "${2-}"; TIMEOUT_HOURS="$2"; shift ;;
    --timeout-hours=*) TIMEOUT_HOURS="${1#*=}" ;;
    --help|-h)
      # The header block above, printed verbatim. A fixed range rather than
      # `sed -n '2,/^$/p'`, which BSD sed rejects, and it has to stop ON the
      # last comment line. The range moves whenever the header does, which is
      # what tests/usenet-drain-walk.bats notices.
      # The range moves whenever a line is added to the header, and it had
      # already fallen five lines short of the end: --help was missing the
      # Prerequisites line and the warning below it, and nothing failed,
      # because the test that "notices" only named strings from the middle of
      # the block. tests/usenet-drain-walk.bats now derives the last header line
      # from this file and asserts it appears in the output.
      sed -n '3,86p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unrecognised argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# Whole numbers only, one check for all of them, so a value that reaches
# arithmetic is a number and not a string that errors halfway through a walk.
for pair in "max-passes=$MAX_PASSES" "max-hours=$MAX_HOURS" \
            "max-barren=$MAX_BARREN" "max-skipped=$MAX_SKIPPED" \
            "poll=$POLL_SECONDS" \
            "pass-stall=$PASS_STALL_SECONDS" "cooldown=$COOLDOWN_SECONDS" \
            "skip-cooldown=$SKIP_COOLDOWN_SECONDS" "kill-grace=$KILL_GRACE_SECONDS" \
            "max-inflight=$MAX_INFLIGHT"; do
  case "${pair#*=}" in
    ''|*[!0-9]*)
      echo "ERROR: --${pair%%=*} must be a whole number, got '${pair#*=}'" >&2
      exit 2
      ;;
  esac
done

# 10# forces base ten: bash reads a leading zero as octal, so --max-passes 08
# would fail the comparison below with "value too great for base".
MAX_PASSES=$((10#$MAX_PASSES))
MAX_HOURS=$((10#$MAX_HOURS))
MAX_BARREN=$((10#$MAX_BARREN))
MAX_SKIPPED=$((10#$MAX_SKIPPED))
POLL_SECONDS=$((10#$POLL_SECONDS))
PASS_STALL_SECONDS=$((10#$PASS_STALL_SECONDS))
COOLDOWN_SECONDS=$((10#$COOLDOWN_SECONDS))
SKIP_COOLDOWN_SECONDS=$((10#$SKIP_COOLDOWN_SECONDS))
KILL_GRACE_SECONDS=$((10#$KILL_GRACE_SECONDS))
MAX_INFLIGHT=$((10#$MAX_INFLIGHT))

# Zero passes, zero minutes or zero barren passes is a walk that cannot run or
# cannot stop. Refused rather than clamped, because a walk that silently ignores
# its own budget is worse than one that says the budget is not a budget.
if [[ "$MAX_PASSES" -lt 1 ]]; then
  echo "ERROR: --max-passes must be at least 1, got '$MAX_PASSES'" >&2
  exit 2
fi
if [[ "$MAX_HOURS" -lt 1 ]]; then
  echo "ERROR: --max-hours must be at least 1, got '$MAX_HOURS'" >&2
  exit 2
fi
if [[ "$MAX_BARREN" -lt 1 ]]; then
  echo "ERROR: --max-barren must be at least 1, got '$MAX_BARREN'" >&2
  exit 2
fi
if [[ "$MAX_SKIPPED" -lt 1 ]]; then
  echo "ERROR: --max-skipped must be at least 1, got '$MAX_SKIPPED'" >&2
  exit 2
fi
if [[ "$POLL_SECONDS" -lt 1 ]]; then
  echo "ERROR: --poll must be at least 1 second, got '$POLL_SECONDS'" >&2
  exit 2
fi
if [[ "$PASS_STALL_SECONDS" -lt "$POLL_SECONDS" ]]; then
  echo "ERROR: --pass-stall (${PASS_STALL_SECONDS}s) must be at least --poll (${POLL_SECONDS}s)," >&2
  echo "       or every pass is killed on its first unchanged sample" >&2
  exit 2
fi

mkdir -p "$NAS_STACK_DIR/logs"

log() {
  printf '[drain-walk %s] %s\n' "$(date '+%H:%M:%S')" "$1" | tee -a "$LOG_FILE"
}

# --- progress probes --------------------------------------------------------

# GNU first, BSD second, the same two-spelling problem scripts/sync-nas.sh
# solves for `timeout`: this script runs on the NAS and in the suite, and the
# suite runs on macOS. A probe that answers 0 on one of them would read as a
# permanently static fingerprint and kill every pass.
file_size() {
  [[ -f "$1" ]] || { printf '0'; return; }
  wc -c < "$1" 2>/dev/null | tr -d ' ' || printf '0'
}

file_mtime() {
  [[ -e "$1" ]] || { printf '0'; return; }
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf '0'
}

dir_kb() {
  [[ -d "$1" ]] || { printf '0'; return; }
  du -sk "$1" 2>/dev/null | awk '{print $1}' || printf '0'
}

watch_entries() {
  [[ -d "$1" ]] || { printf '0'; return; }
  find "$1" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ' || printf '0'
}

# The fingerprint the watchdog compares. Four cheap reads, none of them a parser
# and none of them an API call, because this runs every --poll seconds for the
# length of the walk.
#
# Staging bytes are the one that matters during a fetch, and the reason this is
# a filesystem probe rather than a reading of the state file: a 38 GB payload
# writes to staging for half an hour with the state file untouched, so a
# state-only fingerprint would call every large fetch a stall and kill it.
#
# The watch folder is counted rather than summed: the arr imports out of it and
# removes what it takes, so the number moves in both directions, and either
# direction means the pipeline is moving.
fingerprint() {
  printf '%s|%s|%s|%s:%s' \
    "$(outbox_depth "$NZB_DIR")" \
    "$(watch_entries "$WATCH_DIR")" \
    "$(dir_kb "$STAGING_DIR")" \
    "$(file_size "$STATE_PATH")" \
    "$(file_mtime "$STATE_PATH")"
}

# The walk-level numbers, once per pass rather than once per poll: three numbers
# out of the state file, read by the script that already renders it
# (scripts/usenet-blackhole-status.sh --json) instead of a second parser here
# that would drift from it.
#
# A pass that cannot be read answers `?`, and `?` never counts as progress in
# either direction -- an unreadable state file is not an improvement.
status_totals() {
  local out
  out="$("$STATUS_SCRIPT" --json 2>/dev/null | python3 -c '
import json, sys
try:
    totals = (json.load(sys.stdin) or {}).get("totals") or {}
except Exception:
    print("? ? ?")
    raise SystemExit
print("%s %s %s" % (totals.get("jobs", "?"), totals.get("complete", "?"),
                    totals.get("stalled", "?")))
' 2>/dev/null)" || out=""
  printf '%s' "${out:-? ? ?}"
}

# `jobs|complete|stalled|outbox`: the queue, and how much of it is finished at
# TorBox and owed a local fetch.
metrics() {
  printf '%s|%s' "$(status_totals)" "$(outbox_depth "$NZB_DIR")"
}

# Did the drain get anywhere between two metrics samples?
#
# Only three things count, and each is a release leaving the path it was stuck
# on: the outstanding count falling, the outbox falling (an NZB is discarded
# only when its release is delivered or has terminally failed), or the finished
# count rising. Submissions alone do not count -- a pass that only queues more
# work has made the drain longer, not shorter.
advanced() {
  local before="$1" after="$2"
  local b_jobs b_complete b_outbox
  local a_jobs a_complete a_outbox
  # `stalled` is read into `_` on purpose: a job going stalled is not progress,
  # and it is in the metrics string so the log shows it, not so this counts it.
  read -r b_jobs b_complete _ b_outbox <<<"$(printf '%s' "$before" | tr '|' ' ')"
  read -r a_jobs a_complete _ a_outbox <<<"$(printf '%s' "$after" | tr '|' ' ')"

  if [[ "$a_jobs" != "?" && "$b_jobs" != "?" ]] && [[ "$a_jobs" -lt "$b_jobs" ]]; then
    return 0
  fi
  if [[ "$a_outbox" -lt "$b_outbox" ]]; then
    return 0
  fi
  if [[ "$a_complete" != "?" && "$b_complete" != "?" ]] && [[ "$a_complete" -gt "$b_complete" ]]; then
    return 0
  fi
  return 1
}

# --- the pass, and the watchdog on it ---------------------------------------

INTERRUPTED=false
CURRENT_PASS_PID=""

# Kill the whole process group, not the shell in front of it. A pass is
# usenet-blackhole.sh -> python3 -> curl, and signalling only the shell leaves
# the python fetch writing into staging with nothing watching it -- a second
# drain with one of them unaccounted for.
#
# The group is the child's own because it is started with job control on
# (`set -m`), which makes the background job a process-group leader. SIGTERM
# first, SIGKILL only after --kill-grace, and the SIGKILL goes to the group too.
stop_pass_group() {
  local pid="$1"
  kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [[ "$waited" -lt "$KILL_GRACE_SECONDS" ]]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi
}

on_signal() {
  INTERRUPTED=true
  log "interrupted; stopping the pass in flight"
  if [[ -n "$CURRENT_PASS_PID" ]]; then
    stop_pass_group "$CURRENT_PASS_PID"
  fi
}
trap on_signal INT TERM

# Sleep in one-second steps so a pass that finishes early is noticed at once
# rather than at the end of the poll interval.
sleep_or_break() {
  local seconds="$1" pid="$2" i=0
  while [[ "$i" -lt "$seconds" ]]; do
    kill -0 "$pid" 2>/dev/null || return 0
    [[ "$INTERRUPTED" == "true" ]] && return 0
    sleep 1
    i=$((i + 1))
  done
}

# Watch one pass. Returns 0 when the pass ended on its own, 1 when the watchdog
# killed it. Sets PASS_KILLED when it did.
watch_pass() {
  local pid="$1"
  local current last_change now idle
  current="$(fingerprint)"
  last_change="$(date +%s)"
  PASS_KILLED=false

  while kill -0 "$pid" 2>/dev/null; do
    sleep_or_break "$POLL_SECONDS" "$pid"
    kill -0 "$pid" 2>/dev/null || break
    [[ "$INTERRUPTED" == "true" ]] && break

    now="$(date +%s)"
    local fresh
    fresh="$(fingerprint)"
    if [[ "$fresh" != "$current" ]]; then
      current="$fresh"
      last_change="$now"
      continue
    fi

    idle=$((now - last_change))
    if [[ "$idle" -ge "$PASS_STALL_SECONDS" ]]; then
      PASS_KILLED=true
      log "no change in the fingerprint for ${idle}s; stopping this pass and moving to the next"
      log "  fingerprint (outbox|watch|staging-kb|state-bytes:mtime): $fresh"
      # The pass's own last lines, because "which release" is the question this
      # answers and the state file does not know about a fetch in flight.
      log "  last output from the pass:"
      tail -n 6 "$PASS_SLICE" 2>/dev/null | sed 's/^/    /' | tee -a "$LOG_FILE" >&2 || true
      stop_pass_group "$pid"
      return 1
    fi
  done
  return 0
}

run_pass() {
  PASS_NUMBER=$((PASS_NUMBER + 1))
  PASS_KILLED=false
  PASS_EXIT=0
  PASS_SLICE="$LOCK_DIR/pass-${PASS_NUMBER}.log"
  : > "$PASS_SLICE"

  log "pass ${PASS_NUMBER}/${MAX_PASSES}: ${PASS_ARGS[*]}"

  set -m
  "$PASS_SCRIPT" "${PASS_ARGS[@]}" > "$PASS_SLICE" 2>&1 &
  CURRENT_PASS_PID=$!
  set +m

  watch_pass "$CURRENT_PASS_PID" || true

  wait "$CURRENT_PASS_PID" 2>/dev/null || PASS_EXIT=$?
  CURRENT_PASS_PID=""

  # The pass's own output is appended to the walk log verbatim, so the log is
  # one chronological record of the whole walk and `tail -f` works on it.
  if [[ -s "$PASS_SLICE" ]]; then
    sed 's/^/    /' "$PASS_SLICE" >> "$LOG_FILE"
  fi

  # The gate prints four messages and refuses on one of them: the other three
  # say "this pass runs unprotected" and then run the pass normally. Matching
  # the prefix alone therefore classified a pass that ran as one that never
  # started, which is the error this branch exists to remove -- it disabled the
  # barren stop on any host whose PSI reading could not be read. Matched on the
  # refusal's own phrase because it is the only one of the four that skips.
  PASS_REFUSED=false
  if grep -q '\[pressure-gate\].*skipping this pass' "$PASS_SLICE" 2>/dev/null; then
    PASS_REFUSED=true
  fi

  local summary
  summary="$(grep -a 'submitted .* fetched .* outstanding' "$PASS_SLICE" 2>/dev/null | tail -n 1 || true)"

  if [[ "$PASS_KILLED" == "true" ]]; then
    log "pass ${PASS_NUMBER}: killed by the watchdog"
  elif [[ "$PASS_REFUSED" == "true" ]]; then
    log "pass ${PASS_NUMBER}: refused by the I/O pressure gate"
  elif [[ "$PASS_EXIT" -ne 0 ]]; then
    log "pass ${PASS_NUMBER}: exited ${PASS_EXIT}"
  else
    log "pass ${PASS_NUMBER}: ${summary:-<no summary line>}"
  fi
  if $VERBOSE; then
    log "pass ${PASS_NUMBER} metrics: $(metrics)"
  fi
}

# --- preconditions ----------------------------------------------------------

# Two drains on one outbox is the load this script exists to avoid, and the
# timer is the other drain. Read only: this never stops or disables anything,
# because the timer's state is the operator's decision and a walk that quietly
# changed it would be the surprise, not the fix.
#
# Fails open, and says which of the two it is doing. systemctl is absent on
# macOS and on the session D-Bus-less containers this suite also runs in, and
# "the check could not run" must not read as "the timer is not armed" -- the
# same rule scripts/usenet-blackhole.sh's pressure gate follows.
timer_is_active() {
  command -v systemctl >/dev/null 2>&1 || return 2
  local state
  state="$(systemctl --user is-active usenet-blackhole.timer 2>/dev/null || true)"
  [[ "$state" == "active" ]] && return 0
  return 1
}

LOCK_HELD=false

# Only ever removes the lock this run took. The trap is installed before the
# lock is acquired, so an unconditional `rm -rf` would also fire on the losing
# side of a race -- deleting the winner's lock and letting a third walk start
# alongside it. Ownership is the PID written into the lock, checked here.
release_lock() {
  if [[ "$LOCK_HELD" == "true" ]]; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
  fi
}

# A directory, not a PID file: `mkdir` is atomic on every filesystem this runs
# on, so two walks started in the same second cannot both believe they won.
# The PID inside is what turns a leftover lock from a killed walk into a stale
# one rather than a permanent refusal.
acquire_lock() {
  local tries=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1))
    local other=""
    [[ -f "$LOCK_DIR/pid" ]] && other="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$other" ]] && kill -0 "$other" 2>/dev/null; then
      echo "ERROR: another drain walk is already running (pid ${other}, lock ${LOCK_DIR})." >&2
      echo "       Two drains on one outbox is the load this walk exists to avoid." >&2
      exit 1
    fi
    if [[ "$tries" -ge 3 ]]; then
      echo "ERROR: ${LOCK_DIR} exists and its owner is gone, but it cannot be replaced." >&2
      exit 1
    fi
    echo "WARNING: replacing a stale walk lock at ${LOCK_DIR} (owner ${other:-unknown} is gone)" >&2
    rm -rf "$LOCK_DIR" 2>/dev/null || true
  done
  printf '%s' "$$" > "$LOCK_DIR/pid"
  LOCK_HELD=true
}
trap 'release_lock' EXIT

# --- what the walk will run -------------------------------------------------

PASS_ARGS=(--apply)
if $REPORT_FAILURES; then PASS_ARGS+=(--report-failures); fi
if $REPORT_DRY_RUN; then PASS_ARGS+=(--report-dry-run); fi
PASS_ARGS+=(--max-inflight "$MAX_INFLIGHT")
if [[ -n "$STALL_HOURS" ]]; then PASS_ARGS+=(--stall-hours "$STALL_HOURS"); fi
if [[ -n "$TIMEOUT_HOURS" ]]; then PASS_ARGS+=(--timeout-hours "$TIMEOUT_HOURS"); fi

OUTBOX_START="$(outbox_depth "$NZB_DIR")"
METRICS_START="$(metrics)"

echo ""
echo "========================================"
echo "Usenet drain walk — $(date '+%Y-%m-%d %H:%M:%S')"
if $APPLY; then
  echo "Mode: APPLYING (up to ${MAX_PASSES} pass(es), ${MAX_HOURS}h, stop after ${MAX_BARREN} fruitless or ${MAX_SKIPPED} refused)"
else
  echo "Mode: DRY RUN (use --apply to walk)"
fi
echo "Mark: outbox below ${QUEUE_HIGH_WATER} NZBs (when the producers resume)"
echo "Watchdog: sample every ${POLL_SECONDS}s, stop a pass after ${PASS_STALL_SECONDS}s with no change"
echo "  NZB folder:   $NZB_DIR"
echo "  watch folder: $WATCH_DIR"
echo "  staging:      $STAGING_DIR"
echo "  state:        $STATE_PATH"
echo "  log:          $LOG_FILE"
echo "========================================"
echo "Outbox now:   ${OUTBOX_START} NZBs"
echo "Drain now:    jobs/complete/stalled/outbox = ${METRICS_START}"
echo ""

if [[ "$OUTBOX_START" -lt "$QUEUE_HIGH_WATER" ]]; then
  echo "The outbox is already below the mark (${OUTBOX_START} < ${QUEUE_HIGH_WATER}), so the"
  echo "producers will run on their own. Nothing to walk."
  exit 0
fi

if ! $APPLY; then
  echo "Would run, repeatedly, until one of the stop conditions above:"
  echo "    ${PASS_SCRIPT} ${PASS_ARGS[*]}"
  echo ""
  echo "First pass would submit up to what the outbox holds and fetch up to 3"
  echo "finished releases (FETCH_WORKERS). Run with --apply to start."
  exit 0
fi

if [[ -z "$(env_value "$ENV_FILE" TORBOX_API_KEY || true)" ]]; then
  echo "ERROR: TORBOX_API_KEY is not set in ${ENV_FILE}; a pass cannot submit or fetch." >&2
  exit 1
fi

# timer_is_active answers 0 (active), 1 (not active) or 2 (could not tell), and
# the status is captured from the call rather than read out of `if ! f; then
# case "$?"`. That reads the NEGATION's status, which is 0 for both "active" and
# "could not tell" -- so a host with no systemctl would have been reported as a
# host with the timer armed, which is the one reading that stops a walk for the
# wrong reason.
TIMER_STATE=0
timer_is_active || TIMER_STATE=$?
if [[ "$TIMER_STATE" -eq 0 ]]; then
  if ! $FORCE; then
    echo "ERROR: usenet-blackhole.timer is ACTIVE. The walk and the timer would both be" >&2
    echo "       draining this outbox. Run: systemctl --user disable --now usenet-blackhole.timer" >&2
    echo "       (see docs/MAINTENANCE.md — holding the ingest down), or pass --force." >&2
    exit 1
  fi
  echo "WARNING: usenet-blackhole.timer is active and --force was given; two drains are about to run." >&2
elif [[ "$TIMER_STATE" -eq 2 ]]; then
  echo "NOTE: no systemctl here, so whether usenet-blackhole.timer is armed could not be checked."
fi

acquire_lock

# --- the walk ---------------------------------------------------------------

PASS_NUMBER=0
BARREN=0
# Passes the pressure gate refused, counted separately from BARREN. A refused
# pass never started -- scripts/usenet-blackhole.sh exits at its gate before it
# reaches python -- so it is evidence about the host, not about the drain.
# Measured 2026-09-22: 4 of 12 passes in one run were refusals and every one of
# them was counted as "no progress", against a run in which no admitted pass
# failed to move anything.
REFUSED=0
STOP_REASON=""
WALK_START="$(date +%s)"

while :; do
  if [[ "$INTERRUPTED" == "true" ]]; then
    STOP_REASON="interrupted"
    break
  fi

  now="$(date +%s)"
  if [[ "$(outbox_depth "$NZB_DIR")" -lt "$QUEUE_HIGH_WATER" ]]; then
    STOP_REASON="the outbox cleared the mark"
    break
  fi
  if [[ "$PASS_NUMBER" -ge "$MAX_PASSES" ]]; then
    STOP_REASON="pass budget reached (${MAX_PASSES})"
    break
  fi
  if [[ $((now - WALK_START)) -ge $((MAX_HOURS * 3600)) ]]; then
    STOP_REASON="time budget reached (${MAX_HOURS}h)"
    break
  fi
  if [[ "$BARREN" -ge "$MAX_BARREN" ]]; then
    STOP_REASON="${MAX_BARREN} passes in a row made no progress"
    break
  fi
  if [[ "$REFUSED" -ge "$MAX_SKIPPED" ]]; then
    STOP_REASON="the I/O pressure gate refused ${MAX_SKIPPED} passes in a row (the host was too busy to start one)"
    break
  fi

  before="$(metrics)"
  run_pass
  after="$(metrics)"

  if [[ "$PASS_REFUSED" == "true" ]]; then
    REFUSED=$((REFUSED + 1))
    log "the pressure gate refused pass ${PASS_NUMBER} (${REFUSED} in a row); the host read as too busy to start it"
  else
    # An admitted pass is what clears the refusal streak: the gate let this one
    # through, so the host was not too busy to start work.
    REFUSED=0
    if advanced "$before" "$after"; then
      BARREN=0
      log "progress: ${before} -> ${after}"
    else
      BARREN=$((BARREN + 1))
      log "no progress this pass (${BARREN}/${MAX_BARREN}): ${before} -> ${after}"
    fi
  fi

  if [[ "$INTERRUPTED" == "true" ]]; then
    STOP_REASON="interrupted"
    break
  fi

  if [[ "$(outbox_depth "$NZB_DIR")" -lt "$QUEUE_HIGH_WATER" ]]; then
    STOP_REASON="the outbox cleared the mark"
    break
  fi

  if [[ "$PASS_REFUSED" == "true" ]]; then
    # The refusal itself is logged above, once. This says only what happens next.
    log "waiting ${SKIP_COOLDOWN_SECONDS}s before the next attempt"
    sleep_or_break "$SKIP_COOLDOWN_SECONDS" "$$"
  elif [[ "$BARREN" -lt "$MAX_BARREN" ]]; then
    sleep_or_break "$COOLDOWN_SECONDS" "$$"
  fi
done

OUTBOX_END="$(outbox_depth "$NZB_DIR")"
METRICS_END="$(metrics)"

echo ""
echo "========================================"
log "stopped: ${STOP_REASON}"
log "passes run: ${PASS_NUMBER} (${BARREN} in a row with no progress at the end)"
log "outbox:     ${OUTBOX_START} -> ${OUTBOX_END} NZBs (mark ${QUEUE_HIGH_WATER})"
log "drain:      ${METRICS_START} -> ${METRICS_END} (jobs/complete/stalled/outbox)"
log "wall clock: $(( ($(date +%s) - WALK_START) / 60 ))m"
if [[ "$PASS_KILLED" == "true" ]]; then
  echo ""
  echo "The last pass was killed by the watchdog, not by the pass finishing. The"
  echo "releases it was working on have gone to the back of the fetch rotation; run"
  echo "this walk again to attempt different ones, and read ${LOG_FILE} for what it"
  echo "was doing."
fi
if [[ "$OUTBOX_END" -ge "$QUEUE_HIGH_WATER" ]]; then
  echo ""
  echo "The outbox is still at or above the mark, so backlog-search and"
  echo "stremio-library-sync are still standing down."
fi
if [[ "$STOP_REASON" == *"pressure gate refused"* ]]; then
  echo ""
  echo "No pass ran at all: the I/O pressure gate refused every one, which means the"
  echo "pool read as stalled each time it was asked. That is the host protecting"
  echo "itself, not a stuck drain -- check /proc/pressure/io (full avg10) and run"
  echo "this again when it is quieter."
fi
if [[ "$STOP_REASON" == *"no progress"* ]]; then
  echo ""
  echo "Nothing moved for ${MAX_BARREN} passes. Before running it again, read"
  echo "${LOG_FILE} and check the releases named in it -- a release whose fetch"
  echo "keeps failing transiently will keep being rotated to, and the arr-side"
  echo "answer is a pass with --report-failures so the arr blocklists it."
fi

# The walk's answer, not a formality. "The outbox cleared the mark" and "the
# walk gave up with the drain still deep" are different facts about the stack,
# and a caller that cannot tell them apart will read the second as the first.
if [[ "$OUTBOX_END" -lt "$QUEUE_HIGH_WATER" ]]; then
  exit 0
fi
exit 3
