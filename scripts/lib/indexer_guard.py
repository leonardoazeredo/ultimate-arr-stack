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

Coordinating with the rotator
-----------------------------
A second actor cycles this same tunnel. gluetun-rotator in
docker-compose.utilities.yml restarts gluetun every
GLUETUN_ROTATE_INTERVAL_SECONDS (six hours by default) to pick a new exit
server, and it knows nothing about bans. Both actors write the moment of a
rotation into one shared file, and the wrapper passes that value here as
`rotator_last`. Without it, a guard rotation can land minutes before the
rotator's own restart -- two tunnel cycles back to back -- or minutes after
one, which rotates on ban evidence gathered through an IP that was already
being replaced. So the guard holds when the rotator's restart is inside
`rotator_window_minutes` (default 30), and holds again for that long after any
rotation, because Prowlarr needs time to fail against the new IP before its
ban evidence means anything.

The guard's own cooldown is untouched by this: `rotator_last` never extends
it, and the cooldown is still measured from the rotations this guard itself
recorded. A missing, empty or non-integer `rotator_last` is "no known
rotation", which decides exactly as this module did before the two actors knew
about each other.

Nothing here opens that file. The wrapper reads it, and passes the value in.

The demand gate
---------------
A banned IP only costs this stack something if an indexer it actually uses is
behind it. Rotating for an indexer nothing here has ever downloaded from spends
an outage -- every connection in the stack drops, the arrs re-establish theirs
-- to fix a search that was never going to be made. So a rotation now needs one
more fact than ban evidence: demand.

An indexer has demand when Sonarr both needs something and has used that
indexer for it. Both halves are joins on the series, and both come from Sonarr's
own documents, fetched by the wrapper:

  * GET /api/v3/wanted/missing?monitored=true -- one record per monitored
    episode Sonarr is still looking for. It says which series are incomplete
    right now. Unmonitored and already-downloaded episodes are not in it, so
    "Sonarr is missing this" is the endpoint's answer, not this module's.
  * GET /api/v3/history?eventType=1 -- one record per grab, carrying the series
    it was for and the indexer that supplied it in `data.indexer`. Sonarr's copy
    of a Prowlarr indexer is named "EZTV (Prowlarr)" where Prowlarr's own
    document says "EZTV", so one trailing " (Prowlarr)" comes off before the
    names are compared, and the comparison is case-insensitive after trimming.

Both endpoints are paginated, and the walk follows the documents' own count
rather than a fixed number of pages: page 1's envelope carries `totalRecords`,
the size of the whole document, the wrapper asks this module's --page-total mode
for that one integer, and it fetches only the pages the count requires --
bounded by its own DEMAND_MAX_PAGES and by one shared time budget for the pass,
so a slow Sonarr costs one bounded wait rather than one per page. This module
reads the same count, and that is what stops a short walk from becoming a false
hold: a document whose pages hold fewer records than the largest totalRecords
they claim was read short, and demand is UNKNOWN -- fail open, exactly as an
unreachable Sonarr is -- with a note naming the document and both counts
("Sonarr history truncated: 5000 of 7120 records"). Judging the join on those
pages instead would report "no demand" for an indexer whose grabs are all on the
pages nobody fetched, which holds a banned IP in place while every indexer
behind it fails. A bare array makes no claim about the whole document and is
taken as complete.

If that data is absent -- Sonarr unreachable, no API key, a document that is not
JSON, a walk that stopped short -- the gate is SKIPPED and the decision is the
one this module made before the gate existed, with a note in the reason and the
document saying demand was unknown. That direction is deliberate: a Sonarr that
is down for a minute must not ground a banned IP for every indexer the stack
does use. The gate is also applied only after the cooldown and the rotator's
windows have had their say, so it can turn a rotation into a hold and never the
other way round.

Usage:
  indexer_guard.py [--statuses PATH|-] [--indexers PATH|-] [--state PATH]
                   [--cooldown-hours N] [--rotator-last EPOCH]
                   [--rotator-interval SECONDS]
                   [--rotator-window-minutes MINUTES]
                   [--demand-missing PATH]... [--demand-history PATH]...
                   [--demand-error TEXT]
                   [--now TIMESTAMP] [--json]
  indexer_guard.py --state PATH --record-rotation [--now TIMESTAMP]
  indexer_guard.py --verdict PATH|-
  indexer_guard.py --page-total PATH|-

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

--rotator-last is the epoch-seconds timestamp the wrapper read out of the file
the two actors share; omit it and the rotator's schedule is not consulted at
all, which is the behaviour of a stack that has not rotated through either
actor yet. --rotator-interval is that service's own restart interval, and
--rotator-window-minutes is how close either event has to be to count as
"about to happen" or "just happened". Both are validated like the cooldown:
zero and below are refused at the argument.

--demand-missing and --demand-history carry Sonarr's two documents, one page
per flag: the wrapper fetches GET /api/v3/wanted/missing?monitored=true and
GET /api/v3/history?eventType=1, writes each page to its own file, and repeats
the flag for each one. Both families together are one demand input: with only
one of them there is no join to make, and the gate is skipped. A set of pages
that holds fewer records than the largest `totalRecords` its envelopes claim is
a document read short, and that is unknown demand too: a join over part of a
history is a join that silently under-reports demand, and the difference between
"this indexer has none" and "this indexer's grabs are on the pages nobody
fetched" is a rotation that should have happened. --demand-error is the
wrapper's own note that it could not fetch them at all, and skips the gate the
same way. Absent every one of these flags, nothing here consults demand and the
decision is byte-for-byte the one this module made before the gate existed;
supplied but unusable, they are "demand unknown" -- a skip with a note, never a
hold.

