#!/bin/bash
set -euo pipefail
#
# Fix Radarr movie paths after TRaSH naming reorganize
#
# When TRaSH naming is applied and "Organize" is run, Radarr renames directories
# on disk (e.g., "Avatar The Way of Water" → "Avatar - The Way of Water") but
# sometimes the database paths don't update. This causes "MissingFromDisk" errors.
#
# This script compares Radarr's database paths against actual directories on disk,
# fixes any mismatches via the Radarr API, and triggers a refresh.
#
# Usage:
#   ./scripts/fix-radarr-paths.sh
#
# Prerequisites:
#   - Radarr running and accessible on localhost:7878
#   - RADARR_API_KEY set in .env
#   - python3 available
#
# ⚠️  This script was generated with LLM assistance and human-reviewed.
#     Read and understand it before running. Do not execute scripts you
#     don't understand on your system.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

# shellcheck source=scripts/lib/env-file.sh
. "${SCRIPT_DIR}/lib/env-file.sh"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env not found at $ENV_FILE"
  exit 1
fi

RADARR_API_KEY=$(env_value "$ENV_FILE" RADARR_API_KEY || true)
if [ -z "$RADARR_API_KEY" ]; then
  echo "ERROR: RADARR_API_KEY not found in .env"
  exit 1
fi

MEDIA_ROOT=$(env_value "$ENV_FILE" MEDIA_ROOT || true)
MOVIES_DIR="${MEDIA_ROOT}/media/movies"

if [ ! -d "$MOVIES_DIR" ]; then
  echo "ERROR: Movies directory not found at $MOVIES_DIR"
  exit 1
fi

echo "=== Radarr Path Fixer ==="
echo "Movies dir: $MOVIES_DIR"
echo ""

RADARR_URL="http://localhost:7878"

# Use unique temp files (avoids /tmp sticky-bit issues across users)
TMPDIR=$(mktemp -d /tmp/fix-radarr-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Dump current state
curl -s "${RADARR_URL}/api/v3/movie?apikey=${RADARR_API_KEY}" > "$TMPDIR/movies.json"
ls -1 "$MOVIES_DIR" > "$TMPDIR/disk_dirs.txt"

# Run the fix
# The Python half lives in its own file rather than a heredoc: bats cannot
# reach a heredoc, universalmutator cannot parse one, and pytest cannot
# import one. Argument indices are unchanged -- `python3 -` and
# `python3 file.py` both put the first argument at sys.argv[1]. RADARR_URL is
# passed through rather than duplicated as a second hardcoded constant in the
# Python module -- see fix-sonarr-folders.sh/fix_sonarr_folders.py for the
# same pattern.
if ! python3 "${SCRIPT_DIR}/lib/fix_radarr_paths.py" "$RADARR_API_KEY" "$TMPDIR" "$RADARR_URL"; then
    echo "ERROR: the path fixer exited non-zero; nothing further was attempted." >&2
    exit 1
fi

# Cleanup handled by EXIT trap
