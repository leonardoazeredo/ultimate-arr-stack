#!/usr/bin/env bats
# scripts/indexer-guard.sh -- the flags and the order of the rotation.
#
# The decision logic lives in scripts/lib/indexer_guard.py and is covered by
# tests/python/test_indexer_guard.py. What is tested here is the shell half:
# the argv handling, the dry run, and two properties of a real rotation that
# are invisible until they are wrong --
#
#   * the exit IP is read out of the control API's `public_ip` field, and
#   * the rotation is recorded before the IP check and the Prowlarr restart.
#
# The script curls Prowlarr, talks to gluetun through `docker exec`, and
# restarts prowlarr with `docker compose`, so every test drives a throwaway
# copy of it with tests/helpers/stubs.bash in front of PATH. No test can reach
# a live container: the harness refuses the `restart` verb outright, and the
# rotation tests below use that refusal rather than working around it.
#
# shellcheck is deliberately not re-run here. tests/shellcheck.bats already
# checks every tracked shell script in the repo, and no per-script bats file
# in this repo carries its own copy.

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init

    STACK="$BATS_TEST_TMPDIR/stack"
    mkdir -p "$STACK/scripts/lib" "$STACK/logs"
    cp "$REPO_ROOT/scripts/indexer-guard.sh" "$STACK/scripts/"
    cp "$REPO_ROOT/scripts/lib/indexer_guard.py" "$STACK/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/env-file.sh" "$STACK/scripts/lib/"
    chmod +x "$STACK/scripts/indexer-guard.sh"
    SCRIPT="$STACK/scripts/indexer-guard.sh"
    ENV_FILE="$STACK/.env"
    STATE="$STACK/logs/indexer-guard-state.json"
    ROTATOR_FILE="$STACK/logs/vpn-rotation/last-rotation"

    printf 'PROWLARR_API_KEY=test-key\n' > "$ENV_FILE"

    # One status record in backoff whose own words are ban evidence, and the
    # indexer document that names it: the verdict every rotation test needs.
    STATUSES_JSON="$BATS_TEST_TMPDIR/statuses.json"
    INDEXERS_JSON="$BATS_TEST_TMPDIR/indexers.json"
    CURL_CALLS="$BATS_TEST_TMPDIR/curl-calls"
    cat > "$STATUSES_JSON" <<'JSON'
[{"id": 4, "indexerId": 7, "disabledTill": "2099-01-01T00:00:00Z", "message": "Cloudflare error 1006"}]
JSON
    printf '%s\n' '[{"id": 7, "name": "1337x"}]' > "$INDEXERS_JSON"
    export STATUSES_JSON INDEXERS_JSON CURL_CALLS

    # The two fetches, in the order the script makes them. The URL travels in
    # the curl config on stdin, not in the argv, so the call number is what
    # tells the documents apart.
    stub_curl '
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
n="$(cat "$CURL_CALLS" 2>/dev/null || echo 0)"
n=$((n + 1))
printf "%s" "$n" > "$CURL_CALLS"
if [ "$n" -eq 1 ]; then
  cat "$STATUSES_JSON"
else
  cat "$INDEXERS_JSON"
fi > "$out"
'

    # A docker that answers the control API. The `ip`-only answer is a
    # parameter so the fallback in gluetun_public_ip has a test of its own;
    # the default is the real shape, which uses public_ip.
    stub_docker 'case "$*" in
  *"/publicip/ip"*) printf "%s" "{\"public_ip\":\"203.0.113.9\"}" ;;
  *) printf "%s" "{\"status\":\"running\"}" ;;
esac'
}

# The same docker stub with an older answer that spells the address `ip`.
stub_docker_with_ip_key() {
    stub_docker 'case "$*" in
  *"/publicip/ip"*) printf "%s" "{\"ip\":\"198.51.100.4\"}" ;;
  *) printf "%s" "{\"status\":\"running\"}" ;;
esac'
}

# A docker whose control API never reports the tunnel running: the PUTs are
# accepted and the state never changes, which is the failure the verification
# read exists to catch.
stub_docker_never_running() {
    stub_docker 'case "$*" in
  *"/publicip/ip"*) printf "%s" "{\"public_ip\":\"203.0.113.9\"}" ;;
  *) printf "%s" "{\"status\":\"stopped\"}" ;;
esac'
}

# --- argument parsing ------------------------------------------------------

