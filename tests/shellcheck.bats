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
        if head -c 64 "$REPO_ROOT/$f" | head -1 | grep -qE '^#!.*(bash|/sh)'; then
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
    [ "${#files[@]}" -gt 10 ] || fail "only ${#files[@]} shell scripts found; the discovery is broken, not the repo"

    if command -v shellcheck >/dev/null 2>&1; then
        run shellcheck -S error -- "${files[@]}"
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        run docker run --rm -v "$REPO_ROOT:/mnt" -w /mnt \
            koalaman/shellcheck:stable -S error -- "${files[@]}"
    else
        skip "no shellcheck binary and no usable docker daemon to run it in"
    fi

    [ "$status" -eq 0 ] || fail "shellcheck errors across ${#files[@]} files:"$'\n'"$output"
}
