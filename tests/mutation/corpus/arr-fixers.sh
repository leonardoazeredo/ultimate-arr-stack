# shellcheck shell=bash
# Corpus: scripts/queue-cleanup.sh, scripts/fix-*.sh and the three Python
# modules they call.
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
#
# These were heredocs and ad-hoc `.env` greps until 2026-09-01, with no test of
# any kind. Four of the defects catalogued for the coverage plan lived here, and
# every one of them was silent: --apply that renamed nothing, an API key
# truncated at an '=', a dry run that trimmed the log anyway, and a pagination
# loop with no exit. Each entry below reintroduces one and requires the test
# that now covers it to go red.
#
# The Python entries all name the same bats test, because tests/python-suite.bats
# is the bridge that runs pytest -- a failure anywhere under tests/python/ comes
# back through it. The pytest file and function are named in --why instead.

# --- fix_sonarr_folders.py: defect #4 -------------------------------------

mutation apply-argv-case \
  --file scripts/lib/fix_sonarr_folders.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "comparing argv against the literal \"True\" while the bash half writes lowercase \`true\` makes --apply inert: the script takes the dry-run branch, prints 'Would rename', and reports a summary that reads as a result - which is how it shipped (test_apply_flag_accepts_the_spelling_bash_actually_passes)" \
  --apply 'sed -i "s@^    return str(value).strip().lower() == \"true\"\$@    return str(value) == \"True\"@" "$F"'

mutation apply-flag-accepts-anything \
  --file scripts/lib/fix_sonarr_folders.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "a flag parser that answers true for every input turns an unexpected argv value into a live folder rename across the whole library (test_apply_flag_is_false_for_anything_unrecognised)" \
  --apply 'sed -i "s@^    return str(value).strip().lower() == \"true\"\$@    return True@" "$F"'

mutation folder-token-order \
  --file scripts/lib/fix_sonarr_folders.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "substituting {Series TitleYear} after {Series Title} is only safe because the shorter token carries its own closing brace; reordering so the bare title runs against an already-substituted string is the live regression risk in this function (test_the_bare_title_token_does_not_eat_the_titleyear_token)" \
  --apply 'sed -i "s@^    result = result.replace(\"{Series TitleYear}\", \"%s (%d)\" % (title, year))\$@    result = result.replace(\"{Series TitleYear}\", title)@" "$F"'

# --- fix_radarr_paths.py --------------------------------------------------

mutation radarr-match-ignores-year \
  --file scripts/lib/fix_radarr_paths.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "without the year filter the loosest tier compares titles alone, so a remake is repointed at the original's directory and Radarr is told a film lives somewhere it does not (test_candidates_are_restricted_to_the_movies_own_year)" \
  --apply 'sed -i "s@^    candidates = \[d for d in disk_dirs if \"(%s)\" % year in d\]\$@    candidates = list(disk_dirs)@" "$F"'

mutation radarr-updates-a-movie-with-a-file \
  --file scripts/lib/fix_radarr_paths.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "hasFile means Radarr has already reconciled that movie; repointing it moves a working entry, and this guard is the only thing preventing it (test_a_movie_with_a_file_is_left_alone_even_if_the_path_looks_wrong)" \
  --apply 'sed -i "s@^        if m.get(\"hasFile\", False):\$@        if False:@" "$F"'

mutation radarr-rejection-counted-as-success \
  --file scripts/lib/fix_radarr_paths.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "treating any curl response as success counts a rejected PUT as a fix; curl prints nothing at all when it cannot connect, so a totally unreachable Radarr would report a clean run (test_an_empty_curl_response_is_a_failure_not_a_success)" \
  --apply 'sed -i "s@^        if code in (\"200\", \"202\"):\$@        if True:@" "$F"'

# --- queue_cleanup.py: defect #9 and the classifier -----------------------

