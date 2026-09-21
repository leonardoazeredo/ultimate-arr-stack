#!/usr/bin/env bats
# scripts/configure-apps.sh — the API-driven app configurator.
#
# This is the most destructive script in the repo that a test is allowed near:
# it POSTs configuration into four live services and restarts one container.
# Everything here runs behind tests/helpers/stubs.bash, and the headline test is
# the one that drives the WHOLE script with --dry-run and asserts that forbid()
# was never tripped — i.e. that the dry-run gate really does sit in front of
# every mutation, rather than in front of most of them.
#
# The script is sourced rather than executed. Its `main` runs only under the
# BASH_SOURCE guard, so sourcing gives direct access to the seven functions the
# refactor split out.

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init

    SCRIPT="$REPO_ROOT/scripts/configure-apps.sh"

    # Everything the docker stub answers with. One file per question, so a test
    # changes the world by writing a file rather than by rewriting the stub.
    FIX="$BATS_TEST_TMPDIR/fixtures"
    mkdir -p "$FIX"
    printf '%s\n' gluetun sonarr radarr prowlarr bazarr > "$FIX/running"
    echo healthy > "$FIX/gluetun-health"
    printf '<Config>\n  <ApiKey>sonarrkey1234</ApiKey>\n</Config>\n' > "$FIX/sonarr.xml"
    printf '<Config>\n  <ApiKey>radarrkey1234</ApiKey>\n</Config>\n' > "$FIX/radarr.xml"
    printf '<Config>\n  <ApiKey>prowlarrkey12</ApiKey>\n</Config>\n' > "$FIX/prowlarr.xml"
    # What `docker exec bazarr grep '^\s*apikey:' ...` would print, not the
    # whole file: the stub stands in for the grep, not for the config.
    printf '  apikey: bazarrkey1234\n' > "$FIX/bazarr.yaml"
    printf 'api_key = sabkey12345\n' > "$FIX/sabnzbd.ini"
    echo '192.168.8.100 10.0.0.5' > "$FIX/hostname"
    echo 200 > "$FIX/curl-out"
    export FIX

    stub_docker '
        case "$1" in
            ps)      cat "$FIX/running" ;;
            inspect)
                # configure-apps.sh:196 is the only inspect call in the script:
                #   docker inspect -f '{{.State.Health.Status}}' gluetun
                # Answering ANY inspect argv with canned content would let a broken
                # format string pass here and fail on real docker with a template
                # parse error -- the one thing this stub cannot check for itself.
                [ "$*" = "inspect -f {{.State.Health.Status}} gluetun" ] \
                    || { echo "unexpected docker inspect argv: $*" >&2; exit 125; }
                cat "$FIX/gluetun-health" ;;
            exec)
                case "$*" in
                    *config.xml*)  cat "$FIX/$2.xml"    2>/dev/null || exit 1 ;;
                    *config.yaml*) cat "$FIX/bazarr.yaml"  2>/dev/null || exit 1 ;;
                    *sabnzbd.ini*) cat "$FIX/sabnzbd.ini"  2>/dev/null || exit 1 ;;
                    *) echo "unexpected docker exec: $*" >&2; exit 126 ;;
                esac ;;
            *) echo "unexpected docker argv: $*" >&2; exit 125 ;;
        esac
    '
    # One canned answer for every curl call. Every curl this script makes
    # outside a dry run is a wait_for_service poll, and all that reads is the
    # HTTP code on the last line.
    stub_curl 'cat "$FIX/curl-out"'
    stub_tool hostname 'cat "$FIX/hostname"'

    ENV_FILE="$BATS_TEST_TMPDIR/env"
    : > "$ENV_FILE"
    export CONFIGURE_ENV_FILE="$ENV_FILE"

    # Source the script in a separate process and call one of its functions.
    # Separate because the script sets `-uo pipefail` and defines `skip()` —
    # which would shadow bats' own `skip` in the test shell.
    #
    # DRIVER_PRE is arbitrary shell run after the source and before the call,
    # so a test can set a global or override a function without the script
    # needing a seam for each one.
    #
    # /usr/bin/env bash, not /bin/bash. The driver sources configure-apps.sh,
    # which uses bash 4 parameter expansion (`${svc^^}` in two places), and
    # macOS ships 3.2 at /bin/bash. Measured on this host: with /bin/bash the
    # driver died on "bad substitution" and 8 of this file's 37 tests were red;
    # `bash` on PATH is 5.x and runs them. The suite itself is already
    # `#!/usr/bin/env bats`, so env bash lands the driver on the interpreter the
    # harness picked rather than an older one nobody chose.
    DRIVER="$BATS_TEST_TMPDIR/drive"
    cat > "$DRIVER" <<'EOF'
