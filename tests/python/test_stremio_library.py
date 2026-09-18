"""Behavioural tests for scripts/lib/stremio_library.py.

Two properties carry this module, and both are the kind that fail silently:

  * the filter that separates a library addition from a viewing-history record.
    Stremio writes both into one collection -- 933 of this account's 1078
    records are tombstones or `temp` watch entries -- so dropping the filter
    does not error, it requests 933 titles nobody asked for.

  * the rule that nothing is marked handled unless it was acted on. The
    alternative loses work rather than duplicating it: a pass capped by --max
    that recorded the whole pending list would silently drop everything past
    the cap, forever, and the log would say it had succeeded.

The API fakes are injected, so no test here touches the network. That is not
tidiness: this module's real inputs are a live account's library and a live
Seerr instance, and a test that read either would change its answer when the
household added a film.
"""

import json

import pytest

import stremio_library as m


# --------------------------------------------------------------------------
# Fakes
# --------------------------------------------------------------------------

class FakeHttp:
    """Stands in for `m.Http`, routing on substrings of the URL.

    `routes` maps a substring to whatever should come back: a parsed document,
    an Exception instance to raise, or a callable taking (url, data).
    """

    def __init__(self, routes=None):
        self.routes = routes or {}
        self.requests = []

    def json(self, url, method="GET", headers=None, data=None):
        self.requests.append(
            {"url": url, "method": method, "headers": headers, "data": data})
        for needle, answer in self.routes.items():
            if needle in url:
                if isinstance(answer, Exception):
                    raise answer
                if callable(answer):
                    return answer(url, data)
                return answer
        raise AssertionError("no route for %s" % url)

    def urls(self):
        return [r["url"] for r in self.requests]


def http_error(status, url="http://seerr.local/x"):
    return m.HttpError(status, "detail", url)


class FakeStremio:
    def __init__(self, items):
        self.items = items

    def library_items(self):
        return self.items


class FakeCinemeta:
    """`mapping` is {imdb_id: tmdb_id}; `raises` is {imdb_id: HttpError}."""

    def __init__(self, mapping=None, raises=None):
        self.mapping = mapping or {}
        self.raises = raises or {}
        self.calls = []

    def tmdb_id(self, item_type, imdb_id):
        self.calls.append((item_type, imdb_id))
        if imdb_id in self.raises:
            raise self.raises[imdb_id]
        return self.mapping.get(imdb_id)


class FakeSeerr:
    """`info` is {(media_type, tmdb_id): mediaInfo}; a missing key means 404."""

    def __init__(self, info=None, lookup_errors=None, request_errors=None):
        self.info = info or {}
        self.lookup_errors = lookup_errors or {}
        self.request_errors = request_errors or {}
        self.lookups = []
        self.requests = []

    def media_info(self, media_type, tmdb_id):
        self.lookups.append((media_type, tmdb_id))
        if (media_type, tmdb_id) in self.lookup_errors:
            raise self.lookup_errors[(media_type, tmdb_id)]
        return self.info.get((media_type, tmdb_id))

    def request(self, media_type, tmdb_id):
        self.requests.append((media_type, tmdb_id))
        if (media_type, tmdb_id) in self.request_errors:
            raise self.request_errors[(media_type, tmdb_id)]
        return {"id": 1}


class Collector:
    """Stand-in for the module's `out` callback."""

    def __init__(self):
        self.lines = []

    def __call__(self, line):
        self.lines.append(line)

    def text(self):
        return "\n".join(self.lines)


# --------------------------------------------------------------------------
# Fixtures / small builders
# --------------------------------------------------------------------------

def record(item_id, name="A Title", item_type="movie", ctime="2026-01-01T00:00:00.000Z",
           removed=False, temp=False, **extra):
    doc = {
        "_id": item_id,
        "name": name,
        "type": item_type,
        "removed": removed,
        "temp": temp,
        "_ctime": ctime,
        "_mtime": ctime,
    }
    doc.update(extra)
    return doc


def entry(item_id, name="A Title", item_type="movie", ctime="2026-01-01T00:00:00.000Z"):
    return {"id": item_id, "type": item_type, "name": name, "ctime": ctime}


def run_pass(tmp_path, items, cinemeta=None, seerr=None, **kwargs):
    out = Collector()
    result = m.run(
        FakeStremio(items),
        cinemeta or FakeCinemeta(),
        seerr or FakeSeerr(),
        str(tmp_path / "state.json"),
        out=out,
        **kwargs,
    )
    return result, out


def state_of(tmp_path):
    with open(tmp_path / "state.json", encoding="utf-8") as handle:
        return json.load(handle)


# --------------------------------------------------------------------------
# library_entries: the collection is not the library
# --------------------------------------------------------------------------

def test_library_entries_keeps_an_added_item():
    entries = m.library_entries([record("tt1")])
    assert [e["id"] for e in entries] == ["tt1"]


def test_library_entries_drops_removed_tombstones():
    # A deleted item keeps its record so other clients learn about the delete.
    # Requesting one would re-download something the user deliberately removed.
    assert m.library_entries([record("tt1", removed=True)]) == []


def test_library_entries_drops_temp_watch_records():
    # `temp` is what Stremio writes when a title is *watched* rather than
    # added. On this account they outnumber the real library six to one.
    assert m.library_entries([record("tt1", temp=True)]) == []


def test_library_entries_drops_a_record_that_is_both_removed_and_temp():
    assert m.library_entries([record("tt1", removed=True, temp=True)]) == []


def test_library_entries_keeps_a_record_explicitly_not_removed_and_not_temp():
    entries = m.library_entries(
        [record("tt1", removed=False, temp=False)])
    assert [e["id"] for e in entries] == ["tt1"]


def test_library_entries_drops_records_without_an_id():
    assert m.library_entries([record("")]) == []
    assert m.library_entries([{"name": "no id at all"}]) == []
    assert m.library_entries([{"_id": None}]) == []


def test_library_entries_ignores_junk_that_is_not_an_object():
    assert m.library_entries(["nonsense", 42, None]) == []


