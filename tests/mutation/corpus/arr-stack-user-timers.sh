# shellcheck shell=bash
# Corpus: scripts/arr-stack-user-timers.service
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)

mutation rearm-unit-default-timeout \
  --file scripts/arr-stack-user-timers.service \
  --bats tests/arr-stack-user-timers.bats \
  --test "timer rearm unit's start timeout covers the script's own wait" \
  --why "without TimeoutStartSec the unit inherits the 90s default while the script polls for 600s, so systemd kills the rearm mid-wait and a slow /home mount reads as a failed unit -- the failure mode this unit exists to prevent" \
  --apply 'sed -i.bak "s@^TimeoutStartSec=900@TimeoutStartSec=10@" "$F" && rm -f "$F.bak"'

mutation rearm-unit-runs-as-root \
  --file scripts/arr-stack-user-timers.service \
  --bats tests/arr-stack-user-timers.bats \
  --test "timer rearm unit runs as leoleg with the user runtime dir set" \
  --why "as root the script looks in /root for the unit directory, never finds one, and burns its whole timeout; every timer stays dead with the unit reporting failure for the wrong reason" \
  --apply 'sed -i.bak "s@^User=leoleg@User=root@" "$F" && rm -f "$F.bak"'

mutation rearm-unit-orders-on-home-mount \
  --file scripts/arr-stack-user-timers.service \
  --bats tests/arr-stack-user-timers.bats \
  --test "timer rearm unit waits for the user manager, not for a mount unit" \
  --why "ordering on home.mount was measured doing nothing on 2026-09-20 -- it has an empty FragmentPath and does not exist until UGOS has already mounted the volume -- so reintroducing it restores the belief that the race can be ordered away" \
  --apply 'sed -i.bak "s@^After=user@After=home.mount user@" "$F" && rm -f "$F.bak"'

mutation rearm-unit-execed-too-early \
  --file scripts/arr-stack-user-timers.service \
  --bats tests/arr-stack-user-timers.bats \
  --test "timer rearm unit waits for its own script before exec'ing it" \
  --why "this is the bug the first version of the unit shipped: /volume1 mounts after multi-user.target, so an ExecStart naming the script directly dies with 203/EXEC -- measured 20:43:08 on a boot where volume1.mount only became active at 20:43:37 -- and every timer stays dead with the unit failing for a reason nobody reads" \
  --apply 'sed -i.bak "s@^ExecStart=/bin/bash.*@ExecStart=/volume1/docker/arr-stack/scripts/rearm-user-timers.sh@" "$F" && rm -f "$F.bak"'
