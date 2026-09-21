# User timers survive reboot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpower-subagent-driven-development (recommended) or superpower-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the eight `--user` timers actually arm after a reboot, and make the boot where they do not impossible to miss.

**Architecture:** The user manager starts before the volumes are usable, so it never loads `~/.config/systemd/user/`, so `timers.target` comes up active and empty and every timer stays inactive while `is-enabled` cheerfully reports each one enabled. Two facts were measured on the NAS before this plan was written: `systemctl --user daemon-reload` makes all eight visible, and **none of them then starts** — they need `timers.target` started too. This plan ships the remedy as an idempotent script, a diagnostic that detects the state without needing the user manager at all, and the procedure. It deliberately does not install a system unit; see Task 3 for why, and for the option if the operator wants one.

**Tech Stack:** Bash 3.2-compatible shell (macOS is a supported host), bats-core + bats-assert, systemd 252 user units.

**Spec:** `docs/NAS-LOAD-INCIDENT-2026-09-18.md` and the **Evidence** section below. The companion plan for the ingest path is `docs/superpowers/plans/2026-09-19-usenet-inflight-brake-and-queue.md`; it is a separate subsystem and neither plan depends on the other.

---

## Evidence

Measured on the NAS, 2026-09-19, on the boot that began 00:04:35.

| Measurement | Value |
| --- | --- |
| boot | 2026-09-19 00:04:35 |
| `user@1000.service` active | 00:05:06 (31 s after boot) |
| `home.mount` active per systemd | 00:05:36 (61 s after boot) |
| `systemd-analyze critical-chain user@1000.service` | `user@1000.service` ← `systemd-user-sessions.service` ← `home.mount` ← `dev-mapper-…volume1.device` |
| Timers loaded by the user manager at boot | 0 of 8, then 2 of 8 some hours later — never all 8 |
| After `systemctl --user daemon-reload` | all 8 listed |
| After that reload, scheduled (`NEXT` set) | **none** — they are known but not started |
| `linger` for leoleg | `yes` |
| `timers.target` | active — and empty |
| `is-enabled` for every timer | `enabled`; the `timers.target.wants/` symlinks are all intact |
| leoleg can write `/etc/systemd/system` | **NO** |
| leoleg `sudo` without a password | **NO** |
| leoleg's crontab | unusable (`crontabs/leoleg/: fopen: Permission denied`) |
| `systemctl --user --machine=leoleg@.host` | works |
| Repo's own note, `scripts/boot-compose-up.service` | "UGOS mounts /volume1 outside systemd's view early in boot, so the only reliable test is the file itself" |

The critical chain is misleading and should not be trusted here: it shows `home.mount` ordered before `user@1000.service`, yet the timestamps put `user@1000.service` 30 seconds *earlier*. UGOS mounts the volumes outside systemd's view, so `home.mount`'s activation time is a late discovery, not the mount. That is why the repo's existing boot unit polls for a file rather than ordering on a mount unit, and why this plan does the same.

## Global Constraints

- The test entry point is `./tests/run-tests.sh`, never `npm test`. `npm` does not exist on pi1 or on the NAS.
- Every new or changed guard needs an entry in `tests/mutation/corpus/`, and `./tests/mutation/run-mutations.sh` must show the named test going red against it. A guard that cannot fail is worse than no guard.
- Shell scripts must stay compatible with bash 3.2 (`/bin/bash` on macOS): expand possibly-empty arrays as `${arr[@]+"${arr[@]}"}` under `set -u`, and never put a literal space in an unquoted `=~` pattern.
- A bare `sed -i "…"` in a mutation `--apply` edits NOTHING under BSD sed. Always `sed -i.bak "…" "$F" && rm -f "$F.bak"`. `./tests/mutation/run-mutations.sh` needs bash 5 on macOS — invoke it as `/opt/homebrew/bin/bash ./tests/mutation/run-mutations.sh`.
- No change reaches `main` before it is verified on the NAS. `main` is protected; land work through a PR.
- The installed copies of the user units under `~/.config/systemd/user/` are plain copies, not symlinks, so the repo copy and the installed copy can drift and nothing will say so.
- **`tests/systemd-units.bats` asserts that the units in `scripts/` carry no root/system-install assumptions: zero occurrences of `/etc/systemd`, zero `WantedBy=multi-user.target`, zero `User=`.** Do not break that. It exists because a wrong "timers need root" belief was carried for most of a session before being re-tested and disproved.

