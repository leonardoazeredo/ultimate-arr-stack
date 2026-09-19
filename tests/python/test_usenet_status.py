"""Behavioural tests for scripts/lib/usenet_status.py.

This module is the only thing in the stack that reads the blackhole's state file
without acting on it, which shapes what is worth asserting here:

  * **it must not raise.** The operator opening this page is already looking at
    something that is wrong -- twelve jobs in flight and nothing arriving, say --
    and a view that dies with a KeyError or a ValueError on the one entry whose
    field is missing is worse than no view, because the failure is silent.
  * **it must not guess.** A missing timestamp is not zero and a missing
    progress is not 0%: an entry this cannot classify says `unknown`, which is
    the honest answer, and the totals count it there rather than under
    `downloading`.
  * **it must not execute a release name.** Release names come from indexers,
    and the HTML page is opened in a browser on a LAN with the arr credentials
    on it. `<script>` in a title has to arrive as characters.

Every test here is pure: no file is written outside tmp_path, no socket is
opened, no clock is read. The module takes `now` for that reason, and a test
whose result depends on when it runs is a test that will one day fail for a
reason nobody can reproduce.
"""

import json
from datetime import datetime, timedelta, timezone

import pytest

import usenet_status as m

NOW = datetime(2026, 9, 15, 22, 0, 0, tzinfo=timezone.utc)


def at(hours_ago):
    """An ISO timestamp `hours_ago` before the fixed NOW."""
    return (NOW - timedelta(hours=hours_ago)).isoformat()


def a_job(**kw):
    """A job as the watcher writes one, with any field overridable.

    The shape is the real one, read off the NAS on 2026-09-15: `last_progress`
    is TorBox's percentage copied verbatim, and `progress_changed_at` is when
    that number last moved rather than when the job was submitted.
    """
    base = {
        "hash": "abc123",
        "name": "the.sopranos.s06e01.1080p.WEB.H264-CHOPiN",
        "torbox_id": 2459178,
        "last_progress": 42,
        "submitted_at": at(2),
        "progress_changed_at": at(0.25),
    }
    base.update(kw)
    return base


def state_with(jobs):
    return {"jobs": jobs}


def only_row(summary):
    assert len(summary["jobs"]) == 1
    return summary["jobs"][0]


# --- the derived status -----------------------------------------------------


def test_a_job_whose_progress_is_still_moving_is_downloading():
    assert m.job_status(a_job(progress_changed_at=at(0.25)), NOW) == "downloading"


def test_a_job_that_stopped_moving_past_the_threshold_is_stalled():
    # The same rule poll() applies -- and the answer to the question this view
    # exists for, because the arr cannot see a stalled blackhole job at all.
    assert m.job_status(a_job(progress_changed_at=at(6)), NOW) == "stalled"


def test_a_job_exactly_on_the_threshold_is_not_stalled_yet():
    # `>` and not `>=`, matching poll()'s own comparison. Two halves of one
    # stack disagreeing about one job at one instant is not worth the symmetry.
    assert m.job_status(a_job(progress_changed_at=at(m.STALL_HOURS)), NOW) == \
        "downloading"


def test_a_job_that_keeps_moving_is_not_stalled_however_old_it_is():
    # A 20-hour-old job that reported progress a minute ago is a large release,
    # not a stuck one: the timeout is the bound for it, not this rule.
    job = a_job(submitted_at=at(20), progress_changed_at=at(0.02))
    assert m.job_status(job, NOW) == "downloading"


def test_the_complete_flag_reads_as_complete():
    assert m.job_status(a_job(complete=True, progress_changed_at=at(30)), NOW) == \
        "complete"


def test_torboxs_own_completed_state_reads_as_complete_without_the_flag():
    # The flag is written by a pass that has seen the state string; a state file
    # read between those two moments carries the string and not yet the flag.
    assert m.job_status(a_job(download_state="completed"), NOW) == "complete"
    assert m.job_status(a_job(download_state="cached"), NOW) == "complete"


def test_a_torbox_failure_is_failed_rather_than_downloading():
    # The reason travels in parentheses, and TorBox never returns a bare
    # "failed" -- matching the exact string is the bug usenet_blackhole.py
    # carries a paragraph about, and this view has to agree with it.
    job = a_job(download_state="failed (Aborted, cannot be completed - "
                              "https://sabnzbd.org/not-complete)")
    assert m.job_status(job, NOW) == "failed"


