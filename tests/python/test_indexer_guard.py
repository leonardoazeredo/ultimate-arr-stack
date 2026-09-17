"""Behavioural tests for scripts/lib/indexer_guard.py.

The module answers one question -- should the VPN be rotated now, and why --
and the two ways to get it wrong are not symmetrical. Rotating when nothing is
banned drops every connection in the stack for nothing and can hand out a
worse exit IP; refusing to rotate while the IP is banned leaves every public
indexer failing until someone notices. So the tests here are about the edges
that decide between those:

  * **evidence, not symptoms.** A timeout, a 500 and a Cloudflare challenge all
    look like "the search failed" from the stack, and only one of the three
    means the IP is banned. 1006 has to match as a whole number -- a record
    whose own id is 1006 is not a Cloudflare ban -- and "challenge" must not
    match at all: FlareSolverr solves those, so a healthy stack produces them.
  * **the cooldown is a minimum, and it is enforced against a clock the caller
    supplies.** Every pure function takes `now`, so a test can put a rotation
    exactly on the boundary or one second inside it and say what happens.
  * **nothing here can act.** No import in the module can open a socket, spawn
    a process or read a credential, the decision never writes the state file,
    and a failure message -- which can carry an indexer URL, and therefore an
    API key -- is never echoed, only reduced to a boolean.

Every test is pure: no socket, no subprocess, no clock outside the fixtures,
and no file written outside tmp_path.
"""

import argparse
import ast
import io
import json
import os
import pathlib
import re
import sys
from datetime import datetime, timedelta, timezone

import pytest

import indexer_guard as m

NOW = datetime(2026, 9, 15, 22, 0, 0, tzinfo=timezone.utc)


def at(hours):
    """An ISO-8601 UTC timestamp `hours` after the fixture NOW, in Z form.

    Z rather than the +00:00 fromisoformat writes, because that is the shape
    Prowlarr sends and the shape this has to parse.
    """
    return (NOW + timedelta(hours=hours)).isoformat().replace("+00:00", "Z")


def a_status(**kw):
    """One GET /api/v1/indexerstatus record, with any field overridable.

    The shape is the real one: a record per indexer in backoff, keyed by its
    own id and carrying the indexer's, with the three timestamps Prowlarr
    writes. A test that wants a record with no disabledTill deletes the key
    rather than overriding it to None, because those are different payloads.
    """
    base = {
        "id": 4,
        "indexerId": 7,
        "initialFailure": "2026-09-14T22:10:03Z",
        "mostRecentFailure": "2026-09-15T01:44:57Z",
        "disabledTill": at(4),
    }
    base.update(kw)
    return base


def an_indexer(the_id=7, name="1337x"):
    """One GET /api/v1/indexer record, with the fields this module reads."""
    return {"id": the_id, "name": name, "protocol": "torrent"}


def a_blocked(name="1337x", evidence=True, indexer_id=7):
    """A row as blocked_indexers returns one, for the should_rotate tests."""
    return {"indexer_id": indexer_id, "name": name, "ban_evidence": evidence}


def only(rows):
    assert len(rows) == 1
    return rows[0]


def real_now():
    """The wall clock, for the CLI tests only.

    main() reads the real clock -- the pure functions take `now` -- so a CLI
    fixture has to be anchored where main() will be when it runs. The margins
    are hours wide, so a slow test cannot cross one.
    """
    return datetime.now(timezone.utc)


def live_status(hours=4.0, **kw):
    """A status record whose backoff is still running on the real clock."""
    return a_status(
        disabledTill=(real_now() + timedelta(hours=hours)).isoformat(), **kw)


def write(path, document):
    """`document` as JSON at `path`, returned as the string paths are passed as."""
    path.write_text(json.dumps(document))
    return str(path)


# --- what counts as evidence -------------------------------------------------


@pytest.mark.parametrize("text", [
    "cloudflare",
    "ClOuDfLaRe error",
    "Cloudflare error 1006: your IP is banned",
    "Error 1006",
    "error 1006.",
    "(1006)",
    "HTTP 403",
    "403",
    "403 Forbidden",
    "Forbidden",
    "forbidden by the indexer",
])
def test_ban_evidence_in_the_shapes_prowlarr_reports_it(text):
    assert m.looks_like_ban(text) is True


def test_a_cloudflare_challenge_is_not_ban_evidence():
    # A challenge is not an IP ban. This stack runs FlareSolverr to solve
    # challenges, so a healthy install produces challenge pages during normal
    # operation, and treating one as evidence would rotate the VPN for nothing.
    #
    # The wording is the whole test. The obvious fixture -- "Indexer returned a
    # Cloudflare challenge page; FlareSolverr will solve it" -- contains
    # "cloudflare", which is still a pattern, so it would return True for a
    # reason that has nothing to do with "challenge" and would pass whatever
    # this test claimed. The messages below carry no other trigger word, so
    # only the deleted pattern could have made them evidence.
    assert m.looks_like_ban("Waiting on a JS challenge to be solved") is False
    assert m.looks_like_ban("Just a moment... challenge") is False
    assert m.looks_like_ban("ChAlLeNgE required") is False


@pytest.mark.parametrize("text", [
    "21006",
    "10063",
    "11006",
    "The operation has timed out",
    "Unable to connect to indexer: connection refused",
    "HTTP 500",
    "indexer 21006 failed",
    None,
    "",
])
def test_ordinary_failures_are_not_ban_evidence(text):
    assert m.looks_like_ban(text) is False


def test_1006_matches_only_as_a_whole_number():
    # Cloudflare error 1006 means the IP is banned. A ray id, a byte count, a
    # record id or an indexer id that merely ends in those digits does not,
    # and 21006 is the case that made this a rule rather than a \b.
    assert m.looks_like_ban("21006") is False
    assert m.looks_like_ban("code 1006") is True
    assert m.looks_like_ban("code 1006.") is True
    assert m.looks_like_ban("code 1006)") is True


@pytest.mark.parametrize("value", [1006, 403, True, 4.2, {}, [], object()])
def test_a_non_string_is_not_evidence(value):
    # looks_like_ban's contract is text. A number in a field the caller
    # guessed at must not match by being the number.
    assert m.looks_like_ban(value) is False


def test_the_patterns_are_a_tuple_of_compiled_case_insensitive_regexes():
    # The case-insensitivity is per pattern and easy to drop from one of them
    # while adding the next, which is why it is asserted over the whole tuple
    # rather than through looks_like_ban alone.
    assert isinstance(m.BAN_PATTERNS, tuple)
    assert m.BAN_PATTERNS
    for pattern in m.BAN_PATTERNS:
        assert isinstance(pattern, re.Pattern)
        assert pattern.flags & re.IGNORECASE


def test_every_named_evidence_shape_has_a_pattern_behind_it():
    # cloudflare, 1006, 403, forbidden: four facts, four patterns. A pattern
    # deleted as redundant would otherwise be invisible until the day Prowlarr
    # reports only that one -- and each of the four has its own test above.
    assert len(m.BAN_PATTERNS) == 4


# --- which indexers are blocked ---------------------------------------------


def test_a_backoff_in_the_future_is_blocking():
    row = only(m.blocked_indexers([a_status()], [an_indexer()], NOW))
    assert row["indexer_id"] == 7
    assert row["name"] == "1337x"
    assert row["status_id"] == 4
    assert row["disabled_till"] == NOW + timedelta(hours=4)
    assert row["hours_remaining"] == 4.0
    assert row["initial_failure"] == datetime(2026, 9, 14, 22, 10, 3, tzinfo=timezone.utc)
    assert row["most_recent_failure"] == datetime(2026, 9, 15, 1, 44, 57, tzinfo=timezone.utc)


def test_a_backoff_in_the_past_is_not_blocking_anything():
    assert m.blocked_indexers([a_status(disabledTill=at(-1))], [an_indexer()], NOW) == []


def test_a_backoff_that_ends_exactly_now_is_over():
    # Strictly in the future, so the boundary belongs to the past: a backoff
    # with no time left on it is not a reason to hold an indexer out of the
    # decision, and `>=` here would keep one alive for an extra pass.
    assert m.blocked_indexers([a_status(disabledTill=at(0))], [an_indexer()], NOW) == []


def test_a_record_with_no_disabled_till_at_all_is_skipped():
    # Prowlarr has records with no disabledTill -- a failure still being
    # counted, with no disable. There is no backoff to report.
    record = a_status()
    del record["disabledTill"]
    assert m.blocked_indexers([record], [an_indexer()], NOW) == []


@pytest.mark.parametrize("disabled", [
    None, "", "   ", "not a date", "2026-13-45T99:00:00Z", 5, 4.2, [], {}, True,
])
def test_a_disabled_till_that_is_not_a_usable_time_is_skipped(disabled):
    # Never raised on: this runs on a timer against a document nobody is
    # watching, and one malformed record must not stop the decision about the
    # other twenty.
    assert m.blocked_indexers([a_status(disabledTill=disabled)], [an_indexer()], NOW) == []


def test_several_records_are_filtered_independently():
    statuses = [
        a_status(id=1, indexerId=7, disabledTill=at(4)),
        a_status(id=2, indexerId=9, disabledTill=at(-4)),
        a_status(id=3, indexerId=11, disabledTill="garbage"),
        a_status(id=4, indexerId=12, disabledTill=at(0)),
    ]
    indexers = [an_indexer(7, "1337x"), an_indexer(9, "YTS"),
                an_indexer(11, "EZTV"), an_indexer(12, "RARBG")]
    assert [row["name"] for row in m.blocked_indexers(statuses, indexers, NOW)] == ["1337x"]


def test_the_name_comes_from_the_indexer_document():
    row = only(m.blocked_indexers([a_status(indexerId=7)],
                                  [an_indexer(9, "YTS"), an_indexer(7, "1337x")], NOW))
    assert row["name"] == "1337x"


def test_an_unknown_indexer_id_falls_back_to_its_own_id():
    # The id is the one label the record always has, and "indexer 7" in a
    # decision line is enough to look the definition up by hand.
    row = only(m.blocked_indexers([a_status(indexerId=7)], [], NOW))
    assert row["name"] == "indexer 7"
    assert row["indexer_id"] == 7


def test_an_indexer_document_keyed_by_id_still_names_what_it_can():
    row = only(m.blocked_indexers([a_status(indexerId=7)], {"abc": an_indexer(7)}, NOW))
    assert row["name"] == "1337x"


def test_a_digit_string_id_still_resolves_to_its_name():
    row = only(m.blocked_indexers([a_status(indexerId="7")], [an_indexer("7")], NOW))
    assert row["indexer_id"] == 7
    assert row["name"] == "1337x"


def test_an_indexer_with_a_blank_name_falls_back_to_its_id():
    row = only(m.blocked_indexers([a_status(indexerId=7)], [an_indexer(7, "   ")], NOW))
    assert row["name"] == "indexer 7"


def test_an_indexer_document_with_no_id_does_not_name_the_wrong_indexer():
    row = only(m.blocked_indexers([a_status(indexerId=7)], [{"name": "1337x"}], NOW))
    assert row["name"] == "indexer 7"


def test_a_record_with_no_indexer_id_is_still_reported():
    row = only(m.blocked_indexers([a_status(indexerId=None)], [], NOW))
    assert row["indexer_id"] is None
    assert row["name"] == m.UNKNOWN_INDEXER


def test_ban_evidence_is_read_from_the_records_own_text():
    record = a_status(message="Cloudflare error 1006: your IP is banned")
    assert only(m.blocked_indexers([record], [an_indexer()], NOW))["ban_evidence"] is True


