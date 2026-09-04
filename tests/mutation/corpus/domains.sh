# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/lib/check-domains.sh.
#
# Safe to run: the oracle overrides has_nas_config, get_nas_ip, get_domain,
# dig and curl as shell functions, and redirects TMPDIR into the test's own
# directory. No mutation here can reach the network or write outside it.

mutation domains-tmpdir-unchecked \
  --file scripts/lib/check-domains.sh \
  --bats tests/lib-domains.bats \
  --test "domains: DEFECT - an unusable temp dir is a skip, not fourteen failures" \
  --why "restores the unchecked mktemp -d. On failure tmpdir is empty, every touch becomes a write to the filesystem ROOT, and all fourteen names are reported as not resolving - a DNS verdict manufactured entirely out of a local filesystem error" \
  --apply 'sed -i "s@if ! tmpdir=\$(mktemp -d); then@if ! tmpdir=\$(mktemp -d) \&\& false; then@" "$F"'

mutation domains-empty-nas-ip-queried-anyway \
  --file scripts/lib/check-domains.sh \
  --bats tests/lib-domains.bats \
  --test "domains: an undeterminable NAS IP is a skip, not a query against nothing" \
  --why "drops the empty-IP guard, so dig is handed an @ with no server after it and falls back to the system resolver. The query answers - from the wrong place - and fourteen names read as healthy without Pi-hole having been consulted at all" \
  --apply 'sed -i "s@if \[\[ -z \"\$pihole_ip\" \]\]; then@if false; then@" "$F"'

mutation domains-dig-server-dropped \
  --file scripts/lib/check-domains.sh \
  --bats tests/lib-domains.bats \
  --test "domains: it asks Pi-hole by IP, with a bounded timeout" \
  --why "removes the @server argument. Same failure as above reached from the other side: the names resolve via whatever the machine's resolver says, which on a developer laptop with a working VPN is a green check for a Pi-hole that is not running" \
  --apply 'sed -i "s|@\"\$pihole_ip\"||" "$F"'

mutation domains-dig-unbounded \
  --file scripts/lib/check-domains.sh \
  --bats tests/lib-domains.bats \
  --test "domains: it asks Pi-hole by IP, with a bounded timeout" \
  --why "removes +time and +tries. Against a NAS that is simply down, fourteen unbounded digs is a commit that hangs - the bounded timeout is the only reason this check can live in a hook at all. Nothing about the RESULT changes, which is why the assertion is on the argv" \
  --apply 'sed -i "s@+time=2 +tries=1 @@g" "$F"'

mutation domains-missing-dig-reads-as-all-down \
  --file scripts/lib/check-domains.sh \
  --bats tests/lib-domains.bats \
  --test "domains: no dig is a skip" \
  --why "drops the command -v dig guard. Without dig every name comes back empty, so a machine that simply lacks bind9-dnsutils reports the entire stack as unreachable - a red check that says nothing about DNS" \
  --apply 'sed -i "s@if ! command -v dig &>/dev/null; then@if false; then@" "$F"'

mutation domains-lan-failure-still-all-clear \
  --file scripts/lib/check-domains.sh \
  --bats tests/lib-domains.bats \
  --test "domains: one name failing is named, and suppresses the all-clear" \
  --why "prints the .lan all-clear unconditionally, so the summary line says every name resolves on the same run that just listed the ones that did not. The FAIL lines are still there - which is worse, because the last line read is the wrong one" \
  --apply 'sed -i "s@if \[\[ \$lan_fail -eq 0 \]\]; then@if true; then@" "$F"'

mutation domains-http-regex-unanchored \
  --file scripts/lib/check-domains.sh \
  --bats tests/lib-domains.bats \
  --test "domains: a code that merely CONTAINS an accepted one is rejected" \
  --why "unanchors the accepted-code regex, so 2000 and 4030 pass. A malformed code from a proxy in front of the tunnel then reads as healthy" \
  --apply 'sed -i "s@\\^(200|301|302|303|307|308|401|403)\\\$@(200|301|302|303|307|308|401|403)@" "$F"'

mutation domains-auth-refusal-rejected \
  --file scripts/lib/check-domains.sh \
  --bats tests/lib-domains.bats \
  --test "domains: every accepted HTTP code is accepted" \
  --why "drops 401 and 403 from the accepted set. Both services answer an unauthenticated probe with a refusal, and a refusal proves the tunnel and the router are working - so this makes the check cry wolf on a perfectly healthy stack, which is how a check stops being read" \
  --apply 'sed -i "s@|401|403@@" "$F"'

mutation domains-nodns-reads-as-ok \
  --file scripts/lib/check-domains.sh \
  --bats tests/lib-domains.bats \
  --test "domains: an external name that does not resolve is not called over HTTPS" \
  --why "files an external name that did not resolve at all under .ok. A name with no DNS record is then counted as accessible - the single most consequential direction to get wrong here, because the tunnel being down is exactly what this half exists to notice" \
  --apply 'sed -i "s@.nodns@.ok@" "$F"'

mutation domains-blocks-the-commit \
  --file scripts/lib/check-domains.sh \
  --bats tests/lib-domains.bats \
  --test "domains: it returns 0 even when everything fails" \
  --why "returns the warning count instead of 0. The file is documented warnings-only and scripts/pre-commit calls it accordingly; this turns a house whose internet is briefly down into a repository nobody can commit to. The count also truncates to one byte on the way out, so sixteen warnings and 272 are not distinguishable" \
  --apply 'sed -i "s@^    return 0\$@    return \$warnings@" "$F"'

mutation domains-tmpdir-leaked \
  --file scripts/lib/check-domains.sh \
  --bats tests/lib-domains.bats \
  --test "domains: it leaves no temp directory behind" \
  --why "stops removing the .lan temp dir. Every commit then leaves a directory of fourteen empty marker files in TMPDIR forever, and nothing about the check's output changes to say so" \
  --apply 'sed -i "s@    rm -rf \"\$tmpdir\"@@" "$F"'
