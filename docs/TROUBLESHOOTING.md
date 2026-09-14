# Troubleshooting

## Gluetun: Harmless Log Noise on Startup

**Symptom:** Two scary-looking lines in `docker logs gluetun` even though the VPN appears to be working:

```
ERROR [vpn] getting public IP address information: persisting public ip address: open /tmp/gluetun/ip: permission denied
INFO  [healthcheck] listening for ICMP packets: not permitted: you can try adding NET_RAW capability to resolve this; permanently falling back to plain DNS over UDP checks
```

**Cause:** Both are non-fatal. The first is gluetun unable to cache the detected public IP to a file inside the container — the VPN connection itself is unaffected. The second is gluetun's healthcheck wanting to ping; we drop `NET_RAW` for security, so it falls back to DNS lookups (still a valid health signal).

**Confirm the VPN is actually working:**
```bash
# Should print your VPN exit IP, NOT your home IP
docker exec gluetun wget -qO- https://ifconfig.me
```

If that shows a different IP from your home connection, gluetun is fine — leave the warnings alone. If it shows your real IP (or times out), see the gluetun logs for `tunnel down`, `auth failed`, or the container restarting — those are the actual failure modes worth chasing.

## Indexers: New Releases Never Grab (VPN Exit Country Blocked)

**Symptom:** A monitored episode/movie that is clearly out (aired days ago) never gets grabbed. Sonarr/Radarr history is empty for it, nothing is in the queue, and an interactive search returns **0 releases**. Prowlarr health shows `Indexers unavailable due to failures for more than 6 hours: EZTV` (or another indexer), and that indexer is auto-disabled.

**Cause:** The VPN exit is in a country that legally blocks the indexer. Our stack defaults to `VPN_COUNTRIES=United Kingdom`, and the UK now serves Cloudflare-level legal blocks for several public torrent indexers. The block returns **HTTP 451** with a body like:

```
In response to a legal order, Cloudflare has taken steps to limit access
to this website through Cloudflare's pass-through security and CDN services
within United Kingdom.
```

Prowlarr (and all `*arr` indexer traffic) rides the gluetun tunnel, so every query exits through the blocked country. EZTV — the indexer most likely to carry a niche/new TV release — is the usual casualty.

**Diagnose:**
```bash
# 1. Confirm the VPN exit country
docker exec gluetun wget -qO- https://ipinfo.io/json   # look at "country"

# 2. Test the failing indexer in Prowlarr (id 3 = EZTV here; GET /indexer to list ids)
PK=<prowlarr-apikey>
curl -s -X POST "http://localhost:9696/api/v1/indexer/test?apikey=$PK" \
  -H "Content-Type: application/json" \
  -d "$(curl -s http://localhost:9696/api/v1/indexer/3?apikey=$PK)"
# "UnavailableForLegalReasons" / 451 in the error = legal block, not a dead indexer

# 3. Which indexers are in backoff
curl -s "http://localhost:9696/api/v1/indexerstatus?apikey=$PK"
```

**Fix — switch the VPN exit out of the blocking country:**
```bash
cd /volume1/docker/arr-stack
cp .env ".env.bak-$(date +%Y%m%d-%H%M%S)"          # .env is gitignored — edit on the NAS
sed -i 's/^VPN_COUNTRIES=United Kingdom$/VPN_COUNTRIES=Netherlands/' .env

# Recreate gluetun AND every container sharing its network namespace
# (sabnzbd, prowlarr, flaresolverr, vpn-socks5 — all bounce together)
docker compose -f docker-compose.arr-stack.yml up -d

# Verify the new exit + that the indexer is reachable again
docker exec gluetun wget -qO- "https://eztvx.to/api/get-torrents?limit=1"   # HTTP 200 = unblocked

# Clear the indexer backoff so Prowlarr queries it again (disable then re-enable)
DEF=$(curl -s "http://localhost:9696/api/v1/indexer/3?apikey=$PK")
echo "$DEF" | python3 -c 'import sys,json;d=json.load(sys.stdin);d["enable"]=False;print(json.dumps(d))' \
  | curl -s -X PUT "http://localhost:9696/api/v1/indexer/3?apikey=$PK" -H "Content-Type: application/json" -d @-
echo "$DEF" | curl -s -X PUT "http://localhost:9696/api/v1/indexer/3?apikey=$PK" -H "Content-Type: application/json" -d @-
```

Surfshark's WireGuard key is account-wide, so changing only `VPN_COUNTRIES` is enough — gluetun picks a server in the new country with the same key. No new config from Surfshark is needed. The VPN only covers the tunneled services (usenet, indexer scraping, Prowlarr, FlareSolverr), **not** Jellyfin or Decypharr, so a non-UK exit has no downside for playback. Leave it on a non-blocking country (e.g. Netherlands) to avoid recurrence; revert with the `.env` backup if ever needed.

> **Diagnostic gotcha — Prowlarr masks API keys.** `GET /api/v1/indexer/<id>` returns indexer secrets as a short placeholder, **not** the real key. If you curl an indexer's newznab API directly using that masked value you'll get `<error code="102" description="Empty API Key"/>` and zero results — which looks like a dead indexer but isn't. Prowlarr's own searches use the real key (32 chars for NZBgeek). Read the real value from `prowlarr.db` (`Indexers.Settings` JSON) before testing by hand, or just trust Prowlarr's search rather than a manual curl.

## Indexers: All Slow / Intermittently Failing (Throttled VPN Exit Server)

**Symptom:** Searches feel broken but nothing is hard-down. An interactive search or `GET /api/v1/search` takes **~50s** instead of a second or two. Per-indexer tests are slow (10s+) or return **HTTP 500**, and the slowness hits *everything* riding the tunnel at once — including reliable paid indexers like NZBgeek that should never be slow. Crucially, this is **not** a 451/legal block, and `GET /api/v1/indexerstatus` may show **0 failures** because nothing has crossed the 6-hour auto-disable threshold yet. The web UIs of VPN-protected services (Prowlarr/SABnzbd) also feel laggy and jittery (response times jumping 10ms → 4s).

This can masquerade as unrelated problems: a `*.lan` service like `seerr.lan` "feeling slow" is **not** caused by this (that path is local and never touches the VPN) — but *triggering a search/request inside Jellyseerr* is, because that call fans out seerr → Sonarr/Radarr → Prowlarr → tunnel.

**Cause:** The specific WireGuard server gluetun happened to connect to is congested or throttled (or partially degraded). The country is fine — it's just a bad server, and gluetun will sit on it indefinitely. The exit IP resolves and basic reachability works (so it's not a tunnel-down or auth failure), it's just slow. Distinct from the geo-block case above (HTTP 451), which needs a *country* change.

