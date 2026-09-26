# The Decypharr patch: what it is, why it exists, how to retire it

This stack runs a locally built Decypharr image rather than the upstream one.
This is the reference for that build — why it exists, how the pipeline works,
what to do when upstream cuts a new release, and how to confirm it's actually
live. For the symptom this patch fixes and how to recover a queue already
wedged by it, see the "TorBox: All Download Links Return 403 (error code 1010)" section of
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) — that section is scoped to the
incident; this one is scoped to the build.

## Why it exists

Decypharr v2.5's `ErrorCodeToLinkError` (`pkg/manager/link/errors.go`) maps
any unrecognised provider error code to a **permanent** failure. TorBox
answers a link-validation request with a bare HTTP `400` when a presigned
link has expired or rotated — not a malformed request, just a link that needs
re-fetching. That reading is this stack's observation, not TorBox's: the API
documents `400` only as "the user did something wrong, or an input wasn't
correct" and says nothing about expired links (`docs/TORBOX-API.md`).
Because `400` isn't one of the codes `ErrorCodeToLinkError`
recognises, it fell to the default branch and got classified permanent, with
two consequences measured directly against the v2.5 source:

- `resolveLinkWithRetry` returns at the first attempt instead of using its
  four tries and exponential backoff — no `link fetch failed, retrying` line
  ever appears in the log.
- `fetchAndValidate` memoises the failure against the link URL, and that URL
  is derived from `torrent_id`/`file_id`, so every subsequent request rebuilds
  the identical URL and hits the identical cached failure.

Measured on this NAS: 70 of these errors in 72 hours. The arr keeps the queue
item at 0% forever, and — because an item stuck at the cutoff makes the arr
refuse every alternative release for that title — the title can't even be
replaced by a different release. Upstream has an open, unmerged fix for this:
[sirrobot01/decypharr#402](https://github.com/sirrobot01/decypharr/pull/402).
This build backports it.

## How the pipeline works

Everything lives under `decypharr/`:

| File | Role |
|---|---|
| `Dockerfile` | Multi-stage build: fetches upstream source pinned to a specific commit, applies the patch, builds with upstream's own recipe verbatim, assembles the runtime image |
| `apply-patch.py` | Applies the fix by exact string replacement, not `patch`/`git apply` |
| `400-is-retryable.patch` | The human-readable form of the same diff, for reviewing without reading Python |
| `verify-patch.sh` | Fails the build if the patch's own Go tests don't exist or don't pass |
| `patch_test.go` | The Go tests (`TestProvider400IsRetryable`, `TestSiblingCodesAreUnchanged`) that prove the fix works and nothing else changed |

**The build fetches source by commit, not by tag.** `DECYPHARR_COMMIT` is the
exact commit `v2.5` pointed at when the patch was written, so the two string
anchors in `apply-patch.py` can't silently drift out from under a moving tag.

**The patch is applied by exact string match, not a diff/patch tool.**
`apply-patch.py` requires each anchor to appear in the source exactly once. A
context mismatch with a patch file can silently "succeed" with a fuzz offset;
this fails loudly instead — if upstream's `errors.go` has changed shape, the
build errors out and says which anchor didn't match, rather than shipping an
unpatched binary that looks fine. It also refuses to run against a tree that's
already patched (upstream shipping the fix, or the edit applying twice).

**The build fails if the patch didn't take.** `verify-patch.sh` runs as a
`RUN` step inside the `Dockerfile`'s builder stage, after `patch_test.go` is
copied into the source tree. It first asserts the test names actually exist
(`go test -list` — a renamed or missing test file would otherwise report "no
tests to run" and exit 0), then runs them for real. Against unpatched v2.5
source, `TestProvider400IsRetryable` fails, because the default branch really
does classify `400` as permanent — that's what proves the test is testing the
right thing.

**`verify-patch.sh` is a separate file, not an inline `RUN`,** because Docker
does not unescape `$$` in an inline `RUN` block; the first attempt at this as
an inline command was one stray `$`/quote away from a shell syntax error.

**CI publishes it; the NAS only pulls.** `.github/workflows/decypharr-image.yml`
builds for `linux/amd64` and `linux/arm64` and pushes to
`ghcr.io/<repo>/decypharr:v2.5-patch1` (plus a `sha-<commit>` tag) on every
push to `decypharr/**` or the workflow file itself. There's no Go toolchain on
the NAS, and a locally built image would exist on exactly one machine — CI is
what makes the patch reproducible and the compose file's image reference
resolvable anywhere. After publishing, the workflow does one more end-to-end
check: pull the tag it just pushed and `grep` the binary for the string the
patch introduces (`HTTP 400: link rejected`), because the build already
proving the patch's *tests* pass is a weaker guarantee than the *published
tag* actually containing it.

## Confirm it's live

```bash
docker inspect decypharr --format '{{.Config.Image}}'
# expect: .../decypharr:v2.5-patch1
```

The `400` itself still appears in Decypharr's logs when TorBox returns one —
that's a real upstream answer, not a bug — but with the patch it now costs a
retry instead of a permanently wedged item.

## When to retire this

Once upstream merges [#402](https://github.com/sirrobot01/decypharr/pull/402)
into a tagged release:

1. Delete `decypharr/` and `.github/workflows/decypharr-image.yml`.
2. Point the compose file's `decypharr` service back at the upstream image
   (`ghcr.io/sirrobot01/decypharr:<new tag>`).
3. Confirm with the same `docker inspect` check above, and watch
   `docker logs decypharr` for a `400` to see the retry actually happen rather
   than assuming the release notes cover it.

`apply-patch.py` itself will refuse to run against an already-patched tree
(it checks for `case "400":` and `ErrLinkRejected` already present), so
there's no risk of silently double-applying the fix if step 1 is missed.
