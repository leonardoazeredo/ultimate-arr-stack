# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for router/firewall.user.
#
# This file is the only thing that puts a client's :53 on AdGuard Home, and it is
# sourced by fw3 on every firewall reload - including the one at boot, before
# AdGuard has started. Every mutation below is a way of pointing the house at a
# resolver that cannot answer, or of letting the rules accumulate.
#
# No router is involved: tests/firewall-user.bats runs this file with `iptables`
# and `dig` as stubs on PATH, and redirects the port file and the probe path
# through ARRDNS_PORT_FILE and ARRDNS_DIG. Nothing here can reach a live router.

mutation firewall-user-no-boot-selfcheck \
  --file router/firewall.user \
  --bats tests/firewall-user.bats \
  --test "firewall-user: AdGuard silent falls back to dnsmasq, and records it" \
  --why "Removes the probe that runs before the house is pointed at AdGuard. The firewall starts at S19 and AdGuard Home at S99, with 48 init scripts and network between them, so on a router reboot this leaves every client redirected at a resolver that is not listening yet - the exact moment this migration promised would never exist. The watchdog cannot cover it: it needs three consecutive failures and cron starts at S50, inside the window" \
  --apply 'perl -0pi -e "s/if \[ \"\x24ARRDNS_PORT\" = \"3053\" \]; then/if false; then/" "$F"'

mutation firewall-user-probe-always-falls-back \
  --file router/firewall.user \
  --bats tests/firewall-user.bats \
  --test "firewall-user: AdGuard answering keeps the house on AdGuard" \
  --why "Inverts the probe so it always decides AdGuard is down. Every client drops to dnsmasq permanently and ad blocking stops, while resolution keeps working - so nothing looks broken and nobody would notice until someone asked why the house stopped filtering" \
  --apply 'perl -0pi -e "s/if ! printf .*grep -qE .*; then/if true; then/" "$F"'

mutation firewall-user-only-vendor-interfaces \
  --file router/firewall.user \
  --bats tests/firewall-user.bats \
  --test "firewall-user: every client bridge is redirected, on both transports" \
  --why "Narrows the interface list to the two GL.iNet's own dns_dispatcher already covers. vlan10, vlan20 and vlan30 then resolve straight off dnsmasq with no ad blocking, which is the state this migration actually shipped on 2026-09-21 and took a client-path check to find" \
  --apply 'perl -0pi -e "s/ARRDNS_IFACES=\"br-lan\.1 br-lan\.10 br-lan\.20 br-lan\.30 br-guest\"/ARRDNS_IFACES=\"br-lan.1 br-guest\"/" "$F"'

mutation firewall-user-never-strips \
  --file router/firewall.user \
  --bats tests/firewall-user.bats \
  --test "firewall-user: it strips its own rules before inserting again" \
  --why "Disables the delete loop. fw3 does not flush the built-in PREROUTING chain, so every reload leaves the previous rules and inserts ten more: eighteen were live at one point during this migration, and a duplicate rule is invisible to any check that only asks whether a correct rule exists" \
  --apply 'perl -0pi -e "s/^while :; do/while false; do/m" "$F"'

mutation firewall-user-tailnet-not-filtered \
  --file router/firewall.user \
  --bats tests/firewall-user.bats \
  --test "firewall-user: the tailnet is redirected when it is in scope" \
  --why "drops tailscale0 from the interface list, so a tailnet device resolves through dnsmasq and gets no ad blocking while every device at home is filtered. Measured 2026-09-21: a tailnet query for a blocklisted name returned a real address while a bridge client got 0.0.0.0, and the asymmetry is invisible from the LAN" \
  --apply 'perl -0pi -e "s/br-guest tailscale0\}/br-guest}/" "$F"'
