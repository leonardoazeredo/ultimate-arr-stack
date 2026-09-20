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

    def __init__(self, submitted=None, list_result=None, zip_link="https://example.invalid/p.zip",
                 delete_error=None):
        self._submitted = submitted or {}
        self._list = list_result or []
        self._zip_link = zip_link
        self._delete_error = delete_error
        self.submits = []
        self.list_calls = 0
        self.zip_requests = []
        self.deletes = []

    def submit_file(self, nzb_path, name):
        self.submits.append((os.path.basename(nzb_path), name))
        return self._submitted.get(name, {"usenetdownload_id": 1, "hash": "h"})

    def list_usenet(self):
        self.list_calls += 1
        return self._list

    def request_zip_link(self, usenet_id):
        self.zip_requests.append(usenet_id)
        return self._zip_link

    def delete_usenet(self, usenet_id):
        self.deletes.append(usenet_id)
        if self._delete_error is not None:
            raise self._delete_error
        return True


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


def test_delete_usenet_posts_the_delete_through_the_curl_config(monkeypatch):
    # controlusenetdownload is the one call that frees a slot, so its shape is
    # load-bearing: a JSON body naming the id and the operation, the key in the
    # Authorization header, and both on stdin rather than in curl's argv.
    api = m.TorBox("secret-token")
    seen = fake_curl(monkeypatch, '{"success":true}\n200')
    assert api.delete_usenet(2449161) is True

    config = seen["input"]
    assert "https://api.torbox.app/v1/api/usenet/controlusenetdownload" in config
    assert 'request = "POST"' in config
    assert 'header = "Authorization: Bearer secret-token"' in config
    # curl's config escaping and JSON's string escaping agree on \" and \\, so
    # the quoted value reads back as the body curl would send.
    line = [l for l in config.splitlines() if l.startswith("data = ")][0]
    assert json.loads(json.loads(line.split(" = ", 1)[1])) == {
        "usenet_id": 2449161, "operation": "delete"}
    assert not any("secret-token" in arg for arg in seen["argv"])


def test_a_refused_delete_raises_the_ordinary_torbox_error(monkeypatch):
    # The caller catches this and carries on, so it has to be a TorBoxError
    # rather than something narrower that the caller would miss.
    api = m.TorBox("k")
    fake_curl(monkeypatch, '{"success":false,'
                           '"detail":"USENET_DOWNLOAD_NOT_FOUND"}\n500')
    with pytest.raises(m.TorBoxError) as caught:
        api.delete_usenet(7)
    assert "USENET_DOWNLOAD_NOT_FOUND" in str(caught.value)


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


def test_a_stall_removes_the_nzb_too(tmp_path, monkeypatch):
    # The whole point of the stall rule. A stalled job is terminal, so its NZB
    # has to leave the outbox with it -- otherwise the very next pass, two
    # minutes later, finds the same file, submits the same dead release and
    # hands it another slot. That is the retry storm this change exists to
    # remove, and leaving "stalled" out of the terminal set reproduces it.
    nzb_dir = tmp_path / "nzb"
    nzb_dir.mkdir()
    write_nzb(str(nzb_dir), "Rel-GRP.nzb")
    watch = tmp_path / "watch"
    watch.mkdir()
    state_path = tmp_path / "state.json"
    stuck_since = datetime.now(timezone.utc) - timedelta(hours=6)
    m.save_state(str(state_path), {"jobs": {m.job_key(str(nzb_dir / "Rel-GRP.nzb")): {
        "name": "Rel-GRP",
        "torbox_id": 7,
        "hash": "h",
        "submitted_at": stuck_since.isoformat(),
        "last_progress": 0.0,
        "progress_changed_at": stuck_since.isoformat(),
    }}})

    api = FakeTorBox(list_result=[{"id": 7, "download_state": "downloading",
                                   "progress": 0.0}])
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), str(state_path),
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lambda *a: None)

    assert os.listdir(str(nzb_dir)) == []
    assert m.load_state(state_path)["jobs"] == {}


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


# --- the 429 backoff -------------------------------------------------------
#
# createusenetdownload is limited to 60 calls an hour, and a pass offers every
# NZB it holds. Retrying a refused one two minutes later spends the next hour's
# budget re-asking a question already answered: measured 2026-09-14, three
# refusals recurring pass after pass with nothing submitted in between, against
# 47 refusals to 37 acceptances overall.

def pending_releases(tmp_path, count):
    """`count` NZBs sitting in the outbox, none of them submitted yet.

    Distinct from `several_jobs`, which marks its releases as already in
    flight. `pending_nzbs` skips anything the state file knows about, so a
    fixture built on that one presents an empty outbox and every assertion
    below would pass against a watcher that never submitted anything.
    """
    nzb_dir = tmp_path / "nzb"
    nzb_dir.mkdir()
    watch = tmp_path / "watch"
    watch.mkdir()
    state_path = str(tmp_path / "state.json")
    for i in range(count):
        name = "Wait-%d-GRP" % i
        write_nzb(str(nzb_dir), name + ".nzb",
                  VALID_NZB.replace(b"Some.Release-GRP", name.encode()))
    m.save_state(state_path, {"jobs": {}})
    return nzb_dir, watch, state_path


def refusing_torbox(count=1, exc=None):
    """A TorBox whose first `count` submissions raise, then succeed."""
    class Refusing(FakeTorBox):
        def __init__(self):
            super().__init__()
            self.calls = 0

        def submit_file(self, nzb_path, name):
            self.calls += 1
            if self.calls <= count:
                raise (exc or m.RateLimited)("HTTP 429: {\"detail\":\"60 per 1 hour\"}")
            return super().submit_file(nzb_path, name)

    return Refusing()


def test_run_curl_raises_rate_limited_on_429(monkeypatch):
    # Its own type, because the answer is not "retry this one" but "stop
    # asking" -- and the caller has to treat the next NZB the same way.
    fake_curl(monkeypatch, '{"detail":"60 per 1 hour"}\n429')
    with pytest.raises(m.RateLimited):
        m._run_curl(['url = "http://x"'])
def test_a_429_is_not_an_ordinary_torbox_error(monkeypatch):
    # The subclass relationship matters both ways: existing handlers keep
    # working, and the new one can catch only the rate limit.
    assert issubclass(m.RateLimited, m.TorBoxError)
    fake_curl(monkeypatch, "{}" + "\n" + "500")
    with pytest.raises(m.TorBoxError) as caught:
        m._run_curl(['url = "http://x"'])
    assert not isinstance(caught.value, m.RateLimited)


def test_a_429_stops_the_pass_instead_of_asking_for_the_next_release(tmp_path, monkeypatch):
    # The whole point. Three NZBs pending, the first refused: one call, not
    # three, because the budget is empty and the other two would be refused
    # identically at the cost of two more calls.
    nzb_dir, watch, state_path = pending_releases(tmp_path, 3)
    api = refusing_torbox(count=1)
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lambda *a: None)

    assert api.calls == 1
    assert m.in_backoff(m.load_state(state_path)) is not None


def test_a_backoff_skips_submitting_entirely(tmp_path, monkeypatch):
    nzb_dir, watch, state_path = pending_releases(tmp_path, 2)
    state = m.load_state(state_path)
    m.note_rate_limit(state)
    m.save_state(state_path, state)

    api = refusing_torbox(count=99)
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lambda *a: None)

    assert api.calls == 0, "a paused pass still asked TorBox to take an upload"
    # ...and the releases are still there for when it lifts.
    assert len(os.listdir(str(nzb_dir))) == 2


def test_the_backoff_survives_into_the_next_pass(tmp_path, monkeypatch):
    # Passes are two minutes apart and each one is a fresh process. A marker
    # held only in memory would be forgotten before it did anything.
    nzb_dir, watch, state_path = pending_releases(tmp_path, 2)
    api = refusing_torbox(count=1)
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)
    for _ in range(3):
        m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
              str(tmp_path / "f.log"), "key", apply_changes=True, out=lambda *a: None)

    assert api.calls == 1


