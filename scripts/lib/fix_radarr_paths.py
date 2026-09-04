"""Repoint Radarr movie paths at the directories that actually exist on disk.

Invoked by scripts/fix-radarr-paths.sh; see that file for the why. This was a
heredoc until 2026-09-01, which is why the structure reads as a script that
grew a main() rather than a module designed as one -- the matching cascade is
lifted out so it can be imported and tested, and the HTTP call is injected so a
test can never reach a live Radarr.
"""

import json
import os
import re
import subprocess
import sys
import unicodedata

MOVIE_ROOT = "/data/media/movies"


def strip_accents(s):
    """Convert accented chars to ASCII (e.g., ā → a, é → e)."""
    return "".join(
        c for c in unicodedata.normalize("NFD", s)
        if unicodedata.category(c) != "Mn"
    )


def normalize(s):
    return re.sub(r"[^a-z0-9]", "", strip_accents(s).lower())


def normalize_no_articles(s):
    s = re.sub(r"[^a-z0-9 ]", "", strip_accents(s).lower()).strip()
    s = re.sub(r"^(the|a|an)\s+", "", s)
    s = re.sub(r",?\s*(the|a|an)$", "", s)
    return re.sub(r"\s+", "", s)


def strip_year(name):
    return re.sub(r"\s*\(\d{4}\)\s*$", "", name)


def find_match(dirname, year, disk_dirs):
    """Three-tier cascade, tried in order and stopping at the first hit.

    The tiers are deliberately ordered from strictest to loosest: an exact
    normalised match, then one that ignores leading/trailing articles, then one
    that also drops the year suffix from both sides. Candidates are always
    restricted to directories carrying the movie's year, so the loosest tier
    still cannot match a different film with the same title.
    """
    candidates = [d for d in disk_dirs if "(%s)" % year in d]

    norm_dirname = normalize(dirname)
    for c in candidates:
        if normalize(c) == norm_dirname:
            return c

    norm_no_art = normalize_no_articles(dirname)
    for c in candidates:
        if normalize_no_articles(c) == norm_no_art:
            return c

    norm_title = normalize_no_articles(strip_year(dirname))
    for c in candidates:
        if normalize_no_articles(strip_year(c)) == norm_title:
            return c

    return None


def curl_updater(tmpdir, key, url):
    """The real side effect, kept behind a seam so a test never forks curl."""
    def update(movie):
        update_file = os.path.join(tmpdir, "update.json")
        with open(update_file, "w") as f:
            json.dump(movie, f)
        result = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
             "-X", "PUT",
             "%s/api/v3/movie/%s?apikey=%s" % (url, movie["id"], key),
             "-H", "Content-Type: application/json",
             "-d", "@%s" % update_file],
            capture_output=True, text=True
        )
        return result.stdout.strip()
    return update


def refresh(key, url):
    subprocess.run(
        ["curl", "-s", "-X", "POST",
         "%s/api/v3/command?apikey=%s" % (url, key),
         "-H", "Content-Type: application/json",
         "-d", '{"name":"RefreshMovie"}'],
        capture_output=True
    )


def run(movies, disk_dirs, update, out=print):
    fixed = 0
    already_ok = 0
    no_match = 0
    failed = 0

    for m in movies:
        path = m.get("path", "")
        dirname = os.path.basename(path)

        if dirname in disk_dirs:
            already_ok += 1
            continue

        if m.get("hasFile", False):
            already_ok += 1
            continue

        year = str(m.get("year", ""))
        match = find_match(dirname, year, disk_dirs)

        if not match:
            no_match += 1
            continue

        m["path"] = "%s/%s" % (MOVIE_ROOT, match)
        code = update(m)
        if code in ("200", "202"):
            out("  Fixed: %s -> %s" % (dirname, match))
            fixed += 1
        else:
            out("  FAILED (%s): %s -> %s" % (code, dirname, match))
            failed += 1

    out("")
    out("Summary: %d fixed, %d already correct, %d no match on disk"
        % (fixed, already_ok, no_match))
    # The summary line above is unchanged from the heredoc version, which
    # counted only three outcomes -- a movie whose PUT was rejected appeared in
    # none of them, so a run that fixed nothing and failed forty times read as
    # "0 fixed". The count is additive rather than folded into that line so
    # nothing reading the old wording breaks.
    if failed:
        out("         %d update(s) were rejected by Radarr — see the FAILED lines above."
            % failed)
    return fixed, already_ok, no_match, failed


def main(argv):
    key = argv[1]
    tmpdir = argv[2]
    url = argv[3]

    with open(os.path.join(tmpdir, "movies.json")) as f:
        movies = json.load(f)

    with open(os.path.join(tmpdir, "disk_dirs.txt")) as f:
        disk_dirs = set(line.strip() for line in f if line.strip())

    fixed, _, _, _ = run(movies, disk_dirs, curl_updater(tmpdir, key, url))

    if fixed > 0:
        print("")
        print("Triggering Radarr refresh...")
        refresh(key, url)
        print("Done. Wait ~30 seconds for Radarr to rescan, then check the Health page.")
    else:
        print("No fixes needed.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
