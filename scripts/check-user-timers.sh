#!/bin/bash
set -euo pipefail
#
# Report whether the arr-stack user timers are actually running, by checking
# the freshness of what they produce.
#
# Usage:
#   ./scripts/check-user-timers.sh
#   TIMER_FRESH_MINUTES=60 ./scripts/check-user-timers.sh
#
# Exit status:
#   0  the freshest artifact is within the window -- the timers are running
#   1  it is stale, or there is no artifact at all
#
# WHY NOT ASK SYSTEMD
#
# `systemctl --user list-timers` answers this directly, and needs the session
# D-Bus, which nothing that runs unattended on this box can reach: every
# always-on process here is a container, and the user manager is only reachable
# from a login session. The timers write files, though, and a stale file is
# observable from anywhere -- including from a container that has /volume1
# mounted.
#
# usenet-status-render.timer rewrites its page every two minutes, so it is the
# fastest-moving artifact and the one worth watching. 15 minutes is seven of
# its cycles: long enough that a slow box is not a false alarm, short enough
# that a reboot is noticed the same morning.
#
# THE ONE CAVEAT THIS CHECK CANNOT SEE
#
# A stale artifact means the timers are not running. A FRESH artifact does not
# prove all of them are: this reads the fastest-moving one. On 2026-09-20 the
# eight timers were all inactive after a reboot while this file's artifact was
# already hours stale, which is the case it is built for.

STACK_DIR="${STACK_DIR:-/volume1/docker/arr-stack}"
FRESH_MINUTES="${TIMER_FRESH_MINUTES:-15}"
ARTIFACT="$STACK_DIR/logs/usenet-status/index.html"

if [[ ! -e "$ARTIFACT" ]]; then
    echo "FAIL: no artifact at $ARTIFACT, so the user timers have never run (or the stack has never rendered a status page)" >&2
    echo "      Remediation: /volume1/docker/arr-stack/scripts/rearm-user-timers.sh" >&2
    exit 1
fi

if [[ -n "$(find "$ARTIFACT" -mmin -"$FRESH_MINUTES" 2>/dev/null)" ]]; then
    echo "OK: timers are running (last render within ${FRESH_MINUTES}m)"
    exit 0
fi

echo "FAIL: the user timers are not running -- $ARTIFACT has not been rewritten in ${FRESH_MINUTES}m." >&2
echo "      This is the state every reboot produced before the /home race was understood: the unit files are on disk, is-enabled says enabled, and the manager never loaded them." >&2
echo "      Remediation: /volume1/docker/arr-stack/scripts/rearm-user-timers.sh" >&2
exit 1
