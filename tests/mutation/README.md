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
