# shellcheck shell=bash
# Corpus: scripts/indexer-guard.sh, the .env validation and the rotation order.
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
#
# The decision logic lives in scripts/lib/indexer_guard.py and is swept as a
# generated target. The wrapper is on the generated sweep's no-sweep list
# because most of what a generator would perturb in it is argv and log text
# the stubs answer either way; this entry is the hand-written half, and it
# covers the wrapper's own validation through tests/indexer-guard.bats.
#
# `perl -0777 -pi`, not `sed -i`: an entry should replay on the Mac as well as
# on Linux, and BSD sed reads -i's next argument as a backup suffix. See
# tests/mutation/README.md.

# --- only the literal 0 is refused as an interval ---------------------------

mutation indexer-guard-only-literal-zero-refused \
  --file scripts/indexer-guard.sh \
  --bats tests/indexer-guard.bats \
  --test "^indexer-guard: every all-zero interval spelling" \
  --why "the all-zero arm is the only thing between a .env of 00 and argparse, which refuses it: positive_seconds reads 00 as zero, exits 2, and the guard stops with an error instead of falling back to the module's six-hour default, so one bad spelling in .env disables the ban guard entirely. gluetun-rotator refuses every spelling of zero for the same reason, and the all-zero test is the only thing here that says the guard does too" \
  --apply 'perl -0777 -pi -e "s/^  \\*\\[!0\\]\\*\\) ;;\\n  \\*\\)\$/  0)/m" "$F"'