def test_polling_and_fetching_continue_during_a_backoff(tmp_path, monkeypatch):
    # Only submissions pause. A download already in flight still has to be
    # collected, or the backoff would cost more than the rate limit did.
    nzb_dir, watch, state_path, listing = several_jobs(tmp_path, 1)
    state = m.load_state(state_path)
    m.note_rate_limit(state)
    m.save_state(state_path, state)
    archive = tmp_path / "p.zip"
    make_zip(str(archive), {"Rel-0-GRP/ep.mkv": b"v"})
    serve_zip(monkeypatch, archive)
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: FakeTorBox(list_result=listing))

    lines = []
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lines.append)

    assert (watch / "Rel-0-GRP" / "ep.mkv").exists()
    assert any("submissions paused" in line for line in lines)
    assert m.load_state(state_path)["jobs"] == {}


def test_the_backoff_expires_and_submissions_resume(tmp_path, monkeypatch):
    nzb_dir, watch, state_path = pending_releases(tmp_path, 2)
    state = m.load_state(state_path)
    state["rate_limited_until"] = (datetime.now(timezone.utc)
                                   - timedelta(minutes=1)).isoformat()
    m.save_state(state_path, state)

    api = refusing_torbox(count=0)
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lambda *a: None)

    assert api.calls == 2
    # The stale marker is dropped rather than left to be re-read forever.
    assert "rate_limited_until" not in m.load_state(state_path)


def test_a_non_429_failure_does_not_pause_submissions(tmp_path, monkeypatch):
    # ACTIVE_LIMIT and friends are per-release refusals: the next NZB may well
    # be accepted, so stopping the pass would lose work for no reason.
    nzb_dir, watch, state_path = pending_releases(tmp_path, 3)
    api = refusing_torbox(count=1, exc=m.TorBoxError)
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lambda *a: None)

    assert api.calls == 3
    assert m.in_backoff(m.load_state(state_path)) is None


def test_an_unparseable_backoff_does_not_wedge_the_watcher(tmp_path):
    # A malformed field must not stop the unit. The worst case is one more
    # refused call; refusing to run at all is the failure the state file is
    # supposed to survive.
    for bad in ("not a date", None, "", 12345):
        assert m.in_backoff({"rate_limited_until": bad}) is None, bad


def test_a_naive_stored_deadline_does_not_raise():
    # A timestamp with no offset cannot be compared to an aware "now":
    # subtracting one from the other raises TypeError, outside the try that
    # guards parsing. Found by mutating the fixup line and watching nothing go
    # red -- the unparseable-value test above exercises a different branch.
    state = {"rate_limited_until": "2099-01-01T00:00:00"}
    assert m.in_backoff(state, datetime(2026, 9, 14, 12, 0, tzinfo=timezone.utc)) is not None


def test_the_backoff_is_measured_from_now_not_from_the_stored_value():
    state = {}
    m.note_rate_limit(state, datetime(2026, 9, 14, 12, 0, tzinfo=timezone.utc))
    assert m.in_backoff(state, datetime(2026, 9, 14, 12, 30, tzinfo=timezone.utc))
    assert not m.in_backoff(state, datetime(2026, 9, 14, 13, 1, tzinfo=timezone.utc))


# --- the ten active download slots ----------------------------------------
#
# The other half of the 429 problem. TorBox allows ten concurrent usenet
# downloads and refuses the eleventh under an HTTP 500 -- the same status as
# UNKNOWN_ERROR and a dozen others -- so the status alone cannot tell "this
# release is bad" from "there is no room for any release".
#
# Measured 2026-09-14: one pass spent 51 refusals this way, each one a call
# against the same 60-an-hour budget.

ACTIVE_LIMIT_BODY = ('{"success":false,"error":"ACTIVE_LIMIT",'
                     '"detail":"You have reached your active download limit of 10.",'
                     '"data":{"active_limit":10,"current_active_downloads":10}}')


def test_an_active_limit_refusal_gets_its_own_type(monkeypatch):
    fake_curl(monkeypatch, ACTIVE_LIMIT_BODY + "\n500")
    with pytest.raises(m.ActiveLimit):
        m._run_curl(['url = "http://x"'])


def test_another_500_stays_an_ordinary_error(monkeypatch):
    # Without this the classifier is just "any 500 stops the pass", which would
    # abandon a batch over one release the provider happened to stumble on.
    fake_curl(monkeypatch, '{"success":false,"error":"UNKNOWN_ERROR"}\n500')
    with pytest.raises(m.TorBoxError) as caught:
        m._run_curl(['url = "http://x"'])
    assert not isinstance(caught.value, m.ActiveLimit)
    assert not isinstance(caught.value, m.RateLimited)


def test_the_error_code_comes_from_the_body_not_the_status():
    for body, expected in (
        (ACTIVE_LIMIT_BODY, "ACTIVE_LIMIT"),
        ('{"error":"DOWNLOAD_SERVER_ERROR"}', "DOWNLOAD_SERVER_ERROR"),
        ("{}", None),
        ("<html>nope</html>", None),
        ("[1,2]", None),
        ("", None),
        (None, None),
        ('{"error":123}', None),
    ):
        assert m.api_error_code(body) == expected, body


def test_an_active_limit_stops_the_pass_instead_of_trying_the_rest(tmp_path, monkeypatch):
    # Three waiting, the first refused for room: one call, not three. Each of
    # the others would be refused identically at the cost of another call.
    nzb_dir, watch, state_path = pending_releases(tmp_path, 3)
    api = refusing_torbox(count=1, exc=m.ActiveLimit)
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lambda *a: None)

    assert api.calls == 1
    # ...and the two that were not offered are still waiting.
    assert len(os.listdir(str(nzb_dir))) == 3


def test_an_active_limit_does_not_pause_the_next_pass(tmp_path, monkeypatch):
    # Unlike a 429. A slot frees on its own, so the next pass has to be free to
    # try -- otherwise the account would sit idle with room available.
    #
    # Every call is refused, not just the first. With `count=1` the second
    # attempt would succeed, and a pass that wrongly continued past the
    # refusal would still total three calls over three passes -- which is how
    # the mutation that removed the break survived this test until it did.
    nzb_dir, watch, state_path = pending_releases(tmp_path, 2)
    api = refusing_torbox(count=99, exc=m.ActiveLimit)
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)
    for _ in range(3):
        m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
              str(tmp_path / "f.log"), "key", apply_changes=True, out=lambda *a: None)

    assert m.in_backoff(m.load_state(state_path)) is None
    assert api.calls == 3, "one probe per pass, and no more"
    assert m.load_state(state_path)["jobs"] == {}


def test_an_active_limit_says_so_in_the_log(tmp_path, monkeypatch):
    # The line has to distinguish this from a per-release failure, because the
    # operator's next move is different: wait, rather than look at the release.
    nzb_dir, watch, state_path = pending_releases(tmp_path, 2)
    api = refusing_torbox(count=1, exc=m.ActiveLimit)
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)
    lines = []
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lines.append)

    assert any("no free slots" in line for line in lines)


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


# --- the in-flight ceiling --------------------------------------------------
#
# TorBox's ten slots are a limit, not a target. Measured over the retained
# window: nine of the ten were held by jobs 3-21h old while only 4 of 50
# submissions were ever fetched, so the operator needs a ceiling below ten to
# find out whether fewer concurrent jobs complete more of themselves. It ships
# off -- 0 is no ceiling -- and the value the measurement lands on is 6 against
# 10, not a constant written here.

def test_the_in_flight_cap_stops_the_pass_at_the_ceiling(tmp_path):
    # One job already in flight, a ceiling of two, three waiting: exactly one
    # more is offered. That the release submitted earlier in the same pass is
    # what reaches the ceiling is the point -- state["jobs"] is read on every
    # iteration, not snapshotted before the loop.
    nzb_dir, _watch, state_path = pending_releases(tmp_path, 3)
    state = m.load_state(state_path)
    state["jobs"]["existing"] = job(name="Existing-GRP", torbox_id=1)
    api = FakeTorBox()
    lines = []

    assert m.submit(api, str(nzb_dir), state, out=lines.append,
                    max_inflight=2) == 1

    assert len(api.submits) == 1
    assert len(state["jobs"]) == 2
    assert any("in-flight cap reached (2/2), stopping this pass" in line
               for line in lines)


def test_a_pass_already_at_the_cap_offers_nothing(tmp_path):
    # The ceiling is checked before `submit_file`, not after. Every create is a
    # call against the 60-an-hour budget, so the check's position is the whole
    # value of it: zero calls here, rather than one paid for to be told what
    # len(state["jobs"]) already said.
    nzb_dir, _watch, state_path = pending_releases(tmp_path, 2)
    state = m.load_state(state_path)
    state["jobs"]["a"] = job(name="A-GRP", torbox_id=1)
    state["jobs"]["b"] = job(name="B-GRP", torbox_id=2)
    api = FakeTorBox()

    assert m.submit(api, str(nzb_dir), state, max_inflight=2) == 0

    assert api.submits == []
    assert len(state["jobs"]) == 2


