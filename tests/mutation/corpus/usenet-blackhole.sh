#!/bin/bash
# Guards added with scripts/usenet-blackhole.sh and its watcher, 2026-09-14.
#
# This script replaces SABnzbd as the usenet path: it submits the arrs' NZBs to
# TorBox's API and moves the finished download into a watch folder the arr
# polls. Three of the four entries below are defects that were live in the first
# version of this file, found by writing tests/usenet-blackhole.bats rather than
# by reading it -- which is the point of the file.

# --- a dry run that applies ------------------------------------------------

mutation usenet-blackhole-dry-run-actually-applies \
  --file scripts/usenet-blackhole.sh \
  --bats tests/usenet-blackhole.bats \
  --test "^usenet-blackhole: the default run does not pass --apply to python" \
  --why "the flags were built with \${APPLY:+--apply}, which reads as 'add it when applying' and is not: \`:+\` tests for non-empty, and APPLY=false is non-empty. So every invocation applied -- while the banner printed DRY RUN. A dry run that silently applies is worse than no dry run, because it is exactly the mode an operator uses to decide whether applying is safe" \
  --apply 'perl -pi -e "s/^if \\\$APPLY; then PY_ARGS\+=\(--apply\); fi$/PY_ARGS+=(--apply)/" "$F"'

# --- the TorBox key back on the command line -------------------------------

mutation usenet-blackhole-key-on-the-command-line \
  --file scripts/usenet-blackhole.sh \
  --bats tests/usenet-blackhole.bats \
  --test "^usenet-blackhole: the key travels in the environment, not on the command line" \
  --why "passing --api-key \"\$TORBOX_KEY\" puts the TorBox token in python3's argv, which /proc/<pid>/cmdline exposes to every user on the box. The timer runs every two minutes, so the window is not small. scripts/queue-cleanup.sh carries the same fix for the same reason, made 2026-09-13" \
  --apply 'perl -pi -e "s/^        \\\$\{PY_ARGS\[@\]\+\"\\\$\{PY_ARGS\[@\]\}\"\} \\\\$/        --api-key \\\"testtorboxkey\\\" \\\\/" "$F"'

# --- --help prints its own source ------------------------------------------

mutation usenet-blackhole-help-prints-its-own-source \
  --file scripts/usenet-blackhole.sh \
  --bats tests/usenet-blackhole.bats \
  --test "^usenet-blackhole: --help stops at the comment block" \
  --why "the fixed-range sed that prints the header has to stop ON the last comment line; one line further and --help emits the SCRIPT_DIR assignment below it, shell source dressed as documentation. This is a hardcoded range, so it goes stale every time a line is added to the header -- which is exactly what happened when the --report-failures paragraph went in, and the test is what noticed" \
  --apply 'perl -pi -e "s/\Qsed -n '"'"'3,55p'"'"'\E/sed -n '"'"'3,58p'"'"'/" "$F"'

# --- staging inside the arr's watch folder ---------------------------------

mutation usenet-blackhole-staging-inside-the-watch-folder \
  --file scripts/usenet-blackhole.sh \
  --bats tests/usenet-blackhole.bats \
  --test "^usenet-blackhole: staging is not inside the arr's watch folder" \
  --why "Sonarr does not skip dot-directories at the top level of a watch folder: DiskProviderBase.GetDirectories skips only FileAttributes.System, and DiskScanService.FilterPaths matches dot-segments with a regex that needs a trailing separator, which PathExtensions.GetRelativePath has already trimmed off. A staging directory parked in there is reported to the arr as a completed download, and its half-written files are what get imported" \
  --apply 'perl -pi -e "s/\Qcomplete}\"\E/staging}\"/" "$F"'

# --- the fetch pool: serial, unbounded, or interleaved ----------------------
#
# One at a time was the ceiling on this path: a pass that found five finished
# releases pulled them in series, so the last waited out four downloads and
# four unpacks. These three pin the concurrency, its bound, and the thing that
# goes wrong when three threads share one output stream.

mutation usenet-blackhole-fetches-one-at-a-time \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "FETCH_WORKERS = 1 restores the serial fetch this was written to remove, and it is the mutation that matters most here: the concurrency test sizes its barrier at three and is hardcoded rather than reading the constant, because a fixture that read it would shrink to one job and one barrier slot and pass against a serial implementation" \
  --apply 'sed -i.bak "s@^FETCH_WORKERS = 3\$@FETCH_WORKERS = 1@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-fetch-pool-unbounded \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "an uncapped pool starts an unrar per completed release at once. The unpack is CPU-bound and this runs on a NAS that is also transcoding, with the arr's importer reading the same disk, so the bound is what keeps a large batch from stalling everything else on the box" \
  --apply 'sed -i.bak "s@max_workers=min(FETCH_WORKERS, len(to_fetch))@max_workers=None@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-fetch-output-interleaved \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "each fetch collects its own lines and the caller prints them whole. Handing the shared stream to three threads instead puts one release's progress inside another's, which is how a log stops being readable at exactly the moment -- several concurrent failures -- when someone needs it" \
  --apply 'sed -i.bak "s@out=lines.append)@out=print)@" "$F" && rm -f "$F.bak"'

