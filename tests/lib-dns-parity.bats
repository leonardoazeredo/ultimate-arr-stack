#!/usr/bin/env bats
# scripts/lib/dns-parity.sh
#
# The parity harness decides whether two resolvers can be swapped for one
# another. Gate 3 is "zero unexplained differences", so the interesting cases
# are the ways it could report that while the two resolvers are in fact
# different:
#
#   * two results that differ only in status (NXDOMAIN vs NODATA) read as the
#     same row, which is exactly the known router/NAS difference for an unknown
#     .lan name - the one row this harness has to make visible;
#   * a resolver that answers nothing at all reads as "both sides agree",
#     because two empty answer sets match;
#   * ALLOW-DIFF waves an unexplained difference through, or fails to excuse a
#     deliberate one, depending on which side of the marker the code reads;
#   * a fixture with no rows passes every comparison it never makes.
#
# STUBS ARE EXECUTABLES ON $PATH, NOT SHELL FUNCTIONS
#
# A function override for dns_matrix_query does not survive this file's
# setup() sourcing the unit: under bats' `run`, the definition the library
# installed is the one a call in the test body reaches, whatever the test
# defines afterwards. That was observed, not theorised - the "stub" was
# silently bypassed and the real dig ran. An executable on $PATH is reached in
# every context, the same reason tests/helpers/stubs.bash exists. The library
# consequently resolves dig at call time; an absolute path captured at load
# time would ignore $PATH and defeat the stub the same way.
#
# The upshot: these tests drive the real dns_matrix_query and the real parsing,
# against a fake resolver. No network, no dig, no ssh.

setup() {
    load helpers/setup
    source "$REPO_ROOT/scripts/lib/dns-parity.sh"
    dns_parity_reset

    SIDE_A_HOST="10.0.0.1"
    SIDE_B_HOST="10.0.0.2"
    SIDE_A="$SIDE_A_HOST:53"
    SIDE_B="$SIDE_B_HOST:53"

    MATRIX="$BATS_TEST_TMPDIR/matrix.txt"

    REPLIES="$BATS_TEST_TMPDIR/replies"
    BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$REPLIES" "$BIN"
    PATH="$BIN:$PATH"
    DNS_PARITY_SSH_LOG="$BATS_TEST_TMPDIR/ssh.log"
    export PATH DNS_PARITY_REPLIES="$REPLIES" DNS_PARITY_SSH_LOG
    stub_dig
    stub_ssh
}

# The stubs are committed files copied onto $PATH rather than heredocs written
# into the test file. Two reasons, both learned the hard way: an embedded
# heredoc is one quoting mistake away from a stub that silently never matches,
# and `run-tests.sh` reads the test list out of this file. The committed files
# are also the same bytes on every run, on every host.
stub_dig() {
    cp "$REPO_ROOT/tests/fixtures/fake-dig.sh" "$BIN/dig"
    chmod +x "$BIN/dig"
}

# A fake ssh, which makes the jump path observable without a network. See the
# fixture's own header for the local:/refused contract.
stub_ssh() {
    cp "$REPO_ROOT/tests/fixtures/fake-ssh.sh" "$BIN/ssh"
    chmod +x "$BIN/ssh"
}

# replies <resolver> <row> ... — replace everything one resolver answers.
#
# A row is "<name>[@<status>][=<answer>[,<answer>]]" and the default status is
# NOERROR, so the only rows that spell it out are the ones that need a
# different one. Two rows in these tests genuinely answer NOERROR with an empty
# answer section (NODATA) and have to stay distinguishable from a resolver that
# did not answer at all — that is what the default buys.
#
# The registration is keyed by (resolver, name, qtype, transport), so a test
# varies one row without disturbing the rest of a resolver's answers - which is
# the whole point of driving the real dns_matrix_query rather than stubbing it.
replies() {
    local resolver="$1"; shift
    local row=""
    local spec name status answer
    for spec in "$@"; do
        name="$spec"; status="NOERROR"; answer=""
        [[ "$spec" == *=* ]] && { name="${spec%%=*}"; answer="${spec#*=}"; }
        [[ "$name" == *@* ]] && { status="${name##*@}"; name="${name%@*}"; }
        row+="$name"$'\t'"$status"$'\t'"${answer//,/$' '}"$'\n'
    done
    printf '%s' "$row" > "$REPLIES/${resolver}_53"
}

