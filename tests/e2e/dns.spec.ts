// DNS acceptance tests for the AdGuard-Home-on-the-router migration — Phase 1,
// task 1.3 of docs/superpowers/plans/2026-09-19-dns-adguard-router-migration.md.
// Runs from the containerised e2e runner on the NAS, alongside the rest of
// tests/e2e/.
//
// These are written BEFORE the router is touched, and they are expected to fail
// against today's design. Today the NAS Pi-hole owns `.lan` (18 hostnames, all
// answering Traefik's macvlan address) and owns blocking (NULL mode, so a
// blocklisted name answers 0.0.0.0); the router's dnsmasq knows neither. A green
// run here means the migration's end state is in place — it is not evidence the
// spec is wrong, and a red one is not a broken test.
//
// Every assertion is on the ANSWER, never on a status code or on dig's exit
// status. "NOERROR" is satisfied by an empty answer, and a resolver answering
// 0.0.0.0 for every name would sail through anything shaped like a status check.
// Each failure message names the query, the transport, and what actually came
// back.
//
// Both transports are asserted for every name. Port 53 is a `tcpudp` rule on the
// router, and a TCP-only probe passes while UDP resolution — the transport DNS
// actually uses — is broken. tests/network-segmentation.bats documents the same
// trap for the same port; this file is where the client path meets it.
//
// The names used here are a deliberate subset of tests/fixtures/dns-baseline.txt,
// the 50-row oracle that scripts/dns-matrix-check.sh and the Phase 3 parity
// harness consume. The two must agree on what each name should answer, so a
// change to one is a reason to look at the other.

import { execFileSync } from 'node:child_process';
import { test, expect } from '@playwright/test';

// ─── The resolver under test ─────────────────────────────────────────────────
//
// One address, in one place. Which resolver answers IS the migration's subject:
// every client is handed the NAS Pi-hole (192.168.110.246) today, and after
// Phase 5/6 they are handed the router. The redirect model means the address a
// client queries keeps being port 53 throughout — only the process behind it
// changes — which is why the default here is the migration's endpoint and not
// the resolver that answers today.
//
// The parameter exists so the same assertions can be pointed elsewhere without
// editing the file:
//
//   DNS_RESOLVER=192.168.110.246 npx playwright test tests/e2e/dns.spec.ts
//
// No port knob, deliberately. AdGuard Home's staging port is 3053, and from a
// VLAN client it is dropped rather than closed (`Allow-DNS-vlan*` permits dport
// 53 only). A port option here would invite exactly the probe the plan tells
// workers not to attempt, and clients never use that port anyway.
const DNS_RESOLVER = process.env.DNS_RESOLVER ?? '192.168.110.1';

// Traefik's macvlan address — what every `.lan` name has to answer as. Read from
// .env.e2e under the same variable networking.spec.ts uses, but defaulted rather
// than skipped when unset: Playwright exits 0 on a skipped test, and a DNS
// acceptance test that skips is one that cannot fail. (The bats suite carries
// the same address as TRAEFIK_VLAN10_IP's default in
// tests/network-segmentation.bats.)
const TRAEFIK_LAN_IP = process.env.TRAEFIK_LAN_IP ?? '192.168.110.250';

// One name per concern. example.com and doubleclick.net are both rows of the
// baseline fixture (public: ANY, blocklist hit: BLOCKED); jellyfin.lan is one of
// the 18 `.lan` hostnames Phase 3.2 migrates, and is the name
// networking.spec.ts already asserts through Pi-hole.
const PUBLIC_NAME = 'example.com';
const LAN_NAME = 'jellyfin.lan';
const BLOCKED_NAME = 'doubleclick.net';

const TRANSPORTS = ['udp', 'tcp'] as const;
type Transport = (typeof TRANSPORTS)[number];

