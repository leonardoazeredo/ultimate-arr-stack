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

# --- scripts/dnsmasq-local-names.sh -----------------------------------------
#
# Phase 4.1 teaches the router's dnsmasq the .lan address records. Every mutation
# below is a way of reporting that the records were installed while the router
# serves none of them, or of leaving a duplicate behind on the second run. All
# five are scored against tests/dnsmasq-local-names.bats, which runs the real
# script against a stubbed router: a fake uci, a fake /var/etc, and a fake
# dnsmasq init that re-renders the config the way the real one does.

mutation dnsmasq-local-second-run-appends \
  --file scripts/dnsmasq-local-names.sh \
  --bats tests/dnsmasq-local-names.bats \
  --test "a second run changes nothing" \
  --why "Inverts the compare-first guard so a router that already carries the records never matches. uci add_list appends duplicates happily, so a second run leaves 19 more entries in flash - the state this script exists to avoid, and the one Gate 4's reboot would then carry" \
  --apply 'perl -0pi -e "s/if \[\[ \x22\x24desired\x22 == /if [[ \x22\x24desired\x22 != /" "$F"'

mutation dnsmasq-local-no-reload \
  --file scripts/dnsmasq-local-names.sh \
  --bats tests/dnsmasq-local-names.bats \
  --test "dnsmasq is reloaded after the commit" \
  --why "Removes the dnsmasq reload. uci commit dhcp emits no config.change event - nothing calls /sbin/reload_config except /etc/init.d/boot - so the records sit in flash while dnsmasq keeps serving the config it rendered at boot" \
  --apply 'perl -0pi -e "s/^if ! reload_out=.*\n//m" "$F"'

mutation dnsmasq-local-verify-reads-uci-only \
  --file scripts/dnsmasq-local-names.sh \
  --bats tests/dnsmasq-local-names.bats \
  --test "a rendered config carrying every record passes" \
  --why "Makes the rendered-config read return nothing, so the self-check cannot see a record and reports success on a config that carries none. dnsmasq is started as dnsmasq -C /var/etc/dnsmasq.conf.<hash>; a check that only reads UCI passes while the daemon serves nothing" \
  --apply 'perl -0pi -e "s/grep \"\^address=\" %s/grep \"\^nope=\" %s/" "$F"'

mutation dnsmasq-local-section-picked-by-position \
  --file scripts/dnsmasq-local-names.sh \
  --bats tests/dnsmasq-local-names.bats \
  --test "the section is resolved, and the type is not mistaken for it" \
  --why "Replaces the structural section choice with the first section of type dnsmasq. This router carries two - the DHCP-serving one and wgclient1 for the WireGuard tunnel - and uci show dhcp does not promise their order. The records would land in the tunnel section, which the DHCP server never reads. It looked right in development only because the live router happens to list the main section first" \
  --apply 'perl -0pi -e "s/leasefile.*continue.*\n//" "$F"'

mutation dnsmasq-local-apply-never-removes \
  --file scripts/dnsmasq-local-names.sh \
  --bats tests/dnsmasq-local-names.bats \
  --test "a record this script does not own is not deleted|an AAAA that NXDOMAINs fails the run" \
  --why "Drops the del_list that precedes each add_list, so the rebuild only ever appends. A record already present is then held twice: the A query still answers, and the zone record is answered twice over, which is what the AAAA assertion catches" \
  --apply 'perl -0pi -e "s/^\s*printf.*del_list.*\n//mg" "$F"'

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

# --- router/adguard-stage.sh -------------------------------------------------
#
# This script enables a DNS resolver for the whole house while its admin API is
# still unauthenticated. Every mutation below is a way of reporting success
# having done that.

mutation adguard-stage-starts-without-a-credential \
  --file router/adguard-stage.sh \
  --bats tests/adguard-stage.bats \
  --test "adguard-stage: an unconfigured instance with no credential is refused" \
  --why "Makes the configured-detection always answer 'already configured', so the script skips the credential entirely and starts an instance with users: [] - an admin API that can rewrite or block any domain for every client, reachable from the maintenance VLAN in 6 ms" \
  --apply 'perl -0pi -e "s/^    configured=0\$/    configured=1/m" "$F"'

mutation adguard-stage-skips-the-login-check \
  --file router/adguard-stage.sh \
  --bats tests/adguard-stage.bats \
  --test "adguard-stage: a credential that cannot log in fails the run" \
  --why "Hard-codes the login result to 200, so the script reports a working credential without ever asking. A file that looks right and a hash AdGuard cannot parse are indistinguishable except by logging in, which is the whole reason this call exists" \
  --apply 'perl -0pi -e "s/login_status=\x24\(/login_status=200 #/" "$F"'

