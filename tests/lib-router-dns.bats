#!/usr/bin/env bats
# scripts/lib/router-dns.sh
#
# Every assertion in tests/router-dns.bats is judged by these functions, and that
# live file skips on any host that cannot reach the router -- which, since
# `ssh arr-stack-router` is refused from a client VLAN, is most of them. A guard
# whose only reachable outcome is "skipped" cannot be shown to be capable of
# failing. These tests feed synthetic captures to the same functions, so the
# reasoning runs everywhere and a mutation in the lib kills a test here instead
# of hiding inside a file that skipped.
#
# Each test names, in a comment, the change to the lib that would turn it red. A
# test that cannot name one proves nothing and does not belong in this file.
#
# The fixtures are written to look like the router's actual output -- `uci show
# dhcp`, `iptables -t nat -S adg_redirect`, `ip -4 -o addr show`,
# `netstat -lntup`, copied from the live box on 2026-09-19 -- rather than like
# the parser's input. A fixture shaped for the parser tests the parser against
# itself.

setup() {
    load helpers/setup
    source "$REPO_ROOT/scripts/lib/router-dns.sh"

    FIX="$BATS_TEST_TMPDIR/fixtures"
    mkdir -p "$FIX"
    TARGET_POOLS="lan vlan10 vlan20 vlan30"
}

# from_file <capture> <stdin parser> -- run a parser over a fixture.
from_file() {
    local file="$1"; shift
    "$@" < "$file"
}

# --------------------------------------------------------------------------
# fixture builders
# --------------------------------------------------------------------------

# The non-pool sections `uci show dhcp` always carries. Matching on the `dhcp.`
# prefix instead of the `=dhcp` type suffix would report @dnsmasq, wgclient1 and
# odhcpd as pools, so they are in every fixture.
new_uci() {
    : > "$FIX/uci.txt"
    cat >> "$FIX/uci.txt" <<'EOF'
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].local='/lan/'
dhcp.@dnsmasq[0].domain='tail32085c.ts.net'
dhcp.odhcpd=odhcpd
dhcp.wgclient1=dnsmasq
dhcp.wgclient1.port='2153'
EOF
}

# uci_pool <pool> [option-token...] -- append one pool section. uci renders a
# list as space-separated quoted values on one line, which is what makes a
# half-moved pool a single-line parse problem.
uci_pool() {
    local pool="$1"; shift
    local token vals=""
    for token in "$@"; do vals="$vals '$token'"; done

    printf 'dhcp.%s=dhcp\n' "$pool" >> "$FIX/uci.txt"
    printf "dhcp.%s.interface='%s'\n" "$pool" "$pool" >> "$FIX/uci.txt"
    if [[ -n "$vals" ]]; then
        printf 'dhcp.%s.dhcp_option=%s\n' "$pool" "${vals# }" >> "$FIX/uci.txt"
    fi
}

# The router as it is today, except that `lan` carries exactly the option tokens
# given (none of them = no option at all). The malformed/half-moved cases are all
# variations of lan, so they are built by calling this rather than by rewriting a
# baseline with sed -- a sed -i here would behave differently on the two hosts
# that run this suite.
uci_with_lan_option() {
    local token vals=""
    for token in "$@"; do vals="$vals '$token'"; done

    {
        printf 'dhcp.@dnsmasq[0]=dnsmasq\n'
        printf "dhcp.@dnsmasq[0].local='/lan/'\n"
        printf 'dhcp.odhcpd=odhcpd\n'
        printf 'dhcp.wgclient1=dnsmasq\n'
        printf 'dhcp.lan=dhcp\n'
        printf "dhcp.lan.interface='lan'\n"
        if [[ -n "$vals" ]]; then
            printf 'dhcp.lan.dhcp_option=%s\n' "${vals# }"
        fi
        printf 'dhcp.guest=dhcp\n'
        printf 'dhcp.iot=dhcp\n'
        printf 'dhcp.vlan10=dhcp\n'
        printf "dhcp.vlan10.dhcp_option='6,192.168.110.246'\n"
        printf 'dhcp.vlan20=dhcp\n'
        printf "dhcp.vlan20.dhcp_option='6,192.168.110.246'\n"
        printf 'dhcp.vlan30=dhcp\n'
        printf "dhcp.vlan30.dhcp_option='6,192.168.110.246'\n"
    } > "$FIX/uci.txt"
}

