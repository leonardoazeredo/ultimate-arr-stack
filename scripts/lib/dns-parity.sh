#!/bin/bash
# Compare tests/fixtures/dns-baseline.txt across two resolvers.
#
# The single-resolver half lives in scripts/lib/dns-matrix.sh and answers "does
# this resolver satisfy the baseline?". This file answers the question Gate 3
# asks: "can these two be swapped for one another?" It reuses dns_matrix_query
# and dns_matrix_expectation_met rather than parsing dig output a second time,
# so both halves agree on what BLOCKED or NODATA means. Two copies of that rule
# drift, and the drift shows up as a parity result nobody can explain by reading
# either resolver's configuration.
#
# WHAT COUNTS AS A DIFFERENCE
#
# The two queries are compared against each other, not against the fixture.
# Each side is a (status, answer set) pair and the row differs when either half
# differs. The status half is not decoration: an unknown .lan name is answered
# NODATA (NOERROR, empty) by the NAS Pi-hole, because address=/lan/:: gives
# dnsmasq local data for the zone, and NXDOMAIN by the router, because
# local=/lan/ makes dnsmasq authoritative over the zone with no data. The two
# answer sections are both empty, so a comparison that looked only at the
# answers would call that row a match - and it is the row this harness exists
# to surface.
#
# Excusing a difference
#
# A note containing ALLOW-DIFF, and nothing else, excuses a row. A deliberate
# difference is named in tests/fixtures/dns-baseline.txt where a reader can see
# it, never waved through in code. Excused rows are reported separately from
# unexplained ones so the report shows what was excused and why; a run that
# excused anything without saying so is a run whose verdict cannot be checked.
#
# Vantage points
#
# The NAS answers from a client VLAN; the router's AdGuard Home on :3053 is
# reachable only from the maintenance VLAN, because the Allow-DNS-vlan* rules
# permit dport 53 to the router and nothing else, and port 3053 is dropped
# rather than closed from every client VLAN. A resolver spec may therefore carry
# a jump host:
#
#     host:port                      queries from here
#     jump=user@host:host:port        queries via `ssh user@host`
#
# Every report line names the vantage a side was queried from. A parity result
# whose vantages are invisible is one nobody can debug.
#
# Exit codes, matching scripts/dns-matrix-check.sh:
#
#   0   every row agrees, or is an excused ALLOW-DIFF
#   1   at least one unexplained difference
#   77  the check could not run at all (no dig, unreadable or empty fixture,
#       neither resolver answered). 77 is the repo's "no oracle" status: a
#       check that could not run must not look like one that passed.

_dns_parity_self="${BASH_SOURCE[0]}"
# shellcheck source=scripts/lib/dns-matrix.sh
source "$(dirname "$_dns_parity_self")/dns-matrix.sh"

# The dig to run. Resolution is deferred to call time rather than captured at
# load time: an absolute path frozen when this file was sourced ignores $PATH,
# so a test's stub dig is bypassed and the query goes to the real resolver
# instead of the fixture. Point DNS_PARITY_DIG at a full path to pin a binary.
DNS_PARITY_DIG="${DNS_PARITY_DIG:-dig}"
# The dig handed to a jumped side. A bare name is resolved here at call time and
# sent as an absolute path, so the remote shell does not depend on finding dig
# in a non-interactive PATH. A path already set here is used verbatim.
DNS_PARITY_REMOTE_DIG="${DNS_PARITY_REMOTE_DIG:-}"

# ssh options for a jumped query. ConnectTimeout keeps an unreachable jump host
# from hanging the whole matrix; BatchMode keeps it from stopping to ask for
# something a non-interactive run can never supply. dns_matrix_query's own
# +time=3 +tries=1 bounds the remote dig once the connection is up.
DNS_PARITY_SSH_OPTS=(-o ConnectTimeout=8 -o BatchMode=yes)

# The jump host currently in effect for dns_matrix_query, empty when the query
# runs from here.
_DNS_PARITY_JUMP=""

# 0 when the dig this invocation would run exists.
#
# `type -P`, not `command -v`: this file defines a `dig` shell function further
# down, and once that is defined `command -v dig` answers with the bare word
# `dig` (a function is a command), not a path. Everything downstream then hands
# the remote side a command name it cannot resolve. `type -P` searches $PATH
# only, ignoring functions and aliases, which is exactly what is wanted here.
dns_parity_dig_path() {
    type -P -- "$DNS_PARITY_DIG" 2>/dev/null
}

