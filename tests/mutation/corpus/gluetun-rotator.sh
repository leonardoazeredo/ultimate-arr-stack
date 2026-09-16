# shellcheck shell=bash
# Corpus: scripts/gluetun-rotator.sh, the poll loop that cycles gluetun.
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
#
# Until 2026-09-16 this loop was an inline compose entrypoint, which is to say it
# had no oracle a mutation could be scored against at all -- and it is the file
# that decides whether the VPN is reconnected. tests/gluetun-rotator.bats is
# that oracle now, and the two entries below are the defects it was written for.
#
# `perl -pi -e`, not `sed -i`: an entry should replay on the Mac as well as on
# Linux, and BSD sed reads -i's next argument as a backup suffix. See
# tests/mutation/README.md.

# --- zero is accepted as an interval ----------------------------------------

mutation rotator-zero-interval-accepted \
  --file scripts/gluetun-rotator.sh \
  --bats tests/gluetun-rotator.bats \
  --test "^gluetun-rotator: 0, 00, empty and non-numeric intervals" \
  --why "with the zero arm gone, an interval of 0 or 00 is accepted and the poll always reaches its restart branch: gluetun is restarted every GLUETUN_ROTATE_CHECK_SECONDS, a reconnect loop with a VPN session inside it and an outage per cycle. The indexer guard refuses 0 for the same reason, and the fallback test is the only thing that says so here" \
  --apply 'perl -pi -e "s@^    \*\[!0\]\*\)\$@    *)@" "$F"'

# --- a restart whose timestamp could not be written is not remembered -------

mutation rotator-write-failure-not-remembered \
  --file scripts/gluetun-rotator.sh \
  --bats tests/gluetun-rotator.bats \
  --test "^gluetun-rotator: after a restart it could not record" \
  --why "remembered is the only thing between an unwritable shared directory and a restart on every poll: the write that records the restart fails, the file still holds the stale timestamp, and the next poll reads that same value and rotates again -- forever, one tunnel cycle per check interval. The test drives two polls and requires exactly one restart" \
  --apply 'perl -pi -e "s@^        remembered=\"\\$\{_now\}\"@        :@" "$F"'
