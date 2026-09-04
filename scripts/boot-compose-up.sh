#!/bin/sh
# Reconcile every deployed compose stack after a reboot or a UGOS update.
#
# Why this exists: Docker's `restart: always` is not enough. A UGOS update on
# 5 Aug 2026 left every container *running* but with its published ports never
# established — Pi-hole reported healthy (its healthcheck digs 127.0.0.1 from
# inside the container, so it passes even when nothing outside can reach it)
# while nothing was listening on the NAS's LAN IP:53. DNS was down for the whole house
# and the NAS looked fine from `docker ps`.
#
# `docker compose up -d` reconciles each container against its compose file and
# re-establishes the port bindings, which is the part a restart misses.
#
# Deliberately NOT using --remove-orphans: containers from the other compose
# files in the same directory look like orphans to each individual file, and it
# would delete them.
#
# Exit codes:
#   0 = every stack that exists on this machine was reconciled
#   1 = docker never became ready, or at least one stack failed (named in the log)

# Both overridable, and only so tests/boot-compose-up.bats can point the script
# at a throwaway tree. Nothing in production sets either: the @reboot crontab
# entry runs this with no environment at all, so the defaults are what runs.
LOG="${BOOT_LOG:-/volume1/docker/boot-compose-up.log}"
DOCKER_ROOT="${BOOT_DOCKER_ROOT:-/volume1/docker}"

# Keep the log bounded without needing logrotate.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1000000 ]; then
    tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

exec >> "$LOG" 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') boot bring-up ==="

# Cron fires @reboot before Docker is necessarily accepting connections.
i=0
while ! docker info >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then
        echo "docker never became ready after 5 minutes — giving up"
        exit 1
    fi
    sleep 5
done
echo "docker ready after $((i * 5))s"

# Order matters across files, and it is a dependency order read off the compose
# files themselves -- the same one scripts/restart-stack.sh's "all" arm uses:
#
#   magnetio  creates magnetio-net, declared `external: true` by
#             docker-compose.arr-stack.yml and joined by gluetun.
#   arr-stack creates arr-core AND holds pihole/dnscrypt-proxy, so it is both
#             the network owner and the DNS everything after it needs.
#   the rest  all declare arr-core `external: true`.
#
# Docker networks survive a reboot, so on this NAS the order has never actually
# been load-bearing. It becomes load-bearing the first time this runs after a
# `docker network prune` or on a rebuilt NAS, which is precisely the situation
# where nobody is watching the log.
STACKS="
$DOCKER_ROOT/arr-stack/docker-compose.magnetio.yml
$DOCKER_ROOT/arr-stack/docker-compose.arr-stack.yml
$DOCKER_ROOT/arr-stack/docker-compose.traefik.yml
$DOCKER_ROOT/arr-stack/docker-compose.utilities.yml
$DOCKER_ROOT/arr-stack/docker-compose.tailscale.yml
$DOCKER_ROOT/arr-stack/docker-compose.cloudflared.yml
$DOCKER_ROOT/frigate/docker-compose.frigate.yml
$DOCKER_ROOT/immich/docker-compose.yml
$DOCKER_ROOT/therapy-stack/docker-compose.nas.yml
"

failed=""
for f in $STACKS; do
    [ -f "$f" ] || { echo "--- SKIP (missing): $f"; continue; }
    echo "--- $f"
    # One stack failing must not stop the rest — DNS matters more than Immich.
    if ! (cd "$(dirname "$f")" && docker compose -f "$(basename "$f")" up -d 2>&1); then
        echo "FAILED: $f"
        failed="$failed $f"
    fi
done

if [ -n "$failed" ]; then
    echo "=== finished WITH FAILURES:$failed"
    # Non-zero, so `failed` is not merely decorative. Nothing reads this today --
    # cron's @reboot discards it, and every line of output already goes to the
    # log rather than to cron's mailer, so this cannot start mailing anyone --
    # but an accumulator that can never change the outcome is the exact shape
    # this repo keeps finding in its own guards. Being able to run this by hand
    # and get an answer costs one line.
    exit 1
fi
echo "=== finished clean $(date '+%H:%M:%S')"
