# NAS load protection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpower-subagent-driven-development (recommended) or superpower-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the usenet ingest path and the duc indexer from driving the NAS into the I/O starvation that wedged every service on it for twelve hours on 2026-09-18.

**Architecture:** Three guards, each at a different point in the chain that produced the incident, plus the incident record itself. The shipped systemd unit caps how many TorBox jobs a pass may hold in flight. The launcher refuses to start a pass at all while the host is already I/O-stalled. The duc container stops re-indexing the whole volume on every restart. Each guard is independently testable and none depends on the others.

**Tech Stack:** Bash 3.2-compatible shell (macOS is a supported host), bats-core + bats-assert, systemd user units, Python 3 (already present), Docker Compose.

**Spec:** This plan has no separate spec document. The requirement source is the incident of 2026-09-18, and the measurements it rests on are reproduced verbatim in the **Evidence** section below. Task 4 exists to make that evidence durable in `docs/`.

---

## Evidence

Everything below was measured on the NAS during or after the incident. These numbers are what the guards are sized against; do not re-derive them from scratch, and do not "round" them.

| Measurement | Value | Source |
| --- | --- | --- |
| Sustained I/O full-stall, incident | 78-81% | `/proc/pressure/io` |
| I/O full-stall, healthy (after reboot) | 1.86% | `/proc/pressure/io` |
| Load average, incident / healthy | 58.55 / 2.43 | `/proc/loadavg` |
| Disk reads vs download throughput | 136 MB/s vs 3 MB/s | `/proc/diskstats` vs `/proc/<pid>/io` |
| Jobs submitted by the blackhole in one hour | 46 | `logs/usenet-blackhole-state.json` |
| Jobs left incomplete | 60 of 64 | same |
| NZBs queued | 531 | `data/usenet/blackhole/nzb/` |
| duc re-index on container start | 2.9 Tb, 842.4K files, 139.8K dirs | `docker logs duc` |
| TorBox concurrent usenet slot limit | 10 | `scripts/lib/usenet_blackhole.py` docstring |
| `FETCH_WORKERS` | 3 | `scripts/lib/usenet_blackhole.py:170` |

## Global Constraints

- The test entry point is `./tests/run-tests.sh`, never `npm test`. `npm` does not exist on pi1 or on the NAS.
- Python tests run through `./tests/toolkit/pytest.sh`, which exits **77** (never 0) when docker is unavailable.
- Every new or changed guard needs an entry in `tests/mutation/corpus/`, and `./tests/mutation/run-mutations.sh` must show the named test going red against it. A guard that cannot fail is worse than no guard.
- Shell scripts must stay compatible with bash 3.2 (`/bin/bash` on macOS): expand possibly-empty arrays as `${arr[@]+"${arr[@]}"}` under `set -u`.
- No change reaches `main` before it is verified on the NAS. `main` is protected; land work through a PR.
- Never pass `--remove-orphans` to any `docker compose` command on the NAS. Recreate a service only via the compose file that defines it.
- The installed copies of the user units under `~/.config/systemd/user/` are plain copies, not symlinks. Copying a changed unit to the NAS is part of the task, not a follow-up.

---

### Task 1: Cap in-flight TorBox jobs in the shipped unit

The script ships `DEFAULT_MAX_INFLIGHT=0` (no ceiling) and takes a flag. That is right for a rollout and wrong as a resting state — the argument the unit's own `--report-failures` comment already makes at length. TorBox refuses the eleventh concurrent usenet download, so a ceiling above 10 bounds nothing and 0 bounds nothing at all. During the incident the pass submitted 46 jobs in one hour with 60 left incomplete, and because a blackhole item never appears in an arr queue, none of that was visible to Sonarr or Radarr.

**Files:**
- Modify: `scripts/usenet-blackhole.service` (the `ExecStart=` line and a comment block above it)
- Modify: `tests/usenet-blackhole.bats` (append a new section at end of file)
- Modify: `tests/mutation/corpus/usenet-blackhole.sh` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing at the code level. The deliverable is a unit whose `ExecStart` passes `--max-inflight 6`, and a test that fails if that number is removed or pushed above 10.

- [ ] **Step 1: Write the failing test**

Append to `tests/usenet-blackhole.bats`:

