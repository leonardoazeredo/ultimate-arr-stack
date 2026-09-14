#!/usr/bin/env python3
"""Search the Sonarr/Radarr missing backlog, paced per service.

Why this exists: nothing in this stack ever searched for the existing backlog.
Both arrs search on their own only for *new* releases (RSS) and for items
already in the queue, so a film added in August and never found sits missing
forever. Measured on this NAS 2026-09-13: 24 films missing with 97 grabbable
releases available for one of them, and 3,107 episodes missing across 42
series -- while the only grabs that day were ones a human asked for by hand.

The two services are paced differently, and both calls come from measurement
rather than taste.

Sonarr is bounded. `MissingEpisodeSearch` searches the whole backlog in one
command: measured, it opened with "Performing search for 3116 episodes", could
not be cancelled (Sonarr answers 409 for a command that has already started),
and had to be killed by restarting the container. So this walks the backlog in
a stable order, at most `limit` seasons per run, switching to the bulk command
only once fewer than `limit` seasons remain -- bounded by definition by then.
Work is per season, so one SeasonSearch covers a season instead of one request
per episode: ~200 requests for this library instead of ~3,100.

The bounded walk restarts at the head of an ordered list every run, so it also
skips units a recent run already asked for -- without that, the same first
`limit` seasons are searched every interval and the tail of the backlog is never
reached. That is a livelock that reads as progress, because the same lines keep
appearing in the log. Measured on the NAS 2026-09-14, before the skip existed:
the 00:02 run searched series 3-5 seasons 1-6, and the 04:02 run would have
searched exactly those again.

Radarr is bulk with a cooldown, because the bounded-looking alternative does not
work here. `MoviesSearch` for a single film processed 2-4 releases per call and
grabbed nothing, even for a film with 22 approved and 43 download-allowed
releases in the same indexer results; `MissingMoviesSearch` grabbed 5 films in
4 minutes. Bulk is affordable because the candidate set is 24 films, and the
cooldown stops it re-presenting that set on every interval.

Skip logic, so a drain run actually reaches the end of the list:
  * Radarr: only films that are monitored, have no file, and are available.
  * Sonarr: only monitored episodes that have no file.
  * Anything already in the queue is skipped -- it is being worked on, and
    searching it again is how the same release gets grabbed twice.
  * Sonarr units are ordered by series then season, so successive runs advance
    rather than re-searching the same head of the list.

Usage:
  backlog_search.py <apply:true|false> <verbose:true|false> <limit> [state-path] [cooldown-hours]
"""

import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone

DEFAULT_LIMIT = 10

# The arr API. Same shape as queue_cleanup.py's ArrApi, including the curl
# config-file trick that keeps the API key off the process's argv.
CURL_MAX_TIME = 30


def quoted(value):
    """Escape a value for a curl config file.

    curl's config parser reads a double-quoted value literally, so a backslash
    or a quote inside the value has to be escaped or it terminates the string
    early. Both occur: a Sonarr API key is hex, but a series title is arbitrary
    text and ends up here in a query string.
    """
    return value.replace("\\", "\\\\").replace('"', '\\"')


class ArrApi:
    """Minimal client for one arr's v3 API."""

    def __init__(self, name, base_url, api_key):
        self.name = name
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key

    def _run(self, path, method="GET", data=None):
        lines = [
            f'url = "{quoted(self.base_url + path)}"',
            f'header = "X-Api-Key: {quoted(self.api_key)}"',
        ]
        if method != "GET":
            lines.append(f'request = "{quoted(method)}"')
        if data is not None:
            lines.append('header = "Content-Type: application/json"')
            lines.append(f'data = "{quoted(json.dumps(data))}"')

        proc = subprocess.run(
            ["curl", "-s", "-f", "--max-time", str(CURL_MAX_TIME), "--config", "-"],
            input="\n".join(lines) + "\n",
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"{self.name}: request to {path} failed "
                f"(curl exit {proc.returncode}): {proc.stderr.strip()}"
            )
        if not proc.stdout.strip():
            raise RuntimeError(f"{self.name}: empty response from {path}")
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError as err:
            # An arr that answers with an HTML error page (a reverse proxy in
            # front of it, say) would otherwise surface as a bare traceback,
            # which reads as a bug in this script rather than a bad response.
            raise RuntimeError(
                f"{self.name}: {path} did not return JSON ({err}); "
                f"first 200 bytes: {proc.stdout[:200]!r}"
            ) from err

    def get(self, path):
        return self._run(path)

    def post_command(self, name, **kwargs):
        payload = {"name": name}
        payload.update(kwargs)
        return self._run("/api/v3/command", method="POST", data=payload)


