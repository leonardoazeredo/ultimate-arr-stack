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
@test "fixture skips for an environment reason" {
    skip "no widget on this machine"
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

@test "the dirty-tree guard only considers targets the filter actually selected" {
    # -k exists to sweep ONE target while the rest of the tree is mid-edit, so a
    # guard that reads an unfiltered SELECTED refuses over files the run was
    # never going to touch. That is not merely an inconvenience: two entries in
    # tests/mutation/corpus/generative.sh were scored SURVIVED because of it,
    # their oracle having skipped on a dirty scripts/lib while the run was
    # measuring a fix to scripts/lib. An over-broad precondition launders itself
    # into a false measurement downstream.
    #
    # This runs against a THROWAWAY repo rather than this one, because the only
    # way to exercise a dirty-tree guard is to have a dirty tree, and dirtying a
    # tracked file here would need a restore -- which is exactly the bare-`cp`
    # interrupt window that already cost this repo a corrupted ledger. A copy
    # has no restore to skip.
    command -v git >/dev/null 2>&1 || skip "no host git binary"
    local r="$FX/r"
    mkdir -p "$r/tests/mutation" "$r/scripts/lib"
    cp "$REPO_ROOT/tests/mutation/run-generated.sh" \
       "$REPO_ROOT/tests/mutation/lib-mutate.sh" "$r/tests/mutation/"
    printf '#!/bin/bash\nexit 0\n' > "$r/tests/run-tests.sh"
    chmod +x "$r/tests/run-tests.sh" "$r/tests/mutation/run-generated.sh"
    # Every TARGETS path must exist and be committed: `git status --porcelain --`
    # errors out on a pathspec matching nothing, which would empty DIRTY and let
    # the mutant pass for the wrong reason.
    local t
    for t in $(sed -n '/^TARGETS=(/,/^)/p' "$REPO_ROOT/tests/mutation/run-generated.sh" \
               | grep -oE '"[^":]+\.sh:' | tr -d '":'); do
        mkdir -p "$r/$(dirname "$t")"; printf '#!/bin/bash\n:\n' > "$r/$t"
    done
    git -C "$r" init -q .
    git -C "$r" config user.email t@example.com
    git -C "$r" config user.name t
    git -C "$r" add -A && git -C "$r" commit -qm seed

    # One target dirty; the filter selects none of them.
    echo '# edited' >> "$r/scripts/lib/check-secrets.sh"

    MUTATION_LEDGER="$FX/led.tsv" run bash "$r/tests/mutation/run-generated.sh" \
        -k zzz-no-such-target
    # A filter matching nothing has nothing to protect, so the guard must stay
    # quiet about a file the run had already decided to ignore.
    [[ "$output" != *"refusing to start"* ]] || { echo "$output"; return 1; }
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "reports SKIPPED, not SURVIVED, when the whole oracle skipped" {
    # TAP spells a skipped test `ok N name # skip reason`, so to anything
    # reading the exit status it is a PASS. An oracle that skipped therefore
    # looks exactly like one that ran and did not notice the defect, and the
    # mutant gets scored SURVIVED -- a coverage gap invented out of an
    # environment condition, filed against a test that never executed.
    #
    # This is not hypothetical. Two entries in tests/mutation/corpus/generative.sh
    # read as SURVIVED during this work because their oracle skips while
    # scripts/lib is dirty, which it was, because the run was measuring a fix to
    # scripts/lib. The tool reported a coverage regression caused by nothing but
    # its own working tree.
    write_corpus <<CORPUS
mutation demo-skipped \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "skips for an environment reason" --why "x" \
  --apply 'sed -i s@yes@nope@ "\$F"'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"SKIPPED demo-skipped"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"SURVIVED"* ]] || { echo "$output"; return 1; }
    # and it says WHY, so the reader is not left to guess which guard fired
    [[ "$output" == *"no widget on this machine"* ]] || { echo "$output"; return 1; }
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

# --- the generative half ------------------------------------------------------

@test "take_backup refuses to arm the restore path from a subshell" {
    # This is not a hypothetical. Extracting the restore core into
    # lib-mutate.sh introduced exactly this bug: take_backup returned the
    # backup path by echoing it, so the caller wrote
    # `backup="$(take_backup ...)"` -- a command substitution, which is a
    # subshell. CURRENT_FILE/CURRENT_BACKUP were set inside it and died with
    # it, restore_current then took its legitimate "nothing to restore" path,
    # and the run finished having left five mutated files in the working tree.
    #
    # Reading the code did not catch it; run-mutations.sh did, on the next run.
    # The guard exists so the next person cannot reintroduce it silently.
    echo pristine > "$FX/subject"
    run bash -c "
        source '$REPO_ROOT/tests/mutation/lib-mutate.sh'
        out=\$(take_backup '$FX/subject' tag)
        echo \"status=\$?\"
        echo \"out=\$out\"
    "
    [[ "$output" == *"status=2"* ]] || {
        echo "take_backup returned success from a subshell, so the caller believes"
        echo "the restore path is armed when it is not:"; echo "$output"; return 1
    }
    [[ "$output" == *"subshell"* ]] || {
        echo "it failed without saying why:"; echo "$output"; return 1
    }
}

@test "take_backup arms the restore path when called plainly" {
    # The other half of the guard above. A refusal that fires unconditionally
    # would pass that test while making the tool useless -- this is the
    # assertion that keeps it honest.
    echo pristine > "$FX/subject"
    run bash -c "
        source '$REPO_ROOT/tests/mutation/lib-mutate.sh'
        take_backup '$FX/subject' tag || { echo REFUSED; exit 1; }
        echo \"backup=\$BACKUP_PATH\"
        echo \"current=\$CURRENT_FILE\"
        cmp -s '$FX/subject' \"\$BACKUP_PATH\" && echo BYTES_MATCH
    "
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"current=$FX/subject"* ]] || {
        echo "CURRENT_FILE was not set, so restore_current would no-op:"
        echo "$output"; return 1
    }
    [[ "$output" == *"BYTES_MATCH"* ]] || {
        echo "the backup is not a byte copy of the target:"; echo "$output"; return 1
    }
}