def test_a_zero_cap_submits_everything_as_before(tmp_path):
    # 0 is the off switch, and off has to mean exactly the old behaviour: every
    # waiting NZB offered, in name order, with no ceiling anywhere in the path.
    nzb_dir, _watch, state_path = pending_releases(tmp_path, 3)
    state = m.load_state(state_path)
    api = FakeTorBox()

    assert m.submit(api, str(nzb_dir), state, max_inflight=0) == 3

    assert len(api.submits) == 3
    assert len(state["jobs"]) == 3


def test_the_in_flight_cap_reaches_submit_through_the_pass(tmp_path, monkeypatch):
    # End to end through run(). A ceiling that reaches submit() in a test but
    # is never threaded through run() from argparse leaves the flag inert, and
    # every other test here passes because they call submit() directly.
    nzb_dir, watch, state_path = pending_releases(tmp_path, 3)
    api = FakeTorBox()
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)

    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True, max_inflight=2,
          out=lambda *a: None)

    assert len(api.submits) == 2


def test_the_in_flight_cap_is_off_unless_a_flag_says_otherwise(tmp_path, monkeypatch):
    # Default 0 means no ceiling, and the pass has to stay uncapped with ten
    # jobs already in flight: a default of 10 would be a second, hidden limit
    # -- the provider's again, under a flag that exists to go below it, and
    # nothing in the banner or the log would say where it came from.
    nzb_dir, watch, state_path = pending_releases(tmp_path, 1)
    state = m.load_state(state_path)
    for i in range(10):
        state["jobs"]["existing-%d" % i] = job(name="Existing-%d-GRP" % i,
                                               torbox_id=i + 1)
    m.save_state(state_path, state)

    api = FakeTorBox()
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)
    rc = m.main([str(nzb_dir), str(watch), str(tmp_path / "staging"),
                 str(state_path), str(tmp_path / "f.log"),
                 "--apply", "--api-key", "k"])

    assert rc == 0
    assert len(api.submits) == 1


def test_a_negative_in_flight_cap_is_refused_at_the_argument(tmp_path, capsys):
    # `len(state["jobs"]) >= -1` is true before the first offer, so a negative
    # ceiling would stop every pass having submitted nothing while the log said
    # the cap had been reached -- the outbox grows without bound and the reason
    # is a number nobody checked. argparse refuses it before the pass starts.
    with pytest.raises(SystemExit) as caught:
        m.main([str(tmp_path), str(tmp_path), str(tmp_path),
                str(tmp_path / "state.json"), str(tmp_path / "f.log"),
                "--max-inflight", "-1"])
    assert caught.value.code != 0
    assert "must not be negative" in capsys.readouterr().err


def test_a_completed_job_does_not_count_against_the_ceiling(tmp_path):
    # The cap counts jobs holding a TorBox slot, not rows in the state file. A
    # job TorBox reports complete stays in state["jobs"] until its fetch
    # succeeds, and one whose fetch keeps failing is never timed out either --
    # so counting it would spend a place against the ceiling for good, and the
    # pass would submit less and less as finished releases piled up unfetched.
    # One flagged complete, one live, a ceiling of two: exactly one slot left.
    nzb_dir, _watch, state_path = pending_releases(tmp_path, 2)
    state = m.load_state(state_path)
    finished = job(name="Finished-GRP", torbox_id=1)
    finished["complete"] = True
    state["jobs"]["finished"] = finished
    state["jobs"]["live"] = job(name="Live-GRP", torbox_id=2)
    api = FakeTorBox()
    lines = []

    assert m.submit(api, str(nzb_dir), state, out=lines.append,
                    max_inflight=2) == 1

    assert len(api.submits) == 1
    # The log line counts the same way the check does: the live job plus the
    # one just submitted, not the three rows now in the state file.
    assert any("in-flight cap reached (2/2), stopping this pass" in line
               for line in lines)


# --- poll ------------------------------------------------------------------

def test_a_completed_job_is_reported_complete():
    state = {"jobs": {"k": job(torbox_id=7)}}
    api = FakeTorBox(list_result=[{"id": 7, "download_state": "completed"}])
    assert [s for _, _, s in m.poll(api, state, 24, "/dev/null")] == ["complete"]


def test_a_completed_job_is_flagged_so_it_leaves_the_in_flight_count():
    # The flag submit() counts instead of the state row (see the in-flight
    # ceiling tests). Written on the entry rather than only returned in
    # `results`, because the entry is what outlives the poll: run() saves the
    # state after poll and fetch, and a fetch that keeps failing leaves the job
    # in there with nothing else marking it finished.
    state = {"jobs": {"k": job(torbox_id=7)}}
    api = FakeTorBox(list_result=[{"id": 7, "download_state": "completed"}])
    m.poll(api, state, 24, "/dev/null")
    assert state["jobs"]["k"]["complete"] is True


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


def test_a_torbox_failure_with_a_reason_is_still_a_failure():
    # The live string, not a tidy one. TorBox puts the reason in parentheses,
    # so `download_state in {"failed", "error"}` never matched it and fifteen
    # releases sat as "in progress" until the 24-hour timeout -- logged as
    # timeouts, never surfaced to the arr. Found on 2026-09-14 by counting the
    # states on the account: 19 completed, 15 aborted, 1 processing.
    state = {"jobs": {"k": job(name="Doomed-GRP")}}
    api = FakeTorBox(list_result=[{
        "id": 7,
        "download_state": "failed (Aborted, cannot be completed - "
                          "https://sabnzbd.org/not-complete)",
    }])
    assert [s for _, _, s in m.poll(api, state, 24, "/dev/null")] == ["failed"]
    assert state["jobs"] == {}


def test_the_failure_reason_survives_into_the_log(tmp_path):
    # "missing articles" and "the provider broke" both end the job here, and
    # only one of them is worth retrying later. The parenthetical is the whole
    # difference, so it has to reach the log.
    log = str(tmp_path / "failed.log")
    state = {"jobs": {"k": job(name="Doomed-GRP")}}
    api = FakeTorBox(list_result=[{
        "id": 7,
        "download_state": "failed (Aborted, cannot be completed - "
                          "https://sabnzbd.org/not-complete)",
    }])
    m.poll(api, state, 24, log)
    logged = open(log).read()
    # The exact line, and not a prefix of it. Asserting only that
    # "aborted, cannot be completed" appears passes just as well when the whole
    # raw state string is logged -- the parenthetical is in there either way --
    # so the mutation that dropped the extraction survived until this pinned
    # what the line starts with.
    assert "torbox reported: aborted, cannot be completed - " \
           "https://sabnzbd.org/not-complete" in logged
    assert "torbox reported: failed" not in logged


def test_each_failure_prefix_is_recognised():
    for state_name, expected in (
        ("failed", "failed"),
        ("failed (anything)", "anything"),
        ("error", "error"),
        ("error (disk full)", "disk full"),
        ("Failed (Mixed Case)", "mixed case"),
    ):
        assert m.failure_reason(state_name) == expected, state_name


def test_a_non_failure_state_has_no_reason():
    # The negation the prefix rule needs: a substring match anywhere would
    # call "not-failed" a failure, and "processing" must stay in progress.
    for state_name in ("completed", "cached", "processing", "downloading",
                       "queued", "", None, "unfailed (nope)"):
        assert m.failure_reason(state_name) is None, state_name


def test_a_failed_state_before_the_done_states_would_be_wrong():
    # Order matters: DONE is checked first. If that were reversed a state
    # carrying both words would be read as complete and the release kept.
    assert m.failure_reason("completed") is None
    assert m.failure_reason("cached") is None


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


# --- the stall rule ---------------------------------------------------------
#
# Phase 2 item 3 of PLAN-USENET-RECOVERY.md. Measured 2026-09-15: the oldest
# in-flight job was 21.2h old with nothing to show, and --timeout-hours is 24,
# so it held one of the account's ten concurrent slots for the full day before
# anything noticed. `progress` is a numeric field on every record `mylist`
# returns; a value that has not moved for --stall-hours is the signal that it
# never will, and the timeout stays the bound for a release that keeps moving.

