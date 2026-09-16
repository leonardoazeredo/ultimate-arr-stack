#!/usr/bin/env python3
"""Show what the usenet blackhole is doing, read-only.

Why this exists
---------------
scripts/usenet-blackhole.sh is a blackhole client: the arr writes an NZB, the
watcher submits it to TorBox and drops the finished release into the arr's watch
folder. The arr sees only what appears in that folder, so a release that is in
flight, stalled or quietly dead is invisible from both ends -- the arr reports no
queue, and the only record this stack keeps is
logs/usenet-blackhole-state.json, which is written for the watcher to resume from
rather than for a person to read. Measured 2026-09-15: twelve jobs in flight,
none of them in either arr's queue.

This module turns that state file into the view the watcher itself does not
print: per job, the release name, how far along TorBox says it is, how long ago
it was submitted, how long since its progress last moved, and a status derived
from those. Plus the totals, and the tail of the failure log.

Reading, not deciding
---------------------
Nothing here writes anything, and nothing here calls TorBox or either arr: no
API key is read, .env is never opened, and both renderers are pure functions
over a structure that was already parsed. The statuses are derived from the
state file alone, so they can lag what TorBox would say by one pass (up to two
minutes) -- that is the price of a view that cannot disturb the downloads it is
describing.

The derived status is a display word, not a verdict. `stalled` means the same
thing poll() means by it -- no progress for longer than the stall threshold,
four hours by default and settable with --stall-hours -- but nothing is failed
or deleted on the strength of this page. The next pass decides, and this only
shows what it will be deciding about. The threshold has to be the one the
watcher was last run with: a view holding a different value would call a job
stalled while the watcher still considered it fine, which is the disagreement
--stall-hours exists to close.

Every field on a job is optional except its key. `complete`, `download_state`
and `pause_until` appear on some entries and not others, the file is written by
a script that has changed shape before, and an operator is reading this
precisely because something is already wrong -- so a missing or malformed field
degrades to "unknown" or to no value at all, and never to a traceback.

Usage:
  usenet_status.py <format:json|html> [state-path] [failed-log-path]
      [--stall-hours N]

--stall-hours (default 4) is the stall threshold `stalled` is derived from; it
takes a number above zero, in the `--stall-hours N` and `--stall-hours=N`
forms, and may appear before, between or after the positional arguments. Pass
the same value the watcher runs with, or the page and the watcher will disagree
about which jobs are stalled.
"""

import html
import json
import math
import sys
from collections import deque
from datetime import datetime, timezone

# The watcher's own rule, imported rather than restated. The view answers the
# same question the writer answers ("is this job done, is it dead?"), and two
# copies of that answer would drift the first time TorBox changes a state
# string -- which has already happened once: the failure match is a PREFIX,
# because TorBox never returns a bare "failed" (see usenet_blackhole.py). The
# stall threshold is the same argument by a different route: the watcher takes
# it from its own command line, so this module takes it from its own
# (--stall-hours) and defaults to the watcher's default.
from usenet_blackhole import DONE_STATES, failure_reason

# TorBox reports `progress` as a percentage, and `last_progress` in the state
# file is that number copied verbatim. Nothing here rescales it: a view that
# guessed at a 0-1 fraction would show "100%" for a job at one percent.
#
# The default stall threshold, and the same 4 hours scripts/usenet-blackhole.sh
# defaults to. main() overrides it from --stall-hours, which is what keeps the
# page agreeing with a watcher running on a different value: with the threshold
# hardcoded, a job stalled 5 hours read "stalled" here while a `--stall-hours 6`
# watcher still considered it fine.
STALL_HOURS = 4.0

# How many failure-log lines the view carries. The log is append-only and holds
# every failure this stack has ever recorded; a page wants the recent ones.
FAILURE_TAIL = 50

# Only a convenience for a hand-run `usenet_status.py json` from the stack root.
# scripts/usenet-blackhole-status.sh always passes absolute paths, because a
# timer or a cron job has no meaningful working directory.
DEFAULT_STATE_PATH = "logs/usenet-blackhole-state.json"
DEFAULT_FAILED_LOG = "logs/usenet-blackhole-failed.log"

