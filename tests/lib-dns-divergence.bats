#!/usr/bin/env bats
# scripts/lib/check-dns-divergence.sh
#
# The migration deliberately holds the same .lan names in two stores, because
# the firewall's dns_enabled flag decides which one answers: AdGuard Home's DNS
# rewrites (Phase 3.2) and the router's dnsmasq `address` records (Phase 4.1).
# A name added to one store and not the other is silent until the flag flips,
# which is what this guard exists to catch before Phase 6.
#
# No router, no network, no ssh: both stores are handed to the functions as
# text. Same shape as tests/lib-router-dns.bats, for the same reason -- a guard
# whose only reachable outcome is "skipped" cannot be shown to be capable of
# failing, and the machine that runs this suite is not the router.
#
# Every test names, in a comment, the change to the production file that would
# turn it red. A test that cannot name one proves nothing.
#
# The fixtures are written in the shape of the two real files rather than in the
# shape of the parser's input: the dnsmasq side carries the comment header and
# blank line that pihole/dnsmasq.d/02-local-dns.conf.example has, and the
# AdGuard side is the domain/answer pair the rewrite table shows.

setup() {
    load helpers/setup
    source "$REPO_ROOT/scripts/lib/check-dns-divergence.sh"

    FIX="$BATS_TEST_TMPDIR/fixtures"
    mkdir -p "$FIX"
    RECORD="$FIX/record.conf"
    CAPTURE="$FIX/rewrites.txt"
}

# repo_record <name>:<address>... -- the repo-side store, one dnsmasq `address`
# record per argument, with the committed file's comment prelude.
repo_record() {
    local spec
    {
        printf '# Local .lan domains for port-free service access\n'
        printf '\n'
        for spec in "$@"; do
            printf 'address=/%s/%s\n' "${spec%%:*}" "${spec#*:}"
        done
    } > "$RECORD"
}

# rewrite_capture <name>:<address>... -- the AdGuard side: domain, answer.
rewrite_capture() {
    local spec
    : > "$CAPTURE"
    for spec in "$@"; do
        printf '%s\t%s\n' "${spec%%:*}" "${spec#*:}" >> "$CAPTURE"
    done
}

# --- agreement --------------------------------------------------------------

@test "dns-divergence: the same names on the same addresses pass" {
    repo_record sonarr.lan:192.168.110.250 jellyfin.lan:192.168.110.250
    rewrite_capture sonarr.lan:192.168.110.250 jellyfin.lan:192.168.110.250

    # The false-red guard for this file. RED if the union loop dropped names, if
    # the address comparison were added to a set that already agrees, or if the
    # parser stumbled on the committed file's comment and blank lines.
    run dns_divergence_check "$RECORD" "$CAPTURE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok   sonarr.lan 192.168.110.250"* ]]
    [[ "$output" == *"ok   jellyfin.lan 192.168.110.250"* ]]
    [[ "$output" == *"0 divergence(s)"* ]]
}

# --- the two one-sided cases ------------------------------------------------

@test "dns-divergence: a name only in the AdGuard rewrite list fails" {
    repo_record sonarr.lan:192.168.110.250
    rewrite_capture sonarr.lan:192.168.110.250 radarr.lan:192.168.110.250

    # The case the migration creates: AdGuard was given radarr.lan and the
    # router-side record was not. RED if the sweep iterated the repo-side names
    # only -- the extra AdGuard name would then never be looked at, and the
    # guard would report agreement while the two stores answer differently.
    run dns_divergence_check "$RECORD" "$CAPTURE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL radarr.lan is in the AdGuard rewrite list but not in the repo-side .lan record"* ]]
    [[ "$output" != *"FAIL sonarr.lan"* ]]
    [[ "$output" == *"1 divergence(s)"* ]]
}

@test "dns-divergence: a name only in the repo-side record fails" {
    repo_record sonarr.lan:192.168.110.250 radarr.lan:192.168.110.250
    rewrite_capture sonarr.lan:192.168.110.250

    # The mirror image, and the one a later AdGuard edit produces. RED if the
    # sweep iterated the AdGuard names only: a name the router's dnsmasq will
    # answer after the flip, and that AdGuard has never heard of, is exactly the
    # latent bug the guard exists for.
    run dns_divergence_check "$RECORD" "$CAPTURE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL radarr.lan is in the repo-side .lan record but not in the AdGuard rewrite list"* ]]
    [[ "$output" != *"FAIL sonarr.lan"* ]]
}

# --- the silent one ---------------------------------------------------------

@test "dns-divergence: the same name on a different address fails" {
    repo_record sonarr.lan:192.168.110.250
    rewrite_capture sonarr.lan:192.168.110.249

    # Worse than a missing name, because nothing looks broken: both stores
    # answer sonarr.lan, and which address a client gets depends on a firewall
    # flag. RED if the comparison matched names only and dropped the addresses,
    # which is the mutation this test exists for.
    run dns_divergence_check "$RECORD" "$CAPTURE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL sonarr.lan answers 192.168.110.250 in the repo-side record and 192.168.110.249 in AdGuard"* ]]
    [[ "$output" != *"ok   sonarr.lan"* ]]
}

