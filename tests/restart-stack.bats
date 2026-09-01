#!/usr/bin/env bats
# scripts/restart-stack.sh, and the proof that the harness guarding it works.
#
# Every path through this script ends in `docker compose ... up -d
# --force-recreate` against the live stack. On the NAS that is Pi-hole, Traefik
# and the VPN tunnel going down and back up. It is the single most destructive
# script in the repo to drive from a test, which makes it the right one to
# prove the safety harness against: if forbid() can stop THIS, the rest of
# Phase 3 is safe to write.
#
# The dispatcher's own behaviour - aliases, the ${1:-all} default, the
# traefik-before-arr-stack ordering - is pinned in Phase 3, once the script has
# a main-guard and can be sourced. These tests deliberately touch no production
# code: the harness has to be trustworthy BEFORE anything is refactored on the
# strength of it.

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init
    # If this ever runs for real, the test has already failed - but say so
    # loudly rather than silently succeeding at a live restart.
    stub_docker 'echo "STUB RAN A REAL DOCKER COMMAND" >&2; exit 1'
}

@test "restart-stack: the harness stops 'all' before it reaches a live restart" {
    run "$REPO_ROOT/scripts/restart-stack.sh" all
    assert_forbidden "verb: compose up"
    [ "$status" -eq 99 ]
}

@test "restart-stack: the harness stops the default (no argument) invocation" {
    # ${1:-all} means a bare call is the widest possible blast radius.
    run "$REPO_ROOT/scripts/restart-stack.sh"
    assert_forbidden "verb: compose up"
    [ "$status" -eq 99 ]
}

@test "restart-stack: the harness stops each individual stack target" {
    for target in arr traefik cloudflared utilities; do
        rm -f "$STUB_FORBIDDEN"
        run "$REPO_ROOT/scripts/restart-stack.sh" "$target"
        [ "$status" -eq 99 ] || { echo "target '$target' exited $status, not 99"; return 1; }
        assert_forbidden "verb: compose up" || return 1
    done
}

@test "restart-stack: an unknown target never reaches docker at all" {
    # The usage arm is the one path with no side effect, so it is the one arm
    # that can be asserted positively rather than by interception.
    run "$REPO_ROOT/scripts/restart-stack.sh" nonsense
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
    assert_nothing_forbidden
    [ ! -s "$STUB_LOG" ]
}

@test "restart-stack: 'down' is never in the argv on any path" {
    # The script's header states this as its reason to exist: `down` kills
    # Pi-hole and takes the house's DNS with it. Assert it on the argv that was
    # actually built, not on the text of the file - a comment cannot regress,
    # and a grep of the source would pass on a script that never ran.
    for target in all arr traefik cloudflared utilities; do
        run "$REPO_ROOT/scripts/restart-stack.sh" "$target"
    done
    run grep -c 'down' "$STUB_LOG"
    [ "$output" = "0" ]
}
