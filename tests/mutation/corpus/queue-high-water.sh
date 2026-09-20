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
  --why "dropping the -name filter counts a partially written file, an operator's note and a stray directory as queue depth. The guard then trips early and stops a stack whose queue is actually below the mark -- a protection that fails closed, on a timer that runs every ten minutes, with the only evidence being a log line saying the outbox is deep when it is not" \
  --apply 'sed -i.bak "s@ -name .\*\.nzb.@@" "$F" && rm -f "$F.bak"'
