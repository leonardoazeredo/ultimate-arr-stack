#!/usr/bin/env bats
# scripts/usenet-blackhole.sh -- argument handling and the shape of the pass.
#
# The pass's decision logic lives in scripts/lib/usenet_blackhole.py and is
# covered by tests/python/test_usenet_blackhole.py. What is tested here is the
# shell half: the flags, the guard that stops an unkeyed --apply, and two
# properties that are invisible until they are wrong --
#
#   * where the staging directory sits, and
#   * where the TorBox key does NOT sit.
#
# Argument parsing is read off the mode banner, which prints the values the loop
# settled on. That needs no stubbing and the banner is the operator's own
# confirmation of what the run is about to do, so it is the thing worth
# asserting on. The Python dry run is reachable from here (no network, no key),
# which is what makes the printed paths assertable too.

setup() {
    load helpers/setup
    SCRIPT="$REPO_ROOT/scripts/usenet-blackhole.sh"
    WORK="$BATS_TEST_TMPDIR/stack"
    mkdir -p "$WORK/scripts"
    cp "$SCRIPT" "$WORK/scripts/usenet-blackhole.sh"
    cp -r "$REPO_ROOT/scripts/lib" "$WORK/scripts/lib"
    chmod +x "$WORK/scripts/usenet-blackhole.sh"
    ENV="$WORK/.env"
    printf 'MEDIA_ROOT=%s/data\n' "$WORK" > "$ENV"
    RUN="$WORK/scripts/usenet-blackhole.sh"
    NZB="$WORK/data/usenet/blackhole/nzb"
    WATCH="$WORK/data/usenet/blackhole/complete"
    STAGING="$WORK/data/usenet/blackhole/staging"
    KEYFILE="$WORK/key"
}

# A python3 that records how it was called instead of running anything. Used to
# assert what the script puts on the command line and in the environment -- the
# two places a credential leaks from.
stub_python() {
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/python3" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$ARGV_FILE"
printf '%s' "${TORBOX_API_KEY:-}" > "$KEYFILE"
printf 'sonarr=%s radarr=%s' "${SONARR_API_KEY:-}" "${RADARR_API_KEY:-}" > "$ARRKEYFILE"
STUB
    chmod +x "$WORK/bin/python3"
    ARGV_FILE="$WORK/argv"
    KEYFILE="$WORK/key"
    ARRKEYFILE="$WORK/arrkeys"
    export ARGV_FILE KEYFILE ARRKEYFILE
}

# --- help ------------------------------------------------------------------

@test "usenet-blackhole: --help prints the header block" {
    run "$RUN" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "--apply"
}

@test "usenet-blackhole: --help stops at the comment block" {
    # The fixed-range sed that prints this used to run one line long, so --help
    # ended with `SCRIPT_DIR="$(cd ...)"` -- shell source printed as if it were
    # documentation. Anything that adds a line to the header has to move the
    # range with it, and this is what says so.
    run "$RUN" --help
    refute_output --partial "SCRIPT_DIR="
    refute_output --partial "NAS_STACK_DIR="
}

# --- the banner ------------------------------------------------------------

@test "usenet-blackhole: the default mode is a dry run with a 24-hour timeout" {
    # The timeout is what turns a release that never completes into a log line
    # instead of an invisible one, so it is not a detail that should drift.
    run "$RUN"
    assert_success
    assert_output --partial "DRY RUN (timeout 24h, use --apply to submit)"
}

@test "usenet-blackhole: --apply announces that it applies" {
    printf 'MEDIA_ROOT=%s/data\nTORBOX_API_KEY=testtorboxkey\n' "$WORK" > "$ENV"
    run "$RUN" --apply
    assert_output --partial "APPLYING (submit, poll, fetch; timeout 24h)"
}

@test "usenet-blackhole: --timeout-hours reaches the banner" {
    run "$RUN" --timeout-hours 6
    assert_output --partial "timeout 6h"
}

@test "usenet-blackhole: --timeout-hours=6 is accepted as one argument" {
    run "$RUN" --timeout-hours=6
    assert_output --partial "timeout 6h"
}

@test "usenet-blackhole: a trailing --timeout-hours is refused, not silently defaulted" {
    # Falling through to 24 reads as "6 was accepted" when nothing was, and the
    # difference is how long a stuck release stays invisible.
    run "$RUN" --timeout-hours
    assert_failure
    assert_output --partial "--timeout-hours needs a number"
}

