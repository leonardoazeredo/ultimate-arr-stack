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
CURL_ARGV = ["curl", "-s", "-f", "--config", "-"]


def curl_config(fake, index=0):
    """The config text handed to curl on stdin by call `index`.

    Every real request goes through here rather than through argv. The API key
    used to be an argv element, where /proc/<pid>/cmdline shows it to any user
    on the box -- and this script runs hourly from systemd. Asserting on this
    text is therefore asserting on where the key went, not just on the request
    being well-formed.
    """
    return fake.calls[index][1]["input"]


def config_value(text, field):
    """The value of one `field = "..."` line, unescaped."""
    prefix = f"{field} = "
    for line in text.splitlines():
        if line.startswith(prefix):
            value = line[len(prefix):]
            assert value.startswith('"') and value.endswith('"'), value
            return value[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    raise AssertionError(f"no {field} in:\n{text}")


def test_get_shells_out_to_curl_with_the_built_url(monkeypatch):
    fake = FakeRun(stdout='{"records": [], "totalRecords": 0}')
    monkeypatch.setattr(m.subprocess, "run", fake)
    assert m.ArrApi().get(8989, "/api/v3/queue", "KEY") == {"records": [],
                                                           "totalRecords": 0}
    assert fake.calls[0][0] == CURL_ARGV
    assert fake.calls[0][1] == dict(CURL_KWARGS, input=curl_config(fake))
    assert config_value(curl_config(fake), "url") == \
        "http://localhost:8989/api/v3/queue?apikey=KEY"


def test_the_api_key_is_not_an_argv_element(monkeypatch):
    # The whole point of the config-file transport. An argv assertion that only
    # checks the argv *shape* would pass with the key appended to it.
    fake = FakeRun(stdout="{}")
    monkeypatch.setattr(m.subprocess, "run", fake)
    m.ArrApi().get(8989, "/api/v3/queue", "S3CRET")
    argv, kwargs = fake.calls[0]
    assert not any("S3CRET" in str(element) for element in argv)
    assert "S3CRET" in kwargs["input"]


def test_a_quote_or_backslash_in_a_value_survives_the_round_trip(monkeypatch):
    # curl's config format quotes values, so a value carrying a quote would end
    # its own line and the rest would be parsed as curl options. A title with
    # either character is ordinary; a key with one is not, but the escaping is
    # shared and this is the function that has to be right.
    fake = FakeRun()
    monkeypatch.setattr(m.subprocess, "run", fake)
    m.ArrApi().post_json(7878, "/api/v3/command", 'KEY"with\\both',
                         {"title": 'He said "hi" back\\slash'})
    text = curl_config(fake)
    assert config_value(text, "url") == \
        'http://localhost:7878/api/v3/command?apikey=KEY"with\\both'
    assert json.loads(config_value(text, "data")) == \
        {"title": 'He said "hi" back\\slash'}


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
    text = curl_config(fake)
    assert config_value(text, "request") == "DELETE"
    assert config_value(text, "url") == \
        "http://localhost:7878/api/v3/queue/9?removeFromClient=true&apikey=KEY"
    assert "data = " not in text


def test_a_failed_delete_reports_false(monkeypatch):
    monkeypatch.setattr(m.subprocess, "run", FakeRun(returncode=1))
    assert m.ArrApi().delete(7878, "/api/v3/queue/9", "KEY") is False


def test_post_json_sends_the_payload_as_a_json_body(monkeypatch):
    fake = FakeRun()
    monkeypatch.setattr(m.subprocess, "run", fake)
    assert m.ArrApi().post_json(7878, "/api/v3/command", "KEY",
                                {"name": "MoviesSearch", "movieIds": [3]}) is True
    text = curl_config(fake)
    assert config_value(text, "request") == "POST"
    assert config_value(text, "url") == \
        "http://localhost:7878/api/v3/command?apikey=KEY"
    assert 'header = "Content-Type: application/json"' in text
    # The body must survive a round trip, not merely look right as a string.
    assert json.loads(config_value(text, "data")) == \
        {"name": "MoviesSearch", "movieIds": [3]}


def test_a_failed_post_reports_false(monkeypatch):
    monkeypatch.setattr(m.subprocess, "run", FakeRun(returncode=7))
    assert m.ArrApi().post_json(7878, "/api/v3/command", "KEY", {}) is False


def test_a_failing_curl_with_a_parseable_body_still_yields_none(monkeypatch):
    # Two independent mechanisms return None -- the returncode check and the
    # JSON guard -- so a test that hands a failure nothing to parse cannot tell
    # which one answered, and deleting the status check survives it. The
    # generative sweep found exactly that after the JSON guard was added. curl
    # -f can leave a body on stdout (a 500 carrying a JSON error object), and
    # parsing it would hand the caller a service error as if it were the queue.
    monkeypatch.setattr(m.subprocess, "run",
                        FakeRun(returncode=22, stdout='{"detail": "boom"}'))
    assert m.ArrApi().get(8989, "/api/v3/queue", "KEY") is None


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
    monkeypatch.setenv("SONARR_API_KEY", "SK")
    monkeypatch.setenv("RADARR_API_KEY", "RK")
    assert m.main(["prog", "true", "false"]) == 0
    assert seen["apply_changes"] is True
    assert seen["verbose"] is False
    assert isinstance(seen["api"], m.ArrApi)
    assert [s["name"] for s in seen["svcs"]] == ["Sonarr", "Radarr"]
    assert [s["key"] for s in seen["svcs"]] == ["SK", "RK"]


def test_main_does_not_read_the_keys_from_argv(monkeypatch):
    # The keys were argv elements 3 and 4 until 2026-09-13, which put both of
    # them in this process's command line -- visible in /proc/<pid>/cmdline to
    # any user on the box, on a script that systemd runs hourly. Extra argv is
    # now ignored outright, and the environment is the only source.
    seen = {}
    monkeypatch.setattr(m, "run", lambda svcs, api, a, v, **kw: seen.update(
        keys=[s["key"] for s in svcs]) or (0, 0))
    monkeypatch.setenv("SONARR_API_KEY", "FROM-ENV")
    monkeypatch.delenv("RADARR_API_KEY", raising=False)
    m.main(["prog", "true", "false", "FROM-ARGV", "ALSO-ARGV"])
    assert seen["keys"] == ["FROM-ENV"]


def test_main_with_no_keys_in_the_environment_does_nothing(monkeypatch):
    # An absent key is an empty string, and services() drops a service whose
    # key is empty -- so a misconfigured environment is a clean no-op rather
    # than a run against two unauthenticated APIs.
    seen = {}
    monkeypatch.delenv("SONARR_API_KEY", raising=False)
    monkeypatch.delenv("RADARR_API_KEY", raising=False)
    monkeypatch.setattr(m, "run", lambda svcs, api, a, v, **kw: seen.update(
        names=[s["name"] for s in svcs]) or (0, 0))
    assert m.main(["prog", "true", "false"]) == 0
    assert seen["names"] == []


def test_main_passes_apply_changes_as_its_own_argument(monkeypatch):
    # Not covered by the spy above, and that is the point: the spy replaces
    # run() entirely, so it can only report what main() handed it. This drives
    # the REAL run() with a fake api and no configured keys, which means the
    # stack is services() -> run() -> process_service() -> api, and the flag's
    # position in that call matters. Drop it and ArrApi() lands in
    # apply_changes (truthy) while the real flag lands in verbose -- an
    # --apply run that quietly becomes a dry run, which is the exact shape of
    # the qBittorrent-removal bug this test is named after.
    monkeypatch.delenv("SONARR_API_KEY", raising=False)
    monkeypatch.delenv("RADARR_API_KEY", raising=False)
    api = FakeApi([stuck()])
    monkeypatch.setattr(m, "ArrApi", lambda: api)
    lines = []
    assert m.main(["prog", "true", "false", "unused"]) == 0
    # Same code path, with the output captured so the mode can be asserted on.
    m.run(m.services("", ""), api, True, False, out=lines.append, now=NOW,
          sleep=lambda _: None)
    assert any("Summary (APPLIED)" in line for line in lines)


def test_main_treats_anything_but_the_literal_true_as_false(monkeypatch):
    # bash passes the lowercase words `true`/`false`; the sibling Sonarr script
    # compared against "True" and its --apply flag was inert for that reason.
    seen = {}
    monkeypatch.setattr(m, "run", lambda svcs, api, a, v, **kw: seen.update(
        apply_changes=a, verbose=v) or (0, 0))
    m.main(["prog", "True", "1"])
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


# --- the debrid deadlock --------------------------------------------------
#
# Found live on 2026-09-12: Decypharr failed to resolve a TorBox link, gave up,
# and left 67 items at 0% "downloading" for a month. Removing such an item
# breaks the loop, and these pin the two things that let the replacement
# actually happen -- no blocklist (the release was never the problem) and
# searches aimed at the removed episodes, spaced out (a burst answers 429).

def debrid(**kw):
    """A stale queue record from a debrid client: 0% for two days."""
    kw.setdefault("downloadClient", "Decypharr (TorBox)")
    kw.setdefault("sizeleft", 100)
    kw.setdefault("added", ago(48))
    # The series id too: every real record carries one, and the removal memory
    # keys on it alongside the title. A fixture without it produces the key
    # "Sonarr|None|Item" and the second-strike tests would all pass vacuously
    # against a key nothing else uses.
    kw.setdefault("seriesId", 7)
    return rec(**kw)


def test_a_debrid_client_is_recognised_by_the_name_the_operator_gave_it():
    assert m.is_debrid_client({"downloadClient": "Decypharr (TorBox)"})
    assert m.is_debrid_client({"downloadClient": "TORBOX"})
    assert m.is_debrid_client({"downloadClient": "Real-Debrid"})
    assert not m.is_debrid_client({"downloadClient": "qBittorrent"})
    assert not m.is_debrid_client({})


def test_a_stale_debrid_item_is_not_blocklisted():
    assert m.should_blocklist(debrid(), "stale") is False


def test_a_stale_swarm_item_is_still_blocklisted():
    assert m.should_blocklist({"downloadClient": "qBittorrent"}, "stale") is True


def test_a_debrid_item_is_blocklisted_for_every_other_reason():
    # A blocked or failing import is about the files, not about who fetched
    # them, and the release is still the wrong one to grab again.
    for reason in ("error", "import_stuck", "import_blocked",
                   "import_warning", "metadata"):
        assert m.should_blocklist(debrid(), reason) is True


def test_episode_ids_merge_the_scalar_the_list_and_the_duplicates():
    record = {"episodeId": 12,
              "episodes": [{"id": 12}, {"id": 7}, {"id": 7}, {"nope": 1}, "junk"]}
    assert m.episode_ids(record) == (7, 12)


def test_episode_ids_is_empty_without_any_usable_id():
    assert m.episode_ids({}) == ()
    assert m.episode_ids({"episodeId": "12", "episodes": None}) == ()


def test_a_sonarr_target_searches_the_episodes_that_were_removed():
    payload, label = m.target_search(svc(), 7, {437})
    assert payload == {"name": "EpisodeSearch", "episodeIds": [437]}
    assert label == "episodeIds=437"


def test_a_sonarr_target_without_episode_ids_falls_back_to_the_series():
    payload, label = m.target_search(svc(), 7, set())
    assert payload == {"name": "SeriesSearch", "seriesId": 7}
    assert label == "seriesId=7"


def test_the_usenet_client_is_not_mistaken_for_a_debrid_one():
    # "SABnzbd (TorBox Usenet)" carries the provider's name, so the debrid
    # patterns match it -- and the stale exemption would then cover every dead
    # NZB as well. A usenet download that never finishes is a release with
    # missing articles, which belongs on the blocklist like a dead torrent.
    assert not m.is_debrid_client({"downloadClient": "SABnzbd (TorBox Usenet)"})
    assert not m.is_debrid_client({"downloadClient": "NZBGet"})
    assert m.should_blocklist({"downloadClient": "SABnzbd (TorBox Usenet)"},
                              "stale") is True


def test_a_radarr_target_keeps_the_per_film_search():
    radarr = {"name": "Radarr", "port": 7878, "key": "K",
              "id_field": "movieId", "search_cmd": "MoviesSearch",
              "search_key": "movieIds"}
    payload, label = m.target_search(radarr, 9, {12, 13})
    assert payload == {"name": "MoviesSearch", "movieIds": [9]}
    assert label == "movieId=9"


def test_applying_a_stale_debrid_item_deletes_without_blocklisting():
    api = FakeApi([debrid()])
    lines = []
    m.process_service(svc(), api, True, False, out=lines.append, now=NOW,
                      sleep=lambda _: None)
    assert api.deletes == ["/api/v3/queue/1?removeFromClient=true&blocklist=false"]
    assert any("Not blocklisted" in line for line in lines)


def test_applying_a_stale_swarm_item_still_blocklists():
    api = FakeApi([debrid(downloadClient="qBittorrent")])
    m.process_service(svc(), api, True, False, out=lambda *_: None, now=NOW,
                      sleep=lambda _: None)
    assert api.deletes == ["/api/v3/queue/1?removeFromClient=true&blocklist=true"]


def test_the_removed_episodes_are_searched_in_one_command():
    api = FakeApi([debrid(id=1, seriesId=7, episodeId=437),
                   debrid(id=2, seriesId=7, episodeId=438)])
    m.process_service(svc(), api, True, False, out=lambda *_: None, now=NOW,
                      sleep=lambda _: None)
    assert api.posts == [{"name": "EpisodeSearch", "episodeIds": [437, 438]}]


def test_a_burst_of_searches_is_paced():
    # Back-to-back searches get 429 from the indexer, and Sonarr then disables
    # that indexer -- every later search in the run returns "0 active indexers"
    # and the items it just removed find no replacement at all.
    api = FakeApi([debrid(id=1, seriesId=7, episodeId=1),
                   debrid(id=2, seriesId=9, episodeId=2)])
    slept = []
    m.process_service(svc(), api, True, False, out=lambda *_: None, now=NOW,
                      sleep=slept.append)
    assert m.SEARCH_INTERVAL_SECONDS in slept


def test_the_last_search_is_not_followed_by_a_wait():
    api = FakeApi([debrid(seriesId=7, episodeId=1)])
    slept = []
    m.process_service(svc(), api, True, False, out=lambda *_: None, now=NOW,
                      sleep=slept.append)
    assert m.SEARCH_INTERVAL_SECONDS not in slept


def test_a_dry_run_does_not_wait_between_searches():
    api = FakeApi([debrid(id=1, seriesId=7, episodeId=1),
                   debrid(id=2, seriesId=9, episodeId=2)])
    slept = []
    m.process_service(svc(), api, False, False, out=lambda *_: None, now=NOW,
                      sleep=slept.append)
    assert m.SEARCH_INTERVAL_SECONDS not in slept


def test_a_malformed_200_is_a_failed_fetch_not_a_traceback(monkeypatch):
    # curl -f passes a 200 whose body is an HTML error page straight through,
    # and json.loads then raises out of the middle of a run -- taking the other
    # service's cleanup with it. fetch_queue already reads None as a failed
    # fetch and says so.
    monkeypatch.setattr(m.subprocess, "run",
                        FakeRun(returncode=0, stdout="<html>nope</html>"))
    assert m.ArrApi().get(8989, "/api/v3/queue", "KEY") is None


# --- the age leash: two thresholds, and which record gets which -----------
#
# A debrid client either resolves a link in seconds or it never will, so a
# three-hour silence is a failure. A swarm client that has found no peers yet
# may still find some, so it keeps the day-long rule. These pin the split, the
# boundary on the short side, and the two client names that must NOT get the
# short leash.

def test_a_debrid_item_goes_stale_after_three_hours_not_twenty_four():
    assert m.is_stuck(debrid(size=100, added=ago(2)), NOW)[0] is None
    kind, why = m.is_stuck(debrid(size=100, added=ago(4)), NOW)
    assert kind == "stale"
    # The reason still reports the measured age with its own wording -- the
    # message is what an operator reads to decide whether the threshold is
    # right, and "4h" is the evidence for it.
    assert why == "0% progress for 4h"


def test_the_debrid_boundary_is_strictly_greater_than_three_hours():
    # `> 3` and `>= 3` differ only at exactly three hours.
    assert m.is_stuck(debrid(size=100, added=ago(3)), NOW)[0] is None
    assert m.is_stuck(debrid(size=100, added=ago(3.5)), NOW)[0] == "stale"


def test_a_swarm_client_keeps_the_twenty_four_hour_rule():
    # Five hours of silence from a torrent client is ordinary. Deleting on the
    # debrid threshold here would remove healthy swarm downloads and blocklist
    # releases that were never the problem.
    assert m.is_stuck(rec(downloadClient="qBittorrent", size=100, sizeleft=100,
                          added=ago(5)), NOW)[0] is None
    assert m.is_stuck(rec(downloadClient="qBittorrent", size=100, sizeleft=100,
                          added=ago(25)), NOW)[0] == "stale"


def test_a_usenet_client_keeps_the_twenty_four_hour_rule():
    # This stack's usenet client is named "SABnzbd (TorBox Usenet)", so the
    # debrid pattern matches it. is_debrid_client excludes usenet first, and
    # the short leash is the second thing that would get it wrong.
    for client in ("SABnzbd (TorBox Usenet)", "NZBGet"):
        assert m.is_stuck(rec(downloadClient=client, size=100, sizeleft=100,
                              added=ago(5)), NOW)[0] is None


def test_the_sizeless_debrid_arm_uses_the_shorter_threshold_too():
    # Two arms, two copies of the comparison. Changing only the first leaves a
    # metadata-only debrid item waiting a day -- the exact record shape a
    # debrid client produces when it cannot resolve anything at all.
    kind, why = m.is_stuck(debrid(size=0, sizeleft=0, added=ago(4)), NOW)
    assert kind == "stale"
    assert why == "no size info for 4h"


def test_a_record_with_no_client_name_is_treated_as_a_swarm_client():
    # The default has to be the cautious one: an unrecognised client getting
    # the three-hour leash would delete real downloads.
    assert m.is_stuck(rec(size=100, sizeleft=100, added=ago(5)), NOW)[0] is None


# --- completed downloads the arr refuses to import ------------------------
#
# Found in the live queues on 2026-09-13. Both shapes are terminal: the arr has
# made its decision, the client has nothing left to report, and the item sits
# in importPending forever. Each one also blocked every alternative release for
# its title, because a queue item at the cutoff makes the arr reject the rest.

def test_a_sample_verdict_is_stuck_although_the_status_is_completed():
    # Sonarr reports this with trackedDownloadStatus "completed", not
    # "warning" -- which is exactly why the older import branch, gated on
    # warning, never saw it.
    kind, why = m.is_stuck(rec(trackedDownloadState="importPending",
                               trackedDownloadStatus="completed",
                               statusMessages=[{"messages":
                                                ["Unable to determine if file is a sample"]}]), NOW)
    assert kind == "import_refused"
    assert why == "cannot import: unable to determine if file is a sample"


def test_a_release_that_does_not_contain_the_movie_is_stuck():
    # Radarr's wording, verbatim from the X-Men queue record: the movie was
    # matched by id, the release name did not parse to it, and Radarr refused.
    kind, why = m.is_stuck(rec(trackedDownloadState="importPending",
                               trackedDownloadStatus="warning",
                               statusMessages=[{"messages":
                                                ["Movie [X-Men (2000)][tt0120903, 36657] was not found in the grabbed release: X-Men.2000.2160p.WEBDL"]}]), NOW)
    assert kind == "import_refused"
    assert why == "cannot import: was not found in the grabbed release"


def test_the_wedged_import_markers_are_matched_case_insensitively():
    # The arrs are consistent about their own capitalisation today; nothing
    # promises they will stay that way, and a silent miss here restores the
    # forever-stuck item this rule exists to remove.
    kind, _ = m.is_stuck(rec(trackedDownloadState="importPending",
                             statusMessages=[{"messages":
                                              ["UNABLE TO DETERMINE IF FILE IS A SAMPLE"]}]), NOW)
    assert kind == "import_refused"


def test_an_import_pending_item_with_an_unrelated_message_is_left_alone():
    # The rule keys on two specific verdicts, not on importPending in general:
    # a download that is simply waiting its turn must survive.
    assert m.is_stuck(rec(trackedDownloadState="importPending",
                          trackedDownloadStatus="warning",
                          statusMessages=[{"messages": ["Waiting to import"]}]), NOW)[0] is None


def test_the_import_pending_warning_rule_still_wins_for_its_own_messages():
    # Ordering guard: the executable/not-an-upgrade verdict is a warning-level
    # import, classified `import_warning`, and the broader wedged-import rule
    # sits after it. Swapping the two would silently reclassify both.
    kind, _ = m.is_stuck(rec(trackedDownloadState="importPending",
                             trackedDownloadStatus="warning",
                             statusMessages=[{"messages": ["Not an upgrade for existing file"]}]), NOW)
    assert kind == "import_warning"


# --- refused imports: keep the file, do not blocklist ---------------------
#
# The first version of this rule classified a refused import as `import_stuck`
# and treated it like every other removal: delete from the client, blocklist
# the release, search again. All three were wrong, and the evidence is what
# happened next. Both live files -- a 2.9 GB Sopranos episode and a 15 GB
# X-Men -- imported cleanly by hand minutes after the script deleted them, so
# the release was never the problem and blocklisting it dropped a working
# copy. And a replacement search is pointless while the file is still on disk:
# all it can do is fetch the same bytes twice.

def refused(**kw):
    """A completed download the arr refused to match."""
    kw.setdefault("trackedDownloadState", "importPending")
    kw.setdefault("statusMessages", [{"messages":
                                      ["Unable to determine if file is a sample"]}])
    kw.setdefault("seriesId", 7)
    kw.setdefault("movieId", 7)
    kw.setdefault("size", 2000)
    return rec(**kw)


def test_a_refused_import_is_never_blocklisted():
    # Blocklisting it would blacklist a release that is sitting on disk,
    # complete and importable, over a naming or sampling verdict.
    assert m.should_blocklist(refused(), "import_refused") is False
    assert m.should_blocklist(debrid(), "import_refused") is False


def test_a_refused_import_keeps_the_download_on_disk():
    assert m.should_remove_from_client(refused(), "import_refused") is False


def test_every_other_reason_still_deletes_the_download():
    # The exemption is one reason type wide. Widening it is how a dead 15 GB
    # torrent stops being cleaned up.
    for reason in ("stale", "error", "import_stuck", "import_blocked",
                   "import_warning", "metadata"):
        assert m.should_remove_from_client(debrid(), reason) is True


def test_a_wedged_import_is_removed_from_the_queue_but_kept_on_disk():
    api = FakeApi([refused()])
    lines = []
    m.process_service(svc(), api, True, False, out=lines.append, now=NOW,
                      sleep=lambda _: None)
    assert api.deletes == [
        "/api/v3/queue/1?removeFromClient=false&blocklist=false"]
    assert any("Kept on disk" in line for line in lines)
    assert not any("blocklisted" in line.lower() and "Not blocklisted" not in line
                   for line in lines)


def test_a_kept_download_triggers_no_replacement_search():
    # The file is still there. A search cannot improve on it, and can only
    # fetch a second copy of something already on disk.
    api = FakeApi([refused()])
    removed, searches = m.process_service(svc(), api, True, False,
                                          out=lambda *_: None, now=NOW,
                                          sleep=lambda _: None)
    assert (removed, searches) == (1, 0)
    assert api.posts == []


def test_the_dry_run_says_the_download_would_be_kept():
    api = FakeApi([refused()])
    lines = []
    removed, searches = m.process_service(svc(), api, False, False,
                                          out=lines.append, now=NOW)
    assert (removed, searches) == (1, 0)
    assert any("Would keep the download on disk" in line for line in lines)


def test_an_import_stuck_that_is_not_a_refusal_still_deletes_and_blocklists():
    # `import_stuck` and `import_refused` are separate reason types precisely
    # so that the KEEP_FILE_REASONS exemption cannot swallow the stuck-import
    # case, where the download really is the problem.
    api = FakeApi([rec(trackedDownloadState="importing",
                       trackedDownloadStatus="warning", seriesId=7)])
    m.process_service(svc(), api, True, False, out=lambda *_: None, now=NOW,
                      sleep=lambda _: None)
    assert api.deletes == [
        "/api/v3/queue/1?removeFromClient=true&blocklist=true"]


# --- the second-strike blocklist ------------------------------------------
#
# Found live on 2026-09-13. The first-strike exemption above is what keeps a
# transient provider failure from costing a release its place in the queue --
# but on its own it is a livelock. Six titles were removed at 00:16, re-grabbed
# by the arr's next RSS sync, and stalled again by 00:45, because nothing was
# blocklisted and the indexer kept offering the same release. The memory of
# what was removed is what breaks the loop.

def test_a_release_is_remembered_by_service_target_and_title():
    key = m.removal_key(svc(), {"seriesId": 7, "title": "Show.S01E01.1080p"})
    assert key == "Sonarr|7|Show.S01E01.1080p"


def test_a_record_with_no_title_still_gets_a_key():
    assert m.removal_key(svc(), {"seriesId": 7}) == "Sonarr|7|unknown"


def test_a_second_removal_of_the_same_release_is_blocklisted():
    state = {}
    m.remember_removal(state, svc(), debrid(), NOW)
    assert m.should_blocklist(debrid(), "stale", removed_before=True) is True
    assert m.should_blocklist(debrid(), "stale", removed_before=False) is False


def test_the_first_removal_records_what_it_did():
    state = {}
    m.remember_removal(state, svc(), debrid(), NOW)
    assert state["Sonarr|7|Item"]["count"] == 1
    assert state["Sonarr|7|Item"]["last"] == NOW.isoformat()
    m.remember_removal(state, svc(), debrid(), NOW)
    assert state["Sonarr|7|Item"]["count"] == 2


def test_a_corrupt_count_does_not_abort_the_run():
    # The file outlives the code that wrote it and sits on the NAS between
    # releases. Raising here aborts a run that has already deleted items from
    # the client.
    state = {"Sonarr|7|Item": {"count": "two", "last": NOW.isoformat()}}
    m.remember_removal(state, svc(), debrid(), NOW)
    assert state["Sonarr|7|Item"]["count"] == 1


def test_a_missing_state_file_is_an_empty_memory(tmp_path):
    assert m.load_state(str(tmp_path / "nope.json")) == {}


def test_a_corrupt_state_file_is_an_empty_memory(tmp_path):
    path = tmp_path / "state.json"
    path.write_text("{ this is not json")
    assert m.load_state(str(path)) == {}


def test_a_state_file_that_is_not_an_object_is_an_empty_memory(tmp_path):
    path = tmp_path / "state.json"
    path.write_text('["a list, not a mapping"]')
    assert m.load_state(str(path)) == {}


def test_the_state_round_trips_through_a_file(tmp_path):
    path = str(tmp_path / "nested" / "state.json")
    state = {}
    m.remember_removal(state, svc(), debrid(), NOW)
    m.save_state(state, path=path, out=lambda *_: None)
    assert m.load_state(path) == state


def test_an_unwritable_state_file_does_not_abort_the_run(tmp_path, capsys):
    # Reported, never raised. A cleanup that removed items and then died while
    # writing its own bookkeeping is worse than one that forgot them.
    lines = []
    m.save_state({}, path=str(tmp_path), out=lines.append)
    assert any("Could not write the removal memory" in line for line in lines)


def test_a_stale_entry_is_pruned_and_a_fresh_one_is_kept():
    old = (NOW - timedelta(days=m.STATE_RETENTION_DAYS + 1)).isoformat()
    state = {"old": {"last": old}, "new": {"last": NOW.isoformat()}}
    assert set(m.prune_state(state, NOW)) == {"new"}


def test_an_entry_with_an_unreadable_timestamp_is_pruned():
    # Otherwise it can never age out, and the file grows without bound.
    assert m.prune_state({"x": {"last": "not a date"}}, NOW) == {}
    assert m.prune_state({"x": {}}, NOW) == {}


def test_the_state_path_sits_beside_the_log_it_is_gitignored_with():
    # Three dirnames from scripts/lib/, not two: two lands in scripts/, which
    # nothing else in this stack writes to.
    assert m.STATE_PATH == os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(m.__file__)))), "logs", "queue-cleanup-state.json")


