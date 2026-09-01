"""Behavioural tests for scripts/lib/fix_sonarr_folders.py.

The module was a heredoc inside fix-sonarr-folders.sh until 2026-09-01, which
is why none of this existed before: bats cannot reach a heredoc and pytest
cannot import one.
"""

import fix_sonarr_folders as m


# --- parse_apply_flag: defect #4 ------------------------------------------
# The bash half writes APPLY as lowercase `true`/`false`
# (fix-sonarr-folders.sh:51,53). The heredoc compared against the literal
# "True", so --apply never once took the apply branch.

def test_apply_flag_accepts_the_spelling_bash_actually_passes():
    assert m.parse_apply_flag("true") is True


def test_apply_flag_still_accepts_the_python_style_spelling():
    assert m.parse_apply_flag("True") is True


def test_apply_flag_is_false_for_the_bash_false():
    assert m.parse_apply_flag("false") is False


def test_apply_flag_is_false_for_anything_unrecognised():
    # Deliberately conservative: an unexpected argv value must not start
    # renaming folders on the NAS.
    for value in ("", "1", "yes", "on", "TRUE ish", "  "):
        assert m.parse_apply_flag(value) is False, value


def test_apply_flag_tolerates_surrounding_whitespace():
    assert m.parse_apply_flag("  true\n") is True


# --- compute_expected_folder ----------------------------------------------

def series(**over):
    s = {
        "id": 1,
        "title": "Alpha: Rising",
        "year": 2019,
        "tvdbId": 111,
        "tvMazeId": 7,
        "imdbId": "tt1",
        "tmdbId": 9,
        "path": "/tv/Alpha- Rising (2019)",
        "rootFolderPath": "/tv/",
    }
    s.update(over)
    return s


def test_title_year_and_tvdbid_are_both_substituted():
    got = m.compute_expected_folder(series(), "{Series TitleYear} [tvdbid-{TvdbId}]")
    assert got == "Alpha - Rising (2019) [tvdbid-111]"


def test_the_bare_title_token_does_not_eat_the_titleyear_token():
    # {Series Title} is replaced before {Series TitleYear}. That is only safe
    # because the shorter token requires its own closing brace, so it is not a
    # prefix of the longer one. Pinned here because the ordering is not
    # obviously safe on reading, and reordering the replaces would break it.
    got = m.compute_expected_folder(series(), "{Series TitleYear}")
    assert got == "Alpha - Rising (2019)"


def test_the_bare_title_token_does_not_eat_the_cleantitle_token():
    got = m.compute_expected_folder(series(), "{Series CleanTitle}")
    assert got == "Alpha Rising"


def test_clean_title_strips_punctuation_but_keeps_spacing():
    got = m.compute_expected_folder(series(title="Zeta!! & Co."), "{Series CleanTitle}")
    assert got == "Zeta  Co"


def test_first_character_token_is_uppercased():
    got = m.compute_expected_folder(series(title="alpha"), "{Series TitleFirstCharacter}")
    assert got == "A"


def test_first_character_token_survives_an_empty_title():
    got = m.compute_expected_folder(series(title=""), "{Series TitleFirstCharacter}")
    assert got == ""


def test_a_null_imdbid_renders_empty_rather_than_the_string_none():
    got = m.compute_expected_folder(series(imdbId=None), "{ImdbId}")
    assert got == ""


def test_missing_optional_ids_fall_back_to_zero():
    s = series()
    del s["tvMazeId"]
    del s["tmdbId"]
    assert m.compute_expected_folder(s, "{TvMazeId}/{TmdbId}") == "0/0"


def test_colon_format_zero_deletes_the_colon():
    got = m.compute_expected_folder(series(), "{Series Title}", colon_fmt=0)
    assert got == "Alpha Rising"


def test_colon_formats_one_and_four_and_the_fallback_all_dash():
    for fmt in (1, 4, 99):
        got = m.compute_expected_folder(series(), "{Series Title}", colon_fmt=fmt)
        assert got == "Alpha - Rising", fmt


