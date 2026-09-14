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
docker exec sabnzbd wget -qO- https://ipinfo.io/ip     # Should match Gluetun's IP
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

### Automated (systemd timer, hourly)

Install once, as the deploy user — no root:

```bash
mkdir -p ~/.config/systemd/user
cp scripts/queue-cleanup.service scripts/queue-cleanup.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now queue-cleanup.timer
systemctl --user list-timers queue-cleanup.timer     # confirm it is armed
```

### Backlog search (systemd timer, every 4 hours)

Neither arr searches its own backlog. They search for new releases (RSS) and for
what is already in their queue, so a film added in August and never found sits
missing indefinitely. Measured on this NAS 2026-09-13: 24 films missing with 97
grabbable releases available for one of them, and 3,107 episodes missing across
42 series — while the only grabs that day were ones a human asked for by hand.

Install once, as the deploy user — no root:

```bash
mkdir -p ~/.config/systemd/user
cp scripts/backlog-search.service scripts/backlog-search.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now backlog-search.timer
systemctl --user list-timers backlog-search.timer     # confirm it is armed
```

Output goes to `logs/backlog-search.log`. What it searched, and when, is in
`logs/backlog-search-state.json`.

**The two services are paced differently, and both calls come from measurement.**

Sonarr is **bounded**: at most `--limit` seasons per run (default 10), walking
the backlog in a stable order. The arr's own `MissingEpisodeSearch` is the trap
here — measured, it opened with *"Performing search for 3116 episodes"*, could
not be cancelled (Sonarr answers 409 for a command already started), and had to
be killed by restarting the container. That is the shape of the burst that
earned this account a 90-minute TorBox refusal earlier the same day. Work is per
season, so one `SeasonSearch` covers a season instead of one request per
episode: ~200 requests for this library rather than ~3,100. Once fewer than
`--limit` seasons remain it switches to the bulk command, which is bounded by
definition by then.

Radarr is **bulk with a cooldown**, the opposite call: `MissingMoviesSearch`
grabbed 5 films in 4 minutes, while `MoviesSearch` on a single film processed
2-4 releases per call and grabbed nothing — even for a film with 22 approved and
43 download-allowed releases in the same indexer results. The per-film path is
what does not work here. Bulk is affordable because the candidate set is 24
films, and `--cooldown` (default 6h) stops it re-presenting that set every
interval.

At ten seasons per run every four hours, this backlog drains in roughly three
and a half days. Check progress with a dry run, which changes nothing:

```bash
./scripts/backlog-search.sh          # what the next run would do
```

**Deploying this unit can run it.** The timer's first elapse is
`OnActiveSec=15min`, measured from when the timer was activated — so
`enable --now` on a running system starts a sweep 15 minutes later, with no
further warning. That is intended, and it is also true on any redeploy that
restarts the timer, so check `logs/queue-cleanup.log` afterwards before assuming
nothing happened.

It used to be `OnBootSec=15min`, which looks like the same grace period and is
not: on a NAS that has been up for weeks, "15 minutes after boot" is always in
the past, so the timer's first elapse was already due and the service started in
the same second the timer was registered. Measured 2026-09-13 — unit registered
at 23:48:19, log header 23:48:19, *"Summary (APPLIED): 16 items removed, 7
searches triggered"*. Installing a schedule fired a destructive sweep, and
nothing in `systemctl` output says so. `tests/systemd-units.bats` fails if
`OnBootSec` (or `OnStartupSec`/`OnUnitInactiveSec`) ever comes back.

Output goes to `logs/queue-cleanup.log` (created by the unit, trimmed at 1,000 lines) and to the user journal:

```bash
journalctl --user -u queue-cleanup.service -n 50
```

**This timer did not exist until 2026-09-12.** The script had shipped with a
"suggested cron: Thu 2am" line in its header and nothing ever installed it, on
any host. In the meantime 67 items sat at 0% in Sonarr's queue since
mid-August: Decypharr had failed to resolve their TorBox links, given up
silently, and Sonarr — reading each stuck item as "already downloading at the
cutoff" — rejected every replacement release for those episodes. The script
that would have cleared them was in the repo the whole time, working, unused.

### What gets removed

