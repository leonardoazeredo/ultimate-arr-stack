#!/usr/bin/env bats
# Tests for the pre-commit check scripts themselves

setup() {
    load helpers/setup
    # Source the check scripts
    source "$REPO_ROOT/scripts/lib/common.sh"
}

@test "check_secrets catches a known WireGuard key pattern" {
    source "$REPO_ROOT/scripts/lib/check-secrets.sh"

    # Copy fixture to a temp path that won't match the tests/fixtures/* skip rule
    local tmpdir
    tmpdir=$(mktemp -d)
    cp "$REPO_ROOT/tests/fixtures/compose-with-secrets.yml" "$tmpdir/docker-compose.secrets.yml"

    # Override get_files_to_scan to return the temp copy
    get_files_to_scan() {
        echo "docker-compose.secrets.yml"
    }

    # Override read_file_content to read from the temp dir
    read_file_content() {
        cat "$tmpdir/$1" 2>/dev/null
    }

    run check_secrets
    assert_failure
    assert_output --partial "WireGuard private key"

    rm -rf "$tmpdir"
}

@test "check_env_vars catches an undocumented variable" {
    source "$REPO_ROOT/scripts/lib/check-env-vars.sh"

    # Create a temp compose file with an undocumented var
    local tmpdir
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/docker-compose.test.yml" <<'EOF'
services:
  test:
    image: alpine:3.20
    environment:
      - UNDOCUMENTED_VAR_XYZZY=${UNDOCUMENTED_VAR_XYZZY}
EOF

    # Run check_env_vars in a subshell with overridden repo root
    run bash -c "
        source '$REPO_ROOT/scripts/lib/common.sh'
        source '$REPO_ROOT/scripts/lib/check-env-vars.sh'
        # Override git rev-parse to use tmpdir
        git() { echo '$tmpdir'; }
        export -f git
        # Copy .env.example to tmpdir
        cp '$REPO_ROOT/.env.example' '$tmpdir/'
        check_env_vars
    "
    assert_failure
    assert_output --partial "UNDOCUMENTED_VAR_XYZZY"

    rm -rf "$tmpdir"
}

@test "check_conflicts catches duplicate ports within a file" {
    source "$REPO_ROOT/scripts/lib/check-conflicts.sh"

    # Create a temp dir with a conflicting compose file
    local tmpdir
    tmpdir=$(mktemp -d)
    cp "$REPO_ROOT/tests/fixtures/compose-port-conflict.yml" "$tmpdir/docker-compose.conflict.yml"

    run bash -c "
        source '$REPO_ROOT/scripts/lib/check-conflicts.sh'
        # Override git rev-parse to use tmpdir
        git() { echo '$tmpdir'; }
        export -f git
        check_conflicts
    "
    assert_failure
    assert_output --partial "Duplicate ports"

    rm -rf "$tmpdir"
}

@test "check_conflicts catches cross-file port duplicates" {
    source "$REPO_ROOT/scripts/lib/check-conflicts.sh"

    # Create two compose files with same port in different files
    local tmpdir
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/docker-compose.a.yml" <<'EOF'
services:
  svc-a:
    image: alpine:3.20
    ports:
      - "9999:80"
EOF
    cat > "$tmpdir/docker-compose.b.yml" <<'EOF'
services:
  svc-b:
    image: alpine:3.20
    ports:
      - "9999:8080"
EOF

    run bash -c "
        source '$REPO_ROOT/scripts/lib/check-conflicts.sh'
        git() { echo '$tmpdir'; }
        export -f git
        check_conflicts
    "
    assert_failure
    assert_output --partial "Port 9999 used across multiple files"

    rm -rf "$tmpdir"
}

# --- Gaps found by generative mutation testing, 2026-09-01 -------------------
#
# Everything below exists because ./tests/mutation/run-generated.sh mutated
# scripts/lib/ and these mutants survived: the defect was introduced and the
# suite stayed green. Each test names the mutant it kills, so a later reader can
# tell what it is for -- a test whose purpose is invisible is how this repo
# ended up with four guards that could not fail.

@test "check_conflicts catches duplicate static IPs within a file" {
    # Kills: `grep -oE` -> `grep -o` (check-conflicts.sh:34), `[[ -n "$dup_ips" ]]`
    # -> `-z` (:39). Both survived because BOTH pre-existing conflict tests used
    # ports only -- the entire static-IP half of this check had no test at all.
    # That matters here specifically: CLAUDE.md pins static IPs precisely because
    # docker's ip_range confines dynamic allocation, so a collision is silent
    # until a container restarts onto an address something else already holds.
    local tmpdir
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/docker-compose.dupip.yml" <<'EOF'
services:
  svc-a:
    image: alpine:3.20
    networks:
      arr-core:
        ipv4_address: 172.20.0.42
  svc-b:
    image: alpine:3.20
    networks:
      arr-core:
        ipv4_address: 172.20.0.42
EOF

    run bash -c "
        source '$REPO_ROOT/scripts/lib/check-conflicts.sh'
        git() { echo '$tmpdir'; }
        export -f git
        check_conflicts
    "
    assert_failure
    assert_output --partial "Duplicate static IPs in docker-compose.dupip.yml"
    assert_output --partial "172.20.0.42"

    rm -rf "$tmpdir"
}

