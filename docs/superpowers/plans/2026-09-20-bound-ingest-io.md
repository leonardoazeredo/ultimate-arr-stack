# Bound the usenet ingest's local I/O Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpower-subagent-driven-development (recommended) or superpower-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop one admitted blackhole pass from turning a standing backlog into hours of local disk I/O, and stop the arr outbox from refilling faster than that pass can drain it.

**Architecture:** Two changes, at the two ends of the same pipe. At the outflow, the fetch set is sliced to a single round of `FETCH_WORKERS` releases, so a pass is bounded by construction rather than by a threshold sampled before it starts. At the inflow, a new shared guard lets the two request producers stand down while the outbox is deep. Nothing new is added to the systemd unit, so this ships with `./scripts/sync-nas.sh` alone — no unit copy, no `daemon-reload`, no container rebuild.

**Tech Stack:** Python 3 (stdlib only, at `scripts/lib/usenet_blackhole.py`), Bash 3.2-compatible shell, bats-core + bats-assert, pytest via a containerised toolkit, systemd user units.

**Spec:** There is no separate spec document. The requirement source is the incident already recorded in `docs/NAS-LOAD-INCIDENT-2026-09-18.md` plus its recurrence on 2026-09-20. The measurements this plan is sized against are reproduced verbatim in **Evidence** below. `docs/superpowers/plans/2026-09-19-nas-load-protection.md` is the plan that produced the guards this one corrects; read it to understand what was tried, but do not treat its sizing arguments as sound — the numbers that refute them are in **Evidence**.

---

## Evidence

Measured on the NAS on 2026-09-20, mostly between 21:00 and 22:10 BST. Do not re-derive these from scratch and do not round them. Where a figure was taken by another agent working the same box, the source is named.

| Measurement | Value | Source |
| --- | --- | --- |
| Jobs in the state file at 21:22:32 | 24 total, **21 already `complete`** | `logs/usenet-blackhole-state.json` |
| What `--max-inflight 6` actually compared | **3** — `sum(1 for j in jobs if not j.get("complete"))` | `scripts/lib/usenet_blackhole.py:882` |
| Fetch set that pass | **21 releases**, 3 at a time | `usenet_blackhole.py:1423-1425` |
| `in-flight cap reached` in the whole pass log | **0 times**, across 1,281 lines and 72 passes | `logs/usenet-blackhole.log` |
| Longest pass that day | **53m12s** | `journalctl --user -u usenet-blackhole.service` |
| PSI gate: skipped, skipped, then admitted | 58.05% (21:08:02), 27.33% (21:10:02), admitted 21:12:30 | `logs/usenet-blackhole.log` |
| Load after that admission | 8.47 → **50.18** in 12 minutes; io full avg10 → **81.91%** | `/proc/loadavg`, `/proc/pressure/io` |
| Stall one minute after the ingest was killed | io full avg10 still **74.41%** at load 39.02 | 21:26:08 |
| Write amplification of one release | 33.19 GB `payload.zip` written, extracted, RAR-unpacked, to deliver ~3.8 GB | live `/proc/<pid>/io`, staging `du` |
| Pool write amplification | 86.22 GB logical → **170.6 GB** at the platter (RAID1; metadata is DUP on top) | `/proc/diskstats` |
| Outbox depth across one day | 488 (09-18 reboot) → 572 (21:17) → **588** (21:56) | `ls data/usenet/blackhole/nzb \| wc -l` |
| Producers' offer rate vs drain rate | ~72 NZBs/h offered; drain ceiling ~24/h at 3 workers | `logs/stremio-library-sync.log`, `logs/backlog-search.log` |
| Releases owed local I/O at 21:22 | 21, of which 4 had complete `payload.zip` already staged (33.19 / 27.59 / 12.10 / 9.04 GB) | `du -s` per staging dir |
| Idle baseline with the ingest stopped | io full avg10 median **~1.0%**, max 10.34% | 180 × 1 Hz samples, 22:44–22:47 |
| Pool ceiling, measured | 252–253 MB/s sequential read (O_DIRECT); random 4 KiB **16.9 ms p50 ≈ 56 IOPS at QD1** | `dd iflag=direct`, timed reads |
| Whole-boot average pool load | 19.47 MB/s write, 9.85 MB/s read over 6,491 s | cgroup `io.stat` on `dm-0` |
| Largest single writer over that boot | **decypharr, 67.07%** of pool writes (84.77 GB) — not the ingest, and not guarded | cgroup `io.stat` on `dm-0` |
| btrfs metadata | DUP **4.58 of 5.00 GiB used (91.5%)**, ~433 MiB free | `btrfs filesystem df /volume1` |
| btrfs commit | `max_commit_ms` **38,952**; 11.9% of boot inside `btrfs_commit_transaction` vs a healthy 2 ms | `/sys/fs/btrfs/*/commit_stats` |
| Re-entry after boot | `arr-stack-user-timers.service` armed `usenet-blackhole.timer` **29 seconds** after boot | `journalctl --user` |

**Two claims this plan deliberately does not build on.** An earlier pass of the same investigation attributed the stall to a Time Machine backup session; boot-wide, `smbd.service` wrote 887 MB, **0.70%** of pool writes, and the window shares that supported it were selection on a peak. A second attributed the failure to the gate's 20% threshold being inside the idle noise band; the measured idle median is **~1.0%**, so 20 is above the ordinary range and the gate's own log shows it discriminating at 22.76, 27.33 and 36.02%. Neither claim is load-bearing here. If you find yourself re-deriving either, stop.

**What remains genuinely unverified, and is not settled by this plan:** whether three concurrent fetches are better or worse than one on this pool. The evidence is a single confounded observation (21 releases, a flapping gate, a Time Machine client, and Docker churn all at once). Task 5 records the measurement that settles it. Until that runs, this plan bounds the number of rounds, not the width of a round, and says so rather than pretending otherwise.

---

## Global Constraints

- The test entry point is `./tests/run-tests.sh`, never `npm test`. `npm` does not exist on pi1 or on the NAS.
- Python tests run through `./tests/toolkit/pytest.sh`, which exits **77** (never 0) when Docker is unavailable. A single file: `./tests/toolkit/pytest.sh tests/python/test_usenet_blackhole.py`.
- One bats file: `./tests/run-tests.sh tests/lib-queue-high-water.bats`.
- Every new or changed guard needs an entry in `tests/mutation/corpus/`, and `./tests/mutation/run-mutations.sh -k <name>` must show the named test going red against it. A guard that cannot fail is worse than no guard.
- Two hand-maintained inventories fail CI when a new file appears and they are not updated. Adding `scripts/lib/queue_high_water.sh` requires a line in **both** `CONTRIBUTING.md`'s `SCRIPTS-TREE-ORACLE` block and `tests/mutation/README.md`'s `NO-SWEEP-ORACLE` block. Both are asserted by `tests/shellcheck.bats`; read the failure message, it tells you which direction is stale.
- Shell scripts must stay compatible with bash 3.2 (`/bin/bash` on macOS): expand possibly-empty arrays as `${arr[@]+"${arr[@]}"}` under `set -u`.
- No change reaches `main` before it is verified on the NAS. `main` is protected; land work through a PR. The order is: branch → `./scripts/sync-nas.sh` → verify on the NAS → PR to `main` → sync `main`.
- Every code change gets a new commit. Do not batch tasks into one commit.
- **Do not restart, re-arm, or reboot the NAS ingest while executing this plan.** As of writing, `usenet-blackhole.timer` is held down only by a hand-run `systemctl --user stop`, and `arr-stack-user-timers.service` re-arms it 29 seconds after any boot. Staging holds 113.47 GB and 21 releases are owed local I/O; the first pass after an unplanned boot reproduces the incident. See Task 5.
- Never pass `--remove-orphans` to any `docker compose` command on the NAS.

