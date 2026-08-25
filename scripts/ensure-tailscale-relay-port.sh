#!/bin/bash
set -euo pipefail
#
# Re-applies `tailscale set --relay-server-port=41641` on node 1 whenever it's
# missing. That setting (Tailscale 1.86+ peer-relay support) lives purely in
# tailscaled's in-memory prefs - confirmed live 2026-08-25 via
# `grep -c RelayServerPort /var/lib/tailscale/tailscaled.state` returning `0`
# both before and after re-applying it - so it does not survive ANY node-1
# restart or recreate, not just a `--reset`-triggered one (see
# docs/EXIT-NODE-PROJECT-LOG.md #91). It is not a `tailscale up` flag, so
# nothing in TS_EXTRA_ARGS ever re-asserts it.
#
# Idempotent apply, not a detect/alert split like detect-credential-drift.sh's:
# the correct value is always known and always safe to just re-apply, so
# there's nothing here that needs a human to unlock a vault or make a call.
#
# Runs entirely on the NAS itself via `docker exec` - no docker socket mount
# needed anywhere, matches detect-credential-drift.sh's own approach.
#
# Usage:
#   ./scripts/ensure-tailscale-relay-port.sh
#
# Exit codes:
#   0 = already correct, or successfully re-applied (or the tailscale
#       container isn't running yet - not a failure, the timer retries)
#   1 = tailscale container is running but `tailscale set` failed
#
# Run on a schedule via the systemd timer alongside this script
# (ensure-tailscale-relay-port.timer). Installed as a --user unit, same as
# detect-credential-drift.timer (no root needed - ~/.config/systemd/user/ is
# writable by its own user; loginctl enable-linger is already on for this NAS
# user from that setup, so no extra step is needed here):
#   systemctl --user daemon-reload
#   systemctl --user enable --now ensure-tailscale-relay-port.timer

RELAY_PORT=41641

if ! docker inspect -f '{{.State.Running}}' tailscale 2>/dev/null | grep -q true; then
  echo "ensure-tailscale-relay-port: tailscale container not running, skipping (timer will retry)"
  exit 0
fi

# Extract the value rather than matching a hardcoded-comma string, so this
# doesn't silently stop detecting a correct value if `tailscale debug prefs`'s
# JSON formatting ever changes (e.g. no trailing comma, extra whitespace).
actual_port=$(docker exec tailscale tailscale debug prefs 2>/dev/null \
  | grep -o '"RelayServerPort":[[:space:]]*[0-9]*' \
  | grep -o '[0-9]*$' || true)

if [[ "$actual_port" == "$RELAY_PORT" ]]; then
  echo "ensure-tailscale-relay-port: OK - RelayServerPort already $RELAY_PORT"
  exit 0
fi

echo "ensure-tailscale-relay-port: RelayServerPort missing or wrong - re-applying $RELAY_PORT"
if docker exec tailscale tailscale set "--relay-server-port=$RELAY_PORT"; then
  echo "ensure-tailscale-relay-port: re-applied successfully"
  exit 0
else
  echo "ensure-tailscale-relay-port: FAILED to re-apply" >&2
  exit 1
fi