# The router as it is today: four pools on the NAS resolver, guest and iot with
# no option at all.
uci_baseline() {
    uci_with_lan_option '6,192.168.110.246'
}

# redirect_capture <rule-line>... -- writes $FIX/rules.txt in the shape of
# `iptables -t nat -S adg_redirect`: the `-N` declaration, then one `-A` line
# per rule, as the argv that would create it.
redirect_capture() {
    local rule
    printf -- '-N adg_redirect\n' > "$FIX/rules.txt"
    for rule in "$@"; do
        printf '%s\n' "$rule" >> "$FIX/rules.txt"
    done
}

# interfaces_capture <name> <ipv4>... -- an `ip -4 -o addr show` capture, with
# the trailing fields netstat-style output keeps after the address.
interfaces_capture() {
    local name="$1"; shift
    local f="$FIX/$name" ip
    printf '1: lo    inet 127.0.0.1/8 scope host lo   valid_lft forever preferred_lft forever\n' > "$f"
    for ip in "$@"; do
        printf '12: br-lan.1    inet %s/24 brd 255.255.255.0 scope global br-lan.1   valid_lft forever preferred_lft forever\n' "$ip" >> "$f"
    done
}

# listeners_capture <name> <ipv4>... -- a `netstat -lntup` capture with :53 on
# tcp and udp for each address.
listeners_capture() {
    local name="$1"; shift
    local f="$FIX/$name" ip
    {
        printf 'Active Internet connections (only servers)\n'
        printf 'Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name\n'
        for ip in "$@"; do
            printf 'tcp        0      0 %-23s 0.0.0.0:*               LISTEN      32215/dnsmasq\n' "$ip:53"
            printf 'udp        0      0 %-23s 0.0.0.0:*                           32215/dnsmasq\n' "$ip:53"
        done
    } > "$f"
}

# --------------------------------------------------------------------------
# the parsers, on their own
# --------------------------------------------------------------------------

@test "router-dns: pool parsing keys on the section type, not the dhcp. prefix" {
    new_uci
    uci_pool lan
    printf 'dhcp.@host[0]=host\n' >> "$FIX/uci.txt"
    printf 'dhcp.@host[0].mac=%s\n' "'86:FA:33:67:A7:EE'" >> "$FIX/uci.txt"
    printf 'dhcp.@dhcp[0]=dhcp\n' >> "$FIX/uci.txt"

    # RED if the matcher looked for `^dhcp\.` instead of `=dhcp$`: the dnsmasq
    # instance (wgclient1, its own resolver on port 2153), the odhcpd section and
    # @host[0] would all be listed as pools, and the outside-the-set sweep in
    # router_dns_option6_check would then report every one of them.
    run from_file "$FIX/uci.txt" router_dns_pool_names
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c '' )" -eq 2 ]
    [[ "$output" == *"lan"* ]]
    [[ "$output" == *"@dhcp[0]"* ]]
    [[ "$output" != *"@dnsmasq[0]"* ]]
    [[ "$output" != *"wgclient1"* ]]
    [[ "$output" != *"odhcpd"* ]]
    [[ "$output" != *"@host[0]"* ]]
}

@test "router-dns: a two-value dhcp_option list yields two entries, not one" {
    new_uci
    uci_pool lan '6,192.168.110.246' '6,192.168.8.1'

    # This is the parse the half-moved-pool assertion rests on. RED if the
    # entries parser took only the first quoted value (or slurped the rest as
    # part of the address), because then the pool would look like it advertises
    # exactly one well-formed resolver.
    run from_file "$FIX/uci.txt" router_dns_option6_entries
    [ "$status" -eq 0 ]
    [[ "$output" == *"lan	6	192.168.110.246"* ]]
    [[ "$output" == *"lan	6	192.168.8.1"* ]]
}

