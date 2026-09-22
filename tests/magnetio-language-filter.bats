#!/usr/bin/env bats
# magnetio/scraper/lib/titleHelper.js + magnetio/addon/lib/filter.js
#
# The language whitelist exists to drop releases whose audio a viewer cannot
# use. It kept dropping ones they can, because the only thing it knew about a
# release was which language names appeared in its title, and two whole classes
# of release carry no usable language name:
#
#   * dual/multi-audio releases. `MULTI`, `DUAL` and the scene's `GERMAN.DL`
#     all mean "more than one audio track", and `MULTI` was being collected as
#     a language *code* that can never equal `en` or `pt`. Measured on this
#     stack 2026-09-22: `Dark.Matter.Der.Zeitenlaeufer.S02E03.GERMAN.DL.1080P
#     .WEB.H264` is German + English dual audio and the viewer's `en,es,pt`
#     whitelist discarded it.
#   * `WEB-DL`, which contains the letters `DL`. A bare `\bdl\b` marker would
#     read every WEB-DL release as dual-language, including genuinely
#     single-language ones, so the source tag has to be stripped before the
#     marker is looked for. Without that the fix trades one wrong answer for a
#     worse one.
#
# Node drives the real modules rather than reading them, so a rewrite that keeps
# the names but changes the behaviour still fails. Both modules are
# dependency-free on purpose -- that is what makes this possible in a bare
# checkout, where neither package's node_modules is vendored. Where node is
# missing the tests skip with a reason rather than passing quietly.

setup() {
    load helpers/setup
    TITLE_JS="$REPO_ROOT/magnetio/scraper/lib/titleHelper.js"
    FILTER_JS="$REPO_ROOT/magnetio/addon/lib/filter.js"
    # `echo "$output" | wc -l` reports 1 for empty output, which is how four
    # tests in this repo were once merged as coverage while being incapable of
    # failing. Every count below goes through here instead.
    KEPT_COUNT=0
}

require_node() {
    command -v node >/dev/null 2>&1 || skip "no node on this host - these modules are ES modules and need one to be driven"
    # Not a skip. magnetio/ is tracked in this repo, not a submodule and not
    # vendored, so a missing file here is a rename or a deletion and the tests
    # named after it should say so rather than quietly skipping.
    [ -f "$TITLE_JS" ]  || { echo "missing $TITLE_JS"; false; }
    [ -f "$FILTER_JS" ] || { echo "missing $FILTER_JS"; false; }
}

