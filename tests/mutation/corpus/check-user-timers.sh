# shellcheck shell=bash
# Corpus: scripts/check-user-timers.sh
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)

mutation check-timers-never-fails \
  --file scripts/check-user-timers.sh \
  --bats tests/check-user-timers.bats \
  --test "check-user-timers: a stale artifact means they are dead" \
  --why "a diagnostic that cannot fail is the silence this exists to break; on 2026-09-19 the timers were dead for eleven hours and nothing said so" \
  --apply 'sed -i.bak "s@^exit 1\$@exit 0@" "$F" && rm -f "$F.bak"'

mutation check-timers-treats-missing-as-fresh \
  --file scripts/check-user-timers.sh \
  --bats tests/check-user-timers.bats \
  --test "check-user-timers: no artifact at all is a failure, not a pass" \
  --why "an absent artifact reported as healthy makes a stack whose timers never ran indistinguishable from one where they are running" \
  --apply 'sed -i.bak "s@if \[\[ ! -e \"\$ARTIFACT\" \]\]; then@if false; then@" "$F" && rm -f "$F.bak"'
