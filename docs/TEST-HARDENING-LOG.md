# Test & Deploy Hardening — Project Log

Audited record of the hardening pass merged as `86d5fcf` on 2026-09-01
(branch `fix/nas-sync-silent-failure`, six commits, 13 files, +1651/−69).

**Last updated: 2026-09-01.** Sections 2–6 and 8 are historical and stay true;
**§1 and §7 decay.** Every claim in §1 carries the command to re-check it rather than a
copied value — `docs/EXIT-NODE-PROJECT-LOG.md` learned this by embedding a commit SHA
that its own commit invalidated on landing. If you find a bare number in §1, treat it
as a bug.

Read this before changing anything in `scripts/post-merge`, `scripts/sync-nas.sh`,
`scripts/arr-backup.sh`, or `tests/mutation/`. Its value is not the list of fixes —
those are in the diff. It is the record of **which of this repo's guards turned out
to be incapable of failing**, and the traps that produced them, because every one of
them read as coverage right up until it was watched.

---

## 1. Status at a glance

| | Re-check |
| --- | --- |
| Merged | `86d5fcf`, 2026-09-01, local merge — the `post-merge` hook fired and synced the NAS. `git log --oneline --no-decorate a56d2cc..86d5fcf` |
| pi1 suite | Green at merge bar 2 pre-existing `jq: command not found` failures (see §7). `./tests/run-tests.sh` |
| NAS suite | Green at merge. `ssh arr-stack-nas 'cd /volume1/docker/arr-stack && ./tests/run-tests.sh'` |
| Mutation corpus | All killed at merge, none survived. `./tests/mutation/run-mutations.sh` — the count is whatever the corpus holds now, not a number to copy |
| Merge gate | CONTESTED → all findings explicitly accepted or rejected on the record (§6) |
| NAS deploy path | Must be `main`. Re-check the **branch**, not the commit: `ssh arr-stack-nas "docker run --rm -v /volume1/docker/arr-stack:/repo -w /repo alpine/git -c safe.directory=/repo rev-parse --abbrev-ref HEAD"` |

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

Corpus: `corpus/nas-sync.sh`, `corpus/backup-and-guards.sh`, `corpus/generative.sh`.
**`tests/mutation/README.md` is the authoritative guide** — design, how to add an entry, and the full write-up of the
lessons summarised below. This section records only what the framework caught here.

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

### 4.1 The generated half, added 2026-09-01

The corpus can only re-ask a question someone already thought to ask. `run-generated.sh`
is the other half: universalmutator perturbs a file systematically and anything the suite
fails to kill is a gap nobody had to think of first.

**The worked example is the reason this was built.** `grep -Fxq` → `grep -Fq` in the
backup volume resolver survived all 18 tests around it. Whole-line matching was
load-bearing — volume names nest, so a substring match silently mis-resolves and a volume
fails to back up — and nothing proved it. Neither review nor the corpus would ever have
asked. The comment recording it is at `tests/backup-volume-resolution.bats:729`.

The first sweep found the *same defect again*, in a different file: `grep -qx "$var"` →
`grep -q "$var"` in `check-env-vars.sh:46`. With `-q`, an undocumented `${NAS_IP}` passes
because `.env.example` mentions `NAS_IP_RANGE`. Two independent instances of one defect
shape, both invisible to reading, both found the same mechanical way.

It also found that static-IP conflict detection had **no test at all** — both existing
`check_conflicts` tests used ports, and nine mutants across the whole IP half survived —
and that `-gt 1` → `-ge 1` survived because both tests asserted the expected message
appeared while neither asserted the wrong one did not.

40 mutants, 21 killed. Five new tests took it to 35 killed / 5 survived, the five triaged
`wontfix` or `equivalent` in `tests/mutation/survivors.tsv`.

