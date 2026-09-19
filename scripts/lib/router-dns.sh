#!/bin/bash
# Verdicts over raw router output. Text in, verdict out: no ssh, no uci, no
# iptables, no network. tests/router-dns.bats fetches the text from the router
# and judges it through here; tests/lib-router-dns.bats feeds the same functions
# synthetic text, so the reasoning runs on a host with no router and can be
# mutated.
#
# WHY THE SPLIT
#
# tests/router-dns.bats skips on every host that cannot reach the router, and
# `ssh arr-stack-router` is refused from a client VLAN -- so on most machines it
# is a file that only ever skips. A guard that can only ever skip cannot be
# shown to be capable of failing. The reasoning lives here instead, where it runs
# everywhere. Same shape as scripts/lib/dns-matrix.sh + tests/lib-dns-matrix.bats.
#
# WHAT THESE CHECKS DELIBERATELY DO NOT ASSERT
#
#   * Which resolver a pool advertises. That value is the migration's variable:
#     before Phase 5 the four target pools point at the NAS (192.168.110.246),
#     during Phase 5 at each VLAN's router address, and after 5.6 they carry no
#     option 6 at all so dnsmasq advertises itself. Pinning the value here would
#     turn a legitimate migration step into a red test, which is exactly how a
#     guard gets deleted instead of fixed.
#   * Which process holds :53. What a client can reach is the socket; whether
#     dnsmasq or AdGuard Home answers behind the redirect is Phase 6's business
#     and is asserted in tests/dns-resilience.bats, not from configuration.
#   * IPv6. dnsmasq binds :53 on a long list of link-local addresses that change
#     with every interface event; the migration is IPv4 (`ra` and `dhcpv6` are
#     disabled on vlan10/20/30) and an IPv6 bind list would be a moving target
#     that fails for reasons no one is migrating.
#
# RETURN CODES, used the same way by every check_* function:
#
#   0  the invariant holds
#   1  the invariant is broken -- the text was read, and it says something wrong
#   2  the check could not run -- nothing parsed, an unreadable state, a capture
#      that is not the output it claims to be
#
# 2 is never a pass. An empty capture satisfies every assertion it never makes,
# which is the failure mode this repo keeps having to dig back out of a merged
# guard.

# ---------------------------------------------------------------------------
# Input plumbing
# ---------------------------------------------------------------------------

# router_dns_read [path] -- an empty path or "-" reads stdin.
router_dns_read() {
    local path="${1:-}"
    if [[ -z "$path" || "$path" == "-" ]]; then
        cat
        return 0
    fi
    [[ -r "$path" ]] || return 1
    cat "$path"
}

