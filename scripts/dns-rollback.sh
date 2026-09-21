#!/bin/sh
# dns-rollback.sh — return every DHCP pool to the NAS resolver.
#
# Rung 1 of the rollback ladder in
# docs/superpowers/plans/2026-09-19-dns-adguard-router-migration.md.
#
# RUNS ON THE ROUTER. That box is OpenWrt 21.02 with busybox ash: no bash, no
# arrays, no `local` outside a function. Keep it that way.
#
#   sh dns-rollback.sh              for real
#   DRY_RUN=1 sh dns-rollback.sh    print the sequence, change nothing
#
# Everything below can be overridden, which exists for the rehearsal in 0.5 and
# for nothing else: NAS_RESOLVER, POOLS, UCI, UCI_CONF, DNSMASQ_INIT,
# FIREWALL_INIT, DIG.
#
# UCI_CONF is the one that needs saying out loud. `uci -c <dir>` reads and writes
# only that directory. The UCI_CONFIG_DIR *environment variable* looks like it
# does the same thing and does not: on this build uci ignores it and writes to
# the live /etc/config. Measured 2026-09-19, comparing the production file's md5
# before and after — an env-var rehearsal changed production, a `-c` rehearsal
# did not. So the rehearsal path goes through -c, which is why every uci call
# here is funnelled through uci_() instead of being written out.
#
# Three things it has to get right, each of which an earlier draft got wrong:
#
#   1. All four pools, not just `lan`. The maintenance pool carries the fewest
#      clients, which is why it is the easiest to forget, and leaving it out
#      strands the break-glass host on a resolver that is being retired.
#   2. `/etc/init.d/dnsmasq reload` after the commit. `uci commit` emits no
#      config.change event — nothing calls /sbin/reload_config except
#      /etc/init.d/boot — so without the reload dnsmasq keeps advertising the
#      old option indefinitely while this script reports success.
#   3. A qualified `uci commit` per package. A bare `uci commit` commits every
#      half-applied change in every config file on the box, which is not a
#      thing to do while rolling back.
#
# The self-check asserts the ADVERTISED VALUE, not that some resolver answers.
# "A resolver answered" is true at every point in this migration, including the
# points where the pool is still pointed at the NAS and the rollback did
# nothing.

set -u

NAS_RESOLVER="${NAS_RESOLVER:-192.168.110.246}"
POOLS="${POOLS:-lan vlan10 vlan20 vlan30}"
UCI="${UCI:-uci}"
UCI_CONF="${UCI_CONF:-}"
DNSMASQ_INIT="${DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
FIREWALL_INIT="${FIREWALL_INIT:-/etc/init.d/firewall}"
DIG="${DIG:-dig}"
DRY_RUN="${DRY_RUN:-0}"

say() { printf '%s\n' "$*"; }
refuse() { printf 'REFUSING: %s\n' "$*" >&2; exit 2; }

# run <command...> — execute it, or print it when rehearsing.
run() {
    if [ "$DRY_RUN" = "1" ]; then
        say "DRY-RUN: $*"
        return 0
    fi
    "$@"
}

# uci_ <args...> — the only way this script talks to uci. With UCI_CONF set,
# every call is scoped to that config directory, which is what lets the
# rehearsal in 0.5 exercise the real uci without touching the live one.
uci_() {
    if [ -n "$UCI_CONF" ]; then
        "$UCI" -c "$UCI_CONF" "$@"
    else
        "$UCI" "$@"
    fi
}

# run_uci <args...> — uci_ with a DRY_RUN transcript that shows the real
# command, -c and all, rather than the helper's name.
run_uci() {
    if [ "$DRY_RUN" = "1" ]; then
        if [ -n "$UCI_CONF" ]; then
            say "DRY-RUN: $UCI -c $UCI_CONF $*"
        else
            say "DRY-RUN: $UCI $*"
        fi
        return 0
    fi
    uci_ "$@"
}

# --- pre-flight -------------------------------------------------------------
#
# This script owns dhcp_option 6 and nothing else. Deleting a pool's
# dhcp_option removes ALL of that pool's options, so if a pool is carrying
# something this script did not put there, stop before touching anything
# instead of quietly dropping a live DHCP setting. Check every pool first, so a
# refusal leaves the box exactly as it was found.
for pool in $POOLS; do
    current=$(uci_ -q get "dhcp.$pool.dhcp_option" 2>/dev/null || true)
    for token in $current; do
        case "$token" in
            6,*) ;;
            *) refuse "dhcp.$pool.dhcp_option carries '$token', which is not a resolver option" ;;
        esac
    done
done

# --- apply ------------------------------------------------------------------
#
# Delete then re-add, rather than set: that normalises the option to a single
# value whether it arrived as a string or as a list, so the advertised result is
# the same shape either way.
for pool in $POOLS; do
    run_uci -q delete "dhcp.$pool.dhcp_option"
    run_uci add_list "dhcp.$pool.dhcp_option=6,$NAS_RESOLVER"
done

run_uci set "adguardhome.config.dns_enabled=0"
run_uci set "adguardhome.config.enabled=0"

run_uci commit dhcp
run_uci commit adguardhome
run_uci commit firewall

run "$DNSMASQ_INIT" reload
run "$FIREWALL_INIT" reload

if [ "$DRY_RUN" = "1" ]; then
    say "DRY-RUN complete: nothing was changed."
    exit 0
fi

# --- self-check -------------------------------------------------------------
#
# Assert what the DHCP server will actually advertise. A pool that still hands
# out the wrong resolver is the failure this whole script exists to undo, and it
# is invisible to a check that only asks whether DNS answers somewhere.
failed=0

for pool in $POOLS; do
    advertised=$(uci_ -q get "dhcp.$pool.dhcp_option" 2>/dev/null || true)
    if [ "$advertised" = "6,$NAS_RESOLVER" ]; then
        say "ok: $pool advertises $NAS_RESOLVER"
    else
        say "FAIL: $pool does not advertise $NAS_RESOLVER (got: ${advertised:-<unset>})"
        failed=1
    fi
done

if "$DIG" +short +time=2 +tries=1 example.com "@$NAS_RESOLVER" >/dev/null 2>&1; then
    say "ok: $NAS_RESOLVER answers"
else
    say "FAIL: $NAS_RESOLVER is not answering, so reverting the pools would strand them"
    failed=1
fi

if [ "$failed" -ne 0 ]; then
    say "ROLLBACK INCOMPLETE — clients may still be pointed at the wrong resolver."
    exit 1
fi

say "OK: every pool in '$POOLS' advertises $NAS_RESOLVER, and AdGuard Home is out of the path."
