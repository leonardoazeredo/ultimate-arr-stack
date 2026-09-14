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
  --file scripts/lib/backlog_search.py \
  --bats tests/backlog-search.bats \
  --test "^backlog-search: the script never shells out to an unbounded arr command" \
  --why "MissingEpisodeSearch searches the whole backlog in one command, cannot be cancelled once started, and had to be killed by restarting Sonarr on 2026-09-13. This entry proves the guard that keeps the unbounded command out of the script can actually fail" \
  --apply 'perl -pi -e "s/^        python3 /        python3 MissingEpisodeSearch /" "$F"'
