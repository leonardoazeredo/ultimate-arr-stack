#!/usr/bin/env bats
# scripts/rearm-user-timers.sh -- re-arm the user timers after a boot that
# missed them.
#
# On the 2026-09-19 boot the user manager started at 00:05:06 and home.mount
# was not active until 00:05:36, so the manager never loaded
# ~/.config/systemd/user/ and timers.target came up active and empty. All eight
# timers were inactive for the next eleven hours while `is-enabled` reported
# every one of them as enabled.
#
# Reproduced on 2026-09-20: user@1000.service active 19:07:38, home.mount
# 19:08:06, and no unit file was loaded until a timer was started by hand.
#
# The trap this file exists to pin: daemon-reload makes them VISIBLE and starts
# nothing. A remedy that stops there prints eight lines of list-timers output
# and leaves every timer dead.

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init
    SCRIPT="$REPO_ROOT/scripts/rearm-user-timers.sh"
    WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK/units"
    export REARM_UNIT_DIR="$WORK/units"
    export REARM_POLL_SECONDS=1
    export REARM_TIMEOUT_SECONDS=3
    # Every systemctl call is recorded; ACTIVE_FILE decides what is-active says.
    export REARM_SYSTEMCTL=systemctl
    export ACTIVE_FILE="$WORK/active"
    export STUB_LOG="$WORK/stub.log"
    : > "$ACTIVE_FILE"
    # The stub appends here, so it has to exist even when the script makes no
    # systemctl call at all. Left to be created by the first call, the
    # "never appeared" test's `grep -c daemon-reload` fails with a missing-file
    # error instead of the 0 it is asserting -- a test that cannot pass for the
    # reason it was written.
    : > "$STUB_LOG"
    stub_tool systemctl '
        printf "%s\n" "$*" >> "$STUB_LOG"
        case "$1" in
            --user) shift ;;
        esac
        # The unit name is the LAST argument, not $2: the script asks
        # `is-active --quiet <name>`, so $2 is the flag. Taking $2 here would
        # test "--quiet" against ACTIVE_FILE and fail every timer.
        last=""
        for a in "$@"; do last="$a"; done
        case "$1" in
            daemon-reload) exit 0 ;;
            start) exit 0 ;;
            is-active)
                grep -qx "$last" "$ACTIVE_FILE" && exit 0 || exit 3 ;;
        esac
        exit 0
    '
    RUN="$SCRIPT"
}

mark_active() { printf '%s\n' "$1" >> "$ACTIVE_FILE"; }

@test "rearm: reloads before starting, and starts timers.target" {
    # The order is the fix. Reload first or the units are not loaded; start
    # second or they are loaded and still dead.
    : > "$WORK/units/queue-cleanup.timer"
    mark_active "queue-cleanup.timer"
    run env "PATH=$STUB_DIR:$PATH" "$RUN"
    assert_success
    run grep -n "daemon-reload" "$STUB_LOG"
    assert_success
    reload_line="${output%%:*}"
    run grep -n "start timers.target" "$STUB_LOG"
    assert_success
    start_line="${output%%:*}"
    [ "$reload_line" -lt "$start_line" ]
}

@test "rearm: fails when a timer is visible but not armed" {
    # Exactly the state a reload-only remedy leaves behind.
    : > "$WORK/units/queue-cleanup.timer"
    run env "PATH=$STUB_DIR:$PATH" "$RUN"
    assert_failure
    assert_output --partial "queue-cleanup.timer"
}

@test "rearm: fails when the unit directory never appears" {
    # A boot where /home never mounts must not read as success. An absent
    # oracle and a passing oracle must not be the same observable result.
    run env "PATH=$STUB_DIR:$PATH" "$RUN"
    assert_failure
    assert_output --partial "never appeared"
    run grep -c "daemon-reload" "$STUB_LOG"
    assert_output "0"
}

@test "rearm: every timer present is checked, not just the first" {
    : > "$WORK/units/queue-cleanup.timer"
    : > "$WORK/units/indexer-guard.timer"
    mark_active "queue-cleanup.timer"
    run env "PATH=$STUB_DIR:$PATH" "$RUN"
    assert_failure
    assert_output --partial "indexer-guard.timer"
}

@test "rearm: is idempotent, and succeeds when everything is armed" {
    : > "$WORK/units/queue-cleanup.timer"
    : > "$WORK/units/indexer-guard.timer"
    mark_active "queue-cleanup.timer"
    mark_active "indexer-guard.timer"
    run env "PATH=$STUB_DIR:$PATH" "$RUN"
    assert_success
    run env "PATH=$STUB_DIR:$PATH" "$RUN"
    assert_success
}
