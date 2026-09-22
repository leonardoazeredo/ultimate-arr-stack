#!/usr/bin/env bats
# scripts/usenet-drain-walk.sh -- the walk's bounds, its watchdog, and the three
# things it promises never to touch.
#
# The pass this drives is scripts/usenet-blackhole.sh and is covered by
# tests/usenet-blackhole.bats and tests/python/test_usenet_blackhole.py. What is
# tested here is the loop around it: that a pass which stops changing anything
# is killed rather than waited on, that the walk then attempts a DIFFERENT pass
# instead of repeating the same one, that it stops for the documented reasons,
# and that it refuses to run alongside the timer or alongside itself.
#
# Every test stubs the pass. Two reasons, and the second is the load-bearing one:
# a real pass talks to TorBox with the account's own key, and
# scripts/usenet-blackhole.sh is an operational script whose whole purpose is
# moving bytes onto a pool that this suite's own docs record going into I/O
# starvation. Nothing here may reach it, so the stub is not a convenience.
#
# The stub is reached by PATH-of-the-sibling: the driver resolves its pass as
# "$SCRIPT_DIR/usenet-blackhole.sh", so copying the driver into a throwaway
# scripts/ directory and writing a fake next to it intercepts it with no seam in
# the shipped script. tests/usenet-blackhole.bats copies the same way.

setup() {
    load helpers/setup
    SCRIPT="$REPO_ROOT/scripts/usenet-drain-walk.sh"
    WORK="$BATS_TEST_TMPDIR/stack"
    mkdir -p "$WORK/scripts" "$WORK/logs" "$WORK/bin" \
             "$WORK/data/usenet/blackhole/nzb" \
             "$WORK/data/usenet/blackhole/complete" \
             "$WORK/data/usenet/blackhole/staging"
    cp "$SCRIPT" "$WORK/scripts/usenet-drain-walk.sh"
    cp -r "$REPO_ROOT/scripts/lib" "$WORK/scripts/lib"
    chmod +x "$WORK/scripts/usenet-drain-walk.sh"
    printf 'MEDIA_ROOT=%s/data\nTORBOX_API_KEY=test-key-not-used\n' "$WORK" > "$WORK/.env"
    RUN="$WORK/scripts/usenet-drain-walk.sh"

    NZB="$WORK/data/usenet/blackhole/nzb"
    WATCH="$WORK/data/usenet/blackhole/complete"
    STAGING="$WORK/data/usenet/blackhole/staging"
    STATE="$WORK/logs/usenet-blackhole-state.json"
    WALK_LOG="$WORK/logs/usenet-drain-walk.log"
    LOCK="$WORK/logs/usenet-drain-walk.lock"
    PASS_CALLS="$WORK/pass-calls"

    # The driver reads its walk-level numbers from the status script, so every
    # test needs one that answers. A fixed body is enough: the numbers matter to
    # `advanced`, and each test controls what they say through the outbox.
    cat > "$WORK/scripts/usenet-blackhole-status.sh" <<'EOS'
#!/bin/bash
echo '{"totals": {"jobs": 22, "complete": 6, "stalled": 2, "failed": 0}}'
EOS
    chmod +x "$WORK/scripts/usenet-blackhole-status.sh"

    # Deterministic timer state for every test -- CI is ubuntu-latest and HAS a
    # systemctl, and this suite must not depend on what the host's user manager
    # happens to say about a timer that does not exist there.
    cat > "$WORK/bin/systemctl" <<'EOS'
#!/bin/bash
echo "systemctl $*" >> "${STUB_TIMER_LOG:-/dev/null}"
echo "inactive"
EOS
    chmod +x "$WORK/bin/systemctl"
    export PATH="$WORK/bin:$PATH"
    export STUB_TIMER_LOG="$WORK/systemctl-calls"
    export STUB_PASS_CALLS="$PASS_CALLS"
    export STUB_WATCH="$WATCH"
    export STUB_NZB="$NZB"

    # The mark is the outbox depth at which the producers resume, and it is 50
    # in production. Seeding 50 NZBs per test to cross it would make every test
    # about counting, so it is pinned low here instead -- scripts/lib/
    # queue_high_water.sh reads it from the environment, and the same override
    # is what a host with a different ceiling would use.
    export QUEUE_HIGH_WATER=2
}

