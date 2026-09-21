#!/usr/bin/env bats
# The live half of the parity harness: can it actually reach both resolvers from
# the vantage they need, and does it say which vantage that was?
#
# WHAT THIS FILE DOES NOT ASSERT
#
# It does not assert parity. Whether the router's AdGuard Home currently agrees
# with the NAS Pi-hole is a property of the router, and on 2026-09-19 it did not:
# the .lan rewrites (3.2), the AAAA behaviour (3.3) and the blocklists (3.4) are
# Phase 3 work that has not landed, so a run of the full matrix reports dozens of
# differences and exits 1. Encoding "must be zero today" here would make this
# file a red test that proves nothing about the harness, and encoding "today's
# differences are fine" would be a guard that cannot fail. Gate 3 is where the
# zero is asserted, by a human reading ./scripts/dns-parity.sh's output.
#
# What it asserts instead is the part of the design that only live resolvers can
# confirm: a real query through a real jump host comes back, and the report names
# the vantage each side was reached from. Without that, a parity result across
# two vantages is unreadable - the reason the spec carries a jump host at all.
#
# VANTAGE POINT
#
# Needs both resolvers reachable: the NAS Pi-hole directly, and the router's
# AdGuard Home on :3053 through the maintenance VLAN (pi1). Port 3053 is dropped,
# not closed, from every client VLAN, so a host that cannot get there skips -
# with a reason - rather than failing. Same discipline as
# tests/network-segmentation.bats and tests/router-dns.bats.

setup() {
    load helpers/setup
    source "$REPO_ROOT/scripts/lib/dns-parity.sh"
}

# The router, not the NAS. Until 2026-09-21 this was the NAS Pi-hole at
# 192.168.110.246; the container was removed in Phase 9.4, and a query sent to
# its old address now meets the router's DNS redirect and is answered by AdGuard
# anyway -- so the old default would have gone on "answering" for a resolver
# that is not there. Both stores this script compares are on the router now.
ROUTER_DNS_IP="${ROUTER_DNS_IP:-192.168.8.1}"
AGH_JUMP="${AGH_JUMP:-pi@pi1.local}"
AGH_ADDR="${AGH_ADDR:-192.168.8.1:3053}"

# Plain dig, deliberately: the gate that decides whether to run must not depend
# on the module under test - a broken dns_parity_query would otherwise turn
# "could not check" into "skipped", and a skip reads as fine.
dig_answers() {
    local name="$1"; shift
    local out
    out=$(dig +time=3 +tries=1 +noall +comments +answer "$@" "$name" A 2>/dev/null) || true
    [[ "$out" == *"status: NOERROR"* ]] && [[ "$out" == *"ANSWER SECTION"* ]]
}

require_router_dnsmasq() {
    command -v dig >/dev/null 2>&1 || skip "dig not installed - cannot query any resolver"
    dig_answers example.com "@$ROUTER_DNS_IP" \
        || skip "the router at $ROUTER_DNS_IP did not answer example.com from here"
}

require_agh() {
    # One cheap query through the jump host. This is also the control for the
    # ssh path itself: a host whose ssh to the maintenance VLAN is broken skips
    # here instead of reporting every row as a difference.
    command -v dig >/dev/null 2>&1 || skip "dig not installed - cannot query any resolver"
    local out
    out=$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$AGH_JUMP" \
              "dig +time=3 +tries=1 +noall +comments +answer -p 3053 @192.168.8.1 example.com A" 2>&1) || true
    [[ "$out" == *"status: NOERROR"* ]] \
        || skip "AdGuard Home at $AGH_ADDR did not answer through $AGH_JUMP (port 3053 is dropped from every client VLAN): ${out:-no output}"
}

@test "dns-parity live: the router answers from here" {
    require_router_dnsmasq
}

@test "dns-parity live: the router's AdGuard Home answers through the jump host" {
    require_agh
}

@test "dns-parity live: a query through the jump host returns a real answer" {
    require_agh

    # A public name, so the answer does not depend on 3.2's rewrites having
    # landed. What is under test is the transport, not the router's config.
    run dns_parity_query "jump=$AGH_JUMP:$AGH_ADDR" example.com A udp
    # A live resolver that has started refusing must not read as an answer, so
    # the assertion is on the status word, not on the output being non-empty.
    [ "${output%% *}" = "NOERROR" ]
    [ -n "${output#* }" ]
}

@test "dns-parity live: the report names the vantage each side was queried from" {
    require_router_dnsmasq
    require_agh

    # Two resolvers reached from different places, which is the case the report
    # exists for: the router's dnsmasq is queried from here, its AdGuard Home
    # only through pi1. The result itself is Phase 3's business; what is
    # asserted is that a reader can tell how each side was reached.
    run dns_parity_endpoint "$ROUTER_DNS_IP:53"
    [ "$output" = "$ROUTER_DNS_IP:53" ]

    run dns_parity_endpoint "jump=$AGH_JUMP:$AGH_ADDR"
    [ "$output" = "$AGH_ADDR (via $AGH_JUMP)" ]
}
