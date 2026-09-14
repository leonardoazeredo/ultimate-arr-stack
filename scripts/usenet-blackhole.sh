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
#   ./scripts/usenet-blackhole.sh              # dry run (default)
#   ./scripts/usenet-blackhole.sh --apply      # submit, poll and fetch
#   ./scripts/usenet-blackhole.sh --apply -v   # with per-job progress
#
# Scheduled by usenet-blackhole.timer, every 2 minutes. Running it by hand is
# how you see what it would do first.
#
# Prerequisites:
#   - TORBOX_API_KEY in .env
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

APPLY=false
VERBOSE=false
TIMEOUT_HOURS="$DEFAULT_TIMEOUT_HOURS"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true ;;
    --verbose|-v) VERBOSE=true ;;
    --timeout-hours)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --timeout-hours needs a number" >&2
        exit 2
      fi
      TIMEOUT_HOURS="$2"
      shift
      ;;
    --timeout-hours=*) TIMEOUT_HOURS="${1#*=}" ;;
    --help|-h)
      # The header block at the top of this file, printed verbatim. A fixed
      # range rather than `sed -n '2,/^$/p'`, which BSD sed rejects -- and it
      # has to stop ON the last comment line. One line further and `--help`
      # prints the SCRIPT_DIR assignment below it, which is how this shipped
      # until tests/usenet-blackhole.bats started asserting the output.
      sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'
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

log() { echo "[usenet-blackhole] $1"; }

echo ""
echo "========================================"
echo "Usenet Blackhole — $(date '+%Y-%m-%d %H:%M:%S')"
if $APPLY; then
  echo "Mode: APPLYING (submit, poll, fetch; timeout ${TIMEOUT_HOURS}h)"
else
  echo "Mode: DRY RUN (timeout ${TIMEOUT_HOURS}h, use --apply to submit)"
fi
echo "========================================"

TORBOX_KEY=$(env_value "$ENV_FILE" TORBOX_API_KEY || true)

if $APPLY && [[ -z "$TORBOX_KEY" ]]; then
  log "ERROR: TORBOX_API_KEY is not set in .env."
  exit 1
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

# The key goes through the environment, not argv -- the same fix
# scripts/queue-cleanup.sh carries, for the same reason: `--api-key "$KEY"`
# puts the TorBox token in python3's command line, which /proc/<pid>/cmdline
# exposes to every user on the box, on a timer that runs every two minutes.
# The Python half reads TORBOX_API_KEY itself; the --api-key flag still exists
# for a one-off run where exporting is more trouble than it is worth.
#
# ${PY_ARGS[@]+"${PY_ARGS[@]}"} rather than a bare expansion: with `set -u`, an
# empty array is an unbound variable in bash before 4.4, and /bin/bash on macOS
# is 3.2.
if ! TORBOX_API_KEY="$TORBOX_KEY" \
        python3 "${SCRIPT_DIR}/lib/usenet_blackhole.py" \
        "$NZB_DIR" "$WATCH_DIR" "$STAGING_DIR" "$STATE_PATH" "$FAILED_LOG" \
        ${PY_ARGS[@]+"${PY_ARGS[@]}"} \
        --timeout-hours "$TIMEOUT_HOURS"; then
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