# Whatever a stub left behind. Normally nothing: the walk's group kill takes
# the pass and everything under it. Under a mutation the survivor is exactly
# what the test is looking for, and it is killed here so that the failing
# assertion is what the run reports -- a suite that hangs on a process
# outliving its test scores that mutation against a timeout instead of against
# the assertion, which is a weaker oracle than it looks.
teardown() {
    if [[ -n "${STUB_DESCENDANTS:-}" && -f "${STUB_DESCENDANTS}" ]]; then
        while read -r d; do
            if [[ -n "$d" ]]; then
                kill -KILL "$d" 2>/dev/null || true
            fi
        done < "$STUB_DESCENDANTS"
    fi
}

# NZBs in the outbox: the queue the walk exists to shorten. They only have to be
# files with the right extension -- nothing in this file parses one, and the
# pass is stubbed.
seed_outbox() {
    local n="${1:-3}" i
    for ((i = 1; i <= n; i++)); do
        printf 'placeholder\n' > "$NZB/Sample.Release.$i.nzb"
    done
}

# A pass that does nothing at all and never returns. The watchdog is the only
# thing that can end it.
write_stuck_pass() {
    cat > "$WORK/scripts/usenet-blackhole.sh" <<'EOS'
#!/bin/bash
echo "stuck pass $$ invoked: $*" >> "$STUB_PASS_CALLS"
sleep 300
EOS
    chmod +x "$WORK/scripts/usenet-blackhole.sh"
}

# A pass that finishes, and that IS progress: it delivers one release, which a
# pass signals by discarding its NZB from the outbox.
write_productive_pass() {
    cat > "$WORK/scripts/usenet-blackhole.sh" <<'EOS'
#!/bin/bash
echo "productive pass $$ invoked: $*" >> "$STUB_PASS_CALLS"
rm -f "$(ls -1 "$STUB_NZB"/*.nzb 2>/dev/null | head -n 1)" 2>/dev/null || true
echo "  submitted 0, fetched 1, outstanding 4 (1 owed local I/O, 3 still at TorBox)"
EOS
    chmod +x "$WORK/scripts/usenet-blackhole.sh"
}

# A pass the pressure gate refuses: it prints the gate's own line, touches
# nothing, and exits 0 -- exactly what scripts/usenet-blackhole.sh does when it
# stands a pass down. The walk detects this by grepping the pass's captured
# output, which is why the line has to be the real one.
write_refused_pass() {
    cat > "$WORK/scripts/usenet-blackhole.sh" <<'EOS'
#!/bin/bash
echo "refused pass $$ invoked: $*" >> "$STUB_PASS_CALLS"
echo "[pressure-gate] host I/O is stalled (io full avg10=88.00%, limit 20%); skipping this pass"
EOS
    chmod +x "$WORK/scripts/usenet-blackhole.sh"
}

@test "usenet-drain-walk: dry run is the default and reaches no pass" {
    seed_outbox 3
    write_stuck_pass
    run "$RUN"
    assert_success
    assert_output --partial "DRY RUN"
    assert_output --partial "Would run, repeatedly"
    [ ! -f "$PASS_CALLS" ]
}

@test "usenet-drain-walk: an empty outbox is left alone" {
    write_stuck_pass
    run "$RUN" --apply
    assert_success
    assert_output --partial "already below the mark"
    [ ! -f "$PASS_CALLS" ]
}

@test "usenet-drain-walk: a pass whose fingerprint never changes is killed and the walk attempts another" {
    seed_outbox 3
    write_stuck_pass
    run "$RUN" --apply --poll 1 --pass-stall 2 --kill-grace 2 \
        --max-passes 3 --max-barren 2 --cooldown 1
    # 3, not 1: the walk ran and gave up, which is not a refusal (1) and not a
    # cleared queue (0).
    assert_failure 3
    # Two invocations, not one: the second is the walk moving on rather than
    # retrying the pass it just killed.
    [ -f "$PASS_CALLS" ]
    [ "$(wc -l < "$PASS_CALLS" | tr -d ' ')" -eq 2 ]
    assert_output --partial "no change in the fingerprint"
    assert_output --partial "stopping this pass and moving to the next"
    assert_output --partial "no progress"
}

@test "usenet-drain-walk: a stuck pass does not survive the watchdog" {
    seed_outbox 3
    write_stuck_pass
    run "$RUN" --apply --poll 1 --pass-stall 2 --kill-grace 2 \
        --max-passes 1 --max-barren 1 --cooldown 1
    # The stub sleeps 300s. Reaching the end of the run at all is the assertion:
    # if the process group survived SIGTERM the wait below would hang here.
    assert_failure 3
    assert_output --partial "killed by the watchdog"
}