def test_a_failed_job_is_failed_even_while_its_progress_looks_live():
    # Order matters: the failure is the fact, the progress is the history.
    job = a_job(download_state="failed (Aborted)", progress_changed_at=at(0.01))
    assert m.job_status(job, NOW) == "failed"


def test_a_job_with_no_usable_timestamp_at_all_is_unknown():
    assert m.job_status({"name": "x"}, NOW) == "unknown"
    assert m.job_status({"submitted_at": "yesterday"}, NOW) == "unknown"


def test_an_unparseable_stall_timestamp_falls_back_to_downloading():
    # "No usable timestamp" is not evidence of a stall. usenet_blackhole.py's
    # poll() makes the same choice for the same reason: a schema change must
    # not fail every live job on the first pass after it.
    job = a_job(progress_changed_at="not-a-date")
    assert m.job_status(job, NOW) == "downloading"


def test_every_status_word_has_a_job_that_produces_it():
    # The closed set the renderer keys its CSS classes on, asserted to be
    # exactly the set this can derive: a status added to the list with no
    # branch behind it is otherwise a row that can never appear.
    produced = {
        m.job_status(a_job(complete=True), NOW),
        m.job_status({"download_state": "failed (Aborted)"}, NOW),
        m.job_status({"progress_changed_at": at(10)}, NOW),
        m.job_status({"progress_changed_at": at(1)}, NOW),
        m.job_status({}, NOW),
    }
    assert produced == set(m.STATUSES)


# --- a job that is missing everything ---------------------------------------


def test_a_job_with_only_a_key_degrades_to_unknown_rather_than_raising():
    row = only_row(m.summarize(state_with({"deadbeefcafe": {}}), NOW))
    assert row["key"] == "deadbeefcafe"
    # The key is the only field the file guarantees, so it becomes the label.
    assert row["name"] == "deadbeefcafe"
    assert row["status"] == "unknown"
    assert row["complete"] is False
    assert row["progress_percent"] is None
    assert row["age_hours"] is None
    assert row["stalled_hours"] is None
    assert row["submitted_at"] is None
    assert row["download_state"] is None


def test_a_job_whose_every_field_is_the_wrong_type_never_raises():
    job = {
        "name": 17,
        "last_progress": "not a number",
        "submitted_at": ["2026-09-15"],
        "progress_changed_at": {"at": "x"},
        "complete": "yes",
        "download_state": 9,
        "pause_until": object(),
    }
    row = only_row(m.summarize(state_with({"k": job}), NOW))
    assert row["name"] == "k"
    assert row["status"] == "unknown"
    assert row["progress_percent"] is None
    assert row["complete"] is False


def test_a_job_that_is_not_even_an_object_never_raises():
    # Tolerated, not required: the file is written by another process, and a
    # truncated write is exactly the situation someone opens this page to see.
    row = only_row(m.summarize(state_with({"k": "not a job"}), NOW))
    assert row["status"] == "unknown"
    assert row["name"] == "k"


def test_summarize_tolerates_a_state_that_is_not_an_object_at_all():
    assert m.summarize(None, NOW)["totals"]["jobs"] == 0
    assert m.summarize({"jobs": ["a", "b"]}, NOW)["totals"]["jobs"] == 0
    assert m.summarize({}, NOW)["jobs"] == []


def test_a_nan_progress_is_dropped_rather_than_rendered():
    # json.dumps writes a bare NaN, which json.loads accepts and most other
    # parsers reject -- so a NaN in the state file must not reach the document.
    summary = m.summarize(state_with({"k": a_job(last_progress=float("nan"))}), NOW)
    assert only_row(summary)["progress_percent"] is None
    assert "NaN" not in m.render_json(summary)


def test_a_boolean_progress_is_not_read_as_one_percent():
    # True is an int in Python, and "1%" on a completed-looking row is a small
    # lie that costs nothing to avoid.
    summary = m.summarize(state_with({"k": a_job(last_progress=True)}), NOW)
    assert only_row(summary)["progress_percent"] is None


def test_a_numeric_string_progress_is_read_rather_than_dropped():
    summary = m.summarize(state_with({"k": a_job(last_progress="12.5")}), NOW)
    assert only_row(summary)["progress_percent"] == 12.5


def test_a_naive_now_is_read_as_utc_rather_than_raising():
    summary = m.summarize(state_with({"k": a_job()}), datetime(2026, 9, 15, 22, 0, 0))
    assert only_row(summary)["age_hours"] == 2.0


# --- the other fields, and the totals ---------------------------------------


