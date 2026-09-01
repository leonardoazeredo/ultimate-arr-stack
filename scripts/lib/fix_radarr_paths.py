import json, os, re, sys, subprocess

KEY = sys.argv[1]
TMPDIR = sys.argv[2]

with open(os.path.join(TMPDIR, "movies.json")) as f:
    movies = json.load(f)

with open(os.path.join(TMPDIR, "disk_dirs.txt")) as f:
    disk_dirs = set(line.strip() for line in f if line.strip())

import unicodedata

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

fixed = 0
already_ok = 0
no_match = 0

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
    candidates = [d for d in disk_dirs if "(%s)" % year in d]

    match = None

    # Exact normalized match
    norm_dirname = normalize(dirname)
    for c in candidates:
        if normalize(c) == norm_dirname:
            match = c
            break

    # Article-agnostic match
    if not match:
        norm_no_art = normalize_no_articles(dirname)
        for c in candidates:
            if normalize_no_articles(c) == norm_no_art:
                match = c
                break

    # Title-only match (strip year)
    if not match:
        title_part = re.sub(r"\s*\(\d{4}\)\s*$", "", dirname)
        norm_title = normalize_no_articles(title_part)
        for c in candidates:
            c_title = re.sub(r"\s*\(\d{4}\)\s*$", "", c)
            if normalize_no_articles(c_title) == norm_title:
                match = c
                break

    if match:
        new_path = "/data/media/movies/%s" % match
        m["path"] = new_path

        update_file = os.path.join(TMPDIR, "update.json")
        with open(update_file, "w") as f:
            json.dump(m, f)

        result = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
             "-X", "PUT",
             "http://127.0.0.1:7878/api/v3/movie/%s?apikey=%s" % (m["id"], KEY),
             "-H", "Content-Type: application/json",
             "-d", "@%s" % update_file],
            capture_output=True, text=True
        )
        code = result.stdout.strip()
        if code in ("200", "202"):
            print("  Fixed: %s -> %s" % (dirname, match))
            fixed += 1
        else:
            print("  FAILED (%s): %s -> %s" % (code, dirname, match))
    else:
        no_match += 1

print("")
print("Summary: %d fixed, %d already correct, %d no match on disk" % (fixed, already_ok, no_match))

if fixed > 0:
    print("")
    print("Triggering Radarr refresh...")
    subprocess.run(
        ["curl", "-s", "-X", "POST",
         "http://127.0.0.1:7878/api/v3/command?apikey=%s" % KEY,
         "-H", "Content-Type: application/json",
         "-d", '{"name":"RefreshMovie"}'],
        capture_output=True
    )
    print("Done. Wait ~30 seconds for Radarr to rescan, then check the Health page.")
else:
    print("No fixes needed.")
