"""Behavioural tests for scripts/lib/queue_cleanup.py.

is_stuck() decides whether a download is deleted from the client and
blocklisted. It had seven classification branches and 24-hour date arithmetic,
and no test of any kind, because it lived in a heredoc.

Every test here injects the clock. A test whose result depends on when it runs
is a test that will one day fail for a reason nobody can reproduce.
"""

import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone

import queue_cleanup as m

NOW = datetime(2026, 9, 1, 12, 0, 0, tzinfo=timezone.utc)


def rec(**kw):
    r = {"id": 1, "title": "Item", "size": 100, "sizeleft": 0,
         "trackedDownloadStatus": "ok", "trackedDownloadState": "downloading",
         "errorMessage": None}
    r.update(kw)
    return r


def ago(hours):
    return (NOW - timedelta(hours=hours)).isoformat().replace("+00:00", "Z")


# --- build_url: the separator branch --------------------------------------

def test_a_path_without_a_query_gets_a_question_mark():
    assert m.build_url(8989, "/api/v3/command", "K") == \
        "http://localhost:8989/api/v3/command?apikey=K"


def test_a_path_that_already_has_a_query_gets_an_ampersand():
    # Getting this backwards produces a URL with two '?' -- the arr APIs answer
    # 404, which api_get reports as "Failed to fetch queue" rather than as the
    # malformed URL it is.
    assert m.build_url(8989, "/api/v3/queue?page=2", "K") == \
        "http://localhost:8989/api/v3/queue?page=2&apikey=K"


# --- search_payload: the list-vs-scalar asymmetry -------------------------

def test_radarr_search_takes_a_list_of_ids():
    svc = m.services("", "RK")[0]
    assert m.search_payload(svc, 42) == {"name": "MoviesSearch", "movieIds": [42]}


def test_sonarr_search_takes_a_bare_id():
    svc = m.services("SK", "")[0]
    assert m.search_payload(svc, 42) == {"name": "SeriesSearch", "seriesId": 42}


def test_services_are_omitted_when_their_key_is_empty():
    assert m.services("", "") == []
    assert [s["name"] for s in m.services("SK", "")] == ["Sonarr"]
    assert [s["name"] for s in m.services("", "RK")] == ["Radarr"]
    assert [s["name"] for s in m.services("SK", "RK")] == ["Sonarr", "Radarr"]


# --- is_stuck: every branch ----------------------------------------------

def test_a_healthy_download_is_not_stuck():
    assert m.is_stuck(rec(added=ago(1)), NOW) == (None, None)


def test_a_stalled_warning_is_classified_as_an_error():
    kind, why = m.is_stuck(rec(trackedDownloadStatus="warning",
                               errorMessage="The download is STALLED"), NOW)
    assert kind == "error"
    assert why == "the download is stalled"


def test_each_error_keyword_is_recognised():
    for msg in ("stalled", "not available", "no files found",
                "import failed", "missing files"):
        kind, _ = m.is_stuck(rec(trackedDownloadStatus="warning",
                                 errorMessage=msg), NOW)
        assert kind == "error", msg


def test_an_error_message_without_a_keyword_is_not_an_error_removal():
    kind, _ = m.is_stuck(rec(trackedDownloadStatus="warning",
                             errorMessage="waiting for a seed"), NOW)
    assert kind is None


def test_error_classification_requires_the_warning_status():
    # Without this the classifier would delete healthy downloads whose message
    # merely mentions a keyword.
    kind, _ = m.is_stuck(rec(trackedDownloadStatus="ok",
                             errorMessage="download is stalled"), NOW)
    assert kind is None


def test_a_null_error_message_does_not_crash():
    assert m.is_stuck(rec(errorMessage=None), NOW) == (None, None)


def test_an_importing_warning_is_a_stuck_import():
    kind, why = m.is_stuck(rec(trackedDownloadState="importing",
                               trackedDownloadStatus="warning"), NOW)
    assert (kind, why) == ("import_stuck", "completed but stuck importing")


def test_import_blocked_reports_its_first_two_status_messages():
    kind, why = m.is_stuck(rec(trackedDownloadState="importBlocked",
                               statusMessages=[{"messages": ["one", "two", "three"]}]), NOW)
    assert kind == "import_blocked"
    assert why == "one; two"


