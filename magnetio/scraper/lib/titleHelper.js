/**
 * Shared torrent title parsing utilities.
 * Extracts quality, codec, size, language hints from raw torrent names.
 */

const QUALITY_PATTERNS = [
  { re: /\b(8k|7680[xX]4320)\b/i,              quality: '8k'    },
  { re: /\b(2160p|4k|uhd)\b/i,                  quality: '4k'    },
  { re: /\b1080p\b/i,                            quality: '1080p' },
  { re: /\b720p\b/i,                             quality: '720p'  },
  { re: /\b480p\b/i,                             quality: '480p'  },
  { re: /\b(cam|camrip|ts|telesync|telecine|hdcam)\b/i, quality: 'cam' },
];

const CODEC_PATTERNS = [
  { re: /\b(x265|hevc|h\.?265)\b/i, codec: 'HEVC' },
  { re: /\b(x264|avc|h\.?264)\b/i,  codec: 'AVC'  },
  { re: /\bav1\b/i,                  codec: 'AV1'  },
];

const SOURCE_PATTERNS = [
  { re: /\b(bluray|blu-ray|bdrip|brrip)\b/i,  source: 'BluRay'   },
  { re: /\b(webrip|web-rip)\b/i,               source: 'WEBRip'   },
  { re: /\b(webdl|web-dl|web)\b/i,             source: 'WEB-DL'   },
  { re: /\bhdrip\b/i,                           source: 'HDRip'    },
  { re: /\bdvdrip\b/i,                          source: 'DVDRip'   },
  { re: /\bhdtv\b/i,                            source: 'HDTV'     },
];

const LANGUAGE_PATTERNS = [
  { re: /\bfrench\b/i,    lang: 'fr'    },
  { re: /\bspanish\b/i,   lang: 'es'    },
  { re: /\bportuguese\b/i,lang: 'pt'    },
  { re: /\bitalian\b/i,   lang: 'it'    },
  { re: /\bgerman\b/i,    lang: 'de'    },
  { re: /\brussian\b/i,   lang: 'ru'    },
  { re: /\bkorean\b/i,    lang: 'ko'    },
  { re: /\bjapanese\b/i,  lang: 'ja'    },
  { re: /\bchinese\b/i,   lang: 'zh'    },
  { re: /\barabic\b/i,    lang: 'ar'    },
  { re: /\bturkish\b/i,   lang: 'tr'    },
  { re: /\bhindi\b/i,     lang: 'hi'    },
  { re: /\b(tamil|tam)\b/i,       lang: 'ta' },
  { re: /\b(telugu|tel)\b/i,      lang: 'te' },
  { re: /\bmalayalam\b/i,         lang: 'ml' },
  { re: /\bkannada\b/i,           lang: 'kn' },
  { re: /\b(greek|ellinika|ελληνικά)\b/i, lang: 'el' },
  { re: /\b(albanian|shqip)\b/i, lang: 'sq' },
  { re: /\bdubbed\b/i,    lang: 'dubbed'},
];

// Tags that assert more than one audio track. They are not language names: a
// `MULTI`, `DUAL` or scene `DL` release carries several, and the addon's
// language whitelist exists to drop releases whose audio a viewer cannot use,
// so these have to satisfy a whitelist of concrete languages rather than be
// compared against one. Measured on this stack 2026-09-22:
// `Dark.Matter.Der.Zeitenlaeufer.S02E03.GERMAN.DL.1080P.WEB.H264` is German +
// English dual audio, and an `en,es,pt` whitelist discarded it -- `DL` was not
// recognised at all and `GERMAN` was the only language found.
const MULTI_AUDIO_PATTERNS = [
  { re: /\bmulti\b/i,                   lang: 'multi' },
  { re: /\bmulti[\s.-]?audio\b/i,       lang: 'multi' },
  { re: /\bmulti[\s.-]?lang(?:uage)?\b/i, lang: 'multi' },
  { re: /\bdual[\s.-]?audio\b/i,        lang: 'multi' },
  { re: /\bdual\b/i,                    lang: 'multi' },
  { re: /\bdl\b/i,                      lang: 'multi' },
];

// The one source tag that collides with a marker above: `WEB-DL` contains `DL`.
// Matching a bare `\bdl\b` without removing it first would read every WEB-DL
// release as dual-audio, including genuinely single-language ones -- a worse
// failure than the one the marker fixes, because the viewer gets a stream in the
// wrong language and nothing on screen says so. Only the colliding family is
// stripped: a broader list would start eating words that are real signals.
const SOURCE_TAG_NOISE = /\bweb[\s.-]?dl\b/gi;

export function parseTitle(title) {
  if (!title) return {};

  let quality = null;
  for (const { re, quality: q } of QUALITY_PATTERNS) {
    if (re.test(title)) { quality = q; break; }
  }

  let codec = null;
  for (const { re, codec: c } of CODEC_PATTERNS) {
    if (re.test(title)) { codec = c; break; }
  }

  let source = null;
  for (const { re, source: s } of SOURCE_PATTERNS) {
    if (re.test(title)) { source = s; break; }
  }

  // Language detection runs on the title with the colliding source tag removed,
  // so `WEB-DL` cannot be read as dual-audio.
  const langTitle = title.replace(SOURCE_TAG_NOISE, ' ');

  const languages = [];
  for (const { re, lang } of LANGUAGE_PATTERNS) {
    if (re.test(langTitle)) languages.push(lang);
  }
  for (const { re, lang } of MULTI_AUDIO_PATTERNS) {
    if (re.test(langTitle) && !languages.includes(lang)) languages.push(lang);
  }
  // Default to English when nothing was recognised. `dubbed` needs no special
  // case: it is in LANGUAGE_PATTERNS, so a title carrying it never arrives here
  // with an empty list.
  if (!languages.length) {
    languages.push('en');
  }

  const hdr = /\b(hdr|hdr10|dolby.?vision|dv)\b/i.test(title);
  const bitdepth = hdr ? '10bit' : (/\b10.?bit\b/i.test(title) ? '10bit' : null);

  return { quality, codec, source, languages, hdr, bitdepth };
}

/**
 * Build a search query string for a given piece of content.
 * For series: "Show Name S01E02"
 * For movies: "Movie Name 2024"
 */
export function buildSearchQuery(meta) {
  if (meta.type === 'series' && meta.season != null && meta.episode != null) {
    const s = String(meta.season).padStart(2, '0');
    const e = String(meta.episode).padStart(2, '0');
    return `${meta.name} S${s}E${e}`;
  }
  if (meta.year) return `${meta.name} ${meta.year}`;
  return meta.name;
}
