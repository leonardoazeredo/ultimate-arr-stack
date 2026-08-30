# Backup & Restore

This stack uses Docker named volumes for service data. This guide covers backing up and restoring your configuration.

## Prerequisites

**USB Drive for Automated Backups (Recommended)**

For the automated daily backup to work, plug a USB drive into your NAS:

1. **Format** the USB drive (ext4 recommended, FAT32 works but has file size limits)
2. **Mount** it at `/mnt/arr-backup` (or update the cron job path)
3. The script will automatically keep 7 days of backups and rotate old ones

> Without a USB drive, backups go to `/tmp` which is cleared on reboot. You'd need to manually pull backups off-NAS.

---

## What Gets Backed Up

The backup script (`scripts/arr-backup.sh`) backs up **state a service cannot rebuild by itself**. Volumes marked *(cache excluded)* are backed up with their regenerable subdirectories skipped — see the exclusion list in the script.

| Volume | Kept | Contents |
|--------|------|----------|
| gluetun-config | ~7MB | VPN provider settings |
| qbittorrent-config | ~15MB | Client settings, categories |
| sabnzbd-config | ~2MB | Usenet provider credentials and settings |
| prowlarr-config | ~14MB | Indexer configs, API keys |
| bazarr-config | ~6MB | Subtitle provider credentials |
| uptime-kuma-data | ~14MB | Monitor configurations |
| seerr-config | ~123MB | User accounts, requests |
| sonarr-config *(cache excluded)* | ~13MB of 1015MB | Series DB, quality profiles, custom formats, API key |
| radarr-config *(cache excluded)* | ~7MB of 190MB | Movie DB, quality profiles, custom formats, API key |
| jellyfin-config *(cache excluded)* | ~9MB of 506MB | Users, watch history, plugin config |
| pihole-etc-pihole *(cache excluded)* | ~5MB of 50MB | `pihole.toml`, gravity DB, custom allow/deny lists |

Sizes measured on the live NAS 2026-08-30.

**The four *(cache excluded)* volumes were previously skipped entirely** on the grounds that they were large and "re-scan to rebuild". That was only ever true of the caches inside them. A re-scan does not rebuild quality profiles, custom formats, release profiles, indexer assignments, Jellyfin users, or watch history. Excluding just the caches buys full protection for those services for roughly 35MB — `sonarr-config`'s 862MB `logs.db` was the bulk of what made the volume look too expensive to back up.

## What's NOT Backed Up

Volumes holding nothing a service cannot rebuild unaided:

| Volume | Size | Why Excluded |
|--------|------|--------------|
| jellyfin-cache | ~12MB | Transcoding cache, fully regenerates |
| duc-index | ~20MB | Disk usage index, regenerates on restart |
| configarr-repos | ~10MB | Git clones of upstream config repos, re-cloned on run |
| magnetio-redis-data | 8KB | Ephemeral cache |
| decypharr-config | ~3MB | Not yet assessed — candidate for inclusion |
| beszel-data | ~400KB | Not yet assessed — candidate for inclusion |
| dnscrypt-config | ~500KB | Not yet assessed — candidate for inclusion |

Plus the cache subdirectories inside the four *(cache excluded)* volumes above: `logs.db`, `logs`, `MediaCover`, `Sentry` (*arr), `metadata`/`cache`/`log`/`transcodes` (Jellyfin), `pihole-FTL.db`/`gravity_old.db`/`listsCache` (Pi-hole).

**Homepage** (`homepage/config/`) isn't a Docker volume at all — it's a
bind-mounted, git-tracked directory, so its config is already backed up by
version control. Nothing to add here; restoring it is just `git pull`.

---

## Running a Backup

### On the NAS

```bash
# SSH into your NAS first, then:
cd $NAS_STACK_DIR
./scripts/arr-backup.sh --tar
```

Output:
```
=== Arr-Stack Backup ===
Volume prefix: arr-stack_*
Backup dir:    /tmp/arr-stack-backup-20241217

Backing up gluetun-config... OK (7.1M)
Backing up qbittorrent-config... OK (8.9M)
...
Summary: 8 backed up, 0 skipped, 0 failed
Total size: 58M

Created: /tmp/arr-stack-backup-20241217.tar.gz (13M)
```

