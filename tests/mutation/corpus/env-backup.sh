# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/lib/check-env-backup.sh.
#
# Safe to run: the oracle overrides has_nas_config / is_nas_reachable /
# is_ssh_available / ssh_to_nas, so no mutation here can open an SSH connection
# or read anything outside $BATS_TEST_TMPDIR.

mutation env-backup-empty-ssh-is-a-difference \
  --file scripts/lib/check-env-backup.sh \
  --bats tests/lib-env-backup.bats \
  --test "env-backup: an empty SSH answer is a skip, not a difference" \
  --why "removes the guard on an empty SSH answer. A failed auth returns empty, empty differs from the backup's contents, so every auth failure would be reported as 'your backup is out of date' - and the remediation would then tell the user to overwrite a good backup with nothing" \
  --apply 'perl -0pi -e "s/    if \[\[ -z \\\"\\\$nas_env\\\" \]\]; then\n        echo \\\"    SKIP: Could not fetch NAS .env \\(SSH auth failed\\)\\\"\n        return 0\n    fi\n//" "$F"'

mutation env-backup-scp-remediation \
  --file scripts/lib/check-env-backup.sh \
  --bats tests/lib-env-backup.bats \
  --test "env-backup: DEFECT - the remediation uses the mechanism this check itself uses" \
  --why "restores the scp remediation. CLAUDE.md records scp failing opaquely against this NAS's BusyBox sftp-server, and the workaround it records is piping through ssh - which is what this very function does two lines earlier to fetch the same file. Printing the broken transport beside the working one is advice that costs an afternoon" \
  --apply 'sed -i "s#Run: ssh .*[.]env[.]nas[.]backup#Run: scp \$nas_user@\$nas_host:\$stack_dir/.env .env.nas.backup#" "$F"'

mutation env-backup-local-side-read-raw \
  --file scripts/lib/check-env-backup.sh \
  --bats tests/lib-env-backup.bats \
  --test "env-backup: a trailing-newline difference alone is not a difference" \
  --why "reads the local file without command substitution. The NAS side goes through \$( ), which strips trailing newlines; the local side then would not, so every .env ending in a newline - which is nearly all of them - differs from itself forever. A warning that is always on is a warning nobody reads" \
  --apply 'sed -i "s@    local_env=\$(cat \"\$backup_file\")@    local_env=\$(cat \"\$backup_file\"; echo x)@" "$F"'

