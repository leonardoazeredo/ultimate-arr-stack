import json, sys, re, urllib.request, urllib.error

KEY = sys.argv[1]
URL = sys.argv[2]
APPLY = sys.argv[3] == "True"

def api_get(path):
    req = urllib.request.Request(
        "%s%s" % (URL, path),
        headers={"X-Api-Key": KEY}
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())

def api_put(path, data, move_files=False):
    url = "%s%s" % (URL, path)
    if move_files:
        url += "?moveFiles=true"
    body = json.dumps(data).encode()
    req = urllib.request.Request(
        url, data=body, method="PUT",
        headers={"X-Api-Key": KEY, "Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())

# Get naming config
naming = api_get("/api/v3/config/naming")
folder_format = naming.get("seriesFolderFormat", "{Series TitleYear}")
print("Configured folder format: %s" % folder_format)
print("")

# Get all series
series_list = api_get("/api/v3/series")

def compute_expected_folder(s, fmt):
    """Compute expected folder name from Sonarr's folder format tokens."""
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

    # Handle tvdbid- pattern (lowercased token name in brackets)
    result = result.replace("[tvdbid-{TvdbId}]", "[tvdbid-%d]" % tvdbid)

    # Apply colon replacement (Sonarr default: dash)
    colon_fmt = naming.get("colonReplacementFormat", 4)
    if colon_fmt == 0:  # delete
        result = result.replace(":", "")
    elif colon_fmt == 1:  # replace with space-dash-space
        result = result.replace(":", " -")
    elif colon_fmt == 4:  # replace with space-dash-space (smart)
        result = result.replace(":", " -")
    else:
        result = result.replace(":", " -")

    return result

renamed = 0
already_ok = 0
errors = 0

for s in sorted(series_list, key=lambda x: x["title"]):
    current_path = s["path"]
    root_folder = s["rootFolderPath"]
    current_folder = current_path.replace(root_folder, "").strip("/")

    expected_folder = compute_expected_folder(s, folder_format)
    expected_path = "%s/%s" % (root_folder.rstrip("/"), expected_folder)

    if current_path == expected_path:
        already_ok += 1
        continue

    if APPLY:
        print("  Renaming: %s" % current_folder)
        print("        ->  %s" % expected_folder)
        try:
            s["path"] = expected_path
            api_put("/api/v3/series/%d" % s["id"], s, move_files=True)
            renamed += 1
        except urllib.error.HTTPError as e:
            print("    FAILED: HTTP %d" % e.code)
            errors += 1
    else:
        print("  Would rename: %s" % current_folder)
        print("           ->   %s" % expected_folder)
        renamed += 1

print("")
if APPLY:
    print("Summary: %d renamed, %d already correct, %d errors" % (renamed, already_ok, errors))
else:
    print("Summary: %d to rename, %d already correct (dry run — use --apply to rename)" % (renamed, already_ok))
