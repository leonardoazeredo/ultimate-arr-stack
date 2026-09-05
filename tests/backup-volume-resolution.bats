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
tailscale_tailscale-state
EOF
)
    # Volumes referenced by a container that EXISTS, running or stopped -- the
    # primary tie-break. Same 2026-08-31 measurement. Note arr-stack_configarr-repos
    # is here but NOT in MOUNTED_VOLUMES below: its container is stopped, which is
    # exactly the distinction this set exists to draw. Anonymous volumes (64-hex
    # names) are omitted; they can never match a curated `*_<suffix>` pattern.
    ATTACHED_VOLUMES=$(cat <<'EOF'
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
arr-utilities_diun-data
arr-utilities_duc-index
arr-utilities_uptime-kuma-data
tailscale_tailscale-state
EOF
)
    # What RUNNING containers mount, same measurement. A strict subset of the above.
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
    local fn body
    # resolve_volume() delegates to two helpers; loading only the resolver would
    # make every test below die on "command not found" rather than assert anything.
    for fn in intersect_lines join_inline resolve_volume; do
        body=$(awk -v s="$fn() {" 'index($0, s) == 1, /^\}$/' "$BACKUP_SH")
        [[ -n "$body" ]] || {
            echo "could not extract $fn() from $BACKUP_SH -- was it renamed?"
            return 1
        }
        grep -qx '}' <<<"$body" || {
            echo "extraction of $fn() never reached a closing brace; got:"
            echo "$body"
            return 1
        }
        eval "$body"
    done
}