@test "router-dns: a dhcp_option with no comma is not silently treated as code 6" {
    new_uci
    uci_pool lan '6'

    # RED if the entry splitter assumed a comma and mapped the whole token to
    # the code: `6` would then come back as code "6" with the value defaulted to
    # something rather than to empty, and the malformed-value assertion below
    # would never see an empty address.
    run from_file "$FIX/uci.txt" router_dns_option6_entries
    [ "$status" -eq 0 ]
    [ "$output" = "lan	6	" ]
}

# --------------------------------------------------------------------------
# (a) per-pool dhcp_option 6 state
# --------------------------------------------------------------------------

@test "router-dns: four pools each advertising one resolver is the baseline pass" {
    uci_baseline

    # The false-red guard for this group. RED if the check demanded a second
    # value, or rejected a well-formed address, or miscounted the target pool
    # set -- any of which would break the suite on the router as it actually is
    # today and get the file deleted rather than fixed.
    run router_dns_option6_check "$TARGET_POOLS" "$FIX/uci.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok   lan      6,192.168.110.246"* ]]
    [[ "$output" == *"4/4 target pools present, 0 problem(s)"* ]]
}

@test "router-dns: a pool carrying two resolvers is a half-moved pool, not a pass" {
    uci_with_lan_option '6,192.168.110.246' '6,192.168.8.1'

    # RED if the count came from `head -1`, or from a `grep -q` that stops at the
    # first match: a pool advertising the NAS *and* the router answers whichever
    # the client happens to pick, which is the state this check exists for.
    run router_dns_option6_check "$TARGET_POOLS" "$FIX/uci.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL lan      advertises 2 resolvers"* ]]
}

@test "router-dns: a malformed option 6 value fails even though the code is right" {
    uci_with_lan_option '6,192.168.110'

    # RED if the value check were `[[ -n "$value" ]]` instead of an address shape
    # check. A truncated address gets handed to clients as-is, and nothing on the
    # router complains at commit time.
    run router_dns_option6_check "$TARGET_POOLS" "$FIX/uci.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL lan      option 6 is not a well-formed 6,<ipv4>"* ]]
}

@test "router-dns: an out-of-range octet is not a well-formed address" {
    uci_with_lan_option '6,999.1.1.1'

    # RED if router_dns_is_ipv4 dropped its 0..255 loop. `999.1.1.1` matches a
    # bare dotted-quad regex, so a shape-only check calls a broken handout
    # well-formed -- the stronger half of the assertion, and the one that has to
    # be seen going red rather than assumed to work.
    run router_dns_option6_check "$TARGET_POOLS" "$FIX/uci.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a well-formed 6,<ipv4>"* ]]
}

@test "router-dns: a value with no address at all is malformed" {
    uci_with_lan_option '6'

    # RED if a comma-less token were skipped silently by the entries parser: the
    # pool would report zero resolvers and pass as the post-migration state.
    run router_dns_option6_check "$TARGET_POOLS" "$FIX/uci.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *'got "6,"'* ]]
}

@test "router-dns: a non-6 dhcp_option is not read as a resolver" {
    new_uci
    uci_pool lan '3,192.168.110.1'
    uci_pool vlan10
    uci_pool vlan20
    uci_pool vlan30

    # RED if the entries parser ignored the option code and reported every
    # dhcp_option as a resolver. Option 3 is the default gateway; the router
    # carries one on no pool today, but a check that cannot tell 3 from 6 would
    # fail the moment one appeared.
    run router_dns_option6_check "$TARGET_POOLS" "$FIX/uci.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok   lan      no resolver advertised"* ]]
}