--page-total prints one Sonarr page envelope's `totalRecords` as an integer and
exits. It is the wrapper's paging half: the walk needs the size of the whole
document to know how many pages to fetch, and this script does no JSON parsing
of its own, so that one integer is read here. A document that is not an envelope
with a usable count -- a bare array, a missing or non-numeric field, something
that is not JSON at all -- is an error (exit 2) rather than a zero: the caller
treats a failure as a Sonarr it could not read and skips the gate, and a zero it
invented here would instead read as "the document is empty" and become a hold.

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
#
# It is measured from the guard's own recorded rotations and from nothing
# else: the rotator's shared timestamp is not a second source for it.
DEFAULT_COOLDOWN_HOURS = 6.0

# The rotator's schedule, as the two actors agree on it. gluetun-rotator
# restarts gluetun GLUETUN_ROTATE_INTERVAL_SECONDS after the last rotation
# either actor recorded, and the guard holds while that restart is inside
# DEFAULT_ROTATOR_WINDOW_MINUTES. Both defaults have to match the ones in
# docker-compose.utilities.yml, or the hold describes a schedule that is not
# the real one.
DEFAULT_ROTATOR_INTERVAL_SECONDS = 21600
DEFAULT_ROTATOR_WINDOW_MINUTES = 30.0

# The two coordination holds, as the decision document names them: the
# rotator's own restart is inside the window ("imminent"), or a rotation by
# either actor is ("recent").
ROTATOR_IMMINENT = "imminent"
ROTATOR_RECENT = "recent"

# Only a convenience for a hand-run from the stack root. The wrapper passes
# absolute paths, because a timer has no meaningful working directory.
DEFAULT_STATE_PATH = "logs/indexer-guard-state.json"

# A missing indexer definition still has to be called something in the
# decision line, and the record's own id is the one label it always has.
UNKNOWN_INDEXER = "unknown indexer"

# What Sonarr appends to a Prowlarr indexer's name. Prowlarr pushes its
# indexers into Sonarr with its own name plus this suffix, so the demand join
# compares "EZTV (Prowlarr)" with Prowlarr's "EZTV". It is matched exactly as
# Sonarr writes it and only at the END of a name: a "(Prowlarr)" in the middle
# is part of the name, and a name that merely ends in something similar is not
# this suffix.
PROWLARR_SUFFIX = " (Prowlarr)"

# Said in the reason and the document when the wrapper could not say why there
# is no demand data. Never an empty string: the note has to read as a sentence.
DEMAND_UNKNOWN = "no Sonarr demand data was supplied"


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


def normalise_indexer_name(name):
    """An indexer name as the demand join compares it.

    Sonarr's copy of a Prowlarr indexer is named "EZTV (Prowlarr)"; Prowlarr's
    own document says "EZTV". One trailing PROWLARR_SUFFIX comes off, the rest
    is trimmed and case-folded, and the result is what the two documents are
    joined on -- so " eztv " and "EZTV (Prowlarr)" are the same indexer, and
    "EZTV (Prowlarr) HD" is not EZTV.

    Anything that is not a string normalises to the empty string, which never
    matches: a name that is a number or a null is not a name, and returning it
    unchanged would let it match another nameless record.
    """
    if not isinstance(name, str):
        return ""
    text = name.strip()
    if text.endswith(PROWLARR_SUFFIX):
        text = text[: -len(PROWLARR_SUFFIX)].strip()
    return text.casefold()


def indexers_with_demand(missing_records, history_records):
    """The normalised names of the indexers Sonarr both needs and has used.

    Demand is a join on the series, and both halves have to hold:

      * `missing_records` -- GET /api/v3/wanted/missing?monitored=true, one
        record per monitored, missing episode, whose `seriesId` is a series
        this stack is still looking for. No records means nothing is missing
        and no indexer has demand.
      * `history_records` -- GET /api/v3/history?eventType=1, one record per
        grab, carrying the series it was for and the indexer that supplied it
        in `data.indexer`.

    An indexer has demand when a grab of its own was for a series that is
    missing something today. A past grab for a series that is complete now, or
    a missing episode whose every grab came from somewhere else, is not a
    reason to spend the stack's connections on a new exit IP.

    Records that are not objects, carry no seriesId, or carry no indexer name
    are skipped rather than guessed at. Pure: two lists in, a set of normalised
    names out, no clock and no I/O.

    Whether `history_records` really are grabs is the request's business
    (`eventType=1`), not this function's: a caller that hands over an
    unfiltered history document gets a weaker join, not an error.

    Both arguments are the records themselves, or Sonarr's page envelope
    around them (`{"page", "pageSize", "totalRecords", "records"}`), which is
    what the wrapper writes to disk -- _page_records reads either.
    """
    series = set()
    for record in _page_records(missing_records):
        key = _as_id(record.get("seriesId"))
        if key is not None:
            series.add(key)
    if not series:
        return set()

    names = set()
    for record in _page_records(history_records):
        key = _as_id(record.get("seriesId"))
        if key is None or key not in series:
            continue
        data = record.get("data")
        if not isinstance(data, dict):
            continue
        name = normalise_indexer_name(data.get("indexer"))
        if name:
            names.add(name)
    return names


