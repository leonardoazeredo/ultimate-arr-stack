#!/usr/bin/env bats
# An Alpine (musl) client must resolve a `.lan` name when the router is its only
# resolver.
#
# Why this file exists, and why it is separate from the dig-based tests:
# `address=/lan/::` is in the NAS Pi-hole's config for one reason. musl, which
# Alpine and every other musl-based container uses, treats an AAAA NXDOMAIN as a
# hard resolution failure rather than "no IPv6 here", so a `.lan` name with an A
# record and no AAAA record is not reachable from those containers at all. That
# behaviour is invisible to `dig`, which happily reports the A record and the
# empty AAAA separately. Only a real musl getaddrinfo call shows it.
#
# THE ROUTER IS THE RESOLVER UNDER TEST
#
# Not the NAS. After the migration the router answers for the house, so the
# assertion is made with the router and nothing else in the resolver list. The
# NAS is used here only as a recorded reference for what "correct" looks like.
#
# Watch it fail, because it does: measured 2026-09-19, from an Alpine 3.20
# container with `--dns <router>`:
#
#   getent ahostsv4 sonarr.lan   -> rc 2
#   nslookup sonarr.lan          -> ** server can't find sonarr.lan: NXDOMAIN
#
# The router's dnsmasq carries `local=/lan/`, which makes it answer NXDOMAIN for
# any `.lan` name it does not know rather than forwarding it. The same container
# pointed at the NAS Pi-hole resolves `sonarr.lan` to 192.168.110.250 over IPv4
# and to `::` over IPv6. Those two readings are the whole point of this file:
# the NAS has the answers, the router does not, and a musl client is the one
# that notices hardest.
#
# Vantage point: any host that can run a container AND reach the router. The
# router has to be reachable from inside the container, not just from the host,
# which is a real constraint and the reason the first test below is a
# reachability check rather than an assumption.

ALPINE_IMAGE="${ALPINE_IMAGE:-alpine:3.20}"
LAN_NAME="${LAN_NAME:-sonarr.lan}"
TRAEFIK_VLAN10_IP="${TRAEFIK_VLAN10_IP:-192.168.110.250}"
PUBLIC_NAME="${PUBLIC_NAME:-example.com}"

setup() {
    load helpers/setup
    source "$BATS_TEST_DIRNAME/helpers/router.bash"

    ROUTER_DNS_IP="$(router_ip_for_host || true)"
}

# Requires: a working docker, a reachable router, and a router address this host
# can actually use. Each has its own reason so the skip says which one is
# missing.
require_container_dns_vantage() {
    command -v docker >/dev/null 2>&1 \
        || skip "docker not installed - cannot run a musl client"
    docker info >/dev/null 2>&1 \
        || skip "docker daemon not reachable - cannot run a musl client"
    require_router
    [[ -n "$ROUTER_DNS_IP" ]] \
        || skip "no router address shares a subnet with this host, so there is no interface to point a client at"
}

# Run a shell snippet in Alpine with the router as its ONLY resolver.
musl_sh() {
    docker run --rm --dns "$ROUTER_DNS_IP" "$ALPINE_IMAGE" sh -c "$1" 2>&1
}

# What the router actually answered, for the failure message. `getent` writes
# nothing on failure - only an exit status - so a message built from its output
# alone reads as "it did not work" and teaches the reader nothing. Also see
# which resolver replied, because a container quietly falling back to its own
# resolver would otherwise look like the router answering.
musl_what_the_router_said() {
    musl_sh "nslookup $LAN_NAME 2>&1 | tail -3" | tr '\n' ' '
}

@test "alpine-dns: the container can resolve a public name through the router (vacuity guard)" {
    require_container_dns_vantage

    # Without this, every failure below is ambiguous: a container whose DNS
    # plumbing is broken for any reason would fail the `.lan` assertions and
    # read as a `.lan` problem. This says the path works before anything is
    # concluded from it.
    run musl_sh "getent hosts $PUBLIC_NAME"
    [ "$status" -eq 0 ] \
        || skip "the container cannot resolve even a public name through $ROUTER_DNS_IP, so nothing can be concluded about .lan: $output"
    [[ -n "$output" ]]
}

