#!/usr/bin/env bats
# Regression coverage for the 2026-08-31 silent volume-coverage gap.
#
# What happened: arr-backup.sh auto-detected ONE volume prefix (from gluetun,
# always `arr-stack`) and pasted it in front of every name in its curated list.
# Docker names a volume `<compose-project>_<name>`, and this stack spans four
# compose projects. When uptime-kuma moved into the `arr-utilities` project its
# volume became `arr-utilities_uptime-kuma-data`; the lookup for
# `arr-stack_uptime-kuma-data` found nothing, and the script printed
# "Skipping (volume not found)" and counted a benign skip. Every nightly run
# reported `11 backed up, 1 skipped, 0 failed` -- a clean-looking summary over an
# unprotected volume. `tailscale_tailscale-state` was worse: never in the list at
# all, while docs/EXIT-NODE-PROJECT-LOG.md requires a state-volume backup before
# node 1 is ever recreated, because recreating it severs every path to the NAS.
#
# These tests exercise the REAL resolve_volume() by extracting it from the script
# and evaluating it against controlled inventories. A test that only grepped the
# script for the right-looking strings could not tell a working resolver from a
# broken one -- which is the class of defect this suite keeps finding.
#
# Static only: no docker, no NAS. Runs anywhere the rest of the fast suite runs.

setup() {
    load helpers/setup
    BACKUP_SH="$REPO_ROOT/scripts/arr-backup.sh"

    # The volume inventory measured on the NAS 2026-08-31. Includes the three
    # real double-prefix collisions and the orphaned unprefixed `tailscale-state`.
    ALL_VOLUMES=$(cat <<'EOF'
arr-stack_bazarr-config
arr-stack_beszel-data
arr-stack_configarr-repos
arr-stack_decypharr-config
arr-stack_dnscrypt-config
arr-stack_gluetun-config
arr-stack_jellyfin-cache
arr-stack_jellyfin-config
arr-stack_magnetio-redis-data
arr-stack_pihole-etc-pihole
arr-stack_prowlarr-config
arr-stack_qbittorrent-config
arr-stack_radarr-config
arr-stack_sabnzbd-config
arr-stack_seerr-config
arr-stack_sonarr-config
arr-utilities_beszel-data
arr-utilities_configarr-repos
arr-utilities_diun-data
arr-utilities_duc-index
arr-utilities_uptime-kuma-data
magnetio_magnetio-redis-data
tailscale-state
tailscale_gluetun-exit-config
tailscale_tailscale-exit-state
tailscale_tailscale-state
EOF
)
    # What running containers actually mount, same measurement.
    MOUNTED_VOLUMES=$(cat <<'EOF'
arr-stack_bazarr-config
arr-stack_beszel-data
arr-stack_decypharr-config
arr-stack_dnscrypt-config
arr-stack_gluetun-config
arr-stack_jellyfin-cache
arr-stack_jellyfin-config
arr-stack_magnetio-redis-data
arr-stack_pihole-etc-pihole
arr-stack_prowlarr-config
arr-stack_qbittorrent-config
arr-stack_radarr-config
arr-stack_sabnzbd-config
arr-stack_seerr-config
arr-stack_sonarr-config
arr-utilities_diun-data
arr-utilities_duc-index
arr-utilities_uptime-kuma-data
tailscale_gluetun-exit-config
tailscale_tailscale-exit-state
tailscale_tailscale-state
EOF
)
    VOLUME_PREFIX=""
    RESOLVED_VOLUME=""
    RESOLVE_ERROR=""
}

# Define the script's real resolve_volume() in this shell. Extraction is asserted
# rather than assumed: a silently-empty eval would make every test below pass
# vacuously, which is the exact failure this file exists to prevent.
load_resolver() {
    local body
    body=$(awk '/^resolve_volume\(\) \{$/,/^\}$/' "$BACKUP_SH")
    [[ -n "$body" ]] || {
        echo "could not extract resolve_volume() from $BACKUP_SH -- was it renamed?"
        return 1
    }
    grep -qx '}' <<<"$body" || {
        echo "extraction never reached a closing brace; got:"
        echo "$body"
        return 1
    }
    eval "$body"
}