---

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `scripts/lib/usenet_blackhole.py` | The pass: submit, poll, fetch. Owns the fetch-set bound and the summary line. | Modify |
| `tests/python/test_usenet_blackhole.py` | Behavioural tests for that module. | Modify |
| `scripts/lib/queue_high_water.sh` | New. Counts the arr outbox and answers whether a producer should stand down. Sourced, never executed. | Create |
| `tests/lib-queue-high-water.bats` | New. Guards the depth count and the threshold boundary. | Create |
| `scripts/stremio-library-sync.sh` | Turns Stremio additions into Seerr requests. First producer. | Modify |
| `scripts/backlog-search.sh` | Queues a bounded slice of the missing backlog. Second producer. | Modify |
| `tests/stremio-library-sync.bats` | Call-site test for the first producer. | Modify |
| `tests/backlog-search.bats` | Call-site test for the second producer. | Modify |
| `tests/mutation/corpus/usenet-blackhole.sh` | Corpus for the fetch-set bound. | Modify |
| `tests/mutation/corpus/queue-high-water.sh` | New. Corpus for the outbox guard. | Create |
| `CONTRIBUTING.md` | `SCRIPTS-TREE-ORACLE` inventory. | Modify |
| `tests/mutation/README.md` | `NO-SWEEP-ORACLE` inventory. | Modify |
| `docs/MAINTENANCE.md` | New section: how to hold the ingest down, and the NAS-side storage steps that are not repo files. | Modify |
| `docs/NAS-LOAD-INCIDENT-2026-09-18.md` | New section: the recurrence and what it corrected. | Modify |

---

### Task 1: Bound the fetch set to one round

This is the load-bearing change. Everything else in this plan is secondary to it.

`run()` builds the fetch set from every job whose poll status is `complete`. On 2026-09-20 that set was 21 releases, three of them 30–38 GB, fetched 3 at a time for 53 minutes. The operator's ceiling read 3 the whole time, because that ceiling counts jobs TorBox has *not* finished — the opposite population.

**Files:**
- Modify: `scripts/lib/usenet_blackhole.py` (the `to_fetch` assignment inside `run()`; find it with `grep -n 'to_fetch = ' scripts/lib/usenet_blackhole.py`)
- Test: `tests/python/test_usenet_blackhole.py` (append to the `# --- the in-flight ceiling ---` section, or at end of file)
- Modify: `tests/mutation/corpus/usenet-blackhole.sh` (append at end of file)

**Interfaces:**
- Consumes: `FETCH_WORKERS` (module constant, currently `3`, `scripts/lib/usenet_blackhole.py:170`), `results` (list of `(key, name, status)` from `poll()`).
- Produces: `owed` (list of `(key, name)` with status `complete`) and `to_fetch` (that list sliced to `FETCH_WORKERS`) inside `run()`. Task 2 reads `state["jobs"]` after this task's change, not `owed`; no other task depends on these two names.

- [ ] **Step 1: Write the failing test**

Append to `tests/python/test_usenet_blackhole.py`:

```python
def test_a_pass_fetches_one_round_and_leaves_the_rest(tmp_path, monkeypatch):
    # 2026-09-20: one admitted pass pulled 21 releases, three at a time, for
    # 53m12s, while the operator's --max-inflight 6 read 3 -- that ceiling
    # counts jobs TorBox has NOT finished, and the fetch set never consulted
    # it. The fetch set is now one round.
    #
    # Nine jobs, not three. With FETCH_WORKERS jobs the unbounded line fetches
    # them all and this test passes against the defect, which is the exact
    # shape of a guard that cannot fail.
    nzb_dir, watch, state_path, listing = several_jobs(tmp_path, m.FETCH_WORKERS * 3)
    started = []

    def fake_fetch(torbox, key, job, watch_dir, staging_dir, out=print):
        started.append(job["name"])
        out(f"    fetched: {job['name']}")
        return True

    monkeypatch.setattr(m, "fetch", fake_fetch)
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: FakeTorBox(list_result=listing))
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lambda *a: None)

    assert len(started) == m.FETCH_WORKERS
    assert len(m.load_state(state_path)["jobs"]) == m.FETCH_WORKERS * 2
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/toolkit/pytest.sh tests/python/test_usenet_blackhole.py -k one_round`

Expected: FAIL. `assert 9 == 3` — the old line fetches all nine, so `len(started)` is 9, and `len(jobs)` is 0 rather than 6.

- [ ] **Step 3: Write minimal implementation**

In `scripts/lib/usenet_blackhole.py`, inside `run()`, replace:

```python
    fetched = 0
    to_fetch = [(key, name) for key, name, status in results if status == "complete"]
    if to_fetch:
```

with:

```python
    fetched = 0
    # One round, not the whole backlog.
    #
    # `results` carries every job TorBox has finished. On 2026-09-20 that was
    # 21 releases, two of them 30-38 GB, and the pass pulled all of them three
    # at a time for 53m12s while the host went to 81.91% io full-stall. The
    # operator's --max-inflight did not bound this and could not: it counts
    # jobs TorBox has NOT finished, which is the opposite population, and it
    # gates only the submission loop.
    #
    # FETCH_WORKERS is the bound, and it is the right one rather than a new
    # constant. It is already the number of releases this pass can work on at
    # once, so slicing to it makes a pass exactly one round: the pass can no
    # longer outlive, by an order of magnitude, the pressure reading that
    # admitted it. A new --fetch-budget flag would be a second knob for a
    # quantity that already has one.
    #
    # First N by the order `results` arrives in. Not by size or age: sorting
    # would make which releases go first depend on something no test pins, and
    # the remainder is not lost -- those jobs stay `complete` in the state
    # file and the next pass picks them up.
    owed = [(key, name) for key, name, status in results if status == "complete"]
    to_fetch = owed[:FETCH_WORKERS]
    if len(owed) > len(to_fetch):
        out(f"  {len(owed)} releases are ready: fetching {len(to_fetch)} this pass, "
            f"{len(owed) - len(to_fetch)} wait for a later one")
    if to_fetch:
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/toolkit/pytest.sh tests/python/test_usenet_blackhole.py`

