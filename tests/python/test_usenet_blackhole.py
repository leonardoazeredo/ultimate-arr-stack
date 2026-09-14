"""Behavioural tests for scripts/lib/usenet_blackhole.py.

This module replaces SABnzbd's usenet path, so the tests here guard the three
things that would make it worse than what it replaced:

  * **a double submit.** The state file is what stops a restart asking TorBox to
    download the same release twice; the arr would then see two folders for one
    episode, and one of them would be imported as a duplicate.
  * **a silently stuck release.** A blackhole client reports no queue to the
    arr -- it only sees what appears in the watch folder -- so a job that never
    completes is invisible. Every failure path has to leave a record.
  * **a half-written release reaching the watch folder.** The arr imports a
    directory once nothing inside it is locked, so anything that appears early
    is imported early. That applies to a partially extracted zip and equally to
    a staging directory parked inside the watch folder, which the arr reports
    as a finished download.

The arr-side contract these tests encode was read from Sonarr's source:
`ScanWatchFolder.cs` imports an immediate SUBDIRECTORY of the watch folder once
nothing inside it is locked, `DiskProviderBase.GetDirectories` skips only
`FileAttributes.System` (not dot-directories), and `DiskScanService.FilterPaths`
matches dot-segments with a regex needing a trailing separator that
`PathExtensions.GetRelativePath` has already trimmed off. `fetch` therefore
stages outside the watch folder and renames into it at the end, and that is
asserted below.
"""

import json
import os
import zipfile
from datetime import datetime, timedelta, timezone

import pytest

import usenet_blackhole as m

NOW = datetime(2026, 9, 14, 12, 0, 0, tzinfo=timezone.utc)

# A minimal but complete NZB. The arr validates what it grabs before writing it
# here, so anything it writes parses; `pending_nzbs` now insists on that too.
VALID_NZB = (
    b'<?xml version="1.0" encoding="utf-8"?>\n'
    b'<nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">'
    b'<file subject="Some.Release-GRP" date="1" parts="1">'
    b'<segments><segment bytes="1000" number="1">abc@example.invalid</segment>'
    b"</segments></file></nzb>"
)