@test "indexer-guard: --help prints the header block and exits 0" {
    run "$SCRIPT" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "--dry-run"
}

@test "indexer-guard: --help stops at the comment block" {
    # The block ends ON its last comment line; one line further and --help
    # prints the SCRIPT_DIR assignment as if it were documentation.
    run "$SCRIPT" --help
    refute_output --partial "SCRIPT_DIR="
    refute_output --partial "NAS_STACK_DIR="
}

@test "indexer-guard: the help output ends on the header block's last line" {
    # The range is derived here from the file's own shape -- the first run of
    # comment lines after the shebang -- rather than from the awk that prints
    # it, so this can fail. A range that stops one line short still prints
    # plausible help text; the last line (and the count) is what says the whole
    # block arrived.
    local first last expected_last help_out
    first="$(awk 'NR > 1 && /^#/ { print NR; exit }' "$SCRIPT")"
    [ -n "$first" ] || fail "found no header comment block in $SCRIPT"
    last="$(awk -v f="$first" 'NR > f && !/^#/ { print NR - 1; exit }' "$SCRIPT")"
    [ -n "$last" ] || fail "the header comment block runs to the end of $SCRIPT"
    expected_last="$(sed -n "${last}p" "$SCRIPT" | sed 's/^# \{0,1\}//')"

    help_out="$BATS_TEST_TMPDIR/help.txt"
    "$SCRIPT" --help > "$help_out" || fail "--help exited non-zero"
    # Read from the file, not from $output: `run` strips the trailing newline,
    # so an empty last line is invisible there.
    [ "$(tail -1 "$help_out")" = "$expected_last" ]
    [ "$(wc -l < "$help_out" | tr -d ' ')" -eq "$((last - first + 1))" ]
}

@test "indexer-guard: an unknown flag is refused with exit 2" {
    run "$SCRIPT" --nonsense
    assert_failure 2
    assert_output --partial "unrecognised argument"
}

@test "indexer-guard: a trailing --state is refused, not silently defaulted" {
    # Falling through to the repo's own state file would make a typo'd flag
    # read as "use the default", and the default is the file the timer uses.
    run "$SCRIPT" --state
    assert_failure 2
    assert_output --partial "--state needs a path"
}

@test "indexer-guard: a zero --cooldown-hours is refused" {
    run "$SCRIPT" --cooldown-hours 0
    assert_failure 2
    assert_output --partial "must be greater than 0"
}

# --- the dry run -----------------------------------------------------------

@test "indexer-guard: --dry-run decides and reaches no docker call" {
    # The whole promise of the dry run: it is how an operator watches the
    # guard decide before a timer is allowed to act on it, so it must stop on
    # this side of every mutating call. Both assertions matter -- the stub log
    # says docker was not asked for anything, and the forbidden file says no
    # stopped/restarted container was reached by another route.
    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "rotate:"
    assert_output --partial "dry run: stopping before the rotation"
    assert_stub_not_called docker ""
    assert_nothing_forbidden
    [ ! -e "$STATE" ]
}

@test "indexer-guard: a hold reaches no docker call either" {
    # The normal path, and the one a timer takes almost every time. A guard
    # that acted on a timeout would rotate the VPN for nothing.
    printf '%s\n' '[{"id": 4, "indexerId": 7, "disabledTill": "2099-01-01T00:00:00Z", "message": "The operation has timed out"}]' > "$STATUSES_JSON"
    run "$SCRIPT" --state "$STATE"
    assert_success
    assert_output --partial "hold:"
    assert_stub_not_called docker ""
    assert_nothing_forbidden
}

# --- the rotation ----------------------------------------------------------

@test "indexer-guard: the exit IP is read from the control API's public_ip key" {
    # The regression: gluetun answers /publicip/ip with public_ip, region,
    # country and so on, and reading "ip" made both IP_BEFORE and IP_AFTER
    # "unknown" -- which destroyed the only evidence that a rotation changed
    # anything.
    run "$SCRIPT" --state "$STATE"
    assert_output --partial "exit IP before: 203.0.113.9"
    assert_output --partial "exit IP after: 203.0.113.9"
    refute_output --partial "exit IP before: unknown"
}

@test "indexer-guard: an older ip key is still read as a fallback" {
    stub_docker_with_ip_key
    run "$SCRIPT" --state "$STATE"
    assert_output --partial "exit IP before: 198.51.100.4"
    refute_output --partial "exit IP before: unknown"
}

