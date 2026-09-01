# Mutation testing

A test that cannot fail is worse than no test, because it is counted as
coverage. This directory holds the machinery for proving each guard in the
bats suite can actually fail, and a corpus recording the specific defects each
one is supposed to catch.

## Why it exists

Four separate times in this project a test was written, reviewed, and merged
while being incapable of failing:

- the `EXTRA_LAN_SUBNETS` grammar guard passed on a trailing comma and on a
  space-separated list, because two silent normalisations upstream of the
  assertion discarded exactly the malformed input it was checking for;
- the deploy-workflow ordering assertion was satisfied by a **fully
  commented-out** validation step;
- `a failing worker teardown does not stop the staging dir from being removed`
  called the handler as `cleanup_on_exit || true` — precisely the position
  where `set -e` does not fire — so it passed against the mutation it exists
  to catch;
- three of the volume-resolution tests were being rescued by a neighbouring
  code path rather than testing the matcher they named.

None of these were caught by reading the tests. In every case they read
correctly. Breaking the thing they guard and watching them stay green is what
found them.

## Two runners, two jobs

|  | `run-mutations.sh` | `run-generated.sh` |
| --- | --- | --- |
| Kind | regression | discovery |
| Mutations | a corpus of defects someone wrote down | generated systematically by universalmutator |
| Answers | "can this guard still fail?" | "what is not guarded at all?" |
| Blocking | **yes** — non-zero on any SURVIVED/ERRORED | **no** — always exits 0 |
| Output | a verdict per corpus entry | `survivors.tsv`, to be triaged by hand |

The corpus can only ever re-ask a question someone already thought to ask; every
entry in it is a bug that was written down after the fact. Generation asks the
questions nobody thought of. Both are needed, and neither substitutes for the
other.

Generation is non-blocking **by design**. Some generated mutants are
*equivalent* — they change the text without changing behaviour — and no test can
ever kill them. A discovery tool that wedges the workflow on an irreducible
false-positive rate gets disabled, and then it finds nothing at all.

## Running it

```sh
./tests/mutation/run-mutations.sh                      # every corpus
./tests/mutation/run-mutations.sh -k sync              # ids containing "sync"
./tests/mutation/run-mutations.sh tests/mutation/corpus/nas-sync.sh

./tests/mutation/run-generated.sh                      # sweep every target
./tests/mutation/run-generated.sh -k check-conflicts   # one target
```

`run-mutations.sh` exits non-zero if anything SURVIVED or ERRORED. Neither is
part of `./tests/run-tests.sh`: they run the bats suite once or twice per
mutation, so they belong to the "changed a guard, or about to trust one" moment
rather than to every commit.

Both share `lib-mutate.sh`, which owns the backup/restore discipline. That is
one file on purpose — a second copy of restore logic would drift, and the copy
that drifted would leave a mutated file in the tree looking like an ordinary
edit.

## The generated half

`mutator.sh` runs universalmutator in a container (`tests/mutation/Dockerfile`,
image and package both pinned). pi1 cannot install it on the host: no pip, no
pipx, PEP 668, and `ensurepip` ships no bundled wheels, so even `python3 -m venv`
cannot bootstrap. Containerising is this repo's standing answer for tools the
host lacks — `alpine/git`, `koalaman/shellcheck`, the Playwright image.

The repo is never bind-mounted. universalmutator writes scratch files into its
working directory, so the target is copied into a throwaway directory instead:
the container cannot reach anything it was not handed.

`shell.rules` is the ruleset. universalmutator ships nothing for bash and its
`universal.rules` fallback is arithmetic-centric — on shell it mutates the
shebang into `#!+bin/bash`. Note that passing `none` as the language does **not**
disable the built-in rules; only `--only shell.rules` does. Measured on
`check-secrets.sh`: `none` alone produced 119 mutants, all of them noise.

### Triaging a survivor

Survivors land in `survivors.tsv` as `unreviewed`. Each gets one of:

| verdict | meaning |
| --- | --- |
| `real-gap` | the suite genuinely cannot see this defect |
| `equivalent` | the mutation does not change behaviour; nothing can kill it |
| `wontfix` | real but unreachable in practice; the note must say why |
| `unreviewed` | not yet looked at |

A `real-gap` gets a test written, **and then a corpus entry**, so the new test is
itself proved capable of failing.

The ledger is merged, never rebuilt, along both axes:

- a row whose target was **not swept** by this run is carried through untouched,
  so a `-k` filter, a positional target, or a target that SKIPs for want of
  docker cannot delete verdicts it never looked at;
- a row whose target **was** swept keeps its verdict if the same mutation is
  still found, and is dropped if it is not.

