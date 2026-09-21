# Step 4: Configure Each App (Script-Assisted)

> Return to [Setup Guide](SETUP.md) · [Manual setup instead?](APP-CONFIG.md)

The [configure-apps.sh](../scripts/configure-apps.sh) script automates the fiddly configuration work across Sonarr, Radarr, Prowlarr, Bazarr and Pi-hole — root folders, download clients, naming schemes, NFO metadata, custom formats, delay profiles, subtitle sync, and more.

> **Note:** This script is LLM-generated and human-reviewed. Best not to blindly run scripts from the internet — review [configure-apps.sh](../scripts/configure-apps.sh) for security before running it.

## Step 1: Set up access to each app

Work through these in order. Each app needs you to create an account or complete a first-run wizard before anything else works.

**Jellyfin** — `http://NAS_IP:8096`
Complete the setup wizard (language, admin user, etc.). Skip adding libraries for now — you'll do that in Step 3.

**SABnzbd** *(skip if not using Usenet)* — `http://NAS_IP:8082`
Complete the Quick-Start Wizard with your Usenet provider details (host, username, password, SSL on, port `563`).

**Sonarr** — `http://NAS_IP:8989`
Create admin account when prompted.

**Radarr** — `http://NAS_IP:7878`
Create admin account when prompted.

**Prowlarr** — `http://NAS_IP:9696`
Create admin account when prompted.

**Bazarr** — `http://NAS_IP:6767`
Create admin account when prompted.

## Step 2: Run the script

```bash
# SSH to your NAS:
cd $NAS_STACK_DIR
./scripts/configure-apps.sh
```

Preview what it will do without making changes:

```bash
./scripts/configure-apps.sh --dry-run
```

> **Safe to re-run:** The script is fully idempotent — it checks each setting before applying it and skips anything already configured. You can run it as many times as needed without side effects (e.g., after a stack update or restore).

**What the script configures:**

| Service | Settings |
|---------|----------|
| Sonarr | Root folder, Usenet Blackhole download client, TRaSH naming, NFO metadata, Reject ISO custom format, Usenet delay profile |
| Radarr | Root folder, Usenet Blackhole download client, TRaSH naming, NFO metadata, Reject ISO custom format, Usenet delay profile |
| Prowlarr | FlareSolverr proxy, Sonarr + Radarr app sync |
| Bazarr | Sonarr + Radarr connections, subtitle sync (ffsubsync), Sub-Zero content mods, default English language |
| Pi-hole | Upstream DNS pointed at the in-stack `dnscrypt-proxy` resolver |

> **The torrent client is not scripted.** Decypharr needs a TorBox key and its own config first, and its download client entry is added by hand — see [TorBox (Decypharr)](SETUP.md#adding-more-services-core).

## Step 3: Configure the remaining services

The script handles Sonarr, Radarr, Prowlarr, Bazarr and Pi-hole. Complete these remaining services in order:

### 1. Jellyfin — Add libraries

- Movies → Content type "Movies" → Folder `/data/media/movies`
- TV Shows → Content type "Shows" → Folder `/data/media/tv`

> **Optional:** [Enable hardware transcoding](APP-CONFIG-ADVANCED.md#hardware-transcoding-intel-quick-sync) for GPU-accelerated playback (recommended for Ugreen NAS).

### 2. SABnzbd — Set download folders (skip if not using Usenet)

Config (⚙️) → Folders → set **absolute paths**:
- Temporary Download Folder: `/data/usenet/incomplete`
- Completed Download Folder: `/data/usenet/complete`

> For hardening settings and `.lan` hostname whitelist, see [SABnzbd Advanced Setup](APP-CONFIG-ADVANCED.md#sabnzbd-hardening-trash-recommended).
>
> **SABnzbd is not the arrs' usenet client.** `configure-apps.sh` gives Sonarr and Radarr a Blackhole client pointing at `/data/usenet/blackhole/{nzb,complete}`, and a systemd timer carries those NZBs through TorBox's API. SABnzbd's own connection to `nntp.torbox.app` reaches only articles about 90 days old, which is most of what an indexer returns — see [Usenet](TROUBLESHOOTING.md#usenet-sabnzbd-fails-every-article-torboxs-own-downloader-succeeds). The folders above matter only if you point SABnzbd at a provider of your own.

### 3. Prowlarr — Add your indexers

1. Indexers (left sidebar) → + → search by name → add your torrent indexers
2. If using Usenet: add a Usenet indexer the same way (e.g., NZBGeek, DrunkenSlug)

### 4. Seerr — Connect to Jellyfin and *arrs

1. Open `http://NAS_IP:5055`
2. Sign in with Jellyfin: URL `http://jellyfin:8096`, enter your Jellyfin credentials
3. Settings → Jellyfin → set **External URL** to `https://jellyfin.lan` (or `http://NAS_IP:8096`) — makes "Play on Jellyfin" links work in your browser
4. Settings → Services → Add Radarr:
   - Hostname: `gluetun`, Port: `7878`, Quality Profile: `UHD Bluray + WEB`
   - External URL: `http://radarr.lan` (or `http://NAS_IP:7878`)
5. Settings → Services → Add Sonarr:
   - Hostname: `gluetun`, Port: `8989`, Quality Profile: `Ultra-HD`
   - External URL: `http://sonarr.lan` (or `http://NAS_IP:8989`)
6. Settings → Jellyfin → toggle **Movies** and **TV** on → Save
7. Click **Sync Libraries** then **Start Scan**

### 5. Bazarr — Add subtitle providers

Settings → Providers → add a provider (e.g., OpenSubtitles).

> The script already configured Sonarr/Radarr connections and subtitle sync.

### 6. DNS — nothing to configure here

DNS is not part of this stack. Pi-hole and dnscrypt-proxy were removed on
2026-09-21 and AdGuard Home on the router answers for the house. There is no
Pi-hole login and no `PIHOLE_UI_PASS`. See [LOCAL-DNS.md](LOCAL-DNS.md).

---

**You're done!** Return to [Setup Guide → Step 5: Check It Works](SETUP.md#step-5-check-it-works).
