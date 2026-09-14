#!/usr/bin/env bats
# scripts/backlog-search.sh -- argument handling and the shape of the sweep.
#
# The sweep's decision logic lives in scripts/lib/backlog_search.py and is
# covered by tests/python/test_backlog_search.py. What is tested here is the
# shell half: the flags, the guards that stop a bad invocation reaching the
# arrs, and the properties that would make this script dangerous if they
# regressed -- an unbounded sweep, or a cooldown that never starts.
#
# Argument parsing is read off the mode banner, which prints the values the
# loop settled on. That needs no python3, no stub and no PATH juggling, and the
# banner is the operator's own confirmation of what the run is about to do --
# so it is the thing worth asserting on.

setup() {
    load helpers/setup
    SCRIPT="$REPO_ROOT/scripts/backlog-search.sh"
    WORK="$BATS_TEST_TMPDIR/stack"
    mkdir -p "$WORK/scripts"
    cp "$SCRIPT" "$WORK/scripts/backlog-search.sh"
    cp -r "$REPO_ROOT/scripts/lib" "$WORK/scripts/lib"
    chmod +x "$WORK/scripts/backlog-search.sh"
    ENV="$WORK/.env"
    printf 'SONARR_API_KEY=testsonarrkey\nRADARR_API_KEY=testradarrkey\n' > "$ENV"
    RUN="$WORK/scripts/backlog-search.sh"
}

@test "backlog-search: the default mode is a dry run with a bounded limit" {
    # Ten seasons per run against the timer's four-hour interval is what drains
    # this backlog without presenting a burst. A silent change to either number
    # is a change to how hard the indexers get hit.
    # No assert_success: this copy has no arr to reach, so the Python half
    # fails. The banner is printed before it runs and is the thing under test.
    run "$RUN"
    assert_output --partial "DRY RUN (limit 10 season(s)/run, film cooldown 6h)"
}

@test "backlog-search: --apply announces that it applies" {
    run "$RUN" --apply
    assert_output --partial "APPLYING (limit 10 season(s)/run, film cooldown 6h)"
}

@test "backlog-search: --limit reaches the banner" {
    run "$RUN" --apply --limit 25
    assert_output --partial "limit 25 season(s)/run"
}

@test "backlog-search: --limit=7 is accepted as one argument" {
    run "$RUN" --limit=7
    assert_output --partial "limit 7 season(s)/run"
}

@test "backlog-search: --cooldown reaches the banner" {
    run "$RUN" --cooldown 3
    assert_output --partial "film cooldown 3h"
}

@test "backlog-search: a trailing --limit is refused, not silently defaulted" {
    # Falling through to the default reads as "10 was accepted" when nothing
    # was: the run would sweep a different number than the operator asked for
    # and say nothing about it.
    run "$RUN" --limit
    assert_failure
    assert_output --partial "--limit needs a number"
}

@test "backlog-search: a non-numeric --limit is refused" {
    run "$RUN" --limit abc
    assert_failure
    assert_output --partial "positive integer"
}

@test "backlog-search: --limit 0 is refused" {
    # Zero would make the sweep a silent no-op that still reported success.
    run "$RUN" --limit 0
    assert_failure
    assert_output --partial "at least 1"
}

@test "backlog-search: a non-numeric --cooldown is refused" {
    # Coercing a typo to 0 would disable the cooldown and let the bulk film
    # search re-fire on every interval -- the burst this option exists to stop.
    run "$RUN" --cooldown soon
    assert_failure
    assert_output --partial "number of hours"
}

@test "backlog-search: an unrecognised argument is refused" {
    run "$RUN" --applyy
    assert_failure
    assert_output --partial "unrecognised argument"
}

@test "backlog-search: --help prints the header block and exits 0" {
    run "$RUN" --help
    assert_success
    assert_output --partial "bounded slice of the Sonarr/Radarr missing backlog"
    assert_output --partial "--cooldown"
}

@test "backlog-search: --help does not require .env to exist" {
    rm -f "$ENV"
    run "$RUN" --help
    assert_success
}

@test "backlog-search: --help works on this host's sed" {
    # The help block used to be `sed -n '2,/^$/{...}'`, which BSD sed rejects
    # with "extra characters at the end of p command" -- so on macOS --help
    # printed sed's error and exited 1. Asserting on the real script with
    # whatever sed this host has is the only way that portability bug could
    # have been caught before it shipped.
    run bash "$SCRIPT" --help
    assert_success
    [[ "$output" == *"bounded slice"* ]] || fail "help printed: ${output:0:120}"
    [[ "$output" != *"extra characters"* ]] || fail "sed rejected the program"
}