# The same document as the arr writes it: one `stream.Write`, so a reader that
# arrives mid-write sees a prefix of this and nothing else.
TRUNCATED_NZB = VALID_NZB[: len(VALID_NZB) // 2]


class FakeTorBox:
    """Records calls; returns canned state. Never touches the network."""

    def __init__(self, submitted=None, list_result=None, zip_link="https://example.invalid/p.zip"):
        self._submitted = submitted or {}
        self._list = list_result or []
        self._zip_link = zip_link
        self.submits = []
        self.list_calls = 0
        self.zip_requests = []

    def submit_file(self, nzb_path, name):
        self.submits.append((os.path.basename(nzb_path), name))
        return self._submitted.get(name, {"usenetdownload_id": 1, "hash": "h"})

    def list_usenet(self):
        self.list_calls += 1
        return self._list

    def request_zip_link(self, usenet_id):
        self.zip_requests.append(usenet_id)
        return self._zip_link


def write_nzb(directory, name, body=VALID_NZB):
    path = os.path.join(directory, name)
    with open(path, "wb") as handle:
        handle.write(body)
    return path


def job(name="Some.Release-GRP", torbox_id=7, age_hours=0.0):
    when = datetime.now(timezone.utc) - timedelta(hours=age_hours)
    return {"name": name, "torbox_id": torbox_id, "hash": "h",
            "submitted_at": when.isoformat()}


def make_zip(path, members):
    with zipfile.ZipFile(path, "w") as archive:
        for name, data in members.items():
            archive.writestr(name, data)


def serve_zip(monkeypatch, archive):
    """Make the curl call in `fetch` a no-op copy of a prepared zip."""
    def fake_run(argv, **kwargs):
        import shutil
        shutil.copy(str(archive), argv[argv.index("-o") + 1])
        return type("R", (), {"returncode": 0, "stderr": ""})()

    monkeypatch.setattr(m.subprocess, "run", fake_run)


# --- job identity ----------------------------------------------------------

def test_job_key_is_the_content_not_the_path(tmp_path):
    # The arr writes a file named after the release, but a re-grab of the same
    # release can land under a different name. Hashing the bytes is what makes
    # those the same job rather than two downloads.
    a = write_nzb(str(tmp_path), "one.nzb", b"<nzb>same</nzb>")
    b = write_nzb(str(tmp_path), "two.nzb", b"<nzb>same</nzb>")
    assert m.job_key(a) == m.job_key(b)


def test_different_nzbs_have_different_keys(tmp_path):
    a = write_nzb(str(tmp_path), "one.nzb", b"<nzb>a</nzb>")
    b = write_nzb(str(tmp_path), "two.nzb", b"<nzb>b</nzb>")
    assert m.job_key(a) != m.job_key(b)


def test_a_vanished_nzb_is_skipped_not_fatal(tmp_path):
    # The arr can delete a file between the listing and this call; that must not
    # take down a pass that has other releases to handle.
    assert m.job_key(str(tmp_path / "gone.nzb")) is None


# --- what counts as an NZB -------------------------------------------------

def test_a_complete_nzb_is_accepted(tmp_path):
    assert m.is_complete_nzb(write_nzb(str(tmp_path), "a.nzb"))


def test_a_partially_written_nzb_is_refused(tmp_path):
    # The window is small -- the arr writes the document in one call -- but the
    # cost of hitting it is not: TorBox would download whatever segments the
    # prefix still describes, and the arr would import that as the release.
    assert not m.is_complete_nzb(write_nzb(str(tmp_path), "half.nzb", TRUNCATED_NZB))


def test_an_nzb_with_no_files_in_it_is_refused(tmp_path):
    # Well-formed XML that describes nothing downloads nothing.
    assert not m.is_complete_nzb(
        write_nzb(str(tmp_path), "empty.nzb", b'<nzb xmlns="x"></nzb>')
    )


def test_something_that_is_not_an_nzb_at_all_is_refused(tmp_path):
    assert not m.is_complete_nzb(
        write_nzb(str(tmp_path), "other.nzb", b"<html>not an nzb</html>")
    )


def test_an_unreadable_nzb_is_refused_not_fatal(tmp_path):
    assert not m.is_complete_nzb(str(tmp_path / "gone.nzb"))


# --- pending_nzbs ----------------------------------------------------------

def test_only_nzb_files_are_picked_up(tmp_path):
    write_nzb(str(tmp_path), "a.nzb")
    write_nzb(str(tmp_path), "b.txt")
    write_nzb(str(tmp_path), "c.nzb")
    os.makedirs(os.path.join(str(tmp_path), "subdir.nzb"), exist_ok=True)
    names = [n for _, n, _ in m.pending_nzbs(str(tmp_path), {"jobs": {}})]
    assert names == ["a.nzb", "c.nzb"]


def test_a_half_written_nzb_is_left_for_the_next_pass(tmp_path):
    # Not submitted and not forgotten: it is simply not in this pass's list, so
    # the next one picks it up once the write has finished. Recording a failure
    # here would be wrong -- nothing has failed.
    write_nzb(str(tmp_path), "half.nzb", TRUNCATED_NZB)
    assert m.pending_nzbs(str(tmp_path), {"jobs": {}}) == []


def test_an_in_flight_nzb_is_not_returned_again(tmp_path):
    # The double-submit guard.
    path = write_nzb(str(tmp_path), "a.nzb")
    key = m.job_key(path)
    assert m.pending_nzbs(str(tmp_path), {"jobs": {key: job()}}) == []


def test_a_missing_nzb_folder_is_empty_not_an_error(tmp_path):
    # The arr creates its folder; on a fresh boot the watcher may run first.
    assert m.pending_nzbs(str(tmp_path / "nope"), {"jobs": {}}) == []


# --- submit ----------------------------------------------------------------

def test_submit_records_the_job_so_it_is_not_sent_twice(tmp_path):
    write_nzb(str(tmp_path), "Some.Release-GRP.nzb")
    state = {"jobs": {}}
    api = FakeTorBox(submitted={"Some.Release-GRP": {"usenetdownload_id": 42, "hash": "abc"}})
    assert m.submit(api, str(tmp_path), state) == 1
    assert len(state["jobs"]) == 1
    entry = next(iter(state["jobs"].values()))
    assert entry["torbox_id"] == 42
    assert entry["name"] == "Some.Release-GRP"
    # ...and a second pass sends nothing.
    assert m.submit(api, str(tmp_path), state) == 0
    assert len(api.submits) == 1


def test_submit_strips_the_nzb_extension_to_get_the_release_name(tmp_path):
    # The arr names the file after the release and appends .nzb; the release
    # name is what the watch folder must be called for the import to match.
    write_nzb(str(tmp_path), "Show.S01E02.1080p-GRP.nzb")
    api = FakeTorBox()
    m.submit(api, str(tmp_path), {"jobs": {}})
    assert api.submits == [("Show.S01E02.1080p-GRP.nzb", "Show.S01E02.1080p-GRP")]


def test_a_submit_failure_leaves_no_state_entry(tmp_path):
    # Recording a job that was never accepted would strand it for the timeout
    # window and then log a timeout for something TorBox never saw.
    class Refusing(FakeTorBox):
        def submit_file(self, nzb_path, name):
            raise m.TorBoxError("refused")

    write_nzb(str(tmp_path), "x.nzb")
    state = {"jobs": {}}
    assert m.submit(Refusing(), str(tmp_path), state) == 0
    assert state["jobs"] == {}


# --- poll ------------------------------------------------------------------

def test_a_completed_job_is_reported_complete():
    state = {"jobs": {"k": job(torbox_id=7)}}
    api = FakeTorBox(list_result=[{"id": 7, "download_state": "completed"}])
    assert [s for _, _, s in m.poll(api, state, 24, "/dev/null")] == ["complete"]


def test_a_failed_job_is_logged_and_dropped(tmp_path):
    # The only record the operator gets: a blackhole failure is otherwise
    # invisible, because the arr sees nothing at all.
    log = str(tmp_path / "failed.log")
    state = {"jobs": {"k": job(name="Doomed-GRP")}}
    api = FakeTorBox(list_result=[{"id": 7, "download_state": "failed"}])
    statuses = [s for _, _, s in m.poll(api, state, 24, log)]
    assert statuses == ["failed"]
    assert state["jobs"] == {}
    assert "Doomed-GRP" in open(log).read()


def test_a_job_still_downloading_is_left_alone():
    state = {"jobs": {"k": job(torbox_id=7)}}
    api = FakeTorBox(list_result=[{"id": 7, "download_state": "downloading"}])
    assert [s for _, _, s in m.poll(api, state, 24, "/dev/null")] == ["in_progress"]
    assert "k" in state["jobs"]


def test_a_job_missing_from_the_list_is_not_treated_as_failed():
    # The list is paginated and cached; a transient empty answer must not fail
    # every live job at once.
    state = {"jobs": {"k": job(torbox_id=999)}}
    api = FakeTorBox(list_result=[{"id": 7, "download_state": "downloading"}])
    assert [s for _, _, s in m.poll(api, state, 24, "/dev/null")] == ["unknown"]
    assert "k" in state["jobs"]


def test_a_job_past_its_timeout_is_logged_and_dropped(tmp_path):
    log = str(tmp_path / "failed.log")
    state = {"jobs": {"k": job(name="Stuck-GRP", torbox_id=7, age_hours=30)}}
    api = FakeTorBox(list_result=[{"id": 7, "download_state": "downloading"}])
    assert [s for _, _, s in m.poll(api, state, 24, log)] == ["timeout"]
    assert state["jobs"] == {}
    assert "Stuck-GRP" in open(log).read()


def test_the_state_name_is_matched_case_insensitively():
    # TorBox has returned both cases; a strict match would strand a finished
    # download until the timeout.
    state = {"jobs": {"k": job(torbox_id=7)}}
    api = FakeTorBox(list_result=[{"id": 7, "download_state": "Completed"}])
    assert [s for _, _, s in m.poll(api, state, 24, "/dev/null")] == ["complete"]


def test_an_unwritable_failure_log_does_not_crash_the_pass(tmp_path):
    # Logging a failure must never become one -- the other jobs still need
    # polling.
    state = {"jobs": {"k": job(torbox_id=7)}}
    api = FakeTorBox(list_result=[{"id": 7, "download_state": "failed"}])
    statuses = [s for _, _, s in m.poll(api, state, 24, str(tmp_path / "no" / "dir" / "f.log"))]
    assert statuses == ["failed"]


# --- fetch -----------------------------------------------------------------

def test_fetch_lands_the_release_as_a_directory_named_after_it(tmp_path, monkeypatch):
    # The arr imports an immediate SUBDIRECTORY and takes the directory name as
    # the title, so both the location and the name matter.
    watch = tmp_path / "watch"
    watch.mkdir()
    staging = tmp_path / "staging"
    archive = tmp_path / "p.zip"
    make_zip(str(archive), {"Some.Release-GRP/episode.mkv": b"video"})
    serve_zip(monkeypatch, archive)

    api = FakeTorBox()
    assert m.fetch(api, "k" * 32, job(name="Some.Release-GRP"), str(watch), str(staging)) is True
    dest = watch / "Some.Release-GRP"
    assert dest.is_dir()
    # The zip's own top-level folder is unwrapped, so the video sits directly
    # under the release directory.
    assert (dest / "episode.mkv").exists()
    assert api.zip_requests == [7]


def test_fetch_writes_nothing_into_the_watch_folder_until_the_end(tmp_path, monkeypatch):
    # The arr scans the watch folder every minute and imports a directory as
    # soon as nothing inside it is locked. Everything has to be assembled
    # elsewhere and moved in whole.
    watch = tmp_path / "watch"
    watch.mkdir()
    staging = tmp_path / "staging"
    archive = tmp_path / "p.zip"
    make_zip(str(archive), {"Rel-GRP/ep.mkv": b"v"})

    seen = []

    def fake_run(argv, **kwargs):
        import shutil
        # Sampled mid-fetch: this is the moment a partial import would happen.
        seen.append(sorted(os.listdir(watch)))
        shutil.copy(str(archive), argv[argv.index("-o") + 1])
        return type("R", (), {"returncode": 0, "stderr": ""})()

    monkeypatch.setattr(m.subprocess, "run", fake_run)
    m.fetch(FakeTorBox(), "a" * 32, job(name="Rel-GRP"), str(watch), str(staging))
    assert seen == [[]]
    assert (watch / "Rel-GRP" / "ep.mkv").exists()


def test_fetch_leaves_no_staging_directory_behind(tmp_path, monkeypatch):
    # A leftover staging directory is invisible to the arr but shows up in
    # disk-usage reports, and a second attempt would collide with it.
    watch = tmp_path / "watch"
    watch.mkdir()
    staging = tmp_path / "staging"
    archive = tmp_path / "p.zip"
    make_zip(str(archive), {"Rel-GRP/ep.mkv": b"v"})
    serve_zip(monkeypatch, archive)

    m.fetch(FakeTorBox(), "a" * 32, job(name="Rel-GRP"), str(watch), str(staging))
    assert list(staging.iterdir()) == []


def test_fetch_is_a_no_op_when_the_release_already_landed(tmp_path):
    watch = tmp_path / "watch"
    (watch / "Rel-GRP").mkdir(parents=True)
    staging = tmp_path / "staging"
    api = FakeTorBox()
    assert m.fetch(api, "k" * 32, job(name="Rel-GRP"), str(watch), str(staging)) is True
    assert api.zip_requests == []  # not downloaded twice


def test_fetch_refuses_a_zip_that_escapes_the_target(tmp_path, monkeypatch):
    # A zip entry of `../../etc/x` would otherwise write outside the staging
    # folder. Refusing is the only safe answer; extracting "carefully" is not a
    # thing.
    watch = tmp_path / "watch"
    watch.mkdir()
    staging = tmp_path / "staging"
    archive = tmp_path / "evil.zip"
    make_zip(str(archive), {"../escaped.mkv": b"x"})
    serve_zip(monkeypatch, archive)

    with pytest.raises(m.TorBoxError):
        m.fetch(FakeTorBox(), "k" * 32, job(name="Evil"), str(watch), str(staging))
    assert not (tmp_path / "escaped.mkv").exists()
    assert not (watch / "Evil").exists()


def test_a_failed_fetch_leaves_the_job_in_flight(tmp_path, monkeypatch):
    # Deleting the job on a failed download would lose the release: the arr was
    # told nothing, so nobody would ever re-grab it. Driven through `run` rather
    # than `fetch`, because staying in the state file is `run`'s job to get
    # right -- and the retry is what makes a transient zip failure survivable.
    nzb_dir = tmp_path / "nzb"
    nzb_dir.mkdir()
    write_nzb(str(nzb_dir), "Rel-GRP.nzb")
    watch = tmp_path / "watch"
    watch.mkdir()
    staging = tmp_path / "staging"
    state_path = str(tmp_path / "state.json")

    api = FakeTorBox(list_result=[{"id": 1, "download_state": "completed"}], zip_link="")
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)

    assert m.run(str(nzb_dir), str(watch), str(staging), state_path,
                 str(tmp_path / "f.log"), "key", apply_changes=True,
                 out=lambda *a: None) == 0
    jobs = m.load_state(state_path)["jobs"]
    assert len(jobs) == 1
    assert next(iter(jobs.values()))["name"] == "Rel-GRP"
    assert not (watch / "Rel-GRP").exists()