def test_import_blocked_falls_back_when_there_are_no_messages():
    kind, why = m.is_stuck(rec(trackedDownloadState="importBlocked"), NOW)
    assert (kind, why) == ("import_blocked", "import blocked")


def test_import_blocked_does_not_require_a_warning_status():
    kind, _ = m.is_stuck(rec(trackedDownloadState="importBlocked",
                             trackedDownloadStatus="ok"), NOW)
    assert kind == "import_blocked"


def test_import_pending_is_only_removed_for_the_two_named_reasons():
    for msg, expected in (("contains an executable file", "import_warning"),
                          ("is not an upgrade for existing episode", "import_warning"),
                          ("waiting to import", None)):
        kind, _ = m.is_stuck(rec(trackedDownloadState="importPending",
                                 trackedDownloadStatus="warning",
                                 statusMessages=[{"messages": [msg]}]), NOW)
        assert kind == expected, msg


def test_import_pending_without_a_warning_is_left_alone():
    kind, _ = m.is_stuck(rec(trackedDownloadState="importPending",
                             trackedDownloadStatus="ok",
                             statusMessages=[{"messages": ["executable"]}]), NOW)
    assert kind is None


def test_a_still_downloading_item_is_not_judged_by_the_import_pending_rule():
    # The state and the status are two separate conditions and the test above
    # only removes one of them. This removes the other: a healthy download that
    # happens to carry a warning and an "not an upgrade" message is not
    # pending import, and deleting it would blocklist a release still in
    # flight.
    kind, _ = m.is_stuck(rec(trackedDownloadState="downloading",
                             trackedDownloadStatus="warning",
                             size=100, sizeleft=50,
                             statusMessages=[{"messages":
                                              ["Not an upgrade for existing file"]}]), NOW)
    assert kind is None


def test_downloading_metadata_is_matched_case_insensitively():
    kind, why = m.is_stuck(rec(errorMessage="Downloading Metadata"), NOW)
    assert (kind, why) == ("metadata", "stuck downloading metadata")


def test_zero_progress_becomes_stale_only_after_twenty_four_hours():
    assert m.is_stuck(rec(size=100, sizeleft=100, added=ago(23)), NOW)[0] is None
    assert m.is_stuck(rec(size=100, sizeleft=100, added=ago(25)), NOW)[0] == "stale"


def test_the_stale_boundary_is_strictly_greater_than_twenty_four_hours():
    assert m.is_stuck(rec(size=100, sizeleft=100, added=ago(24)), NOW)[0] is None


def test_the_age_is_measured_in_fractional_hours_not_whole_ones():
    # `/ 3600` and `// 3600` agree on every whole-hour age, so the two tests
    # above cannot tell them apart. Half past the boundary is where they split:
    # 24.5 clears `> 24`, floor(24.5) does not, and the item stops being stale.
    assert m.is_stuck(rec(size=100, sizeleft=100, added=ago(24.5)), NOW)[0] == "stale"


def test_a_one_byte_item_still_counts_as_having_a_known_size():
    # `size > 0` distinguishes "the size is known" from "no size info at all",
    # and the two arms report different reasons. `size > 1` reads the same on
    # every realistic size; one byte is where it stops meaning the same thing.
    kind, why = m.is_stuck(rec(size=1, sizeleft=1, added=ago(25)), NOW)
    assert kind == "stale"
    assert why.startswith("0% progress")


def test_a_partially_downloaded_item_is_never_stale_however_old():
    # sizeleft < size means progress was made; age alone must not delete it.
    assert m.is_stuck(rec(size=100, sizeleft=50, added=ago(1000)), NOW)[0] is None


def test_an_item_with_no_size_goes_stale_on_age_with_its_own_wording():
    kind, why = m.is_stuck(rec(size=0, sizeleft=0, added=ago(48)), NOW)
    assert kind == "stale"
    assert why == "no size info for 48h"


def test_a_sizeless_item_with_no_timestamp_is_not_stale_and_does_not_raise():
    # The no-size arm has its own copy of the `is not None and > 24` guard, and
    # the missing-timestamp test above only ever exercises the other one. With
    # the None check gone this comparison raises TypeError instead of skipping.
    assert m.is_stuck(rec(size=0, sizeleft=0), NOW)[0] is None
    assert m.is_stuck(rec(size=0, sizeleft=0, added="not a date"), NOW)[0] is None


