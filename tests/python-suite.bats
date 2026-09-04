#!/usr/bin/env bats
# The Python half of the suite, and the contract of the runner that carries it.
#
# scripts/lib/*.py were heredocs inside their shell scripts until 2026-09-01.
# Nothing could import them, so ~460 lines of the repo's densest logic -- date
# classification, token substitution, title normalisation, pagination -- had no
# test of any kind. They are modules now, and this file is what makes them part
# of `./tests/run-tests.sh` rather than a suite someone has to remember to run.
#
# pytest itself is containerised (tests/toolkit/), for the same reason git and
# shellcheck are: pi1 has no pip and PEP 668 forbids installing one.

setup() {
    load helpers/setup
}

@test "python: the extracted modules pass their pytest suite" {
    run "$REPO_ROOT/tests/toolkit/pytest.sh"
    if [ "$status" -eq 77 ]; then
        skip "docker unavailable: $output"
    fi
    [ "$status" -eq 0 ] || {
        echo "$output"
        false
    }
}

# The runner must report a missing tool as a missing tool. This repo has been
# burned twice by the opposite: sync-nas.sh exited 0 on an unreachable NAS, and
# shellcheck.bats skipped green for months on hosts with no shellcheck. An
# absent oracle and a passing oracle must never be the same observable result.
@test "python: pytest.sh exits 77, not 0, when docker is not on PATH" {
    local bin="$BATS_TEST_TMPDIR/curated"
    mkdir -p "$bin"
    # Everything pytest.sh needs before it reaches the docker check -- and
    # deliberately not docker itself.
    local tool
    for tool in bash dirname pwd sha256sum cut id; do
        ln -s "$(command -v "$tool")" "$bin/$tool"
    done

    PATH="$bin" run "$REPO_ROOT/tests/toolkit/pytest.sh"
    [ "$status" -eq 77 ]
    [[ "$output" == *"no usable docker"* ]]
}

@test "python: pytest.sh falls back to the default cap on a non-numeric override" {
    # MEM_KB's fallback ("[[ "$MEM_KB" =~ ^[0-9]+$ ]] || MEM_KB=524288") is
    # shell arithmetic nothing else exercises. If it were missing, a garbage
    # override would reach `ulimit -v` directly, which rejects a non-numeric
    # argument and pytest.sh would exit 1 instead of running under the
    # default cap -- a clear behavioural difference, not just "still passes".
    PYTEST_ADDRESS_SPACE_KB=bogus run "$REPO_ROOT/tests/toolkit/pytest.sh" \
        tests/python/test_oracle_environment.py
    if [ "$status" -eq 77 ]; then
        skip "docker unavailable: $output"
    fi
    [ "$status" -eq 0 ] || {
        echo "$output"
        false
    }
}

@test "python: pytest.sh exits 77, not 0, when the docker daemon is unreachable" {
    local bin="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin"
    # Present on PATH, but `docker info` fails -- a stopped daemon, or a user
    # outside the docker group. `command -v` alone would call this available.
    cat > "$bin/docker" <<'STUB'
#!/bin/bash
echo "Cannot connect to the Docker daemon" >&2
exit 1
STUB
    chmod +x "$bin/docker"

    PATH="$bin:$PATH" run "$REPO_ROOT/tests/toolkit/pytest.sh"
    [ "$status" -eq 77 ]
    [[ "$output" == *"no usable docker"* ]]
}

# Derived at run time rather than listed, so a new module cannot be added
# without a test file and have nothing notice. The same reasoning as
# shellcheck.bats's shebang-derived file list.
@test "python: every module in scripts/lib has a test file" {
    local missing=() f base
    for f in "$REPO_ROOT"/scripts/lib/*.py; do
        [ -e "$f" ] || continue
        base="$(basename "$f" .py)"
        [ -f "$REPO_ROOT/tests/python/test_$base.py" ] || missing+=("$base")
    done
    [ "${#missing[@]}" -eq 0 ] || {
        echo "no tests/python/test_<name>.py for: ${missing[*]}"
        false
    }
}
