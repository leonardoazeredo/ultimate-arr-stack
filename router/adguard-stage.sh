#!/bin/sh
# adguard-stage.sh — Phase 2: start AdGuard Home on 3053 and give it an admin
# credential, without putting it in the query path.
#
# RUNS ON THE ROUTER. OpenWrt 21.02, busybox ash: no bash, no arrays.
#
#   ADMIN_PASSWORD='...' sh adguard-stage.sh
#   DRY_RUN=1 sh adguard-stage.sh
#
# Idempotent. Running it a second time finds the service enabled, finds the
# instance already configured, and changes nothing.
#
# WHY THE CREDENTIAL COMES FIRST
#
# As shipped, `/etc/AdGuardHome/config.yaml` carries `users: []`. That is not
# "no password yet" in a harmless sense: it is an unauthenticated admin API on
# port 3000, and the maintenance VLAN reaches it in 6 ms. Anything on that VLAN
# could rewrite or block any domain for every client in the house. So the
# instance is configured in the same run that starts it, and the script refuses
# to report success with an empty `users:` unless it was never asked for a
# password in the first place.
#
# WHY dns_enabled IS WATCHED AND NOT SET
#
# Phase 2 stages a resolver; it does not put one in the path. `dns_enabled`
# controls the firewall REDIRECT that sends :53 to AdGuard, and it must still be
# '0' when this finishes. The script records the value before it does anything
# and fails if it moved: a staged resolver that has quietly taken over is the
# opposite of what this phase is for, and it would be a house-wide cutover with
# none of Phase 3's parity work behind it.
#
# The password arrives in the environment, never in argv (a process list is
# world-readable on this box) and never in a file.

set -u

UCI="${UCI:-uci}"
CURL="${CURL:-curl}"
DIG="${DIG:-dig}"
AGH_INIT="${AGH_INIT:-/etc/init.d/adguardhome}"
AGH_CONFIG="${AGH_CONFIG:-/etc/AdGuardHome/config.yaml}"
WEB_PORT="${WEB_PORT:-3000}"
DNS_PORT="${DNS_PORT:-3053}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
DRY_RUN="${DRY_RUN:-0}"

say() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

run() {
    if [ "$DRY_RUN" = "1" ]; then
        say "DRY-RUN: $*"
        return 0
    fi
    "$@"
}

# --- what state are we in? --------------------------------------------------

dns_enabled_before=$("$UCI" -q get adguardhome.config.dns_enabled 2>/dev/null || echo "<unset>")
enabled_before=$("$UCI" -q get adguardhome.config.enabled 2>/dev/null || echo "<unset>")

if [ -r "$AGH_CONFIG" ] && grep -qE '^users:[[:space:]]*\[\]' "$AGH_CONFIG"; then
    configured=0
else
    configured=1
fi

say "before: enabled=$enabled_before dns_enabled=$dns_enabled_before configured=$configured"

# Refuse before starting anything, rather than starting an open admin API and
# then discovering there is nothing to close it with. The check is deliberately
# here and not only in the credential section: enabling an unauthenticated
# AdGuard and then failing to credential it leaves the exposure in place.
if [ "$configured" -eq 0 ] && [ "$DRY_RUN" != "1" ]; then
    [ -n "${ADMIN_PASSWORD_HASH:-}" ] \
        || fail "the instance is unconfigured and no ADMIN_PASSWORD_HASH was given. Starting it unauthenticated would expose an admin API to the maintenance VLAN, so this refuses rather than doing that"
    [ -n "$ADMIN_PASSWORD" ] \
        || fail "the instance is unconfigured and no ADMIN_PASSWORD was given, so the credential written could not be verified"
fi

# --- stage the service ------------------------------------------------------

if [ "$enabled_before" != "1" ]; then
    run "$UCI" set adguardhome.config.enabled=1
    run "$UCI" commit adguardhome
else
    say "ok: adguardhome.config.enabled is already 1"
fi

if [ "$DRY_RUN" = "1" ]; then
    run "$AGH_INIT" restart
    say "DRY-RUN complete: nothing was changed."
    exit 0
fi

