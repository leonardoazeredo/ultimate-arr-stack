"""Remove stuck Sonarr/Radarr queue items and re-search what was removed.

Invoked by scripts/queue-cleanup.sh; see that file for the why. This was a
heredoc until 2026-09-01. The pure parts -- the stuck classifier, the URL
builder, the search-payload shape -- are lifted out so they can be imported and
tested, and every side effect (HTTP, the clock, the inter-delete sleep) is
injected so a test can never reach a live Sonarr or Radarr.

Two behaviours below exist for one failure mode, found live on 2026-09-12. A
debrid client (TorBox, behind Decypharr) failed to resolve a download link,
gave up, and told nobody: the arr kept the item at 0% "downloading" for a
month, and because a queue item at the cutoff makes Sonarr reject every
candidate with "Release in queue already meets cutoff", it could not replace
one either. 67 items sat in that loop. Removing the item breaks it, and both
details below are about making the replacement actually happen:

  * A stale item from a debrid client is not blocklisted. The release is fine,
    the provider failed. Blocklisting it forces a different release that the
    provider may not have cached, which fails the same way and repeats.
  * Searches are paced, and aimed at the episodes that were removed rather
    than at the whole series. A burst of searches answers 429 from the
    indexer, and Sonarr then disables that indexer for the rest of the run.

A second, unrelated shape was found in the same queues on 2026-09-13: a
completed download the arr had permanently refused -- a sample verdict on two
Sopranos episodes, and a release that did not contain the film it was grabbed
for. The client had nothing left to report, so nothing ever moved the item,
and through the same cutoff rule each one blocked every alternative release for
its title. IMPORT_BLOCKING_MARKERS is what makes those two visible, and they are
handled unlike every other removal: the arr's verdict is about matching, not
about the file (both live cases imported cleanly by hand minutes later), so they
are neither blocklisted nor deleted from the client. The download stays on disk
for a manual import; see KEEP_FILE_REASONS.

The third behaviour is memory. A stale item from a debrid client is deliberately
not blocklisted the first time, because the provider may only have been
transiently broken -- but Decypharr classifies an unrecognised link error as
permanent, so the release comes back and fails identically. Six titles did
exactly that on 2026-09-13: removed at 00:16, re-grabbed, stalled again by 00:45.
A release removed once already is blocklisted the second time round.
"""

import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

PAGE_SIZE = 50

# A queue of 5,000 items is already far past anything this stack produces; the
# bound exists to stop a service that reports a growing totalRecords from
# looping forever, not to ration real work. Hitting it is reported, never
# silent -- a truncation nobody is told about reads as a complete run.
MAX_PAGES = 100

# How long to wait between search commands. Each one costs indexer requests,
# and a burst is not free: on 2026-09-12 a run of back-to-back searches got
# `429 Too Many Requests` from LimeTorrents through Prowlarr, and Sonarr then
# disabled that indexer outright. The rest of that run reported "0 active
# indexers" for every search -- items removed, nothing found to replace them,
# and the indexer down for the following hour.
SEARCH_INTERVAL_SECONDS = 30

# Debrid clients do the torrenting somewhere else and hand this host an HTTPS
# link. A download that never starts through one of them failed at link
# resolution on the provider's side, which is a different thing from a torrent
# with no peers, and it is why the blocklist rule below is conditional. Matched
# against the name the operator gave the client in the arr, which is the only
# signal a queue record carries about who is downloading it.
DEBRID_CLIENT_PATTERNS = ("decypharr", "torbox", "debrid")

# How long a 0%-progress download is given before it is called dead. The two
# numbers differ because the waits behind them differ.
#
# A debrid client resolves a cached release in seconds and tells the arr it is
# done; an uncached one is fetched on the provider's own servers in minutes.
# Three hours of 0% through one of them is not slowness, it is the
# link-resolution failure this script exists for -- and 24 hours was too
# patient to notice it. On 2026-09-12 the stuck items were 9 hours old, none of
# them would have been looked at until the next day, and each one was blocking
# its episode through Sonarr's "Release in queue already meets cutoff".
#
# A swarm client is the opposite case: a torrent with no peers yet can still
# find seeders, so age alone is weak evidence there, and 24 hours stays.
STALE_HOURS_DEBRID = 3
STALE_HOURS_DEFAULT = 24

