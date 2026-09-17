import { SortType, Quality } from './types.js';

// Seeder thresholds
const HEALTHY_SEEDER_COUNT = 5;
const SEEDED_SEEDER_COUNT  = 1;

// Quality ordering (index 0 = best)
const QUALITY_ORDER = [
  Quality.UHD_8K,
  Quality.UHD_4K,
  Quality.FHD,
  Quality.HD,
  Quality.SD,
  Quality.CAM,
  Quality.UNKNOWN,
];

// The same tiers with 1080p ahead of the UHD ones, for `sort=fhd-first`.
//
// Upstream's ordering answers "which release is best?" and puts the largest
// resolution first. That is the wrong question for a client that has to start
// playing the thing: a 25 GB 4K remux is the slowest entry in the list to begin
// streaming, the least likely to direct-play on a phone, a laptop or a TV
// stick, and the most likely to need transcoding. Measured on this stack, the
// default order returned five 4K releases and no 1080p at all under a
// `limit=5` -- the tier that would have played immediately was sorted past the
// cut and never sent.
//
// So this order is "playable first": the HD tiers in descending resolution,
// then the UHD tiers, with the genuinely-bad tiers last as upstream has them.
// Opt-in, and the default above is untouched.
const QUALITY_ORDER_FHD_FIRST = [
  Quality.FHD,
  Quality.HD,
  Quality.SD,
  Quality.UHD_4K,
  Quality.UHD_8K,
  Quality.CAM,
  Quality.UNKNOWN,
];

/**
 * Sort streams by language preference first, then by the configured sort strategy.
 */
export function sortStreams(streams, config) {
  const preferredLangs = config?.languages ?? [];
  if (preferredLangs.length) {
    const preferred = streams.filter(s => hasLanguage(s, preferredLangs));
    const rest      = streams.filter(s => !hasLanguage(s, preferredLangs));
    return [..._sortStreams(preferred, config), ..._sortStreams(rest, config)];
  }
  return _sortStreams(streams, config);
}

// ─── Internal ─────────────────────────────────────────────────────────────────

function _sortStreams(streams, config) {
  const sort = config?.sort ?? SortType.QUALITY_THEN_SEEDERS;

  switch (sort) {
    case SortType.QUALITY_THEN_SIZE:
      return sortByQuality(streams, (a, b) => b.size - a.size);

    case SortType.SEEDERS:
      return sortBySeeders(streams);

    case SortType.SIZE:
      return [...streams].sort((a, b) => b.size - a.size);

    case SortType.FHD_FIRST:
      return sortByQuality(streams, (a, b) => b.seeders - a.seeders, QUALITY_ORDER_FHD_FIRST);

    case SortType.QUALITY_THEN_SEEDERS:
    default:
      return sortByQuality(streams, (a, b) => b.seeders - a.seeders);
  }
}

/**
 * Group by quality tier and sort within each tier by the given comparator.
 * Prioritises "healthy" streams (≥5 seeders) over merely "seeded" (≥1).
 */
function sortByQuality(streams, tiebreak, qualityOrder = QUALITY_ORDER) {
  const groups = new Map();
  for (const q of qualityOrder) groups.set(q, { healthy: [], seeded: [], unhealthy: [] });

  for (const s of streams) {
    const q     = extractQuality(s);
    const group = groups.get(q) ?? groups.get(Quality.UNKNOWN);
    if      (s.seeders >= HEALTHY_SEEDER_COUNT) group.healthy.push(s);
    else if (s.seeders >= SEEDED_SEEDER_COUNT)  group.seeded.push(s);
    else                                         group.unhealthy.push(s);
  }

  const result = [];
  for (const { healthy, seeded, unhealthy } of groups.values()) {
    result.push(
      ...healthy.sort(tiebreak),
      ...seeded.sort(tiebreak),
      ...unhealthy.sort(tiebreak),
    );
  }
  return result;
}

function sortBySeeders(streams) {
  return [...streams].sort((a, b) => {
    const aHealthy = a.seeders >= HEALTHY_SEEDER_COUNT;
    const bHealthy = b.seeders >= HEALTHY_SEEDER_COUNT;
    if (aHealthy !== bHealthy) return bHealthy ? 1 : -1;
    return b.seeders - a.seeders;
  });
}

/**
 * Derive the Quality tier from stream metadata.
 */
export function extractQuality(stream) {
  const info = [stream.quality, stream.resolution, stream.title, stream.name]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();

  if (/\b(cam|camrip|ts|telesync|telecine|hdcam)\b/.test(info)) return Quality.CAM;
  if (/\b(8k|7680)\b/.test(info))                                 return Quality.UHD_8K;
  if (/\b(4k|2160p|uhd)\b/.test(info))                            return Quality.UHD_4K;
  if (/\b(1080p|fhd|fullhd)\b/.test(info))                        return Quality.FHD;
  if (/\b(720p|hd)\b/.test(info))                                  return Quality.HD;
  if (/\b(480p|sd)\b/.test(info))                                  return Quality.SD;
  return Quality.UNKNOWN;
}

function hasLanguage(stream, langs) {
  return (stream.languages ?? []).some(l => langs.includes(l));
}