STALL_START = NOW - timedelta(hours=9)


def job_with_progress(name="Stuck-GRP", submitted_at=STALL_START, torbox_id=7,
                      last_progress=None, changed_at=None):
    """A state entry shaped the way submit() writes one."""
    return {
        "name": name,
        "torbox_id": torbox_id,
        "hash": "h",
        "submitted_at": submitted_at.isoformat(),
        "last_progress": last_progress,
        "progress_changed_at": (changed_at or submitted_at).isoformat(),
    }


def test_submit_starts_the_stall_clock_at_submission(tmp_path):
    # Without these two fields a freshly submitted job has no baseline: the
    # first poll after a restart would have nothing to compare against, and a
    # job could read as stalled from the moment it started.
    nzb_dir = tmp_path / "nzb"
    nzb_dir.mkdir()
    write_nzb(str(nzb_dir), "Rel-GRP.nzb")

    class OneJob:
        def submit_file(self, nzb_path, name):
            return {"usenetdownload_id": 7, "hash": "h"}

    state = {"jobs": {}}
    assert m.submit(OneJob(), str(nzb_dir), state) == 1
    entry = list(state["jobs"].values())[0]
    assert entry["last_progress"] is None
    assert entry["progress_changed_at"] == entry["submitted_at"]


def test_progress_that_has_not_moved_past_stall_hours_is_failed(tmp_path):
    log = str(tmp_path / "failed.log")
    state = {"jobs": {"k": job_with_progress()}}
    api = FakeTorBox(list_result=[{"id": 7, "download_state": "downloading",
                                   "progress": 0.0}])
    # The first poll records the value; there is nothing to compare against yet.
    assert [s for _, _, s in m.poll(api, state, 24, log, now=STALL_START)] == \
        ["in_progress"]
    # Five hours later it has not moved, and the job is going nowhere.
    statuses = [s for _, _, s in m.poll(api, state, 24, log,
                                        now=STALL_START + timedelta(hours=5))]
    assert statuses == ["stalled"]
    assert state["jobs"] == {}
    # The detail carries all three: the value it is stuck at, the state TorBox
    # still reports, and how long it has been there.
    assert "progress stuck at 0.0 in downloading for 5.0h" in open(log).read()


def test_progress_that_keeps_moving_is_never_stalled():
    # The counter-case, and the plan's own stated intent: the 24h bound stays
    # for genuinely large releases that are still moving, so a job whose value
    # changes between polls must survive a gap far longer than --stall-hours.
    state = {"jobs": {"k": job_with_progress()}}
    for hours, value in ((0, 0.10), (5, 0.35), (9, 0.60)):
        api = FakeTorBox(list_result=[{"id": 7, "download_state": "downloading",
                                       "progress": value}])
        assert [s for _, _, s in
                m.poll(api, state, 24, "/dev/null",
                       now=STALL_START + timedelta(hours=hours))] == ["in_progress"]
    assert "k" in state["jobs"]


def test_a_job_that_has_not_stalled_long_enough_stays_in_progress():
    # Four hours is the default, not "any quiet poll". One pass is two minutes,
    # so a rule that fired on the first unchanged value would fail every job on
    # its second pass.
    state = {"jobs": {"k": job_with_progress()}}
    api = FakeTorBox(list_result=[{"id": 7, "download_state": "downloading",
                                   "progress": 0.0}])
    m.poll(api, state, 24, "/dev/null", now=STALL_START)
    assert [s for _, _, s in m.poll(api, state, 24, "/dev/null",
                                    now=STALL_START + timedelta(hours=2))] == \
        ["in_progress"]
    assert "k" in state["jobs"]


def test_a_record_with_no_progress_field_is_not_read_as_unchanged(tmp_path):
    # A missing field is not "0% forever". A schema change or an older record
    # would otherwise fail every live job at once -- the same trap the
    # paginated-list handling avoids. Skip the stall check, and let the timeout
    # stay the only bound.
    log = str(tmp_path / "failed.log")
    state = {"jobs": {"k": job_with_progress()}}
    api = FakeTorBox(list_result=[{"id": 7, "download_state": "downloading"}])
    assert [s for _, _, s in m.poll(api, state, 24, log, now=STALL_START)] == \
        ["in_progress"]
    assert [s for _, _, s in
            m.poll(api, state, 24, log,
                   now=STALL_START + timedelta(hours=5))] == ["in_progress"]
    assert "k" in state["jobs"]
    assert not os.path.exists(log)


def test_the_stall_bound_comes_from_the_caller():
    # --stall-hours is the whole point of the flag; a hardcoded four would make
    # the argument a decoration.
    state = {"jobs": {"k": job_with_progress()}}
    api = FakeTorBox(list_result=[{"id": 7, "download_state": "downloading",
                                   "progress": 0.0}])
    m.poll(api, state, 24, "/dev/null", now=STALL_START, stall_hours=1.0)
    assert [s for _, _, s in
            m.poll(api, state, 24, "/dev/null",
                   now=STALL_START + timedelta(hours=2),
                   stall_hours=1.0)] == ["stalled"]


# --- freeing the slot at TorBox --------------------------------------------
#
# A stalled or timed-out job is terminal here but still ACTIVE there, so it goes
# on holding one of the account's ten concurrent slots until something deletes
# it. `controlusenetdownload` with `operation: "delete"` is the only thing that
# frees the slot -- dropping the job from the state file just stops watching it
# being spent, which is the opposite of what the stall rule's docstring claims
# it does.

def test_a_stalled_job_is_deleted_at_torbox(tmp_path):
    log = str(tmp_path / "failed.log")
    state = {"jobs": {"k": job_with_progress(name="Stuck-GRP", torbox_id=7)}}
    api = FakeTorBox(list_result=[{"id": 7, "download_state": "downloading",
                                   "progress": 0.0}])
    # The first poll only records the value; there is nothing to compare to yet.
    m.poll(api, state, 24, log, now=STALL_START)
    statuses = [s for _, _, s in m.poll(api, state, 24, log,
                                        now=STALL_START + timedelta(hours=5))]

    assert statuses == ["stalled"]
    assert api.deletes == [7]
    assert state["jobs"] == {}


def test_a_timed_out_job_is_deleted_at_torbox(tmp_path):
    # The other branch where the job is still running. The watcher has given up
    # after --timeout-hours but TorBox has not stopped, so the slot stays spent
    # until the download is deleted.
    log = str(tmp_path / "failed.log")
    state = {"jobs": {"k": job(name="Stuck-GRP", torbox_id=7, age_hours=30)}}
    api = FakeTorBox(list_result=[{"id": 7, "download_state": "downloading"}])
    assert [s for _, _, s in m.poll(api, state, 24, log)] == ["timeout"]
    assert api.deletes == [7]
    assert state["jobs"] == {}


def test_a_job_torbox_reports_failed_is_not_deleted(tmp_path):
    # The third terminal branch, and the one that must not be deleted: TorBox
    # has already stopped this job, so it is not holding a slot and the call
    # would buy nothing.
    log = str(tmp_path / "failed.log")
    state = {"jobs": {"k": job(name="Doomed-GRP", torbox_id=7)}}
    api = FakeTorBox(list_result=[{
        "id": 7,
        "download_state": "failed (Aborted, cannot be completed - "
                          "https://sabnzbd.org/not-complete)",
    }])
    assert [s for _, _, s in m.poll(api, state, 24, log)] == ["failed"]
    assert api.deletes == []


def test_a_job_with_no_torbox_id_is_not_deleted():
    # Nothing was ever submitted for it, so there is nothing at TorBox to
    # delete. Reached through the helper because poll() classifies a job with
    # no id as "unknown" long before it gets to a terminal branch.
    api = FakeTorBox()
    assert m.delete_at_torbox(api, {"name": "Rel-GRP"}) is False
    assert api.deletes == []


