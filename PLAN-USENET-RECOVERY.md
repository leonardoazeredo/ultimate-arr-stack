# Plan: make usenet drain the backlog instead of re-treading it

Status: Phase 0 done (finding below). Phase 1 shipped and live: `--report-failures`
is enabled in `scripts/usenet-blackhole.service`, and reporting was verified on
the NAS on 2026-09-17, where the running service's log shows the repeating
`Failure reporting: ON (POST /api/v3/history/failed)` banner across multiple
passes and the state file's ledger holds accepted failure reports. Phase 2 items
3 (the stall rule, `--stall-hours`, default 4) and 4 (the in-flight ceiling,
`--max-inflight`, default 0) both shipped. Phase 2 items 1-2 are closed as
unbuildable (finding below). Phase 3's baseline is recorded and the decision is
deliberately deferred (finding below). Plan written 2026-09-15 11:30 BST;
Phase 0 finding added 12:05; closeout findings added 2026-09-17.

Phase 0 was read-only on purpose and stayed that way: no writes to the stack, no
branch, no deploy. Phase 1 is live now, with reporting switched on in the unit
that ships rather than left as a flag on a command line someone has to remember.
The phases below are left as written, with a finding appended to each recording
what the 2026-09-17 measurements settled and what they leave open.

## Where we actually are

Measured 2026-09-15 11:15 BST, NAS on `main`, load 1.73, 16 T free.

