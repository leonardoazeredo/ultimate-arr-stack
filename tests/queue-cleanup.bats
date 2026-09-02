#!/usr/bin/env bats
# scripts/queue-cleanup.sh -- the bash half.
#
# The Python half is covered by tests/python/test_queue_cleanup.py; what is
# left here is everything that decides whether that half runs at all, plus the
# log trim. This script runs from cron with --apply against a live Sonarr and
# Radarr, so every test drives the real file with the PATH stubs from
# tests/helpers/stubs.bash in front of it.
#
# It is run out of a throwaway copy rather than in place, because LOG_FILE is
# derived from the script's own location -- testing it where it lives would
# rewrite the repo's real logs/queue-cleanup.log.

# `run --separate-stderr` is a 1.5.0 feature; without this the runner warns on
# every use of it.
bats_require_minimum_version 1.5.0

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init

    STACK="$BATS_TEST_TMPDIR/stack"
    mkdir -p "$STACK/scripts/lib" "$STACK/logs"
    cp "$REPO_ROOT/scripts/queue-cleanup.sh" "$STACK/scripts/"
    cp "$REPO_ROOT/scripts/lib/queue_cleanup.py" "$STACK/scripts/lib/"
    SCRIPT="$STACK/scripts/queue-cleanup.sh"
    LOG="$STACK/logs/queue-cleanup.log"

    # Both containers up, each handing back a config.xml with an API key.
    stub_docker '
case "$1" in
  ps)   printf "sonarr\nradarr\n" ;;
  exec) echo "<Config><ApiKey>KEY-$2</ApiKey></Config>" ;;
  *)    exit 1 ;;
esac
'
    # No queue anywhere: curl -f fails, which the Python half reports as a
    # failed fetch. Tests that care about queue contents live in the pytest
    # file; these care about the bash around it.
    stub_curl 'exit 22'
}

# --- argument parsing -----------------------------------------------------

@test "queue-cleanup: --help prints the header block and exits 0" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Remove stuck/stalled items"* ]]
    [[ "$output" == *"--apply"* ]]
}

@test "queue-cleanup: --help does not reach the containers" {
    run "$SCRIPT" --help
    assert_stub_not_called docker ""
}

@test "queue-cleanup: the default mode is a dry run" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mode: DRY RUN"* ]]
}

@test "queue-cleanup: --apply announces that it is applying" {
    run "$SCRIPT" --apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mode: APPLYING"* ]]
}

@test "queue-cleanup: an unrecognised argument is ignored, not fatal" {
    # cron lines accumulate flags; an unknown one must not take the job down.
    run "$SCRIPT" --nonsense
    [ "$status" -eq 0 ]
    [[ "$output" == *"Mode: DRY RUN"* ]]
}

# --- the argv boundary into Python ----------------------------------------

@test "queue-cleanup: passes apply, verbose and both keys in that order" {
    # Pinned because a type mismatch across exactly this boundary is what made
    # fix-sonarr-folders.sh's --apply inert for its whole life: bash writes
    # `true`/`false` and the Python compared against "True".
    stub_tool python3 'echo "ARGV: $*"'
    run "$SCRIPT" --apply -v
    [[ "$output" == *"ARGV: "*"queue_cleanup.py true true KEY-sonarr KEY-radarr"* ]]
}

@test "queue-cleanup: a dry run passes false, not an empty string" {
    stub_tool python3 'echo "ARGV: $*"'
    run "$SCRIPT"
    [[ "$output" == *"queue_cleanup.py false false KEY-sonarr KEY-radarr"* ]]
}

@test "queue-cleanup: --verbose is accepted as well as -v" {
    stub_tool python3 'echo "ARGV: $*"'
    run "$SCRIPT" --verbose
    [[ "$output" == *"queue_cleanup.py false true "* ]]
}

