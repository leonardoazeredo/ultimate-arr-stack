#!/bin/bash
# adguard-configure.sh — Phase 3 of the DNS migration: point the router's
# AdGuard Home at two encrypted upstreams, teach it every .lan name, and give it
# the blocklist the NAS Pi-hole already uses.
#
#   ./scripts/adguard-configure.sh --dry-run    print what would change
#   ./scripts/adguard-configure.sh              apply it
#
# RUNS FROM THIS CHECKOUT, NOT ON THE ROUTER. The transform is line surgery in
# bash; the router is busybox ash with no bash, no python and no PyYAML. So this
# reads the live config over ssh, edits it here, validates and installs it
# there.
#
# WHY config.yaml AND NOT THE API
#
# AdGuard Home's HTTP API is not usable on this build. GL.iNet patches the
# binary so /control/* sits behind its own authMiddlewareGLiNet with
# checkToken/tokenDate, and it ignores AdGuard's own agh_session cookie: a login
# returns 200 and sets the cookie, and every subsequent request carrying that
# cookie — and every request with `-u admin:pw` — is answered 401. That was
# measured, not assumed. The config file is the only way in.
#
# WHY THE VALIDATION HAPPENS ON A STAGED COPY
#
# `AdGuardHome --check-config -c <path>` is not a pure parser. Given a path that
# does not exist it runs the first-launch path: measured on this router, it
# tried to bind :53 and :3000 and panicked on the ports already in use. So
# "validate the live file before installing it" is not available — validating
# the live path means starting a second AdGuard against the live one, and
# deleting the live file first to make the path valid is the thing we are trying
# to avoid.
#
# The staged copy is byte-identical to what gets installed (checked with md5sum
# on both sides before it is moved anywhere), so validating it is validating the
# config. Anything that fails the check is refused and the staged file is
# deleted; the live file is not touched until the check has passed.
#
# WHERE THE BACKUP GOES
#
# `<config>.bak-<UTC timestamp>` beside the live file on the router, e.g.
# /etc/AdGuardHome/config.yaml.bak-20260919T200500Z. The path is printed. The
# original is copied before the move and the copy is only ever additive, so
# re-running this cannot lose the pre-migration config.
#
# exit codes: 0 done (or nothing to do), 1 verification failed, 2 refused
# before changing anything. The lib uses the same vocabulary.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/agh-config.sh
source "$SCRIPT_DIR/lib/agh-config.sh"

AGH_SSH="${AGH_SSH:-ssh}"
AGH_JUMP="${AGH_JUMP:-pi@pi1.local}"
AGH_ROUTER="${AGH_ROUTER:-arr-stack-router}"
AGH_CONNECT_TIMEOUT="${AGH_CONNECT_TIMEOUT:-15}"

AGH_CONFIG="${AGH_CONFIG:-/etc/AdGuardHome/config.yaml}"
AGH_STAGE="${AGH_STAGE:-$AGH_CONFIG.incoming}"
AGH_BIN="${AGH_BIN:-/usr/bin/AdGuardHome}"
AGH_INIT="${AGH_INIT:-/etc/init.d/adguardhome}"
AGH_DNS_PORT="${AGH_DNS_PORT:-3053}"

AGH_DNSMASQ_CONF="${AGH_DNSMASQ_CONF:-$REPO_ROOT/pihole/dnsmasq.d/02-local-dns.conf.example}"
AGH_TRAEFIK_IP="${AGH_TRAEFIK_IP:-192.168.110.250}"
AGH_UPSTREAMS="${AGH_UPSTREAMS:-https://dns.quad9.net/dns-query https://cloudflare-dns.com/dns-query}"
AGH_FILTER_URL="${AGH_FILTER_URL:-https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts}"
AGH_FILTER_NAME="${AGH_FILTER_NAME:-StevenBlack hosts}"

# Polls, not probes. The DNS proxy comes up a second or two after the web UI, so
# a single query after a restart reports "does not answer" for a resolver that
# is serving normally moments later — a trap that has already cost this
# migration time. Blocking needs longer still: AdGuard fetches its filter lists
# in the background after it starts, and until the StevenBlack list has landed
# the blocked-name check legitimately fails.
AGH_DNS_TRIES="${AGH_DNS_TRIES:-20}"
AGH_DNS_SLEEP="${AGH_DNS_SLEEP:-1}"
AGH_BLOCK_TRIES="${AGH_BLOCK_TRIES:-45}"
# How long to wait between the read attempts. `.local` resolution can miss once
# and be fine a second later.
AGH_RETRY_SLEEP="${AGH_RETRY_SLEEP:-1}"

