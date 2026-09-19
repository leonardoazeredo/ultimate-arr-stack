#!/usr/bin/env bats
# router/adguard-stage.sh
#
# This script enables a service that answers DNS for the whole house, and it
# does so while `users:` is still empty in the config. The two properties worth
# proving are therefore both about what it refuses to do:
#
#   * it must not start an instance it has no credential for. An AdGuard Home
#     with `users: []` is an admin API that can rewrite or block any domain for
#     every client, and the maintenance VLAN reaches port 3000 in 6 ms;
#   * it must not move `dns_enabled`. That flag installs the firewall redirect
#     that sends :53 to AdGuard, and Phase 2 stages a resolver rather than
#     putting one in the path. A staging script that silently cuts the house
#     over would be a Phase 6 change with none of Phase 3 behind it.
#
# No router is involved. `uci`, `curl`, `dig` and the init script are stubs on
# PATH under $BATS_TEST_TMPDIR, so this file produces a verdict on any host.

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init
    SCRIPT="$REPO_ROOT/router/adguard-stage.sh"

    stub_tool uci "$(_fake_uci_body)"
    stub_tool curl "$(_fake_curl_body)"
    stub_tool dig 'printf "93.184.216.34\n"'
    stub_tool adguardhome-init 'exit 0'

    AGH_INIT="$STUB_DIR/adguardhome-init"
    AGH_CONFIG="$BATS_TEST_TMPDIR/config.yaml"
    export AGH_INIT AGH_CONFIG

    # A config shaped like the shipped one: populated, DNS pointed at 3053, and
    # with no admin user.
    cat > "$AGH_CONFIG" <<'YAML'
http:
  address: 0.0.0.0:3000
  session_ttl: 720h
users: []
auth_attempts: 5
dns:
  bind_hosts:
    - 0.0.0.0
  port: 3053
YAML

    : > "$STUB_DIR/uci.state"
    printf 'adguardhome.config.enabled=%s\n' "${ENABLED_BEFORE:-0}" >> "$STUB_DIR/uci.state"
    printf 'adguardhome.config.dns_enabled=%s\n' "${DNS_ENABLED_BEFORE:-0}" >> "$STUB_DIR/uci.state"
    export UCI_STATE="$STUB_DIR/uci.state"
}

_fake_uci_body() {
    cat <<'BODY'
state="$UCI_STATE"
read_after="${DNS_ENABLED_AFTER:-}"
count_file="$STUB_DIR/dns-enabled-reads"
cmd="${1:-}"; [ "$cmd" = "-q" ] && { shift; cmd="${1:-}"; shift; }
case "$cmd" in
    get)
        key="$1"
        if [ "$key" = "adguardhome.config.dns_enabled" ] && [ -n "$read_after" ]; then
            n=$(cat "$count_file" 2>/dev/null || echo 0)
            n=$((n + 1)); printf '%s' "$n" > "$count_file"
            if [ "$n" -gt 1 ]; then printf '%s\n' "$read_after"; exit 0; fi
        fi
        sed -n "s/^${key}=//p" "$state" | head -1
        ;;
    set)
        kv="$1"; key="${kv%%=*}"; val="${kv#*=}"
        grep -v "^${key}=" "$state" > "$state.new" || true
        mv "$state.new" "$state"
        printf '%s=%s\n' "$key" "$val" >> "$state"
        ;;
    commit) : ;;
    *) : ;;
esac
BODY
}

_fake_curl_body() {
    cat <<'BODY'
case "$*" in
    *control/login*)  printf '%s' "${LOGIN_CODE:-200}" ;;
    *control/status*) printf '%s' "${STATUS_CODE:-401}" ;;
    *) exit 0 ;;
esac
BODY
}

run_stage() {
    run env \
        ADMIN_PASSWORD_HASH="${ADMIN_PASSWORD_HASH-}" \
        ADMIN_PASSWORD="${ADMIN_PASSWORD-}" \
        AGH_CONFIG="$AGH_CONFIG" AGH_INIT="$AGH_INIT" \
        sh "$SCRIPT"
}

users_block_written() {
    grep -qE '^users:$' "$AGH_CONFIG"
}

# --- refuses to expose an unauthenticated admin API -------------------------