# The baseline every test perturbs: identical answers on both resolvers, except
# for the one row the test is about. Answers are modelled on the real fixture
# rows - two load-balanced ANY names, one .lan name, one unknown .lan name, one
# blocked name, one negative control - so the expectations the harness judges
# are the ones the real matrix uses.
seed_baseline() {
    replies "$SIDE_A_HOST" "agree.test=10.0.0.1" "nope.test=" \
        "diff.test=203.0.113.7" "nope.lan=" "ads.test=0.0.0.0" "wrong.test=10.9.9.9"
    # The unknown .lan row agrees here. The real difference - NODATA from the
    # NAS, NXDOMAIN from the router - is what the status-mutation test below
    # introduces, because it is the row Gate 3 exists to surface.
    replies "$SIDE_B_HOST" "agree.test=10.0.0.1" "nope.test=" \
        "diff.test=203.0.113.7" "nope.lan=" "ads.test=0.0.0.0" "wrong.test=10.9.9.9"
}

# A fixture whose rows cover agreement, disagreement, excused and negative
# control cases in one file. The note column is real fixture syntax: ALLOW-DIFF
# may appear anywhere in it.
write_matrix() {
    {
        printf '# a test matrix\n'
        printf '%s\n' "$(printf 'agree.test\tA\tudp\t10.0.0.1\tsame on both')"
        printf '%s\n' "$(printf 'nope.test\tA\tudp\tNODATA\tsame on both')"
        printf '%s\n' "$(printf 'diff.test\tA\tudp\tANY\ta load-balanced name')"
        printf '%s\n' "$(printf 'nope.lan\tA\tudp\tNXDOMAIN\tunknown .lan name')"
        printf '%s\n' "$(printf 'ads.test\tA\tudp\tNXDOMAIN\tALLOW-DIFF: named on purpose')"
        printf '%s\n' "$(printf 'wrong.test\tA\tudp\t10.9.9.9\tneither side matches this')"
    } > "$MATRIX"
}

# The report assertions match with `grep -qF` rather than `[[ $output == *x* ]]`.
# Two reasons, both worth keeping. The pattern form needs the caller to know
# where the report's line breaks are: an assertion written as "UNEXPLAINED
# something" is false against a line that starts "UNEXPLAINED DIFF something",
# and it reads as if it should pass - a failure that says nothing about the
# code. And a literal handed to the pattern form is still a pattern; -F says
# "this is text".
output_has() {
    printf '%s\n' "$output" | grep -qF -- "$1"
}

output_lacks() {
    ! printf '%s\n' "$output" | grep -qF -- "$1"
}

# --- resolver specs ---------------------------------------------------------
#
# The two resolvers are not reachable from the same place: the NAS answers from
# a client VLAN, the router's AdGuard Home on :3053 only from pi1. A harness
# that cannot carry that distinction reports a parity result nobody can debug,
# so the spec grammar is unit-tested like any other parsing.

@test "dns-parity: a plain host:port spec parses with no jump" {
    # Fails if the parser starts requiring a jump= prefix, which would make the
    # common case - both resolvers local - unusable.
    run dns_parity_parse_spec "192.168.110.246:53"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '192.168.110.246\t53\t')" ]
}

@test "dns-parity: a host with no port defaults to 53" {
    # Fails if the port becomes mandatory, so `./scripts/dns-parity.sh 192.168.110.246`
    # - the sibling script's form - stops working.
    run dns_parity_parse_spec "192.168.110.246"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '192.168.110.246\t53\t')" ]
}

@test "dns-parity: a jump= spec keeps the jump host and the resolver apart" {
    # Fails if the parser keeps the jump host as part of the address, so queries
    # go to a name that does not resolve instead of through pi1.
    run dns_parity_parse_spec "jump=pi@pi1.local:192.168.8.1:3053"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '192.168.8.1\t3053\tpi@pi1.local')" ]
}

@test "dns-parity: a jump= spec with no port defaults to 53" {
    # Fails if the port default only applies to the non-jump branch.
    run dns_parity_parse_spec "jump=pi@pi1.local:192.168.8.1"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '192.168.8.1\t53\tpi@pi1.local')" ]
}

