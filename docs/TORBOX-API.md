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

Four of the 65, all usenet, all from `scripts/lib/usenet_blackhole.py`.
Decypharr speaks the torrent half of the API itself and is configured rather
than coded here.

| Call | Where | Notes |
|---|---|---|
| `POST /v1/api/usenet/createusenetdownload` | `TorBox.submit_file` | multipart NZB upload |
| `GET /v1/api/usenet/mylist` | `TorBox.list_usenet` | `bypass_cache=true`, polled every pass |
| `POST /v1/api/usenet/controlusenetdownload` | `TorBox.delete_usenet` | `operation: "delete"`, frees the slot a stalled or timed-out job still holds |
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

`--max-inflight N` puts an operator-set ceiling below that ten, and it ships
off (`0`). The provider's ten is a limit, not a target: measured over the
retained window, nine of the ten slots were held by jobs 3-21h old while only 4
of 50 submissions were ever fetched, so the question is whether six concurrent
jobs complete more of themselves than ten do. Run it at 6 for a measured window
and compare fetch rates before keeping any value: a ceiling set too low trades
wasted slots for idle ones. Reaching the ceiling spends no
`createusenetdownload` call, because the check runs before the upload.

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

**Progress is a number on every `mylist` record.** `progress` is TorBox's own
completion figure for the job, and it moves while bytes arrive. The watcher's
`--stall-hours` rule reads it, because `download_state` says `downloading` for a
job that is downloading nothing: the value is what separates a large release
that is still moving from one that has stopped and is holding a slot for no
reason.

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
prompted each. Most are unfixed; a section that has since been addressed says
so, and what changed.

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
under a second per hundred. It cannot serve as that check, for two reasons, both
measured against the live account on 2026-09-17 with 327 usenet jobs in
`mylist`.

Given a hash the account already owns, the call works. The `hash` field on a
`mylist` job is a 32-character MD5-shaped string (for example
`9acd321c7ddcded56e7f84890291b9c5`), and this returns that release's name, size
and hash:

```
GET /v1/api/usenet/checkcached?hash=<hash>&format=object
```

No derivation tried so far computes that hash from a local NZB before submitting
it. 16 candidate derivations were tested against 3 NZB files whose release names
matched a `mylist` entry character for character:
`the.sopranos.s04e09.1080p.bluray.x264-shortbrehd`,
`Severance.S01E08.1080p.BluRay.x264-BORDURE` and
`Foundation.S01E05.1080p.WEB.H264-CAKES-FTP`. Each candidate is the MD5 of one
input:

1. the raw file bytes
2. the release name
3. the release name plus `.nzb`
4. the file's basename
5. the first segment message-id, bare
6. the first segment message-id, wrapped in angle brackets
7. every segment message-id concatenated in document order, no separator
8. every segment message-id concatenated in sorted order, no separator
9. every segment message-id joined with newlines in original document order
10. the last segment message-id
11. the first `subject` attribute
12. all `subject` attributes concatenated
13. the sorted `<group>` list joined by commas
14. the lowercased release name
15. the file with all whitespace stripped
16. the reported size as a string

None matched: no client-computable derivation was found among the sixteen tried.

Even with the hash, the endpoint cannot predict whether a release will complete,
because `cached` describes what TorBox already holds rather than what the
backbone can still retrieve. Queried for `the.sopranos.s04e09...` (hash
`ce05aede44be4f71859ddc7ae283eca4`) while that job's `download_state` was
`processing` and it was downloading, `checkcached` answered `{"data":{}}`, the
identical empty answer it gives for a job that failed
(`d601c08cc972ebea0535f085996af9bf`). Across all 327 jobs, `cached` is true for
167 of the 167 that completed and false for 155 of the 155 that failed. The
remaining five were neither completed nor failed at measurement time, still in
flight and non-terminal, so they fall outside that comparison entirely; among the
322 terminal jobs there are no exceptions. A field that matches the outcome
perfectly in both directions is written after the bytes arrive; it does not
forecast whether they will.