# How many whitespace-separated words are in $1. Empty string counts 0.
_router_dns_count_words() {
    local n=0
    for _ in $1; do n=$((n + 1)); done
    printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# `uci show dhcp`
# ---------------------------------------------------------------------------

# router_dns_pool_names -- stdin: `uci show dhcp` -> one pool name per line.
#
# A pool is a section declared with type `dhcp`. The same output also carries
# `dhcp.@dnsmasq[0]=dnsmasq` (the resolver's own config), `dhcp.wgclient1=dnsmasq`
# (a second, disabled dnsmasq instance with its own port 2153) and
# `dhcp.odhcpd=odhcpd`; none of those is a DHCP pool, and matching on the `.=`
# suffix rather than on the `dhcp.` prefix is what keeps them out.
router_dns_pool_names() {
    sed -n 's/^dhcp\.\([^.|=]*\)=dhcp$/\1/p'
}

# router_dns_option6_entries -- stdin: `uci show dhcp` -> "<pool>\t<code>\t<rest>"
# for every value of every pool's `dhcp_option` list, one line per value.
#
# uci renders a list as space-separated quoted values, so a pool that has been
# half-moved to a second resolver arrives on ONE line:
#
#     dhcp.lan.dhcp_option='6,192.168.110.246' '6,192.168.110.1'
#
# Splitting that line into values is the whole point of this function; a parser
# that read only the first value would report a half-moved pool as correct.
router_dns_option6_entries() {
    local pool block value
    while IFS='|' read -r pool block; do
        [[ -n "$pool" ]] || continue
        # Strip the quotes uci wraps each value in and split on whitespace. A
        # dhcp_option value has no embedded space in any option this check reads
        # (option 6 is a bare address); a value that did would be mis-split here,
        # which is why the per-pool check also validates the shape of what it got
        # rather than trusting the split.
        block="${block//\'/}"
        for value in $block; do
            if [[ "$value" == *,* ]]; then
                printf '%s\t%s\t%s\n' "$pool" "${value%%,*}" "${value#*,}"
            else
                printf '%s\t%s\t%s\n' "$pool" "$value" ""
            fi
        done
    done < <(sed -n 's/^dhcp\.\([^.|=]*\)\.dhcp_option=/\1|/p')
}

# router_dns_is_ipv4 <string> -- a dotted quad with every octet in 0..255.
#
# The range check is not pedantry: `6,999.1.1.1` matches a bare
# `[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+` shape and is not an address any client can
# use, so a shape-only test would call a broken handout well-formed.
router_dns_is_ipv4() {
    local ip="$1" octet
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local IFS='.'
    for octet in $ip; do
        # 10# so a leading zero is decimal (08) and not an octal parse error.
        (( 10#$octet <= 255 )) || return 1
    done
    return 0
}

# router_dns_option6_check <known-pools> <capture-path>
#
# <known-pools> is a space-separated list of the pools the migration targets.
# The check asserts, of each:
#
#   * the pool exists in the capture (a missing pool would otherwise pass on the
#     zero values it contributed);
#   * it advertises AT MOST ONE resolver -- a second value is a pool that has
#     been half-moved, which is the failure this catches;
#   * anything it does advertise is a well-formed `6,<ipv4>`;
#
# and of every other pool: that it advertises no resolver at all. `guest` and
# `iot` are the ones on this router with no option 6 today, and a resolver
# appearing on either is a migration step nobody declared.
#
# Zero values is a PASS, not an omission: task 5.6 deletes option 6 from all four
# target pools so dnsmasq advertises itself, and that end state has to be able to
# pass. What keeps the all-zero case from being vacuous is the pool-existence
# assertion above and the "parsed no pools" guard below.
router_dns_option6_check() {
    local known="$1" path="${2:--}"
    local text
    text=$(router_dns_read "$path") || {
        echo "SKIP: cannot read the uci capture '$path'"
        return 2
    }

    local pools entries lines
    pools=$(printf '%s\n' "$text" | router_dns_pool_names)
    if [[ -z "$pools" ]]; then
        lines=$(printf '%s' "$text" | grep -c '' || true)
        echo "FAIL: parsed no dhcp pools out of ${lines} lines - this is not 'uci show dhcp' output, or its shape changed. Every assertion below would be vacuous."
        return 2
    fi
    entries=$(printf '%s\n' "$text" | router_dns_option6_entries)

    local pool value listing count failures=0 checked=0
    for pool in $known; do
        if ! printf '%s\n' "$pools" | grep -qxF "$pool"; then
            printf 'FAIL %-8s not present in the capture, so nothing about it was judged\n' "$pool"
            failures=$((failures + 1))
            continue
        fi
        checked=$((checked + 1))

        # Counted in awk, over entries, NOT by word-counting the extracted
        # values: `dhcp_option='6'` is one entry with an empty address, and a
        # word count reads that as zero entries and reports the pool as
        # advertising nothing. The first version of this function did exactly
        # that, and tests/lib-router-dns.bats caught it.
        count=$(printf '%s\n' "$entries" \
            | awk -F'\t' -v p="$pool" '$1 == p && $2 == 6 { n++ } END { print n + 0 }')
        listing=$(printf '%s\n' "$entries" \
            | awk -F'\t' -v p="$pool" '$1 == p && $2 == 6 { printf "6,%s ", $3 }')

        case "$count" in
            0)
                printf 'ok   %-8s no resolver advertised (dnsmasq advertises itself)\n' "$pool"
                ;;
            1)
                value=$(printf '%s\n' "$entries" \
                    | awk -F'\t' -v p="$pool" '$1 == p && $2 == 6 { print $3; exit }')
                if router_dns_is_ipv4 "$value"; then
                    printf 'ok   %-8s 6,%s\n' "$pool" "$value"
                else
                    printf 'FAIL %-8s option 6 is not a well-formed 6,<ipv4>: got "6,%s"\n' \
                        "$pool" "$value"
                    failures=$((failures + 1))
                fi
                ;;
            *)
                printf 'FAIL %-8s advertises %s resolvers (%s) - a half-moved pool, and no client can be predicted to use one of them\n' \
                    "$pool" "$count" "${listing% }"
                failures=$((failures + 1))
                ;;
        esac
    done

    local p c r
    while IFS=$'\t' read -r p c r; do
        [[ -n "$p" ]] || continue
        [[ "$c" == "6" ]] || continue
        if [[ " $known " != *" $p "* ]]; then
            printf 'FAIL %-8s advertises a resolver but is not a migration target: 6,%s\n' "$p" "$r"
            failures=$((failures + 1))
        fi
    done <<<"$entries"

    echo "--- option 6: ${checked}/$(_router_dns_count_words "$known") target pools present, ${failures} problem(s) ---"
    [[ "$failures" -eq 0 ]] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# `iptables -t nat -S adg_redirect`
# ---------------------------------------------------------------------------
#
# The canonical form is parsed, not `iptables -t nat -L adg_redirect -n`. `-S`
# prints one rule per line as the argv that would create it, so the protocol,
# the jump target and `--to-ports` each sit in a fixed token; the `-L` table pads
# columns and folds the match options into one free-text column whose width
# depends on the longest address in the table. The live test captures `-L -n` as
# well, but only to print it next to a failure for a human to read.
#
# The `-N` declaration is required, which also makes this function fail-closed
# against the wrong capture: handed `-L -n` output, it reports the chain missing
# rather than reporting zero rules and passing whatever state it was given.

# router_dns_redirect_rules -- stdin: `-S adg_redirect` -> "<prot>\t<target>\t<to-ports>\t<full rule>"
router_dns_redirect_rules() {
    local line
    while IFS= read -r line; do
        [[ "$line" == "-A adg_redirect "* ]] || continue
        local -a f
        read -r -a f <<<"$line"
        local prot="" target="" toports="" i=0 n=${#f[@]}
        while [[ "$i" -lt "$n" ]]; do
            case "${f[$i]}" in
                -p)          prot="${f[$((i + 1))]:-}";   i=$((i + 2)); continue ;;
                -j)          target="${f[$((i + 1))]:-}"; i=$((i + 2)); continue ;;
                --to-ports)  toports="${f[$((i + 1))]:-}"; i=$((i + 2)); continue ;;
                --to-ports=*) toports="${f[$i]#--to-ports=}"; i=$((i + 1)); continue ;;
            esac
            i=$((i + 1))
        done
        printf '%s\t%s\t%s\t%s\n' "${prot:-?}" "${target:-?}" "$toports" "$line"
    done
}

