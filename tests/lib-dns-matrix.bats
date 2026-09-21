#!/usr/bin/env bats
# scripts/lib/dns-matrix.sh
#
# The evaluator decides whether a resolver's answer satisfies a row of
# tests/fixtures/dns-baseline.txt. Every later phase is judged by its verdict, so
# the ways it could say "fine" about a wrong answer are the interesting cases:
#
#   * BLOCKED that accepts any answer at all, which would make the whole
#     blocklist column of the migration read as passing on a resolver that
#     blocks nothing;
#   * NODATA and NXDOMAIN treated as interchangeable, which they are not -
#     `local=/lan/` answers NOERROR with no record, while a name that does not
#     exist comes back NXDOMAIN, and a resolver that has started refusing must
#     not read as either;
#   * an empty fixture reported as a pass.

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init
    source "$REPO_ROOT/scripts/lib/dns-matrix.sh"

    mkdir -p "$STUB_DIR/dig-replies"
    stub_tool dig "$(_fake_dig_body)"

    MATRIX="$BATS_TEST_TMPDIR/matrix.txt"
    printf '%s\n' \
        "$(printf 'good.test\tA\tudp\t10.0.0.1\texact answer')" \
        "$(printf 'blocked.test\tA\tudp\tBLOCKED\tblocklist hit')" \
        "$(printf 'gone.test\tA\tudp\tNXDOMAIN\tcontrol')" \
        "$(printf 'local.test\tA\tudp\tNODATA\tanswered locally with no record')" \
        "$(printf 'any.test\tA\tudp\tANY\tload balanced')" \
        > "$MATRIX"
}

# Answers from a response directory keyed by <name>_<qtype>_<transport>, which
# keeps each test's setup to one line and exercises the real parsing.
_fake_dig_body() {
    cat <<'BODY'
expect_port=0
name=""
qtype=""
transport="udp"
for a in "$@"; do
    case "$a" in
        +tcp) transport="tcp" ;;
        -p) expect_port=1 ;;
        @*) ;;
        +*) ;;
        *)
            if [ "$expect_port" = "1" ]; then
                expect_port=0
            elif [ -z "$name" ]; then
                name="$a"
            else
                qtype="$a"
            fi
            ;;
    esac
done
reply="$STUB_DIR/dig-replies/${name}_${qtype}_${transport}"
if [ -f "$reply" ]; then
    cat "$reply"
else
    printf ';; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1\n\n;; ANSWER SECTION:\n'
fi
BODY
}

# dig_reply <file> <status> [answer...]
dig_reply() {
    local file="$1" status="$2"; shift 2
    {
        printf ';; ->>HEADER<<- opcode: QUERY, status: %s, id: 1\n' "$status"
        printf ';; flags: qr rd ra; QUERY: 1, ANSWER: %d, AUTHORITY: 0, ADDITIONAL: 0\n\n' "$#"
        printf ';; ANSWER SECTION:\n'
        local a
        for a in "$@"; do
            printf 'x.test.\t5\tIN\tA\t%s\n' "$a"
        done
    } > "$STUB_DIR/dig-replies/$file"
}

seed_all_correct() {
    dig_reply good.test_A_udp NOERROR 10.0.0.1
    dig_reply blocked.test_A_udp NOERROR 0.0.0.0
    dig_reply gone.test_A_udp NXDOMAIN
    dig_reply local.test_A_udp NOERROR
    dig_reply any.test_A_udp NOERROR 203.0.113.7
}

@test "dns-matrix: a fully correct resolver matches every row" {
    seed_all_correct
    run dns_matrix_check_resolver 10.0.0.1 53 "$MATRIX"
    [ "$status" -eq 0 ]
    [[ "$output" == *"5/5 rows matched"* ]]
}

@test "dns-matrix: a wrong address is reported against its row" {
    seed_all_correct
    dig_reply good.test_A_udp NOERROR 10.0.0.9
    run dns_matrix_check_resolver 10.0.0.1 53 "$MATRIX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL good.test A udp: expected 10.0.0.1, got NOERROR 10.0.0.9"* ]]
    [[ "$output" == *"4/5 rows matched"* ]]
}

@test "dns-matrix: a right address alongside a wrong one is not a match" {
    seed_all_correct
    dig_reply good.test_A_udp NOERROR 10.0.0.1 10.0.0.9
    run dns_matrix_check_resolver 10.0.0.1 53 "$MATRIX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL good.test A udp"* ]]
}

