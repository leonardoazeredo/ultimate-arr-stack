#!/bin/bash
set -euo pipefail
#
# Show what the usenet blackhole is doing, read-only.
#
# scripts/usenet-blackhole.sh submits, polls and fetches. A blackhole client
# reports no queue to the arr, so between the grab and the file appearing in the
# watch folder there is nothing to look at: the release is not in either arr's
# queue, not on any dashboard, and the state file it keeps is written for the
# watcher to resume from rather than for a person to read. Measured 2026-09-15:
# twelve jobs in flight, none of them in an arr queue.
#
# This renders that state file as an HTML page (the default) or as JSON, over
# the same data: release names, how far along each one is, how long since its
# progress last moved, which ones are stalled or complete, and the tail of the
# failure log. It reads and nothing else -- no TorBox call, no arr call, no API
# key, and .env is never opened -- so it is safe to run at any time, including
# while a pass is mid-fetch.
#
# Usage:
#   ./scripts/usenet-blackhole-status.sh                    # HTML on stdout
#   ./scripts/usenet-blackhole-status.sh --json             # the same as JSON
#   ./scripts/usenet-blackhole-status.sh --output /tmp/usenet.html
#   ./scripts/usenet-blackhole-status.sh --state /tmp/state.json --json
#   ./scripts/usenet-blackhole-status.sh --stall-hours 6    # match the watcher
#
# --json is for a script or a jq pipe. --html is one self-contained page with
# its own inline style, so it renders from a file:// URL on the NAS with nothing
# fetched from anywhere.
#
# --stall-hours (default 4) is the threshold behind the `stalled` badge, and it
# has to be the value the watcher is running with. The watcher takes the same
# flag (scripts/usenet-blackhole.sh --stall-hours N); leave this page on its
# default while that timer runs on 6 and a job stalled five hours reads
# "stalled" here while the watcher still considers it fine. Accepts the
# `--stall-hours N` and `--stall-hours=N` forms; a value that is not a number
# above zero is refused with exit 2 rather than passed to the module.
#
# The banner goes to stderr, not stdout, which is where this differs from its
# siblings: stdout is the document here, and a banner line in front of a JSON
# body is a JSON parse error.
#
# Prerequisites:
#   - python3, for scripts/lib/usenet_status.py
#
# ⚠️  Read-only by construction. There is no --apply, and nothing to apply.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAS_STACK_DIR="$(dirname "$SCRIPT_DIR")"

# The two files scripts/usenet-blackhole.sh writes. Same names, same directory,
# derived the same way -- the two halves of this stack have to be looking at one
# state file, and a second copy of the path is how they stop being.
STATE_PATH="$NAS_STACK_DIR/logs/usenet-blackhole-state.json"
FAILED_LOG="$NAS_STACK_DIR/logs/usenet-blackhole-failed.log"

# HTML by default: the JSON is the machine-readable half, and a person who runs
# this by hand without arguments is asking to see what is downloading.
FORMAT=html
OUTPUT=""
# The watcher's own default (scripts/usenet-blackhole.sh), so the page and a
# watcher run with no --stall-hours keep answering the same question.
STALL_HOURS=4
# Tracked separately from OUTPUT, because an empty OUTPUT is also the normal
# "write to stdout" state: `--output=` has to be an error, while no --output at
# all must not be.
OUTPUT_SET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --html) FORMAT=html ;;
    --json) FORMAT=json ;;
    --output)
      # No shift-without-value: `--output` as the last argument would otherwise
      # leave the empty string behind, which reaches the redirection below as
      # bash's "ambiguous redirect" rather than as an explanation.
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --output needs a file" >&2
        exit 2
      fi
      OUTPUT="$2"
      OUTPUT_SET=true
      shift
      ;;
    --output=*)
      OUTPUT="${1#*=}"
      OUTPUT_SET=true
      ;;
    --state)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --state needs a path" >&2
        exit 2
      fi
      STATE_PATH="$2"
      shift
      ;;
    --state=*) STATE_PATH="${1#*=}" ;;
    --failed-log)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --failed-log needs a path" >&2
        exit 2
      fi
      FAILED_LOG="$2"
      shift
      ;;
    --failed-log=*) FAILED_LOG="${1#*=}" ;;
    --stall-hours)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --stall-hours needs a number" >&2
        exit 2
      fi
      STALL_HOURS="$2"
      shift
      ;;
    --stall-hours=*) STALL_HOURS="${1#*=}" ;;
    --help|-h)
      # The header block at the top of this file, printed verbatim. A fixed
      # range rather than `sed -n '2,/^$/p'`, which BSD sed rejects -- the trap
      # every sibling here documents, learned on macOS. It has to stop ON the
      # last comment line: one line further and --help prints the SCRIPT_DIR
      # assignment below it, which is how this shipped in
      # scripts/usenet-blackhole.sh until a bats test started asserting on it.
      # Line 47 is the `#` under the read-only warning; the range moves
      # whenever a line is added to the header above. It was 3,38 until
      # --stall-hours went in.
      sed -n '3,47p' "$0" | sed 's/^# \{0,1\}//'
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
# forms, and each one fails somewhere unhelpful downstream: an empty --output is
# bash's "ambiguous redirect", and empty paths would be read by the module as
# "use the default", quietly showing a different file's contents than the one
# named.
if $OUTPUT_SET && [[ -z "$OUTPUT" ]]; then
  echo "ERROR: --output needs a file" >&2
  exit 2