**Diagnose:**
```bash
PK=<prowlarr-apikey>
# Aggregate search time — the headline symptom (healthy = ~1-2s, throttled = ~50s)
time curl -s "http://localhost:9696/api/v1/search?query=ubuntu&type=search&limit=5" -H "X-Api-Key: $PK" >/dev/null

# Per-indexer latency — throttled = several seconds each and/or HTTP 500
for id in $(curl -s "http://localhost:9696/api/v1/indexer" -H "X-Api-Key: $PK" | python3 -c 'import sys,json;[print(i["id"]) for i in json.load(sys.stdin)]'); do
  cfg=$(curl -s "http://localhost:9696/api/v1/indexer/$id" -H "X-Api-Key: $PK")
  code=$(printf '%s' "$cfg" | curl -s -o /dev/null -w '%{http_code} %{time_total}s' -X POST "http://localhost:9696/api/v1/indexer/test" -H "X-Api-Key: $PK" -H "Content-Type: application/json" --data-binary @-)
  echo "indexer $id: $code"
done

# Confirm the exit IP (note it, so you can verify it changes after the restart)
docker exec gluetun wget -qO- https://ipinfo.io/ip
```

**Fix — bounce gluetun onto a fresh server (same country, no `.env` change):**
```bash
cd /volume1/docker/arr-stack
docker restart gluetun                       # reconnects to a *different* server with the same key
# Wait for healthy (~50s), confirm the exit IP changed:
docker inspect -f '{{.State.Health.Status}}' gluetun
docker exec gluetun wget -qO- https://ipinfo.io/ip

# REQUIRED: restart every container sharing gluetun's network namespace.
# Restarting gluetun alone severs their networking — they go dead (empty/000 responses)
# until bounced too.
docker restart prowlarr sabnzbd flaresolverr vpn-socks5   # every container sharing gluetun's netns
```

Re-run the aggregate search to confirm it's back to ~1-2s. (Observed 2026-06-19: a throttled NL server gave a 54s search with two indexers at HTTP 500; `docker restart gluetun` + bouncing the dependents dropped it to **1.2s**, no config change.) If the new server is *also* slow, restart gluetun again to roll the dice on another. Only switch `VPN_COUNTRIES` (the section above) if you actually see HTTP 451 — that's a different problem.

## Apps Unreachable After a VPN Reconnect (Stale Network Namespace)

> **Note (v1.7.23):** Sonarr and Radarr were moved off the VPN onto the bridge, so they are **no longer affected** by this — a gluetun restart can't strand them. This section now applies only to the remaining VPN-bound apps: **SABnzbd, Prowlarr, FlareSolverr, vpn-socks5**.

**Symptom:** After gluetun restarts (VPN reconnect, server switch, or container recreate), some VPN-bound apps go unreachable from the rest of the stack even though `docker ps` shows them **Up (healthy)**. Classic tells: Prowlarr reporting FlareSolverr down, or Sonarr/Radarr unable to reach their download clients (grabs not starting). The affected container answers fine on its own `localhost` but refuses connections from anything else.

**Cause:** These services use `network_mode: "service:gluetun"`, so they share gluetun's network namespace. When gluetun restarts, that namespace is destroyed. Two things can happen to each dependent:
- It is SIGKILLed and stays **Exited** (docker can't rejoin a vanished namespace), or
- It keeps **running as a zombie** on the dead namespace — alive on `127.0.0.1`, invisible to the network, and its localhost healthcheck still passes so it shows green.

The second case is the nasty one: everything *looks* fine. `deunhealth` won't touch it (it's not unhealthy) and an exited-only watcher misses it.

**Auto-recovery (built in):** The `gluetun-recover` watcher handles both cases. On every gluetun `health_status: healthy` event it restarts any `gluetun.dependent=true` container that is Exited **or** whose `StartedAt` predates gluetun's current start (a stale-namespace zombie). No action needed — give it ~30-60s after gluetun goes healthy.

**Verify / manual fix if ever needed:**
```bash
# Any dependent started BEFORE gluetun is a stale zombie:
g=$(docker inspect -f '{{.State.StartedAt}}' gluetun | cut -c1-19); echo "gluetun: $g"
for c in sabnzbd prowlarr flaresolverr vpn-socks5; do
  echo "  $c: $(docker inspect -f '{{.State.StartedAt}}' $c | cut -c1-19)"
done
# Confirm reachability through the shared namespace:
docker exec seerr   wget -qO- http://gluetun:9696/ping   # prowlarr -> {"status":"OK"}
docker exec prowlarr wget -qO- http://127.0.0.1:8191/    # flaresolverr -> "ready" (use 127.0.0.1, it's IPv4-only)

# Manual recovery (gluetun-recover does this automatically):
docker restart sabnzbd prowlarr flaresolverr vpn-socks5   # or whichever started before gluetun
```

`./scripts/detect-vpn-zombies.sh` automates the check above — it compares each dependent's `network_mode` binding against Gluetun's *current* container ID and prints exactly which ones are stale, plus the correct recovery command for each. It's also exercised as `tests/e2e/resilience.spec.ts` in the Playwright suite. Run it any time you suspect a zombie, or on a schedule via cron/SSH.

