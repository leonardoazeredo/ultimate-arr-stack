/**
 * 1337x provider -- scrapes search and detail pages via HTML.
 */
import * as cheerio from 'cheerio';
import { getViaFlareSolverr, createFlareSolverrSession, destroyFlareSolverrSession } from '../lib/httpClient.js';
import { parseTitle, buildSearchQuery } from '../lib/titleHelper.js';
import { tryDomains, PROVIDER_DOMAINS } from '../lib/domainRotation.js';
import { logger } from '../lib/logger.js';

const DOMAINS = PROVIDER_DOMAINS['1337x'];

// 1337x is Cloudflare-blocked at the network level (confirmed live
// 2026-08-16, flat 403 even via plain curl/wget) - every page, search and
// detail alike, has to go through FlareSolverr's shared headless browser.
// Capped at 5 detail-page fetches (not the site's full ~20-result page) to
// bound how much load one 1337x search puts on that shared instance, which
// Prowlarr also depends on. All fetches in one scrape() share a single
// FlareSolverr session so only the first request pays the ~30s
// challenge-solve cost - without this, each detail fetch re-solves from
// scratch (confirmed live 2026-08-16).
const MAX_DETAIL_FETCHES = 5;

export const id   = '1337x';
export const name = '1337x';
// index.js reads this to give 1337x specifically more room than the default
// 15s provider budget: one ~30s challenge-solve plus up to MAX_DETAIL_FETCHES
// session-reused (fast) detail fetches.
export const timeoutMs = 45_000;

export async function scrape(meta) {
  if (!meta?.name) return [];

  let session;
  try {
    session = await createFlareSolverrSession();

    const query = buildSearchQuery(meta);
    const cat   = meta.type === 'movie' ? 'Movies' : 'TV';

    const { data, base } = await tryDomains(DOMAINS, async (base) => {
      const url = `${base}/category-search/${encodeURIComponent(query)}/${cat}/1/`;
      const res = await getViaFlareSolverr(url, { session });
      return { data: res.data, base };
    }, '1337x');

    const $ = cheerio.load(data);

    const detailUrls = [];
    $('table.table-list tbody tr').each((_, row) => {
      const href = $(row).find('td.name a').last().attr('href');
      if (href) detailUrls.push(href.startsWith('http') ? href : `${base}${href}`);
    });

    const results = [];
    const batches = chunkArray(detailUrls.slice(0, MAX_DETAIL_FETCHES), 5);

    for (const batch of batches) {
      const settled = await Promise.allSettled(batch.map(u => fetchDetail(u, meta, session)));
      for (const r of settled) {
        if (r.status === 'fulfilled' && r.value) results.push(r.value);
      }
    }

    return results;
  } catch (err) {
    logger.warn(`[1337x] ${err.message}`);
    return [];
  } finally {
    if (session) destroyFlareSolverrSession(session);
  }
}

async function fetchDetail(url, meta, session) {
  try {
    const { data } = await getViaFlareSolverr(url, { session });
    const $ = cheerio.load(data);

    const magnet   = $('a[href^="magnet:"]').first().attr('href') ?? '';
    const infoHash = extractInfoHash(magnet);
    if (!infoHash) return null;

    const title    = $('div.box-info-heading h1').text().trim();
    const seeders  = parseInt($('span.seeds').first().text().trim(), 10) || 0;
    const leechers = parseInt($('span.leeches').first().text().trim(), 10) || 0;
    const sizeText = $('div.file-size').text().trim();
    const size     = parseSize(sizeText);

    return {
      infoHash,
      title: title || url.split('/').slice(-2, -1)[0] || '',
      seeders,
      leechers,
      size,
      provider: '1337x',
      imdbId:   meta.imdbId,
      ...parseTitle(title),
    };
  } catch {
    return null;
  }
}

function extractInfoHash(magnet) {
  const match = magnet.match(/xt=urn:btih:([a-fA-F0-9]{40}|[a-zA-Z2-7]{32})/i);
  return match ? match[1].toLowerCase() : null;
}

function parseSize(str) {
  if (!str) return 0;
  const m = str.match(/([\d.]+)\s*(B|KB|MB|GB|TB)/i);
  if (!m) return 0;
  const val   = parseFloat(m[1]);
  const units = { b: 1, kb: 1024, mb: 1024 ** 2, gb: 1024 ** 3, tb: 1024 ** 4 };
  return Math.round(val * (units[m[2].toLowerCase()] ?? 1));
}

function chunkArray(arr, size) {
  const chunks = [];
  for (let i = 0; i < arr.length; i += size) chunks.push(arr.slice(i, i + size));
  return chunks;
}