def test_the_stale_reason_reports_the_measured_age():
    _, why = m.is_stuck(rec(size=100, sizeleft=100, added=ago(30)), NOW)
    assert why == "0% progress for 30h"


def test_a_missing_added_timestamp_is_not_stale():
    assert m.is_stuck(rec(size=100, sizeleft=100), NOW)[0] is None


def test_a_null_added_timestamp_is_not_stale_and_does_not_raise():
    # An absent key and a key holding null are different values: `.get("added",
    # "")` returns "" for the first and None for the second, and only ""
    # survives the fromisoformat below -- None raises AttributeError, which the
    # except clause does not catch. The empty-string guard is what stops it,
    # so the test above cannot show that the guard is load bearing.
    assert m.is_stuck(rec(size=100, sizeleft=100, added=None), NOW)[0] is None


def test_an_unparseable_added_timestamp_is_not_stale():
    assert m.is_stuck(rec(size=100, sizeleft=100, added="not a date"), NOW)[0] is None


def test_a_naive_added_timestamp_does_not_raise():
    # datetime.fromisoformat accepts a timestamp with no offset; subtracting it
    # from an aware "now" raises TypeError outside the heredoc's try block.
    assert m.is_stuck(rec(size=100, sizeleft=100, added="2020-01-01T00:00:00"), NOW)[0] is None


def test_the_error_branch_wins_over_the_stale_branch():
    kind, _ = m.is_stuck(rec(trackedDownloadStatus="warning",
                             errorMessage="stalled", size=100, sizeleft=100,
                             added=ago(999)), NOW)
    assert kind == "error"


def test_is_stuck_defaults_to_the_real_clock_when_none_is_given():
    # The default path is what production uses; a test that only ever injects
    # a clock would not notice it being broken.
    assert m.is_stuck(rec(size=100, sizeleft=100,
                          added="2020-01-01T00:00:00Z"))[0] == "stale"


# --- fetch_queue: defect #9, the unbounded loop ---------------------------

class PagingApi:
    def __init__(self, pages, total):
        self.pages = pages
        self.total = total
        self.gets = 0

    def get(self, port, path, key):
        self.gets += 1
        from urllib.parse import parse_qs, urlparse
        page = int(parse_qs(urlparse(path).query)["page"][0])
        return {"records": self.pages(page), "totalRecords": self.total(page)}


def svc():
    return m.services("SK", "")[0]


def test_a_single_page_queue_makes_exactly_one_request():
    api = PagingApi(lambda p: [{"id": 1}], lambda p: 1)
    assert m.fetch_queue(api, svc(), out=lambda *_: None) == [{"id": 1}]
    assert api.gets == 1


def test_pagination_continues_until_the_reported_total_is_covered():
    api = PagingApi(lambda p: [{"id": i} for i in range(m.PAGE_SIZE)], lambda p: 120)
    got = m.fetch_queue(api, svc(), out=lambda *_: None)
    assert api.gets == 3
    assert len(got) == 150


def test_a_service_reporting_an_ever_growing_total_is_bounded():
    # Defect #9. The heredoc looped on `page * 50 >= totalRecords` alone, so a
    # total that grows at least as fast as the pages are consumed never
    # terminated -- inside a systemd unit, with no output and no timeout.
    api = PagingApi(lambda p: [{"id": p}] * m.PAGE_SIZE, lambda p: 10 ** 9)
    lines = []
    got = m.fetch_queue(api, svc(), out=lines.append, max_pages=5)
    assert api.gets == 5
    assert len(got) == 5 * m.PAGE_SIZE


def test_hitting_the_page_bound_is_reported_rather_than_silent():
    # A truncation nobody is told about reads as a complete run.
    api = PagingApi(lambda p: [{"id": p}] * m.PAGE_SIZE, lambda p: 10 ** 9)
    lines = []
    m.fetch_queue(api, svc(), out=lines.append, max_pages=2)
    assert any("Stopped after 2 pages" in line for line in lines)
    assert any("not examined" in line for line in lines)


