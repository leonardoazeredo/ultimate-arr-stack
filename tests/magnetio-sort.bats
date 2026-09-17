#!/usr/bin/env bats
# magnetio/addon/lib/sort.js
#
# Magnetio's stream ordering is what decides which release a viewer sees first,
# and nothing else in this repo covers it: there is no JS test runner here, the
# e2e suite asserts on services rather than on this module, and the module has
# no observable output of its own.
#
# The `fhd-first` mode exists because upstream's ordering answers "which release
# is best?" and puts the largest resolution first, which is the wrong question
# for a client that has to start playing the thing. Measured on this stack: with
# `limit=5`, the default order returned five 4K releases and no 1080p at all --
# the tier that would have played immediately was sorted past the cut and never
# sent to Stremio.
#
# These tests drive the real module through node rather than reading it, so a
# rewrite that keeps the names but changes the behaviour still fails. Node is on
# ubuntu-latest for the actions themselves; where it is missing the tests skip
# with a reason rather than passing quietly.

setup() {
    load helpers/setup
    SORT_JS="$REPO_ROOT/magnetio/addon/lib/sort.js"
    ORDER_JS="$BATS_TEST_TMPDIR/order.mjs"
}

# Render the sorted order as one line per stream, so a failure shows the actual
# sequence rather than a diff of two objects.
sorted_order() {
    local sort_mode="$1"
    node --input-type=module -e "
        import { sortStreams } from '$SORT_JS';
        const mk = (q, seeders, size, title) => ({ quality: q, seeders, size, title, name: title, languages: ['en'] });
        const streams = [
            mk('4k',    120, 33e9, 'uhd-a'),
            mk('1080p',  60,  8e9, 'fhd-a'),
            mk('4k',    129, 25e9, 'uhd-b'),
            mk('1080p',  40,  6e9, 'fhd-b'),
        ];
        for (const s of sortStreams(streams, { sort: '$sort_mode', languages: ['en'] })) console.log(s.title);
    "
}

require_node() {
    command -v node >/dev/null 2>&1 || skip "no node on this host - sort.js is an ES module and needs one to be driven"
    [ -f "$SORT_JS" ] || skip "magnetio sort.js is not vendored here"
}

@test "magnetio sort: the default order still puts the largest resolution first" {
    require_node
    run sorted_order "qualityseeders"
    [ "$status" -eq 0 ]
    # Upstream's behaviour, and the reason the new mode is opt-in: this must not
    # change just because a preference was added alongside it.
    [ "$(echo "$output" | head -1)" = "uhd-b" ]
    [ "$(echo "$output" | head -2 | tail -1)" = "uhd-a" ]
}

@test "magnetio sort: fhd-first puts 1080p ahead of every 4K release" {
    require_node
    run sorted_order "fhd-first"
    [ "$status" -eq 0 ]
    local first_uhd last_fhd
    first_uhd=$(echo "$output" | grep -n '^uhd-' | head -1 | cut -d: -f1)
    last_fhd=$(echo "$output" | grep -n '^fhd-' | tail -1 | cut -d: -f1)
    [ -n "$first_uhd" ] && [ -n "$last_fhd" ]
    [ "$last_fhd" -lt "$first_uhd" ]
}

@test "magnetio sort: fhd-first still ranks the better 1080p release above the worse one" {
    require_node
    run sorted_order "fhd-first"
    [ "$status" -eq 0 ]
    # Both are 1080p and the tiebreak is seeders (60 vs 40), so the order within
    # the tier is not arbitrary -- a mode that merely moved the tier would pass
    # the test above while losing this.
    [ "$(echo "$output" | head -1)" = "fhd-a" ]
    [ "$(echo "$output" | head -2 | tail -1)" = "fhd-b" ]
}

@test "magnetio sort: an unknown sort value falls back rather than returning nothing" {
    require_node
    run sorted_order "no-such-mode"
    [ "$status" -eq 0 ]
    # config.sort is parsed with no validation, so any string a viewer types
    # reaches the switch. Returning an empty list there would present as a title
    # with no streams at all.
    [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 4 ]
}

@test "magnetio sort: fhd-first caps each tier, so the 4K releases are still sent" {
    require_node
    # The cap is the whole difference between "1080p first" and "1080p only".
    # The pool on this stack runs to roughly 29x 1080p against 5x 4K, so with a
    # plain ordering the 1080p group fills every slot the limit allows and the
    # 4K tier never reaches the client -- measured, `limit=20` gave 19x 1080p
    # and 1x 4K. Ordering fixes which comes first; only the cap makes the lower
    # tier visible at all.
    run node --input-type=module -e "
        import { sortStreams } from '$SORT_JS';
        const mk = (q, i) => ({ quality: q, seeders: 10, size: 5e9, title: q + '-' + i, name: q + '-' + i, languages: ['en'] });
        const streams = [
            ...Array.from({ length: 12 }, (_, i) => mk('1080p', i)),
            ...Array.from({ length: 6 },  (_, i) => mk('4k', i)),
        ];
        console.log(sortStreams(streams, { sort: 'fhd-first', languages: ['en'] }).map(s => s.quality).join(' '));
    "
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | tr ' ' '\n' | grep -c '^1080p$')" -eq 5 ]
    [ "$(echo "$output" | tr ' ' '\n' | grep -c '^4k$')" -eq 5 ]
    # Position, not just presence: every 1080p must precede every 4K.
    local first_uhd
    first_uhd=$(echo "$output" | tr ' ' '\n' | grep -n '^4k$' | head -1 | cut -d: -f1)
    [ "$first_uhd" -eq 6 ]
}

@test "magnetio sort: the cap does not touch the default mode" {
    require_node
    # QUALITY_ORDER's call site passes no cap, so a default-mode list is still
    # every stream it was given. A cap leaking into the shared helper would
    # silently drop streams for everyone not using fhd-first.
    run node --input-type=module -e "
        import { sortStreams } from '$SORT_JS';
        const mk = (q, i) => ({ quality: q, seeders: 10, size: 5e9, title: q + '-' + i, name: q + '-' + i, languages: ['en'] });
        const streams = [
            ...Array.from({ length: 12 }, (_, i) => mk('1080p', i)),
            ...Array.from({ length: 6 },  (_, i) => mk('4k', i)),
        ];
        console.log(sortStreams(streams, { sort: 'qualityseeders', languages: ['en'] }).length);
    "
    [ "$status" -eq 0 ]
    [ "$output" -eq 18 ]
}

@test "magnetio sort: every SortType the config offers has a case in the switch" {
    require_node
    # A mode added to types.js and exposed in the dropdown but never handled in
    # sort.js is invisible rather than broken: the switch falls through to the
    # default and the mode quietly behaves like qualityseeders. That is the
    # failure this pins -- not that a mode exists, but that it is reachable.
    local missing=""
    for name in $(sed -n '/export const SortType = {/,/^};/p' "$REPO_ROOT/magnetio/addon/lib/types.js" \
                  | grep -oE '^\s+[A-Z_]+:' | tr -d ' :'); do
        # The values that are NOT sort modes live in the Quality enum, which has
        # its own block, so anything in this range is a sort mode by construction.
        grep -qE "case SortType\.${name}:" "$SORT_JS" || missing="$missing $name"
    done
    [ -z "$missing" ] || { echo "SortType entries with no case in sort.js:$missing"; false; }
}
