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
