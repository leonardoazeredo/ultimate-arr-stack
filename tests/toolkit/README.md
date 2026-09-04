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

It also runs the oracle under a hard **address-space cap** (`ulimit -v`, 512 MB,
overridable via `PYTEST_ADDRESS_SPACE_KB`). That is a blast door, not tuning.
`run-generated.sh` bounds a mutant's wall clock and nothing else, and a mutant
that loops *allocating* is a different animal from one that merely spins: on
2026-09-02 `queue_cleanup.py:209 break ==> continue` exhausted this 1.8 GiB
host's RAM and swap and rebooted the machine twice, at the same mutant, losing
~30 minutes of sweep and its ledger each time.

`docker run --memory` does not work here and fails silently — pi1 boots with
`cgroup_disable=memory`, so cgroup v2 offers only `cpuset cpu io pids`. Check
`/sys/fs/cgroup/cgroup.controllers` before believing any container resource
limit on this host. `ulimit -v` needs no cgroup and no privilege.

The cap is asserted from *inside* the capped process —
`tests/python/test_oracle_environment.py` reads its own `RLIMIT_AS` back and
fails on `RLIM_INFINITY` — because asserting that the script merely *contains* a
`ulimit` line is the presence-is-not-behaviour trap this repo keeps paying for.
Corpus entry: `oracle-address-space-uncapped`.

This cap only covers the containerised half. `run_tests()` in
`tests/mutation/lib-mutate.sh` is the shared entry point for every mutant —
bash-native ones as much as the Python ones that route through this script —
and a native bats file never goes through docker, so this cap does not reach
it. `lib-mutate.sh` carries a sibling `ulimit -S -v` (soft-only — a bare
`ulimit -v` sets the hard limit too, which `run_tests()` calling itself on
every mutant's control run would then never let a later mutated run raise
back) around its own invocation, with one deliberate carve-out:
`NATIVE_MEM_EXEMPT` skips the small list of bats files that shell out to a
real `docker` daemon, because the `docker` CLI itself cannot start under a
cap tight enough to matter here — a Go-runtime quirk, verified 2026-09-02,
where `docker version` needs 2 GiB+ of virtual address space regardless of
actual usage, more than this host's total RAM. Corpus entry:
`oracle-native-address-space-uncapped`. Full incident, the soft/hard-limit
trap, and the docker-incompatibility measurement: `docs/TEST-HARDENING-LOG.md` §8.

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