def demand_split(rows, demand):
    """Which of `rows` Sonarr has demand for: (with, without) display names.

    (None, None) means the demand data could not be read at all, and every
    caller has to treat that as "not known" rather than "nothing has demand":
    holding a banned IP for every indexer because Sonarr was briefly
    unreachable is the one fail-closed answer this gate must not give.

    The names are the rows' own labels, in the order they arrived, so a
    decision document names indexers the way the rest of it does.
    """
    if not isinstance(demand, dict) or demand.get("known") is not True:
        return None, None
    wanted = demand.get("indexers")
    if not isinstance(wanted, (set, frozenset, list, tuple)):
        wanted = ()
    with_demand, without_demand = [], []
    for row in rows:
        label = row.get("name") or UNKNOWN_INDEXER
        if normalise_indexer_name(label) in wanted:
            with_demand.append(label)
        else:
            without_demand.append(label)
    return with_demand, without_demand


def demand_note(reason, note):
    """`reason` with a parenthesised note about the demand half of it.

    The note goes after the decision's own clause rather than inside it: the
    sentence that says what was decided is the one a log is read for, and it
    has to stay the same sentence with the gate's caveat appended.
    """
    return f"{reason} ({note})"


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


def _positive_float(value):
    """`value` as a float above zero, or (None, the refusal to raise).

    The one positive-number rule in this module. _require_positive and
    _positive_number are the two wrappers over it -- a ValueError for the
    checks inside the decision, an argparse.ArgumentTypeError for the flags --
    so their accept and reject sets cannot drift apart.

    Zero is not "no limit" anywhere here: a window of zero holds on nothing at
    all, a cooldown of zero rotates on every pass with a failed indexer in it,
    and nan compares false against every elapsed time, so it would read as a
    limit nothing ever reaches. A bool is not a number, for the same reason it
    is not an id in _as_id.
    """
    if isinstance(value, bool):
        return None, f"not a number: {value!r}"
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None, f"not a number: {value!r}"
    if not math.isfinite(number) or not number > 0:
        # `not number > 0`, not `number <= 0`, so nan is caught here too.
        return None, f"must be a number greater than 0, got {value!r}"
    return number, ""


def _require_positive(value, label):
    """`value` as a float above zero, or ValueError.

    The refusal the cooldown has always had, now shared with the rotator
    interval and window so all three refuse the same set -- _positive_float is
    the rule itself.
    """
    number, _refusal = _positive_float(value)
    if number is None:
        raise ValueError(f"{label} must be a number above 0, got {value!r}")
    return number


def _epoch_seconds(value):
    """`value` as epoch seconds, or None when it is not one.

    A missing, empty, non-numeric or non-finite value means "no known
    rotation" rather than an error: that is the state of a stack whose rotator
    has not written the file yet, and it has to decide the same way this
    module did before the two actors were coordinated. A numeric string is
    read as the number it spells, a whole number comes back as an int so the
    decision document reads 1789573153 rather than 1789573153.0, and a
    fractional one comes back as a float.

    A bool is not a number here for the same reason it is not an id in
    _as_id.

    A negative value is a number here: the shared file's reader has no bound
    of its own, and epoch_seconds adds the one the --rotator-last flag needs.
    """
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
    elif isinstance(value, str) and value.strip():
        try:
            number = float(value.strip())
        except ValueError:
            return None
    else:
        return None
    if not math.isfinite(number):
        return None
    return int(number) if number.is_integer() else number


def rotator_hold(rotator_last, now,
                 rotator_interval_seconds=DEFAULT_ROTATOR_INTERVAL_SECONDS,
                 rotator_window_minutes=DEFAULT_ROTATOR_WINDOW_MINUTES):
    """Which coordination hold applies, and the minutes it is about.

    Returns (kind, minutes): kind is ROTATOR_IMMINENT, ROTATOR_RECENT or
    None, and minutes is the time until the rotator's restart or the time
    since the rotation. Pure -- `now` is a parameter, like everywhere else
    here -- and it reads no file: the wrapper hands over the value it read.

    The rotator restarts gluetun `rotator_interval_seconds` after the last
    rotation either actor recorded, so a restart inside the window is about to
    cycle the tunnel anyway (imminent), and a rotation inside it is too fresh
    for the ban evidence to mean much -- Prowlarr is still latched into a
    backoff it earned on the old IP (recent). Both bounds are inclusive.

    Only an event still ahead of, or behind, `now` holds: a rotator whose
    restart moment has already passed is overdue rather than imminent, and
    nothing here can tell when it will actually fire. `rotator_last` None --
    no file, an empty one, a value that is not a number -- is no hold at all.
    """
    interval = _require_positive(rotator_interval_seconds,
                                 "rotator_interval_seconds")
    window = _require_positive(rotator_window_minutes,
                               "rotator_window_minutes") * 60.0
    last = _epoch_seconds(rotator_last)
    if last is None:
        return None, None
    moment = _utc(now).timestamp()
    remaining = (last + interval) - moment
    if 0.0 <= remaining <= window:
        return ROTATOR_IMMINENT, remaining / 60.0
    elapsed = moment - last
    if 0.0 <= elapsed <= window:
        return ROTATOR_RECENT, elapsed / 60.0
    return None, None