| | |
| --- | --- |
| Library | 42 series, 673 episode files; 65 films, 51 with a file |
| Monitored but missing | 3,006 episodes |
| Imports since 16:00 on the 14th | 127 Sonarr + 17 Radarr = 144 |
| Where those 144 came from | `Usenet Blackhole`, all of them. Decypharr: zero |
| Blackhole failures logged | 215 lines covering 100 distinct releases |
| Failure kinds | 211 `aborted, cannot be completed`, 4 `unrar exit 3` checksum |
| Sonarr blocklist | 7,327 entries. Radarr: 9 |
| Queues | Sonarr 3 (all Radarr's Star Wars, unknown items), Radarr 4 |
| In flight | 9 jobs, oldest 21.2 h, `--timeout-hours` is 24 |
| TorBox ceilings | 10 concurrent usenet, 60 creates/hour, 3 h link window |

Two facts carry the whole plan.

The first is that usenet is now the only thing feeding the library. Every import
in the last 19 hours came through the blackhole. That is a long way from the
91 grabs to 1 import we started with, so the blackhole works.

The second is the ratio. 144 imports against 215 failures, and those 215 are
only 100 distinct releases, so dead releases come back two to five times. The
Sopranos POLiSH batch and Sopranos S04 each failed three times. Sonarr's
blocklist holds 7,327 entries, and `The Sopranos S05E11 ... DUAL BiOMA`, the
release we proved is corrupt at source, is in there 26 times and is still being
grabbed.

## The hypothesis this plan is built on

For a `UsenetBlackhole` client the arr only sees what sits in the watch folder.
The blackhole moves each NZB out of `/nzb` into staging as soon as it submits
it. If that makes the arr's queue item disappear, then:

- the arr's queue never shows the 9 in-flight or the 215 failed
- `queue-cleanup` has nothing to remove and nothing to blocklist
- the episode is still missing, so the next `MissingEpisodeSearch` grabs the
  same release again, and the blackhole fails it again

The evidence is that Sonarr's queue holds 3 items while the blackhole holds 9
in flight and has logged 215 failures. If the arr were tracking its own usenet
downloads, they would be in that queue. They are not.

If that holds, the blackhole is a one-way street: it knows everything, the arr
knows nothing, and nothing in the arr can ever blocklist what the blackhole
already knows is dead.

**Phase 0 exists to prove or kill this before anyone builds on it.** The
opposite is also possible, and it needs a different fix: the arr does see the
failure, blocklists the release, and re-grabs it anyway because the blocklist
entry is keyed on a title that never matches the indexer's. Sonarr holding
7,327 entries while the same title is grabbed 27 times is at least as consistent
with that reading.

## Success criteria

- A release that fails to complete is submitted exactly once, not two to five
  times. Measured as: distinct release names in the failure log equals the
  failure count over a clean 24 h window.
- Submissions that land rise above 50%. Today 144 landed against 215 failures.
- The 3,006 missing episodes converge, rather than the same dead releases
  cycling through a fixed number of slots.
- Nothing that would have worked gets blocklisted. The retryable TorBox answers
  (`429`, `ACTIVE_LIMIT`) keep their current retry behaviour.

## Phase 0 — prove the mechanism

Read-only. No writes to the stack, no branch, no deploy.

### Steps

1. Take three releases from the failure log that failed three times each:
   `the.sopranos.s04e08.1080p.bluray.x264-shortbrehd`,
   `The.Sopranos.S01E08.POLiSH.1080p.WEB.H264-CHOPiN`, and
   `X-Men.Days.of.Future.Past.2014.BluRay.Remux.1080p.AVC.DTS-HD.MA.7.1-HiFi`.

2. For each, pull `GET /api/v3/history?eventType=grabbed&pageSize=250` from
   both arrs and count the grabs whose `sourceTitle` matches. Record the history
   ids, the `downloadId` values, and the timestamps. Three grabs with three
   history ids is the signature of hypothesis A. One grab with three blocklist
   entries is hypothesis B.

3. At a moment when the blackhole has releases in flight, diff the blackhole's
   state file against the arrs' `/api/v3/queue`. Confirm the in-flight releases
   are absent from both queues, and record the result with timestamps.

4. Read `queue-cleanup`'s journal and its state file for the hours the failures
   landed. Establish whether it saw those items at all.

5. Pull the arrs' blocklist entries for the same three titles and note their
   creation times. If entries exist with timestamps between the second and third
   grab, hypothesis B is live and Phase 1 changes shape.

6. Watch one in-flight release for 15 minutes with a 60-second poll of
   `/api/v3/queue`, logging what the arr shows. This is the direct observation
   that settles A against B.

7. `docs/TORBOX-API.md` already confirms a usenet `checkcached` endpoint
   exists (comma-separated hashes, ~100 per call, sub-second per hundred) —
   the open question isn't whether it exists but which hash an NZB maps to,
   which that same doc flags as unresolved. Establish the mapping (submit a
   known release, compare what the usenet-list response reports against what
   `checkcached` expects) before deciding Phase 2.1 is buildable.

### Exit criteria

One of three outcomes confirmed with raw evidence, not inference: history ids
and timestamps for A, blocklist entries predating a re-grab for B, or zero
grabs found for either signature. The third is inconclusive, not a third
hypothesis — before treating it as settling anything, rule out pagination
limits on the `/api/v3/history` call and confirm the arr's history retention
window actually covers the failure window being checked.
Written up as a short finding appended to this file before Phase 1 starts.

### Finding: hypothesis A, confirmed 2026-09-15 11:35 BST

Read-only throughout; nothing on the stack was written. Run against the live
NAS over Tailscale, arr APIs on `:8989` / `:7878`, blackhole state file read
from `/volume1/docker/arr-stack/logs/`.

**History ids and timestamps for A.** All three named releases have three or
four separate grab records and not one failure record against any of them:

| Release | Grabs (history id @ time) |
| --- | --- |
| `the.sopranos.s04e08.1080p.bluray.x264-shortbrehd` | 11545 @ 09-14T14:57:17Z, 11763 @ 09-14T22:55:53Z, 11921 @ 09-15T06:57:04Z |
| `The.Sopranos.S01E08.POLiSH.1080p.WEB.H264-CHOPiN` | 598 @ 09-12T13:37:24Z, 11540 @ 09-14T14:57:07Z, 11766 @ 09-14T22:55:59Z, 11917 @ 09-15T06:56:56Z |
| `X-Men.Days.of.Future.Past.2014.BluRay.Remux.1080p.AVC.DTS-HD.MA.7.1-HiFi` | 57 @ 09-12T23:44:05Z, 172 @ 09-14T14:54:31Z, 208 @ 09-14T22:54:49Z, 216 @ 09-15T06:55:48Z |

Three grabs with three history ids is the A signature. The fourth grab on the
S01E08 and X-Men rows is the arrival of the blackhole itself on 09-14.

**The history call was not the limit.** `/api/v3/history?eventType=grabbed`
answers `400 The value 'grabbed' is not valid` on Sonarr 4.0.19 — `eventType`
is an integer enum there, not a name. The pull was done with
`/api/v3/history/since?date=2026-08-25T00:00:00Z`, which returns every event
unfiltered: 11,646 rows in Sonarr, 198 in Radarr, covering 08-25T20:17Z to
09-15T10:58Z. There is no pagination to rule out and the window covers the
whole failure log. All 227 failure lines fall between 09-14T13:33Z and the
present.

Sonarr's 9,114 `downloadFailed` rows are almost all from the SABnzbd era and
almost all one bulk write: 9,102 of them are dated 09-12, and 8,581 carry the
message `Manually marked as failed` from the blocklisting sweep that day. Two
on the 13th, ten on the 14th. Nothing in that set is a blackhole failure,
which is the point: the arr has never been told about one.

**Not in either queue, watched for fourteen minutes.** The blackhole held
twelve jobs in flight when the observation opened and thirteen when it closed,
polled once a minute throughout; not one of them ever appeared in either arr's
queue. Sonarr's queue held 3 items and Radarr's 4 on every poll, and all seven
are the same three Star Wars releases sitting in the *watch folder* at
`completed / warning` — import-blocked, not downloading, and outside a blackhole
queue read entirely. The thirteenth job (`the.sopranos.s06e08...`, TorBox id
2457134) was submitted at 11:34:15Z, between the last two polls, and is the same
story as the other twelve.

**`queue-cleanup` saw nothing to act on.** Its journal for the hours the
failures landed reports `Queue size: 0 items` for Sonarr and `1 items` for
Radarr on every run, with `No stuck items found`. Its queue read is capped at
`pageSize=50` and it only considers items that are downloading or queued, so
the completed-and-warning records are outside its scope. Either way it removed
nothing, so it blocklisted nothing: every one of the 215 failures went through
the blackhole and past the arr without a trace.

**Blocklist entries predating a re-grab — for B, and the answer is not
quite either.** The S01E08 title has six blocklist entries, all written
09-12T14:21–14:22Z, and it was grabbed again on 09-14 and 09-15. That is
literally "blocklist entries predating a re-grab", but it is not hypothesis B:
B requires the arr to see the failure, blocklist the release, and re-grab it
anyway. Here the arr was told nothing after 09-12, so there was no second
blocklist and no second failure record. The two blocklists that exist are both
from the SABnzbd era, before the blackhole was the usenet path. A seventh
observation points the same way: the s04e08 title, which the blackhole failed
three times, has *zero* blocklist entries, and so does X-Men.

**Outcome.** A. The arr's queue never holds a blackhole item, so
`queue-cleanup` never sees one, never blocklists one, and the next
`MissingEpisodeSearch` grabs the same dead release and the blackhole fails it
again. Phase 1 is the right fix and its shape stands as written.

Two things this changes about the plan's own assumptions, both small:

- Phase 1's design says the resolution should fall back to `data.downloadId`
  from `/api/v3/history/since`. Every grab record in this window has
  `downloadId: null`, including the ones whose release is in flight right now.
  The fallback is harmless but it is not a second path — do not rely on it.
- The dry run's stated job is catching a title mismatch between the NZB name
  and the arr's stored `sourceTitle`. On this data those two strings were
  already identical for every release checked: the NZB filenames in
  `/volume1/data/usenet/blackhole/nzb/` are the history `sourceTitle` plus
  `.nzb`, character for character, on all four examples above. The check is
  still worth the day it costs, because the four examples are the ones that
  happened to be looked at and the interesting cases are the ones where they
  differ.

## Phase 1 — make the blackhole tell the arrs

The main change. Written for hypothesis A, with the variant for B noted at the
end.

### Design

When the blackhole reaches a terminal failure for a release, it resolves that
release to an arr history grab and reports it failed with
`POST /api/v3/history/failed/{historyId}`.

That endpoint is the right one rather than a hand-rolled blocklist call, because
it does three things the arr already knows how to do: marks the grab failed,
writes a blocklist entry keyed the way the arr keys its own, and triggers a
replacement search. Inventing our own blocklist entry means inventing our own
title matching, and title matching is exactly what we would be guessing at.

Resolving the history id means matching the NZB's release name against
`sourceTitle` from `GET /api/v3/history/since?eventType=grabbed`, falling back
to `data.downloadId`. Sonarr and Radarr are both tried; the release belongs to
whichever matches. A match requires an exact title comparison and a grab no
older than seven days.

### Pieces to add

- `scripts/lib/usenet_blackhole.py`: a `report_failure()` function plus a
  reporter seam, so tests can substitute HTTP the way `queue_cleanup.py` does
  with its `ArrApi` class. No new dependency.
- `scripts/usenet-blackhole.sh`: pass `SONARR_API_KEY` and `RADARR_API_KEY`
  through the same way the TorBox key already is. Auth follows
  `queue_cleanup.py`'s `ArrApi` precedent exactly: a query-string
  `?apikey=<key>` parameter, not a header — reuse that convention rather than
  picking a new one.
- State file: record reported history ids so a retry cannot double-report, the
  same shape as `queue-cleanup`'s removal memory.
- A `--report-failures` flag, default off, so the change ships inert and is
  switched on after the dry run below. A `--report-dry-run` mode logs what it
  would report without calling anything.

### What must not happen

Reporting failure must never stop the blackhole. An unreachable arr, a missing
match, or a malformed response gets logged and the pass carries on. The
blackhole's job is moving bytes; telling the arr is bookkeeping.

Retryable answers must not be reported. `RateLimited` and `ActiveLimit` are
transient provider states with their own backoff, and reporting them as failures
would blocklist releases that were never given a chance.

### Testing

- `tests/python/test_usenet_blackhole.py`: matching by `sourceTitle`, the
  no-match path, arr unreachable, the double-report guard, and Sonarr versus
  Radarr routing. Built with a `FailureReporter` seam whose HTTP is a fake, the
  way `queue_cleanup.py`'s `ArrApi` is substituted — none of it needs a socket.
- `tests/usenet-blackhole.bats`: the shell half of the flags — reporting is off
  by default and says so in the banner, both flags reach python when asked for,
  and the arr keys travel in the environment rather than in argv.
- `tests/mutation/corpus/usenet-blackhole.sh`: eight entries, one per guard
  (exact match, case folding, newest-grab, the `grabbed` filter, the date
  window, the ledger write, the ledger read, and the persist-on-report call).
- Each new guard gets proved capable of failing by reintroducing the defect.
  That is what turned up two things reading the code did not: a mutation that
  changed nothing at all because its pattern had stopped matching, and the fact
  that every pre-existing `sed -i` entry in this corpus was silently inert on
  macOS (BSD sed reads the path as the `-i` suffix and fails, which the
  harness's "did the file change" assertion catches as an ERROR rather than a
  false KILLED). Both are fixed: the corpus now uses `sed -i.bak ... && rm -f
  "$F.bak"`, which behaves identically on GNU sed and leaves nothing behind.
  Verified by running all 24 entries locally under bash 5 — bash 3.2 cannot run
  the harness at all, because `lib-mutate.sh` reads `$BASHPID` under `set -u`.
  All 24 kill.

### Rollout

Ship with reporting off. Run `--report-dry-run` for a day; the log must print
the matched `sourceTitle` next to the NZB release name verbatim for each
candidate report, not just "a match was found" — the exact-title comparison
this depends on can pass on a false positive (indexer re-releases with
cosmetic title differences, filesystem-safe normalization the arr applies
before storing `sourceTitle`, case handling), and only a character-for-character
read of both strings side by side catches that before it blocklists a release
that was fine. Only enable reporting once a day's worth of these pairs have
been hand-checked. If any pair doesn't match exactly, the matching rule is
wrong and Phase 1 is not ready.

Rollout done. `--report-failures` is on in `scripts/usenet-blackhole.service`,
verified on the NAS on 2026-09-17: the running service's log shows the
`Failure reporting: ON (POST /api/v3/history/failed)` banner on pass after pass,
and the state file's ledger holds accepted failure reports.

### Variant for hypothesis B

If Phase 0 shows the arr already blocklists and re-grabs anyway, the work moves
from the blackhole to the arr's matching: compare the `sourceTitle` the arr
blocklists against the title the indexer returns for the same release, and find
where they diverge. Phase 1's plumbing is unnecessary in that case, and Phase 2
becomes the whole job.

### What shipped, and the two places it differs from the design above

Both differences are deliberate; neither changes the mechanism.

**The resolution does not use `data.downloadId`.** The design names it as a
fallback. Every grab record in the Phase 0 window carries `downloadId: null`,
including releases in flight at the time, so it is not a second path on this
stack — the exact title comparison against `sourceTitle` is the whole of it. A
fallback that can never fire is worse than none: it reads as a safety net while
providing nothing. If a future arr version starts populating it, that is the
moment to add it back, with a test that shows it firing.

**The ledger is keyed on the arr, the history id AND the outcome**
(`Sonarr:11921:timeout`, `Sonarr:11921:torbox`). The design says "reported
history ids". A bare history id would have been enough for the double-report
guard, but a job that times out and is later reported with TorBox's own answer
is two different facts about one grab, and one key would silently drop the
second. Nothing in the arr cares either way — both end as a failure report on
the same row.

One thing worth knowing about the pass, because it is not obvious from the
design: the ledger is written to disk the moment the arr accepts a report,
rather than at the end of the pass. A crash between the POST and the next
`save_state` would otherwise re-report the same grab on the next pass, and with
the NZB already discarded there is nothing else to stop it. That costs one extra
state write per report, which is a handful of writes a day.

## Phase 2 — stop paying for releases that cannot complete

Items 1-2 depend on Phase 0 step 7. Item 3 (the stall rule) does not depend on
anything above — it has its own already-measured trigger (a 21.2h job about to
hit the 24h cap) and can ship on its own timeline, ahead of Phase 0/1 if
useful.

1. If TorBox exposes a usenet availability check, use it before spending one of
   the ten slots. A dead release then costs nothing instead of costing an arr
   round trip and a slot.

2. If there is no such check, the abort is a TorBox-side fact learned only by
   submitting, and Phase 1 is what makes it cost once instead of five times.
   Say so plainly rather than building a check that cannot exist.

3. Add a stall rule. The oldest in-flight job is 21.2 hours old with nothing to
   show, and `--timeout-hours` is 24, so it will age out tomorrow morning having
   held a slot the whole time. Proposal: `--stall-hours`, default 4, failing a
   job whose reported progress has not moved across that many passes. The 24 h
   bound stays for genuinely large releases that are still moving.

4. Cap submissions to what completes. Over the retained window the blackhole
   submitted 50 and fetched 4, and 9 of the 10 slots are held by jobs between 3
   and 21 hours old. Proposal: stop submitting for the pass once in-flight
   reaches a configured ceiling rather than pushing to the provider's 10.
   Measure the fetch rate at 6 and at 10 before keeping this; a ceiling set too
   low would trade wasted slots for idle ones.

### Finding: the pre-flight check cannot be built, 2026-09-17

Measured against the live account's 327 usenet jobs. Phase 0 step 7 asked which
hash an NZB maps to. That question is settled, and the answer closes items 1 and
2 without building anything.

**`checkcached` works given a hash the account already owns.** A `mylist` job's
`hash` is a 32-character MD5-shaped string, and the endpoint returns that
release's name and size for it. The endpoint is not the obstacle.

**No tested derivation computes that hash from a local NZB.** Sixteen candidates
were tested against three NZBs whose names matched a `mylist` entry exactly, each
the MD5 of one input:

1. the raw file bytes
2. the release name
3. the release name plus `.nzb`
4. the file's basename
5. the first segment message-id, bare
6. the first segment message-id, wrapped in angle brackets
7. every segment message-id concatenated in document order, no separator
8. every segment message-id concatenated in sorted order, no separator
9. every segment message-id joined with newlines in original document order
10. the last segment message-id
11. the first `subject` attribute
12. all `subject` attributes concatenated
13. the sorted `<group>` list joined by commas
14. the lowercased release name
15. the file with all whitespace stripped
16. the reported size as a string

None matched: no client-computable derivation was found among the sixteen tried.

**Even with the hash it would not predict completion.** Queried while
`the.sopranos.s04e09...` was in `download_state: processing` and actively
downloading, `checkcached` returned an empty `data` object, the same answer it
gives for a failed job. Across all 327 jobs, `cached` was true for 167 of the 167
that completed and false for the 155 that failed; five jobs were in neither
group. A field collinear with the outcome in both directions is written after the
bytes arrive, not before.

Item 2 is the live branch of that fork, exactly as the plan anticipated: the
abort is a TorBox-side fact learned only by submitting, and Phase 1 is what makes
it cost once rather than three to five times. This closes the question rather
than deferring it. The full evidence is written up in `docs/TORBOX-API.md` under
"Availability is never checked before spending a slot".

## Phase 3 — make the backlog converge

`backlog-search` walks 10 seasons every 4 hours against roughly 205 seasons, so
a full pass takes about 3.3 days.

With Phase 1 in place a dead release costs one attempt, and a pass stops
re-treading ground it already covered. Until that is true, raising the walker's
limit multiplies waste rather than progress. So: re-measure after Phase 1, then
decide whether the walker needs to move at all.

One separate question belongs here. Older content is where usenet retention runs
out, and it is also where debrid caches do well, because an old torrent is as
available as it ever was while an old usenet post is gone after about 90 days.
Routing old releases to Decypharr may be the better answer for the tail of the
backlog. That needs its own diagnosis first, since Decypharr imported nothing
overnight and nobody has established why.

Phase 4 (the live download view) and Phase 5 (unrelated housekeeping) are not
part of this plan — neither is load-bearing for the retry-storm this plan
exists to fix, and bundling them here muddied when "this plan" is actually
done. Moved to `PLAN-USENET-RECOVERY-FOLLOWUPS.md`.

### Finding: baseline recorded, no action taken, 2026-09-17

Sonarr's monitored-missing count was 3,006 when this plan was written on
2026-09-15 and 2,964 on 2026-09-17. The 42-episode drop is not convergence.
Failure reporting only went live on 2026-09-17, so no window has yet elapsed in
which a dead release costs one attempt instead of several, and the plan's own
instruction is to re-measure after Phase 1 rather than before it.

`backlog-search.sh` still walks `DEFAULT_LIMIT=10` seasons every four hours
against roughly 207 seasons now (205 when this section was written), about 3.3
days for a full pass, unchanged. Raising the walker's limit stays explicitly
deferred.

2,964 at 2026-09-17 is the baseline to measure the next reading against. Take
that reading no sooner than a week of reporting being live, so the two cover a
like-for-like window; the risk section below warns against reading a quiet window
as a healthy one.

## Sequencing

Phase 0 gates everything; it is read-only and cheap and it decides which of two
different fixes is the right one.

Phase 1 is the highest-value change and the one that stops the bleeding.

Phase 2 depends on step 7 of Phase 0 and works alongside Phase 1.

Phase 3 waits for 1 and 2, because measuring convergence before failures cost
one attempt each is measuring noise.

## Delivery

Per the repo's rules, and not negotiable for any phase that touches code:

- Feature branch, never a commit to `main`; `main` is protected and
  `enforce_admins` is on.
- Push the branch, `./scripts/sync-nas.sh`, verify on the NAS, then PR. Four
  required checks: bats suite, mutation guards for the change, supply chain
  (trivy and sbom), workflow and terraform lint.
- Squash merge, then `git fetch origin main && git checkout main && git merge
  --ff-only origin/main`, then `./scripts/sync-nas.sh` again.
- Never pass `--remove-orphans`; recreate a service only through the compose
  file that defines it.
- Anything driving a real operational script goes through
  `tests/helpers/stubs.bash`.
- Grep `tests/mutation/corpus/` for an anchor before editing the line it points
  at. The corpus inertness check skips on BSD sed, so a broken anchor is
  invisible locally and only surfaces in CI.
- `lens_diagnostics mode=all` before calling anything done.

Baselines to compare against, both with known pre-existing failures: bats 735
executed, 20 skipped, 27 failed; pytest 356 passed, 2 failed, both confirmed
failing on a pristine tree.

## Rollback

Phases 1 through 3 add flags whose defaults reproduce today's behaviour, so
turning each one off restores the current state exactly. None of them touch
compose files, so rollback is `git revert` plus a re-sync, with no containers to
recreate and no volumes to restore.

Phase 1's reported-history-ids ledger is a persistent state file, not code — a
`git revert` doesn't touch it. Wipe it explicitly as part of rollback, or
accept in writing that already-reported ids stay suppressed until it's
cleared by hand; don't assume the revert alone restores exact prior state.

## Risks

A wrong history match marks an unrelated grab as failed and blocklists a release
that was fine. The dry run, the exact title comparison, the seven-day window,
and the reported-id ledger all exist to make that unlikely, and the dry run is
the check that it worked.

Blocklisting a release that would have worked. Only terminal failures are
reported; the retryable provider answers keep their current handling.

A ceiling on in-flight trades wasted slots for idle ones. Measure before
keeping it.

Reading a quiet window as a healthy one. The blackhole is bursty and was idle
after 07:32 today. Compare like-for-like windows of at least four hours.

Owner questions unrelated to the retry-storm mechanism (Sopranos audio track,
Star Wars import-blocked triage, Decypharr's future) moved to
`PLAN-USENET-RECOVERY-FOLLOWUPS.md` — they don't belong in this plan's exit
criteria.