### Copying Off-NAS

**Ugreen NAS** (scp doesn't work with /tmp):
```bash
ssh user@nas "cat /tmp/arr-stack-backup-*.tar.gz" > ./backup.tar.gz
```

**Other systems** (Synology, QNAP, Linux):
```bash
scp user@nas:/tmp/arr-stack-backup-*.tar.gz ./backup.tar.gz
```

> **Important:** Backups in `/tmp` are cleared on reboot. Copy off-NAS promptly!

---

## Restore

### Full Restore (New Installation)

1. Deploy the stack normally (see [Setup Guide](SETUP.md))
2. SSH into your NAS and stop the services:
   ```bash
   docker compose -f docker-compose.arr-stack.yml down
   ```
3. Extract backup and restore each volume:
   ```bash
   tar -xzf backup.tar.gz
   cd arr-stack-backup-20241217

   for dir in */; do
     vol="arr-stack_${dir%/}"
     echo "Restoring $vol..."
     docker run --rm \
       -v "$(pwd)/$dir":/source:ro \
       -v "$vol":/dest \
       alpine cp -a /source/. /dest/
   done
   ```
4. Start services:
   ```bash
   docker compose -f docker-compose.arr-stack.yml up -d
   ```

### Single Volume Restore

```bash
# On NAS via SSH - example: restore seerr config
docker compose -f docker-compose.arr-stack.yml stop seerr

docker run --rm \
  -v ./backup/seerr-config:/source:ro \
  -v arr-stack_seerr-config:/dest \
  alpine cp -a /source/. /dest/

docker compose -f docker-compose.arr-stack.yml start seerr
```

---

## Script Options

```bash
./scripts/arr-backup.sh [OPTIONS] [BACKUP_DIR]

Options:
  --tar           Create .tar.gz archive (recommended)
  --prefix NAME   Override volume prefix (default: auto-detect)

Examples:
  ./scripts/arr-backup.sh --tar                    # Default location
  ./scripts/arr-backup.sh --tar /path/to/backup    # Custom location
  ./scripts/arr-backup.sh --prefix media-stack     # Custom prefix
```

### Volume Prefix Auto-Detection

The script auto-detects your volume prefix from running containers. If you cloned the repo to a different directory (e.g., `media-stack` instead of `arr-stack`), it will detect this automatically.

If auto-detection fails, use `--prefix`:
```bash
./scripts/arr-backup.sh --tar --prefix media-stack
```

### Request Manager Detection

The script auto-detects which request manager volume exists and backs it up:
- `seerr-config` (Seerr)
- `overseerr-config` (Overseerr, if used instead)

---

## Automated Daily Backup

> **NOT CURRENTLY CONFIGURED — verified on the live NAS 2026-08-30.** This section
> used to say the cron job below was "already configured". There is no
> `/mnt/arr-backup`, no `/var/log/arr-backup.log`, and no `arr-stack-backup-*`
> file on any of the five mounted USB devices (`/mnt/@usb/sd{a,b,c,f,g}1`). No
> daily USB backup has ever run. The only backups that exist are the pre-deploy
> ones in `/volume1/docker/arr-stack-backups`. Treat the block below as the
> procedure for setting it up, not a description of current state.

To run a daily backup to USB at 6am:

```bash
# View current cron
sudo crontab -l

# Add:
0 6 * * * $NAS_STACK_DIR/scripts/arr-backup.sh --tar --rotate-days 7 /mnt/arr-backup >> /var/log/arr-backup.log 2>&1
```

Mount the USB drive at `/mnt/arr-backup` first, or use `--usb <dir-name>` so the
script finds the device by content rather than by a letter that changes on reboot.

> **`--rotate-days 7` is required as of 2026-08-30.** Rotation used to happen implicitly whenever a destination was given. It is now opt-in, so a cron line without this flag will fill the USB. Conversely, **never pass `--rotate-days` at a directory managed by `backup-prune.sh`** — see the warning under *Automated Pre-Deploy Backup*.

**Features:**
- ✓ Backs up to `/tmp` first (reliable), then moves to USB
- ✓ Checks actual tarball size vs destination space before moving
- ✓ Falls back to `/tmp` if USB lacks space (with warning)
- ✓ With `--rotate-days N`, deletes backups older than N days and prints each one
- ✓ EXIT trap ensures critical services stay running no matter what
- ✓ Does NOT stop services during backup

**To modify the schedule:**
```bash
sudo crontab -e
# Change "0 6" to preferred hour (e.g., "0 4" for 4am)
```

---

## Automated Pre-Deploy Backup (GitHub Actions)

`.github/workflows/nas-auto-deploy.yml` (see that file's header comment for the full pipeline, and CLAUDE.md's *Deploying to the NAS* section for how this relates to the manual branch-first workflow) backs up before every deploy it runs, to a separate location from the daily cron backup above: `/volume1/docker/arr-stack-backups/` on the NAS itself, not the USB drive. It reuses `scripts/arr-backup.sh --tar` unchanged (same volume list as above) and runs `scripts/backup-prune.sh` on that directory. `arr-backup.sh` stamps tarballs `arr-stack-backup-YYYYMMDD-HHMMSS.tar.gz` itself, so the workflow no longer renames them; before 2026-08-30 it stamped by day only and the workflow had to rename each tarball to stop same-day runs clobbering each other.

> **Never pass `--rotate-days` at this directory.** Its retention belongs to `backup-prune.sh` alone. On 2026-08-30 a manual `arr-backup.sh --tar /volume1/docker/arr-stack-backups` destroyed the entire backup history: the script then applied a silent, non-optional `find -mtime +7 -delete` to any destination it was given, and every existing tarball was 14 days old. Nothing was printed and stderr was suppressed. That rotation is now opt-in, and this is why.

**Retention is GFS (Grandfather-Father-Son) tiered, not flat 7-day**, since this runs on every deploy rather than once a day and a flat "keep everything for 7 days" policy would grow unbounded over months of frequent deploys:

| Age | Kept |
|-----|------|
| ≤ 7 days | every backup |
| 7–30 days | newest per calendar day |
| 30–180 days | newest per ISO week |
| > 180 days | newest per month, capped at 12 total |

This mirrors the retention scheme restic/BorgBackup/Time Machine use. Run `./scripts/backup-prune.sh <dir>` manually against any directory of `arr-stack-backup-*.tar.gz` files to apply the same thinning elsewhere.

**Required GitHub repo secrets** (Settings → Secrets and variables → Actions):

| Secret | Value |
|--------|-------|
| `TS_AUTHKEY_CI` | A reusable Tailscale auth key ([admin console](https://login.tailscale.com/admin/settings/keys)) so the GitHub runner can join the tailnet and reach the NAS |
| `NAS_SSH_HOST` | The NAS's Tailscale MagicDNS name (`arr-stack-nas`, per `docker-compose.tailscale.yml`'s `TS_HOSTNAME`) |
| `NAS_SSH_USER` | SSH user on the NAS |
| `NAS_SSH_KEY` | Private half of a **dedicated CI deploy keypair** — generate a fresh one (`ssh-keygen -t ed25519 -f ci_deploy_key -N ""`), add the public half to that user's `~/.ssh/authorized_keys` on the NAS, don't reuse a personal key |

Also requires Settings → Actions → General → Workflow permissions → **Read and write permissions**, so the default `GITHUB_TOKEN` can push to `main` / merge PRs.

The e2e step runs `npm run test:e2e` **on the NAS itself** over SSH (not from the GitHub runner) so the tests gated on local Docker access (VPN egress/leak/killswitch, zombie-container checks — see `tests/e2e/helpers.ts`'s `DOCKER_AVAILABLE`) actually run instead of skipping. This assumes Playwright's browsers are already installed on the NAS (`npx playwright install --with-deps chromium`, one-time) and `.env.e2e` is already populated there, same as for a manual `npm run test:e2e` run.

---

## Troubleshooting

### "Permission denied" errors
The backup script runs docker containers which handle permissions internally. If you see permission errors, ensure:
- You're in the docker group: `groups` should show `docker`
- Docker daemon is running: `docker ps`

### "Volume not found"
- Ensure services have been started at least once (volumes are created on first run)
- Check the volume prefix matches: `docker volume ls | grep config`

### Backup too large
If backup exceeds ~60MB, check if optional volumes were accidentally included. The script only backs up essential configs by default.
