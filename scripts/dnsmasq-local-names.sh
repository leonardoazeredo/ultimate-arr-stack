#!/bin/bash
# dnsmasq-local-names.sh — Phase 4.1 of the DNS migration: teach the router's
# dnsmasq the `.lan` names, so `.lan` resolves against the router's :53.
#
#   ./scripts/dnsmasq-local-names.sh --dry-run   print the records, change nothing
#   ./scripts/dnsmasq-local-names.sh             apply, reload, verify
#
# RUNS FROM THIS CHECKOUT, NOT ON THE ROUTER. The router is OpenWrt with busybox
# ash: no bash, no arrays, no `local` outside a function. So the record set is
# computed here and the router runs a short POSIX script that arrives on stdin.
#
# WHY THE RECORDS ARE PARSED AND NOT LISTED
#
# The names come from pihole/dnsmasq.d/02-local-dns.conf.example through
# agh_dnsmasq_hostnames, the same reader scripts/adguard-configure.sh uses for
# the AdGuard rewrites. Two parsers over one record is how the two stores drift:
# a service added to the record would be taught to one resolver and not the
# other, and nothing would look wrong until `dns_enabled` flipped. A hardcoded
# list is the same defect with a longer fuse.
#
# 192.168.110.250 is Traefik's macvlan. `.lan` names point at Traefik because
# port 80 is what is free there; it routes by Host header.
#
# THE APEX, AND WHY IT IS ADDED BY HAND
#
# `address=/lan/::` is in the record, and `agh_dnsmasq_hostnames` deliberately
# skips it: `lan` has no dot, so it is the zone rather than a host, and a
# rewrite for it would answer for every `.lan` name at once. It is carried here
# explicitly because its purpose is the AAAA side: a musl/Alpine client asking
# for AAAA on a `.lan` name must get an answer instead of the NXDOMAIN dnsmasq
# returns today, which such clients treat as a hard failure. `local=/lan/` does
# not supply that answer — it only stops the query being forwarded upstream —
# so the apex record is complementary to it and both stay.
#
# WHY THE CONFDIR IS NOT TOUCHED
#
# `dhcp.@dnsmasq[0].confdir` is `/tmp/dnsmasq.d`, which is tmpfs. Dropping
# `address=` files there is the most tempting way to do this and the wrong one:
# the names resolve until the next reboot and then vanish, with nothing on the
# box to show they were ever there. The records go into UCI, which is flash, and
# dnsmasq is pointed at them through its own init script.
#
# IDEMPOTENCY: COMPARE, THEN REBUILD
#
# `uci add_list` appends duplicates happily, so a second run that re-adds leaves
# 19 more records in flash while printing "applied" again. Two ways out: rebuild
# the list unconditionally, or compare first and change nothing when the records
# already say what they should. This compares first, because it keeps a run with
# nothing to do from committing and reloading dnsmasq at all — a no-op that
# bounces the house's resolver is not a no-op — and because the comparison is
# what "a second run changes nothing" means. When something has to change, the
# owned records are removed and re-added in sorted order rather than merged: a
# name deleted from the record file has to disappear from the router, and
# merging leaves it answering.
#
# Only the records this script owns are rewritten: the 18 hostnames from the
# record file, plus the apex. Anything else in the router's address list — a
# hand-added host, another dnsmasq instance — is left where it is.
#
# WHY THE COMMIT IS FOLLOWED BY A RELOAD
#
# `uci commit dhcp` emits no config.change event. `procd_add_reload_trigger
# "dhcp" "system"` fires on that event, and nothing on this box emits it except
# /sbin/reload_config, which only /etc/init.d/boot calls. So the commit writes
# flash and dnsmasq keeps serving the config it rendered at boot — indefinitely,
# while a script that stopped at the commit reports success.
#
# WHY THE VERIFICATION READS THE RENDERED CONFIG
#
# dnsmasq is started as `dnsmasq -C /var/etc/dnsmasq.conf.<section>`; that file
# is what the daemon actually loaded. Reading the records back out of UCI proves
# only that the write landed in flash. So the check greps the rendered file for
# every record, and then asks the resolver itself — `dig` against 127.0.0.1 —
# for one name and for its AAAA. UCI-correct and resolver-silent is the failure
# state this migration keeps re-learning, and it is exactly what a UCI-only
# self-check calls a success.
#
# exit codes: 0 done (or nothing to do), 1 verification failed, 2 refused before
# changing anything.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/agh-config.sh
source "$SCRIPT_DIR/lib/agh-config.sh"

