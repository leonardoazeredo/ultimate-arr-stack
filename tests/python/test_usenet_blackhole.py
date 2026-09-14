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
import threading
import time
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


def config_output(config):
    """The `output = "..."` destination out of a curl config written to stdin."""
    line = [l for l in config.splitlines() if l.startswith("output = ")][0]
    return line.split('"')[1]


def serve_zip(monkeypatch, archive):
    """Make the curl download in `fetch` a no-op copy of a prepared zip.

    The destination is read out of the curl config on stdin, not off argv: the
    download moved there because TorBox's link carries the account token in its
    own query string.
    """
    def fake_run(argv, **kwargs):
        import shutil
        shutil.copy(str(archive), config_output(kwargs.get("input", "")))
        return type("R", (), {"returncode": 0, "stderr": ""})()

    monkeypatch.setattr(m.subprocess, "run", fake_run)


# --- the HTTP layer --------------------------------------------------------

def fake_curl(monkeypatch, stdout, returncode=0, stderr=""):
    """Stand in for subprocess.run and capture what curl was invoked with."""
    seen = {}

    def run(argv, **kwargs):
        seen["argv"] = argv
        seen["input"] = kwargs.get("input", "")
        return type("R", (), {"returncode": returncode, "stdout": stdout,
                              "stderr": stderr})()

    monkeypatch.setattr(m.subprocess, "run", run)
    return seen


def test_a_2xx_body_comes_back_without_the_status_line(monkeypatch):
    # -w appends the code on its own line; leaving it in the body would break
    # every json.loads downstream.
    fake_curl(monkeypatch, '{"success":true}\n200')
    assert m._run_curl(['url = "http://x"']) == '{"success":true}'


def test_a_multi_line_body_survives(monkeypatch):
    fake_curl(monkeypatch, '{\n  "a": 1\n}\n200')
    assert m._run_curl(['url = "http://x"']) == '{\n  "a": 1\n}'


def test_a_non_2xx_raises_with_the_apis_own_message(monkeypatch):
    # This is the whole reason curl -f is gone. TorBox answered a real 422 with
    # `{"detail":[{"type":"missing","loc":["query","token"],...}]}` and `-f`
    # reduced it to `curl: (22) The requested URL returned error: 422`, which
    # says nothing about what was missing.
    body = ('{"detail":[{"type":"missing","loc":["query","token"],'
            '"msg":"Field required","input":null}]}')
    fake_curl(monkeypatch, body + "\n422")
    with pytest.raises(m.TorBoxError) as caught:
        m._run_curl(['url = "http://x"'])
    assert "422" in str(caught.value)
    assert "token" in str(caught.value)


def test_curl_is_not_invoked_with_f(monkeypatch):
    # `-f` is what discarded the body, so its return is a regression.
    seen = fake_curl(monkeypatch, "{}\n200")
    m._run_curl(['url = "http://x"'])
    assert "-f" not in seen["argv"]


def test_a_failed_curl_still_reports_its_stderr(monkeypatch):
    fake_curl(monkeypatch, "", returncode=6, stderr="Could not resolve host")
    with pytest.raises(m.TorBoxError) as caught:
        m._run_curl(['url = "http://x"'])
    assert "Could not resolve host" in str(caught.value)


def test_request_zip_link_sends_the_token_in_the_query(monkeypatch):
    # The endpoint requires it. With only the Authorization header it answers
    # 422, which is how a working watcher once fetched nothing at all.
    api = m.TorBox("secret-token")
    seen = {}

    def fake_get(path):
        seen["path"] = path
        return {"success": True, "data": "https://store.example/z.zip"}

    monkeypatch.setattr(api, "_get", fake_get)
    assert api.request_zip_link(2449161) == "https://store.example/z.zip"
    assert "token=secret-token" in seen["path"]
    assert "usenet_id=2449161" in seen["path"]
    assert "zip_link=true" in seen["path"]