@test "the generative runner refuses to start on a dirty target" {
    # It overwrites tracked files in place. On a dirty tree a failed restore is
    # indistinguishable from the user's own uncommitted work, and the documented
    # recovery -- `git checkout --` -- would destroy that work.
    local target="scripts/lib/check-secrets.sh"
    cp "$REPO_ROOT/$target" "$FX/pristine"
    printf '\n# dirt introduced by %s\n' "$BATS_TEST_NAME" >> "$REPO_ROOT/$target"

    run "$REPO_ROOT/tests/mutation/run-generated.sh" "$target"
    cp "$FX/pristine" "$REPO_ROOT/$target"

    [ "$status" -ne 0 ] || {
        echo "the runner started against a dirty target. A failed restore would"
        echo "then be indistinguishable from the user's own edits:"
        echo "$output"; return 1
    }
    [[ "$output" == *"refusing to start"* && "$output" == *"$target"* ]] || {
        echo "it refused without naming the file that blocked it:"
        echo "$output"; return 1
    }
}

@test "mutant generation reports an absent docker distinctly, not as success" {
    # 77, not 0. "docker is unavailable" and "the sweep found nothing" must
    # never be the same observable result -- that equivalence is the single
    # defect shape this whole directory exists to remove, and sync-nas.sh
    # already shipped it once (unreachable NAS exited 0, silently).
    # A stub docker that fails, which is the realistic shape of this: the
    # binary is installed and the daemon is not answering. PATH=/nonexistent
    # would remove bash along with docker and prove nothing.
    mkdir -p "$FX/bin"
    printf '#!/bin/sh\nexit 1\n' > "$FX/bin/docker"
    chmod +x "$FX/bin/docker"
    run env PATH="$FX/bin:$PATH" bash "$REPO_ROOT/tests/mutation/mutator.sh" \
        "$REPO_ROOT/scripts/lib/check-secrets.sh" "$FX/out"
    [ "$status" -eq 77 ] || {
        echo "expected 77 (docker unavailable), got $status:"; echo "$output"; return 1
    }
}

@test "the ledger path is overridable so a test never writes to the repo's own" {
    # The seam that makes the test below safe to interrupt. Without it that test
    # has to overwrite the tracked survivors.tsv and copy it back at the end,
    # and anything that kills the sweep in between -- a timeout, a Ctrl-C --
    # leaves the repo holding sentinel rows that look enough like real triage
    # output to be committed by accident. That is not hypothetical: it happened
    # during the session that added this test.
    #
    # A -k that matches no target sweeps nothing, so this needs no docker and
    # costs nothing, while still exercising the one line that decides where the
    # ledger is written.
    local probe="$FX/probe-ledger.tsv"
    local real="$REPO_ROOT/tests/mutation/survivors.tsv"
    cp "$real" "$FX/real.before"

    MUTATION_LEDGER="$probe" run "$REPO_ROOT/tests/mutation/run-generated.sh" -k zzz-no-such-target
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    [ -f "$probe" ] || {
        echo "MUTATION_LEDGER was ignored - the runner wrote somewhere else."
        return 1
    }
    diff -q "$FX/real.before" "$real" || {
        echo "the runner wrote the REPO's ledger despite MUTATION_LEDGER being set."
        echo "every test that exercises ledger merging now corrupts tracked state."
        return 1
    }
}

