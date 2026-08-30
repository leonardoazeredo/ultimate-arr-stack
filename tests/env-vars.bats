#!/usr/bin/env bats
# Environment variable coverage tests

setup() {
    load helpers/setup
}

@test "all compose variables are documented in .env.example" {
    local env_example="$REPO_ROOT/.env.example"
    [[ -f "$env_example" ]] || skip ".env.example not found"

    # Extract vars from .env.example (including commented ones)
    local documented_vars
    documented_vars=$(grep -E '^[# ]*[A-Z_][A-Z0-9_]*=' "$env_example" | \
        sed -E 's/^[# ]*([A-Z_][A-Z0-9_]*)=.*/\1/' | sort -u)

    # Extract all ${VAR} from compose files
    local missing=""
    for f in $(get_compose_files); do
        while IFS= read -r var; do
            [[ -z "$var" ]] && continue
            if ! echo "$documented_vars" | grep -qx "$var"; then
                missing+="  $var (in $(basename "$f"))\n"
            fi
        done < <(grep -oE '\$\{[A-Z_][A-Z0-9_]*' "$f" | sed 's/\${//' | sort -u)
    done

    if [[ -n "$missing" ]]; then
        fail "Variables not in .env.example:\n$missing"
    fi
}

@test ".env.example has no real secret values" {
    local env_example="$REPO_ROOT/.env.example"
    [[ -f "$env_example" ]] || skip ".env.example not found"

    # Check for patterns that look like real secrets (not placeholders)
    # WireGuard keys: 44 chars base64 ending in =
    if grep -E 'WIREGUARD_PRIVATE_KEY=[A-Za-z0-9+/]{43}=' "$env_example" | \
       grep -qvE '(your|here|example|placeholder|xxx)'; then
        fail ".env.example contains what looks like a real WireGuard key"
    fi

    # JWT tokens
    if grep -qE '=eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' "$env_example"; then
        fail ".env.example contains what looks like a JWT token"
    fi

    # Long random-looking strings in password fields
    if grep -E '(PASSWORD|SECRET)=[A-Za-z0-9+/]{30,}' "$env_example" | \
       grep -qvE '(your|here|example|placeholder|xxx|bcrypt)'; then
        fail ".env.example contains what looks like a real password"
    fi
}