def test_fetch_keeps_the_download_link_off_argv(tmp_path, monkeypatch):
    # The link TorBox hands back carries the account token in its own query
    # string, so an argv copy would be readable through /proc/<pid>/cmdline.
    watch = tmp_path / "watch"
    watch.mkdir()
    staging = tmp_path / "staging"
    archive = tmp_path / "p.zip"
    make_zip(str(archive), {"Rel-GRP/ep.mkv": b"v"})

    seen = {}

    def fake_run(argv, **kwargs):
        import shutil
        seen["argv"] = argv
        seen["input"] = kwargs.get("input", "")
        shutil.copy(str(archive), config_output(kwargs.get("input", "")))
        return type("R", (), {"returncode": 0, "stderr": ""})()

    monkeypatch.setattr(m.subprocess, "run", fake_run)
    api = FakeTorBox(zip_link="https://store.example/zip/abc?token=SECRET")
    m.fetch(api, "k" * 32, job(name="Rel-GRP"), str(watch), str(staging))

    assert not any("SECRET" in arg for arg in seen["argv"])
    # ...and it did arrive, on stdin, rather than being dropped entirely.
    assert "SECRET" in seen["input"]


# --- RAR unpacking ---------------------------------------------------------

def touch(directory, *names):
    for name in names:
        with open(os.path.join(str(directory), name), "wb") as handle:
            handle.write(b"x")


def test_rar_volume_names_are_recognised():
    for name in ("x.rar", "x.RAR", "x.part03.rar", "x.r00", "x.R99", "x.s00"):
        assert m.is_rar_volume(name), name
    for name in ("x.mkv", "x.nfo", "x.r00.txt", "sample.mkv", "x.rar.txt"):
        assert not m.is_rar_volume(name), name


def test_a_plain_release_is_left_alone(tmp_path):
    # A release posted as loose files must not be touched.
    touch(tmp_path, "release.mkv", "release.nfo")
    assert m.unpack_rar(str(tmp_path)) is False


def test_the_first_volume_is_the_entry_point(tmp_path):
    # `x.rar` opens the set; `x.r00` does it only when there is no `.rar`.
    touch(tmp_path, "x.r00", "x.r01", "x.rar")
    assert os.path.basename(m.find_rar_entry(str(tmp_path))) == "x.rar"
    os.remove(os.path.join(str(tmp_path), "x.rar"))
    assert os.path.basename(m.find_rar_entry(str(tmp_path))) == "x.r00"
    os.remove(os.path.join(str(tmp_path), "x.r00"))
    os.remove(os.path.join(str(tmp_path), "x.r01"))
    assert m.find_rar_entry(str(tmp_path)) is None


def test_part01_wins_over_part02(tmp_path):
    touch(tmp_path, "x.part02.rar", "x.part01.rar")
    assert os.path.basename(m.find_rar_entry(str(tmp_path))) == "x.part01.rar"


def archive_dest(argv):
    """The extraction directory out of an unrar or 7z argv.

    They spell it differently: unrar takes it as the trailing positional and
    uses `-o+` for overwrite, while 7z has no positional at all and writes it
    into `-o<dir>`. Reading `-o+` as a directory named `+` is how this helper
    first broke both of the callers below.
    """
    if os.path.basename(argv[0]).startswith("unrar"):
        return argv[-1]
    for arg in argv:
        if arg.startswith("-o") and len(arg) > 2:
            return arg[2:]
    return argv[-1]


def unpack_stub(monkeypatch, tool="unrar", returncode=0, stderr=""):
    """Pretend to be unrar: write the video, and record the argv."""
    seen = {}
    monkeypatch.setattr(m.shutil, "which", lambda name: "/usr/bin/" + name if name == tool else None)

    def run(argv, **kwargs):
        seen["argv"] = argv
        if returncode == 0:
            with open(os.path.join(archive_dest(argv), "release.mkv"), "wb") as handle:
                handle.write(b"video")
        return type("R", (), {"returncode": returncode, "stdout": "", "stderr": stderr})()

    monkeypatch.setattr(m.subprocess, "run", run)
    return seen


def serve_release(monkeypatch, archive, tool="unrar", returncode=0, stderr=""):
    """One fake for both subprocesses `fetch` runs: curl, then the unpacker.

    Two separate monkeypatches cannot both win -- the second replaces the first,
    and whichever loses takes its half of the fetch with it.
    """
    seen = {}
    monkeypatch.setattr(m.shutil, "which", lambda name: "/usr/bin/" + name if name == tool else None)

    def run(argv, **kwargs):
        seen.setdefault("argv", []).append(argv)
        if argv[0].endswith("curl"):
            import shutil
            shutil.copy(str(archive), config_output(kwargs.get("input", "")))
            return type("R", (), {"returncode": 0, "stdout": "", "stderr": ""})()
        if returncode == 0:
            with open(os.path.join(archive_dest(argv), "release.mkv"), "wb") as handle:
                handle.write(b"video")
        return type("R", (), {"returncode": returncode, "stdout": "", "stderr": stderr})()

    monkeypatch.setattr(m.subprocess, "run", run)
    return seen