@test "usenet-blackhole: a non-numeric --timeout-hours is refused" {
    run "$RUN" --timeout-hours soon
    assert_failure
    assert_output --partial "must be a number"
}

@test "usenet-blackhole: a two-dot --timeout-hours is refused" {
    # `1.2.3` passes a naive digit-and-dot check and then reaches python's
    # float() as a ValueError, which exits 1 with a traceback instead of a
    # message about the argument.
    run "$RUN" --timeout-hours 1.2.3
    assert_failure
    assert_output --partial "must be a number"
}

@test "usenet-blackhole: the banner carries the 4-hour stall rule by default" {
    # The stall rule is what stops a job that never moves holding one of the ten
    # slots for the full timeout, so the bound it settled on is worth confirming
    # the same way the timeout is.
    run "$RUN"
    assert_success
    assert_output --partial "Stall rule: no progress for 4h fails the job"
}

@test "usenet-blackhole: --stall-hours reaches the banner" {
    run "$RUN" --stall-hours 6
    assert_success
    assert_output --partial "Stall rule: no progress for 6h fails the job"
}

@test "usenet-blackhole: --stall-hours=6 is accepted as one argument" {
    run "$RUN" --stall-hours=6
    assert_success
    assert_output --partial "Stall rule: no progress for 6h fails the job"
}

@test "usenet-blackhole: a trailing --stall-hours is refused, not silently defaulted" {
    # Falling through to 4 reads as "6 was accepted" when nothing was, and the
    # difference is how long a dead release keeps one of ten slots.
    run "$RUN" --stall-hours
    assert_failure
    assert_output --partial "--stall-hours needs a number"
}

@test "usenet-blackhole: a non-numeric --stall-hours is refused" {
    run "$RUN" --stall-hours soon
    assert_failure
    assert_output --partial "must be a number"
}

@test "usenet-blackhole: a two-dot --stall-hours is refused" {
    # The same trap as --timeout-hours: `1.2.3` passes a naive digit-and-dot
    # check and reaches python's float() as a ValueError, which exits 1 with a
    # traceback instead of a message about the argument.
    run "$RUN" --stall-hours 1.2.3
    assert_failure
    assert_output --partial "must be a number"
}

@test "usenet-blackhole: a zero --stall-hours is refused, in any spelling" {
    # Zero is numeric, so the pattern check above lets it through -- and it is
    # the one value that makes the stall rule true on the first poll after a job
    # is submitted (`stalled_hours > 0` the moment the clock starts), so one
    # pass would fail every in-flight job it has. All four spellings are that
    # same bound. Negatives never reach this check: "-" is not in the pattern's
    # allowed set, which the -1 case below pins.
    for value in 0 0.0 .0 00; do
        run "$RUN" --stall-hours "$value"
        assert_failure 2
        assert_output --partial "ERROR: --stall-hours must be greater than 0, got '$value'"
    done
    run "$RUN" --stall-hours -1
    assert_failure 2
    assert_output --partial "ERROR: --stall-hours must be a number, got '-1'"
}

@test "usenet-blackhole: --stall-hours reaches python" {
    # The banner is only half of it: a value that never reaches the watcher
    # would leave the banner announcing a bound nothing enforces.
    printf 'MEDIA_ROOT=%s/data\nTORBOX_API_KEY=testtorboxkey\n' "$WORK" > "$ENV"
    stub_python
    run env "PATH=$WORK/bin:$PATH" "$RUN" --apply --stall-hours 6
    assert_success
    # -A 1 so the number is read out of the argv pair, not from anywhere else
    # in the file -- the flag and its value both have to be there.
    run grep -A 1 -x -- "--stall-hours" "$ARGV_FILE"
    assert_success
    assert_output --partial "6"
}

@test "usenet-blackhole: the banner says the in-flight cap is off by default" {
    # The cap ships inert, and "off" has to be visible. A pass that quietly
    # gained a ceiling looks exactly like a pass with nothing waiting, and the
    # measurement the flag exists for rests on knowing which of the two it was.
    run "$RUN"
    assert_success
    assert_output --partial "In-flight cap: off"
}