@test "indexer-guard: the rotation is recorded even when the tunnel never comes back" {
    # The fail-safe, and the reason the record moved out of the end of the
    # pass: the VPN has already been cycled when the verification read fails,
    # and the script exits 1 from there. If the record only happened at the
    # end, this pass would leave no cooldown behind -- and the timer would
    # rotate again fifteen minutes later, which is the loop the cooldown
    # exists to prevent.
    stub_docker_never_running
    run "$SCRIPT" --state "$STATE"
    assert_failure
    assert_output --partial "FATAL: gluetun still does not report the VPN as running"
    [ -f "$STATE" ]

    run python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["rotations"])' "$STATE"
    assert_success
    assert_output "1"
}

@test "indexer-guard: the rotation is recorded before the Prowlarr restart" {
    # The stub harness refuses `docker compose ... restart`, which is the only
    # mutating call the script makes that it cannot let through. The pass ends
    # non-zero, and the two log lines are compared by position rather than by
    # presence: the record has to come first, or a restart that hangs or dies
    # leaves a cycled VPN with nothing on file.
    run "$SCRIPT" --state "$STATE"
    assert_failure
    assert_forbidden "restart"
    assert_output --partial "recorded the rotation"
    assert_output --partial "restarting prowlarr failed"
    [ -f "$STATE" ]

    local recorded restart
    recorded="$(printf '%s\n' "$output" | grep -n "recorded the rotation" | head -1 | cut -d: -f1)"
    restart="$(printf '%s\n' "$output" | grep -n "restarting prowlarr failed" | head -1 | cut -d: -f1)"
    [ -n "$recorded" ]
    [ -n "$restart" ]
    [ "$recorded" -lt "$restart" ]
}

@test "indexer-guard: the rotation the wrapper writes is the one the module reads" {
    # The exit statuses are not the point here; the round trip is. What
    # --record-rotation wrote has to be a state the decision honours, or the
    # cooldown covers nothing on the next pass.
    run "$SCRIPT" --state "$STATE"
    assert_failure
    [ -f "$STATE" ]

    run python3 "$STACK/scripts/lib/indexer_guard.py" --state "$STATE" \
        --statuses "$STATUSES_JSON" --indexers "$INDEXERS_JSON"
    assert_success
    assert_output --partial "hold:"
    assert_output --partial "cooldown"
}

# --- the shared rotation timestamp ------------------------------------------
#
# The other half of the coordination: logs/vpn-rotation/last-rotation, the one
# line gluetun-rotator reads and writes too. What the module does with the
# value is covered in tests/python/test_indexer_guard.py; what is covered here
# is the shell half -- that it reads the file, passes what it found, and writes
# it at the right moment and only then.

@test "indexer-guard: the shared file's timestamp reaches the decision" {
    # A rotation ten minutes ago, which is inside the module's default window:
    # the guard holds and the reason says why, which it can only do if the
    # value in the file arrived.
    mkdir -p "$(dirname "$ROTATOR_FILE")"
    printf '%s\n' "$(( $(date +%s) - 600 ))" > "$ROTATOR_FILE"

    run "$SCRIPT" --state "$STATE"
    assert_success
    assert_output --partial "hold:"
    assert_output --partial "re-probe"
    assert_stub_not_called docker ""
    assert_nothing_forbidden
}

@test "indexer-guard: a timestamp the rotator is about to act on holds too" {
    # The other hold: the rotator's own restart is ten minutes away, and a
    # rotation now would cycle the tunnel twice inside those ten minutes.
    mkdir -p "$(dirname "$ROTATOR_FILE")"
    printf '%s\n' "$(( $(date +%s) - (21600 - 600) ))" > "$ROTATOR_FILE"

    run "$SCRIPT" --state "$STATE"
    assert_success
    assert_output --partial "hold:"
    assert_output --partial "restarts gluetun in"
    assert_nothing_forbidden
}

@test "indexer-guard: the interval comes from GLUETUN_ROTATE_INTERVAL_SECONDS" {
    # The same ten-minutes-to-restart timestamp under a three-hour interval.
    # Under the module's six-hour default it would be more than three hours
    # from a restart and the guard would rotate, so the hold is the .env value
    # arriving rather than the default doing the work.
    printf 'GLUETUN_ROTATE_INTERVAL_SECONDS=10800\n' >> "$ENV_FILE"
    mkdir -p "$(dirname "$ROTATOR_FILE")"
    printf '%s\n' "$(( $(date +%s) - (10800 - 600) ))" > "$ROTATOR_FILE"

    run "$SCRIPT" --state "$STATE"
    assert_success
    assert_output --partial "hold:"
    assert_output --partial "restarts gluetun in"
    assert_nothing_forbidden
}