# Usenet clients are named after their provider here too ("SABnzbd (TorBox
# Usenet)"), so the debrid patterns match them and the exemption below would
# cover a class of failure it was never meant to cover.
USENET_CLIENT_PATTERNS = ("sabnzbd", "nzbget", "nzb")

# Status messages that mean the arr has looked at a completed download and
# refused the file itself. None of these clear on their own: the decision is
# the arr's, the client has nothing left to report, and the item stays in
# importPending indefinitely -- holding its title hostage through the cutoff
# rule the whole time. Seen live on 2026-09-13:
#   * Sonarr, "Unable to determine if file is a sample" (two Sopranos episodes)
#   * Radarr, "Movie [...] was not found in the grabbed release" (X-Men 2000)
# Matched case-insensitively against every status message on the record.
IMPORT_BLOCKING_MARKERS = (
    "unable to determine if file is a sample",
    "was not found in the grabbed release",
)


# Reason types whose files are kept on disk and left alone beyond the queue
# entry itself. An `import_refused` item is a completed download the arr would
# not match -- the bytes are all there and the verdict is about naming or
# sampling, so deleting them throws away a working release and asking for a
# different one. Both live cases on 2026-09-13 imported cleanly by hand.
KEEP_FILE_REASONS = ("import_refused",)

# Where the script remembers what it has already removed once. Without it the
# first-strike exemption above is a livelock: remove the item, the arr's next
# RSS sync re-grabs the identical release because nothing is blocklisted, it
# stalls in the same way, and the hour after that removes it again. Six titles
# were in exactly that loop on 2026-09-13 (removed 00:16, stalled again 00:45).
# Kept beside the log it belongs to, and gitignored -- it is runtime state, not
# configuration. A missing file is the normal first run.
#
# Three dirnames, not two: this file is scripts/lib/queue_cleanup.py, and the
# repo root -- the directory holding logs/ -- is three levels up. Two lands in
# scripts/, which no other part of this stack writes to.
STATE_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "logs", "queue-cleanup-state.json",
)

# How long a remembered removal stays relevant. Short enough that the file
# stays a few hundred entries on a busy stack, long enough that a re-grab a
# fortnight later is genuinely a new attempt rather than a repeat of the old
# one.
STATE_RETENTION_DAYS = 14


def build_url(port, path, key):
    """Append the apikey with the right separator.

    The path already carries a query string for the paginated and the
    parameterised-delete calls, and does not for the rest.

    Only tests and `--dry-run` read this. Every real request goes through
    `ArrApi`, which hands the URL to curl on stdin instead: `curl <url>` puts
    the key in this process's argv, where any user on the box can read it out
    of `/proc/<pid>/cmdline`. It was there in `ps` output on the NAS on
    2026-09-13 for both arrs.
    """
    url = f"http://localhost:{port}{path}"
    if "?" in url:
        return url + f"&apikey={key}"
    return url + f"?apikey={key}"


def _curl_config(url, method="GET", data=None):
    """A curl config file, so the key never reaches argv.

    curl reads `url`, `request`, `header` and `data` from a config file passed
    with `--config -`, and a request built that way carries no key in the
    process list. The escaping is curl's own: a value may be quoted, and a
    backslash or a quote inside one has to be backslashed.
    """
    def quoted(value):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

    lines = [f"url = {quoted(url)}"]
    if method != "GET":
        lines.append(f"request = {quoted(method)}")
    if data is not None:
        lines.append('header = "Content-Type: application/json"')
        lines.append(f"data = {quoted(data)}")
    return "\n".join(lines) + "\n"