@test "usenet-blackhole: --max-inflight reaches the banner" {
    run "$RUN" --max-inflight 6
    assert_success
    assert_output --partial "In-flight cap: 6"
    # ...and zero is still spelled as off, not as a cap of zero.
    run "$RUN" --max-inflight 0
    assert_success
    assert_output --partial "In-flight cap: off"
}

@test "usenet-blackhole: --max-inflight=6 is accepted as one argument" {
    run "$RUN" --max-inflight=6
    assert_success
    assert_output --partial "In-flight cap: 6"
}

@test "usenet-blackhole: a trailing --max-inflight is refused, not silently defaulted" {
    # Falling through to 0 reads as "off was chosen" when nothing was, and the
    # difference is whether the pass someone is reading a log from was capped.
    run "$RUN" --max-inflight
    assert_failure 2
    assert_output --partial "--max-inflight needs a number"
}

@test "usenet-blackhole: a non-integer --max-inflight is refused" {
    # Digits only. The negative is the dangerous one -- `len(jobs) >= -1` is
    # true before the first offer, so the pass would submit nothing while its
    # log said the cap had been reached -- and "1.5" would reach python's type
    # check as a float where the cap is a count.
    for value in soon -1 1.5; do
        run "$RUN" --max-inflight "$value"
        assert_failure 2
        assert_output --partial "ERROR: --max-inflight must be a whole number, got '$value'"
    done
}

@test "usenet-blackhole: a leading-zero --max-inflight is read as decimal" {
    # "08" passes the digits-only check, and bash then reads it as an invalid
    # octal in the banner's `-eq` test: the comparison errors, falls to the else
    # branch, and prints the operator's spelling -- while python reads the same
    # string as 8. Both halves have to see one decimal number, and a value the
    # validation accepted must not put an arithmetic error in the timer's log.
    printf 'MEDIA_ROOT=%s/data\nTORBOX_API_KEY=testtorboxkey\n' "$WORK" > "$ENV"
    stub_python
    run env "PATH=$WORK/bin:$PATH" "$RUN" --apply --max-inflight 08
    assert_success
    refute_output --partial "value too great for base"
    assert_output --partial "In-flight cap: 8"
    refute_output --partial "In-flight cap: 08"
    run grep -A 1 -x -- "--max-inflight" "$ARGV_FILE"
    assert_success
    # Exact, not `--partial`: "8" is a substring of "08", and the difference
    # between the two is the whole point of this test.
    assert_line --index 1 "8"
}

@test "usenet-blackhole: --max-inflight reaches python" {
    # Same rule as --stall-hours: a value the banner announces but python never
    # receives leaves the ceiling inert, and the banner would be the only place
    # it existed.
    printf 'MEDIA_ROOT=%s/data\nTORBOX_API_KEY=testtorboxkey\n' "$WORK" > "$ENV"
    stub_python
    run env "PATH=$WORK/bin:$PATH" "$RUN" --apply --max-inflight 6
    assert_success
    run grep -A 1 -x -- "--max-inflight" "$ARGV_FILE"
    assert_success
    assert_output --partial "6"
}

@test "usenet-blackhole: an unknown argument is refused" {
    run "$RUN" --applyy
    assert_failure
    assert_output --partial "unrecognised argument"
}

# --- the key ---------------------------------------------------------------

@test "usenet-blackhole: --apply without a key stops before python runs" {
    stub_python
    run env "PATH=$WORK/bin:$PATH" "$RUN" --apply
    assert_failure
    assert_output --partial "TORBOX_API_KEY is not set"
    [ ! -f "$WORK/argv" ]
}

@test "usenet-blackhole: a dry run does not need a key" {
    # Being able to see what a run would submit, before handing it a credential,
    # is the whole reason the dry run is the default.
    run "$RUN"
    assert_success
    assert_output --partial "in flight:    0"
}

@test "usenet-blackhole: the key travels in the environment, not on the command line" {
    # `--api-key "$KEY"` until this test existed, which put the TorBox token in
    # python3's argv -- world-readable through /proc/<pid>/cmdline, on a timer
    # that runs every two minutes. queue-cleanup.sh carries the same fix for the
    # same reason. Both halves are asserted: absent from argv is only half a
    # fix if it also fails to arrive.
    printf 'MEDIA_ROOT=%s/data\nTORBOX_API_KEY=testtorboxkey\n' "$WORK" > "$ENV"
    stub_python
    run env "PATH=$WORK/bin:$PATH" "$RUN" --apply
    assert_success
    assert_equal "$(cat "$KEYFILE")" "testtorboxkey"
    run grep -q "testtorboxkey" "$ARGV_FILE"
    assert_failure
}

