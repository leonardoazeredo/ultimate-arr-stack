# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/dns-rollback.sh.
#
# Safe to run: the script under test only ever reaches a stub `uci`, a stub
# dnsmasq init, a stub firewall init and a stub dig, all installed under
# $BATS_TEST_TMPDIR by tests/helpers/stubs.bash. Nothing here can touch a real
# router.
#
# The two mutations that matter most are dns-rollback-lan-only and
# dns-rollback-selfcheck-any-value: those are the two failures the plan's review
# record found in an earlier draft of this script, and each would have left the
# house pointing at a resolver that cannot answer while the script printed
# success.

mutation dns-rollback-lan-only \
  --file scripts/dns-rollback.sh \
  --bats tests/dns-rollback.bats \
  --test "dns-rollback: all four pools are reverted, not just lan" \
  --why "Drops the maintenance pool from the default pool list, which is how an earlier draft of this script shipped. dhcp.lan carries the fewest clients, so the omission is invisible until the break-glass host is the only one left and it is pointed at a resolver that is about to be retired" \
  --apply 'perl -0pi -e "s/:-lan vlan10 vlan20 vlan30/:-vlan10 vlan20 vlan30/" "$F"'

mutation dns-rollback-no-dnsmasq-reload \
  --file scripts/dns-rollback.sh \
  --bats tests/dns-rollback.bats \
  --test "dns-rollback: dnsmasq is reloaded after the commit" \
  --why "Removes both service reloads. uci commit emits no config.change event - nothing calls /sbin/reload_config except /etc/init.d/boot - so the reverted pools sit in flash while dnsmasq keeps advertising the resolver the rollback was supposed to undo, and the self-check still passes because it reads uci, not the running server" \
  --apply 'perl -0pi -e "s/^run .*_INIT\" reload\n//mg" "$F"'

mutation dns-rollback-bare-commit \
  --file scripts/dns-rollback.sh \
  --bats tests/dns-rollback.bats \
  --test "dns-rollback: every uci commit names its package" \
  --why "Strips the package name from all three commits, turning them into a bare 'uci commit'. That commits every half-applied change in every config file on the router, not just dhcp, adguardhome and firewall" \
  --apply 'perl -0pi -e "s/commit dhcp/commit/; s/commit adguardhome/commit/; s/commit firewall/commit/" "$F"'

mutation dns-rollback-selfcheck-any-value \
  --file scripts/dns-rollback.sh \
  --bats tests/dns-rollback.bats \
  --test "dns-rollback: a pool left un-reverted fails the script" \
  --why "Degrades the self-check from 'this pool advertises the NAS resolver' to 'this pool has some value'. The stronger form is the whole point: a pool still handing out a router address is exactly the state the rollback was run to fix, and it satisfies a check that only asks whether a value is present" \
  --apply 'perl -0pi -e "s/if \[ \"\x24advertised\" = \"6,\x24NAS_RESOLVER\" \]; then/if [ -n \"\x24advertised\" ]; then/" "$F"'

mutation dns-rollback-dryrun-ignored \
  --file scripts/dns-rollback.sh \
  --bats tests/dns-rollback.bats \
  --test "dns-rollback: DRY_RUN prints the sequence and changes nothing" \
  --why "Hard-codes DRY_RUN to 0, so the rehearsal flag is ignored and the script writes to the box anyway. The rehearsal in 0.5 exists precisely so the rollback kit can be proven without touching production; a rehearsal that mutates is worse than no rehearsal, because it is believed" \
  --apply 'perl -0pi -e "s/\x24\{DRY_RUN:-0\}/0/" "$F"'

mutation dns-rollback-preflight-accepts-anything \
  --file scripts/dns-rollback.sh \
  --bats tests/dns-rollback.bats \
  --test "dns-rollback: a foreign dhcp_option is refused, and nothing is written" \
  --why "Widens the pre-flight test so every dhcp_option token is accepted. Deleting a pool's dhcp_option removes all of that pool's options, so without this the script silently drops any unrelated DHCP setting the pool was carrying" \
  --apply 'perl -0pi -e "s/6,\*\)/*)/" "$F"'

mutation dns-rollback-selfcheck-never-fails \
  --file scripts/dns-rollback.sh \
  --bats tests/dns-rollback.bats \
  --test "dns-rollback: a pool left un-reverted fails the script" \
  --why "Leaves the detection intact and breaks only the reporting: the script notices the wrong pool, prints the failure, and exits 0 anyway. A rollback that a calling script cannot tell apart from a successful one is the failure mode this project keeps re-learning" \
  --apply 'perl -0pi -e "s/^    exit 1\$/    exit 0/m" "$F"'

mutation dns-matrix-blocked-accepts-anything \
  --file scripts/lib/dns-matrix.sh \
  --bats tests/lib-dns-matrix.bats \
  --test "dns-matrix: BLOCKED does not accept an unblocked answer" \
  --why "Weakens the BLOCKED rule to 'some answer came back'. The entire blocklist half of the migration - the 3.4 lists, the Gate 3 parity rows and the Phase 6 acceptance run - is judged through this one comparison, so a resolver that blocks nothing would read as perfect" \
  --apply 'perl -0pi -e "s/\[\[ \" \x24answers \" == \*\" 0\.0\.0\.0 \"\* \]\]/[[ -n \"\x24answers\" ]]/" "$F"'

mutation dns-matrix-nodata-accepts-nxdomain \
  --file scripts/lib/dns-matrix.sh \
  --bats tests/lib-dns-matrix.bats \
  --test "dns-matrix: NODATA and NXDOMAIN are not the same answer" \
  --why "Collapses NODATA into 'no answers', which makes NXDOMAIN satisfy it. That erases the difference between 'answered locally with no record' - which is what local=/lan/ does, and what the .lan AAAA rows depend on - and 'this name does not resolve at all'" \
  --apply 'perl -0pi -e "s/\[\[ \"\x24status\" == \"NOERROR\" && -z \"\x24answers\" \]\]/[[ -z \"\x24answers\" ]]/" "$F"'

mutation dns-matrix-exact-ignores-the-value \
  --file scripts/lib/dns-matrix.sh \
  --bats tests/lib-dns-matrix.bats \
  --test "dns-matrix: a wrong address is reported against its row" \
  --why "Drops the address comparison, so any answer satisfies a row that names a specific address. Every .lan row is written this way, and the migration's whole claim is that those names keep pointing at Traefik" \
  --apply 'perl -0pi -e "s/\[\[ \"\x24answer\" == \"\x24expectation\" \]\] \|\| return 1/:/" "$F"'

mutation dns-rollback-ignores-uci-conf \
  --file scripts/dns-rollback.sh \
  --bats tests/dns-rollback.bats \
  --test "dns-rollback: UCI_CONF is passed to every uci call as -c" \
  --why "Stops scoping uci to UCI_CONF, so a rehearsal aimed at a scratch config directory silently runs against the live /etc/config instead. This is not hypothetical: on 2026-09-19 a rehearsal written against the UCI_CONFIG_DIR environment variable did exactly that on this router, because uci accepts the variable and ignores it. The scratch directory only isolates while -c is on every call" \
  --apply 'perl -0pi -e "s/if \[ -n \"\x24UCI_CONF\" \]; then/if false; then/" "$F"'
