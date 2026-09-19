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

# --- tests/helpers/router.bash ----------------------------------------------
#
# The helper is what stands between a test and a live router. Two of these
# mutations reintroduce holes this file's tests actually found: the deny rule
# matched uci set but not uci -q set, and matched iptables -A but not
# iptables -t nat -I, which is how the redirect would really be added.

mutation router-access-deny-ignores-uci-flags \
  --file tests/helpers/router.bash \
  --bats tests/router-access.bats \
  --test "router-access: a qualified uci set is refused, not just the bare form" \
  --why "Drops the flag allowance, so the guard only matches the unqualified form. The qualified one - uci -q set - then walks through, which is the shape a real script would use" \
  --apply 'perl -0pi -e "s/\Quci([[:space:]]+-[^[:space:]]+)*[[:space:]]+\E/uci[[:space:]]+/" "$F"'

mutation router-access-deny-iptables-needs-leading-flag \
  --file tests/helpers/router.bash \
  --bats tests/router-access.bats \
  --test "router-access: an iptables insert is refused" \
  --why "Requires the mutating flag to be iptables' first argument. iptables -t nat -I is how the DNS redirect would actually be inserted, and it never has its flag first" \
  --apply 'perl -0pi -e "s/\Qiptables.*-[AIDXNFZE]\E/iptables[[:space:]]+-[AIDXNFZE]/" "$F"'

mutation router-access-deny-drops-add-list \
  --file tests/helpers/router.bash \
  --bats tests/router-access.bats \
  --test "router-access: add_list is refused" \
  --why "Removes both add_list and its add prefix from the verb list. add_list is the verb the rollback script uses to write a pool's resolver, so a deny list that misses it misses the operation this whole migration performs" \
  --apply 'perl -0pi -e "s/\(set\|add\|add_list\|/(set|/" "$F"'

mutation router-access-prefers-the-jump-host \
  --file tests/helpers/router.bash \
  --bats tests/router-access.bats \
  --test "router-access: the direct path is preferred when it works" \
  --why "Makes the probe reach for pi1 before trying the router directly, so every live assertion runs through an unnecessary extra hop and a broken direct path is never noticed" \
  --apply 'perl -0pi -e "s/if _router_try direct; then ROUTER_PATH=direct; return 0; fi/if _router_try jump;   then ROUTER_PATH=jump;   return 0; fi/" "$F"'

mutation router-access-any-subnet-matches \
  --file tests/helpers/router.bash \
  --bats tests/router-access.bats \
  --test "router-access: no shared subnet yields no address rather than a wrong one" \
  --why "Makes the subnet comparison always succeed, so the first address the router reports is used whatever VLAN this host is on. That is the silent wrong-interface failure the derivation exists to prevent: 192.168.8.1 answers, it is just not the address a client here queries" \
  --apply 'perl -0pi -e "s/if \[\[ \"\x24\{m%\.\*\}\" == \"\x24prefix\" \]\]; then/if true; then/" "$F"'

mutation router-access-swallows-the-error-text \
  --file tests/helpers/router.bash \
  --bats tests/router-access.bats \
  --test "router-access: no route at all is reported, not swallowed" \
  --why "Keeps the failure and drops the explanation, so a skip says the router is unreachable without saying what happened. Two different problems - a refused connection and a missing ssh alias - become one indistinguishable skip" \
  --apply 'perl -0pi -e "s/ROUTER_SSH_ERR=\"\x24out\"/ROUTER_SSH_ERR=\"\"/" "$F"'

