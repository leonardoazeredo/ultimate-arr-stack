# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/lib/check-uptime-monitors.sh.
#
# Safe to run: the check's only outside contact is ssh_to_nas, which every test
# in tests/lib-uptime-monitors.bats replaces with a function reading a fixture
# file. No mutation here can reach the NAS.

mutation uptime-warnings-abort-bare-caller \
  --file scripts/lib/check-uptime-monitors.sh \
  --bats tests/lib-uptime-monitors.bats \
  --test "uptime-monitors: a missing-monitor warning does not kill a bare caller" \
  --why "restores the post-increment; scripts/pre-commit calls this check bare under set -e, so the first warning from a check documented as warnings-only killed the hook and took checks 8-11 and the summary with it" \
  --apply 'sed -i "s@warnings=\$((warnings + 1))@((warnings++))@g" "$F"'

mutation uptime-blank-line-is-a-monitor \
  --file scripts/lib/check-uptime-monitors.sh \
  --bats tests/lib-uptime-monitors.bats \
  --test "uptime-monitors: a blank line in the query output is not a monitor" \
  --why "sqlite3 output ends in a newline, so the here-string always feeds this loop one empty final field; without the guard every single run warns about an unknown monitor named '' and the warnings stop being read" \
  --apply 'sed -i "s@^\s*\[\[ -z \"\$monitor\" \]\] \&\& continue@        :@" "$F"'

mutation uptime-empty-query-looks-unmonitored \
  --file scripts/lib/check-uptime-monitors.sh \
  --bats tests/lib-uptime-monitors.bats \
  --test "uptime-monitors: an empty query result is a skip, not twelve warnings" \
  --why "a NAS that answers SSH but cannot reach docker returns nothing, and nothing compares equal to no monitor at all - without this arm a broken query is indistinguishable from a completely unmonitored stack, which is the more alarming of the two and the wrong one" \
  --apply 'perl -0pi -e "s/if \[\[ -z \\\"\\\$actual\\\" \]\]; then/if false; then/" "$F"'