class ArrApi:
    """The real side effects, behind a seam."""

    def _run(self, url, method="GET", data=None):
        return subprocess.run(
            ["curl", "-s", "-f", "--config", "-"],
            input=_curl_config(url, method, data),
            capture_output=True, text=True, timeout=30
        )

    def get(self, port, path, key):
        result = self._run(build_url(port, path, key))
        if result.returncode != 0:
            return None
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            # A 200 carrying something that is not JSON -- an HTML error page
            # from whatever sits in front of the arr, or an empty body. The
            # caller already reads None as "could not fetch the queue" and says
            # so; raising here instead would abort the run with a traceback and
            # take the other service's cleanup with it.
            return None

    def delete(self, port, path, key):
        return self._run(build_url(port, path, key), method="DELETE").returncode == 0

    def post_json(self, port, path, key, data):
        url = f"http://localhost:{port}{path}?apikey={key}"
        return self._run(url, method="POST", data=json.dumps(data)).returncode == 0


def services(sonarr_key, radarr_key):
    out = []
    if sonarr_key:
        out.append({
            "name": "Sonarr",
            "port": 8989,
            "key": sonarr_key,
            "id_field": "seriesId",
            "search_cmd": "SeriesSearch",
            "search_key": "seriesId",
        })
    if radarr_key:
        out.append({
            "name": "Radarr",
            "port": 7878,
            "key": radarr_key,
            "id_field": "movieId",
            "search_cmd": "MoviesSearch",
            "search_key": "movieIds",
        })
    return out


def search_payload(svc, target_id):
    """Radarr's MoviesSearch takes a list; Sonarr's SeriesSearch takes a scalar.

    An asymmetry in the two APIs, not a mistake here -- posting a scalar to
    Radarr or a list to Sonarr is rejected.
    """
    if svc["search_key"] == "movieIds":
        return {"name": svc["search_cmd"], svc["search_key"]: [target_id]}
    return {"name": svc["search_cmd"], svc["search_key"]: target_id}


def target_search(svc, target_id, removed_episodes):
    """The search command for one removal target, and the label to log it by.

    For Sonarr, searching the series would re-search every missing episode of
    it -- dozens of indexer requests to replace one stuck episode, and the
    indexer answers 429 long before that finishes. When the queue record named
    its episodes, search exactly those. Radarr's MoviesSearch is already
    per-film, and a Sonarr record carrying no episode ids (which the API does
    not normally produce) falls back to the series search.
    """
    episodes = sorted(removed_episodes)
    if episodes and svc["search_key"] == "seriesId":
        return ({"name": "EpisodeSearch", "episodeIds": episodes},
                f"episodeIds={','.join(str(episode) for episode in episodes)}")
    return search_payload(svc, target_id), f"{svc['id_field']}={target_id}"


def is_debrid_client(record):
    """Whether the arr handed this download to a debrid provider.

    Matched against the client name the operator configured, because that name
    is the only thing a queue record says about where the bytes come from.

    Usenet clients are excluded first, and that is not a technicality: this
    stack's usenet client is named "SABnzbd (TorBox Usenet)", so the provider
    pattern matches it and the exemption below would swallow every dead NZB
    too. A usenet download that never completes is a release with missing
    articles -- the release is the problem, and it belongs on the blocklist.
    """
    client = (record.get("downloadClient") or "").lower()
    if any(pattern in client for pattern in USENET_CLIENT_PATTERNS):
        return False
    return any(pattern in client for pattern in DEBRID_CLIENT_PATTERNS)


def should_blocklist(record, reason_type, removed_before=False):
    """Whether the release behind a stuck item should be blacklisted.

    A dead torrent on a swarm client: yes. The same release is still dead the
    next time, which is what the blocklist is for. A stale item that never
    started through a debrid client: no, the first time. There the release is
    fine and the provider failed, so the replacement search has to be free to
    pick that same release again -- blocklisting it forces a different one,
    which the provider may not have cached, which fails the same way.

    The first time. `removed_before` is what makes that a first strike rather
    than a permanent exemption, and it is the fix for a livelock: with the
    release never blocklisted, the arr's next RSS sync re-grabbed the identical
    release ~40 minutes after it was removed, it stalled again in the same way,
    and the next hourly run removed it again. Six titles were doing that on
    2026-09-13. A release this script has already removed once gets blocklisted
    on the second removal, which is the same thing the swarm case does
    immediately, just one round later.

    `import_refused` is exempt regardless. The arr's verdict there is about
    matching -- a sample call, a release that did not contain the film -- not
    about the release being bad, and both live cases imported cleanly by hand.
    Blocklisting those would blacklist a working release over a naming quirk.
    """
    if reason_type in KEEP_FILE_REASONS:
        return False
    if reason_type == "stale" and is_debrid_client(record):
        return removed_before
    return True


