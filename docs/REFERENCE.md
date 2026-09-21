# Quick Reference: URLs, Commands, Network

> ⚠️ **If you lose internet connection:** this warning used to say that stopping
> Pi-hole kills DNS for the whole network, and to recover by
> `docker compose up -d pihole`. **That no longer applies here.** DNS moved to
> AdGuard Home on the router on 2026-09-21, and the router answers with or
> without the NAS — see [LOCAL-DNS.md](LOCAL-DNS.md) and
> [the migration plan](superpowers/plans/2026-09-19-dns-adguard-router-migration.md).
> The old advice is kept only because it is still correct for a deployment that
> points its DHCP at the NAS.
>
> **What to do instead, if DNS stops working:** the NAS is no longer the first
> suspect and restarting it will not help.
> 1. Confirm the router is up at all — a house whose router is down has no
>    internet regardless of DNS.
> 2. Check the watchdog: `ssh arr-stack-router '/usr/sbin/arrdns-watchdog.sh --status'`.
>    `mode=fallback` means AdGuard Home stopped answering and the router moved
>    the house to dnsmasq; resolution is still working and only ad blocking is
>    lost, so this is not an outage.
> 3. `mode=adguard` with `probe=down` means the watchdog has not yet fired —
>    three consecutive failures are required. `tail /var/log/arrdns-watchdog.log`
>    shows every transition.
> 4. If a single client is broken and the router is fine, that client is the
>    problem; point it at `192.168.8.1` by hand to confirm.
>
> **Tip:** When doing full stack restarts, use mobile hotspot first, or restart with a single command:
> ```bash
> docker compose -f docker-compose.arr-stack.yml up -d  # Recreates without full down
> # Add `-f docker-compose.utilities.yml` after the first `-f` if you also run utilities (beszel, configarr, etc.)
> ```

## Service Access

| Service | Core (IP:port) | + local DNS | + remote access |
|---------|----------------|-------------|-----------------|
| Jellyfin | `NAS_IP:8096` | `https://jellyfin.lan`* | `https://jellyfin.DOMAIN` |
| Seerr | `NAS_IP:5055` | `https://seerr.lan`* | `https://seerr.DOMAIN` |
| Sonarr | `NAS_IP:8989` | `https://sonarr.lan`* | — |
| Radarr | `NAS_IP:7878` | `https://radarr.lan`* | — |
| Prowlarr | `NAS_IP:9696` | `https://prowlarr.lan`* | — |
| Bazarr | `NAS_IP:6767` | `https://bazarr.lan`* | — |
| SABnzbd | `NAS_IP:8082` | `https://sabnzbd.lan`* | — |
| Decypharr | `NAS_IP:8282` | — | — |
| AdGuard Home (DNS) | — (on the router) | `http://192.168.8.1:3000` | maintenance VLAN only |
| Traefik | — | `https://traefik.lan`* | — |
| Uptime Kuma | `NAS_IP:3001` | `https://uptime.lan`* | — |
| duc | — | `https://duc.lan`* | — |
| Beszel | — | `https://beszel.lan`* | — |
| Homepage | — | `https://homepage.lan`* | — |
| Usenet status | — | `https://usenet.lan`* | — |

**Legend:**
- **Core** — Always works on your LAN
- **+ local DNS** — Requires [Pi-hole + Traefik setup](LOCAL-DNS.md). `*` = also requires the
  [+ HTTPS + auth](HTTPS-LOCAL.md) setup and prompts for basic-auth (`http://` still works and
  redirects here automatically). Jellyfin/Seerr keep their own app-level login in addition to this
  gate — see that doc's client-compatibility caveat if a non-browser device stops connecting.
- **+ remote access** — Requires [Cloudflare Tunnel setup](REMOTE-ACCESS.md). Services marked "—" are LAN-only (not exposed to internet).

## Services & Network