> The survivor ledger shipped a second instance of the same class, caught by the merge
> review rather than by the tool. It was rebuilt from the current run's survivors alone,
> so any run that did not sweep everything — a `-k` filter, a SKIPped target, an ERRORed
> one — silently deleted every row it had not just regenerated. Five hand-assigned
> verdicts were lost. The verification that should have caught it, *"two consecutive
> sweeps produce an identical ledger"*, passed: both sweeps were full ones, so the check
> could not fail. Identity also included the line number, which would have orphaned every
> verdict on the next edit above a mutation. Both are fixed, both are asserted in
> `tests/mutation-framework.bats`, and both have corpus entries.
>
> The extraction of `lib-mutate.sh` — the shared backup/restore core — shipped a bug of
> exactly the class this directory exists to catch, and the corpus caught it on the next
> run. `take_backup` returned its path by echoing it, so every caller wrote
> `backup="$(take_backup ...)"`: a command substitution is a **subshell**, the
> `CURRENT_FILE`/`CURRENT_BACKUP` globals were set inside it and died with it,
> `restore_current` took its legitimate "nothing to restore" branch, and the run finished
> having left five mutated files in the working tree. Reading the diff did not catch it.
> A function whose entire purpose is a side effect on globals now refuses to run where
> those globals go nowhere (`BASHPID != $$`), with a corpus entry proving the refusal
> can fail.

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

Discovery widened from `scripts/*.sh` plus `terraform/apply.sh` to every tracked file
that is a shell script: **16 → 43 files**. Clean at `-S error`. Widening the severity
is a separate deliberate decision, not done here.

What the old glob missed matters more than the count. A shell glob is **not**
recursive, so `scripts/*.sh` never descended into `scripts/lib/` — all **13** check
scripts that `scripts/pre-commit` sources (`check-secrets.sh`, `check-env-vars.sh`,
`check-conflicts.sh`, …) were unchecked, as were `scripts/post-merge` and
`scripts/pre-commit` themselves, both extensionless and both load-bearing.

> Two numbers for this were published wrong before the right one: commit `3f56fd1`'s
> own message says "19 files -> 43", and the first draft of this document said 29. Both
> came from `git ls-files 'scripts/*.sh'`, whose pathspec `*` matches across `/` and so
> counts the `lib/` files the real glob could never see. The correct comparison runs the
> glob the test actually ran: `ls -1 scripts/*.sh | wc -l` → 15, plus `terraform/apply.sh`.
> Checking a proxy instead of the thing itself is the defect class this whole document is
> about, committed while documenting it.

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

**This section decays.** Mark an item done in place rather than deleting it — an
"Open items" list that silently loses entries is indistinguishable from one nobody
has touched.

- **The 04:00 cron log redirection — needs interactive sudo on the NAS.** The nightly
  backup runs (tarball `20260831-040002`, root-owned) but writes **no log**, so its
  only failure signals reach nobody. Replacement crontab staged and verified intact at
  `/volume1/docker/arr-stack-backups/root-crontab.proposed-20260831-171220`
  (mode 0600, sha256 `50e22c3bcbd3eab8ecb4b23dc4fe1f7814cae597a57efbd878cbe94e48940e9d`),
  both `@reboot` lines preserved, backup beside it as `root-crontab.bak-20260831-171220`.
  One command: `sudo crontab <that file>`.
- **`sudo apt install jq` on pi1** clears the only 2 failures in the local suite
  (`tests/credential-propagation.bats`, both `exit 127`).
- **DONE 2026-09-01 — generative mutation testing installed.** universalmutator,
  containerised and pinned, wired to the bats suite as `run-generated.sh`. See §4.1.
- **Ten `scripts/lib/` files have no bats test at all** — `common.sh` plus the nine
  `check-*.sh` listed in `tests/mutation/README.md`. They are sourced by
  `scripts/pre-commit`, so a defect in any of them silently weakens every commit's
  checks. `common.sh` was measured: 78 mutants, 78 survived, 0 killed. Writing those
  tests is separate work and is the largest remaining gap in this suite.

---

## 8. Traps