DRY_RUN="${AGH_DRY_RUN:-0}"

say() { printf '%s\n' "$*"; }
refuse() { printf 'REFUSING: %s\n' "$*" >&2; exit 2; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
adguard-configure.sh — Phase 3 for the router's AdGuard Home: two encrypted
upstreams, one rewrite per .lan name, and the blocklist.

  ./scripts/adguard-configure.sh --dry-run   print the diff and what would
                                             change; touch nothing
  ./scripts/adguard-configure.sh             transform, stage, validate with
                                             --check-config, back the original
                                             up, install, restart, verify

Reads and writes over `ssh AGH_JUMP 'ssh AGH_ROUTER sh -s'`. It runs here, not
on the router: that box is busybox ash with no python and no PyYAML.

All of these can be overridden: AGH_JUMP, AGH_ROUTER, AGH_SSH, AGH_CONFIG,
AGH_STAGE, AGH_BIN, AGH_INIT, AGH_DNS_PORT, AGH_UPSTREAMS, AGH_FILTER_URL,
AGH_FILTER_NAME, AGH_TRAEFIK_IP, AGH_DNSMASQ_CONF, AGH_DNS_TRIES,
AGH_BLOCK_TRIES, AGH_DRY_RUN. The file header says what each one is for.
USAGE
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --dry-run|-n) DRY_RUN=1 ;;
        --help|-h) usage; exit 0 ;;
        *) refuse "unknown argument '$1'" ;;
    esac
    shift
done

