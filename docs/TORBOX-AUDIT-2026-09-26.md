# TorBox audit — the repo against TorBox's own documentation

2026-09-26. TorBox's API reference (the Postman collection behind
<https://api-docs.torbox.app/>) and all seven help-center collections were read
in full, then every script, config and doc in this repo that touches TorBox was
compared to them. [TORBOX-API.md](TORBOX-API.md) is the resulting reference;
this file is the list of places the repo is wrong, fragile, or working harder
than it has to.

**Why this was done:** the usenet drain is limited by NAS disk I/O. A 60-second
per-process sample on 2026-09-26 put 1.73 GB read and 1.74 GB written on the
watcher's own Python process, against about 0.7 GB read and 0.02 GB written for
every container combined, with both disks 76-79 % busy at ~30 MB/s. The fetch
path writes every release three times (zip, extracted RARs, unrarred video).
Several findings below are about that path; the rest turned up on the way.

Each finding gives the TorBox source, the repo location, and the fix. Findings
are ranked by consequence, not by effort. **None of the code fixes are made in
this change**: each is its own branch, tested on the NAS before `main`.

---

## A. Shape of the solution

### A1. There is no ~90-day NNTP cliff — re-measured 2026-09-26

- **Repo:** `scripts/lib/usenet_blackhole.py:6-15`,
  `scripts/usenet-blackhole.sh:6-11`, `scripts/lib/configure-helpers.sh:195`,
  `CHANGELOG.md` (#75). These say `nntp.torbox.app` "serves articles only up to
  about 90 days old", and that claim is why usenet left SABnzbd. The docs
  (`TROUBLESHOOTING.md`, `APP-CONFIG.md`, `MAINTENANCE.md`, `CLAUDE.md`) are
  corrected in this change; the code comments and the changelog are not.
- **TorBox:** `GET /usenet/provider/connection` returns `"retention": 5000`;
  [TorBox News Server](https://support.torbox.app/en/articles/15531672-torbox-news-server)
  says "3900+ days", "99.8% completion rate", 10 connections, included with Pro.
  [Why Are My Usenet Transfers To TorBox Slow?](https://support.torbox.app/en/articles/15300133-why-are-my-usenet-transfers-to-torbox-slow)
  adds that older posts "may sit on cold storage or with partner providers".
- **Re-measurement (2026-09-26).** Every NZB in the blackhole outbox (209
  parsed), from inside the `sabnzbd` container, with SABnzbd's own credentials
  (`281 Authentication accepted`), one connection. Per NZB, three segments of
  its largest file (first, middle, last): `STAT` on each, and `BODY` on the
  middle one plus every segment `STAT` refused. Age is the NZB's earliest
  `<file date>`.

  | Posting age | NZBs | all 3 present | some | none |
  | --- | --- | --- | --- | --- |
  | < 90 days | 5 | 5 | 0 | 0 |
  | 90-364 days | 21 | 8 | 4 | 9 |
  | 365-999 days | 110 | 32 | 26 | 52 |
  | 1000+ days | 73 | 18 | 15 | 40 |

  - **Retention is not the limit.** Releases 1000+ days old (the oldest,
    1303 days) are fully present. What is missing looks like per-release
    article loss (takedowns, incomplete posts), and its rate rises with age
    without any cutoff.
  - **`STAT` does not lie.** 372 segments answered `430` to `STAT`; all 372 also
    answered `430` to `BODY`. Every `BODY` that succeeded returned a whole
    article (~740 KB). The cold-storage hypothesis — `STAT` refusing what
    `BODY` would fetch — is not supported.
  - Three present segments is an upper bound on completeness, not proof of it:
    only 63 of 209 (30%) cleared even that bar.
  - The sample is biased old and hard: it is the backlog waiting to drain, the
    titles the arrs have failed to find. Fresh grabs would do better.
- **What it means.** The 2026-09-14 probe was right about its eight releases
  and wrong in its generalisation: "~90 days" was eight data points read as a
  rule. The API path hits the same wall — `usenet-blackhole-failed.log` holds
  986 failures since 2026-09-14, 898 of them TorBox's own
  `aborted, cannot be completed`. So the question is no longer retention but
  whether TorBox's API completes releases the news server cannot (partner
  providers, per TorBox), and at what rate.
- **Next measurement:** run the same NZBs down both paths — this probe's
  per-release verdict against the blackhole's outcome for the same release
  (`usenet-blackhole-failed.log` vs. arrival in `complete/`). If the API's
  completion is not materially higher, SABnzbd on `nntp.torbox.app` does the
  same job with native par2 repair, unpack and arr failure reporting, an
  incomplete dir that could live on an SSD, and no zip/unrar pipeline — and
  the watcher becomes optional.

### A2. Every release is fetched as a zip — the documented slow path, and 2 of the 3 disk writes

- **Repo:** `TorBox.request_zip_link` (`usenet_blackhole.py:368`) always sends
  `zip_link=true`; `fetch()` (1205-1283) writes `payload.zip`, extracts it,
  deletes it, then unrars.
- **TorBox:** zips are "generated on the fly", single-connection, served "only …
  from the main storage servers in WNAM and WEUR", deprioritised under load, and
  an interrupted zip "forces a restart from the beginning"; a per-file link
  allows "up to 16 connections per file" from the CDN
  ([Why Are Zip Files Slow…](https://support.torbox.app/en/articles/15030073-why-are-zip-files-slow-downloading-to-my-computer)).
  With the default `post_processing=-1` the item's `files[]` is already the
  repaired, extracted payload (API).
- **Consequence:** for an item TorBox extracted, the zip step alone is a full
  extra write and a full extra read on the RAID1 pair.
- **Fix:** in `fetch()`, read the job's `files[]` from the `mylist` record
  already in hand, and `requestdl?usenet_id=N&file_id=M` each wanted file into
  staging (curl config on stdin, as now). Run `unpack_rar` only if RAR volumes
  are among them — the 12-of-31 case in TORBOX-API.md. Keep the rename into the
  watch folder. Expected effect: one write per byte for extracted items instead
  of ~2.4 (the ratio measured in `docs/MAINTENANCE.md`).

### A3. The ten slots are probably shared with torrents, and this stack budgets 11

- **Repo:** usenet treats ten as its own (`usenet_blackhole.py:64,202`,
  `scripts/usenet-blackhole.service:44-46`, `CLAUDE.md`), runs up to 6; Decypharr
  runs up to 5 (`max_active_downloads`, TORBOX-API.md).
- **TorBox:** Pro is "10 active torrents, which allows you a total of 10
  concurrent downloads"; cached items don't count
  ([Account Restrictions](https://support.torbox.app/en/articles/9836418-account-restrictions)).
  Whether usenet shares that pool is **not stated**.
- **Fix:** measure it — log `data.current_active_downloads` from the next
  `ACTIVE_LIMIT` body next to the watcher's in-flight count and Decypharr's
  active count. If shared, set the two ceilings to sum to ≤ 10 (e.g. 6 + 4).
  Cheap either way: the watcher already parses that body in `api_error_code`.

### A4. The 403 / `error code: 1010` "account refusal" is most likely a Cloudflare block, not a TorBox limit

- **Repo:** `CLAUDE.md` (*What a TorBox refusal actually looks like*),
  `docs/TROUBLESHOOTING.md` (*All Download Links Return 403 (error code 1010)*),
  `docs/MAINTENANCE.md:223` — all describe it as TorBox refusing the account
  after a `createtorrent` burst, and derive "queue in ones and twos".
- **TorBox:** rate limits are "per API token, no edge rate limiting"; the API's
  403s are JSON `NO_AUTH`/`BAD_TOKEN`; the error enum has no `1010`. A bare
  `error code: 1010` is Cloudflare's "banned browser signature", which this repo
  already concluded for Cinemeta (`scripts/lib/stremio_library.py:113-122`,
  `docs/MAINTENANCE.md:811-818`). The TROUBLESHOOTING probe uses curl's default
  User-Agent, and no response headers were kept.
- **Fix:** docs now say "unproven, probably Cloudflare" instead of stating a
  cause. On the next occurrence, capture `curl -sSI` headers (`server`,
  `cf-ray`) and retry once with a browser User-Agent. If confirmed, the lesson
  is the caller's signature (Decypharr's Go client, curl), not queue size — and
  "queue in ones and twos" is still sound for the 60/hour uncached-create limit,
  just not for this.

---

## B. Correctness bugs

### B1. A job TorBox stops listing is never timed out, and holds an in-flight slot forever

- **Repo:** `poll()` (`usenet_blackhole.py:1016-1018`) marks a job missing from
  `mylist` as `unknown` and `continue`s **before** the stall and timeout checks.
  `jobs_at_torbox()` (863-877) counts it against `--max-inflight`. No test
  covers expiry.
- **When it happens:** the job was deleted on TorBox's side (dashboard, WebDAV,
  30-day expiry), `usenetdownload_id` came back missing, or it fell off the one
  `mylist` page (B3).
- **Fix:** record `missing_since` on the first `unknown`; after N consecutive
  passes or the timeout, drop it and report `timeout`. Keep the grace for a
  transient empty list.

### B2. Completion is read from `download_state`, which TorBox says not to use

- **Repo:** `DONE_STATES = {"completed", "cached"}` (`usenet_blackhole.py:117`).
- **TorBox:** of torrent `completed`: "Do not use this for download completion
  status" (API). The completion fields are `download_finished` and
  `download_present`, present on usenet records too. Usenet `download_state` has
  no documented enum at all.
- **Fix:** treat a job as fetchable when `download_finished and
  download_present`; keep the state-string prefix match for failure.

### B3. `mylist` is read as one page of 1000, and finished items are never deleted

- **Repo:** `list_usenet` (333) requests `limit=1000` once, no `offset`.
  Completed items are never deleted after a successful fetch (TORBOX-API.md,
  "completed items still accumulate"); 327 records were present on 2026-09-17.
- **TorBox:** `offset` and `limit` exist; ordering is undocumented; items expire
  only after 30 days unused.
- **Fix:** `controlusenetdownload delete` after a successful fetch (the files are
  on the NAS; TorBox's copy is then only a slot on a list), and page with
  `offset` until a short page. Either alone prevents B1 from being triggered by
  list length.

### B4. A `mylist` error kills the pass with a traceback

- **Repo:** `run()` calls `poll()` (1421) unguarded; `main()` catches only
  `StateError` (1642). A 429, 5xx or network error on `mylist` aborts the pass;
  the same holds for anything `requestdl`/`controlusenetdownload` raises outside
  their existing handlers.
- **Fix:** catch `TorBoxError` around the poll, log it, skip poll and fetch for
  this pass, keep submissions' state. Test with `FakeTorBox` raising.

### B5. The zip download is capped at one hour and restarts from zero

- **Repo:** `curl … --max-time 3600` (1242). A 38 GB zip needs ~85 Mbit/s
  sustained on a single connection to finish in that hour; a zip cannot resume.
  Every timeout re-downloads and re-writes the whole payload on the next pass.
- **Fix:** A2 removes it (per-file links resume). Until then, scale the timeout
  to the job's `size`.

### B6. Unrar failures are declared permanent, silently

- **Repo:** `unpack_rar` (1155-1162) raises `PermanentError` on any non-zero
  exit ("the same release will fail the same way"); `run()` (1521-1529) then
  records it, drops the job and the NZB, **without** reporting the failure to
  the arr and **without** deleting the item at TorBox.
- **Evidence against:** `PLAN-USENET-RECOVERY-FOLLOWUPS.md:53-60` — three of
  four checksum failures recovered on a later grab.
- **Fix:** report it to the arr like `poll()`'s terminal branches (so the arr
  blocklists and searches again), and delete at TorBox. A2 also makes it rarer:
  TorBox's own PAR2 repair runs before any local unrar is needed.

### B7. Magnetio polls torrent state without bypassing TorBox's 600-second cache

- **Repo:** `_waitForReady` (`magnetio/addon/moch/torbox.js:118-134`) polls
  `mylist?id=` 10 × 2 s with no `bypass_cache`.
- **TorBox:** torrent `mylist` "only gets updated every 600 seconds" (API).
- **Fix:** add `bypass_cache: true` to that call. (The 300/min general limit
  easily covers ten polls.)

### B8. Magnetio turns TorBox off on any 401/403 until restart

- **Repo:** `handleTbError` (`torbox.js:158-161`) blacklists the key in memory
  on any 401 or 403.
- **Why it bites:** with A4, one Cloudflare 403 disables TorBox for the addon
  until the container restarts.
- **Fix:** blacklist only on a JSON body whose `error` is `BAD_TOKEN`,
  `NO_AUTH` or `AUTH_ERROR`; treat anything else as transient.

---

## C. Documentation corrections (made in this change)

| # | Where | Was | Now |
|---|---|---|---|
| C1 | `CLAUDE.md` (TorBox Account) | "`plan` is an integer … none of them say 'Pro'" | `plan` is a documented enum; `2` is Pro. `cooldown_until` is the Free-tier add cooldown, not a rate window |
| C2 | `CLAUDE.md`, `docs/TROUBLESHOOTING.md` | 403/1010 stated as TorBox's account refusal | stated as observed, cause unproven, probably Cloudflare (A4) |
| C3 | `docs/TORBOX-API.md` | 429 and `ACTIVE_LIMIT` "treated as ordinary failures"; backoff as future work | describes the backoff that exists |
| C4 | `docs/TORBOX-API.md` | documented and measured facts mixed | separated; every documented fact sourced |
| C5 | `tests/python/test_usenet_blackhole.py:676` | "ACTIVE_LIMIT and friends are per-release refusals" | corrected comment |
| C6 | `.env.example` | `TORBOX_API_KEY` "for decypharr" | for the usenet watcher; Decypharr keeps its own key in its config volume |
| C7 | `CLAUDE.md`, `docs/DECYPHARR-PATCH.md` | link to a heading that does not exist | fixed |
| C8 | `docs/DECYPHARR-PATCH.md` | 400 meaning stated as TorBox's | marked as observed; TorBox documents 400 only as a client error |

Left as is, noted: `terraform/main.tf:36,55` still defines "SABnzbd (TorBox
Usenet)" clients. That is drift from the blackhole move — or, if A1 comes back
in SABnzbd's favour, the configuration to return to. Decide after A1.

---

## Suggested order

1. **A1** — retention is settled (no cliff); the path-vs-path completion
   comparison still decides whether the rest of the usenet work is worth doing.
2. **B1 + B3** — small, testable, and they stop the watcher's in-flight count
   drifting upward.
3. **A2** (with B5, B6) — the disk-load fix, if the watcher stays.
4. **A3** — one log line, then a config change.
5. **B7 + B8** — Magnetio, independent of the rest.
6. **B2, B4** — hardening.