def test_unpacking_writes_the_video_and_removes_the_volumes(tmp_path, monkeypatch):
    # What the arr has to end up with: a video, and none of the eighty-odd
    # archive parts. Leftovers count towards the release size the arr reports.
    touch(tmp_path, "x.rar", "x.r00", "x.r01", "x.r99", "x.nfo", "x.sfv")
    seen = unpack_stub(monkeypatch)
    assert m.unpack_rar(str(tmp_path)) is True
    assert (tmp_path / "release.mkv").exists()
    leftovers = sorted(os.listdir(str(tmp_path)))
    # The video and the non-archive extras survive; every volume is gone.
    assert leftovers == ["release.mkv", "x.nfo", "x.sfv"]
    assert seen["argv"][0].endswith("unrar")


def test_unpacking_falls_back_to_7z(tmp_path, monkeypatch):
    # The NAS has both; a host with only p7zip should still work.
    touch(tmp_path, "x.rar")
    seen = unpack_stub(monkeypatch, tool="7z")
    assert m.unpack_rar(str(tmp_path)) is True
    assert seen["argv"][0].endswith("7z")
    assert any(arg.startswith("-o") for arg in seen["argv"])


def test_no_unpacker_is_a_permanent_failure(tmp_path, monkeypatch):
    # Better to fail loudly than to hand the arr a release it will reject as a
    # sample and delete.
    touch(tmp_path, "x.rar")
    monkeypatch.setattr(m.shutil, "which", lambda name: None)
    with pytest.raises(m.PermanentError) as caught:
        m.unpack_rar(str(tmp_path))
    assert "unrar" in str(caught.value)


def test_a_password_protected_set_is_a_permanent_failure(tmp_path, monkeypatch):
    # unrar exits non-zero and prints the reason; that reason is what the
    # operator needs, so it has to survive into the error.
    touch(tmp_path, "x.rar")
    unpack_stub(monkeypatch, returncode=3, stderr="ERROR: Enter password")
    with pytest.raises(m.PermanentError) as caught:
        m.unpack_rar(str(tmp_path))
    assert "Enter password" in str(caught.value)


def test_unpacking_runs_before_the_release_is_renamed(tmp_path, monkeypatch):
    # The whole point: the arr must never see the archive parts. The rename is
    # the moment it becomes visible, so the video has to exist by then.
    watch = tmp_path / "watch"
    watch.mkdir()
    staging = tmp_path / "staging"
    archive = tmp_path / "p.zip"
    make_zip(str(archive), {"Rel-GRP/x.rar": b"part"})
    serve_release(monkeypatch, archive)

    m.fetch(FakeTorBox(), "k" * 32, job(name="Rel-GRP"), str(watch), str(staging))
    released = sorted(os.listdir(str(watch / "Rel-GRP")))
    assert released == ["release.mkv"]


# --- terminal outcomes -----------------------------------------------------

def test_a_successful_fetch_removes_the_nzb(tmp_path, monkeypatch):
    # The arr never cleans its own nzb folder, so a file left there looks like a
    # fresh grab on the next pass -- and the job is no longer in flight to stop
    # it. Measured: a 4.6 GB release downloaded again in full because of this.
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
    m.run(str(nzb_dir), str(watch), str(staging), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lambda *a: None)

    assert os.listdir(str(nzb_dir)) == []
    assert m.load_state(state_path)["jobs"] == {}


