#!/usr/bin/env bats
# scripts/check-user-timers.sh -- detect dead user timers from their artifacts.
#
# The 2026-09-19 boot left all eight timers inactive for eleven hours and
# nothing said so. Anything that could have noticed runs in a container, and a
# container cannot reach the session D-Bus; but the timers write files, and a
# stale file is observable from anywhere.

setup() {
    load helpers/setup
    SCRIPT="$REPO_ROOT/scripts/check-user-timers.sh"
    WORK="$BATS_TEST_TMPDIR/stack"
    mkdir -p "$WORK/logs/usenet-status"
    export STACK_DIR="$WORK"
    RUN="$SCRIPT"
}

touch_fresh() { : > "$WORK/logs/usenet-status/index.html"; }
touch_stale()  { : > "$WORK/logs/usenet-status/index.html"; touch -t 202001010000 "$WORK/logs/usenet-status/index.html"; }

@test "check-user-timers: a fresh artifact means the timers are alive" {
    touch_fresh
    run "$RUN"
    assert_success
    assert_output --partial "timers are running"
}

@test "check-user-timers: a stale artifact means they are dead" {
    touch_stale
    run "$RUN"
    assert_failure
    assert_output --partial "rearm-user-timers.sh"
}

@test "check-user-timers: no artifact at all is a failure, not a pass" {
    # An absent oracle and a passing oracle must not be the same observable
    # result -- the rule this repo has been bitten by more than once.
    run "$RUN"
    assert_failure
    assert_output --partial "no artifact"
}

@test "check-user-timers: the freshness window is configurable" {
    touch_stale
    run env TIMER_FRESH_MINUTES=99999999 "$RUN"
    assert_success
}
