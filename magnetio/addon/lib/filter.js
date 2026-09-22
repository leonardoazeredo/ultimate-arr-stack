import { extractQuality } from './sort.js';
import { Quality } from './types.js';

const SIZE_LIMITS = {
  '1GB':   1  * 1024 ** 3,
  '2GB':   2  * 1024 ** 3,
  '3GB':   3  * 1024 ** 3,
  '5GB':   5  * 1024 ** 3,
  '10GB':  10 * 1024 ** 3,
  '20GB':  20 * 1024 ** 3,
  '50GB':  50 * 1024 ** 3,
};

/**
 * Apply user-configured filters to a sorted stream list.
 *
 * Filters applied (in order):
 *  1. Quality whitelist (if configured)
 *  2. Language whitelist (if configured)
 *  3. Exclude specific size buckets
 *  4. Maximum absolute size cap
 *  5. Limit total stream count
 */
export function applyFilters(streams, config) {
  let result = streams;

  // 1. Quality whitelist. `extractQuality` never returns null -- an unreadable
  // title comes back as `Quality.UNKNOWN` -- so the "null/unknown always passes
  // through" this comment used to claim described the opposite of what the code
  // did. The strict behaviour is the wanted one: a title carrying no resolution
  // is not evidence of a good release, and every tokenless record measured for
  // tt19231492:2:3 was an XviD or HDTV rip. `unknown` has to be named in the
  // whitelist to be allowed, and is therefore a deliberate choice rather than
  // something that slips past.
  if (config.qualities?.length) {
    result = result.filter(s => config.qualities.includes(extractQuality(s)));
  }

  // 2. Language whitelist. A multi-audio release is not a language: it carries
  // several tracks, so a whitelist of concrete languages has nothing to compare
  // it against and used to discard it. Excluding these is what emptied the list
  // for titles whose good releases are tagged MULTI, DUAL or GERMAN.DL --
  // measured on this stack: `records=10 filtered=0` for one episode.
  if (config.languages?.length) {
    result = result.filter(s =>
      (s.languages ?? []).some(l => l === 'multi' || config.languages.includes(l))
    );
  }

  // 3. Excluded size buckets (e.g. ['1GB', '2GB'])
  if (config.excludeSizes?.length) {
    result = result.filter(s => {
      for (const label of config.excludeSizes) {
        const cap = SIZE_LIMITS[label.toUpperCase()];
        if (cap && s.size && s.size <= cap) return false;
      }
      return true;
    });
  }

  // 4. Absolute max size cap (in bytes)
  if (config.maxSize) {
    result = result.filter(s => !s.size || s.size <= config.maxSize);
  }

  // 5. Limit count
  const limit = config.limit ?? 10;
  return result.slice(0, limit * 5); // fetch extra; moch layer will trim further
}
