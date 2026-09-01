#!/usr/bin/env bats
# scripts/lib/check-env-backup.sh
#
# Compares the local .env.nas.backup against the NAS's live .env. Warnings
# only: every path returns 0 and none of them can block a commit.
#
# It is almost entirely made of skip arms -- five of them, in a fixed order,
# each guarding the next. That structure is the reason it needs tests rather
# than the reason it does not: a check whose normal outcome on any given
# machine is SKIP will report green forever if the comparison underneath is
# broken, and nobody would see a difference.
#
# Seams are all in common.sh, so plain function overrides reach them.

setup() {
    load helpers/setup
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORK="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$WORK"
    source "$REPO_ROOT/scripts/lib/common.sh"
    source "$REPO_ROOT/scripts/lib/check-env-backup.sh"

    get_repo_root()      { echo "$WORK"; }
    has_nas_config()     { return "${NAS_CONFIG_RC:-0}"; }
    is_nas_reachable()   { return "${REACHABLE_RC:-0}"; }
    is_ssh_available()   { return "${SSH_RC:-0}"; }
    get_nas_stack_dir()  { echo "/volume1/docker/arr-stack"; }
    get_nas_host()       { echo "mynas.local"; }
    get_nas_user()       { echo "leoleg"; }
    # The command goes to a FILE, not a variable. check_env_backup calls this
    # inside $( ), so anything it assigns dies with the subshell -- the same
    # trap as asserting on a variable set inside bats' own `run`.
    SSH_CMD_LOG="$BATS_TEST_TMPDIR/ssh-cmd"
    ssh_to_nas()         { printf '%s' "$1" > "$SSH_CMD_LOG"; printf '%s' "${NAS_ENV-}"; }
}

backup() { printf '%s' "$1" > "$WORK/.env.nas.backup"; }

# --- the skip ladder, in order ---------------------------------------------

@test "env-backup: no backup file is a skip and never touches the network" {
    NAS_CONFIG_RC=1 REACHABLE_RC=1
    run check_env_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP: No .env.nas.backup file"* ]]
}

@test "env-backup: the file check comes before the NAS config check" {
    # Order matters for the message the user gets. With no backup file, being
    # told "no NAS host configured" would send them to fix the wrong thing.
    NAS_CONFIG_RC=1
    run check_env_backup
    [[ "$output" == *"No .env.nas.backup file"* ]]
    [[ "$output" != *"No NAS host"* ]]
}

@test "env-backup: no NAS config is a skip" {
    backup 'A=1'
    NAS_CONFIG_RC=1
    run check_env_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP: No NAS host in .claude/config.local.md"* ]]
}

@test "env-backup: an unreachable NAS is a skip" {
    backup 'A=1'
    REACHABLE_RC=1
    run check_env_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP: NAS not reachable"* ]]
}

@test "env-backup: a closed SSH port is a skip" {
    backup 'A=1'
    SSH_RC=1
    run check_env_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP: SSH port not reachable"* ]]
}

@test "env-backup: an empty SSH answer is a skip, not a difference" {
    # This is the arm that matters most. A failed SSH returns empty, and empty
    # is not equal to the backup's contents -- so without this guard every
    # auth failure would be reported as "your backup is out of date", and the
    # remediation would tell the user to copy an empty file over a good one.
    backup 'A=1'
    NAS_ENV=''
    run check_env_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP: Could not fetch NAS .env (SSH auth failed)"* ]]
    [[ "$output" != *"WARNING"* ]]
}

# --- the comparison ---------------------------------------------------------

@test "env-backup: identical contents report OK" {
    backup 'A=1
B=2'
    NAS_ENV='A=1
B=2'
    run check_env_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: .env.nas.backup matches NAS"* ]]
}

@test "env-backup: differing contents warn" {
    backup 'A=1'
    NAS_ENV='A=2'
    run check_env_backup
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: .env.nas.backup differs from NAS .env"* ]]
}

@test "env-backup: a difference is a warning and never blocks" {
    # The file's own header says "warns if out of sync (non-blocking)". The
    # value is what decides that, not the header.
    backup 'A=1'
    NAS_ENV='A=2'
    run check_env_backup
    [ "$status" -eq 0 ]
}

@test "env-backup: a trailing-newline difference alone is not a difference" {
    # ssh_to_nas' output goes through $( ), which strips trailing newlines, and
    # the local side is read with cat, which does not. Comparing them raw would
    # report every single .env as out of sync forever -- a warning that is
    # always on is a warning nobody reads.
    backup 'A=1
'
    NAS_ENV='A=1'
    run check_env_backup
    [[ "$output" == *"OK: .env.nas.backup matches NAS"* ]]
}

@test "env-backup: it reads the .env under the configured stack dir" {
    backup 'A=1'
    NAS_ENV='A=1'
    check_env_backup >/dev/null
    [ "$(cat "$SSH_CMD_LOG")" = "cat /volume1/docker/arr-stack/.env" ]
}

# --- the remediation --------------------------------------------------------

@test "env-backup: DEFECT - the remediation uses the mechanism this check itself uses" {
    # It used to print an scp command. This function fetches the same file with
    # `ssh_to_nas "cat ..."` two lines earlier, and CLAUDE.md records scp
    # failing opaquely against this NAS's BusyBox sftp-server -- the workaround
    # there was piping through ssh, which is what this already does. Telling the
    # user to reach for the one transport the repo has documented as broken,
    # while the check beside it uses the working one, is advice that wastes an
    # afternoon.
    backup 'A=1'
    NAS_ENV='A=2'
    run check_env_backup
    [[ "$output" != *"scp "* ]]
    [[ "$output" == *"ssh leoleg@mynas.local"* ]]
    [[ "$output" == *"/volume1/docker/arr-stack/.env"* ]]
    [[ "$output" == *".env.nas.backup"* ]]
}

@test "env-backup: the remediation carries the real user, host and path" {
    backup 'A=1'
    NAS_ENV='A=2'
    get_nas_user() { echo "someoneelse"; }
    get_nas_host() { echo "other.local"; }
    get_nas_stack_dir() { echo "/srv/stack"; }
    run check_env_backup
    [[ "$output" == *"someoneelse@other.local"* ]]
    [[ "$output" == *"/srv/stack/.env"* ]]
}
