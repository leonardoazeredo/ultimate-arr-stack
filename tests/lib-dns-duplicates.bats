#!/usr/bin/env bats
# scripts/lib/check-dns-duplicates.sh
#
# Warns when a .lan name is defined in BOTH dnsmasq's 02-local-dns.conf and
# pihole.toml, which is a real class of bug here: the two answer independently
# and whichever wins is not something the reader of either file can predict.
#
# Two ssh_to_nas calls with different jobs, so the stub dispatches on the
# command text rather than answering everything the same way. A stub that
# answered both the same would make the intersection compare a list with
# itself, and every name would look like a duplicate.
#
# Warnings only: every arm returns 0.

setup() {
    load helpers/setup
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    source "$REPO_ROOT/scripts/lib/common.sh"
    source "$REPO_ROOT/scripts/lib/check-dns-duplicates.sh"

    has_nas_config()    { return "${NAS_CONFIG_RC:-0}"; }
    is_nas_reachable()  { return "${REACHABLE_RC:-0}"; }
    is_ssh_available()  { return "${SSH_RC:-0}"; }
    get_nas_stack_dir() { echo "/volume1/docker/arr-stack"; }
    SSH_CMD_LOG="$BATS_TEST_TMPDIR/ssh-cmds"
    : > "$SSH_CMD_LOG"
    ssh_to_nas() {
        printf '%s\n' "$1" >> "$SSH_CMD_LOG"
        case "$1" in
            *dnsmasq*)     printf '%s' "${DNSMASQ-}" ;;
            *pihole.toml*) printf '%s' "${PIHOLE-}" ;;
        esac
    }
}

# --- the skip ladder --------------------------------------------------------

@test "dns-duplicates: no NAS config is a skip" {
    NAS_CONFIG_RC=1
    run check_dns_duplicates
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP: No NAS host in .claude/config.local.md"* ]]
}

@test "dns-duplicates: an unreachable NAS is a skip" {
    REACHABLE_RC=1
    run check_dns_duplicates
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP: NAS not reachable"* ]]
}

@test "dns-duplicates: a closed SSH port is a skip" {
    SSH_RC=1
    run check_dns_duplicates
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP: SSH port not reachable"* ]]
}

@test "dns-duplicates: an unreadable dnsmasq config is a skip, not an all-clear" {
    # Without this, an empty left-hand side makes the intersection empty and the
    # check reports "No duplicate DNS entries" -- an all-clear produced by
    # having read nothing at all.
    DNSMASQ='' PIHOLE='sonarr'
    run check_dns_duplicates
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP: Could not read dnsmasq config"* ]]
    [[ "$output" != *"OK: No duplicate"* ]]
}

@test "dns-duplicates: it never runs the pihole query when dnsmasq gave nothing" {
    DNSMASQ='' PIHOLE='sonarr'
    check_dns_duplicates >/dev/null
    [[ "$(cat "$SSH_CMD_LOG")" != *"pihole.toml"* ]]
}

# --- the intersection -------------------------------------------------------

@test "dns-duplicates: an overlapping name is reported with its .lan suffix" {
    DNSMASQ='jellyfin
sonarr'
    PIHOLE='sonarr'
    run check_dns_duplicates
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: Duplicate .lan domains"* ]]
    [[ "$output" == *"- sonarr.lan"* ]]
    [[ "$output" != *"jellyfin.lan"* ]]
}

@test "dns-duplicates: every overlapping name is listed, not just the first" {
    DNSMASQ='jellyfin
sonarr
radarr'
    PIHOLE='sonarr
radarr'
    run check_dns_duplicates
    [[ "$output" == *"- sonarr.lan"* ]]
    [[ "$output" == *"- radarr.lan"* ]]
}

@test "dns-duplicates: no overlap reports OK" {
    DNSMASQ='jellyfin'
    PIHOLE='sonarr'
    run check_dns_duplicates
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: No duplicate DNS entries"* ]]
}

@test "dns-duplicates: an empty pihole.toml side is no overlap, not a skip" {
    # Asymmetric on purpose: dnsmasq is the file this repo owns, so failing to
    # read it means the check learned nothing. pihole.toml legitimately holds
    # no .lan entries, and that is the state the check wants people to be in.
    DNSMASQ='sonarr'
    PIHOLE=''
    run check_dns_duplicates
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: No duplicate DNS entries"* ]]
}

@test "dns-duplicates: a duplicate is a warning and never blocks" {
    DNSMASQ='sonarr' PIHOLE='sonarr'
    run check_dns_duplicates
    [ "$status" -eq 0 ]
}

# --- matching rules ---------------------------------------------------------

@test "dns-duplicates: DEFECT - a name is matched whole, not as a hyphen-bounded word" {
    # `grep -w` counts a hyphen as a word boundary, so "sonarr" matched inside
    # "sonarr-4k" and the check reported a conflict between two names that
    # resolve to different hosts. A warning that fires on correct config is how
    # a check gets ignored.
    DNSMASQ='sonarr'
    PIHOLE='sonarr-4k'
    run check_dns_duplicates
    [[ "$output" == *"OK: No duplicate DNS entries"* ]]
    [[ "$output" != *"WARNING"* ]]
}

@test "dns-duplicates: DEFECT - a name is matched literally, not as a regex" {
    # A dot in a name matches any character once it is compiled as a pattern.
    DNSMASQ='a.b'
    PIHOLE='axb'
    run check_dns_duplicates
    [[ "$output" == *"OK: No duplicate DNS entries"* ]]
}

@test "dns-duplicates: a genuine exact match is still caught" {
    # The pair to the two above: tightening the match must not turn the check
    # off. Without this, `grep -qxF -- 'no-such-name'` would satisfy both
    # DEFECT tests while never matching anything at all.
    DNSMASQ='sonarr-4k'
    PIHOLE='sonarr-4k'
    run check_dns_duplicates
    [[ "$output" == *"- sonarr-4k.lan"* ]]
}

@test "dns-duplicates: it reads the config under the configured stack dir" {
    DNSMASQ='sonarr' PIHOLE=''
    check_dns_duplicates >/dev/null
    [[ "$(cat "$SSH_CMD_LOG")" == *"/volume1/docker/arr-stack/pihole/dnsmasq.d/02-local-dns.conf"* ]]
}
