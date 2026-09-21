# DNS migration to AdGuard Home on the router Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpower-subagent-driven-development (recommended) or superpower-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the house's DNS off the NAS onto the router so the NAS can be powered off without taking internet access with it, then retire the NAS Pi-hole and `dnscrypt-proxy` — with no moment in which any client is left pointing at a resolver that cannot answer.

**Architecture:** The router already runs `dnsmasq` on `:53` on every VLAN interface and already ships AdGuard Home, disabled, listening on `:3053`. GL.iNet's `/etc/firewall.dns_order` installs a NAT `REDIRECT --to-ports 3053` for `tcp/udp dport 53` **only when `adguardhome.config.enabled='1'` and `adguardhome.config.dns_enabled='1'`** (line 31). That gives the migration two separable halves:

- **Which resolver answers** is a firewall rule on the router. Clients keep querying the same IP throughout. Cutover and revert are seconds, with no lease propagation.
- **Which IP clients query** is `dhcp_option 6`. This is the client-visible, slow-propagating half, and it is the only part that can strand a device.

The plan does the firewall half first (staged, tested, reversible), then the DHCP half pool by pool, and only then removes the NAS resolver.

**Tech Stack:** OpenWrt 21.02 vendor build (`fw3`/iptables, `use_fw4='0'`), AdGuard Home 0.107.73 as shipped by GL.iNet, dnsmasq-full 2.92, bats-core + bats-assert, Playwright e2e, Docker Compose on the NAS.

**Spec:** No separate spec document. The requirement is "the NAS being off must not remove internet access". The measurements this plan is sized against are in **Evidence**; do not re-derive them.

---

## Evidence

Measured 2026-09-19 on the live router (via `ssh pi@pi1 'ssh arr-stack-router ...'`), the NAS, and pi2. These are the facts the plan rests on.

| Measurement | Value | Source |
| --- | --- | --- |
| Pools advertising an IPv4 resolver | 4 — `lan`, `vlan10`, `vlan20`, `vlan30` | `uci show dhcp` |
| Resolver advertised by all 4 | `192.168.110.246` (NAS Pi-hole), single value | `dhcp.<pool>.dhcp_option='6,192.168.110.246'` |
| `guest` pool IPv4 resolver | none advertised, so dnsmasq advertises itself | `dhcp.guest` has no `dhcp_option` |
| DHCP lease time | `12h` on `lan`, `vlan10`, `vlan20`, `vlan30` | `uci show dhcp` |
| **IPv6 handout on `vlan10`/`vlan20`/`vlan30`** | **`dhcpv6='disabled'`, `ra='disabled'` — no IPv6 resolver is handed out** | `uci show dhcp` |
| IPv6 DNS handed out | only `dhcp.lan.dns='fde0:4646:77b8::1'`, `dhcp.guest.dns='fde0:4646:77b8:1::1'`; both are the router | same, `ip -6 addr` |
| Zone `lan` forward policy | `ACCEPT`, and `input='ACCEPT'` | `zone_lan_forward` ends `zone_lan_dest_ACCEPT` |
| Zone `vlan10` forward policy | `REJECT` + `input='REJECT'`, one pinhole | `zone_vlan10_forward` ends `zone_vlan10_dest_REJECT` |
| Zone `vlan20` / `vlan30` policy | `forward='REJECT'`, `input='REJECT'` | generated `iptables` |
| The only cross-VLAN DNS rule | `vlan20-to-pihole-dns` (`vlan20`→`vlan10`, tcp/udp 53) | `firewall.@rule[31]` |
| `Allow-DNS-vlan*` rules | land in each zone's **input** chain, permitting only dport 53 **to the router** | generated `iptables` |
| Non-53 ports to the router from VLAN20 | port 80 and 443 are **listening** yet time out at ~1020 ms | `nc -z` from the Mac |
| Same ports from the maintenance VLAN | port 80 and 443 OPEN in 6 ms | `nc -z` from pi1's `eth0` |
| Port 3053 from VLAN20 / from maintenance | dropped ~1025 ms / fails fast at 6 ms (nothing listening) | same two probes |
| Accept path for non-53 router traffic | `ACCEPT all ctstate DNAT` in each zone input chain — matches only already-redirected traffic | `iptables -L zone_vlan20_input` |
| Router model / RAM / overlay | GL-MT6000 / 1,013,116 kB (667,264 kB free) / 6.7G free | `ubus call system board`, `/proc/meminfo`, `df -h` |
| AdGuard Home packages | `adguardhome-conntrack 0.107.73-2`, `gl-sdk4-adguardhome`, `gl-sdk4-ui-adguardhome` | `opkg list-installed` |
| AdGuard Home state | `enabled='0'`, `dns_enabled='0'`, no process running | `uci show adguardhome`, `ps` |
| AdGuard Home DNS listener | `bind_hosts: [0.0.0.0]`, `port: 3053` | `/etc/AdGuardHome/config.yaml` |
| AdGuard Home web UI | `address: 0.0.0.0:3000`, **`users: []` — no credential configured** | same |
| AdGuard Home upstreams today | `8.8.8.8`, `9.9.9.9` plain, bootstrap Quad9 | same |
| `adg_redirect` chain at `dns_enabled='0'` | **exists and is empty** (1 reference, no rules) | `iptables -t nat -L adg_redirect` |
| dnsmasq `:53` binds | `192.168.8.1`, `192.168.9.1`, `192.168.110.1`, `192.168.120.1`, `192.168.130.1`, `127.0.0.1`, tailscale, the router's ProtonVPN address | `netstat -lntup` |
| Disabled `iot` pool | `network.iot` is configured at `192.168.10.1` on `br-iot`, but **`network.iot.disabled='1'`** — the bridge does not exist and no `iot` interface is registered, so dnsmasq never binds `192.168.10.1`. `dhcp.iot` advertises no resolver, so it is not a migration target | `uci show network`, `ip -4 addr`, `ubus list network.interface.*` |
| dnsmasq `address` option support | yes — `append_address()` at `/etc/init.d/dnsmasq:172`, wired at `:1087`, emits `--address=$1`; `address_as_local` defaults to `0` | `/etc/init.d/dnsmasq` |
| Pre-existing `local='/lan/'` | set; stops `.lan` queries being forwarded upstream. **It makes dnsmasq authoritative over the zone with no data, so an unknown `.lan` name comes back `NXDOMAIN`, not `NODATA`** — measured 2026-09-19 against the router's `:53`. The NAS Pi-hole answers the same question with `NODATA` (`NOERROR`, empty), because `address=/lan/::` gives dnsmasq local data for the zone. The two resolvers therefore differ on names that do not exist, and 3.6's parity harness has to name that as a deliberate difference rather than discovering it | `uci show dhcp`, `dig nope.lan @192.168.120.1` vs `@192.168.110.246` |
| dnsmasq `confdir` | `/tmp/dnsmasq.d` — tmpfs, does not survive reboot | `uci show dhcp` |
| dnsmasq reload trigger | `procd_add_reload_trigger "dhcp" "system"` — fires only if a `config.change` event is emitted | `/etc/init.d/dnsmasq:1370` |
| Who emits `config.change` | `/sbin/reload_config`, and **nothing calls it except `/etc/init.d/boot`** | `grep -rl reload_config /etc/init.d/` |
| Effect of `uci commit dhcp` alone | emits nothing; dnsmasq keeps serving the old rendered config | consequence of the two rows above |
| `clean_conntrack()` scope | deletes only DNS flows — udp/tcp dport 53 and `2x53`/`4x53` — **not** the whole table | `/lib/functions/vpn_func/route_policy_func.sh:43` |
| Firewall reload side effect | runs `clean_conntrack` at the end of `setup_rules` | `/etc/firewall.dns_order:505` |
| `.lan` records to migrate | 19 (18 hostnames + `address=/lan/::`) | `pihole/dnsmasq.d/02-local-dns.conf.example` |
| NAS Pi-hole upstream | `172.20.0.6#5053` (dnscrypt-proxy container, same host) | `pihole-FTL --config dns.upstreams` |
| gluetun resolver | `DNS_ADDRESS=172.20.0.5`, `depends_on: pihole: service_healthy`, own DoT resolver present | `docker inspect gluetun`, compose |
| gluetun outbound allow list | `192.168.110.0/24,192.168.120.0/24,172.20.0.0/24,10.8.1.0/24` — **`192.168.8.0/24` absent** | same |
| `check-dns-duplicates.sh` scope | compares the NAS's `02-local-dns.conf` **against `pihole.toml` inside the container** — it is not a router-vs-AdGuard check | `scripts/lib/check-dns-duplicates.sh` |
| Repo files referencing Pi-hole/dnscrypt | 25+ across compose, scripts, tests, docs | `grep -rniE 'pihole\|172\.20\.0\.5\|dnscrypt'` |

### The property that makes this safe

Under the redirect model the client's configured resolver is the router's address, and it never changes during cutover or revert. Flipping `dns_enabled` changes which process answers, not where packets go. **Revert is `uci set adguardhome.config.dns_enabled='0'` plus `/etc/init.d/firewall reload` — seconds, no reboot, no DHCP renewal.** The risky, slow half (`dhcp_option 6`) is done separately and first, while the NAS resolver is still up as a proven fallback.

### What that property does NOT cover

Two limits were established by adversarial review on 2026-09-19 and are load-bearing:

