#!/bin/bash
set -euo pipefail
#
# Rotate the VPN exit IP when Prowlarr's indexers report a Cloudflare ban.
#
# scripts/lib/indexer_guard.py decides; this is the half that acts. It fetches
# Prowlarr's indexer-status and indexer documents, asks the module whether the
# failures in them are evidence of an IP-level block, and does nothing at all
# when the answer is no -- which is nearly always. That path makes no docker
# call, opens no container, and costs two curl requests and one python3 run.
#
# When the answer is yes, the reconnect goes through gluetun's own control API.
# Everything about how that API is reached was learned on 2026-09-15, and all
# three of these are the difference between a rotation and a log line claiming
# one:
#
#   - The API is NOT published on the NAS host. It listens on 127.0.0.1:8000
#     inside the container's own network namespace, so every call goes through
#     `docker exec gluetun wget ...`. A curl to localhost:8000 from the NAS is
#     connection-refused, which is how the first attempt "rotated" the VPN
#     without the tunnel noticing.
#   - The wget in that container is BusyBox's, and its PUT is written
#     --method=PUT --body-data='{"status":"stopped"}'. --post-data is accepted,
#     exits 0 and changes nothing: the tunnel keeps its old exit IP while the
#     log says it moved. It does not appear anywhere in this file.
#   - A failed or partial PUT can leave the VPN STOPPED, which takes every
#     download in the stack down with it. The two PUTs are therefore followed
#     by a real read of the status, and the script will not exit 0 while
#     gluetun does not report running.
#
# This guard is not the only thing that cycles the tunnel. gluetun-rotator
# (docker-compose.utilities.yml) restarts gluetun on its own six-hour schedule,
# so the two coordinate through logs/vpn-rotation/last-rotation: one
# epoch-seconds line that either actor writes after it rotates. This script
# reads it and passes it to the decision module, which holds when the rotator
# is about to fire anyway or when a rotation just happened; after a rotation of
# its own the script writes it, so the rotator's interval starts from that
# moment instead of minutes earlier.
#
# Usage:
#   ./scripts/indexer-guard.sh                     # decide, rotate if warranted
#   ./scripts/indexer-guard.sh --dry-run           # decide and log, touch nothing
#   ./scripts/indexer-guard.sh --cooldown-hours 12 # a longer minimum gap
#   ./scripts/indexer-guard.sh --state /tmp/indexer-guard-state.json
#
# --dry-run stops after the decision: no PUT is sent, no container is restarted
# and neither the state file nor the shared rotation timestamp is written. It
# is how to watch the guard decide before a timer is allowed to act on it.
#
# --cooldown-hours is the minimum time between two rotations and defaults to
# the module's own six hours. A banned IP stays banned, so two reconnects
# inside one VPN session cannot produce an IP Cloudflare likes better -- and
# each one costs an outage.
#
# --state defaults to logs/indexer-guard-state.json under the repo root. It is
# written through the module's own save_state/record_rotation as soon as the
# tunnel has been cycled -- before the IP check and the Prowlarr restart -- so
# a pass that fails after that still leaves the cooldown in place.
#
# Prerequisites:
#   - PROWLARR_API_KEY in .env
#   - python3, curl and docker on PATH
#   - the gluetun and prowlarr containers running
#
# Exit status is 0 for a hold, for a dry run, and for a completed rotation. It
# is 1 when the tunnel cannot be left running, when the stop request failed, or
# when Prowlarr could not be restarted -- each of which the systemd unit should
# record as a failure. Bad argv is 2.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAS_STACK_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$NAS_STACK_DIR/.env"
GUARD_MODULE="$SCRIPT_DIR/lib/indexer_guard.py"

# Prowlarr's published port on the NAS, and gluetun's control API at its
# in-container address. The second one is never reachable from this shell
# directly; see the header.
PROWLARR_URL="http://localhost:9696"
GLUETUN_API="http://127.0.0.1:8000/v1"
GLUETUN_CONTAINER="gluetun"

# Prowlarr is defined in this compose file and must be restarted through it.
# Never with --remove-orphans: this stack splits its services across several
# compose files sharing one project name, so compose reads every container
# from the other files as an orphan and deletes them. That took out 11
# containers on 2026-08-01.
COMPOSE_FILE="docker-compose.arr-stack.yml"
PROWLARR_SERVICE="prowlarr"

# logs/indexer-guard-state.json under the repo root, which is the module's own
# DEFAULT_STATE_PATH -- but absolute, because a timer has no meaningful working
# directory and the module would resolve a relative one against whatever it got.
STATE_PATH="$NAS_STACK_DIR/logs/indexer-guard-state.json"