```bash
# --- the shipped unit ------------------------------------------------------

@test "usenet-blackhole: the shipped unit caps in-flight jobs below TorBox's ten slots" {
    # The script ships the cap inert (0, printed as "off"), which is right for a
    # rollout and wrong as a resting state -- the argument this unit's own
    # --report-failures comment already makes. TorBox refuses the eleventh
    # concurrent usenet download, so a ceiling above 10 bounds nothing, and 0
    # bounds nothing at all: on 2026-09-18 the pass submitted 46 jobs in one
    # hour and left 60 incomplete while neither arr could see any of them.
    local unit="$REPO_ROOT/scripts/usenet-blackhole.service"
    local exec_line value
    exec_line="$(grep -m1 '^ExecStart=' "$unit")"
    if [[ ! "$exec_line" =~ --max-inflight[= ]([0-9]+) ]]; then
        fail "ExecStart does not pass --max-inflight: $exec_line"
    fi
    value="${BASH_REMATCH[1]}"
    if (( value < 1 )); then
        fail "--max-inflight $value is no ceiling at all"
    fi
    if (( value > 10 )); then
        fail "--max-inflight $value is above TorBox's ten concurrent slots"
    fi
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./tests/run-tests.sh tests/usenet-blackhole.bats`

Expected: FAIL on `usenet-blackhole: the shipped unit caps in-flight jobs below TorBox's ten slots`, with output `ExecStart does not pass --max-inflight: ExecStart=/bin/bash -c 'mkdir -p ...'`.

- [ ] **Step 3: Add the ceiling to the unit**

In `scripts/usenet-blackhole.service`, add this comment block directly above the existing `ExecStart=` line:

```
# --max-inflight 6 is the resting state, for the same reason --report-failures
# is on above: the script ships the cap inert and takes a flag, which is right
# for a rollout and wrong for a stack that is supposed to stay up. TorBox holds
# ten concurrent usenet downloads and refuses the eleventh, so 6 sits below the
# limit rather than at it, and the module's own docstring records why 6 was the
# value worth trying. Measured 2026-09-18, with no ceiling: 46 jobs submitted in
# one hour, 60 incomplete, and the arrs blind to all of them because a blackhole
# item is never in an arr queue.
ExecStart=/bin/bash -c 'mkdir -p /volume1/docker/arr-stack/logs && exec /bin/bash /volume1/docker/arr-stack/scripts/usenet-blackhole.sh --apply --report-failures --max-inflight 6 >> /volume1/docker/arr-stack/logs/usenet-blackhole.log 2>&1'
```

The only change to the command itself is `--max-inflight 6` inserted after `--report-failures`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `./tests/run-tests.sh tests/usenet-blackhole.bats`

Expected: PASS on all tests in the file, including the new one.

- [ ] **Step 5: Add the mutation corpus entry**

Append to `tests/mutation/corpus/usenet-blackhole.sh`:

```bash
# --- usenet-blackhole.service: the in-flight ceiling ----------------------

mutation unit-inflight-cap-removed \
  --file scripts/usenet-blackhole.service \
  --bats tests/usenet-blackhole.bats \
  --test "usenet-blackhole: the shipped unit caps in-flight jobs below TorBox's ten slots" \
  --why "removing the flag from ExecStart returns the pass to --max-inflight 0, the state that submitted 46 jobs in one hour on 2026-09-18 while 60 sat incomplete" \
  --apply 'sed -i "s@--report-failures --max-inflight 6@--report-failures@" "$F"'

mutation unit-inflight-cap-above-slots \
  --file scripts/usenet-blackhole.service \
  --bats tests/usenet-blackhole.bats \
  --test "usenet-blackhole: the shipped unit caps in-flight jobs below TorBox's ten slots" \
  --why "a ceiling at or above TorBox's ten concurrent slots cannot bound anything; set to 11 it is indistinguishable from no ceiling from the provider's side" \
  --apply 'sed -i "s@--max-inflight 6@--max-inflight 11@" "$F"'
```

- [ ] **Step 6: Prove the corpus entries can fail the test**

Run: `./tests/mutation/run-mutations.sh`

Expected: both new mutations report the named test going red. If either reports the test staying green, the test is not guarding what it claims and must be fixed before continuing.

- [ ] **Step 7: Apply to the NAS**