# Define the script's real docker_volume_inventory() in this shell, and put a stub
# `docker` first on PATH so its failure modes can be driven directly. Same
# extraction assertions as load_resolver() and for the same reason.
#
# $1 is the stub's body: a bash case/if over "$@" that plays whatever docker
# behaviour the test needs. It APPENDS its own argv to $STUB_LOG, so a test can
# assert what the helper actually asked docker, not just what came back.
load_inventory() {
    local body
    body=$(awk -v s="docker_volume_inventory() {" 'index($0, s) == 1, /^\}$/' "$BACKUP_SH")
    [[ -n "$body" ]] || {
        echo "could not extract docker_volume_inventory() from $BACKUP_SH -- renamed?"
        return 1
    }
    grep -qx '}' <<<"$body" || {
        echo "extraction of docker_volume_inventory() never reached a closing brace; got:"
        echo "$body"
        return 1
    }
    eval "$body"

    STUB_LOG="$BATS_TEST_TMPDIR/docker-calls"
    : > "$STUB_LOG"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    {
        echo '#!/usr/bin/env bash'
        echo 'printf "%s\n" "$*" >> "$STUB_LOG"'
        echo "$1"
    } > "$BATS_TEST_TMPDIR/bin/docker"
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export STUB_LOG
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

@test "resolve_volume breaks a two-prefix tie using a STOPPED container's volume" {
    # beszel-data exists twice: arr-stack_ (live) and arr-utilities_ (orphaned by
    # the project split). Backing up the orphan would produce a successful-looking
    # archive of an abandoned volume.
    #
    # Deliberately NOT using the measured inventory here. In every real collision
    # on this NAS the live volume also happens to sort first, so this assertion
    # would pass against a resolver that simply took the first candidate and
    # ignored the tie-break entirely -- proved by mutation, it did. The inventory
    # below is inverted so only a resolver actually consulting the tie-break sets
    # can get it right.
    #
    # MOUNTED_VOLUMES is EMPTY here on purpose: this is the 04:00 case. The live
    # container is stopped, so nothing is mounted, and a resolver that tie-breaks
    # on "what is running" has no answer -- it must either fail the backup or guess.
    # Tie-breaking on what a container REFERENCES is independent of uptime, which
    # is the property a backup actually needs.
    load_resolver
    ALL_VOLUMES=$(printf '%s\n' aa-orphan_beszel-data zz-live_beszel-data)
    ATTACHED_VOLUMES="zz-live_beszel-data"
    MOUNTED_VOLUMES=""

    resolve_volume beszel-data
    [ "$RESOLVED_VOLUME" = "zz-live_beszel-data" ] || {
        echo "expected zz-live_beszel-data (referenced by a stopped container),"
        echo "got '$RESOLVED_VOLUME' -- reason: '$RESOLVE_ERROR'"
        echo "(first-candidate-wins would return aa-orphan_beszel-data; a resolver"
        echo " tie-breaking only on running containers would fail outright)"
        return 1
    }
}

@test "resolve_volume falls back to the running container when both are attached" {
    # Tier 2. If two candidates are each referenced by a container that exists,
    # attachment cannot separate them and liveness is the next best signal.
    # Inverted fixture again, so first-candidate-wins cannot pass.
    load_resolver
    ALL_VOLUMES=$(printf '%s\n' aa-stopped_beszel-data zz-running_beszel-data)
    ATTACHED_VOLUMES=$(printf '%s\n' aa-stopped_beszel-data zz-running_beszel-data)
    MOUNTED_VOLUMES="zz-running_beszel-data"

    resolve_volume beszel-data
    [ "$RESOLVED_VOLUME" = "zz-running_beszel-data" ] || {
        echo "expected zz-running_beszel-data, got '$RESOLVED_VOLUME' (err: '$RESOLVE_ERROR')"
        return 1
    }
}

@test "resolve_volume never picks a volume no container references at all" {
    # The orphan case asserted directly, against the MEASURED inventory, rather
    # than inferred from a synthetic tie-break. arr-utilities_beszel-data is a
    # leftover of the project split: nothing references it running or stopped.
    # Restoring from it would look exactly like success.
    load_resolver
    MOUNTED_VOLUMES=""

    resolve_volume beszel-data
    [ "$RESOLVED_VOLUME" = "arr-stack_beszel-data" ] || {
        echo "expected arr-stack_beszel-data with nothing running, got '$RESOLVED_VOLUME'"
        echo "reason: '$RESOLVE_ERROR'"
        return 1
    }
}

@test "resolve_volume refuses to guess when a tie cannot be broken" {
    # Two candidates, each referenced by an existing container AND each running.
    # Neither tie-break separates them, so no signal is left. Picking one at random
    # is worse than failing: the archive would look complete.
    #
    # This used the measured configarr-repos pair until 2026-08-31. It no longer
    # can: arr-stack_configarr-repos is referenced by a stopped container and the
    # arr-utilities one by nothing, so the resolver now separates them correctly.
    # Keeping the old fixture would have left a test of a case that no longer
    # exists -- i.e. one that cannot fail.
    load_resolver
    ALL_VOLUMES=$(printf '%s\n' proj-a_configarr-repos proj-b_configarr-repos)
    ATTACHED_VOLUMES=$(printf '%s\n' proj-a_configarr-repos proj-b_configarr-repos)
    MOUNTED_VOLUMES=$(printf '%s\n' proj-a_configarr-repos proj-b_configarr-repos)

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
    ATTACHED_VOLUMES=""
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

@test "the Tailscale node state volume is in the curated list" {
    # docs/EXIT-NODE-PROJECT-LOG.md: recreating Tailscale node 1 severs every path
    # to the NAS at once -- SSH and the UGOS admin UI both ride its own subnet
    # route -- and must only be done with a state-volume backup. Dropping this
    # from the list re-arms that hazard silently, which is how it came to be
    # missing in the first place.
    local list
    list=$(curated_volumes)

    grep -qx "tailscale-state" <<<"$list" || {
        echo "'tailscale-state' is not backed up. docs/EXIT-NODE-PROJECT-LOG.md requires a"
        echo "state-volume backup before Tailscale node 1 is ever recreated."
        return 1
    }
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

@test "the manifest records a volume only when its copy succeeded" {
    # volume-manifest.tsv is how a restore learns which volume each directory came
    # from, so an entry is a claim that the directory is restorable. Written
    # unconditionally it would make that claim for a copy that FAILED -- a record
    # saying the backup worked when it did not, which is the failure shape this
    # whole file exists to catch. Line order is branch membership inside the
    # loop's if/else, so the write must sit above the copy-failure branch.
    local loop
    loop=$(awk '/^for suffix in "\$\{VOLUME_SUFFIXES\[@\]\}"; do$/,/^done$/' "$BACKUP_SH")
    [ -n "$loop" ] || {
        echo "could not extract the volume loop from $BACKUP_SH"
        return 1
    }

    local write fail_branch
    write=$(grep -n 'printf .*>> "\$MANIFEST"' <<<"$loop" | cut -d: -f1)
    fail_branch=$(grep -n 'echo "FAILED (permission denied' <<<"$loop" | cut -d: -f1)

    [ -n "$write" ] || {
        echo "the loop never writes a manifest entry -- a restore would have to guess"
        echo "which compose project each directory came from."
        return 1
    }
    [ "$(wc -l <<<"$write")" -eq 1 ] || {
        echo "expected exactly one manifest write in the loop, found:"
        echo "$write"
        return 1
    }
    [ -n "$fail_branch" ] || {
        echo "could not find the copy-failure branch; re-point this test at its new form"
        return 1
    }

    [ "$write" -lt "$fail_branch" ] || {
        echo "the manifest write (line $write of the loop) is not inside the copy-success"
        echo "branch -- it sits at or after the failure branch (line $fail_branch), so a"
        echo "volume whose copy failed still gets a restore entry."
        return 1
    }
}

@test "the manifest is created with a header before the loop runs" {
    grep -q "printf 'directory\\\\tsource_volume" "$BACKUP_SH" || {
        echo "no manifest header is written. Without it an empty manifest is"
        echo "indistinguishable from a missing one."
        return 1
    }
}

@test "an unresolvable request manager reports why, not just 'not found'" {
    # The request-manager pair is the one place a resolution failure is tolerated,
    # because only one of seerr/overseerr is ever deployed. That tolerance must not
    # extend to swallowing the REASON: "ambiguous" is a real fault and "absent" is
    # expected, and a single canned message cannot tell them apart. Had
    # uptime-kuma-data been optional rather than required, that flattening is
    # exactly what would have hidden the original regression.
    local block
    block=$(awk '/^if resolve_volume seerr-config; then$/,/^fi$/' "$BACKUP_SH")
    [ -n "$block" ] || {
        echo "could not extract the request-manager block from $BACKUP_SH"
        return 1
    }

    local code
    code=$(grep -vE '^[[:space:]]*#' <<<"$block")

    # Must be ECHOED, not merely mentioned. Grepping the block for RESOLVE_ERROR
    # passes on the `seerr_err="$RESOLVE_ERROR"` capture alone -- proved by
    # mutation: swapping the reporting lines for a canned "neither found" message
    # left that grep satisfied and this test green. The assertion has to name the
    # thing that reaches the operator.
    grep -qE 'echo .*\$(RESOLVE_ERROR|seerr_err)' <<<"$code" || {
        echo "the request-manager failure path never PRINTS the resolution reason, so"
        echo "an ambiguous resolution is indistinguishable from the volume being absent."
        echo "block was:"
        echo "$code"
        return 1
    }
}

@test "a run with failures exits non-zero" {
    # Until 2026-08-31 the script counted failures, printed a warning, and then
    # ended on an echo -- so $? was 0. Every machine reading the result (a cron
    # `&&` chain, a CI step, a wrapper checking status) saw a clean run over an
    # unprotected volume: the same lie the single-prefix bug told, one layer out
    # and at the layer machines actually read.
    local blk
    blk=$(awk '/^if \[ "\$FAILED" -gt 0 \]; then$/,/^fi$/' "$BACKUP_SH")
    [ -n "$blk" ] || {
        echo "no \$FAILED-gated exit block found in $BACKUP_SH"
        return 1
    }
    grep -qE '^[[:space:]]*exit 1$' <<<"$blk" || {
        echo "the \$FAILED-gated block does not exit non-zero:"
        echo "$blk"
        return 1
    }
}

@test "the non-zero exit runs after the tarball, so a partial backup is still archived" {
    # Placement is the whole point. Exiting the moment a volume failed would trade
    # a reporting bug for a data-loss one: every volume that DID resolve would go
    # unarchived. A partial backup that reports itself as partial is useful;
    # withholding the archive is not. A guard in the wrong place is not a guard.
    local tar_line exit_line
    tar_line=$(grep -n '^STEP="creating tarball"$' "$BACKUP_SH" | cut -d: -f1)
    exit_line=$(grep -n '^if \[ "\$FAILED" -gt 0 \]; then$' "$BACKUP_SH" | cut -d: -f1)
    [ -n "$tar_line" ] || { echo "could not find the tarball step"; return 1; }
    [ -n "$exit_line" ] || { echo "could not find the \$FAILED-gated exit"; return 1; }
    [ "$exit_line" -gt "$tar_line" ] || {
        echo "the failure exit (line $exit_line) precedes tarball creation (line $tar_line)"
        echo "-- a failed volume would suppress the archive of every volume that worked"
        return 1
    }
}

@test "two attached candidates with nothing running is ambiguous, not a guess" {
    # Exercises the empty-MOUNTED_VOLUMES path through the tier-2 intersect, which
    # no other test reaches: every other fixture either resolves at tier 1 or has
    # something running. Without it, intersect_lines' behaviour against an empty
    # set is asserted nowhere -- and "returns nothing" vs "returns everything" is
    # the difference between a refused backup and a silently wrong one.
    load_resolver
    ALL_VOLUMES=$(printf '%s\n' proj-a_beszel-data proj-b_beszel-data)
    ATTACHED_VOLUMES=$(printf '%s\n' proj-a_beszel-data proj-b_beszel-data)
    MOUNTED_VOLUMES=""

    run resolve_volume beszel-data
    [ "$status" -ne 0 ] || {
        echo "picked a candidate with no running-container signal to separate them"
        return 1
    }

    resolve_volume beszel-data || true
    [ -z "$RESOLVED_VOLUME" ] || {
        echo "RESOLVED_VOLUME set on a failed resolution: '$RESOLVED_VOLUME'"
        return 1
    }
}

@test "the ATTACHED inventory asks docker for stopped containers too" {
    # Was a static grep for `docker ps -a -q` until the inventory moved into a
    # function. It is now a real behavioural test: drive the helper with a stub
    # docker and assert what it actually asked for.
    #
    # A `docker ps` here instead of `docker ps -a` makes the whole backup's answer
    # depend on which containers happen to be up at 04:00 -- the defect this
    # resolver exists to remove.
    load_inventory 'case "$1 $2" in
      "ps -a") echo c1; echo c2 ;;
      "ps -q") echo c1 ;;
      *) echo vol-from-inspect ;;
    esac'

    docker_volume_inventory -a
    grep -q -- "^ps -a -q$" "$STUB_LOG" || {
        echo "helper did not ask docker for stopped containers. It ran:"
        cat "$STUB_LOG"
        return 1
    }
}

