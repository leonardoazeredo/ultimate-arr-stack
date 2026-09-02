# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for the address-space cap that tests/toolkit/pytest.sh runs the
# oracle under.
#
# This guard protects the HOST, not the code, which makes it the easiest one in
# the repo to delete by accident: pytest.sh runs in a container, and "the
# container already bounds memory" is a reasonable-sounding assumption that
# happens to be false here. It is false because this host boots with
# `cgroup_disable=memory` in /proc/cmdline, so cgroup v2 exposes only
# `cpuset cpu io pids` and `docker run --memory` is accepted and ignored.
#
# What it cost before it existed, on 2026-09-02: the generated mutant
# `scripts/lib/queue_cleanup.py:209 break ==> continue` turned the max-pages
# guard into a loop that extended all_records AND emitted a pytest-captured log
# line every iteration. run-generated.sh bounds a mutant's wall clock and
# nothing else, so it ran until this 1.8 GiB machine exhausted RAM and swap and
# REBOOTED -- twice, deterministically, at the same mutant, each time taking
# ~30 minutes of unfinished sweep and an unwritten ledger with it.
#
# Safe to run: it removes a resource limit from a test runner. The suite it then
# runs is the ordinary one, which peaks far below the cap.

mutation oracle-address-space-uncapped \
  --file tests/toolkit/pytest.sh \
  --bats tests/python-suite.bats \
  --test "python: the extracted modules pass their pytest suite" \
  --why "with RLIMIT_AS unlimited a mutant that loops allocating is no longer scored KILLED - it is scored by the OOM killer, against the whole machine. The wall-clock budget cannot save it: the host died well inside a 70s budget, and a rebooted host writes no ledger, so the sweep loses everything rather than recording a survivor" \
  --apply 'sed -i "s#ulimit -v [^;]*; ##" "$F"'

# The sibling guard: run_tests() in lib-mutate.sh is the entry point for EVERY
# mutant, bash-native ones as much as the Python ones that route through
# pytest.sh. A native bats file never goes through a container, so the
# pytest.sh cap above does not reach it - this is what closes that path.
# Adversarial review of the incident writeup this guard came out of is what
# caught the gap: the fix as first written protected only the containerised
# half.
mutation oracle-native-address-space-uncapped \
  --file tests/mutation/lib-mutate.sh \
  --bats tests/mutation-framework.bats \
  --test "run_tests bounds the oracle's memory, not just its wall clock" \
  --why "the native path (every bash-side bats file run_tests invokes directly) has no container to fall back on - if this ulimit goes missing, a bash mutant that loops allocating can take the host down exactly the way the Python one did on 2026-09-02, and run-mutations.sh's own full-corpus sweep would be the thing that finds out" \
  --apply 'sed -i "s#ulimit -S -v \"\$NATIVE_MEM_KB\"#:#" "$F"'
