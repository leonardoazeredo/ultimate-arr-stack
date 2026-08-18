#!/usr/bin/env bats
# Unit tests for scripts/detect-vpn-zombies.sh, with docker stubbed so no
# live NAS/network access is needed. The script is a flat top-level script
# (no functions to source selectively), so each test stubs `docker` then
# sources the whole thing inside a `bash -c` subshell and asserts on its
# stdout/exit code.
#
# Regression coverage for the fix that added vpn-socks5 to DEPENDENTS
# (previously missing, a real pre-existing gap in Gluetun-recreate zombie
# detection found while auditing this script for NAS/VLAN10 migration
# readiness) — confirms the detection logic actually catches vpn-socks5
# going stale, not just that the script runs without crashing on it.

setup() {
    load helpers/setup
}

stub_docker() {
    # $1 = current gluetun ID, $2 = space-separated list of "name:mode" pairs
    # for docker inspect --format '{{.HostConfig.NetworkMode}}' <name>.
    cat <<EOF
docker() {
    if [[ "\$*" == *"--format {{.Id}} gluetun"* ]]; then
        echo "$1"
        return 0
    fi
    local name="\${*: -1}"
    case "\$name" in
$2
        *) return 1 ;;
    esac
}
export -f docker
EOF
}

@test "detect-vpn-zombies reports clean when every dependent shares gluetun's current netns" {
    run bash -c "
        $(stub_docker current-id '
            qbittorrent) echo "container:current-id" ;;
            sabnzbd) echo "container:current-id" ;;
            prowlarr) echo "container:current-id" ;;
            flaresolverr) echo "container:current-id" ;;
            vpn-socks5) echo "container:current-id" ;;
            magnetio-addon) echo "container:current-id" ;;
        ')
        source '$REPO_ROOT/scripts/detect-vpn-zombies.sh'
    "
    assert_success
    assert_output --partial "OK: all VPN-tunneled dependents share Gluetun's current netns"
}

@test "detect-vpn-zombies flags vpn-socks5 specifically when it's bound to a stale gluetun ID" {
    run bash -c "
        $(stub_docker current-id '
            qbittorrent) echo "container:current-id" ;;
            sabnzbd) echo "container:current-id" ;;
            prowlarr) echo "container:current-id" ;;
            flaresolverr) echo "container:current-id" ;;
            vpn-socks5) echo "container:stale-id" ;;
            magnetio-addon) echo "container:current-id" ;;
        ')
        source '$REPO_ROOT/scripts/detect-vpn-zombies.sh'
    "
    assert_failure
    assert_output --partial "ZOMBIE CONTAINERS"
    assert_output --partial "vpn-socks5"
    assert_output --partial "docker restart"
    refute_output --partial "qbittorrent"
}

@test "detect-vpn-zombies skips a dependent docker inspect can't find rather than crashing" {
    run bash -c "
        $(stub_docker current-id '
            qbittorrent) echo "container:current-id" ;;
            sabnzbd) return 1 ;;
            prowlarr) echo "container:current-id" ;;
            flaresolverr) echo "container:current-id" ;;
            vpn-socks5) echo "container:current-id" ;;
            magnetio-addon) echo "container:current-id" ;;
        ')
        source '$REPO_ROOT/scripts/detect-vpn-zombies.sh'
    "
    assert_success
    assert_output --partial "OK: all VPN-tunneled dependents share Gluetun's current netns"
}
