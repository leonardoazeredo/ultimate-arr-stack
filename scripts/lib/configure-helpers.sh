#!/bin/bash
#
# Shared helper functions for configure-apps.sh
#
# Sourced by the main script — not meant to be run directly.
# Requires python3 for JSON parsing.

# ============================================
# JSON parsing
# ============================================

# General-purpose JSON extraction via python3
#
# Usage:
#   json_extract "$json" "print(data.get('id',''))"            — extract a value
#   json_extract "$json" "sys.exit(0 if condition else 1)"     — boolean check
#   json_extract "$json" "print(json.dumps(modified))"         — transform JSON
json_extract() {
    local json="$1" expr="$2"
    echo "$json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
$expr
" 2>/dev/null
}

# ============================================
# Output helpers
# ============================================

log()   { echo "[configure] $1"; }
ok()    { echo "  ✓ $1"; CONFIGURED=$((CONFIGURED + 1)); }
skip()  { echo "  - $1 (already configured)"; SKIPPED=$((SKIPPED + 1)); }
fail()  { echo "  ✗ $1"; FAILED=$((FAILED + 1)); }
info()  { echo "  $1"; }
dry()   { echo "  [dry-run] Would: $1"; }

# ============================================
# HTTP helpers
# ============================================

# Set by _api_request to the HTTP code of the most recent call, or "000" when
# curl never got a response. This is the ONLY place the code survives -- it is
# deliberately kept out of the exit status. See the comment in _api_request.
_API_LAST_CODE=""

# Usage: body=$(api_get "url" "header1" "header2" ...)
#        body=$(api_post "url" "application/json" '{"k":"v"}' "header1" ...)
_api_request() {
    local method="$1" url="$2"; shift 2
    local args=(-s -w '\n%{http_code}' -o -)
    if [[ "$method" != "GET" ]]; then
        local content_type="$1" data="$2"; shift 2
        args+=(-X "$method" -H "Content-Type: $content_type")
        if [[ -n "$data" ]]; then args+=(--data "$data"); fi
    fi
    for h in "$@"; do args+=(-H "$h"); done
    local response
    response=$(curl "${args[@]}" "$url")
    local code
    code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    # The HTTP code goes in a global, never in the exit status. Every caller in
    # configure-apps.sh is `if api_post ...; then ok "added X"; else fail; fi`,
    # so the status is read as a boolean and nothing else -- and an HTTP code
    # makes a terrible boolean. 404 became status 148, 500 became 244, an empty
    # code became `return: : numeric argument required`, and curl's own "000"
    # for a connection that never completed became status 0, so a refused port
    # was reported to the user as a tick.
    _API_LAST_CODE="${code:-000}"

    if [[ "$code" =~ ^2 ]]; then
        echo "$body"
        return 0
    fi

    # A failing non-GET prints the body because it usually carries the reason
    # ("already exists", a validation message). A failing GET prints nothing,
    # so a caller doing `x=$(api_get ...)` never captures an error page as data.
    if [[ "$method" != "GET" ]]; then
        echo "$body"
    fi
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        echo "  [verbose] $method $url → HTTP ${_API_LAST_CODE}" >&2
        echo "  [verbose] Response: $body" >&2
    fi
    return 1
}

api_get()  { _api_request GET  "$@"; }
api_post() { _api_request POST "$@"; }
api_put()  { _api_request PUT  "$@"; }

# Wait for a service to respond (default 180s wall-clock timeout, override with WAIT_TIMEOUT)
# 180s covers first-boot *arr DB migrations on slower NAS hardware.
# Accepts 2xx, 3xx, and 401 (auth required = service is up)
# Per-curl --max-time prevents one hung connection from eating the entire budget.
wait_for_service() {
    local name="$1" url="$2"
    local timeout=${WAIT_TIMEOUT:-180}
    local start=$SECONDS
    local deadline=$((SECONDS + timeout))
    local last_heartbeat=$SECONDS
    local code=""
    while (( SECONDS < deadline )); do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 --connect-timeout 2 "$url" 2>/dev/null)
        if [[ "$code" =~ ^[23] ]] || [[ "$code" == "401" ]]; then
            return 0
        fi
        if (( SECONDS - last_heartbeat >= 10 )); then
            info "Still waiting for $name ($((SECONDS - start))s/${timeout}s, last HTTP: ${code:-none})..."
            last_heartbeat=$SECONDS
        fi
        sleep 1
    done
    fail "$name not responding after ${timeout}s at $url (last HTTP code: ${code:-none})"
    return 1
}