@test "usenet-drain-walk: killing a stuck pass takes the work under it too" {
    seed_outbox 3
    # The grandchild stands in for the curl inside a fetch, and it is in the
    # pass's process group -- so the group SIGTERM reaches it. Signalling only
    # the shell in front leaves it running, and a walk that leaves one behind is
    # two drains with one of them unaccounted for.
    # Both descendants point their stdio at /dev/null. Not decoration: an
    # orphan that inherits this process's output descriptor holds it open, so a
    # mutation that leaves one behind would hang whatever is reading the suite's
    # output and be scored against a timeout instead of against the marker this
    # test looks for.
    cat > "$WORK/scripts/usenet-blackhole.sh" <<'EOS'
#!/bin/bash
echo "stuck pass $$ invoked: $*" >> "$STUB_PASS_CALLS"
( sleep 4; : > "$STUB_SURVIVOR" ) >/dev/null 2>&1 &
echo "$!" >> "$STUB_DESCENDANTS"
sleep 300 >/dev/null 2>&1 &
echo "$!" >> "$STUB_DESCENDANTS"
wait
EOS
    chmod +x "$WORK/scripts/usenet-blackhole.sh"
    export STUB_SURVIVOR="$WORK/survivor-marker"
    export STUB_DESCENDANTS="$WORK/stub-descendants"

    run "$RUN" --apply --poll 1 --pass-stall 2 --kill-grace 2 \
        --max-passes 1 --max-barren 1 --cooldown 1
    assert_failure 3
    # Longer than the grandchild's own delay, so a survivor has had its chance
    # to leave the marker. Absence is the assertion.
    sleep 5
    [ ! -f "$WORK/survivor-marker" ]
}

@test "usenet-drain-walk: a pass that keeps changing something is not killed" {
    seed_outbox 3
    # Six seconds of work against a three-second stall window, moving the watch
    # folder on every tick -- the shape of a healthy fetch, which is what the
    # watchdog must not interrupt.
    cat > "$WORK/scripts/usenet-blackhole.sh" <<'EOS'
#!/bin/bash
echo "working pass $$ invoked: $*" >> "$STUB_PASS_CALLS"
for i in 1 2 3 4 5 6; do
    : > "$STUB_WATCH/release-$i"
    sleep 1
done
echo "  submitted 0, fetched 0, outstanding 22 (6 owed local I/O, 16 still at TorBox)"
EOS
    chmod +x "$WORK/scripts/usenet-blackhole.sh"
    run "$RUN" --apply --poll 1 --pass-stall 3 --kill-grace 2 \
        --max-passes 1 --max-barren 1 --cooldown 1
    # It stops on "no progress" -- the pass delivered nothing -- but the point
    # here is the two refutations below.
    assert_failure 3
    refute_output --partial "no change in the fingerprint"
    refute_output --partial "killed by the watchdog"
}

@test "usenet-drain-walk: progress resets the barren streak and the budget ends the walk" {
    seed_outbox 12
    write_productive_pass
    run "$RUN" --apply --poll 1 --pass-stall 60 --max-passes 3 --max-barren 2 --cooldown 1
    assert_failure 3
    assert_output --partial "pass budget reached (3)"
    refute_output --partial "made no progress"
    # Three passes, each having cleared one NZB.
    [ "$(wc -l < "$PASS_CALLS" | tr -d ' ')" -eq 3 ]
}

@test "usenet-drain-walk: a pass the pressure gate refused is not a barren pass" {
    seed_outbox 12
    write_refused_pass
    # --max-barren 1 is the assertion. A refused pass never ran, so it is not
    # evidence about the drain, and counting it as barren stopped the walk after
    # one attempt with "1 passes in a row made no progress" -- the wrong
    # sentence about the right observation, because the host was busy and the
    # queue was not stuck. Both attempts must happen for this to pass.
    run "$RUN" --apply --poll 1 --pass-stall 60 --max-passes 2 --max-barren 1 \
        --skip-cooldown 1 --cooldown 1
    [ "$(wc -l < "$PASS_CALLS" | tr -d ' ')" -eq 2 ]
    refute_output --partial "made no progress"
    assert_output --partial "the pressure gate refused"
}

