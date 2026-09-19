#!/usr/bin/env bats
# scripts/dns-rollback.sh
#
# The rollback script is the one artifact that has to work while the house's DNS
# is broken, so its guards are tested rather than reasoned about. Two of them
# are the exact failures the plan's review record names:
#
#   * the maintenance pool `lan` being left out of the loop, which strands the
#     break-glass host on a resolver that is being retired;
#   * the self-check passing while a pool still advertises the wrong resolver,
#     which is what happens when it only asks whether DNS answers somewhere.
#
# Everything runs against a stub `uci` backed by a file in $BATS_TEST_TMPDIR.
# The stub carries the same guard as every other one here, so no test can reach
# a real router.

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init
    SCRIPT="$REPO_ROOT/scripts/dns-rollback.sh"

    stub_tool uci "$(_fake_uci_body)"
    stub_tool dnsmasq-init 'exit 0'
    stub_tool firewall-init 'exit 0'
    stub_tool dig 'printf "93.184.216.34\n"'

    DNSMASQ_INIT="$STUB_DIR/dnsmasq-init"
    FIREWALL_INIT="$STUB_DIR/firewall-init"
    export DNSMASQ_INIT FIREWALL_INIT
}

# A stand-in for uci with just the verbs the rollback script uses, backed by a
# `key=value` file. UCI_STUB_DROP_KEY makes one key silently ignore add_list,
# which is how a change that does not take effect is reproduced — the shape of
# failure the self-check exists to catch.
_fake_uci_body() {
    cat <<'BODY'
state="$STUB_DIR/uci.state"
[ -f "$state" ] || : > "$state"
# `-c <dir>` is what the script uses for a rehearsal against a scratch config
# dir. The stub logs the raw argv, so tests can still assert it was passed.
if [ "${1:-}" = "-c" ]; then shift 2; fi
quiet=0
[ "${1:-}" = "-q" ] && { quiet=1; shift; }
cmd="${1:-}"; shift || true
case "$cmd" in
    get)
        key="$1"
        if grep -q "^${key}=" "$state"; then
            sed -n "s/^${key}=//p" "$state" | head -1
        else
            [ "$quiet" = "1" ] || echo "uci: Entry not found" >&2
            exit 1
        fi
        ;;
    delete)
        key="$1"
        if [ -n "${UCI_STUB_DROP_KEY:-}" ] && [ "$key" = "$UCI_STUB_DROP_KEY" ]; then
            exit 0
        fi
        grep -v "^${key}=" "$state" > "$state.new" || true
        mv "$state.new" "$state"
        ;;
    set)
        kv="$1"; key="${kv%%=*}"; val="${kv#*=}"
        grep -v "^${key}=" "$state" > "$state.new" || true
        mv "$state.new" "$state"
        printf '%s=%s\n' "$key" "$val" >> "$state"
        ;;
    add_list)
        kv="$1"; key="${kv%%=*}"; val="${kv#*=}"
        if [ -n "${UCI_STUB_DROP_KEY:-}" ] && [ "$key" = "$UCI_STUB_DROP_KEY" ]; then
            exit 0
        fi
        if grep -q "^${key}=" "$state"; then
            old=$(sed -n "s/^${key}=//p" "$state" | head -1)
            grep -v "^${key}=" "$state" > "$state.new" || true
            mv "$state.new" "$state"
            printf '%s=%s %s\n' "$key" "$old" "$val" >> "$state"
        else
            printf '%s=%s\n' "$key" "$val" >> "$state"
        fi
        ;;
    commit)
        ;;
    *)
        echo "uci: unknown command: $cmd" >&2
        exit 1
        ;;
esac
BODY
}

state_get() {
    sed -n "s/^$1=//p" "$STUB_DIR/uci.state" | head -1
}

