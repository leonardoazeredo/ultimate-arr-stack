#!/usr/bin/env bats
# magnetio/scraper/lib/scrapeBudget.js
#
# The scraper fans out over ~22 torrent providers, most of which have to fetch
# a detail page per result. Two independent defaults conspired to throw away the
# providers that hold the good releases, and neither is visible from the outside
# because the scrape returns a plausible-looking list either way.
#
# Measured on this stack 2026-09-22, `tt19231492:2:3` (Dark Matter 2024 S02E03):
#
#     Early return: 10 results from 11/17 providers after 3000ms
#     Scrape totals: 10 raw, 11/17 providers responded
#
# Eleven providers had answered with nothing. One -- ThePirateBay -- had
# returned ten 480p/xvid releases, which was enough for the result-count gate.
# The other six had not been given a slot yet, because the default concurrency
# of 12 is below the provider count, so the one provider holding the episode's
# 1080p releases was still queued when the scrape ended. The addon's
# `qualities=4k,1080p` whitelist then emptied the list: `records=10 filtered=0`.
#
# The policy is a dependency-free module precisely so it can be driven here:
# `providers/index.js` imports every scraper, which pulls in axios and cheerio,
# and neither package is vendored in this checkout. Node drives the real module;
# where node is missing the tests skip with a reason rather than passing quietly.

setup() {
    load helpers/setup
    BUDGET_JS="$REPO_ROOT/magnetio/scraper/lib/scrapeBudget.js"
}

require_node() {
    command -v node >/dev/null 2>&1 || skip "no node on this host - scrapeBudget.js is an ES module and needs one to be driven"
    # Not a skip. magnetio/ is tracked in this repo, not a submodule and not
    # vendored, so a missing file here is a rename or a deletion and the tests
    # named after it should say so rather than quietly skipping.
    [ -f "$BUDGET_JS" ] || { echo "missing $BUDGET_JS"; false; }
}

# $1 = field to print. Every case runs against a budget of 22 providers -- the
# real provider count -- and against the recorded early-return sample, so a
# failure below is a statement about the measured incident rather than an
# invented one.
probe_field() {
    node --input-type=module -e "
        import { resolveScrapeBudget, shouldReturnEarly } from '$BUDGET_JS';

        const budget = resolveScrapeBudget(22, {});
        const measured = { results: 10, completed: 11, total: 17 };
        const fields = {
            concurrency:     budget.concurrency,
            providerTimeout: budget.providerTimeoutMs,
            hardTimeout:     budget.hardTimeoutMs,
            measured:        shouldReturnEarly(measured, budget),
            covered:         shouldReturnEarly({ results: 40, completed: 16, total: 17 }, budget),
            resultsOnly:     shouldReturnEarly({ results: 500, completed: 2, total: 22 }, budget),
            coverageOnly:    shouldReturnEarly({ results: 0, completed: 22, total: 22 }, budget),
            envConcurrency:  resolveScrapeBudget(22, { SCRAPER_CONCURRENCY: '4' }).concurrency,
        };

        const want = process.argv[1];
        if (!(want in fields)) {
            console.error('no such field: ' + want);
            process.exit(1);
        }
        console.log(fields[want]);
    " "$1"
}

@test "magnetio scrape budget: every provider gets a slot, so none is starved behind the queue" {
    require_node
    # The starvation half. With 22 providers and 12 slots, ten wait for a slot;
    # the 15s provider timeout can consume the whole hard-timeout budget before
    # the tail of that queue is ever started, so those providers contribute
    # nothing at all rather than contributing late.
    run probe_field concurrency
    [ "$status" -eq 0 ]
    [ "$output" -eq 22 ]
}

@test "magnetio scrape budget: the recorded early-return sample is refused" {
    require_node
    # 10 results from 11/17 providers is the exact sample that emptied the list.
    # It must not be allowed to end a scrape.
    run probe_field measured
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
}

@test "magnetio scrape budget: an early return still fires once nearly every provider has answered" {
    require_node
    # The gate has to leave the latency optimisation alive, or the honest fix
    # would be to delete the feature. 16/17 providers and 40 results is the
    # state the early return is for.
    run probe_field covered
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "magnetio scrape budget: any amount of results is not enough without coverage" {
    require_node
    # One fast provider returning a hundred records must not end a 22-provider
    # scrape. This is the half that fixes the bug; the result count was already
    # satisfied in the recorded sample.
    run probe_field resultsOnly
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
}

@test "magnetio scrape budget: coverage alone does not end a scrape with nothing to show" {
    require_node
    # Total coverage with zero results is what the hard timeout is for. An early
    # return there would be indistinguishable in cost from waiting, and it would
    # make the "nobody has this title" path look like a different code path.
    run probe_field coverageOnly
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
}

@test "magnetio scrape budget: an explicit concurrency override is honoured" {
    require_node
    # Hosts that cannot take 22 simultaneous scrapes need the escape hatch, and
    # it has to beat the provider-count default rather than be merged with it.
    run probe_field envConcurrency
    [ "$status" -eq 0 ]
    [ "$output" -eq 4 ]
}

@test "magnetio scrape budget: the hard timeout stays behind the per-provider timeout" {
    require_node
    # A hard timeout at or below the provider timeout cancels providers that were
    # still inside their own budget, which is the same missing-results failure
    # one layer down.
    local provider hard
    provider=$(probe_field providerTimeout)
    hard=$(probe_field hardTimeout)
    [ "$hard" -gt "$provider" ]
}