# The one file this guard and gluetun-rotator both write: a single epoch-seconds
# line naming the most recent rotation by either actor. Only that subdirectory
# is mounted into the rotator, and the guard writes it as the deploy user, so
# the directory has to be one this user can create and write.
ROTATOR_FILE="$NAS_STACK_DIR/logs/vpn-rotation/last-rotation"

DRY_RUN=false
# Empty means "not given": the module's default applies, and there is nothing
# for this script to validate or pass through.
COOLDOWN_HOURS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --cooldown-hours)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --cooldown-hours needs a number" >&2
        exit 2
      fi
      COOLDOWN_HOURS="$2"
      shift
      ;;
    --cooldown-hours=*) COOLDOWN_HOURS="${1#*=}" ;;
    --state)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --state needs a path" >&2
        exit 2
      fi
      STATE_PATH="$2"
      shift
      ;;
    --state=*) STATE_PATH="${1#*=}" ;;
    --help|-h)
      # The header block at the top of this file, printed verbatim: the first
      # run of comment lines after the shebang, up to the first line that is
      # not a comment. An awk range rather than a line range, because a fixed
      # `sed -n '3,69p'` silently drops the tail of the help the moment anyone
      # adds a line to the header -- and it has to stop ON the last comment
      # line, or --help prints the SCRIPT_DIR assignment below it as if it were
      # documentation. `sed -n '2,/^$/p'` is not the answer either: BSD sed
      # rejects a range whose end is a regex combined with a start line.
      awk 'NR == 1 { next } /^#/ { started = 1; sub(/^# ?/, ""); print; next }
           started { exit }' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unrecognised argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# An empty value gets past the `$# -lt 2` guards above and past the `--flag=`
# forms, and would read to the module as "use my default" -- quietly consulting
# a different file than the one the operator named.
if [[ -z "$STATE_PATH" ]]; then
  echo "ERROR: --state needs a path" >&2
  exit 2
fi

# The same two checks scripts/usenet-blackhole.sh applies to its own numeric
# flags: a value that is not a number, and the one number that must not be
# accepted. Zero would turn the cooldown into "rotate on every pass that has a
# failed indexer in it", which is a reconnect loop with a VPN session in it.
# The module refuses it too; catching it here means the operator reads this
# script's message rather than argparse's.
if [[ -n "$COOLDOWN_HOURS" ]]; then
  case "$COOLDOWN_HOURS" in
    ''|*[!0-9.]*|*.*.*)
      echo "ERROR: --cooldown-hours must be a number, got '$COOLDOWN_HOURS'" >&2
      exit 2
      ;;
  esac
  # awk rather than a `case` for the float comparison, and not bc: bc is not
  # installed everywhere this runs.
  if ! awk -v hours="$COOLDOWN_HOURS" 'BEGIN { exit !(hours > 0) }'; then
    echo "ERROR: --cooldown-hours must be greater than 0, got '$COOLDOWN_HOURS'" >&2
    exit 2
  fi
fi

log() { echo "[indexer-guard] $1"; }
err() { echo "[indexer-guard] ERROR: $1" >&2; }

# A separate check rather than letting the first python3 call fail: `python3:
# command not found` is exit 127 with the shell's own wording, which reads as
# the guard being broken rather than the host being short a package.
if ! command -v python3 >/dev/null 2>&1; then
  err "python3 is not on PATH; ${GUARD_MODULE} needs it."
  exit 1
fi

# Both documents, and the trap that removes them. One directory rather than two
# mktemp files: there is one thing to clean up, and nothing is left behind if
# the second mktemp would have failed.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/indexer-guard.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
STATUS_FILE="$WORK_DIR/indexerstatus.json"
INDEXER_FILE="$WORK_DIR/indexer.json"

# shellcheck source=scripts/lib/env-file.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/env-file.sh"

# No credential ever reaches a command line here: env_value prints the value
# into a variable, and prowlarr_get hands it to curl on stdin.
PROWLARR_KEY="$(env_value "$ENV_FILE" PROWLARR_API_KEY || true)"
if [[ -z "$PROWLARR_KEY" ]]; then
  err "PROWLARR_API_KEY is not set in $ENV_FILE."
  exit 1
fi

# rotator_last_value: the shared rotation timestamp, if it is one at all.
#
# The file holds one epoch-seconds integer and either actor may have written
# it. Missing, empty, unreadable, or anything that is not a run of digits means
# there is no known rotation, and then this script passes nothing on: that is
# the state of a stack whose rotator has not written the file yet, and the
# module is the one place that decides what "no known rotation" means.
rotator_last_value() {
  local text
  [[ -f "$ROTATOR_FILE" ]] || return 1
  text="$(cat "$ROTATOR_FILE" 2>/dev/null)" || return 1
  text="${text//[[:space:]]/}"
  case "$text" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$text"
}