def test_an_empty_page_ends_pagination_whatever_the_total_claims():
    api = PagingApi(lambda p: [] if p > 1 else [{"id": 1}], lambda p: 10 ** 9)
    got = m.fetch_queue(api, svc(), out=lambda *_: None)
    assert api.gets == 2
    assert got == [{"id": 1}]


def test_a_failed_fetch_stops_and_says_so():
    class Dead:
        def get(self, *a):
            return None
    lines = []
    assert m.fetch_queue(Dead(), svc(), out=lines.append) == []
    assert any("Failed to fetch queue" in line for line in lines)


def test_the_default_page_bound_is_not_unlimited():
    assert isinstance(m.MAX_PAGES, int) and 0 < m.MAX_PAGES < 10 ** 6


# --- process_service ------------------------------------------------------

class FakeApi:
    def __init__(self, records, delete_ok=True, post_ok=True):
        self.records = records
        self.delete_ok = delete_ok
        self.post_ok = post_ok
        self.deletes = []
        self.posts = []

    def get(self, port, path, key):
        return {"records": self.records, "totalRecords": len(self.records)}

    def delete(self, port, path, key):
        self.deletes.append(path)
        return self.delete_ok

    def post_json(self, port, path, key, data):
        self.posts.append(data)
        return self.post_ok


def stuck(**kw):
    kw.setdefault("seriesId", 7)
    kw.setdefault("movieId", 7)
    return rec(trackedDownloadState="importBlocked", **kw)


def test_process_service_announces_the_service_and_queue_size():
    api = FakeApi([stuck(), rec(id=2, added=ago(1))])
    lines = []
    m.process_service(svc(), api, False, False, out=lines.append, now=NOW)
    assert any("--- Sonarr (port 8989) ---" in line for line in lines)
    assert any("Queue size: 2 items" in line for line in lines)


def test_a_dry_run_issues_no_delete_and_no_search():
    api = FakeApi([stuck()])
    lines = []
    removed, searches = m.process_service(svc(), api, False, False,
                                          out=lines.append, now=NOW)
    assert api.deletes == [] and api.posts == []
    assert (removed, searches) == (1, 1)
    assert any("[dry-run] Would remove: Item" in line for line in lines)
    # The dry-run branch's own reason line -- the apply branch prints the same
    # text from a different call site, so a test only covering that one leaves
    # this one droppable.
    assert any("Reason: import blocked" in line for line in lines)


def test_apply_deletes_from_the_client_and_blocklists():
    api = FakeApi([stuck()])
    m.process_service(svc(), api, True, False, out=lambda *_: None, now=NOW,
                      sleep=lambda _: None)
    assert api.deletes == ["/api/v3/queue/1?removeFromClient=true&blocklist=true"]


def test_apply_triggers_one_search_per_distinct_target():
    api = FakeApi([stuck(id=1, seriesId=7), stuck(id=2, seriesId=7),
                   stuck(id=3, seriesId=9)])
    removed, searches = m.process_service(svc(), api, True, False,
                                          out=lambda *_: None, now=NOW,
                                          sleep=lambda _: None)
    assert removed == 3
    assert searches == 2
    assert api.posts == [{"name": "SeriesSearch", "seriesId": 7},
                         {"name": "SeriesSearch", "seriesId": 9}]


def test_a_failed_search_says_so_against_the_item_it_failed_for():
    # The summary counts searches *attempted*, so a service rejecting every
    # search still reports "2 searches triggered". This per-item line is the
    # only place the failure is visible at all -- and dropping it changes no
    # count, no status and no other message.
    api = FakeApi([stuck(seriesId=7)], post_ok=False)
    lines = []
    m.process_service(svc(), api, True, False, out=lines.append, now=NOW,
                      sleep=lambda _: None)
    assert any("Search seriesId=7: FAILED" in line for line in lines)
    assert not any("queued" in line for line in lines)


def test_a_successful_search_is_reported_as_queued():
    api = FakeApi([stuck(seriesId=7)])
    lines = []
    m.process_service(svc(), api, True, False, out=lines.append, now=NOW,
                      sleep=lambda _: None)
    assert any("Search seriesId=7: queued" in line for line in lines)
    assert any("✓ Removed: Item" in line for line in lines)
    assert any("Reason: import blocked" in line for line in lines)
    assert any("Triggering searches for 1 sonarr item(s):" in line for line in lines)