# The state after Phase 5, which is when a rollback is actually needed: every
# pool pointed at its own VLAN's router address.
seed_migrated() {
    : > "$STUB_DIR/uci.state"
    {
        printf '%s\n' 'dhcp.lan.dhcp_option=6,192.168.8.1'
        printf '%s\n' 'dhcp.vlan10.dhcp_option=6,192.168.110.1'
        printf '%s\n' 'dhcp.vlan20.dhcp_option=6,192.168.120.1'
        printf '%s\n' 'dhcp.vlan30.dhcp_option=6,192.168.130.1'
    } >> "$STUB_DIR/uci.state"
}

# The state at baseline, which is what a rollback leaves behind.
seed_baseline() {
    : > "$STUB_DIR/uci.state"
    for pool in lan vlan10 vlan20 vlan30; do
        printf 'dhcp.%s.dhcp_option=6,192.168.110.246\n' "$pool" >> "$STUB_DIR/uci.state"
    done
}

# --- coverage ---------------------------------------------------------------

@test "dns-rollback: all four pools are reverted, not just lan" {
    seed_migrated
    run env sh "$SCRIPT"
    [ "$status" -eq 0 ]

    for pool in lan vlan10 vlan20 vlan30; do
        assert_stub_called uci "add_list dhcp.$pool.dhcp_option=6,192.168.110.246"
        [ "$(state_get "dhcp.$pool.dhcp_option")" = "6,192.168.110.246" ] || {
            echo "$pool ended up as: $(state_get "dhcp.$pool.dhcp_option")"
            return 1
        }
    done
    assert_nothing_forbidden
}

@test "dns-rollback: dnsmasq is reloaded after the commit" {
    seed_migrated
    run env sh "$SCRIPT"
    [ "$status" -eq 0 ]

    # Without this the pools are reverted in flash and dnsmasq keeps serving the
    # old rendered config while the script reports success.
    assert_stub_called dnsmasq-init "reload"

    local commit_line dnsmasq_line
    commit_line=$(grep -n "^uci"$'\t'"commit dhcp" "$STUB_LOG" | head -1 | cut -d: -f1)
    dnsmasq_line=$(grep -n "^dnsmasq-init" "$STUB_LOG" | head -1 | cut -d: -f1)
    [ -n "$commit_line" ] && [ -n "$dnsmasq_line" ]
    [ "$dnsmasq_line" -gt "$commit_line" ] || {
        echo "dnsmasq reload at line $dnsmasq_line, commit dhcp at $commit_line"
        return 1
    }
}

@test "dns-rollback: every uci commit names its package" {
    seed_migrated
    run env sh "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_stub_called uci "commit dhcp"
    assert_stub_called uci "commit adguardhome"
    assert_stub_called uci "commit firewall"

    # A bare `uci commit` commits every half-applied change in every config file.
    if grep -q "^uci"$'\t'"commit$" "$STUB_LOG"; then
        echo "a bare 'uci commit' was issued:"; cat "$STUB_LOG"
        return 1
    fi
}

# --- the self-check ---------------------------------------------------------

@test "dns-rollback: a pool left un-reverted fails the script" {
    seed_migrated
    UCI_STUB_DROP_KEY="dhcp.vlan20.dhcp_option"
    export UCI_STUB_DROP_KEY

    run env sh "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL: vlan20 does not advertise 192.168.110.246"* ]]
    [[ "$output" == *"ROLLBACK INCOMPLETE"* ]]
    # The other three are still reported as fine - the check has to name the one
    # pool that is wrong, not just fail.
    [[ "$output" == *"ok: lan advertises 192.168.110.246"* ]]
}

@test "dns-rollback: an unanswering NAS resolver fails the script" {
    seed_migrated
    stub_tool dig 'exit 1'

    run env sh "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL: 192.168.110.246 is not answering"* ]]
}

# --- the pre-flight refusal -------------------------------------------------

