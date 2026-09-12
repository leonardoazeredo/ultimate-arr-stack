#!/usr/bin/env bats
# Static checks for the credential-drift systemd units. No `systemd-analyze`
# here - it's not available on this darwin dev machine and isn't guaranteed
# in CI; these are the checks that can run anywhere. Live verification
# (`systemd-analyze --user verify`) still happens against the real NAS
# before every install, per CLAUDE.md's deploy rule.

setup() {
    load helpers/setup
    UNITS_DIR="$REPO_ROOT/scripts"
}

# --- Regression for snag #19: the alert unit's journalctl call read the
# wrong journal scope once installed as a --user unit (queries the system
# journal by default; the detector's own logs live in the user journal
# under this install method). Every journalctl invocation in this file must
# carry --user. ---

@test "alert unit's journalctl calls all use --user" {
    run bash -c "grep -o 'journalctl[^;|]*' '$UNITS_DIR/detect-credential-drift-alert.service'"
    assert_success
    # Every matched journalctl invocation must include --user.
    while IFS= read -r invocation; do
        [[ "$invocation" == *"--user"* ]] || fail "journalctl call missing --user: $invocation"
    done <<< "$output"
}

# --- Regression for snag #17: a wrong "systemd timer install needs root"
# assumption was carried for most of a session before being re-tested and
# found false. These units are designed to install under
# ~/.config/systemd/user/ with no root/system-install assumptions baked in
# - assert none of the three creep back in. ---

@test "unit files carry no root/system-install assumptions" {
    local f
    for f in detect-credential-drift.service detect-credential-drift.timer detect-credential-drift-alert.service ensure-tailscale-relay-port.service ensure-tailscale-relay-port.timer queue-cleanup.service queue-cleanup.timer; do
        run grep -c '/etc/systemd' "$UNITS_DIR/$f"
        assert_output "0"

        run grep -c '^WantedBy=multi-user.target' "$UNITS_DIR/$f"
        assert_output "0"

        run grep -c '^User=' "$UNITS_DIR/$f"
        assert_output "0"
    done
}

@test "service and alert unit ExecStart paths point at the NAS deploy path, not a root-only location" {
    run grep 'ExecStart=' "$UNITS_DIR/detect-credential-drift.service"
    assert_output --partial "/volume1/docker/arr-stack/"
    refute_output --partial "/root/"
}

@test "ensure-tailscale-relay-port unit ExecStart path points at the NAS deploy path, not a root-only location" {
    run grep 'ExecStart=' "$UNITS_DIR/ensure-tailscale-relay-port.service"
    assert_output --partial "/volume1/docker/arr-stack/"
    refute_output --partial "/root/"
}

# --- queue-cleanup: the timer that was missing -----------------------------
#
# scripts/queue-cleanup.sh shipped with a "suggested cron: Thu 2am" line in its
# own header and nothing ever installed it. On 2026-09-12 the cost showed up:
# 67 items at 0% for a month, every individual piece of the pipeline working.
# These pin the unit that closes that gap, and the two directives without which
# it would be a scheduled no-op.

@test "queue-cleanup unit runs the script with --apply, not the dry run" {
    # Without --apply the timer runs the script's default mode forever: it
    # prints what it would remove, removes nothing, and exits 0. A scheduled
    # job that reports success and does nothing is the failure this whole unit
    # exists to fix, one layer up.
    run grep '^ExecStart=' "$UNITS_DIR/queue-cleanup.service"
    assert_output --partial "/volume1/docker/arr-stack/scripts/queue-cleanup.sh"
    assert_output --partial "--apply"
}

@test "queue-cleanup unit creates its log directory before redirecting into it" {
    # The redirect and the mkdir have to live in the same shell. Splitting them
    # -- ExecStartPre=mkdir plus StandardOutput=append: into that directory --
    # fails at boot with status=209/STDOUT, because systemd applies the unit's
    # StandardOutput to ExecStartPre too, so mkdir dies setting up the redirect
    # to a directory that does not exist yet. The first version of this unit
    # did exactly that and never started.
    run grep '^ExecStart=' "$UNITS_DIR/queue-cleanup.service"
    assert_output --partial "mkdir -p /volume1/docker/arr-stack/logs"
    assert_output --partial ">> /volume1/docker/arr-stack/logs/queue-cleanup.log 2>&1"

    # And nothing tries the split version again.
    run grep -c '^ExecStartPre=' "$UNITS_DIR/queue-cleanup.service"
    assert_output "0"

    run grep -c '^StandardOutput=' "$UNITS_DIR/queue-cleanup.service"
    assert_output "0"
}

@test "queue-cleanup timer is enabled by the install step and actually repeats" {
    # No [Install] means `systemctl --user enable` silently does nothing and
    # the timer never runs; no OnUnitActiveSec means it fires once per boot.
    run grep '^WantedBy=timers.target' "$UNITS_DIR/queue-cleanup.timer"
    assert_success

    run grep '^OnUnitActiveSec=' "$UNITS_DIR/queue-cleanup.timer"
    assert_success
}

@test "queue-cleanup timer fires faster than the shortest staleness threshold" {
    # The script removes an item that has made no progress for STALE_HOURS_*
    # (24h for a swarm client, 3h for a debrid one). A timer that fires less
    # often than that leaves a stuck item in place for the difference -- and
    # blocks every replacement search for it the whole time, which is the part
    # that actually hurt.
    #
    # Both numbers are read from where they live rather than restated here. The
    # first version of this test hardcoded 6h against a hardcoded 24, so it
    # would have kept passing on the day the thresholds stopped agreeing with
    # it, which is precisely when it needed to fail.
    local threshold
    threshold=$(grep -oE '^STALE_HOURS_[A-Z_]+ = [0-9]+' "$REPO_ROOT/scripts/lib/queue_cleanup.py" \
                | grep -oE '[0-9]+$' | sort -n | head -1)
    [ -n "$threshold" ] || fail "found no STALE_HOURS_* constants to compare against; this guard would pass by comparing nothing"

    local interval
    interval=$(grep '^OnUnitActiveSec=' "$UNITS_DIR/queue-cleanup.timer" | sed 's/^OnUnitActiveSec=//')
    case "$interval" in
        *h) ;;
        *) fail "expected an hour-based interval, got '$interval'" ;;
    esac

    local timer_hours="${interval%h}"
    [ "$timer_hours" -lt "$threshold" ] \
        || fail "timer fires every ${interval}, which is not faster than the shortest staleness threshold (${threshold}h)"
}
