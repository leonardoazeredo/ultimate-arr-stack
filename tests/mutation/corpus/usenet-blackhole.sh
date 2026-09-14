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
  --why "the fixed-range sed that prints the header ran one line long and emitted the SCRIPT_DIR assignment below it, so --help ended with shell source dressed as documentation. Nothing asserted the output, so it shipped that way" \
  --apply 'perl -pi -e "s/\Qsed -n '"'"'3,27p'"'"'\E/sed -n '"'"'3,30p'"'"'/" "$F"'

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
  --apply 'sed -i "s@^FETCH_WORKERS = 3\$@FETCH_WORKERS = 1@" "$F"'

mutation usenet-blackhole-fetch-pool-unbounded \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "an uncapped pool starts an unrar per completed release at once. The unpack is CPU-bound and this runs on a NAS that is also transcoding, with the arr's importer reading the same disk, so the bound is what keeps a large batch from stalling everything else on the box" \
  --apply 'sed -i "s@max_workers=min(FETCH_WORKERS, len(to_fetch))@max_workers=None@" "$F"'

mutation usenet-blackhole-fetch-output-interleaved \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "each fetch collects its own lines and the caller prints them whole. Handing the shared stream to three threads instead puts one release's progress inside another's, which is how a log stops being readable at exactly the moment -- several concurrent failures -- when someone needs it" \
  --apply 'sed -i "s@out=lines.append)@out=print)@" "$F"'

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
  --apply 'sed -i "s@^    if not lowered.startswith(FAILED_STATES):\$@    if lowered not in (\"failed\", \"error\"):@" "$F"'

mutation usenet-blackhole-failure-reason-dropped \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the parenthetical is the whole value of the message: 'missing articles' and 'the provider broke' both end the job, and only one is worth another attempt later. Logging the raw state instead keeps the answer buried in a URL that ends in not-complete" \
  --apply 'sed -i "s@^        inner = lowered.split(\"(\", 1)\[1\].rsplit(\")\", 1)\[0\].strip()\$@        inner = \"\"@" "$F"'

mutation usenet-blackhole-failure-substring-match \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "a substring match anywhere in the state reads a healthy state as a failure. The prefix is what TorBox varies the tail of, and nothing else" \
  --apply 'sed -i "s@^    if not lowered.startswith(FAILED_STATES):\$@    if not any(f in lowered for f in FAILED_STATES):@" "$F"'

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
  --apply 'sed -i "s@^            out(f\"    ! {release}: rate limited, pausing submissions: {err}\")\$@            out(f\"    ! {release}: rate limited\")\n            continue\n            break@g" "$F"'

mutation usenet-blackhole-backoff-not-honoured \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "recording the deadline and then never checking it is the same as no backoff at all, with extra state. The marker is written from a pass that has already been refused, so nothing else in the run would notice" \
  --apply 'sed -i "s@^    paused_until = in_backoff(state)\$@    paused_until = None@" "$F"'

mutation usenet-blackhole-429-read-as-an-ordinary-error \
  --file scripts/lib/usenet_blackhole.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "a 429 that is not distinguished from a 500 is retried on the next pass like any other transient failure. That is the entire bug: the status is the one signal that says stop asking rather than try again" \
  --apply 'sed -i "s@^        if code == \"429\":\$@        if False:@" "$F"'
