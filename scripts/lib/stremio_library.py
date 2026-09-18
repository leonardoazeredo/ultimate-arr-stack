#!/usr/bin/env python3
"""Request Stremio library additions in Seerr, so they download on the NAS.

Why this exists
---------------
Adding a title to the Stremio library is one tap on a phone, and nothing in this
stack was listening to it. Seerr is the front door for every other request here,
so this is a bridge between the two: read the Stremio account's `libraryItem`
collection, resolve each newly added title to a TMDB id, and create the Seerr
request that routes it to Sonarr or Radarr.

Why it polls rather than listens
--------------------------------
Stremio shipped a push mechanism for exactly this -- a `library` addon resource
whose handler fires on `libraryAdd` -- and then removed it. It is not in the
current SDK: `defineLibraryHandler` is absent from `builder.js` on master, its
documentation is 404 on master and survives only at commit cbc2e04, and the
manifest linter's recognised resource set is `catalog, meta, stream, subtitles`.
There is no supported way to be told, so the datastore is read on a timer.
`POST https://api.strem.io/api/datastoreGet` with
`{"authKey": ..., "collection": "libraryItem", "all": true}` returns the whole
collection in one call -- measured 2026-09-17 from this NAS: HTTP 200, 1078
records, 575 KB.

The collection is not the library
---------------------------------
Those 1078 records are 145 library items. The rest are tombstones and viewing
history: 933 carry `removed: true` and 883 `temp: true`, because Stremio writes a
record when you merely *watch* something and marks it temporary rather than
leaving no trace. `library_entries()` keeps only `not removed and not temp`,
which is the difference between "I added this" and "I watched this once in
2023". Without that filter the first pass would request the account's entire
viewing history.

Two more things the raw records do not tell you:

  * The id is not always an IMDB id. Measured on the real library: 143 of the
    145 are `tt...`, and 2 are `tmdb:374052`-style, because the id comes from
    whichever meta provider supplied the item.

  * Seerr cannot resolve an IMDB id itself. `GET /api/v1/search?query=tt1588170`
    returns zero results -- measured, not assumed -- so the id has to be
    translated first. Cinemeta does it keylessly and is already in the path of
    every one of these titles: `/meta/movie/tt0072890.json` carries
    `moviedb_id: 968`, and the series form carries `moviedb_id` and `tvdb_id`.
    Searching Seerr by name is not a substitute: "I Saw the Devil" returns four
    results, including a remake and an unrelated TV show.

Requesting, and what stops it running away
------------------------------------------
`POST /api/v1/request` with `{"mediaType": ..., "mediaId": <tmdb>}`, plus
`"seasons": "all"` for a series, is the whole call. The Seerr API documents that
an `ADMIN` or `AUTO_APPROVE` user's request is approved automatically, and the
one account on this instance is an admin, so the request reaches Sonarr or
Radarr immediately and the download starts. Nothing else needs passing: both arr
instances are configured in Seerr as defaults, each with its own profile and root
folder.

The pacing matters more than the mechanism. `logs/stremio-library-sync-state.json`
records what has been handled, and this module never marks something handled that
it did not act on -- so a bounded pass resumes where it left off instead of
losing the remainder. Three bounds keep a first run from becoming the burst that
earned this TorBox account a 90-minute refusal:

  * A first run with no state file **baselines**: it records every item already
    in the library and requests none of them. Measured on this library, 122 of
    the 145 items are in neither arr, and requesting them in one pass is the
    exact shape of that burst. `--backfill` asks for them deliberately, and
    `--max` still applies.
  * `--max` (default 3) caps how many requests one pass creates. The remainder
    waits for the next pass, which is what makes a ten-minute timer safe.
  * A dry run is the default and writes no state at all, so inspecting the queue
    is never the thing that consumes it.

What it will not do
-------------------
Removing a title from the Stremio library does nothing here. A library edit is a
low-stakes action on a phone, and wiring it to a delete from disk is not a trade
worth making silently. Nothing in this module deletes anything.

An id it cannot resolve is recorded as unresolved and skipped, once. It is not
retried every ten minutes, and it is not guessed at from the title: a wrong
request downloads the wrong film, which is worse than a missed one.

Usage:
  stremio_library.py <state-path> [--apply] [--backfill] [--max N] [--verbose]
                     [--seerr-url URL]
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

STREMIO_DATASTORE_URL = "https://api.strem.io/api/datastoreGet"
CINEMETA_URL = "https://v3-cinemeta.strem.io"
DEFAULT_SEERR_URL = "http://localhost:5055"

LIBRARY_COLLECTION = "libraryItem"

# A pass creates at most this many requests. The timer runs every ten minutes,
# so three is roughly eighteen an hour at the very most, and in practice a pass
# has one or two to make because a person adds titles at human speed. The cap is
# for the case where that is not true: a bulk import, a restored account, or the
# `--backfill` run over a library that is mostly missing.
DEFAULT_MAX_REQUESTS = 3

REQUEST_TIMEOUT = 30

# Every request carries a User-Agent, and it is load-bearing rather than
# manners. On 2026-09-18 `v3-cinemeta.strem.io` began answering 307 to
# `cinemeta-live.strem.io`, and that host refuses urllib's default
# `Python-urllib/3.11` signature with `HTTP 403  error code: 1010` -- a
# Cloudflare signature block, not a rate limit and not an entitlement. The same
# URL returns 200 with any other name, the honest one below included, so there
# is nothing to impersonate.
#
# Without this, every metadata lookup fails, and the sync does not degrade -- it
# stops. Measured: the first version of this module sent no User-Agent and sat
# dead for ten hours from 00:43 to 10:52 on 2026-09-18, one failed pass every
# ten minutes, having stopped on the first title it could not look up. See
# MAX_LOOKUP_FAILURES for the other half of that failure.
USER_AGENT = "arr-stack-stremio-library-sync/1.0"

# How many metadata lookups may fail in a row before a pass gives up.
#
# One unlookupable title must not end a pass: it stays pending and is retried,
# and the pass moves to the next one. But a provider that is down altogether
# would otherwise turn one pass into one lookup per pending title -- 145 of them
# on this library -- every ten minutes. Three in a row reads as "the provider is
# unreachable" rather than "this title is odd", so the pass stops there and
# exits non-zero, leaving everything not yet acted on pending for the next one.
MAX_LOOKUP_FAILURES = 3

# MediaInfo.status, as the Seerr API describes the field: 1 UNKNOWN, 2 PENDING,
# 3 PROCESSING, 4 PARTIALLY_AVAILABLE, 5 AVAILABLE, 6 DELETED. Only 5 stops a
# request. Status 4 is deliberately not on that list: a series you own one
# season of is one you want the rest of, and Sonarr only grabs monitored,
# missing episodes, so asking for it again is how the rest arrives.
MEDIA_AVAILABLE = 5

# The library item types that map onto something Seerr can be asked about.
# Stremio's other types ("other", "channel", ...) have no Radarr or Sonarr
# counterpart, and Seerr accepts only `movie` and `tv`.
MEDIA_TYPES = {
    "movie": "movie",
    "series": "tv",
    "anime": "tv",
    "tv": "tv",
}

# Cinemeta serves one path per content type and knows nothing about "anime".
# Only these two are ever asked for.
CINEMETA_TYPES = {"movie": "movie", "series": "series"}


class HttpError(Exception):
    """A request that did not produce JSON.

    `status` is the HTTP status, or None when no response arrived at all (DNS,
    refused connection, timeout). Callers distinguish 404 from a transport
    failure, so the two cannot share an exception class without carrying the
    status.
    """

    def __init__(self, status, detail, url):
        self.status = status
        self.detail = detail
        self.url = url
        super().__init__("HTTP %s from %s: %s" % (status, url, detail))


class StateError(Exception):
    """The state file exists and cannot be trusted."""


class Http:
    """JSON over HTTP, in the one shape the callers here need.

    A class rather than a module-level function so tests can substitute a fake
    wholesale -- the same seam `backlog_search.ArrApi` gives its tests.
    """

    def __init__(self, timeout=REQUEST_TIMEOUT):
        self.timeout = timeout

    def json(self, url, method="GET", headers=None, data=None):
        body = None
        hdrs = dict(headers or {})
        # Every caller gets the User-Agent, and a caller that sets its own keeps
        # it. See USER_AGENT above: this is the difference between a working
        # metadata lookup and `HTTP 403  error code: 1010`.
        hdrs.setdefault("User-Agent", USER_AGENT)
        if data is not None:
            body = json.dumps(data).encode()
            hdrs["Content-Type"] = "application/json"

        request = urllib.request.Request(url, data=body, headers=hdrs,
                                         method=method)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as err:
            # The body is worth keeping: Seerr puts the reason in it ("Request
            # for this media already exists", say), and a bare status code
            # sends the reader to the container logs for something the response
            # already said.
            try:
                detail = err.read()[:200].decode("utf-8", "replace")
            except OSError:
                detail = ""
            raise HttpError(err.code, detail, url) from None
        except urllib.error.URLError as err:
            raise HttpError(None, str(err.reason), url) from None

        try:
            return json.loads(raw)
        except ValueError as err:
            raise HttpError(None, "response was not JSON (%s); first 200 bytes: %r"
                            % (err, raw[:200]), url) from None


class StremioClient:
    """The Stremio account's datastore."""

    def __init__(self, auth_key, http, url=STREMIO_DATASTORE_URL):
        self.auth_key = auth_key
        self.http = http
        self.url = url

    def library_items(self):
        """Every record in the `libraryItem` collection, filtered or not.

        The API answers HTTP 200 whether or not it liked the request: an
        expired or wrong key comes back as
        `{"error": {"code": 1, "message": "Session does not exist"}}` with a
        200, measured 2026-09-17. So a caller that only checks the status sees
        success and an absent `result` -- and an absent `result` that is read as
        an empty library is a bridge that stops working and reports nothing at
        all. Both halves are checked here instead.
        """
        doc = self.http.json(self.url, method="POST", data={
            "authKey": self.auth_key,
            "collection": LIBRARY_COLLECTION,
            "all": True,
        })

        if not isinstance(doc, dict):
            raise HttpError(None, "expected a JSON object", self.url)

        error = doc.get("error")
        if error:
            message = error.get("message") if isinstance(error, dict) else error
            raise HttpError(None, "Stremio rejected the auth key: %s" % message,
                            self.url)

        result = doc.get("result")
        if not isinstance(result, list):
            raise HttpError(None, "no `result` list in the response", self.url)
        return result