@test "dns-matrix: BLOCKED does not accept an unblocked answer" {
    seed_all_correct
    dig_reply blocked.test_A_udp NOERROR 93.184.216.34
    run dns_matrix_check_resolver 10.0.0.1 53 "$MATRIX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL blocked.test A udp: expected BLOCKED"* ]]
}

@test "dns-matrix: NODATA and NXDOMAIN are not the same answer" {
    seed_all_correct
    dig_reply local.test_A_udp NXDOMAIN
    run dns_matrix_check_resolver 10.0.0.1 53 "$MATRIX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL local.test A udp: expected NODATA"* ]]
}

@test "dns-matrix: ANY needs a value, not a particular one" {
    seed_all_correct
    dig_reply any.test_A_udp NOERROR 198.51.100.4
    run dns_matrix_check_resolver 10.0.0.1 53 "$MATRIX"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok   any.test A udp -> 198.51.100.4"* ]]

    dig_reply any.test_A_udp NXDOMAIN
    run dns_matrix_check_resolver 10.0.0.1 53 "$MATRIX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL any.test A udp: expected ANY"* ]]
}

@test "dns-matrix: a resolver that never answers is not a pass" {
    # No reply files at all: the stub returns NXDOMAIN for everything.
    run dns_matrix_check_resolver 10.0.0.1 53 "$MATRIX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL good.test A udp"* ]]
}

@test "dns-matrix: an empty fixture is not a pass" {
    : > "$BATS_TEST_TMPDIR/empty.txt"
    run dns_matrix_check_resolver 10.0.0.1 53 "$BATS_TEST_TMPDIR/empty.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"the fixture has no rows"* ]]
}

@test "dns-matrix: a missing fixture is a skip, not a pass" {
    run dns_matrix_check_resolver 10.0.0.1 53 "$BATS_TEST_TMPDIR/nope.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"SKIP: cannot read fixture"* ]]
}

# --------------------------------------------------------------------------
# The LAN_AAAA expectation — the one `.lan` row the two resolvers answer
# differently, and the only one where pinning a literal would be wrong.
#
# dnsmasq (the fallback) holds `address=/lan/::` and answers the literal `::`.
# AdGuard Home (the healthy path) answers NOERROR with no record, because its
# DNS rewrites carry an IPv4 address only. Phase 3.3 settled this in favour of
# NODATA, having measured that musl's hard failure is AAAA *NXDOMAIN* rather than
# an empty answer. A row pinned to `::` would fail on the healthy path and pass
# on the fallback, which is the exact inversion of what the row is for.
#
# These call the expectation directly rather than through a fixture: the question
# is what the rule accepts, not how a fixture is parsed.

@test "dns-matrix: LAN_AAAA accepts NODATA, which is what AdGuard Home answers" {
    # RED if the rule demanded an answer section. AdGuard is what serves the
    # house on the healthy path, so a rule that rejected NODATA would make the
    # migration's own target state read as broken.
    run dns_matrix_expectation_met LAN_AAAA NOERROR ""
    [ "$status" -eq 0 ]
}

@test "dns-matrix: LAN_AAAA accepts the literal :: that dnsmasq answers" {
    # RED if the rule were narrowed to NODATA alone. This is the watchdog's
    # fallback state, and a house running on dnsmasq in an incident must not be
    # scored against a rule that only the healthy resolver satisfies.
    run dns_matrix_expectation_met LAN_AAAA NOERROR "::"
    [ "$status" -eq 0 ]
}

@test "dns-matrix: LAN_AAAA refuses NXDOMAIN" {
    # The whole point of the row: NXDOMAIN on AAAA is what musl turns into a hard
    # resolution failure. RED if the status check were dropped, because NXDOMAIN
    # carries no answers and would then satisfy the "no answer is fine" arm.
    run dns_matrix_expectation_met LAN_AAAA NXDOMAIN ""
    [ "$status" -eq 1 ]
}

@test "dns-matrix: LAN_AAAA refuses an unreachable resolver" {
    # ERROR is "dig never reached anything", which must never read as an answer.
    # RED if the rule accepted anything that was not NXDOMAIN.
    run dns_matrix_expectation_met LAN_AAAA ERROR ""
    [ "$status" -eq 1 ]
}

@test "dns-matrix: LAN_AAAA refuses an .lan name pointing at some other address" {
    # RED if the answer set were not checked at all. A `.lan` name that resolves
    # to an undeclared IPv6 address is a real misconfiguration, not a variant of
    # `::`.
    run dns_matrix_expectation_met LAN_AAAA NOERROR "2001:db8::1"
    [ "$status" -eq 1 ]
}
