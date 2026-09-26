# The TorBox API, and how this stack uses it

TorBox is where every byte of media in this stack actually comes from. Decypharr
hands it torrents; the usenet watcher hands it NZBs. Both then download a
finished file back over HTTPS. Nothing here joins a swarm or opens a usenet
connection, so the provider's API is the load-bearing dependency, and getting a
detail wrong shows up as a stalled queue rather than as an error.

This page has two kinds of statement, and keeps them apart:

- **Documented** — what TorBox itself publishes, each with its source. This is
  the source of truth. Where the repo and TorBox's docs disagree, the docs win
  until a measurement says otherwise.
- **Measured** — what this stack has observed and TorBox does not document. Each
  is dated. A measured fact is only as good as the method behind it; two of them
  turned out wrong once re-read against the docs (see
  [TORBOX-AUDIT-2026-09-26.md](TORBOX-AUDIT-2026-09-26.md)).

> **Documented facts were re-read in full on 2026-09-26** from the API reference
> and all seven help-center collections. Re-fetch before trusting a detail that
> matters:

```bash
curl -s "https://documenter.gw.postman.com/api/collections/29572726/2s9YXo1zX4" \
  > /tmp/torbox-collection.json
```

That is the Postman collection behind <https://api-docs.torbox.app/>, which is a
rendered view of it rather than a document with its own URLs. `openapi.json`,
`swagger.json` and friends return 404 on that host; TorBox also serves a thinner
FastAPI view at <http://api.torbox.app/docs>. The help center is
<https://support.torbox.app/>; the collections that matter here are
[Downloads](https://support.torbox.app/en/collections/10369529-downloads),
[Usenet](https://support.torbox.app/en/collections/10369623-usenet),
[Torrents](https://support.torbox.app/en/collections/10367765-torrents),
[Web Downloads](https://support.torbox.app/en/collections/10369622-web-downloads),
[Integrations](https://support.torbox.app/en/collections/10369620-integrations)
and [Technical](https://support.torbox.app/en/collections/18398135-technical).

---

# Part 1 — What TorBox documents

Sources are abbreviated: **API** is the Postman collection above; a help-center
article is linked by title.

## Base, versioning, response contract

Base `https://api.torbox.app`, version `v1`, every path under `/v1/api/`. Every
response carries the same envelope (API):

```json
{ "success": true, "error": null, "detail": "human-readable", "data": {} }
```

> "Status code `200` always means a success. `403` means authentication error.
> `500` means something went wrong on TorBox's end. `400` means the user did
> something wrong, or an input wasn't correct, or expected." — API

`error` is a code from a fixed enum (below). "If the code ends in 'ERROR', the
error is the server's fault else that error is something that the client
caused." Dates are UTC, `%Y-%m-%dT%H:%M:%SZ`.

**A response that is not this envelope did not come from TorBox's application.**
A plain-text body such as `error code: 1010` is the CDN in front of it, not the
API — see *Measured: the 403 / 1010 refusal* below.

## Authorization

| Mechanism | Used by |
|---|---|
| `Authorization: Bearer <key>` header | everything except the three below |
| `?token=<key>` **query parameter** | `requestdl` (torrents, usenet, webdl) and `notifications/rss` |
| none | `/`, `stats`, `changelogs/*`, `speedtest`, `usenet/provider/connection`, `torrents/torrentinfo`, `torrents/magnettofile`, `user/auth/device/*` |

Measured (2026-09-14): `requestdl` answers `422`
`{"detail":[{"type":"missing","loc":["query","token"]}]}` when given the header
alone. The link it returns carries the account token in its own query string
(`https://tb-cdn.xx/dld/<uuid>?token=<uuid>`), so passing it as a command-line
argument puts the key in `/proc/<pid>/cmdline` for every user on the box;
`scripts/lib/usenet_blackhole.py` downloads through a curl config on stdin
instead. The same rule applies to any new call site.

## Rate limits

> "Unless stated below, all endpoints are rate limited to 300/min per API token,
> no edge rate limiting." — API

| Endpoint | Limit |
|---|---|
| everything | 300/min per API token |
| `POST /usenet/createusenetdownload` | 60/hour per API token |
| `POST /webdl/createwebdownload` | 60/hour per API token |
| `POST /torrents/createtorrent` | 60/hour for **uncached** items, and every call also counts against the 300/min |

"Synchronized across all our servers", per key, "subject to change"
([API Rate Limits](https://support.torbox.app/en/articles/13726368-api-rate-limits)).
TorBox no longer accepts IP-whitelisting requests "due to rate limiting being
API token based, rather than IP based" (API).

**Not documented:** the status code or body of a rate-limit refusal, and any
`Retry-After`. What this stack sees is under *Measured*.

A separate, per-link limit applies to CDN downloads: using the same link from
more than one app or device at once can earn `429 Too Many Requests`; TorBox
recommends "Max connections: 4 or less" per link
([Why Are My Download Links Not Working?](https://support.torbox.app/en/articles/15315517-why-are-my-download-links-not-working)).

## Plans and active slots

`GET /user/me` returns `plan` as an integer. The mapping is documented (API) and
is not ordered by price:

| `plan` | Plan |
|---|---|
| `0` | Free |
| `1` | Essential ($3) |
| `2` | **Pro ($10)** — this account |
| `3` | Standard ($5) |

Pro-gated endpoints refuse with `PLAN_RESTRICTED_FEATURE` and say "Pro (plan: 2)"
in their own text, so `plan == 2` is a direct check, not an inference.

`cooldown_until` is the timestamp in a `COOLDOWN_LIMIT` refusal ("User is on
download cooldown. It is recommended user upgrade their account"), the Free
plan's one-download-per-24h rule. It is not a rate-limit window, and it has no
meaning on Pro.

Per [Account Restrictions](https://support.torbox.app/en/articles/9836418-account-restrictions):

| Plan | Active slots | Max per download |
|---|---|---|
| Free | 1 | 10 GiB |
| Essential | 3 | 200 GiB |
| Standard | 5 | 200 GiB |
| **Pro** | **10** — "10 active torrents, which allows you a total of 10 concurrent downloads" | 500 GiB per the API's `DOWNLOAD_TOO_LARGE` table (the article says 1 TB) |

"Cached items, which are already stored on TorBox servers, do not count toward
your active slot limit." **The docs do not say whether usenet and web downloads
draw from the same ten as torrents.** The wording ("a total of 10 concurrent
downloads", "the maximum slot limit available") leans that way. It is
measurable: an `ACTIVE_LIMIT` refusal carries
`data: {"active_limit", "current_active_downloads"}`, and comparing that count
with the usenet jobs in flight at the same moment settles it. Until then, treat
the budget as shared — this stack runs Decypharr at 5 and the usenet watcher at
6, which is 11.

Queued downloads have their own ceiling: "maximum queued downloads limit of
1000" (`DIFF_ISSUE`, API). The queue is processed "every 3 hours"
([Why Do Queued Downloads Not Start?](https://support.torbox.app/en/articles/10293822-why-do-queued-downloads-not-start)).

## Downloading a finished item: `requestdl`

Same model for torrents, usenet and webdl; only the id parameter differs
(`torrent_id` / `usenet_id` / `web_id`).

| Parameter | Meaning |
|---|---|
| `token` | API key (query parameter, required) |
| `*_id` | the item |
| `file_id` | one file of the item |
| `zip_link` | the whole item as a zip; "Required if no file_id. Takes precedence over file_id if both given" (SDK docstring) |
| `user_ip` | pick the CDN closest to that IP |
| `redirect` | answer `307` to the CDN URL instead of returning it — the permalink form |
| `append_name` | present in every URL template, described nowhere |

**Link lifetime.** "This endpoint opens the link for 3 hours for downloads. Once
a download is started, the user has nearly unlimited time to download the file."
(API; the same paragraph also says "1 hour", an inconsistency in TorBox's text.)
The help center states 3 hours without qualification. A link is for *starting*
a transfer; do not store one. The durable form is the permalink:

```
https://api.torbox.app/v1/api/usenet/requestdl?token=KEY&usenet_id=N&file_id=N&redirect=true
```

**Zip versus per-file — the difference is large**
([Why Are Zip Files Slow…](https://support.torbox.app/en/articles/15030073-why-are-zip-files-slow-downloading-to-my-computer),
[How To Debug Slow Download Speeds](https://support.torbox.app/en/articles/16168587-how-to-debug-slow-download-speeds)):

| | Per-file link | Zip link |
|---|---|---|
| Connections | "up to 16 connections per file" | one; "zips cannot be multi-connection" |
| Served from | the CDN (`*.tb-cdn.*`) | "only … the main storage servers in WNAM and WEUR" |
| Built | already exists | "generated on the fly", "require a lot of compute", deprioritised under load |
| Interrupted | resumable (HTTP range) | "forces a restart from the beginning" |

For usenet the per-file route is also the one that uses TorBox's own
post-processing: with the default `post_processing=-1` the item's `files[]` is
already the repaired, extracted payload.

## Listing items: `mylist`

`GET /{torrents,usenet,webdl}/mylist` with `bypass_cache`, `id` (returns one
object instead of a list), `offset` (default 0), `limit` (default 1000).

| Type | Freshness (API) |
|---|---|
| usenet, webdl | "updated on its own every 5 seconds for live … downloads" |
| **torrents** | "only gets updated every **600 seconds**" unless the cache is bypassed |

A poll of torrent state that does not send `bypass_cache=true` can go ten
minutes without seeing a change.

An empty list is `ITEM_NOT_FOUND` **with `"success": true`** — a documented
quirk; do not read `success` alone.

Record fields (usenet): `id`, `hash`, `name`, `size`, `download_state`,
`progress`, `download_speed`, `eta`, `active`, `cached`, `cached_at`,
`download_present`, `download_finished`, `expires_at`, `server`,
`files[]` (`id`, `name`, `short_name`, `absolute_path`, `size`, `mimetype`,
`md5`, `infected`, `zipped`, …), `tags`, `alternative_hashes`, `airlocked`.
Torrents add `seeds`, `peers`, `ratio`, `availability`, `tracker`, … ; webdl adds
`error`.

### States

Torrent `download_state` is documented (API): `downloading`, `uploading`,
`stalled (no seeds)`, `paused`, `completed`, `cached`, `metaDL`,
`checkingResumeData`, and "all other statuses are basic qBittorrent states". Of
`completed`: **"Do not use this for download completion status."** Completion is
`download_finished` (with `download_present` for "the files are on TorBox").

Usenet `download_state` has **no documented enum**. Measured values are listed
under *Measured*. The same two booleans exist on usenet records and are the
documented completion signal.

The dashboard's status vocabulary
([Download Statuses](https://support.torbox.app/en/articles/9928977-download-statuses)):
Downloading; Stalled (No seeds); Uploading; MetaDL; **Failed** — "server error,
a missing encryption key, missing par2 files, or anything else"; **Failed
(Processing)** — failed TorBox's mandatory post-download step, "delete and
re-add"; **Expired**; **(Reported) Missing**; **Incomplete** — a torrent with no
progress for 2 days.

## Creating a usenet download

`POST /usenet/createusenetdownload`, multipart (API):

| Field | Meaning |
|---|---|
| `file` / `link` | the NZB, or a URL to one ("Cannot be a redirection"); exactly one |
| `name` | display name |
| `password` | "used for extracting the RAR at the end" |
| `post_processing` | see below |
| `as_queued` | put it straight into the queue |
| `add_only_if_cached` | refuse with `DOWNLOAD_NOT_CACHED` unless cached |

Returns `data: {hash, usenetdownload_id, auth_id}`. NZB files over 100 MB are
refused (`TOO_MUCH_DATA`); not an NZB is `BOZO_NZB`.

| `post_processing` | Behaviour (API) |
|---|---|
| `-1` | **Default.** "runs repairs, and extractions as well as deletes the source files leaving only the wanted downloaded files" |
| `0` | none — every file, PAR2 included |
| `1` | PAR2 verify and repair |
| `2` | repair and unpack, keeping the RAR/ZIP files |
| `3` | repair, unpack, delete the archives |

"It is recommended you either don't send this parameter, or keep it at `-1`."

`POST /usenet/controlusenetdownload` takes `{usenet_id, operation, all}`. The
body comment lists `delete`, `pause`, `resume`; the `INVALID_OPTION` example
lists only `delete`. `delete` removes the item and its files.

`checkcached` (GET, ~100 hashes a call, or POST with a list) answers from a
one-hour cache. How TorBox hashes an NZB is described
([Getting Hashes For Searches](https://support.torbox.app/en/articles/13681109-technical-getting-hashes-for-searches)):
"NZB files — clean then MD5 the whole NZB", or "MD5 of the first message ID per
file segment". "Clean" is not defined, which is why no client-side derivation
has matched (see *Measured*).

## Retention on TorBox

- Files are stored "for at least 30 days", longer if popular, never guaranteed
  ([How Long Are TorBox Files Stored For?](https://support.torbox.app/en/articles/9961332-how-long-are-torbox-files-stored-for)).
- "Any downloads not downloaded within 30 days of being cached are removed";
  WebDAV access does not reset the timer
  ([Why Is My Download Inactive?](https://support.torbox.app/en/articles/10333785-why-is-my-download-inactive)).
- NZBs themselves are not stored: an item added by file cannot be re-downloaded
  from the dashboard ([Re-Download Action](https://support.torbox.app/en/articles/13875800-re-download-action-in-torbox)).

## TorBox's usenet provider (NNTP)

Pro includes a conventional usenet server, separate from the API pipeline:
downloads through it "do NOT appear on the dashboard and do NOT use the TorBox
cache" ([TorBox News Server](https://support.torbox.app/en/articles/15531672-torbox-news-server)).

| | Documented |
|---|---|
| Host | `nntp.torbox.app:563`, TLS (`GET /usenet/provider/connection`) |
| Retention | `"retention": 5000` (API); "3900+ days" (article) |
| Completion | "99.8%" |
| Connections | 10 per account |
| Location | EU |
| Credentials | generated by `GET /usenet/provider/account`, shown once; `POST …/resetpw` regenerates |
| Clients | "NZBHydra, SABnzbd, NZBGet, NZBDav, Usenet Streamer, Stremio" |

"Older NZBs may sit on cold storage or with partner providers", which is slower
([Why Are My Usenet Transfers To TorBox Slow?](https://support.torbox.app/en/articles/15300133-why-are-my-usenet-transfers-to-torbox-slow)).
This stack measured something much shorter than the documented retention; see
*Measured*.

## Other access paths

- **WebDAV** `https://webdav.torbox.app`, user = email (or `torbox`), password =
  account password or API key; read-only except delete, which deletes for real;
  the tree refreshes every 15 minutes
  ([TorBox WebDAV](https://support.torbox.app/en/articles/14662867-torbox-webdav)).
- **T3**, S3-compatible, `https://t3.nexus`, Auth ID + API key, read-only,
  15-minute refresh ([TorBox T3](https://support.torbox.app/en/articles/15531689-torbox-t3)).
- The one arr guide TorBox publishes is RDTClient in Docker
  ([How To: Setup RDTClient](https://support.torbox.app/en/articles/10167535-how-to-setup-rdtclient-with-torbox-docker)).

## Error enum

From the API's errors table. Codes ending in `ERROR` are server-side.

| Code | Meaning |
|---|---|
| `DATABASE_ERROR` | internal store unavailable |
| `UNKNOWN_ERROR` | unknown; details in `data` |
| `NO_AUTH` / `BAD_TOKEN` / `AUTH_ERROR` | missing / invalid / unverifiable credentials |
| `INVALID_OPTION` / `MISSING_REQUIRED_OPTION` / `TOO_MANY_OPTIONS` | bad input |
| `REDIRECT_ERROR`, `OAUTH_VERIFICATION_ERROR` | redirect / OAuth failures |
| `ENDPOINT_NOT_FOUND`, `ITEM_NOT_FOUND` | not found (`ITEM_NOT_FOUND` on `mylist` comes with `success: true`) |
| `PLAN_RESTRICTED_FEATURE` | higher plan needed |
| `DUPLICATE_ITEM` | already exists |
| `TOO_MUCH_DATA` | request over 100 MB |
| `DOWNLOAD_TOO_LARGE` | over the plan's per-download size |
| `BOZO_TORRENT`, `BOZO_NZB`, `BOZO_RSS_FEED`, `BOZO_REGEX`, `BOZO_FILE` | malformed input |
| `NO_SERVERS_AVAILABLE_ERROR` | "should never happen" |
| `MONTHLY_LIMIT`, `COOLDOWN_LIMIT` | Free-tier limits |
| `ACTIVE_LIMIT` | "hit their max active download limit" |
| `DOWNLOAD_SERVER_ERROR` | download-server trouble; "wait some time before trying again" |
| `DOWNLOAD_NOT_CACHED` | `add_only_if_cached` and it wasn't |
| `SEARCH_ERROR`, `INVALID_DEVICE`, `DIFF_ISSUE`, `LINK_OFFLINE`, `VENDOR_DISABLED`, `BAD_CONFIRMATION`, `CONFIRMATION_EXPIRED` | as named |

Endpoint examples also use `NOT_OWNER` (409), `NO_CHANGES`, `NAME_TOO_LONG`,
`NAME_TOO_SHORT`, `INVALID_HASH`, `NOT_CACHED`, `UNSUPPORTED_SITE`,
`TEMPORARILY_DISABLED`, `INVALID_LINK`, `DEVICE_CODE_NOT_USED`,
`STREAM_INFO_ERROR`. **There is no `1010`, and no rate-limit code.**

## The endpoint inventory

65 endpoints under 10 folders.

| Folder | Endpoints |
|---|---|
| Torrents | `createtorrent`, `asynccreatetorrent`, `controltorrent`, `requestdl`, `mylist`, `checkcached` (GET and POST), `exportdata`, `torrentinfo` (GET and POST), `edittorrent`, `magnettofile` |
| Usenet | `createusenetdownload`, `controlusenetdownload`, `requestdl`, `mylist`, `checkcached` (GET and POST), `editusenetdownload`, `provider/connection`, `provider/account`, `provider/account/resetpw` |
| Web Downloads | `createwebdownload`, `controlwebdownload`, `requestdl`, `mylist`, `checkcached` (GET and POST), `hosters`, `editwebdownload` |
| General | up status, `stats`, `changelogs/rss`, `changelogs/json`, `speedtest` |
| Notifications | `notifications/rss`, `mylist`, `clear`, `clear/{id}`, `test` |
| User | `me`, `refreshtoken`, `addreferral`, `getconfirmation`, `auth/device/start`, `auth/device/token`, `referraldata`, `subscriptions`, `transactions`, `transaction/pdf`, `settings/editsettings`, `stats` |
| RSS Feeds | `addrss`, `controlrss`, `modifyrss`, `getfeeds`, `getfeeditems` (Pro) |
| Integrations | `integration/jobs`, `integration/job/{id}` (GET and DELETE), `integration/jobs/{hash}` |
| Queued | `queued/getqueued`, `queued/controlqueued` (`start`, `delete`) |
| Stream | `stream/createstream`, `stream/getstreamdata` (Pro) |

---

# Part 2 — Measured, not documented

Each of these is this stack's observation. Keep them, but do not promote them
into the documented section without a TorBox source.

**The two refusals `submit()` handles** (2026-09-14):

- `createusenetdownload` over its hourly budget answers
  `HTTP 429: {"detail":"60 per 1 hour"}`, no `Retry-After`. Not the standard
  envelope.
- An 11th concurrent usenet download answers `HTTP 500`
  `{"success":false,"error":"ACTIVE_LIMIT","detail":"You have reached your active download limit of 10.","data":{"active_limit":10,"current_active_downloads":10}}`.
  The code is documented; the 500 status is not, and 500 is shared with
  `DOWNLOAD_SERVER_ERROR`, `UNKNOWN_ERROR` and others, so classify on `error`,
  never on status.

Over 76 logged passes that day, 37 submissions were accepted and 47 refused,
22 of them by the hourly cap alone. `submit()` now backs off on both: a `429`
stops the submission loop and persists `rate_limited_until` (one hour) in the
state file; `ACTIVE_LIMIT` stops the loop for this pass only, since a slot frees
by itself.

**Usenet failure is a prefix, not a word.** `download_state` comes back as
`failed (Aborted, cannot be completed - https://sabnzbd.org/not-complete)`, the
reason in parentheses. Other values seen: `completed`, `cached`, `processing`,
`downloading`, `queued`. Both cases of the first letter have been seen.

**`progress` moves while bytes arrive.** `download_state` says `downloading` for
a job that is downloading nothing, so `--stall-hours` reads `progress`. Its
scale (0-1 or 0-100) has not been pinned down.

**The default post-processing does not always apply.** On 2026-09-14, 12 of 31
completed usenet items still delivered RAR volumes — 47 parts each for the
`TENEIGHTY` releases. The watcher unpacks locally to compensate. Whether TorBox
declined because the set was damaged is not known.

**`checkcached` cannot be a pre-flight check** (2026-09-17, 327 jobs). No
client-side derivation of the NZB hash matched a real job's — sixteen were tried:
MD5 of the raw bytes, the release name (with and without `.nzb`, lowercased), the
basename, the first/last segment message-id (bare and bracketed), every
message-id concatenated (document order, sorted, newline-joined), the first and
all `subject` attributes, the sorted group list, the whitespace-stripped file,
and the size. TorBox's own description ("clean then MD5") does not define the
cleaning. And even with the hash, `cached` is written after the bytes arrive: it
was true for 167 of 167 completed jobs and false for 155 of 155 failed ones, and
empty for a job still downloading. A gate on it would refuse every new release.

**`nntp.torbox.app` has no ~90-day cutoff** (re-measured 2026-09-26, `STAT`
and `BODY`, 209 NZBs, SABnzbd's own credentials). Releases up to 1303 days old
are fully present; what is missing is per-release article loss, whose rate rises
with age: 5/5 releases under 90 days had every probed segment, 8/21 at 90-364
days, 32/110 at 365-999, 18/73 at 1000+. `STAT` and `BODY` agreed on all 372
refused segments, so `STAT` is a valid probe here. The 2026-09-14 "~90 days"
reading (1/34/60/86-day found, 101/138-day `430`) was eight releases generalised
into a rule. The API path aborts on missing articles too (898 `aborted, cannot be
completed` since 2026-09-14); whether it completes materially more than the news
server is the open question — see the audit, A1.

### The 403 / 1010 refusal

On 2026-09-13 every `requestdl` call answered `403` with a plain-text body
`error code: 1010`, for about 90 minutes, then cleared with no change on this
side. Links already issued kept working. `docs/TROUBLESHOOTING.md` records the
incident and its probe.

Read against the docs, **this was almost certainly not TorBox's API refusing the
account**: the API's 403s are JSON `NO_AUTH`/`BAD_TOKEN`, its rate limits are
"per API token, no edge rate limiting", and `1010` appears in no TorBox error.
`error code: 1010` as a bare body is Cloudflare's "banned browser signature" —
the same code this repo already diagnosed that way for Cinemeta
(`scripts/lib/stremio_library.py`, `docs/MAINTENANCE.md`). The likelier variable
is the *client signature* of the caller (Decypharr's Go client, curl's default
User-Agent), not the number of torrents queued. Not yet proven either way: the
next occurrence should capture the response headers (`cf-ray`, `server`) and
retry once with a browser User-Agent.

---

# Part 3 — How this stack uses it

## What this repo calls

Four endpoints, all usenet, all from `scripts/lib/usenet_blackhole.py`.
Decypharr speaks the torrent half itself; Magnetio calls the torrent half from
`magnetio/addon/moch/torbox.js`.

| Call | Where | Notes |
|---|---|---|
| `POST /usenet/createusenetdownload` | `TorBox.submit_file` | multipart NZB, `name`, `as_queued=false`; no `post_processing`, no `password` |
| `GET /usenet/mylist` | `TorBox.list_usenet` | `bypass_cache=true&limit=1000`, one page, polled every pass |
| `POST /usenet/controlusenetdownload` | `TorBox.delete_usenet` | `delete`, for stalled and timed-out jobs only |
| `GET /usenet/requestdl` | `TorBox.request_zip_link` | `zip_link=true`, token in the query |
| `GET /torrents/checkcached`, `POST createtorrent`, `GET mylist?id=`, `GET requestdl?file_id=` | Magnetio | per-file links (`zip_link=false`) |

`scripts/lib/queue_cleanup.py` mentions TorBox only in `DEBRID_CLIENT_PATTERNS`,
which matches a client *name* in an arr queue record. It makes no API call.

## `--max-inflight`

An operator-set ceiling on usenet jobs in flight, below TorBox's ten. The
script's default is `0` (off); the shipped unit
(`scripts/usenet-blackhole.service`) and `scripts/usenet-drain-walk.sh` run `6`.
Six sits below ten; it was not measured better. The evidence for wanting a
ceiling at all is that nine of ten slots were once held by jobs 3-21 h old while
only 4 of 50 submissions were fetched, and that an uncapped pass on 2026-09-18
submitted 46 jobs in an hour and left 60 incomplete. If the ten slots are shared
with torrents (see *Plans and active slots*), 6 plus Decypharr's 5 already
exceeds them. Reaching the ceiling spends no `createusenetdownload` call, because
the check runs before the upload.

## Open items

The full list, each with its TorBox source and the code it touches, is
[TORBOX-AUDIT-2026-09-26.md](TORBOX-AUDIT-2026-09-26.md). In short:

- **Fetch per file, not per zip.** The single largest change available to the
  NAS's disk load, and the documented fast path.
- **Compare completion, API vs. news server, on the same NZBs.** Retention is
  not the limit (above); if the API does not complete materially more, the API
  watcher is optional.
- **Use `download_finished`, delete after fetch, page through `mylist`, and
  expire jobs TorBox no longer lists.**
- **Settle whether the ten slots are shared**, from an `ACTIVE_LIMIT` body.

Two questions this page used to carry as open are closed. The retry pattern that
spent the hourly budget it was waiting on is fixed (`submit()` backs off, above).
`checkcached` as a pre-flight gate is ruled out (above).

Still unused, and deliberately so for now: `password` (protected releases fail
locally as permanent), `as_queued` and the Queued endpoints (processed only every
3 hours), `add_only_if_cached`, `user_ip`, `append_name`.

## The official SDKs, and why this stack does not use one

TorBox publishes generated, MIT-licensed SDKs under
[TorBox-App](https://github.com/TorBox-App): `torbox-sdk-py`, `-go`, `-js`,
`-java`, `-dotnet`, `-php`, all last pushed 2025-04-26. The Python one is on PyPI
as `TorBox` 0.1.0a1.

It would have caught one bug: `request_download_link1` puts `token` in the query,
the requirement that cost a failed fetch here. But the Python SDK's
`CreateUsenetDownloadRequest` models only `file` and `link` — no `name`,
`password`, `post_processing`, `as_queued` or `add_only_if_cached` — and it needs
`pydantic`, `click` and `requests` on a host with no pip. **Decision: keep the
hand-rolled client, read the SDKs when auditing.** Revisit when
`CreateUsenetDownloadRequest` grows a `post_processing` field.

## What Decypharr covers

The torrent half is Decypharr's own Go client. This repo controls its
configuration, in the `decypharr-config` volume (`docs/SETUP.md` has the
template):

| Setting | Value here | Effect |
|---|---|---|
| `debrids[].provider` | `torbox` | which provider it calls |
| `debrids[].download_uncached` | `true` | TorBox fetches uncached torrents on its own servers |
| `max_active_downloads` | `5` | its own ceiling (live config; not in the template) |
| `download_folder` | `/data/torbox` | where finished files land for the arr |
| `mount.type` | `none` | no mount, no local torrent engine |

The image is patched to treat a bare `400` from TorBox as retryable
([DECYPHARR-PATCH.md](DECYPHARR-PATCH.md)). What TorBox means by that 400 is not
documented — the API says only that 400 is "the user did something wrong" — so
the patch rests on observed behaviour, not on a TorBox statement.
