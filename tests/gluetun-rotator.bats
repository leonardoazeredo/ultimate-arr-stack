#!/usr/bin/env bats
# scripts/gluetun-rotator.sh -- the poll loop that cycles gluetun on a schedule,
# and the shared file that keeps it out of the indexer guard's way.
#
# The script is sourced (ROTATOR_SOURCE_ONLY=1), never run: running it walks
# into the loop and sleeps for a real interval. tests/helpers/stubs.bash sits in
# front of PATH because the one thing this file must never do is reach a live
# `docker restart`; the harness refuses that verb outright. The failed-restart
# test uses the refusal. The successful-restart tests override `docker` with a
# shell function that logs the same line the stub would, and leave the PATH stub
# installed behind it, so anything that escapes the override trips the denylist
# instead of reaching a daemon.
#
# Time is an argument to rotator_poll, so every interval boundary here is exact
# rather than a race with the clock.
#
# shellcheck is deliberately not re-run here: tests/shellcheck.bats already
# checks every tracked shell script, and no per-script bats file in this repo
# carries its own copy.

# `run --separate-stderr` is a 1.5.0 feature, and the two tests that read the
# streams apart need it: `run` on its own merges them, which is what would let
# the `>&2` on a failure line be deleted without a test going red.
bats_require_minimum_version 1.5.0

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init

    SCRIPT="$REPO_ROOT/scripts/gluetun-rotator.sh"
    INTERVAL=21600
    NOW=1700000000
    SHARED_DIR="$BATS_TEST_TMPDIR/vpn-rotation"
    SHARED_FILE="$SHARED_DIR/last-rotation"

    export SCRIPT NOW ROTATOR_SOURCE_ONLY=1
    export ROTATOR_SHARED_FILE="$SHARED_FILE"
    # A usable interval for the tests that are about the poll rather than about
    # the validation; the validation tests override these themselves, and the
    # environment must not decide what they see.
    export GLUETUN_ROTATE_INTERVAL_SECONDS="$INTERVAL"
    export GLUETUN_ROTATE_CHECK_SECONDS=60

    # A stub that answers nothing. It is here for its denylist: `restart` trips
    # it, which is how the failed-restart path is reachable at all.
    stub_docker ''
}

teardown() {
    # Two tests make the shared directory unwritable; put it back so bats can
    # remove its own tmpdir.
    [ -d "$SHARED_DIR" ] && chmod 700 "$SHARED_DIR" 2>/dev/null
    return 0
}

# one_poll <now>: exactly one rotator_poll, in its own shell, at a fixed clock.
# The script's globals -- `remembered` with them -- live only for that call, so
# a test that needs two polls in a row runs them in one subshell itself.
# resolve_config runs first because main runs it before the loop: without it
# $INTERVAL is unset and the poll never reaches its restart branch.
one_poll() {
    run bash -c '. "$SCRIPT"; resolve_config; rotator_poll "$1"' bash "$1"
}

# --- the script itself -------------------------------------------------------

@test "gluetun-rotator: the script is executable and runs under /bin/sh" {
    [ -x "$SCRIPT" ]
    run head -1 "$SCRIPT"
    assert_output "#!/bin/sh"
}

@test "gluetun-rotator: the shared path defaults to the mounted location" {
    # The compose service mounts ./logs/vpn-rotation at /vpn-rotation, and the
    # indexer guard writes the same path on the host. A default that drifted
    # would leave both actors coordinating through two different files and
    # neither would say so.
    run bash -c 'unset ROTATOR_SHARED_FILE; . "$SCRIPT"; printf "%s\n" "$SHARED_FILE"'
    assert_success
    assert_output "/vpn-rotation/last-rotation"
}

@test "gluetun-rotator: sourcing for tests does not start the loop" {
    # Completing is the assertion: without the ROTATOR_SOURCE_ONLY guard this
    # sources into main and sleeps for a real interval.
    run bash -c '. "$SCRIPT"; command -v rotator_poll >/dev/null || exit 1; printf "sourced-ok\n"'
    assert_success
    assert_output "sourced-ok"
}

