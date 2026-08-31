#!/usr/bin/env bats
# The mutation runner is itself a verification tool, so it gets the same
# treatment it imposes: it is only trusted once it has been watched producing
# every verdict it can produce.
#
# This is not paranoia about a shell script. A harness in this project once
# reported five straight passes because its own `cmp` guard inverted its exit
# status -- the mutations were never applied and the tool said they all worked.
# A mutation runner that cannot report SURVIVED is worse than none: it converts
# every vacuous test in the suite into a certificate that the test is sound.

setup() {
    load helpers/setup
    command -v git >/dev/null 2>&1 \
        || skip "no host git binary on this machine (the NAS drives this repo through a containerised alpine/git)"
    RUNNER="$REPO_ROOT/tests/mutation/run-mutations.sh"
    FX="$BATS_TEST_TMPDIR/fx"
    mkdir -p "$FX"

    # A subject with one guarded behaviour ...
    cat > "$FX/target.sh" <<'SUBJ'
#!/bin/bash
if [[ "$1" == "ok" ]]; then echo yes; else echo no; fi
SUBJ

    # ... and two tests: one that inspects the behaviour, one that only checks
    # the exit status and therefore cannot see the behaviour change at all.
    cat > "$FX/fixture.bats" <<'FXB'
setup() { TARGET="${BATS_TEST_FILENAME%/*}/target.sh"; }
@test "fixture asserts the guarded output" {
    run bash "$TARGET" ok
    [ "$output" = "yes" ]
}
@test "fixture asserts only the exit status" {
    run bash "$TARGET" ok
    [ "$status" -eq 0 ]
}
FXB
}

write_corpus() { cat > "$FX/corpus.sh"; }

@test "reports KILLED when the test detects the mutation" {
    write_corpus <<CORPUS
mutation demo-killed \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts the guarded output" --why "x" \
  --apply 'sed -i s@yes@nope@ "\$F"'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"KILLED demo-killed"* ]] || { echo "$output"; return 1; }
}

@test "reports SURVIVED when the test cannot detect the mutation" {
    write_corpus <<CORPUS
mutation demo-survived \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts only the exit status" --why "the test never looks at the output" \
  --apply 'sed -i s@yes@nope@ "\$F"'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"
    [[ "$output" == *"SURVIVED demo-survived"* ]] || {
        echo "the runner could not report a vacuous test. Everything it has ever"
        echo "called KILLED would be worthless."
        echo "$output"; return 1
    }
    [ "$status" -ne 0 ] || { echo "a survivor must fail the run, got exit 0"; return 1; }
}

@test "errors instead of scoring a mutation that changed nothing" {
    write_corpus <<CORPUS
mutation demo-noop \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts the guarded output" --why "x" \
  --apply 'true'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"
    [[ "$output" == *"ERROR  demo-noop"* && "$output" == *"changed NOTHING"* ]] || {
        echo "a mutation that never applied was scored as a result. This is the"
        echo "exact failure the previous harness had, five times in a row."
        echo "$output"; return 1
    }
    [ "$status" -ne 0 ]
}

@test "errors instead of scoring a filter that matches no tests" {
    write_corpus <<CORPUS
mutation demo-badfilter \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "this test name does not exist anywhere" --why "x" \
  --apply 'sed -i s@yes@nope@ "\$F"'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"
    [[ "$output" == *"ERROR  demo-badfilter"* && "$output" == *"matched NO tests"* ]] || {
        echo "bats exits 0 after running nothing; that must never read as a pass."
        echo "$output"; return 1
    }
    [ "$status" -ne 0 ]
}

@test "errors instead of scoring a test that was already failing" {
    cat > "$FX/target.sh" <<'BROKEN'
#!/bin/bash
echo definitely-not-yes
BROKEN
    write_corpus <<CORPUS
mutation demo-already-red \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts the guarded output" --why "x" \
  --apply 'sed -i s@definitely@surely@ "\$F"'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"
    [[ "$output" == *"ERROR  demo-already-red"* && "$output" == *"already failing"* ]] || {
        echo "a red test failing again proves nothing about the mutation."
        echo "$output"; return 1
    }
    [ "$status" -ne 0 ]
}

@test "restores the target byte-for-byte after every verdict" {
    local before; before=$(sha256sum < "$FX/target.sh")
    write_corpus <<CORPUS
mutation demo-a \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts the guarded output" --why "x" \
  --apply 'sed -i s@yes@nope@ "\$F"'
mutation demo-b \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts only the exit status" --why "x" \
  --apply 'sed -i s@no@maybe@ "\$F"'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"
    local after; after=$(sha256sum < "$FX/target.sh")
    [ "$before" = "$after" ] || {
        echo "the runner left the tree mutated. A mutated file looks exactly"
        echo "like an ordinary edit, which is the worst way to lose one."
        return 1
    }
}

@test "-k restricts the run to matching mutation ids" {
    write_corpus <<CORPUS
mutation demo-alpha \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts the guarded output" --why "x" \
  --apply 'sed -i s@yes@nope@ "\$F"'
mutation demo-beta \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts the guarded output" --why "x" \
  --apply 'sed -i s@no@maybe@ "\$F"'
CORPUS
    run "$RUNNER" -k alpha "$FX/corpus.sh"
    [[ "$output" == *"demo-alpha"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"demo-beta"* ]] || { echo "-k did not filter: $output"; return 1; }
    [[ "$output" == *"skipped 1"* ]] || { echo "skips are not accounted for: $output"; return 1; }
}

