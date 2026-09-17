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

    printf 'PROWLARR_API_KEY=test-key\nSONARR_API_KEY=test-sonarr-key\n' > "$ENV_FILE"

    # One status record in backoff whose own words are ban evidence, and the
    # indexer document that names it: the verdict every rotation test needs.
    STATUSES_JSON="$BATS_TEST_TMPDIR/statuses.json"
    INDEXERS_JSON="$BATS_TEST_TMPDIR/indexers.json"
    # Sonarr's two documents, for the demand gate, and the marker that makes
    # the stub's Sonarr calls fail. The default pair is demand for 1337x; the
    # helpers below rewrite it.
    SONARR_MISSING_JSON="$BATS_TEST_TMPDIR/sonarr-missing.json"
    SONARR_HISTORY_JSON="$BATS_TEST_TMPDIR/sonarr-history.json"
    SONARR_DOWN="$BATS_TEST_TMPDIR/sonarr-down"
    SONARR_HISTORY_PAGE2_DOWN="$BATS_TEST_TMPDIR/sonarr-history-page2-down"
    # Every URL curl was asked for, one per line. The URL travels in the curl
    # config on stdin, so it is not in any argv and STUB_LOG cannot see it.
    CURL_URLS="$BATS_TEST_TMPDIR/curl-urls"
    cat > "$STATUSES_JSON" <<'JSON'
[{"id": 4, "indexerId": 7, "disabledTill": "2099-01-01T00:00:00Z", "message": "Cloudflare error 1006"}]
JSON
    printf '%s\n' '[{"id": 7, "name": "1337x"}]' > "$INDEXERS_JSON"
    sonarr_demand_documents "1337x (Prowlarr)"
    : > "$CURL_URLS"
    export STATUSES_JSON INDEXERS_JSON SONARR_MISSING_JSON SONARR_HISTORY_JSON \
        SONARR_DOWN SONARR_HISTORY_PAGE2_DOWN CURL_URLS

    # The Prowlarr and Sonarr fetches, dispatched by the URL in the curl config
    # on stdin -- not by call order, which could not tell a Sonarr page from
    # Prowlarr's own indexer document. Only the URL is written to $CURL_URLS:
    # the config also carries the API key, and one test asserts the key reaches
    # no argv and no log line.
    #
    # The history page 2 arm is first: a document whose envelope needs a second
    # page, and a marker that makes exactly that one fail -- the partial-walk
    # case, which has to reach the module as --demand-error rather than as the
    # page one it did fetch.
    stub_curl '
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
url="$(sed -n "s/^url = \"\(.*\)\"$/\1/p")"
printf "%s\n" "$url" >> "$CURL_URLS"
case "$url" in
  *8989/api/v3/wanted/missing*)
    [ -f "$SONARR_DOWN" ] && exit 7
    cat "$SONARR_MISSING_JSON" > "$out" ;;
  *8989/api/v3/history*page=2*)
    if [ -f "$SONARR_DOWN" ] || [ -f "$SONARR_HISTORY_PAGE2_DOWN" ]; then exit 7; fi
    cat "$SONARR_HISTORY_JSON" > "$out" ;;
  *8989/api/v3/history*)
    [ -f "$SONARR_DOWN" ] && exit 7
    cat "$SONARR_HISTORY_JSON" > "$out" ;;
  *9696/api/v1/indexerstatus*) cat "$STATUSES_JSON" > "$out" ;;
  *9696/api/v1/indexer*) cat "$INDEXERS_JSON" > "$out" ;;
  *) exit 22 ;;
esac
'

    # python3 is stubbed only so its argv can be read: which demand flags
    # reached the module is the one thing the decision document cannot show,
    # because --demand-error and a partial --demand-history render the same way
    # when the error wins. The stub logs the argv and execs the real
    # interpreter, so the module still runs and every other test is unaffected.
    REAL_PYTHON3="$(command -v python3)"
    export REAL_PYTHON3
    stub_tool python3 'exec "$REAL_PYTHON3" "$@"'

    # A docker that answers the control API. The `ip`-only answer is a
    # parameter so the fallback in gluetun_public_ip has a test of its own;
    # the default is the real shape, which uses public_ip.
    stub_docker 'case "$*" in
  *"/publicip/ip"*) printf "%s" "{\"public_ip\":\"203.0.113.9\"}" ;;
  *) printf "%s" "{\"status\":\"running\"}" ;;
esac'
}

