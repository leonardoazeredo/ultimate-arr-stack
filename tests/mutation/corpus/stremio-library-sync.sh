# shellcheck shell=bash
# Corpus: scripts/stremio-library-sync.sh and the bridge it drives.
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
#
# Two halves, one oracle each. The Python half -- the filter that decides what
# counts as a library item, the pacing that keeps a first run from becoming a
# burst, and the two ways an API answer is misread -- runs through
# tests/python-suite.bats. The shell half runs through
# tests/stremio-library-sync.bats, which drives the real script against a stub
# python3.
#
# `perl -0777 -pi` and `python3 -c`, not `sed -i`: an entry should replay on the
# Mac as well as on Linux, and BSD sed reads -i's next argument as a backup
# suffix. See tests/mutation/README.md.

# --- the temp filter comes off ---------------------------------------------
#
# The single most expensive defect available in this module, and the reason the
# filter is written the way it is. `temp` is what Stremio writes when a title is
# WATCHED rather than ADDED -- 883 of this account's 1078 records on 2026-09-17.
# Lift the filter and the pass reads the household's viewing history as a
# library and requests it, which is both a request storm and a wrong answer:
# nothing in that set was ever asked for. Nothing errors, and the log reads like
# an ordinary busy pass.

mutation stremio-library-temp-filter-dropped \
	--file scripts/lib/stremio_library.py \
	--bats tests/python-suite.bats \
	--test "the extracted modules pass their pytest suite" \
	--why "temp marks a record Stremio wrote because the title was watched, not added, and they outnumber the real library six to one -- 883 of 1078 records when this was measured. Without the filter, the pass treats the account's viewing history as things to download: 933 titles nobody asked for, through Seerr, to Sonarr and Radarr. Nothing raises, nothing is logged as unusual, and the failure is only visible as a queue full of films the household watched once in 2023" \
	--apply 'perl -0777 -pi -e "s/\Q        if item.get(\"removed\") or item.get(\"temp\"):\E/        if item.get(\"removed\"):/" "$F"'

# --- the removed filter comes off ------------------------------------------
#
# The other half of the same line, and a different failure: a tombstone is a
# record the user deliberately deleted. Re-requesting one downloads something
# they removed on purpose, and because the record survives the delete by design
# it will be there on every pass until the state file remembers it.

mutation stremio-library-removed-filter-dropped \
	--file scripts/lib/stremio_library.py \
	--bats tests/python-suite.bats \
	--test "the extracted modules pass their pytest suite" \
	--why "removed marks a tombstone: the record survives the delete so other clients learn about it. Reading one as a library item means every title the user has ever deleted from Stremio gets requested -- 933 of 1078 records here -- and the pass re-requests what it re-adds, so the arrs fill with films somebody removed on purpose" \
	--apply 'perl -0777 -pi -e "s/\Q        if item.get(\"removed\") or item.get(\"temp\"):\E/        if item.get(\"temp\"):/" "$F"'

# --- the per-pass cap stops bounding the pass -------------------------------
#
# The two halves of the pacing rule are one line apart: the slice bounds how
# many requests a pass makes, and because the state is written from what the
# loop acted on, it also keeps everything past the cap pending for the next
# pass. Remove the slice and both halves go at once -- the burst the cap exists
# to prevent, plus every one of those titles recorded as handled.

mutation stremio-library-cap-dropped \
	--file scripts/lib/stremio_library.py \
	--bats tests/python-suite.bats \
	--test "the extracted modules pass their pytest suite" \
	--why "the slice is what makes a ten-minute timer safe. Without it a pass requests everything pending at once -- measured 2026-09-17, 122 of this library's 145 items are in neither arr -- which is the shape of the burst that earned this TorBox account a 90-minute refusal on 2026-09-13. It also breaks the resume: the extra titles are recorded as requested, so the next pass skips them and the work is silently lost rather than retried" \
	--apply 'perl -0777 -pi -e "s/\Q        pending = pending[:max_requests]\E/        pending = list(pending)/" "$F"'