# router_dns_redirect_check <dns_enabled> <capture-path>
#
# The invariant, and why it is one: /etc/firewall.dns_order declares the chain
# unconditionally through iptables-restore, so it exists in BOTH states and an
# "exists iff enabled" assertion is wrong at baseline. What changes with
# adguardhome.config.dns_enabled is only what the chain holds:
#
#   0 -> no rules. dnsmasq on :53 answers, which is what the NAS migration
#        falls back to.
#   1 -> a tcp and a udp REDIRECT --to-ports 3053. UDP is the transport a client
#        actually resolves over; a tcp-only chain passes a TCP probe while
#        leaving real resolution broken, which is the trap
#        tests/network-segmentation.bats already documents for port 53.
#
# Anything else is a failure, in both directions: a rule while disabled means
# queries are being redirected to a resolver the configuration says is off, and
# a missing arm while enabled means one transport reaches dnsmasq and the other
# does not.
router_dns_redirect_check() {
    local enabled="$1" path="${2:--}"
    local text
    text=$(router_dns_read "$path") || {
        echo "SKIP: cannot read the redirect capture '$path'"
        return 2
    }

    if [[ "$enabled" != "0" && "$enabled" != "1" ]]; then
        echo "FAIL: adguardhome.config.dns_enabled is '${enabled:-<unset>}', expected 0 or 1 - which rules the chain should hold is undecidable, so this check cannot pass"
        return 2
    fi

    if ! printf '%s\n' "$text" | grep -qE '^-N[[:space:]]+adg_redirect([[:space:]]|$)'; then
        echo "FAIL: the nat table does not declare the chain adg_redirect. It is created unconditionally by iptables-restore from /etc/firewall.dns_order, so its absence is the firewall having changed, not a state of the migration. Capture was:"
        printf '%s\n' "$text" | sed 's/^/     /'
        return 1
    fi

    local rules
    rules=$(printf '%s\n' "$text" | router_dns_redirect_rules)

    local count=0 line
    while IFS= read -r line; do
        [[ -n "$line" ]] && count=$((count + 1))
    done <<<"$rules"

    if [[ "$enabled" == "0" ]]; then
        if [[ "$count" -gt 0 ]]; then
            echo "FAIL: dns_enabled='0' but adg_redirect holds ${count} rule(s): queries on :53 are redirected to a resolver this configuration says is off:"
            printf '%s\n' "$rules" | sed 's/^/     /'
            return 1
        fi
        echo "--- adg_redirect: dns_enabled=0, chain declared, 0 rules ---"
        return 0
    fi

    local prot target toports rule tcp=0 udp=0 failures=0
    while IFS=$'\t' read -r prot target toports rule; do
        [[ -n "$prot" ]] || continue
        if [[ "$target" == "REDIRECT" && "$toports" == "3053" \
              && ( "$prot" == "tcp" || "$prot" == "udp" ) ]]; then
            [[ "$prot" == "tcp" ]] && tcp=$((tcp + 1))
            [[ "$prot" == "udp" ]] && udp=$((udp + 1))
        else
            printf 'FAIL adg_redirect holds a rule that is not a tcp/udp REDIRECT --to-ports 3053: %s\n' "$rule"
            failures=$((failures + 1))
        fi
    done <<<"$rules"

    if [[ "$tcp" -lt 1 ]]; then
        echo "FAIL: dns_enabled='1' but adg_redirect has no tcp REDIRECT --to-ports 3053 rule - TCP queries on :53 still reach dnsmasq while UDP goes to AdGuard Home"
        failures=$((failures + 1))
    fi
    if [[ "$udp" -lt 1 ]]; then
        echo "FAIL: dns_enabled='1' but adg_redirect has no udp REDIRECT --to-ports 3053 rule - UDP is the transport DNS is actually used over, so this is the arm whose absence stops resolution"
        failures=$((failures + 1))
    fi

    [[ "$failures" -eq 0 ]] || return 1
    echo "--- adg_redirect: dns_enabled=1, chain declared, tcp+udp REDIRECT --to-ports 3053 (${tcp} tcp, ${udp} udp) ---"
    return 0
}

