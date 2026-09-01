#!/bin/bash
set -uo pipefail
#
# Generative mutation testing: the discovery half.
#
# run-mutations.sh replays a corpus of defects someone already knew about. It
# cannot find a gap nobody has thought of -- every entry in it is a bug that was
# written down after the fact. This script is the other half: universalmutator
# perturbs the source systematically, and any mutant the suite fails to kill is
# a hole in the tests that no one had to think of first.
#
# That is not hypothetical here. `grep -Fxq` -> `grep -Fq` in the backup volume
# resolver survived all 18 tests around it; the exact-match property was
# completely uncovered, and because volume names nest, a substring match
# silently mis-resolves and a volume fails to back up. Review did not find it.
#
# NON-BLOCKING BY DESIGN. This always exits 0. Generated mutants include
# equivalent ones -- mutations that change the text without changing behaviour --
# which can never be killed by any test and are not defects. A discovery tool
# that can wedge the workflow on an irreducible false-positive rate gets
# disabled, and then it finds nothing at all. run-mutations.sh stays the only
# blocking gate.
#
# Usage:
#   ./tests/mutation/run-generated.sh [-k <substring>] [target ...]
#
# With no target argument, every file in the TARGETS map below is swept.
# -k restricts to targets whose path contains <substring>.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/mutation/lib-mutate.sh
source "$ROOT/tests/mutation/lib-mutate.sh"

LEDGER="$ROOT/tests/mutation/survivors.tsv"
MUTANT_DIR="$ROOT/tests/mutation/.mutants"

# target file : bats oracle : test-name regex
#
# One table, same shape as the corpus's --file/--bats/--test triple. A target
# with no oracle does not belong here: against an untested file EVERY mutant
# survives by construction, which is not a finding, it is a restatement of
# "this file has no tests" -- and a few hundred guaranteed survivors would bury
# the real signal. The nine untested scripts/lib/ files are recorded as a
# missing-test gap in tests/mutation/README.md instead of being swept.
TARGETS=(
  "scripts/lib/check-secrets.sh:tests/pre-commit-checks.bats:check_secrets"
  "scripts/lib/check-env-vars.sh:tests/pre-commit-checks.bats:check_env_vars"
  "scripts/lib/check-conflicts.sh:tests/pre-commit-checks.bats:check_conflicts"
  # scripts/lib/common.sh is deliberately NOT here. It was swept once, on the
  # theory that being sourced by three tested files made it covered: 78 mutants
  # generated, 78 survived, 0 killed. Sourced is not covered -- the four tests
  # exercise none of its NAS/SSH/domain helpers. It belongs on the missing-test
  # list in README.md with the other nine, and leaving it in the sweep would add
  # 78 guaranteed survivors that say nothing beyond "this file has no tests".
)

FILTER=""
while getopts "k:" opt; do
    case "$opt" in
        k) FILTER="$OPTARG" ;;
        *) echo "usage: $0 [-k <substring>] [target ...]" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