@test "the NAS-sync corpus is wired to files that still exist" {
    # A corpus entry pointing at a renamed file errors rather than silently
    # covering nothing, but nobody reads a report they assume is green. This
    # asserts the wiring directly so a rename fails the ordinary suite.
    local corpus="$REPO_ROOT/tests/mutation/corpus/nas-sync.sh"
    [ -f "$corpus" ] || { echo "corpus is missing"; return 1; }
    local f
    while read -r f; do
        [ -f "$REPO_ROOT/$f" ] || { echo "corpus targets a missing file: $f"; return 1; }
    done < <(grep -oE -- '--file [^ ]+' "$corpus" | awk '{print $2}' | sort -u)
    while read -r f; do
        [ -f "$REPO_ROOT/$f" ] || { echo "corpus targets a missing bats file: $f"; return 1; }
    done < <(grep -oE -- '--bats [^ ]+' "$corpus" | awk '{print $2}' | sort -u)
}

@test "a failed restore is fatal and keeps the pristine copy" {
    # The runner's own defect class, turned on itself. The first version printed
    # FATAL, carried on, and could still finish with every mutation KILLED and
    # exit 0 while a mutated file sat in the tree -- indistinguishable from an
    # ordinary edit. It then rm -rf'd the backup directory the FATAL message had
    # just told the reader to restore from.
    #
    # cp to an existing unwritable file fails for a non-root user, so chmod 444
    # after mutating is a faithful stand-in for a restore that cannot happen.
    if [ "$(id -u)" -eq 0 ]; then
        skip "root ignores the write bit, so a failed restore cannot be simulated"
    fi
    # Do not assume this platform's `cp` refuses an unwritable destination. If
    # it happily overwrites, the mutation restores cleanly, the runner exits 0,
    # and this test fails for a reason that has nothing to do with the runner.
    # Prove the premise here, and skip honestly if it does not hold -- a test
    # that cannot set up its own scenario must say so, not report a verdict.
    echo probe > "$FX/probe"; echo other > "$FX/probe.src"; chmod 444 "$FX/probe"
    if cp "$FX/probe.src" "$FX/probe" 2>/dev/null; then
        chmod 644 "$FX/probe"
        skip "this platform's cp overwrites an unwritable file; cannot simulate a failed restore"
    fi
    chmod 644 "$FX/probe"
    write_corpus <<CORPUS
mutation demo-unrestorable \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts the guarded output" --why "x" \
  --apply 'sed -i s@yes@nope@ "\$F"; chmod 444 "\$F"'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"
    chmod 644 "$FX/target.sh"

    [ "$status" -ne 0 ] || {
        echo "the runner exited 0 having left a mutated file in the tree."
        echo "$output"; return 1
    }
    [[ "$output" == *"FATAL"* && "$output" == *"could not restore"* ]] || {
        echo "a failed restore said nothing identifiable."
        echo "$output"; return 1
    }

    # The message names a path to restore from by hand. It has to still be there.
    local backup_dir
    backup_dir=$(grep -oE '/tmp/[^ ]*\.orig' <<<"$output" | head -1)
    [ -n "$backup_dir" ] || { echo "no backup path was reported: $output"; return 1; }
    [ -f "$backup_dir" ] || {
        echo "the runner deleted the very backup it told the reader to use:"
        echo "  $backup_dir"
        return 1
    }
    grep -q 'echo yes' "$backup_dir" || { echo "the kept backup is not pristine"; return 1; }
}

@test "a vanished backup is fatal, not a silent no-op" {
    # restore_current's guard used to be one condition covering two very
    # different situations: nothing to restore (fine) and the backup is gone
    # (the tree is mutated and unrecoverable). Both returned 0, silently.
    #
    # --apply runs under `bash -c` with only $F exported, so it cannot read
    # $CURRENT_BACKUP. It does not need to: the backup is named after the
    # mutation id, so the fixture can find it.
    write_corpus <<CORPUS
mutation demo-lostbackup \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts the guarded output" --why "x" \
  --apply 'sed -i s@yes@nope@ "\$F"; find "\${TMPDIR:-/tmp}" -maxdepth 2 -name demo-lostbackup.orig -delete'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"

    [ "$status" -ne 0 ] || {
        echo "the runner exited 0 with a mutated file and no backup of it."
        echo "$output"; return 1
    }
    # Assert on a phrase that appears ONLY in the missing-backup branch. The
    # first version of this checked for "vanished", which also appears in the
    # backup's own filename (it is named after the mutation id) -- so the
    # assertion was satisfied by the fixture's own test data and passed with the
    # guard disabled. An assertion matching an incidental substring of its
    # inputs is exactly the vacuous-test shape this file exists to catch, and it
    # got in here.
    [[ "$output" == *"FATAL"* && "$output" == *"nothing left to restore"* ]] || {
        echo "a missing backup was treated as nothing-to-do."
        echo "$output"; return 1
    }
}