# The curated list, minus comments. Conditional appends (seerr/overseerr) are not
# included -- those are optional by design and handled before the loop.
curated_volumes() {
    awk '/^VOLUME_SUFFIXES=\($/,/^\)$/' "$BACKUP_SH" \
        | sed -e '1d' -e '$d' -e 's/#.*//' -e 's/[[:space:]]//g' \
        | grep .
}

@test "resolve_volume finds a volume under a non-arr-stack project prefix" {
    # THE REGRESSION. Under the old single-prefix scheme this name resolved to
    # arr-stack_uptime-kuma-data, which does not exist, and the run called it a skip.
    load_resolver

    resolve_volume uptime-kuma-data
    [ "$RESOLVED_VOLUME" = "arr-utilities_uptime-kuma-data" ] || {
        echo "expected arr-utilities_uptime-kuma-data, got '$RESOLVED_VOLUME'"
        return 1
    }
}

@test "resolve_volume breaks a two-prefix tie using the mounted volume" {
    # beszel-data exists twice: arr-stack_ (live) and arr-utilities_ (orphaned by
    # the project split). Backing up the orphan would produce a successful-looking
    # archive of an abandoned volume.
    #
    # Deliberately NOT using the measured inventory here. In every real collision
    # on this NAS the live volume also happens to sort first, so this assertion
    # would pass against a resolver that simply took the first candidate and
    # ignored the tie-break entirely -- proved by mutation, it did. The inventory
    # below is inverted so only a resolver actually consulting MOUNTED_VOLUMES
    # can get it right.
    load_resolver
    ALL_VOLUMES=$(printf '%s\n' aa-orphan_beszel-data zz-live_beszel-data)
    MOUNTED_VOLUMES="zz-live_beszel-data"

    resolve_volume beszel-data
    [ "$RESOLVED_VOLUME" = "zz-live_beszel-data" ] || {
        echo "expected the mounted zz-live_beszel-data, got '$RESOLVED_VOLUME'"
        echo "(a resolver taking the first candidate would return aa-orphan_beszel-data)"
        return 1
    }
}

@test "resolve_volume refuses to guess when a tie cannot be broken" {
    # configarr-repos exists under both prefixes and neither is mounted. Picking
    # one at random is worse than failing: the archive would look complete.
    load_resolver

    run resolve_volume configarr-repos
    [ "$status" -ne 0 ] || {
        echo "resolved an unbreakable tie instead of failing"
        return 1
    }

    resolve_volume configarr-repos || true
    [ -z "$RESOLVED_VOLUME" ] || {
        echo "RESOLVED_VOLUME was set on a failed resolution: '$RESOLVED_VOLUME'"
        return 1
    }
    [[ "$RESOLVE_ERROR" == *ambiguous* ]] || {
        echo "expected an 'ambiguous' reason, got: '$RESOLVE_ERROR'"
        return 1
    }
}

@test "resolve_volume ignores an unprefixed volume with the same name" {
    # There is a leftover bare `tailscale-state` alongside `tailscale_tailscale-state`.
    # Matching it would resolve the single most load-bearing volume in the list to
    # an empty orphan -- and report success.
    #
    # Asserted with NOTHING mounted, which is the case that actually discriminates.
    # With every container running, the mounted-volume tie-break masks a matcher
    # that wrongly accepts the bare name; with the tailscale container stopped --
    # entirely possible at 04:00 -- that safety net is gone and the match itself
    # has to be right. Proved by mutation: relaxing the matcher's length guard
    # passes the mounted variant of this test and fails this one.
    load_resolver
    MOUNTED_VOLUMES=""

    resolve_volume tailscale-state
    [ "$RESOLVED_VOLUME" = "tailscale_tailscale-state" ] || {
        echo "expected tailscale_tailscale-state, got '$RESOLVED_VOLUME'"
        return 1
    }
}