1. **The staged resolver cannot be reached by any VLAN client.** Port 3053 is reachable only from the maintenance VLAN. `Allow-DNS-vlan*` permits dport 53 only, and the only other accept for router-bound traffic is `ctstate DNAT`, which requires the redirect to already be on. So "test AdGuard Home in parallel from every client" is not available. The off-box vantage is pi1 over the maintenance VLAN; the client-path test can only happen once the redirect is live.
2. **`uci commit` does not reload anything.** `/sbin/reload_config` is what emits `config.change`, and nothing calls it except `/etc/init.d/boot`. Every DHCP-side change in this plan must be followed by an explicit `/etc/init.d/dnsmasq reload`, or the change is written to flash and never takes effect.

### Why not Pi-hole on a Pi

Recorded here so it is not re-litigated. Pi-hole on OpenWrt needs glibc-linked FTL, PHP, lighttpd and systemd units against musl and procd; the vendor firmware carries only GL.iNet's own package feeds, so the pieces are not installable. Moving Pi-hole to pi2 (VLAN20) additionally required new `vlan10 → vlan20` and `vlan30 → vlan20` forward rules, because `zone_vlan10_forward` ends in REJECT and the `Allow-DNS-*` rules are input-only. It also replaces "the NAS is a single point of failure" with "the Pi is a single point of failure", while the router is already the point of failure for internet access itself.

---

## Target architecture

```
client ──▶ router IP :53 ──▶ [firewall REDIRECT dport 53 → :3053]
                                 │
                                 ├─ dns_enabled='0' ──▶ dnsmasq :53   (DHCP + local names)
                                 └─ dns_enabled='1' ──▶ AdGuard Home :3053 ──▶ DoH upstream
                                                            │
                                                            └─ .lan rewrites → Traefik macvlan
```

- The router is the only resolver any client is configured with. `dhcp_option 6` is deleted from all four pools so dnsmasq advertises itself.
- AdGuard Home owns resolution and blocking; `dnsmasq` keeps DHCP and the local lease names.
- The NAS Pi-hole and `dnscrypt-proxy` are stopped, then removed after the observation window.
- gluetun's `DNS_ADDRESS` becomes `192.168.110.1` (same subnet as the NAS, already in `FIREWALL_OUTBOUND_SUBNETS`).
- IPv6 is unaffected: `ra` and `dhcpv6` are `disabled` on all three VLAN pools, so there is no IPv6 resolver handout to migrate. `lan` and `guest` already point at the router.

---

## Global constraints

- The test entry point is `./tests/run-tests.sh`, never `npm test`. `npm` exists on neither pi1 nor the NAS.
- Python tests run through `./tests/toolkit/pytest.sh`, which exits **77** (never 0) when docker is unavailable.
- Every new or changed guard needs an entry in `tests/mutation/corpus/`, and `./tests/mutation/run-mutations.sh` must show the named test going red. Four guards in this repo were merged while being incapable of failing; a guard that cannot fail is worse than no guard.
- No change reaches `main` before it is verified on the NAS. `main` is protected; land work through a PR.
- Never pass `--remove-orphans` to any `docker compose` command. Recreate a service only via the compose file that defines it.
- **The router's configuration is not in this repo.** Live-only state has already cost this project once (the exit-node work). Every router change lands in `router/` in the same commit that applies it, plus a committed backup under `docs/`.
- **Every router-side change is applied by a committed, idempotent, self-verifying script** — never by ad-hoc `uci` commands typed once and forgotten. A script that reports success while the change did not take effect is the failure mode this plan exists to prevent.
- **`uci commit` is followed by an explicit service reload.** `uci commit dhcp` then `/etc/init.d/dnsmasq reload`; `uci commit adguardhome` then `/etc/init.d/adguardhome restart` and `/etc/init.d/firewall reload`. Nothing reloads on commit.
- The NAS stays on `main` throughout, with one exception: another plan in flight may hold it on a feature branch for a declared verification window. Confirm the branch before any phase that touches the NAS, and leave it on `main` when you stop. See *Running this in parallel with other work*.

---

## Running this in parallel with other work

This plan shares a repository and a NAS with other plans that may be in flight. On 2026-09-19, `fix/usenet-inflight-brake-and-queue` sat 20-odd commits ahead of `origin/main`, unmerged, changing `scripts/usenet-blackhole.sh`, `scripts/usenet-queue-report.sh` and their tests. Nothing here means the two must be serialized. Each point below is a default that would bite if it were followed without thinking.

**The file sets are disjoint, and that was checked rather than assumed.** The nine files that branch changes and the files this plan creates or rewrites have no path in common; that was checked by diffing `git diff --name-only origin/main..HEAD` against the phase list below, not by reading the two plans and assuming. One area does rub together: that branch edits `tests/mutation/corpus/usenet-blackhole.sh` and `tests/mutation/README.md`, so 1.5 should put its guards in a new corpus file (`tests/mutation/corpus/dns.sh` or similar) and leave the mutation README's shared prose alone. `docs/TROUBLESHOOTING.md` already carries an `## Everything Is Unreachable At Once` section from the merged PR #101, and 8.8 rewrites that file.

**Branch from `origin/main` explicitly.** This plan inherits nothing from whatever happens to be checked out.

```bash
git fetch origin
git worktree add ../arr-stack-dns -b fix/dns-adguard-router-migration origin/main
```

This document was untracked when the worktree was created, so copy it in (`cp docs/superpowers/plans/2026-09-19-dns-adguard-router-migration.md ../arr-stack-dns/docs/superpowers/plans/`) and commit it there as the plan of record; it is not on `origin/main` yet. Use a worktree so the two plans cannot take turns moving the same working tree's HEAD mid-task. A bare `git checkout -b` from a working copy parked on another plan's branch would carry that plan's unmerged commits into this plan's pull request, and the reviewer would be reading two bodies of work. Adjust the path if `../arr-stack-dns` is taken.

**The NAS's deploy checkout is shared, and this plan needs it on `main`.** Gate 0 requires it, and every phase below assumes the files at `/volume1/docker/arr-stack` are `main`'s. Another plan's verification flow (`scripts/sync-nas.sh`) parks that checkout on a feature branch for the length of its window and returns it to `main` afterwards. Before any phase that touches the NAS, check rather than assume. The `cloud-nas` alias in `~/.ssh/config` carries the key, and the explicit form is what the snippets below use:

```bash
ssh -i ~/.ssh/ugreen_nas_ed25519 leoleg@192.168.110.246 \
  'cat /volume1/docker/arr-stack/.git/HEAD'
# expect: ref: refs/heads/main
```

If it names a feature branch, another plan owns the box right now. Wait, or take the window explicitly. Do not run 8.2 through 9.1 against a branch whose config is live.

**Do not cold-boot the NAS with an armed ingest timer over a full queue.** 8.2 requires a reboot. The usenet ingest consumes a watch folder outside this plan's scope, holding 516 items on 2026-09-19, and a cold boot arms its timer. On 2026-09-18 that same sequence drove the NAS into an I/O stall that took every service on it down for twelve hours; `docs/NAS-LOAD-INCIDENT-2026-09-18.md` is the record. Check before rebooting:

```bash
ssh -i ~/.ssh/ugreen_nas_ed25519 leoleg@192.168.110.246 '
  export XDG_RUNTIME_DIR=/run/user/1000
  systemctl --user is-enabled usenet-blackhole.timer
  ls /volume1/data/usenet/blackhole/nzb | wc -l'
```

An enabled timer over a queue in the hundreds means stopping the timer before you reboot.

**A cold boot does not currently arm the user timers at all**, because the user manager starts before `/home` is mounted. That is another plan's subject, and it cuts both ways here: today it is accidentally protective, and once it is fixed, 8.2's reboot starts the ingest for real. Check the timer state instead of relying on either behaviour.

---

## Phases

Each phase ends at a **gate**. A gate has pass criteria and a rollback trigger. Do not start the next phase until the gate passes.

### Phase 0 — Baseline, backup, and the rollback kit

Nothing changes for any client in this phase.

- [x] **0.0 Create the directories the rest of this phase writes into.**

```bash
mkdir -p router/backup
```

`router/` and `router/backup/` do not exist today, and 0.1's redirect target does not create itself. Without this, 0.1 writes nothing and exits without an error anyone is told to look for.

- [x] **0.1 Capture the router's DNS state.**

```bash
ssh pi@pi1 'ssh arr-stack-router sh -s' <<'EOF' > router/backup/2026-09-19-dns-state.txt
uci show dhcp; uci show firewall; uci show adguardhome; uci show network
EOF
test -s router/backup/2026-09-19-dns-state.txt || { echo "capture failed"; exit 1; }
```

Capture the redirect machinery alongside the UCI state, because the UCI dump does not contain it and open question 2 is closed here:

```bash
ssh pi@pi1 'ssh arr-stack-router sh -s' <<'EOF' > router/backup/2026-09-19-redirect.txt
grep -nE 'adguardhome|dns_enabled|3053|adg_redirect|dns_dispatcher' /etc/firewall.dns_order
iptables -t nat -L adg_redirect -n -v
iptables -t nat -S | grep -i adg
EOF
test -s router/backup/2026-09-19-redirect.txt || { echo "redirect capture failed"; exit 1; }
```

The assertion that closes open question 2 is that `dns_enabled` appears exactly once in `/etc/firewall.dns_order` — line 31, gating `adg_handle_dns`. If a second consumer shows up, the file has changed under this plan and the flip in 6.2 is no longer a single-variable change.

**Redact the ProtonVPN WireGuard private key before committing `2026-09-19-dns-state.txt`.** `uci show network` includes `network.protonvpn.private_key`, and this file is committed. Replace that one value in place, leave the surrounding structure readable, and say in a header why the line is redacted. A private key in a git repository is not undoable by a later commit, and this repo's own suite scans tracked files for exactly this. The line was the only credential in the capture; the firewall, dhcp and adguardhome sections carry none.

