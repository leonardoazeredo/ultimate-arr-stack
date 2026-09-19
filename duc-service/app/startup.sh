#!/usr/bin/env bash

set -euo pipefail

# Overridable so tests/duc-service.bats can drive this against a throwaway tree.
# Nothing in the image sets any of them - the defaults are what the container
# runs, and each one is the value that was hardcoded here before.
LOG_FILE="${DUC_LOG_FILE:-/var/log/duc.log}"
CRON_FILE="${DUC_CRON_FILE:-/etc/cron.d/duc-index}"
CRON_BIN="${DUC_CRON_BIN:-cron}"
SCAN_SH="${DUC_SCAN_SH:-/scan.sh}"
MANUAL_SCAN_SH="${DUC_MANUAL_SCAN_SH:-/manual_scan.sh}"
# The fifth seam, and the one that makes the wait in start_webserver reachable
# at all: /var/run/fcgiwrap.socket is root-owned on both hosts the suite runs on,
# so a test that drives that loop has to point it at a path it can bind a socket
# in. The default is the path the image uses.
FCGI_SOCKET="${DUC_FCGI_SOCKET:-/var/run/fcgiwrap.socket}"
# The index this reads to decide whether a start-up scan is worth running, and
# how old it may be before one is. Same convention as the seams above: the
# image sets neither, so the container uses these defaults.
#
# 20 hours, not 24: the daily cron is `0 4 * * *`, so an index is at most 24
# hours old and normally much younger. 20 leaves room for a cron run that
# started late without letting a genuinely stale index through.
INDEX_DB="${DUC_INDEX_DB:-/database/duc.db}"
STARTUP_SCAN_MAX_AGE_HOURS="${DUC_STARTUP_SCAN_MAX_AGE_HOURS:-20}"
FALLBACK_SCHEDULE="0 0 * * *"

# A cron schedule is exactly five whitespace-separated fields on exactly one
# line.
#
# This used to be `echo "$SCHEDULE" | awk 'NF==5'`, which is a PRINT FILTER and
# not a test: awk with a pattern and no action prints the matching lines and
# exits 0 whatever it matched. The negation could therefore never be true and
# the fallback below was unreachable code - any value at all, including an empty
# one, went straight into /etc/cron.d, where cron ignores a malformed line
# without comment and the daily scan simply never runs.
#
# NR==1 matters as much as NF==5: /etc/cron.d entries are newline-delimited, so
# a multi-line SCHEDULE whose first line happens to carry five fields would
# otherwise append arbitrary extra crontab lines, running as root.
valid_schedule() {
    printf '%s' "${1-}" | awk 'NF == 5 { ok = 1 } END { exit !(ok && NR == 1) }'
}

write_cron_file() {
    local schedule="$1" dest="$2"
    {
        echo "# Auto-generated Duc cron tasks"
        echo "# Manual scan request poller"
        echo "* * * * * root $MANUAL_SCAN_SH"
        echo "# Scheduled full scan"
        echo "$schedule root $SCAN_SH"
    } > "$dest"
    chmod 0644 "$dest"
}

# A seam. Everything in here is process-level setup that a test has no business
# performing - and tests/duc-service.bats overrides it so main() can be driven
# end to end without fcgiwrap or nginx being installed. The socket path it waits
# on is a seam of its own (DUC_FCGI_SOCKET) so that the wait loop itself can be
# driven directly, since no test that overrides this function ever reaches it.
start_webserver() {
    echo "Launching webserver"
    rm -f "$FCGI_SOCKET"
    nohup fcgiwrap -s unix:"$FCGI_SOCKET" &
    while ! [ -S "$FCGI_SOCKET" ]; do sleep .2; done
    chmod 777 "$FCGI_SOCKET"
    test -f nohup.out && rm -f ./nohup.out

    nginx
}

# Is a start-up scan worth running?
#
# The start-up scan exists for a first run with no index at all. It used to run
# on every container start, which made `restart: always` a loaded gun: on
# 2026-09-18 duc restarted at 23:07 while the NAS was already I/O-starved and
# immediately walked 2.9 Tb / 842.4K files / 139.8K directories again, adding to
# the stall it was suffering from. A fresh index is a warm start.
#
# Returns 0 when a scan is needed, 1 when the index is fresh enough to skip.
# Fails towards scanning: an index that is missing, unreadable, or whose age
# cannot be determined gets a scan, which is the behaviour that shipped before
# this function existed.
startup_scan_needed() {
    local age_minutes
    [[ -f "$INDEX_DB" ]] || return 0
    age_minutes=$(( STARTUP_SCAN_MAX_AGE_HOURS * 60 ))
    [[ -z "$(find "$INDEX_DB" -mmin -"$age_minutes" 2>/dev/null)" ]]
}

main() {
    touch "$LOG_FILE"

    if startup_scan_needed; then
        echo "Starting initial recursive scan"
        echo "This may take a while..."
        echo "Now: $(date)"
        "$SCAN_SH" || echo "Initial scan failed (exit $?)" | tee -a "$LOG_FILE"
        echo "Now: $(date)"
        echo "Scan complete"
    else
        echo "Index is newer than ${STARTUP_SCAN_MAX_AGE_HOURS}h; skipping the initial scan"
    fi

    local schedule="${SCHEDULE:-}"
    if ! valid_schedule "$schedule"; then
        echo "Invalid SCHEDULE '$schedule' - falling back to '$FALLBACK_SCHEDULE'" | tee -a "$LOG_FILE"
        schedule="$FALLBACK_SCHEDULE"
    fi

    echo "Creating cron schedule: $schedule"
    write_cron_file "$schedule" "$CRON_FILE"
    "$CRON_BIN"

    start_webserver
}

# Sourced by tests/duc-service.bats, executed by the image's CMD.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
