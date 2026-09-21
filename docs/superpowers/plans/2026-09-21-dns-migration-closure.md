# DNS Migration Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpower-subagent-driven-development (recommended) or superpower-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close out the DNS migration — retire the NAS resolver, settle the two open access decisions, and clear every item deferred across the migration and the adjacent ingest plan.

**Architecture:** The migration itself is done and merged (`#104`–`#110`): DNS is served by AdGuard Home on the router, the NAS Pi-hole and dnscrypt-proxy are stopped, and nothing points at them. What remains is removal (Phase 9.4), the record (9.5), two decisions that were deliberately left open, and a handful of cleanups. Every change lands on a feature branch, is verified on the live NAS or router, then merges through a PR.

**Tech Stack:** OpenWrt 21.02 (BusyBox ash) on a GL-MT6000 router; Docker Compose on a Ugreen NAS; bash + bats + a mutation corpus in this repo; Docker for anything the NAS OS lacks.

**Spec:** `docs/superpowers/plans/2026-09-19-dns-adguard-router-migration.md` — the migration plan this closes out. Read its Gate 9 and the Phase 9 section; this plan implements 8.6 and 9.1–9.5 of it and records why 5.4 and 9.3's stated method cannot be used as written.

## Global Constraints

- **`main` is protected.** Every change is a PR: `git push origin <branch>` → `gh pr create` → wait for CI green → `gh pr merge <n> --squash` → `git checkout main && git fetch origin main && git merge --ff-only origin/main` → `./scripts/sync-nas.sh`. A local merge cannot be pushed.
- **Test on the NAS before merging.** Compose or service changes are synced to the NAS and verified live first.
- **NEVER pass `--remove-orphans`** to any `docker compose` command. Services are split across compose files sharing one project name, so compose treats every container from the other files as an orphan and deletes them all. This happened on 2026-08-01.
- **Recreate a service only through the compose file that defines it.** `traefik` must go through `docker-compose.traefik.yml` or it loses its macvlan and every `.lan` URL dies.
- **Run the suite via `./tests/run-tests.sh`**, never `npm test` (the NAS and pi1 have no npm).
- **28 failures are the known macOS baseline.** BSD sed, no `timeout` binary, no PyYAML. A change is judged by whether it adds a *new* failure, and CI (Linux) is the real gate — it runs green. Do not chase the 28.
- **Any new guard needs a mutation-corpus entry that KILLS.** `./tests/mutation/run-mutations.sh -k <id>`; a SURVIVED or ERROR fails CI's "mutation guards for this change" job.
- **Corpus prose must not contain backticks.** The corpus is `source`d by bash, so a backtick is command substitution; `tests/mutation-framework.bats` guards this.
- **Approval prompts are disabled in this session.** Never set `sandbox_permissions`; a denial is final.
- **Access.** Router: `ssh -i ~/.ssh/gl_router_ed25519 root@100.70.123.86`. NAS: `ssh -i ~/.ssh/ugreen_nas_ed25519 leoleg@100.98.67.13`; `sudo` needs a password, obtained with `bw get password "nas cloud"` under `BW_SESSION` and piped with `sudo -S -p ""` — never printed, never stored. pi1: `ssh pi@pi1.local`.
- **Two decisions are the user's**, and Tasks 1 and 2 exist to settle them. Do not pick for them; present the measurement and the two fully-specified branches.

---

## Task 1: Settle how the DNS admin UI is reached

> **DECIDED 2026-09-21: Branch A.** The admin UI stays maintenance-VLAN-only, recorded as policy rather than left as an omission. Execute Steps 1–2 for the record, then **Branch A** (Steps 3A–4A). Do not implement Branch B — it is kept below so the alternative is on the record, not because it is wanted.

The migration leaves AdGuard Home's UI at `http://192.168.8.1:3000`. It answers from the router itself and from the maintenance VLAN (`302` from pi1's `eth0`), and is **refused from every client VLAN** — `zone_vlan10_input` allows DHCP (67–68) and DNS (53) only, then falls through to `zone_vlan10_src_REJECT`. So after Task 4 removes Pi-hole, a client-VLAN browser has no way to reach the DNS UI.

**Files:**
- Modify (branch A only): `docs/LOCAL-DNS.md`
- Modify (branch B only): `router/firewall.user`, plus a Traefik route and an `adguard.lan` rewrite
- Test: `tests/firewall-user.bats`

**Interfaces:**
- Consumes: nothing.
- Produces: a recorded decision in `docs/LOCAL-DNS.md`, and either a new firewall rule or a documented restriction. Task 4 depends on the decision being recorded, not on which branch was taken.

- [x] **Step 1: Reproduce the measurement, so the decision rests on current facts**

```bash
# --interface on BOTH, and not optional: pi1 holds eth0 on the maintenance VLAN
# and wlan0 on VLAN20, so an unqualified curl reaches 192.168.110.1 through
# whichever the route table picks and a 302 from the maintenance path reads as
# "the client VLAN can reach it" -- the opposite of what this step exists to show.
ssh -o ConnectTimeout=8 pi@pi1.local '
  echo "maintenance VLAN: $(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
      --interface 192.168.8.227  http://192.168.8.1:3000/)"
  echo "client VLAN:      $(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
      --interface 192.168.120.228 http://192.168.120.1:3000/)"'
```

Expected: `maintenance VLAN: 302`, `client VLAN: 000`. If the client-VLAN call ever returns 302, the decision is moot — record that and skip to Task 3.

Measured 2026-09-21, and recorded here because it is the whole basis of the decision:

```
router itself                302
pi1 - maintenance VLAN eth0  302
pi1 - VLAN20 wlan0           000
NAS - VLAN10                 000
```

The NAS line is the one that matters: it cannot reach the admin port either, so Branch B's firewall rule is a genuine prerequisite for a Traefik-proxied `.lan` name rather than a nicety.

- [x] **Step 2: Put the decision to the user**

Present exactly this, then wait:

> AdGuard's admin UI is reachable from the maintenance VLAN only. Two options:
> **(A)** Leave it — administer DNS from the maintenance VLAN, same as the router's own UI always has been. No security change.
> **(B)** Add one scoped firewall rule — source `192.168.110.246` (the NAS), destination port `3000`, `zone_vlan10` — and a Traefik route plus an `adguard.lan` DNS rewrite, so a `.lan` name works from every VLAN behind Traefik's basic auth and TLS. This widens what the NAS can reach on the router.

#### Branch A — leave it (recommended)

- [x] **Step 3A: Record the decision**

Append to `docs/LOCAL-DNS.md`, under the AdGuard section:

```markdown
**The admin UI is reachable from the maintenance VLAN only**, by design and
deliberately. `zone_vlan10_input` allows a client VLAN to reach the router on
DHCP and DNS alone, so `http://192.168.8.1:3000` answers from the maintenance
VLAN and nowhere else. That is the same posture as the router's own admin UI.
Making it a `.lan` name behind Traefik would need a rule letting the NAS reach
`router:3000`, which widens what a compromised container on the NAS can touch on
the router — a trade nobody has chosen. Decide it explicitly if it ever matters.
```

- [x] **Step 4A: Verify and commit**

```bash
./tests/run-tests.sh tests/lib-doc-links.bats
git checkout -b fix/dns-admin-ui-posture
git add docs/LOCAL-DNS.md
git commit -m "dns: record that the DNS admin UI is maintenance-VLAN-only"
git push -u origin fix/dns-admin-ui-posture
gh pr create --base main --head fix/dns-admin-ui-posture --fill
```

Then wait for CI green, `gh pr merge --squash`, and re-sync main. The plan's global constraints require a PR for every change — a bare `git commit` leaves the work unlandable.

#### Branch B — add the scoped rule

- [ ] **Step 3B: Write the failing test**

In `tests/firewall-user.bats`, inside `setup()`, the `iptables` stub already logs argv. Add to the end of the file:

```bash
@test "firewall-user: the DNS admin UI rule is scoped to the NAS, not the VLAN" {
    port_file 3053
    dig_answers

    bash "$FIREWALL"

    # RED if the source were the whole subnet, or the rule were absent. Scoped to
    # one host on purpose: VLAN10 holds the arr stack, and only the NAS needs to
    # reach the router's admin port to proxy AdGuard behind Traefik.
    # Counted on the -I, not on the address: the idempotency strip added below
    # emits the identical -s ... --dport 3000 substring on its -D, and the stub
    # logs every invocation, so matching on the address alone always reads 2.
    [[ "$(grep -c -- "-I zone_vlan10_input 1 -s 192.168.110.246/32 -p tcp --dport 3000" "$IPT_LOG")" -eq 1 ]]
    [[ "$(grep -c -- "-D zone_vlan10_input -s 192.168.110.246/32 -p tcp --dport 3000" "$IPT_LOG")" -ge 1 ]]
    [[ "$(grep -c -- "192.168.110.0/24.*--dport 3000" "$IPT_LOG")" -eq 0 ]]
}
```

- [ ] **Step 4B: Run it and watch it fail**

Run: `./tests/run-tests.sh tests/firewall-user.bats`
Expected: FAIL — `0 -eq 1`.

- [ ] **Step 5B: Implement the rule**

In `router/firewall.user`, after the redirect loop, add:

```sh
# The NAS alone may reach AdGuard Home's admin port, so Traefik can proxy the DNS
# UI behind a .lan name. Scoped to one host rather than the VLAN: VLAN10 holds the
# whole arr stack, and this is the router's admin surface. See docs/LOCAL-DNS.md.
iptables -w 5 -I zone_vlan10_input 1 \
  -s 192.168.110.246/32 -p tcp --dport 3000 \
  -m comment --comment arrdns-admin -j ACCEPT
```

Because `zone_vlan10_input` is rebuilt on every firewall reload, this insert is idempotent only if the previous one is gone — add the strip alongside the existing delete loop:

```sh
while iptables -w 5 -D zone_vlan10_input -s 192.168.110.246/32 -p tcp --dport 3000 \
        -m comment --comment arrdns-admin -j ACCEPT 2>/dev/null; do :; done
```

- [ ] **Step 6B: Verify it passes, then deploy and verify live**

```bash
./tests/run-tests.sh tests/firewall-user.bats
ssh -i ~/.ssh/gl_router_ed25519 root@100.70.123.86 'cat > /etc/firewall.user' < router/firewall.user
ssh -i ~/.ssh/gl_router_ed25519 root@100.70.123.86 'sh /etc/firewall.user && iptables -S zone_vlan10_input | grep 3000'
ssh -o ConnectTimeout=12 -i ~/.ssh/ugreen_nas_ed25519 leoleg@100.98.67.13 \
  'curl -s -o /dev/null -w "from the NAS: %{http_code}\n" --max-time 5 http://192.168.110.1:3000/'
```

Expected: rule present; `from the NAS: 302`.

- [ ] **Step 7B: Add the mutation entry**

Append to `tests/mutation/corpus/firewall-user.sh`:

```bash
mutation firewall-user-admin-rule-wide-open \
  --file router/firewall.user \
  --bats tests/firewall-user.bats \
  --test "firewall-user: the DNS admin UI rule is scoped to the NAS, not the VLAN" \
  --why "widens the source from the NAS to its whole subnet, so every container on VLAN10 can reach the router admin port the migration deliberately keeps off client VLANs" \
  --apply 'perl -0pi -e "s@192\.168\.110\.246/32 -p tcp --dport 3000@192.168.110.0/24 -p tcp --dport 3000@" "$F"'
```

Run: `/opt/homebrew/bin/bash ./tests/mutation/run-mutations.sh -k firewall-user-admin-rule`
Expected: `KILLED`.

- [ ] **Step 8B: Commit**

```bash
git add router/firewall.user tests/firewall-user.bats tests/mutation/corpus/firewall-user.sh
git commit -m "dns: let the NAS reach AdGuard's admin port, scoped to one host"
```

---

## Task 2: Settle whether the tailnet gets ad blocking

> **DECIDED 2026-09-21: Branch B.** The tailnet is filtered, so a remote device sees the same DNS a home one does. Execute Steps 1–2 for the record, then **Branch B** (Steps 5B–8B) and its commit. Branch A below is kept only for the record.

`tailscale0` is not in `router/firewall.user`'s interface list, so a tailnet client resolving through the router reaches dnsmasq and gets no filtering. `tests/router-dns.bats` reports this as a note and deliberately does not fail on it — whether the tailnet should be filtered is a policy decision nobody has made.

**Files:**
- Modify: `router/firewall.user`, `tests/firewall-user.bats`, `tests/router-dns.bats`, `scripts/lib/router-dns.sh`
- Test: `tests/firewall-user.bats`, `tests/lib-router-dns.bats`

**Interfaces:**
- Consumes: `ARRDNS_IFACES` from `router/firewall.user`; `router_dns_client_ifaces` and the tailnet note in `router_dns_client_path_check`.
- Produces: a decided and tested tailnet posture.

- [ ] **Step 1: Establish what a tailnet client gets today**

```bash
ssh -i ~/.ssh/gl_router_ed25519 root@100.70.123.86 \
  'dig +short doubleclick.net @100.70.123.86;
   echo "--- via the redirect path, i.e. what a client on a bridge gets:"
   dig +short doubleclick.net @192.168.8.1'
