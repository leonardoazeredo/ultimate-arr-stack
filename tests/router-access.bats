#!/usr/bin/env bats
# tests/helpers/router.bash
#
# Two things in that helper are worth proving rather than trusting:
#
#   * the refusal that stops a test from writing to the router. It has to fire
#     BEFORE a connection is opened, not after — a guard that runs the command
#     and then complains about it is not a guard. 2026-09-19 is the reason it
#     exists at all: a rehearsal wrote `dhcp.lan.dhcp_option` into live
#     /etc/config because a scratch config directory was not being honoured.
#   * the address derivation. Every live assertion then depends on querying the
#     right router interface, and picking the wrong one does not fail — it
#     quietly asks a different interface the same question.
#
# No router and no network are involved. `ssh` and `ip` are stubs on PATH under
# $BATS_TEST_TMPDIR, so this file produces a verdict on any host, which is what
# lets the mutation corpus score it.
#
# Two traps in writing it, both hit and fixed rather than guessed at:
#   * `printf ... | source file` runs `source` in a pipeline subshell, so the
#     helper is never defined in the shell that then calls it. Sourcing comes
#     first, the pipe second.
#   * `run some_function` runs it in a subshell, so the globals it sets
#     (ROUTER_PATH, ROUTER_SSH_ERR) are discarded. Those tests call the function
#     plainly and assert on the status themselves.

ROUTER_HELPER="$BATS_TEST_DIRNAME/helpers/router.bash"

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init

    source "$ROUTER_HELPER"
    ROUTER_PATH=""
    ROUTER_SSH_ERR=""
    export ROUTER_JUMP ROUTER_SSH_TARGET

    stub_tool ssh "$(_ssh_stub_body)"
    stub_tool ip 'printf "%s\n" "2: eth0    inet 192.168.120.135/24 brd 192.168.120.255 scope global eth0"'

    # What the router answers to a read-only command.
    printf '%s\n' "192.168.8.1" "192.168.120.1" > "$STUB_DIR/router-reply"
}

# A stand-in for ssh that can be told which paths work, so the probe's fallback
# is exercised rather than assumed.
_ssh_stub_body() {
    cat <<'BODY'
script=$(cat 2>/dev/null || true)
mode="${SSH_STUB_MODE:-both}"
case "$mode" in
    none)
        echo "ssh: connect to host arr-stack-router port 22: Connection refused" >&2
        exit 255
        ;;
    jump-only)
        case "$*" in
            *"${ROUTER_JUMP}"*) ;;
            *)
                echo "ssh: connect to host arr-stack-router port 22: Connection refused" >&2
                exit 255
                ;;
        esac
        ;;
esac
case "$script" in
    *router-ok*) printf '%s\n' router-ok; exit 0 ;;
esac
[ -f "$STUB_DIR/router-reply" ] && cat "$STUB_DIR/router-reply"
exit 0
BODY
}

# Send a script through the helper in a shell where it is actually defined.
router_run_script() {
    run bash -c 'source "$1"; printf "%s\n" "$2" | router_sh' _ "$ROUTER_HELPER" "$1"
}

# --- the refusal ------------------------------------------------------------

@test "router-access: a mutating script is refused before any connection" {
    # The stub is told every path fails. If the refusal happened after
    # connecting, this would come back as a failed connection (1) rather than a
    # refusal (99) - the two are told apart on purpose.
    SSH_STUB_MODE=none
    export SSH_STUB_MODE

    router_run_script "uci set dhcp.lan.dhcp_option=6,10.0.0.1"
    [ "$status" -eq 99 ]
    [[ "$output" == *"REFUSING"* ]]

    # And it never opened a connection to find that out.
    assert_stub_not_called ssh "arr-stack-router"
}

@test "router-access: a service reload is refused" {
    SSH_STUB_MODE=none
    export SSH_STUB_MODE

    router_run_script "/etc/init.d/dnsmasq reload"
    [ "$status" -eq 99 ]
    [[ "$output" == *"REFUSING"* ]]
}