# `restart` rather than `start`: start is a no-op when procd already has the
# service. Only restarted when something actually changed - every restart runs
# `/etc/init.d/firewall reload` inside start_service, which flushes DNS
# conntrack, so a no-op re-run should not cost the house a DNS blip.
if [ "$enabled_before" != "1" ]; then
    "$AGH_INIT" restart >/dev/null 2>&1 || true
fi

# --- wait for the web UI ----------------------------------------------------
#
# AdGuard takes a moment, and an install POST sent before it listens fails in a
# way that looks like a credential problem.
tries=0
while [ "$tries" -lt 30 ]; do
    if "$CURL" -s -o /dev/null "http://127.0.0.1:$WEB_PORT/" 2>/dev/null; then
        break
    fi
    tries=$((tries + 1))
    sleep 1
done
[ "$tries" -lt 30 ] || fail "the AdGuard web UI did not answer on 127.0.0.1:$WEB_PORT within 30s"

# --- set the credential -----------------------------------------------------
#
# The first-run installer is NOT available on this box, and that is worth
# writing down because the obvious approach fails confusingly:
#
#   POST /control/install/configure  ->  404
#
# AdGuard only registers the /control/install/* routes when it starts without a
# config file. GL.iNet ships a populated /etc/AdGuardHome/config.yaml, so
# AdGuard considers itself configured from the first boot and the wizard never
# exists - with `users: []` sitting in that file. `/control/status` answering
# 401 unauthenticated confirms the API is there and wants a user that does not
# yet exist.
#
# So the credential goes in the file, as AdGuard stores it: a bcrypt hash under
# `users:`. bcrypt cannot be computed on this router (busybox has no htpasswd
# and there is no python), so the hash is computed off-box and passed in -
# `htpasswd -nbB <user> '<password>'`, with the leading `$2y$` rewritten to
# `$2a$` because Go's bcrypt does not accept the `$2y$` marker some htpasswd
# builds emit.
#
# ADMIN_PASSWORD is passed alongside the hash for one reason only: to log in
# afterwards and prove the credential actually works. A self-check that only
# inspected the file would pass on a hash AdGuard cannot parse, which is a
# router with a password nobody can use and a check that says it is fine.
if [ "$configured" -eq 1 ]; then
    say "ok: the instance is already configured; leaving its credential alone"
else
    [ -n "${ADMIN_PASSWORD_HASH:-}" ] \
        || fail "the instance is unconfigured and no ADMIN_PASSWORD_HASH was given"
    [ -n "$ADMIN_PASSWORD" ] \
        || fail "the instance is unconfigured and no ADMIN_PASSWORD was given - without it this script cannot verify the credential it just wrote"

    case "$ADMIN_PASSWORD_HASH" in
        \$2a\$*|\$2b\$*) ;;
        *) fail "ADMIN_PASSWORD_HASH is not a \$2a\$/\$2b\$ bcrypt hash. AdGuard will not accept it, and the file would look configured while the API stayed unusable" ;;
    esac

    cp "$AGH_CONFIG" "$AGH_CONFIG.before-stage"
    awk -v u="$ADMIN_USER" -v h="$ADMIN_PASSWORD_HASH" '
        $0 == "users: []" {
            print "users:"
            print "  - name: " u
            print "    password: " h
            next
        }
        { print }
    ' "$AGH_CONFIG" > /tmp/agh-config.new || fail "could not rewrite $AGH_CONFIG"

    grep -qE '^users:[[:space:]]*\[\]' /tmp/agh-config.new \
        && fail "the rewrite left an empty users list - refusing to install a config that changes nothing"

    cat /tmp/agh-config.new > "$AGH_CONFIG" || fail "could not write $AGH_CONFIG"
    rm -f /tmp/agh-config.new
    say "ok: wrote a users entry for '$ADMIN_USER' into $AGH_CONFIG (previous copy at $AGH_CONFIG.before-stage)"

    "$AGH_INIT" restart >/dev/null 2>&1 || true
    tries=0
    while [ "$tries" -lt 30 ]; do
        "$CURL" -s -o /dev/null "http://127.0.0.1:$WEB_PORT/" 2>/dev/null && break
        tries=$((tries + 1))
        sleep 1
    done
fi

# --- self-check -------------------------------------------------------------

failed=0

