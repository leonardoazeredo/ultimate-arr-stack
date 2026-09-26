# Step 4: Configure Each App

> Return to [Setup Guide](SETUP.md)

Your stack is running! Now configure each app to work together.

**Configuration order:** Services depend on each other, so configure them in the order below:
1. Jellyfin (media server — needed before Seerr)
2. Decypharr (torrent client — needed before Sonarr/Radarr)
3. Usenet (optional — `configure-apps.sh` adds the TorBox blackhole client for you)
4. Sonarr & Radarr (library managers — need Decypharr configured first)
5. Prowlarr (indexers — needs Sonarr/Radarr configured first)
6. Seerr (requests — needs Jellyfin + Sonarr/Radarr configured first)
7. Bazarr (subtitles — needs Sonarr/Radarr configured first)
8. Pi-hole (DNS — independent, do anytime)

See **[Quick Reference → Service Connection Guide](REFERENCE.md#service-connection-guide)** for how services connect to each other.

## Choose your path

| | Script-Assisted (Recommended) | Manual |
|---|---|---|
| **Time** | ~5 minutes | ~30 minutes |
| **What happens** | Script configures Sonarr, Radarr, Prowlarr, Bazarr and Pi-hole; you do the rest manually | You configure everything through the web UI |
| **Guide** | **[APP-CONFIG-QUICK.md](APP-CONFIG-QUICK.md)** | Continue below ↓ |

---

## Manual Configuration

Work through these sections top to bottom.

## 4.1 Jellyfin (Media Server)

Streams your media library to any device.

1. **Access:** `http://NAS_IP:8096`
2. **Create admin account** when prompted (setup wizard)
3. **Add Libraries:**
   - Movies: Content type "Movies", Folder `/data/media/movies`
   - TV Shows: Content type "Shows", Folder `/data/media/tv`

> **Optional:** [Enable hardware transcoding](APP-CONFIG-ADVANCED.md#hardware-transcoding-intel-quick-sync) for GPU-accelerated playback (recommended for Ugreen NAS). Also see [Kodi for Fire TV](APP-CONFIG-ADVANCED.md#kodi-for-fire-tv-dolby-vision--truehd-atmos) and [RAID5 streaming tuning](APP-CONFIG-ADVANCED.md#raid5-streaming-tuning).

## 4.2 Usenet (TorBox Blackhole)

Usenet runs through TorBox's API. Sonarr and Radarr get the arrs' own **Blackhole** download
client, which writes each `.nzb` it grabs into one folder and polls a second for the finished
release:

| Setting | Value |
|---------|-------|
| NZB Folder | `/data/usenet/blackhole/nzb` |
| Watch Folder | `/data/usenet/blackhole/complete` |

`configure-apps.sh` adds that client to both arrs, so there is nothing to set up by hand — provided
the **SABnzbd container is running**, which is this stack's marker for "this deployment wants
usenet". Stop that container and re-run the script and the client is simply not added; the blackhole
itself needs no service and no credential of its own. Between the two folders sits
[usenet-blackhole.timer](MAINTENANCE.md#usenet-blackhole-systemd-timer-every-2-minutes):
it submits each NZB to TorBox, waits for the download, fetches it, unpacks the RAR volumes a scene
release is usually posted as, and moves the result into the watch folder.

> **Why a blackhole and not SABnzbd?** 81 of 85 Sonarr usenet grabs failed on SABnzbd's TorBox
> server (`nntp.torbox.app`), and releases it could not fetch completed through TorBox's API. It
> was blamed on a ~90-day retention limit; re-measured 2026-09-26 there is no such limit, only
> per-release article loss that grows with age, so the comparison is still open. The
> measurements are in [Usenet: SABnzbd Fails Every
> Article](TROUBLESHOOTING.md#usenet-sabnzbd-fails-every-article-torboxs-own-downloader-succeeds).

> **Next:** add a Usenet indexer in [Prowlarr §4.5](#45-prowlarr-indexer-manager).

### Using a usenet provider of your own instead

SABnzbd is still part of the stack and still works, and you may prefer paying a provider to
routing everything through TorBox. To go that way, replace the Blackhole client with SABnzbd in
each arr (Settings → Download Clients), then:

1. **Access:** `http://NAS_IP:8082`
2. **Run Quick-Start Wizard** with your Usenet provider details:

   **Popular providers:**
   | Provider | Price | Server |
   |----------|-------|--------|
   | Frugal Usenet | $4/mo | `news.frugalusenet.com` |
   | Newshosting | $6/mo | `news.newshosting.com` |
   | Eweka | €4/mo | `news.eweka.nl` |

   **Wizard settings:**
   - Host: (from table above)
   - Username: (your account email)
   - Password: (your account password)
   - SSL: ✓ checked
   - Click **Advanced Settings**:
     - Port: `563`
     - Connections: `20-60` (depends on plan)
   - Click **Test Server** → **Next**

3. **Configure Folders:** Config (⚙️) → Folders → set **absolute paths**:
   - **Temporary Download Folder:** `/data/usenet/incomplete`
   - **Completed Download Folder:** `/data/usenet/complete`
   - Save Changes

   > **Important:** Don't use relative paths like `Downloads/complete` - Sonarr/Radarr won't find them.

4. **Get API Key:** Config (⚙️) → General → Copy **API Key**

> **Optional:** [SABnzbd hardening](APP-CONFIG-ADVANCED.md#sabnzbd-hardening-trash-recommended) (TRaSH recommended settings for sorting, propagation, hostname whitelist).

> **Leave the blackhole timer running** even on this path. It is harmless with an empty NZB folder,
> and a re-run of `configure-apps.sh` will put the Blackhole client back.

## 4.3 Sonarr (TV Shows)

Searches for TV shows, sends download links to Decypharr (torrents) or the Blackhole client
(usenet), and organizes completed files.

1. **Access:** `http://NAS_IP:8989`
2. **Create admin account** when prompted
3. **Add Root Folder:** Settings → Media Management → `/data/media/tv`
4. **Add Download Client(s):** Settings → Download Clients

   **Decypharr / TorBox (torrents):** *(setup in [TorBox (Decypharr)](SETUP.md#adding-more-services-core))*
   - Add → qBittorrent (Decypharr speaks the qBittorrent Web API)
   - Host: `decypharr` (Decypharr is on the bridge, same as Sonarr — no VPN hop needed)
   - Port: `8282`
   - **Username:** `http://sonarr:8989` (Sonarr's own URL — not a real qBittorrent login; this is
     how Decypharr identifies which Arr is calling, matched against its own `arrs` config)
   - **Password:** Sonarr's API key (Settings → General → API Key)
   - Category: `tv`

   **Usenet Blackhole:** *(added by `configure-apps.sh`)*
   - Add → Blackhole
   - NZB Folder: `/data/usenet/blackhole/nzb`
   - Watch Folder: `/data/usenet/blackhole/complete`
   - There is no host or API key, because no usenet server is involved: a timer moves each NZB
     between those two folders through TorBox's API — see [§4.2](#42-usenet-torbox-blackhole)
   - No category (the Blackhole client has no such field)

5. **Enable NFO metadata:** Settings → Metadata → Kodi (XBMC) / Emby → **Enable** (see [why this matters](#nfo-metadata))
   - Series Metadata: ✅
   - Episode Metadata: ✅
   - All image options: ❌ (Jellyfin handles its own artwork)

5. **Configure naming (TRaSH recommended):** Settings → Media Management → Episode Naming
   - **Rename Episodes:** ✅
   - **Standard Episode Format:** `{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}`
   - **Daily Episode Format:** `{Series TitleYear} - {Air-Date} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}`
   - **Anime Episode Format:** `{Series TitleYear} - S{season:00}E{episode:00} - {absolute:000} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels}{MediaInfo AudioLanguages}]{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec][ Mediainfo VideoBitDepth]bit}{-Release Group}`
   - **Season Folder Format:** `Season {season:00}`
   - **Series Folder Format:** `{Series TitleYear} [tvdbid-{TvdbId}]`
   - **Multi-Episode Style:** Prefixed Range

   > These follow [TRaSH Guides Sonarr naming](https://trash-guides.info/Sonarr/Sonarr-recommended-naming-scheme/). After saving, rename existing files: Series → Select All → Organize.

7. **Block ISOs:** Some indexers serve disc images that Jellyfin can't play.
   - Settings → Custom Formats → + → Name: `Reject ISO`
   - Add condition: Release Title, value `\.iso$`, check **Regex**
   - Settings → Profiles → your quality profile → set `Reject ISO` to `-10000`

## 4.4 Radarr (Movies)

Searches for movies, sends download links to Decypharr (torrents) or the Blackhole client
(usenet), and organizes completed files.

1. **Access:** `http://NAS_IP:7878`
2. **Create admin account** when prompted
3. **Add Root Folder:** Settings → Media Management → `/data/media/movies`
4. **Add Download Client(s):** Settings → Download Clients

   **Decypharr / TorBox (torrents):** *(setup in [TorBox (Decypharr)](SETUP.md#adding-more-services-core))*
   - Add → qBittorrent (Decypharr speaks the qBittorrent Web API)
   - Host: `decypharr` (Decypharr is on the bridge, same as Radarr — no VPN hop needed)
   - Port: `8282`
   - **Username:** `http://radarr:7878` (Radarr's own URL — not a real qBittorrent login; this is
     how Decypharr identifies which Arr is calling, matched against its own `arrs` config)
   - **Password:** Radarr's API key (Settings → General → API Key)
   - Category: `movies`

   **Usenet Blackhole:** *(added by `configure-apps.sh`)*
   - Add → Blackhole
   - NZB Folder: `/data/usenet/blackhole/nzb`
   - Watch Folder: `/data/usenet/blackhole/complete`
   - There is no host or API key, because no usenet server is involved: a timer moves each NZB
     between those two folders through TorBox's API — see [§4.2](#42-usenet-torbox-blackhole)
   - No category (the Blackhole client has no such field)

5. **Enable NFO metadata:** Settings → Metadata → Kodi (XBMC) / Emby → **Enable** (see [why this matters](#nfo-metadata))
   - Movie Metadata: ✅
   - Movie Images: ❌ (Jellyfin handles its own artwork)

6. **Configure naming (TRaSH recommended):** Settings → Media Management → Movie Naming
   - **Rename Movies:** ✅
   - **Standard Movie Format:** `{Movie CleanTitle} {(Release Year)} {imdb-{ImdbId}} - {Edition Tags }{[Custom Formats]}{[Quality Full]}{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}`
   - **Movie Folder Format:** `{Movie CleanTitle} ({Release Year})`

   > These follow [TRaSH Guides Radarr naming](https://trash-guides.info/Radarr/Radarr-recommended-naming-scheme/). After saving, rename existing files: Movies → Select All → Organize.

7. **Block ISOs:** Some indexers serve disc images that Jellyfin can't play.
   - Settings → Custom Formats → + → Name: `Reject ISO`
   - Add condition: Release Title, value `\.iso$`, check **Regex**
   - Settings → Profiles → your quality profile → set `Reject ISO` to `-10000`

### Prefer Usenet over Torrents (Optional)

With both Decypharr and the Blackhole client enabled, Sonarr/Radarr grab whichever release scores
first. To prefer Usenet (faster, no seeding):

1. Settings → Profiles → Delay Profiles
2. Click the **wrench/spanner icon** on the existing profile (don't click +)
3. Set: **Usenet Delay:** `0` minutes, **Torrent Delay:** `30` minutes
4. Save

This gives Usenet a 30-minute head start before considering torrents.

> **Note:** Do this in both Sonarr and Radarr (same steps in each).

**Client priority:** Decypharr is the only torrent client, so there is nothing to rank it against.
Its **Priority** field (Settings → Download Clients → edit the client → Priority, `1` = tried
first, `50` = tried last) still matters if you add a second client later: give the one you want
tried first the lower number.

### NFO Metadata

> **Applies to both Sonarr (step 4 above) and Radarr (step 4 above).**
>
> **Why this matters:** Without NFO files, Jellyfin identifies media by guessing from the filename. For movies or shows with common titles shared by multiple entries on TMDB, it can match the wrong one. When the TMDB IDs don't agree between Radarr/Sonarr and Jellyfin, Seerr can't link them — so requests stay stuck at "Requested" even though the file is downloaded and playable.
>
> Enabling NFO metadata makes Radarr/Sonarr write a small `.nfo` file alongside each media file containing the correct TMDB/IMDB/TVDB IDs. Jellyfin reads these instead of guessing. This eliminates the entire class of metadata mismatch bugs.
>
> **After enabling:** Run a full library refresh to write NFOs for existing media. In Radarr: Movies → Update All. In Sonarr: Series → Update All. New downloads will get NFOs automatically.

## 4.5 Prowlarr (Indexer Manager)

Manages torrent/Usenet indexers and syncs them to Sonarr/Radarr.

1. **Access:** `http://NAS_IP:9696`
2. **Create admin account** when prompted
3. **Add Torrent Indexers:** Indexers (left sidebar) → + button → search by name
4. **If using Usenet: Add Usenet Indexer**
   - **Indexers** (left sidebar, NOT Settings → Indexer Proxies) → + button
   - Search by indexer name (e.g., "NZBGeek", "Usenet-Crawler") — use **Generic Newznab** if
     Prowlarr has no built-in definition for your indexer, with Url `https://<indexer-host>` and
     API Path `/api`
   - API Key: (from your indexer account → profile/API section)
   - **Tags:** leave blank (syncs to all apps)
   - **Indexer Proxy:** leave blank (not needed for Usenet)
   - Test → Save

   > **Tested with:** a paid Usenet-Crawler account, real search results confirmed working via
   > Generic Newznab. NZBGeek (~$12/year) is another paid option. **Avoid:** NZBFinder's free tier
   > has no API access (search returns "premium member required" even with a valid key);
   > DrunkenSlug's registration is currently closed; TorBox's own `search-api.torbox.app`
   > Newznab/Torznab endpoint (documented in their changelog) currently doesn't resolve in DNS at
   > all — confirmed via TorBox's own authoritative nameserver, not just a local issue.

   > **Full pipeline verified end-to-end (2026-08-15), back when SABnzbd was the usenet client:**
   > Usenet-Crawler search → Radarr grab → SABnzbd download/repair/unpack → Radarr hardlink-import,
   > all confirmed with a real movie grab. That half is historical: Sonarr and Radarr now use a
   > UsenetBlackhole client, and
   > [usenet-blackhole.timer](MAINTENANCE.md#usenet-blackhole-systemd-timer-every-2-minutes)
   > hands each grabbed NZB to TorBox instead (see [§4.2](#42-usenet-torbox-blackhole)). The TorBox
   > credentials note below still applies if you point SABnzbd at a provider. One gotcha along the way: SABnzbd's TorBox NNTP server (`nntp.torbox.app:563`) rejected
   > login with a generic `482 Invalid username or password` even though the credentials matched
   > what was on file — this looked like a rate limit (TorBox's `/v1/api/user/me` showed a
   > `cooldown_until` field at the time) but was actually just **stale/incorrect Usenet
   > credentials**. Regenerating the username+password from TorBox's Usenet settings page fixed it
   > immediately. If you hit `482` errors, regenerate the credentials before assuming it's a
   > plan-tier limit.

4. **Add FlareSolverr** (for protected torrent sites):
   - Settings → Indexers → Add FlareSolverr
   - Host: `http://localhost:8191` (FlareSolverr shares Gluetun's network with Prowlarr)
   - Tag: `flaresolverr`
   - **Note:** FlareSolverr doesn't bypass all Cloudflare protections - some indexers may still fail. If you have issues, [Byparr](https://github.com/ThePhaseless/Byparr) is a drop-in alternative using different browser tech.
5. **Connect to Sonarr:**
   - Settings → Apps → Add → Sonarr
   - Prowlarr Server: `http://gluetun:9696` (how Sonarr reaches Prowlarr, which is behind the VPN)
   - Sonarr Server: `http://172.20.0.10:8989` (Prowlarr is inside gluetun's namespace where DNS can't resolve container names — use Sonarr's bridge IP)
   - API Key: (from Sonarr → Settings → General → Security)
6. **Connect to Radarr:** Same process — Radarr Server: `http://172.20.0.11:7878`
7. **Sync:** Settings → Apps → Sync App Indexers

## 4.6 Trakt (Watched-status sync + list-based suggestions)

Two independent integrations — install/configure separately, they don't depend on each other.

**Jellyfin (watched-status sync, scrobbling):**
1. Install the **Trakt** plugin: Dashboard → Plugins → Catalog → Trakt → Install → restart Jellyfin
2. Dashboard → Plugins → Trakt → configure per-user, click **Authorize** → note the device code
   shown → visit `https://trakt.tv/activate` in a browser, sign in (Trakt is passwordless now —
   it emails a magic sign-in link, no password prompt), enter the code, approve
3. Confirms via the plugin's config page once approved; access/refresh tokens are stored and
   auto-renew

**Sonarr/Radarr (auto-add from Trakt lists — watchlist, trending, a specific list URL, etc.):**
1. Settings → Import Lists → Add → **Trakt User List** (personal watchlist/watched/collection) or
   **Trakt List** (any public list URL) or **Trakt Popular List** (no auth needed)
2. For the user-authenticated types, click **Authenticate with Trakt** inside the Add-list modal —
   this opens Trakt's OAuth consent in a popup, backed by Servarr's own shared OAuth proxy
   (`auth.servarr.com`), not something this stack configures directly

> **Trakt free-tier gotcha:** free Trakt accounts allow only **one** connected third-party app at
> a time — Jellyfin, Sonarr, and Radarr each count separately (different registered client IDs).
> Connecting a second one kicks the first. **Trakt VIP removes this limit** and lets all three
> stay connected simultaneously.

> **Known issue (confirmed 2026-08-15, still open):** Sonarr/Radarr's Trakt OAuth fails with
> `Received oauth token was invalid`. Clicking "Authenticate with Trakt" *does* complete Trakt's
> own login step (it shows up under Trakt → Settings → Apps → Connected Apps, "last used" just
> now) — but the token-exchange step that hands a real token back to Sonarr/Radarr fails, so no
> import list ever actually gets saved (confirmed empty `GET /api/v3/importlist` on both apps even
> right after a "successful" login). Root cause per
> [Radarr/Radarr#11579](https://github.com/Radarr/Radarr/issues/11579) (closed `not planned`, but
> with a precise technical writeup from a Radarr contributor): Trakt migrated its OAuth backend in
> mid-July 2026, and its authorize endpoint now silently 307-redirects the legacy request into a
> PKCE flow, injecting a server-generated `code_challenge` that Sonarr/Radarr never sent — so
> `auth.servarr.com`'s proxy has no matching `code_verifier` to present at the token-exchange step
> and it fails every time. As of the same thread's Aug 11 update, Trakt has also moved API access
> behind its VIP paywall for developers, which a Radarr maintainer cited as the reason this isn't
> being actively worked on — **no fix timeline, no known workaround.** (An earlier version of this
> note cited [Radarr/Radarr#7905](https://github.com/Radarr/Radarr/issues/7905) — that was wrong,
> it's an unrelated, long-closed 2022 issue; disregard it.) See also
> [trakt/trakt-api#663](https://github.com/trakt/trakt-api/issues/663). Jellyfin's plugin is
> unaffected because it uses Trakt's native device-code flow directly, bypassing Servarr's proxy
> entirely. Nothing to fix in this repo — retry once upstream patches it.

## 4.7 Seerr (Request Manager)

Lets users browse and request movies/TV shows.

1. **Access:** `http://NAS_IP:5055`
2. **Sign in with Jellyfin:**
   - Jellyfin URL: `http://jellyfin:8096`
   - Enter Jellyfin credentials
3. **Set Jellyfin External URL:** Settings → Jellyfin → **External URL:** `https://jellyfin.lan` (or `http://NAS_IP:8096`) — makes "Play on Jellyfin" links work in your browser
4. **Configure Services:**
   - Settings → Services → Add Radarr:
     - **Hostname:** `radarr` (Radarr is on the bridge with its own Docker DNS name)
     - **Port:** `7878`
     - **Quality Profile:** `UHD Bluray + WEB` (ensures all requests get the best available quality)
     - **External URL:** `http://radarr.lan` (or `http://NAS_IP:7878`) — makes "Open in Radarr" links work in your browser
   - Settings → Services → Add Sonarr:
     - **Hostname:** `sonarr`
     - **Port:** `8989`
     - **Quality Profile:** `Ultra-HD`
     - **External URL:** `http://sonarr.lan` (or `http://NAS_IP:8989`)
5. **Enable Jellyfin Libraries:** Settings → Jellyfin → toggle **Movies** and **TV** on → Save
6. **Sync Libraries:** On the same page, click **Sync Libraries** then **Start Scan**

> **Why libraries matter:** Without this, Seerr doesn't know what's already in your Jellyfin library. Movies and shows will stay stuck at "Requested" even after they're downloaded and playable.

## 4.8 Bazarr (Subtitles)

Automatically downloads subtitles for your media.

1. **Access:** `http://NAS_IP:6767`
2. **Enable Authentication:** Settings → General → Security → Forms
3. **Connect to Sonarr:** Settings → Sonarr → Address `sonarr`, Port `8989` (Sonarr is on the bridge)
4. **Connect to Radarr:** Settings → Radarr → Address `radarr`, Port `7878` (Radarr is on the bridge)
5. **Add Providers:** Settings → Providers (OpenSubtitles, etc.)
6. **Enable Subtitle Sync:** Settings → Subtitles → Subtitle Synchronization:
   - **Subtitle Synchronization:** On — enables `ffsubsync` to re-time subtitles against the audio track
   - **Series Score Threshold:** On (default 90) — auto-syncs series subs scoring below this
   - **Movies Score Threshold:** On (default 70) — auto-syncs movie subs scoring below this

   > **Why:** Jellyfin's web player has no manual subtitle delay control. If subs are out of sync, the only fix is re-timing the subtitle file itself — which is exactly what this does.

## 4.9 DNS

**There is no DNS service in this stack any more.** Pi-hole and its
dnscrypt-proxy sidecar were removed on 2026-09-21; AdGuard Home on the router
answers for the house, and the warning that used to sit here about the NAS going
down taking DNS with it is the reason. Nothing in `.env` configures it.

- The arrangement, and what to do when a name does not resolve: [LOCAL-DNS.md](LOCAL-DNS.md)
- How it got there, and what it cost: [DNS-MIGRATION.md](DNS-MIGRATION.md)

---

**Next step:** Return to [Setup Guide → Step 5: Check It Works](SETUP.md#step-5-check-it-works)