# --- what this corpus does NOT score yet, and why ---------------------------
#
# tests/dns-resilience.bats, tests/alpine-dns-aaaa.bats and tests/router-dns.bats
# are Phase 1 acceptance tests, and the first two are RED on purpose: they assert
# the migration's end state, which the router does not reach until Phase 4 and
# Phase 6. The mutation harness runs the named test unmutated first and refuses
# to score a test that is already failing ("a later failure would prove
# nothing"), so a corpus entry naming one of them would ERROR rather than kill.
# Adding one now would be noise, not coverage.
#
# Their sensitivity is established two other ways instead:
#
#   * the same expectations are scored by dns-matrix-* above, through the unit
#     test of scripts/lib/dns-matrix.sh, which is the module every one of those
#     files judges with;
#   * the assertions were run against the NAS Pi-hole, which is the correct end
#     state for these rows: ./scripts/dns-matrix-check.sh reports 50/50 rows
#     matched against 192.168.110.246, including sonarr.lan A = 192.168.110.250,
#     sonarr.lan AAAA = :: and doubleclick.net = BLOCKED. Assertions that cannot
#     pass on a correct resolver would be the defect; these demonstrably can.
#
# When Phase 4 makes the .lan rows green and Phase 6 makes the blocked rows
# green, each of those tests becomes scorable and needs its entry here. That is
# a deliberate debt, recorded rather than forgotten.
#
# tests/alpine-dns-aaaa.bats is a third case: its guard is a container's exit
# status against a live resolver, and the configuration that would break it
# lives on the router, not in a file this repo can mutate. There is nothing to
# break and watch go red.

# --- scripts/lib/router-dns.sh ----------------------------------------------
#
# These judge the router's live state: which pools advertise a resolver, what
# the redirect chain holds, and where dnsmasq listens. Each mutation loosens one
# rule to "whatever, it's fine", which is the failure mode that matters here -
# the checks print a verdict either way, so a rule that stops discriminating
# reports a healthy router regardless of what it was handed.

mutation router-dns-ignores-rules-while-disabled \
  --file scripts/lib/router-dns.sh \
  --bats tests/lib-router-dns.bats \
  --test "router-dns: a rule in the chain while dns_enabled=0 fails" \
  --why "Stops noticing rules in adg_redirect while dns_enabled is 0. That state is the one the migration is supposed to be reversible to: the config says AdGuard is off, so every query is being redirected to a resolver that is not supposed to be answering" \
  --apply 'perl -0pi -e "s/if \[\[ \"\x24count\" -gt 0 \]\]; then/if false; then/" "$F"'

mutation router-dns-udp-arm-not-required \
  --file scripts/lib/router-dns.sh \
  --bats tests/lib-router-dns.bats \
  --test "router-dns: a tcp-only chain with dns_enabled=1 fails on the missing udp arm" \
  --why "Drops the check that the redirect covers UDP. UDP is the transport DNS is actually used over, so a tcp-only redirect leaves dnsmasq answering ordinary lookups while the config claims AdGuard Home does - the exact half-installed state the two-transport assertions exist for" \
  --apply 'perl -0pi -e "s/if \[\[ \"\x24udp\" -lt 1 \]\]; then/if false; then/" "$F"'

mutation router-dns-any-redirect-port-counts \
  --file scripts/lib/router-dns.sh \
  --bats tests/lib-router-dns.bats \
  --test "router-dns: a udp arm pointed at another port does not count as the arm" \
  --why "Accepts a REDIRECT to any port as the AdGuard arm, so a chain pointing at 3053's neighbour would satisfy a check whose whole purpose is to confirm the queries land on 3053" \
  --apply 'perl -0pi -e "s/\"\x24toports\" == \"3053\"/\"\x24toports\" != \"\"/" "$F"'

mutation router-dns-octet-range-unchecked \
  --file scripts/lib/router-dns.sh \
  --bats tests/lib-router-dns.bats \
  --test "router-dns: an out-of-range octet is not a well-formed address" \
  --why "Keeps the shape test and drops the range test, so 999.1.1.1 is accepted as a resolver address. A pool handed a value no client can parse is a DHCP fault that reads as a healthy pool" \
  --apply 'perl -0pi -e "s/\(\( 10#\x24octet <= 255 \)\) \|\| return 1/:/" "$F"'

mutation router-dns-port53-binds-invisible \
  --file scripts/lib/router-dns.sh \
  --bats tests/lib-router-dns.bats \
  --test "router-dns: every live non-loopback address bound passes" \
  --why "Inverts the port filter so :53 listeners are discarded instead of kept. Every address then looks unbound, and the check that a client's queries land somewhere on the router stops being able to see the listeners that answer them" \
  --apply 'perl -0pi -e "s/if \(port != \"53\"\) continue/if (port == \"53\") continue/" "$F"'