def test_a_timeout_record_carries_no_ban_evidence():
    record = a_status(message="The operation has timed out")
    assert only(m.blocked_indexers([record], [an_indexer()], NOW))["ban_evidence"] is False


def test_a_failure_nested_inside_the_record_is_still_read():
    # The failure text has arrived under more than one key. The scan is over
    # the record's values, not one named field, so a nested one is not missed.
    record = a_status(extra={"error": {"message": "403 Forbidden"}})
    assert only(m.blocked_indexers([record], [an_indexer()], NOW))["ban_evidence"] is True


def test_a_records_own_id_is_not_evidence():
    # An install with a thousand indexer-status rows has a row with id 1006 in
    # it. That is a record number, not Cloudflare's, and rotating the VPN over
    # it is the false positive this module exists to avoid.
    record = a_status(id=1006, message="The operation has timed out")
    assert only(m.blocked_indexers([record], [an_indexer()], NOW))["ban_evidence"] is False


def test_the_failure_text_itself_is_not_carried_out_of_the_module():
    # A Prowlarr message can carry the request URL, and an indexer URL carries
    # its API key, so the row keeps a boolean and drops the text.
    record = a_status(message="403 http://prowlarr:9696/7/api?apikey=SENTINEL")
    row = only(m.blocked_indexers([record], [an_indexer()], NOW))
    assert row["ban_evidence"] is True
    assert "SENTINEL" not in json.dumps(m._plain(row))


@pytest.mark.parametrize("statuses", [
    None, {}, [], "not a document", 7, [None, "x", 3], {"a": "b"},
])
def test_a_statuses_document_in_any_other_shape_blocks_nothing(statuses):
    # The documented shape is a list; a dict keyed by id is the same data.
    # Anything else is no records, not a traceback on a timer.
    assert m.blocked_indexers(statuses, None, NOW) == []


def test_blocked_indexers_come_back_in_a_stable_order():
    # Two runs over the same documents must produce the same list: the
    # decision is read in a log next to the previous run's.
    statuses = [a_status(id=1, indexerId=9), a_status(id=2, indexerId=7),
                a_status(id=3, indexerId=11)]
    indexers = [an_indexer(9, "YTS"), an_indexer(7, "1337x"), an_indexer(11, "zoo")]
    assert [row["name"] for row in m.blocked_indexers(statuses, indexers, NOW)] == \
        ["1337x", "YTS", "zoo"]


def test_a_naive_now_is_read_as_utc():
    rows = m.blocked_indexers([a_status()], [an_indexer()],
                              datetime(2026, 9, 15, 22, 0, 0))
    assert only(rows)["hours_remaining"] == 4.0


def test_the_remaining_hours_are_from_now_to_the_end_of_the_backoff():
    row = only(m.blocked_indexers([a_status(disabledTill=at(1.5))], [an_indexer()], NOW))
    assert row["hours_remaining"] == 1.5


# --- the decision ------------------------------------------------------------


def test_rotates_when_there_is_ban_evidence_and_the_cooldown_has_expired():
    rotate, reason = m.should_rotate([a_blocked()], NOW - timedelta(hours=7), NOW, 6.0)
    assert rotate is True
    assert "1337x" in reason
    assert reason.strip() and "\n" not in reason


def test_holds_while_the_cooldown_is_still_running():
    rotate, reason = m.should_rotate([a_blocked()], NOW - timedelta(hours=2), NOW, 6.0)
    assert rotate is False
    # The reason names the indexer and says how long is left: a log line
    # reading only "hold" is indistinguishable from a broken guard.
    assert "1337x" in reason
    assert "cooldown" in reason
    assert "4.0h left" in reason
    assert reason.strip() and "\n" not in reason


def test_a_rotation_exactly_on_the_cooldown_has_waited_long_enough():
    # The cooldown is a minimum time *between* rotations, so a rotation that
    # waited exactly six hours is one that waited.
    assert m.should_rotate([a_blocked()], NOW - timedelta(hours=6), NOW, 6.0)[0] is True


def test_a_never_rotated_stack_may_rotate():
    # None means this stack has never recorded a rotation, which cannot be
    # inside a cooldown: refusing here would mean never rotating at all.
    rotate, reason = m.should_rotate([a_blocked()], None, NOW, 6.0)
    assert rotate is True
    assert "1337x" in reason
    assert reason.strip() and "\n" not in reason


def test_a_blank_last_rotation_is_a_stack_that_has_never_rotated():
    assert m.should_rotate([a_blocked()], "   ", NOW, 6.0)[0] is True


def test_holds_when_indexers_are_blocked_without_ban_evidence():
    # The whole point: a timeout is a slow indexer, not a banned IP.
    rotate, reason = m.should_rotate([a_blocked(name="YTS", evidence=False)],
                                     None, NOW, 6.0)
    assert rotate is False
    assert "YTS" in reason
    assert "no ban evidence" in reason
    assert reason.strip() and "\n" not in reason


def test_nothing_blocked_never_rotates():
    rotate, reason = m.should_rotate([], None, NOW, 6.0)
    assert rotate is False
    assert reason.strip() and "\n" not in reason


def test_one_evidenced_indexer_is_enough():
    rows = [a_blocked("YTS", False, 9), a_blocked("1337x", True, 7)]
    rotate, reason = m.should_rotate(rows, NOW - timedelta(hours=10), NOW, 6.0)
    assert rotate is True
    assert "1337x" in reason
    # Only the indexers the decision is about are named: the timeout is not
    # part of why the VPN is about to move.
    assert "YTS" not in reason


def test_an_unreadable_last_rotation_holds_rather_than_rotating():
    # "Never rotated" and "a timestamp nobody can read" call for opposite
    # answers: the one irreversible action here must not be taken because the
    # record of the last one was garbled.
    rotate, reason = m.should_rotate([a_blocked()], "yesterday", NOW, 6.0)
    assert rotate is False
    assert reason.strip() and "\n" not in reason


def test_a_naive_last_rotation_is_read_as_utc():
    rotate, _ = m.should_rotate([a_blocked()], datetime(2026, 9, 15, 15, 0, 0), NOW, 6.0)
    assert rotate is True  # seven hours before NOW


def test_a_datetime_and_the_string_it_was_stored_as_decide_the_same_way():
    # The state file stores a string; a caller that already parsed it passes a
    # datetime. Reading one of those as "unreadable" would make the cooldown
    # depend on which one the caller happened to have.
    moment = NOW - timedelta(hours=2)
    assert m.should_rotate([a_blocked()], moment, NOW, 6.0)[0] == \
        m.should_rotate([a_blocked()], moment.isoformat(), NOW, 6.0)[0]


def test_a_naive_now_is_read_as_utc_here_too():
    rotate, _ = m.should_rotate([a_blocked()], NOW - timedelta(hours=7),
                                datetime(2026, 9, 15, 22, 0, 0), 6.0)
    assert rotate is True


def test_junk_in_the_blocked_list_does_not_stop_the_decision():
    rotate, _ = m.should_rotate([None, "x", a_blocked()], None, NOW, 6.0)
    assert rotate is True


def test_a_row_with_no_ban_evidence_key_is_not_evidence():
    # Truthiness is not the test; `is True` is. A row from a caller that put a
    # string there has not established a ban.
    assert m.should_rotate([{"name": "1337x", "ban_evidence": "yes"}],
                           None, NOW, 6.0)[0] is False


@pytest.mark.parametrize("cooldown", [0, 0.0, -1, -0.5, float("nan"), float("inf")])
def test_a_cooldown_that_is_not_above_zero_is_refused(cooldown):
    # Not silently read as "no cooldown": a cooldown of zero is a rotation on
    # every pass that has a failed indexer in it, which is a reconnect loop
    # with a VPN session inside it. The CLI refuses it at the argument; this
    # is the same refusal at the function.
    with pytest.raises(ValueError):
        m.should_rotate([a_blocked()], None, NOW, cooldown)


def test_a_custom_cooldown_is_the_one_that_applies():
    last = NOW - timedelta(hours=2)
    assert m.should_rotate([a_blocked()], last, NOW, 6.0)[0] is False
    assert m.should_rotate([a_blocked()], last, NOW, 1.0)[0] is True


def test_every_branch_of_the_decision_explains_itself_in_one_line():
    # Both answers, and every reason to give one: a wrapper's log is read to
    # find out why the VPN did or did not move.
    cases = [
        m.should_rotate([a_blocked()], None, NOW, 6.0),
        m.should_rotate([a_blocked()], NOW - timedelta(hours=1), NOW, 6.0),
        m.should_rotate([a_blocked()], NOW - timedelta(hours=7), NOW, 6.0),
        m.should_rotate([a_blocked()], "garbage", NOW, 6.0),
        m.should_rotate([a_blocked(evidence=False)], None, NOW, 6.0),
        m.should_rotate([], None, NOW, 6.0),
        m.should_rotate([a_blocked()], None, NOW, 6.0, EPOCH - 600),
        m.should_rotate([a_blocked()], None, NOW, 6.0, EPOCH - (21600 - 600)),
    ]
    assert {rotate for rotate, _ in cases} == {True, False}
    for _rotate, reason in cases:
        assert reason.strip()
        assert "\n" not in reason


# --- the rotator's schedule --------------------------------------------------
#
# The second actor on this tunnel, and the only reason this module knows a
# clock other than its own. Everything here is in epoch seconds, because that
# is what the shared file holds and what the wrapper passes: EPOCH is the
# fixture NOW as a number.


EPOCH = NOW.timestamp()


def test_holds_when_the_rotator_fires_inside_the_window():
    # Ten minutes until the rotator's own restart: rotating now would cycle the
    # tunnel twice inside ten minutes, for one ban.
    rotate, reason = m.should_rotate([a_blocked()], None, NOW, 6.0,
                                     EPOCH - (21600 - 600))
    assert rotate is False
    assert "1337x" in reason
    assert "10.0 minutes" in reason
    assert reason.strip() and "\n" not in reason


def test_holds_when_a_rotation_happened_inside_the_window():
    # A rotation ten minutes ago. Prowlarr is still latched into the backoff it
    # earned against the old IP, so its ban evidence says nothing about the new
    # one yet.
    rotate, reason = m.should_rotate([a_blocked()], None, NOW, 6.0, EPOCH - 600)
    assert rotate is False
    assert "1337x" in reason
    assert "10.0 minutes ago" in reason
    assert "re-probe" in reason
    assert reason.strip() and "\n" not in reason


def test_rotates_when_neither_rotator_window_applies():
    # Two hours since the last rotation and four hours until the next: the
    # rotator is at neither end of its schedule.
    rotate, reason = m.should_rotate([a_blocked()], None, NOW, 6.0,
                                     EPOCH - 7200)
    assert rotate is True
    assert "1337x" in reason
    assert "rotator" not in reason


def test_the_recent_window_is_inclusive_at_both_ends():
    # Closed window: a rotation exactly on `now`, and one exactly the window
    # old, both hold. One second beyond it does not -- by then Prowlarr has had
    # its full chance to fail against the new IP.
    assert m.should_rotate([a_blocked()], None, NOW, 6.0, EPOCH)[0] is False
    assert m.should_rotate([a_blocked()], None, NOW, 6.0, EPOCH - 1800)[0] is False
    assert m.should_rotate([a_blocked()], None, NOW, 6.0, EPOCH - 1801)[0] is True