@test "queue-cleanup: a failing Python half is fatal and says so" {
    # The heredoc form inherited set -e; the extracted form is a subprocess,
    # and a subprocess that dies must not read as success.
    stub_tool python3 'exit 3'
    run "$SCRIPT" --apply
    [ "$status" -eq 1 ]
    [[ "$output" == *"the queue cleanup exited non-zero"* ]]
}

@test "queue-cleanup: the fatal error goes to stderr, not stdout" {
    # This runs from cron with its stdout redirected into a log. An error on
    # stdout lands in that log and nowhere else; on stderr it also reaches
    # cron's mail, which is the only thing that tells anyone the weekly job
    # stopped working.
    stub_tool python3 'exit 3'
    run --separate-stderr "$SCRIPT" --apply
    [[ "$stderr" == *"the queue cleanup exited non-zero"* ]]
    [[ "$output" != *"the queue cleanup exited non-zero"* ]]
}

@test "queue-cleanup: a failing Python half suppresses the webhook" {
    stub_tool python3 'exit 3'
    HA_WEBHOOK_URL="http://ha.example/hook" run "$SCRIPT" --apply
    assert_stub_not_called curl "ha.example"
}

# --- API key discovery ----------------------------------------------------

@test "queue-cleanup: exits 1 when neither container is running" {
    stub_docker 'case "$1" in ps) : ;; *) exit 1 ;; esac'
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not get API keys"* ]]
}

@test "queue-cleanup: one container running is enough to proceed" {
    stub_docker '
case "$1" in
  ps)   printf "sonarr\n" ;;
  exec) [ "$2" = sonarr ] || exit 1; echo "<ApiKey>KEY-sonarr</ApiKey>" ;;
  *)    exit 1 ;;
esac
'
    stub_tool python3 'echo "ARGV: $*"'
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"queue_cleanup.py false false KEY-sonarr "* ]]
}

@test "queue-cleanup: a container with no ApiKey in its config is not a key" {
    stub_docker '
case "$1" in
  ps)   printf "sonarr\nradarr\n" ;;
  exec) echo "<Config></Config>" ;;
  *)    exit 1 ;;
esac
'
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not get API keys"* ]]
}

# --- the webhook ----------------------------------------------------------

@test "queue-cleanup: no webhook is sent without --apply" {
    HA_WEBHOOK_URL="http://ha.example/hook" run "$SCRIPT"
    assert_stub_not_called curl "ha.example"
}

@test "queue-cleanup: no webhook is sent when the URL is unset" {
    run "$SCRIPT" --apply
    assert_stub_not_called curl "ha.example"
}

@test "queue-cleanup: --apply with a URL attempts the webhook" {
    HA_WEBHOOK_URL="http://ha.example/hook" run "$SCRIPT" --apply
    [ "$status" -eq 0 ]
    assert_stub_called curl "ha.example"
    # The stub harness stops it there: an outbound POST is on the denylist, so
    # the notification is attempted and never actually sent. The script's own
    # `|| true` is what keeps that from failing the run.
    assert_forbidden "POST"
}

@test "queue-cleanup: the webhook carries the cleanup payload" {
    # Asserting only that curl was called with the URL would pass on a request
    # with no body at all -- and on `-e`, which sets a Referer header instead
    # of a POST body and would have Home Assistant fire a notification with
    # nothing in it.
    HA_WEBHOOK_URL="http://ha.example/hook" run "$SCRIPT" --apply
    assert_stub_called curl '\-d .*Queue Cleanup'
    assert_stub_called curl "Content-Type: application/json"
}

# --- log trim: defect #8 --------------------------------------------------

@test "queue-cleanup: --apply trims a log past the limit" {
    seq 1 1200 > "$LOG"
    run "$SCRIPT" --apply
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$LOG")" -eq 1000 ]
    # The tail, not the head: the newest 1000 lines are the ones worth keeping.
    [ "$(head -1 "$LOG")" = "201" ]
}

