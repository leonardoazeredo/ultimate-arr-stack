# tests/toolkit

Two tools this repo needs and its hosts do not have, containerised for the same
reason `alpine/git`, `koalaman/shellcheck` and the pinned Playwright image are:
pi1 has no pip and a PEP 668 externally-managed python3, and the NAS has no npm
at all. Containerising a missing tool is the standing answer here, not a new
idea introduced by this directory.

Both scripts exit **77**, never 0, when docker is unavailable. An absent oracle
and a passing oracle must not be the same observable result — `sync-nas.sh`
shipped exactly that equivalence once, for an unreachable NAS, and it read as
"synced" for weeks.

The image tag is the Dockerfile's own content hash, so editing the Dockerfile
necessarily builds a new image. A fixed tag plus build-on-first-use is how the
NAS's `duc-service` ended up running code that the repo, the tests and `git log`
all said had been fixed.

## pytest.sh — an oracle, and load bearing

Runs `tests/python/` against the three modules in `scripts/lib/*.py`. Those were
heredocs inside their shell scripts until 2026-09-01 and could not be imported,
let alone tested; roughly 460 lines of the richest logic in the repo had no test
of any kind. `tests/python-suite.bats` is the bridge that runs this from the
bats suite, and it also asserts that every module in `scripts/lib/` has a test
file, so a new one cannot arrive untested.

The repo is mounted **read-only**. Nothing here needs to write to it, and a
writable mount would put a test one bug away from editing tracked files.

## coverage.sh — one diagnostic, with a delete-by rule

kcov is **not** load bearing and is not a gate. It exists to be run once and
read once.

`tests/shellcheck.bats` already answers "which files does the suite never enter"
at file granularity, for free, with no container, derived from `TARGETS` at run
time. kcov's only non-redundant contribution is *within* a file: which branches
of a file we do enter go unexercised.

That is also the signal this repo's oldest test idiom destroys. Six test files
extract a function body with `awk` and `eval` it into the bats shell, which
produces code with **no file path**, so kcov cannot attribute a single line of
it and reports some of the most thoroughly tested shell in the repo as 0%
covered. Those files are listed in `kcov-blind-spots.txt` and the summary marks
them `BLIND` rather than `0%`, so nobody re-derives that fact each run.

**The keep-or-delete rule.** After the first report: if every zero it flags is
either a listed blind spot or a file with no `TARGETS` entry — which
`shellcheck.bats` already reports — then kcov has told us nothing the mutation
ledger did not already say. Delete `coverage.sh`, drop the `kcov` line from the
`Dockerfile`, and record that result here. Carrying a second tool that
duplicates the first is how a suite accumulates maintenance with no coverage to
show for it.

A zero that is neither a blind spot nor an unswept file is a real finding. A
zero in no category at all is a bug in the report, not a coverage gap.

Unlike `pytest.sh`, this one mounts the repo **read-write** — the bats suite
bootstraps its vendored submodule and several tests stage files inside the tree.
kcov's own output goes to a separate mount. It is the one script here that can
touch tracked files, which is a further reason it is run by hand.

### Result of the first run

_Not yet run. This section records the keep-or-delete decision and the evidence
for it; until it is filled in, the rule above has not been applied._
