"""Behavioural tests for scripts/lib/queue_cleanup.py.

is_stuck() decides whether a download is deleted from the client and
blocklisted. It had seven classification branches and 24-hour date arithmetic,
and no test of any kind, because it lived in a heredoc.

Every test here injects the clock. A test whose result depends on when it runs
is a test that will one day fail for a reason nobody can reproduce.
"""

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


def test_downloading_metadata_is_matched_case_insensitively():
    kind, why = m.is_stuck(rec(errorMessage="Downloading Metadata"), NOW)
    assert (kind, why) == ("metadata", "stuck downloading metadata")


def test_zero_progress_becomes_stale_only_after_twenty_four_hours():
    assert m.is_stuck(rec(size=100, sizeleft=100, added=ago(23)), NOW)[0] is None
    assert m.is_stuck(rec(size=100, sizeleft=100, added=ago(25)), NOW)[0] == "stale"


def test_the_stale_boundary_is_strictly_greater_than_twenty_four_hours():
    assert m.is_stuck(rec(size=100, sizeleft=100, added=ago(24)), NOW)[0] is None


def test_a_partially_downloaded_item_is_never_stale_however_old():
    # sizeleft < size means progress was made; age alone must not delete it.
    assert m.is_stuck(rec(size=100, sizeleft=50, added=ago(1000)), NOW)[0] is None


def test_an_item_with_no_size_goes_stale_on_age_with_its_own_wording():
    kind, why = m.is_stuck(rec(size=0, sizeleft=0, added=ago(48)), NOW)
    assert kind == "stale"
    assert why == "no size info for 48h"


def test_the_stale_reason_reports_the_measured_age():
    _, why = m.is_stuck(rec(size=100, sizeleft=100, added=ago(30)), NOW)
    assert why == "0% progress for 30h"


def test_a_missing_added_timestamp_is_not_stale():
    assert m.is_stuck(rec(size=100, sizeleft=100), NOW)[0] is None


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


def test_a_dry_run_issues_no_delete_and_no_search():
    api = FakeApi([stuck()])
    removed, searches = m.process_service(svc(), api, False, False,
                                          out=lambda *_: None, now=NOW)
    assert api.deletes == [] and api.posts == []
    assert (removed, searches) == (1, 1)


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


def test_a_failed_delete_is_not_counted_and_triggers_no_search():
    api = FakeApi([stuck()], delete_ok=False)
    removed, searches = m.process_service(svc(), api, True, False,
                                          out=lambda *_: None, now=NOW,
                                          sleep=lambda _: None)
    assert (removed, searches) == (0, 0)
    assert api.posts == []


def test_a_healthy_queue_reports_nothing_stuck_and_writes_nothing():
    api = FakeApi([rec(added=ago(1))])
    lines = []
    removed, searches = m.process_service(svc(), api, True, False,
                                          out=lines.append, now=NOW)
    assert (removed, searches) == (0, 0)
    assert api.deletes == []
    assert any("No stuck items found" in line for line in lines)


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
