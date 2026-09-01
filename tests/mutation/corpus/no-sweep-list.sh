# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for the derived no-sweep list.
#
# The guard being proved here is unusual: it asserts that PROSE agrees with
# code. That is exactly the kind of check that gets merged, passes forever, and
# turns out to have been comparing nothing against nothing - so all three
# directions it can be wrong in get an entry.
#
# Safe to run: the oracle is a single bats test that reads two tracked files
# and compares two sorted lists. Nothing is executed, fetched or written.

mutation no-sweep-list-omits-a-file \
  --file tests/mutation/README.md \
  --bats tests/shellcheck.bats \
  --test "the no-sweep list in tests/mutation/README.md matches what TARGETS actually covers" \
  --why "drops a genuinely unswept file from the documented list. This is the direction that under-reports the gap: the list shrinks, the coverage does not, and the README reads as though more is covered than is. A check that only failed on the stale direction would never notice" \
  --apply 'sed -i "\@^- .scripts/lib/common.sh.\$@d" "$F"'

mutation no-sweep-list-names-a-swept-file \
  --file tests/mutation/README.md \
  --bats tests/shellcheck.bats \
  --test "the no-sweep list in tests/mutation/README.md matches what TARGETS actually covers" \
  --why "names a file that IS swept as though it were not. This is the stale direction - the shape the old hand-written 'ten scripts/lib files have no bats test' claim failed in, and the shape CLAUDE.md's old '14 tests' count failed in before it" \
  --apply 'sed -i "\@^- .scripts/lib/common.sh.\$@i\\- \`scripts/lib/check-secrets.sh\`" "$F"'

mutation no-sweep-list-blind-to-a-new-target \
  --file tests/mutation/run-generated.sh \
  --bats tests/shellcheck.bats \
  --test "the no-sweep list in tests/mutation/README.md matches what TARGETS actually covers" \
  --why "adds a real TARGETS entry without touching the README, which is how this list will actually go stale in practice: nobody edits prose to make it wrong, they add coverage and forget the paragraph. The mutation names a file that is currently ON the documented list, because a bogus path would leave the derived set unchanged and the test would pass while proving nothing" \
  --apply 'sed -i "s@^  \"scripts/lib/check-secrets.sh:@  \"scripts/lib/common.sh:tests/pre-commit-checks.bats:^check_secrets \"\n  \"scripts/lib/check-secrets.sh:@" "$F"'