# --- reading TorBox's failure states ----------------------------------------
#
# Found live on 2026-09-14 by counting the states on the account rather than by
# anything in this stack complaining: 19 completed, 15 aborted, 1 processing,
# and all sixteen in-flight jobs reported as "in progress". TorBox puts the
# reason in parentheses -- `failed (Aborted, cannot be completed - ...)` -- and
# the classifier matched the failure set exactly.

mutation usenet-blackhole-failed-state-exact-match \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "matching the failure set exactly is the original bug. TorBox never returns a bare 'failed', so the branch was unreachable, fifteen releases sat as in-progress until the 24-hour timeout, and the arr was told nothing at all -- a blackhole failure is invisible to the arr by design, so this was the only thing that could have reported it" \
  --apply 'sed -i.bak "s@^    if not lowered.startswith(FAILED_STATES):\$@    if lowered not in (\"failed\", \"error\"):@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-failure-reason-dropped \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the parenthetical is the whole value of the message: 'missing articles' and 'the provider broke' both end the job, and only one is worth another attempt later. Logging the raw state instead keeps the answer buried in a URL that ends in not-complete" \
  --apply 'sed -i.bak "s@^        inner = lowered.split(\"(\", 1)\[1\].rsplit(\")\", 1)\[0\].strip()\$@        inner = \"\"@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-failure-substring-match \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "a substring match anywhere in the state reads a healthy state as a failure. The prefix is what TorBox varies the tail of, and nothing else" \
  --apply 'sed -i.bak "s@^    if not lowered.startswith(FAILED_STATES):\$@    if not any(f in lowered for f in FAILED_STATES):@" "$F" && rm -f "$F.bak"'

# --- the 429 backoff --------------------------------------------------------
#
# `createusenetdownload` is limited to 60 calls an hour. Measured 2026-09-14:
# 47 refusals to 37 acceptances, with three refusals recurring on pass after
# pass because each one was retried two minutes later and spent another call
# from the budget it was waiting on.

mutation usenet-blackhole-429-does-not-stop-the-pass \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "continuing the loop after a 429 offers every remaining NZB to a budget that is already empty. Each one is refused and each refusal is another call, which is the defect this backoff exists to remove -- reconfirmed three passes in a row with nothing submitted in between" \
  --apply 'sed -i.bak "s@^            out(f\"    ! {release}: rate limited, pausing submissions: {err}\")\$@            out(f\"    ! {release}: rate limited\")\n            continue\n            break@g" "$F"'

mutation usenet-blackhole-backoff-not-honoured \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "recording the deadline and then never checking it is the same as no backoff at all, with extra state. The marker is written from a pass that has already been refused, so nothing else in the run would notice" \
  --apply 'sed -i.bak "s@^    paused_until = in_backoff(state)\$@    paused_until = None@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-429-read-as-an-ordinary-error \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "a 429 that is not distinguished from a 500 is retried on the next pass like any other transient failure. That is the entire bug: the status is the one signal that says stop asking rather than try again" \
  --apply 'sed -i.bak "s@^        if code == \"429\":\$@        if False:@" "$F" && rm -f "$F.bak"'

# --- the ten active download slots ------------------------------------------
#
# The other half of the 429 problem, and the larger half by count. Measured
# 2026-09-14: one pass spent 51 refusals offering releases to an account that
# already had ten downloads running, each refusal a call against the same
# 60-an-hour budget.

mutation usenet-blackhole-active-limit-read-as-a-per-release-failure \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "without its own type an ACTIVE_LIMIT is an ordinary 500, so the loop carries on offering every remaining NZB to a provider that has already said there is no room. That is the 51-refusals-in-one-pass measurement, and the same reasoning that makes the 429 break out applies here" \
  --apply 'sed -i.bak "s@^        if api_error_code(body) == \"ACTIVE_LIMIT\":\$@        if False:@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-active-limit-does-not-stop-the-pass \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "continuing past the refusal spends one call per waiting release on an answer that cannot change within the pass. The point of the break is that the next pass, two minutes later, is a submission rather than a waste when a slot has freed" \
  --apply 'sed -i.bak "s@^            out(f\"    ! {release}: no free slots, stopping this pass: {err}\")\$@            out(f\"    ! {release}: no free slots\")\n            continue\n            break@g" "$F"'

