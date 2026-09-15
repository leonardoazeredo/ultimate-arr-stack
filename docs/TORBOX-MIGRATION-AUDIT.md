# TorBox Migration Audit (2026-09-15)

Full audit of the TorBox migration merged to `main` (`0a9e7fd..4ea7160`, 90 files,
+8,166/−1,170), covering the removal of qBittorrent, the move of torrenting to
`decypharr` → TorBox debrid, the move of usenet to the arrs' `UsenetBlackhole`
client + `usenet-blackhole.timer` → TorBox's usenet API, and the new
`backlog-search.timer` / `queue-cleanup.timer` pair. Full suite re-run clean
before writing this up: 780 executed, 2 skipped, 0 failed. NAS confirmed on
`4ea7160` with all three timers live.

Findings 1–3 were reproduced against the merged code, not just read. 4–8 were
verified by inspection of the merged tree. Ranked by severity.

## What changed

| Path | Before | Now |
|---|---|---|
| Torrents | qBittorrent behind Gluetun | `decypharr` → TorBox debrid API, on the bridge |
| Usenet | SABnzbd → `nntp.torbox.app` | arr `UsenetBlackhole` client + `usenet-blackhole.timer` → TorBox usenet API |
| Backlog | nothing ever searched it | `backlog-search.timer`, every 4h, bounded |
| Stuck queues | manual | `queue-cleanup.timer`, hourly, with removal memory |

Neither download path needs the VPN any more — only Prowlarr's indexer
scraping still runs through Gluetun. SABnzbd's container is deliberately kept:
it is both an escape hatch for a real usenet provider, and the stack's marker
for "this deployment wants usenet" (`configure-apps.sh` only adds the
blackhole client if SABnzbd is running).

The reason usenet moved is measured, not assumed: `nntp.torbox.app` serves
articles only to about 90 days, so 81 of 85 Sonarr usenet grabs failed on it
while the same releases completed through TorBox's API.

## Findings

### 1. [High] A stuck usenet job can never time out if TorBox forgets it

`scripts/lib/usenet_blackhole.py`, `poll()`, the `record is None` branch.

The module's own docstring states the contract: *"Every job that TorBox
reports failed, or that exceeds `--timeout-hours`, is appended to
`usenet-blackhole-failed.log`."* A blackhole client reports no queue to the
arr, so that log is the only place a stuck release can surface.

```python
record = by_id.get(job.get("torbox_id"))
if record is None:
    results.append((key, job["name"], "unknown"))
    continue          # <-- age check below is never reached
...
if age_hours > timeout_hours:   # unreachable for "unknown"
    record_failure(...)
```

Leaving a *transiently* missing job alone is correct, and is tested. The bug
is that there is no upper bound on how long "transient" may last. A job whose
record is gone for good — deleted from the account, or past the hardcoded
`limit=1000` on the un-paginated `mylist` call — stays in the state file
forever: never timed out, never logged, its NZB never discarded from the
outbox, its staging directory never swept (it stays in the `keep` set).

**Reproduced:** a job submitted 500 hours ago against a 24-hour timeout
returns `unknown` and remains in state indefinitely. **Not currently
manifesting:** the live state file has 6 jobs in flight and 0 past timeout —
this is latent, not active.

**Fix:** apply the same age check inside the `unknown` branch — a job TorBox
hasn't acknowledged for longer than the timeout is a failure, and should be
recorded as "vanished from TorBox." Separately, paginate `mylist` instead of
trusting `limit=1000`.

### 2. [High] The backlog search can fire the unbounded command it exists to avoid

`scripts/lib/backlog_search.py`, `process_sonarr()`, the bulk-switch guard.

This module exists because `MissingEpisodeSearch` is dangerous here. Its own
docstring records the incident: *"measured, it opened with 'Performing search
for 3116 episodes', could not be cancelled (Sonarr returns 409 for a command
that has already started), and had to be killed by restarting the
container."* So the design walks the backlog `limit` seasons at a time, and
only switches to the bulk command once the remaining work is small — "bounded
by definition by then, because the backlog is smaller than the limit." That
invariant does not hold: the cooldown filter reassigns `units` before the
guard measures it.

```python
recent = recently_searched(state.get("history", {}), "sonarr-season", cooldown_hours)
fresh  = [u for u in units if unit_id(u[0], u[1]) not in recent]
if fresh:
    units = fresh           # now "not searched recently", not "remaining"
...
if len(units) <= limit:
    api.post_command("MissingEpisodeSearch")   # searches the WHOLE backlog
```

Once most of the backlog sits inside the cooldown window, `fresh` shrinks
below `limit` while the actual backlog is untouched — and the bulk command
goes out over all of it.

