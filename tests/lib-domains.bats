#!/usr/bin/env bats
# scripts/lib/check-domains.sh
#
# Check 9 of scripts/pre-commit. It resolves fourteen .lan names against
# Pi-hole and two external names against the internet, and it is documented as
# warnings-only: it returns 0 on every path, including the ones that print
# FAIL. That contract is what these tests pin first, because it is the one a
# future "make the checks stricter" edit is most likely to break silently.
#
# The work happens in `( ... ) &` subshells. Shell function overrides ARE
# inherited by those, so dig and curl are overridden as functions rather than
# PATH stubs -- and every override logs to a FILE, because a variable assigned
# inside a subshell dies with it. Same trap as asserting on a variable set
# inside bats' own `run`.

setup() {
    load helpers/setup
    source "$REPO_ROOT/scripts/lib/common.sh"
    source "$REPO_ROOT/scripts/lib/check-domains.sh"

    # common.sh short-circuits on cached _LOADED flags; left alone, whichever
    # test ran first would decide the answer for all the rest.
    _NAS_CONFIG_LOADED=true
    _DOMAIN_LOADED=true

    DIG_LOG="$BATS_TEST_TMPDIR/dig.log"
    CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    : > "$DIG_LOG"
    : > "$CURL_LOG"

    # The default world: NAS configured, Pi-hole answering, no external domain.
    # Individual tests re-override to reach the other arms.
    has_nas_config() { return 0; }
    get_nas_ip()     { echo "192.168.8.2"; }
    get_domain()     { echo ""; }

    dig() {
        printf 'dig\t%s\n' "$*" >> "$DIG_LOG"
        echo "192.168.8.250"
    }
    curl() {
        printf 'curl\t%s\n' "$*" >> "$CURL_LOG"
        printf '%s' "${HTTP_CODE-200}"
    }
}

# Fail exactly one .lan name, resolve the rest.
fail_lan() { local n="$1"; dig() {
        printf 'dig\t%s\n' "$*" >> "$DIG_LOG"
        case "$*" in *"$n"*) return 0 ;; *) echo "192.168.8.250" ;; esac
    }; }

# ------------------------------------------------------------------ the skips

@test "domains: no NAS config is a skip" {
    has_nas_config() { return 1; }
    run check_domains
    assert_success
    assert_output --partial "SKIP: No NAS config"
    [ ! -s "$DIG_LOG" ]
}

@test "domains: no dig is a skip" {
    # The only test that must not define dig as a function, since `command -v`
    # finds a function perfectly well. An empty PATH is how the absence is made
    # real, and it is restored immediately rather than left to teardown.
    local saved="$PATH"
    unset -f dig
    mkdir -p "$BATS_TEST_TMPDIR/nothing"
    PATH="$BATS_TEST_TMPDIR/nothing"
    run check_domains
    PATH="$saved"
    assert_success
    assert_output --partial "SKIP: dig not installed"
}

@test "domains: an undeterminable NAS IP is a skip, not a query against nothing" {
    get_nas_ip() { echo ""; }
    run check_domains
    assert_success
    assert_output --partial "SKIP: Could not determine NAS IP"
    # The guard exists so dig is never handed `@` with no server after it,
    # which resolves against the system resolver instead -- a query that would
    # answer, from the wrong place, and read as a pass.
    [ ! -s "$DIG_LOG" ]
}

@test "domains: DEFECT - an unusable temp dir is a skip, not fourteen failures" {
    # mktemp -d was unchecked. On failure tmpdir is empty, every touch becomes
    # a write to the filesystem ROOT, and all fourteen names are then reported
    # as not resolving -- a DNS verdict manufactured entirely out of a local
    # filesystem error, which is the exact shape of a green check that means
    # nothing (here, inverted: a red one that means nothing).
    mktemp() { return 1; }
    run check_domains
    assert_success
    assert_output --partial "SKIP: Could not create temp dir"
    refute_output --partial "does not resolve"
}

# -------------------------------------------------------------- the .lan half

@test "domains: all fourteen .lan names resolving is one OK line" {
    run check_domains
    assert_success
    assert_output --partial "OK: All 14 .lan domains resolve"
    refute_output --partial "FAIL"
}

@test "domains: it asks Pi-hole by IP, with a bounded timeout" {
    run check_domains
    assert_success
    # Assert on what was ASKED FOR. Against a NAS that is simply down, an
    # unbounded dig is a commit that hangs; +time and +tries are the whole
    # reason this check can live in a hook.
    grep -q '@192.168.8.2' "$DIG_LOG"
    grep -q '+time=2' "$DIG_LOG"
    grep -q '+tries=1' "$DIG_LOG"
    [ "$(grep -c '^dig' "$DIG_LOG")" -eq 14 ]
}

@test "domains: it queries every name the stack publishes" {
    run check_domains
    assert_success
    for name in jellyfin seerr jellyseerr sonarr radarr prowlarr bazarr \
                qbit sabnzbd traefik pihole uptime duc beszel; do
        grep -q " $name.lan " "$DIG_LOG" || {
            echo "never queried: $name.lan"; cat "$DIG_LOG"; return 1
        }
    done
}