def test_a_permanent_failure_drops_the_job_and_the_nzb(tmp_path, monkeypatch):
    # A retry re-downloads the whole release, so an unusable one has to be
    # recorded and let go -- and its NZB with it, or the next pass picks the
    # same release up again.
    nzb_dir = tmp_path / "nzb"
    nzb_dir.mkdir()
    write_nzb(str(nzb_dir), "Rel-GRP.nzb")
    watch = tmp_path / "watch"
    watch.mkdir()
    staging = tmp_path / "staging"
    state_path = str(tmp_path / "state.json")
    failed_log = str(tmp_path / "failed.log")
    archive = tmp_path / "p.zip"
    make_zip(str(archive), {"Rel-GRP/x.rar": b"part"})
    monkeypatch.setattr(m.shutil, "which", lambda name: None)  # no unpacker
    serve_zip(monkeypatch, archive)

    api = FakeTorBox(list_result=[{"id": 1, "download_state": "completed"}])
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)
    m.run(str(nzb_dir), str(watch), str(staging), state_path,
          failed_log, "key", apply_changes=True, out=lambda *a: None)

    assert m.load_state(state_path)["jobs"] == {}
    assert os.listdir(str(nzb_dir)) == []
    assert "Rel-GRP" in open(failed_log).read()
    assert not (watch / "Rel-GRP").exists()


def test_a_timeout_removes_the_nzb_too(tmp_path, monkeypatch):
    nzb_dir = tmp_path / "nzb"
    nzb_dir.mkdir()
    write_nzb(str(nzb_dir), "Rel-GRP.nzb")
    watch = tmp_path / "watch"
    watch.mkdir()
    state_path = tmp_path / "state.json"
    m.save_state(str(state_path), {"jobs": {m.job_key(str(nzb_dir / "Rel-GRP.nzb")):
                                            job(name="Rel-GRP", age_hours=30)}})

    api = FakeTorBox(list_result=[{"id": 7, "download_state": "downloading"}])
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), str(state_path),
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lambda *a: None)

    assert os.listdir(str(nzb_dir)) == []


def test_a_transient_fetch_failure_keeps_the_nzb_for_the_retry(tmp_path, monkeypatch):
    # The opposite of the two above: a network failure must leave both the job
    # and the NZB in place, or the release is lost with nothing logged.
    nzb_dir = tmp_path / "nzb"
    nzb_dir.mkdir()
    write_nzb(str(nzb_dir), "Rel-GRP.nzb")
    watch = tmp_path / "watch"
    watch.mkdir()
    state_path = str(tmp_path / "state.json")

    api = FakeTorBox(list_result=[{"id": 1, "download_state": "completed"}], zip_link="")
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lambda *a: None)

    assert len(m.load_state(state_path)["jobs"]) == 1
    assert os.listdir(str(nzb_dir)) == ["Rel-GRP.nzb"]


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
        shutil.copy(str(archive), config_output(kwargs.get("input", "")))
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


# --- fetching several releases at once -------------------------------------
#
# One at a time was the ceiling on this whole path. A pass that finds five
# finished releases pulled them in series, so the last waited out four full
# downloads and four unpacks. Each fetch is a curl download then an unrar, and
# both are nearly all waiting, so overlapping them costs nothing but disk.

def several_jobs(tmp_path, count):
    """`count` in-flight jobs, each a distinct NZB, all reported completed.

    The bodies have to differ: `job_key` hashes the content, so identical NZBs
    are one job, and a fixture that reused the default body would pass every
    assertion below against a single release.
    """
    nzb_dir = tmp_path / "nzb"
    nzb_dir.mkdir()
    watch = tmp_path / "watch"
    watch.mkdir()
    state_path = str(tmp_path / "state.json")
    jobs, listing = {}, []
    for i in range(count):
        name = "Rel-%d-GRP" % i
        body = VALID_NZB.replace(b"Some.Release-GRP", name.encode())
        path = write_nzb(str(nzb_dir), name + ".nzb", body)
        jobs[m.job_key(path)] = job(name=name, torbox_id=i + 1)
        listing.append({"id": i + 1, "download_state": "completed"})
    m.save_state(state_path, {"jobs": jobs})
    return nzb_dir, watch, state_path, listing