STATUS_COMPLETE = "complete"
STATUS_FAILED = "failed"
STATUS_STALLED = "stalled"
STATUS_DOWNLOADING = "downloading"
STATUS_UNKNOWN = "unknown"

# The same list the renderer switches CSS classes on, so a status added without
# a badge is a KeyError in a test rather than an unstyled row in production.
STATUSES = (
    STATUS_COMPLETE,
    STATUS_FAILED,
    STATUS_STALLED,
    STATUS_DOWNLOADING,
    STATUS_UNKNOWN,
)

# Terminal statuses: a job in one of these is not using a TorBox slot, whatever
# else the state file says about it.
FINISHED = (STATUS_COMPLETE, STATUS_FAILED)


def parse_time(value):
    """A datetime for an ISO timestamp, or None if it is not one.

    A naive timestamp is read as UTC, the convention every other module here
    uses (backoff_until, hours_since_last): the state file is written with
    timezone-aware values, so a naive one means something else wrote it, and
    treating it as local time would shift every age by the host's offset.

    The trailing-Z form is rewritten rather than left to fromisoformat, which
    did not accept it before Python 3.11. TorBox timestamps and hand-edited
    files both arrive in that shape.
    """
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        moment = datetime.fromisoformat(text)
    except (TypeError, ValueError):
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment


def _number(value):
    """A finite float for a numeric field, or None.

    Deliberately not `float(value)` and a bare except: `True` is an int in
    Python and would read as 1%, and `float("nan")` parses, compares false
    against everything and re-serialises into JSON that most parsers reject.
    A string is accepted because it costs nothing and a hand-edited state file
    is exactly the kind of input this view exists to survive.
    """
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, str):
        try:
            value = float(value)
        except ValueError:
            return None
    if not isinstance(value, (int, float)):
        return None
    number = float(value)
    return number if math.isfinite(number) else None


def _hours_since(moment, now):
    """Hours from `moment` to `now`, to one decimal, or None."""
    if moment is None:
        return None
    return round((now - moment).total_seconds() / 3600.0, 1)


def _release_name(key, job):
    """The release name, or the job key when the name is missing or unusable.

    The key is the only field the state file guarantees -- it is the NZB's
    content hash -- and it is what an operator greps the state file for, so an
    entry with no name still gets a label rather than an empty cell.
    """
    name = job.get("name") if isinstance(job, dict) else None
    if isinstance(name, str) and name.strip():
        return name
    return str(key)


def job_status(job, now, stall_hours=STALL_HOURS):
    """One job's status word, derived from whatever fields it actually has.

    The order of the tests is the order of the facts: a completed job is
    complete however long its progress has been still, a failed one is failed
    even though TorBox was reporting progress when it died, and only then is the
    stall clock consulted. `unknown` is the honest answer for a job with no
    usable timestamp at all -- there is nothing to compute an age or a stall
    from, and calling that "downloading" would put a reassuring word on a row
    that says nothing.
    """
    entry = job if isinstance(job, dict) else {}
    state_name = entry.get("download_state")
    state_name = state_name.strip().lower() if isinstance(state_name, str) else ""
    if entry.get("complete") is True or state_name in DONE_STATES:
        return STATUS_COMPLETE
    if failure_reason(state_name) is not None:
        return STATUS_FAILED
    moved = parse_time(entry.get("progress_changed_at"))
    submitted = parse_time(entry.get("submitted_at"))
    if moved is None and submitted is None:
        return STATUS_UNKNOWN
    # `>` and not `>=`, matching poll()'s own comparison: a job sitting exactly
    # on the threshold has not yet crossed it, and the two halves of this stack
    # disagreeing about one job at one instant is not worth the symmetry.
    if moved is not None and (now - moved).total_seconds() / 3600.0 > stall_hours:
        return STATUS_STALLED
    return STATUS_DOWNLOADING