def test_a_dry_run_names_each_search_it_would_have_triggered():
    # The dry run's whole output is its product; the count in the summary says
    # how many, and only this line says which.
    api = FakeApi([stuck(seriesId=7), stuck(id=2, seriesId=9)])
    lines = []
    m.process_service(svc(), api, False, False, out=lines.append, now=NOW)
    assert any("[dry-run] Search seriesId=7" in line for line in lines)
    assert any("[dry-run] Search seriesId=9" in line for line in lines)
    assert api.posts == []
    assert any("Found 2 stuck item(s):" in line for line in lines)
    assert any("Would trigger searches for 2 sonarr item(s):" in line for line in lines)


def test_a_failed_delete_is_not_counted_and_triggers_no_search():
    api = FakeApi([stuck()], delete_ok=False)
    lines = []
    removed, searches = m.process_service(svc(), api, True, False,
                                          out=lines.append, now=NOW,
                                          sleep=lambda _: None)
    assert (removed, searches) == (0, 0)
    assert api.posts == []
    assert any("✗ Failed to remove: Item" in line for line in lines)


def test_a_healthy_queue_reports_nothing_stuck_and_writes_nothing():
    api = FakeApi([rec(added=ago(1))])
    lines = []
    removed, searches = m.process_service(svc(), api, True, False,
                                          out=lines.append, now=NOW)
    assert (removed, searches) == (0, 0)
    assert api.deletes == []
    assert any("No stuck items found" in line for line in lines)
    # The early return this message sits on skips the rest of the function --
    # with it gone, the same return value comes back via fallthrough, and only
    # this "was the found-count line printed too" check can tell the two apart.
    assert not any("Found" in line for line in lines)


def test_an_item_with_no_target_id_is_removed_without_a_search():
    api = FakeApi([rec(id=1, trackedDownloadState="importBlocked")])
    removed, searches = m.process_service(svc(), api, True, False,
                                          out=lambda *_: None, now=NOW,
                                          sleep=lambda _: None)
    assert (removed, searches) == (1, 0)


def test_the_apply_path_pauses_between_deletes():
    api = FakeApi([stuck(id=1), stuck(id=2)])
    slept = []
    m.process_service(svc(), api, True, False, out=lambda *_: None, now=NOW,
                      sleep=slept.append)
    assert slept == [0.5, 0.5]


def test_verbose_reports_progress_and_the_classification():
    api = FakeApi([stuck(size=200, sizeleft=50)])
    lines = []
    m.process_service(svc(), api, False, True, out=lines.append, now=NOW)
    assert any("Progress: 75.0%" in line and "Type: import_blocked" in line
               for line in lines)


def test_verbose_does_not_divide_by_a_zero_size():
    api = FakeApi([stuck(size=0, sizeleft=0)])
    lines = []
    m.process_service(svc(), api, False, True, out=lines.append, now=NOW)
    assert any("Progress: 0%" in line for line in lines)


def test_titles_are_truncated_to_seventy_characters():
    api = FakeApi([stuck(title="x" * 200)])
    lines = []
    m.process_service(svc(), api, False, False, out=lines.append, now=NOW)
    assert any("x" * 70 in line for line in lines)
    assert not any("x" * 71 in line for line in lines)


# --- run ------------------------------------------------------------------

def test_the_summary_names_the_mode_and_totals():
    api = FakeApi([stuck()])
    lines = []
    m.run(m.services("SK", "RK"), api, False, False, out=lines.append, now=NOW)
    assert any("Summary (DRY RUN): 2 items removed, 2 searches triggered" in line
               for line in lines)


def test_a_dry_run_that_found_work_says_how_to_apply_it():
    api = FakeApi([stuck()])
    lines = []
    m.run(m.services("SK", ""), api, False, False, out=lines.append, now=NOW)
    assert any("Run with --apply" in line for line in lines)


def test_a_dry_run_that_found_nothing_does_not_suggest_applying():
    api = FakeApi([rec(added=ago(1))])
    lines = []
    m.run(m.services("SK", ""), api, False, False, out=lines.append, now=NOW)
    assert not any("Run with --apply" in line for line in lines)


