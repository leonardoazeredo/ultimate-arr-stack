#!/bin/bash
set -euo pipefail
#
# Detects the credential-propagation bug class that silently broke Seerr on
# 2026-08-17: Sonarr/Radarr's own API key rotated (via the declarative
# SONARR__AUTH__APIKEY/RADARR__AUTH__APIKEY env vars), but Seerr, Bazarr,
# and Prowlarr each keep their own cached copy of that key as a client
# credential and were never told it changed - so they started 401ing on
# every background poll, with nothing surfacing it beyond a UI warning
# nobody was looking at.
#
# Needs no API keys or Bitwarden access of its own - it only reads
# container logs each app already writes when its own auth to a peer
# fails. Deliberately doesn't call any app's REST API: that would need a
# key of its own to store on the NAS, which is the exact tradeoff this
# script exists to avoid (see docs/TAILSCALE.md-adjacent research, 2026-08-17
# - a scheduled *fix* would need an unattended-unlockable secret store;
# a scheduled *detector* doesn't).
#
# Usage:
#   ./scripts/detect-credential-drift.sh
#
# Exit codes:
#   0 = no auth-failure signatures found in the lookback window
#   1 = one or more containers logged an auth failure against a peer app
#
# Fix for a real finding: from a local checkout (not the NAS),
#   cd terraform && bw unlock && ./apply.sh
#
# Run on a schedule via cron or a systemd timer on the NAS itself, e.g.:
#   */30 * * * * /volume1/docker/arr-stack/scripts/detect-credential-drift.sh
# (installing that schedule needs root - see the systemd unit alongside
# this script, or add the crontab line by hand; this script itself only
# needs the same docker-group access any other check script here uses.)

LOOKBACK="${1:-35m}"
# Deliberately NOT a bare `401` - session IDs, hex memory addresses, and C#
# stack-trace line numbers all contain stray "401" substrings often enough
# to make that alone pure noise (confirmed live 2026-08-17 against real
# logs: matched a UUID fragment and an `0x401be10` ffprobe address). Require
# it to appear in recognizable HTTP-auth-failure phrasing instead.
PATTERN='[Ss]tatus code 401|401.{0,20}[Uu]nauthorized|[Uu]nauthorized|[Ii]nvalid credentials|[Aa]pi[Kk]ey.*(invalid|incorrect|expired)'

declare -A CONTAINERS=(
  [seerr]="Seerr's stored Sonarr/Radarr connection"
  [bazarr]="Bazarr's stored Sonarr/Radarr connection"
  [sonarr]="Sonarr's own auth (indexer sync from Prowlarr, or its SABnzbd download client)"
  [radarr]="Radarr's own auth (indexer sync from Prowlarr, or its SABnzbd download client)"
  [prowlarr]="Prowlarr's Applications sync to Sonarr/Radarr"
)

findings=""
for c in "${!CONTAINERS[@]}"; do
  hits=$(docker logs "$c" --since "$LOOKBACK" 2>&1 | grep -iE "$PATTERN" | tail -3 || true)
  if [[ -n "$hits" ]]; then
    findings+=$'\n'"-- ${c}: ${CONTAINERS[$c]} --"$'\n'"${hits}"$'\n'
  fi
done

if [[ -n "$findings" ]]; then
  echo "CREDENTIAL DRIFT DETECTED (auth failures in the last ${LOOKBACK}):"
  echo "$findings"
  echo "Fix: from a local checkout, run 'cd terraform && bw unlock && ./apply.sh'"
  exit 1
fi

echo "OK: no cross-app auth failures in the last ${LOOKBACK}"
