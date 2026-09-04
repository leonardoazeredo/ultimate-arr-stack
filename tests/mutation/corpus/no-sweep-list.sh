# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for the derived no-sweep list.
#
# The guard being proved here is unusual: it asserts that PROSE agrees with
# code. That is exactly the kind of check that gets merged, passes forever, and
# turns out to have been comparing nothing against nothing - so all three
# directions it can be wrong in get an entry.
#
# All three anchor on duc-service/app/duc.cgi, and that choice is the point.
# The obvious anchor is whatever file is unswept today - which makes the entry
# ERROR out the moment that file gains coverage, and this list is designed to
# shrink. The .cgi files are the one stable choice: they are five lines each,
# they get a smoke assertion rather than a TARGETS entry by decision, so they
# stay on the no-sweep list permanently.
#
# Safe to run: the oracle is a single bats test that reads two tracked files
# and compares two sorted lists. Nothing is executed, fetched or written.

mutation no-sweep-list-omits-a-file \
  --file tests/mutation/README.md \
  --bats tests/shellcheck.bats \
  --test "the no-sweep list in tests/mutation/README.md matches what TARGETS actually covers" \
  --why "drops a genuinely unswept file from the documented list. This is the direction that under-reports the gap: the list shrinks, the coverage does not, and the README reads as though more is covered than is. A check that only failed on the stale direction would never notice" \
  --apply 'sed -i "\@^- .duc-service/app/duc.cgi.\$@d" "$F"'

mutation no-sweep-list-names-a-swept-file \
  --file tests/mutation/README.md \
  --bats tests/shellcheck.bats \
  --test "the no-sweep list in tests/mutation/README.md matches what TARGETS actually covers" \
  --why "names a file that IS swept as though it were not. This is the stale direction - the shape the old hand-written 'ten scripts/lib files have no bats test' claim failed in, and the shape CLAUDE.md's old '14 tests' count failed in before it" \
  --apply 'sed -i "\@^- .duc-service/app/duc.cgi.\$@i\\- \`scripts/lib/check-secrets.sh\`" "$F"'

mutation no-sweep-list-blind-to-a-new-target \
  --file tests/mutation/run-generated.sh \
  --bats tests/shellcheck.bats \
  --test "the no-sweep list in tests/mutation/README.md matches what TARGETS actually covers" \
  --why "adds a real TARGETS entry without touching the README, which is how this list will actually go stale in practice: nobody edits prose to make it wrong, they add coverage and forget the paragraph. The mutation names a file that is currently ON the documented list, because a bogus path would leave the derived set unchanged and the test would pass while proving nothing" \
  --apply 'sed -i "s@^  \"scripts/lib/check-secrets.sh:@  \"duc-service/app/duc.cgi:tests/pre-commit-checks.bats:^check_secrets \"\n  \"scripts/lib/check-secrets.sh:@" "$F"'

# --- the same guard, applied to CONTRIBUTING.md's scripts tree -------------
#
# Anchored on `restart-stack.sh`, chosen for the same reason duc.cgi anchors
# the entries above: it is not going anywhere. A script that might be deleted
# would make these entries ERROR out the day it was.
#
# Only two directions here, not three. The list is derived straight from what
# is on disk rather than from another file's contents, so there is no third
# party that can drift out from under it the way TARGETS can.

mutation scripts-tree-omits-a-script \
  --file CONTRIBUTING.md \
  --bats tests/shellcheck.bats \
  --test "the scripts tree in CONTRIBUTING.md names every script that exists" \
  --why "drops an existing script from the tree. This is the direction the tree was already broken in when the guard was written - it named 3 of the 16 files in scripts/ and omitted env-file.sh and all three extracted Python modules, having been accurate once" \
  --apply 'sed -i "\@^├── restart-stack.sh @d" "$F"'

mutation scripts-tree-keeps-a-deleted-script \
  --file CONTRIBUTING.md \
  --bats tests/shellcheck.bats \
  --test "the scripts tree in CONTRIBUTING.md names every script that exists" \
  --why "names a script that does not exist. check-dns-duplicates.sh was deleted from scripts/ as a divergent duplicate of the lib version, and a tree still listing it would send a reader looking for a file whose absence is the whole point" \
  --apply 'sed -i "\@^├── restart-stack.sh @i\\├── check-dns-duplicates.sh    # Detect duplicate .lan domains" "$F"'