if grep -qE '^users:[[:space:]]*\[\]' "$AGH_CONFIG"; then
    say "FAIL: $AGH_CONFIG still has an empty 'users:', so the admin API is unauthenticated"
    failed=1
else
    say "ok: $AGH_CONFIG carries a user, so the UI is no longer open"
fi

# Unauthenticated requests must be refused. 200 here would mean the credential
# did not take effect even though the file looks right.
status=$("$CURL" -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$WEB_PORT/control/status" 2>/dev/null || echo none)
case "$status" in
    401|403) say "ok: an unauthenticated /control/status is refused (HTTP $status)" ;;
    *)       say "FAIL: an unauthenticated /control/status answered HTTP ${status:-<none>}, expected 401 or 403"
             failed=1 ;;
esac

# The half that matters: the credential has to actually log in. A file that
# looks right and a hash AdGuard cannot parse are indistinguishable without
# this, and the difference is a router with a password nobody can use.
#
# Via /control/login, NOT HTTP Basic. Measured on this build: a `curl -u admin:…`
# request to /control/status is answered 401 even when the password is correct,
# because the API authenticates with a session cookie and never looks at the
# Authorization header. Verifying the credential with Basic auth would report a
# working password as broken - and, worse, a check written that way and then
# "fixed" by loosening it is how a real mismatch gets waved through.
if [ -n "$ADMIN_PASSWORD" ]; then
    case "$ADMIN_PASSWORD" in
        *'"'*|*'\'*) say "FAIL: ADMIN_PASSWORD contains a double quote or backslash, which the login body cannot carry, so it cannot be verified here"
                     failed=1 ;;
        *)
            # No `-X POST` on purpose: `--data-binary` already makes this a
            # POST, so the flag is redundant - and the repo's stub harness
            # treats `-X POST` as a mutating call and refuses it, which would
            # make this script untestable through the one harness that exists.
            login_status=$(
                printf '{"name":"%s","password":"%s"}' "$ADMIN_USER" "$ADMIN_PASSWORD" \
                | "$CURL" -s -o /dev/null -w '%{http_code}' \
                      "http://127.0.0.1:$WEB_PORT/control/login" \
                      -H 'Content-Type: application/json' --data-binary @- 2>/dev/null
            ) || true
            case "$login_status" in
                200) say "ok: '$ADMIN_USER' logs in (HTTP 200 from /control/login)" ;;
                *)   say "FAIL: logging in as '$ADMIN_USER' answered HTTP ${login_status:-<none>}, expected 200. The instance is running with a credential that does not work."
                     failed=1 ;;
            esac
            ;;
    esac
fi

# The staged resolver has to be answering, or Phase 2 verified nothing. Polled
# rather than asked once: the DNS proxy comes up a moment after the web UI, and
# a single probe right after a restart reported "does not answer" for a resolver
# that was serving normally a second later.
dns_tries=0
dns_ok=0
while [ "$dns_tries" -lt 15 ]; do
    if "$DIG" +short +time=3 +tries=1 example.com "@127.0.0.1" -p "$DNS_PORT" >/dev/null 2>&1; then
        dns_ok=1
        break
    fi
    dns_tries=$((dns_tries + 1))
    sleep 1
done
if [ "$dns_ok" -eq 1 ]; then
    say "ok: AdGuard answers on 127.0.0.1:$DNS_PORT"
else
    say "FAIL: AdGuard does not answer on 127.0.0.1:$DNS_PORT after 15s"
    failed=1
fi

dns_enabled_after=$("$UCI" -q get adguardhome.config.dns_enabled 2>/dev/null || echo "<unset>")
if [ "$dns_enabled_after" = "$dns_enabled_before" ]; then
    say "ok: dns_enabled is unchanged ($dns_enabled_after) - no client's queries were moved"
else
    say "FAIL: dns_enabled moved from '$dns_enabled_before' to '$dns_enabled_after'. This script stages a resolver; it must not put one in the path."
    failed=1
fi

[ "$failed" -eq 0 ] || { say "STAGING INCOMPLETE"; exit 1; }
say "OK: AdGuard Home staged on $DNS_PORT with a credential, dns_enabled='$dns_enabled_after', no redirect installed."
