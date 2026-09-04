# Maintenance Guide

Day-to-day operations, multi-compose commands, and verification procedures.

## Multi-Compose Quick Reference

This stack uses multiple compose files. Here are common commands for each scenario.

### Core Stack Only

```bash
# Start / recreate
docker compose -f docker-compose.arr-stack.yml up -d

# Stop (without removing — safe, keeps Pi-hole running)
docker compose -f docker-compose.arr-stack.yml stop

# View logs
docker compose -f docker-compose.arr-stack.yml logs -f --tail=50

# Pull latest images
docker compose -f docker-compose.arr-stack.yml pull
```

### Core + Traefik (.lan domains)

```bash
# Start both
docker compose -f docker-compose.arr-stack.yml -f docker-compose.traefik.yml up -d

# Pull images for both
docker compose -f docker-compose.arr-stack.yml -f docker-compose.traefik.yml pull
```

### Core + Traefik + Cloudflared (remote access)

```bash
# Start all three
docker compose -f docker-compose.arr-stack.yml -f docker-compose.traefik.yml -f docker-compose.cloudflared.yml up -d
```

### Utilities (independent)

```bash
# Start utilities
docker compose -f docker-compose.utilities.yml up -d

```

### Tailscale (independent)

```bash
# Start / update Tailscale (uses its own compose project name, so this won't disturb the arr-stack)
docker compose -f docker-compose.tailscale.yml up -d
docker compose -f docker-compose.tailscale.yml pull
```

### All Stacks

```bash
# Start everything
docker compose \
  -f docker-compose.arr-stack.yml \
  -f docker-compose.traefik.yml \
  -f docker-compose.cloudflared.yml \
  -f docker-compose.tailscale.yml \
  -f docker-compose.utilities.yml \
  up -d

# Pull all images
docker compose \
  -f docker-compose.arr-stack.yml \
  -f docker-compose.traefik.yml \
  -f docker-compose.cloudflared.yml \
  -f docker-compose.tailscale.yml \
  -f docker-compose.utilities.yml \
  pull
```

> **Never use `docker compose down`** on the arr-stack file — it removes the Pi-hole container and you lose DNS (and internet) before you can bring it back up. Use `stop` instead, or just `up -d` to recreate.

---

## VPN Verification

Verify the VPN is working and your real IP is not exposed:

```bash
# Quick check
./scripts/check-vpn.sh

# Manual check
docker exec gluetun wget -qO- https://ipinfo.io/ip     # Should show VPN IP
docker exec qbittorrent wget -qO- https://ipinfo.io/ip  # Should match Gluetun's IP
```

The `check-vpn.sh` script compares Gluetun's exit IP against your household's WAN IP — taken from a bridge-only container's egress, since every IP involved is a public address as seen by `ifconfig.me` — and exits non-zero if they match (leak detected). It then checks that each VPN-tunneled service's egress matches Gluetun's exactly. You can add it to cron for periodic monitoring:

```bash
# Check every 5 minutes, log failures
*/5 * * * * $NAS_STACK_DIR/scripts/check-vpn.sh >> /var/log/vpn-check.log 2>&1
```

---

## Backups

Run periodic backups of service configs:

```bash
# Manual backup
./scripts/arr-backup.sh --tar

# Encrypted backup
./scripts/arr-backup.sh --tar --encrypt
```

See [Backup & Restore](BACKUP.md) for full details and [Restore Guide](RESTORE.md) for recovery procedures.

---

## Queue Cleanup

Torrents frequently stall (dead seeders, stuck metadata, failed imports). The cleanup script removes stuck items, blocklists them, and triggers fresh searches:

```bash
# Dry run — see what would be removed
./scripts/queue-cleanup.sh

# Actually remove stuck items
./scripts/queue-cleanup.sh --apply

# With verbose output
./scripts/queue-cleanup.sh --apply -v
```

### Automated (cron)

Add to NAS crontab (`crontab -e`):

```bash
# Thursday 2am — clean stuck downloads weekly
0 2 * * 4 $NAS_STACK_DIR/scripts/queue-cleanup.sh --apply >> $NAS_STACK_DIR/logs/queue-cleanup.log 2>&1
```

### What gets removed

- Downloads stalled with no connections (dead seeders)
- Torrents stuck downloading metadata (no peers)
- Failed imports (downloaded but can't import)
- Blocked imports (already imported, not an upgrade, missing episodes in pack)
- Import-pending items with warnings (executable files, quality not accepted)
- Items at 0% progress for more than 24 hours

Items with **any** download progress are never removed, even if slow.

Removed releases are blocklisted so the same broken release won't be grabbed again. A fresh search is triggered for each affected series/movie to find better-seeded alternatives.

---

## Health Checks

All services have Docker healthchecks. Check status:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
```

Services showing `(unhealthy)` may need attention. Common causes:
- **Gluetun unhealthy**: VPN connection lost — check `docker logs gluetun`
- **qBittorrent/SABnzbd/Prowlarr unhealthy**: Often caused by Gluetun being down (they share its network). Sonarr/Radarr are on the bridge and not affected by a gluetun outage.
- **Pi-hole unhealthy**: DNS resolution failing — check upstream DNS config

---

## Updating Images

Check for available updates:

```bash
# If using Diun (from utilities stack), it sends notifications automatically

# Manual check
docker compose -f docker-compose.arr-stack.yml pull
# Review what changed, then recreate
docker compose -f docker-compose.arr-stack.yml up -d
```

**Before bumping a service that owns a database** (Pi-hole's gravity/FTL config, the \*arrs' SQLite), back up its config volume first — a minor-version bump can migrate the DB irreversibly:

```bash
docker run --rm -v <project>_<service>-config:/src:ro -v "$PWD/backups":/bak \
  alpine tar czf /bak/<service>-config-backup-$(date +%Y%m%d).tgz -C /src .
# e.g. arr-stack_pihole-etc-pihole  →  backups/pihole-config-backup-YYYYMMDD.tgz
```

**Pi-hole and Cloudflared notes:** recreating Pi-hole briefly drops LAN DNS (~20-30s) — expected; verify `.lan` and external resolution after. Cloudflared runs as its **own compose project** (`-f docker-compose.cloudflared.yml`), so bump it with that file, not via the arr-stack project.

See [Upgrading Guide](UPGRADING.md) for version-specific upgrade notes.
