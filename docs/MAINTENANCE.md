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

### After every reboot: the user timers may not have armed

The eight `--user` timers can come up inactive after a reboot, and nothing on the
box says so. The user manager starts before `/home` is usable, so it reads
`~/.config/systemd/user/` while that directory is not yet there, loads none of
the unit files, and brings `timers.target` up active and empty. `is-enabled`
reports every timer as enabled the whole time and the `timers.target.wants/`
symlinks stay intact, so every signal a person would check looks correct.

Measured twice. 2026-09-19: `user@1000.service` active 00:05:06, `home.mount`
00:05:36. 2026-09-20: `user@1000.service` active 19:07:38, `home.mount`
19:08:06 — and on that boot the manager had not loaded a single unit file by the
time someone started one by hand at 19:22.

Check, then fix:

```bash
./scripts/check-user-timers.sh     # exit 0 running, exit 1 dead; names the remedy
./scripts/rearm-user-timers.sh     # daemon-reload, then start timers.target
systemctl --user list-timers       # confirm NEXT is set, not just that eight print
```

Both steps are required and the order matters. `daemon-reload` makes the unit
files visible to the running manager and starts nothing; `start timers.target`
is what arms them. A reload alone leaves all eight listed with `NEXT` at `-`,
which reads like success. Measured on this box 2026-09-20: a stopped but enabled
timer, with `timers.target` already active, is re-armed by
`systemctl --user start timers.target`.

**This is automated.** `scripts/arr-stack-user-timers.service` is a *system*
unit, not a `--user` one, that runs the rearm script as leoleg once the user
manager is up. The script polls for the unit directory rather than ordering on a
mount, because UGOS mounts the volumes outside systemd's view. Install once,
with root:

```bash
sudo install -m 644 scripts/arr-stack-user-timers.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now arr-stack-user-timers.service
```

A drop-in adding `RequiresMountsFor=/home/leoleg` to `user@1000.service` was
tried first, on 2026-09-20, and does nothing: `home.mount` has an empty
`FragmentPath`, so it does not exist as a unit until UGOS has already performed
the mount, and the directive therefore has nothing to order against.

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
| --- | --- | --- |
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

## Holding the usenet ingest down

`usenet-blackhole.timer` is a user timer, and `arr-stack-user-timers.service`
re-arms every enabled timer in `timers.target.wants` about 29 seconds after a
boot. A `systemctl --user stop` therefore lasts only until the next reboot, and
a reboot is not a way to hold this path down.

To hold it down across boots, disable it rather than stopping it, and put it
back explicitly:

```bash
# Hold down (survives a reboot, because `is-enabled` stays disabled)
systemctl --user disable --now usenet-blackhole.timer

# Confirm: this must print `disabled`, not `enabled`
systemctl --user is-enabled usenet-blackhole.timer

# Release
systemctl --user enable --now usenet-blackhole.timer
```

Do **not** `mask` the timer as a hold. `scripts/rearm-user-timers.sh` exits 1
whenever any `*.timer` in the unit directory is inactive, so a masked timer
turns a deliberate hold into a failed system unit on every boot.

**Do not start the pass, re-arm the timer, or reboot the NAS while the outbox
is deep.** As of 2026-09-20 the queue stands at 588 NZBs with 21 releases
already complete at TorBox and owed a local download, including four staged
`payload.zip` files of 33.19, 27.59, 12.10 and 9.04 GB. The first pass after an
unplanned boot fetches a full round of those onto a pool whose metadata is
already at 91.5%.

**Do not delete the staging directory to reclaim the 113 GB it holds.** Every
one of those directories is a live key in `logs/usenet-blackhole-state.json`,
`sweep_staging` keeps them on purpose, and `fetch` wipes and re-downloads its
own staging path anyway. Deleting them frees space and buys nothing.

### Measuring whether one fetch stream beats three

`FETCH_WORKERS` is 3, and no one has measured whether three concurrent fetches
finish more releases per hour than one on this pool. The only observation is a
single pass that cannot separate the concurrency from a 21-release pile-up, a
flapping gate, a Time Machine client and Docker churn.

With the ingest held down and the box quiet, patch `FETCH_WORKERS` to 1 on a
branch, sync, and hand-run one pass with this sampler alongside. It reads
`/proc` only and needs no root:

```bash
while :; do
  printf '%s ' "$(date +%s)"
  awk '/^full/{print $2, $3}' /proc/pressure/io
  for d in sda sdb; do printf '%s ' "$(cut -d' ' -f1-8 /sys/block/$d/stat)"; done
  echo
  sleep 1
done
```

