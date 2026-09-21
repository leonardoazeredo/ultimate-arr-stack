#!/bin/bash
# Evaluate tests/fixtures/dns-baseline.txt against one resolver.
#
# The baseline matrix is the oracle for the AdGuard Home migration: it records
# what the NAS Pi-hole answers today, and every later phase is judged against
# it. This file holds the row-by-row comparison; scripts/dns-matrix-check.sh is
# the one-resolver CLI built on it, and scripts/dns-parity.sh (3.6) sends the
# same matrix to both resolvers and diffs the results.
#
# Why a shared module and not a one-off script: the single-resolver check and
# the two-resolver parity check must agree on what "BLOCKED" means. Two copies
# of that rule drift, and the drift shows up as a parity result that cannot be
# explained by either resolver's configuration.
#
# The expectation vocabulary is documented at the top of the fixture itself.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DNS_MATRIX_FIXTURE="${DNS_MATRIX_FIXTURE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/fixtures/dns-baseline.txt}"

# dns_matrix_query <resolver> <port> <name> <qtype> <transport>
#
# Prints "<STATUS> <answer> <answer> ...". The status is always present, so a
# caller can tell "the resolver said NXDOMAIN" apart from "dig never reached
# anything" - ERROR is the latter, and no expectation accepts it.
dns_matrix_query() {
    local resolver="$1" port="$2" name="$3" qtype="$4" transport="$5"
    local -a flags=()
    [[ "$transport" == "tcp" ]] && flags+=(+tcp)

    local out
    out=$(dig +time=3 +tries=1 ${flags[@]+"${flags[@]}"} +noall +comments +answer \
              -p "$port" "@$resolver" "$name" "$qtype" 2>/dev/null) || true

    local status answers
    status=$(sed -n 's/.*status: \([A-Z]*\).*/\1/p' <<<"$out" | head -1)
    answers=$(awk -v T="$qtype" '$4==T {print $5}' <<<"$out" | tr '\n' ' ')

    printf '%s %s' "${status:-ERROR}" "${answers% }"
}

# dns_matrix_expectation_met <expectation> <status> <answers>
#
# <answers> is the space-separated answer set from dns_matrix_query.
dns_matrix_expectation_met() {
    local expectation="$1" status="$2" answers="$3" answer

    case "$expectation" in
        ANY)
            # Worth having a value at all, not worth comparing it: these are
            # load-balanced names that hand out a different edge per query.
            [[ "$status" == "NOERROR" && -n "$answers" ]] && return 0
            ;;
        BLOCKED)
            [[ " $answers " == *" 0.0.0.0 "* ]] && return 0
            ;;
        NXDOMAIN)
            [[ "$status" == "NXDOMAIN" ]] && return 0
            ;;
        NODATA)
            # NOERROR with nothing in it. Distinct from NXDOMAIN on purpose:
            # `local=/lan/` answers locally and returns no record, while a name
            # that does not exist at all comes back NXDOMAIN, and a resolver
            # that has started refusing rather than answering must not read as
            # either.
            [[ "$status" == "NOERROR" && -z "$answers" ]] && return 0
            ;;
        LAN_AAAA)
            # NOERROR carrying either `::` or nothing at all -- and never
            # NXDOMAIN. This is the only .lan row the two resolvers answer
            # differently, and the difference is deliberate.
            #
            # dnsmasq holds `address=/lan/::`, so it answers AAAA with the
            # literal `::`. AdGuard Home's DNS rewrites carry an IPv4 address
            # only, so it answers AAAA with NOERROR and no record (NODATA).
            # Phase 3.3 of the migration plan decided the NODATA form is
            # sufficient, and measured why: musl's hard failure is AAAA
            # *NXDOMAIN*, not an empty answer. An AAAA query for a `.lan` name
            # still resolves over IPv4 from a musl client under NODATA, which
            # tests/alpine-dns-aaaa.bats asserts directly with a real container.
            #
            # So the requirement is "not NXDOMAIN", not "the literal `::`".
            # Pinning `::` here would fail on the healthy path (AdGuard) and pass
            # on the fallback path (dnsmasq) -- the exact inversion of what this
            # row is for. Both accepted values are non-NXDOMAIN; NXDOMAIN and an
            # unreachable resolver still fail.
            [[ "$status" == "NOERROR" ]] || return 1
            [[ -z "$answers" ]] && return 0
            for answer in $answers; do
                [[ "$answer" == "::" ]] || return 1
            done
            return 0
            ;;
        *)
            # An address literal. Every answer has to be it, and there has to be
            # one: a resolver that returns the right address alongside a wrong
            # one is not answering correctly.
            [[ -n "$answers" ]] || return 1
            for answer in $answers; do
                [[ "$answer" == "$expectation" ]] || return 1
            done
            return 0
            ;;
    esac
    return 1
}

# dns_matrix_check_resolver <resolver> [port] [fixture]
#
# One line per row on stdout, and a summary. Returns 0 when every row matched,
# 1 when any row did not, and 2 when it could not run at all.
dns_matrix_check_resolver() {
    local resolver="$1" port="${2:-53}" fixture="${3:-$DNS_MATRIX_FIXTURE}"

    if ! command -v dig &>/dev/null; then
        echo "SKIP: dig not installed"
        return 2
    fi
    if [[ ! -r "$fixture" ]]; then
        echo "SKIP: cannot read fixture $fixture"
        return 2
    fi

    local name qtype transport expectation note result status answers
    local rows=0 failures=0
    while IFS=$'\t' read -r name qtype transport expectation note; do
        [[ -z "$name" ]] && continue
        rows=$((rows + 1))

        result=$(dns_matrix_query "$resolver" "$port" "$name" "$qtype" "$transport")
        status=${result%% *}
        answers=${result#* }

        if dns_matrix_expectation_met "$expectation" "$status" "$answers"; then
            printf 'ok   %s %s %s -> %s\n' \
                "$name" "$qtype" "$transport" "${answers:-$status}"
        else
            printf 'FAIL %s %s %s: expected %s, got %s %s\n' \
                "$name" "$qtype" "$transport" "$expectation" \
                "${status:-ERROR}" "${answers:-<none>}"
            failures=$((failures + 1))
        fi
    done < <(grep -vE '^#|^$' "$fixture")

    if [[ "$rows" -eq 0 ]]; then
        # An empty matrix passes every comparison it never makes.
        echo "FAIL: the fixture has no rows"
        return 2
    fi

    echo "--- $resolver:$port --- $((rows - failures))/$rows rows matched"
    [[ "$failures" -eq 0 ]] || return 1
    return 0
}
