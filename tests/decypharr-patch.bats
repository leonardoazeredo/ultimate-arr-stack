#!/usr/bin/env bats
# The locally patched Decypharr image.
#
# Decypharr v2.5 classifies an unrecognised provider error code as PERMANENT
# (pkg/manager/link/errors.go, ErrorCodeToLinkError default branch), so a bare
# HTTP 400 from TorBox makes resolveLinkWithRetry give up on its first attempt
# and memoises the failure. A title then sits at 0% until queue-cleanup removes
# it. decypharr/ carries the backport of the open upstream fix.
#
# These are static and host-independent. The patch's own Go test runs inside the
# image build (see decypharr/Dockerfile), so an unpatched binary cannot be
# published; the patcher is exercised here against a fixture carrying the two
# anchors it rewrites.

setup() {
    load helpers/setup
    PATCHER="$REPO_ROOT/decypharr/apply-patch.py"
    DOCKERFILE="$REPO_ROOT/decypharr/Dockerfile"
    WORKFLOW="$REPO_ROOT/.github/workflows/decypharr-image.yml"
    COMPOSE="$REPO_ROOT/docker-compose.arr-stack.yml"
}

teardown() {
    [[ -n "${FIXTURE:-}" && -f "$FIXTURE" ]] && rm -f "$FIXTURE"
    return 0
}

# The two anchors the patcher rewrites, in the shape it expects. Only these
# regions matter: the patcher does exact string replacement, not a parse.
write_pristine_fixture() {
    FIXTURE="$BATS_TEST_TMPDIR/errors.go"
    cat > "$FIXTURE" <<'GO'
package link

var (
	Err503 = errors.New("HTTP 503 Service Unavailable")
)

func ErrorCodeToLinkError(code string) *Error {
	switch code {
	case "429":
		return NewRetryableError(Err429, code)
	case "503", "read_pxy_timeout":
		return NewRetryableError(Err503, code)
	default:
		return NewPermanentError(fmt.Errorf("unknown error code: %s", code), code)
	}
}
GO
}

@test "decypharr: the patcher adds the 400 case to a pristine source file" {
    command -v python3 >/dev/null || skip "requires python3"
    write_pristine_fixture
    run python3 "$PATCHER" "$FIXTURE"
    assert_success
    run grep -c 'case "400":' "$FIXTURE"
    assert_output "1"
    # The comment, the sentinel declaration, and its use in the new case.
    run grep -c "ErrLinkRejected" "$FIXTURE"
    assert_output "3"
}

@test "decypharr: the patched file still sends other codes down the old path" {
    # The patch adds one case; it must not disturb the default branch that
    # everything else still relies on.
    command -v python3 >/dev/null || skip "requires python3"
    write_pristine_fixture
    run python3 "$PATCHER" "$FIXTURE"
    assert_success
    run grep -c "unknown error code" "$FIXTURE"
    assert_output "1"
    run grep -c "NewPermanentError" "$FIXTURE"
    assert_output "1"
}

@test "decypharr: the patcher refuses an already-patched file" {
    # Guards the double-apply case, including upstream eventually shipping the
    # fix: a second run must fail loudly rather than produce two case clauses.
    command -v python3 >/dev/null || skip "requires python3"
    write_pristine_fixture
    run python3 "$PATCHER" "$FIXTURE"
    assert_success
    run python3 "$PATCHER" "$FIXTURE"
    assert_failure
    [[ "$output" == *"already contains"* ]] || fail "unexpected message: $output"
}

@test "decypharr: the patcher refuses when an anchor has drifted" {
    # The failure that matters. A context-based patch tool can report success
    # with a fuzz offset and leave the binary unpatched; this must not.
    command -v python3 >/dev/null || skip "requires python3"
    write_pristine_fixture
    sed -i.bak 's/case "429":/case "ratelimit":/' "$FIXTURE"
    run python3 "$PATCHER" "$FIXTURE"
    assert_failure
    [[ "$output" == *"expected 1"* ]] || fail "unexpected message: $output"
    # And it must not have written a half-patched file.
    run grep -c "ErrLinkRejected" "$FIXTURE"
    assert_output "0"
}

