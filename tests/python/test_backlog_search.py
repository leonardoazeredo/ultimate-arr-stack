"""Behavioural tests for scripts/lib/backlog_search.py.

This module decides what gets searched and, more importantly, how much. Both
halves of that are load-bearing:

  * the pacing, because the unbounded alternative is what wedged this stack --
    `MissingEpisodeSearch` over 3,116 episodes could not be cancelled and had
    to be killed by restarting Sonarr;
  * the cooldown, because Radarr's sweep is deliberately bulk and would
    otherwise re-present the same 24 films to the indexers on every interval.

Every test injects a fake API and, where time matters, a fixed clock. A test
whose result depends on when it runs is a test that will one day fail for a
reason nobody can reproduce.
"""

import json
from datetime import datetime, timedelta, timezone

import backlog_search as m

NOW = datetime(2026, 9, 14, 12, 0, 0, tzinfo=timezone.utc)


class FakeApi:
    """Records every request instead of making one.

    `posts` is the point of most of these tests: what was queued, and how much.
    """

    def __init__(self, movies=(), series=(), episodes=None, queue=()):
        self._movies = list(movies)
        self._series = list(series)
        self._episodes = episodes or {}
        self._queue = list(queue)
        self.posts = []
        self.gets = []

    def get(self, path):
        self.gets.append(path)
        if path.startswith("/api/v3/movie"):
            return self._movies
        if path.startswith("/api/v3/series"):
            return self._series
        if path.startswith("/api/v3/episode?seriesId="):
            series_id = int(path.split("=", 1)[1])
            return self._episodes.get(series_id, [])
        if path.startswith("/api/v3/queue"):
            return {"records": self._queue}
        raise AssertionError(f"unexpected GET {path}")

    def post_command(self, name, **kwargs):
        self.posts.append((name, kwargs))
        return {"id": 1, "name": name}


class Collector:
    """Stand-in for the module's `out` callback."""

    def __init__(self):
        self.lines = []

    def __call__(self, line):
        self.lines.append(line)

    def text(self):
        return "\n".join(self.lines)


def film(mid, title, **kw):
    base = {"id": mid, "title": title, "year": 2000, "monitored": True,
            "hasFile": False, "isAvailable": True}
    base.update(kw)
    return base


def episode(eid, series_id, season, **kw):
    base = {"id": eid, "seriesId": series_id, "seasonNumber": season,
            "monitored": True, "hasFile": False}
    base.update(kw)
    return base


def state_at(hours_ago, kind="radarr-bulk", real=False):
    """A history whose last `kind` run was `hours_ago` hours ago.

    `real` measures against the wall clock, which is what the production code
    reads: `process_radarr` calls `hours_since_last` without a `now`, so a
    fixture pinned to the module's fixed NOW is a timestamp in the *future* and
    the cooldown reads as negative. `real=False` is for the tests that pass a
    clock explicitly.
    """
    base = datetime.now(timezone.utc) if real else NOW
    when = base - timedelta(hours=hours_ago)
    return {"runs": [{"at": when.isoformat(), "kind": kind, "count": 1}]}


# --- radarr_candidates -----------------------------------------------------

def test_a_film_with_a_file_is_not_a_candidate():
    api = FakeApi(movies=[film(1, "Have", hasFile=True), film(2, "Want")])
    got = m.radarr_candidates(api, set())
    assert [f["title"] for f in got] == ["Want"]


def test_an_unmonitored_film_is_not_a_candidate():
    api = FakeApi(movies=[film(1, "Off", monitored=False), film(2, "On")])
    assert [f["title"] for f in m.radarr_candidates(api, set())] == ["On"]


def test_a_film_not_yet_available_is_not_a_candidate():
    # A cinema-only film has nothing to search for; including it every run
    # would burn a slot in the bounded sweep on a guaranteed miss.
    api = FakeApi(movies=[film(1, "Soon", isAvailable=False), film(2, "Out")])
    assert [f["title"] for f in m.radarr_candidates(api, set())] == ["Out"]