@test "dns-parity: a malformed spec is refused rather than guessed at" {
    # Fails if a spec that cannot be parsed is coerced into something
    # plausible. Guessing here means querying an address nobody asked for and
    # reporting the answer as if it came from the resolver that was named.
    run dns_parity_parse_spec "jump=pi@pi1.local"
    [ "$status" -eq 1 ]
    run dns_parity_parse_spec "192.168.110.246:notaport"
    [ "$status" -eq 1 ]
    run dns_parity_parse_spec "192.168.110.246:99999"
    [ "$status" -eq 1 ]
}

# --- comparison -------------------------------------------------------------

@test "dns-parity: two resolvers that agree report zero unexplained differences" {
    # Fails if a matching row is ever classified as a difference - the harness
    # would be unusable against a correct pair.
    write_matrix
    seed_baseline
    run dns_parity_check "$SIDE_A" "$SIDE_B" "$MATRIX"
    [ "$status" -eq 0 ]
    output_has "0 unexplained"
    output_has "6 rows compared"
}

@test "dns-parity: two resolvers that disagree on an answer are reported" {
    # Fails if the answers are not compared, only the statuses - a resolver
    # handing out the wrong address would read as parity.
    write_matrix
    seed_baseline
    replies "$SIDE_B_HOST" "agree.test=10.0.0.9" "nope.test=" \
        "diff.test=203.0.113.7" "nope.lan=" "ads.test=0.0.0.0" "wrong.test=10.9.9.9"
    run dns_parity_check "$SIDE_A" "$SIDE_B" "$MATRIX"
    [ "$status" -eq 1 ]
    output_has "UNEXPLAINED DIFF agree.test"
    output_has "1 unexplained"
}

@test "dns-parity: a status mutation (NXDOMAIN vs NODATA) is an unexplained difference" {
    # Fails if two results are compared by their answer section alone. This is
    # the known router/NAS difference for an unknown .lan name: the NAS Pi-hole
    # answers NODATA because address=/lan/:: gives the zone data, the router's
    # dnsmasq answers NXDOMAIN because local=/lan/ makes it authoritative with
    # none. Both have an empty answer section, so an answer-only comparison
    # would report parity on the exact row Gate 3 is meant to surface.
    write_matrix
    seed_baseline
    replies "$SIDE_B_HOST" "agree.test=10.0.0.1" "nope.test=" \
        "diff.test=203.0.113.7" "nope.lan@NXDOMAIN" "ads.test=0.0.0.0" "wrong.test=10.9.9.9"
    run dns_parity_check "$SIDE_A" "$SIDE_B" "$MATRIX"
    # The NAS side answers NODATA for the unknown .lan row; the router side
    # answers NXDOMAIN for the same name. Same empty answer section.
    [ "$status" -eq 1 ]
    output_has "UNEXPLAINED DIFF nope.lan"
    output_has "NXDOMAIN"
    output_has "NODATA"
}

@test "dns-parity: a difference named ALLOW-DIFF is excused and listed separately" {
    # Fails two ways: if the marker is ignored, a deliberate difference is
    # reported as unexplained and Gate 3 can never pass; if every difference is
    # excused, the marker means nothing and the report cannot be read.
    write_matrix
    seed_baseline
    # The NAS-shaped side answers the blocked name with NXDOMAIN. That row is
    # the fixture's ALLOW-DIFF row, and NXDOMAIN satisfies its expectation, so
    # this is a difference between two valid answers and nothing else.
    replies "$SIDE_A_HOST" "agree.test=10.0.0.1" "nope.test=" \
        "diff.test=203.0.113.7" "nope.lan=" "ads.test@NXDOMAIN" "wrong.test=10.9.9.9"
    run dns_parity_check "$SIDE_A" "$SIDE_B" "$MATRIX"
    [ "$status" -eq 0 ]
    output_has "0 unexplained"
    output_has "1 excused"
    output_has "EXCUSED DIFF ads.test"
    output_has "named on purpose"
}