@test "a docker ps failure is an ERROR, not an empty inventory" {
    # The whole point of the guard. An empty ATTACHED_VOLUMES is read by
    # resolve_volume() as proof that every candidate is an orphan, so a docker
    # failure that returns empty makes multi-candidate volumes FAIL with
    # "no container references any of them" -- a specific, confident, wrong reason.
    load_inventory 'echo "Cannot connect to the Docker daemon" >&2; exit 1'

    run docker_volume_inventory -a
    [ "$status" -ne 0 ] || {
        echo "docker ps failed and the helper returned success"
        return 1
    }

    docker_volume_inventory -a || true
    [ -n "$INVENTORY_ERROR" ] || { echo "no INVENTORY_ERROR set on failure"; return 1; }
    [ -z "$INVENTORY_VOLUMES" ] || {
        echo "INVENTORY_VOLUMES set despite failure: '$INVENTORY_VOLUMES'"
        return 1
    }
}

@test "no containers at all is a legal empty inventory, not an error" {
    # The other half, and the reason the guard cannot just be "empty means broken":
    # asking successfully and being told "none" is a real state a fresh host is in.
    load_inventory 'exit 0'

    run docker_volume_inventory -a
    [ "$status" -eq 0 ] || {
        echo "an empty-but-successful docker ps was treated as a failure: $output"
        return 1
    }
}