```bash
./scripts/sync-nas.sh
ssh leoleg@192.168.110.246 \
  'cp /volume1/docker/arr-stack/scripts/usenet-blackhole.service ~/.config/systemd/user/ && systemctl --user daemon-reload'
```

Note: `sync-nas.sh` pulls files only; it never installs units. The copy is the step that makes the ceiling real, and the unit's own comment records that the installed copy can drift silently from the repo copy.

- [ ] **Step 8: Commit**

```bash
git add scripts/usenet-blackhole.service tests/usenet-blackhole.bats tests/mutation/corpus/usenet-blackhole.sh
git commit -m "fix(usenet): cap in-flight TorBox jobs at 6 in the shipped unit"
```

---

### Task 2: Refuse to start a pass while the host is I/O-stalled

A pass writes to the same pool the whole stack reads from. A pass that starts while the host is already stalled is the one thing that cannot help: it lengthens the stall it is competing with. The gate reads PSI's `full avg10`, which counts time when *every* runnable task was stalled on I/O at once — the reading that separates a busy box from a wedged one, and the one that sat at 78-81% for hours during the incident while a healthy NAS reads 1.9%.

**Files:**
- Modify: `scripts/usenet-blackhole.sh` (add a default near the other defaults, a function near the other helpers, and the gate immediately before the `python3` invocation)
- Modify: `tests/usenet-blackhole.bats` (append a new section)
- Modify: `tests/mutation/corpus/usenet-blackhole.sh` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `psi_io_full_avg10()` in `scripts/usenet-blackhole.sh`, which prints the `full avg10` value from `$PSI_IO_PATH` (default `/proc/pressure/io`) and returns non-zero when that file is unreadable. Consumed only by the gate in the same file. Environment variables read: `PSI_IO_PATH`, `PSI_IO_LIMIT` (default 20).

- [ ] **Step 1: Write the failing tests**

Append to `tests/usenet-blackhole.bats`:

```bash
# --- host I/O pressure gate -------------------------------------------------

# A fixture standing in for /proc/pressure/io. The real file is Linux-only, so
# nothing in this section may touch it -- the suite also runs on macOS.
psi_fixture() {
    printf 'some avg10=%s avg60=0.00 avg300=0.00 total=0\nfull avg10=%s avg60=0.00 avg300=0.00 total=0\n' \
        "$1" "$1" > "$WORK/pressure-io"
    echo "$WORK/pressure-io"
}

# Every test here needs a keyed .env, because the gate sits after the key guard.
keyed_env() {
    printf 'MEDIA_ROOT=%s/data\nTORBOX_API_KEY=testtorboxkey\n' "$WORK" > "$ENV"
}

@test "usenet-blackhole: a stalled host skips the pass before python runs" {
    keyed_env
    stub_python
    run env "PATH=$WORK/bin:$PATH" "PSI_IO_PATH=$(psi_fixture 95.00)" "$RUN" --apply
    assert_success
    assert_output --partial "pressure-gate"
    # The whole point of the gate: no work reaches python at all.
    [ ! -f "$WORK/argv" ]
}

@test "usenet-blackhole: a healthy host runs the pass" {
    keyed_env
    stub_python
    run env "PATH=$WORK/bin:$PATH" "PSI_IO_PATH=$(psi_fixture 1.90)" "$RUN" --apply
    assert_success
    refute_output --partial "pressure-gate"
    [ -f "$WORK/argv" ]
}

@test "usenet-blackhole: no PSI on the host means the gate fails open" {
    # macOS, and any kernel built without PSI, have no /proc/pressure/io. A gate
    # that blocked there would stop the stack downloading on every machine the
    # suite runs on, and would do it silently -- which is the failure mode this
    # repo keeps being bitten by.
    keyed_env
    stub_python
    run env "PATH=$WORK/bin:$PATH" "PSI_IO_PATH=$WORK/does-not-exist" "$RUN" --apply
    assert_success
    refute_output --partial "pressure-gate"
    [ -f "$WORK/argv" ]
}

@test "usenet-blackhole: the gate is the only thing that changes when pressure crosses the limit" {
    # Same run, same fixture, one hundredth apart. Without this, a gate that
    # always skipped -- or never did -- would pass the three tests above.
    keyed_env
    local pair value expect
    for pair in "19.99:run" "20.00:skip"; do
        value="${pair%%:*}"
        expect="${pair##*:}"
        stub_python
        rm -f "$WORK/argv"
        run env "PATH=$WORK/bin:$PATH" "PSI_IO_PATH=$(psi_fixture "$value")" "$RUN" --apply
        assert_success
        if [[ "$expect" == "run" ]]; then
            [ -f "$WORK/argv" ] || fail "avg10=$value should have run the pass"
        else
            [ ! -f "$WORK/argv" ] || fail "avg10=$value should have skipped the pass"
        fi
    done
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/run-tests.sh tests/usenet-blackhole.bats`

