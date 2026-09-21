#!/usr/bin/env bats
# router/firewall.user
#
# This file is the only thing that puts a client's :53 on AdGuard Home. It is
# sourced by fw3 on every firewall reload, and it runs at boot before AdGuard
# does, so the properties worth proving are about what it points the house at:
#
#   * it points at AdGuard when AdGuard answers, and does not drift there on a
#     whim — a probe that failed spuriously would cost ad blocking;
#   * it points at dnsmasq when AdGuard does NOT answer, which is the state a
#     router reboot creates: the firewall starts at S19 and AdGuard at S99, with
#     48 init scripts and `network` between them. Redirecting a client at a
#     resolver that is not listening is the one thing this migration promised
#     never to do, and nothing else catches that window — the watchdog needs
#     three consecutive failures and cron starts at S50, inside it;
#   * it does not probe at all when the port file already says dnsmasq;
#   * it strips its own rules first, because fw3 does not flush the built-in
#     PREROUTING chain and a reload would otherwise stack another ten.
#
# No router is involved. `iptables` and `dig` are stubs on PATH under
# $BATS_TEST_TMPDIR, and the port file and the probe path are redirected with
# ARRDNS_PORT_FILE and ARRDNS_DIG — the same shape tests/adguard-stage.bats uses
# for AGH_INIT/AGH_CONFIG.

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init

    FIREWALL="$REPO_ROOT/router/firewall.user"
    PORT_FILE="$BATS_TEST_TMPDIR/arrdns-port"
    IPT_LOG="$BATS_TEST_TMPDIR/iptables.log"
    DIG_LOG="$BATS_TEST_TMPDIR/dig.log"
    RULES_FILE="$BATS_TEST_TMPDIR/rules"
    export PORT_FILE IPT_LOG DIG_LOG RULES_FILE
    export ARRDNS_PORT_FILE="$PORT_FILE"
    export ARRDNS_DIG="$STUB_DIR/dig"

    printf '0\n' > "$RULES_FILE"
    : > "$IPT_LOG"
    : > "$DIG_LOG"

    # `-L` reports however many rules RULES_FILE holds and `-D` removes one, so
    # the strip loop terminates the way the real one does. A stub that always
    # reported the same rule would hang instead of testing anything.
    stub_tool iptables '#!/usr/bin/env bash
printf "%s\n" "$*" >> "$IPT_LOG"
case "$*" in
  *"-t nat -L PREROUTING"*)
    n=$(cat "$RULES_FILE" 2>/dev/null || echo 0)
    i=1
    while [ "$i" -le "$n" ]; do
      echo "$i REDIRECT tcp -- 0.0.0.0/0 0.0.0.0/0 tcp dpt:53 redir ports 3053"
      i=$((i + 1))
    done
    exit 0 ;;
  *"-t nat -D PREROUTING"*)
    n=$(cat "$RULES_FILE" 2>/dev/null || echo 0)
    if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$RULES_FILE"; fi
    exit 0 ;;
esac
exit 0'

    stub_tool dig '#!/usr/bin/env bash
printf "%s\n" "$*" >> "$DIG_LOG"
exit 0'
}

# The stub answers, or stays silent the way a resolver that is not listening does.
dig_answers() {
    stub_tool dig '#!/usr/bin/env bash
printf "%s\n" "$*" >> "$DIG_LOG"
printf "140.82.121.4\n"'
}
dig_is_silent() {
    stub_tool dig '#!/usr/bin/env bash
printf "%s\n" "$*" >> "$DIG_LOG"
exit 1'
}

port_file() { printf '%s\n' "$1" > "$PORT_FILE"; }
rules_present() { printf '%s\n' "$1" > "$RULES_FILE"; }
targets_used() { grep -oE 'to-ports [0-9]+' "$IPT_LOG" | awk '{print $2}' | sort -u | tr '\n' ' '; }