def test_a_delete_that_raises_is_logged_and_the_pass_carries_on(tmp_path):
    # The delete is bookkeeping, so a TorBox that refuses it must not take the
    # pass with it: the job leaves the state either way, and the job behind it
    # still has to be classified. Same rule a failure report follows.
    log = str(tmp_path / "failed.log")
    state = {"jobs": {
        "stuck": job_with_progress(name="Stuck-GRP", torbox_id=7),
        "live": job_with_progress(name="Live-GRP", torbox_id=8),
    }}
    stuck = {"id": 7, "download_state": "downloading", "progress": 0.0}
    first = FakeTorBox(list_result=[
        stuck, {"id": 8, "download_state": "downloading", "progress": 0.5}])
    m.poll(first, state, 24, log, now=STALL_START)

    lines = []
    second = FakeTorBox(
        list_result=[stuck,
                     {"id": 8, "download_state": "downloading", "progress": 0.9}],
        delete_error=m.TorBoxError("HTTP 500: controlusenetdownload refused"),
    )
    statuses = [s for _, _, s in
                m.poll(second, state, 24, log, now=STALL_START + timedelta(hours=5),
                       out=lines.append)]

    assert statuses == ["stalled", "in_progress"]
    assert second.deletes == [7]
    assert any("Stuck-GRP: could not delete from TorBox" in line for line in lines)
    assert any("controlusenetdownload refused" in line for line in lines)
    assert "stuck" not in state["jobs"]
    assert "live" in state["jobs"]


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
    #
    # What this test still proves is that the fetches overlap at all --
    # `peak >= 2` is the assertion with teeth. The `peak <= FETCH_WORKERS` line
    # is a cheap invariant, not an independent proof of the bound: the slice in
    # `run()` already caps `to_fetch` at FETCH_WORKERS upstream, so the pool can
    # never be handed more than that no matter how wide it is. No fixture size
    # makes an uncapped pool observable here; `usenet-blackhole-fetch-set-
    # unbounded` is what covers the unbounded case.
    #
    # The fixture is one round's worth of jobs, not two. A fixture of
    # FETCH_WORKERS * 2 leaves half of them `complete` in the state file by
    # design and the empty-state assertion below could only pass against the
    # unbounded defect.
    nzb_dir, watch, state_path, listing = several_jobs(tmp_path, m.FETCH_WORKERS)
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


def test_a_dry_run_deletes_nothing_at_torbox(tmp_path, monkeypatch):
    # poll() never runs in dry run -- run() returns before TorBox is even built
    # -- so the delete cannot happen there. Pinned rather than left implicit: a
    # stalled job in the state file is exactly what an operator points a dry run
    # at while deciding whether to keep the stall bound where it is.
    nzb_dir = tmp_path / "nzb"
    nzb_dir.mkdir()
    watch = tmp_path / "watch"
    watch.mkdir()
    state_path = str(tmp_path / "state.json")
    m.save_state(state_path, {"jobs": {
        "k": job_with_progress(name="Stuck-GRP", torbox_id=7)}})

    api = FakeTorBox(list_result=[{"id": 7, "download_state": "downloading",
                                   "progress": 0.0}])
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)

    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=False,
          out=lambda *a: None)

    assert api.deletes == []
    assert api.list_calls == 0
    assert "k" in m.load_state(state_path)["jobs"]


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


def test_main_carries_the_stall_bound_into_the_pass(tmp_path, monkeypatch):
    # End to end through argparse. A flag that reaches the banner and python's
    # argv but is never read back out of `args` would leave --stall-hours inert,
    # and every other test here would still pass.
    nzb_dir = tmp_path / "nzb"
    nzb_dir.mkdir()
    watch = tmp_path / "watch"
    watch.mkdir()
    state_path = tmp_path / "state.json"
    failed_log = tmp_path / "f.log"
    stuck_since = datetime.now(timezone.utc) - timedelta(hours=2)
    m.save_state(str(state_path), {"jobs": {"k": {
        "name": "Stuck-GRP",
        "torbox_id": 7,
        "hash": "h",
        "submitted_at": stuck_since.isoformat(),
        "last_progress": 0.0,
        "progress_changed_at": stuck_since.isoformat(),
    }}})
    api = FakeTorBox(list_result=[{"id": 7, "download_state": "downloading",
                                   "progress": 0.0}])
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: api)

    rc = m.main([str(nzb_dir), str(watch), str(tmp_path / "staging"),
                 str(state_path), str(failed_log), "--apply",
                 "--api-key", "k", "--stall-hours", "1"])

    assert rc == 0
    # The detail, not the word "stalled": the word is the outcome the pass
    # printed, while the log records why -- the value, the state and the hours.
    assert "progress stuck at 0.0 in downloading for 2.0h" in failed_log.read_text()
    assert m.load_state(str(state_path))["jobs"] == {}


def test_a_zero_stall_bound_is_refused_at_the_argument(tmp_path, capsys):
    # Zero is numeric, so nothing before this rejects it -- and it is the one
    # value that makes the stall rule true on the first poll after a job is
    # submitted (`stalled_hours > 0` the moment the clock starts), so one live
    # pass would fail every in-flight job it has. argparse owns the refusal, so
    # the pass never reaches a loop that could act on it.
    with pytest.raises(SystemExit) as caught:
        m.main([str(tmp_path), str(tmp_path), str(tmp_path),
                str(tmp_path / "state.json"), str(tmp_path / "f.log"),
                "--stall-hours", "0"])
    assert caught.value.code != 0
    assert "must be greater than 0" in capsys.readouterr().err


def test_a_negative_stall_bound_is_refused_at_the_argument(tmp_path):
    # The shell half already refuses "-1" as not-a-number, but `--stall-hours=-1`
    # is only reachable through the shell's `=` form and the Python entry point
    # can be called directly. A negative bound fails every job on its first
    # unchanged poll, exactly as zero does.
    with pytest.raises(SystemExit) as caught:
        m.main([str(tmp_path), str(tmp_path), str(tmp_path),
                str(tmp_path / "state.json"), str(tmp_path / "f.log"),
                "--stall-hours=-1"])
    assert caught.value.code != 0


# --- telling the arrs what died ---------------------------------------------
#
# Phase 1 of PLAN-USENET-RECOVERY.md. The measured problem: the arr's queue
# never holds a blackhole item -- 12 in flight, 0 in either queue, and
# `queue-cleanup` reporting "Queue size: 0 items" hourly while 227 failures
# accumulated across 100 distinct releases. So the arr cannot blocklist what it
# cannot see, and the same dead release comes back on the next search.
#
# The risk this section exists to hold down is the opposite one: a wrong match
# reports a DIFFERENT grab as failed, and the arr blocklists a release that was
# fine. Every test below is one of the guards against that.

SONARR = {"name": "Sonarr", "port": 8989, "key": "sk"}
RADARR = {"name": "Radarr", "port": 7878, "key": "rk"}


def grab(history_id, title, date="2026-09-15T06:57:04Z", event_type="grabbed"):
    return {"id": history_id, "eventType": event_type, "sourceTitle": title,
            "date": date}


class FakeArrApi:
    """Records the calls; returns canned history. Never touches the network."""

    def __init__(self, histories=None, post_ok=True):
        # Keyed by port, so a test can make one arr answer and the other not.
        self.histories = histories or {}
        self.post_ok = post_ok
        self.gets = []
        self.posts = []

    def get_json(self, url):
        self.gets.append(url)
        for port, body in self.histories.items():
            if f":{port}/" in url:
                return body
        return None

    def post(self, url):
        self.posts.append(url)
        return self.post_ok


def reporter(api, services=None, ledger=None, now=None, out=None, dry_run=False):
    return m.FailureReporter(api, services or [SONARR, RADARR],
                             ledger=ledger if ledger is not None else {},
                             now=now or NOW, out=out or (lambda *a: None),
                             dry_run=dry_run)


RELEASE = "the.sopranos.s04e08.1080p.bluray.x264-shortbrehd"


def test_an_exact_title_match_resolves_to_the_grab():
    api = FakeArrApi({8989: [grab(11921, RELEASE)]})
    assert reporter(api).resolve(RELEASE) == (SONARR, 11921, RELEASE)


def test_a_release_with_no_grab_in_either_arr_does_not_resolve():
    # The measured case for a title that arrived through the blackhole from
    # somewhere other than an arr grab, and the case for a name that has
    # already aged out of the history window.
    api = FakeArrApi({8989: [grab(1, "some.other.release-GRP")],
                      7878: [grab(2, "yet.another-GRP")]})
    assert reporter(api).resolve(RELEASE) is None
    assert api.posts == []


def test_the_newest_grab_wins_when_a_release_was_grabbed_more_than_once():
    # The normal case here, and the whole reason the resolution takes a max:
    # `the.sopranos.s04e08...` was grabbed three times in 24 hours (history ids
    # 11545, 11763, 11921). Reporting the oldest would mark a grab that has
    # already been superseded, and leave the live one unblocked.
    api = FakeArrApi({8989: [
        grab(11545, RELEASE, "2026-09-14T14:57:17Z"),
        grab(11921, RELEASE, "2026-09-15T06:57:04Z"),
        grab(11763, RELEASE, "2026-09-14T22:55:53Z"),
    ]})
    assert reporter(api).resolve(RELEASE)[1] == 11921


