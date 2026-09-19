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
# The index this reads to decide whether a start-up scan is worth running, how
# old it may be before one is, and the same host I/O pressure reading
# scripts/usenet-blackhole.sh refuses to start a pass on. Same convention as the
# seams above: the image sets none of them.
#
# 20 hours, not 24, and not because of a late cron run -- a scan stamps the
# mtime when it FINISHES, so starting late shortens the age rather than
# lengthening it. The window has to be shorter than the cron period or the
# start-up scan is dead code: with `0 4 * * *` and a 24-hour window a running
# stack's index never expires, so the one case this branch exists for besides a
# first run -- a container whose own cron has stopped -- could never be caught.
# The price of that is a band from the moment the index crosses 20h old to the
# moment the 04:00 scan finishes, roughly four hours a day, in which a
# `restart: always` restart re-walks the volume. That band is the residual
# exposure, and it is what the pressure reading below bounds.
INDEX_DB="${DUC_INDEX_DB:-/database/duc.db}"
STARTUP_SCAN_MAX_AGE_HOURS="${DUC_STARTUP_SCAN_MAX_AGE_HOURS:-20}"
# `full` rather than `some`, and 20% rather than anything tuned: `some` counts a
# single stalled task and runs high on a merely busy box, while `full` means
# every runnable task was stalled on I/O at once. Measured on this NAS, 1.86%
# healthy and 78-81% for hours during the incident of 2026-09-18.
#
# Read inline rather than sourced from scripts/lib/. duc-service/Dockerfile
# copies app/ and nothing else, so there is no library in this image to share
# with; two consumers reading one kernel interface is the whole overlap, and it
# is the same parse scripts/usenet-blackhole.sh makes before it will start a
# pass.
PSI_IO_PATH="${DUC_PSI_IO_PATH:-/proc/pressure/io}"
PSI_IO_LIMIT="${DUC_PSI_IO_LIMIT:-20}"
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

# io full avg10 from /proc/pressure/io, or nothing when PSI is unavailable.
#
# The same reading scripts/usenet-blackhole.sh takes before it will start a
# pass, and deliberately the same shape: `full` rather than `some`, because
# `some` counts a single stalled task and would veto a scan on any busy box.
psi_io_full_avg10() {
    [[ -r "$PSI_IO_PATH" ]] || return 1
    awk '$1 == "full" {
           for (i = 2; i <= NF; i++) {
             split($i, kv, "=")
             if (kv[1] == "avg10") { print kv[2]; exit }
           }
         }' "$PSI_IO_PATH"
}

# Is the host too I/O-stalled to walk 2.9 Tb right now?
#
# Returns 0 when it is, 1 when it is not -- or when this cannot tell, which is
# the point. It fails OPEN and says so out loud: a kernel built without PSI, a
# container that cannot read /proc/pressure, and a reading or a limit that is
# not a number all leave the decision to the index age alone, and each is
# announced. A guard that cannot read its own input must not be the thing that
# leaves a host with no index and no way to build one -- and "the guard ran and
# found nothing" and "the guard could not run" must not be the same observable
# result.
#
# The numeric checks are the `case` idiom scripts/usenet-blackhole.sh uses for
# the same two values. They matter in both directions: awk compares a
# non-numeric operand as a string, so a garbage LIMIT is false against every
# reading (the guard silently never trips) while a garbage READING is true
# against a numeric limit (the guard trips on nothing and skips the scan).
host_io_stalled() {
    local reading
    reading="$(psi_io_full_avg10 || true)"
    if [[ -z "$reading" ]]; then
        echo "I/O pressure: nothing readable at ${PSI_IO_PATH}; deciding on index age alone"
    elif [[ "$reading" == *[!0-9.]* || "$reading" == *.*.* ]]; then
        echo "I/O pressure: the reading '${reading}' is not a number; deciding on index age alone"
        reading=""
    elif [[ "$PSI_IO_LIMIT" == *[!0-9.]* || "$PSI_IO_LIMIT" == *.*.* ]]; then
        echo "I/O pressure: the limit '${PSI_IO_LIMIT}' is not a number; deciding on index age alone"
        reading=""
    fi
    [[ -n "$reading" ]] || return 1
    awk -v seen="$reading" -v limit="$PSI_IO_LIMIT" \
        'BEGIN { exit !(seen >= limit) }'
}

# Is a start-up scan worth running?
#
# The start-up scan exists for a first run with no index at all. It used to run
# on every container start, which made `restart: always` a loaded gun: on
# 2026-09-18 duc restarted at 23:07 while the NAS was already I/O-starved and
# immediately walked 2.9 Tb / 842.4K files / 139.8K directories again, adding to
# the stall it was suffering from. A fresh index is a warm start.
#
# The host gets a veto before the calendar does, and that veto is the whole
# reason this function knows about PSI at all. Age alone is not enough: the
# daily cron writes the index at ~04:07, so from ~00:07 to 04:00 the index is
# older than the window and a `restart: always` restart in that band re-walks
# the volume -- while scripts/usenet-blackhole.sh is skipping the ingest pass
# for the very same reason. Two guards reading one stalled host and disagreeing
# about it is the loop in docs/NAS-LOAD-INCIDENT-2026-09-18.md, one restart away
# from turning again.
#
# Returns 0 when a scan is needed, 1 when it is skipped. Fails towards scanning
# on everything except a host that reads as stalled: an index that is missing,
# unreadable, or whose age cannot be determined gets a scan, which is the
# behaviour that shipped before this function existed.
startup_scan_needed() {
    local age_minutes
    if host_io_stalled; then
        echo "Host I/O is stalled; skipping the start-up scan"
        return 1
    fi
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
