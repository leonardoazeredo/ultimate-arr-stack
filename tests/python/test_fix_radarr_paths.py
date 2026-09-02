"""Behavioural tests for scripts/lib/fix_radarr_paths.py.

The three-tier match cascade here is the densest logic in the repo's Python and
had no test of any kind while it lived in a heredoc. Every tier is exercised
separately, and so is the boundary between them -- a looser tier must only be
consulted after a stricter one has failed.
"""

import json
import os
import subprocess
import sys

import fix_radarr_paths as m


# --- normalisation --------------------------------------------------------

def test_strip_accents_folds_to_ascii():
    assert m.strip_accents("Amélie") == "Amelie"
    assert m.strip_accents("Kōkaku") == "Kokaku"


def test_strip_accents_leaves_unaccented_text_alone():
    assert m.strip_accents("The Matrix (1999)") == "The Matrix (1999)"


def test_normalize_drops_everything_but_lowercase_alphanumerics():
    assert m.normalize("The Matrix (1999)") == "thematrix1999"
    assert m.normalize("Amélie (2001)") == "amelie2001"


def test_normalize_no_articles_strips_a_leading_article():
    assert m.normalize_no_articles("The Matrix") == "matrix"
    assert m.normalize_no_articles("A Ghost Story") == "ghoststory"
    assert m.normalize_no_articles("An Education") == "education"


def test_normalize_no_articles_strips_a_trailing_article_with_or_without_comma():
    assert m.normalize_no_articles("Matrix, The") == "matrix"
    assert m.normalize_no_articles("Matrix The") == "matrix"


def test_normalize_no_articles_does_not_eat_an_article_inside_a_word():
    # "Theatre" starts with "the" but is not an article. The regex requires
    # whitespace after it, which is the only thing keeping this correct.
    assert m.normalize_no_articles("Theatre of Blood") == "theatreofblood"


def test_strip_year_removes_only_a_trailing_parenthesised_year():
    assert m.strip_year("The Matrix (1999)") == "The Matrix"
    assert m.strip_year("2012 (2009)") == "2012"
    assert m.strip_year("Blade Runner 2049") == "Blade Runner 2049"


# --- find_match: the cascade ---------------------------------------------

def test_tier_one_matches_on_normalisation_alone():
    assert m.find_match("Amelie (2001)", "2001", {"Amélie (2001)"}) == "Amélie (2001)"


def test_tier_two_matches_across_a_moved_article():
    assert m.find_match("Matrix, The (1999)", "1999",
                        {"The Matrix (1999)"}) == "The Matrix (1999)"


def test_tier_three_matches_when_only_one_side_carries_the_year():
    assert m.find_match("The Matrix (1999)", "1999",
                        {"Matrix (1999)"}) == "Matrix (1999)"


def test_no_match_returns_none_rather_than_a_guess():
    assert m.find_match("Solaris (1972)", "1972", {"Stalker (1972)"}) is None


def test_candidates_are_restricted_to_the_movies_own_year():
    # The loosest tier compares titles with the year stripped, so without the
    # year filter a 2010 remake would match the 1970 original.
    assert m.find_match("Alpha (2010)", "2010", {"Alpha (1970)"}) is None


def test_an_exact_match_wins_over_a_looser_one():
    disk = {"The Alpha (1999)", "Alpha (1999)"}
    assert m.find_match("Alpha (1999)", "1999", disk) == "Alpha (1999)"


def test_an_empty_disk_listing_matches_nothing():
    assert m.find_match("Alpha (1999)", "1999", set()) is None


# --- run ------------------------------------------------------------------

def collect():
    """An updater that records rather than acting, plus its call log."""
    calls = []

    def update(movie):
        calls.append((movie["id"], movie["path"]))
        return "200"
    return update, calls


def test_a_movie_already_on_disk_is_never_updated():
    update, calls = collect()
    counts = m.run([{"id": 1, "path": "/x/Alpha (1999)", "year": 1999}],
                   {"Alpha (1999)"}, update, out=lambda *_: None)
    assert calls == []
    assert counts == (0, 1, 0, 0)


def test_a_movie_with_a_file_is_left_alone_even_if_the_path_looks_wrong():
    # hasFile means Radarr has already reconciled it; repointing the path would
    # move a working entry.
    update, calls = collect()
    counts = m.run([{"id": 1, "path": "/x/Alfa (1999)", "year": 1999, "hasFile": True}],
                   {"Alpha (1999)"}, update, out=lambda *_: None)
    assert calls == []
    assert counts == (0, 1, 0, 0)