def queue_keys(records):
    """Identifiers of everything already in flight, per service.

    Returns (movie_ids, episode_ids). A queue record nests the ids it is about
    under `movieId` / `episodeId`; older records carry them at the top level.
    """
    movies, episodes = set(), set()
    for record in records:
        movie_id = record.get("movieId")
        if movie_id is not None:
            movies.add(movie_id)
        episode_id = record.get("episodeId")
        if episode_id is not None:
            episodes.add(episode_id)
    return movies, episodes


def order_key(item):
    """A stable sort key, so successive runs advance through the backlog.

    Sorted by title then id rather than by "recently added" -- a run that
    starts from the same end of the list every time is what makes a bounded
    sweep finish. Sorting by added-date would put the newest first forever and
    never reach the tail.
    """
    return ((item.get("title") or "").lower(), item.get("id") or 0)


def radarr_candidates(api, queued_movie_ids):
    """Films worth searching: monitored, no file, available, not already queued."""
    films = api.get("/api/v3/movie")
    out = []
    for film in films:
        if not film.get("monitored") or film.get("hasFile"):
            continue
        if not film.get("isAvailable"):
            continue
        if film.get("id") in queued_movie_ids:
            continue
        out.append(film)
    return sorted(out, key=order_key)


def sonarr_candidates(api, queued_episode_ids, series=None):
    """Episodes worth searching: monitored, no file, not already queued.

    Fetched one series at a time. `/api/v3/episode` with no `seriesId` answers
    `400 BadRequest: seriesId or episodeIds must be provided` -- measured, not
    assumed -- so there is no single call that returns the whole library's
    episodes. One call per series is ~40 requests on this library, and each
    response is a few hundred KB, which is cheaper than the alternative of
    asking per season.

    Returned grouped by series and season, because one `SeasonSearch` covers a
    whole season in a single indexer request where `EpisodeSearch` issues one
    per episode. On this library that is the difference between ~200 requests
    and ~3,100.
    """
    if series is None:
        series = api.get("/api/v3/series")

    wanted = {}
    for show in series:
        series_id = show.get("id")
        if series_id is None:
            continue
        episodes = api.get(f"/api/v3/episode?seriesId={series_id}")
        for episode in episodes:
            if not episode.get("monitored") or episode.get("hasFile"):
                continue
            if episode.get("id") in queued_episode_ids:
                continue
            season = episode.get("seasonNumber")
            if season is None:
                continue
            wanted.setdefault(series_id, {}).setdefault(season, []).append(episode)
    return wanted


def load_state(path):
    """Read the run history, tolerating a missing or malformed file.

    A state file that cannot be read must not stop the sweep -- losing the
    cooldown costs one extra bulk search, which is survivable, while refusing
    to run at all is a silently dead timer.
    """
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {"runs": []}
    if not isinstance(data, dict):
        return {"runs": []}
    data.setdefault("runs", [])
    return data


def hours_since_last(history, kind, now=None):
    """Hours since the last run that did `kind`, or None if never.

    Returns None rather than a large number so "never ran" and "ran long ago"
    stay distinguishable -- the caller treats them the same, but a test can
    tell them apart, and a log line reading "0.0h since a bulk search" when
    none has ever run would be a small lie.
    """
    now = now or datetime.now(timezone.utc)
    latest = None
    for entry in history.get("runs", []):
        if entry.get("kind") != kind:
            continue
        try:
            when = datetime.fromisoformat(entry["at"])
        except (KeyError, ValueError):
            continue
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
        if latest is None or when > latest:
            latest = when
    if latest is None:
        return None
    return (now - latest).total_seconds() / 3600.0