# $1 = whitelisted languages, $2 = whitelisted qualities, $3 = JSON array of titles.
# Sets KEPT_COUNT to the number of survivors, so a test can assert on a count
# without the empty-output trap above.
run_filter() {
    local out
    out=$(node --input-type=module -e "
        import { parseTitle } from '$TITLE_JS';
        import { applyFilters } from '$FILTER_JS';
        const [langs, quals, titlesJson] = process.argv.slice(1);
        const config = {
            languages: langs.split(',').filter(Boolean),
            qualities: quals.split(',').filter(Boolean),
        };
        // parseTitle first, then the stream shape the addon builds from it, so
        // this exercises the real hand-off between the two modules.
        const records = JSON.parse(titlesJson).map(t => ({
            title: t, name: t, seeders: 10, size: 2e9, ...parseTitle(t),
        }));
        for (const r of applyFilters(records, config)) console.log(r.title);
    " "$1" "$2" "$3")
    local status=$?
    if [ "$status" -ne 0 ]; then
        echo "$out"
        return "$status"
    fi
    KEPT=$(printf '%s' "$out")
    if [ -z "$KEPT" ]; then
        KEPT_COUNT=0
    else
        KEPT_COUNT=$(printf '%s\n' "$KEPT" | grep -c .)
    fi
}

# $1 = JSON array of titles. Sets DETECTED to the "<title> -> <languages>" lines.
run_detect() {
    local out
    out=$(node --input-type=module -e "
        import { parseTitle } from '$TITLE_JS';
        for (const t of JSON.parse(process.argv[1])) {
            console.log(t + ' -> ' + JSON.stringify(parseTitle(t).languages));
        }
    " "$1")
    local status=$?
    [ "$status" -eq 0 ] || { echo "$out"; return "$status"; }
    DETECTED="$out"
}

@test "magnetio languages: a German dual-language release still reaches an en/es/pt whitelist" {
    require_node
    # The scene's DL means dual audio (German + the original), not "German only".
    # This is the release the library actually holds for the episode in question.
    run_filter "en,es,pt" "4k,1080p" \
        '["Dark.Matter.Der.Zeitenlaeufer.S02E03.GERMAN.DL.1080P.WEB.H264-WAYNE"]'
    [ "$KEPT_COUNT" -eq 1 ]
}

@test "magnetio languages: a WEB-DL source tag is not read as a dual-language tag" {
    require_node
    # The whole reason the source tag is stripped before the marker is looked
    # for. A Spanish-only WEB-DL release must not ride a `\bdl\b` match into an
    # English/Portuguese whitelist -- that is a worse failure than the one the
    # dual-language fix addresses, because it is invisible: the viewer gets a
    # stream, in the wrong language.
    run_detect '["Pelicula.2024.SPANISH.WEB-DL.1080p"]'
    [[ "$DETECTED" != *'"multi"'* ]]

    run_filter "en,pt" "4k,1080p" '["Pelicula.2024.SPANISH.WEB-DL.1080p"]'
    [ "$KEPT_COUNT" -eq 0 ]
}

@test "magnetio languages: a MULTI release satisfies the language whitelist" {
    require_node
    # `multi` is in the language list already, as a display label for
    # Multi-Audio. A whitelist of concrete languages can never contain it, so
    # every MULTI release was excluded by construction.
    run_filter "en,es,pt" "4k,1080p" '["Some.Show.S01E01.MULTI.1080p.WEB-DL.x264-GRP"]'
    [ "$KEPT_COUNT" -eq 1 ]
}

@test "magnetio languages: a DUAL release satisfies the language whitelist" {
    require_node
    run_filter "en,es,pt" "4k,1080p" '["Some.Show.S01E01.GERMAN.DUAL.1080p.WEB.H264-GRP"]'
    [ "$KEPT_COUNT" -eq 1 ]
}

@test "magnetio languages: a single-language release is still excluded" {
    require_node
    # The exemption is narrow on purpose: a release that names one language it
    # does not share with the viewer is exactly what the whitelist is for, and
    # widening the dual-language rule into a blanket pass would lose this.
    run_filter "en,pt" "4k,1080p" '["Dark.Matter.S02E03.GERMAN.1080P.WEB.H264-WAYNE"]'
    [ "$KEPT_COUNT" -eq 0 ]
}

@test "magnetio quality: a 1080p release passes a 4k/1080p whitelist" {
    require_node
    run_filter "en,es,pt" "4k,1080p" '["Dark Matter 2024 S02E03 1080p HEVC x265-MeGusta"]'
    [ "$KEPT_COUNT" -eq 1 ]
}

@test "magnetio quality: 480p does not pass a 4k/1080p whitelist" {
    require_node
    run_filter "en,es,pt" "4k,1080p" '["Dark Matter 2024 S02E03 480p x264-mSD"]'
    [ "$KEPT_COUNT" -eq 0 ]
}

@test "magnetio quality: a title with no resolution token does not pass a 4k/1080p whitelist" {
    require_node
    # `extractQuality` never returns null, so the old comment claiming unknown
    # quality always passes described the opposite of what the code did. The
    # behaviour is the one the viewer wants and is now stated and pinned rather
    # than accidental: these are the XviD/HDTV rips that filled the list for
    # tt19231492:2:3, and none of them is a 1080p release.
    run_filter "en,es,pt" "4k,1080p" \
        '["Dark Matter 2024 S02E03 XviD-AFG","Dark.Matter.S02E03.HDTV.x264-KILLERS[ettv]","Dark.Matter.S02E03.WEB-DL.XviD-FUM[ettv]"]'
    [ "$KEPT_COUNT" -eq 0 ]
}

@test "magnetio quality: the real S02E03 scrape keeps the 1080p releases and drops the rest" {
    require_node
    # The measured shape of the failure: one 1080p HEVC among a pile of 480p and
    # tokenless XviD, and `records=10 filtered=0` because everything the scrape
    # returned came from the one provider fast enough to survive its early
    # return. Both halves have to hold -- the good releases survive the quality
    # filter, and the junk does not survive with them.
    run_filter "en,es,pt" "4k,1080p" \
        '["Dark Matter 2024 S02E03 480p x264-mSD","Dark Matter 2024 S02E03 XviD-AFG","Dark.Matter.S02E03.HDTV.x264-KILLERS[ettv]","Dark Matter 2024 S02E03 1080p HEVC x265-MeGusta","Dark Matter 2024 S02E03 1080p HEVC x265-MeGusta ELiTe"]'
    [ "$KEPT_COUNT" -eq 2 ]
    [[ "$KEPT" == *"1080p"* ]]
    [[ "$KEPT" != *"XviD"* ]]
    [[ "$KEPT" != *"480p"* ]]
}

@test "magnetio languages: an empty whitelist still returns everything" {
    require_node
    # `languages=` in the install URL parses to an empty array, which means "all
    # languages" -- the filter must not turn that into "no languages", which
    # would present as a title with no streams at all.
    run_filter "" "4k,1080p" \
        '["Dark.Matter.S02E03.GERMAN.1080P.WEB.H264-WAYNE","Some.Show.S01E01.MULTI.1080p.WEB-DL"]'
    [ "$KEPT_COUNT" -eq 2 ]
}