dns_parity_have_dig() {
    [[ -n "$(dns_parity_dig_path)" ]]
}

# dns_parity_remote_dig_path -- the absolute path sent to a jumped side.
dns_parity_remote_dig_path() {
    if [[ -n "$DNS_PARITY_REMOTE_DIG" ]]; then
        printf '%s' "$DNS_PARITY_REMOTE_DIG"
        return 0
    fi
    local p
    p="$(dns_parity_dig_path)"
    printf '%s' "${p:-$DNS_PARITY_DIG}"
}

# dns_parity_reset -- clear the module's globals. Called by tests setup(), and
# by anything else that needs the module back at its initial state.
dns_parity_reset() {
    _DNS_PARITY_JUMP=""
}

# dns_parity_parse_spec <spec> -- prints "<host>\t<port>\t<jump-host-or-empty>".
# Returns 1 when the spec is not the documented shape.
#
# The parse runs RIGHT TO LEFT, and that is the whole trick. Jump hosts look
# like `user@host` and carry a dot, so `jump=pi@pi1.local:192.168.8.1:3053` has
# no left-to-right split that can tell the jump host from the resolver: a split
# at the first colon hands back `local` as the jump host and `pi@pi1.local` as
# the resolver, which is a query at a name that does not resolve, from a host
# that was never named. Read from the right instead:
#
#   port      the last colon-separated field, when it is a number
#   host      the colon-separated field before it
#   jump host everything before that, with `jump=` and the separating colon
#             removed - so it may itself contain colons (an IPv6 literal) or an
#             `@`.
dns_parity_parse_spec() {
    local spec="$1" prefix="" hostport host port jump="" rest last

    if [[ "$spec" == jump=* ]]; then
        prefix="jump="
        rest="${spec#jump=}"
    else
        rest="$spec"
    fi
    [[ -n "$rest" ]] || return 1

    if [[ -n "$prefix" ]]; then
        # Everything before the LAST colon is the jump host; the last field is
        # either a port or the resolver host. That single rule covers both
        # `jump=user@host:host:port` and the port-less `jump=user@host:host`,
        # and it is what keeps `pi@pi1.local` whole - a left-to-right split
        # hands back `local` as the jump host and `pi@pi1.local` as the
        # resolver, which is a query at a name that does not resolve, from a
        # host nobody named.
        last="${rest##*:}"
        if [[ "$rest" != *:* ]]; then
            host="$rest"
            port=53
            jump=""
        elif [[ "$last" =~ ^[0-9]+$ ]]; then
            port="$last"
            hostport="${rest%:*}"
            [[ "$port" -ge 1 && "$port" -le 65535 ]] || return 1
            host="${hostport##*:}"
            jump="${hostport%:*}"
            [[ "$jump" != "$hostport" ]] || jump="$hostport"
        else
            port=53
            host="$last"
            jump="${rest%:*}"
        fi
    elif [[ "$rest" == *:* ]]; then
        # No jump: a trailing field that is not a number is a port nobody can
        # use, not a host. Refused rather than defaulted, so a typo in the
        # script's arguments does not silently query port 53 of a name that
        # does not exist.
        last="${rest##*:}"
        [[ "$last" =~ ^[0-9]+$ ]] || return 1
        port="$last"
        host="${rest%:*}"
        [[ "$port" -ge 1 && "$port" -le 65535 ]] || return 1
    else
        host="$rest"
        port=53
    fi

    [[ -n "$host" ]] || return 1
    if [[ -n "$prefix" ]]; then
        [[ -n "$jump" ]] || return 1
    fi

    printf '%s\t%s\t%s\n' "$host" "$port" "$jump"
}

# dns_parity_endpoint <spec> -- "host:port (via jump)", the readable form used
# in every report line.
dns_parity_endpoint() {
    local parsed host port jump
    parsed=$(dns_parity_parse_spec "$1") || {
        printf '%s' "$1"
        return 0
    }
    IFS=$'\t' read -r host port jump <<<"$parsed"
    if [[ -n "$jump" ]]; then
        printf '%s:%s (via %s)' "$host" "$port" "$jump"
    else
        printf '%s:%s' "$host" "$port"
    fi
}