Read off two numbers: releases completed per minute, and the delta in fields 3
and 7 of `/sys/block/*/stat` (sectors read and written) per release. If one
stream delivers 80% or more of the three-stream rate, set `FETCH_WORKERS` to 1 —
the array is two rotational spindles, and the concurrency is buying queue depth
rather than throughput. Record the two rates here when it is done.

### Storage steps that are not in this repo

These are host configuration on the NAS, applied by hand and persisted by
UGOS-side mechanism, in the same category as the macvlan shim and the UGOS
firewall rules. Run them with the ingest held down and the box quiet.

**btrfs metadata is at 91.5% of its allocated chunk.** `/volume1` reported
Metadata,DUP 4.58 GiB used of 5.00 GiB, against a `max_commit_ms` of 38,952 —
the healthy reference in `btrfs(5)` is 2 ms.

```bash
btrfs filesystem usage -h /volume1          # before
btrfs balance start -musage=50 /volume1     # the balance itself is I/O heavy
btrfs filesystem usage -h /volume1          # after: expect Used below 60%
cat /sys/fs/btrfs/*/commit_stats            # compare last_commit_ms before/after
```

**The two mirror legs disagree about request size.** `sda` has
`max_sectors_kb=512` and `sdb` has `2048`, on identical
`WDC WD201KFGX-68` firmware. RAID1 inherits the minimum, and `sda` issued 8.8%
more write requests for byte-identical totals. Raise the smaller one, then
confirm both legs report the same value and that their request counts converge:

```bash
for d in sda sdb; do echo "$d $(cat /sys/block/$d/queue/max_sectors_kb)"; done
echo 2048 > /sys/block/sda/queue/max_sectors_kb     # needs root
```

**Lower the dirty-page ceiling.** The box has 7.88 GB of RAM, and
`vm.dirty_ratio=20` permits 1.58 GB of dirty pages. Three concurrent downloads
plus an extract plus a RAR unpack can cross that in seconds. This reduces peak
throughput on a rotational array, so measure before adopting it:

```bash
sysctl vm.dirty_bytes vm.dirty_background_bytes
```

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
| `logs/usenet-blackhole-failed.log` | releases TorBox failed, that stalled past `--stall-hours`, or that passed `--timeout-hours` |
| `logs/usenet-blackhole-state.json` | what is in flight. **Do not delete it** |
| `logs/usenet-blackhole-skipped.log` | one line per pass the I/O pressure gate refused to start. Its presence means the last pass was skipped, and the status page reads its line count as "N in a row" |

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

## Usenet Status Page (systemd timer, every 2 minutes)