def _rotator_reason(names, hold, minutes):
    """The one-line reason for a coordination hold. Never called without one."""
    if hold == ROTATOR_IMMINENT:
        return (f"{names} show ban evidence but the rotator restarts gluetun "
                f"in {minutes:.1f} minutes on its own schedule; not rotating")
    return (f"{names} show ban evidence but the VPN rotated {minutes:.1f} "
            f"minutes ago and Prowlarr needs time to re-probe from the new "
            f"IP before its ban evidence can be trusted; not rotating")


def _decide_ban_evidence(blocked, last_rotation, now, cooldown_hours,
                         rotator_last, rotator_interval_seconds,
                         rotator_window_minutes):
    """The decision this module made before Sonarr was consulted at all.

    (rotate, reason, hold): ban evidence, the cooldown, and the rotator's own
    schedule, in that order of precedence. Everything about the demand gate
    lives in _decide, which applies it to this answer -- so this half is the
    behaviour every pass without demand data still gets, unchanged.
    """
    cooldown_hours = _require_positive(cooldown_hours, "cooldown_hours")
    hold, minutes = rotator_hold(rotator_last, now, rotator_interval_seconds,
                                 rotator_window_minutes)

    def rotating(reason):
        """A rotation the guard is otherwise clear to make, or the hold."""
        if hold is None:
            return True, reason, None
        return False, _rotator_reason(names, hold, minutes), hold

    now = _utc(now)
    rows = [row for row in blocked or () if isinstance(row, dict)]
    banned = [row for row in rows if row.get("ban_evidence") is True]
    cooldown = f"{cooldown_hours:g}h"

    if not banned:
        if not rows:
            return False, ("no indexer is in backoff, so there is nothing to "
                           "rotate for"), None
        names = ", ".join(row.get("name") or UNKNOWN_INDEXER for row in rows)
        return False, (f"{names} in backoff with no ban evidence (a timeout or "
                       f"a plain error is not an IP ban); not rotating"), None

    names = ", ".join(row.get("name") or UNKNOWN_INDEXER for row in banned)
    if last_rotation is None or (isinstance(last_rotation, str)
                                 and not last_rotation.strip()):
        return rotating(f"{names} show ban evidence and no rotation has been "
                        f"recorded yet; rotating")

    since = last_rotation_time(last_rotation)
    if since is None:
        return False, (f"{names} show ban evidence but the recorded last "
                       f"rotation ({last_rotation!r}) is not a timestamp, so "
                       f"the {cooldown} cooldown cannot be checked; not rotating"), None

    elapsed = (now - _utc(since)).total_seconds() / 3600.0
    if elapsed >= cooldown_hours:
        return rotating(f"{names} show ban evidence and the {cooldown} cooldown "
                        f"has expired (last rotation {elapsed:.1f}h ago); rotating")
    return False, (f"{names} show ban evidence but the {cooldown} cooldown has "
                   f"{cooldown_hours - elapsed:.1f}h left (last rotation "
                   f"{elapsed:.1f}h ago); not rotating"), None


def _decide(blocked, last_rotation, now, cooldown_hours, rotator_last,
            rotator_interval_seconds, rotator_window_minutes, demand=None):
    """should_rotate's whole answer: the ban/cooldown/rotator decision, gated
    on Sonarr's demand when there is any demand data.

    (rotate, reason, hold), with hold one of the ROTATOR_* names or None. The
    decision document reports the third element and the wrapper only needs the
    first two, so one function decides both and the two renderers cannot
    disagree.

    The order is the point. Ban evidence, the cooldown and the rotator's
    windows are decided first, exactly as they were before this gate existed,
    and the demand gate is applied to that answer and can only ever turn a
    rotation into a hold -- never the reverse, and never ahead of a hold the
    cooldown or the rotator already justified. A pass whose cooldown is still
    running says so; it does not say Sonarr has no demand, because the demand
    was never consulted.

    `demand` is None when nothing asked Sonarr, and then the answer is the one
    this module gave before the gate existed. Otherwise it is the dict
    demand_from_documents builds -- {"known", "indexers", "error"}. Demand that
    could NOT be read is a skip with a note, not a hold: fail open, because a
    Sonarr that is unreachable for one pass must not stop the VPN rotating away
    from an IP that is banned for every indexer this stack does use.
    """
    rotate, reason, hold = _decide_ban_evidence(
        blocked, last_rotation, now, cooldown_hours, rotator_last,
        rotator_interval_seconds, rotator_window_minutes)
    if not rotate or demand is None:
        return rotate, reason, hold

    # The same rows the reason above was built from: a rotation is only ever
    # decided for indexers whose own text is ban evidence, and those are the
    # ones the gate asks about.
    banned = [row for row in blocked or () if isinstance(row, dict)
              and row.get("ban_evidence") is True]
    with_demand, without_demand = demand_split(banned, demand)
    if with_demand is None:
        error = demand.get("error") if isinstance(demand, dict) else None
        note = f"Sonarr demand unknown: {error or DEMAND_UNKNOWN}"
        # Fail open: the rotation this function was already clear to make still
        # happens. Reading an unread document as "no demand" is the one wrong
        # direction here -- it would hold a banned IP in place for every
        # indexer this stack does use, for as long as Sonarr is unhappy.
        return rotate, demand_note(reason, note), hold
    if not with_demand:
        return False, (f"banned indexers have no Sonarr demand: "
                       f"{', '.join(without_demand) or UNKNOWN_INDEXER}; no "
                       f"monitored missing episode here was ever grabbed from "
                       f"them, so a new exit IP would buy nothing; not "
                       f"rotating"), None
    if without_demand:
        # A rotation one of the banned indexers does justify, with the ones it
        # does not named beside it: "rotating, and here is what is not part of
        # why" is the same shape as the ban-evidence line above.
        return rotate, demand_note(
            reason, f"no Sonarr demand for {', '.join(without_demand)}"), hold
    return rotate, reason, hold