- [x] **0.2 Back up the AdGuard Home config and data, outside the repo.**

```bash
ssh pi@pi1 'ssh arr-stack-router tar czf - /etc/AdGuardHome' > ~/agh-backup-2026-09-19.tgz
```

Deliberately outside the repo. `config.yaml` currently holds `users: []`, so no credential is committed today, but it will hold an admin hash from Phase 2 onward. Committing it into a repo whose test suite scans for secrets is a needless hazard.

- [x] **0.3 Record the baseline answer matrix.** Every resolver question this migration is judged on, answered by the NAS Pi-hole today. Commit as `tests/fixtures/dns-baseline.txt`. This file is the oracle for Phase 3's parity test. `tests/fixtures/` already exists.

- [x] **0.4 Write `scripts/dns-rollback.sh`** — one command that returns every pool to the NAS resolver. It must:

```
for pool in lan vlan10 vlan20 vlan30; do
  uci delete dhcp.$pool.dhcp_option 2>/dev/null
  uci add_list dhcp.$pool.dhcp_option='6,192.168.110.246'
done
uci set adguardhome.config.dns_enabled='0'
uci set adguardhome.config.enabled='0'
uci commit dhcp
uci commit adguardhome
uci commit firewall
/etc/init.d/dnsmasq reload          # REQUIRED: uci commit reloads nothing
/etc/init.d/firewall reload
```

Three things it must get right, each of which an earlier draft of this plan got wrong:

- **All four pools, not just `lan`.** A loop, not a comment. The maintenance pool is easy to forget precisely because it carries the fewest clients.
- **`/etc/init.d/dnsmasq reload` after the commit.** Nothing emits a `config.change` event, so without this the DHCP server keeps advertising the old option indefinitely while the script reports success.
- **Qualified `uci commit` per package.** A bare `uci commit` commits every half-applied change in every config file.

Its self-check must assert the **advertised value**, not that some resolver answers:

```bash
for pool in lan vlan10 vlan20 vlan30; do
  uci get dhcp.$pool.dhcp_option | grep -q '192.168.110.246' || { echo "$pool not reverted"; exit 1; }
done
dig +short +time=2 +tries=1 example.com @192.168.110.246 >/dev/null || { echo "NAS resolver down"; exit 1; }
```

- [x] **0.5 Prove the rollback kit works — on a copy, not on production.**

It is **not** a no-op at baseline: it rewrites `dhcp_option` on four pools (changing the UCI representation from a string to a list), commits three config files, reloads dnsmasq and reloads the firewall, which flushes DNS conntrack. Running it "for real before any change" is itself a production change.

Rehearse it on a scratch copy of `/etc/config` with the `uci` calls pointed at a temporary config dir, assert with `DRY_RUN=1` that it emits the expected command sequence, and assert the loop covers four pools. Then run it once for real **during Phase 5's window**, as the first rung of the rollback ladder, before any pool is moved — that is the rehearsal that matters and it happens when a rollback is already a live possibility.

Per repo convention this lives in `tests/mutation/corpus/`, with a red test proving the guard can fail.

**The scratch config dir must be passed as `uci -c <dir>`, never as the `UCI_CONFIG_DIR` environment variable.** Measured 2026-09-19: this build's uci accepts `UCI_CONFIG_DIR`, does not honour it, and writes to the live `/etc/config`. A rehearsal written that way is a production change wearing a rehearsal's name — it was tried, it wrote `dhcp.lan.dhcp_option` in production, and the production file's md5 was checked before and after to establish it. `uci -c <dir>` on the same copy did not touch production. The rollback script therefore takes `UCI_CONF` and routes every uci call through `-c`; a mutation in the corpus removes that and the test catches it.

**Correction, later the same day: `-c` is not reliable either, and the plan should not tell you it is.** While measuring `del_list` semantics in Phase 4, a `uci -c /tmp/<dir>` probe wrote `/c/3 /b/2 /d/4` into the **live** `/etc/config/dhcp`. It was removed and the live config was diffed against the Phase 0 capture, which showed the probe left nothing behind. So the two measurements disagree: `-c` isolated in the first case and did not in the second. **Treat no `uci` invocation on this box as read-only or sandboxed just because it names a directory.** The rehearsal that can be trusted is the stubbed one in `tests/dns-rollback.bats`, which never opens a connection at all; a rehearsal on the live router is a production change that happens to be aimed somewhere else. Keep the `-c` plumbing, because it is what makes the stubbed rehearsal model the real command, and stop describing it as a sandbox.

**Gate 0.** `router/backup/` exists and holds a non-empty capture. Baseline matrix committed and passing against the NAS resolver (50/50 rows as of 2026-09-19). Rollback script covers four pools, reloads dnsmasq, and fails when a pool is left un-reverted — all four properties proven by a mutation in `tests/mutation/corpus/dns.sh` that reintroduces the defect and turns the named test red. `git status` clean, NAS on `main`.

---

### Phase 1 — Acceptance tests first (TDD)

These tests are written before any change and **must fail against the current design**. If a test passes now, it is not testing the migration.

- [x] **1.1 `tests/dns-resilience.bats`** — the anchor test. Asserts that a resolver answering on the router's address is sufficient for a client to resolve a public name, a `.lan` name, and to have a blocked name blocked — with the NAS resolver not consulted. It fails today because the router's dnsmasq knows no `.lan` records and does no blocking.

- [x] **1.2 `tests/router-dns.bats`** — live assertions over the router, in the style of `tests/network-segmentation.bats`, including its vantage-point discipline. Assert:
  - per-pool `dhcp_option 6` state;
  - **`adg_redirect` exists in both states and is empty when `dns_enabled='0'`**, holding `REDIRECT --to-ports 3053` for tcp and udp when it is `'1'`. The chain is declared unconditionally by `iptables-restore`; an "exists iff" assertion fails at baseline;
  - dnsmasq binds `:53` on every **live** VLAN-side interface — `192.168.8.1`, `192.168.9.1`, `192.168.110.1`, `192.168.120.1`, `192.168.130.1` — and not on `192.168.10.1`, because `network.iot` is `disabled='1'` and `br-iot` does not exist. Derive the expected set from the live interface list rather than hardcoding six addresses.

  Must **skip with a reason** everywhere except a host that can reach the router (pi1), never fail silently.

- [x] **1.3 `tests/e2e/dns.spec.ts`** — from the e2e container on the NAS: public resolution, `.lan` resolution, blocked-domain behaviour, **TCP and UDP both** (a TCP-only probe passes while UDP resolution is broken — the trap `network-segmentation.bats` already documents for port 53). Assert on the answer, not on a status code.

- [x] **1.4 The AAAA parity test.** `address=/lan/::` exists because musl/Alpine containers treat AAAA NXDOMAIN as a hard failure. Assert an Alpine container can resolve a `.lan` name when the router is the only resolver. This test is the one most likely to fail late and expensively; it runs from Phase 2 onward. Delivered as `tests/alpine-dns-aaaa.bats`, which points a real `alpine` container at the router with `--dns` and judges it with `getent ahostsv4` (IPv4 answer), `getent hosts` (getaddrinfo not defeated) and an AAAA query (parity with the recorded `::`).

- [x] **1.5 Extend `tests/mutation/corpus/`** with an entry for each new guard, and confirm `./tests/mutation/run-mutations.sh` turns each named test red. Put them in a new corpus file rather than appending to an existing one; another plan in flight edits `usenet-blackhole.sh` and `tests/mutation/README.md`. See *Running this in parallel with other work*.

  One of the two anticipated rubs turned out to be a required edit rather than something to avoid: `tests/shellcheck.bats` derives a no-sweep list from the generative sweep's `TARGETS` and fails when a new production script is missing from `tests/mutation/README.md`. The new scripts had to be listed there, so this branch and the in-flight one both touch that file and the PR will conflict in it. Small and mechanical, but plan for it.

**Gate 1.** `./tests/run-tests.sh` runs, the new tests execute, the ones that must fail do fail for the stated reason, and the mutation corpus kills the new guards. No production change yet.

**Mutation scoring has a stated debt here.** The acceptance tests that are red on purpose cannot be scored by the corpus: the harness runs each named test unmutated first and refuses to score a test that is already failing, so an entry naming one of them would ERROR rather than kill. Coverage for their guards comes from two other places meanwhile — the `dns-matrix-*` mutations score the module they all judge with, and `./scripts/dns-matrix-check.sh` reports 50/50 rows matched against the NAS Pi-hole, which is the correct end state for those rows. When Phase 4 makes the `.lan` rows green and Phase 6 makes the blocked rows green, each becomes scorable and needs its entry. This is recorded in the corpus file itself, not just here.

---

### Phase 2 — Stage AdGuard Home on 3053

`enabled='1'` starts AdGuard Home; `dns_enabled` stays `'0'`, so no redirect is installed and every client keeps using dnsmasq on `:53`.

Impact is small but not zero: `start_service()` calls `/etc/init.d/firewall reload`, and that reload runs `clean_conntrack`, which deletes DNS conntrack entries. Expect a sub-second DNS blip, not a connectivity interruption.

