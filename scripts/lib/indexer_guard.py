#!/usr/bin/env python3
"""Decide whether Prowlarr's indexer backoffs are evidence of a banned VPN IP.

Why this exists
---------------
The public torrent indexers in this stack sit behind Cloudflare, and Prowlarr
reaches them through the VPN. When the exit IP is one Cloudflare has already
banned, every indexer behind it starts failing at once, and the only fix is a
new exit IP: a VPN reconnect, which drops every connection in the stack, makes
the arrs re-establish theirs, and leaves their indexer tests failing until it
is done.

That is disruptive enough that it must not happen on a hunch. A slow indexer,
a timeout, a 500 from the indexer's own origin and an ordinary Cloudflare
challenge all look the same from here -- "that search failed" -- and all of
them clear on their own. Rotating for one of those spends an outage on
nothing, and the new exit IP can be worse than the one it replaced.

So the evidence is narrow. Cloudflare error 1006 means the IP itself is
banned, which is a different fact from a challenge a browser would pass; an
HTTP 403, or the word "forbidden", is the same refusal in plainer words, and
the word "cloudflare" itself is read as that family of refusal too. A
challenge is not evidence at all -- this stack runs FlareSolverr to solve
them, so a healthy install produces challenge pages during normal operation.
BAN_PATTERNS holds exactly those four and `looks_like_ban` is the only thing
that decides what counts. On top of that a rotation is rate limited
(DEFAULT_COOLDOWN_HOURS): a banned IP stays banned, so reconnecting twice in
ten minutes cannot fix anything and does cost two outages.

Deciding, not doing
-------------------
Nothing here fetches or rotates: no HTTP, no socket, no subprocess. The shell
wrapper that runs this makes the two Prowlarr calls with curl and pipes the
documents in, and this module answers one question about them -- rotate now,
or not, and why. Nothing here opens .env or reads an API key, and no failure
text is ever echoed: a Prowlarr message can carry the request URL, an indexer
URL carries its API key, so the only thing that leaves the message is a
boolean.

The decision path reads the state file and never writes it. Writing is its own
mode (--record-rotation), which the wrapper calls only after it has cycled the
VPN: a module that could mark a rotation on the decision path would make the
cooldown a lie.

Usage:
  indexer_guard.py [--statuses PATH|-] [--indexers PATH|-] [--state PATH]
                   [--cooldown-hours N] [--now TIMESTAMP] [--json]
  indexer_guard.py --state PATH --record-rotation [--now TIMESTAMP]
  indexer_guard.py --verdict PATH|-

--statuses defaults to stdin, so the everyday invocation is a pipe:

  curl -sS -H "X-Api-Key: $PROWLARR_API_KEY" \\
      "$PROWLARR_URL/api/v1/indexerstatus" \\
    | python3 scripts/lib/indexer_guard.py --indexers /tmp/indexers.json \\
        --state logs/indexer-guard-state.json --json

--indexers is optional: without it the indexer definitions are unknown and a
blocked record is labelled `indexer 7` from its own id. --cooldown-hours takes
a number above zero; zero is refused at the argument rather than read as "no
cooldown", because a cooldown of zero is a rotation on every pass that has a
failed indexer in it.

--record-rotation writes a rotation into --state and exits; it is the mode the
wrapper calls once the VPN has been cycled, and it is the only thing here that
writes anything. --verdict turns a --json decision document back into the
wrapper's one-line `rotate`/`hold` verdict. Both read their input the way the
decision does: a path, or `-` for stdin.

--now is the moment to act as now, as an ISO timestamp, for any of those
modes; the default is the real clock, and a naive timestamp is read as UTC.

The exit status is 0 for any decision that was reached, `rotate` included: the
decision is the output, and a wrapper that read a rotation as a failure would
have it exactly backwards. Bad argv, and a --verdict document that is not one,
are 2. A rotation that could not be written is 1.
"""

import argparse
import json
import math
import os
import re
import sys
from datetime import datetime, timezone

