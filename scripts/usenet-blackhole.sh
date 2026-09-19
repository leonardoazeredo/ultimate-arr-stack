#!/bin/bash
set -euo pipefail
#
# Move NZBs between the arrs and TorBox, for the UsenetBlackhole download client.
#
# SABnzbd here talks to nntp.torbox.app, which serves articles only up to about
# 90 days old (measured 2026-09-14: 1/34/60/86-day releases resolved every time,
# 101/138-day releases resolved none of them). TorBox's API has no such limit --
# the same 138-day-old NZB completed at 836 MB -- so this submits to the API
# instead of reading from that cache. See scripts/lib/usenet_blackhole.py for
# the full evidence and the arr-side contract.
#
# Usage:
#   ./scripts/usenet-blackhole.sh                    # dry run (default)
#   ./scripts/usenet-blackhole.sh --apply            # submit, poll and fetch
#   ./scripts/usenet-blackhole.sh --apply -v         # with per-job progress
#   ./scripts/usenet-blackhole.sh --apply --report-failures
#   ./scripts/usenet-blackhole.sh --apply --report-dry-run
#   ./scripts/usenet-blackhole.sh --apply --max-inflight 6
#
# --report-failures tells the owning arr when a release reaches a terminal
# failure, via POST /api/v3/history/failed/{id}: the arr marks the grab failed,
# blocklists the release and searches for a replacement. Without it the arr
# never learns, because a blackhole client reports no queue -- so the same dead
# release is grabbed again on the next missing-episode search. Off by default;
# turn it on after a day of --report-dry-run has been hand-checked, because a
# wrong history match blocklists a release that was fine. --report-dry-run logs
# the matched title next to the release name and calls nothing.
#
# --stall-hours (default 4) fails a job whose TorBox-reported progress has not
# moved for that long, rather than letting it hold one of the account's ten
# concurrent slots until --timeout-hours. A release that keeps moving is still
# bounded by --timeout-hours, which stays the outer limit for genuinely large
# downloads; a record with no progress field at all falls back to that bound.
#
# --max-inflight (default 0, off) stops submitting for the pass once that many
# jobs are in flight, below TorBox's own ten. Measured over the retained window:
# nine of the ten slots were held by jobs 3-21h old while only 4 of 50
# submissions were ever fetched, so the question is whether fewer concurrent
# jobs complete more of themselves. Measure the fetch rate at 6 against 10
# before keeping a value -- a ceiling set too low trades wasted slots for idle
# ones. Reaching it costs no TorBox call: the check runs before the upload.
#
# Scheduled by usenet-blackhole.timer, every 2 minutes. Running it by hand is
# how you see what it would do first.
#
# Prerequisites:
#   - TORBOX_API_KEY in .env
#   - SONARR_API_KEY / RADARR_API_KEY in .env once --report-failures is on;
#     without them the pass still runs and simply reports nothing
#   - the arrs configured with a UsenetBlackhole client pointed at the two
#     folders below (docs/MAINTENANCE.md); the third is ours alone
#   - python3, curl and unzip-equivalent (zipfile module) available
#
# ⚠️  Generated with LLM assistance and human-reviewed. Dry run is the default.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAS_STACK_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$NAS_STACK_DIR/.env"

# shellcheck source=scripts/lib/env-file.sh
. "${SCRIPT_DIR}/lib/env-file.sh"

# Both live under MEDIA_ROOT, because a blackhole is a filesystem handshake:
# the arr writes the .nzb and then looks for the result, and it does both from
# inside its container where ${MEDIA_ROOT} is mounted at /data. The paths the
# arr is configured with are therefore the /data ones, and these are their
# host-side counterparts.
#
# `blackhole/` rather than SABnzbd's `/data/usenet/{incomplete,complete}` on
# purpose: the two clients would otherwise share a watch folder, and the arr
# would see SABnzbd's half-finished downloads as completed blackhole releases.
#
# Staging is a sibling of the watch folder and NOT a `.incoming-` directory
# inside it. Sonarr does not skip dot-directories at the top level of a watch
# folder -- `GetDirectories` skips only `FileAttributes.System`, and the regex
# that filters them in `FilterPaths` needs a trailing separator that
# `GetRelativePath` has already trimmed -- so a staging directory in there is
# reported as a completed download and its half-written files get imported.
MEDIA_ROOT_VALUE=$(env_value "$ENV_FILE" MEDIA_ROOT || true)
MEDIA_ROOT_VALUE="${MEDIA_ROOT_VALUE:-$NAS_STACK_DIR/data}"
NZB_DIR="${USENET_NZB_DIR:-$MEDIA_ROOT_VALUE/usenet/blackhole/nzb}"
WATCH_DIR="${USENET_WATCH_DIR:-$MEDIA_ROOT_VALUE/usenet/blackhole/complete}"
STAGING_DIR="${USENET_STAGING_DIR:-$MEDIA_ROOT_VALUE/usenet/blackhole/staging}"
STATE_PATH="$NAS_STACK_DIR/logs/usenet-blackhole-state.json"
FAILED_LOG="$NAS_STACK_DIR/logs/usenet-blackhole-failed.log"
LOG_FILE="$NAS_STACK_DIR/logs/usenet-blackhole.log"
MAX_LOG_LINES=1000

