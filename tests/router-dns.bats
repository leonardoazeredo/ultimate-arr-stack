#!/usr/bin/env bats
# Live assertions over the router, for the DNS migration to AdGuard Home.
#
# Why this file exists: the migration's two client-visible variables are
# `dhcp_option 6` on the DHCP pools and the nat REDIRECT that decides which
# resolver answers on :53. Neither is in this repo -- both live only on the
# router -- so nothing that reads compose text or the working tree can see them
# change. These tests read the router and assert the invariants that have to hold
# across every phase of the migration.
#
# Vantage point: needs a host that can reach the router, which today is pi1 over
# the maintenance VLAN. `ssh arr-stack-router` is refused from a client VLAN
# (measured 2026-09-19: port 22 refused from VLAN20, the same hop through pi1
# answers), so tests/helpers/router.bash probes both doors and uses whichever
# answers. Anywhere else -- CI, the NAS, a laptop on another VLAN -- every test
# skips with that reason rather than failing, the pattern
# tests/network-segmentation.bats uses for its own vantage point.
#
# READ-ONLY: every command below goes through router_cmd/router_sh, which refuse
# any script containing a mutating verb before opening a connection. These tests
# observe; the migration applies changes through committed scripts, never from a
# test.
#
# WHERE THE JUDGEMENT LIVES: scripts/lib/router-dns.sh. This file fetches text
# and the lib decides. That split is not tidiness -- this file skips on most
# hosts, and a guard that can only ever skip cannot be shown to be capable of
# failing. tests/lib-router-dns.bats exercises the same lib against synthetic
# captures on any host.

setup() {
    load helpers/setup
    load helpers/router
    source "$REPO_ROOT/scripts/lib/router-dns.sh"

    # The pools the migration moves (plan 5.5, and the same four in 0.4 and the
    # target architecture). The list is policy; the resolver each pool points at
    # is not asserted anywhere here, because that is the migration's variable --
    # NAS before Phase 5, the VLAN's router address during it, nothing at all
    # after 5.6.
    ROUTER_DNS_TARGET_POOLS="${ROUTER_DNS_TARGET_POOLS:-lan vlan10 vlan20 vlan30}"
}

# Capture a read-only router command's stdout, skipping with the reason when it
# cannot run and failing when it returns nothing. An empty capture passes every
# assertion it never makes, and a skip and a pass must not look alike.
router_capture() {
    local dest="$1"; shift
    local err="$BATS_TEST_TMPDIR/router-stderr"
    if ! router_cmd "$*" >"$dest" 2>"$err"; then
        skip "router command failed: $* -- $(tr '\n' ' ' <"$err" | head -c 300)"
    fi
    [[ -s "$dest" ]] \
        || fail "'$*' returned nothing from the router - every assertion below would be vacuous"
}

@test "router-dns: this host can reach the router (the vantage point for this whole file)" {
    require_router

    run router_cmd "echo router-dns-vantage-ok"
    assert_success
    [[ "$output" == *router-dns-vantage-ok* ]] \
        || fail "the router answered, but not with the probe's own output: $output"
}

# ---------------------------------------------------------------------------
# (a) per-pool dhcp_option 6 state
# ---------------------------------------------------------------------------

@test "router-dns: every target pool advertises at most one well-formed resolver" {
    require_router

    local cap="$BATS_TEST_TMPDIR/uci-show-dhcp.txt"
    router_capture "$cap" "uci show dhcp"

    run router_dns_option6_check "$ROUTER_DNS_TARGET_POOLS" "$cap"
    if [[ "$status" -ne 0 ]]; then
        echo "$output"
        echo "--- raw 'uci show dhcp', dhcp_option lines ---"
        grep dhcp_option "$cap" || echo "  (no pool carries any dhcp_option at all)"
        echo "--- pool sections in the capture ---"
        grep -E '^dhcp\.[^.]*=dhcp$' "$cap" || true
        false
    fi
    echo "$output"
}

# ---------------------------------------------------------------------------
# (b) adg_redirect semantics
# ---------------------------------------------------------------------------

