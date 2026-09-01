"""Remove stuck Sonarr/Radarr queue items and re-search what was removed.

Invoked by scripts/queue-cleanup.sh; see that file for the why. This was a
heredoc until 2026-09-01. The pure parts -- the stuck classifier, the URL
builder, the search-payload shape -- are lifted out so they can be imported and
tested, and every side effect (HTTP, the clock, the inter-delete sleep) is
injected so a test can never reach a live Sonarr or Radarr.
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
        return json.loads(result.stdout)

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

    search_targets = set()
    removed_count = 0

    for record, reason_type, reason_msg in stuck_items:
        title = record.get("title", "unknown")[:70]
        qid = record.get("id")
        target_id = record.get(svc["id_field"])

        if apply_changes:
            success = api.delete(
                svc["port"],
                f"/api/v3/queue/{qid}?removeFromClient=true&blocklist=true",
                svc["key"]
            )
            if success:
                out(f"  ✓ Removed: {title}")
                out(f"    Reason: {reason_msg}")
                removed_count += 1
                if target_id:
                    search_targets.add(target_id)
                sleep(0.5)
            else:
                out(f"  ✗ Failed to remove: {title}")
        else:
            out(f"  [dry-run] Would remove: {title}")
            out(f"    Reason: {reason_msg}")
            removed_count += 1
            if target_id:
                search_targets.add(target_id)

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
        for target_id in sorted(search_targets):
            payload = search_payload(svc, target_id)
            if apply_changes:
                success = api.post_json(svc["port"], "/api/v3/command", svc["key"], payload)
                status = "queued" if success else "FAILED"
                out(f"    ✓ Search {svc['id_field']}={target_id}: {status}")
            else:
                out(f"    [dry-run] Search {svc['id_field']}={target_id}")

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