def test_the_applied_summary_says_applied():
    api = FakeApi([stuck()])
    lines = []
    m.run(m.services("SK", ""), api, True, False, out=lines.append, now=NOW,
          sleep=lambda _: None)
    assert any("Summary (APPLIED): 1 items removed" in line for line in lines)


def test_no_configured_service_is_a_clean_no_op():
    api = FakeApi([stuck()])
    assert m.run([], api, True, False, out=lambda *_: None, now=NOW) == (0, 0)
    assert api.deletes == []


# --- ArrApi: the seam every other test replaces ----------------------------
#
# Every test above hands run()/process_service() a FakeApi, which is what makes
# them fast and hermetic -- and also means ArrApi, the class that actually
# shells out to curl, had never been constructed once. The mutation sweep found
# it: the whole argv list could be truncated to `[]` and nothing went red.
# These tests patch subprocess.run and assert on the argv that would have been
# executed, so the command is pinned without a request ever leaving the process.

class FakeRun:
    def __init__(self, returncode=0, stdout=""):
        self.returncode = returncode
        self.stdout = stdout
        self.calls = []

    def __call__(self, argv, **kwargs):
        self.calls.append((argv, kwargs))

        class R:
            pass
        r = R()
        r.returncode = self.returncode
        r.stdout = self.stdout
        return r


CURL_KWARGS = {"capture_output": True, "text": True, "timeout": 30}


def test_get_shells_out_to_curl_with_the_built_url(monkeypatch):
    fake = FakeRun(stdout='{"records": [], "totalRecords": 0}')
    monkeypatch.setattr(m.subprocess, "run", fake)
    assert m.ArrApi().get(8989, "/api/v3/queue", "KEY") == {"records": [],
                                                           "totalRecords": 0}
    assert fake.calls == [(
        ["curl", "-s", "-f", "http://localhost:8989/api/v3/queue?apikey=KEY"],
        CURL_KWARGS,
    )]


def test_a_failed_curl_yields_none_rather_than_a_parse_error(monkeypatch):
    # stdout is empty on failure, so returning it to json.loads would raise.
    # The returncode check is the only thing standing between the two.
    monkeypatch.setattr(m.subprocess, "run", FakeRun(returncode=22, stdout=""))
    assert m.ArrApi().get(8989, "/api/v3/queue", "KEY") is None


def test_delete_sends_the_delete_verb_and_reports_success(monkeypatch):
    fake = FakeRun()
    monkeypatch.setattr(m.subprocess, "run", fake)
    assert m.ArrApi().delete(7878, "/api/v3/queue/9?removeFromClient=true",
                             "KEY") is True
    assert fake.calls == [(
        ["curl", "-s", "-f", "-X", "DELETE",
         "http://localhost:7878/api/v3/queue/9?removeFromClient=true&apikey=KEY"],
        CURL_KWARGS,
    )]


def test_a_failed_delete_reports_false(monkeypatch):
    monkeypatch.setattr(m.subprocess, "run", FakeRun(returncode=1))
    assert m.ArrApi().delete(7878, "/api/v3/queue/9", "KEY") is False


def test_post_json_sends_the_payload_as_a_json_body(monkeypatch):
    fake = FakeRun()
    monkeypatch.setattr(m.subprocess, "run", fake)
    assert m.ArrApi().post_json(7878, "/api/v3/command", "KEY",
                                {"name": "MoviesSearch", "movieIds": [3]}) is True
    argv, kwargs = fake.calls[0]
    assert argv == [
        "curl", "-s", "-f", "-X", "POST",
        "-H", "Content-Type: application/json",
        "-d", '{"name": "MoviesSearch", "movieIds": [3]}',
        "http://localhost:7878/api/v3/command?apikey=KEY",
    ]
    assert kwargs == CURL_KWARGS
    # The body must survive a round trip, not merely look right as a string.
    assert json.loads(argv[8]) == {"name": "MoviesSearch", "movieIds": [3]}


def test_a_failed_post_reports_false(monkeypatch):
    monkeypatch.setattr(m.subprocess, "run", FakeRun(returncode=7))
    assert m.ArrApi().post_json(7878, "/api/v3/command", "KEY", {}) is False


# --- run(): what it forwards to process_service ----------------------------
#
# run() passes out=, now=, sleep= and max_pages= straight through. Dropping any
# one of them silently reinstates the production default -- the real clock, the
# real sleep, the real page bound -- which is invisible to a test that only
# asserts on the summary line.

