import { test, expect } from '@playwright/test';
import { url, bridgeUrl, HOST, DOCKER_AVAILABLE, dockerExec } from './helpers';

// Newer additions to the stack — Decypharr/TorBox, Magnetio, stremio-jellyfin
// — had zero test coverage before this file existed.

test.describe('Decypharr', () => {
  test('Decypharr web UI responds', async ({ request }) => {
    const res = await request.get(url('decypharr', '/'));
    expect(res.ok()).toBeTruthy();
  });
});

test.describe('Magnetio', () => {
  test('magnetio-scraper health endpoint responds', () => {
    // Internal only — no published port — so this needs docker exec.
    test.skip(!DOCKER_AVAILABLE, 'docker CLI not available — run on the NAS directly');
    const body = dockerExec('magnetio-scraper', ['wget', '-qO-', 'http://localhost:8080/health']);
    expect(body).toBeTruthy();
  });

  test('magnetio-addon manifest is reachable (published via Gluetun port 7000)', async ({ request }) => {
    const res = await request.get(url('magnetioAddon', '/manifest.json'));
    expect(res.ok()).toBeTruthy();
    const manifest = await res.json();
    expect(manifest.id ?? manifest.name).toBeTruthy();
  });

  test('magnetio-redis responds to PING', () => {
    test.skip(!DOCKER_AVAILABLE, 'docker CLI not available — run on the NAS directly');
    const password = process.env.MAGNETIO_REDIS_PASSWORD;
    test.skip(!password, 'MAGNETIO_REDIS_PASSWORD not set');

    const reply = dockerExec('magnetio-redis', ['redis-cli', '-a', password!, 'PING']);
    expect(reply).toContain('PONG');
  });
});