# Guards against the class of drift that put NAS_IP=192.168.1.102 in the same
# file as LAN_SUBNET=10.10.0.0/24: every host address the stack pins must sit
# inside the LAN it claims. gluetun's FIREWALL_OUTBOUND_SUBNETS is built from
# ${LAN_SUBNET}, so a host outside it is silently unreachable from the tunnel.
ip_to_int() {
    local IFS=.
    read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# ─── LAN_SUBNET / EXTRA_LAN_SUBNETS grammar ─────────────────────────────────
# On 2026-08-30 the NAS .env held LAN_SUBNET=192.168.110.0/24,192.168.120.0/24.
# That is legal for the gluetun killswitch and FATAL for Traefik's macvlan, which
# takes exactly one CIDR. `docker compose up -d traefik` stopped Traefik, DELETED
# the traefik-lan network, then failed to recreate it -- every .lan name went down.
#
# `docker compose config` will NOT catch this: it only interpolates, and the CIDR
# grammar is enforced by the network driver at creation time, i.e. after the old
# network is already gone. Verified against the real broken .env -- it reported
# the file VALID. So the check has to live here.
#
# The test below at ":66" is a second victim of the same value: `prefix=${subnet#*/}`
# feeding `$(( 32 - prefix ))` is a bash arithmetic syntax error on a comma form.

# One CIDR, with real bounds -- not just "digits, dot, digits".
is_cidr() {
    local c="$1" ip prefix o
    [[ "$c" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    ip="${c%/*}"; prefix="${c#*/}"
    (( 10#$prefix <= 32 )) || return 1
    local IFS=.
    for o in $ip; do (( 10#$o <= 255 )) || return 1; done
    return 0
}

# The .env the suite can actually see. On pi1/CI that is .env.example (the real
# .env is gitignored); on the NAS it is the deployed one. Reported either way so
# a pass never hides WHICH file was checked.
grammar_envfile() {
    if [[ -f "$REPO_ROOT/.env" ]]; then printf '%s' "$REPO_ROOT/.env"
    else printf '%s' "$REPO_ROOT/.env.example"; fi
}

# Trims quotes, CR and surrounding whitespace ONLY. It must not delete interior
# spaces: `a/24, b/24` is a real error and stripping it would make the guard below
# unable to fail, which is the whole defect class these tests exist to catch.
env_value() {
    grep -E "^[[:space:]]*${1}=" "$2" | tail -1 | cut -d= -f2- \
        | tr -d "\"'\r" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

@test "LAN_SUBNET is exactly one CIDR (Traefik's macvlan cannot parse a list)" {
    local f; f=$(grammar_envfile)
    [[ -f "$f" ]] || skip "no .env or .env.example to check"

    # Guard against this test silently outliving the thing it protects.
    grep -qE '^[[:space:]]*- subnet: \$\{LAN_SUBNET\}' "$REPO_ROOT/docker-compose.traefik.yml" \
        || skip "docker-compose.traefik.yml no longer interpolates LAN_SUBNET into a macvlan subnet"

    local val; val=$(env_value LAN_SUBNET "$f")
    [[ -n "$val" ]] || skip "LAN_SUBNET not set in $(basename "$f")"

    is_cidr "$val" || fail "LAN_SUBNET must be exactly one CIDR, got:"$'\n'"  LAN_SUBNET=$val  (in $(basename "$f"))"$'\n'"A comma-joined value is tolerated by gluetun's FIREWALL_OUTBOUND_SUBNETS but destroys the traefik-lan macvlan on its next recreate. Put further subnets in EXTRA_LAN_SUBNETS."
}

@test "EXTRA_LAN_SUBNETS is a clean comma-separated CIDR list" {
    local f; f=$(grammar_envfile)
    [[ -f "$f" ]] || skip "no .env or .env.example to check"

    local val; val=$(env_value EXTRA_LAN_SUBNETS "$f")
    [[ -n "$val" ]] || skip "EXTRA_LAN_SUBNETS is unset or empty in $(basename "$f") - nothing to validate"

    # Structure is checked on the RAW string first. Splitting on commas cannot
    # detect a trailing comma -- bash word-splitting discards the empty trailing
    # field -- so a split-then-check guard would pass on `10.0.0.0/24,` forever.
    local bad="" part
    [[ "$val" == ,* || "$val" == *, ]] && bad+="  leading or trailing comma"$'\n'
    [[ "$val" == *,,* ]]               && bad+="  empty element (',,')"$'\n'
    [[ "$val" == *[[:space:]]* ]]      && bad+="  contains whitespace"$'\n'

    local IFS=,
    for part in $val; do
        is_cidr "$part" || bad+="  '${part}' is not a CIDR"$'\n'
    done
    [[ -z "$bad" ]] || fail "EXTRA_LAN_SUBNETS must be CIDRs separated by commas, no spaces:"$'\n'"  EXTRA_LAN_SUBNETS=$val  (in $(basename "$f"))"$'\n'"$bad"
}

@test ".env.example host IPs all fall inside LAN_SUBNET" {
    local env_example="$REPO_ROOT/.env.example"
    [[ -f "$env_example" ]] || skip ".env.example not found"

    local subnet
    subnet=$(grep -E '^LAN_SUBNET=' "$env_example" | head -1 | cut -d= -f2)
    [[ -n "$subnet" ]] || skip "LAN_SUBNET not set in .env.example"

    local net prefix mask net_int
    net=${subnet%/*}
    prefix=${subnet#*/}
    mask=$(( 0xFFFFFFFF ^ ((1 << (32 - prefix)) - 1) ))
    net_int=$(( $(ip_to_int "$net") & mask ))

    local outside=""
    for var in NAS_IP PI1_IP PI2_IP TRAEFIK_LAN_IP; do
        local val
        val=$(grep -E "^${var}=" "$env_example" | head -1 | cut -d= -f2)
        [[ -n "$val" ]] || continue
        [[ "$val" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        if [[ $(( $(ip_to_int "$val") & mask )) -ne $net_int ]]; then
            outside+="  $var=$val is outside LAN_SUBNET=$subnet\n"
        fi
    done

    if [[ -n "$outside" ]]; then
        fail "Host IPs outside their own LAN_SUBNET:\n$outside"
    fi
}

# ─── magnetio /stats credentials ────────────────────────────────────────────
# magnetio-addon's basic auth falls back to the published upstream default
# admin/magnetio when METRICS_USER/METRICS_PASSWORD are unset
# (magnetio/addon/index.js:18-19, magnetio/addon/serverless.js:153-154).
# Found live on the NAS 2026-08-30 serving /stats on those defaults.
#
# A bare ${METRICS_USER} does NOT fix this: an unset compose variable expands
# to the empty string, which is falsy in JS, so the `|| 'admin'` fallback still
# fires. Only the required form ${VAR:?...} makes the misconfiguration loud.
# These tests exist to stop that distinction being lost in a later edit.

@test "magnetio-addon sets METRICS_USER and METRICS_PASSWORD" {
    local f="$REPO_ROOT/docker-compose.magnetio.yml"
    [[ -f "$f" ]] || skip "docker-compose.magnetio.yml not found"

    for var in METRICS_USER METRICS_PASSWORD; do
        grep -qE "^[[:space:]]*-[[:space:]]*${var}=" "$f" \
            || fail "$var is not set on magnetio-addon - /stats falls back to admin/magnetio"
    done
}

@test "magnetio metrics credentials use the required-variable form" {
    local f="$REPO_ROOT/docker-compose.magnetio.yml"
    [[ -f "$f" ]] || skip "docker-compose.magnetio.yml not found"

    for var in METRICS_USER METRICS_PASSWORD; do
        local line
        line=$(grep -E "^[[:space:]]*-[[:space:]]*${var}=" "$f" | head -1)
        [[ -n "$line" ]] || fail "$var not set at all"
        # Anchored whole-value match, not a substring: the value must be
        # EXACTLY ${VAR:?message} and nothing else. A substring test passes
        # `- METRICS_USER=fallback_${METRICS_USER:?err}`, which still hands the
        # addon a usable value and defeats the point. A bare ${VAR} or
        # ${VAR:-default} likewise leave an empty string / a default in place,
        # and the addon falls back to admin.
        echo "$line" | grep -qE "^[[:space:]]*-[[:space:]]*${var}=\\\$\{${var}:\?[^}]+\}[[:space:]]*$" \
            || fail "$var must be exactly \${${var}:?...}, got: $line"
    done
}

@test "magnetio metrics credentials are documented in .env.example" {
    local f="$REPO_ROOT/.env.example"
    [[ -f "$f" ]] || skip ".env.example not found"

    for var in METRICS_USER METRICS_PASSWORD; do
        grep -qE "^[# ]*${var}=" "$f" || fail "$var is not documented in .env.example"
    done
}

# The compose-side fix above is only necessary because the vendored addon
# source falls back to published upstream defaults. That coupling is invisible
# from the compose file, so assert it directly: if a future sync of
# magnetio/addon/ removes the fallback, this fails and forces someone to
# re-read whether the ${VAR:?} requirement is still buying anything - rather
# than leaving a rationale in the compose file that quietly stopped being true.
@test "magnetio addon source still has the default-credential fallback the compose fix exists for" {
    local idx="$REPO_ROOT/magnetio/addon/index.js"
    local srv="$REPO_ROOT/magnetio/addon/serverless.js"
    [[ -f "$idx" && -f "$srv" ]] || skip "vendored magnetio addon source not present"

    local found=0
    for f in "$idx" "$srv"; do
        if grep -qE "process\.env\.METRICS_(USER|PASSWORD)[[:space:]]*\|\|" "$f"; then
            found=$((found + 1))
        fi
    done

    [[ "$found" -eq 2 ]] || fail \
        "Expected the METRICS_* '|| default' fallback in BOTH index.js and serverless.js, found it in $found. If upstream removed it, re-evaluate whether docker-compose.magnetio.yml still needs the \${VAR:?} required form and update the rationale there."
}

# ─── the guard must actually be wired into the deploy path ──────────────────
# The grammar guard above is only as good as where it runs. In CI it executes
# on ubuntu-latest, which has no .env, so it falls back to the always-clean
# committed .env.example and cannot fail. The value that took every .lan
# hostname down lived in the NAS's real, untracked .env. So the workflow has to
# run this file ON THE NAS, after the sync and before any recreate -- and that
# ordering has to be asserted, or a future reshuffle silently reopens the gap
# without breaking a single test.

@test "nas-auto-deploy validates the NAS .env after syncing and before recreating" {
    local wf="$REPO_ROOT/.github/workflows/nas-auto-deploy.yml"
    [[ -f "$wf" ]] || skip "nas-auto-deploy.yml not present"

    # This assertion only means something while the workflow still recreates
    # services on the NAS. Skipping on a missing step name alone would let an
    # incomplete cleanup hide here, so only skip when NOTHING in the workflow
    # recreates anything -- i.e. the hazard is genuinely gone, not renamed.
    local recreate
    recreate=$(grep -n '^      - name: Recreate affected services' "$wf" | cut -d: -f1)
    if [[ -z "$recreate" ]]; then
        grep -qE '^[^#]*docker compose .*up ' "$wf" \
            && fail "the 'Recreate affected services' step was renamed or restructured, but the workflow still runs a compose recreate. Re-point this test at the new step rather than letting it skip."
        skip "workflow no longer recreates anything on the NAS -- the hazard this guards is gone"
    fi

    local sync validate
    sync=$(grep -n '^      - name: Sync branch to NAS' "$wf" | cut -d: -f1)
    # The guard invocation itself, not a step name -- a renamed step still
    # passes, a deleted one does not. `^[^#]*` rejects a commented-out step:
    # both reviewers of this change independently caught that a bare substring
    # match passes against a fully commented-out block, and a direct test
    # confirmed it. A guard that survives its own subject being commented out
    # is the could-not-fail defect this file exists to catch.
    validate=$(grep -n '^[^#]*run-tests\.sh tests/env-vars\.bats' "$wf" | cut -d: -f1)

    [[ -n "$validate" ]] || fail "nas-auto-deploy.yml never runs tests/env-vars.bats on the NAS."\n'"Without it the deploy pipeline recreates services against an .env that nothing has validated -- exactly how the traefik-lan macvlan was destroyed."

    [[ $(wc -l <<<"$validate") -eq 1 ]] || fail "expected exactly one NAS env-vars invocation, found:"\n'"$validate"

    [[ -n "$sync" ]] || fail "no 'Sync branch to NAS' step -- cannot prove the guard runs against the branch's own copy"

    # Present but disabled is the same as absent. A step carrying `if:` may
    # never execute (`if: false`, or a condition that is simply never true),
    # and a line-presence check cannot see that. The validation step must be
    # unconditional -- it guards a recreate that would already have detonated.
    local step_start step_body
    step_start=$(grep -n '^      - name: .*Validate the NAS .env' "$wf" | cut -d: -f1)
    if [[ -n "$step_start" ]]; then
        step_body=$(awk -v s="$step_start" 'NR>s && /^      - name: /{exit} NR>=s' "$wf")
        grep -qE '^        if:' <<<"$step_body" \
            && fail "the NAS .env validation step carries an 'if:' condition, so it may never run. This step must be unconditional -- unlike the recreate it protects, there is nothing to skip it for."
    fi
    (( sync < validate )) || fail "the NAS .env validation (line $validate) runs BEFORE the sync (line $sync), so it tests whatever was already on the NAS, not this branch."
    (( validate < recreate )) || fail "the NAS .env validation (line $validate) runs AFTER 'Recreate affected services' (line $recreate). A bad .env would detonate before it is ever checked."
}