# The wrapper `dig` reaches. Defined so a jumped side can redirect the query
# without dns_matrix_query having to know about ssh at all; it runs the real dig
# otherwise. An absent dig returns 127, which dns_matrix_query turns into ERROR.
dig() {
    if [[ -n "$_DNS_PARITY_JUMP" ]]; then
        local rd
        rd="$(dns_parity_remote_dig_path)"
        # argv is built explicitly rather than spread across the call. A
        # multi-line `ssh "${OPTS[@]}" "$jump" "cmd" <<EOF` form was tried and
        # silently dropped every argument after the command: the stub saw 6
        # args where 16 were passed, so the remote dig ran with an empty argv
        # and every row came back ERROR - a broken vantage that reads as a
        # resolver which does not answer. `command` also skips a shell function
        # or alias named ssh, which a user's shell may legitimately define.
        local -a ssh_argv=("${DNS_PARITY_SSH_OPTS[@]}" "$_DNS_PARITY_JUMP" "sh -s -- '$rd'")
        ssh_argv+=("$@")
        # The remote script arrives over stdin (`sh -s`), the repo's rule for
        # scripts that would otherwise have to survive quoting through a hop.
        command ssh "${ssh_argv[@]}" <<'DNS_PARITY_REMOTE_DIG'
dig_path="$1"; shift
"$dig_path" "$@"
DNS_PARITY_REMOTE_DIG
    else
        command "$DNS_PARITY_DIG" "$@"
    fi
}

# dns_parity_query <spec> <name> <qtype> <transport> -- "<STATUS> <answers...>".
# The format is dns_matrix_query's, unmodified.
dns_parity_query() {
    local spec="$1" name="$2" qtype="$3" transport="$4"
    local parsed host port jump
    parsed=$(dns_parity_parse_spec "$spec") || {
        printf 'ERROR '
        return 0
    }
    IFS=$'\t' read -r host port jump <<<"$parsed"

    # Deliberately NOT `local`: the dig wrapper below is a different function
    # frame (and dns_matrix_query runs it inside a command substitution), so a
    # local here is invisible to it. The wrapper would then take the local
    # branch, the query would go out from this host to an address only the jump
    # host can reach, and every row would come back ERROR - a whole-matrix
    # "difference" caused by nothing but a shadowed variable.
    _DNS_PARITY_JUMP="$jump"
    dns_matrix_query "$host" "$port" "$name" "$qtype" "$transport"
}

# Sort the words of $1 so two answer sets can be compared as sets.
#
# Order within a DNS answer section carries no meaning, and these two resolvers
# regularly return the same addresses in different order - measured on the live
# pair: the NAS Pi-hole answered example.com with 104.20.23.154 then
# 172.66.147.243 while AdGuard answered 172.66.147.243 then 104.20.23.154.
# Comparing them in order reported that as a difference, which is noise of the
# worst kind: a false Gate 3 failure on a row the fixture already labels
# load-balanced. Sorting keeps the finding that matters - the two resolvers hand
# out a DIFFERENT set of addresses, which is what "these are not
# interchangeable" means - and drops the one that does not.
_dns_parity_sorted_answers() {
    local word
    for word in $1; do printf '%s\n' "$word"; done | LC_ALL=C sort | tr '\n' ' '
}

# dns_parity_differs <status_a> <answers_a> <status_b> <answers_b>
# 0 when the two results are a difference, 1 when they agree.
dns_parity_differs() {
    [[ "$1" != "$3" ]] && return 0
    local a b
    a="$(_dns_parity_sorted_answers "$2")"
    b="$(_dns_parity_sorted_answers "$4")"
    [[ "$a" != "$b" ]] && return 0
    return 1
}

# dns_parity_row_excused <note> -- 0 when the row's note names ALLOW-DIFF.
dns_parity_row_excused() {
    [[ "${1:-}" == *ALLOW-DIFF* ]]
}

# dns_parity_result_text <status> <answers> -- the readable form of one result.
#
# NOERROR with an empty answer section is printed as NODATA because that is what
# it is, and because the distinction this harness exists to draw - NODATA on the
# NAS versus NXDOMAIN on the router for an unknown .lan name - is invisible if
# both sides print `NOERROR <none>` against each other. Everything else prints as
# it arrived, including ERROR, which must never be spelled as a plausible
# answer.
dns_parity_result_text() {
    local status="$1" answers="$2"
    if [[ "$status" == "NOERROR" && -z "${answers// /}" ]]; then
        printf 'NODATA'
        return 0
    fi
    printf '%s' "$status"
    [[ -n "${answers// /}" ]] && printf ' %s' "$answers"
    return 0
}

