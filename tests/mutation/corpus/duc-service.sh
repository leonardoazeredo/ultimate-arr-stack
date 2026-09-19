# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for duc-service/app/{scan,manual_scan,startup}.sh and manual_scan.cgi.
#
# Safe to run: tests/duc-service.bats points every path at a throwaway tree via
# the DUC_* seams and answers `duc` from a PATH stub, so nothing here indexes
# /volume1, writes /etc/cron.d, or starts nginx.

mutation duc-awk-nf-not-a-predicate \
  --file duc-service/app/startup.sh \
  --bats tests/duc-service.bats \
  --test "duc: valid_schedule rejects the values that used to reach cron unchecked" \
  --why "restores the shipped check, \`echo \$SCHEDULE | awk 'NF==5'\`. awk with a pattern and no action is a PRINT FILTER: it exits 0 whatever it matched, so the negation was never true and the fallback under it was unreachable code. Any value at all went into /etc/cron.d, where cron ignores a malformed line silently and the daily scan just never runs" \
  --apply 'sed -i "s@^    printf .%s. \"\${1-}\" | awk .*\$@    echo \"\${1-}\" | awk '"'"'NF==5'"'"' >/dev/null 2>\&1@" "$F"'

mutation duc-schedule-multiline-accepted \
  --file duc-service/app/startup.sh \
  --bats tests/duc-service.bats \
  --test "duc: valid_schedule rejects a multi-line schedule" \
  --why "drops the one-line requirement, keeping only the field count. /etc/cron.d is newline-delimited, so a SCHEDULE whose first line looks valid appends whatever follows it as further crontab lines - running as root, on a container that mounts all of /volume1" \
  --apply 'sed -i "s@exit !(ok \&\& NR == 1)@exit !ok@" "$F"'

mutation duc-cron-poller-line-dropped \
  --file duc-service/app/startup.sh \
  --bats tests/duc-service.bats \
  --test "duc: the cron file runs the poller every minute and the scan on schedule" \
  --why "removes the once-a-minute poller from the generated crontab. The scheduled scan still runs, so duc looks entirely healthy - but every manual scan request queued from the web UI sits in /tmp forever with nothing to consume it" \
  --apply 'sed -i "\@^        echo \"\* \* \* \* \* root \$MANUAL_SCAN_SH\"\$@d" "$F"'

mutation duc-cron-file-not-readable \
  --file duc-service/app/startup.sh \
  --bats tests/duc-service.bats \
  --test "duc: the cron file is world-readable, which cron requires" \
  --why "writes the cron file 0600. cron refuses to load a /etc/cron.d entry it cannot read as the invoking user and says nothing about it, so both the scheduled scan and the poller vanish with no error anywhere" \
  --apply 'sed -i "s@^    chmod 0644 \"\$dest\"\$@    chmod 0600 \"\$dest\"@" "$F"'

mutation duc-initial-scan-failure-is-fatal \
  --file duc-service/app/startup.sh \
  --bats tests/duc-service.bats \
  --test "duc: a failed initial scan does not stop the container coming up" \
  --why "lets a failing initial index kill startup under set -e. The web UI and the crontab both matter more than the first scan: this turns one bad index into a container that never serves anything again, and restart: always makes it a crash loop" \
  --apply 'sed -i "s@^    \"\$SCAN_SH\" || echo \"Initial scan failed (exit \$?)\" | tee -a \"\$LOG_FILE\"\$@    \"\$SCAN_SH\"@" "$F"'

mutation duc-scan-failure-loses-the-log-line \
  --file duc-service/app/scan.sh \
  --bats tests/duc-service.bats \
  --test "duc: a failing index still logs the end of the scan and its exit code" \
  --why "restores the shipped form. The block runs in a pipeline subshell that inherits set -e, so a failing duc killed it on the spot and both 'status=\$?' and the End of scan line were unreachable. The exit status still propagated via PIPESTATUS, which is exactly why this read as correct: the only symptom was a log that stopped mid-scan" \
  --apply 'sed -i "/^    status=0\$/d; s@ || status=\$?\$@\n    status=\$?@" "$F"'

