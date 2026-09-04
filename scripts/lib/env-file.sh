#!/bin/bash
# Read a single value out of a .env file.
#
# Sourced by the operational scripts that need one or two settings and have no
# business sourcing the whole file (a `.env` here carries API keys, and
# `source`ing it would export every one of them into the process and its
# children).
#
# It exists because the two callers had grown two different wrong parsers:
#
#   fix-radarr-paths.sh:34  grep "^KEY=" .env | cut -d= -f2
#   fix-sonarr-folders.sh   grep "^KEY=" .env | cut -d= -f2 | tr -d '"' | tr -d "'"
#
# `cut -d= -f2` returns the field BETWEEN the first and second `=`, so a value
# containing an `=` -- which base64 API keys and passwords routinely do -- was
# silently truncated at that character. The radarr one then did not strip
# quotes at all, so a quoted key was used with its quotes still attached; the
# sonarr one stripped every quote anywhere in the value rather than a
# surrounding pair.

# env_value <file> <key>
#
# Prints the value on stdout and returns 0, or returns 1 if the file is absent
# or the key is not assigned in it. The last assignment wins, which is what
# sourcing the file would do and what docker compose does.
env_value() {
    local file="$1" key="$2" line value found=1

    [ -f "$file" ] || return 1

    # Read rather than grep: no regex means a key is never interpreted as a
    # pattern, and the loop gets last-assignment-wins for free. The `|| [ -n ]`
    # guard is for a final line with no trailing newline.
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "${key}="*)
                # Everything after the FIRST '=' -- the value may contain more.
                value=${line#*=}
                found=0
                ;;
        esac
    done < "$file"

    [ "$found" -eq 0 ] || return 1

    # A file authored on Windows leaves a carriage return on every value; it is
    # invisible in output and breaks any comparison the value takes part in.
    value=${value%$'\r'}

    # One surrounding pair of quotes, not every quote in the value.
    case "$value" in
        \"*\") value=${value#\"}; value=${value%\"} ;;
        \'*\') value=${value#\'}; value=${value%\'} ;;
    esac

    printf '%s\n' "$value"
}