def test_a_near_miss_title_is_not_a_match():
    # The failure mode the dry run exists to catch. `S01E08` and `S01E09` are
    # one character apart, and treating them as equal blocklists the wrong
    # episode of a series that has 3,006 missing episodes to get through.
    api = FakeArrApi({8989: [
        grab(1, "The.Sopranos.S01E09.POLiSH.1080p.WEB.H264-CHOPiN"),
        grab(2, "the.sopranos.s04e08.1080p.bluray.x264-shortbrehd.MKV"),
    ]})
    assert reporter(api).resolve(RELEASE) is None


def test_case_is_not_folded_when_matching():
    # The arr stores the indexer's own release name, and the NZB filename is
    # that name plus `.nzb`. If they ever differ in case, the pair is what the
    # operator reads in the dry run -- not something to paper over here.
    api = FakeArrApi({8989: [grab(1, RELEASE.upper())]})
    assert reporter(api).resolve(RELEASE) is None


def test_the_date_window_is_sent_to_the_arr():
    # A re-release years later carries the same release name, so an unbounded
    # search would happily match last year's grab and fail it. The bound is
    # enforced by the arr; this pins that the parameter is actually sent.
    #
    # Two days, not a week. The gap it has to cover is `--timeout-hours`, 24h,
    # and a week does not work at all: `/api/v3/history/since` over 7 days never
    # returns on this Sonarr (measured 2026-09-17; 2 days answers in 13s, 7 days
    # times out past 90s). Every Sonarr report failed on the read alone while
    # Radarr's smaller history resolved fine.
    api = FakeArrApi({8989: []})
    reporter(api, now=NOW).resolve(RELEASE)
    assert "date=2026-09-12T12:00:00Z" in api.gets[0]


def test_a_failed_grab_record_is_not_a_candidate():
    # Only grabs resolve. A `downloadFailed` row carries the same sourceTitle
    # and would otherwise be re-reported on every pass, forever.
    api = FakeArrApi({8989: [grab(1, RELEASE, event_type="downloadFailed")]})
    assert reporter(api).resolve(RELEASE) is None


def test_an_unreachable_arr_is_logged_and_the_other_one_is_still_tried():
    # A stack running only Sonarr, or a Sonarr that is down, must not stop
    # Radarr being told. `None` is the answer ArrApi gives for both "could not
    # connect" and "answered with something that is not JSON".
    api = FakeArrApi({7878: [grab(216, "X-Men.Days.of.Future.Past.2014.BluRay."
                                        "Remux.1080p.AVC.DTS-HD.MA.7.1-HiFi")]})
    lines = []
    r = reporter(api, out=lines.append)
    match = r.resolve("X-Men.Days.of.Future.Past.2014.BluRay.Remux.1080p.AVC."
                      "DTS-HD.MA.7.1-HiFi")
    assert match == (RADARR, 216, "X-Men.Days.of.Future.Past.2014.BluRay.Remux."
                                   "1080p.AVC.DTS-HD.MA.7.1-HiFi")
    assert any("could not read history" in line for line in lines)


def test_history_is_read_once_per_arr_per_pass():
    # `/history/since` over the 7-day window is thousands of rows behind a 30s
    # curl timeout -- measured ~11,600 rows over three weeks on Sonarr -- and
    # resolve() runs once for every failure in the pass. Several failures in one
    # pass is the ordinary case (227 accumulated across 100 releases in a day),
    # and without the cache each of them paid for the same body again. One
    # reporter is built per pass, so one GET per arr is the bound.
    other = "the.sopranos.s04e09.1080p.bluray.x264-shortbrehd"
    movie = ("X-Men.Days.of.Future.Past.2014.BluRay.Remux.1080p.AVC."
             "DTS-HD.MA.7.1-HiFi")
    api = FakeArrApi({8989: [grab(11921, RELEASE), grab(11922, other)],
                      7878: [grab(216, movie)]})
    r = reporter(api, services=[SONARR, RADARR])
    # Two failures, one owned by each arr -- so both services are consulted and
    # the count below cannot be satisfied by never asking one of them.
    assert [r.report(RELEASE, "torbox"), r.report(movie, "torbox")] == \
        ["reported", "reported"]
    assert sum(1 for url in api.gets if ":8989/" in url) == 1
    assert sum(1 for url in api.gets if ":7878/" in url) == 1


def test_an_unreachable_arr_is_not_retried_within_the_pass():
    # `None` is cached too, and this is why: an arr that is down cannot come
    # back inside one pass, so retrying it per failure turns one dead arr into
    # one connection timeout per dead release -- each of them behind the same
    # 30s curl limit. The log still says so once per release, because each one
    # genuinely went unreported.
    other = "the.sopranos.s04e09.1080p.bluray.x264-shortbrehd"
    api = FakeArrApi({7878: [grab(216, RELEASE), grab(217, other)]})
    lines = []
    r = reporter(api, services=[SONARR, RADARR], out=lines.append)
    assert [r.report(RELEASE, "timeout"), r.report(other, "timeout")] == \
        ["reported", "reported"]
    assert sum(1 for url in api.gets if ":8989/" in url) == 1
    assert len([line for line in lines if "could not read history" in line]) == 2


def test_reporting_posts_the_failure_to_the_matching_arr_only():
    api = FakeArrApi({8989: [grab(11921, RELEASE)]})
    r = reporter(api)
    assert r.report(RELEASE, "torbox", "aborted, cannot be completed") == "reported"
    assert api.posts == ["http://localhost:8989/api/v3/history/failed/11921"
                         "?apikey=sk"]


def test_the_radarr_port_is_used_when_radarr_owns_the_release():
    # Routing, specifically: the two arrs listen on different ports and a
    # report sent to the wrong one 404s.
    title = "X-Men.Days.of.Future.Past.2014.BluRay.Remux.1080p.AVC.DTS-HD.MA.7.1-HiFi"
    api = FakeArrApi({7878: [grab(216, title)]})
    reporter(api).report(title, "torbox", "aborted")
    assert api.posts[0].startswith("http://localhost:7878/api/v3/history/failed/216")


def test_a_reported_grab_is_not_reported_twice():
    # The ledger. Without it, every terminal failure would be re-reported on
    # each subsequent pass -- the arr would take a second blocklist entry for a
    # release it had already blocked, and the log would be unreadable.
    api = FakeArrApi({8989: [grab(11921, RELEASE)]})
    ledger = {}
    r = reporter(api, ledger=ledger)
    assert r.report(RELEASE, "torbox", "aborted") == "reported"
    assert r.report(RELEASE, "torbox", "aborted") == "already"
    assert len(api.posts) == 1
    assert list(ledger) == ["Sonarr:11921:torbox"]


def test_a_refused_report_is_not_remembered():
    # The arr never got the message, so the ledger must not claim it did --
    # otherwise a transient 500 suppresses the report permanently and the
    # release stays unblocked with nothing in the log saying so.
    api = FakeArrApi({8989: [grab(11921, RELEASE)]}, post_ok=False)
    ledger = {}
    r = reporter(api, ledger=ledger)
    assert r.report(RELEASE, "torbox", "aborted") == "failed"
    assert ledger == {}
    assert r.report(RELEASE, "torbox", "aborted") == "failed"
    assert len(api.posts) == 2


def test_a_timeout_and_a_torbox_failure_on_one_grab_are_two_reports():
    # They are different facts about the same grab -- "we gave up waiting" and
    # "the provider said it is dead" -- and collapsing them into one ledger key
    # would silently drop the second.
    api = FakeArrApi({8989: [grab(11921, RELEASE)]})
    ledger = {}
    r = reporter(api, ledger=ledger, now=NOW)
    assert r.report(RELEASE, "timeout", "still downloading after 24.0h") == "reported"
    assert r.report(RELEASE, "torbox", "aborted") == "reported"
    assert len(ledger) == 2