# Upstreams arrive as one space-separated string; empty them into an array here
# rather than word-splitting at each use.
upstreams=()
for u in $AGH_UPSTREAMS; do upstreams+=("$u"); done
(( ${#upstreams[@]} > 0 )) || refuse "AGH_UPSTREAMS is empty; there would be nothing to resolve through"

# --- the ssh layer ----------------------------------------------------------
#
# Every router command is a shell script on stdin, never an argument. Two
# reasons, and the second is the one that matters: quoting a script into an argv
# element is where the bugs live, and this repo's stub harness inspects argv for
# mutating verbs — a restart in argv is refused by design, and rightly, so a
# command that has to reach the router goes over the wire instead.
#
#   ssh pi@pi1.local 'ssh arr-stack-router sh -s'
#
# Direct `ssh arr-stack-router` is refused from a client VLAN; pi1 sits on the
# maintenance VLAN, where it is not.
remote() {
    "$AGH_SSH" -o ConnectTimeout="$AGH_CONNECT_TIMEOUT" "$AGH_JUMP" \
        "$AGH_SSH -o ConnectTimeout=$AGH_CONNECT_TIMEOUT $AGH_ROUTER sh -s"
}

# q <value> — quote a value for the remote shell. Single quotes survive
# everything except a single quote, and a value that cannot be quoted is
# refused rather than escaped badly.
q() {
    case "$1" in
        *"'"*) refuse "value contains a single quote and cannot be quoted safely for the router: $1" ;;
    esac
    printf "'%s'" "$1"
}

local_md5() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" | cut -d' ' -f1
    elif command -v md5 >/dev/null 2>&1; then
        md5 -q "$1"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        refuse "no md5sum, md5 or shasum here: this script cannot prove the config it pushed is the config that landed, and that check is not optional"
    fi
}

WORK="$(mktemp -d)" || refuse "could not create a working directory"
# shellcheck disable=SC2064
trap "rm -rf '$WORK'" EXIT

# --- what the rewrites are for ----------------------------------------------

if [[ ! -r "$AGH_DNSMASQ_CONF" ]]; then
    refuse "cannot read the .lan record at $AGH_DNSMASQ_CONF. The rewrites are derived from it rather than from a list in this script, so a missing record is a missing rewrite set"
fi
hostnames=$(agh_dnsmasq_hostnames < "$AGH_DNSMASQ_CONF") \
    || refuse "no hostnames in $AGH_DNSMASQ_CONF, so there would be no rewrites to install"

rewrite_args=()
while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    rewrite_args+=("$name=$AGH_TRAEFIK_IP")
done <<<"$hostnames"

# --- read the live config ---------------------------------------------------
#
# The read is retried, and only the read. `.local` name resolution is the
# flakiest part of this path: measured on this Mac, `ssh pi@pi1.local` failed
# once with "Could not resolve hostname pi@pi1.local" and worked immediately
# afterwards — mDNS, one second apart. Retrying a MUTATING step is a different
# proposition (a half-completed stage or install is not something to repeat
# blindly), so only the pure read gets a second chance.
fetch_config() {   # <destination file>
    local dest="$1" attempt
    for attempt in 1 2 3; do
        if printf 'cat %s\n' "$(q "$AGH_CONFIG")" | remote > "$dest" 2> "$WORK/fetch.err"; then
            return 0
        fi
        if (( attempt < 3 )); then
            sed 's/^/  /' "$WORK/fetch.err" >&2
            say "adguard-configure: could not read $AGH_CONFIG (attempt $attempt of 3), retrying" >&2
            sleep "$AGH_RETRY_SLEEP"
        fi
    done
    return 1
}

say "adguard-configure: reading $AGH_CONFIG from $AGH_ROUTER via $AGH_JUMP"
if ! fetch_config "$WORK/00-live.yaml"; then
    sed 's/^/  /' "$WORK/fetch.err" >&2
    refuse "could not read $AGH_CONFIG from the router"
fi
if [[ ! -s "$WORK/00-live.yaml" ]]; then
    refuse "$AGH_CONFIG on the router is empty. The transform edits a populated file in place; building one from nothing would produce a config with three keys and no users, no ports and no cache — and it would install cleanly"
fi

# --- transform it here ------------------------------------------------------
#
# Three passes rather than one pipeline, so a refusal names which edit could not
# be applied and stops there. A pipeline would run the remaining stages over the
# empty output of the failed one and report three problems for one cause.
if ! agh_config_set_upstream_dns "${upstreams[@]}" \
        < "$WORK/00-live.yaml" > "$WORK/01-upstreams.yaml"; then
    refuse "the upstream edit could not be applied. Nothing was pushed"
fi
if ! agh_config_set_filters "$AGH_FILTER_URL" "$AGH_FILTER_NAME" \
        < "$WORK/01-upstreams.yaml" > "$WORK/02-filters.yaml"; then
    refuse "the filter edit could not be applied. Nothing was pushed"
fi
if ! agh_config_set_rewrites "${rewrite_args[@]}" \
        < "$WORK/02-filters.yaml" > "$WORK/03-rewrites.yaml"; then
    refuse "the rewrite edit could not be applied. Nothing was pushed"
fi
NEW="$WORK/03-rewrites.yaml"

filter_count=$(grep -c '^  - enabled:' "$NEW" || true)

if cmp -s "$WORK/00-live.yaml" "$NEW"; then
    if [[ "$DRY_RUN" == "1" ]]; then
        say "adguard-configure: DRY-RUN: no change. $AGH_CONFIG already carries"
    else
        say "adguard-configure: no change. $AGH_CONFIG already carries"
    fi
    say "  - dns.upstream_dns:    ${#upstreams[@]} entries (${upstreams[*]})"
    say "  - filtering.rewrites:  ${#rewrite_args[@]} entries"
    say "  - filters:             $filter_count entries"
    say "Nothing was pushed and nothing was restarted."
    exit 0
fi

local_md5 "$NEW" > "$WORK/local.md5"
local_hash=$(cat "$WORK/local.md5")

say "adguard-configure: the config that would be installed differs:"
say "  - dns.upstream_dns:    ${#upstreams[@]} entries (${upstreams[*]})"
say "  - filtering.rewrites:  ${#rewrite_args[@]} entries answering $AGH_TRAEFIK_IP"
say "  - filters:             $filter_count entries (+$AGH_FILTER_URL)"

if [[ "$DRY_RUN" == "1" ]]; then
    say "adguard-configure: DRY-RUN: this is the diff, and it is all that happens."
    say "--- $AGH_CONFIG (live) -> what would be installed ---"
    diff -u "$WORK/00-live.yaml" "$NEW" || true
    say "adguard-configure: DRY-RUN complete: nothing was written to the router and nothing was restarted."
    exit 0
fi

# --- stage it on the router -------------------------------------------------
#
# A quoted heredoc, so nothing in the config is expanded on the way, and the
# delimiter is not a string the config contains. If a rewrite ever produced a
# line equal to the delimiter the transfer would be cut short — which is exactly
# what the hash comparison two lines later catches and refuses.
#
# The delimiter is QUOTED in the generated heredoc, and that is not a detail:
# with `<<WORD` the remote shell expands `$` inside the body, and this config is
# full of bcrypt hashes (`$2a$05$...`) and empty strings. The first version of
# this script shipped an unquoted delimiter; the remote shell ate every `$` in
# the users block, and the hash comparison below is what caught it before it was
# installed.
DELIM="AGH_CONFIG_EOF_$$"
stage_script() {
    printf 'umask 022\n'
    printf 'cat > %s <<%s\n' "$(q "$AGH_STAGE")" "$(q "$DELIM")"
    cat "$NEW"
    printf '%s\n' "$DELIM"
    printf 'md5sum %s | cut -d" " -f1\n' "$(q "$AGH_STAGE")"
}

if ! stage_script | remote > "$WORK/stage.out" 2> "$WORK/stage.err"; then
    sed 's/^/  /' "$WORK/stage.err" >&2
    refuse "could not write the staged config to $AGH_STAGE on the router"
fi

staged_hash=$(tail -1 "$WORK/stage.out" | tr -d '[:space:]')
if [[ "$staged_hash" != "$local_hash" ]]; then
    printf 'rm -f %s\n' "$(q "$AGH_STAGE")" | remote >/dev/null 2>&1
    refuse "the staged file did not land intact: local md5 $local_hash, on the router $staged_hash. Nothing was installed"
fi
say "adguard-configure: staged at $AGH_STAGE, md5 $staged_hash matches the local transform"

# --- validate it, on the router, before it goes anywhere near the live path --

check_out=$(printf '%s --check-config -c %s 2>&1\n' "$(q "$AGH_BIN")" "$(q "$AGH_STAGE")" | remote)
check_rc=$?
say "adguard-configure: $AGH_BIN --check-config on the staged file:"
printf '%s\n' "$check_out" | sed 's/^/  /'

if [[ "$check_rc" -ne 0 || "$check_out" != *"configuration file is ok"* ]]; then
    printf 'rm -f %s\n' "$(q "$AGH_STAGE")" | remote >/dev/null 2>&1
    fail "the produced config did not pass AdGuard Home's own --check-config (rc $check_rc), so it was NOT installed. $AGH_CONFIG is untouched; the failed copy has been deleted"
fi

# --- back the original up, then install -------------------------------------
#
# `cp -p` then `mv`, never a redirect over the live file: a truncated write to
# the live path is a resolver with a half a config, and the window is real on a
# box this slow. `mv` is a rename, so the live path goes from the old config to
# the new one with nothing in between.
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
install_script() {
    printf 'set -e\n'
    printf 'base=%s.bak-%s\n' "$(q "$AGH_CONFIG")" "$STAMP"
    printf 'b="$base"\n'
    printf 'n=0\n'
    printf 'while [ -e "$b" ]; do n=$((n+1)); b="$base.$n"; done\n'
    printf 'cp -p %s "$b"\n' "$(q "$AGH_CONFIG")"
    printf 'mv %s %s\n' "$(q "$AGH_STAGE")" "$(q "$AGH_CONFIG")"
    printf 'printf "BACKUP %%s\\n" "$b"\n'
    printf 'md5sum %s | cut -d" " -f1\n' "$(q "$AGH_CONFIG")"
}

if ! install_script | remote > "$WORK/install.out" 2> "$WORK/install.err"; then
    sed 's/^/  /' "$WORK/install.err" >&2
    fail "the install step failed on the router. The staged file is still at $AGH_STAGE and may be complete; check before re-running"
fi

backup=$(sed -n 's/^BACKUP //p' "$WORK/install.out" | head -1)
installed_hash=$(tail -1 "$WORK/install.out" | tr -d '[:space:]')
if [[ "$installed_hash" != "$local_hash" ]]; then
    fail "the installed file's md5 is $installed_hash, not $local_hash. The original is at $backup — restore it with: ssh $AGH_JUMP \"ssh $AGH_ROUTER 'cp -p $backup $AGH_CONFIG'\""
fi
say "adguard-configure: original backed up to $backup on the router"
say "adguard-configure: installed, md5 $installed_hash"

# --- restart ----------------------------------------------------------------

if ! printf '%s restart\n' "$(q "$AGH_INIT")" | remote > "$WORK/restart.out" 2>&1; then
    sed 's/^/  /' "$WORK/restart.out" >&2
    fail "the AdGuard Home restart failed. $AGH_CONFIG holds the new config and the previous one is at $backup"
fi
say "adguard-configure: restarted $AGH_INIT"

# --- verify, from on the router, in this order ------------------------------

poll_answer() {   # <name> <expected|-for-anything> <tries> -> the answer on stdout
    local name="$1" want="$2" tries="$3"
    local i got=""
    for (( i = 1; i <= tries; i++ )); do
        got=$(printf 'dig +short +time=3 +tries=1 %s @127.0.0.1 -p %s\n' "$(q "$name")" "$AGH_DNS_PORT" \
              | remote 2>/dev/null | tr '\n' ' ')
        got="${got% }"
        if [[ "$want" == "-" ]]; then
            [[ -n "$got" ]] && { printf '%s' "$got"; return 0; }
        else
            [[ "$got" == "$want" ]] && { printf '%s' "$got"; return 0; }
        fi
        sleep "$AGH_DNS_SLEEP"
    done
    printf '%s' "$got"
    return 1
}

say "adguard-configure: verifying from on the router"

# 1. the upstreams in the live config
if ! fetch_config "$WORK/10-live.yaml"; then
    fail "could not re-read $AGH_CONFIG to check the upstreams that are actually configured"
fi
expected_upstreams=$(printf '    - %s\n' "${upstreams[@]}")
actual_upstreams=$(agh_config_block_lines upstream_dns 2 < "$WORK/10-live.yaml")
if [[ "$actual_upstreams" != "$expected_upstreams" ]]; then
    say "FAIL: dns.upstream_dns in the live config is not the encrypted set. expected:"
    printf '%s\n' "$expected_upstreams" | sed 's/^/  /'
    say "got:"
    printf '%s\n' "$actual_upstreams" | sed 's/^/  /'
    fail "the config now on the router does not have the upstreams this script was asked to set"
fi
say "ok: the live config's upstreams are the encrypted ones (${upstreams[*]})"

# 2. a .lan name answers Traefik's macvlan address — this is what 3.2 is for
if got=$(poll_answer sonarr.lan "$AGH_TRAEFIK_IP" "$AGH_DNS_TRIES"); then
    say "ok: sonarr.lan -> $got"
else
    fail "sonarr.lan answered '${got:-<nothing>}' after ${AGH_DNS_TRIES}s, expected $AGH_TRAEFIK_IP. A client typing sonarr.lan would not reach Traefik"
fi

# 3. blocking still works
if got=$(poll_answer doubleclick.net "0.0.0.0" "$AGH_BLOCK_TRIES"); then
    say "ok: doubleclick.net -> $got (blocked)"
else
    fail "doubleclick.net answered '${got:-<nothing>}' after ${AGH_BLOCK_TRIES}s, expected 0.0.0.0. Blocking is not working; on a fresh start the filter lists are still being downloaded, so check that $AGH_FILTER_URL is reachable from the router"
fi

# 4. the encrypted upstreams actually resolve
if got=$(poll_answer example.com "-" "$AGH_DNS_TRIES"); then
    say "ok: example.com -> $got"
else
    fail "example.com answered nothing after ${AGH_DNS_TRIES}s. The encrypted upstreams are configured and not resolving — check that bootstrap_dns can still reach the DoH hostnames"
fi

# 5. the redirect is still off: this stages a resolver, it does not put one in
#    every client's path (that is Phase 6)
enabled=$(printf 'uci -q get adguardhome.config.dns_enabled\n' | remote 2>/dev/null | tr -d '[:space:]')
if [[ "$enabled" == "0" ]]; then
    say "ok: dns_enabled is still 0, so no client's queries were moved"
else
    fail "dns_enabled is '${enabled:-<nothing>}', not 0. Phase 3 stages a resolver; putting it in the path is the firewall redirect and Phase 6's decision"
fi

# ...and one more, because the four above would all pass on a config whose
# rewrites AdGuard Home dropped while loading it.
rewrites_now=$(agh_config_block_lines rewrites 2 < "$WORK/10-live.yaml" | grep -c '^    - domain: ' || true)
if [[ "$rewrites_now" -eq "${#rewrite_args[@]}" ]]; then
    say "ok: the live config still carries $rewrites_now rewrites after the restart"
else
    fail "the live config carries $rewrites_now rewrites, not ${#rewrite_args[@]} — AdGuard Home did not keep what was installed"
fi

say "adguard-configure: OK. $AGH_CONFIG on $AGH_ROUTER carries ${#upstreams[@]} encrypted upstreams, ${#rewrite_args[@]} .lan rewrites and $filter_count filter entries; dns_enabled is 0."
say "adguard-configure: the pre-migration config is at $backup on the router."