@test "indexer-guard: every all-zero interval spelling falls back to the default" {
    # `00` is the same interval as `0` spelled differently, and an exact `0)`
    # arm passed it through to argparse, whose refusal stopped the whole pass
    # instead of falling back. The hold is what proves the fallback: this
    # timestamp is ten minutes short of the rotator's restart under the
    # module's six-hour default, and a value read as an interval would leave
    # no rotator schedule for the guard to hold on.
    local value
    for value in 0 00 000; do
        printf 'PROWLARR_API_KEY=test-key\nGLUETUN_ROTATE_INTERVAL_SECONDS=%s\n' "$value" > "$ENV_FILE"
        mkdir -p "$(dirname "$ROTATOR_FILE")"
        printf '%s\n' "$(( $(date +%s) - (21600 - 600) ))" > "$ROTATOR_FILE"
        # The curl stub counts calls to tell the two fetches apart, so the
        # counter starts over for each pass rather than serving the indexer
        # document in place of the status one.
        rm -f "$CURL_CALLS"

        run "$SCRIPT" --state "$STATE"
        assert_success
        assert_output --partial "GLUETUN_ROTATE_INTERVAL_SECONDS='$value' in $ENV_FILE is not an interval"
        assert_output --partial "hold:"
        assert_output --partial "restarts gluetun in"
        assert_nothing_forbidden
    done
}

@test "indexer-guard: a missing shared file passes nothing to the module" {
    # The normal state of a stack whose rotator has not written the file yet:
    # the decision is the one the guard made before there was anything to
    # coordinate with.
    [ ! -e "$ROTATOR_FILE" ]

    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "rotate:"
    refute_output --partial "re-probe"
    refute_output --partial "restarts gluetun in"
}

@test "indexer-guard: a garbage shared file passes nothing to the module" {
    # If this reached argparse, the module would exit 2 and the pass would stop
    # rather than decide; the guard rotating is the proof that it did not.
    mkdir -p "$(dirname "$ROTATOR_FILE")"
    printf 'not-a-number\n' > "$ROTATOR_FILE"

    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "rotate:"
    refute_output --partial "re-probe"
}

@test "indexer-guard: an empty shared file passes nothing to the module" {
    mkdir -p "$(dirname "$ROTATOR_FILE")"
    : > "$ROTATOR_FILE"

    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "rotate:"
}

@test "indexer-guard: a real rotation writes the shared timestamp" {
    # It has to be written on the rotation path, next to the state file's own
    # record, so the rotator's interval starts from this moment instead of the
    # one it last knew about. The value is checked against the clock this test
    # saw rather than merely "a number": a file written from a stale variable
    # would be the same bug in a quieter form.
    local start end written
    start="$(date +%s)"
    run "$SCRIPT" --state "$STATE"
    end="$(date +%s)"

    assert_failure  # the stubbed prowlarr restart is refused; the rotation itself happened
    assert_output --partial "recorded the rotation in $ROTATOR_FILE"
    [ -f "$ROTATOR_FILE" ]

    written="$(cat "$ROTATOR_FILE")"
    case "$written" in
        ''|*[!0-9]*) fail "the shared timestamp is not an integer: '$written'" ;;
    esac
    [ "$written" -ge "$start" ]
    [ "$written" -le "$end" ]

    # Atomic means no temporary left beside it: a reader that finds one has
    # found this script's leftovers, not a timestamp.
    run bash -c "ls '$STACK/logs/vpn-rotation/'"
    assert_output "last-rotation"
}

@test "indexer-guard: --dry-run writes no shared timestamp" {
    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "rotate:"
    [ ! -e "$ROTATOR_FILE" ]
}

@test "indexer-guard: --dry-run leaves an existing shared timestamp alone" {
    mkdir -p "$(dirname "$ROTATOR_FILE")"
    printf '1700000000\n' > "$ROTATOR_FILE"

    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success

    run cat "$ROTATOR_FILE"
    assert_output "1700000000"
}
