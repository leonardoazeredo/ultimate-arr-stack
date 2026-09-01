#!/bin/bash
# PATH-executable stubs for tests that drive real operational scripts.
#
# WHY THIS EXISTS, AND WHY IT IS AN EXECUTABLE AND NOT A SHELL FUNCTION
#
# This repo already has four working stub idioms and three of them stay exactly
# where they are:
#
#   1. awk-extract a function body and eval it  (backup-volume-resolution.bats)
#   2. a function + `export -f` inside `run bash -c`  (vpn-zombies.bats)
#   3. a local function override in the current shell  (pre-commit-checks.bats)
#   4. THIS ONE: a real executable on $PATH
#
# They are not unifiable and there is nothing to gain by pretending otherwise -
# (1) needs per-function boundary syntax, (2) needs subshell export, (3) needs
# closure over test-local variables. Only (4) is centralised here, because only
# (4) is load bearing for SAFETY: it is the single thing standing between a test
# and a live `docker restart` on a NAS that is serving the house's DNS.
#
# A shell function is not sufficient for that job:
#
#   * `timeout` EXECs its argument, so it can never see a shell function.
#   * scripts/configure-apps.sh runs commands in grandchild processes.
#
# Only a real file on $PATH is reached in both cases.
#
# WHAT A TEST GETS
#
#   stub_docker / stub_curl / stub_ssh / stub_git  - install a stub whose body
#   is the shell text you pass in. `$@` is the argv the script under test used.
#
#   $STUB_LOG   - one line per stub call: "<tool><TAB><argv>". Assert on what
#                 was ASKED FOR, not merely that something returned 0. The
#                 pattern comes from backup-volume-resolution.bats:161.
#
#   $STUB_FORBIDDEN - written only when forbid() fires; holds the rule that
#                 tripped and the full argv. Absence of this file is the
#                 assertion that a test did not reach a destructive path.
#
# `stub_dig` is deliberately NOT here: it has exactly one caller
# (tests/lib-domains.bats) and lives inline there. A shared helper for one call
# site is indirection, not abstraction. It moves here when a second one appears.

# --- The denylist -----------------------------------------------------------
#
# Matching is over the ARGV ARRAY, never the joined string. That single choice
# kills both halves of the substring problem at once:
#
#   * `docker compose  up` with doubled whitespace still matches, because words
#     are compared, not spacing.
#   * `./scripts/restart-stack.sh` does NOT match the `restart` rule, because a
#     word merely CONTAINING restart is not the word `restart`.
#
# Sequence rules match as an ORDERED SUBSEQUENCE of words, so both
# `docker restart x` and `docker container restart x` trip the same rule, and
# `... tailscale set ...` trips regardless of what sits in between.
#
# Case-sensitive on purpose: every real call site in this repo is lowercase, so
# case-insensitivity would buy nothing and add false positives.
STUB_DENY_SEQ=(
    "compose up"
    "compose down"
    "compose rm"
    "restart"
    "stop"
    "kill"
    "rm"
    "network rm"
    "volume rm"
    "system prune"
    "tailscale set"
    "-X PUT"
    "-X POST"
    "-X DELETE"
    "-X PATCH"
)

# Substring rules, checked against each argv word on its own. A query string is
# never split across words, so this is the right shape for a URL fragment - and
# the wrong shape for a verb, which is why the two lists are separate.
STUB_DENY_SUBSTR=(
    "moveFiles=true"
    "deleteFiles=true"
)

# A PATH stub cannot intercept /usr/bin/curl. Nothing in this repo invokes a
# stubbable tool by absolute path today (measured), so this is a regression
# guard - and it is a real one for the DELEGATING tools: `ssh host /usr/bin/docker
# restart x` and `timeout 5 /usr/bin/curl ...` both hand an absolute path to a
# stub as an argument, and both would otherwise run for real on the far side.
STUB_DENY_ABSPATH_RE='^/(usr/)?(local/)?s?bin/'

# forbid() exits with this. No tool in the denylist returns 99 in normal
# operation, so a test can tell "the harness stopped a destructive call" apart
# from "the real command failed" - a distinction bare assert_failure destroys.
STUB_FORBID_RC=99

# --- Harness ----------------------------------------------------------------

# Create the stub bin dir, put it FIRST on PATH, and write the shared guard.
# Everything lands under $BATS_TEST_TMPDIR: per-test, removed by bats itself, so
# there is no teardown to forget and no log that grows across runs.
stub_init() {
    STUB_DIR="${BATS_TEST_TMPDIR:?stub_init needs BATS_TEST_TMPDIR}/stubbin"
    STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    STUB_FORBIDDEN="$BATS_TEST_TMPDIR/stub.forbidden"
    export STUB_DIR STUB_LOG STUB_FORBIDDEN
    mkdir -p "$STUB_DIR"
    : > "$STUB_LOG"
    rm -f "$STUB_FORBIDDEN"
    _stub_write_guard
    PATH="$STUB_DIR:$PATH"
    export PATH
}

