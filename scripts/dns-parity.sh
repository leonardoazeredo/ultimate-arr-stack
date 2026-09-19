#!/bin/bash
# dns-parity.sh — send the committed baseline matrix to two resolvers and diff
# the answers. Phase 3.6 / Gate 3 of the DNS migration plan.
#
#   ./scripts/dns-parity.sh
#       NAS Pi-hole at $NAS_DNS_IP (default 192.168.110.246) against the
#       router's AdGuard Home at 192.168.8.1:3053, queried through pi1.
#
#   ./scripts/dns-parity.sh 192.168.110.246:53 'jump=pi@pi1.local:192.168.8.1:3053'
#       explicit, which is what a run from another vantage point needs.
#
#   ./scripts/dns-parity.sh A B tests/fixtures/dns-baseline.txt
#       an explicit fixture.
#
# A resolver spec is `host[:port]` or `jump=user@host:host[:port]`. The jump
# form exists because the two resolvers are not reachable from the same place:
# the NAS answers from a client VLAN, and the router's AdGuard Home on :3053 is
# reachable only from the maintenance VLAN, where `ssh pi@pi1.local` gets you.
# Port 3053 is dropped rather than closed from every client VLAN, so a run that
# ignores the vantage does not fail - it times out, which reads like a resolver
# problem instead of a firewall one.
#
# The report names the vantage of each side, lists excused rows separately from
# unexplained ones, and exits 0 only when nothing is unexplained.
#
# Exit codes, matching scripts/dns-matrix-check.sh:
#   0 every row agrees or is an excused ALLOW-DIFF; 1 an unexplained difference;
#   77 it could not run at all.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/dns-parity.sh
source "$SCRIPT_DIR/lib/dns-parity.sh"

DEFAULT_A="${NAS_DNS_IP:-192.168.110.246}:53"
DEFAULT_B="jump=${ADGUARD_JUMP:-pi@pi1.local}:${ADGUARD_DNS_IP:-192.168.8.1}:${ADGUARD_DNS_PORT:-3053}"

usage() {
    cat <<'USAGE'
usage: dns-parity.sh [resolver-a] [resolver-b] [fixture]

  resolver  host[:port]  or  jump=user@host:host[:port]
  fixture   defaults to tests/fixtures/dns-baseline.txt

  ex: dns-parity.sh 192.168.110.246:53 jump=pi@pi1.local:192.168.8.1:3053
USAGE
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

SPEC_A="${1:-$DEFAULT_A}"
SPEC_B="${2:-$DEFAULT_B}"
FIXTURE="${3:-$DNS_MATRIX_FIXTURE}"

for spec in "$SPEC_A" "$SPEC_B"; do
    if ! dns_parity_parse_spec "$spec" >/dev/null; then
        printf 'dns-parity: not a resolver spec: %s\n' "$spec" >&2
        printf '  expected host[:port] or jump=user@host:host[:port]\n' >&2
        exit 2
    fi
done

dns_parity_check "$SPEC_A" "$SPEC_B" "$FIXTURE"
rc=$?

if [[ "$rc" -eq 77 ]]; then
    printf 'dns-parity: could not run - no parity verdict was produced\n' >&2
    exit 77
fi
exit "$rc"
