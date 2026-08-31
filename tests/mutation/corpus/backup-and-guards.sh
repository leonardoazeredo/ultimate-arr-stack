# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for the backup path and the deploy guards.
#
# These encode the breakages that were applied by hand during the sessions that
# built these files. Doing it by hand caught three vacuous tests that reading
# them did not; the point of writing them down is that the next refactor gets
# the same scrutiny without anyone having to remember the trick.

# --- scripts/arr-backup.sh: the interrupt handling -------------------------

mutation backup-no-term-trap \
  --file scripts/arr-backup.sh \
  --bats tests/backup-retention.bats \
  --test "an interrupt is deferred until the in-flight volume copy finishes" \
  --why "without a trap bash dies instantly, mid volume-copy, and the daemon re-creates the staging dir root-owned behind the cleanup" \
  --apply 'sed -i "/^trap .on_interrupt 143. TERM$/d" "$F"'

mutation backup-no-int-trap \
  --file scripts/arr-backup.sh \
  --bats tests/backup-retention.bats \
  --test "an interrupt is deferred until the in-flight volume copy finishes" \
  --why "Ctrl-C leaks RAM-backed /tmp exactly like a SIGTERM; covering only TERM is half a fix" \
  --apply 'sed -i "/^trap .on_interrupt 130. INT$/d" "$F"'

mutation backup-no-hup-trap \
  --file scripts/arr-backup.sh \
  --bats tests/backup-retention.bats \
  --test "an interrupt is deferred until the in-flight volume copy finishes" \
  --why "a backup started over ssh that loses its connection is an ordinary way for this to die" \
  --apply 'sed -i "/^trap .on_interrupt 129. HUP$/d" "$F"'

mutation backup-traps-after-first-copy \
  --file scripts/arr-backup.sh \
  --bats tests/backup-retention.bats \
  --test "the interrupt traps are installed before any copy container is started" \
  --why "a trap installed after the first copy container leaves the very first volume unprotected, which is where the leak was found" \
  --apply 'sed -i -e "/^trap .on_interrupt 1[0-9][0-9]. \(TERM\|INT\|HUP\)$/d" -e "/^COPY_CMD=/i trap \x27on_interrupt 143\x27 TERM" "$F"'

mutation backup-cleanup-loses-exit-status \
  --file scripts/arr-backup.sh \
  --bats tests/backup-retention.bats \
  --test "preserves the exit status when ensure_services_running FAILS" \
  --why "under set -e a bare failing call inside an EXIT trap aborts the handler AND becomes the exit status - a successful backup once exited 42" \
  --apply 'sed -i "s@^  ensure_services_running || true@  ensure_services_running@" "$F"'

mutation backup-no-worker-teardown \
  --file scripts/arr-backup.sh \
  --bats tests/backup-retention.bats \
  --test "cleanup stops the copy worker before removing what it writes into" \
  --why "a worker orphaned by an earlier killed run writes back into the directory cleanup just removed" \
  --apply 'sed -i "/docker rm -f arr-backup-worker/d" "$F"'

mutation backup-second-exit-trap \
  --file scripts/arr-backup.sh \
  --bats tests/backup-retention.bats \
  --test "there is exactly one EXIT trap" \
  --why "bash keeps ONE EXIT trap slot; a second one silently replaces the first and the cleanup simply stops running" \
  --apply 'printf "trap %s EXIT\n" "\x27:\x27" >> "$F"'

mutation backup-copy-without-pipefail \
  --file scripts/arr-backup.sh \
  --bats tests/backup-retention.bats \
  --test "the tar-pipe copy sets pipefail" \
  --why "without pipefail a failing producer in \`tar | tar\` exits 0, so a truncated copy is recorded as a successful backup" \
  --apply 'sed -i "s@^      COPY_CMD=\"set -o pipefail; @      COPY_CMD=\"@" "$F"'

mutation backup-stamp-without-seconds \
  --file scripts/arr-backup.sh \
  --bats tests/backup-retention.bats \
  --test "stamps tarballs with seconds" \
  --why "two runs in the same minute silently overwrite each other" \
  --apply 'sed -i "s@^RUN_TS=\"\$(date +%Y%m%d-%H%M%S)\"@RUN_TS=\"\$(date +%Y%m%d-%H%M)\"@" "$F"'

