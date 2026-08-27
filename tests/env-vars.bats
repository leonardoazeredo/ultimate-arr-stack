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