def test_run_forwards_the_injected_clock():
    # Added in 2020 with zero progress: stale against any real clock, and not
    # stale against the clock injected here. If run() stops forwarding `now`,
    # process_service falls back to datetime.now() and deletes it.
    api = FakeApi([rec(size=100, sizeleft=100, added="2020-01-01T00:00:00Z")])
    removed, _ = m.run(m.services("SK", ""), api, True, False,
                       out=lambda *_: None,
                       now=datetime(2020, 1, 1, 1, 0, tzinfo=timezone.utc),
                       sleep=lambda _: None)
    assert removed == 0
    assert api.deletes == []


def test_run_forwards_the_injected_sleep():
    slept = []
    api = FakeApi([stuck()])
    m.run(m.services("SK", ""), api, True, False, out=lambda *_: None,
          now=NOW, sleep=slept.append)
    assert slept, "the pause between deletes went to the real time.sleep"


def test_run_forwards_the_page_bound():
    lines = []
    api = PagingApi(pages=lambda p: [rec(id=p)], total=lambda p: 10_000)
    m.run([svc()], api, False, False, out=lines.append, now=NOW, max_pages=1)
    assert any("Stopped after 1 pages" in line for line in lines)


def test_the_summary_is_introduced_by_a_rule():
    # The separator is the only thing separating one service's per-item output
    # from the totals in a log cron mails out; dropping it changes no status
    # and no total. Asserted by position rather than presence, so it cannot be
    # satisfied by some other line that happens to contain the same characters.
    api = FakeApi([stuck()])
    lines = []
    m.run(m.services("SK", ""), api, False, False, out=lines.append, now=NOW)
    i = next(n for n, line in enumerate(lines) if line.startswith("Summary ("))
    assert lines[i - 1] == "\n" + "=" * 40


def test_the_applied_summary_does_not_suggest_applying():
    # `not apply_changes and total_removed > 0` -> `True and ...` keeps every
    # existing assertion true, because no test had an applied run *and* looked
    # for the absence of the dry-run hint.
    api = FakeApi([stuck()])
    lines = []
    m.run(m.services("SK", ""), api, True, False, out=lines.append, now=NOW,
          sleep=lambda _: None)
    assert not any("Run with --apply" in line for line in lines)


# --- main(): the argv boundary --------------------------------------------

def test_main_maps_argv_onto_the_run_arguments(monkeypatch):
    seen = {}

    def spy(svcs, api, apply_changes, verbose, **kw):
        seen.update(svcs=svcs, api=api, apply_changes=apply_changes,
                    verbose=verbose)
        return 0, 0

    monkeypatch.setattr(m, "run", spy)
    assert m.main(["prog", "true", "false", "SK", "RK"]) == 0
    assert seen["apply_changes"] is True
    assert seen["verbose"] is False
    assert isinstance(seen["api"], m.ArrApi)
    assert [s["name"] for s in seen["svcs"]] == ["Sonarr", "Radarr"]
    assert [s["key"] for s in seen["svcs"]] == ["SK", "RK"]


def test_main_treats_anything_but_the_literal_true_as_false(monkeypatch):
    # bash passes the lowercase words `true`/`false`; the sibling Sonarr script
    # compared against "True" and its --apply flag was inert for that reason.
    seen = {}
    monkeypatch.setattr(m, "run", lambda svcs, api, a, v, **kw: seen.update(
        apply_changes=a, verbose=v) or (0, 0))
    m.main(["prog", "True", "1", "SK", ""])
    assert seen == {"apply_changes": False, "verbose": False}


def test_the_module_actually_runs_when_executed_as_a_script():
    # `sys.exit(main(sys.argv))` is unreachable from any import-based test, and
    # with it gone the script exits 0 having done nothing -- indistinguishable
    # from a clean run, as far as the bash half can tell. Run with no arguments
    # so main() dies on argv[1] before it can build an ArrApi and reach curl.
    r = subprocess.run(
        [sys.executable,
         os.path.join(os.path.dirname(m.__file__), "queue_cleanup.py")],
        capture_output=True, text=True)
    assert r.returncode != 0
    assert "IndexError" in r.stderr