Expected: PASS, whole file. If `test_finished_releases_are_fetched_concurrently` or `test_the_fetch_pool_is_bounded` now fail, you sliced further than `FETCH_WORKERS` — check the slice is `[:FETCH_WORKERS]` and not `[:1]`.

- [ ] **Step 5: Add the mutation corpus entry**

Append to `tests/mutation/corpus/usenet-blackhole.sh`:

```bash
# --- the fetch set has no ceiling ------------------------------------------
#
# The ceiling that shipped with PR #101 counts jobs TorBox has NOT finished.
# The local I/O that wedged the host comes from the jobs it HAS finished, and
# that population had no bound at all on 2026-09-20: 21 releases owed local
# I/O while --max-inflight read 3.

mutation usenet-blackhole-fetch-set-unbounded \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "restores the line that let a single admitted pass pull 21 releases, two of them 30-38 GB, three at a time for 53m12s. Measured that day: load went 8.47 -> 50.18 and io full avg10 to 81.91%, and the value the operator's ceiling compared against was 3 because it counts jobs still AT TorBox. The pass cost 86.22 GB logical and 170.6 GB of platter writes to deliver a few GB of media" \
  --apply 'sed -i.bak "s@to_fetch = owed\[:FETCH_WORKERS\]@to_fetch = owed@" "$F" && rm -f "$F.bak"'
```

- [ ] **Step 6: Prove the guard can fail**

Run: `./tests/mutation/run-mutations.sh -k usenet-blackhole-fetch-set-unbounded`

Expected: `KILLED`. `SURVIVED` means the new test does not actually depend on the slice; `ERRORED` means the `--apply` pattern stopped matching, which is the message that says update the corpus entry rather than delete it.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/usenet_blackhole.py tests/python/test_usenet_blackhole.py \
        tests/mutation/corpus/usenet-blackhole.sh
git commit -m "fix(usenet): bound a pass to one round of fetches

A pass fetched every release TorBox had finished. On 2026-09-20 that was 21
releases, two of them 30-38 GB, pulled three at a time for 53m12s while the
host went to 81.91% io full-stall at load 50. --max-inflight did not bound it
and could not: it counts jobs TorBox has NOT finished, so at the moment the
local I/O began the guard's reading fell from 24 to 3.

Slicing the fetch set to FETCH_WORKERS makes a pass exactly one round, so it
can no longer outlive the pressure reading that admitted it by an order of
magnitude."
```

---

### Task 2: Stop the pass summary calling three numbers "in flight"

On 2026-09-20 the pass log printed `still in flight 24` while the ceiling compared `3`. Both are labelled in flight; they are different quantities (jobs in the state file, versus jobs still holding a TorBox slot). That ambiguity cost real time in the investigation, because 24 against a limit of 6 reads as a cap that is not working.

**Files:**
- Modify: `scripts/lib/usenet_blackhole.py` (the final `out(...)` in `run()`; `grep -n 'still in flight' scripts/lib/usenet_blackhole.py`)
- Test: `tests/python/test_usenet_blackhole.py` (append)

**Interfaces:**
- Consumes: `state["jobs"]`, each entry a dict with an optional `"complete": True` set by `poll()`.
- Produces: nothing at the code level. The deliverable is a summary line naming `outstanding`, `owed local I/O` and `still at TorBox` separately.

- [ ] **Step 1: Write the failing test**

Append to `tests/python/test_usenet_blackhole.py`:

```python
def test_the_summary_names_the_three_numbers_separately(tmp_path, monkeypatch):
    # "still in flight 24" next to a ceiling of 6 reads as a broken cap. It is
    # not: 24 is the state file, 3 is the subset still holding a TorBox slot,
    # and the I/O comes from a third count again -- finished at TorBox and not
    # yet fetched. One word for three quantities is what made this look like a
    # cap failure on 2026-09-20.
    nzb_dir, watch, state_path, listing = several_jobs(tmp_path, m.FETCH_WORKERS + 2)
    lines = []

    monkeypatch.setattr(m, "fetch", lambda *a, **k: True)
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: FakeTorBox(list_result=listing))
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lines.append)

    summary = [l for l in lines if l.strip().startswith("submitted ")][-1]
    assert "outstanding 2" in summary
    assert "2 owed local I/O" in summary
    assert "0 still at TorBox" in summary
    assert "still in flight" not in summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/toolkit/pytest.sh tests/python/test_usenet_blackhole.py -k three_numbers`

Expected: FAIL at `assert "outstanding 2" in summary`. The old line reads `submitted 0, fetched 3, still in flight 2`.

- [ ] **Step 3: Write minimal implementation**

In `scripts/lib/usenet_blackhole.py`, inside `run()`, replace:

```python
    out(f"  submitted {submitted}, fetched {fetched}, still in flight {len(state['jobs'])}")
```

with:

```python
    # Three counts, three names. `outstanding` is the state file; `at_torbox`
    # is the subset still holding one of TorBox's ten slots, which is the only
    # number --max-inflight compares against; and the remainder is owed local
    # I/O, which is what actually reaches the disks. Calling all three "in
    # flight" is what made a working ceiling read as a broken one.
    outstanding = len(state["jobs"])
    at_torbox = sum(1 for j in state["jobs"].values() if not j.get("complete"))
    out(f"  submitted {submitted}, fetched {fetched}, outstanding {outstanding} "
        f"({outstanding - at_torbox} owed local I/O, {at_torbox} still at TorBox)")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/toolkit/pytest.sh tests/python/test_usenet_blackhole.py`

Expected: PASS, whole file.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/usenet_blackhole.py tests/python/test_usenet_blackhole.py
git commit -m "fix(usenet): name the three counts the pass summary conflates

'still in flight 24' sat beside a ceiling of 6 on 2026-09-20 and read as a
cap that was not working. It was: 24 is the state file, 3 is the subset still
holding a TorBox slot, and the disk I/O comes from a third count -- finished
at TorBox and not yet fetched. Say which is which."
```

---

### Task 3: The outbox high-water guard

`usenet-blackhole.sh` owns the drain. The request producers own the inflow, and nothing in the stack connects them: `scripts/stremio-library-sync.sh` adds up to 3 Seerr requests every 10 minutes and `scripts/backlog-search.sh` queues a slice of 4,614 missing episodes every 4 hours, while the blackhole drains at a measured ceiling of about 24 releases an hour. The queue went 488 → 572 → 588 across a day in which the pressure gate was refusing passes, which is the point: skipping a pass takes the drain to zero and leaves the producers running.

This task builds the guard and its own test. Task 4 wires it into the producers.

**Files:**
- Create: `scripts/lib/queue_high_water.sh`
- Create: `tests/lib-queue-high-water.bats`
- Modify: `CONTRIBUTING.md` (inside the `SCRIPTS-TREE-ORACLE` block — see Step 4)
- Modify: `tests/mutation/README.md` (inside the `NO-SWEEP-ORACLE` block — see Step 5)
- Create: `tests/mutation/corpus/queue-high-water.sh`

