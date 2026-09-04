#!/bin/bash
set -euo pipefail
#
# Fix Sonarr series folder names to match the configured folder format
#
# When TRaSH naming is enabled, Sonarr expects folders like:
#   "Show Name (2024) [tvdbid-123456]"
# but existing folders may be just "Show Name (2024)".
#
# This causes duplicate folders and entries in Jellyfin when Sonarr downloads
# new episodes into the expected folder while old episodes sit in the old one.
#
# This script:
#   1. Reads Sonarr's configured series folder format
#   2. Computes the expected folder name for each series
#   3. If a series' current path doesn't match, uses Sonarr's API to move it
#      (Sonarr renames the folder on disk AND updates its database atomically)
#
# Usage:
#   ./scripts/fix-sonarr-folders.sh            # dry run (default)
#   ./scripts/fix-sonarr-folders.sh --apply     # actually rename
#
# Prerequisites:
#   - Sonarr running and accessible on localhost:8989
#   - SONARR_API_KEY set in .env (or .env.nas.backup)
#   - python3 and curl available
#
# ⚠️  This script was generated with LLM assistance and human-reviewed.
#     Read and understand it before running. Do not execute scripts you
#     don't understand on your system. Dry run (no --apply) is the default
#     so you can inspect what it would do first.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

# shellcheck source=scripts/lib/env-file.sh
. "${SCRIPT_DIR}/lib/env-file.sh"

# Find API key
SONARR_API_KEY=""
for f in "${REPO_ROOT}/.env" "${REPO_ROOT}/.env.nas.backup"; do
  if [ -f "$f" ]; then
    SONARR_API_KEY=$(env_value "$f" SONARR_API_KEY || true)
    [ -n "$SONARR_API_KEY" ] && break
  fi
done

if [ -z "$SONARR_API_KEY" ]; then
  echo "ERROR: SONARR_API_KEY not found in .env or .env.nas.backup"
  exit 1
fi

APPLY=false
if [ "${1:-}" = "--apply" ]; then
  APPLY=true
fi

SONARR_URL="http://localhost:8989"

echo "=== Sonarr Folder Fixer ==="
if [ "$APPLY" = "false" ]; then
  echo "Mode: DRY RUN (use --apply to rename)"
else
  echo "Mode: APPLYING CHANGES"
fi
echo ""

# The Python half lives in its own file rather than a heredoc: bats cannot
# reach a heredoc, universalmutator cannot parse one, and pytest cannot
# import one. Argument indices are unchanged -- `python3 -` and
# `python3 file.py` both put the first argument at sys.argv[1].
if ! python3 "${SCRIPT_DIR}/lib/fix_sonarr_folders.py" \
        "$SONARR_API_KEY" "$SONARR_URL" "$APPLY"; then
    echo "ERROR: the folder fixer exited non-zero; nothing further was attempted." >&2
    exit 1
fi