def test_a_film_already_in_the_queue_is_not_searched_again():
    # Searching it again is how the same release gets grabbed twice.
    api = FakeApi(movies=[film(1, "Queued")])
    assert m.radarr_candidates(api, {1}) == []


def test_radarr_candidates_are_ordered_by_title_so_a_sweep_advances():
    # Order is what makes a bounded sweep finish. Newest-first would re-search
    # the same head of the list forever and never reach the tail.
    api = FakeApi(movies=[film(3, "Zulu"), film(1, "Alpha"), film(2, "Mike")])
    assert [f["title"] for f in m.radarr_candidates(api, set())] == \
        ["Alpha", "Mike", "Zulu"]


# --- sonarr units ----------------------------------------------------------

def test_sonarr_groups_episodes_by_season_not_one_per_episode():
    # The whole reason the sweep is affordable: one SeasonSearch per season
    # instead of one request per episode.
    api = FakeApi(
        series=[{"id": 7}],
        episodes={7: [episode(1, 7, 1), episode(2, 7, 1), episode(3, 7, 2)]},
    )
    wanted = m.sonarr_candidates(api, set())
    units = m.sonarr_units(wanted)
    assert units == [(7, 1, 2), (7, 2, 1)]


def test_a_sonarr_season_with_every_episode_present_is_dropped():
    api = FakeApi(series=[{"id": 7}], episodes={7: [episode(1, 7, 1, hasFile=True)]})
    assert m.sonarr_units(m.sonarr_candidates(api, set())) == []


def test_an_episode_already_queued_is_not_searched_again():
    api = FakeApi(series=[{"id": 7}], episodes={7: [episode(1, 7, 1)]})
    assert m.sonarr_units(m.sonarr_candidates(api, {1})) == []


def test_sonarr_units_are_ordered_by_series_then_season():
    api = FakeApi(
        series=[{"id": 9}, {"id": 2}],
        episodes={9: [episode(1, 9, 1)], 2: [episode(2, 2, 3), episode(3, 2, 1)]},
    )
    assert m.sonarr_units(m.sonarr_candidates(api, set())) == \
        [(2, 1, 1), (2, 3, 1), (9, 1, 1)]


# --- hours_since_last ------------------------------------------------------

def test_hours_since_last_is_none_when_the_kind_never_ran():
    # Distinguishable from "ran long ago" on purpose: a log line claiming
    # "0.0h since a bulk search" when none has ever run is a small lie.
    assert m.hours_since_last({"runs": []}, "radarr-bulk", now=NOW) is None


def test_hours_since_last_measures_the_most_recent_matching_run():
    history = {"runs": [
        {"at": (NOW - timedelta(hours=20)).isoformat(), "kind": "radarr-bulk"},
        {"at": (NOW - timedelta(hours=3)).isoformat(), "kind": "radarr-bulk"},
        {"at": (NOW - timedelta(hours=1)).isoformat(), "kind": "sonarr-bulk"},
    ]}
    assert m.hours_since_last(history, "radarr-bulk", now=NOW) == 3.0


def test_hours_since_last_ignores_entries_of_other_kinds():
    # The Sonarr bulk run must never satisfy the Radarr cooldown, or the films
    # would be searched whenever the episodes were.
    history = {"runs": [{"at": (NOW - timedelta(minutes=1)).isoformat(),
                         "kind": "sonarr-bulk"}]}
    assert m.hours_since_last(history, "radarr-bulk", now=NOW) is None


def test_hours_since_last_survives_a_malformed_timestamp():
    history = {"runs": [{"at": "not-a-date", "kind": "radarr-bulk"},
                        {"kind": "radarr-bulk"}]}
    assert m.hours_since_last(history, "radarr-bulk", now=NOW) is None


# --- the radarr cooldown ---------------------------------------------------

