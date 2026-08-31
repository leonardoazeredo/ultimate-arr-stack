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

## Running it

```sh
./tests/mutation/run-mutations.sh                      # every corpus
./tests/mutation/run-mutations.sh -k sync              # ids containing "sync"
./tests/mutation/run-mutations.sh tests/mutation/corpus/nas-sync.sh
```

Exits non-zero if anything SURVIVED or ERRORED. It is not part of
`./tests/run-tests.sh`: it runs the bats suite twice per mutation, so it
belongs to the "changed a guard, or about to trust one" moment rather than to
every commit.

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
