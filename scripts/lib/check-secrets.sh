#!/bin/bash
# Secret detection for pre-commit hook
# Scans ALL tracked files in repo (not just staged) for security

# Source common functions
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Report every match of $pattern that is not itself a placeholder.
#
# The allowlist used to be applied to `grep -o`'s entire output at once:
# `match=$(echo "$content" | grep -oE ...)` collected every hit in the file
# into one string, and `echo "$match" | grep -qi <allowlist>` then exempted
# the whole set if any ONE of them looked like a placeholder. So a single
# `PASSWORD=your-password-here` line disarmed that pattern for every real
# credential in the same file.
#
# Measured, not theorised: a file holding that line plus
# `SSH_PASSWORD=hunter2-Tr0ub4dor-real` made check_secrets return 0 and print
# nothing at all. Filtering hit-by-hit is the entire fix -- one match's
# placeholder can no longer vouch for another's. Simulated across every
# tracked file before the change: two files rely on the allowlist today
# (.env.e2e.example and tests/configure-apps.bats) and in both every hit is
# itself a placeholder, so nothing newly fires. This closes a hole rather
# than tightening a threshold.
#
# Args: 1 severity  2 file  3 message  4 content  5 pattern
#       6 extra allowlist alternatives, '' for none
#       7 extra exclusion regex applied to the surviving hits, '' for none
# Returns: 0 if it reported something, 1 if nothing survived filtering.
_report_secret_matches() {
    local severity="$1" file="$2" message="$3" content="$4" pattern="$5"
    local extra_allow="${6:-}" extra_exclude="${7:-}"

    local allow='your|here|example|placeholder'
    if [[ -n "$extra_allow" ]]; then
        allow="$allow|$extra_allow"
    fi

    local hits
    hits=$(echo "$content" | grep -oE "$pattern" 2>/dev/null) || true

    # Hit by hit, never over the joined set. See the note above the function.
    hits=$(echo "$hits" | grep -viE "($allow)") || true
    if [[ -n "$extra_exclude" ]]; then
        hits=$(echo "$hits" | grep -vE "$extra_exclude") || true
    fi

    if [[ -z "$hits" ]]; then
        return 1
    fi
    echo "    $severity: $message in $file"
    return 0
}

check_secrets() {
    local errors=0

    # Get files to scan
    local files_to_check
    files_to_check=$(get_files_to_scan)

    if [[ -z "$files_to_check" ]]; then
        return 0
    fi

    for file in $files_to_check; do
        # Skip binary files, .env, and the check scripts themselves (contain example patterns)
        case "$file" in
            *.png|*.jpg|*.gif|*.ico|*.woff|*.woff2|*.ttf|*.eot) continue ;;
            .env) continue ;;  # .env should be gitignored anyway
            scripts/lib/check-*.sh) continue ;;  # These contain example patterns
            scripts/lib/common.sh) continue ;;
            tests/fixtures/*) continue ;;  # Test fixtures contain intentional fake secrets
            *.md) continue ;;  # Documentation may contain examples
        esac

        # Get file content
        local content
        content=$(read_file_content "$file") || continue

        # Pattern 1: WireGuard private key (44-char base64 ending in =)
        if _report_secret_matches ERROR "$file" "Possible WireGuard private key" \
               "$content" '(WIREGUARD_PRIVATE_KEY|PRIVATE_KEY)=[A-Za-z0-9+/]{40,}=' 'xxx' ''; then
            errors=$((errors + 1))
        fi

        # Pattern 2: Cloudflare API token (alphanumeric, 35-45 chars)
        #
        # Its allowlist used to carry 'token' as a sixth placeholder word, and
        # that made the pattern incapable of firing: the allowlist is tested
        # against the whole match, and every match begins with the literal key
        # name CF_DNS_API_TOKEN, so `grep -i token` excused all of them. A real
        # 35-45 character Cloudflare token has always passed this check.
        # Dropping the word costs nothing -- the placeholder it was meant to
        # excuse, CF_DNS_API_TOKEN=your_token_here, is already covered twice
        # over by 'your' and 'here'.
        if _report_secret_matches ERROR "$file" "Possible Cloudflare API token" \
               "$content" 'CF_DNS_API_TOKEN=[A-Za-z0-9_-]{35,45}$' 'xxx' ''; then
            errors=$((errors + 1))
        fi

        # Pattern 3: Cloudflare tunnel token (JWT format)
        # No allowlist by design: a well-formed JWT is not something anyone
        # writes as an example.
        if echo "$content" | grep -qE 'TUNNEL_TOKEN=eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' 2>/dev/null; then
            echo "    ERROR: Possible Cloudflare tunnel token in $file"
            errors=$((errors + 1))
        fi

        # Pattern 4: Real bcrypt hashes (60 chars after $2a$XX$ or $2y$XX$)
        # Its allowlist omits xxx, and keeps omitting it: xxx is a plausible
        # substring of a real 53-char base64 tail, so accepting it here would
        # exempt genuine hashes.
        if _report_secret_matches ERROR "$file" "Possible bcrypt password hash" \
               "$content" '\$2[aby]\$[0-9]{2}\$[A-Za-z0-9./]{50,}' '' ''; then
            errors=$((errors + 1))
        fi

        # Pattern 5: PEM private key blocks
        # No allowlist by design, same reasoning as pattern 3.
        if echo "$content" | grep -qE '^-----BEGIN (RSA |EC |OPENSSH |DSA |)PRIVATE KEY-----' 2>/dev/null; then
            echo "    ERROR: Private key block detected in $file"
            errors=$((errors + 1))
        fi

        # Pattern 6: Generic high-entropy secrets (long base64 in value position)
        if _report_secret_matches ERROR "$file" "Possible secret value" \
               "$content" '(PASSWORD|SECRET|API_KEY)=[A-Za-z0-9+/=]{30,}$' 'xxx' ''; then
            errors=$((errors + 1))
        fi

        # Pattern 7: OpenVPN credentials (non-placeholder values)
        if _report_secret_matches ERROR "$file" "Possible OpenVPN credential" \
               "$content" 'OPENVPN_(USER|PASSWORD)=.{30,}' 'xxx' ''; then
            errors=$((errors + 1))
        fi

        # Pattern 8: Bearer/Auth tokens in non-example files
        if _report_secret_matches ERROR "$file" "Possible auth token" \
               "$content" '(Authorization|Bearer|TOKEN):\s*(Bearer\s+)?[A-Za-z0-9._-]{20,}' 'xxx' ''; then
            errors=$((errors + 1))
        fi

        # Pattern 9: SSH/generic passwords (15+ chars, non-placeholder)
        # The exclusion regex skips shell variable references like
        # PASSWORD="${VAR:-}", PASSWORD=${VAR} (unquoted docker-compose env
        # list style), and PASSWORD=$(...).
        if _report_secret_matches ERROR "$file" "Possible password" \
               "$content" '(SSH_PASS|_PASSWORD|_PASSWD)=[^[:space:]]{15,}' 'xxx' '="?\$\{|=\$\('; then
            errors=$((errors + 1))
        fi
    done

    if [[ $errors -eq 0 ]]; then
        return 0
    fi

    # The count goes in the message, the status stays a boolean. `return
    # $errors` put an unbounded count into one byte, so exactly 256 findings
    # returned 0 and the hook reported the tree clean. The only caller,
    # scripts/pre-commit:68, is `if check_secrets; then` -- it read the value
    # as a boolean all along, so the count was never reaching anyone anyway.
    # Same defect and same fix as check_doc_links, 9cc4b2d.
    echo "    $errors secret finding(s)"
    return 1
}
