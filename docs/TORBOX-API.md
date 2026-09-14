# The TorBox API, and how this stack uses it

TorBox is where every byte of media in this stack actually comes from. Decypharr
hands it torrents; the usenet watcher hands it NZBs. Both then download a
finished file back over HTTPS. Nothing here joins a swarm or opens a usenet
connection, so the provider's API is the load-bearing dependency, and getting a
detail wrong shows up as a stalled queue rather than as an error.

This is the reference for that dependency: where the authoritative docs live,
what the API offers, what this repo actually calls, and what it is leaving on
the table.

> **This file described the API as published on 2026-09-14.** The upstream
> collection is the source of truth, not this page. Re-fetch before trusting a
> detail that matters:

```bash
curl -s "https://api-docs.torbox.app/api/collections/29572726/2s9YXo1zX4?environment=29572726-1b0d18ed-d45c-43f1-ad3f-253c7d41f915&segregateAuth=true&versionTag=latest" \
  > /tmp/torbox-collection.json
```

That is the Postman collection behind <https://api-docs.torbox.app/>, which is a
rendered view of it rather than a document with its own URLs. Fetching
`openapi.json`, `swagger.json` and friends off that host returns 404; the
collection endpoint above is the only machine-readable form.

## Authorization

Two mechanisms, and which one applies depends on the endpoint.

| Mechanism | Used by |
|---|---|
| `Authorization: Bearer <key>` header | everything except `requestdl` |
| `?token=<key>` **query parameter** | `requestdl`, both protocols |

`requestdl` needs the query parameter and does not accept the header alone. It
answers `422` with `{"detail":[{"type":"missing","loc":["query","token"]}]}`,
which is how a watcher that looked correct fetched nothing at all — see
`docs/TROUBLESHOOTING.md`.

The link it returns carries the account token in its own query string. Passing
that URL as a command-line argument puts the key in `/proc/<pid>/cmdline` for
every user on the box; `scripts/lib/usenet_blackhole.py` downloads through a
curl config on stdin instead. The same rule applies to any new call site.

## The endpoint inventory

65 endpoints under 10 folders. None of this is required reading; it is here so
that the next person can see what exists without re-fetching the collection.

| Folder | Endpoints |
|---|---|
| Torrents | `createtorrent`, `asynccreatetorrent`, `controltorrent`, `requestdl`, `mylist`, `checkcached` (GET and POST), `exportdata`, `torrentinfo` (GET and POST), `edittorrent`, `magnettofile` |
| Usenet | `createusenetdownload`, `controlusenetdownload`, `requestdl`, `mylist`, `checkcached` (GET and POST), `editusenetdownload`, `provider/connection`, `provider/account`, `provider/account/resetpw` |
| Web Downloads | `createwebdownload`, `controlwebdownload`, `requestdl`, `mylist`, `checkcached` (GET and POST), `hosters`, `editwebdownload` |
| General | up status, `stats`, `changelogs/rss`, `changelogs/json`, `speedtest` |
| Notifications | `notifications/rss`, `mylist`, `clear`, `clear/{id}`, `test` |
| User | `me`, `refreshtoken`, `addreferral`, `getconfirmation`, `auth/device/start`, `auth/device/token`, `referraldata`, `subscriptions`, `transactions`, `transaction/pdf`, `settings/editsettings`, `stats` |
| RSS Feeds | `addrss`, `controlrss`, `modifyrss`, `getfeeds`, `getfeeditems` |
| Integrations | `integration/jobs`, `integration/job/{id}` (GET and DELETE), `integration/jobs/{hash}` |
| Queued | `queued/getqueued`, `queued/controlqueued` |
| Stream | `stream/createstream`, `stream/getstreamdata` |

## What this repo actually calls

Three of the 65, all usenet, all from `scripts/lib/usenet_blackhole.py`.
Decypharr speaks the torrent half of the API itself and is configured rather
than coded here.

| Call | Where | Notes |
|---|---|---|
| `POST /v1/api/usenet/createusenetdownload` | `TorBox.submit_file` | multipart NZB upload |
| `GET /v1/api/usenet/mylist` | `TorBox.list_usenet` | `bypass_cache=true`, polled every pass |
| `GET /v1/api/usenet/requestdl` | `TorBox.request_zip_link` | `zip_link=true`, token in the query |

`scripts/lib/queue_cleanup.py` mentions TorBox only in `DEBRID_CLIENT_PATTERNS`,
which matches a client *name* in an arr queue record. It makes no API call.
`docs/TROUBLESHOOTING.md` carries a `requestdl` probe for the 403 case.

## Constraints that shape the design

**Ten active download slots, and sixty create calls an hour.** Two independent
limits, both reachable from one large backlog search.

An 11th concurrent usenet download is refused with `HTTP 500` and
`{"error":"ACTIVE_LIMIT","detail":"... active download limit of 10 ..."}`.
Separately, `createusenetdownload` is rate-limited at 60 calls per hour:
`HTTP 429: {"detail":"60 per 1 hour"}`.

Measured over 76 logged passes on 2026-09-14: **37 submissions accepted and 47
refused**, with 22 releases held back by the hourly cap alone. More calls were
refused than accepted.