def job_summary(key, job, now, stall_hours=STALL_HOURS):
    """One state entry as plain data. Never raises, whatever the file held.

    `key` is the NZB hash the state file is keyed by; it is passed in rather
    than read from the job because that is where the identity actually lives.
    """
    entry = job if isinstance(job, dict) else {}
    submitted = parse_time(entry.get("submitted_at"))
    moved = parse_time(entry.get("progress_changed_at"))
    state_name = entry.get("download_state")
    state_name = state_name.strip() if isinstance(state_name, str) else ""
    status = job_status(entry, now, stall_hours)
    progress = _number(entry.get("last_progress"))
    return {
        "key": str(key),
        "name": _release_name(key, entry),
        "status": status,
        "complete": status == STATUS_COMPLETE,
        "progress_percent": None if progress is None else round(progress, 1),
        "submitted_at": submitted.isoformat() if submitted else None,
        "age_hours": _hours_since(submitted, now),
        "progress_changed_at": moved.isoformat() if moved else None,
        "stalled_hours": _hours_since(moved, now),
        "download_state": state_name or None,
    }


def summarize(state, now, stall_hours=STALL_HOURS, failures=()):
    """The whole view as plain data: per job, plus totals, plus the log tail.

    Pure by construction -- state in, structure out, no file is opened -- so the
    tests need no filesystem and no clock. The caller passes `now` rather than
    this reading it, because a summary whose numbers mean something different
    every second cannot be asserted on.

    `failures` is the already-parsed tail from load_failures. It rides in the
    same structure so both renderers show one document rather than the JSON
    renderer quietly dropping half the view.
    """
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    jobs = state.get("jobs") if isinstance(state, dict) else None
    if not isinstance(jobs, dict):
        jobs = {}

    rows = [job_summary(key, job, now, stall_hours) for key, job in jobs.items()]
    # Ordered by release name, with the key as the tie-break, so two renderings
    # of an unchanged state file are byte-identical however the dict was built
    # up. Without this the page reshuffles between runs for no reason an
    # operator can see.
    rows.sort(key=lambda row: (row["name"].lower(), row["key"]))

    totals = {
        "jobs": len(rows),
        # A failed job still listed in the state file is terminal -- it is on
        # its way out, and the watcher has already stopped spending a slot on
        # it -- so counting it as in flight would overstate what is running.
        "in_flight": sum(1 for row in rows if row["status"] not in FINISHED),
        "complete": sum(1 for row in rows if row["status"] == STATUS_COMPLETE),
        "stalled": sum(1 for row in rows if row["status"] == STATUS_STALLED),
        "failed": sum(1 for row in rows if row["status"] == STATUS_FAILED),
        "unknown": sum(1 for row in rows if row["status"] == STATUS_UNKNOWN),
    }

    return {
        "generated_at": now.isoformat(),
        "stall_hours": stall_hours,
        "totals": totals,
        "jobs": rows,
        "failures": [entry for entry in failures if isinstance(entry, dict)],
    }


# --- reading the two files --------------------------------------------------


def load_state(path):
    """The state file, or an empty one.

    Same contract as usenet_blackhole.load_state -- the shape is the writer's,
    and a viewer that insisted on it would be the second thing to break after
    the thing it is trying to describe. An absent file, a truncated write, a
    JSON array where an object was expected: all of them are "no jobs to
    show", which is also exactly what a healthy idle stack looks like, so the
    page says which file it read instead (see `sources`).
    """
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {"jobs": {}}
    if not isinstance(data, dict):
        return {"jobs": {}}
    if not isinstance(data.get("jobs"), dict):
        data["jobs"] = {}
    return data