# ============================================
# Shared Sonarr/Radarr configuration
# ============================================

# Configure an *arr service (Sonarr or Radarr)
#
# Arguments:
#   $1 = name              — "Sonarr" or "Radarr"
#   $2 = port              — 8989 or 7878
#   $3 = api_key           — API key for the service
#   $4 = root_path         — /data/media/tv or /data/media/movies
#   $5 = category          — accepted and unused; see the note in the body
#   $6 = naming_check      — field to check: "renameEpisodes" or "renameMovies"
#   $7 = metadata_fields   — JSON array of metadata field objects
#   $8 = naming_payload    — full JSON payload for naming config
#
# Requires globals: NAS_IP, DRY_RUN, SABNZBD_RUNNING
# The `$flag` booleans below are compared as STRINGS, never run as commands.
# `if $DRY_RUN; then` executes the variable's value - unquoted, so it word-splits
# too - which is a command-execution path bought in exchange for nothing over a
# string comparison. Same shape as the two cache flags fixed in common.sh.
configure_arr_service() {
    local name="$1"
    local port="$2"
    local api_key="$3"
    local root_path="$4"
    # Positional argument 5, kept so the call sites and the $6-$8 that follow it
    # do not have to shift. Nothing reads it any more: it existed to name the
    # SABnzbd category and its per-arr priority fields, and the blackhole client
    # has neither -- it has two folder paths.
    local _category="$5"
    local naming_check="$6"
    local metadata_fields="$7"
    local naming_payload="$8"

    log "Configuring ${name}..."

    if [[ -z "$api_key" ]]; then
        fail "${name}: no API key, skipping"
        return
    fi

    local BASE="http://${NAS_IP}:${port}"
    local AUTH="X-Api-Key: ${api_key}"

    if ! wait_for_service "$name" "${BASE}/api/v3/health"; then return; fi

    if [[ "$DRY_RUN" == true ]]; then
        dry "Add root folder ${root_path}"
        if [[ "$SABNZBD_RUNNING" == true ]]; then dry "Add usenet blackhole download client"; fi
        dry "Enable NFO metadata (Kodi/Emby)"
        dry "Set TRaSH naming scheme"
        dry "Add Reject ISO custom format"
        dry "Score Reject ISO at -10000 in quality profiles"
        if [[ "$SABNZBD_RUNNING" == true ]]; then dry "Add delay profile (Usenet 0, Torrent 30)"; fi
        return
    fi

    # --- Root folder ---
    local roots
    roots=$(api_get "${BASE}/api/v3/rootfolder" "$AUTH") || true
    if json_extract "$roots" "sys.exit(0 if any(r.get('path') == '${root_path}' for r in data) else 1)"; then
        skip "${name}: root folder ${root_path}"
    else
        if api_post "${BASE}/api/v3/rootfolder" "application/json" "{\"path\":\"${root_path}\"}" "$AUTH" >/dev/null 2>&1; then
            ok "${name}: added root folder ${root_path}"
        else
            fail "${name}: add root folder ${root_path}"
        fi
    fi

    # --- Download client: the usenet blackhole (if usenet is wanted) ---
    # This used to add a `Sabnzbd` client pointed at 172.20.0.3:8080. It is not a
    # working usenet path here: SABnzbd reads `nntp.torbox.app`, which serves
    # articles only up to about 90 days old, so a backlog grab is a guaranteed
    # failure (measured 2026-09-14 -- see docs/TROUBLESHOOTING.md). The arr's own
    # UsenetBlackhole client plus usenet-blackhole.timer moves releases through
    # TorBox's API instead, which has no age limit.
    #
    # Re-running this script is the specific way the old client could come back:
    # it only skips a client it already finds.
    #
    # The gate is still SABnzbd: it is this stack's marker for "this deployment
    # wants usenet", and the blackhole itself needs no service and no credential.
    #
    # The client list is fetched here, inside the branch that reads it. It
    # used to be fetched once above by the qBittorrent block that owned the first
    # reader -- and when that block was deleted on 2026-09-12 this one kept
    # referencing a variable nothing assigned any more. Under `set -u` the
    # expansion failed, the branch took its else arm, and the "already
    # configured" skip below became unreachable: every run re-POSTed the client.
    if [[ "$SABNZBD_RUNNING" == true ]]; then
        local clients
        clients=$(api_get "${BASE}/api/v3/downloadclient" "$AUTH") || true
        if json_extract "$clients" "sys.exit(0 if any(c.get('implementation','') == 'UsenetBlackhole' for c in data) else 1)"; then
            skip "${name}: usenet blackhole download client"
        else
            local blackhole_payload
            # `/data/...` and not the host path: the handshake is a filesystem
            # one, and the arr does it from inside its container, where
            # ${MEDIA_ROOT} is mounted at /data.
            blackhole_payload=$(cat <<BLACKHOLE_JSON
{
    "enable": true,
    "protocol": "usenet",
    "priority": 1,
    "name": "Usenet Blackhole",
    "implementation": "UsenetBlackhole",
    "configContract": "UsenetBlackholeSettings",
    "fields": [
        {"name": "nzbFolder", "value": "/data/usenet/blackhole/nzb"},
        {"name": "watchFolder", "value": "/data/usenet/blackhole/complete"}
    ]
}
BLACKHOLE_JSON
)
            if api_post "${BASE}/api/v3/downloadclient" "application/json" "$blackhole_payload" "$AUTH" >/dev/null 2>&1; then
                ok "${name}: added usenet blackhole download client"
            else
                fail "${name}: add usenet blackhole download client"
            fi
        fi
    fi

    # --- NFO Metadata ---
    local metadata
    metadata=$(api_get "${BASE}/api/v3/metadata" "$AUTH") || true
    local meta_id
    meta_id=$(json_extract "$metadata" "
xbmc = [m for m in data if m.get('implementation') == 'XbmcMetadata']
print(xbmc[0]['id'] if xbmc else '')")
    if [[ -n "$meta_id" ]]; then
        local meta_enabled
        meta_enabled=$(json_extract "$metadata" "
xbmc = [m for m in data if m.get('implementation') == 'XbmcMetadata']
print(str(xbmc[0].get('enable', False)).lower() if xbmc else 'false')")
        if [[ "$meta_enabled" == "true" ]]; then
            skip "${name}: NFO metadata"
        else
            local meta_payload="{\"enable\":true,\"name\":\"Kodi (XBMC) / Emby\",\"id\":${meta_id},\"fields\":${metadata_fields},\"implementation\":\"XbmcMetadata\",\"configContract\":\"XbmcMetadataSettings\"}"
            if api_put "${BASE}/api/v3/metadata/${meta_id}" "application/json" "$meta_payload" "$AUTH" >/dev/null 2>&1; then
                ok "${name}: enabled NFO metadata"
            else
                fail "${name}: enable NFO metadata"
            fi
        fi
    fi

    # --- Naming ---
    local naming
    naming=$(api_get "${BASE}/api/v3/config/naming" "$AUTH") || true
    local rename_enabled
    rename_enabled=$(json_extract "$naming" "print(str(data.get('${naming_check}', False)).lower())")
    if [[ "$rename_enabled" == "true" ]]; then
        skip "${name}: TRaSH naming (already customised)"
    else
        if api_put "${BASE}/api/v3/config/naming" "application/json" "$naming_payload" "$AUTH" >/dev/null 2>&1; then
            ok "${name}: set TRaSH naming scheme"
        else
            fail "${name}: set TRaSH naming scheme"
        fi
    fi

    # --- Custom Format: Reject ISO ---
    local formats
    formats=$(api_get "${BASE}/api/v3/customformat" "$AUTH") || true
    local iso_cf_id=""
    if json_extract "$formats" "sys.exit(0 if any(c.get('name') == 'Reject ISO' for c in data) else 1)"; then
        skip "${name}: Reject ISO custom format"
        iso_cf_id=$(json_extract "$formats" "
cfs = [c['id'] for c in data if c.get('name') == 'Reject ISO']
print(cfs[0] if cfs else '')")
    else
        local cf_payload='{"name":"Reject ISO","includeCustomFormatWhenRenaming":false,"specifications":[{"name":"ISO","implementation":"ReleaseTitleSpecification","negate":false,"required":true,"fields":[{"name":"value","value":"\\.iso$"}]}]}'
        local cf_result
        cf_result=$(api_post "${BASE}/api/v3/customformat" "application/json" "$cf_payload" "$AUTH") || true
        iso_cf_id=$(json_extract "$cf_result" "print(data.get('id', ''))")
        if [[ -n "$iso_cf_id" ]]; then
            ok "${name}: added Reject ISO custom format"
        else
            fail "${name}: add Reject ISO custom format"
        fi
    fi

    # --- Score Reject ISO in quality profiles ---
    if [[ -n "$iso_cf_id" ]]; then
        local profiles
        profiles=$(api_get "${BASE}/api/v3/qualityprofile" "$AUTH") || true
        local profile_ids
        profile_ids=$(json_extract "$profiles" "
for p in data:
    print(p['id'])")
        for pid in $profile_ids; do
            local profile
            profile=$(api_get "${BASE}/api/v3/qualityprofile/${pid}" "$AUTH") || continue
            # Skip if already scored correctly
            if json_extract "$profile" "
items = data.get('formatItems', [])
match = [i for i in items if i.get('format') == ${iso_cf_id}]
sys.exit(0 if match and match[0].get('score') == -10000 else 1)"; then
                continue
            fi
            # Add or update the custom format score
            local updated_profile
            updated_profile=$(json_extract "$profile" "
items = data.get('formatItems', [])
items = [i for i in items if i.get('format') != ${iso_cf_id}]
items.insert(0, {'format': ${iso_cf_id}, 'name': 'Reject ISO', 'score': -10000})
data['formatItems'] = items
print(json.dumps(data))")
            if api_put "${BASE}/api/v3/qualityprofile/${pid}" "application/json" "$updated_profile" "$AUTH" >/dev/null 2>&1; then
                ok "${name}: scored Reject ISO at -10000 in profile ${pid}"
            else
                fail "${name}: score Reject ISO in profile ${pid}"
            fi
        done
    fi

    # --- Delay profile (if SABnzbd running — prefer Usenet) ---
    if [[ "$SABNZBD_RUNNING" == true ]]; then
        local delays
        delays=$(api_get "${BASE}/api/v3/delayprofile" "$AUTH") || true
        if json_extract "$delays" "sys.exit(0 if any(d.get('preferredProtocol') == 'usenet' for d in data) else 1)"; then
            skip "${name}: delay profile"
        else
            local delay_payload='{"enableUsenet":true,"enableTorrent":true,"preferredProtocol":"usenet","usenetDelay":0,"torrentDelay":30,"bypassIfHighestQuality":true,"order":2147483647,"tags":[]}'
            if api_post "${BASE}/api/v3/delayprofile" "application/json" "$delay_payload" "$AUTH" >/dev/null 2>&1; then
                ok "${name}: added delay profile (Usenet 0, Torrent 30 min)"
            else
                fail "${name}: add delay profile"
            fi
        fi
    fi
}