@test "alpine-dns: a musl client resolves a .lan name over IPv4 to the Traefik address" {
    require_container_dns_vantage

    run musl_sh "getent ahostsv4 $LAN_NAME"
    local rc="$status"
    [ "$rc" -eq 0 ] \
        || fail "musl could not resolve $LAN_NAME over IPv4 through the router ($ROUTER_DNS_IP): getent exited $rc. The router answered: $(musl_what_the_router_said)"
    [[ "$output" == *"$TRAEFIK_VLAN10_IP"* ]] \
        || fail "$LAN_NAME resolved to something other than $TRAEFIK_VLAN10_IP: $output"
}

@test "alpine-dns: a .lan name is not a hard NXDOMAIN failure for a musl client" {
    require_container_dns_vantage

    # The `address=/lan/::` guard in one assertion. `getent hosts` calls
    # getaddrinfo, which is where musl turns an AAAA NXDOMAIN into an outright
    # failure even when the A record exists.
    run musl_sh "getent hosts $LAN_NAME"
    local rc="$status"
    [ "$rc" -eq 0 ] \
        || fail "getaddrinfo for $LAN_NAME failed outright through the router (getent exited $rc) - this is the musl/AAAA case. The router answered: $(musl_what_the_router_said)"
}

@test "alpine-dns: the AAAA answer for a .lan name is not NXDOMAIN" {
    require_container_dns_vantage

    # What this row is for: musl treats an AAAA NXDOMAIN as a hard failure, so
    # the AAAA query for a `.lan` name has to come back answered rather than
    # refused. It must NOT be pinned to the literal `::`.
    #
    # The two resolvers answer this row differently and both are correct.
    # dnsmasq, the fallback underneath, holds `address=/lan/::` and answers the
    # literal `::`. AdGuard Home, the healthy path, answers NOERROR with no
    # record at all, because its DNS rewrites carry an IPv4 address only. Phase
    # 3.3 of the migration plan decided the NODATA form is sufficient, and
    # measured why: musl's hard failure is AAAA *NXDOMAIN*, not an empty answer.
    # Pinning `::` here would therefore fail on the healthy path and pass on the
    # fallback -- the exact inversion of what this row is for. See the LAN_AAAA
    # case in scripts/lib/dns-matrix.sh.
    #
    # Measured through the router on 2026-09-21, Alpine 3.20 with `--dns <router>`:
    #   nslookup -type=AAAA sonarr.lan  ->  NODATA, rc 0
    #   nslookup -type=A    sonarr.lan  ->  192.168.110.250
    #   getent hosts        sonarr.lan  ->  192.168.110.250, rc 0
    run musl_sh "nslookup -type=AAAA $LAN_NAME"

    [[ "$output" != *"NXDOMAIN"* ]] \
        || fail "AAAA for $LAN_NAME came back NXDOMAIN, which musl treats as a hard failure: $output"
    [[ "$output" != *"no servers could be reached"* && "$output" != *"timed out"* ]] \
        || fail "the AAAA query for $LAN_NAME never reached a resolver, so nothing about .lan AAAA was tested: $output"

    # If a record came back at all it has to be `::`, the only AAAA value the
    # fixture records for a `.lan` name. Any other address would mean the name
    # points somewhere nobody declared.
    if [[ "$output" == *"Name:"* ]]; then
        [[ "$output" == *"::"* ]] \
            || fail "$LAN_NAME answered AAAA with a record that is not the recorded '::': $output"
    fi
    echo "$output"
}

# NOT tested, and why: that a Docker container can `connect()` to `::` and reach
# Traefik. It cannot - Linux maps a destination of `::` to `::1`, the loopback of
# the container itself - and that is a documented trap in this repo, not a defect
# this migration introduces or can fix. The requirement here is narrower and is
# what the NAS satisfies today: getaddrinfo must SUCCEED, so a client that
# prefers IPv4 (or falls back to it) can reach the service. Asserting that `::`
# is connectable would encode a false expectation.
#
# Also not covered by the mutation corpus, for a stated reason rather than an
# oversight: the guard is a container's exit status against a live resolver, and
# the configuration that would break it lives on the router, not in a file this
# repo can mutate. There is nothing here to break and watch go red without
# fabricating a change to the test's own assertion, which would prove nothing.
