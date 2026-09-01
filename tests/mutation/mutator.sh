#!/bin/bash
set -uo pipefail
#
# Generate shell mutants of one file, using universalmutator in a container.
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
# universalmutator picks its language from the file extension, and the two
# load-bearing hook scripts here (scripts/pre-commit, scripts/post-merge) have
# none. Give the copy a .sh name so they are mutable like everything else; the
# original name is irrelevant once the bytes are in a scratch directory.
[[ "$BASE" == *.sh ]] || BASE="${BASE}.sh"
cp "$SRC" "$WORKDIR/$BASE" || exit 1
cp "$HERE/shell.rules" "$HERE/shell.ignore" "$WORKDIR/" || exit 1

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
    "$MUT_IMAGE" "$BASE" none --only shell.rules \
    --mutantDir /out --noCheck --ignore shell.ignore >/dev/null 2>&1

# Keep only mutants that are valid bash. A mutant that does not parse cannot
# distinguish a good test suite from a bad one -- every test fails on it for the
# same uninteresting reason, and it would be scored KILLED, inflating the score
# with mutants that prove nothing.
kept=0; dropped=0
for m in "$RAW"/*; do
    [[ -f "$m" ]] || continue
    if bash -n "$m" 2>/dev/null; then
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
