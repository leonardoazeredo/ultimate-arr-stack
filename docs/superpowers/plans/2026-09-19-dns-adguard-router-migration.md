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
| Pre-existing `local='/lan/'` | set; means "answer `.lan` locally, never forward". Complementary to `address`, not conflicting | `uci show dhcp` |
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

- [ ] **0.0 Create the directories the rest of this phase writes into.**

```bash
mkdir -p router/backup
```

`router/` and `router/backup/` do not exist today, and 0.1's redirect target does not create itself. Without this, 0.1 writes nothing and exits without an error anyone is told to look for.

- [ ] **0.1 Capture the router's DNS state.**

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

- [ ] **0.2 Back up the AdGuard Home config and data, outside the repo.**

```bash
ssh pi@pi1 'ssh arr-stack-router tar czf - /etc/AdGuardHome' > ~/agh-backup-2026-09-19.tgz
```

Deliberately outside the repo. `config.yaml` currently holds `users: []`, so no credential is committed today, but it will hold an admin hash from Phase 2 onward. Committing it into a repo whose test suite scans for secrets is a needless hazard.

- [ ] **0.3 Record the baseline answer matrix.** Every resolver question this migration is judged on, answered by the NAS Pi-hole today. Commit as `tests/fixtures/dns-baseline.txt`. This file is the oracle for Phase 3's parity test. `tests/fixtures/` already exists.

- [ ] **0.4 Write `scripts/dns-rollback.sh`** — one command that returns every pool to the NAS resolver. It must:

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

- [ ] **0.5 Prove the rollback kit works — on a copy, not on production.**

It is **not** a no-op at baseline: it rewrites `dhcp_option` on four pools (changing the UCI representation from a string to a list), commits three config files, reloads dnsmasq and reloads the firewall, which flushes DNS conntrack. Running it "for real before any change" is itself a production change.

Rehearse it on a scratch copy of `/etc/config` with the `uci` calls pointed at a temporary config dir, assert with `DRY_RUN=1` that it emits the expected command sequence, and assert the loop covers four pools. Then run it once for real **during Phase 5's window**, as the first rung of the rollback ladder, before any pool is moved — that is the rehearsal that matters and it happens when a rollback is already a live possibility.

Per repo convention this lives in `tests/mutation/corpus/`, with a red test proving the guard can fail.

**Gate 0.** `router/backup/` exists and holds a non-empty capture. Baseline matrix committed and passing against the NAS resolver. Rollback script covers four pools, reloads dnsmasq, and fails when a pool is left un-reverted. `git status` clean, NAS on `main`.

---

### Phase 1 — Acceptance tests first (TDD)

These tests are written before any change and **must fail against the current design**. If a test passes now, it is not testing the migration.

- [ ] **1.1 `tests/dns-resilience.bats`** — the anchor test. Asserts that a resolver answering on the router's address is sufficient for a client to resolve a public name, a `.lan` name, and to have a blocked name blocked — with the NAS resolver not consulted. It fails today because the router's dnsmasq knows no `.lan` records and does no blocking.

- [ ] **1.2 `tests/router-dns.bats`** — live assertions over the router, in the style of `tests/network-segmentation.bats`, including its vantage-point discipline. Assert:
  - per-pool `dhcp_option 6` state;
  - **`adg_redirect` exists in both states and is empty when `dns_enabled='0'`**, holding `REDIRECT --to-ports 3053` for tcp and udp when it is `'1'`. The chain is declared unconditionally by `iptables-restore`; an "exists iff" assertion fails at baseline;
  - dnsmasq binds `:53` on every **live** VLAN-side interface — `192.168.8.1`, `192.168.9.1`, `192.168.110.1`, `192.168.120.1`, `192.168.130.1` — and not on `192.168.10.1`, because `network.iot` is `disabled='1'` and `br-iot` does not exist. Derive the expected set from the live interface list rather than hardcoding six addresses.

  Must **skip with a reason** everywhere except a host that can reach the router (pi1), never fail silently.

- [ ] **1.3 `tests/e2e/dns.spec.ts`** — from the e2e container on the NAS: public resolution, `.lan` resolution, blocked-domain behaviour, **TCP and UDP both** (a TCP-only probe passes while UDP resolution is broken — the trap `network-segmentation.bats` already documents for port 53). Assert on the answer, not on a status code.

- [ ] **1.4 The AAAA parity test.** `address=/lan/::` exists because musl/Alpine containers treat AAAA NXDOMAIN as a hard failure. Assert an Alpine container can resolve a `.lan` name when the router is the only resolver. This test is the one most likely to fail late and expensively; it runs from Phase 2 onward.