def test_the_imminent_window_is_inclusive_at_both_ends():
    # The same two boundaries against the rotator's restart: exactly now, and
    # exactly the window away.
    interval = m.DEFAULT_ROTATOR_INTERVAL_SECONDS
    assert m.should_rotate([a_blocked()], None, NOW, 6.0,
                           EPOCH - interval)[0] is False
    assert m.should_rotate([a_blocked()], None, NOW, 6.0,
                           EPOCH - (interval - 1800))[0] is False
    assert m.should_rotate([a_blocked()], None, NOW, 6.0,
                           EPOCH - (interval - 1801))[0] is True


def test_a_rotator_timestamp_outside_both_windows_changes_nothing():
    # Present, readable, and irrelevant: the answer is the one the module gave
    # before it knew the rotator existed.
    assert m.should_rotate([a_blocked()], None, NOW, 6.0, EPOCH - 3 * 3600) == \
        m.should_rotate([a_blocked()], None, NOW, 6.0, None)


def test_a_stack_with_no_rotator_record_decides_exactly_as_before():
    # rotator_last None is every stack whose shared file has not been written:
    # the whole schedule half of the decision is skipped, so each of these is
    # compared against the same call without the argument.
    cases = [
        ([a_blocked()], None),
        ([a_blocked()], NOW - timedelta(hours=1)),
        ([a_blocked()], NOW - timedelta(hours=7)),
        ([a_blocked()], "garbage"),
        ([a_blocked(evidence=False)], None),
        ([], None),
    ]
    for blocked, last in cases:
        assert m.should_rotate(blocked, last, NOW, 6.0, None) == \
            m.should_rotate(blocked, last, NOW, 6.0)


def test_the_rotator_timestamp_does_not_feed_the_cooldown():
    # The cooldown is the guard's own: a rotation by the rotator five hours ago
    # is not five hours of the guard's cooldown, and a guard rotation seven
    # hours ago is still one that waited.
    rotate, reason = m.should_rotate([a_blocked()], NOW - timedelta(hours=7),
                                     NOW, 6.0, EPOCH - 5 * 3600)
    assert rotate is True
    assert "cooldown has expired" in reason


def test_the_rotator_windows_do_not_override_the_cooldown():
    # And the other direction: a rotator timestamp outside both windows does
    # not make a rotation inside the guard's own cooldown allowed.
    rotate, reason = m.should_rotate([a_blocked()], NOW - timedelta(hours=2),
                                     NOW, 6.0, EPOCH - 5 * 3600)
    assert rotate is False
    assert "4.0h left" in reason
    assert "re-probe" not in reason


def test_the_cooldown_is_reported_before_the_rotator_windows():
    # Both reasons to hold at once. The rotator's schedule is only consulted
    # for a rotation the guard is otherwise clear to make, so the cooldown's
    # own line is the one that comes back.
    rotate, reason = m.should_rotate([a_blocked()], NOW - timedelta(hours=2),
                                     NOW, 6.0, EPOCH - 600)
    assert rotate is False
    assert "cooldown" in reason
    assert "re-probe" not in reason


def test_rotator_hold_names_the_hold_and_the_minutes():
    assert m.rotator_hold(EPOCH - 600, NOW) == (m.ROTATOR_RECENT, 10.0)
    assert m.rotator_hold(EPOCH - (21600 - 600), NOW) == (m.ROTATOR_IMMINENT, 10.0)
    assert m.rotator_hold(None, NOW) == (None, None)
    assert m.rotator_hold(EPOCH - 7200, NOW) == (None, None)


def test_a_digit_string_timestamp_is_read_as_epoch_seconds():
    # The wrapper passes what it read out of the file through a variable, and
    # the module accepts the same value as text.
    assert m.rotator_hold(str(int(EPOCH)), NOW) == (m.ROTATOR_RECENT, 0.0)


@pytest.mark.parametrize("value", [
    None, "", "   ", "not a number", "12x", "1.5e9x", True, False, [], {}, object(),
])
def test_an_unusable_rotator_timestamp_is_no_known_rotation(value):
    # The shared file's own contract, at the function: missing, empty and
    # non-integer all mean "no known rotation", and each decides as None does.
    assert m.rotator_hold(value, NOW) == (None, None)
    assert m.should_rotate([a_blocked()], None, NOW, 6.0, value) == \
        m.should_rotate([a_blocked()], None, NOW, 6.0, None)


def test_the_window_is_configurable_in_minutes():
    # Five minutes is a different question from thirty: the same rotation is
    # recent under one window and not under the other.
    assert m.should_rotate([a_blocked()], None, NOW, 6.0,
                           EPOCH - 600, 21600, 30.0)[0] is False
    assert m.should_rotate([a_blocked()], None, NOW, 6.0,
                           EPOCH - 600, 21600, 5.0)[0] is True


def test_the_interval_is_configurable_in_seconds():
    # A three-hour interval puts the next restart somewhere else entirely: the
    # same timestamp is ten minutes from a restart under 10800 and over three
    # hours from one under the default.
    last = EPOCH - (10800 - 600)
    assert m.should_rotate([a_blocked()], None, NOW, 6.0,
                           last, 10800, 30.0)[0] is False
    assert m.should_rotate([a_blocked()], None, NOW, 6.0,
                           last, 21600, 30.0)[0] is True


@pytest.mark.parametrize("interval", [0, 0.0, -1, -0.5, float("nan"), float("inf")])
def test_a_rotator_interval_that_is_not_above_zero_is_refused(interval):
    # The cooldown's own refusal, applied to the interval it is compared with:
    # an interval of zero would make every known rotation "imminent".
    with pytest.raises(ValueError):
        m.should_rotate([a_blocked()], None, NOW, 6.0, EPOCH - 600, interval)


@pytest.mark.parametrize("window", [0, 0.0, -1, -0.5, float("nan"), float("inf")])
def test_a_rotator_window_that_is_not_above_zero_is_refused(window):
    with pytest.raises(ValueError):
        m.should_rotate([a_blocked()], None, NOW, 6.0, EPOCH - 600, 21600, window)


# --- the demand gate ---------------------------------------------------------
#
# The other half of a rotation: ban evidence says the IP is blocked, demand
# says this stack cares. The two ways to get the gate wrong are not
# symmetrical either. Holding a banned IP because Sonarr could not be reached
# leaves every indexer failing until someone notices; rotating for an indexer
# nothing here has ever downloaded from spends the outage for nothing. So the
# tests below are about the join, the name Sonarr spells differently, and which
# way an unreadable answer falls.


def a_demand(*names, known=True, error=None):
    """A demand state as demand_from_documents builds one.

    Names are given already normalised -- lower case, no " (Prowlarr)" suffix
    -- because that is what indexers_with_demand returns. The tests that spell
    a name the way Sonarr does go through the join itself.
    """
    return {"known": known, "indexers": set(names), "error": error}


def a_page(*records):
    """One Sonarr page, shaped the way the API sends it."""
    return {"page": 1, "pageSize": 1000, "totalRecords": len(records),
            "records": list(records)}


def a_grabbed(series_id, indexer):
    """One GET /api/v3/history?eventType=1 record."""
    return {"seriesId": series_id, "eventType": "grabbed",
            "data": {"indexer": indexer}}


def a_full_page(total, record, page=1, size=1000):
    """One page of `size` records, out of a document the envelope counts `total`.

    The two numbers are deliberately independent: `totalRecords` is the whole
    document's size, and a page that holds fewer records than its envelope
    claims is exactly what a walk that stopped early produces.
    """
    return {"page": page, "pageSize": size, "totalRecords": total,
            "records": [dict(record) for _ in range(size)]}


def write_pages(directory, name, pages):
    """`pages` written as <name>-1.json, <name>-2.json, ...; returns the paths.

    One file per page, the way the wrapper writes them, so a test declares the
    document as a whole and the flags as the walk produced them.
    """
    return [write(directory / f"{name}-{index}.json", page)
            for index, page in enumerate(pages, start=1)]


def test_sonarrs_prowlarr_suffix_comes_off_before_the_comparison():
    # Prowlarr owns the indexer and pushes it into Sonarr, which stores the
    # name with this suffix. The demand join compares the two documents, so the
    # suffix is the difference between "EZTV has demand" and "no indexer here
    # needs anything".
    assert m.normalise_indexer_name("EZTV (Prowlarr)") == "eztv"
    assert m.normalise_indexer_name("1337x (Prowlarr)") == "1337x"


def test_normalising_trims_and_folds_case():
    assert m.normalise_indexer_name("  EZTV  ") == "eztv"
    assert m.normalise_indexer_name("eZtV") == "eztv"
    assert m.normalise_indexer_name(" EZTV (Prowlarr) ") == "eztv"
    assert m.normalise_indexer_name("1337X (Prowlarr)") == "1337x"


def test_a_prowlarr_that_is_not_the_trailing_suffix_is_part_of_the_name():
    # "exactly that trailing suffix": a name that merely contains the text is
    # a different indexer, and stripping it would join two of them.
    assert m.normalise_indexer_name("EZTV (Prowlarr) HD") == "eztv (prowlarr) hd"
    assert m.normalise_indexer_name("(Prowlarr) EZTV") == "(prowlarr) eztv"
    assert m.normalise_indexer_name("EZTV (Prowlarrs)") == "eztv (prowlarrs)"
    assert m.normalise_indexer_name("EZTV (Prowlarr) (Prowlarr)") == "eztv (prowlarr)"


def test_a_name_that_is_not_text_normalises_to_nothing():
    # The empty string never matches anything, which is the point: a number or
    # a null in the field is not a name, and returning it unchanged would let
    # two nameless records match each other.
    for value in (None, 7, 4.2, True, {}, [], object()):
        assert m.normalise_indexer_name(value) == ""


def test_a_grab_for_a_missing_series_is_demand():
    missing = [{"seriesId": 12, "monitored": True}]
    history = [a_grabbed(12, "EZTV (Prowlarr)")]
    assert m.indexers_with_demand(missing, history) == {"eztv"}


def test_a_grab_for_a_series_that_is_not_missing_is_not_demand():
    # The series is complete today, so the one indexer that ever supplied it is
    # not one this stack needs anything from.
    missing = [{"seriesId": 12}]
    history = [a_grabbed(99, "EZTV (Prowlarr)")]
    assert m.indexers_with_demand(missing, history) == set()


def test_nothing_missing_is_no_demand_from_anyone():
    # Half of the join, and the half that decides the other way: a stack with
    # nothing missing has no demand at all, however many grabs its history
    # holds.
    history = [a_grabbed(12, "EZTV (Prowlarr)"), a_grabbed(13, "YTS")]
    assert m.indexers_with_demand([], history) == set()
    assert m.indexers_with_demand([{"seriesId": None}], history) == set()


def test_only_series_with_a_missing_episode_can_carry_demand():
    # An unmonitored episode and an already-downloaded one are not in the
    # document at all: `monitored=true` is the request's filter, asserted in
    # tests/indexer-guard.bats. What the module enforces is the join's other
    # half -- a grab for a series the missing document does not name was for a
    # series that is not missing, whatever the reason.
    missing = a_page({"seriesId": 12})
    history = a_page(a_grabbed(12, "EZTV (Prowlarr)"),
                     a_grabbed(13, "YTS"), a_grabbed(14, "RARBG"))
    assert m.indexers_with_demand(missing, history) == {"eztv"}


def test_several_indexers_with_demand_come_back_together():
    missing = [{"seriesId": 1}, {"seriesId": 2}]
    history = [a_grabbed(1, "EZTV (Prowlarr)"), a_grabbed(2, "yts"),
               a_grabbed(2, "EZTV (Prowlarr)")]
    assert m.indexers_with_demand(missing, history) == {"eztv", "yts"}