# ---------------------------------------------------------------------------
# `ip -4 -o addr show` vs `netstat -lntup`
# ---------------------------------------------------------------------------

# router_dns_ipv4_addrs -- stdin: `ip -4 -o addr show` -> one address per line.
#
# The `inet` token is located by scanning fields rather than by column index:
# `-o` puts the address in field 4 today, but the interface name can contain a
# dot (`br-lan.1`) and a second address on one interface would shift everything.
router_dns_ipv4_addrs() {
    awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "inet") {
                a = $(i + 1)
                sub(/\/.*/, "", a)
                print a
                break
            }
        }
    }'
}

# router_dns_port53_addrs -- stdin: `netstat -lntup` (or `ss -lntup`) -> one
# address per line, for every listener whose port is 53.
#
# Field-by-field too, and also shape-tolerant: netstat puts the local address in
# field 4 and `ss` in field 5, and the address that matters is whichever field
# ends in `:53`. IPv6 addresses come back as-is and are separated from IPv4 by
# the caller, because `fe80::x:53` ends in `:53` for exactly the same reason.
router_dns_port53_addrs() {
    awk '{
        for (i = 1; i <= NF; i++) {
            if ($i !~ /:[0-9]+$/) continue
            port = $i
            sub(/.*:/, "", port)
            if (port != "53") continue
            addr = $i
            sub(/:[0-9]+$/, "", addr)
            print addr
            break
        }
    }'
}

