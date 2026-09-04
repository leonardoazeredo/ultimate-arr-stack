"""Rename Sonarr series folders to match the configured seriesFolderFormat.

Invoked by scripts/fix-sonarr-folders.sh; see that file for the why. This half
was a heredoc until 2026-09-01, which is why the structure below looks like a
script that grew a main() rather than a module that was designed as one -- the
pure parts are lifted out so they can be imported and tested, and the rest is
unchanged.
"""

import json
import re
import sys
import urllib.error
import urllib.request


def parse_apply_flag(value):
    """Read the --apply flag as the bash half actually spells it.

    The heredoc version tested `sys.argv[3] == "True"`, and the bash half sets
    APPLY to `true` or `false` (lowercase -- fix-sonarr-folders.sh:53). So
    --apply was inert: the script always took the dry-run branch, printed
    "Would rename", and reported a summary that read as a plan rather than a
    result. A type mismatch across an argv boundary, which is exactly why the
    boundary was moved with a proof rather than an assurance.

    Both spellings are accepted, because "True" is what the old code wanted and
    accepting it costs nothing; anything else is false, so a future caller that
    passes something unexpected does not silently start renaming folders.
    """
    return str(value).strip().lower() == "true"


def compute_expected_folder(s, fmt, colon_fmt=4):
    """Compute expected folder name from Sonarr's folder format tokens.

    colon_fmt was read from an enclosing global before this was a module. It is
    a parameter now, with the same default the original `naming.get(...)` call
    used, so behaviour is unchanged for every caller that passes what Sonarr
    reported.
    """
    title = s["title"]
    year = s["year"]
    tvdbid = s["tvdbId"]
    clean_title = re.sub(r"[^a-zA-Z0-9 ]", "", title).strip()

    # Replace common Sonarr tokens
    result = fmt
    result = result.replace("{Series Title}", title)
    result = result.replace("{Series CleanTitle}", clean_title)
    result = result.replace("{Series TitleYear}", "%s (%d)" % (title, year))
    result = result.replace("{Series TitleFirstCharacter}", title[0].upper() if title else "")
    result = result.replace("{Series TitleTheYear}", "%s (%d)" % (title, year))
    result = result.replace("{TvdbId}", str(tvdbid))
    result = result.replace("{TvMazeId}", str(s.get("tvMazeId", 0)))
    result = result.replace("{ImdbId}", s.get("imdbId", "") or "")
    result = result.replace("{TmdbId}", str(s.get("tmdbId", 0)))

    # There was a "[tvdbid-{TvdbId}]" replacement here. It was dead: the
    # {TvdbId} substitution above runs first and rewrites the token wherever it
    # appears, brackets included, so this line could never find its pattern. A
    # mutation sweep found it -- deleting the line changed no output any test
    # could see, which for a line that is supposed to do something is the
    # finding, not a gap.

    # Apply colon replacement (Sonarr default: dash)
    if colon_fmt == 0:  # delete
        result = result.replace(":", "")
    elif colon_fmt == 1:  # replace with space-dash-space
        result = result.replace(":", " -")
    elif colon_fmt == 4:  # replace with space-dash-space (smart)
        result = result.replace(":", " -")
    else:
        result = result.replace(":", " -")

    return result


class SonarrApi:
    def __init__(self, url, key):
        self.url = url
        self.key = key

    def get(self, path):
        req = urllib.request.Request(
            "%s%s" % (self.url, path),
            headers={"X-Api-Key": self.key},
        )
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())

    def put(self, path, data, move_files=False):
        url = "%s%s" % (self.url, path)
        if move_files:
            url += "?moveFiles=true"
        body = json.dumps(data).encode()
        req = urllib.request.Request(
            url, data=body, method="PUT",
            headers={"X-Api-Key": self.key, "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())


def plan_rename(s, folder_format, colon_fmt):
    """Return (current_folder, expected_path, expected_folder), or None if the
    series is already where it belongs."""
    current_path = s["path"]
    root_folder = s["rootFolderPath"]
    current_folder = current_path.replace(root_folder, "").strip("/")

    expected_folder = compute_expected_folder(s, folder_format, colon_fmt)
    expected_path = "%s/%s" % (root_folder.rstrip("/"), expected_folder)

    if current_path == expected_path:
        return None
    return current_folder, expected_path, expected_folder


def run(api, apply_changes, out=print):
    naming = api.get("/api/v3/config/naming")
    folder_format = naming.get("seriesFolderFormat", "{Series TitleYear}")
    colon_fmt = naming.get("colonReplacementFormat", 4)
    out("Configured folder format: %s" % folder_format)
    out("")

    series_list = api.get("/api/v3/series")

    renamed = 0
    already_ok = 0
    errors = 0

    for s in sorted(series_list, key=lambda x: x["title"]):
        plan = plan_rename(s, folder_format, colon_fmt)
        if plan is None:
            already_ok += 1
            continue
        current_folder, expected_path, expected_folder = plan

        if apply_changes:
            out("  Renaming: %s" % current_folder)
            out("        ->  %s" % expected_folder)
            try:
                s["path"] = expected_path
                api.put("/api/v3/series/%d" % s["id"], s, move_files=True)
                renamed += 1
            except urllib.error.HTTPError as e:
                out("    FAILED: HTTP %d" % e.code)
                errors += 1
        else:
            out("  Would rename: %s" % current_folder)
            out("           ->   %s" % expected_folder)
            renamed += 1

    out("")
    if apply_changes:
        out("Summary: %d renamed, %d already correct, %d errors" % (renamed, already_ok, errors))
    else:
        out("Summary: %d to rename, %d already correct (dry run — use --apply to rename)"
            % (renamed, already_ok))
    return renamed, already_ok, errors


def main(argv):
    key = argv[1]
    url = argv[2]
    apply_changes = parse_apply_flag(argv[3])
    run(SonarrApi(url, key), apply_changes)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