mutation usenet-blackhole-any-500-stops-the-pass \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "treating every 500 as a full account abandons a batch over one release the provider stumbled on. ACTIVE_LIMIT shares its status with UNKNOWN_ERROR, DOWNLOAD_SERVER_ERROR and a dozen others, which is why the decision is read from the body" \
  --apply 'sed -i.bak "s@^        if api_error_code(body) == \"ACTIVE_LIMIT\":\$@        if True:@" "$F" && rm -f "$F.bak"'

# --- telling the arrs what died ---------------------------------------------
#
# Phase 1 of PLAN-USENET-RECOVERY.md. The arr's queue never holds a blackhole
# item -- measured 2026-09-15: 12 in flight, 0 in either queue, `queue-cleanup`
# reporting "Queue size: 0 items" hourly while 227 failures accumulated across
# 100 distinct releases. So the arr could not blocklist what it could not see,
# and `The.Sopranos.S01E08.POLiSH.1080p.WEB.H264-CHOPiN` was grabbed again on
# the 14th and the 15th after six blocklist entries on the 12th.
#
# The defect these entries reintroduce is the dangerous direction: a loosened
# match marks an unrelated grab failed, and the arr blocklists a release that
# was fine.
#
# The first one below is the opposite direction, and the one that shipped: the
# wiring between main() and arr_services() never matched, so the feature could
# not report anything at all and no test noticed -- the per-function test calls
# arr_services() directly with the shape it wants, so the half that was wrong
# had no coverage. It sits first in this section because every other entry here
# reintroduces a defect that some test already catches; this one did not.

mutation usenet-blackhole-arr-keys-keyed-by-display-name \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "keys the dict by display name where arr_services() looks each one up by environment variable, so every lookup misses and the list is empty however correct the keys are. Reporting is then dead on arrival: the pass prints 'no SONARR_API_KEY or RADARR_API_KEY set' with both keys present and 32 characters long, and nothing else in the run notices, because a blackhole that reports nothing is indistinguishable from one with nothing to report. This is how it shipped -- --report-failures was switched on against the live NAS, resolved no services for three consecutive passes, and every dead release went on being grabbed again" \
  --apply 'sed -i.bak "s@arr_keys = {env:@arr_keys = {name:@" "$F" && sed -i.bak "s@for _name, _port, env in ARR_SERVICES}@for name, _port, env in ARR_SERVICES}@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-title-match-not-exact \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "a prefix or substring match resolves S01E08 to S01E09 when the arr has not yet written the one you asked about, and the wrong episode of a series with 3,006 missing episodes gets blocklisted. The exact comparison is the only thing standing between a re-release with a cosmetic title difference and a blocklist entry for a release that was fine" \
  --apply 'sed -i.bak "s@if record.get(\"sourceTitle\") != release:@if release not in (record.get(\"sourceTitle\") or \"\"):@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-title-match-case-folded \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "folding case is the first step of the fuzzy matching this deliberately does not do, and it is invisible in a dry-run log where both titles look identical anyway. If the arr's stored title ever differs in case, the pair is what the operator has to see in the dry run, not something to paper over" \
  --apply 'sed -i.bak "s@if record.get(\"sourceTitle\") != release:@if (record.get(\"sourceTitle\") or \"\").lower() != release.lower():@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-oldest-grab-wins \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the arr writes a fresh history row on every grab, and three grabs in 24 hours is the normal case here (history ids 11545, 11763, 11921 for one Sopranos episode). Reporting the oldest marks a grab that has already been superseded while the live one stays unblocked -- the arr would then re-grab the same dead release again" \
  --apply 'sed -i.bak "s@best = max(matches, key=lambda r: str(r.get(\"date\") or \"\"))@best = min(matches, key=lambda r: str(r.get(\"date\") or \"\"))@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-already-failed-grabs-are-candidates \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "a downloadFailed row carries the same sourceTitle as the grab it came from, so dropping the eventType filter makes a re-report the newest match on the second pass -- the arr writes a second blocklist entry for a release it already blocked, every two minutes, forever" \
  --apply 'sed -i.bak "s@if record.get(\"eventType\") != \"grabbed\":@if False:@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-no-history-window \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "an unbounded search matches a grab from a previous season, because the indexer returns the same release name for a re-post. The seven-day bound is what keeps a failure attributed to the attempt that actually failed" \
  --apply 'sed -i.bak "s@since = self.now - timedelta(days=HISTORY_WINDOW_DAYS)@since = self.now - timedelta(days=3650)@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-a-failed-report-is-remembered \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the ledger means 'the arr has this'. Recording a report the arr refused (a 500, a restart mid-POST) suppresses every retry, so the release stays unblocked with nothing in the log saying the report never landed -- the exact silent failure this whole change exists to remove" \
  --apply 'sed -i.bak "s@^            return \"failed\"\$@            self.ledger[key] = {\"at\": self.now.isoformat()}\n            return \"failed\"@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-arr-post-http-error-read-as-success \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "curl exits 0 on a 4xx/5xx without -f, so the arr's 401 (a stale key) or 500 comes back as an accepted report. FailureReporter writes the ledger entry and returns \"reported\", and the suppression is permanent: the NZB is already discarded, so the grab the arr never accepted is never offered again -- a silent failure the ledger exists to make impossible" \
  --apply 'sed -i.bak "/def post/,/return proc.returncode/s@\"-s\", \"-f\", \"--max-time\"@\"-s\", \"--max-time\"@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-ledger-not-checked \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "writing the ledger and never reading it is the same as no ledger, with extra state. The arr takes a second blocklist entry for a release it already blocked, and the log fills with duplicates until the state file stops being readable" \
  --apply 'sed -i.bak "s@^        if key in self.ledger:\$@        if False:@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-ledger-not-persisted-on-report \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the ledger has to be on disk the moment the arr accepts the report. A crash between the POST and the next save_state re-reports the same grab on the next pass -- and with the NZB already discarded there is nothing else to stop it" \
  --apply 'sed -i.bak "s@^    if on_report is not None and outcome == \"reported\":\$@    if False:@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-history-refetched-per-failure \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the history body is thousands of rows behind a 30s curl timeout -- measured ~11,600 rows over three weeks on Sonarr -- and resolve() runs once per failure in the pass, with several failures a pass being the ordinary case. Without the cache each failure pays for the same download again, on a timer that runs every two minutes, while the arr it is asking is the one already struggling" \
  --apply 'sed -i.bak "s@if name not in self._history_cache:@if True:@" "$F" && rm -f "$F.bak"'