def test_the_row_carries_the_age_and_the_stall_clock():
    row = only_row(m.summarize(
        state_with({"k": a_job(submitted_at=at(3), progress_changed_at=at(0.5))}),
        NOW,
    ))
    assert row["age_hours"] == 3.0
    assert row["stalled_hours"] == 0.5
    assert row["progress_percent"] == 42.0
    assert row["download_state"] is None


def test_a_job_with_no_name_is_labelled_with_its_key():
    row = only_row(m.summarize(state_with({"abc123": {"name": "   "}}), NOW))
    assert row["name"] == "abc123"


def test_totals_count_what_the_statuses_say():
    jobs = {
        "a": a_job(name="A", complete=True),
        "b": a_job(name="B", download_state="failed (Aborted)"),
        "c": a_job(name="C", progress_changed_at=at(9)),
        "d": a_job(name="D"),
        "e": {},
    }
    assert m.summarize(state_with(jobs), NOW)["totals"] == {
        "jobs": 5,
        "in_flight": 3,
        "complete": 1,
        "stalled": 1,
        "failed": 1,
        "unknown": 1,
    }


def test_a_failed_job_still_in_the_file_is_not_counted_as_in_flight():
    # It is terminal and on its way out; counting it as running would overstate
    # what is spending one of the ten slots.
    totals = m.summarize(state_with({"k": a_job(download_state="error")}), NOW)["totals"]
    assert totals["in_flight"] == 0
    assert totals["failed"] == 1


def test_jobs_are_ordered_by_name_so_two_runs_diff_cleanly():
    jobs = {"z": a_job(name="Zulu"), "a": a_job(name="alpha"), "m": a_job(name="Mike")}
    assert [r["name"] for r in m.summarize(state_with(jobs), NOW)["jobs"]] == \
        ["alpha", "Mike", "Zulu"]


def test_the_summary_carries_the_stall_threshold_it_used():
    # The page says "stalled past 4h"; a run with a different threshold has to
    # say so rather than leave the reader to assume the default.
    summary = m.summarize(state_with({"k": a_job()}), NOW, stall_hours=12.0)
    assert summary["stall_hours"] == 12.0


# --- the state file ---------------------------------------------------------


def test_a_missing_state_file_reads_as_no_jobs(tmp_path):
    assert m.load_state(str(tmp_path / "nope.json")) == {"jobs": {}}


def test_a_corrupt_state_file_reads_as_no_jobs(tmp_path):
    path = tmp_path / "state.json"
    path.write_text('{"jobs": {"a": ')
    assert m.load_state(str(path)) == {"jobs": {}}


def test_a_state_file_that_is_not_an_object_reads_as_no_jobs(tmp_path):
    path = tmp_path / "state.json"
    path.write_text("[1, 2, 3]")
    assert m.load_state(str(path)) == {"jobs": {}}


def test_a_jobs_field_of_the_wrong_type_reads_as_no_jobs(tmp_path):
    path = tmp_path / "state.json"
    path.write_text('{"jobs": ["a"]}')
    assert m.load_state(str(path)) == {"jobs": {}}


def test_a_state_file_that_is_a_directory_reads_as_no_jobs(tmp_path):
    # The path is a --state argument someone typed, so it can be anything.
    assert m.load_state(str(tmp_path)) == {"jobs": {}}


def test_the_whole_view_survives_a_corrupt_state_file(tmp_path):
    path = tmp_path / "state.json"
    path.write_text("{ not json at all")
    summary = m.summarize(m.load_state(str(path)), NOW)
    assert summary["totals"]["jobs"] == 0
    assert "No jobs in the state file" in m.render_html(summary)
    assert json.loads(m.render_json(summary))["jobs"] == []


# --- the failure log --------------------------------------------------------


def test_a_missing_failure_log_is_an_empty_tail(tmp_path):
    assert m.load_failures(str(tmp_path / "nope.log")) == []


def test_an_undecodable_failure_log_is_an_empty_tail(tmp_path):
    path = tmp_path / "failed.log"
    path.write_bytes(b"\xff\xfe\x00 not utf-8 at all\n")
    assert m.load_failures(str(path)) == []


def test_a_failure_line_splits_into_time_name_and_reason(tmp_path):
    path = tmp_path / "failed.log"
    path.write_text("2026-09-15T21:01:04Z\tthe.sopranos.s06e01\tmissing articles\n")
    assert m.load_failures(str(path)) == [{
        "at": "2026-09-15T21:01:04Z",
        "name": "the.sopranos.s06e01",
        "reason": "missing articles",
    }]


