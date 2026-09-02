# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for tests/toolkit/coverage.sh and the list that excuses its zeroes.
#
# The blind-spots list is a guard of an unusual kind: its job is to say "do not
# believe this zero". A guard that suppresses a warning is worth more scepticism
# than one that raises it, because when it goes wrong nothing appears at all.
# Both directions it can be wrong in get an entry, and so does the 77 contract.
#
# Safe to run: two of the three mutate a text file, and the third only changes
# an exit status on a path that never reaches docker.

mutation blind-spots-names-a-missing-file \
  --file tests/toolkit/kcov-blind-spots.txt \
  --bats tests/coverage-tool.bats \
  --test "every blind spot names a file that exists" \
  --why "a renamed or deleted script leaves a dead entry behind, and a dead entry excuses nothing while looking like it does - the next real zero for that path would be reported as measured with nobody the wiser" \
  --apply 'printf "scripts/no-such-script.sh\n" >> "$F"'

mutation blind-spots-excuses-an-unextracted-file \
  --file tests/toolkit/kcov-blind-spots.txt \
  --bats tests/coverage-tool.bats \
  --test "every blind spot is actually tested by extraction" \
  --why "this is the direction that hides a real gap: queue-cleanup.sh is tested by running it, not by extracting a function out of it, so kcov can see it perfectly well. Listing it BLIND would turn a genuine coverage hole into a measurement artefact by assertion" \
  --apply 'printf "scripts/queue-cleanup.sh\n" >> "$F"'

mutation coverage-missing-docker-reads-as-clean \
  --file tests/toolkit/coverage.sh \
  --bats tests/coverage-tool.bats \
  --test "coverage.sh exits 77, not 0, when docker is not on PATH" \
  --why "exiting 0 when the tool is absent makes 'nothing was measured' and 'the measurement was clean' the same observable result. shellcheck.bats skipped green for months on hosts with no shellcheck for exactly this reason, and sync-nas.sh reported an unreachable NAS as synced" \
  --apply 'sed -i "s@^    exit 77\$@    exit 0@" "$F"'