- [x] **2.0 Set an admin credential before leaving the service running.** `users: []` means the web UI has no authentication, and the maintenance VLAN reaches it (port 3000 answers in 6 ms from pi1; the same port is dropped from VLAN20). Left as-is, anything on the maintenance VLAN can rewrite or block any domain for every client. Bind the UI to the maintenance interface rather than `0.0.0.0` if it does not need to be reachable elsewhere.

  **How, because the obvious way does not work here.** `POST /control/install/configure` answers **404**: AdGuard registers the `/control/install/*` routes only when it starts with no config file, and GL.iNet ships a populated `/etc/AdGuardHome/config.yaml`, so the instance counts as configured from first boot with `users: []` sitting in it. The credential therefore goes into the file the way AdGuard stores it — a bcrypt hash under `users:` — and bcrypt has to be computed off-box, because this router has no `htpasswd` and no python: `htpasswd -nBi <user>`, with a leading `$2y$` rewritten to `$2a$`.

  **Verify with `/control/login`, not HTTP Basic.** Measured: `curl -u admin:…` against `/control/status` answers 401 *with the correct password*, because the API authenticates on a session cookie and ignores the Authorization header. A check written with Basic auth reports a working credential as broken, and loosening it to make that go away is how a real mismatch gets waved through.

  Delivered as `router/adguard-stage.sh`, which enables the service, writes the credential only when `users:` is empty, verifies by logging in, and refuses to start at all when it has no credential to set. `tests/adguard-stage.bats` covers the refusals; the credential value itself is not in the repo.

  The bind was left at `0.0.0.0:3000`. It is already unreachable from every client VLAN (only the maintenance VLAN and the tailnet get there), the credential is the control, and narrowing the bind would silently remove remote admin access that nobody asked to lose.

- [x] **2.1 Start it.**

```bash
uci set adguardhome.config.enabled='1'
uci commit adguardhome
/etc/init.d/adguardhome start
```

  Done through `router/adguard-stage.sh` rather than by hand, per the global constraint that router changes go through a committed script. `enabled='1'`, `dns_enabled='0'`.

- [x] **2.2 Verify it answers on 3053 — from the only vantage that can reach it.**

From **pi1 over the maintenance VLAN** (`lan` zone, `input='ACCEPT'` is the only zone that permits it):

```bash
ssh pi@pi1 'dig +short +time=3 +tries=1 example.com @192.168.8.1 -p 3053'
ssh pi@pi1 'dig +short +time=3 +tries=1 example.com @192.168.8.1 -p 3053 +tcp'
```

  Both answered, UDP and TCP, with the same address pair. From the router itself, both transports answered too.

  **One measurement note worth keeping:** the DNS proxy comes up a second or two after the web UI, so a single probe immediately after a restart reports "does not answer" for a resolver that is serving fine moments later. Both the script and any hand-check should poll.

Then settle open question 1 from **on the router**, because pi1 cannot test local-name resolution that only the router's own data can answer:

```bash
ssh pi@pi1 'ssh arr-stack-router "dig +short +time=3 +tries=1 <a-known-dhcp-lease-name> @127.0.0.1 -p 3053"'
```

  Answered, and the answer was no — see open question 1. Note the leases file's fields are `<expiry> <mac> <ip> <hostname> <clientid>`, so the hostname is `$4`, not `$3`.

Do **not** attempt `dig @192.168.x.1 -p 3053` from a client on `vlan10`, `vlan20` or `vlan30`. It is dropped, not merely closed, and a worker who sees that failure will chase a firewall problem that is not a bug.

- [x] **2.3 Confirm the live path is untouched.** The baseline matrix still passes against the NAS, and `iptables -t nat -L adg_redirect -n` shows the chain with no rules.

  Both confirmed after staging: `./scripts/dns-matrix-check.sh` reported `50/50 rows matched` against 192.168.110.246, and `adg_redirect` is declared with no rules while `dns_enabled='0'`.

**Gate 2.** AdGuard Home answers on 3053 from pi1 and from the router. Baseline matrix unchanged. `adg_redirect` present and empty. Rollback trigger: any answer wrong → `enabled='0'`, no client affected.

---

### Phase 3 — Configure AdGuard Home to parity

**How this phase can be executed, because the obvious route is closed.** AdGuard's HTTP API is not usable on this build. GL.iNet patches the binary: `/control/*` is wrapped in `authMiddlewareGLiNet` (the binary carries that symbol, along with `checkToken` and `tokenDate`), and it does not honour AdGuard's own `agh_session` cookie. Measured 2026-09-19 from the router against `127.0.0.1:3000`:

- `POST /control/login` → **200**, `webapi: successful login user=admin ip=127.0.0.1`, and a valid `Set-Cookie`;
- every following request carrying that cookie → **401**, with the server logging `auth: no authentication cookie`. The cookie is provably sent: curl's verbose output shows `> Cookie: agh_session=…`.
- `curl -u admin:…` → **401**. No `WWW-Authenticate` header is offered.

So the API is gated by the router's own auth, not by the `users:` entry, and no token is obtainable without reverse-engineering that middleware. **`/etc/AdGuardHome/config.yaml` is the configuration path**: transform it off-box (the router has no bash, python, perl or PyYAML), push it back, validate with `/usr/bin/AdGuardHome --check-config`, and restart.

This also softens Phase 2's premise, and the correction is worth keeping: with `users: []` the *API* was never open, because GL.iNet's middleware refuses everything without its token. The credential is still correct to set — the browser UI needs it, and defense in depth is not a thing to skip on a device that answers DNS for the house — but the exposure was narrower than "anything on the maintenance VLAN can rewrite any domain".

Restarting AdGuard is free during this phase: `dns_enabled='0'`, so no client is asking it anything.

- [x] **3.1 Replace the plain upstreams** (`8.8.8.8`, `9.9.9.9`) with DoH/DoT. This is what `dnscrypt-proxy` provided before; do not retire it until this is proven.

- [x] **3.2 Add all 19 `.lan` records as DNS rewrites**, pointing at Traefik's macvlan `192.168.110.250`.

- [x] **3.3 Reproduce the AAAA behaviour** for `.lan` so musl/Alpine clients keep working. Open question 3 decides whether this is a configuration change or a design problem, and it is answered here, not in Phase 6.

- [x] **3.4 Add blocklists**, and record the chosen lists in `docs/`.

- [x] **3.5 Add the duplicate guard for the new topology.** The repo's rule is not to define a domain in two places (`docs/LOCAL-DNS.md:63`). This plan deliberately breaks that rule by holding the 19 names in both AdGuard rewrites (3.2) and dnsmasq `address` records (4.1), because `dns_enabled` decides which one answers. Write the check that catches divergence, in the spirit of `scripts/lib/check-dns-duplicates.sh`. Note that script compares the NAS's `02-local-dns.conf` against `pihole.toml` inside the container — it is not, and never was, a router-vs-AdGuard check, so retiring it in 8.6 removes nothing that covered this.

- [x] **3.6 Run the parity harness.** A script that sends the committed baseline matrix to **both** resolvers — the NAS Pi-hole and AdGuard Home — and diffs the answers. AdGuard Home is queried from pi1 on 3053; the NAS from anywhere. Commit as `scripts/dns-parity.sh`, with a bats test that proves it reports a mismatch when one is introduced.

**Gate 3.** `./scripts/dns-parity.sh` reports zero unexplained differences across the full matrix, including the blocked-name and `.lan` rows. Differences that are deliberate (a different CDN edge for a load-balanced name) must be named and allowed explicitly in the fixture, not waved through. The duplicate guard from 3.5 fails when a name is added to one store only. Rollback trigger: parity cannot be reached for `.lan` or blocked names → leave `enabled='1'`, `dns_enabled='0'`; no client impact.

### Phase 3 outcome, 2026-09-19

**Gate 3 passes.** `./scripts/dns-parity.sh 192.168.110.246:53 jump=pi@pi1.local:192.168.8.1:3053` reports **50 rows compared, 0 unexplained, 20 excused**. The same command before the configuration landed reported 41 unexplained, which is the measure of what this phase did.

Applied to the router by `scripts/adguard-configure.sh` — idempotent, and a second run reports "no change" and restarts nothing, which also proves AdGuard does not reserialise `config.yaml` on start:

- **3.1** upstreams are `https://dns.quad9.net/dns-query` and `https://cloudflare-dns.com/dns-query`; `bootstrap_dns` stays on plain Quad9 addresses, because bootstrapping cannot itself be encrypted.
- **3.2** 18 `.lan` rewrites, one per hostname in `pihole/dnsmasq.d/02-local-dns.conf.example`, all answering Traefik's macvlan. Names are parsed from that file rather than hardcoded, and the apex `lan` is skipped.
- **3.4** StevenBlack's hosts list added — the same list the NAS uses, so a blocked name stays blocked — alongside the AdGuard DNS filter. Recorded in `docs/LOCAL-DNS.md`.

**3.3 needed no configuration change, and that is the answer to open question 3.** A rewrite makes AdGuard answer AAAA with `NOERROR` and no answer (NODATA), not NXDOMAIN. musl's failure mode is AAAA *NXDOMAIN*; NODATA is not that, so `::` does not have to be reproduced. Measured on the router, same question to both resolvers:

```
sonarr.lan A     AdGuard :3053 -> 192.168.110.250     NAS :53 -> 192.168.110.250
sonarr.lan AAAA  AdGuard :3053 -> NOERROR <empty>     NAS :53 -> NOERROR ::
```

**Two differences are named, not suppressed.** 18 `.lan` AAAA rows (NAS `::` vs AdGuard NODATA) and `nope.lan` (NAS NODATA vs AdGuard NXDOMAIN) carry `ALLOW-DIFF` with the reason attached. Reproducing `::` would have imported a hack that hands a dual-stack client the unspecified address, which `connect()` maps to loopback. NODATA is the better answer and both keep musl working.

