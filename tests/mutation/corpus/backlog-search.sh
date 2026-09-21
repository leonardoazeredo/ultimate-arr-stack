#!/bin/bash
# Guards added with scripts/backlog-search.sh, 2026-09-14.
#
# The sweep walks an ordered list of missing seasons and searches at most
# `--limit` per run. Every entry here is a way that walk stops advancing while
# still reporting queued searches -- the shape of failure that looks like
# progress in a log.

# --- the walk re-searches its own head forever -----------------------------

mutation backlog-walk-never-advances \
  --file scripts/lib/backlog_search.py \
  --bats tests/python-suite.bats \
  --test "^python: the extracted modules pass their pytest suite" \
  --why "the ordered walk restarts at the head of the list every run, so without the skip it re-searches the same first limit seasons every interval and the tail of a 207-season backlog is never reached. Measured on the NAS 2026-09-14: the 00:02 run searched series 3-5 seasons 1-6, and the 04:02 run would have searched exactly those again. It reads as progress, because the same lines keep appearing" \
  --apply 'perl -pi -e "s/\Q    fresh = [u for u in units if unit_id(u[0], u[1]) not in recent]\E/    fresh = list(units)/" "$F"'

# --- a searched unit is never retried --------------------------------------

mutation backlog-walk-never-retries-a-unit \
  --file scripts/lib/backlog_search.py \
  --bats tests/python-suite.bats \
  --test "^python: the extracted modules pass their pytest suite" \
  --why "the skip becomes a permanent exclusion instead of a delay, so a season that produced no grab when it was first tried is never tried again and the backlog silently stops draining even though every run reports work" \
  --apply 'perl -pi -e "s/\Q    cutoff = now - timedelta(hours=hours)\E/    cutoff = now - timedelta(hours=hours*10000)/" "$F"'

# --- the episode cooldown satisfies the film cooldown ----------------------

mutation backlog-cooldowns-share-one-kind \
  --file scripts/lib/backlog_search.py \
  --bats tests/python-suite.bats \
  --test "^python: the extracted modules pass their pytest suite" \
  --why "both kinds of record live in one history list; matching on the wrong kind lets an episode search satisfy the film cooldown, so the films are never searched again while the episodes keep being swept" \
  --apply 'perl -pi -e "s/\Q        if entry.get(\"kind\") != kind:\E/        if False:/" "$F"'

# --- the unbounded command comes back --------------------------------------

mutation backlog-search-reaches-for-the-unbounded-command \
  --file scripts/backlog-search.sh \
  --bats tests/backlog-search.bats \
  --test "^backlog-search: the script never shells out to an unbounded arr command" \
  --why "MissingEpisodeSearch searches the whole backlog in one command, cannot be cancelled once started, and had to be killed by restarting Sonarr on 2026-09-13. This entry proves the guard that keeps the unbounded command out of the script can actually fail" \
  --apply 'perl -pi -e "s/^        python3 /        python3 MissingEpisodeSearch /" "$F"'

# --- the queue check is not reached ----------------------------------------

mutation backlog-search-queue-check-removed \
  --file scripts/backlog-search.sh \
  --bats tests/backlog-search.bats \
  --test "backlog-search: a deep outbox stands the pass down" \
  --why "the call site is the load-bearing half: the library can answer whether the outbox is deep, but only this line acts on it. With the check gone the four-hourly sweep keeps queueing a whole backlog slice -- 4,614 missing episodes across 71 series, measured -- into an outbox the drain clears at about 24 releases an hour, and every one of those NZBs becomes multi-GB local I/O. The library's own tests stay green, so nothing else notices" \
  --apply 'perl -0777 -pi -e "s/\Qif outbox_over_high_water \E.*?\nfi\n//s" "$F"'

# --- the queue check is ordered above the key checks -----------------------
#
# The gate exits 0 -- it is a pause, not a failure. Above the key checks that
# makes the two indistinguishable: "neither API key is set" reads as "nothing
# to do this pass", and a pass that has nothing else to do never reports it.

mutation backlog-search-queue-gate-hides-the-key-check \
  --file scripts/backlog-search.sh \
  --bats tests/backlog-search.bats \
  --test "backlog-search: a deep outbox does not hide a missing API key" \
  --why "moves the gate back above the key checks, which is where it shipped. Both keys missing is a configuration error and the gate answers 'skipping this pass' with exit 0 instead, so the fault stays invisible for as long as the outbox stays deep -- and the outbox stays deep exactly when the stack is least healthy. Stremio's gate has always sat below its key guards; this one is the same shape now" \
  --apply 'python3 -c "import sys;p=sys.argv[1];L=open(p).read().split(chr(10));q=next(i for i,l in enumerate(L) if l.startswith(\"NZB_DIR=\"));qe=next(i for i in range(q,len(L)) if L[i].rstrip()==\"fi\");g=L[q:qe+1];R=L[:q]+L[qe+1:];k=next(i for i,l in enumerate(R) if l.startswith(\"if [[ -z \"));open(p,\"w\").write(chr(10).join(R[:k]+g+R[k:]))" "$F"'