# --- reads that produced nothing --------------------------------------------

@test "dns-divergence: an unreadable capture is a skip, not an all-clear" {
    repo_record sonarr.lan:192.168.110.250

    # RED if the unreadable path were treated as empty text and fed to the
    # parser: the caller could no longer tell "the file is missing" from "the
    # capture has no rewrites", and neither may read as agreement.
    run dns_divergence_check "$RECORD" "$BATS_TEST_TMPDIR/no-such-capture.txt"
    [ "$status" -eq 2 ]
    [[ "$output" == *"SKIP: cannot read the AdGuard rewrite capture"* ]]
    [[ "$output" != *"ok   sonarr.lan"* ]]
    [[ "$output" != *"divergence(s)"* ]]
}

@test "dns-divergence: a capture that parsed no names is not a pass and is not a divergence" {
    repo_record sonarr.lan:192.168.110.250 radarr.lan:192.168.110.250
    : > "$CAPTURE"

    # RED if the zero-name case fell through to the comparison: an empty or
    # unread AdGuard list would report every repo-side name as missing from
    # AdGuard, which is a divergence verdict manufactured out of a read that
    # produced nothing -- the defect this repo keeps re-learning.
    run dns_divergence_check "$RECORD" "$CAPTURE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"parsed no hostnames"* ]]
    [[ "$output" != *"FAIL"* ]]
    [[ "$output" != *"divergence(s)"* ]]
}

@test "dns-divergence: an unreadable repo-side record is a skip, not a divergence" {
    rewrite_capture sonarr.lan:192.168.110.250

    # RED if the repo side defaulted to empty text: every AdGuard name would be
    # reported as missing from the record, so a mistyped path would read as a
    # real divergence and send someone editing the wrong file.
    run dns_divergence_check "$BATS_TEST_TMPDIR/no-such-record.conf" "$CAPTURE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"SKIP: cannot read the repo-side .lan record"* ]]
    [[ "$output" != *"FAIL"* ]]
}

@test "dns-divergence: a repo-side record with no hostnames is the Phase 3 state, not a divergence" {
    repo_record
    rewrite_capture sonarr.lan:192.168.110.250

    # Phase 3 populates AdGuard (3.2) while the router-side store does not exist
    # until 4.1. Read literally, "AdGuard has a name the other store does not"
    # is a divergence, and reporting it would fail the whole of Phase 3 for a
    # state the plan intends -- the way a guard gets deleted instead of fixed.
    # Reading it as agreement would be worse: the name really is unanswered
    # through dnsmasq until 4.1 lands. So it is its own verdict, exit 2, naming
    # the phase that fills the store.
    #
    # RED if the empty repo side were compared anyway: sonarr.lan would come
    # back FAIL "in the AdGuard rewrite list but not in the repo-side .lan
    # record", and Gate 3 would be unpassable until Phase 4.
    run dns_divergence_check "$RECORD" "$CAPTURE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"parsed no hostnames"* ]]
    [[ "$output" == *"4.1"* ]]
    [[ "$output" != *"FAIL"* ]]
}

@test "dns-divergence: a record line that is not an address= record is not skipped" {
    printf 'local=/lan/\n' > "$RECORD"
    rewrite_capture sonarr.lan:192.168.110.250

    # RED if unrecognized lines were ignored: this record would parse zero
    # hostnames and report the Phase 3 message, which is a different problem
    # with a different fix, and a future `.lan` record written in a syntax the
    # parser does not know would read as an empty store.
    run dns_divergence_check "$RECORD" "$CAPTURE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"line 1"* ]]
    [[ "$output" == *"is not an address= record"* ]]
}

@test "dns-divergence: a capture line that is not a domain/answer pair is not skipped" {
    repo_record sonarr.lan:192.168.110.250
    printf 'sonarr.lan\n' > "$CAPTURE"

    # RED if a line that did not split into two fields were dropped: silently
    # losing a rewrite shortens the AdGuard list, and a shorter list reads as a
    # name the router has and AdGuard does not.
    run dns_divergence_check "$RECORD" "$CAPTURE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"line 1"* ]]
    [[ "$output" == *"domain"* ]]
}

# --- the records that are deliberately different -----------------------------

@test "dns-divergence: the zone-wide address=/lan/:: record is not a hostname" {
    printf '# AAAA parity for .lan, not a hostname\naddress=/lan/::\naddress=/sonarr.lan/192.168.110.250\n' > "$RECORD"
    rewrite_capture sonarr.lan:192.168.110.250

    # `address=/lan/::` is the repo's AAAA-parity record and has no hostname to
    # compare: AdGuard expresses the same thing another way (open question 3).
    # RED if the hostname filter were dropped from the repo-side parser -- `lan`
    # would be reported as a name only the record has, on every run, turning a
    # deliberate difference into a permanent red.
    run dns_divergence_check "$RECORD" "$CAPTURE"
    [ "$status" -eq 0 ]
    [[ "$output" != *"lan is"* ]]
    [[ "$output" == *"1 hostname(s)"* ]]

    repo_record sonarr.lan:192.168.110.250
    { printf 'lan\t::\n'; printf 'sonarr.lan\t192.168.110.250\n'; } > "$CAPTURE"

    # The same filter on the AdGuard side, for the same reason.
    run dns_divergence_check "$RECORD" "$CAPTURE"
    [ "$status" -eq 0 ]
    [[ "$output" != *"FAIL"* ]]
}