```

Expected: the first returns real addresses (dnsmasq, unfiltered); the second returns `0.0.0.0`.

Measured 2026-09-21:

```
tailnet query  @100.70.123.86  doubleclick.net -> 142.250.129.101   unfiltered
bridge client  via the router  doubleclick.net -> 0.0.0.0           filtered
covered interfaces: br-guest br-lan.1 br-lan.10 br-lan.20 br-lan.30
tailscale0 rules: 0
```

- [ ] **Step 2: Put the decision to the user**

> Tailnet devices (phones, laptops off-site) resolve through the router's `tailscale0` and get **no ad blocking** — they reach dnsmasq, which is the fallback resolver. Two options:
> **(A)** Leave the tailnet unfiltered. Remote devices behave differently from home ones, on purpose.
> **(B)** Add `tailscale0` to the redirect so tailnet DNS goes to AdGuard too. Remote clients get the same filtering; the cost is that a tailnet device now depends on AdGuard being up (the watchdog covers it, but the exposure is real for a device that is not on the LAN).

#### Branch A — leave it

- [ ] **Step 3A: Record the decision as a settled policy, not an omission**

In `scripts/lib/router-dns.sh`, the tailnet note's wording currently ends "Not asserted — whether the tailnet should be filtered is an open decision." Replace that sentence with:

```
Not asserted: the tailnet is deliberately unfiltered. Tailnet DNS reaches
dnsmasq rather than AdGuard Home, so a remote device is not made dependent on
AdGuard being up. Settled 2026-09-21 — see docs/LOCAL-DNS.md.
```

Add the matching paragraph to `docs/LOCAL-DNS.md`.

- [ ] **Step 4A: Verify and commit**

```bash
./tests/run-tests.sh tests/lib-router-dns.bats tests/router-dns.bats
git add scripts/lib/router-dns.sh docs/LOCAL-DNS.md
git commit -m "dns: settle the tailnet as deliberately unfiltered"
```

#### Branch B — filter the tailnet

- [x] **Step 5B: Write the failing tests**

In `tests/firewall-user.bats`:

```bash
@test "firewall-user: the tailnet is redirected when the tailnet is in scope" {
    port_file 3053
    dig_answers

    bash "$FIREWALL"

    # RED while ARRDNS_IFACES omits tailscale0: a remote device would resolve
    # through dnsmasq and get no ad blocking, unlike every device at home.
    [[ "$(grep -c -- "-i tailscale0 -p udp --dport 53" "$IPT_LOG")" -ge 1 ]]
}
```

In `tests/lib-router-dns.bats`, replace the existing tailnet test (currently "a tailnet interface is reported, never failed") with:

```bash
@test "router-dns: a tailnet interface is required when the tailnet is in scope" {
    client_ifaces_capture ifaces.txt br-lan.1:192.168.8.1 tailscale0:100.70.123.86
    nat_capture nat.txt "$(direct_dns br-lan.1 tcp)" "$(direct_dns br-lan.1 udp)"

    # RED while the derivation only ever prints bridges: tailscale0 would be
    # silently exempt from the invariant that every client interface is served.
    ROUTER_DNS_EXTRA_CLIENT_IFACES=tailscale0 \
        run router_dns_client_path_check 3053 "$FIX/ifaces.txt" "$FIX/nat.txt"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL tailscale0"* ]]
}

@test "router-dns: a covered tailnet interface passes when the tailnet is in scope" {
    client_ifaces_capture ifaces.txt br-lan.1:192.168.8.1 tailscale0:100.70.123.86
    nat_capture nat.txt \
        "$(direct_dns br-lan.1 tcp)" "$(direct_dns br-lan.1 udp)" \
        "$(direct_dns tailscale0 tcp)" "$(direct_dns tailscale0 udp)"

    # The positive arm, and it is not decoration: without it a derivation that
    # dropped tailscale0 entirely would satisfy the failure test above, because
    # that test only ever asserts the failure it was written to produce.
    ROUTER_DNS_EXTRA_CLIENT_IFACES=tailscale0 \
        run router_dns_client_path_check 3053 "$FIX/ifaces.txt" "$FIX/nat.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok   tailscale0"* ]]
}
```

- [x] **Step 6B: Run them and watch them fail**

Run: `./tests/run-tests.sh tests/firewall-user.bats tests/lib-router-dns.bats`
Expected: FAIL on both.

- [x] **Step 7B: Implement**

In `router/firewall.user`, extend the list — as a default, so an operator can still override it:

```sh
ARRDNS_IFACES="${ARRDNS_IFACES:-br-lan.1 br-lan.10 br-lan.20 br-lan.30 br-guest tailscale0}"
```

In `scripts/lib/router-dns.sh`, replace `router_dns_client_ifaces` with a version that takes non-bridge clients from a variable, defaulting to none so today's behaviour is unchanged:

```bash
# router_dns_client_ifaces -- stdin: `ip -4 -o addr show` -> one interface name
# per line, for every interface that serves clients.
#
# Bridges by default. ROUTER_DNS_EXTRA_CLIENT_IFACES names any non-bridge
# interface that also serves clients -- the tailnet, when it is in scope -- and
# is empty otherwise.
router_dns_client_ifaces() {
    awk -v extra="${ROUTER_DNS_EXTRA_CLIENT_IFACES-}" '
        BEGIN { n = split(extra, e, " "); for (i = 1; i <= n; i++) if (e[i] != "") want[e[i]] = 1 }
        $1 ~ /^[0-9]+:$/ { name = $2 }
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "inet") {
                    addr = $(i + 1)
                    sub(/\/.*/, "", addr)
                    if (addr !~ /^127\./ && (name ~ /^br-/ || name in want)) print name
                    break
                }
            }
        }'
}
```

Then delete the note-only tailnet branch in `router_dns_client_path_check` (the block that prints "tailscale0 is NOT redirected" / "tailscale0 DNS is redirected as well") — with the tailnet in scope it is a required interface like any other, and the note becomes a second, weaker way of saying the same thing.

Finally, close the live coverage gap. `router-dns.bats` group (d) runs against the real router, and it does **not** set the variable — so without this it would pass whether or not the deployed include carries `tailscale0`, and the deployed state would be the one thing unasserted. Add the export to that test, before the loop:

```bash
    # Set here, not in the lib's default: this is the arm that reads the router,
    # and without it the live check derives bridges only and reports a healthy
    # client path even if the deployed include has dropped the tailnet.
    export ROUTER_DNS_EXTRA_CLIENT_IFACES=tailscale0
```

`ROUTER_DNS_EXTRA_CLIENT_IFACES` is for the **tests**. Production covers the interface directly through `router/firewall.user`, and setting it in the router's environment would do nothing — `fw3` sources the include with a bare PATH and no repo config. Note that in the lib comment so nobody wires both.

- [x] **Step 8B: Verify, deploy, verify live, add the mutation, commit**

```bash
./tests/run-tests.sh tests/firewall-user.bats tests/lib-router-dns.bats tests/router-dns.bats
ssh -i ~/.ssh/gl_router_ed25519 root@100.70.123.86 'cat > /etc/firewall.user' < router/firewall.user
ssh -i ~/.ssh/gl_router_ed25519 root@100.70.123.86 \
  'sh /etc/firewall.user; iptables -t nat -S PREROUTING | grep tailscale0'
```

Expected: two `redir ports 3053` rules for `tailscale0`; a tailnet query for a blocklisted name now answers `0.0.0.0`.

Add a corpus entry (same shape as Task 1 Step 7B) that removes `tailscale0` from the list and is killed by the new test. Then commit, push and open the PR — the global constraints require one:

```bash
git checkout -b fix/dns-filter-the-tailnet
git add router/firewall.user tests/firewall-user.bats tests/lib-router-dns.bats \
        tests/router-dns.bats tests/mutation/corpus/firewall-user.sh
git commit -m "dns: filter the tailnet, and assert it in both directions"
git push -u origin fix/dns-filter-the-tailnet
gh pr create --base main --head fix/dns-filter-the-tailnet --fill
```

---

## Task 3: Back up the two volumes before anything is removed

Phase 9.4 says "back up the volumes first per the repo's backup convention". `scripts/arr-backup.sh` uses `/volume1/docker/arr-stack-backups` as the destination.

**Files:**
- Create: `/volume1/docker/arr-stack-backups/pihole-etc-pihole-<stamp>.tgz` and `dnscrypt-config-<stamp>.tgz` on the NAS
- Test: the verification step below

**Interfaces:**
- Consumes: nothing.
- Produces: two tarballs whose paths Task 4's commit message cites.

- [ ] **Step 1: Confirm the volumes and what is in them**

```bash
ssh -o ConnectTimeout=12 -i ~/.ssh/ugreen_nas_ed25519 leoleg@100.98.67.13 \
  'docker volume ls --format "{{.Name}}" | grep -E "pihole|dnscrypt";
   docker run --rm -v arr-stack_pihole-etc-pihole:/src:ro alpine sh -c "du -sh /src; ls /src | head -8"'
