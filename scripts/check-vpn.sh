#!/bin/bash
set -euo pipefail
#
# Verify VPN is working — confirms Gluetun's exit IP differs from the
# household's WAN IP, and that every VPN-tunneled dependent's egress IP matches
# Gluetun's (not leaking via a fallback route). This is the bash/cron-friendly
# counterpart to tests/e2e/vpn-security.spec.ts's egress-IP checks — both
# implement the same comparison and should be kept in sync.
#
# The reference for "not tunneled" is a BRIDGE-ONLY CONTAINER'S EGRESS, not the
# NAS's own LAN address. Until 2026-09-01 this compared Gluetun's exit IP
# against `hostname -I`, which cannot detect anything on this network: every IP
# here comes from ifconfig.me, which reports the public source address it sees,
# and behind NAT that is never equal to a 192.168.x.x LAN address. The headline
# leak check was incapable of firing. The e2e suite had already been written the
# correct way — `egressIp('sonarr')`, commented "sonarr is bridge-only — gives
# host WAN egress" — while its header claimed to productionize this script's
# comparison. The two had silently diverged, and the weaker half was the one
# wired into cron.
#
# Usage:
#   ./scripts/check-vpn.sh
#
# Exit codes:
#   0 = VPN is active and no tunneled dependent is leaking
#   1 = VPN leak detected (an IP matched the household WAN IP, or Gluetun
#       unreachable)
#
# Use in cron or monitoring to catch VPN failures:
#   */5 * * * * /path/to/arr-stack/scripts/check-vpn.sh || notify "VPN leak!"

TUNNELED_SERVICES=(qbittorrent prowlarr sabnzbd flaresolverr)

# Bridge-only, no VPN dependency, so its egress IS the household's WAN IP.
# tests/e2e/vpn-security.spec.ts picks the same container for the same reason
# and carries a standing test that Sonarr must NOT match Gluetun — so if this
# ever stops being bridge-only, that suite says so rather than this script
# quietly comparing the VPN against itself and reporting OK forever.
BRIDGE_REF="${BRIDGE_REF:-sonarr}"

# Uses /ip specifically: ifconfig.me serves curl a plain IP at the bare root,
# but serves wget (no Accept header) its full HTML homepage instead — /ip
# returns plain text for both clients, confirmed live against Gluetun (which
# has no curl, only wget).
egress_ip() {
    docker exec "$1" sh -c 'curl -s --max-time 5 https://ifconfig.me/ip || wget -qO- --timeout=5 https://ifconfig.me/ip' 2>/dev/null
}

# Get Gluetun's exit IP
echo "Checking VPN exit IP..."
VPN_IP=$(egress_ip gluetun) || {
    echo "ERROR: Could not reach an IP-check service through Gluetun"
    echo "       Gluetun may be down or VPN disconnected"
    exit 1
}

if [[ -z "$VPN_IP" ]]; then
    echo "ERROR: Empty response from IP check"
    exit 1
fi

WAN_IP=$(egress_ip "$BRIDGE_REF") || WAN_IP=""

if [[ -z "$WAN_IP" ]]; then
    # Loud, and named as a skip. The comparison genuinely cannot be made without
    # a reference, and failing the run would page someone every time an unrelated
    # container is down — but a silent skip is how a guard stops guarding, so it
    # says which check did not run.
    echo "WARN: could not determine the household WAN IP via $BRIDGE_REF"
    echo "      SKIPPED: Gluetun-vs-WAN comparison (is $BRIDGE_REF running?)"
elif [[ "$VPN_IP" == "$WAN_IP" ]]; then
    echo "LEAK DETECTED: VPN IP ($VPN_IP) matches the household WAN IP"
    echo "               Gluetun is not routing through the VPN!"
    exit 1
else
    echo "OK: VPN is active"
fi
echo "  WAN IP: ${WAN_IP:-unknown}"
echo "  VPN IP: $VPN_IP"

# Check each VPN-tunneled dependent's egress IP matches Gluetun's exactly —
# not just "differs from the WAN IP", since a dependent leaking via some other
# non-VPN route would also differ from it without actually being tunneled.
echo ""
echo "Checking tunneled services..."
leaked=0
for svc in "${TUNNELED_SERVICES[@]}"; do
    svc_ip=$(egress_ip "$svc") || svc_ip=""
    if [[ -z "$svc_ip" ]]; then
        echo "  WARN: $svc — could not determine egress IP (container down or unreachable)"
        continue
    fi
    if [[ "$svc_ip" == "$VPN_IP" ]]; then
        echo "  OK: $svc egress IP matches Gluetun ($svc_ip)"
    else
        echo "  LEAK DETECTED: $svc egress IP ($svc_ip) does NOT match Gluetun ($VPN_IP)"
        leaked=1
    fi
done

if [[ "$leaked" -eq 1 ]]; then
    exit 1
fi
