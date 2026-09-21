# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/configure-apps.sh.
#
# Safe to run: tests/configure-apps.bats sources the script rather than
# executing it, answers every docker question from a fixture directory, points
# CONFIGURE_ENV_FILE and TMPDIR at throwaway paths, and keeps the stub harness
# on PATH. Every mutation below therefore reaches forbid() rather than a live
# container, which matters most for the ones that leave a check out.

mutation configure-apps-help-fixed-line-range \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: the help block is derived from the file, not a fixed length" \
  --why "restores the head -27 | tail -24 extractor this pass replaced. It was already wrong when it was found - the header runs to line 29, so --help silently dropped its last two lines - and a hardcoded range goes stale again the moment anyone edits the header, with nothing to say so" \
  --apply 'sed -i "s@^    awk .*self\"\$@    head -27 \"\$self\" | tail -24@" "$F"'

mutation configure-apps-unknown-option-tolerated \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: an unknown option is named and fails without exiting" \
  --why "prints the usage error and then reports success anyway, so a typo like --dryrun configures the whole stack for real while the operator reads a message telling them it did not" \
  --apply 'sed -i "/Usage: \$0 \[--dry-run\]/{n;s@^                return 1\$@                return 0@}" "$F"'

mutation configure-apps-env-value-cut-at-second-equals \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: env_value keeps everything after the first =" \
  --why "goes back to cut -d= -f2, which truncates any value containing an = at the second one. Whatever reads that value back gets the half before the second =, and a truncated credential fails exactly as a wrong one does - with no clue that the parser, not the value, is what broke" \
  --apply 'sed -i "s@line=\"\${line#\*=}\"@line=\$(cut -d= -f2 <<< \"\$line\")@" "$F"'

mutation configure-apps-env-value-keeps-quotes \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: env_value strips one layer of double quotes" \
  --why "drops the quote stripping. .env files in this repo quote values as a matter of style, so the value comes back with its quotes still attached and whatever consumes it treats them as part of it - the failure surfaces as a rejected credential, which points at the value rather than at the parser" \
  --apply 'sed -i "/^    line=\"\${line%/d" "$F"'

mutation configure-apps-prereq-exits-instead-of-returning \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: check_prerequisites returns rather than exits, so main can report" \
  --why "puts back the bare exit 1. It looks identical from the shell - same status - but it kills the caller from inside a function, so main can never print its summary or say what it did, and the script becomes untestable without a subprocess per assertion" \
  --apply 'sed -i "/^check_prerequisites()/,/^}/ s@^        return 1\$@        exit 1@" "$F"'

mutation configure-apps-container-name-substring-match \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: a container whose name merely contains a required one does not count" \
  --why "drops -x from the running-container check, so it stops requiring a whole-line match. This NAS runs gluetun-exit alongside gluetun, so a substring match reports the VPN as present when only the exit-node tunnel is up, and the script then waits four minutes for services that share a namespace which does not exist" \
  --apply 'sed -i "s@grep -qx \"\$c\" <<< \"\$running\"@grep -q \"\$c\" <<< \"\$running\"@" "$F"'

mutation configure-apps-gluetun-health-unchecked \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: an unhealthy gluetun is named with its actual state" \
  --why "accepts any health state that is not the empty string, so starting, unhealthy and the literal unknown all read as ready. Prowlarr, SABnzbd and FlareSolverr share Gluetun's netns - the whole point of this check is that they cannot answer on any port until the tunnel is up" \
  --apply 'sed -i "s@if \[\[ \"\$health\" != \"healthy\" \]\]; then@if [[ -z \"\$health\" ]]; then@" "$F"'

mutation configure-apps-arr-key-missing-not-counted \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: a missing arr key is reported as a failure, not skipped silently" \
  --why "downgrades an undiscoverable API key from a counted failure to an informational line. Every later step for that service then fails for its own reasons, and the summary reports a pile of downstream errors with no mention of the one cause" \
  --apply 'sed -i "s@fail \"Could not discover \${svc^} API key\"@info \"Could not discover \${svc^} API key\"@" "$F"'

mutation configure-apps-sab-key-always-queried \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: SABnzbd's key is only looked for when SABnzbd is running" \
  --why "queries a container that may not exist. SABnzbd is optional here, and reaching into an absent container is how an optional dependency turns into a hard one" \
  --apply 'sed -i "/^discover_api_keys()/,/^}/ s@if \[\[ \"\$SABNZBD_RUNNING\" == true \]\]; then@if true; then@" "$F"'

mutation configure-apps-failed-count-is-decorative \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: FAILED is not decorative — a failure makes the script exit non-zero" \
  --why "prints the failure count and then discards it, which is what the script did before this pass: it exited 0 whether it had configured everything or nothing. An accumulator that cannot change the outcome is the exact shape this repo keeps finding in its own guards" \
  --apply 'sed -i "s@^    (( FAILED == 0 ))\$@    return 0@" "$F"'

mutation configure-apps-sab-summary-step-always-shown \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: the SABnzbd manual step appears only when SABnzbd is running" \
  --why "tells every operator to go and enter usenet credentials into a container this stack may not run. A remaining-steps list that names steps that do not apply stops being read" \
  --apply 'sed -i "/^print_summary()/,/^}/ s@if \[\[ \"\$SABNZBD_RUNNING\" == true \]\]; then@if true; then@" "$F"'

# --- Entries below close gaps the generative sweep found, not gaps anyone
# --- thought of first. run-generated.sh reported them as survivors against the
# --- first 44 tests in tests/configure-apps.bats; each one is here because a
# --- test was then written for it.

mutation configure-apps-sabnzbd-name-substring-match \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: a container whose name merely contains sabnzbd is not sabnzbd" \
  --why "drops -x from the SABnzbd check, so any running container whose name contains 'sabnzbd' counts. SABNZBD_RUNNING gates both the API-key lookup and the manual step in the summary, so an unrelated container turns an optional service into one this script reaches into and reports a failure for - the same substring-match defect as the required-container check above, and the same one that reached production twice already" \
  --apply 'perl -pi -e "s/grep -qx \"sabnzbd\"/grep -q \"sabnzbd\"/" "$F"'

# The -P removal in this file is not cosmetic: the extraction it replaced could
# not fail on BSD grep (it exited 2 with the status discarded), so these two
# lines were only ever judged on a GNU host. Pin the shape the replacement has
# to keep.
mutation configure-apps-arr-key-extraction-prints-the-whole-file \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: each arr key is read out of that service's own config.xml" \
  --why "drops -n from the extraction, so sed prints every line of config.xml and then the substitution output as well. The variable that carries the service's API key then holds the whole file: every later request authenticates with a value containing newlines, and the eight characters shown to the operator come from the XML prologue instead of the value itself" \
  --apply 'python3 -c "import sys;p=sys.argv[1];s=open(p).read();old=\"| sed -n \x27s|.*<ApiKey>\";new=\"| sed -e \x27s|.*<ApiKey>\";assert old in s, old;s=s.replace(old,new,1);open(p,\"w\").write(s)" "$F"'
