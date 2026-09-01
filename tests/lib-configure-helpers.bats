#!/usr/bin/env bats
# scripts/lib/configure-helpers.sh
#
# The HTTP layer under scripts/configure-apps.sh. Every call site in that file
# is `if api_post ...; then ok "added X"; else fail "add X"; fi`, so the ONLY
# thing those success/failure lines are reading is this unit's exit status.
#
# _api_request:68 returned the HTTP code AS that status for non-GET requests.
# Three separate things fall out of that, and the third is the live bug:
#
#   * 404 -> 148, 500 -> 244. Meaningless numbers, though at least non-zero.
#   * an empty code -> `return: : numeric argument required`, a bash runtime
#     error, and status 2.
#   * curl writes "000" to %{http_code} when the connection never completed --
#     refused, DNS failure, timed out. `return "000"` is status 0. So the most
#     ordinary failure there is, a service that is simply not up, was reported
#     by configure-apps.sh as `✓ added`. Verified live against a dead port.
#
# WHY THE CURL STUB HERE IS A SHELL FUNCTION AND NOT tests/helpers/stubs.bash
#
# The PATH harness forbids `-X POST` and `-X PUT` on purpose: they are how this
# repo mutates *arr state, and no test driving an operational script may reach
# one. But `-X POST` is precisely the argv THIS unit exists to construct, so a
# PATH stub would refuse to let the unit under test run at all. _api_request
# calls curl in the current shell and never execs or forks a grandchild, so the
# function override (the pre-commit-checks.bats idiom) reaches it and nothing
# destructive is reachable from here in the first place.

setup() {
    load helpers/setup
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    source "$REPO_ROOT/scripts/lib/configure-helpers.sh"
    CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    : > "$CURL_LOG"
    # wait_for_service's only real cost. Its loop is bounded by $SECONDS, not by
    # an iteration count, so a no-op sleep spins rather than hangs.
    sleep() { :; }
}

# Emit exactly what curl -w '\n%{http_code}' -o - would: body, newline, code.
# CURL_BODY may contain newlines; CURL_CODE is written verbatim, so a test can
# hand over "000" or "" the way curl really does.
curl() {
    printf '%s\t%s\n' curl "$*" >> "$CURL_LOG"
    if [[ -n "${CURL_BODY:-}" ]]; then printf '%s\n' "$CURL_BODY"; fi
    printf '%s' "${CURL_CODE-200}"
    printf '\n'
    return "${CURL_RC:-0}"
}

# --- _api_request: the status contract -------------------------------------

@test "configure-helpers: a 2xx GET returns 0 and prints the body" {
    CURL_BODY='{"id":7}' CURL_CODE=200
    run api_get "http://x/api"
    [ "$status" -eq 0 ]
    [ "$output" = '{"id":7}' ]
}

@test "configure-helpers: a 404 GET returns 1" {
    CURL_BODY='not found' CURL_CODE=404
    run api_get "http://x/api"
    [ "$status" -eq 1 ]
}

@test "configure-helpers: a 2xx POST returns 0 and prints the body" {
    CURL_BODY='{"id":9}' CURL_CODE=201
    run api_post "http://x/api" "application/json" '{"k":"v"}'
    [ "$status" -eq 0 ]
    [ "$output" = '{"id":9}' ]
}

@test "configure-helpers: a 404 POST returns 1, not the HTTP code as a status" {
    CURL_BODY='nope' CURL_CODE=404
    run api_post "http://x/api" "application/json" '{}'
    [ "$status" -eq 1 ]
    # 404 % 256 == 148. Pinning the old value explicitly, because a status that
    # merely happens to be non-zero would satisfy a bare assert_failure.
    [ "$status" -ne 148 ]
}

@test "configure-helpers: a 500 PUT returns 1, not 244" {
    CURL_BODY='boom' CURL_CODE=500
    run api_put "http://x/api" "application/json" '{}'
    [ "$status" -eq 1 ]
    [ "$status" -ne 244 ]
}

@test "configure-helpers: a connection that never completed is a failure, not a success" {
    # curl's own sentinel for "I never got a response". This is the case that
    # was reported to the user as a tick.
    CURL_BODY='' CURL_CODE=000
    run api_post "http://x/api" "application/json" '{}'
    [ "$status" -ne 0 ]
}

