# User Journey Audit (2026-09-15)

Ten independent agents, each briefed on a distinct household persona and given
read-only network/API access, tried to actually *use* the stack the way a
real person would — not read its code. Each ran from `pi1`
(`192.168.110.246` is the NAS), documented exactly what they tried and what
happened, and returned a first-person journey log. This is that record,
synthesized and ranked. It complements [TORBOX-MIGRATION-AUDIT.md](TORBOX-MIGRATION-AUDIT.md),
which covers the code; this covers what a household member actually
experiences hitting it.

One agent's finding did not survive verification and is flagged as such
rather than silently dropped — see Finding 6.

## Findings

### 1. [High] Download progress is a black box for 46 of 47 in-flight requests

Persona: household member checking on a request. Via Seerr's own API
(`GET /api/v1/request`), of 47 requests sitting at `processing` or
`partially available`, only **one** carried a populated `downloadStatus`
(size, `sizeLeft`, ETA). The other 46 returned `"downloadStatus": []` —
nothing between "processing" and "available." No notification channel is
configured either (`emailEnabled`, `enablePushRegistration`, and all
per-user notification methods are off), so there's no push when something
finishes. A household member has strictly less visibility into an in-flight
download than the old qBittorrent progress bar gave them.

**Why:** the transfer now runs entirely on TorBox's servers; Seerr's
`downloadStatus` field only lights up when Radarr/Sonarr's own queue happens
to carry a live entry for it, which is inconsistent now that there's no
always-present local download client for it to poll.

### 2. [Medium] Remote access doesn't exist — not broken, never deployed

Persona: traveling household member. The live `.env` on the NAS still has
`DOMAIN=yourdomain.com` — the literal template placeholder, never replaced.
There is no `cloudflared` container on the NAS at all, running or stopped.
The placeholder domain is a real, publicly registered domain owned by an
unrelated third party (answers with a wildcard record and an expired
certificate) — not a red herring worth chasing, just proof nothing here was
ever pointed at a real address. Anyone away from the house currently has
zero path to reach Jellyfin or Seerr.

### 3. [Medium] Password recovery is admin-assisted only, not self-service

Persona: locked-out household member. Seerr: `emailEnabled: false` and
`jellyfinForgotPasswordUrl` is empty, so the login page never even renders a
reset link. Jellyfin: `POST /Users/ForgotPassword` does work and generates a
real PIN — but writes it to a JSON file inside the container's `/config`
directory, reachable only by whoever has shell access to the NAS. Functions
correctly as designed; just isn't reachable by the person who needs it.

### 4. [Medium] Traefik's front door is inconsistent between the two apps

Persona: unauthenticated visitor. `http://jellyfin.lan` redirects straight
through to Jellyfin's own login page with no extra gate. `http://seerr.lan`
stops at a Traefik-level HTTP Basic Auth prompt (`WWW-Authenticate: Basic
realm="traefik"`) before Seerr's own login screen is ever reached. Worth
confirming whether this is deliberate (an extra layer in front of the
request tool specifically) or a leftover from a `traefik/dynamic/*.yml` rule
that was never applied consistently — `docs/ARCHITECTURE.md`'s Traefik
routing section doesn't currently explain the asymmetry either way.

### 5. [Low-Medium] Subtitle coverage is a per-title lottery

Persona: non-native-English-speaking household member. Sampled 18 items:
several episodes of one show carry 40+ embedded languages with correct
SDH/forced flags — genuinely excellent. Several mainstream movies and at
least two other episodes have English-only or **zero** subtitle streams.
Bazarr clearly works well when it works; coverage just isn't uniform across
the library.

### 6. [Correction — not a real finding] A Seerr API-key test produced a false 403

One agent reported that the real `SEERR_API_KEY` and a garbage string
produced an identical `403 You do not have permission` on `/api/v1/search`,
`/api/v1/request`, and `/api/v1/auth/me`, and flagged the key as
non-functional. **Independently re-verified and found incorrect:** the real
key returns `200` on all three endpoints (`/api/v1/request` lists 105 real
requests, `/api/v1/auth/me` returns the real account). The agent's own key
extraction had a bug, not the API. Recorded here so the false lead doesn't
get rediscovered — the key is fine.

### 7. [Low] Jellyfin's discovery endpoint hands mobile clients a Docker-internal address

`GET /System/Info/Public` (unauthenticated, as real mobile apps call it on
first connect) returns `LocalAddress: http://172.20.0.4:8096` — Jellyfin's
own container IP, unreachable from any real device. Harmless as long as a
client trusts the address the user actually typed, but a landmine for any
client flow (saved-server QR code, auto-discovery) that trusts this field
instead.

### 8. [Info] Pre-login endpoints disclose version/build/host info on both apps

No auth required to read: Seerr's exact version and git commit
(`/api/v1/status`), and Jellyfin's server name, version, and persistent
server ID (`/System/Info/Public`). Normal for self-hosted apps reachable
only on the LAN; noted for completeness, not a real risk at this network
position.

## What holds up

- **Network segmentation is real, not just a passing bats test.** From an
  ordinary household device's network position, all seven admin-only ports
  (Sonarr, Radarr, Bazarr, Prowlarr, decypharr, Pi-hole admin, Uptime Kuma)
  refused connections instantly — a fast REJECT, not a timeout — while the
  two consumer apps responded normally. Confirmed as a live boundary, not
  read off a config file.
- **`.lan` hostnames genuinely work** for a client whose resolver is
  actually pointed at Pi-hole (as `pi1` is): `dig` confirms a real A record
  behind the deliberate `::` AAAA stub, and glibc's default resolution order
  picks the A record without help. The stub remains a real, narrow trap only
  for a resolver/client that prefers IPv6 or mishandles the dual answer —
  not something this check hit, but not eliminated either.
- **Quick Connect works** — a real mobile user can log in with a 6-digit code
  instead of typing a password on a phone keyboard.
- **Playback itself is clean**: direct-play with no transcode needed on a
  sampled 1080p title, correct byte-range support, rich metadata and
  artwork, accurate per-episode watched state (even where the top-level
  "resume" payload shape was confusing).
- **The `SEERR_API_KEY` and Jellyfin automation account both work correctly**
  end-to-end once used properly (see Finding 6).

## Method

Ten `general-purpose` subagents, each given a self-contained persona brief
(network details, credential-retrieval method via the existing
`arr-stack-nas` SSH alias, and a hard read-only constraint — no mutating
requests, no new Seerr requests, no account/setting changes, no exploitation
of the admin-port boundary beyond observing it). Personas: unauthenticated
visitor, Jellyfin browser, Seerr requester, mobile onboarder, `.lan`
hostname explorer, admin-boundary prober, download-transparency seeker,
subtitle/metadata checker, remote-access reality check, locked-out account
recovery. Every finding above traces to a specific agent's transcript; one
(Finding 6) was independently re-run and corrected before being written down.