**Interfaces:**
- Consumes: nothing.
- Produces, for Task 4:
  - `QUEUE_HIGH_WATER` — shell variable, default `50`, overridable from the environment.
  - `outbox_depth DIR` — prints the count of `*.nzb` files directly in `DIR` as a bare integer; prints `0` when `DIR` is empty, unset, or not a directory. Never fails.
  - `outbox_over_high_water DIR` — returns `0` when the depth is at or above `QUEUE_HIGH_WATER`, non-zero otherwise.

- [ ] **Step 1: Write the guard**

Create `scripts/lib/queue_high_water.sh`:

```bash
#!/bin/bash
# A high-water mark on the arrs' usenet outbox.
#
# The outbox is a filesystem handshake: the arr writes an .nzb into its
# nzbFolder when it grabs a release, and scripts/usenet-blackhole.sh moves the
# finished download into the watchFolder the arr polls. Nothing paces the
# writing side, and the reading side has a measured ceiling -- about 24
# releases an hour at FETCH_WORKERS=3 -- so a producer that offers 72 an hour
# builds a queue that can only be discharged by a burst.
#
# Measured 2026-09-20: the outbox went 488 -> 572 -> 588 across one day, in a
# stretch where the pressure gate was refusing passes. Every NZB in it becomes
# local I/O the moment the gate opens, and each release costs a large multiple
# of its delivered size in platter writes -- a 33.19 GB payload writing,
# extracting and unpacking to deliver a few GB.
#
# Sourced, never executed. Two callers today:
#   scripts/stremio-library-sync.sh   (up to 3 requests every 10 minutes)
#   scripts/backlog-search.sh         (a 4-hourly slice of the missing backlog)
#
# Nothing here deletes or moves an NZB. The outbox is the arrs' own work queue
# and clearing it is not a producer's business.

# shellcheck shell=bash

QUEUE_HIGH_WATER="${QUEUE_HIGH_WATER:-50}"

# Number of .nzb files directly in the outbox, or 0 when there is no such
# directory.
#
# `-maxdepth 1` and `-type f` on purpose. The arr writes flat files into this
# folder, and the alternative -- walking a 3.3 TB pool to answer "how deep is
# the queue" -- is the same shape of read this guard exists to prevent. A
# missing directory is 0 and not an error: a stack that has never run has no
# outbox, and a producer that refuses to start because of it has invented a
# new failure.
outbox_depth() {
  local dir="${1-}"
  [[ -n "$dir" && -d "$dir" ]] || { printf '0'; return 0; }
  find "$dir" -maxdepth 1 -type f -name '*.nzb' 2>/dev/null | wc -l | tr -d ' '
}

# 0 (true) when a producer should stand down for this pass.
#
# One threshold, no hysteresis, and that is deliberate. A two-sided check --
# stand down above the mark, resume below a lower one -- needs somewhere to
# remember which side it is on, and a timer-driven script has nowhere durable
# to keep that: every pass starts from nothing, so the lower mark could never
# fire. One threshold bounded by the mark is the whole mechanism, and it is
# honest about what is enforced.
outbox_over_high_water() {
  local depth
  depth="$(outbox_depth "${1-}")"
  [[ "$depth" -ge "$QUEUE_HIGH_WATER" ]]
}
```

- [ ] **Step 2: Write the test**

Create `tests/lib-queue-high-water.bats`:

```bash
#!/usr/bin/env bats
# scripts/lib/queue_high_water.sh -- the outbox depth count and its threshold.
#
# The guard is three lines of shell, and the two things that can go wrong in it
# are both invisible on a quiet box: a count that includes files the arr did
# not write, and a threshold that trips one file late. The first over-reports
# the queue and stops a healthy stack; the second is one more pass of inflow
# than the mark allows, which on this ingest is another 40 GB of local I/O.

setup() {
    load helpers/setup
    LIB="$REPO_ROOT/scripts/lib/queue_high_water.sh"
    # shellcheck source=scripts/lib/queue_high_water.sh
    . "$LIB"
    OUTBOX="$BATS_TEST_TMPDIR/nzb"
    mkdir -p "$OUTBOX"
}

# `$1` NZBs in the outbox, named the way the arr names them.
seed_outbox() {
    local i
    for ((i = 0; i < $1; i++)); do
        : > "$OUTBOX/Rel-$i-GRP.nzb"
    done
}

@test "queue-high-water: an empty outbox is depth zero and under the mark" {
    run outbox_depth "$OUTBOX"
    [ "$output" = "0" ]
    run outbox_over_high_water "$OUTBOX"
    [ "$status" -ne 0 ]
}

@test "queue-high-water: a missing outbox reads as zero, not as an error" {
    # A stack that has never run has no outbox. A guard that treats that as a
    # failure stops a first run, which is the opposite of what a queue-depth
    # check is for.
    run outbox_depth "$BATS_TEST_TMPDIR/nope"
    [ "$output" = "0" ]
    run outbox_over_high_water "$BATS_TEST_TMPDIR/nope"
    [ "$status" -ne 0 ]
}

@test "queue-high-water: only .nzb files count" {
    # The arr writes its NZB atomically, but its own temp names and anything an
    # operator drops in the folder are not queue depth. Counting them makes the
    # guard trip early, which stops a healthy stack for no reason.
    seed_outbox 2
    : > "$OUTBOX/Rel-9-GRP.nzb.partial"
    : > "$OUTBOX/notes.txt"
    mkdir -p "$OUTBOX/a-directory.nzb"
    run outbox_depth "$OUTBOX"
    [ "$output" = "2" ]
}

@test "queue-high-water: at the mark is over it" {
    # >= and not >. At the mark the producer is already one pass behind what
    # the drain can clear, and the failure this guard exists to prevent is the
    # queue growing while the drain is stopped -- so the boundary is where it
    # has to trip, not one file later.
    QUEUE_HIGH_WATER=3
    seed_outbox 2
    run outbox_over_high_water "$OUTBOX"
    [ "$status" -ne 0 ]

    seed_outbox 3
    run outbox_over_high_water "$OUTBOX"
    [ "$status" -eq 0 ]
}

@test "queue-high-water: the mark is 50 unless the environment says otherwise" {
    # The value the producers actually get, in the file, so a change to it is a
    # change someone made on purpose. Five hundred and eighty-eight NZBs is
    # what the queue reached on 2026-09-20; this is what it is allowed to reach.
    [ "$QUEUE_HIGH_WATER" = "50" ]
}
```

- [ ] **Step 3: Run the test**

Run: `./tests/run-tests.sh tests/lib-queue-high-water.bats`

Expected: PASS, 5 tests.

The guard is new rather than a fix to existing behaviour, so this task has no red step of its own — the test and the implementation land together. That is only acceptable because Step 7 proves the test can fail.

- [ ] **Step 4: Update the CONTRIBUTING.md scripts tree**

`tests/shellcheck.bats` derives the list of scripts from disk and fails until `CONTRIBUTING.md` names the new one. Find the `<!-- SCRIPTS-TREE-ORACLE:` block and add one line, in its alphabetical position among the `scripts/lib/` entries:

