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
# Sourced, never executed. Two callers today:
#   scripts/stremio-library-sync.sh   (up to 3 requests every 10 minutes)
#   scripts/backlog-search.sh         (a 4-hourly slice of the missing backlog)
#
# Nothing here deletes or moves an NZB. The outbox is the arrs' own work queue
# and clearing it is not a producer's business.

# shellcheck shell=bash

QUEUE_HIGH_WATER="${QUEUE_HIGH_WATER:-50}"

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
  local dir="${1-}"
  [[ -n "$dir" && -d "$dir" ]] || { printf '0'; return 0; }
  find "$dir" -maxdepth 1 -type f -name '*.nzb' 2>/dev/null | wc -l | tr -d ' '
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