@test "router-dns: a target pool with no option 6 is the post-migration state, not a failure" {
    new_uci
    uci_pool lan
    uci_pool vlan10
    uci_pool vlan20
    uci_pool vlan30

    # Task 5.6 deletes option 6 from all four pools so dnsmasq advertises itself,
    # so this state has to be able to pass. RED if the check required a value, or
    # treated the all-zero case as an empty parse.
    run router_dns_option6_check "$TARGET_POOLS" "$FIX/uci.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"4/4 target pools present, 0 problem(s)"* ]]
}

@test "router-dns: a target pool missing from the capture fails instead of passing on zero values" {
    new_uci
    uci_pool lan
    uci_pool vlan10
    uci_pool vlan20          # vlan30 absent

    # RED if the per-pool loop skipped pools it could not find. An absent pool
    # contributes zero values, and zero values is a pass -- so without this the
    # one capture that means "the parser is looking at the wrong thing" reads as
    # the cleanest possible result.
    run router_dns_option6_check "$TARGET_POOLS" "$FIX/uci.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL vlan30   not present in the capture"* ]]
}

@test "router-dns: a pool outside the migration set that gained a resolver fails" {
    new_uci
    uci_pool lan '6,192.168.110.246'
    uci_pool guest '6,192.168.8.1'
    uci_pool iot
    uci_pool vlan10 '6,192.168.110.246'
    uci_pool vlan20 '6,192.168.110.246'
    uci_pool vlan30 '6,192.168.110.246'

    # guest and iot are the pools with no option 6 today. RED if the
    # outside-the-set sweep were dropped: a resolver appearing on a pool nobody
    # declared a move for is a client-visible change with no phase behind it.
    run router_dns_option6_check "$TARGET_POOLS" "$FIX/uci.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL guest    advertises a resolver but is not a migration target: 6,192.168.8.1"* ]]
}

@test "router-dns: an anonymous pool carrying a resolver is caught too" {
    uci_baseline
    printf 'dhcp.@dhcp[0]=dhcp\n' >> "$FIX/uci.txt"
    printf "dhcp.@dhcp[0].dhcp_option='6,192.168.8.1'\n" >> "$FIX/uci.txt"

    # RED if the entries parser's section pattern stopped at `[` or `.`, or if
    # pool names were read from a fixed list rather than derived from the type
    # lines -- the anonymous form is exactly how a pool added by a UI lands.
    run router_dns_option6_check "$TARGET_POOLS" "$FIX/uci.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"@dhcp[0] advertises a resolver but is not a migration target"* ]]
}

@test "router-dns: a capture with no pools at all is not a pass" {
    : > "$FIX/empty.txt"
    printf 'some other command output\n' > "$FIX/junk.txt"

    # RED if the empty-parse guard returned 0. An empty capture satisfies every
    # assertion it never makes -- the exact shape of four guards this repo has
    # already had to throw out.
    run router_dns_option6_check "$TARGET_POOLS" "$FIX/empty.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"parsed no dhcp pools"* ]]

    run router_dns_option6_check "$TARGET_POOLS" "$FIX/junk.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"parsed no dhcp pools"* ]]
}

@test "router-dns: an option 6 capture that cannot be read is a skip, not a pass" {
    # RED if the unreadable path were treated as empty text and run through the
    # parser: an empty capture would then reach the "no pools" guard, which is a
    # different failure with a different message, and the caller could not tell
    # "the file is missing" from "the router said nothing".
    run router_dns_option6_check "$TARGET_POOLS" "$BATS_TEST_TMPDIR/nope.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"SKIP: cannot read the uci capture"* ]]
}

# --------------------------------------------------------------------------
# (b) adg_redirect semantics
# --------------------------------------------------------------------------

TCP_RULE='-A adg_redirect -p tcp -m tcp --dport 53 -m comment --comment "adg_dns" -j REDIRECT --to-ports 3053'
UDP_RULE='-A adg_redirect -p udp -m udp --dport 53 -j REDIRECT --to-ports 3053'