mutation adguard-stage-ignores-dns-enabled-drift \
  --file router/adguard-stage.sh \
  --bats tests/adguard-stage.bats \
  --test "adguard-stage: dns_enabled moving during the run fails it" \
  --why "Makes the before/after comparison always agree, so the script cannot notice that it moved dns_enabled. That flag installs the redirect that sends every client's :53 to AdGuard, and Phase 2 is supposed to stage a resolver without putting it in the path" \
  --apply 'perl -0pi -e "s/if \[ \"\x24dns_enabled_after\" = \"\x24dns_enabled_before\" \]; then/if true; then/" "$F"'

mutation adguard-stage-writes-the-plaintext-password \
  --file router/adguard-stage.sh \
  --bats tests/adguard-stage.bats \
  --test "adguard-stage: the user is written and a real login is required to pass" \
  --why "Writes the plaintext password where the bcrypt hash belongs. AdGuard cannot authenticate against it, so the router ends up with a credential nobody can use and a config file holding a secret in the clear" \
  --apply 'perl -0pi -e "s/-v h=\"\x24ADMIN_PASSWORD_HASH\"/-v h=\"\x24ADMIN_PASSWORD\"/" "$F"'

# --- scripts/lib/check-dns-divergence.sh ------------------------------------
#
# The migration deliberately holds the same .lan names in two stores, because a
# firewall flag decides which one answers: AdGuard Home's DNS rewrites (3.2) and
# the router's dnsmasq `address` records (4.1). A name added to one side only is
# a latent bug - nothing looks wrong until dns_enabled flips, and by then the
# name is answered by the wrong store or by neither. Each mutation below keeps
# the guard printing a verdict while removing the one rule that would have
# caught it, which is the failure this file exists to make visible.

mutation dns-divergence-address-not-compared \
  --file scripts/lib/check-dns-divergence.sh \
  --bats tests/lib-dns-divergence.bats \
  --test "dns-divergence: the same name on a different address fails" \
  --why "Stops comparing the address each store gives for a name held in both. The name sets still have to agree, so the guard reports a clean comparison while AdGuard and the router's dnsmasq answer the same hostname with different addresses - the silent half of the divergence, and the worse one, because after the flip the name still resolves and only goes somewhere else" \
  --apply 'perl -0pi -e "s/elif \[\[ \"\x24repo_address\" != \"\x24capture_address\" \]\]; then/elif false; then/" "$F"'

mutation dns-divergence-empty-capture-is-a-verdict \
  --file scripts/lib/check-dns-divergence.sh \
  --bats tests/lib-dns-divergence.bats \
  --test "dns-divergence: a capture that parsed no names is not a pass and is not a divergence" \
  --why "Removes the guard on a capture that parsed no hostnames. Every name in the repo-side record then comes back as missing from AdGuard, so a read that produced nothing is reported as a divergence - the same defect as an all-clear manufactured from an empty read, with the sign flipped" \
  --apply 'perl -0pi -e "s/if \[\[ -z \"\x24capture_names\" \]\]; then/if false; then/" "$F"'

mutation dns-divergence-adguard-side-ignored \
  --file scripts/lib/check-dns-divergence.sh \
  --bats tests/lib-dns-divergence.bats \
  --test "dns-divergence: a name only in the AdGuard rewrite list fails" \
  --why "Empties the AdGuard-side name list, so the comparison only ever walks the names the repo-side record holds. A rewrite added to AdGuard and not to the router's dnsmasq address list goes unnoticed until dns_enabled flips and the name stops resolving through dnsmasq - the state Gate 3 exists to catch while nothing is answering from it yet" \
  --apply 'perl -0pi -e "s/capture_names=\x24\(printf .%s. \"\x24capture_entries\" \| cut -f1 \| grep \. \|\| true\)/capture_names=\"\"/" "$F"'

# --- scripts/lib/dns-parity.sh ----------------------------------------------
#
# The parity harness reports whether two resolvers can be swapped for one
# another, and Gate 3's pass condition is "zero unexplained differences". Every
# mutation below is a way of reporting that while the two resolvers disagree -
# the failure mode the whole harness exists to prevent, and the one a reader of
# a green report has no way to notice.
#
# The two warnings in these diffs are deliberate. The status comparison is
# written as `"$1" != "$3"` and the ALLOW-DIFF refusal as `!= ERROR`: in both
# cases the mutation removes a guard clause from an `&&` chain or a `[[ ]]`, so
# `set -e` inspection in the diff is doing exactly what the mutant intends.