@test "router-access: an iptables insert is refused" {
    SSH_STUB_MODE=none
    export SSH_STUB_MODE

    router_run_script "iptables -t nat -I adg_redirect 1 -j REDIRECT --to-ports 3053"
    [ "$status" -eq 99 ]
}

@test "router-access: a reboot is refused" {
    SSH_STUB_MODE=none
    export SSH_STUB_MODE

    router_run_script "reboot"
    [ "$status" -eq 99 ]
}

@test "router-access: a qualified uci set is refused, not just the bare form" {
    # `uci -q set` is how the qualified form would actually be written, and a
    # rule that only matches `uci set` catches the form nobody uses.
    SSH_STUB_MODE=none
    export SSH_STUB_MODE

    router_run_script "uci -q set dhcp.lan.dhcp_option=6,10.0.0.1"
    [ "$status" -eq 99 ]
    [[ "$output" == *"REFUSING"* ]]
}

@test "router-access: add_list is refused" {
    # This is the verb the rollback script uses to write a pool's resolver. A
    # deny list that covers `set` but not `add_list` covers half the hazard.
    SSH_STUB_MODE=none
    export SSH_STUB_MODE

    router_run_script "uci add_list dhcp.lan.dhcp_option=6,10.0.0.1"
    [ "$status" -eq 99 ]
}

@test "router-access: a read-only script is not refused and does run" {
    SSH_STUB_MODE=both
    export SSH_STUB_MODE

    router_run_script "uci show dhcp"
    [ "$status" -eq 0 ]
    [[ "$output" == *"192.168.8.1"* ]]
    assert_stub_called ssh "arr-stack-router"
}

# --- the two ways in --------------------------------------------------------

@test "router-access: the direct path is preferred when it works" {
    SSH_STUB_MODE=both
    export SSH_STUB_MODE

    router_probe
    [ "$ROUTER_PATH" = "direct" ] || fail "expected the direct path, got '${ROUTER_PATH:-<none>}': $ROUTER_SSH_ERR"
}

@test "router-access: the probe falls back to the jump host" {
    SSH_STUB_MODE=jump-only
    export SSH_STUB_MODE

    router_probe
    [ "$ROUTER_PATH" = "jump" ] || fail "expected the jump path, got '${ROUTER_PATH:-<none>}': $ROUTER_SSH_ERR"
    # The jump path has to name the target inside the remote command; a probe
    # that only reached pi1 would report success while measuring the wrong box.
    assert_stub_called ssh "arr-stack-router"
}

@test "router-access: no route at all is reported, not swallowed" {
    SSH_STUB_MODE=none
    export SSH_STUB_MODE

    router_probe && fail "expected the probe to fail with no route at all"
    [ -z "$ROUTER_PATH" ]
    # The skip reason depends on this text; an empty one turns "the router is
    # unreachable" into an unexplained skip.
    [[ -n "$ROUTER_SSH_ERR" ]] || fail "the failure left no error text for the skip reason"
    [[ "$ROUTER_SSH_ERR" == *"Connection refused"* ]]
}

# --- address derivation -----------------------------------------------------

@test "router-access: the host's own addresses exclude only loopback" {
    run host_ipv4_addrs
    assert_success
    [[ "$output" == *"192.168.120.135"* ]]
}

@test "router-access: the router address is the one sharing a subnet with this host" {
    # host is 192.168.120.135; the router offers 192.168.8.1 and 192.168.120.1.
    run router_ip_for_host
    assert_success
    [ "$output" = "192.168.120.1" ]
}

@test "router-access: no shared subnet yields no address rather than a wrong one" {
    printf '%s\n' "192.168.8.1" "192.168.110.1" > "$STUB_DIR/router-reply"
    run router_ip_for_host
    assert_failure
    [ -z "$output" ]
}

@test "router-access: a router interface on another VLAN is not silently substituted" {
    # Guard against the tempting shortcut of falling back to the first address
    # the router reports: from VLAN20 that is 192.168.8.1, which is reachable
    # but is not the interface a client here queries.
    printf '%s\n' "192.168.130.1" > "$STUB_DIR/router-reply"
    run router_ip_for_host
    assert_failure
    [[ "$output" != *"192.168.130.1"* ]]
}