def test_finished_releases_are_fetched_concurrently(tmp_path, monkeypatch):
    # A barrier is what makes this a test of concurrency rather than of
    # wall-clock. Every worker must arrive before any of them leaves, so a
    # serial implementation never starts the second fetch: the barrier times
    # out, the fetches fail, and the jobs are still in flight at the end.
    #
    # Three is written out rather than taken from FETCH_WORKERS on purpose.
    # Sized off the constant, this test shrinks its own fixture when the
    # constant is mutated -- FETCH_WORKERS = 1 makes one job and a one-slot
    # barrier, which releases immediately and passes. That is exactly the
    # regression it exists to catch, and it survived until this was hardcoded.
    nzb_dir, watch, state_path, listing = several_jobs(tmp_path, 3)
    barrier = threading.Barrier(3, timeout=5)
    started = []

    def fake_fetch(torbox, key, job, watch_dir, staging_dir, out=print):
        started.append(job["name"])
        barrier.wait()
        out(f"    fetched: {job['name']}")
        return True

    monkeypatch.setattr(m, "fetch", fake_fetch)
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: FakeTorBox(list_result=listing))
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lambda *a: None)

    assert len(started) == m.FETCH_WORKERS
    assert m.load_state(state_path)["jobs"] == {}


def test_the_fetch_pool_is_bounded(tmp_path, monkeypatch):
    # Unbounded would stack an unrar per completed release on a NAS that is
    # also transcoding, and the arr's importer reads the same disk.
    nzb_dir, watch, state_path, listing = several_jobs(tmp_path, m.FETCH_WORKERS * 2)
    lock = threading.Lock()
    live, peak = 0, 0

    def fake_fetch(torbox, key, job, watch_dir, staging_dir, out=print):
        nonlocal live, peak
        with lock:
            live += 1
            peak = max(peak, live)
        time.sleep(0.05)
        with lock:
            live -= 1
        out(f"    fetched: {job['name']}")
        return True

    monkeypatch.setattr(m, "fetch", fake_fetch)
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: FakeTorBox(list_result=listing))
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lambda *a: None)

    assert peak <= m.FETCH_WORKERS
    assert peak >= 2, "the pool never overlapped anything, so it is not parallel"
    assert m.load_state(state_path)["jobs"] == {}


def test_the_pool_is_not_pinned_to_one_worker():
    # FETCH_WORKERS is the knob; a regression to 1 would restore the serial
    # behaviour the concurrency test above is written to catch.
    assert m.FETCH_WORKERS >= 2


def test_one_releases_output_is_not_interleaved_with_anothers(tmp_path, monkeypatch):
    # Three threads sharing a print stream would put a release's lines inside
    # another's. Each fetch collects its own and the caller prints them whole.
    nzb_dir, watch, state_path, listing = several_jobs(tmp_path, 3)
    lines = []

    def fake_fetch(torbox, key, job, watch_dir, staging_dir, out=print):
        name = job["name"]
        out(f"    unpacked {name}")
        out(f"    fetched: {name}")
        return True

    monkeypatch.setattr(m, "fetch", fake_fetch)
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: FakeTorBox(list_result=listing))
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lines.append)

    body = [l for l in lines if "fetched: Rel-" in l or "unpacked Rel-" in l]
    assert len(body) == 6
    # Each release's two lines must be adjacent, in its own order.
    for i in range(0, len(body), 2):
        first, second = body[i], body[i + 1]
        assert "unpacked" in first and "fetched" in second
        assert first.split()[-1] == second.split()[-1]


def test_a_permanent_failure_in_a_batch_drops_only_that_release(tmp_path, monkeypatch):
    # Under concurrency the three outcomes are decided per future, in the
    # caller. A permanent failure must not take the successful fetches with it,
    # and the transient one must stay in flight to be retried.
    nzb_dir, watch, state_path, listing = several_jobs(tmp_path, 3)
    outcome = {"Rel-0-GRP": True, "Rel-1-GRP": False, "Rel-2-GRP": False}

    def fake_fetch(torbox, key, job, watch_dir, staging_dir, out=print):
        name = job["name"]
        if name == "Rel-1-GRP":
            raise m.PermanentError("no unpacker")
        out(f"    fetched: {name}")
        return outcome[name]

    monkeypatch.setattr(m, "fetch", fake_fetch)
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: FakeTorBox(list_result=listing))
    failed_log = str(tmp_path / "failed.log")
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          failed_log, "key", apply_changes=True, out=lambda *a: None)

    jobs = m.load_state(state_path)["jobs"]
    # Rel-0 delivered and Rel-1 is unusable, so both leave the state file;
    # only the transient one stays, to be retried next pass.
    assert [j["name"] for j in jobs.values()] == ["Rel-2-GRP"]
    assert "no unpacker" in open(failed_log).read()


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
