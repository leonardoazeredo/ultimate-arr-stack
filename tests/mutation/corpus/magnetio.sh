# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for magnetio/scraper/lib/scrapeBudget.js, the language half of
# magnetio/scraper/lib/titleHelper.js, and the filter that consumes both.
#
# Safe to run: every test named here drives a dependency-free module through
# node and touches no network, so a mutation cannot reach a torrent site.
#
# `perl -pi -e` rather than `sed -i` throughout, per the README: GNU sed treats
# -i as an in-place flag and BSD sed reads the next argument as a backup suffix,
# so a `sed -i` entry silently changes nothing on macOS -- which is where these
# were written, and "the mutation changed NOTHING" is the only thing that
# catches it.
#
# Both bugs these guard were silent. The early return ended a scrape on a sample
# and returned a plausible-looking list; the language whitelist discarded
# releases without saying so. Nothing failed, nothing logged an error, and the
# only symptom was a viewer with fewer streams than they should have had.

# --- The early return -------------------------------------------------------
#
# Recorded incident, 2026-09-22, tt19231492:2:3:
#   Early return: 10 results from 11/17 providers after 3000ms
# One fast provider with ten 480p/xvid releases was enough to end a scrape while
# the providers holding the episode's 1080p releases were still queued.

mutation magnetio-early-return-ignores-coverage \
  --file magnetio/scraper/lib/scrapeBudget.js \
  --bats tests/magnetio-scrape-budget.bats \
  --test "magnetio scrape budget: the recorded early-return sample is refused" \
  --why "drops the coverage half of the gate, which is the half that fixes the recorded incident: the result count was already satisfied when the scrape ended at 11 of 17 providers, so a gate that only counts results reproduces the exact failure the module exists to prevent" \
  --apply 'perl -pi -e "s#\Qreturn completed / total >= minEarlyCoverage;\E#return true;#" "$F"'

mutation magnetio-early-return-ignores-results \
  --file magnetio/scraper/lib/scrapeBudget.js \
  --bats tests/magnetio-scrape-budget.bats \
  --test "magnetio scrape budget: coverage alone does not end a scrape with nothing to show" \
  --why "drops the result half, so a scrape where every provider answered with nothing returns immediately on full coverage; that is the 'nobody has this title' path, and ending it early hides it behind a different code path from the one the hard timeout takes" \
  --apply 'perl -pi -e "s#\Qif (!(results >= minEarlyResults)) return false;\E#if (false) return false;#" "$F"'

mutation magnetio-provider-concurrency-starves-the-queue \
  --file magnetio/scraper/lib/scrapeBudget.js \
  --bats tests/magnetio-scrape-budget.bats \
  --test "magnetio scrape budget: every provider gets a slot, so none is starved behind the queue" \
  --why "restores the fixed 12-slot default that starved ten of 22 providers; those providers do not merely answer late, they never start before the hard timeout, so the tail of the provider list contributes nothing at all" \
  --apply 'perl -pi -e "s#\Q, count),\E#, 12),#" "$F"'

mutation magnetio-hard-timeout-below-provider-timeout \
  --file magnetio/scraper/lib/scrapeBudget.js \
  --bats tests/magnetio-scrape-budget.bats \
  --test "magnetio scrape budget: the hard timeout stays behind the per-provider timeout" \
  --why "removes the grace above the provider timeout, so the aggregate cancels providers that are still inside their own budget; a provider killed at its own deadline has done all its work for nothing, which is the same missing-results failure one layer down" \
  --apply 'perl -pi -e "s#\QproviderTimeoutMs + SCRAPE_BUDGET_DEFAULTS.hardTimeoutGraceMs,\E#providerTimeoutMs,#" "$F"'

# --- The language whitelist -------------------------------------------------
#
# A dual-audio release carries audio the viewer can use. The whitelist threw
# them away because `MULTI` was collected as a language code that can never
# equal `en`, and `DL` was not recognised at all.

mutation magnetio-webdl-read-as-dual-language \
  --file magnetio/scraper/lib/titleHelper.js \
  --bats tests/magnetio-language-filter.bats \
  --test "magnetio languages: a WEB-DL source tag is not read as a dual-language tag" \
  --why "removes the source-tag strip, so the DL marker matches the DL inside WEB-DL and every WEB-DL release claims a second audio track; that is worse than the bug it trades for, because a single-language release then passes an English/Portuguese whitelist and the viewer gets a stream in a language they cannot use with nothing on screen to say so" \
  --apply 'perl -pi -e "s#\Qconst langTitle = \E.*?;#const langTitle = title;#" "$F"'

mutation magnetio-dual-language-tag-not-detected \
  --file magnetio/scraper/lib/titleHelper.js \
  --bats tests/magnetio-language-filter.bats \
  --test "magnetio languages: a German dual-language release still reaches an en/es/pt whitelist" \
  --why "deletes the DL marker, so the scene's 'GERMAN.DL' reads as German-only; this is the release the library actually holds for the episode under investigation, and it was discarded by an en/es/pt whitelist for exactly this reason" \
  --apply 'perl -ni -e "print unless /\Q\bdl\E/i" "$F"'

mutation magnetio-multi-audio-no-longer-satisfies-whitelist \
  --file magnetio/addon/lib/filter.js \
  --bats tests/magnetio-language-filter.bats \
  --test "magnetio languages: a MULTI release satisfies the language whitelist" \
  --why "restores the plain containment check, so a whitelist of concrete languages has nothing to match against 'multi' and every MULTI release is excluded by construction - which is how a multi-audio release, the most likely kind to carry the viewer's language, became the least likely to be shown" \
  --apply 'perl -pi -e "s#\Qsome(l => \E.*?\Qconfig.languages.includes(l))\E#some(l => config.languages.includes(l))#" "$F"'

mutation magnetio-unknown-quality-dressed-as-1080p \
  --file magnetio/addon/lib/sort.js \
  --bats tests/magnetio-language-filter.bats \
  --test "magnetio quality: a title with no resolution token does not pass a 4k/1080p whitelist" \
  --why "reports an unreadable title as 1080p instead of unknown, which is what letting unknown quality through a whitelist amounts to in practice: the tokenless records measured for tt19231492:2:3 were XviD and HDTV rips, so a 4k/1080p viewer gets a list dominated by releases they did not ask for while every count looks healthy" \
  --apply 'perl -pi -e "s#\Qreturn Quality.UNKNOWN;\E#return Quality.FHD;#" "$F"'
