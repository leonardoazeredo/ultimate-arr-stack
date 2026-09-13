#!/usr/bin/env python3
"""Apply the local Decypharr fix to a checked-out upstream source tree.

This is the machine-readable half of `400-is-retryable.patch`, which carries the
rationale. A patch file alone would be applied with `patch`/`git apply`, and a
context mismatch there is easy to misread as success (or to "succeed" with a
fuzz offset). This does exact string replacement instead and fails loudly, so a
build can never quietly ship an unpatched binary:

  * each anchor must appear exactly once, so upstream drift is an error rather
    than a silent no-op;
  * the result must contain the new text and must no longer contain the anchor.

Usage: apply-patch.py <path to pkg/manager/link/errors.go>
"""

import sys

# (anchor, replacement, description) — each anchor appears exactly once in v2.5.
EDITS = [
    (
        '\tErr503 = errors.New("HTTP 503 Service Unavailable")\n)',
        '\tErr503 = errors.New("HTTP 503 Service Unavailable")\n'
        "\t// ErrLinkRejected is a 400 from the provider/CDN, which in practice means\n"
        "\t// the presigned link expired or rotated rather than a malformed request.\n"
        '\tErrLinkRejected = errors.New("HTTP 400: link rejected")\n)',
        "add the ErrLinkRejected sentinel",
    ),
    (
        '\tcase "429":\n'
        "\t\treturn NewRetryableError(Err429, code)\n"
        '\tcase "503", "read_pxy_timeout":',
        '\tcase "429":\n'
        "\t\treturn NewRetryableError(Err429, code)\n"
        "\t// TorBox returns a bare 400 for a presigned link that has expired or\n"
        "\t// rotated. ClassifyStreamStatus already treats 400 at the CDN layer as\n"
        "\t// refetchable; the provider-API path must agree, otherwise a stale link is\n"
        "\t// classified permanent and no retry is ever attempted.\n"
        '\tcase "400":\n'
        "\t\treturn NewRefetchableError(ErrLinkRejected, code)\n"
        '\tcase "503", "read_pxy_timeout":',
        "classify a provider 400 as refetchable",
    ),
]

# Guards against patching a tree that is already patched (upstream shipping the
# fix, or the edit applied twice in one build) and against silently doing
# nothing when an anchor fails to match.
ALREADY_PATCHED = (
    'case "400":',
    "ErrLinkRejected",
)


def main(argv):
    if len(argv) != 2:
        print(f"usage: {argv[0]} <errors.go>", file=sys.stderr)
        return 2

    path = argv[1]
    try:
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
    except OSError as err:
        print(f"error: cannot read {path}: {err}", file=sys.stderr)
        return 1

    for marker in ALREADY_PATCHED:
        if marker in source:
            print(
                f"error: {path} already contains {marker!r}. If upstream shipped this "
                "fix, delete decypharr/ and go back to the upstream image.",
                file=sys.stderr,
            )
            return 1

    for anchor, replacement, description in EDITS:
        count = source.count(anchor)
        if count != 1:
            print(
                f"error: cannot {description}: anchor found {count} times, expected 1. "
                "Upstream's errors.go has changed; re-derive the edit against the new "
                "source before bumping DECYPHARR_COMMIT.",
                file=sys.stderr,
            )
            return 1
        if replacement in source:
            print(f"error: {description} appears already applied", file=sys.stderr)
            return 1
        source = source.replace(anchor, replacement, 1)
        if anchor in source or replacement not in source:
            print(f"error: {description} did not take effect", file=sys.stderr)
            return 1

    try:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(source)
    except OSError as err:
        print(f"error: cannot write {path}: {err}", file=sys.stderr)
        return 1

    print(f"patched {path}: " + "; ".join(edit[2] for edit in EDITS))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
