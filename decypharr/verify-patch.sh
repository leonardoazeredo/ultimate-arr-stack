#!/bin/sh
# Refuse to build the patched Decypharr image unless the patch is really in the
# tree and really changes how a provider 400 is classified.
#
# Runs as a build step in decypharr/Dockerfile, from the builder stage's /app.
# Exists as a file rather than an inline RUN because Docker does not unescape
# dollar-dollar here, so the inline form needs single dollars and one stray
# comment or quote turns the whole thing into a shell syntax error (which is how
# the first published attempt failed).
set -eu

TESTS='TestProvider400IsRetryable|TestSiblingCodesAreUnchanged'

# Not decoration: `go test -run <pattern>` exits 0 reporting "no tests to run"
# when nothing matches, so this gate would go quiet and still pass if the test
# file never landed in the tree or were renamed. Ask for the names first.
listed=$(go test ./pkg/manager/link/ -list "$TESTS" 2>&1) || {
    echo "go test -list failed:" >&2
    echo "$listed" >&2
    exit 1
}
case "$listed" in
    *TestProvider400IsRetryable*) ;;
    *)
        echo "the patch's tests are not in this tree; refusing to build" >&2
        echo "$listed" >&2
        exit 1
        ;;
esac

# Against unpatched v2.5 this fails: the default branch classifies an
# unrecognised code as PERMANENT, so a 400 is not retryable and would never be
# re-fetched.
go test ./pkg/manager/link/ -run "$TESTS" -v
