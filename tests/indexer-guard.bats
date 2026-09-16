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
    # The fixed-range sed that prints this stops ON the last comment line; one
    # line further and --help prints the SCRIPT_DIR assignment as if it were
    # documentation. Anything that adds a line to the header has to move the
    # range with it, and this is what says so.
    run "$SCRIPT" --help
    refute_output --partial "SCRIPT_DIR="
    refute_output --partial "NAS_STACK_DIR="
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