@test "dns-parity: a deliberate difference without the marker is not excused" {
    # Fails if the excuse is granted per run rather than per row, or if it is
    # granted to any difference at all. The marked row here agrees and the
    # unmarked one differs, so a harness that excuses everything because
    # something in the fixture was marked reports "0 unexplained" while a real
    # difference sits in the matrix. The fixture header is explicit that a
    # deliberate difference is named, not waved through.
    write_matrix
    seed_baseline
    replies "$SIDE_B_HOST" "agree.test=10.0.0.1" "nope.test=" \
        "diff.test=203.0.113.7" "nope.lan@NXDOMAIN" "ads.test=0.0.0.0" "wrong.test=10.9.9.9"
    run dns_parity_check "$SIDE_A" "$SIDE_B" "$MATRIX"
    [ "$status" -eq 1 ]
    output_has "1 unexplained"
    output_has "UNEXPLAINED DIFF nope.lan"
}

@test "dns-parity: sharing one expectation is not the same as agreeing" {
    # Fails if a row is called "same" whenever both sides satisfy the fixture's
    # expectation. Two load-balanced names (expectation ANY) can both satisfy
    # ANY and still hand out different answers, and the reader of a parity
    # report is asking whether the two are interchangeable, not whether each
    # one is individually acceptable.
    write_matrix
    seed_baseline
    replies "$SIDE_B_HOST" "agree.test=10.0.0.1" "nope.test=" \
        "diff.test=198.51.100.4" "nope.lan=" "ads.test=0.0.0.0" "wrong.test=10.9.9.9"
    run dns_parity_check "$SIDE_A" "$SIDE_B" "$MATRIX"
    [ "$status" -eq 1 ]
    output_has "UNEXPLAINED DIFF diff.test"
}

@test "dns-parity: the same addresses in a different order are not a difference" {
    # Fails if the answer sets are compared in order. Measured on the live pair:
    # the NAS Pi-hole and AdGuard Home both answer the ANY rows but list the
    # addresses in opposite order, and the in-order comparison reported that as
    # an unexplained difference on a row the fixture already labels
    # load-balanced. A Gate 3 failure invented by answer ordering is exactly the
    # kind of noise that gets a real difference read as ordinary.
    write_matrix
    seed_baseline
    replies "$SIDE_B_HOST" "agree.test=10.0.0.1" "nope.test=" \
        "diff.test=198.51.100.4,203.0.113.7" "nope.lan=" "ads.test=0.0.0.0" "wrong.test=10.9.9.9"
    replies "$SIDE_A_HOST" "agree.test=10.0.0.1" "nope.test=" \
        "diff.test=203.0.113.7,198.51.100.4" "nope.lan=" "ads.test=0.0.0.0" "wrong.test=10.9.9.9"
    run dns_parity_check "$SIDE_A" "$SIDE_B" "$MATRIX"
    [ "$status" -eq 0 ]
    output_has "0 unexplained"
}

@test "dns-parity: two sides that both fail the expectation are still a difference" {
    # Fails if the verdict rests on dns_matrix_expectation_met alone: a pair of
    # answers that are both wrong in different ways is still a parity failure,
    # and reporting "no unexplained differences" while both resolvers answer the
    # wrong address is the worst possible verdict here.
    write_matrix
    seed_baseline
    replies "$SIDE_A_HOST" "agree.test=10.0.0.1" "nope.test=" \
        "diff.test=203.0.113.7" "nope.lan=" "ads.test=0.0.0.0" "wrong.test=10.0.0.8"
    replies "$SIDE_B_HOST" "agree.test=10.0.0.1" "nope.test=" \
        "diff.test=203.0.113.7" "nope.lan=" "ads.test=0.0.0.0" "wrong.test=10.0.0.7"
    run dns_parity_check "$SIDE_A" "$SIDE_B" "$MATRIX"
    [ "$status" -eq 1 ]
    output_has "UNEXPLAINED DIFF wrong.test"
}

@test "dns-parity: a resolver that never answers is not agreement" {
    # Fails if two empty results compare equal. A resolver that is down, blocked
    # by a firewall or refusing answers returns no status and no answers, and
    # "nothing equals nothing" is the most dangerous way this harness could
    # report parity.
    write_matrix
    # Only the first side answers anything at all; every row on the second side
    # is unregistered, which is what ERROR means.
    replies "$SIDE_A_HOST" "agree.test=10.0.0.1" "nope.test=" \
        "diff.test=203.0.113.7" "nope.lan=" "ads.test=0.0.0.0" "wrong.test=10.9.9.9"
    run dns_parity_check "$SIDE_A" "$SIDE_B" "$MATRIX"
    [ "$status" -eq 1 ]
    output_has "6 unexplained"
    output_has "UNEXPLAINED DIFF agree.test"
}