@test "docker inspect failing on a vanished container is tolerated if others answered" {
    # A container can be removed between `ps` and `inspect`; docker then exits
    # non-zero having still reported on every other container. Failing the whole
    # backup for that would swap a silent-wrong-answer bug for a flaky-backup bug.
    load_inventory 'case "$1" in
      ps) echo c1; echo c2 ;;
      inspect) echo survivor-vol; echo "No such object: c2" >&2; exit 1 ;;
    esac'

    run docker_volume_inventory -a
    [ "$status" -eq 0 ] || { echo "a partial inspect was treated as fatal: $output"; return 1; }

    docker_volume_inventory -a
    [ "$INVENTORY_VOLUMES" = "survivor-vol" ] || {
        echo "expected the surviving container's volume, got '$INVENTORY_VOLUMES'"
        return 1
    }
}

@test "docker inspect failing with NO output is an error" {
    # The boundary of the tolerance above. Nothing came back at all, so the
    # question itself failed and there is no inventory to reason from.
    load_inventory 'case "$1" in
      ps) echo c1 ;;
      inspect) echo "permission denied" >&2; exit 1 ;;
    esac'

    run docker_volume_inventory -a
    [ "$status" -ne 0 ] || {
        echo "a total inspect failure was treated as an empty inventory"
        return 1
    }
}