def test_a_matched_movie_is_repointed_under_the_media_root():
    update, calls = collect()
    counts = m.run([{"id": 7, "path": "/x/Amelie (2001)", "year": 2001}],
                   {"Amélie (2001)"}, update, out=lambda *_: None)
    assert calls == [(7, "/data/media/movies/Amélie (2001)")]
    assert counts == (1, 0, 0, 0)


def test_an_unmatched_movie_is_counted_and_not_updated():
    update, calls = collect()
    counts = m.run([{"id": 1, "path": "/x/Solaris (1972)", "year": 1972}],
                   {"Stalker (1972)"}, update, out=lambda *_: None)
    assert calls == []
    assert counts == (0, 0, 1, 0)


def test_a_rejected_update_is_counted_and_reported_rather_than_silent():
    # The heredoc version counted three outcomes and a rejected PUT was none of
    # them, so a run that fixed nothing and failed repeatedly still printed
    # "0 fixed" with no other signal.
    lines = []
    counts = m.run([{"id": 1, "path": "/x/Amelie (2001)", "year": 2001}],
                   {"Amélie (2001)"}, lambda mv: "500", out=lines.append)
    assert counts == (0, 0, 0, 1)
    assert any("FAILED (500)" in line for line in lines)
    assert any("rejected by Radarr" in line for line in lines)


def test_the_summary_line_keeps_its_original_wording():
    lines = []
    m.run([{"id": 1, "path": "/x/Alpha (1999)", "year": 1999}],
          {"Alpha (1999)"}, lambda mv: "200", out=lines.append)
    assert "Summary: 0 fixed, 1 already correct, 0 no match on disk" in lines


def test_no_rejection_line_is_printed_when_nothing_was_rejected():
    lines = []
    m.run([{"id": 1, "path": "/x/Alpha (1999)", "year": 1999}],
          {"Alpha (1999)"}, lambda mv: "200", out=lines.append)
    assert not any("rejected" in line for line in lines)


def test_a_202_is_accepted_as_success_alongside_200():
    counts = m.run([{"id": 1, "path": "/x/Amelie (2001)", "year": 2001}],
                   {"Amélie (2001)"}, lambda mv: "202", out=lambda *_: None)
    assert counts[0] == 1


def test_an_empty_curl_response_is_a_failure_not_a_success():
    # curl prints nothing when it cannot connect at all; the code path must not
    # read that as a successful update.
    counts = m.run([{"id": 1, "path": "/x/Amelie (2001)", "year": 2001}],
                   {"Amélie (2001)"}, lambda mv: "", out=lambda *_: None)
    assert counts == (0, 0, 0, 1)


def test_a_movie_with_no_path_key_does_not_crash():
    counts = m.run([{"id": 1, "year": 1999}], {"Alpha (1999)"},
                   lambda mv: "200", out=lambda *_: None)
    assert counts == (0, 0, 1, 0)


# --- tier ordering, pinned by result rather than by count -----------------
#
# The cascade's three tiers get looser in order, so a case that a stricter tier
# matches is nearly always matched by a looser one too -- which means deleting a
# tier changes nothing observable unless the looser tier would pick a DIFFERENT
# candidate. Both tests below are built that way, and both pass a list rather
# than a set: `candidates` preserves input order, so with a set the expected
# answer would depend on hash ordering and the test would be flaky by
# construction.

def test_tier_one_is_consulted_before_tier_two_and_wins():
    # Tier 1 matches "The Matrix (1999)" exactly. Tier 2 strips the article and
    # would match "Matrix (1999)" first, so if tier 1 stops being consulted the
    # answer changes to the wrong folder.
    got = m.find_match("The Matrix (1999)", "1999",
                       ["Matrix (1999)", "The Matrix (1999)"])
    assert got == "The Matrix (1999)"


def test_tier_two_is_consulted_before_tier_three_and_wins():
    # Tier 1 matches neither. Tier 2 matches "Matrix (1999)". Tier 3 also drops
    # the year, which lets the comma-inverted "Matrix, The (1999)" match first
    # -- so losing tier 2 silently repoints the movie at the other folder.
    got = m.find_match("The Matrix (1999)", "1999",
                       ["Matrix, The (1999)", "Matrix (1999)"])
    assert got == "Matrix (1999)"