# --- stale staging ---------------------------------------------------------

def test_sweep_staging_removes_an_orphan_older_than_the_threshold(tmp_path):
    # An 800 MB half-download nothing is going to claim, sitting somewhere the
    # arr never looks.
    staging = tmp_path / "staging"
    orphan = staging / "deadbeef"
    orphan.mkdir(parents=True)
    (orphan / "part.mkv").write_bytes(b"x")
    old = (NOW - timedelta(hours=2)).timestamp()
    os.utime(orphan, (old, old))

    assert m.sweep_staging(str(staging), set(), now=NOW) == 1
    assert not orphan.exists()


def test_sweep_staging_leaves_a_job_that_is_still_in_flight(tmp_path):
    # A fetch in progress must not be swept out from under itself.
    staging = tmp_path / "staging"
    live = staging / "livekey"
    live.mkdir(parents=True)
    old = (NOW - timedelta(hours=2)).timestamp()
    os.utime(live, (old, old))

    assert m.sweep_staging(str(staging), {"livekey"}, now=NOW) == 0
    assert live.exists()


def test_sweep_staging_leaves_a_recent_staging_directory(tmp_path):
    # Belt and braces on top of `keep`: a directory being written right now has
    # a fresh mtime. Pinned to NOW rather than left at the machine clock -- the
    # threshold is measured against a `now` this test supplies, so a directory
    # dated by the real clock only looks fresh while the real clock happens to
    # be behind it.
    staging = tmp_path / "staging"
    fresh = staging / "freshkey"
    fresh.mkdir(parents=True)
    os.utime(fresh, (NOW.timestamp(), NOW.timestamp()))

    assert m.sweep_staging(str(staging), set(), now=NOW) == 0
    assert fresh.exists()


