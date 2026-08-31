#!/usr/bin/env bats
# Regression coverage for the 2026-08-30 backup-history loss.
#
# What happened: `arr-backup.sh --tar /volume1/docker/arr-stack-backups` destroyed
# every existing tarball. The script applied a non-optional, silent
# `find <dest> -mtime +7 -delete` (stderr suppressed, nothing printed) to any
# destination it was handed, and that directory was already under
# backup-prune.sh's GFS retention. Two retention policies on one directory, one of
# them invisible. Nothing in this suite would have caught it.
#
# These tests are deliberately static-or-filesystem only: no docker, no NAS, so
# they run anywhere the rest of the fast suite runs.

setup() {
    load helpers/setup
    BACKUP_SH="$REPO_ROOT/scripts/arr-backup.sh"
    PRUNE_SH="$REPO_ROOT/scripts/backup-prune.sh"
}

@test "arr-backup.sh deletes at a destination only when --rotate-days is given" {
    # The guard must test ROTATE_DAYS. A bare `[ -n "$FINAL_DEST" ]` guard is
    # exactly the bug: it fires on every run that names a destination.
    run grep -n 'rm -rf "\$stale"' "$BACKUP_SH"
    assert_success

    # Walk back from the deletion to its enclosing `if` and require ROTATE_DAYS in it.
    local guard
    guard=$(grep -B 12 'rm -rf "\$stale"' "$BACKUP_SH" | grep -E '^\s*if \[' | tail -1)
    [[ "$guard" == *'$ROTATE_DAYS'* ]] || {
        echo "deletion is not gated on --rotate-days; guard was: $guard"
        return 1
    }
}

@test "arr-backup.sh has no silent destination-wide delete" {
    # The original bug in one line. `-delete`/`-exec rm` on a find whose output is
    # never printed removes files with no record that it happened.
    # Comments describe the old bug on purpose; only executable lines count.
    run bash -c "grep -vE '^[[:space:]]*#' '$BACKUP_SH' | grep -nE 'find .*-mtime.*(-delete|-exec[[:space:]]+rm)'"
    assert_failure
}

@test "arr-backup.sh announces every rotation deletion" {
    # Whatever it removes, it must say so. Silence is what made this unrecoverable.
    run grep -A 6 'rm -rf "\$stale"' "$BACKUP_SH"
    assert_success
    assert_output --partial 'removed:'
}

@test "arr-backup.sh stamps tarballs with seconds, not just the date" {
    # A date-only name means a second run the same day clobbers the first, and
    # backup-prune.sh cannot tier what it cannot parse.
    run grep -n 'RUN_TS="\$(date +%Y%m%d-%H%M%S)"' "$BACKUP_SH"
    assert_success

    run grep -n 'FINAL_TARBALL="\$FINAL_DEST/arr-stack-backup-\${RUN_TS}.tar.gz"' "$BACKUP_SH"
    assert_success

    # No surviving date-only tarball construction anywhere.
    run grep -nE 'arr-stack-backup-.*date \+%Y%m%d\)' "$BACKUP_SH"
    assert_failure
}

@test "every excluded volume is one arr-backup.sh actually backs up" {
    # An exclusion naming a volume absent from VOLUME_SUFFIXES is dead config that
    # reads as protection.
    local suffixes excludes
    suffixes=$(sed -n '/^VOLUME_SUFFIXES=(/,/^)/p' "$BACKUP_SH" | sed -E 's/#.*//' | tr -d ' ' | grep -vE '^\(|^\)|^VOLUME_SUFFIXES|^$')
    excludes=$(sed -n '/^declare -A VOLUME_EXCLUDES=(/,/^)/p' "$BACKUP_SH" | grep -oE '^\s*\[[a-z0-9-]+\]' | tr -d ' []')

    [ -n "$excludes" ] || { echo "no VOLUME_EXCLUDES found"; return 1; }
    for e in $excludes; do
        echo "$suffixes" | grep -qx "$e" || {
            echo "VOLUME_EXCLUDES has [$e] but VOLUME_SUFFIXES does not list it"
            return 1
        }
    done
}