def load_failures(path, limit=FAILURE_TAIL):
    """The last `limit` lines of the failure log, oldest first, parsed.

    Each line the watcher writes is `stamp<TAB>release<TAB>reason`. A line that
    does not split that way is kept whole as the release name rather than
    dropped: the log is the only record a dead release leaves, and a malformed
    line is still evidence that something died.

    An absent file returns nothing, which is the normal state of a stack that
    has not failed anything yet. An undecodable one does too: the file is
    append-only bytes, so a corrupt tail means the whole read is suspect, and
    "no failures shown" is the one wrong answer here that is at least visible
    as wrong.
    """
    if limit is None or limit < 1:
        return []
    try:
        with open(path, encoding="utf-8") as handle:
            lines = deque(handle, maxlen=limit)
    except (OSError, UnicodeDecodeError):
        return []

    out = []
    for line in lines:
        text = line.rstrip("\n")
        if not text.strip():
            continue
        fields = text.split("\t")
        if len(fields) >= 2:
            out.append({
                "at": fields[0].strip() or None,
                "name": fields[1].strip() or None,
                "reason": "\t".join(fields[2:]).strip() or None,
            })
        else:
            out.append({"at": None, "name": text.strip(), "reason": None})
    return out


# --- rendering --------------------------------------------------------------


def render_json(summary):
    """The summary as JSON, keys sorted so two runs diff cleanly.

    Sorted rather than insertion-ordered because the structure is assembled in
    several places and a diff of two runs should show what changed about the
    downloads, not the order the fields happened to be built in.

    ASCII escaping is left on (ensure_ascii, the default) so a release name
    outside ASCII cannot make the print itself fail on a host whose locale is
    C -- the NAS, where this is most likely to be run from a systemd unit.
    """
    return json.dumps(summary, indent=2, sort_keys=True) + "\n"


def esc(value):
    """Text safe to put in the page, as HTML and as ASCII.

    html.escape is the part that matters: release names come from indexers and
    are attacker-influenced text, so `The.Release.<script>alert(1)</script>`
    has to arrive as characters, not as markup. quote=True (the default) also
    escapes the quotes, because the same helper fills attribute values.

    The second half is the xmlcharrefreplace pass: it turns anything outside
    ASCII into a numeric reference, which renders identically and keeps the
    page byte-for-byte printable under a C locale. Without it, printing an
    accented release name on the NAS raises UnicodeEncodeError.
    """
    return (html.escape(str(value), quote=True)
            .encode("ascii", "xmlcharrefreplace")
            .decode("ascii"))


def _percent(value):
    """A progress figure for the page, or a dash when there is not one."""
    return "&mdash;" if value is None else f"{value:g}%"


def _hours(value):
    """A duration in hours for the page, or a dash when there is not one."""
    return "&mdash;" if value is None else f"{value:.1f}h"


# Inline, and the only stylesheet the page has. A status page that fetched a
# font or a framework from a CDN would be a page that renders differently (or
# not at all) on the NAS's LAN, which is where it is read from.
PAGE_CSS = """\
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body {
  margin: 0 auto; padding: 2rem 1rem 4rem; max-width: 62rem;
  font: 15px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  color: #16181d; background: #f6f7f9;
}
h1 { font-size: 1.4rem; margin: 0 0 .25rem; }
h2 { font-size: 1.05rem; margin: 2.5rem 0 .5rem; }
p.meta { margin: 0 0 1.5rem; color: #5c626e; }
p.empty { color: #5c626e; font-style: italic; }
table { width: 100%; border-collapse: collapse; background: #fff;
        border: 1px solid #dfe2e8; border-radius: 6px; overflow: hidden; }
th, td { padding: .5rem .75rem; text-align: left; border-bottom: 1px solid #eceef2;
         vertical-align: top; }
th { font-size: .78rem; text-transform: uppercase; letter-spacing: .04em;
     color: #5c626e; background: #fafbfc; }
tbody tr:last-child td { border-bottom: 0; }
td.num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
td.release { font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
             font-size: .86rem; word-break: break-all; }
span.state { display: block; margin-top: .15rem; color: #5c626e; font-size: .78rem; }
span.badge { display: inline-block; padding: .1rem .5rem; border-radius: 999px;
             font-size: .75rem; font-weight: 600; background: #e8eaef; color: #3b4049; }
/* Every status gets a rule of its own, unknown included: it restates the badge
   default, which is the point -- "no rule" and "deliberately neutral" would
   otherwise look the same in the stylesheet and in a test. */
tr.s-unknown span.badge { background: #e8eaef; color: #3b4049; }
tr.s-complete span.badge { background: #e3f4e6; color: #1c6b2c; }
tr.s-downloading span.badge { background: #e5eefc; color: #1b4f9c; }
tr.s-stalled span.badge { background: #fdf0da; color: #8a5300; }
tr.s-failed span.badge { background: #fbe4e4; color: #94231f; }
ul.failures { list-style: none; margin: 0; padding: 0; }
ul.failures li { padding: .4rem 0; border-bottom: 1px solid #eceef2;
                 font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                 font-size: .84rem; word-break: break-all; }
ul.failures span.when { color: #5c626e; }
ul.failures span.why { color: #94231f; }
footer { margin-top: 3rem; color: #5c626e; font-size: .8rem; }
"""


