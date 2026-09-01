#!/usr/bin/env bats
# scripts/lib/check-secrets.sh
#
# Nine patterns, all reported through one helper, all read through the two
# seams every check in scripts/lib/ uses. The tests below are grouped by the
# thing that actually decides whether a finding is reported:
#
#   * the skip list       -- files never scanned at all
#   * the pattern itself  -- what a hit looks like, and what a near-miss does
#   * the allowlist       -- which hits are excused as placeholders
#   * the status          -- what check_secrets returns to the hook
#
# The allowlist group carries the most weight. Until 2026-09-01 the allowlist
# was applied to the whole set of hits in a file at once, so a single
# `PASSWORD=your-password-here` line excused every real credential beside it.
# A test that only ever puts one hit in a file cannot see that, which is why
# every allowlist test here uses two.

setup() {
    load helpers/setup
    source "$REPO_ROOT/scripts/lib/common.sh"
    source "$REPO_ROOT/scripts/lib/check-secrets.sh"

    # common.sh caches config in globals behind _LOADED flags, so whichever
    # test ran first would otherwise decide the answer for the rest.
    _NAS_CONFIG_LOADED=true
    _DOMAIN_LOADED=true

    FILES="$BATS_TEST_TMPDIR/files"
    mkdir -p "$FILES"

    get_files_to_scan() { (cd "$FILES" && find . -type f | sed 's|^\./||' | sort); }
    read_file_content() { cat "$FILES/$1" 2>/dev/null; }

    # The realistic-looking values every positive test needs. They are read from
    # tests/fixtures/ rather than written inline because check-secrets.sh scans
    # this repo too -- an inline copy made it flag this very file and block every
    # later commit. The file explains itself; the short shell names are what keep
    # the literals out of this one.
    # shellcheck source=tests/fixtures/secret-samples.env
    source "$REPO_ROOT/tests/fixtures/secret-samples.env"
}

# A run of $1 identical characters, for the tests that assert on the 15-character
# boundary. Built rather than typed so the length is stated as a number instead of
# being something a reader has to count -- and so the literal never appears here.
chars() { printf 'a%.0s' $(seq 1 "$1"); }

fixture() { mkdir -p "$FILES/$(dirname "$1")"; printf '%s\n' "$2" > "$FILES/$1"; }


# --- The skip list ----------------------------------------------------------

@test "secrets: nothing to scan is a pass, not a crash" {
    run check_secrets
    assert_success
    refute_output --partial "ERROR"
}

@test "secrets: .env is never scanned" {
    fixture ".env" "SSH_PASSWORD=$REAL_PW"
    run check_secrets
    assert_success
}

@test "secrets: documentation is never scanned" {
    fixture "docs/NOTES.md" "SSH_PASSWORD=$REAL_PW"
    run check_secrets
    assert_success
}

@test "secrets: the check scripts themselves are never scanned" {
    fixture "scripts/lib/check-secrets.sh" "SSH_PASSWORD=$REAL_PW"
    fixture "scripts/lib/common.sh" "SSH_PASSWORD=$REAL_PW"
    run check_secrets
    assert_success
}

@test "secrets: tests/fixtures holds intentional fake secrets and is skipped" {
    fixture "tests/fixtures/compose.yml" "SSH_PASSWORD=$REAL_PW"
    run check_secrets
    assert_success
}

@test "secrets: binary extensions are skipped by name" {
    for ext in png jpg gif ico woff woff2 ttf eot; do
        fixture "assets/logo.$ext" "SSH_PASSWORD=$REAL_PW"
    done
    run check_secrets
    assert_success
}

@test "secrets: a listed file that cannot be read is skipped, not a finding" {
    get_files_to_scan() { echo "gone.yml"; }
    run check_secrets
    assert_success
}

@test "secrets: a .bats file is NOT skipped" {
    # Deliberate, and load-bearing: tests/*.bats is where a real credential is
    # most likely to be pasted while debugging. tests/configure-apps.bats
    # carries a comment saying so, because its own fixture values had to be
    # renamed to placeholders rather than the exemption being widened.
    fixture "tests/some.bats" "SSH_PASSWORD=$REAL_PW"
    run check_secrets
    assert_failure
    assert_output --partial "Possible password in tests/some.bats"
}

