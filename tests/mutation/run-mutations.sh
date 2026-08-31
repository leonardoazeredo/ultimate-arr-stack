#!/bin/bash
set -uo pipefail
#
# Mutation testing for the bats suite.
#
# Why this exists: four separate times in this project a test was merged as
# coverage while being incapable of failing. Reading them did not catch it --
# in every case they read correctly. Breaking the thing they guard and watching
# them stay green is what caught it. This script does that mechanically instead
# of by hand.
#
# For each mutation in a corpus:
#   1. CONTROL   - run the named test(s) unmutated. They must PASS, and at
#                  least one must actually have run. A `-f` filter that matches
#                  nothing exits 0 with `1..0`, which reads exactly like a pass.
#   2. APPLY     - break the target file.
#   3. ASSERT    - the file's checksum MUST have changed. A mutation that did
#                  not apply (a regex that stopped matching after a refactor)
#                  produces a green run and a false KILLED. This project has
#                  already shipped one harness that reported five passes for
#                  exactly this reason, because its guard inverted its own exit
#                  status. Nothing here is believed before this check.
#   4. RUN       - the named test(s) must now FAIL. If they pass, the test
#                  cannot detect the defect it exists to detect: SURVIVED.
#   5. RESTORE   - from a byte copy, verified by checksum. Enforced by an EXIT
#                  trap, so a Ctrl-C never leaves a mutated tree behind.
#
# Usage:
#   ./tests/mutation/run-mutations.sh [-k <substring>] [corpus.sh ...]
#
# With no corpus argument, every tests/mutation/corpus/*.sh is run.
# -k restricts to mutation ids containing <substring>.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILTER=""
while getopts "k:" opt; do
    case "$opt" in
        k) FILTER="$OPTARG" ;;
        *) echo "usage: $0 [-k <substring>] [corpus.sh ...]" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

TOTAL=0; KILLED=0; SURVIVED=0; ERRORED=0; SKIPPED=0
WORK="$(mktemp -d)"
CURRENT_FILE=""; CURRENT_BACKUP=""
RESTORE_FAILED=0

# Restoring is the one thing that must happen no matter how this exits. A
# mutated file left in the tree is worse than no mutation testing at all: it
# looks like an ordinary edit and there is nothing to distinguish it from one.
restore_current() {
    [[ -n "$CURRENT_FILE" && -f "$CURRENT_BACKUP" ]] || return 0
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

# mutation <id> --file F --bats B --test REGEX --why TEXT --apply 'SHELL'
#
# The corpus is a shell script that calls this. No bespoke file format to parse
# and get subtly wrong -- the corpus is executable, and `$F` inside --apply is
# the absolute path to the target.
mutation() {
    local id="$1"; shift
    local file="" batsfile="" testre="" why="" apply=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)  file="$2";     shift 2 ;;
            --bats)  batsfile="$2"; shift 2 ;;
            --test)  testre="$2";   shift 2 ;;
            --why)   why="$2";      shift 2 ;;
            --apply) apply="$2";    shift 2 ;;
            *) echo "mutation $id: unknown argument '$1'" >&2; return 2 ;;
        esac
    done

    if [[ -n "$FILTER" && "$id" != *"$FILTER"* ]]; then
        SKIPPED=$((SKIPPED + 1)); return 0
    fi
    TOTAL=$((TOTAL + 1))

    for req in file batsfile testre apply; do
        if [[ -z "${!req}" ]]; then
            echo "ERROR  $id"; echo "       missing --${req/batsfile/bats}"
            ERRORED=$((ERRORED + 1)); return 0
        fi
    done

    [[ "$file"     = /* ]] || file="$ROOT/$file"
    [[ "$batsfile" = /* ]] || batsfile="$ROOT/$batsfile"
    if [[ ! -f "$file" ]]; then
        echo "ERROR  $id"; echo "       target does not exist: $file"
        echo "       (renamed? the corpus entry needs updating, not deleting)"
        ERRORED=$((ERRORED + 1)); return 0
    fi

    # Split declaration from assignment (SC2155): `local x=$(cmd)` takes the
    # exit status of `local`, not of the command.
    local backup
    backup="$WORK/$(echo "$id" | tr -c 'A-Za-z0-9._-' '_').orig"
    cp "$file" "$backup"
    CURRENT_FILE="$file"; CURRENT_BACKUP="$backup"

    # 1. Control.
    local res st count
    res=$(run_tests "$batsfile" "$testre"); st=${res% *}; count=${res#* }
    if [[ "$count" -eq 0 ]]; then
        echo "ERROR  $id"
        echo "       --test '$testre' matched NO tests in $(basename "$batsfile")."
        echo "       bats exits 0 having run nothing, which is indistinguishable"
        echo "       from a pass. Fix the regex."
        ERRORED=$((ERRORED + 1)); restore_current; return 0
    fi
    if [[ "$st" -ne 0 ]]; then
        echo "ERROR  $id"
        echo "       the test is already failing unmutated - a later failure"
        echo "       would prove nothing. Fix the test first."
        sed 's/^/       | /' "$WORK/last-output.txt" | head -20
        ERRORED=$((ERRORED + 1)); restore_current; return 0
    fi

    # 2. Apply, 3. assert it actually landed.
    ( cd "$ROOT" && F="$file" bash -c "$apply" ) >/dev/null 2>&1
    if cmp -s "$backup" "$file"; then
        echo "ERROR  $id"
        echo "       the mutation changed NOTHING. Its result would have been a"
        echo "       false KILLED (or a false SURVIVED) either way. Most likely"
        echo "       the pattern no longer matches $(basename "$file")."
        ERRORED=$((ERRORED + 1)); restore_current; return 0
    fi

    # 4. The test must now fail.
    res=$(run_tests "$batsfile" "$testre"); st=${res% *}; count=${res#* }

    # 5. Restore, verified. If it did not work, stop the entire run here --
    # mutating the next target on top of a tree we could not put back turns one
    # recoverable problem into an unrecoverable one.
    restore_current || exit 3

    if [[ "$st" -ne 0 ]]; then
        echo "KILLED $id  ($count test(s))"
        KILLED=$((KILLED + 1))
    else
        echo "SURVIVED $id"
        echo "         $why"
        echo "         The defect was introduced and '$testre' still passed."
        echo "         That test is not covering what it claims to cover."
        SURVIVED=$((SURVIVED + 1))
    fi
}

CORPUS=("$@")
if [[ ${#CORPUS[@]} -eq 0 ]]; then
    shopt -s nullglob
    CORPUS=("$ROOT"/tests/mutation/corpus/*.sh)
    shopt -u nullglob
fi
if [[ ${#CORPUS[@]} -eq 0 ]]; then
    echo "no corpus files found under tests/mutation/corpus/" >&2
    exit 2
fi

for c in "${CORPUS[@]}"; do
    [[ -f "$c" ]] || { echo "no such corpus: $c" >&2; ERRORED=$((ERRORED + 1)); continue; }
    echo "== $(basename "$c")"
    # shellcheck disable=SC1090
    source "$c"
done

echo
echo "killed $KILLED / $TOTAL   survived $SURVIVED   errored $ERRORED   skipped $SKIPPED"
if [[ "$SURVIVED" -gt 0 || "$ERRORED" -gt 0 ]]; then exit 1; fi
[[ "$TOTAL" -eq 0 ]] && { echo "no mutations ran" >&2; exit 2; }
exit 0
