#!/bin/bash
set -euo pipefail
#
# Remove stuck/stalled items from Sonarr and Radarr download queues
#
# Torrents frequently stall (dead seeders, stuck metadata, failed imports)
# and sit in queues indefinitely. This script identifies stuck items,
# removes them (with blocklist to prevent re-grabbing the same release),
# and triggers fresh searches for better alternatives.
#
# Usage:
#   ./scripts/queue-cleanup.sh                # dry run (default)
#   ./scripts/queue-cleanup.sh --apply        # actually remove stuck items
#   ./scripts/queue-cleanup.sh --apply -v     # remove with verbose output
#
# Cron (Thursday 2am):
#   0 2 * * 4 $NAS_STACK_DIR/scripts/queue-cleanup.sh --apply >> $NAS_STACK_DIR/logs/queue-cleanup.log 2>&1
#
# Prerequisites:
#   - Sonarr and Radarr running and accessible on localhost
#   - python3 and curl available
#
# What gets removed:
#   - Downloads stalled with no connections
#   - Torrents stuck downloading metadata
#   - Failed imports (completed but can't import)
#   - Downloads with errors (missing files, not available, etc.)
#   - Items at 0% progress for more than 24 hours
#
# What is NEVER removed:
#   - Items with any download progress (even if slow)
#   - Healthy downloads (trackedDownloadStatus == "ok" with progress)
#
# After removal, a fresh search is triggered for each affected
# series (Sonarr) or movie (Radarr) to find better-seeded releases.
#
# ⚠️  This script was generated with LLM assistance and human-reviewed.
#     Read and understand it before running. Do not execute scripts you
#     don't understand on your system. Dry run (no --apply) is the default
#     so you can inspect what it would do first.
#

# Derive stack directory from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAS_STACK_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="$NAS_STACK_DIR/logs/queue-cleanup.log"
MAX_LOG_LINES=1000

# --- Parse arguments ---
APPLY=false
VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    --verbose|-v) VERBOSE=true ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# //; s/^#//; p }' "$0"
      exit 0
      ;;
  esac
done

# --- Output helpers ---
log()  { echo "[queue-cleanup] $1"; }
ok()   { echo "  ✓ $1"; }
skip() { echo "  - $1"; }
fail() { echo "  ✗ $1"; }
info() { echo "  $1"; }
verbose() { $VERBOSE && echo "  [verbose] $1" || true; }

# --- Timestamp ---
echo ""
echo "========================================"
echo "Queue Cleanup — $(date '+%Y-%m-%d %H:%M:%S')"
if $APPLY; then
  echo "Mode: APPLYING (removing stuck items)"
else
  echo "Mode: DRY RUN (use --apply to remove)"
fi
echo "========================================"

# --- Discover API keys from running containers ---
get_api_key() {
  local container="$1"
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
    return 1
  fi
  docker exec "$container" cat /config/config.xml 2>/dev/null \
    | grep -oP '(?<=<ApiKey>)[^<]+' || return 1
}

SONARR_KEY=$(get_api_key sonarr) || true
RADARR_KEY=$(get_api_key radarr) || true

if [[ -z "$SONARR_KEY" ]] && [[ -z "$RADARR_KEY" ]]; then
  log "ERROR: Could not get API keys for Sonarr or Radarr. Are the containers running?"
  exit 1
fi

# --- Main cleanup logic (python3 for JSON processing) ---
# The Python half lives in its own file rather than a heredoc: bats cannot
# reach a heredoc, universalmutator cannot parse one, and pytest cannot
# import one. Argument indices are unchanged -- `python3 -` and
# `python3 file.py` both put the first argument at sys.argv[1].
if ! python3 "${SCRIPT_DIR}/lib/queue_cleanup.py" \
        "$APPLY" "$VERBOSE" "$SONARR_KEY" "$RADARR_KEY"; then
    echo "ERROR: the queue cleanup exited non-zero; no webhook was sent." >&2
    exit 1
fi

# --- Optional: HA webhook notification ---
if $APPLY && [[ -n "${HA_WEBHOOK_URL:-}" ]]; then
  curl -s -m 10 -X POST "$HA_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"Queue Cleanup\",\"message\":\"Weekly queue cleanup completed. Check $NAS_STACK_DIR/logs/queue-cleanup.log for details.\"}" || true
fi

# --- Trim log file ---
if [[ -f "$LOG_FILE" ]]; then
  LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
  if [[ "$LINES" -gt "$MAX_LOG_LINES" ]]; then
    TMPLOG=$(mktemp)
    tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$TMPLOG" && mv "$TMPLOG" "$LOG_FILE"
  fi
fi