def test_sweep_staging_on_a_missing_directory_is_a_no_op(tmp_path):
    assert m.sweep_staging(str(tmp_path / "nope"), set(), now=NOW) == 0


# --- state persistence -----------------------------------------------------

def test_state_round_trips(tmp_path):
    path = str(tmp_path / "state.json")
    m.save_state(path, {"jobs": {"k": job()}})
    assert "k" in m.load_state(path)["jobs"]


def test_a_missing_state_file_is_an_empty_queue(tmp_path):
    assert m.load_state(str(tmp_path / "nope.json")) == {"jobs": {}}


def test_malformed_state_does_not_crash_a_pass(tmp_path):
    # A corrupt state file loses the double-submit guard for one pass, which is
    # survivable; refusing to run is not.
    path = tmp_path / "state.json"
    path.write_text("{ not json")
    assert m.load_state(str(path)) == {"jobs": {}}


def test_save_state_is_atomic(tmp_path):
    # The file is the double-submit guard, so a half-written one that read back
    # as empty would re-submit everything.
    path = str(tmp_path / "state.json")
    m.save_state(path, {"jobs": {"k": job()}})
    m.save_state(path, {"jobs": {"k": job(), "j": job(name="two")}})
    assert sorted(json.load(open(path))["jobs"]) == ["j", "k"]
    assert not os.path.exists(path + ".tmp")