def test_an_applied_run_writes_the_state_and_a_dry_run_does_not(tmp_path):
    path = str(tmp_path / "state.json")

    api = FakeApi([debrid()])
    m.run(m.services("SK", ""), api, False, False, out=lambda *_: None,
          now=NOW, state_path=path)
    assert not os.path.exists(path), "a dry run recorded removals that never happened"

    api = FakeApi([debrid()])
    m.run(m.services("SK", ""), api, True, False, out=lambda *_: None,
          now=NOW, sleep=lambda _: None, state_path=path)
    assert m.load_state(path)["Sonarr|7|Item"]["count"] == 1


def test_a_run_that_removed_nothing_does_not_write_state(tmp_path):
    path = str(tmp_path / "state.json")
    api = FakeApi([rec(added=ago(1))])
    m.run(m.services("SK", ""), api, True, False, out=lambda *_: None,
          now=NOW, state_path=path)
    assert not os.path.exists(path)


def test_the_second_run_over_a_remembered_release_blocklists_it(tmp_path):
    # The livelock, end to end: remove, re-grab, remove again -- and the second
    # removal is the one that stops the indexer offering it a third time.
    path = str(tmp_path / "state.json")
    first = FakeApi([debrid()])
    m.run(m.services("SK", ""), first, True, False, out=lambda *_: None,
          now=NOW, sleep=lambda _: None, state_path=path)
    assert first.deletes == [
        "/api/v3/queue/1?removeFromClient=true&blocklist=false"]

    regrabbed = FakeApi([debrid(id=1)])
    m.run(m.services("SK", ""), regrabbed, True, False, out=lambda *_: None,
          now=NOW, sleep=lambda _: None, state_path=path)
    assert regrabbed.deletes == [
        "/api/v3/queue/1?removeFromClient=true&blocklist=true"]
    assert m.load_state(path)["Sonarr|7|Item"]["count"] == 2


def test_an_expired_removal_is_a_first_strike_again(tmp_path):
    path = tmp_path / "state.json"
    stale_stamp = (NOW - timedelta(days=m.STATE_RETENTION_DAYS + 1)).isoformat()
    path.write_text(json.dumps({"Sonarr|7|Item": {"count": 1,
                                                  "last": stale_stamp}}))
    api = FakeApi([debrid()])
    m.run(m.services("SK", ""), api, True, False, out=lambda *_: None,
          now=NOW, sleep=lambda _: None, state_path=str(path))
    assert api.deletes == [
        "/api/v3/queue/1?removeFromClient=true&blocklist=false"]


def test_a_dry_run_over_a_remembered_release_leaves_the_memory_alone(tmp_path):
    # The memory has to describe what was actually removed. A dry run that
    # recorded its intentions would blocklist a release on a removal it
    # survived.
    path = tmp_path / "state.json"
    path.write_text(json.dumps({"Sonarr|7|Item": {"count": 1,
                                                  "last": NOW.isoformat()}}))
    before = path.read_text()
    api = FakeApi([debrid()])
    m.run(m.services("SK", ""), api, False, False, out=lambda *_: None,
          now=NOW, state_path=str(path))
    assert path.read_text() == before