def test_library_entries_orders_oldest_first():
    # A capped pass walks this order, so oldest-first is what makes a backlog
    # drain in the order the titles were added rather than re-serving its head.
    entries = m.library_entries([
        record("tt2", ctime="2026-03-01T00:00:00.000Z"),
        record("tt1", ctime="2026-01-01T00:00:00.000Z"),
        record("tt3", ctime="2026-02-01T00:00:00.000Z"),
    ])
    assert [e["id"] for e in entries] == ["tt1", "tt3", "tt2"]


def test_library_entries_breaks_a_timestamp_tie_by_id():
    # Without this the order depends on what the API happened to return, and a
    # capped pass could ask for the same item twice across two runs.
    entries = m.library_entries([
        record("tt9", ctime="2026-01-01T00:00:00.000Z"),
        record("tt1", ctime="2026-01-01T00:00:00.000Z"),
    ])
    assert [e["id"] for e in entries] == ["tt1", "tt9"]


def test_library_entries_carries_the_fields_the_report_needs():
    entries = m.library_entries(
        [record("tt1", name="Army of Darkness", item_type="movie")])
    assert entries[0]["name"] == "Army of Darkness"
    assert entries[0]["type"] == "movie"
    assert entries[0]["ctime"] == "2026-01-01T00:00:00.000Z"


def test_library_entries_tolerates_a_record_with_no_type_or_name():
    entries = m.library_entries([{"_id": "tt1"}])
    assert entries[0]["type"] == ""
    assert entries[0]["name"] == ""


def test_library_entries_keeps_a_real_library_out_of_a_real_collection_shape():
    # The measured shape in miniature: one added film, one watched-and-forgotten
    # film, one deleted film.
    entries = m.library_entries([
        record("tt0111161", name="Added", removed=False, temp=False),
        record("tt0068646", name="Watched", removed=True, temp=True),
        record("tt0071562", name="Deleted", removed=True, temp=False),
    ])
    assert [e["id"] for e in entries] == ["tt0111161"]


# --------------------------------------------------------------------------
# resolve: three id shapes, two of them needing a lookup
# --------------------------------------------------------------------------

def test_resolve_reads_a_tmdb_prefixed_id_without_looking_anything_up():
    cinemeta = FakeCinemeta()
    assert m.resolve(entry("tmdb:374052"), cinemeta) == ("movie", 374052)
    assert cinemeta.calls == []


def test_resolve_maps_a_tmdb_prefixed_series_to_tv():
    assert m.resolve(entry("tmdb:1399", item_type="series"),
                     FakeCinemeta()) == ("tv", 1399)


def test_resolve_returns_none_for_a_non_numeric_tmdb_prefixed_id():
    assert m.resolve(entry("tmdb:not-a-number"), FakeCinemeta()) is None


def test_resolve_translates_an_imdb_id_through_cinemeta():
    cinemeta = FakeCinemeta({"tt0072890": 968})
    assert m.resolve(entry("tt0072890"), cinemeta) == ("movie", 968)
    assert cinemeta.calls == [("movie", "tt0072890")]


def test_resolve_asks_cinemeta_for_a_series_path_and_returns_tv():
    cinemeta = FakeCinemeta({"tt0903747": 1396})
    assert m.resolve(entry("tt0903747", item_type="series"), cinemeta) == ("tv", 1396)
    assert cinemeta.calls == [("series", "tt0903747")]


def test_resolve_treats_anime_as_series_for_the_lookup():
    # Cinemeta has no anime path; the item still resolves as a series.
    cinemeta = FakeCinemeta({"tt1234": 55})
    assert m.resolve(entry("tt1234", item_type="anime"), cinemeta) == ("tv", 55)
    assert cinemeta.calls == [("anime", "tt1234")]


def test_resolve_returns_none_when_cinemeta_has_no_mapping():
    assert m.resolve(entry("tt0000001"), FakeCinemeta()) is None


def test_resolve_returns_none_for_an_unknown_id_prefix():
    # `kitsu:` and friends. Guessing from the title is how the wrong film gets
    # requested, so an unresolvable id is a skip and not a search.
    cinemeta = FakeCinemeta()
    assert m.resolve(entry("kitsu:1234", item_type="anime"), cinemeta) is None
    assert cinemeta.calls == []


def test_resolve_returns_none_for_an_id_that_is_neither_prefixed_nor_imdb():
    cinemeta = FakeCinemeta()
    assert m.resolve(entry("local-movie-1"), cinemeta) is None
    assert cinemeta.calls == []


def test_resolve_returns_none_for_a_type_seerr_cannot_be_asked_about():
    cinemeta = FakeCinemeta({"tt1": 5})
    assert m.resolve(entry("tt1", item_type="channel"), cinemeta) is None
    assert cinemeta.calls == []


def test_resolve_lets_a_lookup_failure_travel():
    # A network failure must not be flattened into "no id": the item then gets
    # recorded as unresolvable and never retried, so a Cinemeta blip would
    # silently drop whichever titles were added during it.
    cinemeta = FakeCinemeta(raises={"tt1": http_error(None)})
    with pytest.raises(m.HttpError):
        m.resolve(entry("tt1"), cinemeta)


# --------------------------------------------------------------------------
# already_coming
# --------------------------------------------------------------------------

def test_already_coming_is_false_for_a_title_seerr_has_never_seen():
    assert m.already_coming(None) is False
    assert m.already_coming({}) is False
    assert m.already_coming({"status": 1}) is False


def test_already_coming_is_true_when_a_request_exists():
    assert m.already_coming({"status": 2, "requests": [{"id": 1}]}) is True


def test_already_coming_is_true_when_the_title_is_available():
    # The case that matters for a film already in Jellyfin that never went
    # through Seerr: no request anywhere, but the file is there.
    assert m.already_coming({"status": m.MEDIA_AVAILABLE}) is True


def test_already_coming_is_false_for_a_partially_available_series():
    # Status 4 is one season of several. Sonarr only grabs monitored, missing
    # episodes, so asking again is how the rest arrives.
    assert m.already_coming({"status": 4}) is False


def test_already_coming_is_false_for_a_deleted_media_record():
    assert m.already_coming({"status": 6}) is False


# --------------------------------------------------------------------------
# StremioClient: a 200 that is not a success
# --------------------------------------------------------------------------

def stremio_client(routes):
    http = FakeHttp(routes)
    return m.StremioClient("key", http), http


