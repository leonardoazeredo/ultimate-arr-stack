#!/bin/bash
# A fake dig for tests/lib-dns-parity.bats — put this file on $PATH as `dig`.
#
# Each registered answer is keyed by the resolver (@host), the port (-p), the
# name and the record type, which is the addressing a real resolver is asked
# with, so a test can vary one row of one resolver's answers without touching
# the rest.
#
# Answers come from $DNS_PARITY_REPLIES/<host>_<port>, one line per name:
#
#     <name>\t<status>\t<answer>[,<answer>...]
#
# A name with no line is "dig never reached anything": no status, no answer
# section, which is what dns_matrix_query turns into ERROR. That distinction is
# the point of a fake resolver here — a resolver that answers NODATA and a
# resolver that did not answer at all must not look the same.
#
# It lives in tests/fixtures/ rather than inline in the bats file because the
# bats file is parsed by `run-tests.sh`, which reads the test list out of the
# file: an embedded heredoc containing `@test`-adjacent syntax has bitten this
# kind of stub before. A committed file is also the same bytes on every run.
#
# Exit status is always 0: dig's own status is not what these tests judge, and
# a non-zero exit here would be swallowed by dns_matrix_query's `|| true`
# anyway, hiding the difference between "refused" and "did not answer".

host=""
port="53"
name=""
qtype="A"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p) port="$2"; shift 2 ;;
        @*) host="${1#@}"; shift ;;
        +tcp) shift ;;
        +*) shift ;;
        *)
            if [[ -z "$name" ]]; then name="$1"; else qtype="$1"; fi
            shift
            ;;
    esac
done

row="$DNS_PARITY_REPLIES/${host}_${port}"
status=""
answers=""
if [[ -f "$row" ]]; then
    while IFS=$'\t' read -r r_name r_status r_answers; do
        [[ -z "$r_name" ]] && continue
        if [[ "$r_name" == "$name" ]]; then
            status="$r_status"
            answers="$r_answers"
            break
        fi
    done < "$row"
fi

if [[ -z "$status" ]]; then
    printf ';; connection timed out; no servers could be reached\n'
    exit 0
fi

set -- $answers
printf ';; ->>HEADER<<- opcode: QUERY, status: %s, id: 1\n' "$status"
printf ';; flags: qr rd ra; QUERY: 1, ANSWER: %d, AUTHORITY: 0, ADDITIONAL: 0\n\n' "$#"
printf ';; ANSWER SECTION:\n'
for a in "$@"; do
    printf 'x.test.\t5\tIN\t%s\t%s\n' "$qtype" "$a"
done