#!/usr/bin/env bash
source "$SCRIPT"
[ -n "${DRIVER_PRE:-}" ] && eval "$DRIVER_PRE"
"$@"
EOF
    chmod +x "$DRIVER"
    export SCRIPT
}

# ---------------------------------------------------------------- print_usage

@test "configure-apps: --help prints the whole header block, not a line range" {
    run "$DRIVER" parse_args --help
    assert_success
    assert_output --partial "Automated app configuration for arr-stack"
    # The line the old `head -27 | tail -24` silently dropped.
    assert_output --partial "SABnzbd: usenet provider credentials + folder config"
    # ...and it must stop at the blank line, not run into the next block.
    refute_output --partial "No \`set -e\`, deliberately"
}

@test "configure-apps: the help block is derived from the file, not a fixed length" {
    # Independent derivation: grep -v '^#' DOES match a blank line, which is
    # exactly the property the script's awk relies on and a sed `/^[^#]/` range
    # does not have. If someone adds or removes a header line, this moves with
    # it; a hardcoded number would not.
    local end expected
    # tail -n +2 renumbers file line N as N-1, so the index of the first
    # non-comment line IS the file line of the last comment line.
    end=$(tail -n +2 "$SCRIPT" | grep -n -m1 -v '^#' | cut -d: -f1)
    [ "$end" -gt 20 ]
    expected=$(sed -n "2,${end}p" "$SCRIPT" | sed 's/^#\{1\} \{0,1\}//')

    run "$DRIVER" print_usage "$SCRIPT"
    assert_success
    # Whole content, not a line count: a count would still pass if the block
    # started or ended one line off.
    [ "$output" = "$expected" ]
}

@test "configure-apps: --help exits 0 without configuring anything" {
    run "$DRIVER" main --help
    assert_success
    assert_stub_not_called docker ''
    assert_nothing_forbidden
}

# ----------------------------------------------------------------- parse_args

@test "configure-apps: --dry-run sets the flag and nothing else" {
    run "$DRIVER" eval 'parse_args --dry-run; echo "DRY=$DRY_RUN VERBOSE=$VERBOSE"'
    assert_success
    assert_output "DRY=true VERBOSE=false"
}

@test "configure-apps: --verbose and -v are the same flag" {
    run "$DRIVER" eval 'parse_args --verbose; echo "V=$VERBOSE"'
    assert_output "V=true"
    run "$DRIVER" eval 'parse_args -v; echo "V=$VERBOSE"'
    assert_output "V=true"
}

@test "configure-apps: flags can be combined and order does not matter" {
    run "$DRIVER" eval 'parse_args -v --dry-run; echo "$DRY_RUN $VERBOSE"'
    assert_output "true true"
}

@test "configure-apps: an unknown option is named and fails without exiting" {
    # `return 1`, not `exit 1` — so a caller can report it. STILLHERE proves
    # the difference; the status alone cannot.
    run "$DRIVER" eval 'parse_args --wat; echo "RC=$?"; echo STILLHERE'
    assert_success
    assert_output --partial "Unknown option: --wat"
    assert_output --partial "RC=1"
    assert_output --partial "STILLHERE"
}

@test "configure-apps: main refuses to run when an argument is unknown" {
    run "$DRIVER" main --wat
    assert_failure
    assert_stub_not_called docker ''
    assert_nothing_forbidden
}

# ------------------------------------------------------------------ env_value

@test "configure-apps: env_value keeps everything after the first =" {
    printf 'SABNZBD_API_KEY=a=b=c\n' > "$ENV_FILE"
    run "$DRIVER" env_value SABNZBD_API_KEY "$ENV_FILE"
    assert_success
    assert_output "a=b=c"
}

@test "configure-apps: env_value strips one layer of double quotes" {
    printf 'SABNZBD_API_KEY="s3cret"\n' > "$ENV_FILE"
    run "$DRIVER" env_value SABNZBD_API_KEY "$ENV_FILE"
    assert_output "s3cret"
}

@test "configure-apps: env_value strips one layer of single quotes" {
    printf "SABNZBD_API_KEY='s3cret'\n" > "$ENV_FILE"
    run "$DRIVER" env_value SABNZBD_API_KEY "$ENV_FILE"
    assert_output "s3cret"
}