def test_the_tail_keeps_the_last_lines_and_drops_the_rest(tmp_path):
    path = tmp_path / "failed.log"
    path.write_text("".join(
        f"2026-09-15T0{i}:00:00Z\tr{i}\tmissing articles\n" for i in range(1, 6)
    ))
    tail = m.load_failures(str(path), limit=2)
    assert [entry["name"] for entry in tail] == ["r4", "r5"]


def test_a_malformed_failure_line_is_kept_as_a_name_rather_than_dropped(tmp_path):
    # The log is the only record a dead release leaves. A line that does not
    # split is still evidence that something died.
    path = tmp_path / "failed.log"
    path.write_text("something went wrong and there are no tabs\n")
    assert m.load_failures(str(path)) == [{
        "at": None,
        "name": "something went wrong and there are no tabs",
        "reason": None,
    }]


def test_blank_lines_in_the_log_are_skipped(tmp_path):
    path = tmp_path / "failed.log"
    path.write_text("\n2026-09-15T21:01:04Z\tr\tmissing articles\n\n")
    assert [entry["name"] for entry in m.load_failures(str(path))] == ["r"]


def test_a_nonpositive_tail_limit_is_empty_rather_than_a_value_error(tmp_path):
    path = tmp_path / "failed.log"
    path.write_text("2026-09-15T21:01:04Z\tr\tmissing articles\n")
    assert m.load_failures(str(path), limit=0) == []


def test_the_failure_tail_rides_in_the_same_structure_the_jobs_do():
    failures = [{"at": "2026-09-15T21:01:04Z", "name": "r", "reason": "missing articles"}]
    summary = m.summarize({"jobs": {}}, NOW, failures=failures)
    assert summary["failures"] == failures
    assert json.loads(m.render_json(summary))["failures"] == failures


def test_a_failure_entry_that_is_not_an_object_is_dropped():
    # load_failures only ever builds dicts; this is the guard for a caller that
    # does not, so the renderers can use .get without checking again.
    summary = m.summarize({"jobs": {}}, NOW, failures=["nonsense", {"name": "r"}])
    assert summary["failures"] == [{"name": "r"}]


# --- the pressure gate's skip record ----------------------------------------
#
# The gate exits before python, so a skipped pass writes neither the state file
# nor the failed log -- the only two files this page otherwise renders. It
# leaves one line per skipped pass in a third file instead, and the page has to
# surface it: the stall clock is derived at render time, so a long stall paints
# every in-flight job `stalled` under a fresh `Generated` timestamp with the
# actual reason appearing nowhere.


def test_a_missing_skip_log_is_no_record(tmp_path):
    # The ordinary case. A file is only ever written when the gate refuses to
    # start a pass, so no file means the last pass ran.
    assert m.load_skips(str(tmp_path / "nope.log")) is None


def test_a_skip_line_carries_the_time_the_reading_and_the_limit(tmp_path):
    path = tmp_path / "skipped.log"
    path.write_text("2026-09-19T04:07:00Z\t95.00\t20\n")
    assert m.load_skips(str(path)) == {
        "passes": 1,
        "at": "2026-09-19T04:07:00Z",
        "avg10": "95.00",
        "limit": "20",
    }


def test_the_skip_record_counts_the_run_and_reads_the_last_line(tmp_path):
    # "N in a row" is the line count, and the reading worth showing is the most
    # recent one -- the run is what makes the page's claim true.
    path = tmp_path / "skipped.log"
    path.write_text("".join(
        f"2026-09-19T0{i}:00:00Z\t{80 + i}.00\t20\n" for i in range(1, 4)
    ))
    record = m.load_skips(str(path))
    assert record["passes"] == 3
    assert record["avg10"] == "83.00"


def test_a_skip_file_with_nothing_readable_still_reports_passes_were_skipped(tmp_path):
    # The gate only writes this file when it refuses to start a pass, so a
    # record that cannot be parsed is still evidence that passes are being
    # skipped. Returning None here would describe a healthy stack during exactly
    # the stall this exists to make visible.
    path = tmp_path / "skipped.log"
    path.write_text("something went wrong and there are no tabs\n")
    record = m.load_skips(str(path))
    assert record["passes"] == 1
    assert record["avg10"] is None and record["limit"] is None


def test_a_skip_file_holding_only_blank_lines_is_no_record(tmp_path):
    path = tmp_path / "skipped.log"
    path.write_text("\n   \n")
    assert m.load_skips(str(path)) is None


