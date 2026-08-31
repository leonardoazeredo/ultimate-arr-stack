# Test & Deploy Hardening — Project Log

Audited record of the hardening pass merged as `86d5fcf` on 2026-09-01
(branch `fix/nas-sync-silent-failure`, six commits, 13 files, +1651/−69).

Read this before changing anything in `scripts/post-merge`, `scripts/sync-nas.sh`,
`scripts/arr-backup.sh`, or `tests/mutation/`. Its value is not the list of fixes —
those are in the diff. It is the record of **which of this repo's guards turned out
to be incapable of failing**, and the traps that produced them, because every one of
them read as coverage right up until it was watched.

---

## 1. Status at a glance

| | |
| --- | --- |
| Merged | `86d5fcf`, 2026-09-01, local merge — the `post-merge` hook fired and synced the NAS |
| pi1 suite | 140 pass / 2 fail — both `jq: command not found`, pre-existing, see §7 |
| NAS suite | **142 / 142** at `main` |
| Mutation corpus | **34 killed / 0 survived / 0 errored** |
| Merge gate | CONTESTED → all findings explicitly accepted or rejected on the record (§6) |
| NAS deploy path | on `main`, verified by reading its branch, not by trusting the hook |

---

## 2. The one defect class

Every bug in this pass is the same shape, and it is worth naming before the list:
**a failure that reports success, or reports the wrong reason.** Not a crash, not a
wrong answer — an `exit 0` and either silence or a cheerful message.

That shape is expensive here specifically because the deploy path is remote. A local
failure gets noticed. A NAS that quietly kept running the old code does not, and the
2026-08-27 outage ran 38 hours on exactly that.

The three stacked deploy bugs are written up in
`docs/TROUBLESHOOTING.md` → *The Deploy Reported Success and Nothing Was Deployed*,
including the check that distinguishes them. Not duplicated here.

---

## 3. Commit-by-commit audit

| Commit | What it changed |
| --- | --- |
| `1c60eb1` | The NAS sync path fails loudly. `sync-nas.sh` no longer `exit 0`s on an unreachable NAS, compares against `origin` before acting, and verifies the **outcome** (NAS branch *and* commit) rather than the exit status of the commands meant to produce it. The `post-merge` hook's `${BASH_SOURCE[0]}` repo-root bug fixed. Mutation framework added. |
| `9156d19` | Every network call in `sync-nas.sh` bounded — `ConnectTimeout=15` on each `ssh`, `timeout 20` on `git ls-remote`. The reachability probe proves the NAS answered *a moment ago*, not that it still will; a bare `ssh` parks on the OS-default connect timeout for ~2 minutes inside a hook that is holding up a merge. |
| `da067a2` | A failed restore in the mutation runner is fatal (exit 3) and keeps the pristine copy, instead of returning 0 and leaving a mutated tree behind. |
| `3f56fd1` | `tests/shellcheck.bats` made capable of running at all (§5.2), and two vacuous-test traps closed. |
| `c479c0d` | Three `scripts/arr-backup.sh` defects (§5.3). |
| `0271c26` | Accepted adversarial-review findings applied. |

---

## 4. The mutation framework, and why it exists

`./tests/mutation/run-mutations.sh` reintroduces a recorded defect into a real file,
asserts the file actually changed, runs the named bats test, and requires it to go
**red**. A mutation that survives means the test cannot fail. Full usage in
`tests/mutation/README.md`.

It is deliberately **not** part of `./tests/run-tests.sh` — it runs the suite twice
per mutation. Run it after touching any guard, and add a corpus entry with any new one.

Corpus: 34 mutations across `corpus/nas-sync.sh` and `corpus/backup-and-guards.sh`.

### What it caught that human review did not

This is the part worth keeping. Each of these was read, by me and by an adversarial
reviewer, and passed.

1. **A guard that could not fail, at all.** `runner-ignores-a-failed-cp` survived.
   The runner checked `cp`'s exit status *and* compared bytes with `cmp`. Belt and
   braces — except every case where a failed `cp` matters is a case where the bytes
   differ, so `cmp` always fires first and the status check is unreachable. The fix
   was to **delete the guard**, not to write a test for it. A survivor is not always
   a missing test; sometimes it is a redundant guard confessing.
2. **An assertion satisfied by its own fixture.** `runner-vanished-backup-is-silent`
   survived while asserting the output contained `"vanished"` — which it did, because
   the fixture was named `demo-vanishedbackup` and the id was printed inside the
   backup path. The test passed with the guard disabled. Renamed the fixture and
   asserted on `"nothing left to restore"` instead.
3. **A test harness missing the function it was exercising.** The awk-extracted
   harness for `ensure_services_running` never defined `notify_failure`, so the alert
   path died with `command not found` while the test passed. Stubbed, asserted, and
   given its own corpus entry.

---

## 5. What each fix actually changed

### 5.1 The sync path

`./scripts/sync-nas.sh` now exits non-zero and says **`NAS NOT synced`** for an
unreachable NAS, a local commit `origin` does not have, or a NAS that did not end up
on the intended commit *and branch*. `tests/nas-sync.bats` runs the hook the way git
runs it — cwd at the work tree top, invoked by its path inside the git dir — against
a throwaway repo with a real origin, and asserts on the side effect.

The predecessor test, `tests/hooks-installed.bats`, asserted the symlink existed, was
executable, and pointed at the right target. All three were true for the hook's entire
inert life. **Presence is not behaviour.**

### 5.2 `tests/shellcheck.bats` had never executed on any machine in this project