def test_library_items_returns_the_result_list():
    client, _ = stremio_client({"datastoreGet": {"result": [record("tt1")]}})
    assert [i["_id"] for i in client.library_items()] == ["tt1"]


def test_library_items_posts_the_datastore_request_shape():
    client, http = stremio_client({"datastoreGet": {"result": []}})
    client.library_items()
    sent = http.requests[0]
    assert sent["method"] == "POST"
    assert sent["data"] == {"authKey": "key", "collection": "libraryItem",
                            "all": True}


def test_library_items_raises_on_an_error_body_returned_with_http_200():
    # Measured 2026-09-17: an expired key answers 200 with
    # {"error": {"code": 1, "message": "Session does not exist"}}. Reading that
    # as an empty library is the failure mode this test exists for -- the sync
    # would keep running, report no new items, and never request anything again.
    client, _ = stremio_client({"datastoreGet": {
        "error": {"code": 1, "message": "Session does not exist"}}})
    with pytest.raises(m.HttpError) as caught:
        client.library_items()
    assert "Session does not exist" in str(caught.value)


def test_library_items_raises_when_the_result_key_is_missing():
    client, _ = stremio_client({"datastoreGet": {"something": "else"}})
    with pytest.raises(m.HttpError):
        client.library_items()


def test_library_items_raises_when_the_result_is_not_a_list():
    client, _ = stremio_client({"datastoreGet": {"result": {"not": "a list"}}})
    with pytest.raises(m.HttpError):
        client.library_items()


def test_library_items_raises_when_the_body_is_not_an_object():
    client, _ = stremio_client({"datastoreGet": ["a list"]})
    with pytest.raises(m.HttpError):
        client.library_items()


# --------------------------------------------------------------------------
# CinemetaClient
# --------------------------------------------------------------------------

def cinemeta_client(meta):
    return m.CinemetaClient(FakeHttp({"cinemeta": {"meta": meta}}))


def test_cinemeta_returns_the_tmdb_id():
    assert cinemeta_client({"moviedb_id": 968}).tmdb_id("movie", "tt0072890") == 968


def test_cinemeta_coerces_a_string_tmdb_id():
    assert cinemeta_client({"moviedb_id": "968"}).tmdb_id("movie", "tt1") == 968


def test_cinemeta_returns_none_when_there_is_no_moviedb_id():
    assert cinemeta_client({"imdb_id": "tt1"}).tmdb_id("movie", "tt1") is None


def test_cinemeta_returns_none_for_a_null_moviedb_id():
    assert cinemeta_client({"moviedb_id": None}).tmdb_id("movie", "tt1") is None


def test_cinemeta_returns_none_for_a_non_numeric_moviedb_id():
    # A raise here would be read upstream as "retry later" for a title that can
    # never resolve, so it is an answer rather than an error.
    assert cinemeta_client({"moviedb_id": "unknown"}).tmdb_id("movie", "tt1") is None


def test_cinemeta_returns_none_when_the_meta_object_is_missing():
    client = m.CinemetaClient(FakeHttp({"cinemeta": {"no": "meta"}}))
    assert client.tmdb_id("movie", "tt1") is None


def test_cinemeta_does_not_look_up_a_type_it_has_no_path_for():
    http = FakeHttp({})
    client = m.CinemetaClient(http)
    assert client.tmdb_id("channel", "tt1") is None
    assert http.requests == []


def test_cinemeta_builds_the_movie_url():
    http = FakeHttp({"cinemeta": {"meta": {}}})
    m.CinemetaClient(http, url="https://cinemeta.test").tmdb_id("movie", "tt0072890")
    assert http.urls() == ["https://cinemeta.test/meta/movie/tt0072890.json"]


def test_cinemeta_builds_the_series_url():
    http = FakeHttp({"cinemeta": {"meta": {}}})
    m.CinemetaClient(http, url="https://cinemeta.test/").tmdb_id("series", "tt0903747")
    assert http.urls() == ["https://cinemeta.test/meta/series/tt0903747.json"]


# --------------------------------------------------------------------------
# SeerrClient
# --------------------------------------------------------------------------

def seerr_client(routes):
    http = FakeHttp(routes)
    return m.SeerrClient("http://seerr.test", "apikey", http), http


def test_seerr_media_info_returns_the_media_info_object():
    client, _ = seerr_client({"seerr.test/api/v1/movie/968":
                              {"mediaInfo": {"status": 5}}})
    assert client.media_info("movie", 968) == {"status": 5}


def test_seerr_media_info_is_an_empty_dict_when_the_key_is_absent():
    client, _ = seerr_client({"seerr.test/api/v1/movie/968": {"title": "x"}})
    assert client.media_info("movie", 968) == {}


def test_seerr_media_info_returns_none_on_a_404():
    # A real answer, not a failure: Seerr has never been asked about this title.
    client, _ = seerr_client({"seerr.test": http_error(404)})
    assert client.media_info("movie", 968) is None


def test_seerr_media_info_lets_a_500_travel():
    # "I could not ask" must never be read as "not there" and turned into a
    # request -- that is how a Seerr outage becomes a request storm.
    client, _ = seerr_client({"seerr.test": http_error(500)})
    with pytest.raises(m.HttpError):
        client.media_info("movie", 968)


def test_seerr_media_info_lets_a_transport_failure_travel():
    client, _ = seerr_client({"seerr.test": http_error(None)})
    with pytest.raises(m.HttpError):
        client.media_info("movie", 968)


def test_seerr_media_info_uses_the_tv_path_for_a_series():
    client, http = seerr_client({"seerr.test": {"mediaInfo": {}}})
    client.media_info("tv", 1399)
    assert http.urls() == ["http://seerr.test/api/v1/tv/1399"]


def test_seerr_media_info_sends_the_api_key():
    client, http = seerr_client({"seerr.test": {"mediaInfo": {}}})
    client.media_info("movie", 1)
    assert http.requests[0]["headers"] == {"X-Api-Key": "apikey"}


def test_seerr_request_posts_a_movie_without_seasons():
    client, http = seerr_client({"seerr.test": {"id": 1}})
    client.request("movie", 968)
    sent = http.requests[0]
    assert sent["method"] == "POST"
    assert sent["data"] == {"mediaType": "movie", "mediaId": 968}