@test "router-dns: an empty chain with dns_enabled=0 is the baseline pass" {
    redirect_capture

    # This is the state the router is in today. RED if the check demanded a rule
    # while disabled: with dns_enabled='0' the chain is declared and empty, and
    # an "exists iff enabled" reading of it would fail at baseline.
    run router_dns_redirect_check 0 "$FIX/rules.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"dns_enabled=0, chain declared, 0 rules"* ]]
}

@test "router-dns: a rule in the chain while dns_enabled=0 fails" {
    redirect_capture "$TCP_RULE"

    # RED if the disabled state only checked that the chain exists. A rule left
    # behind after a revert keeps redirecting :53 to a resolver the config says
    # is off, which is silent and total.
    run router_dns_redirect_check 0 "$FIX/rules.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"dns_enabled='0' but adg_redirect holds 1 rule(s)"* ]]
}

@test "router-dns: tcp and udp REDIRECT --to-ports 3053 with dns_enabled=1 passes" {
    redirect_capture "$TCP_RULE" "$UDP_RULE"

    # The state Phase 6 installs. RED if the rule parser could not reach
    # --to-ports through the `-m comment` match, which is what this line
    # deliberately carries.
    run router_dns_redirect_check 1 "$FIX/rules.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"tcp+udp REDIRECT --to-ports 3053 (1 tcp, 1 udp)"* ]]
}

@test "router-dns: a tcp-only chain with dns_enabled=1 fails on the missing udp arm" {
    redirect_capture "$TCP_RULE"

    # RED if the enabled state were satisfied by any REDIRECT rule, or checked
    # only one transport. UDP is the transport DNS is actually used over, and a
    # TCP-only chain passes a TCP probe while leaving resolution broken -- the
    # trap tests/network-segmentation.bats already documents for port 53.
    run router_dns_redirect_check 1 "$FIX/rules.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no udp REDIRECT --to-ports 3053 rule"* ]]
    [[ "$output" != *"no tcp REDIRECT"* ]]
}

@test "router-dns: a udp-only chain with dns_enabled=1 fails on the missing tcp arm" {
    redirect_capture "$UDP_RULE"

    # The other half of the same assertion. RED if only the udp arm were required.
    run router_dns_redirect_check 1 "$FIX/rules.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no tcp REDIRECT --to-ports 3053 rule"* ]]
    [[ "$output" != *"no udp REDIRECT"* ]]
}

@test "router-dns: a udp arm pointed at another port does not count as the arm" {
    redirect_capture "$TCP_RULE" '-A adg_redirect -p udp -m udp --dport 53 -j REDIRECT --to-ports 9999'

    # RED if the port comparison were dropped, keeping only "is there a udp
    # REDIRECT rule". A redirect to a port nothing listens on black-holes every
    # query, and it looks exactly like a working rule in a listing.
    run router_dns_redirect_check 1 "$FIX/rules.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a tcp/udp REDIRECT --to-ports 3053"* ]]
    [[ "$output" == *"--to-ports 9999"* ]]
}

@test "router-dns: a chain that is not declared fails in both states" {
    printf 'iptables: No chain/target/match by that name.\n' > "$FIX/missing.txt"

    # /etc/firewall.dns_order declares the chain unconditionally through
    # iptables-restore, so its absence is the firewall having changed. RED if the
    # declaration check were removed, or if it accepted the `-L` table header:
    # zero parsed rules would then read as "empty chain" while disabled, and the
    # check would pass on the wrong capture.
    local state
    for state in 0 1; do
        run router_dns_redirect_check "$state" "$FIX/missing.txt"
        [ "$status" -eq 1 ]
        [[ "$output" == *"does not declare the chain adg_redirect"* ]]
    done

    printf 'Chain adg_redirect (1 references)\ntarget     prot opt source               destination\n' \
        > "$FIX/listing.txt"
    run router_dns_redirect_check 0 "$FIX/listing.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not declare the chain adg_redirect"* ]]
}

