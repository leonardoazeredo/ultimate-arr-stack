# Stop a busy host reading as a stuck drain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpower-subagent-driven-development (recommended) or superpower-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `scripts/usenet-drain-walk.sh` distinguish a pass the I/O pressure gate refused from a pass that ran and moved nothing, so a saturated host stops the walk for its own stated reason instead of reporting a stuck drain.

**Architecture:** Two counters where there was one. A refused pass never starts — `scripts/usenet-blackhole.sh` exits 0 at its pressure gate before reaching Python — so it is evidence about the host, not about the drain, and it must not increment `BARREN`. It gets a consecutive counter of its own (`REFUSED`), its own bound (`--max-skipped`, default 6), its own stop reason, a cumulative counter (`REFUSED_TOTAL`) that the summary prints, and a reset whenever the gate does admit a pass. Nothing else about the walk changes: the pass budget still counts attempts, the exit codes are unchanged, and the watchdog, the lock, the timer refusal and the path resolution are untouched.

**Tech Stack:** Bash 3.2-compatible shell (no associative arrays, no `${var,,}`), bats-core + bats-assert for the suite, the in-repo mutation harness (`tests/mutation/`), systemd-free — the walk is a foreground script run by hand.

**Spec:** There is no separate spec document. The requirement source is a real run of the tool on 2026-09-22, whose log is the defect report: 12 passes, of which **4 were refused by the pressure gate and counted as "no progress"**, and the stop reason the tool would have printed had the run been shorter. The numbers are reproduced verbatim in **Evidence** below. `docs/MAINTENANCE.md`'s "Holding the usenet ingest down" is the policy this tool implements; read it before editing the walk's bounds.

---

## Global Constraints

- **Bash 3.2 compatible.** The suite runs on the maintainer's macOS (`/bin/bash` 3.2.57) as well as on Linux. No associative arrays, no `mapfile`, no `${var,,}`/`${var^^}`. The GNU/BSD split is already handled by `file_mtime` in this file; do not add another place that reads `stat`.
- **Shellcheck clean at `-S error`.** `tests/shellcheck.bats` derives its file list from shebangs, so `scripts/usenet-drain-walk.sh` is covered. CI runs it on every push.
- **No new files.** This change adds no script, so the two hand-maintained inventories (`CONTRIBUTING.md`'s scripts tree, `tests/mutation/README.md`'s no-sweep list) must **not** be edited. If a task seems to need a line in either, it has created a file it should not have.
- **Every new guard needs a mutation-corpus entry.** `tests/mutation/README.md` is explicit: a test merged without one has no evidence it can fail. Task 5 adds it.
- **The `--help` range is a fixed line range in the source.** `sed -n '3,<N>p'` must stop ON the last non-blank header comment line. It is currently **wrong** (see Task 2) and both tasks that touch the header must re-derive it.
- **Comments say why, with the measurement.** This file's existing comments cite dates and numbers; match that. A comment that restates the code is worse than no comment.
- **Deploy is branch-first and NAS-verified** (`CLAUDE.md`): feature branch, `./scripts/sync-nas.sh`, verify on the NAS, only then a PR and a squash merge, then sync `main` back. This change is scripts-only — **no container rebuild, no unit copy, no `daemon-reload`**.
- **Never pass `--remove-orphans`** to any `docker compose` command on the NAS, and do not arm `usenet-blackhole.timer` at any point in this plan.

---

## Evidence

Measured on the NAS on 2026-09-22, during and after a 140-minute run of the tool as it exists today (`f286867`). Do not re-derive these; where a figure came from a log, the file is named.