@test "gluetun-rotator: the compose service mounts the script read-only and runs it" {
    # Static text rather than `docker compose config`: that check skips without
    # the CLI (tests/compose-validation.bats), and this has to hold on every
    # host the suite runs on.
    local block
    block="$(awk '
        /^  gluetun-rotator:/ { found = 1; next }
        found && /^  [a-zA-Z#]/ { found = 0 }
        found
    ' "$REPO_ROOT/docker-compose.utilities.yml")"
    [ -n "$block" ] || fail "found no gluetun-rotator service block in docker-compose.utilities.yml"

    printf '%s\n' "$block" | grep -qxF '      - ./scripts/gluetun-rotator.sh:/gluetun-rotator.sh:ro' \
        || fail "the compose service does not mount scripts/gluetun-rotator.sh read-only"
    printf '%s\n' "$block" | grep -qxF '      - /bin/sh' \
        || fail "the compose entrypoint does not exec /bin/sh"
    printf '%s\n' "$block" | grep -qxF '      - /gluetun-rotator.sh' \
        || fail "the compose entrypoint does not run the mounted script"
    printf '%s\n' "$block" | grep -qxF '      - ./logs/vpn-rotation:/vpn-rotation' \
        || fail "the compose service no longer mounts the shared rotation directory"
}

# --- validation --------------------------------------------------------------

@test "gluetun-rotator: 0, 00, empty and non-numeric intervals all fall back to 21600" {
    # Zero is the value that must never take effect quietly: it reconnects the
    # tunnel on every poll. `00` is the same number spelled differently, which
    # an exact `case ... |0` would let through.
    local value
    for value in 0 00 000 '' abc '-1' '1.5' ' 300'; do
        export GLUETUN_ROTATE_INTERVAL_SECONDS="$value"
        run bash -c '. "$SCRIPT"; resolve_config; printf "%s\n" "$INTERVAL"'
        assert_success
        assert_output --partial "using 21600"
        assert_line "21600"
    done
}

@test "gluetun-rotator: a check interval of 0 falls back to 300" {
    export GLUETUN_ROTATE_CHECK_SECONDS=0
    run bash -c '. "$SCRIPT"; resolve_config; printf "%s %s\n" "$INTERVAL" "$CHECK"'
    assert_success
    assert_output --partial "GLUETUN_ROTATE_CHECK_SECONDS=0 is not above zero; using 300"
    assert_line "21600 300"
}

@test "gluetun-rotator: a usable interval is kept without a fallback line" {
    export GLUETUN_ROTATE_INTERVAL_SECONDS=10800
    export GLUETUN_ROTATE_CHECK_SECONDS=60
    run bash -c '. "$SCRIPT"; resolve_config; printf "%s %s\n" "$INTERVAL" "$CHECK"'
    assert_success
    assert_output "10800 60"
}

# default_agrees <label> <source-a> <value-a> <source-b> <value-b>: one default
# as two files spell it, compared as text. Both extractions have to yield
# something: a sed that stops matching after a refactor would otherwise leave
# two empty strings, which compare equal and read as agreement.
default_agrees() {
    local label="$1" source_a="$2" value_a="$3" source_b="$4" value_b="$5"
    [ -n "$value_a" ] || fail "could not extract $label from $source_a"
    [ -n "$value_b" ] || fail "could not extract $label from $source_b"
    [ "$value_a" = "$value_b" ] \
        || fail "$label disagrees: $value_a in $source_a but $value_b in $source_b"
}

@test "gluetun-rotator: the interval and check defaults agree across the files that carry them" {
    # Four files carry these two numbers -- this script's own fallbacks, the
    # module's rotator interval, the compose environment defaults the container
    # actually starts with, and .env.example -- and nothing else compares them.
    # A drift is invisible in any file read alone: the module would hold for a
    # schedule the rotator does not keep, or compose would start the loop on an
    # interval the script's own fallback disagrees with.
    local compose="$REPO_ROOT/docker-compose.utilities.yml"
    local env_example="$REPO_ROOT/.env.example"
    local module="$REPO_ROOT/scripts/lib/indexer_guard.py"

    local sh_interval sh_check py_interval compose_interval compose_check env_interval env_check
    sh_interval="$(sed -n 's/^INTERVAL_DEFAULT=\([0-9][0-9]*\)$/\1/p' "$SCRIPT")"
    sh_check="$(sed -n 's/^CHECK_DEFAULT=\([0-9][0-9]*\)$/\1/p' "$SCRIPT")"
    py_interval="$(sed -n 's/^DEFAULT_ROTATOR_INTERVAL_SECONDS = \([0-9][0-9]*\)$/\1/p' "$module")"
    compose_interval="$(sed -n 's/^      - GLUETUN_ROTATE_INTERVAL_SECONDS=\${GLUETUN_ROTATE_INTERVAL_SECONDS:-\([0-9][0-9]*\)}$/\1/p' "$compose")"
    compose_check="$(sed -n 's/^      - GLUETUN_ROTATE_CHECK_SECONDS=\${GLUETUN_ROTATE_CHECK_SECONDS:-\([0-9][0-9]*\)}$/\1/p' "$compose")"
    env_interval="$(sed -n 's/^GLUETUN_ROTATE_INTERVAL_SECONDS=\([0-9][0-9]*\)$/\1/p' "$env_example")"
    env_check="$(sed -n 's/^GLUETUN_ROTATE_CHECK_SECONDS=\([0-9][0-9]*\)$/\1/p' "$env_example")"

    default_agrees INTERVAL_DEFAULT scripts/gluetun-rotator.sh "$sh_interval" \
        scripts/lib/indexer_guard.py "$py_interval"
    default_agrees INTERVAL_DEFAULT scripts/gluetun-rotator.sh "$sh_interval" \
        docker-compose.utilities.yml "$compose_interval"
    default_agrees INTERVAL_DEFAULT scripts/gluetun-rotator.sh "$sh_interval" \
        .env.example "$env_interval"
    default_agrees CHECK_DEFAULT scripts/gluetun-rotator.sh "$sh_check" \
        docker-compose.utilities.yml "$compose_check"
    default_agrees CHECK_DEFAULT scripts/gluetun-rotator.sh "$sh_check" \
        .env.example "$env_check"
}

# --- the poll ----------------------------------------------------------------

@test "gluetun-rotator: a missing shared file starts the interval instead of restarting" {
    # The first poll of a fresh stack. Restarting here would be a restart on
    # every boot; the file written now is what the next poll measures against.
    mkdir -p "$SHARED_DIR"
    one_poll "$NOW"
    assert_success
    assert_output --partial "no usable timestamp"
    assert_stub_not_called docker ""
    assert_nothing_forbidden

    run cat "$SHARED_FILE"
    assert_output "$NOW"
    run ls -A "$SHARED_DIR"
    assert_output "last-rotation"
}

@test "gluetun-rotator: inside the interval no docker call is made" {
    mkdir -p "$SHARED_DIR"
    printf '%s\n' "$((NOW - 60))" > "$SHARED_FILE"
    one_poll "$NOW"
    assert_success
    refute_output --partial "restarting gluetun"
    assert_stub_not_called docker ""
    assert_nothing_forbidden

    run cat "$SHARED_FILE"
    assert_output "$((NOW - 60))"
}

@test "gluetun-rotator: a non-numeric shared file is treated as missing" {
    # A half-written or hand-edited file is not a rotation. Reading it as one
    # would either rotate immediately or park the interval in the far future.
    mkdir -p "$SHARED_DIR"
    printf 'not-a-number\n' > "$SHARED_FILE"
    one_poll "$NOW"
    assert_success
    assert_output --partial "no usable timestamp"
    assert_stub_not_called docker ""
    assert_nothing_forbidden

    run cat "$SHARED_FILE"
    assert_output "$NOW"
    run ls -A "$SHARED_DIR"
    assert_output "last-rotation"
}

@test "gluetun-rotator: elapsed interval restarts gluetun and records the moment" {
    # The boundary is exact: elapsed == interval. The restart succeeds through
    # the override, and the file must now hold the moment of the restart so the
    # next interval measures from it.
    mkdir -p "$SHARED_DIR"
    printf '%s\n' "$((NOW - INTERVAL))" > "$SHARED_FILE"
    run bash -c '
        . "$SCRIPT"
        resolve_config
        docker() { printf "docker\t%s\n" "$*" >> "$STUB_LOG"; return 0; }
        rotator_poll "$1"
    ' bash "$NOW"
    assert_success
    assert_output --partial "restarting gluetun"
    assert_stub_called docker "restart gluetun"
    assert_nothing_forbidden

    run cat "$SHARED_FILE"
    assert_output "$NOW"
    # Atomic means no temporary left beside it: a reader that finds one has
    # found this script's leftovers, not a timestamp.
    run ls -A "$SHARED_DIR"
    assert_output "last-rotation"
}

@test "gluetun-rotator: a failed restart is reported on stderr and records nothing" {
    # The stub harness refuses `restart` and exits non-zero, which is the
    # failed restart. Nothing may be written: recording it would hide the
    # failure for a whole interval instead of letting the next poll retry.
    mkdir -p "$SHARED_DIR"
    printf '%s\n' "$((NOW - INTERVAL))" > "$SHARED_FILE"
    run --separate-stderr bash -c '. "$SCRIPT"; resolve_config; rotator_poll "$1"' bash "$NOW"
    assert_success
    assert_forbidden "restart"
    [[ "$stderr" == *"FAILED to restart gluetun"* ]]
    [[ "$output" != *"FAILED to restart gluetun"* ]]

    run cat "$SHARED_FILE"
    assert_output "$((NOW - INTERVAL))"
    run ls -A "$SHARED_DIR"
    assert_output "last-rotation"
}

# --- an unwritable shared directory ------------------------------------------

@test "gluetun-rotator: an unwritable shared directory is named at startup, on stderr" {
    # The failure this loop cannot otherwise see: the bind mount is owned by
    # root, so every write fails and the indexer guard never learns of a
    # rotation. It is a warning rather than an exit -- the loop still has an
    # interval to keep.
    [ "$(id -u)" -ne 0 ] || skip "root writes to a 0500 directory regardless"
    mkdir -p "$SHARED_DIR"
    chmod 500 "$SHARED_DIR"

    run --separate-stderr bash -c '. "$SCRIPT"; check_shared_dir'
    assert_failure
    [[ "$stderr" == *"$SHARED_DIR"* ]]
    [[ "$stderr" == *"NOT WRITABLE"* ]]
    [[ "$stderr" == *"indexer-guard.sh cannot see rotations"* ]]
    [[ "$stderr" == *"in memory only"* ]]
    [[ "$output" != *"NOT WRITABLE"* ]]

    # The probe file is cleaned up whether or not the probe could be written.
    run ls -A "$SHARED_DIR"
    assert_output ""
}

@test "gluetun-rotator: after a restart it could not record, the next poll holds the remembered moment" {
    # Two polls in one shell, because `remembered` is the state under test. The
    # first restarts and fails to write; the second reads the same stale file
    # and must not restart again on the strength of it.
    [ "$(id -u)" -ne 0 ] || skip "root writes to a 0500 directory regardless"
    mkdir -p "$SHARED_DIR"
    local stale=$((NOW - INTERVAL - 10))
    printf '%s\n' "$stale" > "$SHARED_FILE"
    chmod 500 "$SHARED_DIR"

    run bash -c '
        . "$SCRIPT"
        resolve_config
        docker() { printf "docker\t%s\n" "$*" >> "$STUB_LOG"; return 0; }
        rotator_poll "$1"
        rotator_poll "$2"
        printf "remembered=%s\n" "$remembered"
    ' bash "$NOW" "$((NOW + 60))"
    assert_success
    assert_output --partial "FAILED to write"
    assert_output --partial "remembered=$NOW"
    [ "$(grep -c '^docker' "$STUB_LOG")" -eq 1 ]
    assert_nothing_forbidden

    run cat "$SHARED_FILE"
    assert_output "$stale"
    run ls -A "$SHARED_DIR"
    assert_output "last-rotation"
}
