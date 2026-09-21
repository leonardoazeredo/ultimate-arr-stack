#!/usr/bin/env bats
# Live DNS resilience — is a resolver answering on the ROUTER's address enough
# for a client to get on with its day?
#
# Why this file exists: the migration moves the house's DNS off the NAS onto the
# router so the NAS can be powered off without taking internet access with it.
# Every phase of that plan is judged against one bar, and this is it: a client
# configured with nothing but the router's address must resolve a public name,
# resolve a `.lan` name, have a blocked name blocked, and get an answer (not
# NXDOMAIN) for AAAA on a `.lan` name.
#
# Vantage point: must run from a host that can reach the router AND shares a /24
# with one of its interfaces (pi1 reaches it over the maintenance VLAN, this Mac
# over VLAN20). Anywhere else — CI runners, the NAS, a laptop on another VLAN —
# every test skips with the reason rather than failing. The address is derived by
# router_ip_for_host, never hardcoded: from VLAN20 the address a client queries
# is 192.168.120.1, from the maintenance VLAN it is 192.168.8.1, and a hardcoded
# one would quietly ask the wrong interface.
#
# WHAT FAILS TODAY, AND WHY
#
#   * `.lan` names. The router's dnsmasq holds no `address` records for them.
#     `sonarr.lan` comes back NXDOMAIN with an empty answer section — nothing in
#     the answer, so both the A and the AAAA assertions fail on content.
#   * Blocked names. The router's dnsmasq runs no blocklist, so doubleclick.net
#     comes back as a real address set instead of Pi-hole's NULL block (0.0.0.0).
#
# Public resolution and both transports pass today. That asymmetry is the point:
# a green run here would mean the acceptance bar was already met, and it is not.
#
# NAS-IS-NOT-CONSULTED, which is what makes the `.lan` rows a real test
#
# The router's dnsmasq carries `local=/lan/`, so `.lan` queries are answered
# locally and are never forwarded upstream — to the NAS Pi-hole or anywhere else.
# A positive `.lan` answer from the router's `:53` can therefore only come from
# the router's own records. The two resolvers are told apart today: the NAS
# answers `sonarr.lan` with 192.168.110.250, the router answers NXDOMAIN. A
# router `.lan` answer of 192.168.110.250 after Phase 4 is the router's own data,
# not a forwarded reply.
#
# UDP AND TCP BOTH, and why that is not redundancy
#
# The migration flips which process answers `:53` via a firewall REDIRECT, and a
# redirect can be installed for one transport and not the other. A TCP-only probe
# passes while UDP resolution — the transport DNS actually uses — is broken; the
# trap tests/network-segmentation.bats already documents for port 53. Both the
# public name and the blocked name are asserted over both transports here.
# dns_matrix_query sends `+tcp` for tcp and nothing for udp, so the udp rows are
# genuinely UDP rather than a TCP query that a fallback made look like one.
#
# Every assertion below is expressed through scripts/lib/dns-matrix.sh so the
# verdict vocabulary (BLOCKED, NODATA, address literal) is the same one
# scripts/dns-parity.sh will use against both resolvers. A failure message that
# only said "expected 1, got 0" would be useless here: what the reader needs is
# the router's actual answer, so the fail messages carry it.

