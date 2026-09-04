# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/lib/check-image-versions.sh.
#
# Safe to run: every test in tests/lib-image-versions.bats calls the pure
# helpers directly against a cache file in $BATS_TEST_TMPDIR. None of them
# reaches _query_dockerhub/_query_ghcr, so no mutation here touches a registry.

mutation stat-bsd-flag \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a fresh cache returns the stored tag" \
  --why "restores the inline 'stat -f %m || stat -c %Y' chain, which reads as a portable BSD-then-GNU fallback but is not: -f is --file-system on GNU, a VALID flag printing a filesystem report to stdout while exiting 1, so the fallback appends the real mtime to that report and the arithmetic consuming it dies on a syntax error - aborting _cache_get, so the cache was never read at all and every commit re-queried 31 registries" \
  --apply 'perl -0pi -e "s/cache_age=\\\$\\(\\( \\\$\\(date \\+%s\\) - \\\$\\(_file_mtime \\\"\\\$_IMAGE_CACHE\\\"\\) \\)\\)/cache_age=\\\$((  \\\$(date +%s) - \\\$(stat -f %m \\\"\\\$_IMAGE_CACHE\\\" 2>\\/dev\\/null || stat -c %Y \\\"\\\$_IMAGE_CACHE\\\" 2>\\/dev\\/null || echo 0) ))/" "$F"'

mutation mtime-shape-unchecked \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a missing file reads as mtime 0, not as garbage" \
  --why "drops the fallback to 0, so an unreadable file yields an empty mtime and the staleness arithmetic silently treats the cache as written at the epoch - permanently stale rather than permanently fresh, which is the same class of invisible wrongness in the other direction" \
  --apply 'sed -i "s@^    echo 0\$@    :@" "$F"'

mutation find-latest-ignores-segment-depth \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: candidates with a different segment depth are rejected" \
  --why "without the dot-count match a two-segment tag competes with a three-segment pin, which is how 'redis 7-alpine -> 8' style noise becomes a recommendation to move to a tag that means something entirely different" \
  --apply 'sed -i "s@^        \[\[ \"\$tag_dots\" -ne \"\$current_dots\" \]\] \&\& continue\$@        :@" "$F"'

mutation find-latest-ignores-v-prefix \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a v-prefixed current tag only matches v-prefixed tags" \
  --why "mixing v-prefixed and bare tags makes the checker recommend a tag that does not exist under the name it printed, so the suggested pin fails to pull" \
  --apply 'perl -0pi -e "s/            \[\[ \\\"\\\$tag\\\" != v\\* \]\] && continue\n/            :\n/" "$F"'
