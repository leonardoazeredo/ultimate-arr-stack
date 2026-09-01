# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/lib/check-secrets.sh.
#
# Safe to run: every test in tests/lib-secrets.bats replaces both of the seams
# this check reads the world through - get_files_to_scan and read_file_content
# - with functions bound to $BATS_TEST_TMPDIR, so no mutation here can reach
# the real repository, let alone the NAS.
#
# Three of the four defects below were guards that could not fire. That is the
# recurring shape in this repo, and it is worth naming that it was found here
# in the check that gates every commit: the file had exactly one test, for one
# of nine patterns, and that test passed against all three.

mutation secrets-allowlist-excuses-the-whole-file \
  --file scripts/lib/check-secrets.sh \
  --bats tests/lib-secrets.bats \
  --test "secrets: a placeholder excuses only itself, not a real value beside it" \
  --why "restores the joined-set allowlist. grep -o collects every hit in a file into one string, and testing that string as a unit means a single PASSWORD=your-password-here line excuses every real credential sitting beside it. Measured before the fix: a file holding that line plus SSH_PASSWORD=<a real 22-character value> made check_secrets return 0 and print nothing at all. A test that puts one hit in a file cannot see this, which is why the oracle uses two" \
  --apply 'sed -i "s@hits=.(echo \\\"\\\$hits\\\" | grep -viE \\\"(\\\$allow)\\\") || true@if echo \\\"\\\$hits\\\" | grep -qiE \\\"(\\\$allow)\\\"; then hits=\\\"\\\"; fi@" "$F"'

mutation secrets-status-is-a-count \
  --file scripts/lib/check-secrets.sh \
  --bats tests/lib-secrets.bats \
  --test "secrets: the status is a boolean, so 256 findings still fail" \
  --why "restores 'return \$errors'. An unbounded count in one byte wraps, so exactly 256 findings returned 0 and scripts/pre-commit:68 - which is 'if check_secrets; then', a boolean read all along - reported the tree clean. Same defect and same fix as check_doc_links in 9cc4b2d; this entry exists so the third instance cannot come back quietly" \
  --apply 'perl -0pi -e "s/    if \[\[ \\\$errors -eq 0 \]\]; then\n        return 0\n    fi\n/    return \\\$errors\n    if false; then\n/" "$F"'

mutation secrets-cf-token-allowlist-swallows-the-key-name \
  --file scripts/lib/check-secrets.sh \
  --bats tests/lib-secrets.bats \
  --test "secrets: pattern 2 reports a Cloudflare API token" \
  --why "puts 'token' back in pattern 2's allowlist. The allowlist is tested against the whole match, and every match begins with the literal key name CF_DNS_API_TOKEN, so a case-insensitive 'token' excuses all of them - the pattern could never fire against a real Cloudflare token, from the day it was written. The placeholder it was added for, CF_DNS_API_TOKEN=your_token_here, is already covered twice by 'your' and 'here'" \
  --apply 'sed -i "s@'\''CF_DNS_API_TOKEN=\[A-Za-z0-9_-\]{35,45}\$'\'' '\''xxx'\''@'\''CF_DNS_API_TOKEN=[A-Za-z0-9_-]{35,45}\$'\'' '\''xxx|token'\''@" "$F"'

mutation secrets-bcrypt-allowlist-made-uniform \
  --file scripts/lib/check-secrets.sh \
  --bats tests/lib-secrets.bats \
  --test "secrets: pattern 4 does NOT accept xxx as a placeholder" \
  --why "adds 'xxx' to pattern 4's allowlist, which is the tidy-up any reader is tempted by: eight patterns pass 'xxx' and this one does not. It is deliberate. xxx is a plausible substring of a real 53-character base64 bcrypt tail, so accepting it exempts genuine hashes. The asymmetry is pinned so that making the allowlists look consistent cannot silently widen one of them" \
  --apply 'sed -i "s@'\''..\$2\[aby\].\$\[0-9\]{2}.\$\[A-Za-z0-9./\]{50,}'\'' '\'''\''@\\0@; s@{50,}'\'' '\'''\'' '\'''\''@{50,}'\'' '\''xxx'\'' '\'''\''@" "$F"'