| Measurement | Value | Source |
| --- | --- | --- |
| Passes attempted | **12** (`--max-passes 12`) | `logs/usenet-drain-walk.log` |
| Passes the pressure gate refused | **4** — passes 4, 5, 9 and 10 | `logs/usenet-drain-walk.log` |
| Refusals in a row, both times | **2** (passes 4-5, then 9-10) | same |
| What the run counted those as | `no progress this pass (1/4)`, `(2/4)`, `(3/4)` | same |
| Passes that ran and moved nothing | **0** — every admitted pass made progress | same |
| Delivered | outbox 603 → 573, jobs 21 → 8 | same |
| Peak `io full avg10` during the run | **73.91%**, peak load **19.97** | 1 Hz sampler, 136 samples |
| `io full avg10` at rest, after the run | ~14% | `/proc/pressure/io` |
| Gate threshold | `PSI_IO_LIMIT` = 20 (the blackhole script's default) | `scripts/usenet-blackhole.sh` |

**The defect, stated precisely.** Had passes 11 and 12 also been refused — a saturated host, which is the state the gate exists for — the walk would have stopped printing `4 passes in a row made no progress`. Not one of those four passes ever ran. The sentence is false about the drain and silent about the host, and it is the sentence an operator reads first.

**The near miss is measured, not imagined:** refusal streaks of 2 happened twice in one 12-pass run, at a threshold of 4, with no change to the host or the queue between them.

**One claim this plan deliberately does not build on.** It does not argue that 4 is too low or that 6 is right. Six is chosen to sit just above the longest streak this run produced (2) and to be expressed in skip-cooldowns — 6 × 300s = **30 minutes** of a host that is too busy to start a pass — while leaving `--max-hours 4` as the outer bound. The threshold is a flag precisely because it is a guess.

**What remains unverified, and this plan does not settle:** whether the gate's refusals cluster on a periodic cause (an import sweep, a backup, a transcode) rather than on the drain's own writeback. If they are periodic, a longer `--max-skipped` is the wrong answer and a schedule is the right one. Nothing here prevents taking that measurement later; it does stop the tool from lying in the meantime.

---

## What this plan deliberately does not do

- **Does not change what consumes the pass budget.** A refused pass still costs one of `--max-passes`, so the log reads `pass 4/12: refused`. Changing that would let a saturated host attempt indefinitely, bounded only by `--max-hours`, and it would move the meaning of a documented flag. The refusal bound is a separate, smaller number, which is why it stops the walk first.
- **Does not add an exit code.** `0` = the outbox cleared the mark, `3` = it did not, `1` = a refused precondition, `2` = bad arguments. A saturated host is still "the mark did not clear", and widening the contract would break every caller that reads `3` today. The reason is in the output and the log.
- **Does not treat an errored pass (`exit != 0`) as its own category.** A pass that died is a drain that is not moving; it stays in `BARREN`, which is accurate and already tested.
- **Does not touch the pressure gate, `PSI_IO_LIMIT`, or `scripts/usenet-blackhole.sh`.**

---

## File structure

| File | Responsibility | Change |
| --- | --- | --- |
| `scripts/usenet-drain-walk.sh` | the walk: bounds, counters, watchdog, stop reasons, summary | modify |
| `tests/usenet-drain-walk.bats` | the walk's contract, with the pass stubbed | modify |
| `tests/mutation/corpus/usenet-drain-walk.sh` | proof the suite can fail | modify |
| `docs/MAINTENANCE.md` | the operator-facing procedure and its bounds | modify |

---

## Task 1: A pass the pressure gate refused is not a barren pass

**Files:**
- Modify: `scripts/usenet-drain-walk.sh` (the walk section, `PASS_NUMBER=0` init block at ~640, and the post-pass block at ~673)
- Test: `tests/usenet-drain-walk.bats`

**Interfaces:**
- Consumes: `$PASS_SKIPPED`, set by `run_pass()` at the end of every pass — `true` when the pass's captured output contains `[pressure-gate]`.
- Produces: shell variable `REFUSED`, an integer initialised to `0` and incremented once per refused pass, reset to `0` by any pass the gate admitted. Task 3 reads it for the stop condition; Task 4 does not.
- Produces: a log line for a refused pass, exactly `the pressure gate refused pass <N> (<M> in a row); the host read as too busy to start it`.

- [ ] **Step 1: Write the failing test**

Add this helper to `tests/usenet-drain-walk.bats` immediately after `write_productive_pass()` (which ends at line ~124):

```bash
# A pass the pressure gate refuses: it prints the gate's own line, touches
# nothing, and exits 0 -- exactly what scripts/usenet-blackhole.sh does when it
# stands a pass down. The walk detects this by grepping the pass's captured
# output, which is why the line has to be the real one.
write_refused_pass() {
    cat > "$WORK/scripts/usenet-blackhole.sh" <<'EOS'
#!/bin/bash
echo "refused pass $$ invoked: $*" >> "$STUB_PASS_CALLS"
echo "[pressure-gate] host I/O is stalled (io full avg10=88.00%, limit 20%); skipping this pass"
EOS
    chmod +x "$WORK/scripts/usenet-blackhole.sh"
}
```

Then add this test immediately after the test `usenet-drain-walk: progress resets the barren streak and the budget ends the walk` (ends at line ~238):

```bash
@test "usenet-drain-walk: a pass the pressure gate refused is not a barren pass" {
    seed_outbox 12
    write_refused_pass
    # --max-barren 1 is the assertion. A refused pass never ran, so it is not
    # evidence about the drain, and counting it as barren stopped the walk after
    # one attempt with "1 passes in a row made no progress" -- the wrong
    # sentence about the right observation, because the host was busy and the
    # queue was not stuck. Both attempts must happen for this to pass.
    run "$RUN" --apply --poll 1 --pass-stall 60 --max-passes 2 --max-barren 1 \
        --skip-cooldown 1 --cooldown 1
    [ "$(wc -l < "$PASS_CALLS" | tr -d ' ')" -eq 2 ]
    refute_output --partial "made no progress"
    assert_output --partial "the pressure gate refused"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `TMPDIR="$PWD/.tmp-bats" tests/bats-core/bin/bats tests/usenet-drain-walk.bats --filter "refused is not a barren pass"`
Expected: FAIL. The output contains `no progress this pass (1/1)` and `stopped: 1 passes in a row made no progress`, and the invocation count assertion fails because only one pass was attempted.

- [ ] **Step 3: Add the counter**

In `scripts/usenet-drain-walk.sh`, in the walk section at ~line 640, this block:

```bash
PASS_NUMBER=0
BARREN=0
STOP_REASON=""
```

becomes:

```bash
PASS_NUMBER=0
BARREN=0
# Passes the pressure gate refused, counted separately from BARREN. A refused
# pass never started -- scripts/usenet-blackhole.sh exits at its gate before it
# reaches python -- so it is evidence about the host, not about the drain.
# Measured 2026-09-22: 4 of 12 passes in one run were refusals and every one of
# them was counted as "no progress", against a run in which no admitted pass
# failed to move anything.
REFUSED=0
STOP_REASON=""
```

- [ ] **Step 4: Split the post-pass branch**

In the same file, this block (at ~line 673):

```bash
  if advanced "$before" "$after"; then
    BARREN=0
    log "progress: ${before} -> ${after}"
  else
    BARREN=$((BARREN + 1))
    log "no progress this pass (${BARREN}/${MAX_BARREN}): ${before} -> ${after}"
  fi
```

becomes:

```bash
  if [[ "$PASS_SKIPPED" == "true" ]]; then
    REFUSED=$((REFUSED + 1))
    log "the pressure gate refused pass ${PASS_NUMBER} (${REFUSED} in a row); the host read as too busy to start it"
  else
    # An admitted pass is what clears the refusal streak: the gate let this one
    # through, so the host was not too busy to start work.
    REFUSED=0
    if advanced "$before" "$after"; then
      BARREN=0
      log "progress: ${before} -> ${after}"
    else
      BARREN=$((BARREN + 1))
      log "no progress this pass (${BARREN}/${MAX_BARREN}): ${before} -> ${after}"
    fi
  fi
```

- [ ] **Step 5: Stop the cooldown block double-logging the refusal**

The refusal is now logged above, so this block (at ~line 691):

```bash
  if [[ "$PASS_SKIPPED" == "true" ]]; then
    log "the pressure gate refused that pass; waiting ${SKIP_COOLDOWN_SECONDS}s before the next"
    sleep_or_break "$SKIP_COOLDOWN_SECONDS" "$$"
  elif [[ "$BARREN" -lt "$MAX_BARREN" ]]; then
```

becomes:

```bash
  if [[ "$PASS_SKIPPED" == "true" ]]; then
    # The refusal itself is logged above, once. This says only what happens next.
    log "waiting ${SKIP_COOLDOWN_SECONDS}s before the next attempt"
    sleep_or_break "$SKIP_COOLDOWN_SECONDS" "$$"
  elif [[ "$BARREN" -lt "$MAX_BARREN" ]]; then
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `TMPDIR="$PWD/.tmp-bats" tests/bats-core/bin/bats tests/usenet-drain-walk.bats --filter "refused is not a barren pass"`
Expected: PASS.

- [ ] **Step 7: Run the whole file**

Run: `TMPDIR="$PWD/.tmp-bats" tests/bats-core/bin/bats tests/usenet-drain-walk.bats`
Expected: 17 tests, all `ok`. If `usenet-drain-walk: progress resets the barren streak and the budget ends the walk` fails, the split has changed which branch a *productive* pass takes — check that `PASS_SKIPPED` is `false` for it (it is set at the end of `run_pass`).

- [ ] **Step 8: Commit**

```bash
git add scripts/usenet-drain-walk.sh tests/usenet-drain-walk.bats
git commit -m "usenet-drain-walk: a refused pass is not a barren one

The pressure gate refusing a pass is the host protecting itself, and the pass
never starts -- scripts/usenet-blackhole.sh exits at the gate before python. It
was counted as 'no progress' anyway, so four refusals in one 12-pass run read
as a drain that had stopped moving. Measured 2026-09-22: 4 of 12 passes refused,
every admitted pass moved something."
```

---

## Task 2: `--help` prints the whole header

This is a pre-existing bug in the file this plan changes, and the header edit in Task 3 makes it worse, which is why it is fixed before the header grows.

**Files:**
- Modify: `scripts/usenet-drain-walk.sh` (the `--help` case at ~line 201)
- Test: `tests/usenet-drain-walk.bats`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing at runtime. The contract this task pins down is that `--help` prints the header block in full, and that the range tracks the header automatically being checked rather than asserted as a number.

- [ ] **Step 1: Write the failing tests**

Add immediately after the existing test `usenet-drain-walk: --help prints the usage block and stops at it` (ends at line ~371):

```bash
@test "usenet-drain-walk: --help prints the whole header, not a prefix of it" {
    run "$RUN" --help
    assert_success
    # The LAST lines of the header, not the middle. This is what the older test
    # above cannot see: every string it names sits in the first half of the
    # block, so a range three lines short of the end passed for as long as it
    # existed. It shipped that way.
    assert_output --partial "Prerequisites: python3"
    assert_output --partial "Generated with LLM assistance and human-reviewed"
    refute_output --partial "SCRIPT_DIR="
}

@test "usenet-drain-walk: the help range ends on the last non-blank header line" {
    # Derived from the file rather than written down. The range moves whenever
    # the header grows, and a hardcoded 3,86 would need editing in the same
    # commit as every line of documentation above it -- which is exactly the
    # edit that was missed.
    local last header_line
    last="$(awk 'NR >= 3 && /^# ./ { n = NR } /^SCRIPT_DIR=/ { print n; exit }' \
                "$REPO_ROOT/scripts/usenet-drain-walk.sh")"
    [ -n "$last" ] || fail "could not find the header/script boundary in scripts/usenet-drain-walk.sh"
    header_line="$(sed -n "${last}p" "$REPO_ROOT/scripts/usenet-drain-walk.sh" | sed 's/^# \{0,1\}//')"
    [ -n "$header_line" ] || fail "the last header line is empty; the awk pattern is wrong"
    run "$RUN" --help
    assert_output --partial "$header_line"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `TMPDIR="$PWD/.tmp-bats" tests/bats-core/bin/bats tests/usenet-drain-walk.bats --filter "help"`
Expected: 2 failures. `--help prints the whole header` fails on `Prerequisites: python3`; `the help range ends on the last non-blank header line` fails on `Generated with LLM assistance and human-reviewed`. The older test still passes.

- [ ] **Step 3: Derive the correct range**

Run: `awk 'NR >= 3 && /^#/ { n = NR } /^SCRIPT_DIR=/ { print n; exit }' scripts/usenet-drain-walk.sh`
Expected: `82`. (82 is the comment block's last line; 81, the line above it, is the `Generated with LLM assistance` line the new test asserts on. The two awks differ on purpose: the range covers the whole block, the test names the last line with text in it.)

- [ ] **Step 4: Fix the range**

In `scripts/usenet-drain-walk.sh`, in the `--help` case:

```bash
      sed -n '3,77p' "$0" | sed 's/^# \{0,1\}//'
```

becomes:

```bash
      sed -n '3,82p' "$0" | sed 's/^# \{0,1\}//'
```

And extend the comment above it, which currently ends `... which is what tests/usenet-drain-walk.bats notices.`:

```bash
      # The range moves whenever a line is added to the header, and it had
      # already fallen three lines short of the end: --help was missing the
      # Prerequisites line and the warning below it, and nothing failed,
      # because the test that "notices" only named strings from the middle of
      # the block. tests/usenet-drain-walk.bats now derives the last header line
      # from this file and asserts it appears in the output.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `TMPDIR="$PWD/.tmp-bats" tests/bats-core/bin/bats tests/usenet-drain-walk.bats --filter "help"`
Expected: 3 tests, all `ok`.

- [ ] **Step 6: Commit**

```bash
git add scripts/usenet-drain-walk.sh tests/usenet-drain-walk.bats
git commit -m "usenet-drain-walk: --help was printing a prefix of its own header

The range stopped three lines short, so the operator's --help was missing the
Prerequisites line and the warning beneath it. The test that was supposed to
notice only named strings from the middle of the block. It now derives the last
header line from the file and asserts it appears, so the range cannot fall
behind the header again without going red."
```

---

## Task 3: A host too busy to start a pass stands the walk down on its own reason

**Files:**
- Modify: `scripts/usenet-drain-walk.sh` (defaults ~line 100, arg parsing ~line 175, validation ~line 214 and ~line 250, the help range ~line 201, the banner ~line 600, the loop ~line 664, the closing notes ~line 721, the header block)
- Modify: `docs/MAINTENANCE.md` ("Walking the queue down with a watchdog")
- Test: `tests/usenet-drain-walk.bats`

**Interfaces:**
- Consumes: `REFUSED` from Task 1 — an integer, consecutive refusals since the last admitted pass.
- Produces: the shell variable `MAX_SKIPPED`, a positive integer, default `6`, settable as `--max-skipped N` or `--max-skipped=N`.
- Produces: the stop reason string, exactly `the I/O pressure gate refused <MAX_SKIPPED> passes in a row (the host was too busy to start one)`. Task 4 does not depend on it. The closing note keys off the substring `pressure gate refused`.

- [ ] **Step 1: Write the failing tests**

Add immediately after the test added in Task 1 (`usenet-drain-walk: a pass the pressure gate refused is not a barren pass`):

```bash
@test "usenet-drain-walk: a host too busy to start a pass stands the walk down on its own reason" {
    seed_outbox 12
    write_refused_pass
    run "$RUN" --apply --poll 1 --pass-stall 60 --max-passes 6 --max-barren 4 \
        --max-skipped 2 --skip-cooldown 1 --cooldown 1
    assert_failure 3
    assert_output --partial "the I/O pressure gate refused 2 passes in a row"
    [ "$(wc -l < "$PASS_CALLS" | tr -d ' ')" -eq 2 ]
    # And it did not spend the pass budget to say so: six were allowed and the
    # refusal bound stopped it at two.
    refute_output --partial "pass budget reached"
}

@test "usenet-drain-walk: --max-skipped must be a positive whole number" {
    run "$RUN" --max-skipped 0
    assert_failure 2
    assert_output --partial "--max-skipped must be at least 1"

    run "$RUN" --max-skipped banana
    assert_failure 2
    assert_output --partial "--max-skipped must be a whole number"

    run "$RUN" --max-skipped
    assert_failure 2
    assert_output --partial "--max-skipped needs a value"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `TMPDIR="$PWD/.tmp-bats" tests/bats-core/bin/bats tests/usenet-drain-walk.bats --filter "max-skipped"`
Expected: `--max-skipped must be a positive whole number` fails at the first assertion with `ERROR: unrecognised argument: --max-skipped`, exit 2.
Run: `TMPDIR="$PWD/.tmp-bats" tests/bats-core/bin/bats tests/usenet-drain-walk.bats --filter "too busy"`
Expected: FAIL — with `--max-skipped` not yet a flag the run stops on `unrecognised argument` (exit 2), and the reason string is absent.

- [ ] **Step 3: Add the default**

In `scripts/usenet-drain-walk.sh`, after the `MAX_BARREN=4` line in the defaults block:

```bash
# Consecutive passes the I/O pressure gate may refuse before the walk stands
# down. The gate refuses when /proc/pressure/io's full avg10 sits at or above
# PSI_IO_LIMIT, which is the host protecting itself and not a fault to retry
# through -- so this is expressed in skip-cooldowns (5 minutes each): 6 is half
# an hour of a host that is too busy to start a pass. Measured 2026-09-22: the
# longest refusal streak in a 12-pass run was 2, twice, with the threshold at 4.
MAX_SKIPPED=6
```

- [ ] **Step 4: Parse the flag**

In the argument loop, after the two `--max-barren` lines:

```bash
    --max-skipped) require_value "$1" "$#" "${2-}"; MAX_SKIPPED="$2"; shift ;;
    --max-skipped=*) MAX_SKIPPED="${1#*=}" ;;
