#!/bin/bash
# YAML syntax validation for compose files
# Uses python (usually available) or docker compose config

check_yaml_syntax() {
    local errors=0
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root="."

    # Get staged compose files
    local staged_compose
    staged_compose=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E 'docker-compose.*\.yml$|\.ya?ml$')

    if [[ -z "$staged_compose" ]]; then
        echo "    SKIP: No YAML files staged"
        return 0
    fi

    # Check if PyYAML is available
    local has_pyyaml=false
    if python3 -c "import yaml" 2>/dev/null; then
        has_pyyaml=true
    fi

    # Try python with PyYAML first (most reliable)
    if $has_pyyaml; then
        for file in $staged_compose; do
            [[ -f "$repo_root/$file" ]] || continue
            if ! python3 -c "import yaml; yaml.safe_load(open('$repo_root/$file'))" 2>/dev/null; then
                echo "    ERROR: Invalid YAML syntax in $file"
                # Show the actual error
                python3 -c "import yaml; yaml.safe_load(open('$repo_root/$file'))" 2>&1 | head -3 | sed 's/^/      /'
                errors=$((errors + 1))
            fi
        done
    else
        # Fallback: basic check with grep for common YAML errors
        for file in $staged_compose; do
            [[ -f "$repo_root/$file" ]] || continue
            # Check for tabs (YAML uses spaces)
            if grep -qP '^\t' "$repo_root/$file" 2>/dev/null; then
                echo "    ERROR: Tab characters found in $file (YAML requires spaces)"
                errors=$((errors + 1))
            fi
        done
        echo "    NOTE: Install PyYAML for full validation: pip install pyyaml"
    fi

    return $errors
}
