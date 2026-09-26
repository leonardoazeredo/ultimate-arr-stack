#!/bin/bash
# Shared test helpers for BATS tests

# Resolve paths
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

# Load BATS helpers
load "$TEST_DIR/bats-support/load"
load "$TEST_DIR/bats-assert/load"

# --- GNU/BSD portability for fixtures -----------------------------------------
#
# The suite runs on Linux (CI, pi1) and on a macOS cold spare, and a fixture
# that spells a date or a mode the GNU way fails there before the code under
# test is reached. Each helper tries the GNU spelling first and checks the
# SHAPE of what came back before trusting it -- the `stat -f` trap in
# docs/TEST-HARDENING-LOG.md section 8 is why the ordering alone is not enough.

# epoch_fmt EPOCH +FORMAT -- format a Unix time. GNU `date -d @N`, BSD `date -r N`.
epoch_fmt() {
    local out
    out=$(date -d "@$1" "$2" 2>/dev/null) && [[ -n "$out" ]] && { printf '%s\n' "$out"; return 0; }
    out=$(date -r "$1" "$2" 2>/dev/null) && [[ -n "$out" ]] && { printf '%s\n' "$out"; return 0; }
    echo "epoch_fmt: this date(1) can format neither 'date -d @$1' nor 'date -r $1'" >&2
    return 1
}

# ago_fmt SECONDS +FORMAT -- the time SECONDS ago, formatted. Arithmetic on the
# epoch rather than `date -d 'N days ago'`, which BSD date does not parse.
ago_fmt() { epoch_fmt "$(( $(date +%s) - $1 ))" "$2"; }

# touch_ago SECONDS FILE -- set FILE's mtime to SECONDS ago. `touch -t` is the
# POSIX spelling both touches accept; `touch -d '25 hours ago'` is GNU-only.
touch_ago() {
    local stamp
    stamp=$(ago_fmt "$1" +%Y%m%d%H%M.%S) || return 1
    touch -t "$stamp" "$2"
}

# file_mode FILE -- permission bits in octal, e.g. 644. GNU `stat -c %a`, BSD
# `stat -f %Lp`. GNU accepts `-f` too (as --file-system) and prints a report,
# hence the shape check on each answer.
file_mode() {
    local m
    m=$(stat -c %a "$1" 2>/dev/null) && [[ "$m" =~ ^[0-7]+$ ]] && { printf '%s\n' "$m"; return 0; }
    m=$(stat -f %Lp "$1" 2>/dev/null) && [[ "$m" =~ ^[0-7]+$ ]] && { printf '%s\n' "$m"; return 0; }
    echo "file_mode: could not read the mode of $1" >&2
    return 1
}

# All compose files in the repo
get_compose_files() {
    local files=()
    for f in "$REPO_ROOT"/docker-compose*.yml; do
        [[ -f "$f" ]] && files+=("$f")
    done
    echo "${files[@]}"
}

# Extract all host ports from compose files (left side of "HOST:CONTAINER")
get_all_ports() {
    for f in $(get_compose_files); do
        grep -E '^\s+-\s*"?[0-9]+:[0-9]+"?\s*$' "$f" 2>/dev/null | \
            sed -E 's/^[[:space:]]*-[[:space:]]*"?([0-9]+):.*/\1/'
    done
}

# Extract all static IPs from compose files
get_all_ips() {
    for f in $(get_compose_files); do
        grep -oE 'ipv4_address:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$f" 2>/dev/null | \
            sed -E 's/ipv4_address:[[:space:]]*//'
    done
}

# Extract all image references from compose files
get_all_images() {
    for f in $(get_compose_files); do
        grep -E '^[[:space:]]+image:[[:space:]]' "$f" 2>/dev/null | \
            sed -E 's/^[[:space:]]+image:[[:space:]]*//'
    done
}

# Extract image references for services that are actually pulled from a
# registry — excludes services with a sibling `build:` directive, whose
# `image:` line is just a local tag name (e.g. magnetio-addon:local), not a
# real registry reference. Those can't be "pinned" or checked for existence
# against a registry the same way. Optional $1 restricts to a single file;
# defaults to every compose file.
get_pulled_images() {
    local files
    if [[ -n "${1:-}" ]]; then
        files="$1"
    else
        files=$(get_compose_files)
    fi
    for f in $files; do
        awk '
            /^  [a-zA-Z0-9_.-]+:[[:space:]]*$/ {
                if (svc != "" && !built) print img
                svc=$0; img=""; built=0; next
            }
            /^[[:space:]]+build:/ { built=1 }
            /^[[:space:]]+image:[[:space:]]/ {
                sub(/^[[:space:]]+image:[[:space:]]*/, "")
                img=$0
            }
            END { if (svc != "" && !built) print img }
        ' "$f"
    done
}