def test_a_stall_and_a_timeout_on_one_grab_are_two_reports():
    # "stalled" is its own kind rather than a timeout under another name. A grab
    # can be reported stalled and later time out for real, and one key would
    # silently drop the second fact -- exactly the argument that already keeps
    # torbox and timeout apart.
    api = FakeArrApi({8989: [grab(11921, RELEASE)]})
    ledger = {}
    r = reporter(api, ledger=ledger, now=NOW)
    assert r.report(RELEASE, "stalled",
                    "progress stuck at 0.0 in downloading for 5.0h") == "reported"
    assert r.report(RELEASE, "timeout", "still downloading after 24.0h") == "reported"
    assert sorted(ledger) == ["Sonarr:11921:stalled", "Sonarr:11921:timeout"]


def test_a_stalled_job_is_reported_with_its_own_kind(tmp_path):
    # The wiring the ledger key depends on: poll() hands the reporter "stalled"
    # as the reason type, not "torbox" or "timeout".
    log = str(tmp_path / "failed.log")
    api = FakeArrApi({8989: [grab(11921, RELEASE)]})
    ledger = {}
    stuck_since = NOW - timedelta(hours=9)
    state = {"jobs": {"k": {
        "name": RELEASE,
        "torbox_id": 7,
        "hash": "h",
        "submitted_at": stuck_since.isoformat(),
        "last_progress": 0.0,
        "progress_changed_at": stuck_since.isoformat(),
    }}}
    torbox = FakeTorBox(list_result=[{"id": 7, "download_state": "downloading",
                                      "progress": 0.0}])
    statuses = [s for _, _, s in
                m.poll(torbox, state, 24, log, now=NOW,
                       report=reporter(api, ledger=ledger))]
    assert statuses == ["stalled"]
    assert list(ledger) == ["Sonarr:11921:stalled"]
    assert api.posts == ["http://localhost:8989/api/v3/history/failed/11921"
                         "?apikey=sk"]
    assert "progress stuck at 0.0 in downloading for 9.0h" in open(log).read()


def test_a_dry_run_logs_both_titles_and_calls_nothing():
    # The rollout runs this for a day. Both strings have to be there verbatim,
    # because the comparison the whole feature depends on is a character-for-
    # character one, and "matched X" hides exactly the difference that matters.
    title = "The.Sopranos.S01E08.POLiSH.1080p.WEB.H264-CHOPiN"
    api = FakeArrApi({8989: [grab(598, title)]})
    lines = []
    assert reporter(api, out=lines.append, dry_run=True).report(
        title, "torbox", "aborted") == "dry-run"
    assert api.posts == []
    joined = "\n".join(lines)
    assert f"would report: {title}" in joined
    assert f"arr title:  {title}" in joined
    assert "Sonarr history 598 (aborted)" in joined


def test_a_dry_run_does_not_need_a_ledger_entry_to_repeat_itself():
    # Dry run deliberately writes nothing, so the same candidate appears on
    # every pass -- which is what makes a day of pairs readable as a set.
    api = FakeArrApi({8989: [grab(11921, RELEASE)]})
    ledger = {}
    r = reporter(api, ledger=ledger, dry_run=True)
    assert r.report(RELEASE, "torbox", "aborted") == "dry-run"
    assert r.report(RELEASE, "torbox", "aborted") == "dry-run"
    assert ledger == {}


def test_a_raising_reporter_does_not_stop_the_pass():
    # "Reporting failure must never stop the blackhole." Whatever the reporter
    # does -- a bug in the matching, an arr that answers with nonsense -- the
    # pass has to reach the next job.
    class Exploding:
        def report(self, *a, **k):
            raise RuntimeError("boom")

    lines = []
    assert m.report_failed(Exploding(), "Rel-GRP", "torbox", "aborted",
                           out=lines.append) is None
    assert any("boom" in line for line in lines)


def test_no_reporter_means_nothing_happens_and_nothing_raises():
    assert m.report_failed(None, "Rel-GRP", "torbox", "aborted") is None


def test_a_posted_report_is_persisted_before_the_pass_continues():
    # The ledger has to be on disk from the moment the arr accepts the report.
    # A crash after the POST and before the next save_state would otherwise
    # re-report the same grab on the next pass.
    written = []
    api = FakeArrApi({8989: [grab(11921, RELEASE)]})
    m.report_failed(reporter(api), RELEASE, "torbox", "aborted",
                    on_report=lambda: written.append(1))
    assert written == [1]


def test_a_failed_report_does_not_trigger_a_persist():
    written = []
    api = FakeArrApi({8989: [grab(11921, RELEASE)]}, post_ok=False)
    m.report_failed(reporter(api), RELEASE, "torbox", "aborted",
                    on_report=lambda: written.append(1))
    assert written == []


def test_the_ledger_prunes_what_has_outlived_the_history_window():
    ledger = {
        "Sonarr:1:torbox": {"at": "2026-09-14T12:00:00+00:00", "name": "keep"},
        "Sonarr:2:torbox": {"at": "2026-08-01T12:00:00+00:00", "name": "drop"},
        "Sonarr:3:torbox": {"at": "not a timestamp", "name": "drop-too"},
        "Sonarr:4:torbox": {"name": "no timestamp at all"},
    }
    kept = m.prune_ledger(ledger, NOW)
    assert list(kept) == ["Sonarr:1:torbox"]


def test_only_the_arrs_with_keys_are_asked():
    assert m.arr_services({"SONARR_API_KEY": "s"}) == [
        {"name": "Sonarr", "port": 8989, "key": "s"}]
    assert m.arr_services({"RADARR_API_KEY": "r"}) == [
        {"name": "Radarr", "port": 7878, "key": "r"}]
    assert m.arr_services({}) == []


def test_main_builds_arr_keys_in_the_shape_arr_services_reads(monkeypatch, tmp_path):
    """The round trip the per-function tests above cannot see.

    `main()` keyed this dict by display name ("Sonarr") while `arr_services()`
    looks each one up by environment variable ("SONARR_API_KEY"). Every lookup
    missed, so the list came back empty no matter how correct the keys were and
    `--report-failures` reported nothing, ever. The tests above call
    `arr_services()` directly with the shape it wants, so they passed
    throughout: nothing exercised the half that was wrong.

    Asserted by feeding main()'s own output to the function that consumes it,
    rather than by comparing dict keys -- the point is that the two agree, not
    that either has any particular shape.
    """
    captured = {}

    def fake_run(*args, **kwargs):
        captured.update(kwargs)
        return 0

    monkeypatch.setattr(m, "run", fake_run)
    monkeypatch.setenv("SONARR_API_KEY", "sonarr-key")
    monkeypatch.setenv("RADARR_API_KEY", "radarr-key")

    rc = m.main([
        str(tmp_path), str(tmp_path), str(tmp_path),
        str(tmp_path / "state.json"), str(tmp_path / "failed.log"),
        "--apply", "--api-key", "torbox-key", "--report-failures",
    ])
    assert rc == 0
    assert [s["name"] for s in m.arr_services(captured["arr_keys"])] == [
        "Sonarr", "Radarr"]


def test_the_arr_key_travels_in_the_curl_config_not_on_argv(monkeypatch):
    # Same rule as the TorBox key, and for the same reason: the blackhole runs
    # from systemd every two minutes, so an argv copy is a key on display twice
    # a minute, forever.
    seen = {}

    def run(argv, **kwargs):
        seen["argv"] = argv
        seen["input"] = kwargs.get("input", "")
        return type("R", (), {"returncode": 0, "stdout": "[]", "stderr": ""})()

    monkeypatch.setattr(m.subprocess, "run", run)
    m.ArrApi().get_json("http://localhost:8989/api/v3/history/since?apikey=SECRET")
    assert not any("SECRET" in arg for arg in seen["argv"])
    assert "SECRET" in seen["input"]


def test_an_arr_that_answers_with_html_is_treated_as_no_answer(monkeypatch):
    # A 200 carrying an error page from whatever sits in front of the arr.
    # Raising here would abort the pass; the caller needs None.
    def run(argv, **kwargs):
        return type("R", (), {"returncode": 0, "stdout": "<html>404</html>",
                              "stderr": ""})()

    monkeypatch.setattr(m.subprocess, "run", run)
    assert m.ArrApi().get_json("http://localhost:8989/x") is None


