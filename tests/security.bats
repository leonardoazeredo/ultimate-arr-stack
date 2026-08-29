#!/usr/bin/env bats
# Security policy enforcement tests

setup() {
    load helpers/setup
}

@test "docker socket mounts are read-only" {
    for f in $(get_compose_files); do
        local fname
        fname=$(basename "$f")
        while IFS= read -r line; do
            if [[ "$line" == *"/var/run/docker.sock"* ]] && [[ "$line" != *":ro"* ]]; then
                fail "Docker socket in $fname is not mounted read-only: $line"
            fi
        done < <(grep 'docker.sock' "$f" 2>/dev/null)
    done
}

@test "no env_file directive on infrastructure containers" {
    for f in $(get_compose_files); do
        local fname
        fname=$(basename "$f")
        if grep -q 'env_file:' "$f" 2>/dev/null; then
            fail "Found env_file directive in $fname — use explicit environment vars instead"
        fi
    done
}

@test "no SYS_TIME capability" {
    for f in $(get_compose_files); do
        local fname
        fname=$(basename "$f")
        if grep -q 'SYS_TIME' "$f" 2>/dev/null; then
            fail "SYS_TIME capability found in $fname"
        fi
    done
}

@test "traefik has no-new-privileges" {
    local traefik_file="$REPO_ROOT/docker-compose.traefik.yml"
    [[ -f "$traefik_file" ]] || skip "traefik compose file not found"
    run grep 'no-new-privileges' "$traefik_file"
    assert_success
}

@test "no privileged: true in any compose file" {
    for f in $(get_compose_files); do
        local fname
        fname=$(basename "$f")
        if grep -qE '^\s+privileged:\s*true' "$f" 2>/dev/null; then
            fail "privileged: true found in $fname"
        fi
    done
}

@test "no :latest image tags" {
    for f in $(get_compose_files); do
        local fname
        fname=$(basename "$f")
        while IFS= read -r image; do
            [[ -z "$image" ]] && continue
            if [[ "$image" == *":latest"* ]]; then
                fail "Image '$image' in $fname uses :latest"
            fi
        done < <(get_pulled_images "$f")
    done
}

@test "gluetun does not receive all env vars via env_file" {
    local arr_file="$REPO_ROOT/docker-compose.arr-stack.yml"
    [[ -f "$arr_file" ]] || skip "arr-stack compose file not found"
    # Gluetun should use explicit environment vars, not env_file
    local gluetun_section
    gluetun_section=$(awk '/^  gluetun:/{found=1; next} found && /^  [a-zA-Z#]/{found=0} found' "$arr_file")
    if echo "$gluetun_section" | grep -q 'env_file:'; then
        fail "Gluetun uses env_file — should use explicit environment vars"
    fi
}

@test "jellyfin media mounts are read-only" {
    for f in $(get_compose_files); do
        local fname
        fname=$(basename "$f")
        # Look for jellyfin service media mounts
        local jellyfin_section
        jellyfin_section=$(awk '/^  jellyfin:/{found=1; next} found && /^  [a-zA-Z#]/{found=0} found' "$f" 2>/dev/null) || continue
        [[ -z "$jellyfin_section" ]] && continue
        while IFS= read -r line; do
            # Check media volume mounts (movies, tv) are :ro
            if [[ "$line" == *"/media/"* ]] && [[ "$line" != *":ro"* ]]; then
                fail "Jellyfin media mount in $fname is not read-only: $line"
            fi
        done <<< "$jellyfin_section"
    done
}

# Services that must NOT publish a host port. Each is either unauthenticated by
# design (FlareSolverr is a headless-browser proxy; duc browses the filesystem)
# or authenticated only behind Traefik, whose basic auth a published port
# bypasses entirely. All four were reachable unauthenticated from the personal
# VLAN until 2026-08-29; Traefik routes to their bridge IPs, so publishing buys
# nothing. Guarded here because nothing else in the suite asserts exposure.
@test "unauthenticated services publish no host port" {
    local -a forbidden=(
        '"8191:8191"'   # FlareSolverr  - SSRF/pivot primitive
        '"3000:3000"'   # Homepage      - leaks the service inventory
        '"8090:8090"'   # Beszel        - /api/collections/... answered 200
        '"8838:80"'     # duc           - filesystem-layout disclosure
    )
    for f in $(get_compose_files); do
        local fname
        fname=$(basename "$f")
        for pattern in "${forbidden[@]}"; do
            if grep -qE "^[[:space:]]*-[[:space:]]*${pattern}" "$f" 2>/dev/null; then
                fail "$fname republishes ${pattern} — this re-exposes an unauthenticated service on the LAN"
            fi
        done
    done
}
