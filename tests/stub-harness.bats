#!/usr/bin/env bats
# The safety harness, tested by MAKING IT FIRE.
#
# tests/helpers/stubs.bash is the only thing standing between a test that drives
# scripts/restart-stack.sh and a live `docker compose up` against a NAS that is
# serving the house's DNS. A guard nobody has watched fail is a guard nobody
# knows anything about - this repo has shipped four of those already (see
# docs/TEST-HARDENING-LOG.md §8), and reading them caught none of them.
#
# So every rule below is asserted in BOTH directions: the thing it must catch,
# and the near-miss it must NOT catch. A denylist that fires on everything is
# just as useless as one that fires on nothing, because the first test to hit a
# false positive is the one that gets the guard deleted.

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init
}

# --- The log ----------------------------------------------------------------

@test "stubs: a stub records the argv it was called with, not just that it ran" {
    stub_docker 'echo ok'
    run docker ps --filter name=gluetun
    [ "$status" -eq 0 ]
    assert_stub_called docker "ps --filter name=gluetun"
}

@test "stubs: the log lives under BATS_TEST_TMPDIR so it cannot grow across runs" {
    [[ "$STUB_LOG" == "$BATS_TEST_TMPDIR"/* ]]
}

@test "stubs: a stub body sees the real argv" {
    stub_docker 'echo "got:$2"'
    run docker ps --format json
    [ "$output" = "got:--format" ]
}

# --- Sequence rules: what they must catch -----------------------------------

@test "stubs: forbid trips on docker compose up with argv in between" {
    # This is the ordered-subsequence case, and the real reason the match walks
    # the argv array instead of comparing adjacent pairs: the `compose` and the
    # `up` of a real invocation are always separated by `-f <file>`. A rule that
    # required them to be adjacent would match the toy form and miss every
    # single call site in this repo.
    stub_docker 'echo "RAN FOR REAL"'
    run docker compose -f docker-compose.arr-stack.yml up -d --force-recreate
    assert_forbidden "verb: compose up"
    [ "$status" -eq 99 ]
    [[ "$output" != *"RAN FOR REAL"* ]]
}

@test "stubs: a one-word verb rule catches every spelling of the command" {
    # `docker container restart x` must trip the same rule as `docker restart x`.
    # Scanning for the word anywhere in the argv is what buys this - a rule
    # anchored to a fixed position would cover only the short spelling, and
    # `docker container restart` is a perfectly ordinary way to write it.
    #
    # Note this does NOT exercise ordered-subsequence matching: `restart` is a
    # single word, so it matches wherever it appears no matter how the walk is
    # written. The mutation corpus proved that the hard way - an adjacency
    # mutation left this test green. The subsequence property belongs to the
    # multi-word rules and is covered by the `compose up` test above.
    stub_docker 'echo "RAN FOR REAL"'
    run docker container restart sonarr
    assert_forbidden "verb: restart"
    [ "$status" -eq 99 ]
}

@test "stubs: forbid is insensitive to whitespace in the command line" {
    # Matching on the argv ARRAY rather than the joined string is what makes
    # doubled spacing a non-event. A joined-string denylist would miss this.
    stub_docker 'echo "RAN FOR REAL"'
    run docker  compose   -f  x.yml   up  -d
    assert_forbidden "verb: compose up"
}

@test "stubs: forbid trips on a mutating HTTP method" {
    stub_curl 'echo "RAN FOR REAL"'
    run curl -s -X PUT http://localhost:8989/api/v3/indexer/2
    assert_forbidden "verb: -X PUT"
    [ "$status" -eq 99 ]
}

@test "stubs: forbid trips on a destructive query string inside one argv word" {
    # A query string is never split across words, so this rule is a substring
    # match - the wrong shape for a verb, the right shape for a URL fragment.
    stub_curl 'echo "RAN FOR REAL"'
    run curl "http://localhost:7878/api/v3/movie/12?deleteFiles=true"
    assert_forbidden "substring: deleteFiles=true"
}

@test "stubs: forbid trips when an absolute tool path is handed to a delegating stub" {
    # A PATH stub cannot intercept /usr/bin/docker. When ssh carries one as an
    # argument, the command runs for real on the FAR side - where there is no
    # stub at all. Nothing in this repo does this today; this keeps it that way.
    #
    # The argv here is deliberately HARMLESS (`docker ps`). That is the whole
    # point: a destructive one would trip a verb rule first and prove nothing
    # about this rule. What makes it dangerous is the absolute path, not the
    # verb - the call escapes the harness whatever it goes on to do.
    stub_ssh 'echo "RAN FOR REAL"'
    run ssh nas /usr/bin/docker ps
    assert_forbidden "absolute path"
    [ "$status" -eq 99 ]
    [[ "$output" != *"RAN FOR REAL"* ]]
}

@test "stubs: forbid looks inside a quoted remote command" {
    # This is how the two most dangerous callers in the repo actually invoke
    # ssh: scripts/sync-nas.sh and scripts/arr-backup.sh both pass the whole
    # remote command as ONE argument. Word matching over the ssh argv sees
    # `docker compose -f ... up -d` as a single opaque blob, so without this the
    # denylist would be blind to precisely the calls it exists to stop.
    stub_ssh 'echo "RAN FOR REAL"'
    run ssh arr-stack-nas "docker compose -f docker-compose.arr-stack.yml up -d"
    assert_forbidden "inside a quoted remote command"
    [ "$status" -eq 99 ]
    [[ "$output" != *"RAN FOR REAL"* ]]
}

@test "stubs: a rule cannot match half outside and half inside a quoted command" {
    # Each compound word is matched on its own, never flattened into the outer
    # argv. Flattening would let `compose` from one argument pair up with an
    # `up` from another and fire on a command that does neither.
    stub_ssh 'echo fine'
    run ssh compose-host "systemctl is-active docker up-to-date.service"
    assert_nothing_forbidden
    [ "$status" -eq 0 ]
}

@test "stubs: a harmless quoted remote command is not forbidden" {
    stub_ssh 'echo "gluetun Up 3 hours"'
    run ssh arr-stack-nas "docker ps --format '{{.Names}} {{.Status}}'"
    assert_nothing_forbidden
    [ "$status" -eq 0 ]
}

# --- Sequence rules: what they must NOT catch -------------------------------

@test "stubs: a word merely CONTAINING a forbidden verb does not trip" {
    # ./scripts/restart-stack.sh contains the string "restart". A substring
    # denylist would refuse to let any test even NAME the script it is testing.
    stub_ssh 'echo fine'
    run ssh nas /volume1/docker/arr-stack/scripts/restart-stack.sh --help
    assert_nothing_forbidden
    [ "$status" -eq 0 ]
}

@test "stubs: a read-only docker call is not forbidden" {
    stub_docker 'echo "gluetun Up 3 hours"'
    run docker ps --format '{{.Names}} {{.Status}}'
    assert_nothing_forbidden
    [ "$status" -eq 0 ]
    [ "$output" = "gluetun Up 3 hours" ]
}

@test "stubs: a plain GET is not forbidden" {
    stub_curl 'echo "{}"'
    run curl -s http://localhost:8989/api/v3/health
    assert_nothing_forbidden
    [ "$status" -eq 0 ]
}

@test "stubs: an out-of-order verb sequence does not trip" {
    # The rule is `compose up`, in that order. `up ... compose` is not it, and a
    # rule that matched regardless of order would fire on unrelated argv.
    stub_docker 'echo fine'
    run docker up-check --label compose
    assert_nothing_forbidden
}

# --- The assertions themselves ----------------------------------------------

@test "stubs: assert_nothing_forbidden FAILS when something was forbidden" {
    # The negative-space check. assert_nothing_forbidden is the assertion every
    # Phase 3 test leans on, so it has to be shown capable of failing.
    stub_docker 'echo x'
    run docker restart sonarr
    run assert_nothing_forbidden
    [ "$status" -ne 0 ]
}

@test "stubs: assert_forbidden FAILS when nothing was forbidden" {
    stub_docker 'echo x'
    run docker ps
    run assert_forbidden
    [ "$status" -ne 0 ]
}

@test "stubs: assert_stub_called FAILS when the tool was never called" {
    stub_docker 'echo x'
    run assert_stub_called docker "ps"
    [ "$status" -ne 0 ]
}