def process_radarr(api, apply_changes, verbose, state, out, cooldown_hours):
    """Search every missing film, at most once per cooldown window.

    Bulk on purpose, and measured: `MissingMoviesSearch` grabbed 5 films in 4
    minutes on 2026-09-13, while `MoviesSearch` on a single film -- the
    bounded-looking alternative -- processed 2-4 releases per call and grabbed
    nothing, even for a film with 22 approved and 43 download-allowed releases
    sitting in the same indexer results. The per-film path is what does not
    work here; the bulk one does.

    Bulk is affordable here because the candidate set is small: 24 missing
    films, against Sonarr's 3,107 episodes. The cooldown is what keeps it from
    re-firing every interval and re-presenting the same set to the indexers.
    """
    queued_records = api.get("/api/v3/queue?pageSize=200") or {}
    records = queued_records.get("records") or []
    queued_movie_ids, _ = queue_keys(records)

    candidates = radarr_candidates(api, queued_movie_ids)
    out(f"  {len(candidates)} film(s) missing, available and not already queued")
    if not candidates:
        out("  nothing to search")
        return 0

    waited = hours_since_last(state.get("history", {}), "radarr-bulk")
    if waited is not None and waited < cooldown_hours:
        out(
            f"  skipped: a full film search ran {waited:.1f}h ago "
            f"(cooldown {cooldown_hours}h)"
        )
        return 0

    if not apply_changes:
        out(f"    would run MissingMoviesSearch across all {len(candidates)} film(s)")
        return 0

    api.post_command("MissingMoviesSearch")
    state["runs"].append(
        {
            "at": datetime.now(timezone.utc).isoformat(),
            "kind": "radarr-bulk",
            "count": len(candidates),
        }
    )
    out(f"    MissingMoviesSearch queued for {len(candidates)} film(s)")
    return len(candidates)


def unit_id(series_id, season):
    """A stable identity for one unit of Sonarr work."""
    return f"{series_id}:{season}"


def recently_searched(history, kind, hours, now=None):
    """Unit ids of `kind` searched within the last `hours`.

    The bounded walk restarts from the head of an ordered list every run, so
    without this it re-searches the same first `limit` seasons forever and never
    reaches the tail -- a livelock that looks exactly like progress in the log
    because the same lines keep appearing. Measured 2026-09-14: the 00:02 run
    searched series 3-5 seasons 1-6, and nothing would have stopped the 04:02
    run searching them again.

    Radarr does not need this: its sweep is bulk, so it has no head to get
    stuck on.
    """
    now = now or datetime.now(timezone.utc)
    cutoff = now - timedelta(hours=hours)
    seen = set()
    for entry in history.get("runs", []):
        if entry.get("kind") != kind:
            continue
        try:
            when = datetime.fromisoformat(entry["at"])
        except (KeyError, ValueError):
            continue
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
        if when >= cutoff:
            unit = entry.get("unit")
            if unit:
                seen.add(unit)
    return seen


def sonarr_units(wanted):
    """One unit of work is a (series, season) pair, not an episode."""
    units = []
    for series_id, seasons in wanted.items():
        for season, eps in seasons.items():
            units.append((series_id, season, len(eps)))
    # Ordered by series then season so successive runs advance through the list
    # instead of re-searching the same head of it every time.
    units.sort(key=lambda u: (u[0], u[1]))
    return units


def process_sonarr(api, apply_changes, verbose, limit, state, out, cooldown_hours=6.0):
    """Search the episode backlog, bounded per run UNTIL it is small enough.

    `MissingEpisodeSearch` is the same trap as the films' bulk command and a
    worse one: measured, it opened with "Performing search for 3116 episodes",
    could not be cancelled (Sonarr returns 409 for a command that has already
    started), and had to be killed by restarting the container.

    So the default is a bounded walk of at most `limit` seasons per run, which
    is what actually drains the backlog here: ~207 seasons, ten per run, every
    four hours. Once the remaining work fits inside one run it switches to the
    bulk command, which finishes the tail in one request instead of several --
    and by then the burst is bounded by definition, because the backlog is
    smaller than the limit.
    """
    queued_records = api.get("/api/v3/queue?pageSize=200") or {}
    records = queued_records.get("records") or []
    _, queued_episode_ids = queue_keys(records)

    wanted = sonarr_candidates(api, queued_episode_ids)
    missing = sum(len(eps) for seasons in wanted.values() for eps in seasons.values())
    out(f"  {missing} episode(s) missing and not already queued, across {len(wanted)} series")

    units = sonarr_units(wanted)
    if not units:
        out("  nothing to search")
        return 0

    # Drop what a recent run already asked for. Without this the ordered walk
    # restarts at the same head every run and the tail is never reached.
    recent = recently_searched(state.get("history", {}), "sonarr-season", cooldown_hours)
    fresh = [u for u in units if unit_id(u[0], u[1]) not in recent]
    if fresh:
        units = fresh
    else:
        out(
            f"  all {len(units)} unit(s) were searched within {cooldown_hours}h; "
            "nothing new to try yet"
        )
        return 0

    if len(units) <= limit:
        if not apply_changes:
            out(f"    would run MissingEpisodeSearch ({len(units)} season(s) left, fits in one run)")
            return 0
        api.post_command("MissingEpisodeSearch")
        state["runs"].append(
            {
                "at": datetime.now(timezone.utc).isoformat(),
                "kind": "sonarr-bulk",
                "count": missing,
            }
        )
        out(f"    MissingEpisodeSearch queued ({len(units)} season(s), {missing} episode(s))")
        return len(units)

    selected = units[:limit]
    if not apply_changes:
        for series_id, season, count in selected:
            out(f"    would search: series {series_id} season {season} ({count} episode(s))")
        out(f"    ... and {len(units) - limit} season(s) more in a later run")
        return 0

    for series_id, season, count in selected:
        api.post_command("SeasonSearch", seriesId=series_id, seasonNumber=season)
        state["runs"].append(
            {
                "at": datetime.now(timezone.utc).isoformat(),
                "kind": "sonarr-season",
                "unit": unit_id(series_id, season),
                "episodes": count,
            }
        )
        out(f"    search queued: series {series_id} season {season} ({count} episode(s))")
    out(f"    {len(units) - limit} season(s) remain for a later run")
    return len(selected)


