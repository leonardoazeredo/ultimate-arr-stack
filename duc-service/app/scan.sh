#!/usr/bin/env bash

set -euo pipefail

# Every path is overridable so tests/duc-service.bats can drive this against a
# throwaway tree. Nothing in the image sets any of them: the defaults are what
# the container runs, and they are the values that were hardcoded here before.
LOG_FILE="${DUC_LOG_FILE:-/var/log/duc.log}"
LOCK_DIR="${DUC_LOCK_DIR:-/tmp/scan.lock}"
DUC_BIN="${DUC_BIN:-/usr/local/bin/duc}"
SCAN_ROOT="${DUC_SCAN_ROOT:-/scan}"

# Reserved: a scan did not run because another one holds the lock. Distinct from
# 0 so the caller can tell "nothing to do, already running" from "done", and
# distinct from every duc exit code so it can never be confused with a failure.
# /manual_scan.sh relies on this to avoid throwing away a queued request.
EX_ALREADY_RUNNING=75

# Acquire the lock atomically with mkdir (portable, no flock in this image).
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    exit "$EX_ALREADY_RUNNING"
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

{
    echo "Start of scan: $(date)"
    # `|| status=$?` and NOT a bare call. This group runs in a subshell of a
    # pipeline and inherits `set -e`, so a failing duc used to kill the subshell
    # on the spot: `status=$?` and the "End of scan" line below were both
    # unreachable on failure, and the log simply stopped mid-scan with no
    # indication that anything had gone wrong. The exit status still propagated
    # via PIPESTATUS, which is why this looked correct.
    status=0
    "$DUC_BIN" index --progress "$SCAN_ROOT" || status=$?
    echo "End of scan: $(date) (exit code: $status)"
    exit "$status"
} 2>&1 | tee -a "$LOG_FILE"

# The block's status, not tee's.
exit "${PIPESTATUS[0]}"