def should_rotate(blocked, last_rotation, now, cooldown_hours=DEFAULT_COOLDOWN_HOURS,
                  rotator_last=None,
                  rotator_interval_seconds=DEFAULT_ROTATOR_INTERVAL_SECONDS,
                  rotator_window_minutes=DEFAULT_ROTATOR_WINDOW_MINUTES,
                  demand=None):
    """Whether to rotate the VPN, and a one-line reason either way.

    True needs both halves: at least one blocked indexer whose failure is ban
    evidence, and a cooldown that has expired. Blocked indexers alone are not
    enough -- a timeout is a slow indexer, not a banned IP -- and evidence
    alone is not enough either, because a rotation five minutes after the last
    one cannot produce a different IP that Cloudflare likes better. On top of
    those, the rotator's own schedule has to leave room: see rotator_hold.

    `last_rotation` is the state file's timestamp, as a datetime or as the
    string it was stored as; None means this stack has never rotated, which
    cannot be inside a cooldown. A value that is present but unreadable blocks
    the rotation instead: the one irreversible action here must not be taken
    because the record of the last one was garbled.

    `rotator_last` is the last rotation by either actor, in epoch seconds, as
    the wrapper read it out of the file the two share. None means there is no
    known one, and the rotator's schedule is not consulted at all -- a stack
    that has never coordinated decides exactly as it did before there was
    anything to coordinate with. A restart inside `rotator_window_minutes`
    holds this rotation, and so does any rotation inside it, because Prowlarr
    has not failed against the new IP yet. Neither window touches the cooldown:
    `rotator_last` never extends it, and the only rotations it is measured
    from are the ones this guard recorded itself.

    `demand` is the Sonarr half, as demand_from_documents builds it, and is
    applied last: it can turn a rotation this function would otherwise make
    into a hold, and it is not consulted at all when the answer is already a
    hold. None -- the default, and every caller that has no Sonarr data -- is
    the decision this module made before the gate existed. See _decide.

    The boundary is inclusive (`elapsed >= cooldown_hours`): the cooldown is a
    minimum time between rotations, and a rotation exactly on it is a rotation
    that waited. cooldown_hours, and the two rotator numbers, must be finite
    and above zero -- the CLI refuses anything else at the argument with
    positive_hours/positive_seconds/positive_minutes, and a ValueError here is
    the same refusal at the function, so a caller cannot pass 0 and quietly
    get "every pass may rotate".
    """
    return _decide(blocked, last_rotation, now, cooldown_hours, rotator_last,
                   rotator_interval_seconds, rotator_window_minutes,
                   demand)[:2]


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


def _positive_number(value):
    """The acceptance rule -- and the wording -- the positive flags share.

    _positive_float decides; this only turns its refusal into the exception
    argparse turns into exit 2.
    """
    number, refusal = _positive_float(value)
    if number is None:
        raise argparse.ArgumentTypeError(refusal)
    return number


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
    return _positive_number(value)


def positive_minutes(value):
    """argparse type for --rotator-window-minutes: a number above zero.

    The cooldown's rule and its accept/reject set, for the same reason: a
    window of zero would hold on nothing at all, and nan would never match a
    remaining time.
    """
    return _positive_number(value)


def positive_seconds(value):
    """argparse type for --rotator-interval: whole seconds, above zero.

    Nothing here needs sub-second precision, and a value that is not a whole
    number is refused rather than truncated -- `--rotator-interval 1.5` read
    as 1 would put the hold in the wrong place every time it is consulted.
    """
    seconds = _positive_number(value)
    if not seconds.is_integer():
        raise argparse.ArgumentTypeError(
            f"must be a whole number of seconds, got {value!r}")
    return int(seconds)


def epoch_seconds(value):
    """argparse type for --rotator-last: epoch seconds, at or after zero.

    Zero is accepted because a file may hold it after a clock that has never
    been set, and it decides the obvious way: a rotation at the epoch is
    neither imminent nor recent. A negative value is refused, and so is
    anything that is not a number. The wrapper omits the flag entirely when
    the shared file is missing or unreadable, so a value that reaches here is
    one the caller meant.

    _epoch_seconds does the reading, so the file's own reader and this flag
    cannot disagree about what a timestamp is; the lower bound is the only
    thing added here, because a moment before the epoch is not one the shared
    file could hold.
    """
    seconds = _epoch_seconds(value)
    if seconds is None or seconds < 0:
        raise argparse.ArgumentTypeError(f"not epoch seconds: {value!r}")
    return seconds


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