mutation pagination-unbounded \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "a page cap large enough to never be reached is the same as no cap: a service whose totalRecords grows at least as fast as the pages are consumed loops forever, inside a systemd unit, with no output and no timeout (test_the_default_page_bound_is_not_unlimited)" \
  --apply 'sed -i "s@^MAX_PAGES = 100\$@MAX_PAGES = 10 ** 9@" "$F"'

mutation pagination-empty-page-continues \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "inverting the empty-page guard stops the walk on the first page that HAS records, so the queue is read as empty and nothing is ever cleaned - the polarity of this test is the whole guard (test_a_single_page_queue_makes_exactly_one_request)" \
  --apply 'sed -i "s@^        if not records:\$@        if records:@" "$F"'

mutation pagination-cap-silent \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "a truncation nobody is told about reads as a complete run; the cap must say what it did not examine (test_hitting_the_page_bound_is_reported_rather_than_silent)" \
  --apply 'sed -i "s@^            out(f\"  ! Stopped after {max_pages} pages ({len(all_records)} items);\"\$@            out(f\"\"@" "$F"'

mutation stale-threshold-inverted \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the 24-hour floor is what stops a download that started ten minutes ago being deleted from the client and blocklisted; comparing the wrong way round deletes exactly the healthy ones (test_zero_progress_becomes_stale_only_after_twenty_four_hours)" \
  --apply 'sed -i "0,/^        if age_hours is not None and age_hours > 24:\$/s@^        if age_hours is not None and age_hours > 24:\$@        if age_hours is not None and age_hours < 24:@" "$F"'

mutation error-removal-ignores-warning-status \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "without the warning-status gate any download whose message merely mentions a keyword is removed and blocklisted, including healthy ones (test_error_classification_requires_the_warning_status)" \
  --apply 'sed -i "s@^    if tracked_status == \"warning\":\$@    if True:@" "$F"'

mutation search-payload-shape \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "Radarr's MoviesSearch takes a list and Sonarr's SeriesSearch takes a scalar; posting the wrong shape is rejected, so every removed item is left with no replacement search - the removal still happened (test_radarr_search_takes_a_list_of_ids)" \
  --apply 'sed -i "s@^        return {\"name\": svc\[\"search_cmd\"\], svc\[\"search_key\"\]: \[target_id\]}\$@        return {\"name\": svc[\"search_cmd\"], svc[\"search_key\"]: target_id}@" "$F"'

mutation queue-url-separator \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "appending the apikey with '?' to a path that already has a query string produces a URL with two '?', which the arr APIs answer 404 - reported by the caller as 'Failed to fetch queue' rather than as the malformed URL it is (test_a_path_that_already_has_a_query_gets_an_ampersand)" \
  --apply 'sed -i "s@^    if \"?\" in url:\$@    if False:@" "$F"'

# --- scripts/lib/env-file.sh: defect #7 -----------------------------------

mutation env-value-truncated-at-equals \
  --file scripts/lib/env-file.sh \
  --bats tests/lib-env-file.bats \
  --test "keeps an equals sign in the middle of a value" \
  --why "taking the text after the LAST '=' rather than the first is the same class of bug as the \`cut -d= -f2\` it replaced: a base64 API key ending in '=' padding is silently truncated and the caller authenticates with a fragment" \
  --apply 'sed -i "s@^                value=\${line#\*=}\$@                value=\${line##*=}@" "$F"'

mutation env-quote-strip \
  --file scripts/lib/env-file.sh \
  --bats tests/lib-env-file.bats \
  --test "strips one surrounding pair of double quotes" \
  --why "a quoted value used with its quotes attached is passed straight into an API URL as %22...%22, which fails as a 401 that nothing reports as a configuration problem" \
  --apply 'sed -i "s@^    case \"\$value\" in\$@    case \"\" in@" "$F"'

mutation env-strips-every-quote \
  --file scripts/lib/env-file.sh \
  --bats tests/lib-env-file.bats \
  --test "keeps quotes that are part of the value" \
  --why "the sonarr script's old \`tr -d\` removed every quote anywhere in the value rather than a surrounding pair, silently corrupting any password that legitimately contained one" \
  --apply 'sed -i "s@^    case \"\$value\" in\$@    value=\$(printf %s \"\$value\" | tr -d \"\\\"\"); case \"\$value\" in@" "$F"'