# --- The patterns -----------------------------------------------------------

@test "secrets: pattern 1 reports a WireGuard private key" {
    fixture "compose.yml" "      - WIREGUARD_PRIVATE_KEY=$WG_SAMPLE="
    run check_secrets
    assert_failure
    assert_output --partial "Possible WireGuard private key in compose.yml"
}

@test "secrets: the captured compose fixture is still caught" {
    # tests/fixtures/compose-with-secrets.yml is a real captured compose file
    # rather than a hand-written line, and it is copied to a path outside
    # tests/fixtures/ because that prefix is on the skip list. This was the
    # file's only test before it had any others; it stays because a
    # hand-written pattern probe and a real file are not the same evidence.
    mkdir -p "$FILES"
    cp "$REPO_ROOT/tests/fixtures/compose-with-secrets.yml" "$FILES/docker-compose.secrets.yml"
    run check_secrets
    assert_failure
    assert_output --partial "WireGuard private key"
}

@test "secrets: pattern 2 reports a Cloudflare API token" {
    fixture ".env.real" "CF_DNS_API_TOKEN=$CF_SAMPLE"
    run check_secrets
    assert_failure
    assert_output --partial "Possible Cloudflare API token in .env.real"
}

@test "secrets: pattern 3 reports a tunnel token and has no placeholder escape" {
    # No allowlist by design: a well-formed JWT is not something anyone writes
    # as an example, so the word 'example' beside one must not excuse it.
    fixture ".env.real" "TUNNEL_TOKEN=$JWT_SAMPLE"
    run check_secrets
    assert_failure
    assert_output --partial "Possible Cloudflare tunnel token in .env.real"
}

@test "secrets: pattern 4 reports a bcrypt hash" {
    fixture "traefik/users" "admin:\$2y\$10\$$BCRYPT_SAMPLE"
    run check_secrets
    assert_failure
    assert_output --partial "Possible bcrypt password hash in traefik/users"
}

@test "secrets: pattern 4 does NOT accept xxx as a placeholder" {
    # The other patterns allow 'xxx'; this one deliberately does not, because
    # xxx is a plausible substring of a real 53-char base64 tail. Pinning the
    # asymmetry so a tidy-up cannot quietly make the allowlists uniform.
    fixture "traefik/users" "admin:\$2y\$10\$xxx${BCRYPT_SAMPLE:3}"
    run check_secrets
    assert_failure
    assert_output --partial "Possible bcrypt password hash"
}

@test "secrets: pattern 5 reports a PEM private key block" {
    fixture "certs/key.pem" "-----BEGIN OPENSSH PRIVATE KEY-----"
    run check_secrets
    assert_failure
    assert_output --partial "Private key block detected in certs/key.pem"
}

@test "secrets: pattern 6 reports a long base64 value" {
    fixture ".env.real" "API_KEY=YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODk="
    run check_secrets
    assert_failure
    assert_output --partial "ERROR: Possible secret value in .env.real"
}

@test "secrets: pattern 7 reports an OpenVPN credential" {
    fixture ".env.real" "OPENVPN_PASSWORD=$OVPN_PW"
    run check_secrets
    assert_failure
    assert_output --partial "Possible OpenVPN credential in .env.real"
}

@test "secrets: pattern 8 reports a bearer token" {
    fixture "docs/req.http" "Authorization: Bearer $BEARER_SAMPLE"
    run check_secrets
    assert_failure
    assert_output --partial "Possible auth token in docs/req.http"
}