# dns_parity_check <spec-a> <spec-b> [fixture]
#
# Prints one line per row that differs, then the excused and unexplained
# sections, then a summary. 0 when nothing is unexplained, 1 when something is,
# 77 when it could not run at all.
dns_parity_check() {
    local spec_a="$1" spec_b="$2" fixture="${3:-$DNS_MATRIX_FIXTURE}"
    local ep_a ep_b
    ep_a="$(dns_parity_endpoint "$spec_a")"
    ep_b="$(dns_parity_endpoint "$spec_b")"

    if ! dns_parity_have_dig; then
        echo "SKIP: dig not installed"
        return 77
    fi
    if [[ ! -r "$fixture" ]]; then
        echo "SKIP: cannot read fixture $fixture"
        return 77
    fi

    local name qtype transport expectation note
    local rows=0 errors_a=0 errors_b=0
    local unexplained=0 excused=0
    local -a unexplained_lines=() excused_lines=()

    while IFS=$'\t' read -r name qtype transport expectation note; do
        [[ -z "$name" ]] && continue
        rows=$((rows + 1))

        local ra rb sa aa sb ab
        ra="$(dns_parity_query "$spec_a" "$name" "$qtype" "$transport")"
        rb="$(dns_parity_query "$spec_b" "$name" "$qtype" "$transport")"
        sa="${ra%% *}"; aa="${ra#* }"
        sb="${rb%% *}"; ab="${rb#* }"
        [[ "$sa" == ERROR ]] && errors_a=$((errors_a + 1))
        [[ "$sb" == ERROR ]] && errors_b=$((errors_b + 1))

        if dns_parity_differs "$sa" "$aa" "$sb" "$ab"; then
            local line
            line=$(printf 'DIFF %s %s %s: %s answered "%s", %s answered "%s"' \
                "$name" "$qtype" "$transport" "$ep_a" \
                "$(dns_parity_result_text "$sa" "$aa")" \
                "$ep_b" "$(dns_parity_result_text "$sb" "$ab")")
            # ALLOW-DIFF excuses a difference between two answers, never a
            # resolver that did not answer. A jumped side earns ERROR the moment
            # its jump host is unreachable, and `local=/lan/` is not the reason a
            # connection failed - excusing that would hide a broken vantage
            # behind a row someone marked as a deliberate difference.
            if [[ "$sa" != ERROR && "$sb" != ERROR ]] && dns_parity_row_excused "$note"; then
                excused=$((excused + 1))
                excused_lines+=("EXCUSED $line"$'\n'"    why: $note")
            else
                unexplained=$((unexplained + 1))
                if dns_matrix_expectation_met "$expectation" "$sa" "$aa"; then
                    line="$line | $ep_a meets the fixture's $expectation"
                else
                    line="$line | $ep_a does NOT meet the fixture's $expectation"
                fi
                if dns_matrix_expectation_met "$expectation" "$sb" "$ab"; then
                    line="$line | $ep_b meets it"
                else
                    line="$line | $ep_b does NOT meet it"
                fi
                unexplained_lines+=("UNEXPLAINED $line")
            fi
        fi
    done < <(grep -vE '^#|^$' "$fixture")

    if [[ "$rows" -eq 0 ]]; then
        # An empty matrix passes every comparison it never makes.
        echo "SKIP: the fixture has no rows"
        return 77
    fi
    if [[ "$errors_a" -eq "$rows" && "$errors_b" -eq "$rows" ]]; then
        # Not a disagreement to report: nothing was reached on either side, so
        # there is no observation to compare. Saying "they differ" here would
        # send a reader after a configuration difference that was never seen.
        echo "SKIP: neither resolver answered (is a jump host or address wrong?)"
        echo "      $ep_a: $errors_a/$rows queries returned ERROR"
        echo "      $ep_b: $errors_b/$rows queries returned ERROR"
        return 77
    fi

    local l
    for l in ${unexplained_lines+"${unexplained_lines[@]}"}; do printf '%s\n' "$l"; done
    for l in ${excused_lines+"${excused_lines[@]}"}; do printf '%s\n' "$l"; done

    echo "--- $ep_a vs $ep_b --- $rows rows compared, $unexplained unexplained, $excused excused"
    if [[ "$errors_a" -gt 0 || "$errors_b" -gt 0 ]]; then
        echo "note: $ep_a returned ERROR on $errors_a/$rows rows, $ep_b on $errors_b/$rows"
    fi
    if [[ "$unexplained" -gt 0 ]]; then
        echo "FAIL: $unexplained unexplained difference(s). Name a deliberate one ALLOW-DIFF in the fixture, or fix the resolver."
        return 1
    fi
    echo "PASS: no unexplained differences"
    return 0
}