@test "usenet-drain-walk: only the real gate's refusal counts as one" {
    # Drives the REAL scripts/usenet-blackhole.sh, because the walk decides this
    # by matching a phrase that script prints -- a phrase a stub hardcodes and
    # therefore cannot keep honest. Two of the gate's four messages mean the pass
    # RAN (it could not read its reading and went unprotected) and must count as
    # evidence about the drain; one means it was refused and must not.
    seed_outbox 12
    cp "$REPO_ROOT/scripts/usenet-blackhole.sh" "$WORK/scripts/usenet-blackhole.sh"
    chmod +x "$WORK/scripts/usenet-blackhole.sh"

    # The pass's second half, reached on the unprotected path. A no-op, because
    # the real thing would call TorBox with the placeholder key in this fixture's
    # .env. The walk reads its own metrics through python3 too, so this also
    # degrades those to `?`, which `advanced` already tolerates.
    mkdir -p "$WORK/pyshim"
    printf '#!/bin/bash\nexit 0\n' > "$WORK/pyshim/python3"
    chmod +x "$WORK/pyshim/python3"

    # 1. A stalled host: the gate's fourth message, exit 0, no pass runs. This
    #    must be a refusal, so a barren bound of 1 cannot stop the walk.
    printf 'some avg10=90.00 total=0\nfull avg10=90.00 total=0\n' > "$WORK/psi-stalled"
    run env "PATH=$WORK/pyshim:$PATH" PSI_IO_PATH="$WORK/psi-stalled" PSI_IO_LIMIT=20 \
        "$RUN" --apply --poll 1 --pass-stall 60 --max-passes 2 --max-barren 1 \
        --skip-cooldown 1 --cooldown 1
    assert_output --partial "refused by the I/O pressure gate"
    refute_output --partial "made no progress"

    # 2. A gate that cannot read its own input says so and the pass RUNS. That
    #    pass is evidence about the drain, so it has to count as barren.
    run env "PATH=$WORK/pyshim:$PATH" PSI_IO_PATH="$WORK/does-not-exist" PSI_IO_LIMIT=20 \
        "$RUN" --apply --poll 1 --pass-stall 60 --max-passes 2 --max-barren 1 \
        --skip-cooldown 1 --cooldown 1
    refute_output --partial "refused by the I/O pressure gate"
    assert_output --partial "made no progress"
}

@test "usenet-drain-walk: clearing the mark ends the walk" {
    seed_outbox 3
    write_productive_pass
    run "$RUN" --apply --poll 1 --pass-stall 60 --max-passes 5 --max-barren 2 --cooldown 1
    assert_success
    assert_output --partial "the outbox cleared the mark"
    [ "$(wc -l < "$PASS_CALLS" | tr -d ' ')" -eq 2 ]
}

@test "usenet-drain-walk: refuses to run alongside the armed timer, and --force is the way past" {
    seed_outbox 3
    write_stuck_pass
    cat > "$WORK/bin/systemctl" <<'EOS'
#!/bin/bash
echo "systemctl $*" >> "${STUB_TIMER_LOG:-/dev/null}"
echo "active"
EOS
    chmod +x "$WORK/bin/systemctl"

    run "$RUN" --apply --max-passes 1
    assert_failure 1
    assert_output --partial "usenet-blackhole.timer is ACTIVE"
    [ ! -f "$PASS_CALLS" ]

    run "$RUN" --apply --force --poll 1 --pass-stall 2 --kill-grace 2 \
        --max-passes 1 --max-barren 1 --cooldown 1
    assert_output --partial "two drains are about to run"
    [ -f "$PASS_CALLS" ]
}

@test "usenet-drain-walk: never arms, disarms or stops the timer it checks" {
    seed_outbox 3
    write_stuck_pass
    run "$RUN" --apply --force --poll 1 --pass-stall 2 --kill-grace 2 \
        --max-passes 1 --max-barren 1 --cooldown 1
    [ -f "$STUB_TIMER_LOG" ]
    # Read only: the one call it is allowed to make is the question.
    run grep -c "systemctl --user is-active usenet-blackhole.timer" "$STUB_TIMER_LOG"
    assert_output "1"
    run grep -E "enable|disable|start|stop|mask|unmask" "$STUB_TIMER_LOG"
    assert_failure
}

@test "usenet-drain-walk: a second walk refuses to start, and a stale lock does not" {
    seed_outbox 3
    write_stuck_pass

    mkdir -p "$LOCK"
    printf '%s' "$$" > "$LOCK/pid"
    run "$RUN" --apply --max-passes 1
    assert_failure 1
    assert_output --partial "another drain walk is already running"
    [ ! -f "$PASS_CALLS" ]

    # A lock whose owner is gone is replaced rather than obeyed: a walk killed
    # by a reboot must not need a human to remove a directory.
    printf '999999' > "$LOCK/pid"
    run "$RUN" --apply --poll 1 --pass-stall 2 --kill-grace 2 \
        --max-passes 1 --max-barren 1 --cooldown 1
    assert_output --partial "replacing a stale walk lock"
    [ ! -d "$LOCK" ]
}