def test_an_unwritable_state_file_names_itself_in_the_error(tmp_path):
    # Raising is deliberate -- the next pass would submit every release twice --
    # but the operator reading the timer's log needs to know which path.
    blocked = tmp_path / "blocked"
    blocked.write_text("a file where the logs directory should be")

    with pytest.raises(m.StateError) as caught:
        m.save_state(str(blocked / "state.json"), {"jobs": {}})
    assert "state.json" in str(caught.value)


def test_main_reports_a_state_failure_as_one_line(tmp_path, capsys):
    # An unhandled StateError would print a traceback into the log every two
    # minutes, which buries the one fact that matters: releases may be sent
    # again until this is fixed.
    nzb_dir = tmp_path / "nzb"
    nzb_dir.mkdir()
    watch = tmp_path / "watch"
    watch.mkdir()
    blocked = tmp_path / "blocked"
    blocked.write_text("a file where the logs directory should be")

    rc = m.main([str(nzb_dir), str(watch), str(tmp_path / "staging"),
                 str(blocked / "state.json"), str(tmp_path / "f.log"),
                 "--apply", "--api-key", "k"])
    assert rc == 1
    err = capsys.readouterr().err
    assert "cannot write" in err
    assert "sent again" in err
    assert "Traceback" not in err


# --- the pass --------------------------------------------------------------