```
├── queue_high_water.sh           # Refuse a request producer while the NZB outbox is deep
```

Run: `./tests/run-tests.sh tests/shellcheck.bats -f "scripts tree"`

Expected: PASS. If it fails, read the diff it prints — it names exactly which file is missing from the tree and which documented line is now stale.

- [ ] **Step 5: Update the mutation no-sweep list**

The same test asserts a second inventory. The new file is not a generated-sweep target (it has a hand-written corpus entry instead), so it belongs in `tests/mutation/README.md`'s `<!-- NO-SWEEP-ORACLE:` block. Add one line in its sorted position:

```
- `scripts/lib/queue_high_water.sh`
```

Run: `./tests/run-tests.sh tests/shellcheck.bats -f "no-sweep list"`

Expected: PASS.

- [ ] **Step 6: Add the mutation corpus entry**

Create `tests/mutation/corpus/queue-high-water.sh`:

```bash
#!/bin/bash
# Guards added with scripts/lib/queue_high_water.sh, 2026-09-20.
#
# The outbox is the arrs' work queue and the blackhole's backlog. Measured that
# day it reached 588 NZBs while the pressure gate was refusing passes, and
# every one of those becomes local I/O the moment the gate opens -- each
# release costing a large multiple of its delivered size in platter writes.

# --- the boundary trips one file late --------------------------------------

mutation queue-high-water-trips-one-late \
  --file scripts/lib/queue_high_water.sh \
  --bats tests/lib-queue-high-water.bats \
  --test "queue-high-water: at the mark is over it" \
  --why "'>' rather than '>=' admits one more producer pass at exactly the mark. On this ingest one pass is up to 3 Seerr requests from stremio-library-sync or a whole 4-hourly backlog slice, and each requested title becomes an NZB and then a multi-GB local download. The boundary is not cosmetic: at the mark the producer is already one pass behind what the drain clears, so that is the file where it has to stop" \
  --apply 'sed -i.bak "s@-ge \"\$QUEUE_HIGH_WATER\"@-gt \"\$QUEUE_HIGH_WATER\"@" "$F" && rm -f "$F.bak"'

# --- the count includes files the arr did not write ------------------------

mutation queue-high-water-counts-non-nzbs \
  --file scripts/lib/queue_high_water.sh \
  --bats tests/lib-queue-high-water.bats \
  --test "queue-high-water: only .nzb files count" \
  --why "dropping the -name filter counts a partially written file, an operator's note and a stray directory as queue depth. The guard then trips early and stops a stack whose queue is actually below the mark -- a protection that fails closed, on a timer that runs every ten minutes, with the only evidence being a log line saying the outbox is deep when it is not" \
  --apply 'sed -i.bak "s@ -name .\*\.nzb.@@" "$F" && rm -f "$F.bak"'
```

Both `--apply` patterns above were verified by hand against the guard's own text before this plan was executed. Two details are easy to get wrong and were, on the first attempt:

- The trailing `.` matches the closing quote. A second `.` consumed the following space as well, which still matched but read as an accident.
- **No `2` flag.** `s@…@…@2` replaces only the *second* occurrence on a line, so against a line with one occurrence it replaces nothing and the runner reports `ERRORED` rather than `KILLED`. The `@@2` form appears elsewhere in this corpus because those targets had two matches on one line; this one does not.

If a pattern ever stops matching, re-derive it against the file rather than editing the corpus entry blind:

```bash
F=scripts/lib/queue_high_water.sh
F="$PWD/$F" bash -c 'sed "s@ -name .\*\.nzb.@@" "$F"' | grep -n 'find '
```

Then confirm with `./tests/mutation/run-mutations.sh -k queue-high-water-counts-non-nzbs`.

- [ ] **Step 7: Prove both guards can fail**

Run: `./tests/mutation/run-mutations.sh -k queue-high-water`

Expected: two entries, each `KILLED`. `SURVIVED` means the named test does not depend on that line; `ERRORED` next to a pattern message means the `--apply` needs updating rather than the entry deleting.

- [ ] **Step 8: Run the shellcheck and contract checks**

Run: `./tests/run-tests.sh tests/shellcheck.bats tests/mutation-corpus.bats tests/mutation-framework.bats`

Expected: PASS. `mutation-corpus.bats` asserts every `--apply` still changes its target, which is the check that catches a corpus entry silently going stale.

- [ ] **Step 9: Commit**

```bash
git add scripts/lib/queue_high_water.sh tests/lib-queue-high-water.bats \
        tests/mutation/corpus/queue-high-water.sh CONTRIBUTING.md \
        tests/mutation/README.md
git commit -m "feat(queue): a high-water mark on the arrs' NZB outbox

Nothing paces the writing side of the outbox and the reading side has a
measured ceiling of about 24 releases an hour, while the producers offer
about 72. Measured 2026-09-20: 488 -> 572 -> 588 across a day in which the
pressure gate was refusing passes, because skipping a pass takes the drain to
zero and leaves the producers running.

The guard counts *.nzb files directly in the outbox and answers whether a
producer should stand down. It deletes nothing -- the outbox is the arrs'
own work queue."
```

---

### Task 4: Wire the guard into both producers

The value of Task 3 is entirely in these two call sites. A guard nothing calls is the same as no guard.

Both producers already source `scripts/lib/env-file.sh` and resolve `NAS_STACK_DIR`, so each can read `MEDIA_ROOT` from `.env` the same way `scripts/usenet-blackhole.sh:81-83` does.

**Files:**
- Modify: `scripts/stremio-library-sync.sh`
- Modify: `scripts/backlog-search.sh`
- Test: `tests/stremio-library-sync.bats` (append)
- Test: `tests/backlog-search.bats` (append)

**Interfaces:**
- Consumes: `outbox_depth` and `outbox_over_high_water` from `scripts/lib/queue_high_water.sh` (Task 3); `env_value` from `scripts/lib/env-file.sh`, already sourced by both files.
- Produces: nothing at the code level. The deliverable is two producers that exit `0` without doing work while the outbox is at or above the mark, and say so on stdout.

- [ ] **Step 1: Write the failing test for the first producer**

Append to `tests/stremio-library-sync.bats`:

