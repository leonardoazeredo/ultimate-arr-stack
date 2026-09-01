"""Behavioural tests for scripts/lib/fix_radarr_paths.py.

The three-tier match cascade here is the densest logic in the repo's Python and
had no test of any kind while it lived in a heredoc. Every tier is exercised
separately, and so is the boundary between them -- a looser tier must only be
consulted after a stricter one has failed.
"""

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
