# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/lib/check-yaml-syntax.sh.
#
# Safe to run: tests/lib-yaml-syntax.bats overrides git for both the repo root
# and the staged list, so every mutation reads only $BATS_TEST_TMPDIR. The
# no-PyYAML arm is reached by overriding python3, not by uninstalling anything.

mutation yaml-count-as-exit-status \
  --file scripts/lib/check-yaml-syntax.sh \
  --bats tests/lib-yaml-syntax.bats \
  --test "yaml-syntax: DEFECT - the count lives in the message, the status is a boolean" \
  --why "restores 'return \$errors'. An unbounded count in a one-byte status is 0 at exactly 256, and scripts/pre-commit:91 reads it as a boolean, so the count only ever risked inverting the verdict" \
  --apply 'perl -0pi -e "s/    echo \\\"    ERROR: \\\$errors file\\(s\\) with invalid YAML\\\"\n    return 1\n/    return \\\$errors\n/" "$F"'

mutation yaml-staged-list-word-split \
  --file scripts/lib/check-yaml-syntax.sh \
  --bats tests/lib-yaml-syntax.bats \
  --test "yaml-syntax: DEFECT - a path containing a space is one file, not two" \
  --why "restores 'for file in \$staged_compose' in the PyYAML arm. A staged path containing a space becomes two paths that do not exist, and the '-f || continue' on the next line converts that into a silent pass - the file is never parsed and the check reports OK" \
  --apply 'perl -0pi -e "s/        while IFS= read -r file; do\n            \[\[ -n \\\"\\\$file\\\" \]\] \|\| continue\n            \[\[ -f \\\"\\\$repo_root\/\\\$file\\\" \]\] \|\| continue\n            if ! _yaml_parses/        for file in \\\$staged_compose; do\n            [[ -f \\\"\\\$repo_root\/\\\$file\\\" ]] || continue\n            if ! _yaml_parses/; s/                errors=\\\$\\(\\(errors \+ 1\\)\\)\n            fi\n        done <<< \\\"\\\$staged_compose\\\"\n    else/                errors=\\\$((errors + 1))\n            fi\n        done\n    else/" "$F"'

mutation yaml-path-in-python-string \
  --file scripts/lib/check-yaml-syntax.sh \
  --bats tests/lib-yaml-syntax.bats \
  --test "yaml-syntax: DEFECT - a path is data to python, never code" \
  --why "puts the path back inside the python -c string. Staged paths are whatever anyone could git add, so inside the -c string they are code. The side effect is what proves it: on an INVALID file the interpolation still produces the right verdict, by SyntaxError rather than by parsing, so a test asserting only the verdict cannot see this at all" \
  --apply $'perl -0pi -e "s/    python3 -c .import sys, yaml; yaml.safe_load\\\\(open\\\\(sys.argv\\\\[1\\\\]\\\\)\\\\). \\\\\\"\\\\\\$1\\\\\\"/    python3 -c \\\\\\"import yaml; yaml.safe_load(open(\'\\\\\\$1\'))\\\\\\"/" "$F"'

mutation yaml-fallback-tab-anywhere \
  --file scripts/lib/check-yaml-syntax.sh \
  --bats tests/lib-yaml-syntax.bats \
  --test "yaml-syntax: a tab that is not at line start is not flagged" \
  --why "drops the line-start anchor, so a tab anywhere in a file is called an indentation error. Only indentation matters to YAML; a tab inside a value is legal, so this rejects valid compose files on the machines that have no PyYAML - exactly the machines with no second opinion available" \
  --apply "sed -i \"s@grep -qP '\\^\\\\\\\\t'@grep -qP '\\\\\\\\t'@\" \"\$F\"" \

mutation yaml-fallback-never-runs \
  --file scripts/lib/check-yaml-syntax.sh \
  --bats tests/lib-yaml-syntax.bats \
  --test "yaml-syntax: without PyYAML a leading tab is an error" \
  --why "hardcodes has_pyyaml=true, so on a machine without PyYAML the parse silently fails for every file and the grep fallback - the only check those machines get - is never reached" \
  --apply 'sed -i "s@^    local has_pyyaml=false\$@    local has_pyyaml=true@" "$F"'