**Reproduced:** with 200 seasons / 3,000 episodes still missing and exactly
one unit outside the cooldown window, the code issues `MissingEpisodeSearch`
over the entire backlog. The relationship is also inverted in a way that will
surprise whoever hits it: raising `--cooldown` to be gentler on indexers puts
*more* units inside the window, making the runaway burst *more* likely, not
less. With shipped defaults (`limit 10`, `cooldown 6h`, timer every 4h) the
exposure is smaller but real — during drain-down the bulk command covers
roughly 2–3x the intended bound.

**Fix:** gate the bulk switch on the total remaining backlog, not the
post-cooldown slice — keep a separate `len(all_units)` and test that, using
`fresh` only to choose which seasons this run walks.

### 3. [Medium] Queue-cleanup's usenet guard no longer matches this stack's usenet client

`scripts/lib/queue_cleanup.py` `is_debrid_client()` ↔
`scripts/lib/configure-helpers.sh` ↔ `docs/APP-CONFIG.md` §4.2.

`is_debrid_client()` excludes usenet clients first, and its docstring says
why: *"this stack's usenet client is named 'SABnzbd (TorBox Usenet)', so the
provider pattern matches it and the exemption below would swallow every dead
NZB too."* That client no longer exists — `configure-helpers.sh` now creates
one named **"Usenet Blackhole"**, which matches neither pattern list:

```python
USENET_CLIENT_PATTERNS = ("sabnzbd", "nzbget", "nzb")
DEBRID_CLIENT_PATTERNS = ("decypharr", "torbox", "debrid")

"Usenet Blackhole" -> is_debrid_client = False   # right answer, by falling through both
"TorBox Blackhole" -> is_debrid_client = True    # wrong -- and this is the name the docs use
```

Today's behaviour is correct only because the shipped name happens to miss
both lists. `docs/APP-CONFIG.md` titles this exact section **"4.2 Usenet
(TorBox Blackhole)"** — an operator naming the client after the docs gets
`is_debrid_client = True`, and every dead NZB inherits the 3-hour debrid
exemption and is never blocklisted. That's precisely the outcome the
docstring says the exclusion exists to prevent.

**Fix:** add `"blackhole"` to `USENET_CLIENT_PATTERNS`, refresh the
docstring to name the client that actually ships, and add a test asserting
the name `configure-helpers.sh` writes classifies as non-debrid.

### 4. [Medium] The busiest new timer is the one unit pair with no test at all

`scripts/usenet-blackhole.service` / `scripts/usenet-blackhole.timer`.

Both sibling timers have unit-file tests (`queue-cleanup.service` asserts
`--apply`; `backlog-search.timer` asserts the `OnBootSec` trap).
`usenet-blackhole`'s two unit files have none — the only mention anywhere in
`tests/` is a prose comment in an unrelated file, and
`tests/systemd-units.bats` hardcodes a 7-unit list that excludes all four new
unit files. The 20 tests in `tests/usenet-blackhole.bats` are thorough but
all cover the shell script's argument handling, none the unit that invokes
it. This matters more than usual here because the script's own comments
record that a dry-run-that-silently-applied bug already shipped once on this
exact path (`${APPLY:+--apply}` is non-empty when `APPLY=false`). The unit
fires every two minutes and carries the TorBox key.

**Fix:** mirror the queue-cleanup unit tests — assert `ExecStart` carries
`--apply`, the log directory is created in the same shell as the redirect,
and the timer's first elapse is measured from activation, not boot. Add all
four new unit files to `tests/systemd-units.bats`'s file list.

### 5. [Medium] ARCHITECTURE.md contradicts itself inside a single diagram

`docs/ARCHITECTURE.md`, "Service Connections".

The `qBittorrent` rows in this block were renamed to `SABnzbd` rather than
deleted, and a line was then added underneath saying the opposite:

```
Bridge -> VPN-side (use gluetun):
-----------------------------
Sonarr -> SABnzbd
  |-- gluetun:8080
Radarr -> SABnzbd
  |-- gluetun:8080
(usenet no longer crosses this boundary - the arrs use the local blackhole client)
```

For the default deployment the parenthetical is the true half —
`configure-helpers.sh` no longer creates a SABnzbd client in either arr. The
table rows describe only the optional bring-your-own-provider path documented
in `APP-CONFIG.md` §4.2, but nothing says so, and as written the two halves
simply disagree.

**Fix:** drop the two rows and keep the note, or label them explicitly as the
opt-in SABnzbd path.

### 6. [Low] One unpinned base image in an otherwise fully pinned build