def test_radarr_searches_bulk_when_it_has_never_run():
    api = FakeApi(movies=[film(1, "A"), film(2, "B")])
    state = {"runs": [], "history": {"runs": []}}
    out = Collector()
    m.process_radarr(api, True, False, state, out, 6.0)
    assert api.posts == [("MissingMoviesSearch", {})]


def test_radarr_is_skipped_inside_its_cooldown():
    # The burst guard. Radarr's sweep is deliberately bulk, so without this it
    # would re-present the same films to the indexers on every interval.
    api = FakeApi(movies=[film(1, "A")])
    state = {"runs": [], "history": state_at(0.2, real=True)}
    out = Collector()
    assert m.process_radarr(api, True, False, state, out, 6.0) == 0
    assert api.posts == []
    assert "cooldown" in out.text()


def test_radarr_runs_again_once_the_cooldown_has_expired():
    api = FakeApi(movies=[film(1, "A")])
    state = {"runs": [], "history": state_at(6.5, real=True)}
    m.process_radarr(api, True, False, state, Collector(), 6.0)
    assert api.posts == [("MissingMoviesSearch", {})]


def test_radarr_records_the_run_so_the_next_one_can_check_the_cooldown():
    api = FakeApi(movies=[film(1, "A")])
    state = {"runs": [], "history": {"runs": []}}
    m.process_radarr(api, True, False, state, Collector(), 6.0)
    assert [r["kind"] for r in state["runs"]] == ["radarr-bulk"]
    assert state["runs"][0]["count"] == 1


def test_a_dry_run_neither_posts_nor_records_a_run():
    # A dry run that recorded a run would start the cooldown without ever
    # having searched anything, and the next real run would skip.
    api = FakeApi(movies=[film(1, "A")])
    state = {"runs": [], "history": {"runs": []}}
    assert m.process_radarr(api, False, False, state, Collector(), 6.0) == 0
    assert api.posts == []
    assert state["runs"] == []


# --- the sonarr bound ------------------------------------------------------

def test_sonarr_never_searches_more_than_the_limit_in_one_run():
    # The single most important assertion in this file. The unbounded version
    # is what could not be cancelled and had to be killed by a restart.
    eps = {1: [episode(i, 1, s) for s in range(1, 21) for i in [s]]}
    api = FakeApi(series=[{"id": 1}], episodes=eps)
    state = {"runs": []}
    out = Collector()
    m.process_sonarr(api, True, False, 5, state, out)
    assert len(api.posts) == 5
    assert all(name == "SeasonSearch" for name, _ in api.posts)
    assert "15 season(s) remain" in out.text()


def test_sonarr_uses_the_bulk_command_only_when_the_work_fits_one_run():
    # Below the limit the bulk command finishes the tail in one request, and
    # the burst is bounded by definition because the backlog is smaller.
    api = FakeApi(series=[{"id": 1}], episodes={1: [episode(1, 1, s) for s in (1, 2)]})
    state = {"runs": []}
    m.process_sonarr(api, True, False, 10, state, Collector())
    assert api.posts == [("MissingEpisodeSearch", {})]


def test_sonarr_does_not_use_the_bulk_command_when_the_backlog_exceeds_the_limit():
    api = FakeApi(series=[{"id": 1}],
                  episodes={1: [episode(s, 1, s) for s in range(1, 8)]})
    state = {"runs": []}
    m.process_sonarr(api, True, False, 3, state, Collector())
    assert ("MissingEpisodeSearch", {}) not in api.posts
    assert len(api.posts) == 3


def test_a_sonarr_season_search_carries_its_series_and_season():
    # Swapping these two is silent: the arr answers 400 and the sweep reports
    # a queued search that never ran.
    api = FakeApi(series=[{"id": 42}], episodes={42: [episode(1, 42, 7)]})
    m.process_sonarr(api, True, False, 10, {"runs": []}, Collector())
    assert api.posts == [("MissingEpisodeSearch", {})]
    api2 = FakeApi(series=[{"id": 42, "title": "X"}],
                   episodes={42: [episode(1, 42, 7), episode(2, 42, 8)]})
    m.process_sonarr(api2, True, False, 1, {"runs": []}, Collector())
    assert api2.posts == [("SeasonSearch", {"seriesId": 42, "seasonNumber": 7})]


