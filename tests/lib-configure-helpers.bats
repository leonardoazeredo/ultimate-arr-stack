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

    declare -gA ROUTE_BODY=() ROUTE_CODE=()
}

# Emit exactly what curl -w '\n%{http_code}' -o - would: body, newline, code.
# CURL_BODY may contain newlines; CURL_CODE is written verbatim, so a test can
# hand over "000" or "" the way curl really does.
#
# configure_arr_service talks to fifteen endpoints in one call, so a single
# CURL_BODY cannot describe it. When a test has registered a route for
# "<METHOD> <path>", that route answers; otherwise the CURL_BODY/CURL_CODE pair
# above does, unchanged, for every test written before routing existed.
curl() {
    printf '%s\t%s\n' curl "$*" >> "$CURL_LOG"
    local method=GET url="" prev="" a
    for a in "$@"; do
        [[ "$prev" == "-X" ]] && method="$a"
        [[ "$a" == http* ]] && url="$a"
        prev="$a"
    done
    local path="${url#http://}"; path="/${path#*/}"
    local key="$method $path"
    if [[ -n "${ROUTE_CODE[$key]+set}" ]]; then
        [[ -n "${ROUTE_BODY[$key]}" ]] && printf '%s\n' "${ROUTE_BODY[$key]}"
        printf '%s\n' "${ROUTE_CODE[$key]}"
        return 0
    fi
    if [[ -n "${CURL_BODY:-}" ]]; then printf '%s\n' "$CURL_BODY"; fi
    printf '%s' "${CURL_CODE-200}"
    printf '\n'
    return "${CURL_RC:-0}"
}

# route "<METHOD> <path>" "<body>" [code]
route() { ROUTE_BODY["$1"]="${2-}"; ROUTE_CODE["$1"]="${3:-200}"; }

assert_curl() {
    grep -qF -- "$1" "$CURL_LOG" || {
        echo "expected a curl call containing: $1"
        cat "$CURL_LOG"; return 1
    }
}

refute_curl() {
    if grep -qF -- "$1" "$CURL_LOG"; then
        echo "curl was called with '$1' and should not have been"
        cat "$CURL_LOG"; return 1
    fi
}

# bats-assert reports every failure by calling bats-support's `fail`, which
# returns 1. The unit under test DEFINES `fail` -- it is one of this library's
# output helpers (configure-helpers.sh:34), and it returns 0. setup() sources
# the library into the bats shell, so bats-support's `fail` is shadowed and
# EVERY assert_output/assert_success in this file becomes incapable of failing.
# Proven: two identical `run echo hello; assert_output --partial "not-present"`
# tests, one with the library sourced and one without -- the clean one goes red,
# the sourced one reports ok.
#
# So this file asserts through helpers that return 1 themselves. The tests
# written before configure_arr_service was covered already used plain `[ ... ]`
# and were never affected. tests/shellcheck.bats carries a standing guard so the
# next test file to source a `fail`-defining library cannot rediscover this the
# hard way.
out_has() {
    [[ "$output" == *"$1"* ]] || {
        echo "expected in output: $1"
        echo "--- actual output ---"; echo "$output"; return 1
    }
}

out_lacks() {
    [[ "$output" != *"$1"* ]] || {
        echo "must NOT be in output: $1"
        echo "--- actual output ---"; echo "$output"; return 1
    }
}