setup() {
    load helpers/setup
    load helpers/router
    source "$REPO_ROOT/scripts/lib/dns-matrix.sh"

    # dig is the only instrument here. Absent it, there is nothing to measure —
    # and a skip has to say so rather than let the file read as passing.
    command -v dig >/dev/null 2>&1 \
        || skip "dig not installed - cannot query the router's :53"

    # Two separate gates. require_router() proves there is a way to the router at
    # all and skips with the helper's error text when there is not; the derivation
    # below then picks the router address THIS host would query.
    require_router

    # Re-derive per test: the value belongs to the vantage point, and a cached
    # one would survive a host moving VLANs mid-run.
    ROUTER_IP=$(router_ip_for_host) \
        || skip "none of the router's interfaces shares a subnet with this host - no resolver address to query"
    [[ -n "$ROUTER_IP" ]] || skip "router_ip_for_host returned no address"

    DNS_PORT="${DNS_PORT:-53}"
    PUBLIC_NAME="${DNS_RESILIENCE_PUBLIC_NAME:-example.com}"
    LAN_NAME="${DNS_RESILIENCE_LAN_NAME:-sonarr.lan}"
    LAN_ADDR="${DNS_RESILIENCE_LAN_ADDR:-192.168.110.250}"
    BLOCKED_NAME="${DNS_RESILIENCE_BLOCKED_NAME:-doubleclick.net}"
    # The `.lan` AAAA row is the one place the two resolvers legitimately answer
    # differently: dnsmasq holds `address=/lan/::` and answers the literal `::`,
    # while AdGuard Home answers NODATA because its DNS rewrites carry an IPv4
    # address only. Phase 3.3 of the migration plan settled this in favour of
    # NODATA, having measured that musl's hard failure is AAAA *NXDOMAIN* rather
    # than an empty answer. LAN_AAAA accepts either and still refuses NXDOMAIN,
    # which is the failure mode this row exists for. See the LAN_AAAA case in
    # scripts/lib/dns-matrix.sh.
    LAN_AAAA="${DNS_RESILIENCE_LAN_AAAA:-LAN_AAAA}"
}

