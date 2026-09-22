/**
 * Scrape budget: how many providers may run at once, how long each may take,
 * and when a scrape may stop before all of them have answered.
 *
 * This lives apart from providers/index.js because that module imports every
 * scraper, which pulls in axios and cheerio -- nothing can import it in a bare
 * checkout, so a policy buried inside it cannot be driven by the bats suite.
 * Here it is plain JavaScript with no imports, and the suite exercises it
 * directly.
 *
 * Why the coverage gate exists. The early return used to be decided by a result
 * count alone. Measured on this stack 2026-09-22, `tt19231492:2:3`:
 *
 *     Early return: 10 results from 11/17 providers after 3000ms
 *     Scrape totals: 10 raw, 11/17 providers responded
 *
 * Eleven providers had answered with nothing and one -- ThePirateBay -- had
 * returned ten 480p/xvid releases, which was enough. Six more had not been given
 * a slot yet, because the default concurrency of 12 is below the provider count,
 * so the providers holding that episode's 1080p releases were still queued when
 * the scrape ended. The addon's `qualities=4k,1080p` whitelist then emptied the
 * list: `records=10 filtered=0`.
 *
 * So there were two defects pulling the same way, and fixing either one alone
 * still loses providers: enough slots to start everything, and a gate that waits
 * for nearly everything to answer.
 */

export const SCRAPE_BUDGET_DEFAULTS = {
  providerTimeoutMs: 15000,
  // The provider timeout bounds one provider; the hard timeout bounds the whole
  // scrape and has to sit above it, or a provider still inside its own budget is
  // cancelled by the aggregate.
  hardTimeoutGraceMs: 2000,
  earlyReturnMs: 3000,
  minEarlyResults: 3,
  // Nearly all, not most. The recorded failure had 11 of 17 answered -- 65% --
  // and every one of the six missing providers was a source of results rather
  // than a provider that had nothing.
  minEarlyCoverage: 0.9,
};

function intFromEnv(env, key, fallback) {
  const raw = env?.[key];
  if (raw === undefined || raw === null || raw === '') return fallback;
  const parsed = parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function ratioFromEnv(env, key, fallback) {
  const raw = env?.[key];
  if (raw === undefined || raw === null || raw === '') return fallback;
  const parsed = Number.parseFloat(raw);
  if (!Number.isFinite(parsed) || parsed <= 0 || parsed > 1) return fallback;
  return parsed;
}

/**
 * Resolve the budget for a scrape.
 *
 * @param {number} providerCount How many providers this scrape can ask. Also the
 *   concurrency default: the aggregate's stated job is to run every enabled
 *   scraper in parallel, and a slot count below the provider count makes that
 *   false for the tail of the list. Per-site pacing is not lost by raising this
 *   -- httpClient keeps a Bottleneck limiter per provider, so two requests to
 *   the same site are still 250ms apart.
 * @param {object} env Environment to read overrides from.
 */
export function resolveScrapeBudget(providerCount, env = process.env) {
  const count = Math.max(1, Math.trunc(Number(providerCount)) || 1);
  const providerTimeoutMs = intFromEnv(env, 'SCRAPER_PROVIDER_TIMEOUT_MS', SCRAPE_BUDGET_DEFAULTS.providerTimeoutMs);

  return {
    concurrency: intFromEnv(env, 'SCRAPER_CONCURRENCY', count),
    providerTimeoutMs,
    hardTimeoutMs: intFromEnv(
      env, 'SCRAPER_HARD_TIMEOUT_MS',
      providerTimeoutMs + SCRAPE_BUDGET_DEFAULTS.hardTimeoutGraceMs,
    ),
    earlyReturnMs: intFromEnv(env, 'SCRAPER_EARLY_RETURN_MS', SCRAPE_BUDGET_DEFAULTS.earlyReturnMs),
    minEarlyResults: intFromEnv(env, 'SCRAPER_MIN_EARLY_RESULTS', SCRAPE_BUDGET_DEFAULTS.minEarlyResults),
    minEarlyCoverage: ratioFromEnv(env, 'SCRAPER_EARLY_RETURN_MIN_COVERAGE', SCRAPE_BUDGET_DEFAULTS.minEarlyCoverage),
  };
}

/**
 * May this scrape stop before every provider has answered?
 *
 * Both halves are required. Enough results on its own is the defect above: one
 * fast, low-quality provider is enough to satisfy it, and the scrape ends while
 * better sources are still queued. Enough coverage on its own would end a scrape
 * that has nothing to show, which costs the same as waiting and hides the
 * "nobody has this title" path behind a different code path.
 *
 * The thresholds arrive as the budget object rather than as loose numbers, so
 * there is no second set of names to keep in step with resolveScrapeBudget --
 * an earlier version took `minResults` while the budget returned
 * `minEarlyResults`, and a caller spreading the budget got `undefined` and a
 * silent false.
 *
 * @param {object} state   { results, completed, total }: raw records collected,
 *                         providers that have answered, providers asked.
 * @param {object} budget  From resolveScrapeBudget.
 */
export function shouldReturnEarly({ results, completed, total }, budget = SCRAPE_BUDGET_DEFAULTS) {
  const { minEarlyResults, minEarlyCoverage } = budget;
  if (!(results >= minEarlyResults)) return false;
  return completed / total >= minEarlyCoverage;
}
