#!/usr/bin/env python3
"""Fetch usenet releases through TorBox's API, for the arrs' UsenetBlackhole.

Why this exists
---------------
SABnzbd here points at `nntp.torbox.app`. Measured 2026-09-14, that server
serves articles only up to roughly 90 days old: releases aged 1, 34, 60 and 86
days resolved 5/5 or 6/6 every time, while 101 and 138 days resolved 0/5 and
0/6. The group always exists; the articles are gone. That is why SABnzbd
imported 1 of 92 Sonarr usenet grabs while torrents imported 109 of 202.

TorBox's *API* has no such limit, because it runs a usenet client against a real
backbone rather than serving from that cache: the exact 138-day-old NZB SABnzbd
cannot fetch was submitted to `createusenetdownload` and completed at 836 MB
across 4 files. So the fix is to stop asking a cache to be a backbone and submit
NZBs to TorBox instead.

How it works
------------
Both arrs ship a `UsenetBlackhole` download client whose entire contract is two
paths. The arr writes `<Release.Title>.nzb` into `nzbFolder` and then polls
`watchFolder` for the result (Sonarr's `ScanWatchFolder.cs`, read from source):

  * it looks at IMMEDIATE SUBDIRECTORIES of the watch folder, plus loose video
    files directly in it. The directory name becomes the item title via
    `FileNameBuilder.CleanFileName`, which is only filesystem sanitisation --
    the release name arrives intact.
  * a directory is `Completed` once no file inside is locked, and it will not be
    imported until its contents have been stable for a 30-second grace period.
  * therefore the release directory must be fully written BEFORE it is renamed
    into place, and the half-written copy must live somewhere the arr does not
    look. `fetch` stages under `staging_dir` and renames into `watch_dir` when
    the release is whole.
  * after importing, the arr deletes the release folder itself
    (`UsenetBlackhole.RemoveItem` -> `DownloadClientBase.DeleteItemData`), so the
    watch folder does not grow on its own.

`staging_dir` is a sibling of the watch folder rather than a `.incoming-`
directory inside it, and that is not cosmetic. A dot-directory looks hidden to
a person, but Sonarr does not skip it: `DiskProviderBase.GetDirectories` skips
only `FileAttributes.System`, and `DiskScanService.FilterPaths` matches
dot-segments with a regex that requires a trailing separator -- which
`PathExtensions.GetRelativePath` has already trimmed off. A `.incoming-` staging
directory inside the watch folder is reported to the arr as a completed
download, and its half-written files are what get imported.

This module does the three steps in between: submit, poll, fetch.

  * `submit`  uploads each NZB to `createusenetdownload`, recording a stable
    identity so a restart never submits the same release twice.
  * `poll`    asks `usenet/mylist` for each in-flight job.
  * `fetch`   requests a zip link once the job is complete, unpacks it into the
    watch folder, and drops the staging directory.

Failure is explicit. A blackhole client reports no queue to the arr -- the arr
only sees what appears in the watch folder -- so a release that never completes
would otherwise sit invisible forever. Every job that TorBox reports failed, or
that exceeds `--timeout-hours`, is appended to `logs/usenet-blackhole-failed.log`
and removed from the state file, so the operator can see it and the arr can be
told to try something else.

Usage:
  usenet_blackhole.py <nzb-dir> <watch-dir> <staging-dir> <state-path>
                      <failed-log>
                      [--api-key K] [--apply] [--timeout-hours N] [--verbose]
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from xml.etree import ElementTree

TORBOX_API = "https://api.torbox.app/v1/api"

# TorBox's own state strings (GET /usenet/mylist -> download_state).
DONE_STATES = {"completed", "cached"}
FAILED_STATES = {"failed", "error"}

# Every API call is bounded. A watcher that hangs on one request stops fetching
# everything behind it, and the arr has no other way to notice.
API_TIMEOUT = 120

# A staging directory older than this with no job claiming it came from a crash
# mid-fetch, not from a fetch in progress.
STALE_STAGING_HOURS = 1.0


class TorBoxError(RuntimeError):
    pass


class PermanentError(TorBoxError):
    """The release itself is unusable, so a retry would fail the same way.

    Worth its own class because the retry is not free: every attempt downloads
    the whole release again. A password-protected RAR set or a release with no
    video in it has to be failed and recorded, not retried every two minutes
    until the 24-hour timeout.
    """


class StateError(RuntimeError):
    """The state file could not be written, so this pass cannot be trusted.

    Raised rather than swallowed: that file is the only thing stopping the next
    pass from submitting every release to TorBox a second time, so a pass that
    cannot write it has to fail loudly rather than look like it succeeded.
    """


def quoted(value):
    """Escape a value for a curl config file (see queue_cleanup.py)."""
    return value.replace("\\", "\\\\").replace('"', '\\"')


def _run_curl(lines, timeout=API_TIMEOUT):
    """Return the response body, or raise TorBoxError carrying the API's answer.

    Deliberately not `curl -f`: that returns exit 22 and throws the response
    body away, and TorBox puts the reason in the body. A 422 here reads as
    `curl: (22) The requested URL returned error: 422` with `-f`, and as
    `{"detail":[{"type":"missing","loc":["query","token"],...}]}` without it.
    The second one is the whole diagnosis.
    """
    proc = subprocess.run(
        ["curl", "-sS", "--max-time", str(timeout), "-w", "\n%{http_code}", "--config", "-"],
        input="\n".join(lines) + "\n",
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise TorBoxError(f"curl exit {proc.returncode}: {proc.stderr.strip()[:200]}")
    body, _, code = proc.stdout.rpartition("\n")
    if not code.startswith("2"):
        raise TorBoxError(f"HTTP {code}: {body.strip()[:240]}")
    return body


class TorBox:
    """The subset of TorBox's usenet API this watcher needs."""

    def __init__(self, api_key, base=TORBOX_API):
        self.api_key = api_key
        self.base = base.rstrip("/")

    def _get(self, path):
        out = _run_curl(
            [
                f'url = "{quoted(self.base + path)}"',
                f'header = "Authorization: Bearer {quoted(self.api_key)}"',
            ]
        )
        try:
            return json.loads(out)
        except json.JSONDecodeError as err:
            raise TorBoxError(f"{path} did not return JSON: {out[:160]!r}") from err

    def submit_file(self, nzb_path, name):
        """Submit an NZB, keyed off argv through the curl config.

        `curl --form file=@path` has to name the path, so the caller passes it;
        the API key itself still travels in the config on stdin rather than on
        the command line, where /proc/<pid>/cmdline would expose it.
        """
        config = [
            f'url = "{quoted(self.base + "/usenet/createusenetdownload")}"',
            f'header = "Authorization: Bearer {quoted(self.api_key)}"',
            f'form = "file=@{quoted(nzb_path)}"',
            f'form = "name={quoted(name)}"',
            'form = "as_queued=false"',
        ]
        out = _run_curl(config)
        try:
            payload = json.loads(out)
        except json.JSONDecodeError as err:
            raise TorBoxError(f"submit did not return JSON: {out[:160]!r}") from err
        if not payload.get("success"):
            raise TorBoxError(f"submit refused: {payload.get('detail') or payload}")
        return payload.get("data") or {}

    def list_usenet(self):
        payload = self._get("/usenet/mylist?bypass_cache=true&limit=1000")
        return payload.get("data") or []

    def request_zip_link(self, usenet_id):
        """Get a zip download link for a finished usenet download.

        `token` goes in the query string as well as the Authorization header,
        because this endpoint requires it: with the header alone it answers
        `422 {"detail":[{"type":"missing","loc":["query","token"]}]}`. Nothing
        else this module calls needs it, and the link TorBox hands back carries
        the same token in its own URL, which is why `fetch` downloads through a
        curl config on stdin rather than on argv.
        """
        payload = self._get(
            f"/usenet/requestdl?token={self.api_key}"
            f"&usenet_id={usenet_id}&zip_link=true"
        )
        if not payload.get("success"):
            raise TorBoxError(f"zip link refused: {payload.get('detail') or payload}")
        data = payload.get("data")
        if isinstance(data, dict):
            return data.get("url") or data.get("download_link")
        return data