@test "backlog-search: missing API keys are an error, not an empty sweep" {
    printf 'UNRELATED=1\n' > "$ENV"
    run "$RUN"
    assert_failure
    assert_output --partial "Could not get API keys"
}

@test "backlog-search: the API keys go in as environment, never as argv" {
    # argv is world-readable through /proc/<pid>/cmdline, and this runs on a
    # timer as a background service. The assignments sit on the continuation
    # line before the python3 call, not on it.
    run grep -E 'SONARR_API_KEY="\$SONARR_KEY" RADARR_API_KEY="\$RADARR_KEY"' "$SCRIPT"
    assert_success
    run grep -nE 'python3 .*\$SONARR_KEY|python3 .*\$RADARR_KEY' "$SCRIPT"
    assert_failure
}

@test "backlog-search: the Python half is handed apply, verbose, limit, state, cooldown" {
    # The order is the Python half's argv contract; getting it wrong is silent
    # (the limit parses as a path, say) and the tests that would catch it are in
    # tests/python/test_backlog_search.py, which only see the arguments this
    # line produces.
    run grep -E 'python3 "\$\{SCRIPT_DIR\}/lib/backlog_search\.py" "\$APPLY" "\$VERBOSE" "\$LIMIT" "\$STATE_PATH" "\$COOLDOWN"' "$SCRIPT"
    assert_success
}

@test "backlog-search: a failing Python half fails the script" {
    # A sweep that reported success while the arrs were never asked to search
    # anything is the failure this whole script exists to avoid.
    run grep -E 'the backlog search exited non-zero' "$SCRIPT"
    assert_success
    run grep -cE '^    exit 1' "$SCRIPT"
    assert_success
}

@test "backlog-search: the timer's first elapse is measured from activation" {
    # Same trap queue-cleanup.timer was caught by: OnBootSec on a NAS that has
    # been up for weeks is always in the past, so `enable --now` would start
    # the sweep in the same second the schedule was registered.
    local timer="$REPO_ROOT/scripts/backlog-search.timer"
    run grep -E '^On(Boot|Startup|UnitInactive)Sec=' "$timer"
    assert_failure
    run grep -E '^OnActiveSec=' "$timer"
    assert_success
}

@test "backlog-search: the service runs the script with --apply" {
    # The unit is what makes this a schedule rather than a suggestion. Without
    # --apply every elapse would be a dry run that logs happily and searches
    # nothing: a green timer attached to no work.
    run grep -E '^ExecStart=.*backlog-search\.sh --apply' \
        "$REPO_ROOT/scripts/backlog-search.service"
    assert_success
}

@test "backlog-search: the service has no ExecStartPre" {
    # StandardOutput is applied to every process systemd spawns, ExecStartPre
    # included, so a separate mkdir step dies before it can create the
    # directory the redirect points into. Observed on queue-cleanup: 209/STDOUT.
    # Anchored, because the unit's own comment names ExecStartPre to explain
    # why it is absent.
    run grep -cE '^ExecStartPre=' "$REPO_ROOT/scripts/backlog-search.service"
    assert_output "0"
    run grep -E '^ExecStart=.*mkdir -p' "$REPO_ROOT/scripts/backlog-search.service"
    assert_success
}

@test "backlog-search: the log is only trimmed on a real run" {
    # A dry run must not be the thing that changes what the operator is
    # reading -- that was learned the hard way in queue-cleanup.sh.
    run grep -E '^if \$APPLY && \[\[ -f "\$LOG_FILE" \]\]' "$SCRIPT"
    assert_success
}

@test "backlog-search: the script never shells out to an unbounded arr command" {
    # The reason this script exists instead of a curl to MissingEpisodeSearch:
    # that command searches the whole backlog at once, cannot be cancelled, and
    # had to be killed by restarting Sonarr on 2026-09-13. The names appear in
    # the header explaining that; they must never reach a command.
    run grep -nE 'python3 .*(MissingEpisodeSearch|MissingMoviesSearch)' \
        "$REPO_ROOT/scripts/backlog-search.sh"
    assert_failure
}