def test_an_undecodable_skip_log_is_no_record(tmp_path):
    path = tmp_path / "skipped.log"
    path.write_bytes(b"\xff\xfe\x00 not utf-8 at all\n")
    assert m.load_skips(str(path)) is None


def test_the_skip_record_rides_in_the_same_structure_the_jobs_do():
    record = {"passes": 2, "at": "2026-09-19T04:07:00Z", "avg10": "95.00", "limit": "20"}
    summary = m.summarize({"jobs": {}}, NOW, skipped=record)
    assert summary["skipped"] == record
    assert json.loads(m.render_json(summary))["skipped"] == record


def test_a_record_with_no_usable_count_is_dropped_rather_than_rendered():
    # `passes` is the one field that says a pass was skipped at all, so a
    # renderer handed a garbage one has nothing honest to say.
    for garbage in ("nonsense", {"passes": 0}, {"passes": True},
                    {"passes": "twelve"}, {"passes": None}, None, 7, []):
        assert m._skip_record(garbage) is None
        assert m.summarize({"jobs": {}}, NOW, skipped=garbage)["skipped"] is None


def test_the_page_says_the_last_pass_was_skipped_rather_than_implying_a_fault():
    summary = m.summarize(
        state_with({"k": a_job(progress_changed_at=at(9))}),
        NOW,
        skipped={"passes": 12, "at": "2026-09-19T04:07:00Z",
                 "avg10": "95.00", "limit": "20"},
    )
    page = m.render_html(summary)
    assert "Last pass skipped" in page
    assert "95.00" in page and "20" in page
    assert "12 in a row" in page
    assert "2026-09-19T04:07:00Z" in page
    # The row is still stalled -- nothing has polled it in nine hours -- and the
    # notice is what says that is not on its own evidence of a fault.
    assert 'class="s-stalled"' in page


def test_the_page_says_nothing_about_skips_when_the_last_pass_ran():
    page = m.render_html(m.summarize(state_with({"k": a_job()}), NOW))
    assert "Last pass skipped" not in page
    assert 'class="notice"' not in page


def test_a_hand_edited_skip_record_is_escaped_like_everything_else():
    summary = m.summarize(
        {"jobs": {}}, NOW,
        skipped={"passes": 1, "at": "2026-09-19T04:07:00Z",
                 "avg10": "<script>alert(1)</script>", "limit": "20"},
    )
    page = m.render_html(summary)
    assert "<script>alert(1)</script>" not in page
    assert "&lt;script&gt;" in page


def test_main_reads_the_skip_log_it_is_given(tmp_path, capsys):
    skip = tmp_path / "skipped.log"
    skip.write_text("2026-09-19T04:07:00Z\t95.00\t20\n")
    assert m.main(["usenet_status.py", "json", str(tmp_path / "nope.json"),
                   str(tmp_path / "nope.log"), str(skip)]) == 0
    loaded = json.loads(capsys.readouterr().out)
    assert loaded["skipped"]["passes"] == 1
    assert loaded["sources"]["skipped_log"] == str(skip)


def test_main_reads_no_skip_log_as_no_record(tmp_path, capsys):
    assert m.main(["usenet_status.py", "json", str(tmp_path / "nope.json"),
                   str(tmp_path / "nope.log"), str(tmp_path / "nope-skip.log")]) == 0
    assert json.loads(capsys.readouterr().out)["skipped"] is None


# --- HTML escaping ----------------------------------------------------------


def test_a_release_name_containing_markup_is_escaped_not_executed():
    name = '<script>alert("x") & \'y\'</script>'
    page = m.render_html(m.summarize(state_with({"k": a_job(name=name)}), NOW))
    assert "<script>" not in page
    assert "&lt;script&gt;" in page
    # The text still reads as text: escaped, not deleted.
    assert "alert(&quot;x&quot;)" in page
    assert "&amp;" in page
    assert "&#x27;y&#x27;" in page


def test_every_state_derived_field_is_escaped():
    job = a_job(name="<img src=x onerror=alert(1)>",
                download_state='"><script>bad()</script>')
    page = m.render_html(m.summarize(state_with({"<b>key</b>": job}), NOW))
    assert "<img" not in page
    assert "<b>key</b>" not in page
    assert "&lt;img src=x onerror=alert(1)&gt;" in page
    assert "&lt;script&gt;bad()&lt;/script&gt;" in page


