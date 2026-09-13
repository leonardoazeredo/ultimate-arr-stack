# Decypharr with one local patch on top of the pinned upstream release.
#
# Why this exists: Decypharr v2.5 maps an unrecognised provider error code to a
# PERMANENT error (pkg/manager/link/errors.go, ErrorCodeToLinkError default
# branch). TorBox can answer a link-validation request with a bare HTTP 400, so
# the 400 is classified permanent, `resolveLinkWithRetry` returns at the first
# attempt and never uses its 4 tries or its backoff, and `fetchAndValidate`
# memoises the failure against the link URL. A title then sits at 0% until
# queue-cleanup removes it.
#
# Upstream fixed this in PR #402, which is open and unmerged as of v2.5. This
# build is `ghcr.io/sirrobot01/decypharr:v2.5` source plus that patch. Drop this
# directory and go back to the upstream image once the fix ships in a release.
#
# The base image is upstream's own Dockerfile, taken from the pinned tag, and we
# run it by making a source tree in the context. That keeps the runtime image
# (fuse3, rclone, entrypoint, healthcheck) exactly what upstream produces, and
# keeps this file from rotting as upstream's build changes.
#
# Build:
#   docker build -f decypharr/Dockerfile .

ARG DECYPHARR_VERSION=v2.5
# The commit `v2.5` pointed at when this patch was written. Fetching by commit
# rather than by tag means the patch anchors below cannot drift under us.
ARG DECYPHARR_COMMIT=0dd1cbbd6e4680000097db0141f7106e02d21b8d

# --- Fetch the pinned source -------------------------------------------------
FROM alpine:3.22 AS patched

ARG DECYPHARR_VERSION
ARG DECYPHARR_COMMIT

# python3 is for the patcher below and exists only in this stage; the runtime
# image is unaffected.
RUN apk add --no-cache curl python3
WORKDIR /src
RUN curl -fsSL "https://github.com/sirrobot01/decypharr/archive/${DECYPHARR_COMMIT}.tar.gz" \
        -o /tmp/src.tar.gz \
    && tar xzf /tmp/src.tar.gz --strip-components=1 \
    && rm /tmp/src.tar.gz \
    && grep -q "func ErrorCodeToLinkError" pkg/manager/link/errors.go

COPY decypharr/apply-patch.py /tmp/apply-patch.py
RUN python3 /tmp/apply-patch.py /src/pkg/manager/link/errors.go

# --- Build with upstream's own recipe, verbatim ------------------------------
FROM --platform=$BUILDPLATFORM tonistiigi/xx AS xx

FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS builder

ARG TARGETOS
ARG TARGETARCH
ARG TARGETPLATFORM
ARG VERSION=0.0.0
ARG CHANNEL=dev

COPY --from=xx / /

WORKDIR /app

RUN apk add --no-cache clang lld && \
    xx-apk add --no-cache gcc g++ musl-dev libc-dev fuse-dev

COPY --from=patched /src/go.mod /src/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY --from=patched /src/ .
COPY decypharr/patch_test.go pkg/manager/link/zz_local_patch_test.go

# Fail the build if the patch did not take. The unpatched classifier returns a
# PERMANENT error for an unrecognised code, so this test is the difference
# between the shipping binary retrying four times and giving up on the first
# attempt -- and a build that skipped the patch would otherwise succeed and look
# perfectly healthy.
#
# The -list check is not decoration. "go test -run <pattern>" exits 0 reporting
# "no tests to run" when nothing matches the pattern, so the whole gate would go
# quiet -- and still pass -- if the COPY above ever failed to land the file or
# the test were renamed. Ask for the test names first and refuse to continue
# without them.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eu; \
    present=$$(go test ./pkg/manager/link/ -list 'TestProvider400IsRetryable|TestSiblingCodesAreUnchanged' 2>&1); \
    case "$$present" in \
      *TestProvider400IsRetryable*) ;; \
      *) echo "the patch's tests are not in the tree; refusing to build" >&2; echo "$$present" >&2; exit 1 ;; \
    esac; \
    go test ./pkg/manager/link/ -run 'TestProvider400IsRetryable|TestSiblingCodesAreUnchanged' -v

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=1 \
    xx-go build -trimpath \
    -ldflags="-w -s -X github.com/sirrobot01/decypharr/pkg/version.Version=${VERSION} -X github.com/sirrobot01/decypharr/pkg/version.Channel=${CHANNEL}" \
    -o /decypharr && \
    xx-verify /decypharr

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-w -s" \
    -o /healthcheck cmd/healthcheck/main.go

# --- Runtime -----------------------------------------------------------------
FROM alpine:3.22

ARG VERSION=0.0.0
ARG CHANNEL=dev

LABEL version="${VERSION}-${CHANNEL}"
LABEL org.opencontainers.image.source="https://github.com/leonardoazeredo/ultimate-arr-stack"
LABEL org.opencontainers.image.title="decypharr-patched"
LABEL org.opencontainers.image.description="decypharr v2.5 plus the open upstream fix for classifying a provider 400 as retryable (PR #402)"
LABEL org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache fuse3 ca-certificates su-exec shadow curl unzip tzdata && \
    echo "user_allow_other" >> /etc/fuse.conf && \
    case "$(uname -m)" in \
        x86_64) ARCH=amd64 ;; \
        aarch64) ARCH=arm64 ;; \
        armv7l|armv7) ARCH=arm ;; \
        *) echo "Unsupported architecture: $(uname -m)" && exit 1 ;; \
    esac && \
    curl -O "https://downloads.rclone.org/rclone-current-linux-${ARCH}.zip" && \
    unzip "rclone-current-linux-${ARCH}.zip" && \
    cp rclone-*/rclone /usr/local/bin/ && \
    chmod +x /usr/local/bin/rclone && \
    rm -rf rclone-* && \
    apk del curl unzip

COPY --from=builder /decypharr /usr/bin/decypharr
COPY --from=builder /healthcheck /usr/bin/healthcheck
COPY --from=patched /src/scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV PUID=1000
ENV PGID=1000
ENV LOG_PATH=/app/logs

EXPOSE 8282
VOLUME ["/app"]

HEALTHCHECK --interval=10s --retries=10 CMD ["/usr/bin/healthcheck", "--config", "/app"]
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/decypharr", "--config", "/app"]