@test "the *arr, jellyfin and pihole configs are backed up" {
    # These were excluded wholesale as "re-scan to rebuild". A re-scan does not
    # rebuild quality profiles, custom formats, or Jellyfin watch history.
    local suffixes
    suffixes=$(sed -n '/^VOLUME_SUFFIXES=(/,/^)/p' "$BACKUP_SH" | sed -E 's/#.*//' | tr -d ' ')
    for v in sonarr-config radarr-config jellyfin-config pihole-etc-pihole; do
        echo "$suffixes" | grep -qx "$v" || {
            echo "$v is not in VOLUME_SUFFIXES"
            return 1
        }
    done
}

@test "backup-prune.sh keeps the newest per day in the 7-30 day tier" {
    local dir="$BATS_TEST_TMPDIR/prune-tier"
    mkdir -p "$dir"
    local d14 d14b
    d14=$(date -d '14 days ago' +%Y%m%d)
    touch "$dir/arr-stack-backup-${d14}-010000.tar.gz" \
          "$dir/arr-stack-backup-${d14}-230000.tar.gz"

    run "$PRUNE_SH" "$dir"
    assert_success

    # Newest of that day survives, the older one goes.
    [ -f "$dir/arr-stack-backup-${d14}-230000.tar.gz" ]
    [ ! -f "$dir/arr-stack-backup-${d14}-010000.tar.gz" ]
}

@test "backup-prune.sh keeps everything inside the 7-day window" {
    local dir="$BATS_TEST_TMPDIR/prune-recent"
    mkdir -p "$dir"
    local d2
    d2=$(date -d '2 days ago' +%Y%m%d)
    touch "$dir/arr-stack-backup-${d2}-010000.tar.gz" \
          "$dir/arr-stack-backup-${d2}-230000.tar.gz"

    run "$PRUNE_SH" "$dir"
    assert_success

    [ -f "$dir/arr-stack-backup-${d2}-010000.tar.gz" ]
    [ -f "$dir/arr-stack-backup-${d2}-230000.tar.gz" ]
}

@test "backup-prune.sh tiers date-only names instead of skipping them forever" {
    # Pre-2026-08-30 naming. A file prune cannot parse accumulates indefinitely
    # while appearing to be managed.
    local dir="$BATS_TEST_TMPDIR/prune-legacy"
    mkdir -p "$dir"
    local d40
    d40=$(date -d '40 days ago' +%Y%m%d)
    touch "$dir/arr-stack-backup-${d40}.tar.gz"

    run "$PRUNE_SH" "$dir"
    assert_success
    refute_output --partial 'no recognizable timestamp'
}

@test "backup-prune.sh leaves genuinely unparseable files alone" {
    local dir="$BATS_TEST_TMPDIR/prune-unparseable"
    mkdir -p "$dir"
    touch "$dir/arr-stack-backup-manual-copy.tar.gz"

    run "$PRUNE_SH" "$dir"
    assert_success
    assert_output --partial 'no recognizable timestamp'
    [ -f "$dir/arr-stack-backup-manual-copy.tar.gz" ]
}

@test "the deploy workflow never rotates the GFS-managed backup directory" {
    # backup-prune.sh owns retention there. --rotate-days on the same directory
    # recreates the two-policy collision that caused the loss.
    local wf="$REPO_ROOT/.github/workflows/nas-auto-deploy.yml"
    [ -f "$wf" ] || skip "workflow not present"

    # Comments may mention the flag; only a real invocation counts.
    run bash -c "grep -vE '^[[:space:]]*#' '$wf' | grep -n -- '--rotate-days'"
    assert_failure
}

@test "both backup scripts are executable in git" {
    # The deploy workflow invokes ./scripts/backup-prune.sh directly. It was mode
    # 644 in the index and only worked on the NAS because that copy happened to
    # carry an exec bit the repo never set - a fresh checkout would have failed
    # the pre-deploy backup with 'Permission denied'.
    for f in scripts/arr-backup.sh scripts/backup-prune.sh; do
        local mode
        mode=$(cd "$REPO_ROOT" && git ls-files -s "$f" | awk '{print $1}')
        [ "$mode" = "100755" ] || {
            echo "$f is mode $mode in git, expected 100755"
            return 1
        }
    done
}

@test "the tar-pipe copy sets pipefail" {
    # Without it the pipe reports the receiving tar's status, so a source tar that
    # dies on an I/O or permission error yields a truncated backup reported "OK".
    run grep -n 'COPY_CMD="set -o pipefail;' "$BACKUP_SH"
    assert_success
}