mutation duc-scan-status-from-tee \
  --file duc-service/app/scan.sh \
  --bats tests/duc-service.bats \
  --test "duc: scan.sh reports the index's status, not tee's" \
  --why "takes the status from the pipeline instead of from PIPESTATUS[0], and drops pipefail. Deliberately mutates BOTH: either one alone is an equivalent mutant, because PIPESTATUS and pipefail each independently carry the index's status out past tee. Together they are the guarantee, and without them tee's success - it succeeds whatever it is fed - turns every failed index into a completed scan, which the poller then believes when deciding whether to keep a queued request" \
  --apply 'sed -i "s@^set -euo pipefail\$@set -eu@; s@^exit \"\${PIPESTATUS\[0\]}\"\$@exit \"\$?\"@" "$F"'

mutation duc-lock-trap-armed-too-early \
  --file duc-service/app/scan.sh \
  --bats tests/duc-service.bats \
  --test "duc: a held lock is left alone, not removed by the run that could not take it" \
  --why "arms the cleanup trap before the lock is actually acquired, so an invocation that was correctly turned away deletes the RUNNING scan's lock on its way out. The next tick of the poller then starts a second concurrent index over all of /volume1" \
  --apply 'sed -i "s@^if ! mkdir \"\$LOCK_DIR\" 2>/dev/null; then\$@trap '"'"'rm -rf \"\$LOCK_DIR\"'"'"' EXIT\nif ! mkdir \"\$LOCK_DIR\" 2>/dev/null; then@" "$F"'

mutation duc-already-running-reads-as-done \
  --file duc-service/app/scan.sh \
  --bats tests/duc-service.bats \
  --test "duc: a request arriving mid-scan is kept, not silently dropped" \
  --why "returns 0 when the lock is held, which is how this shipped. 'I did not scan' and 'I scanned' become the same answer, and the poller - which can only decide what to do with the request from that answer - discards it. The user's manual scan never happens and nothing anywhere reports a problem" \
  --apply 'sed -i "s@^    exit \"\$EX_ALREADY_RUNNING\"\$@    exit 0@" "$F"'

mutation duc-request-cleared-mid-scan \
  --file duc-service/app/manual_scan.sh \
  --bats tests/duc-service.bats \
  --test "duc: a request arriving mid-scan is kept, not silently dropped" \
  --why "clears the request on the already-running branch too. Same lost scan as the mutation above, reached from the consumer's side rather than the producer's - the two are separate entries because either file alone can reintroduce it" \
  --apply 'sed -i "s@^        echo \"Manual scan deferred: a scan is already running\" >> \"\$LOG_FILE\"\$@        rm -rf \"\$REQUEST_DIR\"; echo \"Manual scan deferred: a scan is already running\" >> \"\$LOG_FILE\"@" "$F"'

mutation duc-failed-scan-retries-forever \
  --file duc-service/app/manual_scan.sh \
  --bats tests/duc-service.bats \
  --test "duc: a failed manual scan clears the request instead of retrying forever" \
  --why "keeps the request after a genuine failure. The poller runs every minute, so a scan that is broken for any lasting reason re-runs sixty times an hour, each one appending a failure line to the log the web UI serves. Addressed from the \`*)\` arm onward because both arms clear the request with the same line - only their position distinguishes them" \
  --apply 'sed -i "/^    \*)\$/,\$ s@^        rm -rf \"\$REQUEST_DIR\"\$@        :@" "$F"'