def _read_documents(paths, label):
    """One document's pages, read into (records, total, why they could not be).

    `records` is every record from every page, in order. `total` is the largest
    `totalRecords` among the pages that are envelopes carrying one, or None when
    no page makes that claim -- a bare array, or a document in any other shape.
    The largest rather than the first, because a document that grew between two
    page fetches is a document the walk covered less of than the count on its
    last page says, and the comparison that matters is against the biggest claim
    the pages make.

    A page that parsed but holds nothing adds nothing and is not an error: an
    empty missing-episode document is Sonarr saying nothing is missing, which is
    a real answer. A page that could not be read at all IS an error -- half a
    history document is a join that silently under-reports demand, and that
    reads exactly like an indexer nothing here uses.
    """
    records = []
    total = None
    for path in paths:
        document, error = _read_json(path, label)
        if error:
            return None, None, error
        records.extend(_page_records(document))
        claimed = page_total(document)
        if claimed is not None and (total is None or claimed > total):
            total = claimed
    return records, total, None


def _page_records(document):
    """The records in one Sonarr page, as a list of dicts.

    Sonarr paginates: a page is an object with `page`, `pageSize`,
    `totalRecords` and a `records` array, and `records` is what every field
    this module reads lives in. A bare array is accepted as the same records,
    so a hand-run -- or a test -- can hand over just the rows. Anything else is
    no records rather than a traceback, the same contract _records has for the
    documents that are not paginated.
    """
    if isinstance(document, dict) and isinstance(document.get("records"),
                                                  (list, tuple)):
        return [item for item in document["records"] if isinstance(item, dict)]
    return _records(document)


def page_total(document):
    """The whole-document record count a Sonarr page envelope carries, or None.

    `totalRecords` is the size of the ENTIRE document, not of the page it
    arrives on, and it is the one number both halves of the paging contract are
    built on: the wrapper's --page-total mode hands it to the shell so the walk
    knows how many pages to fetch, and _truncation_note compares the records
    that arrived against it to notice a walk that stopped short. Reading it in
    one function is what keeps those two from disagreeing about what an
    envelope is.

    None means "no claim about the whole document", and it is the answer for
    every shape that is not an envelope with a usable count: a bare array is
    the records themselves, and a document whose totalRecords is missing, null,
    negative or not a number says nothing about how many there are. All of them
    are taken as complete rather than truncated -- reading every document nobody
    vouched for as short would make demand unknown for a caller that handed the
    records over directly, which is the opposite failure: a rotation for an
    indexer nothing needs.

    A digit string is accepted as the number it spells, the way _as_id accepts
    one for an id: the same document round-tripped through a JSON viewer comes
    back with quotes. A bool is not a count, for the same reason it is not an id
    in _as_id -- `true` is not one record.
    """
    if not isinstance(document, dict):
        return None
    total = document.get("totalRecords")
    if isinstance(total, bool):
        return None
    if isinstance(total, int):
        return total if total >= 0 else None
    if isinstance(total, str):
        text = total.strip()
        if text.isdigit():
            return int(text)
    return None


def _truncation_note(label, collected, total):
    """The note that says a document was read short, or None when it was not.

    A note comes back when the pages handed over hold fewer records than the
    largest totalRecords their envelopes claim, which is a document nobody has
    all of: the join cannot see the grabs on the pages that were never fetched,
    and an indexer whose grabs are all there looks exactly like an indexer with
    no demand at all. That is a false hold, so the caller turns this into
    unknown demand, which fails open. `total` None -- no envelope claimed
    anything, a bare array -- is not truncation.

    The wording names the document and both counts, so the log line says how
    much of it was read rather than only that something was wrong.
    """
    if total is None or collected >= total:
        return None
    return f"{label} truncated: {collected} of {total} records"


