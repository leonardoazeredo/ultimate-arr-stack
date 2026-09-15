#!/usr/bin/env python3
"""Fetch usenet releases through TorBox's API, for the arrs' UsenetBlackhole.

Why this exists
---------------
SABnzbd here points at `nntp.torbox.app`. Measured 2026-09-14, that server
serves articles only up to roughly 90 days old: releases aged 1, 34, 60 and 86
days resolved 5/5 or 6/6 every time, while 101 and 138 days resolved 0/5 and
0/6. The group always exists; the articles are gone. That is why SABnzbd
imported 1 of 92 Sonarr usenet grabs while torrents imported 109 of 202.

TorBox's *API* has no such limit, because it runs a usenet client against a real
backbone rather than serving from that cache: the exact 138-day-old NZB SABnzbd
cannot fetch was submitted to `createusenetdownload` and completed at 836 MB
across 4 files. So the fix is to stop asking a cache to be a backbone and submit
NZBs to TorBox instead.

How it works
------------
Both arrs ship a `UsenetBlackhole` download client whose entire contract is two
paths. The arr writes `<Release.Title>.nzb` into `nzbFolder` and then polls
`watchFolder` for the result (Sonarr's `ScanWatchFolder.cs`, read from source):

  * it looks at IMMEDIATE SUBDIRECTORIES of the watch folder, plus loose video
    files directly in it. The directory name becomes the item title via
    `FileNameBuilder.CleanFileName`, which is only filesystem sanitisation --
    the release name arrives intact.
  * a directory is `Completed` once no file inside is locked, and it will not be
    imported until its contents have been stable for a 30-second grace period.
  * therefore the release directory must be fully written BEFORE it is renamed
    into place, and the half-written copy must live somewhere the arr does not
    look. `fetch` stages under `staging_dir` and renames into `watch_dir` when
    the release is whole.
  * after importing, the arr deletes the release folder itself
    (`UsenetBlackhole.RemoveItem` -> `DownloadClientBase.DeleteItemData`), so the
    watch folder does not grow on its own.

`staging_dir` is a sibling of the watch folder rather than a `.incoming-`
directory inside it, and that is not cosmetic. A dot-directory looks hidden to
a person, but Sonarr does not skip it: `DiskProviderBase.GetDirectories` skips
only `FileAttributes.System`, and `DiskScanService.FilterPaths` matches
dot-segments with a regex that requires a trailing separator -- which
`PathExtensions.GetRelativePath` has already trimmed off. A `.incoming-` staging
directory inside the watch folder is reported to the arr as a completed
download, and its half-written files are what get imported.

This module does the three steps in between: submit, poll, fetch.

  * `submit`  uploads each NZB to `createusenetdownload`, recording a stable
    identity so a restart never submits the same release twice.
  * `poll`    asks `usenet/mylist` for each in-flight job, and fails one that
    has stopped reporting progress as well as one that TorBox reports dead. A
    job failed either of those two ways is still active at TorBox, so it is
    deleted there as well -- that is what actually frees its slot.
  * `fetch`   requests a zip link once the job is complete, unpacks it into the
    watch folder, and drops the staging directory.

Failure is explicit. A blackhole client reports no queue to the arr -- the arr
only sees what appears in the watch folder -- so a release that never completes
would otherwise sit invisible forever. Every job that TorBox reports failed, that
has reported no progress for `--stall-hours`, or that exceeds `--timeout-hours`
is appended to `logs/usenet-blackhole-failed.log` and removed from the state
file, so the operator can see it and the arr can be told to try something else.
The stall rule is what stops such a job holding one of the account's ten
concurrent slots for the full timeout; the timeout stays the bound for a large
release that is still moving. Both of those outcomes leave the job running at
TorBox, so both delete it there: removing it from the state file alone would
only stop watching the slot being spent.

Telling the arrs
----------------
A blackhole is a one-way street unless something walks back. The arr writes an
NZB and then looks in the watch folder; this moves the file out of the outbox as
soon as it submits it, so the arr's queue never holds the item. Measured
2026-09-15: twelve in-flight jobs, none of them in either arr's queue, and
`queue-cleanup` reporting "Queue size: 0 items" every hour while the blackhole
logged 227 failures across 100 distinct releases. The arr could not blocklist
what it could not see, so the same dead release came back on the next missing-
episode search. `The.Sopranos.S01E08.POLiSH.1080p.WEB.H264-CHOPiN` was
blocklisted six times on 2026-09-12 and grabbed again on the 14th and the 15th.

`FailureReporter` closes that loop: when a job reaches a terminal failure it is
resolved to the arr history record for the grab and reported with
`POST /api/v3/history/failed/{id}`, which marks the grab failed, writes a
blocklist entry keyed the way the arr keys its own, and triggers a replacement
search. Reported history ids are remembered in the state file so a retry cannot
report the same grab twice.

Two things it will not do. It will not report a retryable provider answer --
`RateLimited` and `ActiveLimit` are transient, and blocklisting a release that
was never given a chance is worse than the retry storm. And it will not stop the
pass: an unreachable arr, a missing match or a malformed response is logged and
the pass carries on. Moving bytes is the job; telling the arr is bookkeeping.

Usage:
  usenet_blackhole.py <nzb-dir> <watch-dir> <staging-dir> <state-path>
                      <failed-log>
                      [--api-key K] [--apply] [--timeout-hours N]
                      [--stall-hours N] [--max-inflight N] [--verbose]
                      [--report-failures] [--report-dry-run]
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from xml.etree import ElementTree

TORBOX_API = "https://api.torbox.app/v1/api"

# TorBox's own state strings (GET /usenet/mylist -> download_state).
#
# Completion is an exact match; failure is a PREFIX, and that difference is not
# cosmetic. TorBox does not return a bare "failed": it returns
#
#   failed (Aborted, cannot be completed - https://sabnzbd.org/not-complete)
#
# with the reason in parentheses. Matching the failure set exactly -- which is
# what this did until 2026-09-14 -- let fifteen failed releases sit as
# "in progress" until the 24-hour timeout, get logged as timeouts rather than
# as the missing-article failures they were, and never be surfaced to the arr
# at all. They were found by counting the states on the account, not by
# anything in this stack noticing.
DONE_STATES = {"completed", "cached"}
FAILED_STATES = ("failed", "error")


def failure_reason(state_name):
    """The reason out of a TorBox failure string, or None if it is not one.

    `failed (Aborted, cannot be completed - ...)` becomes `Aborted, cannot be
    completed`. The parenthetical is what an operator needs: it separates
    missing articles from a provider outage, and those want different answers.
    """
    lowered = (state_name or "").lower()
    if not lowered.startswith(FAILED_STATES):
        return None
    if "(" in lowered and ")" in lowered:
        inner = lowered.split("(", 1)[1].rsplit(")", 1)[0].strip()
        if inner:
            return inner
    return lowered

# Every API call is bounded. A watcher that hangs on one request stops fetching
# everything behind it, and the arr has no other way to notice.
API_TIMEOUT = 120

# A staging directory older than this with no job claiming it came from a crash
# mid-fetch, not from a fetch in progress.
STALE_STAGING_HOURS = 1.0

# How many finished releases are downloaded at once.
#
# One at a time was the ceiling on this whole path: a pass that finds five
# completed releases pulled them in series, so the last one waited for four
# full downloads plus four unpacks. Each fetch is a curl download and then an
# unrar, and both spend nearly all their time waiting, so overlapping them
# costs nothing but disk.
#
# Bounded, not unbounded. The unpack is CPU-bound and this runs on a NAS that
# is also transcoding for Jellyfin, and the arr's importer reads the same
# pool. Three keeps several CDN streams busy without stacking four unrars
# against a transcode; raise it only with a measurement of the NAS's own load.
FETCH_WORKERS = 3

# How long to stop submitting after TorBox refuses one with a 429.
#
# `createusenetdownload` is limited to 60 calls an hour, and a pass that finds a
# backlog offers every NZB it holds. Each offer is a call, so a pass that runs
# into the limit and is retried two minutes later spends the next hour's budget
# re-asking a question already answered: measured 2026-09-14, three refusals
# recurring on pass after pass with nothing submitted in between, against 47
# refusals to 37 acceptances overall.
#
# The API documents the window ("60 per 1 hour") and sends no Retry-After, so
# the wait is the documented one. Guessing shorter costs calls on the probe; a
# window is a sliding count, so waiting it out is the cheap side of the
# trade. Polling and fetching continue throughout -- only submissions pause,
# and the outbox holds them.
RATE_LIMIT_BACKOFF_HOURS = 1.0


class TorBoxError(RuntimeError):
    pass


class RateLimited(TorBoxError):
    """TorBox refused the call with a 429, so the hourly budget is spent.

    Separate from TorBoxError because the answer is not "retry this one", it is
    "stop asking for a while" -- and because the caller has to know that
    offering the next NZB is as pointless as offering this one.
    """


class ActiveLimit(TorBoxError):
    """The account is using all of its concurrent download slots.

    The other half of the same problem as RateLimited, and the same answer.
    TorBox allows ten concurrent usenet downloads and refuses the eleventh with
    `{"error":"ACTIVE_LIMIT"}` under an HTTP 500. That status is shared with a
    dozen unrelated failures, so a caller reading the status alone cannot tell
    "this release is bad" from "there is no room for any release".

    No backoff follows this one: a slot frees by itself, and the next pass two
    minutes later is what finds out.
    """


class PermanentError(TorBoxError):
    """The release itself is unusable, so a retry would fail the same way.

    Worth its own class because the retry is not free: every attempt downloads
    the whole release again. A password-protected RAR set or a release with no
    video in it has to be failed and recorded, not retried every two minutes
    until the 24-hour timeout.
    """


class StateError(RuntimeError):
    """The state file could not be written, so this pass cannot be trusted.

    Raised rather than swallowed: that file is the only thing stopping the next
    pass from submitting every release to TorBox a second time, so a pass that
    cannot write it has to fail loudly rather than look like it succeeded.
    """


def quoted(value):
    """Escape a value for a curl config file (see queue_cleanup.py)."""
    return value.replace("\\", "\\\\").replace('"', '\\"')


def api_error_code(body):
    """TorBox's own error code out of a failure body, or None.

    Exists because the HTTP status is too coarse to act on. ACTIVE_LIMIT
    arrives under a 500, the same status as DOWNLOAD_SERVER_ERROR,
    UNKNOWN_ERROR and a dozen others, and it is the only one of them that means
    "stop offering, there is no room" rather than "this release was refused".
    """
    try:
        payload = json.loads(body)
    except (TypeError, ValueError):
        return None
    if isinstance(payload, dict):
        code = payload.get("error")
        return code if isinstance(code, str) else None
    return None


def _run_curl(lines, timeout=API_TIMEOUT):
    """Return the response body, or raise TorBoxError carrying the API's answer.

    Deliberately not `curl -f`: that returns exit 22 and throws the response
    body away, and TorBox puts the reason in the body. A 422 here reads as
    `curl: (22) The requested URL returned error: 422` with `-f`, and as
    `{"detail":[{"type":"missing","loc":["query","token"],...}]}` without it.
    The second one is the whole diagnosis.
    """
    proc = subprocess.run(
        ["curl", "-sS", "--max-time", str(timeout), "-w", "\n%{http_code}", "--config", "-"],
        input="\n".join(lines) + "\n",
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise TorBoxError(f"curl exit {proc.returncode}: {proc.stderr.strip()[:200]}")
    body, _, code = proc.stdout.rpartition("\n")
    if not code.startswith("2"):
        message = f"HTTP {code}: {body.strip()[:240]}"
        # Two refusals mean "stop offering", and both are decided on the body
        # rather than the status: 429 is the hourly budget, ACTIVE_LIMIT is the
        # ten download slots. Everything else is a per-release failure that the
        # caller should carry on past.
        if code == "429":
            raise RateLimited(message)
        if api_error_code(body) == "ACTIVE_LIMIT":
            raise ActiveLimit(message)
        raise TorBoxError(message)
    return body


class TorBox:
    """The subset of TorBox's usenet API this watcher needs."""

    def __init__(self, api_key, base=TORBOX_API):
        self.api_key = api_key
        self.base = base.rstrip("/")

    def _get(self, path):
        out = _run_curl(
            [
                f'url = "{quoted(self.base + path)}"',
                f'header = "Authorization: Bearer {quoted(self.api_key)}"',
            ]
        )
        try:
            return json.loads(out)
        except json.JSONDecodeError as err:
            raise TorBoxError(f"{path} did not return JSON: {out[:160]!r}") from err

    def submit_file(self, nzb_path, name):
        """Submit an NZB, keyed off argv through the curl config.

        `curl --form file=@path` has to name the path, so the caller passes it;
        the API key itself still travels in the config on stdin rather than on
        the command line, where /proc/<pid>/cmdline would expose it.
        """
        config = [
            f'url = "{quoted(self.base + "/usenet/createusenetdownload")}"',
            f'header = "Authorization: Bearer {quoted(self.api_key)}"',
            f'form = "file=@{quoted(nzb_path)}"',
            f'form = "name={quoted(name)}"',
            'form = "as_queued=false"',
        ]
        out = _run_curl(config)
        try:
            payload = json.loads(out)
        except json.JSONDecodeError as err:
            raise TorBoxError(f"submit did not return JSON: {out[:160]!r}") from err
        if not payload.get("success"):
            raise TorBoxError(f"submit refused: {payload.get('detail') or payload}")
        return payload.get("data") or {}

    def list_usenet(self):
        payload = self._get("/usenet/mylist?bypass_cache=true&limit=1000")
        return payload.get("data") or []

    def delete_usenet(self, usenet_id):
        """Delete a download from the account, which is what frees its slot.

        `controlusenetdownload` is the only call that stops a job running at
        TorBox. Dropping one from the state file does not: a stalled or
        timed-out job is still ACTIVE there, holding one of the account's ten
        concurrent slots, which is the cost the stall rule exists to stop
        paying. `operation: "delete"` removes it and its files.

        Both the key and the JSON body travel through the curl config on stdin,
        the same arrangement `submit_file` uses, so neither reaches argv. Raises
        TorBoxError when TorBox refuses, the convention the other methods here
        follow.
        """
        body = json.dumps({"usenet_id": usenet_id, "operation": "delete"})
        out = _run_curl(
            [
                f'url = "{quoted(self.base + "/usenet/controlusenetdownload")}"',
                f'header = "Authorization: Bearer {quoted(self.api_key)}"',
                'header = "Content-Type: application/json"',
                'request = "POST"',
                f'data = "{quoted(body)}"',
            ]
        )
        try:
            payload = json.loads(out)
        except json.JSONDecodeError as err:
            raise TorBoxError(f"delete did not return JSON: {out[:160]!r}") from err
        if not payload.get("success"):
            raise TorBoxError(f"delete refused: {payload.get('detail') or payload}")
        return True

    def request_zip_link(self, usenet_id):
        """Get a zip download link for a finished usenet download.

        `token` goes in the query string as well as the Authorization header,
        because this endpoint requires it: with the header alone it answers
        `422 {"detail":[{"type":"missing","loc":["query","token"]}]}`. Nothing
        else this module calls needs it, and the link TorBox hands back carries
        the same token in its own URL, which is why `fetch` downloads through a
        curl config on stdin rather than on argv.
        """
        payload = self._get(
            f"/usenet/requestdl?token={self.api_key}"
            f"&usenet_id={usenet_id}&zip_link=true"
        )
        if not payload.get("success"):
            raise TorBoxError(f"zip link refused: {payload.get('detail') or payload}")
        data = payload.get("data")
        if isinstance(data, dict):
            return data.get("url") or data.get("download_link")
        return data