@test "check_conflicts catches cross-file static IP duplicates" {
    # Kills: `grep -oE` -> `grep -o` (:70), `$1 == i` -> `$1 != i` (:101),
    # `[[ -z "$ip" ]]` flips (:99).
    local tmpdir
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/docker-compose.a.yml" <<'EOF'
services:
  svc-a:
    image: alpine:3.20
    networks:
      arr-core:
        ipv4_address: 172.20.0.77
EOF
    cat > "$tmpdir/docker-compose.b.yml" <<'EOF'
services:
  svc-b:
    image: alpine:3.20
    networks:
      arr-core:
        ipv4_address: 172.20.0.77
EOF

    run bash -c "
        source '$REPO_ROOT/scripts/lib/check-conflicts.sh'
        git() { echo '$tmpdir'; }
        export -f git
        check_conflicts
    "
    assert_failure
    assert_output --partial "IP 172.20.0.77 used across multiple files"
    assert_output --partial "docker-compose.a.yml"
    assert_output --partial "docker-compose.b.yml"

    rm -rf "$tmpdir"
}

@test "check_conflicts does not report a within-file duplicate as cross-file" {
    # Kills: `-gt 1` -> `-ge 1` (check-conflicts.sh:86 and :104).
    #
    # `uniq -d` feeds the cross-file loop every value that appears more than
    # once ANYWHERE, including twice inside one file. `-gt 1` is what separates
    # those two cases. Both pre-existing tests asserted only that the expected
    # message appeared; neither asserted that the wrong one did not, so the
    # mutant's spurious "used across multiple files" went unnoticed. Getting the
    # right message is not proof the check is right -- it also has to not emit
    # the wrong one.
    local tmpdir
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/docker-compose.only.yml" <<'EOF'
services:
  svc-a:
    image: alpine:3.20
    ports:
      - "9998:80"
      - "9998:81"
    networks:
      arr-core:
        ipv4_address: 172.20.0.88
  svc-b:
    image: alpine:3.20
    networks:
      arr-core:
        ipv4_address: 172.20.0.88
EOF

    run bash -c "
        source '$REPO_ROOT/scripts/lib/check-conflicts.sh'
        git() { echo '$tmpdir'; }
        export -f git
        check_conflicts
    "
    # It must still fail -- these ARE duplicates, just not cross-file ones.
    assert_failure
    assert_output --partial "Duplicate ports in docker-compose.only.yml"
    refute_output --partial "used across multiple files"
}

@test "check_env_vars matches variable names exactly, not as substrings" {
    # Kills: `grep -qx "$var"` -> `grep -q "$var"` (check-env-vars.sh:46).
    #
    # This is the same defect that generative mutation testing already found
    # once in this repo -- `grep -Fxq` -> `grep -Fq` in the backup volume
    # resolver, where it survived all 18 tests around it. Whole-line matching is
    # the entire point: with `-q`, an undocumented ${NAS_IP} is considered
    # documented because .env.example happens to mention NAS_IP_RANGE, and the
    # guard reports success while the variable is genuinely missing.
    local tmpdir
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/docker-compose.substr.yml" <<'EOF'
services:
  svc-a:
    image: alpine:3.20
    environment:
      - THING=${NAS_IP}
EOF
    # NAS_IP itself is absent; only a variable it is a substring of is present.
    cat > "$tmpdir/.env.example" <<'EOF'
NAS_IP_RANGE=192.0.2.0/24
EOF

    run bash -c "
        source '$REPO_ROOT/scripts/lib/check-env-vars.sh'
        git() { echo '$tmpdir'; }
        export -f git
        check_env_vars
    "
    assert_failure
    assert_output --partial "NAS_IP"

    rm -rf "$tmpdir"
}

@test "check_env_vars fails when .env.example is missing" {
    # Kills: `return 1` -> `return 0` (check-env-vars.sh:34).
    #
    # A silent-success mutant, this repo's most expensive defect shape: with no
    # .env.example the check printed its ERROR line and then reported success,
    # so every commit's env-var verification was skipped while looking green.
    local tmpdir
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/docker-compose.noenv.yml" <<'EOF'
services:
  svc-a:
    image: alpine:3.20
    environment:
      - THING=${SOME_VAR}
EOF

    run bash -c "
        source '$REPO_ROOT/scripts/lib/check-env-vars.sh'
        git() { echo '$tmpdir'; }
        export -f git
        check_env_vars
    "
    assert_failure
    assert_output --partial ".env.example not found"

    rm -rf "$tmpdir"
}