`decypharr/Dockerfile:48`.

The custom Decypharr image is pinned everywhere else — upstream by commit SHA
rather than tag, `alpine:3.22`, `golang:1.26-alpine`. One line floats:

```dockerfile
FROM --platform=$BUILDPLATFORM tonistiigi/xx AS xx     # no tag -> :latest
```

This is a build-stage cross-compilation helper, so the blast radius is the
binary rather than the runtime image, but it's still a third-party `:latest`
in the supply chain. `tests/decypharr-patch.bats` pins the upstream commit;
nothing covers build-stage base images, and the repo's "no `:latest` tags"
guard only reads compose files.

**Fix:** pin to a released tag or digest, and extend the pinning assertion to
Dockerfile `FROM` lines.

### 7. [Low] The build gate checks one of the two test names it relies on

`decypharr/verify-patch.sh`.

The guard's reasoning is right, and its own comment says why: *"`go test -run
<pattern>` exits 0 reporting 'no tests to run' when nothing matches, so this
gate would go quiet and still pass if the test file never landed."* It then
applies that reasoning to only one of its two names:

```bash
TESTS='TestProvider400IsRetryable|TestSiblingCodesAreUnchanged'
...
case "$listed" in
    *TestProvider400IsRetryable*) ;;      # TestSiblingCodesAreUnchanged unchecked
```

Rename or drop the sibling test and the gate still passes, quietly verifying
half of what it claims. The sibling is the one proving the patch didn't
disturb the 404/429/503 cases — the regression half.

**Fix:** check both names, or derive the `case` patterns from `$TESTS` so the
two can't drift apart.

### 8. [Low] Two documents still describe qBittorrent as present

- `.claude/config.local.md.example` still lists qBittorrent at
  `NAS_IP:8085`, a `qbit.yourdomain.com` URL, and `/volume1/data/torrents/`
  as the download path. The port is no longer published and the path is now
  `torbox/`.
- `docs/MIGRATION-arr-off-vpn.md:124` claims
  `tests/e2e/vpn-security.spec.ts` "asserts qBittorrent/Prowlarr/SABnzbd/
  FlareSolverr egress IPs match Gluetun's exit IP." The same PR series
  removed `qbittorrent` from that file's `TUNNELED_SERVICES`, so the doc now
  describes a test that no longer exists.

## What holds up

- **The API key is off `argv` everywhere.** All three Python services pass
  credentials to curl through `--config -` on stdin. The key was visible in
  `ps` output on the NAS for both arrs on 2026-09-13 — this is a real fix,
  not a theoretical one.
- **Zip extraction refuses path traversal.** `fetch()` resolves every member
  against the staging root before extracting.
- **Evidence is dated and measured.** Nearly every constant carries the
  observation that set it — the 90-day NNTP ceiling, the 60-calls-per-hour
  limit, the ten-slot `ACTIVE_LIMIT`, the 3-hour debrid staleness threshold.
- **Several traps were caught and written down rather than quietly fixed** —
  the `${APPLY:+--apply}` dry-run bug, the `set -u` unbound `clients`
  variable left behind by the qBittorrent deletion, the `sed` help-range
  off-by-one, the truthy-empty-dict guard in `save_state`.
- **The staging-directory design is grounded in Sonarr's source**, not
  guesswork: dot-directories are not skipped in a watch folder, so staging is
  a sibling, not a subdirectory.
- **The Decypharr fork is disciplined** — pinned to an upstream commit,
  gated by a build-time test that fails against unpatched source, with 13
  bats tests including one asserting compose consumes the exact tag the
  workflow publishes.
- **`docs/TORBOX-API.md` audits itself**, listing seven ways the stack
  under-uses the API. None overlap with the findings above.

## Live state at time of audit

| Signal | Value | Reading |
|---|---|---|
| Jobs in flight | 6 | healthy |
| Jobs past the 24h timeout | 0 | finding 1 is latent, not active |
| NZBs waiting in the outbox | 51 | expected — held back by the 10-slot and 60/hr limits |
| Failures logged | 107 | visibility mechanism working |
| Stale staging directories | 0 | sweep working |
| `rate_limited_until` | none | not currently backed off |

## Suggested order

Findings 1 and 2 matter most: each defeats a guard the surrounding code
explicitly describes as the thing keeping a known failure mode contained, and
both are small fixes. Finding 3 is worth doing in the same pass — it's a
rename away from becoming live. Findings 4–8 are hygiene, and 4 is the one
that would have caught 1 and 2's class of problem earlier.

Nothing here argues against the migration. The architecture change is
well-reasoned, the measurements behind it are real, and the test suite is
green at 780 passing.
