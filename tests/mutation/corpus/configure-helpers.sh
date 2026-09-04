# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/lib/configure-helpers.sh.
#
# Safe to run: every test in tests/lib-configure-helpers.bats overrides curl
# with a shell function, so no mutation here can reach a network, a container
# or an *arr instance. The PATH harness in tests/helpers/stubs.bash is
# deliberately NOT used - it forbids `-X POST`, which is the exact argv this
# unit exists to build.

mutation http-code-as-exit-status \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: a connection that never completed is a failure, not a success" \
  --why "restores 'return \$code' for non-GET. curl writes 000 to %{http_code} when the connection never completed, and 'return 000' is exit status 0 - so a refused port, a DNS failure or a timeout was reported by configure-apps.sh as a tick against work it never did. The same line turns 404 into 148 and an empty code into a bash runtime error" \
  --apply 'perl -0pi -e "s/(\[verbose\] Response: \\\$body\\\" >&2\n    fi\n)    return 1\n/\$1    if [[ \\\"\\\$method\\\" == \\\"GET\\\" ]]; then return 1; else return \\\"\\\$code\\\"; fi\n/" "$F"'

mutation api-code-sentinel-dropped \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: a connection that never completed is recorded as 000" \
  --why "drops the :-000 default, so the two ways curl signals 'I never got a response' - an empty code and the literal 000 - stop reading the same way to a caller inspecting _API_LAST_CODE. An empty code then looks like a code that was simply not checked" \
  --apply 'sed -i "s@_API_LAST_CODE=\"\${code:-000}\"@_API_LAST_CODE=\"\$code\"@" "$F"'

mutation failing-get-leaks-the-error-body \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: a failing GET prints nothing" \
  --why "makes a failing GET print the body. Every GET call site is x=\$(api_get ...) feeding json_extract, so an HTML error page would be captured as if it were the resource - and json_extract swallows its own parse errors, so the caller sees an empty answer rather than a failure" \
  --apply 'perl -0pi -e "s/    if \[\[ \\\"\\\$method\\\" != \\\"GET\\\" \]\]; then\n        echo \\\"\\\$body\\\"\n    fi\n/    echo \\\"\\\$body\\\"\n/" "$F"'

mutation qbit-auth-trusts-the-status-code \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: qbit_auth rejects a 200 whose body is a refusal" \
  --why "drops the body half of the check. qBittorrent answers a WRONG PASSWORD with HTTP 200 and the body 'Fails.', so a status-only check reports a successful login and hands every later call a cookie that authenticates nothing" \
  --apply 'sed -i "s@if \[\[ \"\$http_code\" != \"200\" \]\] || \[\[ \"\$body\" != \"Ok.\" \]\]; then@if [[ \"\$http_code\" != \"200\" ]]; then@" "$F"'

mutation wait-accepts-any-http-code \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: wait_for_service rejects a 404 and gives up at the deadline" \
  --why "treats any answer as 'service is up'. Traefik answers 404 the whole time a backend is still starting, so configure_arr_service would proceed against a container that is mid-migration and write config into a database that is about to be rewritten" \
  --apply 'sed -i "s@if \[\[ \"\$code\" =~ \^\[23\] \]\] || \[\[ \"\$code\" == \"401\" \]\]; then@if [[ -n \"\$code\" ]]; then@" "$F"'

mutation wait-unbounded-per-attempt \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: wait_for_service bounds each attempt, not just the total" \
  --why "removes the per-request timeouts the file's own comment at :79 states as design intent. One hung connection then consumes the entire 180s budget in a single attempt, so the retry loop never retries and the failure message reports 'none' rather than the code the service was actually returning" \
  --apply 'sed -i "s@ --max-time 3 --connect-timeout 2@@" "$F"'

# --- configure_arr_service --------------------------------------------------
# The 250-line half of this file, and the only part of it that writes. Each
# entry below is one section of it losing the check that makes the script's
# "safe to re-run" claim true.

mutation arr-download-client-match-case-sensitive \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: the download-client match is case-insensitive on the name" \
  --why "compares the existing client's name case-sensitively. The *arr UI title-cases what the user typed, so an existing QBittorrent no longer matches and a second copy of the same client is added on every run - the same defect the ok/skip split exists to prevent" \
  --apply 'sed -i "s@c.get(.name.,..).lower() == .qbittorrent.@c.get(\x27name\x27,\x27\x27) == \x27qBittorrent\x27@" "$F"'

mutation arr-category-field-always-tv \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: the same call for Radarr derives movie field names instead" \
  --why "hardcodes the tv field names, so Radarr's download client is created with a tvCategory field Radarr does not have. The client saves, and then never picks anything up, because the category it was told to use is on a field the API ignored" \
  --apply 'sed -i "s@^        cat_field=\"movieCategory\"\$@        cat_field=\"tvCategory\"@" "$F"'

mutation arr-sab-added-without-a-key \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: SABnzbd is added only when it is running and has a key" \
  --why "drops the API-key half of the condition, so a running SABnzbd whose key could not be discovered gets a download client created with an empty apiKey. It authenticates against nothing and every grab fails later, far from here" \
  --apply 'sed -i "s@if \[\[ \"\$SABNZBD_RUNNING\" == true && -n \"\$SABNZBD_API_KEY\" \]\]; then@if [[ \"\$SABNZBD_RUNNING\" == true ]]; then@" "$F"'

mutation arr-metadata-put-to-a-fixed-id \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: disabled NFO metadata is enabled at its own id" \
  --why "writes the XbmcMetadata payload to metadata id 1 instead of the id it just looked up. The ids differ per install, so this overwrites whatever consumer happens to be first - and the read that found the right id still runs, which is what makes it look correct" \
  --apply 'sed -i "s@api_put \"\${BASE}/api/v3/metadata/\${meta_id}\"@api_put \"\${BASE}/api/v3/metadata/1\"@" "$F"'

mutation arr-naming-check-hardcoded \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: the naming check reads the field it was told to read" \
  --why "reads Sonarr's renameEpisodes for both services. Radarr has no such field, so the check finds nothing every time and Radarr's naming config is rewritten on every run - an idempotent script that is not" \
  --apply 'sed -i "s@data.get(.\${naming_check}., False)@data.get(\x27renameEpisodes\x27, False)@" "$F"'

mutation arr-root-folder-failure-reported-as-success \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: a rejected root-folder write is counted, not swallowed" \
  --why "reports a rejected root-folder write as a tick. Every later step depends on the root folder existing, so the run ends green and the library stays empty" \
  --apply 'sed -i "s@fail \"\${name}: add root folder \${root_path}\"@ok \"\${name}: add root folder \${root_path}\"@" "$F"'

mutation arr-score-appended-not-replaced \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: a wrong score is replaced rather than duplicated" \
  --why "stops removing the existing entry for the format before inserting the new one, so the profile ends up with two entries for one custom format. Which score wins is then an implementation detail of the *arr, and the run reports success either way" \
  --apply 'sed -i "/^items = \[i for i in items if i.get(.format.) != \${iso_cf_id}\]\$/d" "$F"'

mutation arr-only-first-profile-scored \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: every quality profile is visited, not just the first" \
  --why "truncates the list of quality-profile ids to its first element, so only one profile is ever visited. Most installs have several, so ISO releases stay eligible in every profile but one - and the summary counts a success either way. The obvious oracle, asserting the score lands in profile 1, passes against this happily" \
  --apply 'sed -i "s@^for p in data:\$@for p in data[:1]:@" "$F"'

mutation arr-unreadable-profile-is-written-anyway \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: one unreadable profile does not abandon the rest" \
  --why "carries on with an empty profile body instead of skipping it, so the PUT that follows sends whatever json_extract made of nothing. A profile that could not be read is the one case where writing it back is guaranteed wrong" \
  --apply 'sed -i "s@|| continue\$@|| true@" "$F"'

mutation arr-null-format-id-scored-into-every-profile \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: a custom-format response with no id is a failure, not a silent skip" \
  --why "runs the scoring pass even when the custom format was never created, so an empty id is interpolated into the Python comparison and into every quality profile PUT. The failure to create the format is already reported; this turns it into a second, silent one" \
  --apply 'sed -i "s@^    if \[\[ -n \"\$iso_cf_id\" \]\]; then\$@    if true; then@" "$F"'

mutation arr-delay-profile-without-sabnzbd \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: the delay profile is added only when SABnzbd is running" \
  --why "adds a delay profile preferring Usenet on a stack that has no Usenet client. Every torrent then waits out a 30-minute delay for a protocol nothing can supply" \
  --apply 'sed -i "s@^    if \[\[ \"\$SABNZBD_RUNNING\" == true \]\]; then\$@    if true; then@" "$F"'

mutation arr-dry-run-gate-removed \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: a dry run reads nothing past the health check and writes nothing" \
  --why "drops the dry-run early return out of the one function that configures both Sonarr and Radarr, so --dry-run creates root folders, download clients, custom formats and quality-profile scores in both. Kept separate from configure-apps.sh's own gates because this function carries its own copy" \
  --apply 'sed -i "s@^    if \[\[ \"\$DRY_RUN\" == true \]\]; then\$@    if false; then@" "$F"'
