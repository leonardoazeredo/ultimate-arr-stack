#!/usr/bin/env bats
# Regression guard: the pre-commit hook (which runs check_conflicts, among
# other blocking checks) must actually be installed, or none of those checks
# ever run before a commit lands. A prior static-IP collision reached the
# repo uncaught specifically because this hook was never installed — the
# detection logic in check-conflicts.sh was correct the whole time; nothing
# was invoking it. Run ./setup-hooks.sh if this test fails.

setup() {
    load helpers/setup
}

@test "pre-commit hook is installed and points at scripts/pre-commit" {
    # The NAS has no host git binary at all - it drives this repo through a
    # containerised alpine/git - so this test failed there with
    # 'git: command not found', which says nothing about whether the hook is
    # installed. Same skip-with-a-reason treatment as the index-mode check in
    # backup-retention.bats.
    #
    # Deliberately keyed on the binary, not on "is this a dev machine": the NAS
    # is not a commit host and never installs these hooks, but the honest reason
    # this cannot be checked there is that the tool to check it is absent.
    command -v git >/dev/null 2>&1 \
        || skip "no host git binary on this machine (the NAS drives this repo through a containerised alpine/git)"

    local git_common_dir
    git_common_dir=$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)
    local hook_path="$git_common_dir/hooks/pre-commit"

    if [[ ! -e "$hook_path" ]]; then
        fail "Pre-commit hook not installed at $hook_path — run ./setup-hooks.sh"
    fi

    if [[ -L "$hook_path" ]]; then
        local target
        target=$(readlink "$hook_path")
        [[ "$target" == *"scripts/pre-commit" ]] || fail "Pre-commit hook symlink points at unexpected target: $target"
    fi
}

@test "post-merge hook is installed and points at scripts/post-merge" {
    # The NAS has no host git binary at all - it drives this repo through a
    # containerised alpine/git - so this test failed there with
    # 'git: command not found', which says nothing about whether the hook is
    # installed. Same skip-with-a-reason treatment as the index-mode check in
    # backup-retention.bats.
    #
    # Deliberately keyed on the binary, not on "is this a dev machine": the NAS
    # is not a commit host and never installs these hooks, but the honest reason
    # this cannot be checked there is that the tool to check it is absent.
    command -v git >/dev/null 2>&1 \
        || skip "no host git binary on this machine (the NAS drives this repo through a containerised alpine/git)"

    local git_common_dir
    git_common_dir=$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)
    local hook_path="$git_common_dir/hooks/post-merge"

    if [[ ! -e "$hook_path" ]]; then
        fail "post-merge hook not installed at $hook_path — run ./setup-hooks.sh"
    fi

    if [[ -L "$hook_path" ]]; then
        local target
        target=$(readlink "$hook_path")
        [[ "$target" == *"scripts/post-merge" ]] || fail "post-merge hook symlink points at unexpected target: $target"
    fi
}