# The rotator's two numbers: when either actor last rotated, and how long the
# rotator's own interval is. Both go to the module together -- one without the
# other cannot say when the next restart is due.
ROTATOR_LAST="$(rotator_last_value || true)"
ROTATOR_INTERVAL="$(env_value "$ENV_FILE" GLUETUN_ROTATE_INTERVAL_SECONDS || true)"

# A value the module would refuse is treated as absent rather than passed on:
# the module's own default (six hours, the compose file's default too) applies,
# and a pass is not stopped over a typo in .env. Zero is in this set because
# "rotate every pass" is the one interval that must never take effect quietly,
# and it is every spelling of zero rather than the literal `0`: `00` used to
# fall through an exact `0)` arm to argparse, whose refusal stopped the whole
# pass.
case "$ROTATOR_INTERVAL" in
  ''|*[!0-9]*)
    if [[ -n "$ROTATOR_INTERVAL" ]]; then
      err "GLUETUN_ROTATE_INTERVAL_SECONDS='$ROTATOR_INTERVAL' in $ENV_FILE is not a whole number of seconds; using the module's default."
    fi
    ROTATOR_INTERVAL=""
    ;;
  # A non-zero digit somewhere makes it a real interval, so 0100 stays out of
  # the zero arm below. The value reaching this point is all digits: the arm
  # above took everything else.
  *[!0]*) ;;
  *)
    err "GLUETUN_ROTATE_INTERVAL_SECONDS='$ROTATOR_INTERVAL' in $ENV_FILE is not an interval; using the module's default."
    ROTATOR_INTERVAL=""
    ;;
esac

# curl_quote <value>: a value escaped for a curl config file.
#
# curl reads a double-quoted config value literally, so a backslash or a quote
# inside one has to be backslashed or it ends the string early. Same function
# as queue_cleanup.py's, for the same reason.
curl_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

# prowlarr_get <path> <output-file>: fetch one API document to a file.
#
# The key travels as an `X-Api-Key` header read by curl out of a config file on
# stdin, not as `-H "X-Api-Key: $KEY"` -- that would put it in curl's argv,
# world-readable through /proc/<pid>/cmdline, which is the fix queue_cleanup.py
# and backlog_search.py both carry.
prowlarr_get() {
  local path="$1" out="$2"
  printf 'url = "%s"\nheader = "X-Api-Key: %s"\n' \
    "$(curl_quote "$PROWLARR_URL$path")" "$(curl_quote "$PROWLARR_KEY")" \
    | curl -sS --fail --max-time 30 --config - -o "$out"
}

if ! prowlarr_get /api/v1/indexerstatus "$STATUS_FILE"; then
  err "could not fetch /api/v1/indexerstatus from Prowlarr at $PROWLARR_URL."
  exit 1
fi
if ! prowlarr_get /api/v1/indexer "$INDEXER_FILE"; then
  err "could not fetch /api/v1/indexer from Prowlarr at $PROWLARR_URL."
  exit 1
fi

# The module's arguments, with a flag appended only when there is a value for
# it: --cooldown-hours when the operator gave one, and the two rotator numbers
# when the shared file and .env between them have usable ones.
# ${ARRAY[@]+"${ARRAY[@]}"} rather than a bare expansion: with `set -u` an
# empty array is an unbound variable in bash before 4.4, and /bin/bash on
# macOS is 3.2.
MODULE_ARGS=()
if [[ -n "$COOLDOWN_HOURS" ]]; then
  MODULE_ARGS+=(--cooldown-hours "$COOLDOWN_HOURS")
fi
if [[ -n "$ROTATOR_LAST" ]]; then
  MODULE_ARGS+=(--rotator-last "$ROTATOR_LAST")
fi
if [[ -n "$ROTATOR_INTERVAL" ]]; then
  MODULE_ARGS+=(--rotator-interval "$ROTATOR_INTERVAL")
fi

# The decision module reads both documents, consults the state file and prints
# its answer. Its exit status is 0 for any decision it reached, `rotate`
# included; a non-zero one means it could not read its own input, which is a
# bug here rather than a verdict.
DECISION_JSON=""
if ! DECISION_JSON="$(python3 "$GUARD_MODULE" \
      --statuses "$STATUS_FILE" \
      --indexers "$INDEXER_FILE" \
      --state "$STATE_PATH" \
      ${MODULE_ARGS[@]+"${MODULE_ARGS[@]}"} \
      --json)"; then
  err "the decision module exited non-zero; nothing was rotated."
  exit 1