def test_seerr_request_posts_a_series_with_every_season():
    client, http = seerr_client({"seerr.test": {"id": 1}})
    client.request("tv", 1399)
    assert http.requests[0]["data"] == {"mediaType": "tv", "mediaId": 1399,
                                        "seasons": "all"}


def test_seerr_request_targets_the_request_endpoint():
    client, http = seerr_client({"seerr.test": {"id": 1}})
    client.request("movie", 968)
    assert http.urls() == ["http://seerr.test/api/v1/request"]


def test_seerr_base_url_tolerates_a_trailing_slash():
    http = FakeHttp({"seerr.test": {"mediaInfo": {}}})
    client = m.SeerrClient("http://seerr.test/", "apikey", http)
    client.media_info("movie", 1)
    assert http.urls() == ["http://seerr.test/api/v1/movie/1"]


# --------------------------------------------------------------------------
# State file
# --------------------------------------------------------------------------

def test_load_state_returns_none_when_there_is_no_file(tmp_path):
    assert m.load_state(str(tmp_path / "absent.json")) is None


def test_load_state_returns_the_document(tmp_path):
    path = tmp_path / "state.json"
    path.write_text(json.dumps({"handled": {"tt1": {}}}), encoding="utf-8")
    assert m.load_state(str(path))["handled"] == {"tt1": {}}


def test_load_state_refuses_malformed_json(tmp_path):
    # Fatal rather than replaced: starting over from empty is a burst, not a
    # recovery.
    path = tmp_path / "state.json"
    path.write_text("{not json", encoding="utf-8")
    with pytest.raises(m.StateError):
        m.load_state(str(path))


def test_load_state_refuses_a_document_with_no_handled_mapping(tmp_path):
    path = tmp_path / "state.json"
    path.write_text(json.dumps({"version": 1}), encoding="utf-8")
    with pytest.raises(m.StateError):
        m.load_state(str(path))


def test_load_state_refuses_a_handled_mapping_that_is_not_an_object(tmp_path):
    path = tmp_path / "state.json"
    path.write_text(json.dumps({"handled": ["tt1"]}), encoding="utf-8")
    with pytest.raises(m.StateError):
        m.load_state(str(path))


def test_save_state_round_trips(tmp_path):
    path = str(tmp_path / "state.json")
    m.save_state(path, {"version": 1, "handled": {"tt1": {"result": "requested"}}})
    assert m.load_state(path)["handled"]["tt1"]["result"] == "requested"


def test_save_state_leaves_no_temporary_file_behind(tmp_path):
    path = tmp_path / "state.json"
    m.save_state(str(path), {"version": 1, "handled": {}})
    assert [p.name for p in tmp_path.iterdir()] == ["state.json"]


def test_save_state_replaces_an_existing_file_rather_than_appending(tmp_path):
    path = str(tmp_path / "state.json")
    m.save_state(path, {"version": 1, "handled": {"tt1": {}}})
    m.save_state(path, {"version": 1, "handled": {"tt2": {}}})
    assert list(m.load_state(path)["handled"]) == ["tt2"]


# --------------------------------------------------------------------------
# run(): the first pass baselines
# --------------------------------------------------------------------------

def test_first_apply_run_records_the_library_and_requests_nothing(tmp_path):
    # 122 of this library's 145 items are in neither arr. Requesting them in
    # one pass is the burst that earned this TorBox account a 90-minute
    # refusal, so the default first run is a baseline.
    items = [record("tt1"), record("tt2"), record("tt3")]
    seerr = FakeSeerr()
    result, out = run_pass(tmp_path, items, seerr=seerr, apply_changes=True)

    assert result == 0
    assert seerr.requests == []
    assert set(state_of(tmp_path)["handled"]) == {"tt1", "tt2", "tt3"}
    assert "requested nothing" in out.text()


def test_first_apply_run_marks_the_baselined_items_as_baselined(tmp_path):
    run_pass(tmp_path, [record("tt1")], apply_changes=True)
    assert state_of(tmp_path)["handled"]["tt1"]["result"] == "baselined"


def test_first_dry_run_writes_no_state_and_requests_nothing(tmp_path):
    # Inspecting must never be the thing that consumes the queue.
    seerr = FakeSeerr()
    result, out = run_pass(tmp_path, [record("tt1")], seerr=seerr)

    assert result == 0
    assert seerr.requests == []
    assert not (tmp_path / "state.json").exists()
    assert "requested nothing" in out.text()


def test_first_run_does_not_consult_seerr_for_anything(tmp_path):
    # Baselining is a record-keeping pass. Calling Seerr for 145 titles to
    # decide something it is not going to act on is 145 requests for nothing.
    seerr = FakeSeerr()
    run_pass(tmp_path, [record("tt1"), record("tt2")], seerr=seerr,
             apply_changes=True)
    assert seerr.lookups == []


def test_first_run_with_backfill_requests_instead_of_baselining(tmp_path):
    seerr = FakeSeerr()
    result, out = run_pass(
        tmp_path,
        [record("tt1", name="One")],
        cinemeta=FakeCinemeta({"tt1": 11}),
        seerr=seerr,
        apply_changes=True,
        backfill=True,
    )

    assert result == 0
    assert seerr.requests == [("movie", 11)]
    assert state_of(tmp_path)["handled"]["tt1"]["result"] == "requested"
    assert "backfill" in out.text()


def test_backfill_still_honours_the_cap(tmp_path):
    seerr = FakeSeerr()
    items = [record("tt%d" % n, ctime="2026-01-%02dT00:00:00.000Z" % n)
             for n in range(1, 6)]
    run_pass(
        tmp_path, items,
        cinemeta=FakeCinemeta({f"tt{n}": n for n in range(1, 6)}),
        seerr=seerr, apply_changes=True, backfill=True, max_requests=2,
    )
    assert seerr.requests == [("movie", 1), ("movie", 2)]


def test_a_baseline_run_creates_no_requests_even_with_no_cap(tmp_path):
    seerr = FakeSeerr()
    run_pass(tmp_path, [record("tt1"), record("tt2")], seerr=seerr,
             apply_changes=True, max_requests=0)
    assert seerr.requests == []