class CinemetaClient:
    """IMDB id to TMDB id, through the meta provider Stremio itself uses."""

    def __init__(self, http, url=CINEMETA_URL):
        self.http = http
        self.url = url.rstrip("/")

    def tmdb_id(self, item_type, imdb_id):
        """The TMDB id for an IMDB id, or None when there is no mapping.

        None and an exception mean different things and the caller acts on the
        difference: None is Cinemeta answering that this title has no TMDB id,
        which will not change on a retry. A raised HttpError is Cinemeta being
        unreachable, which will.
        """
        cinemeta_type = CINEMETA_TYPES.get(item_type)
        if cinemeta_type is None:
            return None

        doc = self.http.json("%s/meta/%s/%s.json" % (self.url, cinemeta_type, imdb_id))
        meta = doc.get("meta") if isinstance(doc, dict) else None
        if not isinstance(meta, dict):
            return None

        tmdb_id = meta.get("moviedb_id")
        # Cinemeta has been seen to carry this as a string as well as a number.
        # `int()` on a non-numeric value raises, and a raise here would be read
        # upstream as "retry later" for a title that will never resolve.
        try:
            return int(tmdb_id)
        except (TypeError, ValueError):
            return None


class SeerrClient:
    """The request portal's v1 API."""

    def __init__(self, base_url, api_key, http):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.http = http

    def _headers(self):
        return {"X-Api-Key": self.api_key}

    def media_info(self, media_type, tmdb_id):
        """Seerr's view of a title, or None when it has no record of one.

        A 404 is a real answer and not a failure: it means Seerr has never been
        asked about this title, which is exactly the case worth requesting. Any
        other status travels on, because "I could not ask" must never be read as
        "not there" and turned into a request.
        """
        path = "/api/v1/movie/%d" % tmdb_id if media_type == "movie" \
            else "/api/v1/tv/%d" % tmdb_id
        try:
            doc = self.http.json(self.base_url + path, headers=self._headers())
        except HttpError as err:
            if err.status == 404:
                return None
            raise
        info = doc.get("mediaInfo") if isinstance(doc, dict) else None
        return info if isinstance(info, dict) else {}

    def request(self, media_type, tmdb_id):
        payload = {"mediaType": media_type, "mediaId": tmdb_id}
        if media_type == "tv":
            # Every season. Seerr sorts out which ones it already has, and
            # naming seasons individually would mean fetching the season list
            # just to repeat what Seerr already knows.
            payload["seasons"] = "all"
        return self.http.json(self.base_url + "/api/v1/request", method="POST",
                              headers=self._headers(), data=payload)