def should_remove_from_client(record, reason_type):
    """Whether the download itself should be deleted along with the queue item.

    Almost always yes: the item is stuck because the download is bad, and
    leaving a dead 15 GB torrent on disk is how the disk fills with things
    nothing is managing.

    `import_refused` is the exception, and it is why this is a separate
    question from the blocklist. The bytes are complete and correct -- the arr
    refused to *match* them -- so deleting the download throws away a release
    that imports fine once someone tells it what it is. Both live cases were
    imported by hand minutes after this script had deleted them. The queue
    entry still has to go (it is what blocks every alternative through the
    cutoff rule), and it goes with `removeFromClient=false`.
    """
    return reason_type not in KEEP_FILE_REASONS


def removal_key(svc, record):
    """Identify a download across re-grabs, for the second-strike rule.

    Not the queue id: that is new every time the arr re-grabs the release, so
    an id-keyed memory would never see a second attempt. Not the title alone
    either, because the same episode name appears in every release of it. What
    a re-grab keeps is the release name and what it is for, so the key is the
    service, the series or film id, and the release title.
    """
    return "|".join((
        svc["name"],
        str(record.get(svc["id_field"])),
        record.get("title") or "unknown",
    ))


def load_state(path=STATE_PATH):
    """Read the removal memory. A missing or unreadable file is an empty one.

    It must never be fatal: the file is a guard against a slow livelock, and
    losing it means one extra removal round, while raising here means the
    cleanup does not run at all.
    """
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {key: value for key, value in data.items() if isinstance(value, dict)}