# sonarr_demand_documents <history indexer name>: Sonarr's two pages.
#
# One monitored episode missing from series 12, and one grabbed history record
# for that same series from <name>. The name is written exactly as Sonarr
# writes it -- "1337x (Prowlarr)", not Prowlarr's "1337x" -- so the default
# pair exercises the suffix stripping rather than sidestepping it.
sonarr_demand_documents() {
    cat > "$SONARR_MISSING_JSON" <<'JSON'
{"page": 1, "pageSize": 1000, "totalRecords": 1, "records": [{"seriesId": 12, "monitored": true}]}
JSON
    printf '{"page": 1, "pageSize": 1000, "totalRecords": 1, "records": [{"seriesId": 12, "eventType": "grabbed", "data": {"indexer": "%s"}}]}\n' \
        "$1" > "$SONARR_HISTORY_JSON"
}

# sonarr_no_demand: Sonarr's two pages with nothing in common.
#
# Series 12 is missing an episode and series 99 was grabbed from 1337x, so the
# join finds nothing: the series that needs something was never supplied by the
# banned indexer. This is the shape the gate exists for.
sonarr_no_demand() {
    cat > "$SONARR_MISSING_JSON" <<'JSON'
{"page": 1, "pageSize": 1000, "totalRecords": 1, "records": [{"seriesId": 12, "monitored": true}]}
JSON
    cat > "$SONARR_HISTORY_JSON" <<'JSON'
{"page": 1, "pageSize": 1000, "totalRecords": 1, "records": [{"seriesId": 99, "eventType": "grabbed", "data": {"indexer": "1337x (Prowlarr)"}}]}
JSON
}

# sonarr_many_records: both envelopes claim 1500 records and deliver 1000 each.
#
# 1500 records is ceil(1500/1000) = 2 pages, so two requests of each endpoint
# are the right number and ten are what a walk that ignores totalRecords makes.
# Two pages of 1000 records also add up to more than the envelope's count, so
# the module judges the document complete and the gate finds its demand.
sonarr_many_records() {
    python3 - "$SONARR_MISSING_JSON" "$SONARR_HISTORY_JSON" <<'PY'
import json
import sys

missing_path, history_path = sys.argv[1], sys.argv[2]
missing = {"page": 1, "pageSize": 1000, "totalRecords": 1500,
           "records": [{"seriesId": 12, "monitored": True}] * 1000}
history = {"page": 1, "pageSize": 1000, "totalRecords": 1500,
           "records": [{"seriesId": 12, "eventType": "grabbed",
                        "data": {"indexer": "1337x (Prowlarr)"}}] * 1000}
with open(missing_path, "w", encoding="utf-8") as handle:
    json.dump(missing, handle)
with open(history_path, "w", encoding="utf-8") as handle:
    json.dump(history, handle)
PY
}

# sonarr_capped_documents: both envelopes count 21 pages of records.
#
# One page past DEMAND_MAX_PAGES, and each page delivers one record, so the
# pages that fit are nowhere near the document's own count: the module has to
# report truncation and the pass has to fail open. This is the shape that used
# to be a false hold -- the fixed walk fetched its five pages, never read
# totalRecords, and judged the join on a slice.
sonarr_capped_documents() {
    python3 - "$SONARR_MISSING_JSON" "$SONARR_HISTORY_JSON" <<'PY'
import json
import sys

missing_path, history_path = sys.argv[1], sys.argv[2]
missing = {"page": 1, "pageSize": 1000, "totalRecords": 21000,
           "records": [{"seriesId": 12, "monitored": True}]}
history = {"page": 1, "pageSize": 1000, "totalRecords": 21000,
           "records": [{"seriesId": 12, "eventType": "grabbed",
                        "data": {"indexer": "1337x (Prowlarr)"}}]}
with open(missing_path, "w", encoding="utf-8") as handle:
    json.dump(missing, handle)
with open(history_path, "w", encoding="utf-8") as handle:
    json.dump(history, handle)
PY
}

# sonarr_documents_without_envelopes: both documents as bare arrays.
#
# Sonarr's real answers are always envelopes. A bare array is what a hand-run
# passes, and it gives --page-total nothing to read: the wrapper has to treat
# the page as a Sonarr it could not read and fail open, not as an empty
# document.
sonarr_documents_without_envelopes() {
    printf '%s\n' '[{"seriesId": 12, "monitored": true}]' > "$SONARR_MISSING_JSON"
    printf '%s\n' '[{"seriesId": 12, "eventType": "grabbed", "data": {"indexer": "1337x (Prowlarr)"}}]' > "$SONARR_HISTORY_JSON"
}