def test_a_dry_run_writes_nothing(tmp_path, monkeypatch):
    # The whole point of the default: look before you submit.
    nzb_dir = tmp_path / "nzb"
    nzb_dir.mkdir()
    write_nzb(str(nzb_dir), "Rel-GRP.nzb")
    watch = tmp_path / "watch"
    watch.mkdir()
    staging = tmp_path / "staging"
    state_path = str(tmp_path / "state.json")

    called = []
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: called.append(1))

    m.run(str(nzb_dir), str(watch), str(staging), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=False)
    assert called == []
    assert not os.path.exists(state_path)
    assert not os.path.exists(staging)


def test_a_pass_submits_polls_and_fetches(tmp_path, monkeypatch):
    nzb_dir = tmp_path / "nzb"
    nzb_dir.mkdir()
    write_nzb(str(nzb_dir), "Rel-GRP.nzb")
    watch = tmp_path / "watch"
    watch.mkdir()
    staging = tmp_path / "staging"
    state_path = str(tmp_path / "state.json")
    archive = tmp_path / "p.zip"
    make_zip(str(archive), {"Rel-GRP/ep.mkv": b"v"})
    serve_zip(monkeypatch, archive)

    api = FakeTorBox(list_result=[{"id": 1, "download_state": "completed"}])
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)

    rc = m.run(str(nzb_dir), str(watch), str(staging), state_path,
               str(tmp_path / "f.log"), "key", apply_changes=True,
               out=lambda *a: None)
    assert rc == 0
    assert (watch / "Rel-GRP" / "ep.mkv").exists()
    # Job finished, so the state is empty again and nothing is re-submitted.
    assert m.load_state(state_path)["jobs"] == {}