def demand_from_documents(missing_paths, history_paths, error=None):
    """The demand state the CLI's flags describe, or None when there are none.

    None is "nobody asked Sonarr": no demand flag was given at all, and the
    decision is the one this module made before the gate existed. That is what
    keeps a pass with no Sonarr data the pass it always was.

    Anything else is a dict: {"known", "indexers", "error"}. It is unknown --
    `known` False with the reason in `error` -- when the wrapper says it could
    not fetch (the `error` note), when only one of the two documents was
    supplied (there is no join to make), when a page cannot be read or is not
    JSON, or when the pages hold fewer records than their envelopes claim. That
    last one is a document read short, and the join over it would under-report
    demand -- see _truncation_note. Unknown is returned rather than raised: the
    gate is skipped and the decision says so, because a demand check that stops
    the guard on a timer is worse than no demand check.

    `known` True needs both halves of the join and nothing else -- an empty
    missing-episode document is a real answer, not a missing one, and it means
    no indexer has demand.
    """
    missing_paths = list(missing_paths or ())
    history_paths = list(history_paths or ())
    if error is None and not missing_paths and not history_paths:
        return None

    def unknown(reason):
        return {"known": False, "indexers": frozenset(), "error": reason}

    if error is not None:
        return unknown(error or DEMAND_UNKNOWN)
    if not missing_paths or not history_paths:
        return unknown("both Sonarr documents are needed to establish demand")

    missing, missing_total, failure = _read_documents(
        missing_paths, "the Sonarr missing-episode page")
    if failure:
        return unknown(failure)
    history, history_total, failure = _read_documents(
        history_paths, "the Sonarr history page")
    if failure:
        return unknown(failure)

    # The completeness check, and the only place a walk that stopped early is
    # recognised. Each set is judged against its own envelopes: pages that
    # arrived are not evidence about pages that did not, and "the records I
    # have" is not an answer to "does this indexer have demand" when the
    # document is bigger than the slice in hand. Both notes are carried when
    # both sets are short, so the log says which documents were incomplete.
    truncated = [note for note in (
        _truncation_note("Sonarr missing episodes", len(missing), missing_total),
        _truncation_note("Sonarr history", len(history), history_total),
    ) if note]
    if truncated:
        return unknown("; ".join(truncated))

    return {"known": True,
            "indexers": indexers_with_demand(missing, history),
            "error": None}


def decision(statuses, indexers, state, now, cooldown_hours,
             rotator_last=None,
             rotator_interval_seconds=DEFAULT_ROTATOR_INTERVAL_SECONDS,
             rotator_window_minutes=DEFAULT_ROTATOR_WINDOW_MINUTES,
             demand=None):
    """The whole answer as plain data, for either renderer.

    Pure, and the only place the two documents meet: everything the CLI prints
    is derived here, so the JSON and the text line cannot disagree about what
    was decided.

    The rotator fields are what a reader of the log needs to see why a
    hold happened: when either actor last rotated, when the rotator will next
    on its own schedule (None when nothing is known), and which of the two
    coordination holds applied. They are derived data -- `reason` remains the
    sentence that says what was decided.

    The demand fields appear only when a demand input was supplied at all, and
    that is deliberate rather than an omission: with no Sonarr data this
    document has to be the one it always was, byte for byte, so that a pass
    without the gate is comparable with every pass before it. When they are
    there, `banned_with_demand` and `banned_without_demand` name the banned
    indexers the gate found on each side, and both are null -- not empty --
    when the demand data could not be read, because an unread document is not
    a list of indexers nothing needs.
    """
    blocked = blocked_indexers(statuses, indexers, now)
    last_rotation = state.get("last_rotation") if isinstance(state, dict) else None
    rotate, reason, hold = _decide(blocked, last_rotation, now, cooldown_hours,
                                   rotator_last, rotator_interval_seconds,
                                   rotator_window_minutes, demand)
    last = _epoch_seconds(rotator_last)
    view = {
        "decided_at": now.isoformat(),
        "rotate": rotate,
        "reason": reason,
        "cooldown_hours": cooldown_hours,
        "last_rotation": last_rotation,
        "rotations": state.get("rotations", 0) if isinstance(state, dict) else 0,
        "rotator_last": last,
        "rotator_next": (last + rotator_interval_seconds
                         if last is not None else None),
        "rotator_interval_seconds": rotator_interval_seconds,
        "rotator_window_minutes": rotator_window_minutes,
        "rotator_hold": hold,
        "blocked": blocked,
    }
    if demand is not None:
        banned = [row for row in blocked if row.get("ban_evidence") is True]
        with_demand, without_demand = demand_split(banned, demand)
        view["demand_known"] = (isinstance(demand, dict)
                                and demand.get("known") is True)
        view["demand_error"] = (demand.get("error")
                                if isinstance(demand, dict) else None)
        view["banned_with_demand"] = with_demand
        view["banned_without_demand"] = without_demand
    return view


def demand_lines(view):
    """The Sonarr half of a decision document, as lines (usually none at all).

    Nothing at all for a document that never consulted Sonarr, which is what
    keeps both renderers' output identical for every pass without demand data.
    A document that did consult it has to say what the gate found: which banned
    indexers Sonarr needs and which it does not, or -- when the data could not
    be read -- that demand was unknown, because "no demand" and "no answer"
    are the same hold otherwise and only one of them is a reason to leave a
    banned IP in place.
    """
    if not isinstance(view, dict) or "demand_known" not in view:
        return []
    if view.get("demand_known") is True:
        def names(key):
            value = view.get(key)
            if not isinstance(value, (list, tuple)):
                return "none"
            return ", ".join(str(item) for item in value) or "none"
        return [f"  Sonarr demand: {names('banned_with_demand')}; "
                f"no Sonarr demand: {names('banned_without_demand')}"]
    return [f"  Sonarr demand unknown: "
            f"{view.get('demand_error') or DEMAND_UNKNOWN}"]


def render_text(view):
    """The decision as one line plus, when there are any, the blocked indexers.

    The reason is the line that matters and is printed for both answers: a
    wrapper's log is read to find out why the VPN did or did not move, and
    "hold" with no reason is indistinguishable from a guard that is broken.

    The demand summary follows the blocked list for a decision that consulted
    Sonarr; see demand_lines.
    """
    lines = [f"{'rotate' if view['rotate'] else 'hold'}: {view['reason']}"]
    for row in view["blocked"]:
        evidence = ", ban evidence" if row["ban_evidence"] else ""
        lines.append(f"  {row['name']} (id {row['indexer_id']}): "
                     f"{row['hours_remaining']}h of backoff left{evidence}")
    lines.extend(demand_lines(view))
    return "\n".join(lines)