# --- state persistence -----------------------------------------------------

def test_state_round_trips_is_not_required_but_malformed_state_must_not_crash(tmp_path):
    # A state file that cannot be read must not stop the sweep: losing the
    # cooldown costs one extra bulk search, while refusing to run at all is a
    # silently dead timer.
    path = tmp_path / "state.json"
    path.write_text("{ this is not json")
    assert m.load_state(str(path)) == {"runs": []}


def test_a_missing_state_file_is_an_empty_history(tmp_path):
    assert m.load_state(str(tmp_path / "nope.json")) == {"runs": []}


def test_save_state_appends_rather_than_replacing(tmp_path):
    # Replacing would drop the timestamp the cooldown reads, so every run
    # would think it was the first.
    path = tmp_path / "state.json"
    previous = {"runs": [{"at": NOW.isoformat(), "kind": "radarr-bulk"}]}
    m.save_state(str(path), [{"at": NOW.isoformat(), "kind": "sonarr-bulk"}], previous)
    kinds = [r["kind"] for r in json.loads(path.read_text())["runs"]]
    assert kinds == ["radarr-bulk", "sonarr-bulk"]


def test_save_state_drops_records_older_than_the_retention_window(tmp_path):
    path = tmp_path / "state.json"
    old = {"at": (NOW - timedelta(days=30)).isoformat(), "kind": "radarr-bulk"}
    m.save_state(str(path), [], {"runs": [old]})
    assert json.loads(path.read_text())["runs"] == []


def test_save_state_writes_nothing_when_there_is_nothing_to_write(tmp_path):
    path = tmp_path / "state.json"
    m.save_state(str(path), [], {"runs": []})
    assert not path.exists()


# --- the api client --------------------------------------------------------

def test_the_api_key_is_not_an_argv_element(monkeypatch):
    # argv is world-readable through /proc/<pid>/cmdline, and this runs on a
    # timer. The key goes in through curl's config on stdin instead.
    seen = {}

    class Done(Exception):
        pass

    def fake_run(argv, **kwargs):
        seen["argv"] = argv
        seen["input"] = kwargs.get("input", "")
        raise Done()

    monkeypatch.setattr(m.subprocess, "run", fake_run)
    api = m.ArrApi("Radarr", "http://localhost:7878", "SECRETKEY")
    try:
        api.get("/api/v3/movie")
    except Done:
        pass
    assert "SECRETKEY" not in " ".join(seen["argv"])
    assert "SECRETKEY" in seen["input"]


# --- the walk must advance, not re-search its own head ---------------------
#
# The bug these cover, found on the NAS 2026-09-14: the ordered walk restarts at
# the head of the list every run, and nothing excluded a unit that had been
# searched without producing a grab -- so the same first `limit` seasons were
# searched every four hours forever and the tail of a 207-season backlog was
# never reached. It read as progress in the log, because the same lines kept
# appearing.

def seasons(n, series_id=3):
    """n missing seasons for one series, as the fake API would return them."""
    return {series_id: [episode(s, series_id, s) for s in range(1, n + 1)]}


def test_the_walk_advances_past_seasons_it_already_searched():
    # Run 1 searches seasons 1-2 of 8; run 2 must search 3-4, not 1-2 again.
    # The backlog has to exceed the limit here, or the walk takes the bulk path
    # and there is no per-season slice to check.
    def run(history):
        api = FakeApi(series=[{"id": 3}], episodes=seasons(8))
        state = {"runs": [], "history": history}
        m.process_sonarr(api, True, False, 2, state, Collector())
        return api, state

    _, state1 = run({"runs": []})
    # The records the first run wrote are what the second run reads.
    api2, _ = run({"runs": state1["runs"]})
    assert [kwargs["seasonNumber"] for _, kwargs in api2.posts] == [3, 4]