@test "resolve_volume fails with a reason when nothing matches" {
    load_resolver

    run resolve_volume no-such-volume
    [ "$status" -ne 0 ] || {
        echo "resolved a volume that does not exist"
        return 1
    }

    resolve_volume no-such-volume || true
    [ -n "$RESOLVE_ERROR" ] || {
        echo "failed without setting RESOLVE_ERROR -- the run would print an empty reason"
        return 1
    }
}

@test "--prefix pins resolution to exactly that prefix" {
    load_resolver
    VOLUME_PREFIX="arr-stack"

    # Pinned, so the arr-utilities volume must NOT be found even though it exists.
    run resolve_volume uptime-kuma-data
    [ "$status" -ne 0 ] || {
        echo "--prefix arr-stack resolved uptime-kuma-data, but only arr-utilities_ has it"
        return 1
    }

    resolve_volume sonarr-config
    [ "$RESOLVED_VOLUME" = "arr-stack_sonarr-config" ] || {
        echo "expected arr-stack_sonarr-config, got '$RESOLVED_VOLUME'"
        return 1
    }
}

@test "every curated volume resolves against the measured NAS inventory" {
    # Catches a typo in a newly added name, which would otherwise surface only as a
    # failed nightly run. If a volume is legitimately retired this test fails and
    # forces the removal to be a decision rather than a drift.
    load_resolver

    local list failed=""
    list=$(curated_volumes)
    [ -n "$list" ] || {
        echo "extracted an empty VOLUME_SUFFIXES list from $BACKUP_SH"
        return 1
    }

    local v
    while IFS= read -r v; do
        resolve_volume "$v" || failed+="  $v: $RESOLVE_ERROR"$'\n'
    done <<<"$list"

    [ -z "$failed" ] || {
        echo "curated volumes that do not resolve against the 2026-08-31 NAS inventory:"
        echo "$failed"
        return 1
    }
}

@test "the Tailscale node state volumes are in the curated list" {
    # docs/EXIT-NODE-PROJECT-LOG.md: recreating Tailscale node 1 severs every path
    # to the NAS at once -- SSH and the UGOS admin UI both ride its own subnet
    # route -- and must only be done with a state-volume backup. Dropping these
    # from the list re-arms that hazard silently, which is how they came to be
    # missing in the first place.
    local list
    list=$(curated_volumes)

    local v
    for v in tailscale-state tailscale-exit-state; do
        grep -qx "$v" <<<"$list" || {
            echo "'$v' is not backed up. docs/EXIT-NODE-PROJECT-LOG.md requires a"
            echo "state-volume backup before Tailscale node 1 is ever recreated."
            return 1
        }
    done
}

@test "an unresolvable curated volume is a failure, not a skip" {
    # The original defect was not the wrong prefix -- it was that the wrong prefix
    # was reported as a benign skip. Every name in VOLUME_SUFFIXES is there because
    # losing it costs manual reconfiguration, so "not found" can never be benign.
    local loop
    loop=$(awk '/^for suffix in "\$\{VOLUME_SUFFIXES\[@\]\}"; do$/,/^done$/' "$BACKUP_SH")
    [ -n "$loop" ] || {
        echo "could not extract the volume loop from $BACKUP_SH"
        return 1
    }

    # Comments in the loop describe the old bug on purpose; only executable lines count.
    local code
    code=$(grep -vE '^[[:space:]]*#' <<<"$loop")

    grep -q 'SKIPPED=' <<<"$code" && {
        echo "the volume loop still increments SKIPPED. A curated volume that cannot"
        echo "be resolved must count as FAILED -- a skip reads as a clean run."
        return 1
    }

    grep -q 'FAILED=\$((FAILED + 1))' <<<"$code" || {
        echo "the volume loop never increments FAILED"
        return 1
    }
    return 0
}