---

### Task 1: The remedy, as a script

`daemon-reload` alone is not enough and that is the trap. Measured: after a reload all eight timers are *listed* and **none is scheduled**, because reloading unit files does not start anything. A remedy that stops at the reload looks like it worked — `list-timers --all` prints eight lines — while every timer stays inactive. This task ships the full sequence, with a verification step that fails when the timers are known but not armed.

**Files:**
- Create: `scripts/rearm-user-timers.sh`
- Create: `tests/rearm-user-timers.bats`
- Create: `tests/mutation/corpus/rearm-user-timers.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `scripts/rearm-user-timers.sh`, exiting **0** when every `*.timer` in the unit directory is active afterwards, **1** when the unit directory never appeared, and **1** when any timer is still inactive. Environment overrides, all read by the script only: `REARM_UNIT_DIR` (default `$HOME/.config/systemd/user`), `REARM_SYSTEMCTL` (default `systemctl`), `REARM_TIMEOUT_SECONDS` (default `600`), `REARM_POLL_SECONDS` (default `5`). Task 2's diagnostic is independent of this script and shares no symbols with it.

- [ ] **Step 1: Write the failing tests**

Create `tests/rearm-user-timers.bats`:

```bash
#!/usr/bin/env bats
# scripts/rearm-user-timers.sh -- re-arm the user timers after a boot that
# missed them.
#
# On the 2026-09-19 boot the user manager started at 00:05:06 and home.mount
# was not active until 00:05:36, so the manager never loaded
# ~/.config/systemd/user/ and timers.target came up active and empty. All eight
# timers were inactive for the next eleven hours while `is-enabled` reported
# every one of them as enabled.
#
# The trap this file exists to pin: daemon-reload makes them VISIBLE and starts
# nothing. A remedy that stops there prints eight lines of list-timers output
# and leaves every timer dead.

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init
    SCRIPT="$REPO_ROOT/scripts/rearm-user-timers.sh"
    WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK/units"
    export REARM_UNIT_DIR="$WORK/units"
    export REARM_POLL_SECONDS=1
    export REARM_TIMEOUT_SECONDS=3
    # Every systemctl call is recorded; ACTIVE_FILE decides what is-active says.
    export REARM_SYSTEMCTL=systemctl
    export ACTIVE_FILE="$WORK/active"
    export STUB_LOG="$WORK/stub.log"
    : > "$ACTIVE_FILE"
    stub_tool systemctl '
        printf "%s\n" "$*" >> "$STUB_LOG"
        case "$1" in
            --user) shift ;;
        esac
        # The unit name is the LAST argument, not $2: the script asks
        # `is-active --quiet <name>`, so $2 is the flag. Taking $2 here would
        # test "--quiet" against ACTIVE_FILE and fail every timer.
        last=""
        for a in "$@"; do last="$a"; done
        case "$1" in
            daemon-reload) exit 0 ;;
            start) exit 0 ;;
            is-active)
                grep -qx "$last" "$ACTIVE_FILE" && exit 0 || exit 3 ;;
        esac
        exit 0
    '
    RUN="$SCRIPT"
}

mark_active() { printf '%s\n' "$1" >> "$ACTIVE_FILE"; }

@test "rearm: reloads before starting, and starts timers.target" {
    # The order is the fix. Reload first or the units are not loaded; start
    # second or they are loaded and still dead.
    : > "$WORK/units/queue-cleanup.timer"
    mark_active "queue-cleanup.timer"
    run env "PATH=$STUB_DIR:$PATH" "$RUN"
    assert_success
    run grep -n "daemon-reload" "$STUB_LOG"
    assert_success
    reload_line="${output%%:*}"
    run grep -n "start timers.target" "$STUB_LOG"
    assert_success
    start_line="${output%%:*}"
    [ "$reload_line" -lt "$start_line" ]
}