# --- the deploy guard's wiring --------------------------------------------
#
# The guard itself was proved able to fail on the NAS. What is asserted here is
# that it is still WIRED IN: present, enabled, and between the sync and the
# recreate. A guard in the wrong place is not a guard, and a commented-out one
# satisfied the first version of this assertion.

mutation workflow-env-guard-commented-out \
  --file .github/workflows/nas-auto-deploy.yml \
  --bats tests/env-vars.bats \
  --test "nas-auto-deploy validates the NAS .env" \
  --why "a commented-out validation step once satisfied this assertion, because it matched a bare substring" \
  --apply 'sed -i "s@^\(.*\)\(\"cd .\${NAS_STACK_DIR}. && timeout 300 ./tests/run-tests.sh tests/env-vars.bats\"\)@\1# \2@" "$F"'

mutation workflow-env-guard-deleted \
  --file .github/workflows/nas-auto-deploy.yml \
  --bats tests/env-vars.bats \
  --test "nas-auto-deploy validates the NAS .env" \
  --why "the plainest regression: the step is simply gone and the pipeline recreates services against an unvalidated .env" \
  --apply 'sed -i "/run-tests.sh tests\/env-vars.bats/d" "$F"'

# --- the .env grammar guards ----------------------------------------------
#
# Target is .env.example rather than the test, because that is the file the
# guard actually reads. Breaking it the way the real .env was broken is the
# only honest check that the guard would have caught the Traefik outage.

mutation env-lan-subnet-is-a-list \
  --file .env.example \
  --bats tests/env-vars.bats \
  --test "LAN_SUBNET is exactly one CIDR" \
  --why "the exact value that deleted the traefik-lan macvlan and took all 16 .lan hostnames down" \
  --apply 'sed -i "s@^LAN_SUBNET=.*@LAN_SUBNET=192.168.1.0/24,192.168.120.0/24@" "$F"'

# --- the EXIT-trap safety net and the staging-dir guard ----------------------

mutation backup-safety-restart-unbounded \
  --file scripts/arr-backup.sh \
  --bats tests/backup-retention.bats \
  --test "cannot hang the exit trap forever" \
  --why "the compose call in the EXIT trap becomes unbounded again, so cleanup hangs for as long as docker does on the one path whose whole job is to finish" \
  --apply 'sed -i "s@^    timeout \"\$SAFETY_TIMEOUT\" docker compose@    docker compose@" "$F"'

mutation backup-safety-restart-silent \
  --file scripts/arr-backup.sh \
  --bats tests/backup-retention.bats \
  --test "failed service restart is reported" \
  --why "a failure to restart gluetun leaves no trace anywhere and the backup still reports success" \
  --apply 'sed -i "s@up -d \$STOPPED || rc=\$?@up -d \$STOPPED 2>/dev/null || rc=\$?@" "$F"'

mutation backup-safety-restart-status-from-negation \
  --file scripts/arr-backup.sh \
  --bats tests/backup-retention.bats \
  --test "failed service restart is reported" \
  --why "the reported exit code comes from the negation rather than the command, so every failure prints 'exit 0'" \
  --apply 'sed -i "s@^    timeout \"\$SAFETY_TIMEOUT\" docker compose -f \"\$COMPOSE_FILE\" up -d \$STOPPED || rc=\$?@    if ! timeout \"\$SAFETY_TIMEOUT\" docker compose -f \"\$COMPOSE_FILE\" up -d \$STOPPED; then rc=\$?; else rc=0; fi@" "$F"'

mutation backup-mkdir-blames-a-collision \
  --file scripts/arr-backup.sh \
  --bats tests/backup-retention.bats \
  --test "reports the REAL reason" \
  --why "a read-only /tmp or a permissions error is reported as a concurrent backup, sending the reader after a run that does not exist" \
  --apply 'sed -i "s@^  if \[ -d \"\$1\" \]; then\$@  if true; then@" "$F"'

mutation backup-staging-dir-never-created \
  --file scripts/arr-backup.sh \
  --bats tests/backup-retention.bats \
  --test "actually creates the directory" \
  --why "create_staging_dir returns success without creating anything, so every later write lands nowhere" \
  --apply 'sed -i "s@^  if err=\"\$(mkdir \"\$1\" 2>&1)\"; then@  if err=\"\"; then@" "$F"'
