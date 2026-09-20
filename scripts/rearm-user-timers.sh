#!/bin/bash
set -euo pipefail
#
# Re-arm the arr-stack user timers after a boot that missed them.
#
# Usage:
#   ./scripts/rearm-user-timers.sh
#   REARM_TIMEOUT_SECONDS=120 ./scripts/rearm-user-timers.sh
#
# Exit status:
#   0  every *.timer in the unit directory is active afterwards
#   1  the unit directory never appeared within REARM_TIMEOUT_SECONDS, or a
#      timer is still inactive. Never 0 for either: a remedy that cannot tell
#      "armed" from "still dead" is the failure this exists to remove.
#
# WHY THE TWO STEPS, IN THIS ORDER
#
# The user manager starts before the volumes are usable. Measured on
# 2026-09-19: user@1000.service became active at 00:05:06 while home.mount
# became active at 00:05:36, so the manager read ~/.config/systemd/user/ before
# /home existed, loaded nothing, and activated timers.target empty. All eight
# timers stayed inactive for eleven hours while `systemctl --user is-enabled`
# reported every one of them as enabled and the symlinks in
# timers.target.wants/ were all intact -- the disk state was never wrong.
#
# Reproduced on the 2026-09-20 boot: user@1000.service active 19:07:38,
# home.mount active 19:08:06, and the unit files were not loaded by the manager
# at all until someone started a timer by hand at 19:22.
#
#   daemon-reload   makes the unit files visible to the running manager.
#   start timers.target   actually arms them. Reloading unit files does not
#                   start anything, and this is the step that is easy to omit:
#                   after a reload `list-timers --all` prints all eight, which
#                   reads like success, while every NEXT column says "-".
#
# UGOS mounts the volumes outside systemd's view, so ordering on home.mount is
# not the answer -- the repo's own boot-compose-up.service polls for the file
# for the same reason. This does too. A drop-in adding
# `RequiresMountsFor=/home/leoleg` to user@1000.service was tried on
# 2026-09-20 and did nothing: home.mount has an empty FragmentPath, so it does
# not exist as a unit until UGOS has already performed the mount, and the
# directive therefore has nothing to order against when the manager loads.

UNIT_DIR="${REARM_UNIT_DIR:-$HOME/.config/systemd/user}"
SYSTEMCTL="${REARM_SYSTEMCTL:-systemctl}"
TIMEOUT_SECONDS="${REARM_TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${REARM_POLL_SECONDS:-5}"

# Wait for the unit files to exist at all. A boot where /home never mounts
# leaves this directory absent, and that must not read as "nothing to do".
waited=0
while ! compgen -G "$UNIT_DIR/*.timer" >/dev/null 2>&1; do
    if [[ "$waited" -ge "$TIMEOUT_SECONDS" ]]; then
        echo "ERROR: $UNIT_DIR never appeared after ${TIMEOUT_SECONDS}s; the user timers cannot be armed" >&2
        exit 1
    fi
    sleep "$POLL_SECONDS"
    waited=$(( waited + POLL_SECONDS ))
done

echo "unit directory ready after ${waited}s: $UNIT_DIR"

"$SYSTEMCTL" --user daemon-reload
"$SYSTEMCTL" --user start timers.target

inactive=()
for unit in "$UNIT_DIR"/*.timer; do
    name="$(basename "$unit")"
    if ! "$SYSTEMCTL" --user is-active --quiet "$name"; then
        inactive+=("$name")
    fi
done

if [[ ${#inactive[@]} -gt 0 ]]; then
    echo "ERROR: ${#inactive[@]} timer(s) are still inactive after the reload and start:" >&2
    printf '  %s\n' "${inactive[@]}" >&2
    echo "Loaded is not armed. Check: $SYSTEMCTL --user list-timers --all" >&2
    exit 1
fi

echo "all timers active"