@test "rearm: fails when a timer is visible but not armed" {
    # Exactly the state a reload-only remedy leaves behind.
    : > "$WORK/units/queue-cleanup.timer"
    run env "PATH=$STUB_DIR:$PATH" "$RUN"
    assert_failure
    assert_output --partial "queue-cleanup.timer"
}

@test "rearm: fails when the unit directory never appears" {
    # A boot where /home never mounts must not read as success. An absent
    # oracle and a passing oracle must not be the same observable result.
    run env "PATH=$STUB_DIR:$PATH" "$RUN"
    assert_failure
    assert_output --partial "never appeared"
    run grep -c "daemon-reload" "$STUB_LOG"
    assert_output "0"
}

@test "rearm: every timer present is checked, not just the first" {
    : > "$WORK/units/queue-cleanup.timer"
    : > "$WORK/units/indexer-guard.timer"
    mark_active "queue-cleanup.timer"
    run env "PATH=$STUB_DIR:$PATH" "$RUN"
    assert_failure
    assert_output --partial "indexer-guard.timer"
}

@test "rearm: is idempotent, and succeeds when everything is armed" {
    : > "$WORK/units/queue-cleanup.timer"
    : > "$WORK/units/indexer-guard.timer"
    mark_active "queue-cleanup.timer"
    mark_active "indexer-guard.timer"
    run env "PATH=$STUB_DIR:$PATH" "$RUN"
    assert_success
    run env "PATH=$STUB_DIR:$PATH" "$RUN"
    assert_success
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/run-tests.sh tests/rearm-user-timers.bats`

Expected: FAIL on all five — the script does not exist, so `run` returns status 127 and the file is not found.

- [ ] **Step 3: Write the script**

Create `scripts/rearm-user-timers.sh`:

```bash
#!/bin/bash
set -euo pipefail
#
# Re-arm the arr-stack user timers after a boot that missed them.
#
# Usage:
#   ./scripts/rearm-user-timers.sh
#   REARM_TIMEOUT_SECONDS=120 ./scripts/rearm-user-timers.sh
#
# Exit status:
#   0  every *.timer in the unit directory is active afterwards
#   1  the unit directory never appeared within REARM_TIMEOUT_SECONDS, or a
#      timer is still inactive. Never 0 for either: a remedy that cannot tell
#      "armed" from "still dead" is the failure this exists to remove.
#
# WHY THE TWO STEPS, IN THIS ORDER
#
# The user manager starts before the volumes are usable. Measured on
# 2026-09-19: user@1000.service became active at 00:05:06 while home.mount
# became active at 00:05:36, so the manager read ~/.config/systemd/user/ before
# /home existed, loaded nothing, and activated timers.target empty. All eight
# timers stayed inactive for eleven hours while `systemctl --user is-enabled`
# reported every one of them as enabled and the symlinks in
# timers.target.wants/ were all intact -- the disk state was never wrong.
#
#   daemon-reload   makes the unit files visible to the running manager.
#   start timers.target   actually arms them. Reloading unit files does not
#                   start anything, and this is the step that is easy to omit:
#                   after a reload `list-timers --all` prints all eight, which
#                   reads like success, while every NEXT column says "-".
#
# UGOS mounts the volumes outside systemd's view, so ordering on home.mount is
# not the answer -- the repo's own boot-compose-up.service polls for the file
# for the same reason. This does too.

UNIT_DIR="${REARM_UNIT_DIR:-$HOME/.config/systemd/user}"
SYSTEMCTL="${REARM_SYSTEMCTL:-systemctl}"
TIMEOUT_SECONDS="${REARM_TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${REARM_POLL_SECONDS:-5}"

# Wait for the unit files to exist at all. A boot where /home never mounts
# leaves this directory absent, and that must not read as "nothing to do".
waited=0
while ! compgen -G "$UNIT_DIR/*.timer" >/dev/null 2>&1; do
    if [[ "$waited" -ge "$TIMEOUT_SECONDS" ]]; then
        echo "ERROR: $UNIT_DIR never appeared after ${TIMEOUT_SECONDS}s; the user timers cannot be armed" >&2
        exit 1
    fi
    sleep "$POLL_SECONDS"
    waited=$(( waited + POLL_SECONDS ))
done

echo "unit directory ready after ${waited}s: $UNIT_DIR"

"$SYSTEMCTL" --user daemon-reload
"$SYSTEMCTL" --user start timers.target

inactive=()
for unit in "$UNIT_DIR"/*.timer; do
    name="$(basename "$unit")"
    if ! "$SYSTEMCTL" --user is-active --quiet "$name"; then
        inactive+=("$name")
    fi
done

if [[ ${#inactive[@]} -gt 0 ]]; then
    echo "ERROR: ${#inactive[@]} timer(s) are still inactive after the reload and start:" >&2
    printf '  %s\n' "${inactive[@]}" >&2
    echo "Loaded is not armed. Check: $SYSTEMCTL --user list-timers --all" >&2
    exit 1
fi

echo "all timers active"
```

Then `chmod +x scripts/rearm-user-timers.sh`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run-tests.sh tests/rearm-user-timers.bats`

Expected: PASS on all five.

- [ ] **Step 5: Add the mutation corpus entries**

Create `tests/mutation/corpus/rearm-user-timers.sh`:

```bash
# shellcheck shell=bash
# Corpus: scripts/rearm-user-timers.sh
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)

# --- the two-step remedy --------------------------------------------------

mutation rearm-skips-the-start \
  --file scripts/rearm-user-timers.sh \
  --bats tests/rearm-user-timers.bats \
  --test "rearm: fails when a timer is visible but not armed" \
  --why "dropping the start leaves the state measured on 2026-09-19: all eight timers visible after a reload and none scheduled, which list-timers prints as eight lines and reads like success" \
  --apply 'sed -i.bak "s@\"\$SYSTEMCTL\" --user start timers.target@true@" "$F" && rm -f "$F.bak"'

mutation rearm-skips-the-reload \
  --file scripts/rearm-user-timers.sh \
  --bats tests/rearm-user-timers.bats \
  --test "rearm: reloads before starting, and starts timers.target" \
  --why "without the reload the manager has never seen the unit files, so starting timers.target arms nothing" \
  --apply 'sed -i.bak "s@\"\$SYSTEMCTL\" --user daemon-reload@true@" "$F" && rm -f "$F.bak"'

mutation rearm-ignores-inactive-timers \
  --file scripts/rearm-user-timers.sh \
  --bats tests/rearm-user-timers.bats \
  --test "rearm: fails when a timer is visible but not armed" \
  --why "a remedy that reports success without checking is the silent failure this whole plan exists to remove; the check is what separates reloaded from armed" \
  --apply 'sed -i.bak "s@if ! \"\$SYSTEMCTL\" --user is-active --quiet \"\$name\"; then@if false; then@" "$F" && rm -f "$F.bak"'

mutation rearm-passes-on-missing-unit-dir \
  --file scripts/rearm-user-timers.sh \
  --bats tests/rearm-user-timers.bats \
  --test "rearm: fails when the unit directory never appears" \
  --why "treating an absent unit directory as nothing-to-do makes a boot where /home never mounted indistinguishable from a healthy one" \
  --apply 'sed -i.bak "s@        exit 1@        exit 0@" "$F" && rm -f "$F.bak"'
```

- [ ] **Step 6: Prove the corpus entries can fail their tests**

Run: `/opt/homebrew/bin/bash ./tests/mutation/run-mutations.sh -k rearm`

Expected: killed 4/4, survived 0. `rearm-passes-on-missing-unit-dir` is the one to watch: its `sed` targets the first `        exit 1` in the file, so confirm the runner reports the file actually changed before trusting a KILLED verdict.

- [ ] **Step 7: Commit**

```bash
git add scripts/rearm-user-timers.sh tests/rearm-user-timers.bats tests/mutation/corpus/rearm-user-timers.sh
git commit -m "fix(systemd): re-arm the user timers after a boot that missed them"
```

---

### Task 2: A diagnostic that works without the user manager

The remedy needs to be *run*, and nothing will run it. Everything reliable on this box is a container, and a container cannot see the user manager without the session D-Bus. But it can see files, and the timers leave files: `usenet-status-render.timer` rewrites `logs/usenet-status/index.html` every two minutes, and `queue-cleanup.timer` appends to `logs/queue-cleanup.log` hourly. If those are stale, the timers are dead — no D-Bus, no root, no user manager required. This is the signal that breaks the silence.

**Files:**
- Create: `scripts/check-user-timers.sh`
- Create: `tests/check-user-timers.bats`
- Create: `tests/mutation/corpus/check-user-timers.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `scripts/check-user-timers.sh`, exiting **0** when the freshest artifact is within its window, **1** when it is stale (the timers are not running) and **1** when no artifact exists at all. Environment overrides: `STACK_DIR` (default `/volume1/docker/arr-stack`), `TIMER_FRESH_MINUTES` (default `15`). It shares no symbols with Task 1.

- [ ] **Step 1: Write the failing tests**

Create `tests/check-user-timers.bats`:

```bash
#!/usr/bin/env bats
# scripts/check-user-timers.sh -- detect dead user timers from their artifacts.
#
# The 2026-09-19 boot left all eight timers inactive for eleven hours and
# nothing said so. Anything that could have noticed runs in a container, and a
# container cannot reach the session D-Bus; but the timers write files, and a
# stale file is observable from anywhere.

setup() {
    load helpers/setup
    SCRIPT="$REPO_ROOT/scripts/check-user-timers.sh"
    WORK="$BATS_TEST_TMPDIR/stack"
    mkdir -p "$WORK/logs/usenet-status"
    export STACK_DIR="$WORK"
    RUN="$SCRIPT"
}

touch_fresh() { : > "$WORK/logs/usenet-status/index.html"; }
touch_stale()  { : > "$WORK/logs/usenet-status/index.html"; touch -t 202001010000 "$WORK/logs/usenet-status/index.html"; }

@test "check-user-timers: a fresh artifact means the timers are alive" {
    touch_fresh
    run "$RUN"
    assert_success
    assert_output --partial "timers are running"
}

@test "check-user-timers: a stale artifact means they are dead" {
    touch_stale
    run "$RUN"
    assert_failure
    assert_output --partial "rearm-user-timers.sh"
}

@test "check-user-timers: no artifact at all is a failure, not a pass" {
    # An absent oracle and a passing oracle must not be the same observable
    # result -- the rule this repo has been bitten by more than once.
    run "$RUN"
    assert_failure
    assert_output --partial "no artifact"
}

@test "check-user-timers: the freshness window is configurable" {
    touch_stale
    run env TIMER_FRESH_MINUTES=99999999 "$RUN"
    assert_success
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./tests/run-tests.sh tests/check-user-timers.bats`

Expected: FAIL on all four — status 127, the script does not exist.

- [ ] **Step 3: Write the script**

Create `scripts/check-user-timers.sh`:

```bash
#!/bin/bash
set -euo pipefail
#
# Report whether the arr-stack user timers are actually running, by checking
# the freshness of what they produce.
#
# Usage:
#   ./scripts/check-user-timers.sh
#   TIMER_FRESH_MINUTES=60 ./scripts/check-user-timers.sh
#
# Exit status:
#   0  the freshest artifact is within the window -- the timers are running
#   1  it is stale, or there is no artifact at all
#
# WHY NOT ASK SYSTEMD
#
# `systemctl --user list-timers` answers this directly, and needs the session
# D-Bus, which nothing that runs unattended on this box can reach: every
# always-on process here is a container, and the user manager is only reachable
# from a login session. The timers write files, though, and a stale file is
# observable from anywhere -- including from a container that has /volume1
# mounted.
#
# usenet-status-render.timer rewrites its page every two minutes, so it is the
# fastest-moving artifact and the one worth watching. 15 minutes is seven of
# its cycles: long enough that a slow box is not a false alarm, short enough
# that a reboot is noticed the same morning.

STACK_DIR="${STACK_DIR:-/volume1/docker/arr-stack}"
FRESH_MINUTES="${TIMER_FRESH_MINUTES:-15}"
ARTIFACT="$STACK_DIR/logs/usenet-status/index.html"

if [[ ! -e "$ARTIFACT" ]]; then
    echo "FAIL: no artifact at $ARTIFACT, so the user timers have never run (or the stack has never rendered a status page)" >&2
    echo "      Remediation: /volume1/docker/arr-stack/scripts/rearm-user-timers.sh" >&2
    exit 1
fi

if [[ -n "$(find "$ARTIFACT" -mmin -"$FRESH_MINUTES" 2>/dev/null)" ]]; then
    echo "OK: timers are running (last render within ${FRESH_MINUTES}m)"
    exit 0
fi

echo "FAIL: the user timers are not running -- $ARTIFACT has not been rewritten in ${FRESH_MINUTES}m." >&2
echo "      This is the state every reboot produced before the /home race was understood: the unit files are on disk, is-enabled says enabled, and the manager never loaded them." >&2
echo "      Remediation: /volume1/docker/arr-stack/scripts/rearm-user-timers.sh" >&2
exit 1
```

Then `chmod +x scripts/check-user-timers.sh`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./tests/run-tests.sh tests/check-user-timers.bats`

Expected: PASS on all four.

- [ ] **Step 5: Add the mutation corpus entries**

Create `tests/mutation/corpus/check-user-timers.sh`:

```bash
# shellcheck shell=bash
# Corpus: scripts/check-user-timers.sh
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)

mutation check-timers-never-fails \
  --file scripts/check-user-timers.sh \
  --bats tests/check-user-timers.bats \
  --test "check-user-timers: a stale artifact means they are dead" \
  --why "a diagnostic that cannot fail is the silence this exists to break; on 2026-09-19 the timers were dead for eleven hours and nothing said so" \
  --apply 'sed -i.bak "s@^exit 1\$@exit 0@" "$F" && rm -f "$F.bak"'

mutation check-timers-treats-missing-as-fresh \
  --file scripts/check-user-timers.sh \
  --bats tests/check-user-timers.bats \
  --test "check-user-timers: no artifact at all is a failure, not a pass" \
  --why "an absent artifact reported as healthy makes a stack whose timers never ran indistinguishable from one where they are running" \
  --apply 'sed -i.bak "s@if \[\[ ! -e \"\$ARTIFACT\" \]\]; then@if false; then@" "$F" && rm -f "$F.bak"'
```

- [ ] **Step 6: Prove the corpus entries can fail their tests**

Run: `/opt/homebrew/bin/bash ./tests/mutation/run-mutations.sh -k check-timers`

Expected: killed 2/2, survived 0. `check-timers-never-fails` anchors on a bare `^exit 1$`, which occurs more than once — confirm from the runner's output that the file changed, and if it reports an ambiguous or unchanged target, anchor it on the `echo "FAIL: the user timers are not running` line instead.

- [ ] **Step 7: Commit**

```bash
git add scripts/check-user-timers.sh tests/check-user-timers.bats tests/mutation/corpus/check-user-timers.sh
git commit -m "feat(systemd): detect dead user timers from the files they write"
```

---

### Task 3: Write the procedure down, and say what is not automatable

Two things need recording: the post-reboot procedure, and the honest limit — nothing on this box can run the remedy automatically without root, and the operator should know that before assuming a fix exists. This task also decides, explicitly, against shipping a system unit.

**Files:**
- Modify: `docs/MAINTENANCE.md` (a new section beside the existing unit-install instructions)
- Modify: `docs/NAS-LOAD-INCIDENT-2026-09-18.md` (§7, replacing the open item with what is now known)

**Interfaces:**
- Consumes: `scripts/rearm-user-timers.sh` (Task 1) and `scripts/check-user-timers.sh` (Task 2), by name.
- Produces: nothing code-level.

- [ ] **Step 1: Document the procedure**

In `docs/MAINTENANCE.md`, near the existing `cp scripts/*.service scripts/*.timer ~/.config/systemd/user/` instructions, add a section covering, in this order:

1. **After every reboot**, verify: `./scripts/check-user-timers.sh` — exit 0 means running, exit 1 means dead, and the message names the remedy.
2. **If dead**, run `./scripts/rearm-user-timers.sh`. State the two steps it performs and why the order matters: `daemon-reload` makes the units visible, `start timers.target` arms them, and a reload alone leaves all eight listed and none scheduled.
3. **Then verify again** with `systemctl --user list-timers` and confirm the `NEXT` column is set — not just that eight lines are printed.
4. The measured evidence for why this happens: the user manager starts at 00:05:06 on a boot whose volumes are not usable until 00:05:36, so it loads nothing; `is-enabled` and the `timers.target.wants/` symlinks stay correct throughout and are therefore not a useful signal.

- [ ] **Step 2: Record the limit, and the ruling**

In the same section, state plainly:

- **Nothing on this box runs the remedy automatically.** leoleg cannot write `/etc/systemd/system` (verified), has no passwordless `sudo`, and cannot use `crontab` (`crontabs/leoleg/: fopen: Permission denied`). The always-on processes are containers, and a container cannot reach the session D-Bus.
- **Ruling, recorded rather than implied: no system unit is shipped for this.** `tests/systemd-units.bats` asserts the units in `scripts/` carry no root/system-install assumptions, and that guard exists because a wrong "the timers need root" belief was carried for most of a session before being disproved. Shipping a `WantedBy=multi-user.target` unit would reverse a deliberate decision to solve a boot-ordering problem, and it would need root to install on a box where we have none. The cost of this ruling is real and should be written down: **a reboot still leaves the timers dead until someone runs one command**, and if nobody looks, the stack is unmanaged again.
- **The option, if the operator wants it**, stated as an option and not a recommendation: a system unit that runs Task 1's script after the volumes appear, installed once by root, exactly as the macvlan shim was. It is not in this plan because it cannot be tested from here and it contradicts a guard the repo deliberately added.

- [ ] **Step 3: Update the incident record**

In `docs/NAS-LOAD-INCIDENT-2026-09-18.md` §7, replace the open item about the user timers with what is now known: the measured timings, the two-step remedy, the diagnostic, and the fact that it remains manual.

- [ ] **Step 4: Verify the doc links resolve**

Run: `./tests/run-tests.sh tests/lib-doc-links.bats`

Expected: PASS (26 tests). This is the only automated check a document gets in this repo.

- [ ] **Step 5: Commit**

```bash
git add docs/MAINTENANCE.md docs/NAS-LOAD-INCIDENT-2026-09-18.md
git commit -m "docs: the post-reboot timer procedure, and why it is not automatic"
```

---

## Not in this plan

**Automating the re-arm.** It needs root, or a container with the session D-Bus mounted, and both are decisions for the operator rather than this plan. Task 2 removes the silence; Task 3 records the limit. If the operator wants automation, the container route is worth trying before the system-unit route — the stack already runs always-on helper containers (`gluetun-recover`, `deunhealth`), so it would follow an existing pattern, but it needs `/run/user/1000` mounted and a working `systemctl --user` from inside, and neither has been tested.

**The ingest path.** A pass that outlives a sustained I/O stall, and the 516-item backlog, are a separate subsystem with a separate plan: `docs/superpowers/plans/2026-09-19-usenet-inflight-brake-and-queue.md`. Restoring `queue-cleanup` is part of *this* plan's value — it is one of the eight timers — but the drain procedure lives in that one.

**Why `home.mount` activates late.** The root cause is UGOS mounting the volumes outside systemd's view, which the repo already documents in `scripts/boot-compose-up.service`. Fixing that is a NAS-platform question, not a repo one.