@test "firewall-user: AdGuard answering keeps the house on AdGuard" {
    port_file 3053
    dig_answers

    run bash "$FIREWALL"
    [ "$status" -eq 0 ]

    # RED if the fallback fired on a resolver that was answering — the failure
    # mode where a flaky probe silently drops every client's ad blocking.
    [[ "$(targets_used)" == "3053 " ]]
    [ "$(cat "$PORT_FILE")" = "3053" ]
}

@test "firewall-user: AdGuard silent falls back to dnsmasq, and records it" {
    port_file 3053
    dig_is_silent

    run bash "$FIREWALL"
    [ "$status" -eq 0 ]

    # RED if the probe were dropped: this is the router-reboot window, where
    # every client would be redirected at a resolver that is not listening.
    [[ "$(targets_used)" == "53 " ]]
    # Written back too, so the file, the rules and the watchdog agree. The
    # watchdog's adguard branch then restores 3053 on its next tick, which is a
    # recovery path the watchdog's own tests already cover.
    [ "$(cat "$PORT_FILE")" = "53" ]
}

@test "firewall-user: every client interface is redirected, on both transports" {
    port_file 3053
    dig_answers

    bash "$FIREWALL"

    # The list is derived here from the same set the include carries, and the
    # total is computed from it rather than written as a number: a hardcoded 10
    # was correct until the tailnet joined, and would have been "fixed" by
    # bumping it rather than by noticing which interface was missing.
    local -a ifaces=(br-lan.1 br-lan.10 br-lan.20 br-lan.30 br-guest tailscale0)
    local iface
    for iface in "${ifaces[@]}"; do
        # RED if the interface list were narrowed — GL.iNet's own dispatcher
        # covers only br-lan.1 and br-guest, which is how three VLANs ended up
        # unfiltered once already.
        [[ "$(grep -c -- "-i $iface -p udp --dport 53" "$IPT_LOG")" -ge 1 ]]
        [[ "$(grep -c -- "-i $iface -p tcp --dport 53" "$IPT_LOG")" -ge 1 ]]
    done
    [ "$(grep -c -- '-j REDIRECT' "$IPT_LOG")" -eq "$(( ${#ifaces[@]} * 2 ))" ]
}

@test "firewall-user: already on dnsmasq, it does not probe AdGuard" {
    port_file 53
    dig_is_silent

    run bash "$FIREWALL"
    [ "$status" -eq 0 ]

    # RED if the probe ran unconditionally. Probing when the answer cannot change
    # anything adds a dig to every firewall reload, and gives a down AdGuard a
    # second way to influence the rules.
    [ ! -s "$DIG_LOG" ]
    [[ "$(targets_used)" == "53 " ]]
    [ "$(cat "$PORT_FILE")" = "53" ]
}

@test "firewall-user: it strips its own rules before inserting again" {
    port_file 3053
    dig_answers
    rules_present 2

    bash "$FIREWALL"

    # RED if the delete loop were removed: fw3 does not flush the built-in
    # PREROUTING chain, so a reload would leave the old rules and add ten more,
    # which is the state this file was written to fix. Two planted rules, so two
    # deletes — and the loop has to stop once they are gone.
    [ "$(grep -c -- '-t nat -D PREROUTING' "$IPT_LOG")" -eq 2 ]
    [ "$(cat "$RULES_FILE")" = "0" ]
}

@test "firewall-user: the tailnet is redirected when it is in scope" {
    port_file 3053
    dig_answers

    bash "$FIREWALL"

    # RED while ARRDNS_IFACES omits tailscale0. A tailnet device would resolve
    # through dnsmasq and get no ad blocking, unlike every device at home -- which
    # is the state this was measured in on 2026-09-21: a tailnet query for a
    # blocklisted name returned a real address while a bridge client got 0.0.0.0.
    [[ "$(grep -c -- "-i tailscale0 -p udp --dport 53" "$IPT_LOG")" -ge 1 ]]
    [[ "$(grep -c -- "-i tailscale0 -p tcp --dport 53" "$IPT_LOG")" -ge 1 ]]
}