@test "decypharr: the patcher fails on a missing file instead of crashing" {
    command -v python3 >/dev/null || skip "requires python3"
    run python3 "$PATCHER" "$BATS_TEST_TMPDIR/nope.go"
    assert_failure
    [[ "$output" == *"cannot read"* ]] || fail "unexpected message: $output"
}

@test "decypharr: the patcher exits non-zero without arguments" {
    command -v python3 >/dev/null || skip "requires python3"
    run python3 "$PATCHER"
    assert_failure
}

@test "decypharr: the Dockerfile pins the upstream commit, not just the tag" {
    # A tag can be moved; the patch anchors cannot survive that silently.
    run grep -E '^ARG DECYPHARR_COMMIT=[0-9a-f]{40}$' "$DOCKERFILE"
    assert_success
    run grep -E '^ARG DECYPHARR_VERSION=v[0-9]' "$DOCKERFILE"
    assert_success
}

@test "decypharr: the build fails if the patch did not take" {
    # The image-build assertion is the only thing standing between "publish
    # succeeded" and "published an unpatched binary that looks healthy".
    run grep -q 'verify-patch.sh' "$DOCKERFILE"
    assert_success
    run grep -q 'sh /tmp/verify-patch.sh' "$DOCKERFILE"
    assert_success
    run test -x "$REPO_ROOT/decypharr/verify-patch.sh"
    assert_success
    run test -f "$REPO_ROOT/decypharr/patch_test.go"
    assert_success
}

@test "decypharr: the gate refuses to build when the patch's tests are absent" {
    # "go test -run <pattern>" exits 0 reporting "no tests to run" when nothing
    # matches, so a gate that only ran that would go quiet -- and still pass --
    # the moment the test file stopped being copied in. Assert the guard exists.
    run grep -q -- '-list' "$REPO_ROOT/decypharr/verify-patch.sh"
    assert_success
    run grep -q "refusing to build" "$REPO_ROOT/decypharr/verify-patch.sh"
    assert_success
}

@test "decypharr: the gate would fail against unpatched source" {
    # The assertion that gives the gate its meaning: it names the 400 test and
    # requires it to be retryable, which unpatched v2.5 is not.
    run grep -q "TestProvider400IsRetryable" "$REPO_ROOT/decypharr/verify-patch.sh"
    assert_success
    run grep -q "IsRetryable\|ShouldRefetch" "$REPO_ROOT/decypharr/patch_test.go"
    assert_success
}

@test "decypharr: the workflow publishes the exact tag compose consumes" {
    # A mismatch here is invisible until a deploy pulls a tag that does not
    # exist, or silently keeps running the old image. The workflow builds the
    # repo name from github.repository, so compare the tag, not the full path.
    local ref tag
    ref=$(grep -oE 'ghcr\.io/[A-Za-z0-9._/-]+/decypharr:[A-Za-z0-9._-]+' "$COMPOSE" | head -1)
    [[ -n "$ref" ]] || fail "compose does not reference the patched decypharr image"
    tag="${ref##*:}"
    run grep -q "decypharr:${tag}" "$WORKFLOW"
    assert_success
}

@test "decypharr: the workflow verifies the pushed image carries the patch" {
    # Publishing an image built from an unpatched tree is the one failure that
    # looks like success from every other angle.
    run grep -q 'HTTP 400: link rejected' "$WORKFLOW"
    assert_success
}

@test "decypharr: the compose image differs from the unpatched upstream tag" {
    # If someone reverts the image line to upstream, the wedge comes back and
    # nothing else in the repo would say so.
    run grep -q 'image: ghcr.io/sirrobot01/decypharr:v2.5' "$COMPOSE"
    assert_failure
}