# A job that never completes is invisible to a blackhole client -- the arr sees
# only what appears in the watch folder -- so this bound is what turns a stuck
# release into a log line someone can act on.
DEFAULT_TIMEOUT_HOURS=24

# A job whose TorBox-reported progress has not moved for this long is going
# nowhere, and it is holding one of the account's ten concurrent slots while it
# goes there. Measured 2026-09-15: the oldest in-flight job was 21.2h old with
# nothing to show, so without this rule it holds that slot for the full timeout.
# The timeout stays the bound for a release that keeps moving.
DEFAULT_STALL_HOURS=4

# The operator's ceiling on jobs in flight, below the ten concurrent slots
# TorBox itself allows. Off by default, because the only ceiling measured so far
# is the provider's: nine of its ten slots were held by jobs 3-21h old while 4
# of 50 submissions were ever fetched, and whether a lower ceiling completes
# more of them is the measurement this exists to make. Off is what ships; a
# value is kept only after the fetch rate at 6 and at 10 have been compared.
DEFAULT_MAX_INFLIGHT=0

# io full avg10 at or above which a pass refuses to start. The reading and the
# reason for `full` over `some` are at the gate below; the number is 20 because
# the healthy baseline measured on this NAS is 1.9% and the incident of
# 2026-09-18 sat between 78% and 81% for hours, so 20% is high enough that an
# ordinary import or a transcoding sweep never reaches it and low enough to fire
# long before the box is wedged. Read from the environment so a host whose
# baseline differs can be tuned without editing the script.
PSI_IO_LIMIT="${PSI_IO_LIMIT:-20}"

# io full avg10 from /proc/pressure/io, or nothing when PSI is unavailable.
#
# `full` rather than `some`: `some` counts a single stalled task, which is
# ordinary on a busy box, while `full` means every runnable task was stalled on
# I/O at once. Measured on this NAS: 1.9% healthy, 78-81% during the incident of
# 2026-09-18.
#
# PSI_IO_PATH exists so a test can point this at a fixture; the real file is
# Linux-only and the suite also runs on macOS.
psi_io_full_avg10() {
  local path="${PSI_IO_PATH:-/proc/pressure/io}"
  [[ -r "$path" ]] || return 1
  awk '$1 == "full" {
         for (i = 2; i <= NF; i++) {
           split($i, kv, "=")
           if (kv[1] == "avg10") { print kv[2]; exit }
         }
       }' "$path"
}

APPLY=false
VERBOSE=false
REPORT_FAILURES=false
REPORT_DRY_RUN=false
TIMEOUT_HOURS="$DEFAULT_TIMEOUT_HOURS"
STALL_HOURS="$DEFAULT_STALL_HOURS"
MAX_INFLIGHT="$DEFAULT_MAX_INFLIGHT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true ;;
    --verbose|-v) VERBOSE=true ;;
    # Two halves of one switch, and they are not aliases. --report-failures is
    # the live one: it POSTs. --report-dry-run resolves the match and logs both
    # titles without calling anything, which is the mode the rollout runs for a
    # day first -- a wrong history match blocklists a release that was fine, and
    # the only thing that catches it before it does is reading the pairs.
    --report-failures) REPORT_FAILURES=true ;;
    --report-dry-run) REPORT_DRY_RUN=true ;;
    --timeout-hours)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --timeout-hours needs a number" >&2
        exit 2
      fi
      TIMEOUT_HOURS="$2"
      shift
      ;;
    --timeout-hours=*) TIMEOUT_HOURS="${1#*=}" ;;
    --stall-hours)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --stall-hours needs a number" >&2
        exit 2
      fi
      STALL_HOURS="$2"
      shift
      ;;
    --stall-hours=*) STALL_HOURS="${1#*=}" ;;
    --max-inflight)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --max-inflight needs a number" >&2
        exit 2
      fi
      MAX_INFLIGHT="$2"
      shift
      ;;
    --max-inflight=*) MAX_INFLIGHT="${1#*=}" ;;
    --help|-h)
      # The header block at the top of this file, printed verbatim. A fixed
      # range rather than `sed -n '2,/^$/p'`, which BSD sed rejects -- and it
      # has to stop ON the last comment line. One line further and `--help`
      # prints the SCRIPT_DIR assignment below it, which is how this shipped
      # until tests/usenet-blackhole.bats started asserting the output.
      #
      # The range moves whenever a line is added to the header. It was 3,27
      # until the --report-failures paragraph above went in, 3,40 until
      # --stall-hours did, and 3,46 until --max-inflight did; that test is what
      # notices, so run it after editing the top of this file.
      sed -n '3,55p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unrecognised argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

