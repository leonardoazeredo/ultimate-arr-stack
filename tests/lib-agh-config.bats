#!/usr/bin/env bats
# scripts/lib/agh-config.sh
#
# Phase 3 edits AdGuard Home's config.yaml by rewriting three blocks in it. The
# API is unusable on this build — GL.iNet wraps /control/* in its own
# checkToken middleware and ignores AdGuard's own agh_session cookie — so the
# file is the only way in, and there is no second chance if a write goes wrong:
# ~90 keys live in it, and losing one is a silent behaviour change nobody sees
# until a client cannot resolve.
#
# Two properties carry that risk, and both are asserted here rather than
# reasoned about:
#
#   * IDEMPOTENCE. The transform has to be a no-op on its own output, because
#     the script that applies it is meant to be safe to re-run. A transform that
#     appends instead of replacing grows the file on every run, and the growth
#     is invisible until AdGuard refuses to start.
#
#   * EVERYTHING ELSE SURVIVES BYTE-FOR-BYTE. Not reserialised, not
#     re-indented, not reordered — the transform edits lines in place and emits
#     every other line exactly as it read it. The test computes that: strip the
#     three managed blocks out of the input and out of the output, and the two
#     must be identical.
#
# An idempotence test is worth nothing if the transform is a no-op to begin
# with, so the first application is asserted to have changed something.

setup() {
    load helpers/setup
    source "$REPO_ROOT/scripts/lib/agh-config.sh"

    Q9='https://dns.quad9.net/dns-query'
    CF='https://cloudflare-dns.com/dns-query'
    SB_URL='https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts'
    SB_NAME='StevenBlack hosts'
    TRAEFIK='192.168.110.250'
    DNSMASQ_CONF="$REPO_ROOT/pihole/dnsmasq.d/02-local-dns.conf.example"

    LIVE="$BATS_TEST_TMPDIR/live.yaml"
    write_live_config "$LIVE"

    REWRITE_PAIRS=()
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] && REWRITE_PAIRS+=("$name=$TRAEFIK")
    done < <(agh_dnsmasq_hostnames < "$DNSMASQ_CONF")
}

