import { test, expect } from '@playwright/test';
import { url, bridgeUrl, HOST, DOCKER_AVAILABLE } from './helpers';

// The operations group: monitoring, dashboards, and the Docker API proxy.
//
// These had no end-to-end coverage of any kind. The four services here are the
// ones that are actually reachable over the bridge network from inside this
// container -- measured 2026-09-11, not assumed: diun, gluetun-rotator and
// gluetun-recover listen on nothing but Docker's own DNS resolver, configarr is
// a one-shot job that exits 0 by design, and beszel-agent, deunhealth,
// dnscrypt-proxy and vpn-socks5 ship no shell, so there is no surface to test
// from here at all. Their coverage is the compose-level checks in the bats
// suite, and saying so is better than a test that could not fail.
//
// Why these matter despite being "only" the ops group: nothing else in either
// suite notices when they stop answering. deunhealth restarts unhealthy
// containers, gluetun-recover is what puts tunneled containers back on a live
// VPN namespace, diun reports image updates, and the socket proxy is the only
// thing standing between those tools and the raw Docker socket.

test.describe('Operations services', () => {
  test.skip(!DOCKER_AVAILABLE, 'needs Docker socket access to resolve bridge IPs (run on the NAS)');

  test('uptime-kuma answers on its published port', async ({ request }) => {
    // The only one of the four with a host port, so this also covers the
    // binding itself and not just the process.
    const res = await request.get(`http://${HOST}:3001/`, { timeout: 10_000 });
    expect(res.ok()).toBeTruthy();
    const body = await res.text();
    expect(body).toContain('<html');
  });

  test('uptime-kuma API answers, so the UI has a backend', async ({ request }) => {
    // The page is a static shell; this is the call it makes on load. A UI that
    // serves HTML while its API is dead looks identical in a screenshot.
    const res = await request.get(`http://${HOST}:3001/api/entry-page`, { timeout: 10_000 });
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body).toHaveProperty('type');
  });

  test('beszel hub reports its API healthy', async ({ request }) => {
    const res = await request.get(bridgeUrl('beszel', 8090, '/api/health'), { timeout: 10_000 });
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body.message).toContain('healthy');
  });

  test('beszel hub serves its UI', async ({ request }) => {
    const res = await request.get(bridgeUrl('beszel', 8090, '/'), { timeout: 10_000 });
    expect(res.ok()).toBeTruthy();
  });

  test('duc serves its web UI over the bridge', async ({ request }) => {
    // duc.lan is asserted through Traefik in networking.spec.ts, but that test
    // stops at the 401 gate and never reaches this backend.
    const res = await request.get(bridgeUrl('duc', 80, '/'), { timeout: 10_000 });
    expect(res.ok()).toBeTruthy();
    const body = await res.text();
    expect(body).toContain('duc');
  });
});

// The socket proxy is a security boundary, so it gets assertions in both
// directions: what it must allow, and what it must refuse. A test that only
// checked reachability would pass just as well against a proxy that had been
// started with everything enabled.
test.describe('Docker socket proxy', () => {
  test.skip(!DOCKER_AVAILABLE, 'needs Docker socket access to resolve the bridge IP (run on the NAS)');

  const proxy = (path: string) => bridgeUrl('docker-socket-proxy', 2375, path);

  test('it answers, and forwards the Docker version', async ({ request }) => {
    const res = await request.get(proxy('/version'), { timeout: 10_000 });
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body.Version).toBeTruthy();
  });

  test('it allows the read surfaces its consumers need', async ({ request }) => {
    // traefik's docker provider needs container and network listings, diun
    // needs image info, gluetun-recover watches events. Losing any of these
    // breaks a consumer silently, so each is asserted rather than assumed from
    // the env block.
    for (const path of ['/containers/json', '/networks', '/images/json', '/info']) {
      const res = await request.get(proxy(path), { timeout: 10_000 });
      expect(res.ok(), `GET ${path} should be allowed`).toBeTruthy();
    }
  });

  test('it refuses the Docker API surfaces nobody asked for', async ({ request }) => {
    // VOLUMES=0, EXEC=0, and every method outside the enabled set. These return
    // 403 from the proxy itself -- measured: the refusal happens without the
    // request ever reaching the daemon, which is why 403 rather than 404.
    const refused: Array<[string, string]> = [
      ['GET', '/volumes'],
      ['GET', '/secrets'],
      ['POST', '/containers/probe/exec'],
      ['PUT', '/containers/probe/archive'],
    ];
    for (const [method, path] of refused) {
      const res = await request.fetch(proxy(path), { method, timeout: 10_000 });
      expect(res.status(), `${method} ${path} must be refused`).toBe(403);
    }
  });

  test('it permits container restart, which is why POST is enabled at all', async ({ request }) => {
    // The documented reason POST=1 is set: gluetun-recover's `docker restart`
    // after a VPN reconnect. Asserted against a name that does not exist, so
    // the assertion is about the proxy's method policy rather than about any
    // container: a 404 from the daemon means the request was forwarded, a 403
    // would mean it was blocked and gluetun-recover is broken.
    //
    // The counterpart: this same permission is what makes the proxy a
    // stop/kill/delete surface for anything on arr-core, which is why the
    // consumers that need it are named in docker-compose.utilities.yml's
    // comment rather than left implicit.
    const res = await request.post(proxy('/containers/playwright-nonexistent-probe/restart'), {
      timeout: 10_000,
      failOnStatusCode: false,
    });
    expect(res.status(), 'restart must be forwarded, not refused by policy').not.toBe(403);
  });
});