status_is() {
    [[ "$status" -eq "$1" ]] || {
        echo "expected status $1, got $status"
        echo "--- actual output ---"; echo "$output"; return 1
    }
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

# --- configure_arr_service --------------------------------------------------
#
# 250 lines, eight sections, fifteen endpoints, and until now not one test. It
# is also the only function here that WRITES: every section is a read, a
# comparison, and a conditional POST or PUT. So the property worth pinning
# hardest is the negative one — given an *arr that is already configured, it
# must issue no write at all. That is what makes the script's "safe to re-run"
# claim true.
#
# The baseline below is a fully-configured Sonarr. Each test perturbs exactly
# one thing about it, which keeps the assertion about that thing rather than
# about the fixture.

META_FIELDS='[{"name":"episodeMetadata","value":true}]'
NAMING_PAYLOAD='{"renameEpisodes":true,"standardEpisodeFormat":"{Series Title}"}'

arr_setup() {
    NAS_IP=10.0.0.1
    DRY_RUN=false
    VERBOSE=false
    QBIT_USERNAME=admin
    QBIT_PASSWORD=hunter2
    SABNZBD_RUNNING=false
    SABNZBD_API_KEY=""
    CONFIGURED=0; SKIPPED=0; FAILED=0

    route "GET /api/v3/health" "" 200
    route "GET /api/v3/rootfolder"       '[{"path":"/data/media/tv"}]'
    route "GET /api/v3/downloadclient"   '[{"name":"qBittorrent"},{"name":"SABnzbd"}]'
    route "GET /api/v3/metadata"         '[{"id":3,"implementation":"XbmcMetadata","enable":true}]'
    route "GET /api/v3/config/naming"    '{"renameEpisodes":true}'
    route "GET /api/v3/customformat"     '[{"id":9,"name":"Reject ISO"}]'
    route "GET /api/v3/qualityprofile"   '[{"id":1}]'
    route "GET /api/v3/qualityprofile/1" '{"id":1,"formatItems":[{"format":9,"name":"Reject ISO","score":-10000}]}'
    route "GET /api/v3/delayprofile"     '[{"preferredProtocol":"usenet"}]'

    route "POST /api/v3/rootfolder"      '{"id":1}' 201
    route "POST /api/v3/downloadclient"  '{"id":2}' 201
    route "PUT /api/v3/metadata/3"       '{}'
    route "PUT /api/v3/config/naming"    '{}'
    route "POST /api/v3/customformat"    '{"id":9}' 201
    route "PUT /api/v3/qualityprofile/1" '{}'
    route "POST /api/v3/delayprofile"    '{}' 201
}

sonarr() {
    configure_arr_service Sonarr 8989 sonarr-key /data/media/tv tv \
        renameEpisodes "$META_FIELDS" "$NAMING_PAYLOAD"
    echo "COUNTS ${CONFIGURED} ${SKIPPED} ${FAILED}"
}

radarr() {
    configure_arr_service Radarr 7878 radarr-key /data/media/movies movies \
        renameMovies "$META_FIELDS" "$NAMING_PAYLOAD"
    echo "COUNTS ${CONFIGURED} ${SKIPPED} ${FAILED}"
}

@test "configure-helpers: an already-configured arr issues no write at all" {
    arr_setup
    run sonarr
    status_is 0
    refute_curl "-X POST"
    refute_curl "-X PUT"
    out_has "COUNTS 0 5 0"
}

@test "configure-helpers: no API key stops before any HTTP call" {
    arr_setup
    run configure_arr_service Sonarr 8989 "" /data/media/tv tv \
        renameEpisodes "$META_FIELDS" "$NAMING_PAYLOAD"
    out_has "Sonarr: no API key, skipping"
    [ ! -s "$CURL_LOG" ]
}

@test "configure-helpers: a service that never answers is not configured anyway" {
    arr_setup
    ROUTE_CODE["GET /api/v3/health"]=404
    WAIT_TIMEOUT=1 run sonarr
    out_has "Sonarr not responding"
    refute_curl "-X POST"
    refute_curl "-X PUT"
}

@test "configure-helpers: a missing root folder is created at the path it was given" {
    arr_setup
    route "GET /api/v3/rootfolder" '[]'
    run sonarr
    assert_curl '{"path":"/data/media/tv"}'
    out_has "added root folder /data/media/tv"
}

@test "configure-helpers: a rejected root-folder write is counted, not swallowed" {
    arr_setup
    route "GET /api/v3/rootfolder" '[]'
    route "POST /api/v3/rootfolder" '{"message":"nope"}' 400
    run sonarr
    out_has "✗ Sonarr: add root folder"
    out_has "COUNTS 0 4 1"
}

@test "configure-helpers: the qBittorrent client carries tv's field names for Sonarr" {
    arr_setup
    route "GET /api/v3/downloadclient" '[]'
    run sonarr
    assert_curl '"name": "tvCategory", "value": "tv"'
    assert_curl '"name": "recentTvPriority"'
    assert_curl '"name": "olderTvPriority"'
    assert_curl '"value": "hunter2"'
}

@test "configure-helpers: the same call for Radarr derives movie field names instead" {
    arr_setup
    route "GET /api/v3/downloadclient" '[]'
    run radarr
    assert_curl '"name": "movieCategory", "value": "movies"'
    assert_curl '"name": "recentMoviePriority"'
    refute_curl "tvCategory"
}

@test "configure-helpers: the download-client match is case-insensitive on the name" {
    # The *arr UI title-cases what the user typed, so an existing client can
    # come back as "QBittorrent". Matching case-sensitively would add a second
    # copy of the same client on every run.
    arr_setup
    route "GET /api/v3/downloadclient" '[{"name":"QBITTORRENT"}]'
    run sonarr
    refute_curl "QBittorrentSettings"
    out_has "qBittorrent download client (already configured)"
}

@test "configure-helpers: SABnzbd is added only when it is running and has a key" {
    arr_setup
    route "GET /api/v3/downloadclient" '[{"name":"qBittorrent"}]'
    run sonarr
    refute_curl "SabnzbdSettings"

    : > "$CURL_LOG"
    SABNZBD_RUNNING=true SABNZBD_API_KEY="" run sonarr
    refute_curl "SabnzbdSettings"

    : > "$CURL_LOG"
    SABNZBD_RUNNING=true SABNZBD_API_KEY=sabkey run sonarr
    assert_curl "SabnzbdSettings"
    assert_curl '"name": "apiKey", "value": "sabkey"'
}

@test "configure-helpers: disabled NFO metadata is enabled at its own id" {
    arr_setup
    route "GET /api/v3/metadata" '[{"id":3,"implementation":"XbmcMetadata","enable":false}]'
    run sonarr
    assert_curl "http://10.0.0.1:8989/api/v3/metadata/3"
    assert_curl '"id":3,"fields":[{"name":"episodeMetadata","value":true}]'
    out_has "enabled NFO metadata"
}

@test "configure-helpers: an arr with no XbmcMetadata entry is left alone, not failed" {
    arr_setup
    route "GET /api/v3/metadata" '[{"id":1,"implementation":"MediaBrowserMetadata"}]'
    run sonarr
    refute_curl "/api/v3/metadata/"
    out_lacks "✗ Sonarr: enable NFO metadata"
}

@test "configure-helpers: the naming check reads the field it was told to read" {
    # Sonarr's flag is renameEpisodes and Radarr's is renameMovies. Reading the
    # wrong one always finds nothing, so naming is rewritten on every run.
    arr_setup
    route "GET /api/v3/config/naming" '{"renameEpisodes":false,"renameMovies":true}'
    run sonarr
    out_has "set TRaSH naming scheme"
    assert_curl '"standardEpisodeFormat":"{Series Title}"'

    # Radarr reads renameMovies, which this fixture has set, so the same
    # response leaves it alone. Everything else in the baseline is already
    # configured, so `-X PUT` appearing at all would be the naming write.
    : > "$CURL_LOG"
    run radarr
    out_has "TRaSH naming (already customised)"
    refute_curl "-X PUT"
}

@test "configure-helpers: a missing Reject ISO format is created and its id captured" {
    arr_setup
    route "GET /api/v3/customformat" '[]'
    route "POST /api/v3/customformat" '{"id":42,"name":"Reject ISO"}' 201
    route "GET /api/v3/qualityprofile/1" '{"id":1,"formatItems":[]}'
    run sonarr
    out_has "added Reject ISO custom format"
    # The captured id is what the scoring pass then writes against.
    assert_curl '{"format": 42, "name": "Reject ISO", "score": -10000}'
}

@test "configure-helpers: a custom-format response with no id is a failure, not a silent skip" {
    arr_setup
    route "GET /api/v3/customformat" '[]'
    route "POST /api/v3/customformat" '{"message":"validation failed"}' 400
    run sonarr
    out_has "✗ Sonarr: add Reject ISO custom format"
    # And with no id there is nothing to score, so the profile pass is skipped
    # rather than writing a null format id into every quality profile.
    refute_curl "-X PUT"
}

@test "configure-helpers: a profile scoring Reject ISO correctly is not rewritten" {
    arr_setup
    run sonarr
    assert_curl "http://10.0.0.1:8989/api/v3/qualityprofile/1"
    refute_curl "-X PUT"
}

@test "configure-helpers: a wrong score is replaced rather than duplicated" {
    arr_setup
    route "GET /api/v3/qualityprofile/1" \
        '{"id":1,"formatItems":[{"format":9,"name":"Reject ISO","score":0},{"format":5,"name":"Other","score":10}]}'
    run sonarr
    out_has "scored Reject ISO at -10000 in profile 1"
    assert_curl '{"format": 9, "name": "Reject ISO", "score": -10000}'
    # The stale entry is gone, not left beside the new one.
    refute_curl '"format": 9, "name": "Reject ISO", "score": 0'
    # ...and an unrelated format is preserved.
    assert_curl '{"format": 5, "name": "Other", "score": 10}'
}

@test "configure-helpers: every quality profile is visited, not just the first" {
    arr_setup
    route "GET /api/v3/qualityprofile" '[{"id":1},{"id":2},{"id":3}]'
    route "GET /api/v3/qualityprofile/1" '{"id":1,"formatItems":[]}'
    route "GET /api/v3/qualityprofile/2" '{"id":2,"formatItems":[]}'
    route "GET /api/v3/qualityprofile/3" '{"id":3,"formatItems":[]}'
    route "PUT /api/v3/qualityprofile/2" '{}'
    route "PUT /api/v3/qualityprofile/3" '{}'
    run sonarr
    out_has "in profile 1"
    out_has "in profile 2"
    out_has "in profile 3"
}

@test "configure-helpers: one unreadable profile does not abandon the rest" {
    arr_setup
    route "GET /api/v3/qualityprofile" '[{"id":1},{"id":2}]'
    route "GET /api/v3/qualityprofile/1" '' 500
    route "GET /api/v3/qualityprofile/2" '{"id":2,"formatItems":[]}'
    route "PUT /api/v3/qualityprofile/2" '{}'
    run sonarr
    out_has "in profile 2"
    out_lacks "in profile 1"
}

@test "configure-helpers: the delay profile is added only when SABnzbd is running" {
    arr_setup
    route "GET /api/v3/delayprofile" '[{"preferredProtocol":"torrent"}]'
    run sonarr
    # Not even read: the whole section sits behind the SABnzbd flag.
    refute_curl "/api/v3/delayprofile"

    : > "$CURL_LOG"
    SABNZBD_RUNNING=true run sonarr
    assert_curl '"preferredProtocol":"usenet","usenetDelay":0,"torrentDelay":30'
    out_has "added delay profile"
}

@test "configure-helpers: an existing usenet delay profile is left alone" {
    arr_setup
    SABNZBD_RUNNING=true run sonarr
    out_has "delay profile (already configured)"
    refute_curl "torrentDelay"
}

@test "configure-helpers: a dry run reads nothing past the health check and writes nothing" {
    arr_setup
    DRY_RUN=true SABNZBD_RUNNING=true SABNZBD_API_KEY=sabkey run sonarr
    out_has "Would: Add root folder /data/media/tv"
    out_has "Would: Add qBittorrent download client (category: tv)"
    out_has "Would: Add SABnzbd download client (category: tv)"
    out_has "Would: Add delay profile (Usenet 0, Torrent 30)"
    refute_curl "-X POST"
    refute_curl "-X PUT"
    refute_curl "/api/v3/rootfolder"
}

@test "configure-helpers: a dry run omits the two SABnzbd steps when it is not running" {
    arr_setup
    DRY_RUN=true run sonarr
    out_lacks "Would: Add SABnzbd"
    out_lacks "Would: Add delay profile"
}
