# The Python and coverage toolkit, containerised.
#
# Same reasoning as tests/mutation/Dockerfile, for the same host: pi1 has no
# pip and no pipx, its python3 is PEP 668 externally-managed, and `apt install`
# needs root it does not have. The NAS is worse -- no npm at all, and a
# containerised alpine/git standing in for git. Containerising a missing tool is
# this repo's standing answer, not a new idea introduced here.
#
# Two tools, one image, because kcov costs one apt line rather than a second
# container:
#
#   python3-pytest  the oracle for scripts/lib/*.py, which were heredocs until
#                   they were lifted out and could not be imported at all.
#   kcov            a ONE-SHOT diagnostic, not a gate. It instruments by file
#                   path, and this repo's signature test idiom (awk-extract a
#                   function body and eval it) produces code with no path, so
#                   kcov reports the most thoroughly tested shell in the repo as
#                   0% covered. See tests/toolkit/README.md for the keep-or-
#                   delete rule that decides whether coverage.sh survives.
#
# Pinned by digest for the same reason the mutator is: a floating install
# silently changes what a measurement means between runs, and this repo has
# already paid for that once (the floating npm install against a pinned
# Playwright base, see CLAUDE.md).
#
# trixie, not bookworm: kcov 43 is published for arm64 there, so this is an
# apt-get install rather than a source build on a Pi.
FROM debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        kcov \
        python3 \
        python3-pytest \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /mnt