mutation dns-parity-answer-only-comparison \
  --file scripts/lib/dns-parity.sh \
  --bats tests/lib-dns-parity.bats \
  --test "dns-parity: a status mutation \\(NXDOMAIN vs NODATA\\) is an unexplained difference" \
  --why "Drops the status comparison and compares only the answer section, so two results with empty answers are equal whatever their statuses. That is exactly the row Gate 3 has to surface: an unknown .lan name is NODATA on the NAS Pi-hole, because address=/lan/:: gives dnsmasq local data for the zone, and NXDOMAIN on the router, because local=/lan/ makes dnsmasq authoritative with none. The two answer sections are both empty, so this mutant reports parity on the one row the router/nas migration is expected to differ on" \
  --apply 'perl -0pi -e "s/    \[\[ \"\x241\" != \"\x243\" \]\] && return 0\n//" "$F"'

mutation dns-parity-excuses-everything \
  --file scripts/lib/dns-parity.sh \
  --bats tests/lib-dns-parity.bats \
  --test "dns-parity: a deliberate difference without the marker is not excused" \
  --why "Makes the ALLOW-DIFF marker unnecessary: every difference is excused, so one marker anywhere in the fixture sanctions the whole matrix. The fixture header says a deliberate difference has to be named; a harness that reports nothing unexplained because something unrelated was named turns Gate 3 into a formality, and the difference that should have failed is the one nobody sees. The replacement is anchored on the excusal function's own body - a bare 'return 1' to 'return 0' hits the parser's first bounds check instead, changes nothing observable, and survives as an equivalent mutant" \
  --apply 'perl -0pi -0777 -e "s/dns_parity_row_excused\(\) \{\n.*?\n\}/dns_parity_row_excused() {\n    return 0\n}/s" "$F"'

mutation dns-parity-both-error-is-agreement \
  --file scripts/lib/dns-parity.sh \
  --bats tests/lib-dns-parity.bats \
  --test "dns-parity: both resolvers unreachable is a no-oracle skip, not a difference" \
  --why "Turns the all-ERROR guard into its opposite, so a run where nothing was reached stops being a reported skip and becomes a matrix of differences. Two unreachable resolvers are not evidence that they disagree, and a report that says they do sends the reader after a configuration difference that was never observed - while the real cause (a dead jump host, a wrong address) is the text that got buried" \
  --apply 'perl -0pi -e "s/if \[\[ \"\x24errors_a\" -eq \"\x24rows\" && \"\x24errors_b\" -eq \"\x24rows\" \]\]; then/if false; then/" "$F"'


# --- scripts/lib/router-dns.sh: the client path ------------------------------
#
# The checks above judge the pieces -- which resolver a pool hands out, what
# adg_redirect holds, where dnsmasq listens. Every one of them can read green
# while no client is served, and on 2026-09-21 that is exactly what happened:
# dns_enabled was 1, adg_redirect was correct, all four pools were correct, and
# three of five client bridges still resolved through dnsmasq with no ad
# blocking, because GL.iNet's dns_dispatcher is wired only for br-lan.1 and
# br-guest. Each mutation below loosens the check that connects the pieces, so
# it reports a healthy router while the connection is gone.

mutation router-dns-client-hardcodes-the-bridge-list \
  --file scripts/lib/router-dns.sh \
  --bats tests/lib-router-dns.bats \
  --test "router-dns: a bridge the router gained later is required without touching the lib" \
  --why "Stops deriving the client bridges from the live addresses and returns br-lan.1 alone. The derivation is the whole defence against the 2026-09-21 shape: a list written on the day covers the interfaces that existed that day, and the next VLAN to be added is uncovered by default with nothing to notice it" \
  --apply 'perl -0pi -e "s/^router_dns_client_ifaces\(\) \{\n/router_dns_client_ifaces() {\n    printf \"br-lan.1\n\"; return 0\n/m" "$F"'

mutation router-dns-client-ignores-the-dispatch-chains \
  --file scripts/lib/router-dns.sh \
  --bats tests/lib-router-dns.bats \
  --test "router-dns: a bridge reached through the vendor dispatch chain passes" \
  --why "Empties the set of chains known to reach AdGuard, so only a direct PREROUTING REDIRECT counts. br-lan.1 and br-guest are served through the vendor path today, and a guard that calls a working interface broken is a guard its operator deletes - which is how the check that would have caught the three missing VLANs would itself have been removed" \
  --apply 'perl -0pi -e "s/^    resolver_chains=.*\$/    resolver_chains=\"\"/m" "$F"'

