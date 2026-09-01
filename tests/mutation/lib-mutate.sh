#!/bin/bash
#
# Shared core for the two mutation runners:
#
#   run-mutations.sh   corpus     - regression, blocking, known defects
#   run-generated.sh   generated  - discovery, non-blocking, unknown gaps
#
# Everything in here is the dangerous half: it overwrites tracked files in
# place and must put them back. That is why it lives in one file. A second
# copy of restore logic is precisely the hazard this directory exists to
# prevent -- the two runners would drift, and the one that drifted would leave
# a mutated file in the tree looking exactly like an ordinary edit.
#
# Sourced, not executed. The sourcing script owns its own counters and its own
# summary; this file owns ROOT, WORK, the restore discipline, and the oracle.

# Sourcing this twice in one process would install a second EXIT trap over the
# first and point WORK at a new directory, orphaning the first one's pristine
# copies -- the backups a FATAL message would tell the reader to restore from.
# `trap` replaces, it does not accumulate. Second source is a no-op.
if [[ -n "${LIB_MUTATE_SOURCED:-}" ]]; then
    return 0 2>/dev/null || true
fi
LIB_MUTATE_SOURCED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
# Without this the failure is silent and misdirected: WORK is empty, every
# backup path becomes "/<tag>.orig" at the filesystem root, and the caller
# reports "could not copy the target aside" for what is actually a full /tmp.
if [[ -z "$WORK" || ! -d "$WORK" ]]; then
    echo "FATAL: mktemp -d failed - no scratch directory to hold backups in." >&2
    echo "FATAL: refusing to mutate anything without somewhere to restore from." >&2
    exit 3
fi
CURRENT_FILE=""; CURRENT_BACKUP=""
RESTORE_FAILED=0

# Restoring is the one thing that must happen no matter how this exits. A
# mutated file left in the tree is worse than no mutation testing at all: it
# looks like an ordinary edit and there is nothing to distinguish it from one.
restore_current() {
    # Nothing to restore is a legitimate no-op. A backup that has gone missing
    # is NOT -- it means the mutated file is in the tree with nothing left to
    # put back, and the old single-condition guard returned 0 for both, silently.
    [[ -n "$CURRENT_FILE" ]] || return 0
    if [[ ! -f "$CURRENT_BACKUP" ]]; then
        RESTORE_FAILED=1
        echo "FATAL: the backup of $CURRENT_FILE has vanished from under us." >&2
        echo "FATAL:   expected it at $CURRENT_BACKUP" >&2
        echo "FATAL: THE TREE IS MUTATED and there is nothing left to restore" >&2
        echo "FATAL: it from. Recover $CURRENT_FILE from git." >&2
        return 1
    fi
    # `cmp` alone, deliberately. Checking cp's exit status as well reads like
    # belt and braces, but a mutation proved it unfalsifiable: every case where
    # a failed cp matters is a case where the bytes differ, so cmp fires first
    # and the cp branch can never be the thing that catches anything. This
    # repo's own rule -- verify the outcome, not the exit status of the command
    # that was supposed to produce it -- picks the survivor.
    cp "$CURRENT_BACKUP" "$CURRENT_FILE" 2>/dev/null || true
    if ! cmp -s "$CURRENT_BACKUP" "$CURRENT_FILE"; then
        RESTORE_FAILED=1
        echo "FATAL: could not restore $CURRENT_FILE" >&2
        echo "FATAL: THE TREE IS MUTATED RIGHT NOW. The pristine copy is at" >&2
        echo "FATAL:   $CURRENT_BACKUP" >&2
        echo "FATAL: put it back by hand before doing anything else." >&2
        return 1
    fi
    RESTORE_FAILED=0
    CURRENT_FILE=""; CURRENT_BACKUP=""
}

# A failed restore must be fatal in BOTH directions, and the first version of
# this was neither. It printed FATAL and carried on: the run could still finish
# with 24 KILLED and exit 0 while a mutated file sat in the tree, indexed by
# nothing, looking exactly like an ordinary edit. And `rm -rf "$WORK"` ran
# immediately after -- deleting the pristine copy the message had just told the
# reader to restore from. A tool built to catch silent failure, failing silently.
cleanup() {
    restore_current || true
    if [[ "$RESTORE_FAILED" -eq 1 ]]; then
        echo "FATAL: keeping the backups in $WORK - do NOT delete it." >&2
        exit 3
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'echo; echo "interrupted - restoring" >&2; exit 130' INT TERM

# Run bats and report both the exit status and how many tests actually ran.
# The count is what makes a filter typo detectable instead of silently green.
# Echoes: "<status> <count>"
run_tests() {
    local batsfile="$1" regex="$2" out
    out="$("$ROOT/tests/run-tests.sh" -f "$regex" "$batsfile" 2>&1)"
    local st=$?
    local plan count
    plan="$(grep -m1 -E '^1\.\.[0-9]+$' <<<"$out" || true)"
    count="${plan#1..}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    printf '%s\n' "$out" > "$WORK/last-output.txt"
    echo "$st $count"
}

# Take the pristine copy and arm the restore path. Callers must pair this with
# `restore_current || exit 3` on every exit path -- the EXIT trap is the
# backstop for a crash, not a substitute for restoring between mutants.
#
# The result comes back in the BACKUP_PATH global rather than on stdout, and
# the guard below enforces that it is never called any other way. The first
# version returned the path by echoing it, so every caller wrote
# `backup="$(take_backup ...)"` -- a command substitution, which is a SUBSHELL.
# The assignments to CURRENT_FILE/CURRENT_BACKUP landed in that subshell and
# died with it, restore_current saw an empty CURRENT_FILE, took its legitimate
# "nothing to restore" path, and the run finished having left five mutated
# files in the working tree. The corpus caught it; nothing about reading the
# code did. A function whose entire purpose is a side effect on globals must
# refuse to run where those globals go nowhere.
BACKUP_PATH=""
take_backup() {
    local file="$1" tag="$2"
    if [[ "$BASHPID" != "$$" ]]; then
        echo "FATAL: take_backup called in a subshell (probably \`\$(take_backup ...)\`)." >&2
        echo "FATAL: it arms the restore path by setting globals, which a subshell" >&2
        echo "FATAL: discards -- the tree would be left mutated. Call it plainly" >&2
        echo "FATAL: and read the BACKUP_PATH variable." >&2
        return 2
    fi
    # printf, not echo: `echo` appends a newline and `tr -c` then turns it into
    # a trailing '_', so every backup was silently named "<id>_.orig".
    BACKUP_PATH="$WORK/$(printf '%s' "$tag" | tr -c 'A-Za-z0-9._-' '_').orig"
    cp "$file" "$BACKUP_PATH" || return 1
    CURRENT_FILE="$file"; CURRENT_BACKUP="$BACKUP_PATH"
}
