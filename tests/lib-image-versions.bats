#!/usr/bin/env bats
# scripts/lib/check-image-versions.sh
#
# Warnings-only: it tells you a pinned image has a newer tag. Its value is
# entirely in being RIGHT, since nobody acts on a checker they have learned to
# distrust -- and it has two ways to be quietly wrong that no exit code shows.
#
# The first is the cache. _cache_get decides staleness with
#
#     $(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
#
# which reads as portable and is not. `-f` means "format" on BSD stat and
# `--file-system` on GNU -- where it is a VALID flag that prints a multi-line
# filesystem report to STDOUT and exits 1. Only stderr is suppressed. So on
# Linux the `||` fires, appends the real mtime to that report, and the
# arithmetic consuming it throws a syntax error; cache_age ends up empty, and
# `[[ "" -gt 86400 ]]` evaluates empty as 0. The 24-hour cache in /tmp never
# expires. Measured on this host, not inferred.
#
# The second is _find_latest's filtering, which decides what counts as "the
# same kind of version" as the current tag. It is right for the wrong-looking
# reasons often enough to deserve its cases spelled out.

setup() {
    load helpers/setup
    source "$REPO_ROOT/scripts/lib/common.sh"
    source "$REPO_ROOT/scripts/lib/check-image-versions.sh"
    # Reassign AFTER sourcing: the file sets these at source time, so a value
    # exported beforehand would be overwritten.
    _IMAGE_CACHE="$BATS_TEST_TMPDIR/cache"
    _CACHE_TTL=86400
}

# --- The cache, and why it never expired -----------------------------------

@test "image-versions: a missing cache file is a miss, not an error" {
    run _cache_get "some/image:1.0"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "image-versions: a fresh cache returns the stored tag" {
    printf 'some/image:1.0=2.0\n' > "$_IMAGE_CACHE"
    run _cache_get "some/image:1.0"
    [ "$status" -eq 0 ]
    [ "$output" = "2.0" ]
}

@test "image-versions: a cache older than the TTL is a miss and is deleted" {
    # The whole point of the file. Without a working mtime read this cache is
    # permanent, and a stale 'latest' is reported as fact until /tmp is cleared
    # -- silently, since a wrong answer and a right one look identical.
    printf 'some/image:1.0=2.0\n' > "$_IMAGE_CACHE"
    touch -d '25 hours ago' "$_IMAGE_CACHE"
    run _cache_get "some/image:1.0"
    [ "$status" -eq 1 ]
    [ ! -f "$_IMAGE_CACHE" ]
}

@test "image-versions: a cache just inside the TTL is still fresh" {
    # The other side of the boundary: over-eager expiry would make every commit
    # re-query 31 registries, which is how a check ends up disabled instead.
    printf 'some/image:1.0=2.0\n' > "$_IMAGE_CACHE"
    touch -d '23 hours ago' "$_IMAGE_CACHE"
    run _cache_get "some/image:1.0"
    [ "$status" -eq 0 ]
    [ "$output" = "2.0" ]
}

@test "image-versions: the mtime read yields a bare integer on this platform" {
    # Pins the actual defect rather than only its symptom. `stat -f` on GNU
    # succeeds at printing a filesystem report to stdout, so any implementation
    # that trusts stdout without checking the shape of it reintroduces this.
    run _file_mtime "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]] || { echo "not an integer: [$output]"; return 1; }
    [ "$output" -gt 1000000000 ]
}

@test "image-versions: a missing file reads as mtime 0, not as garbage" {
    run _file_mtime "$BATS_TEST_TMPDIR/definitely-absent"
    [ "$output" = "0" ]
}

@test "image-versions: storing a tag twice replaces rather than appends" {
    _cache_set "some/image:1.0" "2.0"
    _cache_set "some/image:1.0" "3.0"
    [ "$(grep -c '^some/image:1.0=' "$_IMAGE_CACHE")" -eq 1 ]
    run _cache_get "some/image:1.0"
    [ "$output" = "3.0" ]
}

@test "image-versions: rewriting one entry does not drop the others" {
    _cache_set "a/one:1" "9"
    _cache_set "b/two:1" "8"
    _cache_set "a/one:1" "10"
    run _cache_get "b/two:1"
    [ "$output" = "8" ]
}

# --- Version comparison -----------------------------------------------------

@test "image-versions: _is_newer is false for the same version" {
    run _is_newer "1.2.3" "1.2.3"
    [ "$status" -eq 1 ]
}

@test "image-versions: _is_newer is true only in the newer direction" {
    run _is_newer "1.2.3" "1.2.4"; [ "$status" -eq 0 ]
    run _is_newer "1.2.4" "1.2.3"; [ "$status" -eq 1 ]
}

@test "image-versions: _is_newer ignores a v prefix on either side" {
    run _is_newer "v1.2.3" "1.2.3"; [ "$status" -eq 1 ]
    run _is_newer "v1.2.3" "v1.2.4"; [ "$status" -eq 0 ]
}

@test "image-versions: _is_newer orders numerically, not lexically" {
    # The case a string compare gets wrong: "10" sorts before "9" as text.
    run _is_newer "1.9.0" "1.10.0"
    [ "$status" -eq 0 ]
}

@test "image-versions: _is_newer handles date-style versions" {
    run _is_newer "2026.7.3" "2026.8.3"
    [ "$status" -eq 0 ]
}

# --- Candidate filtering ----------------------------------------------------

@test "image-versions: _find_latest picks the highest newer candidate" {
    run _find_latest "1.2.3" <<< $'1.2.4\n1.2.9\n1.2.5'
    [ "$output" = "1.2.9" ]
}

@test "image-versions: _find_latest returns nothing when all are older" {
    run _find_latest "9.0.0" <<< $'1.2.4\n1.2.9'
    [ -z "$output" ]
}

@test "image-versions: a v-prefixed current tag only matches v-prefixed tags" {
    run _find_latest "v1.2.3" <<< $'1.9.9\nv1.2.4'
    [ "$output" = "v1.2.4" ]
}

@test "image-versions: a bare current tag only matches bare tags" {
    # Both directions matter: mixing the styles is how a checker starts
    # recommending a tag that does not exist under the name it printed.
    run _find_latest "1.2.3" <<< $'v9.9.9\n1.2.4'
    [ "$output" = "1.2.4" ]
}

@test "image-versions: candidates with a different segment depth are rejected" {
    # 'redis 7-alpine -> 8' style noise: a two-segment tag is not a candidate
    # for a three-segment pin, however much larger it sorts.
    run _find_latest "1.2.3" <<< $'9.9\n1.2.4'
    [ "$output" = "1.2.4" ]
}

@test "image-versions: non-numeric tags are rejected outright" {
    run _find_latest "1.2.3" <<< $'latest\nalpine\n1.2.4-rc1\n1.2.4'
    [ "$output" = "1.2.4" ]
}

@test "image-versions: an empty candidate list yields an empty answer" {
    run _find_latest "1.2.3" <<< ""
    [ -z "$output" ]
}