case "$TIMEOUT_HOURS" in
  ''|*[!0-9.]*|*.*.*)
    echo "ERROR: --timeout-hours must be a number, got '$TIMEOUT_HOURS'" >&2
    exit 2
    ;;
esac

case "$STALL_HOURS" in
  ''|*[!0-9.]*|*.*.*)
    echo "ERROR: --stall-hours must be a number, got '$STALL_HOURS'" >&2
    exit 2
    ;;
esac

# Zero is numeric and gets past the pattern above, and it is the one value that
# turns the stall rule into "fail every job on its first unchanged poll" -- no
# progress can move within zero hours. Negatives -- the "-" is not in the
# allowed set above -- are already refused there. awk rather than a `case` for
# the float comparison, and not bc: bc is not installed everywhere this runs.
if ! awk -v hours="$STALL_HOURS" 'BEGIN { exit !(hours > 0) }'; then
  echo "ERROR: --stall-hours must be greater than 0, got '$STALL_HOURS'" >&2
  exit 2
fi

# Digits only, so the empty string, a negative and "1.5" are all refused here
# rather than reaching python as a ValueError traceback or, worse, reaching the
# cap check as a number it reads differently from what the operator typed. Zero
# is valid and means off, which is why this is not the stall-hours check again.
case "$MAX_INFLIGHT" in
  ''|*[!0-9]*)
    echo "ERROR: --max-inflight must be a whole number, got '$MAX_INFLIGHT'" >&2
    exit 2
    ;;
esac

