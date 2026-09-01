#!/usr/bin/env bash

set -euo pipefail

LOG_FILE="${DUC_LOG_FILE:-/var/log/duc.log}"
REQUEST_DIR="${DUC_REQUEST_DIR:-/tmp/scan_requested}"
SCAN_SH="${DUC_SCAN_SH:-/scan.sh}"

EX_ALREADY_RUNNING=75

[ -d "$REQUEST_DIR" ] || exit 0

# The request is cleared by the OUTCOME, not on the way in. It used to be
# removed before /scan.sh was called, which silently lost the request whenever a
# scheduled scan happened to hold the lock at that moment: scan.sh exited 0
# without scanning, this poller had already deleted the marker, and the user's
# manual scan simply never happened. There is no error anywhere in that
# sequence, which is why it could sit unnoticed.
status=0
"$SCAN_SH" || status=$?

case "$status" in
    0)
        rm -rf "$REQUEST_DIR"
        ;;
    "$EX_ALREADY_RUNNING")
        # Keep the marker. This poller runs every minute, so the request is
        # picked up by the first tick after the running scan releases the lock.
        echo "Manual scan deferred: a scan is already running" >> "$LOG_FILE"
        ;;
    *)
        # A genuine failure clears the request: retrying a broken scan every
        # minute forever would fill the log and fix nothing.
        rm -rf "$REQUEST_DIR"
        echo "Manual scan failed (exit $status)" >> "$LOG_FILE"
        ;;
esac