def _job_row(job):
    """One table row, with every state-derived value escaped."""
    status = job.get("status")
    if status not in STATUSES:
        status = STATUS_UNKNOWN
    name = esc(job.get("name") or "(unnamed)")
    key = esc(job.get("key") or "")
    state_name = job.get("download_state")
    # TorBox's own words, kept beside the release: "downloading" here is this
    # module's summary, and the state string is what the watcher will act on.
    detail = (f'<span class="state">TorBox: {esc(state_name)}</span>'
              if state_name else "")
    return (
        f'        <tr class="s-{status}">\n'
        f'          <td><span class="badge">{esc(status)}</span></td>\n'
        f'          <td class="release" title="key {key}">{name}{detail}</td>\n'
        f'          <td class="num">{_percent(job.get("progress_percent"))}</td>\n'
        f'          <td class="num">{_hours(job.get("age_hours"))}</td>\n'
        f'          <td class="num">{_hours(job.get("stalled_hours"))}</td>\n'
        f'        </tr>'
    )


def _failure_item(entry):
    """One failure-log line, escaped."""
    reason = (f' <span class="why">{esc(entry.get("reason"))}</span>'
              if entry.get("reason") else "")
    return (
        f'        <li><span class="when">{esc(entry.get("at") or "no timestamp")}'
        f'</span> <span class="release">{esc(entry.get("name") or "(unnamed)")}'
        f'</span>{reason}</li>'
    )


def render_html(summary):
    """A self-contained page: one inline stylesheet, no script, no network.

    Every value that came out of the state file passes through `esc`, including
    the ones that look numeric and the ones that look like timestamps: this
    function cannot see which field was attacker-influenced and which was
    written by the watcher, and the cost of escaping a safe value is nothing.
    """
    jobs = [job for job in summary.get("jobs") or [] if isinstance(job, dict)]
    totals = summary.get("totals")
    totals = totals if isinstance(totals, dict) else {}
    sources = summary.get("sources")
    sources = sources if isinstance(sources, dict) else {}
    failures = [entry for entry in summary.get("failures") or []
                if isinstance(entry, dict)]

    if jobs:
        body = (
            "    <table>\n"
            "      <thead>\n"
            "        <tr><th>Status</th><th>Release</th><th>Progress</th>"
            "<th>Age</th><th>Since progress</th></tr>\n"
            "      </thead>\n"
            "      <tbody>\n"
            + "\n".join(_job_row(job) for job in jobs) + "\n"
            "      </tbody>\n"
            "    </table>"
        )
    else:
        body = ('    <p class="empty">No jobs in the state file. Either nothing '
                'is in flight, or the file is not there yet.</p>')

    if failures:
        failures_html = ("    <ul class=\"failures\">\n"
                         + "\n".join(_failure_item(entry) for entry in failures)
                         + "\n    </ul>")
    else:
        failures_html = ('    <p class="empty">No failures in the log tail.</p>')

    counts = " &middot; ".join([
        f'{totals.get("jobs", 0)} job(s)',
        f'{totals.get("in_flight", 0)} in flight',
        f'{totals.get("complete", 0)} complete',
        f'{totals.get("stalled", 0)} stalled',
        f'{totals.get("failed", 0)} failed',
    ])
    stall = summary.get("stall_hours")

    return (
        "<!DOCTYPE html>\n"
        '<html lang="en">\n'
        "<head>\n"
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        "<title>Usenet blackhole status</title>\n"
        "<style>\n" + PAGE_CSS + "</style>\n"
        "</head>\n"
        "<body>\n"
        "  <h1>Usenet blackhole</h1>\n"
        f'  <p class="meta">Generated {esc(summary.get("generated_at") or "unknown")}'
        f' &middot; {counts} &middot; stall threshold {esc(stall)}h</p>\n'
        + body + "\n"
        "  <h2>Recent failures</h2>\n"
        + failures_html + "\n"
        "  <footer>\n"
        "    Read-only view: nothing on this page changes a download.\n"
        f'    State: {esc(sources.get("state") or "unknown")}.'
        f' Failures: {esc(sources.get("failed_log") or "unknown")}.\n'
        "  </footer>\n"
        "</body>\n"
        "</html>\n"
    )