`submit()` treats both as ordinary failures, so the NZB stays in the outbox and
the stack converges rather than losing work. The cost is that every pass
re-asks, and each re-ask spends the same 60-per-hour budget. The ceiling on
this path is therefore the provider's two limits, not the link speed — and the
retry pattern makes the second one worse than it needs to be.

**Download links open for three hours.** Long enough to start, not long enough
to store. The docs are explicit that CDN links are not permanent and that
permalinks are the durable form:

```
https://api.torbox.app/v1/api/usenet/requestdl?token=KEY&usenet_id=N&file_id=N&redirect=true
```

**Failure is a prefix, not a word.** `download_state` comes back as
`failed (Aborted, cannot be completed - https://sabnzbd.org/not-complete)`, with
the reason in parentheses. Matching `{"failed", "error"}` exactly leaves the
branch unreachable and reports dead jobs as running; see
`FAILED_STATES` in `usenet_blackhole.py` for the live incident.

**Post-processing is TorBox's job by default.** `post_processing` defaults to
`-1`: repair, extract, delete the source, keep only the wanted files.

| Value | Behaviour |
|---|---|
| `-1` | Default. Repair, extract, delete source files |
| `0` | None. Everything, PAR2 included |
| `1` | Repair |
| `2` | Repair and unpack, keeping the archives |
| `3` | Repair, unpack, delete the archives |

## Audit: where this stack is under-using the API

Findings from reading the collection against the code, with the evidence that
prompted each. None of these is fixed yet.

### Post-processing is not requested, only assumed

We omit `post_processing` and rely on the documented default. That default does
not always take effect: on 2026-09-14, **12 of 31 completed usenet items still
delivered RAR volumes** — 47 parts each for the `TENEIGHTY` releases — so the
watcher unpacks them locally with `unrar` to compensate, and a release whose
RARs are damaged fails with `checksum error` at our end rather than being
repaired by the provider.

Sending the value explicitly makes the behaviour deterministic instead of
inferred, and `2` or `3` would let the provider own the unpack step. Worth
measuring before moving: TorBox may be declining to extract precisely because
the archive is incomplete, in which case the local step is not the problem.

### Password-protected releases are unhandled

`createusenetdownload` accepts `password` for extracting an encrypted RAR set.
We never send one, so anything password-protected fails as a permanent error.
There is no configuration path for it yet.

### Availability is never checked before spending a slot

`checkcached` reports whether TorBox already holds a post. Today we submit and
find out: 36 of the 40 failures logged on 2026-09-14 were
`aborted, cannot be completed`, each one having consumed a slot from a pool of
ten. A pre-flight check would not make bad releases good, but it would stop them
costing download capacity.

The endpoint takes comma-separated hashes, around 100 per call, and returns in
under a second per hundred. What is less clear from the docs is which hash an
NZB maps to; that needs establishing before this is worth building.

### Nothing is ever deleted from the account

`controlusenetdownload` takes `{usenet_id, operation}` with `delete`, `pause` or
`resume`, and `all: true` for the whole account. We never call it. Completed
items therefore accumulate indefinitely, and a release the watcher has given up
on stays in the account rather than being cleaned out.

### The queue system is unused

`createusenetdownload` accepts `as_queued`, and the `Queued` folder exposes
`getqueued` and `controlqueued` with `start` and `delete`. That is the API's own
answer to the ten-slot limit: queue the work and start it as capacity frees,
instead of submitting blind and absorbing `ACTIVE_LIMIT` refusals. The current
behaviour converges, so this is an efficiency question rather than a
correctness one.

### The retry pattern spends the rate limit it is waiting on

Related to the unused queue system below, and worth its own entry because it is
a defect rather than a missed opportunity.

A submission refused with `429 60 per 1 hour` is retried on the next pass, two
minutes later. `submit()` iterates every pending NZB, so a release the provider
has just declined is offered again immediately, and each offer is another call
against the same hourly budget. With 22 releases held back on 2026-09-14, that
is 22 calls every two minutes spent asking a question already answered — the
pass log shows three refusals recurring on pass after pass with nothing
submitted in between.

Nothing is lost, because the NZBs stay put. What degrades is the rate at which
the ones that *would* be accepted get their turn.

Backing off after a `429` — remembering when the refusal happened and skipping
new submissions until the window has passed — would recover most of it. That is
a change to `submit()` and needs its own tests.

### Whole-release zips where a single file would do

`requestdl` takes `file_id` as well as `zip_link`, so one file can be fetched
directly. We always ask for the zip, then extract it locally. For a
single-video release the zip is a second copy of the payload written to the same
disk before being unpacked — for a 5 GB episode, 5 GB of staging for nothing.
`append_name` is also available and unused.

## What Decypharr covers

The torrent half of the API is exercised by Decypharr's own Go client, not by
this repo. What this repo controls is its configuration, in the
`decypharr-config` volume:

| Setting | Value here | Effect |
|---|---|---|
| `debrids[].provider` | `torbox` | which provider it calls |
| `debrids[].download_uncached` | `true` | TorBox fetches uncached torrents on its own servers |
| `max_active_downloads` | `5` | its own concurrency ceiling, separate from TorBox's |
| `download_folder` | `/data/torbox` | where finished files land for the arr to import |
| `mount.type` | `none` | no mount, so no local torrent engine |

Two concurrency limits therefore stack: Decypharr will not run more than 5 at
once, and TorBox will not hold more than 10. Neither is the network.