def test_arr_post_treats_http_error_as_failure(monkeypatch):
    # This POST is what tells the arr to blocklist a dead release, and its exit
    # status is the whole answer. curl exits 0 on a 4xx/5xx unless -f is given,
    # so a 401 from a stale key -- or a 500 -- would come back as success and
    # FailureReporter would write the ledger entry anyway: the release stays
    # unblocked and is never reported again.
    seen = {}

    def run(argv, **kwargs):
        seen["argv"] = argv
        # curl's exit code for HTTP >= 400. Without -f curl has nothing to
        # report, so it exits 0 -- which is the defect this test exists for.
        code = 22 if "-f" in argv else 0
        return type("R", (), {"returncode": code, "stdout": "", "stderr": ""})()

    monkeypatch.setattr(m.subprocess, "run", run)
    ok = m.ArrApi().post("http://localhost:8989/api/v3/history/failed/11921")
    assert ok is False
    assert "-f" in seen["argv"]


def test_reporting_is_off_unless_the_flag_says_otherwise(tmp_path, monkeypatch):
    # Ships inert. A pass that never resolves a single match is the safe
    # default, and the reported line says which mode the pass ran in -- a quiet
    # log must not be readable as "there was nothing to report".
    lines = []
    touched = []
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: FakeTorBox())
    monkeypatch.setattr(m, "ArrApi",
                        lambda *a, **k: touched.append(1) or FakeArrApi())
    m.run(str(tmp_path / "nzb"), str(tmp_path / "w"), str(tmp_path / "s"),
          str(tmp_path / "state.json"), str(tmp_path / "f.log"), "key",
          apply_changes=True, out=lines.append,
          arr_keys={"SONARR_API_KEY": "sk", "RADARR_API_KEY": "rk"})
    assert touched == []
    assert not any("failure reporting" in line for line in lines)


def test_the_pass_resolves_and_posts_when_reporting_is_on(tmp_path, monkeypatch):
    nzb_dir = tmp_path / "nzb"
    nzb_dir.mkdir()
    write_nzb(str(nzb_dir), f"{RELEASE}.nzb")
    watch = tmp_path / "watch"
    watch.mkdir()
    state_path = str(tmp_path / "state.json")

    arr = FakeArrApi({8989: [grab(11921, RELEASE)]})
    torbox = FakeTorBox(list_result=[{
        "id": 1,
        "download_state": "failed (Aborted, cannot be completed - "
                          "https://sabnzbd.org/not-complete)",
    }])
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: torbox)
    monkeypatch.setattr(m, "ArrApi", lambda *a, **k: arr)

    lines = []
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True,
          out=lines.append,
          arr_keys={"SONARR_API_KEY": "sk", "RADARR_API_KEY": "rk"},
          report_failures=True)

    assert arr.posts == ["http://localhost:8989/api/v3/history/failed/11921"
                         "?apikey=sk"]
    # And the ledger is on disk, not only in memory.
    assert list(m.load_state(state_path)["reported"]) == ["Sonarr:11921:torbox"]
    assert any("failure reporting: on (Sonarr, Radarr)" in l for l in lines)


def test_the_timeout_branch_reports_the_release_it_gave_up_on(tmp_path, monkeypatch):
    # The 24-hour bound is the other terminal outcome, and it is the one the
    # live stack was actually losing releases to: the oldest in-flight job was
    # 21.2h old against a 24h cap. Reporting only TorBox's own failures would
    # leave every timed-out release unblocked.
    nzb_dir = tmp_path / "nzb"
    nzb_dir.mkdir()
    write_nzb(str(nzb_dir), f"{RELEASE}.nzb")
    watch = tmp_path / "watch"
    watch.mkdir()
    state_path = str(tmp_path / "state.json")
    m.save_state(state_path, {"jobs": {
        m.job_key(str(nzb_dir / f"{RELEASE}.nzb")): job(name=RELEASE, age_hours=30)}})

    arr = FakeArrApi({8989: [grab(11921, RELEASE)]})
    torbox = FakeTorBox(list_result=[{"id": 7, "download_state": "downloading"}])
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: torbox)
    monkeypatch.setattr(m, "ArrApi", lambda *a, **k: arr)

    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True,
          out=lambda *a: None,
          arr_keys={"SONARR_API_KEY": "sk"}, report_failures=True)

    assert arr.posts == ["http://localhost:8989/api/v3/history/failed/11921"
                         "?apikey=sk"]
    # ...and the ledger records it as a timeout, not as TorBox's verdict.
    assert list(m.load_state(state_path)["reported"]) == ["Sonarr:11921:timeout"]


def test_an_unusable_release_at_fetch_time_is_not_reported(tmp_path, monkeypatch):
    # A password-protected or truncated RAR set is permanent, but it is not
    # TorBox's verdict and it does not come through `poll` -- so it does not
    # resolve to a grab here. Worth pinning: reporting it would mean matching a
    # release the arr may still import by hand if the bytes are good.
    nzb_dir = tmp_path / "nzb"
    nzb_dir.mkdir()
    write_nzb(str(nzb_dir), f"{RELEASE}.nzb")
    watch = tmp_path / "watch"
    watch.mkdir()
    state_path = str(tmp_path / "state.json")
    archive = tmp_path / "p.zip"
    make_zip(str(archive), {f"{RELEASE}/x.rar": b"part"})
    monkeypatch.setattr(m.shutil, "which", lambda name: None)  # no unpacker
    serve_zip(monkeypatch, archive)

    arr = FakeArrApi({8989: [grab(11921, RELEASE)]})
    torbox = FakeTorBox(list_result=[{"id": 1, "download_state": "completed"}])
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: torbox)
    monkeypatch.setattr(m, "ArrApi", lambda *a, **k: arr)

    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True,
          out=lambda *a: None,
          arr_keys={"SONARR_API_KEY": "sk"}, report_failures=True)

    assert arr.posts == []


def test_a_pass_fetches_one_round_and_leaves_the_rest(tmp_path, monkeypatch):
    # 2026-09-20: one admitted pass pulled 21 releases, three at a time, for
    # 53m12s, while the operator's --max-inflight 6 read 3 -- that ceiling
    # counts jobs TorBox has NOT finished, and the fetch set never consulted
    # it. The fetch set is now one round.
    #
    # Nine jobs, not three. With FETCH_WORKERS jobs the unbounded line fetches
    # them all and this test passes against the defect, which is the exact
    # shape of a guard that cannot fail.
    nzb_dir, watch, state_path, listing = several_jobs(tmp_path, m.FETCH_WORKERS * 3)
    started = []

    def fake_fetch(torbox, key, job, watch_dir, staging_dir, out=print):
        started.append(job["name"])
        out(f"    fetched: {job['name']}")
        return True

    monkeypatch.setattr(m, "fetch", fake_fetch)
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: FakeTorBox(list_result=listing))
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lambda *a: None)

    assert len(started) == m.FETCH_WORKERS
    assert len(m.load_state(state_path)["jobs"]) == m.FETCH_WORKERS * 2


def test_the_summary_names_the_three_numbers_separately(tmp_path, monkeypatch):
    # "still in flight 24" next to a ceiling of 6 reads as a broken cap. It is
    # not: 24 is the state file, 3 is the subset still holding a TorBox slot,
    # and the I/O comes from a third count again -- finished at TorBox and not
    # yet fetched. One word for three quantities is what made this look like a
    # cap failure on 2026-09-20.
    nzb_dir, watch, state_path, listing = several_jobs(tmp_path, m.FETCH_WORKERS + 2)
    # One job still downloading at TorBox. Without it every job in the fixture
    # is `complete`, so `at_torbox` is 0 and `owed` equals `outstanding` --
    # which means a summary that hardcoded "0 still at TorBox" satisfied every
    # assertion below. Replacing the real count with a literal 0 left all 148
    # tests green. One in-progress job is what makes the three counts
    # distinguishable, which is the entire point of this test.
    listing[-1]["download_state"] = "downloading"
    lines = []

    monkeypatch.setattr(m, "fetch", lambda *a, **k: True)
    monkeypatch.setattr(m, "TorBox", lambda *a, **k: FakeTorBox(list_result=listing))
    m.run(str(nzb_dir), str(watch), str(tmp_path / "staging"), state_path,
          str(tmp_path / "f.log"), "key", apply_changes=True, out=lines.append)

    summary = [l for l in lines if l.strip().startswith("submitted ")][-1]
    assert "outstanding 2" in summary
    assert "1 owed local I/O" in summary
    assert "1 still at TorBox" in summary
    # No line in the pass reuses the conflated label.
    assert not any("in flight" in l for l in lines)
    assert any(l.strip().startswith("outstanding:") for l in lines)