DNS_DNSMASQ_SSH="${DNS_DNSMASQ_SSH:-ssh}"
DNS_DNSMASQ_JUMP="${DNS_DNSMASQ_JUMP:-pi@pi1.local}"
DNS_DNSMASQ_ROUTER="${DNS_DNSMASQ_ROUTER:-arr-stack-router}"
DNS_DNSMASQ_CONNECT_TIMEOUT="${DNS_DNSMASQ_CONNECT_TIMEOUT:-15}"

# The dnsmasq UCI section. Resolved rather than hardcoded: the name is a
# generated hash on this image (dhcp.cfg01411c), and it changes if the section
# is ever recreated.
DNS_DNSMASQ_SECTION="${DNS_DNSMASQ_SECTION:-}"
DNS_DNSMASQ_INIT="${DNS_DNSMASQ_INIT:-/etc/init.d/dnsmasq}"
DNS_DNSMASQ_RENDERED_GLOB="${DNS_DNSMASQ_RENDERED_GLOB:-/var/etc/dnsmasq.conf.*}"
# The option that marks the DHCP-serving dnsmasq section. It is dnsmasq's own
# lease file and is not something this script should ever write, so it is the
# one identifier that cannot be confused with a value the script itself sets.
DNS_DNSMASQ_LEASEFILE="${DNS_DNSMASQ_LEASEFILE:-/tmp/dhcp.leases}"

DNS_DNSMASQ_CONF="${DNS_DNSMASQ_CONF:-$REPO_ROOT/pihole/dnsmasq.d/02-local-dns.conf.example}"
DNS_DNSMASQ_TRAEFIK_IP="${DNS_DNSMASQ_TRAEFIK_IP:-192.168.110.250}"
# The AAAA answer for the zone. `::` is what the NAS carries and what this
# migration reproduces; see the header.
DNS_DNSMASQ_ZONE_NAME="${DNS_DNSMASQ_ZONE_NAME:-lan}"
DNS_DNSMASQ_ZONE_ANSWER="${DNS_DNSMASQ_ZONE_ANSWER:-::}"
# The name the live check queries, and the AAAA it expects back.
DNS_DNSMASQ_CHECK_NAME="${DNS_DNSMASQ_CHECK_NAME:-sonarr.lan}"
DNS_DNSMASQ_DIG="${DNS_DNSMASQ_DIG:-dig}"
# Polls, not a single probe: a reload takes a moment before dnsmasq is answering
# again. The default is generous because the cost of waiting is a second and the
# cost of a false failure is a chase for a fault that is not one.
DNS_DNSMASQ_TRIES="${DNS_DNSMASQ_TRIES:-10}"
DNS_DNSMASQ_SLEEP="${DNS_DNSMASQ_SLEEP:-1}"

DRY_RUN="${DRY_RUN:-0}"

say() { printf '%s\n' "$*"; }
refuse() { printf 'REFUSING: %s\n' "$*" >&2; exit 2; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
dnsmasq-local-names.sh — put the .lan address records into the router's
dnsmasq, reload it, and prove the running resolver answers with them.

  ./scripts/dnsmasq-local-names.sh --dry-run   print the records and what would
                                               change; touch nothing
  ./scripts/dnsmasq-local-names.sh             compare, apply if needed, reload,
                                               then verify against the rendered
                                               config and the live resolver

Runs from this checkout over `ssh DNS_DNSMASQ_JUMP 'ssh DNS_DNSMASQ_ROUTER sh -s'`.

Overridable: DNS_DNSMASQ_JUMP, DNS_DNSMASQ_ROUTER, DNS_DNSMASQ_SSH,
DNS_DNSMASQ_SECTION, DNS_DNSMASQ_INIT, DNS_DNSMASQ_RENDERED_GLOB,
DNS_DNSMASQ_CONF, DNS_DNSMASQ_TRAEFIK_IP, DNS_DNSMASQ_ZONE_NAME,
DNS_DNSMASQ_ZONE_ANSWER, DNS_DNSMASQ_CHECK_NAME, DNS_DNSMASQ_DIG,
DNS_DNSMASQ_TRIES, DNS_DNSMASQ_SLEEP, DRY_RUN. The file header says what each
one is for.
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

# --- the ssh layer ----------------------------------------------------------
#
# Every router command is a shell script on stdin, never an argument: quoting a
# script into an argv element is where the bugs live, and the shared test
# harness refuses a mutating verb in an argv on purpose. Direct
# `ssh arr-stack-router` is refused from a client VLAN; pi1 sits on the
# maintenance VLAN and is the way in.
remote() {
    "$DNS_DNSMASQ_SSH" -o ConnectTimeout="$DNS_DNSMASQ_CONNECT_TIMEOUT" "$DNS_DNSMASQ_JUMP" \
        "$DNS_DNSMASQ_SSH -o ConnectTimeout=$DNS_DNSMASQ_CONNECT_TIMEOUT $DNS_DNSMASQ_ROUTER sh -s"
}

# q <value> — quote a value for the remote shell. A value containing a single
# quote is refused rather than escaped badly: nothing here produces one, and a
# half-quoted record lands on the wrong name.
q() {
    case "$1" in
        *"'"*) refuse "value contains a single quote and cannot be quoted safely for the router: $1" ;;
    esac
    printf "'%s'" "$1"
}

