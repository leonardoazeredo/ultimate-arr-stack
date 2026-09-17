#!/usr/bin/env bats
# scripts/stremio-library-sync.sh -- argument handling, the banner, and the two
# things about this script that are invisible until they are wrong.
#
# The decision logic lives in scripts/lib/stremio_library.py and is covered by
# tests/python/test_stremio_library.py. What is tested here is the shell half:
# the flags, the two key guards, and --
#
#   * that the credentials reach python3 through the environment rather than
#     argv, because /proc/<pid>/cmdline is world-readable and this runs on a
#     ten-minute timer;
#   * that --apply is passed only when it was asked for. `${APPLY:+--apply}`
#     reads as "add the flag when applying" and is not: `:+` tests for
#     non-empty, and APPLY=false is non-empty, so the flag goes on every
#     invocation and the banner says DRY RUN while the pass requests things.
#     usenet-blackhole.sh shipped exactly that bug; this is the test that says
#     so out loud.
#
# The real python is never run. A stub on PATH records how it was called, so
# nothing here touches the Stremio API or Seerr.

setup() {
    load helpers/setup
    SCRIPT="$REPO_ROOT/scripts/stremio-library-sync.sh"
    WORK="$BATS_TEST_TMPDIR/stack"
    mkdir -p "$WORK/scripts"
    cp "$SCRIPT" "$WORK/scripts/stremio-library-sync.sh"
    cp -r "$REPO_ROOT/scripts/lib" "$WORK/scripts/lib"
    chmod +x "$WORK/scripts/stremio-library-sync.sh"
    ENV="$WORK/.env"
    printf 'SEERR_API_KEY=seerr-key\nSTREMIO_AUTH_KEY=stremio-key\n' > "$ENV"
    RUN="$WORK/scripts/stremio-library-sync.sh"
    STATE="$WORK/logs/stremio-library-sync-state.json"
    ARGV_FILE="$WORK/argv"
    KEYS_FILE="$WORK/keys"
    export ARGV_FILE KEYS_FILE
}

# A python3 that records its argv and the two credentials it was handed.
stub_python() {
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/python3" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$ARGV_FILE"
printf 'stremio=%s\nseerr=%s\n' "${STREMIO_AUTH_KEY:-}" "${SEERR_API_KEY:-}" > "$KEYS_FILE"
exit "${STUB_EXIT:-0}"
STUB
    chmod +x "$WORK/bin/python3"
    PATH="$WORK/bin:$PATH"
    export PATH
}

# --- help ------------------------------------------------------------------
@test "stremio-library-sync: --help prints the header block" {
    run "$RUN" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "--apply"
    assert_output --partial "--backfill"
}

@test "stremio-library-sync: --help stops at the comment block" {
    # The header is found by awk stopping at the first non-comment line, not by
    # a fixed range. usenet-blackhole.sh's fixed range has been edited four
    # times and once ran a line long, printing `SCRIPT_DIR="$(cd ...)"` as if it
    # were documentation. This is what would catch that here.
    run "$RUN" --help
    refute_output --partial "SCRIPT_DIR="
    refute_output --partial "NAS_STACK_DIR="
    refute_output --partial "set -euo pipefail"
}

@test "stremio-library-sync: --help prints no shell code from the body" {
    run "$RUN" --help
    refute_output --partial "env_value"
    refute_output --partial "PY_ARGS"
}

# --- argument handling -----------------------------------------------------

@test "stremio-library-sync: an unrecognised argument is refused" {
    run "$RUN" --nonsense
    assert_failure 2
    assert_output --partial "unrecognised argument"
}

@test "stremio-library-sync: --max without a value is refused" {
    run "$RUN" --max
    assert_failure 2
    assert_output --partial "--max needs a number"
}

@test "stremio-library-sync: a non-numeric --max is refused" {
    run "$RUN" --max many
    assert_failure 2
    assert_output --partial "must be a whole number"
}