mutation router-dns-client-one-transport-is-enough \
  --file scripts/lib/router-dns.sh \
  --bats tests/lib-router-dns.bats \
  --test "router-dns: a bridge with only the tcp arm fails on the missing udp arm" \
  --why "Accepts a bridge covered on either transport rather than both. UDP is the transport DNS is actually used over, so a tcp-only redirect leaves ordinary lookups on dnsmasq while the config claims AdGuard Home answers them - the half-installed state tests/network-segmentation.bats already documents for port 53" \
  --apply 'perl -0pi -e "s/if \[\[ \"\x24tcp\" -eq 1 && \"\x24udp\" -eq 1 \]\]; then/if [[ \"\x24tcp\" -eq 1 || \"\x24udp\" -eq 1 ]]; then/" "$F"'

mutation router-dns-client-any-port-counts \
  --file scripts/lib/router-dns.sh \
  --bats tests/lib-router-dns.bats \
  --test "router-dns: redirects aimed at another port do not count" \
  --why "Accepts a REDIRECT to any port as the AdGuard arm, so a router whose every DNS rule points at dnsmasq on 53 satisfies a check whose entire purpose is to confirm the queries land on AdGuard. That is precisely the watchdog's fallback state, and the guard would call it healthy" \
  --apply 'perl -0pi -e "s/if \[\[ \"\x24_t\" == \"REDIRECT\" && \"\x24_tp\" == \"\x24port\" \]\]; then/if [[ \"\x24_t\" == \"REDIRECT\" \&\& -n \"\x24_tp\" ]]; then/" "$F"'

mutation router-dns-client-empty-capture-is-a-verdict \
  --file scripts/lib/router-dns.sh \
  --bats tests/lib-router-dns.bats \
  --test "router-dns: a nat capture with no PREROUTING rule is not a pass" \
  --why "Removes the guard on a nat capture that carried no PREROUTING rule. Every bridge then reports as uncovered, so a read that produced nothing is reported as a broken router rather than as a read that produced nothing - the same defect as an all-clear manufactured from an empty capture, with the sign flipped, and it sends the reader after a firewall fault that was never observed" \
  --apply 'perl -0pi -e "s/    if \[\[ -z \"\x24pr\" \]\]; then/    if false; then/" "$F"'

mutation router-dns-client-adguard-port-off-by-a-key \
  --file scripts/lib/router-dns.sh \
  --bats tests/lib-router-dns.bats \
  --test "router-dns: the AdGuard port comes from the dns section, not the http one" \
  --why "Drops the key test and takes the first line of the dns section, which is bind_hosts:. The port then parses as empty, and since the live test skips on an empty parse, the check that every client actually reaches AdGuard would skip for ever while reporting nothing wrong - a guard whose only reachable outcome is 'skipped'" \
  --apply 'perl -0pi -e "s/section == \"dns:\" && \x241 == \"port:\" \{/section == \"dns:\" {/" "$F"'

# --- scripts/lib/dns-matrix.sh: the .lan AAAA row ----------------------------
#
# The only `.lan` row the two resolvers answer differently, and the only one
# where pinning a literal is wrong: dnsmasq answers `::` (address=/lan/::),
# AdGuard Home answers NODATA. Both are correct and 3.3 chose NODATA as
# sufficient, having measured that musl's failure mode is AAAA NXDOMAIN rather
# than an empty answer. The rule accepts both and must still refuse NXDOMAIN,
# which is the one answer that actually breaks a musl client.

mutation dns-matrix-lan-aaaa-accepts-nxdomain \
  --file scripts/lib/dns-matrix.sh \
  --bats tests/lib-dns-matrix.bats \
  --test "dns-matrix: LAN_AAAA refuses NXDOMAIN" \
  --why "Drops the status check from the LAN_AAAA rule, leaving 'no answer section is fine'. NXDOMAIN carries no answers, so it then satisfies the rule -- and NXDOMAIN on AAAA is precisely what musl turns into a hard resolution failure, the failure this whole row exists to catch. The AWS/musl trap in tests/alpine-dns-aaaa.bats only shows up through getaddrinfo, so a dig-level row that waves NXDOMAIN through removes the cheap early warning and leaves the expensive container test as the only thing standing between a broken .lan AAAA answer and the house" \
  --apply 'perl -0pi -e "s/\[\[ \"\x24status\" == \"NOERROR\" \]\] \|\| return 1/:/" "$F"'