# --- what the records should be ---------------------------------------------

if [[ ! -r "$DNS_DNSMASQ_CONF" ]]; then
    refuse "cannot read the .lan record at $DNS_DNSMASQ_CONF. The records are derived from it rather than from a list in this script, so a missing record is a missing record set"
fi
hostnames=$(agh_dnsmasq_hostnames < "$DNS_DNSMASQ_CONF") \
    || refuse "no hostnames in $DNS_DNSMASQ_CONF, so there would be no records to install"

# The names this script owns. Anything else in the router's address list is left
# alone, so the ownership set has to be complete before anything is deleted.
wanted=()
while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    wanted+=("/$name/$DNS_DNSMASQ_TRAEFIK_IP")
done <<<"$hostnames"
# The apex is not a hostname and does not come back from the parser; see the
# header for why it is carried anyway.
wanted+=("/$DNS_DNSMASQ_ZONE_NAME/$DNS_DNSMASQ_ZONE_ANSWER")

# ONE order for both sides of the comparison. `desired` is sorted, and the
# apply block writes `desired`, so a router already carrying the records is
# byte-identical to what a run would write and the guard above reports "no
# change". Writing `wanted` — which is in the record file's order, deliberately,
# because that file groups the services — would reorder the router's list on
# every run and make a converged router look like one that needs rewriting.
desired=$(printf '%s\n' "${wanted[@]}" | sort)
owned_names=$(printf '%s\n%s\n' "$hostnames" "$DNS_DNSMASQ_ZONE_NAME" | grep . | sort -u)

# --- read the router's current state ----------------------------------------

say "dnsmasq-local-names: reading the dnsmasq address records from $DNS_DNSMASQ_ROUTER via $DNS_DNSMASQ_JUMP"

# The resolved section is checked before anything is written to it, including
# when it was supplied through DNS_DNSMASQ_SECTION. An override that named the
# tunnel's section, or a name that does not exist at all, would put the records
# where dnsmasq's DHCP server never reads them — the same outcome as the two
# traps below, arriving by a different road.
section="$DNS_DNSMASQ_SECTION"
if [[ -n "$section" ]]; then
    leasefile=$(printf 'uci -q get %s.leasefile || true\n' "$(q "$section")" | remote 2>/dev/null | sed 's/[[:space:]]//g')
    [[ "$leasefile" == "$DNS_DNSMASQ_LEASEFILE" ]] \
        || refuse "DNS_DNSMASQ_SECTION=$section is not the DHCP-serving dnsmasq section: its leasefile is '${leasefile:-<unset>}', expected $DNS_DNSMASQ_LEASEFILE. Writing the address records to any other section leaves dnsmasq's DHCP server reading none of them"