@test "usenet-drain-walk: the paths it watches are the paths the pass writes" {
    # Not a style check: the driver decides whether a pass is moving by looking
    # at the watch and staging folders the pass fills, and asks the status script
    # about the state file the pass writes. A driver watching a different path
    # than the pass writes reads every running pass as stalled.
    seed_outbox 3
    cp "$REPO_ROOT/scripts/usenet-blackhole.sh" "$WORK/scripts/usenet-blackhole.sh"
    chmod +x "$WORK/scripts/usenet-blackhole.sh"

    run "$WORK/scripts/usenet-blackhole.sh"
    assert_success
    local pass_nzb pass_watch pass_staging
    pass_nzb="$(printf '%s\n' "$output" | awk -F'  NZB folder:   ' 'NF > 1 {print $2}')"
    pass_watch="$(printf '%s\n' "$output" | awk -F'  watch folder: ' 'NF > 1 {print $2}')"
    pass_staging="$(printf '%s\n' "$output" | awk -F'  staging:      ' 'NF > 1 {print $2}')"
    [ "$pass_nzb" = "$NZB" ]
    [ "$pass_watch" = "$WATCH" ]
    [ "$pass_staging" = "$STAGING" ]

    run "$RUN"
    assert_success
    assert_output --partial "  NZB folder:   $NZB"
    assert_output --partial "  watch folder: $WATCH"
    assert_output --partial "  staging:      $STAGING"
    assert_output --partial "  state:        $STATE"
}

@test "usenet-drain-walk: refuses a walk it cannot bound" {
    run "$RUN" --poll 0
    assert_failure 2
    assert_output --partial "--poll must be at least 1"

    run "$RUN" --pass-stall 5 --poll 10
    assert_failure 2
    assert_output --partial "must be at least --poll"

    run "$RUN" --max-passes
    assert_failure 2
    assert_output --partial "--max-passes needs a value"

    run "$RUN" --max-passes 0
    assert_failure 2
    assert_output --partial "--max-passes must be at least 1"

    run "$RUN" --max-passes banana
    assert_failure 2
    assert_output --partial "must be a whole number"
}

@test "usenet-drain-walk: a leading zero is read as decimal, not octal" {
    seed_outbox 12
    write_productive_pass
    # Bash reads a leading zero as octal, so `$((08))` fails outright with
    # "value too great for base" -- the banner is where the parsed value is
    # visible without running the walk to its budget.
    run "$RUN" --apply --poll 1 --pass-stall 60 --max-passes 08 --max-barren 2 --cooldown 1
    assert_output --partial "up to 8 pass(es)"
}

@test "usenet-drain-walk: --help prints the usage block and stops at it" {
    run "$RUN" --help
    assert_success
    assert_output --partial "Walk the usenet outbox down"
    assert_output --partial "--apply is required to run a pass"
    # The range in the script has to stop ON the last header line; one line
    # further prints the SCRIPT_DIR assignment below it.
    refute_output --partial "SCRIPT_DIR="
    refute_output --partial "set -euo pipefail"
}

@test "usenet-drain-walk: --help prints the whole header, not a prefix of it" {
    run "$RUN" --help
    assert_success
    # The LAST lines of the header, not the middle. This is what the older test
    # above cannot see: every string it names sits in the first half of the
    # block, so a range three lines short of the end passed for as long as it
    # existed. It shipped that way.
    assert_output --partial "Prerequisites: python3"
    assert_output --partial "Generated with LLM assistance and human-reviewed"
    refute_output --partial "SCRIPT_DIR="
}

@test "usenet-drain-walk: the help range ends on the last non-blank header line" {
    # Derived from the file rather than written down. The range moves whenever
    # the header grows, and a hardcoded 3,86 would need editing in the same
    # commit as every line of documentation above it -- which is exactly the
    # edit that was missed.
    local last header_line
    last="$(awk 'NR >= 3 && /^# ./ { n = NR } /^SCRIPT_DIR=/ { print n; exit }' \
                "$REPO_ROOT/scripts/usenet-drain-walk.sh")"
    [ -n "$last" ] || fail "could not find the header/script boundary in scripts/usenet-drain-walk.sh"
    header_line="$(sed -n "${last}p" "$REPO_ROOT/scripts/usenet-drain-walk.sh" | sed 's/^# \{0,1\}//')"
    [ -n "$header_line" ] || fail "the last header line is empty; the awk pattern is wrong"
    run "$RUN" --help
    assert_output --partial "$header_line"
}

@test "usenet-drain-walk: it is executable" {
    [ -x "$REPO_ROOT/scripts/usenet-drain-walk.sh" ]
}