test.describe('stremio-jellyfin', () => {
  // The whole chain a Stremio client walks, not just "the port answers".
  //
  // manifest -> catalog -> stream -> the media itself. Every step here failed
  // at least once on 2026-09-11 and nothing in either suite noticed, because the
  // only assertion was that manifest.json responds:
  //
  //   - the login header was malformed, so the addon exited on boot and
  //     restarted in a loop: the manifest test failed, but only because the port
  //     was dead, and the cause took an evening to find;
  //   - with the login fixed, every authenticated call 401'd, so the catalog
  //     came back with zero items -- which no test asserted;
  //   - with that fixed, episodes resolved to nothing, because the season
  //     lookup asked for IndexNumber === 1 while the library had only Specials,
  //     which was answered by falling back to the first season and the first
  //     episode the library did have. That fallback then outlived its reason
  //     and served a wrong episode for every season of a series the library
  //     holds only in part.
  //
  // Each of those is a different failure of the same chain, and each is caught
  // by one assertion below. The addon is local build with a published port, so
  // none of this needs Docker access and it runs everywhere the suite runs.
  //
  // The season/episode contract the two last tests pin down is exact match or
  // no stream, in both directions: what the library holds resolves, and what it
  // does not hold is refused rather than approximated.

  const addon = (path: string) => url('stremioJellyfin', path);

  test('stremio-jellyfin manifest is reachable', async ({ request }) => {
    const res = await request.get(addon('/manifest.json'));
    expect(res.ok()).toBeTruthy();
    const manifest = await res.json();
    expect(manifest.id ?? manifest.name).toBeTruthy();
  });

  test('the manifest advertises the catalogs and resources the addon serves', async ({ request }) => {
    const manifest = await (await request.get(addon('/manifest.json'))).json();
    // A manifest whose catalogs disappear is an addon that installs and then
    // shows an empty Discover page -- the failure that reads as success.
    expect(manifest.resources).toEqual(expect.arrayContaining(['catalog', 'stream']));
    const catalogs = (manifest.catalogs ?? []).map((c: { type: string }) => c.type);
    expect(catalogs).toEqual(expect.arrayContaining(['movie', 'series']));
  });

  test('the catalog returns items carrying IMDb ids', async ({ request }) => {
    const res = await request.get(addon('/catalog/movie/all/skip=0.json'), { timeout: 30_000 });
    expect(res.ok()).toBeTruthy();
    const metas = (await res.json()).metas ?? [];
    // Not `toBeGreaterThan(0)` alone: an item with no IMDb id cannot be turned
    // into a stream URL, so it is present-but-unplayable. The addon's own
    // itemToMeta drops anything without one.
    expect(metas.length).toBeGreaterThan(0);
    const withImdb = metas.filter((m: { id?: string }) => /^tt\d+$/.test(m.id ?? ''));
    expect(withImdb.length, 'no catalog item carried an IMDb id').toBeGreaterThan(0);
    expect(withImdb[0].name).toBeTruthy();
  });

  test('a catalog item resolves to a stream URL, and that URL serves media', async ({ request }) => {
    // The end of the chain: this is the URL Stremio hands to its player, so
    // fetching it is what proves the addon produced something playable rather
    // than merely a well-formed JSON body.
    const catalog = await (await request.get(addon('/catalog/movie/all/skip=0.json'), { timeout: 30_000 })).json();
    const item = (catalog.metas ?? []).find((m: { id?: string }) => /^tt\d+$/.test(m.id ?? ''));
    expect(item, 'no catalog item with an IMDb id to resolve').toBeTruthy();

    const streamRes = await request.get(addon(`/stream/movie/${item.id}.json`), { timeout: 30_000 });
    expect(streamRes.ok()).toBeTruthy();
    const streams = (await streamRes.json()).streams ?? [];
    expect(streams.length, `no stream resolved for ${item.id} (${item.name})`).toBeGreaterThan(0);
    expect(streams[0].url).toContain('/videos/');

    // Range request, like a player starting playback.
    //
    // What this proves, measured by mutating the addon and watching: it catches
    // a malformed URL -- a wrong id, a missing mediaSourceId, a path that is not
    // /videos/ -- because those return 404 or a JSON error rather than bytes.
    //
    // What it does NOT prove, and the mutation showed this plainly: the
    // `api_key` in that URL is not what authorises it. Replacing the token with
    // a fixed wrong value still returned 206 with real media, as did removing
    // the parameter entirely. Jellyfin 12 serves `/videos/` to anything that can
    // reach it, so on this network the token is decoration rather than a gate.
    // The real gate is network reach, which is why the addon's port not being in
    // the VLAN20 allow-list mattered, and why routing it through Traefik (which
    // is allowed) is what made it usable. Do not read this assertion as an
    // access-control check.
    const media = await request.get(streams[0].url, { headers: { Range: 'bytes=0-1023' }, timeout: 30_000 });
    expect([200, 206]).toContain(media.status());
    const body = await media.body();
    expect(body.length, 'the stream URL returned no media bytes').toBeGreaterThan(0);
  });

  test('an episode the library holds resolves to a stream URL', async ({ request }) => {
    // Whichever series the catalog returns first is not guaranteed to hold a
    // first season, so walk a few of them rather than asserting on one. A
    // library where none of the first few has a season 1 is a real failure
    // here, not a reason to skip.
    const catalog = await (await request.get(addon('/catalog/series/all/skip=0.json'), { timeout: 30_000 })).json();
    const candidates = (catalog.metas ?? [])
      .filter((m: { id?: string }) => /^tt\d+$/.test(m.id ?? ''))
      .slice(0, 5);
    expect(candidates.length, 'the series catalog returned nothing with an IMDb id').toBeGreaterThan(0);

    let resolved: { name: string; url: string } | undefined;
    for (const series of candidates) {
      const streamRes = await request.get(addon(`/stream/series/${series.id}:1:1.json`), { timeout: 30_000 });
      const streams = (await streamRes.json()).streams ?? [];
      if (streams.length > 0) {
        resolved = { name: series.name, url: streams[0].url };
        break;
      }
    }
    // An empty list for every candidate is exactly the 2026-09-11 bug. It is
    // asserted rather than skipped because the library does have series with
    // episodes.
    expect(resolved, `no stream resolved for S1E1 on any of ${candidates.length} catalog series`).toBeTruthy();
    expect(resolved!.url).toContain('/videos/');
  });

  test('an episode the library does not hold resolves to no stream', async ({ request }) => {
    // The other half of the same contract, and the half that went untested.
    //
    // Both lookups used to end in a fallback -- first season, first episode --
    // so a request for an episode the library does not hold was answered with
    // an unrelated one. Stremio offers a Jellyfin stream for every episode of
    // the series Cinemeta lists, so a partly-downloaded series looked complete
    // and picking any missing episode played the wrong thing. Measured
    // 2026-09-22 with only Dragon Ball Super S1-S2 held: S03E01, S03E19 and
    // S05E55 all resolved, to S01E01.
    //
    // Season 99 is asked for because no library holds one, which keeps the
    // assertion independent of what this library happens to contain.
    const catalog = await (await request.get(addon('/catalog/series/all/skip=0.json'), { timeout: 30_000 })).json();
    const series = (catalog.metas ?? []).find((m: { id?: string }) => /^tt\d+$/.test(m.id ?? ''));
    test.skip(!series, 'the series catalog returned nothing with an IMDb id');

    const streamRes = await request.get(addon(`/stream/series/${series.id}:99:1.json`), { timeout: 30_000 });
    expect(streamRes.ok()).toBeTruthy();
    // The shape matters as much as the emptiness. Every refusal path in this
    // handler used to answer with a bare `[]`, which is not what a stream
    // resource returns; this asserts the declared shape, so a return to the old
    // one fails here rather than passing on `undefined ?? []`.
    const body = await streamRes.json();
    expect(body.streams, `${series.id} answered a request for season 99 without a streams array`).toEqual([]);
  });
});