def verdict_line(view):
    """A --json decision document as the wrapper's one-line verdict.

    Returns (line, error). The line is the rotate/hold word, a tab, and the
    reason -- the shape the wrapper splits on, and the tab is what stops a
    reason that opens with a word like "rotate" from reading as the verdict
    itself. A document with no usable rotate flag or reason is an error rather
    than a hold: a guard that quietly holds when it cannot read its own
    decision is a guard that has stopped working, and nothing would say so.

    A document that consulted Sonarr carries its demand summary on the lines
    after the verdict, for the same reason the reason itself is carried: the
    wrapper logs what this returns, and a hold that does not say Sonarr was
    consulted reads like a hold that never asked. The verdict stays the first
    line and the reason stays behind the tab, so the wrapper's split is
    untouched.
    """
    rotate = view.get("rotate") if isinstance(view, dict) else None
    reason = view.get("reason") if isinstance(view, dict) else None
    if rotate not in (True, False) or not isinstance(reason, str):
        return None, "the decision carried no rotate flag and reason"
    lines = [("rotate" if rotate else "hold") + "\t" + reason]
    lines.extend(demand_lines(view))
    return "\n".join(lines), None


def main(argv=None):
    """Read the two documents and print the decision. Returns the exit status.

    Four modes share the one parser: the default decides, --record-rotation
    writes the rotation the wrapper has just performed, --verdict renders a
    decision document the wrapper already has, and --page-total prints one
    envelope's record count for the wrapper's paging. argparse owns the argv
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
    parser.add_argument("--rotator-last", type=epoch_seconds, default=None,
                        metavar="EPOCH",
                        help="the last VPN rotation by either actor, in epoch "
                             "seconds, out of the timestamp file the wrapper "
                             "shares with gluetun-rotator (default: none, and "
                             "the rotator's schedule is not consulted)")
    parser.add_argument("--rotator-interval", type=positive_seconds,
                        default=DEFAULT_ROTATOR_INTERVAL_SECONDS,
                        metavar="SECONDS",
                        help="how often gluetun-rotator restarts gluetun, in "
                             "seconds (default: %(default)s)")
    parser.add_argument("--rotator-window-minutes", type=positive_minutes,
                        default=DEFAULT_ROTATOR_WINDOW_MINUTES,
                        metavar="MINUTES",
                        help="how close either rotation has to be, in minutes, "
                             "for the guard to hold (default: %(default)s)")
    parser.add_argument("--demand-missing", action="append", default=None,
                        metavar="PATH",
                        help="GET /api/v3/wanted/missing?monitored=true, one "
                             "page per flag, as JSON; repeat it for every page "
                             "(default: none, and the demand gate is skipped)")
    parser.add_argument("--demand-history", action="append", default=None,
                        metavar="PATH",
                        help="GET /api/v3/history?eventType=1, one page per "
                             "flag, as JSON; repeat it for every page "
                             "(default: none)")
    parser.add_argument("--demand-error", default=None, metavar="TEXT",
                        help="the wrapper's note that it could not establish "
                             "demand -- a request that failed, a page that is "
                             "not an envelope, or the pass's time budget spent; "
                             "the gate is skipped and the reason says demand "
                             "was unknown (default: none)")
    parser.add_argument("--record-rotation", action="store_true",
                        help="record a rotation in --state and exit, printing "
                             "the new count; the caller must have performed "
                             "one")
    parser.add_argument("--verdict", default=None, metavar="PATH",
                        help="a --json decision document, rendered back as one "
                             "rotate/hold line (default: none)")
    parser.add_argument("--page-total", default=None, metavar="PATH",
                        help="print one Sonarr page envelope's totalRecords as "
                             "an integer and exit; a document that is not an "
                             "envelope with a usable count, or is not JSON, is "
                             "an error (default: none)")
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

    # The wrapper's paging half: one integer out of an envelope, so the shell
    # can size its walk without parsing JSON. A document it cannot read is an
    # error rather than a zero -- see the --page-total help.
    if args.page_total is not None:
        document, error = _read_json(args.page_total, "the Sonarr page envelope")
        if error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 2
        total = page_total(document)
        if total is None:
            print(f"ERROR: {args.page_total} is not a Sonarr page envelope "
                  f"with a totalRecords count", file=sys.stderr)
            return 2
        print(total)
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

    # None when no demand flag was given at all -- and then the decision below
    # is the one this module made before the gate existed, unchanged.
    demand = demand_from_documents(args.demand_missing, args.demand_history,
                                   args.demand_error)

    view = decision(statuses, indexers, load_state(args.state),
                    now, args.cooldown_hours, args.rotator_last,
                    args.rotator_interval, args.rotator_window_minutes,
                    demand)
    if args.json:
        print(json.dumps(_plain(view), indent=2, sort_keys=True))
    else:
        print(render_text(view))
    return 0


if __name__ == "__main__":
    sys.exit(main())
