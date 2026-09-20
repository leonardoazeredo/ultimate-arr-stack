#!/usr/bin/env bats
# scripts/arr-stack-user-timers.service -- the system unit that arms the eight
# user timers after a boot that missed them.
#
# This is the one unit in scripts/ that is NOT installed into
# ~/.config/systemd/user/. It runs as a system service, as leoleg, and calls
# scripts/rearm-user-timers.sh. tests/systemd-units.bats asserts the *user*
# units carry no root/system assumptions and names its files explicitly; this
# file is deliberately not among them, and this test is what pins the
# distinction so a later reader does not "fix" the omission.

setup() {
    load helpers/setup
    UNIT="$REPO_ROOT/scripts/arr-stack-user-timers.service"
}

@test "timer rearm unit is a system unit, not a --user one" {
    # If this ever loses WantedBy=multi-user.target it stops being a boot hook,
    # and if it is copied into ~/.config/systemd/user/ it becomes a user unit
    # that cannot start before the manager has loaded anything.
    run grep '^WantedBy=multi-user.target' "$UNIT"
    assert_success
}

@test "timer rearm unit runs the rearm script from the deploy path" {
    run grep '^ExecStart=' "$UNIT"
    assert_output --partial "/volume1/docker/arr-stack/scripts/rearm-user-timers.sh"
    refute_output --partial "/root/"
}

@test "timer rearm unit runs as leoleg with the user runtime dir set" {
    # `systemctl --user` needs both. Running as root would look in /root, find
    # no unit directory, and spend the whole timeout waiting for one.
    run grep '^User=leoleg' "$UNIT"
    assert_success

    run grep '^Environment=XDG_RUNTIME_DIR=/run/user/1000' "$UNIT"
    assert_success
}

@test "timer rearm unit's start timeout covers the script's own wait" {
    # The script polls for up to REARM_TIMEOUT_SECONDS (600). systemd's default
    # TimeoutStartSec is 90s, so without this the unit is killed mid-wait and a
    # slow mount reads as a failure. Both numbers are read from where they live
    # rather than restated: if the script's default wait grows past this
    # timeout, this test has to fail.
    local script_default
    script_default=$(grep -oE 'REARM_TIMEOUT_SECONDS:-[0-9]+' \
        "$REPO_ROOT/scripts/rearm-user-timers.sh" | grep -oE '[0-9]+$')
    [ -n "$script_default" ] || fail "could not read REARM_TIMEOUT_SECONDS from the script; this guard would compare nothing"

    local unit_timeout
    unit_timeout=$(grep -oE '^TimeoutStartSec=[0-9]+' "$UNIT" | grep -oE '[0-9]+$')
    [ -n "$unit_timeout" ] || fail "no TimeoutStartSec in the unit; it would fall back to the 90s default and kill the wait"

    [ "$unit_timeout" -ge "$script_default" ] \
        || fail "TimeoutStartSec=${unit_timeout} is shorter than the script's ${script_default}s wait; the unit would be killed mid-poll"
}

@test "timer rearm unit waits for the user manager, not for a mount unit" {
    # home.mount has an empty FragmentPath and does not exist until UGOS has
    # mounted /home, so ordering on it is a no-op (measured 2026-09-20).
    #
    # Asserted against the dependency directives, not the whole file: the
    # header explains at length why home.mount is not used, and a bare grep for
    # the string counts those comments and fails on its own explanation.
    run grep -E '^(After|Wants|Requires|RequiresMountsFor|BindsTo)=' "$UNIT"
    assert_success
    refute_output --partial "home.mount"

    run grep '^Wants=user@1000.service' "$UNIT"
    assert_success
}

@test "timer rearm unit waits for its own script before exec'ing it" {
    # /volume1 arrives after multi-user.target, exactly as /home does. Measured
    # on the 2026-09-20 20:42 boot: this unit started at 20:43:08 and
    # volume1.mount only became active at 20:43:37. A plain ExecStart pointing
    # at the script died with status=203/EXEC -- systemd cannot execute a path
    # that does not exist yet -- so the script's own poll for /home never ran
    # and all eight timers stayed dead. The first version of this unit shipped
    # exactly that bug.
    run grep '^ExecStart=' "$UNIT"
    assert_output --partial "/bin/bash"
    assert_output --partial "until [ -x /volume1/docker/arr-stack/scripts/rearm-user-timers.sh ]"
    # ...and then actually runs it, rather than waiting forever or exiting.
    assert_output --partial "exec /volume1/docker/arr-stack/scripts/rearm-user-timers.sh"
}
