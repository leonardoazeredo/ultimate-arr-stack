# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for the assertion-shadowing guard in tests/shellcheck.bats.
#
# THE DEFECT THIS RECORDS
#
# bats-assert reports every failure by piping its diagnostic to bats-support's
# `fail`, which returns 1. scripts/lib/configure-helpers.sh:34 defines its own
# `fail` - an output helper that prints a red cross, increments a counter and
# returns 0. tests/lib-configure-helpers.bats sources that library into the bats
# shell in setup(), so bats-support's `fail` was shadowed and every
# assert_output in the file became incapable of failing: twenty-two tests
# reported ok against output that plainly contradicted them, and two entries in
# corpus/configure-helpers.sh survived because the tests meant to kill them
# could not go red.
#
# Running the suite can never reveal this - the file is green either way. So the
# guard is static, and both directions it can be wrong in get an entry: failing
# to notice a real collision, and "passing" because its own discovery found
# nothing to compare.
#
# Safe to run: the oracle is a single bats test that reads tracked files and
# compares two sorted name lists. Nothing is executed, fetched or written.

mutation shadowed-assertion-goes-unnoticed \
  --file tests/lib-configure-helpers.bats \
  --bats tests/shellcheck.bats \
  --test "no test file sources a unit that shadows a function bats-assert reports through" \
  --why "puts a real bats-assert call back into the one test file that sources a fail-defining library. This is the original defect, verbatim: the assertion is inert, the test reports ok whatever the output says, and nothing in the suite objects. If the guard does not go red here it is not guarding" \
  --apply 'sed -i "s@^    out_has \"COUNTS 0 5 0\"\$@    assert_output --partial \"COUNTS 0 5 0\"@" "$F"'

mutation shadowing-guard-compares-nothing \
  --file tests/shellcheck.bats \
  --bats tests/shellcheck.bats \
  --test "no test file sources a unit that shadows a function bats-assert reports through" \
  --why "empties the derived list of bats-support/bats-assert function names. Every collision test then intersects against nothing and finds nothing, so the guard reports green while checking literally no names - the same comparing-nothing-against-nothing shape the no-sweep list carries an entry for, and the shape four already-discarded tests in this repo failed in. Killed by the explicit non-empty assertion, not by luck" \
  --apply 'sed -i "s@| tr -d .()..| sort -u\$@| tr -d '\''()'\'' | sort -u | grep -v .@" "$F"'