if [[ $# -gt 0 ]]; then
    SELECTED=("$@")
else
    SELECTED=()
    for t in "${TARGETS[@]}"; do SELECTED+=("${t%%:*}"); done
fi

# This overwrites tracked files in place. On a dirty tree a failed restore is
# indistinguishable from the user's own uncommitted work, and `git checkout --`
# -- the documented recovery -- would destroy that work. Refuse.
cd "$ROOT" || exit 2
DIRTY="$(git status --porcelain -- "${SELECTED[@]}" 2>/dev/null)"
if [[ -n "$DIRTY" ]]; then
    echo "run-generated: refusing to start - these targets have uncommitted changes:" >&2
    sed 's/^/  /' <<<"$DIRTY" >&2
    echo "run-generated: this script overwrites them in place. Commit or stash first." >&2
    exit 2
fi

oracle_for() {
    local want="$1" t
    for t in "${TARGETS[@]}"; do
        [[ "${t%%:*}" == "$want" ]] || continue
        local rest="${t#*:}"
        printf '%s\t%s\n' "${rest%%:*}" "${rest#*:}"
        return 0
    done
    return 1
}

# Describe a mutant as one stable line: the first changed line number, the
# original text, and the replacement. This triple is the ledger's identity for
# a survivor, so a re-run recognises one it has already been triaged.
describe() {
    local orig="$1" mut="$2"
    # ` ==> ` is universalmutator's own rule syntax, reused here so a ledger row
    # reads the same way the rule that produced it does.
    diff --unchanged-line-format= --old-line-format='%dn|%L ==> ' --new-line-format='%L' \
        "$orig" "$mut" 2>/dev/null \
    | head -2 | tr -d '\n' \
    | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//'
}

TOTAL=0; KILLED=0; SURVIVED=0; ERRORED=0
declare -a NEW_SURVIVORS=()

for target in "${SELECTED[@]}"; do
    if [[ -n "$FILTER" && "$target" != *"$FILTER"* ]]; then continue; fi

    map="$(oracle_for "$target")" || {
        echo "ERROR  $target has no oracle in the TARGETS map - skipping" >&2
        ERRORED=$((ERRORED + 1)); continue
    }
    batsfile="${map%%$'\t'*}"; testre="${map#*$'\t'}"

    if [[ ! -f "$ROOT/$target" ]]; then
        echo "ERROR  no such target: $target" >&2
        ERRORED=$((ERRORED + 1)); continue
    fi

    echo "== $target  (oracle: $(basename "$batsfile") -f '$testre')"

    # Control, once per target rather than once per mutant. A suite that is
    # already red would score every mutant KILLED and report a perfect sweep.
    res=$(run_tests "$ROOT/$batsfile" "$testre"); st=${res% *}; count=${res#* }
    if [[ "$count" -eq 0 ]]; then
        echo "   ERROR: -f '$testre' matched NO tests. bats exits 0 having run"
        echo "          nothing, which reads exactly like a pass. Fix the regex."
        ERRORED=$((ERRORED + 1)); continue
    fi
    if [[ "$st" -ne 0 ]]; then
        echo "   ERROR: the oracle is already failing unmutated - every mutant"
        echo "          would score KILLED. Fix the tests first."
        ERRORED=$((ERRORED + 1)); continue
    fi

    outdir="$MUTANT_DIR/$(printf '%s' "$target" | tr -c 'A-Za-z0-9._-' '_')"
    rm -rf "$outdir"
    gen="$("$ROOT/tests/mutation/mutator.sh" "$ROOT/$target" "$outdir")"
    genst=$?
    if [[ "$genst" -eq 77 ]]; then
        echo "   SKIP: no usable docker daemon to generate mutants in"
        continue
    fi
    if [[ "$genst" -ne 0 ]]; then
        echo "   ERROR: mutant generation failed"
        ERRORED=$((ERRORED + 1)); continue
    fi
    echo "   $gen, $count oracle test(s)"

    for mutant in "$outdir"/*; do
        [[ -f "$mutant" ]] || continue
        TOTAL=$((TOTAL + 1))

        take_backup "$ROOT/$target" "gen-$(basename "$target")-$(basename "$mutant")" || {
            echo "   ERROR: could not copy $target aside"
            ERRORED=$((ERRORED + 1)); continue
        }
        backup="$BACKUP_PATH"
        desc="$(describe "$backup" "$mutant")"

        cp "$mutant" "$ROOT/$target" 2>/dev/null || true
        # The mutation must actually have landed. A no-op mutant scores KILLED
        # or SURVIVED on the unmutated file either way, and both answers are
        # lies -- this is the same assertion the corpus runner makes, and the
        # reason it exists at all.
        if cmp -s "$backup" "$ROOT/$target"; then
            echo "   ERROR: mutant $(basename "$mutant") changed nothing"
            ERRORED=$((ERRORED + 1)); restore_current || exit 3; continue
        fi

        res=$(run_tests "$ROOT/$batsfile" "$testre"); st=${res% *}

        # Restore before classifying. Stop the whole run if it failed: mutating
        # the next target on top of a tree we could not put back turns one
        # recoverable problem into an unrecoverable one.
        restore_current || exit 3

        if [[ "$st" -ne 0 ]]; then
            KILLED=$((KILLED + 1))
        else
            SURVIVED=$((SURVIVED + 1))
            NEW_SURVIVORS+=("$target"$'\t'"$desc")
            echo "   SURVIVED  $desc"
        fi
    done
done

# --- ledger ------------------------------------------------------------------
#
# Merge, never overwrite. A survivor that has already been triaged keeps its
# verdict and note; only genuinely new ones land as `unreviewed`. Rewriting the
# file from scratch each run would discard every hand-triage decision, which is
# the only part of this whole exercise a human actually did.
if [[ ${#NEW_SURVIVORS[@]} -gt 0 || -f "$LEDGER" ]]; then
    tmp="$WORK/ledger.tsv"
    {
        echo "# Survivors of ./tests/mutation/run-generated.sh -- mutants the suite did NOT kill."
        echo "# verdict: real-gap | equivalent | wontfix | unreviewed"
        echo "# A real-gap gets a test written, and then a corpus entry so the new test is"
        echo "# itself proved capable of failing. An equivalent mutant changes text without"
        echo "# changing behaviour and can never be killed by anything - it is not a defect."
        printf '#file\tmutation\tverdict\tnote\n'
    } > "$tmp"

    declare -A KNOWN=()
    if [[ -f "$LEDGER" ]]; then
        while IFS=$'\t' read -r f m v n; do
            [[ "$f" == \#* || -z "$f" ]] && continue
            KNOWN["$f"$'\t'"$m"]="$v"$'\t'"$n"
        done < "$LEDGER"
    fi

    for s in "${NEW_SURVIVORS[@]}"; do
        if [[ -n "${KNOWN[$s]+set}" ]]; then
            printf '%s\t%s\n' "$s" "${KNOWN[$s]}"
        else
            printf '%s\tunreviewed\t\n' "$s"
        fi
    done | sort >> "$tmp"

    cp "$tmp" "$LEDGER"
fi

echo
echo "killed $KILLED / $TOTAL   survived $SURVIVED   errored $ERRORED"
if [[ "$SURVIVED" -gt 0 ]]; then
    echo "ledger: $LEDGER  (survivors are findings to triage, not failures)"
fi
# Always 0 -- see the header. run-mutations.sh is the blocking gate.
exit 0