@test "adguard-stage: an unconfigured instance with no credential is refused" {
    run_stage
    [ "$status" -ne 0 ]
    [[ "$output" == *"no ADMIN_PASSWORD_HASH was given"* ]]

    # Refused BEFORE anything was enabled: a guard that starts the service and
    # then complains has already created the exposure it exists to prevent.
    assert_stub_not_called uci "set adguardhome.config.enabled=1"
    assert_stub_not_called adguardhome-init "restart"
    ! users_block_written
}

@test "adguard-stage: a hash without the password to verify it is refused too" {
    # Without the plaintext there is no way to prove the credential works, and a
    # file that looks right with a hash AdGuard cannot parse is a router with a
    # password nobody can use.
    ADMIN_PASSWORD_HASH='$2a$05$abcdefghijklmnopqrstuv'
    run_stage
    [ "$status" -ne 0 ]
    [[ "$output" == *"no ADMIN_PASSWORD was given"* ]]
}

@test "adguard-stage: a non-bcrypt hash is refused" {
    ADMIN_PASSWORD_HASH='plaintext-nonsense'
    ADMIN_PASSWORD='whatever'
    run_stage
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not a"*"bcrypt hash"* ]]
    ! users_block_written
}

# --- the credential actually lands ------------------------------------------

@test "adguard-stage: the user is written and a real login is required to pass" {
    ADMIN_PASSWORD_HASH='$2a$05$abcdefghijklmnopqrstuv'
    ADMIN_PASSWORD='a-temp-password'
    LOGIN_CODE=200
    STATUS_CODE=401
    export LOGIN_CODE STATUS_CODE

    run_stage
    [ "$status" -eq 0 ]
    users_block_written
    grep -q 'name: admin' "$AGH_CONFIG"
    # The hash is what AdGuard stores and what must land in the file. The
    # plaintext appearing here would mean the config holds a value no AdGuard
    # build can authenticate against, and a secret sitting in a world-readable
    # file on the router.
    grep -qE '^    password: \$2a\$' "$AGH_CONFIG" \
        || fail "the bcrypt hash was not written where AdGuard reads it: $(grep -n password "$AGH_CONFIG")"
    if grep -q 'a-temp-password' "$AGH_CONFIG"; then
        fail "the plaintext password was written into $AGH_CONFIG"
    fi
    [[ "$output" == *"logs in (HTTP 200 from /control/login)"* ]]
    [[ "$output" == *"an unauthenticated /control/status is refused"* ]]
}

@test "adguard-stage: a credential that cannot log in fails the run" {
    # The file looks correct and AdGuard rejects the password. Only the login
    # call can tell the difference, which is why the script makes it.
    ADMIN_PASSWORD_HASH='$2a$05$abcdefghijklmnopqrstuv'
    ADMIN_PASSWORD='wrong-password'
    LOGIN_CODE=403
    STATUS_CODE=401
    export LOGIN_CODE STATUS_CODE

    run_stage
    [ "$status" -ne 0 ]
    [[ "$output" == *"FAIL"* ]]
    [[ "$output" == *"logging in as 'admin' answered HTTP 403"* ]]
}

# --- the redirect must not move ---------------------------------------------

@test "adguard-stage: dns_enabled moving during the run fails it" {
    DNS_ENABLED_BEFORE=0
    DNS_ENABLED_AFTER=1
    ADMIN_PASSWORD_HASH='$2a$05$abcdefghijklmnopqrstuv'
    ADMIN_PASSWORD='a-temp-password'
    LOGIN_CODE=200
    STATUS_CODE=401
    export DNS_ENABLED_BEFORE DNS_ENABLED_AFTER LOGIN_CODE STATUS_CODE

    run_stage
    [ "$status" -ne 0 ]
    [[ "$output" == *"dns_enabled moved from '0' to '1'"* ]]
}

# --- rehearsal --------------------------------------------------------------

@test "adguard-stage: DRY_RUN prints the changes and touches nothing" {
    run env DRY_RUN=1 AGH_CONFIG="$AGH_CONFIG" AGH_INIT="$AGH_INIT" sh "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN: uci set adguardhome.config.enabled=1"* ]]
    [[ "$output" == *"DRY-RUN complete"* ]]
    assert_stub_not_called adguardhome-init "restart"
    ! users_block_written
    [ "$(sed -n 's/^adguardhome.config.enabled=//p' "$STUB_DIR/uci.state" | head -1)" = "0" ]
}