// Homepage publishes no host port by design — it is fronted by Traefik with
// basic auth, so it is reached here on its arr-core bridge IP instead. Needs the
// Docker CLI to resolve that IP, hence the DOCKER_AVAILABLE gate, matching this
// suite's convention of skipping off-NAS rather than failing.
test.describe('Homepage', () => {
  test.skip(!DOCKER_AVAILABLE, 'needs Docker socket access (run on the NAS)');

  test('Homepage dashboard responds', async ({ request }) => {
    const res = await request.get(bridgeUrl('homepage', 3000, '/'));
    expect(res.ok()).toBeTruthy();
  });

  test('Homepage healthcheck endpoint responds', async ({ request }) => {
    const res = await request.get(bridgeUrl('homepage', 3000, '/api/healthcheck'));
    expect(res.ok()).toBeTruthy();
  });

  test('Homepage is NOT reachable on the old published port', async ({ request }) => {
    // Regression guard for the fix that removed "3000:3000": republishing it
    // would silently restore unauthenticated LAN access to the dashboard.
    const res = await request
      .get(`http://${HOST}:3000/`, { timeout: 5000 })
      .catch(() => null);
    expect(res).toBeNull();
  });
});

// Container-toolchain contracts. Regression for snags #14/#15 from the
// credential-drift work (2026-08-17): scripts written against an assumed
// toolchain broke live when a base image didn't have what was expected
// (Bazarr has no pyyaml, Seerr has no curl). These assert the toolchain
// shape the detector script and its tests rely on, so a future base-image
// bump that silently changes it fails here instead of in production.
test.describe('Container toolchain contracts', () => {
  test('seerr has no curl but does have node', () => {
    test.skip(!DOCKER_AVAILABLE, 'docker CLI not available — run on the NAS directly');

    expect(() => dockerExec('seerr', ['which', 'curl'])).toThrow();
    expect(() => dockerExec('seerr', ['which', 'node'])).not.toThrow();
  });

  test('bazarr has no importable yaml module', () => {
    test.skip(!DOCKER_AVAILABLE, 'docker CLI not available — run on the NAS directly');

    expect(() => dockerExec('bazarr', ['python3', '-c', 'import yaml'])).toThrow();
  });
});
