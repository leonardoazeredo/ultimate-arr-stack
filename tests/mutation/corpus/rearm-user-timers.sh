# shellcheck shell=bash
# Corpus: scripts/rearm-user-timers.sh
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)

# --- the two-step remedy --------------------------------------------------

mutation rearm-skips-the-start \
  --file scripts/rearm-user-timers.sh \
  --bats tests/rearm-user-timers.bats \
  --test "rearm: reloads before starting, and starts timers.target" \
  --why "dropping the start leaves the state measured on 2026-09-19: all eight timers visible after a reload and none scheduled, which list-timers prints as eight lines and reads like success" \
  --apply 'sed -i.bak "s@\"\$SYSTEMCTL\" --user start timers.target@true@" "$F" && rm -f "$F.bak"'

mutation rearm-skips-the-reload \
  --file scripts/rearm-user-timers.sh \
  --bats tests/rearm-user-timers.bats \
  --test "rearm: reloads before starting, and starts timers.target" \
  --why "without the reload the manager has never seen the unit files, so starting timers.target arms nothing" \
  --apply 'sed -i.bak "s@\"\$SYSTEMCTL\" --user daemon-reload@true@" "$F" && rm -f "$F.bak"'

mutation rearm-ignores-inactive-timers \
  --file scripts/rearm-user-timers.sh \
  --bats tests/rearm-user-timers.bats \
  --test "rearm: fails when a timer is visible but not armed" \
  --why "a remedy that reports success without checking is the silent failure this whole plan exists to remove; the check is what separates reloaded from armed" \
  --apply 'sed -i.bak "s@if ! \"\$SYSTEMCTL\" --user is-active --quiet \"\$name\"; then@if false; then@" "$F" && rm -f "$F.bak"'

mutation rearm-passes-on-missing-unit-dir \
  --file scripts/rearm-user-timers.sh \
  --bats tests/rearm-user-timers.bats \
  --test "rearm: fails when the unit directory never appears" \
  --why "treating an absent unit directory as nothing-to-do makes a boot where /home never mounted indistinguishable from a healthy one" \
  --apply 'sed -i.bak "s@        exit 1@        exit 0@" "$F" && rm -f "$F.bak"'