- [ ] **1.5 Extend `tests/mutation/corpus/`** with an entry for each new guard, and confirm `./tests/mutation/run-mutations.sh` turns each named test red. Put them in a new corpus file rather than appending to an existing one; another plan in flight edits `usenet-blackhole.sh` and `tests/mutation/README.md`. See *Running this in parallel with other work*.

**Gate 1.** `./tests/run-tests.sh` runs, the new tests execute, the ones that must fail do fail for the stated reason, and the mutation corpus kills the new guards. No production change yet.

---

### Phase 2 — Stage AdGuard Home on 3053

`enabled='1'` starts AdGuard Home; `dns_enabled` stays `'0'`, so no redirect is installed and every client keeps using dnsmasq on `:53`.

Impact is small but not zero: `start_service()` calls `/etc/init.d/firewall reload`, and that reload runs `clean_conntrack`, which deletes DNS conntrack entries. Expect a sub-second DNS blip, not a connectivity interruption.

- [ ] **2.0 Set an admin credential before leaving the service running.** `users: []` means the web UI has no authentication, and the maintenance VLAN reaches it (port 3000 answers in 6 ms from pi1; the same port is dropped from VLAN20). Left as-is, anything on the maintenance VLAN can rewrite or block any domain for every client. Bind the UI to the maintenance interface rather than `0.0.0.0` if it does not need to be reachable elsewhere.

- [ ] **2.1 Start it.**

```bash
uci set adguardhome.config.enabled='1'
uci commit adguardhome
/etc/init.d/adguardhome start
```

- [ ] **2.2 Verify it answers on 3053 — from the only vantage that can reach it.**

From **pi1 over the maintenance VLAN** (`lan` zone, `input='ACCEPT'` is the only zone that permits it):

```bash
ssh pi@pi1 'dig +short +time=3 +tries=1 example.com @192.168.8.1 -p 3053'
ssh pi@pi1 'dig +short +time=3 +tries=1 example.com @192.168.8.1 -p 3053 +tcp'
```

Then settle open question 1 from **on the router**, because pi1 cannot test local-name resolution that only the router's own data can answer:

```bash
ssh pi@pi1 'ssh arr-stack-router "dig +short +time=3 +tries=1 <a-known-dhcp-lease-name> @127.0.0.1 -p 3053"'
```

Do **not** attempt `dig @192.168.x.1 -p 3053` from a client on `vlan10`, `vlan20` or `vlan30`. It is dropped, not merely closed, and a worker who sees that failure will chase a firewall problem that is not a bug.

- [ ] **2.3 Confirm the live path is untouched.** The baseline matrix still passes against the NAS, and `iptables -t nat -L adg_redirect -n` shows the chain with no rules.

**Gate 2.** AdGuard Home answers on 3053 from pi1 and from the router. Baseline matrix unchanged. `adg_redirect` present and empty. Rollback trigger: any answer wrong → `enabled='0'`, no client affected.

---

### Phase 3 — Configure AdGuard Home to parity

- [ ] **3.1 Replace the plain upstreams** (`8.8.8.8`, `9.9.9.9`) with DoH/DoT. This is what `dnscrypt-proxy` provided before; do not retire it until this is proven.

- [ ] **3.2 Add all 19 `.lan` records as DNS rewrites**, pointing at Traefik's macvlan `192.168.110.250`.

- [ ] **3.3 Reproduce the AAAA behaviour** for `.lan` so musl/Alpine clients keep working. Open question 3 decides whether this is a configuration change or a design problem, and it is answered here, not in Phase 6.

- [ ] **3.4 Add blocklists**, and record the chosen lists in `docs/`.

- [ ] **3.5 Add the duplicate guard for the new topology.** The repo's rule is not to define a domain in two places (`docs/LOCAL-DNS.md:63`). This plan deliberately breaks that rule by holding the 19 names in both AdGuard rewrites (3.2) and dnsmasq `address` records (4.1), because `dns_enabled` decides which one answers. Write the check that catches divergence, in the spirit of `scripts/lib/check-dns-duplicates.sh`. Note that script compares the NAS's `02-local-dns.conf` against `pihole.toml` inside the container — it is not, and never was, a router-vs-AdGuard check, so retiring it in 8.6 removes nothing that covered this.

- [ ] **3.6 Run the parity harness.** A script that sends the committed baseline matrix to **both** resolvers — the NAS Pi-hole and AdGuard Home — and diffs the answers. AdGuard Home is queried from pi1 on 3053; the NAS from anywhere. Commit as `scripts/dns-parity.sh`, with a bats test that proves it reports a mismatch when one is introduced.

