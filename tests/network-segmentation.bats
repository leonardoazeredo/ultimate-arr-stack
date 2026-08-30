#!/usr/bin/env bats
# Live network segmentation tests — VLAN20 (personal) -> VLAN10 (services).
#
# Why this file exists: every other bats file here checks compose TEXT. Nothing
# checked the actual network, which is exactly how an unrestricted VLAN20->VLAN10
# forward survived unnoticed until a manual audit found it. These assert the
# router's allow-list as it actually behaves, from a host sitting on VLAN20.
#
# Vantage point: must run from a host with an address on VLAN20 (pi1). Anywhere
# else — CI runners, the NAS itself, a laptop on another VLAN — every test skips
# rather than failing, the same gate pattern tests/e2e/helpers.ts uses for Docker.
#
# The allow-list mirrors the router rules `vlan20-to-nas-svcs`,
# `vlan20-to-pihole-dns` and `vlan20-to-traefik`. If you change a rule, change
# this file in the same commit — a silent divergence here is worse than no test.
#
# NOT asserted, deliberately: the router's own :22 is reachable from this host.
# That is `Allow-pi1-router-mgmt`, an INPUT rule with no `dest`, so it matches
# any router interface including the VLAN10 one. It is a deliberate pinhole, not
# a forwarding hole, and asserting it blocked would encode a false expectation.

setup() {
    load helpers/setup
}

NAS_VLAN10_IP="${NAS_VLAN10_IP:-192.168.110.246}"
TRAEFIK_VLAN10_IP="${TRAEFIK_VLAN10_IP:-192.168.110.250}"

# Ports VLAN20 is meant to reach.
SEG_ALLOWED_NAS="${SEG_ALLOWED_NAS:-22 5055 8096}"
SEG_ALLOWED_TRAEFIK="${SEG_ALLOWED_TRAEFIK:-80 443}"

# Ports VLAN20 must NOT reach. Every one of these is chosen because it is
# genuinely LISTENING on the NAS — a probe that fails against a closed port
# proves nothing about the firewall, so liveness is verified before asserting.
SEG_DENIED_NAS="${SEG_DENIED_NAS:-3001 6767 7000 7878 8989 9696}"

tcp_open() {
    timeout "${3:-4}" bash -c "cat </dev/null >/dev/tcp/$1/$2" 2>/dev/null
}

on_vlan20() {
    ip -4 -o addr show 2>/dev/null | grep -qE 'inet 192\.168\.120\.'
}

require_vlan20() {
    on_vlan20 || skip "not on VLAN20 (no 192.168.120.0/24 address) - nothing to assert from here"
}

# Can we ask the NAS what it is listening on? pi1->NAS:22 is itself part of the
# allow-list, so this works from the intended vantage point and nowhere else.
nas_ssh() {
    ssh -o ConnectTimeout=8 -o BatchMode=yes arr-stack-nas "$@" 2>/dev/null
}

@test "segmentation: this host is on VLAN20 (vantage point for the rest of this file)" {
    require_vlan20
    run bash -c "ip -4 -o addr show | grep -oE 'inet 192\.168\.120\.[0-9]+' | head -1"
    assert_success
    [[ -n "$output" ]] || fail "expected a VLAN20 address"
}

@test "segmentation: VLAN20 can reach the NAS on exactly its allow-listed ports" {
    require_vlan20
    local unreachable=""
    for p in $SEG_ALLOWED_NAS; do
        tcp_open "$NAS_VLAN10_IP" "$p" || unreachable+="  $NAS_VLAN10_IP:$p\n"
    done
    [[ -z "$unreachable" ]] || fail "allow-listed NAS ports NOT reachable from VLAN20:\n$unreachable"
}

@test "segmentation: VLAN20 can reach Traefik on exactly its allow-listed ports" {
    require_vlan20
    local unreachable=""
    for p in $SEG_ALLOWED_TRAEFIK; do
        tcp_open "$TRAEFIK_VLAN10_IP" "$p" || unreachable+="  $TRAEFIK_VLAN10_IP:$p\n"
    done
    [[ -z "$unreachable" ]] || fail "allow-listed Traefik ports NOT reachable from VLAN20:\n$unreachable"
}

@test "segmentation: VLAN20 is blocked from NAS service ports that are provably listening" {
    require_vlan20

    # Vacuity guard. Asserting "port closed from here" is meaningless unless the
    # port is open THERE. Confirm liveness over the allow-listed SSH path first;
    # if that is unavailable, skip rather than pass on a hollow assertion.
    nas_ssh true || skip "cannot reach the NAS over SSH to confirm port liveness - assertion would be vacuous"

    local checked=0 leaked="" dead=""
    for p in $SEG_DENIED_NAS; do
        if ! nas_ssh "timeout 3 bash -c 'cat </dev/null >/dev/tcp/127.0.0.1/$p'"; then
            dead+="  $p\n"
            continue
        fi
        checked=$((checked + 1))
        if tcp_open "$NAS_VLAN10_IP" "$p"; then
            leaked+="  $NAS_VLAN10_IP:$p is LIVE and REACHABLE from VLAN20\n"
        fi
    done

    [[ -z "$leaked" ]] || fail "VLAN20 -> VLAN10 segmentation hole:\n$leaked"
    [[ "$checked" -gt 0 ]] || fail "none of the denied ports were listening on the NAS, so this test proved nothing. Ports not listening:\n$dead"
}
