# NAS Load Incident — 2026-09-18

Audited record of the host-level I/O stall that took every service on the NAS
down on 2026-09-18. Written 2026-09-19 from measurements taken during and after
the incident.

Everything below was reconstructed from live readings that no longer exist:
`/proc/pressure/io` counters reset on reboot, Beszel's database was never
populated, and the journal carries only host-level messages because container
logs go to Docker's json files. It was recoverable this time because the box
happened to be calm enough to read. It will not be next time. The three guards
described in [§6](#6-what-was-done-about-it) are committed to
`fix/nas-load-protection` and are **not deployed**.

## 1. What happened

From about 11:51 on 2026-09-18 until the box was rebooted at 23:33, the NAS sat
in sustained I/O starvation: load average 58.55 on 8 cores, `/proc/pressure/io`
`full avg10` between 78% and 81%, 0% CPU idle and 67-86% iowait. Every service on
it accepted TCP connections and answered nothing. `.lan` names still resolved in
3 ms and Traefik still completed TCP handshakes in 3-6 ms, which is why the first
reading of it was a DNS or proxy fault. It was not: the intermittent name
resolution failures were a symptom of the stall, not its cause.

The same readings after the reboot, for contrast: I/O full-stall 1.86%, load
average 2.43, memory full-stall 2.00%.

### Measured

| Measurement | Value |
| --- | --- |
| Sustained I/O full-stall, incident | 78-81% (`/proc/pressure/io`, `full avg10`) |
| I/O full-stall, healthy (after reboot) | 1.86% |
| Load average, incident / healthy | 58.55 / 2.43 (8 cores) |
| CPU idle / iowait, incident | 0% idle, 67-86% iowait |
| `kswapd0` | pinned at 100% CPU |
| Memory PSI full-stall, incident / healthy | 88.12% / 2.00% |
| Disk reads vs download throughput | 136 MB/s vs 3 MB/s |
| Jobs the blackhole submitted in one hour | 46 |
| Jobs left incomplete | 60 of 64 |
| NZBs queued | 531 (488 still queued at the reboot) |
| duc re-index on container start | 2.9 Tb, 842.4K files, 139.8K directories |
| TorBox concurrent usenet slot limit | 10 |
| `FETCH_WORKERS` | 3 |

## 2. The timeline

All times BST.

| When | Event |
| --- | --- |
| Sep 17 22:00-23:00 | 91 NZBs land |
| Sep 17 22:20 | Stremio library baselined (`stremio-library-sync-state.json`, `baselined_at` 2026-09-17T21:20:53Z) |
| Sep 17 22:41 | 108-item backfill starts (`backfill_started_at` 2026-09-17T21:41:12Z, `handled: 108`) |
| Sep 18 05:00-06:00 | 113 + 44 NZBs land |
| Sep 18 10:00-12:00 | 43 + 61 + 47 NZBs land (531 total) |
| Sep 18 11:45-12:20 | Sonarr: `DownloadDecisionMaker: Processing 932 releases`, mass episode searches, `Adding Series [391153][Peacemaker]` |
| Sep 18 11:51:04 | Six services flip DOWN within 5 ms — a system-wide stall, not individual failures |
| Sep 18 11:53 | Blackhole pass starts; services recover briefly |
| Sep 18 12:18 | Rolling cascade begins and never clears |
| Sep 18 12:46:59 | First `queue-cleanup` hard failure (Sonarr unreachable) |
| Sep 18 15:45, 17:45, 19:45, 20:12, 20:32 | Batches of containers restart |
| Sep 18 21:00 | Blackhole submits 46 jobs in one hour |
| Sep 18 23:07-23:14 | duc re-indexes 842.4K files / 2.9 Tb on restart |
| Sep 18 23:33 | Shutdown (previous boot ends; next begins 2026-09-19 00:05:06) |

The three NZB waves are the trigger, not the load: 91, then 113, then 61, against
an ingest path with no ceiling on how many of them became live TorBox jobs at
once.

## 3. The mechanism

A feedback loop, all of it measured rather than inferred:

writes fill page cache → reclaim thrashes (`kswapd0` pinned at 100% CPU, memory
full-stall 87.78%) → healthchecks time out → `deunhealth` and `restart: always`
restart containers → each restart re-reads `overlay2` image layers, and duc
re-walks the whole volume → more I/O.

PSI's `avg10` is a rolling ten-second average, so the two memory full-stall
figures in this document (87.78% here, 88.12% in the table above) are samples
taken at different moments in the same stall.

The fingerprint that identifies it is **136 MB/s of disk reads against 3 MB/s of
downloads**: a box re-reading itself, not one busy downloading.

## 4. What it was not

Each of these was checked and ruled out, and saying so is the point — the first
two were wrong guesses made during the investigation.

- **Not OOM.** The previous boot's kernel journal contains no `oom-kill` or
  `Memory cgroup out of memory` entry at all. radarr's `Exited (137)` was a
  SIGKILL from a restart whose stop grace period expired, not the OOM killer.
- **Not the blackhole's download volume.** `FETCH_WORKERS = 3`, and observed
  throughput was ~3 MB/s. It was the trigger, not the load.
- **Not disk-full** — 3.0 TB of 19 TB used.
- **Not DNS, routing, or Traefik.** `.lan` names resolved correctly (3 ms),
  Traefik's port 80/443 completed TCP handshakes in 3-6 ms, closed ports returned
  proper RSTs. The name resolution failing intermittently was a symptom of the
  stall, not its cause.

## 5. Why nothing recovered on its own

The four timers that exist to clear a stuck queue — `queue-cleanup`,
`backlog-search`, `indexer-guard`, `stremio-library-sync` — were all failing
against the apps they drive, because the apps were the thing that was starved.
Each one needed a healthy arr to do its job, and none of them had one.

## 6. What was done about it

Three guards, committed to `fix/nas-load-protection`:

- [`scripts/usenet-blackhole.service`](../scripts/usenet-blackhole.service) —
  caps in-flight TorBox jobs at 6, below the provider's ten concurrent slots.
- [`scripts/usenet-blackhole.sh`](../scripts/usenet-blackhole.sh) — refuses to
  start a pass while the host is already I/O-stalled, reading PSI's `full avg10`
  and tripping at 20%, against a measured healthy baseline of 1.86%. It fails
  open, and announces every state that leaves the gate inert. A skipped pass
  leaves a line in the pass log, `logs/usenet-blackhole.log`, and one in
  `logs/usenet-blackhole-skipped.log`; the status page reads the second and says
  "last pass skipped: host I/O stalled … N in a row" above the table. It has to
  say it there: the state file and the failed log the page otherwise renders are
  both written by the pass the gate refused to start, so a long stall leaves
  every in-flight job looking `stalled` under a fresh `Generated` timestamp with
  the reason appearing nowhere.
- [`duc-service/app/startup.sh`](../duc-service/app/startup.sh) — skips the
  start-up re-index when the index is younger than 20 hours, so `restart: always`
  stops meaning "re-walk 2.9 Tb".

**These are committed, not deployed.** The NAS has not been synced or
`daemon-reload`ed, and the installed unit under `~/.config/systemd/user/` is a
plain copy rather than a symlink, so the two can drift with nothing to say so. As
of this writing the NAS still runs uncapped. The deploy is a deliberate single
pass performed after all four tasks, because leaving the NAS on a feature branch
between tasks is itself a documented hazard in this repo. Anyone reading this
document to conclude the box is protected has read it wrong, and that
misreading is the failure this record exists to prevent.

## 7. What is still open

Two items are live on the box right now, not architectural:

- **488 NZBs were still queued at the reboot**, and the blackhole timer is
  currently inactive, so nothing is submitting. Both need a decision before this
  ingest path is exercised again.
- **The user timers did not arm after that reboot.** On the boot after this
  incident the user manager started at 00:05:04, 29 seconds after boot, while the
  unit files live under `/home`, a separate btrfs subvolume on the LVM/md pool.
  `timers.target` came up active and empty, and all eight user timers were left
  inactive while `is-enabled` still reported every one of them as enabled.
  Confirming when `/home` actually mounts relative to `user@1000.service` is a
  prerequisite for fixing it; that is a plan of its own.

The rest is capacity, and no guard in this repo removes it:

- `overlay2` shares `/volume1` with the media library, so container churn
  competes with downloads for the same two disks.
- 7.7 GB of RAM carries 30 containers.
- **Beszel's `data.db` is entirely empty** — zero rows in `systems`,
  `system_stats`, `container_stats` and `system_details`. The hub was never given
  a system, so the stack's own metrics layer recorded nothing across the whole
  incident. The only reason a timeline exists at all is Uptime Kuma's 8 monitors,
  covering 8 endpoints out of 30 containers.
- The restart cascade itself is undamped: `deunhealth` restarts 7 labelled
  containers when they go unhealthy, `restart: always` restarts anything that
  exits, `gluetun-recover` restarts the containers whose network namespace dies
  with a gluetun restart, and gluetun is restarted by `gluetun-rotator` every 6
  hours and by `indexer-guard` on an indexer ban. Under I/O starvation that is
  the loop in §3, and damping it means weakening healthchecks, which hides real
  failures.