# Evidence of an IP-level block, and the whole of it. Every pattern is
# case-insensitive because Prowlarr repeats the indexer's own words, and those
# arrive in every case there is.
#
# A Cloudflare challenge is deliberately not one of these. It is not an IP ban
# -- this stack runs FlareSolverr to solve challenges -- so matching
# "challenge" would rotate the VPN during normal operation, which is exactly
# the outage the narrow evidence exists to avoid.
#
# The 1006 pattern is bounded on both sides by "not a digit" rather than by
# \b: error 1006 is Cloudflare saying the IP is banned, while 21006 is a
# number that happens to end in it -- a Cloudflare ray id, a byte count, an
# indexer id in a URL. \b would not separate those (both sides are digits, so
# there is no boundary inside 21006 to match at), and punishing a \b with a
# lookahead would also stop the pattern matching the ordinary "error 1006."
# at the end of a sentence.
BAN_PATTERNS = (
    re.compile(r"cloudflare", re.IGNORECASE),
    # IGNORECASE is a no-op on a pattern with no letters; it is here so the
    # tuple is uniformly case-insensitive, which is the property a caller (and
    # the test) reads off it.
    re.compile(r"(?<!\d)1006(?!\d)", re.IGNORECASE),
    re.compile(r"\b403\b", re.IGNORECASE),
    re.compile(r"forbidden", re.IGNORECASE),
)

# The minimum time between two rotations. Six hours is one VPN session: long
# enough that a burst of indexer failures cannot cause a reconnect loop, short
# enough that a genuinely banned IP is not held for the rest of the day. It is
# a *minimum*, not a schedule -- nothing rotates on a timer, and this only
# decides whether a rotation that is otherwise justified may happen yet.
DEFAULT_COOLDOWN_HOURS = 6.0

# Only a convenience for a hand-run from the stack root. The wrapper passes
# absolute paths, because a timer has no meaningful working directory.
DEFAULT_STATE_PATH = "logs/indexer-guard-state.json"

# A missing indexer definition still has to be called something in the
# decision line, and the record's own id is the one label it always has.
UNKNOWN_INDEXER = "unknown indexer"