# --------------------------------------------------------------------------
# run(): steady state
# --------------------------------------------------------------------------

def seed(tmp_path, handled):
    m.save_state(str(tmp_path / "state.json"),
                 {"version": 1, "baselined_at": "2026-01-01T00:00:00+00:00",
                  "handled": {key: {"result": "requested"} for key in handled}})


def already_baselined(tmp_path):
    """Put the state file in its steady state, with nothing handled yet.

    Without this a pass is a *first* pass, which baselines: it records the
    library and requests none of it. That is correct behaviour and not what
    most of these tests are about, so the precondition is stated rather than
    left implied.
    """
    seed(tmp_path, [])


def test_a_handled_item_is_not_requested_again(tmp_path):
    seed(tmp_path, ["tt1"])
    seerr = FakeSeerr()
    result, out = run_pass(
        tmp_path, [record("tt1")],
        cinemeta=FakeCinemeta({"tt1": 11}), seerr=seerr, apply_changes=True)

    assert result == 0
    assert seerr.requests == []
    assert "Nothing new" in out.text()


def test_only_the_new_item_is_requested(tmp_path):
    seed(tmp_path, ["tt1"])
    seerr = FakeSeerr()
    run_pass(
        tmp_path,
        [record("tt1", ctime="2026-01-01T00:00:00.000Z"),
         record("tt2", ctime="2026-02-01T00:00:00.000Z")],
        cinemeta=FakeCinemeta({"tt1": 11, "tt2": 22}),
        seerr=seerr, apply_changes=True)

    assert seerr.requests == [("movie", 22)]


def test_a_new_item_requests_the_resolved_tmdb_id(tmp_path):
    already_baselined(tmp_path)
    seerr = FakeSeerr()
    run_pass(tmp_path, [record("tt0072890", name="Dog Day Afternoon")],
             cinemeta=FakeCinemeta({"tt0072890": 968}), seerr=seerr,
             apply_changes=True)
    assert seerr.requests == [("movie", 968)]


def test_a_new_series_requests_as_tv(tmp_path):
    already_baselined(tmp_path)
    seerr = FakeSeerr()
    run_pass(tmp_path, [record("tt0903747", item_type="series")],
             cinemeta=FakeCinemeta({"tt0903747": 1396}), seerr=seerr,
             apply_changes=True)
    assert seerr.requests == [("tv", 1396)]


def test_a_tmdb_prefixed_item_is_requested_without_a_lookup(tmp_path):
    already_baselined(tmp_path)
    seerr = FakeSeerr()
    cinemeta = FakeCinemeta()
    run_pass(tmp_path, [record("tmdb:374052")], cinemeta=cinemeta, seerr=seerr,
             apply_changes=True)
    assert seerr.requests == [("movie", 374052)]
    assert cinemeta.calls == []


def test_the_result_is_recorded_so_the_next_pass_skips_it(tmp_path):
    seed(tmp_path, [])
    run_pass(tmp_path, [record("tt1")], cinemeta=FakeCinemeta({"tt1": 11}),
             seerr=FakeSeerr(), apply_changes=True)
    recorded = state_of(tmp_path)["handled"]["tt1"]
    assert recorded["result"] == "requested"
    assert recorded["tmdb"] == 11
    assert recorded["name"] == "A Title"
    assert recorded["at"]


def test_a_removed_item_is_left_alone(tmp_path):
    # Nothing here deletes anything, and a library edit must not become one.
    seed(tmp_path, ["tt1"])
    seerr = FakeSeerr()
    result, _ = run_pass(tmp_path, [record("tt1", removed=True)], seerr=seerr,
                         apply_changes=True)
    assert result == 0
    assert seerr.requests == []
    assert "tt1" in state_of(tmp_path)["handled"]


# --------------------------------------------------------------------------
# run(): the cap, and why an unacted item must stay pending
# --------------------------------------------------------------------------

def capped_items(count):
    return [record("tt%d" % n, ctime="2026-01-%02dT00:00:00.000Z" % n)
            for n in range(1, count + 1)]


def capped_cinemeta(count):
    return FakeCinemeta({"tt%d" % n: n for n in range(1, count + 1)})


def test_the_cap_bounds_how_many_requests_one_pass_makes(tmp_path):
    already_baselined(tmp_path)
    seerr = FakeSeerr()
    run_pass(tmp_path, capped_items(5), cinemeta=capped_cinemeta(5), seerr=seerr,
             apply_changes=True, max_requests=2)
    assert len(seerr.requests) == 2


def test_the_cap_requests_the_oldest_items_first(tmp_path):
    already_baselined(tmp_path)
    seerr = FakeSeerr()
    run_pass(tmp_path, capped_items(5), cinemeta=capped_cinemeta(5), seerr=seerr,
             apply_changes=True, max_requests=2)
    assert seerr.requests == [("movie", 1), ("movie", 2)]


def test_items_past_the_cap_are_not_recorded_as_handled(tmp_path):
    already_baselined(tmp_path)
    # The failure this guards is silent and permanent: recording the whole
    # pending list would drop everything past the cap forever, while the log
    # reported success.
    run_pass(tmp_path, capped_items(5), cinemeta=capped_cinemeta(5),
             seerr=FakeSeerr(), apply_changes=True, max_requests=2)
    assert set(state_of(tmp_path)["handled"]) == {"tt1", "tt2"}


def test_a_second_pass_picks_up_what_the_cap_left(tmp_path):
    already_baselined(tmp_path)
    run_pass(tmp_path, capped_items(5), cinemeta=capped_cinemeta(5),
             seerr=FakeSeerr(), apply_changes=True, max_requests=2)

    seerr = FakeSeerr()
    run_pass(tmp_path, capped_items(5), cinemeta=capped_cinemeta(5), seerr=seerr,
             apply_changes=True, max_requests=2)
    assert seerr.requests == [("movie", 3), ("movie", 4)]


def test_a_cap_larger_than_the_pending_list_changes_nothing(tmp_path):
    already_baselined(tmp_path)
    seerr = FakeSeerr()
    run_pass(tmp_path, capped_items(2), cinemeta=capped_cinemeta(2), seerr=seerr,
             apply_changes=True, max_requests=10)
    assert seerr.requests == [("movie", 1), ("movie", 2)]