@test "queue-cleanup: a dry run does not trim the log" {
    # The one thing a dry run used to change on disk, and what it changed was
    # the record of previous runs -- the thing the operator is reading when
    # they dry-run to decide whether to apply.
    seq 1 1200 > "$LOG"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$LOG")" -eq 1200 ]
}

@test "queue-cleanup: a log under the limit is left alone" {
    seq 1 10 > "$LOG"
    run "$SCRIPT" --apply
    [ "$(wc -l < "$LOG")" -eq 10 ]
    [ "$(head -1 "$LOG")" = "1" ]
}

@test "queue-cleanup: an absent log is not an error" {
    rm -f "$LOG"
    run "$SCRIPT" --apply
    [ "$status" -eq 0 ]
    [ ! -e "$LOG" ]
}

@test "queue-cleanup: a successful trim leaves no temp file behind" {
    seq 1 1200 > "$LOG"
    run "$SCRIPT" --apply
    run bash -c "ls '$STACK/logs/' | grep -v '^queue-cleanup.log$' || true"
    [ "$output" = "" ]
}

@test "queue-cleanup: a failing trim leaves neither a temp file nor a truncated log" {
    # mktemp had no trap, so every failed trim leaked a file -- and the temp
    # lived in /tmp, a different filesystem from the log on the NAS, which
    # makes the `mv` a copy rather than the atomic rename it reads as.
    seq 1 1200 > "$LOG"
    stub_tool tail 'exit 1'
    run "$SCRIPT" --apply
    [ "$(wc -l < "$LOG")" -eq 1200 ]
    run bash -c "ls '$STACK/logs/' | grep -v '^queue-cleanup.log$' || true"
    [ "$output" = "" ]
}

@test "queue-cleanup: the temp file is created beside the log, not in /tmp" {
    # A bare `mktemp` puts the file in /tmp, which on the NAS is a different
    # filesystem from the log -- so the `mv` below it is a copy-then-unlink
    # that can leave the log half-written, not the atomic rename it reads as.
    seq 1 1200 > "$LOG"
    stub_tool mktemp 'exec /usr/bin/mktemp "$@"'
    run "$SCRIPT" --apply
    [ "$status" -eq 0 ]
    assert_stub_called mktemp "$(basename "$LOG").XXXXXX"
    [ "$(wc -l < "$LOG")" -eq 1000 ]
}

# --- the harness's own claim ----------------------------------------------

@test "queue-cleanup: a failing mktemp aborts rather than trimming to nowhere" {
    # errexit must stop the script at the failed assignment, before the trim is
    # attempted at all. Exit status alone cannot show that: without errexit the
    # script carries on with TMPLOG empty, `> ""` fails, and the enclosing `if`
    # compound returns 1 too -- so both variants exit non-zero. What separates
    # them is stderr. The errexit path says nothing; the other emits bash's own
    # `: No such file or directory` from a redirect into the empty string, and
    # an operator reading cron's mail sees a confusing redirect error instead
    # of a clean abort. Assert on the stream, not just the status.
    #
    # The stub fails only for the script's own template: `run --separate-stderr`
    # calls mktemp itself to make the stderr file, so a blanket `exit 1` breaks
    # the harness rather than the script under test.
    seq 1 1200 > "$LOG"
    stub_tool mktemp "case \"\$1\" in \"$LOG\".*) exit 1;; esac; exec /usr/bin/mktemp \"\$@\""
    run --separate-stderr "$SCRIPT" --apply
    [ "$status" -ne 0 ]
    [[ "$stderr" != *"No such file or directory"* ]]
    [ "$(wc -l < "$LOG")" -eq 1200 ]
}

@test "queue-cleanup: a dry run reaches no destructive operation at all" {
    seq 1 1200 > "$LOG"
    HA_WEBHOOK_URL="http://ha.example/hook" run "$SCRIPT" -v
    assert_nothing_forbidden
}