# --- the stall rule ---------------------------------------------------------
#
# Phase 2 item 3 of PLAN-USENET-RECOVERY.md. Measured 2026-09-15: the oldest
# in-flight job was 21.2h old with nothing to show and --timeout-hours is 24, so
# it held one of the account's ten concurrent slots for the whole day before
# anything noticed. TorBox reports a numeric `progress` on every `mylist`
# record; a value that has not moved for --stall-hours is the signal that it
# never will, and the timeout stays the bound for a release that keeps moving.
#
# The dangerous directions here are opposite to Phase 1's: failing a job that
# was still moving (it loses a release that would have worked), reading a
# missing field as a value (it fails every live job at once), and letting a
# stalled release keep its NZB (it reproduces the retry storm).

mutation usenet-blackhole-stall-rule-never-fires \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the whole rule. Without it a release that never reports a byte of progress holds one of ten slots until the 24-hour timeout -- the measured 21.2h job, which is what Phase 2 exists to stop paying for" \
  --apply 'sed -i.bak "s@^                if stalled_hours > stall_hours:\$@                if False:@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-stall-bound-hardcoded \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "a hardcoded four makes --stall-hours a decoration: the banner announces the operator's number while the watcher enforces its own. The flag exists because the right bound is an operational choice, not a constant" \
  --apply 'sed -i.bak "s@stalled_hours > stall_hours@stalled_hours > 4.0@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-progress-change-is-not-a-change \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "if a moved value does not reset the clock, a genuinely large release that is still downloading is failed at the stall bound anyway -- the 24h window the plan explicitly keeps for releases that keep moving. This is the direction that costs a release that would have worked" \
  --apply 'sed -i.bak "s@if job.get(\"last_progress\") != progress:@if job.get(\"last_progress\") is None:@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-missing-progress-read-as-unchanged \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "a record with no progress field read as the value zero fails every live job at once the moment TorBox changes its schema or an older record omits the field. Absence is not a value: the stall check is skipped and the timeout stays the only bound" \
  --apply 'sed -i.bak "s@progress = record.get(\"progress\")@progress = record.get(\"progress\", 0.0)@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-stalled-nzb-not-discarded \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the arr never cleans its own nzb folder, so a terminal job whose NZB stays there looks like a fresh grab two minutes later. The same dead release is submitted again and handed another slot -- the retry storm Phase 1 exists to fix, reproduced inside the change meant to relieve it" \
  --apply 'sed -i.bak "s@if status in (\"failed\", \"timeout\", \"stalled\"):@if status in (\"failed\", \"timeout\"):@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-stall-flag-not-read-from-argv \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the flag has to be read back out of argparse and handed to the pass. Reaching python's argv and the banner while never reaching poll() leaves --stall-hours inert, and every other stall test still passes because they call poll() directly" \
  --apply 'sed -i.bak "/^            stall_hours=args.stall_hours,\$/d" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-stall-reported-as-a-timeout \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "\"stalled\" is the ledger key, not decoration. Reporting a stall as a timeout collides with a real timeout on the same grab, so the second fact is silently dropped -- the same argument that already keeps torbox and timeout apart in Phase 1's ledger" \
  --apply 'sed -i.bak "s@report_failed(report, job\[\"name\"\], \"stalled\", detail,@report_failed(report, job[\"name\"], \"timeout\", detail,@" "$F" && rm -f "$F.bak"'

# --- a stall bound of zero, refused at both entry points --------------------
#
# `--stall-hours 0` is numeric and parses, and it is the one accepted value that
# makes `stalled_hours > stall_hours` true the moment a job's clock starts: a
# single live pass would fail every in-flight job it has and report each one to
# its arr as a stalled release. The shell refuses it before python starts and
# argparse refuses it at the argument, so neither has to trust that the other
# ran -- the module is importable and callable on its own.

mutation usenet-blackhole-zero-stall-bound-accepted \
  --file scripts/usenet-blackhole.sh \
  --bats tests/usenet-blackhole.bats \
  --test "^usenet-blackhole: a zero --stall-hours is refused, in any spelling" \
  --why "zero passes the numeric pattern, so without this check the pass runs with a zero-hour stall bound: the banner announces it and python is handed it. \`stalled_hours > 0\` is true the moment a job's clock starts, so every in-flight job is terminal on its first unchanged poll -- reported to its arr, its NZB discarded. The argument check is the only place the operator gets a message about the value itself rather than a pass that failed afterwards for a reason nothing explained" \
  --apply 'sed -i.bak "s@exit !(hours > 0)@exit 0@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-zero-stall-bound-accepted-in-python \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the module is a real entry point, not only something the shell calls: tests and one-off runs reach main() directly, and the shell's check is a separate file that can be edited without this one noticing. The zero reaches run() and poll() as soon as the type check stops refusing it, with the same cost -- every in-flight job terminal on its first unchanged poll -- and this is what says the Python half refuses it on its own rather than relying on the shell having run first" \
  --apply 'sed -i.bak "s@if not hours > 0:@if False:@" "$F" && rm -f "$F.bak"'

# --- freeing the slot a terminal job still holds ----------------------------
#
# poll() ended a stalled or timed-out job by deleting it from the state file and
# doing nothing else. The job itself stayed ACTIVE at TorBox, so it went on
# holding one of the account's ten concurrent slots -- the exact cost the stall
# rule says it exists to stop. `controlusenetdownload` with `operation: delete`
# is the call that actually frees it. Only the stalled and timeout branches need
# it: a job TorBox reports failed has already stopped, so it holds nothing.

mutation usenet-blackhole-stalled-job-not-deleted \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "dropping a stalled job from the state file does not stop it running. It is still ACTIVE at TorBox, so it holds one of the ten slots until the 24h timeout the stall rule exists to pre-empt -- measured 2026-09-15, the oldest in-flight job was 21.2h old with nothing to show. Without this call the stall rule only stops watching the slot being spent, which is not what its docstring claims it does" \
  --apply 'sed -i.bak "/if stalled_hours > stall_hours:/,/results.append((key, job/ s@^\( *\)delete_at_torbox(torbox, job, out)\$@\1pass@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-timed-out-job-not-deleted \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "a job past --timeout-hours is still downloading at TorBox even though the watcher has given up on it, so its slot stays spent until TorBox finishes or fails it on its own. Deleting only on the stall branch leaves this one -- the branch the live stack lost the most to, with the oldest job at 21.2h against a 24h cap -- exactly as it was" \
  --apply 'sed -i.bak "/age_hours > timeout_hours:/,/results.append((key, job/ s@^\( *\)delete_at_torbox(torbox, job, out)\$@\1pass@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-delete-failure-stops-the-pass \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the delete is best-effort, the same rule a failure report follows. A TorBox that refuses one -- a 500, a job already gone -- must not take the pass down with it, or one un-deletable release stops every job behind it from being polled and fetched, and the job that could not be deleted is dropped from the state either way. Narrowing the catch past TorBoxError is how that rule gets lost" \
  --apply 'sed -i.bak "s@^    except Exception as err:  # noqa: BLE001 - the delete is best-effort\$@    except ValueError as err:  # noqa: BLE001 - the delete is best-effort@" "$F" && rm -f "$F.bak"'

# --- the in-flight ceiling --------------------------------------------------
#
# TorBox's ten slots are a limit, not a target. Measured over the retained
# window: nine of the ten were held by jobs 3-21h old while only 4 of 50
# submissions were ever fetched. `--max-inflight N` stops submitting for the
# pass once N jobs are in flight, and the module's own default is 0 -- the flag
# has to do nothing until an operator asks otherwise, and the unit asks for 6.
# A ceiling set too low trades wasted slots for idle ones.
#
# Every entry here leaves the flag looking present and working while it is not.
# The dangerous direction is the off-by-one and the ignored check: both look
# like the ceiling doing its job, in a log line that says it was reached, while
# the account goes back to ten jobs ageing out.

mutation usenet-blackhole-inflight-cap-off-by-one \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "\`>\` admits one more job than the operator asked for: a ceiling of 2 submits while 2 are already in flight, so the pass runs at 3 and the measurement is taken at a bound nobody set. It is invisible from the outside because the log line only appears on the pass AFTER the ceiling is exceeded, so a capped run looks capped. The check is \`>=\` because the ceiling is a count that must not be passed" \
  --apply 'sed -i.bak "s@max_inflight > 0 and inflight >= max_inflight:@max_inflight > 0 and inflight > max_inflight:@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-inflight-cap-ignored \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the whole flag, made inert. The pass offers every waiting NZB to the provider's ten again -- the pile-up of jobs 3-21h old against 4 of 50 ever fetched that the ceiling exists to measure away -- and every create is a call against the 60-an-hour budget, spent on an account that is already full. The banner still announces the cap, so the operator reads a capped run and gets the uncapped one" \
  --apply 'sed -i.bak "s@^        if max_inflight > 0 and inflight >= max_inflight:\$@        if False:@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-inflight-cap-counts-completed-jobs \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "counting rows in the state file rather than jobs holding a TorBox slot. A job TorBox reports complete stays in state[\"jobs\"] until its fetch succeeds, and one whose fetch keeps failing is never timed out either -- so every finished-but-unfetched release would spend a place against the ceiling for good, and the effective cap would fall pass by pass with nothing in the log to show why. The ceiling is about the provider's ten slots, and a completed job no longer holds one" \
  --apply 'sed -i.bak "s@ if not j.get(\"complete\"))@)@" "$F" && rm -f "$F.bak"'

mutation usenet-blackhole-inflight-cap-default-on \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the ceiling has to ship off: it is a measurement, and a default of 10 makes the provider's limit look like a chosen value while removing the only comparison the measurement needs. A pass with ten jobs already in flight then stops offering the eleventh before the flag was ever used, and nothing in argparse or the banner says a default put it there" \
  --apply 'sed -i.bak "s@type=non_negative_int, default=0,@type=non_negative_int, default=10,@" "$F" && rm -f "$F.bak"'

# --- usenet-blackhole.service: the in-flight ceiling ----------------------
#
# The module ships the cap inert on purpose, and that is the half every entry
# above guards. Nothing above looks at the unit, and the unit is where the
# ceiling actually rests: a stack that never passes the flag runs uncapped no
# matter how correct the module is.
#
# `sed -i.bak`, not the bare `sed -i` this was first written with: GNU sed
# reads `-i` as the in-place flag, BSD sed reads the script as a backup suffix,
# fails, and edits nothing -- so on this host both entries would have been
# reported as changing no file at all. tests/mutation/README.md names the same
# trap for the corpus as a whole.

mutation unit-inflight-cap-removed \
  --file scripts/usenet-blackhole.service \
  --bats tests/usenet-blackhole.bats \
  --test "usenet-blackhole: the shipped unit caps in-flight jobs below TorBox's ten slots" \
  --why "removing the flag from ExecStart returns the pass to --max-inflight 0, the state that submitted 46 jobs in one hour on 2026-09-18 while 60 sat incomplete" \
  --apply 'sed -i.bak "s@--report-failures --max-inflight 6@--report-failures@" "$F" && rm -f "$F.bak"'

mutation unit-inflight-cap-above-slots \
  --file scripts/usenet-blackhole.service \
  --bats tests/usenet-blackhole.bats \
  --test "usenet-blackhole: the shipped unit caps in-flight jobs below TorBox's ten slots" \
  --why "a ceiling at or above TorBox's ten concurrent slots cannot bound anything; set to 11 it is indistinguishable from no ceiling from the provider's side" \
  --apply 'sed -i.bak "s@--max-inflight 6@--max-inflight 11@" "$F" && rm -f "$F.bak"'

# --- scripts/usenet-blackhole.sh: the host I/O pressure gate --------------
#
# On 2026-09-18 the NAS sat at load 58 with io full avg10 between 78% and 81%
# for hours while a usenet pass went on submitting into the same pool every two
# minutes -- the pass lengthening the stall it was competing with. Every entry
# here either runs a pass exactly when the host is wedged or stops the stack
# downloading on a host that has no PSI to read, and the fail-open direction is
# the quieter of the two: a guard that cannot read /proc/pressure looks the same
# as a guard with nothing to report.

mutation pressure-gate-inverted \
  --file scripts/usenet-blackhole.sh \
  --bats tests/usenet-blackhole.bats \
  --test "usenet-blackhole: the gate is the only thing that changes when pressure crosses the limit" \
  --why "inverting the comparison runs the pass exactly when the host is stalled and skips it when the host is healthy -- the whole guard backwards, and the boundary test is what notices" \
  --apply 'sed -i.bak "s@exit !(seen >= limit)@exit !(seen < limit)@" "$F" && rm -f "$F.bak"'

mutation pressure-gate-threshold-hardcoded \
  --file scripts/usenet-blackhole.sh \
  --bats tests/usenet-blackhole.bats \
  --test "usenet-blackhole: the gate is the only thing that changes when pressure crosses the limit" \
  --why "ignoring PSI_IO_LIMIT and comparing against a literal makes the trip point unmeasurable and un-tunable on a host whose healthy baseline is not this one's" \
  --apply 'sed -i.bak "s@-v limit=\"\$PSI_IO_LIMIT\"@-v limit=\"999999\"@" "$F" && rm -f "$F.bak"'

mutation pressure-gate-fails-closed \
  --file scripts/usenet-blackhole.sh \
  --bats tests/usenet-blackhole.bats \
  --test "usenet-blackhole: no PSI on the host means the gate fails open" \
  --why "treating an unreadable /proc/pressure/io as stalled stops the stack downloading on every host without PSI, silently, and it would take the macOS half of this suite down with it. The reading has to be invented for this mutant to be observable at all: the reader's own exit status is discarded by the gate's \`|| true\`, so \`|| return 0\` alone is an equivalent mutant -- empty stdout either way, fail-open gate either way. Returning a number that looks stalled is what makes the defect reach the behaviour the fail-open test names" \
  --apply 'sed -i.bak "s@\[\[ -r \"\$path\" \]\] || return 1@[[ -r \"\$path\" ]] || { echo 100; return 0; }@" "$F" && rm -f "$F.bak"'

mutation pressure-gate-reads-some-not-full \
  --file scripts/usenet-blackhole.sh \
  --bats tests/usenet-blackhole.bats \
  --test "usenet-blackhole: a stalled host skips the pass before python runs" \
  --why "reading PSI's \`some\` instead of \`full\` inverts the guard's purpose: \`some\` counts a single stalled task and runs high on a merely busy box, so the pass would skip on healthy hosts and the stack would silently stop downloading -- the failure mode the fail-open test exists to prevent, arriving from the other direction" \
  --apply 'sed -i.bak "s@\$1 == \"full\"@\$1 == \"some\"@" "$F" && rm -f "$F.bak"'

mutation pressure-gate-failopen-silent \
  --file scripts/usenet-blackhole.sh \
  --bats tests/usenet-blackhole.bats \
  --test "usenet-blackhole: no PSI on the host means the gate fails open" \
  --why "an unreadable PSI reading that announces nothing is indistinguishable in the pass log from a guard that ran and found the host calm. Both leave the stack unprotected on a host the operator believes is being watched -- and the unreadable case is the one that hits every macOS box and every kernel built without PSI, which is where the first version of this gate silently did nothing. The range deletes BOTH reading-announcement branches, not just the first: an empty reading is caught by the \`-z\` branch, so deleting that one alone leaves the not-a-number branch announcing the same thing and the mutant survives while looking silenced" \
  --apply 'sed -i.bak "/elif \[\[ -z \"\$HOST_PRESSURE\" \]\]/,/so nothing can be compared against the limit/d" "$F" && rm -f "$F.bak"'

mutation pressure-gate-limit-unvalidated \
  --file scripts/usenet-blackhole.sh \
  --bats tests/usenet-blackhole.bats \
  --test "usenet-blackhole: a malformed PSI limit is announced and runs the pass unprotected" \
  --why "the case block accepting every value is the same as dropping it: awk then compares the limit as a string, \"95.00\" >= \"abc\" is false, and a host with a stalled reading runs the pass while PSI_IO_LIMIT says it is bounded. The gate looks armed and the limit is the thing that was wrong, so nothing downstream notices" \
  --apply 'sed -i.bak "s@PSI_IO_LIMIT_USABLE=false@PSI_IO_LIMIT_USABLE=true@" "$F" && rm -f "$F.bak"'

mutation pressure-gate-reading-unvalidated \
  --file scripts/usenet-blackhole.sh \
  --bats tests/usenet-blackhole.bats \
  --test "usenet-blackhole: a malformed PSI reading is announced and runs the pass unprotected" \
  --why "accepting every reading is the one path in this guard that fails CLOSED. awk compares a non-numeric \`seen\` as a string and \"garbage\" >= 20 is true, so a reading that is not a measurement trips the gate, skips the pass, and quotes the garbage back as a pressure figure -- a stack that has silently stopped downloading on a host the operator has no reason to look at. A truncated read is enough to produce one, and the pass log is the only place it would show" \
  --apply 'sed -i.bak "s@HOST_PRESSURE_USABLE=false@HOST_PRESSURE_USABLE=true@" "$F" && rm -f "$F.bak"'

# --- the skip trace the status page reads ---------------------------------
#
# The gate exits before python, so a skipped pass writes neither of the two
# files scripts/usenet-blackhole-status.sh renders. It appends to a third one
# instead, and that is the only place "nothing is being polled" appears: the
# stall clock is derived at render time, so without it a long stall paints every
# in-flight job `stalled` under a freshly stamped `Generated` and reads as a
# stack full of dead downloads.
#
# Two writers, one file, and the second is the half that is easy to leave out:
# the file has to be cleared when a pass runs, or the page goes on saying passes
# are being skipped on a host that recovered hours ago.

mutation pressure-gate-skip-not-recorded \
  --file scripts/usenet-blackhole.sh \
  --bats tests/usenet-blackhole.bats \
  --test "usenet-blackhole: a skipped pass leaves a trace the status page can read" \
  --why "the skip is invisible without this line. The gate exits before python, so neither the state file nor the failed log is written, and usenet.lan shows a fresh timestamp over jobs whose stall clock keeps climbing -- the whole page describing a fault that is in fact the protection working" \
  --apply 'sed -i.bak "/^  record_skipped_pass /d" "$F" && rm -f "$F.bak"'

mutation pressure-gate-skip-record-outlives-the-pass \
  --file scripts/usenet-blackhole.sh \
  --bats tests/usenet-blackhole.bats \
  --test "usenet-blackhole: the skip trace counts the run and clears when a pass runs" \
  --why "a trace that is never cleared turns the page into a permanent claim that the last pass was skipped. The run length also stops meaning anything: it becomes the number of skips since the file was created rather than the current run, on a host that may have been passing normally for days" \
  --apply 'sed -i.bak "/^rm -f \"\$SKIP_PATH\"/d" "$F" && rm -f "$F.bak"'

mutation status-drop-the-skip-notice \
  --file scripts/lib/usenet_status.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the shell half records the skip and the renderer half has to show it; a page that reads the file and prints nothing is the same page as before the fix -- twelve jobs painted \`stalled\` with a fresh \`Generated\` timestamp and no reason anywhere. The JSON keeps the record either way, so only a renderer test notices" \
  --apply 'sed -i.bak "s@^    if not isinstance(skipped, dict):\$@    if True:@" "$F" && rm -f "$F.bak"'

# --- the fetch set has no ceiling ------------------------------------------
#
# The ceiling that shipped with PR #101 counts jobs TorBox has NOT finished.
# The local I/O that wedged the host comes from the jobs it HAS finished, and
# that population had no bound at all on 2026-09-20: 21 releases owed local
# I/O while --max-inflight read 3.

mutation usenet-blackhole-fetch-set-unbounded \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "restores the line that let a single admitted pass pull 21 releases, two of them 30-38 GB, three at a time for 53m12s. Measured that day: load went 8.47 -> 50.18 and io full avg10 to 81.91%, and the value the operator's ceiling compared against was 3 because it counts jobs still AT TorBox. The pass cost 86.22 GB logical and 170.6 GB of platter writes to deliver a few GB of media" \
  --apply 'sed -i.bak "s@to_fetch = owed\[:FETCH_WORKERS\]@to_fetch = owed@" "$F" && rm -f "$F.bak"'