@test "configure-helpers: the same sentinel fails a PUT too" {
    CURL_BODY='' CURL_CODE=000
    run api_put "http://x/api" "application/json" '{}'
    [ "$status" -ne 0 ]
}

@test "configure-helpers: an empty code is a failure and not a bash runtime error" {
    CURL_BODY='' CURL_CODE=''
    run api_post "http://x/api" "application/json" '{}'
    [ "$status" -ne 0 ]
    [[ "$output" != *"numeric argument required"* ]]
}

@test "configure-helpers: the last code is readable by a caller that wants it" {
    # The code was the only thing the old return value carried. Dropping it from
    # the status without exposing it anywhere would be a real loss of signal.
    CURL_BODY='nope' CURL_CODE=404
    api_post "http://x/api" "application/json" '{}' >/dev/null || true
    [ "$_API_LAST_CODE" = "404" ]
}

@test "configure-helpers: a connection that never completed is recorded as 000" {
    # curl leaves %{http_code} empty in some failure modes and writes the
    # literal 000 in others. Both mean the same thing and both must read the
    # same way to a caller inspecting the code.
    CURL_BODY='' CURL_CODE=''
    api_post "http://x/api" "application/json" '{}' >/dev/null || true
    [ "$_API_LAST_CODE" = "000" ]
}

@test "configure-helpers: the last code is set on success as well" {
    CURL_BODY='{}' CURL_CODE=201
    api_post "http://x/api" "application/json" '{}' >/dev/null
    [ "$_API_LAST_CODE" = "201" ]
}

# --- _api_request: body handling -------------------------------------------