Expected: FAIL on all four new tests. The first three fail on `refute_output`/`[ ! -f ]` because there is no gate yet, so python runs in every case; the fourth fails on `avg10=20.00 should have skipped the pass`.

- [ ] **Step 3: Add the limit default**

In `scripts/usenet-blackhole.sh`, next to the other defaults (around `DEFAULT_MAX_INFLIGHT=0`), add:

```bash
PSI_IO_LIMIT="${PSI_IO_LIMIT:-20}"
```

- [ ] **Step 4: Add the reader function**

Add `psi_io_full_avg10()` beside the script's other helper functions, above the argument loop:

```bash
# io full avg10 from /proc/pressure/io, or nothing when PSI is unavailable.
#
# `full` rather than `some`: `some` counts a single stalled task, which is
# ordinary on a busy box, while `full` means every runnable task was stalled on
# I/O at once. Measured on this NAS: 1.9% healthy, 78-81% during the incident of
# 2026-09-18.
#
# PSI_IO_PATH exists so a test can point this at a fixture; the real file is
# Linux-only and the suite also runs on macOS.
psi_io_full_avg10() {
  local path="${PSI_IO_PATH:-/proc/pressure/io}"
  [[ -r "$path" ]] || return 1
  awk '$1 == "full" {
         for (i = 2; i <= NF; i++) {
           split($i, kv, "=")
           if (kv[1] == "avg10") { print kv[2]; exit }
         }
       }' "$path"
}
```

- [ ] **Step 5: Add the gate**

Immediately before the `if ! TORBOX_API_KEY="$TORBOX_KEY" \` block that invokes `python3`:

```bash
# --- host I/O pressure gate -------------------------------------------------
#
# A pass writes to the same pool the rest of the stack reads from, so a pass
# that starts while the host is already stalled is the one thing that cannot
# help: it lengthens the stall it is competing with. On 2026-09-18 this NAS sat
# at load 58 with io full avg10 between 78% and 81% for hours; every container
# accepted a TCP connection and answered nothing.
#
# Fails OPEN, deliberately. A kernel built without PSI, or a container that
# cannot read /proc/pressure, must not become a stack that silently stops
# downloading -- and "the guard ran and found nothing" and "the guard could not
# run" must not be the same observable result.
HOST_PRESSURE="$(psi_io_full_avg10 || true)"
if [[ -n "$HOST_PRESSURE" ]] &&
   awk -v seen="$HOST_PRESSURE" -v limit="$PSI_IO_LIMIT" \
       'BEGIN { exit !(seen >= limit) }'; then
  echo "[pressure-gate] host I/O is stalled (io full avg10=${HOST_PRESSURE}%, limit ${PSI_IO_LIMIT}%); skipping this pass"
  exit 0
fi
```

Exit 0, not non-zero: a skipped pass is a healthy outcome, and the unit is `Type=oneshot` — a non-zero exit would mark the unit failed in `systemctl --user list-units --state=failed` and bury the signal in noise. The skip is visible in the pass log and on the usenet status page.

Do not add this to the `--help` header block. The header documents flags, and this is an environment override; adding a line there also moves the `sed -n '3,55p'` range that `--help` depends on, which has its own test.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./tests/run-tests.sh tests/usenet-blackhole.bats`

Expected: PASS on all tests in the file, new and pre-existing. The pre-existing tests must stay green: none of them sets `PSI_IO_PATH`, and on macOS the default `/proc/pressure/io` does not exist, so the gate fails open for them.

- [ ] **Step 7: Add the mutation corpus entries**

Append to `tests/mutation/corpus/usenet-blackhole.sh`:

```bash
# --- scripts/usenet-blackhole.sh: the host I/O pressure gate --------------

mutation pressure-gate-inverted \
  --file scripts/usenet-blackhole.sh \
  --bats tests/usenet-blackhole.bats \
  --test "usenet-blackhole: the gate is the only thing that changes when pressure crosses the limit" \
  --why "inverting the comparison runs the pass exactly when the host is stalled and skips it when the host is healthy -- the whole guard backwards, and the boundary test is what notices" \
  --apply 'sed -i "s@exit !(seen >= limit)@exit !(seen < limit)@" "$F"'

mutation pressure-gate-threshold-hardcoded \
  --file scripts/usenet-blackhole.sh \
  --bats tests/usenet-blackhole.bats \
  --test "usenet-blackhole: the gate is the only thing that changes when pressure crosses the limit" \
  --why "ignoring PSI_IO_LIMIT and comparing against a literal makes the trip point unmeasurable and un-tunable on a host whose healthy baseline is not this one's" \
  --apply 'sed -i "s@-v limit=\"\$PSI_IO_LIMIT\"@-v limit=\"999999\"@" "$F"'

mutation pressure-gate-fails-closed \
  --file scripts/usenet-blackhole.sh \
  --bats tests/usenet-blackhole.bats \
  --test "usenet-blackhole: no PSI on the host means the gate fails open" \
  --why "treating an unreadable /proc/pressure/io as stalled stops the stack downloading on every host without PSI, silently, and it would take the macOS half of this suite down with it" \
  --apply 'sed -i "s@\[\[ -r \"\$path\" \]\] || return 1@[[ -r \"\$path\" ]] || return 0@" "$F"'
```

- [ ] **Step 8: Prove the corpus entries can fail their tests**

Run: `./tests/mutation/run-mutations.sh`

Expected: all three new mutations report the named test going red. The third depends on the reader function returning non-zero for an unreadable path — if it reports green, the `|| return 1` is not the thing the fail-open test rests on, and the test needs rewriting before continuing.

- [ ] **Step 9: Commit**

```bash
git add scripts/usenet-blackhole.sh tests/usenet-blackhole.bats tests/mutation/corpus/usenet-blackhole.sh
git commit -m "fix(usenet): skip a pass while the host is I/O-stalled"
```

---

### Task 3: Stop duc re-indexing the whole volume on every restart

`duc` mounts `/volume1` and walks it to build its index. Its entrypoint runs that walk on **every container start**, and the service is `restart: always`. During the incident duc restarted at 23:07 while the NAS was already I/O-starved and immediately walked 2.9 Tb / 842.4K files / 139.8K directories again — adding to the stall it was suffering from. The daily cron at `0 4 * * *` is the schedule that keeps the index current; a start-up scan that finds a fresh index is pure cost.

**Files:**
- Modify: `duc-service/app/startup.sh` (add two seams near the other `DUC_*` seams, a function, and branch `main()` on it)
- Modify: `tests/duc-service.bats` (append a new section)
- Modify: `tests/mutation/corpus/duc-service.sh` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `startup_scan_needed()` in `duc-service/app/startup.sh`, returning 0 when the index must be rebuilt and 1 when it is fresh enough to skip. Environment variables read: `DUC_INDEX_DB` (default `/database/duc.db`), `DUC_STARTUP_SCAN_MAX_AGE_HOURS` (default `20`). Both follow the existing `DUC_*` seam convention, which exists only for `tests/duc-service.bats`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/duc-service.bats`. The `startup` helper already defined in that file sources `startup.sh` and calls one named function, which is how these reach `startup_scan_needed` without running `main()` and blocking on `start_webserver`:

```bash
# --- startup.sh: the start-up scan -----------------------------------------

@test "duc: startup scans when there is no index yet" {
    export DUC_INDEX_DB="$WORK/duc.db"
    rm -f "$DUC_INDEX_DB"
    startup startup_scan_needed
    assert_success
}

@test "duc: startup skips the scan when the index is fresh" {
    # The incident case: restart: always brought duc up at 23:07 on 2026-09-18
    # while the NAS was already I/O-starved, and it walked 842.4K files again
    # for nothing. The daily cron is what keeps the index current.
    export DUC_INDEX_DB="$WORK/duc.db"
    : > "$DUC_INDEX_DB"
    startup startup_scan_needed
    assert_failure
}