**One gap is left open on purpose.** Reaching that NXDOMAIN means AdGuard asks a public resolver for unknown `.lan` names, which the NAS never did. `bogus_nxdomain: [lan]` answers those locally and closes it. It is not in this phase: it would not change the parity result, and it is a privacy improvement rather than a correctness one. It belongs before the Phase 6 flip, and it is recorded in `docs/LOCAL-DNS.md` as a follow-up rather than smoothed over.

**The duplicate guard is not yet wired into anything.** `scripts/lib/check-dns-divergence.sh` is run by hand; against the live rewrites and the repo record it reports 18 vs 18 and 0 divergences. Its natural home is 8.6, where it replaces `check-dns-duplicates.sh` and `check-domains.sh` in the pre-commit checks as those are retired.


---

### Phase 4 — Teach the router's dnsmasq the local names

Until this is done, moving any client to the router would break `.lan`. Verified gap: `dig sonarr.lan @192.168.120.1` returns nothing today.

- [x] **4.1 Add the `.lan` records to dnsmasq via the `address` list.** The option exists on this build: `append_address()` at `/etc/init.d/dnsmasq:172`, wired at `:1087` by `config_list_foreach "$cfg" "address" append_address "$address_as_local"`, emitting `--address=$1`. `address_as_local` defaults to `0`, so leave it unset.

```bash
ssh pi@pi1 'ssh arr-stack-router sh -s' <<'EOF'
uci add_list dhcp.@dnsmasq[0].address='/sonarr.lan/192.168.110.250'
# ... one per name, plus:
uci add_list dhcp.@dnsmasq[0].address='/lan/::'
uci commit dhcp
/etc/init.d/dnsmasq reload          # REQUIRED: uci commit reloads nothing
EOF
```

Do not write files into `/tmp/dnsmasq.d` — that is the configured `confdir` and it is tmpfs, so records placed there work until the next reboot and then vanish. The pre-existing `dhcp.@dnsmasq[0].local='/lan/'` is complementary, not conflicting: it stops `.lan` queries being forwarded upstream, and these records supply the answers.

- [x] **4.2 Verify immediately, from a host on each live VLAN**, that `sonarr.lan` and `jellyfin.lan` resolve to `192.168.110.250` while the client still uses the NAS resolver. Verify now, not at the gate: a wrong option name or value syntax produces no records and no error.

**Gate 4.** `.lan` names resolve against the router's `:53` from every live VLAN (`lan`, `vlan10`, `vlan20`, `vlan30`; `iot` is disabled and `guest` already points at the router), and the baseline matrix is unchanged for every existing client. Reboot the router once and re-verify, because surviving a reboot is the point of 4.1.

### Phase 4 outcome, 2026-09-19 — resolution half passes, reboot half outstanding

**4.1 applied** by `scripts/dnsmasq-local-names.sh` (idempotent; a second run reports no change, no commit, no reload, identical `md5sum /etc/config/dhcp`). 19 records — the 18 hostnames plus `address=/lan/::` — are in UCI **and** in the config dnsmasq actually loaded (`grep '^address=' /var/etc/dnsmasq.conf.cfg01411c`), with `local='/lan/'` untouched and `/tmp/dnsmasq.d` holding nothing. That last one is the check that matters: a record written into the tmpfs `confdir` would work until the next reboot and then vanish, which is exactly what 4.1 warns about.

**4.2 verified from every VLAN that has a client:**

| Vantage | `sonarr.lan` | `jellyfin.lan` | AAAA | its own resolver |
| --- | --- | --- | --- | --- |
| `vlan10` — the NAS, 192.168.110.246 | 192.168.110.250 | 192.168.110.250 | `::` | 192.168.8.1 |
| `lan` — pi1 eth0, 192.168.8.227 | 192.168.110.250 | 192.168.110.250 | `::` | — |
| `vlan20` — pi2, 192.168.120.241 | 192.168.110.250 | 192.168.110.250 | — | **192.168.110.246, unchanged** |
| `vlan20` — this Mac, 192.168.120.135 | 192.168.110.250 | 192.168.110.250 | — | — |
| `vlan30` — **no client exists** | 192.168.110.250 | 192.168.110.250 | — | answered from the router itself |

`vlan30` is the one gap and it is stated rather than papered over. There is no DHCP lease on `192.168.130.0/24` at all, so the address was queried from the router's own shell. That proves dnsmasq answers on that interface; it does not prove a client on that VLAN resolves, and those are different claims.

pi2's resolver still reading `192.168.110.246` is the point of the phase: the records were added to the router without moving a single client onto it.

**The acceptance tests moved exactly as predicted.** `tests/alpine-dns-aaaa.bats` is now **4/4 green** — the end-to-end musl proof that could not be made in Phase 3, because `--dns` only ever reaches port 53 and port 53 answers with dnsmasq until Phase 6. `tests/dns-resilience.bats` is 5/6, its only failure the blocked-name row, which needs the Phase 6 redirect to reach AdGuard's blocklist. The baseline matrix is still `50/50` against the NAS, every pool still advertises `6,192.168.110.246`, and `dns_enabled` is still `0`.

**The two stores now agree, which is the first time the 3.5 guard has meant anything.** `check-dns-divergence` over the router's dnsmasq records vs AdGuard's rewrites reports 18 hostnames each and 0 divergences. Both are populated, and they match.

**Two traps 4.1 hit that this plan did not name.** `uci -q get dhcp.@dnsmasq[0]` returns the section **type** (`dnsmasq`), not the name (`cfg01411c`), so a script that builds `dhcp.dnsmasq` writes into a section dnsmasq never reads and reports success while `.lan` stays broken — the same failure the phase exists to prevent, arriving by an unnamed road. And "first section of type dnsmasq" is not stable: the tunnel's `wgclient1` section is also a dnsmasq. The section is now identified by the `leasefile` option only the DHCP-serving one carries. Neither was caught by reading; both were caught by tests.

**Reboot survival verified, 2026-09-19.** The router was rebooted with the owner's approval. It came back in about 90 seconds and everything held:

| After the reboot | Value |
| --- | --- |
| `md5sum /etc/config/dhcp` | `66f2755a…`, **byte-identical to before the reboot** |
| `grep -c '^address=' /var/etc/dnsmasq.conf.cfg01411c` | 19 — re-rendered from flash at boot |
| `/tmp/dnsmasq.d` entries | **0** |
| `dns_enabled` / `enabled` | `0` / `1` |
| dnsmasq / AdGuard | new PIDs, both up |
| `sonarr.lan` / AAAA / pool `lan` | `192.168.110.250` / `::` / `6,192.168.110.246` |

The empty `/tmp/dnsmasq.d` next to a live 19-record rendered config is the proof 4.1 was asking for: the records cannot have come from the tmpfs confdir, because after a reboot there is nothing in it. Re-checked from the NAS on vlan10, pi1's eth0 on `lan`, pi2 and this Mac on vlan20 — all four resolve `.lan` to Traefik's macvlan, the baseline matrix is still `50/50`, AdGuard came back serving on `:3053` with its 18 rewrites, the redirect chain is still empty, and pi2's resolver still reads `192.168.110.246`.

**Gate 4 passes.**

---

### Phase 5 — Move clients, one pool at a time

Order by blast radius, smallest first. **The maintenance pool `lan` goes first**, not last and not omitted: it carries the fewest clients, an error there is visible immediately from pi1, and proceeding without it leaves the break-glass host pointing at the NAS. Then `vlan30`, `vlan20`, and `vlan10` last, because it holds the NAS itself and everything that depends on it. `guest` advertises no IPv4 resolver and is already on the router; leave it alone.

- [x] **5.1 Shorten the lease time** on the pool being moved (`12h` → `5m`) so both cutover **and rollback** propagate in minutes instead of half a day. Apply with `uci commit dhcp && /etc/init.d/dnsmasq reload`. — Applied to all four pools on 2026-09-21.

- [x] **5.2 Move one pool**, by setting its `dhcp_option 6` to that VLAN's router address. Do not delete the option yet: setting it explicitly keeps the change visible and one command from reverting. — All four, on 2026-09-21: `lan`→192.168.8.1, `vlan10`→192.168.110.1, `vlan20`→192.168.120.1, `vlan30`→192.168.130.1.

- [x] **5.3 Verify from a real client on that VLAN:** public name resolves, `.lan` name resolves, a blocked name is blocked, and both transports work. Confirm the answer matrix for that client matches the baseline. — Verified from the NAS (VLAN10) and pi1 (VLAN20) on 2026-09-21.

- [ ] **5.4 Observe for a fixed 24 hours** before touching the next pool. Do not tie the soak to the lease duration: 5.1 shortened it to 5 minutes, so "one full lease cycle" is not an observation window. — **Deliberately not done, and the plan's sequencing was wrong here.** See Ruling D1 below: this phase's premise was that resolution was healthy and the risk was in moving it. On 2026-09-21 resolution was *already* down for the whole house, because every client pointed at a NAS that was unplugged. There was no healthy baseline to soak. All four pools moved in one action as outage recovery, not as a staged migration.

- [x] **5.5 Repeat for `lan`, `vlan30`, `vlan20`, then `vlan10`.** All four. The pool list here, in task 0.4, and in the Target architecture must agree; an earlier draft listed three pools in one place and four in another. — All four moved together (Ruling D1). Backup of the pre-move state: `/root/dns-pools-backup-20260921-122846.txt`.

