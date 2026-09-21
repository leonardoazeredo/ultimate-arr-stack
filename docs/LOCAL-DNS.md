# + local DNS (.lan domains)

> Return to [Setup Guide](SETUP.md)

Access services without remembering port numbers: `http://sonarr.lan` instead of `http://NAS_IP:8989`.

This works by giving Traefik its own IP address on your home network. When you type `sonarr.lan`, Pi-hole's DNS points it to Traefik, which routes you to the right service.

**Step 1: Configure macvlan settings in .env**

These are already in `.env` (from `.env.example`). Edit the values for your network:

```bash
TRAEFIK_LAN_IP=192.168.1.11    # Unused IP in your LAN range
LAN_INTERFACE=eth0            # Network interface (check with: ip link show)
LAN_SUBNET=192.168.1.0/24       # Your LAN subnet
LAN_GATEWAY=192.168.1.1         # Your router IP
```

**Step 2: Reserve the IP in your router**

The container uses a static IP with a fake MAC address (`TRAEFIK_LAN_MAC` in `.env`, default `02:42:c0:a8:01:0b`). Your router doesn't know about it, so add a DHCP reservation to prevent it assigning that IP to another device.

<details>
<summary>Router-specific instructions</summary>

- **MikroTik:** `/ip dhcp-server lease add address=192.168.1.11 mac-address=02:42:c0:a8:01:0b comment="Traefik macvlan" server=dhcp1`
- **UniFi:** Settings → Networks → DHCP → Static IP → Add `02:42:c0:a8:01:0b` → your `TRAEFIK_LAN_IP`
- **pfSense/OPNsense:** Services → DHCP → Static Mappings → Add
- **TP-Link:** Advanced → Network → DHCP Server → Address Reservation → Add
- **Netgear:** Advanced → Setup → LAN Setup → Address Reservation → Add
- **ASUS:** LAN → DHCP Server → Manual Assignment → Add
- **Linksys:** Connectivity → Local Network → DHCP Reservations
- **Other routers:** Look for "DHCP Reservation" or "Address Reservation"

</details>

**Step 3: Create Traefik config and deploy**

> **Important:** You MUST create `traefik.yml` before deploying. If Docker can't find the file, it creates a directory instead, and Traefik fails to start.

```bash
cd $NAS_STACK_DIR

# Create Traefik config from example
cp traefik/traefik.yml.example traefik/traefik.yml

# Deploy Traefik
docker compose -f docker-compose.traefik.yml up -d
```

**Step 4: Configure DNS**
```bash
# Copy example and replace placeholder with your Traefik IP
mkdir -p pihole/dnsmasq.d
sed "s/TRAEFIK_LAN_IP/192.168.1.11/g" pihole/dnsmasq.d/02-local-dns.conf.example > pihole/dnsmasq.d/02-local-dns.conf
chmod 644 pihole/dnsmasq.d/02-local-dns.conf

# Restart Pi-hole to apply changes
docker compose -f docker-compose.arr-stack.yml restart pihole
```

> **⚠️ Important:** Stack `.lan` domains are managed in `02-local-dns.conf`. If you add your own domains (e.g., homeassistant.lan), use either the CLI or Pi-hole web UI — but never define the same domain in both places, as they can conflict and cause unpredictable DNS resolution.

### Adding a `.lan` domain for a service outside this stack

For a container that isn't part of this compose project (Frigate, Home
Assistant, etc.) but that you still want at `myservice.lan`:

**1. Add the DNS entry** (gitignored `pihole/dnsmasq.d/02-local-dns.conf`):

```
address=/myservice.lan/TRAEFIK_LAN_IP
```

**2. Add a Traefik route** (create `traefik/dynamic/my-services.local.yml` —
also gitignored):

```yaml
http:
  routers:
    myservice-lan:
      rule: "Host(`myservice.lan`)"
      entryPoints: [web]
      service: myservice-lan

  services:
    myservice-lan:
      loadBalancer:
        servers:
          - url: "http://172.20.0.30:5000"
```

**3. Deploy:**

```bash
docker exec pihole pihole restartdns
# Traefik picks up *.local.yml automatically
```

**Requirement**: the service must be on the `arr-stack` network with a static
IP — see the `ip_range: 172.20.0.128/25` note in `docker-compose.traefik.yml`
for why a manually added container needs an IP outside that range.

**Step 5: Set router DNS**

Configure your router's DHCP to advertise a resolver that is not the NAS. In this
deployment that is the router itself, running AdGuard Home — see *Which resolver
actually serves each VLAN* below for what the router does with the query.

> **Note:** Due to a macvlan limitation, `.lan` domains don't work from the NAS itself (e.g., via SSH). They work from all other devices.