@test "dns-rollback: a foreign dhcp_option is refused, and nothing is written" {
    seed_baseline
    # A list value carrying a second option: one token is ours, one is not.
    grep -v '^dhcp.vlan30.dhcp_option=' "$STUB_DIR/uci.state" > "$STUB_DIR/uci.state.new"
    mv "$STUB_DIR/uci.state.new" "$STUB_DIR/uci.state"
    printf '%s\n' 'dhcp.vlan30.dhcp_option=6,192.168.110.246 42,203.0.113.9' >> "$STUB_DIR/uci.state"

    run env sh "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"REFUSING"* ]]
    [[ "$output" == *"42,203.0.113.9"* ]]

    # Checked before anything is touched, so a refusal leaves the router as it
    # was found rather than half-reverted.
    assert_stub_not_called uci "add_list"
    assert_stub_not_called uci "commit"
    assert_stub_not_called dnsmasq-init "reload"
    [ "$(state_get dhcp.lan.dhcp_option)" = "6,192.168.110.246" ]
}

# --- rehearsal --------------------------------------------------------------

@test "dns-rollback: DRY_RUN prints the sequence and changes nothing" {
    seed_migrated
    run env DRY_RUN=1 sh "$SCRIPT"
    [ "$status" -eq 0 ]

    for pool in lan vlan10 vlan20 vlan30; do
        [[ "$output" == *"DRY-RUN: uci -q delete dhcp.$pool.dhcp_option"* ]]
        [[ "$output" == *"DRY-RUN: uci add_list dhcp.$pool.dhcp_option=6,192.168.110.246"* ]]
    done
    [[ "$output" == *"DRY-RUN: $DNSMASQ_INIT reload"* ]]
    [[ "$output" == *"DRY-RUN: $FIREWALL_INIT reload"* ]]
    [[ "$output" == *"DRY-RUN complete"* ]]

    assert_stub_not_called uci "commit"
    assert_stub_not_called dnsmasq-init "reload"
    [ "$(state_get dhcp.lan.dhcp_option)" = "6,192.168.8.1" ]
}

@test "dns-rollback: DRY_RUN does not report a self-check result" {
    seed_migrated
    run env DRY_RUN=1 sh "$SCRIPT"
    [ "$status" -eq 0 ]
    # A rehearsal that printed "ok: lan advertises ..." would be reporting on a
    # check it never ran.
    [[ "$output" != *"ok: "* ]]
    [[ "$output" != *"ROLLBACK INCOMPLETE"* ]]
}

# --- the scratch config dir -------------------------------------------------
#
# This is the rehearsal path from 0.5, and it is the one that went wrong on the
# live router: `UCI_CONFIG_DIR` is accepted by uci and ignored, so a rehearsal
# written that way writes to /etc/config. Every uci call has to carry `-c`.

@test "dns-rollback: UCI_CONF is passed to every uci call as -c" {
    seed_migrated
    UCI_CONF="/tmp/dns-rehearsal-config"
    export UCI_CONF

    run env sh "$SCRIPT"
    [ "$status" -eq 0 ]

    assert_stub_called uci "-c /tmp/dns-rehearsal-config -q get dhcp.lan.dhcp_option"
    assert_stub_called uci "-c /tmp/dns-rehearsal-config commit dhcp"
    assert_stub_called uci "-c /tmp/dns-rehearsal-config commit adguardhome"
    # And nothing may reach uci without it.
    if grep -q "^uci"$'\t'"-q get" "$STUB_LOG" || grep -q "^uci"$'\t'"commit" "$STUB_LOG"; then
        echo "a uci call went out without -c:"; cat "$STUB_LOG"
        return 1
    fi
}

@test "dns-rollback: DRY_RUN shows the -c in the commands it prints" {
    seed_migrated
    UCI_CONF="/tmp/dns-rehearsal-config"
    export UCI_CONF

    run env DRY_RUN=1 sh "$SCRIPT"
    [ "$status" -eq 0 ]
    # The transcript has to be the command that would actually run. Printing
    # `uci_` or dropping `-c` would describe a run against the live config.
    [[ "$output" == *"DRY-RUN: uci -c /tmp/dns-rehearsal-config -q delete dhcp.lan.dhcp_option"* ]]
    [[ "$output" == *"DRY-RUN: uci -c /tmp/dns-rehearsal-config commit dhcp"* ]]
}