mutation env-key-matched-as-prefix \
  --file scripts/lib/env-file.sh \
  --bats tests/lib-env-file.bats \
  --test "a key is not matched as a suffix of another" \
  --why "matching the key anywhere in the line rather than anchored at its start answers a request for KEY with OLD_KEY's value - a stale credential returned as if it were the live one" \
  --apply 'sed -i "s@^            \"\${key}=\"\*)\$@            *\"\${key}=\"*)@" "$F"'

# --- scripts/queue-cleanup.sh: defect #8 ----------------------------------

mutation log-trim-ignores-dry-run \
  --file scripts/queue-cleanup.sh \
  --bats tests/queue-cleanup.bats \
  --test "a dry run does not trim the log" \
  --why "trimming the log outside --apply makes it the one thing a dry run changes on disk, and what it discards is the operator's record of previous runs - the thing they are reading when they dry-run to decide whether to apply" \
  --apply 'sed -i "s@^if \$APPLY && \[\[ -f \"\$LOG_FILE\" \]\]; then\$@if [[ -f \"\$LOG_FILE\" ]]; then@" "$F"'

mutation log-trim-temp-leaks \
  --file scripts/queue-cleanup.sh \
  --bats tests/queue-cleanup.bats \
  --test "a failing trim leaves neither a temp file nor a truncated log" \
  --why "mktemp with no trap leaks a file on every failed trim, forever, in a directory nobody watches" \
  --apply 'sed -i "s@^    trap .rm -f \"\$TMPLOG\". EXIT\$@    :@" "$F"'

mutation log-trim-temp-in-tmp \
  --file scripts/queue-cleanup.sh \
  --bats tests/queue-cleanup.bats \
  --test "the temp file is created beside the log, not in /tmp" \
  --why "a bare mktemp puts the temp in /tmp, a different filesystem from the log on the NAS, which turns the mv below it into a copy-then-unlink that can leave the log half-written rather than the atomic rename it reads as" \
  --apply 'sed -i "s@^    TMPLOG=\$(mktemp \"\${LOG_FILE}.XXXXXX\")\$@    TMPLOG=\$(mktemp)@" "$F"'

mutation queue-python-failure-ignored \
  --file scripts/queue-cleanup.sh \
  --bats tests/queue-cleanup.bats \
  --test "a failing Python half is fatal and says so" \
  --why "the heredoc form inherited set -e; the extracted form is a subprocess, so without an explicit status check a Python half that died reads as a clean run and the webhook announces a cleanup that never happened" \
  --apply 'sed -i "s@^if ! python3 \"\${SCRIPT_DIR}/lib/queue_cleanup.py\" \\\\\$@if false; then :; elif false; then@" "$F"'

# --- scripts/fix-*.sh -----------------------------------------------------

mutation sonarr-apply-flag-not-passed \
  --file scripts/fix-sonarr-folders.sh \
  --bats tests/fix-arr-paths.bats \
  --test "--apply passes the lowercase true the Python half expects" \
  --why "an --apply that never reaches the Python half is defect #4 by another route: the operator is told 'Mode: APPLYING CHANGES' and nothing is renamed" \
  --apply 'sed -i "s@^  APPLY=true\$@  APPLY=false@" "$F"'

mutation radarr-tmpdir-not-cleaned \
  --file scripts/fix-radarr-paths.sh \
  --bats tests/fix-arr-paths.bats \
  --test "the temp directory is removed even when the fixer fails" \
  --why "the temp dir holds a full dump of the Radarr library including the API key in no file the user chose; without the EXIT trap it survives every failed run" \
  --apply 'sed -i "s@^trap .rm -rf \"\$TMPDIR\". EXIT\$@:@" "$F"'