fi
if [[ -z "$section" ]]; then
    # TWO TRAPS HERE, both measured on this router 2026-09-19.
    #
    # 1. The section name does NOT come from `uci -q get dhcp.@dnsmasq[0]`. That
    #    answers `dnsmasq` — the section TYPE — so building `dhcp.$it` produces
    #    `dhcp.dnsmasq`, a section that does not exist. The records would go
    #    somewhere dnsmasq never reads, the script would report them written,
    #    and `.lan` would still not resolve.
    #
    # 2. It is NOT simply the first section of type dnsmasq either. This box
    #    carries two — the main anonymous one and `wgclient1`, for the
    #    WireGuard tunnel — and `uci show dhcp` does not promise their order. In
    #    the ordering observed during development the main one was first, which
    #    is exactly why picking by position looks fine until it is not: the
    #    records would land in the tunnel's section, and the DHCP server would
    #    never see them.
    #
    # So the section is identified structurally: the one that carries
    # `leasefile`, which only the DHCP-serving dnsmasq has. Ownership of a name
    # is then confirmed with `uci -q get` before anything is written, because a
    # section that cannot be read is a section this script must not write to.
    #
    # The remote pipeline is POSIX because this runs on busybox ash. In
    # particular `sed "s/[[:space:]]//g"` rather than `tr -d '[:space:]'`: this
    # router's tr reads that as a literal character set and deletes s, p, a, c
    # and e, so `dhcp.@dnsmasq[0]` came back as `dh.@dnmq0`.
    # `echo`, not `printf`, for the section name. Every `%` in the remote script
    # is consumed once by the `printf` below that sends it, so a remote
    # `printf "%s\n"` arrives as a literal `%s` and prints `%s` instead of the
    # section name — measured while writing this, and it read as a plausible
    # section name. `echo` has nothing to escape.
    section=$(printf '%s\n' \
        'for s in $(uci -q show dhcp | grep "=dnsmasq" | cut -d= -f1 | sed "s/[[:space:]]//g"); do' \
        '  [ "$(uci -q get "$s.leasefile" | sed "s/[[:space:]]//g")" = "'"$DNS_DNSMASQ_LEASEFILE"'" ] || continue' \
        '  echo "$s"' \
        'done | head -1' \
        | remote 2>/dev/null | sed 's/[[:space:]]//g')
    [[ -n "$section" ]] || refuse "could not resolve the DHCP-serving dnsmasq section on the router (none of its '=dnsmasq' sections carries leasefile=/tmp/dhcp.leases)"
fi
say "dnsmasq-local-names: the dnsmasq section is $section"

current=$(printf 'uci -q get %s.address || true\n' "$(q "$section")" | remote 2>/dev/null \
          | tr ' ' '\n' | grep . | sort || true)

# Which of the current records this script owns, and which of those are stale.
owned=""
stale=""
while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    name="${entry#/}"; name="${name%%/*}"
    printf '%s\n' "$owned_names" | grep -qx "$name" || continue
    owned="$owned$entry"$'\n'
    printf '%s\n' "$desired" | grep -qx "$entry" || stale="$stale$entry"$'\n'
done <<<"$current"

# `printf '%s\n'`, not `'%s'`, and that is load-bearing rather than tidiness.
# `grep -c .` counts a final line with no trailing newline, but the whole
# pipeline is read back through a command substitution, which strips trailing
# newlines — so with `'%s'` the last counter is short by one, every time. That
# turned a set that had one record too few into a set that "already carries all
# 19", and the guard below let a change through as a no-op.
current_owned=$(printf '%s\n' "$owned" | grep -c . || true)
current_stale=$(printf '%s\n' "$stale" | grep -c . || true)
current_foreign=$(( $(printf '%s\n' "$current" | grep -c . || true) - current_owned ))

# `printf '%s'` here and `'%s\n'` in the counters below, and the difference is
# the whole guard. The accumulator above ends with a trailing newline, so `'%s\n'`
# here would add an empty line to the sorted set and a router carrying exactly
# the wanted records would compare unequal to them — the guard would never fire
# and every run would rewrite and reload. Without the trailing newline,
# `grep -c` in a command substitution drops the last count instead, which is why
# the counters are written with `'%s\n'`.
if [[ "$desired" == "$(printf '%s' "$owned" | sort)" ]]; then
    say "dnsmasq-local-names: no change. The router already carries all ${#wanted[@]} records:"
    printf '%s\n' "$desired" | sed 's/^/  /'
    [[ "$current_foreign" -gt 0 ]] && say "  (plus $current_foreign record(s) this script does not own, left alone)"
    say "Nothing was written and nothing was reloaded."
    exit 0
fi

say "dnsmasq-local-names: the router's records differ from the record file:"
say "  - wanted:              ${#wanted[@]} records (18 hostnames at $DNS_DNSMASQ_TRAEFIK_IP, plus /$DNS_DNSMASQ_ZONE_NAME/$DNS_DNSMASQ_ZONE_ANSWER)"
say "  - already there:       $current_owned"
say "  - within those, stale: $current_stale"
say "  - left alone:          $current_foreign record(s) this script does not own"