It skipped when `shellcheck` was absent, and it is absent on pi1 and the NAS both — so
it had been counted as coverage while never once running. Now it falls back to
`koalaman/shellcheck:stable` in a container (the same pattern this repo already uses
for `alpine/git` and the Playwright runner) and skips only when neither is available,
naming which.

Discovery widened from `scripts/*.sh` plus `terraform/apply.sh` to every tracked file that is a shell script:
**29 → 43 files**, which brought in `scripts/post-merge` and `scripts/pre-commit` —
both load-bearing git hooks, both extensionless, both previously unchecked. Clean at
`-S error`. Widening the severity is a separate deliberate decision, not done here.

### 5.3 `scripts/arr-backup.sh` — three defects

1. **The exit-trap restart was unbounded and silent.** `ensure_services_running` is
   called from the EXIT trap; a hung `docker compose up -d` held cleanup open
   indefinitely and a failed one was invisible (`2>/dev/null`). Now bounded by
   `SAFETY_TIMEOUT` (default 120s), reports timeout and failure distinctly, and calls
   `notify_failure`. **It still returns 0, deliberately** — see §6.
2. **The staging-dir collision message misreported every other failure.** A `mkdir`
   failure printed *"already exists — another backup may be running"* for a
   permissions error or a missing parent equally. `create_staging_dir` now tests the
   directory's existence to distinguish, and surfaces `mkdir`'s own stderr otherwise.
3. **`BACKUP_DIR` held two different roles.** It was the user's destination for the
   first half of the script, then reassigned partway through to the `/tmp` staging
   path — with `TARBALL` deriving from whichever meaning was current. Split into
   `FINAL_DEST` and `STAGING_DIR`; `BACKUP_DIR` now holds only the destination.
   The two must **stay** separate: the EXIT trap does `rm -rf` on the staging
   directory, and a single shared variable points that `rm -rf` at the user's
   backup destination.

---

## 6. The merge gate, and the two findings rejected

Three gates were run across the branch. The final full three-lens gate returned
**CONTESTED** — three HIGH findings with no reviewer consensus. Seven findings
accepted and fixed in `0271c26`. Two rejected, recorded here rather than silently
dropped:

- **"`create_staging_dir` taking its path as `$1` is inconsistent with the
  surrounding globals."** Rejected. Taking the path as an argument is better than
  reading a global, and it is what makes the function testable in isolation. The
  inconsistency is in the surrounding code.
- **"`ensure_services_running` should return non-zero on failure."** Rejected, and
  this one is load-bearing. It runs under `set -e` from the EXIT trap, where
  `cleanup_on_exit` calls it as `|| true`. A non-zero return there becomes the
  script's exit status — which once made a *successful* backup exit 42, and would
  make a `backup && prune` cron chain skip pruning permanently. The real problem the
  reviewer sensed was the missing signal, not the status; `notify_failure` closes it.

---

## 7. Open items

- **The 04:00 cron log redirection — needs interactive sudo on the NAS.** The nightly
  backup runs (tarball `20260831-040002`, root-owned) but writes **no log**, so its
  only failure signals reach nobody. Replacement crontab staged and verified intact at
  `/volume1/docker/arr-stack-backups/root-crontab.proposed-20260831-171220`
  (mode 0600, sha256 `50e22c3bcbd3eab8ecb4b23dc4fe1f7814cae597a57efbd878cbe94e48940e9d`),
  both `@reboot` lines preserved, backup beside it as `root-crontab.bak-20260831-171220`.
  One command: `sudo crontab <that file>`.
- **`sudo apt install jq` on pi1** clears the only 2 failures in the local suite
  (`tests/credential-propagation.bats`, both `exit 127`).

---

## 8. Traps

Concrete, each one paid for in this pass.

**Shell**

- **`rc=$?` immediately inside `if ! cmd; then` reads the status of the negation** —
  always `0`. It printed `FAILED (exit 0)`. Capture with `cmd || rc=$?` instead.
- **`echo "$x" | tr -c 'A-Za-z0-9._-' '_'` converts the trailing newline into `_`**,
  silently yielding `<id>_.orig`. Use `printf '%s'`.
- **`timeout` execs its argument**, so it can never run a shell function. A test that
  needs to intercept a `timeout`-wrapped call must put a real executable on `PATH`.
- **`^#!.*(bash|/sh)` misses `#!/usr/bin/env sh`** — no `/sh` substring, no `bash`.
  Match the interpreter *word*: `^#!.*\b(ba|da|k|z)?sh([[:space:]]|$)`.
- **`sed -i` is rename-based**, so a running bash keeps its original inode — the
  mutation runner can safely mutate itself.

**Tests**

- **An assertion can be satisfied by its own fixture.** Never assert on a string that
  also appears in the test's own data — especially not the fixture's name.
- **`$TMPDIR` is not `/tmp` under bats**, and `mktemp -d` honours it.
- **bats `-f <regex>` exits 0 having run nothing** when the filter matches no test.
  The runner parses the TAP `1..N` plan line rather than trusting the status.
- **A test extracted from a script with `awk` inherits none of its callees.** Anything
  the extracted body calls must be stubbed, or it dies `command not found` while the
  test reports success.

**Operational**

- **`backup-prune.sh` uses `find "$DIR" -maxdepth 1`** and never descends. Anything
  written to a *subdirectory* of the backup root is retained forever by nobody's
  policy. Two 139 MB verification tarballs were parked in `scratch-verify/` during
  this pass and had to be removed by hand. See also the general hazard: two retention
  policies pointed at one directory.
- **"18 backed up" against 17 archive directories is not a defect.** `.env` /
  `dot-env` increments `BACKED_UP` alongside the 17 volumes (`arr-backup.sh:748`).
  Recorded so nobody re-investigates it.