@test "configure-helpers: a multi-line body survives the code being stripped" {
    CURL_BODY=$'line1\nline2\nline3' CURL_CODE=200
    run api_get "http://x/api"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "line1" ]
    [ "${lines[2]}" = "line3" ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "configure-helpers: an empty 2xx body yields empty output, not the code" {
    CURL_BODY='' CURL_CODE=204
    run api_get "http://x/api"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "configure-helpers: a failing non-GET still prints the body so the caller sees why" {
    CURL_BODY='{"message":"already exists"}' CURL_CODE=409
    run api_post "http://x/api" "application/json" '{}'
    [ "$status" -eq 1 ]
    [[ "$output" == *"already exists"* ]]
}

@test "configure-helpers: a failing GET prints nothing" {
    CURL_BODY='some error page' CURL_CODE=500
    run api_get "http://x/api"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# --- _api_request: the argv it builds ---------------------------------------

@test "configure-helpers: a GET carries no -X and no Content-Type" {
    CURL_BODY='{}' CURL_CODE=200
    api_get "http://x/api" "X-Api-Key: k" >/dev/null
    run cat "$CURL_LOG"
    [[ "$output" != *"-X"* ]]
    [[ "$output" != *"Content-Type"* ]]
    [[ "$output" == *"X-Api-Key: k"* ]]
}

@test "configure-helpers: a POST carries the method, the content type and the data" {
    CURL_BODY='{}' CURL_CODE=200
    api_post "http://x/api" "application/json" '{"k":"v"}' "X-Api-Key: k" >/dev/null
    run cat "$CURL_LOG"
    [[ "$output" == *"-X POST"* ]]
    [[ "$output" == *"Content-Type: application/json"* ]]
    [[ "$output" == *'{"k":"v"}'* ]]
    [[ "$output" == *"X-Api-Key: k"* ]]
}

@test "configure-helpers: a POST with no data omits --data entirely" {
    CURL_BODY='{}' CURL_CODE=200
    api_post "http://x/api" "application/json" '' >/dev/null
    run cat "$CURL_LOG"
    [[ "$output" != *"--data"* ]]
}

@test "configure-helpers: every trailing argument becomes its own -H" {
    CURL_BODY='{}' CURL_CODE=200
    api_get "http://x/api" "A: 1" "B: 2" >/dev/null
    run cat "$CURL_LOG"
    [[ "$output" == *"-H A: 1"* ]]
    [[ "$output" == *"-H B: 2"* ]]
}

@test "configure-helpers: VERBOSE detail goes to stderr, never into the body" {
    CURL_BODY='detail' CURL_CODE=404
    # Capture stdout only. If the verbose lines leaked here they would be parsed
    # as JSON by the caller.
    out=$(VERBOSE=true api_get "http://x/api" 2>/dev/null) || true
    [[ "$out" != *"[verbose]"* ]]
    err=$(VERBOSE=true api_get "http://x/api" 2>&1 >/dev/null) || true
    [[ "$err" == *"[verbose]"* ]]
    [[ "$err" == *"404"* ]]
}

# --- wait_for_service -------------------------------------------------------

@test "configure-helpers: wait_for_service accepts a 200" {
    CURL_CODE=200
    run wait_for_service "Sonarr" "http://x/health"
    [ "$status" -eq 0 ]
}

@test "configure-helpers: wait_for_service accepts a 401 because auth means it is up" {
    CURL_CODE=401
    run wait_for_service "Sonarr" "http://x/health"
    [ "$status" -eq 0 ]
}

@test "configure-helpers: wait_for_service accepts a 3xx" {
    CURL_CODE=302
    run wait_for_service "Sonarr" "http://x/health"
    [ "$status" -eq 0 ]
}

@test "configure-helpers: wait_for_service rejects a 404 and gives up at the deadline" {
    CURL_CODE=404 WAIT_TIMEOUT=1
    run wait_for_service "Sonarr" "http://x/health"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not responding after 1s"* ]]
    [[ "$output" == *"last HTTP code: 404"* ]]
}

@test "configure-helpers: wait_for_service reports 'none' when curl never answered" {
    CURL_CODE='' WAIT_TIMEOUT=1
    run wait_for_service "Sonarr" "http://x/health"
    [ "$status" -eq 1 ]
    [[ "$output" == *"last HTTP code: none"* ]]
}

@test "configure-helpers: wait_for_service bounds each attempt, not just the total" {
    # One hung connection must not eat the whole budget; the file's own comment
    # at :79 states this as the design intent.
    CURL_CODE=200
    wait_for_service "Sonarr" "http://x/health" >/dev/null
    run cat "$CURL_LOG"
    [[ "$output" == *"--max-time"* ]]
    [[ "$output" == *"--connect-timeout"* ]]
}

# --- qbit_auth --------------------------------------------------------------

@test "configure-helpers: qbit_auth succeeds only on 200 AND the literal Ok." {
    CURL_BODY='Ok.' CURL_CODE=200
    run qbit_auth "http://q" u p "$BATS_TEST_TMPDIR/c"
    [ "$status" -eq 0 ]
}

@test "configure-helpers: qbit_auth rejects a 200 whose body is a refusal" {
    # qBittorrent answers a bad password with HTTP 200 and the body "Fails.".
    # Reading the status alone would call that a successful login.
    CURL_BODY='Fails.' CURL_CODE=200
    run qbit_auth "http://q" u wrong "$BATS_TEST_TMPDIR/c"
    [ "$status" -eq 1 ]
}

@test "configure-helpers: qbit_auth rejects a non-200 even with an Ok. body" {
    CURL_BODY='Ok.' CURL_CODE=403
    run qbit_auth "http://q" u p "$BATS_TEST_TMPDIR/c"
    [ "$status" -eq 1 ]
}

@test "configure-helpers: qbit_auth passes the credentials url-encoded" {
    CURL_BODY='Ok.' CURL_CODE=200
    qbit_auth "http://q" "us er" "p&ss" "$BATS_TEST_TMPDIR/c"
    run cat "$CURL_LOG"
    [[ "$output" == *"--data-urlencode username=us er"* ]]
    [[ "$output" == *"--data-urlencode password=p&ss"* ]]
}

# --- json_extract -----------------------------------------------------------

@test "configure-helpers: json_extract prints an extracted value" {
    run json_extract '{"id":42}' "print(data['id'])"
    [ "$output" = "42" ]
}

@test "configure-helpers: json_extract carries a sys.exit through as a status" {
    run json_extract '[{"path":"/a"}]' "sys.exit(0 if any(r['path'] == '/a' for r in data) else 1)"
    [ "$status" -eq 0 ]
    run json_extract '[{"path":"/b"}]' "sys.exit(0 if any(r['path'] == '/a' for r in data) else 1)"
    [ "$status" -eq 1 ]
}

@test "configure-helpers: json_extract on malformed JSON fails rather than printing garbage" {
    run json_extract 'not json' "print(data)"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}