mutation duc-cgi-queues-during-a-scan \
  --file duc-service/app/manual_scan.cgi \
  --bats tests/duc-service.bats \
  --test "duc: the cgi shows the running scan's log instead of queueing" \
  --why "drops the in-progress branch, so pressing the button during a scan queues another one instead of showing progress. The poller then starts a second full index of /volume1 the moment the first finishes, every time" \
  --apply 'sed -i "s@^if \[ -d \"\$LOCK_DIR\" \]; then\$@if false; then@" "$F"'

mutation duc-cgi-missing-log-is-fatal \
  --file duc-service/app/manual_scan.cgi \
  --bats tests/duc-service.bats \
  --test "duc: the cgi still returns a body when the log file does not exist yet" \
  --why "removes the fallback for an absent log. Under set -e the script dies AFTER the headers have gone out, so a fresh container answers the status page with a truncated response and no explanation" \
  --apply 'sed -i "s@^    cat \"\$LOG_FILE\" 2>/dev/null || echo \"(no log yet)\"\$@    cat \"\$LOG_FILE\"@" "$F"'

mutation duc-cgi-response-never-completed \
  --file duc-service/app/manual_scan.cgi \
  --bats tests/duc-service.bats \
  --test "duc: the cgi does not report a queued scan when the marker cannot be created" \
  --why "removes the trap that finishes a response whose branch never reached the end of the script. A failed mkdir then leaves the client the Content-type header and nothing else: the status is still non-zero and the success message is still absent, so only an assertion on the shape of the response can see it" \
  --apply 'perl -pi -e '"'"'s{^trap _finish_response EXIT}{:}'"'"' "$F"'

# The three below all drop errexit and nothing else. Each names the one place in
# its file where that is load-bearing: an unguarded command whose failure the
# script would otherwise continue past. Applying them with perl rather than
# `sed -i` like their neighbours, because these three are also the entries a
# macOS host can replay - tests/mutation/README.md records that GNU `sed -i`
# syntax is an ERROR there. The rest of this file stays as it was.

mutation duc-startup-cron-failure-is-swallowed \
  --file duc-service/app/startup.sh \
  --bats tests/duc-service.bats \
  --test "duc: startup does not come up when the cron daemon cannot start" \
  --why "drops errexit from startup.sh, so a cron daemon that will not start stops being fatal. main() runs on to the webserver, the container comes up and reports success, and every scan it will ever run - the once-a-minute poller and the scheduled one - is an entry in a crontab nothing is reading" \
  --apply 'perl -pi -e "s/^set -euo pipefail\$/set -uo pipefail/" "$F"'

mutation duc-cgi-queued-scan-that-was-never-queued \
  --file duc-service/app/manual_scan.cgi \
  --bats tests/duc-service.bats \
  --test "duc: the cgi does not report a queued scan when the marker cannot be created" \
  --why "drops errexit from the cgi, so a failed mkdir is followed by the success message anyway. The user is told a scan starts within one minute; no marker was created, the poller branches on that marker, and no scan ever runs" \
  --apply 'perl -pi -e "s/^set -euo pipefail\$/set -uo pipefail/" "$F"'

mutation duc-scan-log-write-failure-reported-as-success \
  --file duc-service/app/scan.sh \
  --bats tests/duc-service.bats \
  --test "duc: a scan whose log cannot be written is not reported as a success" \
  --why "drops errexit from scan.sh, so a tee that cannot open the log stops failing the run. The script falls through to its explicit exit \${PIPESTATUS[0]}, which is the index's status - 0 - so a scan that left no record anywhere is reported as a success to cron and to the poller" \
  --apply 'perl -pi -e "s/^set -euo pipefail\$/set -uo pipefail/" "$F"'