- [x] **5.6 Delete the now-redundant `dhcp_option 6` from all four pools** and reload dnsmasq, so dnsmasq advertises itself. This is the state the Target architecture describes and no earlier step produces. Verify by renewing a lease and confirming the client still receives the router. — Applied 2026-09-21. The rendered dnsmasq config now carries no `dhcp-option=<pool>,6` line for any pool, so dnsmasq advertises its own address, which is the same address the deleted option named (each pool's own VLAN gateway) — the change is client-invisible by construction. **The renewal half was not forced, but it has since been observed happening on its own.** Forcing it was not possible — pi1 needs a sudo password nobody has, the NAS's only interface is the one it depends on, and the router cannot test its own DHCP server (a DISCOVER sent from the router never reaches dnsmasq; macvlan is unsupported). It did not need forcing: by 2026-09-21 15:00 pi1 had renewed, and DHCP handed it the router, which is the end state this task describes:

```
DHCP4.OPTION domain_name_servers   = 192.168.120.1     (the router, not the NAS)
DHCP4.OPTION dhcp_lease_time       = 43200             (12h)
DHCP4.OPTION dhcp_server_identifier= 192.168.120.1
```

No `dhcp_option 6` exists in the dnsmasq config for any pool, so that address is dnsmasq advertising itself. The same client resolves correctly through it: `doubleclick.net` -> `0.0.0.0`, `github.com` resolves, `sonarr.lan` -> `192.168.110.250`. Live evidence instead: dnsmasq is demonstrably serving these pools (a real `DHCPDISCOVER`/`DHCPOFFER` on `br-lan.1` at 13:32:35), and both real clients verified in 5.3 are resolving correctly through the router with `dhcp_option 6` already absent from their pools' configuration.

- [x] **5.7 Restore lease times to `12h`** once all pools are moved and stable. — All six pools are `12h` as of 2026-09-21 13:30.

**Gate 5.** Every pool's clients resolve correctly against the router, with `dhcp_option 6` removed and each pool reverted to `12h`. The NAS resolver is still running and still correct, so **any pool can be reverted with one script run**. Rollback trigger: a pool's clients fail any row of the matrix → run `scripts/dns-rollback.sh`, which restores all four pools and reloads dnsmasq.

---

### Phase 6 — Flip the redirect to AdGuard Home

Client-transparent: the address they query does not change, only which process answers it. Expect one sub-second DNS blip from the firewall reload.

- [x] **6.1 Capture the current `adg_redirect` chain state** so the flip's effect is observable and reversible. — Captured; `adg_redirect` is declared unconditionally by `/etc/firewall.dns_order` and holds nothing while `dns_enabled='0'`, which is the baseline this plan's 1.2 assumed.

- [x] **6.2 Flip.** — Done 2026-09-21. `adg_redirect` then held `tcp`+`udp` `REDIRECT --to-ports 3053`.

```bash
uci set adguardhome.config.dns_enabled='1'
uci commit adguardhome
/etc/init.d/firewall reload
```

- [x] **6.3 Re-run the full acceptance set**: the parity harness against `:53` now (not 3053), the per-VLAN checks **from real clients on every VLAN — this is the first point at which that is possible**, blocking, `.lan`, the AAAA/musl test, and `tests/e2e/dns.spec.ts`.

- [x] **6.4 Confirm the revert works, then revert it.** Flip `dns_enabled='0'`, reload, confirm resolution returns to dnsmasq, then flip back to `'1'`. A rollback path that has never been executed is a hypothesis, not a plan. — **Executed for real, twice**, as part of Phase 7.4 on 2026-09-21: the watchdog fell back to dnsmasq and recovered, and a real VLAN10 client (the NAS) kept resolving throughout while blocking was correctly dropped. See Ruling D7 — the first watchdog version made the fallback *look* correct while leaving every rule pointed at a dead AdGuard, which is why this revert had to be observed from a client rather than from the router.

**Gate 6.** AdGuard Home serves every client; the NAS resolver is idle but still running; the revert has been executed once for real and restored service both ways. Rollback trigger: any acceptance failure → `dns_enabled='0'` plus firewall reload, seconds of degraded blocking at worst, no loss of resolution.

---

### Phase 7 — Add the watchdog

Phase 6 leaves a new exposure: `dnsmasq` still listens on `:53` and works, but the redirect sends every query to AdGuard Home. If AdGuard Home stops answering, the redirect black-holes DNS for the whole house.

- [x] **7.1 Add a periodic health check on the router** that queries AdGuard Home on 3053 and, on repeated failure, sets `dns_enabled='0'` and reloads the firewall — falling back to the resolver still running underneath. This is the difference between "AdGuard crashed" and "the house has no internet". — `/usr/sbin/arrdns-watchdog.sh`, from `/etc/crontabs/root` every minute; source in `router/arrdns-watchdog.sh`. It probes for a real A record, not for a listening socket, because a resolver that is up and cannot resolve is no better than a dead one. **The first version could not fire**: `dig +short` writes `;; communications error ... connection refused` to *stdout* and exits 0, so a non-empty capture read a stopped AdGuard as healthy. Observed difference on a closed port: old probe UP, new probe DOWN.

- [x] **7.2 Make it two-way, or say plainly that it is not.** — Two-way, and round-tripped for real: fallback after three consecutive failures at 12:42:43, recovery after three consecutive successes at 12:46:00, both driven by cron and both logged to `/var/log/arrdns-watchdog.log`. As specified, the watchdog only ever disables. Gate 7 previously required restoration to happen "without manual steps", which nothing here provides. Either add re-enable after sustained recovery, or restate the gate as one-way with a documented manual restore step.

- [x] **7.3 Bound it.** Require consecutive failures, log every transition, and never fight a deliberate `dns_enabled='0'`. — Three failures to fall back, three successes to restore, a `mkdir` lock so a slow reload cannot overlap the next tick, and a state file that records why: a `dns_enabled='0'` seen while AdGuard is the target is treated as a deliberate operator choice (`reason=operator`) and is not re-enabled behind their back. **Both arms are now exercised** (2026-09-21): the operator disable is honoured, held across repeated runs, and released only when a person sets `dns_enabled='1'` again.

  That test found an ordering bug worth keeping. The operator check used to sit *inside* the `probe_ok` branch, so an operator who disabled AdGuard **and stopped it** fell through to the probe-failure path and waited three cycles — and for all three, every client was still redirected at a dead resolver. The operator's own action caused the outage the watchdog exists to prevent. Intent is now read before health, so it is honoured in one tick regardless of what AdGuard is doing; verified with AdGuard stopped and `dns_enabled='0'` set together, where the port had already moved to 53 after a single run. The three-failure bound is unchanged for a genuine crash, verified separately.

- [x] **7.4 Test it by making AdGuard Home genuinely unhealthy** and confirming DNS recovers and the watchdog reports why. A watchdog never observed firing is a guard of unknown capability. — Done, and it is what caught the probe bug in 7.1. After that fix: `dns_enabled=0 port=53 adg_redirect=0 rules=10 targets=53`, with a real VLAN10 client (the NAS) still resolving `github.com` and `sonarr.lan` while AdGuard was stopped, and blocking correctly dropped (`doubleclick.net` -> a real address rather than `0.0.0.0`). Recovery restored `dns_enabled=1 port=3053 adg_redirect=2 targets=3053` and blocking returned.

**Gate 7.** Killing AdGuard Home leaves the house resolving, the watchdog records the transition, and the documented restore path (manual or automatic, per 7.2) returns serving to AdGuard Home.

### Phase 5-7 outcome, 2026-09-21

Gates 5, 6 and 7 pass. Three things in this phase were wrong when executed, and
two of them were introduced during it rather than by the plan.

**The redirect did not put the VLANs on AdGuard Home.** The rules added during
the cutover matched `-d 192.168.110.246`, so they only caught clients still
addressing the NAS. A client that renewed its lease asked its own gateway,
reached dnsmasq, and got no ad blocking — so the migration was being quietly
undone by lease renewal, one client every five minutes. `dns_enabled`,
`adg_redirect`, the per-pool `dhcp_option 6` and the `:53` binds all read green
throughout, because every one of them judges a piece and nothing judged the
connection between them. The vendor `dns_dispatcher` is wired only for
`br-lan.1` and `br-guest`, which the plan's Evidence never checked.

**fw3 does not re-run `/etc/firewall.user` on reload.** It is
`firewall.@include[0]` with no `reload` option, and the option defaults to off,
while `/etc/firewall.dns_order` sets `reload='1'`. So `fw3 reload` rebuilt the
vendor chain and left the include's rules untouched. That made the first
watchdog leave `dns_enabled='1'` with an empty `adg_redirect`, and — worse — made
a *fallback* leave all ten rules pointed at a stopped AdGuard. Both are fixed by
`uci set firewall.@include[0].reload='1'`. fw3 also does not flush the built-in
`PREROUTING` chain, so the include now strips its own rules before inserting them;
without that, every reload stacked another ten.

**The `.lan` AAAA row is a deliberate difference, and the Phase 1 tests did not
know it.** 3.3 concluded `::` need not be reproduced, and the parity harness
excuses that row — but `tests/alpine-dns-aaaa.bats` and `tests/dns-resilience.bats`
both asserted the literal `::`. That could never pass once AdGuard was in the
path, because AdGuard answers NODATA while dnsmasq answers `::`, which is why the
suite has carried those two red rows. The requirement is *not NXDOMAIN*: musl
turns AAAA NXDOMAIN into a hard resolution failure, and an empty NOERROR is not
that. Measured through the router from Alpine 3.20:

```
nslookup -type=AAAA sonarr.lan  ->  NODATA, rc 0
nslookup -type=A    sonarr.lan  ->  192.168.110.250
getent hosts        sonarr.lan  ->  192.168.110.250, rc 0
```

Both rows now use a `LAN_AAAA` expectation that accepts `::` or NODATA and still
refuses NXDOMAIN, an unreachable resolver, and an undeclared address. Pinning
either literal alone would fail on one resolver and pass on the other.

**5.6's client-renewal check was not performed literally.** No client that could
safely be made to renew was reachable: pi1 needs a sudo password, and the NAS's
only interface is the one it depends on. The change is client-invisible by
construction — dnsmasq advertises its own address, which is the same address the
deleted option named — and the rendered config carries no `dhcp-option` line for
any pool. Recorded as a gap rather than dressed up.

---

### Phase 8 — Repoint the NAS's consumers

- [x] **8.1 `docker-compose.arr-stack.yml`** — gluetun's `DNS_ADDRESS` from `172.20.0.5` to `192.168.110.1`, drop `depends_on: pihole: service_healthy`. — Changed on the branch and validated with `docker compose config` (exit 0; rendered `DNS_ADDRESS: 192.168.110.1`, no `depends_on`). **Deployed to the NAS and verified live on 2026-09-21, then reverted** (the NAS is back on `main`; see 8.2 for why it was not left there). With the change live: gluetun reached `healthy` in 20 seconds, the tunnel came up and carried traffic (egress `146.70.194.23`), and its own resolver answered through the router — `github.com` resolved and `sonarr.lan` -> `192.168.110.250`. The crash-loop risk the plan worried about was disproved *before* the change as well, without touching anything: from inside gluetun's network namespace, `nslookup github.com 192.168.110.1` and `nslookup sonarr.lan 192.168.110.1` both answered through gluetun's own outbound firewall, which is what would have refused them if `192.168.110.0/24` were not already in `FIREWALL_OUTBOUND_SUBNETS`.

  **And it removes the last Pi-hole client.** With gluetun repointed, a query against Pi-hole's FTL database for anything since the change returned nothing at all — not gluetun, not a LAN device. Before the change gluetun was the only remaining consumer.

  **Recreating gluetun strands five containers, and `gluetun-recover` cannot fix it.** `magnetio-addon`, `prowlarr`, `sabnzbd`, `flaresolverr` and `vpn-socks5` all run in gluetun's network namespace. A *restart* keeps the namespace id and `gluetun-recover` handles it; a **recreate** does not, and the service says so itself: `FAILED to restart — if gluetun was RECREATED (not restarted), run: docker compose ... up -d --force-recreate`. The four in `docker-compose.arr-stack.yml` go back with one command against that file; `magnetio-addon` is defined in `docker-compose.magnetio.yml` and must be recreated through **that** file. Verified both ways (deploy and revert) with all six containers healthy afterwards. Anyone doing 8.2's cold boot will need this, and a cold boot is where it matters most.
- [ ] **8.2 Cold-boot test, before merging anything.** Reboot the NAS with the router answering, confirm gluetun reaches healthy and VPN egress works with no manual intervention. This is the assumption the 2026-08-27 38-hour outage falsified; do not assume it holds. Check the ingest timer and queue depth first — a reboot with an armed timer over a large watch folder is how the 2026-09-18 stall started, and it is not a DNS fault worth diagnosing inside this phase. See *Running this in parallel with other work*. — **Still open: it needs a NAS reboot, which is the user's call.** The prerequisites are satisfied — `usenet-blackhole.timer` is `disabled` and `inactive` on the NAS, so the armed-timer hazard this task warns about cannot occur; the deploy path was confirmed on `main` at `eb80f71`; gluetun was healthy with VPN egress before anything was touched.

  What 8.1's deploy test changed is the size of the remaining unknown. The part this test exists to cover — does gluetun come up and resolve on the router's DNS at all — is now answered yes, twice over. What a reboot still adds is the *ordering* case: whether the NAS's own network is up far enough at boot for gluetun to reach the router before gluetun gives up. That is the 2026-08-27 shape, and nothing but a boot exercises it.

  **Note for whoever runs it:** recreating gluetun strands the five namespace-sharing containers, and `gluetun-recover` only handles the restart case. See 8.1 for the exact recovery. A reboot will hit this.
- [x] **8.3 `docker-compose.utilities.yml:304`** — the `172.20.0.5` DNS entry. — That entry belongs to `uptime-kuma`; repointed to `192.168.110.1`. Validated with `docker compose config`.
- [ ] **8.4 `traefik/dynamic/local-services.yml`** — the `pihole-lan` route. — **Deferred to 9.4, because repointing it cannot work.** Measured 2026-09-21: AdGuard Home's admin port answers on the router (`302` from the router itself) but is **refused from every client VLAN**, because `zone_vlan10_input` lets a client VLAN reach the router on DHCP and DNS only and then falls through to `zone_vlan10_src_REJECT`. The maintenance VLAN does reach it (`302` from pi1's `eth0`), which is the path the rollback ladder already assumes. Neither the tailnet nor a macvlan shim offers a way round: the shim and Traefik's macvlan are both on VLAN10 (192.168.110.251 and .250), and the NAS cannot reach the router's Tailscale address at all. Opening router:3000 to VLAN10 would breach the segmentation `tests/network-segmentation.bats` exists to assert, for one admin UI already reachable on the maintenance VLAN — so the route stays on Pi-hole and is retired with it in 9.4. Recorded in the file itself.
- [x] **8.5 `scripts/configure-apps.sh`** — stop configuring a Pi-hole upstream; retire or repoint. — `configure_pihole` now skips when the container is not running. It would otherwise have called `fail` on every run once 9.1 stopped Pi-hole, breaking the whole script for a service that no longer exists. The dry-run branch stays first, because `--dry-run` previews every step this script knows how to take and `tests/configure-apps.bats` asserts exactly that. Not deleted: while Pi-hole runs it is still configured, because Gate 5 keeps the NAS resolver correct so a pool can be reverted to it.
- [ ] **8.6 `scripts/lib/check-dns-duplicates.sh` and `scripts/lib/check-domains.sh`** — these read the NAS Pi-hole's config, and `check-dns-duplicates.sh` compares `02-local-dns.conf` against `pihole.toml` inside the container. Both stores are being retired, so the check goes with them; 3.5 is what replaces it. Do not retire them before 3.5 passes. — 3.5 passes, but **deferred to 9.4 rather than retired now**. Retiring them before the stores go would drop the only check that the NAS resolver is internally consistent, and Gate 5 deliberately keeps that resolver correct and revertible — so this is live coverage, not dead weight. One finding along the way: `check-dns-duplicates.sh` guards an unreadable `dnsmasq` side but not an unreadable `pihole.toml` side, so from 9.1 until 9.4 — while Pi-hole is stopped — it reports `OK: No duplicate DNS entries` without having looked at anything. The asymmetry is deliberate (`tests/lib-dns-duplicates.bats` states that an empty `pihole.toml` is the state the check wants) and the two cases are indistinguishable through the remote read, so it is recorded in the file rather than changed. **That window is the reason 9.4 must not slip.**
- [ ] **8.7 `homepage/config/services.yaml`** — the Pi-hole dashboard entry. — **Deferred to 9.4, for the same reason as 8.4.** Homepage runs on the NAS, on VLAN10, and so does any browser on a client VLAN: neither can reach AdGuard's UI on the router. Retiring the entry now would remove a working dashboard for a week and replace it with a link nobody on that network can open. It goes with the service.
- [x] **8.8 Docs:** `docs/LOCAL-DNS.md` (rewrite — the "single point of failure for the entire house" note becomes the migration record), `docs/ARCHITECTURE.md`, `docs/REFERENCE.md`, `docs/TROUBLESHOOTING.md`, `CLAUDE.md`. `docs/TROUBLESHOOTING.md` is not a blank slate: the `## Everything Is Unreachable At Once` section at the top came from the merged PR #101 and documents the NAS I/O stall, not DNS. Rewrite around it. — **Done.** `docs/LOCAL-DNS.md` rewritten around the new resolver: which pool advertises what, the two-stage router path, the watchdog, and that the remaining single point of failure is now the router rather than the NAS (its old "single point of failure for the entire house" note is the migration record). `docs/REFERENCE.md`'s "if you lose internet" warning no longer says to restart Pi-hole, and instead gives the four-step DNS triage. `docs/TROUBLESHOOTING.md` gains a "DNS: nothing resolves, or one client cannot" section, and `## Everything Is Unreachable At Once` now states how to tell an I/O stall from a DNS failure, because their symptoms overlap and their fixes do not. `docs/ARCHITECTURE.md`'s diagrams and flow lines name AdGuard Home on the router. `CLAUDE.md` gains the three expensive-to-rediscover facts about this topology. All relative links verified to resolve.

