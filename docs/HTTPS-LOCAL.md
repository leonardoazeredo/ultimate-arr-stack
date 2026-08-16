# + HTTPS + auth for local admin UIs

> Return to [Setup Guide](SETUP.md) · Requires [+ local DNS](LOCAL-DNS.md) already set up

Adds basic-auth and HTTPS to the local-only admin panels (Sonarr, Radarr, Prowlarr, Bazarr,
qBittorrent, SABnzbd, Pi-hole, Uptime Kuma, duc, Beszel, and the `traefik.lan` dashboard) — several
of these (qBittorrent by explicit design) have no auth of their own on the LAN, so this is the only
gate they get. Jellyfin and Seerr are untouched: they already have real app-level auth and stay
plain HTTP on `.lan` — Cloudflare Tunnel handles their public HTTPS.

This uses a **locally-trusted internal CA** (via [`mkcert`](https://github.com/FiloSottile/mkcert)),
not a public CA — `*.lan` isn't a real, publicly-resolvable domain, so Let's Encrypt can't issue for
it, and running a full ACME server (step-ca) for a single-user home setup is unnecessary
complexity. The tradeoff: every personal device needs the CA's root cert installed once before it
trusts `https://sonarr.lan` etc. without a browser warning.

**Step 1: Generate the CA + wildcard cert (once, on your own machine — not the NAS)**

```bash
brew install mkcert          # macOS; see mkcert's README for other platforms
mkcert -install               # installs the CA into this machine's trust store
mkcert -cert-file lan-wildcard.crt -key-file lan-wildcard.key "*.lan"
```

This creates two files (`lan-wildcard.crt`, `lan-wildcard.key`) signed by a CA whose private key
never leaves this machine — only the leaf cert/key pair goes to the NAS.

**Step 2: Deploy the cert to the NAS**

`traefik/certs/` is gitignored (like `traefik.yml` itself) — copy the two files there directly,
they aren't synced by `git pull`:

```bash
scp -O lan-wildcard.crt lan-wildcard.key cloud-nas:/volume1/docker/arr-stack/traefik/certs/
```

**Step 3: Set the admin-UI password (reuses the Traefik dashboard credential)**

If `TRAEFIK_DASHBOARD_AUTH` is already set in `.env` on the NAS, there's nothing to do — the
`admin-auth` middleware reuses it. To use a different password for the local admin tier, add a
separate `ADMIN_UI_AUTH` var (same `htpasswd -nbB admin 'YOUR_PASSWORD'` format) and point
`docker-compose.traefik.yml`'s `admin-auth` label at it instead.

**Step 4: Recreate Traefik**

```bash
cd /volume1/docker/arr-stack
docker compose -f docker-compose.traefik.yml up -d --force-recreate
```

**Step 5: Trust the CA on every personal device**

`mkcert -install` (Step 1) only trusted the CA on the machine that ran it. For every other
device that should see a green padlock instead of a warning:

- Find the CA root cert: `mkcert -CAROOT` (on the machine from Step 1) → `rootCA.pem`.
- **Other Macs/PCs:** run `mkcert -install` there too, using the *same* `rootCA-key.pem`/
  `rootCA.pem` (copy the whole `mkcert -CAROOT` directory over) — otherwise each machine mints
  its own independent CA and none of them will trust each other's certs.
- **Android:** transfer `rootCA.pem` to the device (AirDrop/email/USB), then
  Settings → Security → Encryption & credentials → Install a certificate → CA certificate.
- **iOS:** AirDrop `rootCA.pem`, install the profile in Settings, then separately enable full
  trust under Settings → General → About → Certificate Trust Settings.

Skipping this step doesn't break anything functionally — the padlock just shows a warning on
devices that haven't trusted the CA, same as any self-signed cert.

**Verification**

- `https://sonarr.lan` (and the other 10 admin hosts) load with no cert warning on a
  CA-trusted device, and prompt for basic-auth before showing the app.
- `http://sonarr.lan` redirects (301) to `https://sonarr.lan`.
- `http://jellyfin.lan` and `http://seerr.lan` are unchanged — still plain HTTP, no auth prompt.
- The Cloudflare-facing public URLs (`jellyfin.yourdomain.com` etc.) are unaffected — Cloudflare
  Tunnel still targets Traefik's `web` (:80) entrypoint, not `websecure`.

**Cert renewal**: `mkcert`-issued leaf certs are valid for ~2.25 years (the CA root itself lasts
~10). Repeat Steps 1–4 (skip `-install`, the CA already exists at `mkcert -CAROOT`) before it
expires — there's no automated renewal here, this is a manual, infrequent step.

**Other docs:** [+ local DNS](LOCAL-DNS.md) · [Reference](REFERENCE.md) · [Troubleshooting](TROUBLESHOOTING.md)
