#!/bin/bash
# Compare the .lan hostnames held in the repo's dnsmasq record against an
# AdGuard Home DNS-rewrite capture.
#
# WHY THIS EXISTS
#
# The migration deliberately holds the same .lan names in two stores, because a
# firewall flag decides which one answers: AdGuard Home's DNS rewrites (Phase
# 3.2, the hostnames -> Traefik's macvlan) and the router's dnsmasq `address`
# records (Phase 4.1, the same names plus `address=/lan/::`). A name added to
# one store and not the other is a latent bug: it only shows when `dns_enabled`
# flips, and by then the name is being answered by the wrong store, or by
# neither.
#
# scripts/lib/check-dns-duplicates.sh sat beside this file and did not cover
# this, and never did: it compared the NAS's 02-local-dns.conf against
# pihole.toml *inside the Pi-hole container*, and returned 0 on every arm. It
# was retired on 2026-09-21 with the store it read (Phase 8.6 of the DNS
# migration), so this file is now the only check comparing two stores at all.
#
# WHY IT FAILS RATHER THAN WARNS
#
# The flip it guards is silent: nothing looks wrong while the two stores
# disagree, because only one of them answers at any moment. A warning nobody
# reads is the same as no guard, so divergence exits 1 and Gate 3 can require
# this to go red when a name is added to one store only.
#
# WHAT IS COMPARED
#
# The two stores meet at hostnames: the entry name and the address it answers
# with. Both sides are filtered to names containing a dot, because the zone-wide
# record (`address=/lan/::` on this side; whatever AdGuard ends up using for
# AAAA, open question 3) is not a hostname and the two stores express it
# differently. Comparing it would report a deliberate difference as a divergence
# on every run. Both sides are lowercased, because DNS names are.
#
# The repo's committed record is pihole/dnsmasq.d/02-local-dns.conf.example,
# which carries the literal TRAEFIK_LAN_IP. Pass the address it stands for as
# the third argument, or every name reads as an address mismatch. A placeholder
# left unresolved when no address was supplied is reported as "cannot compare"
# (2), not as divergence: the file is right and the caller did not say what the
# placeholder means.
#
# RETURN CODES
#
#   0  the two stores agree, hostname for hostname and address for address
#   1  they diverge: a name in one store only, or the same name answering a
#      different address in each
#   2  the comparison could not run, and claims neither verdict -- unreadable
#      input, a record or capture that parsed no hostnames, a store that defines
#      the same name twice, or the not-yet-populated state below
#
# 2 IS NEVER A PASS. A capture that parsed nothing satisfies every comparison it
# never makes, which is the failure this repo has had to dig back out of a
# merged guard more than once.
#
# THE PHASE 3 STATE, AND WHY IT IS NOT A DIVERGENCE
#
# Phase 3 populates AdGuard (3.2) while the router's dnsmasq has no `address`
# records at all until Phase 4.1. Read literally, "the AdGuard store has 18
# names the other store does not" is a divergence, and a guard that reports it
# fails the whole of Phase 3 for a state the plan intends -- which is how a
# guard gets deleted instead of fixed. Reading it as agreement would be worse:
# until 4.1 lands, those names genuinely are unanswered through dnsmasq. So an
# empty repo-side record is its own verdict, exit 2, naming the phase that fills
# it. Not a divergence claim, and not a pass.
#
# tests/lib-dns-divergence.bats drives all of it with synthetic text: no router,
# no network, no ssh.

# ---------------------------------------------------------------------------
# Input plumbing
# ---------------------------------------------------------------------------

# dns_divergence_read [path] -- an empty path or "-" reads stdin. Returns 1 when
# a named path cannot be read, so a caller can tell "the file is missing" from
# "the file says nothing".
dns_divergence_read() {
    local path="${1:-}"
    if [[ -z "$path" || "$path" == "-" ]]; then
        cat
        return 0
    fi
    [[ -r "$path" ]] || return 1
    cat "$path"
}

# True for a line that is only whitespace.
_dns_divergence_blank() {
    [[ -z "${1//[[:space:]]/}" ]]
}

# DNS compares names case-insensitively, and AdGuard stores them lowercased.
_dns_divergence_normalize_name() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# _dns_divergence_address_for <name> <entries> -- the address one store gives
# for a name, or nothing when that store does not have the name. "This store
# does not have it" is decided by the empty result, so an entry whose address
# were allowed to be empty would read as a missing name; both parsers reject an
# empty address instead.
_dns_divergence_address_for() {
    printf '%s\n' "$2" | awk -F'\t' -v want="$1" '$1 == want { print $2; exit }'
}