**Gate 8.** Full `./tests/run-tests.sh` green on pi1 and on the NAS; `tests/e2e/` green including VPN egress, leak and kill-switch checks; a NAS cold boot completes with no manual intervention.

---

### Phase 9 — Sunset the NAS resolver

- [ ] **9.1 Stop** `pihole` and `dnscrypt-proxy` (`docker stop`, not `down`, not removal). Keep `pihole-etc-pihole` and `dnscrypt-config` volumes.
- [ ] **9.2 Confirm nothing regressed** across a full week, including the NAS's own reboot cycle.
- [ ] **9.3 Confirm no client still queries them**, from the Pi-hole query count over seven days. Do not use a conntrack check for this: DNS conntrack entries expire in seconds, so "no remaining flows" passes immediately after the last query regardless of whether clients still query occasionally.
- [ ] **9.4 Only then** remove the two services from the compose file, back up the volumes first per the repo's backup convention, and land it through a PR.
- [ ] **9.5 Record the retirement** in `docs/` with the measurements that justified it, in the style of the exit-node project log.

**Gate 9.** A week with no traffic to the NAS resolver and no incident. Removal lands as its own PR, separate from any behaviour change.

---

## Rollback ladder

Stop at the first rung that restores service. The rungs are **not** interchangeable, and which one applies depends on the phase you are in.