def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def library_entries(items):
    """The user's actual library, from the raw datastore records.

    Two filters, and both are load bearing. `removed` marks a tombstone: the
    record survives the delete so other clients learn about it. `temp` marks a
    record Stremio wrote because the title was *watched*, not because it was
    added. On the library this was written against that is 145 items out of
    1078 -- so the unfiltered version requests 933 titles nobody asked for.

    Returned oldest first. A pass that only gets partway through a backlog --
    by `--max`, or by the box rebooting -- then resumes in the order the titles
    were added rather than re-serving whatever the API happened to sort first.
    The id breaks ties so the order is stable across runs.
    """
    entries = []
    for item in items:
        if not isinstance(item, dict):
            continue
        if item.get("removed") or item.get("temp"):
            continue
        item_id = item.get("_id")
        if not item_id:
            continue
        entries.append({
            "id": item_id,
            "type": item.get("type") or "",
            "name": item.get("name") or "",
            "ctime": item.get("_ctime") or "",
        })
    return sorted(entries, key=lambda e: (e["ctime"], e["id"]))


def resolve(entry, cinemeta):
    """`(media_type, tmdb_id)` for a library entry, or None if there is none.

    Three inputs reach this and each takes a different route:

      `tmdb:374052`   the id *is* the TMDB id, so nothing is looked up.
      `tt...`         IMDB, so Cinemeta translates it.
      anything else   `kitsu:` and whatever else a catalog invents. Seerr has
                      no way to be asked about these, and guessing from the
                      title is how the wrong film gets downloaded.

    Raises HttpError when the lookup could not be made; returns None only when
    the answer was that there is no mapping. See CinemetaClient.tmdb_id.
    """
    media_type = MEDIA_TYPES.get(entry["type"])
    if media_type is None:
        return None

    item_id = entry["id"]

    if ":" in item_id:
        prefix, _, value = item_id.partition(":")
        if prefix != "tmdb":
            return None
        try:
            return media_type, int(value)
        except ValueError:
            return None

    if not item_id.startswith("tt"):
        return None

    tmdb_id = cinemeta.tmdb_id(entry["type"], item_id)
    if tmdb_id is None:
        return None
    return media_type, tmdb_id


