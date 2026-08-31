#!/usr/bin/env bats
# Shellcheck baseline.
#
# This file was merged as coverage and then never ran once, on any machine in
# this project. It skipped when `shellcheck` was absent, and shellcheck is
# absent on pi1 AND on the NAS -- the only two hosts that run this suite. So it
# reported a green skip forever while checking nothing, which is the same shape
# as the four tests this repo has already had to throw out for being incapable
# of failing. It now runs through `koalaman/shellcheck:stable` when no host
# binary exists, the pattern this repo already uses for tools the host lacks
# (alpine/git for git, the Playwright image for e2e), and skips only when
# neither shellcheck nor Docker is available -- saying which.
#
# The file list is derived from shebangs, not from `scripts/*.sh`. The old glob
# silently excluded `scripts/post-merge` and `scripts/pre-commit` -- both git
# hooks, both load-bearing, both extensionless -- along with the CGI scripts in
# duc-service/ and this suite's own tooling. A file becomes covered the moment
# it declares itself a shell script, rather than whenever someone remembers to
# widen a glob.
#
# Scoped to `-S error` only: the repo carries pre-existing info/warning-level
# findings (SC2086 unquoted vars, SC2012 `ls` usage, SC2034 unused vars) that
# are out of scope here. This check exists to catch genuine bugs -- broken
# syntax, invalid redirections, an unknown dialect -- not to gate on style.
# Widening the severity stays a separate, deliberate decision.

setup() {
    load helpers/setup
}

# Every tracked file that declares itself a shell script, minus the vendored
# bats-core submodule (not ours to fix).
shell_files() {
    local f
    while read -r f; do
        [ -f "$REPO_ROOT/$f" ] || continue
        case "$f" in
            tests/bats-core/*) continue ;;
            *.sh) echo "$f"; continue ;;
            *.bats|*.md|*.yml|*.yaml|*.json) continue ;;
        esac
        # Match the interpreter WORD, not a path fragment. The first version
        # was '^#!.*(bash|/sh)', which misses `#!/usr/bin/env sh` entirely --
        # no `/sh` substring, no `bash` -- so such a file would be silently
        # uncovered. The \b keeps `#!/usr/bin/env fish` and `.../python` out.
        if head -c 64 "$REPO_ROOT/$f" | head -1 \
           | grep -qE '^#!.*\b(ba|da|k|z)?sh([[:space:]]|$)'; then
            echo "$f"
        fi
    done < <(git -C "$REPO_ROOT" ls-files)
}

@test "every tracked shell script is free of shellcheck errors" {
    command -v git >/dev/null 2>&1 \
        || skip "no host git binary (the NAS drives this repo through a containerised alpine/git)"

    local files
    mapfile -t files < <(shell_files)

    # A file list that came back empty would make this pass while checking
    # nothing -- the exact failure this rewrite exists to remove.
    # 10 is a floor, not a count: scripts/lib/ alone holds a dozen check-*.sh,
    # so any real state of this repo is far above it and a result below it means
    # the discovery broke rather than that the scripts went away. Deliberately
    # not pinned to an exact number -- that is how the old "14 tests" claim in
    # CLAUDE.md went stale.
    [ "${#files[@]}" -gt 10 ] || fail "only ${#files[@]} shell scripts found; the discovery is broken, not the repo"

    if command -v shellcheck >/dev/null 2>&1; then
        run shellcheck -S error -- "${files[@]}"
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        # Check the image is actually present before running it. Without this,
        # an offline host or a registry hiccup makes this test FAIL with a pull
        # error -- a red suite for a reason that has nothing to do with the
        # code, which this repo has already been bitten by once in CI.
        if ! docker image inspect koalaman/shellcheck:stable >/dev/null 2>&1 \
           && ! docker pull -q koalaman/shellcheck:stable >/dev/null 2>&1; then
            skip "shellcheck image is not available locally and cannot be pulled"
        fi
        run docker run --rm -v "$REPO_ROOT:/mnt" -w /mnt \
            koalaman/shellcheck:stable -S error -- "${files[@]}"
    else
        skip "no shellcheck binary and no usable docker daemon to run it in"
    fi

    [ "$status" -eq 0 ] || fail "shellcheck errors across ${#files[@]} files:"$'\n'"$output"
}