def test_colon_format_defaults_to_four_when_not_passed():
    # The heredoc read this from an enclosing global; the default keeps every
    # existing caller's behaviour when Sonarr does not report the field.
    assert m.compute_expected_folder(series(), "{Series Title}") == "Alpha - Rising"


# --- plan_rename ----------------------------------------------------------

def test_plan_is_none_when_the_series_is_already_correct():
    s = series(path="/tv/Alpha - Rising (2019)")
    assert m.plan_rename(s, "{Series TitleYear}", 4) is None


def test_plan_reports_the_current_folder_relative_to_the_root():
    s = series(path="/tv/Alpha- Rising (2019)")
    current, expected_path, expected_folder = m.plan_rename(s, "{Series TitleYear}", 4)
    assert current == "Alpha- Rising (2019)"
    assert expected_path == "/tv/Alpha - Rising (2019)"
    assert expected_folder == "Alpha - Rising (2019)"


def test_plan_does_not_double_the_separator_for_a_root_with_a_trailing_slash():
    s = series(rootFolderPath="/tv/", path="/tv/x")
    _, expected_path, _ = m.plan_rename(s, "{Series TitleYear}", 4)
    assert "//" not in expected_path


# --- run ------------------------------------------------------------------

class FakeApi:
    def __init__(self, series_list, naming=None):
        self.series_list = series_list
        self.naming = naming if naming is not None else {
            "seriesFolderFormat": "{Series TitleYear}",
            "colonReplacementFormat": 4,
        }
        self.puts = []

    def get(self, path):
        if path.startswith("/api/v3/config/naming"):
            return self.naming
        return self.series_list

    def put(self, path, data, move_files=False):
        self.puts.append((path, data["path"], move_files))
        return {"ok": True}


def test_a_dry_run_never_issues_a_write():
    api = FakeApi([series(path="/tv/wrong")])
    renamed, ok, errors = m.run(api, apply_changes=False, out=lambda *_: None)
    assert api.puts == []
    assert (renamed, ok, errors) == (1, 0, 0)


def test_apply_issues_a_move_files_put_with_the_new_path():
    api = FakeApi([series(path="/tv/wrong")])
    renamed, ok, errors = m.run(api, apply_changes=True, out=lambda *_: None)
    assert api.puts == [("/api/v3/series/1", "/tv/Alpha - Rising (2019)", True)]
    assert (renamed, ok, errors) == (1, 0, 0)


def test_a_correct_series_is_counted_not_written():
    api = FakeApi([series(path="/tv/Alpha - Rising (2019)")])
    renamed, ok, errors = m.run(api, apply_changes=True, out=lambda *_: None)
    assert api.puts == []
    assert (renamed, ok, errors) == (0, 1, 0)


def test_an_http_error_is_counted_and_does_not_abort_the_rest():
    import urllib.error

    class Failing(FakeApi):
        def put(self, path, data, move_files=False):
            if data["path"].startswith("/tv/Alpha"):
                raise urllib.error.HTTPError(path, 409, "conflict", None, None)
            return super().put(path, data, move_files)

    api = Failing([series(path="/tv/wrong"),
                   series(id=2, title="Zeta", tvdbId=333, path="/tv/also-wrong")])
    renamed, ok, errors = m.run(api, apply_changes=True, out=lambda *_: None)
    assert errors == 1
    assert renamed == 1, "a failure on one series must not skip the next"


def test_the_dry_run_summary_says_it_is_a_dry_run():
    lines = []
    m.run(FakeApi([series(path="/tv/wrong")]), apply_changes=False, out=lines.append)
    assert any("dry run" in line for line in lines)
    assert not any("Renaming:" in line for line in lines)


def test_series_are_processed_in_title_order():
    api = FakeApi([
        series(id=2, title="Zeta", tvdbId=2, path="/tv/z-wrong"),
        series(id=1, title="Alpha", tvdbId=1, path="/tv/a-wrong"),
    ])
    m.run(api, apply_changes=True, out=lambda *_: None)
    assert [p[0] for p in api.puts] == ["/api/v3/series/1", "/api/v3/series/2"]
