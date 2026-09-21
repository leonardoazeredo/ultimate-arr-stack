#!/usr/bin/env bats
# scripts/adguard-configure.sh — Phase 3.1/3.2/3.4 applied to the live router.
#
# AdGuard Home's HTTP API is not usable on this build: GL.iNet patches the
# binary so /control/* sits behind its own token middleware and ignores
# AdGuard's own session cookie, which was measured rather than assumed (a
# successful /control/login followed by 401 on every request carrying the
# cookie, and on `-u admin:pw`). config.yaml is the only way in, and it is a
# ~90-key file served by a resolver the house will eventually depend on. So the
# script's job is to be boring about it: transform the text, validate it with
# `--check-config` BEFORE it goes anywhere near the live path, keep a backup,
# install, restart, and then prove the result by querying the thing.
#
# The ssh layer is stubbed, and the stub EMULATES THE ROUTER rather than
# recording argv: the script arrives on stdin and runs for real against a fake
# /etc and stub tools. That is what makes the second-run test meaningful — the
# same script, run twice against the state the first run left behind, has to
# write nothing the second time.
#
# One thing the stub cannot do: the shared harness refuses `restart` in any
# argv, which is the property that keeps a test from restarting a live service.
# A remote script's text is not argv, so the stub declines to EXECUTE a restart
# too — it records the line and substitutes an exit code the test controls.
# Otherwise the CLI's restart path would be untestable or, worse, silently
# skipped.

setup() {
    load helpers/setup
    load helpers/stubs

    # Resolved BEFORE stub_init puts $STUB_DIR on PATH. A stub for `md5sum`
    # whose body calls `md5sum` is an infinite fork, and this test file hashes
    # files itself.
    REAL_MD5SUM="$(command -v md5sum 2>/dev/null || true)"
    stub_init

    SCRIPT="$REPO_ROOT/scripts/adguard-configure.sh"
    ORIG="$BATS_TEST_TMPDIR/orig.yaml"
    write_router_config "$ORIG"

    # A fake router filesystem. The CLI builds its remote commands from these
    # paths, so overriding them is what lets the stub run the real script.
    ROUTER_ROOT="$BATS_TEST_TMPDIR/router"
    mkdir -p "$ROUTER_ROOT/etc/AdGuardHome"
    cp "$ORIG" "$ROUTER_ROOT/etc/AdGuardHome/config.yaml"

    export AGH_SSH=ssh
    export AGH_JUMP=pi@pi1.local
    export AGH_ROUTER=arr-stack-router
    export AGH_CONFIG="$ROUTER_ROOT/etc/AdGuardHome/config.yaml"
    export AGH_STAGE="$AGH_CONFIG.incoming"
    export AGH_BIN=AdGuardHome
    export AGH_INIT=adguardhome-init
    export AGH_DNS_PORT=3053
    export AGH_DNSMASQ_CONF="$REPO_ROOT/pihole/dnsmasq.d/02-local-dns.conf.example"
    # The CLI polls the resolver rather than probing it once (the proxy comes up
    # a moment after the web UI). Three tries with no sleep keeps that behaviour
    # under test without spending a minute per case.
    export AGH_DNS_TRIES=3 AGH_DNS_SLEEP=0 AGH_BLOCK_TRIES=3 AGH_RETRY_SLEEP=0

    : > "$STUB_DIR/uci.state"
    printf 'adguardhome.config.dns_enabled=%s\n' "${DNS_ENABLED:-0}" >> "$STUB_DIR/uci.state"

    stub_tool ssh "$(_fake_ssh_body)"
    stub_tool dig "$(_fake_dig_body)"
    stub_tool uci "$(_fake_uci_body)"
    [ -n "$REAL_MD5SUM" ] || skip "no md5sum on this host: the CLI hashes the staged file to prove it landed intact, and this emulation cannot stand in for that"
    stub_tool md5sum "$(_fake_md5sum_body "$REAL_MD5SUM")"
    stub_tool AdGuardHome "$(_fake_check_body)"
    stub_tool adguardhome-init 'printf "%s\n" "init $*"; exit 0'

    # Created here and not at file scope: these are built from $STUB_DIR, which
    # does not exist until stub_init has run. Empty files rather than paths that
    # do not exist yet, so a count over them is "0" and not an empty string.
    mkdir -p "$STUB_DIR/remote"
    remote_log="$STUB_DIR/remote/all"
    restart_log="$STUB_DIR/remote/restarts"
    : > "$remote_log"
    : > "$restart_log"
}

