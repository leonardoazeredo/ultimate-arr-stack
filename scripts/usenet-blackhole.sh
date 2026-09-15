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

APPLY=false
VERBOSE=false
REPORT_FAILURES=false
REPORT_DRY_RUN=false
TIMEOUT_HOURS="$DEFAULT_TIMEOUT_HOURS"
STALL_HOURS="$DEFAULT_STALL_HOURS"

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
    --help|-h)
      # The header block at the top of this file, printed verbatim. A fixed
      # range rather than `sed -n '2,/^$/p'`, which BSD sed rejects -- and it
      # has to stop ON the last comment line. One line further and `--help`
      # prints the SCRIPT_DIR assignment below it, which is how this shipped
      # until tests/usenet-blackhole.bats started asserting the output.
      #
      # The range moves whenever a line is added to the header. It was 3,27
      # until the --report-failures paragraph above went in, and 3,40 until
      # --stall-hours did; that test is what notices, so run it after editing
      # the top of this file.
      sed -n '3,46p' "$0" | sed 's/^# \{0,1\}//'
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
if ! TORBOX_API_KEY="$TORBOX_KEY" \
        SONARR_API_KEY="$SONARR_KEY" \
        RADARR_API_KEY="$RADARR_KEY" \
        python3 "${SCRIPT_DIR}/lib/usenet_blackhole.py" \
        "$NZB_DIR" "$WATCH_DIR" "$STAGING_DIR" "$STATE_PATH" "$FAILED_LOG" \
        ${PY_ARGS[@]+"${PY_ARGS[@]}"} \
        --timeout-hours "$TIMEOUT_HOURS" \
        --stall-hours "$STALL_HOURS"; then
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