def already_coming(info):
    """Whether Seerr already has this title requested or in the library.

    `requests` covers both an outstanding request and one that has been filled:
    an approved request stays on the record. Status 5 is the belt to that
    braces, and it is the one that matters for a title that arrived in Jellyfin
    without ever going through Seerr at all -- a file copied in by hand is
    AVAILABLE with no request anywhere.
    """
    if not info:
        return False
    if info.get("requests"):
        return True
    return info.get("status") == MEDIA_AVAILABLE


def load_state(path):
    """The state document, or None when there has never been one.

    None is not an error and is not the same as empty: it is the first run, and
    the first run baselines. That distinction is the whole reason this returns
    None rather than `{}`.

    An unreadable or malformed file is fatal instead of being replaced. The
    state is what stops a pass re-requesting everything it already handled, so
    silently starting over from empty is a burst, not a recovery.
    """
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError) as err:
        raise StateError("state file %s is unreadable (%s)" % (path, err)) from None

    if not isinstance(doc, dict) or not isinstance(doc.get("handled"), dict):
        raise StateError("state file %s has no `handled` mapping" % path)
    return doc


def save_state(path, doc):
    """Write the state atomically.

    Through a temporary file and a rename, because the alternative is a pass
    killed mid-write truncating the only record of what has already been
    requested -- which the next pass reads as a first run.
    """
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(doc, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, path)
    except OSError as err:
        raise StateError("could not write state file %s (%s)" % (path, err)) from None


