#!/bin/bash
set -uo pipefail
#
# Run the Python half of the suite (tests/python/) against the containerised
# toolkit.
#
# Usage:
#   ./tests/toolkit/pytest.sh                       # the whole tests/python tree
#   ./tests/toolkit/pytest.sh tests/python/test_x.py  # one file
#   ./tests/toolkit/pytest.sh -k some_name          # the tree, filtered
#
# Exit status:
#   0   pytest passed
#   1   pytest failed, or the image could not be built
#  77   docker is unavailable -- the CALLER decides whether that is a skip.
#       Never 0: "the tool is missing" and "the tests passed" must not be the
#       same observable result. sync-nas.sh shipped that equivalence once, for
#       an unreachable NAS, and nobody noticed for weeks.
#
# The repo is mounted READ-ONLY. Nothing here needs to write to it, and a
# writable mount would put a test one bug away from editing tracked files --
# which is the hazard tests/mutation/ exists to contain. PYTHONDONTWRITEBYTECODE
# and pytest's cacheprovider are both disabled so a read-only mount is actually
# viable rather than merely aspirational.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# The tag is the Dockerfile's own content hash, so editing the Dockerfile
# necessarily builds a new image instead of silently reusing the old one. A
# fixed tag plus "build on first use" is exactly how this repo's duc-service
# ended up running code that the repo, the tests and git log all said had been
# fixed.
TAG="arr-toolkit:$(sha256sum "$HERE/Dockerfile" | cut -c1-12)"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "pytest.sh: no usable docker daemon" >&2
    exit 77
fi

if ! docker image inspect "$TAG" >/dev/null 2>&1; then
    echo "pytest.sh: building $TAG (first use)..." >&2
    if ! docker build -q -t "$TAG" "$HERE" >/dev/null; then
        echo "pytest.sh: could not build $TAG" >&2
        exit 1
    fi
fi

# A caller that names an existing path means "run exactly this"; anything else
# is a pytest flag and rides on top of the default target. Appending both would
# hand pytest the tree AND a file inside it, which collects some tests twice.
if [[ $# -gt 0 && -e "$1" ]]; then
    ARGS=("$@")
else
    ARGS=(tests/python "$@")
fi

# A hard address-space cap on the oracle, in KB. Overridable only so a test can
# watch it fire; a non-numeric value falls back rather than reaching ulimit.
#
# THIS IS NOT A TUNING KNOB, IT IS A BLAST DOOR: without it, a generated mutant
# that loops *allocating* (not just spinning) can exhaust host RAM and reboot
# the machine before run-generated.sh's wall-clock budget ever fires. Full
# incident, why `docker run --memory` doesn't work on this host, and the
# measurement behind the 512 MB figure below: docs/TEST-HARDENING-LOG.md §8.
#
# ulimit -v sets RLIMIT_AS, enforced per process by the kernel, no cgroup or
# privilege needed. 512 MB is 2x the tightest value the real suite passes at
# (256 MB) and ~3.5x below host RAM -- a runaway mutant dies with MemoryError
# and a red exit status (a correct KILLED) instead of taking the host with it.
MEM_KB="${PYTEST_ADDRESS_SPACE_KB:-524288}"
[[ "$MEM_KB" =~ ^[0-9]+$ ]] || MEM_KB=524288

# `exec` so pytest replaces the shell and keeps the container's exit status; the
# cap is inherited across exec because RLIMIT_AS is a property of the process.
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "$ROOT:/mnt:ro" \
    -w /mnt \
    -e PYTHONDONTWRITEBYTECODE=1 \
    -e PYTHONPATH=/mnt/scripts/lib \
    "$TAG" \
    sh -c 'ulimit -v "$1" || exit 1; shift; exec python3 -m pytest -p no:cacheprovider -q "$@"' \
       sh "$MEM_KB" "${ARGS[@]}"