def parse_time(value):
    """A datetime for an ISO timestamp, or None if it is not one.

    A naive timestamp is read as UTC, the convention the other modules here
    use: Prowlarr writes timezone-aware values, so a naive one means something
    else wrote it, and reading it as local time would shift every backoff by
    the host's offset.

    The trailing-Z form is rewritten rather than left to fromisoformat, which
    did not accept it before Python 3.11. Prowlarr's own timestamps arrive in
    that shape.
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


def _utc(moment):
    """`moment` as an aware UTC datetime; a naive one is read as UTC."""
    if moment.tzinfo is None:
        return moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(timezone.utc)


def looks_like_ban(text):
    """Whether a failure message is evidence of an IP-level block.

    A pure predicate over text: no record, no clock, no state. None and the
    empty string are not evidence, and neither is anything that is not text at
    all -- a number in a field the caller guessed at must not match 1006 by
    being 1006.
    """
    if not isinstance(text, str) or not text:
        return False
    return any(pattern.search(text) for pattern in BAN_PATTERNS)


def _strings(value, depth=0):
    """Every string inside a decoded JSON value, at any sane depth.

    The scan is over values rather than a named field because Prowlarr's
    payload has changed shape before: the failure text has arrived under more
    than one key, and a version that only looked at `message` would go quiet
    the day that key is renamed. Depth is bounded so a self-referential or
    absurdly nested document cannot turn a decision into a stack walk.

    Numbers are not stringified into the scan: a status record carries its own
    `id`, and an install with a thousand indexer-status rows has a row with
    id 1006 in it. That is a record number, not Cloudflare's, and rotating the
    VPN over it would be the exact false positive this module exists to avoid.
    """
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict) and depth < 4:
        for item in value.values():
            yield from _strings(item, depth + 1)
    elif isinstance(value, (list, tuple)) and depth < 4:
        for item in value:
            yield from _strings(item, depth + 1)


def record_ban_evidence(record):
    """Whether a status record's own text is evidence of an IP-level block.

    True means the record says Cloudflare, 1006, 403 or forbidden somewhere;
    it says nothing about which indexer, which is the caller's job.
    """
    if not isinstance(record, dict):
        return False
    return any(looks_like_ban(text) for text in _strings(record))


def _as_id(value):
    """An indexer id as an int, or None when the value is not one.

    Prowlarr sends ints. A digit string is accepted anyway because the same
    document round-tripped through a shell or a JSON viewer comes back with
    quotes, and an id that is not recognised is the difference between "1337x"
    and "indexer 7" in the decision line. `True` is an int in Python and is
    not an id.
    """
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        text = value.strip()
        if text.lstrip("-").isdigit():
            return int(text)
    return None


def _records(value):
    """The records in a decoded JSON document, as a list of dicts.

    A list is the documented shape of both endpoints; a dict is tolerated
    because a document keyed by id is the same data and costs one isinstance
    to accept. Anything else -- None, a number, a truncated string -- is no
    records, not an exception: this runs on a timer against a service whose
    output nobody is watching.
    """
    if isinstance(value, dict):
        value = list(value.values())
    if not isinstance(value, (list, tuple)):
        return []
    return [item for item in value if isinstance(item, dict)]


def _indexer_names(indexers):
    """{id: name} from the GET /api/v1/indexer document, best effort.

    An entry with no id or a blank name is skipped rather than guessed at: the
    fallback label already says the name is unknown, and a half-read entry
    would put the wrong name on the right id.
    """
    names = {}
    for entry in _records(indexers):
        key = _as_id(entry.get("id"))
        name = entry.get("name")
        if key is not None and isinstance(name, str) and name.strip():
            names[key] = name.strip()
    return names


def _label(key, names):
    """What to call an indexer: its name, or its id, or that neither is known."""
    name = names.get(key) if key is not None else None
    if name:
        return name
    return f"indexer {key}" if key is not None else UNKNOWN_INDEXER


def blocked_indexers(statuses, indexers, now):
    """The indexers Prowlarr currently has in backoff, from its own documents.

    "Currently" is `disabledTill` strictly in the future of `now`: a record
    whose backoff has just elapsed is not blocking anything, and one that is
    exactly on `now` has not a moment left either. A record with no
    disabledTill, a null one, or one that does not parse is skipped -- those
    records exist in the payload (a failure that is still being counted, with
    no disable), and there is no backoff length to report for them.

    Each row carries the resolved name, the moment the backoff ends, how long
    that is from `now`, and whether the record's own text is ban evidence. The
    failure text itself is deliberately not carried: it can contain the
    indexer URL, and the indexer URL contains the API key.

    Pure: `now` is a parameter, so the same documents and the same instant
    always produce the same rows.
    """
    now = _utc(now)
    names = _indexer_names(indexers)
    rows = []
    for record in _records(statuses):
        until = parse_time(record.get("disabledTill"))
        if until is None or until <= now:
            continue
        key = _as_id(record.get("indexerId"))
        rows.append({
            "indexer_id": key,
            "name": _label(key, names),
            "status_id": _as_id(record.get("id")),
            "disabled_till": until,
            "hours_remaining": round((until - now).total_seconds() / 3600.0, 1),
            "initial_failure": parse_time(record.get("initialFailure")),
            "most_recent_failure": parse_time(record.get("mostRecentFailure")),
            "ban_evidence": record_ban_evidence(record),
        })
    # Named order, then id, so two runs over the same documents produce the
    # same list: the decision line is read in a log next to the previous run's.
    rows.sort(key=lambda row: (row["name"].lower(),
                               row["indexer_id"] if row["indexer_id"] is not None
                               else -1))
    return rows


def last_rotation_time(value):
    """The recorded last rotation as an aware datetime, or None.

    None for no value at all, and None for a value that is not a timestamp --
    the caller has to tell those apart, because "never rotated" and "a
    timestamp nobody can read" call for opposite answers.

    A datetime is accepted as well as the string the state file stores,
    because a caller that already parsed the state passes the datetime it has
    and must not be silently read as "unreadable".
    """
    if isinstance(value, datetime):
        return _utc(value)
    if value is None or (isinstance(value, str) and not value.strip()):
        return None
    return parse_time(value)


def should_rotate(blocked, last_rotation, now, cooldown_hours=DEFAULT_COOLDOWN_HOURS):
    """Whether to rotate the VPN, and a one-line reason either way.

    True needs both halves: at least one blocked indexer whose failure is ban
    evidence, and a cooldown that has expired. Blocked indexers alone are not
    enough -- a timeout is a slow indexer, not a banned IP -- and evidence
    alone is not enough either, because a rotation five minutes after the last
    one cannot produce a different IP that Cloudflare likes better.

    `last_rotation` is the state file's timestamp, as a datetime or as the
    string it was stored as; None means this stack has never rotated, which
    cannot be inside a cooldown. A value that is present but unreadable blocks
    the rotation instead: the one irreversible action here must not be taken
    because the record of the last one was garbled.

    The boundary is inclusive (`elapsed >= cooldown_hours`): the cooldown is a
    minimum time between rotations, and a rotation exactly on it is a rotation
    that waited. cooldown_hours must be finite and above zero -- the CLI
    refuses anything else at the argument with positive_hours, and a ValueError
    here is the same refusal at the function, so a caller cannot pass 0 and
    quietly get "every pass may rotate".
    """
    if not isinstance(cooldown_hours, (int, float)) or isinstance(cooldown_hours, bool) \
            or not math.isfinite(cooldown_hours) or not cooldown_hours > 0:
        raise ValueError(f"cooldown_hours must be a number above 0, "
                         f"got {cooldown_hours!r}")

    now = _utc(now)
    rows = [row for row in blocked or () if isinstance(row, dict)]
    banned = [row for row in rows if row.get("ban_evidence") is True]
    cooldown = f"{cooldown_hours:g}h"

    if not banned:
        if not rows:
            return False, ("no indexer is in backoff, so there is nothing to "
                           "rotate for")
        names = ", ".join(row.get("name") or UNKNOWN_INDEXER for row in rows)
        return False, (f"{names} in backoff with no ban evidence (a timeout or "
                       f"a plain error is not an IP ban); not rotating")

    names = ", ".join(row.get("name") or UNKNOWN_INDEXER for row in banned)
    if last_rotation is None or (isinstance(last_rotation, str)
                                 and not last_rotation.strip()):
        return True, (f"{names} show ban evidence and no rotation has been "
                      f"recorded yet; rotating")

    since = last_rotation_time(last_rotation)
    if since is None:
        return False, (f"{names} show ban evidence but the recorded last "
                       f"rotation ({last_rotation!r}) is not a timestamp, so "
                       f"the {cooldown} cooldown cannot be checked; not rotating")

    elapsed = (now - _utc(since)).total_seconds() / 3600.0
    if elapsed >= cooldown_hours:
        return True, (f"{names} show ban evidence and the {cooldown} cooldown "
                      f"has expired (last rotation {elapsed:.1f}h ago); rotating")
    return False, (f"{names} show ban evidence but the {cooldown} cooldown has "
                   f"{cooldown_hours - elapsed:.1f}h left (last rotation "
                   f"{elapsed:.1f}h ago); not rotating")


# --- the state file ---------------------------------------------------------


def empty_state():
    """The state of a stack that has never rotated. Also the loader's fallback."""
    return {"last_rotation": None, "rotations": 0}