def test_zero_means_no_cap(tmp_path):
    already_baselined(tmp_path)
    seerr = FakeSeerr()
    run_pass(tmp_path, capped_items(4), cinemeta=capped_cinemeta(4), seerr=seerr,
             apply_changes=True, max_requests=0)
    assert len(seerr.requests) == 4


def test_the_cap_is_reported_when_it_bites(tmp_path):
    already_baselined(tmp_path)
    _, out = run_pass(tmp_path, capped_items(4), cinemeta=capped_cinemeta(4),
                      seerr=FakeSeerr(), apply_changes=True, max_requests=1)
    assert "--max 1" in out.text()


# --------------------------------------------------------------------------
# run(): dry run
# --------------------------------------------------------------------------

def test_a_dry_run_requests_nothing(tmp_path):
    seed(tmp_path, [])
    seerr = FakeSeerr()
    run_pass(tmp_path, [record("tt1")], cinemeta=FakeCinemeta({"tt1": 11}),
             seerr=seerr)
    assert seerr.requests == []


def test_a_dry_run_writes_no_state(tmp_path):
    seed(tmp_path, ["tt1"])
    before = state_of(tmp_path)
    run_pass(tmp_path, [record("tt1"), record("tt2")],
             cinemeta=FakeCinemeta({"tt2": 22}), seerr=FakeSeerr())
    assert state_of(tmp_path) == before


def test_a_dry_run_still_asks_seerr_whether_the_title_is_wanted(tmp_path):
    # The interesting line in a dry run is the one that would have been
    # requested, and deciding that needs the same availability check.
    seed(tmp_path, [])
    seerr = FakeSeerr()
    run_pass(tmp_path, [record("tt1")], cinemeta=FakeCinemeta({"tt1": 11}),
             seerr=seerr)
    assert seerr.lookups == [("movie", 11)]


def test_a_dry_run_says_what_it_would_do(tmp_path):
    seed(tmp_path, [])
    _, out = run_pass(tmp_path, [record("tt1", name="Army of Darkness")],
                      cinemeta=FakeCinemeta({"tt1": 766}), seerr=FakeSeerr())
    assert "would" in out.text()
    assert "Army of Darkness" in out.text()
    assert "nothing was requested" in out.text()


def test_a_dry_run_reports_the_would_be_count_in_its_summary(tmp_path):
    seed(tmp_path, [])
    _, out = run_pass(tmp_path, capped_items(2), cinemeta=capped_cinemeta(2),
                      seerr=FakeSeerr())
    assert "2 would be requested" in out.text()


# --------------------------------------------------------------------------
# run(): Seerr's view
# --------------------------------------------------------------------------

def test_a_title_seerr_already_requested_is_skipped(tmp_path):
    seed(tmp_path, [])
    seerr = FakeSeerr(info={("movie", 11): {"status": 2, "requests": [{"id": 1}]}})
    result, out = run_pass(tmp_path, [record("tt1")],
                           cinemeta=FakeCinemeta({"tt1": 11}), seerr=seerr,
                           apply_changes=True)

    assert result == 0
    assert seerr.requests == []
    assert state_of(tmp_path)["handled"]["tt1"]["result"] == "already-in-seerr"
    assert "already has it" in out.text()


def test_a_title_already_available_in_the_library_is_skipped(tmp_path):
    seed(tmp_path, [])
    seerr = FakeSeerr(info={("movie", 11): {"status": 5}})
    run_pass(tmp_path, [record("tt1")], cinemeta=FakeCinemeta({"tt1": 11}),
             seerr=seerr, apply_changes=True)
    assert seerr.requests == []


def test_a_partially_available_series_is_still_requested(tmp_path):
    seed(tmp_path, [])
    seerr = FakeSeerr(info={("tv", 1396): {"status": 4}})
    run_pass(tmp_path, [record("tt0903747", item_type="series")],
             cinemeta=FakeCinemeta({"tt0903747": 1396}), seerr=seerr,
             apply_changes=True)
    assert seerr.requests == [("tv", 1396)]


def test_a_title_seerr_404s_on_is_requested(tmp_path):
    seed(tmp_path, [])
    seerr = FakeSeerr()  # no info for anything, so media_info returns None
    run_pass(tmp_path, [record("tt1")], cinemeta=FakeCinemeta({"tt1": 11}),
             seerr=seerr, apply_changes=True)
    assert seerr.requests == [("movie", 11)]


def test_a_409_on_the_request_is_recorded_and_does_not_fail_the_pass(tmp_path):
    # Seerr says the request already exists. That is the outcome we wanted, so
    # it must not leave the item pending to be attempted again every ten
    # minutes, and it must not make the unit report a failure.
    seed(tmp_path, [])
    seerr = FakeSeerr(request_errors={("movie", 11): http_error(409)})
    result, out = run_pass(tmp_path, [record("tt1")],
                           cinemeta=FakeCinemeta({"tt1": 11}), seerr=seerr,
                           apply_changes=True)

    assert result == 0
    assert state_of(tmp_path)["handled"]["tt1"]["result"] == "already-requested"
    assert "already exists" in out.text()


# --------------------------------------------------------------------------
# run(): failure keeps the item pending
# --------------------------------------------------------------------------

def test_a_failed_request_is_not_recorded(tmp_path):
    seed(tmp_path, [])
    seerr = FakeSeerr(request_errors={("movie", 11): http_error(500)})
    run_pass(tmp_path, [record("tt1")], cinemeta=FakeCinemeta({"tt1": 11}),
             seerr=seerr, apply_changes=True)
    assert "tt1" not in state_of(tmp_path)["handled"]


def test_a_failed_request_makes_the_pass_exit_non_zero(tmp_path):
    # The unit is oneshot: a non-zero exit is the only thing that turns "Seerr
    # was unreachable" into something visible outside the log file.
    seed(tmp_path, [])
    seerr = FakeSeerr(request_errors={("movie", 11): http_error(500)})
    result, _ = run_pass(tmp_path, [record("tt1")],
                         cinemeta=FakeCinemeta({"tt1": 11}), seerr=seerr,
                         apply_changes=True)
    assert result == 1