def test_a_history_record_with_no_usable_indexer_is_skipped():
    missing = [{"seriesId": 12}]
    history = [
        {"seriesId": 12},
        {"seriesId": 12, "data": None},
        {"seriesId": 12, "data": "EZTV (Prowlarr)"},
        a_grabbed(12, ""),
        a_grabbed(12, "   "),
        a_grabbed(12, None),
    ]
    assert m.indexers_with_demand(missing, history) == set()


def test_a_series_id_that_arrived_as_a_string_still_joins():
    # The same document round-tripped through a shell or a viewer comes back
    # with quotes. _as_id accepts both, so the join does too.
    missing = [{"seriesId": "12"}]
    history = [a_grabbed(12, "EZTV (Prowlarr)")]
    assert m.indexers_with_demand(missing, history) == {"eztv"}


@pytest.mark.parametrize("document", [None, {}, [], "not a document", 7, [None, "x"]])
def test_a_demand_document_in_any_other_shape_has_no_records(document):
    assert m.indexers_with_demand(document, document) == set()


def test_a_paginated_page_is_read_as_its_records(tmp_path):
    # Sonarr answers with an envelope, not a bare array, and `records` is where
    # every field this gate reads lives.
    missing = write(tmp_path / "missing.json", a_page({"seriesId": 12}))
    history = write(tmp_path / "history.json", a_page(a_grabbed(12, "EZTV (Prowlarr)")))
    state = m.demand_from_documents([missing], [history])
    assert state["known"] is True
    assert state["indexers"] == {"eztv"}


def test_several_pages_of_one_document_are_joined():
    # The wrapper writes one file per page and repeats the flag; the pages are
    # one document as far as the join is concerned.
    missing_a = {"page": 1, "records": [{"seriesId": 12}]}
    missing_b = {"page": 2, "records": [{"seriesId": 13}]}
    history = {"page": 1, "records": [a_grabbed(13, "EZTV (Prowlarr)")]}
    # Through the pure join, which is what the CLI feeds both pages into.
    assert m.indexers_with_demand(missing_a["records"] + missing_b["records"],
                                  history["records"]) == {"eztv"}


@pytest.mark.parametrize("blocks", [
    [None], [{}], [[]], ["not a document"], [{"page": 1}], [{"records": "no"}],
])
def test_a_demand_document_with_no_records_is_an_empty_join(blocks):
    assert m.indexers_with_demand(blocks, blocks) == set()


def test_no_demand_flags_at_all_is_not_a_demand_input():
    # None, not an empty state: nothing asked Sonarr, and the decision has to
    # be the one this module made before the gate existed.
    assert m.demand_from_documents(None, None, None) is None
    assert m.demand_from_documents([], [], None) is None


def test_a_wrapper_that_could_not_fetch_is_unknown_demand():
    state = m.demand_from_documents(None, None, "Sonarr unreachable")
    assert state == {"known": False, "indexers": frozenset(),
                     "error": "Sonarr unreachable"}


def test_half_of_the_join_is_unknown_demand():
    # Both documents are needed to know anything: with one of them there is no
    # join to make, and "no demand" would be a guess.
    assert m.demand_from_documents(["missing.json"], [], None)["known"] is False
    assert m.demand_from_documents([], ["history.json"], None)["known"] is False
    assert "both Sonarr documents" in \
        m.demand_from_documents([], ["history.json"], None)["error"]


def test_an_empty_missing_document_is_a_real_answer(tmp_path):
    # Sonarr saying "nothing is missing" is known demand with nothing in it --
    # not an unknown one. Reading it as unknown would skip the gate and rotate
    # for an indexer nothing here needs.
    missing = write(tmp_path / "missing.json", a_page())
    history = write(tmp_path / "history.json", a_page(a_grabbed(12, "EZTV (Prowlarr)")))
    state = m.demand_from_documents([missing], [history])
    assert state["known"] is True
    assert state["indexers"] == frozenset()


@pytest.mark.parametrize("content", ["", "{ not json", "<html>nope</html>", "[1,"])
def test_a_malformed_demand_document_is_unknown_demand(content, tmp_path):
    # Fail open all the way down: a page that cannot be read is demand nobody
    # knows, not a traceback on a timer and not "no demand".
    missing = write(tmp_path / "missing.json", a_page({"seriesId": 12}))
    history = tmp_path / "history.json"
    history.write_text(content)
    state = m.demand_from_documents([missing], [str(history)])
    assert state["known"] is False
    assert state["indexers"] == frozenset()
    assert "not JSON" in state["error"]


def test_a_demand_page_that_is_not_there_is_unknown_demand(tmp_path):
    state = m.demand_from_documents([str(tmp_path / "nope.json")],
                                    [str(tmp_path / "also-nope.json")])
    assert state["known"] is False
    assert "cannot read" in state["error"]


# --- a walk that stopped short -----------------------------------------------
#
# The wrapper fetches Sonarr's pages until the envelope's own count is covered,
# bounded by its page cap and its time budget. Whatever the reason it stopped,
# the pages in hand are not the whole document, and a join over them is the
# dangerous reading: an indexer whose grabs are all on the pages nobody fetched
# looks exactly like an indexer with no demand, and that hold leaves a banned IP
# in place while every indexer behind it fails. So an incomplete document is
# demand UNKNOWN -- fail open, like every other unreadable answer -- and the
# note says which document and how much of it arrived.


def test_a_multi_page_document_that_adds_up_is_known_demand(tmp_path):
    # Three pages of a thousand records each, and envelopes that count 3000:
    # the walk covered the document, so the join is made on all of it. This is
    # the shape the early stop produces on a healthy stack, and it has to stay
    # a known answer -- reading every multi-page document as truncated would
    # make the gate unknown forever.
    missing = write_pages(tmp_path, "missing",
                          [a_full_page(3000, {"seriesId": 12}, page=page)
                           for page in (1, 2, 3)])
    history = write_pages(
        tmp_path, "history",
        [a_full_page(3000, a_grabbed(12, "1337x (Prowlarr)"), page=page)
         for page in (1, 2, 3)])
    state = m.demand_from_documents(missing, history)
    assert state["known"] is True
    assert state["indexers"] == {"1337x"}


def test_pages_that_add_up_exactly_to_the_envelope_are_complete(tmp_path):
    # The boundary, and the comparison is inclusive: collected == totalRecords
    # is the whole document. `>` here would make the gate unknown for every
    # library whose history is a whole number of pages, which is every document
    # Sonarr serves with totalRecords == page * pageSize.
    missing = write(tmp_path / "missing.json",
                    a_full_page(1000, {"seriesId": 12}))
    history = write(tmp_path / "history.json",
                    a_full_page(1000, a_grabbed(12, "1337x (Prowlarr)")))
    state = m.demand_from_documents([missing], [history])
    assert state["known"] is True
    assert state["indexers"] == {"1337x"}


def test_a_truncated_history_document_is_unknown_demand(tmp_path):
    # Five pages of a thousand, from a history the envelope says holds 7120 --
    # the pre-fix wrapper's exact walk, and the count it never read.
    missing = write(tmp_path / "missing.json", a_page({"seriesId": 12}))
    history = write_pages(
        tmp_path, "history",
        [a_full_page(7120, a_grabbed(99, "1337x (Prowlarr)"), page=page)
         for page in range(1, 6)])
    state = m.demand_from_documents([missing], history)
    assert state["known"] is False
    assert state["indexers"] == frozenset()
    assert state["error"] == "Sonarr history truncated: 5000 of 7120 records"


def test_a_truncated_history_fails_open_and_rotates(tmp_path):
    # The failure the truncation check exists to prevent, in the direction it
    # has to fall. The pages in hand show 1337x grabbing series 99 and nothing
    # for the missing series 12, so a join over them alone would hold the
    # rotation -- while the grabs that would justify it sit on page six. The
    # answer is unknown demand: the rotation happens, and the reason names the
    # document that was read short.
    missing = write(tmp_path / "missing.json", a_page({"seriesId": 12}))
    history = write_pages(
        tmp_path, "history",
        [a_full_page(7120, a_grabbed(99, "1337x (Prowlarr)"), page=page)
         for page in range(1, 6)])
    state = m.demand_from_documents([missing], history)
    rotate, reason = m.should_rotate([a_blocked()], None, NOW, 6.0,
                                     demand=state)
    assert rotate is True
    assert "1337x show ban evidence" in reason
    assert "Sonarr demand unknown: Sonarr history truncated: 5000 of 7120 records" in reason
    assert reason.strip() and "\n" not in reason


def test_a_truncated_missing_document_is_unknown_demand(tmp_path):
    # The other half of the join, and the same rule: an incomplete list of what
    # is missing is not "nothing is missing".
    missing = write_pages(tmp_path, "missing",
                          [a_full_page(4000, {"seriesId": 12}, page=page)
                           for page in (1, 2)])
    history = write(tmp_path / "history.json",
                    a_page(a_grabbed(12, "1337x (Prowlarr)")))
    state = m.demand_from_documents(missing, [history])
    assert state["known"] is False
    assert state["error"] == \
        "Sonarr missing episodes truncated: 2000 of 4000 records"


def test_both_truncated_documents_are_named_in_the_note(tmp_path):
    missing = write_pages(tmp_path, "missing",
                          [a_full_page(4000, {"seriesId": 12}, page=page)
                           for page in (1, 2)])
    history = write_pages(
        tmp_path, "history",
        [a_full_page(3000, a_grabbed(12, "1337x (Prowlarr)"), page=page)
         for page in (1, 2)])
    state = m.demand_from_documents(missing, history)
    assert state["known"] is False
    assert state["error"] == (
        "Sonarr missing episodes truncated: 2000 of 4000 records; "
        "Sonarr history truncated: 2000 of 3000 records")


def test_the_largest_total_records_across_the_pages_is_the_one_judged(tmp_path):
    # Sonarr's count moves while the walk runs -- two more grabs arrived between
    # page one and page two. The largest claim is the one that says how much of
    # the document the pages have to cover, so the comparison is against 2600,
    # not the 2500 page one happened to report first.
    missing = write(tmp_path / "missing.json", a_page({"seriesId": 12}))
    history = [
        write(tmp_path / "history-1.json",
              a_full_page(2500, a_grabbed(12, "1337x (Prowlarr)"))),
        write(tmp_path / "history-2.json",
              a_full_page(2600, a_grabbed(12, "1337x (Prowlarr)"), page=2)),
    ]
    state = m.demand_from_documents([missing], history)
    assert state["known"] is False
    assert state["error"] == "Sonarr history truncated: 2000 of 2600 records"


def test_bare_arrays_are_taken_as_complete(tmp_path):
    # A caller that hands over the records themselves makes no claim about a
    # whole document, so there is nothing to be short of. Treating them as
    # truncated would make every hand-run and every direct caller unknown.
    missing = write(tmp_path / "missing.json", [{"seriesId": 12}])
    history = write(tmp_path / "history.json",
                    [a_grabbed(12, "1337x (Prowlarr)")])
    state = m.demand_from_documents([missing], [history])
    assert state["known"] is True
    assert state["indexers"] == {"1337x"}


