#!/bin/bash
set -uo pipefail
#
# Generate mutants of one file, using universalmutator in a container.
#
# Shell and Python are both handled; the language is picked from the file's
# extension, because that is the only thing that distinguishes them here and a
# flag would just be a second place for the two to disagree.
#
# Usage:
#   ./tests/mutation/mutator.sh <source-file> <output-dir>
#
# Exit status:
#   0   mutants were generated into <output-dir> (at least one)
#   1   generation failed, or produced nothing
#   2   usage error
#  77   docker is unavailable -- the CALLER decides whether that is a skip.
#       Returning a distinct status rather than exiting 0 keeps "no docker"
#       from looking identical to "no mutants survived", which is the whole
#       failure mode this directory exists to catch.
#
# The repo is NEVER bind-mounted. universalmutator writes its scratch files
# (.tmp_mutant.N.<ext>) into the working directory, so a read-only mount of the
# repo makes it crash outright and a writable one puts it one bug away from
# scribbling on tracked files. Copying the single target into a throwaway
# directory is both simpler and a strictly better safety property: the
# container cannot reach anything it was not handed.

MUT_VERSION="1.14.1"
MUT_IMAGE="arr-mutator:${MUT_VERSION}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ $# -eq 2 ]] || { echo "usage: $0 <source-file> <output-dir>" >&2; exit 2; }
SRC="$1"; OUTDIR="$2"
[[ -f "$SRC" ]] || { echo "mutator: no such file: $SRC" >&2; exit 2; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "mutator: no usable docker daemon" >&2
    exit 77
fi

# Build on first use only. `docker build` on an unchanged Dockerfile is nearly
# free, but it is not free enough to pay on every one of a few hundred mutants.
if ! docker image inspect "$MUT_IMAGE" >/dev/null 2>&1; then
    echo "mutator: building $MUT_IMAGE (first use)..." >&2
    if ! docker build -q -t "$MUT_IMAGE" "$HERE" >/dev/null; then
        echo "mutator: could not build $MUT_IMAGE" >&2
        exit 1
    fi
fi

WORKDIR="$(mktemp -d)"
RAW="$(mktemp -d)"
trap 'rm -rf "$WORKDIR" "$RAW"' EXIT

BASE="$(basename "$SRC")"
if [[ "$BASE" == *.py ]]; then
    # python.rules ships inside universalmutator itself, so unlike shell.rules
    # there is nothing to copy in -- `--only python.rules` resolves against the
    # package. `python` is a real language argument here (the extension lookup
    # succeeds), where the shell path has to pass `none`.
    LANG_ARG="python"
    RULES="python.rules"
    IGNORE="python.ignore"
else
    # universalmutator picks its language from the file extension, and the two
    # load-bearing hook scripts here (scripts/pre-commit, scripts/post-merge)
    # have none. Give the copy a .sh name so they are mutable like everything
    # else; the original name is irrelevant once the bytes are in a scratch
    # directory.
    [[ "$BASE" == *.sh ]] || BASE="${BASE}.sh"
    LANG_ARG="none"
    RULES="shell.rules"
    IGNORE="shell.ignore"
    cp "$HERE/shell.rules" "$WORKDIR/" || exit 1
fi
cp "$SRC" "$WORKDIR/$BASE" || exit 1
cp "$HERE/$IGNORE" "$WORKDIR/" || exit 1

mkdir -p "$OUTDIR"

# `none --only shell.rules`, and both halves matter.
#
# universalmutator ALWAYS applies a built-in ruleset; passing `none` does not
# make it empty. Measured on check-secrets.sh: `none` alone produced 119
# mutants, all of them universal.rules noise (`/` -> `*`, an inserted `break;`)
# that means nothing in bash. `--only shell.rules` is what actually restricts
# generation to this repo's ruleset -- 5 mutants on that same file, every one of
# them a real bash defect. `none` remains as the language argument because a
# rules filename in that position makes universalmutator try an extension ->
# language lookup and die with KeyError: '.sh'.
#
# --noCheck because universalmutator's own --cmd validation path crashes
# (os.remove(None) in genmutants.py's cmdHandler). We filter with `bash -n`
# below instead, which is the check we actually want anyway.
# --user so nothing lands in the output directory owned by root: pi1 has no
# sudo available, and root-owned mutants would be undeletable.
docker run --rm --user "$(id -u):$(id -g)" \
    -v "$WORKDIR:/work" -v "$RAW:/out" -w /work \
    "$MUT_IMAGE" "$BASE" "$LANG_ARG" --only "$RULES" \
    --mutantDir /out --noCheck --ignore "$IGNORE" >/dev/null 2>&1

# Keep only mutants that parse. A mutant that does not cannot distinguish a good
# test suite from a bad one -- every test fails on it for the same uninteresting
# reason, and it would be scored KILLED, inflating the score with mutants that
# prove nothing.
#
# `ast.parse` rather than py_compile: py_compile writes a .pyc beside the file,
# and a syntax checker with a side effect is not one this directory should own.
parses() {
    if [[ "$BASE" == *.py ]]; then
        python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$1" 2>/dev/null
    else
        bash -n "$1" 2>/dev/null
    fi
}

kept=0; dropped=0
for m in "$RAW"/*; do
    [[ -f "$m" ]] || continue
    if parses "$m"; then
        cp "$m" "$OUTDIR/$(basename "$m")"
        kept=$((kept + 1))
    else
        dropped=$((dropped + 1))
    fi
done

if [[ "$kept" -eq 0 ]]; then
    echo "mutator: generated no usable mutants for $SRC" >&2
    exit 1
fi

echo "$kept kept, $dropped unparseable"