@test "usenet-blackhole: the default run does not pass --apply to python" {
    # This is the one that matters most in this file. The flags were built with
    # `${APPLY:+--apply}`, which reads as "add it when applying" and is not:
    # `:+` tests for non-empty, and APPLY=false is non-empty. Every run applied,
    # under a banner that said DRY RUN -- and a dry run that silently applies is
    # worse than no dry run, because it is exactly the mode an operator uses to
    # decide whether applying is safe.
    printf 'MEDIA_ROOT=%s/data\nTORBOX_API_KEY=testtorboxkey\n' "$WORK" > "$ENV"
    stub_python
    run env "PATH=$WORK/bin:$PATH" "$RUN"
    assert_success
    run grep -qx -- "--apply" "$ARGV_FILE"
    assert_failure
}

@test "usenet-blackhole: --apply reaches python" {
    # The other half: a guard that never passes the flag would be just as wrong,
    # and would make --apply a no-op on a timer nobody reads.
    printf 'MEDIA_ROOT=%s/data\nTORBOX_API_KEY=testtorboxkey\n' "$WORK" > "$ENV"
    stub_python
    run env "PATH=$WORK/bin:$PATH" "$RUN" --apply
    assert_success
    run grep -qx -- "--apply" "$ARGV_FILE"
    assert_success
}

@test "usenet-blackhole: --verbose is only passed when asked for" {
    # Same expansion, same bug, quieter symptom: every pass logged per-job
    # progress whether or not anyone wanted it.
    printf 'MEDIA_ROOT=%s/data\nTORBOX_API_KEY=testtorboxkey\n' "$WORK" > "$ENV"
    stub_python
    run env "PATH=$WORK/bin:$PATH" "$RUN"
    assert_success
    run grep -qx -- "--verbose" "$ARGV_FILE"
    assert_failure

    run env "PATH=$WORK/bin:$PATH" "$RUN" -v
    assert_success
    run grep -qx -- "--verbose" "$ARGV_FILE"
    assert_success
}

@test "usenet-blackhole: failure reporting is off unless asked for" {
    # The whole safety story for Phase 1 rests on the default. Reporting is the
    # thing that can blocklist a release that was fine, so a pass that did not
    # ask for it must not resolve a single match -- and the banner has to say
    # which mode it ran in, because "nothing was reported" and "there was
    # nothing to report" have to be told apart by whoever reads the log.
    printf 'MEDIA_ROOT=%s/data\nTORBOX_API_KEY=testtorboxkey\n' "$WORK" > "$ENV"
    stub_python
    run env "PATH=$WORK/bin:$PATH" "$RUN"
    assert_success
    assert_output --partial "Failure reporting: off"
    run grep -qx -- "--report-failures" "$ARGV_FILE"
    assert_failure
    run grep -qx -- "--report-dry-run" "$ARGV_FILE"
    assert_failure
}

@test "usenet-blackhole: --report-failures and --report-dry-run reach python" {
    # A guard that never passes the flag would make both a no-op on a timer
    # nobody reads -- and the dry run is the only thing standing between a
    # wrong title match and a blocklisted release, so it has to actually work.
    printf 'MEDIA_ROOT=%s/data\nTORBOX_API_KEY=testtorboxkey\n' "$WORK" > "$ENV"
    stub_python
    run env "PATH=$WORK/bin:$PATH" "$RUN" --apply --report-failures
    assert_success
    assert_output --partial "Failure reporting: ON"
    run grep -qx -- "--report-failures" "$ARGV_FILE"
    assert_success

    run env "PATH=$WORK/bin:$PATH" "$RUN" --apply --report-dry-run
    assert_success
    assert_output --partial "Failure reporting: DRY RUN"
    run grep -qx -- "--report-dry-run" "$ARGV_FILE"
    assert_success
}