if [[ "$DRY_RUN" == "1" ]]; then
    say "dnsmasq-local-names: DRY-RUN: these are the records that would be written, and it is all that happens:"
    printf '%s\n' "$desired" | sed 's/^/  /'
    if [[ -n "$stale" ]]; then
        say "dnsmasq-local-names: DRY-RUN: these owned records would be removed:"
        printf '%s' "$stale" | sed 's/^/  /'
    fi
    say "dnsmasq-local-names: DRY-RUN complete: nothing was written to the router and nothing was reloaded."
    exit 0
fi

# --- apply ------------------------------------------------------------------
#
# A quoted heredoc with a delimiter the records cannot contain, quoted at the
# remote end as well so the remote shell expands nothing inside the body: these
# are literal records and they have to stay literal.
#
# Stale records go first, individually, so a record held twice loses both copies
# before the rebuild adds one back.
#
# The whole `section.address` key is written as one word with only the variable
# inside quotes — `'dhcp.x'.address="$entry"`. Quoting the concatenation instead
# (`'dhcp.x.address='`) leaves the quotes in the value, and `uci` then gets a key
# whose name literally ends in a quote: every del_list and add_list silently does
# nothing, the run reports the records written, and the router keeps serving what
# it had. That defect was in the first version of this function.
# The whole `section.address` key goes through `q` as one word. Passing
# `$(q "$section")` and concatenating `.address=` beside it produces
# `'dhcp.x'.address=…`: the quotes close before `.address`, so the remote shell
# hands uci a key whose name literally ends in a quote. Every del_list and
# add_list then quietly does nothing, the run still reports the records written,
# and the router keeps serving what it already had. That defect was in the first
# version of this function and the tests caught it; keep the key whole.
DELIM="DNSMASQ_ADDRESS_EOF_$$"
apply_script() {
    local entry key
    key="$section.address"
    printf 'set -e\n'
    printf 'n=0\n'
    if [[ -n "$stale" ]]; then
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            printf 'uci -q del_list %s=%s\n' "$(q "$key")" "$(q "$entry")"
            printf 'n=$((n+1))\n'
        done <<<"$stale"
    fi
    printf 'while IFS= read -r entry; do\n'
    printf '  [ -n "$entry" ] || continue\n'
    printf '  uci -q del_list %s="$entry" || true\n' "$(q "$key")"
    printf '  uci add_list %s="$entry"\n' "$(q "$key")"
    printf '  n=$((n+1))\n'
    printf 'done <<%s\n' "$(q "$DELIM")"
    printf '%s\n' "$desired"
    printf '%s\n' "$DELIM"
    printf 'uci commit dhcp\n'
    printf 'printf "APPLIED %%s\\n" "$n"\n'
}

if ! apply_out=$(apply_script | remote 2>&1); then
    printf '%s\n' "$apply_out" | sed 's/^/  /' >&2
    fail "the apply step failed on the router. The records may be half-written; re-run this script, which is idempotent, or check 'uci show $section' on the router"
fi
applied=$(printf '%s\n' "$apply_out" | sed -n 's/^APPLIED //p' | tail -1)
if [[ -z "$applied" ]]; then
    printf '%s\n' "$apply_out" | sed 's/^/  /' >&2
    fail "the apply step did not report how many records it wrote, so it cannot be told apart from one that did nothing. Nothing was reloaded"
fi
say "dnsmasq-local-names: wrote and committed $applied record(s)"

# --- reload -----------------------------------------------------------------
#
# REQUIRED. `uci commit dhcp` emits no config.change event, so without this the
# records are in flash and dnsmasq keeps serving the config it rendered at boot.
say "dnsmasq-local-names: reloading $DNS_DNSMASQ_INIT"
if ! reload_out=$(printf '%s reload\n' "$(q "$DNS_DNSMASQ_INIT")" | remote 2>&1); then
    printf '%s\n' "$reload_out" | sed 's/^/  /' >&2
    fail "the dnsmasq reload failed. The records are committed to flash and dnsmasq is still serving the old rendered config. Re-run this script once the reload works"
fi

