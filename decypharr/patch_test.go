package link

import "testing"

// Guards the local patch in decypharr/apply-patch.py. It runs during the image
// build (see decypharr/Dockerfile), so an image cannot be published unless a
// provider 400 really does classify as retryable.
//
// Why this is worth a test of its own: the unpatched default branch classifies
// an unrecognised code as PERMANENT, and `resolveLinkWithRetry` returns
// immediately on a permanent error. The patch is therefore the difference
// between "tries 4 times with backoff" and "gives up on the first attempt", and
// a build that silently skipped it would look successful everywhere else.
func TestProvider400IsRetryable(t *testing.T) {
	err := ErrorCodeToLinkError("400")
	if !err.IsRetryable() {
		t.Errorf("a provider 400 is classified %s; resolveLinkWithRetry would bail at attempt 1", err.Category)
	}
	if !err.ShouldRefetch() {
		t.Errorf("a provider 400 is %s, not refetchable; the link would never be re-fetched", err.Category)
	}
}

// The patch must not loosen anything else. A 404 is a genuinely dead file and an
// account issue must still be able to disable the account.
func TestSiblingCodesAreUnchanged(t *testing.T) {
	if ErrorCodeToLinkError("404").IsRetryable() {
		t.Error("404 must stay permanent")
	}
	if ErrorCodeToLinkError("file_not_available").IsRetryable() {
		t.Error("file_not_available must stay permanent")
	}
	if !ErrorCodeToLinkError("429").IsRetryable() {
		t.Error("429 must stay retryable")
	}
	if !ErrorCodeToLinkError("503").IsRetryable() {
		t.Error("503 must stay retryable")
	}
	if !ErrorCodeToLinkError("bandwidth_exceeded").ShouldDisableAccount() {
		t.Error("bandwidth_exceeded must still disable the account")
	}
}