# --- state -----------------------------------------------------------------

def load_state(path):
    """Jobs we have submitted and not yet finished.

    Keyed by a stable identity so a restart between submit and fetch resumes
    rather than submitting the release a second time -- TorBox would happily
    download it twice and the arr would see two folders.
    """
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {"jobs": {}}
    if not isinstance(data, dict):
        return {"jobs": {}}
    data.setdefault("jobs", {})
    return data


def save_state(path, state):
    """Write the state atomically, or raise StateError.

    Atomic because the file is what prevents a double submit: a half-written
    state read back on the next pass would look empty and TorBox would be asked
    to download every release again.
    """
    directory = os.path.dirname(path)
    try:
        if directory:
            os.makedirs(directory, exist_ok=True)
        tmp = f"{path}.tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(state, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, path)
    except OSError as err:
        raise StateError(f"cannot write {path}: {err}") from err


def job_key(nzb_path):
    """Identity for an NZB: its content hash, not its path.

    Hashing the bytes means a re-grab of the same release under a slightly
    different filename still counts as the same job, and a release the arr
    re-sends after a failure is not queued twice.

    Returns None when the file cannot be read -- the arr may have deleted it
    between the directory listing and this call.
    """
    try:
        with open(nzb_path, "rb") as handle:
            return hashlib.sha256(handle.read()).hexdigest()[:32]
    except OSError:
        return None