# The last real-gap row in tests/mutation/survivors.tsv (startup.sh:51). It was
# unreachable for as long as the socket path was hardcoded to /var/run: every
# test that drives main() overrides start_webserver, because the function needs
# fcgiwrap, nginx and a root-owned directory. DUC_FCGI_SOCKET is the seam that
# lets a test drive the wait itself, in both directions.
mutation duc-webserver-socket-wait-inverted \
  --file duc-service/app/startup.sh \
  --bats tests/duc-service.bats \
  --test "duc: start_webserver returns as soon as the socket is up" \
  --why "inverts the wait for the fcgiwrap socket, which is severe in both directions. With the socket up the loop spins instead of returning, so the chmod and nginx are never reached and the container serves no web UI at all; with it absent the loop is skipped, the chmod finds no socket, and errexit kills the function before nginx - the same dead UI, arrived at from the other side" \
  --apply 'perl -pi -e '"'"'s{while ! \[ -S "\$FCGI_SOCKET" \]}{while [ -S "\$FCGI_SOCKET" ]}'"'"' "$F"'

# --- duc startup.sh: the start-up scan ------------------------------------
#
# The five below pin the decision that keeps `restart: always` from re-walking
# all of /volume1 on every restart. The last two are the ones that matter most:
# every other entry here calls startup_scan_needed directly, so without them
# deleting or inverting the branch in main() restores the 2026-09-18 defect with
# the whole suite still green.
#
# All five apply with `sed -i.bak … && rm -f "$F.bak"`: a bare `sed -i` on this
# macOS host reads the script as the -i suffix and edits nothing, which the
# runner scores as "changed NOTHING" rather than as a pass - see
# tests/mutation/README.md.

mutation duc-index-missing-treated-fresh \
  --file duc-service/app/startup.sh \
  --bats tests/duc-service.bats \
  --test "duc: startup scans when there is no index yet" \
  --why "treating a missing index as fresh is the first-run defect: a container started against an empty volume never builds an index, every page of the UI is empty, and nothing in the log says why" \
  --apply 'sed -i.bak "s@\[\[ -f \"\$INDEX_DB\" \]\] || return 0@[[ -f \"\$INDEX_DB\" ]] || return 1@" "$F" && rm -f "$F.bak"'

mutation duc-staleness-compared-backwards \
  --file duc-service/app/startup.sh \
  --bats tests/duc-service.bats \
  --test "duc: startup scans again once the index is older than the window" \
  --why "comparing the age the wrong way round skips the scan on a stale index and runs it on a fresh one -- the guard exactly backwards; it also fails the fresh-index test, so both directions of the decision are pinned" \
  --apply 'sed -i.bak "s@-mmin -\"\$age_minutes\"@-mmin +\"\$age_minutes\"@" "$F" && rm -f "$F.bak"'

mutation duc-freshness-window-hardcoded \
  --file duc-service/app/startup.sh \
  --bats tests/duc-service.bats \
  --test "duc: the freshness window comes from the environment, not a literal" \
  --why "hardcoding the window makes the seam inert, so the number cannot be tuned on a host whose cron cadence differs and the test above silently stops testing anything" \
  --apply 'sed -i.bak "s@age_minutes=\$(( STARTUP_SCAN_MAX_AGE_HOURS \* 60 ))@age_minutes=1200@" "$F" && rm -f "$F.bak"'

mutation duc-startup-branch-removed \
  --file duc-service/app/startup.sh \
  --bats tests/duc-service.bats \
  --test "duc: main\(\) branches on the start-up scan decision" \
  --why "deleting the branch restores the unconditional start-up scan, which with restart: always is the defect of 2026-09-18 -- and no behavioural test notices, because they all call the decision function directly" \
  --apply 'sed -i.bak "s@if startup_scan_needed; then@if true; then@" "$F" && rm -f "$F.bak"'

mutation duc-startup-branch-inverted \
  --file duc-service/app/startup.sh \
  --bats tests/duc-service.bats \
  --test "duc: main\(\) branches on the start-up scan decision" \
  --why "inverting the branch scans only when the index is fresh and never when it is stale -- the opposite of the intent, reached by a one-character edit" \
  --apply 'sed -i.bak "s@if startup_scan_needed; then@if ! startup_scan_needed; then@" "$F" && rm -f "$F.bak"'
