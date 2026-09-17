#!/bin/bash
set -euo pipefail
#
# Turn a Stremio library addition into a Seerr request, so it downloads here.
#
# Adding a title to the Stremio library is one tap on a phone, and nothing in
# this stack listened to it. Seerr is the front door for every other request
# here, so this bridges the two: read the Stremio account's library, resolve
# each newly added title to a TMDB id, and create the Seerr request that routes
# it to Sonarr or Radarr.
#
# Stremio cannot push this. It once shipped an addon `library` resource whose
# handler fired on `libraryAdd`, and then removed it: `defineLibraryHandler` is
# gone from the SDK's builder.js on master, its documentation is 404 on master,
# and the manifest linter recognises only catalog/meta/stream/subtitles. So the
# account's datastore is read on a timer instead.
#
# Usage:
#   ./scripts/stremio-library-sync.sh                     # dry run (default)
#   ./scripts/stremio-library-sync.sh --apply             # create the requests
#   ./scripts/stremio-library-sync.sh --apply -v          # per-item detail
#   ./scripts/stremio-library-sync.sh --apply --max 1     # at most one request
#
# The first --apply with no state file records everything already in the
# library and requests none of it. That is deliberate: measured on this library,
# 122 of its 145 items are in neither arr, and requesting them in one pass is
# the shape of the burst that earned this TorBox account a 90-minute refusal on
# 2026-09-13. --backfill asks for them on purpose, --max at a time.
#
# Scheduled by stremio-library-sync.timer, every ten minutes. Running it by hand
# is how you see what it would do first -- the dry run is the default, and it
# writes no state, so inspecting the queue never consumes it.
#
# Prerequisites:
#   - STREMIO_AUTH_KEY and SEERR_API_KEY in .env
#   - python3 available (3.6+, stdlib only)
#   - the NAS host can reach api.strem.io directly; no VPN, and none is wanted.
#     Nothing here is indexer traffic.
#
# ⚠️  Generated with LLM assistance and human-reviewed. Dry run is the default.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAS_STACK_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$NAS_STACK_DIR/.env"
STATE_PATH="$NAS_STACK_DIR/logs/stremio-library-sync-state.json"
LOG_FILE="$NAS_STACK_DIR/logs/stremio-library-sync.log"

# The timer fires every ten minutes, so this is a little over a day of history.
# Long enough that a run which stopped working can be compared against one that
# worked, short enough that the file stays something a person can read.
MAX_LOG_LINES=2000

# shellcheck source=scripts/lib/env-file.sh
. "${SCRIPT_DIR}/lib/env-file.sh"

APPLY=false
BACKFILL=false
VERBOSE=false
MAX_REQUESTS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true ;;
    --backfill) BACKFILL=true ;;
    --verbose|-v) VERBOSE=true ;;
    --max)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --max needs a number" >&2
        exit 2
      fi
      MAX_REQUESTS="$2"
      shift
      ;;
    --max=*) MAX_REQUESTS="${1#*=}" ;;
    --help|-h)
      # The leading comment block, printed verbatim, stopping at the first line
      # that is not a comment. Not a fixed `sed -n '3,55p'` range, which is the
      # form usenet-blackhole.sh uses and has had to edit four times, once
      # because the range printed a line of code. awk stops on the boundary
      # instead of on a count, so adding a paragraph above cannot break it.
      awk 'NR == 1 { next } /^#/ { header = 1; sub(/^# ?/, ""); print; next } header { exit }' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unrecognised argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# Digits only, so the empty string, a negative and "1.5" are refused here rather
# than reaching python as a ValueError traceback or, worse, reaching the slice
# that bounds the pass as a number it reads differently from what was typed.
if [[ -n "$MAX_REQUESTS" ]]; then
  case "$MAX_REQUESTS" in
    ''|*[!0-9]*)
      echo "ERROR: --max must be a whole number, got '$MAX_REQUESTS'" >&2
      exit 2
      ;;
  esac
fi

STREMIO_KEY=$(env_value "$ENV_FILE" STREMIO_AUTH_KEY || true)
SEERR_KEY=$(env_value "$ENV_FILE" SEERR_API_KEY || true)

log() { echo "[stremio-library-sync] $1"; }

# Checked in both modes, not only under --apply. The one thing an operator does
# with a dry run is decide whether applying is safe, and a dry run that says
# "nothing new" while the key is missing or wrong is the opposite of that
# answer. A bad key is especially quiet here: the Stremio API answers HTTP 200
# with an `error` body rather than a 401, so the failure has to be named before
# the request is made rather than after.
if [[ -z "$STREMIO_KEY" ]]; then
  log "ERROR: STREMIO_AUTH_KEY is not set in $ENV_FILE"
  log "       The sync cannot read the library without it."
  exit 1
fi

if [[ -z "$SEERR_KEY" ]]; then
  log "ERROR: SEERR_API_KEY is not set in $ENV_FILE"
  log "       Requests would be rejected; see Seerr Settings > General."
  exit 1
fi

echo ""
echo "========================================"
echo "Stremio library sync — $(date '+%Y-%m-%d %H:%M:%S')"
if $APPLY; then
  echo "Mode: APPLYING (create Seerr requests)"
else
  echo "Mode: DRY RUN (use --apply to create requests)"
fi
# Printed in both modes. "Backfilling" and "picking up new additions" are
# otherwise indistinguishable in a log that had a queue to work through, and the
# difference is the whole reason this is a flag rather than the default.
if $BACKFILL && [[ ! -f "$STATE_PATH" ]]; then
  echo "Backfill: ON (a first run will treat every library item as new)"
fi
# The cap is printed even when it did nothing this pass, because "capped" and
# "nothing to do" look identical in the summary line otherwise.
if [[ -n "$MAX_REQUESTS" ]]; then
  echo "Per-pass cap: $MAX_REQUESTS"
else
  echo "Per-pass cap: default"
fi
echo "========================================"

mkdir -p "$NAS_STACK_DIR/logs"

# --apply and --verbose are appended only when true. Not `${APPLY:+--apply}`,
# which reads as "add the flag when applying" and is not: `:+` tests for
# non-empty, and APPLY=false is non-empty, so the flag would go on every
# invocation and the banner would say DRY RUN while the pass requested things.
PY_ARGS=()
if $APPLY; then PY_ARGS+=(--apply); fi
if $BACKFILL; then PY_ARGS+=(--backfill); fi
if $VERBOSE; then PY_ARGS+=(--verbose); fi
if [[ -n "$MAX_REQUESTS" ]]; then PY_ARGS+=(--max "$MAX_REQUESTS"); fi

# The keys go through the environment, not argv. `--api-key "$KEY"` would put
# them in python3's command line, which /proc/<pid>/cmdline exposes to every
# user on the box, on a timer that runs every ten minutes. The Python half reads
# STREMIO_AUTH_KEY and SEERR_API_KEY itself.
#
# ${PY_ARGS[@]+"${PY_ARGS[@]}"} rather than a bare expansion: with `set -u`, an
# empty array is an unbound variable in bash before 4.4, and /bin/bash on macOS
# is 3.2.
if ! STREMIO_AUTH_KEY="$STREMIO_KEY" \
        SEERR_API_KEY="$SEERR_KEY" \
        python3 "${SCRIPT_DIR}/lib/stremio_library.py" "$STATE_PATH" \
        ${PY_ARGS[@]+"${PY_ARGS[@]}"}; then
  echo "ERROR: the stremio library sync pass exited non-zero." >&2
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