@test "both inventories are guarded, and the ATTACHED one asks for -a" {
    # Wiring, asserted statically and narrowly: the behaviour above is only worth
    # anything if the script actually routes through the guarded helper. A bare
    # assignment would restore the silent-empty path with every test still green.
    grep -qE '^if ! docker_volume_inventory -a; then' "$BACKUP_SH" || {
        echo "the ATTACHED inventory is not built through a guarded 'docker_volume_inventory -a'"
        grep -nE 'ATTACHED_VOLUMES=|docker_volume_inventory' "$BACKUP_SH" || true
        return 1
    }
    grep -qE '^if ! docker_volume_inventory; then' "$BACKUP_SH" || {
        echo "the MOUNTED inventory is not built through a guarded 'docker_volume_inventory'"
        return 1
    }
    grep -qE '^(ATTACHED|MOUNTED)_VOLUMES=\$\(docker ' "$BACKUP_SH" && {
        echo "an inventory is still assigned straight from a docker pipeline, bypassing the guard"
        return 1
    }

    # Each result must land in its OWN variable. Proved by mutation: swapping one
    # assignment for the other leaves both guards in place and every other test
    # green, while the tie-break silently reads an unset or duplicated inventory.
    grep -qx 'ATTACHED_VOLUMES="$INVENTORY_VOLUMES"' "$BACKUP_SH" || {
        echo "ATTACHED_VOLUMES is never assigned from the guarded inventory"
        return 1
    }
    grep -qx 'MOUNTED_VOLUMES="$INVENTORY_VOLUMES"' "$BACKUP_SH" || {
        echo "MOUNTED_VOLUMES is never assigned from the guarded inventory"
        return 1
    }
    return 0
}

@test "a failed inventory exits NON-ZERO, not just loudly" {
    # Proved by mutation: turning either guard's `exit 1` into `exit 0` survived
    # every other test in this file. The script would print ERROR, call
    # notify_failure, and then exit successfully -- a detected failure reported as
    # a clean run, which is the exact defect class this whole file exists to break.
    local blk n=0
    while IFS= read -r ln; do
        # NOT `awk 'NR>=s, /^fi$/'`: a range whose start condition stays true
        # re-opens on the line after it closes, so that form walks the whole rest
        # of the file and finds the NEXT guard's `exit 1`. Proved by mutation --
        # it passed against a first guard whose exit had been changed to 0.
        blk=$(awk -v s="$ln" 'NR>=s{print; if ($0 == "fi") exit}' "$BACKUP_SH")
        grep -qE '^[[:space:]]*exit 1$' <<<"$blk" || {
            echo "the inventory guard starting at line $ln does not exit non-zero:"
            echo "$blk"
            return 1
        }
        n=$((n + 1))
    done < <(grep -nE '^if ! docker_volume_inventory' "$BACKUP_SH" | cut -d: -f1)

    [ "$n" -eq 2 ] || {
        echo "expected 2 guarded inventory builds, found $n"
        return 1
    }
}

@test "containers with no named volumes give an empty inventory, not a crash" {
    # The function's contract is that empty-but-successful is legal. Proved by
    # mutation: flipping the `|| true` after `grep .` to `&& true` makes an
    # all-blank inspect result abort the script under `set -e` -- turning the
    # normal state of a host whose containers use only bind mounts into a failure.
    load_inventory 'case "$1" in
      ps) echo c1; echo c2 ;;
      inspect) echo ""; echo "" ;;
    esac'

    run docker_volume_inventory -a
    [ "$status" -eq 0 ] || {
        echo "volume-less containers were treated as a failure: $output"
        return 1
    }

    docker_volume_inventory -a
    [ -z "$INVENTORY_VOLUMES" ] || {
        echo "expected an empty inventory, got '$INVENTORY_VOLUMES'"
        return 1
    }
}

@test "intersect_lines matches WHOLE lines, so a substring name cannot false-match" {
    # Found by mutation testing (universalmutator), not by review: replacing
    # `grep -Fxq` with `grep -Fq` survived all 18 tests above. Nothing here proved
    # the -x was load-bearing, so the exact-match property was uncovered.
    #
    # It is load-bearing. Volume names nest: a candidate `old_seerr-config` is a
    # substring of an unrelated `xold_seerr-config-v2`. Without -x the orphan
    # matches a live volume it has nothing to do with, both candidates survive
    # tier 1, and a name that resolves cleanly today becomes ambiguous -- i.e. a
    # FAILED volume, silently, the moment someone creates a longer-named volume.
    load_resolver

    local cands=$'old_seerr-config\nnew_seerr-config'
    local attached=$'xold_seerr-config-v2\nnew_seerr-config'

    run intersect_lines "$cands" "$attached"
    [ "$output" = "new_seerr-config" ] || {
        echo "expected only the exactly-matching new_seerr-config, got:"
        echo "$output"
        echo "(a substring match would also return old_seerr-config)"
        return 1
    }
}