def test_an_envelope_with_no_usable_count_is_taken_as_complete(tmp_path):
    # The same rule one step in: an envelope whose totalRecords is missing,
    # null, negative or not a number claims nothing, and a claim nobody made
    # cannot be short. What it must NOT do is read as zero, which would report
    # a truncated document for every page a proxy or a viewer stripped a field
    # from.
    missing = write(tmp_path / "missing.json", a_page({"seriesId": 12}))
    for unusable in (None, "many", -1, True, 1.5, []):
        history = tmp_path / "history.json"
        history.write_text(json.dumps({
            "page": 1, "pageSize": 1000, "totalRecords": unusable,
            "records": [a_grabbed(12, "1337x (Prowlarr)")]}))
        state = m.demand_from_documents([missing], [str(history)])
        assert state["known"] is True, unusable
        assert state["indexers"] == {"1337x"}, unusable


def test_a_banned_indexer_with_demand_rotates():
    rotate, reason = m.should_rotate([a_blocked()], None, NOW, 6.0,
                                     demand=a_demand("1337x"))
    assert rotate is True
    assert "1337x" in reason
    assert "no Sonarr demand" not in reason


def test_a_banned_indexer_without_demand_holds_with_the_demand_reason():
    # The whole point of the gate. The IP is banned for this indexer and
    # nothing here needs it: the rotation is held, and the reason says which
    # indexer it is not for.
    rotate, reason = m.should_rotate([a_blocked()], None, NOW, 6.0,
                                     demand=a_demand())
    assert rotate is False
    assert "banned indexers have no Sonarr demand: 1337x" in reason
    assert "not rotating" in reason
    assert reason.strip() and "\n" not in reason


def test_one_banned_indexer_with_demand_is_enough():
    # A mixed set rotates, and names the indexer it is not for beside the one
    # it is: "rotating, and here is what is not part of why".
    rows = [a_blocked("1337x", True, 7), a_blocked("EZTV", True, 9)]
    rotate, reason = m.should_rotate(rows, None, NOW, 6.0,
                                     demand=a_demand("1337x"))
    assert rotate is True
    assert "1337x" in reason
    assert "no Sonarr demand for EZTV" in reason
    assert reason.strip() and "\n" not in reason


def test_the_gate_compares_the_names_the_join_compares():
    # A row labelled the way Sonarr labels it, and a demand set normalised the
    # way the join normalises it. Getting one side only right is no demand at
    # all, which is a silent hold.
    assert m.should_rotate([a_blocked("EzTv (Prowlarr)", True, 7)], None, NOW,
                           6.0, demand=a_demand("eztv"))[0] is True
    assert m.should_rotate([a_blocked("EZTV", True, 7)], None, NOW, 6.0,
                           demand=a_demand("eztv"))[0] is True
    assert m.should_rotate([a_blocked("EzTv (Prowlarr) HD", True, 7)], None,
                           NOW, 6.0, demand=a_demand("eztv"))[0] is False


def test_the_demand_gate_does_not_override_the_cooldown():
    # The ordering, and the reason for it: a cooldown that is still running
    # holds any rotation at all, demand or no demand, and the reason says the
    # cooldown rather than Sonarr -- the demand was never consulted.
    rotate, reason = m.should_rotate([a_blocked()], NOW - timedelta(hours=2),
                                     NOW, 6.0, demand=a_demand())
    assert rotate is False
    assert "cooldown" in reason
    assert "4.0h left" in reason
    assert "Sonarr" not in reason


def test_the_demand_gate_does_not_override_the_rotator_window():
    rotate, reason = m.should_rotate([a_blocked()], None, NOW, 6.0,
                                     EPOCH - 600, demand=a_demand())
    assert rotate is False
    assert "re-probe" in reason
    assert "Sonarr" not in reason


def test_the_demand_gate_is_not_consulted_without_ban_evidence():
    rotate, reason = m.should_rotate([a_blocked(evidence=False)], None, NOW,
                                     6.0, demand=a_demand())
    assert rotate is False
    assert "no ban evidence" in reason
    assert "Sonarr" not in reason


def test_unknown_demand_fails_open_with_a_note():
    # A Sonarr that cannot be reached must not ground a banned IP: the rotation
    # still happens, and the reason says the demand half was unknown rather
    # than leaving the reader to guess.
    rotate, reason = m.should_rotate([a_blocked()], None, NOW, 6.0,
                                     demand=a_demand(known=False,
                                                     error="Sonarr unreachable"))
    assert rotate is True
    assert "1337x show ban evidence" in reason
    assert "Sonarr demand unknown: Sonarr unreachable" in reason
    assert reason.strip() and "\n" not in reason


def test_unknown_demand_does_not_change_a_hold_that_was_already_decided():
    # Fail open is about not inventing a hold; it is not a reason to decorate
    # one that the cooldown already justified.
    before = m.should_rotate([a_blocked()], NOW - timedelta(hours=2), NOW, 6.0)
    after = m.should_rotate([a_blocked()], NOW - timedelta(hours=2), NOW, 6.0,
                            demand=a_demand(known=False, error="Sonarr unreachable"))
    assert after == before


def test_no_demand_input_leaves_the_decision_untouched():
    # The gate cannot decorate a decision it was never given input for: with no
    # demand argument, every reason is the sentence this module printed before
    # the gate existed, and the document that pairs with it carries no demand
    # field at all. That is what makes a pass without Sonarr data comparable
    # with every pass before it.
    cases = [
        ([a_blocked()], None),
        ([a_blocked()], NOW - timedelta(hours=1)),
        ([a_blocked()], NOW - timedelta(hours=7)),
        ([a_blocked()], "garbage"),
        ([a_blocked(evidence=False)], None),
        ([a_blocked("1337x", True, 7), a_blocked("YTS", False, 9)], None),
        ([], None),
    ]
    for blocked, last in cases:
        # Not "two identical calls agree": the demand-free answer has to BE the
        # pre-gate decision, bit for bit, which is what _decide_ban_evidence is.
        assert m.should_rotate(blocked, last, NOW, 6.0) == \
            m._decide_ban_evidence(blocked, last, NOW, 6.0, None,
                                   m.DEFAULT_ROTATOR_INTERVAL_SECONDS,
                                   m.DEFAULT_ROTATOR_WINDOW_MINUTES)[:2], blocked
        _rotate, reason = m.should_rotate(blocked, last, NOW, 6.0)
        assert "Sonarr" not in reason, blocked
        assert reason.strip() and "\n" not in reason, blocked

    view = m.decision([a_status()], [an_indexer()], m.empty_state(), NOW, 6.0)
    assert not [key for key in view if "demand" in key or "banned_" in key]


def test_unreadable_demand_is_a_skip_with_a_note_not_a_hold():
    # Every case where the module would rotate stays a rotation, with the note
    # that says the demand half was not judged; every case where it had already
    # decided to hold is untouched, because there was no demand decision to
    # note.
    cases = [
        ([a_blocked()], None),
        ([a_blocked()], NOW - timedelta(hours=1)),
        ([a_blocked()], NOW - timedelta(hours=7)),
        ([a_blocked()], "garbage"),
        ([a_blocked(evidence=False)], None),
        ([a_blocked("1337x", True, 7), a_blocked("YTS", False, 9)], None),
        ([], None),
    ]
    for blocked, last in cases:
        base = m.should_rotate(blocked, last, NOW, 6.0)
        unknown = m.should_rotate(blocked, last, NOW, 6.0,
                                  demand=a_demand(known=False))
        assert unknown[0] == base[0], blocked
        if base[0]:
            assert unknown[1].startswith(base[1]), blocked
            assert "Sonarr demand unknown" in unknown[1], blocked
        else:
            assert unknown == base, blocked


def test_the_demand_fields_a_known_gate_adds():
    view = m.decision([a_status(message="Cloudflare error 1006")],
                      [an_indexer()], m.empty_state(), NOW, 6.0,
                      demand=a_demand("1337x"))
    assert view["demand_known"] is True
    assert view["demand_error"] is None
    assert view["banned_with_demand"] == ["1337x"]
    assert view["banned_without_demand"] == []


def test_the_demand_fields_an_unknown_gate_adds():
    # Null, not empty: an unread document is not a list of indexers nothing
    # needs, and a reader has to be able to tell those apart.
    view = m.decision([a_status()], [an_indexer()], m.empty_state(), NOW, 6.0,
                      demand=a_demand(known=False, error="Sonarr unreachable"))
    assert view["demand_known"] is False
    assert view["demand_error"] == "Sonarr unreachable"
    assert view["banned_with_demand"] is None
    assert view["banned_without_demand"] is None


def test_the_demand_document_splits_a_mixed_banned_set():
    statuses = [a_status(id=4, indexerId=7, message="Cloudflare error 1006"),
                a_status(id=5, indexerId=9, message="403 Forbidden")]
    indexers = [an_indexer(7, "1337x"), an_indexer(9, "EZTV")]
    view = m.decision(statuses, indexers, m.empty_state(), NOW, 6.0,
                      demand=a_demand("1337x"))
    assert view["banned_with_demand"] == ["1337x"]
    assert view["banned_without_demand"] == ["EZTV"]
    assert view["rotate"] is True


def test_main_rotates_on_a_demand_document_that_matches(tmp_path, capsys):
    statuses = write(tmp_path / "statuses.json",
                     [live_status(message="Cloudflare error 1006")])
    indexers = write(tmp_path / "indexers.json", [an_indexer()])
    missing = write(tmp_path / "missing.json", a_page({"seriesId": 12}))
    history = write(tmp_path / "history.json", a_page(a_grabbed(12, "1337x (Prowlarr)")))

    assert m.main(["--statuses", statuses, "--indexers", indexers,
                   "--state", str(tmp_path / "state.json"),
                   "--demand-missing", missing, "--demand-history", history,
                   "--json"]) == 0
    view = json.loads(capsys.readouterr().out)
    assert view["rotate"] is True
    assert view["demand_known"] is True
    assert view["banned_with_demand"] == ["1337x"]


def test_main_holds_on_a_demand_document_that_does_not(tmp_path, capsys):
    statuses = write(tmp_path / "statuses.json",
                     [live_status(message="Cloudflare error 1006")])
    missing = write(tmp_path / "missing.json", a_page({"seriesId": 12}))
    history = write(tmp_path / "history.json", a_page(a_grabbed(99, "EZTV (Prowlarr)")))

    assert m.main(["--statuses", statuses,
                   "--state", str(tmp_path / "state.json"),
                   "--demand-missing", missing, "--demand-history", history,
                   "--json"]) == 0
    view = json.loads(capsys.readouterr().out)
    assert view["rotate"] is False
    assert "banned indexers have no Sonarr demand" in view["reason"]
    assert view["banned_without_demand"] == ["indexer 7"]


def test_main_fails_open_on_a_malformed_demand_document(tmp_path, capsys):
    statuses = write(tmp_path / "statuses.json",
                     [live_status(message="Cloudflare error 1006")])
    missing = write(tmp_path / "missing.json", a_page({"seriesId": 12}))
    history = tmp_path / "history.json"
    history.write_text("{ not json")

    assert m.main(["--statuses", statuses,
                   "--state", str(tmp_path / "state.json"),
                   "--demand-missing", missing,
                   "--demand-history", str(history), "--json"]) == 0
    view = json.loads(capsys.readouterr().out)
    assert view["rotate"] is True
    assert view["demand_known"] is False
    assert view["banned_with_demand"] is None
    assert "Sonarr demand unknown" in view["reason"]