```bash
@test "stremio-library-sync: a deep outbox stands the pass down" {
    # The sync adds requests; the blackhole drains them. Nothing connected the
    # two until 2026-09-20, when the outbox reached 588 while the pressure gate
    # was refusing passes -- the producers kept writing while the drain was
    # stopped, and every NZB in the queue becomes a multi-GB local download the
    # moment the gate opens.
    #
    # The key checks come first in the script and the queue check after them, so
    # this fixture has to set both keys or it would exit on the key error and
    # pass against a guard that was never reached.
    printf 'STREMIO_AUTH_KEY=k\nSEERR_API_KEY=k\nMEDIA_ROOT=%s/media\n' "$WORK" > "$ENV"
    mkdir -p "$WORK/media/usenet/blackhole/nzb"
    local i
    for ((i = 0; i < 50; i++)); do
        : > "$WORK/media/usenet/blackhole/nzb/Rel-$i-GRP.nzb"
    done

    run "$RUN" --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"Outbox: 50 NZBs waiting"* ]]
    [[ "$output" == *"skipping this pass"* ]]
}

@test "stremio-library-sync: a shallow outbox does not stand the pass down" {
    # The boundary's other side, in the call site rather than in the guard. A
    # check that stands down unconditionally would pass the test above.
    printf 'STREMIO_AUTH_KEY=k\nSEERR_API_KEY=k\nMEDIA_ROOT=%s/media\n' "$WORK" > "$ENV"
    mkdir -p "$WORK/media/usenet/blackhole/nzb"
    : > "$WORK/media/usenet/blackhole/nzb/Rel-0-GRP.nzb"

    run "$RUN" --apply
    [[ "$output" != *"skipping this pass"* ]]
}
```

If `tests/stremio-library-sync.bats`'s `setup()` does not already define `$WORK`, `$ENV` and `$RUN`, read the existing setup block and use its names — do not rename its variables.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./tests/run-tests.sh tests/stremio-library-sync.bats -f "deep outbox"`

Expected: FAIL at `[[ "$output" == *"Outbox: 50 NZBs waiting"* ]]`. The script has no queue check yet, so it runs the pass and the string never appears.

- [ ] **Step 3: Wire the guard into `stremio-library-sync.sh`**

Source the guard next to the existing `env-file.sh` source (`scripts/stremio-library-sync.sh:54-55`), so both sit together:

```bash
# shellcheck source=scripts/lib/env-file.sh
. "${SCRIPT_DIR}/lib/env-file.sh"
# shellcheck source=scripts/lib/queue_high_water.sh
. "${SCRIPT_DIR}/lib/queue_high_water.sh"
```

Then add the check immediately after the banner's closing `echo "======"` and before `mkdir -p "$NAS_STACK_DIR/logs"`:

```bash
# The requests this pass creates become NZBs, and every NZB becomes local I/O
# for the blackhole. Measured 2026-09-20: the outbox reached 588 while the
# pressure gate was refusing passes, because standing a pass down takes the
# drain to zero and leaves the producers running -- so the queue only grew
# while the host was being protected from it.
#
# Checked in both modes, for the same reason the key checks are: the one thing
# an operator does with a dry run is decide whether applying is safe, and a dry
# run that reports "12 new items" while the outbox is 588 deep answers the
# wrong question.
MEDIA_ROOT_VALUE="$(env_value "$ENV_FILE" MEDIA_ROOT || true)"
NZB_DIR="${USENET_NZB_DIR:-${MEDIA_ROOT_VALUE:-$NAS_STACK_DIR/data}/usenet/blackhole/nzb}"
OUTBOX_NOW="$(outbox_depth "$NZB_DIR")"
if outbox_over_high_water "$NZB_DIR"; then
  echo "Outbox: $OUTBOX_NOW NZBs waiting (mark ${QUEUE_HIGH_WATER}); skipping this pass"
  exit 0
fi
echo "Outbox: $OUTBOX_NOW NZBs waiting (mark ${QUEUE_HIGH_WATER})"
```

- [ ] **Step 4: Run the first producer's tests**

Run: `./tests/run-tests.sh tests/stremio-library-sync.bats`

Expected: PASS, whole file. If an existing test now fails, it is because its fixture writes a `.env` with no `MEDIA_ROOT` and the default path resolved to a directory that does not exist — `outbox_depth` returns `0` there, so the pass should still run. A failure means the new check was placed above the banner, before `$ENV_FILE` is set.

- [ ] **Step 5: Write the failing test for the second producer**

Append to `tests/backlog-search.bats`:

```bash
@test "backlog-search: a deep outbox stands the pass down" {
    # Same coupling as the stremio sync, and a bigger unit of work: this pass
    # queues a whole slice of a backlog the log measured at 4,614 episodes
    # across 71 series against a drain of about 24 releases an hour.
    printf 'MEDIA_ROOT=%s/media\n' "$WORK" >> "$ENV"
    mkdir -p "$WORK/media/usenet/blackhole/nzb"
    local i
    for ((i = 0; i < 50; i++)); do
        : > "$WORK/media/usenet/blackhole/nzb/Rel-$i-GRP.nzb"
    done

    run "$RUN" --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping this pass"* ]]
}
```

Use whatever variable names `tests/backlog-search.bats`'s own `setup()` defines for the environment file and the script path; read it first rather than assuming `$ENV` and `$RUN`.

- [ ] **Step 6: Run it to verify it fails**

Run: `./tests/run-tests.sh tests/backlog-search.bats -f "deep outbox"`

Expected: FAIL. The string never appears.

- [ ] **Step 7: Wire the guard into `backlog-search.sh`**

Source it next to that file's existing `env-file.sh` source (`scripts/backlog-search.sh:77-78`):

```bash
# shellcheck source=scripts/lib/env-file.sh
. "${SCRIPT_DIR}/lib/env-file.sh"
# shellcheck source=scripts/lib/queue_high_water.sh
. "${SCRIPT_DIR}/lib/queue_high_water.sh"
```

Then add the same check immediately after that script's banner block and before its own logging setup. Use the identical four lines from Step 3, adapted to this pass's unit:

```bash
# Queued searches become NZBs, and every NZB becomes local I/O for the
# blackhole. The backlog this walks was measured at 4,614 missing episodes
# across 71 series against a drain of about 24 releases an hour, so a deep
# outbox means this pass is queueing work the host cannot absorb.
MEDIA_ROOT_VALUE="$(env_value "$ENV_FILE" MEDIA_ROOT || true)"
NZB_DIR="${USENET_NZB_DIR:-${MEDIA_ROOT_VALUE:-$NAS_STACK_DIR/data}/usenet/blackhole/nzb}"
OUTBOX_NOW="$(outbox_depth "$NZB_DIR")"
if outbox_over_high_water "$NZB_DIR"; then
  echo "Outbox: $OUTBOX_NOW NZBs waiting (mark ${QUEUE_HIGH_WATER}); skipping this pass"
  exit 0
fi
echo "Outbox: $OUTBOX_NOW NZBs waiting (mark ${QUEUE_HIGH_WATER})"
```

- [ ] **Step 8: Run both files and shellcheck**

Run: `./tests/run-tests.sh tests/backlog-search.bats tests/stremio-library-sync.bats tests/shellcheck.bats`

Expected: PASS. Shellcheck is in the list because both files now source a new library, and the `# shellcheck source=` directive on the source line is what keeps `shellcheck -S error` quiet about functions it cannot otherwise resolve.

- [ ] **Step 9: Add a mutation entry for the call site**

Append to `tests/mutation/corpus/stremio-library-sync.sh`:

```bash
# --- the queue check is not reached ----------------------------------------

mutation stremio-sync-queue-check-removed \
  --file scripts/stremio-library-sync.sh \
  --bats tests/stremio-library-sync.bats \
  --test "stremio-library-sync: a deep outbox stands the pass down" \
  --why "the guard is a library and a call site, and only the call site is load-bearing. With the check gone the sync keeps requesting while the outbox is 588 deep and the drain is stopped -- the arrangement that built the backlog which wedged the host on 2026-09-20. Nothing else in the suite notices, because the library's own tests still pass" \
  --apply 'sed -i.bak "/^if outbox_over_high_water /d" "$F" && rm -f "$F.bak"'
```

- [ ] **Step 10: Prove it can fail**

Run: `./tests/mutation/run-mutations.sh -k stremio-sync-queue-check-removed`

Expected: `KILLED`.

- [ ] **Step 11: Commit**

```bash
git add scripts/stremio-library-sync.sh scripts/backlog-search.sh \
        tests/stremio-library-sync.bats tests/backlog-search.bats \
        tests/mutation/corpus/stremio-library-sync.sh
git commit -m "feat(queue): stand the request producers down on a deep outbox

Both passes create work the blackhole then has to move onto the same pool the
rest of the stack reads from, and neither knew how deep the queue was. On
2026-09-20 the outbox reached 588 while the pressure gate was refusing
passes: skipping a pass takes the drain to zero and leaves the producers
running.

Checked in both modes, so a dry run reports the queue depth rather than
twelve new items."
```

---

### Task 5: The runbook, and the NAS-side steps that are not repo files

Three things have nowhere else to live. The hold-down procedure, because the timer is currently held down by a hand-run command that a reboot erases. The measurement that settles whether one fetch stream beats three, because this plan bounds rounds and not width. And the storage steps, which are host configuration on the NAS and deliberately not tracked in this repo — the same ruling the macvlan shim and the UGOS firewall rules are under.

**Files:**
- Modify: `docs/MAINTENANCE.md` (new section, placed after the `## Queue Cleanup` section)
- Modify: `docs/NAS-LOAD-INCIDENT-2026-09-18.md` (new section at end)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. The deliverable is the procedure an operator follows, and the recorded value of the open measurement.

- [ ] **Step 1: Add the hold-down and measurement section to `docs/MAINTENANCE.md`**

Insert after the `## Queue Cleanup` section. The nested fences below are deliberate: the outer four-backtick fence is not part of the document.

````markdown
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
````

- [ ] **Step 2: Check the doc links**

Run: `./tests/run-tests.sh tests/lib-doc-links.bats`

Expected: PASS. The check fails on a link to a file or anchor that does not exist, which is how a section added to one document without the other would be caught.

- [ ] **Step 3: Record the recurrence in the incident document**

Append a new section to `docs/NAS-LOAD-INCIDENT-2026-09-18.md`:

````markdown
## 8. The recurrence of 2026-09-20

