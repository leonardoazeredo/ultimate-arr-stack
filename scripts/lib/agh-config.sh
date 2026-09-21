#!/bin/bash
# agh-config.sh — the Phase 3 edits to AdGuard Home's config.yaml, as pure text
# transforms.
#
# Text in, text out. No ssh, no files, no network. The CLI that applies them
# (scripts/adguard-configure.sh) reads the live config over ssh, pipes it
# through here, and pushes the result — which is what lets all of this reasoning
# be tested on a host with no router at all.
#
# WHY TEXT SURGERY AND NOT YAML
#
# The router has no python and no PyYAML, so parse-and-reserialise is not
# available there anyway; more to the point it would be wrong everywhere.
# config.yaml holds ~90 keys in an order AdGuard Home owns, and a reserialiser
# reorders keys, drops the ones it does not understand, and turns `""` into
# `null`. Each of those is a silent behaviour change on a file nobody diffs by
# hand. So these functions replace the lines of one block and emit every other
# line exactly as it arrived — indentation, quoting, ordering and all.
#
# THE THREE SHAPES A KEY CAN HAVE
#
#   dns:
#     upstream_dns:      a key at 2 spaces with a block list at 4
#       - 8.8.8.8
#   filters:             a top-level key with a block list at 2
#     - enabled: true
#   filtering:
#     rewrites: []       an inline empty flow list
#
# The first two are handled by locating the block's extent (every following line
# indented deeper than the key, stopping at the first line that is not). The
# inline `[]` is handled by rewriting the key line and inserting the items under
# it.
#
# An inline list that is NOT empty (`rewrites: [{domain: a.lan, ...}]`) is
# refused rather than guessed at. Editing a flow sequence in place needs a real
# YAML parser and a wrong guess here is a resolver's rewrite table.
#
# WHEN THE KEY IS ABSENT ENTIRELY, these functions refuse: nothing on stdout,
# a reason on stderr, exit 2. Inserting a key that is not there means choosing a
# position in a file whose order AdGuard owns, and a caller cannot tell an
# absent key from a misspelled one. Refusing is also what keeps a caller from
# piping a half-built config onward — a refusal that printed the config it had
# so far would be worse than no refusal at all. Every shape this repo ships has
# all three keys; if the live file stops having one, that is worth stopping for.

# --- plumbing ---------------------------------------------------------------

# The current config, split into lines, plus whether the input ended with a
# newline. Both are needed to be byte-exact: `$(cat)` strips trailing newlines,
# so a file read through a command substitution silently loses one.
_AGH_LINES=()
_AGH_FINAL_NEWLINE=1

_agh_config_error() {
    printf 'agh-config: %s\n' "$*" >&2
}

# _agh_config_read_all — stdin -> _AGH_LINES and _AGH_FINAL_NEWLINE.
#
# The trailing 'X' is what survives command substitution in place of the
# newline that would otherwise be stripped, so the last byte of the input can be
# told apart from the last byte of a stripped copy.
_agh_config_read_all() {
    local all
    if ! all=$(cat; printf 'X'); then
        _agh_config_error "could not read the config from stdin"
        return 2
    fi
    if [[ "$all" == *$'\n'X ]]; then
        _AGH_FINAL_NEWLINE=1
    else
        _AGH_FINAL_NEWLINE=0
    fi

    _AGH_LINES=()
    local text="${all%X}" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        _AGH_LINES+=("$line")
    done < <(printf '%s' "$text")
    return 0
}

# _agh_config_indent_of <line> — how many leading spaces it has.
_agh_config_indent_of() {
    local s="$1"
    s="${s%%[! ]*}"
    printf '%s' "${#s}"
}

# _agh_config_pad <n> — n spaces.
_agh_config_pad() {
    local pad="" i
    for (( i = 0; i < $1; i++ )); do pad="$pad "; done
    printf '%s' "$pad"
}

# _agh_config_find_block <key> <indent> — locate the key's line and its extent.
#
# Sets _AGH_START, _AGH_END (the key line and the last line belonging to it) and
# _AGH_STYLE (block | flow-empty). Returns 2, with a reason on stderr, when the
# key is missing or carries an inline list this transform will not touch.
_AGH_START=-1
_AGH_END=-1
_AGH_STYLE=""