| Service | IP | Port | Notes |
|---------|-----|------|-------|
| **Gluetun** | **172.20.0.3** | — | VPN gateway |
| ↳ SABnzbd | (via Gluetun) | 8082 | Optional — usenet runs through TorBox instead ([why](APP-CONFIG.md#42-usenet-torbox-blackhole)) |
| ↳ Prowlarr | (via Gluetun) | 9696 | Indexer manager |
| Sonarr | 172.20.0.10 | 8989 | TV shows (own IP — not via VPN) |
| Radarr | 172.20.0.11 | 7878 | Movies (own IP — not via VPN) |
| Jellyfin | 172.20.0.4 | 8096 | Media server |
| Seerr | 172.20.0.8 | 5055 | Request management |
| Bazarr | 172.20.0.9 | 6767 | Subtitles |
| Decypharr | 172.20.0.7 | 8282 | TorBox debrid client (own IP — not via VPN; it only calls TorBox over HTTPS) |
| ↳ FlareSolverr | (via Gluetun) | 8191 (not published on the host) | Cloudflare bypass (inactive until added as an Indexer Proxy in Prowlarr — see [APP-CONFIG.md](APP-CONFIG.md#45-prowlarr-indexer-manager)) |

**+ local DNS** (traefik.yml):

| Service | IP | Port | Notes |
|---------|-----|------|-------|
| Traefik | 172.20.0.2 | 80 | Reverse proxy |

**+ remote access — Cloudflared path** (cloudflared.yml):

| Service | IP | Port | Notes |
|---------|-----|------|-------|
| Cloudflared | 172.20.0.12 | — | Tunnel (no ports exposed). **Opt-in `tunnel` profile** — boot/restart reconciles skip it until an operator adds `cloudflared/config.yml` and enables it explicitly (see below) |

**+ remote access — Tailscale path** (tailscale.yml):

| Service | IP | Port | Notes |
|---------|-----|------|-------|
| Tailscale | host-network | — | Subnet router, advertises `LAN_SUBNET` to tailnet |

The Tailscale exit-node role (ProtonVPN egress for remote clients) now runs
natively on `arr-stack-router`, not on the NAS — see
[EXIT-NODE-PROJECT-LOG.md](EXIT-NODE-PROJECT-LOG.md). The NAS-based
`gluetun-exit`/`tailscale-exit` pair that used to live here was decommissioned.

**Optional** (utilities.yml):

| Service | IP | Port | Notes |
|---------|-----|------|-------|
| Uptime Kuma | 172.20.0.13 | 3001 | Service monitoring |
| duc | 172.20.0.14 | 8838 | Disk usage |
| Beszel | 172.20.0.15 | 8090 | System monitoring |
| DIUN | 172.20.0.16 | — | Image update notifier (no UI) |
| Configarr | — | — | TRaSH Guides sync (one-shot, no UI) |
| Homepage | 172.20.0.22 | 3000 | Unified dashboard |
| Usenet status | 172.20.0.23 | 80 | Usenet blackhole download view (no host port; served through Traefik) |

### Service Connection Guide

**VPN-protected services** (SABnzbd, Prowlarr, FlareSolverr, vpn-socks5) share Gluetun's network via `network_mode: service:gluetun` — these carry the traffic that must stay hidden (indexer scraping). Usenet downloads no longer cross this boundary: TorBox fetches them on its own servers, and a NAS-side timer moves the finished file into the arr's watch folder.

**Bridge services** (Sonarr, Radarr, Jellyfin, Seerr, Bazarr, Decypharr, …) run on the `arr-core` bridge with their own IPs. Sonarr (172.20.0.10) and Radarr (172.20.0.11) are *not* behind the VPN: they only contact metadata providers (TVDB/TMDB) and internal services, so they need no VPN — and staying on the bridge keeps them reachable when a gluetun/VPN reconnect happens. Decypharr is on the bridge for the same reason: the torrent runs on TorBox's servers, and only the finished file comes back over HTTPS.

| From | To | Use | Why |
|------|-----|-----|-----|
| Sonarr | SABnzbd | `gluetun:8080` | Download client is behind the VPN |
| Radarr | SABnzbd | `gluetun:8080` | Download client is behind the VPN |
| Prowlarr | Sonarr | `sonarr:8989` | Sonarr is on the bridge (own IP) |
| Prowlarr | Radarr | `radarr:7878` | Radarr is on the bridge (own IP) |
| Prowlarr | FlareSolverr | `localhost:8191` | Same network stack (both behind Gluetun) |
| Seerr | Sonarr | `sonarr:8989` | Both on the bridge |
| Seerr | Radarr | `radarr:7878` | Both on the bridge |
| Seerr | Jellyfin | `jellyfin:8096` | Both have own IPs |
| Bazarr | Sonarr | `sonarr:8989` | Both on the bridge |
| Bazarr | Radarr | `radarr:7878` | Both on the bridge |
| Sonarr | Decypharr | `decypharr:8282` | Both on the bridge (Decypharr only calls TorBox's HTTPS API, no VPN needed) |
| Radarr | Decypharr | `decypharr:8282` | Both on the bridge (Decypharr only calls TorBox's HTTPS API, no VPN needed) |

> **Reaching VPN-side services from the bridge:** use the `gluetun` hostname (or `172.20.0.3`) — SABnzbd/Prowlarr listen inside gluetun's namespace, so they have no Docker DNS name of their own. Gluetun's `FIREWALL_OUTBOUND_SUBNETS` includes `172.20.0.0/24`, so Prowlarr (in the VPN namespace) can reach Sonarr/Radarr on the bridge.

## Common Commands

```bash
# All commands below run on your NAS via SSH

# View all containers
docker ps

# View logs
docker logs -f <container_name>

# Restart single service
docker compose -f docker-compose.arr-stack.yml restart <service_name>

# Restart entire stack (safe - Pi-hole restarts immediately)
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate

# Pull repo updates then redeploy
git pull origin main
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate

# Update container images (core stack only)
docker compose -f docker-compose.arr-stack.yml pull
docker compose -f docker-compose.arr-stack.yml up -d

# If you also run utilities (beszel, configarr, etc.), add -f docker-compose.utilities.yml to both commands
```

> ⚠️ **Never use `docker compose down` (+ local DNS users)** - if your router uses Pi-hole for DNS, stopping it kills DNS for your entire network. Use `up -d --force-recreate` instead.

## Networks

| Network | Subnet | Purpose |
|---------|--------|---------|
| arr-stack | 172.20.0.0/24 | Service communication |
| vpn-net | 10.8.1.0/24 | Internal VPN routing (WireGuard peers) |
| traefik-lan | (your LAN)/24 | macvlan for .lan domains (+ local DNS only) |

> **Note:** `docker compose up` shows these as `arr-stack`, `arr-stack_vpn-net`, and `arr-stack_traefik-lan`. The `arr-stack_` prefix is normal — Docker adds the project name to networks that don't have an explicit `name:` set.

## Startup Order

Services start in dependency order (handled automatically by `depends_on`):

1. **Pi-hole** → DNS ready (for containers; optionally your LAN)
2. **Gluetun** → VPN connected (uses Pi-hole for internal DNS)
3. **Prowlarr, SABnzbd** → VPN-protected services (behind Gluetun)
4. **Sonarr, Radarr, Decypharr** → bridge services (own IPs, not via VPN); Sonarr and Radarr reach SABnzbd via `gluetun`
5. **Seerr, Bazarr** → connect to Sonarr/Radarr by bridge hostname (`sonarr`/`radarr`)
6. **FlareSolverr** → Cloudflare bypass (via Gluetun, shares VPN with Prowlarr)
6. **Jellyfin, WireGuard** → Independent, start anytime

## Compose Files

### `docker-compose.arr-stack.yml` (Core - Jellyfin)

| Service | Description |
|---------|-------------|
| Jellyfin | Media streaming |
| Seerr | Request system |
| Sonarr | TV management |
| Radarr | Movie management |
| Prowlarr | Indexer manager |
| Decypharr | TorBox debrid client (torrents) |
| SABnzbd | Usenet client |
| Bazarr | Subtitles |
| Gluetun | VPN gateway |
| Pi-hole | DNS/ad-blocking |
| WireGuard | VPN server |
| FlareSolverr | CAPTCHA bypass |

### `docker-compose.traefik.yml` (+ local DNS)

| Service | Description |
|---------|-------------|
| Traefik | Reverse proxy for .lan domains |

### `docker-compose.cloudflared.yml` (+ remote access — Cloudflared path)

| Service | Description |
|---------|-------------|
| Cloudflared | Tunnel to Cloudflare for external access |

**Opt-in.** The service is behind the `tunnel` profile, so `scripts/boot-compose-up.sh`
(every boot) and `scripts/restart-stack.sh all` skip it rather than starting a tunnel
whose gitignored `cloudflared/config.yml` does not exist — which would exit immediately
and be restarted forever by `restart: always`. To enable it:

```bash
cp cloudflared/config.yml.example cloudflared/config.yml   # then fill it in
docker compose -f docker-compose.cloudflared.yml --profile tunnel up -d
```

### `docker-compose.tailscale.yml` (+ remote access — Tailscale path)

| Service | Description |
|---------|-------------|
| Tailscale | Mesh VPN subnet router — private full-LAN access from anywhere |

### `docker-compose.utilities.yml` (Optional)

| Service | Description |
|---------|-------------|
| deunhealth | Auto-restart on VPN reconnect |
| Uptime Kuma | Service uptime monitoring |
| duc | Disk usage treemap |
| Beszel | System metrics (CPU, RAM, disk, containers) |
| DIUN | Docker image update notifications |
| Configarr | TRaSH Guides quality profile sync (one-shot) |