def test_a_failed_title_is_retried_on_the_next_pass(tmp_path):
    seed(tmp_path, [])
    run_pass(tmp_path, [record("tt1")], cinemeta=FakeCinemeta({"tt1": 11}),
             seerr=FakeSeerr(request_errors={("movie", 11): http_error(500)}),
             apply_changes=True)

    seerr = FakeSeerr()
    run_pass(tmp_path, [record("tt1")], cinemeta=FakeCinemeta({"tt1": 11}),
             seerr=seerr, apply_changes=True)
    assert seerr.requests == [("movie", 11)]


def test_a_failed_lookup_is_not_recorded(tmp_path):
    seed(tmp_path, [])
    seerr = FakeSeerr(lookup_errors={("movie", 11): http_error(500)})
    run_pass(tmp_path, [record("tt1")], cinemeta=FakeCinemeta({"tt1": 11}),
             seerr=seerr, apply_changes=True)
    assert "tt1" not in state_of(tmp_path)["handled"]


def test_a_failed_lookup_fails_the_pass(tmp_path):
    seed(tmp_path, [])
    seerr = FakeSeerr(lookup_errors={("movie", 11): http_error(500)})
    result, _ = run_pass(tmp_path, [record("tt1")],
                         cinemeta=FakeCinemeta({"tt1": 11}), seerr=seerr,
                         apply_changes=True)
    assert result == 1


# --------------------------------------------------------------------------
# run(): a metadata lookup that fails must not end the pass
#
# The defect these cover is not hypothetical and not quiet. On 2026-09-18
# Cinemeta started refusing this module's requests, and because `resolve()` was
# called outside any try the first failure propagated straight out of run():
# every pass died on the same title, made no request, and logged a 403 naming
# one library id. Ten hours of that, one pass every ten minutes, no progress.
# --------------------------------------------------------------------------

def lookup_failures(**errors):
    """A FakeCinemeta whose named ids raise instead of resolving."""
    return FakeCinemeta(raises=errors)


def test_a_failed_lookup_does_not_stop_the_pass(tmp_path):
    already_baselined(tmp_path)
    seerr = FakeSeerr()
    run_pass(
        tmp_path,
        [record("tt1", name="unlookupable", ctime="2026-01-01T00:00:00.000Z"),
         record("tt2", name="fine", ctime="2026-01-02T00:00:00.000Z")],
        cinemeta=FakeCinemeta(mapping={"tt2": 22},
                              raises={"tt1": http_error(403, url="https://cinemeta.test/x")}),
        seerr=seerr, apply_changes=True)

    # The one behind it still gets its turn.
    assert seerr.requests == [("movie", 22)]
    assert state_of(tmp_path)["handled"]["tt2"]["result"] == "requested"


def test_a_failed_lookup_leaves_that_item_pending(tmp_path):
    # Not recorded: a lookup that could not be made is not an answer, so the
    # title has to be retried rather than remembered as unresolvable forever.
    already_baselined(tmp_path)
    run_pass(tmp_path, [record("tt1")],
             cinemeta=lookup_failures(**{"tt1": http_error(403)}),
             seerr=FakeSeerr(), apply_changes=True)
    assert "tt1" not in state_of(tmp_path)["handled"]


def test_a_failed_lookup_is_reported_in_the_summary(tmp_path):
    already_baselined(tmp_path)
    _, out = run_pass(tmp_path, [record("tt1")],
                      cinemeta=lookup_failures(**{"tt1": http_error(403)}),
                      seerr=FakeSeerr(), apply_changes=True)
    assert "metadata lookup failed" in out.text()
    assert "1 failed" in out.text()


def test_the_pass_stops_after_three_consecutive_lookup_failures(tmp_path):
    # The breaker, so one pass against a wholly unreachable provider is three
    # lookups rather than one per pending title.
    already_baselined(tmp_path)
    items = capped_items(8)
    seerr = FakeSeerr()
    cinemeta = FakeCinemeta(raises={"tt%d" % n: http_error(403) for n in range(1, 9)})

    result, out = run_pass(tmp_path, items, cinemeta=cinemeta, seerr=seerr,
                           apply_changes=True, max_requests=0)

    assert result == 1
    assert len(cinemeta.calls) == m.MAX_LOOKUP_FAILURES
    assert "3 lookups failed in a row" in out.text()
    assert seerr.requests == []


def test_the_lookup_failure_counter_resets_after_a_success(tmp_path):
    # Otherwise three failures spread across an hour would end a pass that had
    # been making progress the whole time.
    already_baselined(tmp_path)
    seerr = FakeSeerr()
    cinemeta = FakeCinemeta(
        mapping={"tt2": 22, "tt4": 44, "tt6": 66},
        raises={"tt1": http_error(403), "tt3": http_error(403), "tt5": http_error(403),
                "tt7": http_error(403)})

    result, _ = run_pass(tmp_path, capped_items(7), cinemeta=cinemeta, seerr=seerr,
                         apply_changes=True, max_requests=0)

    # Four failures, but never three in a row, so the pass runs to the end.
    assert result == 1
    assert seerr.requests == [("movie", 22), ("movie", 44), ("movie", 66)]
    assert len(cinemeta.calls) == 7


# --------------------------------------------------------------------------
# the User-Agent
#
# Cinemeta redirects to a host whose Cloudflare rule refuses urllib's default
# `Python-urllib/3.11` signature with `HTTP 403  error code: 1010`. Measured
# 2026-09-18: the same URL answers 200 with any other name. Without a
# User-Agent every lookup fails, which is what killed the sync for ten hours.
# --------------------------------------------------------------------------

class FakeResponse:
    def __init__(self, payload):
        self._payload = payload

    def read(self):
        return self._payload

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def capture_headers(monkeypatch, payload=b'{"ok": true}'):
    """Run one Http.json call and return the headers urllib was given."""
    seen = {}

    def fake_urlopen(request, timeout=None):
        seen["headers"] = dict(request.headers)
        return FakeResponse(payload)

    monkeypatch.setattr(m.urllib.request, "urlopen", fake_urlopen)
    seen["result"] = m.Http().json("http://example.test/")
    return seen