@test "stremio-library-sync: a negative --max is refused" {
    # Refused here rather than in python so the message names the flag the
    # operator typed. A negative cap would slice the pending list from the
    # wrong end instead of bounding the pass.
    run "$RUN" --max -- -1
    assert_failure 2
}

@test "stremio-library-sync: a fractional --max is refused" {
    run "$RUN" --max 1.5
    assert_failure 2
    assert_output --partial "must be a whole number"
}

@test "stremio-library-sync: a well-formed --max is accepted" {
    stub_python
    run "$RUN" --apply --max 2
    assert_success
}

# --- the key guards --------------------------------------------------------

@test "stremio-library-sync: refuses to run without STREMIO_AUTH_KEY" {
    # The Stremio API answers HTTP 200 with an `error` body for a bad key, so a
    # missing one does not look like an auth failure anywhere downstream. The
    # script names it before the request instead.
    printf 'SEERR_API_KEY=seerr-key\n' > "$ENV"
    run "$RUN"
    assert_failure 1
    assert_output --partial "STREMIO_AUTH_KEY is not set"
}

@test "stremio-library-sync: the key guard fires in dry run too" {
    # A dry run is how an operator decides whether applying is safe. One that
    # reports "nothing new" while the key is missing is the opposite of that
    # answer, so the guard is not conditional on --apply.
    printf 'SEERR_API_KEY=seerr-key\n' > "$ENV"
    run "$RUN"
    assert_failure 1
}

@test "stremio-library-sync: refuses to run without SEERR_API_KEY" {
    printf 'STREMIO_AUTH_KEY=stremio-key\n' > "$ENV"
    run "$RUN" --apply
    assert_failure 1
    assert_output --partial "SEERR_API_KEY is not set"
}

@test "stremio-library-sync: refuses to run when .env is missing entirely" {
    rm -f "$ENV"
    run "$RUN"
    assert_failure 1
    assert_output --partial "not set"
}

@test "stremio-library-sync: a value containing an equals sign survives" {
    # Read through lib/env-file.sh rather than `cut -d= -f2`, which returns the
    # field between the first and second `=` and truncates a base64 key.
    stub_python
    printf 'SEERR_API_KEY=abc==def\nSTREMIO_AUTH_KEY=xyz==\n' > "$ENV"
    run "$RUN"
    assert_success
    run cat "$KEYS_FILE"
    assert_output --partial "seerr=abc==def"
    assert_output --partial "stremio=xyz=="
}

@test "stremio-library-sync: the last assignment in .env wins" {
    stub_python
    printf 'STREMIO_AUTH_KEY=first\nSTREMIO_AUTH_KEY=second\nSEERR_API_KEY=k\n' > "$ENV"
    run "$RUN"
    assert_success
    run cat "$KEYS_FILE"
    assert_output --partial "stremio=second"
}

# --- the credential never reaches argv -------------------------------------

@test "stremio-library-sync: the keys go through the environment, not argv" {
    stub_python
    run "$RUN" --apply
    assert_success

    run cat "$ARGV_FILE"
    refute_output --partial "stremio-key"
    refute_output --partial "seerr-key"

    run cat "$KEYS_FILE"
    assert_output --partial "stremio=stremio-key"
    assert_output --partial "seerr=seerr-key"
}

@test "stremio-library-sync: the state path is passed as the only positional" {
    stub_python
    run "$RUN" --apply
    assert_success
    run cat "$ARGV_FILE"
    assert_output --partial "$STATE"
}

# --- --apply is passed only when asked for ---------------------------------

@test "stremio-library-sync: a dry run does not pass --apply to python" {
    stub_python
    run "$RUN"
    assert_success
    run cat "$ARGV_FILE"
    refute_output --partial "--apply"
}

@test "stremio-library-sync: --apply passes --apply to python" {
    stub_python
    run "$RUN" --apply
    assert_success
    run cat "$ARGV_FILE"
    assert_output --partial "--apply"
}