# ---------------------------------------------------------------------------
# The repo-side store
# ---------------------------------------------------------------------------

# dns_divergence_repo_entries <record-file> [lan-address]
#
# Prints "<name><TAB><address>" per hostname, lowercased and sorted. Reads
# dnsmasq's `address=` records, including the multi-name form
# `address=/one.lan/two.lan/192.168.1.1`. Comments and blank lines are ignored;
# anything else is a parse failure rather than something to skip, because a
# record in a syntax this parser does not know would otherwise read as an empty
# store. Returns 0, or 2 with the reason on stdout.
dns_divergence_repo_entries() {
    local path="${1:-}" lan_address="${2:-}"
    local text line body address name number=0 out=""
    local -a fields

    text=$(dns_divergence_read "$path") || {
        printf 'SKIP: cannot read the repo-side .lan record %s\n' "${path:-<stdin>}"
        return 2
    }

    while IFS= read -r line; do
        number=$((number + 1))
        # Strips a trailing comment. dnsmasq also uses `#` as an address
        # wildcard (`address=/#/1.2.3.4`, answer everything); the record carries
        # no such line today, and one would land in the SKIP below rather than
        # being read as an empty store.
        line="${line%%#*}"
        _dns_divergence_blank "$line" && continue

        case "$line" in
            address=*) ;;
            *)
                printf 'SKIP: %s line %d is not an address= record: %s\n' \
                    "${path:-<stdin>}" "$number" "$line"
                return 2
                ;;
        esac

        body="${line#address=}"
        body="${body#/}"
        body="${body%/}"
        IFS='/' read -r -a fields <<< "$body"

        # The last field is the address; everything before it is a name. A
        # record with only one field has no address to answer with.
        if [[ "${#fields[@]}" -lt 2 ]]; then
            printf 'SKIP: %s line %d is not an address=/<name>/<address> record: %s\n' \
                "${path:-<stdin>}" "$number" "$line"
            return 2
        fi
        address="${fields[${#fields[@]}-1]}"

        local i
        for (( i = 0; i < ${#fields[@]} - 1; i++ )); do
            name="${fields[$i]}"
            [[ -n "$name" ]] || continue

            # `address=/lan/::` answers the whole zone, not a hostname, and the
            # two stores express it differently. See the header.
            [[ "$name" == *.* ]] || continue

            if [[ -n "$lan_address" && "$address" == "TRAEFIK_LAN_IP" ]]; then
                address="$lan_address"
            fi
            if [[ "$address" == *TRAEFIK_LAN_IP* ]]; then
                printf 'SKIP: %s line %d holds the TRAEFIK_LAN_IP placeholder and no address was supplied to resolve it\n' \
                    "${path:-<stdin>}" "$number"
                return 2
            fi

            out="$out$(_dns_divergence_normalize_name "$name")"$'\t'"$address"$'\n'
        done
    done <<< "$text"

    printf '%s' "$out" | sort
    return 0
}

# ---------------------------------------------------------------------------
# The AdGuard side
# ---------------------------------------------------------------------------

# dns_divergence_capture_entries <capture-file|->
#
# The AdGuard rewrite list as plain text: one rewrite per line,
# "<domain><whitespace><answer>", which is the shape of the UI's rewrite table
# and of the domain/answer pair /control/rewrite/list returns. Comments and
# blank lines are ignored. A line that is not a pair is a parse failure rather
# than something to skip: silently dropping it drops a rewrite, and a shorter
# list is how a name the router has read as one AdGuard does not.
dns_divergence_capture_entries() {
    local path="${1:-}"
    local text line name answer extra number=0 out=""

    text=$(dns_divergence_read "$path") || {
        printf 'SKIP: cannot read the AdGuard rewrite capture %s\n' "${path:-<stdin>}"
        return 2
    }

    while IFS= read -r line; do
        number=$((number + 1))
        line="${line%%#*}"
        _dns_divergence_blank "$line" && continue

        name="" answer="" extra=""
        read -r name answer extra <<< "$line"
        if [[ -z "$name" || -z "$answer" || -n "$extra" ]]; then
            printf 'SKIP: %s line %d is not a "<domain> <answer>" rewrite: %s\n' \
                "${path:-<stdin>}" "$number" "$line"
            return 2
        fi

        # A zone-wide entry is not a hostname; see the header.
        [[ "$name" == *.* ]] || continue

        out="$out$(_dns_divergence_normalize_name "$name")"$'\t'"$answer"$'\n'
    done <<< "$text"

    printf '%s' "$out" | sort
    return 0
}

# ---------------------------------------------------------------------------
# The comparison
# ---------------------------------------------------------------------------

# dns_divergence_check <repo-record> [capture-file|-] [lan-address]
#
# Returns 0 when the two stores agree, 1 when they diverge, 2 when the
# comparison could not run. One line per hostname either way, then a summary.
dns_divergence_check() {
    local repo_path="${1:-}" capture="${2:--}" lan_address="${3:-}"
    local repo_entries="" capture_entries=""
    local repo_rc=0 capture_rc=0

    repo_entries=$(dns_divergence_repo_entries "$repo_path" "$lan_address") || repo_rc=$?
    if [[ "$repo_rc" -ne 0 ]]; then
        printf '%s\n' "$repo_entries"
        return 2
    fi

    capture_entries=$(dns_divergence_capture_entries "$capture") || capture_rc=$?
    if [[ "$capture_rc" -ne 0 ]]; then
        printf '%s\n' "$capture_entries"
        return 2
    fi

    local repo_names="" capture_names="" repo_count=0 capture_count=0
    repo_names=$(printf '%s' "$repo_entries" | cut -f1 | grep . || true)
    capture_names=$(printf '%s' "$capture_entries" | cut -f1 | grep . || true)

    if [[ -z "$repo_names" ]]; then
        # Not a divergence and not a pass: see THE PHASE 3 STATE in the header.
        printf 'SKIP: the repo-side .lan record parsed no hostnames. If this is Phase 3, the router-side store (4.1) does not exist yet -- that is not a divergence and not agreement.\n'
        return 2
    fi
    if [[ -z "$capture_names" ]]; then
        # Zero names is a failed read far more often than it is an AdGuard with
        # no rewrites, and every name "looking absent" is not a divergence
        # either. Neither may read as agreement.
        printf 'SKIP: the AdGuard rewrite capture parsed no hostnames -- a read that produced nothing is not an all-clear, and it is not a divergence either.\n'
        return 2
    fi

    local problems=0 name repo_address="" capture_address=""
    local repeated=""

    # A store that defines one name twice is undecidable here: which of the two
    # addresses that store means is not this guard's to guess, and guessing
    # picks whichever line the sort put first -- an agreement nothing in either
    # file supports. check-dns-duplicates.sh covered the Pi-hole side of this
    # until 2026-09-21; it is gone with the store, and neither store in this
    # pair has such a check now.
    repeated=$(printf '%s\n' "$repo_names" | sort | uniq -d | head -1)
    if [[ -n "$repeated" ]]; then
        printf 'SKIP: the repo-side .lan record defines %s more than once -- which address wins is not something to guess\n' \
            "$repeated"
        return 2
    fi
    repeated=$(printf '%s\n' "$capture_names" | sort | uniq -d | head -1)
    if [[ -n "$repeated" ]]; then
        printf 'SKIP: the AdGuard rewrite capture defines %s more than once -- which answer wins is not something to guess\n' \
            "$repeated"
        return 2
    fi

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        repo_address=$(_dns_divergence_address_for "$name" "$repo_entries")
        capture_address=$(_dns_divergence_address_for "$name" "$capture_entries")

        if [[ -z "$repo_address" ]]; then
            printf 'FAIL %s is in the AdGuard rewrite list but not in the repo-side .lan record (AdGuard answers %s)\n' \
                "$name" "$capture_address"
            problems=$((problems + 1))
        elif [[ -z "$capture_address" ]]; then
            printf 'FAIL %s is in the repo-side .lan record but not in the AdGuard rewrite list (the record asks for %s)\n' \
                "$name" "$repo_address"
            problems=$((problems + 1))
        elif [[ "$repo_address" != "$capture_address" ]]; then
            printf 'FAIL %s answers %s in the repo-side record and %s in AdGuard -- the flip silently changes the answer\n' \
                "$name" "$repo_address" "$capture_address"
            problems=$((problems + 1))
        else
            printf 'ok   %s %s\n' "$name" "$repo_address"
        fi
    done < <(printf '%s\n%s\n' "$repo_names" "$capture_names" | sort -u)

    repo_count=$(printf '%s\n' "$repo_names" | grep -c . || true)
    capture_count=$(printf '%s\n' "$capture_names" | grep -c . || true)
    printf -- '--- repo %s hostname(s), AdGuard %s hostname(s), %s divergence(s)\n' \
        "$repo_count" "$capture_count" "$problems"

    [[ "$problems" -eq 0 ]] || return 1
    return 0
}