**Gate 3.** `./scripts/dns-parity.sh` reports zero unexplained differences across the full matrix, including the blocked-name and `.lan` rows. Differences that are deliberate (a different CDN edge for a load-balanced name) must be named and allowed explicitly in the fixture, not waved through. The duplicate guard from 3.5 fails when a name is added to one store only. Rollback trigger: parity cannot be reached for `.lan` or blocked names → leave `enabled='1'`, `dns_enabled='0'`; no client impact.

---

### Phase 4 — Teach the router's dnsmasq the local names

Until this is done, moving any client to the router would break `.lan`. Verified gap: `dig sonarr.lan @192.168.120.1` returns nothing today.

- [ ] **4.1 Add the `.lan` records to dnsmasq via the `address` list.** The option exists on this build: `append_address()` at `/etc/init.d/dnsmasq:172`, wired at `:1087` by `config_list_foreach "$cfg" "address" append_address "$address_as_local"`, emitting `--address=$1`. `address_as_local` defaults to `0`, so leave it unset.

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

- [ ] **4.2 Verify immediately, from a host on each live VLAN**, that `sonarr.lan` and `jellyfin.lan` resolve to `192.168.110.250` while the client still uses the NAS resolver. Verify now, not at the gate: a wrong option name or value syntax produces no records and no error.

**Gate 4.** `.lan` names resolve against the router's `:53` from every live VLAN (`lan`, `vlan10`, `vlan20`, `vlan30`; `iot` is disabled and `guest` already points at the router), and the baseline matrix is unchanged for every existing client. Reboot the router once and re-verify, because surviving a reboot is the point of 4.1.

---

### Phase 5 — Move clients, one pool at a time

Order by blast radius, smallest first. **The maintenance pool `lan` goes first**, not last and not omitted: it carries the fewest clients, an error there is visible immediately from pi1, and proceeding without it leaves the break-glass host pointing at the NAS. Then `vlan30`, `vlan20`, and `vlan10` last, because it holds the NAS itself and everything that depends on it. `guest` advertises no IPv4 resolver and is already on the router; leave it alone.

- [ ] **5.1 Shorten the lease time** on the pool being moved (`12h` → `5m`) so both cutover **and rollback** propagate in minutes instead of half a day. Apply with `uci commit dhcp && /etc/init.d/dnsmasq reload`.

- [ ] **5.2 Move one pool**, by setting its `dhcp_option 6` to that VLAN's router address. Do not delete the option yet: setting it explicitly keeps the change visible and one command from reverting.

- [ ] **5.3 Verify from a real client on that VLAN:** public name resolves, `.lan` name resolves, a blocked name is blocked, and both transports work. Confirm the answer matrix for that client matches the baseline.

- [ ] **5.4 Observe for a fixed 24 hours** before touching the next pool. Do not tie the soak to the lease duration: 5.1 shortened it to 5 minutes, so "one full lease cycle" is not an observation window.

- [ ] **5.5 Repeat for `lan`, `vlan30`, `vlan20`, then `vlan10`.** All four. The pool list here, in task 0.4, and in the Target architecture must agree; an earlier draft listed three pools in one place and four in another.

- [ ] **5.6 Delete the now-redundant `dhcp_option 6` from all four pools** and reload dnsmasq, so dnsmasq advertises itself. This is the state the Target architecture describes and no earlier step produces. Verify by renewing a lease and confirming the client still receives the router.

- [ ] **5.7 Restore lease times to `12h`** once all pools are moved and stable.

**Gate 5.** Every pool's clients resolve correctly against the router, with `dhcp_option 6` removed and each pool reverted to `12h`. The NAS resolver is still running and still correct, so **any pool can be reverted with one script run**. Rollback trigger: a pool's clients fail any row of the matrix → run `scripts/dns-rollback.sh`, which restores all four pools and reloads dnsmasq.

---

### Phase 6 — Flip the redirect to AdGuard Home

Client-transparent: the address they query does not change, only which process answers it. Expect one sub-second DNS blip from the firewall reload.

- [ ] **6.1 Capture the current `adg_redirect` chain state** so the flip's effect is observable and reversible.

- [ ] **6.2 Flip.**

```bash
uci set adguardhome.config.dns_enabled='1'
uci commit adguardhome
/etc/init.d/firewall reload
```

- [ ] **6.3 Re-run the full acceptance set**: the parity harness against `:53` now (not 3053), the per-VLAN checks **from real clients on every VLAN — this is the first point at which that is possible**, blocking, `.lan`, the AAAA/musl test, and `tests/e2e/dns.spec.ts`.

