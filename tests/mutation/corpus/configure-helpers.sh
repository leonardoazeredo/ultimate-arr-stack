# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/lib/configure-helpers.sh.
#
# Safe to run: every test in tests/lib-configure-helpers.bats overrides curl
# with a shell function, so no mutation here can reach a network, a container
# or an *arr instance. The PATH harness in tests/helpers/stubs.bash is
# deliberately NOT used - it forbids `-X POST`, which is the exact argv this
# unit exists to build.

mutation http-code-as-exit-status \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: a connection that never completed is a failure, not a success" \
  --why "restores 'return \$code' for non-GET. curl writes 000 to %{http_code} when the connection never completed, and 'return 000' is exit status 0 - so a refused port, a DNS failure or a timeout was reported by configure-apps.sh as a tick against work it never did. The same line turns 404 into 148 and an empty code into a bash runtime error" \
  --apply 'perl -0pi -e "s/(\[verbose\] Response: \\\$body\\\" >&2\n    fi\n)    return 1\n/\$1    if [[ \\\"\\\$method\\\" == \\\"GET\\\" ]]; then return 1; else return \\\"\\\$code\\\"; fi\n/" "$F"'

mutation api-code-sentinel-dropped \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: a connection that never completed is recorded as 000" \
  --why "drops the :-000 default, so the two ways curl signals 'I never got a response' - an empty code and the literal 000 - stop reading the same way to a caller inspecting _API_LAST_CODE. An empty code then looks like a code that was simply not checked" \
  --apply 'sed -i "s@_API_LAST_CODE=\"\${code:-000}\"@_API_LAST_CODE=\"\$code\"@" "$F"'

mutation failing-get-leaks-the-error-body \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: a failing GET prints nothing" \
  --why "makes a failing GET print the body. Every GET call site is x=\$(api_get ...) feeding json_extract, so an HTML error page would be captured as if it were the resource - and json_extract swallows its own parse errors, so the caller sees an empty answer rather than a failure" \
  --apply 'perl -0pi -e "s/    if \[\[ \\\"\\\$method\\\" != \\\"GET\\\" \]\]; then\n        echo \\\"\\\$body\\\"\n    fi\n/    echo \\\"\\\$body\\\"\n/" "$F"'

mutation qbit-auth-trusts-the-status-code \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: qbit_auth rejects a 200 whose body is a refusal" \
  --why "drops the body half of the check. qBittorrent answers a WRONG PASSWORD with HTTP 200 and the body 'Fails.', so a status-only check reports a successful login and hands every later call a cookie that authenticates nothing" \
  --apply 'sed -i "s@if \[\[ \"\$http_code\" != \"200\" \]\] || \[\[ \"\$body\" != \"Ok.\" \]\]; then@if [[ \"\$http_code\" != \"200\" ]]; then@" "$F"'

mutation wait-accepts-any-http-code \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: wait_for_service rejects a 404 and gives up at the deadline" \
  --why "treats any answer as 'service is up'. Traefik answers 404 the whole time a backend is still starting, so configure_arr_service would proceed against a container that is mid-migration and write config into a database that is about to be rewritten" \
  --apply 'sed -i "s@if \[\[ \"\$code\" =~ \^\[23\] \]\] || \[\[ \"\$code\" == \"401\" \]\]; then@if [[ -n \"\$code\" ]]; then@" "$F"'

mutation wait-unbounded-per-attempt \
  --file scripts/lib/configure-helpers.sh \
  --bats tests/lib-configure-helpers.bats \
  --test "configure-helpers: wait_for_service bounds each attempt, not just the total" \
  --why "removes the per-request timeouts the file's own comment at :79 states as design intent. One hung connection then consumes the entire 180s budget in a single attempt, so the retry loop never retries and the failure message reports 'none' rather than the code the service was actually returning" \
  --apply 'sed -i "s@ --max-time 3 --connect-timeout 2@@" "$F"'