@test "usenet-blackhole: the arr keys travel in the environment too" {
    # Same rule as the TorBox key, same reason, and the same half-a-fix trap:
    # absent from argv only counts if it also arrives.
    printf 'MEDIA_ROOT=%s/data\nTORBOX_API_KEY=testtorboxkey\nSONARR_API_KEY=testsonarrkey\nRADARR_API_KEY=testradarrkey\n' "$WORK" > "$ENV"
    stub_python
    run env "PATH=$WORK/bin:$PATH" "$RUN" --apply --report-failures
    assert_success
    run grep -q "testsonarrkey\|testradarrkey" "$ARGV_FILE"
    assert_failure
    run cat "$ARRKEYFILE"
    assert_output --partial "sonarr=testsonarrkey"
    assert_output --partial "radarr=testradarrkey"
}

# --- the paths -------------------------------------------------------------

@test "usenet-blackhole: the three folders are derived from MEDIA_ROOT" {
    # A blackhole is a filesystem handshake, so these have to be the host-side
    # counterparts of the /data paths the arrs are configured with. Deriving
    # them from MEDIA_ROOT is what keeps the two in step.
    run "$RUN"
    assert_success
    assert_output --partial "$NZB"
    assert_output --partial "$WATCH"
    assert_output --partial "$STAGING"
}

