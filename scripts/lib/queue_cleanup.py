import json, sys, subprocess, time
from datetime import datetime, timezone

APPLY = sys.argv[1] == "true"
VERBOSE = sys.argv[2] == "true"
SONARR_KEY = sys.argv[3]
RADARR_KEY = sys.argv[4]

SERVICES = []
if SONARR_KEY:
    SERVICES.append({
        "name": "Sonarr",
        "port": 8989,
        "key": SONARR_KEY,
        "id_field": "seriesId",
        "search_cmd": "SeriesSearch",
        "search_key": "seriesId",
    })
if RADARR_KEY:
    SERVICES.append({
        "name": "Radarr",
        "port": 7878,
        "key": RADARR_KEY,
        "id_field": "movieId",
        "search_cmd": "MoviesSearch",
        "search_key": "movieIds",
    })

total_removed = 0
total_searches = 0

def api_get(port, path, key):
    url = f"http://localhost:{port}{path}"
    if "?" in url:
        url += f"&apikey={key}"
    else:
        url += f"?apikey={key}"
    result = subprocess.run(
        ["curl", "-s", "-f", url],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)

def api_delete(port, path, key):
    url = f"http://localhost:{port}{path}"
    if "?" in url:
        url += f"&apikey={key}"
    else:
        url += f"?apikey={key}"
    result = subprocess.run(
        ["curl", "-s", "-f", "-X", "DELETE", url],
        capture_output=True, text=True, timeout=30
    )
    return result.returncode == 0

def api_post_json(port, path, key, data):
    url = f"http://localhost:{port}{path}?apikey={key}"
    result = subprocess.run(
        ["curl", "-s", "-f", "-X", "POST",
         "-H", "Content-Type: application/json",
         "-d", json.dumps(data), url],
        capture_output=True, text=True, timeout=30
    )
    return result.returncode == 0

def is_stuck(record):
    """Determine if a queue record is stuck and should be removed."""
    status = record.get("status", "")
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
        msgs = []
        for sm in record.get("statusMessages", []):
            msgs.extend(sm.get("messages", []))
        reason = "; ".join(msgs[:2]) if msgs else "import blocked"
        return "import_blocked", reason

    # Import pending with warnings (e.g. executable files, not an upgrade)
    if tracked_state == "importPending" and tracked_status == "warning":
        msgs = []
        for sm in record.get("statusMessages", []):
            msgs.extend(sm.get("messages", []))
        all_msgs = " ".join(msgs).lower()
        if "executable" in all_msgs or "not an upgrade" in all_msgs:
            reason = "; ".join(msgs[:2]) if msgs else "import pending with warnings"
            return "import_warning", reason

    # Stuck downloading metadata (no peers at all)
    if "downloading metadata" in error_msg:
        return "metadata", "stuck downloading metadata"

    # Age-based: 0% progress for 24+ hours
    if size > 0 and sizeleft == size:
        added_str = record.get("added", "")
        if added_str:
            try:
                added = datetime.fromisoformat(added_str.replace("Z", "+00:00"))
                age_hours = (datetime.now(timezone.utc) - added).total_seconds() / 3600
                if age_hours > 24:
                    return "stale", f"0% progress for {age_hours:.0f}h"
            except (ValueError, TypeError):
                pass
    elif size == 0:
        # No size info at all — likely metadata-only, check age
        added_str = record.get("added", "")
        if added_str:
            try:
                added = datetime.fromisoformat(added_str.replace("Z", "+00:00"))
                age_hours = (datetime.now(timezone.utc) - added).total_seconds() / 3600
                if age_hours > 24:
                    return "stale", f"no size info for {age_hours:.0f}h"
            except (ValueError, TypeError):
                pass

    return None, None

for svc in SERVICES:
    print(f"\n--- {svc['name']} (port {svc['port']}) ---")

    # Paginate through queue
    all_records = []
    page = 1
    while True:
        data = api_get(svc["port"], f"/api/v3/queue?page={page}&pageSize=50", svc["key"])
        if data is None:
            print(f"  ✗ Failed to fetch queue")
            break
        records = data.get("records", [])
        all_records.extend(records)
        total_records = data.get("totalRecords", 0)
        if page * 50 >= total_records:
            break
        page += 1

    print(f"  Queue size: {len(all_records)} items")

    stuck_items = []
    for record in all_records:
        reason_type, reason_msg = is_stuck(record)
        if reason_type:
            stuck_items.append((record, reason_type, reason_msg))

    if not stuck_items:
        print(f"  - No stuck items found")
        continue

    print(f"  Found {len(stuck_items)} stuck item(s):")

    removed_ids = set()   # queue IDs successfully removed
    search_targets = set()  # unique series/movie IDs to re-search
    removed_count = 0

    for record, reason_type, reason_msg in stuck_items:
        title = record.get("title", "unknown")[:70]
        qid = record.get("id")
        target_id = record.get(svc["id_field"])

        if APPLY:
            success = api_delete(
                svc["port"],
                f"/api/v3/queue/{qid}?removeFromClient=true&blocklist=true",
                svc["key"]
            )
            if success:
                print(f"  ✓ Removed: {title}")
                print(f"    Reason: {reason_msg}")
                removed_ids.add(qid)
                removed_count += 1
                if target_id:
                    search_targets.add(target_id)
                time.sleep(0.5)
            else:
                print(f"  ✗ Failed to remove: {title}")
        else:
            print(f"  [dry-run] Would remove: {title}")
            print(f"    Reason: {reason_msg}")
            removed_count += 1
            if target_id:
                search_targets.add(target_id)

        if VERBOSE:
            pct = 0
            if record.get("size", 0) > 0:
                pct = round((1 - record.get("sizeleft", 0) / record["size"]) * 100, 1)
            print(f"    [verbose] Status: {record.get('status')} | "
                  f"Tracked: {record.get('trackedDownloadStatus')} | "
                  f"State: {record.get('trackedDownloadState')} | "
                  f"Progress: {pct}% | Type: {reason_type}")

    # Trigger re-searches
    if search_targets:
        action = "Triggering" if APPLY else "Would trigger"
        print(f"\n  {action} searches for {len(search_targets)} {svc['name'].lower()} item(s):")
        for target_id in sorted(search_targets):
            if svc["search_key"] == "movieIds":
                payload = {"name": svc["search_cmd"], svc["search_key"]: [target_id]}
            else:
                payload = {"name": svc["search_cmd"], svc["search_key"]: target_id}

            if APPLY:
                success = api_post_json(svc["port"], "/api/v3/command", svc["key"], payload)
                status = "queued" if success else "FAILED"
                print(f"    ✓ Search {svc['id_field']}={target_id}: {status}")
            else:
                print(f"    [dry-run] Search {svc['id_field']}={target_id}")

    total_removed += removed_count
    total_searches += len(search_targets)

# --- Summary ---
print(f"\n{'=' * 40}")
mode = "APPLIED" if APPLY else "DRY RUN"
print(f"Summary ({mode}): {total_removed} items removed, {total_searches} searches triggered")
if not APPLY and total_removed > 0:
    print("Run with --apply to actually remove stuck items")