# --- verify against the RUNNING config --------------------------------------
#
# The rendered file first, then the resolver's own answers. dnsmasq is started
# as `dnsmasq -C /var/etc/dnsmasq.conf.<section>`: that file is what the daemon
# loaded, and a record missing from it has exactly one user-visible consequence,
# which is that the queries below fail. Reporting them in this order means a
# failure names the missing record instead of only saying that a name did not
# resolve — and "UCI is right, the reload never re-rendered" and "the record is
# there and the daemon is not answering with it" stay distinguishable.

rendered=$(printf 'for f in %s; do [ -f "$f" ] && { printf "%%s\\n" "$f"; break; }; done\n' \
               "$DNS_DNSMASQ_RENDERED_GLOB" | remote 2>/dev/null | tr -d '[:space:]')
[[ -n "$rendered" ]] || fail "could not find the rendered dnsmasq config on the router ($DNS_DNSMASQ_RENDERED_GLOB). UCI may say the records are there; without the file dnsmasq is actually started from, nothing proves the daemon loaded them"

say "dnsmasq-local-names: verifying against $rendered, which is what dnsmasq loaded"
# `sed` rather than reading the whole line: the rendered file holds
# `address=/<name>/<answer>` while a record in `wanted` is the `/<name>/<answer>`
# value, which is what `uci` stores and what `--address=` receives.
loaded=$(printf 'grep "^address=" %s || true\n' "$(q "$rendered")" \
             | remote 2>/dev/null | sed 's/^address=//' || true)

failed=0
for entry in "${wanted[@]}"; do
    printf '%s\n' "$loaded" | grep -qxF "$entry" || {
        say "FAIL: the running config does not carry address=$entry"
        failed=1
    }
done

if [[ "$failed" -ne 0 ]]; then
    say "--- the address= lines the running config does carry ---"
    printf '%s\n' "$loaded" | grep . | sed 's/^/  address=/' || true
    fail "dnsmasq did not load every record. UCI is not the oracle here; the rendered file is. Check that $DNS_DNSMASQ_INIT reload re-renders it"
fi
say "ok: all ${#wanted[@]} records are in the running config"

# ...and then ask the resolver itself. A rendered file with the records in it is
# not proof that the daemon is answering with them.
poll_dig() {   # <name> <qtype|-> <expected> -> 0 when the answer matches
    local name="$1" qtype="$2" want="$3"
    local i got=""
    for (( i = 1; i <= DNS_DNSMASQ_TRIES; i++ )); do
        if [[ "$qtype" == "-" ]]; then
            got=$(printf '%s +short +time=3 +tries=1 %s @127.0.0.1\n' \
                      "$(q "$DNS_DNSMASQ_DIG")" "$(q "$name")" \
                  | remote 2>/dev/null | tr '\n' ' ')
        else
            got=$(printf '%s +short +time=3 +tries=1 %s %s @127.0.0.1\n' \
                      "$(q "$DNS_DNSMASQ_DIG")" "$(q "$name")" "$(q "$qtype")" \
                  | remote 2>/dev/null | tr '\n' ' ')
        fi
        got="${got% }"
        [[ "$got" == "$want" ]] && return 0
        sleep "$DNS_DNSMASQ_SLEEP"
    done
    printf '%s' "${got:-<nothing>}"
    return 1
}

if got=$(poll_dig "$DNS_DNSMASQ_CHECK_NAME" - "$DNS_DNSMASQ_TRAEFIK_IP"); then
    say "ok: $DNS_DNSMASQ_CHECK_NAME -> $DNS_DNSMASQ_TRAEFIK_IP"
else
    fail "$DNS_DNSMASQ_CHECK_NAME answered '$got' on the router's own :53, expected $DNS_DNSMASQ_TRAEFIK_IP. A client typing it would not reach Traefik"
fi

if got=$(poll_dig "$DNS_DNSMASQ_CHECK_NAME" AAAA "$DNS_DNSMASQ_ZONE_ANSWER"); then
    say "ok: $DNS_DNSMASQ_CHECK_NAME AAAA -> $DNS_DNSMASQ_ZONE_ANSWER"
else
    fail "$DNS_DNSMASQ_CHECK_NAME AAAA answered '$got' on the router's own :53, expected $DNS_DNSMASQ_ZONE_ANSWER. A musl/Alpine client that treats AAAA NXDOMAIN as a hard failure would still break"
fi

say "dnsmasq-local-names: OK. $DNS_DNSMASQ_ROUTER carries ${#wanted[@]} address records in flash and in the config dnsmasq is running, and answers an A and an AAAA query with them."