A pre-flight gate built on `checkcached` would therefore reject every release
that is merely new, which is every release worth submitting. The abort is a
TorBox-side fact learned only by submitting. It still costs a submission, and
what makes it cost once instead of three to five times is the failure reporting
that went live on 2026-09-17.

This closes the question rather than deferring it. If TorBox ever documents a
client-derivable identifier, that is the moment to revisit, and it would need a
test showing the derivation matching a real job's hash.

### Stalled and timed-out jobs are deleted; completed items still accumulate

`controlusenetdownload` takes `{usenet_id, operation}` with `delete`, `pause` or
`resume`, and `all: true` for the whole account. The watcher now calls it with
`operation: "delete"` for the two terminal outcomes where the job is still
ACTIVE at TorBox: `poll()`'s stalled and timeout branches. Dropping a job from
the state file does not stop it, so without the delete it went on holding one of
the ten concurrent slots, which is the cost the stall rule exists to stop paying.

The call is best-effort. A TorBox that refuses it (a 500, a job that is already
gone) is logged as `could not delete from TorBox`, and the job is dropped from
the state either way, because one un-deletable release must not stop the pass
classifying everything behind it. A job TorBox itself reports failed is not
deleted: it has already stopped, so there is no slot to free.

Completed items still accumulate. The watcher downloads what it asked for and
never deletes it afterwards, so the account's completed list only grows.

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

## The official SDKs, and why this stack does not use one

TorBox publishes SDKs in six languages, under the
[TorBox-App](https://github.com/TorBox-App) organisation and linked from
<https://torbox.app/integrations>:

| SDK | Language | Last pushed |
|---|---|---|
| `torbox-sdk-py` | Python | 2025-04-26 |
| `torbox-sdk-go` | Go | 2025-04-26 |
| `torbox-sdk-js` | TypeScript | 2025-04-26 |
| `torbox-sdk-java` | Java | 2025-04-26 |
| `torbox-sdk-dotnet` | C# | 2025-04-26 |
| `torbox-sdk-php` | PHP | 2025-04-26 |

They are generated clients, MIT-licensed, and the Python one is on PyPI as
`TorBox` at 0.1.0a1, published 2024-11-23.

**It would have caught one of our bugs.** `request_download_link1` builds the
call with `.add_query("token", token)`, so the requirement that `requestdl`'s
token travel as a query parameter — the one that cost a failed fetch and a
rewritten HTTP layer — is encoded in it. That is a real argument for a generated
client over a hand-rolled one: the vendor's own view of the surface lives in the
code rather than in prose someone has to read.

**It cannot express what the audit above recommends.** The Python SDK's
`CreateUsenetDownloadRequest` models two fields:

```python
self.file = file
self.link = link
```

No `name`, no `password`, no `post_processing`, no `as_queued`, no
`add_only_if_cached` — despite the method's own docstring documenting the
post-processing values in full. The generator's output has drifted behind the
collection it was generated from, and the fields it is missing are exactly the
ones this stack is not using well.

**And the watcher could not install it anyway.** `usenet-blackhole` runs as a
systemd user unit on the NAS against the system `python3`, with no pip and no
package manager. The Python SDK pulls `pydantic`, `click`, `requests` and
`typing-extensions`. Adopting it means containerising the watcher, which is the
pattern this repo uses for anything with dependencies
(`tests/toolkit/pytest.sh`, the e2e runner, `alpine/git`). That is worth doing
on its own merits, but not for a client whose HTTP layer is 93 lines of `curl`
plus stdlib.

**Decision: keep the hand-rolled client, read the SDKs when auditing.** A
generated client is worth consulting for a detail the collection buries — the
`requestdl` token requirement is a good example — but not worth a runtime
dependency that is a year and a half behind the API and cannot be installed on
the host that runs it.

The calculation changes if the SDKs catch up. Worth re-checking when
`CreateUsenetDownloadRequest` grows a `post_processing` field.

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