@test "router-dns: an undecidable dns_enabled is not a pass" {
    redirect_capture "$TCP_RULE" "$UDP_RULE"

    # RED if an unset or unexpected dns_enabled fell through to one of the two
    # branches. `uci -q get` prints nothing and exits 1 when the option is
    # absent, and guessing which invariant applies is how a check passes on a
    # router whose AdGuard Home state nobody can name.
    run router_dns_redirect_check "" "$FIX/rules.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"dns_enabled is '<unset>'"* ]]

    run router_dns_redirect_check "yes" "$FIX/rules.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"dns_enabled is 'yes'"* ]]
}

# --------------------------------------------------------------------------
# (c) dnsmasq :53 binds
# --------------------------------------------------------------------------

@test "router-dns: every live non-loopback address bound passes" {
    interfaces_capture ifaces.txt 192.168.8.1 192.168.9.1 192.168.110.1 192.168.120.1 192.168.130.1 10.2.0.2 100.70.123.86
    listeners_capture listeners.txt 127.0.0.1 192.168.8.1 192.168.9.1 192.168.110.1 192.168.120.1 192.168.130.1 10.2.0.2 100.70.123.86

    # The false-red guard. RED if loopback were required (host_ipv4's own
    # subtraction would then have to be wrong in the other direction), or if the
    # parser read the address by column index and a name like `br-lan.1` shifted
    # it.
    run router_dns_binds_check "$FIX/ifaces.txt" "$FIX/listeners.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"100.70.123.86    :53 bound"* ]]
    [[ "$output" == *"0 problem(s)"* ]]
}

@test "router-dns: a live address with no :53 bind fails" {
    interfaces_capture ifaces.txt 192.168.8.1 192.168.120.1
    listeners_capture listeners.txt 127.0.0.1 192.168.8.1

    # RED if the required set were built from the listeners instead of from the
    # interfaces -- the same circularity that would make the whole check pass on
    # a router whose dnsmasq never started.
    run router_dns_binds_check "$FIX/ifaces.txt" "$FIX/listeners.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL 192.168.120.1"* ]]
    [[ "$output" == *"has no :53 bind"* ]]
    [[ "$output" != *"FAIL 192.168.8.1"* ]]
}

@test "router-dns: a :53 bind on an address the router does not have fails" {
    interfaces_capture ifaces.txt 192.168.8.1 192.168.9.1 192.168.110.1 192.168.120.1 192.168.130.1
    listeners_capture listeners.txt 127.0.0.1 192.168.8.1 192.168.9.1 192.168.110.1 192.168.120.1 192.168.130.1 192.168.10.1

    # 192.168.10.1 is what `network.iot` is configured to be, and
    # `network.iot.disabled='1'` means br-iot never comes up. This is the iot row
    # of the plan's Evidence, asserted in derived form instead of by naming the
    # address: RED if the stale direction were dropped, which is the same
    # assertion as "and not on 192.168.10.1" without the hardcoded list.
    #
    # The last two assertions are what make that true rather than approximately
    # true. Without them the stale check could flag EVERY bound address and this
    # test would still pass on 192.168.10.1 appearing somewhere in a wall of
    # failures -- the mutation that survived this test's first version.
    run router_dns_binds_check "$FIX/ifaces.txt" "$FIX/listeners.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL 192.168.10.1"* ]]
    [[ "$output" == *"has a :53 bind but is not an address this router has"* ]]
    [[ "$output" != *"FAIL 192.168.8.1"* ]]
    [[ "$output" != *"FAIL 192.168.130.1"* ]]
}

@test "router-dns: only loopback listening is not a pass" {
    interfaces_capture ifaces.txt 192.168.8.1
    listeners_capture listeners.txt 127.0.0.1

    # RED if the required set silently dropped to the loopback subtract and the
    # check passed on the empty remainder. The last assertion pins the other
    # half: this check is specified over non-loopback addresses, so 127.0.0.1
    # must not appear in its output at all. Without it, removing the loopback
    # exclusion still fails this test (on 192.168.8.1) while quietly accepting a
    # loopback bind as if it covered a live interface -- the mutation that
    # survived this test's first version.
    run router_dns_binds_check "$FIX/ifaces.txt" "$FIX/listeners.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL 192.168.8.1"* ]]
    [[ "$output" == *"has no :53 bind"* ]]
    [[ "$output" != *"127.0.0.1"* ]]
}