See [REFERENCE.md](REFERENCE.md#service-access) for the full list of `.lan` URLs.

### Which resolver actually serves each VLAN (read off the router, 2026-09-10)

**The router, and it no longer depends on the NAS.** Every pool advertises the
router. `dhcp_option 6` was deleted from all four target pools on 2026-09-21 and
dnsmasq advertises itself, which is each VLAN's own gateway address; `guest` and
`iot` never carried the option at all.

| Pool | advertises |
|---|---|
| `lan` | 192.168.8.1 |
| `vlan10` | 192.168.110.1 |
| `vlan20` | 192.168.120.1 |
| `vlan30` | 192.168.130.1 |

Check it from a host with router access — this repo's design makes pi1 the only
one. An empty `dhcp_option` result is the correct one:

```bash
ssh arr-stack-router 'uci show dhcp | grep dhcp_option'   # expect no output
ssh arr-stack-router 'uci show dhcp | grep leasetime'     # expect all 12h
```

What the router does with that query is two-stage, and the second stage is the
part that used to live on the NAS:

1. Every DNS packet arriving on a client bridge is redirected to **AdGuard Home
   on `:3053`** — blocklists, DoH upstreams, and the `.lan` rewrites that point
   at Traefik.
2. If AdGuard Home stops answering, `/usr/sbin/arrdns-watchdog.sh` (cron, every
   minute) moves that redirect back to dnsmasq on `:53` after three consecutive
   failed probes, and forward again after three successes. Resolution continues
   either way; only ad blocking is lost while degraded. Source:
   `router/arrdns-watchdog.sh`, and the redirect itself is `router/firewall.user`.

   `router/firewall.user` also carries its own check, and it exists for one
   specific case: the firewall starts at `S19` and AdGuard Home at `S99`, so on a
   router reboot there is a window in which every client would be redirected at a
   resolver that has not started yet. The watchdog cannot cover it — it needs
   three consecutive failures and cron starts at `S50`, inside the window — so
   the include probes AdGuard before choosing it and uses dnsmasq if it does not
   answer, recording that in `/etc/arrdns-port` so the file, the rules and the
   watchdog agree. The watchdog moves the house back on its next tick. If you
   ever see clients on dnsmasq right after a router reboot, this is why, and it
   is the intended behaviour rather than a fault.

Two consequences worth keeping:

- **The NAS being powered off no longer removes DNS from the house.** It used to:
  every pool advertised `192.168.110.246`, so a NAS that was down, stalled or
  being rebooted took the internet with it, and `scripts/boot-compose-up.service`
  was load-bearing for that reason. Resolution is now answered entirely on the
  router, and the NAS resolver is gone rather than idle. The full record is
  [DNS-MIGRATION.md](DNS-MIGRATION.md).
- **There is one remaining single point of failure, and it is the router** rather
  than the NAS. That is a deliberate trade: the router is already the gateway,
  so a house whose router is down has no internet with or without DNS. The
  watchdog above is what keeps it from being *two* points.
- **The NAS Pi-hole and dnscrypt-proxy are removed** as of 2026-09-21. They were
  stopped first (9.1), held stopped across a reboot — plain `docker stop` is not
  durable against `restart: always`, so both got `docker update --restart=no` —
  and then deleted from `docker-compose.arr-stack.yml` in 9.4, so no `docker
  compose up` can bring them back. **The volumes are still there**
  (`arr-stack_pihole-etc-pihole`, `arr-stack_dnscrypt-config`) and were backed up
  to `/volume1/docker/arr-stack-backups/` before removal. Rolling back means
  restoring a volume and re-adding the service blocks, which are in history:
  `git show 7327de1^:docker-compose.arr-stack.yml`. The containers are gone.

- **The `pi2-dns` stack (Pi-hole + dnscrypt-proxy on the Pi 3) is a standby, not a
  peer** — it serves no DHCP client. It was **stopped and retired on 2026-09-10**:
  containers stopped (not removed), and pi2's checkout returned to `main` so no
  unmerged branch code stays live. To bring it back deliberately:

  ```bash
  ssh pi@pi2 'cd /home/pi/arr-stack && git fetch origin feat/pi1-pi2-split && \
      git checkout feat/pi1-pi2-split && \
      docker compose -f docker-compose.pi2-dns.yml up -d'
  ```

  It was a usable fallback while the NAS was the resolver. It is now a third
  option behind the router and the NAS, and repointing a pool at
  `192.168.120.241` is still a router edit rather than a code change.

**Upstream is encrypted, now on the router rather than on the NAS.** AdGuard Home
forwards over DoH — `https://dns.quad9.net/dns-query` and
`https://cloudflare-dns.com/dns-query`, with plain Quad9 addresses for
`bootstrap_dns` because bootstrapping cannot itself be encrypted. The NAS
dnscrypt-proxy used to sit in that path at `172.20.0.6#5053`; it was removed with
the rest of the NAS resolver on 2026-09-21, and its config is in the
`arr-stack_dnscrypt-config` volume and the backup of it.

### AdGuard Home on the router (serving since 2026-09-21)

The house's DNS moved off the NAS onto the router, so that the NAS can be powered
off without taking internet access with it. AdGuard Home runs on
`arr-stack-router`, listening on `:3053`, and **it is the resolver every client
reaches** — `adguardhome.config.dns_enabled='1'`.

**The admin UI is reachable from the maintenance VLAN only**, by design and
deliberately. `zone_vlan10_input` allows a client VLAN to reach the router on DHCP
and DNS alone, so `http://192.168.8.1:3000` answers from the maintenance VLAN and
nowhere else. Measured 2026-09-21:

```
router itself                302
pi1 - maintenance VLAN eth0  302
pi1 - VLAN20 wlan0           000
NAS - VLAN10                 000
```

That is the same posture as the router's own admin UI. Making it a `.lan` name
behind Traefik would need a rule letting the NAS reach `router:3000` — which
widens what a compromised container on the NAS can touch on the router, for one
UI that is already reachable. Decided against on 2026-09-21; decide it explicitly
if it ever matters.

One thing about it is not obvious from the GL.iNet UI and cost real time to find:
**the vendor's own AdGuard dispatch covers only `br-lan.1` and `br-guest`.** On
this firmware `dns_enabled='1'` cannot put `vlan10`, `vlan20` or `vlan30` on
AdGuard at all; that is done by the per-bridge REDIRECT rules in
`router/firewall.user`, which is why they are load-bearing rather than a
stale-lease convenience. `tests/router-dns.bats` asserts it, and the same rules
have to move in lockstep with `dns_enabled` because they are reloaded by different
mechanisms — see that test's `(d)` group.

Its configuration is written by `scripts/adguard-configure.sh`, which transforms
`/etc/AdGuardHome/config.yaml` here (the router has no bash, python, perl or
PyYAML), pushes it, runs `AdGuardHome --check-config`, backs up the old file and
restarts. It is idempotent: a second run reports "no change" and restarts
nothing. **The AdGuard HTTP API is not usable on this build** — GL.iNet wraps
`/control/*` in its own auth middleware, which ignores AdGuard's session cookie
— so the config file is the only route.

**Encrypted upstreams:** `https://dns.quad9.net/dns-query` and
`https://cloudflare-dns.com/dns-query`, with `bootstrap_dns` left on plain Quad9
addresses because bootstrapping cannot itself be encrypted. This replaces the
plain `8.8.8.8`/`9.9.9.9` that shipped, and stands in for what `dnscrypt-proxy`
provides on the NAS.

**Blocklists**, and why these two:

| List | Why it is here |
| --- | --- |
| AdGuard DNS filter (`adguardteam.github.io/AdGuardSDNSFilter`) | Shipped enabled with the package; the general-purpose baseline |
| StevenBlack hosts (`raw.githubusercontent.com/StevenBlack/hosts/master/hosts`) | **The list the NAS Pi-hole used**, so a blocked name stayed blocked through the migration. Parity between the two resolvers was a Gate 3 requirement, and two different lists would have made "did the migration change what is blocked?" unanswerable |
| AdAway Default Blocklist | Present but disabled — shipped that way, left alone |

A name the NAS blocks with Pi-hole's NULL mode answers `0.0.0.0` there and does
the same here, which is what lets `tests/fixtures/dns-baseline.txt` compare the
two resolvers directly.

**Two answers deliberately differ from the NAS**, both named `ALLOW-DIFF` in
that fixture with the reason attached. First, AAAA on a `.lan` name: the NAS
answers `::` from its `address=/lan/::` hack, AdGuard answers NODATA. Both work
for a musl client — musl's failure mode is AAAA *NXDOMAIN*, and NODATA is not
that — and NODATA is the safer answer, since `::` is the unspecified address and
`connect()` maps it to loopback. Second, a `.lan` name that does not exist: the
NAS answers it NODATA from its local zone, AdGuard answers NXDOMAIN.

One gap remains, recorded rather than smoothed over: reaching that NXDOMAIN means
AdGuard **asks a public resolver** for `.lan` names it does not know, which the
NAS never did. Putting `lan` in AdGuard's `bogus_nxdomain` answers those locally
and closes it. That is a deliberate follow-up, not an oversight.

---

## ✅ + local DNS Complete!

**Congratulations!** You now have:
- Pretty `.lan` URLs for all services
- Ad-blocking via Pi-hole
- No ports to remember

**What's next?**
- **Stop here** if local access is all you need
- **Continue to [+ remote access](REMOTE-ACCESS.md)** to watch from anywhere

**Other docs:** [Upgrading](UPGRADING.md) · [Home Assistant Integration](HOME-ASSISTANT.md) · [Quick Reference](REFERENCE.md)

Issues? [Report on GitHub](https://github.com/leonardoazeredo/ultimate-arr-stack/issues) or [chat on Reddit](https://www.reddit.com/user/Jeff46K4/).