@test "a partial sweep does not delete ledger rows for targets it did not sweep" {
    # The regression this exists for: the ledger used to be rebuilt from the
    # current run's survivors alone. Any run that did not sweep everything -- a
    # -k filter, a positional target, a target that SKIPped for want of docker,
    # a target that ERRORed -- silently deleted every row it had not just
    # regenerated. Five hand-assigned verdicts were lost that way, and the
    # "two consecutive sweeps produce an identical ledger" check could not see
    # it, because both of those sweeps were full ones.
    #
    # Both directions are asserted. A rule that only preserved rows would be
    # satisfied by never rewriting anything, which would strand verdicts for
    # mutations that no longer exist.
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
        || skip "no usable docker daemon to generate mutants in"
    [ -z "$(cd "$REPO_ROOT" && git status --porcelain -- scripts/lib/)" ] \
        || skip "scripts/lib is dirty; the runner refuses to sweep it (by design)"

    # A throwaway ledger, NOT the repo's. This test used to overwrite the
    # tracked survivors.tsv and copy it back at the end; an interrupt between
    # those two points left the sentinel rows committed-ready in the working
    # tree, which is exactly what happened once during this work. $MUTATION_LEDGER
    # is the seam that removes the shared-state mutation altogether, so there is
    # no window to interrupt and no restore that can be skipped.
    local ledger="$FX/survivors.tsv"

    # One row for a target this run will NOT sweep, carrying a hand verdict...
    # ...and one for a target it WILL sweep, describing a mutation that does not
    # exist, which must therefore be dropped.
    {
        printf '#file\tline\tmutation\tverdict\tnote\n'
        printf 'scripts/lib/check-conflicts.sh\t99\tSENTINEL_NOT_SWEPT ==> x\twontfix\tkeep me\n'
        printf 'scripts/lib/check-env-vars.sh\t1\tSENTINEL_STALE ==> x\tequivalent\tdrop me\n'
    } > "$ledger"

    MUTATION_LEDGER="$ledger" run "$REPO_ROOT/tests/mutation/run-generated.sh" -k check-env-vars
    local rc="$status" out="$output"
    local after
    after="$(cat "$ledger")"

    [ "$rc" -eq 0 ] || { echo "the runner must always exit 0:"; echo "$out"; return 1; }

    [[ "$after" == *"SENTINEL_NOT_SWEPT"* ]] || {
        echo "a filtered run deleted the ledger row for a target it never swept."
        echo "every hand-assigned verdict outside the filter is lost this way."
        echo "$after"; return 1
    }
    [[ "$after" == *"wontfix"$'\t'"keep me"* ]] || {
        echo "the carried row lost its verdict or note:"; echo "$after"; return 1
    }
    [[ "$after" != *"SENTINEL_STALE"* ]] || {
        echo "a stale row for a SWEPT target was preserved. Rows for a target the"
        echo "run actually swept must be replaced by what that sweep found:"
        echo "$after"; return 1
    }
}

# Fields whose contents are PROSE and are therefore never allowed to be
# evaluated. --apply is deliberately absent: it is single-quoted shell by
# design and is the one field that is supposed to contain code.
scan_corpus_prose() {
    grep -n '^  --\(why\|test\|file\|bats\) ' "$1"/*.sh \
        | grep -P '(?<!\\)(`|\$\()' || true
}

@test "no corpus prose field can execute anything when the file is sourced" {
    # Corpus files are SOURCED by run-mutations.sh, so a backtick or $( ) left
    # unescaped inside a double-quoted --why or --test runs as a command before
    # any mutation is applied. This was not hypothetical: two entries shipped
    # that way and one of them executed `check-vpn.sh || notify` on every run of
    # the whole corpus. It found neither name on PATH; a prose field that
    # happened to name a real command would not have been so lucky.
    local bad
    bad=$(scan_corpus_prose "$REPO_ROOT/tests/mutation/corpus")
    if [ -n "$bad" ]; then
        fail "$(printf 'a corpus prose field would be evaluated when sourced:\n%s' "$bad")"
    fi
}

@test "the corpus prose scan actually catches an evaluating field" {
    # This guard gets no corpus entry, and not by omission. The only way to
    # mutate it is to reintroduce an unescaped substitution into a real corpus
    # file - and run-mutations.sh SOURCES every corpus file on every run, so the
    # mutation would execute the very thing the guard exists to prevent, in the
    # runner, before any test could observe it. A fixture proves the same thing
    # without arming it.
    local dir="$BATS_TEST_TMPDIR/corpus"
    mkdir -p "$dir"
    cat > "$dir/clean.sh" <<'EOF'
mutation fine \
  --why "a \`quoted\` name and a literal \$(not a substitution)" \
  --apply 'sed -i "s@a@b@" "$F"'
EOF
    run scan_corpus_prose "$dir"
    assert_success
    [ -z "$output" ] || fail "flagged a correctly escaped corpus file: $output"

    printf '%s\n' 'mutation bad \' '  --why "the consumer, `notify`, never fires" \' > "$dir/bad.sh"
    run scan_corpus_prose "$dir"
    assert_output --partial "bad.sh"

    printf '%s\n' 'mutation bad2 \' '  --test "runs $(id -u) at source time" \' > "$dir/bad2.sh"
    run scan_corpus_prose "$dir"
    assert_output --partial "bad2.sh"
}