- Downloads stalled with no connections (dead seeders)
- Torrents stuck downloading metadata (no peers)
- Failed imports (downloaded but can't import)
- Blocked imports (already imported, not an upgrade, missing episodes in pack)
- Import-pending items with warnings (executable files, quality not accepted)
- Items at 0% progress for more than 24 hours, or more than 3 hours
  when the client is a debrid provider (Decypharr/TorBox) — there a stalled
  link resolution never recovers on its own, and the item blocks its episode
  the whole time
- Completed downloads the arr has permanently refused to import — a sample
  verdict, or a release that was not found to contain the film. The client has
  nothing left to report, so without this the item sits in `importPending`
  forever and blocks every alternative release for that title

Items with **any** download progress are never removed, even if slow.

### The size floor is global, not per-profile

The minimum-size filter that decides which releases are acceptable lives in the
arr's **quality definitions** (`/api/v3/qualitydefinition`), which are global.
It is not a per-profile or per-indexer setting, and both arrs' profiles carry no
size keys of their own — checked directly on 2026-09-13: Radarr's quality
definitions hold the `minSize` values and all seven of its profiles report
`size keys in items = False`, same for Sonarr's seven.

That matters because lowering the floor to let a release through lets it through
**everywhere**. Measured the same day, after the floor was lowered:

| | before | after |
|---|---|---|
| Radarr `Bluray-1080p` | 50.8 MB/min | **18 MB/min** |
| Sonarr `Bluray-1080p` | 50.4 MB/min | **18 MB/min** |
| Sonarr `Bluray-2160p` | — | 94.6 MB/min |
| Sonarr `WEBDL-2160p` | — | 25 MB/min |

Two consequences worth knowing before changing it again. A 1080p floor of
18 MB/min admits releases down to roughly 1.5 GB for a 90-minute film, in *any*
profile that permits 1080p — "Any" included. And 4K is **not** filtered at the
same rate: `Bluray-2160p` sits an order of magnitude above it, deliberately, so
a floor lowered for 1080p does not also flatten 4K.

There is no per-catalogue floor to be had here. If one profile should be
stricter, that is a custom-format or a separate profile, not a second `minSize`.

Removed releases are blocklisted so the same broken release won't be grabbed
again. The exception is a stale item from a debrid client (TorBox behind
Decypharr, and the like): there the release is fine and the provider failed, so
blocklisting it would forbid the one release the provider is known to have
cached. A fresh search is then triggered for the episodes that were removed —
or the film, for Radarr — spaced 30 seconds apart, because a burst of searches
answers `429` and Sonarr disables that indexer for the rest of the run.

---

## Usenet Blackhole (systemd timer, every 2 minutes)

Both arrs use their native `UsenetBlackhole` download client for usenet, not
SABnzbd. The arr writes `<Release.Title>.nzb` into a folder and polls another
one; `scripts/usenet-blackhole.sh` is what moves a release between them, by
submitting it to TorBox's API and fetching the finished zip back. The reason is
in `docs/TROUBLESHOOTING.md` — SABnzbd's NNTP server serves articles only up to
about 90 days old, and a backlog is mostly older than that. Decypharr still
handles torrents, and SABnzbd still runs with nothing pointed at it.

```bash
mkdir -p ~/.config/systemd/user
cp scripts/usenet-blackhole.service scripts/usenet-blackhole.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now usenet-blackhole.timer
systemctl --user list-timers usenet-blackhole.timer     # confirm it is armed
```

Two minutes, not an hour: the arr imports a release only after it appears in the
watch folder *and* its contents have been stable for the arr's 30-second grace
period, so the poll interval is the floor on how long a finished download sits
before the arr notices. A pass with nothing in flight is a handful of API calls.

| Path | What it is |
| --- | --- |
| `${MEDIA_ROOT}/usenet/blackhole/nzb` | the arr writes NZBs here |
| `${MEDIA_ROOT}/usenet/blackhole/complete` | the arr imports from here; it deletes the folder after importing |
| `${MEDIA_ROOT}/usenet/blackhole/staging` | ours alone; a release is downloaded here and renamed into place |
| `logs/usenet-blackhole.log` | what each pass did |
| `logs/usenet-blackhole-failed.log` | releases TorBox failed, or that passed `--timeout-hours` |
| `logs/usenet-blackhole-state.json` | what is in flight. **Do not delete it** |

Staging is deliberately a sibling of the watch folder and not a `.incoming-`
directory inside it. Sonarr does not skip dot-directories when scanning a watch
folder — `DiskProviderBase.GetDirectories` skips only `FileAttributes.System`,
and the regex in `DiskScanService.FilterPaths` that would filter them needs a
trailing separator that `PathExtensions.GetRelativePath` has already trimmed —
so a staging directory in there is reported as a finished download, and its
half-written files are what gets imported.

Both arrs point at the `/data/...` form of those paths, because the handshake
happens from inside their containers where `${MEDIA_ROOT}` is mounted at
`/data`. The arr configuration is:

| Setting | Value |
| --- | --- |
| implementation | `UsenetBlackhole` (`protocol: usenet`) |
| `nzbFolder` | `/data/usenet/blackhole/nzb` |
| `watchFolder` | `/data/usenet/blackhole/complete` |

A blackhole client reports no queue to the arr, so a release that never
completes is invisible from the arr's side. That is what the failed log is for:
`queue-cleanup.sh` cannot see a stuck usenet release, because there is nothing
in the arr's queue to see.

---

## Health Checks

All services have Docker healthchecks. Check status:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
```

Services showing `(unhealthy)` may need attention. Common causes:
- **Gluetun unhealthy**: VPN connection lost — check `docker logs gluetun`
- **SABnzbd/Prowlarr/FlareSolverr unhealthy**: Often caused by Gluetun being down (they share its network). Sonarr/Radarr are on the bridge and not affected by a gluetun outage.
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