# The two fake keys below spell "example" on purpose, and the pre-commit hook is
# why. check-secrets.sh Pattern 6 flags `(PASSWORD|SECRET|API_KEY)=<30+ chars>`
# in any tracked file, and it exempts only `tests/fixtures/*`, not
# `tests/*.bats` -- so a realistic-looking key here would block every later
# commit in the repo, not just this file's. Placeholder-shaped values keep the
# guard armed at full strength everywhere instead of widening the exemption to
# all of tests/.
@test "configure-apps: env_value matches the key at the start of the line only" {
    printf 'OLD_SABNZBD_API_KEY=example-wrong\nSABNZBD_API_KEY=example-right\n' > "$ENV_FILE"
    run "$DRIVER" env_value SABNZBD_API_KEY "$ENV_FILE"
    assert_output "example-right"
}

@test "configure-apps: env_value fails on a missing key and a missing file" {
    printf 'OTHER=1\n' > "$ENV_FILE"
    run "$DRIVER" env_value SABNZBD_API_KEY "$ENV_FILE"
    assert_failure
    run "$DRIVER" env_value SABNZBD_API_KEY "$BATS_TEST_TMPDIR/nope"
    assert_failure
}

# --------------------------------------------------------- check_prerequisites

@test "configure-apps: check_prerequisites fails when docker is absent" {
    DRIVER_PRE='PATH=/nonexistent-for-tests' run "$DRIVER" check_prerequisites
    assert_failure
    assert_output --partial "docker not found"
}

@test "configure-apps: check_prerequisites fails when no NAS IP can be detected" {
    DRIVER_PRE='hostname() { return 0; }' run "$DRIVER" check_prerequisites
    assert_failure
    assert_output --partial "Could not detect NAS IP"
}

@test "configure-apps: check_prerequisites takes the first address hostname -I prints" {
    run "$DRIVER" eval 'check_prerequisites >/dev/null; echo "IP=$NAS_IP"'
    assert_output --partial "IP=192.168.8.100"
}

@test "configure-apps: every required container is checked and missing ones are named" {
    : > "$FIX/running"
    run "$DRIVER" check_prerequisites
    assert_failure
    local c
    for c in gluetun sonarr radarr prowlarr bazarr; do
        assert_output --partial " $c"
    done
    assert_output --partial "Required containers not running:"
}

@test "configure-apps: one missing container is enough to stop the run" {
    grep -v '^radarr$' "$FIX/running" > "$FIX/running.tmp" && mv "$FIX/running.tmp" "$FIX/running"
    run "$DRIVER" check_prerequisites
    assert_failure
    assert_output --partial "Required containers not running: radarr"
}

@test "configure-apps: a container whose name merely contains a required one does not count" {
    printf '%s\n' gluetun-exit sonarr radarr prowlarr bazarr > "$FIX/running"
    run "$DRIVER" check_prerequisites
    assert_failure
    assert_output --partial "Required containers not running: gluetun"
}

@test "configure-apps: an unhealthy gluetun is named with its actual state" {
    echo unhealthy > "$FIX/gluetun-health"
    run "$DRIVER" check_prerequisites
    assert_failure
    assert_output --partial "Gluetun is 'unhealthy' (need 'healthy')"
}

@test "configure-apps: check_prerequisites returns rather than exits, so main can report" {
    echo starting > "$FIX/gluetun-health"
    run "$DRIVER" eval 'check_prerequisites >/dev/null; echo "RC=$?"; echo STILLHERE'
    assert_success
    assert_output --partial "RC=1"
    assert_output --partial "STILLHERE"
}

@test "configure-apps: SABnzbd is optional and its absence is not a failure" {
    run "$DRIVER" eval 'check_prerequisites >/dev/null; echo "RC=$? SAB=$SABNZBD_RUNNING"'
    assert_output --partial "RC=0 SAB=false"
}

@test "configure-apps: SABNZBD_RUNNING is set when the container is up" {
    echo sabnzbd >> "$FIX/running"
    run "$DRIVER" eval 'check_prerequisites >/dev/null; echo "SAB=$SABNZBD_RUNNING"'
    assert_output --partial "SAB=true"
}

@test "configure-apps: a container whose name merely contains sabnzbd is not sabnzbd" {
    # The same substring-match defect as the required-container check above: with
    # `grep -q` instead of `-qx`, any name containing "sabnzbd" counts. This flag
    # gates the SABnzbd API-key lookup and the manual step in the summary, so
    # an unrelated container (sabnzbd-exporter, a sabnzbd-sidecar) turns an
    # optional service into one the script reaches into and reports a failure
    # for. This repo has already shipped this exact matcher twice.
    printf '%s\n' sabnzbd-exporter >> "$FIX/running"
    run "$DRIVER" eval 'check_prerequisites >/dev/null; echo "SAB=$SABNZBD_RUNNING"'
    assert_output --partial "SAB=false"
}