Identity is `(file, mutation text)`. The line number is a separate column and is
deliberately **not** part of the key: line numbers shift the moment anything is
inserted above a mutation, and an identity that included one would silently
orphan every hand-assigned verdict on the next edit.

> Both halves of that were paid for. The first version rebuilt the file from the
> current run's survivors alone, so a filtered run deleted every row outside the
> filter — five triaged verdicts, lost silently. The "two consecutive sweeps
> produce an identical ledger" check could not see it, because both sweeps were
> full ones. `tests/mutation-framework.bats` now asserts both directions, with
> corpus entries proving each assertion can fail.

### First sweep, 2026-09-01

40 mutants across the three covered `scripts/lib/` files: 21 killed, 19 survived.
Writing five tests for the survivors took it to **35 killed, 5 survived** — the
remaining five are triaged `wontfix`/`equivalent` in the ledger.

Two of those were real, and both are this repo's recurring shapes:

- **`grep -qx "$var"` → `grep -q "$var"`** in `check-env-vars.sh` survived. This
  is the *same defect* generation already found once here, in the backup volume
  resolver (`grep -Fxq` → `grep -Fq`). Whole-line matching was load-bearing in
  both places and proved in neither: with `-q`, an undocumented `${NAS_IP}` is
  considered documented because `.env.example` mentions `NAS_IP_RANGE`.
- **Static-IP conflict detection had no test at all.** Both pre-existing
  `check_conflicts` tests used ports; nine mutants across the entire IP half
  survived. CLAUDE.md pins static IPs precisely because a collision is silent
  until a container restarts onto an address something else holds.

A third was subtler and worth its own line: `-gt 1` → `-ge 1` survived because
both tests asserted that the *expected* message appeared and neither asserted
that the *wrong* one did not. Getting the right output is not proof — the check
also has to not emit the wrong one.

## Targets with no oracle

Mutation testing needs a test as its oracle. Against a file with no tests, every
mutant survives by construction — that is not a finding, it is a restatement of
"this file has no tests", and a few hundred guaranteed survivors would bury the
real signal. So the sweep covers only files that have one.

`scripts/lib/common.sh` was swept once on the theory that being sourced by three
tested files made it covered. **78 mutants generated, 78 survived, 0 killed.**
Sourced is not covered: the four `pre-commit-checks.bats` tests exercise none of
its NAS, SSH, or domain helpers. It is listed below with the rest.

### What is not swept

The list below is every tracked production shell file with no `TARGETS` entry,
which is to say every one a generated mutant could not be scored against.
Some of them do have bats tests and are simply not swept yet; others have no
test at all. The list does not distinguish the two, because only the first is
mechanically knowable — "has a test" has no honest definition here, as
`setup-hooks.sh` demonstrated by being *named* by a bats file that never ran it.

There is no count written down, and the list is not maintained by hand. It is
derived from field 1 of `TARGETS` at run time by
`tests/shellcheck.bats`, which fails if the two disagree in either direction.
The previous version of this paragraph was a hand-written count that went stale
the day the first of those tests was written, which is the same way `CLAUDE.md`'s
old "14 tests" claim went stale.

<!-- NO-SWEEP-ORACLE: asserted by tests/shellcheck.bats; do not edit by hand -->
- `duc-service/app/duc.cgi`
- `duc-service/app/log.cgi`
- `duc-service/app/manual_scan.cgi`
- `duc-service/app/manual_scan.sh`
- `duc-service/app/scan.sh`
- `duc-service/app/startup.sh`
- `scripts/arr-backup.sh`
- `scripts/backup-prune.sh`
- `scripts/boot-compose-up.sh`
- `scripts/check-network.sh`
- `scripts/check-vpn.sh`
- `scripts/configure-apps.sh`
- `scripts/detect-credential-drift.sh`
- `scripts/detect-vpn-zombies.sh`
- `scripts/ensure-tailscale-relay-port.sh`
- `scripts/fix-radarr-paths.sh`
- `scripts/fix-sonarr-folders.sh`
- `scripts/post-merge`
- `scripts/pre-commit`
- `scripts/queue-cleanup.sh`
- `scripts/restart-stack.sh`
- `scripts/sync-nas.sh`
- `setup-hooks.sh`
- `terraform/apply.sh`
<!-- /NO-SWEEP-ORACLE -->

## The stub harness, and why it has its own corpus entries

`tests/helpers/stubs.bash` puts real executables named `docker`, `curl`, `ssh` and
`git` at the front of `$PATH` so a test can drive an operational script without the
script reaching a live daemon. It is the only thing standing between
`tests/restart-stack.bats` and a `docker compose up` against the NAS that serves the
house's DNS.