# router_dns_binds_check <interface-capture> <listener-capture>
#
# Asserts dnsmasq holds :53 on every live non-loopback IPv4 the router has.
#
# BOTH SIDES ARE DERIVED FROM THE ROUTER. A hardcoded list of the five VLAN-side
# addresses was the plan's first draft, and it is wrong in two directions at
# once: it silently stops covering an interface added later, and it keeps
# demanding a bind on an address that no longer exists. The `iot` pool is the
# live example -- `network.iot.disabled='1'`, so br-iot never comes up, there is
# no 192.168.10.1 in `ip -4 addr`, and dnsmasq correctly has nothing to bind
# there. Derived, that needs no special case; hardcoded, it needed a paragraph
# of apology and would have gone stale.
#
# The stale direction is asserted too: a :53 bind on an IPv4 the router does not
# have means a listener left behind on a disabled or removed interface, which is
# the shape of the iot problem if it ever appears. A wildcard bind (0.0.0.0) is
# reported but not failed -- it covers every address, so it cannot strand a
# client, and the failure this check exists for is a MISSING bind.
router_dns_binds_check() {
    local iface_path="$1" listener_path="$2"
    local iface_text listener_text
    iface_text=$(router_dns_read "$iface_path") || {
        echo "SKIP: cannot read the interface capture '$iface_path'"
        return 2
    }
    listener_text=$(router_dns_read "$listener_path") || {
        echo "SKIP: cannot read the listener capture '$listener_path'"
        return 2
    }

    local live required bound
    live=$(printf '%s\n' "$iface_text" | router_dns_ipv4_addrs | sort -u)
    if [[ -z "$live" ]]; then
        echo "FAIL: parsed no IPv4 address out of 'ip -4 -o addr show' - this is not that output, or its shape changed. Every assertion below would be vacuous."
        return 2
    fi

    required=$(printf '%s\n' "$live" | grep -v '^127\.' || true)
    if [[ -z "$required" ]]; then
        echo "FAIL: the router has no non-loopback IPv4 address at all, so there is no bind to require"
        return 2
    fi

    # IPv4 only, on this side too. dnsmasq also binds every link-local IPv6
    # address it can find, and comparing those would make the check fail on
    # `::1` alone -- an address on no interface's list by design. The migration
    # is IPv4; the IPv6 list is a moving target and is out of scope, stated in
    # the file header.
    bound=$(printf '%s\n' "$listener_text" | router_dns_port53_addrs \
        | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u || true)
    if [[ -z "$bound" ]]; then
        echo "FAIL: parsed no IPv4 :53 listener out of 'netstat -lntup' - either nothing is listening on :53, or the capture is not that output. Assertion would be vacuous."
        return 2
    fi

    local wildcard=0
    printf '%s\n' "$bound" | grep -qxE '0\.0\.0\.0|\*' && wildcard=1

    local ip failures=0 bound_count=0
    for ip in $bound; do bound_count=$((bound_count + 1)); done

    for ip in $required; do
        if [[ "$wildcard" -eq 1 ]] || printf '%s\n' "$bound" | grep -qxF "$ip"; then
            printf 'ok   %-16s :53 bound\n' "$ip"
        else
            printf 'FAIL %-16s has no :53 bind - dnsmasq is not listening on this live interface, so a client on it cannot resolve at all\n' "$ip"
            failures=$((failures + 1))
        fi
    done

    local extras=0
    for ip in $bound; do
        case "$ip" in
            127.*) continue ;;
            0.0.0.0 | '*') continue ;;
        esac
        printf '%s\n' "$live" | grep -qxF "$ip" && continue
        printf 'FAIL %-16s has a :53 bind but is not an address this router has - a listener left behind on an interface that no longer exists\n' "$ip"
        failures=$((failures + 1))
        extras=$((extras + 1))
    done

    if [[ "$wildcard" -eq 1 ]]; then
        echo "note: a wildcard :53 bind is present, which covers every address; the per-address binds above are informational"
    fi
    echo "--- :53 binds: $(_router_dns_count_words "$required") live non-loopback address(es), ${bound_count} distinct :53 bind(s), ${extras} stale, ${failures} problem(s) ---"
    [[ "$failures" -eq 0 ]] || return 1
    return 0
}