# --- telling the arrs what died --------------------------------------------

# How far back a history entry is allowed to be and still be the grab this
# release came from.
#
# A week is generous for a submission-to-failure gap -- the test case that
# prompted this ran the 24-hour timeout -- and bounded on purpose: the same
# release name comes back from the indexer season after season, and an
# unbounded search would happily match a grab from last year and fail it.
HISTORY_WINDOW_DAYS = 7

# How long a reported history id is remembered. This is the ledger that stops a
# retry reporting the same grab twice; no reason for it to outlive the window
# that produced it.
REPORT_LEDGER_DAYS = 7

# The arrs listen on the NAS's own loopback. This module runs on the host, not
# in a container, which is the same arrangement queue_cleanup.py has.
ARR_SERVICES = (
    ("Sonarr", 8989, "SONARR_API_KEY"),
    ("Radarr", 7878, "RADARR_API_KEY"),
)


def arr_services(keys):
    """The arrs worth asking, given the keys that are actually present.

    An absent key removes its arr from the list rather than failing: a stack
    running only Sonarr should still report Sonarr's failures.
    """
    return [
        {"name": name, "port": port, "key": keys.get(env)}
        for name, port, env in ARR_SERVICES
        if keys.get(env)
    ]


def _curl_config(url, method="GET"):
    """A curl config file, so the arr key never reaches argv.

    The same shape as queue_cleanup.py's, and for the same reason: `curl <url>`
    puts `?apikey=...` in the process list, where any user on the box can read
    it out of /proc/<pid>/cmdline. The blackhole runs from systemd every two
    minutes, so that would be a key on display twice a minute, forever.
    """
    lines = [f'url = "{quoted(url)}"']
    if method != "GET":
        lines.append(f'request = "{quoted(method)}"')
    return "\n".join(lines) + "\n"