_agh_config_find_block() {
    local key="$1" indent="$2"
    _AGH_START=-1; _AGH_END=-1; _AGH_STYLE=""

    local pad i
    pad=$(_agh_config_pad "$indent")

    local n=${#_AGH_LINES[@]}
    for (( i = 0; i < n; i++ )); do
        local line="${_AGH_LINES[$i]}"
        # `"$pad$key:"` and not a prefix match: `upstream_dns_file:` and
        # `whitelist_filters:` both sit directly after the key this edits, and a
        # prefix match would find them first.
        [[ "$line" == "$pad$key:"* ]] || continue

        local rest="${line#"$pad$key:"}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        rest="${rest%"${rest##*[![:space:]]}"}"

        _AGH_START=$i
        if [[ -z "$rest" ]]; then
            _AGH_STYLE="block"
            _AGH_END=$i
            local j=$(( i + 1 ))
            while (( j < n )); do
                local next="${_AGH_LINES[$j]}"
                # A blank line ends the block rather than being absorbed: the
                # live config has none inside a list, and swallowing one would
                # move it.
                [[ -n "$next" ]] || break
                local nind
                nind=$(_agh_config_indent_of "$next")
                (( nind > indent )) || break
                _AGH_END=$j
                j=$(( j + 1 ))
            done
        elif [[ "$rest" == "[]" ]]; then
            _AGH_STYLE="flow-empty"
            _AGH_END=$i
        else
            _agh_config_error "${pad}${key}: carries an inline list ('$rest'). Only the block form and an empty '[]' can be edited in place; editing a flow list needs a YAML parser, and guessing at one would put a wrong rewrite table in a resolver"
            _AGH_START=-1
            return 2
        fi
        return 0
    done

    _agh_config_error "no '${pad}${key}:' key in the config. This transform edits that key in place rather than inserting it, because where a key belongs in a file whose order AdGuard Home owns is not something this can know"
    return 2
}

# _agh_config_emit — _AGH_LINES to stdout, byte-for-byte what came in (modulo
# the edited blocks).
_agh_config_emit() {
    local n=${#_AGH_LINES[@]} i
    (( n > 0 )) || return 0
    for (( i = 0; i < n; i++ )); do
        if (( i < n - 1 )) || (( _AGH_FINAL_NEWLINE == 1 )); then
            printf '%s\n' "${_AGH_LINES[$i]}"
        else
            printf '%s' "${_AGH_LINES[$i]}"
        fi
    done
}

# _agh_config_apply_replace <key> <indent> <item line>... — replace the located
# block with the key line and the given items.
_agh_config_apply_replace() {
    local key="$1" indent="$2"; shift 2
    local pad i
    pad=$(_agh_config_pad "$indent")

    local -a out=()
    for (( i = 0; i < _AGH_START; i++ )); do out+=("${_AGH_LINES[$i]}"); done
    out+=("$pad$key:")
    local l
    for l in "$@"; do out+=("$l"); done
    local n=${#_AGH_LINES[@]}
    for (( i = _AGH_END + 1; i < n; i++ )); do out+=("${_AGH_LINES[$i]}"); done
    _AGH_LINES=("${out[@]}")
}

# _agh_config_insert_after <index> <line>... — splice lines in after a line.
_agh_config_insert_after() {
    local at="$1"; shift
    local -a out=()
    local i
    for (( i = 0; i <= at; i++ )); do out+=("${_AGH_LINES[$i]}"); done
    local l
    for l in "$@"; do out+=("$l"); done
    local n=${#_AGH_LINES[@]}
    for (( i = at + 1; i < n; i++ )); do out+=("${_AGH_LINES[$i]}"); done
    _AGH_LINES=("${out[@]}")
}

# --- the public surface -----------------------------------------------------

# agh_config_set_upstream_dns <dns>... — stdin -> stdout, with
# dns.upstream_dns replaced by the given entries, in the given order.
#
# `dns.bootstrap_dns` is deliberately not touched: it holds plain IPs because
# bootstrapping cannot itself be encrypted. It is what resolves the DoH
# hostnames in the first place.
agh_config_set_upstream_dns() {
    if [[ "$#" -eq 0 ]]; then
        _agh_config_error "no upstreams given. Emptying dns.upstream_dns leaves AdGuard Home with nothing to resolve through, which is a resolver that answers nothing"
        return 2
    fi

    _agh_config_read_all || return 2
    _agh_config_find_block upstream_dns 2 || return 2

    local -a items=()
    local d
    for d in "$@"; do
        if [[ -z "$d" || "$d" == *[[:space:]]* ]]; then
            _agh_config_error "upstream '$d' is empty or contains whitespace, so it cannot be written as one list item"
            return 2
        fi
        items+=("    - $d")
    done

    _agh_config_apply_replace upstream_dns 2 "${items[@]}"
    _agh_config_emit
}

# agh_config_set_rewrites <domain=answer>... — stdin -> stdout, with
# filtering.rewrites replaced by one A rewrite per pair.
#
# The whole list is replaced rather than merged: the caller derives it from the
# repo's record of the .lan names, and a merge would leave a name behind that
# the record no longer has.
agh_config_set_rewrites() {
    if [[ "$#" -eq 0 ]]; then
        _agh_config_error "no rewrites given. Replacing filtering.rewrites with an empty list would drop every .lan name this migration exists to serve"
        return 2
    fi

    _agh_config_read_all || return 2
    _agh_config_find_block rewrites 2 || return 2

    local -a items=()
    local pair domain answer
    for pair in "$@"; do
        if [[ "$pair" != *=* ]]; then
            _agh_config_error "rewrite '$pair' is not <domain=answer>"
            return 2
        fi
        domain="${pair%%=*}"
        answer="${pair#*=}"
        if [[ -z "$domain" || -z "$answer" || "$domain" == *[[:space:]]* ]]; then
            _agh_config_error "rewrite '$pair' does not have a non-empty domain and answer"
            return 2
        fi
        items+=("    - domain: $domain" "      answer: $answer" "      enabled: true")
    done

    _agh_config_apply_replace rewrites 2 "${items[@]}"
    _agh_config_emit
}

# agh_config_set_filters <url> <name> [<url> <name> ...] — stdin -> stdout, with
# any filter whose url is not already in `filters` appended to it, enabled.
#
# Appended rather than regenerated, so the entries AdGuard Home itself wrote
# keep their exact bytes — including the disabled ones this does not enable and
# the fields it does not know about. An entry whose url is already present is
# left alone even if the name differs: this is not the place to overwrite
# somebody else's filter name.
agh_config_set_filters() {
    if [[ "$#" -eq 0 ]]; then
        _agh_config_error "no filter urls given"
        return 2
    fi
    if (( $# % 2 != 0 )); then
        _agh_config_error "filters are given as <url> <name> pairs; got an odd number of arguments"
        return 2
    fi

    _agh_config_read_all || return 2
    _agh_config_find_block filters 0 || return 2

    # The existing entries, and the highest id among them. Ids are AdGuard's:
    # it keys each filter's downloaded file by id, so a collision is not
    # cosmetic.
    local -a block=()
    local i
    for (( i = _AGH_START + 1; i <= _AGH_END; i++ )); do
        block+=("${_AGH_LINES[$i]}")
    done

    local maxid=0 id
    for i in ${block[@]+"${block[@]}"}; do
        if [[ "$i" =~ ^[[:space:]]*id:[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
            id="${BASH_REMATCH[1]}"
            (( id > maxid )) && maxid=$id
        fi
    done

    local -a add=()
    local url name
    while [[ "$#" -gt 0 ]]; do
        url="$1"; name="$2"; shift 2
        if [[ -z "$url" ]]; then
            _agh_config_error "a filter url is empty"
            return 2
        fi

        local seen=0 line
        for line in ${block[@]+"${block[@]}"}; do
            line="${line#"${line%%[![:space:]]*}"}"
            if [[ "$line" == "url: $url" ]]; then
                seen=1
                break
            fi
        done
        [[ "$seen" -eq 0 ]] || continue

        maxid=$(( maxid + 1 ))
        add+=("  - enabled: true" "    url: $url" "    name: $name" "    id: $maxid")
    done

    if (( ${#add[@]} == 0 )); then
        _agh_config_emit
        return 0
    fi

    _agh_config_insert_after "$_AGH_END" "${add[@]}"
    _agh_config_emit
}

# agh_config_block_lines <key> <indent> — stdin -> stdout, the item lines of a
# block, verbatim. This is how a caller reads back what is actually in the live
# config rather than grepping for the value it hoped for.
#
# Returns 2 when the key is absent, which is how "no such key" is told apart
# from "present and empty".
agh_config_block_lines() {
    _agh_config_read_all || return 2
    _agh_config_find_block "$1" "$2" || return 2
    local i
    for (( i = _AGH_START + 1; i <= _AGH_END; i++ )); do
        printf '%s\n' "${_AGH_LINES[$i]}"
    done
    return 0
}

# agh_dnsmasq_hostnames — stdin: a dnsmasq `address=` record (this repo's
# pihole/dnsmasq.d/02-local-dns.conf.example) -> one hostname per line.
#
# The names are parsed rather than listed, because a hardcoded list of 18 is a
# list that goes stale the day a service is added — and it would go stale
# silently, as a .lan name that resolves on the NAS and not on the router.
#
# `address=/lan/::` is skipped: a zone with no dot in it is the apex, not a
# host, and a rewrite for the apex would answer for every .lan name at once.
# The answer field (`TRAEFIK_LAN_IP` in the example file) is not read here; the
# caller supplies the address, because the placeholder is not one.
agh_dnsmasq_hostnames() {
    local line name
    local -a seen=()
    local count=0 dup i

    while IFS= read -r line; do
        case "$line" in
            \#*|'') continue ;;
        esac
        [[ "$line" == *"address=/"* ]] || continue

        name="${line#*address=/}"
        name="${name%%/*}"
        name="${name#"${name%%[![:space:]]*}"}"
        name="${name%"${name##*[![:space:]]}"}"
        [[ -n "$name" ]] || continue
        # The apex zone, not a host.
        [[ "$name" == *.* ]] || continue

        dup=0
        for i in ${seen[@]+"${seen[@]}"}; do
            [[ "$i" == "$name" ]] && { dup=1; break; }
        done
        [[ "$dup" -eq 0 ]] || continue

        seen+=("$name")
        count=$(( count + 1 ))
        printf '%s\n' "$name"
    done

    if (( count == 0 )); then
        _agh_config_error "no hostnames in the address record. Applying this would leave filtering.rewrites empty, so it is refused instead"
        return 2
    fi
    return 0
}