# ------------------------------------------------------------ API-key discovery

@test "configure-apps: each arr key is read out of that service's own config.xml" {
    run "$DRIVER" discover_api_keys
    assert_success
    assert_output --partial "Sonarr API key: sonarrke..."
    assert_output --partial "Radarr API key: radarrke..."
    assert_output --partial "Prowlarr API key: prowlarr..."
    assert_stub_called docker "exec sonarr cat /config/config.xml"
    assert_stub_called docker "exec radarr cat /config/config.xml"
    assert_stub_called docker "exec prowlarr cat /config/config.xml"
}

@test "configure-apps: a missing arr key is reported as a failure, not skipped silently" {
    rm "$FIX/radarr.xml"
    run "$DRIVER" eval 'discover_api_keys >/dev/null 2>&1; echo "FAILED=$FAILED"'
    assert_output --partial "FAILED=1"
}

@test "configure-apps: the Bazarr key comes off the apikey line of its yaml" {
    run "$DRIVER" discover_api_keys
    assert_output --partial "Bazarr API key: bazarrke..."
}

@test "configure-apps: a missing Bazarr key is a counted failure" {
    rm "$FIX/bazarr.yaml"
    run "$DRIVER" eval 'discover_api_keys >/dev/null 2>&1; echo "FAILED=$FAILED"'
    assert_output --partial "FAILED=1"
}

@test "configure-apps: SABnzbd's key is only looked for when SABnzbd is running" {
    run "$DRIVER" discover_api_keys
    assert_stub_not_called docker "sabnzbd.ini"
    DRIVER_PRE='SABNZBD_RUNNING=true' run "$DRIVER" discover_api_keys
    assert_output --partial "SABnzbd API key: sabkey12..."
}

# -------------------------------------------------------------- print_summary

@test "configure-apps: the summary reports all three counters" {
    DRIVER_PRE='CONFIGURED=7; SKIPPED=3; FAILED=0' run "$DRIVER" print_summary
    assert_success
    assert_output --partial "Summary: 7 configured, 3 skipped, 0 failed"
}

@test "configure-apps: FAILED is not decorative — a failure makes the script exit non-zero" {
    DRIVER_PRE='FAILED=2' run "$DRIVER" print_summary
    assert_failure
    assert_output --partial "2 failed"
    assert_output --partial "Some steps failed."
}

@test "configure-apps: a clean run exits zero and says nothing about failures" {
    DRIVER_PRE='FAILED=0' run "$DRIVER" print_summary
    assert_success
    refute_output --partial "Some steps failed."
}

@test "configure-apps: the SABnzbd manual step appears only when SABnzbd is running" {
    run "$DRIVER" print_summary
    refute_output --partial "4. SABnzbd"
    DRIVER_PRE='SABNZBD_RUNNING=true' run "$DRIVER" print_summary
    assert_output --partial "4. SABnzbd: usenet provider credentials"
}

# --------------------------------------------------------- the dry-run boundary

@test "configure-apps: a full --dry-run run reaches no mutating operation at all" {
    # The test in this file. Every configure_* function has its own dry-run
    # early return; this drives all four through main and asserts the harness
    # never had to stop anything. A per-function assertion would pass even if
    # one function's gate were in the wrong place.
    echo sabnzbd >> "$FIX/running"
    run "$DRIVER" main --dry-run
    assert_success
    assert_nothing_forbidden
    assert_output --partial "DRY RUN - no changes will be made"
    assert_output --partial "[dry-run] Would:"
}

@test "configure-apps: --dry-run touches nothing in the arrs or Bazarr" {
    run "$DRIVER" main --dry-run
    assert_success
    # The named mutations, one per service, asserted on the argv actually used.
    assert_stub_not_called curl "rootfolder"
    assert_stub_not_called curl "downloadclient"
    assert_stub_not_called docker "restart"
    assert_nothing_forbidden
}

@test "configure-apps: --dry-run still names every step it would have taken" {
    run "$DRIVER" main --dry-run
    assert_output --partial "Would: Add root folder /data/media/tv"
    assert_output --partial "Would: Add root folder /data/media/movies"
}

@test "configure-apps: main stops at prerequisites and configures nothing" {
    echo unhealthy > "$FIX/gluetun-health"
    run "$DRIVER" main
    assert_failure
    assert_output --partial "Gluetun is 'unhealthy'"
    refute_output --partial "Discovering API keys"
    assert_nothing_forbidden
}