@test "router-dns: adg_redirect holds exactly what dns_enabled says it should" {
    require_router

    local rules="$BATS_TEST_TMPDIR/adg-rules.txt"
    local listing="$BATS_TEST_TMPDIR/adg-listing.txt"
    local state="$BATS_TEST_TMPDIR/dns-enabled.txt"

    # `iptables -S adg_redirect` is the form the lib parses: one rule per line as
    # the argv that would create it, so protocol, jump target and --to-ports sit
    # in fixed tokens. The failure modes differ, so the command is not run
    # through router_capture: a missing chain is a FAIL the lib reports, not a
    # skip, because the chain is declared unconditionally by iptables-restore
    # from /etc/firewall.dns_order and its absence means the firewall changed.
    if ! router_cmd "iptables -t nat -S adg_redirect 2>&1 || true" >"$rules" 2>"$BATS_TEST_TMPDIR/router-stderr"; then
        skip "cannot run 'iptables -t nat -S adg_redirect' on the router: $(tr '\n' ' ' <"$BATS_TEST_TMPDIR/router-stderr" | head -c 300)"
    fi

    # Diagnostics for a human, not parsed: the padded listing is what most people
    # look at first, and printing it next to a failure saves a second ssh.
    router_cmd "iptables -t nat -L adg_redirect -n 2>&1 || true" >"$listing" 2>/dev/null || true

    if ! router_cmd "uci -q get adguardhome.config.dns_enabled || true" >"$state" 2>"$BATS_TEST_TMPDIR/router-stderr"; then
        skip "cannot read adguardhome.config.dns_enabled from the router: $(tr '\n' ' ' <"$BATS_TEST_TMPDIR/router-stderr" | head -c 300)"
    fi
    local dns_enabled
    dns_enabled=$(tr -d '[:space:]' <"$state")

    run router_dns_redirect_check "$dns_enabled" "$rules"
    if [[ "$status" -ne 0 ]]; then
        echo "$output"
        echo "--- adguardhome.config.dns_enabled: '${dns_enabled:-<unset>}' ---"
        echo "--- iptables -t nat -S adg_redirect ---"
        cat "$rules"
        echo "--- iptables -t nat -L adg_redirect -n ---"
        cat "$listing"
        false
    fi
    echo "$output"
}

# ---------------------------------------------------------------------------
# (c) dnsmasq :53 binds
# ---------------------------------------------------------------------------

@test "router-dns: dnsmasq binds :53 on every live non-loopback IPv4 the router has" {
    require_router

    local ifaces="$BATS_TEST_TMPDIR/ip-4-addr.txt"
    local listeners="$BATS_TEST_TMPDIR/netstat.txt"

    router_capture "$ifaces" "ip -4 -o addr show"
    router_capture "$listeners" "netstat -lntup 2>/dev/null"

    run router_dns_binds_check "$ifaces" "$listeners"
    if [[ "$status" -ne 0 ]]; then
        echo "$output"
        echo "--- live IPv4 addresses ---"
        cat "$ifaces"
        echo "--- :53 listeners ---"
        grep -E ':53([[:space:]]|$)' "$listeners" || echo "  (no :53 listener line at all)"
        false
    fi
    echo "$output"
}

# ---------------------------------------------------------------------------
# (d) the client path -- the connection between the pieces (a), (b) and (c) judge
# ---------------------------------------------------------------------------