@test "usenet-blackhole: staging is not inside the arr's watch folder" {
    # The reason this is a sibling and not a `.incoming-` directory: Sonarr does
    # not skip dot-directories at the top level of a watch folder, so a staging
    # directory in there is reported as a completed download and its
    # half-written files are what gets imported. Read back out of the script's
    # own output rather than recomputed here, so moving the default is caught.
    #
    # All three assertions are needed. `staging inside watch` was the first
    # version of this test, and the mutation that pointed WATCH_DIR at the
    # staging folder survived it: with the two equal, each fetch stages at
    # `<watch>/<job key>` and the arr sees a release named after a hash.
    run "$RUN"
    assert_success
    watch=$(sed -n 's/^  watch folder: *//p' <<< "$output")
    staging=$(sed -n 's/^  staging: *//p' <<< "$output")
    [ -n "$watch" ]
    [ -n "$staging" ]
    [ "$staging" != "$watch" ]
    [[ "$staging" != "$watch"/* ]]
    # Siblings, so the rename into the watch folder stays a rename. Across
    # filesystems `os.replace` raises EXDEV and every fetch fails.
    [ "$(dirname "$staging")" = "$(dirname "$watch")" ]
}

@test "usenet-blackhole: python is called with the five paths in order" {
    # Misordering these is silent: the state path would be used as the staging
    # directory, or the failed log written where the state file belongs.
    printf 'MEDIA_ROOT=%s/data\nTORBOX_API_KEY=testtorboxkey\n' "$WORK" > "$ENV"
    stub_python
    run env "PATH=$WORK/bin:$PATH" "$RUN" --apply
    assert_success
    # Index 0 is the module path -- that is python's own first argument, not one
    # of the five the script is responsible for ordering.
    run sed -n '1,6p' "$ARGV_FILE"
    assert_line --index 1 "$NZB"
    assert_line --index 2 "$WATCH"
    assert_line --index 3 "$STAGING"
    assert_line --index 4 "$WORK/logs/usenet-blackhole-state.json"
    assert_line --index 5 "$WORK/logs/usenet-blackhole-failed.log"
}

@test "usenet-blackhole: a failing pass is reported and exits non-zero" {
    # The service is Type=oneshot, so this exit status is the only thing that
    # puts a failed pass in front of anyone.
    printf 'MEDIA_ROOT=%s/data\nTORBOX_API_KEY=testtorboxkey\n' "$WORK" > "$ENV"
    mkdir -p "$WORK/bin"
    printf '#!/bin/bash\nexit 3\n' > "$WORK/bin/python3"
    chmod +x "$WORK/bin/python3"
    run env "PATH=$WORK/bin:$PATH" "$RUN" --apply
    assert_failure
    assert_output --partial "exited non-zero"
}

# --- the shipped unit ------------------------------------------------------

@test "usenet-blackhole: the shipped unit caps in-flight jobs below TorBox's ten slots" {
    # The script ships the cap inert (0, printed as "off"), which is right for a
    # rollout and wrong as a resting state -- the argument this unit's own
    # --report-failures comment already makes. TorBox refuses the eleventh
    # concurrent usenet download, so a ceiling above 10 bounds nothing, and 0
    # bounds nothing at all: on 2026-09-18 the pass submitted 46 jobs in one
    # hour and left 60 incomplete while neither arr could see any of them.
    local unit="$REPO_ROOT/scripts/usenet-blackhole.service"
    local exec_line value
    exec_line="$(grep -m1 '^ExecStart=' "$unit")"
    # `[=[:space:]]`, not `[= ]`: the unit line is one long single-quoted
    # argument, and a literal space inside an unquoted regex word is a syntax
    # error on bash 3.2 (the /bin/bash this repo's shell half must keep
    # working on) -- the test never ran at all. The class is the same two
    # characters, `=` and a space, spelled so the parser sees one word.
    if [[ ! "$exec_line" =~ --max-inflight[=[:space:]]([0-9]+) ]]; then
        fail "ExecStart does not pass --max-inflight: $exec_line"
    fi
    value="${BASH_REMATCH[1]}"
    if (( value < 1 )); then
        fail "--max-inflight $value is no ceiling at all"
    fi
    if (( value > 10 )); then
        fail "--max-inflight $value is above TorBox's ten concurrent slots"
    fi
}

# --- host I/O pressure gate -------------------------------------------------

# A fixture standing in for /proc/pressure/io. The real file is Linux-only, so
# nothing in this section may touch it -- the suite also runs on macOS.
#
# `some` is pinned at 0.00 and deliberately differs from `full`. Carrying the
# same number on both lines made the fixture blind to which one the gate reads,
# and `full` rather than `some` is the whole argument for this reading: `some`
# counts a single stalled task and runs high on a merely busy box, so a
# regression to it would stop the stack downloading on healthy hosts.
psi_fixture() {
    printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=%s avg60=0.00 avg300=0.00 total=0\n' \
        "$1" > "$WORK/pressure-io"
    echo "$WORK/pressure-io"
}

# Every test here needs a keyed .env, because the gate sits after the key guard.
keyed_env() {
    printf 'MEDIA_ROOT=%s/data\nTORBOX_API_KEY=testtorboxkey\n' "$WORK" > "$ENV"
}

@test "usenet-blackhole: a stalled host skips the pass before python runs" {
    keyed_env
    stub_python
    run env "PATH=$WORK/bin:$PATH" "PSI_IO_PATH=$(psi_fixture 95.00)" "$RUN" --apply
    assert_success
    assert_output --partial "pressure-gate"
    # The whole point of the gate: no work reaches python at all.
    [ ! -f "$WORK/argv" ]
}

@test "usenet-blackhole: a healthy host runs the pass" {
    keyed_env
    stub_python
    run env "PATH=$WORK/bin:$PATH" "PSI_IO_PATH=$(psi_fixture 1.90)" "$RUN" --apply
    assert_success
    refute_output --partial "pressure-gate"
    [ -f "$WORK/argv" ]
}

@test "usenet-blackhole: no PSI on the host means the gate fails open" {
    # macOS, and any kernel built without PSI, have no /proc/pressure/io. A gate
    # that blocked there would stop the stack downloading on every machine the
    # suite runs on, and would do it silently -- which is the failure mode this
    # repo keeps being bitten by.
    keyed_env
    stub_python
    run env "PATH=$WORK/bin:$PATH" "PSI_IO_PATH=$WORK/does-not-exist" "$RUN" --apply
    assert_success
    refute_output --partial "pressure-gate"
    [ -f "$WORK/argv" ]
}

@test "usenet-blackhole: the gate is the only thing that changes when pressure crosses the limit" {
    # Same run, same fixture, one hundredth apart. Without this, a gate that
    # always skipped -- or never did -- would pass the three tests above.
    keyed_env
    local pair value expect
    for pair in "19.99:run" "20.00:skip"; do
        value="${pair%%:*}"
        expect="${pair##*:}"
        stub_python
        rm -f "$WORK/argv"
        run env "PATH=$WORK/bin:$PATH" "PSI_IO_PATH=$(psi_fixture "$value")" "$RUN" --apply
        assert_success
        if [[ "$expect" == "run" ]]; then
            [ -f "$WORK/argv" ] || fail "avg10=$value should have run the pass"
        else
            [ ! -f "$WORK/argv" ] || fail "avg10=$value should have skipped the pass"
        fi
    done
}