@test "dns-parity: one resolver answering nothing at all is a difference, not a pass" {
    # Fails if the ERROR status is normalised away. ERROR is dns_matrix_query's
    # "dig never reached anything"; if it is folded into NODATA the unreachable
    # resolver would satisfy every NODATA row and the harness would approve a
    # pair in which one side answers nothing.
    write_matrix
    replies "$SIDE_B_HOST" "agree.test=10.0.0.1" "nope.test=" \
        "diff.test=203.0.113.7" "nope.lan=" "ads.test=0.0.0.0" "wrong.test=10.9.9.9"
    run dns_parity_check "$SIDE_A" "$SIDE_B" "$MATRIX"
    [ "$status" -eq 1 ]
    output_has "UNEXPLAINED DIFF nope.test"
}

# --- vacuity guards ---------------------------------------------------------

@test "dns-parity: a fixture with no rows is a no-oracle skip, not a pass" {
    # Fails if an empty fixture exits 0. An empty matrix passes every comparison
    # it never makes, which is how dns_matrix_check_resolver was already fixed
    # once in this repo.
    : > "$MATRIX"
    run dns_parity_check "$SIDE_A" "$SIDE_B" "$MATRIX"
    [ "$status" -eq 77 ]
    output_has "no rows"
}

@test "dns-parity: an unreadable fixture is a no-oracle skip" {
    # Fails if a missing fixture is treated as agreement or as a difference.
    # 77 is the repo's "no oracle" status: a check that could not run must not
    # look like one that ran and passed.
    run dns_parity_check "$SIDE_A" "$SIDE_B" "$BATS_TEST_TMPDIR/nope.txt"
    [ "$status" -eq 77 ]
    output_has "cannot read fixture"
}

@test "dns-parity: both resolvers unreachable is a no-oracle skip, not a difference" {
    # Fails if "neither side could be reached" reports as a failed comparison.
    # Two unreachable resolvers are not evidence that they disagree, and the
    # reader needs "I could not run" to be a different answer from "they differ".
    write_matrix
    run dns_parity_check "$SIDE_A" "$SIDE_B" "$MATRIX"
    [ "$status" -eq 77 ]
    output_has "neither resolver answered"
}

# --- vantage points ---------------------------------------------------------

@test "dns-parity: the jumped side runs dig through the jump host" {
    # Fails if the jump= spec is parsed but never used - the queries would go
    # out from this host, get dropped by the router's firewall, and every row
    # would read as a difference for the wrong reason. The resolver spec keeps
    # the NAS-shaped address but names a jump target, so a run that ignored the
    # jump would never reach the ssh stub and the log would stay empty.
    write_matrix
    seed_baseline
    run dns_parity_check "jump=local:pi@pi1.local:$SIDE_A_HOST:53" "$SIDE_B" "$MATRIX"
    [ "$status" -eq 0 ]
    output_has "via local:pi@pi1.local"
    output_has "$SIDE_A (via local:pi@pi1.local)"
    [ -f "$DNS_PARITY_SSH_LOG" ]
    grep -q '^local:pi@pi1.local$' "$DNS_PARITY_SSH_LOG"
}

@test "dns-parity: ALLOW-DIFF does not excuse a resolver that never answered" {
    # Fails if the marker is checked before the ERROR status. A jumped side
    # returns ERROR on every row the moment its jump host is unreachable, and a
    # marked row would then read as a healthy deliberate difference while the
    # vantage it depends on is simply gone.
    write_matrix
    seed_baseline
    run dns_parity_check "$SIDE_A" "jump=pi@nowhere.invalid:$SIDE_B_HOST:53" "$MATRIX"
    [ "$status" -eq 1 ]
    output_has "UNEXPLAINED DIFF ads.test"
    output_lacks "EXCUSED DIFF ads.test"
}