- [ ] **6.4 Confirm the revert works, then revert it.** Flip `dns_enabled='0'`, reload, confirm resolution returns to dnsmasq, then flip back to `'1'`. A rollback path that has never been executed is a hypothesis, not a plan.

**Gate 6.** AdGuard Home serves every client; the NAS resolver is idle but still running; the revert has been executed once for real and restored service both ways. Rollback trigger: any acceptance failure → `dns_enabled='0'` plus firewall reload, seconds of degraded blocking at worst, no loss of resolution.

---

### Phase 7 — Add the watchdog

Phase 6 leaves a new exposure: `dnsmasq` still listens on `:53` and works, but the redirect sends every query to AdGuard Home. If AdGuard Home stops answering, the redirect black-holes DNS for the whole house.

- [ ] **7.1 Add a periodic health check on the router** that queries AdGuard Home on 3053 and, on repeated failure, sets `dns_enabled='0'` and reloads the firewall — falling back to the resolver still running underneath. This is the difference between "AdGuard crashed" and "the house has no internet".

- [ ] **7.2 Make it two-way, or say plainly that it is not.** As specified, the watchdog only ever disables. Gate 7 previously required restoration to happen "without manual steps", which nothing here provides. Either add re-enable after sustained recovery, or restate the gate as one-way with a documented manual restore step.

- [ ] **7.3 Bound it.** Require consecutive failures, log every transition, and never fight a deliberate `dns_enabled='0'`.

- [ ] **7.4 Test it by making AdGuard Home genuinely unhealthy** and confirming DNS recovers and the watchdog reports why. A watchdog never observed firing is a guard of unknown capability.

**Gate 7.** Killing AdGuard Home leaves the house resolving, the watchdog records the transition, and the documented restore path (manual or automatic, per 7.2) returns serving to AdGuard Home.

---

### Phase 8 — Repoint the NAS's consumers

- [ ] **8.1 `docker-compose.arr-stack.yml`** — gluetun's `DNS_ADDRESS` from `172.20.0.5` to `192.168.110.1`, drop `depends_on: pihole: service_healthy`.
- [ ] **8.2 Cold-boot test, before merging anything.** Reboot the NAS with the router answering, confirm gluetun reaches healthy and VPN egress works with no manual intervention. This is the assumption the 2026-08-27 38-hour outage falsified; do not assume it holds. Check the ingest timer and queue depth first — a reboot with an armed timer over a large watch folder is how the 2026-09-18 stall started, and it is not a DNS fault worth diagnosing inside this phase. See *Running this in parallel with other work*.
- [ ] **8.3 `docker-compose.utilities.yml:304`** — the `172.20.0.5` DNS entry.
- [ ] **8.4 `traefik/dynamic/local-services.yml`** — the `pihole-lan` route.
- [ ] **8.5 `scripts/configure-apps.sh`** — stop configuring a Pi-hole upstream; retire or repoint.
- [ ] **8.6 `scripts/lib/check-dns-duplicates.sh` and `scripts/lib/check-domains.sh`** — these read the NAS Pi-hole's config, and `check-dns-duplicates.sh` compares `02-local-dns.conf` against `pihole.toml` inside the container. Both stores are being retired, so the check goes with them; 3.5 is what replaces it. Do not retire them before 3.5 passes.
- [ ] **8.7 `homepage/config/services.yaml`** — the Pi-hole dashboard entry.
- [ ] **8.8 Docs:** `docs/LOCAL-DNS.md` (rewrite — the "single point of failure for the entire house" note becomes the migration record), `docs/ARCHITECTURE.md`, `docs/REFERENCE.md`, `docs/TROUBLESHOOTING.md`, `CLAUDE.md`. `docs/TROUBLESHOOTING.md` is not a blank slate: the `## Everything Is Unreachable At Once` section at the top came from the merged PR #101 and documents the NAS I/O stall, not DNS. Rewrite around it.

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

1. **Does AdGuard Home see dnsmasq's local records at all?** Its configured upstreams are public resolvers, so DHCP lease names and the `lan` search domain may stop resolving once it takes `:53`. Closed in 2.2 by querying 3053 for a known lease name from the router. If the answer is no, either add rewrites or give AdGuard Home an upstream pointing at a dnsmasq instance on a secondary port.
2. **What does `dns_enabled` do beyond the redirect?** Closed in Phase 0 by reading `/etc/firewall.dns_order` in full; line 31 is the only consumer found so far.
3. **What does AdGuard Home return for AAAA on a rewrite?** Decides whether 3.3 is a configuration change or a design problem. Test with an Alpine/musl container, which is the client that cares.
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