def is_complete_nzb(path):
    """True when this parses as an NZB with at least one file in it.

    The arr writes the whole document with one `stream.Write`, but a pass that
    reads it mid-write would submit a truncated one -- and TorBox would then
    download whatever segments survived, which arrives as a damaged release
    rather than as a failure. An unparseable NZB is skipped and retried on the
    next pass, by which time the write has finished.
    """
    try:
        root = ElementTree.parse(path).getroot()
    except (OSError, ElementTree.ParseError):
        return False
    if root.tag.split("}")[-1].lower() != "nzb":
        return False
    return any(child.tag.split("}")[-1].lower() == "file" for child in root)


def record_failure(log_path, name, reason):
    """Make a failure visible.

    A blackhole client reports no queue to the arr: a release that never
    completes is simply absent, indistinguishable from one still downloading.
    Without this line the only symptom is a title that never arrives.
    """
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        directory = os.path.dirname(log_path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(f"{stamp}\t{name}\t{reason}\n")
    except OSError as err:
        print(f"warning: could not write {log_path}: {err}", file=sys.stderr)


# --- the three steps -------------------------------------------------------

def pending_nzbs(nzb_dir, state):
    """NZBs on disk that are whole and not already in flight, in name order."""
    try:
        names = sorted(os.listdir(nzb_dir))
    except OSError:
        return []
    out = []
    for name in names:
        if not name.lower().endswith(".nzb"):
            continue
        path = os.path.join(nzb_dir, name)
        if not os.path.isfile(path) or not is_complete_nzb(path):
            continue
        key = job_key(path)
        if key is None or key in state["jobs"]:
            continue
        out.append((key, name, path))
    return out


def submit(torbox, nzb_dir, state, out=print):
    """Upload every new NZB. Returns the number submitted."""
    submitted = 0
    for key, name, path in pending_nzbs(nzb_dir, state):
        release = os.path.splitext(name)[0]
        try:
            data = torbox.submit_file(path, release)
        except TorBoxError as err:
            out(f"    ! {release}: submit failed: {err}")
            continue
        state["jobs"][key] = {
            "name": release,
            "torbox_id": data.get("usenetdownload_id"),
            "hash": data.get("hash"),
            "submitted_at": datetime.now(timezone.utc).isoformat(),
        }
        submitted += 1
        out(f"    queued: {release} (id {data.get('usenetdownload_id')})")
    return submitted


def poll(torbox, state, timeout_hours, failed_log, now=None, out=print):
    """Classify in-flight jobs. Returns a list of (key, release, state).

    TorBox is the authority on completion; a job missing from its list is left
    alone rather than assumed failed, because the list is paginated and cached
    and a transient empty answer would otherwise fail every live job at once.
    """
    results = []
    by_id = {}
    for item in torbox.list_usenet():
        if item.get("id") is not None:
            by_id[item["id"]] = item

    now = now or datetime.now(timezone.utc)
    for key, job in list(state["jobs"].items()):
        record = by_id.get(job.get("torbox_id"))
        if record is None:
            results.append((key, job["name"], "unknown"))
            continue
        state_name = (record.get("download_state") or "").lower()
        if state_name in DONE_STATES:
            results.append((key, job["name"], "complete"))
            continue
        if state_name in FAILED_STATES:
            record_failure(failed_log, job["name"], f"torbox reported {state_name}")
            del state["jobs"][key]
            results.append((key, job["name"], "failed"))
            continue

        try:
            started = datetime.fromisoformat(job["submitted_at"])
        except (KeyError, ValueError):
            started = now
        if started.tzinfo is None:
            started = started.replace(tzinfo=timezone.utc)
        age_hours = (now - started).total_seconds() / 3600.0
        if age_hours > timeout_hours:
            record_failure(
                failed_log,
                job["name"],
                f"still {state_name or 'unknown'} after {age_hours:.1f}h",
            )
            del state["jobs"][key]
            results.append((key, job["name"], "timeout"))
            continue
        results.append((key, job["name"], "in_progress"))
    return results


def is_rar_volume(name):
    """True for `x.rar`, `x.part03.rar`, `x.r00`..`x.r99` and `x.s00`."""
    lower = name.lower()
    if lower.endswith(".rar"):
        return True
    _, _, ext = lower.rpartition(".")
    return len(ext) == 3 and ext[0] in ("r", "s") and ext[1:].isdigit()


def find_rar_entry(directory):
    """The first volume of a RAR set in this directory, or None.

    Multi-volume sets are opened through their first file: `x.rar` (or
    `x.part01.rar`) when present, otherwise `x.r00`. Sorted, so `part01` wins
    over `part02`.
    """
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return None
    files = [n for n in names if os.path.isfile(os.path.join(directory, n))]
    for suffix in (".rar", ".r00"):
        found = [n for n in files if n.lower().endswith(suffix)]
        if found:
            return os.path.join(directory, found[0])
    return None


def unpack_rar(directory, out=print):
    """Unpack a RAR set in place and delete the volumes. Returns True if it did.

    Usenet releases are normally posted as RAR volumes, and the video is inside
    them: SABnzbd's unpack step is what turned those into a file the arr could
    import. TorBox hands back exactly what was posted, so without this the
    release arrives as eighty-odd `.rNN` files plus an un-rarred `Sample/`,
    Sonarr finds only the sample, rejects the release as a sample, and deletes
    the whole folder -- measured 2026-09-14 on the first real release through
    this path.
    """
    entry = find_rar_entry(directory)
    if entry is None:
        return False

    unrar = shutil.which("unrar")
    seven = shutil.which("7z") or shutil.which("7zr")
    if unrar:
        argv = [unrar, "x", "-o+", "-idq", entry, directory + os.sep]
    elif seven:
        argv = [seven, "x", "-y", "-bso0", "-bsp0", f"-o{directory}", entry]
    else:
        raise PermanentError(f"no unrar or 7z to unpack {os.path.basename(entry)}")

    try:
        proc = subprocess.run(argv, capture_output=True, text=True)
    except OSError as err:
        raise PermanentError(f"could not run {argv[0]}: {err}") from err
    if proc.returncode != 0:
        # A password-protected or truncated set lands here, and both are safe to
        # call permanent: the same release will fail the same way.
        detail = (proc.stderr or proc.stdout).strip().splitlines()
        raise PermanentError(
            f"{os.path.basename(argv[0])} exit {proc.returncode}: "
            f"{detail[-1][:160] if detail else 'no output'}"
        )

    removed = 0
    try:
        names = os.listdir(directory)
    except OSError as err:
        # The unpack itself worked, so this is not worth failing the release
        # over; the volumes left behind are only extra bytes in the release
        # directory.
        out(f"    ! could not list {directory} to remove the volumes: {err}")
        return True
    for name in names:
        if not is_rar_volume(name):
            continue
        path = os.path.join(directory, name)
        try:
            if os.path.isfile(path):
                os.remove(path)
                removed += 1
        except OSError as err:
            # Leftovers are not fatal, but they are worth a line: they are what
            # the arr would otherwise count towards the release size.
            out(f"    ! could not remove {name}: {err}")
    out(f"    unpacked {os.path.basename(entry)} ({removed} volume(s) removed)")
    return True


def discard_nzb(nzb_dir, name):
    """Delete a finished job's NZB, so it is never submitted again.

    The arr never cleans its own nzb folder -- for a blackhole it is an outbox,
    not a queue the arr tracks -- so a file left there is indistinguishable from
    a fresh grab on the next pass. The job is no longer in flight by then, so it
    would be submitted and downloaded a second time, and again every two
    minutes: measured 2026-09-14, a 4.6 GB release re-downloaded in full on the
    pass after the one that delivered it.
    """
    try:
        os.remove(os.path.join(nzb_dir, name + ".nzb"))
    except OSError:
        pass


def fetch(torbox, key, job, watch_dir, staging_dir, out=print):
    """Download the finished release into the watch folder.

    Staged outside the watch folder and renamed into place, because the arr
    treats a directory as complete the moment nothing inside it is locked and
    will import it after a 30-second grace period. A directory that appears
    before its contents are written gets imported half-empty, and one that
    merely *sits* in the watch folder -- `.incoming-` included -- is read as a
    finished download.
    """
    name = job["name"]
    dest = os.path.join(watch_dir, name)
    staging = os.path.join(staging_dir, key)

    if os.path.isdir(dest):
        out(f"    already in the watch folder: {name}")
        return True

    link = torbox.request_zip_link(job["torbox_id"])
    if not link:
        raise TorBoxError("no zip link returned")

    try:
        os.makedirs(watch_dir, exist_ok=True)
        os.makedirs(staging_dir, exist_ok=True)
        shutil.rmtree(staging, ignore_errors=True)
        os.makedirs(staging, exist_ok=True)
    except OSError as err:
        raise TorBoxError(f"cannot stage under {staging_dir}: {err}") from err

    zip_path = os.path.join(staging, "payload.zip")
    try:
        # Through a curl config on stdin, so the link stays off argv. TorBox's
        # download URLs carry the account token in their own query string, and
        # an argv copy is readable by anything on the box through
        # /proc/<pid>/cmdline -- the same leak the shell wrapper used to have.
        subprocess.run(
            ["curl", "-sS", "-f", "-L", "--max-time", "3600", "--config", "-"],
            input=f'url = "{quoted(link)}"\noutput = "{quoted(zip_path)}"\n',
            check=True,
            capture_output=True,
            text=True,
        )
        try:
            archive = zipfile.ZipFile(zip_path)
        except zipfile.BadZipFile as err:
            raise PermanentError(f"TorBox returned something that is not a zip: {err}") from err
        with archive:
            # Zip entries from TorBox can carry path traversal; refuse rather
            # than write outside the staging directory.
            root = os.path.realpath(staging)
            for member in archive.namelist():
                target = os.path.realpath(os.path.join(staging, member))
                if not target.startswith(root + os.sep):
                    raise PermanentError(f"zip entry escapes the target: {member}")
            archive.extractall(staging)
        os.remove(zip_path)

        # TorBox zips the release inside a folder of its own name; unwrap it so
        # the arr sees the video files directly under the release directory.
        entries = [e for e in os.listdir(staging) if not e.startswith(".")]
        if len(entries) == 1 and os.path.isdir(os.path.join(staging, entries[0])):
            inner = os.path.join(staging, entries[0])
            for entry in os.listdir(inner):
                shutil.move(os.path.join(inner, entry), os.path.join(staging, entry))
            os.rmdir(inner)

        # ...and the release itself is usually inside RAR volumes, which the arr
        # cannot read. This is SABnzbd's unpack step, and it runs BEFORE the
        # rename: an un-unpacked release that reaches the watch folder is
        # rejected as a sample and deleted.
        unpack_rar(staging, out=out)

        os.replace(staging, dest)
        out(f"    fetched: {name}")
        return True
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def sweep_staging(staging_dir, keep, older_than_hours=STALE_STAGING_HOURS,
                  now=None, out=print):
    """Delete staging directories that no job is going to claim.

    `fetch` reuses a job's own staging path and wipes it first, so a retry of the
    same release cleans up after itself. A release that failed, timed out, or was
    superseded leaves its half-written copy behind with nothing left to claim it
    -- invisible to the arr, which never looks in here, and worth ~800 MB a time
    on a NAS where nobody would think to look.
    """
    now = now or datetime.now(timezone.utc)
    try:
        entries = os.listdir(staging_dir)
    except OSError:
        return 0
    removed = 0
    for entry in entries:
        path = os.path.join(staging_dir, entry)
        if entry in keep or not os.path.isdir(path):
            continue
        try:
            written = datetime.fromtimestamp(os.path.getmtime(path), timezone.utc)
        except OSError:
            continue
        if (now - written).total_seconds() / 3600.0 < older_than_hours:
            continue
        try:
            shutil.rmtree(path)
        except OSError as err:
            # Reported rather than ignored: `ignore_errors=True` here would let a
            # directory that survived the delete still count as cleared, which is
            # the one thing this sweep exists to prevent.
            out(f"    ! could not clear staging {entry}: {err}")
            continue
        removed += 1
        out(f"    cleared stale staging: {entry}")
    return removed


def run(nzb_dir, watch_dir, staging_dir, state_path, failed_log, api_key,
        apply_changes=False, timeout_hours=24.0, verbose=False, out=print):
    """One pass: submit new NZBs, poll in-flight jobs, fetch completed ones."""
    state = load_state(state_path)

    if nzb_dir and os.path.isdir(nzb_dir):
        out(f"  NZB folder:   {nzb_dir}")
    out(f"  watch folder: {watch_dir}")
    out(f"  staging:      {staging_dir}")
    out(f"  in flight:    {len(state['jobs'])}")

    if not apply_changes:
        for key, name, path in pending_nzbs(nzb_dir, state):
            out(f"    would submit: {name}")
        for key, job in state["jobs"].items():
            out(f"    in flight: {job['name']} (torbox id {job.get('torbox_id')})")
        return 0

    torbox = TorBox(api_key)
    submitted = submit(torbox, nzb_dir, state, out=out)
    save_state(state_path, state)

    fetched = 0
    for key, name, status in poll(torbox, state, timeout_hours, failed_log, out=out):
        if status == "complete":
            try:
                if fetch(torbox, key, state["jobs"][key], watch_dir, staging_dir, out=out):
                    del state["jobs"][key]
                    fetched += 1
                    discard_nzb(nzb_dir, name)
            except PermanentError as err:
                # Nothing will change on a retry, and a retry re-downloads the
                # whole release. Record it, drop it, and clear the NZB so the
                # next pass does not pick the same release up again.
                record_failure(failed_log, name, f"unusable: {err}")
                del state["jobs"][key]
                discard_nzb(nzb_dir, name)
                out(f"    ! {name}: {err}")
            except Exception as err:  # noqa: BLE001 - one bad release must not stop the sweep
                out(f"    ! {name}: fetch failed, will retry: {err}")
        elif status in ("failed", "timeout"):
            # Both are terminal, and `poll` has already logged them.
            discard_nzb(nzb_dir, name)
            if status == "timeout":
                out(f"    ! {name}: timed out")
        elif verbose:
            out(f"    ... {name}: {status}")
    save_state(state_path, state)

    sweep_staging(staging_dir, set(state["jobs"]), out=out)

    out(f"  submitted {submitted}, fetched {fetched}, still in flight {len(state['jobs'])}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("nzb_dir")
    parser.add_argument("watch_dir")
    parser.add_argument("staging_dir")
    parser.add_argument("state_path")
    parser.add_argument("failed_log")
    parser.add_argument("--api-key", default=os.environ.get("TORBOX_API_KEY", ""))
    parser.add_argument("--apply", action="store_true", help="do it (default: dry run)")
    parser.add_argument("--timeout-hours", type=float, default=24.0)
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args(argv)

    if args.apply and not args.api_key:
        print("ERROR: no API key (--api-key or TORBOX_API_KEY)", file=sys.stderr)
        return 2

    try:
        return run(
            args.nzb_dir,
            args.watch_dir,
            args.staging_dir,
            args.state_path,
            args.failed_log,
            args.api_key,
            apply_changes=args.apply,
            timeout_hours=args.timeout_hours,
            verbose=args.verbose,
        )
    except StateError as err:
        # One line, not a traceback: whoever reads the timer's log needs to know
        # that releases may be submitted twice until this is fixed.
        print(f"ERROR: {err}", file=sys.stderr)
        print("ERROR: releases already submitted may be sent again", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