def test_a_key_cannot_break_out_of_the_attribute_it_is_written_into():
    # The key goes into a title="..." attribute, where a quote is the escape
    # that matters rather than an angle bracket.
    key = 'x" onmouseover="alert(1)'
    page = m.render_html(m.summarize(state_with({key: a_job(name="ok")}), NOW))
    assert 'onmouseover="alert(1)"' not in page
    assert "&quot; onmouseover=&quot;alert(1)" in page


def test_a_failure_log_line_is_escaped_too():
    failures = [{"at": "2026-09-15T21:01:04Z",
                 "name": '<script>alert("x")</script>',
                 "reason": "missing & gone"}]
    page = m.render_html(m.summarize({"jobs": {}}, NOW, failures=failures))
    assert "<script>" not in page
    assert "missing &amp; gone" in page


def test_the_page_is_self_contained():
    page = m.render_html(m.summarize(state_with({"k": a_job()}), NOW))
    # One inline stylesheet, and nothing fetched from anywhere. A page that
    # pulled a font or a framework from a CDN would render differently on the
    # NAS's LAN, which is where it is read.
    assert "<style>" in page
    assert "<script" not in page
    assert "http://" not in page and "https://" not in page
    assert "<link" not in page
    assert page.startswith("<!DOCTYPE html>")
    assert page.rstrip().endswith("</html>")


def test_the_page_says_where_it_read_from():
    summary = m.summarize(state_with({"k": a_job()}), NOW)
    summary["sources"] = {"state": "/tmp/state.json", "failed_log": "/tmp/failed.log"}
    page = m.render_html(summary)
    assert "/tmp/state.json" in page
    assert "/tmp/failed.log" in page


def test_the_page_says_so_rather_than_showing_an_empty_table():
    page = m.render_html(m.summarize({"jobs": {}}, NOW))
    assert "No jobs in the state file" in page
    assert "No failures in the log tail" in page


def test_each_status_has_a_colour_rule_in_the_stylesheet():
    # A status with no rule renders as an unstyled badge, which is invisible in
    # a passing run -- so the list and the stylesheet are asserted together.
    for status in m.STATUSES:
        assert f"tr.s-{status} span.badge" in m.PAGE_CSS


def test_both_renderers_are_ascii_so_a_c_locale_cannot_break_the_print():
    # The NAS runs this from a shell whose locale may be C, where printing a
    # release name outside ASCII raises UnicodeEncodeError.
    summary = m.summarize(state_with({"k": a_job(name="Ünïcödé.Reléase-GRP")}), NOW)
    m.render_json(summary).encode("ascii")
    page = m.render_html(summary)
    page.encode("ascii")
    assert "&#2" in page  # the accent survives as a numeric reference


# --- JSON shape -------------------------------------------------------------


def test_the_json_keys_are_sorted_so_two_runs_diff_cleanly():
    text = m.render_json(m.summarize(state_with({"k": a_job()}), NOW))
    assert text == json.dumps(json.loads(text), indent=2, sort_keys=True) + "\n"
    assert text.index('"failures"') < text.index('"generated_at"') \
        < text.index('"jobs"') < text.index('"skipped"') \
        < text.index('"stall_hours"') < text.index('"totals"')


def test_the_json_shape_is_the_documented_one():
    loaded = json.loads(m.render_json(m.summarize(state_with({"k": a_job()}), NOW)))
    assert set(loaded) == {"generated_at", "stall_hours", "totals", "jobs",
                           "failures", "skipped"}
    assert set(loaded["totals"]) == {"jobs", "in_flight", "complete", "stalled",
                                     "failed", "unknown"}
    assert set(loaded["jobs"][0]) == {
        "key", "name", "status", "complete", "progress_percent", "submitted_at",
        "age_hours", "progress_changed_at", "stalled_hours", "download_state",
    }


def test_the_json_carries_the_same_numbers_the_row_shows():
    summary = m.summarize(
        state_with({"k": a_job(last_progress=42.5, submitted_at=at(3),
                               progress_changed_at=at(0.5))}),
        NOW,
    )
    row = json.loads(m.render_json(summary))["jobs"][0]
    assert row["progress_percent"] == 42.5
    assert row["age_hours"] == 3.0
    assert row["stalled_hours"] == 0.5
    assert row["name"] == "the.sopranos.s06e01.1080p.WEB.H264-CHOPiN"


def test_the_json_ends_with_exactly_one_newline():
    text = m.render_json(m.summarize({"jobs": {}}, NOW))
    assert text.endswith("}\n")
    assert not text.endswith("\n\n")