@test "stremio-library-sync: --backfill is passed only when asked for" {
    stub_python
    run "$RUN" --apply
    assert_success
    run cat "$ARGV_FILE"
    refute_output --partial "--backfill"

    run "$RUN" --apply --backfill
    assert_success
    run cat "$ARGV_FILE"
    assert_output --partial "--backfill"
}

@test "stremio-library-sync: --max is passed with its value" {
    stub_python
    run "$RUN" --apply --max 7
    assert_success
    run cat "$ARGV_FILE"
    assert_output --partial "--max"
    assert_output --partial "7"
}

@test "stremio-library-sync: no --max passes no cap, leaving python's default" {
    stub_python
    run "$RUN" --apply
    assert_success
    run cat "$ARGV_FILE"
    refute_output --partial "--max"
}

@test "stremio-library-sync: --max=7 is accepted as one token" {
    stub_python
    run "$RUN" --apply --max=7
    assert_success
    run cat "$ARGV_FILE"
    assert_output --partial "7"
}

# --- the banner ------------------------------------------------------------

@test "stremio-library-sync: the banner says which mode it is in" {
    stub_python
    run "$RUN"
    assert_success
    assert_output --partial "Mode: DRY RUN"

    run "$RUN" --apply
    assert_success
    assert_output --partial "Mode: APPLYING"
}

@test "stremio-library-sync: the banner names the cap it will use" {
    # Printed even when nothing is pending, because "capped" and "nothing to
    # do" otherwise look identical in the summary.
    stub_python
    run "$RUN" --apply --max 2
    assert_success
    assert_output --partial "Per-pass cap: 2"
}

@test "stremio-library-sync: the banner says when no cap was given" {
    stub_python
    run "$RUN" --apply
    assert_success
    assert_output --partial "Per-pass cap: default"
}

@test "stremio-library-sync: --backfill is announced only on a first run" {
    stub_python
    run "$RUN" --apply --backfill
    assert_success
    assert_output --partial "Backfill: ON"

    mkdir -p "$(dirname "$STATE")"
    printf '{"version":1,"handled":{}}\n' > "$STATE"
    run "$RUN" --apply --backfill
    assert_success
    refute_output --partial "Backfill: ON"
}

# --- exit status -----------------------------------------------------------

@test "stremio-library-sync: a failing pass exits non-zero" {
    # The unit is oneshot, so this is what makes an unreachable Seerr visible in
    # systemctl status rather than only in the log file.
    stub_python
    STUB_EXIT=1 run "$RUN" --apply
    assert_failure 1
    assert_output --partial "exited non-zero"
}

@test "stremio-library-sync: a successful pass exits zero" {
    stub_python
    run "$RUN" --apply
    assert_success
}

# --- the units -------------------------------------------------------------

@test "stremio-library-sync: the service runs the script with --apply" {
    # Without --apply the timer would run the dry run forever: it would print
    # what it would request, request nothing, and exit 0.
    run grep '^ExecStart=' "$REPO_ROOT/scripts/stremio-library-sync.service"
    assert_success
    assert_output --partial "/volume1/docker/arr-stack/scripts/stremio-library-sync.sh"
    assert_output --partial "--apply"
}

@test "stremio-library-sync: the service creates its log directory in the same shell" {
    # Splitting them -- ExecStartPre=mkdir plus StandardOutput=append: -- fails
    # at boot with status=209/STDOUT, because systemd applies the unit's
    # StandardOutput to ExecStartPre too.
    run grep '^ExecStart=' "$REPO_ROOT/scripts/stremio-library-sync.service"
    assert_output --partial "mkdir -p /volume1/docker/arr-stack/logs"
    assert_output --partial ">> /volume1/docker/arr-stack/logs/stremio-library-sync.log 2>&1"

    run grep -c '^ExecStartPre=' "$REPO_ROOT/scripts/stremio-library-sync.service"
    assert_output "0"

    run grep -c '^StandardOutput=' "$REPO_ROOT/scripts/stremio-library-sync.service"
    assert_output "0"
}

