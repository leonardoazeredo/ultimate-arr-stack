#!/usr/bin/env bats
#
# tests/toolkit/coverage.sh is a diagnostic, not a gate, so almost none of its
# behaviour is worth pinning. Two things are.
#
# The first is the 77 contract it shares with pytest.sh: an absent tool and a
# clean result must not be the same observable result. shellcheck.bats skipped
# green for months on hosts with no shellcheck, which is how that rule was
# learned here.
#
# The second is the blind-spots list. Its whole job is to excuse a zero -- to
# say "kcov structurally cannot see this file, do not read it as untested". A
# stale entry in that list is therefore worse than no list: it excuses a zero
# that nobody checked. So the list is asserted against reality in both the ways
# it can be wrong.

load helpers/setup

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    BLIND="$REPO_ROOT/tests/toolkit/kcov-blind-spots.txt"
}

blind_spot_files() {
    grep -vE '^\s*(#|$)' "$BLIND"
}

# Test files that use the awk-extract-and-eval idiom -- the one thing kcov
# cannot attribute, and therefore the only thing the blind-spots list is
# allowed to be about.
extraction_test_files() {
    local f
    for f in "$REPO_ROOT"/tests/*.bats; do
        if grep -q 'awk' "$f" && grep -q 'eval' "$f"; then echo "$f"; fi
    done
}

@test "coverage: coverage.sh exits 77, not 0, when docker is not on PATH" {
    local bin="$BATS_TEST_TMPDIR/curated"
    mkdir -p "$bin"
    local tool
    for tool in bash dirname pwd sha256sum cut id; do
        ln -s "$(command -v "$tool")" "$bin/$tool"
    done

    PATH="$bin" run "$REPO_ROOT/tests/toolkit/coverage.sh"
    [ "$status" -eq 77 ]
    [[ "$output" == *"no usable docker"* ]]
}

@test "coverage: coverage.sh exits 77, not 0, when the docker daemon is unreachable" {
    local bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin"
    cat > "$bin/docker" <<'STUB'
#!/bin/bash
echo "Cannot connect to the Docker daemon" >&2
exit 1
STUB
    chmod +x "$bin/docker"

    PATH="$bin:$PATH" run "$REPO_ROOT/tests/toolkit/coverage.sh"
    [ "$status" -eq 77 ]
    [[ "$output" == *"no usable docker"* ]]
}

@test "coverage: every blind spot names a file that exists" {
    local f missing=()
    while read -r f; do
        [ -f "$REPO_ROOT/$f" ] || missing+=("$f")
    done < <(blind_spot_files)

    if [ ${#missing[@]} -gt 0 ]; then
        printf 'blind-spot entry names no such file: %s\n' "${missing[@]}" >&2
        fail "kcov-blind-spots.txt is stale"
    fi
}

@test "coverage: every blind spot is actually tested by extraction" {
    # The direction that matters. A file listed here has its zero excused; if it
    # is not in fact extracted-and-eval'd, the list is hiding a real gap rather
    # than explaining a measurement artefact.
    local f bogus=()
    while read -r f; do
        if ! grep -lF "$f" $(extraction_test_files) >/dev/null 2>&1; then
            bogus+=("$f")
        fi
    done < <(blind_spot_files)

    if [ ${#bogus[@]} -gt 0 ]; then
        printf 'listed BLIND but no extraction test names it: %s\n' "${bogus[@]}" >&2
        fail "kcov-blind-spots.txt excuses a zero it should not"
    fi
}

@test "coverage: the blind-spots list is not empty" {
    # Both tests above pass vacuously against an empty list, which is exactly
    # the shape of guard this repo keeps finding merged and incapable of
    # failing. If the idiom is ever retired, delete the list and this file
    # together rather than letting them pass by matching nothing.
    [ -n "$(blind_spot_files)" ]
}