# --- the command line -------------------------------------------------------


def test_main_prints_json_for_a_state_file(tmp_path, capsys):
    path = tmp_path / "state.json"
    path.write_text(json.dumps(state_with({"k": a_job()})))
    assert m.main(["usenet_status.py", "json", str(path),
                   str(tmp_path / "nope.log")]) == 0
    out = capsys.readouterr().out
    assert json.loads(out)["totals"]["jobs"] == 1
    assert json.loads(out)["sources"]["state"] == str(path)


def test_main_prints_html_and_names_the_file_it_read(tmp_path, capsys):
    path = tmp_path / "state.json"
    path.write_text(json.dumps(state_with({"k": a_job()})))
    assert m.main(["usenet_status.py", "html", str(path)]) == 0
    out = capsys.readouterr().out
    assert out.startswith("<!DOCTYPE html>")
    assert str(path) in out


def test_main_shows_an_empty_view_for_a_missing_state_file(tmp_path, capsys):
    # An absent state file and an idle stack are the same fact about the
    # downloads, so this is a page, not an error.
    assert m.main(["usenet_status.py", "html", str(tmp_path / "nope.json"),
                   str(tmp_path / "nope.log")]) == 0
    assert "No jobs in the state file" in capsys.readouterr().out


def test_main_refuses_an_unknown_format_on_stderr(tmp_path, capsys):
    assert m.main(["usenet_status.py", "yaml", str(tmp_path / "state.json")]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "format must be json or html" in captured.err
    assert "'yaml'" in captured.err


def test_main_with_no_format_prints_the_usage_block(capsys):
    assert m.main(["usenet_status.py"]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "Usage:" in captured.err
    assert "usenet_status.py" in captured.err


def test_main_accepts_the_format_in_any_case(tmp_path, capsys):
    assert m.main(["usenet_status.py", "JSON", str(tmp_path / "nope.json"),
                   str(tmp_path / "nope.log")]) == 0
    assert json.loads(capsys.readouterr().out)["totals"]["jobs"] == 0


def test_no_api_key_reaches_the_document(monkeypatch, tmp_path, capsys):
    # This module reads no credential and opens no .env; the guard here is that
    # a key sitting in the environment cannot end up on the page either, since
    # the page is a file people paste into a chat.
    monkeypatch.setenv("TORBOX_API_KEY", "TORBOX-SENTINEL")
    monkeypatch.setenv("SONARR_API_KEY", "SONARR-SENTINEL")
    monkeypatch.setenv("RADARR_API_KEY", "RADARR-SENTINEL")
    path = tmp_path / "state.json"
    path.write_text(json.dumps(state_with({"k": a_job()})))

    assert m.main(["usenet_status.py", "html", str(path), str(tmp_path / "l")]) == 0
    page = capsys.readouterr().out
    assert m.main(["usenet_status.py", "json", str(path), str(tmp_path / "l")]) == 0
    text = capsys.readouterr().out

    for sentinel in ("SENTINEL", "TORBOX_API_KEY", "SONARR_API_KEY", "RADARR_API_KEY"):
        assert sentinel not in page
        assert sentinel not in text


# --- timestamp parsing ------------------------------------------------------


@pytest.mark.parametrize("value", [None, "", "   ", "yesterday", 5, 4.2, {}, [], True])
def test_anything_that_is_not_a_timestamp_is_none(value):
    assert m.parse_time(value) is None


def test_a_trailing_z_timestamp_parses():
    # TorBox's own strings and hand-written state files both use this form, and
    # fromisoformat only learned it in Python 3.11.
    parsed = m.parse_time("2026-09-15T21:01:04Z")
    assert parsed is not None
    assert parsed.utcoffset() == timedelta(0)


def test_a_naive_timestamp_is_read_as_utc():
    assert m.parse_time("2026-09-15T21:01:04").utcoffset() == timedelta(0)


# --- the stall threshold on the command line --------------------------------
#
# The watcher takes --stall-hours and is run on a timer, so its value is not
# always the default. The view derives `stalled` from the same threshold and has
# to be able to hold the watcher's number: a hardcoded 4 here called a job
# stalled at five hours while a `--stall-hours 6` watcher still considered it
# fine.


def test_the_default_stall_threshold_is_the_watchers_four_hours():
    # The number scripts/usenet-blackhole.sh defaults to. If this moved, every
    # page rendered without --stall-hours would disagree with every watcher run
    # without it.
    assert m.STALL_HOURS == 4.0


def test_a_custom_threshold_changes_which_jobs_are_stalled():
    # The finding this closes, at the pure-function level: five hours of no
    # progress is a stall to the default and is not one to a six-hour watcher.
    job = a_job(progress_changed_at=at(5))
    assert m.job_status(job, NOW) == "stalled"
    assert m.job_status(job, NOW, stall_hours=6.0) == "downloading"


def test_main_passes_a_custom_threshold_through_to_the_view(tmp_path, capsys):
    # 100000 hours rather than the watcher's 6: main() reads the real clock
    # while these fixture timestamps are anchored at the fixed NOW, so only a
    # threshold no elapsed time can reach keeps this independent of when it
    # runs. The pure job_status test above is where 6 versus 5 is asserted.
    path = tmp_path / "state.json"
    path.write_text(json.dumps(
        state_with({"k": a_job(progress_changed_at=at(5))})))

    assert m.main(["usenet_status.py", "json", str(path),
                   str(tmp_path / "nope.log"), "--stall-hours", "100000"]) == 0
    view = json.loads(capsys.readouterr().out)
    assert view["stall_hours"] == 100000.0
    assert view["jobs"][0]["status"] == "downloading"
    assert view["totals"]["stalled"] == 0


def test_main_still_stalls_that_job_without_the_flag(tmp_path, capsys):
    path = tmp_path / "state.json"
    path.write_text(json.dumps(
        state_with({"k": a_job(progress_changed_at=at(5))})))

    assert m.main(["usenet_status.py", "json", str(path)]) == 0
    view = json.loads(capsys.readouterr().out)
    assert view["stall_hours"] == 4.0
    # at(5) is five hours before the fixture's NOW, so it is more than four
    # hours in the past whenever this runs: the default rule sees a stall.
    assert view["jobs"][0]["status"] == "stalled"
    assert view["totals"]["stalled"] == 1


def test_the_positional_order_survives_the_flag_in_front(tmp_path, capsys):
    # `usenet_status.py <format> [state-path] [failed-log-path]` is the contract
    # the wrapper and a hand-run rely on, with the skip path appended after it.
    # The flag is pulled out of argv wherever it appears, so it must not become a
    # positional itself -- and a three-argument call must keep naming exactly the
    # files it was given, with the skip path falling back to its default rather
    # than shifting one of them along.
    path = tmp_path / "state.json"
    path.write_text(json.dumps(state_with({"k": a_job()})))
    log = tmp_path / "failed.log"
    log.write_text("2026-09-15T21:00:00Z\tsome.release\twont import\n")

    assert m.main(["usenet_status.py", "--stall-hours=6", "json", str(path),
                   str(log)]) == 0
    view = json.loads(capsys.readouterr().out)
    assert view["sources"] == {
        "state": str(path),
        "failed_log": str(log),
        "skipped_log": m.DEFAULT_SKIP_LOG,
    }
    assert view["failures"][0]["name"] == "some.release"


@pytest.mark.parametrize("value", ["0", "abc", "-1", "1.2.3", "nan", "inf"])
def test_main_refuses_a_stall_threshold_that_is_not_above_zero(
        value, tmp_path, capsys):
    assert m.main(["usenet_status.py", "json", str(tmp_path / "state.json"),
                   str(tmp_path / "l"), "--stall-hours", value]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "greater than 0" in captured.err
    assert repr(value) in captured.err


def test_main_refuses_an_empty_stall_threshold(tmp_path, capsys):
    # The `--stall-hours=` form with nothing after the `=`, which is the shape
    # the wrapper's own empty-value guard exists for.
    assert m.main(["usenet_status.py", "json", str(tmp_path / "state.json"),
                   "--stall-hours="]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "greater than 0" in captured.err


def test_main_refuses_a_trailing_stall_hours_flag(tmp_path, capsys):
    # Left as the last argument, the flag would otherwise be dropped and the
    # default silently used -- the one wrong answer that looks like a good run.
    assert m.main(["usenet_status.py", "json", str(tmp_path / "s.json"),
                   "--stall-hours"]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "--stall-hours needs a number" in captured.err


def test_positive_hours_takes_a_decimal_and_refuses_everything_else():
    assert m.positive_hours("6") == 6.0
    assert m.positive_hours("0.5") == 0.5
    # nan and inf parse as floats and compare false against a job's age, so
    # they read as "no job is ever stalled"; "" and None are not numbers at all.
    for value in ("0", "-1", "abc", "", "nan", "inf", None):
        assert m.positive_hours(value) is None