```

Expected: `arr-stack_pihole-etc-pihole`, `arr-stack_dnscrypt-config`; `pihole-FTL.db` (about 70 MB) among the contents.

- [ ] **Step 2: Back them up**

```bash
STAMP=$(date +%Y%m%d-%H%M%S)
ssh -o ConnectTimeout=12 -i ~/.ssh/ugreen_nas_ed25519 leoleg@100.98.67.13 "
  mkdir -p /volume1/docker/arr-stack-backups
  for pair in 'arr-stack_pihole-etc-pihole:pihole-etc-pihole' 'arr-stack_dnscrypt-config:dnscrypt-config'; do
    vol=\${pair%%:*}; name=\${pair#*:}
    docker run --rm -v \$vol:/src:ro -v /volume1/docker/arr-stack-backups:/bak alpine \
      tar czf /bak/\$name-$STAMP.tgz -C /src .
  done
  ls -lh /volume1/docker/arr-stack-backups/*-$STAMP.tgz"
```

- [ ] **Step 3: Verify the tarballs are readable and non-trivial**

`STAMP` does not survive from Step 2 — that was its own shell. Re-derive it from
the two newest tarballs, or the glob expands to a literal `*-.tgz`, matches
nothing, and this step fails whatever the backup did:

```bash
ssh -o ConnectTimeout=12 -i ~/.ssh/ugreen_nas_ed25519 leoleg@100.98.67.13 '
  for f in $(ls -t /volume1/docker/arr-stack-backups/*.tgz | head -2); do
    printf "  %s: %s entries\n" "$f" "$(tar tzf "$f" | wc -l)"
  done'
```

Expected: two files, both with entries (not 0, not an error). **A 0-entry tarball is a failure, not a small one** — `tar` exits 0 on an empty directory.

- [ ] **Step 4: Record the paths**

Note both tarball paths in `.superpowers/sdd/2026-09-19-dns-adguard-router-migration/progress.md` so Task 4 can cite them.

- [ ] **Step 5: Commit** — nothing to commit; this task's deliverable is on the NAS. Its proof is Step 3's output, pasted into the ledger.

---

## Task 4: Remove Pi-hole and dnscrypt-proxy from the stack

The services are stopped and nothing points at them. This removes the definitions, so no future `docker compose up` can bring them back.

**Files:**
- Modify: `docker-compose.arr-stack.yml` — the `dnscrypt-proxy:` service (line 422), the `pihole:` service (line 455), the `dnscrypt-config:` volume (line 53), the `pihole-etc-pihole:` volume (line 55)
- Modify: `scripts/configure-apps.sh` — delete `configure_pihole()` and its call
- Modify: `tests/configure-apps.bats` — remove the Pi-hole assertions
- Test: `tests/configure-apps.bats`, `./tests/run-tests.sh`

**Interfaces:**
- Consumes: the volume backups from Task 3; the Task 1/2 decisions recorded in `docs/LOCAL-DNS.md`.
- Produces: a stack with no NAS resolver. Task 6 removes the last DNS name that pointed at it.

- [ ] **Step 1: Establish the current baseline so a new failure is visible**

Run: `./tests/run-tests.sh > /tmp/before-9.4.out 2>&1; grep -c '^not ok' /tmp/before-9.4.out`
Expected: `28`. Record it; Step 7 compares against it.

- [ ] **Step 2: Write the failing test**

Create `tests/no-nas-resolver.bats`:

```bash
#!/usr/bin/env bats
# The NAS is not a resolver any more. Phase 9.4 of the DNS migration.
#
# These read compose text, so they run anywhere -- including CI, which is the
# point: a service that is merely stopped comes back on a reboot, and a service
# removed from the file cannot.

setup() {
    load helpers/setup
}

@test "no-nas-resolver: neither service is defined in any compose file" {
    local hits
    hits="$(grep -rn '^  \(pihole\|dnscrypt-proxy\):' "$REPO_ROOT"/docker-compose*.yml || true)"
    # RED while either is still declared. docker compose up -d starts every
    # service in the file, so a definition is a resurrection waiting for a reboot.
    [ -z "$hits" ] || fail "still declared: $hits"
}

@test "no-nas-resolver: nothing in the stack points at the old resolver addresses" {
    local hits
    hits="$(grep -rn '172\.20\.0\.5\|172\.20\.0\.6' "$REPO_ROOT"/docker-compose*.yml "$REPO_ROOT"/traefik/dynamic/*.yml || true)"
    # 172.20.0.5 was Pi-hole and 172.20.0.6 dnscrypt-proxy. A leftover reference
    # is a container that cannot resolve once those addresses are gone.
    [ -z "$hits" ] || fail "still referenced: $hits"
}

@test "no-nas-resolver: the compose files still parse" {
    local f
    for f in "$REPO_ROOT"/docker-compose.arr-stack.yml "$REPO_ROOT"/docker-compose.utilities.yml; do
        run docker compose --env-file "$REPO_ROOT/.env.example" -f "$f" config --quiet
        [ "$status" -eq 0 ] || skip "docker compose unavailable, or the file will not parse: $output"
    done
}
```

- [ ] **Step 3: Run it and watch it fail**

Run: `./tests/run-tests.sh tests/no-nas-resolver.bats`
Expected: the first two FAIL naming the services and the addresses; the third passes.

- [ ] **Step 4: Remove the services**

Delete from `docker-compose.arr-stack.yml`: the `dnscrypt-proxy:` and `pihole:` service blocks, the `dnscrypt-config:` and `pihole-etc-pihole:` volume declarations, and the `- ./pihole/dnsmasq.d:/etc/dnsmasq.d` line inside the pihole service.

**Delete the compose line, not the path.** `pihole/dnsmasq.d/02-local-dns.conf.example` is the single source both DNS stores are generated from, and Task 6 edits it — removing the directory takes all 19 `.lan` names with it, not just `pihole.lan`.

Leave a note where each was:

```yaml
  # Pin-hole and dnscrypt-proxy lived here until 2026-09-21. DNS moved to AdGuard
  # Home on the router and nothing pointed at them any more. Volumes were backed
  # up to /volume1/docker/arr-stack-backups/ before removal; restore from there if
  # a rollback is ever wanted. See docs/DNS-MIGRATION.md.
```

- [ ] **Step 5: Remove configure-apps' Pi-hole step**

Delete `configure_pihole()` from `scripts/configure-apps.sh` and its call site. Remove the matching tests from `tests/configure-apps.bats` — including `configure-apps: --dry-run still names every step it would have taken`, whose partial-output assertion names the Pi-hole line, and the two `--dry-run touches nothing … Pi-hole` assertions.

- [ ] **Step 6: Delete the now-dead mutation entries**

Remove `configure-apps-pihole-dry-run-gate-removed` from `tests/mutation/corpus/configure-apps.sh`. It targets a function that no longer exists, and the harness errors on a mutation that changes nothing.

- [ ] **Step 7: Run the suite and compare to the baseline**

Run: `./tests/run-tests.sh > /tmp/after-9.4.out 2>&1; grep -c '^not ok' /tmp/after-9.4.out`
Expected: `28`, or fewer. **A number above 28 is a regression** — diff the two failure lists before going on.

- [ ] **Step 8: Deploy to the NAS and verify the stack still works**

```bash
./scripts/sync-nas.sh
ssh -o ConnectTimeout=15 -i ~/.ssh/ugreen_nas_ed25519 leoleg@100.98.67.13 '
  cd /volume1/docker/arr-stack
  docker compose -f docker-compose.arr-stack.yml up -d
  docker ps --format "{{.Names}}\t{{.Status}}" | grep -E "gluetun|sonarr|radarr|prowlarr|jellyfin"'
```

Expected: every remaining service `Up`; `pihole` and `dnscrypt-proxy` absent from `docker ps -a` only after Step 9.

- [ ] **Step 9: Remove the stopped containers**

```bash
ssh -o ConnectTimeout=15 -i ~/.ssh/ugreen_nas_ed25519 leoleg@100.98.67.13 \
  'docker rm pihole dnscrypt-proxy' || echo "!! docker rm FAILED -- containers still exist"

ssh -o ConnectTimeout=15 -i ~/.ssh/ugreen_nas_ed25519 leoleg@100.98.67.13 \
  'docker volume ls --format "{{.Name}}" | grep -E "pihole|dnscrypt" || echo "(no such volumes)"'
```

Two commands, not one `&&`/`||` chain: chained, a `docker rm` that fails short-circuits into the volume branch and reports "volumes kept or gone" for a removal that never happened.

**Keep the volumes.** Step 11 verifies the backups restore, and the volumes stay until it passes.

- [ ] **Step 10: Verify the backup restores, before the PR**

Step 9 deferred to this, so it has to actually happen here — `tar tzf` counting entries is not a restore.

```bash
ssh -o ConnectTimeout=15 -i ~/.ssh/ugreen_nas_ed25519 leoleg@100.98.67.13 '
  newest=$(ls -t /volume1/docker/arr-stack-backups/pihole-etc-pihole-*.tgz | head -1)
  docker run --rm -v /volume1/docker/arr-stack-backups:/bak:ro alpine \
    sh -c "mkdir -p /tmp/x && tar xzf /bak/$(basename "$newest") -C /tmp/x && \
           ls -l /tmp/x/pihole-FTL.db && head -c 16 /tmp/x/pihole-FTL.db | od -c | head -1"'
```

Expected: `pihole-FTL.db` extracted, and its first 16 bytes start `S Q L i t e   f o r m a t 3`. If it does not, **stop** — do not remove the volumes, and fix the backup first.

- [ ] **Step 11: Mark 9.4 done in the migration plan**

Set `- [ ] **9.4 Only then**` to `- [x] **9.4 Only then**` in `docs/superpowers/plans/2026-09-19-dns-adguard-router-migration.md`, citing the backup paths from Task 3. **Task 8 asserts that plan has no open boxes** — an unticked box makes that check permanently red.

- [ ] **Step 12: Commit and open the PR**

```bash
git add docker-compose.arr-stack.yml scripts/configure-apps.sh tests/configure-apps.bats \
        tests/mutation/corpus/configure-apps.sh tests/no-nas-resolver.bats
git commit -m "dns: remove the NAS resolver from the stack (Phase 9.4)"
git push -u origin fix/dns-remove-nas-resolver
gh pr create --base main --head fix/dns-remove-nas-resolver --fill
```

Then wait for CI green, `gh pr merge --squash`, `git checkout main && git fetch origin main && git merge --ff-only origin/main`, `./scripts/sync-nas.sh`.

---

## Task 5: Retire everything that reads the NAS resolver (8.6)

`scripts/lib/check-dns-duplicates.sh` and `scripts/lib/check-domains.sh` read the NAS Pi-hole's config and resolve names through it. Both stores are gone as of Task 4, so the checks can only misreport. `check-dns-duplicates.sh` in particular guards an unreadable `dnsmasq` side but not an unreadable `pihole.toml` side — it cannot tell "no entries" from "could not read", which is exactly the state it is about to be in.

**Files:**
- Delete: `scripts/lib/check-dns-duplicates.sh`, `scripts/lib/check-domains.sh`, `tests/lib-dns-duplicates.bats`, `tests/lib-domains.bats`, `tests/mutation/corpus/dns-duplicates.sh`, `tests/mutation/corpus/domains.sh`
- Modify: `scripts/pre-commit` (lines 42–43 source them, 143 and 150 call them), `scripts/lib/check-dns-divergence.sh` (lines 15 and 277 refer to them in comments), `tests/lib-common.bats:479` (a comment), `tests/mutation/corpus/common.sh` (a `--why` names `check-dns-duplicates.sh`)
- Modify: `scripts/dns-matrix-check.sh:21` and `scripts/dns-parity.sh:36` — both still default to the resolver this phase removes
- **Not** `tests/fixtures/dns-baseline.txt`: it is the 50-row oracle consumed by `scripts/dns-parity.sh`, `scripts/lib/dns-matrix.sh`, `scripts/lib/dns-parity.sh`, `tests/lib-dns-matrix.bats` and `tests/e2e/dns.spec.ts`, and has nothing to do with these two checks.
- Test: `./tests/run-tests.sh`, `tests/shellcheck.bats`

**Interfaces:**
- Consumes: Task 4 (the services must be gone first — retiring the checks while the stores exist would delete live coverage).
- Produces: nothing; this is removal.

- [ ] **Step 1: Find every reference, so none is left dangling**

```bash
grep -rn "check-dns-duplicates\|check-domains\|check_dns_duplicates\|check_domains" \
  --include="*.sh" --include="*.bats" --include="*.md" --include="*.yml" . \
  | grep -v "^./docs/superpowers/plans/" | grep -v "^./.superpowers/"
```

Record the list. Every line is either deleted, updated, or justified in the commit message.

- [ ] **Step 2: Delete the files and the two call sites**

```bash
git rm scripts/lib/check-dns-duplicates.sh scripts/lib/check-domains.sh \
       tests/lib-dns-duplicates.bats tests/lib-domains.bats \
       tests/mutation/corpus/dns-duplicates.sh tests/mutation/corpus/domains.sh
```

Then remove lines 42–43 and the calls at 143 and 150 from `scripts/pre-commit`.

- [ ] **Step 3: Update the prose that named them**

In `scripts/lib/check-dns-divergence.sh`, both comments describe what the deleted check covered. Rewrite them to say the check was retired with the store, and that `check-dns-divergence.sh` is now the only thing comparing the two stores. Same for `tests/lib-common.bats:479` and the `--why` in `tests/mutation/corpus/common.sh` — **no backticks in corpus prose**.

- [ ] **Step 4: Let the oracles name anything still stale**

Run: `./tests/run-tests.sh tests/shellcheck.bats tests/mutation-corpus.bats`
Expected: PASS. If `shellcheck.bats`'s no-sweep oracle or `CONTRIBUTING.md`'s scripts-tree oracle names a deleted file, update that inventory — the oracle tests exist to catch exactly this.

- [ ] **Step 5: Run the suite and compare**

Run: `./tests/run-tests.sh > /tmp/after-8.6.out 2>&1; grep -c '^not ok' /tmp/after-8.6.out`
Expected: no new failures against the Task 4 baseline.

- [ ] **Step 6: Repoint the two scripts that still default to the NAS resolver**

Both read the resolver this phase removes, and neither is covered by any other task:

```bash
grep -n 'NAS_DNS_IP:-192.168.110.246' scripts/dns-matrix-check.sh scripts/dns-parity.sh
```

```
dns-matrix-check.sh:21:  RESOLVER="${1:-${NAS_DNS_IP:-192.168.110.246}}"
dns-parity.sh:36:        DEFAULT_A="${NAS_DNS_IP:-192.168.110.246}:53"
```

A bare invocation after Task 4 queries a resolver that no longer exists and reports whatever an empty answer looks like. Repoint both defaults at the router (`192.168.8.1`) and update the usage text in each file's header, which still names the NAS Pi-hole.

- [ ] **Step 7: Mark 8.6 done in the migration plan**

Set `- [ ] **8.6**` to `- [x] **8.6**` in `docs/superpowers/plans/2026-09-19-dns-adguard-router-migration.md`, with a line saying what was retired and that the fixtures survive. **Task 8 asserts that plan has no open boxes** — a task that changes a phase without ticking it leaves that check permanently red.

- [ ] **Step 8: Commit, PR, merge**

```bash
git add -A
git commit -m "dns: retire the two NAS-resolver checks (Phase 8.6)"
git push -u origin fix/dns-retire-resolver-checks
gh pr create --base main --head fix/dns-retire-resolver-checks --fill
```

---

## Task 6: Retire the `pihole.lan` name from both DNS stores

The name still resolves (`192.168.110.250`, Traefik) but its route was retired in `#109`, so it 404s. Both DNS stores are generated from one file, so retiring it means editing that file and re-running both generators.

**Files:**
- Modify: `pihole/dnsmasq.d/02-local-dns.conf.example` (line 29)
- Modify: `tests/lib-domains.bats` — only if Task 5 has not deleted it; otherwise the check's list is already gone
- Test: `tests/dnsmasq-local-names.bats`, `tests/router-dns.bats`

**Interfaces:**
- Consumes: Task 5 (`check-domains.sh` asserted this name resolves, so the name must not be retired before the check is gone, or that check fails — that ordering is the whole reason these two tasks are adjacent).
- Produces: no DNS record for a service that no longer exists.

- [ ] **Step 1: Confirm the ordering constraint is satisfied**

```bash
grep -rn "pihole.lan" scripts/lib/check-domains.sh tests/lib-domains.bats 2>/dev/null || echo "check retired — safe to proceed"
```

Expected: `check retired — safe to proceed`. If those files still exist, do Task 5 first: `tests/lib-domains.bats` asserts the domains check queries every published name, so retiring the name while the check lives is a red test.

- [ ] **Step 2: Remove the record**

Delete `address=/pihole.lan/TRAEFIK_LAN_IP` from `pihole/dnsmasq.d/02-local-dns.conf.example`.

- [ ] **Step 3: Re-run both generators**

```bash
./scripts/dnsmasq-local-names.sh          # the router's dnsmasq
./scripts/adguard-configure.sh            # AdGuard Home's DNS rewrites
```

Both parse that one file, so both drop the name together. AdGuard restarts as part of this — expect a sub-second DNS blip.

- [ ] **Step 4: Verify from a client that the name is gone and the rest are not**

```bash
ssh -o ConnectTimeout=8 pi@pi1.local '
  echo "pihole.lan: $(dig +short +time=3 +tries=1 pihole.lan  | tr "\n" " ")<-- expect empty"
  echo "sonarr.lan: $(dig +short +time=3 +tries=1 sonarr.lan)"
  echo "blocked:    $(dig +short +time=3 +tries=1 doubleclick.net | head -1)"
  echo "public:     $(dig +short +time=3 +tries=1 github.com | head -1)"'
```

Expected: `pihole.lan` empty; `sonarr.lan` → `192.168.110.250`; `blocked` → `0.0.0.0`; `public` a real address.

- [ ] **Step 5: Run the suite**

Run: `./tests/run-tests.sh tests/dnsmasq-local-names.bats tests/router-dns.bats tests/no-nas-resolver.bats`
Expected: PASS. If `dnsmasq-local-names.bats` pins the record count, update it — 19 names become 18.

- [ ] **Step 6: Commit, PR, merge**

```bash
git add -A
git commit -m "dns: retire the pihole.lan name from both DNS stores"
git push -u origin fix/dns-retire-pihole-name
gh pr create --base main --head fix/dns-retire-pihole-name --fill
```

---

## Task 7: Record the retirement (9.5)

Nine months of incident records exist for less change than this. The repo's convention for this is an audited project log in the style of `docs/EXIT-NODE-PROJECT-LOG.md`.

**Files:**
- Create: `docs/DNS-MIGRATION.md`
- Modify: `docs/LOCAL-DNS.md`, `CLAUDE.md`, `README.md` — each still describes the NAS as a live resolver somewhere
- Test: `tests/lib-doc-links.bats`, and an `executed=0` guard like the exit-node log has

**Interfaces:**
- Consumes: every measurement in this plan and in `.superpowers/sdd/2026-09-19-dns-adguard-router-migration/progress.md`.
- Produces: the durable record. Nothing depends on it.

- [ ] **Step 1: Write the document**

Create `docs/DNS-MIGRATION.md` following the exit-node log's shape: **Status at a glance**, **Commit-by-commit audit** (`#104`–the removal PR), **The plan's phases — planned vs actual**, **Corrections — where the plan was wrong**, **Live-only state that is not in this repo**, **Open items**.

It must contain, with the numbers as measured:

- the goal, and that the NAS being off no longer removes DNS — evidenced by the reboot monitor: **99 samples, 99 resolved, 0 failures, including 36/36 during the 108 seconds the NAS was down**;
- the corrections, which are the valuable part: the redirect once covered only stale leases and was being undone by lease renewal; `fw3` does not re-run `/etc/firewall.user` on reload; IPv6 was never out of scope though the plan said it was; `docker stop` is not durable against `restart: always`; and the router-reboot window between `S19firewall` and `S99adguardhome`;
- the two guards that could not fail, and that running them is what found both;
- the measurement trap: a query the router sends to its own address is not a client test;
- that 9.3's stated method is unusable because 9.1 stops the container, with the database evidence instead;
- live-only state: `router/firewall.user`, `router/arrdns-watchdog.sh`, `/etc/arrdns-port`, the crontab entry, `firewall.@include[0].reload='1'`;

- [ ] **Step 2: Fix the docs that still describe a NAS resolver**

```bash
grep -rn "NAS Pi-hole\|nas resolver\|172\.20\.0\.5" docs/*.md CLAUDE.md README.md | grep -v "^docs/DNS-MIGRATION.md" | grep -v "^docs/superpowers/"
```

Each hit is either updated or explicitly marked historical. `CLAUDE.md`'s DNS section already says the services are stopped — update it to say removed.

- [ ] **Step 3: Verify the links and the doc scan**

Run: `./tests/run-tests.sh tests/lib-doc-links.bats`
Expected: PASS. Broken relative links fail this.

- [ ] **Step 4: Mark 9.5 done in the migration plan**

Set `- [ ] **9.5 Record the retirement**` to `- [x]`, pointing at `docs/DNS-MIGRATION.md`. **Task 8 asserts that plan has no open boxes.**

- [ ] **Step 5: Commit, PR, merge**

```bash
git add -A
git commit -m "docs: record the DNS migration and its corrections (Phase 9.5)"
git push -u origin fix/dns-migration-record
gh pr create --base main --head fix/dns-migration-record --fill
```

---

## Task 8: Close the soak items (5.4, 9.2, 9.3)

**This task cannot run before 2026-09-28.** Nine-point-one stopped the NAS resolver on 2026-09-21; Gate 9 is "a week with no traffic to the NAS resolver and no incident". Starting it early defeats the gate it is meant to satisfy.

**Files:**
- Modify: `docs/superpowers/plans/2026-09-19-dns-adguard-router-migration.md` (5.4, 9.2, 9.3)
- Test: the checks below, and the plan's own checkbox count

**Interfaces:**
- Consumes: Task 4 (the services must be gone for the week to mean anything).
- Produces: 9.2 and 9.3 marked done, or a written statement of what is still open.

- [ ] **Step 1: Refuse to start early**

```bash
[ "$(date +%Y-%m-%d)" \< "2026-09-28" ] && echo "too early: Gate 9 needs a week from 2026-09-21" || echo "the week has passed"
```

Expected: `the week has passed`. If not, stop — do not mark 9.2 or 9.3 done.

- [ ] **Step 2: Gather the week's evidence**

```bash
# The router moved the house only if it had to, and said why when it did.
ssh -i ~/.ssh/gl_router_ed25519 root@100.70.123.86 '
  echo "=== watchdog transitions this week ==="; cat /var/log/arrdns-watchdog.log 2>/dev/null || echo "(none — the log is tmpfs and does not survive a reboot)"
  echo "=== current ==="; /usr/sbin/arrdns-watchdog.sh --status
  echo "=== rules ==="; iptables -t nat -S PREROUTING | grep -c "dport 53.*to-ports"; ip6tables -t nat -S PREROUTING | grep -c "dport 53.*to-ports"'

# Nothing on the NAS should have logged a DNS failure all week.
ssh -o ConnectTimeout=15 -i ~/.ssh/ugreen_nas_ed25519 leoleg@100.98.67.13 '
  for c in gluetun uptime-kuma sonarr radarr prowlarr jellyfin; do
    printf "  %-14s %s\n" "$c" "$(docker logs "$c" --since 168h 2>&1 | grep -icE "no such host|server misbehaving|could not resolve" || true)"
  done'

# A client, both families.
ssh -o ConnectTimeout=8 pi@pi1.local '
  echo "v4 blocked: $(dig +short doubleclick.net | head -1)"
  echo "v6 blocked: $(dig +short doubleclick.net @fde0:4646:77b8::1 | head -1)"'
```

Expected: no transition attributable to an incident; `mode=adguard probe=up`; 10 rules per family; zero DNS failures in every container; `0.0.0.0` on both families.

- [ ] **Step 3: Mark 9.2 and 9.3, and close 5.4**

In the plan:
- **9.2** → `[x]`, citing the checks above and stating what the week covered.
- **9.3** → `[x]`, citing the database evidence already recorded (every real LAN client's last query between 10:50 and 11:15 on 2026-09-21; nothing after the stop), and restating that the count is guaranteed by the redirect and is therefore weak evidence — the resolver being off for a week with nothing noticing is the strong evidence.
- **5.4** → `[x]`, marked **not applicable**: the 24-hour soak assumed a healthy baseline to soak against, and on 2026-09-21 resolution was already down for the whole house. There was no staged migration to observe.

- [ ] **Step 4: Verify the plan reads correctly**

```bash
grep -c '^- \[x\]' docs/superpowers/plans/2026-09-19-dns-adguard-router-migration.md
grep -n '^- \[ \]'  docs/superpowers/plans/2026-09-19-dns-adguard-router-migration.md
```

Expected: the second command lists nothing — 51 of 51. If anything is still open, it gets a note saying why, not a silent checkbox.

- [ ] **Step 5: Commit, PR, merge**

```bash
git add docs/superpowers/plans/2026-09-19-dns-adguard-router-migration.md
git commit -m "docs: close the DNS migration's soak items (5.4, 9.2, 9.3)"
git push -u origin fix/dns-close-soak
gh pr create --base main --head fix/dns-close-soak --fill
```

---

## Task 9: Two small cleanups the migration left behind

**Files:**
- Modify: `docker-compose.utilities.yml:352`, `.env.example:230`, `router/arrdns-watchdog.sh`, `docs/LOCAL-DNS.md`
- Test: `tests/env-vars.bats`, `tests/firewall-user.bats`

**Interfaces:**
- Consumes: Task 4 (the Pi-hole service must be gone before its token is).
- Produces: nothing.

- [ ] **Step 1: Check whether the Homepage token is still needed**

```bash
grep -rn "PIHOLE_API_TOKEN\|HOMEPAGE_VAR_PIHOLE" --include="*.yaml" --include="*.yml" --include="*.example" .
```

Expected after Task 4: only the compose line and the `.env.example` line, with no `services.yaml` consumer — the widget that used it was removed in `#109`.

- [ ] **Step 2: Remove the dead wiring**

Delete the `HOMEPAGE_VAR_PIHOLE_API_TOKEN=${PIHOLE_API_TOKEN}` line from `docker-compose.utilities.yml` and the `PIHOLE_API_TOKEN=` line from `.env.example`.

Run: `./tests/run-tests.sh tests/env-vars.bats`
Expected: PASS. This suite checks `.env.example` against compose usage, so it is the oracle for whether anything still wants the variable.

- [ ] **Step 3: Make the watchdog log survive a router reboot**

`/var/log` is tmpfs, so every transition is lost when the router reboots — including the boot-time fallback, which is the one transition most worth having afterwards. Point the log at the overlay instead:

In `router/arrdns-watchdog.sh`, change

```sh
LOG_FILE=/var/log/arrdns-watchdog.log
```

to

```sh
# /etc is the overlay filesystem and survives a reboot; /var/log is tmpfs and
# does not. The one transition most worth keeping is the boot-time fallback,
# which is exactly the one a tmpfs log loses. A few lines per transition, so
# flash wear is not a concern.
LOG_FILE=/etc/arrdns-watchdog.log
```

- [ ] **Step 4: Deploy and confirm the log lands there**

```bash
ssh -i ~/.ssh/gl_router_ed25519 root@100.70.123.86 'cat > /usr/sbin/arrdns-watchdog.sh' < router/arrdns-watchdog.sh
ssh -i ~/.ssh/gl_router_ed25519 root@100.70.123.86 '
  chmod +x /usr/sbin/arrdns-watchdog.sh
  /usr/sbin/arrdns-watchdog.sh --status
  echo "--- the path the script will actually write ---"
  grep -n "^LOG_FILE=" /usr/sbin/arrdns-watchdog.sh
  echo "--- and /etc survives a reboot; /var/log does not ---"
  df /etc /var/log | tail -2'
```

Expected: `--status` works, `LOG_FILE=/etc/arrdns-watchdog.log`, and `df` shows `/etc` on the overlay and `/var/log` on tmpfs.

Proving the log *gets created* is not available here — it only appears on a transition — so asserting the configured path is the honest check, and the first real transition after this is what confirms it. Do not write `ls ... || echo "not created yet"`: that prints the same line for a healthy router and a typo'd path, which is the equivalence this repo's guards exist to avoid.

- [ ] **Step 5: Commit, PR, merge**

```bash
git add docker-compose.utilities.yml .env.example router/arrdns-watchdog.sh
git commit -m "dns: drop the dead Homepage token, and keep the watchdog log across a reboot"
git push -u origin fix/dns-small-cleanups
gh pr create --base main --head fix/dns-small-cleanups --fill
```

---

## Task 10: Close out the adjacent plan's deferred items

`.superpowers/sdd/2026-09-20-bound-ingest-io/deferred-minors.md` lists eight findings deferred from the ingest plan. **All eight were verified resolved on 2026-09-21** — this task confirms that against the code and marks the file, rather than reworking it. It is a different plan's business, so it is a separate task and a separate PR.

**Files:**
- Modify: `.superpowers/sdd/2026-09-20-bound-ingest-io/deferred-minors.md`
- Test: the greps below

**Interfaces:**
- Consumes: nothing.
- Produces: a closed deferred list, so nobody re-triages it.

- [ ] **Step 1: Verify each item against the code**

```bash
# 6: outbox_depth must say something when find fails
grep -c "queue-high-water: cannot read" scripts/lib/queue_high_water.sh          # expect 1

# 7: the queue gate must sit BELOW the API-key checks in backlog-search
awk '/Could not get API keys/{k=NR} /outbox_over_high_water/{o=NR} END{print "keys at "k", gate at "o; exit (o>k?0:1)}' scripts/backlog-search.sh

# 8: a dry-run gate test must exist
grep -c "stands the dry run down too" tests/stremio-library-sync.bats             # expect 1

# 1 and 4: the corpus --why strings must name the real hazard
grep -c "load went 8.47" tests/mutation/corpus/usenet-blackhole.sh                # expect 1
grep -c "partially written file and an operator" tests/mutation/corpus/queue-high-water.sh  # expect 1

# 3: the python comment must be narrowed to the apply path
grep -c "the dry-run branch returns before any of this runs" tests/python/test_usenet_blackhole.py  # expect 1

# 5: the redundant -n and return 0 must be gone
grep -c 'n "\$dir"' scripts/lib/queue_high_water.sh                               # expect 0
```

Expected: every count as annotated, and the `awk` guard exits 0. Any that does not match is a genuinely open item and gets fixed here instead of marked.

- [ ] **Step 2: Mark the file closed**

Add to the top of `deferred-minors.md`:

```markdown
> **Closed 2026-09-21.** All eight items below were verified resolved against the
> code — the three ruled "Fix." (6, 7, 8) and the five prose or tidy corrections
> (1–5). The verification greps are in the DNS migration's closure plan, Task 10.
> Kept for the record, not as a work list.
```

- [ ] **Step 3: Record the closure where it can be found**

```bash
git check-ignore -v .superpowers/sdd/2026-09-20-bound-ingest-io/deferred-minors.md
```

Expected: it **is** ignored — `.superpowers/sdd/.gitignore` contains `*`, so this file cannot be committed and there is no PR to open. That is the correct home for a working note, and it means the durable record of the closure has to be somewhere else:

- add a line to `.superpowers/sdd/2026-09-19-dns-adguard-router-migration/progress.md` saying the ingest plan's deferred list was verified resolved on 2026-09-21 and where the verification lives;
- and, because both of those are local to this checkout, put the one-line summary in `docs/DNS-MIGRATION.md`'s open-items section in Task 7 — that file is committed, and "the ingest plan's deferred minors were all verified resolved" is a fact worth keeping.

Nothing to commit. If the team ever moves `.superpowers/sdd/` under version control, the note is already written.

---

## Task 11: Clear the working tree

Three files have been sitting uncommitted in the main checkout through the whole migration. They are not the DNS work, and they are one `git checkout` away from being lost.

**Files:**
- Add: `docs/superpowers/plans/2026-09-19-user-timers-survive-reboot.md`, `docs/superpowers/plans/2026-09-20-bound-ingest-io.md` (untracked; both are **trackable**, verified with `git check-ignore`)
- Modify: `docs/MAINTENANCE.md` (tracked, modified)

**Interfaces:**
- Consumes: nothing.
- Produces: a clean tree.

- [ ] **Step 1: See exactly what is loose**

```bash
git status --short
git diff --stat docs/MAINTENANCE.md
```

Expected at the time of writing: `M docs/MAINTENANCE.md`, and two untracked plans — `2026-09-19-user-timers-survive-reboot.md` and `2026-09-20-bound-ingest-io.md`.

- [ ] **Step 2: Establish whether each is wanted**

```bash
git log --oneline -1 origin/main -- docs/MAINTENANCE.md
git show origin/main:docs/MAINTENANCE.md | diff - docs/MAINTENANCE.md | head -40
```

The two plans describe work that has already merged (`#102`, `#103`). The `MAINTENANCE.md` diff is the ingest plan's Task 5 documentation.

- [ ] **Step 3: Land them, or discard them deliberately**

If the diff is the ingest plan's documented outcome, commit it with a message that says so. If it is superseded, `git checkout -- docs/MAINTENANCE.md` and say in the commit that it was superseded — the one outcome that is not acceptable is leaving it loose for another session to trip over.

- [ ] **Step 4: Verify and commit**

```bash
git status --short          # expect no unexpected output
git add -A
git commit -m "docs: land the ingest plan's documentation and its two plans"
git push -u origin fix/working-tree-hygiene
gh pr create --base main --head fix/working-tree-hygiene --fill
```

---

## Self-review

**Spec coverage.** 8.6 → Task 5. 9.2 → Task 8. 9.3 → Task 8, with its method defect recorded in Task 7. 9.4 → Tasks 3, 4 and 6 (the plan bundles "back up, remove, and retire the name" into 9.4; splitting them lets each be verified and reverted alone, and Task 6 has a hard ordering dependency on Task 5). 9.5 → Task 7. 5.4 → Task 8, closed as not applicable. The two decisions the migration left open are Tasks 1 and 2, each with both branches fully specified so neither is a placeholder.

**Placeholders.** Every code step carries the actual text, including Task 2 Branch B's `router_dns_client_ifaces` replacement.

**Type consistency.** `ARRDNS_IFACES`, `ARRDNS_PORT_FILE`, `ARRDNS_DIG`, `LOG_FILE` and `router_dns_client_path_check` are used with the names and signatures they have in the repo today. Task 2's Branch B extends `ARRDNS_IFACES` by default rather than redefining it, so Task 1's `iptables` additions are unaffected.

**Ordering, which is the one thing a careless executor gets wrong.** Task 5 before Task 6 (retiring the name while `check-domains.sh` lives is a red test — it asserts every published name is queried, which is exactly how a premature removal was already caught once). Task 3 before Task 4 (the backups). Task 4 Step 10 before Step 9's volume removal (the restore check). Task 8 last of the migration tasks (it asserts the migration plan has no open boxes, so Tasks 4, 5 and 7 must have ticked theirs). Task 8 not before 2026-09-28.

**What this review changed.** Twelve defects were found by adversarial review before execution and are fixed above. The two that would have cost most: Task 3's backup verification referenced a `STAMP` from a different shell, so the only proof the backup worked always failed and the containers were removed on that basis; and Task 1's `Files:` block had the two decisions' file lists swapped, so an executor taking it as the scope statement would have added the firewall rule the user declined. The rest: three tasks never ticked their migration-plan boxes (making Task 8's final check permanently red), Task 5 listed a fixture five live consumers use for deletion, two scripts still defaulted to the resolver being removed, Task 1 Branch B's test could never pass (the strip and the insert both match its grep), the tailnet guard was one-sided and its deployed state unasserted, Step 9's `||` masked a `docker rm` failure, Step 4's log check could not fail, the measurement could pick the wrong VLAN, and the bind-mount instruction risked deleting the file Task 6 needs.