# A config shaped like the live one, with the traps that matter clustered:
# `upstream_dns_file` sits directly after `upstream_dns` and `whitelist_filters`
# directly after `filters` (a prefix match would swallow the wrong key),
# `rewrites` is an inline empty flow list, `bootstrap_dns` must not move, and
# `user_rules` belongs to task 3.3, which is someone else's decision.
write_live_config() {
    cat > "$1" <<'YAML'
http:
  address: 0.0.0.0:3000
  session_ttl: 720h
users:
  - name: admin
    password: $2a$05$wbGXDl8iYr7aspkzk7RYvutoV6kkn7EE3LhPNFAnTiCgatUP57qVS
auth_attempts: 5
http_proxy: ""
dns:
  bind_hosts:
    - 0.0.0.0
  port: 3053
  upstream_dns:
    - 8.8.8.8
    - 9.9.9.9
  upstream_dns_file: ""
  bootstrap_dns:
    - 9.9.9.10
    - 149.112.112.10
  upstream_mode: load_balance
  cache_optimistic_answer_ttl: 30s
filters:
  - enabled: true
    url: https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: false
    url: https://adaway.org/hosts.txt
    name: AdAway Default Blocklist
    id: 2
whitelist_filters: []
user_rules: []
filtering:
  blocking_mode: default
  rewrites: []
  safe_fs_patterns:
    - /etc/AdGuardHome/data/userfilters/*
  filters_update_interval: 24
  rewrites_enabled: true
schema_version: 33
YAML
}

# The whole transform, in the order scripts/adguard-configure.sh runs it.
transform() {
    agh_config_set_upstream_dns "$Q9" "$CF" \
        | agh_config_set_filters "$SB_URL" "$SB_NAME" \
        | agh_config_set_rewrites "${REWRITE_PAIRS[@]}"
}

# The file minus the three managed blocks, so two of them can be compared.
strip_managed() {
    awk '
        {
            ind = 0
            while (substr($0, ind + 1, 1) == " ") ind++
            if (managing && ind > manind) next
            managing = 0
            if ($0 ~ /^  upstream_dns:([ \t]*\[\])?[ \t]*$/ ||
                $0 ~ /^  rewrites:([ \t]*\[\])?[ \t]*$/ ||
                $0 ~ /^filters:([ \t]*\[\])?[ \t]*$/) {
                managing = 1; manind = ind
                next
            }
            print
        }
    ' "$1"
}

apply_once() {
    run transform < "$LIVE"
    [ "$status" -eq 0 ] || fail "the transform failed: $output"
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/once.yaml"
}

# --- 3.1 the upstreams ------------------------------------------------------

@test "agh-config: the plain upstreams are replaced by the two encrypted resolvers" {
    apply_once
    [[ "$output" == *"    - $Q9"* ]]
    [[ "$output" == *"    - $CF"* ]]
    [[ "$output" != *"    - 8.8.8.8"* ]]
    [[ "$output" != *"    - 9.9.9.9"* ]]
}

@test "agh-config: bootstrap_dns keeps its plain addresses" {
    apply_once
    # Bootstrapping cannot itself be encrypted: these addresses are what
    # resolves the DoH hostnames in the first place.
    grep -q '^  bootstrap_dns:$' "$BATS_TEST_TMPDIR/once.yaml"
    grep -qxF '    - 9.9.9.10' "$BATS_TEST_TMPDIR/once.yaml"
    grep -qxF '    - 149.112.112.10' "$BATS_TEST_TMPDIR/once.yaml"
}

@test "agh-config: upstream_dns_file is not touched by the upstream edit" {
    # The key next door, and the reason the block scan matches the trailing
    # colon rather than the key prefix.
    apply_once
    grep -qxF '  upstream_dns_file: ""' "$BATS_TEST_TMPDIR/once.yaml"
}

# --- the two properties the whole design rests on ---------------------------

@test "agh-config: every key outside the three managed blocks survives byte-for-byte" {
    apply_once
    strip_managed "$LIVE" > "$BATS_TEST_TMPDIR/live.stripped"
    strip_managed "$BATS_TEST_TMPDIR/once.yaml" > "$BATS_TEST_TMPDIR/once.stripped"

    run diff -u "$BATS_TEST_TMPDIR/live.stripped" "$BATS_TEST_TMPDIR/once.stripped"
    [ "$status" -eq 0 ] || fail "a line outside the managed blocks changed:"$'\n'"$output"

    # And the three keys themselves are still there, rather than deleted.
    grep -q '^  upstream_dns:$' "$BATS_TEST_TMPDIR/once.yaml"
    grep -q '^  rewrites:$' "$BATS_TEST_TMPDIR/once.yaml"
    grep -q '^filters:$' "$BATS_TEST_TMPDIR/once.yaml"

    # A REPLACEMENT THAT LEFT THE OLD ITEMS BEHIND would sit inside the block,
    # where the stripped comparison above cannot see it — it strips the block
    # from both sides. Found by mutation: making the block scan stop at the key
    # line leaves `- 8.8.8.8` under the new upstreams and this test still passed.
    # So the values that were replaced are named here.
    grep -qxF '    - 8.8.8.8' "$BATS_TEST_TMPDIR/once.yaml" \
        && fail "the old upstream line survived the replacement"
    grep -qxF '    - 9.9.9.9' "$BATS_TEST_TMPDIR/once.yaml" \
        && fail "the old upstream line survived the replacement"

    # A stripped comparison that stripped everything would pass while the
    # transform ate the file.
    [ "$(wc -l < "$BATS_TEST_TMPDIR/once.stripped")" -ge 25 ]
}

@test "agh-config: applying the whole transform to its own output changes nothing" {
    apply_once
    # Guard the guard: if the first application changed nothing, the second one
    # being a no-op proves nothing at all.
    cmp -s "$LIVE" "$BATS_TEST_TMPDIR/once.yaml" \
        && fail "the transform did not change anything, so this test cannot fail"

    run transform < "$BATS_TEST_TMPDIR/once.yaml"
    [ "$status" -eq 0 ] || fail "the second application failed: $output"
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/twice.yaml"

    run cmp -s "$BATS_TEST_TMPDIR/once.yaml" "$BATS_TEST_TMPDIR/twice.yaml"
    [ "$status" -eq 0 ] || fail "the second application was not a no-op:"$'\n'"$(diff -u "$BATS_TEST_TMPDIR/once.yaml" "$BATS_TEST_TMPDIR/twice.yaml")"
}

@test "agh-config: the transforms are idempotent one at a time, too" {
    # The CLI can be pointed at any subset; each function has to stand alone.
    run agh_config_set_filters "$SB_URL" "$SB_NAME" < "$LIVE"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/f1.yaml"
    run agh_config_set_filters "$SB_URL" "$SB_NAME" < "$BATS_TEST_TMPDIR/f1.yaml"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/f2.yaml"
    run cmp -s "$BATS_TEST_TMPDIR/f1.yaml" "$BATS_TEST_TMPDIR/f2.yaml"
    [ "$status" -eq 0 ] || fail "the filter edit is not idempotent"

    run agh_config_set_upstream_dns "$Q9" "$CF" < "$LIVE"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/u1.yaml"
    run agh_config_set_upstream_dns "$Q9" "$CF" < "$BATS_TEST_TMPDIR/u1.yaml"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/u2.yaml"
    run cmp -s "$BATS_TEST_TMPDIR/u1.yaml" "$BATS_TEST_TMPDIR/u2.yaml"
    [ "$status" -eq 0 ] || fail "the upstream edit is not idempotent"
}

# --- 3.2 the rewrites -------------------------------------------------------

@test "agh-config: one rewrite per name in the repo's record, and no others" {
    [ "${#REWRITE_PAIRS[@]}" -eq 18 ] || fail "expected 18 names, got ${#REWRITE_PAIRS[@]}"

    apply_once
    local domains
    domains=$(grep -E '^    - domain: ' "$BATS_TEST_TMPDIR/once.yaml" | sed 's/^    - domain: //')
    [ "$(printf '%s\n' "$domains" | grep -c .)" -eq 18 ]

    local name
    while IFS= read -r name; do
        printf '%s\n' "$domains" | grep -qxF "$name" \
            || fail "$name is in the dnsmasq record but has no rewrite"
    done < <(agh_dnsmasq_hostnames < "$DNSMASQ_CONF")

    # Nothing invented, and specifically not the apex zone itself.
    printf '%s\n' "$domains" | grep -qxF 'lan' \
        && fail "a rewrite was added for the apex 'lan', which is not a host"
    return 0
}

@test "agh-config: every rewrite answers Traefik's macvlan address and is enabled" {
    apply_once
    local out="$BATS_TEST_TMPDIR/once.yaml"
    [ "$(grep -c '^      answer: 192.168.110.250$' "$out")" -eq 18 ]
    [ "$(grep -c '^      enabled: true$' "$out")" -eq 18 ]
}

@test "agh-config: an inline-empty rewrites list is replaced, and the block shape is too" {
    # `rewrites: []` is how AdGuard ships it; the block form is what the first
    # application produces. Both have to be handled.
    grep -qxF '  rewrites: []' "$LIVE"
    apply_once
    grep -qxF '  rewrites:' "$BATS_TEST_TMPDIR/once.yaml"
    grep -q '^    - domain: ' "$BATS_TEST_TMPDIR/once.yaml"

    # Second pass reads the block form.
    run agh_config_set_rewrites "${REWRITE_PAIRS[@]}" < "$BATS_TEST_TMPDIR/once.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"  rewrites:"* ]]
    [[ "$output" == *"    - domain: sonarr.lan"* ]]
}

@test "agh-config: user_rules is left exactly as it was" {
    # Task 3.3 owns AAAA behaviour and the parent decides it after measuring
    # what AdGuard answers. This transform must not have an opinion.
    apply_once
    [ "$(grep '^user_rules:' "$LIVE")" = "$(grep '^user_rules:' "$BATS_TEST_TMPDIR/once.yaml")" ]
    [ "$(grep -c '^user_rules:' "$BATS_TEST_TMPDIR/once.yaml")" -eq 1 ]

    # And with a populated user_rules block, which is the shape a later phase
    # would leave behind.
    sed 's/^user_rules: \[\]$/user_rules:\n  - \|\|example.com^\n  - @@||good.example^/' \
        "$LIVE" > "$BATS_TEST_TMPDIR/rules.yaml"
    run transform < "$BATS_TEST_TMPDIR/rules.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *'  - ||example.com^'* ]]
    [[ "$output" == *'  - @@||good.example^'* ]]
    [[ "$output" == *'  - ||example.com^'*$'\n''  - @@||good.example^'* ]]
}

# --- 3.4 the filters --------------------------------------------------------

@test "agh-config: StevenBlack is appended and the existing filter is left enabled" {
    apply_once
    local out="$BATS_TEST_TMPDIR/once.yaml"

    grep -qF "    url: $SB_URL" "$out"
    grep -qF '    name: StevenBlack hosts' "$out"
    grep -qF '    url: https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt' "$out"
    grep -qF '    name: AdGuard DNS filter' "$out"

    # The AdGuard entry keeps `enabled: true`; the disabled AdAway entry keeps
    # its own line rather than being reformatted or dropped. Matched through the
    # url, not by position, so a reordered file still says something.
    grep -B3 'name: AdGuard DNS filter' "$out" | grep -q 'enabled: true'
    grep -qxF '    url: https://adaway.org/hosts.txt' "$out"
    grep -qxF '    id: 2' "$out"
}

@test "agh-config: the new filter id does not collide with one already in the file" {
    apply_once
    grep -qxF '    id: 3' "$BATS_TEST_TMPDIR/once.yaml"
    [ "$(grep -c '^    id: ' "$BATS_TEST_TMPDIR/once.yaml")" -eq 3 ]

    # With 3 already taken, the next free id is 4.
    sed 's/^    id: 2$/    id: 3/' "$LIVE" > "$BATS_TEST_TMPDIR/id3.yaml"
    run agh_config_set_filters "$SB_URL" "$SB_NAME" < "$BATS_TEST_TMPDIR/id3.yaml"
    [ "$status" -eq 0 ]
    [[ "$output" == *'    id: 4'* ]]
}

@test "agh-config: a filter url already present is not added a second time" {
    # Matched on the url alone: a list that is present under a different name is
    # still present, and rewriting it would be a byte change for no reason.
    sed "s|^  - enabled: true\$|  - enabled: true\n    url: $SB_URL\n    name: something-else\n    id: 9|" \
        "$LIVE" > "$BATS_TEST_TMPDIR/has.yaml"
    # Only inside the filters block: the sed above also hits the first `- enabled`
    # that precedes a url line, which is the AdGuard entry. Assert on the count.
    [ "$(grep -cF "url: $SB_URL" "$BATS_TEST_TMPDIR/has.yaml")" -eq 1 ]

    run agh_config_set_filters "$SB_URL" "$SB_NAME" < "$BATS_TEST_TMPDIR/has.yaml"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/has-out.yaml"
    [ "$(grep -cF "url: $SB_URL" "$BATS_TEST_TMPDIR/has-out.yaml")" -eq 1 ]
    run cmp -s "$BATS_TEST_TMPDIR/has.yaml" "$BATS_TEST_TMPDIR/has-out.yaml"
    [ "$status" -eq 0 ] || fail "a present filter url still changed the file"
}

# --- refusals ---------------------------------------------------------------
#
# Every one of these leaves stdout EMPTY. A caller pipes this into a file that
# then gets pushed to the router, so a refusal that emitted the half-built
# config it had so far is worse than no refusal at all.

refusal_emits_nothing() {
    local out="$BATS_TEST_TMPDIR/refuse.out" err="$BATS_TEST_TMPDIR/refuse.err"
    : > "$out"; : > "$err"
    run bash -c "source '$REPO_ROOT/scripts/lib/agh-config.sh'; $1 < '$2' > '$out' 2> '$err'"
    [ "$status" -eq 2 ] || fail "expected a refusal (2), got $status: $(cat "$err")"
    [ ! -s "$out" ] || fail "the refusal wrote a partial config to stdout: $(cat "$out")"
    printf '%s' "$(cat "$err")"
}

@test "agh-config: a missing upstream_dns key is refused, not silently skipped" {
    sed '/^  upstream_dns:$/,/^  upstream_dns_file:/{/^  upstream_dns:$/d;/^    - /d;}' "$LIVE" > "$BATS_TEST_TMPDIR/nokey.yaml"
    ! grep -q '^  upstream_dns:$' "$BATS_TEST_TMPDIR/nokey.yaml"

    local msg
    msg=$(refusal_emits_nothing "agh_config_set_upstream_dns '$Q9' '$CF'" "$BATS_TEST_TMPDIR/nokey.yaml")
    [[ "$msg" == *"upstream_dns"* ]]
}

@test "agh-config: a missing filtering.rewrites key is refused" {
    sed '/^  rewrites: \[\]$/d' "$LIVE" > "$BATS_TEST_TMPDIR/norewrites.yaml"
    local msg
    msg=$(refusal_emits_nothing "agh_config_set_rewrites 'a.lan=1.2.3.4'" "$BATS_TEST_TMPDIR/norewrites.yaml")
    [[ "$msg" == *"rewrites"* ]]
}

@test "agh-config: an inline flow list that is not empty is refused" {
    # Rewriting a flow sequence in place is a different parser; guessing at it
    # would be how a wrong config reaches the router.
    sed 's/^  rewrites: \[\]$/  rewrites: [{domain: a.lan, answer: 1.2.3.4}]/' \
        "$LIVE" > "$BATS_TEST_TMPDIR/flow.yaml"
    local msg
    msg=$(refusal_emits_nothing "agh_config_set_rewrites 'a.lan=1.2.3.4'" "$BATS_TEST_TMPDIR/flow.yaml")
    [[ "$msg" == *"rewrites"* ]]
}

@test "agh-config: an empty upstream or rewrite list is refused" {
    # Emptying a resolver's upstreams, or its rewrites, is not a no-op.
    local msg
    msg=$(refusal_emits_nothing "agh_config_set_upstream_dns" "$LIVE")
    [[ "$msg" == *"upstream"* ]]

    msg=$(refusal_emits_nothing "agh_config_set_rewrites" "$LIVE")
    [[ "$msg" == *"rewrite"* ]]
}

@test "agh-config: a malformed rewrite argument is refused" {
    local msg
    msg=$(refusal_emits_nothing "agh_config_set_rewrites 'no-answer-here'" "$LIVE")
    [[ "$msg" == *"domain=answer"* ]]
}

@test "agh-config: an odd number of filter arguments is refused" {
    local msg
    msg=$(refusal_emits_nothing "agh_config_set_filters 'https://example.test/hosts.txt'" "$LIVE")
    [[ "$msg" == *"pairs"* ]]
}

# --- the name record --------------------------------------------------------

@test "agh-config: the hostnames come from the tracked dnsmasq record" {
    run agh_dnsmasq_hostnames < "$DNSMASQ_CONF"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 18 ]
    printf '%s\n' "${lines[@]}" | grep -qxF 'sonarr.lan'
    printf '%s\n' "${lines[@]}" | grep -qxF 'magnetio.lan'

    # The apex is not a host and has no rewrite; the comments are not data.
    printf '%s\n' "${lines[@]}" | grep -qxF 'lan' && fail "the apex 'lan' was parsed as a hostname"
    printf '%s\n' "${lines[@]}" | grep -q '^#' && fail "a comment line was parsed as a hostname"
    return 0
}

@test "agh-config: the name record's own placeholder is not mistaken for an answer" {
    # `address=/jellyfin.lan/TRAEFIK_LAN_IP` — only the middle field is a name.
    run agh_dnsmasq_hostnames < "$DNSMASQ_CONF"
    [ "$status" -eq 0 ]
    printf '%s\n' "${lines[@]}" | grep -q 'TRAEFIK' && fail "the placeholder was parsed as part of a name"
    return 0
}

@test "agh-config: duplicate names are reported once" {
    printf '%s\n' \
        'address=/a.lan/1.1.1.1' \
        'address=/b.lan/1.1.1.1' \
        'address=/a.lan/1.1.1.1' \
        'address=/lan/::' > "$BATS_TEST_TMPDIR/dupes.conf"
    run agh_dnsmasq_hostnames < "$BATS_TEST_TMPDIR/dupes.conf"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "agh-config: a name record with no hostnames is refused" {
    # Wiping every rewrite because the parse came back empty is exactly the
    # silent change this refusal exists to prevent.
    printf 'address=/lan/::\n# nothing else\n' > "$BATS_TEST_TMPDIR/empty.conf"
    run agh_dnsmasq_hostnames < "$BATS_TEST_TMPDIR/empty.conf"
    [ "$status" -eq 2 ]
    [[ "$output" == *"no hostnames"* ]]
}