# --- the loop's skip paths ------------------------------------------------
#
# Every `continue` in run() is one `break` away from abandoning the rest of the
# library. The counts alone cannot see that: what distinguishes them is that a
# movie AFTER the skipped one still gets processed.

def test_a_movie_already_on_disk_does_not_stop_the_ones_after_it():
    update, calls = collect()
    fixed, already_ok, no_match, failed = m.run(
        [{"id": 1, "path": "/x/Alpha (1999)", "year": 1999},
         {"id": 2, "path": "/x/Beta (1999)", "year": 1999}],
        {"Alpha (1999)", "Beta (1999)"}, update, out=lambda *a: None)
    assert (already_ok, len(calls)) == (2, 0)


def test_a_movie_with_a_file_does_not_stop_the_ones_after_it():
    update, calls = collect()
    fixed, already_ok, no_match, failed = m.run(
        [{"id": 1, "path": "/x/Alpha", "year": 1999, "hasFile": True},
         {"id": 2, "path": "/x/Beta", "year": 1999}],
        {"Beta (1999)"}, update, out=lambda *a: None)
    assert (fixed, already_ok) == (1, 1)
    assert calls == [(2, "/data/media/movies/Beta (1999)")]


def test_an_unmatched_movie_does_not_stop_the_ones_after_it():
    update, calls = collect()
    fixed, already_ok, no_match, failed = m.run(
        [{"id": 1, "path": "/x/Nothing Like It", "year": 1999},
         {"id": 2, "path": "/x/Beta", "year": 1999}],
        {"Beta (1999)"}, update, out=lambda *a: None)
    assert (fixed, no_match) == (1, 1)
    assert calls == [(2, "/data/media/movies/Beta (1999)")]


def test_a_fix_is_reported_by_name_not_only_counted():
    update, _ = collect()
    lines = []
    m.run([{"id": 2, "path": "/x/Beta", "year": 1999}],
          {"Beta (1999)"}, update, out=lines.append)
    assert "  Fixed: Beta -> Beta (1999)" in lines


def test_a_blank_line_separates_the_per_movie_output_from_the_summary():
    update, _ = collect()
    lines = []
    m.run([{"id": 2, "path": "/x/Beta", "year": 1999}],
          {"Beta (1999)"}, update, out=lines.append)
    assert lines[-2] == ""


# --- curl_updater: the real side effect -----------------------------------
#
# Every test above injects an updater, so until these the actual subprocess
# call -- the PUT that moves a movie in Radarr -- was never looked at once.
# Nothing here forks curl: subprocess.run is replaced in the module's own
# namespace.

class FakeRun:
    def __init__(self, stdout="200"):
        self.stdout = stdout
        self.calls = []

    def __call__(self, argv, **kwargs):
        self.calls.append((argv, kwargs))

        class R:
            pass
        r = R()
        r.stdout = self.stdout
        return r


def test_curl_updater_returns_a_callable_rather_than_acting_immediately(tmp_path, monkeypatch):
    fake = FakeRun()
    monkeypatch.setattr(m, "subprocess", type("S", (), {"run": fake}))
    update = m.curl_updater(str(tmp_path), "KEY")
    assert callable(update)
    assert fake.calls == []


def test_curl_updater_puts_the_movie_at_its_own_id_with_the_key(tmp_path, monkeypatch):
    fake = FakeRun()
    monkeypatch.setattr(m, "subprocess", type("S", (), {"run": fake}))
    update = m.curl_updater(str(tmp_path), "KEY")
    update({"id": 42, "path": "/data/media/movies/Beta (1999)"})
    argv, kwargs = fake.calls[0]
    assert argv == [
        "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
        "-X", "PUT",
        "http://127.0.0.1:7878/api/v3/movie/42?apikey=KEY",
        "-H", "Content-Type: application/json",
        "-d", "@%s" % os.path.join(str(tmp_path), "update.json"),
    ]
    assert kwargs == {"capture_output": True, "text": True}


def test_curl_updater_writes_the_movie_body_it_points_curl_at(tmp_path, monkeypatch):
    fake = FakeRun()
    monkeypatch.setattr(m, "subprocess", type("S", (), {"run": fake}))
    movie = {"id": 42, "path": "/data/media/movies/Beta (1999)"}
    m.curl_updater(str(tmp_path), "KEY")(movie)
    with open(os.path.join(str(tmp_path), "update.json")) as f:
        assert json.load(f) == movie