# The guard is generated from the arrays above rather than hand-written into
# each stub, so a corpus mutation that neuters the denylist here neuters it
# everywhere - which is exactly what makes forbid() provable.
_stub_write_guard() {
    {
        echo '#!/bin/bash'
        echo '# generated by tests/helpers/stubs.bash - do not edit'
        printf 'STUB_DENY_SEQ=('
        printf ' %q' "${STUB_DENY_SEQ[@]}"
        printf ' )\n'
        printf 'STUB_DENY_SUBSTR=('
        printf ' %q' "${STUB_DENY_SUBSTR[@]}"
        printf ' )\n'
        printf 'STUB_DENY_ABSPATH_RE=%q\n' "$STUB_DENY_ABSPATH_RE"
        printf 'STUB_FORBID_RC=%q\n' "$STUB_FORBID_RC"
        cat <<'GUARD'

# Ordered-subsequence match of $rule's words against the argv array.
_seq_matches() {
    local rule="$1"; shift
    local -a want; read -r -a want <<<"$rule"
    local wi=0 word
    for word in "$@"; do
        [[ "$word" == "${want[$wi]}" ]] && wi=$((wi + 1))
        [[ $wi -eq ${#want[@]} ]] && return 0
    done
    return 1
}

forbid() {
    local tool="$1"; shift
    local rule word
    for rule in "${STUB_DENY_SEQ[@]}"; do
        _seq_matches "$rule" "$@" && _stub_trip "$tool" "verb: $rule" "$@"

        # A remote command arrives as ONE argv word: scripts/sync-nas.sh and
        # scripts/arr-backup.sh both do `ssh "$HOST" "docker ... up -d"`. Word
        # matching over the ssh argv sees `docker ... up -d` as a single opaque
        # blob and finds nothing in it, so the most destructive calls this repo
        # makes would sail straight past the denylist that exists to stop them.
        #
        # Re-run the same rules over the words of any argv element that contains
        # whitespace. Each compound word is matched on its own rather than
        # flattened into the outer list, so a rule can never match half in the
        # argv and half inside a quoted string.
        for word in "$@"; do
            [[ "$word" == *[[:space:]]* ]] || continue
            local -a inner; read -r -a inner <<<"$word"
            _seq_matches "$rule" ${inner+"${inner[@]}"} \
                && _stub_trip "$tool" "verb: $rule (inside a quoted remote command)" "$@"
        done
    done
    for rule in "${STUB_DENY_SUBSTR[@]}"; do
        for word in "$@"; do
            [[ "$word" == *"$rule"* ]] && _stub_trip "$tool" "substring: $rule" "$@"
        done
    done
    for word in "$@"; do
        [[ "$word" =~ $STUB_DENY_ABSPATH_RE ]] \
            && _stub_trip "$tool" "absolute path bypasses the stub: $word" "$@"
    done
    return 0
}

# Breadcrumb first, THEN exit. The exit status can be swallowed by a `|| true`
# or an `if` in the script under test; the file cannot.
_stub_trip() {
    local tool="$1" rule="$2"; shift 2
    { echo "FORBIDDEN $tool"
      echo "  rule: $rule"
      echo "  argv: $*"
    } >> "$STUB_FORBIDDEN"
    echo "stub: FORBIDDEN ($rule) - $tool $*" >&2
    exit "$STUB_FORBID_RC"
}
GUARD
    } > "$STUB_DIR/.guard.bash"
}

# stub_tool <name> <body>
#
# <body> is shell text run with "$@" set to the argv the script under test
# passed. It runs AFTER logging and AFTER the guard, so a body can never
# accidentally re-enable a destructive path.
stub_tool() {
    local name="$1" body="${2:-}"
    {
        echo '#!/bin/bash'
        printf 'printf "%%s\\t%%s\\n" %q "$*" >> %q\n' "$name" "$STUB_LOG"
        printf 'source %q\n' "$STUB_DIR/.guard.bash"
        printf 'forbid %q "$@"\n' "$name"
        echo "$body"
    } > "$STUB_DIR/$name"
    chmod +x "$STUB_DIR/$name"
}

stub_docker() { stub_tool docker "${1:-}"; }
stub_curl()   { stub_tool curl   "${1:-}"; }
stub_ssh()    { stub_tool ssh    "${1:-}"; }
stub_git()    { stub_tool git    "${1:-}"; }

# --- Assertions -------------------------------------------------------------

# The positive form: this exact argv was asked for.
assert_stub_called() {
    local tool="$1" pattern="$2"
    grep -q "^${tool}"$'\t'".*${pattern}" "$STUB_LOG" || {
        echo "expected $tool to be called matching: $pattern"
        echo "--- $STUB_LOG ---"; cat "$STUB_LOG"
        return 1
    }
}

assert_stub_not_called() {
    local tool="$1" pattern="$2"
    if grep -q "^${tool}"$'\t'".*${pattern}" "$STUB_LOG"; then
        echo "$tool was called matching '$pattern' and should not have been"
        echo "--- $STUB_LOG ---"; cat "$STUB_LOG"
        return 1
    fi
}

# The whole point of the harness: nothing destructive was reached.
assert_nothing_forbidden() {
    [[ ! -f "$STUB_FORBIDDEN" ]] || {
        echo "a test reached a destructive operation:"
        cat "$STUB_FORBIDDEN"
        return 1
    }
}

# For a test that INTENDS to reach one. Asserting the breadcrumb and the
# reserved status together is what stops this passing on an unrelated failure -
# a bare assert_failure would pass if the script died for any reason at all.
assert_forbidden() {
    local pattern="${1:-}"
    [[ -f "$STUB_FORBIDDEN" ]] || {
        echo "expected a forbidden operation to be tripped, none was"
        echo "--- $STUB_LOG ---"; cat "$STUB_LOG"
        return 1
    }
    if [[ -n "$pattern" ]]; then
        grep -q "$pattern" "$STUB_FORBIDDEN" || {
            echo "forbidden, but not matching '$pattern':"
            cat "$STUB_FORBIDDEN"
            return 1
        }
    fi
}
