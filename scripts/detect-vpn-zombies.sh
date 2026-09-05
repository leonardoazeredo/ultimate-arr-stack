#!/bin/bash
set -euo pipefail
#
# Detects VPN-tunneled containers whose network namespace binding is stale
# relative to Gluetun's *current* container ID — the "zombie" failure mode
# from a Gluetun recreate (docker compose up -d, even of an unrelated
# service, if Gluetun's own config drifted). Neither `docker ps`, container
# health status, nor deunhealth can see this: a zombie still answers fine on
# its own localhost healthcheck, but is completely unreachable from the rest
# of the stack because it's bound to a network namespace that no longer
# exists as "gluetun" — Docker just hasn't cleaned up the dead reference.
#
# Usage:
#   ./scripts/detect-vpn-zombies.sh
#
# Exit codes:
#   0 = all VPN-tunneled dependents share Gluetun's current netns
#   1 = one or more zombies found (or the check itself failed)
#
# Fix for a detected zombie: recreate it through the compose file that
# DEFINES it (the script prints the exact commands). `docker restart` cannot
# work here and never could: the dead gluetun container's ID is baked into
# each dependent's HostConfig.NetworkMode, so dockerd refuses with
# "joining network namespace of container <old-id>: No such container" —
# confirmed live on 2026-08-27 against all six dependents at once. This
# script only ever fires when gluetun's ID has CHANGED, i.e. precisely the
# recreate case that docs/TROUBLESHOOTING.md documents restart as useless
# for, so restart advice here was wrong for 100% of real detections.
#
# Use in cron or after any Gluetun recreate:
#   */5 * * * * /path/to/arr-stack/scripts/detect-vpn-zombies.sh || notify "VPN zombie container!"

GLUETUN_ID=$(docker inspect --format '{{.Id}}' gluetun 2>/dev/null) || {
    echo "ERROR: Could not inspect gluetun — is it running?"
    exit 1
}

# Must list every container with network_mode: "service:gluetun" or
# "container:gluetun" across all compose files — grep for that pattern when
# adding a new VPN-tunneled service, this list doesn't derive itself.
DEPENDENTS=(qbittorrent sabnzbd prowlarr flaresolverr vpn-socks5 magnetio-addon)
zombies=()

for c in "${DEPENDENTS[@]}"; do
    mode=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$c" 2>/dev/null) || continue
    [[ "$mode" == container:* ]] || continue
    if [[ "$mode" != "container:$GLUETUN_ID" ]]; then
        zombies+=("$c")
    fi
done

# The gluetun-exit/tailscale-exit second gateway (docker-compose.tailscale.yml)
# that used to need a mirror check here was decommissioned once the Tailscale
# exit-node role moved to arr-stack-router — see docs/EXIT-NODE-PROJECT-LOG.md.

# Which compose file DEFINES each dependent. Recovery is a compose recreate,
# and this stack's standing rule is that a service may only ever be recreated
# through its own file (see docs/TROUBLESHOOTING.md) — so a single blanket
# command would be wrong for any zombie defined elsewhere. Like DEPENDENTS
# above, this map doesn't derive itself: add a service here when you add it
# there. tests/vpn-zombies.bats asserts the two stay in sync, and that each
# mapped file both exists and actually defines that service.
#
# Deliberately hardcoded rather than grepped out of the compose files at
# runtime, which would be shorter. This script's whole job is to be trusted
# when the stack is already in a bad state — and the documented cause of the
# 2026-08-27 outage was the NAS sitting on the WRONG BRANCH, where those files
# say something other than what is deployed. A hardcoded map still prints the
# right recovery command in that state; a derived one would confidently print
# the wrong one. It also keeps the script's only runtime dependency `docker`,
# so it works from cron regardless of where the checkout is. Don't "simplify"
# this into a grep.
compose_file_for() {
    case "$1" in
        qbittorrent|sabnzbd|prowlarr|flaresolverr|vpn-socks5) echo "docker-compose.arr-stack.yml" ;;
        magnetio-addon)                                      echo "docker-compose.magnetio.yml" ;;
        *)                                                   echo "" ;;
    esac
}

if [[ ${#zombies[@]} -gt 0 ]]; then
    echo "ZOMBIE CONTAINERS (stale netns binding to a dead Gluetun): ${zombies[*]}"
    echo
    echo "Fix: recreate each through the compose file that DEFINES it."
    echo "'docker restart' CANNOT work here — the dead container's ID is baked into"
    echo "HostConfig.NetworkMode, so dockerd refuses with 'No such container'."
    echo
    # -f takes a path relative to the working directory, and this script's usual
    # caller is cron — whose cwd is not the deploy path. Emit the cd so the
    # block below is pasteable as-is from wherever the output was read.
    echo "  cd $(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    # Group by the files the zombies actually map to, derived from
    # compose_file_for() rather than a second hardcoded file list. A literal
    # list here could disagree with the mapping above, and a zombie whose file
    # was missing from it would be named as broken and then given no command
    # and no warning — mapped, so not "unmapped"; absent, so never grouped.
    # Deriving makes that state unrepresentable: every non-empty mapping gets a
    # command, every empty one gets the warning below.
    unmapped=()
    files=$(for c in "${zombies[@]}"; do compose_file_for "$c"; done | sort -u)

    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        group=()
        for c in "${zombies[@]}"; do
            [[ "$(compose_file_for "$c")" == "$f" ]] && group+=("$c")
        done
        [[ ${#group[@]} -gt 0 ]] && echo "  docker compose -f $f up -d --force-recreate ${group[*]}"
    done <<< "$files"

    for c in "${zombies[@]}"; do
        [[ -z "$(compose_file_for "$c")" ]] && unmapped+=("$c")
    done
    if [[ ${#unmapped[@]} -gt 0 ]]; then
        echo
        echo "  WARNING: no compose file mapped for: ${unmapped[*]}"
        echo "  Find the owning file with: grep -l '^  <service>:' docker-compose.*.yml"
        echo "  then add it to compose_file_for() in this script. Recreate by hand meanwhile."
    fi

    echo
    echo "Re-run this script afterward to confirm every dependent binds to the new ID."
    exit 1
fi

echo "OK: all VPN-tunneled dependents share Gluetun's current netns"