@test "arr-backup.sh cleans up its /tmp staging dir from the EXIT trap" {
    # Superseded the old assertion on the literal string `rm -rf "$BACKUP_DIR"`,
    # which proved a removal existed but nothing about WHEN it ran -- and it ran
    # only on the happy path, which was the bug. The behavioural coverage is in
    # the cleanup_on_exit tests at the end of this file; this one just pins the
    # removal to the trap handler and to STAGING_DIR rather than BACKUP_DIR.
    run grep -c 'rm -rf "\$BACKUP_DIR"' "$BACKUP_SH"
    assert_output "0"

    run grep -n 'rm -rf "\$STAGING_DIR"' "$BACKUP_SH"
    assert_success
}

@test "arr-backup.sh refuses to reuse an existing staging dir" {
    # Plain mkdir, not mkdir -p: two runs in the same second would otherwise
    # interleave their staging files into one tarball.
    run grep -nE '^mkdir "\$BACKUP_DIR"' "$BACKUP_SH"
    assert_success

    run grep -nE '^mkdir -p "\$BACKUP_DIR"' "$BACKUP_SH"
    assert_failure
}

@test "rotation does not suppress find's errors" {
    # A rotation that cannot read the directory must say so; silence is the
    # failure mode this whole change exists to remove.
    run bash -c "grep -A 2 -- '-mtime \"+\\\$ROTATE_DAYS\"' '$BACKUP_SH' | grep -c '2>/dev/null'"
    assert_output "0"
}

# --- staging-directory cleanup on every exit path -------------------------------
#
# Until 2026-08-31 the /tmp staging copy was removed inline on the happy path only.
# /tmp on this NAS is tmpfs (RAM-backed) and each run stages ~220MB, so every FAILED
# run leaked a directory into RAM until the next reboot. Cleanup now lives in the
# EXIT trap, which covers normal, error and interrupt exits alike.
#
# These extract cleanup_on_exit() and run it directly rather than grepping for it:
# the previous version of this coverage asserted the literal string
# `rm -rf "$BACKUP_DIR"`, which said nothing about WHEN it ran -- and "when" was the
# entire bug.

load_cleanup() {
    local body
    body=$(awk -v s="cleanup_on_exit() {" 'index($0, s) == 1, /^\}$/' "$BACKUP_SH")
    [[ -n "$body" ]] || {
        echo "could not extract cleanup_on_exit() from $BACKUP_SH -- renamed?"
        return 1
    }
    grep -qx '}' <<<"$body" || {
        echo "extraction of cleanup_on_exit() never reached a closing brace; got:"
        echo "$body"
        return 1
    }
    # Stubbed: the handler shells out to docker (compose up, and the worker
    # teardown), which this file's header promises never to touch. Without these
    # the tests would silently depend on a docker binary being present.
    ensure_services_running() { :; }
    docker() { :; }
    eval "$body"
}

@test "cleanup_on_exit removes the staging dir when --tar was used" {
    load_cleanup
    CREATE_TAR=true
    STAGING_DIR="$BATS_TEST_TMPDIR/staging"
    mkdir -p "$STAGING_DIR"
    dd if=/dev/zero of="$STAGING_DIR/blob" bs=1024 count=8 2>/dev/null

    cleanup_on_exit

    [ ! -d "$STAGING_DIR" ] || {
        echo "staging dir survived cleanup_on_exit"
        return 1
    }
}

@test "cleanup_on_exit KEEPS the staging dir when --tar was not used" {
    # Without --tar the staging directory IS the backup. Removing it would delete
    # the only thing the run produced.
    load_cleanup
    CREATE_TAR=false
    STAGING_DIR="$BATS_TEST_TMPDIR/staging"
    mkdir -p "$STAGING_DIR"

    cleanup_on_exit

    [ -d "$STAGING_DIR" ] || {
        echo "cleanup_on_exit deleted the staging dir that WAS the backup"
        return 1
    }
}

@test "cleanup_on_exit never removes the tarball, only the staging directory" {
    # When the move to the final destination fails, the tarball left in /tmp is the
    # run's only output. It sits beside the staging dir and shares its name stem, so
    # a careless glob would take it too.
    load_cleanup
    CREATE_TAR=true
    STAGING_DIR="$BATS_TEST_TMPDIR/arr-stack-backup-20260831-010203"
    mkdir -p "$STAGING_DIR"
    local tarball="${STAGING_DIR}.tar.gz"
    echo "archive" > "$tarball"

    cleanup_on_exit

    [ ! -d "$STAGING_DIR" ] || { echo "staging dir survived"; return 1; }
    [ -f "$tarball" ] || {
        echo "cleanup removed $tarball -- that is the backup when the move failed"
        return 1
    }
}