@test "router-dns: IPv6 :53 listeners are ignored, not counted as stale binds" {
    interfaces_capture ifaces.txt 192.168.8.1
    listeners_capture listeners.txt 192.168.8.1
    {
        printf 'tcp        0      0 ::1:53                  :::*                    LISTEN      32215/dnsmasq\n'
        printf 'tcp        0      0 fe80::9683:c4ff:fee5:2b21:53 :::*               LISTEN      32215/dnsmasq\n'
    } >> "$FIX/listeners.txt"

    # This is a real bug the first version of the check had: `::1` ends in `:53`
    # for the same reason `127.0.0.1` does, and it appeared as a stale bind on
    # the live router. RED if the IPv4 filter on the listener side is removed.
    run router_dns_binds_check "$FIX/ifaces.txt" "$FIX/listeners.txt"
    [ "$status" -eq 0 ]
    [[ "$output" != *"::1"* ]]
}

@test "router-dns: ss-shaped listener output parses like netstat" {
    interfaces_capture ifaces.txt 192.168.8.1 192.168.110.1
    cat > "$FIX/ss.txt" <<'EOF'
Netid State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess
tcp   LISTEN 0      32         192.168.8.1:53      0.0.0.0:*    users:(("dnsmasq",pid=32215,fd=5))
tcp   LISTEN 0      32         192.168.110.1:53    0.0.0.0:*
tcp   LISTEN 0      32         127.0.0.1:53        0.0.0.0:*
EOF

    # The live test uses netstat because that is what the plan's Evidence row was
    # measured with, but the parser scans for the field ending in `:53` rather
    # than reading a fixed column, and `ss` puts it one column further right.
    # RED if the parser went back to a column index.
    run router_dns_binds_check "$FIX/ifaces.txt" "$FIX/ss.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"192.168.110.1    :53 bound"* ]]
}

@test "router-dns: a wildcard :53 bind satisfies the requirement and is reported as such" {
    interfaces_capture ifaces.txt 192.168.8.1 192.168.110.1
    listeners_capture listeners.txt 0.0.0.0

    # RED if the wildcard bind were treated as a stale address: it is on no
    # interface's list, but it covers every one of them, so failing it would be
    # a red test about a router that is serving every client correctly.
    run router_dns_binds_check "$FIX/ifaces.txt" "$FIX/listeners.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"a wildcard :53 bind is present"* ]]
}

@test "router-dns: an interface capture with no IPv4 address is not a pass" {
    printf 'this is not ip output\n' > "$FIX/junk.txt"
    listeners_capture listeners.txt 192.168.8.1

    # RED if the empty side of the comparison were allowed through: with no
    # required addresses, the missing-bind loop has nothing to iterate and the
    # check would report zero problems.
    run router_dns_binds_check "$FIX/junk.txt" "$FIX/listeners.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"parsed no IPv4 address"* ]]
}

@test "router-dns: a listener capture with no :53 is not a pass" {
    interfaces_capture ifaces.txt 192.168.8.1
    printf 'tcp        0      0 0.0.0.0:80              0.0.0.0:*               LISTEN      10755/nginx\n' \
        > "$FIX/other.txt"

    # RED if "nothing is listening on :53" fell through as "nothing to report".
    run router_dns_binds_check "$FIX/ifaces.txt" "$FIX/other.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"parsed no IPv4 :53 listener"* ]]
}

@test "router-dns: an unreadable bind capture is a skip, not a pass" {
    interfaces_capture ifaces.txt 192.168.8.1

    # RED if the unreadable path were treated as empty text, because an empty
    # capture would then reach the "no IPv4 address" guard and report a parse
    # failure rather than a missing file.
    run router_dns_binds_check "$FIX/ifaces.txt" "$BATS_TEST_TMPDIR/nope.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"SKIP: cannot read the listener capture"* ]]
}