@test "stremio-library-sync: the service loads .env for its credentials" {
    run grep '^EnvironmentFile=' "$REPO_ROOT/scripts/stremio-library-sync.service"
    assert_output --partial "/volume1/docker/arr-stack/.env"
}

@test "stremio-library-sync: the timer repeats and is enabled by the install step" {
    run grep '^WantedBy=timers.target' "$REPO_ROOT/scripts/stremio-library-sync.timer"
    assert_success
    run grep '^OnUnitActiveSec=' "$REPO_ROOT/scripts/stremio-library-sync.timer"
    assert_success
}

@test "stremio-library-sync: the timer's first elapse is measured from activation" {
    # OnBootSec measures from the last boot, which on a NAS up for weeks is
    # always in the past: `systemctl --user enable --now` would fire the service
    # in the same second the schedule was registered. queue-cleanup was caught
    # by exactly that.
    run grep -E '^On(Boot|Startup|UnitInactive)Sec=' "$REPO_ROOT/scripts/stremio-library-sync.timer"
    assert_failure
    run grep '^OnActiveSec=' "$REPO_ROOT/scripts/stremio-library-sync.timer"
    assert_success
}

@test "stremio-library-sync: the install docs name this timer" {
    # A scheduled unit nobody documents is how queue-cleanup shipped: a correct
    # script, a correct timer, and nothing anywhere saying the timer existed.
    run grep -F "stremio-library-sync.timer" "$REPO_ROOT/docs/MAINTENANCE.md"
    assert_success
}

@test "stremio-library-sync: the documented cadence matches the unit" {
    # Both halves are read from where they live. Restating "10 minutes" here
    # would keep passing on the day the unit and the prose stopped agreeing,
    # which is exactly when it needs to fail.
    local minutes
    minutes=$(grep -oE '^OnUnitActiveSec=[0-9]+min' "$REPO_ROOT/scripts/stremio-library-sync.timer" | grep -oE '[0-9]+')
    [ -n "$minutes" ] || fail "OnUnitActiveSec is not in minutes; this check cannot compare anything"

    run grep -E "every ${minutes} minutes" "$REPO_ROOT/docs/MAINTENANCE.md"
    assert_success
}

@test "stremio-library-sync: the units carry no root/system-install assumptions" {
    local f
    for f in stremio-library-sync.service stremio-library-sync.timer; do
        run grep -c '/etc/systemd' "$REPO_ROOT/scripts/$f"
        assert_output "0"
        run grep -c '^WantedBy=multi-user.target' "$REPO_ROOT/scripts/$f"
        assert_output "0"
        run grep -c '^User=' "$REPO_ROOT/scripts/$f"
        assert_output "0"
    done
}

# --- documentation ---------------------------------------------------------

@test "stremio-library-sync: STREMIO_AUTH_KEY is documented in .env.example" {
    # .env.example is the repo's only inventory of what an install needs. A key
    # that exists only on the machine that happens to work is invisible to
    # everyone else.
    run grep -E '^# ?STREMIO_AUTH_KEY=' "$REPO_ROOT/.env.example"
    assert_success
}

@test "stremio-library-sync: .env.example says where the auth key comes from" {
    # "Set the auth key" is not an instruction. The value is not displayed
    # anywhere in Stremio's UI, so the file that names it has to say how to get
    # it.
    run grep -F "auth.key" "$REPO_ROOT/.env.example"
    assert_success
}

# --- the script has no network of its own ----------------------------------

@test "stremio-library-sync: the shell half makes no HTTP requests itself" {
    # Everything network-facing lives in the python module, which is what the
    # python tests fake. curl or wget here would be a second, untested path to
    # the same APIs.
    run grep -E '\b(curl|wget)\b' "$REPO_ROOT/scripts/stremio-library-sync.sh"
    assert_failure
}