def _rotation_count(value):
    """The rotation count as a non-negative int, or 0.

    A bool is an int in Python, a negative count is not something a counter
    can be, and a string is what a hand-edited file produces -- all three read
    as 0 rather than raising. The count is bookkeeping; the timestamp beside
    it is what the cooldown is made of.
    """
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return 0
    return value


def load_state(path):
    """The rotation state, or an empty one.

    An absent file, an empty one, a truncated write, a JSON array where an
    object was expected: every one of them is "this stack has never recorded a
    rotation", which is also exactly what a fresh install looks like. The
    alternative -- raising -- would stop the guard on the first pass after its
    own state file was damaged, which is the pass most likely to be a real
    ban. Unknown keys are kept so a later version's state survives a read by
    this one.
    """
    state = empty_state()
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return state
    if not isinstance(data, dict):
        return state
    raw = data.get("last_rotation")
    data["last_rotation"] = raw.strip() if isinstance(raw, str) and raw.strip() else None
    data["rotations"] = _rotation_count(data.get("rotations"))
    return data


def save_state(path, state):
    """Write the state atomically, or raise OSError.

    Atomic because the timestamp is what enforces the cooldown: a half-written
    file read back on the next pass would look like a stack that has never
    rotated, which is the one wrong answer that ends in a second reconnect.
    Written by the caller that performs a rotation, not by anything in this
    module's decision path.
    """
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(state, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)