fi

# The verdict and its reason, out of the JSON the module just printed. The
# module's own --verdict mode does that reading, so the validation that used to
# be an untested heredoc here sits inside the pytest oracle instead. A parse
# failure stops the pass rather than being read as "hold": a guard that quietly
# holds when it cannot read its own decision is a guard that has stopped
# working, and nothing would say so.
if ! VERDICT="$(printf '%s' "$DECISION_JSON" \
      | python3 "$GUARD_MODULE" --verdict -)"; then
  err "could not read the decision module's output as a decision."
  exit 1
fi

ROTATE="${VERDICT%%$'\t'*}"
REASON="${VERDICT#*$'\t'}"

case "$ROTATE" in
  hold)
    # The normal case, and it stays one line. Nothing below this point has run:
    # no docker call has been made, and on this path none ever is.
    log "hold: $REASON"
    exit 0
    ;;
  rotate) ;;
  *)
    err "the decision module returned an unrecognised verdict: $ROTATE"
    exit 1
    ;;
esac

log "rotate: $REASON"

if $DRY_RUN; then
  log "dry run: stopping before the rotation; no VPN call and no container was touched"
  exit 0
fi

# --- the rotation -----------------------------------------------------------
#
# From here on, everything gluetun is asked to do goes through `docker exec`,
# because the control API listens inside the container's network namespace and
# is not published on the NAS host.

if ! command -v docker >/dev/null 2>&1; then
  err "docker is not on PATH; the rotation cannot be performed."
  exit 1
fi

gluetun_get() {
  docker exec "$GLUETUN_CONTAINER" wget -q -O - "$GLUETUN_API$1"
}

# The PUT that changes the tunnel state. --body-data, never --post-data: the
# BusyBox wget in the container accepts the latter, exits 0 and sends nothing,
# which is how a rotation reports success while the exit IP stays put.
gluetun_put_status() {
  docker exec "$GLUETUN_CONTAINER" wget -q -O - \
    --method=PUT --body-data="{\"status\":\"$1\"}" "$GLUETUN_API/vpn/status"
}

# Whether the control API reports the tunnel running. Whitespace is stripped
# first because the endpoint's formatting is not ours to depend on, and the
# word only appears there as the status value.
vpn_is_running() {
  local body
  body="$(gluetun_get /vpn/status)" || return 1
  body="${body//[[:space:]]/}"
  [[ "$body" == *'"running"'* ]]
}

# The exit IP as the control API reports it, or "unknown". Parsed by python3
# because the endpoint answers in JSON and the field order is the server's
# business; a shell pattern would read the whole document as the IP the day
# that order changes. Never fails: the address is evidence in the log, and a
# pass that cannot read it must still get on with the rotation.
gluetun_public_ip() {
  local body ip
  if body="$(gluetun_get /publicip/ip)"; then
    ip="$(printf '%s' "$body" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except ValueError:
    data = None
# The real key is "public_ip" -- verified live against /v1/publicip/ip on
# 2026-09-15, whose object is public_ip, region, country, city, location,
# organization, postal_code, timezone. "ip" is kept only as a fallback for a
# build that spells it differently; reading "ip" alone made every IP_BEFORE
# and IP_AFTER "unknown", which is the evidence a rotation changed anything.
if isinstance(data, dict):
    print(data.get("public_ip") or data.get("ip") or "unknown")
else:
    print("unknown")
')" || ip=""
  fi
  printf '%s' "${ip:-unknown}"
}

# record_rotation: write the rotation into the state file, through the module.
#
# The shape of that file is the module's business -- load_state,
# record_rotation and save_state all live there, and a wrapper hand-writing
# JSON would be a second definition of the format that could disagree with the
# reader. The module's --record-rotation mode is that write; it prints the new
# rotation count.
record_rotation() {
  python3 "$GUARD_MODULE" --state "$STATE_PATH" --record-rotation
}

