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
        # ${VAR:?...} only. A bare ${VAR} or ${VAR:-default} both leave the
        # empty string / a default in place, and the addon falls back to admin.
        echo "$line" | grep -qE "\\\$\{${var}:\?" \
            || fail "$var must use \${${var}:?...}, got: $line"
    done
}

@test "magnetio metrics credentials are documented in .env.example" {
    local f="$REPO_ROOT/.env.example"
    [[ -f "$f" ]] || skip ".env.example not found"

    for var in METRICS_USER METRICS_PASSWORD; do
        grep -qE "^[# ]*${var}=" "$f" || fail "$var is not documented in .env.example"
    done
}