The three guards in [§6](#6-what-was-done-about-it) shipped, and the host went
into I/O starvation again. This section records what the second failure
corrected, because §6 argues from numbers that turned out not to bound the
thing they were meant to bound.

**What the guards got right, and kept.** The duc start-up guard never fired a
false scan: `docker logs duc` shows `Host I/O is stalled; skipping the start-up
scan` on every restart, so the 2.9 Tb re-walk is genuinely gone. The pressure
gate's own log shows it discriminating correctly — it skipped at 58.05% and
27.33% and admitted a pass at a valid sub-20 reading. The gate works. It
watches the wrong window.

**What they did not bound.** `--max-inflight 6` counts jobs TorBox has *not*
finished (`scripts/lib/usenet_blackhole.py:882`). The local I/O comes from jobs
it *has* finished. At 21:22:32 the state file held 24 jobs, **21 of them
complete**, so the guard read **3** at the exact moment 21 releases — two of
them 30–38 GB — were owed a local download. The fetch set took all 21
(`usenet_blackhole.py:1423`) with no reference to the ceiling anywhere on that
path, and the string `in-flight cap reached` appears **zero times in 1,281 log
lines across 72 passes**. A guard whose reading falls as the load rises cannot
bound the load.

Consequences measured: one admitted pass ran 53m12s; a second took load from
8.47 to 50.18 and io full avg10 to 81.91% in twelve minutes; one release cost
86.22 GB logical and 170.6 GB of platter writes to deliver a few GB, because
the payload is written, extracted, and then RAR-unpacked before delivery.

**The stall outlives its process.** After the ingest was killed at 21:25:06,
io full avg10 was still 74.41% at load 39.02 a minute later. A stalled box does
not recover when the producer stops; it recovers when the writeback drains and
then only by reboot — four boots in two hours, one of them a hand-run
`sudo reboot`.

**The queue is a ratchet.** 488 NZBs at the 09-18 reboot, 572 at 21:17, 588 at
21:56. Producers offer roughly 72 an hour against a drain ceiling near 24, and
when the gate skips a pass the drain goes to zero while they keep running.

**Two things this investigation corrected in its own first pass.** An active
Time Machine backup was proposed as a co-driver; boot-wide, `smbd.service`
wrote 887 MB, **0.70%** of pool writes, and the shares that supported the claim
were selection on a peak. The gate's 20% threshold was proposed as sitting
inside the idle noise band; the measured idle median is **~1.0%** and the gate
is above it. Neither corrected claim appears in what follows.

**What is still open and was not settled.** The pool was never
bandwidth-saturated: whole-boot averages are 19.47 MB/s of writes and 9.85
MB/s of reads against drives that do 253 MB/s sequential. The failure is
latency and queue depth, not throughput. Random 4 KiB reads cost 16.9 ms at
p50, about 56 IOPS at queue depth 1, and btrfs metadata sits at 91.5%. The
largest single writer over that boot was **decypharr at 67.07% of pool writes**
(84.77 GB) — the torrent path, which no guard in §6 touches, and which has had
no investigation of its own.
````

- [ ] **Step 4: Run the doc and inventory checks**

Run: `./tests/run-tests.sh tests/lib-doc-links.bats tests/shellcheck.bats`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/MAINTENANCE.md docs/NAS-LOAD-INCIDENT-2026-09-18.md
git commit -m "docs: record the 2026-09-20 recurrence and how to hold the ingest down

The timer is held down by a hand-run stop that a reboot erases, and the rearm
unit brings it back 29 seconds after boot. Disabling is the hold that
survives; masking is not, because rearm-user-timers.sh exits 1 on an inactive
timer.

Also records the measurement that settles whether one fetch stream beats
three, and the three NAS-side storage steps -- metadata balance, request-size
mismatch, dirty-page ceiling -- which are host configuration and deliberately
not repo files."
```

---

### Task 6: Verify on the NAS

The repo's rule has no exceptions: nothing reaches `main` before it is confirmed working on the NAS.

**Files:** none. This task produces a verification record, in the PR description.

**Interfaces:**
- Consumes: everything above.
- Produces: a branch confirmed on the NAS, and the PR that lands it.

- [ ] **Step 1: Run the full local suite**

Run: `./tests/run-tests.sh`

Expected: PASS apart from the pre-existing macOS-environmental failures (`bash 3.2` `BASHPID`, BSD `date`/`stat`, missing PyYAML, `sshpass`, no VLAN20 address). Compare failure *names* against the branch base rather than against a count. CI on `ubuntu-latest` is the authoritative run.

- [ ] **Step 2: Run the Python suite**

Run: `./tests/toolkit/pytest.sh`

Expected: PASS. Exit 77 means Docker was unavailable and the tests did not run — that is not a pass, and the run must be repeated somewhere Docker exists.

- [ ] **Step 3: Run the mutation corpus for everything touched**

`run-mutations.sh` takes **one** `-k` filter, not a list: `getopts "k:"` assigns `FILTER="$OPTARG"` on every occurrence, so a repeated `-k` keeps only the last and silently skips the rest. That is the same class of failure this repo's census output exists to prevent — a run that reports success while covering a fraction of what it claims. Invoke it once per filter:

```bash
./tests/mutation/run-mutations.sh -k usenet-blackhole-fetch-set-unbounded
./tests/mutation/run-mutations.sh -k queue-high-water
./tests/mutation/run-mutations.sh -k stremio-sync-queue-check-removed
```

Expected: all four entries across the three runs report `KILLED`, none `SURVIVED`, none `ERRORED`. A run that prints `no mutations ran` and exits 2 means the filter matched nothing — that run proved nothing, whatever its exit status looked like next to the others.

- [ ] **Step 4: Confirm the ingest is still held down before syncing**

Run: `ssh <nas> 'systemctl --user is-enabled usenet-blackhole.timer; systemctl --user is-active usenet-blackhole.timer'`

Expected: `disabled` and `inactive`. If it reads `enabled`, stop and hold it down first using the procedure in Task 5 Step 1. Do not sync onto a box whose ingest can arm itself.

- [ ] **Step 5: Sync the branch and verify the guard on the box**

Run: `./scripts/sync-nas.sh`

Then, on the NAS, confirm the deployed module carries the slice and that a dry run reports the new header without fetching anything:

```bash
ssh <nas> 'grep -n "to_fetch = owed" /volume1/docker/arr-stack/scripts/lib/usenet_blackhole.py'
ssh <nas> '/volume1/docker/arr-stack/scripts/usenet-blackhole.sh 2>&1 | head -8'
```

Expected: the grep matches, and the header reads `outstanding:  24` — not `in flight:    24`.

**The dry run does not print the summary line.** It returns from `run()` before the fetch section (`scripts/lib/usenet_blackhole.py:1352`), so `submitted N, fetched N, outstanding N (…)` appears only on a live `--apply` pass. Check the new wording in Step 6, not here. A dry run that looks like it is missing the summary is behaving correctly, and a future reader who "fixes" that has broken the dry run's guarantee that it touches nothing.

- [ ] **Step 6: Hand-run exactly one pass and watch it**

With the timer still disabled, run one pass and watch it in a second session. Expect **at most 3** fetch completions in that pass's log, and the closing summary to read `outstanding N (N-3 owed local I/O, 0 still at TorBox)` — the wording this plan changed, on the line where it actually prints.

```bash
ssh <nas> '/volume1/docker/arr-stack/scripts/usenet-blackhole.sh --apply --report-failures --max-inflight 6'
```

Abort and revert if the pass fetches a fourth release, or if `io full avg10` stays above 50% for more than two minutes without falling.

- [ ] **Step 7: Re-enable the timer and watch three passes**

Only once Step 6 is clean:

```bash
ssh <nas> 'systemctl --user enable --now usenet-blackhole.timer'
```

Then, across three consecutive passes, check that each fetches at most 3 and that `io full avg10` returns below 20% between them. If it does not, disable the timer again and stop — that is the signal that the bound is not the problem, and that Task 5's open measurement needs running before anything further ships.

- [ ] **Step 8: Land it**

```bash
git push origin <branch>
gh pr create --fill && gh pr merge <n> --squash
git fetch origin main && git checkout main && git merge --ff-only origin/main
./scripts/sync-nas.sh
```

The `--ff-only` merge is the step that fires `post-merge`, and the NAS pulls from `origin`, so an unsynced merge never reaches it.

---

## Self-review

**Spec coverage.** Each measured defect in **Evidence** maps to a task. The fetch set with no ceiling → Task 1. The pass summary conflating three counts → Task 2. The outbox ratchet → Tasks 3 and 4. The hold-down hazard, the open concurrency measurement, and the storage steps → Task 5. Verification on the NAS → Task 6.

**Deliberately out of scope, and why.**

- **`FETCH_WORKERS` itself.** Whether 3 beats 1 on two rotational spindles is unmeasured, and guessing would trade a bounded round for an unbounded guess. Task 5 records the experiment that settles it; the value changes in a follow-up once there is a number.
- **A byte-rate cap via cgroup `io.max`.** Measured blocker: `user@1000.service`'s `cgroup.subtree_control` is `cpu memory pids`, so the `io` controller is not delegated and an `IOWriteBandwidthMax=` on a user unit would be silently inert. Fixing that means a root-side `Delegate=` drop-in on the user manager, which risks every user timer on the box and does not belong in a bundle with a two-line slice.
- **`decypharr`, the largest single writer at 67.07% of pool writes.** It is the torrent path, guarded by nothing, and it has had no investigation of its own. It needs its own plan, not a task appended to this one.
- **Time Machine and the pressure gate's threshold.** Both were raised and both were refuted by measurement. Changing either would be reacting to a claim the evidence does not support.

**Placeholder scan.** No `TBD`, no `TODO`, no "add error handling", no "similar to Task N". Every code step carries the code. The one place a pattern may need adjusting is Task 3 Step 6's second `--apply`, and that step gives the exact command to check it against the file rather than leaving the reader to guess.

**Type and name consistency.** `owed` and `to_fetch` are introduced in Task 1 and used in Task 1 only; Task 2 computes its own `outstanding` and `at_torbox` and does not depend on Task 1's local names. `QUEUE_HIGH_WATER`, `outbox_depth` and `outbox_over_high_water` are defined in Task 3 and called with the same signatures in Task 4. `MEDIA_ROOT_VALUE` and `NZB_DIR` are local to each producer and both files use the same two names. `USENET_NZB_DIR` is the override `scripts/usenet-blackhole.sh:83` already honours, so a test fixture that sets it affects all three scripts consistently.

**Test-code accuracy.** The fixtures used in Tasks 1 and 2 (`several_jobs`, `FakeTorBox(list_result=...)`, `m.run(...)`, and a patched `m.fetch` whose return value `_fetch_one` repacks) are the ones the existing concurrency and cap tests already use, and both new tests size their fixture above `FETCH_WORKERS` specifically so they do not pass against the defect they target.

**One thing to check before starting.** `tests/stremio-library-sync.bats` and `tests/backlog-search.bats` each have their own `setup()` with its own variable names. Task 4 Step 5 says to read that block and use its names rather than the ones written here. Do that — do not rename the existing fixtures to match this plan.