def new_state():
    return {"version": 1, "baselined_at": None, "handled": {}}


def run(stremio, cinemeta, seerr, state_path, apply_changes=False,
        backfill=False, max_requests=DEFAULT_MAX_REQUESTS, verbose=False,
        out=print):
    """One pass. Returns 0, or 1 when a request was attempted and failed."""
    items = stremio.library_items()
    entries = library_entries(items)
    out("Stremio datastore: %d records, %d of them library items"
        % (len(items), len(entries)))

    state = load_state(state_path)

    if state is None:
        state = new_state()
        state["baselined_at"] = now_iso()
        if not backfill:
            for entry in entries:
                state["handled"][entry["id"]] = {
                    "name": entry["name"],
                    "type": entry["type"],
                    "result": "baselined",
                    "at": state["baselined_at"],
                }
            if apply_changes:
                save_state(state_path, state)
            out("First run: recorded %d existing item(s) and requested nothing."
                % len(entries))
            out("  Re-run with --backfill to request them, %d per pass."
                % max_requests)
            return 0
        out("First run with --backfill: all %d item(s) are candidates."
            % len(entries))

    pending = [entry for entry in entries if entry["id"] not in state["handled"]]
    if not pending:
        out("Nothing new since the last pass.")
        return 0

    out("%d new item(s) since the last pass." % len(pending))
    if max_requests and len(pending) > max_requests:
        out("  --max %d: %d of them wait for a later pass."
            % (max_requests, len(pending) - max_requests))
        pending = pending[:max_requests]

    requested = skipped = failed = 0
    lookup_failures = 0

    for entry in pending:
        label = "%s (%s)" % (entry["name"] or "?", entry["id"])

        try:
            resolved = resolve(entry, cinemeta)
        except HttpError as err:
            # A lookup that could not be made is not an answer, and it must not
            # end the pass: the next pass retries, and the titles behind this one
            # still get their turn. This used to propagate, which is what turned
            # a Cloudflare block on one title into a dead sync on 2026-09-18 --
            # ten hours of identical failures, no progress, and the only line in
            # the log naming a single library id rather than the provider.
            out("  FAIL     %s: metadata lookup failed (%s)" % (label, err))
            failed += 1
            lookup_failures += 1
            if lookup_failures >= MAX_LOOKUP_FAILURES:
                out("  stopping: %d lookups failed in a row, which reads as the meta "
                    "provider being unreachable rather than one odd title. "
                    "Everything not acted on stays pending for the next pass."
                    % lookup_failures)
                break
            continue
        lookup_failures = 0

        if resolved is None:
            # Recorded, so the next pass does not re-resolve it every ten
            # minutes forever. A transient failure raises and is handled above,
            # which leaves the item pending.
            out("  skip     %s: no TMDB id could be resolved" % label)
            state["handled"][entry["id"]] = {
                "name": entry["name"], "type": entry["type"],
                "result": "unresolved", "at": now_iso(),
            }
            skipped += 1
            continue

        media_type, tmdb_id = resolved

        try:
            info = seerr.media_info(media_type, tmdb_id)
        except HttpError as err:
            out("  FAIL     %s: Seerr lookup failed (%s)" % (label, err))
            failed += 1
            continue

        if already_coming(info):
            # The status is only worth a line when someone is debugging why a
            # title did not get requested; on an ordinary pass this is noise.
            detail = " (status %s)" % (info or {}).get("status") if verbose else ""
            out("  skip     %s: Seerr already has it%s" % (label, detail))
            state["handled"][entry["id"]] = {
                "name": entry["name"], "type": entry["type"], "tmdb": tmdb_id,
                "result": "already-in-seerr", "at": now_iso(),
            }
            skipped += 1
            continue

        if not apply_changes:
            out("  would    %s -> %s request, tmdb %d" % (label, media_type, tmdb_id))
            # Deliberately not recorded. A dry run that consumed the queue would
            # mean the inspection pass was the one that changed the answer.
            requested += 1
            continue

        try:
            seerr.request(media_type, tmdb_id)
        except HttpError as err:
            if err.status == 409:
                out("  skip     %s: Seerr reports a request already exists" % label)
                state["handled"][entry["id"]] = {
                    "name": entry["name"], "type": entry["type"], "tmdb": tmdb_id,
                    "result": "already-requested", "at": now_iso(),
                }
                skipped += 1
                continue
            out("  FAIL     %s: request failed (%s)" % (label, err))
            failed += 1
            continue

        out("  request  %s -> %s request, tmdb %d" % (label, media_type, tmdb_id))
        state["handled"][entry["id"]] = {
            "name": entry["name"], "type": entry["type"], "tmdb": tmdb_id,
            "result": "requested", "at": now_iso(),
        }
        requested += 1

    if apply_changes:
        save_state(state_path, state)

    if verbose:
        out("  state: %d item(s) handled, %s"
            % (len(state["handled"]), state_path))

    verb = "requested" if apply_changes else "would be requested"
    out("%d %s, %d skipped, %d failed"
        % (requested, verb, skipped, failed))
    if not apply_changes and requested:
        out("  Dry run: nothing was requested and no state was written.")

    # A failed request is the only outcome worth a non-zero exit. The unit is
    # oneshot, so this is what makes a run that could not reach Seerr visible in
    # `systemctl --user status` rather than only in the log.
    return 1 if failed else 0