@test "router-dns: every client bridge's :53 is redirected to the port AdGuard Home listens on, over IPv4 and IPv6" {
    require_router

    local ifaces="$BATS_TEST_TMPDIR/ip-4-addr.txt"
    local nat4="$BATS_TEST_TMPDIR/nat4.txt"
    local nat6="$BATS_TEST_TMPDIR/nat6.txt"
    local adg_cfg="$BATS_TEST_TMPDIR/adguard-home-config.yaml"

    router_capture "$ifaces" "ip -4 -o addr show"
    router_capture "$nat4" "iptables -t nat -S"
    # Both families, because both are real. The plan assumed IPv6 was out of
    # scope; measured 2026-09-21, the router's ip6tables carries the same ten
    # per-bridge rules, following the same port file, and pi1 querying the ULA
    # fde0:4646:77b8::1 gets 0.0.0.0 for a blocklisted name. The mechanism that
    # mirrors them is not identified — running the include directly does not
    # create them — so the observable is what gets asserted. Nothing else in this
    # repo reads ip6tables, and an unasserted half of a working mechanism is how
    # it stops working.
    router_capture "$nat6" "ip6tables -t nat -S"

    # Read from AdGuard's own config rather than writing 3053 here. The invariant
    # is that the redirects name the port AdGuard Home is listening on; a
    # constant would let the two drift apart while this test stayed green, which
    # is the same class of failure as the three VLANs this test exists for, one
    # layer down.
    if ! router_cmd "cat /etc/AdGuardHome/config.yaml" >"$adg_cfg" 2>"$BATS_TEST_TMPDIR/router-stderr"; then
        skip "cannot read /etc/AdGuardHome/config.yaml from the router: $(tr '\n' ' ' <"$BATS_TEST_TMPDIR/router-stderr" | head -c 300)"
    fi

    local adg_port
    adg_port=$(router_dns_adguard_port <"$adg_cfg" | tr -d '[:space:]')
    [[ -n "$adg_port" ]] \
        || skip "AdGuard Home's config.yaml does not state a DNS port, so there is no port to require the redirects to name"

    local pair family path failures=0
    for pair in "IPv4:$nat4" "IPv6:$nat6"; do
        family="${pair%%:*}"
        path="${pair#*:}"

        run router_dns_client_path_check "$adg_port" "$ifaces" "$path"
        echo "--- ${family} ---"
        echo "$output"
        if [[ "$status" -ne 0 ]]; then
            echo "--- ${family} PREROUTING rules on :53 ---"
            grep -E '^-A PREROUTING.*--dport 53' "$path" || echo "  (none)"
            echo "--- ${family} chains that reach a REDIRECT to ${adg_port} ---"
            router_dns_chain_redirects "$adg_port" <"$path" | sed 's/^/  /' || true
            failures=$((failures + 1))
        fi
    done

    # Both families are asserted before either failure is raised, so one run
    # reports what IPv4 and IPv6 each look like rather than stopping at the
    # first. A single red family is still a red test.
    [[ "$failures" -eq 0 ]]
}

# NOT tested, and why:
#
#   * Which resolver a pool advertises. Deliberate, and it is the whole reason
#     the lib exists in the shape it does: before Phase 5 all four target pools
#     point at the NAS (192.168.110.246), during Phase 5 each points at its own
#     VLAN's router address, and after 5.6 they carry no option 6 at all. Pinning
#     that value here would make every legitimate migration step a red test.
#
#   * That the redirect actually intercepts a client's query. This file reads
#     configuration state; it never sends a query. That assertion belongs to
#     tests/dns-resilience.bats (router-only resolution) and tests/e2e/dns.spec.ts
#     (from the NAS), and it needs a client path this host does not have: port
#     3053 is reachable only from the maintenance VLAN, so the VLAN client path
#     can only be exercised once the redirect is live (plan, "What that property
#     does NOT cover").
#
#   * The dns_enabled='1' branch of (b) against the live router. Today it is '0',
#     so what runs here is the empty-chain arm; the enabled arm is exercised only
#     by tests/lib-router-dns.bats against synthetic `-S` output. It cannot be
#     made non-vacuous from this host without flipping the flag, which is Phase 6
#     and not a test's business. The first real flip is what proves the parse of
#     the enabled chain; until then this file's coverage of that arm is a
#     hypothesis and is labelled as one rather than counted as coverage.
#
#   * Which process holds :53. The grammar of `netstat -lntup` is parsed for the
#     address only, not the PID/program column, and that is the right scope: the
#     socket is what a client can reach, and dnsmasq deliberately keeps listening
#     underneath AdGuard Home after Phase 6 (that is the Phase 7 fallback).
#
#   * IPv6 binds. dnsmasq holds :53 on a long list of link-local addresses that
#     change with every interface event, and the migration is IPv4: `ra` and
#     `dhcpv6` are `disabled` on vlan10/20/30, and lan/guest already point at the
#     router. An assertion here would fail for reasons nobody is migrating.
#
#   * That the chain's rules survive a firewall reload or a reboot. Nothing here
#     reboots the router; applying a change and re-running this file is how that
#     is checked (plan Gate 4 does exactly that for a different invariant).
