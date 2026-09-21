# DNS moved off the NAS onto the router — migration record

**The house's DNS is served by AdGuard Home on `arr-stack-router`, and the NAS is
not in that path.** Written as the audited record of the 2026-09-21 migration:
what was attempted, what actually happened, where the plan was wrong, and what is
still open. If you are picking this up cold, read [§1](#1-status-at-a-glance),
[§6](#6-live-only-state-that-is-not-in-this-repo) and
[§8](#8-open-items) first. The two corrections worth reading even if you read
nothing else are [§4.1](#41-the-redirect-only-ever-covered-stale-leases) and
[§4.4](#44-fw3-does-not-re-run-etcfirewalluser-at-all).

Last updated: **2026-09-21**. Sections 3, 4, 5 and 6 are historical and stay
true; **§1 and §8 decay.** Where §1 would otherwise carry a bare number it names
the command to re-check it instead.

---

## 1. Status at a glance

| | |
|---|---|
| Status | **Migrated and merged 2026-09-21**, PRs #104 through #115. The NAS resolver is removed, not stopped. |
| The claim | With the NAS powered off, the house keeps resolving and keeps blocking. Measured, not inferred: see below. |
| HEAD | Do not trust a number written here. `gh api repos/leonardoazeredo/ultimate-arr-stack/branches/main --jq .commit.sha` |
| Deployed | The NAS tracks `main`. Re-check on the NAS with `arrgit rev-parse --abbrev-ref HEAD` and compare. |
| Where DNS is served | AdGuard Home on the router, `:53` after the redirect, listening on `:3053`; the router's dnsmasq sits underneath on `:53`. |
| Watchdog | `/usr/sbin/arrdns-watchdog.sh` from cron every minute. Re-check: `ssh <router> /usr/sbin/arrdns-watchdog.sh --status` |
| Tests | Green in CI. Locally, 28 failures are the known macOS baseline (BSD sed, no `timeout`, no PyYAML); CI on Linux is the gate. |
| Open | [§8](#8-open-items): the soak (9.2/9.3) has to pass on the calendar, and the two config volumes are still on the NAS. |

The measurement the whole migration rests on, taken from a VLAN20 client polling
every two seconds across a real NAS reboot on 2026-09-21:

```
samples: 99   DNS OK: 99   DNS FAILED: 0
during the 108 seconds the NAS was down: 36/36 OK
```

Every sample resolved `sonarr.lan` to `192.168.110.250`, `doubleclick.net` to
`0.0.0.0`, and a public name to a real address. Before this migration that reboot
was the outage: with the NAS off, nothing on the LAN could resolve anything, and
on 2026-09-21 the house had already been in that state for hours when the work
started.

**What moved.** Pi-hole and dnscrypt-proxy ran as containers on the NAS, and four
DHCP pools advertised the NAS as their resolver. All four now advertise the
router. The NAS containers were stopped (9.1), held stopped across a reboot
(#107), and removed from the compose file (9.4, #113), so no future
`docker compose up` can bring them back.

---

## 2. What a query does now

A client's DHCP hands it its own VLAN's router address (`192.168.8.1`,
`192.168.110.1`, `192.168.120.1`, `192.168.130.1`). Whatever it asks, the router
redirects port 53 to AdGuard Home's `:3053`, per bridge, over both transports:

```
iptables  -t nat -S PREROUTING | grep -c "dport 53.*to-ports"   # 12
ip6tables -t nat -S PREROUTING | grep -c "dport 53.*to-ports"   # 12
```

Twelve per family is six interfaces times two transports. The six are the four
VLAN bridges, `br-guest`, and `tailscale0`.

The rules live in `/etc/firewall.user`, which is `firewall.@include[0]`, and they
read their target port from `/etc/arrdns-port` rather than naming it. That file
is the switch the watchdog moves: `3053` means AdGuard answers, `53` means the
router's dnsmasq does and ad blocking is lost deliberately.

Three facts about that arrangement cost real time to learn and are documented in
full in [§4](#4-corrections-where-the-plan-was-wrong): GL.iNet's own
`dns_dispatcher` covers only `br-lan.1` and `br-guest`, so these rules are what
put the VLANs on AdGuard and are not a convenience; `fw3 reload` does not flush
the built-in `PREROUTING` chain, so the include strips its own rules before
re-inserting them; and the include has to be registered for reloads
(`firewall.@include[0].reload='1'`) or a reload rebuilds the vendor's chain and
never re-runs the include.

`docs/LOCAL-DNS.md` covers the operator's view of this: which pool advertises
what, how to add a name, and how to roll back. This file is the record of how it
got there and what it cost.

---

## 3. Commit-by-commit audit

| Commit | What it did | Verified by |
|---|---|---|
| `7327de1` (#104) | Move the house's DNS off the NAS onto the router: the include, the watchdog, `/etc/arrdns-port`, the client-path check in `scripts/lib/router-dns.sh` | 99/99 samples across a NAS reboot; live `tests/router-dns.bats`; 6 mutations |
| `57deed5` (#105) | 9.1: stop Pi-hole and dnscrypt-proxy, volumes kept | a real client resolves and blocks; nothing on the NAS's `:53` |
| `dc34ddb` (#106) | Close the router-reboot window between `S19firewall` and `S99adguardhome` | `tests/firewall-user.bats`, 6 tests with stubbed `iptables` and `dig` |
| `36fa783` (#107) | Hold the stopped services stopped: `docker update --restart=no` | `policy=no`, `exited`, everything else healthy |
| `38a53fe` (#108) | Answer 9.2's reboot clause early, and record why 9.3's stated method cannot be used | live NAS inspection of boot mechanisms; the Pi-hole database |
| `0165db0` (#109) | Retire the `pihole.lan` Traefik route and its Homepage entry | link and icon checked; the name itself follows in #115 |
| `c047b40` (#110) | Record 8.4 and 8.7 as done rather than deferred, with the reason | — (docs) |
| `66d8db6` (#111) | Record the admin-UI decision: maintenance-VLAN-only, as policy | the 302/000 measurement on both interfaces |
| `d10acd6` (#112) | Filter the tailnet, and assert it in both directions | a real tailnet client gets `0.0.0.0` for a blocklisted name |
| `4371c5b` (#113) | 9.4: remove both services, both volume declarations and the bind mount; delete `configure_pihole()` | new `tests/no-nas-resolver.bats`, watched fail then pass; live NAS `up -d` |
| `27fc797` (#114) | 8.6: retire `check-dns-duplicates.sh` and `check-domains.sh`, and repoint two defaults that still named the dead resolver | suite; tree and sweep oracles |
| `a74da71` (#115) | Retire the `pihole.lan` name from both DNS stores | `pihole.lan` empty on A and AAAA from a client; both stores read back zero hits |

Two commits in that table are corrections to earlier ones, which is why they are
listed rather than squashed: `dc34ddb` closes a window `7327de1` did not know
about, and `36fa783` fixes a durability assumption `57deed5` made.

---

## 4. Corrections: where the plan was wrong

The plan is
[`docs/superpowers/plans/2026-09-19-dns-adguard-router-migration.md`](superpowers/plans/2026-09-19-dns-adguard-router-migration.md),
and its closure plan is
[`2026-09-21-dns-migration-closure.md`](superpowers/plans/2026-09-21-dns-migration-closure.md).
Both were amended as these were found. The corrections are the part of this
document worth reusing; the phases went roughly as written.

### 4.1 The redirect only ever covered stale leases

The plan's answer to clients holding a DHCP lease was to shorten lease times. A
client with a 12-hour lease keeps it until T1, half the lease, so that leaves up
to six hours with a resolver that is switched off. A `PREROUTING` redirect was
added for anything still addressed to `192.168.110.246`.

That reading was then wrong in the other direction. The rules carried
`-d 192.168.110.246`, so they matched only clients still *addressing* the NAS.
Measured by asking each gateway for a blocklisted name:

```
192.168.8.1      doubleclick.net -> 142.250.129.102     NOT blocked
192.168.110.1    doubleclick.net -> 142.250.129.102     NOT blocked
192.168.120.1    doubleclick.net -> 142.250.129.113     NOT blocked
192.168.130.1    doubleclick.net -> 142.250.129.100     NOT blocked
127.0.0.1:3053   doubleclick.net -> 0.0.0.0             blocked
```

The migration was getting *worse* over time: every five-minute lease renewal
moved one more client off AdGuard and onto the unfiltered resolver. What the plan
called the target state was being actively undone by the DHCP change meant to
deliver it. The fix was to drop the destination match entirely and redirect all
DNS on each client bridge, which makes the stale-lease case a subset.

The way this one was wrong is worth more than the fix. The first conclusion came
from dnsmasq's query log going quiet, and it went quiet because those clients had
not yet renewed. The second came from a probe run on the router, which is
[§5](#5-the-measurement-trap) and was not a client test at all.

### 4.2 `dns_enabled` alone does not put the VLANs on AdGuard

The plan assumed the vendor switch was the mechanism. It is not, on this
firmware. `dns_enabled='1'` populates `adg_redirect`, but that chain is reached
only from two `dns_dispatcher` jumps for `br-lan.1` and two for `br-guest`.
`br-lan.10`, `br-lan.20` and `br-lan.30` are not covered at all, which is where
every device the plan cares about lives. The plan's Gate 6 was unreachable
through `dns_enabled`, and the plan's Evidence had recorded that the rule existed
without ever checking which interfaces it matched.

The consequence runs the other way from what the plan said: the per-bridge rules
are not a temporary bridge, they are the only mechanism that puts a VLAN client
on AdGuard, and they are load-bearing for the target state.

### 4.3 `fw3 reload` does not flush `PREROUTING`

The nat `PREROUTING` chain is built-in; `fw3` flushes only the chains it created.
Anything inserted directly into `PREROUTING` survives a reload, and because the
include re-inserted on every run, a reload was not idempotent. Eighteen rules
were live at one point. The include now strips its own rules before inserting,
and three consecutive runs leave exactly the same set.

This is also why "the rules exist and point at 3053" was not the proof it looked
like: a duplicate rule is invisible to a check that only asks whether a correct
one is present.

### 4.4 `fw3` does not re-run `/etc/firewall.user` at all

§4.3 was true and incomplete, and the missing half mattered more.
`/etc/firewall.user` is `firewall.@include[0]` and had **no `reload` option**,
which defaults to off. Every other include that matters sets `reload='1'`. So
`fw3 reload` rebuilt the vendor's `adg_redirect` from `dns_enabled` and never
re-ran the include. The two halves of the redirect moved by different mechanisms
and only one of them was plugged into a reload.

Two bugs fell out of that. The first: the watchdog changed `dns_enabled` and
re-ran the include by hand, so after one fallback-and-recover cycle the flag said
`1` while `adg_redirect` held nothing. An existing test went red and named it.

The second would have taken the house down during a fallback. With the watchdog
calling `fw3 reload`, the include is not re-run, so the fallback set
`dns_enabled='0'` and left all ten redirect rules pointing at `3053` with AdGuard
Home stopped. Every client would have been sent to a dead resolver: the outage
the watchdog exists to prevent, produced by the watchdog. It was invisible from
the router, because that is [§5](#5-the-measurement-trap) again.

Fixed by registering the include for reloads, so one `fw3 reload` moves both
halves:

```sh
uci set firewall.@include[0].reload='1' && uci commit firewall
```

### 4.5 The router's own reboot had a window

The router's firewall starts at `S19` and AdGuard Home at `S99`, with 48 init
scripts and `network` (`S20`) between them. For that span every client was
redirected at a resolver that was not listening. Nothing else catches it: the
watchdog needs three consecutive failures and cron starts at `S50`, inside the
window.

`router/firewall.user` now probes AdGuard before choosing it and falls back to
dnsmasq, writing that decision back to `/etc/arrdns-port` so the file, the rules
and the watchdog agree. The watchdog restores AdGuard on its next tick.

### 4.6 IPv6 was never outside the query path

The plan's Evidence says IPv6 is unaffected because `ra` and `dhcpv6` are
disabled on the three VLAN pools. That is true of those VLANs and was treated as
settled for five rounds, because every check run was IPv4. It is not the whole
picture: the router's `ip6tables` nat `PREROUTING` carries the same per-bridge
rules, and pi1 querying the router's ULA gets `0.0.0.0` for a blocklisted name.
IPv6 clients were being served and filtered all along.

Both families follow `/etc/arrdns-port`, so the watchdog moves them together,
which is the property that matters. **The mechanism is not identified.** An
earlier explanation (fw3 runs the include once per address family) was measured
and is wrong: fw3 runs it exactly once, and running it by hand creates no IPv6
rules either. `tests/router-dns.bats` asserts both families in one test, which is
the honest position: the behaviour is pinned, the mechanism is not claimed.

### 4.7 `docker stop` is not durable

Both services carried `restart: always`, and Docker restarts a manually stopped
`always` container when the daemon restarts. The next NAS reboot, which 9.2's
week explicitly includes, would have brought both back and silently undone 9.1.
The plan said "`docker stop`, not `down`, not removal" and treated that as
enough; it never mentions the restart policy. `docker update --restart=no` fixed
it, and `no` has no daemon-restart exception, so the stopped state is durable by
construction.

The follow-up mattered too: a compose `up -d` anywhere at boot would have
restarted them regardless of policy. Nothing does it. No systemd unit mentions
`docker compose`, there is no `@reboot` entry, and `rc.local` says nothing about
Docker, so the stack comes up purely through restart policies. Checked on the
live NAS rather than assumed.

### 4.8 A retirement can report success and remove nothing

`pihole.lan` resolved to Traefik's macvlan, which is not the problem; the
problem is that the record outlived the service. `dnsmasq-local-names.sh`
decided which router records it owned by **name**, against the record file. So
dropping a name from that file moved its router record into the foreign bucket,
"a record this script does not own, left alone", and the script printed `no
change. The router already carries all 18 records` while the retired name went on
resolving.

Ownership is now by name **or** by answer: a record pointing at Traefik's
macvlan, or at the zone's own answer, is one this script wrote whatever it is
called. A hand-added record pointing anywhere else is still left alone, which is
what the foreign bucket is for. Both directions have a test, and the mutation
corpus kills the name-only rule.

### 4.9 The AdGuard generator asserted a flag the migration changed on purpose

`adguard-configure.sh` verified after writing that `dns_enabled` was still
literally `0`. That was right while Phase 3 staged a resolver and became wrong
the moment the migration turned it on for good: every correct run ended in
`FAIL` immediately after installing the config. It now reads the flag before
writing and fails only if the run moved it, which is the property the check was
for.

Both this and §4.8 were found by the checks the closure plan already specified,
not by reading code: the dry run said "no change" for a record that needed
removing, and the generator printed FAIL after a successful install.

---

## 5. The measurement trap

**A query the router sends to its own address is not a client test.** It
originates locally, traverses `OUTPUT`, and never meets `PREROUTING`, so it is
answered by dnsmasq while clients are being redirected to AdGuard.

This produced two wrong conclusions and one near-miss in this migration. The
Round 1 conclusion that "VLAN clients moved to AdGuard" rested on a four-gateway
probe run from the router; what it actually showed is that dnsmasq does not
block, which was never in question. During the watchdog work, a check run on the
router reported blocking broken when it was not. And the watchdog's fallback
looked perfect from the router while the client path was black-holed.

One further reading was wrong for a different reason and is kept because it is
the same shape: the reboot monitor's NAS-liveness column said `DOWN` on all 99
samples, including before the reboot. That is ICMP from VLAN20 to VLAN10 being
filtered, not a NAS outage. **A column that reads the same in both states
measures nothing.**

The only vantage point that can see the client path is a real client. pi1 is the
one used throughout: `ssh pi@pi1.local 'dig +short doubleclick.net'`.

---

## 6. Live-only state that is not in this repo

Everything below is on `arr-stack-router` and nowhere else. The repo's copies are
`router/firewall.user` and `router/arrdns-watchdog.sh`, which are meant to be
byte-identical to what is deployed; the rest exists only on the device.

- `/etc/firewall.user` — the include, registered as `firewall.@include[0]` with
  `reload='1'`. Strips its own rules, probes AdGuard at boot, inserts per-bridge
  `REDIRECT`s from `/etc/arrdns-port`.
- `/etc/arrdns-port` — `53` or `3053`. The switch the watchdog moves, read by the
  include and by the watchdog.
- `/usr/sbin/arrdns-watchdog.sh` — cron, every minute
  (`* * * * * /usr/sbin/arrdns-watchdog.sh` in `/etc/crontabs/root`). Three
  consecutive failures move the house to dnsmasq; three successes move it back.
  A deliberate `dns_enabled='0'` is recorded as `reason=operator` and never
  fought.
- `/var/log/arrdns-watchdog.log` — every transition, including the boot-time
  fallback. **`/var/log` is tmpfs, so this does not survive a reboot**; moving it
  to `/etc` is an open item (§8).
- The four `dhcp_option 6` entries and the shortened lease times, and
  `/root/dns-pools-backup-20260921-122846.txt` — the rollback record.
- `/etc/AdGuardHome/config.yaml` — the encrypted upstreams, the `.lan` rewrites
  and the blocklist, written by `scripts/adguard-configure.sh`. The admin UI is
  reachable only from the maintenance VLAN.

**The plan's own gate.** `adguardhome.config.dns_enabled='1'` plus the include's
rules is what makes AdGuard answer for the house. It is not what puts the VLANs
on AdGuard, which is [§4.2](#42-dns_enabled-alone-does-not-put-the-vlans-on-adguard).

---

## 7. Open items

### 7.1 The soak (9.2/9.3) has to pass on the calendar

Gate 9 is "a week with no traffic to the NAS resolver and no incident", starting
2026-09-21. The parts answerable early are answered: the stopped services stay
stopped across a NAS reboot (§4.7), and no real LAN client's last query is later
than the cutover.

9.3's stated method is unusable and the reason is the plan's own ordering:
it says to confirm no client queries the NAS resolver "from the Pi-hole query
count over seven days", and 9.1 stops the container. A stopped Pi-hole counts
nothing, so the measurement became impossible the moment the step before it ran.
The intent was answered from the database in the stopped container's volume
instead:

```
total queries ever        1,124,819
last query per client     127.0.0.1 (itself)      15:23:07
                          172.20.0.13 uptime-kuma 14:51:09
                          172.20.0.3  gluetun     14:44:14
                          192.168.120.231/.208/.150/.114/.228
                                     all between 10:50 and 11:15
queries after the stop    0
```

That signal is weaker than it reads, and the difference matters: the router
redirects anything addressed to the NAS, so a client left pointing at
`192.168.110.246` is answered by AdGuard and never reaches Pi-hole. A zero count
is guaranteed by the redirect, not earned by the migration. The strong evidence
is that the resolver has been off since 2026-09-21 and nothing noticed.

The database lives in `arr-stack_pihole-etc-pihole`, which was backed up before
removal, so this stays checkable.

### 7.2 The two config volumes are still on the NAS

`arr-stack_pihole-etc-pihole` and `arr-stack_dnscrypt-config` are intact and are
no longer declared in the compose file. The containers are gone. Backups taken
before removal are in `/volume1/docker/arr-stack-backups/`:

```
pihole-etc-pihole-20260921-200504.tgz   29M   37 entries
dnscrypt-config-20260921-200504.tgz     75K   14 entries
```

The Pi-hole one was restored and read back before removal, not just counted:
`pihole-FTL.db`, 70,017,024 bytes, header `SQLite format 3`. Removing the volumes
isn't scheduled; they are the rollback path, and they cost 80 MB.

### 7.3 The watchdog log does not survive a reboot

`/var/log` is tmpfs, so the transition most worth keeping afterwards, the
boot-time fallback, is the one it loses. Moving it to `/etc` (the overlay) is a
one-line change, deferred rather than dropped.

### 7.4 The tailnet is filtered, and that was a decision

A tailnet device resolves through AdGuard and gets ad blocking, same as a device
at home, because `tailscale0` is in the include's interface list. That was
measured and chosen on 2026-09-21, not inherited: before it, a tailnet query for
a blocklisted name returned a real address while a bridge client got `0.0.0.0`.
`ARRDNS_IFACES` overrides the list for a router where the tailnet should reach
dnsmasq unfiltered.

### 7.5 No client has ever been tested from `vlan30`

VLAN30 does not exist on this network. The plan's "every VLAN" therefore cannot
be done, and the reason is not a gap in the work: there is no such client
population to test. The rules cover `br-lan.30` anyway, and
`tests/lib-router-dns.bats` asserts it synthetically.

---

## 8. Traps

Short versions of the things that cost time here. Each one has a fuller entry
above.

1. **A query from the router to its own address is not a client test** (§5).
   Re-measure from a real client before believing a DNS conclusion.
2. **`fw3 reload` does not flush `PREROUTING`** (§4.3), so an include that
   inserts without stripping accumulates. Eighteen rules were live at once.
3. **`fw3 reload` does not re-run `/etc/firewall.user`** unless the include has
   `reload='1'` (§4.4). Two halves of one redirect moved by different mechanisms.
4. **`dns_enabled='1'` is not enough on this firmware** (§4.2): GL.iNet wires its
   dispatcher for `br-lan.1` and `br-guest` only.
5. **`docker stop` does not hold a `restart: always` container across a daemon
   restart** (§4.7). Use `docker update --restart=no` and check the policy.
6. **A green guard is not a working guard.** Three of the guards in this
   migration could not fail when first written: the watchdog's `probe_ok` read
   dig's error text off stdout and exited 0, so 92 bytes of "connection refused"
   scored as *up*; `tests/router-dns.bats` judged the pieces and never the
   connection between them, which is how a green run coexisted with three
   uncovered VLANs; and `dnsmasq-local-names.sh`'s name-only ownership let a
   retirement report success and remove nothing (§4.8). Each was found by
   running it.
7. **`grep -qE '\t'` behaves differently on BSD and GNU grep.** BSD reads a tab,
   GNU reads a literal `t`. A test that passes locally can be inert on Linux.
8. **A mutation that changes nothing is scored ERROR, and it should be.** Two
   corpus entries went stale in this work by naming code that had been rewritten,
   and CI caught both.
9. **A literal count in a test fails on exactly the change it should welcome.**
   Five assertions pinned record counts here; retiring one name broke them all
   and the fix is to derive the number from the record file.