RENDERERS = {"json": render_json, "html": render_html}


def positive_hours(value):
    """The stall threshold from argv, or None if it is not a usable one.

    The same rule usenet_blackhole.positive_hours applies to the watcher's
    --stall-hours, and for the same reason: zero is the one value that turns the
    stall rule into "every job is stalled the moment its clock starts", so a
    view run with it would paint the whole page stalled while the watcher went
    on working. `not hours > 0` rather than `hours <= 0` so nan is refused too --
    it parses as a float, compares false against everything, and would read as a
    threshold no job ever crosses. Non-finite values are refused outright: inf
    is the same "never stalled" answer, and either one re-serialises into JSON
    (in `stall_hours`) that most parsers reject.
    """
    try:
        hours = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(hours) or not hours > 0:
        return None
    return hours


def main(argv):
    """Render one view and print it. Returns the process exit status.

    argv errors exit 2 with a message on stderr, the convention
    backlog_search.py and the shell wrappers here follow; a missing state file
    is not an error, because an empty state file and no state file are the same
    fact about the downloads.

    --stall-hours is pulled out of argv wherever it appears, so the positional
    order this module has always had -- format, state path, failed-log path --
    keeps working unchanged, with or without the flag.
    """
    positionals = []
    stall_hours = STALL_HOURS
    index = 0
    while index < len(argv) - 1:
        arg = argv[1 + index]
        if arg == "--stall-hours" or arg.startswith("--stall-hours="):
            if arg == "--stall-hours":
                if 2 + index >= len(argv):
                    print("--stall-hours needs a number", file=sys.stderr)
                    return 2
                raw = argv[2 + index]
                index += 1
            else:
                raw = arg.split("=", 1)[1]
            parsed = positive_hours(raw)
            if parsed is None:
                print(f"--stall-hours must be a number greater than 0, "
                      f"got {raw!r}", file=sys.stderr)
                return 2
            stall_hours = parsed
        else:
            positionals.append(arg)
        index += 1

    if not positionals:
        print(__doc__, file=sys.stderr)
        return 2

    fmt = positionals[0].strip().lower()
    if fmt not in RENDERERS:
        print(f"format must be json or html, got {positionals[0]!r}",
              file=sys.stderr)
        return 2

    state_path = positionals[1] if len(positionals) > 1 and positionals[1] \
        else DEFAULT_STATE_PATH
    failed_log = positionals[2] if len(positionals) > 2 and positionals[2] \
        else DEFAULT_FAILED_LOG

    summary = summarize(
        load_state(state_path),
        datetime.now(timezone.utc),
        stall_hours=stall_hours,
        failures=load_failures(failed_log),
    )
    # Which files produced this page. Added here rather than inside summarize,
    # which is pure and has no paths to report; a view read from a different
    # directory than it was generated in is otherwise ambiguous.
    summary["sources"] = {"state": state_path, "failed_log": failed_log}

    print(RENDERERS[fmt](summary), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