fi
if [[ -z "$STATE_PATH" ]]; then
  echo "ERROR: --state needs a path" >&2
  exit 2
fi
if [[ -z "$FAILED_LOG" ]]; then
  echo "ERROR: --failed-log needs a path" >&2
  exit 2
fi

# The same two checks scripts/usenet-blackhole.sh applies to its own
# --stall-hours, copied rather than approximated: the page derives `stalled`
# from this number, and a value the watcher would have refused must not reach
# the view and quietly become the rule it disagrees by.
case "$STALL_HOURS" in
  ''|*[!0-9.]*|*.*.*)
    echo "ERROR: --stall-hours must be a number, got '$STALL_HOURS'" >&2
    exit 2
    ;;
esac

# Zero is numeric and gets past the pattern above, and it is the one value that
# turns the stall rule into "every job is stalled the moment its clock starts".
# Negatives -- the "-" is not in the allowed set above -- are already refused
# there. awk rather than a `case` for the float comparison, and not bc: bc is
# not installed everywhere this runs.
if ! awk -v hours="$STALL_HOURS" 'BEGIN { exit !(hours > 0) }'; then
  echo "ERROR: --stall-hours must be greater than 0, got '$STALL_HOURS'" >&2
  exit 2
fi

log() { echo "[usenet-blackhole-status] $1" >&2; }

# A separate check rather than letting exec fail: `python3: command not found`
# from exec is exit 127 with the shell's own wording, which reads as the view
# being broken rather than the host being short a package.
if ! command -v python3 >/dev/null 2>&1; then
  log "ERROR: python3 is not on PATH; ${SCRIPT_DIR}/lib/usenet_status.py needs it."
  exit 1
fi

# To stderr, so stdout stays exactly the document: this is piped into jq, or
# redirected into a file someone opens in a browser.
echo "" >&2
echo "========================================" >&2
echo "Usenet Blackhole Status — $(date '+%Y-%m-%d %H:%M:%S')" >&2
echo "Format: $FORMAT" >&2
echo "State:  $STATE_PATH" >&2
echo "Log:    $FAILED_LOG" >&2
echo "Stall:  no progress for ${STALL_HOURS}h" >&2
if [[ -n "$OUTPUT" ]]; then
  echo "Output: $OUTPUT" >&2
else
  echo "Output: stdout" >&2
fi
echo "========================================" >&2

# The three positional arguments the module takes, in its own order, plus the
# stall threshold as its own flag -- the module pulls that out of argv wherever
# it appears, so the positional order the module has always had is unchanged. No
# credential is among them and none is read: there is nothing here for
# /proc/<pid>/cmdline to expose, which is the one thing this script gets for
# free by being read-only.
#
# exec, so python3 replaces this shell and its exit status is the script's --
# `if ! python3 ...; then exit 1` would flatten "bad format" (2) and "crashed"
# (1) into the same answer for whatever is calling this.
if [[ -n "$OUTPUT" ]]; then
  exec python3 "${SCRIPT_DIR}/lib/usenet_status.py" \
    "$FORMAT" "$STATE_PATH" "$FAILED_LOG" \
    --stall-hours "$STALL_HOURS" > "$OUTPUT"
fi

exec python3 "${SCRIPT_DIR}/lib/usenet_status.py" \
  "$FORMAT" "$STATE_PATH" "$FAILED_LOG" \
  --stall-hours "$STALL_HOURS"