def record_rotation(state, now):
    """A copy of `state` with this rotation recorded. Writes nothing.

    The shape lives here rather than in the wrapper so the writer and the
    reader cannot disagree about it: `last_rotation` is the moment, as ISO
    with an offset, and `rotations` is how many times this stack has done it
    -- a number nobody decides anything on, kept because "the VPN has rotated
    nine times this week" is a fact an operator wants without grepping a log.
    """
    updated = dict(state) if isinstance(state, dict) else {}
    updated["last_rotation"] = _utc(now).isoformat()
    updated["rotations"] = _rotation_count(updated.get("rotations")) + 1
    return updated


def positive_hours(value):
    """argparse type for --cooldown-hours: a number, and strictly above zero.

    The same rule usenet_blackhole.positive_hours applies to --stall-hours,
    and the same accept/reject set: zero and below are refused, and nan and
    inf with them. Zero here is the one value that turns the cooldown into
    "rotate whenever there is a failed indexer", which is a reconnect loop
    with a VPN session in it; nan compares false against everything and would
    read as a cooldown nothing ever reaches.

    Unlike that function this one raises, because it is handed to argparse as
    a type: the refusal has to happen at the argument, before a decision is
    ever computed, and argparse turns ArgumentTypeError into exit 2.
    """
    try:
        hours = float(value)
    except (TypeError, ValueError):
        raise argparse.ArgumentTypeError(f"not a number: {value!r}")
    if not math.isfinite(hours) or not hours > 0:  # `not >` so nan is caught too
        raise argparse.ArgumentTypeError(
            f"must be a number greater than 0, got {value!r}")
    return hours


def _timestamp_arg(value):
    """argparse type for --now: an ISO timestamp, through parse_time.

    parse_time is the one timestamp reader this module has, and the state
    file's own timestamps go through it. A bare word is refused at the
    argument rather than read as "the real clock": silently falling back would
    make `--now yesterday` record a rotation at the moment the command ran,
    which is a cooldown nobody asked for.
    """
    moment = parse_time(value)
    if moment is None:
        raise argparse.ArgumentTypeError(f"not a timestamp: {value!r}")
    return moment


# --- the command line -------------------------------------------------------


def _read_json(path, label):
    """A parsed JSON document from a file, or from stdin when path is `-`.

    Returns (document, error). An unreadable or unparseable document is an
    error rather than an empty one: this is the caller's input, not Prowlarr's
    output -- a wrapper that fetched nothing has a bug, and reading that as
    "no indexers are blocked" is a silent one.
    """
    if path is None or path == "-":
        source = "stdin"
        text = sys.stdin.read()
    else:
        source = path
        try:
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
        except OSError as err:
            return None, f"cannot read {label} from {source}: {err}"
    try:
        return json.loads(text), None
    except ValueError as err:
        return None, f"{label} from {source} is not JSON: {err}"


