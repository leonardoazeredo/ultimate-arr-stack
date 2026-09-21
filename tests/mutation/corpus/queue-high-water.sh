#!/bin/bash
# Guards added with scripts/lib/queue_high_water.sh, 2026-09-20.
#
# The outbox is the arrs' work queue and the blackhole's backlog. Measured that
# day it reached 588 NZBs while the pressure gate was refusing passes, and
# every one of those becomes local I/O the moment the gate opens -- each
# release costing a large multiple of its delivered size in platter writes.

# --- the boundary trips one file late --------------------------------------

mutation queue-high-water-trips-one-late \
  --file scripts/lib/queue_high_water.sh \
  --bats tests/lib-queue-high-water.bats \
  --test "queue-high-water: at the mark is over it" \
  --why "'>' rather than '>=' admits one more producer pass at exactly the mark. On this ingest one pass is up to 3 Seerr requests from stremio-library-sync or a whole 4-hourly backlog slice, and each requested title becomes an NZB and then a multi-GB local download. The boundary is not cosmetic: at the mark the producer is already one pass behind what the drain clears, so that is the file where it has to stop" \
  --apply 'sed -i.bak "s@-ge \"\$QUEUE_HIGH_WATER\"@-gt \"\$QUEUE_HIGH_WATER\"@" "$F" && rm -f "$F.bak"'

# --- the count includes files the arr did not write ------------------------

mutation queue-high-water-counts-non-nzbs \
  --file scripts/lib/queue_high_water.sh \
  --bats tests/lib-queue-high-water.bats \
  --test "queue-high-water: only .nzb files count" \
  --why "dropping the -name filter counts a partially written file and an operator's note as queue depth -- the two additions this makes are Rel-9-GRP.nzb.partial and notes.txt. It cannot also count the stray a-directory.nzb: -type f survives the edit and excludes it. The guard then trips early and stops a stack whose queue is actually below the mark -- a protection that fails closed, on a timer that runs every ten minutes, with the only evidence being a log line saying the outbox is deep when it is not" \
  --apply 'sed -i.bak "s@ -name .\*\.nzb.@@" "$F" && rm -f "$F.bak"'

# --- the pipeline failure reaches the caller -------------------------------
#
# `outbox_depth` clears that pipeline itself now -- `if ! count="$(find ...)"`
# with the pipeline's stderr dropped -- so there is no ` || true` left to
# remove. The rescue branch is the whole protection, and re-raising its status
# is what puts the failure back on the caller: a producer that assigns the
# depth straight into a command substitution under `set -euo pipefail` dies on
# a directory it cannot read, which is the guard against an overloaded host
# taking the timer down instead.

mutation queue-high-water-pipeline-failure-propagates \
  --file scripts/lib/queue_high_water.sh \
  --bats tests/lib-queue-high-water.bats \
  --test "queue-high-water: an unreadable outbox reads as zero and does not abort the caller" \
  --why "both producers run under 'set -euo pipefail' and assign the depth straight into a command substitution. An existing-but-unreadable outbox makes 'find' exit 1, and a rescue branch that returns that status instead of zero carries it out of the function and into the caller -- so the guard against an overloaded host takes the producer timer down instead, and the log's last line is a depth count rather than an error anyone can act on. The documented contract is 'never fails', and this is the entry that says so mechanically" \
  --apply 'sed -i.bak "s@^    return\$@    return 1@" "$F" && rm -f "$F.bak"'
