#!/bin/bash
# Check for and optionally clean orphaned Docker networks
#
# Interactive, manual-only tooling. Nothing invokes it automatically and nothing
# is meant to: run it by hand before a deployment if you have had failed
# attempts and suspect a network is left over. "No automated caller" is not
# evidence this is dead code.
#
# Usage: ./scripts/check-network.sh

set -euo pipefail

# The networks this repo's compose files CREATE, as opposed to the ones they
# declare `external: true` and merely join. Only a network we own can be
# orphaned by a failed deploy of ours.
#
# Hardcoded rather than parsed out of the YAML at run time, for the same reason
# detect-vpn-zombies.sh hardcodes its dependent map: a bash YAML parser is a
# liability on a NAS whose compose files may be mid-sync, and this script has to
# work when the deploy is in a bad state -- that is the only time it is run.
# tests/check-network.bats derives the same set from the compose files and fails
# if the two disagree, so the list cannot go stale quietly.
OWNED_NETWORKS=(arr-core vpn-net magnetio-net traefik-lan)

# Color output, disabled when stdout is not a terminal so a redirected run or a
# `| tee` produces a readable log rather than escape sequences. Deliberately
# gated on stdout (-t 1) while the removal prompt below is gated on stdin
# (-t 0): they are different questions and a pipeline can make them disagree.
GREEN='' YELLOW='' NC=''
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
fi

# A seam, not indirection: `[[ -t 0 ]]` cannot be made true from a test without
# allocating a pty, so the only alternative to overriding this is leaving the
# entire interactive branch -- the one that reaches `docker network rm` -- with
# no test at all. tests/check-network.bats overrides it in both directions.
stdin_is_tty() { [[ -t 0 ]]; }

# Report on one network, and offer to remove it if it is orphaned.
# Args: $1 = network name
check_one_network() {
    local net="$1" containers

    if ! docker network inspect "$net" &>/dev/null; then
        echo -e "${GREEN}OK${NC}: $net doesn't exist (will be created on deploy)"
        return 0
    fi

    containers=$(docker network inspect "$net" -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)
    if [[ -n "${containers// /}" ]]; then
        # The template emits a trailing space after every name, so a network
        # with one container yields "name " -- and an EMPTY one yields "". The
        # check strips spaces before testing so a future template change that
        # emits a bare separator cannot read as "in use" and silently stop this
        # script from ever offering to clean anything.
        echo -e "${GREEN}OK${NC}: $net exists with containers: $containers"
        return 0
    fi

    echo -e "${YELLOW}WARNING${NC}: $net network exists but has no containers attached."
    echo "         This may be orphaned from a previous deployment."
    echo ""

    if ! stdin_is_tty; then
        # Not interactive: say what to run, do not guess. This is the branch a
        # redirected or piped run takes, and it must never remove anything.
        echo "Run interactively to remove, or use: docker network rm $net"
        return 0
    fi

    # `|| true` because a closed stdin (Ctrl-D, or a caller that lied about
    # having a terminal) makes read return 1, and under `set -e` that would kill
    # the script mid-report. REPLY is pre-cleared so the EOF case lands on the
    # SAFE branch rather than on whatever a previous iteration left behind.
    REPLY=""
    read -r -p "Remove it? [y/N] " -n 1 REPLY || true
    echo
    if [[ "${REPLY:-}" =~ ^[Yy]$ ]]; then
        docker network rm "$net"
        echo -e "${GREEN}OK${NC}: Removed $net"
    else
        echo "Skipped. You can remove it manually with: docker network rm $net"
    fi
}

main() {
    echo ""
    echo "Checking Docker networks..."
    echo ""

    local net
    for net in "${OWNED_NETWORKS[@]}"; do
        check_one_network "$net"
    done

    echo ""
    echo "All Docker networks:"
    docker network ls --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}"

    echo ""
    echo "Tip: To clean up all unused networks: docker network prune"
    echo ""
}

# Sourced by tests/check-network.bats; executed by a human.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