def _plain(value):
    """The decision as JSON-safe data: datetimes become ISO strings."""
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, dict):
        return {key: _plain(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_plain(item) for item in value]
    return value


def decision(statuses, indexers, state, now, cooldown_hours):
    """The whole answer as plain data, for either renderer.

    Pure, and the only place the two documents meet: everything the CLI prints
    is derived here, so the JSON and the text line cannot disagree about what
    was decided.
    """
    blocked = blocked_indexers(statuses, indexers, now)
    last_rotation = state.get("last_rotation") if isinstance(state, dict) else None
    rotate, reason = should_rotate(blocked, last_rotation, now, cooldown_hours)
    return {
        "decided_at": now.isoformat(),
        "rotate": rotate,
        "reason": reason,
        "cooldown_hours": cooldown_hours,
        "last_rotation": last_rotation,
        "rotations": state.get("rotations", 0) if isinstance(state, dict) else 0,
        "blocked": blocked,
    }


def render_text(view):
    """The decision as one line plus, when there are any, the blocked indexers.

    The reason is the line that matters and is printed for both answers: a
    wrapper's log is read to find out why the VPN did or did not move, and
    "hold" with no reason is indistinguishable from a guard that is broken.
    """
    lines = [f"{'rotate' if view['rotate'] else 'hold'}: {view['reason']}"]
    for row in view["blocked"]:
        evidence = ", ban evidence" if row["ban_evidence"] else ""
        lines.append(f"  {row['name']} (id {row['indexer_id']}): "
                     f"{row['hours_remaining']}h of backoff left{evidence}")
    return "\n".join(lines)


def verdict_line(view):
    """A --json decision document as the wrapper's one-line verdict.

    Returns (line, error). The line is the rotate/hold word, a tab, and the
    reason -- the shape the wrapper splits on, and the tab is what stops a
    reason that opens with a word like "rotate" from reading as the verdict
    itself. A document with no usable rotate flag or reason is an error rather
    than a hold: a guard that quietly holds when it cannot read its own
    decision is a guard that has stopped working, and nothing would say so.
    """
    rotate = view.get("rotate") if isinstance(view, dict) else None
    reason = view.get("reason") if isinstance(view, dict) else None
    if rotate not in (True, False) or not isinstance(reason, str):
        return None, "the decision carried no rotate flag and reason"
    return ("rotate" if rotate else "hold") + "\t" + reason, None


def main(argv=None):
    """Read the two documents and print the decision. Returns the exit status.

    Three modes share the one parser: the default decides, --record-rotation
    writes the rotation the wrapper has just performed, and --verdict renders
    a decision document the wrapper already has. argparse owns the argv
    refusals and exits 2 for them, which is caught here and returned, so
    `main()` is callable from a test without a SystemExit to catch -- the
    convention usenet_status.py's main follows.
    """
    parser = argparse.ArgumentParser(
        prog="indexer_guard.py",
        description=__doc__.split("\n")[0],
    )
    parser.add_argument("--statuses", default="-", metavar="PATH",
                        help="GET /api/v1/indexerstatus, as JSON (default: "
                             "stdin, or - for stdin)")
    parser.add_argument("--indexers", default=None, metavar="PATH",
                        help="GET /api/v1/indexer, as JSON, for the names "
                             "(default: none, and blocked indexers are "
                             "labelled by id)")
    parser.add_argument("--state", default=DEFAULT_STATE_PATH, metavar="PATH",
                        help="the rotation state (default: %(default)s); it is "
                             "read by the decision and written only by "
                             "--record-rotation")
    parser.add_argument("--cooldown-hours", type=positive_hours,
                        default=DEFAULT_COOLDOWN_HOURS, metavar="N",
                        help="the minimum hours between two rotations "
                             "(default: %(default)s)")
    parser.add_argument("--record-rotation", action="store_true",
                        help="record a rotation in --state and exit, printing "
                             "the new count; the caller must have performed "
                             "one")
    parser.add_argument("--verdict", default=None, metavar="PATH",
                        help="a --json decision document, rendered back as one "
                             "rotate/hold line (default: none)")
    parser.add_argument("--now", type=_timestamp_arg, default=None,
                        metavar="TIMESTAMP",
                        help="the moment to act as now, as an ISO timestamp "
                             "(default: the real clock)")
    parser.add_argument("--json", action="store_true",
                        help="print the decision as JSON instead of a line")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        # argparse's own exit(2), and its exit(0) for --help, turned into a
        # return value. The status is unchanged for the process: the caller
        # below hands whatever this returns to sys.exit.
        return exc.code if isinstance(exc.code, int) else 2

    now = args.now if args.now is not None else datetime.now(timezone.utc)

    # Writing the rotation is its own mode, and only the wrapper can know that
    # a rotation happened: this module cannot tell one from a decision, and
    # marking a rotation nobody performed would make the cooldown a lie.
    if args.record_rotation:
        updated = record_rotation(load_state(args.state), now)
        try:
            save_state(args.state, updated)
        except OSError as err:
            print(f"ERROR: cannot record the rotation in {args.state}: {err}",
                  file=sys.stderr)
            return 1
        # The count alone, which is what the wrapper logs. A caller that asked
        # for a write is not owed a decision document.
        print(updated["rotations"])
        return 0

    if args.verdict is not None:
        document, error = _read_json(args.verdict, "decision")
        if error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 2
        line, error = verdict_line(document)
        if error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 2
        print(line)
        return 0

    statuses, error = _read_json(args.statuses, "indexerstatus")
    if error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    indexers = []
    if args.indexers is not None:
        indexers, error = _read_json(args.indexers, "indexer")
        if error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 2

    view = decision(statuses, indexers, load_state(args.state),
                    now, args.cooldown_hours)
    if args.json:
        print(json.dumps(_plain(view), indent=2, sort_keys=True))
    else:
        print(render_text(view))
    return 0


if __name__ == "__main__":
    sys.exit(main())