# --- an expired key reads as an empty library -------------------------------
#
# The failure mode with no symptom anywhere downstream. This API answers HTTP
# 200 with an `error` body for a bad key rather than a 401, so a caller that
# checks only the status sees success -- and a sync that keeps reporting "no new
# items" while requesting nothing is indistinguishable from a quiet week.

mutation stremio-library-expired-key-read-as-success \
	--file scripts/lib/stremio_library.py \
	--bats tests/python-suite.bats \
	--test "the extracted modules pass their pytest suite" \
	--why "a wrong or expired key comes back as HTTP 200 with {'error': {'code': 1, 'message': 'Session does not exist'}} -- measured 2026-09-17. Drop this branch and the message never reaches the operator: the pass raises on the missing result list instead, so the one line that says WHICH thing is wrong is gone, and the documented recovery (log in again, re-copy auth.key) no longer matches what the log says" \
	--apply 'perl -0777 -pi -e "s/\Q        if error:\E/        if False:/" "$F"'

# --- "I could not ask" reads as "it is not there" ---------------------------
#
# The inversion that turns a Seerr outage into a request storm. A 404 genuinely
# means Seerr has never heard of the title and is the case worth requesting;
# every other status means the question was never answered, and answering it
# with a request is how a briefly unreachable portal gets asked for everything
# at once.

mutation stremio-library-http-error-read-as-not-there \
	--file scripts/lib/stremio_library.py \
	--bats tests/python-suite.bats \
	--test "the extracted modules pass their pytest suite" \
	--why "only a 404 is Seerr answering that it has no record of this title. Widen that to any HTTP error and a 500, a 502 from a restarting container or a 429 becomes 'not there', so the pass creates requests it could not check -- and Seerr's own dedupe is the only thing left between an outage and a request for every pending title at once" \
	--apply 'perl -0777 -pi -e "s/\Q            if err.status == 404:\E/            if err.status is not None:/" "$F"'

# --- the first run requests instead of baselining ---------------------------
#
# The deliberate pause that makes the first run safe. `--backfill` is how an
# operator asks for the existing library; the default records it and stops.
# Invert the default and installing the timer is itself the burst.

mutation stremio-library-first-run-does-not-baseline \
	--file scripts/lib/stremio_library.py \
	--bats tests/python-suite.bats \
	--test "the extracted modules pass their pytest suite" \
	--why "the baseline is the whole reason the first run is allowed to be automatic. Without it, 'enable --now' on the timer -- or any run after the state file is lost -- reads 145 existing library items as 145 new ones and starts requesting them, three at a time forever. Measured 2026-09-17: 122 of those 145 are in neither arr, so the backlog is real and the burst is real, and it arrives with no operator action beyond installing the schedule" \
	--apply 'perl -0777 -pi -e "s/\Q        if not backfill:\E/        if False:/" "$F"'

# --- the wrapper passes --apply on a dry run --------------------------------
#
# The exact bug usenet-blackhole.sh shipped, reproduced here as a mutation. A
# dry run that applies is worse than no dry run, because the dry run is the mode
# an operator uses to decide whether applying is safe.

mutation stremio-library-shell-dry-run-passes-apply \
	--file scripts/stremio-library-sync.sh \
	--bats tests/stremio-library-sync.bats \
	--test "^stremio-library-sync: a dry run does not pass --apply to python" \
	--why "the banner says DRY RUN while the pass creates real Seerr requests, which is the one thing a dry run must never do -- it is how an operator checks what a change would do before letting it happen. usenet-blackhole.sh shipped this exact defect, from \${APPLY:+--apply}: ':+' tests for non-empty and APPLY=false is non-empty, so the flag went on every invocation" \
	--apply 'python3 -c "import sys;p=sys.argv[1];s=open(p).read();old=\"if \$APPLY; then PY_ARGS+=(--apply); fi\";new=\"PY_ARGS+=(--apply)\";assert old in s, old;s=s.replace(old,new,1);open(p,\"w\").write(s)" "$F"'

# --- the missing-key guard comes off ----------------------------------------
#
# The guard exists because the key's absence is silent: the API answers 200 with
# an error body, so nothing downstream reports an auth problem. With the guard
# gone the failure surfaces as a python error string rather than as the sentence
# naming the variable an operator has to set.