@test "secrets: pattern 9 reports a password of 15 characters, as an ERROR" {
    # 15 is the boundary the pattern names, so it is asserted at the boundary
    # rather than somewhere comfortably past it.
    #
    # The severity word is asserted too. Patterns 6 and 9 used to print
    # WARNING while still incrementing the same counter every ERROR fed, so
    # the hook printed a warning and then blocked on it -- the label and the
    # effect disagreed, and the only way to tell which warning was the error
    # was to count them. They block, so they say ERROR.
    fixture ".env.real" "SSH_PASSWORD=$(chars 15)"
    run check_secrets
    assert_failure
    assert_output --partial "ERROR: Possible password in .env.real"
}

@test "secrets: pattern 9 ignores a password of 14 characters" {
    fixture ".env.real" "SSH_PASSWORD=$(chars 14)"
    run check_secrets
    assert_success
}

@test "secrets: pattern 9 ignores shell variable references" {
    fixture "compose.yml" 'QBIT_PASSWORD="${QBIT_PASSWORD:-}"'
    fixture "compose2.yml" 'QBIT_PASSWORD=${QBIT_PASSWORD_FROM_ENV}'
    fixture "run.sh" 'QBIT_PASSWORD=$(read_secret_from_somewhere_else)'
    run check_secrets
    assert_success
}

# --- The allowlist ----------------------------------------------------------

@test "secrets: a placeholder value is excused" {
    fixture ".env.example" "SSH_PASSWORD=your-password-here"
    run check_secrets
    assert_success
}

@test "secrets: each of the five placeholder words is excused" {
    local value
    for word in your here example placeholder xxx; do
        # Assembled into a variable first: written inline, the resulting line
        # would be 15+ non-placeholder characters in THIS file's source and the
        # pre-commit hook would flag the test that proves the hook works.
        value="$(chars 10)-${word}-$(chars 10)"
        fixture ".env.$word" "SSH_PASSWORD=$value"
    done
    run check_secrets
    assert_success
}

@test "secrets: a placeholder excuses only itself, not a real value beside it" {
    # THE defect this file exists for. The allowlist used to be applied to the
    # whole set of hits at once, so this file returned 0 and printed nothing.
    fixture ".env.real" "SSH_PASSWORD=your-password-here
SSH_PASSWORD=$REAL_PW"
    run check_secrets
    assert_failure
    assert_output --partial "Possible password in .env.real"
}

@test "secrets: the same leak-past-a-placeholder holds for a WireGuard key" {
    # Same shape, different pattern, because the joined-set bug was in the
    # shared idiom rather than in any one pattern.
    fixture "compose.yml" "      - WIREGUARD_PRIVATE_KEY=your-key-here-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=
      - WIREGUARD_PRIVATE_KEY=$WG_SAMPLE="
    run check_secrets
    assert_failure
    assert_output --partial "Possible WireGuard private key in compose.yml"
}

@test "secrets: a placeholder in one file does not excuse another file" {
    fixture ".env.example" "SSH_PASSWORD=your-password-here"
    fixture ".env.real" "SSH_PASSWORD=$REAL_PW"
    run check_secrets
    assert_failure
    assert_output --partial "in .env.real"
    refute_output --partial "in .env.example"
}

@test "secrets: the allowlist is case-insensitive" {
    fixture ".env.example" "SSH_PASSWORD=YOUR-PASSWORD-HERE"
    run check_secrets
    assert_success
}

# --- The status -------------------------------------------------------------

@test "secrets: findings in several files are all named" {
    fixture "a.yml" "SSH_PASSWORD=$REAL_PW"
    fixture "b.yml" "-----BEGIN RSA PRIVATE KEY-----"
    run check_secrets
    assert_failure
    assert_output --partial "in a.yml"
    assert_output --partial "in b.yml"
    assert_output --partial "2 secret finding(s)"
}

@test "secrets: the status is a boolean, so 256 findings still fail" {
    # `return $errors` put an unbounded count into one byte. At exactly 256 it
    # returned 0 and the hook reported the tree clean. One finding per file,
    # since errors increments once per pattern per file.
    for i in $(seq 1 256); do
        fixture "keys/k$i.pem" "-----BEGIN RSA PRIVATE KEY-----"
    done
    run check_secrets
    assert_failure
    assert_output --partial "256 secret finding(s)"
}