def today():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def run(apply_changes, verbose, limit, state_path=None, out=print, cooldown_hours=6.0):
    """Search the backlog. Returns (radarr, sonarr) counts, or None on failure."""
    sonarr_key = os.environ.get("SONARR_API_KEY")
    radarr_key = os.environ.get("RADARR_API_KEY")
    if not sonarr_key and not radarr_key:
        out("ERROR: neither SONARR_API_KEY nor RADARR_API_KEY is set")
        return None

    state = {"runs": []}
    if state_path:
        state["history"] = load_state(state_path)

    counts = {}

    if radarr_key:
        api = ArrApi("Radarr", "http://localhost:7878", radarr_key)
        out("Radarr:")
        counts["radarr"] = process_radarr(
            api, apply_changes, verbose, state, out, cooldown_hours
        )
    if sonarr_key:
        api = ArrApi("Sonarr", "http://localhost:8989", sonarr_key)
        out("Sonarr:")
        counts["sonarr"] = process_sonarr(
            api, apply_changes, verbose, limit, state, out, cooldown_hours
        )

    if apply_changes and state_path:
        save_state(state_path, state["runs"], state.get("history", {}))

    return counts.get("radarr", 0), counts.get("sonarr", 0)


def save_state(path, new_runs, previous=None):
    """Append this run's records, trimmed to a 14-day window.

    Appended rather than replaced: a run that searched nothing must not erase
    the record of the run that did, and the Radarr cooldown depends on the
    previous run's timestamp surviving. Trimmed on the same 14-day window the
    queue cleanup keeps, for the same reason -- an unbounded append on an
    hourly timer is a slow disk leak.
    """
    # `previous` is normally `{"runs": []}` rather than None, and an empty dict
    # is truthy -- so the obvious `if not previous: return` guard never fires
    # and every no-op run rewrites the file. Test for the runs, not the dict.
    if not new_runs and not (previous or {}).get("runs"):
        return

    history = list(previous.get("runs", [])) if previous else []
    history.extend(new_runs)

    cutoff = datetime.now(timezone.utc).timestamp() - 14 * 86400
    kept = []
    for entry in history:
        try:
            when = datetime.fromisoformat(entry["at"])
        except (KeyError, ValueError, TypeError):
            continue
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
        if when.timestamp() >= cutoff:
            kept.append(entry)

    payload = {"runs": kept}
    tmp = f"{path}.tmp"
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2)
            handle.write("\n")
        os.replace(tmp, path)
    except OSError as err:
        print(f"warning: could not write {path}: {err}", file=sys.stderr)


def main(argv):
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2

    apply_changes = argv[1] == "true"
    verbose = argv[2] == "true"
    try:
        limit = int(argv[3])
    except ValueError:
        print(f"limit must be an integer, got {argv[3]!r}", file=sys.stderr)
        return 2
    if limit < 1:
        print("limit must be at least 1", file=sys.stderr)
        return 2

    state_path = argv[4] if len(argv) > 4 else None
    cooldown_hours = 6.0
    if len(argv) > 5:
        try:
            cooldown_hours = float(argv[5])
        except ValueError:
            print(f"cooldown must be a number of hours, got {argv[5]!r}", file=sys.stderr)
            return 2
    if cooldown_hours < 0:
        print("cooldown must not be negative", file=sys.stderr)
        return 2

    result = run(
        apply_changes, verbose, limit, state_path=state_path, cooldown_hours=cooldown_hours
    )
    if result is None:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
