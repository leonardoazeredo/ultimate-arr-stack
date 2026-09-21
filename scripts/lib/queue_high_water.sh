#!/bin/bash
# A high-water mark on the arrs' usenet outbox.
#
# The outbox is a filesystem handshake: the arr writes an .nzb into its
# nzbFolder when it grabs a release, and scripts/usenet-blackhole.sh moves the
# finished download into the watchFolder the arr polls. Nothing paces the
# writing side, and the reading side has a measured ceiling -- about 24
# releases an hour at FETCH_WORKERS=3 -- so a producer that offers 72 an hour
# builds a queue that can only be discharged by a burst.
#
# Measured 2026-09-20: the outbox went 488 -> 572 -> 588 across one day, in a
# stretch where the pressure gate was refusing passes. Every NZB in it becomes
# local I/O the moment the gate opens, and each release costs a large multiple
# of its delivered size in platter writes -- a 33.19 GB payload writing,
# extracting and unpacking to deliver a few GB.
#
# Sourced, never executed. Three callers today:
#   scripts/stremio-library-sync.sh   (up to 3 requests every 10 minutes)
#   scripts/backlog-search.sh         (a 4-hourly slice of the missing backlog)
#   scripts/usenet-blackhole.sh       (the drain, which must read the same path)
#
# Nothing here deletes or moves an NZB. The outbox is the arrs' own work queue
# and clearing it is not a producer's business.

# shellcheck shell=bash

QUEUE_HIGH_WATER="${QUEUE_HIGH_WATER:-50}"

# Host path MEDIA_ROOT resolves to, with the default the callers used to each
# spell out for themselves.
media_root() {
  local value
  value="$(env_value "${ENV_FILE-}" MEDIA_ROOT || true)"
  printf '%s' "${value:-$NAS_STACK_DIR/data}"
}

# The arrs' nzbFolder on the host: where a grabbed release becomes an NZB.
#
# One function because three scripts resolved this path and a fourth spelling
# would drift from them. A producer that paces itself against a directory the
# watcher never reads stands down over a queue that does not exist, and the pass
# it stands down is the one that would have drained the real one.
outbox_dir() {
  printf '%s' "${USENET_NZB_DIR:-$(media_root)/usenet/blackhole/nzb}"
}

# Number of .nzb files directly in the outbox, or 0 when there is no such
# directory.
#
# `-maxdepth 1` and `-type f` on purpose. The arr writes flat files into this
# folder, and the alternative -- walking a 3.3 TB pool to answer "how deep is
# the queue" -- is the same shape of read this guard exists to prevent. A
# missing directory is 0 and not an error: a stack that has never run has no
# outbox, and a producer that refuses to start because of it has invented a
# new failure.
outbox_depth() {
  local dir="${1-}" count
  # No separate test for an empty argument: `-d ''` is false, so the one check
  # covers both "no directory configured" and "it is not there".
  [[ -d "$dir" ]] || { printf '0'; return; }
  # `|| true` semantics without the bare assignment. Both callers run under
  # `set -euo pipefail` and assign this straight into a command substitution, so
  # a `find` that exits 1 on a directory it cannot read -- existing but not
  # searchable -- would kill a producer timer. But an unreadable directory must
  # not read as an empty queue either: "the outbox is empty" and "the outbox
  # cannot be read" are different facts, and only one of them means the guard
  # has nothing to do. Both producer units redirect 2>&1 into their logs, so the
  # note lands beside the "Outbox: N NZBs waiting" line it contradicts.
  if ! count="$(find "$dir" -maxdepth 1 -type f -name '*.nzb' 2>/dev/null | wc -l | tr -d ' ')"; then
    echo "queue-high-water: cannot read $dir; treating the outbox as empty" >&2
    printf '0'
    return
  fi
  printf '%s' "$count"
}

# 0 (true) when a producer should stand down for this pass.
#
# One threshold, no hysteresis, and that is deliberate. A two-sided check --
# stand down above the mark, resume below a lower one -- needs somewhere to
# remember which side it is on, and a timer-driven script has nowhere durable
# to keep that: every pass starts from nothing, so the lower mark could never
# fire. One threshold bounded by the mark is the whole mechanism, and it is
# honest about what is enforced.
outbox_over_high_water() {
  local depth
  depth="$(outbox_depth "${1-}")"
  [[ "$depth" -ge "$QUEUE_HIGH_WATER" ]]
}