mutation stremio-library-shell-key-guard-removed \
	--file scripts/stremio-library-sync.sh \
	--bats tests/stremio-library-sync.bats \
	--test "^stremio-library-sync: refuses to run without STREMIO_AUTH_KEY" \
	--why "with no key, nothing in the stack reports an auth failure -- Stremio's API answers HTTP 200 with a body saying the session does not exist, and the pass then fails with a generic non-zero exit. The guard is what turns that into a line naming STREMIO_AUTH_KEY in the log the timer writes, which is the difference between a five-minute fix and an afternoon spent on the wrong service" \
	--apply 'python3 -c "import sys;p=sys.argv[1];s=open(p).read();old=\"if [[ -z \\\"\$STREMIO_KEY\\\" ]]; then\";new=\"if false; then\";assert old in s, old;s=s.replace(old,new,1);open(p,\"w\").write(s)" "$F"'

# --- the User-Agent comes off -----------------------------------------------
#
# The defect that actually took this feature down, on 2026-09-18. Cinemeta
# redirected to cinemeta-live.strem.io, whose Cloudflare rule refuses urllib's
# default `Python-urllib/3.11` signature with `HTTP 403  error code: 1010`.
# Measured: the same URL answers 200 with any other name. With no User-Agent
# every metadata lookup fails -- so this is not a politeness header, it is the
# difference between a working sync and a dead one.

mutation stremio-library-user-agent-dropped \
	--file scripts/lib/stremio_library.py \
	--bats tests/python-suite.bats \
	--test "the extracted modules pass their pytest suite" \
	--why "without a User-Agent, urllib sends Python-urllib/3.11, and Cinemeta's Cloudflare rule refuses that signature with HTTP 403 error 1010 -- measured 2026-09-18, alongside the same URL answering 200 to any other name. Every lookup fails, so the sync stops entirely rather than degrading: ten hours of identical failed passes, one every ten minutes, and the only line in the timer's log naming a single library id instead of the provider" \
	--apply 'python3 -c "import sys;p=sys.argv[1];s=open(p).read();old=\"        hdrs.setdefault(\\\"User-Agent\\\", USER_AGENT)\n\";assert old in s, old;s=s.replace(old,\"\",1);open(p,\"w\").write(s)" "$F"'

# --- one bad lookup ends the whole pass -------------------------------------
#
# The other half of that outage, and the reason it lasted ten hours instead of
# ten minutes. `resolve()` used to be called outside any try, so the first
# failure propagated out of run(): the pass made no request, saved no state, and
# died on the same title every time. Nothing was lost, but nothing progressed
# either, and the log said the same thing 60 times an hour.

mutation stremio-library-lookup-failure-ends-the-pass \
	--file scripts/lib/stremio_library.py \
	--bats tests/python-suite.bats \
	--test "the extracted modules pass their pytest suite" \
	--why "a lookup that could not be made is not an answer, and one odd title must not decide the fate of everything behind it in the queue. Propagating it ends the pass on the first failure and leaves every later title unexamined for another ten minutes -- and if the provider is unhappy for an hour, that is six passes that each examine one title. With the handler in place the pass notes it, leaves the item pending for a retry, and carries on to the next" \
	--apply 'python3 -c "import sys;p=sys.argv[1];s=open(p).read();old=\"            lookup_failures += 1\";new=\"            raise err\";assert old in s, old;s=s.replace(old,new,1);open(p,\"w\").write(s)" "$F"'

# --- the queue check is not reached ----------------------------------------

mutation stremio-sync-queue-check-removed \
  --file scripts/stremio-library-sync.sh \
  --bats tests/stremio-library-sync.bats \
  --test "stremio-library-sync: a deep outbox stands the pass down" \
  --why "the guard is a library and a call site, and only the call site is load-bearing. With the check gone the sync keeps requesting while the outbox is 588 deep and the drain is stopped -- the arrangement that built the backlog which wedged the host on 2026-09-20. Nothing else in the suite notices, because the library's own tests still pass" \
  --apply 'perl -0777 -pi -e "s/\Qif outbox_over_high_water \E.*?\nfi\n//s" "$F"'