def test_main_notes_a_demand_error_the_wrapper_sent(tmp_path, capsys):
    # The wrapper's fail-open path: it could not fetch, so it says so and sends
    # no documents. The decision is the one without the gate, plus the note.
    statuses = write(tmp_path / "statuses.json",
                     [live_status(message="Cloudflare error 1006")])

    assert m.main(["--statuses", statuses,
                   "--state", str(tmp_path / "state.json"),
                   "--demand-error", "the Sonarr history request failed",
                   "--json"]) == 0
    view = json.loads(capsys.readouterr().out)
    assert view["rotate"] is True
    assert view["demand_known"] is False
    assert view["demand_error"] == "the Sonarr history request failed"
    assert "Sonarr demand unknown: the Sonarr history request failed" in view["reason"]


def test_main_with_no_demand_flags_prints_no_demand_fields(tmp_path, capsys):
    statuses = write(tmp_path / "statuses.json",
                     [live_status(message="Cloudflare error 1006")])
    assert m.main(["--statuses", statuses,
                   "--state", str(tmp_path / "state.json"), "--json"]) == 0
    view = json.loads(capsys.readouterr().out)
    assert not [key for key in view if "demand" in key or "banned_" in key]


def test_the_text_line_carries_the_demand_summary(tmp_path, capsys):
    statuses = write(tmp_path / "statuses.json",
                     [live_status(message="Cloudflare error 1006")])
    indexers = write(tmp_path / "indexers.json", [an_indexer()])
    missing = write(tmp_path / "missing.json", a_page({"seriesId": 12}))
    history = write(tmp_path / "history.json", a_page(a_grabbed(12, "1337x (Prowlarr)")))

    assert m.main(["--statuses", statuses, "--indexers", indexers,
                   "--state", str(tmp_path / "state.json"),
                   "--demand-missing", missing, "--demand-history", history]) == 0
    out = capsys.readouterr().out
    assert out.startswith("rotate: ")
    assert "Sonarr demand: 1337x" in out
    assert "no Sonarr demand: none" in out


def test_the_verdict_carries_the_demand_summary(tmp_path, capsys):
    # The wrapper's --verdict path is what writes its log line, so a hold the
    # gate caused has to say so there too.
    document = write(tmp_path / "decision.json", {
        "rotate": False,
        "reason": "banned indexers have no Sonarr demand: 1337x; not rotating",
        "demand_known": True,
        "demand_error": None,
        "banned_with_demand": [],
        "banned_without_demand": ["1337x"],
    })
    assert m.main(["--verdict", document]) == 0
    out = capsys.readouterr().out
    assert out.startswith("hold\tbanned indexers have no Sonarr demand")
    assert "Sonarr demand: none; no Sonarr demand: 1337x" in out


def test_the_verdict_carries_an_unknown_demand_note(tmp_path, capsys):
    document = write(tmp_path / "decision.json", {
        "rotate": True,
        "reason": "1337x show ban evidence; rotating",
        "demand_known": False,
        "demand_error": "Sonarr unreachable",
        "banned_with_demand": None,
        "banned_without_demand": None,
    })
    assert m.main(["--verdict", document]) == 0
    out = capsys.readouterr().out
    assert out.startswith("rotate\t1337x show ban evidence; rotating")
    assert "Sonarr demand unknown: Sonarr unreachable" in out


def test_a_document_that_never_asked_sonarr_renders_no_demand_line(tmp_path, capsys):
    # The whole fail-open guarantee in one assertion: what --verdict prints for
    # a decision without demand data is exactly what it printed before the gate
    # existed.
    document = write(tmp_path / "decision.json",
                     {"rotate": True, "reason": "1337x show ban evidence; rotating"})
    assert m.main(["--verdict", document]) == 0
    assert capsys.readouterr().out == \
        "rotate\t1337x show ban evidence; rotating\n"


# --- reading one page's envelope ---------------------------------------------
#
# The wrapper's paging half. The walk has to know how big the whole document is
# before it can fetch the right number of pages, and the shell parses no JSON,
# so the module prints that one integer for it. A document it cannot read is an
# error rather than a zero: zero is a real answer -- Sonarr saying the document
# is empty -- and a made-up one would become a hold, while the caller's
# fail-open path is only reached when this exits non-zero.


def test_page_total_mode_prints_the_envelope_count(tmp_path, capsys):
    page = write(tmp_path / "page.json",
                 a_page(*(a_grabbed(series, "1337x") for series in range(7))))
    assert m.main(["--page-total", page]) == 0
    assert capsys.readouterr().out == "7\n"


def test_page_total_mode_prints_a_zero_count(tmp_path, capsys):
    # Zero is a real answer, and the caller's ceil() is what still fetches page
    # one for it. Reading it as a failure would skip the gate on a stack whose
    # missing list happens to be empty.
    page = write(tmp_path / "page.json", a_page())
    assert m.main(["--page-total", page]) == 0
    assert capsys.readouterr().out == "0\n"


def test_page_total_mode_reads_a_digit_string_as_its_number(tmp_path, capsys):
    # The same leniency _as_id has, for the same reason: the document
    # round-tripped through a viewer comes back with quotes.
    page = write(tmp_path / "page.json",
                 {"page": 1, "totalRecords": "7120", "records": []})
    assert m.main(["--page-total", page]) == 0
    assert capsys.readouterr().out == "7120\n"


