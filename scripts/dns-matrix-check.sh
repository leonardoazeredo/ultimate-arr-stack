#!/bin/bash
# dns-matrix-check.sh — check the committed baseline matrix against one resolver.
#
#   ./scripts/dns-matrix-check.sh                       the NAS Pi-hole, port 53
#   ./scripts/dns-matrix-check.sh 192.168.8.1 3053      AdGuard Home from pi1
#
# This is the single-resolver half of the migration's acceptance testing. The
# two-resolver parity check (3.6) is a separate script; both share the row
# evaluation in scripts/lib/dns-matrix.sh.
#
# Exits 0 when every row matched, 1 when any row did not, 77 when the check
# could not run (no dig, unreadable fixture). 77 is the repo's "no oracle"
# status: a skipped check and a passing check must not look the same.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/dns-matrix.sh
source "$SCRIPT_DIR/lib/dns-matrix.sh"

RESOLVER="${1:-${NAS_DNS_IP:-192.168.110.246}}"
PORT="${2:-53}"
FIXTURE="${3:-$DNS_MATRIX_FIXTURE}"

dns_matrix_check_resolver "$RESOLVER" "$PORT" "$FIXTURE"
rc=$?

if [[ "$rc" -eq 2 ]]; then
    exit 77
fi
exit "$rc"