@test "duc: startup scans again once the index is older than the window" {
    export DUC_INDEX_DB="$WORK/duc.db"
    : > "$DUC_INDEX_DB"
    touch -t 202001010000 "$DUC_INDEX_DB"
    startup startup_scan_needed
    assert_success
}

@test "duc: the freshness window comes from the environment, not a literal" {
    export DUC_INDEX_DB="$WORK/duc.db"
    : > "$DUC_INDEX_DB"
    touch -t 202001010000 "$DUC_INDEX_DB"
    export DUC_STARTUP_SCAN_MAX_AGE_HOURS=999999
    startup startup_scan_needed
    assert_failure
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/run-tests.sh tests/duc-service.bats`

Expected: FAIL on all four with `startup_scan_needed: command not found` (the sourced `startup.sh` does not define it yet).

- [ ] **Step 3: Add the seams**

In `duc-service/app/startup.sh`, beside the existing `DUC_*` seam block at the top of the file:

```bash
# The index this reads to decide whether a start-up scan is worth running, and
# how old it may be before one is. Same convention as the seams above: the
# image sets neither, so the container uses these defaults.
#
# 20 hours, not 24: the daily cron is `0 4 * * *`, so an index is at most 24
# hours old and normally much younger. 20 leaves room for a cron run that
# started late without letting a genuinely stale index through.
INDEX_DB="${DUC_INDEX_DB:-/database/duc.db}"
STARTUP_SCAN_MAX_AGE_HOURS="${DUC_STARTUP_SCAN_MAX_AGE_HOURS:-20}"
```

- [ ] **Step 4: Add the decision function**

Add above `main()` in the same file:

```bash
# Is a start-up scan worth running?
#
# The start-up scan exists for a first run with no index at all. It used to run
# on every container start, which made `restart: always` a loaded gun: on
# 2026-09-18 duc restarted at 23:07 while the NAS was already I/O-starved and
# immediately walked 2.9 Tb / 842.4K files / 139.8K directories again, adding to
# the stall it was suffering from. A fresh index is a warm start.
#
# Returns 0 when a scan is needed, 1 when the index is fresh enough to skip.
# Fails towards scanning: an index that is missing, unreadable, or whose age
# cannot be determined gets a scan, which is the behaviour that shipped before
# this function existed.
startup_scan_needed() {
    local age_minutes
    [[ -f "$INDEX_DB" ]] || return 0
    age_minutes=$(( STARTUP_SCAN_MAX_AGE_HOURS * 60 ))
    [[ -z "$(find "$INDEX_DB" -mmin -"$age_minutes" 2>/dev/null)" ]]
}
```

- [ ] **Step 5: Branch `main()` on it**

Replace the first six lines of `main()` — the unconditional scan — with:

```bash
    if startup_scan_needed; then
        echo "Starting initial recursive scan"
        echo "This may take a while..."
        echo "Now: $(date)"
        "$SCAN_SH" || echo "Initial scan failed (exit $?)" | tee -a "$LOG_FILE"
        echo "Now: $(date)"
        echo "Scan complete"
    else
        echo "Index is newer than ${STARTUP_SCAN_MAX_AGE_HOURS}h; skipping the initial scan"
    fi
```

Everything from `local schedule="${SCHEDULE:-}"` down is unchanged.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./tests/run-tests.sh tests/duc-service.bats`

Expected: PASS on all tests in the file, new and pre-existing.

- [ ] **Step 7: Add the mutation corpus entries**

Append to `tests/mutation/corpus/duc-service.sh`:

```bash
# --- duc startup.sh: the start-up scan ------------------------------------

mutation duc-startup-always-scans \
  --file duc-service/app/startup.sh \
  --bats tests/duc-service.bats \
  --test "duc: startup skips the scan when the index is fresh" \
  --why "restoring the unconditional start-up scan is the defect of 2026-09-18: with restart: always, every restart re-walks the whole volume" \
  --apply 'sed -i "s@if startup_scan_needed; then@if true; then@" "$F"'

mutation duc-startup-never-scans \
  --file duc-service/app/startup.sh \
  --bats tests/duc-service.bats \
  --test "duc: startup scans when there is no index yet" \
  --why "the opposite defect: a first run against an empty volume never builds an index, and every page of the UI is empty with nothing in the log to say why" \
  --apply 'sed -i "s@if startup_scan_needed; then@if false; then@" "$F"'

mutation duc-freshness-window-hardcoded \
  --file duc-service/app/startup.sh \
  --bats tests/duc-service.bats \
  --test "duc: the freshness window comes from the environment, not a literal" \
  --why "hardcoding the window makes the seam inert, so the number cannot be tuned on a host whose cron cadence differs and the test above silently stops testing anything" \
  --apply 'sed -i "s@age_minutes=\$(( STARTUP_SCAN_MAX_AGE_HOURS \* 60 ))@age_minutes=1200@" "$F"'
```

- [ ] **Step 8: Prove the corpus entries can fail their tests**

Run: `./tests/mutation/run-mutations.sh`

Expected: all three new mutations report their named test going red. The third is the one to watch — if it reports green, `sed` matched nothing and the mutation never applied.

- [ ] **Step 9: Commit**

```bash
git add duc-service/app/startup.sh tests/duc-service.bats tests/mutation/corpus/duc-service.sh
git commit -m "fix(duc): skip the start-up re-index when the index is fresh"
```

---

### Task 4: Record the incident

Everything in the Evidence section above was reconstructed from live measurements that no longer exist: `/proc/pressure/io` counters reset on reboot, the Beszel database was never populated, and the journal carries only host-level messages because container logs go to Docker's json files. It was recoverable this time because the box happened to be calm enough to read. It will not be next time. This repo keeps audited incident records (`docs/TEST-HARDENING-LOG.md`, `docs/EXIT-NODE-PROJECT-LOG.md`) for exactly this reason.

**Files:**
- Create: `docs/NAS-LOAD-INCIDENT-2026-09-18.md`
- Modify: `docs/TROUBLESHOOTING.md` (add a cross-reference)
- Test: `tests/lib-doc-links.bats` (existing)

**Interfaces:**
- Consumes: the Evidence table in this plan.
- Produces: nothing code-level. The deliverable is a document that a future reader can act on without re-deriving it.

- [ ] **Step 1: Write the document**

Create `docs/NAS-LOAD-INCIDENT-2026-09-18.md` containing, in this order:

1. **What happened** — one paragraph: the NAS entered sustained I/O starvation from ~11:51 on 2026-09-18 until it was rebooted, with load 58 on 8 cores and io full-stall at 78-81%. Every service on it accepted TCP connections and answered nothing, which is why `.lan` looked like a DNS problem.
2. **The timeline** — the table from this plan's Evidence section, extended with: the three NZB waves (Sep 17 22:00 = 91, Sep 18 05:00 = 113, Sep 18 11:00 = 61); `stremio-library-sync-state.json`'s `baselined_at` 2026-09-17T21:20:53Z and `backfill_started_at` 2026-09-17T21:41:12Z with `handled: 108`; Sonarr's `DownloadDecisionMaker: Processing 932 releases` at 11:45-12:20; the first `queue-cleanup` hard failure at 12:46:59; the container restart batches at 15:45, 17:45, 19:45, 20:12, 20:32 and 23:07; the shutdown at 23:33.
3. **The mechanism** — the feedback loop: writes fill page cache → reclaim thrashes (`kswapd0` at 100% CPU, memory full-stall 87.78%) → healthchecks time out → `deunhealth` and `restart: always` restart containers → each restart re-reads `overlay2` image layers and duc re-walks the volume → more I/O. The measured fingerprint is 136 MB/s of disk reads against 3 MB/s of downloads.
4. **What it was not** — no OOM: the previous boot's kernel journal contains no `oom-kill` or `Memory cgroup out of memory` entry, so radarr's `Exited (137)` was a SIGKILL from a restart whose stop grace period expired, not the OOM killer. Not disk-full (3.0 TB of 19 TB). Not DNS, routing, or Traefik. Not the downloads themselves (`FETCH_WORKERS = 3`, 3 MB/s observed).
5. **Why nothing recovered** — the four timers that exist to clear a stuck queue (`queue-cleanup`, `backlog-search`, `indexer-guard`, `stremio-library-sync`) were all failing against the apps they drive, because the apps were the thing that was starved.
6. **What was done about it** — one line each, linking to `scripts/usenet-blackhole.service`, `scripts/usenet-blackhole.sh`, and `duc-service/app/startup.sh`.
7. **What is still open** — the items this plan deliberately does not fix: `overlay2` sharing `/volume1` with the media library; 7.7 GB of RAM for 30 containers; Beszel's database being entirely empty because no system was ever registered with the hub; Uptime Kuma covering 8 endpoints out of 30 containers; and the user timers not arming after a reboot when the user manager beats the `/home` mount.

- [ ] **Step 2: Cross-reference it**

In `docs/TROUBLESHOOTING.md`, add a new section at the top of the file, before the first existing section, headed `## Everything Is Unreachable At Once`:

```markdown
If the whole stack looks unreachable at once — `.lan` names resolve, ports accept
connections, and nothing ever answers — read
[NAS load incident, 2026-09-18](NAS-LOAD-INCIDENT-2026-09-18.md) before
re-deriving it. That is a host-level I/O stall, not a DNS or proxy fault.
```

- [ ] **Step 3: Verify the links resolve**

Run: `./tests/run-tests.sh tests/lib-doc-links.bats`

Expected: PASS. This is the only automated check a document gets in this repo.

- [ ] **Step 4: Commit**

```bash
git add docs/NAS-LOAD-INCIDENT-2026-09-18.md docs/TROUBLESHOOTING.md
git commit -m "docs: record the 2026-09-18 NAS load incident"
```

---

## Deliberately not in this plan

Each of these is a separate subsystem and belongs in its own plan. None is a prerequisite for the guards above, and shipping the three guards does not depend on any of them.

**Plan: automation survives reboot.** On this boot the user manager started at 00:05:04, 29 seconds after boot, while the unit files live under `/home` — a separate btrfs subvolume on the LVM/md pool. `timers.target` came up active and empty, and all eight user timers were left inactive while `is-enabled` still reported every one of them as enabled. Do not write this plan until one thing is settled on the NAS first: **when does `/home` actually mount, relative to `user@1000.service`?** That needs `systemd-analyze critical-chain` and the previous boot's journal, and it decides whether the fix is a drop-in ordering `user@1000.service` after `home.mount`, a re-arm unit, or moving the units off `/home` entirely. Guessing it now would produce a plan that cannot be verified.

**Plan: the restart cascade.** `deunhealth` restarts 7 labelled containers when they go unhealthy, `restart: always` restarts anything that exits, `gluetun-recover` restarts the containers whose network namespace dies with a gluetun restart, and gluetun itself is restarted by `gluetun-rotator` every 6 hours and by `indexer-guard` on an indexer ban. Under I/O starvation that is a positive feedback loop. Damping it means deciding which healthchecks may fail before a restart is justified, and that is a behaviour change with its own risk — weakening a healthcheck hides real failures.

**Plan: observability.** Beszel's `data.db` has zero rows in `systems`, `system_stats`, `container_stats` and `system_details`: the hub was never given a system, so the stack's own metrics layer recorded nothing across the whole incident. The only reason a timeline exists is Uptime Kuma's 8 monitors. `scripts/lib/check-uptime-monitors.sh` already knows what ought to be monitored — it is `warnings only - does not block commits` and skips without NAS config.

**Rejected on the evidence: rate-limiting the Stremio backfill.** `stremio-library-sync` already caps itself at `DEFAULT_MAX_REQUESTS = 3` per pass on a 10-minute timer, which is at most 18 requests an hour, against a `stremio_library.py` docstring that says the cap exists precisely for "a bulk import, a restored account, or the `--backfill` run over a library that is mostly missing". The backfill of 108 items was therefore already paced at the request layer. What was not paced was anything between those requests and the disks: each accepted request triggers an arr search that grabs many releases, and the resulting NZB volume met an ingest path with no ceiling at all. Adding a second limiter at the request layer would slow the symptom without bounding the queue that actually caused the stall. Do not add one without a measurement showing the current cap is the binding constraint.

**Not planned, not fixable in code:** `overlay2` and the media library share `/volume1`, so container churn competes with downloads for the same two disks. 7.7 GB of RAM carries 30 containers. Both are capacity decisions, and the guards above reduce how hard they get pushed rather than removing the constraint.