def non_negative_int(value):
    """argparse type for --max: a whole number, and not negative.

    Zero is the off switch and is accepted. A negative value is the one input
    that would make `pending[:max_requests]` silently drop items from the end
    instead of bounding the pass, so it is refused at the argument.
    """
    try:
        count = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("not a whole number: %r" % (value,))
    if count < 0:
        raise argparse.ArgumentTypeError("must not be negative, got %r" % (value,))
    return count


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("state_path")
    parser.add_argument("--apply", action="store_true",
                        help="create the requests (default: dry run)")
    parser.add_argument("--backfill", action="store_true",
                        help="on a first run, request everything already in the "
                             "library instead of only recording it")
    parser.add_argument("--max", type=non_negative_int,
                        default=DEFAULT_MAX_REQUESTS,
                        help="most requests to create in one pass (default: %d; "
                             "0 for no ceiling)" % DEFAULT_MAX_REQUESTS)
    parser.add_argument("--verbose", "-v", action="store_true")
    parser.add_argument("--seerr-url", default=os.environ.get("SEERR_URL")
                        or DEFAULT_SEERR_URL)
    args = parser.parse_args(argv)

    auth_key = os.environ.get("STREMIO_AUTH_KEY", "")
    seerr_key = os.environ.get("SEERR_API_KEY", "")

    # Named rather than assumed: `--apply` with no key would otherwise run, fail
    # on the first request, and report it as a Seerr problem.
    if not auth_key:
        print("ERROR: STREMIO_AUTH_KEY is not set", file=sys.stderr)
        return 2
    if not seerr_key:
        print("ERROR: SEERR_API_KEY is not set", file=sys.stderr)
        return 2

    http = Http()
    try:
        return run(
            StremioClient(auth_key, http),
            CinemetaClient(http),
            SeerrClient(args.seerr_url, seerr_key, http),
            args.state_path,
            apply_changes=args.apply,
            backfill=args.backfill,
            max_requests=args.max,
            verbose=args.verbose,
        )
    except StateError as err:
        # One line, not a traceback: until this is fixed the next pass may
        # re-request titles this one already handled.
        print("ERROR: %s" % err, file=sys.stderr)
        print("ERROR: items already requested may be requested again", file=sys.stderr)
        return 1
    except HttpError as err:
        print("ERROR: %s" % err, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
