#!/bin/bash
set -euo pipefail
#
# Search a bounded slice of the Sonarr/Radarr missing backlog.
#
# Neither arr searches its own backlog. They search for NEW releases (RSS) and
# for things already in their queue, so a film added in August that was never
# found sits missing indefinitely. Measured on this NAS 2026-09-13: 24 films
# missing -- 97 grabbable releases available for one of them -- and 3,107
# episodes missing across 42 series, while the only grabs that day were ones a
# human asked for by hand.
#
# Usage:
#   ./scripts/backlog-search.sh                 # dry run (default)
#   ./scripts/backlog-search.sh --apply         # actually queue searches
#   ./scripts/backlog-search.sh --apply -v      # verbose
#   ./scripts/backlog-search.sh --limit 25      # seasons per run (Sonarr only)
#
# Scheduled by backlog-search.timer (installed as a --user unit -- see
# docs/MAINTENANCE.md). Running it by hand is still the way to see what it
# would do first.
#
# THE TWO SERVICES ARE PACED DIFFERENTLY, ON MEASUREMENT
#
# Both arrs ship a search-everything command and both are a trap at this
# library's size. Sonarr's is the dangerous one: `MissingEpisodeSearch` opened
# with "Performing search for 3116 episodes" on 2026-09-13, could not be
# cancelled (Sonarr answers 409 for a command that has already started), and
# had to be killed by restarting the container. That is the shape of the burst
# that earned this account a 90-minute TorBox refusal earlier the same day.
#
#   Sonarr  bounded: at most --limit seasons per run, walking the backlog in a
#           stable order. ~207 seasons here, ten per run every four hours.
#           Once fewer than --limit seasons remain it switches to the bulk
#           command to finish the tail -- bounded by definition by then.
#           Work is per season, so one SeasonSearch covers a season instead of
#           one request per episode: ~200 requests instead of ~3,100.
#
#   Radarr  bulk with a cooldown, the opposite call and for a measured reason:
#           `MissingMoviesSearch` grabbed 5 films in 4 minutes, while
#           `MoviesSearch` on a single film processed 2-4 releases per call and
#           grabbed nothing -- even for a film with 22 approved and 43
#           download-allowed releases in the same indexer results. The
#           per-film path is what does not work; the bulk one does. It is
#           affordable because the candidate set is 24 films, and the cooldown
#           (--cooldown, default 6h) stops it re-presenting that set every
#           interval.
#
# Prerequisites:
#   - Sonarr and Radarr running and accessible on localhost
#   - SONARR_API_KEY / RADARR_API_KEY set in .env (a key rotated in the app
#     without updating .env will 401 here)
#   - python3 and curl available
#
# ⚠️  Generated with LLM assistance and human-reviewed. Dry run is the default
#     so you can inspect what it would do before letting it queue anything.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAS_STACK_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="$NAS_STACK_DIR/logs/backlog-search.log"
STATE_PATH="$NAS_STACK_DIR/logs/backlog-search-state.json"
ENV_FILE="$NAS_STACK_DIR/.env"
MAX_LOG_LINES=1000

# Ten units per service per run. Chosen against the timer's interval, not in
# isolation: at every 4 hours that is 60 units a day, enough to clear this
# backlog's ~200 Sonarr seasons in a few days while never presenting more than
# ten indexer searches at once.
DEFAULT_LIMIT=10

# Minimum hours between two full film searches. Radarr's sweep is bulk (see
# the header for why), so this is what stops it re-presenting the same 24
# films to the indexers every interval.
DEFAULT_COOLDOWN_HOURS=6

# shellcheck source=scripts/lib/env-file.sh
. "${SCRIPT_DIR}/lib/env-file.sh"
# shellcheck source=scripts/lib/queue_high_water.sh
. "${SCRIPT_DIR}/lib/queue_high_water.sh"

APPLY=false
VERBOSE=false
LIMIT="$DEFAULT_LIMIT"
COOLDOWN="$DEFAULT_COOLDOWN_HOURS"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true ;;
    --verbose|-v) VERBOSE=true ;;
    --limit)
      # No shift-without-value: `--limit` as the last argument would otherwise
      # fall through and quietly keep the default, which reads as "10 was
      # accepted" when nothing was.
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --limit needs a number" >&2
        exit 2
      fi
      LIMIT="$2"
      shift
      ;;
    --limit=*) LIMIT="${1#*=}" ;;
    --cooldown)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --cooldown needs a number of hours" >&2
        exit 2
      fi
      COOLDOWN="$2"
      shift
      ;;
    --cooldown=*) COOLDOWN="${1#*=}" ;;
    --help|-h)
      # The header block at the top of this file, printed verbatim.
      #
      # `sed -n '2,/<blank>/p'` with several commands was the obvious
      # one-liner and is GNU-only: BSD sed rejects it ("extra characters
      # at the end of p command"), so on macOS --help printed sed's error
      # and exited 1 instead of the usage block. awk behaved differently
      # inside this script than standalone. A fixed range costs one line
      # to maintain and cannot break: the header ends at line 57.
      sed -n '3,57p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unrecognised argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

