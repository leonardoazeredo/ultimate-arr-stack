#!/usr/bin/env bash

set -euo pipefail

LOG_FILE="${DUC_LOG_FILE:-/var/log/duc.log}"
LOCK_DIR="${DUC_LOCK_DIR:-/tmp/scan.lock}"
REQUEST_DIR="${DUC_REQUEST_DIR:-/tmp/scan_requested}"

echo "Content-type: text/plain"; echo
if [ -d "$LOCK_DIR" ]; then
    echo "A scan is already in progress:"; echo
    # Never let a missing log turn a status page into a 500: `set -e` plus a
    # bare `cat` would abort the script AFTER the headers had already gone out.
    cat "$LOG_FILE" 2>/dev/null || echo "(no log yet)"
elif [ -d "$REQUEST_DIR" ]; then
    echo "A manual scan has already been requested and will start within one minute"
else
    mkdir -p "$REQUEST_DIR"
    echo "A scan will be started within one minute"
fi