class ArrApi:
    """HTTP to the arrs, behind a seam.

    Split out so tests can substitute it the way `FakeTorBox` substitutes
    TorBox: the matching logic and the ledger are what carry the risk here, and
    none of it needs a socket.
    """

    def __init__(self, timeout=30):
        self.timeout = timeout

    def get_json(self, url):
        """The parsed body, or None if the arr did not answer usefully.

        None rather than an exception. "This arr could not be asked" and "this
        arr has nothing matching" both end with nothing reported, and the
        caller has to carry on either way -- so the only difference worth
        keeping is the log line.
        """
        proc = subprocess.run(
            ["curl", "-s", "-f", "--max-time", str(self.timeout), "--config", "-"],
            input=_curl_config(url),
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            return None
        try:
            return json.loads(proc.stdout)
        except ValueError:
            # A 200 carrying an HTML error page from something in front of the
            # arr, or an empty body. Same answer as an unreachable one.
            return None

    def post(self, url):
        # -f for the same reason get_json carries it: without it curl exits 0
        # on a 4xx/5xx, so a 401 from a stale key or a 500 would be read as a
        # successful report. FailureReporter writes the ledger entry and returns
        # "reported", and the grab the arr never accepted is suppressed forever.
        proc = subprocess.run(
            ["curl", "-s", "-f", "--max-time", str(self.timeout), "--config", "-"],
            input=_curl_config(url, method="POST"),
            capture_output=True,
            text=True,
        )
        return proc.returncode == 0


class FailureReporter:
    """Resolve a dead release to the arr grab that produced it, and report it.

    Three things stand between this and blocklisting a release that was fine,
    and all three are here rather than in the caller:

      * an exact title comparison. Not case-insensitive, not normalised -- the
        arr stores the indexer's own release name as `sourceTitle`, and the NZB
        filename this resolves from is that name plus `.nzb`. Fuzzy matching
        would let `S01E08` resolve to `S01E09`, and the wrong episode gets
        blocklisted.
      * a date window, so a re-release years later cannot resolve to the
        original grab.
      * the newest match wins, because the arr writes a fresh history row on
        every grab and only the latest one is the grab this failure belongs to.

    Returns None whenever it cannot be certain, and the caller logs that.
    """

    def __init__(self, api, services, ledger=None, now=None, out=print,
                 dry_run=False):
        self.api = api
        self.services = services
        self.ledger = ledger if ledger is not None else {}
        self.now = now or datetime.now(timezone.utc)
        self.out = out
        self.dry_run = dry_run
        # One history body per arr, not one per failure. `/history/since` over
        # the 7-day window is thousands of rows (measured ~11,600 over three
        # weeks on Sonarr) behind a 30s curl timeout, and resolve() runs once
        # for every failure in the pass -- five failures re-downloaded it five
        # times to answer the same question. A reporter is built once per pass
        # in run(), so this cache lives for exactly one pass and no longer.
        # The None an unreachable arr returns is stored too: the answer cannot
        # change within the pass, and retrying it per failure would turn one
        # dead arr into one connection timeout per dead release.
        self._history_cache = {}

    def _history(self, service, since):
        name = service["name"]
        if name not in self._history_cache:
            url = (f"http://localhost:{service['port']}/api/v3/history/since"
                   f"?date={since.strftime('%Y-%m-%dT%H:%M:%SZ')}"
                   f"&apikey={service['key']}")
            self._history_cache[name] = self.api.get_json(url)
        return self._history_cache[name]

    def resolve(self, release):
        """(service, history_id, source_title) for this release, or None.

        `release` is the NZB filename without its extension. The arr writes
        `<Release.Title>.nzb`, and `.nzb` is the only thing this has to take
        off -- an arr-side normalisation of the name is exactly the failure
        mode the dry run exists to catch, so nothing is normalised here.
        """
        since = self.now - timedelta(days=HISTORY_WINDOW_DAYS)
        for service in self.services:
            records = self._history(service, since)
            if records is None:
                self.out(f"    ! {service['name']}: could not read history; "
                         f"not reporting {release}")
                continue
            if not isinstance(records, list):
                self.out(f"    ! {service['name']}: history/since returned "
                         f"{type(records).__name__}, not a list")
                continue
            matches = []
            for record in records:
                if not isinstance(record, dict):
                    continue
                if record.get("eventType") != "grabbed":
                    continue
                if record.get("sourceTitle") != release:
                    continue
                matches.append(record)
            if not matches:
                continue
            # Newest wins: several grabs of one release name are the normal
            # case here, and the failure belongs to the most recent of them.
            best = max(matches, key=lambda r: str(r.get("date") or ""))
            history_id = best.get("id")
            if history_id is None:
                self.out(f"    ! {service['name']}: matched {release} with no id")
                continue
            return service, history_id, best.get("sourceTitle")
        return None

    def report(self, release, reason_type, reason=None):
        """Resolve and report one terminal failure. Never raises.

        Returns "reported", "dry-run", "already", "no-match" or "failed" so a
        caller (and a test) can tell those apart without reading the log.

        `reason_type` is TorBox's own failure ("torbox"), this watcher's
        24-hour bound ("timeout"), or its stall rule ("stalled"), and it is part
        of the ledger key rather than decoration. A job can time out and then be
        reported again later with TorBox's real answer, and those are two
        different facts about the same grab; collapsing them into one key would
        silently drop the second.
        """
        match = self.resolve(release)
        if match is None:
            self.out(f"    ? {release}: no matching grab in either arr "
                     f"(within {HISTORY_WINDOW_DAYS}d); nothing reported")
            return "no-match"
        service, history_id, source_title = match
        key = f"{service['name']}:{history_id}:{reason_type}"
        if key in self.ledger:
            self.out(f"    ? {release}: already reported as history "
                     f"{history_id} in {service['name']}")
            return "already"
        detail = reason or reason_type
        if self.dry_run:
            # Both strings, verbatim, on their own lines. The whole point of
            # this mode is a character-for-character read of the pair, and a
            # one-line "matched X" hides a difference the eye would catch.
            self.out(f"    would report: {release}")
            self.out(f"      arr title:  {source_title}")
            self.out(f"      {service['name']} history {history_id} ({detail})")
            return "dry-run"
        url = (f"http://localhost:{service['port']}/api/v3/history/failed/"
               f"{history_id}?apikey={service['key']}")
        if not self.api.post(url):
            # Deliberately not remembered in the ledger: the arr never got the
            # message, so the next pass should try again rather than suppress a
            # report that never happened.
            self.out(f"    ! {release}: {service['name']} refused the failure "
                     f"report for history {history_id}")
            return "failed"
        self.ledger[key] = {
            "name": release,
            "service": service["name"],
            "reason": detail,
            "at": self.now.isoformat(),
        }
        self.out(f"    reported failed: {release} -> {service['name']} "
                 f"history {history_id}")
        return "reported"


def prune_ledger(ledger, now, retention_days=REPORT_LEDGER_DAYS):
    """Drop reported ids nothing has touched for `retention_days`.

    An unparseable timestamp is treated as expired, the same choice
    queue_cleanup's prune_state makes: an entry that can never age out grows
    the state file forever, and the cost of dropping it is one duplicate report
    on a grab that is already past the history window anyway.
    """
    kept = {}
    for key, entry in ledger.items():
        try:
            at = datetime.fromisoformat(str(entry.get("at", "")))
            if at.tzinfo is None:
                at = at.replace(tzinfo=timezone.utc)
            fresh = (now - at).days < retention_days
        except (AttributeError, TypeError, ValueError):
            fresh = False
        if fresh:
            kept[key] = entry
    return kept


def report_failed(reporter, release, reason_type, reason, on_report=None,
                  out=print):
    """Hand one terminal failure to the reporter, and never let it stop a pass.

    This is the whole of the "must not stop the blackhole" rule, in one place
    rather than at each call site: whatever the reporter does -- an unreachable
    arr, a malformed response, a bug in the matching -- the pass carries on.
    Moving bytes is the job; telling the arr is bookkeeping.
    """
    if reporter is None:
        return None
    try:
        outcome = reporter.report(release, reason_type, reason)
    except Exception as err:  # noqa: BLE001 - see the docstring
        out(f"    ! {release}: failure reporting raised {type(err).__name__}: {err}")
        return None
    if on_report is not None and outcome == "reported":
        # Written now rather than at the end of the pass. If the process dies
        # between here and the next save_state, a ledger that was not persisted
        # reports the same grab a second time -- and the arr would then
        # blocklist a release it had already blocked, which is harmless, or
        # mark a second grab failed, which is not.
        try:
            on_report()
        except StateError as err:
            out(f"    ! {release}: {err}")
    return outcome


# --- state -----------------------------------------------------------------

def load_state(path):
    """Jobs we have submitted and not yet finished.

    Keyed by a stable identity so a restart between submit and fetch resumes
    rather than submitting the release a second time -- TorBox would happily
    download it twice and the arr would see two folders.
    """
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {"jobs": {}}
    if not isinstance(data, dict):
        return {"jobs": {}}
    data.setdefault("jobs", {})
    return data


def save_state(path, state):
    """Write the state atomically, or raise StateError.

    Atomic because the file is what prevents a double submit: a half-written
    state read back on the next pass would look empty and TorBox would be asked
    to download every release again.
    """
    directory = os.path.dirname(path)
    try:
        if directory:
            os.makedirs(directory, exist_ok=True)
        tmp = f"{path}.tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(state, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, path)
    except OSError as err:
        raise StateError(f"cannot write {path}: {err}") from err


def backoff_until(state):
    """When submissions may resume, or None if they are not paused.

    An unparseable timestamp reads as "not paused" rather than as a failure:
    the worst case is one more refused call, where refusing to run would stop
    the whole watcher over a malformed field.
    """
    raw = state.get("rate_limited_until")
    if not raw:
        return None
    try:
        moment = datetime.fromisoformat(raw)
    except (TypeError, ValueError):
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment


def in_backoff(state, now=None):
    """Whether submissions are paused, and for how much longer."""
    until = backoff_until(state)
    if until is None:
        return None
    now = now or datetime.now(timezone.utc)
    return until if until > now else None


def note_rate_limit(state, now=None):
    """Record that TorBox refused a call, and pause submissions until it lifts."""
    now = now or datetime.now(timezone.utc)
    until = now + timedelta(hours=RATE_LIMIT_BACKOFF_HOURS)
    state["rate_limited_until"] = until.isoformat()


def job_key(nzb_path):
    """Identity for an NZB: its content hash, not its path.

    Hashing the bytes means a re-grab of the same release under a slightly
    different filename still counts as the same job, and a release the arr
    re-sends after a failure is not queued twice.

    Returns None when the file cannot be read -- the arr may have deleted it
    between the directory listing and this call.
    """
    try:
        with open(nzb_path, "rb") as handle:
            return hashlib.sha256(handle.read()).hexdigest()[:32]
    except OSError:
        return None


def is_complete_nzb(path):
    """True when this parses as an NZB with at least one file in it.

    The arr writes the whole document with one `stream.Write`, but a pass that
    reads it mid-write would submit a truncated one -- and TorBox would then
    download whatever segments survived, which arrives as a damaged release
    rather than as a failure. An unparseable NZB is skipped and retried on the
    next pass, by which time the write has finished.
    """
    try:
        root = ElementTree.parse(path).getroot()
    except (OSError, ElementTree.ParseError):
        return False
    if root.tag.split("}")[-1].lower() != "nzb":
        return False
    return any(child.tag.split("}")[-1].lower() == "file" for child in root)


def record_failure(log_path, name, reason):
    """Make a failure visible.

    A blackhole client reports no queue to the arr: a release that never
    completes is simply absent, indistinguishable from one still downloading.
    Without this line the only symptom is a title that never arrives.
    """
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        directory = os.path.dirname(log_path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(f"{stamp}\t{name}\t{reason}\n")
    except OSError as err:
        print(f"warning: could not write {log_path}: {err}", file=sys.stderr)


# --- the three steps -------------------------------------------------------

def pending_nzbs(nzb_dir, state):
    """NZBs on disk that are whole and not already in flight, in name order."""
    try:
        names = sorted(os.listdir(nzb_dir))
    except OSError:
        return []
    out = []
    for name in names:
        if not name.lower().endswith(".nzb"):
            continue
        path = os.path.join(nzb_dir, name)
        if not os.path.isfile(path) or not is_complete_nzb(path):
            continue
        key = job_key(path)
        if key is None or key in state["jobs"]:
            continue
        out.append((key, name, path))
    return out


def submit(torbox, nzb_dir, state, out=print, max_inflight=0):
    """Upload new NZBs, stopping at the in-flight ceiling. Returns the count.

    `max_inflight` is the operator's ceiling on jobs in flight, and 0 means no
    ceiling. It exists to sit below TorBox's own ten slots: measured over the
    retained window, nine of the ten were held by jobs 3-21h old while only 4
    of 50 submissions were ever fetched, so the question is whether fewer
    concurrent jobs complete more of themselves -- at 6 against 10 -- before
    any value is kept. A ceiling set too low trades wasted slots for idle ones,
    which is why this is a flag to measure with rather than a constant.
    """
    submitted = 0
    for key, name, path in pending_nzbs(nzb_dir, state):
        # Counted, not `len(state["jobs"])`. A job stays in the state file
        # until its fetch succeeds, and a finished one no longer holds a TorBox
        # slot -- so counting it would lower the effective ceiling for good on a
        # release whose fetch keeps failing, which is also never timed out.
        # Recomputed per iteration so jobs submitted earlier in this same pass
        # have no flag yet and count too.
        inflight = sum(1 for j in state["jobs"].values() if not j.get("complete"))
        # Ahead of the call, not after it: each create is a call against the
        # 60-an-hour budget, and a pass already at its ceiling has nothing to
        # ask -- the refusal would be bought with a call that bought nothing.
        if max_inflight > 0 and inflight >= max_inflight:
            out(f"    in-flight cap reached "
                f"({inflight}/{max_inflight}), stopping this pass")
            break
        release = os.path.splitext(name)[0]
        try:
            data = torbox.submit_file(path, release)
        except RateLimited as err:
            # Stop the whole pass, not just this release. The hourly budget is
            # spent, so every remaining NZB would earn the same refusal and
            # spend another call from a budget that is already empty. The
            # outbox keeps them all until the window moves.
            note_rate_limit(state)
            out(f"    ! {release}: rate limited, pausing submissions: {err}")
            break
        except ActiveLimit as err:
            # Ten downloads are already running, so every remaining NZB would
            # be refused identically -- and each refusal is a call against the
            # same 60-an-hour budget the 429 path exists to protect. Measured
            # 2026-09-14: one pass spent 51 of them this way.
            #
            # No backoff, unlike RateLimited. A slot frees by itself, and a
            # submission is the only way to find out; one probe per pass is the
            # price of noticing, and it is a submission rather than a waste
            # when a slot is free.
            out(f"    ! {release}: no free slots, stopping this pass: {err}")
            break
        except TorBoxError as err:
            out(f"    ! {release}: submit failed: {err}")
            continue
        submitted_at = datetime.now(timezone.utc).isoformat()
        state["jobs"][key] = {
            "name": release,
            "torbox_id": data.get("usenetdownload_id"),
            "hash": data.get("hash"),
            "submitted_at": submitted_at,
            # Stall detection. `last_progress` starts unset so that poll()'s
            # first pass reads it as "not yet observed" and stores the first
            # real reading and its timestamp. The stall clock starts at that
            # first-observed progress, not at submission; this initial
            # `progress_changed_at` is only a fallback for the case where
            # something reads the field before poll() overwrites it.
            "last_progress": None,
            "progress_changed_at": submitted_at,
        }
        submitted += 1
        out(f"    queued: {release} (id {data.get('usenetdownload_id')})")
    return submitted


def delete_at_torbox(torbox, job, out=print):
    """Delete one terminal job, and never let that stop the pass.

    A stalled or timed-out job has left the state file but is still ACTIVE at
    TorBox, where it goes on holding one of the account's ten concurrent slots
    until something deletes it. Freeing that slot is the entire point of the
    stall rule rather than a side effect of it.

    Best-effort, for the same reason `report_failed` is: freeing a slot is
    bookkeeping, and a TorBox that refuses the delete must not take the pass
    down with it. The job is dropped from the state either way, and the next
    job in the loop still has to be classified.

    A job with no `torbox_id` is skipped: nothing was ever submitted for it, so
    there is nothing at TorBox to delete.
    """
    usenet_id = job.get("torbox_id")
    if usenet_id is None:
        return False
    try:
        torbox.delete_usenet(usenet_id)
    except Exception as err:  # noqa: BLE001 - the delete is best-effort
        out(f"    ! {job['name']}: could not delete from TorBox: {err}")
        return False
    return True


def poll(torbox, state, timeout_hours, failed_log, now=None, out=print,
         report=None, on_report=None, stall_hours=4.0):
    """Classify in-flight jobs. Returns a list of (key, release, state).

    TorBox is the authority on completion; a job missing from its list is left
    alone rather than assumed failed, because the list is paginated and cached
    and a transient empty answer would otherwise fail every live job at once.

    `report` is the failure reporter, or None when reporting is off. All three
    terminal branches hand it the release on their way out, and all three do it
    BEFORE the job is dropped: the report is the only thing that survives as a
    record the arr can act on.

    The stalled and timed-out branches also delete the job at TorBox, because
    those are the two outcomes where it is still active and still costing a
    slot. The failed branch does not: TorBox has already stopped that one.

    `stall_hours` bounds one of those three. TorBox reports a numeric `progress`
    on every `mylist` record, and a job whose value has not moved across that
    many hours is going nowhere -- measured 2026-09-15, the oldest in-flight job
    was 21.2h old with nothing to show, holding one of the account's ten
    concurrent slots against a 24h timeout. A release that keeps moving is not
    stalled, and `timeout_hours` stays its bound.

    Nothing here runs in dry run: `run` returns before the client is built when
    `apply_changes` is false, so it never reaches this function.
    """
    results = []
    by_id = {}
    for item in torbox.list_usenet():
        if item.get("id") is not None:
            by_id[item["id"]] = item

    now = now or datetime.now(timezone.utc)
    for key, job in list(state["jobs"].items()):
        record = by_id.get(job.get("torbox_id"))
        if record is None:
            results.append((key, job["name"], "unknown"))
            continue
        state_name = (record.get("download_state") or "").lower()
        if state_name in DONE_STATES:
            # Flagged on the state entry, not merely returned in `results`. A
            # completed job no longer holds a TorBox slot, but it stays in
            # state["jobs"] until a fetch succeeds -- and if its fetch keeps
            # failing it is never timed out either, so submit() would go on
            # counting it against --max-inflight forever. Persisted by the
            # save_state run() makes after poll and fetch.
            job["complete"] = True
            results.append((key, job["name"], "complete"))
            continue
        reason = failure_reason(state_name)
        if reason is not None:
            # The reason travels into the log: "missing articles" and "the
            # provider broke" both end the job here, and only one of them means
            # the release is worth another attempt later.
            record_failure(failed_log, job["name"], f"torbox reported: {reason}")
            report_failed(report, job["name"], "torbox", reason, on_report, out)
            del state["jobs"][key]
            results.append((key, job["name"], "failed"))
            continue

        try:
            started = datetime.fromisoformat(job["submitted_at"])
        except (KeyError, ValueError):
            started = now
        if started.tzinfo is None:
            started = started.replace(tzinfo=timezone.utc)
        age_hours = (now - started).total_seconds() / 3600.0

        # Stall detection, ahead of the timeout: a job that has stopped moving
        # is not going to finish, and it costs one of ten slots for every hour
        # it is left alone. `progress` is a numeric field on every record TorBox
        # returns; a record without one is skipped rather than read as
        # "unchanged", so a schema change falls back to the timeout instead of
        # failing every live job on the first pass after it.
        progress = record.get("progress")
        if progress is not None:
            if job.get("last_progress") != progress:
                job["last_progress"] = progress
                job["progress_changed_at"] = now.isoformat()
            else:
                try:
                    moved_at = datetime.fromisoformat(job["progress_changed_at"])
                except (KeyError, TypeError, ValueError):
                    # No usable timestamp is not evidence of a stall. Treat it
                    # as "just moved" and let the next pass store one.
                    moved_at = now
                if moved_at.tzinfo is None:
                    moved_at = moved_at.replace(tzinfo=timezone.utc)
                stalled_hours = (now - moved_at).total_seconds() / 3600.0
                if stalled_hours > stall_hours:
                    detail = (f"progress stuck at {progress} in "
                              f"{state_name or 'unknown'} for {stalled_hours:.1f}h")
                    record_failure(failed_log, job["name"], detail)
                    report_failed(report, job["name"], "stalled", detail,
                                  on_report, out)
                    # The job is still running at TorBox and still holding a
                    # slot, so it has to be deleted there -- not merely
                    # forgotten here. Best-effort: see delete_at_torbox.
                    delete_at_torbox(torbox, job, out)
                    del state["jobs"][key]
                    results.append((key, job["name"], "stalled"))
                    continue

        if age_hours > timeout_hours:
            bound = f"still {state_name or 'unknown'} after {age_hours:.1f}h"
            record_failure(failed_log, job["name"], bound)
            report_failed(report, job["name"], "timeout", bound, on_report, out)
            # Same as the stall branch: past the timeout the watcher has given
            # up, but TorBox has not stopped, so the slot stays taken until the
            # download is deleted.
            delete_at_torbox(torbox, job, out)
            del state["jobs"][key]
            results.append((key, job["name"], "timeout"))
            continue
        results.append((key, job["name"], "in_progress"))
    return results


def is_rar_volume(name):
    """True for `x.rar`, `x.part03.rar`, `x.r00`..`x.r99` and `x.s00`."""
    lower = name.lower()
    if lower.endswith(".rar"):
        return True
    _, _, ext = lower.rpartition(".")
    return len(ext) == 3 and ext[0] in ("r", "s") and ext[1:].isdigit()


def find_rar_entry(directory):
    """The first volume of a RAR set in this directory, or None.

    Multi-volume sets are opened through their first file: `x.rar` (or
    `x.part01.rar`) when present, otherwise `x.r00`. Sorted, so `part01` wins
    over `part02`.
    """
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return None
    files = [n for n in names if os.path.isfile(os.path.join(directory, n))]
    for suffix in (".rar", ".r00"):
        found = [n for n in files if n.lower().endswith(suffix)]
        if found:
            return os.path.join(directory, found[0])
    return None


def unpack_rar(directory, out=print):
    """Unpack a RAR set in place and delete the volumes. Returns True if it did.

    Usenet releases are normally posted as RAR volumes, and the video is inside
    them: SABnzbd's unpack step is what turned those into a file the arr could
    import. TorBox hands back exactly what was posted, so without this the
    release arrives as eighty-odd `.rNN` files plus an un-rarred `Sample/`,
    Sonarr finds only the sample, rejects the release as a sample, and deletes
    the whole folder -- measured 2026-09-14 on the first real release through
    this path.
    """
    entry = find_rar_entry(directory)
    if entry is None:
        return False

    unrar = shutil.which("unrar")
    seven = shutil.which("7z") or shutil.which("7zr")
    if unrar:
        argv = [unrar, "x", "-o+", "-idq", entry, directory + os.sep]
    elif seven:
        argv = [seven, "x", "-y", "-bso0", "-bsp0", f"-o{directory}", entry]
    else:
        raise PermanentError(f"no unrar or 7z to unpack {os.path.basename(entry)}")

    try:
        proc = subprocess.run(argv, capture_output=True, text=True)
    except OSError as err:
        raise PermanentError(f"could not run {argv[0]}: {err}") from err
    if proc.returncode != 0:
        # A password-protected or truncated set lands here, and both are safe to
        # call permanent: the same release will fail the same way.
        detail = (proc.stderr or proc.stdout).strip().splitlines()
        raise PermanentError(
            f"{os.path.basename(argv[0])} exit {proc.returncode}: "
            f"{detail[-1][:160] if detail else 'no output'}"
        )

    removed = 0
    try:
        names = os.listdir(directory)
    except OSError as err:
        # The unpack itself worked, so this is not worth failing the release
        # over; the volumes left behind are only extra bytes in the release
        # directory.
        out(f"    ! could not list {directory} to remove the volumes: {err}")
        return True
    for name in names:
        if not is_rar_volume(name):
            continue
        path = os.path.join(directory, name)
        try:
            if os.path.isfile(path):
                os.remove(path)
                removed += 1
        except OSError as err:
            # Leftovers are not fatal, but they are worth a line: they are what
            # the arr would otherwise count towards the release size.
            out(f"    ! could not remove {name}: {err}")
    out(f"    unpacked {os.path.basename(entry)} ({removed} volume(s) removed)")
    return True


def discard_nzb(nzb_dir, name):
    """Delete a finished job's NZB, so it is never submitted again.

    The arr never cleans its own nzb folder -- for a blackhole it is an outbox,
    not a queue the arr tracks -- so a file left there is indistinguishable from
    a fresh grab on the next pass. The job is no longer in flight by then, so it
    would be submitted and downloaded a second time, and again every two
    minutes: measured 2026-09-14, a 4.6 GB release re-downloaded in full on the
    pass after the one that delivered it.
    """
    try:
        os.remove(os.path.join(nzb_dir, name + ".nzb"))
    except OSError:
        pass


def fetch(torbox, key, job, watch_dir, staging_dir, out=print):
    """Download the finished release into the watch folder.

    Staged outside the watch folder and renamed into place, because the arr
    treats a directory as complete the moment nothing inside it is locked and
    will import it after a 30-second grace period. A directory that appears
    before its contents are written gets imported half-empty, and one that
    merely *sits* in the watch folder -- `.incoming-` included -- is read as a
    finished download.
    """
    name = job["name"]
    dest = os.path.join(watch_dir, name)
    staging = os.path.join(staging_dir, key)

    if os.path.isdir(dest):
        out(f"    already in the watch folder: {name}")
        return True

    link = torbox.request_zip_link(job["torbox_id"])
    if not link:
        raise TorBoxError("no zip link returned")

    try:
        os.makedirs(watch_dir, exist_ok=True)
        os.makedirs(staging_dir, exist_ok=True)
        shutil.rmtree(staging, ignore_errors=True)
        os.makedirs(staging, exist_ok=True)
    except OSError as err:
        raise TorBoxError(f"cannot stage under {staging_dir}: {err}") from err

    zip_path = os.path.join(staging, "payload.zip")
    try:
        # Through a curl config on stdin, so the link stays off argv. TorBox's
        # download URLs carry the account token in their own query string, and
        # an argv copy is readable by anything on the box through
        # /proc/<pid>/cmdline -- the same leak the shell wrapper used to have.
        subprocess.run(
            ["curl", "-sS", "-f", "-L", "--max-time", "3600", "--config", "-"],
            input=f'url = "{quoted(link)}"\noutput = "{quoted(zip_path)}"\n',
            check=True,
            capture_output=True,
            text=True,
        )
        try:
            archive = zipfile.ZipFile(zip_path)
        except zipfile.BadZipFile as err:
            raise PermanentError(f"TorBox returned something that is not a zip: {err}") from err
        with archive:
            # Zip entries from TorBox can carry path traversal; refuse rather
            # than write outside the staging directory.
            root = os.path.realpath(staging)
            for member in archive.namelist():
                target = os.path.realpath(os.path.join(staging, member))
                if not target.startswith(root + os.sep):
                    raise PermanentError(f"zip entry escapes the target: {member}")
            archive.extractall(staging)
        os.remove(zip_path)

        # TorBox zips the release inside a folder of its own name; unwrap it so
        # the arr sees the video files directly under the release directory.
        entries = [e for e in os.listdir(staging) if not e.startswith(".")]
        if len(entries) == 1 and os.path.isdir(os.path.join(staging, entries[0])):
            inner = os.path.join(staging, entries[0])
            for entry in os.listdir(inner):
                shutil.move(os.path.join(inner, entry), os.path.join(staging, entry))
            os.rmdir(inner)

        # ...and the release itself is usually inside RAR volumes, which the arr
        # cannot read. This is SABnzbd's unpack step, and it runs BEFORE the
        # rename: an un-unpacked release that reaches the watch folder is
        # rejected as a sample and deleted.
        unpack_rar(staging, out=out)

        os.replace(staging, dest)
        out(f"    fetched: {name}")
        return True
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def sweep_staging(staging_dir, keep, older_than_hours=STALE_STAGING_HOURS,
                  now=None, out=print):
    """Delete staging directories that no job is going to claim.

    `fetch` reuses a job's own staging path and wipes it first, so a retry of the
    same release cleans up after itself. A release that failed, timed out, or was
    superseded leaves its half-written copy behind with nothing left to claim it
    -- invisible to the arr, which never looks in here, and worth ~800 MB a time
    on a NAS where nobody would think to look.
    """
    now = now or datetime.now(timezone.utc)
    try:
        entries = os.listdir(staging_dir)
    except OSError:
        return 0
    removed = 0
    for entry in entries:
        path = os.path.join(staging_dir, entry)
        if entry in keep or not os.path.isdir(path):
            continue
        try:
            written = datetime.fromtimestamp(os.path.getmtime(path), timezone.utc)
        except OSError:
            continue
        if (now - written).total_seconds() / 3600.0 < older_than_hours:
            continue
        try:
            shutil.rmtree(path)
        except OSError as err:
            # Reported rather than ignored: `ignore_errors=True` here would let a
            # directory that survived the delete still count as cleared, which is
            # the one thing this sweep exists to prevent.
            out(f"    ! could not clear staging {entry}: {err}")
            continue
        removed += 1
        out(f"    cleared stale staging: {entry}")
    return removed


def _fetch_one(torbox, key, job, watch_dir, staging_dir):
    """Fetch one release, keeping its output to itself.

    `fetch` narrates as it goes, and those lines would interleave into
    nonsense if three of them shared a stream. Each call collects into its own
    list and the caller prints them whole, so the log still reads as one
    release at a time even though the work overlapped.
    """
    lines = []
    try:
        ok = fetch(torbox, key, job, watch_dir, staging_dir, out=lines.append)
        return ok, lines, None
    except Exception as err:  # noqa: BLE001 - classified by the caller
        return False, lines, err


def run(nzb_dir, watch_dir, staging_dir, state_path, failed_log, api_key,
        apply_changes=False, timeout_hours=24.0, stall_hours=4.0, verbose=False,
        out=print, arr_keys=None, report_failures=False, report_dry_run=False,
        max_inflight=0):
    """One pass: submit new NZBs, poll in-flight jobs, fetch completed ones.

    `report_failures` is off by default and reported off in the summary, so a
    pass that says nothing about failures is not also a pass that could have
    said something and chose not to. `report_dry_run` resolves the match and
    logs both titles without calling anything -- the mode the rollout runs for
    a day first.

    `max_inflight` is the operator's ceiling on jobs in flight; 0 is no
    ceiling, so the default pass behaves exactly as it did before the flag.
    """
    state = load_state(state_path)

    if nzb_dir and os.path.isdir(nzb_dir):
        out(f"  NZB folder:   {nzb_dir}")
    out(f"  watch folder: {watch_dir}")
    out(f"  staging:      {staging_dir}")
    out(f"  in flight:    {len(state['jobs'])}")

    if not apply_changes:
        for key, name, path in pending_nzbs(nzb_dir, state):
            out(f"    would submit: {name}")
        for key, job in state["jobs"].items():
            out(f"    in flight: {job['name']} (torbox id {job.get('torbox_id')})")
        return 0

    torbox = TorBox(api_key)

    # Reporting and the ledger it maintains. Both dry-run and live need the
    # reporter -- dry run is a resolver that logs; live is a resolver that
    # POSTs -- so it is built for either, and only for either.
    reporter = None
    on_report = None
    if report_failures or report_dry_run:
        services = arr_services(arr_keys or {})
        # The ledger grows one entry per reported failure and nothing else ever
        # removes one, so it is pruned on every pass that could add to it.
        state["reported"] = prune_ledger(
            state.get("reported") or {}, datetime.now(timezone.utc))
        ledger = state["reported"]
        if not services:
            out("  failure reporting: no SONARR_API_KEY or RADARR_API_KEY set; "
                "nothing will be reported")
        else:
            reporter = FailureReporter(ArrApi(), services, ledger=ledger,
                                       now=datetime.now(timezone.utc), out=out,
                                       dry_run=report_dry_run)
            out(f"  failure reporting: {'dry run' if report_dry_run else 'on'} "
                f"({', '.join(s['name'] for s in services)})")

            def on_report():
                save_state(state_path, state)

    paused_until = in_backoff(state)
    if paused_until is not None:
        # Submissions are the only thing that pauses. Polling and fetching run
        # as normal, so downloads already in flight still finish; the outbox
        # simply waits. Saying so every pass is the point: otherwise a quiet
        # log reads as "nothing pending" rather than "deliberately holding".
        wait = paused_until - datetime.now(timezone.utc)
        out(f"  submissions paused for {wait.total_seconds() / 60:.0f}m more "
            f"(until {paused_until.astimezone(timezone.utc).strftime('%H:%M')}Z)")
        submitted = 0
    else:
        # Past the deadline, so the marker is stale. Dropping it here rather
        # than inside in_backoff keeps that a question with no side effects.
        state.pop("rate_limited_until", None)
        submitted = submit(torbox, nzb_dir, state, out=out,
                           max_inflight=max_inflight)
    save_state(state_path, state)

    results = list(poll(torbox, state, timeout_hours, failed_log, out=out,
                        report=reporter, on_report=on_report,
                        stall_hours=stall_hours))

    # Anything that is not a completed download settles here first. A failure,
    # a timeout or a stall is terminal and costs one line to record; the fetch
    # is the only part of a pass that takes minutes, so it goes last and in
    # parallel.
    #
    # The NZB has to be discarded for all three. Leaving it in the outbox is
    # what turns a terminal failure into a retry storm: the arr never cleans
    # that folder itself, so the next pass -- two minutes later -- finds the
    # same file, submits the same dead release, and pays another slot for it.
    for key, name, status in results:
        if status in ("failed", "timeout", "stalled"):
            discard_nzb(nzb_dir, name)
            if status == "timeout":
                out(f"    ! {name}: timed out")
            elif status == "stalled":
                out(f"    ! {name}: stalled")
        elif status != "complete" and verbose:
            out(f"    ... {name}: {status}")

    fetched = 0
    to_fetch = [(key, name) for key, name, status in results if status == "complete"]
    if to_fetch:
        with ThreadPoolExecutor(max_workers=min(FETCH_WORKERS, len(to_fetch))) as pool:
            pending = {
                pool.submit(_fetch_one, torbox, key, state["jobs"][key],
                            watch_dir, staging_dir): (key, name)
                for key, name in to_fetch
            }
            for future in as_completed(pending):
                key, name = pending[future]
                ok, lines, err = future.result()
                for line in lines:
                    out(line)
                if ok:
                    del state["jobs"][key]
                    fetched += 1
                    discard_nzb(nzb_dir, name)
                elif isinstance(err, PermanentError):
                    # Nothing will change on a retry, and a retry re-downloads
                    # the whole release. Record it, drop it, and clear the NZB
                    # so the next pass does not pick the same release up
                    # again.
                    record_failure(failed_log, name, f"unusable: {err}")
                    del state["jobs"][key]
                    discard_nzb(nzb_dir, name)
                    out(f"    ! {name}: {err}")
                else:
                    # One bad release must not stop the sweep, and a transient
                    # failure must leave the job in place to be retried.
                    out(f"    ! {name}: fetch failed, will retry: {err}")
    save_state(state_path, state)

    sweep_staging(staging_dir, set(state["jobs"]), out=out)

    out(f"  submitted {submitted}, fetched {fetched}, still in flight {len(state['jobs'])}")
    return 0


def positive_hours(value):
    """argparse type for --stall-hours: a number, and strictly above zero.

    Zero is the one value that makes the stall rule fire on the first poll
    after a job is submitted -- `stalled_hours > stall_hours` is true the
    moment the clock starts -- so a live pass would fail every in-flight job
    it has. It parses as a float and would otherwise run, so it is refused
    here, at the argument, rather than left to the loop it disables.
    """
    try:
        hours = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a number: {value!r}")
    if not hours > 0:  # `not >` rather than `<=` so nan is refused too
        raise argparse.ArgumentTypeError(
            f"must be greater than 0, got {value!r}")
    return hours


def non_negative_int(value):
    """argparse type for --max-inflight: a whole number, and not negative.

    Zero is the off switch and is accepted. A negative number is the one value
    that would silently disable submitting altogether: `inflight >=
    max_inflight` is true before the first offer, so every pass would break out
    of the loop having offered nothing, the outbox would grow without bound,
    and the log line would say the ceiling had been reached.
    """
    try:
        count = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a whole number: {value!r}")
    if count < 0:
        raise argparse.ArgumentTypeError(
            f"must not be negative, got {value!r}")
    return count


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("nzb_dir")
    parser.add_argument("watch_dir")
    parser.add_argument("staging_dir")
    parser.add_argument("state_path")
    parser.add_argument("failed_log")
    parser.add_argument("--api-key", default=os.environ.get("TORBOX_API_KEY", ""))
    parser.add_argument("--apply", action="store_true", help="do it (default: dry run)")
    parser.add_argument("--timeout-hours", type=float, default=24.0)
    parser.add_argument("--stall-hours", type=positive_hours, default=4.0,
                        help="fail a job whose reported progress has not moved "
                             "for this many hours (default: 4)")
    parser.add_argument("--max-inflight", type=non_negative_int, default=0,
                        help="stop submitting once this many jobs are in "
                             "flight (default: 0, no ceiling)")
    parser.add_argument("--verbose", "-v", action="store_true")
    parser.add_argument("--report-failures", action="store_true",
                        help="tell the owning arr when a release fails for good")
    parser.add_argument("--report-dry-run", action="store_true",
                        help="log the failures that would be reported, and call nothing")
    args = parser.parse_args(argv)

    if args.apply and not args.api_key:
        print("ERROR: no API key (--api-key or TORBOX_API_KEY)", file=sys.stderr)
        return 2

    arr_keys = {name: os.environ.get(env, "")
                for name, _port, env in ARR_SERVICES}

    try:
        return run(
            args.nzb_dir,
            args.watch_dir,
            args.staging_dir,
            args.state_path,
            args.failed_log,
            args.api_key,
            apply_changes=args.apply,
            timeout_hours=args.timeout_hours,
            stall_hours=args.stall_hours,
            verbose=args.verbose,
            arr_keys=arr_keys,
            report_failures=args.report_failures,
            report_dry_run=args.report_dry_run,
            max_inflight=args.max_inflight,
        )
    except StateError as err:
        # One line, not a traceback: whoever reads the timer's log needs to know
        # that releases may be submitted twice until this is fixed.
        print(f"ERROR: {err}", file=sys.stderr)
        print("ERROR: releases already submitted may be sent again", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