`scripts/usenet-blackhole-status.sh` renders the same state file as a
self-contained HTML page, and `docker-compose.utilities.yml`'s `usenet-status`
serves it at `https://usenet.lan` (Traefik's `usenet-lan` router, basic auth,
no host port published; see [UTILITIES.md](UTILITIES.md#usenet-status-setup)).
`scripts/usenet-status-render.timer` is what keeps the served file current.

```bash
# The served directory must exist before the container mounts it: `docker
# compose up` creates a missing bind-mount source itself, as root, and this
# user-level unit then cannot write into it. The unit creates it too, so this
# line is only a belt-and-braces step for a first install.
mkdir -p /volume1/docker/arr-stack/logs/usenet-status

cp scripts/usenet-status-render.service scripts/usenet-status-render.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now usenet-status-render.timer
systemctl --user start usenet-status-render.service      # render now, and create the directory
systemctl --user list-timers usenet-status-render.timer  # confirm it is armed

docker compose -f docker-compose.utilities.yml up -d usenet-status
```

The unit creates the directory itself on every run, so a re-install never
depends on the manual `mkdir` above, but the order in that block does matter:
start the render once **before** the container, or the container's own
root-owned copy of the directory wins and the render fails with a permission
error from then on (`systemctl --user status usenet-status-render.service`
shows it, and the fix is to remove the directory as root and render again).

Two minutes, matching the blackhole timer: the page reports on what that timer
is doing, so a faster refresh buys nothing and two minutes is the longest a
just-grabbed release can be missing from it. A render reads two local files and
writes a few KB, with no API call and no credential anywhere in the loop; the
unit deliberately carries no `EnvironmentFile`.

Deploying this needs the two live-NAS steps any new `.lan` host needs, neither
of which is synced by `git pull`:

```bash
# 1. Pi-hole must answer for the name (see pihole/dnsmasq.d/02-local-dns.conf.example).
#    Edit it on the NAS, then:
docker restart pihole
# 2. traefik/certs/lan-admin.crt must carry usenet.lan in its SAN list, or the
#    -secure router fails the TLS handshake under sniStrict. Regenerate the
#    cert with usenet.lan appended and redeploy it: see
#    docs/HTTPS-LOCAL.md, "adding a new .lan admin host".
```

| Path | What it is |
| --- | --- |
| `logs/usenet-status/index.html` | the served page, generated; do not edit by hand |
| `logs/usenet-status-render.log` | the render script's banner (its stdout is the document) |

---

## Stremio Library Sync (systemd timer, every 10 minutes)

Adding a title to the Stremio library does nothing on this stack by itself.
Nothing watches for it, so the film sits in Stremio's library and never reaches
Radarr or Sonarr. This bridges the two: it reads the Stremio account's library
every 10 minutes, resolves anything newly added to a TMDB id, and creates the
Seerr request that routes it to the arrs.

```bash
# Dry run — see what it would request. Writes no state and requests nothing.
./scripts/stremio-library-sync.sh

# Actually create the requests
./scripts/stremio-library-sync.sh --apply

# Per-item detail, including the state file's size
./scripts/stremio-library-sync.sh --apply -v

# At most one request this pass
./scripts/stremio-library-sync.sh --apply --max 1
```

**First run baselines and requests nothing.** It records every title already in
the library and stops. That is not a bug and it is the most important thing on
this page: measured 2026-09-17, 122 of this library's 145 items are in neither
arr, and requesting them in one pass is the shape of the burst that earned this
TorBox account a 90-minute refusal. To bring them in deliberately:

```bash
./scripts/stremio-library-sync.sh --apply --backfill --max 3
```

Run that by hand, repeatedly, over days — the timer will not do it for you,
because `--backfill` only means anything on a first run and the timer passes no
such flag. Each pass creates at most `--max` requests (default 3) and leaves the
rest for the next one, so a backlog drains in the order the titles were added.

Install once, as the deploy user — no root:

```bash
mkdir -p ~/.config/systemd/user
cp scripts/stremio-library-sync.service scripts/stremio-library-sync.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now stremio-library-sync.timer
systemctl --user list-timers stremio-library-sync.timer   # confirm it is armed
systemctl --user start stremio-library-sync.service       # baseline now, rather than in a minute
```

Output goes to `logs/stremio-library-sync.log`, and what has been handled to
`logs/stremio-library-sync-state.json`. The unit exits non-zero when a request
could not be created, so `systemctl --user status stremio-library-sync.service`
shows an unreachable Seerr rather than leaving it only in the log.

**When it stops finding anything.** The Stremio API answers HTTP 200 with an
`error` body for an expired key rather than a 401, so the symptom is not an
error anywhere except this log. It reads:

```
ERROR: HTTP None from https://api.strem.io/api/datastoreGet: Stremio rejected the auth key: Session does not exist
```

Log in at [web.stremio.com](https://web.stremio.com) again and re-copy
`auth.key` into `STREMIO_AUTH_KEY`, as `.env.example` describes. If instead it
reports a plausible library size and nothing new, the key is fine and nobody has
added anything.

**The other way it stops, and the one that already cost ten hours.** A run that
reports a library size and then ends in a `403` from `v3-cinemeta.strem.io`
(`error code: 1010`) is neither your key nor rate limiting: it is Cinemeta's
Cloudflare rule refusing the client's `User-Agent`. Cinemeta redirects to
`cinemeta-live.strem.io`, and that host blocks urllib's default
`Python-urllib/3.11` signature while answering any other name. The module sends
one (`USER_AGENT`) for exactly this reason, so seeing the 403 again means the
header was dropped in an edit rather than that anything upstream changed.

Measured before the header went in: one failed pass every ten minutes from 00:43
to 10:52 on 2026-09-18, each dying on the same title and creating no request. A
failed lookup is now handled per title — the item stays pending and the pass
carries on — so an unreachable provider costs three lookups and a non-zero exit
instead of a stalled queue.

What it deliberately does not do:

- **Nothing is deleted.** Removing a title from the Stremio library is not
  wired to anything here. A library edit is a low-stakes action on a phone, and
  connecting it to a delete from disk is not a trade worth making silently.
- **Nothing is guessed from a title.** An id it cannot resolve — `kitsu:` and
  anything else a catalog invents — is logged, recorded once so the timer does
  not re-log it forever, and skipped. Falling back to a name search is how the
  wrong film gets downloaded, which is worse than a miss.

| Path | What it is |
| --- | --- |
| `logs/stremio-library-sync.log` | one banner per pass, and what it requested |
| `logs/stremio-library-sync-state.json` | every item handled, and how |

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
