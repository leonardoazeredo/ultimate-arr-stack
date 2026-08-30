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
