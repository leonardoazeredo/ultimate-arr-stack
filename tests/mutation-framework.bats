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
