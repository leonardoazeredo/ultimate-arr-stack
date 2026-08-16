import axios from 'axios';
import Bottleneck from 'bottleneck';

// Default browser-like headers to avoid basic bot detection
const DEFAULT_HEADERS = {
  'User-Agent':
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'Accept-Language': 'en-US,en;q=0.9',
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
};

const limiters = new Map();

function getLimiter(key, opts = { minTime: 250, maxConcurrent: 4 }) {
  if (!limiters.has(key)) {
    limiters.set(key, new Bottleneck(opts));
  }
  return limiters.get(key);
}

/**
 * Throttled GET with retries and browser-like headers.
 *
 * @param {string}  url
 * @param {object}  opts
 * @param {string}  opts.limiterKey    Rate-limiter bucket (e.g. provider name)
 * @param {object}  opts.params        Query params
 * @param {object}  opts.headers       Extra headers
 * @param {number}  opts.timeout       Request timeout ms (default 12000)
 * @param {string}  opts.responseType  axios responseType (default 'text')
 * @param {number}  opts.retries       Retry count on 5xx / network error (default 2)
 */
export async function get(url, {
  limiterKey = 'default',
  params = {},
  headers = {},
  timeout = 12000,
  responseType = 'text',
  retries = 2,
} = {}) {
  const limiter = getLimiter(limiterKey);

  return limiter.schedule(async () => {
    let lastErr;
    for (let attempt = 0; attempt <= retries; attempt++) {
      try {
        const res = await axios.get(url, {
          params,
          headers: { ...DEFAULT_HEADERS, ...headers },
          timeout,
          responseType,
        });
        return res;
      } catch (err) {
        lastErr = err;
        const status = err.response?.status;
        // Don't retry on client errors (4xx)
        if (status && status < 500) throw err;
        if (attempt < retries) await sleep(1000 * (attempt + 1));
      }
    }
    throw lastErr;
  });
}

const FLARESOLVERR_URL = process.env.FLARESOLVERR_URL;

// Single shared limiter (maxConcurrent: 1) across every caller regardless of
// limiterKey - FlareSolverr is one headless-Chrome instance shared with
// Prowlarr, so requests must be serialized, not parallelized per-provider.
const flareSolverrLimiter = new Bottleneck({ minTime: 500, maxConcurrent: 1 });

/**
 * GET a Cloudflare-protected page via FlareSolverr's headless-browser proxy.
 * Much slower than a plain GET (page render, several seconds+) - only use
 * this for providers that a plain axios GET can't reach at all.
 *
 * @param {string}  url
 * @param {number}  opts.timeout  FlareSolverr render timeout ms (default 30000)
 */
export async function getViaFlareSolverr(url, { timeout = 30000 } = {}) {
  if (!FLARESOLVERR_URL) throw new Error('FLARESOLVERR_URL not configured');

  return flareSolverrLimiter.schedule(async () => {
    const res = await axios.post(`${FLARESOLVERR_URL}/v1`, {
      cmd: 'request.get',
      url,
      maxTimeout: timeout,
    }, { timeout: timeout + 10_000 });

    if (res.data.status !== 'ok') {
      throw new Error(`FlareSolverr: ${res.data.message ?? 'unknown error'}`);
    }
    return { data: res.data.solution.response };
  });
}

function sleep(ms) {
  return new Promise(r => setTimeout(r, ms));
}