Concrete, each one paid for in this pass. The test traps marked ▸ have their full
write-up in `tests/mutation/README.md`; these are the one-line forms.

**Shell**

- **`rc=$?` immediately inside `if ! cmd; then` reads the status of the negation** —
  always `0`. It printed `FAILED (exit 0)`. Capture with `cmd || rc=$?` instead.
- **`echo "$x" | tr -c 'A-Za-z0-9._-' '_'` converts the trailing newline into `_`**,
  silently yielding `<id>_.orig`. Use `printf '%s'`.
- **`timeout` execs its argument**, so it can never run a shell function. A test that
  needs to intercept a `timeout`-wrapped call must put a real executable on `PATH`.
- **A command substitution is a subshell, so a function that "returns" by setting a
  global cannot be called as `x="$(fn ...)"`** — the assignment lands in the subshell
  and dies with it. If the function's whole purpose is a side effect on globals, make
  it refuse to run where they go nowhere (`[[ "$BASHPID" != "$$" ]]`).
- **`trap` replaces, it does not accumulate**, so sourcing a file that installs an EXIT
  trap twice orphans the first one's cleanup. Guard the file against double-sourcing.
- **A `$PATH` stub cannot intercept an absolute path.** `/usr/bin/curl` reaches the real
  binary however carefully `curl` was stubbed. It matters most for the *delegating*
  tools: `ssh host /usr/bin/docker restart x` runs unstubbed on the far side, where the
  harness has no reach at all. `tests/helpers/stubs.bash` refuses any argv word matching
  `^/(usr/)?(local/)?s?bin/` for exactly this reason.
- **`((n++))` returns exit status 1 when `n` is 0**, because a post-increment evaluates
  to the value *before* incrementing and `((0))` is a failure. Under `set -e` the first
  increment of a counter starting at zero therefore kills the shell — and only the
  first, which is why it reads as an intermittent, input-dependent crash rather than a
  syntax error. Use `n=$((n + 1))`, which is always status 0.
- **`set -e` is suppressed for the entire body of a function invoked as an `if`
  condition.** So the same `((n++))` is harmless in `if check_x; then` and fatal in a
  bare `check_x`. A library's correctness ends up decided by a property of its *call
  site* that is invisible where the function is defined — `scripts/pre-commit` had 18
  safe sites and 9 live bugs, identical code in both. Pin the contract the library owes
  *any* caller.
- **Every idiom for CATCHING an errexit abort also PREVENTS it.** `run` clears errexit,
  `if` suppresses it in the callee, and `( set -e; f ) || rc=$?` suppresses it too — a
  subshell that is the left operand of `||` runs with errexit disabled no matter what
  `set -e` it contains. A first probe of this bug "disproved" it three ways for that
  reason. Only a separate process (`bash -c '...'`, status read afterwards) observes it.
- **Command substitution strips trailing newlines**, so `x=$(cmd)` can never end in a
  blank line and a fixture appending one to test a blank-line guard never reaches it.

**Test**

- ▸ **`tests/shellcheck.bats` only sees *tracked* files.** A newly written script passes
  it until the moment it is committed, so "shellcheck clean" is not a statement about
  the working tree. Check a new script explicitly, or `git add` it first.
- ▸ **A determinism check between two *identical* invocations cannot fail.** "Two
  consecutive sweeps produce an identical ledger" passed while a filtered sweep was
  deleting rows, because both sweeps were full ones. Vary the thing the invariant is
  supposed to be robust to, not the clock.
- **`^#!.*(bash|/sh)` misses `#!/usr/bin/env sh`** — no `/sh` substring, no `bash`.
  Match the interpreter *word*: `^#!.*\b(ba|da|k|z)?sh([[:space:]]|$)`.
- **`sed -i` is rename-based**, so a running bash keeps its original inode — the
  mutation runner can safely mutate itself.
