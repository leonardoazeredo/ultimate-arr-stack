#!/bin/bash
set -uo pipefail
#
# One-shot kcov diagnostic over the bats suite. NOT a gate, and deliberately
# not wired into ./tests/run-tests.sh.
#
# Usage:
#   ./tests/toolkit/coverage.sh
#
# Exit status:
#   0   the run completed, whatever it found -- this never fails a build
#  77   docker is unavailable. Never 0: an absent tool and a clean report must
#       not be the same observable result, which is the rule pytest.sh states
#       at greater length.
#
# WHAT THIS IS FOR, AND WHAT IT IS NOT FOR
#
# tests/shellcheck.bats already answers "which files does the suite never enter"
# at file granularity, for free, with no container -- it derives the unswept set
# from TARGETS at run time. kcov's only non-redundant contribution is *within* a
# file: which branches of a file we do enter go unexercised.
#
# That is also the signal this repo's test idiom destroys. A function body
# extracted with awk and eval'd has no path, so kcov cannot attribute a single
# line of it. tests/toolkit/kcov-blind-spots.txt lists the files that are tested
# that way and the summary marks them BLIND, not 0%.
#
# So this script exists to be run once and read once. If every zero it reports
# is either a listed blind spot or a file with no TARGETS entry -- which
# `tests/shellcheck.bats` already reports -- then kcov has told us nothing new,
# and the right move is to delete this script and the kcov line from the
# Dockerfile rather than carry a second tool that duplicates the first. That
# rule is written down in tests/toolkit/README.md so it cannot quietly lapse
# into "we have a coverage tool" without anyone acting on what it said.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/arr-kcov-$$"
SUMMARY="$HERE/coverage-summary.tsv"

TAG="arr-toolkit:$(sha256sum "$HERE/Dockerfile" | cut -c1-12)"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "coverage.sh: no usable docker daemon" >&2
    exit 77
fi

if ! docker image inspect "$TAG" >/dev/null 2>&1; then
    echo "coverage.sh: building $TAG (first use)..." >&2
    if ! docker build -q -t "$TAG" "$HERE" >/dev/null; then
        echo "coverage.sh: could not build $TAG" >&2
        exit 0
    fi
fi

mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT

# The repo is mounted READ-WRITE here, unlike pytest.sh, and that is a real
# difference worth stating: the bats suite writes a vendored-submodule bootstrap
# and several tests stage files inside the tree. kcov's own output goes to a
# separate mount so nothing lands in the repo. This is the one script in
# tests/toolkit/ that can touch tracked files, which is a further reason it is a
# one-shot diagnostic run by hand rather than anything automatic.
#
# --bash-dont-parse-binary-dir keeps kcov from following into /usr/bin and
# reporting on the system's own shell scripts.
echo "coverage.sh: running the suite under kcov (this is slow)..." >&2
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "$ROOT:/mnt" \
    -v "$OUT:/out" \
    -w /mnt \
    "$TAG" \
    kcov --bash-dont-parse-binary-dir /out ./tests/run-tests.sh \
    >"$OUT/kcov.log" 2>&1
status=$?

if [[ -z "$(find "$OUT" -name 'coverage.json' -print -quit)" ]]; then
    echo "coverage.sh: kcov produced no coverage.json (exit $status). Tail of its log:" >&2
    tail -20 "$OUT/kcov.log" >&2
    exit 0
fi

# Build the summary. Rows are file, percent, and a category: BLIND for a file
# kcov structurally cannot measure, otherwise the raw percentage.
python3 - "$OUT" "$ROOT" "$SUMMARY" <<'PYEOF'
import json, os, sys, glob

out_dir, root, summary_path = sys.argv[1], sys.argv[2], sys.argv[3]

blind = set()
with open(os.path.join(root, "tests/toolkit/kcov-blind-spots.txt")) as fh:
    for line in fh:
        line = line.strip()
        if line and not line.startswith("#"):
            blind.add(line)

rows = {}
for path in glob.glob(os.path.join(out_dir, "**", "coverage.json"), recursive=True):
    with open(path) as fh:
        try:
            data = json.load(fh)
        except ValueError:
            continue
    for f in data.get("files", []):
        name = f.get("file", "")
        if name.startswith("/mnt/"):
            name = name[len("/mnt/"):]
        if not name or name.startswith("tests/bats"):
            continue
        rows[name] = f.get("percent_covered", "0")

with open(summary_path, "w") as fh:
    fh.write("# Written by tests/toolkit/coverage.sh. BLIND means kcov cannot\n")
    fh.write("# measure the file at all -- see kcov-blind-spots.txt. Do not\n")
    fh.write("# read a BLIND row, or any zero, as an absence of tests without\n")
    fh.write("# checking tests/mutation/survivors.tsv first.\n")
    fh.write("#file\tpercent\tcategory\n")
    for name in sorted(rows):
        pct = rows[name]
        cat = "BLIND" if name in blind else "measured"
        fh.write(f"{name}\t{pct}\t{cat}\n")

print(f"coverage.sh: wrote {len(rows)} rows to {summary_path}", file=sys.stderr)
PYEOF

exit 0