def save_state(state, path=STATE_PATH, out=print):
    """Write the removal memory, atomically, and never fatally.

    Written through a temporary file in the same directory and renamed, so a
    run killed partway leaves the previous file intact rather than a truncated
    one. Failure is reported and swallowed for the same reason loading is.
    """
    try:
        directory = os.path.dirname(path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        tmp_path = f"{path}.{os.getpid()}.tmp"
        with open(tmp_path, "w", encoding="utf-8") as handle:
            json.dump(state, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp_path, path)
    except OSError as exc:
        out(f"  ! Could not write the removal memory at {path}: {exc}")
        out("    The next run will re-treat every release as a first removal.")


def remember_removal(state, svc, record, now):
    """Record that this release was removed, and how many times.

    `last` is refreshed on every removal; `first` is kept so that pruning and
    any future rule can tell when the loop started.

    The count is read defensively. This file outlives the code that wrote it --
    it sits on the NAS between releases, and anyone debugging the loop is
    likely to open it by hand. A `count` that is not a number is treated as
    zero rather than allowed to raise, because raising here aborts the run
    after items have already been deleted from the client.
    """
    key = removal_key(svc, record)
    stamp = now.isoformat()
    entry = state.get(key) or {}
    try:
        count = int(entry.get("count", 0))
    except (TypeError, ValueError):
        count = 0
    state[key] = {
        "count": count + 1,
        "first": entry.get("first") or stamp,
        "last": stamp,
        "title": record.get("title") or "unknown",
    }


def prune_state(state, now, retention_days=STATE_RETENTION_DAYS):
    """Drop entries nothing has touched for `retention_days`.

    An unparseable `last` is treated as expired: the alternative is an entry
    that can never age out, and the cost of dropping it is one unblocked
    removal.
    """
    kept = {}
    for key, entry in state.items():
        try:
            last = datetime.fromisoformat(str(entry.get("last", "")))
            fresh = (now - last).days < retention_days
        except ValueError:
            fresh = False
        if fresh:
            kept[key] = entry
    return kept


def episode_ids(record):
    """Every episode id on a queue record, deduped and sorted.

    Sonarr puts one id in `episodeId` and the full list in `episodes`; a
    season pack carries many, and the same id can sit in both. Sorted so the
    search payload it generates is stable between runs.
    """
    ids = set()
    single = record.get("episodeId")
    if isinstance(single, int):
        ids.add(single)
    for episode in record.get("episodes") or []:
        if isinstance(episode, dict) and isinstance(episode.get("id"), int):
            ids.add(episode["id"])
    return tuple(sorted(ids))


def _age_hours(added_str, now):
    """Hours since `added`, or None if it is missing or unparseable."""
    if not added_str:
        return None
    try:
        added = datetime.fromisoformat(added_str.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None
    try:
        return (now - added).total_seconds() / 3600
    except TypeError:
        # A naive timestamp cannot be subtracted from an aware one. The heredoc
        # let this raise out of the try above only by accident of ordering.
        return None


def is_stuck(record, now=None):
    """Determine if a queue record is stuck and should be removed."""
    if now is None:
        now = datetime.now(timezone.utc)

    tracked_status = record.get("trackedDownloadStatus", "")
    tracked_state = record.get("trackedDownloadState", "")
    error_msg = (record.get("errorMessage", "") or "").lower()
    size = record.get("size", 0)
    sizeleft = record.get("sizeleft", 0)

    # Error-based: stalled, unavailable, missing, etc.
    if tracked_status == "warning":
        error_keywords = ["stall", "not available", "no files found",
                          "import failed", "missing"]
        if any(kw in error_msg for kw in error_keywords):
            return "error", error_msg.strip()

    # Stuck imports (completed download but can't import)
    if tracked_state == "importing" and tracked_status == "warning":
        return "import_stuck", "completed but stuck importing"

    # Import blocked (already imported, not an upgrade, etc.)
    if tracked_state == "importBlocked":
        msgs = _status_messages(record)
        reason = "; ".join(msgs[:2]) if msgs else "import blocked"
        return "import_blocked", reason

    # Import pending with warnings (e.g. executable files, not an upgrade)
    if tracked_state == "importPending" and tracked_status == "warning":
        msgs = _status_messages(record)
        all_msgs = " ".join(msgs).lower()
        if "executable" in all_msgs or "not an upgrade" in all_msgs:
            reason = "; ".join(msgs[:2]) if msgs else "import pending with warnings"
            return "import_warning", reason

    # Import pending because the arr has permanently refused the file itself.
    #
    # Both of these were sat in the queue on 2026-09-13 and neither could ever
    # clear on its own, because the verdict is the arr's, not the client's:
    # a completed download sits in importPending and the client has nothing
    # left to report. Through the cutoff rule each one also blocked every
    # alternative release for its title -- Radarr rejected 50 of 52 candidates
    # for X-Men while a 15 GB copy of the film sat on disk unimported.
    #
    # Deliberately not gated on trackedDownloadStatus: the sample verdict
    # arrives with status "completed", and requiring "warning" is what left
    # these two invisible to this classifier while it removed everything
    # around them.
    if tracked_state == "importPending":
        msgs = _status_messages(record)
        joined = " ".join(msgs).lower()
        for marker in IMPORT_BLOCKING_MARKERS:
            if marker in joined:
                return "import_refused", f"cannot import: {marker}"

    # Stuck downloading metadata (no peers at all)
    if "downloading metadata" in error_msg:
        return "metadata", "stuck downloading metadata"

    # Age-based. The leash is shorter for a debrid client: it either resolves a
    # link in seconds or it never will, so 0% for three hours is a failure
    # rather than slowness. A swarm client keeps the 24-hour rule, where a
    # torrent that has found no peers yet may still find some.
    stale_hours = (STALE_HOURS_DEBRID if is_debrid_client(record)
                   else STALE_HOURS_DEFAULT)
    if size > 0 and sizeleft == size:
        age_hours = _age_hours(record.get("added", ""), now)
        if age_hours is not None and age_hours > stale_hours:
            return "stale", f"0% progress for {age_hours:.0f}h"
    elif size == 0:
        # No size info at all — likely metadata-only, check age
        age_hours = _age_hours(record.get("added", ""), now)
        if age_hours is not None and age_hours > stale_hours:
            return "stale", f"no size info for {age_hours:.0f}h"

    return None, None


def _status_messages(record):
    msgs = []
    for sm in record.get("statusMessages", []):
        msgs.extend(sm.get("messages", []))
    return msgs


def fetch_queue(api, svc, out=print, max_pages=MAX_PAGES):
    """Page through the queue, and stop even when the service says not to.

    The heredoc version looped on `page * 50 >= totalRecords` alone. A service
    reporting a totalRecords that grows at least as fast as the pages are
    consumed -- or one that keeps answering with an empty `records` list --
    never satisfied that condition, and the script hung with no output and no
    timeout, inside a systemd unit.
    """
    all_records = []
    page = 1
    while True:
        data = api.get(svc["port"],
                       f"/api/v3/queue?page={page}&pageSize={PAGE_SIZE}",
                       svc["key"])
        if data is None:
            out(f"  ✗ Failed to fetch queue")
            break
        records = data.get("records", [])
        if not records:
            # Nothing on this page: whatever totalRecords claims, there is no
            # further work to collect and another request would repeat this one.
            break
        all_records.extend(records)
        total_records = data.get("totalRecords", 0)
        if page * PAGE_SIZE >= total_records:
            break
        if page >= max_pages:
            out(f"  ! Stopped after {max_pages} pages ({len(all_records)} items);"
                f" {svc['name']} reported {total_records} total."
                f" The rest of the queue was not examined.")
            break
        page += 1
    return all_records


def process_service(svc, api, apply_changes, verbose, out=print,
                    now=None, sleep=time.sleep, max_pages=MAX_PAGES,
                    state=None):
    if now is None:
        now = datetime.now(timezone.utc)
    if state is None:
        state = {}

    out(f"\n--- {svc['name']} (port {svc['port']}) ---")

    all_records = fetch_queue(api, svc, out=out, max_pages=max_pages)
    out(f"  Queue size: {len(all_records)} items")

    stuck_items = []
    for record in all_records:
        reason_type, reason_msg = is_stuck(record, now)
        if reason_type:
            stuck_items.append((record, reason_type, reason_msg))

    if not stuck_items:
        out(f"  - No stuck items found")
        return 0, 0

    out(f"  Found {len(stuck_items)} stuck item(s):")

    search_targets = {}
    removed_count = 0

    for record, reason_type, reason_msg in stuck_items:
        title = record.get("title", "unknown")[:70]
        qid = record.get("id")
        target_id = record.get(svc["id_field"])
        episodes = episode_ids(record)
        keep_file = not should_remove_from_client(record, reason_type)
        # A release this script removed on an earlier run gets the blocklist the
        # first removal withheld. Read, never written, on a dry run: the memory
        # has to describe what was actually removed.
        removed_before = removal_key(svc, record) in state

        if apply_changes:
            blocklist = should_blocklist(record, reason_type, removed_before)
            success = api.delete(
                svc["port"],
                f"/api/v3/queue/{qid}?removeFromClient={str(not keep_file).lower()}"
                f"&blocklist={str(blocklist).lower()}",
                svc["key"]
            )
            if success:
                out(f"  ✓ Removed: {title}")
                out(f"    Reason: {reason_msg}")
                if keep_file:
                    out("    Kept on disk (removeFromClient=false): the download itself"
                        " is fine, the arr just would not match it -- import it by hand,"
                        " it is in the client's completed folder")
                elif not blocklist:
                    out(f"    Not blocklisted: {record.get('downloadClient', 'the client')}"
                        f" does the downloading, so the release is still usable")
                    if reason_type == "stale":
                        out("    First removal of this release; a second one gets blocklisted")
                elif removed_before:
                    out("    Blocklisted: this release was already removed once and came back")
                remember_removal(state, svc, record, now)
                removed_count += 1
                # No replacement search for a kept download: the release is still
                # there, and the arr would only grab a second copy of something
                # already sitting on disk.
                if target_id and not keep_file:
                    search_targets.setdefault(target_id, set()).update(episodes)
                sleep(0.5)
            else:
                out(f"  ✗ Failed to remove: {title}")
        else:
            out(f"  [dry-run] Would remove: {title}")
            out(f"    Reason: {reason_msg}")
            if keep_file:
                out("    Would keep the download on disk (removeFromClient=false)")
            elif reason_type == "stale" and is_debrid_client(record) and not removed_before:
                out("    Would not blocklist: first removal of this release")
            removed_count += 1
            if target_id and not keep_file:
                search_targets.setdefault(target_id, set()).update(episodes)

        if verbose:
            pct = 0
            if record.get("size", 0) > 0:
                pct = round((1 - record.get("sizeleft", 0) / record["size"]) * 100, 1)
            out(f"    [verbose] Status: {record.get('status')} | "
                f"Tracked: {record.get('trackedDownloadStatus')} | "
                f"State: {record.get('trackedDownloadState')} | "
                f"Progress: {pct}% | Type: {reason_type}")

    if search_targets:
        action = "Triggering" if apply_changes else "Would trigger"
        out(f"\n  {action} searches for {len(search_targets)} {svc['name'].lower()} item(s):")
        targets = sorted(search_targets)
        for position, target_id in enumerate(targets):
            payload, label = target_search(svc, target_id, search_targets[target_id])
            if apply_changes:
                success = api.post_json(svc["port"], "/api/v3/command", svc["key"], payload)
                status = "queued" if success else "FAILED"
                out(f"    ✓ Search {label}: {status}")
                # Nothing to wait for after the last one, and in a dry run
                # there is no request to space out.
                if position < len(targets) - 1:
                    sleep(SEARCH_INTERVAL_SECONDS)
            else:
                out(f"    [dry-run] Search {label}")

    return removed_count, len(search_targets)


def run(svcs, api, apply_changes, verbose, out=print, now=None, sleep=time.sleep,
        max_pages=MAX_PAGES, state_path=None):
    if now is None:
        now = datetime.now(timezone.utc)
    if state_path is None:
        state_path = STATE_PATH
    state = prune_state(load_state(state_path), now)

    total_removed = 0
    total_searches = 0
    for svc in svcs:
        removed, searches = process_service(svc, api, apply_changes, verbose,
                                            out=out, now=now, sleep=sleep,
                                            max_pages=max_pages, state=state)
        total_removed += removed
        total_searches += searches

    # Only a run that removed something has anything new to remember, and only
    # an applying run is allowed to write: a dry run that wrote would record
    # removals that never happened, and the release would be blocklisted on a
    # removal it survived. Pruning still happens in memory either way.
    if apply_changes and total_removed > 0:
        save_state(state, path=state_path, out=out)

    out(f"\n{'=' * 40}")
    mode = "APPLIED" if apply_changes else "DRY RUN"
    out(f"Summary ({mode}): {total_removed} items removed, {total_searches} searches triggered")
    if not apply_changes and total_removed > 0:
        out("Run with --apply to actually remove stuck items")
    return total_removed, total_searches


def main(argv):
    apply_changes = argv[1] == "true"
    verbose = argv[2] == "true"
    # Read from the environment rather than argv, so the keys are not in `ps`.
    # The shell half still has to pass them somehow; an env assignment in its
    # invocation puts them in that shell's environment, not in this argv.
    sonarr_key = os.environ.get("SONARR_API_KEY", "")
    radarr_key = os.environ.get("RADARR_API_KEY", "")
    run(services(sonarr_key, radarr_key), ArrApi(), apply_changes, verbose)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