def lower_headers(headers):
    return {k.lower(): v for k, v in headers.items()}


def test_every_request_carries_a_user_agent(monkeypatch):
    seen = capture_headers(monkeypatch)
    assert seen["result"] == {"ok": True}
    assert lower_headers(seen["headers"])["user-agent"] == m.USER_AGENT


def test_the_user_agent_is_not_url_urllibs_default(monkeypatch):
    # Stated as its own test because "a User-Agent is present" is already true
    # when urllib supplies its default -- and its default is the thing that is
    # blocked. Asserting presence alone would pass on the broken version.
    seen = capture_headers(monkeypatch)
    ua = lower_headers(seen["headers"])["user-agent"]
    assert not ua.lower().startswith("python-urllib")


def test_a_caller_supplied_user_agent_is_kept(monkeypatch):
    seen = {}

    def fake_urlopen(request, timeout=None):
        seen["headers"] = dict(request.headers)
        return FakeResponse(b"{}")

    monkeypatch.setattr(m.urllib.request, "urlopen", fake_urlopen)
    m.Http().json("http://example.test/", headers={"User-Agent": "caller/1.0"})
    assert lower_headers(seen["headers"])["user-agent"] == "caller/1.0"


def test_the_user_agent_does_not_displace_the_callers_other_headers(monkeypatch):
    seen = {}

    def fake_urlopen(request, timeout=None):
        seen["headers"] = dict(request.headers)
        return FakeResponse(b"{}")

    monkeypatch.setattr(m.urllib.request, "urlopen", fake_urlopen)
    m.Http().json("http://example.test/", headers={"X-Api-Key": "secret"})
    assert lower_headers(seen["headers"])["x-api-key"] == "secret"


def test_one_failing_title_does_not_stop_the_others(tmp_path):
    seed(tmp_path, [])
    seerr = FakeSeerr(request_errors={("movie", 11): http_error(500)})
    result, _ = run_pass(
        tmp_path,
        [record("tt1", ctime="2026-01-01T00:00:00.000Z"),
         record("tt2", ctime="2026-01-02T00:00:00.000Z")],
        cinemeta=FakeCinemeta({"tt1": 11, "tt2": 22}), seerr=seerr,
        apply_changes=True)

    assert seerr.requests == [("movie", 11), ("movie", 22)]
    assert result == 1
    assert state_of(tmp_path)["handled"]["tt2"]["result"] == "requested"


# --------------------------------------------------------------------------
# run(): unresolvable ids
# --------------------------------------------------------------------------

def test_an_unresolvable_id_is_recorded_as_unresolved(tmp_path):
    seed(tmp_path, [])
    run_pass(tmp_path, [record("kitsu:1234", item_type="anime")],
             seerr=FakeSeerr(), apply_changes=True)
    assert state_of(tmp_path)["handled"]["kitsu:1234"]["result"] == "unresolved"


def test_an_unresolvable_id_is_not_retried_on_the_next_pass(tmp_path):
    # Recorded once so a ten-minute timer does not re-log it forever.
    seed(tmp_path, [])
    run_pass(tmp_path, [record("kitsu:1234", item_type="anime")],
             seerr=FakeSeerr(), apply_changes=True)
    _, out = run_pass(tmp_path, [record("kitsu:1234", item_type="anime")],
                      seerr=FakeSeerr(), apply_changes=True)
    assert "Nothing new" in out.text()


def test_an_unresolvable_id_is_never_guessed_at_from_the_name(tmp_path):
    # A wrong request downloads the wrong film, which is worse than a miss.
    seed(tmp_path, [])
    seerr = FakeSeerr()
    run_pass(tmp_path, [record("kitsu:1234", name="Some Anime",
                               item_type="anime")], seerr=seerr,
             apply_changes=True)
    assert seerr.lookups == []
    assert seerr.requests == []


def test_an_unresolved_skip_does_not_fail_the_pass(tmp_path):
    seed(tmp_path, [])
    result, _ = run_pass(tmp_path, [record("kitsu:1234", item_type="anime")],
                         seerr=FakeSeerr(), apply_changes=True)
    assert result == 0


# --------------------------------------------------------------------------
# run(): the datastore itself failing
# --------------------------------------------------------------------------

def test_a_library_read_failure_travels_out_of_run(tmp_path):
    # An expired key must stop the pass, not be reported as an empty library.
    class BrokenStremio:
        def library_items(self):
            raise http_error(None, url="https://api.strem.io/api/datastoreGet")

    with pytest.raises(m.HttpError):
        m.run(BrokenStremio(), FakeCinemeta(), FakeSeerr(),
              str(tmp_path / "state.json"), out=Collector())


def test_an_unreadable_state_file_stops_the_pass(tmp_path):
    path = tmp_path / "state.json"
    path.write_text("{not json", encoding="utf-8")
    with pytest.raises(m.StateError):
        m.run(FakeStremio([record("tt1")]), FakeCinemeta(), FakeSeerr(),
              str(path), out=Collector())


# --------------------------------------------------------------------------
# Argument handling
# --------------------------------------------------------------------------

def test_non_negative_int_accepts_zero():
    assert m.non_negative_int("0") == 0


def test_non_negative_int_accepts_a_positive_number():
    assert m.non_negative_int("5") == 5


def test_non_negative_int_refuses_a_negative_number():
    # A negative cap would silently drop items from the end of the pending
    # list instead of bounding the pass.
    with pytest.raises(Exception):
        m.non_negative_int("-1")


def test_non_negative_int_refuses_a_non_number():
    with pytest.raises(Exception):
        m.non_negative_int("many")


def test_main_refuses_to_run_without_the_stremio_key(tmp_path, monkeypatch):
    monkeypatch.delenv("STREMIO_AUTH_KEY", raising=False)
    monkeypatch.setenv("SEERR_API_KEY", "seerr-key")
    assert m.main([str(tmp_path / "state.json")]) == 2


def test_main_refuses_to_run_without_the_seerr_key(tmp_path, monkeypatch):
    monkeypatch.setenv("STREMIO_AUTH_KEY", "stremio-key")
    monkeypatch.delenv("SEERR_API_KEY", raising=False)
    assert m.main([str(tmp_path / "state.json")]) == 2