# curl_max_time: the --max-time the stub was asked for on the first Sonarr
# missing page, or empty when that request was never made.
#
# The Sonarr URL travels in the curl config on stdin, so it is not in any argv;
# the output path is, and it names the document and the page.
curl_max_time() {
    grep "sonarr-missing-1.json" "$STUB_LOG" \
        | grep -o -- "--max-time [0-9]*" | head -1 | awk '{print $2}'
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
        printf 'PROWLARR_API_KEY=test-key\nSONARR_API_KEY=test-sonarr-key\nGLUETUN_ROTATE_INTERVAL_SECONDS=%s\n' "$value" > "$ENV_FILE"
        mkdir -p "$(dirname "$ROTATOR_FILE")"
        printf '%s\n' "$(( $(date +%s) - (21600 - 600) ))" > "$ROTATOR_FILE"

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

# --- the demand gate ---------------------------------------------------------
#
# The module's half of the gate -- the join, the name normalisation, the
# fail-open rule -- is covered in tests/python/test_indexer_guard.py. What is
# covered here is the shell half: that Sonarr is asked the right questions,
# that its documents reach the decision, that a Sonarr which cannot answer is a
# warning rather than a failed pass, and that a pass which already holds on
# Prowlarr's evidence asks Sonarr nothing at all.

@test "indexer-guard: the demand documents reach the decision" {
    # The stub's history names 1337x the way Sonarr does -- with the
    # " (Prowlarr)" suffix -- so the gate finds demand and the pass still
    # rotates. The demand line comes from the module's --verdict renderer,
    # which is only reached if the pages the wrapper wrote arrived. One page of
    # each, because the envelope says each document holds one record.
    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "rotate:"
    assert_output --partial "Sonarr demand: 1337x"
    assert_stub_called curl "sonarr-history-1.json"
    assert_stub_called curl "sonarr-missing-1.json"
    assert_stub_not_called curl "sonarr-missing-2.json"
    assert_stub_not_called curl "sonarr-history-2.json"
}

@test "indexer-guard: both endpoints are asked for monitored, paged records" {
    # monitored=true is the request's job, not the module's: the module cannot
    # tell a monitored missing episode from an unmonitored one, so the filter
    # has to be on the URL. page/pageSize are what make the answers more than
    # Sonarr's default page of twenty. How many pages are fetched is the
    # envelope's own count -- a one-record document is one request.
    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success

    grep -q "8989/api/v3/wanted/missing?monitored=true&page=1&pageSize=1000" "$CURL_URLS" || {
        echo "no wanted/missing page 1 in:"; cat "$CURL_URLS"; return 1
    }
    grep -q "8989/api/v3/history?eventType=1&page=1&pageSize=1000" "$CURL_URLS" || {
        echo "no history page 1 in:"; cat "$CURL_URLS"; return 1
    }
    [ "$(grep -c 8989 "$CURL_URLS")" -eq 2 ]
}

@test "indexer-guard: a 1500-record document is fetched in exactly two pages" {
    # The early stop, and the whole reason the wrapper asks the module for
    # totalRecords: 1500 records is two pages of 1000, so two requests of each
    # endpoint are enough and twenty are waste. The gate still finds its demand
    # -- both pages of each document arrived, and 1000 + 1000 covers the
    # envelope's 1500.
    sonarr_many_records

    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "rotate:"
    assert_output --partial "Sonarr demand: 1337x"

    local page
    for page in 1 2; do
        grep -q "wanted/missing?monitored=true&page=$page&pageSize=1000" "$CURL_URLS" || {
            echo "no wanted/missing page $page in:"; cat "$CURL_URLS"; return 1
        }
        grep -q "history?eventType=1&page=$page&pageSize=1000" "$CURL_URLS" || {
            echo "no history page $page in:"; cat "$CURL_URLS"; return 1
        }
    done
    ! grep -q "page=3" "$CURL_URLS" || {
        echo "the walk fetched a page the count did not ask for:"; cat "$CURL_URLS"; return 1
    }
    [ "$(grep -c 8989 "$CURL_URLS")" -eq 4 ]
}

@test "indexer-guard: a document past the page cap stops at it and fails open" {
    # 21000 records is 21 pages of 1000, one past DEMAND_MAX_PAGES, so the walk
    # stops at the cap. Every page carries the document's own count, so the
    # module can see the pages do not cover it: demand unknown, which fails
    # open. Judging the join on the twenty pages that fit is the false hold
    # this cap exists to make impossible.
    sonarr_capped_documents

    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "past the 20-page cap"
    assert_output --partial "rotate:"
    assert_output --partial "Sonarr missing episodes truncated:"
    assert_output --partial "Sonarr history truncated:"
    assert_output --partial "Sonarr demand unknown: Sonarr missing episodes truncated"

    local page
    for page in 1 2 20; do
        grep -q "wanted/missing?monitored=true&page=$page&pageSize=1000" "$CURL_URLS" || {
            echo "no wanted/missing page $page in:"; cat "$CURL_URLS"; return 1
        }
    done
    ! grep -q "page=21" "$CURL_URLS" || {
        echo "the walk went past the cap:"; cat "$CURL_URLS"; return 1
    }
    [ "$(grep -c "wanted/missing" "$CURL_URLS")" -eq 20 ]
    [ "$(grep -c "api/v3/history" "$CURL_URLS")" -eq 20 ]
}

@test "indexer-guard: a first page the module cannot count is a skipped gate" {
    # --page-total is the walk's only source for how many pages to fetch, and a
    # bare array has no totalRecords to read. That is a Sonarr this pass could
    # not read -- fail open -- and the walk stops at page one rather than
    # falling back to some fixed number of requests.
    sonarr_documents_without_envelopes

    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "rotate:"
    assert_output --partial "is not a page envelope"
    assert_output --partial "Sonarr demand unknown: the Sonarr monitored missing episodes page could not be read"
    [ "$(grep -c 8989 "$CURL_URLS")" -eq 1 ]
}

@test "indexer-guard: a history page 2 that fails sends no partial history pages" {
    # Page one succeeds and its envelope says the document needs a second page;
    # that one fails. The pass has half a history in hand, and half a history is
    # a join that under-reports demand -- so the module gets --demand-error and
    # neither document's page flags, and the pass decides on Prowlarr's evidence
    # exactly as it would with Sonarr unreachable.
    sonarr_many_records
    : > "$SONARR_HISTORY_PAGE2_DOWN"

    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "could not fetch the grabbed history from Sonarr"
    assert_output --partial "rotate:"
    assert_output --partial "Sonarr demand unknown: the Sonarr history request failed"
    assert_stub_called python3 "--demand-error"
    assert_stub_not_called python3 "--demand-history"
    assert_stub_not_called python3 "--demand-missing"
    assert_stub_not_called docker ""
    assert_nothing_forbidden
}

@test "indexer-guard: a spent demand budget fails open without a Sonarr request" {
    # The budget is overridable so a test can spend it without waiting two
    # minutes, and zero is the deterministic end of that: the first request
    # would start with nothing left, so it is not made at all. The gate is
    # skipped with the reason, and the pass completes on Prowlarr's evidence.
    export INDEXER_GUARD_DEMAND_BUDGET_SECONDS=0

    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "the Sonarr demand fetch exceeded its 0s budget"
    assert_output --partial "rotate:"
    assert_output --partial "Sonarr demand unknown: the Sonarr demand fetch exceeded its 0s budget"
    ! grep -q 8989 "$CURL_URLS" || {
        echo "Sonarr was called with no budget left:"; cat "$CURL_URLS"; return 1
    }
    assert_stub_not_called docker ""
    assert_nothing_forbidden
}

@test "indexer-guard: a non-numeric demand budget falls back to the default" {
    # The override exists for tests, but a typo in it must not take the guard
    # down: a word would reach the arithmetic in demand_budget_spent, fail
    # there, and `set -e` would end the pass instead of the gate. The default
    # applies, the warning names the variable, and the pass still decides.
    export INDEXER_GUARD_DEMAND_BUDGET_SECONDS=soon

    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "INDEXER_GUARD_DEMAND_BUDGET_SECONDS='soon' is not a whole number of seconds; using 120"
    assert_output --partial "rotate:"
}

@test "indexer-guard: a request's timeout is the smaller of 30s and the budget" {
    # The per-request ceiling is what let ten slow pages stall a pass for five
    # minutes: the budget clamps every request to what is left of it. Under the
    # default budget the first page still gets its full 30 seconds; under a
    # seven-second budget it gets at most seven.
    local value

    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    value="$(curl_max_time)"
    [ -n "$value" ] || fail "no Sonarr request carried a --max-time"
    if (( value < 28 || value > 30 )); then
        fail "the default budget gave the first Sonarr page --max-time $value, not 30"
    fi

    export INDEXER_GUARD_DEMAND_BUDGET_SECONDS=7
    : > "$CURL_URLS"
    : > "$STUB_LOG"
    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    value="$(curl_max_time)"
    [ -n "$value" ] || fail "no Sonarr request carried a --max-time"
    if (( value < 1 || value > 7 )); then
        fail "a seven-second budget gave the first Sonarr page --max-time $value"
    fi
}

@test "indexer-guard: a banned indexer Sonarr has no demand for holds" {
    # Series 12 is missing an episode and series 99 was grabbed from 1337x, so
    # nothing Sonarr needs was ever supplied by the banned indexer: a new exit
    # IP would buy nothing, and the pass holds on the demand reason.
    sonarr_no_demand
    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "hold:"
    assert_output --partial "banned indexers have no Sonarr demand: 1337x"
    assert_output --partial "no Sonarr demand: 1337x"
    assert_stub_not_called docker ""
    assert_nothing_forbidden
}

@test "indexer-guard: a mix of banned indexers rotates on the one with demand" {
    # Two banned indexers, one of them with demand: the rotation happens, and
    # the one it is not for is named rather than silently dropped.
    cat > "$STATUSES_JSON" <<'JSON'
[{"id": 4, "indexerId": 7, "disabledTill": "2099-01-01T00:00:00Z", "message": "Cloudflare error 1006"},
 {"id": 5, "indexerId": 9, "disabledTill": "2099-01-01T00:00:00Z", "message": "403 Forbidden"}]
JSON
    printf '%s\n' '[{"id": 7, "name": "1337x"}, {"id": 9, "name": "EZTV"}]' > "$INDEXERS_JSON"

    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "rotate:"
    assert_output --partial "no Sonarr demand for EZTV"
}

@test "indexer-guard: a Sonarr that cannot be reached is a warning, not a stop" {
    # Fail open, and the whole reason it matters: a Sonarr that is down for one
    # pass must not hold a banned IP in place for every indexer the stack does
    # use. The warning says the gate was skipped, and the pass rotates on
    # Prowlarr's evidence exactly as it did before the gate existed.
    : > "$SONARR_DOWN"

    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "could not fetch the monitored missing episodes from Sonarr"
    assert_output --partial "rotate:"
    assert_output --partial "Sonarr demand unknown"
    assert_stub_not_called docker ""
    assert_nothing_forbidden
}

@test "indexer-guard: no Sonarr call is made when no indexer is in backoff" {
    # The cheap pass, which is nearly every pass: two Prowlarr requests and
    # nothing else. Sonarr is asked only for a decision that would otherwise
    # rotate.
    printf '%s\n' '[]' > "$STATUSES_JSON"

    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "hold:"
    assert_output --partial "no indexer is in backoff"
    ! grep -q 8989 "$CURL_URLS" || {
        echo "Sonarr was called with no indexer in backoff:"; cat "$CURL_URLS"; return 1
    }
    grep -q 9696/api/v1/indexerstatus "$CURL_URLS"
}

@test "indexer-guard: no Sonarr call is made while the cooldown holds" {
    # The other cheap hold, and the one the ordering was chosen for: the module
    # decides first, so a pass whose cooldown is still running never reaches
    # Sonarr at all.
    printf '{"last_rotation": "%s", "rotations": 1}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE"

    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "hold:"
    assert_output --partial "cooldown"
    ! grep -q 8989 "$CURL_URLS" || {
        echo "Sonarr was called for a pass inside the cooldown:"; cat "$CURL_URLS"; return 1
    }
}

@test "indexer-guard: a missing SONARR_API_KEY skips the gate with a warning" {
    # The key is needed only for the demand gate, so its absence is not the
    # PROWLARR_API_KEY situation: the pass continues, and no Sonarr request is
    # made with an empty key.
    printf 'PROWLARR_API_KEY=test-key\n' > "$ENV_FILE"

    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success
    assert_output --partial "SONARR_API_KEY is not set"
    assert_output --partial "rotate:"
    ! grep -q 8989 "$CURL_URLS" || {
        echo "Sonarr was called without a key:"; cat "$CURL_URLS"; return 1
    }
}

@test "indexer-guard: the Sonarr API key reaches no argv and no log line" {
    # Both keys travel in the curl config on stdin. The stub logs the argv it
    # was handed, which is where a -H "X-Api-Key: ..." would show up.
    run "$SCRIPT" --dry-run --state "$STATE"
    assert_success

    ! grep -q "test-sonarr-key" "$STUB_LOG" || {
        echo "the Sonarr key is in a stubbed argv:"; cat "$STUB_LOG"; return 1
    }
    ! grep -q "test-key" "$STUB_LOG" || {
        echo "the Prowlarr key is in a stubbed argv:"; cat "$STUB_LOG"; return 1
    }
    refute_output --partial "test-sonarr-key"
    refute_output --partial "test-key"
}