| Phase | Rung | Action | Time | Blast radius |
| --- | --- | --- | --- | --- |
| 5 | 1 | `scripts/dns-rollback.sh` — restores all four pools and reloads dnsmasq | ~1 min | whole house, to the NAS resolver |
| 5 | 1b | Revert one pool's `dhcp_option 6` by hand + `dnsmasq reload` | ~1 min | that pool only |
| 6-7 | 1 | `uci set adguardhome.config.dns_enabled='0'; uci commit; /etc/init.d/firewall reload` | seconds | blocking stops, resolution continues |
| any | 2 | Point one client's DNS at `1.1.1.1` by hand | seconds | that client only |
| any | 3 | `uci set adguardhome.config.enabled='0'` | ~1 min | AdGuard Home out of the picture entirely |

**Rung ordering matters.** Before Phase 6 the `dns_enabled` flip is already `0` and does nothing; during Phase 5 the only useful revert is the pool move. A single "fastest first" ladder was wrong, because the fastest rung addresses a failure that has not happened yet.

Access for the router rungs does not depend on DNS working: SSH by IP via pi1 on the maintenance VLAN, or the router's Tailscale address. Confirm this before Phase 6, not during an incident.

## Gates summary

| Gate | Passes when | Rollback trigger |
| --- | --- | --- |
| 0 | `router/backup/` exists with a non-empty capture; rollback script covers four pools, reloads dnsmasq, fails on an un-reverted pool | — |
| 1 | New tests fail for the right reasons; mutation corpus kills new guards | — |
| 2 | AdGuard answers on 3053 from pi1 and the router; live path untouched; credential set | any answer wrong |
| 3 | Parity harness reports no unexplained difference; duplicate guard fails on divergence | `.lan` or blocking cannot reach parity |
| 4 | `.lan` resolves via the router from every VLAN, survives a reboot | `.lan` broken after reboot |
| 5 | All four pools moved, `dhcp_option 6` removed, clients pass the matrix; NAS resolver still live | any pool fails → rollback script |
| 6 | AdGuard serves all clients; revert executed once for real | any acceptance failure |
| 7 | Killing AdGuard Home does not remove resolution; restore path documented and exercised | watchdog flaps or fails to fire |
| 8 | Full suite green; NAS cold boot clean | gluetun unhealthy after cold boot |
| 9 | Seven days, zero traffic to the NAS resolver | any client still resolving through it |

## Open questions, and where each is closed

1. **Does AdGuard Home see dnsmasq's local records at all?** **No, and the answer matters more than the question did.** Answered 2026-09-19 from the router against the staged AdGuard on 3053:
   - `pi1` and `Redmi-Note-14-Pro-5G` (bare DHCP lease names) answer `NOERROR` with the lease address on dnsmasq's `:53`, and `NXDOMAIN` on AdGuard's `:3053`. Every short name a person actually types stops working.
   - `sonarr.lan` answers `NXDOMAIN` on 3053 as well. 3.2's rewrites fix the 18 known names, but **AdGuard forwards `.lan` upstream to public resolvers**, which dnsmasq's `local=/lan/` prevented. That is the parity gap 3.5 has to close, and it is a privacy leak as well as a correctness one: every `.lan` lookup leaves the house today.
   
   So 3.2 alone is not enough. Phase 3 needs either an upstream pointing at a dnsmasq instance on a secondary port (which restores lease names and local records together) or the rewrites **plus** an AdGuard equivalent of `local=/lan/` — `bogus_nxdomain` with `lan` on it, so unknown `.lan` names are answered locally instead of being asked of Google. Decide this in 3.2/3.3, not later: it changes what 3.6's parity run compares.
2. **What does `dns_enabled` do beyond the redirect?** Closed in Phase 0 by reading `/etc/firewall.dns_order` in full; line 31 is the only consumer found so far.
3. **What does AdGuard Home return for AAAA on a rewrite?** **NODATA** — `NOERROR` with an empty answer section, measured on the router against the staged AdGuard (`dig sonarr.lan AAAA @127.0.0.1 -p 3053`). So 3.3 is neither a configuration change nor a design problem: musl's failure mode is AAAA *NXDOMAIN*, NODATA is not that, and `address=/lan/::` does not need reproducing. The NXDOMAIN case is the name that does **not** exist, not the one that does.

   The end-to-end proof still has to be made with a real musl client, and it cannot be made yet: `tests/alpine-dns-aaaa.bats` points a container at the router's `:53`, which `dns_enabled='0'` still routes to dnsmasq, and dnsmasq has no `.lan` records until 4.1. A `--dns` flag cannot be pointed at `:3053`, because getaddrinfo only ever uses port 53. That test goes green at Phase 4, and 6.3 re-runs it when AdGuard actually serves the port. Until then the NODATA measurement above is the evidence, and it is the right shape: the resolver answer is what changed, and it is no longer NXDOMAIN.
4. **Does GL.iNet's firmware upgrade preserve `/etc/AdGuardHome`?** If not, 0.2's backup plus a documented restore is load-bearing, not a nicety.
5. **Should the router keep a second resolver as a floor?** dnsmasq on `:53` already is exactly that, which is why the Phase 7 watchdog can fall back rather than fail.

---

## Review record, 2026-09-19

An adversarial pass over the first draft produced fifteen findings. Three were critical, and all three would have caused a house-wide DNS outage if executed as written. Auditing those findings against the live system downgraded three and corrected one in substance.

**Confirmed critical.** Port 3053 is unreachable from every VLAN client, so the staging gate could not run as written (control test: router ports 80/443 are listening yet dropped from VLAN20 at ~1020 ms, while 53 answers in 16 ms; the same ports are open from pi1 in 6 ms). The rollback script's `uci commit` reloads nothing, because only `/etc/init.d/boot` calls `/sbin/reload_config`, so the DHCP revert would never take effect while its self-check passed. The maintenance pool `dhcp.lan` appeared in the rollback script and the target state but was missing from the migration order.

**Confirmed high.** `router/` did not exist, so the Phase 0 capture wrote nothing. The rollback ladder's "each rung is independently sufficient" was false, and its fastest rung was inert during the phase with the real exposure. AdGuard Home ships with `users: []` and binds `0.0.0.0:3000`, reachable from the maintenance VLAN, with no credential task.

**Corrected.** The claim that `check-dns-duplicates.sh` guards against router-vs-AdGuard divergence was wrong: it compares the NAS's `02-local-dns.conf` against `pihole.toml` inside the container. The duplication this plan creates is real and unguarded, but the retired script never covered it, so 3.5 has to build the new guard rather than inherit one.

**Downgraded.** Phase 4.1's missing option name is a documentation gap, not a blocker: `append_address()` at `/etc/init.d/dnsmasq:172` confirms `list address '/domain/ip'` works, `address_as_local` defaults to `0`, and the pre-existing `local='/lan/'` is complementary rather than conflicting. "Zero client impact" in Phase 2 was overstated but nearly right: `clean_conntrack()` at `/lib/functions/vpn_func/route_policy_func.sh:43` deletes only DNS flows, so the effect is a sub-second DNS blip. The IPv6 concern was largely moot: `ra` and `dhcpv6` are `disabled` on all three VLAN pools, so no IPv6 resolver is handed out there to migrate.

## Amendment, 2026-09-19 evening — Evidence re-measured before Phase 0

Every row in **Evidence** was re-measured against the live router, NAS, pi1 and pi2 before Phase 0 started. All of them reproduced except the dnsmasq bind list, which is corrected above. Three changes came out of it:

- **dnsmasq `:53` binds.** The table previously listed `192.168.10.1`. That address belongs to `network.iot`, which is `disabled='1'`, so `br-iot` does not exist and dnsmasq has nothing to bind there. The live set is five LAN-side addresses plus loopback, tailscale and the ProtonVPN address. This matters because 1.2 asserts on the bind list and Phase 4/Gate 4 say "every VLAN" — the plan now says "every live VLAN" and lists the four.
- **The disabled `iot` pool is now a row of its own.** It is a sixth DHCP section that the first draft never mentioned: configured, in its own firewall zone with an `Allow-DNS` rule, but inert. It advertises no resolver, so it is not a migration target and needs no pool move.
- **Lease time was understated.** All four advertising pools carry `12h`, not three; 5.1 and 5.7 touch all four.

Two facts that were not in the table but matter operationally, recorded here rather than as rows: `pi1` does not resolve by name from the maintenance host — it answers as `pi1.local` (wlan0 `192.168.120.228` on VLAN20, eth0 `192.168.8.227` on maintenance), and the router hop works from there as the plan assumes. `pi2` is up at `192.168.120.241` on VLAN20 and still resolves through the NAS Pi-hole, so it is a usable VLAN20 vantage for 5.3.

The re-measurement also closed open question 2 in full: `dns_enabled` appears exactly once in `/etc/firewall.dns_order` (line 31, gating `adg_handle_dns`), and nowhere else in that file.
