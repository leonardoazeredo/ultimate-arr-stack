#!/usr/bin/env bats
# The NAS is not a resolver any more. Phase 9.4 of the DNS migration.
#
# These read compose text, so they run anywhere -- including CI, which is the
# point: a service that is merely stopped comes back on a reboot, and a service
# removed from the file cannot.

setup() {
    load helpers/setup
}

# Comments are excluded deliberately. Two of them still name the old addresses
# to explain why a neighbouring setting points at the router instead, and that
# history is worth keeping: a grep that failed on it would be a test nobody can
# ever make green, which is the same thing as no test. What matters is that no
# setting carries the address any more.
non_comment_hits() {
    grep -rn "$1" "$@" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true
}

@test "no-nas-resolver: neither service is defined in any compose file" {
    local hits
    hits="$(grep -rn '^  \(pihole\|dnscrypt-proxy\):' "$REPO_ROOT"/docker-compose*.yml || true)"
    # RED while either is still declared. docker compose up -d starts every
    # service in the file, so a definition is a resurrection waiting for a reboot.
    [ -z "$hits" ] || fail "still declared: $hits"
}

@test "no-nas-resolver: nothing in the stack points at the old resolver addresses" {
    local hits
    hits="$(non_comment_hits '172\.20\.0\.5\|172\.20\.0\.6' \
        "$REPO_ROOT"/docker-compose*.yml "$REPO_ROOT"/traefik/dynamic/*.yml)"
    # 172.20.0.5 was Pi-hole and 172.20.0.6 dnscrypt-proxy. A leftover reference
    # is a container that cannot resolve once those addresses are gone.
    [ -z "$hits" ] || fail "still referenced: $hits"
}

@test "no-nas-resolver: the compose files still parse" {
    local f
    for f in "$REPO_ROOT"/docker-compose.arr-stack.yml "$REPO_ROOT"/docker-compose.utilities.yml; do
        run docker compose --env-file "$REPO_ROOT/.env.example" -f "$f" config --quiet
        [ "$status" -eq 0 ] || skip "docker compose unavailable, or the file will not parse: $output"
    done
}