def test_a_season_searched_long_ago_becomes_eligible_again():
    # The cooldown is a delay, not a permanent exclusion: a season that never
    # produced a grab has to be retried eventually.
    api = FakeApi(series=[{"id": 3}], episodes=seasons(2))
    old = {"runs": [
        {"at": (datetime.now(timezone.utc) - timedelta(hours=30)).isoformat(),
         "kind": "sonarr-season", "unit": "3:1"},
        {"at": (datetime.now(timezone.utc) - timedelta(hours=30)).isoformat(),
         "kind": "sonarr-season", "unit": "3:2"},
    ]}
    state = {"runs": [], "history": old}
    m.process_sonarr(api, True, False, 5, state, Collector())
    assert api.posts == [("MissingEpisodeSearch", {})]


def test_a_recently_searched_season_is_skipped():
    # Season 1 already tried; the walk must start at 2 rather than re-issue 1.
    # 6 seasons against a limit of 2 keeps it on the per-season path.
    api = FakeApi(series=[{"id": 3}], episodes=seasons(6))
    recent = {"runs": [
        {"at": datetime.now(timezone.utc).isoformat(),
         "kind": "sonarr-season", "unit": "3:1"},
    ]}
    state = {"runs": [], "history": recent}
    m.process_sonarr(api, True, False, 2, state, Collector())
    assert [kwargs["seasonNumber"] for _, kwargs in api.posts] == [2, 3]


def test_searches_are_recorded_with_a_stable_unit_id():
    # The unit id is what the next run matches on, so it has to be stable and
    # to identify the season, not just the series.
    api = FakeApi(series=[{"id": 7}], episodes=seasons(2, series_id=7))
    state = {"runs": [], "history": {"runs": []}}
    m.process_sonarr(api, True, False, 1, state, Collector())
    assert [r["unit"] for r in state["runs"]] == ["7:1"]
    assert state["runs"][0]["kind"] == "sonarr-season"


def test_nothing_to_do_when_every_unit_was_searched_recently():
    # The whole backlog already tried inside the cooldown: say so, and queue
    # nothing, rather than re-issuing the same searches.
    api = FakeApi(series=[{"id": 3}], episodes=seasons(2))
    recent = {"runs": [
        {"at": datetime.now(timezone.utc).isoformat(),
         "kind": "sonarr-season", "unit": u} for u in ("3:1", "3:2")
    ]}
    state = {"runs": [], "history": recent}
    out = Collector()
    assert m.process_sonarr(api, True, False, 5, state, out) == 0
    assert api.posts == []
    assert "nothing new to try yet" in out.text()


def test_the_radarr_cooldown_does_not_treat_sonarr_units_as_its_own():
    # Both kinds land in one history list; matching on the wrong kind would let
    # episode searches satisfy the film cooldown.
    history = {"runs": [{"at": datetime.now(timezone.utc).isoformat(),
                         "kind": "sonarr-season", "unit": "3:1"}]}
    assert m.hours_since_last(history, "radarr-bulk") is None


def test_the_all_tried_message_when_the_backlog_exceeds_the_limit():
    # The other half of the exhausted case: a backlog BIGGER than the limit
    # where every unit has already been tried. The bulk command must not fire
    # (the backlog does not fit), and the run must say so rather than silently
    # doing nothing or re-issuing the same searches.
    api = FakeApi(series=[{"id": 3}], episodes=seasons(6))
    recent = {"runs": [
        {"at": datetime.now(timezone.utc).isoformat(),
         "kind": "sonarr-season", "unit": f"3:{s}"} for s in range(1, 7)
    ]}
    state = {"runs": [], "history": recent}
    out = Collector()
    assert m.process_sonarr(api, True, False, 2, state, out) == 0
    assert api.posts == []
    assert "nothing new to try yet" in out.text()