# dns_matrix_ask <name> <qtype> <transport> — run the module's query and leave the
# answer set in ASK_ANSWERS. The full result string is the readable half.
dns_matrix_ask() {
    ASK_RESULT=$(dns_matrix_query "$ROUTER_IP" "$DNS_PORT" "$1" "$2" "$3")
    ASK_STATUS=${ASK_RESULT%% *}
    ASK_ANSWERS=${ASK_RESULT#* }
}

# dns_matrix_require <name> <qtype> <transport> <expectation> <why>
#
# Fails with the expectation, the why, and the router's actual answer. Never
# returns a bare "not met" — the reader should not have to re-run dig to find out
# what the router said.
dns_matrix_require() {
    local name="$1" qtype="$2" transport="$3" expectation="$4" why="$5"
    dns_matrix_ask "$name" "$qtype" "$transport"
    if dns_matrix_expectation_met "$expectation" "$ASK_STATUS" "$ASK_ANSWERS"; then
        return 0
    fi
    fail "$why
  queried:     $ROUTER_IP:$DNS_PORT $name $qtype over $transport
  expected:    $expectation
  router said: $ASK_STATUS ${ASK_ANSWERS:-<empty answer section>}"
}

# Every expectation has to be applied to a query that could have failed it. That
# is dns_matrix_expectation_met's job — an address literal needs at least one
# answer and every answer must be it, BLOCKED needs 0.0.0.0 present, ANY needs
# something there. The guard worth adding by hand is that the `.lan` rows really
# ask about `.lan`: if someone points LAN_NAME at a public name, the "`.lan`
# resolves from the router" assertion becomes a test of public resolution wearing
# a local name's label and can pass without the router knowing a single record.
require_lan_name() {
    [[ "$LAN_NAME" == *.lan ]] \
        || fail "DNS_RESILIENCE_LAN_NAME is '$LAN_NAME', which is not a .lan name - this test would then pass without the router answering from its own records"
}

# Both transports, in one line of test body. The first transport that fails ends
# the loop, so the reported answer is the one that actually broke.
dns_matrix_require_both() {
    local name="$1" qtype="$2" expectation="$3" why="$4"
    dns_matrix_require "$name" "$qtype" udp "$expectation" "$why (UDP, the transport DNS actually uses)"
    dns_matrix_require "$name" "$qtype" tcp "$expectation" "$why (TCP, a redirect can cover one transport only)"
}

@test "dns-resilience: the router address this host would query is derived, not guessed" {
    # Vacuity guard for every test below: each one queries $ROUTER_IP, so the
    # address has to be one of the router's own interfaces on this host's /24. A
    # derivation that returned something else would have the whole file asking a
    # different box the same questions and failing for reasons that look real.
    run router_ipv4_addrs
    assert_success
    # grep -F, because the address has dots: a pattern match here would treat
    # 192.168.120.1 as a regex where every dot is any character.
    printf '%s\n' "$output" | grep -qF -- "$ROUTER_IP" \
        || fail "derived $ROUTER_IP is not among the router's own addresses: $output"

    local host_mine
    host_mine=$(host_ipv4_addrs | grep -v '^127\.' | head -1)
    [[ "${host_mine%.*}" == "${ROUTER_IP%.*}" ]] \
        || fail "$ROUTER_IP shares no /24 with this host ($host_mine) - the query would go to a router interface a client here never uses"
}

@test "dns-resilience: a public name resolves via the router over both transports" {
    # The passing baseline. If this ever fails, the vantage point or the router's
    # upstream is the problem, not the migration.
    dns_matrix_require_both "$PUBLIC_NAME" A ANY \
        "the router's :53 did not return an address for $PUBLIC_NAME"
}

@test "dns-resilience: the router is not silently answering public names with a null block" {
    # `ANY` deliberately does not compare the value, because load-balanced names
    # hand out a different edge per query. Left unguarded that would also accept
    # 0.0.0.0, and a resolver blocking everything must not read as resolving. The
    # positive assertion is that the answer is a real address, not a null one.
    dns_matrix_ask "$PUBLIC_NAME" A udp
    [[ -n "$ASK_ANSWERS" ]] \
        || fail "$PUBLIC_NAME came back $ASK_STATUS with an empty answer section"
    [[ " $ASK_ANSWERS " != *" 0.0.0.0 "* ]] \
        || fail "$PUBLIC_NAME was answered with the null block, not a real address: $ASK_STATUS $ASK_ANSWERS"
}

@test "dns-resilience: a .lan name resolves via the router to Traefik's macvlan" {
    require_lan_name
    dns_matrix_require "$LAN_NAME" A udp "$LAN_ADDR" \
        "the router's :53 did not resolve $LAN_NAME to $LAN_ADDR (the router has no .lan records today, and local=/lan/ stops it forwarding the question anywhere that does)"
    dns_matrix_require "$LAN_NAME" A tcp "$LAN_ADDR" \
        "the router's :53 did not resolve $LAN_NAME to $LAN_ADDR over TCP"
}

@test "dns-resilience: a .lan AAAA query gets an answer rather than NXDOMAIN" {
    require_lan_name
    # Not merely "something came back": NXDOMAIN is an answer, and it is the one
    # that breaks musl/Alpine clients, which treat AAAA NXDOMAIN as a hard failure
    # rather than falling back to the A record. What is NOT asserted is the
    # literal `::` -- dnsmasq answers that, AdGuard Home answers NODATA, and 3.3
    # decided NODATA is sufficient. LAN_AAAA accepts either, refuses NXDOMAIN,
    # and refuses an unreachable resolver.
    dns_matrix_require "$LAN_NAME" AAAA udp "$LAN_AAAA" \
        "the router's :53 did not answer $LAN_NAME AAAA acceptably (NXDOMAIN here is the failure mode that breaks musl/Alpine clients; NODATA and '::' are both fine)"
}

@test "dns-resilience: a blocked name is blocked via the router over both transports" {
    # Pi-hole's NULL blocking mode answers 0.0.0.0. The router runs no blocklist,
    # so today this comes back as the real doubleclick.net address set. The
    # assertion is on the answer, not on a status: a resolver that returns
    # NXDOMAIN for a blocked name has not blocked it, it has broken it.
    dns_matrix_require_both "$BLOCKED_NAME" A BLOCKED \
        "$BLOCKED_NAME was not blocked by the router's :53"
}

# NOT tested, and why:
#
#   * DoH/DoT on the router, and any claim about where a public answer came from.
#     This file can see that a name resolves; it cannot see which upstream
#     answered it. That is scripts/dns-parity.sh's job (3.6), against two
#     resolvers, not this one.
#   * Blocklist coverage beyond one name. doubleclick.net is the control: it is
#     the name the migration's baseline matrix records as blocked, so a change in
#     its verdict is meaningful. A second blocked name would be a second control
#     with no independent source of truth.
#   * AAAA on a public name. Phase 3.3 changes behaviour for `.lan` AAAA
#     specifically; public AAAA has no such requirement and is already covered by
#     the baseline matrix.
#   * The NAS resolver, at all. This file asserts the router is sufficient on its
#     own, which is the whole point of the migration. Whether the NAS is still
#     correct is the baseline matrix's business, and whether client pools have
#     been moved to the router is tests/router-dns.bats (1.2).