# record_rotator_rotation: write this rotation into the file the rotator reads.
#
# The same epoch seconds the rotator writes, written the same way: a temporary
# file in the same directory, then a rename over the target, so the rotator's
# poll can never read half a number. The directory is created first, because a
# missing one leaves the write nowhere to land.
#
# A failure here is logged and nothing else -- deliberately not part of
# $FAILED. This is coordination, not the cooldown (that is the state file,
# recorded just above), and its worst case is the rotator starting a fresh
# interval from an absent timestamp: one redundant cycle six hours from now,
# not a rotation that did not happen. The pass must not fail over it.
record_rotator_rotation() {
  local dir now tmp
  dir="$(dirname "$ROTATOR_FILE")"
  now="$(date +%s)"
  if ! mkdir -p "$dir"; then
    err "could not create $dir; the rotator's interval will not restart from this rotation."
    return 0
  fi
  tmp="$ROTATOR_FILE.$$"
  if printf '%s\n' "$now" > "$tmp" && mv "$tmp" "$ROTATOR_FILE"; then
    log "recorded the rotation in $ROTATOR_FILE"
  else
    rm -f "$tmp"
    err "could not write $ROTATOR_FILE; the rotator's interval will not restart from this rotation."
  fi
  return 0
}

FAILED=false
STOPPED=false

IP_BEFORE="$(gluetun_public_ip)"
log "exit IP before: $IP_BEFORE"

if gluetun_put_status stopped >/dev/null; then
  STOPPED=true
  log "asked gluetun to stop the tunnel"
else
  FAILED=true
  err "the PUT that stops the tunnel failed; the VPN was not rotated."
fi

# Sent whether or not the stop landed. If the stop did happen, this is what
# brings the tunnel back; if it did not, it costs one call and leaves the VPN
# in the state it should be in anyway.
if gluetun_put_status running >/dev/null; then
  log "asked gluetun to start the tunnel"
else
  FAILED=true
  err "the PUT that starts the tunnel failed."
fi

# Recorded HERE, right after the stop/start pair has been issued, and before
# the IP check and the Prowlarr restart below. The cooldown has to be
# fail-safe: once the VPN has been cycled it has been cycled, and if this
# process is killed or anything below fails from here on, a rotation with no
# record means the timer fires again and rotates again -- exactly the loop the
# cooldown exists to prevent. Do not tidy this back to the end of the pass.
#
# Only when the tunnel actually went down: recording a rotation that did not
# happen would hold the module's cooldown over an IP that is still banned.
if $STOPPED; then
  if RECORDED="$(record_rotation)"; then
    log "recorded the rotation in $STATE_PATH (rotation #$RECORDED)"
  else
    FAILED=true
    err "could not record the rotation in $STATE_PATH; the cooldown will not cover the next pass."
  fi
  # The rotator's half of the same record, on the same condition and at the
  # same point in the pass: the timestamp has to be there before anything
  # below can fail, or the rotator's interval restarts from a moment that is
  # already hours old.
  record_rotator_rotation
fi

# The verification the incident asked for, and the reason it is a read rather
# than trust in the two exit statuses above: a PUT that silently did nothing is
# exactly how the VPN was left stopped. One re-issue, one re-check, and then a
# hard failure the unit records.
if ! vpn_is_running; then
  err "gluetun does not report the VPN as running; re-issuing the start request."
  if ! gluetun_put_status running >/dev/null; then
    err "the second start request failed too."
  fi
  if ! vpn_is_running; then
    err "FATAL: gluetun still does not report the VPN as running. Downloads through the tunnel are down until it does."
    err "Check the container: docker logs ${GLUETUN_CONTAINER} --tail 50"
    exit 1
  fi
fi
log "gluetun reports the VPN running"

IP_AFTER="$(gluetun_public_ip)"
log "exit IP after: $IP_AFTER"
if [[ "$IP_BEFORE" == "$IP_AFTER" ]]; then
  # Not an error: the guard rotated, and the provider handed back the same
  # address. It is worth its own line because it is the one log line that says
  # the rotation bought nothing.
  log "the exit IP did not change"
else
  log "the exit IP changed: $IP_BEFORE -> $IP_AFTER"
fi

# Prowlarr latches a failed indexer into a backoff that can run for 24 hours,
# and the arrs will not search through that indexer until it expires. The
# backoff was earned against the IP that was banned, so it is cleared here, now
# that the IP has moved. Restarting the container is what clears it: observed
# on 2026-09-15 on this stack, where a latched 24-hour backoff on the 1337x
# indexer was gone after a prowlarr restart. Through the compose file that
# defines the service, from the stack root, and never with --remove-orphans --
# see the note beside COMPOSE_FILE above.
if (cd "$NAS_STACK_DIR" && docker compose -f "$COMPOSE_FILE" restart "$PROWLARR_SERVICE"); then
  log "restarted ${PROWLARR_SERVICE} to clear its latched indexer backoff"
else
  FAILED=true
  err "restarting ${PROWLARR_SERVICE} failed; it may sit out its backoff against the old IP."
fi

if $FAILED; then
  err "the rotation did not complete cleanly; exiting non-zero so the unit records it."
  exit 1
fi

log "rotation complete"
exit 0
