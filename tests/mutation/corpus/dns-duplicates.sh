# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/lib/check-dns-duplicates.sh.
#
# Safe to run: the oracle overrides has_nas_config / is_nas_reachable /
# is_ssh_available / ssh_to_nas, so no mutation here can open an SSH connection
# or read anything outside $BATS_TEST_TMPDIR.

mutation dns-empty-dnsmasq-is-an-all-clear \
  --file scripts/lib/check-dns-duplicates.sh \
  --bats tests/lib-dns-duplicates.bats \
  --test "dns-duplicates: an unreadable dnsmasq config is a skip, not an all-clear" \
  --why "removes the empty-dnsmasq guard. The intersection of nothing with anything is empty, so the check prints 'No duplicate DNS entries' having read nothing at all - a green result manufactured from a failed read, which is the exact shape of every guard this repo has had to throw out" \
  --apply 'perl -0pi -e "s/    if \[\[ -z \\\"\\\$dnsmasq_domains\\\" \]\]; then\n        echo \\\"    SKIP: Could not read dnsmasq config\\\"\n        return 0\n    fi\n//" "$F"'

mutation dns-name-match-word-bounded \
  --file scripts/lib/check-dns-duplicates.sh \
  --bats tests/lib-dns-duplicates.bats \
  --test "dns-duplicates: DEFECT - a name is matched whole, not as a hyphen-bounded word" \
  --why "restores grep -w, which counts a hyphen as a word boundary - so 'sonarr' matches inside 'sonarr-4k' and the check reports a conflict between two names that resolve to different hosts" \
  --apply 'sed -i "s@grep -qxF -- \"\$domain\"@grep -qw \"\$domain\"@" "$F"'

mutation dns-name-match-as-regex \
  --file scripts/lib/check-dns-duplicates.sh \
  --bats tests/lib-dns-duplicates.bats \
  --test "dns-duplicates: DEFECT - a name is matched literally, not as a regex" \
  --why "drops the fixed-string flag, so a name is compiled as a pattern and a dot in it matches any character" \
  --apply 'sed -i "s@grep -qxF -- \"\$domain\"@grep -qx -- \"\$domain\"@" "$F"'

mutation dns-match-never-matches \
  --file scripts/lib/check-dns-duplicates.sh \
  --bats tests/lib-dns-duplicates.bats \
  --test "dns-duplicates: a genuine exact match is still caught" \
  --why "tightens the match until nothing can ever match. Both DEFECT tests above assert that something is NOT reported, so they would both pass against a check that reports nothing ever. This is the entry that stops the fix for a false-positive from silently becoming a check that is switched off" \
  --apply 'sed -i "s@grep -qxF -- \"\$domain\"@grep -qxF -- \"zz-no-such-name-\$domain\"@" "$F"'