# The fixture the lib tests also build. Named per-file rather than shared: two
# identical copies that can drift are worse than one that is obviously local,
# and a helper name that two .bats files both define is how a silently shadowed
# assertion got into this suite once before.
write_router_config() {
    cat > "$1" <<'YAML'
http:
  address: 0.0.0.0:3000
  session_ttl: 720h
users:
  - name: admin
    password: $2a$05$wbGXDl8iYr7aspkzk7RYvutoV6kkn7EE3LhPNFAnTiCgatUP57qVS
auth_attempts: 5
http_proxy: ""
dns:
  bind_hosts:
    - 0.0.0.0
  port: 3053
  upstream_dns:
    - 8.8.8.8
    - 9.9.9.9
  upstream_dns_file: ""
  bootstrap_dns:
    - 9.9.9.10
    - 149.112.112.10
  upstream_mode: load_balance
  cache_optimistic_answer_ttl: 30s
filters:
  - enabled: true
    url: https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: false
    url: https://adaway.org/hosts.txt
    name: AdAway Default Blocklist
    id: 2
whitelist_filters: []
user_rules: []
filtering:
  blocking_mode: default
  rewrites: []
  safe_fs_patterns:
    - /etc/AdGuardHome/data/userfilters/*
  filters_update_interval: 24
  rewrites_enabled: true
schema_version: 33
YAML
}

# --- the stub "router" ------------------------------------------------------

# Emulates `ssh pi@pi1.local 'ssh arr-stack-router sh -s'`: stdin is the script,
# which runs for real with $STUB_DIR first on PATH and the real cp/mv/cmp.
_fake_ssh_body() {
    cat <<'BODY'
script=$(cat)
mkdir -p "$STUB_DIR/remote"

# AGH_STUB_SSH_FAIL makes the first N connections fail the way `.local` name
# resolution does on this Mac: worked, then "could not resolve hostname" one
# second later, then worked again.
if [ -n "${AGH_STUB_SSH_FAIL:-}" ]; then
    n=$(cat "$STUB_DIR/ssh-calls" 2>/dev/null || echo 0)
    n=$((n + 1)); printf '%s' "$n" > "$STUB_DIR/ssh-calls"
    if [ "$n" -le "$AGH_STUB_SSH_FAIL" ]; then
        printf '%s\n' "ssh: Could not resolve hostname pi1.local: nodename nor servname provided, or not known" >&2
        exit 255
    fi
fi

printf '%s\n' "$script" >> "$STUB_DIR/remote/all"

# The one line this stub refuses to execute. See the file header.
if printf '%s\n' "$script" | grep -q 'restart'; then
    printf '%s\n' "$script" | grep 'restart' >> "$STUB_DIR/remote/restarts"
fi
exec_script=$(printf '%s\n' "$script" | awk -v rc="${AGH_STUB_RESTART_RC:-0}" \
    '/restart/ { print "exit " rc; next } { print }')

PATH="$STUB_DIR:$PATH" sh -c "$exec_script"
BODY
}

_fake_dig_body() {
    cat <<'BODY'
name=""
wants_port=0
for a in "$@"; do
    case "$a" in
        +*) ;;
        @*) ;;
        -p) wants_port=1 ;;
        *) if [ "$wants_port" = "1" ]; then wants_port=0
           elif [ -z "$name" ]; then name="$a"; fi ;;
    esac
done

calls="$STUB_DIR/dig-calls"
n=$(cat "$calls" 2>/dev/null || echo 0)
n=$((n + 1)); printf '%s' "$n" > "$calls"
if [ "$n" -le "${AGH_STUB_DIG_FAIL:-0}" ]; then exit 1; fi

case "$name" in
    sonarr.lan)      printf '%s\n' "${AGH_STUB_SONARR:-192.168.110.250}" ;;
    doubleclick.net) printf '%s\n' "${AGH_STUB_BLOCKED:-0.0.0.0}" ;;
    # `-` and not `:-`: the test that wants an unanswered public name sets this
    # to the empty string, and `:-` would substitute the default instead and
    # quietly pass against a resolver that answered.
    example.com)     printf '%s\n' "${AGH_STUB_PUBLIC-93.184.216.34}" ;;
    *)               printf '\n' ;;
esac
BODY
}

_fake_uci_body() {
    cat <<'BODY'
[ "${1:-}" = "-q" ] && shift
case "${1:-}" in
    get)
        # AGH_FLIP_DNS_ENABLED_ON_READ=<n> changes the flag on the nth read of
        # it, which is the only way to reproduce "something else moved the house
        # while this script was installing". The CLI reads it once before writing
        # anything and once after, and only a difference between the two says so.
        # The counting and the mutation live here; the value itself still comes
        # out of uci.state, so the fixture stays the single source for it.
        if [ "$2" = "adguardhome.config.dns_enabled" ] && [ -n "${AGH_FLIP_DNS_ENABLED_ON_READ:-}" ]; then
            n=$(cat "$STUB_DIR/uci.reads" 2>/dev/null || echo 0)
            n=$((n + 1))
            printf '%s\n' "$n" > "$STUB_DIR/uci.reads"
            if [ "$n" -eq "$AGH_FLIP_DNS_ENABLED_ON_READ" ]; then
                printf 'adguardhome.config.dns_enabled=0\n' > "$STUB_DIR/uci.state"
            fi
        fi
        sed -n "s/^$2=//p" "$STUB_DIR/uci.state" | head -1 ;;
    *) : ;;
esac
BODY
}

# The real md5sum (whose path is passed in, because by the time this body runs
# the name resolves to this very stub), with one override: AGH_STUB_MD5_STAGE
# forces a wrong hash for the staged file, which is how a truncated transfer is
# reproduced.
_fake_md5sum_body() {
    cat <<BODY
if [ -n "\${AGH_STUB_MD5_STAGE:-}" ] && [ "\$1" = "\$AGH_STAGE" ]; then
    printf '%s\n' "\$AGH_STUB_MD5_STAGE"
    exit 0
fi
exec '$1' "\$@"
BODY
}

_fake_check_body() {
    cat <<'BODY'
path=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -c) shift; path="${1:-}" ;;
    esac
    shift
done
if [ "${AGH_STUB_CHECK_RC:-0}" = "0" ] && [ -s "$path" ]; then
    printf '%s\n' '2026/09/19 20:04:47 [info] configuration file is ok'
    exit 0
fi
printf '%s\n' '2026/09/19 20:04:56 [error] failed to parse configuration file' >&2
exit "${AGH_STUB_CHECK_RC:-1}"
BODY
}

configure() { run "$SCRIPT" "$@"; }

remote_log="$STUB_DIR/remote/all"
restart_log="$STUB_DIR/remote/restarts"

remote_wrote() {  # did any router script write to a path?
    [ -f "$remote_log" ] && grep -q "$1" "$remote_log"
}

backup_count() {
    local n
    n=$(ls -d "$AGH_CONFIG".bak-* 2>/dev/null | wc -l | tr -d ' ')
    printf '%s' "${n:-0}"
}

# --- the dry run ------------------------------------------------------------

@test "adguard-configure: the dry run prints what would change and touches nothing" {
    BEFORE=$(md5sum "$AGH_CONFIG" | cut -d' ' -f1)

    configure --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    # What changes, named: the upstreams, the rewrites, the filter.
    [[ "$output" == *"https://dns.quad9.net/dns-query"* ]]
    [[ "$output" == *"sonarr.lan"* ]]
    [[ "$output" == *"StevenBlack"* ]]

    # Nothing was staged, validated, backed up or restarted, and the only thing
    # that crossed the wire was the read.
    ! remote_wrote 'cat >'
    assert_stub_not_called AdGuardHome "--check-config"
    [ ! -s "$restart_log" ] || fail "the dry run restarted the service"
    [ "$(backup_count)" -eq 0 ]
    [ "$(md5sum "$AGH_CONFIG" | cut -d' ' -f1)" = "$BEFORE" ]
    [ "$(grep -c '^ssh' "$STUB_LOG" || true)" -eq 1 ]
}

@test "adguard-configure: the dry run reports no change when there is none" {
    configure
    [ "$status" -eq 0 ]

    : > "$STUB_LOG"
    : > "$remote_log"
    configure --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"no change"* ]]
    ! remote_wrote 'cat >'
    [ "$(grep -c '^ssh' "$STUB_LOG" || true)" -eq 1 ]
}

# --- applying ---------------------------------------------------------------

@test "adguard-configure: it installs the transformed config after validating it" {
    configure
    [ "$status" -eq 0 ]

    grep -qF '    - https://dns.quad9.net/dns-query' "$AGH_CONFIG"
    grep -qF '    - https://cloudflare-dns.com/dns-query' "$AGH_CONFIG"
    grep -q '^    - domain: sonarr.lan$' "$AGH_CONFIG"
    grep -qF '    url: https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts' "$AGH_CONFIG"
    ! grep -q '^    - 8.8.8.8$' "$AGH_CONFIG"

    # Validated before installation, and the original is recoverable.
    assert_stub_called AdGuardHome "--check-config"
    [[ "$output" == *"configuration file is ok"* ]]
    [ "$(backup_count)" -eq 1 ]
    local backup
    backup=$(ls "$AGH_CONFIG".bak-* | head -1)
    cmp -s "$backup" "$ORIG" || fail "the backup is not the original config"
    [[ "$output" == *"$backup"* ]]

    # And the five things the run has to prove, reported in order.
    [[ "$output" == *"ok: sonarr.lan -> 192.168.110.250"* ]]
    [[ "$output" == *"ok: doubleclick.net -> 0.0.0.0"* ]]
    [[ "$output" == *"ok: example.com"* ]]
    # The value is asserted back, not the literal 0: this script must leave the
    # dispatcher flag where it found it, and what it finds it at is 1 now that
    # the migration is live. Asserting 0 here made a correct run print FAIL.
    [[ "$output" == *"ok: dns_enabled is still 0, so this run did not move any client's queries"* ]]

    assert_nothing_forbidden
}

@test "adguard-configure: every router command arrives on stdin, never in argv" {
    configure
    [ "$status" -eq 0 ]

    local bad
    bad=$(grep '^ssh' "$STUB_LOG" | grep -v 'sh -s$' || true)
    [ -z "$bad" ] || fail "an ssh call did not use the sh -s form: $bad"
    # The scripts really did go over: the validator ran on the router.
    grep -q 'check-config' "$remote_log"
}

@test "adguard-configure: running it a second time writes nothing and restarts nothing" {
    configure
    [ "$status" -eq 0 ]

    local backups restarts cfg
    backups=$(backup_count)
    restarts=$(grep -c 'restart' "$restart_log" || true)
    cfg=$(md5sum "$AGH_CONFIG" | cut -d' ' -f1)
    : > "$STUB_LOG"

    configure
    [ "$status" -eq 0 ]
    [[ "$output" == *"no change"* ]]

    [ "$(backup_count)" -eq "$backups" ] || fail "a second backup was written on a no-op run"
    [ "$(grep -c 'restart' "$restart_log" || true)" -eq "$restarts" ] || fail "the service was restarted again"
    [ "$(md5sum "$AGH_CONFIG" | cut -d' ' -f1)" = "$cfg" ]
    # One read and nothing else.
    [ "$(grep -c '^ssh' "$STUB_LOG" || true)" -eq 1 ]
    [ "$(grep -c '^AdGuardHome' "$STUB_LOG" || true)" -eq 0 ]
}

# --- the refusals that protect the live file --------------------------------

@test "adguard-configure: a config that fails --check-config is never installed" {
    run env AGH_STUB_CHECK_RC=1 "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"check-config"* ]]

    cmp -s "$AGH_CONFIG" "$ORIG" || fail "a config that failed validation was left in place"
    [ "$(backup_count)" -eq 0 ] || fail "the original was backed up before it was known to be needed"
    [ ! -s "$restart_log" ] || fail "the service was restarted with an unvalidated config"
    [ ! -e "$AGH_STAGE" ] || fail "the staged file was left on the router"
}

@test "adguard-configure: a truncated transfer is caught before installation" {
    # The hash of what landed on the router is compared with the hash of what
    # was transformed here. A heredoc that lost a line is otherwise invisible.
    run env AGH_STUB_MD5_STAGE=00000000000000000000000000000000 "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"md5"* || "$output" == *"byte"* ]]
    cmp -s "$AGH_CONFIG" "$ORIG" || fail "a config that did not survive the transfer was installed"
    [ ! -e "$AGH_STAGE" ]
}

@test "adguard-configure: an empty live config is refused before anything is pushed" {
    : > "$BATS_TEST_TMPDIR/empty.yaml"
    run env AGH_CONFIG="$BATS_TEST_TMPDIR/empty.yaml" AGH_STAGE="$BATS_TEST_TMPDIR/empty.yaml.incoming" \
        "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"empty"* ]]
    [ "$(grep -c 'cat >' "$remote_log" 2>/dev/null || true)" -eq 0 ]
}

@test "adguard-configure: a live config the transform cannot edit is refused, not half-written" {
    sed '/^  upstream_dns:$/,/^  upstream_dns_file:/{/^  upstream_dns:$/d;/^    - /d;}' \
        "$ORIG" > "$ROUTER_ROOT/etc/AdGuardHome/config.yaml"
    local before
    before=$(md5sum "$AGH_CONFIG" | cut -d' ' -f1)

    configure
    [ "$status" -eq 2 ]
    [[ "$output" == *"upstream_dns"* ]]
    [ "$(md5sum "$AGH_CONFIG" | cut -d' ' -f1)" = "$before" ]
    ! remote_wrote 'cat >'
}

@test "adguard-configure: a name record with no hostnames is refused" {
    printf 'address=/lan/::\n' > "$BATS_TEST_TMPDIR/nonames.conf"
    run env AGH_DNSMASQ_CONF="$BATS_TEST_TMPDIR/nonames.conf" "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"hostname"* ]]
    ! remote_wrote 'cat >'
}

# --- the live verification --------------------------------------------------

@test "adguard-configure: a rewrite that answers the wrong address fails the run" {
    run env AGH_STUB_SONARR=10.0.0.9 "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"sonarr.lan"* ]]
    [[ "$output" == *"10.0.0.9"* ]]
}

@test "adguard-configure: blocking that does not block fails the run" {
    run env AGH_STUB_BLOCKED=93.184.216.34 "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"doubleclick.net"* ]]
}

@test "adguard-configure: an encrypted upstream that does not resolve fails the run" {
    run env AGH_STUB_PUBLIC= "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"example.com"* ]]
}

@test "adguard-configure: a live router whose flag is already 1 is not a failure" {
    # The migration's end state, and the one that used to fail: Phase 3 asserted
    # dns_enabled was still 0, so once the house genuinely moved onto AdGuard
    # every correct run ended in FAIL immediately after installing the config.
    # Reading it before the change and comparing after keeps the property that
    # mattered -- this script does not move the house -- without pinning a value
    # the migration deliberately changed.
    # The state has to be written before the run, not passed as a prefix: the uci
    # stub answers from $STUB_DIR/uci.state, which setup() seeds from DNS_ENABLED
    # once, and a prefix on the call would arrive too late to reach it.
    printf 'adguardhome.config.dns_enabled=1\n' > "$STUB_DIR/uci.state"
    configure
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"ok: dns_enabled is still 1, so this run did not move any client's queries"* ]]
}

@test "adguard-configure: dns_enabled moving during the run fails it" {
    # The tripwire the check exists for. The stub flips the value the moment the
    # run asks for it the second time, which is what "something changed who
    # answers while this script was writing config" looks like from here.
    printf 'adguardhome.config.dns_enabled=1\n' > "$STUB_DIR/uci.state"
    DNS_ENABLED=1 AGH_FLIP_DNS_ENABLED_ON_READ=2 configure
    [ "$status" -ne 0 ]
    [[ "$output" == *"dns_enabled moved from"* ]]
}

@test "adguard-configure: a resolver that is a moment late is polled, not probed once" {
    # Measured on this build: the DNS proxy comes up a second or two after the
    # web UI, so a single probe after a restart reports "does not answer" for a
    # resolver that is fine moments later.
    run env AGH_STUB_DIG_FAIL=2 "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^dig' "$STUB_LOG" || true)" -gt 3 ]
    assert_stub_called dig "-p 3053"
}

@test "adguard-configure: a restart that fails fails the run" {
    run env AGH_STUB_RESTART_RC=1 "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"restart"* ]]
}

@test "adguard-configure: a read that fails once is retried, not reported as a dead router" {
    # Measured on this Mac: `ssh pi@pi1.local` answering "Could not resolve
    # hostname" and then working a second later. A read is safe to repeat; a
    # half-completed write is not, which is why only the read is retried.
    run env AGH_STUB_SSH_FAIL=1 "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"retrying"* ]]
    grep -qF 'https://dns.quad9.net/dns-query' "$AGH_CONFIG"
}

@test "adguard-configure: a read that never succeeds is still a refusal, and writes nothing" {
    local before
    before=$(md5sum "$AGH_CONFIG" | cut -d' ' -f1)
    run env AGH_STUB_SSH_FAIL=9 "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not read"* ]]
    ! remote_wrote 'cat >'
    [ "$(md5sum "$AGH_CONFIG" | cut -d' ' -f1)" = "$before" ]
}
