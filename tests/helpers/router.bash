#!/bin/bash
# Router access for the live DNS tests.
#
# The migration's acceptance tests all need to look at the router: what dnsmasq
# has bound, what the redirect chain holds, what the router answers on :53. This
# file is the one place that knows how to get there, because two test files
# needing it is where the repo's convention says a helper stops being
# indirection.
#
# TWO WAYS IN, AND WHY BOTH ARE HERE
#
# `ssh arr-stack-router` works from a host that can route to 192.168.8.1. From a
# client VLAN it is refused outright — measured 2026-09-19, port 22 refused from
# VLAN20, while the same hop through pi1 answers — so the fallback is
# `ssh pi@pi1.local 'ssh arr-stack-router ...'`. The probe picks whichever
# answers and everything else goes through the same door. A host with neither
# gets a skip with the reason, never a silent pass.
#
# READ-ONLY BY CONSTRUCTION
#
# These tests observe; they do not configure. `router_sh` refuses any script
# containing a mutating verb before it opens a connection, so a test cannot
# write to the router even by accident. That guard exists because on 2026-09-19
# a *rehearsal* wrote `dhcp.lan.dhcp_option` into live `/etc/config` — the
# mechanism was different and the class is the same, and "it was only a test"
# is not a property that survives contact with a live device serving the
# house's DNS.
#
# Scripts go over stdin (`sh -s`), never interpolated into an argv. Quoting a
# command through two ssh hops is where the bugs live; stdin has no such edge.

ROUTER_SSH_TARGET="${ROUTER_SSH_TARGET:-arr-stack-router}"
ROUTER_JUMP="${ROUTER_JUMP:-pi@pi1.local}"
ROUTER_SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes)
ROUTER_PATH=""
ROUTER_SSH_ERR=""

# Verbs that change the router. Checked against the script text before it is
# sent. Deliberately broad and fail-closed: a read-only script that trips this
# is a false positive worth having, and a comment mentioning a mutating verb in
# a test will simply have to be reworded.
#
# Two shapes here were wrong first and are written down so they stay right:
#   * `uci` may carry flags before the verb (`uci -q set ...`), so the rule
#     allows flag words in between. Without that, the qualified form walks
#     straight past a guard that catches the unqualified one.
#   * an iptables mutating flag need not be the first argument — `iptables -t
#     nat -I ...` is how the redirect would actually be added, and requiring
#     the flag immediately after `iptables` missed it.
ROUTER_DENY_RE='(^|[[:space:]])uci([[:space:]]+-[^[:space:]]+)*[[:space:]]+(set|add|add_list|delete|commit|revert|import|rename|reorder)'
ROUTER_DENY_RE+='|(^|[[:space:]])(reboot|halt|poweroff)'
ROUTER_DENY_RE+='|/etc/init\.d/[a-z0-9_-]+[[:space:]]+(start|stop|restart|reload|enable|disable)'
ROUTER_DENY_RE+='|(^|[[:space:]])iptables.*-[AIDXNFZE]'
ROUTER_DENY_RE+='|(^|[[:space:]])nft[[:space:]]+(add|delete|flush|insert|replace)'
ROUTER_DENY_RE+='|(^|[[:space:]])docker[[:space:]]+(rm|stop|restart|kill|compose)'

_router_try() {
    local mode="$1" out rc
    if [[ "$mode" == direct ]]; then
        out=$(printf 'echo router-ok\n' | ssh "${ROUTER_SSH_OPTS[@]}" "$ROUTER_SSH_TARGET" sh -s 2>&1)
        rc=$?
    else
        out=$(printf 'echo router-ok\n' | ssh "${ROUTER_SSH_OPTS[@]}" "$ROUTER_JUMP" \
                  "ssh -o ConnectTimeout=8 -o BatchMode=yes '$ROUTER_SSH_TARGET' sh -s" 2>&1)
        rc=$?
    fi
    if [[ "$rc" -eq 0 && "$out" == *router-ok* ]]; then
        return 0
    fi
    ROUTER_SSH_ERR="$out"
    return 1
}

# Resolve once per test process. Cheap enough not to cache across tests, and a
# stale cache would be worse than a repeated probe: the whole point of checking
# is that the answer can change (another plan parks the NAS on a branch, a
# tunnel drops).
router_probe() {
    [[ -n "$ROUTER_PATH" ]] && return 0
    if _router_try direct; then ROUTER_PATH=direct; return 0; fi
    if _router_try jump;   then ROUTER_PATH=jump;   return 0; fi
    return 1
}

# router_sh — run a shell script (stdin) on the router, print its stdout.
router_sh() {
    local script
    script=$(cat)
    if printf '%s' "$script" | grep -Eq "$ROUTER_DENY_RE"; then
        printf 'router_sh: REFUSING a script that changes the router:\n%s\n' "$script" >&2
        return 99
    fi
    router_probe || {
        printf 'router_sh: no route to %s: %s\n' "$ROUTER_SSH_TARGET" "${ROUTER_SSH_ERR:-no error text}" >&2
        return 1
    }
    if [[ "$ROUTER_PATH" == direct ]]; then
        ssh "${ROUTER_SSH_OPTS[@]}" "$ROUTER_SSH_TARGET" sh -s <<<"$script"
    else
        ssh "${ROUTER_SSH_OPTS[@]}" "$ROUTER_JUMP" \
            "ssh -o ConnectTimeout=8 -o BatchMode=yes '$ROUTER_SSH_TARGET' sh -s" <<<"$script"
    fi
}

# router_cmd <shell text> — the one-command form of router_sh.
router_cmd() {
    printf '%s\n' "$*" | router_sh
}

# Skip, with the reason, on a host that cannot reach the router. Never a silent
# pass: a suite where the router tests simply did not run reads exactly like one
# where the router is fine.
require_router() {
    router_probe || skip "cannot reach the router at '$ROUTER_SSH_TARGET' (direct or via $ROUTER_JUMP) - nothing to assert from here: ${ROUTER_SSH_ERR:-no error text}"
}

# The host's own IPv4 addresses. `ip` where it exists, `ifconfig` otherwise —
# macOS has no `ip`, and a VLAN20 laptop is a legitimate vantage point, so
# detection that only works on Linux would skip the very host that can see the
# problem.
host_ipv4_addrs() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | awk '/[[:space:]]inet[[:space:]]/ {print $2}' | sed 's/^addr://'
    fi
}

# The router's IPv4 addresses, as the router sees them.
router_ipv4_addrs() {
    printf '%s\n' "ip -4 -o addr show 2>/dev/null | awk '{print \$4}' | cut -d/ -f1" | router_sh
}

# The router address this host would actually query: the one sharing a /24 with
# one of the host's own addresses. Derived rather than configured, because the
# answer differs by vantage point — a VLAN20 client uses 192.168.120.1, the
# maintenance host 192.168.8.1 — and a hardcoded address would silently test the
# wrong interface from the other side.
router_ip_for_host() {
    local ip prefix mine m
    mine=$(host_ipv4_addrs | grep -v '^127\.' || true)
    [[ -n "$mine" ]] || return 1
    local theirs
    theirs=$(router_ipv4_addrs) || return 1
    for ip in $theirs; do
        prefix="${ip%.*}"
        for m in $mine; do
            if [[ "${m%.*}" == "$prefix" ]]; then
                printf '%s\n' "$ip"
                return 0
            fi
        done
    done
    return 1
}