@test "cleanup_on_exit is inert before the staging dir is armed" {
    # The trap is installed near the top of the script, long before CREATE_TAR and
    # STAGING_DIR exist. Under `set -u` an undefaulted expansion would abort the
    # handler with "unbound variable", masking whatever real failure was on its way
    # out. Asserted by reaching the line AFTER the call: the abort would skip it.
    #
    # Run in a fresh shell rather than via bats' `run`, because cleanup_on_exit
    # deliberately returns the status it inherited -- so its exit code says nothing
    # about whether it aborted, and only the marker does.
    local script="$BATS_TEST_TMPDIR/inert.sh"
    {
        echo 'set -euo pipefail'
        awk -v s="cleanup_on_exit() {" 'index($0, s) == 1, /^\}$/' "$BACKUP_SH"
        echo 'ensure_services_running() { :; }'
        echo 'cleanup_on_exit'
        echo 'echo REACHED_END'
    } > "$script"

    run bash "$script"
    [[ "$output" == *REACHED_END* ]] || {
        echo "cleanup_on_exit aborted before its variables were initialised:"
        echo "$output"
        return 1
    }
}

@test "the EXIT trap preserves the script's exit status" {
    # The last statement of arr-backup.sh is `exit 1` when any volume FAILED. A
    # cron `backup && prune` chain reads exactly that status to decide whether to
    # prune, so a handler that clobbered it would re-tell the lie this script was
    # fixed to stop telling.
    #
    # What this does and does not cover, established by mutation rather than
    # assumed: bash preserves the pending exit status whenever an EXIT trap
    # returns normally, so this cannot be broken by what the handler RETURNS.
    # What it DOES catch is a handler that calls `exit` itself -- the real
    # EXIT-trap footgun, and the one an "always exit cleanly" edit would add.
    # The other way to break it has its own test directly below.
    local script="$BATS_TEST_TMPDIR/exit-status.sh"
    {
        echo 'set -euo pipefail'
        awk -v s="cleanup_on_exit() {" 'index($0, s) == 1, /^\}$/' "$BACKUP_SH"
        echo 'ensure_services_running() { :; }'
        echo 'CREATE_TAR=false'
        echo 'STAGING_DIR=""'
        echo 'trap cleanup_on_exit EXIT'
        echo 'exit 1'
    } > "$script"

    run bash "$script"
    [ "$status" -eq 1 ] || {
        echo "expected exit 1 through the trap, got $status"
        return 1
    }
}

@test "there is exactly one EXIT trap in arr-backup.sh" {
    # bash keeps ONE EXIT trap: a second `trap ... EXIT` silently REPLACES the
    # first. Adding one for the staging cleanup would have disabled
    # ensure_services_running, the safety net that restarts stopped containers.
    run bash -c "grep -cE '^[^#]*trap .* EXIT' '$BACKUP_SH'"
    assert_output "1"
}

@test "STAGING_DIR is armed only after the mkdir collision guard" {
    # The mkdir is deliberately not -p: it fails when the directory already exists,
    # which means ANOTHER RUN owns it. Arming the trap before that guard would make
    # this run delete a concurrent run's staging copy on its way out.
    local mkdir_ln arm_ln
    mkdir_ln=$(grep -n '^mkdir "\$BACKUP_DIR"' "$BACKUP_SH" | cut -d: -f1)
    arm_ln=$(grep -n '^STAGING_DIR="\$BACKUP_DIR"' "$BACKUP_SH" | cut -d: -f1)
    [ -n "$mkdir_ln" ] || { echo "could not find the mkdir guard"; return 1; }
    [ -n "$arm_ln" ] || { echo "could not find the STAGING_DIR assignment"; return 1; }
    [ "$arm_ln" -gt "$mkdir_ln" ] || {
        echo "STAGING_DIR armed at line $arm_ln, before the mkdir guard at $mkdir_ln"
        return 1
    }
}