⚠️ **The `docker restart` above only works if gluetun was restarted, not recreated.** Because that script compares *container IDs*, anything it flags is by definition the recreate case — where restart always fails. Jump to [After a Gluetun RECREATE](#after-a-gluetun-recreate-not-just-a-restart-docker-restart-cannot-save-you) instead.

## NEVER Use `--remove-orphans` (Multi-Compose-File Project)

This stack splits its services across several compose files (`docker-compose.arr-stack.yml`, `docker-compose.utilities.yml`, `docker-compose.traefik.yml`, …) that share **one project directory and project name**. To compose, any running container of the project that is not defined in the file you passed with `-f` is an *orphan*. So:

```bash
# DO NOT DO THIS — it deletes every container from the OTHER compose files:
docker compose -f docker-compose.arr-stack.yml up -d --remove-orphans
```

This happened for real on 2026-08-01 (~20:30 BST): a single `--remove-orphans` run removed **traefik, camera-listen, cloudflared, diun, uptime-kuma, beszel, beszel-agent, gluetun-recover, deunhealth, duc and configarr** in one stroke. Volumes and configs survived (downtime only), and everything had to be restored file by file.

The same split has a second face: **recreate a service only via the file that defines it.** Attachments and settings that live in one file are silently dropped if the container is ever brought up through another path — e.g. traefik's `traefik-lan` macvlan (its `192.168.1.11` LAN presence) exists only in `docker-compose.traefik.yml`; a traefik container created without that file comes up bridge-only and **every `.lan` URL dies while the container still reports healthy** (also observed 2026-08-01).

If you actually need to prune an orphan, remove that one container by name with `docker rm`.

### After a Gluetun RECREATE (not just a restart), `docker restart` cannot save you

Everything above assumes gluetun was **restarted** — same container, same ID. If gluetun is **recreated** (its config in the compose file drifted, so *any* `docker compose up -d`, even of an unrelated service like seerr, replaces it), the dependents' `network_mode: "service:gluetun"` still points at the **old container ID**. They are SIGKILLed (exit 137), and now `docker restart` — whether run by you or by `gluetun-recover` — fails with:

```
Error response from daemon: ... joining network namespace of container <old-id>: No such container
```

`gluetun-recover` logs this failure loudly but **cannot fix it** (it would need to run compose, which it can't). The only fix is a compose-level recreate of the dependents so they bind to the new gluetun container:

```bash
cd /volume1/docker/arr-stack
# Four of the five dependents live here; --force-recreate because compose will
# otherwise consider an "Up" (but zombie) container already up-to-date:
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate \
    sabnzbd prowlarr flaresolverr vpn-socks5
# magnetio-addon is defined in a DIFFERENT file and must go through it:
docker compose -f docker-compose.magnetio.yml up -d --force-recreate magnetio-addon
```

**Don't stop at the arr-stack file.** `vpn-socks5` and `magnetio-addon` are tunneled dependents too, and `magnetio-addon` is defined in `docker-compose.magnetio.yml` — recreating only the three "obvious" apps leaves the other two as zombies that still look healthy. `./scripts/detect-vpn-zombies.sh` prints the correct per-file commands for exactly the containers it found; prefer its output over any list written here, which can go stale.

Run `./scripts/detect-vpn-zombies.sh` afterward to confirm every dependent now binds to Gluetun's *new* container ID rather than the old one — this is the exact scenario it's built to catch.

#### Worked example: the 2026-08-27 outage

Downloads had been dead for 38 hours before anyone noticed, and the visible symptoms pointed nowhere near the cause: *"series won't download"* and *"Seerr seems to prefer torrents"*.

The chain, root cause first:

1. The NAS was still checked out on an **unmerged feature branch** (`feat/pi1-pi2-split`) from an earlier test. Nothing distinguishes that from a deployed state — see *Deploying to the NAS* in `CLAUDE.md`.
2. That branch sets `DNS_ADDRESS=${PI2_IP}`, pointing gluetun's resolver at pi2. The matching step that actually *moves* Pi-hole to pi2 had never run, so nothing was listening on `192.168.120.241:53`. (Not a firewall problem — `FIREWALL_OUTBOUND_SUBNETS` did include that subnet.)
3. gluetun's startup healthcheck could not resolve `cloudflare.com`/`github.com`, so it restarted the VPN roughly every 5 seconds — **failing streak 211**, a different WireGuard server each time.
4. A restart cycle recreated gluetun with a new container ID, orphaning all six dependents on the dead namespace.
5. `qbittorrent` and `sabnzbd` were SIGKILLed (exit 137). `prowlarr`, `flaresolverr` and `magnetio-addon` kept reporting **`Up (healthy)`** with *zero* internet, because their healthchecks only probe localhost.

Prowlarr being a healthy-looking zombie is what produced the user-visible symptom: every indexer search returned nothing, so Sonarr/Radarr weren't failing to grab — they were being handed an empty result set. Usenet looked "disabled" simply because SABnzbd was dead, while `decypharr` (on the `arr-core` bridge, *not* in gluetun's namespace) kept working — hence everything that did succeed arrived by torrent.

Recovery was: sync the NAS back to `main`, recreate gluetun via `docker-compose.arr-stack.yml`, then recreate all six dependents via their own compose files as above.

Two lessons worth carrying:

- **`gluetun-recover` cannot help here and ran uselessly for 38 hours.** It is a `docker restart` loop, and restart is precisely what a recreate breaks.
- **A localhost healthcheck proves nothing about reachability.** This is the same trap as *"an HTTP 200 is not proof you hit the right backend"*, one layer down: three containers were green and had no network at all. When diagnosing, assert on egress (`docker exec <c> curl -s https://api.ipify.org`), not on health status.

**If that compose command hangs:** a dependent that died mid-netns-join can land in a `Dead` state that dockerd can never remove (`docker rm -f` → "removal of container is already in progress", forever). Compose then wedges trying to replace it, or leaves the replacement under a hash-prefixed name (`<id>_flaresolverr`). The only cure is a Docker daemon restart, which also clears the Dead container (observed 2026-08-01 with flaresolverr; check nobody is streaming first):

```bash
sudo systemctl restart docker    # bounces the whole stack; ~2-3 min to settle
```

**Prevention:** before any `docker compose up -d <service>` on the arr-stack file, check whether gluetun would be recreated too, and plan for the dependents:

```bash
docker compose -f docker-compose.arr-stack.yml up -d --dry-run <service> 2>&1 | grep -i recreate
```

## The Deploy Reported Success and Nothing Was Deployed

The single most expensive failure shape in this repo. Every instance looks
identical from outside: **exit 0, and either silence or a cheerful message.** No
error to search for, no log line to grep, nothing in `docker ps`. The stack just
quietly keeps running the old code, and the gap between "deployed" and "not
deployed" is invisible until something downstream trips over it — 38 hours later,
in the worked example above.

Three separate bugs of this shape were live simultaneously until 2026-08-31, each
independently sufficient to break a deploy, stacked so that fixing any one of them
alone would have changed nothing observable.

| # | The bug | What it looked like from outside |
| --- | --- | --- |
| 1 | The `post-merge` hook derived its repo root from `${BASH_SOURCE[0]}` — which git sets to the path *inside* the git dir (`.git/hooks/post-merge`). Bash does not resolve that symlink, so `git -C .git/hooks rev-parse --show-toplevel` fatalled, `\|\| true` swallowed it, and an `exit 0` guard meant for "not a git repo" fired on **every merge**. | `git merge` printed its normal output. The hook produced not one character, ever. |
| 2 | `scripts/sync-nas.sh` exited 0 when the NAS was unreachable. | Indistinguishable from a successful sync. |
| 3 | The NAS pulls from **`origin`**, but the hook fires *during* the merge, before any push. The merge commit did not exist on origin yet. | `git pull` on the NAS: `Already up to date.` — exit 0, correct output, wrong commit. |

Note the third one especially: nothing there is broken. Every command did exactly
what it was asked. The remote genuinely was up to date with a ref that did not yet
contain the merge.

### The check that distinguishes them

Never ask whether the deploy command succeeded. Ask the NAS what it is holding —
**the branch, not only the commit.** A NAS on the right commit of the wrong branch
is the 2026-08-27 outage.

```bash
docker run --rm -v /volume1/docker/arr-stack:/repo -w /repo \
  alpine/git -c safe.directory=/repo rev-parse --abbrev-ref HEAD   # must be: main
```

Run that from the NAS (or over `ssh arr-stack-nas`). `git rev-parse --abbrev-ref HEAD`
on the deploy path is the **first** thing to check when diagnosing anything
stack-wide, before touching a single container.

`sync-nas.sh` now does this itself and reports `NAS NOT synced` on any failure, and
the hook refuses to push a dirty or diverged tree. But the reason all three survived
so long is worth more than the fixes: **`tests/hooks-installed.bats` passed the entire
time.** It asserted the hook symlink existed, was executable, and pointed at the right
target. All three were true. All three were irrelevant. Presence is not behaviour —
see `tests/nas-sync.bats`, which runs the hook against a throwaway repo with a real
origin and asserts on what it *did*, and `./tests/mutation/run-mutations.sh`, which
proves each of those assertions can actually fail.

## SABnzbd: Stuck Unpack Loop

**Symptom:** Radarr shows "Downloading" at 100% with 0 B file size. SABnzbd UI is unresponsive or Save fails. Logs show `Unpacked files []` repeatedly.

**Cause:** NZB had obfuscated filenames + par2 files but no RARs. The unpacker finds nothing to extract and retries on every SABnzbd restart, creating a new `_UNPACK_*` directory each time. Each copy is 20-50+ GB — this can silently eat TBs of disk space. The stuck post-processing loop also locks up SABnzbd's API and UI.

**Diagnose:**
```bash
# _UNPACK_ buildup = stuck unpack loop
ls -d /volume1/data/usenet/incomplete/_UNPACK_* | wc -l
du -shc /volume1/data/usenet/incomplete/_UNPACK_*

# Confirm in SABnzbd logs
docker logs sabnzbd --tail 200 2>&1 | grep "Unpacked files"
# "Unpacked files []" = nothing to unpack, stuck
```

**Fix:**
```bash
# 1. Stop SABnzbd (API will be unresponsive, must use docker stop)
docker stop sabnzbd

# 2. Delete the postproc queue to clear the stuck job
#    (The history API delete is NOT enough — the postproc queue is separate
#    and will re-trigger the loop on every restart)
sudo rm /volume1/@docker/volumes/arr-stack_sabnzbd-config/_data/admin/postproc2.sab

# 3. Delete all failed _UNPACK_ attempts to reclaim disk space
rm -rf /volume1/data/usenet/incomplete/_UNPACK_<release_name>*

# 4. Move the actual file (in incomplete/) to the movie folder
mkdir -p "/volume1/data/media/movies/MovieName (Year)"
mv "/volume1/data/usenet/incomplete/<release>/obfuscated.mkv" \
   "/volume1/data/media/movies/MovieName (Year)/MovieName (Year).mkv"
rm -rf "/volume1/data/usenet/incomplete/<release>"

# 5. Start SABnzbd back up
docker start sabnzbd

# 6. Remove from Radarr queue (get queue ID from queue API)
docker exec radarr curl -s -X DELETE \
  "http://localhost:7878/api/v3/queue/ID?removeFromClient=false&blocklist=false&apikey=KEY"

# 7. Tell Radarr to pick up the file
docker exec radarr curl -s -X POST "http://localhost:7878/api/v3/command" \
  -H "Content-Type: application/json" -H "X-Api-Key: KEY" \
  -d '{"name":"RefreshMovie","movieIds":[MOVIE_ID]}'
```

**Prevention:** No SABnzbd setting fully prevents this. Monitor disk usage (Beszel/duc) and investigate if a movie stays at "Downloading 100%" for more than 30 minutes.

## Pi-hole: Doesn't Start After Reboot

**Symptom:** After every NAS reboot, Pi-hole stays in `Exited (128)` state. All other containers start fine. Your network loses DNS resolution until you manually `docker start pihole`.

**Cause:** Pi-hole binds to `${NAS_IP}:53` (it can't use `0.0.0.0:53` because most NAS OS's run dnsmasq on `127.0.0.1:53`). If `NAS_IP` is assigned via DHCP, Docker starts before the DHCP handshake completes — the IP doesn't exist yet, the port bind fails with exit 128, and Docker's restart policy does not retry start failures (only process exits).

**Diagnose:**
```bash
# Check if Pi-hole is stopped
docker ps -a --filter name=pihole
# Look for: Exited (128)

# Check the error
docker inspect pihole --format "{{.State.Error}}"
# Look for: "listen tcp4 <IP>:53: bind: cannot assign requested address"

# Confirm your IP is from DHCP
ip addr show eth0 | grep inet
# "dynamic" = DHCP (the problem). No "dynamic" = static (correct).
```

**Fix:** Configure a static IP on the NAS itself (not just a DHCP reservation on your router):
```bash
# Back up current config
sudo cp /etc/network/interfaces.d/ifcfg-eth0 /etc/network/interfaces.d/ifcfg-eth0.bak

# Edit to static (replace IP, gateway, netmask with YOUR network values)
sudo tee /etc/network/interfaces.d/ifcfg-eth0 << 'EOF'
auto eth0
iface eth0 inet static
    address 192.168.1.100
    netmask 255.255.255.0
    gateway 192.168.1.1
    dns-nameservers 1.1.1.1 8.8.8.8
iface eth0 inet6 dhcp
EOF

# Reboot and verify
sudo reboot
# After reboot: ip addr show eth0 should show NO "dynamic" flag
# docker ps should show pihole Up
```

**Why DHCP reservation isn't enough:** A DHCP reservation on your router guarantees the same IP every time, but the NAS still *obtains* it via DHCP at boot. The DHCP handshake takes a few seconds — by which time Docker has already tried and failed to start Pi-hole. A static IP is configured directly on the NAS, so it's available the moment the interface comes up — no router involved, no delay.

**Keep the DHCP reservation too:** After switching to a static IP, keep the reservation on your router. The static IP means the NAS claims it instantly at boot; the reservation means the router won't hand out that same IP to another device via DHCP. Both together prevent IP conflicts.

## Pi-hole: Restarted but Answering Nobody

**Symptom:** You restart Pi-hole to load a `dnsmasq.d` change (an `address=` line, say). The container comes back `Up (unhealthy)`, `docker ps` shows `${NAS_IP}:53` published, and `ss` on the NAS shows the socket bound — but every `dig` against it times out and the whole house loses DNS. Nothing is refused; queries just never come back.

**Cause:** `docker restart` allows the container 10 seconds to stop, and `docker restart pihole` is what people reach for. FTL flushes its in-memory query history to `pihole-FTL.db` on shutdown, and on a busy Pi-hole that takes longer than 10s, so Docker SIGKILLs it mid-write. The next start then comes up in a broken half-state: FTL binds port 53, logs `Importing queries`, and never finishes — the dnsmasq worker thread is missing from the process, FTL sits near 0% CPU, and inbound queries pile up in the socket's receive queue until they are dropped. Observed 2026-09-12 after restarting Pi-hole to drop `qbit.lan`: 214 KB queued, 373 dropped, LAN DNS down for 6 minutes, and the FTL log's last line stuck at `Parsing queries in database`. The same restart also logs `ERROR: SQLite3: recovered 410 frames from WAL file`, which is the earlier SIGKILL being cleaned up.

**Diagnose:**
```bash
docker ps --filter name=pihole --format "{{.Status}}"     # Up (unhealthy)
dig +short jellyfin.lan @192.168.110.246                  # times out
docker exec pihole sh -c "tail -6 /var/log/pihole/FTL.log"   # stuck at "Parsing queries in database"
docker exec pihole sh -c 'for t in /proc/52/task/*; do cat $t/comm; done'   # no dnsmasq worker
```

**Fix:** stop it with a grace period long enough for FTL to flush, then start it — do not `docker restart`:
```bash
docker stop -t 60 pihole && docker start pihole
```
Recovery is immediate (verified: `.lan` resolving again 5s after start, health back to `healthy`).

**Prevention:** when the change is a Pi-hole `dnsmasq.d` edit that needs a restart, use `docker stop -t 60 pihole && docker start pihole` from the start. Container *recreates* through the compose file (`up -d --force-recreate pihole`) go through the same 10s default and carry the same risk — if you must recreate, `docker stop -t 60 pihole` first so the recreate starts from a cleanly-closed database. Either way, confirm with `dig +short jellyfin.lan @192.168.110.246` before walking away; `docker ps` showing `Up` is not evidence that DNS works.

## Docker: Ports Not Published After Reboot (Containers "Running", Nothing Listening)

**Symptom:** After any reboot — or a UGOS update — the whole network loses DNS, yet everything *looks* fine. `docker ps` shows Pi-hole `Up` and **healthy**. The giveaway is the `PORTS` column: it's **empty** for pihole, and nothing is listening on `${NAS_IP}:53`.

**This is not the exit-128 problem above.** There, Pi-hole is *stopped* and the cause is obvious. Here it is *running and answering nobody*, which is far harder to spot — `docker ps`, health status and the Pi-hole UI all look normal.

**Cause:** at boot the Docker **daemon** restores containers itself (`restart: always`) — compose is not involved, so no amount of `depends_on` affects it. Bindings pinned to a specific host IP fail to be established, and this Docker version logs it and starts the container anyway rather than refusing. Verified across three reboots on 2026-08-05: **pihole, baserow and therapybot — the only three containers pinned to `${NAS_IP}` — failed every time, while all 13 wildcard-bound containers were fine.** A single failed binding drops the container's *entire* mapping set, which is why Pi-hole also lost its `0.0.0.0:8081` web UI.

Pi-hole's healthcheck (`dig @127.0.0.1` *inside* the container) passes throughout, so neither `docker ps` nor `deunhealth` will ever flag this.

**Diagnose:**
```bash
docker ps --format "{{.Names}}\t{{.Ports}}" | grep pihole   # empty PORTS = not published
ss -tlnp | grep ':53 '                                      # only 127.0.0.1:53 = UGOS's own dnsmasq
dig @<NAS_IP> google.com                                    # "connection refused"
```

**Fix (permanent):** `scripts/boot-compose-up.sh`, run at boot by `scripts/boot-compose-up.service`. It runs `docker compose up -d` across every deployed stack, which reconciles each container against its compose file and re-establishes the bindings. Deployed as:

| Repo | On the NAS |
|---|---|
| `scripts/boot-compose-up.sh` | `/volume1/docker/boot-compose-up.sh` (symlink into this repo) |
| `scripts/boot-compose-up.service` | `/etc/systemd/system/boot-compose-up.service` (`systemctl enable`) |

DNS is back ~20s after boot (Pi-hole's stack is first in the list, deliberately); the full sweep takes ~5 minutes.

> **Status on this NAS, 2026-09-10: the unit is NOT installed.** `systemctl status boot-compose-up.service` returns *Unit could not be found*; there is no unit file in `/etc/systemd/system`, nothing in any `.wants/` directory, and no `@reboot` entry in the root crontab or `/etc/crontab`. The script's own log path (`/volume1/docker/boot-compose-up.log`) **has never existed**, so it has never run on this host. The symlink above *is* in place (recreated 2026-09-10); installing the unit needs root, which the deploy account (`leoleg`) does not have — it is not in `sudoers` and cron is not writable for it either:
>
> ```bash
> sudo ln -sf /volume1/docker/arr-stack/scripts/boot-compose-up.service /etc/systemd/system/boot-compose-up.service
> sudo systemctl daemon-reload
> sudo systemctl enable --now boot-compose-up.service
> ```
>
> **Do not read "it hasn't bitten us since August" as "it cannot".** Pi-hole's current container was created 2026-08-21 — two days *after* the last boot (2026-08-19) — which is exactly the shape of a binding that failed at boot and was repaired later by hand. Until the unit is enabled, every reboot leaves the whole house one missing binding away from losing DNS.
>
> The script is compatible with the unit's invocation: it is `#!/bin/sh` with no bashisms, so the `ExecStart` line's `/bin/sh /volume1/docker/boot-compose-up.sh` parses and runs under dash (checked with `sh -n`), and it works through the symlink. `<NAS admin user>` can also run it by hand at any time — no root needed.

**Critical: use `Wants=`, never `Requires=` or `RequiresMountsFor=` in that unit.** The first version used `RequiresMountsFor=/volume1` + `Requires=docker.service`. Those are *hard* dependencies: `/volume1` wasn't mounted nine seconds into boot, so systemd failed the job outright (`Job boot-compose-up.service/start failed with result 'dependency'`) and **never retried**. DNS stayed down and the unit sat `inactive (dead)` with no error visible in `systemctl status`. The unit now waits for the script itself in `ExecStart`.

**A static IP does NOT fix this** (unlike the exit-128 case above). UGOS reverts the Control Panel setting to DHCP on reboot, and `/etc/network/interfaces.d/ifcfg-eth0` has declared `static` since February while UGOS's own `dhclient@eth0.service` overrides it regardless.

**Manual repair**, if the unit is ever missing or you need DNS back now — no root required, the NAS admin user is in the `docker` group:
```bash
sh /volume1/docker/boot-compose-up.sh
```

**Reading boot logs:** `nasadmin` must be in the `systemd-journal` group or `journalctl` silently returns nothing, which reads exactly like "no logs" rather than "no permission" — that mistake cost an hour of diagnosis. `sudo usermod -aG systemd-journal nasadmin`.

## Pi-hole: Gravity Update Fails With Empty Status

**Symptom:** Running `pihole -g` (or "Update Gravity" in the web UI) shows a blocklist with a blank status and falls back to cache:

```
[i] Target: https://raw.githubusercontent.com/.../SmartTV.txt
[✗] Status: https://raw.githubusercontent.com/.../SmartTV.txt ()
[✗] List download failed: using previously cached list
```

The empty `()` is the curl HTTP code — empty means curl never got a response. Other lists from the same domain succeed, so it isn't network or DNS.

**Cause:** A file in `/etc/pihole/listsCache/` is owned by `root` instead of `pihole`. Gravity runs as the `pihole` user and uses curl's `--etag-save` to update the etag file; if that file is root-owned, curl can't overwrite it and exits before producing an HTTP code. `gravity.sh` swallows curl's stderr (`2>/dev/null`), so the only visible symptom is the empty status. This typically comes from an old Pi-hole image version that didn't chown files back to `pihole` after running gravity as root.

**Diagnose:**
```bash
docker exec pihole ls -la /etc/pihole/listsCache/
# Files owned by root: that's the problem. Should all be pihole:pihole.
```

**Fix:**
```bash
docker exec -u root pihole chown -R pihole:pihole /etc/pihole/listsCache
docker exec pihole pihole -g   # confirm both lists succeed
```

Current Pi-hole versions chown files back to `pihole` after each gravity run, so once corrected this shouldn't recur.

## Seerr: "/app/config volume mount was not configured properly"

**Symptom:** Seerr container starts but logs `The /app/config volume mount was not configured properly` (or similar) and the web UI is unreachable.

**Cause:** Seerr does a strict check on `/app/config` at startup and is fussier than Jellyseerr was. Usually triggered by a half-initialised `seerr-config` volume from an interrupted earlier start — failed `up -d`, container OOM, Ctrl+C mid-init, etc.

**Diagnose:**
```bash
docker logs seerr --tail 30
```

**Fix:** Wipe and re-init the volume.

```bash
docker compose -f docker-compose.arr-stack.yml stop seerr
docker volume rm arr-stack_seerr-config
docker compose -f docker-compose.arr-stack.yml up -d seerr
docker logs seerr --tail 30
```

> **⚠️ Destructive.** Safe on a fresh install before you've configured Seerr. Once you've added Sonarr/Radarr connections, users, or requests, this wipes them — back up `/var/lib/docker/volumes/arr-stack_seerr-config/_data/` first if you need to preserve state.

If a fresh wipe still hits the same error, post `docker logs seerr` output as a GitHub issue.

## Jellyfin: Video Stutters/Freezes Every Few Minutes

**Symptom:** Playing large video files (especially 4K remuxes, 50-100+ GB) causes playback to freeze for a few seconds every 2-3 minutes, then resume. Happens on both Jellyfin apps and Kodi with Jellyfin plugin. Jellyfin dashboard may show "Direct Play" (no transcoding).

**Cause:** UGOS default RAID5 read-ahead is 384 KB — far too small for streaming large files. This forces the kernel to issue many small IO requests to spinning HDDs, each triggering a disk seek (5-10ms). At high bitrates (60+ Mbps for 4K remuxes), the IO queue backs up, disk utilization hits 90%+, and the stream buffer empties causing the stall.

**Diagnose:**
```bash
# Check current read-ahead (384 = too low for streaming)
cat /sys/block/md1/queue/read_ahead_kb
cat /sys/block/dm-0/queue/read_ahead_kb

# Check stripe cache (256 = default, too low)
cat /sys/block/md1/md/stripe_cache_size

# Monitor disk IO during playback (look for high %util and w_await)
iostat -x 1 5 | grep -E "Device|dm-0"
```

**Fix:** Increase read-ahead and stripe cache to allow larger sequential reads:
```bash
# Apply immediately (requires root)
sudo bash -c '
echo 4096 > /sys/block/md1/queue/read_ahead_kb
echo 4096 > /sys/block/dm-0/queue/read_ahead_kb
echo 4096 > /sys/block/md1/md/stripe_cache_size
'
```

**Make permanent:** Add a `@reboot` cron job for root (**not** `/etc/rc.local` — UGOS overwrites it on firmware updates):
```bash
# Add to root crontab (sleep 30 lets RAID finish initialising)
sudo crontab -e
# Add this line:
@reboot sleep 30 && echo 4096 > /sys/block/md1/queue/read_ahead_kb && echo 4096 > /sys/block/dm-0/queue/read_ahead_kb && echo 4096 > /sys/block/md1/md/stripe_cache_size
```

> **Warning:** Do NOT use `/etc/rc.local` for custom tuning on UGOS — firmware updates silently overwrite it. Use root crontab `@reboot` instead.

**Result:** Disk utilization drops from ~96% to ~8-15% during 4K playback. Read latency drops from 20ms to 3-7ms. Stalls eliminated.

**Note:** SSD caching will **not** help with video streaming — it only accelerates frequently re-read data, and video playback is sequential read-once.

## Memory: Unnecessary Swap With Plenty of Free RAM

**Symptom:** `free -h` shows several GB of swap used even though there's plenty of available RAM. System feels slower than expected for the amount of RAM installed.

**Cause:** UGOS default `vm.swappiness=60` tells the kernel to aggressively move inactive pages to swap (including zram) even when RAM is plentiful. This is fine for a desktop but suboptimal for a server where you want application pages to stay resident.

**Diagnose:**
```bash
# Check swappiness (60 = too aggressive for a server with plenty of RAM)
cat /proc/sys/vm/swappiness

# Check swap usage (zram = compressed RAM, not disk — but still has overhead)
cat /proc/swaps
free -h
```

**Fix:**
```bash
# Apply immediately
sudo bash -c 'echo 10 > /proc/sys/vm/swappiness'

# Verify
cat /proc/sys/vm/swappiness
# Should show: 10
```

**Make permanent:** Add to the root `@reboot` crontab (alongside RAID5 tuning if present):
```bash
sudo crontab -e
# Append to existing @reboot line, or add new:
@reboot sleep 30 && echo 10 > /proc/sys/vm/swappiness
```

> **Note:** `swappiness=10` doesn't disable swap — the kernel will still swap under real memory pressure. It just stops proactively swapping out app pages to make room for disk cache when there's no pressure.

## SSH: Post-Quantum Key Exchange Warning

**Symptom:** Every SSH connection to the NAS shows:
```
** WARNING: connection is not using a post-quantum key exchange algorithm.
** This session may be vulnerable to "store now, decrypt later" attacks.
```

**Cause:** macOS OpenSSH 10.x warns when the connection doesn't use a post-quantum key exchange algorithm (`sntrup761x25519-sha512@openssh.com`). UGOS ships OpenSSH 9.2 which supports the algorithm, but the UGOS-managed `/etc/ssh/sshd_config.d/high_crypt.conf` sets `KexAlgorithms` without it — so it's never offered to clients.

**Fix (two parts):**

1. **NAS — add a drop-in config** that loads before the UGOS-managed one:
```bash
sudo tee /etc/ssh/sshd_config.d/00-pq-kex.conf << 'EOF'
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
EOF
sudo systemctl restart sshd
```

The `00-` prefix ensures it loads before `high_crypt.conf` (alphabetical order, first match wins in sshd).

2. **Client (Mac) — add to `~/.ssh/config`:**
```
Host your-nas.local
    KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org
```

**Verify:**
```bash
ssh -vv user@your-nas.local 'exit' 2>&1 | grep 'kex: algorithm'
# Should show: sntrup761x25519-sha512@openssh.com
```

**UGOS resilience:** The `sshd_config.d/` drop-in directory is less likely to be wiped than the main config (same principle as using `@reboot` crontab instead of `/etc/rc.local`). If a UGOS update does remove it, you'll just see the warning again — nothing breaks. The client-side config on your Mac is completely UGOS-proof.


## Downloads: Queue Items Sit at 0% Forever and Nothing Re-Grabs Them

**Symptom:** Sonarr's queue fills with items that never move. `sizeleft` equals
`size`, the added date is weeks old, and Status is `warning` while
`trackedDownloadStatus` is `ok` — so nothing in the queue reads as an error.
New releases still download fine, which is what makes it look like an indexer
or bandwidth problem rather than a stuck queue.

**Cause:** two failures stacked. The download client (Decypharr, pulling from
TorBox) failed to resolve a download link, logged
`Error running post-download action`, and stopped — without telling Sonarr.
Sonarr then treats the item as still downloading, and because a queue item at
the cutoff makes it reject every candidate with `Release in queue already meets
cutoff: <quality>`, it cannot replace the item either. The episode is stuck in
both directions until the queue entry is removed.

**Diagnose:**

```bash
# The queue item: sizeleft == size, weeks old
curl -s -H "X-Api-Key: $SONARR_API_KEY" \
  'http://localhost:8989/api/v3/queue?pageSize=500' \
  | jq '.records[] | select(.sizeleft == .size) | {id, title, added, downloadClient}'

# Why the searches are finding nothing: every release is rejected by the item
# that is already (not) downloading
curl -s -H "X-Api-Key: $SONARR_API_KEY" \
  'http://localhost:8989/api/v3/release?seriesId=8&episodeId=437' | jq '.[0].rejections'

# And the client's side of it
docker logs --since 24h decypharr 2>&1 | grep -E "Error running post-download|no valid download links"
```

**Fix:** remove the stuck item and let the arr search again —
`./scripts/queue-cleanup.sh --apply` does exactly that (dry run first). On
2026-09-12 this cleared 67 items that had been stuck since mid-August; the
first re-grabbed episode imported 31 seconds after the grab.

**Do not blocklist these.** For a debrid client the release is fine and the
provider failed, so blocking it forbids the one release the provider is known
to have cached. `queue_cleanup.py` skips the blocklist for a stale item whose
`downloadClient` looks like a debrid provider, and paces the replacement
searches 30 seconds apart — a burst answers `429` and Sonarr disables the
indexer for the rest of the run.

**Prevention:** `queue-cleanup.timer` (hourly). A debrid-backed item is
called dead after 3 hours of no progress rather than the 24-hour rule a swarm
client gets, so the sweep is set to run faster than the shortest threshold it
enforces. It shipped as a
"suggested cron line" in a comment and was never installed anywhere, which is
how a month went by with the fix sitting in the repo. Check it is armed:

```bash
systemctl --user list-timers queue-cleanup.timer
```

## Usenet: SABnzbd Fails Every Article, TorBox's Own Downloader Succeeds

**Symptom:** Nothing ever arrives by usenet. SABnzbd's queue is Idle, its
history is empty, and Sonarr/Radarr history fills with
`Aborted, cannot be completed - https://sabnzbd.org/not-complete`,
`Repair failed, not enough repair blocks`, and
`Manually marked as failed`. Torrents through Decypharr keep working, which is
what makes it look like an indexer or a preference problem.

**Cause: `nntp.torbox.app` serves articles only up to about 90 days old.**
Measured 2026-09-14 by resolving every article of eight grabbed NZBs against the
same server, same credentials:

| Release age | Articles resolved |
| --- | --- |
| 1, 34, 60, 86 days | 5/5 or 6/6, every attempt |
| 101 days | 0/5 |
| 138 days | 0/6 |

The newsgroup always exists (`GROUP` returns `211`) and authentication is fine
(`200 Welcome to TorBox` → `381` → `281 Authentication accepted.`), which is why
this reads as a configuration problem for so long. The *articles* are gone:
`STAT <id>` → `430 No such article`.

The impact is not marginal, because a backlog is mostly old releases. Sonarr's
usenet grabs: 81 of 85 were older than 90 days, and SABnzbd imported 1 of 91
while the torrent path imported 109 of 202. Radarr: 42 of 58 older than 90 days,
8 of 58 imported, and every one of those 8 was 30 days old or newer.

**TorBox's API has no such limit**, which is what separates the two paths.
TorBox's usenet is an API that runs a usenet client against a real backbone, not
an NNTP service you read from: the exact 138-day-old NZB SABnzbd cannot fetch
was submitted to `POST /v1/api/usenet/createusenetdownload` and completed at
836 MB across 4 files. The two halves are not the same store, and no setting on
either side closes the gap -- there is no age filter in Prowlarr, in an indexer
entry, or in either arr.

**The fix is to stop using SABnzbd for usenet.** Both arrs use their native
`UsenetBlackhole` download client instead, and `usenet-blackhole.timer` moves
the releases through TorBox's API:

* the arr writes `<Release.Title>.nzb` into
  `/data/usenet/blackhole/nzb` and polls `/data/usenet/blackhole/complete`;
* `scripts/usenet-blackhole.sh` submits each NZB to TorBox, polls it, downloads
  the finished zip, and renames the release into the watch folder under its
  release name — the name the arr parses to decide what it just got;
* the arr imports it and deletes the folder itself.

Decypharr still handles torrents. SABnzbd still runs, with nothing pointed at
it.

**Operating it:**

```bash
./scripts/usenet-blackhole.sh              # dry run: what it would submit
./scripts/usenet-blackhole.sh --apply -v   # submit, poll, fetch, per-job lines
tail -30 logs/usenet-blackhole.log         # what the timer has been doing
cat logs/usenet-blackhole-failed.log       # releases that failed or timed out
cat logs/usenet-blackhole-state.json       # what is in flight
```

A release that never completes is invisible to the arr — a blackhole client
reports no queue, so the arr sees only what appears in the watch folder. That is
what `logs/usenet-blackhole-failed.log` exists for: anything TorBox reports
failed, or that is still going after `--timeout-hours` (24 by default), is
written there and dropped from the state file.

**Do not "fix" a stall by deleting the state file.** It is what stops a restart
asking TorBox to download the same release twice; without it the arr sees two
folders for one episode and imports one of them as a duplicate. A release that
fails is already removed from it automatically.

**If nothing arrives at all, check in this order:** is the timer armed
(`systemctl --user list-timers usenet-blackhole.timer`); is `TORBOX_API_KEY` set
in `.env`; does the dry run list the NZBs the arr has written; does
`logs/usenet-blackhole.log` show the last pass erroring. A pass that cannot
write its state file exits non-zero and says so rather than continuing, because
releases already submitted would otherwise be sent again.

**Not the fix:** waiting. The 403 rate-limit section below describes a transient
failure that clears on its own; this one was stable across every release tested,
for every age past roughly 90 days, over the whole measurement window.

## TorBox: All Download Links Return 403 (error code 1010)

**Symptom:** Everything stops arriving at once. The TorBox dashboard looks
healthy — hundreds of downloads, nearly all of them "ready" — and shows no
restriction notice. Sonarr's and Radarr's queues fill with items at 0% that
never move, and Decypharr logs:

```
Error running post-download action  error="resolve download link for <file>.mkv: 400: unknown error code: 400"
```

The rate limit and that `400` are two different things, an hour apart, and the
second is the one that wedges the queue. See *Related: the bare 400* below.

**This is not a plan limit, and it is not the indexer.** Confirmed 2026-09-13:
the account is **Pro** — 10 active slots, usenet included, no add-download
cool-down. The refusal is a transient, account-wide rate limit on TorBox's
download-link endpoint.

**Cause:** a burst of `createtorrent` calls (a large missing-titles search) plus
repeated `requestdl` calls earns `403` with `error code: 1010` on
`/v1/api/torrents/requestdl`. It applies to the whole account regardless of
which item you ask for, and it clears on its own. Measured that day: it began at
01:20 BST after ~100 torrents were queued within an hour, refused every request
for about 90 minutes — new and week-old items, GET and HEAD, `redirect` true and
false, a 15 GB video and its .nfo sibling alike — then started answering `200`
again. What ended it was time, not anything done here: the same probes that had
been refused for 90 minutes were answered again with no configuration change, no
restart and no key rotation in between. Links issued before it began keep
serving for their full 3 hours, so transfers already in flight continue while
new ones are refused; the pipeline looks half-alive rather than dead.

None of which means the queue recovers by itself afterwards. An earlier draft of
this section said so, in the same paragraph as the sentence above, and the two
contradicted each other: nothing changed here is why the *refusals* stopped, and
also why every item they wedged stayed wedged, and also why the items that
`queue-cleanup` then removed were re-grabbed unchanged. See *Fix* below.

**Diagnose:** ask for a link to something TorBox already holds. `200` means
fine; `403 error code: 1010` means the account is being limited right now.

```bash
TB=$(grep -E '^TORBOX_API_KEY=' .env | cut -d= -f2-)
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://api.torbox.app/v1/api/torrents/requestdl?token=$TB&torrent_id=<any cached id>&file_id=<file id>"
```

Cross-check what the account thinks it has: `GET /v1/api/torrents/mylist`
returns every torrent with `download_state`, and `GET /v1/api/user/me` carries
`cooldown_until`. **Neither tells you the plan**, and a non-empty
`cooldown_until` is the rate-limit timestamp, not a plan property — reading it
as one produced two wrong diagnoses in a single evening. The plan is Pro; see
`CLAUDE.md`'s *TorBox Account* section.

**Related: the bare 400.** The 403 above is the rate limit. This is the other
error, and it is the one that wedges the queue. Decypharr's
`ErrorCodeToLinkError` has no case for `"400"`, so it falls through to the
default branch, which classifies the error as **permanent**. Two consequences,
both measured in the v2.5 source:

- `resolveLinkWithRetry` returns at the first attempt instead of using its four
  tries and its exponential backoff (`pkg/manager/downloader.go`). The log shows
  no `link fetch failed, retrying` line at all, which is the tell.
- `fetchAndValidate` memoises the failure against the link URL, and the link URL
  for a given torrent is derived from `torrent_id`/`file_id`, so the same
  request keeps producing the same URL.

The client keeps the torrent, the arr keeps the queue item at 0%, and — because
an item at the cutoff makes the arr refuse every alternative — the title cannot
be replaced either. A transient upstream hiccup becomes permanently stuck
episodes and films.

**This is fixed locally.** `decypharr/Dockerfile` builds the pinned upstream
release with upstream's own open fix ([PR #402](https://github.com/sirrobot01/decypharr/pull/402))
applied, and `.github/workflows/decypharr-image.yml` publishes it. The compose
file uses that image instead of `ghcr.io/sirrobot01/decypharr:v2.5`. Confirm the
running image carries the fix:

```bash
docker inspect decypharr --format '{{.Config.Image}}'   # .../decypharr:v2.5-patch1
```

The `400` itself still appears in the logs — it is a real upstream answer — but
it now costs a retry rather than the file. Delete `decypharr/`, its workflow and
the compose reference once upstream merges the fix into a release.

**Fix (the rate limit itself):** wait it out. It cleared inside ~90 minutes
here. Once links answer again, `queue-cleanup.timer` removes the wedged items as
they pass the 3-hour age rule and re-searches them — **but do not expect a
queue-cleanup re-grab to succeed on its own.** Measured the same evening, before
the 400 fix was deployed: six titles were removed at 00:16 and re-grabbed by the
arr's next RSS sync, and by 00:45 all six were stalled again at 0%, because
Decypharr was still treating the link error as permanent and the indexer kept
offering the same release. The refusals stopping and the queue recovering are
separate events, and `queue-cleanup` is what connects them: the first removal is
exempt from the blocklist (the provider may have been transiently broken), and a
release that comes back a second time is blocklisted, which forces a different
release instead of the same one forever. Give it two sweeps. Do not force-clear
the whole queue to hurry it along — that submits another burst and can re-trip
the limiter.

**Prevention:** queue in ones and twos. A 45-film `MissingMoviesSearch` plus six
season searches in an hour is what triggered this; `queue-cleanup.timer`'s age
gate exists to pace exactly that kind of work.