# Base ten, said out loud. Bash reads a leading zero as octal, so "08" and "09"
# are not numbers it can compare: the `-eq` below errors with "value too great
# for base" and takes the else branch, leaving the banner to print the
# operator's spelling ("08") while python reads the same string as 8 -- two
# halves of one pass disagreeing about the cap. 10# forces the decimal value
# both ways, and keeps an arithmetic error that errexit only tolerates here
# because it sits in an `if` condition out of the timer's log.
MAX_INFLIGHT=$((10#$MAX_INFLIGHT))

log() { echo "[usenet-blackhole] $1"; }

echo ""
echo "========================================"
echo "Usenet Blackhole — $(date '+%Y-%m-%d %H:%M:%S')"
if $APPLY; then
  echo "Mode: APPLYING (submit, poll, fetch; timeout ${TIMEOUT_HOURS}h)"
else
  echo "Mode: DRY RUN (timeout ${TIMEOUT_HOURS}h, use --apply to submit)"
fi
# Its own line rather than folded into the mode line above: the timeout bound
# and the stall bound answer different questions ("is it never going to finish"
# versus "is it not moving"), and a run that only looked at one of them would
# read as covered by the other.
echo "Stall rule: no progress for ${STALL_HOURS}h fails the job"
# Printed in both modes, "off" included. The cap is the one bound whose absence
# and whose presence at a value look identical in a pass that had nothing to
# submit, and the difference is the whole point of running it at 6 for a while.
if [[ "$MAX_INFLIGHT" -eq 0 ]]; then
  echo "In-flight cap: off"
else
  echo "In-flight cap: $MAX_INFLIGHT"
fi
# Said out loud in both modes, because "reporting is on" and "reporting is off"
# are otherwise indistinguishable from a log that had nothing to report -- and
# the difference matters: a wrong match blocklists a release that was fine.
if $REPORT_FAILURES; then
  echo "Failure reporting: ON (POST /api/v3/history/failed)"
elif $REPORT_DRY_RUN; then
  echo "Failure reporting: DRY RUN (logged, never sent)"
else
  echo "Failure reporting: off"
fi
echo "========================================"

TORBOX_KEY=$(env_value "$ENV_FILE" TORBOX_API_KEY || true)
SONARR_KEY=$(env_value "$ENV_FILE" SONARR_API_KEY || true)
RADARR_KEY=$(env_value "$ENV_FILE" RADARR_API_KEY || true)

if $APPLY && [[ -z "$TORBOX_KEY" ]]; then
  log "ERROR: TORBOX_API_KEY is not set in .env."
  exit 1
fi

# A missing arr key is a warning, not a stop. Reporting is bookkeeping on a
# script whose job is moving bytes: refusing to run over it would stop every
# download on the box because one credential was wrong. The Python half reports
# the same thing and carries on.
if $REPORT_FAILURES && [[ -z "$SONARR_KEY" ]] && [[ -z "$RADARR_KEY" ]]; then
  log "WARNING: neither SONARR_API_KEY nor RADARR_API_KEY is set; nothing will be reported."
fi

# The NZB folder is created here rather than required: the arr writes into it,
# and an absent folder makes the arr's own connection test fail in a way that
# reads as a misconfiguration. The staging folder is ours; the arr never sees it.
mkdir -p "$NZB_DIR" "$WATCH_DIR" "$STAGING_DIR" "$NAS_STACK_DIR/logs"

# --apply and --verbose are appended only when true. This was
# `${APPLY:+--apply}` until tests/usenet-blackhole.bats existed, which reads as
# "add the flag when applying" and is not: `:+` tests for non-empty, and
# APPLY=false is non-empty, so the flag went on every invocation. The banner
# said DRY RUN while the pass submitted and fetched -- a dry run that applies is
# worse than no dry run, because it is the mode an operator uses to decide
# whether applying is safe.
PY_ARGS=()
if $APPLY; then PY_ARGS+=(--apply); fi
if $VERBOSE; then PY_ARGS+=(--verbose); fi
if $REPORT_FAILURES; then PY_ARGS+=(--report-failures); fi
if $REPORT_DRY_RUN; then PY_ARGS+=(--report-dry-run); fi

# The keys go through the environment, not argv -- the same fix
# scripts/queue-cleanup.sh carries, for the same reason: `--api-key "$KEY"`
# puts the TorBox token in python3's command line, which /proc/<pid>/cmdline
# exposes to every user on the box, on a timer that runs every two minutes.
# The Python half reads TORBOX_API_KEY / SONARR_API_KEY / RADARR_API_KEY itself;
# the --api-key flag still exists for a one-off run where exporting is more
# trouble than it is worth.
#
# ${PY_ARGS[@]+"${PY_ARGS[@]}"} rather than a bare expansion: with `set -u`, an
# empty array is an unbound variable in bash before 4.4, and /bin/bash on macOS
# is 3.2.

# --- host I/O pressure gate -------------------------------------------------
#
# A pass writes to the same pool the rest of the stack reads from, so a pass
# that starts while the host is already stalled is the one thing that cannot
# help: it lengthens the stall it is competing with. On 2026-09-18 this NAS sat
# at load 58 with io full avg10 between 78% and 81% for hours; every container
# accepted a TCP connection and answered nothing.
#
# Fails OPEN, deliberately. A kernel built without PSI, or a container that
# cannot read /proc/pressure, must not become a stack that silently stops
# downloading -- and "the guard ran and found nothing" and "the guard could not
# run" must not be the same observable result.
HOST_PRESSURE="$(psi_io_full_avg10 || true)"
if [[ -n "$HOST_PRESSURE" ]] &&
   awk -v seen="$HOST_PRESSURE" -v limit="$PSI_IO_LIMIT" \
       'BEGIN { exit !(seen >= limit) }'; then
  echo "[pressure-gate] host I/O is stalled (io full avg10=${HOST_PRESSURE}%, limit ${PSI_IO_LIMIT}%); skipping this pass"
  exit 0
fi

if ! TORBOX_API_KEY="$TORBOX_KEY" \
        SONARR_API_KEY="$SONARR_KEY" \
        RADARR_API_KEY="$RADARR_KEY" \
        python3 "${SCRIPT_DIR}/lib/usenet_blackhole.py" \
        "$NZB_DIR" "$WATCH_DIR" "$STAGING_DIR" "$STATE_PATH" "$FAILED_LOG" \
        ${PY_ARGS[@]+"${PY_ARGS[@]}"} \
        --timeout-hours "$TIMEOUT_HOURS" \
        --stall-hours "$STALL_HOURS" \
        --max-inflight "$MAX_INFLIGHT"; then
  echo "ERROR: the usenet blackhole pass exited non-zero." >&2
  exit 1
fi

# Trim the log, but only on a real run: a dry run must not be the thing that
# changes what the operator is reading. Same rule as queue-cleanup.sh.
if $APPLY && [[ -f "$LOG_FILE" ]]; then
  LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
  if [[ "$LINES" -gt "$MAX_LOG_LINES" ]]; then
    TMPLOG=$(mktemp "${LOG_FILE}.XXXXXX")
    trap 'rm -f "$TMPLOG"' EXIT
    tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$TMPLOG"
    mv "$TMPLOG" "$LOG_FILE"
    trap - EXIT
  fi
fi