case "$LIMIT" in
  ''|*[!0-9]*)
    echo "ERROR: --limit must be a positive integer, got '$LIMIT'" >&2
    exit 2
    ;;
esac
if [[ "$LIMIT" -lt 1 ]]; then
  echo "ERROR: --limit must be at least 1, got $LIMIT" >&2
  exit 2
fi

# Whole hours or a decimal, so "6" and "6.5" both work. Rejected rather than
# coerced: a typo silently becoming 0 would disable the cooldown and let the
# bulk film search re-fire on every interval, which is the burst this exists
# to avoid.
case "$COOLDOWN" in
  ''|*[!0-9.]*|*.*.*)
    echo "ERROR: --cooldown must be a number of hours, got '$COOLDOWN'" >&2
    exit 2
    ;;
esac

log() { echo "[backlog-search] $1"; }

echo ""
echo "========================================"
echo "Backlog Search — $(date '+%Y-%m-%d %H:%M:%S')"
if $APPLY; then
  echo "Mode: APPLYING (limit ${LIMIT} season(s)/run, film cooldown ${COOLDOWN}h)"
else
  echo "Mode: DRY RUN (limit ${LIMIT} season(s)/run, film cooldown ${COOLDOWN}h)"
fi
echo "========================================"

# Queued searches become NZBs, and every NZB becomes local I/O for the
# blackhole. The backlog this walks was measured at 4,614 missing episodes
# across 71 series against a drain of about 24 releases an hour, so a deep
# outbox means this pass is queueing work the host cannot absorb.
MEDIA_ROOT_VALUE="$(env_value "$ENV_FILE" MEDIA_ROOT || true)"
NZB_DIR="${USENET_NZB_DIR:-${MEDIA_ROOT_VALUE:-$NAS_STACK_DIR/data}/usenet/blackhole/nzb}"
OUTBOX_NOW="$(outbox_depth "$NZB_DIR")"
if outbox_over_high_water "$NZB_DIR"; then
  echo "Outbox: $OUTBOX_NOW NZBs waiting (mark ${QUEUE_HIGH_WATER}); skipping this pass"
  exit 0
fi
echo "Outbox: $OUTBOX_NOW NZBs waiting (mark ${QUEUE_HIGH_WATER})"

SONARR_KEY=$(env_value "$ENV_FILE" SONARR_API_KEY || true)
RADARR_KEY=$(env_value "$ENV_FILE" RADARR_API_KEY || true)

if [[ -z "$SONARR_KEY" ]] && [[ -z "$RADARR_KEY" ]]; then
  log "ERROR: Could not get API keys for Sonarr or Radarr. Check SONARR_API_KEY / RADARR_API_KEY are set in .env."
  exit 1
fi

# The Python half lives in its own file rather than a heredoc: bats cannot reach
# a heredoc, universalmutator cannot parse one, and pytest cannot import one.
#
# Keys go through the environment, never argv -- argv is world-readable via
# /proc/<pid>/cmdline, and this runs on a timer.
if ! SONARR_API_KEY="$SONARR_KEY" RADARR_API_KEY="$RADARR_KEY" \
        python3 "${SCRIPT_DIR}/lib/backlog_search.py" "$APPLY" "$VERBOSE" "$LIMIT" "$STATE_PATH" "$COOLDOWN"; then
    echo "ERROR: the backlog search exited non-zero." >&2
    exit 1
fi

# Trim the log, but only on a real run: a dry run must not be the thing that
# changes what the operator is reading. Same rule as queue-cleanup.sh, and for
# the same reason -- it was learned there.
if $APPLY && [[ -f "$LOG_FILE" ]]; then
  LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
  if [[ "$LINES" -gt "$MAX_LOG_LINES" ]]; then
    # Beside the log rather than in /tmp: on the NAS those are different
    # filesystems, so `mv` would be a copy-then-unlink that can leave the log
    # half-written if it dies partway. The trap is why a failing `tail` no
    # longer leaks a temp file per run.
    TMPLOG=$(mktemp "${LOG_FILE}.XXXXXX")
    trap 'rm -f "$TMPLOG"' EXIT
    tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$TMPLOG"
    mv "$TMPLOG" "$LOG_FILE"
    trap - EXIT
  fi
fi
