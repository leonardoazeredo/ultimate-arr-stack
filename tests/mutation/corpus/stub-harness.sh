# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for the test safety harness itself.
#
# tests/helpers/stubs.bash is the only thing standing between a Phase 3 test and
# a live `docker compose up` on the NAS. Every other guard in this repo that
# nobody watched fail turned out to be incapable of failing - four of them, all
# listed in docs/TEST-HARDENING-LOG.md §8, none caught by reading.
#
# These entries exist so the harness cannot join that list. They run under
# run-mutations.sh, which is already installed and blocking, so this proof lands
# on day one rather than waiting for the generative sweep.
#
# Mutating the harness is SAFE to run: with the denylist neutered the docker
# stub still runs, and that stub does nothing but print and exit 1. No mutation
# here can reach a real docker daemon.

mutation forbid-denylist-disabled \
  --file tests/helpers/stubs.bash \
  --bats tests/restart-stack.bats \
  --test "the harness stops 'all' before it reaches a live restart" \
  --why "if forbid() can be neutered without a test noticing, then every Phase 3 test that drives an operational script is running unguarded and nobody would know" \
  --apply 'sed -i "s/^forbid() {/forbid() { return 0;/" "$F"'

mutation forbid-seq-requires-adjacency \
  --file tests/helpers/stubs.bash \
  --bats tests/stub-harness.bats \
  --test "forbid trips on docker compose up with argv in between" \
  --why "an adjacent-pair match would still catch the toy 'docker compose up' and miss every real call site, because a real one is always 'compose -f <file> up'; first written against the one-word restart rule, where it SURVIVED - a single-word rule matches wherever it appears however the walk is written" \
  --apply 'sed -i "s@wi=\$((wi + 1))@wi=\$((wi + 1)) || wi=0@" "$F"'

mutation forbid-abspath-rule-removed \
  --file tests/helpers/stubs.bash \
  --bats tests/stub-harness.bats \
  --test "forbid trips when an absolute tool path is handed to a delegating stub" \
  --why "a PATH stub cannot intercept /usr/bin/docker; without this rule an ssh carrying an absolute tool path runs unstubbed on the far side and the harness reports nothing" \
  --apply 'sed -i "s@^STUB_DENY_ABSPATH_RE=.*@STUB_DENY_ABSPATH_RE=\x27^ZZZ_NEVER_MATCHES\x27@" "$F"'

mutation forbid-breadcrumb-not-written \
  --file tests/helpers/stubs.bash \
  --bats tests/stub-harness.bats \
  --test "assert_nothing_forbidden FAILS when something was forbidden" \
  --why "the exit status can be swallowed by a || true or an if in the script under test; the breadcrumb file is what survives that, so a harness that only exits non-zero is a harness that can be silenced by the code it is guarding" \
  --apply 'sed -i "/^    } >> \"\$STUB_FORBIDDEN\"$/s@.*@    } >> /dev/null@" "$F"'

mutation forbid-blind-to-quoted-remote-command \
  --file tests/helpers/stubs.bash \
  --bats tests/stub-harness.bats \
  --test "forbid looks inside a quoted remote command" \
  --why "scripts/sync-nas.sh and scripts/arr-backup.sh both pass the whole remote command as ONE ssh argument, so word matching over the ssh argv sees an opaque blob - without the inner split the denylist is blind to exactly the calls it exists to stop" \
  --apply 'sed -i "s@^            \[\[ \"\$word\" == \*\[\[:space:\]\]\* \]\] || continue@            continue@" "$F"'

# --- tests/mutation/run-generated.sh: the ledger seam -----------------------
#
# Not the stub harness, but the same class of problem and found by the same
# work: a test that mutates tracked repo state and restores it with a bare `cp`
# has a window, and an interrupt inside that window commits the wreckage.

mutation ledger-path-not-overridable \
  --file tests/mutation/run-generated.sh \
  --bats tests/mutation-framework.bats \
  --test "the ledger path is overridable so a test never writes to the repo's own" \
  --why "re-hardcoding the ledger path forces the merge tests to overwrite the tracked survivors.tsv in place; an interrupt between the overwrite and the restore then leaves sentinel rows in the working tree, which is how this was found" \
  --apply 'sed -i "s@^LEDGER=\"\${MUTATION_LEDGER:-\$ROOT/tests/mutation/survivors.tsv}\"@LEDGER=\"\$ROOT/tests/mutation/survivors.tsv\"@" "$F"'