@test "dns-divergence: the TRAEFIK_LAN_IP placeholder resolves against the address given" {
    printf 'address=/sonarr.lan/TRAEFIK_LAN_IP\naddress=/radarr.lan/TRAEFIK_LAN_IP\n' > "$RECORD"
    rewrite_capture sonarr.lan:192.168.110.250 radarr.lan:192.168.110.250

    # The committed record is pihole/dnsmasq.d/02-local-dns.conf.example, which
    # carries the literal placeholder. RED if the third argument were ignored:
    # the repo's own record would report every name as an address mismatch, and
    # a guard that fails on correct configuration is one nobody keeps.
    run dns_divergence_check "$RECORD" "$CAPTURE" 192.168.110.250
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok   sonarr.lan 192.168.110.250"* ]]
    [[ "$output" == *"ok   radarr.lan 192.168.110.250"* ]]
}

@test "dns-divergence: an unresolved TRAEFIK_LAN_IP is not reported as an address mismatch" {
    printf 'address=/sonarr.lan/TRAEFIK_LAN_IP\n' > "$RECORD"
    rewrite_capture sonarr.lan:192.168.110.250

    # RED if the placeholder were compared literally: the file is right and the
    # caller did not say what the placeholder stands for, which is a thing to
    # ask for rather than a divergence to report.
    run dns_divergence_check "$RECORD" "$CAPTURE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"TRAEFIK_LAN_IP"* ]]
    [[ "$output" != *"FAIL"* ]]
}

# --- input shapes -----------------------------------------------------------

@test "dns-divergence: a capture on stdin is compared like a file" {
    repo_record sonarr.lan:192.168.110.250
    rewrite_capture sonarr.lan:192.168.110.250

    # The task this exists for is testing without a router, so the capture has to
    # be pipeable: `ssh router 'cat rewrites' | check ...`. RED if '-' were
    # opened as a filename, or if stdin were read as empty and reported as a
    # parse failure.
    local out="" rc=0
    out=$(dns_divergence_check "$RECORD" - < "$CAPTURE") || rc=$?
    [ "$rc" -eq 0 ]
    [[ "$out" == *"ok   sonarr.lan 192.168.110.250"* ]]
}

@test "dns-divergence: one address= record can carry several names" {
    printf 'address=/sonarr.lan/radarr.lan/192.168.110.250\n' > "$RECORD"
    rewrite_capture sonarr.lan:192.168.110.250 radarr.lan:192.168.110.250

    # dnsmasq's own multi-name form. RED if the parser took only the first field
    # before the address as a name: radarr.lan would be reported as present in
    # AdGuard only, on a record that plainly defines it.
    run dns_divergence_check "$RECORD" "$CAPTURE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok   sonarr.lan 192.168.110.250"* ]]
    [[ "$output" == *"ok   radarr.lan 192.168.110.250"* ]]
}

@test "dns-divergence: names are compared case-insensitively" {
    repo_record Sonarr.LAN:192.168.110.250
    rewrite_capture sonarr.lan:192.168.110.250

    # DNS names are case-insensitive, and AdGuard lowercases what the UI stores.
    # RED if both sides were compared as written: one hostname would be reported
    # as present in each store only -- two findings for a name that agrees.
    run dns_divergence_check "$RECORD" "$CAPTURE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok   sonarr.lan 192.168.110.250"* ]]
    [[ "$output" != *"FAIL"* ]]
}

@test "dns-divergence: a name defined twice in one store is not decided by sort order" {
    repo_record sonarr.lan:192.168.110.250 sonarr.lan:192.168.110.251
    rewrite_capture sonarr.lan:192.168.110.250

    # RED if duplicates were left to the lookup, which returns the first match:
    # the record would agree or disagree depending on which line sorted first,
    # so a store contradicting itself would read as agreement. Not a divergence
    # either -- the comparison has no verdict to give.
    run dns_divergence_check "$RECORD" "$CAPTURE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"defines sonarr.lan more than once"* ]]
    [[ "$output" != *"FAIL"* ]]

    repo_record sonarr.lan:192.168.110.250
    rewrite_capture sonarr.lan:192.168.110.250 sonarr.lan:192.168.110.251

    # The same on the AdGuard side.
    run dns_divergence_check "$RECORD" "$CAPTURE"
    [ "$status" -eq 2 ]
    [[ "$output" == *"defines sonarr.lan more than once"* ]]
}