// dig ships in tests/e2e/Dockerfile's image (`dnsutils`), so this is true in the
// runner the suite is built for. Probed once at load time, the way helpers.ts
// probes `docker version` for DOCKER_AVAILABLE: a missing oracle skips with a
// reason instead of failing every test here with a misleading resolver error.
const DIG_AVAILABLE = (() => {
  try {
    execFileSync('dig', ['-v'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
})();

interface Answer {
  /** RCODE from dig's comment line: NOERROR, NXDOMAIN, SERVFAIL…, or ERROR when
   *  dig never got far enough to report one. Carried for the failure message,
   *  never asserted on its own. */
  status: string;
  /** The answer section's records of the requested type, in order. Empty is a
   *  legitimate outcome (NODATA/NXDOMAIN) and also what a timeout produces. */
  records: string[];
  /** dig's own output, so a failure can show what came back rather than only
   *  how many records did. */
  raw: string;
}

// Query one name over exactly one transport. Parsing mirrors
// scripts/lib/dns-matrix.sh's dns_matrix_query so this spec and the oracle read
// the same dig output the same way.
function query(name: string, qtype: string, transport: Transport): Answer {
  // +notcp on the UDP leg is not decoration: dig retries a truncated UDP answer
  // over TCP by default, which would let a broken UDP path pass on the very
  // transport this spec separately asserts over TCP.
  const transportFlag = transport === 'tcp' ? '+tcp' : '+notcp';

  let raw = '';
  try {
    raw = execFileSync(
      'dig',
      [
        '+time=3',
        '+tries=1',
        transportFlag,
        '+noall',
        '+comments',
        '+answer',
        `@${DNS_RESOLVER}`,
        name,
        qtype,
      ],
      { encoding: 'utf8', timeout: 10_000 },
    );
  } catch (err) {
    // A timeout or an unreachable resolver makes dig exit non-zero with little
    // or no output. That is a resolution failure, not a reason to skip: it
    // becomes an answer with no records, and the assertion reports it by name
    // and transport instead of passing quietly.
    const failure = err as { stdout?: string; stderr?: string; message?: string };
    raw = `${failure.stdout ?? ''}${failure.stderr ?? ''}`.trim() || (failure.message ?? 'dig produced no output');
  }

  const status = /status:\s*([A-Z]+)/.exec(raw)?.[1] ?? 'ERROR';
  // dig's answer line: <name> <ttl> <class> <type> <value> …
  const records = raw
    .split('\n')
    .map((line) => line.trim().split(/\s+/))
    .filter((fields) => fields.length >= 5 && fields[3] === qtype)
    .map((fields) => fields[4]);

  return { status, records, raw };
}

// The whole point of a legible Phase 1 failure: name, transport, and what came
// back, in one message.
function report(name: string, qtype: string, transport: Transport, answer: Answer): string {
  const records = answer.records.length > 0 ? answer.records.join(', ') : '<none>';
  const dig = answer.raw.trim().replace(/\n/g, '\n           ');
  return [
    `${name} ${qtype} over ${transport.toUpperCase()} against ${DNS_RESOLVER}:53`,
    `  status:  ${answer.status}`,
    `  answers: ${records}`,
    `  dig:     ${dig}`,
  ].join('\n');
}

test.describe(`DNS acceptance (resolver ${DNS_RESOLVER}:53)`, () => {
  test.describe('public names', () => {
    // Resolution itself. This one passes today and must keep passing after the
    // router takes over — it is the control that separates "the resolver is
    // broken for everything" from "the resolver lost `.lan`/blocking".
    for (const transport of TRANSPORTS) {
      test(`${PUBLIC_NAME} resolves over ${transport.toUpperCase()}`, () => {
        test.skip(!DIG_AVAILABLE, 'dig is not installed — nothing here can query a resolver');

        const answer = query(PUBLIC_NAME, 'A', transport);
        // ANY, one record minimum: example.com is load-balanced and hands out a
        // different edge per query, so its value is not compared (the baseline
        // fixture records the same expectation).
        expect(answer.records.length, report(PUBLIC_NAME, 'A', transport, answer)).toBeGreaterThan(0);
      });
    }
  });

  test.describe('.lan names', () => {
    // The answer is the assertion: the Traefik macvlan address every `.lan`
    // hostname must resolve to. Against today's design this fails with a real
    // answer from upstream (`.lan` is not a public suffix, so the router either
    // NXDOMAINs or forwards it) — which is the failure the migration exists to
    // remove.
    for (const transport of TRANSPORTS) {
      test(`${LAN_NAME} resolves to Traefik's macvlan address over ${transport.toUpperCase()}`, () => {
        test.skip(!DIG_AVAILABLE, 'dig is not installed — nothing here can query a resolver');

        const answer = query(LAN_NAME, 'A', transport);
        // Exactly that address and nothing else. The baseline fixture's rule for
        // an address expectation is "every answer has to be it, and there has to
        // be one"; naming the array makes a resolver that answers the right
        // address alongside a wrong one fail here rather than pass on a
        // substring match.
        expect(answer.records, report(LAN_NAME, 'A', transport, answer)).toEqual([TRAEFIK_LAN_IP]);
      });
    }
  });

  test.describe('blocked names', () => {
    // Pi-hole's NULL blocking mode answers 0.0.0.0 for a blocklisted name, and
    // the migration has to reproduce that (Gate 3). Against today's design this
    // fails with the real ad-network addresses, which is the legible form of
    // "the router does not block yet".
    //
    // Deliberately stricter than the fixture's BLOCKED rule, which accepts
    // 0.0.0.0 as one of the answers: here a resolver that returns 0.0.0.0
    // *and* the real address is a leak, and has to fail. googleadservices.com
    // and googlesyndication.com are in the fixture too; one name per transport
    // is enough in this spec, and the parity harness carries the full list.
    for (const transport of TRANSPORTS) {
      test(`${BLOCKED_NAME} comes back as 0.0.0.0 over ${transport.toUpperCase()}`, () => {
        test.skip(!DIG_AVAILABLE, 'dig is not installed — nothing here can query a resolver');

        const answer = query(BLOCKED_NAME, 'A', transport);
        expect(answer.records, report(BLOCKED_NAME, 'A', transport, answer)).toEqual(['0.0.0.0']);
      });
    }
  });

  // Not covered here, deliberately: AAAA for `.lan`, where dnsmasq answers `::`
  // (pihole/dnsmasq.d/02-local-dns.conf.example's `address=/lan/::`, needed so
  // musl/Alpine containers do not treat AAAA NXDOMAIN as a hard failure). That
  // is task 1.4's subject and needs an Alpine client, not a dig line here.
});
