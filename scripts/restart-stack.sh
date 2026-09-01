#!/bin/bash
#
# Safe stack restart - NEVER uses 'down' which kills Pi-hole DNS
#
# Usage:
#   ./scripts/restart-stack.sh           # Restart all compose files
#   ./scripts/restart-stack.sh arr       # Restart arr-stack only
#   ./scripts/restart-stack.sh traefik   # Restart traefik only
#   ./scripts/restart-stack.sh utilities # Restart utilities only
#   ./scripts/restart-stack.sh magnetio  # Restart the magnetio addon only
#
# "all" means every compose file in the repo EXCEPT docker-compose.tailscale.yml,
# and that exclusion is deliberate: recreating Tailscale node 1 severs every path
# to the NAS at once -- SSH and the UGOS admin UI both ride its own subnet route,
# so the command that would fix it arrives over the link it just cut. Rotate or
# restart that one by hand, detached, with a state-volume backup. See CLAUDE.md.
#
# tests/restart-stack.bats derives the covered set from the filesystem, so a new
# docker-compose.*.yml fails the suite until someone decides which list it joins.
#

set -euo pipefail
cd "$(dirname "$0")/.."

restart_compose() {
    local file="$1"
    local name="$2"
    echo "♻️  Restarting $name..."
    docker compose -f "$file" up -d --force-recreate
    echo "✅ $name restarted"
}

case "${1:-all}" in
    arr|arr-stack)
        restart_compose docker-compose.arr-stack.yml "arr-stack"
        ;;
    traefik)
        restart_compose docker-compose.traefik.yml "traefik"
        ;;
    cloudflared|tunnel)
        restart_compose docker-compose.cloudflared.yml "cloudflared"
        ;;
    utilities|utils)
        restart_compose docker-compose.utilities.yml "utilities"
        ;;
    magnetio)
        restart_compose docker-compose.magnetio.yml "magnetio"
        ;;
    all)
        restart_compose docker-compose.traefik.yml "traefik"
        restart_compose docker-compose.arr-stack.yml "arr-stack"
        restart_compose docker-compose.cloudflared.yml "cloudflared"
        restart_compose docker-compose.utilities.yml "utilities"
        restart_compose docker-compose.magnetio.yml "magnetio"
        echo ""
        echo "✅ All stacks restarted"
        ;;
    *)
        echo "Usage: $0 [arr|traefik|cloudflared|utilities|magnetio|all]"
        exit 1
        ;;
esac
