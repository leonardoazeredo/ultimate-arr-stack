#!/bin/sh
# gluetun-rotator: restart gluetun on a fixed interval so it re-picks a
# WireGuard exit server from VPN_COUNTRIES, instead of staying pinned to
# whatever server it first connected to. A plain `docker restart` (same
# container ID, not a recreate), so gluetun-recover's existing health_status
# watcher revives every "service:gluetun" dependent afterwards.
#
# The schedule is shared with scripts/indexer-guard.sh, which rotates the same
# tunnel when Prowlarr reports a banned exit IP. Both actors write the moment of
# a rotation into logs/vpn-rotation/last-rotation -- one epoch-seconds line, and
# only that subdirectory is mounted into this container -- and this loop
# restarts gluetun once GLUETUN_ROTATE_INTERVAL_SECONDS have passed since it. A
# guard rotation therefore restarts this interval instead of being followed
# minutes later by a second tunnel cycle. A missing or unreadable file starts
# the interval rather than rotating on the spot, which keeps the first restart a
# full interval after the container starts.
#
# Runs as ${PUID}:${PGID} because the shared file lives in a bind-mounted
# directory owned by the deploy user, and `cap_drop: ALL` leaves even this
# container's root without CAP_DAC_OVERRIDE, so root could not write it.
# Create the directory as that user before starting the service
# (mkdir -p logs/vpn-rotation): docker creates a missing bind-mount source as
# root, and the write would then fail for everyone. Reaching the Docker API
# needs no privilege either way -- DOCKER_HOST is TCP through
# docker-socket-proxy, not a unix socket owned by root -- so the docker CLI
# works as an ordinary uid.
#
# ROTATOR_SHARED_FILE overrides the shared path, and ROTATOR_SOURCE_ONLY=1
# keeps the file from starting the loop at all. Both exist for
# tests/gluetun-rotator.bats, which sources this file and drives one poll at a
# time.

SHARED_FILE="${ROTATOR_SHARED_FILE:-/vpn-rotation/last-rotation}"

# The compose file sets both of these from .env; these are the same defaults it
# uses, for the case where the service is started without them.
INTERVAL_DEFAULT=21600
CHECK_DEFAULT=300

log() { echo "gluetun-rotator: $1"; }
err() { echo "gluetun-rotator: $1" >&2; }

# validate_seconds <name> <value> <fallback>: sets $VALIDATED to <value> when it
# is a whole number of seconds above zero, and to <fallback> with a log line
# when it is not.
#
# A value that is not a whole number of seconds is refused here rather than
# reaching sleep or the arithmetic in rotator_poll: `sleep abc` fails instantly,
# which would turn this poll loop into a busy loop against the Docker API.
# Zero is refused in every spelling -- 0, 00, 000 -- for the same reason the
# indexer guard refuses it: an interval of zero reconnects the tunnel on every
# poll, and a check of zero spins.
validate_seconds() {
  case "$2" in
    ''|*[!0-9]*)
      log "$1='$2' is not a whole number of seconds; using $3"
      VALIDATED="$3"
      return 0
      ;;
  esac
  case "$2" in
    *[!0]*)
      VALIDATED="$2"
      return 0
      ;;
  esac
  log "$1=$2 is not above zero; using $3"
  VALIDATED="$3"
}

# resolve_config: $INTERVAL and $CHECK, each validated once at startup.
resolve_config() {
  validate_seconds GLUETUN_ROTATE_INTERVAL_SECONDS \
    "${GLUETUN_ROTATE_INTERVAL_SECONDS:-}" "$INTERVAL_DEFAULT"
  INTERVAL="$VALIDATED"
  validate_seconds GLUETUN_ROTATE_CHECK_SECONDS \
    "${GLUETUN_ROTATE_CHECK_SECONDS:-}" "$CHECK_DEFAULT"
  CHECK="$VALIDATED"
}

# Atomic: a temporary file beside the target, then a rename over it, so a
# reader never sees a half-written timestamp.
write_last_rotation() {
  _tmp="${SHARED_FILE}.$$"
  if printf '%s\n' "$1" > "${_tmp}" && mv "${_tmp}" "${SHARED_FILE}"; then
    return 0
  fi
  rm -f "${_tmp}"
  return 1
}

# check_shared_dir: whether the shared file's directory can be written at all.
#
# A probe write rather than `test -w`, which answers for the directory's mode
# and not for the user this runs as. Runs once, before the loop, and never
# stops it: an unwritable directory is a coordination failure -- the indexer
# guard cannot see this loop's rotations, so it will not hold off its own --
# and the loop has to keep rotating on its in-memory interval regardless.
check_shared_dir() {
  _dir="$(dirname "$SHARED_FILE")"
  _probe="${_dir}/.gluetun-rotator-probe.$$"
  if printf '%s\n' "$$" > "${_probe}" 2>/dev/null && rm -f "${_probe}" 2>/dev/null; then
    return 0
  fi
  rm -f "${_probe}" 2>/dev/null
  err "ERROR: the shared rotation directory ${_dir} is NOT WRITABLE."
  err "scripts/indexer-guard.sh cannot see rotations this loop makes and will not hold off its own, and the rotation interval is tracked in memory only: every restart of this container begins a new interval."
  return 1
}

# The newest timestamp this loop knows of, for the polls where the file is
# missing or stale because a write failed: without it an unwritable directory
# would mean a restart on every poll, or no restart at all.
remembered=""

# rotator_poll [now]: one poll.
#
# `now` defaults to the real clock and exists as an argument so a test can drive
# the interval without waiting for it.
rotator_poll() {
  _now="${1:-$(date +%s)}"
  _last=""
  if [ -r "${SHARED_FILE}" ]; then
    _last="$(tr -d '[:space:]' < "${SHARED_FILE}" 2>/dev/null)" || _last=""
  fi
  case "${_last}" in
    ''|*[!0-9]*) _last="" ;;
  esac
  # A write that failed earlier leaves the file missing or stale. The value
  # this loop already decided on wins, so a directory it cannot write stays a
  # coordination problem and never becomes a rotation that does not happen at
  # all.
  if [ -n "${remembered}" ] && { [ -z "${_last}" ] || [ "${remembered}" -gt "${_last}" ]; }; then
    _last="${remembered}"
  fi

  if [ -z "${_last}" ]; then
    # No known rotation: start the interval now and leave the tunnel alone.
    # Restarting here instead would be a restart on every boot.
    log "no usable timestamp in ${SHARED_FILE}; starting the interval now"
    if write_last_rotation "${_now}"; then
      remembered=""
    else
      remembered="${_now}"
      err "FAILED to write ${SHARED_FILE}; the interval continues in memory"
    fi
  elif [ $((_now - _last)) -ge "${INTERVAL}" ]; then
    log "restarting gluetun (interval=${INTERVAL}s, last rotation ${_last}) to rotate exit server"
    # Written only when the restart succeeded: a failed one rotated nothing,
    # and recording it would hide the failure for a whole interval instead of
    # letting the next poll retry.
    if docker restart gluetun; then
      if write_last_rotation "${_now}"; then
        remembered=""
      else
        remembered="${_now}"
        err "FAILED to write ${SHARED_FILE}; the interval continues in memory"
      fi
    else
      err "FAILED to restart gluetun"
    fi
  fi
}

# main: validate the two settings, say so once if the shared directory cannot be
# written, then poll forever.
main() {
  resolve_config
  check_shared_dir
  while true; do
    rotator_poll
    sleep "${CHECK}"
  done
}

if [ "${ROTATOR_SOURCE_ONLY:-0}" != "1" ]; then
  main
fi
