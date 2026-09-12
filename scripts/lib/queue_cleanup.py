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
"""

import json
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

# Usenet clients are named after their provider here too ("SABnzbd (TorBox
# Usenet)"), so the debrid patterns match them and the exemption below would
# cover a class of failure it was never meant to cover.
USENET_CLIENT_PATTERNS = ("sabnzbd", "nzbget", "nzb")


def build_url(port, path, key):
    """Append the apikey with the right separator.

    The path already carries a query string for the paginated and the
    parameterised-delete calls, and does not for the rest.
    """
    url = f"http://localhost:{port}{path}"
    if "?" in url:
        return url + f"&apikey={key}"
    return url + f"?apikey={key}"


class ArrApi:
    """The real side effects, behind a seam."""

    def get(self, port, path, key):
        result = subprocess.run(
            ["curl", "-s", "-f", build_url(port, path, key)],
            capture_output=True, text=True, timeout=30
        )
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
        result = subprocess.run(
            ["curl", "-s", "-f", "-X", "DELETE", build_url(port, path, key)],
            capture_output=True, text=True, timeout=30
        )
        return result.returncode == 0

    def post_json(self, port, path, key, data):
        url = f"http://localhost:{port}{path}?apikey={key}"
        result = subprocess.run(
            ["curl", "-s", "-f", "-X", "POST",
             "-H", "Content-Type: application/json",
             "-d", json.dumps(data), url],
            capture_output=True, text=True, timeout=30
        )
        return result.returncode == 0


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


def should_blocklist(record, reason_type):
    """Whether the release behind a stuck item should be blacklisted.

    A dead torrent on a swarm client: yes. The same release is still dead the
    next time, which is what the blocklist is for. A stale item that never
    started through a debrid client: no. There the release is fine and the
    provider failed, so the replacement search has to be free to pick that
    same release again -- blocklisting it forces a different one, which the
    provider may not have cached, which fails the same way.

    Only `stale` is exempted. A blocked or failing import is about the files,
    not about who downloaded them, and is blocklisted as before.
    """
    if reason_type == "stale" and is_debrid_client(record):
        return False
    return True


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

    # Stuck downloading metadata (no peers at all)
    if "downloading metadata" in error_msg:
        return "metadata", "stuck downloading metadata"

    # Age-based: 0% progress for 24+ hours
    if size > 0 and sizeleft == size:
        age_hours = _age_hours(record.get("added", ""), now)
        if age_hours is not None and age_hours > 24:
            return "stale", f"0% progress for {age_hours:.0f}h"
    elif size == 0:
        # No size info at all — likely metadata-only, check age
        age_hours = _age_hours(record.get("added", ""), now)
        if age_hours is not None and age_hours > 24:
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
                    now=None, sleep=time.sleep, max_pages=MAX_PAGES):
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

        if apply_changes:
            blocklist = should_blocklist(record, reason_type)
            success = api.delete(
                svc["port"],
                f"/api/v3/queue/{qid}?removeFromClient=true&blocklist={str(blocklist).lower()}",
                svc["key"]
            )
            if success:
                out(f"  ✓ Removed: {title}")
                out(f"    Reason: {reason_msg}")
                if not blocklist:
                    out(f"    Not blocklisted: {record.get('downloadClient', 'the client')}"
                        f" does the downloading, so the release is still usable")
                removed_count += 1
                if target_id:
                    search_targets.setdefault(target_id, set()).update(episodes)
                sleep(0.5)
            else:
                out(f"  ✗ Failed to remove: {title}")
        else:
            out(f"  [dry-run] Would remove: {title}")
            out(f"    Reason: {reason_msg}")
            removed_count += 1
            if target_id:
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
        max_pages=MAX_PAGES):
    total_removed = 0
    total_searches = 0
    for svc in svcs:
        removed, searches = process_service(svc, api, apply_changes, verbose,
                                            out=out, now=now, sleep=sleep,
                                            max_pages=max_pages)
        total_removed += removed
        total_searches += searches

    out(f"\n{'=' * 40}")
    mode = "APPLIED" if apply_changes else "DRY RUN"
    out(f"Summary ({mode}): {total_removed} items removed, {total_searches} searches triggered")
    if not apply_changes and total_removed > 0:
        out("Run with --apply to actually remove stuck items")
    return total_removed, total_searches


def main(argv):
    apply_changes = argv[1] == "true"
    verbose = argv[2] == "true"
    sonarr_key = argv[3]
    radarr_key = argv[4]
    run(services(sonarr_key, radarr_key), ArrApi(), apply_changes, verbose)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
