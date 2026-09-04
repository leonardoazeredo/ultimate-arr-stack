#!/usr/bin/env bats
# scripts/lib/env-file.sh
#
# One `.env` reader, replacing two divergent wrong ones. The defect it fixes is
# invisible in normal use and total when it fires: `cut -d= -f2` returns the
# field between the FIRST and SECOND '=', so a value containing an '=' -- which
# base64 API keys and generated passwords routinely end in -- was silently
# truncated, and the caller went on to authenticate with a prefix of the real
# key. Nothing reported an error; the arr API simply answered 401.

setup() {
    load helpers/setup
    source "$REPO_ROOT/scripts/lib/env-file.sh"

    ENV="$BATS_TEST_TMPDIR/.env"
}

@test "env-file: reads a plain value" {
    printf 'RADARR_API_KEY=abc123\n' > "$ENV"
    run env_value "$ENV" RADARR_API_KEY
    [ "$status" -eq 0 ]
    [ "$output" = "abc123" ]
}

@test "env-file: keeps everything after the first equals sign" {
    # The whole reason this file exists. A base64 key ends in '=' padding.
    printf 'K=YWJjZGVmZ2hpamts=\n' > "$ENV"
    run env_value "$ENV" K
    [ "$output" = "YWJjZGVmZ2hpamts=" ]
}

@test "env-file: keeps an equals sign in the middle of a value" {
    printf 'K=a=b=c\n' > "$ENV"
    run env_value "$ENV" K
    [ "$output" = "a=b=c" ]
}

@test "env-file: strips one surrounding pair of double quotes" {
    printf 'K="abc123"\n' > "$ENV"
    run env_value "$ENV" K
    [ "$output" = "abc123" ]
}

@test "env-file: strips one surrounding pair of single quotes" {
    printf "K='abc123'\n" > "$ENV"
    run env_value "$ENV" K
    [ "$output" = "abc123" ]
}

@test "env-file: keeps quotes that are part of the value" {
    # `tr -d '\"'` removed every quote anywhere, silently corrupting any value
    # that legitimately contained one.
    printf 'K=say "hi" now\n' > "$ENV"
    run env_value "$ENV" K
    [ "$output" = 'say "hi" now' ]
}

@test "env-file: does not strip a lone unbalanced quote" {
    printf 'K="abc\n' > "$ENV"
    run env_value "$ENV" K
    [ "$output" = '"abc' ]
}

@test "env-file: strips a trailing carriage return from a CRLF file" {
    printf 'K=abc\r\n' > "$ENV"
    run env_value "$ENV" K
    [ "$output" = "abc" ]
    [ "${#output}" -eq 3 ]
}

@test "env-file: an empty value is read as empty and still succeeds" {
    printf 'K=\n' > "$ENV"
    run env_value "$ENV" K
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "env-file: the last assignment wins" {
    printf 'K=first\nK=second\n' > "$ENV"
    run env_value "$ENV" K
    [ "$output" = "second" ]
}

@test "env-file: a key is matched whole, not as a prefix" {
    # RADARR_API_KEY must not be answered by RADARR_API_KEY_OLD, and a longer
    # key must not be answered by a shorter one that happens to be a prefix.
    printf 'RADARR_API_KEY_OLD=stale\nRADARR_API_KEY=live\n' > "$ENV"
    run env_value "$ENV" RADARR_API_KEY
    [ "$output" = "live" ]
}

@test "env-file: a key is not matched as a suffix of another" {
    printf 'OLD_KEY=stale\n' > "$ENV"
    run env_value "$ENV" KEY
    [ "$status" -eq 1 ]
}

@test "env-file: a commented-out assignment is not a value" {
    printf '#K=commented\n' > "$ENV"
    run env_value "$ENV" K
    [ "$status" -eq 1 ]
}

@test "env-file: an indented assignment is not matched" {
    # The old `grep "^K="` anchored too, and compose does not honour leading
    # whitespace either. Pinned so the rewrite did not quietly widen it.
    printf '  K=indented\n' > "$ENV"
    run env_value "$ENV" K
    [ "$status" -eq 1 ]
}

@test "env-file: a missing key returns non-zero and prints nothing" {
    printf 'OTHER=1\n' > "$ENV"
    run env_value "$ENV" K
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
}

@test "env-file: a missing file returns non-zero rather than an error" {
    run env_value "$BATS_TEST_TMPDIR/nope" K
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
}

@test "env-file: a directory in place of the file reads as absent, quietly" {
    # `-e` instead of `-f` gets as far as redirecting from a directory, which
    # returns the same non-zero but prints a bash error to stderr from inside a
    # library function -- noise in a cron log, from a call that is supposed to
    # be a clean "not configured".
    run env_value "$BATS_TEST_TMPDIR" K
    [ "$status" -eq 1 ]
    [ "$output" = "" ]
}

@test "env-file: reads a final line with no trailing newline" {
    printf 'K=lastline' > "$ENV"
    run env_value "$ENV" K
    [ "$output" = "lastline" ]
}

@test "env-file: a value containing a hash is kept whole" {
    # `.env` has no inline-comment syntax, and compose does not strip one.
    printf 'K=pa#ss\n' > "$ENV"
    run env_value "$ENV" K
    [ "$output" = 'pa#ss' ]
}

@test "env-file: a value containing spaces is kept whole" {
    printf 'K=/volume1/my media\n' > "$ENV"
    run env_value "$ENV" K
    [ "$output" = "/volume1/my media" ]
}

@test "env-file: a value that looks like a glob is not expanded" {
    printf 'K=*\n' > "$ENV"
    run env_value "$ENV" K
    [ "$output" = "*" ]
}