@test "the EXIT trap preserves the exit status when ensure_services_running FAILS" {
    # The dangerous case, and the one every other test here was blind to because
    # they all stub ensure_services_running as a no-op.
    #
    # Under `set -e` a non-zero return from a bare call inside the handler ABORTS
    # the handler and becomes the script's exit status. Measured: a script exiting
    # 0 exited 42 when this call returned 42 -- a clean backup reported as failed,
    # which makes a `backup && prune` cron chain skip pruning for good. The `|| true`
    # in the handler is what prevents it.
    local script="$BATS_TEST_TMPDIR/ensure-fails.sh"
    {
        echo 'set -euo pipefail'
        awk -v s="cleanup_on_exit() {" 'index($0, s) == 1, /^\}$/' "$BACKUP_SH"
        echo 'docker() { return 0; }'
        echo 'ensure_services_running() { return 42; }'
        echo 'CREATE_TAR=false'
        echo 'STAGING_DIR=""'
        echo 'trap cleanup_on_exit EXIT'
        echo 'exit 0'
    } > "$script"

    run bash "$script"
    [ "$status" -eq 0 ] || {
        echo "a successful run exited $status because the exit handler's own call failed"
        return 1
    }
}

@test "cleanup stops the copy worker before removing what it writes into" {
    # An interrupted run leaves the `arr-backup-worker` container orphaned: killing
    # the script does not stop it, and docker re-creates a bind mount's host
    # directory on demand. Measured on the NAS 2026-08-31 -- the staging path
    # reappeared root-owned seconds after cleanup removed it. Order matters: killing
    # the worker after the rm would race exactly the same way.
    local kill_ln rm_ln
    kill_ln=$(grep -n 'docker rm -f arr-backup-worker' "$BACKUP_SH" | head -1 | cut -d: -f1)
    rm_ln=$(grep -n 'rm -rf "\$STAGING_DIR"' "$BACKUP_SH" | head -1 | cut -d: -f1)
    [ -n "$kill_ln" ] || { echo "no arr-backup-worker teardown in the exit handler"; return 1; }
    [ -n "$rm_ln" ] || { echo "could not find the staging removal"; return 1; }
    [ "$kill_ln" -lt "$rm_ln" ] || {
        echo "worker teardown at line $kill_ln runs AFTER the staging rm at $rm_ln"
        return 1
    }
}

@test "cleanup waits for the copy client before removing the staging dir" {
    # `docker rm -f` alone does NOT make the teardown safe, and the test above is
    # therefore only half the guarantee. Measured on the NAS 2026-08-31: a SIGTERM
    # landing between the `docker run` client's create request and the daemon acting
    # on it left the rm -f matching nothing, the staging rm succeeding, and the
    # daemon then creating the container anyway -- re-making the bind-mount host
    # directory root-owned and copying a volume into it, after cleanup had already
    # printed "Cleaned up staging dir".
    #
    # The `wait` is the barrier that closes it: once the client has exited, nothing
    # is left that can re-create the directory. It must sit AFTER the rm -f (which
    # bounds how long it blocks) and BEFORE the staging rm (which is what it
    # protects). Asserting only that a `wait` exists somewhere would not catch it
    # being moved past the rm, which is the failure mode.
    local kill_ln wait_ln rm_ln
    kill_ln=$(grep -n 'docker rm -f arr-backup-worker' "$BACKUP_SH" | head -1 | cut -d: -f1)
    wait_ln=$(grep -n '^ *wait 2>/dev/null' "$BACKUP_SH" | head -1 | cut -d: -f1)
    rm_ln=$(grep -n 'rm -rf "\$STAGING_DIR"' "$BACKUP_SH" | head -1 | cut -d: -f1)
    [ -n "$wait_ln" ] || {
        echo "no 'wait' barrier in the exit handler -- an orphaned copy container"
        echo "can re-create the staging dir after it is removed"
        return 1
    }
    [ -n "$kill_ln" ] && [ -n "$rm_ln" ] || { echo "could not locate rm -f / staging rm"; return 1; }
    [ "$kill_ln" -lt "$wait_ln" ] || {
        echo "wait at line $wait_ln runs BEFORE the rm -f at $kill_ln - it would block"
        echo "for a full volume copy instead of a killed container"
        return 1
    }
    [ "$wait_ln" -lt "$rm_ln" ] || {
        echo "wait at line $wait_ln runs AFTER the staging rm at $rm_ln - the rm is unprotected"
        return 1
    }
}