```

- [ ] **Step 5: Validate it as a whole number**

In the `for pair in ...` list, add the pair:

```bash
for pair in "max-passes=$MAX_PASSES" "max-hours=$MAX_HOURS" \
            "max-barren=$MAX_BARREN" "max-skipped=$MAX_SKIPPED" \
            "poll=$POLL_SECONDS" \
```

- [ ] **Step 6: Convert it to base ten**

After `MAX_BARREN=$((10#$MAX_BARREN))` in the `10#` block:

```bash
MAX_SKIPPED=$((10#$MAX_SKIPPED))
```

- [ ] **Step 7: Refuse a value that cannot bound anything**

After the `MAX_BARREN` minimum check block:

```bash
if [[ "$MAX_SKIPPED" -lt 1 ]]; then
  echo "ERROR: --max-skipped must be at least 1, got '$MAX_SKIPPED'" >&2
  exit 2
fi
```

- [ ] **Step 8: Add the stop condition**

In the walk loop, after the `BARREN` check block at ~line 664:

```bash
  if [[ "$REFUSED" -ge "$MAX_SKIPPED" ]]; then
    STOP_REASON="the I/O pressure gate refused ${MAX_SKIPPED} passes in a row (the host was too busy to start one)"
    break
  fi
```

- [ ] **Step 9: Show the bound in the banner**

The banner line:

```bash
  echo "Mode: APPLYING (up to ${MAX_PASSES} pass(es), ${MAX_HOURS}h, stop after ${MAX_BARREN} fruitless)"
```

becomes:

```bash
  echo "Mode: APPLYING (up to ${MAX_PASSES} pass(es), ${MAX_HOURS}h, stop after ${MAX_BARREN} fruitless or ${MAX_SKIPPED} refused)"
```

- [ ] **Step 10: Say what a refusal stop means**

After the existing `pass budget`/`cleared the mark` closing notes, before the `if [[ "$STOP_REASON" == *"no progress"* ]]` block at ~line 721, add:

```bash
if [[ "$STOP_REASON" == *"pressure gate refused"* ]]; then
  echo ""
  echo "No pass ran at all: the I/O pressure gate refused every one, which means the"
  echo "pool read as stalled each time it was asked. That is the host protecting"
  echo "itself, not a stuck drain -- check /proc/pressure/io (full avg10) and run"
  echo "this again when it is quieter."
fi
```

- [ ] **Step 11: Document the flag in the header**

In the header, after the usage example line `#   ./scripts/usenet-drain-walk.sh --apply --report-dry-run`, add:

```bash
#   ./scripts/usenet-drain-walk.sh --apply --max-skipped 3
```

Then replace the five-line stop-reasons paragraph:

```bash
# It runs in the foreground and stops for one of five reasons, each printed and
# logged when it happens: the outbox dropped below the high-water mark (the
# point at which the producers start running again), --max-passes was reached,
# --max-hours elapsed, --max-barren passes in a row made no progress, or someone
# interrupted it.
```

with:

```bash
# It runs in the foreground and stops for one of six reasons, each printed and
# logged when it happens: the outbox dropped below the high-water mark (the
# point at which the producers start running again), --max-passes was reached,
# --max-hours elapsed, --max-barren passes in a row made no progress, the I/O
# pressure gate refused --max-skipped passes in a row, or someone interrupted
# it. The refused case is deliberately not folded into the barren one: a pass
# the gate refused never started, so it says the host was busy, not that the
# drain is stuck.
```

- [ ] **Step 12: Re-derive and update the help range**

Run: `awk 'NR >= 3 && /^#/ { n = NR } /^SCRIPT_DIR=/ { print n; exit }' scripts/usenet-drain-walk.sh`
Expected: `86` — four lines more than Step 12 of Task 2 left it at (one usage example, and the stop-reasons paragraph growing from five lines to eight). If the number printed is not 86, use the number it prints: the derivation is authoritative, and Step 13's derived-range test asserts the outcome rather than the value.

Update the range in the `--help` case to match, e.g. `sed -n '3,86p' "$0" | sed 's/^# \{0,1\}//'`.

- [ ] **Step 13: Run the tests to verify they pass**

Run: `TMPDIR="$PWD/.tmp-bats" tests/bats-core/bin/bats tests/usenet-drain-walk.bats`
Expected: 21 tests, all `ok` (16 to begin with, one from Task 1, two from Task 2, two here). The derived-range test from Task 2 is what proves Step 12 landed.

- [ ] **Step 14: Document it for the operator**

In `docs/MAINTENANCE.md`, in the "Walking the queue down with a watchdog" section, replace the third bullet:

```markdown
- after each pass, whether the drain got anywhere at all. Four passes in a row
  that did not end the walk.
```

with:

```markdown
- after each pass, whether the drain got anywhere at all. Four passes in a row
  that did not end the walk.
- a pass the I/O pressure gate refused is **not** counted among those four. It
  never started, so it is evidence about the host, not the drain. Six refusals
  in a row (`--max-skipped`) end the walk on their own reason instead, which
  means a saturated pool reports itself rather than reading as a stuck queue.
```

- [ ] **Step 15: Commit**

```bash
git add scripts/usenet-drain-walk.sh tests/usenet-drain-walk.bats docs/MAINTENANCE.md
git commit -m "usenet-drain-walk: a saturated host gets its own stop reason

Six refusals in a row now end the walk saying the I/O pressure gate refused
every pass, instead of '4 passes in a row made no progress' -- a sentence about
a drain that stopped moving, printed for passes that never started. --max-skipped
makes the bound a flag because the value is a guess: 6 skip-cooldowns is half an
hour of a host too busy to start a pass, against a measured worst streak of 2."
```

---

## Task 4: The summary counts the passes the gate refused

**Files:**
- Modify: `scripts/usenet-drain-walk.sh` (the walk-section init at ~line 640 and the summary line at ~line 705)
- Test: `tests/usenet-drain-walk.bats`

**Interfaces:**
- Consumes: `REFUSED` from Task 1.
- Produces: `REFUSED_TOTAL`, an integer, the number of refusals across the whole run (never reset). Task 5 does not depend on it.

- [ ] **Step 1: Write the failing test**

Add this helper to `tests/usenet-drain-walk.bats` immediately after `write_refused_pass()` from Task 1:

```bash
# Refused on the first invocation, productive afterwards: the shape of a host
# that was busy and then was not.
write_refused_then_productive_pass() {
    cat > "$WORK/scripts/usenet-blackhole.sh" <<'EOS'
#!/bin/bash
echo "pass $$ invoked: $*" >> "$STUB_PASS_CALLS"
if [[ "$(wc -l < "$STUB_PASS_CALLS" | tr -d ' ')" -eq 1 ]]; then
    echo "[pressure-gate] host I/O is stalled (io full avg10=88.00%, limit 20%); skipping this pass"
    exit 0
fi
rm -f "$(ls -1 "$STUB_NZB"/*.nzb 2>/dev/null | head -n 1)" 2>/dev/null || true
echo "  submitted 0, fetched 1, outstanding 4 (1 owed local I/O, 3 still at TorBox)"
EOS
    chmod +x "$WORK/scripts/usenet-blackhole.sh"
}
```

Then add this test immediately after the test added in Task 3:

```bash
@test "usenet-drain-walk: the summary counts the passes the gate refused" {
    seed_outbox 12
    write_refused_then_productive_pass
    run "$RUN" --apply --poll 1 --pass-stall 60 --max-passes 2 --max-barren 4 \
        --max-skipped 4 --skip-cooldown 1 --cooldown 1
    # Two attempts, one of which never ran. The count is the difference between
    # reading "12 passes" and knowing that four of them were the host saying no.
    assert_output --partial "1 refused by the pressure gate"
    # An admitted pass clears the streak, so a host that recovers is not stood
    # down for refusals it has already made up for.
    refute_output --partial "pressure gate refused 4 passes in a row"
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `TMPDIR="$PWD/.tmp-bats" tests/bats-core/bin/bats tests/usenet-drain-walk.bats --filter "summary counts"`
Expected: FAIL on `1 refused by the pressure gate`.

- [ ] **Step 3: Add the cumulative counter**

In the walk-section init block, add below the `REFUSED=0` line added in Task 1:

```bash
# Every refusal in the run, never reset: REFUSED answers "is the host still too
# busy", this answers "how much of this run was the host saying no". The summary
# needs the second one.
REFUSED_TOTAL=0
```

- [ ] **Step 4: Increment it**

In the refusal branch of the post-pass block, add a line:

```bash
  if [[ "$PASS_SKIPPED" == "true" ]]; then
    REFUSED=$((REFUSED + 1))
    REFUSED_TOTAL=$((REFUSED_TOTAL + 1))
    log "the pressure gate refused pass ${PASS_NUMBER} (${REFUSED} in a row); the host read as too busy to start it"
```

- [ ] **Step 5: Print it in the summary**

The summary line:

```bash
log "passes run: ${PASS_NUMBER} (${BARREN} in a row with no progress at the end)"
```

becomes:

```bash
log "passes run: ${PASS_NUMBER} (${REFUSED_TOTAL} refused by the pressure gate, ${BARREN} in a row with no progress at the end)"
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `TMPDIR="$PWD/.tmp-bats" tests/bats-core/bin/bats tests/usenet-drain-walk.bats --filter "summary counts"`
Expected: PASS.

- [ ] **Step 7: Run the whole file**

Run: `TMPDIR="$PWD/.tmp-bats" tests/bats-core/bin/bats tests/usenet-drain-walk.bats`
Expected: 22 tests, all `ok`.

- [ ] **Step 8: Commit**

```bash
git add scripts/usenet-drain-walk.sh tests/usenet-drain-walk.bats
git commit -m "usenet-drain-walk: the summary says how many passes never ran

passes run: 12 (4 refused by the pressure gate, 0 in a row with no progress at
the end) is the line that would have made the 2026-09-22 run readable without
cross-referencing the pass log by hand."
```

---

## Task 5: Proof the separation can fail

**Files:**
- Modify: `tests/mutation/corpus/usenet-drain-walk.sh`
- Test: the corpus entry runs `tests/usenet-drain-walk.bats`

**Interfaces:**
- Consumes: the test name from Task 1, verbatim: `usenet-drain-walk: a pass the pressure gate refused is not a barren pass`.
- Produces: nothing at runtime.

- [ ] **Step 1: Add the corpus entry**

Append to `tests/mutation/corpus/usenet-drain-walk.sh`:

```bash
# --- a refusal counted against the drain again ------------------------------

mutation usenet-drain-walk-refusal-counted-as-barren \
  --file scripts/usenet-drain-walk.sh \
  --bats tests/usenet-drain-walk.bats \
  --test "usenet-drain-walk: a pass the pressure gate refused is not a barren pass" \
  --why "the increment lands on BARREN instead of REFUSED, which is the defect this branch removed: a pass the gate refused never started, so it says nothing about whether the drain is moving. With --max-barren 1 the walk then stops after a single attempt, and on the real 2026-09-22 run it printed '4 passes in a row made no progress' for four passes that never ran -- the sentence an operator reads first, and the one that sends them to look at the queue instead of the host" \
  --apply 'sed -i.bak "s@REFUSED=\$((REFUSED + 1))@BARREN=\$((BARREN + 1))@" "$F" && rm -f "$F.bak"'
```

Do **not** put backticks or `$` in the `--why` text: this file is sourced by the harness, so a backtick runs a command and an unescaped `$` expands at source time. (Both have bitten this corpus before.)

- [ ] **Step 2: Run the harness for this corpus**

Run: `TMPDIR="$PWD/.tmp-bats" /opt/homebrew/bin/bash ./tests/mutation/run-mutations.sh tests/mutation/corpus/usenet-drain-walk.sh`
Expected: `KILLED usenet-drain-walk-refusal-counted-as-barren (1 test(s))`, and the tail reads `killed 3 / 3   survived 0   errored 0   skipped 0` with no `hit the oracle budget` note. On Linux use `bash` rather than `/opt/homebrew/bin/bash`; the harness needs bash 4+ for `BASHPID`.

- [ ] **Step 3: If it reports SURVIVED or a budget hit**

SURVIVED means the new test passes with `REFUSED` incremented as `BARREN` — read the test and check it asserts the invocation count, because that is the assertion the mutation breaks. A budget hit means the oracle hung; the test's stub writes to `$STUB_PASS_CALLS` and sleeps only via the walk's own cooldowns, so check `--skip-cooldown 1` is present.

- [ ] **Step 4: Commit**

```bash
git add tests/mutation/corpus/usenet-drain-walk.sh
git commit -m "tests: prove the refusal/barren split can fail

The mutation puts the increment back on BARREN, which is the branch this work
removed, and requires the new test to go red."
```

---

## Task 6: Verify on the NAS, then land it

**Files:** none modified. This task is the deploy gate `CLAUDE.md` requires.

**Interfaces:**
- Consumes: everything above, committed on a feature branch.
- Produces: `main` carrying the change, and a NAS checked out on `main`.

- [ ] **Step 1: Push the branch**

```bash
git checkout -b fix/drain-walk-gate-refusals
git push -u origin fix/drain-walk-gate-refusals
```

- [ ] **Step 2: Sync it to the NAS**

```bash
./scripts/sync-nas.sh
```

Expected: `sync-nas: verified arr-stack-nas is on fix/drain-walk-gate-refusals @ <sha>.`

- [ ] **Step 3: Exercise the new path with the gate forced closed**

`PSI_IO_LIMIT` is read from the environment by `scripts/usenet-blackhole.sh`, and its comparison is `seen >= limit`. Setting it to 0 makes every pass be refused, so this runs the exact new code path with **no TorBox call, no download, and no pass I/O** — the safe way to see a saturated-host stop on demand.

```bash
ssh arr-stack-nas 'cd /volume1/docker/arr-stack && PSI_IO_LIMIT=0 ./scripts/usenet-drain-walk.sh --apply --max-passes 6 --max-barren 4 --max-skipped 2 --skip-cooldown 1; echo "EXIT: $?"'
```

Expected, and all of it is the assertion:
- `pass 1/6: --apply --max-inflight 6` and `pass 2/6: ...`, then a stop;
- `pass 1: refused by the I/O pressure gate` twice;
- `stopped: the I/O pressure gate refused 2 passes in a row (the host was too busy to start one)`;
- `EXIT: 3`;
- `[pressure-gate] host I/O is stalled (io full avg10=..., limit 0%); skipping this pass` in the pass output;
- and `passes run: 2 (2 refused by the pressure gate, 0 in a row with no progress at the end)`, which is Task 4's line.

- [ ] **Step 4: Clean up what the forced test wrote**

Each refusal appends a line to `logs/usenet-blackhole-skipped.log`, the sidecar `usenet.lan` reads as "N passes skipped in a row". Two synthetic lines would be served as fact until the next real pass.

```bash
ssh arr-stack-nas 'rm -f /volume1/docker/arr-stack/logs/usenet-blackhole-skipped.log && echo removed'
```

- [ ] **Step 5: Confirm the normal path still reads the live queue**

```bash
ssh arr-stack-nas 'cd /volume1/docker/arr-stack && ./scripts/usenet-drain-walk.sh'
```

Expected: `Mode: DRY RUN`, the new banner text `stop after 4 fruitless or 6 refused`, the four resolved paths, `Outbox now: <n> NZBs`, and it exits 0 without running a pass. No `--apply`, so nothing is fetched.

- [ ] **Step 6: Open the PR and wait for CI**

```bash
gh pr create --fill
gh pr checks --watch
```

Expected: `bats suite`, `mutation guards for this change`, `supply chain (trivy and sbom)` and `workflow and terraform lint` all `pass`. The bats job is the one that runs the shellcheck and inventory guards; a new *script* would fail the two inventory tests, and this change adds none, so their passing is also evidence no file was created by accident.

- [ ] **Step 7: Merge and return the NAS to main**

```bash
gh pr merge <n> --squash
git fetch origin main && git checkout main && git merge --ff-only origin/main
./scripts/sync-nas.sh
```

Expected: `sync-nas: verified arr-stack-nas is on main @ <sha>.` A NAS left on a feature branch is indistinguishable from a deployed one, so this step is not optional.

- [ ] **Step 8: Confirm the NAS is where you left it**

```bash
ssh arr-stack-nas 'cd /volume1/docker/arr-stack && docker run --rm -v /volume1/docker/arr-stack:/repo -w /repo alpine/git -c safe.directory=/repo rev-parse --abbrev-ref HEAD; XDG_RUNTIME_DIR=/run/user/1000 systemctl --user is-active usenet-blackhole.timer'
```

Expected: `main`, then `inactive` — the ingest stays held down, which this plan must not change.

---

## How this plan covers the requirement

| Requirement | Where |
| --- | --- |
| A refused pass must not read as a stalled drain | Task 1 |
| A saturated host must stop the walk with its own reason | Task 3 |
| The bound for that must be tunable without editing the script | Task 3 (`--max-skipped`) |
| The operator must be able to see how much of a run never ran | Task 4 |
| The new behaviour must be provably testable | Task 1 and Task 5 |
| The operator documentation must match | Task 3, Step 14 |
| `--help` must not silently truncate the header it prints | Task 2 |
| Nothing ships untested to `main` | Task 6 |