- **An exit code can be right for the wrong reason.** The pre-commit hook rejected bad
  commits with status 1 for as long as anyone had looked, while every explanation of the
  rejection — the message naming the leaking file, the summary, the error count, the
  later checks — was unreachable. Asserting the status alone would have passed forever;
  what caught it was asserting on *output* and on *how far the run got*.
- **A counter that is written and never read is not bookkeeping, it is a latent abort.**
  `check-hardcoded-domain.sh` kept a `hostname_errors` tally whose only observable effect
  was killing the hook. Deleting it was the fix.
- **Content filters silently exempt fixtures.** `check-secrets.sh:27` skips `*.md`, so a
  planted secret in a markdown fixture is reported "OK" and the test then asserts against
  a check that never ran. Confirm the fixture's *extension* is one the code under test
  actually scans.
- **A skipped oracle reads as a passing one.** TAP spells a skip as `ok N name # skip`,
  so a mutation runner scores the mutant SURVIVED — a coverage gap invented out of an
  environment condition and filed against a test that never executed. Two entries read
  that way here, both because their oracle skips on a dirty `scripts/lib` while the run
  was measuring a fix to `scripts/lib`. `run-mutations.sh` now reports SKIPPED and the
  reason.
- **A corpus entry whose verdict depends on the ambient tree is worse than none.**
  `gen-dirty-guard-ignores-the-filter` killed while the tree was dirty and survived once
  it was clean, because the condition it needed was ambient rather than constructed. An
  entry must build the state it measures. Where that state is a dirty tree, build a
  throwaway repo — dirtying a tracked file needs a restore, and a restore has an
  interrupt window that has already cost this repo a corrupted ledger once.
- **An over-broad precondition does not merely block, it launders itself into a false
  measurement.** `run-generated.sh` refused to start over targets a `-k` run would never
  touch; downstream that surfaced not as "refused" but as two coverage gaps that did not
  exist.

**Tests**

- ▸ **An assertion can be satisfied by its own fixture.** Never assert on a string that
  also appears in the test's own data — especially not the fixture's name.
- **`$TMPDIR` is not `/tmp` under bats**, and `mktemp -d` honours it.
- **bats `-f <regex>` exits 0 having run nothing** when the filter matches no test.
  The runner parses the TAP `1..N` plan line rather than trusting the status.
- ▸ **A test extracted from a script with `awk` inherits none of its callees.** Anything
  the extracted body calls must be stubbed, or it dies `command not found` while the
  test reports success.
- ▸ **A test that mutates tracked repo state and restores it with a bare `cp` has a
  window.** `tests/mutation-framework.bats`'s ledger-merge test overwrote the real
  `survivors.tsv` and copied it back at the end. A 2026-09-01 timeout killed the sweep
  in between and left two sentinel rows in the working tree that looked enough like
  real triage output to be committed by accident. The fix is a seam, not a trap:
  `MUTATION_LEDGER` lets the test point the runner somewhere disposable, so there is no
  window to interrupt and no restore that can be skipped.
- ▸ **A single-word denylist rule cannot test an ordered-subsequence matcher.** The
  first mutation written against `forbid()`'s subsequence walk targeted the one-word
  `restart` rule and SURVIVED: a one-word rule matches wherever the word appears, no
  matter how the walk is written. Only a multi-word rule with argv in between
  (`compose -f x.yml up`) exercises the property. The test read as though it covered
  it — the mutation is what said otherwise.

**Operational**

- **`backup-prune.sh` uses `find "$DIR" -maxdepth 1`** and never descends. Anything
  written to a *subdirectory* of the backup root is retained forever by nobody's
  policy. Two 139 MB verification tarballs were parked in `scratch-verify/` during
  this pass and had to be removed by hand. See also the general hazard: two retention
  policies pointed at one directory.
- **"18 backed up" against 17 archive directories is not a defect.** `.env` /
  `dot-env` increments `BACKED_UP` alongside the 17 volumes (`arr-backup.sh:748`).
  Recorded so nobody re-investigates it.