@test "domains: one name failing is named, and suppresses the all-clear" {
    fail_lan "sonarr.lan"
    run check_domains
    assert_success
    assert_output --partial "FAIL: sonarr.lan does not resolve"
    refute_output --partial ".lan domains resolve"
    # Warnings-only: a failure is still a zero exit. Pinned because the file
    # says so in a comment, and a comment is not a test.
    refute_output --partial "OK: All domains accessible"
}

@test "domains: an empty answer is a failure, not an answer" {
    # dig +short exits 0 with no output for NXDOMAIN, so the status is useless
    # here and only the emptiness of the answer carries the verdict.
    dig() { printf 'dig\t%s\n' "$*" >> "$DIG_LOG"; return 0; }
    run check_domains
    assert_success
    [ "$(printf '%s\n' "$output" | grep -c 'does not resolve')" -eq 14 ]
}

# --------------------------------------------------------- the external half

@test "domains: no configured domain skips the external half entirely" {
    run check_domains
    assert_success
    assert_output --partial "SKIP: No domain found in config.local.md"
    [ ! -s "$CURL_LOG" ]
}

@test "domains: a configured domain checks jellyfin and seerr over HTTPS" {
    get_domain() { echo "example.com"; }
    run check_domains
    assert_success
    assert_output --partial "OK: All 2 external domains accessible"
    grep -q 'https://jellyfin.example.com' "$CURL_LOG"
    grep -q 'https://seerr.example.com' "$CURL_LOG"
    grep -q -- '--max-time 5' "$CURL_LOG"
}

@test "domains: every accepted HTTP code is accepted" {
    # 401 and 403 are in the list on purpose: these services answer an
    # unauthenticated probe with a refusal, and a refusal proves the tunnel and
    # the router are working. Treating them as failures would make the check
    # cry wolf on a perfectly healthy stack, so each arm gets its own run.
    get_domain() { echo "example.com"; }
    for code in 200 301 302 303 307 308 401 403; do
        HTTP_CODE="$code" run check_domains
        assert_success
        assert_output --partial "OK: All 2 external domains accessible" \
            || { echo "code $code was rejected"; return 1; }
    done
}

@test "domains: a rejected HTTP code is reported with the code itself" {
    get_domain() { echo "example.com"; }
    HTTP_CODE=502 run check_domains
    assert_success
    assert_output --partial "FAIL: jellyfin.example.com - HTTP 502"
    refute_output --partial "external domains accessible"
}

@test "domains: curl's 000 -- no response at all -- is a failure" {
    # 000 is what curl writes to %{http_code} when the connection never
    # completed. It is not an HTTP code and must not be mistaken for one; the
    # same sentinel was being returned as a SUCCESS exit status by
    # configure-helpers.sh until it was fixed.
    get_domain() { echo "example.com"; }
    HTTP_CODE=000 run check_domains
    assert_success
    assert_output --partial "HTTP 000"
}

@test "domains: a code that merely CONTAINS an accepted one is rejected" {
    # The regex is anchored at both ends. Unanchored, 2000 and 4030 would pass,
    # and a proxy returning a malformed code would read as healthy.
    get_domain() { echo "example.com"; }
    HTTP_CODE=2000 run check_domains
    assert_success
    assert_output --partial "HTTP 2000"
}

@test "domains: an external name that does not resolve is not called over HTTPS" {
    get_domain() { echo "example.com"; }
    dig() {
        printf 'dig\t%s\n' "$*" >> "$DIG_LOG"
        case "$*" in *example.com*) return 0 ;; *) echo "192.168.8.250" ;; esac
    }
    run check_domains
    assert_success
    assert_output --partial "FAIL: jellyfin.example.com does not resolve"
    # No DNS, no request. Pinned because the alternative -- curl'ing a name
    # that does not resolve -- is a five-second wait per name inside a hook.
    [ ! -s "$CURL_LOG" ]
}

# ------------------------------------------------------------ the contract

@test "domains: the all-clear needs BOTH halves clean" {
    get_domain() { echo "example.com"; }
    run check_domains
    assert_success
    assert_output --partial "OK: All domains accessible"

    fail_lan "duc.lan"
    run check_domains
    assert_success
    refute_output --partial "OK: All domains accessible"
}

@test "domains: it returns 0 even when everything fails" {
    # The reason check 9 is called with `if ... ; then` in scripts/pre-commit is
    # that it is not allowed to block. Every failure path above already asserts
    # assert_success; this is the total-failure case, stated on its own so the
    # contract is impossible to miss when reading the file.
    get_domain() { echo "example.com"; }
    dig() { return 1; }
    run check_domains
    assert_success
}

@test "domains: it leaves no temp directory behind" {
    # TMPDIR is redirected into this test's own tmpdir so the count is of THIS
    # function's leavings and nothing else on the machine. Counting /tmp would
    # make the assertion depend on whatever else happens to be running.
    get_domain() { echo "example.com"; }
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    run check_domains
    assert_success
    [ -z "$(ls -A "$TMPDIR")" ] || { ls -la "$TMPDIR"; return 1; }
}