@pytest.mark.parametrize("document", [
    {"page": 1, "pageSize": 1000, "records": []},                   # no field
    {"page": 1, "pageSize": 1000, "totalRecords": None, "records": []},
    {"page": 1, "pageSize": 1000, "totalRecords": "many", "records": []},
    {"page": 1, "pageSize": 1000, "totalRecords": True, "records": []},
    {"page": 1, "pageSize": 1000, "totalRecords": -1, "records": []},
    {"page": 1, "pageSize": 1000, "totalRecords": 1.5, "records": []},
    [{"seriesId": 12}],                                             # a bare array
    {"records": [{"seriesId": 12}]},
    "not a document",
])
def test_page_total_mode_refuses_a_document_that_is_not_an_envelope(document, tmp_path, capsys):
    path = write(tmp_path / "page.json", document)
    assert m.main(["--page-total", path]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "envelope" in captured.err


@pytest.mark.parametrize("content", ["", "{ not json", "<html>nope</html>", "[1,"])
def test_page_total_mode_refuses_a_malformed_document(content, tmp_path, capsys):
    # An HTML error page served with a 200 is what a proxy in front of Sonarr
    # produces. It has to be a failure here, or the walk is sized from a
    # document nobody read.
    page = tmp_path / "page.json"
    page.write_text(content)
    assert m.main(["--page-total", str(page)]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "not JSON" in captured.err


def test_page_total_mode_refuses_a_document_it_cannot_open(tmp_path, capsys):
    assert m.main(["--page-total", str(tmp_path / "nope.json")]) == 2
    assert "cannot read" in capsys.readouterr().err


def test_page_total_mode_reads_stdin_with_a_dash(monkeypatch, capsys):
    monkeypatch.setattr(sys, "stdin", io.StringIO(json.dumps(
        {"page": 1, "pageSize": 1000, "totalRecords": 2963, "records": []})))
    assert m.main(["--page-total", "-"]) == 0
    assert capsys.readouterr().out == "2963\n"


# --- the state file ----------------------------------------------------------


def test_load_state_tolerates_a_missing_file(tmp_path):
    assert m.load_state(str(tmp_path / "nope.json")) == {"last_rotation": None,
                                                         "rotations": 0}


def test_load_state_tolerates_a_directory(tmp_path):
    # The path is a --state argument someone typed, so it can be anything.
    assert m.load_state(str(tmp_path)) == m.empty_state()


@pytest.mark.parametrize("content", [
    "",                     # an empty file, or a write that never landed
    "{ not json at all",    # a truncated write
    "[1, 2, 3]",            # a JSON array where an object was expected
    '"a string"',
    "42",
    "null",
])
def test_load_state_tolerates_every_unusable_document(content, tmp_path):
    path = tmp_path / "state.json"
    path.write_text(content)
    assert m.load_state(str(path)) == m.empty_state()


def test_load_state_returns_a_well_formed_state_that_can_be_decided_from(tmp_path):
    # The fallback is not just non-raising: it has to be the state a decision
    # can be made from, which is the whole reason a broken file is survivable.
    path = tmp_path / "state.json"
    path.write_text("{ truncated")
    state = m.load_state(str(path))
    assert m.should_rotate([a_blocked()], state["last_rotation"], NOW, 6.0)[0] is True


def test_load_state_keeps_a_recorded_rotation(tmp_path):
    path = tmp_path / "state.json"
    path.write_text(json.dumps({
        "last_rotation": "2026-09-15T20:00:00+00:00",
        "rotations": 3,
    }))
    state = m.load_state(str(path))
    assert state["last_rotation"] == "2026-09-15T20:00:00+00:00"
    assert state["rotations"] == 3


@pytest.mark.parametrize("rotations", ["three", -1, 2.5, True, None, [], {}])
def test_load_state_normalises_a_counter_that_is_not_one(rotations, tmp_path):
    path = tmp_path / "state.json"
    path.write_text(json.dumps({"last_rotation": "2026-09-15T20:00:00+00:00",
                                "rotations": rotations}))
    assert m.load_state(str(path))["rotations"] == 0


def test_load_state_normalises_a_blank_timestamp_to_none(tmp_path):
    path = tmp_path / "state.json"
    path.write_text(json.dumps({"last_rotation": "   ", "rotations": 1}))
    assert m.load_state(str(path))["last_rotation"] is None


def test_load_state_keeps_keys_it_does_not_know(tmp_path):
    # A state file written by a later version -- or by a person -- must not
    # lose everything this version does not recognise on the next read.
    path = tmp_path / "state.json"
    path.write_text(json.dumps({"last_rotation": None, "rotations": 1,
                                "note": "kept"}))
    assert m.load_state(str(path))["note"] == "kept"


def test_save_state_round_trips_through_load_state(tmp_path):
    path = tmp_path / "state" / "indexer-guard.json"
    m.save_state(str(path), m.record_rotation(m.empty_state(), NOW))
    state = m.load_state(str(path))
    assert state["rotations"] == 1
    assert state["last_rotation"] == NOW.isoformat()


def test_save_state_creates_its_directory_and_leaves_no_temporary_behind(tmp_path):
    path = tmp_path / "logs" / "indexer-guard.json"
    m.save_state(str(path), m.empty_state())
    assert path.exists()
    assert not (tmp_path / "logs" / "indexer-guard.json.tmp").exists()
    assert list((tmp_path / "logs").iterdir()) == [path]


def test_record_rotation_is_pure_and_counts(tmp_path):
    state = m.empty_state()
    updated = m.record_rotation(state, NOW)
    assert state == {"last_rotation": None, "rotations": 0}
    assert updated["rotations"] == 1
    assert updated["last_rotation"] == NOW.isoformat()
    assert m.record_rotation(updated, NOW)["rotations"] == 2


def test_record_rotation_survives_a_state_that_is_not_an_object():
    assert m.record_rotation(None, NOW)["rotations"] == 1


def test_a_recorded_rotation_holds_the_next_one_off():
    # The shape the writer and the reader share, end to end: what
    # record_rotation writes is what should_rotate reads.
    state = m.record_rotation(m.empty_state(), NOW)
    assert m.should_rotate([a_blocked()], state["last_rotation"],
                           NOW + timedelta(hours=1), 6.0)[0] is False
    assert m.should_rotate([a_blocked()], state["last_rotation"],
                           NOW + timedelta(hours=7), 6.0)[0] is True


# --- the cooldown argument ---------------------------------------------------


def test_positive_hours_accepts_a_number_above_zero():
    assert m.positive_hours("6") == 6.0
    assert m.positive_hours("0.5") == 0.5
    assert m.positive_hours(6) == 6.0


@pytest.mark.parametrize("value", ["0", "-1", "abc", "", "nan", "inf", "-inf",
                                   "  ", None, "1.2.3"])
def test_positive_hours_refuses_everything_that_is_not_above_zero(value):
    # nan and inf parse as floats: nan compares false against every elapsed
    # time, so it reads as a cooldown nothing ever reaches, and inf is the
    # same answer by another route.
    with pytest.raises(argparse.ArgumentTypeError):
        m.positive_hours(value)


def test_positive_hours_agrees_with_the_same_function_in_usenet_status():
    # Two functions, one name, one contract: the two modules must not drift
    # into accepting different numbers. usenet_status returns None where this
    # raises, because it parses argv by hand while this one is an argparse
    # type -- the accept/reject *set* is what has to agree.
    import usenet_status

    def accepted(function, value):
        try:
            return function(value) is not None
        except argparse.ArgumentTypeError:
            return False

    for value in ("6", "0.5", "0", "-1", "abc", "", "nan", "inf"):
        assert accepted(m.positive_hours, value) == \
            accepted(usenet_status.positive_hours, value), value


# --- the command line --------------------------------------------------------


def test_main_decides_from_two_files_and_prints_json(tmp_path, capsys):
    statuses = write(tmp_path / "statuses.json",
                     [live_status(message="Cloudflare error 1006")])
    indexers = write(tmp_path / "indexers.json", [an_indexer()])
    state_path = tmp_path / "state.json"

    assert m.main(["--statuses", statuses, "--indexers", indexers,
                   "--state", str(state_path), "--json"]) == 0

    view = json.loads(capsys.readouterr().out)
    assert view["rotate"] is True
    assert view["cooldown_hours"] == 6.0
    assert view["last_rotation"] is None
    assert only(view["blocked"])["name"] == "1337x"
    assert only(view["blocked"])["ban_evidence"] is True
    # A decision is not a rotation: nothing on this path may write the state,
    # or the wrapper's own record of a rotation it did not do would enforce a
    # cooldown against a reconnect that never happened.
    assert not state_path.exists()


def test_main_holds_when_the_cooldown_is_still_running(tmp_path, capsys):
    statuses = write(tmp_path / "statuses.json",
                     [live_status(message="Cloudflare error 1006")])
    state = write(tmp_path / "state.json",
                  {"last_rotation": real_now().isoformat(), "rotations": 1})

    assert m.main(["--statuses", statuses, "--state", state, "--json"]) == 0
    view = json.loads(capsys.readouterr().out)
    assert view["rotate"] is False
    assert "cooldown" in view["reason"]
    assert view["rotations"] == 1


def test_main_rotates_once_the_cooldown_has_expired(tmp_path, capsys):
    statuses = write(tmp_path / "statuses.json",
                     [live_status(message="403 Forbidden")])
    state = write(tmp_path / "state.json", {
        "last_rotation": (real_now() - timedelta(hours=7)).isoformat(),
        "rotations": 4,
    })

    assert m.main(["--statuses", statuses, "--state", state, "--json"]) == 0
    view = json.loads(capsys.readouterr().out)
    assert view["rotate"] is True
    assert view["rotations"] == 4
    assert "1337x" in view["reason"] or "indexer 7" in view["reason"]


def test_main_now_pins_the_clock_the_decision_is_made_against(tmp_path, capsys):
    # --now is the module's own timestamp handling, not a second time source:
    # the two documents do not change between these runs, only the moment
    # does, and the verdict flips on the cooldown between them.
    statuses = write(tmp_path / "statuses.json", [a_status(
        disabledTill="2099-01-01T00:00:00Z", message="Cloudflare error 1006")])
    state = write(tmp_path / "state.json", {
        "last_rotation": "2026-09-15T21:00:00+00:00", "rotations": 1})

    assert m.main(["--statuses", statuses, "--state", state,
                   "--now", "2026-09-15T22:00:00Z", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["rotate"] is False

    assert m.main(["--statuses", statuses, "--state", state,
                   "--now", "2026-09-16T04:00:00Z", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["rotate"] is True


def test_main_plumbs_the_rotator_flags_through(tmp_path, capsys):
    # The wrapper's whole half of the coordination: the value it read out of
    # the shared file reaches the decision, and the document says which hold
    # that produced. real_now() because main() reads the real clock.
    statuses = write(tmp_path / "statuses.json",
                     [live_status(message="Cloudflare error 1006")])
    last = int(real_now().timestamp()) - 600

    assert m.main(["--statuses", statuses,
                   "--state", str(tmp_path / "state.json"),
                   "--rotator-last", str(last),
                   "--rotator-interval", "21600",
                   "--rotator-window-minutes", "30", "--json"]) == 0

    view = json.loads(capsys.readouterr().out)
    assert view["rotate"] is False
    assert view["rotator_hold"] == m.ROTATOR_RECENT
    assert "re-probe" in view["reason"]
    assert view["rotator_last"] == last
    assert view["rotator_next"] == last + 21600
    assert view["rotator_interval_seconds"] == 21600
    assert view["rotator_window_minutes"] == 30.0


def test_main_holds_for_the_rotators_own_restart(tmp_path, capsys):
    # The other hold, through the same flags: a restart ten minutes away.
    statuses = write(tmp_path / "statuses.json",
                     [live_status(message="Cloudflare error 1006")])
    last = int(real_now().timestamp()) - (21600 - 600)

    assert m.main(["--statuses", statuses,
                   "--state", str(tmp_path / "state.json"),
                   "--rotator-last", str(last), "--json"]) == 0

    view = json.loads(capsys.readouterr().out)
    assert view["rotate"] is False
    assert view["rotator_hold"] == m.ROTATOR_IMMINENT
    assert "minutes" in view["reason"]
    # The interval default is the compose file's, so the wrapper does not have
    # to pass one for the hold to be the right one.
    assert view["rotator_interval_seconds"] == m.DEFAULT_ROTATOR_INTERVAL_SECONDS


def test_main_with_a_rotator_window_shorter_than_the_gap_still_rotates(tmp_path, capsys):
    # The same timestamp with a five-minute window is outside it, and the
    # guard rotates -- which is what makes the window a real input rather than
    # a flag that is parsed and ignored.
    statuses = write(tmp_path / "statuses.json",
                     [live_status(message="Cloudflare error 1006")])
    last = int(real_now().timestamp()) - 600

    assert m.main(["--statuses", statuses,
                   "--state", str(tmp_path / "state.json"),
                   "--rotator-last", str(last),
                   "--rotator-window-minutes", "5", "--json"]) == 0

    view = json.loads(capsys.readouterr().out)
    assert view["rotate"] is True
    assert view["rotator_hold"] is None
    assert view["rotator_window_minutes"] == 5.0


def test_main_prints_a_rotator_hold_as_a_reason_line_too(tmp_path, capsys):
    # The text renderer is the one the timer's log carries, and it has to say
    # why the VPN did not move without the JSON around it.
    statuses = write(tmp_path / "statuses.json",
                     [live_status(message="Cloudflare error 1006")])
    assert m.main(["--statuses", statuses,
                   "--state", str(tmp_path / "state.json"),
                   "--rotator-last", str(int(real_now().timestamp()) - 60)]) == 0

    out = capsys.readouterr().out
    assert out.startswith("hold: ")
    assert "re-probe" in out
    # No --indexers document, so the record's own id is the label.
    assert "indexer 7 (id 7)" in out


@pytest.mark.parametrize("value", ["0", "-1", "abc", "", "nan", "inf", "1.5"])
def test_main_exits_2_on_an_interval_that_is_not_a_positive_whole_number(value, tmp_path, capsys):
    assert m.main(["--statuses", str(tmp_path / "s.json"),
                   "--state", str(tmp_path / "state.json"),
                   "--rotator-interval", value]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "--rotator-interval" in captured.err


@pytest.mark.parametrize("value", ["0", "-1", "abc", "", "nan", "inf"])
def test_main_exits_2_on_a_window_that_is_not_above_zero(value, tmp_path, capsys):
    assert m.main(["--statuses", str(tmp_path / "s.json"),
                   "--state", str(tmp_path / "state.json"),
                   "--rotator-window-minutes", value]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "--rotator-window-minutes" in captured.err


@pytest.mark.parametrize("value", ["yesterday", "-1", "nan", "inf", "", "12x"])
def test_main_exits_2_on_a_rotator_last_that_is_not_epoch_seconds(value, tmp_path, capsys):
    # The wrapper omits the flag when the shared file is missing or unreadable,
    # so anything that does reach here was meant and has to be a moment.
    assert m.main(["--statuses", str(tmp_path / "s.json"),
                   "--state", str(tmp_path / "state.json"),
                   "--rotator-last", value]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "--rotator-last" in captured.err


def test_positive_seconds_accepts_whole_seconds_above_zero():
    assert m.positive_seconds("21600") == 21600
    assert m.positive_seconds(300) == 300


@pytest.mark.parametrize("value", ["0", "-1", "abc", "", "nan", "inf", "1.5"])
def test_positive_seconds_refuses_everything_that_is_not_a_positive_whole_number(value):
    with pytest.raises(argparse.ArgumentTypeError):
        m.positive_seconds(value)


@pytest.mark.parametrize("value", ["30", "0.5", "1800"])
def test_positive_minutes_accepts_a_number_above_zero(value):
    assert m.positive_minutes(value) == float(value)


@pytest.mark.parametrize("value", ["0", "-1", "abc", "", "nan", "inf"])
def test_positive_minutes_refuses_everything_that_is_not_above_zero(value):
    with pytest.raises(argparse.ArgumentTypeError):
        m.positive_minutes(value)


def test_epoch_seconds_accepts_zero_and_a_real_moment():
    # Zero is what a clock that was never set produces, and it decides the
    # obvious way rather than stopping the guard.
    assert m.epoch_seconds("0") == 0
    assert m.epoch_seconds("1789509600") == 1789509600


@pytest.mark.parametrize("value", ["-1", "abc", "", "nan", "inf", "12x"])
def test_epoch_seconds_refuses_everything_that_is_not_epoch_seconds(value):
    with pytest.raises(argparse.ArgumentTypeError):
        m.epoch_seconds(value)


def test_main_reads_the_statuses_document_from_stdin_by_default(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(sys, "stdin",
                        io.StringIO(json.dumps([live_status(message="Cloudflare error 1006")])))
    assert m.main(["--state", str(tmp_path / "state.json"), "--json"]) == 0

    view = json.loads(capsys.readouterr().out)
    assert view["rotate"] is True
    # No indexer document, so the record's own id is the label.
    assert only(view["blocked"])["name"] == "indexer 7"


def test_main_takes_a_dash_for_stdin_explicitly(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(sys, "stdin", io.StringIO(
        json.dumps([live_status(message="Cloudflare error 1006")])))
    assert m.main(["--statuses", "-", "--state", str(tmp_path / "state.json")]) == 0
    assert capsys.readouterr().out.startswith("rotate: ")


def test_main_prints_a_reason_line_rather_than_json_by_default(tmp_path, capsys):
    statuses = write(tmp_path / "statuses.json",
                     [live_status(message="The operation has timed out")])
    assert m.main(["--statuses", statuses,
                   "--state", str(tmp_path / "state.json")]) == 0

    out = capsys.readouterr().out
    assert out.startswith("hold: ")
    assert "no ban evidence" in out
    assert "indexer 7" in out
    assert not out.startswith("{")


def test_main_lists_the_blocked_indexers_with_their_backoff(tmp_path, capsys):
    statuses = write(tmp_path / "statuses.json",
                     [live_status(hours=4.0, message="Cloudflare error 1006")])
    indexers = write(tmp_path / "indexers.json", [an_indexer()])
    assert m.main(["--statuses", statuses, "--indexers", indexers,
                   "--state", str(tmp_path / "state.json")]) == 0

    out = capsys.readouterr().out
    assert "1337x (id 7): 4.0h of backoff left, ban evidence" in out


def test_the_json_decision_is_the_documented_shape(tmp_path, capsys):
    statuses = write(tmp_path / "statuses.json", [live_status()])
    assert m.main(["--statuses", statuses,
                   "--state", str(tmp_path / "state.json"), "--json"]) == 0

    view = json.loads(capsys.readouterr().out)
    assert set(view) == {"decided_at", "rotate", "reason", "cooldown_hours",
                         "last_rotation", "rotations", "rotator_last",
                         "rotator_next", "rotator_interval_seconds",
                         "rotator_window_minutes", "rotator_hold", "blocked"}
    # With no --rotator-last there is nothing known about the rotator, and the
    # document says so rather than inventing a schedule.
    assert view["rotator_last"] is None
    assert view["rotator_next"] is None
    assert view["rotator_hold"] is None
    assert view["rotator_interval_seconds"] == m.DEFAULT_ROTATOR_INTERVAL_SECONDS
    assert view["rotator_window_minutes"] == m.DEFAULT_ROTATOR_WINDOW_MINUTES
    assert set(only(view["blocked"])) == {
        "indexer_id", "name", "status_id", "disabled_till", "hours_remaining",
        "initial_failure", "most_recent_failure", "ban_evidence",
    }
    assert view["blocked"][0]["disabled_till"].endswith("+00:00")


def test_main_survives_a_state_file_that_is_not_one(tmp_path, capsys):
    statuses = write(tmp_path / "statuses.json",
                     [live_status(message="Cloudflare error 1006")])
    state = tmp_path / "state.json"
    state.write_text("[1, 2, 3]")

    assert m.main(["--statuses", statuses, "--state", str(state), "--json"]) == 0
    view = json.loads(capsys.readouterr().out)
    assert view["rotate"] is True
    assert view["rotations"] == 0


# --- the write mode ----------------------------------------------------------


def test_record_rotation_cli_mode_writes_the_rotation(tmp_path, capsys):
    state = tmp_path / "state.json"
    assert m.main(["--state", str(state), "--record-rotation",
                   "--now", NOW.isoformat()]) == 0

    # The count, and nothing else: the wrapper logs it, and a caller that
    # asked for a write is not owed a decision document.
    assert capsys.readouterr().out.strip() == "1"
    written = m.load_state(str(state))
    assert written["rotations"] == 1
    assert written["last_rotation"] == NOW.isoformat()


def test_record_rotation_cli_mode_counts_the_way_the_function_does(tmp_path, capsys):
    # The mode is record_rotation plus a write, so two runs have to land where
    # two calls to the function land: the count climbs, the timestamp is the
    # later one, and what is written is a cooldown the next decision honours.
    state = tmp_path / "state.json"
    later = NOW + timedelta(hours=7)
    assert m.main(["--state", str(state), "--record-rotation",
                   "--now", NOW.isoformat()]) == 0
    capsys.readouterr()
    assert m.main(["--state", str(state), "--record-rotation",
                   "--now", later.isoformat()]) == 0

    assert capsys.readouterr().out.strip() == "2"
    written = m.load_state(str(state))
    assert written["rotations"] == 2
    assert written["last_rotation"] == later.isoformat()
    assert m.should_rotate([a_blocked()], written["last_rotation"],
                           later + timedelta(hours=1), 6.0)[0] is False


def test_record_rotation_cli_mode_creates_a_state_file_that_is_not_there(tmp_path, capsys):
    # A first rotation has no state file to read. That is a fresh stack, not an
    # error: load_state falls back to the empty state and save_state makes the
    # directory it was pointed at.
    state = tmp_path / "logs" / "indexer-guard.json"
    assert m.main(["--state", str(state), "--record-rotation"]) == 0
    assert capsys.readouterr().out.strip() == "1"
    assert m.parse_time(m.load_state(str(state))["last_rotation"]) is not None


@pytest.mark.parametrize("now", ["yesterday", "", "2026-13-45T99:00:00Z"])
def test_record_rotation_cli_mode_refuses_a_now_that_is_not_a_timestamp(now, tmp_path, capsys):
    # Refused at the argument rather than falling back to the real clock: a
    # `--now yesterday` that quietly recorded the moment of the run would put
    # a cooldown on the wrong six hours.
    assert m.main(["--state", str(tmp_path / "state.json"),
                   "--record-rotation", "--now", now]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "--now" in captured.err


def test_record_rotation_cli_mode_exits_nonzero_on_a_state_path_that_is_a_directory(tmp_path, capsys):
    state = tmp_path / "state.json"
    state.mkdir()
    assert m.main(["--state", str(state), "--record-rotation"]) != 0
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "ERROR" in captured.err


def test_record_rotation_cli_mode_exits_nonzero_when_the_parent_is_a_file(tmp_path, capsys):
    blocker = tmp_path / "blocker"
    blocker.write_text("not a directory")
    assert m.main(["--state", str(blocker / "state.json"),
                   "--record-rotation"]) != 0
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "ERROR" in captured.err


# --- reading a decision back -------------------------------------------------


def test_verdict_mode_renders_a_decision_document(tmp_path, capsys):
    document = write(tmp_path / "decision.json",
                     {"rotate": True, "reason": "1337x shows ban evidence"})
    assert m.main(["--verdict", document]) == 0
    assert capsys.readouterr().out == "rotate\t1337x shows ban evidence\n"


def test_verdict_mode_reads_stdin_with_a_dash(monkeypatch, capsys):
    monkeypatch.setattr(sys, "stdin", io.StringIO(json.dumps(
        {"rotate": False, "reason": "no indexer is in backoff"})))
    assert m.main(["--verdict", "-"]) == 0
    assert capsys.readouterr().out == "hold\tno indexer is in backoff\n"


@pytest.mark.parametrize("document", [
    {"reason": "no rotate flag"},
    {"rotate": "yes", "reason": "not a boolean"},
    {"rotate": True},
    {"rotate": True, "reason": 7},
    [1, 2, 3],
    "not a document",
])
def test_verdict_mode_refuses_a_document_that_is_not_a_decision(document, tmp_path, capsys):
    # Holding would be the dangerous reading, and the silent one: this is what
    # stops the wrapper treating a decision it cannot read as "nothing to do".
    path = write(tmp_path / "decision.json", document)
    assert m.main(["--verdict", path]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "rotate flag" in captured.err


def test_verdict_mode_exits_2_on_a_document_it_cannot_read(tmp_path, capsys):
    assert m.main(["--verdict", str(tmp_path / "nope.json")]) == 2
    assert "cannot read decision" in capsys.readouterr().err


def test_main_exits_2_when_the_statuses_document_cannot_be_read(tmp_path, capsys):
    assert m.main(["--statuses", str(tmp_path / "nope.json"),
                   "--state", str(tmp_path / "state.json")]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "cannot read indexerstatus" in captured.err


def test_main_exits_2_when_the_indexer_document_cannot_be_read(tmp_path, capsys):
    statuses = write(tmp_path / "statuses.json", [live_status()])
    assert m.main(["--statuses", statuses, "--indexers", str(tmp_path / "nope.json"),
                   "--state", str(tmp_path / "state.json")]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "cannot read indexer" in captured.err


@pytest.mark.parametrize("content", ["", "{ not json", "<html>nope</html>"])
def test_main_exits_2_when_a_document_is_not_json(content, tmp_path, capsys):
    statuses = tmp_path / "statuses.json"
    statuses.write_text(content)
    assert m.main(["--statuses", str(statuses),
                   "--state", str(tmp_path / "state.json")]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "is not JSON" in captured.err


def test_main_exits_2_on_an_empty_stdin(monkeypatch, tmp_path, capsys):
    # A wrapper whose curl failed has a bug, and reading that as "no indexers
    # are blocked" is a silent one.
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert m.main(["--statuses", "-", "--state", str(tmp_path / "s.json")]) == 2
    assert "is not JSON" in capsys.readouterr().err


@pytest.mark.parametrize("value", ["0", "-1", "abc", "", "nan", "inf"])
def test_main_exits_2_on_a_cooldown_that_is_not_above_zero(value, tmp_path, capsys):
    assert m.main(["--statuses", str(tmp_path / "s.json"),
                   "--state", str(tmp_path / "state.json"),
                   "--cooldown-hours", value]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    # argparse names the argument and quotes the value, so the timer's log
    # says which flag the wrapper got wrong and what it was given.
    assert "--cooldown-hours" in captured.err
    assert repr(value) in captured.err


@pytest.mark.parametrize("value", ["0", "-1", "nan", "inf"])
def test_main_refuses_a_numeric_cooldown_that_is_not_above_zero(value, tmp_path, capsys):
    # The half of the refusal that is numeric: each of these parses as a
    # float and would otherwise run, and the message has to say the rule
    # rather than only "not a number".
    assert m.main(["--statuses", str(tmp_path / "s.json"),
                   "--state", str(tmp_path / "state.json"),
                   "--cooldown-hours", value]) == 2
    assert "greater than 0" in capsys.readouterr().err


def test_main_exits_2_on_a_trailing_cooldown_flag(tmp_path, capsys):
    # argparse's own "expected one argument", which must exit 2 rather than
    # fall back to the default -- a silently ignored flag is a cooldown nobody
    # asked for.
    assert m.main(["--statuses", str(tmp_path / "s.json"),
                   "--state", str(tmp_path / "state.json"),
                   "--cooldown-hours"]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err


def test_main_exits_2_on_an_unknown_flag(tmp_path, capsys):
    assert m.main(["--statuses", str(tmp_path / "s.json"), "--rotate-now"]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err


def test_no_api_key_reaches_either_renderer(monkeypatch, tmp_path, capsys):
    # Prowlarr's failure text can carry the request URL, and an indexer URL
    # carries its key. Neither renderer may echo the message, and nothing on
    # this path reads the environment for a credential at all.
    monkeypatch.setenv("PROWLARR_API_KEY", "PROWLARR-SENTINEL")
    monkeypatch.setenv("TORBOX_API_KEY", "TORBOX-SENTINEL")
    statuses = write(tmp_path / "statuses.json", [live_status(
        message="403 http://prowlarr:9696/7/api?apikey=INDEXER-SENTINEL")])
    state = str(tmp_path / "state.json")

    assert m.main(["--statuses", statuses, "--state", state]) == 0
    text = capsys.readouterr().out
    assert m.main(["--statuses", statuses, "--state", state, "--json"]) == 0
    document = capsys.readouterr().out

    for sentinel in ("SENTINEL", "PROWLARR_API_KEY", "TORBOX_API_KEY", "apikey"):
        assert sentinel not in text
        assert sentinel not in document


def test_the_module_cannot_reach_the_network_or_a_subprocess():
    # "No HTTP, no socket, no subprocess" is a property of the whole module
    # and invisible to every other test here: one added import would be enough
    # to let a decision that is supposed to be pure make the call itself. The
    # allowed set is asserted exactly, not as a blocklist, so an import added
    # for any other reason has to be looked at rather than merely not match.
    tree = ast.parse(pathlib.Path(m.__file__).read_text(encoding="utf-8"))
    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module.split(".")[0])
    assert imported == {"argparse", "json", "math", "os", "re", "sys", "datetime"}