def test_curl_updater_returns_the_http_code_curl_printed():
    fake = FakeRun(stdout=" 202\n")
    import types
    mod = types.SimpleNamespace(run=fake)
    old = m.subprocess
    m.subprocess = mod
    try:
        assert m.curl_updater("/tmp", "KEY")({"id": 1}) == "202"
    finally:
        m.subprocess = old


def test_refresh_asks_radarr_to_rescan_with_the_key(monkeypatch):
    fake = FakeRun()
    monkeypatch.setattr(m, "subprocess", type("S", (), {"run": fake}))
    m.refresh("KEY")
    argv, kwargs = fake.calls[0]
    assert argv == [
        "curl", "-s", "-X", "POST",
        "http://127.0.0.1:7878/api/v3/command?apikey=KEY",
        "-H", "Content-Type: application/json",
        "-d", '{"name":"RefreshMovie"}',
    ]
    assert kwargs == {"capture_output": True}


# --- main -----------------------------------------------------------------

def write_inputs(tmp_path, movies, disk_dirs):
    with open(os.path.join(str(tmp_path), "movies.json"), "w") as f:
        json.dump(movies, f)
    with open(os.path.join(str(tmp_path), "disk_dirs.txt"), "w") as f:
        f.write("\n".join(disk_dirs) + "\n")


def test_main_reads_the_key_from_argv1_and_the_tmpdir_from_argv2(tmp_path, monkeypatch, capsys):
    seen = {}
    monkeypatch.setattr(m, "curl_updater",
                        lambda d, k: seen.update(tmpdir=d, key=k) or (lambda mv: "200"))
    monkeypatch.setattr(m, "refresh", lambda k: None)
    write_inputs(tmp_path, [], [])
    assert m.main(["prog", "KEY", str(tmp_path)]) == 0
    assert seen == {"tmpdir": str(tmp_path), "key": "KEY"}


def test_main_triggers_a_refresh_only_when_something_was_fixed(tmp_path, monkeypatch, capsys):
    refreshed = []
    monkeypatch.setattr(m, "curl_updater", lambda d, k: (lambda mv: "200"))
    monkeypatch.setattr(m, "refresh", refreshed.append)
    write_inputs(tmp_path, [{"id": 2, "path": "/x/Beta", "year": 1999}], ["Beta (1999)"])
    m.main(["prog", "KEY", str(tmp_path)])
    out = capsys.readouterr().out
    assert refreshed == ["KEY"]
    assert "Triggering Radarr refresh..." in out
    assert "Wait ~30 seconds" in out


def test_main_says_so_and_skips_the_refresh_when_nothing_was_fixed(tmp_path, monkeypatch, capsys):
    refreshed = []
    monkeypatch.setattr(m, "curl_updater", lambda d, k: (lambda mv: "200"))
    monkeypatch.setattr(m, "refresh", refreshed.append)
    write_inputs(tmp_path, [{"id": 1, "path": "/x/Alpha (1999)", "year": 1999}],
                 ["Alpha (1999)"])
    m.main(["prog", "KEY", str(tmp_path)])
    out = capsys.readouterr().out
    assert refreshed == []
    assert "No fixes needed." in out


def test_main_ignores_blank_lines_in_the_disk_listing(tmp_path, monkeypatch):
    monkeypatch.setattr(m, "curl_updater", lambda d, k: (lambda mv: "200"))
    monkeypatch.setattr(m, "refresh", lambda k: None)
    with open(os.path.join(str(tmp_path), "movies.json"), "w") as f:
        json.dump([{"id": 2, "path": "/x/Beta", "year": 1999}], f)
    with open(os.path.join(str(tmp_path), "disk_dirs.txt"), "w") as f:
        f.write("\n  \nBeta (1999)\n\n")
    assert m.main(["prog", "KEY", str(tmp_path)]) == 0


def test_the_module_actually_runs_when_executed_as_a_script(tmp_path):
    # The `sys.exit(main(sys.argv))` line is only reached by running the file,
    # so no import-based test can see it -- and with it gone the script exits 0
    # having done nothing, which is indistinguishable from a clean run. An empty
    # library is used deliberately: nothing matches, so main() never builds an
    # updater that could fork a real curl at a real Radarr.
    write_inputs(tmp_path, [], [])
    r = subprocess.run(
        [sys.executable, os.path.join(os.path.dirname(m.__file__),
                                      "fix_radarr_paths.py"),
         "KEY", str(tmp_path)],
        capture_output=True, text=True)
    assert r.returncode == 0
    assert "No fixes needed." in r.stdout
