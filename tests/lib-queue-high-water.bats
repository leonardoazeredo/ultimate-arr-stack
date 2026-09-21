#!/usr/bin/env bats
# scripts/lib/queue_high_water.sh -- the outbox depth count and its threshold.
#
# The guard is three lines of shell, and the two things that can go wrong in it
# are both invisible on a quiet box: a count that includes files the arr did
# not write, and a threshold that trips one file late. The first over-reports
# the queue and stops a healthy stack; the second is one more pass of inflow
# than the mark allows, which on this ingest is another 40 GB of local I/O.

setup() {
    load helpers/setup
    LIB="$REPO_ROOT/scripts/lib/queue_high_water.sh"
    # shellcheck source=scripts/lib/queue_high_water.sh
    . "$LIB"
    OUTBOX="$BATS_TEST_TMPDIR/nzb"
    mkdir -p "$OUTBOX"
}

# `$1` NZBs in the outbox, named the way the arr names them.
seed_outbox() {
    local i
    for ((i = 0; i < $1; i++)); do
        : > "$OUTBOX/Rel-$i-GRP.nzb"
    done
}

@test "queue-high-water: an empty outbox is depth zero and under the mark" {
    run outbox_depth "$OUTBOX"
    [ "$output" = "0" ]
    run outbox_over_high_water "$OUTBOX"
    [ "$status" -ne 0 ]
}

@test "queue-high-water: a missing outbox reads as zero, not as an error" {
    # A stack that has never run has no outbox. A guard that treats that as a
    # failure stops a first run, which is the opposite of what a queue-depth
    # check is for.
    run outbox_depth "$BATS_TEST_TMPDIR/nope"
    [ "$output" = "0" ]
    run outbox_over_high_water "$BATS_TEST_TMPDIR/nope"
    [ "$status" -ne 0 ]
}

@test "queue-high-water: only .nzb files count" {
    # The arr writes its NZB atomically, but its own temp names and anything an
    # operator drops in the folder are not queue depth. Counting them makes the
    # guard trip early, which stops a healthy stack for no reason.
    seed_outbox 2
    : > "$OUTBOX/Rel-9-GRP.nzb.partial"
    : > "$OUTBOX/notes.txt"
    mkdir -p "$OUTBOX/a-directory.nzb"
    run outbox_depth "$OUTBOX"
    [ "$output" = "2" ]
}

@test "queue-high-water: at the mark is over it" {
    # >= and not >. At the mark the producer is already one pass behind what
    # the drain can clear, and the failure this guard exists to prevent is the
    # queue growing while the drain is stopped -- so the boundary is where it
    # has to trip, not one file later.
    QUEUE_HIGH_WATER=3
    seed_outbox 2
    run outbox_over_high_water "$OUTBOX"
    [ "$status" -ne 0 ]

    seed_outbox 3
    run outbox_over_high_water "$OUTBOX"
    [ "$status" -eq 0 ]
}

@test "queue-high-water: the mark is 50 unless the environment says otherwise" {
    # The value the producers actually get, in the file, so a change to it is a
    # change someone made on purpose. Five hundred and eighty-eight NZBs is
    # what the queue reached on 2026-09-20; this is what it is allowed to reach.
    [ "$QUEUE_HIGH_WATER" = "50" ]
}

@test "queue-high-water: an unreadable outbox reads as zero and does not abort the caller" {
    # Both producers run under `set -euo pipefail` and assign this straight
    # into a command substitution. An existing-but-unreadable directory made
    # `find` exit 1, which pipefail propagated and `set -e` turned into a dead
    # producer timer -- a guard that stops the pass it exists to pace. The
    # documented contract is "never fails", so this pins it.
    #
    # Two properties, and only one of them is about the number. The count has
    # to read as zero, and the caller has to survive. The note on stderr is
    # what keeps the second from being indistinguishable from an empty queue,
    # so it is asserted too -- and the two streams are read apart, because the
    # warning and the depth would otherwise land in the same string.
    #
    # `chmod 000` does not block root. Run as root the directory stays
    # readable, the rescue branch is never taken, and the note assertion below
    # fails rather than passing vacuously -- which is why the suite is not run
    # as root, and why the mutation corpus entry for this test exists.
    mkdir -p "$OUTBOX"
    chmod 000 "$OUTBOX"
    run bash -c '
        set -euo pipefail
        . "$1"
        X="$(outbox_depth "$2" 2>"$3")"
        printf "depth=%s\n" "$X"
        printf "note=%s\n" "$(cat "$3")"
    ' _ "$LIB" "$OUTBOX" "$BATS_TEST_TMPDIR/depth.err"
    chmod 755 "$OUTBOX"
    [ "$status" -eq 0 ]
    [[ "$output" == *"depth=0"* ]]
    [[ "$output" == *"cannot read"* ]]
}