That makes it a guard, and this repo's whole reason for owning a mutation framework is
that four guards were merged here while being incapable of failing. So the harness is
mutated too, in `corpus/stub-harness.sh`: neuter `forbid()`, remove the absolute-path
rule, silence the breadcrumb, require adjacency in the verb matcher — each one must
turn a named test red. Mutating it is safe to run, because with the denylist disabled
the `docker` stub still runs and that stub does nothing but print and exit 1.

Two rules that are easy to get wrong, both learned here:

- **Match the argv array, not the joined command line.** Word comparison is what lets
  `docker  compose   up` (doubled spaces) trip while `./scripts/restart-stack.sh` does
  not. A substring denylist would refuse to let a test so much as name the script it
  is testing.
- **Reserve an exit status.** `forbid()` exits 99, which none of these tools return. A
  test that means to reach a forbidden call asserts 99 *and* the breadcrumb file; a
  bare `assert_failure` would pass if the script had died for any reason at all.

The breadcrumb exists because the status alone is not enough: a `|| true` or an `if`
in the script under test swallows it. The file does not get swallowed.

## What the runner refuses to do

Each of these is a way a mutation run can report a green result while proving
nothing, and each is a hard ERROR rather than a verdict:

| Refusal | The trap it closes |
| --- | --- |
| the mutation left the file byte-identical | a pattern that stopped matching after a refactor scores a false KILLED. An earlier harness in this project reported **five** passes this way, because its own `cmp` guard inverted its exit status. |
| `--test` matched no tests | `bats -f` exits 0 having run nothing, which is indistinguishable from a pass. |
| the test was already failing unmutated | a red test failing again says nothing about the mutation. |

The target is restored from a byte copy through an EXIT trap and re-checked
with `cmp`, so an interrupt cannot leave a mutated file in the tree — which
would look exactly like an ordinary edit.

**A restore that fails is fatal, in both directions.** The first version of the
runner was not: it printed `FATAL`, carried on, and could still finish with
every mutation KILLED and exit 0 while a mutated file sat in the tree. It then
`rm -rf`'d the backup directory the message had just named as the thing to
restore from. A run that cannot put a file back now exits 3, stops immediately
rather than mutating the next target on top of a tree it could not repair, and
keeps `$WORK`. A backup that has *vanished* is treated the same way, not as
"nothing to restore" — those two were one condition, and both returned 0.

That defect was found by an adversarial review of this very directory, which is
the honest version of the lesson: the tool built to catch silent failure shipped
failing silently. Its own tests are in `tests/mutation-framework.bats` and its
own mutations are at the bottom of `corpus/nas-sync.sh`.

`tests/mutation-framework.bats` holds the runner to its own standard: it is
proved able to emit KILLED, SURVIVED, and all three ERRORs against a fixture
built for the purpose. A mutation runner that cannot report SURVIVED is worse
than none — it turns every vacuous test in the suite into a certificate.

## Adding a mutation

A corpus file is an ordinary shell script calling `mutation`. There is no
bespoke format to parse and get subtly wrong.

```sh
mutation some-stable-id \
  --file scripts/thing.sh \
  --bats tests/thing.bats \
  --test "the test name, as a bats -f regex" \
  --why "what breaks in production if this survives" \
  --apply 'sed -i "s@^guard@# guard@" "$F"'
```

`$F` is the absolute path to the target; `--apply` runs from the repo root.
Keep `--apply` **single-quoted** — corpus files are sourced, so a double-quoted
value would expand `$F` to nothing at load time.

Write `--why` as the consequence, not the edit. It is what gets printed when
the mutation survives, and by then the useful sentence is the one explaining
what is now unguarded.

### An assertion can be satisfied by its own fixture

The test for the vanished-backup guard asserted the output contained
`"vanished"`. It passed with the guard fully disabled — because the backup file
is named after the mutation id, and the id was `demo-vanishedbackup`, so the
word appeared in a path the runner prints either way. The assertion was matching
its own test data.

Reading it caught nothing; it looks completely reasonable. The corpus entry
caught it on the first run. When asserting on output, pick a phrase that exists
**only** on the path being proved — not a word that also appears in an id, a
filename, or an echoed argument.

### A survivor is not always a missing test

Sometimes it means the guard itself is redundant. Adding a `cp` exit-status
check alongside the existing `cmp` produced a mutation that could not be killed:
every case where a failed `cp` matters is a case where the bytes differ, so
`cmp` fires first and the `cp` branch can never be the thing that catches
anything. The right response was to delete the guard, not to write a test for
it. **Verify the outcome, not the exit status of the command that was supposed
to produce it** — when two guards overlap, keep the one that inspects reality.
